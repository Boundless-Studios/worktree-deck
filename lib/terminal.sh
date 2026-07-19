#!/usr/bin/env bash
# Terminal, browser, and agent-launch helpers for worktree-deck.
#
# Functions that open terminal tabs, launch agent CLIs, open frontend URLs,
# open VS Code, show logs, and run e2e tests for worktrees.

# Escape string content for use inside an AppleScript string literal.
escape_for_applescript() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '%s' "$value"
}

# Pick terminal app, preferring explicit override, then current shell host app.
resolve_terminal_app() {
    if [[ -n "${WTD_TERMINAL_APP:-}" ]]; then
        echo "$WTD_TERMINAL_APP"
        return
    fi

    case "${TERM_PROGRAM:-}" in
        iTerm.app)
            echo "iTerm2"
            ;;
        Apple_Terminal)
            echo "Terminal"
            ;;
        *)
            echo "Terminal"
            ;;
    esac
}

# Open a new terminal tab for a worktree and optionally run a CLI command.
# Prefers current terminal app; set WTD_TERMINAL_APP to override.
open_terminal_tab() {
    local path="$1"
    local cli_command="${2:-}"
    local terminal_app
    terminal_app="$(resolve_terminal_app)"
    local iterm_mode="${WTD_ITERM_OPEN_MODE:-split}"
    local shell_cmd="cd $(printf '%q' "$path") && export WTD_PROJECT_DIR=$(printf '%q' "$path")"
    # Optional per-worktree banner command (set WTD_BANNER_CMD in your config).
    if [[ -n "${WTD_BANNER_CMD:-}" ]]; then
        shell_cmd="${shell_cmd} && ${WTD_BANNER_CMD}"
    fi

    if [[ -n "$cli_command" ]]; then
        shell_cmd="${shell_cmd} && ${cli_command}"
    fi

    local escaped_cmd
    escaped_cmd="$(escape_for_applescript "$shell_cmd")"

    if [[ "$terminal_app" == "iTerm2" || "$terminal_app" == "iTerm" ]]; then
        if [[ "$iterm_mode" == "tab" ]]; then
            osascript \
                -e "tell application \"iTerm2\"" \
                -e "activate" \
                -e "if (count of windows) is 0 then" \
                -e "create window with default profile" \
                -e "else" \
                -e "tell current window to create tab with default profile" \
                -e "end if" \
                -e "tell current session of current window" \
                -e "write text \"$escaped_cmd\"" \
                -e "end tell" \
                -e "end tell" >/dev/null 2>&1
            return $?
        fi

        # Default: split vertically in the current tab using the current profile.
        osascript \
            -e "tell application \"iTerm2\"" \
            -e "activate" \
            -e "if (count of windows) is 0 then" \
            -e "create window with default profile" \
            -e "tell current session of current window" \
            -e "write text \"$escaped_cmd\"" \
            -e "end tell" \
            -e "else" \
            -e "tell current session of current tab of current window" \
            -e "set newSession to (split vertically with same profile)" \
            -e "end tell" \
            -e "tell newSession to write text \"$escaped_cmd\"" \
            -e "end if" \
            -e "end tell" >/dev/null 2>&1
        return $?
    fi

    osascript \
        -e "tell application \"Terminal\"" \
        -e "activate" \
        -e "if (count of windows) is 0 then" \
        -e "do script \"$escaped_cmd\"" \
        -e "else" \
        -e "do script \"$escaped_cmd\" in front window" \
        -e "end if" \
        -e "end tell" >/dev/null 2>&1
}

# Open terminal in worktree (new tab)
open_terminal() {
    local path="$1"
    echo -e "${BLUE}Opening terminal tab in ${BOLD}$(basename "$path")${NC}..."
    if ! open_terminal_tab "$path"; then
        echo -e "${RED}Failed to open terminal tab.${NC}"
        return 1
    fi
}

# Launch CLI inline from the current TUI session.
# Banner rendering is best-effort and must not block CLI startup.
launch_cli_inline() {
    local path="$1"
    local cli_command="$2"
    local label="$3"
    shift 3
    # Remaining args are forwarded verbatim to the CLI (e.g. resume flags). No
    # extra args == a normal fresh launch, so existing callers are unaffected.
    local extra_args="$*"
    local launch_flag
    launch_flag="$(wtd_normalize_launch_flag "$cli_command")"

    echo -e "${BLUE}Launching ${label}...${NC}"
    if [[ -n "${WTD_LAUNCH_CMD:-}" ]]; then
        # Project-provided launcher override. Receives the SAME
        #   <worktree_path> <launch_flag> [extra_args]
        # contract as the built-in launcher, so a project whose own flows (e.g. a
        # `new-wt` target) already shell out to a richer launcher can route the
        # console through that SAME launcher — one launcher, identical behavior on
        # both paths — instead of forking project-specific logic into the engine.
        #
        # Run from the target worktree in a subshell so a RELATIVE override (e.g.
        # "bash scripts/launch-worktree-cli.sh") resolves against the project tree,
        # not the TUI's cwd (which may be a subdirectory or, via WTD_MAIN_REPO,
        # outside the repo entirely); the console's own cwd is left untouched.
        # shellcheck disable=SC2086
        ( cd "$path" && ${WTD_LAUNCH_CMD} "$path" "$launch_flag" "$extra_args" )
    else
        bash "$LIB_DIR/launch-worktree-cli.sh" "$path" "$launch_flag" "$extra_args"
    fi
}

# Launch a fresh agent session, optionally through a project-provided session
# supervisor. The managed command receives the same neutral launcher contract
# as WTD_LAUNCH_CMD and runs directly from the target worktree; worktree-deck
# does not add a second tmux/process owner around it.
#
# WTD_SESSION_ID is opaque chain metadata only. It is intentionally forwarded
# without interpreting it as a native Claude or Codex conversation identifier.
launch_worktree_agent() {
    local path="$1"
    local cli_command="$2"
    local label="$3"
    shift 3

    if [[ -z "${WTD_MANAGED_FRESH_CMD:-}" ]]; then
        launch_cli_inline "$path" "$cli_command" "$label" "$@"
        return
    fi

    local extra_args="$*"
    local launch_flag
    launch_flag="$(wtd_normalize_launch_flag "$cli_command")"

    echo -e "${BLUE}Launching managed ${label}...${NC}"
    # Project-provided command; preserve the same intentionally shell-like
    # configuration contract as WTD_LAUNCH_CMD (for example, "bash script").
    # shellcheck disable=SC2086
    (
        cd "$path" || exit 1
        WTD_MANAGED_EVENT_OWNER=1 \
        WTD_PROJECT_DIR="$path" \
        WTD_SESSION_ID="${WTD_SESSION_ID:-}" \
            ${WTD_MANAGED_FRESH_CMD} "$path" "$launch_flag" "$extra_args"
    )
}

# Print the agent CLI (e.g. claude|codex) of the most-recent session in a
# worktree via the optional WTD_LAST_AGENT_CMD hook. Empty when the hook is
# unconfigured or reports nothing.
wtd_last_agent_cli() {
    local path="$1"
    [[ -n "${WTD_LAST_AGENT_CMD:-}" ]] || return 0
    # shellcheck disable=SC2086
    ${WTD_LAST_AGENT_CMD} "$path" 2>/dev/null
}

# Resume the most-recent agent session for a worktree. Picks which CLI to resume
# from WTD_LAST_AGENT_CMD (falling back to the worktree's default launcher when
# unknown), then relaunches it with that CLI's resume args. If the CLI has no
# known resume args, launches it fresh.
# Args: path fallback_cli fallback_label
resume_worktree_agent() {
    local path="$1"
    local fallback_cli="$2"
    local fallback_label="$3"
    local name
    name=$(short_name "$path")

    local cli label
    cli="$(wtd_last_agent_cli "$path")"
    if [[ -z "$cli" ]]; then
        cli="$fallback_cli"
        label="$fallback_label"
        echo -e "${YELLOW}No recorded agent for ${name} — resuming default ${label}.${NC}"
    else
        label="$(wtd_launch_label_from_flag "$cli")"
    fi

    local resume_args
    resume_args="$(wtd_resume_args_from_cli "$cli")"
    if [[ -z "$resume_args" ]]; then
        echo -e "${YELLOW}No resume flags known for '${cli}' — launching ${label} fresh.${NC}"
        launch_cli_inline "$path" "$cli" "$label"
        return
    fi

    echo -e "${BLUE}Resuming ${label} (most recent) in ${name}...${NC}"
    launch_cli_inline "$path" "$cli" "$label" "$resume_args"
}

# Open frontend in browser. Always uses http://localhost:<port> — Auth0 refuses
# any non-localhost / non-HTTPS origin. For remote-daemon worktrees, verifies
# the SSH tunnel is up first (auto-starts if down) so localhost actually resolves.
open_frontend() {
    local path="$1"
    if [[ ! -f "$path/.env" ]]; then
        echo -e "${RED}No .env found. Run 'start' first to generate ports.${NC}"
        return 1
    fi

    local frontend_port
    frontend_port=$(grep "^FRONTEND_PORT=" "$path/.env" 2>/dev/null | cut -d= -f2)
    if [[ -z "$frontend_port" ]]; then
        echo -e "${RED}FRONTEND_PORT missing from $path/.env.${NC}"
        return 1
    fi

    # If this worktree was started against a remote Docker daemon, ensure the
    # SSH port-forward is alive before opening — otherwise localhost:<port>
    # has nothing listening and the browser will just see a connection refused.
    # Optional remote-daemon tunnel hook: when the frontend runs on a remote
    # Docker host, set WTD_REMOTE_TUNNEL_CMD to a command that ensures the SSH
    # port-forward is up (run with the worktree as cwd) before the browser opens.
    if [[ -n "${WTD_REMOTE_TUNNEL_CMD:-}" ]]; then
        (cd "$path" && eval "$WTD_REMOTE_TUNNEL_CMD") || {
            echo -e "${RED}Remote tunnel command failed — cannot open frontend.${NC}"
            return 1
        }
    fi

    local url="http://localhost:${frontend_port}"
    local browser_app="${WTD_BROWSER_APP:-Google Chrome}"
    echo -e "${BLUE}Opening frontend at ${url}${NC}"

    # Prefer the user's regular Chrome app to avoid Playwright's persistent test profile.
    if open -a "$browser_app" "$url" >/dev/null 2>&1; then
        return
    fi
    if open "$url" >/dev/null 2>&1; then
        return
    fi
    echo -e "${RED}Failed to open browser. Tried '${browser_app}' and default browser.${NC}"
    return 1
}

# Open worktree in VS Code with robust fallback.
open_vscode() {
    local path="$1"

    if command -v code >/dev/null 2>&1; then
        if code "$path" >/dev/null 2>&1; then
            return
        fi
    fi

    if open -a "Visual Studio Code" "$path" >/dev/null 2>&1; then
        return
    fi

    echo -e "${RED}Failed to open VS Code. Install the 'code' CLI or ensure 'Visual Studio Code' is installed.${NC}"
}

# Tail the dev-stack container logs for a worktree.
show_logs() {
    local path="$1"
    local names
    names="$(wtd_service_names "$path")"
    if [[ -z "$names" ]]; then
        echo -e "${YELLOW}No dev-stack containers configured (set WTD_SERVICE_TEMPLATES).${NC}"
        read -p "Press Enter to continue..."
        return
    fi
    # Build a docker logs follow across whichever of the worktree's containers exist.
    local running=()
    local n
    while IFS= read -r n; do
        [[ -z "$n" ]] && continue
        docker ps --filter "name=^${n}$" --format '{{.Names}}' 2>/dev/null | grep -qFx "$n" && running+=("$n")
    done <<< "$names"
    if [[ ${#running[@]} -eq 0 ]]; then
        echo -e "${YELLOW}No running containers for this worktree.${NC}"
        read -p "Press Enter to continue..."
        return
    fi
    echo -e "${CYAN}Tailing logs (Ctrl-C to stop): ${running[*]}${NC}"
    docker logs -f --tail 100 "${running[0]}" 2>&1 || true
}

# Run e2e tests for a worktree
run_e2e_tests() {
    local path="$1"
    local test_file="${2:-}"
    local name=$(basename "$path")

    # Check if containers are running. get_container_status returns a status
    # containing "Stopped" both when containers are actually down and when
    # Docker itself is unreachable (we cannot verify containers either way) —
    # both block the e2e run so we never silently target a daemon we can't
    # talk to.
    local status=$(get_container_status "$path")
    if [[ "$status" == *"Docker unavailable"* ]]; then
        echo -e "${RED}Docker daemon unreachable for ${name}; cannot verify containers. Resolve Docker access and retry.${NC}"
        return 1
    fi
    if [[ "$status" == *"Stopped"* ]]; then
        echo -e "${RED}Containers not running for ${name}. Start them first.${NC}"
        return 1
    fi

    if [[ -z "$WTD_E2E_CMD" ]]; then
        echo -e "${YELLOW}No e2e command configured (set WTD_E2E_CMD).${NC}"
        return 0
    fi

    echo -e "${BOLD}Running e2e tests for ${CYAN}${name}${NC}..."
    echo -e "${CYAN}──────────────────────────────────────────────────────────────────${NC}"

    if [[ -n "$test_file" ]]; then
        echo -e "Test file: ${CYAN}${test_file}${NC}"
        (cd "$path" && TEST_FILE="$test_file" eval "$WTD_E2E_CMD")
    else
        (cd "$path" && eval "$WTD_E2E_CMD")
    fi
}
