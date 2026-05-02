# agentic-pod-launcher

A wizard that scaffolds persistent Claude Code agents in Docker, with two-way Telegram chat, structured heartbeat observability, plugin auto-management, and durable memory across restarts.

## What this is

`agentic-pod-launcher` is a bash-based template generator. Running `./setup.sh` prompts for agent personality, plugins, MCPs, notification channel, and heartbeat schedule, then scaffolds a self-contained workspace anywhere on disk. That workspace contains a `docker-compose.yml`, a `docker/` directory with the Alpine-based image source, and the scripts the container needs to run a Claude Code agent end-to-end. Once built, `docker compose up -d` is enough on any machine with Docker.

The launcher clone is disposable after scaffolding. Every subsequent operation (`--regenerate`, `--uninstall`, `heartbeatctl ...`) runs from inside the destination workspace.

## Prerequisites

- Docker 24+ with the Compose v2 plugin (`docker compose`, not `docker-compose`).
- `git`, `yq` v4+, `jq`, and `bash` 4+ on the host (wizard only).
- macOS or Linux (the wizard tolerates both BSD and GNU `sed`).

## Quickstart

```bash
git clone git@github.com:rodrigo-hinojosa-labs/agentic-pod-launcher.git
cd agentic-pod-launcher
./setup.sh --destination ~/agents/my-agent
cd ~/agents/my-agent

docker compose build
./scripts/agentctl up        # docker compose up -d

# Attach to the agent's tmux session (retries while the supervisor respawns).
./scripts/agentctl attach
#  a. Pick a theme, accept trust on /workspace.
#  b. /login → paste OAuth code → /exit.
#  c. Re-run `./scripts/agentctl attach`. The supervisor relaunches claude
#     into the in-container wizard for the Telegram bot token (only on first boot).
#  d. Paste the token. The wizard regenerates CLAUDE.md with live workspace
#     info and exits.
#  e. Re-attach again. DM your bot, then run `/telegram:access pair <code>`
#     to authorize your chat.
#  f. Detach with Ctrl-b d.
```

`agentctl` is a thin host wrapper for the most common `docker exec -u agent NAME ...` patterns. It resolves the container name from `agent.yml`, applies `-u agent` automatically, and includes a retry-loop in `attach` for the post-`/login` window. Subcommands: `doctor` (full diagnostic), `attach`, `logs [-f]`, `status`, `heartbeat <sub>`, `mcp [list]`, `shell [--root]`, `up`, `stop`, `restart`, `ps`, `run <cmd…>`. Run `./scripts/agentctl --help` for the full list.

When something looks off, the first move is **`./scripts/agentctl doctor`** — it checks Docker daemon, container status, healthcheck, agent.yml, .env, tmux, crond, the Telegram plugin, the heartbeat, the vault, and the plugin patches in dependency order, and prints an actionable hint per failing subsystem.

The full step-by-step (with troubleshooting) lives in [`docs/getting-started.md`](docs/getting-started.md). Each scaffolded agent also gets a `NEXT_STEPS.md` with concrete commands using the agent's name and paths.

### Agentic mode (one-prompt setup)

If you'd rather drive the wizard from a Claude Code session than answer 30+ prompts in your shell, open `claude` inside the repo and run `/quickstart`. The slash command reads `tests/helper.bash::wizard_answers()` (the canonical prompt order) and `docs/agentic-quickstart.es.md` (field semantics + safe defaults), asks you for the minimum required values in a single message, and runs `./setup.sh` with the answers piped in. Full details (and a copy-paste alternative for non-Claude environments) in [`docs/agentic-quickstart.es.md`](docs/agentic-quickstart.es.md) — English version at [`docs/agentic-quickstart.en.md`](docs/agentic-quickstart.en.md).

## What's in the box

### Scaffolding from `agent.yml`

The wizard collects answers into `agent.yml` and treats it as the **single source of truth**. Every derived file (`docker-compose.yml`, `.mcp.json`, `CLAUDE.md`, `scripts/heartbeat/heartbeat.conf`, `.env` skeleton, `NEXT_STEPS.md`) is rendered from it via `scripts/lib/render.sh`. Re-running `./setup.sh --regenerate` re-emits all derived files. Editing a derived file by hand without touching `agent.yml` will be silently overwritten on the next regenerate.

### Self-healing supervisor

Inside the container, `tini` is PID 1; `entrypoint.sh` runs as root for crontab installation, then drops to the `agent` user via `su-exec`. `start_services.sh` runs as `agent` on a 2-second poll and supervises three independent things:

- The tmux session that hosts the interactive Claude session.
- `crond` (busybox), which dispatches the scheduled heartbeat.
- The Telegram channel plugin's `bun server.ts` MCP server.

Crashes of any of these get respawned automatically. A sliding 300-second crash budget exits the container after 5 crashes so Docker's `unless-stopped` policy can take over the recovery layer.

### Two-way Telegram chat

The agent ships with the `claude-plugins-official/telegram` channel plugin enabled by default. Boot-time post-install hooks layer four behaviors on top of the upstream plugin:

- **Persistent "typing…" indicator** — the upstream plugin fires `sendChatAction` once per inbound and Telegram auto-expires the action at ~5 seconds. The post-install hook adds a 4-second refresh interval (with a 120-second hard cap) so the user sees "typing…" continuously while Claude is processing, including during long tool calls.
- **Durable update offset on reply** — the Telegram `update_id` cursor is persisted to `~/.claude/channels/telegram/last-offset.json` only after a `reply` MCP tool call returns successfully. If the plugin process dies between "Claude received the inbound" and "Claude actually replied," the offset stays put and Telegram re-delivers the update on the next plugin start. End-to-end at-least-once semantics, not just at-least-once-on-inbound.
- **Single-primary lock** — the plugin's PID file is refreshed every 5 seconds while the primary instance polls. Any second instance (spawned, for example, by a sub-Claude that happens to load the plugin) reads the PID file, sees a fresh `mtime`, and exits cleanly instead of taking over the bot token. The primary keeps polling without interruption.
- **Forensic stderr** — the plugin's stderr (including unhandled exceptions and rejections) is teed to `<workspace>/scripts/heartbeat/logs/telegram-mcp-stderr.log`. The MCP transport otherwise consumes stderr; this gives crashes a place to leave evidence.

All four hooks are idempotent (each guarded by a marker comment) and fail-silent if any anchor in the upstream plugin source drifts — the plugin keeps its default behavior in that case.

For the silent-stuck case where the bun process is alive but its MCP notifications stop reaching Claude (an upstream-bridge bug), `heartbeatctl kick-channel` forces a clean respawn of the channel session.

### Heartbeat with structured observability

`crond` inside the container fires `scripts/heartbeat/heartbeat.sh` on a schedule chosen at scaffold (default: every 30 minutes). Each tick:

- Spawns an isolated `claude --print` in a separate tmux session under a dedicated `CLAUDE_CONFIG_DIR=/home/agent/.claude-heartbeat`.
- That config dir shares OAuth credentials with the main agent (via symlink) but ships its own `settings.json` with `enabledPlugins: {}` and an empty `plugins/` directory — so heartbeat ticks don't load the channel plugin and don't touch the interactive session's plugin processes.
- Captures Claude's stdout, ANSI-strips it, caps at 3500 chars, and forwards via the configured notifier (`none`, `log`, or `telegram`).
- Appends a structured JSON line to `logs/runs.jsonl` (size-rotated at 10 MB → `.1`, `.2.gz`, `.3.gz`).
- Atomically rewrites `state.json` (schema 1) with last-run summary + counters (`total_runs`, `ok`, `timeout`, `error`, `consecutive_failures`, `success_rate_24h`).

### `heartbeatctl` — runtime CLI

`agentctl heartbeat <sub>` proxies to the in-container `heartbeatctl`:

```bash
./scripts/agentctl status                          # pretty dashboard, also --json
./scripts/agentctl heartbeat logs                  # tail runs.jsonl
./scripts/agentctl heartbeat show                  # active config
./scripts/agentctl heartbeat test                  # one tick now (--trigger=manual)
./scripts/agentctl heartbeat pause                 # comment crontab + enabled=false
./scripts/agentctl heartbeat resume                # inverse
./scripts/agentctl heartbeat reload                # re-derive crontab + heartbeat.conf from agent.yml
./scripts/agentctl heartbeat kick-channel          # respawn the chat session

./scripts/agentctl heartbeat set-interval 5m
./scripts/agentctl heartbeat set-prompt "Report status as plain text"
./scripts/agentctl heartbeat set-notifier telegram
./scripts/agentctl heartbeat set-timeout 180
./scripts/agentctl heartbeat set-retries 2
./scripts/agentctl heartbeat drop-plugin <spec>    # evict a plugin from agent.yml
```

`agentctl` always passes `-u agent` (raw `docker exec` defaults to root, which `cap_drop: ALL` blocks from writing agent-owned files). Mutations write to `agent.yml` first (with atomic `agent.yml.prev` backup and rollback on failure), then regenerate derived files. Full reference: [`docs/heartbeatctl.md`](docs/heartbeatctl.md).

### Plugin catalog

`agent.yml.plugins[]` lists every plugin the supervisor will install on boot. The launcher ships a declarative descriptor catalog under `modules/plugins/<id>.yml` and the wizard offers two tiers:

- **Default plugins** (5, installed automatically): `claude-md-management`, `claude-mem`, `context7`, `security-guidance`, `telegram` — all from `claude-plugins-official` except `claude-mem` which comes from `thedotmack`.
- **Opt-in plugins** (multi-select at scaffold time): `superpowers` and the other catalog entries documented in `NEXT_STEPS.md`.

The supervisor's `ensure_all_plugins_installed` runs `claude plugin install <spec>` for each, idempotent thanks to a per-plugin `.installed-ok` sentinel (`claude plugin install` can leave half-extracted caches when a network blip kills it mid-install; the sentinel forces a clean re-install in that case).

`heartbeatctl drop-plugin <spec>` is the recommended way to evict a plugin without manual `yq` invocations — it mutates `agent.yml` atomically and tells you to `kick-channel` afterwards.

### Memory persistence

The agent has up to three independent memory layers, all surviving container restarts because they live under the bind-mounted workspace:

- **Auto-memory** (`<workspace>/.state/.claude/projects/-workspace/memory/`) — Claude's first-party file-based memory. The agent writes typed memories (user, feedback, project, reference) and an index file `MEMORY.md` that gets loaded into context on every session start. `claude --continue` resumes the most recent session and the memory dir is the same on either side of a restart.
- **claude-mem** (`<workspace>/.state/.claude-mem/claude-mem.db`) — the `claude-mem@thedotmack` plugin's SQLite-backed observation store with WAL-mode durability. Provides `mem-search`, `smart_search`, `timeline`, and corpus tools that surface earlier sessions' content.
- **Knowledge vault** (`<workspace>/.state/.vault/`, opt-in at scaffold) — a per-agent Obsidian-style wiki following Andrej Karpathy's [LLM Wiki pattern](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f): immutable `raw_sources/`, LLM-owned `wiki/` with the six page types from the gist (summaries, entities, concepts, comparisons, overviews, synthesis), and a `CLAUDE.md` schema. When `vault.mcp.enabled` is true, the `vault` MCP server (package `@bitbonsai/mcpvault`) exposes structured note operations on top of native file access. Full reference: [`docs/vault.md`](docs/vault.md).

All layers stay populated across `docker compose restart`, image rebuilds, and `setup.sh --uninstall` (the no-flag form preserves state). They're cleared only by `setup.sh --uninstall --purge` (which also removes `agent.yml` + `.env`) or `--nuke` (which deletes the whole workspace).

[`docs/state-layout.md`](docs/state-layout.md) maps every persistent file to its concrete host and container path, including OAuth credentials, plugin cache, Telegram channel state, session JSONL logs, and the heartbeat's isolated config dir.

### Headless-friendly settings

`pre_accept_bypass_permissions` runs at every boot and writes `skipDangerousModePermissionPrompt: true` and `permissions.defaultMode: "auto"` to `~/.claude/settings.json`. The chat-driven workflow requires `auto` because plan mode blocks the Telegram `reply` MCP call — without auto, the agent would look like it's ghosting every message.

### Self-contained workspace

All agent state (OAuth login, Telegram pairing, sessions, plugin cache, channels state, heartbeat logs) lives under `<workspace>/.state/` via a bind-mount to `/home/agent` in the container. The workspace directory **is** the agent: portable via `rsync` / `cp -a`, immune to `docker compose down -v`, and removed only when the workspace itself is deleted. `.state/` is gitignored and contains OAuth tokens — never commit it.

### Backup to the agent's own fork (three orphan branches)

The non-regenerable subset of the workspace is replicated to the agent's own GitHub fork as three orphan branches:

- `backup/identity` — OAuth login, Telegram pairing, plugin config, settings, age-encrypted `.env`. Triggered by `heartbeatctl backup-identity`, the watchdog (60s hash check), post-plugin-install hooks, and a daily 03:30 cron.
- `backup/vault` — the vault's markdown subset, hourly by default. Excludes `.obsidian/workspace*.json`, cache, `.trash/`, and `*.sync-conflict-*` so Syncthing-induced churn doesn't pollute snapshots.
- `backup/config` — `agent.yml` (plaintext, no secrets), daily.

Encryption uses your existing GitHub SSH key (no extra secret to manage), fetched from `github.com/<owner>.keys` at scaffold time. Restore on a new machine with `setup.sh --restore-from-fork <url>` — the agent rehydrates without re-`/login`, re-pairing, or re-installing plugins. Each branch is independently optional; partial forks rehydrate whatever's available. Full reference in [`docs/heartbeatctl.md`](docs/heartbeatctl.md#backup-commands).

#### Restore walkthrough (Mac → Linux example)

You lost your laptop, or you're moving the agent to a Raspberry Pi. From the new host:

```bash
# 1. Pre-requisites: gh, git, docker, age (apk on Alpine; brew/apt elsewhere).
#    The same SSH key registered with GitHub must be on the new host
#    (`~/.ssh/id_ed25519`) — that's what decrypts .env.age.

# 2. Clone the launcher.
git clone https://github.com/rodrigo-hinojosa-labs/agentic-pod-launcher.git
cd agentic-pod-launcher

# 3. Restore. Pulls backup/{config,identity,vault} in order, copies files
#    into <dest>, decrypts .env with your SSH key.
./setup.sh \
    --restore-from-fork git@github.com:<your-user>/<agent-fork>.git \
    --destination ~/agentic-agents/<agent-name>

# Expected output:
#   ✓ restore: agent.yml restored from backup/config
#   ✓ restore: decrypted .env with /home/<you>/.ssh/id_ed25519
#   ✓ restore: identity restored into ~/agentic-agents/<agent-name>/.state/
#   ✓ restore: vault restored into ~/agentic-agents/<agent-name>/.state/.vault/

# 4. Build the image (slow on the first run — pulls Alpine, installs uv/bun,
#    pre-installs Python MCPs). Subsequent rebuilds are fast.
cd ~/agentic-agents/<agent-name>
docker compose build

# 5. Boot. The agent comes up authenticated and paired — no /login, no
#    /telegram:access pair, no plugin re-install.
./scripts/agentctl up
./scripts/agentctl doctor   # 12 green checks if everything is right
```

Common gotchas:
- **No SSH key on the new host** → `.env.age` cannot be decrypted. Either copy the key over (`scp ~/.ssh/id_ed25519 newhost:~/.ssh/`) or pass `RESTORE_IDENTITY_KEY=/path/to/private-key` env var to `setup.sh`. As a last resort, regenerate `.env` by re-running the wizard's secrets section: `./setup.sh --regenerate` followed by `./scripts/agentctl shell` to paste the Telegram token manually.
- **Different host UID/GID** → the bind-mount needs the container's `agent` user to match the host UID. The wizard auto-detects via `id -u`/`id -g`, so a fresh `--regenerate` after restore re-bakes the right build args.
- **Partial fork** (only some branches present) → restore continues with a `⚠ no backup/X branch` notice for the missing ones. You can re-run `--restore-from-fork` later when the missing branch is populated.

### UID/GID matched at build

`setup.sh` reads the host user's UID/GID and writes them as build args in `docker-compose.yml`. The container's `agent` user is created with the same numeric ownership at image-build time, so writes through the bind-mount land with the host user's identity. macOS hosts often have GID 20 (`staff`) which collides with Alpine's `dialout` group — the Dockerfile deletes the colliding user/group before `addgroup agent`.

## Architecture summary

```
HOST ~/agents/<name>/                     ← workspace IS the agent
  ├── agent.yml                           ← single source of truth
  ├── docker-compose.yml                  ← rendered, references .state/ as bind-mount
  ├── docker/                             ← Dockerfile + image-baked scripts
  ├── scripts/heartbeat/                  ← workspace-templated heartbeat code
  └── .state/                             ← bind-mounted to /home/agent
       ├── .claude/                       ← OAuth, sessions, plugin cache, channels
       ├── .claude-mem/                   ← claude-mem SQLite + WAL
       ├── .claude-heartbeat/             ← heartbeat's isolated CLAUDE_CONFIG_DIR
       └── .vault/                        ← knowledge vault (opt-in, Karpathy LLM Wiki)

CONTAINER (alpine 3.20, agentic-pod:latest)
  ├── tini (PID 1)
  └── entrypoint.sh
       ├── chown bind-mounts to UID:GID
       ├── render default crontab
       └── exec start_services.sh as agent
            ├── crond (root, dispatches heartbeat with setgid agent)
            ├── tmux session "agent" → claude --continue --channels
            └── watchdog loop (2-second poll, 5/300 crash budget)
```

Three restart layers (containerized → Docker → optional host systemd) compose to keep the agent alive through process crashes, container exits, and host reboots. Capability set is `cap_drop: ALL` plus `CHOWN`, `SETUID`, `SETGID` only — no Docker socket, no inbound ports.

Full architecture (render engine, container lifecycle, heartbeat data contracts, privilege model): [`docs/architecture.md`](docs/architecture.md).

## Regenerate after editing `agent.yml`

```bash
cd ~/agents/my-agent
./setup.sh --regenerate
```

Or mutate live without regenerating:

```bash
docker exec -u agent my-agent heartbeatctl set-prompt "Report status as plain text"
docker exec -u agent my-agent heartbeatctl set-interval 15m
```

Mutations propagate via `agent.yml` → `heartbeat.conf` → staging crontab → `/etc/crontabs/agent` (root sync loop) within ~75 seconds, no container restart needed.

## Testing

The test suite uses `bats-core` and runs entirely on the host (no Docker required for the default suite). Coverage spans the render engine, YAML lib, interval-to-cron converter, state-lib helpers, notifier contracts, the heartbeat runner, the plugin catalog, the Telegram patcher, the heartbeat config-dir isolation, and every `heartbeatctl` subcommand.

```bash
bats tests/                                       # full suite (~220 tests)
bats tests/heartbeatctl.bats                      # single file
bats tests/render.bats -f "substitutes"           # single test by name fragment

DOCKER_E2E=1 bats tests/docker-e2e-heartbeat.bats # opt-in: builds image + boots a container
```

## Uninstall

```bash
cd ~/agents/my-agent
./setup.sh --uninstall --yes                      # stop container, remove generated files; preserves agent.yml + .env + .state/
./setup.sh --uninstall --purge --yes              # also removes agent.yml + .env + .state/
./setup.sh --uninstall --nuke --yes               # also deletes the workspace directory
```

## License

MIT. See [LICENSE](LICENSE).

## Lineage

Forked from `agent-admin-template@feature/docker-mode` (`927fffca700b111b84ae32f70b49b230c781aaf1`). Docker-only template: no `--docker` flag, no host-mode paths, single-user-per-container model.
