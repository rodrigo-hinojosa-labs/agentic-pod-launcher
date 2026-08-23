# Tasks: Channel interactive-prompt (AskUserQuestion) guard

**Feature**: 031-channel-askuserquestion-guard | **Branch**: `031-channel-askuserquestion-guard`
**Spec**: [spec.md](./spec.md) · **Plan**: [plan.md](./plan.md) · **Research (feasibility gate MEASURED)**: [research.md](./research.md)

Test-first is NON-OPTIONAL here (Constitution Principle III). Each behavior ships a
host-runnable `bats` test written to fail first. Anchors verified in-repo:
`setup.sh` config `:1230` / backfill `:2072-2083` / render gate `:2337-2345`;
`scripts/lib/schema.sh:65-67` (`_SCHEMA_BOOLEANS`); `modules/stop-hook*.tpl`;
`docker/scripts/start_services.sh:784` (`pre_install_stop_hook`); `scripts/local/agent-login.sh`;
`docker/scripts/apply_telegram_typing_patch.py` (v5 marker, upgrade cascade, `bot.api.sendMessage`).
Patterns: `tests/reply-guard-config.bats`, `tests/stop-hook-guard.bats`, `tests/apply-telegram-patches.bats`.

## Phase 1: Setup

- [X] T001 Baseline: run `bats tests/` on bash 3.2.57 AND 5.x, record `ok/not ok` counts (regression baseline for T019). No code change. — 1262 ok / 4 not ok on BOTH arms (byte-identical counts); the 4 confirmed pre-existing flakes (3 pass in isolation — concurrent full-suite contention, documented project pattern) + 1 genuine drift (`schema: every {{VAR}} placeholder…`, closed by T004b below).

## Phase 2: Foundational (blocking — config is a prerequisite for the hook render/install)

- [X] T002 [P] Test (RED): write `tests/askq-guard-config.bats` per contract `contracts/hook-install-and-config.md` config matrix — `--regenerate` backfills `features.askuserquestion_guard.enabled=true` with telegram plugin, `false` without, `max_attempts=1`, and preserves an operator-set `enabled:false/max_attempts:2` (`has()` guard). Mirror `tests/reply-guard-config.bats`. (FR-007, SC-006)
- [X] T003 Config foundational in `setup.sh`: add `features.askuserquestion_guard: {enabled, max_attempts: 1}` to the wizard heredoc beside `reply_guard` (`:1163-1168`, `:1230-1233`); backfill in `regenerate()` with `has()` — NOT `//` — `enabled` derived from a `^telegram@` entry in `plugins[]` (`:2095-2103`); `render.sh`'s generic flatten produces `FEATURES_ASKUSERQUESTION_GUARD_ENABLED`/`_MAX_ATTEMPTS` automatically (same mechanism as `reply_guard`, no `render.sh` change needed). (FR-007) → makes T002 GREEN.
- [X] T004 Add `.features.askuserquestion_guard.enabled` to `_SCHEMA_BOOLEANS` in `scripts/lib/schema.sh:65-67` (touchpoint — mirrors `reply_guard.enabled`), so schema validation accepts the new toggle.
- [X] T004b (found during T001 baseline) Add `features.askuserquestion_guard: {enabled: true, max_attempts: 1}` to `tests/fixtures/sample-agent-with-vault.yml` and `tests/fixtures/sample-agent.yml` — the new `{{FEATURES_ASKUSERQUESTION_GUARD_*}}` placeholders in `askq-guard.sh.tpl` need a fixture source or `schema: every {{VAR}} placeholder…` (tests/schema.bats) correctly flags drift. Mirrors the existing `reply_guard` block in both fixtures.

## Phase 3: User Story 1 — the guard intercepts and redirects (Priority: P1)

**Goal**: A channel turn calling `AskUserQuestion` is intercepted before it blocks and
the agent is redirected to ask via the reply tool; console turns and unknown-origin
turns are untouched (fail open); bounded by `max_attempts`.
**Independent test**: `tests/askq-guard.bats` exercises the C1–C6 decision table with
fixture payloads — no live agent.

- [X] T005 [P] [US1] Test (RED): write `tests/askq-guard.bats` per `contracts/pretooluse-guard-io.md` — C1 disabled → no-op; C2 empty/non-JSON stdin → allow; C3 `tool_name != AskUserQuestion` → allow; C4 marker absent → **fail open** (no output); C5 marker present + under cap → deny+**redirect** JSON (`permissionDecision:"deny"` + redirect reason) + one stderr line + counter increment; C6 marker present + at cap → deny+**terminal give-up** JSON (`permissionDecision:"deny"` + terminal "stop retrying" reason — the prompt never opens, NOT an allow) + give-up marker written once + stderr line. Assert C6 still emits a deny (never empty output). Stub `HOME`/marker/counter/stderr via env (`REPLY_GUARD_MARKER` etc.). Mirror `tests/stop-hook-guard.bats`. (FR-001..FR-004, FR-008, FR-010) — 13/13 GREEN.
- [X] T006 [US1] Create `modules/askq-guard.sh.tpl` (rendered → `scripts/hooks/askq-guard.sh`): bake `{{FEATURES_ASKUSERQUESTION_GUARD_ENABLED}}`/`{{FEATURES_ASKUSERQUESTION_GUARD_MAX_ATTEMPTS}}`; read stdin; gate `tool_name=="AskUserQuestion"`; origin = presence of `${HOME}/.claude/channels/telegram/pending-reply.json` (fail OPEN if absent); per-`prompt_id` counter under `askq-guard-attempts/`; under cap → emit deny+redirect JSON and increment; at cap → emit deny+**terminal give-up** JSON (never allow-through: the prompt must never open on a confirmed channel turn) and write `askq-guard-giveup.json` once (only if absent); one stderr line per fire; `set +e`, exit 0 EVERY path (fail-silent). (FR-001..FR-004, FR-008; research D3/D4) → makes C1–C6 GREEN.
- [X] T007 [US1] Render gate in `setup.sh` `regenerate()` (`:2347-2354`, mirrors the `028` block at `:2340-2346`): when `FEATURES_ASKUSERQUESTION_GUARD_ENABLED=true`, render `scripts/hooks/askq-guard.sh` (+ the installer from T008) and `chmod +x`; disabled → not rendered. (FR-007, SC-006)
- [X] T008 [US1] Install helper for PreToolUse: added a **sibling** `modules/askq-guard-install.sh.tpl` (028's `stop-hook-install.sh.tpl` left untouched, per its own file header calling this the intended path) — additive idempotent `jq` merge into `.hooks.PreToolUse` with `matcher:"AskUserQuestion"`, touching ONLY that key (never clobbers `.hooks.Stop`/permissions/plugins), base `{}` if absent, exit 0. (contract `hook-install-and-config.md`)
- [X] T009 [P] [US1] Test: settings-merge coverage — folded into `tests/askq-guard.bats` (not a dedicated file; keeps the hook and its installer's tests together) — the installer adds the PreToolUse+matcher entry, is idempotent on re-run, and leaves a pre-existing `.hooks.Stop` entry intact. (FR-005)
- [X] T010 [US1] Boot + local wiring: `docker/scripts/start_services.sh` gets `pre_install_askq_hook()` beside `pre_install_stop_hook()`, called in `start_session()`; `modules/local-login.sh.tpl` gets the matching install call (the real path — `scripts/local/agent-login.sh` doesn't exist as a source file, it's the rendered output); `scripts/heartbeat/heartbeat.sh`'s isolated config now does `del(.hooks.Stop) | del(.hooks.PreToolUse)` (extended `tests/heartbeat-isolation.bats` with a dedicated test, 11/11 GREEN). (FR-006, FR-007)

## Phase 4: User Story 1 (give-up delivery) — operator never left in silence (Priority: P1)

**Goal**: On give-up (cap reached), the operator receives one explicit channel message,
delivered by the plugin's existing send path (no new privilege in the hook).
**Independent test**: patcher fixture asserts the give-up hunk reads/sends/clears.

- [X] T011 [P] [US1] Test (RED): extend `tests/apply-telegram-patches.bats` — the give-up hunk is present (reads `askq-guard-giveup.json`, sends via `bot.api.sendMessage(chat_id, …)`, deletes the marker), checked at **both** pinned triggers (on each keep-alive tick AND on keep-alive (re)start for the next inbound turn), delivers exactly once (delete-on-send), gated by its own marker, idempotent, fail-silent on anchor drift. (FR-002, Q2; contract `giveup-and-warning.md` A) — 7 tests, all GREEN.
- [X] T012 [US1] Add the give-up read/send/clear hunk to `docker/scripts/apply_telegram_typing_patch.py` (`MARKER_ASKQ_GIVEUP`, `apply_askq_giveup()`), reusing the plugin's existing `bot.api.sendMessage` path. Wired at the two pinned triggers — the keep-alive interval callback (every tick) and the keep-alive (re)start for the next inbound turn — with delete-on-send so exactly one message is delivered and the triggers can never double-send; never the question text or a secret. (FR-002; research D5; contract `giveup-and-warning.md` A) → makes T011 GREEN.

## Phase 5: User Story 2 — typing warning names the interactive-prompt cause (Priority: P3)

**Goal**: The typing-timeout warning (v5) also names "blocked in an interactive prompt
the channel can't answer", still asserting no single definite cause.
**Independent test**: patcher fixture asserts v6 + the new cause text.

- [X] T013 [P] [US2] Test (RED): extend `tests/apply-telegram-patches.bats` — `MARKER_TYPING` becomes v6; the warning names the interactive-prompt cause; cascade `v1→…→v6` ratchets a v5 fixture up; idempotent; fail-silent if the `warnMsg` anchor drifted. (FR-009, SC-004; contract `giveup-and-warning.md` B)
- [X] T014 [US2] Bumped `MARKER_TYPING` v5→v6 (new `MARKER_TYPING_V5` const for the intermediate state) and added `upgrade_typing_v5_to_v6` mirroring `upgrade_typing_v4_to_v5`; extended `_V6_WARNMSG` with the interactive-prompt cause (only before the LAST cause gets "o" — a transcription bug here broke 2 tests, found and fixed via byte-diff against the real generated text). (FR-009) → makes T013 GREEN, 43/43 in the full patcher suite.

## Phase 6: Polish & cross-cutting

- [X] T015 [P] `shellcheck -S error` clean (exact CI command, `-e SC1090,SC1091` over every `*.sh`/`*.bash` + `agentctl`/`heartbeatctl`) — rc=0. `.tpl` files are excluded by the CI `find` (only `*.sh`/`*.bash`); checked them too, ad-hoc, also clean. (Principle III)
- [X] T016 [P] Docs: `CHANGELOG.md` entry (top of `### Added`, above 030) + a `README.md` "Two-way Telegram chat" subsection (6th hook bullet: what the guard does, fail-open, terminal-deny-at-cap, give-up delivery, `agent.yml` toggle, stderr diagnosis). (FR-011)
- [X] T017 `VERSION` bump 0.21.0 → 0.22.0 (MINOR) — verified against `origin/main` (`git show origin/main:VERSION` = 0.21.0) before bumping (lesson 023). (FR-011)
- [X] T018 Mutation spot-check, 6/6 confirmed (each reverted, ≥1 named test failed, then restored — verified byte-identical via `diff` against a pre-mutation backup since these are untracked new files with no git baseline): marker origin/fail-open in T006 (C4 broke); counter cap in T006 (C6 + max_attempts=2 broke, 3 tests); C5 redirect deny emission in T006 (broke C5 + both C6 tests — same jq template); **C6 terminal-deny-at-cap in T006** (swapped back to allow-through → both C6 tests + max_attempts=2 broke — the I1 fix has real test coverage); give-up marker in T006 (2 C6 tests broke) and separately in T012 (4 patcher tests broke); telegram-derivation in T003's **backfill** block (not the wizard heredoc — the config tests exercise `--regenerate` on an existing agent.yml, so the backfill's own independent `grep telegram@` at `:2100` is the live code path, not the heredoc's `_aq_enabled` at `:1167`; 3 tests broke). (SC-002/SC-003)
- [X] T019 Regenerate-safety: two `./setup.sh --regenerate` render `askq-guard.sh` + `install-askq-guard-hook.sh` byte-identical (new dedicated test); an agent with NO telegram channel renders no `scripts/hooks/askq-guard.sh` (T002's test 5). (SC-006)
- [X] T020 Full suite `bats tests/` GREEN on bash 3.2.57 AND 5.x — **1299 ok / 0 not ok on BOTH arms**, exact math vs the T001 baseline (1266 + 33 new: 13 `askq-guard.bats` + 6 `askq-guard-config.bats` + 10 `apply-telegram-patches.bats` + 1 `heartbeat-isolation.bats` + 3 `docker-e2e-askq-guard.bats`). Only textual difference between arms: one PRE-EXISTING, documented bash-3.2-only skip (`qmd_watch … # skip host bash returns 1 … needs bash 4+`), unrelated to 031. Caught and fixed a self-introduced race in the process: the first bash5 run was launched a few tool-calls before `docker-e2e-askq-guard.bats` existed on disk, so it silently missed those 3 tests — not a real bash-version behavior difference, just a sequencing bug in this session; re-ran and confirmed true parity. (SC-005)
- [X] T021 [P] Write `tests/docker-e2e-askq-guard.bats` (gated `DOCKER_E2E=1`) per contract `giveup-and-warning.md` D: boot registers `.hooks.PreToolUse` with matcher `AskUserQuestion` + `askq-guard.sh` present; the baked hook denies+redirects a real fixture payload; baked patcher yields v6 warning + give-up hunk. Modeled on `tests/docker-e2e-warm-cache.bats`; parses and skips cleanly (`DOCKER_E2E` unset in this environment).
- [ ] T022 DEFERRED — `DOCKER_E2E=1 bats tests/docker-e2e-askq-guard.bats` on a Docker host. Gate of the Development Workflow (touches image-baked patcher + boot); closes at deploy.
- [ ] T023 DEFERRED — ferrari deploy gate: recreate `donna`; from Telegram drive a turn that calls `AskUserQuestion` and confirm the question arrives as a text reply (not a silent hang) and give-up delivers a message (SC-001 live).
- [X] T024 (Optional, recommended) `/speckit-analyze` for spec/plan/tasks consistency before `/speckit-implement` — ran; found I1 (C6 fail-open reintroduced the hang) and U1 (give-up delivery trigger unpinned), both MEDIUM, 0 CRITICAL/HIGH; remediated in spec.md/contracts/data-model.md/tasks.md before implementation started.

## Dependencies & order

- **Setup (T001)** → **Foundational (T002–T004)** blocks everything (config + schema).
- **US1 core (T005–T010)** depends on Foundational; T006 (hook) before T007 (render) before T008/T010 (install/wire); T005/T009 tests before their impl.
- **US1 give-up (T011–T012)** depends on T006 (writes the give-up marker) but the plugin hunk is independent of the hook script file → parallelizable with T007–T010.
- **US2 (T013–T014)** is independent of US1 (different concern, same patcher file → sequential with T011/T012 edits to `apply_telegram_typing_patch.py`).
- **Polish (T015–T024)** after the code lands; T022/T023 deferred to deploy.

## Parallel opportunities

- T002 (config test) ∥ T005 (hook test) ∥ T011/T013 (patcher tests) — different files, all RED-first.
- T015 (shellcheck) ∥ T016 (docs) ∥ T021 (e2e file authoring).
- Note: T011, T013, T014, T012 all edit `apply_telegram_typing_patch.py` → serialize the EDITS even though their tests are parallel.

## MVP scope

**US1 (T001–T010 + T011–T012)** is the MVP: the guard intercepts, redirects, and never
leaves the operator in silence on give-up. US2 (T013–T014) is a P3 honesty improvement
shippable independently.

## Independent test criteria

- **US1**: `tests/askq-guard.bats` C1–C6 + the give-up hunk assertion — deny+redirect on a
  channel turn, fail-open on console/unknown, bounded, give-up marker written.
- **US2**: `tests/apply-telegram-patches.bats` — v6 warning names the interactive-prompt cause.
