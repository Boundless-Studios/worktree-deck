#!/usr/bin/env bash
# Launch an interactive agent CLI inside a worktree, with a consistent terminal
# title and an optional session-event bridge (WTD_EVENT_SINK).
#
# Usage: launch-worktree-cli.sh <worktree_path> [launch_flag] [extra_cli_args]
#
# [extra_cli_args] is an optional whitespace-separated string appended verbatim
# to the launched CLI command (e.g. resume flags: "--continue" for Claude,
# "resume --last" for Codex). Omit it for a normal fresh launch.
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=config.sh
source "${LIB_DIR}/config.sh"
# shellcheck source=worktree-launch-mode.sh
source "${LIB_DIR}/worktree-launch-mode.sh"

WORKTREE_PATH="${1:?Usage: launch-worktree-cli.sh <worktree_path> [launch_flag]}"

# This launcher runs as its own process (spawned by the TUI), so it must load
# the project config itself — env vars and hook-function overrides from
# worktree-deck.conf are NOT inherited across the subprocess boundary. Without
# this, WTD_EVENT_SINK and any wtd_launch_* override would silently not apply.
wtd_load_config "$WORKTREE_PATH"

LAUNCH_FLAG="${2:-$(wtd_default_launch_flag)}"
if wtd_is_launch_selector "$LAUNCH_FLAG"; then
    LAUNCH_FLAG="$(wtd_normalize_launch_flag "$LAUNCH_FLAG")"
fi

LABEL="$(wtd_launch_label_from_flag "$LAUNCH_FLAG")"
CLI_COMMAND="$(wtd_launch_cli_from_flag "$LAUNCH_FLAG")"

# Optional extra args appended to the CLI command (e.g. resume flags). Word-split
# on purpose so a caller can pass "resume --last" as a single argument.
EXTRA_CLI_ARGS="${3:-}"

# Session id is opaque; used only to correlate start/end events.
SESSION_ID="${WTD_SESSION_ID:-wtd-$$-$(git -C "$WORKTREE_PATH" rev-parse --short HEAD 2>/dev/null || echo nohead)}"

# Optional event bridge: WTD_EVENT_SINK is a command that receives
#   "<event> <session_id> <cli> <worktree_path> <launcher_pid> [exit_code]"
# <launcher_pid> is THIS launcher process ($$) — it stays alive for the whole
# agent session, so a sink that tracks liveness can treat it as the owning pid.
_emit_event() {
    [[ -n "${WTD_EVENT_SINK:-}" ]] || return 0
    # shellcheck disable=SC2086
    ${WTD_EVENT_SINK} "$1" "$SESSION_ID" "$CLI_COMMAND" "$WORKTREE_PATH" "$$" "${2:-}" >/dev/null 2>&1 || true
}

# Process-level crash resilience (WTD_TMUX_RESUME): re-exec inside a stable
# per-worktree+CLI tmux session so the agent survives a terminal crash, quit, or
# SSH drop. `new-session -A` attaches when the session already exists, so a
# re-launch (or the <n>r resume action) returns to the SAME live process instead
# of starting a duplicate — and the resume flags ($3) are simply ignored on
# attach. Skipped when disabled, tmux is absent, not a TTY (headless/piped
# launches keep raw stdout), or already inside tmux ($TMUX — also the recursion
# guard). WTD_SESSION_ID is threaded through so event correlation is stable.
if [[ "${WTD_TMUX_RESUME:-auto}" != "off" \
      && -z "${TMUX:-}" \
      && -t 0 && -t 1 ]] \
   && command -v tmux >/dev/null 2>&1; then
    _wtd_tmux_mode="${WTD_TMUX_RESUME:-auto}"
    if [[ "$_wtd_tmux_mode" == "auto" ]]; then
        if [[ "${TERM_PROGRAM:-}" == "iTerm.app" ]]; then
            _wtd_tmux_mode="cc"
        else
            _wtd_tmux_mode="plain"
        fi
    fi
    _wtd_cc=()
    [[ "$_wtd_tmux_mode" == "cc" ]] && _wtd_cc=(-CC)

    _wtd_session="$(wtd_tmux_session_name "$WORKTREE_PATH" "$CLI_COMMAND")"
    _wtd_relaunch="exec $(printf '%q' "${LIB_DIR}/launch-worktree-cli.sh")"
    _wtd_relaunch+=" $(printf '%q' "$WORKTREE_PATH") $(printf '%q' "$LAUNCH_FLAG")"
    [[ -n "$EXTRA_CLI_ARGS" ]] && _wtd_relaunch+=" $(printf '%q' "$EXTRA_CLI_ARGS")"

    exec tmux "${_wtd_cc[@]}" new-session -A -s "$_wtd_session" -c "$WORKTREE_PATH" \
        -e "WTD_SESSION_ID=$SESSION_ID" \
        "$_wtd_relaunch"
fi

# Set the terminal title (best-effort; harmless if unsupported).
printf '\033]0;%s — %s\007' "$(basename "$WORKTREE_PATH")" "$LABEL" 2>/dev/null || true

cd "$WORKTREE_PATH"
export WTD_PROJECT_DIR="$WORKTREE_PATH" WTD_SESSION_ID="$SESSION_ID"

_emit_event started
rc=0
# shellcheck disable=SC2086
${CLI_COMMAND} ${EXTRA_CLI_ARGS} || rc=$?
if [[ $rc -eq 0 ]]; then
    _emit_event completed "$rc"
else
    _emit_event failed "$rc"
fi
exit $rc
