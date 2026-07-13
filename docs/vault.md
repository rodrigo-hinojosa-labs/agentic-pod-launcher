# Vault — per-agent Karpathy LLM Wiki

The vault is a per-agent, file-based knowledge base following Andrej Karpathy's "LLM Wiki"
pattern (https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f). It coexists with
the agent's two other memory layers (auto-memoria and claude-mem) and serves a different
role: **curated, synthetic, compounding knowledge derived from external sources**.

This page is for the human running the agent. The agent's own instructions for using the vault
live in the vault's own `CLAUDE.md` (at the vault root — `~/.vault/CLAUDE.md` in docker mode,
`<workspace>/.state/.vault/CLAUDE.md` in local mode) — that file is authoritative for vault
conventions and is co-evolved between the human and the LLM.

**Deployment modes.** The vault, the QMD index, the wiki-graph runner and the vault backup all
work in both `deployment.mode: docker` and `deployment.mode: local` (systemd). Where the two
differ (paths, commands, scheduling) this page qualifies the statement explicitly. Facts below
(versions, defaults, counts) are as of **v0.12.0** unless a section says otherwise.

## When to enable it

Turn on the vault when you want the agent to:

- Read external sources (articles, papers, transcripts, gists) and build a structured
  knowledge base over them.
- Maintain a wiki of entities, concepts, comparisons, overviews, and synthesis pages — and
  update those pages as new sources arrive.
- Answer questions with citations that reference the wiki.
- Periodically lint the wiki (orphans, contradictions, stale claims, missing cross-refs).

Skip the vault if your agent's job is purely operational (heartbeat reports, ops automation,
chat handler) — auto-memoria covers that ground without the bookkeeping overhead.

## Three layers (verbatim from Karpathy)

> *"Raw sources — your curated collection of source documents. Articles, papers, images, data
> files. These are immutable — the LLM reads from them but never modifies them. This is your
> source of truth.*
>
> *The wiki — a directory of LLM-generated markdown files. Summaries, entity pages, concept
> pages, comparisons, an overview, a synthesis. The LLM owns this layer entirely. It creates
> pages, updates them when new sources arrive, maintains cross-references, and keeps everything
> consistent. You read it; the LLM writes it.*
>
> *The schema — a document (e.g. CLAUDE.md for Claude Code or AGENTS.md for Codex) that tells
> the LLM how the wiki is structured, what the conventions are, and what workflows to follow
> when ingesting sources, answering questions, or maintaining the wiki."*

In this implementation:

- **Layer 1 — `raw_sources/`**: Immutable. The LLM reads, never modifies.
- **Layer 2 — `wiki/`**: LLM-owned. Six type subdirectories named verbatim from the gist:
  `summaries/`, `entities/`, `concepts/`, `comparisons/`, `overviews/`, `synthesis/`. Plus
  `normalization/` (feature 014) — writing rules, not knowledge; see below.
- **Layer 3 — `CLAUDE.md`**: Schema. Defines frontmatter spec, wikilink format, and the
  protocols for ingest / query / lint operations. Co-evolved by you and the LLM.

Plus two root files Karpathy calls out:

- `index.md` — content-oriented catalog (one entry per wiki page, organized by type).
- `log.md` — chronological append-only record of every operation, parseable with
  `grep "^## \[" log.md | tail -N`.

## Where it lives

The vault path is `vault.path` in `agent.yml` (default `.state/.vault`, relative to the
workspace).

| Mode | On disk (host) | As the agent sees it |
|---|---|---|
| **docker** | `<workspace>/.state/.vault/` | `/home/agent/.vault/` (real path), `/home/agent/vault/` → symlink alias |
| **local** | `<workspace>/.state/.vault/` | same path — no rebase, no symlink |

Docker mode: the vault inherits the workspace's `.state/` bind-mount (`./.state:/home/agent` in
`docker-compose.yml`) — no extra Docker volume. It is immune to `docker compose down -v` (no
Docker-managed volumes). The convenience symlink `~/vault → ~/.vault` exists so docs and prompts
can use the shorter path; the MCP server config targets the real path (`~/.vault`) to avoid
symlink ambiguity in tools that resolve paths. Local mode has no container, so the agent reads
the workspace path directly and no symlink is created.

Either way the vault is per-agent, portable via `rsync` (the same migration command that copies
the rest of the agent's state) and preserved across `setup.sh --uninstall --yes`. Only `--purge`
or `--nuke` removes it.

## Lifecycle

### At scaffold (`./setup.sh`)

The wizard's "▸ Knowledge vault" section asks **four** questions:

1. **Enable knowledge vault?** (default `y`) — toggles `vault.enabled`.
2. **Seed initial vault structure (templates, schema, log)?** (default `y`) — toggles
   `vault.seed_skeleton`. Copies `modules/vault-skeleton/` into the per-agent vault.
3. **Register MCPVault server (@bitbonsai/mcpvault)?** (default `y`) — toggles
   `vault.mcp.enabled`. Adds a `vault` server entry to `.mcp.json` so Claude has structured
   tools (`read_note`, `write_note`, `search_notes`, etc.) on top of file-system access.
4. **Enable QMD hybrid search (BM25+vector+rerank, ~300MB embedding model on first use)?**
   (default **`n`**) — toggles `vault.qmd.enabled`.

Questions 2–4 are only asked when question 1 is `y`.

Answers go to the `vault:` block in `agent.yml`:

```yaml
vault:
  enabled: true
  path: .state/.vault
  seed_skeleton: true
  force_reseed: false
  initial_sources: []
  mcp:
    enabled: true
    server: vault
  qmd:
    enabled: false
    version: "2.5.3"
    schedule: "*/5 * * * *"
  schema:
    frontmatter_required: true
    log_format: "## [{date}] {op} | {title}"
```

Two optional keys are **not** written by the wizard but are read when present:

- `vault.wiki_graph.enabled` / `vault.wiki_graph.schedule` — the derived-graph runner is on by
  default whenever the vault is on; set `enabled: false` to opt out, or override the cadence
  (default `20 */6 * * *`).
- `vault.backup_schedule` — cadence of the vault backup (default `0 * * * *`, hourly).

### Seeding

**Docker mode** — `docker/scripts/start_services.sh::seed_vault_if_needed` runs as the `agent`
user during `boot_side_effects` on every boot:

1. Reads `vault.enabled` from `agent.yml`. No-op if false.
2. Resolves the in-container path. Default `.state/.vault` maps to `/home/agent/.vault/`.
3. `vault_ensure_paths` — `mkdir -p` the vault root with agent ownership.
4. If `vault.seed_skeleton` is true and the vault is empty: `vault_seed_if_empty` **copies**
   (`cp -R`) `/opt/agent-admin/modules/vault-skeleton/` into the vault and replaces the
   `SCAFFOLD_DATE` placeholder in `log.md` with today's date. Idempotent — no-op once seeded.
5. `vault_seed_missing` — additive upgrade for an already-populated vault (see feature 014
   below): adds only the *new* skeleton structures, never overwrites, never touches the vault's
   co-evolved `CLAUDE.md`.
6. Creates the convenience symlink `/home/agent/vault → /home/agent/.vault` if missing.

**Local mode** — `setup.sh::_seed_vault_local` does the equivalent host-side at scaffold and on
every `--regenerate`, against `<workspace>/<vault.path>` (no `/home/agent` rebase, no symlink).
Same skeleton, same idempotency, same `force_reseed` and `vault_seed_missing` semantics.

### Day-to-day

The agent reads the vault's `CLAUDE.md` to know how to handle the vault. When you ask it to
ingest a source, query a topic, or lint the wiki, it follows the protocols defined in that
schema document. See "Operations" below for what each one does.

### After editing `agent.yml`

Toggling `vault.enabled`, `vault.mcp.enabled` or `vault.qmd.enabled` requires re-rendering
`.mcp.json` (and, in local mode, the systemd units) so the MCP entries and timers appear or
disappear:

```bash
cd ~/agents/my-agent
./setup.sh --regenerate

# docker mode — restart so Claude picks up the new .mcp.json
./scripts/agentctl restart

# local mode — restart the session unit
sudo systemctl restart agent-<name>.service
```

The vault's content is never re-rendered — once seeded, it belongs to the LLM.

## Operations

The agent invokes these via the protocols documented in the vault's `CLAUDE.md`. There are no
built-in slash commands like `/vault:ingest` — the operations are prompted in natural
language ("ingest this URL", "what does the wiki say about X", "lint the wiki").

### Ingest

The LLM:

1. Clips the source (URL, file, or paste) into `raw_sources/<slug>.md` with minimal
   frontmatter. Never edits the source again.
2. Writes a summary page in `wiki/summaries/<slug>.md` linking to the raw source.
3. Updates entity / concept / comparison pages this source affects. May create new ones.
4. Adds entries to `index.md` under the relevant section.
5. Appends a line to `log.md`: `## [YYYY-MM-DD] ingest | <source title>`.

Karpathy's note on this: *"a single source might touch 10–15 wiki pages."* That's normal —
the LLM doesn't get bored, and the cost of bookkeeping is near zero.

### Query (answering questions)

The LLM:

1. Searches the wiki (file tools, MCPVault's `search_notes`, or the QMD MCP when enabled).
2. Reads relevant pages end-to-end, plus 1-hop neighbors from `.graph/backlinks.json`.
3. Synthesizes a fresh answer with citations to wiki pages and raw sources.
4. Optionally proposes filing the synthesis as a new wiki page (typically `overview` or
   `synthesis`). Doesn't auto-create — asks first.
5. Logs to `log.md`: `## [YYYY-MM-DD] query | <question summary>`.

### Lint (maintenance)

Run periodically. The LLM scans for:

- **Contradictions** — incompatible claims about the same thing across pages.
- **Orphans** — wiki pages with no inbound `[[wikilinks]]`.
- **Stale claims** — page `updated:` predates its newest source by a long gap.
- **Missing cross-refs** — entities/concepts mentioned in body text but not in `related:`.
- **Important concepts without their own page** — terms that appear across many summaries
  but lack a dedicated `wiki/concepts/<term>.md`.

Outputs a report at `wiki/synthesis/lint-<date>.md`. Doesn't make destructive changes —
surfaces findings for you to act on. This is the *semantic* lint (LLM-driven); the *structural*
lint is the deterministic wiki-graph runner below.

## Normalization + the derived graph (feature 014)

Two additions turn the wiki from a folder of files into a navigable, self-checking graph —
deployment-agnostic (docker & local alike).

**`wiki/normalization/`** holds *writing rules*, not knowledge. Each page declares a
`canonical` form and its `aliases` (mis-spellings, transcription errors) with its own
frontmatter — e.g. canonical `Cencosud`, aliases `[SENCOSUD, Sencosud]`. See
`_templates/normalization.md`. During ingest the agent normalizes terminology to the
canonical form (the raw source stays verbatim — layer 1 is immutable). These pages are NOT
one of the six knowledge types and are never cited as knowledge.

**The derived graph** (`<vault>/.graph/`) is regenerated deterministically — without an LLM,
and it never edits the wiki — by `scripts/lib/wiki_graph.sh`:

- `graph.json` — nodes (typed pages) + edges (`[[wikilinks]]`, `related:`, `sources:`,
  `alias→canonical`).
- `backlinks.json` — per page: `backlinks`, `related_out`, `co_sourced`, `canonical_of`. The
  query protocol reads this for 1-hop neighbors before synthesizing.
- `findings.json` — structural lint: orphans, broken wikilinks, frontmatter violations,
  `index.md` drift, stale pages, alias occurrences.

Scheduling and manual trigger:

| | Scheduled | On demand |
|---|---|---|
| **docker** | cron line rendered by `heartbeatctl` from `vault.wiki_graph.schedule` (default `20 */6 * * *`) | `./scripts/agentctl heartbeat wiki-graph` |
| **local** | `agent-<name>-wiki-graph.timer` (same cron converted to `OnCalendar`) | `./scripts/agentctl heartbeat wiki-graph` |

State lands in `scripts/heartbeat/wiki-graph.json` (freshness + finding counts). The `.graph/`
artifacts are JSON only, so they are excluded from the vault backup and the QMD index by
construction, and are always regenerable (never backed up). Local mode surfaces them in
`agentctl status` (freshness + counts) and `agentctl doctor` (warns on integrity findings, fails
on a runner dead for more than 2× its interval); docker mode: read the state file directly with
`jq . scripts/heartbeat/wiki-graph.json`.

Existing vaults get `wiki/normalization/` and the schema updates added automatically on the next
boot (docker) or `--regenerate` (local) without overwriting anything — `vault_seed_missing`,
gated by a hidden `.applied` marker so the schema delta is never re-deposited after you delete
it (see `modules/vault-deltas/` + the `log.md` entry).

## Vault backup (the `backup/vault` orphan branch)

When the agent has a fork configured, the vault's **markdown subset** is replicated to a
`backup/vault` orphan branch in that fork (`scripts/lib/backup_vault.sh`). It is one of three
independent backup branches (`identity`, `vault`, `config`) — see
[`docs/architecture.md`](architecture.md) for the shared shape.

- **What is staged**: every `*.md` under the vault, minus the exclusions
  (`.obsidian/cache`, `.obsidian/workspace*.json`, `.obsidian/.trash`, `.trash`,
  `*.sync-conflict-*`). Non-markdown raw sources and `.graph/*.json` are out by construction.
- **Idempotency**: a sha256 over the markdown content + relative filenames (`vault_hash`) —
  the *same* hash the QMD reindex debounces on. Unchanged vault → no commit, no push.
- **Cadence**: default hourly. Docker: a cron line from `vault.backup_schedule` (default
  `0 * * * *`). Local: `agent-<name>-vault-backup.timer` with the same cron converted to
  `OnCalendar` (default `*-*-* *:00:00`).
- **On demand**: `./scripts/agentctl heartbeat backup-vault` (both modes; supports `--dry-run`).
- **State**: `scripts/heartbeat/vault-backup.json` (hash, last commit, last push).
- **Restore**: `./setup.sh --restore-from-fork <url>` pulls `config` → `identity` → `vault`,
  skipping any branch that is absent.

No fork configured → the primitive is a clean no-op.

## Coexistence with auto-memoria and claude-mem

| Layer | Use it for |
|---|---|
| **Auto-memoria** (`~/.claude/projects/-workspace/memory/`) | Atomic facts about the user / project. Loaded into context on every session start via `MEMORY.md`. Tipped: `user_*`, `feedback_*`, `project_*`, `reference_*`. |
| **`claude-mem`** (`~/.claude-mem/*.db`) | Auto-captured observations from your transcripts (passive). The worker daemon writes; you query via `mem-search`, `smart_search`, `timeline`. |
| **Vault** (`~/.vault/`) | Curated, synthetic, compounding knowledge from external sources. Pages you'll revisit, refine, link, and lint. |

Heuristic:

- "Save this fact about the user / project" → auto-memoria.
- "What did we do last week?" → claude-mem (transcript-derived).
- "Build a knowledge base on X / ingest this article / synthesize across sources" → vault.

If unsure, ask the agent. Don't double-write across layers.

## File reference

```
<vault>/                               docker: ~/.vault  |  local: <workspace>/.state/.vault
│
├── raw_sources/                       Layer 1, immutable
│   ├── README.md                      naming, formats, frontmatter spec
│   └── (articles, papers, transcripts, gists, data, images...)
│
├── wiki/                              Layer 2, LLM-owned
│   ├── summaries/                     one per ingested raw source
│   ├── entities/                      people, products, tools, projects, places
│   ├── concepts/                      ideas, frameworks, principles
│   ├── comparisons/                   X vs Y
│   ├── overviews/                     high-level synthesis of a domain
│   ├── synthesis/                     cross-cutting integration; meta-pages
│   └── normalization/                 canonical forms + aliases (NOT knowledge; 014)
│
├── _templates/                        operational boilerplate (NOT wiki content)
│   ├── source.md, summary.md, entity.md, concept.md
│   ├── comparison.md, overview.md, synthesis.md, normalization.md
│
├── .graph/                            derived graph + structural lint (JSON, regenerable; 014)
├── index.md                           catalog by type (LLM updates on every change)
├── log.md                             chronological append-only
├── CLAUDE.md                          Layer 3 schema (authoritative)
└── .obsidian/                         Obsidian config (empty at scaffold; user-owned)
```

## MCP integration (MCPVault)

When `vault.mcp.enabled` is true, `.mcp.json` includes a `vault` server entry. The template is
`modules/mcp-json.tpl`; the vault path is rendered per deployment mode (`{{VAULT_MCP_PATH}}` —
`/home/agent/.vault` in docker, `<workspace>/<vault.path>` in local):

```json
"vault": {
  "command": "npx",
  "args": ["-y", "@bitbonsai/mcpvault@0.12.0", "<vault path>"],
  "env": {}
}
```

The version is **pinned** (`@0.12.0` as of v0.12.0), not `@latest` — and in docker mode the same
version is pre-warmed into the image's npm cache at build time (`ARG MCP_VAULT_VERSION` in
`docker/Dockerfile`), so the first MCP handshake is a cache hit with no registry round-trip.

The package is `@bitbonsai/mcpvault` (https://github.com/bitbonsai/mcpvault). It's a
zero-dependency MCP server that accesses vault files directly — it does NOT require the
Obsidian app to be running, which makes it suitable for a headless agent. The server
exposes 14 tools: `read_note`, `write_note`, `patch_note`, `delete_note`, `move_note`,
`move_file`, `list_directory`, `read_multiple_notes`, `search_notes`, `get_frontmatter`,
`update_frontmatter`, `get_notes_info`, `get_vault_stats`, `manage_tags`.

Docker mode: `npx` caches under **`/opt/npm-cache`** (`NPM_CONFIG_CACHE`), image-baked and
deliberately **off** the `/home/agent` bind-mount — the npm cache's thousands of small-file ops
fail on macOS VirtioFS (errno -35). It is not part of `.state/` and does not migrate with the
agent; it is rebuilt with the image.

You can still use the vault without the MCP — the agent has native `Read`, `Write`, `Edit`,
`Glob`, and `Grep` tools that work on the vault path. The MCP adds frontmatter-aware operations
and structured search; for simple reads and writes, native tools work just as well.

## Hybrid search via QMD (opt-in RAG)

For vaults with hundreds of pages, or when keyword search stops being enough, layer QMD
(https://github.com/tobi/qmd, package `@tobilu/qmd`) on top. QMD is a local search engine for
Markdown with **BM25 + vector + LLM-rerank** combined via Reciprocal Rank Fusion. It runs
entirely on-device and exposes an MCP server so Claude can use it as a tool alongside MCPVault.

Since feature 010 (and its local-mode parity in 012/013) the whole QMD pipeline is
**launcher-managed**: you enable it, and setup, indexing, embedding and re-indexing happen on
their own in both deployment modes. There is nothing to run by hand.

### Enable it

At scaffold, answer `y` to:

```
▸ Knowledge vault
  Enable QMD hybrid search (BM25+vector+rerank, ~300MB embedding model on first use)? [y/N]
```

Or, later, in `agent.yml` (QMD requires **both** `vault.enabled` and `vault.qmd.enabled`):

```yaml
vault:
  enabled: true
  qmd:
    enabled: true
    version: "2.5.3"        # pinned — see the upgrade checklist before bumping
    schedule: "*/5 * * * *" # reindex backstop cadence
```

Then regenerate and restart (see "After editing `agent.yml`" above).

### What runs on your behalf

| Stage | What happens | Where |
|---|---|---|
| **Setup** (once) | `qmd_setup_if_needed`: `collection add <vault> --name vault --mask '**/*.md'` → `update` → `embed`. Downloads the ~300 MB embedding model on first `embed`. Idempotent via a sentinel + `index.sqlite`; `flock`-guarded against the reindex. | docker: backgrounded by `start_services.sh` at every boot. local: dispatched by `agent-login.sh` and re-checked at the start of every reindex tick. |
| **Reindex** | `qmd_reindex`: hash-debounced (`vault_hash`) + `flock`-guarded; runs `update` then the embed-completion loop. Always exits 0 (a cron tick must never crash) — honesty lives in the state file. | docker: cron backstop (`vault.qmd.schedule`, default `*/5 * * * *`) + the inotify watcher `qmd_watch.sh`. local: `agent-<name>-qmd-reindex.timer` (cron converted to `OnCalendar`) + `agent-<name>-qmd-watch.service`. |
| **Watch** | inotify on the vault, debounced (~15s), dispatches the same `qmd-reindex`. Captures every change regardless of source (MCPVault, native `Write`, Syncthing). Degrades to the cron/timer backstop when `inotifywait` is unavailable. | docker: respawned by the 2s watchdog. local: `Restart=always` systemd service with a supervised loop. |
| **Manual** | `./scripts/agentctl heartbeat qmd-reindex` (both modes; in-container it is `heartbeatctl qmd-reindex`). `--dry-run` works in docker mode only — the local wrapper has none, so it is refused (exit 2) rather than silently running a real reindex. | |

State: `scripts/heartbeat/qmd-index.json` — `{hash, last_run, last_status, runs[, pending]}`,
with `last_status ∈ {indexed, skipped, error, partial, stalled}`. Full schema and semantics in
[`docs/heartbeatctl.md`](heartbeatctl.md#vault-rag).

### How qmd is invoked (no `bunx`)

`bunx @tobilu/qmd@... ` is **retired** — do not run it by hand. `bunx` lets Bun run every
transitive dependency's install script, which on Alpine musl aborts the whole install on
`tree-sitter-*` (BUG 4). Instead, `scripts/lib/qmd_index.sh` maintains a **managed bun-install
prefix**:

- `<qmd cache root>/pkg/` holds a `package.json` pinning `@tobilu/qmd` with
  `trustedDependencies: ["better-sqlite3", "node-llama-cpp"]` — so those two compile and
  `tree-sitter-*` stay unbuilt (qmd uses the `web-tree-sitter` WASM grammar at runtime).
- Install is idempotent by manifest hash; the one-time native build gets its own timeout budget.
- Batch commands (`update`, `embed`, `status`) run from `pkg/node_modules/.bin/qmd`.
- Docker mode only: `embed` (and the MCP server) preload `bigstack.so`, an 8 MB-stack pthread
  shim for musl's 128 KB default stack.

### The `qmd` MCP entry

When `vault.qmd.enabled` is true, `.mcp.json` gains a `qmd` server whose `command` is a
**per-mode wrapper** and whose `args` are empty — never `bunx`:

```json
"qmd": {
  "command": "<wrapper>",
  "args": [],
  "env": { }
}
```

| Mode | `command` (`{{QMD_MCP_COMMAND}}`) | `env` (`{{QMD_MCP_ENV}}`) |
|---|---|---|
| docker | `/opt/agent-admin/scripts/qmd-mcp` (image-baked) | `{}` — `$HOME/.cache/qmd` resolves via the bind-mount |
| local | `<workspace>/scripts/local/agent-qmd-mcp.sh` (rendered) | `XDG_CACHE_HOME` + `QMD_CONFIG_DIR` under `<workspace>/.state` |

Both wrappers call `qmd_index.sh::qmd_mcp_exec`, which execs `qmd mcp` from the **same managed
prefix and the same storage** as the reindex writer. That symmetry is load-bearing: point the
reader at a different prefix or a different `index.sqlite` and RAG silently returns nothing.

### Storage and cost

| Path | docker (container) | local (host) | What |
|---|---|---|---|
| index | `~/.cache/qmd/index.sqlite` | `<ws>/.state/.cache/qmd/index.sqlite` | FTS5 + vector index. Grows with vault content. |
| models | `~/.cache/qmd/models/` | `<ws>/.state/.cache/qmd/models/` | Downloaded embedding model, ~300 MB. One-time per agent. |
| managed prefix | `~/.cache/qmd/pkg/` | `<ws>/.state/.cache/qmd/pkg/` | The pinned qmd install + its compiled native deps (016). |
| collections config | qmd default under `$HOME` | `<ws>/.state/.config/qmd/` | Which folders are indexed. |
| lock + sentinel | `~/.cache/qmd/{.reindex.lock,.qmd-setup-ok}` | same, under `.state` | Serializes setup ↔ reindex; marks setup done. |

Docker mode: everything under `~/.cache/` lands in `<workspace>/.state/.cache/` via the
bind-mount, so it persists across container restarts and rebuilds and migrates with the agent
via `rsync`. Local mode reaches the identical host paths by explicit env in the rendered
wrappers (`XDG_CACHE_HOME`, `QMD_CONFIG_DIR`, `QMD_CACHE_HOME`) — the qmd binary honors
`XDG_CACHE_HOME` and `QMD_CONFIG_DIR`; `QMD_CACHE_HOME` is read only by the bash lib.

### Embed completion on large vaults (feature 018)

A single `qmd embed` runs inside an engine session hard-capped at ~30 minutes. On a large
first-time corpus that pass dies with "LLM session expired", leaving part of the vault without
vectors — and, before 018, the unchanged-vault guard then skipped embedding forever.

As of v0.12.0 the reindex runs **successive fresh embed passes inside one locked invocation**
until qmd reports full coverage, a pass makes no forward progress, or a fixed pass cap
(`QMD_EMBED_MAX_PASSES`, 12 — a constant, deliberately not an `agent.yml` field) is reached. The
outcome is recorded in `qmd-index.json`:

- `indexed` + `pending: 0` — complete.
- `partial` / `stalled` + `pending > 0` — the vector index is **incomplete**; the next tick
  *resumes* embedding (an unchanged vault only skips when it is also fully embedded).
- `error` — the pass failed or timed out; the previous hash is kept so the next tick re-runs
  `update` from scratch.

Reference detail: [`docs/heartbeatctl.md`](heartbeatctl.md#vault-rag).

### Vector search on Alpine musl (feature 017, docker mode only)

qmd's transitive `sqlite-vec` prebuilt is glibc-only and cannot `dlopen` under musl. In docker
mode the image compiles the pinned sqlite-vec amalgamation for musl at build time (gated by the
`QMD_NATIVE_TOOLCHAIN=1` build arg) and `_qmd_swap_sqlite_vec` swaps it into the managed prefix
at runtime. If that artifact is missing (e.g. an image built with `QMD_NATIVE_TOOLCHAIN=0`), the
log says `vector embed unavailable, lexical index intact` — BM25 still works, vectors don't.
Local mode runs on glibc: the stock prebuilt loads and the swap is a no-op.

### Version pin and upgrades

`vault.qmd.version` (`2.5.3`) is the single source of the pin — `qmd_index.sh::qmd_pkg` reads it
from `agent.yml`. It is a **guardrail**, not a preference: 016/017/018 depend on qmd's dependency
graph (tree-sitter as optional deps), its transitive sqlite-vec version (0.1.9, paired with the
baked musl build), and the exact CLI strings the embed loop parses. Never bump it casually —
work through [`docs/qmd-upgrade-checklist.md`](qmd-upgrade-checklist.md) first.

### When to enable QMD

- Vault grew past ~100 sources and `Glob`/`Grep` over `wiki/` is hitting friction.
- You want semantic queries ("find pages about distributed consensus") over keyword search.
- You want LLM-reranked results (more relevant, less noisy) for ambiguous queries.

When **not** to enable:

- Small vaults (<50 sources) — keyword search via MCPVault `search_notes` is faster and
  doesn't carry the ~300 MB model overhead.
- Air-gapped environments where the model download isn't possible.
- Agents that mostly write to the vault and rarely query it.

QMD and MCPVault are complementary: MCPVault is for read/write/list operations on individual
notes, QMD is for retrieval-style search across the corpus. Both registered together is the
common case for a mature vault. The exact tool names the `qmd` MCP server registers come from
the pinned package — check them at runtime with `/mcp` inside the session (or
`./scripts/agentctl mcp list` in docker mode) rather than trusting a list here.

## Ops surface

| | docker | local |
|---|---|---|
| Status | `./scripts/agentctl status` → `heartbeatctl status`: heartbeat + the `vault backup` line. QMD/wiki-graph state: read `scripts/heartbeat/{qmd-index,wiki-graph}.json`. | `./scripts/agentctl status` adds a `vault/RAG:` block: reindex timer, watcher, index present, last reindex + `last_status`, backup timer, wiki-graph timer + counts, schedule-fallback markers |
| Diagnostics | `./scripts/agentctl doctor`: vault skeleton seeded + vault-backup freshness | `./scripts/agentctl doctor`: the above plus qmd index/reindex health and wiki-graph findings + runner liveness |
| Kill switch | — | `./scripts/local/agent-killswitch.sh` — also stops the qmd reindex timer, the watcher, the vault-backup timer, the wiki-graph timer and the healthcheck |

`agentctl doctor` exits `0` (clean), `1` (warnings — e.g. a stale vault backup, or in local mode
an incomplete index / wiki-graph findings) or `2` (failures — e.g. a dead runner), so it composes
with `agentctl doctor || alert`.

## Browsing the vault from your computer

The vault is a normal Obsidian vault on disk, plus a `_templates/` directory that Obsidian
will treat as a regular folder. To open it in Obsidian:

1. Obsidian → Open vault as folder → pick `<workspace>/.state/.vault/` (same host path in both
   deployment modes).
2. Optional: enable Obsidian's graph view for Layer 2 navigation (the wikilinks `[[type/title]]`
   render natively).
3. Optional: enable the Dataview plugin in Obsidian to query the wiki by frontmatter
   (`type`, `tags`, `status`, `updated`).

You don't need Obsidian for the agent to function — file access works without it. Obsidian
is for human browsing and editing.

## Why no slash-command "skill"

The plan considered shipping a `vault-ops` skill with `/vault:ingest`, `/vault:query`,
`/vault:lint` commands. We didn't add it because:

- This repo doesn't have an existing pattern for workspace-local Claude Code skills (the
  related infrastructure is plugins like `superpowers` that ship their own skill framework).
- The protocols already live in the vault's `CLAUDE.md` (the Layer 3 schema), which the agent
  reads when working with the vault. Natural-language prompts ("ingest this URL", "what does
  the wiki say about X") work as well as slash commands.
- Slash commands could be added later as a separate plugin if the friction shows up in
  practice.

## Troubleshooting

### The vault wasn't seeded

Check `agent.yml`:

```bash
yq '.vault' agent.yml
# Expected:
# enabled: true
# seed_skeleton: true
```

**Docker mode** — if both are true and the dir is still empty, check `docker compose logs` for
`WARN: seed_vault_if_needed failed`. Common causes:

- The skeleton wasn't COPYd into the image:
  `./scripts/agentctl run ls /opt/agent-admin/modules/vault-skeleton/` should show `CLAUDE.md`.
  If not, rebuild (`docker compose build`) — the COPY happens at build time.
- The vault dir wasn't empty (the seed only runs on an empty target). Delete its contents to
  re-seed: `./scripts/agentctl run sh -c 'rm -rf /home/agent/.vault/* /home/agent/.vault/.[!.]*'`
  then `./scripts/agentctl restart`.

**Local mode** — seeding happens host-side during `./setup.sh` / `--regenerate`, so re-run
`./setup.sh --regenerate` and read its output (it prints `vault skeleton ready` with the
resolved path). The skeleton is read from `modules/vault-skeleton/` in the *launcher* clone.

### The `vault` MCP server isn't listed

```bash
./scripts/agentctl mcp list        # docker mode
# local mode: /mcp inside the session
```

If `vault` is missing, check:

```bash
yq '.vault.mcp.enabled' agent.yml         # should be true
jq '.mcpServers.vault' .mcp.json          # should be a non-null object
```

If `agent.yml` is true but `.mcp.json` has no entry, run `./setup.sh --regenerate`, then restart
(docker: `./scripts/agentctl restart`; local: `sudo systemctl restart agent-<name>.service`) so
Claude reloads `.mcp.json`.

### MCPVault fails to start

- No network: the container has full outbound; check with
  `./scripts/agentctl run curl -s -o /dev/null -w '%{http_code}\n' https://registry.npmjs.org/`.
- Docker mode: the package is pre-warmed into `/opt/npm-cache` at build time. That cache is baked
  into the image and owned by the agent's UID/GID (`chown -R ${UID}:${GID} /opt/npm-cache` in
  `docker/Dockerfile`), so the agent can read it — and can delete it. But a `rm -rf` inside a
  running container only touches that container's writable layer: the image layer still holds the
  cache, and the deletion is undone the moment the container is recreated. To clear it *durably*,
  rebuild the image (`docker compose build`).
- The MCPVault version is **pinned**, and the pin is single-sourced in
  `scripts/lib/versions.sh` (`AGENTIC_FLOOR_MCP_VAULT`). Two mirrors read from it:
  `modules/mcp-json.tpl` and `ARG MCP_VAULT_VERSION` in `docker/Dockerfile`. A bump means all
  three, then `--regenerate` and rebuild — never `@latest`. Two bats drift-guards fail if the
  mirrors and the floor disagree (`tests/versions.bats`, `tests/modules-render.bats`).

### The symlink `~/vault → ~/.vault` is missing (docker mode)

`seed_vault_if_needed` creates the symlink at boot **only when nothing exists at
`/home/agent/vault`** — it never replaces an existing one, so a symlink left pointing at a
previous `vault.path` survives untouched. A missing symlink is therefore fixed by a restart; a
stale one has to be removed first. To (re)create it manually:

```bash
./scripts/agentctl run sh -c 'ln -sfn /home/agent/.vault /home/agent/vault'
```

Local mode has no symlink by design — the vault is at its real workspace path.

### QMD: the index looks empty / search returns nothing

1. Read the state file: `jq . scripts/heartbeat/qmd-index.json`.
   - `last_status: indexed`, `pending: 0` → the index is complete; the problem is elsewhere.
   - `partial` / `stalled` with `pending > 0` → the vector index is incomplete. Let the next
     tick resume, or force one: `./scripts/agentctl heartbeat qmd-reindex`.
   - `error` → read the reindex log (docker: `scripts/heartbeat/logs/qmd-reindex.log`; local:
     `journalctl -u agent-<name>-qmd-reindex.service`). The library logs a redacted tail of the
     real qmd stderr, including a failed native build.
2. Confirm the reader and the writer share storage: in local mode both the reindex wrapper and
   `scripts/local/agent-qmd-mcp.sh` must export the same `XDG_CACHE_HOME` / `QMD_CONFIG_DIR` /
   `QMD_CACHE_HOME`. Re-render them with `./setup.sh --regenerate` if in doubt.
3. Docker mode: `vector embed unavailable, lexical index intact` in the log means the musl
   sqlite-vec artifact is missing — rebuild the image with `QMD_NATIVE_TOOLCHAIN=1` (the
   default).

Never "fix" this by running `bunx @tobilu/qmd ...` by hand: it builds a *different* install than
the managed prefix and re-triggers the tree-sitter build that BUG 4 was about.

### Upgrading the skeleton (`force_reseed`)

`modules/vault-skeleton/` evolves over time — new templates, new schema rules in `CLAUDE.md`,
new sections in `index.md`. Two mechanisms:

- **Additive (default, safe)**: `vault_seed_missing` adds only the new structures on the next
  boot (docker) / `--regenerate` (local). Never overwrites, never touches the vault's own
  `CLAUDE.md`. Nothing to enable.
- **Full re-seed (destructive-ish)**: set the flag in `agent.yml` when you want the skeleton
  back to pristine:

```yaml
vault:
  ...
  force_reseed: true
```

Then restart (docker) or `./setup.sh --regenerate` (local). On the next seed pass:

1. The entire vault is moved to `<vault>.backup-YYYY-MM-DD-HHMMSS/`.
2. The vault is re-seeded from the bundled skeleton.
3. **`vault.force_reseed` is reset to `false` in `agent.yml`** so the next boot is a no-op (no
   recurring re-seed on every restart).

The backup is preserved indefinitely so you can recover anything from the old vault:

```bash
# copy a specific page back from the backup (docker mode)
./scripts/agentctl run sh -c '
  cp ~/.vault.backup-2026-04-29-153000/wiki/concepts/my-page.md \
     ~/.vault/wiki/concepts/
'
```

Or pull whole subdirectories with `cp -R` (in local mode, plain host `cp`). When you're
satisfied that nothing was lost, the backup can be deleted.

**Caveats:**

- Docker mode: the reset is written by the `agent` user via `yq -i` — the same pattern
  `heartbeatctl set-*` uses for in-place mutations. If the reset fails (extremely rare), a `WARN`
  lands in the container log and you must reset the flag manually; the re-seed itself completes
  either way.
- `raw_sources/` is part of the seed; it gets backed up too. If you've ingested many sources you
  don't want to re-seed onto a fresh `raw_sources/`, copy them out of the backup before deleting
  it.
- A full re-seed changes every file → the next QMD reindex re-embeds the corpus and the next
  vault backup pushes a full new tree.

### Removing the vault

```bash
# 1. Disable the feature in agent.yml.
yq -i '.vault.enabled = false | .vault.mcp.enabled = false | .vault.qmd.enabled = false' agent.yml

# 2. Re-render (drops the MCP entries, the cron lines / systemd timers).
./setup.sh --regenerate

# 3. Restart.
./scripts/agentctl restart                       # docker
sudo systemctl restart agent-<name>.service      # local

# 4. Drop the data (optional).
rm -rf .state/.vault .state/.cache/qmd
```

To re-enable later: flip the flags back, regenerate, restart. The seed runs again because the
vault dir is empty, and QMD rebuilds its index from scratch.

## See also

- [`docs/heartbeatctl.md`](heartbeatctl.md#vault-rag) — reference for `qmd-reindex`,
  `wiki-graph`, `backup-vault`, the `qmd-index.json` schema and the embed-completion loop.
- [`docs/qmd-upgrade-checklist.md`](qmd-upgrade-checklist.md) — everything to verify before
  bumping `vault.qmd.version`.
- [`docs/state-layout.md`](state-layout.md) — every persistent path in the agent, including
  the vault and the QMD cache.
- [`docs/architecture.md`](architecture.md) — container/local architecture, render engine,
  lifecycle phases, the three backup branches.
- `modules/vault-skeleton/CLAUDE.md` (in this repo, copied into each agent's vault) — the
  authoritative schema document the LLM follows when working with the vault.
- Karpathy's gist: https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f
- MCPVault upstream: https://github.com/bitbonsai/mcpvault
