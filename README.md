# agentic-pod-launcher

Lightweight, portable Claude Code agent in a Docker container.

## What this is

`agentic-pod-launcher` is a bash-based template generator. Running `./setup.sh`
prompts you for agent personality, MCP configuration, and notification channel,
then scaffolds a self-contained workspace in a directory you choose. That
workspace contains a `docker-compose.yml`, a `docker/` directory with a
pre-built Alpine image, and all the scripts needed to run a persistent Claude
Code agent entirely inside a container. Once built, `docker compose up` is all
it takes — on any machine with Docker.

The installer clone is disposable after scaffolding. All subsequent operations
(regenerate, uninstall) run from inside the destination directory.

## Prerequisites

- Docker 24+ with the Compose v2 plugin (`docker compose` not `docker-compose`)
- `git`, `yq` v4+, `jq`, and `bash` 4+ on the host (wizard only)
- macOS or Linux (the wizard uses BSD sed on macOS and GNU sed on Linux)

## Quickstart

```bash
git clone git@github.com:rodrigo-hinojosa-labs/agentic-pod-launcher.git
cd agentic-pod-launcher
./setup.sh --destination ~/my-agent
cd ~/my-agent

# Build the image (once, or after editing docker/Dockerfile)
docker compose build

# Start the container
docker compose up -d

# Attach to the first-run wizard inside the container
docker exec -it -u agent my-agent tmux attach -t agent
# The wizard prompts you to run /login once, collects Anthropic and optional
# Atlassian / GitHub tokens, and starts the Telegram channel server if
# configured. Detach with Ctrl-B then D.
```

To regenerate after editing `agent.yml`:

```bash
cd ~/my-agent
./setup.sh --regenerate   # re-renders docker-compose.yml + .mcp.json
```

## Features

- Single deployment mode — Docker only, no host-mode mental overhead.
- Container-aware `CLAUDE.md` — the agent knows it runs inside a container via
  a refreshed `CONTAINER.md` baked into the image at build time.
- Self-healing — `verify_channel_healthy` respawns the tmux session if the
  Telegram channel server fails to start.
- Optional Telegram channel server for two-way chat with the agent.
- In-container `crond` running the periodic heartbeat; notifier drivers are
  pluggable (none, log, Telegram).
- UID/GID matched to host at build time for bind-mount parity.
- Named volume for `/home/agent` isolates the agent's `.claude` profile and
  plugin cache from the bind-mounted workspace.

## Architecture

The image is built on Alpine 3.20 and includes `bash`, `tmux`, `nodejs`/`npm`,
`git`, `tini`, `su-exec`, `busybox crond`, `gum`, `bun`, `uv`, and the Claude
Code CLI. `tini` is the container init process; it reaps zombies and forwards
signals cleanly. `crond` runs the heartbeat schedule. `tmux` hosts the agent
session so it survives detaches and container restarts.

See [docs/architecture.md](docs/architecture.md) for the render engine, module
system, and data-flow diagram. See [docs/docker-mode.md](docs/docker-mode.md)
for container-specific design decisions, upgrade paths, and teardown.

## Testing

The test suite uses `bats-core` and requires `bats-core`, `yq` v4+, `jq`,
`git`, and `tmux` on the host.

```bash
bats tests/          # full suite
bats tests/render.bats   # single file
```

## Uninstall

```bash
cd ~/my-agent
./setup.sh --uninstall --yes   # stops container + removes generated files
./setup.sh --uninstall --purge --yes   # also removes agent.yml + .env
./setup.sh --uninstall --nuke --yes    # deletes the workspace directory
```

## License

MIT. See [LICENSE](LICENSE).

## Lineage

Forked from agent-admin-template.
