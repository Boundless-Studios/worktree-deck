#!/usr/bin/env bash
# Launch an interactive CLI from a Gaia worktree with consistent terminal context.
#
# Usage:
#   launch-worktree-cli.sh <worktree-path> [--codex|--claude] [prompt...]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/worktree-launch-mode.sh"

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <worktree-path> [--codex|--claude] [prompt...]" >&2
    exit 2
fi

WORKTREE_PATH="$1"
shift

LAUNCH_FLAG="$(gaia_default_launch_flag)"
if gaia_is_launch_selector "${1:-}"; then
    LAUNCH_FLAG="$(gaia_normalize_launch_flag "$1")"
    shift
fi

LABEL="$(gaia_launch_label_from_flag "$LAUNCH_FLAG")"
CLI_COMMAND="$(gaia_launch_cli_from_flag "$LAUNCH_FLAG")"
BRANCH_NAME="$(git -C "$WORKTREE_PATH" branch --show-current 2>/dev/null || echo "")"

export GAIA_SESSION_ID="${GAIA_SESSION_ID:-gaia-$(date +%s)-$$}"
export GAIA_SESSION_CLI="$CLI_COMMAND"
export GAIA_SESSION_LAUNCH_SOURCE="${GAIA_SESSION_LAUNCH_SOURCE:-launch-worktree-cli}"
export GAIA_PROJECT_DIR="$WORKTREE_PATH"

# Mark feature-pipeline sessions so the PR dashboard's ownership detector can
# distinguish them from a generic Claude/Codex session a developer happens to
# have open on the worktree. The dashboard only defers PR maintenance to a
# real feature-pipeline session; deferring to a generic session would leave the
# handoff unattended.
GAIA_SESSION_FEATURE_PIPELINE_DETECTED=""
case " $* " in
    *"/feature-pipeline"*|*"feature-pipeline:"*)
        GAIA_SESSION_FEATURE_PIPELINE_DETECTED="1" ;;
esac
export GAIA_SESSION_FEATURE_PIPELINE="${GAIA_SESSION_FEATURE_PIPELINE:-$GAIA_SESSION_FEATURE_PIPELINE_DETECTED}"

record_session_event() {
    local event="$1"
    local exit_code="${2:-}"
    local args=(
        -m pr_dashboard.session_registry record
        --event "$event"
        --session-id "$GAIA_SESSION_ID"
        --cli "$GAIA_SESSION_CLI"
        --launch-source "$GAIA_SESSION_LAUNCH_SOURCE"
        --pid "$$"
        --ppid "$PPID"
        --worktree-path "$WORKTREE_PATH"
    )
    if [[ -n "$BRANCH_NAME" ]]; then
        args+=(--branch "$BRANCH_NAME")
    fi
    if [[ "${GAIA_SESSION_FEATURE_PIPELINE:-}" == "1" ]]; then
        args+=(--feature-pipeline)
    fi
    if [[ -n "$exit_code" ]]; then
        args+=(--exit-code "$exit_code")
        if [[ "$event" == "failed" ]]; then
            args+=(--failure-reason "${CLI_COMMAND} exited with code ${exit_code}")
        fi
    fi
    python3 "${args[@]}" >/dev/null 2>&1 || true
}

if [[ "$CLI_COMMAND" == "codex" ]]; then
    CLI_ARGS=(
        "$CLI_COMMAND"
        "-c" "features.codex_hooks=true"
        "--dangerously-bypass-approvals-and-sandbox"
        "$@"
    )
else
    CLI_ARGS=("$CLI_COMMAND" "$@")
fi

short_name() {
    local worktree_path="$1"
    local branch
    branch=$(git -C "$worktree_path" branch --show-current 2>/dev/null || echo "")
    if [[ -z "$branch" || "$branch" == "main" || "$branch" == "master" ]]; then
        echo "main"
    else
        echo "$branch" | sed -E 's#^(feature|fix|chore|hotfix|release)/##; s#/#-#g'
    fi
}

resolve_warden_hook() {
    if command -v warden-hook >/dev/null 2>&1; then
        command -v warden-hook
        return 0
    fi

    local user_shell="${SHELL:-/bin/zsh}"
    if [[ -x "$user_shell" ]]; then
        "$user_shell" -lic 'command -v warden-hook' 2>/dev/null | head -n1
    fi
}

gh_timeout() {
    local timeout_bin=""
    if command -v timeout >/dev/null 2>&1; then
        timeout_bin="timeout"
    elif command -v gtimeout >/dev/null 2>&1; then
        timeout_bin="gtimeout"
    fi

    if [[ -n "$timeout_bin" ]]; then
        "$timeout_bin" 3 gh "$@" 2>/dev/null
    else
        gh "$@" 2>/dev/null
    fi
}

set_iterm_tab_color() {
    local color="${1:-}"
    [[ -t 1 ]] || return 0
    [[ "${TERM_PROGRAM:-}" == "iTerm.app" ]] || return 0

    local red green blue
    case "$color" in
        green) red=45; green=170; blue=70 ;;
        blue) red=45; green=105; blue=220 ;;
        red) red=205; green=55; blue=55 ;;
        yellow) red=220; green=175; blue=45 ;;
        *) return 0 ;;
    esac

    printf '\033]6;1;bg;red;brightness;%d\a' "$red" > /dev/tty 2>/dev/null || true
    printf '\033]6;1;bg;green;brightness;%d\a' "$green" > /dev/tty 2>/dev/null || true
    printf '\033]6;1;bg;blue;brightness;%d\a' "$blue" > /dev/tty 2>/dev/null || true
}

set_terminal_context() {
    [[ -t 1 ]] || return 0

    local branch worktree_name pr_num frontend_port title badge
    branch=$(git -C "$WORKTREE_PATH" branch --show-current 2>/dev/null || echo "unknown")
    worktree_name=$(short_name "$WORKTREE_PATH")
    pr_num=""

    if command -v gh >/dev/null 2>&1 && [[ "$branch" != "main" && "$branch" != "master" && "$branch" != "unknown" ]]; then
        pr_num=$(gh_timeout pr list --head "$branch" --state open --json number --jq '.[0].number' || true)
        [[ "$pr_num" == "null" ]] && pr_num=""
    fi

    frontend_port=""
    if [[ -f "$WORKTREE_PATH/.env" ]]; then
        frontend_port=$(grep '^FRONTEND_PORT=' "$WORKTREE_PATH/.env" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]' || true)
    fi

    title=""
    if [[ -n "$pr_num" ]]; then
        title="PR #${pr_num}  "
    fi
    if [[ -n "$frontend_port" ]]; then
        title="${title}:${frontend_port}  "
    fi
    title="${title}wc  ${worktree_name}"
    badge="${branch:-$worktree_name}"

    printf '\033]0;%s\a' "$title" > /dev/tty 2>/dev/null || true

    if [[ "${TERM_PROGRAM:-}" == "iTerm.app" ]] && command -v base64 >/dev/null 2>&1; then
        local badge_b64
        badge_b64=$(printf '%s' "$badge" | base64)
        printf '\033]1337;SetBadgeFormat=%s\a' "$badge_b64" > /dev/tty 2>/dev/null || true

        if [[ "$CLI_COMMAND" == "codex" ]]; then
            set_iterm_tab_color blue
        fi
    fi
}

cd "$WORKTREE_PATH"
record_session_event started

# Keep Serena bounded to the selected worktree. Without a local project.yml,
# Serena can walk up to a broad parent project and start expensive TypeScript
# indexing across sibling worktrees.
bash "$SCRIPT_DIR/setup-serena-worktree.sh" --quiet "$WORKTREE_PATH" || true

resolved_warden_hook="${WARDEN_HOOK_PATH:-$(resolve_warden_hook || true)}"
if [[ -n "${resolved_warden_hook:-}" ]]; then
    export WARDEN_HOOK_PATH="$resolved_warden_hook"
    resolved_warden_dir="$(dirname "$resolved_warden_hook")"
    case ":$PATH:" in
        *":$resolved_warden_dir:"*) ;;
        *) export PATH="$resolved_warden_dir:$PATH" ;;
    esac
fi

# Show banner when possible, but do not block CLI startup on banner errors.
bash scripts/worktree-banner.sh || echo "Warning: failed to render worktree banner." >&2
set_terminal_context

if command -v "$CLI_COMMAND" >/dev/null 2>&1; then
    set +e
    "${CLI_ARGS[@]}"
    rc=$?
    set -e
    if [[ "$CLI_COMMAND" == "codex" ]]; then
        set_iterm_tab_color green
    fi
    if [[ "$rc" -eq 0 ]]; then
        record_session_event completed "$rc"
    else
        record_session_event failed "$rc"
    fi
    exit "$rc"
fi

user_shell="${SHELL:-/bin/zsh}"
if [[ -x "$user_shell" ]] && "$user_shell" -lic "command -v $CLI_COMMAND >/dev/null 2>&1"; then
    quoted_args=""
    for arg in "${CLI_ARGS[@]}"; do
        quoted_args="${quoted_args} $(printf '%q' "$arg")"
    done
    if [[ "$CLI_COMMAND" == "codex" ]]; then
        done_color_cmd="if [[ \"\${TERM_PROGRAM:-}\" == \"iTerm.app\" ]]; then printf '\\033]6;1;bg;red;brightness;45\\a\\033]6;1;bg;green;brightness;170\\a\\033]6;1;bg;blue;brightness;70\\a' > /dev/tty 2>/dev/null || true; fi"
        exec "$user_shell" -lic "cd $(printf '%q' "$WORKTREE_PATH") && export GAIA_PROJECT_DIR=$(printf '%q' "$WORKTREE_PATH") GAIA_SESSION_ID=$(printf '%q' "$GAIA_SESSION_ID") GAIA_SESSION_CLI=$(printf '%q' "$GAIA_SESSION_CLI") GAIA_SESSION_LAUNCH_SOURCE=$(printf '%q' "$GAIA_SESSION_LAUNCH_SOURCE") &&${quoted_args}; rc=\$?; ${done_color_cmd}; if [[ \$rc -eq 0 ]]; then python3 -m pr_dashboard.session_registry record --event completed --session-id $(printf '%q' "$GAIA_SESSION_ID") --cli $(printf '%q' "$GAIA_SESSION_CLI") --launch-source $(printf '%q' "$GAIA_SESSION_LAUNCH_SOURCE") --worktree-path $(printf '%q' "$WORKTREE_PATH") --exit-code \$rc >/dev/null 2>&1 || true; else python3 -m pr_dashboard.session_registry record --event failed --session-id $(printf '%q' "$GAIA_SESSION_ID") --cli $(printf '%q' "$GAIA_SESSION_CLI") --launch-source $(printf '%q' "$GAIA_SESSION_LAUNCH_SOURCE") --worktree-path $(printf '%q' "$WORKTREE_PATH") --exit-code \$rc --failure-reason $(printf '%q' "${CLI_COMMAND} exited") >/dev/null 2>&1 || true; fi; exit \$rc"
    fi
    exec "$user_shell" -lic "cd $(printf '%q' "$WORKTREE_PATH") && export GAIA_PROJECT_DIR=$(printf '%q' "$WORKTREE_PATH") GAIA_SESSION_ID=$(printf '%q' "$GAIA_SESSION_ID") GAIA_SESSION_CLI=$(printf '%q' "$GAIA_SESSION_CLI") GAIA_SESSION_LAUNCH_SOURCE=$(printf '%q' "$GAIA_SESSION_LAUNCH_SOURCE") &&${quoted_args}; rc=\$?; if [[ \$rc -eq 0 ]]; then python3 -m pr_dashboard.session_registry record --event completed --session-id $(printf '%q' "$GAIA_SESSION_ID") --cli $(printf '%q' "$GAIA_SESSION_CLI") --launch-source $(printf '%q' "$GAIA_SESSION_LAUNCH_SOURCE") --worktree-path $(printf '%q' "$WORKTREE_PATH") --exit-code \$rc >/dev/null 2>&1 || true; else python3 -m pr_dashboard.session_registry record --event failed --session-id $(printf '%q' "$GAIA_SESSION_ID") --cli $(printf '%q' "$GAIA_SESSION_CLI") --launch-source $(printf '%q' "$GAIA_SESSION_LAUNCH_SOURCE") --worktree-path $(printf '%q' "$WORKTREE_PATH") --exit-code \$rc --failure-reason $(printf '%q' "${CLI_COMMAND} exited") >/dev/null 2>&1 || true; fi; exit \$rc"
fi

echo "${CLI_COMMAND} not found in PATH." >&2
echo "Install it or add it to your shell PATH, then retry." >&2
record_session_event failed 127
exit 127
