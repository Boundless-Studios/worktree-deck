#!/usr/bin/env bash
# Continue working in a worktree after its PR merged and the branch was deleted:
# repoint the worktree onto a fresh branch off the base, without recreating it.
#
# Generic flow:
#   1. validate the new branch name (reuse validate-worktree-name.sh)
#   2. fetch the base remote
#   3. stash any local changes (incl. untracked)
#   4. create the new branch off the base (or rebase it if it already exists)
#   5. push with correct upstream tracking
#   6. regenerate the worktree's env via WTD_ENV_REGEN_CMD (if configured)
#   7. pop the stash
#
# .env regeneration is intentionally delegated to the project: set
# WTD_ENV_REGEN_CMD (run with the worktree as cwd) to your slot/port/.env
# generator, or leave it empty and re-run your stack-start command afterward.

# wtd_continue_worktree <worktree_path> <new_branch> [base]
wtd_continue_worktree() {
    local worktree_path="${1:?Usage: wtd_continue_worktree <worktree_path> <new_branch> [base]}"
    local new_branch="${2:?Usage: wtd_continue_worktree <worktree_path> <new_branch> [base]}"
    local base="${3:-origin/main}"

    if [[ ! -d "$worktree_path" ]]; then
        echo "continue-worktree: '$worktree_path' is not a directory" >&2
        return 1
    fi

    local lib_dir
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
    if ! bash "$lib_dir/validate-worktree-name.sh" "$new_branch"; then
        return 1
    fi

    local fetch_remote="origin"
    [[ "$base" == */* ]] && fetch_remote="${base%%/*}"

    local current_branch
    current_branch="$(git -C "$worktree_path" branch --show-current 2>/dev/null || echo "")"
    echo "🔄 Worktree continuation"
    echo "   Worktree:   $worktree_path"
    echo "   Current:    ${current_branch:-detached}"
    echo "   New branch: $new_branch"
    echo "   Base:       $base"

    echo "⟳ Fetching from ${fetch_remote}..."
    git -C "$worktree_path" fetch "$fetch_remote" --prune

    local stashed=0
    if ! git -C "$worktree_path" diff --quiet \
        || ! git -C "$worktree_path" diff --cached --quiet \
        || [[ -n "$(git -C "$worktree_path" ls-files --others --exclude-standard)" ]]; then
        echo "⚠️  Stashing local changes (including untracked)..."
        git -C "$worktree_path" stash push -u -m "continue-worktree: auto-stash before branch switch"
        stashed=1
    fi

    if git -C "$worktree_path" show-ref --verify --quiet "refs/heads/$new_branch" 2>/dev/null; then
        echo "⚠️  Branch '$new_branch' exists locally — checking out and rebasing on $base..."
        git -C "$worktree_path" checkout "$new_branch"
        git -C "$worktree_path" rebase "$base"
    else
        echo "✓ Creating branch '$new_branch' from $base..."
        git -C "$worktree_path" checkout -b "$new_branch" "$base"
    fi

    echo "✓ Pushing '$new_branch' with upstream tracking..."
    git -C "$worktree_path" push -u origin "$new_branch" || {
        git -C "$worktree_path" branch --unset-upstream 2>/dev/null || true
        echo "⚠️  Could not push; upstream unset. Run 'git push -u origin ${new_branch}' when ready."
    }

    if [[ -n "${WTD_ENV_REGEN_CMD:-}" ]]; then
        echo "✓ Regenerating worktree env (WTD_ENV_REGEN_CMD)..."
        ( cd "$worktree_path" && eval "$WTD_ENV_REGEN_CMD" ) || echo "⚠️  env regen command failed"
    fi

    if [[ "$stashed" -eq 1 ]]; then
        echo "✓ Restoring stashed changes..."
        git -C "$worktree_path" stash pop || echo "⚠️  Stash pop had conflicts — resolve manually"
    fi

    echo "✅ Worktree continued on '$new_branch' (base $base)."
    echo "   Restart the stack if services need to pick up the new branch."
}
