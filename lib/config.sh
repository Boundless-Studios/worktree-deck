#!/usr/bin/env bash
# worktree-deck configuration layer.
#
# Defines project-agnostic defaults, then sources the user's config to override.
# Everything that used to be hardcoded to one project — the dev-stack container
# names, the start/stop commands, the port/slot scheme, the agent launchers, the
# remote Docker host — lives here as variables + small hook functions.
#
# Resolution order (later wins):
#   1. defaults below
#   2. repo-local  ./worktree-deck.conf   (found by walking up from the main repo)
#   3. user-global ${WORKTREE_DECK_CONFIG:-$HOME/.config/worktree-deck/config}
#
# A config file is just sourced shell, so it can set variables AND redefine any
# wtd_* hook function for full control.

# ---------------------------------------------------------------------------
# Defaults (override in your worktree-deck.conf)
# ---------------------------------------------------------------------------

# Main repo + where sibling worktrees live. Auto-derived when empty.
: "${WTD_MAIN_REPO:=}"
: "${WTD_WORKTREES_DIR:=}"

# Branch-name prefixes stripped when deriving a worktree's short tag/suffix.
: "${WTD_BRANCH_PREFIXES:=feature fix chore hotfix release}"
# Max length of the derived tag (keeps container names bounded).
: "${WTD_TAG_MAXLEN:=30}"

# Dev-stack container-name templates. `{suffix}` expands to the per-worktree
# suffix (e.g. "-my-branch"); the main checkout on main/master gets "".
# EMPTY array => "stackless" mode: pure worktree management, no Docker.
if [[ -z "${WTD_SERVICE_TEMPLATES+x}" ]]; then
    WTD_SERVICE_TEMPLATES=()
fi

# Commands to bring a worktree's dev stack up / down / restart. Empty => no-op
# (stackless). `{path}` expands to the worktree path; if absent the command is
# run with the worktree as cwd.
: "${WTD_STACK_START:=}"
: "${WTD_STACK_STOP:=}"
: "${WTD_STACK_RESTART:=}"

# Optional: command to run the project's e2e tests for a worktree ({path}).
: "${WTD_E2E_CMD:=}"

# .env keys the console reads for display (ports + slot).
: "${WTD_BACKEND_PORT_KEY:=BACKEND_PORT}"
: "${WTD_FRONTEND_PORT_KEY:=FRONTEND_PORT}"
: "${WTD_SLOT_ENV_KEY:=WTD_SLOT}"

# Optional: space-separated .env keys that record a worktree's ACTUAL container
# names (e.g. written by your start command). These are matched in addition to
# the branch-derived WTD_SERVICE_TEMPLATES names, so a worktree whose containers
# aren't derivable from its current branch (renamed branch, custom names) still
# matches its containers instead of showing them as orphans. Empty => derive
# names only from WTD_SERVICE_TEMPLATES.
: "${WTD_ENV_CONTAINER_KEYS:=}"

# Agent CLIs the console can launch in a worktree (first = default).
if [[ -z "${WTD_AGENT_LAUNCHERS+x}" ]]; then
    WTD_AGENT_LAUNCHERS=(claude codex)
fi

# Optional remote Docker daemon (ssh://user@host). Empty => local daemon only.
: "${WTD_REMOTE_DOCKER_HOST:=}"

# Container-name prefix that identifies THIS project's containers, used by the
# dead/orphan/stop-all sweeps. Empty => those destructive sweeps are disabled
# (so we never `docker rm -f` containers from other projects). Set it to the
# common prefix of your WTD_SERVICE_TEMPLATES, e.g. "myapp-".
: "${WTD_CONTAINER_PREFIX:=}"

# Shared-infra containers to NEVER sweep (space-separated), e.g. a shared
# postgres/rabbitmq used across worktrees.
: "${WTD_SHARED_CONTAINERS:=}"

# Optional background daemons the console can manage. Declare each one by adding
# its name to WTD_DAEMONS and filling the registry maps below in your config:
#   WTD_DAEMONS=(dash)
#   WTD_DAEMON_CMD[dash]="exec agentic-pr-dash serve"
#   WTD_DAEMON_URL[dash]="http://localhost:9000"     # optional
#   WTD_DAEMON_TYPE[dash]="persistent"               # or "loop:<seconds>"
#   WTD_DAEMON_PATTERN[dash]="agentic-pr-dash"        # pgrep pattern for orphans
if [[ -z "${WTD_DAEMONS+x}" ]]; then
    WTD_DAEMONS=()
fi
# Autostart subset (default: none). Names the console may start unattended.
if [[ -z "${WTD_DAEMONS_AUTOSTART+x}" ]]; then
    WTD_DAEMONS_AUTOSTART=()
fi
declare -gA WTD_DAEMON_CMD WTD_DAEMON_URL WTD_DAEMON_TYPE WTD_DAEMON_PATTERN 2>/dev/null || true

# Where daemon pid/log files live.
: "${WTD_DAEMON_DIR:=$HOME/.cache/worktree-deck/daemons}"

# Optional: a command the console pipes session lifecycle events to
# (e.g. "agentic-pr-dash record"). Empty => no session bridge.
: "${WTD_EVENT_SINK:=}"

# Optional: a command that, given a worktree path as its final argument, prints
# the agent CLI (e.g. "claude" or "codex") of the MOST RECENT session in that
# worktree — used by the resume action (`<n>r`) to relaunch the right agent.
# Empty => resume falls back to the worktree's default launcher.
: "${WTD_LAST_AGENT_CMD:=}"

# ---------------------------------------------------------------------------
# Config file loading
# ---------------------------------------------------------------------------

wtd_load_config() {
    local main_repo="${1:-$PWD}"
    # repo-local config (walk up from the main repo)
    local dir="$main_repo"
    while [[ -n "$dir" && "$dir" != "/" ]]; do
        if [[ -r "$dir/worktree-deck.conf" ]]; then
            # shellcheck disable=SC1090,SC1091
            source "$dir/worktree-deck.conf"
            break
        fi
        dir="$(dirname "$dir")"
    done
    # user-global config (wins over repo-local)
    local global="${WORKTREE_DECK_CONFIG:-$HOME/.config/worktree-deck/config}"
    if [[ -r "$global" ]]; then
        # shellcheck disable=SC1090,SC1091
        source "$global"
    fi
}

# ---------------------------------------------------------------------------
# Hook functions (override any of these in your config for full control)
# ---------------------------------------------------------------------------

# Derive the per-worktree suffix from its path + branch (e.g. "-my-branch").
# Main checkout on main/master => "".
wtd_branch_tag() {
    local worktree_path="$1"
    local base; base="$(basename "$worktree_path")"
    local branch; branch="$(cd "$worktree_path" && git branch --show-current 2>/dev/null || true)"
    branch="${branch:-detached}"
    local tag=""
    if [[ "$branch" != "main" && "$branch" != "master" ]]; then
        local strip_re=""
        local p
        for p in $WTD_BRANCH_PREFIXES; do strip_re+="${strip_re:+|}$p"; done
        tag="$(printf '%s' "$branch" | sed -E "s#^(${strip_re})/##; s#/#-#g")"
        tag="${tag:0:$WTD_TAG_MAXLEN}"
    fi
    if [[ "$branch" == "detached" && "$base" != "$(basename "${WTD_MAIN_REPO:-$base}")" ]]; then
        tag="${base:0:$WTD_TAG_MAXLEN}"
    fi
    printf '%s' "${tag:+-$tag}"
}

# Emit a worktree's dev-stack container names (one per line): the branch-derived
# WTD_SERVICE_TEMPLATES names, plus any actual names recorded in the worktree's
# .env under WTD_ENV_CONTAINER_KEYS. Empty when neither is configured (stackless).
wtd_service_names() {
    local worktree_path="$1"
    local suffix; suffix="$(wtd_branch_tag "$worktree_path")"
    local tmpl
    for tmpl in "${WTD_SERVICE_TEMPLATES[@]}"; do
        printf '%s\n' "${tmpl//\{suffix\}/$suffix}"
    done
    # Actual container names recorded in the worktree's .env (covers renamed
    # branches / non-derivable names). These match the running containers even
    # when the current branch no longer derives them.
    if [[ -n "${WTD_ENV_CONTAINER_KEYS:-}" && -f "$worktree_path/.env" ]]; then
        local key val
        for key in $WTD_ENV_CONTAINER_KEYS; do
            val="$(grep "^${key}=" "$worktree_path/.env" 2>/dev/null | head -n1 | cut -d= -f2-)"
            val="${val%\"}"; val="${val#\"}"; val="${val%\'}"; val="${val#\'}"
            [[ -n "$val" ]] && printf '%s\n' "$val"
        done
    fi
}

# Run a configured stack command ($1=template, $2=worktree path). No-op if empty.
_wtd_run_stack_cmd() {
    local cmd="$1" path="$2"
    [[ -n "$cmd" ]] || return 0
    if [[ "$cmd" == *"{path}"* ]]; then
        eval "${cmd//\{path\}/$path}"
    else
        (cd "$path" && eval "$cmd")
    fi
}

wtd_stack_start()   { _wtd_run_stack_cmd "$WTD_STACK_START" "$1"; }
wtd_stack_stop()    { _wtd_run_stack_cmd "$WTD_STACK_STOP" "$1"; }
wtd_stack_restart() {
    if [[ -n "$WTD_STACK_RESTART" ]]; then
        _wtd_run_stack_cmd "$WTD_STACK_RESTART" "$1"
    else
        wtd_stack_stop "$1"; wtd_stack_start "$1"
    fi
}

# True when a dev stack is configured at all.
wtd_has_stack() { [[ ${#WTD_SERVICE_TEMPLATES[@]} -gt 0 || -n "$WTD_STACK_START" ]]; }
