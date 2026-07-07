# Schema updates — launcher 0.8.0 (feature 014: wiki-graph-rag)

> **For the agent**: this file was deposited into `_templates/` by the additive vault
> upgrade because your vault predates launcher 0.8.0. Integrate the sections below into
> THIS vault's `CLAUDE.md` (the upgrade never edits `CLAUDE.md` itself — it is your
> co-evolved layer-3 schema). Once integrated, you may delete this file; the upgrade will
> not re-deposit it (the sentinel is a hidden marker, not this file).

Two new things exist in this vault as of 0.8.0:

1. A `wiki/normalization/` folder (writing rules).
2. A derived `.graph/` directory (regenerated on a schedule and by
   `agentctl heartbeat wiki-graph`) with `graph.json`, `backlinks.json`, `findings.json`.

Add the following to your `CLAUDE.md`.

## New section: Normalization rules (`wiki/normalization/`)

Separate from the six knowledge types, `wiki/normalization/` holds **writing rules**, not
knowledge. Each page declares a `canonical` form and the `aliases` (mis-spellings,
transcription errors) that resolve to it — e.g. canonical `Cencosud`, aliases
`[SENCOSUD, Sencosud]`. See `_templates/normalization.md` for the frontmatter. These pages
are NOT nodes in the six-type system and are never cited as knowledge.

## Ingest protocol — add step 2.5

After writing the summary page and before identifying entities/concepts:

> **2.5. Normalize terminology.** Read `wiki/normalization/` (or the `canonical_of` map in
> `.graph/backlinks.json`). Write EVERY layer-2 page using canonical forms; keep the raw
> source VERBATIM (layer 1 is immutable). If the source has a recurring mis-transcription
> not yet declared, propose creating a `wiki/normalization/` page for it.

## Query protocol — add a graph-expansion step

After locating seed pages and before synthesizing:

> **Expand via the graph.** Read `.graph/backlinks.json` and pull the seed pages' 1-hop
> neighbors — `backlinks`, `related_out`, `co_sourced`, `canonical_of` — before
> synthesizing. A variant mention resolves to its canonical page via `canonical_of`. Cite
> the neighbors you used. If `.graph/` is absent or stale, fall back to plain search.

## Lint protocol — note the deterministic linter

A deterministic linter now runs on a schedule (and on demand via
`agentctl heartbeat wiki-graph`). It covers the STRUCTURAL dimension without an LLM —
orphans, broken wikilinks, frontmatter violations, `index.md` drift, stale pages, alias
occurrences — and writes `.graph/findings.json`. It NEVER edits the wiki; you apply fixes.
Your agentic lint now focuses on SEMANTIC contradictions and genuinely missing pages.

## index.md — add a Normalization section

```markdown
## Normalization

<!-- Canonical-form rules. Format: `- [[normalization/<slug>]] — <canonical> <- <aliases>` -->
```
