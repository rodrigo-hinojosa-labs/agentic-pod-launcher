# Contract: agent identity render (`CLAUDE.md`) — US1

Governs the `regenerate()` CLAUDE.md render decision in `setup.sh`, driven by the new
`_is_launcher_own_claude_md` discriminator.

## Discriminator

`_is_launcher_own_claude_md FILE` returns success iff FILE contains the launcher sentinel
`This is **the launcher**, not an agent` (the launcher's own `CLAUDE.md` carries it; the agent
template `modules/claude-md.tpl` never emits it). Pure content check; no mtime; no interactive
input.

## Render decision

**Given** a workspace whose `CLAUDE.md` is the launcher's own dev doc (fresh clone),
**When** `./setup.sh --non-interactive` (or `--regenerate`) runs with no TTY,
**Then** `CLAUDE.md` is re-rendered from `modules/claude-md.tpl` (contains the agent's
`## Identity` + `Name:`/`Role:` from `agent.yml`; the launcher sentinel is gone), with no prompt.

**Given** a workspace whose `CLAUDE.md` is a genuine operator-edited agent doc (no sentinel),
**When** `--regenerate` runs (without `--force-claude-md`),
**Then** `CLAUDE.md` is preserved byte-for-byte (FR-002).

**Given** a workspace with no `CLAUDE.md`,
**When** the render runs,
**Then** `CLAUDE.md` is rendered from the template (unchanged from today's behavior).

**Given** the interactive wizard path,
**When** an agent is scaffolded,
**Then** CLAUDE.md generation is unchanged (FR-013).

## Mutation check (SC-007)

Reverting the discriminator (or removing it from the render condition) makes the
launcher-doc-clone case fall back to `preserved` → the "agent has its own identity" test fails.
