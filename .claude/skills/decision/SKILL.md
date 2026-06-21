---
name: decision
description: Write an architecture decision record (ADR) from a technical decision and its context. Use when a relevant decision is made that is worth documenting.
argument-hint: [decision and context]
---

Write an ADR (Architecture Decision Record) for this decision:

$ARGUMENTS

Format in neutral Spanish (Chile), Markdown, ready to save as a file in `docs/adr/`:

# ADR-NNN: [decision title]

## Status
Proposed | Accepted | Superseded | Deprecated (choose; default "Proposed").

## Context
The situation and the forces at play: requirements, constraints, problem to solve.

## Decision
What was decided, expressed clearly and affirmatively.

## Alternatives considered
Each option evaluated with its pros and cons, and why it was discarded.

## Consequences
Positive and negative effects of the decision. Technical debt or trade-offs taken on. What becomes easier and what becomes harder.

## References
Links, tickets, related documents. Omit if not applicable.

Rules:
- Be honest about the trade-offs: a decision with no downsides is poorly analyzed.
- Do not invent filler alternatives; include the ones actually considered.
- No emojis. Precise and traceable.
