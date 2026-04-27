# Vault — per-agent Karpathy LLM Wiki

The vault is a per-agent, file-based knowledge base following Andrej Karpathy's "LLM Wiki"
pattern (https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f). It coexists with
the agent's two other memory layers (auto-memoria and claude-mem) and serves a different
role: **curated, synthetic, compounding knowledge derived from external sources**.

This page is for the human running the agent. The agent's own instructions for using the vault
live in the vault's own `CLAUDE.md` (at `~/.vault/CLAUDE.md` inside the container) — that file
is authoritative for vault conventions and is co-evolved between the human and the LLM.

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
  `summaries/`, `entities/`, `concepts/`, `comparisons/`, `overviews/`, `synthesis/`.
- **Layer 3 — `CLAUDE.md`**: Schema. Defines frontmatter spec, wikilink format, and the
  protocols for ingest / query / lint operations. Co-evolved by you and the LLM.

Plus two root files Karpathy calls out:

- `index.md` — content-oriented catalog (one entry per wiki page, organized by type).
- `log.md` — chronological append-only record of every operation, parseable with
  `grep "^## \[" log.md | tail -N`.

## Where it lives

| Host | Container |
|---|---|
| `<workspace>/.state/.vault/` | `/home/agent/.vault/` (real path) |
| (same dir) | `/home/agent/vault/` → symlink to `/home/agent/.vault/` (convenience alias) |

The vault inherits the workspace's `.state/` bind-mount — no extra Docker volume. It is
per-agent, portable via `rsync` (the same migration command that copies the rest of the
agent's state). It is immune to `docker compose down -v` (no Docker-managed volumes) and
preserved across `setup.sh --uninstall --yes`. Only `--purge` or `--nuke` removes it.

The convenience symlink `~/vault → ~/.vault` exists so docs and prompts can use the
shorter path without confusing duplicate state. The MCP server config and skill instructions
target the real path (`~/.vault`) to avoid symlink ambiguity in tools that resolve paths.

## Lifecycle

### At scaffold (`./setup.sh`)

The wizard's "▸ Knowledge vault" section asks three opt-in questions (defaults yes):

1. **Enable knowledge vault?** — toggles `vault.enabled`.
2. **Seed initial vault structure?** — toggles `vault.seed_skeleton`. Copies
   `modules/vault-skeleton/` into the per-agent vault on first boot.
3. **Register MCPVault server?** — toggles `vault.mcp.enabled`. Adds a `vault` server entry
   to `.mcp.json` so Claude has structured tools (`read_note`, `write_note`, `search_notes`,
   etc.) for the vault on top of file-system access.

Answers go to the `vault:` block in `agent.yml`:

```yaml
vault:
  enabled: true
  path: .state/.vault
  seed_skeleton: true
  initial_sources: []
  mcp:
    enabled: true
    server: vault
  schema:
    frontmatter_required: true
    log_format: "## [{date}] {op} | {title}"
```

### At first container boot

`docker/scripts/start_services.sh::seed_vault_if_needed` runs as the `agent` user during
`boot_side_effects`:

1. Reads `vault.enabled` from `agent.yml`. No-op if false.
2. Resolves the in-container path. Default `.state/.vault` maps to `/home/agent/.vault/`.
3. `vault_ensure_paths` — `mkdir -p` the vault root with agent ownership.
4. If `vault.seed_skeleton` is true and the vault is empty: `vault_seed_if_empty` rsyncs
   `/opt/agent-admin/modules/vault-skeleton/` into the vault and replaces the
   `SCAFFOLD_DATE` placeholder in `log.md` with today's date. Idempotent — no-op once seeded.
5. Creates the convenience symlink `/home/agent/vault → /home/agent/.vault` if missing.

### Day-to-day

The agent reads `~/.vault/CLAUDE.md` to know how to handle the vault. When you ask it to
ingest a source, query a topic, or lint the wiki, it follows the protocols defined in that
schema document. See "Operations" below for what each one does.

### After editing `agent.yml`

Toggling `vault.enabled` or `vault.mcp.enabled` requires re-rendering `.mcp.json` so the
MCP server entry appears or disappears:

```bash
cd ~/agents/my-agent
./setup.sh --regenerate
docker compose restart  # restart so the new .mcp.json is picked up by Claude
```

The vault's content is never re-rendered — once seeded, it belongs to the LLM.

## Operations

The agent invokes these via the protocols documented in `~/.vault/CLAUDE.md`. There are no
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

1. Searches the wiki (file tools or MCPVault's `search_notes`).
2. Reads relevant pages end-to-end.
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
surfaces findings for you to act on.

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
~/.vault/                              (host: <workspace>/.state/.vault/)
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
│   └── synthesis/                     cross-cutting integration; meta-pages
│
├── _templates/                        operational boilerplate (NOT wiki content)
│   ├── source.md, summary.md, entity.md, concept.md
│   ├── comparison.md, overview.md, synthesis.md
│
├── index.md                           catalog by type (LLM updates on every change)
├── log.md                             chronological append-only
├── CLAUDE.md                          Layer 3 schema (authoritative)
└── .obsidian/                         Obsidian config (empty at scaffold; user-owned)
```

## MCP integration (MCPVault)

When `vault.mcp.enabled` is true, `.mcp.json` includes a `vault` server entry:

```json
"vault": {
  "command": "npx",
  "args": ["-y", "@bitbonsai/mcpvault@latest", "/home/agent/.vault"],
  "env": {}
}
```

The package is `@bitbonsai/mcpvault` (https://github.com/bitbonsai/mcpvault). It's a
zero-dependency MCP server that accesses vault files directly — it does NOT require the
Obsidian app to be running, which makes it suitable for the headless container. The server
exposes 14 tools: `read_note`, `write_note`, `patch_note`, `delete_note`, `move_note`,
`move_file`, `list_directory`, `read_multiple_notes`, `search_notes`, `get_frontmatter`,
`update_frontmatter`, `get_notes_info`, `get_vault_stats`, `manage_tags`.

`npx` caches the package under `/home/agent/.npm/` (also bind-mounted via `.state/.npm/`).
The first invocation downloads; subsequent invocations are cache hits.

You can still use the vault without the MCP — the agent has native `Read`, `Write`, `Edit`,
`Glob`, and `Grep` tools that work on any path under `/home/agent/`. The MCP adds
frontmatter-aware operations and structured search; for simple reads and writes, native
tools work just as well.

## Browsing the vault from your computer

The vault is a normal Obsidian vault on disk, plus a `_templates/` directory that Obsidian
will treat as a regular folder. To open it in Obsidian:

1. Obsidian → Open vault as folder → pick `<workspace>/.state/.vault/`.
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
- The protocols already live in `~/.vault/CLAUDE.md` (the Layer 3 schema), which the agent
  reads when working with the vault. Natural-language prompts ("ingest this URL", "what does
  the wiki say about X") work as well as slash commands.
- Slash commands could be added later as a separate plugin if the friction shows up in
  practice.

## Troubleshooting

### The vault wasn't seeded on first boot

Check `agent.yml`:

```bash
yq '.vault' agent.yml
# Expected:
# enabled: true
# seed_skeleton: true
```

If both are true and the dir is still empty, check `claude.cron.log` and `docker compose logs`
for `WARN: seed_vault_if_needed failed`. Common causes:

- The skeleton wasn't COPYd into the image: `docker exec -u agent <name> ls /opt/agent-admin/modules/vault-skeleton/` should show `CLAUDE.md`. If not, the image needs a rebuild
  (`docker compose build`) — the COPY happens at build time.
- The vault dir wasn't empty (idempotent: seed only runs on empty target). Delete its
  contents to re-seed: `docker exec -u agent <name> rm -rf /home/agent/.vault/* /home/agent/.vault/.[!.]*`
  then `docker compose restart`.

### The `vault` MCP server isn't listed

```bash
docker exec -u agent <name> claude mcp list
```

If `vault` is missing, check:

```bash
yq '.vault.mcp.enabled' agent.yml         # should be true
jq '.mcpServers.vault' .mcp.json          # should be a non-null object
```

If `agent.yml` is true but `.mcp.json` is empty, run `./setup.sh --regenerate`. Then
`docker compose restart` so Claude reloads `.mcp.json`.

### `npx @bitbonsai/mcpvault@latest` fails inside the container

The package is fetched on first MCP call and cached under `/home/agent/.npm/`. Failure causes:

- No network: the container has full outbound; check via
  `docker exec -u agent <name> curl -s -o /dev/null -w '%{http_code}\n' https://registry.npmjs.org/`.
- npm cache corruption: `docker exec -u agent <name> rm -rf /home/agent/.npm` then restart.
- A new MCPVault version broke compatibility: pin a version in `modules/mcp-json.tpl` by
  replacing `@latest` with `@<version>` and regenerate.

### The symlink `~/vault → ~/.vault` is missing

The symlink is recreated on every container boot by `seed_vault_if_needed`. If it's missing,
restart the container. To create manually inside the container:

```bash
docker exec -u agent <name> sh -c 'ln -sfn /home/agent/.vault /home/agent/vault'
```

### Removing the vault

```bash
# Drop the data while keeping the agent.
docker exec -u agent <name> rm -rf /home/agent/.vault /home/agent/vault

# Disable the feature in agent.yml, then regenerate + restart.
yq -i '.vault.enabled = false | .vault.mcp.enabled = false' agent.yml
./setup.sh --regenerate
docker compose restart
```

To re-enable later: flip the flags back, regenerate, restart. The seed runs again because
the vault dir is empty.

## See also

- [`docs/state-layout.md`](state-layout.md) — every persistent path in the agent, including
  the vault.
- [`docs/architecture.md`](architecture.md) — full container architecture, render engine,
  lifecycle phases.
- `modules/vault-skeleton/CLAUDE.md` (in this repo, copied into each agent's vault) — the
  authoritative schema document the LLM follows when working with the vault.
- Karpathy's gist: https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f
- MCPVault upstream: https://github.com/bitbonsai/mcpvault
