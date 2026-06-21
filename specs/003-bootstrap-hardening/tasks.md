# Tasks: Bootstrap hardening

**Feature**: `003-bootstrap-hardening` · **Spec**: [spec.md](./spec.md) · **Plan**: [plan.md](./plan.md) · **Research**: [research.md](./research.md)

Test-first (constitution Principle III): each story writes a RED bats test, then the minimal
change to GREEN it. 8/9 stories are host-only (`bats tests/`, no Docker); only Story H (US3) adds a
`DOCKER_E2E=1` behavioral test alongside its host prompt-text test.

**Shared-file note**: Stories A, C, G all edit `docker/scripts/start_services.sh`; they are NOT
parallel with each other. Likewise D and E both edit `scripts/lib/wizard-validators.sh` +
`setup.sh`. `[P]` is marked only where file sets are disjoint.

## Phase 1: Setup

- [ ] T001 Run `bats tests/` and record the baseline (green except the known env-dependent `#105`); this is the red/green reference for the feature.

## Phase 2: Foundational

No foundational/blocking tasks — each story is independent and the test seams reuse existing
patterns (`START_SERVICES_NO_RUN=1` sourcing in `tests/start-services-watchdog.bats`; `load_lib`
in `tests/helper.bash`). Proceed directly to user stories.

## Phase 3: User Story 1 — Silent failures become loud/automatic (P1) 🎯 MVP

**Goal**: After `/login`, plugins auto-install with no manual restart (A); no surprise-public forks (B); plugin failures are distinct, retried, and surfaced (C).

**Independent Test**: `bats tests/watchdog-auth-flip-detection.bats tests/fork-commands.bats tests/start-services-plugin-install.bats` all green; a scaffold→`/login`→`/exit` cycle (no restart) ends fully plugged.

### Tests for US1 (write first, confirm RED)

- [x] T002 [P] [US1] Write red test `tests/watchdog-auth-flip-detection.bats`: source `docker/scripts/start_services.sh` with `START_SERVICES_NO_RUN=1`; in a tmpdir `$HOME`, mock `~/.claude/.credentials.json` + a plugin cache with `.installed-ok`; assert the absent→present flip triggers a stubbed re-install exactly once, and that no-credentials / already-present ticks do not. Confirm it FAILS.
- [x] T003 [P] [US1] Write red test in `tests/fork-commands.bats`: stub `gh` in `$PATH` to return `visibility=public`; assert the wizard emits the public-fork warning and calls `ask_choice` with `[proceed-public, disable-fork]`; `disable-fork` ⇒ `fork_enabled=false`, `proceed-public` ⇒ `fork_private` unchanged. Confirm it FAILS.
- [x] T004 [P] [US1] Write red test `tests/start-services-plugin-install.bats`: stub `claude` in `$PATH`; assert `retry_plugin_install_bounded` logs "not authenticated" vs "install failed" distinctly, retries non-auth failures 3×, writes `.state/plugin-install-failures.jsonl` on residual failure, and clears the entry on a later success. Confirm it FAILS.

### Implementation for US1

- [x] T005 [US1] In `docker/scripts/start_services.sh` (`_run_watchdog`, ~764-803), track the prior `~/.claude/.credentials.json` existence per tick; on absent→present, **actively kick the tmux session** (kill → the watchdog respawns it) so `ensure_all_plugins_installed` + `next_tmux_cmd` run immediately, even if the operator stays logged in (passive wait-for-respawn rejected). Extract the tick logic into a testable helper (e.g. `_watchdog_tick`). NO tmux-pane scraping. GREEN T002.
- [x] T006 [P] [US1] Add `gh_get_repo_visibility()` to `scripts/lib/wizard.sh` and wire the warning + `ask_choice` into the `setup.sh` fork block (between the template-url and PAT prompts, ~487); persist the choice to `fork_enabled`/`fork_private` before the agent.yml heredoc; in a non-interactive run (no TTY) default the conflict to disable-fork + a logged notice (FR-B4); FAIL LOUD if the `gh api` probe errors. GREEN T003.
- [x] T007 [US1] Create `docker/scripts/lib/plugin-install.sh::retry_plugin_install_bounded(spec, max=3)` and refactor `ensure_plugin_installed_one`/`ensure_all_plugins_installed` (`docker/scripts/start_services.sh` 168-214) to use it: distinct logs, bounded retry with a short fixed backoff (1s, then 2s), write/clear `.state/plugin-install-failures.jsonl`. **Sanitize `last_error`** (first line only; strip token-like strings `ghp_*`/`xox*`/`*_TOKEN=…`) before persisting (FR-C4, Principle V). Add the sanitizer to T004's red assertions first. (After T005 — same file.) GREEN T004.
- [x] T008 [US1] Surface residual failures. **Write the RED fixture-based assertion first** (host, no Docker): a fixture `.state/plugin-install-failures.jsonl` ⇒ `cmd_doctor` prints the `✗` + retry line; an empty file ⇒ the `✓` line. Then add the check to `scripts/agentctl::cmd_doctor` (293-559) and the failed-plugins section to the NEXT_STEPS template — **confirm the exact template filename first** (`ls modules/ | grep -i next`). GREEN.

**Checkpoint**: US1 (MVP) independently testable — `bats tests/` green, the 3 P1 files green.

## Phase 4: User Story 2 — Input validation + doc/wizard sync (P2)

**Goal**: Bad destinations and spaced names are caught/corrected up front (D, E); the quickstart doc can't drift from the wizard (F).

**Independent Test**: `bats tests/wizard-validators.bats tests/agent-name-normalization.bats tests/quickstart-doc.bats` green; a non-absolute destination and a spaced name are rejected/normalized before scaffold.

### Tests for US2 (write first, confirm RED)

- [ ] T009 [P] [US2] Add red cases to `tests/wizard-validators.bats` for `validate_destination_path`: non-absolute reject, leading `~` expand, mid-path `~` reject, `/home/...` on Darwin warn, `/Users/...` accept. Confirm they FAIL.
- [ ] T010 [P] [US2] Write red test `tests/agent-name-normalization.bats` for `normalize_agent_name`: "Rodri Cenco Admin"→"rodri-cenco-admin", "my  --  agent"→"my-agent", " -leading"→"leading"; idempotent on an already-normalized name. Confirm it FAILS.
- [ ] T011 [P] [US2] Add a red case to `tests/quickstart-doc.bats`: source `scripts/lib/mcp-catalog.sh`; for each `mcp_catalog_list optional` id, assert it appears (as `MCPS_<ID>`) in the wizard-order section of BOTH `docs/agentic-quickstart.es.md` and `.en.md`. Confirm it FAILS.

### Implementation for US2

- [ ] T012 [US2] Implement `validate_destination_path()` in `scripts/lib/wizard-validators.sh` (mirror `validate_workspace_path`); wire `ask_validated` into the `setup.sh` destination prompt (~446), the review edit action (~894), and the `scaffold_destination` pre-check (~1547). GREEN T009.
- [ ] T013 [US2] Extract `normalize_agent_name()` into `scripts/lib/wizard-validators.sh`; replace the `tr` pipeline in `setup.sh` (399-408) with it + show raw/normalized + `ask_yn` confirm. (After T012 — same files.) GREEN T010.
- [ ] T014 [P] [US2] Update `docs/agentic-quickstart.es.md` and `docs/agentic-quickstart.en.md`: insert the 6 optional catalog-MCP prompts (aws, firecrawl, google-calendar, playwright, time, tree-sitter) as the step between heartbeat-notif and Atlassian. GREEN T011.

**Checkpoint**: US2 green; existing suite no regressions.

## Phase 5: User Story 3 — Noise + polish (P3)

**Goal**: No identity-backup spam when fork-less (G); CLAUDE.md refresh preserves injected sections (H); multi-line persona via `role_file` (I).

**Independent Test**: `bats tests/start-services-watchdog.bats tests/wizard-container-refresh.bats tests/render.bats` green; `DOCKER_E2E=1 bats tests/docker-e2e-claude-md-refresh.bats` green; a fork-less agent logs zero backup lines.

### Tests for US3 (write first, confirm RED)

- [ ] T015 [P] [US3] Add a red case to `tests/start-services-watchdog.bats`: source with `START_SERVICES_NO_RUN=1`; agent.yml fixture WITHOUT `scaffold.fork.url`; stub `_trigger_identity_backup`; assert `_check_identity_backup` does NOT call it and logs nothing. Confirm it FAILS.
- [ ] T016 [P] [US3] Write red host test `tests/wizard-container-refresh.bats`: capture the `claude --print` refresh prompt HEREDOC from `docker/scripts/wizard-container.sh` WITHOUT executing `claude`; assert it contains "preserve ALL" / "scan … section headers" / "do not edit or reorder". Confirm it FAILS.
- [ ] T017 [P] [US3] Write red test in `tests/render.bats` + add a `role_file` field to fixture `tests/fixtures/sample-agent-with-vault.yml`: with `role_file` set, `render_load_context` exports `AGENT_ROLE_MULTILINE` == file content; the template injects it; a missing `role_file` path makes render fail loud. **Also add a `tests/regenerate.bats` case** asserting `role_file` survives `./setup.sh --regenerate` (field preserved, content re-read) — covers FR-X1 for the new field. Confirm it FAILS.

### Implementation for US3

- [ ] T018 [P] [US3] Add a fork-presence early-exit guard at the top of `_check_identity_backup` (`docker/scripts/start_services.sh` 729-758): read `.scaffold.fork.url`; if empty/null, `return 0` before hashing/logging (mirror `heartbeatctl::_bi_run`). GREEN T015.
- [ ] T019 [P] [US3] Rewrite the `claude --print` prompt in `docker/scripts/wizard-container.sh` (56-76): preserve ALL existing `## ` sections verbatim, only ADD missing command/architecture/test sections, Edit-not-Write, no-op if complete; keep the 90s timeout + skip-on-error. GREEN T016.
- [ ] T020 [P] [US3] Implement `role_file`: `--role-file PATH` flag in `setup.sh::parse_args` (350-373) + write `role_file:` in the agent.yml heredoc (986-1001); if the file is outside the destination workspace, copy it in (`personas/<name>.md`) and store the relative path (FR-I2); `scripts/lib/render.sh` reads it → `AGENT_ROLE_MULTILINE` (fail loud if set-but-missing); `modules/claude-md.tpl` (7-11) conditional inject; `scripts/lib/schema.sh` optional leaf. GREEN T017.
- [ ] T021 [US3] Add the opt-in `DOCKER_E2E=1` test `tests/docker-e2e-claude-md-refresh.bats`: scaffold, inject `## Marker`, boot (triggers the refresh), assert `## Marker` survives byte-for-byte and a commands section is added. (After T019.)

**Checkpoint**: US3 green; `bats tests/` green with no Docker; H's DOCKER_E2E test green opt-in.

## Phase 6: Polish & Cross-Cutting

- [ ] T022 [P] Add `CHANGELOG.md` `[Unreleased]` entries (Fixed/Added) covering the 9 stories (A–I).
- [ ] T023 [P] Bump `VERSION` (**MINOR** — new backward-compatible user surface: `--role-file`, fork warning, name-normalize confirm, doctor failed-plugins); confirm `agentctl doctor` surfaces the new `meta.launcher_version`.
- [ ] T024 Run `shellcheck -S error` on all touched shell (`setup.sh`, `scripts/lib/{wizard,wizard-validators,render,schema}.sh`, `docker/scripts/{start_services,wizard-container}.sh`, `docker/scripts/lib/plugin-install.sh`, `scripts/agentctl`); fix findings.
- [ ] T025 Run the full default suite `bats tests/` — all green, no regressions (the ~195 existing + the new files). Then `DOCKER_E2E=1 bats tests/docker-e2e-claude-md-refresh.bats`.

## Dependencies & Execution Order

- **Phases are priority-ordered**: P1 (US1) → P2 (US2) → P3 (US3) → Polish. Each story phase is an independently shippable increment.
- **Within a story**: the RED test precedes its implementation (strict). T005 GREENs T002, T006→T003, T007→T004, T012→T009, T013→T010, T014→T011, T018→T015, T019→T016, T020→T017.
- **Shared-file serialization**: T005 → T007 → T018 all edit `start_services.sh` (across phases, sequential); T012 → T013 both edit `wizard-validators.sh` + `setup.sh`.
- **Polish** (T022–T025) after all stories; T022/T023 are `[P]`.

## Parallel Execution Examples

- **US1 tests**: T002, T003, T004 in parallel (3 different test files).
- **US1 impl**: T006 (setup.sh/wizard.sh) runs parallel to T005/T007 (start_services.sh); T005→T007 serialize; T008 (agentctl/next-steps) after T007.
- **US2 tests**: T009, T010, T011 in parallel. **US2 impl**: T014 (docs) parallel to T012→T013.
- **US3**: T015/T016/T017 tests parallel; T018/T019/T020 impl parallel (disjoint files: start_services.sh / wizard-container.sh / setup.sh+render+tpl+schema).

## Implementation Strategy

**MVP = US1 (T001–T008)**: the three silent-failure fixes — the traps that break every new
operator's happy path. Ship/verify P1, then layer P2 (validation/doc-sync) and P3 (polish)
incrementally. Each phase keeps `bats tests/` green with no Docker; H's behavioral proof is the
single opt-in `DOCKER_E2E=1` test.
