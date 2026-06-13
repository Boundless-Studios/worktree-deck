#!/usr/bin/env bash
# Host-global serialization for stack-start.
#
# Why: bringing one worktree's stack up can touch HOST-GLOBAL, non-worktree-
# scoped resources — a shared file-sync session, a shared image builder, shared
# background cleanup sweeps, a single-stack guard, etc. Two starts running at
# once interleave those phases and trample each other. Serializing starts on the
# host removes that whole contention class: a queued start simply runs after the
# first finishes (every well-built start command is idempotent).
#
# This is OPT-IN. It does nothing unless WTD_SERIALIZE_STACK_START is truthy.
# When enabled, wtd_stack_start runs under an advisory, host-scoped lock — which
# is exactly the scope of the contended resources.
#
# macOS ships no `flock`, so this uses an atomic `mkdir` lock with PID +
# process-start-token stale reclaim (a recycled PID can't masquerade as the
# original holder). Sourced by config.sh; also drives the `lock-health` command.
#
# Config:
#   WTD_SERIALIZE_STACK_START         1/true to serialize wtd_stack_start (default off)
#   WTD_STACK_START_LOCK              lock dir (default ${TMPDIR:-/tmp}/wtd-stack-start.lock)
#   WTD_STACK_START_LOCK_TIMEOUT      seconds to wait for the lock (default 1800; 0 = forever)
#   WTD_STACK_START_LOCK_LONG_HELD    seconds before a held lock is flagged long-running (default 300)

: "${WTD_STACK_START_LOCK:=${TMPDIR:-/tmp}/wtd-stack-start.lock}"
: "${WTD_STACK_START_LOCK_TIMEOUT:=1800}"
: "${WTD_STACK_START_LOCK_LONG_HELD:=300}"
: "${WTD_STACK_START_LOCK_MISSING_PID_GRACE:=1}"

_wtd_lock_path_mtime() {
    local path="$1"
    stat -c %Y "$path" 2>/dev/null || stat -f %m "$path" 2>/dev/null || date +%s
}

_wtd_lock_elapsed_seconds() {
    local path="$1" now mtime
    now="$(date +%s)"
    mtime="$(_wtd_lock_path_mtime "$path")"
    printf '%s\n' "$((now - mtime))"
}

_wtd_lock_path_old_enough() {
    local path="$1" grace="$2"
    [[ -e "$path" ]] || return 1
    [[ "$(_wtd_lock_elapsed_seconds "$path")" -ge "$grace" ]]
}

_wtd_lock_pid_is_running() {
    local pid="$1"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$pid" 2>/dev/null || ps -p "$pid" >/dev/null 2>&1
}

# A token that uniquely identifies a process INSTANCE (not just its PID), so a
# recycled PID can't be mistaken for the original lock holder.
_wtd_lock_process_start_token() {
    local pid="$1" token
    if [[ -r "/proc/$pid/stat" ]]; then
        token="$(awk '{ sub(/^[^)]*\) /, ""); print $20 }' "/proc/$pid/stat" 2>/dev/null || true)"
        if [[ -n "$token" ]]; then
            printf 'linux-start-ticks:%s\n' "$token"
            return 0
        fi
    fi
    token="$(TZ=UTC0 ps -p "$pid" -o lstart= 2>/dev/null | tr -s ' ' | sed 's/^ //;s/ $//' || true)"
    if [[ -n "$token" ]]; then
        printf 'utc-lstart:%s\n' "$token"
    fi
}

_wtd_lock_holder_matches_startfile() {
    local pid="$1" startfile="$2" expected actual
    _wtd_lock_pid_is_running "$pid" || return 1
    expected="$(cat "$startfile" 2>/dev/null || true)"
    [[ -z "$expected" ]] && return 0
    actual="$(_wtd_lock_process_start_token "$pid")"
    [[ -z "$actual" ]] && return 0
    [[ "$actual" == "$expected" ]]
}

_wtd_lock_write_owner_metadata() {
    local pidfile="$1" startfile="$2" owner_start
    owner_start="$(_wtd_lock_process_start_token "$$")"
    [[ -n "$owner_start" ]] || return 1
    printf '%s\n' "$$" >"$pidfile" && printf '%s\n' "$owner_start" >"$startfile"
}

# Acquire the lock, run "$@", release on any exit path. Only the owner releases.
# Always invoked inside a subshell (see wtd_stack_start), so the local `set +e`
# and the EXIT/signal traps stay contained. The original gaia script ran under
# `set -uo pipefail` (no -e); the polling/reclaim logic relies on individual
# commands being allowed to fail, so disable -e for the duration here too.
wtd_stack_start_lock_run() {
    [[ $# -gt 0 ]] || { echo "wtd_stack_start_lock_run: command required" >&2; return 2; }
    set +e

    local lock_dir="$WTD_STACK_START_LOCK"
    local pidfile="$lock_dir/pid" startfile="$lock_dir/start"
    local reclaim_dir="${lock_dir}.reclaim" reclaim_pid="${lock_dir}.reclaim/pid" reclaim_start="${lock_dir}.reclaim/start"
    local wait_timeout="$WTD_STACK_START_LOCK_TIMEOUT" grace="$WTD_STACK_START_LOCK_MISSING_PID_GRACE"
    local waited=0 announced=0 child_pid="" status

    _release() {
        local owner
        owner="$(cat "$reclaim_pid" 2>/dev/null || true)"
        [[ "$owner" == "$$" ]] && rm -rf "$reclaim_dir" 2>/dev/null || true
        owner="$(cat "$pidfile" 2>/dev/null || true)"
        [[ "$owner" == "$$" ]] && rm -rf "$lock_dir" 2>/dev/null || true
    }
    # shellcheck disable=SC2329  # invoked indirectly via the signal traps below
    _terminate() {
        local sig="$1" code="$2"
        trap - EXIT INT TERM HUP
        if [[ -n "${child_pid:-}" ]] && kill -0 "$child_pid" 2>/dev/null; then
            kill "-$sig" "$child_pid" 2>/dev/null || true
            wait "$child_pid" 2>/dev/null || true
        fi
        _release
        return "$code"
    }
    # Reclaim a stale lock under a short-lived mkdir mutex, re-verifying the
    # holder is still dead before deleting — so a freshly-acquired LIVE lock is
    # never wiped (which would let two starts run at once).
    _acquire_reclaim() {
        if mkdir "$reclaim_dir" 2>/dev/null; then
            _wtd_lock_write_owner_metadata "$reclaim_pid" "$reclaim_start" && return 0
            rm -rf "$reclaim_dir" 2>/dev/null || true
        fi
        return 1
    }

    trap '_release' EXIT
    trap '_terminate INT 130; exit 130' INT
    trap '_terminate TERM 143; exit 143' TERM
    trap '_terminate HUP 129; exit 129' HUP

    while true; do
        if mkdir "$lock_dir" 2>/dev/null; then
            if ! _wtd_lock_write_owner_metadata "$pidfile" "$startfile"; then
                echo "[stack-start-lock] failed to record lock owner metadata; aborting." >&2
                rm -rf "$lock_dir" 2>/dev/null || true
                trap - EXIT INT TERM HUP
                return 1
            fi
            break
        fi

        local holder
        holder="$(cat "$pidfile" 2>/dev/null || true)"
        if [[ -z "$holder" ]] || ! _wtd_lock_holder_matches_startfile "$holder" "$startfile"; then
            local reclaimed=0
            if _acquire_reclaim; then
                local h
                h="$(cat "$pidfile" 2>/dev/null || true)"
                if [[ -z "$h" ]] && _wtd_lock_path_old_enough "$lock_dir" "$grace"; then
                    echo "[stack-start-lock] reclaiming stale lock with missing pidfile" >&2
                    rm -rf "$lock_dir" 2>/dev/null && [[ ! -e "$lock_dir" ]] && reclaimed=1
                elif [[ -n "$h" ]] && ! _wtd_lock_holder_matches_startfile "$h" "$startfile"; then
                    echo "[stack-start-lock] reclaiming stale lock from dead pid $h" >&2
                    rm -rf "$lock_dir" 2>/dev/null && [[ ! -e "$lock_dir" ]] && reclaimed=1
                fi
                rm -rf "$reclaim_dir" 2>/dev/null || true
            fi
            [[ "$reclaimed" -eq 1 ]] && continue
        fi

        if [[ "$announced" -eq 0 ]]; then
            echo "[stack-start-lock] another stack start is running (pid ${holder:-?}); waiting…" >&2
            echo "[stack-start-lock] inspect: worktree-deck lock-health   repair: worktree-deck lock-health --repair" >&2
            announced=1
        fi
        if [[ "$wait_timeout" -gt 0 && "$waited" -ge "$wait_timeout" ]]; then
            echo "[stack-start-lock] timed out after ${wait_timeout}s waiting for pid ${holder:-?}." >&2
            trap - EXIT INT TERM HUP
            _release
            return 1
        fi
        sleep 2
        waited=$((waited + 2))
    done

    "$@" &
    child_pid=$!
    wait "$child_pid"
    status=$?
    child_pid=""
    trap - EXIT INT TERM HUP
    _release
    return "$status"
}

# Diagnose (and with --repair, clear) a stale stack-start lock.
wtd_stack_start_lock_health() {
    local repair=0
    [[ "${1:-}" == "--repair" ]] && repair=1

    local lock_dir="$WTD_STACK_START_LOCK"
    local pidfile="$lock_dir/pid"
    local grace="$WTD_STACK_START_LOCK_MISSING_PID_GRACE"
    local long_held="$WTD_STACK_START_LOCK_LONG_HELD"

    _remove_if_stale() {
        local reason="$1"
        if [[ "$repair" -ne 1 ]]; then
            printf 'stale lock: %s\n' "$reason" >&2
            printf 'repair: worktree-deck lock-health --repair\n' >&2
            return 1
        fi
        if rm -rf "$lock_dir" 2>/dev/null && [[ ! -e "$lock_dir" ]]; then
            printf 'removed stale stack-start lock: %s (%s)\n' "$lock_dir" "$reason"
            return 0
        fi
        printf 'failed to remove stale stack-start lock: %s\n' "$lock_dir" >&2
        return 1
    }

    if [[ ! -e "$lock_dir" ]]; then
        printf 'stack-start lock: none active\npath: %s\n' "$lock_dir"
        return 0
    fi

    local elapsed pid
    elapsed="$(_wtd_lock_elapsed_seconds "$lock_dir")"
    pid="$(cat "$pidfile" 2>/dev/null || true)"
    printf 'stack-start lock: active\npath: %s\nelapsed: %ss\n' "$lock_dir" "$elapsed"

    if [[ -z "$pid" ]]; then
        if _wtd_lock_path_old_enough "$lock_dir" "$grace"; then
            _remove_if_stale "missing pidfile"; return $?
        fi
        printf 'state: owner metadata pending\n' >&2
        return 1
    fi
    printf 'pid: %s\n' "$pid"

    if ! _wtd_lock_holder_matches_startfile "$pid" "$lock_dir/start"; then
        _remove_if_stale "dead or mismatched owner pid $pid"; return $?
    fi

    local cmd
    cmd="$(ps -o args= -p "$pid" 2>/dev/null | head -c 240 || true)"
    printf 'state: live owner\ncommand: %s\n' "${cmd:-unknown}"
    if [[ "$elapsed" -ge "$long_held" ]]; then
        printf 'assessment: healthy long-running start if the command is still making progress\n'
        printf 'next: inspect the owning session before repairing (worktree-deck lock-health --repair)\n'
        return 1
    fi
    printf 'assessment: healthy recent start\nnext: wait, or inspect again if it stays blocked\n'
    return 0
}
