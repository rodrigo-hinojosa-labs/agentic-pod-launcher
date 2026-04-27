# Raw sources — Layer 1

This directory holds **immutable source material**: articles, papers, transcripts, gists,
data files, screenshots. The LLM reads from here but never edits these files. They are the
source of truth that the wiki (in `../wiki/`) summarizes and synthesizes.

## What goes in here

- Web articles clipped to Markdown (e.g., via Obsidian Web Clipper).
- Academic papers (PDF or extracted text).
- Meeting transcripts.
- Gist-style snippets the human shared.
- Reference docs from external systems.
- Screenshots and images, kept alongside the page that cites them.

## What does NOT go in here

- LLM-generated content of any kind. That's the wiki, not a source.
- Mutable working notes. Those go in the wiki as `summary` or `concept` pages.
- Configuration. That's the schema (`../CLAUDE.md`).

## Optional subdirectories

Flat `raw_sources/` works fine up to roughly 50 sources. Beyond that, organize by type:

- `articles/` — web articles, blog posts.
- `papers/` — academic papers.
- `transcripts/` — meeting notes, call transcripts.
- `data/` — datasets, exports, structured input.
- `images/` — figures, screenshots, diagrams.

Move existing sources into subdirectories only when the flat layout starts to hurt navigation.
Premature subdivision wastes effort.

## Naming

- Slugified, kebab-case, lowercase: `karpathy-llm-wiki.md`, not `Karpathy LLM Wiki.md`.
- No dates in filenames; the source's own publication date goes in frontmatter.
- Append a discriminator if titles collide: `obsidian-mcp-cyanheads.md` vs.
  `obsidian-mcp-pfundstein.md`.

## Frontmatter for sources

Each text-based source carries minimal frontmatter (see `../_templates/source.md`):

```yaml
---
title: ""
url: ""              # original URL or DOI; empty for offline-only material
author: ""
published: YYYY-MM-DD  # source's own date, not the date you clipped it
clipped: YYYY-MM-DD    # the date you added it to the vault
type: article | paper | transcript | gist | data | image
---
```

For binaries (PDFs, images), keep the file as-is and add a sibling `<filename>.md` with the
frontmatter and any extracted text.

## Once a source is in here

The wiki maintainer (the LLM) is expected to:

1. Write a `summary` page in `../wiki/summaries/`.
2. Create or update entity / concept pages this source touches.
3. Update `../index.md`.
4. Append to `../log.md`.

See `../CLAUDE.md` § "Operation: ingest" for the full protocol.
