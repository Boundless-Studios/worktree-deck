# Shared helper used by scripts/cleanup-merged-worktrees.sh and
# scripts/worktree-console.sh to skip stale .env files so their
# *_CONTAINER_NAME entries don't shield orphan containers from the sweep.

# Return 0 when $wt_path/.env can be trusted for container names, 1 when it
# cannot.
#
# We intentionally only flag one narrow staleness pattern: the worktree is
# now on main/master but .env still carries a feature-branch tag. That's the
# "checked main back out after working on a feature branch" case where the
# .env's *_CONTAINER_NAME entries shield orphans whose owning worktree is
# long gone.
#
# In-worktree branch renames (e.g. `git branch -m`) also produce a
# branch-vs-env mismatch, but the containers named in .env are usually still
# the live ones the user is working with — so we leave those alone.
gaia_env_matches_branch() {
    local wt_path="$1"
    [[ -f "$wt_path/.env" ]] || return 1
    local branch recorded
    branch="$(git -C "$wt_path" branch --show-current 2>/dev/null || true)"
    # Only the main/master-with-stale-tag pattern is treated as stale.
    if [[ "$branch" != "main" && "$branch" != "master" ]]; then
        return 0
    fi
    recorded="$(grep -E '^GAIA_BRANCH_TAG=' "$wt_path/.env" 2>/dev/null | head -n1 | cut -d= -f2-)"
    recorded="${recorded%\"}"; recorded="${recorded#\"}"
    recorded="${recorded%\'}"; recorded="${recorded#\'}"
    # Legacy .env without the field, or the expected "latest" tag → trust.
    [[ -z "$recorded" || "$recorded" == "latest" ]]
}
