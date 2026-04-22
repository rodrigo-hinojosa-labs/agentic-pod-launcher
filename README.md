# agentic-pod-launcher

Lightweight, portable Claude Code agent in a Docker container — with an observable, mutable scheduled-task ("heartbeat") system out of the box.

## What this is

`agentic-pod-launcher` is a bash-based template generator. Running `./setup.sh` prompts you for agent personality, MCP configuration, notification channel, and heartbeat schedule, then scaffolds a self-contained workspace in a directory you choose. That workspace contains a `docker-compose.yml`, a `docker/` directory with a pre-built Alpine image, and all the scripts needed to run a persistent Claude Code agent entirely inside a container. Once built, `docker compose up -d` is all it takes — on any machine with Docker.

The installer clone is disposable after scaffolding. All subsequent operations (regenerate, uninstall) run from inside the destination directory.

## Prerequisites

- Docker 24+ with the Compose v2 plugin (`docker compose`, not `docker-compose`)
- `git`, `yq` v4+, `jq`, and `bash` 4+ on the host (wizard only)
- macOS or Linux (the wizard uses BSD sed on macOS and GNU sed on Linux)

## Quickstart

```bash
git clone git@github.com:rodrigo-hinojosa-labs/agentic-pod-launcher.git
cd agentic-pod-launcher
./setup.sh --destination ~/my-agent
cd ~/my-agent

# Build the image and start the container
docker compose build
docker compose up -d

# 1. Attach to the agent's tmux session
docker exec -it -u agent my-agent tmux attach -t agent

#    a. Pick a theme and accept trust on /workspace.
#    b. /login → paste OAuth code → /exit (or Ctrl-D).
#    c. Wait ~2-3 seconds, then re-attach. The supervisor relaunches
#       claude into the in-container wizard for the Telegram bot token.
#    d. Paste the token at the prompt; the wizard updates a refreshed
#       CLAUDE.md with live workspace info, then exits.
#    e. Re-attach once more, send a DM to your bot, and run
#       `/telegram:access pair <code>` to authorize your chat.
#    f. Detach with Ctrl-b d.
```

Full step-by-step (including troubleshooting) is in [`docs/getting-started.md`](docs/getting-started.md). Each scaffolded agent also gets a `NEXT_STEPS.md` rendered with concrete commands using the agent's name and paths.

## What you get

- **Single deployment mode** — Docker only, no host-mode mental overhead.
- **Container-aware `CLAUDE.md`** — refreshed at boot from `CONTAINER.md` (live OS, kernel, paths, MCPs). Wizard runs `claude --print` once at first boot to enrich the agent's base memory file with workspace-specific commands and architecture notes.
- **Self-healing supervisor** — `start_services.sh` watches tmux + crond + the channel plugin (bun); respawns each on death with bounded crash-restart logic.
- **Telegram chat plugin** — optional two-way chat with the agent via `claude-plugins-official/telegram`. `heartbeatctl kick-channel` for manual recovery if the upstream plugin's MCP bridge wedges.
- **Persistent "typing…" indicator** — auto-applied post-install patch keeps the Telegram typing action refreshed every 4s while Claude is processing a message (upstream fires once and expires at 5s, leaving the user staring at silence during tool calls or longer thinks). Idempotent via marker comment and fail-silent if the upstream source drifts — re-applied on every boot by `start_services.sh` against the plugin cached in the state volume.
- **Heartbeat with structured observability** — `crond` inside the container fires `scripts/heartbeat/heartbeat.sh` on a schedule you pick. Each run gets a JSON-line entry in `runs.jsonl` (with `run_id`, status, duration, notifier envelope) and an atomic `state.json` snapshot.
- **`heartbeatctl` CLI** — single command to inspect, control, and mutate the heartbeat at runtime. Mutations write back to `agent.yml` (source of truth) with atomic rollback. See [`docs/heartbeatctl.md`](docs/heartbeatctl.md) for the full reference.
- **Pluggable notifier drivers** — `none`, `log`, `telegram`. Each driver follows a JSON-envelope contract and never crashes the heartbeat.
- **Headless-friendly settings** — `permissions.defaultMode=auto` and `skipDangerousModePermissionPrompt=true` set at every boot so the chat-driven workflow doesn't stall on approval dialogs.
- **UID/GID matched to host** at build time for bind-mount parity.
- **Self-contained workspace** — all agent state (login, Telegram pairing, session history, plugin cache) lives under `<workspace>/.state/` via bind-mount to `/home/agent` in the container. The workspace directory IS the agent: portable via `rsync` / `cp -r`, immune to `docker compose down -v`, removed only when the workspace is deleted. `.state/` is git-ignored; it contains OAuth tokens and secrets.

## `heartbeatctl` at a glance

```bash
docker exec -u agent <agent-name> heartbeatctl status         # dashboard
docker exec -u agent <agent-name> heartbeatctl logs           # tail runs.jsonl
docker exec -u agent <agent-name> heartbeatctl test           # one tick now
docker exec -u agent <agent-name> heartbeatctl pause          # comment crontab + enabled=false
docker exec -u agent <agent-name> heartbeatctl resume         # inverse
docker exec -u agent <agent-name> heartbeatctl set-interval 5m
docker exec -u agent <agent-name> heartbeatctl kick-channel   # respawn the chat session
```

Always pass `-u agent` — `cap_drop: ALL` means root inside the container can't write agent-owned files. Full reference: [`docs/heartbeatctl.md`](docs/heartbeatctl.md).

## Architecture

The image is built on Alpine 3.20 and includes `bash`, `tmux`, `nodejs`/`npm`, `git`, `tini`, `su-exec`, `busybox crond`, `gum`, `bun`, `uv`, and the Claude Code CLI. `tini` is the container init process; it reaps zombies and forwards signals cleanly. `crond` runs as root from `entrypoint.sh` (so it can `setgid` agent on dispatch). A small sync loop in entrypoint copies the heartbeatctl-managed staging crontab into `/etc/crontabs/` (busybox crond requires root-owned crontabs). `tmux` hosts the agent session so it survives detaches and container restarts.

See [`docs/architecture.md`](docs/architecture.md) for the render engine, container lifecycle, the heartbeat data contracts (`runs.jsonl`, `state.json`), and the privilege model.

## Regenerate after editing `agent.yml`

```bash
cd ~/my-agent
./setup.sh --regenerate   # re-renders docker-compose.yml + .mcp.json + heartbeat.conf
```

Or mutate live without regenerating:

```bash
docker exec -u agent my-agent heartbeatctl set-prompt "Report status as plain text"
docker exec -u agent my-agent heartbeatctl set-interval 15m
```

Mutations write to `agent.yml` first (so a clone gets the same state), then propagate to `heartbeat.conf` and the live crontab via the sync loop within ~75 seconds.

## Testing

The test suite uses `bats-core` and requires `bats-core`, `yq` v4+, `jq`, `git`, and `tmux` on the host. ~160 tests covering the render engine, YAML lib, interval-to-cron converter, state-lib helpers, notifier contracts, the heartbeat runner, and every `heartbeatctl` subcommand.

```bash
bats tests/                       # full suite
bats tests/heartbeatctl.bats      # single file
bats tests/render.bats -f "name"  # single test by name

DOCKER_E2E=1 bats tests/docker-e2e-heartbeat.bats   # opt-in e2e (builds + boots a container)
```

## Uninstall

```bash
cd ~/my-agent
./setup.sh --uninstall --yes              # stops container, removes named volume + generated files
./setup.sh --uninstall --purge --yes      # also removes agent.yml + .env
./setup.sh --uninstall --nuke --yes       # also deletes the workspace directory
```

## License

MIT. See [LICENSE](LICENSE).

## Lineage

Forked from agent-admin-template.
