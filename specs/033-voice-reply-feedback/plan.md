# Implementation Plan: Voice reply feedback + explicit audio requests (voice group v2)

**Branch**: `033-voice-reply-feedback` | **Date**: 2026-09-13 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/033-voice-reply-feedback/spec.md`

## Summary

Bump the Telegram plugin's **voice patch group from v1 to v2** inside the image-baked
patcher (`docker/scripts/apply_telegram_typing_patch.py`) so that: (US1) the `reply` tool's
acknowledgement carries a deterministic `voice: sent (…)` / `voice: failed (step=…, …)`
line whenever the outbound voice step ran — and stays byte-identical to v0.23.0 when it
did not; (US2) the channel contract the agent reads states the truth (automatic voice on
voice-originated exchanges and explicit requests, never claim inability, omission
consequence, one honest mention on failure, no verbatim relay); (US3) omitting the spoken
rendition is recorded to stderr and, above a threshold derived from the spoken cap, named
in the acknowledgement; (US4) a typed message that explicitly asks for audio — a fixed,
documented phrase table in Spanish and English, accent/case-insensitive, with a negation
guard — marks the exchange voice-originated exactly like a voice note, and a new
`voice_force` boolean lets the agent honour wordings outside the table. The whole change is
five rewritten constants plus one new `upgrade_voice_v1_to_v2` that migrates the two
fleet agents already at v1 in place, all-or-nothing, fail-silent. No `agent.yml` field,
no wizard, no schema, no privilege, no image package change; DOCKER_E2E required
(image-baked patcher). VERSION 0.23.0 → 0.24.0.

## Technical Context

**Language/Version**: Python 3 (image-baked patcher, importable — `__main__` guard at
`:1402`), TypeScript-on-bun (the patched plugin hunks; upstream `telegram/0.0.6` on the
fleet — the 032 plan's "0.0.7" was a doc drift), bash 3.2+/5.x (bats tests only; no
launcher shell code changes)

**Primary Dependencies**: none new. grammY `bot.api.sendVoice` (existing), ElevenLabs TTS
(existing, unchanged), `String.prototype.normalize('NFD')` (built-in)

**Storage**: none — `_voiceOutcome` is a per-call local; `_voiceOrigin` map (032) reused
in memory; nothing under `.state/` changes

**Testing**: host bats (`tests/apply-telegram-patches.bats`, hermetic — asserts the patched
text; the v1 ground truth is the committed golden fixture
`tests/fixtures/telegram-server-voice-v1.ts` (research D8); the patcher's `_V1` constants
are imported only for the G2b fidelity / G2c round-trip checks); `DOCKER_E2E=1`
(`tests/docker-e2e-voice.bats`, self-seeding) for the in-image upgrade path, the matcher's
behaviour under bun, and a parse-only check of the patched file; live gate on linus/donna
(quickstart §3)

**Target Platform**: docker mode (Alpine aarch64 pods on ferrari). Local (Remote Control)
mode: inert, untouched (FR-010)

**Project Type**: launcher feature — patcher group bump + tests + docs

**Performance Goals**: zero added latency on the text path (one substring scan of each
typed DM against 38 short phrases — 23 ES + 15 EN); voice path unchanged (same single
30 s budget, now covering the send leg too if the grammY `signal` parameter is confirmed)

**Constraints**: acknowledgement byte-identical when voice did not run (FR-002);
whitelist-only fields in the acknowledgement (FR-003); in-place v1→v2 upgrade, group-
scoped, all-or-nothing, fail-silent (FR-005); no new config surface (FR-007); every
`re.subn` replacement a `lambda`, every TS backslash doubled in the Python literal (032
bug class, research D10); no change to `handleInbound`, the inbound STT hunk, or any
other patch group

**Scale/Scope**: 3 docker agents; two (donna, linus) take the upgrade path, one
(rodri-cenco-admin, pending its 0.19.0 → 0.24.0 upgrade) lands v2 fresh

## Constitution Check

*Source: `.specify/memory/constitution.md` (v1.0.1). Evaluated pre-Phase-0 and re-checked
post-design (Phase 1) — both passes recorded here.*

- [x] **I. Single Source of Truth** — PASS (both passes). Nothing rendered from `agent.yml`
  changes; the patcher is boot-applied against the plugin cache and is idempotent by
  marker, so `--regenerate` is irrelevant to it and every derived file is byte-identical
  before/after. The phrase table and the nag threshold are deliberately constants (spec
  Q2/Q6, FR-007), not configuration — no new field, no drift surface.
- [x] **II. Least-Privilege (NON-NEGOTIABLE)** — PASS. No capability, mount, socket or
  privilege change. The hunks use only what 032 already used (`bot.api.sendVoice`,
  `fetch` to ElevenLabs, `process.stderr`). The new data reaching the model (the outcome
  line) is a whitelist of six fields; no secret, URL or free-form error text.
- [x] **III. Test-First, Host-Runnable** — PASS. Every behaviour is asserted on the patched
  text by host bats before the constants are written (tasks order RED→GREEN); the v1
  ground truth is a **committed golden fixture** generated once by the real v0.23.0
  patcher (no git history needed at test time, CI-shallow-safe) plus a `_V1`-fidelity
  test — the review found the first draft's constants-only oracle tautological;
  `DOCKER_E2E=1` gated e2e rewritten to be **self-seeding** (the image ships no plugin;
  the inherited 032 cases could never find a `server.ts`) and extended (E5 matcher
  behaviour, E6 parse, E7 upgrade, E8 errClass); every negative assertion uses a
  bats-live form (`run …; [ "$status" -ne 0 ]` / counts) and the dead 032 negatives in
  the same file are repaired; no shell code changes (shellcheck gate unaffected but run).
  **Declared deviation, same as 016/028/031/032**: the DOCKER_E2E RUN is deploy-deferred
  (no docker daemon in the dev environment); the e2e file ships parse-clean and gated.
- [x] **IV. Idempotent, Fail-Silent Lifecycle** — PASS. Marker-gated (`MARKER_VOICE` v2
  short-circuits both functions); the upgrader is all-or-nothing on five exact anchors and
  leaves v1 in place with a WARN on any miss; `apply_voice` refuses a v1 file so it can
  never double-insert; fresh-apply anchor drift still rolls the whole group back (032
  behaviour); the reply block's try/catch/finally shape is preserved and the outcome
  assembly is primitive concatenation (FR-008).
- [x] **V. Workspace-Is-the-Agent** — PASS. No state written; the plugin file under
  `.state/` is re-patched at boot as today; the acknowledgement never carries a token,
  URL or the spoken text; backups untouched.
- [x] **VI. Reproducible, Pinned Dependencies** — PASS. No pins touched; VERSION 0.23.0 →
  0.24.0 (MINOR, 028/031 precedent: plugin behaviour change + marker bump); CHANGELOG +
  README (phrase table is a user-facing contract) + CLAUDE.md patch section updated.

**Post-design re-check (Phase 1)**: unchanged, 6/6 PASS. One risk named rather than a
violation: a TS syntax error in a v2 hunk would flap the channel at boot (research D12);
mitigated by e2e E6 and the linus-first deploy order in quickstart §3.

**Adversarial review of this plan (2026-09-13, workflow `wf_e99b3212-83d`)**: 4 reviewers
(patcher mechanics / runtime semantics / test oracles / spec coverage), 32 findings —
3 HIGH, 12 MEDIUM, 17 LOW after dedup. The session token limit killed 20 of 32 refuters;
the 12 that ran refuted nothing. Both HIGH clusters were re-verified by hand and stand:
(1) the upgrade oracle was tautological → golden v1 fixture (research D8); (2) the e2e
harness inherited from 032 can never find a plugin file under `--entrypoint sh` → self-
seeding (research D11). All HIGH/MEDIUM and the actionable LOWs are remediated across
spec/research/data-model/contracts/quickstart — table in research.md §Review remediation.
Constitution gates unaffected (still 6/6).

## Project Structure

### Documentation (this feature)

```text
specs/033-voice-reply-feedback/
├── plan.md                                  # this file
├── research.md                              # Phase 0 — measured baseline + D1..D12
├── data-model.md                            # Phase 1 — entities, marker state machine
├── quickstart.md                            # Phase 1 — host / DOCKER_E2E / live gates, rollback
├── contracts/
│   ├── reply-voice-outcome.md               # acknowledgement grammar, whitelist, wording (US1-US3)
│   ├── explicit-audio-request.md            # phrase table, matcher, effect, strictness (US4)
│   └── voice-group-v2-upgrade.md            # constants, upgrader, apply_voice changes, guarantees
├── checklists/requirements.md
└── tasks.md                                 # Phase 2 — /speckit-tasks (not created here)
```

### Source Code (repository root) — touchpoints

```text
docker/scripts/apply_telegram_typing_patch.py   # THE change: MARKER_VOICE v2 + MARKER_VOICE_V1;
                                                #   *_V1 twins of five constants; v2 constants;
                                                #   upgrade_voice_v1_to_v2(); apply_voice gate + hunk4
                                                #   replace; main() wiring + parts list; docstring
tests/fixtures/telegram-server-pristine.ts      # NEW: the bats heredoc extracted byte-for-byte (host + e2e)
tests/fixtures/telegram-server-voice-v1.ts      # NEW: GOLDEN — v0.23.0 patcher output over pristine, generated
                                                #   once via `git show a7eb2e5:…` on the dev host, committed
tests/apply-telegram-patches.bats               # setup() cps the pristine fixture; 5 v1 oracles → v2 (RED first),
                                                #   :804 flipped to a v2 count (no RED); dead 032 negatives
                                                #   (:804 :876-878 :886 :984 :995) repaired to live forms
                                                #   (:878 narrowed to stderr lines); new 033 section (G1-G11
                                                #   + wording, wrap gating/parity, voice_force strictness,
                                                #   matcher table/structure/negatives, cooldown structure)
tests/docker-e2e-voice.bats                     # E1-E4 rewritten SELF-SEEDING (copy fixture into the plugin
                                                #   cache path, run the image-baked patcher); E5 matcher under
                                                #   bun; E6 parse-only check; E7 golden v1 upgrade in-container;
                                                #   E8 _voiceErrClass({error_code:400})
README.md                                       # Telegram section, 7th hook: v2 behaviours + phrase table
CHANGELOG.md                                    # [Unreleased] Added/Changed
VERSION                                         # 0.23.0 → 0.24.0
CLAUDE.md                                       # "Telegram plugin patch" section: voice group v2 note
```

Untouched by design: `setup.sh`, `scripts/lib/*`, `modules/*`, `docker/Dockerfile`,
`docker/scripts/start_services.sh`, `agent.yml` schema, wizard, `tests/voice-config.bats`,
`tests/docker-render.bats`, `tests/local-render.bats`.

**Structure Decision**: single-file behaviour change in the image-baked patcher, mirrored by
its two existing test files; docs follow the 028/031/032 precedent (README hook bullet,
CHANGELOG, VERSION, CLAUDE.md section).

## Design summary (from research.md — decisions the tasks implement)

| # | Decision | Spec link |
| --- | --- | --- |
| D1 | `let _voiceOutcome = ''` before the voice `if`; return `result + _voiceOutcome` | FR-001, FR-002 |
| D2 | Outcome grammar: `sent (fmt, chars, ms)[; omitted nag]` / `failed (step, cls, status)` | FR-001, FR-003 |
| D3 | `_voiceStep` flipped between synth and send; `_voiceErrClass` reads grammY `error_code` | Q3, SC-006 |
| D4 | Omission stderr record always; nag when `chars > floor(cap/4)` (300 default) | FR-006, FR-007, Q2 |
| D5 | Fixed ES/EN phrase table + NFD normalisation + word boundaries + negation guard, in the `message:text` wrap, DM-only, gated on `VOICE_ACTIVE` | FR-011, FR-012, Q6 |
| D6 | `voice_force: boolean` (strict `=== true`) as third trigger in mode `auto` | FR-013, FR-014 |
| D7 | `upgrade_voice_v1_to_v2`: five exact-constant replacements, all-or-nothing; `apply_voice` gates on v1 too; hunk4 replaces the return line | FR-005 |
| D8 | Committed golden v1 fixture (real v0.23.0 patcher output) + `_V1`-fidelity test; oracle = `sha(patcher(golden)) == sha(patcher(pristine))`; reverse-replace round trip only secondary | FR-005, SC-005 |
| D9 | Contract wording keeps the 032 substrings so 032 oracles stay valid | FR-004 |
| D10 | Double every TS backslash in Python literals; lambda replacements only | 032 bug class |
| D11 | Three verification tiers; E6 parse check API is measured, not assumed | SC-001..009 |
| D12 | VERSION 0.24.0; README phrase table; linus-first deploy | VI |
| D13 | One-shot per-chat failure cooldown in mode `always` (set on `failed`, consumed before the next synthesis) — mechanises the loop bound | FR-012, edge case |

## Phase 2 handoff (for /speckit-tasks)

- Test-first order: (0) generate and commit the two fixtures (quickstart §0) and switch
  `setup()` to `cp` the pristine one — suite must stay 64/64 GREEN byte-for-byte before
  anything else; (1) move the four host v1-literal/return-line oracles to v2 and confirm
  RED (`:781 :795 :921 :934`); flip `:804` to a v2 count (no RED); the two e2e greps
  (`:64 :113`) are rewritten by T021, which owns that file; repair the dead 032 negatives
  to live forms (expect `:878` to need narrowing); (2) write
  the 033 host tests RED (G1-G11 + wording/wrap/flag/matcher/cooldown); (3) constants +
  upgrader + wiring GREEN; (4) e2e file rewritten self-seeding + E5-E8 (parse-clean,
  gated); (5) docs + VERSION + CHANGELOG; (6) the eight mutation spot-checks (quickstart
  §1); (7) full suite in bash 3.2 and 5.x; shellcheck.
- Deploy-deferred (declared): DOCKER_E2E run; live gates SC-001/002/003/006/007/008/009
  on linus first, then donna (quickstart §3). Rollback note in quickstart §4 — reverting
  the image alone does NOT downgrade the patched plugin file.
- Do not merge with the pending rodri-cenco-admin 0.19.0 → 0.24.0 fleet upgrade; that
  agent lands v2 fresh as part of its own upgrade.

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
| --- | --- | --- |
| Test gate "DOCKER_E2E MUST pass for changes touching `docker/`" is satisfied AFTER merge (T029 rides the v0.24.0 deploy), not before | No docker daemon in the development environment; the e2e file ships parse-clean and gated; the boot risk (TS syntax error) is bounded by the linus-first deploy order and the E6 parse check on first run. Same openly-recorded deviation as 016/028/031/032 | Blocking the merge until a docker host is available would hold a production lie (the measured defect) open for the duration with no added assurance the host suite does not already provide |
