# worktree-deck Architecture

This document explains `worktree-deck` from the outside in. Start here if you
need a mental model before reading the shell code.

## ELI5 Mental Model

Imagine every branch of your app gets its own little desk.

Each desk has:

- a folder with that branch's files;
- maybe a running backend/frontend/worker stack;
- its own ports;
- its own terminal or coding agent;
- a PR that may or may not be open.

`worktree-deck` is the front desk for all of those desks. It keeps a list of
them, shows which ones are running, and gives you buttons to start, stop, open,
clean up, or jump into one.

It is not the app builder. It does not know what Gaia, Rails, Django, Vite, or
Docker Compose need. It only knows: "when the user presses start for this desk,
run the start command the project configured."

The simplest responsibility split is:

```text
worktree-deck:
  "Which worktrees exist, what state are they in, and which generic action
   should happen next?"

the project using it:
  "How do I actually start my app, assign ports, authenticate, seed data,
   run tests, or clean app-specific resources?"
```

For example, Gaia is a downstream application repo that uses `worktree-deck`.
In Gaia, `worktree-deck` owns the generic worktree console. Gaia owns
`gmake start-worktree`, `.env` generation, Docker Compose policy, Auth0 local
host assumptions, database policy, proof bundles, and Gaia-specific scripts.

## One-Sentence Summary

`worktree-deck` turns "many git worktrees" into "many visible, controllable dev
environments" by combining git worktree discovery, configurable stack commands,
Docker status reads, PR metadata, and agent launch hooks.

## What It Owns

`worktree-deck` owns generic mechanics:

- find and display all worktrees for a main repository;
- create, remove, continue, and clean worktrees;
- read per-worktree runtime metadata from `.env`;
- translate a worktree branch into expected container names;
- show whether each worktree's stack appears to be running;
- run configured start, stop, restart, and test commands;
- select local or remote Docker for status and cleanup;
- launch or resume a configured agent CLI inside a worktree;
- manage optional background daemons declared by configuration.

## What It Does Not Own

`worktree-deck` does not own app-specific behavior:

- no Docker Compose files;
- no port-allocation algorithm;
- no database migrations or seeds;
- no Auth0 or browser-login policy;
- no proof-bundle rules;
- no issue-tracker workflow;
- no Gaia-specific paths or Make targets in upstream code.

Those behaviors belong in the consuming project and are exposed to
`worktree-deck` through configuration.

## How To Read The Code

Read the code as a dispatcher around a config contract:

1. `bin/worktree-deck.sh` draws the console and handles user choices.
2. `lib/config.sh` loads defaults plus project config and defines the stable
   `WTD_*` variables and `wtd_*` hook functions.
3. Focused `lib/*.sh` files provide reusable capabilities: Docker reachability,
   daemon management, launch mode handling, stack-start locking, branch
   continuation, and name validation.

Most confusing behavior becomes easier if you ask two questions:

- Is this generic for any repo with worktrees? If yes, it probably belongs here.
- Is this specific to how one app starts or validates itself? If yes, it belongs
  in that app and should enter through config.

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

## Responsibility Boundaries

The stable boundary is the `WTD_*`/`wtd_*` contract.

Application-specific behavior should enter through:

- `WTD_STACK_START`, `WTD_STACK_STOP`, `WTD_STACK_RESTART`, `WTD_E2E_CMD`;
- `WTD_SERVICE_TEMPLATES`, `WTD_ENV_CONTAINER_KEYS`, and port/slot key names;
- `WTD_REMOTE_DOCKER_HOST` and `WTD_REMOTE_TUNNEL_CMD`;
- `WTD_LAUNCH_CMD`, `WTD_AGENT_LAUNCHERS`, `WTD_EVENT_SINK`,
  `WTD_LAST_AGENT_CMD`;
- `WTD_DAEMONS` and the daemon registry maps;
- hook overrides such as `wtd_branch_tag()` or `wtd_launch_cli_from_flag()`.

The rule of thumb: upstream code should provide knobs, not opinions about one
project.

For example, `worktree-deck` can provide `WTD_STACK_START`. Gaia can set it to
`gmake start-worktree`. `worktree-deck` should not hardcode `gmake`, Gaia
container names, Gaia database setup, or Gaia proof rules.

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

In plain terms: every screen refresh asks git, Docker, `.env`, and GitHub for a
small status snapshot, then turns those snapshots into the table you see.

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
