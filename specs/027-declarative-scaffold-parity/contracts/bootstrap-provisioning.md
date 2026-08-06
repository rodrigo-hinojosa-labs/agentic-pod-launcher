# Contract: runtime provisioner (`agent-bootstrap.sh`) — US2 + US3

The rendered provisioner's observable contract is its `BOOTSTRAP_DRY_RUN=1` plan output plus its
real install commands. These are the host-testable assertions (no network).

## US2 — bun provisioning gate

**Given** a workspace `.mcp.json` whose command set includes a QMD wrapper command
(`…/scripts/local/agent-qmd-mcp.sh`) and no literal `bunx`,
**When** `BOOTSTRAP_DRY_RUN=1 agent-bootstrap.sh` runs,
**Then** the output contains a `PLAN bun …` line.

**Given** a workspace `.mcp.json` with NO qmd wrapper and no `bunx`,
**When** the dry-run runs,
**Then** the output contains NO `PLAN bun` line.

**Given** a workspace `.mcp.json` with a literal `bunx` command (docker-style / legacy),
**When** the dry-run runs,
**Then** the output still contains `PLAN bun …` (no regression to the existing trigger).

## US3 — uvx MCP version pins

**Given** a workspace `.mcp.json` warming `mcp-server-fetch`, `mcp-server-git`, `mcp-atlassian`,
**When** the dry-run runs,
**Then** each warmed tool's plan line carries the pinned version and the `mcp` lib pin, e.g.
`PLAN uv-tool mcp-server-fetch==<AGENTIC_FLOOR_MCP_FETCH> (mcp==<AGENTIC_FLOOR_MCP_LIB>)` — the
versions match `versions.sh`, never "latest"/unpinned.

**Real-install form** (not asserted in the no-network dry-run; verified on a live host):
`uv tool install [--python python3] mcp-server-fetch==<pin> --with mcp==<lib-pin>` (and likewise
for git/atlassian), producing servers that `claude mcp list` reports Connected.

## Invariants (both)

- The provisioner still exits `0` and warns-and-continues on any failed optional install
  (FR-016); a bad pin/download never blocks `--login`.
- With `BOOTSTRAP_DRY_RUN=1`, nothing is downloaded or installed.
- Mutation check (SC-007): reverting the US2 trigger drops the `PLAN bun` line for a qmd workspace;
  reverting the US3 pins drops the `==<ver>`/`mcp==` from the plan lines. Each is caught by ≥1 test.
