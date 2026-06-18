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
    cat > "$dir/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail
sleep "${FAKE_GH_SLEEP:-0}"
if [[ "${FAKE_GH_FAIL:-0}" == "1" ]]; then
    exit 1
fi
printf '%b' "${FAKE_GH_OUTPUT:-}"
FAKE_GH
    chmod +x "$dir/gh"
}

extract_refresh_pr_data() {
    awk '
        /^refresh_pr_data\(\) \{/ { in_fn=1 }
        in_fn { print }
        in_fn && /^}/ { exit }
    ' "$ROOT/bin/worktree-deck.sh"
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
        extract_refresh_pr_data
        cat <<'RUNNER'
start="$(date +%s)"
refresh_pr_data
elapsed="$(( $(date +%s) - start ))"
printf 'elapsed=%s\n' "$elapsed"
printf 'available=%s\n' "$PR_DATA_AVAILABLE"
printf 'data=%s\n' "$PR_DATA"
RUNNER
    } > "$runner"
    bash "$runner"
}

test_slow_gh_times_out() {
    local repo fake_bin output elapsed available
    repo="$(make_temp_repo)"
    fake_bin="$(mktemp -d "${TMPDIR:-/tmp}/wtd-fake-gh.XXXXXX")"
    make_fake_gh "$fake_bin"

    output="$(PATH="$fake_bin:$PATH" FAKE_GH_SLEEP=3 WTD_GH_PR_TIMEOUT_SECONDS=1 run_refresh "$repo")"
    elapsed="$(awk -F= '/^elapsed=/{print $2}' <<< "$output")"
    available="$(awk -F= '/^available=/{print $2}' <<< "$output")"

    [[ "$elapsed" -lt 3 ]] || fail "slow gh was not bounded; elapsed=${elapsed}; output=${output}"
    [[ "$available" == "0" ]] || fail "timed-out gh should leave PR data unavailable; output=${output}"
}

test_fast_gh_populates_pr_data() {
    local repo fake_bin output available data
    repo="$(make_temp_repo)"
    fake_bin="$(mktemp -d "${TMPDIR:-/tmp}/wtd-fake-gh.XXXXXX")"
    make_fake_gh "$fake_bin"

    output="$(PATH="$fake_bin:$PATH" FAKE_GH_OUTPUT=$'feature/demo\t7\tOPEN\tabc123\n' run_refresh "$repo")"
    available="$(awk -F= '/^available=/{print $2}' <<< "$output")"
    data="$(sed -n 's/^data=//p' <<< "$output")"

    [[ "$available" == "1" ]] || fail "fast gh should mark PR data available; output=${output}"
    [[ "$data" == $'feature/demo\t7\tOPEN\tabc123' ]] || fail "PR data not captured; output=${output}"
}

test_slow_gh_times_out
test_fast_gh_populates_pr_data
echo "refresh-pr-data-timeout: ok"
