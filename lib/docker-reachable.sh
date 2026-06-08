#!/usr/bin/env bash
# Source me — I provide a fast probe for "is the docker daemon reachable?"
# with transparent fallback from a dead remote DOCKER_HOST to the local
# daemon, plus an optional wake-hook flow callers can invoke explicitly.
#
# Background: with DOCKER_HOST=ssh://user@desktop, every `docker ...` call
# SSH-connects to the remote daemon. If the desktop is offline, each call
# waits for docker's internal ssh connect timeout (~30s) before failing.
# Scripts like cleanup-merged-worktrees.sh and worktree-console.sh issue
# many docker calls in a loop and wedge for many minutes.
#
# Default behavior — transparent fallback, tty-aware
#   gaia_docker_reachable probes the current DOCKER_HOST. If it's ssh://
#   and the probe fails, we silently `unset DOCKER_HOST` in this process
#   and re-probe the local daemon. Callers (cleanup, wc, …) just continue.
#   Mirrors what the top-level Makefile already does (Makefile:52-69).
#
#   The default probe timeout adapts to context:
#     - interactive (stderr/stdout/stdin is a tty)  → 15s
#         Long enough to absorb a directed-packet wake (S3 sleep or WSL2
#         vmIdleTimeout resume) so the user gets the remote daemon back
#         without setting anything.
#     - non-interactive (agent / pipeline / CI)     →  3s
#         Background invokers shouldn't stall on a desktop that might be
#         asleep — they fall back to local fast.
#
#   If a wake hook is installed AND we're interactive, the hook is invoked
#   before falling back. Presence of the hook = consent. Non-interactive
#   callers never invoke it, even if installed.
#
#   Set WTD_DOCKER_SKIP_WAKE=1 for latency-sensitive interactive callers that
#   need a fast probe and should not invoke the wake hook.
#
#   Set WTD_DOCKER_SKIP_FALLBACK=1 to suppress the silent fallback that unsets
#   DOCKER_HOST when the remote daemon probe fails. Callers that need a
#   cache-only result without swapping the active daemon — e.g. console
#   startup, where a slow-but-reachable remote could otherwise be misclassified
#   and silently flip the session to local Docker — set this before probing.
#
# Public API
#   gaia_docker_reachable [timeout_s]
#     0 if any docker daemon answers within timeout_s — the current one
#     or the local fallback. 1 only if both are unreachable. Omit the arg
#     to get the tty-aware default. Caches the result in
#     WTD_DOCKER_REACHABLE_CACHED (yes|no). When fallback happens, sets
#     WTD_DOCKER_FELL_BACK_FROM to the original DOCKER_HOST.
#
#   gaia_docker_wake_then_reprobe [poll_total_s] [poll_interval_s]
#     Called automatically from gaia_docker_reachable when interactive
#     and a wake hook exists. Also exported so callers can invoke it
#     directly with custom polling budgets.
#
# Wake hook search order (first executable wins)
#   1) $GAIA_DESKTOP_WAKE_SCRIPT
#   2) $HOME/.config/gaia/desktop-wake.sh
#   3) <repo_root>/scripts/local/desktop-wake.sh   (.gitignored)
#
# Hook contract
#   - exit 0  → wake initiated successfully, caller will poll for the daemon
#   - exit !0 → no wake possible, caller falls through
#   - stdout/stderr are surfaced to the user.

# Detect if we've already been sourced; allow re-sourcing safely.
if [[ -n "${_WTD_DOCKER_REACHABLE_LOADED:-}" ]]; then
    return 0 2>/dev/null || true
fi
_WTD_DOCKER_REACHABLE_LOADED=1

# Treat a caller as interactive if any of stdin/stdout/stderr is a tty.
# stderr is the most reliable signal — it's rarely redirected even when
# stdout is piped into something else.
_gaia_is_interactive() {
    [[ -t 2 ]] || [[ -t 1 ]] || [[ -t 0 ]]
}

# Internal — probe whatever DOCKER_HOST currently points at, with a hard
# timeout. ssh:// uses ssh's own ConnectTimeout (the daemon's actual ping
# isn't needed; if the ssh handshake works the daemon is one syscall away).
# Anything else runs `docker info` under a background+kill timeout.
# Internal — authoritative "can the docker CLI reach a daemon?" probe. Runs
# `docker info` under a hard background+kill timeout. Works for any DOCKER_HOST
# scheme: for ssh:// the docker CLI uses its own ssh transport, so this answers
# the real question even where a raw `ssh` probe is unavailable.
_gaia_docker_info_probe() {
    local timeout="${1:-3}"
    local out_file; out_file="$(mktemp -t docker-probe.XXXXXX)"
    docker info --format ' ' >"$out_file" 2>&1 &
    local pid=$!
    local waited=0
    while kill -0 "$pid" 2>/dev/null; do
        sleep 1
        waited=$((waited + 1))
        if [[ "$waited" -ge "$timeout" ]]; then
            kill -9 "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
            rm -f "$out_file"
            return 1
        fi
    done
    wait "$pid" 2>/dev/null
    local rc=$?
    rm -f "$out_file"
    return "$rc"
}

_gaia_docker_probe_one() {
    local timeout="${1:-3}"
    case "${DOCKER_HOST:-}" in
        ssh://*)
            local userhost="${DOCKER_HOST#ssh://}"
            userhost="${userhost%%/*}"
            ssh -o BatchMode=yes \
                -o ConnectTimeout="$timeout" \
                -o ServerAliveInterval=1 \
                -o ServerAliveCountMax=2 \
                "$userhost" true >/dev/null 2>&1
            ;;
        *)
            _gaia_docker_info_probe "$timeout"
            ;;
    esac
}

# Authoritative reachability via the docker CLI (`docker info`), independent of
# the DOCKER_HOST scheme. Use as a BACKSTOP after gaia_docker_reachable when a
# false negative from the raw ssh:// probe would be costly — e.g. a preflight
# gate in a sandbox that blocks raw `ssh` but where the docker CLI still reaches
# the remote daemon over its own ssh transport. Mirrors the Makefile's
# docker-info-based remote detection. Does NOT mutate DOCKER_HOST or the cache.
gaia_docker_cli_reachable() {
    _gaia_docker_info_probe "${1:-3}"
}

gaia_docker_reachable() {
    # No-arg call → tty-aware default. Interactive callers absorb a
    # directed-packet wake (S3 sleep / WSL2 vmIdleTimeout) within the
    # window; non-interactive callers fall back fast.
    local timeout="${1:-}"
    local interactive=0
    if _gaia_is_interactive; then interactive=1; fi
    if [[ -z "$timeout" ]]; then
        # Explicit arg wins; else honor DOCKER_PROBE_TIMEOUT (matches the
        # Makefile probe, PR #1905); else tty-aware default.
        if [[ "${DOCKER_PROBE_TIMEOUT:-}" =~ ^[0-9]+$ ]]; then
            timeout="$DOCKER_PROBE_TIMEOUT"
        else
            [[ "$interactive" -eq 1 ]] && timeout=15 || timeout=3
        fi
    fi

    # Honor cached result unless the caller explicitly cleared it.
    if [[ -n "${WTD_DOCKER_REACHABLE_CACHED:-}" ]]; then
        [[ "$WTD_DOCKER_REACHABLE_CACHED" == "yes" ]]
        return $?
    fi

    if _gaia_docker_probe_one "$timeout"; then
        export WTD_DOCKER_REACHABLE_CACHED=yes
        return 0
    fi

    # Remote ssh:// unreachable. If interactive AND a wake hook is
    # installed, give it one shot to bring the daemon back before we
    # fall back to local. Non-interactive callers skip this entirely.
    if [[ "${DOCKER_HOST:-}" == ssh://* ]]; then
        local prev_host="$DOCKER_HOST"

        if [[ "$interactive" -eq 1 ]] \
           && [[ "${WTD_DOCKER_SKIP_WAKE:-}" != "1" ]] \
           && _gaia_docker_wake_hook_path >/dev/null 2>&1; then
            if gaia_docker_wake_then_reprobe 30 3; then
                export WTD_DOCKER_REACHABLE_CACHED=yes
                return 0
            fi
        fi

        # Skip-fallback callers (e.g. console startup pre-render) want the
        # cache set without swapping the active daemon. Preserves DOCKER_HOST
        # so a slow-but-reachable remote can still be used by subsequent
        # operations that re-probe with the cache cleared.
        if [[ "${WTD_DOCKER_SKIP_FALLBACK:-}" == "1" ]]; then
            export WTD_DOCKER_REACHABLE_CACHED=no
            return 1
        fi

        # Transparent fallback to the local daemon. We modify DOCKER_HOST
        # only in this process; the user's shell env is untouched.
        export DOCKER_HOST=""
        if _gaia_docker_probe_one 2; then
            echo "🌐 remote Docker (${prev_host}) slow/unreachable within ${timeout}s — using local daemon" >&2
            export WTD_DOCKER_REACHABLE_CACHED=yes
            export WTD_DOCKER_FELL_BACK_FROM="$prev_host"
            return 0
        fi
        # Local also failed — restore DOCKER_HOST so diagnostics show what
        # the user actually has configured.
        export DOCKER_HOST="$prev_host"
    fi

    export WTD_DOCKER_REACHABLE_CACHED=no
    return 1
}

gaia_docker_select() {
    unset WTD_DOCKER_MODE WTD_DOCKER_SELECTED_HOST WTD_DOCKER_FALLBACK_REASON WTD_DOCKER_DAEMON_NAME

    if [[ "${WTD_DOCKER_FORCE_LOCAL:-}" == "1" ]]; then
        export DOCKER_HOST=""
        export WTD_DOCKER_MODE="local-forced"
        export WTD_DOCKER_SELECTED_HOST=""
        export WTD_DOCKER_FALLBACK_REASON="forced-local"
    elif [[ -n "${DOCKER_HOST:-}" ]]; then
        local intended_host="$DOCKER_HOST"
        unset WTD_DOCKER_REACHABLE_CACHED WTD_DOCKER_FELL_BACK_FROM
        if gaia_docker_reachable "$@"; then
            if [[ -n "${WTD_DOCKER_FELL_BACK_FROM:-}" ]]; then
                export WTD_DOCKER_MODE="local-fallback"
                export WTD_DOCKER_SELECTED_HOST=""
                export WTD_DOCKER_FALLBACK_REASON="remote-unreachable:${WTD_DOCKER_FELL_BACK_FROM}"
            else
                export WTD_DOCKER_MODE="remote"
                export WTD_DOCKER_SELECTED_HOST="$intended_host"
                export WTD_DOCKER_FALLBACK_REASON=""
            fi
        else
            export WTD_DOCKER_MODE="unknown"
            export WTD_DOCKER_SELECTED_HOST="$intended_host"
            export WTD_DOCKER_FALLBACK_REASON="no-daemon-reachable"
            return 1
        fi
    else
        unset WTD_DOCKER_REACHABLE_CACHED WTD_DOCKER_FELL_BACK_FROM
        if gaia_docker_reachable "$@"; then
            export WTD_DOCKER_MODE="local-forced"
            export WTD_DOCKER_SELECTED_HOST=""
            export WTD_DOCKER_FALLBACK_REASON=""
        else
            export WTD_DOCKER_MODE="unknown"
            export WTD_DOCKER_SELECTED_HOST=""
            export WTD_DOCKER_FALLBACK_REASON="no-daemon-reachable"
            return 1
        fi
    fi

    local daemon_name
    daemon_name="$(docker info --format '{{.Name}}' 2>/dev/null || true)"
    export WTD_DOCKER_DAEMON_NAME="$daemon_name"
    return 0
}

_gaia_docker_wake_hook_path() {
    local script_dir; script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local candidates=(
        "${GAIA_DESKTOP_WAKE_SCRIPT:-}"
        "$HOME/.config/gaia/desktop-wake.sh"
        "$script_dir/../local/desktop-wake.sh"
    )
    for c in "${candidates[@]}"; do
        if [[ -n "$c" && -x "$c" ]]; then
            echo "$c"
            return 0
        fi
    done
    return 1
}

gaia_docker_wake_then_reprobe() {
    local total="${1:-60}"
    local interval="${2:-5}"

    local hook
    if ! hook="$(_gaia_docker_wake_hook_path)"; then
        return 1
    fi

    echo "🌐 Docker daemon unreachable. Invoking wake hook: $hook" >&2
    if ! "$hook"; then
        echo "🌐 Wake hook returned non-zero; no wake initiated." >&2
        return 1
    fi

    echo "🌐 Wake hook invoked. Polling daemon for up to ${total}s…" >&2
    local waited=0
    while [[ "$waited" -lt "$total" ]]; do
        unset WTD_DOCKER_REACHABLE_CACHED
        if gaia_docker_reachable 3; then
            echo "🌐 Docker daemon reachable after ${waited}s. Continuing." >&2
            return 0
        fi
        sleep "$interval"
        waited=$((waited + interval))
    done
    echo "🌐 Daemon still unreachable after ${total}s. Continuing in degraded mode." >&2
    return 1
}
