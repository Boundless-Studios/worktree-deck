#!/usr/bin/env bash
# Worktree list rendering helpers for worktree-deck.
#
# Functions that compute display names, container status, port/slot info, and
# render the full worktree table shown in the main menu.

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

# Format an epoch as a compact relative age
wtd_format_age() {
    local epoch="${1:-}"
    local now_epoch="${2:-}"
    local age

    [[ -n "$now_epoch" ]] || now_epoch=$(date +%s 2>/dev/null || true)
    if [[ ! "$epoch" =~ ^[0-9]+$ || ! "$now_epoch" =~ ^[0-9]+$ ]]; then
        echo "-"
        return 0
    fi

    epoch=$((10#$epoch))
    now_epoch=$((10#$now_epoch))
    if (( epoch == 0 || epoch > now_epoch )); then
        echo "-"
        return 0
    fi

    age=$((now_epoch - epoch))
    if (( age < 60 )); then
        echo "<1m"
    elif (( age < 3600 )); then
        echo "$((age / 60))m"
    elif (( age < 86400 )); then
        echo "$((age / 3600))h"
    elif (( age < 604800 )); then
        echo "$((age / 86400))d"
    elif (( age < 2592000 )); then
        echo "$((age / 604800))w"
    elif (( age < 31536000 )); then
        echo "$((age / 2592000))mo"
    else
        echo "$((age / 31536000))y"
    fi
}

# Get a worktree's git directory creation time
wtd_worktree_created_epoch() {
    local worktree_path="${1:-}"
    local gitdir epoch fallback_path

    if [[ -z "$worktree_path" ]] \
        || ! gitdir=$(git -C "$worktree_path" rev-parse --git-dir 2>/dev/null); then
        echo
        return 0
    fi
    [[ "$gitdir" == /* ]] || gitdir="$worktree_path/$gitdir"

    # GNU first: BSD stat rejects -c cleanly, but probing BSD's -f first would
    # "succeed" on GNU (filesystem mode: %B = block size, %m = mount point) and
    # return garbage instead of failing over.
    if ! epoch=$(stat -c %W "$gitdir" 2>/dev/null); then
        epoch=$(stat -f %B "$gitdir" 2>/dev/null || true)
    fi
    if [[ "$epoch" =~ ^[0-9]+$ ]] && (( epoch > 0 )); then
        echo "$epoch"
        return 0
    fi

    fallback_path="$gitdir"
    [[ -f "$gitdir/gitdir" ]] && fallback_path="$gitdir/gitdir"
    if ! epoch=$(stat -c %Y "$fallback_path" 2>/dev/null); then
        epoch=$(stat -f %m "$fallback_path" 2>/dev/null || true)
    fi
    if [[ "$epoch" =~ ^[0-9]+$ ]] && (( epoch > 0 )); then
        echo "$epoch"
    else
        echo
    fi
}

# Get the latest local git activity time for a worktree
wtd_worktree_updated_epoch() {
    local worktree_path="${1:-}"
    local gitdir epoch

    if [[ -z "$worktree_path" ]] \
        || ! gitdir=$(git -C "$worktree_path" rev-parse --git-dir 2>/dev/null); then
        echo
        return 0
    fi
    [[ "$gitdir" == /* ]] || gitdir="$worktree_path/$gitdir"

    if [[ -f "$gitdir/index" ]]; then
        # GNU-first for the same reason as wtd_worktree_created_epoch.
        if ! epoch=$(stat -c %Y "$gitdir/index" 2>/dev/null); then
            epoch=$(stat -f %m "$gitdir/index" 2>/dev/null || true)
        fi
        if [[ "$epoch" =~ ^[0-9]+$ ]] && (( epoch > 0 )); then
            echo "$epoch"
            return 0
        fi
    fi

    epoch=$(git -C "$worktree_path" log -1 --format=%ct 2>/dev/null || true)
    if [[ "$epoch" =~ ^[0-9]+$ ]] && (( epoch > 0 )); then
        echo "$epoch"
    else
        echo
    fi
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
    echo -e "${CYAN}────────────────────────────────────────────────────────────────────────────────────────────${NC}"
    printf "  %-4s %-22s %-3s %-8s%-5s %-14s %-8s %-8s %s\n" "#" "NAME" "ON" "STATUS" "SLOT" "PORTS" "CREATED" "UPDATED" "PR"
    echo -e "${CYAN}────────────────────────────────────────────────────────────────────────────────────────────${NC}"

    local i=1
    local now_epoch
    now_epoch=$(date +%s 2>/dev/null || true)
    declare -g -a WORKTREE_PATHS=()

    while IFS= read -r line; do
        local path=$(echo "$line" | awk '{print $1}')
        local branch=$(echo "$line" | awk '{print $3}' | tr -d '[]')

        WORKTREE_PATHS+=("$path")

        local display_name=$(short_name "$path")
        local slot=$(get_slot_info "$path")
        local ports=$(get_port_info "$path")
        local pr=$(get_pr_info "$branch")
        local created updated
        created=$(wtd_format_age "$(wtd_worktree_created_epoch "$path")" "$now_epoch")
        updated=$(wtd_format_age "$(wtd_worktree_updated_epoch "$path")" "$now_epoch")
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
        local pcreated pupdated
        pcreated=$(printf "%-8s" "$created")
        pupdated=$(printf "%-8s" "$updated")

        echo -e "${marker} $(printf "%-3s" "$i") ${CYAN}${pname}${NC}${where_icon} ${dot_color}${dot}${NC}   ${pslot} ${pports} ${pcreated} ${pupdated} ${pr}"
        ((i++))
    done < <(git -C "$MAIN_REPO" worktree list 2>/dev/null)

    echo -e "${CYAN}────────────────────────────────────────────────────────────────────────────────────────────${NC}"

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
