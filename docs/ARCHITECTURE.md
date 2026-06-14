# worktree-deck Architecture

This document is the maintainer map for `worktree-deck`. The README explains
what the tool does for users; this file explains how the implementation is
structured, where behavior belongs, and which contracts must stay stable for
downstream repos such as Gaia.

## Purpose

`worktree-deck` is a project-agnostic control panel for a repository's git
worktrees and, optionally, one isolated dev stack per worktree. It owns the
generic mechanics:

- finding and displaying worktrees for a main repository;
- creating, removing, continuing, and cleaning worktrees;
- reading per-worktree runtime metadata from `.env`;
- mapping each worktree to configured container names;
- starting, stopping, and restarting a configured stack command;
- selecting local versus remote Docker for status and cleanup;
- launching or resuming a configured agent CLI inside a worktree;
- running optional background daemons declared by configuration.

It does not know how a specific application builds, assigns ports, authenticates,
runs tests, or provisions shared infrastructure. Those are configuration or hook
responsibilities.

## Setup Model

The tool is installed as a standalone shell checkout:

```bash
git clone https://github.com/Boundless-Studios/worktree-deck ~/.worktree-deck
alias wtd='bash ~/.worktree-deck/bin/worktree-deck.sh'
```

Run it from inside the repository you want to manage, or pin the target repo in
configuration with `WTD_MAIN_REPO`.

Configuration is sourced shell. Load order is:

1. built-in defaults from `lib/config.sh`;
2. repo-local `worktree-deck.conf`, found by walking upward from the main repo;
3. global `${WORKTREE_DECK_CONFIG:-$HOME/.config/worktree-deck/config}`.

Later files win. A config may set `WTD_*` variables and may override any
`wtd_*` hook function.

## Design Boundaries

The stable boundary is the `WTD_*`/`wtd_*` contract.

Application-specific behavior should enter through:

- `WTD_STACK_START`, `WTD_STACK_STOP`, `WTD_STACK_RESTART`, `WTD_E2E_CMD`;
- `WTD_SERVICE_TEMPLATES`, `WTD_ENV_CONTAINER_KEYS`, and port/slot key names;
- `WTD_REMOTE_DOCKER_HOST` and `WTD_REMOTE_TUNNEL_CMD`;
- `WTD_LAUNCH_CMD`, `WTD_AGENT_LAUNCHERS`, `WTD_EVENT_SINK`,
  `WTD_LAST_AGENT_CMD`;
- `WTD_DAEMONS` and the daemon registry maps;
- hook overrides such as `wtd_branch_tag()` or `wtd_launch_cli_from_flag()`.

Do not add repo-specific paths, Make targets, Docker Compose assumptions, Auth0
logic, database rules, proof-bundle rules, or issue-tracker policy to this repo.
If a downstream application needs that behavior, expose a generic command or hook
and let its config invoke the application-specific implementation.

## Runtime Flows

### Interactive Console

`bin/worktree-deck.sh` is the TUI entrypoint. It:

1. dispatches explicit headless subcommands before any TUI guard;
2. behaves like coreutils `wc` in non-interactive contexts so an alias named
   `wc` does not break pipelines;
3. loads launch-mode, Docker, config, and daemon libraries;
4. resolves `MAIN_REPO` and `WORKTREES_DIR`;
5. loads repo and global config;
6. optionally exports `DOCKER_HOST` from `WTD_REMOTE_DOCKER_HOST`;
7. renders worktree rows, accepts menu actions, and delegates actual operations
   to focused functions and libs.

The render path avoids expensive repeated probes. It snapshots Docker container
names once per screen, reads PR metadata once via `gh pr list`, and reuses those
snapshots while building rows.

### Worktree Status

For each worktree, the console derives:

- display name from the current branch;
- slot and ports from `.env` keys configured by `WTD_SLOT_ENV_KEY`,
  `WTD_BACKEND_PORT_KEY`, and `WTD_FRONTEND_PORT_KEY`;
- expected service names from `wtd_service_names()`;
- running/stopped status from Docker snapshots;
- PR number/state from the cached `gh pr list` result.

`wtd_service_names()` emits both template-derived names and any actual names
recorded in `.env` under `WTD_ENV_CONTAINER_KEYS`. This prevents renamed
branches from being misclassified as orphan containers.

### Stack Start and Restart

`start_worktree()` and `restart_worktree()` are TUI-safe wrappers. They do not
crash the menu on expected refusals; they print the refusal and return control to
the UI.

The generic command path is:

```text
start_worktree()
  -> wtd_backend_cap_ok()
  -> wtd_stack_start()
  -> _wtd_run_stack_cmd_guarded()
  -> optionally wtd_stack_start_lock_run()
  -> configured WTD_STACK_START
```

The stack-start lock is enabled when `WTD_SERIALIZE_STACK_START` is true or when
`WTD_BACKEND_CAP` is configured. The cap is rechecked inside the lock so two
concurrent starts cannot both pass an optimistic pre-lock count.

### Remote Docker

`lib/docker-reachable.sh` owns reachability and fallback behavior. The console
can point Docker at `WTD_REMOTE_DOCKER_HOST`, but status reads still fall back to
local Docker when the configured remote is unreachable. Cleanup actions use the
same daemon that produced the displayed cleanup summary.

### Agent Launch and Resume

The console supports built-in launching via `lib/launch-worktree-cli.sh` and a
project override via `WTD_LAUNCH_CMD`.

`WTD_LAUNCH_CMD` is preferred for downstream projects that already have their
own launcher. The contract is:

```text
<command> <worktree_path> <launch_flag> [extra_args...]
```

The command runs with the target worktree as the current directory, so relative
commands can refer to files in the managed repo.

Session lifecycle events are sent to `WTD_EVENT_SINK` when configured. Resume
uses `WTD_LAST_AGENT_CMD` to ask the downstream project which agent last worked
in a worktree, then maps that agent to resume args through
`wtd_resume_args_from_cli()`.

### Headless Subcommands

`bin/worktree-deck.sh` exposes explicit headless verbs:

- `lock-health` inspects or repairs the host-global stack-start lock;
- `run-locked` runs any command under the same lock;
- `continue` / `continue-worktree` repoints an existing worktree onto a new
  branch and optionally runs `WTD_ENV_REGEN_CMD`.

These dispatch before the interactive guard so they are safe in scripts, CI, and
agent sessions.

## Code Map

| Path | Responsibility |
| --- | --- |
| `bin/worktree-deck.sh` | Interactive console, row rendering, menu actions, headless subcommand dispatch. |
| `lib/config.sh` | Defaults, config loading, hook contract, stack command execution, backend cap. |
| `lib/docker-reachable.sh` | Docker reachability, remote/local selection, wake/reprobe hooks. |
| `lib/stack-start-lock.sh` | Host-global `mkdir` lock, owner metadata, stale detection, health/repair. |
| `lib/continue-worktree.sh` | Generic branch continuation flow for an existing worktree. |
| `lib/launch-worktree-cli.sh` | Built-in agent launcher for terminal tabs and inline sessions. |
| `lib/worktree-launch-mode.sh` | Launch flag normalization and resume-argument mapping. |
| `lib/daemon.sh` | Configured background daemon lifecycle, pidfiles, logs, orphan cleanup. |
| `lib/validate-worktree-name.sh` | Branch/worktree name validation shared by create and continue flows. |
| `worktree-deck.conf.example` | Canonical example of the config contract. |

## Data and State

`worktree-deck` intentionally keeps little durable state:

- git worktree metadata comes from `git worktree list`;
- runtime metadata comes from each worktree's `.env`;
- Docker state comes from the selected daemon;
- PR metadata comes from GitHub CLI output;
- daemon pid/log files live under `WTD_DAEMON_DIR`;
- per-user console state lives at
  `${WORKTREE_DECK_STATE:-$HOME/.config/worktree-deck/console.conf}`;
- stack-start lock metadata lives under `WTD_STACK_START_LOCK` or its default.

The managed application owns its own app state, database state, container
configuration, and environment generation.

## Gaia Integration

Gaia consumes `worktree-deck` as an upstream engine and keeps Gaia-specific
behavior in `worktree-deck.conf` plus local adapter scripts.

Important Gaia-facing integration points are:

- `WTD_MAIN_REPO` pins the main Gaia checkout for global `wc` usage;
- `WTD_STACK_START` and `WTD_STACK_STOP` call Gaia's `gmake` targets;
- `WTD_SERVICE_TEMPLATES`, `WTD_CONTAINER_PREFIX`,
  `WTD_SHARED_CONTAINERS`, and `WTD_ENV_CONTAINER_KEYS` describe Gaia
  containers without hardcoding them upstream;
- `WTD_EVENT_SINK` records launched agent sessions into Gaia's
  `agentic-pr-dash` session registry;
- `WTD_LAST_AGENT_CMD` lets resume reopen the most recent Gaia agent;
- `WTD_DAEMONS` declares the PR dashboard as a configurable daemon;
- Gaia-specific Docker, DB, Auth0, proof, tunnel, and test policy remains in
  Gaia commands invoked by config.

When adding a feature for Gaia, first ask whether it is generic worktree-engine
behavior. Generic behavior belongs here behind a config key or hook. Gaia policy
belongs in Gaia.

## Testing and Maintenance

For shell changes, run syntax and static checks before manual smoke:

```bash
bash -n bin/worktree-deck.sh lib/*.sh
shellcheck bin/worktree-deck.sh lib/*.sh
```

Then smoke the relevant path:

- `worktree-deck lock-health`;
- `worktree-deck run-locked true`;
- `worktree-deck continue <worktree> <branch>` in a disposable repo;
- interactive render from a repo with at least one worktree;
- start/stop/restart only against a safe local test stack or a downstream repo
  whose config you control.

Preserve the non-interactive `wc` guard when editing the entrypoint. It is part
of the public behavior for users who alias the console to `wc`.
