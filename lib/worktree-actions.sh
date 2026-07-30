#!/usr/bin/env bash
# Worktree lifecycle actions for worktree-deck.
#
# Functions that start, stop, restart, create, remove, and bulk-stop worktrees
# and their associated dev stacks.

# Start the dev stack for a worktree (config-driven; no-op when stackless).
# Handles its own expected outcomes (no stack / cap refusal / start failure) and
# always returns 0 — so the TUI can call it WITHOUT an `|| true` wrapper, which
# would otherwise suppress errexit for the whole function and print "✓ Started!"
# even when the start actually failed.
start_worktree() {
    local path="$1"
    if ! wtd_has_stack; then echo -e "${YELLOW}No dev stack configured (set WTD_STACK_START).${NC}"; return 0; fi
    # Concurrent-stack cap (no-op unless WTD_BACKEND_CAP is set). Exclude ALL of
    # this worktree's own container names (template- AND .env-derived) so a
    # restart of an already-counted stack isn't blocked by its own presence.
    local own; own="$(wtd_service_names "$path" 2>/dev/null)"
    if ! wtd_backend_cap_ok "$own"; then
        return 0  # refusal already explained by wtd_backend_cap_ok; handled, not a crash
    fi
    echo -e "${BLUE}Starting stack for ${BOLD}$(basename "$path")${NC}..."
    if wtd_stack_start "$path"; then
        echo -e "${GREEN}✓ Started!${NC}"
    else
        echo -e "${RED}✗ Start failed (see output above).${NC}"
    fi
    return 0
}

# Stop the dev stack for a worktree.
stop_worktree() {
    local path="$1"
    if ! wtd_has_stack; then echo -e "${YELLOW}No dev stack configured (set WTD_STACK_STOP).${NC}"; return; fi
    echo -e "${YELLOW}Stopping stack for ${BOLD}$(basename "$path")${NC}..."
    wtd_stack_stop "$path"
    echo -e "${GREEN}✓ Stopped!${NC}"
}

# Restart the dev stack for a worktree. Like start_worktree, handles its own
# outcomes and always returns 0 (no `|| true` needed at the call site).
restart_worktree() {
    local path="$1"
    if ! wtd_has_stack; then echo -e "${YELLOW}No dev stack configured.${NC}"; return 0; fi
    # Restart can START a stopped stack (directly via wtd_stack_restart), so it
    # must honour WTD_BACKEND_CAP just like start_worktree. Exclude ALL of this
    # worktree's own container names so restarting an already-running stack isn't
    # blocked by itself.
    local own; own="$(wtd_service_names "$path" 2>/dev/null)"
    if ! wtd_backend_cap_ok "$own"; then
        return 0  # refusal already explained; handled, not a crash
    fi
    echo -e "${YELLOW}Restarting stack for ${BOLD}$(basename "$path")${NC}..."
    if wtd_stack_restart "$path"; then
        echo -e "${GREEN}✓ Restarted!${NC}"
    else
        echo -e "${RED}✗ Restart failed (see output above).${NC}"
    fi
    return 0
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
    local placement_result placement_rc

    echo
    echo -e "Creating worktree:"
    echo -e "  Path:   ${CYAN}${worktree_path}${NC}"
    echo -e "  Branch: ${CYAN}${branch_name}${NC}"
    echo -e "  Base:   ${CYAN}${base_branch}${NC}"
    echo

    if wtd_execution_target_configured; then
        placement_rc=0
        placement_result="$(
            wtd_evaluate_configured_placement \
                "$branch_name" "managed_worktree" "$worktree_path"
        )" || placement_rc=$?
        if [[ "$placement_rc" -ne 0 ]]; then
            echo -e "${RED}✗ Worktree placement is incompatible with the configured execution target.${NC}" >&2
            printf '%s\n' "$placement_result" >&2
            return 1
        fi
    fi

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
