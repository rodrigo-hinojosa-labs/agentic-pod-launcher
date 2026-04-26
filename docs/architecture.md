# Docker Architecture

Docker mode runs each agent inside a container with a self-contained workspace on the host: both the editable files and the agent's private state (login, pairing, sessions) live under the same directory, mounted into the container via two bind-mounts. This section describes the layout, process tree, and lifecycle.

## Host / Container / Volume Layout

```
HOST (e.g. myhost)
├── ~/agents/<name>/                    ← the workspace IS the agent
│   ├── CLAUDE.md
│   ├── .env                            ← 0600, secrets written by wizard
│   ├── agent.yml
│   ├── scripts/heartbeat/
│   │   ├── heartbeat.sh
│   │   ├── heartbeat.conf
│   │   └── logs/
│   ├── docs/
│   ├── .git/
│   └── .state/                         ← bind-mounted to /home/agent inside container
│       └── .claude/                    ← OAuth login, sessions, plugin cache,
│                                         channels/telegram/access.json (pairing)
│
├── /etc/systemd/system/agent-<name>.service   ← host systemd unit
│
└── cloudflared (unchanged, SSH tunnels only)

CONTAINER (agent-admin:latest, one per agent)
├── tini (PID 1)
│   └── entrypoint.sh
│       ├── first-run check → wizard-container.sh (interactive)
│       └── steady-state   → start_services.sh (watchdog + services)
│
├── /opt/agent-admin/                   ← baked in image (read-only)
│   ├── entrypoint.sh
│   ├── scripts/start_services.sh       ← watchdog loop
│   ├── scripts/wizard-container.sh           ← first-run prompts
│   └── crontab.tpl
│
├── /workspace/                         ← bind-mount (host's ~/agents/<name>)
└── /home/agent/                        ← bind-mount (host's ~/agents/<name>/.state)
```

## Process Tree Inside Container

```
PID 1: tini
  └── start_services.sh (bash watchdog)
        ├── crond (background)
        │     └── every 5 min: /workspace/scripts/heartbeat/heartbeat.sh
        │
        ├── tmux server (session "agent")
        │     └── claude CLI (Telegram polling, interactive)
        │
        └── watchdog loop (respawns tmux/claude on death, backoff on repeated crashes)
```

The watchdog polls tmux every 2s (`tmux has-session` plus a channel-plugin liveness check) and respawns on death. After 5 crashes in 5 minutes the container exits and Docker's `unless-stopped` policy restarts it.

## Lifecycle Phases

### Phase 1: Scaffold (host)

```bash
./setup.sh                          # interactive wizard
./setup.sh --destination ~/my-agent # skip the destination prompt
```

Runs interactively on the host. Collects agent config (name, personality, MCPs, notifications) but **does not ask for Telegram chat secrets** — those are deferred to the in-container wizard so they never sit on disk in plaintext outside the bind-mount. Renders:

- `<destination>/` with `agent.yml`, `CLAUDE.md`, `docker-compose.yml`, `.mcp.json`, `scripts/`, `docker/`.
- On Linux only, `/etc/systemd/system/agent-<name>.service` (wraps `docker compose up -d`).

Detects the host user's UID and GID and writes them to `docker-compose.yml` as build args (`UID`, `GID`). The container's `agent` user is created with the same numeric ownership at image-build time so writes through the bind-mount land with the host user's identity.

### Phase 2: First-run wizard (container)

```bash
cd ~/agents/<name> && docker compose up -d && docker attach <name>
```

The host-side wizard intentionally skips Telegram secrets. The first time the container boots:

1. `entrypoint.sh` runs as root, fixes ownership of `/home/agent` (the bind-mount target), renders a safe-default crontab to `/etc/crontabs/agent`, starts the root crontab-sync loop, starts `crond`, then `exec su-exec agent /opt/agent-admin/scripts/start_services.sh`.
2. `start_services.sh::next_tmux_cmd` decides the launch:
    - **Case A** — no Claude profile yet → `claude` (bare) so the user runs `/login` interactively.
    - **Case B** — authenticated but `/workspace/.env` lacks `TELEGRAM_BOT_TOKEN` → `wizard-container.sh` (gum prompts for the token, writes `.env` with 0600). When the wizard exits, the watchdog respawns and re-decides.
    - **Case C** — token present → `claude --channels plugin:telegram@claude-plugins-official --dangerously-skip-permissions [--continue]`.

Each respawn re-evaluates these cases, so going from "no login" → "/login done" → "token saved" happens without manual restart.

### Phase 3: Steady state

`start_services.sh` runs an event loop on the `agent` user:

```text
loop every 2s:
  if crond died             → exit 1   (Docker restarts the container)
  if tmux session alive
     and channel plugin OK  → continue
  if tmux alive but bun     → kill tmux + respawn (forces fresh plugin attachment)
     server.ts gone
  otherwise (tmux gone)     → respawn via next_tmux_cmd

crash budget: 5 crashes within a 300s window → exit 1
```

Real-world detail worth noting:

- **No `pgrep claude`.** Earlier iterations grepped the process tree, which false-positived on every claude subprocess (heartbeat ticks, `claude plugin install`, etc.). The current check is purely on the tmux session.
- **Channel plugin liveness** is checked separately because bun can die while tmux stays up (claude keeps running but stops receiving Telegram messages); kill+respawn re-attaches the plugin.
- **No bridge watchdog.** A previous attempt to detect "bun alive but MCP notifications dropped" via tmux pane scraping was reverted (see commit `ebfe35f`) because the false-positive rate killed sessions every ~2 minutes during normal use. Manual recovery is `heartbeatctl kick-channel`.

Every N minutes (configurable via `agent.yml`'s `features.heartbeat.interval`, default 30m), `crond` dispatches `/workspace/scripts/heartbeat/heartbeat.sh` as the `agent` user. The heartbeat probes the agent and writes a structured trace; the notifier (none / log / telegram, configurable) forwards a status line. See [Heartbeat Pipeline](#heartbeat-pipeline) below.

## Restart Layers

Three independent restart mechanisms:

```
watchdog in-container ──► Docker `unless-stopped` ──► systemd host unit
  (tmux/claude death)      (container exit)           (host reboot / OOM)
```

- **In-container watchdog** respawns tmux/claude on isolated crashes.
- **Docker restart policy** restarts the container if it exits.
- **systemd unit** (on the host) ensures the container starts on boot and restarts if Docker itself crashes.

## Connecting to the Session

```bash
ssh <host>
docker exec -it -u agent <name> tmux attach -t agent
# Ctrl-b d to detach
```

This is exactly one extra hop over the current host-mode flow (`ssh <host> && tmux attach`).

## Upgrade & Rollback

### Upgrade

```bash
# Backup current image
docker tag agent-admin:latest agent-admin:prev

# Update template
cd agent-admin-template && git pull

# Rebuild and restart
cd ~/agents/<name>
docker compose build
docker compose up -d
```

Workspace bind-mount and state volume persist. All agent data survives.

### Rollback

```bash
docker tag agent-admin:prev agent-admin:latest
docker compose up -d
```

Container restarts with the previous image.

## Secrets and Environment Variables

`.env` is a host-side file (0600 permissions) bind-mounted into the container's `/workspace/` directory. The `docker-compose.yml` uses `env_file: ./.env` to inject these into the container's environment.

To rotate secrets (e.g. Telegram token):

```bash
nano ~/agents/<name>/.env
docker compose restart
```

Changes take effect immediately. No rebuild needed.

## Security

- **UID/GID matching:** Container user is created at build time with the host's UID/GID, preventing bind-mount permission issues.
- **Capabilities:** Container drops ALL capabilities and adds only `CHOWN`, `SETUID`, `SETGID` (for the initial entrypoint to chown the volume).
- **Read-only root:** Not currently enforced, but the image layer is read-only; only `/tmp` (tmpfs, 100MB) and bind-mounts are writable.
- **No Docker socket:** Container cannot access `/var/run/docker.sock` or manage the host's Docker.
- **No inbound ports:** Telegram is outbound-only (polling). No services listen on exposed ports.

## Heartbeat Pipeline

The heartbeat is a single scheduled task per agent. `/etc/crontabs/agent`
is rendered by `heartbeatctl reload` from `agent.yml`. Busybox crond
runs as root (launched from entrypoint) so it can `setgid(agent)` when
dispatching the job; `heartbeat.sh` runs as `agent`.

    /etc/crontabs/agent (busybox user crontab, no user field)
         │  every N min
         ▼
    heartbeat.sh (as agent)
      ├─ gen_run_id  →  20260419013000-a3f2
      ├─ tmux new -d -s <agent>-hb-<run_id>  "claude --print <prompt>"
      ├─ wait until HEARTBEAT_DONE or timeout
      ├─ notifiers/<channel>.sh <run_id> <status> → JSON envelope
      ├─ append_run_line   → logs/runs.jsonl
      ├─ write_state_json  → state.json (atomic)
      └─ rotate_runs_jsonl → gz rotation at 10MB

Inspection and mutation go through a single CLI — see
[`docs/heartbeatctl.md`](heartbeatctl.md) for the full reference.

```bash
docker exec -u agent <agent> heartbeatctl status   # dashboard
docker exec -u agent <agent> heartbeatctl logs     # tail runs.jsonl
docker exec -u agent <agent> heartbeatctl set-interval 5m
```

`agent.yml` is the single source of truth. Every mutation backs up to
`agent.yml.prev`, applies via `yq -i`, then regenerates derived files;
any failure restores the backup and re-runs `reload` against the prior
state. `heartbeatctl reload` writes the staging crontab; the
root-privileged sync loop in `entrypoint.sh` installs it into
`/etc/crontabs/` (busybox crond refuses non-root-owned crontabs).

Data files (all under `/workspace/scripts/heartbeat/`):
- `heartbeat.conf` — shell-sourced by heartbeat.sh; regenerated by reload.
- `state.json` — atomic snapshot of last run + counters. Schema 1.
- `logs/runs.jsonl` — one JSON object per run, rotated at 10MB → `.1`,
  `.2.gz`, `.3.gz` (max 3 generations).
- `logs/cron.log` — crond stderr for schedule-dispatch debugging.
- `logs/sessions/` — per-run tmux session logs (last 20 kept).

## See Also

- [Docker Mode User Guide](getting-started.md) — how to scaffold, boot, upgrade, and troubleshoot.
- [Adding an MCP (Docker)](adding-an-mcp.md) — extending the agent with custom MCPs in Docker mode.
- [Design Specification](../superpowers/specs/2026-04-18-agent-admin-docker-mode-design.md) — full technical spec with error handling and testing strategy.
