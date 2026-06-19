---
description: "Task list for 001-deps-upgrade — reproducible in-container dependency upgrades"
---

# Tasks: Reproducible In-Container Dependency Upgrades

**Input**: Design documents from `specs/001-deps-upgrade/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/cli-versions.md

**Tests**: REQUIRED for this feature (spec FR-008 + constitution Principle III:
test-first, host-runnable `bats`; the default suite must not need Docker).

**Organization**: Grouped by user story. US1 (P1) is the MVP. Concrete target
versions and caveats are in [research.md](./research.md).

## Format: `[ID] [P?] [Story?] Description`

- **[P]**: parallelizable (different files, no incomplete-task dependency)
- **[Story]**: US1 / US2 / US3 (user-story phases only)
- Paths are repo-relative from the launcher root.

---

## Phase 1: Setup (Shared Infrastructure)

- [x] T001 Create `scripts/lib/versions.sh`: declare default CHANNELS (`AGENTIC_CHANNEL_CLAUDE_CODE=stable`, `*_ALPINE/UV/BUN/GUM=latest`), a documented last-known offline fallback floor, and a `BASH_SOURCE`-guard so sourcing has no side effects (Principle III). No frozen version numbers as the source of truth (FR-011).
- [x] T002 [P] Source `scripts/lib/versions.sh` from `setup.sh` (near the other `scripts/lib/*` sources) and from `scripts/agentctl`, guarded so it loads once.

**Checkpoint**: `versions.sh` exists and sources cleanly in both entrypoints.

---

## Phase 2: Foundational (Blocking Prerequisites)

**⚠️ Blocks all user stories.**

- [x] T003 Implement `versions_resolve <component>` in `scripts/lib/versions.sh`: per-component best-effort upstream query (Claude Code npm `stable` dist-tag; uv/bun/gum GitHub `releases/latest`; Alpine `latest-stable` release) using `curl`+`jq` with a per-call timeout; echo concrete version on success, return non-zero + fall back to recorded/floor offline (FR-012). Queries per [research.md](./research.md).
- [x] T004 [P] Add `docker.claude_code_version`, `docker.uv_version`, `docker.bun_version`, `docker.gum_version` and `docker.toolchain_channels.*` as OPTIONAL, legacy-safe leaves (+ channel enum `stable|latest|pinned`) to `scripts/lib/schema.sh` rule arrays.
- [x] T005 [P] [US-test] Create `tests/versions.bats`: assert `scripts/lib/versions.sh` sources with no side effects, channels are defined, and `versions_resolve` parses a MOCKED upstream payload (no live network in the default suite).

**Checkpoint**: resolver + schema + base test harness in place; default `bats tests/` still green.

---

## Phase 3: User Story 1 — Upgrade from one place, build honors it (Priority: P1) 🎯 MVP

**Goal**: Set a managed version in one place (or accept the channel default) and have the documented `docker compose build` / `agentctl up` produce that version; bump all five to latest stable as the first use.

**Independent Test**: Record a Claude Code version, `docker compose build`, boot, and `agentctl run claude --version` reports it; repeat with a second version.

### Tests for US1 (write first, ensure they FAIL)

- [x] T006 [P] [US1] Extend `tests/render.bats`: `docker.*_version` + `docker.base_image` render into `docker-compose.yml` `build.args` (`CLAUDE_CODE_VERSION`, `ALPINE_VERSION`, `UV_VERSION`, `BUN_VERSION`, `GUM_VERSION`).
- [x] T007 [P] [US1] In `tests/versions.bats`: `setup.sh` scaffold + `--regenerate` resolves channels (mocked) and RECORDS concrete `docker.*_version` into `agent.yml`; re-render twice without `--upgrade` is byte-identical (SC-005).

### Implementation for US1

- [x] T008 [US1] `modules/docker-compose.yml.tpl`: add `build.args` `CLAUDE_CODE_VERSION/ALPINE_VERSION/UV_VERSION/BUN_VERSION/GUM_VERSION` as `{{DOCKER_*}}` (keep existing `UID`/`GID`).
- [x] T009 [US1] `docker/Dockerfile`: declare `ARG ALPINE_VERSION` BEFORE `FROM alpine:${ALPINE_VERSION}`; ensure `CLAUDE_CODE_VERSION/UV_VERSION/BUN_VERSION/GUM_VERSION` ARGs receive build-args; add `ENV UV_PYTHON_PREFERENCE=only-system` (research.md uv 0.8.0 guard); keep `DISABLE_AUTOUPDATER=1` and the GID-20/`dialout` block.
- [x] T010 [US1] `setup.sh`: at scaffold AND `--regenerate`, call `versions_resolve` for each non-`pinned` channel and write concrete `docker.*_version` + `docker.base_image` into `agent.yml` (atomic `agent.yml.prev`, rollback on failure).
- [x] T011 [US1] Initial bump (FR-007): record latest stable — Claude Code `stable` 2.1.170, Alpine 3.24.1, uv 0.11.22, bun 1.3.14, gum 0.17.0 — and align the drift-guarded `docker/Dockerfile` ARG defaults to the resolver/floor values.
- [x] T012 [US1] Fix `scripts/lib/wizard-gum.sh::_abort_if_interrupted` for gum 0.17.0: treat rc==1 from `gum input`/`gum choose` as abort, but NOT from `gum confirm` (rc==1 = legitimate "no"). Required by the gum bump (research.md).
- [x] T013 [US1] Audit `docker/` (Dockerfile, `entrypoint.sh`, `scripts/start_services.sh`) for any parsing of `apk` output and adjust for apk v3 (Alpine 3.23+); fix `/simplify`→`/code-review` references repo-wide (Claude Code 2.1.147).
- [x] T014 [US1] Extend the opt-in Docker-e2e suite (`tests/docker-e2e-*.bats`): build via compose with a declared `claude_code_version`, boot, assert `claude --version`; smoke the heartbeat/crond path under Alpine 3.24/busybox 1.37 and the three uvx MCP installs.

**Checkpoint**: US1 independently testable — declared version is honored by the documented build; all five at latest stable.

---

## Phase 4: User Story 2 — One source of truth, no drift (Priority: P2)

**Goal**: Every managed version has a single authoritative origin; the previously duplicated literals (gum, Alpine) are derived, not maintained.

**Independent Test**: Grep the repo — each managed version value has one authoritative origin; a one-place change propagates on regenerate with no stale copy.

### Tests for US2

- [x] T015 [P] [US2] In `tests/versions.bats`: no-duplicate-pin invariant — assert no managed version is an independent editable literal in `setup.sh` (gum) or `docker/Dockerfile` (Alpine) outside the build-arg/resolver path; Dockerfile ARG defaults stay drift-consistent with `versions.sh`.

### Implementation for US2

- [x] T016 [US2] `setup.sh`: drive the host-side `gum` download from the recorded `docker.gum_version` (remove the hardcoded `local version="0.14.5"` at setup.sh:154).
- [x] T017 [US2] Make `docker.base_image` the sole Alpine origin: it flows via the `ALPINE_VERSION` build-arg into `FROM`; remove the independent `FROM alpine:3.20` literal as a second source (becomes `${ALPINE_VERSION}` with a drift-guarded default).
- [x] T018 [US2] Honor `docker.toolchain_channels.*=pinned` in `setup.sh`/resolver so `--regenerate`/`--upgrade` leave pinned components untouched; keep regenerate deterministic.

**Checkpoint**: US2 testable — single-origin invariant passes; no drift.

---

## Phase 5: User Story 3 — See what is outdated (Priority: P3)

**Goal**: `agentctl versions [--check] [--json] [--upgrade]` reports recorded-vs-latest and can re-resolve, best-effort, network-optional.

**Independent Test**: `agentctl versions --check` against a behind agent lists declared/latest/status; offline → `unknown` without error.

### Tests for US3

- [x] T019 [P] [US3] In `tests/versions.bats`: `agentctl versions` (recorded table), `--check` status derivation with MOCKED upstream (`current`/`outdated`/`unknown`), and `--json` shape per contracts/cli-versions.md.

### Implementation for US3

- [x] T020 [US3] `scripts/agentctl`: add `versions` subcommand printing recorded version + channel per component (reads `agent.yml`); `--json` machine output. Exit 0.
- [x] T021 [US3] `scripts/agentctl`: `versions --check` — live best-effort `versions_resolve` per component, derive `status`, offline → `unknown`; always exit 0 (reporting).
- [x] T022 [US3] `scripts/agentctl`: `versions --upgrade` — re-resolve non-`pinned` channels, write `agent.yml` (atomic `.prev`), regenerate derived files, print `old → new` diff + "rebuild to apply".
- [x] T023 [US3] `scripts/agentctl` `doctor`: add a read-only "Toolchain versions" section (recorded, no network) beside the existing `Launcher version` line.

**Checkpoint**: US3 testable — the report and `--upgrade` work, degrade gracefully offline.

---

## Phase 6: Polish & Cross-Cutting Concerns

- [x] T024 [P] Update docs: `README.md`, `docs/getting-started.md`, `docs/architecture.md` for the channel/resolve-and-record upgrade workflow + `agentctl versions`; mirror into `modules/next-steps.{en,es}.tpl` if operator-facing.
- [x] T025 [P] `CHANGELOG.md` entry (under a new version) + bump `VERSION` (user-facing change per Principle VI).
- [x] T026 [P] `shellcheck -S error` clean on `scripts/lib/versions.sh`, `scripts/agentctl`, `setup.sh`, `scripts/lib/wizard-gum.sh`.
- [ ] T027 Run full default suite `bats tests/` (no Docker) green, then `DOCKER_E2E=1 bats tests/docker-e2e-heartbeat.bats` (Alpine 3.24/busybox/crond) — the gating verification.
- [ ] T028 E2E re-verify the high-risk caveats (research.md): Telegram `reply` path under Claude Code 2.1.170 (acceptEdits 2.1.160 change with `permissions.defaultMode=auto`), and the Python-3.14 patch scripts (`apply_telegram_typing_patch.py`, `fetch-github-key`).

---

## Dependencies & Execution Order

- **Setup (P1)** → **Foundational (P2)** → user stories.
- **US1 (P1)** depends on Foundational (resolver + schema). MVP — deliver and validate first.
- **US2 (P2)** depends on US1's build-arg passthrough (T008–T010) being in place to dedupe against.
- **US3 (P3)** depends on Foundational `versions_resolve` (T003) and the recorded `agent.yml` fields (T004/T010); otherwise independent of US2.
- **Polish** after the desired stories.

## Parallel Opportunities

- Setup: T002 ∥ (after T001).
- Foundational: T004 ∥ T005 (after T003).
- US1 tests: T006 ∥ T007 (different files).
- Cross-story (once Foundational done): US3 implementation (T020–T023, all in `scripts/agentctl`) can proceed alongside US2 since they touch different files — but US3's tests (T019) and US1's build path are independent.
- Polish: T024 ∥ T025 ∥ T026.

## Implementation Strategy

- **MVP = US1**: Setup → Foundational → US1 (T001–T014). Stop and validate: declared
  version honored by the documented build; all five at latest stable; Docker-e2e green.
- **Increment**: add US2 (dedupe/no-drift), then US3 (`agentctl versions`).
- **Gate**: T027 (Alpine 3.24 Docker-e2e) is the load-bearing verification — if the
  heartbeat/crond e2e regresses under busybox 1.37 / apk v3, STOP and escalate
  (do not silently fall back to a different Alpine).
