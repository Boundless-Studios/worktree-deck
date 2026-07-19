#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_BASE="${TMPDIR:-/tmp}"
TMP_ROOT="$(mktemp -d "${TMP_BASE%/}/wtd-terminal-launch.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_file_eq() {
    local expected="$1" path="$2" label="$3"
    local actual=""
    [[ -f "$path" ]] && actual="$(cat "$path")"
    [[ "$actual" == "$expected" ]] \
        || fail "$label: got '$actual', expected '$expected'"
}

WORKTREE="$TMP_ROOT/worktree with spaces"
mkdir -p "$WORKTREE"
LEGACY_LOG="$TMP_ROOT/legacy.log"
MANAGED_LOG="$TMP_ROOT/managed.log"
NORMALIZE_LOG="$TMP_ROOT/normalize.log"
LEGACY="$TMP_ROOT/legacy-launcher"
MANAGED="$TMP_ROOT/managed-launcher"

cat > "$LEGACY" <<'RECORDER'
#!/usr/bin/env bash
set -euo pipefail
{
    printf 'legacy'
    printf '|%s' "$@"
    printf '|owner=%s|session=%s|project=%s|pwd=%s\n' \
        "${WTD_MANAGED_EVENT_OWNER:-}" \
        "${WTD_SESSION_ID:-}" \
        "${WTD_PROJECT_DIR:-}" \
        "$PWD"
} >> "${LEGACY_LOG:?}"
RECORDER
cat > "$MANAGED" <<'RECORDER'
#!/usr/bin/env bash
set -euo pipefail
{
    printf 'managed'
    printf '|%s' "$@"
    printf '|owner=%s|session=%s|project=%s|pwd=%s\n' \
        "${WTD_MANAGED_EVENT_OWNER:-}" \
        "${WTD_SESSION_ID:-}" \
        "${WTD_PROJECT_DIR:-}" \
        "$PWD"
} >> "${MANAGED_LOG:?}"
RECORDER
chmod +x "$LEGACY" "$MANAGED"

export LEGACY_LOG MANAGED_LOG
export BLUE="" YELLOW="" NC=""
export LIB_DIR="$ROOT/lib"
short_name() { basename "$1"; }

# shellcheck source=/dev/null
source "$ROOT/lib/config.sh"
# shellcheck source=/dev/null
source "$ROOT/lib/worktree-launch-mode.sh"
# shellcheck source=/dev/null
source "$ROOT/lib/terminal.sh"

declare -F launch_worktree_agent >/dev/null \
    || fail "launch_worktree_agent is not implemented"

# Project hooks may make normalization observable. The disabled managed seam
# must not add a second call on top of the unchanged legacy launch path.
wtd_normalize_launch_flag() {
    printf '%s\n' "$1" >> "$NORMALIZE_LOG"
    case "$1" in
        codex|--codex) printf '%s\n' --codex ;;
        claude|--claude) printf '%s\n' --claude ;;
        *) return 1 ;;
    esac
}

export WTD_LAUNCH_CMD="$LEGACY"
export WTD_MANAGED_FRESH_CMD=""
launch_worktree_agent "$WORKTREE" codex "Codex CLI" "prompt with spaces"
assert_file_eq \
    "legacy|$WORKTREE|--codex|prompt with spaces|owner=|session=|project=|pwd=$WORKTREE" \
    "$LEGACY_LOG" \
    "legacy fresh dispatch"
assert_file_eq "codex" "$NORMALIZE_LOG" "legacy selector normalized once"
[[ ! -e "$MANAGED_LOG" ]] || fail "managed command ran while disabled"

: > "$LEGACY_LOG"
: > "$NORMALIZE_LOG"
export WTD_MANAGED_FRESH_CMD="$MANAGED"
export WTD_SESSION_ID="opaque-deck-session"
launch_worktree_agent "$WORKTREE" claude "Claude Code" "one prompt argument"
assert_file_eq "" "$LEGACY_LOG" "legacy launcher bypassed in managed mode"
assert_file_eq \
    "managed|$WORKTREE|--claude|one prompt argument|owner=1|session=opaque-deck-session|project=$WORKTREE|pwd=$WORKTREE" \
    "$MANAGED_LOG" \
    "managed fresh dispatch"
assert_file_eq "claude" "$NORMALIZE_LOG" "managed selector normalized once"

: > "$LEGACY_LOG"
: > "$MANAGED_LOG"
wtd_last_agent_cli() { printf '%s\n' codex; }
resume_worktree_agent "$WORKTREE" codex "Codex CLI"
assert_file_eq \
    "legacy|$WORKTREE|--codex|resume --last|owner=|session=opaque-deck-session|project=|pwd=$WORKTREE" \
    "$LEGACY_LOG" \
    "manual resume stays legacy"
assert_file_eq "" "$MANAGED_LOG" "manual resume bypasses managed command"

echo "PASS: terminal managed fresh dispatch"
