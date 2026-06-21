---
name: journal
description: Create a traceable journal entry from the work done. Use to record progress, learnings, and pending items from a session or workday.
argument-hint: [what was done / context]
allowed-tools: Bash(date *), Bash(git status *)
---

Today's context: !`date +%Y-%m-%d`

Create a journal entry from this:

$ARGUMENTS

If the description is brief and there are recent changes in the repository, consider them as input (summary of uncommitted changes):

!`git status --short 2>/dev/null`

Format in neutral Spanish (Chile), Markdown, ready to paste into a journal:

## [date] — [short title]

**Context:** what was being done and why.

**Done:** concrete actions taken, in bullets.

**Learnings:** findings, decisions, what worked or didn't. Omit if not applicable.

**Pending:** what's left to do, in actionable bullets.

Rules:
- Concise and traceable: it should be useful when consulted later.
- Do not invent actions that don't follow from the description or the repo state.
- No emojis.
