---
description: "Task list for feature 028 — channel reply-delivery guard"
---

# Tasks: Channel reply-delivery guard

**Input**: Design documents from `specs/028-channel-reply-guard/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md

**Tests**: REQUIRED, not optional — Principle III (test-first, host-runnable bats)
governs every behavior change in this repo. Each user story writes its bats
coverage FIRST (RED) before the implementation that turns it GREEN.

**Organization**: by user story. US1 (the guard) is the MVP; US2 (the honest
warning) is independent and can be built in parallel — EXCEPT both edit
`docker/scripts/apply_telegram_typing_patch.py` and
`tests/apply-telegram-patches.bats`, so those specific tasks are sequential.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel (different files, no dependency on an incomplete task)
- **[Story]**: US1 / US2 (Setup & Foundational & Polish carry no story label)
- Every task names its exact file path.

---

## Phase 1: Setup

- [X] T001 Record the host bats baseline before any change: run `PATH=/opt/homebrew/bin:$PATH bats tests/` (bash 5.x) and `PATH=/bin:$PATH bats tests/` (bash 3.2) and note the two `ok` counts in `specs/028-channel-reply-guard/quickstart.md` (or a scratch note) so SC-005 deltas are measurable after implementation.

---

## Phase 2: Foundational — the `features.reply_guard` toggle (agent.yml substrate)

**Purpose**: the single-source-of-truth toggle the guard reads. Blocks US1 (which
consumes `FEATURES_REPLY_GUARD_MAX_ATTEMPTS` and is gated on `enabled`). US2 does
NOT depend on this phase and may proceed in parallel.

**Tests first (RED):**

- [X] T002 [P] Add a `features.reply_guard:` block (`enabled: true`, `max_attempts: 1`) to `tests/fixtures/sample-agent-with-vault.yml` under the existing `features:` key — REQUIRED once a template references `{{FEATURES_REPLY_GUARD_MAX_ATTEMPTS}}`, because `tests/schema.bats:52` renders this fixture and greps every `{{VAR}}` in `modules/*.tpl`.
- [X] T003 [P] Add the same `features.reply_guard:` block to `tests/fixtures/sample-agent.yml` for shape parity (no test renders the hook template against it, but keeps fixtures representative).
- [X] T004 Write a failing backfill test in `tests/reply-guard-config.bats` (new): (a) a legacy `agent.yml` with a `telegram@…` plugin and NO `features.reply_guard` gets `enabled=true` + `max_attempts=1` after `./setup.sh --regenerate`; (b) an agent.yml WITHOUT a telegram plugin gets `enabled=false`. RED (backfill not written yet).

**Implementation (GREEN):**

- [X] T005 Add `.features.reply_guard.enabled` to `_SCHEMA_BOOLEANS` in `scripts/lib/schema.sh` (fail-loud on `yes`/typo, mirroring `.features.heartbeat.enabled`). Keep `max_attempts` OUT of required leaves.
- [X] T006 Add a `reply_guard:` sub-block to the wizard `features:` heredoc in `setup.sh` (near the heartbeat block ~`setup.sh:1216-1222`): `enabled` derived from the resolved plugins list containing `^telegram@`, `max_attempts: 1`.
- [X] T007 Add the `features.reply_guard` backfill in `regenerate()` in `setup.sh`, inside the `[ -f "$agent_yml" ]` block BEFORE `render_load_context` (~`setup.sh:2041`), alongside the `deployment.mode` / `session_name` / `vault.qmd.version` backfills: if absent, derive `enabled` from `yq -r '.plugins[]?' | grep -qE '^telegram@'`, default `max_attempts=1`, `yq -i` both. Makes T004 GREEN.

**Checkpoint**: `agent.yml` carries the toggle; `FEATURES_REPLY_GUARD_ENABLED` /
`FEATURES_REPLY_GUARD_MAX_ATTEMPTS` are produced by `render_load_context`.

---

## Phase 3: User Story 1 — a channel answer always reaches the operator (P1) 🎯 MVP

**Goal**: when a channel (Telegram) turn ends without the reply tool having been
called, re-inject once so the agent delivers the answer through the tool.

**Independent Test**: feed `stop-redeliver.sh` a Stop payload + a fake pending-reply
marker (present/absent × `stop_hook_active` true/false) and assert the decision
table in `contracts/stop-hook-io.md`; apply the patcher to a fixture `server.ts` and
assert the marker hunks. Both fully host-runnable, no live agent.

**Tests first (RED):**

- [X] T008 [US1] Write `tests/stop-hook-guard.bats` (new) covering `contracts/stop-hook-io.md`: (1) marker absent → no output, exit 0; (2) marker present + `stop_hook_active=false` + non-empty `last_assistant_message` → exactly one `{"decision":"block",…}` on stdout + one stderr line, exit 0; (3) console turn (marker absent) → no output; (4) marker present + `stop_hook_active=true` → no output (loop guard); plus fail-silent (malformed stdin / disabled / no jq → exit 0, no output) AND the `settings-merge.md` jq cases (merge into a fixture settings.json that already has `permissions` + a foreign `hooks.PreToolUse`: `.hooks.Stop` gains exactly one entry, foreign keys/hooks survive, a second merge is a no-op). Render `stop-redeliver.sh` from the template into a tmpdir with a test `max_attempts`. RED (script + merge function absent).
- [X] T009 [P] [US1] Add failing assertions to `tests/apply-telegram-patches.bats` for the pending-reply marker hunks (`contracts/pending-reply-marker.md`): applying the patch to a fixture `server.ts` inserts a write at the `_markPending`/`OFFSET_MARK` anchor and a delete at the `_ackPending`/`case 'reply'` anchor; second run no-ops on `MARKER_PENDING`; anchor edited out-of-band → WARN + skip only this patch. RED (marker hunks not written). Different file from T008 → [P].

**Implementation (GREEN):**

- [X] T010 [US1] Create `modules/stop-hook.sh.tpl` → renders to `<workspace>/scripts/hooks/stop-redeliver.sh`: read the Stop payload from stdin (jq); locate the pending-reply marker under the telegram channel state dir; apply the decision table (block+reason instructing a resend via `plugin:telegram:telegram`, one fixed-format stderr line, `max_attempts` baked from `{{FEATURES_REPLY_GUARD_MAX_ATTEMPTS}}`); **exit 0 on every path** (fail-silent); never log the message text or any secret. Guard sourced-init with a `BASH_SOURCE` check if it sources any lib.
- [X] T011 [US1] In `setup.sh` `regenerate()` module-render block (~`setup.sh:2265`), render `modules/stop-hook.sh.tpl` → `scripts/hooks/stop-redeliver.sh` + `chmod +x`, GATED on `[ "$FEATURES_REPLY_GUARD_ENABLED" = true ]` so non-channel agents stay byte-identical (FR-012). Runs in both modes. Makes T008 hook-decision tests GREEN.
- [X] T012 [US1] Add `pre_install_stop_hook()` to `docker/scripts/start_services.sh` — invokes the shared rendered helper `scripts/hooks/install-stop-hook.sh` (from `modules/stop-hook-install.sh.tpl`) carrying the additive idempotent jq from `contracts/settings-merge.md`, command = literal `/workspace/scripts/hooks/stop-redeliver.sh` — called in `start_session()` one line after `pre_accept_bypass_permissions` (~`:770`). Makes T008 settings-merge tests GREEN. (image-baked → DOCKER_E2E)
- [X] T013 [US1] Invoke the same shared helper `scripts/hooks/install-stop-hook.sh` from `modules/local-login.sh.tpl` (→ `agent-login.sh`) after `CONFIG_DIR` exists, writing to `${CONFIG_DIR}/settings.json`, command = `{{DEPLOYMENT_WORKSPACE}}/scripts/hooks/stop-redeliver.sh`, guarded by `command -v jq`.
- [X] T014 [US1] Extend the heartbeat isolation jq in `scripts/heartbeat/heartbeat.sh` (`ensure_heartbeat_config_dir`, ~`:146`) from `.enabledPlugins = {} | .extraKnownMarketplaces = {}` to also `| del(.hooks.Stop)`, so cron ticks never carry the redelivery hook.
- [X] T015 [US1] Add the pending-reply marker hunks to `docker/scripts/apply_telegram_typing_patch.py`: new `MARKER_PENDING`; a write hunk at the `OFFSET_MARK`/`_markPending` site (`pending-reply.json = {chat_id, update_id, ts}`) and a delete hunk at the `OFFSET_ACK`/`case 'reply'` site; best-effort `try/catch`; fail-silent on anchor drift (WARN, skip only this patch); wire both into `main()`. Makes T009 GREEN. (image-baked → DOCKER_E2E; **same file as T017 — sequential**)

**Checkpoint**: US1 host-testable end-to-end (hook decision table + patcher marker
hunks GREEN); live re-injection is validated on a host in Polish/quickstart §6.

---

## Phase 4: User Story 2 — the stuck-turn warning stops lying (P2)

**Goal**: the typing-timeout message no longer asserts OAuth; it names the real
alternatives + a diagnostic.

**Independent Test**: apply the patcher to a fixture `server.ts` and assert the v5
message wording; assert the v4→v5 upgrade path and v5 idempotency. Host-runnable.

**Tests first (RED):**

- [X] T016 [US2] Add failing assertions to `tests/apply-telegram-patches.bats`: a fresh install produces the honest message (names slow-turn / answered-without-tool / expired-login + `agentctl doctor`, and does NOT assert "OAuth … expirado"); a v4-patched fixture ratchets to v5 via `upgrade_typing_v4_to_v5`; a v5 file is idempotent. RED. (**same file as T009 — sequential**)

**Implementation (GREEN):**

- [X] T017 [US2] In `docker/scripts/apply_telegram_typing_patch.py`: bump `MARKER_TYPING` to the `…v5` string, add a `MARKER_TYPING_V4` constant, rewrite the `TYPING_HELPERS` `warnMsg` to the honest wording (FR-009), add `upgrade_typing_v4_to_v5` (same shape as `upgrade_typing_v3_to_v4`), and extend the cascade in `main()` to `v1→v2→v3→v4→v5`. Makes T016 GREEN. (**same file as T015 — sequential**)

**Checkpoint**: US1 and US2 both GREEN on the host suite.

---

## Phase 5: Polish & Cross-Cutting

- [X] T018 [P] Add a `CHANGELOG.md` entry under `[Unreleased]` (028, US1 guard + US2 honest warning; note docker-image scope + the local present-but-inert behaviour).
- [X] T019 [P] Update `README.md`: document `features.reply_guard` (enabled/max_attempts, on-by-default with a Telegram channel) and the honest timeout message.
- [X] T020 [P] Update `docs/architecture.md`: the Stop-hook reply guard, the pending-reply marker, the per-mode settings-merge, and the heartbeat `del(.hooks.Stop)` isolation.
- [X] T021 Bump `VERSION` `0.18.0 → 0.19.0` (MINOR — new feature; Principle VI).
- [X] T022 Run the full host suite on bash 5.x AND 3.2 (`PATH=/opt/homebrew/bin:$PATH bats tests/` and `PATH=/bin:$PATH bats tests/`) + `shellcheck -S error` on `scripts/hooks/stop-redeliver.sh` and `docker/scripts/start_services.sh`; confirm `ok` = T001 baseline + new tests, `0 not ok`, byte-identical across both bash versions (SC-005). **DONE 2026-08-08: `1..1225` / `1225 ok` / `0 not ok` byte-identical on bash 5.3.15 and 3.2.57 (baseline 1207 + 18 new); shellcheck CI gate `rc=0`; both rendered hooks shellcheck-clean with no unresolved `{{ }}`.**
- [X] T023 Mutation check (quickstart §2): revert each fix in isolation and confirm ≥1 test goes RED (marker-present branch → case 2; ignore `stop_hook_active` → case 4; old OAuth string → US2 assertion; drop the marker-delete hunk → marker-lifecycle test). **DONE 2026-08-08: 5 mutations, all ≥1 RED — A marker-origin check → cases 1/2/3/8; B loop-guard → case 4; C v5 fresh-install message → US2 test; D clear-injection → pending-marker clear assertion; E backfill telegram-detection → reply-guard-config test 1. Each restored.**
- [X] T024 Regenerate-safety (quickstart §3): a Telegram scaffold `--regenerate` twice → `scripts/hooks/stop-redeliver.sh` byte-stable; a non-channel scaffold → `scripts/hooks/` NOT created, regenerate byte-identical (SC-006, FR-012). **DONE 2026-08-08 (throwaway bats, not committed): (a) telegram agent — two `--regenerate` → both hooks byte-identical + executable; (b) non-telegram agent — `enabled=false`, no `scripts/hooks/` rendered.**
- [~] T025 DOCKER_E2E (gated, on a Docker host) + live-host residual: run `DOCKER_E2E=1 bats tests/docker-e2e-*.bats` (settings.json Stop entry + patched `server.ts` + marker lifecycle). Note the live-host tail (donna/rodri, quickstart §6): confirm `{decision:block}` re-injects and `stop_hook_active` caps the loop in the container's Claude Code, and (optional) whether the transcript marks channel origin — the v0.19.0 DEPLOYMENT is a separate step, not part of this PR. **DEFERRED 2026-08-08: no Docker daemon on this macOS host; the live-host tail requires deploying v0.19.0 to donna/rodri — a separate, operator-gated step out of this PR's scope. Host-runnable gates (T022-T024) are all GREEN.**

---

## Dependencies & Execution Order

- **Phase 1 (Setup)** → no deps.
- **Phase 2 (Foundational toggle)** → blocks US1. US2 is independent of it.
- **US1 (Phase 3)** → after Phase 2. Internal order: T008/T009 (tests, RED) → T010 → T011 (hook GREEN) → T012/T013/T014 (config/isolation) → T015 (marker patcher).
- **US2 (Phase 4)** → after Phase 1; independent of Phase 2 and US1's runtime, EXCEPT T016/T017 share files with T009/T015 (patcher + its bats), so run T015 before T017 and T009 before T016 (same-file serialization).
- **Polish (Phase 5)** → after US1 (+US2 for the CHANGELOG/version).

## Parallel Opportunities

- T002 ‖ T003 (different fixtures).
- T008 ‖ T009 (different test files) — but NOT ‖ T016 (T016 shares the patcher bats with T009).
- T018 ‖ T019 ‖ T020 (different docs).
- US2 (T016→T017) can proceed alongside US1's non-patcher tasks (T008/T010–T014), converging only on the shared patcher file.

## Parallel Example: Foundational tests

```bash
Task: "Add features.reply_guard to tests/fixtures/sample-agent-with-vault.yml"   # T002
Task: "Add features.reply_guard to tests/fixtures/sample-agent.yml"              # T003
```

## Implementation Strategy

### MVP (US1 only)

1. Phase 1 (Setup) → Phase 2 (toggle) → Phase 3 (US1).
2. **STOP and VALIDATE**: `bats tests/stop-hook-guard.bats` + `tests/apply-telegram-patches.bats`
   (marker) GREEN on bash 3.2 + 5.x; mutation check bites.
3. US1 alone restores the dropped reply — the measured bug is fixed.

### Incremental delivery

1. Setup + Foundational → toggle ready.
2. US1 → the guard (MVP).
3. US2 → the honest warning (independent; converges on the patcher file).
4. Polish → docs, VERSION, full-suite + mutation + regenerate gates, DOCKER_E2E,
   live-host residual note.

## Notes

- `schema.bats` `known_external` needs NO edit: `FEATURES_REPLY_GUARD_*` are
  fixture-produced (Decision 5). The top-level-keys test (`schema.bats:21`) is
  unaffected (`reply_guard` lives under the existing `features` key).
- No new wizard prompt → `tests/helper.bash::wizard_answers` and the
  `tests/e2e-smoke.bats` hand-rolled answers array are untouched (verify anyway when
  editing the heredoc).
- The hook and the plugin patcher are fail-silent (exit 0 / skip-on-drift) —
  Principle IV. Never log the message text, the token, or chat contents — Principle V.
- Live-host verification and the v0.19.0 deploy to donna/rodri are OUT of this PR's
  scope (they touch running agents); tracked as the residual in research.md.
