---
description: "Task list — Modo agente local standalone (011)"
---

# Tasks: Modo agente local standalone (Linux/systemd)

**Input**: Design documents from `specs/011-local-standalone-mode/`

**Prerequisites**: plan.md, spec.md, research.md (D1–D12), data-model.md, contracts/

**Tests**: INCLUDED and REQUIRED — Principle III (test-first, host-runnable bats) is binding for this repo.

**Scope**: v1 Thin (D3) — mode choice + config-base render + Remote Control session persistence + guided
login + trust-merge + healthcheck + kill-switch + security. Supervisor automation (heartbeat scheduling,
plugin auto-install, qmd watcher, backups) is DEFERRED to a follow-up.

**Format**: `[ID] [P?] [Story] Description with file path`

---

## Phase 1: Setup (Shared Infrastructure)

- [X] T001 Bump `VERSION` 0.4.4 → 0.5.0 (new deployment mode = minor feature).
- [X] T002 [P] Add an `[Unreleased]` entry stub for 011 in `CHANGELOG.md` (local standalone mode; filled in T033).
- [X] T003 [P] Add `mode: docker` under `deployment:` in `tests/fixtures/sample-agent.yml` and `tests/fixtures/sample-agent-with-vault.yml` so fixtures stay valid after the schema change.

---

## Phase 2: Foundational (Blocking Prerequisites)

**⚠️ CRITICAL**: the `deployment.mode` plumbing below blocks BOTH US1 and US2.

- [X] T004 [P] In `tests/schema-validate.bats`: add `deployment.mode` cases — `docker` valid, `local` valid, bogus value rejected, absent valid (legacy-safe). (RED first.)
- [X] T005 In `scripts/lib/schema.sh` (~52-59): append `'.deployment.mode=docker,local'` to `_SCHEMA_ENUMS` (optional + enum-checked; NOT added to `_SCHEMA_REQUIRED_LEAVES`). Makes T004 green.
- [X] T006 [P] In `tests/regenerate.bats`: add a test that `--regenerate` on an `agent.yml` WITHOUT `deployment.mode` backfills `mode: docker`, and that an existing `mode` is preserved across `--regenerate`. (RED first.)
- [X] T007 In `setup.sh` regenerate (~1786-1819): backfill `deployment.mode` → `docker` when absent (mirror the `docker.*` backfill block); after `render_load_context`, `export DEPLOYMENT_MODE="$(yq -r '.deployment.mode // "docker"')"` and derive+export `DEPLOYMENT_MODE_IS_DOCKER` (`true`/`false`). Makes T006 green.

**Checkpoint**: `deployment.mode` is validated, rendered into context, and `--regenerate`-safe.

---

## Phase 3: User Story 1 — Wizard mode choice + local scaffolding (Priority: P1) 🎯 MVP

**Goal**: el wizard ofrece docker (recomendado) vs local (con advertencia); en local renderiza la base
en el host SIN artefactos Docker; docker queda byte-idéntico.

**Independent Test**: `deployment-mode.bats` — `mode=local` → no `docker-compose.yml`/mirror, base presente; `mode=docker` → set de archivos byte-idéntico a hoy.

### Tests for User Story 1 ⚠️ (write first, must FAIL)

- [X] T008 [P] [US1] `tests/deployment-mode.bats` (NEW): scaffold/regenerate con `mode=docker` → `docker-compose.yml` presente + `mirror_catalog_to_docker` corrió (regresión byte-idéntica); con `mode=local` → NO `docker-compose.yml`, NO mirror, base de config presente (CLAUDE.md, .mcp.json, heartbeat.conf, vault). **Incluye el test del aviso de cambio de modo (G1/FR-005a):** regenerar un workspace docker como `local` (o viceversa) emite un aviso que lista los artefactos huérfanos del modo previo y NO los borra (assert: el archivo huérfano sigue existiendo). Hace fallar T016 (RED).
- [X] T009 [P] [US1] In `tests/helper.bash`: extend `wizard_answers` to accept `deployment_mode=docker|local` (default docker) so wizard-driven tests can select the mode.

### Implementation for User Story 1

- [X] T010 [US1] In `setup.sh` wizard deployment block (~449-489): add `ask_choice` mode selection (options `docker local`, default `docker`) with "Docker (recomendado)" first and "local standalone (riesgo de seguridad)" second; assign to `deploy_mode`.
- [X] T011 [US1] In `setup.sh` agent.yml heredoc (~1075-1080): persist `  mode: "$deploy_mode"` under `deployment:`.
- [X] T012 [US1] In `setup.sh` regenerate (~1901-1909): wrap the `render_to_file docker-compose.yml.tpl` and `mirror_catalog_to_docker` calls in `if [ "$DEPLOYMENT_MODE_IS_DOCKER" = true ]; then … fi` (skip for local).
- [X] T013 [US1] In `setup.sh` `scaffold_destination` (~1671-1702): gate the docker mirror so `mode=local` copies `modules/`+`scripts/` to the workspace but does NOT mirror catalogs into `docker/` (no Docker build context).
- [X] T014 [US1] In `modules/next-steps.en.tpl` and `modules/next-steps.es.tpl`: wrap docker steps in `{{#if DEPLOYMENT_MODE_IS_DOCKER}}…{{/if}}` and add a `{{#unless DEPLOYMENT_MODE_IS_DOCKER}}…{{/unless}}` local section (filled fully in T025).
- [X] T015 [US1] In `modules/claude-md.tpl`: make the runtime line mode-aware (`{{#unless DEPLOYMENT_MODE_IS_DOCKER}}Local host (systemd){{/unless}}{{#if DEPLOYMENT_MODE_IS_DOCKER}}Docker container{{/if}}`).
- [X] T016 [US1] In `setup.sh` regenerate: implement the mode-switch warning (FR-005a) — detect the prior mode (presence of `docker-compose.yml` vs the local unit) and, if it differs from the current mode, print a warning listing the orphaned artifacts WITHOUT deleting them.

**Checkpoint**: US1 standalone — local scaffold produces the base + no Docker artifacts; docker mode unchanged.

---

## Phase 4: User Story 2 — Remote Control persistence via systemd (Priority: P1)

**Goal**: una sesión `claude remote-control` persistente atada al SO (login guiado, trust, rearranque, kill-switch).

**Independent Test**: `local-render.bats` (unit/env invariants) + `local-trust-merge.bats` (idempotent trust) green; on a real Linux host the 6 manual gates pass (quickstart).

### Tests for User Story 2 ⚠️ (write first, must FAIL)

- [X] T017 [P] [US2] `tests/local-render.bats` (NEW): render `systemd-remote-control.service.tpl` + `remote-control.env.tpl` from an `agent.yml` with `mode=local`; assert: unit has `Restart=always`, an `ExecCondition` on `.credentials.json`, `ExecStart` contains `remote-control --name … --spawn=session` and NOT `--dangerously-skip-permissions`, `WorkingDirectory` = workspace, `EnvironmentFile` = `.state/remote-control.env`; env has `CLAUDE_CONFIG_DIR` + `DISABLE_AUTOUPDATER=1` and NO `ANTHROPIC_API_KEY`.
- [X] T018 [P] [US2] `tests/local-trust-merge.bats` (NEW): apply the trust-merge to a `.claude.json` that has other keys → `projects["<ws>"].hasTrustDialogAccepted=true` set AND all other keys preserved; re-running is a no-op (exact-equality compare, not substring — gotcha #4). **Also (G2/FR-011):** onboarding pre-seed sets `hasCompletedOnboarding=true` when absent and does NOT overwrite an existing `.claude.json`/onboarding value.

### Implementation for User Story 2

- [X] T019 [P] [US2] Create `modules/systemd-remote-control.service.tpl` per `contracts/systemd-remote-control.md` (Type=simple, Restart=always/RestartSec=10, StartLimit 5/300, ExecCondition, WorkingDirectory, EnvironmentFile, User placeholder, ExecStart `claude remote-control --name <hostname>-{{AGENT_NAME}} --spawn=session --verbose`, no skip-permissions).
- [X] T020 [P] [US2] Create `modules/remote-control.env.tpl` (0640): `CLAUDE_CONFIG_DIR={{DEPLOYMENT_WORKSPACE}}/.state/.claude`, `DISABLE_AUTOUPDATER=1`, `HOME` placeholder; no API key.
- [X] T021 [US2] Create `modules/local-login.sh.tpl` (rendered to `scripts/local/agent-login.sh`): verify `claude --version` ≥ 2.1.51; pre-seed `hasCompletedOnboarding=true` if absent; launch the OAuth login; AFTER login do the idempotent trust-merge (discrete, BASH_SOURCE-guarded function or jq/python snippet — the unit tested in T018); `systemctl enable --now`. Idempotent.
- [X] T022 [P] [US2] Create `modules/local-killswitch.sh.tpl` (rendered to `scripts/local/agent-killswitch.sh`): `systemctl stop` (+ optional `disable`); document the claude.ai remote toggle.
- [X] T023 [US2] In `setup.sh` `install_service` (~1933-1960): branch on mode — for `local` render `systemd-remote-control.service.tpl` as a **system unit** (`/etc/systemd/system/agent-<name>.service`; A1, no `systemd --user`/linger in v1), resolving `User=$(id -un)`, absolute `claude` path and `<hostname>`; for `docker` keep current behavior.
- [X] T024 [US2] In `setup.sh` regenerate: when `mode=local`, render the local artifacts (env, login helper, kill-switch) into the workspace; add a `--login` flag that runs the rendered `scripts/local/agent-login.sh`.
- [X] T025 [US2] Fill the local section of `modules/next-steps.{en,es}.tpl` with the real flow: `setup.sh --login`, `systemctl status/journalctl`, kill-switch, and requisitos (claude ≥ 2.1.51, plan compatible, MFA).

**Checkpoint**: US2 — local artifacts render correctly; trust-merge idempotent; ready for the manual Linux gate.

---

## Phase 5: User Story 3 — Healthcheck + security (Priority: P2)

**Goal**: healthcheck periódico (vivo/conectado/expirado) + advertencias de seguridad explícitas.

**Independent Test**: `local-healthcheck.bats` → OK/WARN/DEGRADED con stubs; el wizard muestra la advertencia de seguridad al elegir local.

### Tests for User Story 3 ⚠️ (write first, must FAIL)

- [X] T026 [P] [US3] `tests/local-healthcheck.bats` (NEW): stub `systemctl`/`journalctl`/`jq` on PATH + a `.credentials.json` with controlled `expiresAt`; assert OK (active+connected+valid), WARN (no connection signal / near-expiry), DEGRADED (401 in journal / expired / unit inactive); and graceful degrade when `jq`/creds missing. **Also (G3):** assert the notify path passes the token via `curl --config -` (token never appears in the rendered command/argv). Add a minimal version-check assertion (G3/FR-014): with a stubbed `claude --version` < 2.1.51, the login helper exits non-zero with a clear message (stub-driven, in this file or `tests/local-render.bats`).

### Implementation for User Story 3

- [X] T027 [P] [US3] Create `modules/local-healthcheck.sh.tpl` (rendered to `scripts/local/agent-healthcheck.sh`) per `contracts/systemd-remote-control.md` (is-active; journal 401/connection; expiresAt via jq; graceful degrade; optional notify with token via `curl --config -`, never in argv).
- [X] T028 [P] [US3] Create `modules/local-healthcheck.service.tpl` (oneshot) + `modules/local-healthcheck.timer.tpl` (~5 min).
- [X] T029 [US3] In `setup.sh`: render the healthcheck script + service + timer for local mode; and reinforce the wizard security warning at the local-mode confirm (current-user privilege/secret inheritance + MFA obligatorio + sin aislamiento de contenedor).
- [X] T030 [P] [US3] In `scripts/agentctl`: detect `mode=local` and degrade — docker-only subcommands (`up/down/restart/attach/shell/logs -f`) error with a `systemctl`/`journalctl` hint; `status`/`doctor` use `systemctl is-active` + journal + login age. Add `tests/agentctl-local.bats` asserting the docker-only subcommands exit non-zero with the hint (stub `docker` NOT invoked) and `status`/`doctor` use the systemctl stubs.

**Checkpoint**: all three stories functional; local mode is operable + observable + safe-by-warning.

---

## Phase 6: Polish & Cross-Cutting Concerns

- [X] T031 [P] Docs: add a local-mode section to `docs/architecture.md` (deployment modes + the Principle II trade-off) and `docs/getting-started.md` (choosing local, the one-time login, the manual Linux gates).
- [X] T032 [P] Verify the workspace `.gitignore` template covers local-mode secrets (`.state/remote-control.env`, `.state/.claude/.credentials.json` — covered by `.state/`; add explicit rules for any local secret outside `.state/`).
- [X] T033 Finalize the `CHANGELOG.md` 011 entry (deployment.mode docker|local, local systemd Remote Control, guided login, healthcheck, security model) and confirm `VERSION` 0.5.0.
- [X] T034 Run the FULL host suite `bats tests/` and `shellcheck -S error` over every touched shell file; fix regressions (esp. docker-mode byte-identity).
- [X] T035 DOCKER_E2E: confirm the docker-mode e2e suite stays green (`DOCKER_E2E=1 bats tests/docker-e2e-*.bats`) — non-regression; document that local mode (systemd/Linux) is NOT e2e-testable on macOS. **Done:** `docker-e2e-smoke` green (scaffold+build+up+healthcheck, exit 0); no files under `docker/` changed; local-mode systemd integration documented as un-e2e-testable on macOS in plan.md Complexity Tracking + research D12 + quickstart.
- [ ] T036 Manual Linux verification gate (quickstart 6 gates): on a real Linux host, scaffold local mode, run `--login`, and verify version/creds/is-active+connection/`claude -p READY`/idempotency/auto-recovery. (Manual checklist — not automatable on the dev host.) **PENDING MANUAL RUN** on a Linux/systemd host — cannot execute on macOS; procedure in `quickstart.md`.

---

## Dependencies & Execution Order

- **Setup (Phase 1)**: no deps.
- **Foundational (Phase 2)**: after Setup; BLOCKS US1 + US2 (the `deployment.mode` plumbing).
- **US1 (Phase 3)**: after Foundational. MVP slice — delivers the mode choice + local base render.
- **US2 (Phase 4)**: after Foundational; builds on US1's local-render branch (renders into the same local path). Independently testable via render/trust tests.
- **US3 (Phase 5)**: after Foundational; independently testable (healthcheck stubs). Integrates with US2's unit.
- **Polish (Phase 6)**: after the desired stories.

### Within each story

- Tests FIRST (must fail) → implementation.
- Templates (modules/*.tpl) before the setup.sh wiring that renders them.
- shellcheck clean per touched file.

### Parallel opportunities

- T002/T003 (Setup) in parallel.
- T004/T006 (foundational tests) in parallel.
- US1 tests T008/T009 in parallel; US2 templates T019/T020/T022 in parallel; US3 T027/T028 in parallel.
- US1 and US2 share the local-render path → sequence US1 before US2's render wiring; US3 can proceed once Foundational is done.

---

## Implementation Strategy

### MVP boundary (M1)

US1 alone is **independently testable** (`mode=local` scaffolds the base with no Docker artifacts; `mode=docker` byte-identical) but is NOT yet an operable agent — the systemd unit, EnvironmentFile and login helper land in US2. Both US1 and US2 are **P1** precisely because a usable local agent = US1 + US2. So:

1. Phase 1 Setup → 2. Phase 2 Foundational (CRITICAL) → 3. Phase 3 US1 → **STOP & VALIDATE** the render branch (docker byte-identical; local base without Docker). 4. Phase 4 US2 → **the first operable local agent** (scaffold → `--login` → persistent session). US3 then makes it observable + safe.

### Incremental Delivery

- US1 (mode + base) → US2 (persistent session + login) → US3 (healthcheck + security) → Polish. Each adds value without breaking docker mode.

---

## Notes

- [P] = different files, no deps. [Story] maps to spec.md user stories.
- Verify tests fail before implementing (Principle III).
- Docker mode MUST stay byte-identical (SC-002) — branch in setup.sh, never wrap `docker-compose.yml.tpl`.
- Never `--dangerously-skip-permissions`; never commit/log `.credentials.json` or the env; token never in argv/journal.
- Local mode is Linux/systemd only; macOS/launchd and supervisor automation are out of v1 scope.
