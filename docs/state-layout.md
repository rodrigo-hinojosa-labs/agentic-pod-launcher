# State layout — where everything persists

This doc maps every piece of agent state to a concrete path, and explains which artifacts survive restarts, image rebuilds, and the various flavors of `setup.sh --uninstall`.

TL;DR: **the workspace directory IS the agent**. Everything that must survive a lifecycle event lives under `<workspace>/`. In docker mode two bind-mounts wire it into the container; nothing important lives in a Docker-managed volume. Paths and counts below are as of **v0.12.0**.

## Deployment modes — read this before any table

`agent.yml` carries `deployment.mode: docker | local` (feature 011). Every `Host | Container` table below is **docker mode**; in local mode there is no container and no `/home/agent` mapping.

| Aspect | docker mode | local mode |
|---|---|---|
| Runtime | Alpine container, `crond` + tmux + watchdog | systemd units on the host (`agent-<name>.service` + timers) |
| Workspace | bind-mounted to `/workspace` | used in place |
| `.state/` | bind-mounted to `/home/agent` (the `agent` user's `$HOME`) | used in place; **`$HOME` stays the operator's home** |
| Claude config dir | `$HOME/.claude` = `.state/.claude` | `CLAUDE_CONFIG_DIR=<workspace>/.state/.claude`, pinned in `.state/remote-control.env` (`modules/remote-control.env.tpl`) |

The local-mode consequence worth internalizing: the session unit sets `HOME={operator home}` and only *repoints* `CLAUDE_CONFIG_DIR`. So `$HOME`-relative state that is not explicitly repointed (`~/.claude-mem`, `~/.bun`, `~/.npm`, the vault-backup clone cache) lands in the **operator's home**, outside the workspace. The paths that *are* explicitly repointed under `.state/` in local mode: the Claude config dir, the vault (`vault.path`), the qmd storage pair (`XDG_CACHE_HOME` + `QMD_CONFIG_DIR`), and the Google Calendar credentials.

## The two bind-mounts (docker mode)

`docker-compose.yml` declares exactly two volume mounts (`modules/docker-compose.yml.tpl`):

```yaml
volumes:
  - ./:/workspace          # the entire workspace dir → /workspace in the container
  - ./.state:/home/agent   # state subtree           → /home/agent (the agent user's $HOME)
```

Anything under `<workspace>/.state/` on the host is the same bytes as `/home/agent/` in the container. The rest of the workspace (`agent.yml`, `docker-compose.yml`, `scripts/`, …) lives at `/workspace/`.

`.state/` is gitignored in both modes. It contains OAuth credentials, Telegram tokens and (local mode) `remote-control.env` — never commit it.

## Memory — three independent layers

### Layer A — first-party auto-memory (Markdown files)

| Host | Container (docker mode) |
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

Every file has YAML frontmatter (`name`, `description`, `type`) plus a body. Claude writes them via the `Write` tool; the directory is created lazily on the first save.

`MEMORY.md` is the index — keep it under 200 lines (lines after 200 are truncated when loaded into context). One-line entries with a link to the full file:

```markdown
- [Title](file.md) — one-line hook
```

Local mode note: the project key follows the working directory, so the project subdir is named after the workspace path, not `-workspace`.

### Layer B — `claude-mem` plugin (SQLite + WAL)

| docker mode | local mode |
|---|---|
| `<workspace>/.state/.claude-mem/` = `/home/agent/.claude-mem/` | `$HOME/.claude-mem/` in the **operator's home** (the unit keeps `HOME` there) |

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

Tools that consult this layer: `mem-search`, `smart_search`, `smart_outline`, `smart_unfold`, `query_corpus`, `timeline`, `get_observations`. The worker daemon processes Claude transcripts in the background and appends observations to the `.db`.

### Layer C — knowledge vault (Karpathy LLM Wiki, opt-in)

| docker mode | local mode |
|---|---|
| `<workspace>/.state/.vault/` = `/home/agent/.vault/` (plus the convenience symlink `/home/agent/vault →`, created on boot **only when absent**) | `<workspace>/.state/.vault/` directly (`LOCAL_VAULT_DIR`, `setup.sh`) |

`.state/.vault` is the **default** of the configurable `agent.yml` key `vault.path` (`scripts/lib/schema.sh`). Docker rebases a non-default path under `/home/agent/` by stripping the `.state/` prefix (`docker/scripts/start_services.sh`). The boot-time symlink is guarded by `[ ! -e /home/agent/vault ]`, so it is created once and never rewritten: after changing `vault.path` on an existing agent, delete the old `/home/agent/vault` (i.e. `<workspace>/.state/vault`) by hand or it keeps pointing at the previous vault.

Per-agent file-based wiki following Karpathy's three-layer pattern (raw sources / wiki / schema). Opt-in via the wizard's "▸ Knowledge vault" prompts; controlled by `agent.yml.vault.enabled`. Used for **curated, synthetic, compounding knowledge derived from external sources** — not atomic facts (Layer A) or passive transcript observations (Layer B).

Layout (when seeded):

```
.vault/
├── raw_sources/             ← Layer 1 — immutable source documents (LLM reads, never edits)
│   └── README.md
├── wiki/                    ← Layer 2 — LLM-owned. Six knowledge-type subdirs + normalization:
│   ├── summaries/           ← one per ingested raw source
│   ├── entities/            ← concrete things (people, products, tools, projects, places)
│   ├── concepts/            ← abstract ideas (frameworks, principles, definitions)
│   ├── comparisons/         ← X vs Y
│   ├── overviews/           ← high-level synthesis of a domain
│   ├── synthesis/           ← cross-cutting integration; meta-pages
│   └── normalization/       ← canonical-name / alias pages (feature 014)
├── _templates/              ← operational boilerplate the LLM reads when creating pages
├── index.md                 ← catalog by type (LLM updates on every ingest/query)
├── log.md                   ← chronological append-only — `## [YYYY-MM-DD] {op} | <title>`
├── CLAUDE.md                ← Layer 3 schema — frontmatter spec, ingest/query/lint protocols
├── .graph/                  ← DERIVED wiki-graph artifacts (JSON, regenerable — see below)
└── .obsidian/               ← optional Obsidian config (user-owned, empty at scaffold)
```

Frontmatter is unified across the **six knowledge types** (`summaries/`, `entities/`, `concepts/`, `comparisons/`, `overviews/`, `synthesis/`):

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

`wiki/normalization/` is the exception: those pages are writing rules, not knowledge pages, and carry a different frontmatter (`canonical`, `aliases`, `match_case`, `entity`, `notes` — `modules/vault-skeleton/_templates/normalization.md`). A `type:` key there is a **violation**: the wiki-graph linter reports `normalization: type key not allowed` (`scripts/lib/wiki_graph.sh`).

Wikilinks use `[[<type>/<title>]]` form (slugified title). The LLM maintains them; backlinks are derived by the wiki-graph runner, not by the editor.

When `agent.yml.vault.mcp.enabled` is true, `.mcp.json` exposes the vault as the `vault` MCP server (package `@bitbonsai/mcpvault`). Its path arg is mode-resolved (`{{VAULT_MCP_PATH}}`): `/home/agent/.vault` in docker, the absolute workspace path in local mode.

**Seeding.** The skeleton is `modules/vault-skeleton/` (COPYd into the image at `/opt/agent-admin/modules/vault-skeleton/`). Two passes, both idempotent (`scripts/lib/vault.sh`):

- `vault_seed_if_empty` — plain `cp -R "$skeleton"/. "$target"/` when the vault dir is empty and `vault.seed_skeleton` is true. Docker runs it on container boot; local mode runs it host-side during `--regenerate` (`_seed_vault_local`).
- `vault_seed_missing` — additive delta upgrade for an **already-populated** vault: creates `wiki/normalization/`, drops `_templates/normalization.md` and the `schema-updates-0.8.0.md` delta, and appends one `log.md` line. Guarded by a hidden sentinel `_templates/.schema-updates-0.8.0.applied`, so it is a no-op after the first run and on fresh seeds.

Full feature documentation: [`docs/vault.md`](vault.md).

### Wiki-graph — derived artifacts (feature 014)

`scripts/lib/wiki_graph.sh` derives a graph from `wiki/` with no LLM and never edits the wiki. Artifacts are written atomically under the vault:

| Path | What |
|---|---|
| `<vault>/.graph/graph.json` | nodes (pages) + edges (wikilinks, `related:`, `sources:`, alias→canonical) |
| `<vault>/.graph/backlinks.json` | reverse index |
| `<vault>/.graph/findings.json` | structural lint: orphans, broken links, frontmatter violations, index drift, stale pages, alias occurrences |
| `<workspace>/scripts/heartbeat/wiki-graph.json` | runner state (last run/hash) |
| `<workspace>/scripts/heartbeat/.wiki-graph.lock` | flock — deliberately **outside** the vault (Syncthing) |

All four are regenerable: `agentctl heartbeat wiki-graph` (both modes). JSON-only by construction, so the vault backup's `*.md` filter and the qmd `**/*.md` mask exclude them.

## Conversation history — JSONL session logs

| Host | Container (docker mode) |
|---|---|
| `<workspace>/.state/.claude/projects/-workspace/*.jsonl` | `/home/agent/.claude/projects/-workspace/*.jsonl` |

Each session is one JSONL file (`<uuid>.jsonl`). One line per turn (user message, assistant message, tool call, tool result). `claude --continue` resumes the most-recent file — this is what makes a tmux respawn pick up where the prior session left off.

Filenames don't carry semantic meaning (random UUIDs); the supervisor / `--continue` finds the latest by mtime.

## Plugins — installed cache and patched code

| Host | Container (docker mode) |
|---|---|
| `<workspace>/.state/.claude/plugins/cache/<marketplace>/<name>/` | `/home/agent/.claude/plugins/cache/...` — holds `.installed-ok` plus a `<version>/` subdir with the plugin code |
| `<workspace>/.state/plugin-install-failures.jsonl` | `/workspace/.state/plugin-install-failures.jsonl` (docker mode; `docker/scripts/lib/plugin-install.sh`) |

Marketplace registration itself is CLI-managed under `.state/.claude/plugins/` and mirrored into `settings.json::extraKnownMarketplaces`, which `start_services.sh::pre_accept_extra_marketplaces` rewrites on every boot from the catalog.

The catalog is **descriptor-driven**: `modules/plugins/*.yml`, read by `scripts/lib/plugin-catalog.sh`. As of v0.12.0 there are 10 descriptors — 5 `type: default` (claude-md-management, claude-mem, context7, security-guidance, telegram) and 5 `type: optional` (code-simplifier, commit-commands, github, skill-creator, superpowers) — so the exact cache tree varies with what was opted into at scaffold time. Only `claude-mem` declares its own marketplace (`thedotmack`); the rest come from `claude-plugins-official`.

```
plugins/cache/
├── claude-plugins-official/
│   ├── claude-md-management/
│   ├── context7/
│   ├── security-guidance/
│   ├── superpowers/                        # only if opted in at scaffold
│   └── telegram/<version>/
│       └── server.ts                       # ← post-install patches edit this file
└── thedotmack/
    └── claude-mem/<version>/
        └── scripts/
            ├── mcp-server.cjs
            └── worker-service.cjs
```

The Telegram plugin's `server.ts` is the file the boot-time post-install hook edits (`docker/scripts/apply_telegram_typing_patch.py`): typing refresh, offset persistence, stderr capture, primary lock. Each group is guarded by a marker comment and is idempotent. On a fully patched file, `grep -c "agentic-pod-launcher:" server.ts` returns **9** (2 typing — the group marker plus the inline `_typingStop` call — + 4 offset hunks + 2 primary + 1 stderr). Treat exact-count greps as fragile: the typing marker is versioned (currently v4) and the patcher runs a `v1 → v4` upgrade cascade on every boot.

Each plugin's cache directory gets an `.installed-ok` sentinel (at `cache/<marketplace>/<name>/.installed-ok`, sibling of the version dir) after a successful `claude plugin install`. The supervisor checks the sentinel before re-running install on boot — a half-extracted cache (network blip) is detected as missing the sentinel and forced into a clean re-install; permanent failures are appended to `plugin-install-failures.jsonl` (surfaced by `agentctl doctor`).

## Telegram channel state

| Host | Container (docker mode) |
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

| Host | Container (docker mode) | What |
|---|---|---|
| `<workspace>/.state/.claude/.credentials.json` | `/home/agent/.claude/.credentials.json` | OAuth token (0600) |
| `<workspace>/.state/.claude/.claude.json` | `/home/agent/.claude/.claude.json` | Global Claude config (known projects, prefs) |
| `<workspace>/.state/.claude/settings.json` | `/home/agent/.claude/settings.json` | `enabledPlugins`, `permissions.defaultMode`, `extraKnownMarketplaces`, theme, effort level |
| `<workspace>/.state/.claude/sessions/` | `/home/agent/.claude/sessions/` | Auth state / locks |
| `<workspace>/.state/.claude/history.jsonl` | `/home/agent/.claude/history.jsonl` | Slash-command and prompt history |
| `<workspace>/.state/.gcal/gcp-oauth.keys.json` | `/home/agent/.gcal/gcp-oauth.keys.json` | Google Calendar MCP OAuth client secret — **secret material**, only when that MCP is enabled (`GOOGLE_OAUTH_CREDENTIALS` in `.mcp.json`) |

Local mode uses the same `.state/.claude/*` and `.state/.gcal/*` paths directly (`CLAUDE_CONFIG_DIR` + a mode-resolved `GCAL_CREDS_PATH`, `setup.sh`).

Docker mode: the supervisor's `pre_accept_bypass_permissions` writes `skipDangerousModePermissionPrompt: true` and `permissions.defaultMode: "auto"` to `settings.json` on every boot. Don't edit those keys by hand and expect them to stick — they get rewritten. The local session unit deliberately does **not** skip permission prompts.

## RAG storage — qmd index, managed prefix, scratch

Opt-in (`vault.enabled` + `vault.qmd.enabled`). The bulk of what qmd writes — index, models, managed prefix, scratch — lives under one root: `$HOME/.cache/qmd` in docker (→ `.state/.cache/qmd` through the bind-mount), and the same `<workspace>/.state/.cache/qmd` in local mode via an explicit env pin. The one thing that lands **outside** that root is the collection registry, which qmd writes to its config dir (`.state/.config/qmd`, see the table).

| Path (host, both modes) | What |
|---|---|
| `<workspace>/.state/.cache/qmd/index.sqlite` | the lexical + vector index (qmd's own storage default) |
| `<workspace>/.state/.cache/qmd/models/*.gguf` | embedding model, downloaded on first `qmd embed` (~300 MB) |
| `<workspace>/.state/.cache/qmd/pkg/` | **managed bun-install prefix** (feature 016): pinned `@tobilu/qmd`, `node_modules/.bin/qmd`, plus `.installed-hash` for idempotency. Replaces `bunx`, which recompiled tree-sitter and aborted on Alpine musl |
| `<workspace>/.state/.cache/qmd/tmp/` | host-backed scratch (feature 015): `TMPDIR`/`TMP`/`TEMP` for install, embed and reindex — deliberately **not** the container tmpfs |
| `<workspace>/.state/.cache/qmd/.qmd-setup-ok` | first-boot setup sentinel |
| `<workspace>/.state/.cache/qmd/.reindex.lock` | flock shared by the cron backstop, the watcher and manual reindexes |
| `<workspace>/.state/.config/qmd/` | qmd's collection registry. **Local mode:** pinned via `QMD_CONFIG_DIR` (`modules/local-qmd-reindex.sh.tpl`). **Docker mode:** not exported — qmd falls back to its own default under `$HOME`, which is `.state/` anyway |
| `<workspace>/scripts/heartbeat/qmd-index.json` | reindex state: `{hash, last_run, last_status, runs}` plus `pending` when known |

**Storage env contract (feature 013).** The qmd *binary* honors `XDG_CACHE_HOME` (index + models) and `QMD_CONFIG_DIR` (collections) — **not** `QMD_CACHE_HOME`, which only the bash lib reads for its own bookkeeping. Local mode therefore exports all three (`modules/local-qmd-reindex.sh.tpl`): `XDG_CACHE_HOME=<workspace>/.state/.cache` and `QMD_CACHE_HOME=<workspace>/.state/.cache/qmd` converge binary and lib on the same cache root, while `QMD_CONFIG_DIR=<workspace>/.state/.config/qmd` isolates the collection registry per workspace. The same `XDG_CACHE_HOME` + `QMD_CONFIG_DIR` pair is pinned into the qmd MCP's `env` in `.mcp.json` (`{{QMD_MCP_ENV}}`; docker renders `{}`, `setup.sh`). Writer and reader are an atomic pair: fix one without the other and the MCP reads a silently empty, auto-created sqlite.

The MCP server itself never uses `bunx` either — `.mcp.json`'s `{{QMD_MCP_COMMAND}}` points at `/opt/agent-admin/scripts/qmd-mcp` (docker, image-baked) or `<workspace>/scripts/local/agent-qmd-mcp.sh` (local, rendered), both of which exec `qmd mcp` from the managed prefix.

`last_status` values (feature 018): `indexed`, `skipped`, `error`, plus `partial` (embed pass cap hit) and `stalled` (a pass made no forward progress). `pending` is the count of documents still lacking an embedding; an unchanged vault only skips embedding when `pending == 0`, so an interrupted first embed resumes on the next tick instead of freezing a partial corpus. See [`docs/qmd-upgrade-checklist.md`](qmd-upgrade-checklist.md) when bumping the qmd pin.

Docker mode also bakes a musl-compiled `sqlite-vec` extension at `/opt/agent-admin/sqlite-vec/vec0.so` (feature 017) and swaps it into the prefix at runtime; that artifact is image-baked, not state.

## Fork-backup state (three orphan branches)

| Path | Mode | What |
|---|---|---|
| `<workspace>/scripts/heartbeat/identity-backup.json` | docker | last hash/commit/push for `backup/identity` |
| `<workspace>/scripts/heartbeat/vault-backup.json` | docker + local | idem for `backup/vault` |
| `<workspace>/scripts/heartbeat/config-backup.json` | docker | idem for `backup/config` |
| `<workspace>/.state/.cache/identity-backup/clone/` | docker | clone cache for the identity branch |
| `<workspace>/.state/.cache/agent-backup/vault-clone/` | docker | clone cache for the vault branch |
| `<workspace>/.state/.cache/agent-backup/config-clone/` | docker | clone cache for the config branch |
| `$HOME/.cache/agent-backup/vault-clone/` | local | vault clone cache — lives in the **operator's home, outside the workspace**; `--uninstall --purge` removes it explicitly |

Local mode ships only the vault backup (a systemd timer). Identity and config backups are driven by `heartbeatctl backup-identity` / `backup-config` inside the container. Restore is `setup.sh --restore-from-fork <url>` during scaffold: it pulls `backup/config` first (so `vault.path` is known), then `backup/identity`, then `backup/vault`, skipping any branch that is absent.

## Heartbeat — docker mode only

There is no heartbeat in local mode (no `crond`, no heartbeat unit); local mode's periodic work runs as systemd timers instead.

### Isolated `CLAUDE_CONFIG_DIR` for the heartbeat session

Created lazily by `ensure_heartbeat_config_dir()` on the first cron tick. May not exist yet if no tick has fired since the most recent boot.

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

### The crontab

`/etc/crontabs/agent` is rendered by `heartbeatctl reload` into `<workspace>/scripts/heartbeat/.crontab.staging` and copied in by a root-owned sync loop. Up to **7 lines**, each gated by its own `agent.yml` key (`docker/scripts/heartbeatctl`):

| Line | Default schedule | Gate |
|---|---|---|
| heartbeat tick | from `features.heartbeat.interval` | `features.heartbeat.enabled` |
| `backup-identity` | `30 3 * * *` | `features.identity_backup.enabled` |
| `backup-vault` | `0 * * * *` | `vault.enabled` (`vault.backup_schedule`) |
| `backup-config` | `30 3 * * *` | `features.config_backup.enabled` (default true) |
| token-health probe | `0 * * * *` | `features.token_health.enabled` (default true) |
| `qmd-reindex` backstop | `*/5 * * * *` | `vault.qmd.enabled` (`vault.qmd.schedule`) |
| `wiki-graph` backstop | `20 */6 * * *` | `vault.enabled` + `vault.wiki_graph.enabled != false` |

### Runner state and logs (not under `.state/`)

Everything the runners persist lives in `<workspace>/scripts/heartbeat/` (`/workspace/scripts/heartbeat/` in the container), next to the heartbeat code itself:

| Path | What | Mode |
|---|---|---|
| `heartbeat.sh`, `heartbeat.conf` | runner + rendered config | docker |
| `state.json` | last-run summary + counters (schema 1, atomic rewrite) | docker |
| `.crontab.staging` | crontab rendered by `heartbeatctl reload` | docker |
| `qmd-index.json`, `wiki-graph.json`, `vault-backup.json` | RAG + backup runner state | docker + local |
| `identity-backup.json`, `config-backup.json` | backup runner state | docker |
| `token-health/<id>.json`, `token-health/warnings.jsonl` | per-token probe state + history | docker |
| `qmd-schedule.fallback`, `wiki-graph-schedule.fallback` | markers left when a cron schedule can't be converted to `OnCalendar` | local |
| `logs/runs.jsonl` | one JSON line per heartbeat tick | docker |
| `logs/sessions/<run_id>.log` | per-tick claude session transcript | docker |
| `logs/cron.log` | crond stderr for the heartbeat line | docker |
| `logs/telegram-mcp-stderr.log` | captured plugin stderr (typing-tick instrumentation) | docker |
| `logs/backup-identity.log`, `logs/backup-vault.log`, `logs/backup-config.log`, `logs/token-health.log`, `logs/qmd-reindex.log`, `logs/wiki-graph.log` | one per cron line | docker |

`runs.jsonl` is rotated at 10 MB → `.1`, `.2.gz`, `.3.gz` (max 3 generations). Per-run session logs in `logs/sessions/` are pruned to the last 20 by the heartbeat itself. `state.json` is rewritten atomically (temp + rename) at the end of every tick — see [`docs/architecture.md`](architecture.md) for the field contract, and [`docs/heartbeatctl.md`](heartbeatctl.md) for the subcommands that mutate it.

## Local-mode artifacts (mode = local)

| Path | What | Gitignored? |
|---|---|---|
| `<workspace>/.state/remote-control.env` | `EnvironmentFile` for the session unit: `CLAUDE_CONFIG_DIR`, `HOME`, `PATH` (0640). Loaded SECOND (after `.env`) so it always wins on a name collision. | yes (`.state/`) |
| `<workspace>/.state/healthcheck-notify.env` | **legacy compatibility override** (021): if present, wins over `.env` for `NOTIFY_BOT_TOKEN`/`NOTIFY_CHAT_ID` — kept only so an agent that already had one keeps alerting unchanged. A fresh scaffold never creates this file; the workspace `.env` is the single source of secrets going forward. | yes (`.state/`) |
| `<workspace>/scripts/local/agent-{login,killswitch,healthcheck,bootstrap}.sh` | rendered helpers | yes |
| `<workspace>/scripts/local/agent-{qmd-reindex,qmd-watch,qmd-mcp}.sh` | rendered when `vault.qmd.enabled` | yes |
| `<workspace>/scripts/local/agent-{vault-backup,wiki-graph}.sh` | rendered when the vault is on | yes |
| `<workspace>/agent-<name>.service` | session unit, staged in the workspace root when `sudo` is unavailable | yes |
| `<workspace>/scripts/local/agent-<name>-*.{service,timer}` | companion units, staged when `sudo` is unavailable | yes |
| `/etc/systemd/system/agent-<name>*.{service,timer}` | the installed copies (session, healthcheck, qmd-reindex, qmd-watch, vault-backup, wiki-graph — up to 10 units) | n/a (outside the workspace) |

`setup.sh --uninstall` disables and removes all 10 units when it can get `sudo`; otherwise it prints the manual command.

## Workspace-level files (outside `.state/`)

Gitignore status is from the `.gitignore` that `setup.sh` copies into every scaffolded workspace.

| Host path | What | Persists? | Gitignored? |
|---|---|---|---|
| `<workspace>/agent.yml` | Single source of truth — wizard + `heartbeatctl set-*` write here | yes | **yes** — durability comes from the `backup/config` orphan branch, not from committing it |
| `<workspace>/.env` | Secrets (TELEGRAM_BOT_TOKEN, MCP tokens), 0600 | yes | yes — replicated as an age-encrypted `.env.age` on `backup/identity` only when a recipient key is configured; without one the identity backup runs in partial mode and omits it |
| `<workspace>/.env.example` | Template with placeholders for `.env` | yes | no |
| `<workspace>/CLAUDE.md` | Agent base memory; derived from `modules/claude-md.tpl` | yes | **yes** (regenerable: `setup.sh --regenerate --force-claude-md`) |
| `<workspace>/.mcp.json` | MCP server config (rendered from `agent.yml`) | yes | **yes** (regenerable) |
| `<workspace>/CONTAINER.md` | Live runtime info; rewritten on every container boot (docker mode) | yes (volatile) | yes |
| `<workspace>/claude.log` | tmux pipe-pane capture of the agent session (docker mode) | yes (grows monotonically) | yes |
| `<workspace>/claude.cron.log` | crond stderr (docker mode) | yes | yes |
| `<workspace>/docker-compose.yml` | Compose config, rendered from `agent.yml` (docker mode) | yes | no |
| `<workspace>/docker/` | Dockerfile + image-baked scripts — **not copied into local-mode workspaces** | yes | no |
| `<workspace>/scripts/heartbeat/` | Workspace-templated heartbeat code | yes | code no; `logs/` + `heartbeat.conf` yes |
| `<workspace>/scripts/local/` | Rendered local-mode helpers + staged units | yes | yes |

Rule of thumb: a derived file being gitignored is not a durability problem — `setup.sh --regenerate` re-renders it from `agent.yml`, and `agent.yml` itself is replicated to the `backup/config` branch of the agent's fork.

## Other state under `.state/` (cache + runtime)

| Host | What | Cheap to wipe? |
|---|---|---|
| `<workspace>/.state/.bun/` | bun's package install cache | yes |
| `<workspace>/.state/.npm/` | npm's package install cache (used by `npx` for some MCPs) | yes |
| `<workspace>/.state/.cache/qmd/` | qmd index, embedding model, managed prefix, scratch (see RAG section) | **no** — see below |
| `<workspace>/.state/.cache/identity-backup/`, `.state/.cache/agent-backup/` | fork-backup clone caches | yes (re-cloned on next backup) |
| `<workspace>/.state/.local/` | XDG state dir for various tools | yes |
| `<workspace>/.state/.config/` | XDG config dir (uv, qmd collections, …) | mostly — `.config/qmd` holds the collection registry, re-created by the next `qmd_setup_if_needed` |

The 2026-era caveat: **`.cache/qmd` is not a throwaway cache.** Deleting it discards `index.sqlite` and the embedding model — the next boot re-downloads ~300 MB and must re-run a full `update` + multi-pass `embed`, which on a large vault is expensive (and is exactly the completion problem feature 018 exists to solve). Everything else in this table genuinely rebuilds itself.

Note also `<workspace>/.state/.claude.json` (at the top level of `.state/`, not inside `.claude/`) — Claude Code writes a stripped copy here as well. Both copies are kept in sync by the CLI.

## What does NOT persist (docker mode)

- `/tmp/` inside the container (tmpfs, capped at 100 MB) — the watchdog markers in `/tmp/agent-watchdog/` and the qmd-watch pidfile. Wiped on container restart. **Note:** RAG tooling does *not* use it — both runners repoint `TMPDIR`/`TMP`/`TEMP` at host-backed scratch (feature 015, `scratch_dir` in `scripts/lib/rag_obs.sh`), precisely because the 100 MB tmpfs ran out of space. They use *different* scratch dirs: `qmd install/embed/reindex` land in `.state/.cache/qmd/tmp` (the qmd cache root), while the wiki-graph runner uses `<workspace>/scripts/heartbeat/tmp` (the dir holding its state file).
- `/opt/agent-admin/` — image-baked, read-only, regenerated on every `docker compose build`. Includes `entrypoint.sh`, `start_services.sh`, `wizard-container.sh`, `heartbeatctl`, `qmd-mcp`, `apply_telegram_typing_patch.py`, `check_token_health.sh`, the `lib/` helpers, `bigstack.so`, the musl `sqlite-vec/vec0.so`, the vault skeleton, and the safe-default crontab template.
- `/etc/crontabs/agent` — root-owned, regenerated by `entrypoint.sh` and kept in sync with `.crontab.staging` by a root background loop. Hand edits are clobbered.
- The Docker image itself (`agentic-pod:latest` by default, `docker.image_tag` in `agent.yml`) — discarded on `docker compose build`.

## Disk usage at steady state

Rough sizes for a fresh agent with the default plugin catalog, as of v0.12.0:

| Path | Size | Notes |
|---|---|---|
| `<workspace>/.state/.claude/` | ~700 MB | Plugin cache (`plugins/cache/`) is the bulk — node_modules per plugin |
| `<workspace>/.state/.cache/qmd/` | ~300 MB + index | Embedding model (`models/*.gguf`) + `index.sqlite` + the managed bun prefix; only when qmd is enabled |
| `<workspace>/.state/.claude-mem/` | ~5 MB | Grows with usage; observation rows + WAL (local mode: in the operator's home) |
| `<workspace>/.state/.bun/` + `.npm/` + `.local/` | ~200 MB | Package caches |
| `<workspace>/claude.log` | grows | tmux pipe-pane capture; truncate / rotate manually if needed |
| `<workspace>/.state/.claude/projects/-workspace/` | grows | One JSONL per session; sessions accumulate |

## Lifecycle commands and what they touch

| Command | Effect on state |
|---|---|
| `docker compose restart` | docker: restarts processes; preserves all of `.state/` and the workspace |
| `docker compose down` | docker: stops + removes container; preserves `.state/` and workspace |
| `docker compose down -v` | docker: same as `down` (there are no Docker-managed volumes) |
| `docker compose build` | docker: rebuilds image; doesn't touch `.state/` |
| `sudo systemctl restart agent-<name>.service` | local: restarts the Remote Control session; touches nothing on disk |
| `setup.sh --regenerate` | Re-renders derived files from `agent.yml` (both modes); doesn't touch `.state/` |
| `setup.sh --restore-from-fork <url>` | Scaffold-time: pulls `backup/config` → `backup/identity` → `backup/vault` into the new workspace, skipping absent branches |
| `setup.sh --backup` | docker: triggers an immediate identity backup (`heartbeatctl backup-identity` in the container) |
| `setup.sh --uninstall --yes` | Stops the container / removes the systemd units, removes rendered files; preserves `agent.yml`, `.env`, `.state/` |
| `setup.sh --uninstall --purge --yes` | Plus removes `agent.yml`, `.env`, `.state/` — and, in local mode, `~/.cache/agent-backup/vault-clone` |
| `setup.sh --uninstall --nuke --yes` | Plus deletes the entire workspace directory (implies `--purge`) |
| `rsync -a <workspace>/ <other-host>:<dest>/` | Full agent migration — including OAuth, memory, sessions, plugin cache, and the qmd index |

## Migrating an agent

Because the workspace is self-contained, copying it is a full migration (docker mode shown):

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

Local mode: `rsync` the workspace, then `./setup.sh --regenerate` on the destination (the units embed absolute paths, the operator user and the resolved `claude` binary) and re-install the systemd units. Remember that `~/.claude-mem` and `~/.cache/agent-backup/vault-clone` live in the operator's home, so they do **not** travel with the workspace.

## See also

- [`docs/architecture.md`](architecture.md) — container architecture, render engine, lifecycle phases, RAG contracts.
- [`docs/heartbeatctl.md`](heartbeatctl.md) — every `heartbeatctl` subcommand and its effect on `agent.yml` and derived files.
- [`docs/getting-started.md`](getting-started.md) — first-boot walkthrough.
- [`docs/vault.md`](vault.md) — knowledge vault feature reference (Karpathy LLM Wiki).
- [`docs/qmd-upgrade-checklist.md`](qmd-upgrade-checklist.md) — what to re-verify when bumping the qmd pin.
