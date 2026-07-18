#!/usr/bin/env bash
# Worktree and container cleanup helpers for worktree-deck.
#
# Functions that identify and remove stale/merged worktrees and dead/orphan
# Docker containers associated with the project.

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
        if [[ "$pr_state" == "none" && "$branch" != "detached" && "${PR_DATA_REFRESH_TIMED_OUT:-0}" != "1" ]] && command -v gh &>/dev/null; then
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
                    # --no-optional-locks: a plain `git status` opportunistically
                    # rewrites even a clean index, which would bump the mtime the
                    # console's UPDATED column reads — the reaper's own probe must
                    # not make every scanned worktree look freshly touched.
                    wt_dirty="$(git -C "$path" --no-optional-locks status --porcelain 2>/dev/null || true)"
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
