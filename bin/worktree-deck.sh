#!/usr/bin/env bash
# worktree-deck — Manage git worktrees and their dev stacks
# Usage: worktree-deck [--codex|--claude] [name]
#   name - optional worktree name (short or full branch) to jump directly to
set -euo pipefail

# --- Explicit subcommands (MUST precede the non-interactive `wc` guard) ---
# These are named verbs (never single-dash flags), so they can't collide with
# `printf ... | wc -l`. They run headless (agents/CI), so they must dispatch
# before the guard that would otherwise delegate to coreutils `wc`.
case "${1:-}" in
    lock-health|continue|continue-worktree|placement-check|run-locked)
        _WTD_SUBCMD="$1"; shift
        _WTD_SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        _WTD_LD="$(cd "${_WTD_SD}/../lib" && pwd)"
        # shellcheck source=../lib/config.sh
        source "${_WTD_LD}/config.sh"
        _WTD_MAIN_REPO="${WTD_MAIN_REPO:-$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || pwd)}"
        wtd_load_config "$_WTD_MAIN_REPO"
        case "$_WTD_SUBCMD" in
            lock-health)
                wtd_stack_start_lock_health "$@"; exit $? ;;
            continue|continue-worktree)
                wtd_continue_worktree "$@"; exit $? ;;
            placement-check)
                [[ $# -ge 1 && $# -le 3 ]] || {
                    echo "usage: worktree-deck placement-check <path> [identity] [class]" >&2
                    exit 2
                }
                _wtd_pc_path="$1"
                _wtd_pc_identity="${2:-$(basename "$_wtd_pc_path")}"
                _wtd_pc_class="${3:-managed_worktree}"
                wtd_evaluate_configured_placement \
                    "$_wtd_pc_identity" "$_wtd_pc_class" "$_wtd_pc_path"
                exit $? ;;
            run-locked)
                # Run an arbitrary command under the host-global stack-start lock,
                # ALWAYS serialized (independent of WTD_SERIALIZE_STACK_START, which
                # only gates the console's own wtd_stack_start). The headless
                # equivalent of a serialized wtd_stack_start — for projects that
                # drive their own start command (e.g. a Makefile) but want it
                # serialized on the host. Inspect/repair the same lock with
                # `worktree-deck lock-health`.
                #
                # With --cap, ALSO enforce WTD_BACKEND_CAP atomically: the cap
                # count and the start run under ONE lock acquisition, so two
                # concurrent capped starts can't both observe free capacity and
                # then both start (the TOCTOU a separate pre-flight check would
                # leave open). No-op cap when WTD_BACKEND_CAP is 0/unset.
                _wtd_rl_cap=0
                if [[ "${1:-}" == "--cap" ]]; then _wtd_rl_cap=1; shift; fi
                [[ $# -gt 0 ]] || { echo "usage: worktree-deck run-locked [--cap] <command> [args...]" >&2; exit 2; }
                # Subshell: wtd_stack_start_lock_run installs EXIT/signal traps and
                # `set +e`; keep them from leaking into this dispatch shell.
                if [[ "$_wtd_rl_cap" == "1" ]]; then
                    # The cap counts containers, so point DOCKER_HOST at the
                    # configured remote daemon (the one the project starts stacks
                    # on) before counting — an explicit DOCKER_HOST in the env
                    # wins. Scoped to --cap so plain run-locked leaves the wrapped
                    # command's own daemon resolution untouched.
                    if [[ -n "${WTD_REMOTE_DOCKER_HOST:-}" && -z "${DOCKER_HOST:-}" ]]; then
                        export DOCKER_HOST="$WTD_REMOTE_DOCKER_HOST"
                    fi
                    ( wtd_stack_start_lock_run _wtd_run_capped_command "$@" ); exit $?
                fi
                ( wtd_stack_start_lock_run "$@" ); exit $? ;;
        esac
        ;;
esac

# --- Non-interactive guard (MUST be first, before any source or arg-parsing) ---
# When not running in an interactive terminal (piped, redirected, agent, or CI),
# delegate transparently to the real coreutils `wc` so that the shell alias
#   wc() { bash .../worktree-console.sh "$@"; }
# is invisible to pipelines like `printf 'a\nb\n' | wc -l`.
# `command wc` bypasses the shell function and reaches the real binary.
# NOTE: `command` is a bash builtin, so it cannot be `exec`'d (exec needs an
# executable). Run `command wc` normally and exit with its status instead.
# The check mirrors the conditions used to guard the TUI render below.
if [[ ! -t 1 ]] || [[ ! -t 0 ]] || [[ "${TERM:-}" == "dumb" ]] || [[ -n "${CLAUDE_CODE:-}" ]] || [[ -n "${CI:-}" ]]; then
    command wc "$@"
    exit $?
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "${SCRIPT_DIR}/../lib" && pwd)"
# shellcheck source=../lib/worktree-launch-mode.sh
source "${LIB_DIR}/worktree-launch-mode.sh"
# shellcheck source=../lib/docker-reachable.sh
source "${LIB_DIR}/docker-reachable.sh"
# shellcheck source=../lib/config.sh
source "${LIB_DIR}/config.sh"
# shellcheck source=../lib/pr-metadata.sh
source "${LIB_DIR}/pr-metadata.sh"
# shellcheck source=../lib/worktree-render.sh
source "${LIB_DIR}/worktree-render.sh"
# shellcheck source=../lib/worktree-actions.sh
source "${LIB_DIR}/worktree-actions.sh"
# shellcheck source=../lib/cleanup.sh
source "${LIB_DIR}/cleanup.sh"
# shellcheck source=../lib/terminal.sh
source "${LIB_DIR}/terminal.sh"

DEFAULT_LAUNCH_FLAG="$(wtd_default_launch_flag)"
if wtd_is_launch_selector "${1:-}"; then
    DEFAULT_LAUNCH_FLAG="$(wtd_normalize_launch_flag "$1")"
    shift
fi

# Optional argument: jump directly to a named worktree
# Skip any remaining flag-like args (starting with -) — they are not worktree names.
# This prevents e.g. `| wc -l` from causing '-l' to be mis-parsed as a name.
_wc_arg="${1:-}"
if [[ "$_wc_arg" == -* ]]; then
    _wc_arg=""
fi
JUMP_TO="$_wc_arg"
unset _wc_arg


# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# --- Daemon manager (source for function access) ---
# shellcheck source=../lib/daemon.sh
DAEMON_COLOR=1 source "${LIB_DIR}/daemon.sh"

# --- Per-user console state ---
# Persistent per-user overrides (e.g. WTD_DAEMONS_DISABLED). Sourced if present.
CONSOLE_CONFIG_FILE="${WORKTREE_DECK_STATE:-$HOME/.config/worktree-deck/console.conf}"

# A daemon is "enabled" unless the user disabled it in WTD_DAEMONS_DISABLED.
is_daemon_enabled() {
    local name="$1" d
    for d in ${WTD_DAEMONS_DISABLED:-}; do
        [[ "$d" == "$name" ]] && return 1
    done
    return 0
}

load_console_config() {
    if [[ -r "$CONSOLE_CONFIG_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$CONSOLE_CONFIG_FILE" 2>/dev/null || true
    fi
}

save_console_config() {
    mkdir -p "$(dirname "$CONSOLE_CONFIG_FILE")" 2>/dev/null || true
    {
        echo "# worktree-deck — per-user state (generated)"
        echo "WTD_DAEMONS_DISABLED=\"${WTD_DAEMONS_DISABLED:-}\""
    } > "$CONSOLE_CONFIG_FILE"
}

# Main repo: explicit config, else the git toplevel of the invoking directory
# (worktree-deck is installed separately from the repo it manages).
MAIN_REPO="${WTD_MAIN_REPO:-$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || pwd)}"
wtd_load_config "$MAIN_REPO"
MAIN_REPO="${WTD_MAIN_REPO:-$MAIN_REPO}"
WORKTREES_DIR="${WTD_WORKTREES_DIR:-${MAIN_REPO}-worktrees}"

# Fail loudly instead of silently showing an empty worktree list. MAIN_REPO is
# derived from the cwd's git toplevel, so running `wc` from outside a repo (e.g.
# your home dir) would otherwise leave it pointed at a non-repo and list nothing.
if ! git -C "$MAIN_REPO" rev-parse --git-dir >/dev/null 2>&1; then
    echo -e "${RED}worktree-deck: '${MAIN_REPO}' is not a git repository.${NC}" >&2
    echo -e "${YELLOW}Run from inside your repo, or set WTD_MAIN_REPO in your config to pin it.${NC}" >&2
    exit 1
fi

# Hand the configured remote daemon off to DOCKER_HOST so every docker operation
# (status, start/stop, sweeps, reachability probe) actually targets it. A
# DOCKER_HOST already present in the environment wins — the user's explicit
# override is never clobbered. When the remote is unreachable, the reachability
# probe below falls back to the local daemon as designed.
if [[ -n "$WTD_REMOTE_DOCKER_HOST" && -z "${DOCKER_HOST:-}" ]]; then
    export DOCKER_HOST="$WTD_REMOTE_DOCKER_HOST"
fi

# Guard for the destructive container sweeps: without a configured prefix,
# `docker ps --filter name=^` would match EVERY container on the host, so the
# dead/orphan/stop-all sweeps refuse to run.
_wtd_require_container_prefix() {
    if [[ -z "${WTD_CONTAINER_PREFIX:-}" ]]; then
        echo -e "${YELLOW}Container cleanup is disabled — set WTD_CONTAINER_PREFIX in your worktree-deck.conf.${NC}"
        return 1
    fi
    return 0
}

# Global PR metadata cache: "branch<TAB>number<TAB>state<TAB>head_oid" per line.
PR_DATA=""
PR_DATA_AVAILABLE=0

# Avoid paying a Docker probe on every render while the daemon is unavailable.
WC_DOCKER_REPROBE_INTERVAL_SECONDS="${WC_DOCKER_REPROBE_INTERVAL_SECONDS:-15}"
WC_DOCKER_LAST_REPROBE_AT=0

# Print a one-line indicator of which docker daemon this console is talking
# to: local (Unix socket / unset DOCKER_HOST) or remote (ssh://, tcp://, …).
# Matches the local/remote split the Makefile uses so the two stay in sync.
print_daemon_indicator() {
    case "${DOCKER_HOST:-}" in
        ""|unix://*)
            echo -e "  ${BOLD}Docker:${NC}  ${GREEN}💻 local${NC}"
            ;;
        ssh://*)
            local host
            host=$(echo "$DOCKER_HOST" | sed -E 's|^ssh://([^@]*@)?([^:/]+).*|\2|')
            echo -e "  ${BOLD}Docker:${NC}  ${YELLOW}🖥  remote${NC} → ${CYAN}${host}${NC}  ${DOCKER_HOST}"
            ;;
        *)
            echo -e "  ${BOLD}Docker:${NC}  ${YELLOW}🌐 remote${NC} → ${CYAN}${DOCKER_HOST}${NC}"
            ;;
    esac
}

# Main menu
main_menu() {
    while true; do
        header
        list_worktrees

        echo -e "${BOLD}Actions:${NC}"
        echo -e "  ${CYAN}[#]${NC}        Select worktree by number"
        echo -e "  ${CYAN}[n]${NC}ew      Create new worktree"
        echo -e "  ${YELLOW}[X]${NC}        Stop + clean ALL dev-stack containers"
        echo -e "  ${YELLOW}[Y]${NC}        Remove dead (exited) containers"
        echo -e "  ${YELLOW}[O]${NC}        Remove orphan containers (no matching worktree)"
        echo -e "  ${RED}[M]${NC}        Delete stale worktrees (merged/closed/orphan)"
        echo -e "  ${CYAN}[r]${NC}efresh  Refresh list"
        echo -e "  ${CYAN}[D]${NC}aemons  Start/stop all daemons"
        echo -e "  ${CYAN}[C]${NC}onfig   Edit per-user console settings (toggle daemons)"
        echo -e "  ${CYAN}[q]${NC}uit     Exit"
        echo
        echo -e "  ${CYAN}[#cmd]${NC}     Quick command (e.g. ${CYAN}1r${NC}=resume agent, ${CYAN}7d${NC}=delete, ${CYAN}7dy${NC}=delete+confirm)"
        echo
        read -p "Choice: " choice

        case "$choice" in
            q|Q|quit|exit)
                echo "Goodbye!"
                exit 0
                ;;
            n|N|new)
                create_worktree
                ;;
            X)
                stop_all_worktrees
                read -p "Press Enter to continue..."
                ;;
            Y)
                remove_dead_containers
                read -p "Press Enter to continue..."
                ;;
            O|o)
                remove_orphan_containers
                read -p "Press Enter to continue..."
                ;;
            M|m)
                remove_stale_worktrees
                read -p "Press Enter to continue..."
                ;;
            r|R|refresh)
                continue
                ;;
            C)
                console_config_menu || true
                ;;
            D|d)
                echo -e "\n${BOLD}Daemon status:${NC}"
                daemon_status_all
                echo
                read -p "Start all / Stop all / Cancel? [s/x/c] " daemon_choice
                case "$daemon_choice" in
                    s|S) daemon_start_all ;;
                    x|X) daemon_stop_all ;;
                    *) ;;
                esac
                read -p "Press Enter to continue..."
                ;;
            [0-9]|[0-9][0-9])
                if [[ "$choice" -ge 1 && "$choice" -le "${#WORKTREE_PATHS[@]}" ]]; then
                    worktree_menu "${WORKTREE_PATHS[$((choice-1))]}"
                else
                    echo -e "${RED}Invalid selection${NC}"
                    read -p "Press Enter to continue..."
                fi
                ;;
            [0-9][a-zA-Z]|[0-9][a-zA-Z][a-zA-Z]|[0-9][0-9][a-zA-Z]|[0-9][0-9][a-zA-Z][a-zA-Z])
                # Quick command: parse number + action + optional extra
                local num="${choice%%[a-zA-Z]*}"
                local rest="${choice#$num}"
                local action="${rest:0:1}"
                local extra="${rest:1}"
                if [[ "$num" -ge 1 && "$num" -le "${#WORKTREE_PATHS[@]}" ]]; then
                    worktree_menu "${WORKTREE_PATHS[$((num-1))]}" "$action" "$extra"
                else
                    echo -e "${RED}Invalid selection${NC}"
                    read -p "Press Enter to continue..."
                fi
                ;;
            *)
                echo -e "${RED}Unknown command${NC}"
                read -p "Press Enter to continue..."
                ;;
        esac
    done
}

# Worktree action menu
# Args: path [pre_action] [pre_extra]
worktree_menu() {
    local path="$1"
    local pre_action="${2:-}"
    local pre_extra="${3:-}"
    local name=$(short_name "$path")
    local preferred_cli
    local preferred_label
    preferred_cli="$(wtd_launch_cli_from_flag "$DEFAULT_LAUNCH_FLAG")"
    preferred_label="$(wtd_launch_label_from_flag "$DEFAULT_LAUNCH_FLAG")"
    refresh_pr_data

    while true; do
        header
        local branch=$(cd "$path" && git branch --show-current 2>/dev/null || echo "unknown")
        local pr_state=$(get_pr_state "$branch")
        local slot=$(get_slot_info "$path")
        local ports=$(get_port_info "$path")
        local raw_status=$(get_container_status "$path")
        local status_display
        if [[ "$raw_status" == *"Running"* ]]; then
            status_display="${GREEN}● up${NC}"
        else
            status_display="${RED}○ down${NC}"
        fi

        echo -e "${BOLD}Worktree: ${CYAN}${name}${NC}  ${status_display}  slot ${slot}/9  ${ports}"
        echo -e "  Branch: ${branch}"
        echo -e "  Path:   ${path}"
        echo
        echo -e "${CYAN}───────────────────────────────────────────────────────────────────${NC}"
        echo -e "${BOLD}Actions:${NC}"
        echo -e "  ${GREEN}[s]${NC}tart   Start containers"
        echo -e "  ${YELLOW}[x]${NC}stop   Stop containers"
        echo -e "  ${YELLOW}[R]${NC}estart Rebuild containers (stop/start)"
        echo -e "  ${BLUE}[r]${NC}esume  Resume last agent (claude/codex)"
        echo -e "  ${BLUE}[f]${NC}ront   Open frontend in browser"
        echo -e "  ${BLUE}[l]${NC}ogs    Show backend logs"
        echo -e "  ${BLUE}[t]${NC}erm    Open terminal here"
        echo -e "  ${BLUE}[v]${NC}scode  Open in VS Code"
        echo -e "  ${BLUE}[o]${NC}pen    Launch ${preferred_label}"
        echo -e "  ${BLUE}[c]${NC}laude  Launch Claude Code"
        echo -e "  ${BLUE}[e]${NC}codex  Launch Codex CLI"
        echo -e "  ${GREEN}[E]${NC}2e     Run e2e tests (Playwright)"
        echo -e "  ${BLUE}[n]${NC}ext    Continue on a new branch (after PR merge)"
        echo -e "  ${RED}[d]${NC}elete  Remove worktree"
        echo -e "  ${NC}[b]${NC}ack    Back to list"
        echo

        local action
        if [[ -n "$pre_action" ]]; then
            action="$pre_action"
            echo -e "Choice: ${action} ${YELLOW}(quick)${NC}"
        else
            read -p "Choice: " action
        fi

        case "$action" in
            b|B|back)
                return
                ;;
            s|S|start)
                # start_worktree handles its own outcomes and returns 0, so no
                # `|| true` (which would suppress errexit inside it) is needed.
                start_worktree "$path"
                read -p "Press Enter to continue..."
                ;;
            x|X|stop)
                stop_worktree "$path"
                read -p "Press Enter to continue..."
                ;;
            R|restart)
                # restart_worktree handles its own outcomes and returns 0.
                restart_worktree "$path"
                read -p "Press Enter to continue..."
                ;;
            r|resume)
                resume_worktree_agent "$path" "$preferred_cli" "$preferred_label"
                ;;
            f|F|front)
                open_frontend "$path"
                ;;
            l|L|logs)
                show_logs "$path"
                read -p "Press Enter to continue..."
                ;;
            t|T|term)
                open_terminal "$path"
                ;;
            v|V|vscode)
                echo -e "${BLUE}Opening VS Code...${NC}"
                open_vscode "$path"
                ;;
            o|O|open)
                launch_worktree_agent "$path" "$preferred_cli" "$preferred_label"
                ;;
            c|C|claude)
                launch_worktree_agent "$path" "claude" "Claude Code"
                ;;
            e|codex)
                launch_worktree_agent "$path" "codex" "Codex CLI"
                ;;
            E|e2e)
                run_e2e_tests "$path" "$pre_extra"
                read -p "Press Enter to continue..."
                ;;
            n|N|next|continue)
                local nb base
                read -p "New branch name: " nb
                if [[ -n "$nb" ]]; then
                    read -p "Base [origin/main]: " base
                    # wtd_continue_worktree is self-contained (checks its own git
                    # steps, doesn't rely on caller errexit), so an `if` here can't
                    # mask an internal failure as success — it just reports outcome.
                    if ! wtd_continue_worktree "$path" "$nb" "${base:-origin/main}"; then
                        echo -e "${YELLOW}Continue did not complete cleanly (see above).${NC}"
                    fi
                else
                    echo -e "${YELLOW}Cancelled (no branch name).${NC}"
                fi
                read -p "Press Enter to continue..."
                ;;
            d|D|delete)
                remove_worktree "$path" "$pre_extra"
                read -p "Press Enter to continue..."
                return
                ;;
            *)
                echo -e "${RED}Unknown command${NC}"
                read -p "Press Enter to continue..."
                ;;
        esac

        # Clear quick-command state so the loop prompts normally
        pre_action=""
        pre_extra=""
    done
}

# Find worktree path by name (short name, full branch, or dir basename)
# Populates WORKTREE_PATHS as a side effect
find_worktree_by_name() {
    local target="$1"
    declare -g -a WORKTREE_PATHS=()

    while IFS= read -r line; do
        local path=$(echo "$line" | awk '{print $1}')
        WORKTREE_PATHS+=("$path")
    done < <(git -C "$MAIN_REPO" worktree list 2>/dev/null)

    for path in "${WORKTREE_PATHS[@]}"; do
        local sname=$(short_name "$path")
        local branch=$(cd "$path" && git branch --show-current 2>/dev/null || echo "")
        local dirname=$(basename "$path")

        if [[ "$sname" == "$target" || "$branch" == "$target" || "$dirname" == "$target" ]]; then
            echo "$path"
            return 0
        fi
    done
    return 1
}

# Interactive editor for the per-user console config. Toggle which daemons
# the console auto-starts and displays, then save. Changes are persisted to
# ${CONSOLE_CONFIG_FILE}; restart the console (or use [D]) to apply to
# already-running daemons.
console_config_menu() {
    local entries=("${WTD_DAEMONS[@]}")
    local labels=("PR dashboard daemon" "Claude usage analyzer" "Trace viewer daemon")
    local dirty=0

    while true; do
        clear
        echo -e "${BOLD}${CYAN}Worktree Console Settings${NC}"
        echo -e "  ${CYAN}File:${NC} ${CONSOLE_CONFIG_FILE}"
        echo
        local i=1
        local entry var val color status
        for entry in "${entries[@]}"; do
            var="$(_wc_daemon_var "$entry")"
            val="${!var:-true}"
            if [[ "$val" == "true" ]]; then
                color="$GREEN"; status="ENABLED "
            else
                color="$RED"; status="DISABLED"
            fi
            local label="${labels[$((i-1))]}"
            printf "  ${CYAN}[%d]${NC} %b%s%b  %s (%s)\n" \
                "$i" "$color" "$status" "$NC" "$label" "$entry"
            ((i++))
        done
        echo
        local pw_color pw_status
        if [[ "${WC_PR_WATCH_AUTOLOOP:-false}" == "true" ]]; then
            pw_color="$GREEN"; pw_status="ENABLED "
        else
            pw_color="$RED"; pw_status="DISABLED"
        fi
        printf "  ${CYAN}[w]${NC} %b%s%b  Auto-arm PR review-watch loop on push (in-session)\n" \
            "$pw_color" "$pw_status" "$NC"
        echo
        if [[ "$dirty" -eq 1 ]]; then
            echo -e "  ${YELLOW}● unsaved changes${NC}"
        fi
        echo -e "  ${CYAN}[s]${NC}ave    Save and return"
        echo -e "  ${CYAN}[c]${NC}ancel  Discard changes and return"
        echo
        local sel
        read -p "Choice: " sel

        case "$sel" in
            s|S)
                save_console_config
                echo -e "${GREEN}✓ Saved to ${CONSOLE_CONFIG_FILE}${NC}"
                echo -e "${YELLOW}Changes apply on next launch (auto-start) and to header display now.${NC}"
                read -p "Press Enter to continue..."
                return 0
                ;;
            c|C|q|Q)
                if [[ "$dirty" -eq 1 ]]; then
                    # Reload from disk to discard in-memory edits.
                    load_console_config
                fi
                return 1
                ;;
            w|W)
                if [[ "${WC_PR_WATCH_AUTOLOOP:-false}" == "true" ]]; then
                    WC_PR_WATCH_AUTOLOOP="false"
                else
                    WC_PR_WATCH_AUTOLOOP="true"
                fi
                dirty=1
                ;;
            [1-9])
                local idx=$((sel - 1))
                if [[ $idx -ge 0 && $idx -lt ${#entries[@]} ]]; then
                    local entry_name="${entries[$idx]}"
                    var="$(_wc_daemon_var "$entry_name")"
                    if [[ "${!var:-true}" == "true" ]]; then
                        printf -v "$var" '%s' "false"
                    else
                        printf -v "$var" '%s' "true"
                    fi
                    dirty=1
                fi
                ;;
            *)
                ;;
        esac
    done
}

# Load per-user config (overrides defaults set above) before autostart.
load_console_config

# Probe Docker reachability before we render the menu. Must stay fast but
# cannot silently flip the session to the wrong daemon: a slow-but-reachable
# ssh:// remote (high-latency VPN, just-waking desktop) could otherwise be
# misclassified as unreachable and trigger the in-process DOCKER_HOST unset.
# WTD_DOCKER_SKIP_FALLBACK=1 preserves DOCKER_HOST so subsequent
# refresh_docker_reachability_for_render calls can re-probe the user's
# original daemon once it answers. The 2s startup timeout keeps first paint
# snappy when Docker is genuinely offline.
_wc_prev_docker_skip_wake="${WTD_DOCKER_SKIP_WAKE:-}"
_wc_prev_docker_skip_fallback="${WTD_DOCKER_SKIP_FALLBACK:-}"
export WTD_DOCKER_SKIP_WAKE=1
export WTD_DOCKER_SKIP_FALLBACK=1
unset WTD_DOCKER_REACHABLE_CACHED
wtd_docker_reachable 2 >/dev/null 2>&1 || true
WC_DOCKER_LAST_REPROBE_AT="$(date +%s)"
if [[ -n "$_wc_prev_docker_skip_wake" ]]; then
    export WTD_DOCKER_SKIP_WAKE="$_wc_prev_docker_skip_wake"
else
    unset WTD_DOCKER_SKIP_WAKE
fi
if [[ -n "$_wc_prev_docker_skip_fallback" ]]; then
    export WTD_DOCKER_SKIP_FALLBACK="$_wc_prev_docker_skip_fallback"
else
    unset WTD_DOCKER_SKIP_FALLBACK
fi
unset _wc_prev_docker_skip_wake _wc_prev_docker_skip_fallback

# Auto-start enabled daemons (idempotent — skips already-running)
_wc_autostart=""
for _wc_d in $DAEMON_NAMES; do
    is_daemon_enabled "$_wc_d" && _wc_autostart+="${_wc_autostart:+ }$_wc_d"
done
if [[ -n "$_wc_autostart" ]]; then
    _daemon_start_named_set "$_wc_autostart"
fi
unset _wc_autostart _wc_d

# Run
if [[ -n "$JUMP_TO" ]]; then
    matched_path=$(find_worktree_by_name "$JUMP_TO") || {
        echo -e "${RED}No worktree found matching '${JUMP_TO}'${NC}"
        echo "Available worktrees:"
        git -C "$MAIN_REPO" worktree list 2>/dev/null | while IFS= read -r line; do
            p=$(echo "$line" | awk '{print $1}')
            echo "  $(short_name "$p")"
        done
        exit 1
    }
    worktree_menu "$matched_path"
fi
main_menu
