#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
text="$(<"$ROOT/lib/continue-worktree.sh")"

[[ "$text" == *'WTD_BRANCH_TRANSITION_SINK} "$WTD_SESSION_ID" "$worktree_path"'* ]] \
    || { echo "missing attributed transition call" >&2; exit 1; }
[[ "$text" == *'refusing to push'* ]] \
    || { echo "transition recording must fail closed before push" >&2; exit 1; }
echo "continue-lineage: PASS"
