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

# Resolve a worktree NAME (path basename or branch) to its absolute path using
# `git worktree list`. Echoes the path on success, nothing on no match.
_wtd_resolve_worktree_path() {
    local needle="$1" path="" branch="" line
    _match() { [[ -n "$path" ]] && { [[ "$(basename "$path")" == "$needle" || "$branch" == "$needle" ]]; }; }
    while IFS= read -r line; do
        case "$line" in
            "worktree "*) path="${line#worktree }" ;;
            "branch "*)   branch="${line#branch }"; branch="${branch#refs/heads/}" ;;
            "")           if _match; then printf '%s\n' "$path"; return 0; fi; path=""; branch="" ;;
        esac
    done < <(git -C "${WTD_MAIN_REPO:-$PWD}" worktree list --porcelain 2>/dev/null)
    if _match; then printf '%s\n' "$path"; return 0; fi
    return 1
}

# Apply + drop a SPECIFIC stash by its commit sha rather than the global top of
# stack. refs/stash is shared across a repo's worktrees, so a bare `git stash
# pop` can apply/drop an unrelated stash another worktree pushed concurrently.
# Returns non-zero (leaving the stash intact) when the apply conflicts.
_wtd_stash_pop_ref() {
    local wt="$1" sha="$2" entry
    # No sha captured (older path) → best-effort fall back to the classic pop.
    [[ -n "$sha" ]] || { git -C "$wt" stash pop; return $?; }
    git -C "$wt" stash apply "$sha" || return 1
    entry="$(git -C "$wt" stash list --format='%gd %H' 2>/dev/null | awk -v s="$sha" '$2==s{print $1; exit}')"
    [[ -n "$entry" ]] && git -C "$wt" stash drop "$entry" >/dev/null 2>&1 || true
    return 0
}

# wtd_continue_worktree <worktree_path_or_name> <new_branch> [base]
wtd_continue_worktree() {
    local worktree_path="${1:?Usage: wtd_continue_worktree <worktree_path_or_name> <new_branch> [base]}"
    local new_branch="${2:?Usage: wtd_continue_worktree <worktree_path_or_name> <new_branch> [base]}"
    local base="${3:-origin/main}"

    # The first argument may be a worktree NAME (as the README/CLI advertise)
    # rather than a path. If it doesn't resolve to a directory directly, look it
    # up in the worktree list (by path basename or branch) before rejecting it.
    if [[ ! -d "$worktree_path" ]]; then
        local _resolved
        # `|| _resolved=""` keeps a no-match (resolver returns 1) from tripping a
        # caller's `set -e` before we can print the helpful rejection below.
        _resolved="$(_wtd_resolve_worktree_path "$worktree_path")" || _resolved=""
        if [[ -n "$_resolved" && -d "$_resolved" ]]; then
            worktree_path="$_resolved"
        else
            echo "continue-worktree: '$worktree_path' is not a worktree path or name" >&2
            return 1
        fi
    fi

    local lib_dir
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
    if ! bash "$lib_dir/validate-worktree-name.sh" "$new_branch"; then
        return 1
    fi

    # Decide whether to fetch: the base may be a remote-tracking ref
    # (origin/main → fetch origin) OR a local ref, including one that contains a
    # slash (feature/base → no remote, skip fetch). Only fetch when the base's
    # leading segment is an actual configured remote.
    local fetch_remote=""
    if [[ "$base" == */* ]]; then
        local base_prefix="${base%%/*}"
        if git -C "$worktree_path" remote | grep -qxF "$base_prefix"; then
            fetch_remote="$base_prefix"
        fi
    fi

    # Record where the user started so a failed switch can put them back — both
    # the branch name (if on one) and the raw HEAD (for a detached worktree).
    local current_branch original_head
    current_branch="$(git -C "$worktree_path" branch --show-current 2>/dev/null || echo "")"
    original_head="$(git -C "$worktree_path" rev-parse HEAD 2>/dev/null || echo "")"
    echo "🔄 Worktree continuation"
    echo "   Worktree:   $worktree_path"
    echo "   Current:    ${current_branch:-detached}"
    echo "   New branch: $new_branch"
    echo "   Base:       $base"

    # Checked (not bare): this function must not rely on the caller's `set -e`,
    # so it stays correct when invoked from the TUI menu inside an `if`/`||`
    # context (where errexit is suppressed for the whole call).
    if [[ -n "$fetch_remote" ]]; then
        echo "⟳ Fetching from ${fetch_remote}..."
        if ! git -C "$worktree_path" fetch "$fetch_remote" --prune; then
            echo "❌ Could not fetch from ${fetch_remote}; aborting." >&2
            return 1
        fi
    else
        echo "⟳ Base '$base' is a local ref; skipping fetch."
    fi

    local stashed=0 stash_sha=""
    if ! git -C "$worktree_path" diff --quiet \
        || ! git -C "$worktree_path" diff --cached --quiet \
        || [[ -n "$(git -C "$worktree_path" ls-files --others --exclude-standard)" ]]; then
        echo "⚠️  Stashing local changes (including untracked)..."
        # Tag the stash uniquely, then look OUR exact entry up by that tag. refs/stash
        # is shared across a repo's worktrees, so reading `stash@{0}` right after the
        # push can capture a sibling worktree's stash if it pushed in the same window.
        local stash_tag; stash_tag="continue-worktree-$$-${EPOCHSECONDS:-$(date +%s)}-${RANDOM}"
        if ! git -C "$worktree_path" stash push -u -m "$stash_tag"; then
            echo "❌ Could not stash local changes; aborting." >&2
            return 1
        fi
        stash_sha="$(git -C "$worktree_path" stash list --format='%H %gs' 2>/dev/null \
            | awk -v t="$stash_tag" 'index($0,t){print $1; exit}')"
        stashed=1
    fi

    # Branch switch. On ANY failure here we must not let `set -e` abort with the
    # user's edits still hidden in the auto-stash — restore them (or point at the
    # stash) and leave the worktree on a known branch.
    local switch_ok=1
    if git -C "$worktree_path" show-ref --verify --quiet "refs/heads/$new_branch" 2>/dev/null; then
        echo "⚠️  Branch '$new_branch' exists locally — checking out and rebasing on $base..."
        git -C "$worktree_path" checkout "$new_branch" \
            && git -C "$worktree_path" rebase "$base" || switch_ok=0
    else
        echo "✓ Creating branch '$new_branch' from $base..."
        git -C "$worktree_path" checkout -b "$new_branch" "$base" || switch_ok=0
    fi
    if [[ "$switch_ok" -ne 1 ]]; then
        echo "❌ Could not switch to '$new_branch' (base $base)." >&2
        git -C "$worktree_path" rebase --abort 2>/dev/null || true
        # An existing-branch checkout may have already moved us off where the user
        # started before the rebase failed — return there before restoring edits,
        # so the stash doesn't reapply onto the wrong branch. Restore the original
        # branch if they were on one, else the original (detached) HEAD.
        local restore_target="${current_branch:-$original_head}"
        if [[ -n "$restore_target" ]]; then
            git -C "$worktree_path" checkout "$restore_target" 2>/dev/null \
                || echo "⚠️  Could not return to '${restore_target}' — left where the switch failed." >&2
        fi
        if [[ "$stashed" -eq 1 ]]; then
            echo "↩️  Restoring your auto-stashed changes onto '${current_branch:-the original commit}'..." >&2
            _wtd_stash_pop_ref "$worktree_path" "$stash_sha" \
                || echo "⚠️  Could not auto-restore the stash — your changes are safe; see 'git stash list'." >&2
        fi
        return 1
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
        if ! _wtd_stash_pop_ref "$worktree_path" "$stash_sha"; then
            echo "❌ Stash apply hit conflicts — your changes remain in the stash; resolve them manually." >&2
            echo "   Worktree is on '$new_branch' (base $base) but is NOT clean." >&2
            return 1
        fi
    fi

    echo "✅ Worktree continued on '$new_branch' (base $base)."
    echo "   Restart the stack if services need to pick up the new branch."
}
