# Feature Specification: macOS bootstrap hardening (MCP + plugin reliability)

**Feature Branch**: `004-macos-bootstrap-hardening`

**Created**: 2026-06-21

**Status**: Draft

**Input**: From-scratch test scaffold of an agent on Docker Desktop macOS (VirtioFS bind-mount) surfaced three independent bootstrap failures that leave the agent partially non-functional even though the container reports `healthy`.

## User Scenarios & Testing *(mandatory)*

The actor throughout is an **operator** scaffolding a brand-new agent on macOS (Docker Desktop) and bringing it up for the first time. "Fully functional" means: every MCP server declared for the agent connects, and every plugin the agent declares installs — with no manual repair steps.

### User Story 1 - npx-based MCPs connect on macOS (Priority: P1)

An operator scaffolds an agent on macOS, builds the image, and brings the container up. The MCP servers that run via the Node package runner (`vault`, `filesystem`, and the GitHub server) must connect, just like the Python-runner ones (`fetch`, `git`, `atlassian`) already do. (`context7` is a Claude **plugin**, not an npx MCP — out of scope here.)

**Why this priority**: Highest impact (four MCP servers down, including the knowledge vault the agent's RAG workflow depends on), lowest risk — the repository already solves the identical problem for the Python tool runner by keeping its cache off the bind-mount. This is the MVP: it restores the bulk of the agent's MCP capability with a localized change.

**Independent Test**: On macOS, scaffold a fresh agent, `docker compose build`, bring it up, and run the agent's MCP listing. `vault` and `filesystem` report connected (they failed before). No manual cache cleanup is required.

**Acceptance Scenarios**:

1. **Given** a freshly scaffolded agent on macOS Docker Desktop, **When** the container boots and an npx-based MCP server starts, **Then** the server connects without `errno -35` / `ENOTEMPTY` / package-runner cache-lock errors.
2. **Given** the agent runs on Linux, **When** the same MCP servers start, **Then** they still connect (no regression).

---

### User Story 2 - Plugins install automatically after login (Priority: P2)

After the operator completes `/login` inside the container, the configured plugins install on their own and the agent becomes usable, with no manual `plugin install` step.

**Why this priority**: Affects every first boot. Today the supervisor retries plugin installation in a narrow window right after the credential file appears, before the authenticated profile is actually operative for installs, then gives up — leaving plugins uninstalled until a human intervenes. High value, but the agent is still partly usable without it (MCPs from US1 matter more), so P2.

**Independent Test**: Scaffold, build, boot, complete `/login`, then wait without any manual action. The declared plugins end up installed (verifiable via the agent's plugin listing) within a bounded time, with no operator `plugin install` command.

**Acceptance Scenarios**:

1. **Given** the operator has just completed `/login`, **When** the supervisor begins installing plugins and the profile is not yet ready, **Then** the supervisor keeps retrying until installation succeeds or a bounded time budget is exhausted — it does not give up after a few sub-second attempts.
2. **Given** plugin installation eventually succeeds, **Then** the channel attaches and no residual install-failure is reported by the diagnostic.

---

### User Story 3 - GitHub MCP uses a maintained server (Priority: P3)

The GitHub MCP server the agent ships with connects and works, instead of relying on a package the registry marks as no longer supported.

**Why this priority**: One MCP server among several, and the fix is the most invasive (changes the server's runtime, not just a cache location). Worth doing for completeness, but lowest urgency.

**Independent Test**: On a fresh scaffold with a valid GitHub token configured, the agent's MCP listing shows the GitHub server connected and a basic GitHub call succeeds.

**Acceptance Scenarios**:

1. **Given** a freshly scaffolded agent with a GitHub token, **When** the GitHub MCP server starts, **Then** it connects without a "no longer supported" / "Permission denied" failure.
2. **Given** an existing agent is regenerated, **Then** the GitHub MCP definition updates to the maintained server and survives `--regenerate`.

### Edge Cases

- **Linux hosts**: the bind-mount cache pathology does not occur on Linux. All three fixes MUST be no-ops or harmless there (no regression to the existing passing behavior).
- **Cache eviction / cold boot**: the default-catalog npx packages are baked warm into the image, so a container re-creation starts from the image's warm cache — no re-download inside the handshake window. A runtime `npx` for a package NOT baked in (a future opt-in MCP) would still download on first use; that case is out of scope for this feature.
- **Offline / restricted network**: if package download genuinely fails (no network), the MCP still fails — but with the real error, not a bind-mount cache-lock error.
- **Plugin install never succeeds**: if the profile never becomes operative (e.g. login abandoned), the widened retry MUST still terminate at its bounded budget and record the failure for the diagnostic, not loop forever.
- **Existing agents**: a regenerate of an already-scaffolded agent MUST pick up the GitHub MCP migration without manual edits.
- **Sibling-package deprecation risk**: `@modelcontextprotocol/server-filesystem` shares the `@modelcontextprotocol/server-*` namespace with the deprecated `server-github`. The plan MUST verify each package it pre-warms is still maintained; any that is deprecated/broken the same way needs the migration treatment (US3 path), not just pre-warming (US1 path).

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The default-catalog npx MCP packages (`vault`, `filesystem`) MUST be pre-installed (warmed) into an image path OUTSIDE the agent's state bind-mount — mirroring the existing uv `/opt` pattern — and the Node package-runner cache MUST likewise live off the bind-mount. Relocating the cache alone is necessary but not sufficient: an empty off-bind-mount cache would still download inside the MCP handshake window.
- **FR-002**: After the fix, npx-based MCP servers (`vault`, `filesystem`) MUST connect on a fresh macOS scaffold from the warm image cache — without downloading inside Claude's MCP handshake window, without hitting the macOS VirtioFS small-file pathology, and with no manual cache cleanup.
- **FR-003**: After the post-login credential flip, the supervisor MUST continue retrying plugin installation, with backoff, until the profile is operative (a plugin install succeeds) OR a bounded time budget of ~120s is exhausted — rather than a few sub-second attempts that race the auth-ready moment.
- **FR-004**: On a successful first boot with `/login` completed, all plugins the agent declares MUST end up installed with no manual operator command.
- **FR-005**: The widened plugin-install retry MUST terminate (never loop unbounded) and, on exhaustion, record the residual failure so the existing diagnostic surfaces it.
- **FR-006**: The GitHub MCP server MUST be GitHub's official `github-mcp-server` (Go binary, run in stdio mode, authenticated via `GITHUB_PERSONAL_ACCESS_TOKEN`), baked into the image — replacing the deprecated `@modelcontextprotocol/server-github`. No Docker-in-Docker.
- **FR-007**: All three changes MUST survive `./setup.sh --regenerate` (agent.yml stays the single source of truth; derived files regenerate).
- **FR-008**: The container's least-privilege model MUST remain unchanged (cap_drop ALL, `-u agent`, no-new-privileges, root-owned crontab).
- **FR-009**: Linux behavior MUST NOT regress: MCPs and plugins that work on Linux today keep working.
- **FR-010**: User-facing changes MUST be recorded in `CHANGELOG.md` and the launcher `VERSION` MUST be bumped.

### Key Entities

- **Package-runner cache**: ephemeral, non-state data (downloaded packages). Not part of the agent's durable state; may live on a non-persistent image path.
- **Plugin set**: the list of plugins an agent declares (source of truth in `agent.yml`), installed post-login by the supervisor.
- **MCP server definition**: the per-server command/args/env that the agent's MCP config declares (rendered from `agent.yml`).

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: On a fresh macOS scaffold, the agent's MCP listing shows `vault` and `filesystem` connected (both failed before the change).
- **SC-002**: On a fresh macOS scaffold with a valid GitHub token, the agent's MCP listing shows the GitHub server connected.
- **SC-003**: After `/login`, 100% of the agent's declared plugins are installed with zero manual operator commands, within a bounded time window.
- **SC-004**: The default (no-Docker) bats suite stays green, and new coverage reproduces each of the three failures (red) and proves each fix (green); image-baked behavior is covered by the opt-in DOCKER_E2E suite.
- **SC-005**: Running the same scaffold on Linux shows no regression in MCP connectivity or plugin installation.

## Assumptions

- The failures reproduce specifically on macOS Docker Desktop (VirtioFS / gRPC-FUSE bind-mount); Linux bind-mounts are unaffected. Fixes target the macOS pathology without changing Linux behavior.
- **Decided (refine 2026-06-21):** mirror the uv `/opt` pattern fully — pre-install/warm the default-catalog npx MCP packages into the image (off the bind-mount) so they start warm. The repository already does this for uv tools (`uv tool install mcp-atlassian …` into `/opt/uv`) precisely because downloading inside the MCP handshake window times out; npm gets the same treatment.
- **Decided (refine 2026-06-21):** the GitHub MCP replacement is GitHub's official `github-mcp-server` binary, baked into the image and run in stdio mode (no Docker-in-Docker); the deprecated npx package is removed. The exact binary version/pin is a plan-level detail.
- The post-login auth-ready lag is on the order of seconds-to-low-minutes, so a bounded retry budget measured in low minutes is sufficient.
- Verification of image-baked behavior uses the opt-in `DOCKER_E2E` path; the default suite must not require Docker.

## Refinement decisions

### 2026-06-21 session

- D: GitHub MCP replacement server (US3/FR-006) → A: GitHub's official `github-mcp-server` Go binary, baked into the image, stdio mode, `GITHUB_PERSONAL_ACCESS_TOKEN`; deprecated npx package removed.
- D: Post-login plugin-install retry budget (US2/FR-003) → A: retry with backoff until the profile is operative (an install succeeds) or ~120s elapses; on exhaustion, record the residual failure (FR-005).
- D: Delivery grouping (US1/US2/US3) → A: ship all three together in a single plan/tasks/PR (one image rebuild covers all), implementing in priority order P1→P2→P3. Stories stay independently testable per the spec, but they land as one PR.
- D: npm fix depth (US1/FR-001) → A: full uv pattern — pre-install/warm the default npx MCP packages (vault, filesystem) into the image off the bind-mount, not just relocate the cache. Relocation alone would still download inside the handshake window.
- D: context7 scope (US1/FR-001, analyze I1 2026-06-21) → A: `context7` is a Claude **plugin** (`modules/plugins/context7.yml`), NOT an npx `mcp-json` MCP — removed from US1/P1 scope. It benefits indirectly from the global `NPM_CONFIG_CACHE` relocation but is not a pre-warm target. Aligns spec.md with research/plan/tasks.
