# Schema updates — launcher 0.27.0 (feature 037: Second Brain sobre el LLM Wiki)

> **For the agent**: this file was deposited into `_templates/` by the additive vault
> upgrade because your vault predates launcher 0.27.0. Integrate the sections below into
> THIS vault's `CLAUDE.md` (the upgrade never edits `CLAUDE.md` itself — it is your
> co-evolved layer-3 schema). Integration is **manual** and entirely additive: nothing
> below asks you to rewrite something that already works. Once integrated, you may delete
> this file; the upgrade will not re-deposit it (the sentinel is the hidden marker
> `_templates/.schema-updates-0.27.0.applied`, not this file).
>
> `schema_delta_pending` will keep appearing in `.graph/findings.json` — with a growing day
> count — until the literal heading `## Actionability (PARA)` is present in this vault's
> `CLAUDE.md`. That's the only integration checkpoint the runner can see; the rest of this
> file's content is for you and the human, not for a script.

This delta adds actionability (Tiago Forte's PARA method — Projects / Areas / Resources /
Archives) on top of your existing six page types, plus intermediate packets, favorite
problems, and a small set of new operations. Add the following to your `CLAUDE.md`.

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

## Migration: project_* memory files

For each `project_*.md` you already have in auto-memory: create or complete the
corresponding vault project page (kickoff, without re-deciding `goal`/`due` — copy them as
they already stand), then reduce the memory file to the pointer form described above ("What
goes here vs. other memory layers"). Do this migration in the next session that touches that
project, one project per turn if there are many — don't batch them all into a single
sitting. Log a `project-open` entry for each one you migrate.

## Also update these existing sections

The pieces above are new sections. These are small patches to sections you already have.

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

### Query protocol — add `Step 0 — read the map first`

Insert this before your existing "answering questions" steps (before what is today's step
1, "Search the wiki first"):

> **Step 0 — read the map first.**
>
> 0. **If this is the first message of the conversation**, and `.graph/findings.json` shows
>    `review_due` or `pending_ingest` greater than zero, offer to walk through the queue
>    before addressing the question — propose it, don't act on anything without confirmation.
> 1. Read `.graph/policy.json` for cadences and thresholds; if it's absent, use the
>    defaults: review every 7 days for projects, 30 for areas, 90 days without activity
>    before an archive candidate, 14 days before a stale delta nags you, 30 days before a
>    favorite problem is unfed, 300 pages before `index.md` stops being read in full.
> 2. Read the `overview` pages of the domain (a two-level map of the territory) and the
>    `## Projects (active)`/`## Areas` sections of `index.md` relevant to the question. If
>    the question names an active project, read that project's page in full.
> 3. Read `index.md` in full **only if** `counts.nodes` in `wiki-graph.json` is below
>    `thresholds.index_first_max_pages` — past that, treat `index.md` as a section-level
>    index, not a page you read cover to cover every time.
> 4. **Then** run hybrid search (`qmd`), then expand via the graph (backlinks, 1-hop), as
>    you already do.
> 5. `raw_sources/` is not in the search collection — when the question needs the raw
>    text itself, use `Grep` or `search_notes` directly on `raw_sources/`, not hybrid
>    search.
> 6. Archived pages (`para: archive`) are cited only when the question asks about the
>    past or names them explicitly — they don't surface in the default map.

### Ingest protocol — add `Step 0.5 — capture filter`

Insert this between your ack step and your clip step (before what is today's step 1,
"Clip the source"):

> **Step 0.5 — capture filter.** Before clipping, decide where this source belongs:
>
> - If `wiki/synthesis/favorite-problems.md` exists, match the source against the
>   problems it lists. Set `problems:` on the pages you create or update for it. Treat
>   any inferred fit as a **candidate** — say "this seems to feed fp-3", never claim
>   resonance you felt.
> - Match the source against active projects (`para: project`). If it feeds one, set
>   `project:` on the pages you create or update.
> - If nothing active seems to need it, **ask the human** before ingesting: "nothing
>   active seems to need this — ingest anyway, file as resource, or skip?"
> - **Two-source rule.** A new `concept` page needs two cited sources to justify its own
>   page. With only one, extend an existing `summary` page instead of creating a concept.

### index.md — add five new sections

```markdown
## Projects (active)

<!-- One entry per `para: project` page. Format:
     `- [[entities/<slug>]] — <goal>, due <due>` -->

## Areas

<!-- One entry per `para: area` page. Format:
     `- [[overviews/<slug>]] — <standard>` -->

## Archive

<!-- One entry per `para: archive` page. Format:
     `- [[<type>/<slug>]] — archived <archived>` -->

## Packets

<!-- One entry per page with a valid `packet:` value. Format:
     `- [[<type>/<slug>]] — <packet> — <description>` -->

## Favorite problems

<!-- Link to `wiki/synthesis/favorite-problems.md` once it exists. Never seeded. Format:
     `- [[synthesis/favorite-problems]] — the current list` -->
```

### What goes here vs. other memory layers — add a row

Add this row to the heuristics list in that section: "Project state → vault project page
(single home); auto-memory keeps the pointer."

### log.md — update the format line

Update the format line of your `log.md` to:

```
## [YYYY-MM-DD] {ingest|query|lint|init|upgrade|project-open|project-close|review|session|other} | <short title>
```
