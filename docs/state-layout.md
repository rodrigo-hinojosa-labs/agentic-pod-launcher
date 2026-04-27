# State layout — where everything persists

This doc maps every piece of agent state to a concrete path on the host AND inside the container, and explains which artifacts persist across `docker compose restart`, image rebuilds, and the various flavors of `setup.sh --uninstall`.

If you only want a TL;DR: the workspace directory IS the agent. Everything that needs to survive container lifecycle events lives under `<workspace>/`. Two bind-mounts wire it into the container; nothing important lives in a Docker-managed volume.

## The two bind-mounts

`docker-compose.yml` declares exactly two volume mounts:

```yaml
volumes:
  - ./:/workspace          # the entire workspace dir → /workspace in the container
  - ./.state:/home/agent   # state subtree           → /home/agent (the agent user's $HOME)
```

Anything under `<workspace>/.state/` on the host is the same bytes as `/home/agent/` in the container — edits on one side are visible on the other. The rest of the workspace (`agent.yml`, `docker-compose.yml`, `scripts/`, etc.) lives at `/workspace/` inside the container.

`.state/` is gitignored. It contains OAuth credentials and Telegram tokens — never commit it.

## Memory — three independent layers

### Layer A — first-party auto-memory (Markdown files)

| Host | Container |
|---|---|
| `<workspace>/.state/.claude/projects/-workspace/memory/` | `/home/agent/.claude/projects/-workspace/memory/` |

Layout:

```
memory/
├── MEMORY.md                ← index file, ALWAYS loaded into context at session start
├── user_<topic>.md          ← typed memory: who the user is, role, preferences
├── feedback_<topic>.md      ← typed memory: how the user wants you to work
├── project_<topic>.md       ← typed memory: project-specific facts, deadlines, decisions
└── reference_<topic>.md     ← typed memory: pointers to external systems / docs
```

Every file has YAML frontmatter (`name`, `description`, `type`) plus a body. Claude writes them via the `Write` tool when it learns something worth keeping; the directory is created lazily on the first save.

`MEMORY.md` is the index — keep it under 200 lines (lines after 200 are truncated when loaded into context). One-line entries with a link to the full file:

```markdown
- [Title](file.md) — one-line hook
```

### Layer B — `claude-mem` plugin (SQLite + WAL)

| Host | Container |
|---|---|
| `<workspace>/.state/.claude-mem/` | `/home/agent/.claude-mem/` |

Layout:

```
.claude-mem/
├── claude-mem.db            ← main SQLite store: observations, user_prompts, embeddings
├── claude-mem.db-wal        ← write-ahead log (durability across crashes)
├── claude-mem.db-shm        ← SQLite shared memory (transient)
├── backups/                 ← periodic .db snapshots
├── corpora/                 ← per-project semantic indices
├── logs/                    ← plugin internal logs
├── observer-sessions/       ← transient sessions of the observer worker
├── settings.json            ← plugin config (hook toggles, retention, etc.)
├── supervisor.json          ← state of the supervisor that keeps the worker alive
├── transcript-watch.json    ← state of the transcript watcher
└── worker.pid               ← PID of the daemon that processes transcripts
```

Tools that consult this layer: `mem-search`, `smart_search`, `smart_outline`, `smart_unfold`, `query_corpus`, `timeline`, `get_observations`. The worker daemon (`bun .../worker-service.cjs --daemon`) processes Claude transcripts in the background and appends observations to the `.db`.

### Layer C — knowledge vault (Karpathy LLM Wiki, opt-in)

| Host | Container |
|---|---|
| `<workspace>/.state/.vault/` | `/home/agent/.vault/` (real path); `/home/agent/vault/` → symlink |

Per-agent file-based wiki following Karpathy's three-layer pattern (raw sources / wiki / schema). Opt-in via the wizard's "▸ Knowledge vault" prompts; controlled by `agent.yml.vault.enabled`. Coexists with auto-memoria (Layer A) and claude-mem (Layer B): used for **curated, synthetic, compounding knowledge derived from external sources**, not atomic facts (auto-memoria) or passive transcript observations (claude-mem).

Layout (when seeded):

```
.vault/
├── raw_sources/             ← Layer 1 — immutable source documents (LLM reads, never edits)
│   └── README.md
├── wiki/                    ← Layer 2 — LLM-owned. Six type subdirs verbatim from Karpathy:
│   ├── summaries/           ← one per ingested raw source
│   ├── entities/            ← concrete things (people, products, tools, projects, places)
│   ├── concepts/            ← abstract ideas (frameworks, principles, definitions)
│   ├── comparisons/         ← X vs Y
│   ├── overviews/           ← high-level synthesis of a domain
│   └── synthesis/           ← cross-cutting integration; meta-pages
├── _templates/              ← operational boilerplate the LLM reads when creating pages
├── index.md                 ← catalog by type (LLM updates on every ingest/query)
├── log.md                   ← chronological append-only — `## [YYYY-MM-DD] {op} | <title>`
├── CLAUDE.md                ← Layer 3 schema — frontmatter spec, ingest/query/lint protocols
└── .obsidian/               ← optional Obsidian config (user-owned, empty at scaffold)
```

Frontmatter on Layer 2 pages is unified:

```yaml
---
title: ""
type: summary | entity | concept | comparison | overview | synthesis
sources: []          # paths under raw_sources/
related: []          # wikilinks like [[concepts/foo]]
created: YYYY-MM-DD
updated: YYYY-MM-DD
status: draft | active | stale | superseded
tags: []
---
```

Wikilinks use `[[<type>/<title>]]` form (slugified title). The LLM maintains them; backlinks are not auto-generated.

When `agent.yml.vault.mcp.enabled` is true, `.mcp.json` exposes the vault as the `vault` MCP server (package `@bitbonsai/mcpvault` — zero dependencies, no Obsidian app required). Tools: `read_note`, `write_note`, `patch_note`, `delete_note`, `move_note`, `move_file`, `list_directory`, `read_multiple_notes`, `search_notes`, `get_frontmatter`, `update_frontmatter`, `get_notes_info`, `get_vault_stats`, `manage_tags`.

The seed comes from `modules/vault-skeleton/` in this repo, COPYd into the image at `/opt/agent-admin/modules/vault-skeleton/` and rsynced into `/home/agent/.vault/` on first container boot if `vault.seed_skeleton` is true and the vault dir is empty (idempotent — no-op once populated). The convenience symlink `/home/agent/vault → /home/agent/.vault` is created on every boot.

Full feature documentation: [`docs/vault.md`](vault.md).

## Conversation history — JSONL session logs

| Host | Container |
|---|---|
| `<workspace>/.state/.claude/projects/-workspace/*.jsonl` | `/home/agent/.claude/projects/-workspace/*.jsonl` |

Each session is one JSONL file (`<uuid>.jsonl`). One line per turn (user message, assistant message, tool call, tool result). `claude --continue` resumes the most-recent file — this is what makes a tmux respawn pick up where the prior session left off.

Filenames don't carry semantic meaning (random UUIDs); the supervisor / `--continue` finds the latest by mtime.

## Plugins — installed cache and patched code

| Host | Container |
|---|---|
| `<workspace>/.state/.claude/plugins/cache/<marketplace>/<name>/<version>/` | `/home/agent/.claude/plugins/cache/...` |
| `<workspace>/.state/.claude/plugins/marketplaces/<marketplace>/` | `/home/agent/.claude/plugins/marketplaces/...` |

The launcher's default catalog (5 plugins) populates two marketplaces:

```
plugins/cache/
├── claude-plugins-official/
│   ├── claude-md-management/
│   ├── context7/
│   ├── security-guidance/
│   ├── superpowers/                        # only if opt-in selected at scaffold
│   └── telegram/0.0.6/
│       └── server.ts                       # ← post-install patches edit this file
└── thedotmack/
    └── claude-mem/12.4.7/
        └── scripts/
            ├── mcp-server.cjs
            └── worker-service.cjs
```

The Telegram plugin's `server.ts` is the file that the boot-time post-install hooks edit (typing refresh, offset persistence, stderr capture, primary lock). Each hook is guarded by a marker comment and is idempotent — re-applying is a no-op once the marker is present. `grep -c "agentic-pod-launcher:" server.ts` should return `8` (1 typing + 4 offset hunks + 1 stderr + 2 primary).

Each plugin's cache directory has a `.installed-ok` sentinel after a successful `claude plugin install`. The supervisor checks for the sentinel before re-running install on boot — half-extracted caches (network blip during install) are detected as missing the sentinel and force a clean re-install.

## Telegram channel state

| Host | Container |
|---|---|
| `<workspace>/.state/.claude/channels/telegram/` | `/home/agent/.claude/channels/telegram/` |

Layout:

```
channels/telegram/
├── .env                     ← TELEGRAM_BOT_TOKEN (0600); synced from /workspace/.env on boot
├── access.json              ← {dmPolicy, allowFrom: [chat_ids], groups, pending}
├── approved/<chat_id>       ← drop-file per approved sender
├── bot.pid                  ← primary bun PID; mtime refreshed every 5s by the running primary
├── last-offset.json         ← {offset, ts} — Telegram getUpdates cursor, persisted ack-on-reply
└── inbox/                   ← attachments downloaded by the bot (photos, documents, etc.)
```

The pairing flow writes to `access.json` (and drops a sentinel into `approved/`). The primary-lock heartbeat refreshes `bot.pid`'s mtime every 5s; secondary instances (sub-claudes) detect a fresh mtime and `process.exit(0)` instead of taking over the bot token. The offset advances only after a `reply` MCP tool call returns successfully, so a crashed turn results in Telegram redelivery rather than silent loss.

## OAuth, config, settings

| Host | Container | What |
|---|---|---|
| `<workspace>/.state/.claude/.credentials.json` | `/home/agent/.claude/.credentials.json` | OAuth token (0600) |
| `<workspace>/.state/.claude/.claude.json` | `/home/agent/.claude/.claude.json` | Global Claude config (known projects, prefs) |
| `<workspace>/.state/.claude/settings.json` | `/home/agent/.claude/settings.json` | `enabledPlugins`, `permissions.defaultMode`, `extraKnownMarketplaces`, theme, effort level |
| `<workspace>/.state/.claude/sessions/` | `/home/agent/.claude/sessions/` | Auth state / locks |
| `<workspace>/.state/.claude/history.jsonl` | `/home/agent/.claude/history.jsonl` | Slash-command and prompt history |

The supervisor's `pre_accept_bypass_permissions` writes `skipDangerousModePermissionPrompt: true` and `permissions.defaultMode: "auto"` to `settings.json` on every boot. Don't edit those keys by hand and expect them to stick — they get rewritten.

## Heartbeat — isolated config dir + artifacts

### Isolated `CLAUDE_CONFIG_DIR` for the heartbeat session

Created lazily by `ensure_heartbeat_config_dir()` on the first cron tick. May not exist yet if no fire has happened since the most recent boot.

| Host | Container |
|---|---|
| `<workspace>/.state/.claude-heartbeat/` | `/home/agent/.claude-heartbeat/` |

Layout:

```
.claude-heartbeat/
├── settings.json            ← REAL file (NOT a symlink) with enabledPlugins:{} and extraKnownMarketplaces:{}
├── .credentials.json        → symlink to ../.claude/.credentials.json (shared OAuth)
├── .claude.json             → symlink to ../.claude/.claude.json (shared global config)
├── plugins/                 ← empty directory (NOT a symlink to the shared cache)
├── channels/                ← empty (heartbeat doesn't poll Telegram)
├── sessions/                ← isolated runtime
└── cache/                   ← isolated runtime
```

The empty `plugins/` plus `enabledPlugins:{}` together prevent `claude --print` from spawning any MCP plugin server (notably the Telegram plugin's bun process). Without this, every cron tick would spawn a second bun that takes over the bot token from the primary.

### Heartbeat artifacts (not under `.state/`)

The heartbeat's logs and last-run state live in the workspace alongside the heartbeat code itself, not under `.state/`:

| Host | Container |
|---|---|
| `<workspace>/scripts/heartbeat/heartbeat.sh` | `/workspace/scripts/heartbeat/heartbeat.sh` |
| `<workspace>/scripts/heartbeat/heartbeat.conf` | `/workspace/scripts/heartbeat/heartbeat.conf` |
| `<workspace>/scripts/heartbeat/state.json` | `/workspace/scripts/heartbeat/state.json` |
| `<workspace>/scripts/heartbeat/logs/runs.jsonl` | `/workspace/scripts/heartbeat/logs/runs.jsonl` |
| `<workspace>/scripts/heartbeat/logs/sessions/<run_id>.log` | idem |
| `<workspace>/scripts/heartbeat/logs/cron.log` | idem |
| `<workspace>/scripts/heartbeat/logs/telegram-mcp-stderr.log` | idem |

`runs.jsonl` is rotated at 10 MB → `.1`, `.2.gz`, `.3.gz` (max 3 generations). Per-run session logs in `logs/sessions/` are pruned to the last 20 by the heartbeat itself.

`state.json` is rewritten atomically (temp + rename) at the end of every tick. Schema 1 — see [`docs/architecture.md`](architecture.md) for the field contract.

## Workspace-level files (outside `.state/`)

| Host path | What | Persists across restart? | Gitignored? |
|---|---|---|---|
| `<workspace>/agent.yml` | Single source of truth — wizard + `heartbeatctl set-*` write here | yes | no (commit it) |
| `<workspace>/.env` | Secrets (TELEGRAM_BOT_TOKEN, MCP tokens), 0600 | yes | yes |
| `<workspace>/.env.example` | Template with placeholders for `.env` | yes | no |
| `<workspace>/CLAUDE.md` | Agent base memory; regenerated by the wizard at first boot | yes | no |
| `<workspace>/CONTAINER.md` | Live runtime info; rewritten on every container boot | yes (but volatile) | yes |
| `<workspace>/claude.log` | tmux pipe-pane capture of the agent session | yes (grows monotonically) | yes |
| `<workspace>/claude.cron.log` | crond stderr | yes | yes |
| `<workspace>/.mcp.json` | MCP server config (rendered from `agent.yml`) | yes | no |
| `<workspace>/docker-compose.yml` | Compose config (rendered from `agent.yml`) | yes | no |
| `<workspace>/docker/` | Dockerfile + image-baked scripts | yes | no |
| `<workspace>/scripts/heartbeat/` | Workspace-templated heartbeat code | yes | no |

## Other state under `.state/` (cache + runtime)

These are caches the `agent` user accumulates inside the container. They persist across restarts because of the bind-mount but you can wipe them safely if needed (the next boot rebuilds whatever it needs):

| Host | What |
|---|---|
| `<workspace>/.state/.bun/` | bun's package install cache |
| `<workspace>/.state/.npm/` | npm's package install cache (used by `npx` for some MCPs) |
| `<workspace>/.state/.cache/` | generic XDG cache dir |
| `<workspace>/.state/.local/` | XDG state dir for various tools |
| `<workspace>/.state/.config/` | XDG config dir (uv, etc.) |

Note also `<workspace>/.state/.claude.json` (at the top level of `.state/`, not inside `.claude/`) — Claude Code writes a stripped copy here as well. Both copies are kept in sync by the CLI.

## What does NOT persist

- `/tmp/` inside the container (tmpfs, capped at 100 MB) — includes the watchdog markers in `/tmp/agent-watchdog/` and any temp files from runtime tools. Wiped on container restart.
- `/opt/agent-admin/` inside the container — image-baked, read-only, regenerated on every `docker compose build`. Includes `entrypoint.sh`, `start_services.sh`, `wizard-container.sh`, `heartbeatctl`, `apply_telegram_typing_patch.py`, the lib/ helpers, and the safe-default crontab template.
- `/etc/crontabs/agent` inside the container — root-owned, regenerated by `entrypoint.sh` and kept in sync with `<workspace>/scripts/heartbeat/.crontab.staging` via a root background loop. Edits are clobbered.
- The Docker image itself (`agentic-pod:latest`) — discarded on `docker compose build`.

## Disk usage at steady state

Rough sizes for a fresh agent with the default plugin catalog:

| Path | Size | Notes |
|---|---|---|
| `<workspace>/.state/.claude/` | ~700 MB | Plugins cache (`plugins/cache/`) is the bulk — node_modules per plugin |
| `<workspace>/.state/.claude-mem/` | ~5 MB | Grows with usage; observation rows + WAL |
| `<workspace>/.state/.bun/` + `.npm/` + `.local/` | ~200 MB | Package caches |
| `<workspace>/claude.log` | grows | tmux pipe-pane capture; truncate / rotate manually if needed |
| `<workspace>/.state/.claude/projects/-workspace/` | grows | One JSONL per session; sessions accumulate |

## Lifecycle commands and what they touch

| Command | Effect on state |
|---|---|
| `docker compose restart` | Restarts processes; preserves all of `.state/` and the workspace |
| `docker compose down` | Stops + removes container; preserves `.state/` and workspace (no `-v` because there are no Docker-managed volumes) |
| `docker compose down -v` | Same as `down` (no Docker volumes to remove) |
| `docker compose build` | Rebuilds image; doesn't touch `.state/` |
| `setup.sh --regenerate` | Re-renders derived files from `agent.yml`; doesn't touch `.state/` |
| `setup.sh --uninstall --yes` | Stops container, removes rendered files; preserves `agent.yml`, `.env`, `.state/` |
| `setup.sh --uninstall --purge --yes` | Plus removes `agent.yml`, `.env`, `.state/` |
| `setup.sh --uninstall --nuke --yes` | Plus deletes the entire workspace directory |
| `rsync -a <workspace>/ <other-host>:<dest>/` | Full agent migration — including OAuth, memory, sessions, and plugin cache |

## Migrating an agent

Because the workspace is self-contained, copying it is a full migration:

```bash
# Stop the container so nothing is mid-write.
cd ~/agents/my-agent && docker compose down

# Copy to the new host (or a backup target).
rsync -a ~/agents/my-agent/ user@new-host:~/agents/my-agent/

# Start on the destination.
ssh user@new-host
cd ~/agents/my-agent
docker compose build         # the image is built locally; not transferred
docker compose up -d
```

If the host's UID/GID differs from the source, edit `docker-compose.yml`'s build args (`UID`, `GID`) before the rebuild — bind-mount file ownership flows through, and a mismatch will trip permission errors.

## See also

- [`docs/architecture.md`](architecture.md) — full container architecture, render engine, lifecycle phases.
- [`docs/heartbeatctl.md`](heartbeatctl.md) — every `heartbeatctl` subcommand, their effect on `agent.yml` and derived files.
- [`docs/getting-started.md`](getting-started.md) — first-boot walkthrough.
- [`docs/vault.md`](vault.md) — knowledge vault feature reference (Karpathy LLM Wiki).
