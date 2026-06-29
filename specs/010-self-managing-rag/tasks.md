# Tasks: Self-Managing RAG (auto-setup + auto-reindex del vault QMD)

**Input**: Design documents from `specs/010-self-managing-rag/`

**Prerequisites**: plan.md, spec.md, research.md (D1–D9), data-model.md (E1–E8), contracts/ (qmd-cli.md, agent-yml-schema.md), quickstart.md

**Tests**: REQUIRED. Principle III makes this repo test-first — every behavior change ships `bats` coverage written BEFORE the implementation. Host suite (`bats tests/`) must stay green and Docker-free; `DOCKER_E2E=1` gates the integration seams.

**Organization**: by user story (US1 P1, US2 P1, US3 P2). Within each story, tests precede implementation.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: parallelizable (different files, no dependency on an incomplete task)
- Paths are repo-relative. Image-baked code lives under `docker/`; host-render under `modules/`+`scripts/lib/`; tests under `tests/`.

## Conventions for this feature (read once)

- New libs `docker/scripts/lib/qmd_index.sh` and `docker/scripts/qmd_watch.sh` MUST guard side-effects at source-time (`BASH_SOURCE`/`*_NO_RUN` pattern) so bats can source them — CLAUDE.md gotcha.
- Every `bunx`/`qmd`/`claude` call in a boot/cron path MUST be `timeout`-bounded and fail-silent (Principle IV). Use the macOS `timeout` shim in tests (pattern from 008/009).
- Each new image-baked file MUST get its Dockerfile `COPY` (008/009 lesson) — tracked as explicit tasks here.
- `shellcheck -S error` MUST stay clean on every touched shell file.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: release bookkeeping + the one new image dependency. No behavior yet.

- [ ] T001 Bump `VERSION` from `0.4.3` to `0.4.4`.
- [ ] T002 [P] Add an `inotify-tools` entry to the `apk add --no-cache` list in `docker/Dockerfile` (alongside `flock`, which is already present at line ~45).
- [ ] T003 [P] Add an `## [Unreleased]` / `0.4.4` section stub to `CHANGELOG.md` describing the self-managing RAG feature (filled out in Polish).

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: the shared config shape + the empty lib shell that every US1/US2 test sources. MUST complete before any user story.

- [ ] T004 Add `version: "2.5.3"` and `schedule: "*/5 * * * *"` under `vault.qmd` in the `agent.yml` heredoc of `setup.sh` (around `setup.sh:1124-1125`), keeping `enabled: $vault_qmd_enabled`.
- [ ] T005 [P] Add `version: "2.5.3"` and `schedule: "*/5 * * * *"` under `vault.qmd` in `tests/fixtures/sample-agent-with-vault.yml` (currently only `enabled: false`).
- [ ] T006 Create `docker/scripts/lib/qmd_index.sh` as a sourceable shell: shebang/`# shellcheck shell=bash` header, a `BASH_SOURCE`/`QMD_INDEX_NO_RUN` side-effect guard, and `source` of `backup_vault.sh` (image path first, repo-relative fallback for host tests — mirror how `start_services.sh:43-47` sources `plugin-install.sh`). No QMD functions yet — just a file that sources cleanly. This unblocks all `qmd-*.bats`.
- [ ] T007 [P] Confirm the render engine emits `$VAULT_QMD_VERSION` from `vault.qmd.version` (3-level flatten, same as the existing `VAULT_QMD_ENABLED`); add a `tests/render.bats` (or `mcp-json.bats`) assertion if the flatten is not already exercised. No code change expected — `scripts/lib/render.sh` already flattens `section.key → $SECTION_KEY`.

**Checkpoint**: `bats tests/` still green; `qmd_index.sh` sources without side effects.

---

## Phase 3: User Story 1 — Auto-setup del RAG al boot (Priority: P1) 🎯 MVP

**Goal**: with QMD enabled, first boot downloads the model + builds the index, idempotently, backgrounded, fail-silent.

**Independent test**: stub `bunx`; call `qmd_setup_if_needed` → setup runs once; second call no-ops; failure leaves no sentinel (retries next boot).

### Tests (write first — MUST fail before implementation)

- [ ] T008 [P] [US1] `tests/qmd-setup.bats`: with a stub `bunx` on PATH and a vault fixture, assert `qmd_setup_if_needed` runs `collection add`+`update`+`embed` once and creates the `.qmd-setup-ok` sentinel + a stub `index.sqlite` (Scenario A.2).
- [ ] T009 [P] [US1] In `tests/qmd-setup.bats`: assert a second `qmd_setup_if_needed` call is a no-op when sentinel + `index.sqlite` exist (no `bunx` invocation) — idempotency, FR-003 (Scenario A.3).
- [ ] T010 [P] [US1] In `tests/qmd-setup.bats`: assert a no-op + return 0 when `vault.qmd.enabled=false` (FR-012); and a partial-state re-run (sentinel removed, index kept → re-runs) (Scenario A.4).
- [ ] T011 [P] [US1] In `tests/qmd-setup.bats`: with a failing stub `bunx`, assert `qmd_setup_if_needed` returns 0 (fail-silent) and does NOT write the sentinel (Scenario A.5, FR-011).
- [ ] T012 [P] [US1] `tests/start-services-qmd.bats`: source `start_services.sh` with `START_SERVICES_NO_RUN=1`; assert `setup_qmd_if_needed` is a no-op when disabled, and (with a stub `qmd_setup_if_needed`) that it is invoked from `boot_side_effects` after `seed_vault_if_needed` and runs **backgrounded** (returns immediately).

### Implementation (make tests pass)

- [ ] T013 [US1] In `docker/scripts/lib/qmd_index.sh`: implement `qmd_pkg [agent_yml]` (→ `@tobilu/qmd@$(yq -r '.vault.qmd.version // "2.5.3"')`) and `qmd_cache_root [agent_yml]` (→ `$HOME/.cache/qmd`, test-overridable) per contracts/qmd-cli.md.
- [ ] T014 [US1] In `docker/scripts/lib/qmd_index.sh`: implement `qmd_setup_if_needed [agent_yml]` — enabled-guard, sentinel+`index.sqlite` idempotency, `timeout`-bounded `bunx $(qmd_pkg) collection add <vault_root>`/`update`/`embed`, touch sentinel on success, fail-silent return 0 (data-model E5, contract).
- [ ] T015 [US1] In `docker/scripts/start_services.sh`: source `qmd_index.sh` (image path + repo fallback); add `setup_qmd_if_needed()` that gates on `vault.qmd.enabled` and runs `qmd_setup_if_needed` **backgrounded in a `( timeout <T> … ) &` subshell** (mirror `_trigger_identity_backup`); call it from `boot_side_effects()` right after `seed_vault_if_needed` (D4, FR-011).
- [ ] T016 [US1] Add the `COPY scripts/lib/qmd_index.sh /opt/agent-admin/scripts/lib/qmd_index.sh` line to `docker/Dockerfile` (with the other lib COPYs ~L213-220). No chmod needed (sourced, not exec'd).

**Checkpoint**: `bats tests/qmd-setup.bats tests/start-services-qmd.bats` green; `shellcheck` clean. US1 deliverable on its own (semantic search comes online after first boot).

---

## Phase 4: User Story 2 — Reindexación automática con doble disparador (Priority: P1)

**Goal**: vault changes reindex automatically — watcher (immediate, debounced) + cron backstop — via one flock-guarded, hash-debounced routine.

**Independent test**: stub `bunx`/`inotifywait`/`heartbeatctl`; unchanged vault → skip; changed → one reindex; concurrent → one runs; burst → one call; cron line present when enabled.

### Tests (write first — MUST fail before implementation)

- [ ] T017 [P] [US2] `tests/qmd-index.bats`: assert `qmd_reindex` records `last_status:"skipped"` and runs no `embed` when the vault hash equals `qmd-index.json.hash` (FR-008, Scenario B.2).
- [ ] T018 [P] [US2] In `tests/qmd-index.bats`: after a vault content change, assert `qmd_reindex` runs `update`+`embed` once, updates `hash`, writes `last_status:"indexed"` (Scenario B.3); validate `qmd-index.json` shape (E6).
- [ ] T019 [P] [US2] In `tests/qmd-index.bats`: hold the `flock` on `.reindex.lock` in the background, then assert a concurrent `qmd_reindex` logs "skip", returns 0, runs no `embed`, leaves state untouched (FR-007, Scenario C).
- [ ] T020 [P] [US2] `tests/qmd-watch.bats`: with a stub `inotifywait` emitting a burst of events and a counting stub `heartbeatctl`, assert exactly ONE `qmd-reindex` call after the debounce window (FR-005, Scenario D.1–D.2); use a short `QMD_WATCH_DEBOUNCE` for the test.
- [ ] T021 [P] [US2] In `tests/qmd-watch.bats`: with `inotifywait` absent from PATH, assert `qmd_watch.sh` logs the degrade message and exits 0 (Scenario D.3).
- [ ] T022 [P] [US2] `tests/qmd-reindex-cmd.bats`: assert `heartbeatctl reload` emits the `*/5 * * * * … heartbeatctl qmd-reindex …` cron line when `vault.qmd.enabled=true`; honors a `vault.qmd.schedule` override; omits the line when disabled (Scenario E). Follow `tests/backup-vault-cmd.bats` (HEARTBEATCTL_WORKSPACE/CRONTAB_FILE overrides).
- [ ] T023 [P] [US2] In `tests/qmd-reindex-cmd.bats`: assert `heartbeatctl qmd-reindex --dry-run` resolves + reports without `embed`, and the `qmd-reindex` dispatch exists.

### Implementation (make tests pass)

- [ ] T024 [US2] In `docker/scripts/lib/qmd_index.sh`: implement `qmd_last_hash`/`qmd_write_state` (mirror `vault_last_hash`/`vault_write_state`) and `qmd_reindex [agent_yml]` — enabled-guard, non-blocking `flock -n` on `.reindex.lock`, hash-debounce via reused `vault_hash`, `timeout`-bounded `bunx $(qmd_pkg) update`+`embed`, atomic `qmd-index.json`, always return 0 (data-model E6/E7, contract).
- [ ] T025 [US2] Create `docker/scripts/qmd_watch.sh` — `inotifywait` availability guard (degrade+exit 0), `inotifywait -r -m -e modify,create,delete,move <vault_root>`, ~15s debounce coalescing to one `heartbeatctl qmd-reindex`, resilient watch loop, env-overridable interval/binaries for tests; `BASH_SOURCE` guard (contract).
- [ ] T026 [US2] In `docker/scripts/heartbeatctl`: add `cmd_qmd_reindex` (mold on `cmd_backup_vault`: `--dry-run` flag → `qmd_reindex`/dry-run via sourced `qmd_index.sh`); add `qmd-reindex) cmd_qmd_reindex "$@" ;;` dispatch in `main`; add a help line.
- [ ] T027 [US2] In `docker/scripts/heartbeatctl::cmd_reload`: add the conditional `qmd_reindex_line` (guard `vault.qmd.enabled=true`, schedule `vault.qmd.schedule // "*/5 * * * *"`, command `/usr/local/bin/heartbeatctl qmd-reindex >> …/logs/qmd-reindex.log 2>&1`) after the token-health line, and add `${qmd_reindex_line}` to the staging-crontab heredoc (research D7 insertion point).
- [ ] T028 [US2] In `docker/scripts/start_services.sh`: when `vault.qmd.enabled`, start `qmd_watch.sh &` at boot (record PID under `$WATCHDOG_RUNTIME_DIR/qmd-watch.pid`); in `_run_watchdog`'s 2s poll add a branch that respawns `qmd_watch.sh` if its recorded PID is dead — DETERMINISTIC liveness only, no tmux scraping (contract; Principle IV; CLAUDE.md bridge-watchdog caveat).
- [ ] T029 [US2] Add `COPY scripts/qmd_watch.sh /opt/agent-admin/scripts/qmd_watch.sh` + `chmod +x` to `docker/Dockerfile` (with the other exec scripts ~L202-210).

**Checkpoint**: `bats tests/qmd-index.bats tests/qmd-watch.bats tests/qmd-reindex-cmd.bats tests/start-services-qmd.bats` green; `shellcheck` clean. US1+US2 = functional MVP (self-managing, fresh RAG).

---

## Phase 5: User Story 3 — Versión reproducible y configuración validada (Priority: P2)

**Goal**: pinned, single-sourced version + schema validation of `vault.qmd.*`.

**Independent test**: template renders the pin (not `@latest`); schema rejects a bad `vault.qmd.*`, accepts a good one.

### Tests (write first — MUST fail before implementation)

- [X] T030 [P] [US3] `tests/mcp-json.bats` + `tests/scaffold.bats`: assert `qmd.args[0] == "@tobilu/qmd@2.5.3"`; `args[1] == "mcp"`.
- [X] T031 [P] [US3] `tests/scaffold.bats`: assert scaffolded `agent.yml` has `vault.qmd.version == "2.5.3"` and `vault.qmd.schedule == "*/5 * * * *"`.
- [X] T032 [P] [US3] `tests/schema-validate.bats`: vault.qmd.* cases — reject `ture` boolean, reject empty version, accept well-formed block, legacy-safe absent, and enabled-without-version validates (regenerate backfills).

### Implementation (make tests pass)

- [X] T033 [US3] `modules/mcp-json.tpl` (L75): `"@tobilu/qmd@{{VAULT_QMD_VERSION}}"` (single-source the pin from `agent.yml`, D2). Render fallback handled by setup.sh backfill (contracts/agent-yml-schema.md).
- [X] T034 [US3] `scripts/lib/schema.sh`: `.vault.qmd.enabled` in `_SCHEMA_BOOLEANS`; `.vault.qmd.version` + `.vault.qmd.schedule` in `_SCHEMA_OPTIONAL_NONEMPTY` (no `// ""` `_schema_get` regression).

**Checkpoint**: `bats tests/mcp-json.bats tests/scaffold.bats tests/schema.bats` green.

---

## Phase 6: DOCKER_E2E (gated integration) & Polish

**Purpose**: prove the integration seams the host suite can't, and finish release discipline.

- [X] T035 [P] `tests/docker-e2e-qmd.bats` WRITTEN: QMD-enabled vault → asserts first-boot setup (`index.sqlite` + `.qmd-setup-ok`, polled), cron-path reindex (`heartbeatctl qmd-reindex` → `last_status=indexed`), inotify-under-bind-mount watcher reindex (hard-asserted on Linux, VirtioFS-tolerant on macOS), and `cap_drop: ALL` via `docker inspect`. `bunx` stubbed (real ~300MB model is network-gated, out of scope). NOT YET EXECUTED — pending image build (T039).
- [X] T036 FULL host suite `bats tests/` = 710 ok / 0 fail / 15 skip; `shellcheck -S error` clean over every touched shell file. Post-adversarial-review fixes included.
- [X] T037 [P] `CHANGELOG.md` 0.4.4 entry finalized (auto-setup, dual-trigger reindex, `inotify-tools`, pin `@tobilu/qmd@2.5.3`, schema validation, version correction).
- [X] T038 [P] `docs/architecture.md` QMD paragraph updated: auto-setup (`collection add`+`update`+`embed`) + dual-trigger reindex + single-sourced pin.
- [ ] T039 Rebuild the image and re-run `DOCKER_E2E=1 bats tests/` until green (plan's final validation gate) — REMAINING.

---

## Dependencies & Execution Order

```text
Setup (T001-T003)
  └─▶ Foundational (T004-T007)         # config shape + sourceable lib shell
        ├─▶ US1 (T008-T016)            # tests → qmd_setup_if_needed → supervisor wiring → COPY
        │     └─▶ US2 (T017-T029)      # reindex routine reuses the lib + cache root from US1
        └─▶ US3 (T030-T034)            # pin + schema — independent of US1/US2 internals
              └─▶ Polish/E2E (T035-T039)
```

- **US1 → US2**: US2's `qmd_reindex` lives in the same lib and reuses `qmd_cache_root`/sentinel layout from US1; do US1 first.
- **US3 is independent** of US1/US2 code paths (template + schema only) and may proceed in parallel with US1/US2 once Foundational is done.
- **E2E/Polish last**: needs all impl present + the image rebuilt.

## Parallel Opportunities

- Setup: T002, T003 in parallel.
- Foundational: T005, T007 in parallel with T004/T006.
- US1 tests T008–T012 all `[P]` (same new test files, independent assertions — author together).
- US2 tests T017–T023 all `[P]`.
- US3 entirely `[P]` against US1/US2 after Foundational.
- Polish: T037, T038 in parallel.

## Implementation Strategy

- **MVP = US1 + US2** (both P1): a vault whose semantic index sets itself up and stays fresh with zero manual steps. US1 alone is a shippable increment (search online after first boot); US2 adds freshness.
- **US3 (P2)** hardens reproducibility/validation; can land in the same PR or immediately after.
- Test-first throughout (Principle III): each `[US*]` block's tests are authored and seen failing before its implementation tasks.
- Two new image-baked files (`qmd_index.sh`, `qmd_watch.sh`) — verify their `COPY` lines (T016, T029) before any DOCKER_E2E run, or the build fails the asset sanity check.

## Notes

- Total: **39 tasks** — Setup 3, Foundational 4, US1 9, US2 13, US3 5, Polish/E2E 5.
- Every `bunx`/`qmd` call timeout-bounded + fail-silent; supervisor never blocks before the watchdog.
- No new container capability/mount/socket (Principle II); model/index/state under `.state` (Principle V); pin single-sourced (Principle VI).
