---
name: ticket
description: Generate a well-structured Jira ticket (title, context, description, acceptance criteria, technical notes) from a free-form description. Use when asked to create a ticket, a story, or a task.
argument-hint: [description of the work]
---

Generate a Jira ticket from this description:

$ARGUMENTS

Return the ticket in neutral Spanish (Chile), in Markdown ready to copy, with this exact structure:

## Title
One line, imperative, clear and actionable.

## Type
Story, Task, Bug, Spike, or Subtask (pick the most suitable one and justify it in one sentence).

## Context
Why this ticket exists. The underlying problem or need.

## Description
What needs to be done, with enough detail for someone to pick it up without further context.

## Acceptance criteria
A verifiable list of "done" conditions. Each criterion must be objectively markable as met or not.

## Technical notes
Dependencies, risks, assumptions, links, or implementation considerations. Omit the section if not applicable.

## Suggested estimate
A relative estimate (S/M/L or points) with a one-sentence justification.

Rules:
- Do not invent requirements that don't follow from the description. If critical information is missing, list it under "Open questions" at the end.
- No emojis. Professional and concise tone.
