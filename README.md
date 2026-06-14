# worktree-deck

**A terminal control panel for running many branches of your app at once — each in its own isolated, fully-running dev environment.**

If you've ever wanted to work on three features in parallel without `git stash`,
without rebuilding, and without four copies of your app fighting over port 3000 —
this is that. `worktree-deck` turns [git worktrees](https://git-scm.com/docs/git-worktree)
into a fleet of live, side-by-side development environments and gives you one
keyboard-driven console to see and drive all of them.

```
╔═══════════════════════════════════════════════╗
║                🌳 worktree-deck                ║
╚═══════════════════════════════════════════════╝
  Docker:  💻 local

   #  worktree         status        slot   ports            PR
  ─────────────────────────────────────────────────────────────────
  * 1   main           ● running      0     B:8000 F:3000    —
    2   rate-limiter   ● running      2     B:8020 F:3002    #418 OPEN
    3   search-paging  ○ stopped      3     B:8030 F:3003    #421 OPEN
    4   checkout-retry 🖥 ● running    5     B:8050 F:3005    #412 OPEN
  ─────────────────────────────────────────────────────────────────
  [#] select   [n]ew   [X] stop+clean all   [M] reap stale   [q]uit
```

---

## Why this exists

A normal git checkout has **one** working directory and **one** running copy of
your app. To switch branches you stash, check out, rebuild, restart, and hope
nothing else was mid-flight. That's painful when you're reviewing a teammate's
PR while your own feature is half-built — or when you're running several coding
agents in parallel, each on its own branch.

**Git worktrees** solve the *filesystem* half: one repo, many working
directories, each on its own branch, all sharing one `.git`. But a checkout
isn't a running app. The missing half is the *runtime* — each worktree needs its
own backend, frontend, database connections, workers, and ports, all isolated so
worktree #2 can't clobber worktree #3.

`worktree-deck` manages **both halves**: the worktrees *and* their per-worktree
runtimes, with one console to list, create, start, stop, inspect, and jump into
any of them.

## Mental model

Think of every branch as its own desk: one folder, one optional running app
stack, one set of ports, and one place where a coding agent can work.
`worktree-deck` is the front desk. It shows all the desks and lets you start,
stop, open, clean, or jump into them.

It does not know how your app works. Your project supplies commands like
`make start-worktree` and decides how ports, containers, databases, auth, and
tests work. For example, Gaia is one downstream app repo that uses
`worktree-deck`; Gaia owns its own Docker, database, and auth setup, while
`worktree-deck` owns the generic multi-worktree control panel.

## The execution model: one Docker stack per worktree

This is the core idea, and it's worth understanding before you configure
anything.

Each worktree gets its **own complete copy of your app's services**, running as
Docker containers, fully isolated from every other worktree:

```
            ┌─────────────────────── your machine (or a remote Docker host) ───────────────────────┐
            │                                                                                       │
  worktree  │   ┌───────── slot 2 ─────────┐   ┌───────── slot 3 ─────────┐   ┌──── slot 5 ────┐    │
  directories│  │ app-backend-rate-limiter │   │ app-backend-search-pag…  │   │ app-backend-…  │    │
  (one per   │  │ app-frontend-rate-limiter│   │ app-frontend-search-pag… │   │ app-frontend-… │    │
  branch)    │  │ app-worker-rate-limiter  │   │ app-worker-search-pag…   │   │ app-worker-…   │    │
            │   │   :8020 / :3002          │   │   :8030 / :3003          │   │  :8050 / :3005 │    │
            │   └──────────────────────────┘   └──────────────────────────┘   └────────────────┘    │
            │            ▲                                                                            │
            │            └── shared infra (one copy, reused): postgres, rabbitmq, …                  │
            └───────────────────────────────────────────────────────────────────────────────────────┘
```

Three things make this work, and all three are **configurable, not hardcoded**:

### 1. Slots → deterministic, non-colliding ports

Every worktree is assigned a small integer **slot** (0, 1, 2, …). The slot
derives the worktree's ports so two worktrees never collide — e.g. with the
common scheme `backend = 8000 + slot*10`, `frontend = 3000 + slot`:

| worktree | slot | backend | frontend |
|----------|------|---------|----------|
| main | 0 | 8000 | 3000 |
| rate-limiter | 2 | 8020 | 3002 |
| search-paging | 3 | 8030 | 3003 |

`worktree-deck` reads the assigned ports/slot from each worktree's `.env`
(you control which keys: `WTD_BACKEND_PORT_KEY`, `WTD_SLOT_ENV_KEY`, …) and shows
them in the status table. The console doesn't *assign* slots — your
start-command does that; `worktree-deck` reads and displays them.

### 2. Container names → templated per worktree

So that worktree #2's backend and worktree #3's backend are different containers,
each worktree's container names carry a **suffix derived from its branch**. You
give templates with a `{suffix}` placeholder:

```bash
WTD_SERVICE_TEMPLATES=("app-backend{suffix}" "app-frontend{suffix}" "app-worker{suffix}")
```

For branch `feature/rate-limiter`, `{suffix}` becomes `-rate-limiter`, so the
containers are `app-backend-rate-limiter`, `app-frontend-rate-limiter`, … The
main checkout on `main`/`master` gets an empty suffix (`app-backend`).

`worktree-deck` uses these names to show running/stopped status per worktree, to
tail the right logs, and to find **orphan** containers (a container whose
worktree was deleted) so it can offer to clean them up — gated on
`WTD_CONTAINER_PREFIX` so it never touches containers from other projects.

### 3. Local vs. remote Docker daemon

The stacks can run on your **local** Docker (Docker Desktop / Colima / native),
or — if your laptop can't comfortably run several full stacks — on a **remote**
Docker host over SSH (`DOCKER_HOST=ssh://user@build-box`). `worktree-deck`:

- shows which daemon each row is talking to (💻 local vs 🖥 remote),
- probes remote reachability cheaply and **falls back to local** when the remote
  is unreachable, so the console never hangs on a dead SSH connection,
- can run an optional tunnel command (`WTD_REMOTE_TUNNEL_CMD`) before opening a
  remote worktree's frontend in your browser, so `localhost:<port>` resolves.

Set `WTD_REMOTE_DOCKER_HOST` and that's it; leave it empty for local-only.

### Starting and stopping a stack

`worktree-deck` doesn't know *how* to build your app — you tell it. The
`[s]tart` / `[x]stop` actions run **your** commands:

```bash
WTD_STACK_START="make start-worktree"   # whatever brings one worktree's stack up
WTD_STACK_STOP="make stop-worktree"
```

Typically that command runs `docker compose up` with the worktree's `.env`
(its slot, ports, and container names). `worktree-deck` orchestrates *which*
worktree and *when*; your command owns the *how*.

#### Serialized starts, a concurrency cap, and continue-worktree

Three optional, config-gated behaviors help when several worktrees share a host:

- **Serialize starts.** Set `WTD_SERIALIZE_STACK_START=1` and only one worktree's
  start runs at a time. Useful when your start command touches *host-global*
  resources (a shared file-sync session, a shared image builder, shared cleanup
  sweeps) that two concurrent starts would trample. The lock is an advisory,
  host-scoped `mkdir` lock with PID + process-start-token stale reclaim (no
  `flock` needed, so it works on macOS). Diagnose or repair a stuck lock with:

  ```bash
  worktree-deck lock-health            # report holder + how long it's been held
  worktree-deck lock-health --repair   # clear it only if the holder is dead/stale
  ```

  To serialize a start command you drive yourself (e.g. from a Makefile) under
  that *same* lock — without routing it through the console's `wtd_stack_start` —
  run it via `run-locked` (always serialized, regardless of
  `WTD_SERIALIZE_STACK_START`); `lock-health` inspects the same lock:

  ```bash
  worktree-deck run-locked <command> [args...]   # e.g. run-locked make start-stack
  ```

  While the lock is held, `WTD_STACK_START_LOCK_HELD` is exported (set to the
  lock dir) into the command's environment. A project whose own start target
  routes through `run-locked` should check it and run its impl **directly** when
  set — otherwise a console start (which already holds this lock before invoking
  `WTD_STACK_START`) would make the target wait on the non-reentrant lock it
  already holds.

- **Cap concurrent stacks.** Set `WTD_BACKEND_CAP=N` to refuse a start once `N`
  stacks are already running (counted from the first `WTD_SERVICE_TEMPLATES`
  entry). Protects a shared host from running out of RAM. The console enforces
  this automatically. A project that drives its own start command gets the
  *same* enforcement by adding `--cap` to `run-locked`: the cap count and the
  start happen **atomically under one lock**, so two concurrent starts can't both
  see free capacity and then both start. No-op cap when `WTD_BACKEND_CAP` is
  `0`/unset; the cwd worktree's own containers are excluded so a restart isn't
  self-counted. The cap is counted on the configured `WTD_REMOTE_DOCKER_HOST`
  when set (same daemon the stack starts on):

  ```bash
  worktree-deck run-locked --cap <start-command>   # e.g. run-locked --cap make start-stack
  ```

- **Continue on a new branch.** After a PR merges and its branch is deleted, keep
  the worktree and repoint it onto a fresh branch instead of recreating it — from
  the worktree action menu (`[n]ext`) or the CLI:

  ```bash
  worktree-deck continue <worktree-name-or-path> <new-branch> [base]   # base defaults to origin/main
  ```

  It validates the name, fetches the base, stashes local work, creates/rebases the
  branch, pushes with upstream tracking, regenerates env via `WTD_ENV_REGEN_CMD`
  (if set), and pops the stash.

### Don't use Docker? It still helps.

The entire stack layer is optional. Omit `WTD_SERVICE_TEMPLATES` /
`WTD_STACK_START` and `worktree-deck` becomes a clean **worktree switcher**:
list, create, remove, jump into, and reap stale worktrees — with the live PR
column — and nothing Docker-related.

---

## What the console does

- **List** every worktree of the current repo with a live row: running/stopped
  dot, local 💻 vs remote 🖥 Docker, slot, ports, and PR number + state (via `gh`).
- **Create / remove** worktrees — creates the branch, pushes it with correct
  upstream tracking, and drops you straight into its action menu. A stale-worktree
  reaper finds merged/closed/orphaned branches and offers to clean them up.
- **Start / stop / restart** a worktree's dev stack via your configured commands.
- **Launch an agent CLI** (Claude Code, Codex, aider, …) *inside* a worktree, in
  a new terminal tab, with the right working directory — with an optional
  session-event bridge (`WTD_EVENT_SINK`).
- **Resume an agent** (`<n>r`) — relaunch the agent that last worked a worktree
  with its resume flags (`claude --continue` / `codex resume --last`). Which
  agent ran last comes from the optional `WTD_LAST_AGENT_CMD` hook; without it,
  resume uses the worktree's default launcher.
- **Open** the frontend in a browser, the worktree in VS Code, or tail its
  container logs.
- **Container hygiene** — remove dead/exited containers and sweep orphans, scoped
  to your project's container prefix.
- **Quick commands** — `7s` = select #7 + start, `1r` = resume #1's last agent,
  `7dy` = delete #7 + confirm.

For maintainers, see [Architecture](docs/ARCHITECTURE.md) for the setup model,
configuration contract, runtime flows, and code map.

## Install

```bash
git clone https://github.com/Boundless-Studios/worktree-deck ~/.worktree-deck
# then add to your shell rc (~/.zshrc, ~/.bashrc):
alias wtd='bash ~/.worktree-deck/bin/worktree-deck.sh'
```

**Requires:** `git`, `bash`.
**Optional:** `docker` (per-worktree stacks), `gh` (the PR status column),
`code` (open in VS Code), and on macOS iTerm2 for split-pane launches.

Run `wtd` from inside any git repo — it manages that repo's worktrees.

## Configure

Drop a `worktree-deck.conf` at your repo root (resolved by walking up from the
repo, then `~/.config/worktree-deck/config`). It's **sourced shell**, so you can
set variables *and* override any `wtd_*` hook for full control. A complete
Docker-backed example:

```bash
# --- the per-worktree Docker stack ---
WTD_SERVICE_TEMPLATES=("app-backend{suffix}" "app-frontend{suffix}" "app-worker{suffix}")
WTD_CONTAINER_PREFIX="app-"                 # enables the dead/orphan sweeps, scoped to your project
WTD_SHARED_CONTAINERS="app-postgres app-rabbitmq"   # one copy, never swept
WTD_STACK_START="make start-worktree"       # your command to bring a stack up
WTD_STACK_STOP="make stop-worktree"
WTD_E2E_CMD="make e2e-test"                  # optional

# --- how the console reads each worktree's .env for display ---
WTD_BACKEND_PORT_KEY="BACKEND_PORT"
WTD_FRONTEND_PORT_KEY="FRONTEND_PORT"
WTD_SLOT_ENV_KEY="APP_SLOT"
# .env keys recording each worktree's ACTUAL container names — matched in
# addition to the branch-derived names, so a worktree whose containers aren't
# derivable from its current branch (renamed branch, custom names) still matches
# instead of looking orphaned.
WTD_ENV_CONTAINER_KEYS="BACKEND_CONTAINER_NAME FRONTEND_CONTAINER_NAME"

# --- agents you can launch in a worktree (first = default) ---
WTD_AGENT_LAUNCHERS=(claude codex)

# --- optional: run stacks on a beefier remote Docker host over SSH ---
WTD_REMOTE_DOCKER_HOST="ssh://user@build-box"
# WTD_REMOTE_TUNNEL_CMD="bash scripts/start-tunnel.sh"   # ensure localhost:<port> resolves

# --- optional: bridge worktree session events to another tool ---
# WTD_EVENT_SINK="agentic-pr-dash record"

# --- optional: route the console's launch/resume actions through your own
# launcher (same `<worktree_path> <launch_flag> [extra_args]` contract as the
# built-in one), so the console and your other launch flows share ONE launcher ---
# WTD_LAUNCH_CMD="bash scripts/launch-worktree-cli.sh"

# --- optional: tell the resume action (<n>r) which agent last ran a worktree ---
# Receives the worktree path as its final arg; prints "claude" or "codex".
# Without this, resume just relaunches the worktree's default launcher.
# WTD_LAST_AGENT_CMD="agentic-pr-dash last-agent"

# --- optional: background daemons the console can toggle (e.g. a dashboard) ---
# WTD_DAEMONS=(dash)
# WTD_DAEMON_CMD[dash]="exec agentic-pr-dash serve"
# WTD_DAEMON_URL[dash]="http://localhost:9000"
# WTD_DAEMON_PATTERN[dash]="agentic-pr-dash"
```

Every value is optional and has a project-agnostic default; any `WTD_*` can also
come from the environment. See `worktree-deck.conf.example` for the full list.

### Where config is loaded from

worktree-deck sources, in order (later wins):

1. a repo-local `worktree-deck.conf` (walking up from the cwd's repo), then
2. a global `~/.config/worktree-deck/config`.

Because `worktree-deck` figures out which repo to manage from your **current
directory's** git root, two tips for a smooth setup:

- **Run `wc` from outside the repo** (e.g. your home dir)? Pin the repo so it
  doesn't depend on cwd — put `WTD_MAIN_REPO="$HOME/code/myapp"` in the **global**
  config. (worktree-deck errors clearly rather than silently listing nothing if
  it can't find a repo.)
- A repo-local `worktree-deck.conf` only loads when you run from a checkout that
  has it (it's a tracked file, so branch-dependent). For config that should apply
  no matter which worktree/branch you're on, prefer the **global** location.

## Pairs with agentic-pr-dash

`worktree-deck` manages the worktrees; its sibling
[**agentic-pr-dash**](https://github.com/Boundless-Studios/agentic-pr-dash)
watches the PRs those worktrees open and drives agents to fix failing CI and
review comments — with a one-agent-per-PR ownership lease. Wire them together
with `WTD_EVENT_SINK` (worktree sessions → dashboard) and `WTD_DAEMONS` (run the
dashboard from the console), or use either entirely on its own.

## License

MIT
