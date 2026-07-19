#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_eq() {
    local expected="$1" actual="$2" label="$3"
    [[ "$actual" == "$expected" ]] \
        || fail "$label: got '$actual', expected '$expected'"
}

# shellcheck source=/dev/null
source "$ROOT/lib/worktree-launch-mode.sh"

unset WTD_LAUNCH_FLAG
assert_eq "--codex" "$(wtd_default_launch_flag)" "default launch flag"
export WTD_LAUNCH_FLAG="--claude"
assert_eq "--claude" "$(wtd_default_launch_flag)" "configured launch flag"

assert_eq "--codex" "$(wtd_normalize_launch_flag codex)" "normalize codex"
assert_eq "--claude" "$(wtd_normalize_launch_flag --claude)" "normalize claude"
assert_eq "codex" "$(wtd_launch_cli_from_flag --codex)" "codex command"
assert_eq "claude" "$(wtd_launch_cli_from_flag claude)" "claude command"
assert_eq "resume --last" "$(wtd_resume_args_from_cli codex)" "codex resume"
assert_eq "--continue" "$(wtd_resume_args_from_cli claude)" "claude resume"

declare -F wtd_is_fresh_action >/dev/null \
    || fail "wtd_is_fresh_action is not implemented"

for action in o O open c C claude e codex; do
    wtd_is_fresh_action "$action" \
        || fail "fresh action '$action' was not classified as fresh"
done

for action in r resume E e2e f logs; do
    if wtd_is_fresh_action "$action"; then
        fail "non-fresh action '$action' was classified as fresh"
    fi
done

echo "PASS: worktree launch mode"
