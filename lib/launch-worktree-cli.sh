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
    # A managed fresh-session supervisor is the canonical lifecycle owner.
    # Suppress this legacy bridge when invoked anywhere beneath that owner so
    # the same child does not produce duplicate started/completed/failed events.
    [[ "${WTD_MANAGED_EVENT_OWNER:-}" != "1" ]] || return 0
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

    # Propagate the launcher's environment into the tmux pane. New panes only see
    # tmux's global/session environment (the client's env is copied solely via
    # `update-environment` or explicit `-e`), so a tmux server that was already
    # running before the user exported OPENAI_API_KEY / ANTHROPIC_API_KEY /
    # GITHUB_TOKEN / a project PATH / WORKTREE_DECK_CONFIG would otherwise relaunch
    # the agent unauthenticated or with stale config. We bake the relevant vars
    # into the relaunched command via `env`, which works on every tmux version and
    # does not depend on `-e` / `update-environment`. WTD_SESSION_ID is included
    # here so event correlation stays stable regardless of tmux version.
    _wtd_env_prefix="env"
    for _wtd_var in WTD_SESSION_ID WTD_MANAGED_EVENT_OWNER \
                    WORKTREE_DECK_CONFIG WTD_EVENT_SINK PATH \
                    OPENAI_API_KEY ANTHROPIC_API_KEY GITHUB_TOKEN GH_TOKEN \
                    HOME LANG LC_ALL TERM; do
        if [[ "$_wtd_var" == "WTD_SESSION_ID" ]]; then
            _wtd_env_prefix+=" WTD_SESSION_ID=$(printf '%q' "$SESSION_ID")"
        elif [[ -n "${!_wtd_var+x}" ]]; then
            _wtd_env_prefix+=" $(printf '%q' "$_wtd_var")=$(printf '%q' "${!_wtd_var}")"
        fi
    done

    _wtd_relaunch="exec ${_wtd_env_prefix} $(printf '%q' "${LIB_DIR}/launch-worktree-cli.sh")"
    _wtd_relaunch+=" $(printf '%q' "$WORKTREE_PATH") $(printf '%q' "$LAUNCH_FLAG")"
    [[ -n "$EXTRA_CLI_ARGS" ]] && _wtd_relaunch+=" $(printf '%q' "$EXTRA_CLI_ARGS")"

    # Avoid attaching to an already-exited pane. With `remain-on-exit on` (or
    # `set -g remain-on-exit failed`) in the user's tmux config, a pane survives
    # after its agent process exits instead of being destroyed; `new-session -A`
    # would then re-attach to that dead pane and never run the fresh/resume
    # command. If our managed session already exists but its pane is dead, tear it
    # down so the launch below starts a live one. (Best-effort: ignore errors.)
    if tmux "${_wtd_cc[@]}" has-session -t "=$_wtd_session" 2>/dev/null; then
        _wtd_dead="$(tmux "${_wtd_cc[@]}" list-panes -t "=$_wtd_session" \
            -F '#{pane_dead}' 2>/dev/null | grep -c '^1$' || true)"
        _wtd_alive="$(tmux "${_wtd_cc[@]}" list-panes -t "=$_wtd_session" \
            -F '#{pane_dead}' 2>/dev/null | grep -c '^0$' || true)"
        if [[ "${_wtd_alive:-0}" -eq 0 && "${_wtd_dead:-0}" -gt 0 ]]; then
            tmux "${_wtd_cc[@]}" kill-session -t "=$_wtd_session" 2>/dev/null || true
        fi
    fi

    # Gate `-e` on tmux 3.2+: `new-session ... -e ENV=VAL` is only documented from
    # tmux 3.2 onward (3.1c's new-session has no -e), so passing it unconditionally
    # makes older tmux exit with an unknown-option error and never launch the agent.
    # Our env is already baked into the relaunch command above, so `-e` is purely a
    # belt-and-suspenders for WTD_SESSION_ID — only add it when tmux is new enough.
    _wtd_tmux_ver="$(tmux -V 2>/dev/null | sed -E 's/^tmux[[:space:]]+//')"
    _wtd_e_flag=()
    if [[ "$_wtd_tmux_ver" =~ ^([0-9]+)\.([0-9]+) ]]; then
        _wtd_major="${BASH_REMATCH[1]}"; _wtd_minor="${BASH_REMATCH[2]}"
        if [[ "$_wtd_major" -gt 3 || ( "$_wtd_major" -eq 3 && "$_wtd_minor" -ge 2 ) ]]; then
            _wtd_e_flag=(-e "WTD_SESSION_ID=$SESSION_ID")
        fi
    fi

    exec tmux "${_wtd_cc[@]}" new-session -A -s "$_wtd_session" -c "$WORKTREE_PATH" \
        "${_wtd_e_flag[@]}" \
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
