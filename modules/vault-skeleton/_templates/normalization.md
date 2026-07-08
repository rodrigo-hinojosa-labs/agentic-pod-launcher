---
canonical: ""
aliases: []
match_case: false
entity: ""
notes: ""
---

# Normalization rule: {{canonical}}

> A normalization rule declares a CANONICAL form and the ALIASES (mis-spellings,
> transcription errors, variant casings) that should resolve to it. It is NOT a
> knowledge page — it is a WRITING rule the agent consults during ingest and the
> deterministic linter reports on. It lives OUTSIDE the six knowledge types.

## Frontmatter

- `canonical` (required, non-empty): the correct form. Example: `Cencosud`.
- `aliases` (required, non-empty list): variants to correct. Example:
  `[SENCOSUD, Sencosud, CENCOSUD S.A.]`.
- `match_case` (optional, default `false`): when `true`, aliases match
  case-sensitively.
- `entity` (optional): a `[[entities/...]]` wikilink to the canonical entity, if
  one exists. The graph models `alias → canonical` so a variant mention resolves
  to that entity.
- `notes` (optional): scope — when the rule applies, when it doesn't.

## How it is used

- **Ingest**: before writing any layer-2 page, the agent reads `wiki/normalization/`
  and writes canonical forms. The raw source stays VERBATIM (layer 1 is immutable).
- **Lint**: the runner scans wiki bodies for known aliases and reports each as an
  `alias_occurrence` finding (informational — the agent corrects, no script edits
  the wiki). Aliases inside `[[wikilinks]]` and fenced code blocks are not counted.
