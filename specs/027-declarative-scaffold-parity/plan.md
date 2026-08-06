# Implementation Plan: Declarative Local-Scaffold Parity

**Branch**: `027-declarative-scaffold-parity` | **Date**: 2026-08-06 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `specs/027-declarative-scaffold-parity/spec.md`

## Summary

Bring four measured defects — surfaced by the fresh declarative local scaffold of `ferrari-admin` (2026-08-05) — into the launcher code, test-first, so the next declarative local scaffold produces a fully working agent with no manual runtime steps. All four are **local-mode only** (no `docker/` change): (US1) the non-interactive render must produce the *agent's* `CLAUDE.md`, not the launcher's dev doc, detected by a stable content sentinel; (US2) the runtime provisioner must install `bun` when the QMD MCP is present as its wrapper (not only when it sees literal `bunx`); (US3) the provisioner must pin the uvx MCP servers (`fetch`, `git`, `atlassian`) + the `mcp` protocol library to a validated, single-sourced set in `versions.sh`; (US4) `NEXT_STEPS.md` must render as a derived file in the `--non-interactive`/`--regenerate` paths, reusing the existing `next-steps` template. Everything is exercised by the host `bats` suite (provisioner via `BOOTSTRAP_DRY_RUN=1`, render via file assertions); no Docker daemon required.

## Technical Context

**Language/Version**: Bash 3.2+ (tested on macOS stock 3.2 and Linux 5.x), plus the `{{var}}`/`{{#if}}`/`{{#each}}` render engine (`scripts/lib/render.sh`).

**Primary Dependencies (host/launcher)**: `yq` v4+, `jq`, `git`, BSD/GNU `sed`; the rendered per-workspace provisioner shells out to `uv`/`uvx`, `bun`, `curl`, `unzip`.

**Storage**: N/A (files rendered from `agent.yml` + `versions.sh`).

**Testing**: `bats` (host, no Docker); `shellcheck -S error`. Provisioner behavior asserted through its `BOOTSTRAP_DRY_RUN=1` "PLAN …" plan lines; render behavior via file-content assertions.

**Target Platform**: local-mode scaffolds (`deployment.mode: local`) on systemd Linux hosts; the launcher runs on the operator's macOS/Linux box.

**Project Type**: single-project bash CLI / scaffolding tool.

**Performance Goals**: N/A (scaffold-time, not a hot path).

**Constraints**: local-mode ONLY — no change to `docker/` rendering or provisioning (FR-012); no regression to the interactive wizard path (FR-013); every change survives `./setup.sh --regenerate` (FR-014); provisioning stays idempotent + fail-silent, exit 0, never blocks `--login` (FR-016).

**Scale/Scope**: 4 user stories; touched files (expected): `modules/local-bootstrap.sh.tpl` (US2, US3), `scripts/lib/versions.sh` (US3), `setup.sh` (`regenerate()` for US1 + US4; a small discriminator helper), and `tests/` (new bats). No `docker/` files.

## Constitution Check

*GATE: passes before Phase 0 and re-checked after Phase 1. Source: `.specify/memory/constitution.md` v1.0.1.*

- [x] **I. Single Source of Truth** — PASS. `CLAUDE.md` (US1) and `NEXT_STEPS.md` (US4) are rendered from `modules/*.tpl` + `agent.yml` and survive `--regenerate`; both are already listed as derived files in Principle I. US3 pins are single-sourced in `versions.sh`. No hand-edited derived file is introduced.
- [x] **II. Least-Privilege (NON-NEGOTIABLE)** — N/A. No `docker/` change; container privilege model untouched (US3 stays local-only by decision 2026-08-06).
- [x] **III. Test-First, Host-Runnable** — PASS. All four US ship `bats` coverage that runs with no Docker daemon (provisioner via `BOOTSTRAP_DRY_RUN=1`; render via file assertions). No `docker/` touch → no `DOCKER_E2E` gate. `shellcheck -S error` stays clean; the bootstrap template guards remain side-effect-free when sourced.
- [x] **IV. Idempotent, Fail-Silent Lifecycle** — PASS. The provisioner keeps its exit-0, warn-and-continue contract (US2/US3 add conditions + pins, never a hard failure). The CLAUDE.md discriminator is content-marker based (not mtime); `NEXT_STEPS.md` render is deterministic/idempotent.
- [x] **V. Workspace-Is-the-Agent** — N/A. No state-lifecycle, backup, or `.state/` change.
- [x] **VI. Reproducible, Pinned Dependencies** — PASS. US3 adds *intentional* pins (`fetch`/`git`/`atlassian` + `mcp` lib) single-sourced in `versions.sh`, consistent with the existing `AGENTIC_FLOOR_MCP_FILESYSTEM/_VAULT/_GH_MCP` entries. No new *duplicate* pin is introduced. VERSION bump + `CHANGELOG.md` entry for the user-facing behavior change.

**Result: 6/6 PASS (II, V N/A). No violations → Complexity Tracking empty.**

**Documented follow-up (not in scope, decision 2026-08-06):** `docker/Dockerfile:122-124` installs `mcp-atlassian`/`mcp-server-fetch`/`mcp-server-time` UNPINNED — the identical latent drift of US3, in docker mode. Left for a separate feature (would touch `docker/` → `DOCKER_E2E` + build-arg plumbing). Recorded in `research.md`.

## Project Structure

### Documentation (this feature)

```text
specs/027-declarative-scaffold-parity/
├── plan.md              # This file
├── research.md          # Phase 0 — the four root causes + chosen designs + the docker follow-up finding
├── data-model.md        # Phase 1 — the config/behavior entities (no persistent data)
├── quickstart.md        # Phase 1 — how to validate each US on host + on a live local host
├── contracts/           # Phase 1 — the provisioner dry-run + render behavioral contracts
│   ├── bootstrap-provisioning.md
│   ├── claude-md-identity.md
│   └── next-steps-render.md
└── tasks.md             # Phase 2 (/speckit-tasks — NOT created here)
```

### Source Code (repository root)

```text
modules/
├── local-bootstrap.sh.tpl     # US2 (bun trigger via qmd wrapper), US3 (uvx pins + --with mcp)
└── next-steps.{es,en}.tpl     # US4 (unchanged content; now also rendered by regenerate)

scripts/lib/
└── versions.sh                # US3 (new AGENTIC_FLOOR_MCP_FETCH/_GIT/_ATLASSIAN/_LIB pins)

setup.sh                       # US1 (regenerate() CLAUDE.md condition + _is_launcher_own_claude_md
                               #      helper); US4 (regenerate() renders NEXT_STEPS via render_next_steps)

tests/
├── local-bootstrap.bats       # US2/US3 dry-run PLAN assertions + pin surfacing + mutation
├── regenerate.bats            # US1 identity render + US4 NEXT_STEPS render (extend existing)
└── fixtures/                  # a launcher-own CLAUDE.md fixture; a qmd-wrapper .mcp.json fixture
```

**Structure Decision**: Single-project bash launcher. Changes are confined to two rendered templates, one launcher lib, and `setup.sh`'s `regenerate()` path, plus host bats. No new top-level structure.

## Complexity Tracking

*No constitution violations. Table intentionally empty.*

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| — | — | — |
