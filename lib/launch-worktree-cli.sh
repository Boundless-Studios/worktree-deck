#!/usr/bin/env bash
# Launch an interactive agent CLI inside a worktree, with a consistent terminal
# title and an optional session-event bridge (WTD_EVENT_SINK).
#
# Usage: launch-worktree-cli.sh <worktree_path> [launch_flag]
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=config.sh
source "${LIB_DIR}/config.sh"
# shellcheck source=worktree-launch-mode.sh
source "${LIB_DIR}/worktree-launch-mode.sh"

WORKTREE_PATH="${1:?Usage: launch-worktree-cli.sh <worktree_path> [launch_flag]}"
LAUNCH_FLAG="${2:-$(wtd_default_launch_flag)}"
if wtd_is_launch_selector "$LAUNCH_FLAG"; then
    LAUNCH_FLAG="$(wtd_normalize_launch_flag "$LAUNCH_FLAG")"
fi

LABEL="$(wtd_launch_label_from_flag "$LAUNCH_FLAG")"
CLI_COMMAND="$(wtd_launch_cli_from_flag "$LAUNCH_FLAG")"

# Session id is opaque; used only to correlate start/end events.
SESSION_ID="${WTD_SESSION_ID:-wtd-$$-$(git -C "$WORKTREE_PATH" rev-parse --short HEAD 2>/dev/null || echo nohead)}"

# Optional event bridge: WTD_EVENT_SINK is a command that receives
# "<event> <session_id> <cli> <worktree_path> [exit_code]" as arguments.
_emit_event() {
    [[ -n "${WTD_EVENT_SINK:-}" ]] || return 0
    # shellcheck disable=SC2086
    ${WTD_EVENT_SINK} "$1" "$SESSION_ID" "$CLI_COMMAND" "$WORKTREE_PATH" "${2:-}" >/dev/null 2>&1 || true
}

# Set the terminal title (best-effort; harmless if unsupported).
printf '\033]0;%s — %s\007' "$(basename "$WORKTREE_PATH")" "$LABEL" 2>/dev/null || true

cd "$WORKTREE_PATH"
export WTD_PROJECT_DIR="$WORKTREE_PATH" WTD_SESSION_ID="$SESSION_ID"

_emit_event started
rc=0
# shellcheck disable=SC2086
${CLI_COMMAND} || rc=$?
if [[ $rc -eq 0 ]]; then
    _emit_event completed "$rc"
else
    _emit_event failed "$rc"
fi
exit $rc
