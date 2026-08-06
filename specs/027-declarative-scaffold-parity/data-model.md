# Data Model: Declarative Local-Scaffold Parity

This feature changes render/provisioning behavior; it introduces no persistent data store.
The "entities" are configuration records and rendered artifacts.

## Version pin record (`scripts/lib/versions.sh`)

New shell variables, following the existing `AGENTIC_FLOOR_MCP_*` convention:

| Variable | Purpose | Reference value (mclaren-validated) |
|---|---|---|
| `AGENTIC_FLOOR_MCP_FETCH` | pinned `mcp-server-fetch` version | `2026.6.4` |
| `AGENTIC_FLOOR_MCP_GIT` | pinned `mcp-server-git` version | `2026.6.16` |
| `AGENTIC_FLOOR_MCP_ATLASSIAN` | pinned `mcp-atlassian` version | `0.21.1` (confirm at implement) |
| `AGENTIC_FLOOR_MCP_LIB` | pinned `mcp` protocol library | `1.28.1` |

- **Validation rule**: the four values MUST form a mutually-compatible set — a clean-env install
  of each server with `--with mcp==$AGENTIC_FLOOR_MCP_LIB` must yield a server that connects.
  If `mcp-atlassian` cannot share `AGENTIC_FLOOR_MCP_LIB`, a per-server `mcp` override is recorded
  alongside its pin (the provisioner map accommodates it).
- **Single source**: these live only in `versions.sh`; the rendered provisioner receives them via
  render-time injection (it cannot source launcher libs at runtime).

## Rendered provisioner (`scripts/local/agent-bootstrap.sh`, from `modules/local-bootstrap.sh.tpl`)

Behavioral record — inputs and the decisions it makes:

- **Input**: the agent's `.mcp.json` command set (`$cmds`) + the injected version pins.
- **bun decision (US2)**: provision `bun`/`bunx` iff `$cmds` contains `bunx` **or** a command
  referencing `agent-qmd-mcp.sh` (the QMD wrapper). Otherwise skip.
- **uvx-tool decision (US3)**: for each warmed uvx package (`mcp-server-fetch`, `mcp-server-git`,
  `mcp-atlassian`), install `pkg==<pin>` with `--with mcp==<lib-pin>` (per-server `mcp` override
  if recorded).
- **Dry-run projection (`BOOTSTRAP_DRY_RUN=1`)**: emits one `PLAN …` line per action, including
  `PLAN bun …` when bun is decided and `PLAN uv-tool <pkg>==<ver> (mcp==<lib>)` per warmed tool —
  the host-testable surface (no network).
- **Invariant**: still exits 0, warn-and-continue on any failed optional install (FR-016).

## Rendered agent `CLAUDE.md` (from `modules/claude-md.tpl`)

- **State transition (US1)**: on `regenerate()`, the workspace `CLAUDE.md` moves to the *rendered
  agent doc* when it is (a) absent, (b) `--force-claude-md` accepted, or (c) detected as the
  launcher's own doc (contains the sentinel `This is **the launcher**, not an agent`). It is
  *preserved* when it is a genuine operator doc (sentinel absent) and neither (a) nor (b) holds.
- **Discriminator (`_is_launcher_own_claude_md`)**: pure content check on the sentinel; no mtime,
  no interactive input; deterministic.

## Rendered `NEXT_STEPS.md` (from `modules/next-steps.{es,en}.tpl`)

- **State transition (US4)**: produced (overwritten) on every `regenerate()` /
  `--non-interactive` / `--regenerate`, selected by `user.language`, with `{{PLUGINS_BLOCK}}`
  injected. Pure derived guidance file — not user-owned, always safe to re-render.
- **Fields consumed**: `agent.display_name`, `deployment.workspace`, `deployment.mode`,
  `agent.name`, `plugins[]` — all from `agent.yml`.
