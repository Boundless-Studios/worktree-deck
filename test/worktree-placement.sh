#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/worktree-placement.sh
source "$ROOT/lib/worktree-placement.sh"
# shellcheck source=../lib/worktree-actions.sh
source "$ROOT/lib/worktree-actions.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
TMP="$(cd "$TMP" && pwd -P)"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_eq() {
    [[ "$1" == "$2" ]] || fail "expected '$2', got '$1'"
}

assert_contains() {
    [[ "$1" == *"$2"* ]] || fail "expected output to contain '$2': $1"
}

run_evaluator() {
    local rc=0
    set +e
    EVALUATOR_OUTPUT="$(wtd_evaluate_placement "$@")"
    rc=$?
    set -e
    EVALUATOR_RC="$rc"
}

mkdir -p "$TMP/physical/visible" "$TMP/physical/ignored"
ln -s "$TMP/physical" "$TMP/link"

future_path="$TMP/physical/future/nested/worktree"
expected_future="$TMP/physical/future/nested/worktree"
assert_eq "$(wtd_canonical_path "$future_path")" "$expected_future"
assert_eq \
    "$(wtd_canonical_path "$TMP/link/visible/worktree")" \
    "$TMP/physical/visible/worktree"

run_evaluator \
    "local-task" "managed_worktree" "$future_path" "unknown" "local" "false"
assert_eq "$EVALUATOR_RC" "0"
assert_contains "$EVALUATOR_OUTPUT" '"schema_version":"1.0"'
assert_contains "$EVALUATOR_OUTPUT" '"contract":"worktree-placement-compatibility/v1"'
assert_contains "$EVALUATOR_OUTPUT" '"compatible":true'
assert_contains "$EVALUATOR_OUTPUT" '"reason_code":"sync_not_required"'
assert_contains "$EVALUATOR_OUTPUT" '"kind":"local"'
assert_contains "$EVALUATOR_OUTPUT" "\"path\":\"$expected_future\""

run_evaluator \
    "remote-task" "managed_worktree" \
    "$TMP/link/visible/worktree" "visible" "remote" "true"
assert_eq "$EVALUATOR_RC" "0"
assert_contains "$EVALUATOR_OUTPUT" '"compatible":true'
assert_contains "$EVALUATOR_OUTPUT" '"reason_code":"sync_visibility_confirmed"'
assert_contains "$EVALUATOR_OUTPUT" '"kind":"remote"'
assert_contains "$EVALUATOR_OUTPUT" "\"path\":\"$TMP/physical/visible/worktree\""

run_evaluator \
    "ignored-task" "managed_worktree" \
    "$TMP/physical/ignored/worktree" "ignored" "remote" "true"
assert_eq "$EVALUATOR_RC" "1"
assert_contains "$EVALUATOR_OUTPUT" '"compatible":false'
assert_contains "$EVALUATOR_OUTPUT" '"reason_code":"sync_visibility_ignored"'
assert_contains "$EVALUATOR_OUTPUT" '"kind":"remote"'
assert_contains "$EVALUATOR_OUTPUT" '"remediation":"Choose a synchronized worktree root or change the configured placement."'

run_evaluator \
    "unknown-task" "managed_worktree" \
    "$TMP/physical/other/worktree" "unknown" "remote" "true"
assert_eq "$EVALUATOR_RC" "1"
assert_contains "$EVALUATOR_OUTPUT" '"reason_code":"sync_visibility_unknown"'
assert_contains "$EVALUATOR_OUTPUT" '"remediation":"Declare this path visible or choose an execution target that does not require synchronization."'

run_evaluator \
    "bad-task" "managed_worktree" \
    "$future_path" "maybe" "remote" "true"
assert_eq "$EVALUATOR_RC" "2"
assert_contains "$EVALUATOR_OUTPUT" '"reason_code":"invalid_contract"'
assert_contains "$EVALUATOR_OUTPUT" '"compatible":false'

WTD_SYNC_VISIBLE_ROOTS=("$TMP/link/visible")
WTD_SYNC_IGNORED_ROOTS=("$TMP/link/ignored")
assert_eq \
    "$(wtd_sync_visibility "$TMP/physical/visible/worktree")" \
    "visible"
assert_eq \
    "$(wtd_sync_visibility "$TMP/physical/ignored/worktree")" \
    "ignored"
assert_eq \
    "$(wtd_sync_visibility "$TMP/physical/other/worktree")" \
    "unknown"

WTD_EXECUTION_TARGET_KIND="remote"
WTD_EXECUTION_TARGET_REQUIRES_SYNC="true"
run_evaluator \
    "configured-task" "managed_worktree" \
    "$TMP/physical/ignored/worktree" \
    "$(wtd_sync_visibility "$TMP/physical/ignored/worktree")" \
    "$WTD_EXECUTION_TARGET_KIND" "$WTD_EXECUTION_TARGET_REQUIRES_SYNC"
assert_eq "$EVALUATOR_RC" "1"
assert_contains "$EVALUATOR_OUTPUT" '"reason_code":"sync_visibility_ignored"'

# A config change must alter the repeatable decision for the same placement.
WTD_SYNC_VISIBLE_ROOTS=("$TMP/physical/ignored")
WTD_SYNC_IGNORED_ROOTS=()
run_evaluator \
    "configured-task" "managed_worktree" \
    "$TMP/physical/ignored/worktree" \
    "$(wtd_sync_visibility "$TMP/physical/ignored/worktree")" \
    "$WTD_EXECUTION_TARGET_KIND" "$WTD_EXECUTION_TARGET_REQUIRES_SYNC"
assert_eq "$EVALUATOR_RC" "0"
assert_contains "$EVALUATOR_OUTPUT" '"reason_code":"sync_visibility_confirmed"'

WTD_EXECUTION_TARGET_KIND=""
run_evaluator \
    "no-target" "managed_worktree" "$future_path" "visible" \
    "$WTD_EXECUTION_TARGET_KIND" "true"
assert_eq "$EVALUATOR_RC" "2"
assert_contains "$EVALUATOR_OUTPUT" '"reason_code":"invalid_contract"'

mkdir -p "$TMP/configured-project"
: > "$TMP/empty-global-config"
cat > "$TMP/configured-project/worktree-deck.conf" <<EOF
WTD_EXECUTION_TARGET_KIND="remote"
WTD_EXECUTION_TARGET_REQUIRES_SYNC="true"
WTD_SYNC_VISIBLE_ROOTS=()
WTD_SYNC_IGNORED_ROOTS=("$TMP/physical/ignored")
EOF

set +e
HEADLESS_OUTPUT="$(
    (
        WTD_MAIN_REPO="$TMP/configured-project"
        WORKTREE_DECK_CONFIG="$TMP/empty-global-config"
        export WTD_MAIN_REPO
        export WORKTREE_DECK_CONFIG
        source "$ROOT/bin/worktree-deck.sh" \
            placement-check "$TMP/physical/ignored/worktree" \
            "headless-task" "managed_worktree"
    )
)"
HEADLESS_RC=$?
set -e
assert_eq "$HEADLESS_RC" "1"
assert_contains "$HEADLESS_OUTPUT" '"reason_code":"sync_visibility_ignored"'
assert_contains "$HEADLESS_OUTPUT" '"kind":"remote"'

WTD_EXECUTION_TARGET_KIND="remote"
WTD_EXECUTION_TARGET_REQUIRES_SYNC="true"
WTD_SYNC_VISIBLE_ROOTS=()
WTD_SYNC_IGNORED_ROOTS=("$TMP/physical/ignored")
run_evaluator \
    "headless-task" "managed_worktree" \
    "$TMP/physical/ignored/worktree" \
    "$(wtd_sync_visibility "$TMP/physical/ignored/worktree")" \
    "$WTD_EXECUTION_TARGET_KIND" "$WTD_EXECUTION_TARGET_REQUIRES_SYNC"
assert_eq "$HEADLESS_OUTPUT" "$EVALUATOR_OUTPUT"

LIB_DIR="$ROOT/lib"
MAIN_REPO="$TMP/main"
WORKTREES_DIR="$TMP/physical/ignored"
BOLD=""
CYAN=""
RED=""
BLUE=""
GREEN=""
YELLOW=""
NC=""
mkdir -p "$MAIN_REPO"
GIT_CALLS="$TMP/git-calls"

git() {
    printf '%s\n' "$*" >> "$GIT_CALLS"
    return 0
}

worktree_menu() {
    return 0
}

set +e
CREATE_OUTPUT="$(
    create_worktree <<< $'blocked-task\norigin/main\ny\n' 2>&1
)"
CREATE_RC=$?
set -e
assert_eq "$CREATE_RC" "1"
assert_contains "$CREATE_OUTPUT" "placement is incompatible"
[[ ! -e "$GIT_CALLS" ]] || fail "incompatible placement reached git"

WTD_EXECUTION_TARGET_KIND=""
set +e
CREATE_OUTPUT="$(
    create_worktree <<< $'legacy-task\norigin/main\ny\n' 2>&1
)"
CREATE_RC=$?
set -e
assert_eq "$CREATE_RC" "0"
assert_contains "$(cat "$GIT_CALLS")" \
    "worktree add -b legacy-task $WORKTREES_DIR/legacy-task origin/main"

echo "worktree placement compatibility tests passed"
