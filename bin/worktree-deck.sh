#!/usr/bin/env bash
# worktree-deck — Manage git worktrees and their dev stacks
# Usage: worktree-deck [--codex|--claude] [name]
#   name - optional worktree name (short or full branch) to jump directly to
set -euo pipefail

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

# Derive display name from branch (strips known type prefixes)
short_name() {
    local worktree_path="$1"
    local branch=$(cd "$worktree_path" && git branch --show-current 2>/dev/null || echo "")
    if [[ -z "$branch" || "$branch" == "main" || "$branch" == "master" ]]; then
        echo "main"
    else
        # Strip known type prefixes only
        echo "$branch" | sed -E 's#^(feature|fix|chore|hotfix|release)/##; s#/#-#g'
    fi
}

# Print header with current worktree context
header() {
    clear
    echo -e "${BOLD}${CYAN}╔═══════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║                🌳 worktree-deck                ║${NC}"
    echo -e "${BOLD}${CYAN}╚═══════════════════════════════════════════════╝${NC}"

    local cur_name=$(short_name "$MAIN_REPO")
    local cur_slot=$(get_slot_info "$MAIN_REPO")
    local cur_ports=$(get_port_info "$MAIN_REPO")
    local raw_status=$(get_container_status "$MAIN_REPO")
    local status_display
    if [[ "$raw_status" == *"Running"* ]]; then
        status_display="${GREEN}● up${NC}"
    elif [[ "$raw_status" == *"Unknown"* ]]; then
        status_display="${YELLOW}? unknown${NC}"
    else
        status_display="${RED}○ down${NC}"
    fi

    echo -e "  ${BOLD}Current:${NC} ${CYAN}${cur_name}${NC}  ${status_display}  slot ${cur_slot}  ${cur_ports}"
    print_daemon_indicator
    # Configured background daemons (WTD_DAEMONS), if any.
    for _d in $DAEMON_NAMES; do
        is_daemon_enabled "$_d" || continue
        daemon_status_line "$_d"
    done
    echo
}

# Compute the per-worktree container-name suffix the same way worktree-env.sh
# Per-worktree container suffix + service names come from lib/config.sh hooks.
# Returns the empty string for the main repo on main/master.
# Per-worktree container suffix + service names are config-driven (lib/config.sh).
worktree_suffix() { wtd_branch_tag "$1"; }
worktree_service_names() { wtd_service_names "$1"; }

# If the cached Docker probe says "no", re-probe with a fast non-waking,
# no-fallback call so the console recovers when Docker comes back during a
# session. Stays cheap when the cache is "yes" or unset — we only pay the
# probe cost when we already believe Docker is down.
refresh_docker_reachability_for_render() {
    [[ "${WTD_DOCKER_REACHABLE_CACHED:-}" == "no" ]] || return 0
    local _now
    _now=$(date +%s)
    if [[ "${WC_DOCKER_LAST_REPROBE_AT:-0}" -gt 0 ]] \
       && (( _now - WC_DOCKER_LAST_REPROBE_AT < WC_DOCKER_REPROBE_INTERVAL_SECONDS )); then
        return 0
    fi
    unset WTD_DOCKER_REACHABLE_CACHED
    local _prev_skip_wake="${WTD_DOCKER_SKIP_WAKE:-}"
    local _prev_skip_fallback="${WTD_DOCKER_SKIP_FALLBACK:-}"
    export WTD_DOCKER_SKIP_WAKE=1
    export WTD_DOCKER_SKIP_FALLBACK=1
    wtd_docker_reachable 2 >/dev/null 2>&1 || true
    WC_DOCKER_LAST_REPROBE_AT="$_now"
    if [[ -n "$_prev_skip_wake" ]]; then
        export WTD_DOCKER_SKIP_WAKE="$_prev_skip_wake"
    else
        unset WTD_DOCKER_SKIP_WAKE
    fi
    if [[ -n "$_prev_skip_fallback" ]]; then
        export WTD_DOCKER_SKIP_FALLBACK="$_prev_skip_fallback"
    else
        unset WTD_DOCKER_SKIP_FALLBACK
    fi
}

service_names_running_in_snapshot() {
    local names="$1"
    local snapshot="$2"
    local service_name
    [[ -n "$snapshot" ]] || return 1
    while IFS= read -r service_name; do
        [[ -z "$service_name" ]] && continue
        if printf '%s\n' "$snapshot" | grep -qFx "$service_name"; then
            return 0
        fi
    done <<< "$names"
    return 1
}

# Get container status for a worktree
get_container_status() {
    local worktree_path="$1"
    local service_names
    service_names="$(worktree_service_names "$worktree_path")"

    refresh_docker_reachability_for_render

    # Pick the daemon to query for status. Prefer the configured one when it's
    # reachable; otherwise fall back to the local daemon, where worktree stacks
    # run when the configured remote is offline. The local probe is cheap (unix
    # socket, fails fast) — only report "Docker unavailable" when neither answers.
    local _query_host
    if [[ "${WTD_DOCKER_REACHABLE_CACHED:-}" != "no" ]]; then
        _query_host="${DOCKER_HOST:-}"
    elif DOCKER_HOST= docker ps --format '{{.Names}}' >/dev/null 2>&1; then
        _query_host=""
    else
        echo -e "${RED}○${NC} Stopped (Docker unavailable)"
        return
    fi

    # Check if any worktree service containers are running. This function is
    # intentionally simple for ad hoc callers; list_worktrees uses a cached
    # docker ps snapshot to avoid 4 docker calls per row.
    local service_name
    while IFS= read -r service_name; do
        [[ -z "$service_name" ]] && continue
        if DOCKER_HOST="$_query_host" docker ps --filter "name=^${service_name}$" --format "{{.Names}}" 2>/dev/null | grep -qFx "$service_name"; then
            echo -e "${GREEN}●${NC} Running"
            return
        fi
    done <<< "$service_names"

    echo -e "${RED}○${NC} Stopped"
}

# Get port info for a worktree
get_port_info() {
    local worktree_path="$1"

    if [[ -f "$worktree_path/.env" ]]; then
        local backend_port=$(grep "^${WTD_BACKEND_PORT_KEY}=" "$worktree_path/.env" 2>/dev/null | cut -d= -f2)
        local frontend_port=$(grep "^${WTD_FRONTEND_PORT_KEY}=" "$worktree_path/.env" 2>/dev/null | cut -d= -f2)
        if [[ -n "$backend_port" ]]; then
            echo "B:${backend_port} F:${frontend_port}"
        else
            echo "-"
        fi
    else
        echo "-"
    fi
}

# Get slot number for a worktree
get_slot_info() {
    local worktree_path="$1"
    if [[ -f "$worktree_path/.env" ]]; then
        local slot=$(grep "^${WTD_SLOT_ENV_KEY}=" "$worktree_path/.env" 2>/dev/null | cut -d= -f2)
        echo "${slot:--}"
    else
        echo "-"
    fi
}

# Refresh PR metadata cache from GitHub.
refresh_pr_data() {
    PR_DATA=""
    PR_DATA_AVAILABLE=0

    if ! command -v gh &>/dev/null; then
        return
    fi

    # Don't gate on `gh auth status`; environments with GH_TOKEN may fail status
    # but still allow successful `gh pr list`.
    local pr_data
    if pr_data=$(cd "$MAIN_REPO" && gh pr list --state all --limit 500 --json number,state,headRefName,headRefOid --template '{{range .}}{{.headRefName}}{{"\t"}}{{.number}}{{"\t"}}{{.state}}{{"\t"}}{{.headRefOid}}{{"\n"}}{{end}}' 2>/dev/null); then
        PR_DATA_AVAILABLE=1
        PR_DATA="$pr_data"
    fi
}

# Get PR info for a branch as: "#123 open|closed|merged"
get_pr_info() {
    local branch="$1"

    if [[ -z "$branch" || "$branch" == "detached" || "${PR_DATA_AVAILABLE:-0}" -ne 1 ]]; then
        echo "-"
        return
    fi

    local pr_match
    pr_match=$(awk -F '\t' -v b="$branch" '
        $1==b {
            if ($3=="OPEN") {
                print $2 "\t" $3
                found=1
                exit
            }
            if ($3=="MERGED" && merged=="") {
                merged=$2 "\t" $3
            }
            if ($3=="CLOSED" && closed=="") {
                closed=$2 "\t" $3
            }
        }
        END {
            if (!found) {
                if (merged!="") {
                    print merged
                } else if (closed!="") {
                    print closed
                }
            }
        }
    ' <<< "$PR_DATA")

    if [[ -z "$pr_match" ]]; then
        echo "-"
        return
    fi

    local number="${pr_match%%$'\t'*}"
    local state="${pr_match#*$'\t'}"

    case "$state" in
        OPEN)
            echo -e "#${number} ${GREEN}open${NC}"
            ;;
        CLOSED)
            echo -e "#${number} ${RED}closed${NC}"
            ;;
        MERGED)
            echo -e "#${number} ${YELLOW}merged${NC}"
            ;;
        *)
            echo "#${number} $(echo "$state" | tr '[:upper:]' '[:lower:]')"
            ;;
    esac
}

# Get PR state for a branch as: open|merged|closed|none
get_pr_state() {
    local branch="$1"

    if [[ -z "$branch" || "$branch" == "detached" || "${PR_DATA_AVAILABLE:-0}" -ne 1 ]]; then
        echo "none"
        return
    fi

    local state
    state=$(awk -F '\t' -v b="$branch" '
        $1==b {
            if ($3=="OPEN") {
                print "open"
                found=1
                exit
            }
            if ($3=="MERGED" && merged=="") {
                merged="merged"
            }
            if ($3=="CLOSED" && closed=="") {
                closed="closed"
            }
        }
        END {
            if (!found) {
                if (merged!="") {
                    print merged
                } else if (closed!="") {
                    print closed
                }
            }
        }
    ' <<< "$PR_DATA")

    echo "${state:-none}"
}

# Get merged PR head SHA for a branch (if available), empty when unknown.
get_pr_merged_head_oid() {
    local branch="$1"

    if [[ -z "$branch" || "$branch" == "detached" || "${PR_DATA_AVAILABLE:-0}" -ne 1 ]]; then
        echo ""
        return
    fi

    local merged_oid
    merged_oid=$(awk -F '\t' -v b="$branch" '
        $1==b && $3=="MERGED" && $4!="" {
            print $4
            exit
        }
    ' <<< "$PR_DATA")

    echo "${merged_oid:-}"
}

# List all worktrees with status
list_worktrees() {
    refresh_pr_data

    # Recover from a stale "Docker unavailable" cache: if the startup probe
    # failed (e.g. desktop was waking up), re-probe here so the row status,
    # cleanup summary, and orphan detection can come back without a restart.
    refresh_docker_reachability_for_render

    # Snapshot container names on both daemons once so each row can show
    # whether its stack is on local Colima (💻) or the remote daemon (🖥).
    #
    # The local daemon is ALWAYS snapshotted: it's cheap (unix socket, fails
    # fast — never the ssh ~30s connect hang) and is where worktree stacks run
    # when the configured remote is offline. Status must keep resolving against
    # local even when DOCKER_HOST points at a dead remote, otherwise every row
    # collapses to "?" while the stacks are healthy on Colima. The configured
    # remote is queried only when its reachability cache says it's up, so we
    # never wedge on an offline ssh:// daemon's connect timeout.
    local _local_ps="" _remote_ps="" _docker_status_available=0 _local_ok=0
    if _local_ps=$(DOCKER_HOST= docker ps --format '{{.Names}}' 2>/dev/null); then
        _local_ok=1
        _docker_status_available=1
    else
        _local_ps=""
    fi
    if [[ "${WTD_DOCKER_REACHABLE_CACHED:-}" != "no" ]]; then
        _docker_status_available=1
        case "${DOCKER_HOST:-}" in
            ""|unix://*) ;;
            *) _remote_ps=$(docker ps --format '{{.Names}}' 2>/dev/null || true) ;;
        esac
    fi
    # When the configured remote is unreachable but local answered, status is
    # being read off the local daemon — say so once so a screen full of local
    # stacks under a remote DOCKER_HOST isn't mistaken for the remote's state.
    local _status_from_local_fallback=0
    case "${DOCKER_HOST:-}" in
        ""|unix://*) ;;
        *) [[ "${WTD_DOCKER_REACHABLE_CACHED:-}" == "no" && "$_local_ok" -eq 1 ]] \
            && _status_from_local_fallback=1 ;;
    esac
    # Daemon the dead/orphan sweep below should target. When we fell back to
    # local for status, the sweep must hit local too — a bare `docker ps -a`
    # against the offline remote would wedge on the ssh connect timeout.
    local _sweep_host="${DOCKER_HOST:-}"
    [[ "$_status_from_local_fallback" -eq 1 ]] && _sweep_host=""
    # Expose the resolved sweep host so the [Y] dead-container cleanup action
    # (remove_dead_containers, dispatched from the menu loop after this render)
    # targets the SAME daemon the summary below counted. The console preserves
    # DOCKER_HOST even when the remote is offline (WTD_DOCKER_SKIP_FALLBACK=1),
    # so without this a local-fallback summary would advertise local dead
    # containers while [Y]'s bare `docker rm` hit the unreachable remote —
    # wedging on the ssh connect timeout or removing nothing.
    declare -g CONTAINER_SWEEP_HOST="$_sweep_host"

    echo -e "${BOLD}Worktrees:${NC}"
    if [[ "$_status_from_local_fallback" -eq 1 ]]; then
        echo -e "  ${YELLOW}Configured remote DOCKER_HOST unreachable — STATUS shown from local daemon.${NC}"
    fi
    echo -e "${CYAN}──────────────────────────────────────────────────────────────────────────${NC}"
    printf "  %-4s %-22s %-3s %-8s%-5s %-14s %s\n" "#" "NAME" "ON" "STATUS" "SLOT" "PORTS" "PR"
    echo -e "${CYAN}──────────────────────────────────────────────────────────────────────────${NC}"

    local i=1
    declare -g -a WORKTREE_PATHS=()

    while IFS= read -r line; do
        local path=$(echo "$line" | awk '{print $1}')
        local branch=$(echo "$line" | awk '{print $3}' | tr -d '[]')

        WORKTREE_PATHS+=("$path")

        local display_name=$(short_name "$path")
        local slot=$(get_slot_info "$path")
        local ports=$(get_port_info "$path")
        local pr=$(get_pr_info "$branch")
        local service_names
        service_names="$(worktree_service_names "$path")"

        # Truncate name (max 26 visible chars, leaves 2 chars padding before dot)
        [[ ${#display_name} -gt 26 ]] && display_name="${display_name:0:23}..."

        # Status dot
        local dot dot_color
        if [[ "$_docker_status_available" -eq 0 ]]; then
            dot="?"; dot_color="$YELLOW"
        elif service_names_running_in_snapshot "$service_names" "$_local_ps" \
            || service_names_running_in_snapshot "$service_names" "$_remote_ps"; then
            dot="●"; dot_color="$GREEN"
        else
            dot="○"; dot_color="$RED"
        fi

        # Which daemon hosts this worktree's stack right now? Check the
        # backend container name against the cached ps snapshots; show 🖥
        # for remote, 💻 for local, blank if not running anywhere.
        local _backend_name
        _backend_name="$(head -n1 <<< "$service_names")"
        local where_icon="  "
        if [[ -n "$_remote_ps" ]] && printf '%s\n' "$_remote_ps" | grep -qFx "$_backend_name"; then
            where_icon="🖥 "
        elif printf '%s\n' "$_local_ps" | grep -qFx "$_backend_name"; then
            where_icon="💻"
        fi

        # Current worktree marker
        local marker=" "
        [[ "$path" == "$MAIN_REPO" ]] && marker="*"

        # Pad plain text first, apply ANSI color after (prevents alignment drift)
        local pname=$(printf "%-28s" "$display_name")
        local pslot=$(printf "%-5s" "$slot")
        local pports=$(printf "%-14s" "$ports")

        echo -e "${marker} $(printf "%-3s" "$i") ${CYAN}${pname}${NC}${where_icon} ${dot_color}${dot}${NC}   ${pslot} ${pports} ${pr}"
        ((i++))
    done < <(git -C "$MAIN_REPO" worktree list 2>/dev/null)

    echo -e "${CYAN}──────────────────────────────────────────────────────────────────────────${NC}"

    # Dead container / orphan summary
    local dead_count=0
    local dead_names=""
    local orphan_names=""
    local all_suffixes=""

    # Collect expected container names per worktree. Read .env first (most
    # accurate — survives branch rename), then fall back to branch-derived
    # suffix so legacy worktrees without .env are still covered.
    all_suffixes=" "
    for path in "${WORKTREE_PATHS[@]}"; do
        # Only trust .env when it was generated for the worktree's current
        # branch — a stale .env (branch changed since it was written) would
        # otherwise shield orphans from the sweep.
        # Expected container names for this worktree come from the config hook.
        local _svc
        while IFS= read -r _svc; do
            [[ -n "$_svc" ]] && all_suffixes+="$_svc "
        done < <(wtd_service_names "$path")
    done

    local orphan_count=0
    if [[ "$_docker_status_available" -eq 1 ]]; then
        # Count dead containers
        while IFS= read -r cname; do
            [[ -z "$cname" ]] && continue
            dead_count=$((dead_count + 1))
            dead_names+="    ${RED}○${NC} ${cname}\n"
        done < <(DOCKER_HOST="$_sweep_host" docker ps -a \
            --filter "name=^${WTD_CONTAINER_PREFIX}" \
            --filter "status=created" \
            --filter "status=exited" \
            --filter "status=dead" \
            --format "{{.Names}}" 2>/dev/null || true)

        # Find orphan containers (running project containers not matching any worktree)
        while IFS= read -r cname; do
            [[ -z "$cname" ]] && continue
            # Skip configured shared infra
            local _shared _skip=0
            for _shared in ${WTD_SHARED_CONTAINERS:-}; do
                [[ "$cname" == "$_shared" ]] && { _skip=1; break; }
            done
            [[ "$_skip" -eq 1 ]] && continue
            # Check if this container matches any known worktree
            if [[ " $all_suffixes " != *" $cname "* ]]; then
                orphan_count=$((orphan_count + 1))
                orphan_names+="    ${YELLOW}?${NC} ${cname}\n"
            fi
        done < <(DOCKER_HOST="$_sweep_host" docker ps --filter "name=^${WTD_CONTAINER_PREFIX}" --format "{{.Names}}" 2>/dev/null || true)
    else
        echo
        echo -e "  ${YELLOW}Skipping Docker container cleanup summary; Docker daemon unavailable.${NC}"
    fi

    if [[ "$dead_count" -gt 0 || "$orphan_count" -gt 0 ]]; then
        echo
        if [[ "$dead_count" -gt 0 ]]; then
            echo -e "  ${RED}${dead_count} dead container(s)${NC} — press ${YELLOW}[Y]${NC} to clean up"
            echo -e "$dead_names"
        fi
        if [[ "$orphan_count" -gt 0 ]]; then
            echo -e "  ${YELLOW}${orphan_count} orphan container(s)${NC} (no matching worktree) — press ${YELLOW}[O]${NC} to remove"
            echo -e "$orphan_names"
        fi
    fi
    echo
}

# Start the dev stack for a worktree (config-driven; no-op when stackless).
start_worktree() {
    local path="$1"
    if ! wtd_has_stack; then echo -e "${YELLOW}No dev stack configured (set WTD_STACK_START).${NC}"; return; fi
    echo -e "${BLUE}Starting stack for ${BOLD}$(basename "$path")${NC}..."
    wtd_stack_start "$path"
    echo -e "${GREEN}✓ Started!${NC}"
}

# Stop the dev stack for a worktree.
stop_worktree() {
    local path="$1"
    if ! wtd_has_stack; then echo -e "${YELLOW}No dev stack configured (set WTD_STACK_STOP).${NC}"; return; fi
    echo -e "${YELLOW}Stopping stack for ${BOLD}$(basename "$path")${NC}..."
    wtd_stack_stop "$path"
    echo -e "${GREEN}✓ Stopped!${NC}"
}

# Restart the dev stack for a worktree.
restart_worktree() {
    local path="$1"
    if ! wtd_has_stack; then echo -e "${YELLOW}No dev stack configured.${NC}"; return; fi
    echo -e "${YELLOW}Restarting stack for ${BOLD}$(basename "$path")${NC}..."
    wtd_stack_restart "$path"
    echo -e "${GREEN}✓ Restarted!${NC}"
}

# Create a new worktree
create_worktree() {
    echo -e "${BOLD}Create New Worktree${NC}"
    echo -e "${CYAN}──────────────────────────────────────────────────────────────────${NC}"

    read -p "Task/feature name (e.g., 'add-login'): " task_name
    if [[ -z "$task_name" ]]; then
        echo -e "${RED}Error: Task name required${NC}"
        return 1
    fi
    if ! bash "$LIB_DIR/validate-worktree-name.sh" "$task_name"; then
        return 1
    fi

    read -p "Base branch [origin/main]: " base_branch
    base_branch="${base_branch:-origin/main}"

    local branch_name="${task_name}"
    local worktree_path="${WORKTREES_DIR}/${task_name}"

    echo
    echo -e "Creating worktree:"
    echo -e "  Path:   ${CYAN}${worktree_path}${NC}"
    echo -e "  Branch: ${CYAN}${branch_name}${NC}"
    echo -e "  Base:   ${CYAN}${base_branch}${NC}"
    echo

    read -p "Proceed? (y/n) [y]: " confirm
    confirm="${confirm:-y}"

    if [[ "$confirm" != "y" ]]; then
        echo "Cancelled."
        return 0
    fi

    # Create directory if needed
    mkdir -p "$WORKTREES_DIR"

    # Refresh selected base ref before creating worktree.
    local fetch_remote="origin"
    local fetch_ref="$base_branch"
    if [[ "$base_branch" == */* ]]; then
        fetch_remote="${base_branch%%/*}"
        fetch_ref="${base_branch#*/}"
    fi
    echo -e "${BLUE}Refreshing from ${fetch_remote}/${fetch_ref}...${NC}"
    git -C "$MAIN_REPO" fetch "$fetch_remote" "$fetch_ref"
    git -C "$MAIN_REPO" worktree add -b "$branch_name" "$worktree_path" "$base_branch"

    # Push branch to remote and set correct upstream tracking.
    # Without this, the branch tracks origin/main and pushes go to main.
    echo -e "${BLUE}Pushing branch to remote...${NC}"
    git -C "$worktree_path" push -u origin "$branch_name" 2>/dev/null || {
        # If push fails (e.g. offline), at least unset the wrong upstream
        git -C "$worktree_path" branch --unset-upstream 2>/dev/null || true
        echo -e "${YELLOW}⚠ Could not push to remote. Upstream unset to prevent accidental pushes to main.${NC}"
        echo -e "${YELLOW}  Run 'git push -u origin ${branch_name}' when ready.${NC}"
    }
    echo
    echo -e "${GREEN}✓ Worktree created!${NC}"

    # Immediately navigate into the new worktree's action menu
    worktree_menu "$worktree_path"
}

# Remove a worktree
# Args: path [pre_confirm]
remove_worktree() {
    local path="$1"
    local pre_confirm="${2:-}"
    local name=$(basename "$path")

    if [[ "$path" == "$MAIN_REPO" ]]; then
        echo -e "${RED}Cannot remove the main repository!${NC}"
        return 1
    fi

    echo -e "${YELLOW}Warning: This will remove worktree '${name}'${NC}"

    local confirm
    if [[ -n "$pre_confirm" ]]; then
        confirm="$pre_confirm"
        echo -e "Are you sure? (y/n) [n]: ${confirm} ${YELLOW}(quick)${NC}"
    else
        read -p "Are you sure? (y/n) [n]: " confirm
    fi

    if [[ "$confirm" != "y" ]]; then
        echo "Cancelled."
        return 0
    fi

    # Stop containers first
    echo "Stopping containers..."
    wtd_stack_stop "$path" 2>/dev/null || true

    # Clear any stale worktree lock (e.g., dead claude-agent) before remove.
    # Returns non-zero only when a *live* process holds the lock — caller skips.
    if ! clear_stale_worktree_lock "$path" "$name"; then
        echo -e "${RED}✗ Skipped '${name}' — locked by a live process.${NC}"
        return 1
    fi

    # Remove worktree (explicit status handling keeps bulk-delete robust under set -e)
    if git -C "$MAIN_REPO" worktree remove --force "$path"; then
        echo -e "${GREEN}✓ Worktree removed!${NC}"
        return 0
    fi

    echo -e "${RED}✗ Failed to remove worktree '${name}'.${NC}"
    return 1
}

# If a worktree has a stale lock file (e.g., from a dead claude-agent process),
# clear it so subsequent `git worktree remove` can proceed. If the locking PID
# is still alive, leave the lock in place and return non-zero.
clear_stale_worktree_lock() {
    local path="$1"
    local name="$2"

    # Resolve the per-worktree gitdir: .git file -> gitdir: line, with a
    # fallback to <git-common-dir>/worktrees/<name> if the .git pointer is
    # missing or unreadable.
    local gitdir=""
    if [[ -f "$path/.git" ]]; then
        gitdir="$(awk -F': *' '/^gitdir:/{print $2; exit}' "$path/.git" 2>/dev/null)"
    fi
    if [[ -z "$gitdir" || ! -d "$gitdir" ]]; then
        local common_dir
        common_dir="$(git -C "$MAIN_REPO" rev-parse --git-common-dir 2>/dev/null)"
        if [[ -n "$common_dir" ]]; then
            [[ "$common_dir" != /* ]] && common_dir="$MAIN_REPO/$common_dir"
            gitdir="${common_dir}/worktrees/${name}"
        fi
    fi

    local lockfile="${gitdir}/locked"
    [[ -f "$lockfile" ]] || return 0

    local lock_reason pid
    lock_reason="$(tr -d '\n' < "$lockfile" 2>/dev/null)"
    pid="$(printf '%s' "$lock_reason" | grep -oE 'pid [0-9]+' | head -1 | awk '{print $2}')"

    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        echo -e "${YELLOW}Worktree '${name}' is locked by live process pid ${pid}: ${lock_reason}${NC}"
        echo -e "${YELLOW}Stop that process or unlock manually:${NC}"
        echo -e "  git -C \"${MAIN_REPO}\" worktree unlock \"${path}\""
        return 1
    fi

    echo -e "${YELLOW}Clearing stale worktree lock on '${name}': ${lock_reason}${NC}"
    git -C "$MAIN_REPO" worktree unlock "$path" 2>/dev/null || rm -f "$lockfile" 2>/dev/null || true
    return 0
}

# Get epoch timestamp of last commit on a branch (0 if unknown)
# Args: branch [repo_path]
branch_last_commit_epoch() {
    local branch="$1"
    local repo="${2:-$MAIN_REPO}"
    git -C "$repo" log -1 --format=%ct "$branch" 2>/dev/null || echo "0"
}

# Check whether a branch is merged into main/origin-main
# Args: branch
branch_is_merged_to_main() {
    local branch="$1"

    if [[ -z "$branch" || "$branch" == "main" || "$branch" == "master" || "$branch" == "detached" ]]; then
        return 1
    fi

    if ! git -C "$MAIN_REPO" rev-parse --verify "$branch" >/dev/null 2>&1; then
        return 1
    fi

    local target_ref="main"
    if git -C "$MAIN_REPO" rev-parse --verify "origin/main" >/dev/null 2>&1; then
        target_ref="origin/main"
    fi

    # Find the fork point (where branch diverged from main)
    local fork_point
    fork_point=$(git -C "$MAIN_REPO" merge-base "$branch" "$target_ref" 2>/dev/null) || return 1

    # Check if branch has any commits beyond the fork point
    # If no commits after fork, the branch never diverged - not "merged"
    local commit_count
    commit_count=$(git -C "$MAIN_REPO" rev-list --count "$fork_point..$branch" 2>/dev/null) || return 1
    if [[ "$commit_count" -eq 0 ]]; then
        return 1
    fi

    # Branch has work - check if it's been incorporated into main
    git -C "$MAIN_REPO" merge-base --is-ancestor "$branch" "$target_ref" >/dev/null 2>&1
}

# Bulk remove stale worktrees (merged, closed PRs, stale orphans)
remove_stale_worktrees() {
    refresh_pr_data

    local now_epoch
    now_epoch=$(date +%s)
    local AGENT_STALE_DAYS=3
    local OTHER_STALE_DAYS=7
    local agent_stale_secs=$((AGENT_STALE_DAYS * 86400))
    local other_stale_secs=$((OTHER_STALE_DAYS * 86400))

    local git_paths=()
    local git_meta=()
    local pr_paths=()
    local pr_meta=()
    local closed_paths=()
    local closed_meta=()
    local orphan_paths=()
    local orphan_meta=()
    local skipped_pr_stale_meta=()
    local skipped_active_meta=()

    # Collect active session dirs (Claude Code, Codex, or any shell cd'd into a
    # worktree). Matches scripts/cleanup-merged-worktrees.sh's protection set so
    # the TUI bulk-remove won't reap worktrees with an open terminal or agent.
    local active_dirs=()
    local pid
    while IFS= read -r pid; do
        local cwd
        cwd="$(lsof -p "$pid" -a -d cwd -Fn 2>/dev/null | grep '^n' | sed 's/^n//' || true)"
        [[ -n "$cwd" ]] && active_dirs+=("$cwd")
    done < <(pgrep -x 'claude|codex|zsh|bash|fish' 2>/dev/null || true)

    _has_active_session() {
        local target="$1"
        local d
        for d in "${active_dirs[@]}"; do
            if [[ "$d" == "$target" || "$d" == "$target/"* ]]; then
                return 0
            fi
        done
        return 1
    }

    for path in "${WORKTREE_PATHS[@]}"; do
        [[ "$path" == "$MAIN_REPO" ]] && continue

        local name branch pr_state reason
        name=$(basename "$path")
        branch=$(cd "$path" && git branch --show-current 2>/dev/null || true); branch="${branch:-detached}"
        pr_state=$(get_pr_state "$branch")
        reason=""

        # If the branch was not found in the cached PR list (capped at 500),
        # do a per-branch lookup so we don't mistakenly treat it as an orphan.
        if [[ "$pr_state" == "none" && "$branch" != "detached" ]] && command -v gh &>/dev/null; then
            local branch_pr
            branch_pr="$(cd "$MAIN_REPO" && gh pr list --head "$branch" --state all --limit 1 \
                --json number,state \
                --template '{{range .}}{{.state}}{{end}}' 2>/dev/null || true)"
            if [[ -n "$branch_pr" ]]; then
                pr_state=$(echo "$branch_pr" | tr '[:upper:]' '[:lower:]')
            fi
        fi

        # Skip current worktree
        [[ "$path" == "$(pwd)" ]] && continue

        # Detect active sessions (shell or agent with cwd inside the worktree).
        # We DON'T skip outright here: merged/closed PR worktrees are reaped
        # regardless because the user explicitly invoked bulk-delete and the
        # branch is "done work". Only orphan branches (no PR yet) are
        # protected, since those may be in-flight work.
        local has_active=0
        if _has_active_session "$path"; then
            has_active=1
        fi
        local active_tag=""
        [[ "$has_active" -eq 1 ]] && active_tag=" active-session"

        # --- Category 1: Merged PRs ---
        local merged_by_git=0
        local merged_by_pr=0

        if branch_is_merged_to_main "$branch"; then
            merged_by_git=1
        fi
        if [[ "$pr_state" == "merged" ]]; then
            merged_by_pr=1
        fi

        # Git ancestry is high-confidence.
        if [[ "$merged_by_git" -eq 1 ]]; then
            if [[ "$merged_by_pr" -eq 1 ]]; then
                reason="git+pr"
            else
                reason="git"
            fi
            git_paths+=("$path")
            git_meta+=("${name}|${branch}|${reason}${active_tag}")
            continue
        fi

        # PR-only path: require branch tip to match merged PR head SHA.
        if [[ "$merged_by_pr" -eq 1 ]]; then
            local branch_tip_oid merged_pr_oid
            branch_tip_oid=$(git -C "$path" rev-parse "$branch" 2>/dev/null || echo "")
            merged_pr_oid=$(get_pr_merged_head_oid "$branch")

            if [[ -n "$branch_tip_oid" && -n "$merged_pr_oid" && "$branch_tip_oid" == "$merged_pr_oid" ]]; then
                reason="pr"
                pr_paths+=("$path")
                pr_meta+=("${name}|${branch}|${reason}${active_tag}")
            else
                skipped_pr_stale_meta+=("${name}|${branch}|${branch_tip_oid}|${merged_pr_oid}")
            fi
            continue
        fi

        # --- Category 2: Closed PRs (not merged) ---
        if [[ "$pr_state" == "closed" ]]; then
            closed_paths+=("$path")
            closed_meta+=("${name}|${branch}|closed${active_tag}")
            continue
        fi

        # --- Category 3: Stale orphans (no PR, old commits or no work done) ---
        if [[ "$pr_state" == "none" && "$branch" != "main" && "$branch" != "master" && "$branch" != "detached" ]]; then
            # Active-session guard applies only to orphans: branches without
            # a PR may still be in-flight work, so don't reap them out from
            # under an open shell.
            if [[ "$has_active" -eq 1 ]]; then
                skipped_active_meta+=("${name}|${branch}|orphan with active session")
                continue
            fi

            # Check if branch has any commits beyond its fork from main.
            # If zero commits diverged, the branch was never worked on — always stale.
            local target_ref="main"
            if git -C "$MAIN_REPO" rev-parse --verify "origin/main" >/dev/null 2>&1; then
                target_ref="origin/main"
            fi
            local fork_point
            fork_point=$(git -C "$MAIN_REPO" merge-base "$branch" "$target_ref" 2>/dev/null || echo "")
            local commit_count=0
            if [[ -n "$fork_point" ]]; then
                commit_count=$(git -C "$MAIN_REPO" rev-list --count "$fork_point..$branch" 2>/dev/null || echo "0")
            fi

            if [[ "$commit_count" -eq 0 ]]; then
                # Skip if worktree has uncommitted local changes
                if [[ -d "$path" ]]; then
                    local wt_dirty
                    wt_dirty="$(git -C "$path" status --porcelain 2>/dev/null || true)"
                    if [[ -n "$wt_dirty" ]]; then
                        continue
                    fi
                fi

                # Require minimum 1-day age so fresh worktrees aren't reaped.
                # Use directory birth time (not commit timestamp) because
                # zero-commit branches point to a main commit whose date
                # reflects when main was updated, not when this worktree was created.
                local dir_birth
                if [[ "$(uname -s)" == "Darwin" ]]; then
                    dir_birth=$(stat -f '%B' "$path" 2>/dev/null || echo "0")
                else
                    dir_birth=$(stat -c '%W' "$path" 2>/dev/null || echo "0")
                fi
                if [[ "$dir_birth" == "0" || "$dir_birth" == "-1" ]]; then
                    dir_birth=$(branch_last_commit_epoch "$branch")
                fi
                local age_secs=$((now_epoch - dir_birth))
                if [[ "$age_secs" -lt 86400 ]]; then
                    continue
                fi

                orphan_paths+=("$path")
                orphan_meta+=("${name}|${branch}|no commits beyond main|empty branch")
            else
                # Branch has actual work — use age-based threshold
                local last_epoch
                last_epoch=$(branch_last_commit_epoch "$branch")
                local age_secs=$((now_epoch - last_epoch))
                local age_days=$((age_secs / 86400))

                local threshold_secs=$other_stale_secs
                local threshold_days=$OTHER_STALE_DAYS
                if [[ "$name" == worktree-agent-* || "$name" == agent-* || "$branch" == worktree-agent-* ]]; then
                    threshold_secs=$agent_stale_secs
                    threshold_days=$AGENT_STALE_DAYS
                fi

                if [[ "$age_secs" -ge "$threshold_secs" ]]; then
                    orphan_paths+=("$path")
                    orphan_meta+=("${name}|${branch}|${age_days}d old|>${threshold_days}d threshold")
                fi
            fi
        fi
    done

    local total_candidates=$((${#git_paths[@]} + ${#pr_paths[@]} + ${#closed_paths[@]} + ${#orphan_paths[@]}))

    if [[ "$total_candidates" -eq 0 ]]; then
        echo -e "${YELLOW}No stale worktrees found.${NC}"
        if [[ ${#skipped_pr_stale_meta[@]} -gt 0 ]]; then
            echo
            echo -e "${YELLOW}Skipped PR-merged branches with tip mismatch (not deleted):${NC}"
            local stale_item
            for stale_item in "${skipped_pr_stale_meta[@]}"; do
                local stale_name="${stale_item%%|*}"
                local stale_rest="${stale_item#*|}"
                local stale_branch="${stale_rest%%|*}"
                stale_rest="${stale_rest#*|}"
                local stale_tip="${stale_rest%%|*}"
                local stale_pr_head="${stale_rest##*|}"
                echo -e "  ${YELLOW}- ${stale_name}${NC} (${stale_branch}) [branch:${stale_tip:0:8} pr:${stale_pr_head:0:8}]"
            done
        fi
        if [[ ${#skipped_active_meta[@]} -gt 0 ]]; then
            echo
            echo -e "${YELLOW}Skipped orphans with active sessions (close the shell to reap):${NC}"
            local active_item
            for active_item in "${skipped_active_meta[@]}"; do
                local act_name="${active_item%%|*}"
                local act_rest="${active_item#*|}"
                local act_branch="${act_rest%%|*}"
                echo -e "  ${YELLOW}- ${act_name}${NC} (${act_branch})"
            done
        fi
        return 0
    fi

    echo -e "${BOLD}Stale worktrees to remove (${total_candidates}):${NC}"
    echo

    local item
    if [[ ${#git_paths[@]} -gt 0 ]]; then
        echo -e "${BOLD}Merged — git-verified (high confidence):${NC}"
        for item in "${git_meta[@]}"; do
            local item_name="${item%%|*}"
            local rest="${item#*|}"
            local item_branch="${rest%%|*}"
            local item_reason="${rest##*|}"
            echo -e "  ${YELLOW}- ${item_name}${NC} (${item_branch}) [${item_reason}]"
        done
    fi

    if [[ ${#pr_paths[@]} -gt 0 ]]; then
        echo -e "${BOLD}Merged — PR-only (squash/rebase):${NC}"
        for item in "${pr_meta[@]}"; do
            local item_name="${item%%|*}"
            local rest="${item#*|}"
            local item_branch="${rest%%|*}"
            local item_reason="${rest##*|}"
            echo -e "  ${YELLOW}- ${item_name}${NC} (${item_branch}) [${item_reason}]"
        done
    fi

    if [[ ${#closed_paths[@]} -gt 0 ]]; then
        echo -e "${BOLD}Closed PRs (not merged, branch abandoned):${NC}"
        for item in "${closed_meta[@]}"; do
            local item_name="${item%%|*}"
            local rest="${item#*|}"
            local item_branch="${rest%%|*}"
            echo -e "  ${RED}- ${item_name}${NC} (${item_branch})"
        done
    fi

    if [[ ${#orphan_paths[@]} -gt 0 ]]; then
        echo -e "${BOLD}Stale orphans (no PR, no recent commits):${NC}"
        for item in "${orphan_meta[@]}"; do
            local item_name="${item%%|*}"
            local rest="${item#*|}"
            local item_branch="${rest%%|*}"
            rest="${rest#*|}"
            local item_age="${rest%%|*}"
            local item_threshold="${rest##*|}"
            echo -e "  ${RED}- ${item_name}${NC} (${item_branch}) [${item_age}, ${item_threshold}]"
        done
    fi

    if [[ ${#skipped_pr_stale_meta[@]} -gt 0 ]]; then
        echo
        echo -e "${YELLOW}Skipped PR-merged branches with tip mismatch (not deleted):${NC}"
        local stale_item
        for stale_item in "${skipped_pr_stale_meta[@]}"; do
            local stale_name="${stale_item%%|*}"
            local stale_rest="${stale_item#*|}"
            local stale_branch="${stale_rest%%|*}"
            stale_rest="${stale_rest#*|}"
            local stale_tip="${stale_rest%%|*}"
            local stale_pr_head="${stale_rest##*|}"
            echo -e "  ${YELLOW}- ${stale_name}${NC} (${stale_branch}) [branch:${stale_tip:0:8} pr:${stale_pr_head:0:8}]"
        done
    fi

    if [[ ${#skipped_active_meta[@]} -gt 0 ]]; then
        echo
        echo -e "${YELLOW}Skipped orphans with active sessions (close the shell to reap):${NC}"
        local active_item
        for active_item in "${skipped_active_meta[@]}"; do
            local act_name="${active_item%%|*}"
            local act_rest="${active_item#*|}"
            local act_branch="${act_rest%%|*}"
            echo -e "  ${YELLOW}- ${act_name}${NC} (${act_branch})"
        done
    fi

    echo

    local confirm
    read -p "Remove all ${total_candidates} stale worktrees above? (y/n) [n]: " confirm
    confirm="${confirm:-n}"
    if [[ "$confirm" != "y" ]]; then
        echo "Cancelled."
        return 0
    fi

    local removed=0
    local failed=0
    local path

    for path in "${git_paths[@]}" "${pr_paths[@]}" "${closed_paths[@]}" "${orphan_paths[@]}"; do
        if remove_worktree "$path" "y"; then
            removed=$((removed + 1))
        else
            failed=$((failed + 1))
        fi
    done

    echo
    echo -e "${GREEN}Removed: ${removed}${NC}"
    if [[ "$failed" -gt 0 ]]; then
        echo -e "${RED}Failed: ${failed}${NC}"
    fi
}

# Tail the dev-stack container logs for a worktree.
show_logs() {
    local path="$1"
    local names
    names="$(wtd_service_names "$path")"
    if [[ -z "$names" ]]; then
        echo -e "${YELLOW}No dev-stack containers configured (set WTD_SERVICE_TEMPLATES).${NC}"
        read -p "Press Enter to continue..."
        return
    fi
    # Build a docker logs follow across whichever of the worktree's containers exist.
    local running=()
    local n
    while IFS= read -r n; do
        [[ -z "$n" ]] && continue
        docker ps --filter "name=^${n}$" --format '{{.Names}}' 2>/dev/null | grep -qFx "$n" && running+=("$n")
    done <<< "$names"
    if [[ ${#running[@]} -eq 0 ]]; then
        echo -e "${YELLOW}No running containers for this worktree.${NC}"
        read -p "Press Enter to continue..."
        return
    fi
    echo -e "${CYAN}Tailing logs (Ctrl-C to stop): ${running[*]}${NC}"
    docker logs -f --tail 100 "${running[0]}" 2>&1 || true
}

# Remove dead (exited/created/dead) project containers
remove_dead_containers() {
    _wtd_require_container_prefix || return 0
    # Target the same daemon the status summary counted dead containers on.
    # CONTAINER_SWEEP_HOST is set by the render path (empty = local daemon);
    # fall back to the ambient DOCKER_HOST if cleanup is ever invoked without
    # a prior render. Without this, a local-fallback summary (offline remote
    # DOCKER_HOST) would list local dead containers while these calls hit the
    # unreachable remote — hanging on the ssh timeout or removing nothing.
    local _host="${CONTAINER_SWEEP_HOST-${DOCKER_HOST:-}}"
    local stale
    stale=$(DOCKER_HOST="$_host" docker ps -a \
        --filter "name=^${WTD_CONTAINER_PREFIX}" \
        --filter "status=created" \
        --filter "status=exited" \
        --filter "status=dead" \
        --format "{{.Names}}\t{{.Status}}" 2>/dev/null || true)

    if [[ -z "$stale" ]]; then
        echo -e "${YELLOW}No dead project containers found.${NC}"
        return 0
    fi

    echo -e "${BOLD}Dead project containers:${NC}"
    while IFS=$'\t' read -r container status; do
        [[ -z "$container" ]] && continue
        echo -e "  ${RED}○${NC} ${container}  (${status})"
    done <<< "$stale"
    echo

    local removed=0
    while IFS=$'\t' read -r container status; do
        [[ -z "$container" ]] && continue
        DOCKER_HOST="$_host" docker rm "$container" >/dev/null 2>&1 || true
        echo -e "  ${GREEN}✓ Removed ${container}${NC}"
        removed=$((removed + 1))
    done <<< "$stale"

    echo -e "${GREEN}Removed ${removed} dead container(s).${NC}"
}

# Remove orphan project containers — delegates to cleanup-merged-worktrees.sh
# which treats each live worktree's .env as source of truth for container
# names. Anything else under name=^${WTD_CONTAINER_PREFIX} gets docker rm -f'd.
remove_orphan_containers() {
    _wtd_require_container_prefix || return 0
    # Target the same daemon the status summary counted orphans on, the same way
    # [Y]/[X] do. CONTAINER_SWEEP_HOST is set by the render path (empty = local
    # daemon); fall back to the ambient DOCKER_HOST if [O] is invoked without a
    # prior render.
    local _host="${CONTAINER_SWEEP_HOST-${DOCKER_HOST:-}}"
    echo -e "${BOLD}Sweeping orphan project containers...${NC}"
    echo
    # Clear the inherited reachability cache so the child re-probes the resolved
    # host. The console exports WTD_DOCKER_REACHABLE_CACHED=no when the
    # configured ssh:// remote is offline; cleanup-merged-worktrees.sh would
    # otherwise short-circuit on that cache, set SKIP_DOCKER, and `exit 0` before
    # its orphan-container sweep — leaving the very local orphans the summary
    # just listed under [O] untouched. Passing the resolved DOCKER_HOST too lets
    # the child probe local directly instead of wasting the ssh connect timeout
    # on the dead remote before falling back.
    # Optional deeper sweep hook (e.g. a project-specific merged-worktree reaper).
    if [[ -n "${WTD_ORPHAN_SWEEP_CMD:-}" ]]; then
        DOCKER_HOST="$_host" WTD_DOCKER_REACHABLE_CACHED= eval "$WTD_ORPHAN_SWEEP_CMD" || true
    fi
    echo
    echo -e "${GREEN}Orphan sweep complete.${NC}"
}

# Run e2e tests for a worktree
run_e2e_tests() {
    local path="$1"
    local test_file="${2:-}"
    local name=$(basename "$path")

    # Check if containers are running. get_container_status returns a status
    # containing "Stopped" both when containers are actually down and when
    # Docker itself is unreachable (we cannot verify containers either way) —
    # both block the e2e run so we never silently target a daemon we can't
    # talk to.
    local status=$(get_container_status "$path")
    if [[ "$status" == *"Docker unavailable"* ]]; then
        echo -e "${RED}Docker daemon unreachable for ${name}; cannot verify containers. Resolve Docker access and retry.${NC}"
        return 1
    fi
    if [[ "$status" == *"Stopped"* ]]; then
        echo -e "${RED}Containers not running for ${name}. Start them first.${NC}"
        return 1
    fi

    if [[ -z "$WTD_E2E_CMD" ]]; then
        echo -e "${YELLOW}No e2e command configured (set WTD_E2E_CMD).${NC}"
        return 0
    fi

    echo -e "${BOLD}Running e2e tests for ${CYAN}${name}${NC}..."
    echo -e "${CYAN}──────────────────────────────────────────────────────────────────${NC}"

    if [[ -n "$test_file" ]]; then
        echo -e "Test file: ${CYAN}${test_file}${NC}"
        (cd "$path" && TEST_FILE="$test_file" eval "$WTD_E2E_CMD")
    else
        (cd "$path" && eval "$WTD_E2E_CMD")
    fi
}

# Escape string content for use inside an AppleScript string literal.
escape_for_applescript() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '%s' "$value"
}

# Pick terminal app, preferring explicit override, then current shell host app.
resolve_terminal_app() {
    if [[ -n "${WTD_TERMINAL_APP:-}" ]]; then
        echo "$WTD_TERMINAL_APP"
        return
    fi

    case "${TERM_PROGRAM:-}" in
        iTerm.app)
            echo "iTerm2"
            ;;
        Apple_Terminal)
            echo "Terminal"
            ;;
        *)
            echo "Terminal"
            ;;
    esac
}

# Open a new terminal tab for a worktree and optionally run a CLI command.
# Prefers current terminal app; set WTD_TERMINAL_APP to override.
open_terminal_tab() {
    local path="$1"
    local cli_command="${2:-}"
    local terminal_app
    terminal_app="$(resolve_terminal_app)"
    local iterm_mode="${WTD_ITERM_OPEN_MODE:-split}"
    local shell_cmd="cd $(printf '%q' "$path") && export WTD_PROJECT_DIR=$(printf '%q' "$path")"
    # Optional per-worktree banner command (set WTD_BANNER_CMD in your config).
    if [[ -n "${WTD_BANNER_CMD:-}" ]]; then
        shell_cmd="${shell_cmd} && ${WTD_BANNER_CMD}"
    fi

    if [[ -n "$cli_command" ]]; then
        shell_cmd="${shell_cmd} && ${cli_command}"
    fi

    local escaped_cmd
    escaped_cmd="$(escape_for_applescript "$shell_cmd")"

    if [[ "$terminal_app" == "iTerm2" || "$terminal_app" == "iTerm" ]]; then
        if [[ "$iterm_mode" == "tab" ]]; then
            osascript \
                -e "tell application \"iTerm2\"" \
                -e "activate" \
                -e "if (count of windows) is 0 then" \
                -e "create window with default profile" \
                -e "else" \
                -e "tell current window to create tab with default profile" \
                -e "end if" \
                -e "tell current session of current window" \
                -e "write text \"$escaped_cmd\"" \
                -e "end tell" \
                -e "end tell" >/dev/null 2>&1
            return $?
        fi

        # Default: split vertically in the current tab using the current profile.
        osascript \
            -e "tell application \"iTerm2\"" \
            -e "activate" \
            -e "if (count of windows) is 0 then" \
            -e "create window with default profile" \
            -e "tell current session of current window" \
            -e "write text \"$escaped_cmd\"" \
            -e "end tell" \
            -e "else" \
            -e "tell current session of current tab of current window" \
            -e "set newSession to (split vertically with same profile)" \
            -e "end tell" \
            -e "tell newSession to write text \"$escaped_cmd\"" \
            -e "end if" \
            -e "end tell" >/dev/null 2>&1
        return $?
    fi

    osascript \
        -e "tell application \"Terminal\"" \
        -e "activate" \
        -e "if (count of windows) is 0 then" \
        -e "do script \"$escaped_cmd\"" \
        -e "else" \
        -e "do script \"$escaped_cmd\" in front window" \
        -e "end if" \
        -e "end tell" >/dev/null 2>&1
}

# Open terminal in worktree (new tab)
open_terminal() {
    local path="$1"
    echo -e "${BLUE}Opening terminal tab in ${BOLD}$(basename "$path")${NC}..."
    if ! open_terminal_tab "$path"; then
        echo -e "${RED}Failed to open terminal tab.${NC}"
        return 1
    fi
}

# Launch CLI inline from the current TUI session.
# Banner rendering is best-effort and must not block CLI startup.
launch_cli_inline() {
    local path="$1"
    local cli_command="$2"
    local label="$3"
    local launch_flag
    launch_flag="$(wtd_normalize_launch_flag "$cli_command")"

    echo -e "${BLUE}Launching ${label}...${NC}"
    bash "$LIB_DIR/launch-worktree-cli.sh" "$path" "$launch_flag"
}

# Open frontend in browser. Always uses http://localhost:<port> — Auth0 refuses
# any non-localhost / non-HTTPS origin. For remote-daemon worktrees, verifies
# the SSH tunnel is up first (auto-starts if down) so localhost actually resolves.
open_frontend() {
    local path="$1"
    if [[ ! -f "$path/.env" ]]; then
        echo -e "${RED}No .env found. Run 'start' first to generate ports.${NC}"
        return 1
    fi

    local frontend_port
    frontend_port=$(grep "^FRONTEND_PORT=" "$path/.env" 2>/dev/null | cut -d= -f2)
    if [[ -z "$frontend_port" ]]; then
        echo -e "${RED}FRONTEND_PORT missing from $path/.env.${NC}"
        return 1
    fi

    # If this worktree was started against a remote Docker daemon, ensure the
    # SSH port-forward is alive before opening — otherwise localhost:<port>
    # has nothing listening and the browser will just see a connection refused.
    # Optional remote-daemon tunnel hook: when the frontend runs on a remote
    # Docker host, set WTD_REMOTE_TUNNEL_CMD to a command that ensures the SSH
    # port-forward is up (run with the worktree as cwd) before the browser opens.
    if [[ -n "${WTD_REMOTE_TUNNEL_CMD:-}" ]]; then
        (cd "$path" && eval "$WTD_REMOTE_TUNNEL_CMD") || {
            echo -e "${RED}Remote tunnel command failed — cannot open frontend.${NC}"
            return 1
        }
    fi

    local url="http://localhost:${frontend_port}"
    local browser_app="${WTD_BROWSER_APP:-Google Chrome}"
    echo -e "${BLUE}Opening frontend at ${url}${NC}"

    # Prefer the user's regular Chrome app to avoid Playwright's persistent test profile.
    if open -a "$browser_app" "$url" >/dev/null 2>&1; then
        return
    fi
    if open "$url" >/dev/null 2>&1; then
        return
    fi
    echo -e "${RED}Failed to open browser. Tried '${browser_app}' and default browser.${NC}"
    return 1
}

# Open worktree in VS Code with robust fallback.
open_vscode() {
    local path="$1"

    if command -v code >/dev/null 2>&1; then
        if code "$path" >/dev/null 2>&1; then
            return
        fi
    fi

    if open -a "Visual Studio Code" "$path" >/dev/null 2>&1; then
        return
    fi

    echo -e "${RED}Failed to open VS Code. Install the 'code' CLI or ensure 'Visual Studio Code' is installed.${NC}"
}

# Stop containers for all worktrees
stop_all_worktrees() {
    _wtd_require_container_prefix || return 0
    local running=()
    for path in "${WORKTREE_PATHS[@]}"; do
        local status=$(get_container_status "$path")
        if [[ "$status" == *"Running"* ]]; then
            running+=("$path")
        fi
    done

    if [[ ${#running[@]} -eq 0 ]]; then
        echo -e "${YELLOW}No active worktree containers detected.${NC}"
    fi

    if [[ ${#running[@]} -gt 0 ]]; then
        echo -e "${BOLD}Stopping containers for ${#running[@]} worktree(s):${NC}"
        for path in "${running[@]}"; do
            local name=$(basename "$path")
            echo -e "  ${YELLOW}Stopping ${name}...${NC}"
            wtd_stack_stop "$path" 2>/dev/null || true
            echo -e "  ${GREEN}✓ ${name}${NC}"
        done
    fi

    # Target the same daemon the status render resolved against. When the
    # configured remote is offline, CONTAINER_SWEEP_HOST is "" (local) so these
    # orphan/stale sweeps act on the daemon that actually holds the containers
    # instead of wedging on the unreachable remote's ssh connect timeout.
    local _host="${CONTAINER_SWEEP_HOST-${DOCKER_HOST:-}}"

    # Catch orphan/shared project containers not tied to currently listed worktrees
    local remaining
    remaining=$(DOCKER_HOST="$_host" docker ps --filter "name=^${WTD_CONTAINER_PREFIX}" --format "{{.Names}}" 2>/dev/null || true)
    if [[ -n "$remaining" ]]; then
        echo
        echo -e "${BOLD}Stopping remaining project containers (orphan/shared):${NC}"
        while IFS= read -r container; do
            [[ -z "$container" ]] && continue
            echo -e "  ${YELLOW}Stopping ${container}...${NC}"
            DOCKER_HOST="$_host" docker stop "$container" >/dev/null 2>&1 || true
            echo -e "  ${GREEN}✓ ${container}${NC}"
        done <<< "$remaining"
    fi

    # Remove stale created/exited/dead project containers so they don't linger in listings
    local stale
    stale=$(DOCKER_HOST="$_host" docker ps -a \
        --filter "name=^${WTD_CONTAINER_PREFIX}" \
        --filter "status=created" \
        --filter "status=exited" \
        --filter "status=dead" \
        --format "{{.Names}}" 2>/dev/null || true)
    if [[ -n "$stale" ]]; then
        echo
        echo -e "${BOLD}Removing stale project containers:${NC}"
        while IFS= read -r container; do
            [[ -z "$container" ]] && continue
            DOCKER_HOST="$_host" docker rm "$container" >/dev/null 2>&1 || true
            echo -e "  ${GREEN}✓ Removed ${container}${NC}"
        done <<< "$stale"
    fi

    echo
    echo -e "${GREEN}✓ All project containers stopped and cleaned.${NC}"
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
        echo -e "  ${CYAN}[#cmd]${NC}     Quick command (e.g. ${CYAN}7d${NC}=select 7+delete, ${CYAN}7dy${NC}=delete+confirm)"
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
        echo -e "  ${YELLOW}[r]${NC}estart Rebuild containers (stop/start)"
        echo -e "  ${BLUE}[f]${NC}ront   Open frontend in browser"
        echo -e "  ${BLUE}[l]${NC}ogs    Show backend logs"
        echo -e "  ${BLUE}[t]${NC}erm    Open terminal here"
        echo -e "  ${BLUE}[v]${NC}scode  Open in VS Code"
        echo -e "  ${BLUE}[o]${NC}pen    Launch ${preferred_label}"
        echo -e "  ${BLUE}[c]${NC}laude  Launch Claude Code"
        echo -e "  ${BLUE}[e]${NC}codex  Launch Codex CLI"
        echo -e "  ${GREEN}[E]${NC}2e     Run e2e tests (Playwright)"
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
                start_worktree "$path"
                read -p "Press Enter to continue..."
                ;;
            x|X|stop)
                stop_worktree "$path"
                read -p "Press Enter to continue..."
                ;;
            r|R|restart)
                restart_worktree "$path"
                read -p "Press Enter to continue..."
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
                launch_cli_inline "$path" "$preferred_cli" "$preferred_label"
                ;;
            c|C|claude)
                launch_cli_inline "$path" "claude" "Claude Code"
                ;;
            e|codex)
                launch_cli_inline "$path" "codex" "Codex CLI"
                ;;
            E|e2e)
                run_e2e_tests "$path" "$pre_extra"
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
