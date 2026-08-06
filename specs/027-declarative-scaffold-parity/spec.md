# Feature Specification: Declarative Local-Scaffold Parity

**Feature Branch**: `027-declarative-scaffold-parity`

**Created**: 2026-08-05

**Status**: Draft

**Input**: User description: harden the declarative (non-interactive) local-mode scaffold so that a fresh clone-and-render produces a fully working local agent, at parity with the interactive wizard. Four gaps were measured on a fresh declarative scaffold of the `ferrari-admin` agent (2026-08-05, launcher v0.17.0).

## Context

There are two ways to scaffold a local-mode agent from this launcher:

1. **Interactive wizard** — `./setup.sh` prompts for answers, writes `agent.yml`, renders everything, and prints `NEXT_STEPS.md`.
2. **Declarative** — clone the launcher as the workspace, hand-author `agent.yml` + persona, then `./setup.sh --non-interactive` (render) and `./setup.sh --login` (OAuth + unit install). This is the path documented in `docs/creating-an-agent.md`.

The declarative path is the one used to stand up agents reproducibly. A live scaffold of a new local agent (`ferrari-admin`, on the `ferrari` host, 2026-08-05) surfaced **four defects that leave a fresh declarative local scaffold broken where a wizard-scaffolded or earlier-era agent works**. All four were measured on the host and manually worked around to bring `ferrari-admin` up; this feature brings the fixes into the launcher, test-first, so the next declarative scaffold needs none of those manual steps.

**Scope boundary**: local mode only. Docker mode bakes its runtimes into the image and renders a different artifact set; it is explicitly out of scope and MUST NOT change. The interactive wizard path already works and MUST NOT regress.

## Clarifications

### Session 2026-08-06

- Q: US4 — render `NEXT_STEPS.md` as a derived file in the non-interactive path, or only document the steps in the runbook? → A: **Render** `NEXT_STEPS.md` as a derived file in the `--non-interactive` and `--regenerate` paths (Principle I; the `next-steps` template already exists). The declarative operator gets the same per-workspace file a wizard user gets, and it survives regeneration.
- Q: US3 — which uvx MCP servers get pinned to a validated combo? → A: Pin **all three** uvx MCP servers the provisioner warms — `fetch`, `git`, AND `atlassian` — plus the `mcp` protocol library, to a validated, single-sourced version set. (`atlassian` connects today only by luck of resolution, exactly as `fetch`/`git` did in June; pinning all closes the whole class.)
- Q: US1 — when does the non-interactive render (re)generate the agent's `CLAUDE.md`? → A: **Surgically** — render the agent's `CLAUDE.md` when the current file is absent OR is detected as the launcher's own developer doc; PRESERVE an `CLAUDE.md` that is a genuine operator-edited agent doc (the "generated once, user-owned after" contract).

## User Scenarios & Testing *(mandatory)*

### User Story 1 - The scaffolded agent has its OWN identity, not the launcher's (Priority: P1)

An operator clones the launcher as a workspace, hand-authors `agent.yml` + persona, and renders with `./setup.sh --non-interactive`. The resulting agent's operating instructions (`CLAUDE.md`) must describe **that agent** (its name, role, persona, MCP set), not the launcher's own developer documentation.

Today the clone ships the launcher's own root `CLAUDE.md` (it is force-committed to the launcher repo), and the render **preserves** any existing `CLAUDE.md`; `--force-claude-md` only overwrites after a destructive-confirmation prompt that defaults to "no" when there is no TTY. So a declarative scaffold silently keeps the launcher's developer doc — the agent believes it "is the launcher."

**Why this priority**: This is the most fundamental failure of the four. An agent running with the wrong system-level instructions misbehaves at every turn regardless of which tools connect — it is, in effect, the wrong agent. It is also silent: nothing in `agentctl doctor` or `claude mcp list` flags it.

**Independent Test**: Render a declarative local workspace whose root `CLAUDE.md` is the launcher's dev doc; assert the post-render `CLAUDE.md` is the agent's rendered instructions (contains the agent's name/role from `agent.yml`), not the launcher's "This is **the launcher**, not an agent" framing — with no prompt and no manual `rm`.

**Acceptance Scenarios**:

1. **Given** a workspace that is a fresh clone of the launcher (so its `CLAUDE.md` is the launcher's dev doc), **When** the operator runs `./setup.sh --non-interactive`, **Then** the resulting `CLAUDE.md` is the agent's rendered instructions (from `modules/claude-md.tpl`, reflecting `agent.yml`), and no interactive prompt is required.
2. **Given** a workspace where `CLAUDE.md` is a genuine operator-authored agent doc (not the launcher's), **When** the operator re-runs `--regenerate`, **Then** that operator content is NOT clobbered (the "user-owned after first generation" contract is preserved for real agent docs).
3. **Given** the interactive wizard path, **When** an operator scaffolds a new agent, **Then** `CLAUDE.md` generation behaves exactly as before (no regression).

---

### User Story 2 - QMD works after a fresh scaffold (Priority: P1)

An operator scaffolds a local agent with the vault/QMD RAG enabled. After `./setup.sh --login` (which provisions runtimes), the QMD semantic index must build and the QMD MCP must connect — with no manual runtime installation.

Today the runtime provisioner installs `bun` only when it sees a literal `bunx` command in `.mcp.json`. In local mode the QMD MCP command is the wrapper script (not `bunx`), so a fresh scaffold never provisions `bun`, and both the QMD reindex and the QMD MCP — which depend on `bun` in the operator's runtime bin dir — are broken. (Agents scaffolded before the wrapper change kept a `bun` installed in an earlier era, masking the gap.)

**Why this priority**: QMD is the whole semantic-RAG subsystem; without it the agent's vault search is dead on arrival for every fresh local scaffold that enables it.

**Independent Test**: With QMD enabled, run the provisioner's dry-run plan on a fresh workspace and assert it plans a `bun` install; and on a real host, assert the QMD reindex reaches an indexed state and the QMD MCP connects — without any manual `bun` install.

**Acceptance Scenarios**:

1. **Given** a fresh local workspace with QMD enabled (QMD MCP rendered as the wrapper, not `bunx`), **When** the runtime provisioner runs, **Then** it provisions `bun`/`bunx` into the operator's runtime bin dir.
2. **Given** QMD is disabled for the agent, **When** the provisioner runs, **Then** it does NOT provision `bun` (no unnecessary download).
3. **Given** `bun` was provisioned, **When** the QMD reindex runs on a populated vault, **Then** it reaches an indexed state and the QMD MCP connects.

---

### User Story 3 - The fetch and git MCPs connect after a fresh scaffold (Priority: P2)

An operator scaffolds a local agent whose MCP set includes the `fetch` and `git` servers (run via the Python tool runner). After provisioning, both must connect — deterministically, regardless of what "latest" resolves to on the day of the scaffold.

Today the provisioner installs these MCP server tools with no version constraint. A fresh scaffold resolves the newest server releases together with a newer core protocol library whose public API changed incompatibly, so both servers fail at import. An earlier-era scaffold happens to hold a self-consistent, working combination.

**Why this priority**: It breaks two general-purpose tools (web fetch, git operations), degrading the agent, but the agent is still usable for other work — so below the identity and RAG failures.

**Independent Test**: On a fresh scaffold, assert both `fetch` and `git` MCPs connect (via the standard MCP listing), and that the provisioned versions match an intentionally pinned, single-sourced set rather than "whatever latest resolves to."

**Acceptance Scenarios**:

1. **Given** a fresh local scaffold whose MCP set includes `fetch` and `git`, **When** the runtime provisioner runs and the MCP listing is checked, **Then** both `fetch` and `git` report Connected.
2. **Given** the provisioner installs the tool-runner MCP servers, **When** it resolves their versions, **Then** it uses an intentionally pinned, single-sourced version set (one edit changes them), not an unconstrained "latest."
3. **Given** a future deliberate version bump, **When** a maintainer changes the single-sourced pin, **Then** no other file needs editing for the new versions to take effect.

---

### User Story 4 - The declarative operator gets post-scaffold guidance (Priority: P3)

An operator who scaffolds non-interactively must receive the same "what to do next" guidance a wizard user gets: the login command, the unit-install path, and how to validate.

Today `NEXT_STEPS.md` is produced only inside the interactive wizard, so `--non-interactive` and `--regenerate` never generate it, leaving a declarative operator with no post-scaffold instructions.

**Why this priority**: Guidance-only; the agent still works without it. Lowest of the four.

**Independent Test**: After a non-interactive render, assert the post-scaffold guidance artifact exists and names the correct next actions for this agent (login command, unit install), OR that the declarative runbook documents the exact equivalent steps.

**Acceptance Scenarios**:

1. **Given** a fresh local workspace, **When** the operator runs `./setup.sh --non-interactive`, **Then** post-scaffold guidance (login command + unit-install + validation) is available to them, derived from `agent.yml`.
2. **Given** `--regenerate` is re-run, **Then** the guidance is re-produced deterministically (no drift) and survives regeneration.

---

### Edge Cases

- **Genuine operator-authored `CLAUDE.md`** (US1): a workspace whose `CLAUDE.md` is a real, edited agent doc (not the launcher's) must NOT be silently overwritten by the non-interactive render — the fix must distinguish "the launcher's own doc, wrongly inherited by a clone" from "an operator's agent doc."
- **QMD disabled** (US2): provisioning `bun` must remain conditional; an agent with QMD off must not pull `bun`.
- **Tool-runner MCP absent** (US3): if `fetch`/`git` are not in the agent's MCP set, the pinned-version logic is a no-op (nothing to install).
- **Offline / pin unavailable** (US2/US3): if a pinned version cannot be fetched, the provisioner must degrade the same fail-silent way it does today (warn, continue, exit 0) — a broken download must not block `--login`.
- **Docker mode** (all): none of these code paths may alter docker-mode rendering or provisioning.
- **NEXT_STEPS needs interactive-only data** (US4): if any wizard-only input is required to produce the guidance, the guidance must be reduced to what `agent.yml` can supply (Principle I), not block the render.

## Requirements *(mandatory)*

### Functional Requirements

**US1 — agent identity**

- **FR-001**: A non-interactive/declarative render MUST produce the agent's own `CLAUDE.md` (rendered from `modules/claude-md.tpl` against `agent.yml`) when the workspace's current `CLAUDE.md` is **absent OR is the launcher's own developer document**, without requiring a TTY, an interactive confirmation, or a manual delete.
- **FR-002**: The render MUST NOT clobber a `CLAUDE.md` that is a genuine, operator-owned agent document (the existing "generated once, user-owned after" contract for real agent docs is preserved).
- **FR-003**: The mechanism that distinguishes the launcher's own doc from an operator's agent doc MUST be deterministic and MUST NOT depend on interactive input.

**US2 — QMD/bun provisioning**

- **FR-004**: The runtime provisioner MUST provision `bun`/`bunx` whenever the agent's rendered MCP set requires it, including when the QMD MCP is expressed as the local wrapper command rather than a literal `bunx`.
- **FR-005**: The provisioner MUST NOT provision `bun` when no MCP in the agent's set needs it (e.g., QMD disabled).
- **FR-006**: The dry-run plan mode of the provisioner MUST reflect the corrected decision (it MUST emit a `bun` provisioning plan line for a QMD-enabled agent and MUST NOT for a QMD-disabled agent), so the behavior is host-testable without downloading anything.

**US3 — tool-runner MCP version pinning**

- **FR-007**: The provisioner MUST install **all** the tool-runner MCP servers it warms — `fetch`, `git`, AND `atlassian` — at intentionally pinned versions, AND MUST pin the `mcp` protocol library to a version mutually compatible with those servers, rather than resolving "latest."
- **FR-008**: Those pins MUST be single-sourced (one place to edit), consistent with the project's existing single-source pin pattern, so a future bump is one change.
- **FR-009**: The pinned set MUST produce `fetch` and `git` MCPs that connect on a fresh scaffold; the dry-run plan MUST surface the pinned versions so the pin is host-testable.

**US4 — declarative next-steps guidance**

- **FR-010**: The `--non-interactive` and `--regenerate` paths MUST render `NEXT_STEPS.md` as a derived file (from the existing `next-steps` template against `agent.yml`), so the declarative operator gets the same post-scaffold guidance (login command, unit-install path, validation) as a wizard user.
- **FR-011**: Any guidance artifact produced MUST be reproducible by `--regenerate` (survives regeneration, no drift), consistent with the single-source-of-truth contract for derived files.

**Cross-cutting**

- **FR-012**: Docker-mode rendering and provisioning MUST be byte-for-byte unchanged by this feature.
- **FR-013**: The interactive wizard path MUST behave exactly as before for all four areas (no regression in wizard `CLAUDE.md` generation, wizard `NEXT_STEPS.md`, or docker provisioning).
- **FR-014**: All changes MUST survive `./setup.sh --regenerate` and keep `agent.yml` the single source of truth.
- **FR-015**: New/changed behavior MUST ship with host-runnable `bats` coverage (no Docker daemon required) and pass `shellcheck`; the provisioner changes MUST be exercised via its existing dry-run plan mode.
- **FR-016**: Provisioning changes MUST preserve the idempotent, fail-silent contract (warn-and-continue, exit 0; never block `--login`).

### Key Entities

- **Runtime provisioner** — the rendered per-workspace script that installs the MCP runtimes into the operator's runtime bin dir based on the agent's `.mcp.json`. Inputs: the agent's MCP set. Outputs: installed runtimes (or a dry-run plan). Governs US2 and US3.
- **Agent `CLAUDE.md`** — the agent's operating instructions, a derived file rendered from `modules/claude-md.tpl` + `agent.yml`. Governs US1.
- **Post-scaffold guidance** — the "what to do next" artifact/derived output for the operator. Governs US4.
- **Version pin source** — the single place recording the intentionally-pinned tool-runner MCP versions. Governs US3.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A fresh declarative local scaffold with QMD enabled reaches a working semantic index (reindex status "indexed", QMD MCP connected) with **zero** manual runtime-installation steps.
- **SC-002**: After a fresh declarative local scaffold, **100%** of the agent's configured tool-runner project MCPs (`fetch`, `git`) connect, and the result is deterministic across different scaffold dates (not dependent on same-day "latest" resolution).
- **SC-003**: A declarative scaffold produces an agent whose operating instructions describe the agent itself — **zero** occurrences of the launcher's "this is the launcher, not an agent" identity in the agent's `CLAUDE.md` — with no manual intervention.
- **SC-004**: An operator following the declarative path has access to the same post-scaffold next-actions (login, unit install, validation) as a wizard user.
- **SC-005**: Docker-mode and interactive-wizard scaffolds are unchanged — a byte-level comparison of their rendered outputs and provisioning behavior shows no difference attributable to this feature.
- **SC-006**: The full host `bats` suite passes on both bash 3.2 (macOS stock) and bash 5.x, with the new coverage included; `shellcheck -S error` is clean.
- **SC-007**: Reverting any one of the four fixes causes at least one new test to fail (the tests genuinely pin the corrected behavior).

## Assumptions

- **NEXT_STEPS is rendered as a derived file** *(Clarified 2026-08-06)*: US4 is resolved to render `NEXT_STEPS.md` from the existing `next-steps` template in the `--non-interactive` and `--regenerate` paths (Principle I lists it as a derived file). If some existing wizard-only content cannot be derived from `agent.yml`, that content is reduced to what `agent.yml` supplies rather than blocking the render (confirmed at plan time against the current `next-steps` template/generator).
- **US3 pins cover all three uvx MCP servers + the protocol lib** *(Clarified 2026-08-06)*: `fetch`, `git`, and `atlassian` plus the `mcp` protocol library are pinned to a validated, single-sourced set. Reference values from the working `mclaren-admin` host: fetch `2026.6.4`, git `2026.6.16`, protocol lib `1.28.1`; the `atlassian` pin and the single-source location are finalized at plan/implement time by reading the reference host.
- **`bun` version for US2** stays the project's already-pinned `bun` version used elsewhere in the provisioner; this feature only changes *when* `bun` is provisioned, not *which* version.
- **The launcher's own `CLAUDE.md` is identifiable** deterministically (e.g., by a stable marker/first-line framing it already carries), so US1's discriminator needs no interactive input. (Exact discriminator chosen at plan time.)
- **This feature is local-mode only and touches no `docker/` code**, so no `DOCKER_E2E` gate is expected; the changed provisioner template and `setup.sh` render paths are host-testable via `bats` + the provisioner dry-run.
- **Version bump**: this changes runtime behavior for local-mode scaffolds, so it warrants a launcher `VERSION` bump and a `CHANGELOG.md` entry (level decided at plan/implement time).
