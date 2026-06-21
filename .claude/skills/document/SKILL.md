---
name: document
description: Generate or improve technical documentation for a module, function, API, flow, or decision. Use when asked to document code, write a README, or produce technical documentation.
argument-hint: [what to document: file, module, topic]
allowed-tools: Read, Grep, Glob
---

Document the following:

$ARGUMENTS

If it refers to project code or files, read them first so you document on the real basis, not an assumed one.

Structure in neutral Spanish (Chile), Markdown, scannable:

## Purpose and scope
What it is and what it is for, in one or two sentences.

## Description
How it works. Components, responsibilities, main flow.

## Usage / examples
Executable code blocks or concrete examples where applicable.

## Decisions and assumptions
The relevant "why": design decisions, trade-offs, assumptions. Omit if not applicable.

## References and pending items
Links, dependencies, TODOs. Omit if not applicable.

Rules:
- Document only what you can verify by reading the code or the source. Do not invent behavior.
- Include the why, not just the what.
- No emojis. Clear and reusable.
