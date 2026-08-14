#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
text="$(<"$ROOT/lib/continue-worktree.sh")"
[[ "$text" == *'WTD_BRANCH_TRANSITION_SINK} "$WTD_SESSION_ID"'* ]]
transition="${text%%WTD_BRANCH_TRANSITION_SINK*}"
push="${text%%git -C \"\$worktree_path\" push -u origin*}"
[[ ${#transition} -lt ${#push} ]]
[[ "$text" == *'Restoring auto-stashed changes'* ]]
grep -q 'WTD_BRANCH_TRANSITION_SINK PATH' "$ROOT/lib/launch-worktree-cli.sh"
echo "continue-lineage: PASS"
