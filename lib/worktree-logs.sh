#!/usr/bin/env bash
# Tail logs for the current worktree:
#   - backend docker container (computed from git branch)
#   - Godot game client (/tmp/gaia-game-client.log + OS Godot user-data log)
# Lines from each source are prefixed so the streams are distinguishable
# in the single pane. Auto-retries if the backend isn't ready; reattaches
# on disconnect. Godot tails use 'tail -F' so they survive the files not
# yet existing (the user-data log only appears after the first launch).
#
# Usage: ./scripts/worktree-logs.sh [--print-config] [worktree_path]
#   If worktree_path is omitted, uses the current directory.
set -euo pipefail

PRINT_CONFIG=0
if [[ "${1:-}" == "--print-config" ]]; then
    PRINT_CONFIG=1
    shift
fi

WORKTREE="${1:-$(pwd)}"

# Colors
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
GREEN='\033[0;32m'
BOLD='\033[1m'
NC='\033[0m'

# Compute worktree tags from branch. Keep the display tag untruncated for log
# clarity, but keep the fallback container suffix byte-for-byte aligned with
# scripts/worktree-env.sh.
branch=$(cd "$WORKTREE" && git branch --show-current 2>/dev/null || true)
branch="${branch:-detached}"
name=$(basename "$WORKTREE")

normalize_branch_tag() {
    printf '%s\n' "$1" | sed -E 's#^(feature|fix|chore|hotfix|release)/##; s#/#-#g'
}

branch_short="$(normalize_branch_tag "$branch")"
if [[ "$branch" == "detached" && "$name" != "gaia-free" ]]; then
    branch_short="$name"
fi
worktree_tag="${GAIA_WORKTREE_TAG:-$branch_short}"
tag=""

if [[ "$branch" != "main" && "$branch" != "master" ]]; then
    tag="$branch_short"
    tag="${tag:0:30}"
fi

if [[ "$branch" == "detached" && "$name" != "gaia-free" ]]; then
    tag="${name:0:30}"
fi
if [[ "$branch" == "detached" && "$name" == "gaia-free" ]]; then
    tag=""
fi

suffix="${tag:+-$tag}"
backend_name="gaia-backend${suffix}"
backend_name_source="branch fallback"

read_env_value() {
    local key="$1"
    local file="$2"
    awk -F= -v key="$key" '
        $1 == key {
            value = substr($0, length(key) + 2)
            gsub(/\r$/, "", value)
            gsub(/^"|"$/, "", value)
            print value
            exit
        }
    ' "$file"
}

env_file="$WORKTREE/.env"
if [[ -f "$env_file" ]]; then
    env_backend_name="$(read_env_value BACKEND_CONTAINER_NAME "$env_file")"
    if [[ -n "$env_backend_name" ]]; then
        backend_name="$env_backend_name"
        backend_name_source=".env BACKEND_CONTAINER_NAME"
    fi
fi

# Godot client log paths (OS-conditional for the user-data engine log)
godot_stdout_log="/tmp/gaia-game-client.log"
case "$(uname -s)" in
    Darwin) godot_user_log="$HOME/Library/Application Support/Godot/app_userdata/Gaia Game Client/logs/godot.log" ;;
    Linux)  godot_user_log="$HOME/.local/share/godot/app_userdata/Gaia Game Client/logs/godot.log" ;;
    *)      godot_user_log="" ;;
esac

backend_label="[backend wc=${worktree_tag}]"
godot_label="[godot wc=${worktree_tag}]"
godot_engine_label="[godot-e wc=${worktree_tag}]"

if [[ "$PRINT_CONFIG" -eq 1 ]]; then
    printf 'worktree=%s\n' "$WORKTREE"
    printf 'worktree_tag=%s\n' "$worktree_tag"
    printf 'backend_container=%s\n' "$backend_name"
    printf 'backend_container_source=%s\n' "$backend_name_source"
    printf 'backend_prefix=%s\n' "$backend_label"
    printf 'godot_prefix=%s\n' "$godot_label"
    printf 'godot_engine_prefix=%s\n' "$godot_engine_label"
    printf 'godot_stdout_log=%s\n' "$godot_stdout_log"
    printf 'godot_user_log=%s\n' "$godot_user_log"
    exit 0
fi

echo -e "${BOLD}Logs for ${CYAN}${name}${NC}${BOLD} (${worktree_tag}):${NC}"
echo -e "  ${CYAN}${backend_label}${NC} ${backend_name} (${backend_name_source})"
echo -e "  ${MAGENTA}${godot_label}${NC} ${godot_stdout_log}"
if [[ -n "$godot_user_log" ]]; then
    echo -e "  ${GREEN}${godot_engine_label}${NC} ${godot_user_log}"
fi
echo -e "${YELLOW}Press Ctrl+C to stop${NC}"
echo

stop_requested=0
trap 'stop_requested=1' INT TERM

# Start the godot tails in the background. Each line is prefixed by source
# colour so the merged stream is readable. 'tail -F' retries on missing
# files (the user-data log appears only after the first Godot launch).
godot_pids=()

# Pre-create /tmp/gaia-game-client.log so tail -F can start immediately
# without a "file does not exist" message.
: >> "$godot_stdout_log" 2>/dev/null || true

tail -n 0 -F "$godot_stdout_log" 2>/dev/null \
    | awk -v p="$(printf '%b%s%b ' "$MAGENTA" "$godot_label" "$NC")" '{ print p $0; fflush() }' &
godot_pids+=($!)

if [[ -n "$godot_user_log" ]]; then
    tail -n 0 -F "$godot_user_log" 2>/dev/null \
        | awk -v p="$(printf '%b%s%b ' "$GREEN" "$godot_engine_label" "$NC")" '
            /Attempt to open script '\''res:\/\/addons\/godot_ai\/runtime\/game_helper\.gd'\'' resulted in error '\''File not found'\''/ {
                if (!seen_game_helper++) {
                    print p "non-fatal setup warning: godot_ai addon missing (suppressed repeated game_helper.gd file-not-found lines)"
                    fflush()
                }
                suppress_game_helper_stack = 1
                next
            }
            /Failed to instantiate an autoload, can'\''t load from path: res:\/\/addons\/godot_ai\/runtime\/game_helper\.gd/ {
                if (!seen_game_helper++) {
                    print p "non-fatal setup warning: godot_ai addon missing (suppressed repeated game_helper.gd file-not-found lines)"
                    fflush()
                }
                suppress_game_helper_stack = 1
                next
            }
            suppress_game_helper_stack && /^[[:space:]]*at: / {
                next
            }
            suppress_game_helper_stack {
                suppress_game_helper_stack = 0
            }
            /SCRIPT ERROR|Parse Error|Failed to load script|Compilation failed|Failed to instantiate/ {
                print p $0
                fflush()
                next
            }
            /MusicPlayer: missing res:\/\/audio\/background\/.*\.mp3/ {
                if (!seen_music++) {
                    print p "non-fatal setup warning: MusicPlayer fallback audio missing (suppressed repeated missing-mp3 lines)"
                    fflush()
                }
                next
            }
            { print p $0; fflush() }
        ' &
    godot_pids+=($!)
fi

cleanup() {
    for pid in "${godot_pids[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
}
trap 'stop_requested=1; cleanup' INT TERM EXIT

backend_prefix="$(printf '%b%s%b ' "$CYAN" "$backend_label" "$NC")"
first_attach=1

while [[ "$stop_requested" -eq 0 ]]; do
    if ! docker ps -a --filter "name=^${backend_name}$" --format "{{.Names}}" 2>/dev/null | grep -q "^${backend_name}$"; then
        echo -e "${backend_prefix}${YELLOW}Container not found; container=${backend_name}; source=${backend_name_source}; retrying in 2s. Run 'gmake worktree-env' if this source looks stale.${NC}"
        sleep 2 || true
        continue
    fi

    log_exit=0
    if [[ "$first_attach" -eq 1 ]]; then
        first_attach=0
        docker logs -f --tail 50 "$backend_name" 2>&1 \
            | awk -v p="$backend_prefix" '{ print p $0; fflush() }' || log_exit=$?
    else
        docker logs -f --since 1s "$backend_name" 2>&1 \
            | awk -v p="$backend_prefix" '{ print p $0; fflush() }' || log_exit=$?
    fi

    if [[ "$stop_requested" -eq 1 ]]; then
        break
    fi

    if [[ "$log_exit" -ne 0 ]]; then
        echo -e "${backend_prefix}${YELLOW}Log stream disconnected (exit ${log_exit}); container=${backend_name}; reattaching in 2s.${NC}"
    else
        echo -e "${backend_prefix}${YELLOW}Log stream ended; container=${backend_name}; reattaching in 2s.${NC}"
    fi
    sleep 2 || true
done
