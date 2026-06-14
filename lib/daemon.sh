#!/usr/bin/env bash
# Generic daemon manager for project-wide singleton processes declared in config.
#
# worktree-deck treats daemons as optional companions to the console: a project
# config names them in WTD_DAEMONS and provides command/url/type/pattern maps.
# This library owns pidfiles, logs, stale-process cleanup, and start/stop/status
# behavior; the project owns the actual daemon command.
#
# Usage (CLI, via the console's daemon menu or a sourced wrapper):
#   daemon.sh start-all           Start all registered daemons
#   daemon.sh start-auto          Start only safe autostart daemons
#   daemon.sh stop-all            Stop all registered daemons
#   daemon.sh status              Show status of all daemons
#   daemon.sh start <name>        Start a specific daemon
#   daemon.sh stop <name>         Stop a specific daemon
#   daemon.sh restart <name>      Restart a specific daemon
#   daemon.sh logs <name> [N]     Show last N lines of log (default 20)
#
# Usage (sourced):
#   source lib/daemon.sh
#   daemon_start pr-dashboard
#   daemon_is_running pr-dashboard && echo "up"

set -euo pipefail

_DAEMON_SH_PATH="${BASH_SOURCE[0]:-$0}"
# Pull in the daemon registry (WTD_DAEMONS + WTD_DAEMON_* maps) if not already
# sourced, so this works both standalone and when sourced by worktree-deck.
if [[ -z "${WTD_DAEMONS+x}" ]]; then
    # shellcheck source=config.sh
    source "$(cd "$(dirname "$_DAEMON_SH_PATH")" && pwd)/config.sh"
fi

DAEMON_DIR="${WTD_DAEMON_DIR:-$HOME/.cache/worktree-deck/daemons}"
PROJECT_ROOT="${WTD_MAIN_REPO:-$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || pwd)}"

# Colors (only when stdout is a terminal or when sourced by an interactive script)
if [[ -t 1 ]] || [[ "${DAEMON_COLOR:-}" == "1" ]]; then
    _R='\033[0;31m'; _G='\033[0;32m'; _Y='\033[1;33m'; _C='\033[0;36m'; _B='\033[1m'; _N='\033[0m'
else
    _R=''; _G=''; _Y=''; _C=''; _B=''; _N=''
fi

# ── Registry ────────────────────────────────────────────────────────────────
# The registry is user-defined in worktree-deck.conf via WTD_DAEMONS + the
# WTD_DAEMON_CMD/URL/TYPE/PATTERN maps (see lib/config.sh). Default: none.
DAEMON_NAMES="${WTD_DAEMONS[*]:-}"
DAEMON_AUTOSTART_NAMES="${WTD_DAEMONS_AUTOSTART[*]:-}"

daemon_get_command() {
    local c="${WTD_DAEMON_CMD[$1]:-}"
    [[ -n "$c" ]] || return 1
    echo "$c"
}

daemon_get_url() {
    echo "${WTD_DAEMON_URL[$1]:-}"
}

# "loop:<seconds>" = run, sleep, repeat.  "persistent" = run once, stays alive.
daemon_get_type() {
    echo "${WTD_DAEMON_TYPE[$1]:-persistent}"
}

# ── Core functions ──────────────────────────────────────────────────────────

daemon_pidfile() { echo "$DAEMON_DIR/$1.pid"; }
daemon_logfile() { echo "$DAEMON_DIR/$1.log"; }

# Recursively kill a process and all its descendants (depth-first).
_kill_tree() {
    local pid="$1" sig="${2:-TERM}"
    local children
    children=$(pgrep -P "$pid" 2>/dev/null || true)
    for child in $children; do
        _kill_tree "$child" "$sig"
    done
    kill "-$sig" "$pid" 2>/dev/null || true
}

_pid_in_tree() {
    local root_pid="$1" candidate_pid="$2"
    [[ -z "$root_pid" || -z "$candidate_pid" ]] && return 1
    [[ "$root_pid" == "$candidate_pid" ]] && return 0

    local children child
    children=$(pgrep -P "$root_pid" 2>/dev/null || true)
    for child in $children; do
        _pid_in_tree "$child" "$candidate_pid" && return 0
    done
    return 1
}

_file_mtime() {
    local path="$1"
    if stat -f%m "$path" >/dev/null 2>&1; then
        stat -f%m "$path"
    elif stat -c %Y "$path" >/dev/null 2>&1; then
        stat -c %Y "$path"
    else
        echo 0
    fi
}
# Grep pattern that matches any running instance of a daemon (tracked or orphaned).
_daemon_grep_pattern() {
    local p="${WTD_DAEMON_PATTERN[$1]:-}"
    [[ -n "$p" ]] || return 1
    echo "$p"
}

# Kill ALL processes matching a daemon's command pattern, regardless of PID tracking.
# This catches orphans from legacy launchers or crashed sessions.
# Pass optional $2 = PID whose full process tree should be spared.
_kill_orphans() {
    local name="$1"
    local spare_pid="${2:-}"
    local pattern
    pattern=$(_daemon_grep_pattern "$name") || return 0
    local my_pid=$$
    local pids
    pids=$(pgrep -f "$pattern" 2>/dev/null || true)
    for pid in $pids; do
        # Don't kill ourselves or anything in the tracked process tree.
        [[ "$pid" == "$my_pid" ]] && continue
        if [[ -n "$spare_pid" ]] && _pid_in_tree "$spare_pid" "$pid"; then
            continue
        fi
        _kill_tree "$pid"
    done
}

# Wait until no process matches the daemon's command pattern, escalating to
# SIGKILL if a graceful shutdown stalls. Bounded (~10s) so a wedged process
# can't block forever. This closes the stop→start race in `restart`: a
# follow-on start would otherwise bind before the old instance released its
# listening socket, failing with "address already in use".
_wait_daemon_dead() {
    local name="$1"
    local pattern
    pattern=$(_daemon_grep_pattern "$name") || return 0
    local my_pid=$$
    local waited=0
    while (( waited < 40 )); do
        local remaining
        remaining=$(pgrep -f "$pattern" 2>/dev/null | grep -vx "$my_pid" || true)
        [[ -z "$remaining" ]] && return 0
        if (( waited == 12 )); then  # ~3s of graceful TERM, then force-kill
            local p
            for p in $remaining; do kill -KILL "$p" 2>/dev/null || true; done
        fi
        sleep 0.25
        waited=$(( waited + 1 ))
    done
}

daemon_is_running() {
    local name="$1"
    local pidfile
    pidfile=$(daemon_pidfile "$name")

    if [[ -f "$pidfile" ]]; then
        local pid
        pid=$(cat "$pidfile" 2>/dev/null)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
        rm -f "$pidfile"  # stale
    fi
    return 1
}

daemon_pid() {
    local pidfile
    pidfile=$(daemon_pidfile "$1")
    [[ -f "$pidfile" ]] && cat "$pidfile" 2>/dev/null || echo ""
}

daemon_start() {
    local name="$1"

    # Reap orphans, but spare the tracked instance if it's still alive.
    local tracked_pid=""
    local pidfile
    pidfile=$(daemon_pidfile "$name")
    if [[ -f "$pidfile" ]]; then
        tracked_pid=$(cat "$pidfile" 2>/dev/null)
        if [[ -n "$tracked_pid" ]] && ! kill -0 "$tracked_pid" 2>/dev/null; then
            tracked_pid=""  # stale — don't spare it
        fi
    fi
    _kill_orphans "$name" "$tracked_pid"

    if daemon_is_running "$name"; then
        return 0  # idempotent
    fi

    local cmd type
    cmd=$(daemon_get_command "$name") || { echo "Unknown daemon: $name" >&2; return 1; }
    type=$(daemon_get_type "$name")

    mkdir -p "$DAEMON_DIR"
    local logfile pidfile
    logfile=$(daemon_logfile "$name")
    pidfile=$(daemon_pidfile "$name")

    # Use a lockfile to prevent concurrent starts from racing
    local lockfile="$DAEMON_DIR/$name.lock"
    if [[ -f "$lockfile" ]]; then
        local lock_age=$(( $(date +%s) - $(_file_mtime "$lockfile") ))
        if [[ $lock_age -lt 30 ]]; then
            return 0  # another start is in progress
        fi
        rm -f "$lockfile"  # stale lock
    fi
    touch "$lockfile"
    trap "rm -f '$lockfile'" RETURN 2>/dev/null || true

    if [[ "$type" == loop:* ]]; then
        local interval="${type#loop:}"
        nohup bash -c "
            while true; do
                echo \"[\$(date -Iseconds)] Starting $name\" >> \"$logfile\"
                ( $cmd ) >> \"$logfile\" 2>&1 || true
                echo \"[\$(date -Iseconds)] $name exited, sleeping ${interval}s\" >> \"$logfile\"
                sleep $interval
            done
        " </dev/null >/dev/null 2>&1 &
    else
        nohup bash -c "
            echo \"[\$(date -Iseconds)] Starting $name\" >> \"$logfile\"
            $cmd >> \"$logfile\" 2>&1
            echo \"[\$(date -Iseconds)] $name exited\" >> \"$logfile\"
        " </dev/null >/dev/null 2>&1 &
    fi

    local pid=$!
    echo "$pid" > "$pidfile"

    # Give it a moment to crash
    sleep 1
    if ! kill -0 "$pid" 2>/dev/null; then
        rm -f "$pidfile"
        # Check if it died because another instance owns the port
        if grep -qiE "Address already in use|port .* is in use" "$logfile" 2>/dev/null; then
            return 2  # already running externally
        fi
        return 1
    fi
    return 0
}

daemon_stop() {
    local name="$1"
    local pidfile
    pidfile=$(daemon_pidfile "$name")

    # Kill tracked process tree
    if [[ -f "$pidfile" ]]; then
        local pid
        pid=$(cat "$pidfile" 2>/dev/null)
        if [[ -n "$pid" ]]; then
            _kill_tree "$pid"
        fi
        rm -f "$pidfile"
    fi

    # Kill any orphaned instances (legacy launchers, crashed sessions, etc.)
    _kill_orphans "$name"

    # Don't return until they're actually gone, so a follow-on start can bind.
    _wait_daemon_dead "$name"
}

daemon_status_line() {
    local name="$1"
    if daemon_is_running "$name"; then
        local pid
        pid=$(daemon_pid "$name")
        echo -e "  ${_G}●${_N} ${_B}${name}${_N}: running (pid ${pid})"
    else
        echo -e "  ${_R}○${_N} ${_B}${name}${_N}: stopped"
    fi
}

daemon_logs() {
    local name="$1"
    local lines="${2:-20}"
    local logfile
    logfile=$(daemon_logfile "$name")
    if [[ -f "$logfile" ]]; then
        tail -n "$lines" "$logfile"
    else
        echo "No log file for $name"
    fi
}

# ── Batch operations ────────────────────────────────────────────────────────

_daemon_start_named_set() {
    local names="$1"
    for name in $names; do
        local url; url=$(daemon_get_url "$name")
        local url_hint=""; [[ -n "$url" ]] && url_hint=" — ${_C}${url}${_N}"
        # Always go through daemon_start — it reaps orphans, checks PID, and is idempotent.
        printf "  ${_Y}→${_N} ${_B}%s${_N}: " "$name"
        local rc=0; daemon_start "$name" || rc=$?
        if [[ $rc -eq 0 ]]; then
            if daemon_is_running "$name"; then
                echo -e "running (pid $(daemon_pid "$name"))${url_hint}"
            else
                echo -e "${_R}✗${_N} failed — see $(daemon_logfile "$name")"
            fi
        elif [[ $rc -eq 2 ]]; then
            echo -e "already running externally${url_hint}"
        else
            echo -e "${_R}✗${_N} failed — see $(daemon_logfile "$name")"
        fi
    done
}

daemon_start_all() {
    _daemon_start_named_set "$DAEMON_NAMES"
}

daemon_start_auto() {
    _daemon_start_named_set "$DAEMON_AUTOSTART_NAMES"
}

daemon_stop_all() {
    for name in $DAEMON_NAMES; do
        daemon_stop "$name"
    done
    echo "All daemons stopped"
}

daemon_status_all() {
    for name in $DAEMON_NAMES; do
        daemon_status_line "$name"
    done
}

# ── CLI interface (only when executed directly, not sourced) ────────────────

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
    case "${1:-status}" in
        start-all)
            daemon_start_all
            ;;
        start-auto)
            daemon_start_auto
            ;;
        stop-all)
            daemon_stop_all
            ;;
        status)
            daemon_status_all
            ;;
        start)
            name="${2:?Usage: daemon.sh start <name>}"
            rc=0; daemon_start "$name" || rc=$?
            if [[ $rc -eq 0 ]]; then
                echo -e "${_G}●${_N} $name started (pid $(daemon_pid "$name"))"
            elif [[ $rc -eq 2 ]]; then
                echo -e "${_Y}●${_N} $name already running externally (port in use)"
            else
                echo -e "${_R}✗${_N} $name failed to start" >&2
                exit 1
            fi
            ;;
        stop)
            name="${2:?Usage: daemon.sh stop <name>}"
            daemon_stop "$name"
            echo -e "${_R}○${_N} $name stopped"
            ;;
        restart)
            name="${2:?Usage: daemon.sh restart <name>}"
            daemon_stop "$name"
            if daemon_start "$name"; then
                echo -e "${_G}●${_N} $name restarted (pid $(daemon_pid "$name"))"
            else
                echo -e "${_R}✗${_N} $name failed to restart" >&2
                exit 1
            fi
            ;;
        logs)
            daemon_logs "${2:?Usage: daemon.sh logs <name> [lines]}" "${3:-20}"
            ;;
        *)
            echo "Usage: daemon.sh {start-all|start-auto|stop-all|status|start|stop|restart|logs} [name] [args]"
            exit 1
            ;;
    esac
fi
