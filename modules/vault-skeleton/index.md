# Vault index

Catalog of every page in `wiki/`. Updated by the LLM on each ingest, query, or lint that
produces a new page. One line per page: `- [[<type>/<title>]] — short one-line hook`.

This file lives at the vault root, alongside `log.md` and `CLAUDE.md`. It is **content-oriented**
(what the wiki contains), in contrast to `log.md` which is **time-oriented** (what happened
when).

If `index.md` and the actual filesystem disagree, the filesystem wins. Run `lint` to surface
the drift.

---

## Summaries

<!-- One entry per ingested source. Format: `- [[summaries/<slug>]] — 1-line hook` -->

## Entities

<!-- Concrete things: people, products, tools, projects, places. -->

## Concepts

<!-- Abstract ideas: frameworks, principles, definitions. -->

## Comparisons

<!-- X vs Y: tradeoffs, decision criteria, when-to-use-which. -->

## Overviews

<!-- High-level synthesis of a domain spanning multiple pages. -->

## Synthesis

<!-- Cross-cutting integration of multiple overviews/concepts. The wiki's meta-pages. -->
