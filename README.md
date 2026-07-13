# agentic-pod-launcher

A wizard that scaffolds persistent Claude Code agents — in a least-privilege Docker container or directly on a Linux host under systemd — with durable memory across restarts, an optional knowledge vault with hybrid (RAG) search, plugin auto-management, and backup/restore to the agent's own GitHub fork. Docker mode adds two-way Telegram chat and structured heartbeat observability.

## What this is

`agentic-pod-launcher` is a bash-based template generator. Running `./setup.sh` starts a wizard whose **first prompt selects the deployment mode** (since feature 011):

- **docker** (default, recommended) — the agent runs in an isolated, least-privilege Alpine container. The scaffolded workspace contains a `docker-compose.yml`, a `docker/` directory with the image source, and the scripts the container needs to run a Claude Code agent end-to-end: two-way Telegram chat, a supervised tmux session, and the scheduled heartbeat. Once built, `docker compose up -d` is enough on any machine with Docker.
- **local** (Linux/systemd only) — the agent runs directly on the host as a persistent Claude Code Remote Control session under systemd (`agent-<name>.service`), plus companion units: a healthcheck timer and, when the vault features are enabled, a QMD reindex timer + inotify watcher and vault-backup + wiki-graph timers. No `docker-compose.yml` is scaffolded; the workspace gets `scripts/local/` wrapper scripts and `.state/remote-control.env` instead. There is **no container isolation**: the agent runs as your login user and inherits your privileges — the wizard prints a security warning, and MFA on the claude.ai account is mandatory.

After the mode, the wizard prompts for agent identity and personality, plugins, MCPs, notification channel, heartbeat schedule, and the optional knowledge vault (with QMD hybrid search), then scaffolds a self-contained workspace anywhere on disk.

The launcher clone is disposable after scaffolding. Every subsequent operation (`--regenerate`, `--uninstall`, `--login`, `heartbeatctl ...`) runs from inside the destination workspace.

## Prerequisites

Both modes:

- `git`, `jq`, and `bash` on the host (wizard only; `setup.sh` sets no bash version floor and uses no bash-4-only constructs, so macOS's stock bash is fine). `yq` is auto-vendored — `setup.sh` downloads mikefarah/yq v4+ to `scripts/vendor/bin/` on first run if missing or if the system yq is v3 (Debian/Ubuntu's `apt install yq` ships the Python wrapper v3; the launcher detects that and bootstraps the right one).
- macOS or Linux for scaffolding (the wizard tolerates both BSD and GNU `sed`).

Docker mode:

- Docker 24+ with the Compose v2 plugin (`docker compose`, not `docker-compose`).

Local mode:

- Linux with systemd, and the Claude Code CLI installed on the host (the launcher resolves and pins its absolute path in `agent.yml`). `./setup.sh --login` hard-gates on Claude Code **>= 2.1.51** — the floor for Remote Control as of v0.12.0. No Docker required. The MCP runtimes the rendered `.mcp.json` needs (uv/uvx, node/npx, bun, github-mcp-server) are self-provisioned into `~/.local/bin` by the rendered `scripts/local/agent-bootstrap.sh`, which `--login` runs before enabling the unit.
- `sudo` on the host to install the systemd units. Without a non-interactive `sudo` at scaffold time the units are staged in the workspace and installed later by `./setup.sh --login`.

## Quickstart

### Docker mode

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

`agentctl` is a thin host wrapper for the most common `docker exec -u agent NAME ...` patterns. It resolves the container name from `agent.yml`, applies `-u agent` automatically, and includes a retry-loop in `attach` for the post-`/login` window. Subcommands: `doctor` (full diagnostic), `attach`, `logs [-f]`, `status`, `heartbeat <sub>`, `mcp [list]`, `versions [--check|--upgrade]` (recorded toolchain versions vs upstream), `shell [--root]`, `up`, `stop`, `restart`, `ps`, `run <cmd…>`. Run `./scripts/agentctl --help` for the full list.

When something looks off, the first move is **`./scripts/agentctl doctor`** — it checks Docker daemon, container status, healthcheck, agent.yml, .env, tmux, crond, the Telegram plugin, the heartbeat, the vault, the plugin patches, backup freshness (identity/vault/config), plugin-install failures, and token health in dependency order, and prints an actionable hint per failing subsystem. Exit codes are honest for scripting: 0 clean, 1 warnings, 2 failures.

### Local mode

```bash
git clone git@github.com:rodrigo-hinojosa-labs/agentic-pod-launcher.git
cd agentic-pod-launcher
./setup.sh --destination ~/agents/my-agent   # answer "local" at the first prompt
cd ~/agents/my-agent

# One-time guided login: OAuth + workspace trust + enables the systemd session.
# Interactive OAuth is required (an inference-only `claude setup-token` token
# does NOT work for Remote Control); on a headless host, tunnel the OAuth
# callback port over SSH.
./setup.sh --login

systemctl status agent-my-agent.service      # session state
journalctl -u agent-my-agent.service -f      # logs (look for 'session url' / 'connected')
./scripts/agentctl status                    # reads systemd instead of a container
./scripts/agentctl doctor                    # local checks, same 0/1/2 exit contract
```

In local mode `agentctl` degrades explicitly: docker-only subcommands (`up`, `attach`, `shell`, `logs`, `mcp`, ...) refuse with an explanation, `status`/`doctor` read systemd, and `heartbeat` supports only `qmd-reindex`, `backup-vault`, and `wiki-graph` (executed directly as the operator, no `systemctl`/polkit needed). Permission prompts stay enabled — local mode intentionally does not apply the docker-mode auto-permission settings. The kill switch is `./scripts/local/agent-killswitch.sh` — it stops the session unit (with `Restart=always`, an explicit `systemctl stop` does not relaunch it) plus every auxiliary unit: qmd-reindex timer, qmd-watch, vault-backup timer, healthcheck timer, wiki-graph timer.

The full step-by-step (with troubleshooting) lives in [`docs/getting-started.md`](docs/getting-started.md). Each scaffolded agent also gets a `NEXT_STEPS.md` with concrete commands using the agent's name, paths, and deployment mode.

### Agentic mode (one-prompt setup)

If you'd rather drive the wizard from a Claude Code session than answer 30+ prompts in your shell, open `claude` inside the repo and run `/quickstart`. The slash command reads `tests/helper.bash::wizard_answers()` (the canonical prompt order) and `docs/agentic-quickstart.es.md` (field semantics + safe defaults), asks you for the minimum required values in a single message, and runs `./setup.sh` with the answers piped in. Full details (and a copy-paste alternative for non-Claude environments) in [`docs/agentic-quickstart.es.md`](docs/agentic-quickstart.es.md) — English version at [`docs/agentic-quickstart.en.md`](docs/agentic-quickstart.en.md).

## What's in the box

### Scaffolding from `agent.yml`

The wizard collects answers into `agent.yml` and treats it as the **single source of truth**. Every derived file (`docker-compose.yml` in docker mode, `.mcp.json`, `CLAUDE.md`, `scripts/heartbeat/heartbeat.conf`, `.env` skeleton, `NEXT_STEPS.md`) is rendered from it via `scripts/lib/render.sh`. In local mode the derived set additionally includes `.state/remote-control.env`, the `scripts/local/agent-*.sh` wrappers (login, kill-switch, healthcheck, bootstrap, and — when the corresponding features are on — qmd-reindex, qmd-watch, qmd-mcp, vault-backup, wiki-graph), and the systemd unit(s), which the service installer installs via sudo or stages in the workspace when sudo is unavailable. Re-running `./setup.sh --regenerate` re-emits all derived files. Editing a derived file by hand without touching `agent.yml` will be silently overwritten on the next regenerate.

### Self-healing supervisor (docker mode)

Inside the container, `tini` is PID 1; `entrypoint.sh` runs as root for crontab installation, then drops to the `agent` user via `su-exec`. `start_services.sh` runs as `agent` on a 2-second poll and supervises three independent things:

- The tmux session that hosts the interactive Claude session.
- `crond` (busybox), which dispatches the scheduled heartbeat.
- The Telegram channel plugin's `bun server.ts` MCP server.

Crashes of any of these get respawned automatically. A sliding 300-second crash budget exits the container after 5 crashes so Docker's `unless-stopped` policy can take over the recovery layer.

Local mode has no supervisor process: systemd's `Restart=always` on `agent-<name>.service` plus the companion timers play the equivalent role.

### Two-way Telegram chat (docker mode)

The agent ships with the `claude-plugins-official/telegram` channel plugin enabled by default. Boot-time post-install hooks layer four behaviors on top of the upstream plugin:

- **Persistent "typing…" indicator** — the upstream plugin fires `sendChatAction` once per inbound and Telegram auto-expires the action at ~5 seconds. The post-install hook adds a 4-second refresh interval so the user sees "typing…" continuously while Claude is processing, including during long tool calls. As of patch v4 the refresh has a hard cap (default 5 minutes, tunable via the `TELEGRAM_TYPING_MAX_MS` env var): on expiry it stops, sends a user-visible timeout warning to the chat (the usual cause is an expired OAuth login), and logs the abort to stderr — instead of showing "typing…" forever while the agent is dead.
- **Durable update offset on reply** — the Telegram `update_id` cursor is persisted to `~/.claude/channels/telegram/last-offset.json` only after a `reply` MCP tool call returns successfully. If the plugin process dies between "Claude received the inbound" and "Claude actually replied," the offset stays put and Telegram re-delivers the update on the next plugin start. End-to-end at-least-once semantics, not just at-least-once-on-inbound.
- **Single-primary lock** — the plugin's PID file is refreshed every 5 seconds while the primary instance polls. Any second instance (spawned, for example, by a sub-Claude that happens to load the plugin) reads the PID file, sees a fresh `mtime`, and exits cleanly instead of taking over the bot token. The primary keeps polling without interruption.
- **Forensic stderr** — the plugin's stderr (including unhandled exceptions and rejections) is teed to `<workspace>/scripts/heartbeat/logs/telegram-mcp-stderr.log`. The MCP transport otherwise consumes stderr; this gives crashes a place to leave evidence.

All four hooks are idempotent (each guarded by a marker comment) and fail-silent if any anchor in the upstream plugin source drifts — the plugin keeps its default behavior in that case.

For the silent-stuck case where the bun process is alive but its MCP notifications stop reaching Claude (an upstream-bridge bug), `heartbeatctl kick-channel` forces a clean respawn of the channel session.

### Heartbeat with structured observability (docker mode)

`crond` inside the container fires `scripts/heartbeat/heartbeat.sh` on a schedule chosen at scaffold (default: every 30 minutes). Local mode does not run the heartbeat — its scheduled work is the systemd timers (healthcheck, qmd reindex, vault backup, wiki-graph). Each tick:

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

./scripts/agentctl heartbeat backup-identity       # push an identity snapshot to backup/identity
./scripts/agentctl heartbeat backup-vault          # push a vault snapshot (supports --dry-run)
./scripts/agentctl heartbeat backup-config         # push an agent.yml snapshot
./scripts/agentctl heartbeat qmd-reindex           # force a vault reindex (lexical + embeddings)
./scripts/agentctl heartbeat wiki-graph            # regenerate the derived wiki graph + lint
./scripts/agentctl heartbeat token-check           # probe OAuth/API token health

./scripts/agentctl heartbeat set-interval 5m
./scripts/agentctl heartbeat set-prompt "Report status as plain text"
./scripts/agentctl heartbeat set-notifier telegram
./scripts/agentctl heartbeat set-timeout 180
./scripts/agentctl heartbeat set-retries 2
./scripts/agentctl heartbeat drop-plugin <spec>    # evict a plugin from agent.yml
```

`agentctl` always passes `-u agent` (raw `docker exec` defaults to root, which `cap_drop: ALL` blocks from writing agent-owned files). Mutations write to `agent.yml` first (with atomic `agent.yml.prev` backup and rollback on failure), then regenerate derived files. In local mode only `qmd-reindex`, `backup-vault`, and `wiki-graph` have local equivalents — the rest of the `heartbeat` subcommands are docker-only. Full reference: [`docs/heartbeatctl.md`](docs/heartbeatctl.md).

### Plugin catalog

`agent.yml.plugins[]` lists every plugin the supervisor will install on boot. The launcher ships a declarative descriptor catalog under `modules/plugins/<id>.yml` and the wizard offers two tiers:

- **Default plugins** (5, installed automatically): `claude-md-management`, `claude-mem`, `context7`, `security-guidance`, `telegram` — all from `claude-plugins-official` except `claude-mem` which comes from `thedotmack`.
- **Opt-in plugins** (asked one by one at scaffold time; as of v0.12.0): `code-simplifier`, `commit-commands`, `github`, `skill-creator`, `superpowers` — documented in `NEXT_STEPS.md`.

The supervisor's `ensure_all_plugins_installed` runs `claude plugin install <spec>` for each, idempotent thanks to a per-plugin `.installed-ok` sentinel (`claude plugin install` can leave half-extracted caches when a network blip kills it mid-install; the sentinel forces a clean re-install in that case).

`heartbeatctl drop-plugin <spec>` is the recommended way to evict a plugin without manual `yq` invocations — it mutates `agent.yml` atomically and tells you to `kick-channel` afterwards.

### Memory persistence

The agent has up to three independent memory layers. All three survive restarts; auto-memory and the vault live under the workspace in both modes, while the claude-mem store's location depends on the deployment mode:

- **Auto-memory** (`<workspace>/.state/.claude/projects/<project-dir>/memory/`) — Claude's first-party file-based memory. The `<project-dir>` name is the sanitized session cwd: `-workspace` in docker mode (container cwd `/workspace`); in local mode it derives from the host workspace path instead. The agent writes typed memories (user, feedback, project, reference) and an index file `MEMORY.md` that gets loaded into context on every session start. `claude --continue` resumes the most recent session and the memory dir is the same on either side of a restart. Under the workspace in both modes (local mode pins `CLAUDE_CONFIG_DIR` to `<workspace>/.state/.claude`).
- **claude-mem** — the `claude-mem@thedotmack` plugin's SQLite-backed observation store with WAL-mode durability. Provides `mem-search`, `smart_search`, `timeline`, and corpus tools that surface earlier sessions' content. Its path is `$HOME`-relative, so it lands in a different place per mode: **docker mode** `<workspace>/.state/.claude-mem/claude-mem.db` (the container's `$HOME` *is* `.state/`); **local mode** `$HOME/.claude-mem/claude-mem.db` in the **operator's own home**, outside the workspace — the session unit repoints `CLAUDE_CONFIG_DIR` but deliberately keeps `HOME` as the operator's (`modules/remote-control.env.tpl`).
- **Knowledge vault** (`<workspace>/.state/.vault/`, opt-in at scaffold) — a per-agent Obsidian-style wiki following Andrej Karpathy's [LLM Wiki pattern](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f): immutable `raw_sources/`, LLM-owned `wiki/` with the six page types from the gist (summaries, entities, concepts, comparisons, overviews, synthesis), and a `CLAUDE.md` schema. When `vault.mcp.enabled` is true, the `vault` MCP server (package `@bitbonsai/mcpvault`) exposes structured note operations on top of native file access. Full reference: [`docs/vault.md`](docs/vault.md).

All layers stay populated across `docker compose restart`, image rebuilds, and `setup.sh --uninstall` (the no-flag form preserves state). What clears them is `setup.sh --uninstall --purge` (which removes `.state/` plus `agent.yml` + `.env`; in local mode it also wipes the vault-backup clone cache under `~/.cache/agent-backup/`) or `--nuke` (which deletes the whole workspace). Caveat in **local mode**: neither flag touches the claude-mem DB in the operator's `$HOME`, so it survives `--purge` *and* `--nuke` — remove `~/.claude-mem/` by hand if you want it gone.

[`docs/state-layout.md`](docs/state-layout.md) maps every persistent file to its concrete host and container path, including OAuth credentials, plugin cache, Telegram channel state, session JSONL logs, and the heartbeat's isolated config dir.

### Vault RAG — QMD hybrid search + wiki-graph (opt-in)

Two derived layers sit on top of the vault, in both deployment modes (as of v0.12.0):

- **QMD hybrid search** — [`@tobilu/qmd`](https://github.com/tobi/qmd) (version pinned in `agent.yml` under `vault.qmd.version`) provides BM25 lexical search + vector embeddings + rerank over the vault's markdown. Enabling it adds a `qmd` server entry to `.mcp.json`, launched through a per-mode wrapper: the image-baked `/opt/agent-admin/scripts/qmd-mcp` in docker mode, the rendered `scripts/local/agent-qmd-mcp.sh` in local mode. Freshness is double-covered: an inotify watcher reindexes on vault changes, backstopped by a scheduled `qmd-reindex` (default every 5 minutes; a cron line in docker mode, a systemd timer + watcher unit in local mode). Each reindex is flock-guarded and runs the lexical update plus embedding passes in a loop until every chunk is embedded (or a fixed pass cap is hit). The index and the ~300 MB embedding model persist under `.state/.cache/qmd/`, so restarts don't re-download or re-embed.
- **Wiki-graph** — a derived, read-only graph over the vault wiki: `<vault>/.graph/{graph,backlinks,findings}.json` (links, backlinks, structural lint findings). Regenerated on a schedule (default `20 */6 * * *`) and on demand via `./scripts/agentctl heartbeat wiki-graph`. It never edits the wiki pages, and `.graph/` is excluded from both the vault backup and the qmd index.

Full reference: [`docs/vault.md`](docs/vault.md) (vault layers, QMD setup, storage and cost, wiki-graph) and [`docs/qmd-upgrade-checklist.md`](docs/qmd-upgrade-checklist.md) (bumping the pinned qmd version).

### Headless-friendly settings (docker mode)

`pre_accept_bypass_permissions` runs at every boot and writes `skipDangerousModePermissionPrompt: true` and `permissions.defaultMode: "auto"` to `~/.claude/settings.json`. The chat-driven workflow requires `auto` because plan mode blocks the Telegram `reply` MCP call — without auto, the agent would look like it's ghosting every message. Local mode deliberately does the opposite: permission prompts stay enabled (the systemd unit never passes the dangerous-skip flag).

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
# 1. Pre-requisites: gh, git, age (apk on Alpine; brew/apt elsewhere), plus
#    docker if the restored agent is a docker-mode agent.
#    The same SSH key registered with GitHub must be on the new host
#    (`~/.ssh/id_ed25519`) — that's what decrypts .env.age.

# 2. Clone the launcher.
git clone https://github.com/rodrigo-hinojosa-labs/agentic-pod-launcher.git
cd agentic-pod-launcher

# 3. Restore. Pulls backup/{config,identity,vault} in order, copies files
#    into <dest>, decrypts .env with your SSH key. The deployment mode comes
#    back with agent.yml (backup/config), so the rest of the run re-renders
#    the right derived set for that mode.
./setup.sh \
    --restore-from-fork git@github.com:<your-user>/<agent-fork>.git \
    --destination ~/agentic-agents/<agent-name>

# Expected output:
#   ✓ restore: agent.yml restored from backup/config
#   ✓ restore: decrypted .env with /home/<you>/.ssh/id_ed25519
#   ✓ restore: identity restored into ~/agentic-agents/<agent-name>/.state/
#   ✓ restore: vault restored into ~/agentic-agents/<agent-name>/.state/.vault/

# 4. Docker mode — build the image (slow on the first run: pulls Alpine,
#    installs uv/bun, pre-installs Python MCPs). Subsequent rebuilds are fast.
cd ~/agentic-agents/<agent-name>
docker compose build

# 5. Docker mode — boot. The agent comes up authenticated and paired: no
#    /login, no /telegram:access pair, no plugin re-install.
./scripts/agentctl up
./scripts/agentctl doctor   # all checks green if everything is right
```

Local mode: skip steps 4-5 — there is no image. The same `setup.sh` run renders `scripts/local/` and installs the systemd units (or stages them if it can't sudo). Verify with `./scripts/agentctl doctor`; if the session unit isn't active, re-run the guided `./setup.sh --login`.

Common gotchas:

- **No SSH key on the new host** → `.env.age` cannot be decrypted. Either copy the key over (`scp ~/.ssh/id_ed25519 newhost:~/.ssh/`) or point the launcher at the key with the `--identity-key` flag: `./setup.sh --restore-from-fork <url> --destination <dest> --identity-key /path/to/private-key`. (There is no `RESTORE_IDENTITY_KEY` env var — the variable is reset before argument parsing, so only the flag has any effect.) As a last resort, regenerate `.env` by re-running the wizard's secrets section: `./setup.sh --regenerate`, then paste the Telegram token by hand.
- **Different host UID/GID** (docker mode) → the bind-mount needs the container's `agent` user to match the host UID. The wizard auto-detects via `id -u`/`id -g`, so a fresh `--regenerate` after restore re-bakes the right build args.
- **Partial fork** (only some branches present) → restore continues with a `⚠ restore: no backup/X branch` notice for the missing ones. You can re-run `--restore-from-fork` later when the missing branch is populated.

### UID/GID matched at build

`setup.sh` reads the host user's UID/GID and writes them as build args in `docker-compose.yml`. The container's `agent` user is created with the same numeric ownership at image-build time, so writes through the bind-mount land with the host user's identity. macOS hosts often have GID 20 (`staff`) which collides with Alpine's `dialout` group — the Dockerfile deletes the colliding user/group before `addgroup agent`.

## Architecture summary

Docker mode (as of v0.12.0 the image base is `alpine:3.24.1`, build arg `BASE_IMAGE`):

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
       ├── .cache/qmd/                    ← qmd index + embedding model (opt-in RAG)
       └── .vault/                        ← knowledge vault (opt-in, Karpathy LLM Wiki)

CONTAINER (alpine 3.24, agentic-pod:latest)
  ├── tini (PID 1)
  └── entrypoint.sh
       ├── chown bind-mounts to UID:GID
       ├── render default crontab
       └── exec start_services.sh as agent
            ├── crond (root, dispatches heartbeat + qmd/backup/wiki-graph jobs)
            ├── tmux session "agent" → claude --continue --channels
            └── watchdog loop (2-second poll, 5/300 crash budget)
```

Three restart layers (containerized → Docker → optional host systemd) compose to keep the agent alive through process crashes, container exits, and host reboots. Capability set is `cap_drop: ALL` plus `CHOWN`, `SETUID`, `SETGID` only — no Docker socket, no inbound ports.

Local mode keeps the same workspace shape (`agent.yml` + `.state/`, with auto-memory, the vault and the qmd index all pinned under `.state/`) but replaces the container column: no `docker-compose.yml` and no `docker/`; instead `scripts/local/agent-*.sh` wrappers plus `.state/remote-control.env`, driven by systemd — `agent-<name>.service` (`Restart=always`) for the session and one timer per scheduled job (healthcheck, qmd reindex + inotify watcher, vault backup, wiki-graph). There is no container boundary: the agent runs as the login user, and `$HOME` stays the operator's — so `$HOME`-relative state that nothing repoints (claude-mem, `~/.bun`, the vault-backup clone cache) lands outside the workspace.

Full architecture (mode comparison, render engine, container lifecycle, systemd units, heartbeat data contracts, privilege model): [`docs/architecture.md`](docs/architecture.md).

## Regenerate after editing `agent.yml`

```bash
cd ~/agents/my-agent
./setup.sh --regenerate
```

`--regenerate` re-emits the derived set for the mode recorded in `agent.yml` — in local mode that includes the `scripts/local/` wrappers, `.state/remote-control.env`, and the systemd units.

Docker mode can also mutate live, without regenerating:

```bash
docker exec -u agent my-agent heartbeatctl set-prompt "Report status as plain text"
docker exec -u agent my-agent heartbeatctl set-interval 15m
```

Mutations propagate via `agent.yml` → `heartbeat.conf` → staging crontab → `/etc/crontabs/agent` (root sync loop) within ~75 seconds, no container restart needed.

## Testing

The test suite uses `bats-core` and runs entirely on the host (no Docker required for the default suite; `yq` v4+, `jq`, `git` and `tmux` are the other host deps). Coverage spans the render engine, YAML lib, interval-to-cron converter, state-lib helpers, notifier contracts, the heartbeat runner, the plugin and MCP catalogs, the Telegram patcher, the heartbeat config-dir isolation, every `heartbeatctl` subcommand, the deployment-mode branch (local render, bootstrap, systemd schedule conversion, kill switch, healthcheck), the QMD/RAG stack (index lib, embed-completion loop, sqlite-vec, wiki-graph), the three backup primitives, and token health.

```bash
bats tests/                                       # full suite (977 tests as of v0.12.0)
bats tests/heartbeatctl.bats                      # single file
bats tests/render.bats -f "substitutes"           # single test by name fragment

DOCKER_E2E=1 bats tests/docker-e2e-heartbeat.bats # opt-in: builds image + boots a container
DOCKER_E2E=1 bats tests/docker-e2e-qmd.bats       # opt-in: real qmd index + embed inside the image
```

## Uninstall

```bash
cd ~/agents/my-agent
./setup.sh --uninstall --yes                      # stop the agent, remove generated files; preserves agent.yml + .env + .state/
./setup.sh --uninstall --purge --yes              # also removes agent.yml + .env + .state/
./setup.sh --uninstall --nuke --yes               # also deletes the workspace directory
```

`--uninstall` tears down whatever it finds, so it covers both modes. It runs `docker compose down` when `docker` is on `PATH` (state in `.state/` survives — with the bind-mount there is no volume to wipe), removes `docker-compose.yml` and the generated files (`CLAUDE.md`, `.mcp.json`, `.env.example`, `scripts/heartbeat/heartbeat.conf`, `scripts/heartbeat/logs/`), and — this is the local-mode half — disables and deletes every `agent-<name>` systemd unit that exists: the session service plus the healthcheck, qmd-reindex, qmd-watch, vault-backup and wiki-graph services/timers. Unit removal needs non-interactive `sudo`; without it, the uninstaller prints the units for you to remove by hand.

## License

MIT. See [LICENSE](LICENSE).

## Lineage

Forked from `agent-admin-template@feature/docker-mode` (`927fffca700b111b84ae32f70b49b230c781aaf1`). Docker-only template: no `--docker` flag, no host-mode paths, single-user-per-container model.
