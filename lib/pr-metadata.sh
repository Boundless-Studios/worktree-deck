#!/usr/bin/env bash
# PR metadata cache helpers for worktree-deck.
#
# Fetches and queries GitHub PR state for the worktrees listed in the console.
# All functions read/write the PR_DATA / PR_DATA_AVAILABLE globals defined in
# bin/worktree-deck.sh.

# Refresh PR metadata cache from GitHub.
refresh_pr_data() {
    PR_DATA=""
    PR_DATA_AVAILABLE=0
    PR_DATA_REFRESH_TIMED_OUT=0

    if ! command -v gh &>/dev/null; then
        return
    fi

    local gh_timeout="${WTD_GH_PR_TIMEOUT_SECONDS:-2}"
    [[ "$gh_timeout" =~ ^[0-9]+$ ]] || gh_timeout=2
    [[ "$gh_timeout" -gt 0 ]] || gh_timeout=2

    # Don't gate on `gh auth status`; environments with GH_TOKEN may fail status
    # but still allow successful `gh pr list`.
    local pr_data_file pr_pid remaining_ticks
    pr_data_file="$(mktemp -t wtd-pr-data.XXXXXX)"
    (
        cd "$MAIN_REPO" || exit 1
        exec gh pr list --state all --limit 500 --json number,state,headRefName,headRefOid --template '{{range .}}{{.headRefName}}{{"\t"}}{{.number}}{{"\t"}}{{.state}}{{"\t"}}{{.headRefOid}}{{"\n"}}{{end}}'
    ) >"$pr_data_file" 2>/dev/null &
    pr_pid=$!
    remaining_ticks=$((gh_timeout * 20))
    while kill -0 "$pr_pid" 2>/dev/null; do
        if [[ "$remaining_ticks" -le 0 ]]; then
            kill "$pr_pid" 2>/dev/null || true
            wait "$pr_pid" 2>/dev/null || true
            PR_DATA_REFRESH_TIMED_OUT=1
            rm -f "$pr_data_file"
            return
        fi
        sleep 0.05
        remaining_ticks=$((remaining_ticks - 1))
    done

    if wait "$pr_pid" 2>/dev/null; then
        PR_DATA_AVAILABLE=1
        PR_DATA="$(cat "$pr_data_file")"
    fi
    rm -f "$pr_data_file"
}

# Get PR info for a branch as: "#123 open|closed|merged"
get_pr_info() {
    local branch="$1"

    if [[ -z "$branch" || "$branch" == "detached" || "${PR_DATA_AVAILABLE:-0}" -ne 1 ]]; then
        echo "-"
        return
    fi

    local pr_match
    pr_match=$(awk -F '\t' -v b="$branch" '
        $1==b {
            if ($3=="OPEN") {
                print $2 "\t" $3
                found=1
                exit
            }
            if ($3=="MERGED" && merged=="") {
                merged=$2 "\t" $3
            }
            if ($3=="CLOSED" && closed=="") {
                closed=$2 "\t" $3
            }
        }
        END {
            if (!found) {
                if (merged!="") {
                    print merged
                } else if (closed!="") {
                    print closed
                }
            }
        }
    ' <<< "$PR_DATA")

    if [[ -z "$pr_match" ]]; then
        echo "-"
        return
    fi

    local number="${pr_match%%$'\t'*}"
    local state="${pr_match#*$'\t'}"

    case "$state" in
        OPEN)
            echo -e "#${number} ${GREEN}open${NC}"
            ;;
        CLOSED)
            echo -e "#${number} ${RED}closed${NC}"
            ;;
        MERGED)
            echo -e "#${number} ${YELLOW}merged${NC}"
            ;;
        *)
            echo "#${number} $(echo "$state" | tr '[:upper:]' '[:lower:]')"
            ;;
    esac
}

# Get PR state for a branch as: open|merged|closed|none
get_pr_state() {
    local branch="$1"

    if [[ -z "$branch" || "$branch" == "detached" || "${PR_DATA_AVAILABLE:-0}" -ne 1 ]]; then
        echo "none"
        return
    fi

    local state
    state=$(awk -F '\t' -v b="$branch" '
        $1==b {
            if ($3=="OPEN") {
                print "open"
                found=1
                exit
            }
            if ($3=="MERGED" && merged=="") {
                merged="merged"
            }
            if ($3=="CLOSED" && closed=="") {
                closed="closed"
            }
        }
        END {
            if (!found) {
                if (merged!="") {
                    print merged
                } else if (closed!="") {
                    print closed
                }
            }
        }
    ' <<< "$PR_DATA")

    echo "${state:-none}"
}

# Get merged PR head SHA for a branch (if available), empty when unknown.
get_pr_merged_head_oid() {
    local branch="$1"

    if [[ -z "$branch" || "$branch" == "detached" || "${PR_DATA_AVAILABLE:-0}" -ne 1 ]]; then
        echo ""
        return
    fi

    local merged_oid
    merged_oid=$(awk -F '\t' -v b="$branch" '
        $1==b && $3=="MERGED" && $4!="" {
            print $4
            exit
        }
    ' <<< "$PR_DATA")

    echo "${merged_oid:-}"
}
