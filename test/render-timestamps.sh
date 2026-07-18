#!/usr/bin/env bash
# Tests for the console CREATED/UPDATED column helpers (BOU-2187):
#   wtd_format_age            — epoch -> compact relative age ("5m", "3h", "2d")
#   wtd_worktree_created_epoch — when a worktree was created
#   wtd_worktree_updated_epoch — last git activity in a worktree
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# worktree-render.sh only defines functions; sourcing it is side-effect free.
# shellcheck source=/dev/null
source "$ROOT/lib/worktree-render.sh"

CLEANUP_DIRS=()
cleanup() {
    local d
    for d in "${CLEANUP_DIRS[@]:-}"; do
        [[ -n "$d" && -d "$d" ]] && rm -rf "$d"
    done
}
trap cleanup EXIT

# --- wtd_format_age -----------------------------------------------------------

NOW=1800000000  # injected "now" so assertions are deterministic

assert_age() {
    local epoch="$1" expected="$2" got
    got="$(wtd_format_age "$epoch" "$NOW")"
    [[ "$got" == "$expected" ]] || fail "wtd_format_age '$epoch' -> '$got', expected '$expected'"
}

assert_age ""                      "-"       # empty input
assert_age "0"                     "-"       # unknown birthtime (GNU stat %W = 0)
assert_age "not-a-number"          "-"       # garbage
assert_age "$((NOW + 3600))"       "-"       # future timestamp = clock skew, don't render nonsense
assert_age "$((NOW - 30))"         "<1m"     # under a minute
assert_age "$((NOW - 300))"        "5m"      # minutes
assert_age "$((NOW - 3 * 3600))"   "3h"      # hours
assert_age "$((NOW - 2 * 86400))"  "2d"      # days
assert_age "$((NOW - 10 * 86400))" "1w"      # weeks
assert_age "$((NOW - 60 * 86400))" "2mo"     # months (30-day months)
assert_age "$((NOW - 400 * 86400))" "1y"     # years

echo "ok: wtd_format_age formatting"

# --- created/updated epochs against a real repo + linked worktree -------------

make_temp_repo() {
    local repo
    repo="$(mktemp -d "${TMPDIR:-/tmp}/wtd-ts-repo.XXXXXX")"
    git -C "$repo" init -q -b main
    git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
    printf '%s\n' "$repo"
}

REPO="$(make_temp_repo)"
CLEANUP_DIRS+=("$REPO")
WT_PARENT="$(mktemp -d "${TMPDIR:-/tmp}/wtd-ts-wt.XXXXXX")"
CLEANUP_DIRS+=("$WT_PARENT")

before="$(date +%s)"
git -C "$REPO" worktree add -q -b feat "$WT_PARENT/feat"
after="$(date +%s)"

created="$(wtd_worktree_created_epoch "$WT_PARENT/feat")"
[[ "$created" =~ ^[0-9]+$ ]] || fail "created epoch not numeric: '$created'"
(( created >= before - 1 && created <= after + 1 )) \
    || fail "created epoch $created outside [$before, $after]"

# Main worktree resolves too (its gitdir is .git itself).
created_main="$(wtd_worktree_created_epoch "$REPO")"
[[ "$created_main" =~ ^[0-9]+$ ]] || fail "main-repo created epoch not numeric: '$created_main'"

updated_t0="$(wtd_worktree_updated_epoch "$WT_PARENT/feat")"
[[ "$updated_t0" =~ ^[0-9]+$ ]] || fail "updated epoch not numeric: '$updated_t0'"

# Git activity in the worktree must advance (or at least not rewind) "updated".
sleep 1
touch "$WT_PARENT/feat/newfile"
git -C "$WT_PARENT/feat" add newfile
git -C "$WT_PARENT/feat" -c user.email=t@t -c user.name=t commit -q -m change
updated_t1="$(wtd_worktree_updated_epoch "$WT_PARENT/feat")"
(( updated_t1 > updated_t0 )) \
    || fail "updated epoch did not advance after commit: $updated_t0 -> $updated_t1"

# A path that isn't a worktree renders as unknown, not a crash.
NOT_A_REPO="$(mktemp -d "${TMPDIR:-/tmp}/wtd-ts-none.XXXXXX")"
CLEANUP_DIRS+=("$NOT_A_REPO")
none_created="$(wtd_worktree_created_epoch "$NOT_A_REPO")"
none_updated="$(wtd_worktree_updated_epoch "$NOT_A_REPO")"
[[ "$(wtd_format_age "$none_created" "$NOW")" == "-" ]] || fail "non-repo created should format as '-'"
[[ "$(wtd_format_age "$none_updated" "$NOW")" == "-" ]] || fail "non-repo updated should format as '-'"

echo "ok: created/updated epochs"
echo "PASS: render-timestamps"
