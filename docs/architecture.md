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

The watchdog detects tmux or claude crashes via `pgrep` and respawns the session with exponential backoff. After 5 crashes in 5 minutes, it exits (causing Docker to restart the container via the `unless-stopped` policy).

## Lifecycle Phases

### Phase 1: Scaffold (host)

```bash
./setup.sh --docker
```

Runs interactively on the host. Collects agent config (name, personality, MCPs, notifications) but **does not ask for secrets**. Renders:

- `~/agents/<name>/` with CLAUDE.md, agent.yml, docker-compose.yml, scripts.
- `/etc/systemd/system/agent-<name>.service` (wraps `docker compose up -d`).

Detects the host user's UID and GID and writes them to `docker-compose.yml` as build args (`AGENT_UID`, `AGENT_GID`). This ensures files in the bind-mount are owned correctly.

### Phase 2: First-run Wizard (container)

```bash
cd ~/agents/<name> && docker compose up -d && docker attach <name>
```

On container start, the entrypoint checks for `/workspace/.env`:

```sh
if [ ! -f /workspace/.env ] || ! grep -q "TELEGRAM_BOT_TOKEN" /workspace/.env ]; then
  exec /opt/agent-admin/scripts/wizard-container.sh --in-container
fi
exec /opt/agent-admin/scripts/start_services.sh
```

The wizard fires interactively (via `gum` prompts inside the container):

1. Telegram bot token
2. Telegram chat ID
3. GitHub PAT (optional)

Writes `/workspace/.env` with 0600 permissions. On completion, the wizard exits. Docker's `unless-stopped` policy restarts the container. The entrypoint finds `.env` and proceeds to Phase 3.

### Phase 3: Steady State

The container runs:

```bash
# Setup crontab for heartbeat
envsubst < /opt/agent-admin/crontab.tpl > /etc/crontabs/agent
crond -b -L /var/log/crond.log

# Start tmux with claude
tmux new-session -d -s agent -c /workspace \
  "CLAUDE_CONFIG_DIR=/home/agent/.claude-personal claude --channels plugin:telegram@claude-plugins-official"

# Watchdog loop: monitor and respawn on crash
CRASH_COUNT=0
WINDOW_START=$(date +%s)
MAX_CRASHES=5
WINDOW=300
while true; do
  sleep 10
  if ! tmux has-session -t agent 2>/dev/null || ! pgrep -f claude >/dev/null; then
    now=$(date +%s)
    [ $((now - WINDOW_START)) -gt $WINDOW ] && { CRASH_COUNT=0; WINDOW_START=$now; }
    CRASH_COUNT=$((CRASH_COUNT + 1))
    if [ $CRASH_COUNT -ge $MAX_CRASHES ]; then
      echo "CRITICAL: $MAX_CRASHES crashes in ${WINDOW}s, exiting"
      exit 1
    fi
    respawn_tmux_session
  fi
done
```

Every 5 minutes, cron runs the heartbeat script from the workspace, which probes the agent and reports status via Telegram.

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
