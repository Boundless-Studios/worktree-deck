#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_BASE="${TMPDIR:-/tmp}"
TMP_ROOT="$(mktemp -d "${TMP_BASE%/}/wtd-launch-cli.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_eq() {
    local expected="$1" actual="$2" label="$3"
    [[ "$actual" == "$expected" ]] \
        || fail "$label: got '$actual', expected '$expected'"
}

WORKTREE="$TMP_ROOT/worktree with spaces"
FAKE_BIN="$TMP_ROOT/bin"
CLI_LOG="$TMP_ROOT/cli.log"
EVENT_LOG="$TMP_ROOT/events.log"
mkdir -p "$WORKTREE" "$FAKE_BIN"

cat > "$FAKE_BIN/codex" <<'FAKE_CLI'
#!/usr/bin/env bash
set -euo pipefail
{
    printf 'pid=%s|ppid=%s|project=%s|session=%s' \
        "$$" "$PPID" "${WTD_PROJECT_DIR:-}" "${WTD_SESSION_ID:-}"
    printf '|%s' "$@"
    printf '\n'
} >> "${CLI_LOG:?}"
exit "${FAKE_EXIT_CODE:-0}"
FAKE_CLI

cat > "$FAKE_BIN/event-sink" <<'FAKE_SINK'
#!/usr/bin/env bash
set -euo pipefail
{
    printf '%s' "$1"
    shift
    printf '|%s' "$@"
    printf '\n'
} >> "${EVENT_LOG:?}"
FAKE_SINK
chmod +x "$FAKE_BIN/codex" "$FAKE_BIN/event-sink"

run_launcher() {
    PATH="$FAKE_BIN:$PATH" \
    WORKTREE_DECK_CONFIG="$TMP_ROOT/missing-config" \
    WTD_TMUX_RESUME=off \
    WTD_SESSION_ID="opaque-session" \
    WTD_EVENT_SINK="$FAKE_BIN/event-sink" \
    CLI_LOG="$CLI_LOG" \
    EVENT_LOG="$EVENT_LOG" \
    FAKE_EXIT_CODE="${FAKE_EXIT_CODE:-0}" \
    WTD_MANAGED_EVENT_OWNER="${WTD_MANAGED_EVENT_OWNER:-}" \
        "$ROOT/lib/launch-worktree-cli.sh" "$WORKTREE" --codex "${1:-}"
}

read_events() {
    local event
    events=()
    while IFS= read -r event; do
        events[${#events[@]}]="$event"
    done < "$EVENT_LOG"
}

run_launcher ""
read_events
assert_eq 2 "${#events[@]}" "legacy event count"
assert_eq "started" "${events[0]%%|*}" "legacy start event"
assert_eq "completed" "${events[1]%%|*}" "legacy completed event"
launcher_pid="$(cut -d'|' -f5 <<< "${events[0]}")"
cli_ppid="$(sed -n 's/^.*|ppid=\([^|]*\).*$/\1/p' "$CLI_LOG")"
assert_eq "$launcher_pid" "$cli_ppid" "event owner is long-lived launcher"

: > "$EVENT_LOG"
: > "$CLI_LOG"
FAKE_EXIT_CODE=7
export FAKE_EXIT_CODE
set +e
run_launcher ""
rc=$?
set -e
assert_eq 7 "$rc" "child exit propagation"
read_events
assert_eq "started" "${events[0]%%|*}" "failure start event"
assert_eq "failed" "${events[1]%%|*}" "failure event"
assert_eq 7 "${events[1]##*|}" "failure exit code"

: > "$EVENT_LOG"
: > "$CLI_LOG"
FAKE_EXIT_CODE=0
WTD_MANAGED_EVENT_OWNER=1
export FAKE_EXIT_CODE WTD_MANAGED_EVENT_OWNER
run_launcher ""
[[ ! -s "$EVENT_LOG" ]] \
    || fail "managed event owner produced duplicate lifecycle events"
[[ -s "$CLI_LOG" ]] || fail "managed event owner did not launch child"

echo "PASS: built-in launcher lifecycle ownership"
