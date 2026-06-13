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

# Optional: serialize stack-start host-globally (only one worktree's start runs
# at a time). Off by default; set to 1/true when your start command touches
# host-global resources (a shared file-sync session, a shared image builder,
# shared background sweeps) that two concurrent starts would trample. See
# stack-start-lock.sh for WTD_STACK_START_LOCK* tuning.
: "${WTD_SERIALIZE_STACK_START:=}"

# Optional: refuse to start a worktree's stack when this many stacks are already
# running (0/unset => unlimited). Counts running containers derived from the
# first WTD_SERVICE_TEMPLATES entry (the "primary" service), so it caps
# concurrent stacks the way a backend-count cap would. Guards shared-host memory.
: "${WTD_BACKEND_CAP:=0}"

# Optional: command run (with the worktree as cwd) to regenerate a worktree's
# env after continue-worktree switches its branch. Empty => skip (re-run your
# stack-start command instead). e.g. "bash scripts/worktree-env.sh".
: "${WTD_ENV_REGEN_CMD:=}"

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

# True when host-global start serialization is enabled.
_wtd_serialize_stack_start() {
    case "${WTD_SERIALIZE_STACK_START:-}" in 1|true|yes|on|TRUE|YES|ON) return 0 ;; *) return 1 ;; esac
}

# Bring a worktree's stack up. When WTD_SERIALIZE_STACK_START is enabled, run it
# under the host-global start lock (in a subshell so the lock's signal traps
# don't leak into the caller). Otherwise run it directly.
wtd_stack_start() {
    if _wtd_serialize_stack_start && declare -F wtd_stack_start_lock_run >/dev/null 2>&1; then
        ( wtd_stack_start_lock_run _wtd_run_stack_cmd "$WTD_STACK_START" "$1" )
    else
        _wtd_run_stack_cmd "$WTD_STACK_START" "$1"
    fi
}
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

# Static base of the primary service template (first WTD_SERVICE_TEMPLATES entry
# with the {suffix} placeholder removed), e.g. "myapp-backend". Empty when no
# templates are configured. Used by the concurrent-stack cap.
_wtd_primary_service_base() {
    [[ ${#WTD_SERVICE_TEMPLATES[@]} -gt 0 ]] || return 0
    local base="${WTD_SERVICE_TEMPLATES[0]}"
    printf '%s' "${base//\{suffix\}/}"
}

# Cap guard: return non-zero (and explain) when starting another stack would
# exceed WTD_BACKEND_CAP. $1 = this worktree's own primary container name to
# exclude from the count (optional). No-op when the cap is unset/0 or no
# templates/Docker are configured.
wtd_backend_cap_ok() {
    local cap="${WTD_BACKEND_CAP:-0}"
    [[ "$cap" =~ ^[0-9]+$ ]] || cap=0
    [[ "$cap" -gt 0 ]] || return 0
    local base; base="$(_wtd_primary_service_base)"
    [[ -n "$base" ]] || return 0
    command -v docker >/dev/null 2>&1 || return 0

    local own="${1:-}" running count
    # Docker's `name` filter is an unanchored substring/regex match, so a generic
    # base like "api"/"backend" would also count unrelated containers that merely
    # CONTAIN it (e.g. "other-backend-x"). Anchor to the start (^base) so the cap
    # only reflects THIS project's stack containers (named "<base><suffix>").
    running="$(docker ps --filter "name=^${base}" --filter 'status=running' --format '{{.Names}}' 2>/dev/null | grep -v '^$' || true)"
    if [[ -n "$own" ]]; then
        running="$(printf '%s\n' "$running" | grep -vxF "$own" || true)"
    fi
    count="$(printf '%s\n' "$running" | grep -c . || true)"
    if [[ "$count" -ge "$cap" ]]; then
        echo "❌ Cannot start: ${count} stack(s) already running (cap WTD_BACKEND_CAP=${cap})." >&2
        printf '%s\n' "$running" | grep -v '^$' | sed 's/^/     - /' >&2
        echo "   Free a slot (stop/remove a stale worktree) or raise WTD_BACKEND_CAP." >&2
        return 1
    fi
    return 0
}

# Source the optional capability libs (start-lock serialization, continue-
# worktree) so their functions are available to the console and CLI subcommands.
_WTD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=stack-start-lock.sh
[[ -r "$_WTD_LIB_DIR/stack-start-lock.sh" ]] && source "$_WTD_LIB_DIR/stack-start-lock.sh"
# shellcheck source=continue-worktree.sh
[[ -r "$_WTD_LIB_DIR/continue-worktree.sh" ]] && source "$_WTD_LIB_DIR/continue-worktree.sh"
