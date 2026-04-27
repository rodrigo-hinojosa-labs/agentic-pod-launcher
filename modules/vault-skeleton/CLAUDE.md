# Vault — Karpathy LLM Wiki

This is your **knowledge vault**. It follows the three-layer pattern from Andrej Karpathy's
"LLM Wiki" gist (https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f).

You — the LLM — are the wiki maintainer. The human curates sources and asks questions; you
do the bookkeeping.

## The three layers

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
> when ingesting sources, answering questions, or maintaining the wiki."*  — Karpathy

In this vault:

- `raw_sources/` is Layer 1 — **never edit files here**. Only read them and link to them.
- `wiki/` is Layer 2 — you own everything inside. Create, edit, link, refactor freely.
- This file (`CLAUDE.md`) is Layer 3 — the schema. You and the human co-evolve it.
- `_templates/` holds boilerplate you read when creating new pages. Not part of the wiki.
- `index.md` and `log.md` live at the vault root. See sections below.

## Page types (the only six)

Every file under `wiki/<type>/` must have `type:` in its frontmatter set to one of:

| `type` | Subdirectory | Purpose |
|---|---|---|
| `summary` | `wiki/summaries/` | One per ingested raw source. Captures the source's argument, claims, examples. |
| `entity` | `wiki/entities/` | A concrete thing — person, product, tool, project, place, organization. |
| `concept` | `wiki/concepts/` | An abstract idea — framework, principle, definition, theory. |
| `comparison` | `wiki/comparisons/` | X vs Y. Tradeoffs, when-to-use-which, decision criteria. |
| `overview` | `wiki/overviews/` | High-level synthesis of a domain or topic spanning multiple pages. |
| `synthesis` | `wiki/synthesis/` | Cross-cutting integration of multiple overviews/concepts. The wiki's meta-pages. |

No other types. If something doesn't fit, the right move is usually to make it a `concept`
or to extend an existing page, not to invent a new type.

## Frontmatter spec

Every page in `wiki/` starts with this YAML block (no exceptions):

```yaml
---
title: ""
type: summary | entity | concept | comparison | overview | synthesis
sources: []          # paths relative to vault root, e.g. ["raw_sources/papers/karpathy-llm-wiki.md"]
related: []          # wikilinks to other pages, e.g. ["[[concepts/llm-wiki-pattern]]"]
created: YYYY-MM-DD
updated: YYYY-MM-DD
status: draft | active | stale | superseded
tags: []
---
```

Raw sources in `raw_sources/` use a smaller frontmatter (see `_templates/source.md`).

## Wikilinks

Use `[[<type>/<title>]]` form, with title slugified (lowercase, dashes for spaces). Examples:

- `[[entities/anthropic]]`
- `[[concepts/prompt-caching]]`
- `[[summaries/karpathy-llm-wiki]]`

Backlinks are not maintained automatically. If you add a link from A to B, also add the
reverse in B's `related:` array if it's load-bearing.

## Operation: ingest

When the human says "ingest <url|file|note>" or attaches a new source:

1. **Clip the source.** Save it under `raw_sources/` with a slugified filename. If the source
   has a natural type (article, paper, transcript, gist), use a subdirectory. Add minimal
   frontmatter (see `_templates/source.md`). **Never modify the source content again.**
2. **Write a summary page.** Create `wiki/summaries/<slug>.md` from `_templates/summary.md`.
   Capture the source's main thesis, key claims, examples, caveats. Link to the raw source via
   the `sources:` array.
3. **Identify load-bearing entities and concepts.** For each one not yet in the wiki, create
   the page. For each one already there, update it: add the new claim, link the new summary,
   bump `updated:`, refine `status:` if the new source supersedes a prior one.
4. **Maintain cross-references.** If the source compares two existing entities/concepts, that
   often warrants a `comparison` page. If it integrates several existing overviews into a
   higher view, consider whether a new `synthesis` page is warranted (these should be rare).
5. **Update `index.md`.** Add one line per new page under the corresponding section.
6. **Append to `log.md`.** Format: `## [YYYY-MM-DD] ingest | <source title>`.

A single ingest typically touches 5–15 wiki pages. That's normal — the LLM doesn't get bored.

## Operation: answering questions (query)

When the human asks a question:

1. **Search the wiki first.** Use `search_notes`, `Glob`, or `Grep` over `wiki/`. Prefer pages
   with `status: active` and recent `updated:` dates.
2. **Read the relevant pages end-to-end.** Don't quote chunks out of context.
3. **Cite.** When you assert something from the wiki, link the page: `[[concepts/foo]]`. When
   you cite a raw source, give its path: `raw_sources/articles/foo.md`.
4. **Synthesize, don't paste.** The answer should be a fresh composition for the question
   asked, drawing on the wiki rather than reciting it.
5. **File good answers back.** If the synthesis is non-trivial and likely to be useful again,
   propose creating a new wiki page (often `overview` or `synthesis`). Don't auto-create —
   ask the human first to avoid noise.
6. **Append to `log.md`.** Format: `## [YYYY-MM-DD] query | <question summary>`.

## Operation: maintaining the wiki (lint)

Run periodically (and before any "wiki health" check from the human). Detect:

- **Contradictions** — two pages making incompatible claims about the same thing. Surface to
  the human; resolution is usually a curation choice.
- **Orphans** — pages with no inbound `[[wikilinks]]`. May indicate a missing parent overview
  or a page that no longer earns its place. Don't auto-delete.
- **Stale claims** — page `updated:` predates its newest source by a long gap, or `status:`
  still `active` but the topic has been superseded by newer sources.
- **Missing cross-refs** — entity/concept mentioned in body text but not in `related:`.
- **Important concepts without their own page** — a term appears across many summaries but
  has no `wiki/concepts/<term>.md`. Propose creating it.

Output a lint report under `wiki/synthesis/lint-<date>.md` (treat it as a synthesis page).
Don't make destructive changes during lint — surface findings, let the human decide.

Append to `log.md`: `## [YYYY-MM-DD] lint | <count> findings`.

## What goes here vs. other memory layers

The agent has three persistent memory layers. Use the right one:

| Layer | Use it for |
|---|---|
| **Auto-memoria** (`~/.claude/projects/-workspace/memory/`) | Single-fact memories about the user, their preferences, ongoing project state. Tiny, atomic, indexed by `MEMORY.md`. |
| **claude-mem** (SQLite, `~/.claude-mem/`) | Auto-captured observations from transcripts. You don't write here directly; the worker does. Query via `mem-search`, `smart_search`, `timeline`. |
| **This vault** (`~/.vault/`) | Curated, synthetic, compounding knowledge derived from external sources. Pages you'll revisit, refine, link, and lint. |

Heuristics:

- "Save this fact about the user" → auto-memoria (e.g., language preference, role, tools).
- "Remember what we did last week" → claude-mem (transcript-derived).
- "Build me a knowledge base on X" → this vault.

If unsure, ask. Don't double-write across layers.

## Maintenance triggers

Run `lint` when:

- After ingesting 5+ new sources in a single sitting.
- Before producing a synthesis page that depends on many concepts.
- When the human asks "how's the wiki doing?" or similar.
- Periodically — once a month is usually enough for a small wiki.

Keep `index.md` updated on every ingest and on every page rename or move. A stale index is
worse than no index.

## File naming

- Slugified, kebab-case: `karpathy-llm-wiki.md`, not `Karpathy LLM Wiki.md`.
- No dates in filenames except for `lint-YYYY-MM-DD.md` and similar dated artifacts.
- One topic per file. If a page exceeds ~500 lines, split it.

## When you're not sure

- If the human asks a question you can answer without the wiki, answer it. Don't force vault
  use when it doesn't add value.
- If a page is wrong, fix it. Don't leave incorrect claims standing because "they were there
  before".
- If you can't decide between two structures, pick the simpler one and note the alternative
  in the page body. The human will tell you when to refactor.
