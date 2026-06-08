#!/usr/bin/env bash
# Auto-cleanup worktrees whose PRs have been merged/closed, or that are stale orphans.
# Stops per-worktree Docker containers and removes the git worktree directory.
#
# Called by:
#   - make start-worktree (opportunistic cleanup before starting)
#   - .git/hooks/post-merge (after git pull / merge)
#
# Detection:
#   1. Merged PRs — branch has a merged PR on GitHub
#   2. Closed PRs — branch has a closed (not merged) PR on GitHub
#   3. Stale orphans — no PR, last commit older than threshold
#      (3 days for agent worktrees, 7 days for others)
#
# Safe by design:
#   - Never touches shared infra (postgres, rabbitmq, volumes)
#   - Never touches the current worktree
#   - Never touches main/master
#   - Never touches worktrees with active sessions (any shell or Claude process)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "${1:-}" in
    -h|--help)
        sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    "")
        ;;
    *)
        echo "Unknown option: $1" >&2
        echo "Usage: $0 [--help]" >&2
        exit 2
        ;;
esac

# shellcheck source=lib/docker-reachable.sh
source "$SCRIPT_DIR/lib/docker-reachable.sh"

# Require gh CLI for PR-based detection
if ! command -v gh &>/dev/null; then
    exit 0
fi

# Resolve main repo from any worktree
MAIN_REPO="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null | sed 's|/\.git$||')"
if [[ -z "$MAIN_REPO" || ! -d "$MAIN_REPO" ]]; then
    exit 0
fi

CURRENT_DIR="$(pwd)"

# Probe docker reachability once. The helper transparently falls back from
# a dead ssh:// remote to the local daemon (matching Makefile:52-69) so we
# don't block 30s per docker call against an offline desktop. SKIP_DOCKER
# is only set when BOTH remote and local are unreachable — in that case we
# skip docker calls but still run git worktree cleanup.
SKIP_DOCKER=""
if ! gaia_docker_reachable; then
    SKIP_DOCKER=1
fi

# Collect directories with active sessions (any shell or Claude Code process).
# Protects worktrees where a user has a terminal open, not just Claude sessions.
ACTIVE_DIRS=()
while IFS= read -r pid; do
    cwd="$(lsof -p "$pid" -a -d cwd -Fn 2>/dev/null | grep '^n' | sed 's/^n//' || true)"
    [[ -n "$cwd" ]] && ACTIVE_DIRS+=("$cwd")
done < <(pgrep -x 'claude|zsh|bash|fish' 2>/dev/null; true)

# Fetch all PR metadata in one call (branch, number, state)
PR_DATA="$(cd "$MAIN_REPO" && gh pr list --state all --limit 500 \
    --json headRefName,number,state \
    --template '{{range .}}{{.headRefName}}{{"\t"}}{{.number}}{{"\t"}}{{.state}}{{"\n"}}{{end}}' 2>/dev/null)" || exit 0

# Staleness thresholds (seconds)
NOW_EPOCH=$(date +%s)
AGENT_STALE_SECS=$((3 * 86400))   # 3 days for agent worktrees
OTHER_STALE_SECS=$((7 * 86400))   # 7 days for others

# Determine main branch ref for fork-point detection
target_ref="main"
if git -C "$MAIN_REPO" rev-parse --verify "origin/main" >/dev/null 2>&1; then
    target_ref="origin/main"
fi

cleaned=0

# Helper: stop containers and remove a worktree
cleanup_worktree() {
    local path="$1"
    local branch="$2"
    local reason="$3"

    local name
    name="$(basename "$path")"
    local tag
    tag="$(echo "$branch" | sed 's|^[a-z]*/||')"
    tag="${tag:0:30}"
    local suffix="${tag:+-$tag}"

    echo "Cleaning ${reason} worktree: $name ($branch)"

    # Stop per-worktree Docker containers (best-effort). Skipped when the
    # daemon is unreachable — see the gaia_docker_reachable probe at the top.
    if [[ -z "$SKIP_DOCKER" ]]; then
        for service in backend frontend image-worker stt; do
            docker stop "gaia-${service}${suffix}" 2>/dev/null || true
            docker rm "gaia-${service}${suffix}" 2>/dev/null || true
        done
    fi

    # Remove the git worktree
    if git -C "$MAIN_REPO" worktree remove --force "$path" 2>/dev/null; then
        echo "  Removed worktree: $path"
        cleaned=$((cleaned + 1))
    else
        echo "  Warning: failed to remove worktree $path" >&2
    fi
}

# Helper: check if a path has any active session (shell or Claude Code)
has_active_session() {
    local path="$1"
    for active_dir in "${ACTIVE_DIRS[@]}"; do
        if [[ "$active_dir" == "$path" || "$active_dir" == "$path/"* ]]; then
            return 0
        fi
    done
    return 1
}

while IFS= read -r line; do
    path="$(echo "$line" | awk '{print $1}')"
    branch="$(echo "$line" | awk '{print $3}' | tr -d '[]')"

    # Skip main repo
    [[ "$path" == "$MAIN_REPO" ]] && continue

    # Skip current worktree
    [[ "$path" == "$CURRENT_DIR" ]] && continue

    # Skip main/master/detached/empty
    [[ -z "$branch" || "$branch" == "main" || "$branch" == "master" || "$branch" == "detached" ]] && continue

    # Skip worktrees with active sessions (any shell or Claude Code process)
    if has_active_session "$path"; then
        echo "Skipping worktree $(basename "$path"): active session detected"
        continue
    fi

    # Look up PR state for this branch (prefer OPEN > MERGED > CLOSED)
    pr_number=""
    pr_state=""
    if [[ -n "$PR_DATA" ]]; then
        pr_match=""
        pr_match=$(awk -F '\t' -v b="$branch" '
            $1==b {
                if ($3=="OPEN") { print $2 "\t" $3; found=1; exit }
                if ($3=="MERGED" && merged=="") { merged=$2 "\t" $3 }
                if ($3=="CLOSED" && closed=="") { closed=$2 "\t" $3 }
            }
            END {
                if (!found) {
                    if (merged!="") print merged
                    else if (closed!="") print closed
                }
            }
        ' <<< "$PR_DATA")

        if [[ -n "$pr_match" ]]; then
            pr_number="${pr_match%%$'\t'*}"
            pr_state="${pr_match#*$'\t'}"
        fi
    fi

    # If the branch was not found in the cached PR list (which is capped at
    # 500 results), do a per-branch lookup so we don't mistakenly treat a
    # branch with an open PR as an orphan.
    if [[ -z "$pr_state" ]]; then
        branch_pr="$(cd "$MAIN_REPO" && gh pr list --head "$branch" --state all --limit 1 \
            --json number,state \
            --template '{{range .}}{{.number}}{{"\t"}}{{.state}}{{end}}' 2>/dev/null || true)"
        if [[ -n "$branch_pr" ]]; then
            pr_number="${branch_pr%%$'\t'*}"
            pr_state="${branch_pr#*$'\t'}"
        fi
    fi

    # Skip branches with open PRs
    if [[ "$pr_state" == "OPEN" ]]; then
        continue
    fi

    # Category 1: Merged PR
    if [[ "$pr_state" == "MERGED" ]]; then
        cleanup_worktree "$path" "$branch" "merged (PR #$pr_number)"
        continue
    fi

    # Category 2: Closed PR (not merged)
    if [[ "$pr_state" == "CLOSED" ]]; then
        cleanup_worktree "$path" "$branch" "closed (PR #$pr_number)"
        continue
    fi

    # Category 3: Stale orphan (no PR, old commits or no work done)
    # Check if branch has any commits beyond its fork from main.
    fork_point=$(git -C "$MAIN_REPO" merge-base "$branch" "${target_ref}" 2>/dev/null || echo "")
    commit_count=0
    if [[ -n "$fork_point" ]]; then
        commit_count=$(git -C "$MAIN_REPO" rev-list --count "$fork_point..$branch" 2>/dev/null || echo "0")
    fi

    if [[ "$commit_count" -eq 0 ]]; then
        # Zero commits beyond main — but the worktree may still have
        # uncommitted work (staged, unstaged, or untracked files).
        # Skip removal if the working tree is dirty.
        if [[ -d "$path" ]]; then
            wt_dirty="$(git -C "$path" status --porcelain 2>/dev/null || true)"
            if [[ -n "$wt_dirty" ]]; then
                echo "Skipping worktree $(basename "$path"): no commits but has local changes"
                continue
            fi
        fi

        # Require minimum 1-day age so freshly created worktrees aren't reaped.
        # Use the directory's birth time (not the commit timestamp) because
        # zero-commit branches point to a main commit whose date reflects when
        # main was updated, not when this worktree was created.
        ZERO_COMMIT_STALE_SECS=$((1 * 86400))
        if [[ "$(uname -s)" == "Darwin" ]]; then
            dir_birth=$(stat -f '%B' "$path" 2>/dev/null || echo "0")
        else
            dir_birth=$(stat -c '%W' "$path" 2>/dev/null || echo "0")
        fi
        if [[ "$dir_birth" == "0" || "$dir_birth" == "-1" ]]; then
            # Fallback: commit timestamp if stat doesn't support birth time
            dir_birth=$(git -C "$MAIN_REPO" log -1 --format=%ct "$branch" 2>/dev/null || echo "0")
        fi
        age_secs=$((NOW_EPOCH - dir_birth))
        if [[ "$age_secs" -lt "$ZERO_COMMIT_STALE_SECS" ]]; then
            continue
        fi

        cleanup_worktree "$path" "$branch" "orphan (no PR, no commits beyond main)"
    else
        # Branch has actual work — use age-based threshold
        last_epoch=$(git -C "$MAIN_REPO" log -1 --format=%ct "$branch" 2>/dev/null || echo "0")
        age_secs=$((NOW_EPOCH - last_epoch))

        threshold_secs=$OTHER_STALE_SECS
        wt_name="$(basename "$path")"
        # Match both directory name patterns (agent-* from .claude/worktrees/
        # and worktree-agent-* from branch names) and the branch name itself.
        if [[ "$wt_name" == worktree-agent-* || "$wt_name" == agent-* || "$branch" == worktree-agent-* ]]; then
            threshold_secs=$AGENT_STALE_SECS
        fi

        if [[ "$age_secs" -ge "$threshold_secs" ]]; then
            age_days=$((age_secs / 86400))
            cleanup_worktree "$path" "$branch" "stale orphan (${age_days}d old, no PR)"
        fi
    fi

done < <(git -C "$MAIN_REPO" worktree list 2>/dev/null)

if [[ "$cleaned" -gt 0 ]]; then
    echo "Cleaned $cleaned stale worktree(s)."
    # Prune stale worktree bookkeeping
    git -C "$MAIN_REPO" worktree prune 2>/dev/null || true
fi

# --- Orphan container sweep ---
# Reap any gaia-* container whose name is not claimed by a live worktree.
# Source of truth is each worktree's .env (BACKEND_CONTAINER_NAME etc.) —
# .env names can diverge from the current branch slug (e.g. after a rename),
# and that divergence is exactly what makes "derive suffix from branch" miss
# the legitimate active containers.
#
# Shared containers (defined once in docker-compose.yml with a literal
# container_name, not a per-worktree ${VAR:-default}) must be exempted here
# so the sweep doesn't tear down tunnels/webhooks/infra used by every worktree.
if [[ -n "$SKIP_DOCKER" ]]; then
    exit 0
fi
# shellcheck source=worktree-env-tag.sh
source "$SCRIPT_DIR/worktree-env-tag.sh"

expected_names=" gaia-postgres gaia-rabbitmq gaia-cloudflare-tunnel "
while IFS= read -r wt_path; do
    [[ -z "$wt_path" || ! -f "$wt_path/.env" ]] && continue
    # Skip stale .env files — when a worktree's branch has changed since
    # .env was written, its *_CONTAINER_NAME entries point at containers
    # from the prior branch and would otherwise shield orphans from sweep.
    if ! gaia_env_matches_branch "$wt_path"; then
        continue
    fi
    while IFS='=' read -r key value; do
        case "$key" in
            BACKEND_CONTAINER_NAME|FRONTEND_CONTAINER_NAME|IMAGE_WORKER_CONTAINER_NAME|STT_CONTAINER_NAME)
                value="${value%\"}"; value="${value#\"}"
                value="${value%\'}"; value="${value#\'}"
                [[ -n "$value" ]] && expected_names+=" $value "
                ;;
        esac
    done < "$wt_path/.env"
done < <(git -C "$MAIN_REPO" worktree list 2>/dev/null | awk '{print $1}')

orphan_removed=0
while IFS= read -r cname; do
    [[ -z "$cname" ]] && continue
    if [[ "$expected_names" != *" $cname "* ]]; then
        echo "Removing orphan container: $cname"
        docker rm -f "$cname" >/dev/null 2>&1 && orphan_removed=$((orphan_removed + 1)) || true
    fi
done < <(docker ps -a --filter 'name=^gaia-' --format '{{.Names}}' 2>/dev/null)

if [[ "$orphan_removed" -gt 0 ]]; then
    echo "Removed $orphan_removed orphan container(s)."
fi
