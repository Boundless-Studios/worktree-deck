#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
text="$(<"$ROOT/lib/continue-worktree.sh")"
[[ "$text" == *'WTD_BRANCH_TRANSITION_SINK} "$WTD_SESSION_ID"'* ]]
[[ "$text" == *'( cd "$worktree_path" && ${WTD_BRANCH_TRANSITION_SINK}'* ]]
transition="${text%%WTD_BRANCH_TRANSITION_SINK*}"
push="${text%%git -C \"\$worktree_path\" push -u origin*}"
[[ ${#transition} -lt ${#push} ]]
[[ "$text" == *'Restoring auto-stashed changes'* ]]
sink_failure="${text#*Could not record attributed branch transition}"
sink_failure="${sink_failure%%return 1*}"
[[ "$sink_failure" == *'restore_target="${current_branch:-$original_head}"'* ]]
[[ "$sink_failure" == *'checkout "$restore_target"'* ]]
[[ "$sink_failure" == *'rollback_ok=1'* ]]
[[ "$sink_failure" == *'"$stashed" -eq 1 && "$rollback_ok" -eq 1'* ]]
grep -q 'WTD_BRANCH_TRANSITION_SINK PATH' "$ROOT/lib/launch-worktree-cli.sh"
echo "continue-lineage: PASS"
