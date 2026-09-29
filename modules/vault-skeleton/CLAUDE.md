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

## Actionability (PARA)

On top of the six page **types** (what a page IS), every page carries an optional `para:`
frontmatter key that says how **actionable** it is right now, following Tiago Forte's PARA
method (Projects / Areas / Resources / Archives):

| `para` | Meaning |
|---|---|
| `project` | A goal with a deadline you are actively driving. Lives on an `entity` page. |
| `area` | A standard to maintain indefinitely, no deadline. Lives on an `overview` page. |
| `resource` | Reference material you may need again. No deadline, no standard to hold. |
| `archive` | Inactive — a closed project or a resource you no longer act on. |

`para` **absent means `resource`** — most pages in a knowledge base are reference material,
not open loops, and that should be the default, not something you have to declare.

PARA lives entirely in frontmatter. It is never a folder: the six-type directory a page lives
in (`wiki/entities/`, `wiki/overviews/`, etc.) never changes when `para` changes. Archiving a
page never moves the file and never touches `status:` — `status` tracks freshness
(`draft`/`active`/`stale`/`superseded`), `para` tracks actionability; they are independent
axes.

**Auxiliary keys** (see the extended frontmatter below for full validation rules):

| Key | When to set it |
|---|---|
| `goal` | On every `para: project` page — the outcome you're driving toward. |
| `due` | On every `para: project` page — the target date. |
| `next_action` | On every `para: project` page — the next concrete step (Hemingway Bridge). |
| `next_review` | On a `para: project` page after every kickoff or review. Optional on `para: area`. |
| `standard` | On a `para: area` page — the bar you're holding, not a deadline. |
| `cadence` | On a `para: area` page — how often you check on it, in your own words. |
| `archived` | On every `para: archive` page — the date it was closed or shelved. |
| `project` / `area` | On any page that feeds a project or area — links it into that page's queue. |
| `problems` | On any page that answers a favorite problem — see "Favorite problems" below. |
| `packet` | On a page that is a reusable Intermediate Packet — see "Intermediate packets" below. |

**Project state lives in one place.** The project page in `wiki/entities/` is the single home
of project state — `goal`, `due`, `next_action`, `next_review`, the outline, the log of
decisions. If an auto-memory pointer (`project_<slug>.md`) exists for the same project, it
stays a 2–3 line pointer (one-sentence status, a wikilink to the project page, the last review
date) and carries no further state of its own — never duplicate `due`/`next_action` there.

Changing `para`, or any other frontmatter key, re-indexes and re-embeds that page on the next
tick regardless — the search index hashes the whole file, frontmatter included. So there is no
separate rule here about bumping `updated:` "because you changed para" — bump it when the
content actually changed, exactly as you already do.

**Views in `index.md`.** Five sections track actionability across the vault:

- `## Projects (active)` — one line per `para: project` page, format
  `- [[entities/<slug>]] — <goal>, due <due>`.
- `## Areas` — one line per `para: area` page, format `- [[overviews/<slug>]] — <standard>`.
- `## Archive` — one line per `para: archive` page, format
  `- [[<type>/<slug>]] — archived <archived>`.
- `## Packets` — see "Intermediate packets" below.
- Favorite problems view — see the "Favorite problems" section below.

## Normalization rules (`wiki/normalization/`)

Separate from the six knowledge types, `wiki/normalization/` holds **writing rules**, not
knowledge. Each page declares a `canonical` form and the `aliases` (mis-spellings,
transcription errors) that should resolve to it — e.g. canonical `Cencosud`, aliases
`[SENCOSUD, Sencosud]`. See `_templates/normalization.md` for the frontmatter. These pages
are NOT nodes in the six-type system and are never cited as knowledge; they steer how you
WRITE layer-2 pages and are checked by the deterministic linter (below).

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

### Extended frontmatter (037)

On top of the block above, any page may also carry:

```yaml
para: project | area | resource | archive   # optional; absent = resource
archived: YYYY-MM-DD        # required when para: archive
goal: ""                    # para: project
due: YYYY-MM-DD             # para: project
next_action: ""             # para: project
next_review: YYYY-MM-DD     # para: project (optional on area)
standard: ""                # para: area
cadence: ""                 # para: area
project: ""                 # wikilink to the project page this page contributes to
area: ""                    # wikilink to the area page this page contributes to
problems: []                # favorite-problem slugs this page answers, e.g. [fp-3]
packet: distilled-note | outtake | wip | deliverable | external
distill: 1                  # 1-4, see below
description: ""             # one line, see below
```

`description` is **required on every page created from now on** — one line, plain prose, no
wikilinks needed. It is the hook that goes into `index.md` and the unit of "distill on read":
when you're short on time, read `description`s before bodies. There is no requirement to
retrofit existing pages.

`distill` records how far a page has gone through Progressive Summarization:

1. Full note — the source material, lightly organized.
2. Bolded — the load-bearing sentences are **bold**.
3. Highlighted — of the bold, the few that matter most are highlighted.
4. Executive summary — a `description`-length synthesis sits at the top of the page.

Raise `distill` only when you are already touching the page for another reason — never run a
distillation pass over the vault. Most pages stay at layer 1 forever, and that is fine.

## Wikilinks

Use `[[<type>/<title>]]` form, with title slugified (lowercase, dashes for spaces). Examples:

- `[[entities/anthropic]]`
- `[[concepts/prompt-caching]]`
- `[[summaries/karpathy-llm-wiki]]`

Backlinks are not maintained automatically. If you add a link from A to B, also add the
reverse in B's `related:` array if it's load-bearing.

## Operation: project kickoff

When the human says "start a project on `<topic>`" or you decide a cluster of open questions
deserves project-level tracking:

0. **Decisional — the human sets the direction.** Propose a `goal` and a `due` date; don't
   invent them. If the human hasn't given you both, ask before creating the page.
1. **Create or complete the project page** at `wiki/entities/<slug>.md` from
   `_templates/entity-project.md`, with `para: project`, `goal`, `due`, `next_action`,
   `next_review = today + review.project_days` (see `.graph/policy.json`; default 7 days),
   and `description`.
2. **Read `.graph/packets.json`** and list any Intermediate Packet whose `description`
   suggests it's reusable for this project. Mention them in the page's `## Packets` section
   instead of redoing the work.
3. **Search related pages** by name, tags and text across the wiki and link the load-bearing
   ones from the project page's outline.
4. **Add the reciprocal edge.** For every page you linked from the project page, add
   `[[entities/<slug>]]` to that page's own `related:` array — the edge should be visible
   from both sides.
5. **Write the outline** as an archipelago of wikilinks — a short map of the pages that
   matter to this project, not a restatement of their content.
6. **Add the page to `## Projects (active)`** in `index.md`.
7. **Create or reduce the auto-memory pointer** `project_<slug>.md` to the pointer form (see
   "What goes here vs. other memory layers" below) — the project page in the vault is the
   single home of project state.
8. **Append to `log.md`**: `## [YYYY-MM-DD] project-open | <slug> — <n> packets reused`.

## Operation: project close

When the human says a project is done, or you notice its `due` has long passed with no open
loop left:

0. **Decisional — the human decides whether to close.** Propose it; don't close a project
   unilaterally. If closing, propose the one-line outcome text too.
1. **Set `para: archive`** and `archived: today` on the project page. Refresh `updated:` —
   the page changed. Optionally add one outcome line to the body.
2. **Extract reusable packets.** For any page produced by this project that's worth reusing
   elsewhere, set `packet:` to the type that fits.
3. **Move the `index.md` entry** from `## Projects (active)` to `## Archive`.
4. **Reduce the auto-memory pointer** to "closed on `<date>`" — no further state.
5. **Append to `log.md`**: `## [YYYY-MM-DD] project-close | <slug> — <outcome>`.

Prohibitions: never move or delete the page's file; never change `status:` as part of a
close — `status` tracks freshness, not actionability, and closing a project doesn't make its
content stale.

## Operation: ingest

When the human says "ingest <url|file|note>" or attaches a new source:

0. **If you're handling a chat-driven request (Telegram, etc.), ack first.** Send a one-line preview with a realistic estimate — e.g. `Ingest en curso de <fuente>, ~5–10 min. Te aviso al terminar.` — then proceed with the steps below. A typical ingest touches 5–15 pages over several minutes; without an ack the user has no signal that the request landed. Optionally send one mid-progress reply when you cross a clear phase boundary (e.g. after step 1, "Source clipeada → escribiendo concepts ahora"). Don't spam: max 1 mid-progress per ingest.

**Step 0.5 — capture filter.** Before clipping, decide where this source belongs:

- If `wiki/synthesis/favorite-problems.md` exists, match the source against the problems it
  lists. Set `problems:` on the pages you create or update for it. Treat any inferred fit as
  a **candidate** — say "this seems to feed fp-3", never claim resonance you felt.
- Match the source against active projects (`para: project`). If it feeds one, set
  `project:` on the pages you create or update.
- If nothing active seems to need it, **ask the human** before ingesting: "nothing active
  seems to need this — ingest anyway, file as resource, or skip?"
- **Two-source rule.** A new `concept` page needs two cited sources to justify its own page.
  With only one, extend an existing `summary` page instead of creating a concept.

1. **Clip the source.** Save it under `raw_sources/` with a slugified filename. If the source
   has a natural type (article, paper, transcript, gist), use a subdirectory. Add minimal
   frontmatter (see `_templates/source.md`). **Never modify the source content again.**
2. **Write a summary page.** Create `wiki/summaries/<slug>.md` from `_templates/summary.md`.
   Capture the source's main thesis, key claims, examples, caveats. Link to the raw source via
   the `sources:` array.
2.5. **Normalize terminology.** Read `wiki/normalization/` (or the `canonical_of` map in
   `.graph/backlinks.json` if fresh). Write EVERY layer-2 page — this summary and all pages
   below — using canonical forms; keep the raw source VERBATIM (layer 1 is immutable). If the
   source contains a recurring mis-transcription not yet declared (e.g. `SENCOSUD` for
   `Cencosud`), propose creating a `wiki/normalization/` page for it.
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

**Step 0 — read the map first.**

0. **If this is the first message of the conversation**, and `.graph/findings.json` shows
   `review_due` or `pending_ingest` greater than zero, offer to walk through the queue before
   addressing the question — propose it, don't act on anything without confirmation.
1. Read `.graph/policy.json` for cadences and thresholds; if it's absent, use the defaults:
   review every 7 days for projects, 30 for areas, 90 days without activity before an archive
   candidate, 14 days before a stale delta nags you, 30 days before a favorite problem is
   unfed, 300 pages before `index.md` stops being read in full.
2. Read the `overview` pages of the domain (a two-level map of the territory) and the
   `## Projects (active)`/`## Areas` sections of `index.md` relevant to the question. If the
   question names an active project, read that project's page in full.
3. Read `index.md` in full **only if** `counts.nodes` in `wiki-graph.json` is below
   `thresholds.index_first_max_pages` — past that, treat `index.md` as a section-level index,
   not a page you read cover to cover every time.
4. **Then** run hybrid search (`qmd`), then expand via the graph (backlinks, 1-hop), as below.
5. `raw_sources/` is not in the search collection — when the question needs the raw text
   itself, use `Grep` or `search_notes` directly on `raw_sources/`, not hybrid search.
6. Archived pages (`para: archive`) are cited only when the question asks about the past or
   names them explicitly — they don't surface in the default map.

**Then work the question:**

1. **Expand via the graph.** After locating seed pages (Step 0), read
   `.graph/backlinks.json` and pull their 1-hop neighbors — `backlinks`, `related_out`,
   `co_sourced` (pages citing the same source) and `canonical_of` (aliases resolving here) —
   before synthesizing. A variant mention (e.g. `SENCOSUD`) resolves to the canonical page via
   `canonical_of`. Cite the neighbor pages you actually used. (The graph is regenerated on a
   schedule and by `agentctl heartbeat wiki-graph`; if `.graph/` is absent or stale, fall back
   to plain search.)
2. **Read the relevant pages end-to-end.** Don't quote chunks out of context.
3. **Cite.** When you assert something from the wiki, link the page: `[[concepts/foo]]`. When
   you cite a raw source, give its path: `raw_sources/articles/foo.md`.
4. **Synthesize, don't paste.** The answer should be a fresh composition for the question
   asked, drawing on the wiki rather than reciting it.
5. **File good answers back.** If the synthesis is non-trivial and likely to be useful
   again, propose creating a new wiki page (often `overview` or `synthesis`). Don't
   auto-create — ask the human first to avoid noise.
6. **Append to `log.md`.** Format: `## [YYYY-MM-DD] query | <question summary>`.

## Operation: weekly review

Triggered by the human, or by the opt-in weekly notice (see the launcher's heartbeat docs)
that tells you the queue is non-empty:

1. **Read `.graph/findings.json`.** Pull `pending_ingest` (your inbox of unsummarized raw
   sources), `project_overdue` + `project_incomplete` (open loops), and `review_due`
   (projects whose review date has come or was never set).
2. **For each `review_due` project**, propose a `next_action` and set
   `next_review = today + review.project_days`.
3. **Produce at most three recommendations** — don't try to fix everything the queue lists
   in one pass. Do not review every project every week — only what the queue lists; a project
   not in `review_due` doesn't need your attention this week.
4. **Decisional (the human).** Changing dates, closing a project (see "Operation: project
   close"), or ignoring an item are all valid outcomes — propose, don't decide.
5. **Append to `log.md`**: `## [YYYY-MM-DD] review | weekly — <n> due, <m> ingested, <k>
   loops`.

## Operation: monthly review

A slower pass, once a month is usually enough:

1. **Areas.** For each `para: area` page, compare the current state against its `standard`
   and any `cadence` you're tracking. This is not a deadline — it's a check on whether the
   standard is still being held.
2. **Archive candidates.** Read `archive_candidate` in `findings.json` and list **at most
   three**, each with its evidence (`backlinks: 0`, `last log mention`) — don't dump the
   whole list on the human.
3. **Summarize outcomes** of any projects closed this month (via "Operation: project
   close").
4. **Append to `log.md`**: `## [YYYY-MM-DD] review | monthly — <n> areas, <m> archive
   candidates, <k> closed`.

Decisional (the human): whether to archive a candidate (always via "Operation: project
close" or the equivalent for a resource — never move the file directly), and whether to
adjust a cadence. Resistance to reviewing an area on schedule is itself feedback — if the
human keeps deferring it, the cadence is probably wrong, not the human.

## Filing policy

When a query produces a synthesis that cites **three or more pages**, propose filing it as a
new wiki page — pick the type that fits (`overview`, `synthesis`, `concept` or `comparison`)
and, if the result is reusable beyond this one answer, a `packet:` value too. This is a
proposal, not an automatic action — ask before creating the page.

Log every such query to `log.md`, whether or not it got filed, so the filing rate stays
measurable: `## [YYYY-MM-DD] query | <question summary> | filed: yes|no`.

## Session close (Hemingway Bridge)

Every session that touched a project page ends the same way, regardless of what else
happened in it: update `next_action` on the project page to the concrete next step — never
leave it stale for the next session to rediscover — and append one line to `log.md`:
`## [YYYY-MM-DD] session | <slug> — next: <next_action>`.

This is the Hemingway Bridge: stop mid-thought, on purpose, with the next step already
written down, so the next session (yours or the human's) starts moving instead of
re-orienting.

## Operation: maintaining the wiki (lint)

Run periodically (and before any "wiki health" check from the human).

> A **deterministic linter** already runs on a schedule (and on demand via
> `agentctl heartbeat wiki-graph`). It covers the STRUCTURAL dimension without an LLM —
> orphans, broken wikilinks, frontmatter violations, `index.md` drift, stale pages and
> alias occurrences — and writes `.graph/findings.json` (read counts with
> `jq .findings .graph/findings.json`, or `agentctl status`). It NEVER edits the wiki; you
> apply the fixes. So the agentic lint below focuses on what a script can't judge:
> SEMANTIC contradictions between pages and genuinely missing pages.

0. **If chat-driven, ack first.** Send `Lint del vault en curso, ~2–5 min según tamaño. Te paso el reporte al terminar.` then proceed.

Detect:

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

## Intermediate packets

An Intermediate Packet is any unit of work you produced along the way that's worth reusing
without redoing the thinking. Set `packet:` to one of:

- `distilled-note` — a page already taken through Progressive Summarization (see `distill`
  above).
- `outtake` — a good excerpt or quote pulled out during research, not yet a full page.
- `wip` — a work-in-progress outline or draft, usable as a starting point.
- `deliverable` — a finished artifact (a report, a written answer) worth citing again.
- `external` — something produced outside the vault (a doc, a slide deck) that this page
  points to.

Set `packet:` on the page's **natural type** — a distilled note is still a `concept` or a
`summary`, it doesn't move anywhere. Never create a `packets/` directory; packets are a
frontmatter classification, not a location. `synthesis` pages stay rare regardless of how
many packets exist — most reuse happens at the concept/summary level.

`index.md`'s `## Packets` section lists every page with a valid `packet:` value. Project
kickoff (above) reads `.graph/packets.json` before starting from scratch.

## Favorite problems

Following Richard Hamming's advice to keep a short list of the problems that matter most to
you and actively work them into everything you read: `wiki/synthesis/favorite-problems.md`
is created **when the human declares their problems** — never pre-created, never seeded by a
script. Once it exists:

- Entries are numbered, one per line: `1. **fp-1** — How should PARA review cadences adapt
  over time?` — always phrased as a question.
- **Maximum twelve.** A longer list stops being a filter.
- Slugs (`fp-1`, `fp-2`, ...) are stable — a retired entry leaves its number unused rather
  than renumbering the rest.
- Link it from the Favorite problems view in `index.md`, and from the root `overview` page
  if one exists.
- Any page that answers or advances a favorite problem sets `problems: [fp-N]` in its
  frontmatter (see the capture filter step above).

`problem_unfed` in `findings.json` is the signal that a favorite problem has gone N days
(default 30) without a single page feeding it — a sign the filter isn't actually being
applied during ingest, not that the problem stopped mattering.

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
- Project state → vault project page (single home); auto-memory keeps the pointer.

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
