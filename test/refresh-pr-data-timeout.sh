#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

make_temp_repo() {
    local repo
    repo="$(mktemp -d "${TMPDIR:-/tmp}/wtd-pr-repo.XXXXXX")"
    git -C "$repo" init -q
    printf '%s\n' "$repo"
}

make_fake_gh() {
    local dir="$1"
    local sleep_for="${2:-0}"
    local fail="${3:-0}"
    local output="${4:-}"
    cat > "$dir/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${FAKE_GH_LOG:-/dev/null}"
sleep "__FAKE_GH_SLEEP__"
if [[ "__FAKE_GH_FAIL__" == "1" ]]; then
    exit 1
fi
printf '%b' "__FAKE_GH_OUTPUT__"
FAKE_GH
    python3 - "$dir/gh" "$sleep_for" "$fail" "$output" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace("__FAKE_GH_SLEEP__", sys.argv[2])
text = text.replace("__FAKE_GH_FAIL__", sys.argv[3])
text = text.replace("__FAKE_GH_OUTPUT__", sys.argv[4].replace("\\", "\\\\").replace('"', '\\"'))
path.write_text(text)
PY
    chmod +x "$dir/gh"
}

extract_refresh_pr_data() {
    # refresh_pr_data lives in lib/pr-metadata.sh (BOU-1690 WS4 decomposition).
    awk '
        /^refresh_pr_data\(\) \{/ { in_fn=1 }
        in_fn { print }
        in_fn && /^}/ { exit }
    ' "$ROOT/lib/pr-metadata.sh"
}

run_refresh() {
    local repo="$1"
    local runner
    runner="$(mktemp "${TMPDIR:-/tmp}/wtd-pr-runner.XXXXXX")"
    {
        printf 'set -euo pipefail\n'
        printf 'MAIN_REPO=%q\n' "$repo"
        printf 'PR_DATA=\n'
        printf 'PR_DATA_AVAILABLE=0\n'
        printf 'PR_DATA_REFRESH_TIMED_OUT=0\n'
        extract_refresh_pr_data
        cat <<'RUNNER'
start="$(python3 -c 'import time; print(time.time())')"
refresh_pr_data
elapsed="$(python3 -c 'import sys, time; print(time.time() - float(sys.argv[1]))' "$start")"
printf 'elapsed=%s\n' "$elapsed"
printf 'available=%s\n' "$PR_DATA_AVAILABLE"
printf 'timed_out=%s\n' "${PR_DATA_REFRESH_TIMED_OUT:-0}"
printf 'data=%s\n' "$PR_DATA"
RUNNER
    } > "$runner"
        FAKE_GH_LOG="${FAKE_GH_LOG:-}" \
        WTD_GH_PR_TIMEOUT_SECONDS="${WTD_GH_PR_TIMEOUT_SECONDS:-}" \
        bash "$runner"
}

test_slow_gh_times_out() {
    local repo fake_bin output elapsed available old_path
    repo="$(make_temp_repo)"
    fake_bin="$(mktemp -d "${TMPDIR:-/tmp}/wtd-fake-gh.XXXXXX")"
    make_fake_gh "$fake_bin" 3

    old_path="$PATH"
    PATH="$fake_bin:$PATH"
    export PATH
    output="$(WTD_GH_PR_TIMEOUT_SECONDS=1 run_refresh "$repo")"
    PATH="$old_path"
    export PATH
    elapsed="$(awk -F= '/^elapsed=/{print $2}' <<< "$output")"
    available="$(awk -F= '/^available=/{print $2}' <<< "$output")"

    python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) < 2.5 else 1)' "$elapsed" \
        || fail "slow gh was not bounded; elapsed=${elapsed}; output=${output}"
    [[ "$available" == "0" ]] || fail "timed-out gh should leave PR data unavailable; output=${output}"
    [[ "$(awk -F= '/^timed_out=/{print $2}' <<< "$output")" == "1" ]] \
        || fail "timed-out gh should record timeout state; output=${output}"
}

test_fast_gh_has_no_one_second_floor() {
    local repo fake_bin output elapsed old_path
    repo="$(make_temp_repo)"
    fake_bin="$(mktemp -d "${TMPDIR:-/tmp}/wtd-fake-gh.XXXXXX")"
    make_fake_gh "$fake_bin" 0.1

    old_path="$PATH"
    PATH="$fake_bin:$PATH"
    export PATH
    output="$(WTD_GH_PR_TIMEOUT_SECONDS=2 run_refresh "$repo")"
    PATH="$old_path"
    export PATH
    elapsed="$(awk -F= '/^elapsed=/{print $2}' <<< "$output")"

    python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) < 0.75 else 1)' "$elapsed" \
        || fail "fast gh hit an avoidable latency floor; elapsed=${elapsed}; output=${output}"
}

test_fast_gh_populates_pr_data() {
    local repo fake_bin output available data old_path
    repo="$(make_temp_repo)"
    fake_bin="$(mktemp -d "${TMPDIR:-/tmp}/wtd-fake-gh.XXXXXX")"
    make_fake_gh "$fake_bin" 0 0 $'feature/demo\t7\tOPEN\tabc123\n'

    old_path="$PATH"
    PATH="$fake_bin:$PATH"
    export PATH
    output="$(run_refresh "$repo")"
    PATH="$old_path"
    export PATH
    available="$(awk -F= '/^available=/{print $2}' <<< "$output")"
    data="$(sed -n 's/^data=//p' <<< "$output")"

    [[ "$available" == "1" ]] || fail "fast gh should mark PR data available; output=${output}"
    [[ "$data" == $'feature/demo\t7\tOPEN\tabc123' ]] || fail "PR data not captured; output=${output}"
}

test_stale_cleanup_branch_lookup_respects_bulk_timeout() {
    awk '
        /PR_DATA_REFRESH_TIMED_OUT/ { saw_timeout_guard=1 }
        /gh pr list --head/ {
            if (!saw_timeout_guard) {
                exit 1
            }
            saw_branch_lookup=1
        }
        END {
            exit !(saw_timeout_guard && saw_branch_lookup)
        }
    ' "$ROOT/lib/cleanup.sh" \
        || fail "per-branch gh fallback is not guarded by PR_DATA_REFRESH_TIMED_OUT"
}

test_slow_gh_times_out
test_fast_gh_has_no_one_second_floor
test_fast_gh_populates_pr_data
test_stale_cleanup_branch_lookup_respects_bulk_timeout
echo "refresh-pr-data-timeout: ok"
