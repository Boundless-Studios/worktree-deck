# worktree-deck

A terminal dashboard for managing many **git worktrees** — each optionally
backed by its own dev stack. List every worktree with live status, create and
remove them, start/stop their containers, launch an agent CLI inside one, and
open its frontend / IDE / logs — all from one keyboard-driven console.

It is **project-agnostic**: container names, ports, the start/stop commands, the
agent launchers, the remote Docker host, and any background daemons are all
configuration (`worktree-deck.conf`), not hardcoded. Omit the stack config
entirely and you get a clean worktree switcher with no Docker at all.

```
╔═══════════════════════════════════════════════╗
║                🌳 worktree-deck                ║
╚═══════════════════════════════════════════════╝
  *  1   main          💻 ● running   slot 0   B:8000 F:3000   #—
     2   rate-limiter  💻 ● running   slot 2   B:8020 F:3002   #418 OPEN
     3   search-pag…   💻 ○ stopped   slot 3   B:8030 F:3003   #421 OPEN
```

## Install

```bash
git clone https://github.com/Boundless-Studios/worktree-deck ~/.worktree-deck
# add to your shell rc:
alias wtd='bash ~/.worktree-deck/bin/worktree-deck.sh'
```

Requires `git`, `bash`. Optional: `docker` (dev stacks), `gh` (PR status column).

## Configure

Drop a `worktree-deck.conf` at your repo root (see `worktree-deck.conf.example`).
It is sourced shell, so it can set variables and override any `wtd_*` hook.

```bash
# --- Dev stack (optional — omit for pure worktree management) ---
WTD_SERVICE_TEMPLATES=("myapp-backend{suffix}" "myapp-frontend{suffix}")
WTD_STACK_START="make start-worktree"
WTD_STACK_STOP="make stop-worktree"
WTD_CONTAINER_PREFIX="myapp-"     # required to enable dead/orphan container sweeps

# --- .env keys the console reads for display ---
WTD_BACKEND_PORT_KEY="BACKEND_PORT"
WTD_FRONTEND_PORT_KEY="FRONTEND_PORT"
WTD_SLOT_ENV_KEY="WTD_SLOT"

# --- Agents you can launch in a worktree ---
WTD_AGENT_LAUNCHERS=(claude codex)

# --- Optional: a remote Docker daemon, a session-event bridge, daemons ---
# WTD_REMOTE_DOCKER_HOST="ssh://user@build-host"
# WTD_EVENT_SINK="agentic-pr-dash record"
# WTD_DAEMONS=(dash); WTD_DAEMON_CMD[dash]="exec agentic-pr-dash serve"
```

`worktree-deck.conf` is resolved from your repo root (walking up), then a global
`~/.config/worktree-deck/config`; any `WTD_*` value can also come from the
environment.

## What it does

- **List** every worktree of the current repo with a live status row: running /
  stopped dot, local 💻 vs remote 🖥 Docker, slot, ports, and PR number + state
  (via `gh`).
- **Create / remove** worktrees (with branch push + upstream tracking, and a
  stale-worktree reaper for merged/closed/orphan branches).
- **Start / stop / restart** a worktree's dev stack via your configured commands
  (skipped cleanly when no stack is configured).
- **Launch** an agent CLI (Claude, Codex, …) inside a worktree, with an optional
  session-event bridge (`WTD_EVENT_SINK`) — e.g. to feed
  [`agentic-pr-dash`](https://github.com/Boundless-Studios/agentic-pr-dash).
- **Open** the frontend in a browser, the worktree in VS Code, or tail its
  container logs.
- **Container hygiene**: remove dead/exited containers and sweep orphans (gated
  on `WTD_CONTAINER_PREFIX` so it never touches other projects' containers).
- **Remote Docker** support with a local↔remote-SSH reachability probe + fallback.

## Pairs with agentic-pr-dash

`worktree-deck` manages the worktrees; [`agentic-pr-dash`](https://github.com/Boundless-Studios/agentic-pr-dash)
watches the PRs those worktrees open and drives agents to fix them. Wire them
with `WTD_EVENT_SINK` / `WTD_DAEMONS` — or use either on its own.

## License

MIT
