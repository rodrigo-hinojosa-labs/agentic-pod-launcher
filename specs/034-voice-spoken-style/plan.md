# Implementation Plan: Voice spoken style (voice group v3)

**Branch**: `034-voice-spoken-style` | **Date**: 2026-09-16 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/034-voice-spoken-style/spec.md`

## Summary

Bump the Telegram plugin's **voice patch group from v2 to v3** inside the image-baked patcher
(`docker/scripts/apply_telegram_typing_patch.py`) and add two `agent.yml` fields, so that
what the agent SPEAKS is a summarized narration rather than the written reply read aloud:
(US1) the channel's contract to the agent states the spoken style in numbers and form —
three length tiers (≈30 / 45 / 60 s at the measured 15 chars/s, 60 s hard), plain spoken
prose, figures in words with the currency named, the configured language, and "the channel
appends the closing phrase"; (US2) every synthesized audio ends with a configurable,
nickname-personalized closing phrase (`features.voice.signoff`, localized default), appended
deterministically and exactly once; (US3) everything sent to synthesis is made spoken-safe by
a regex-only normalizer (markup, lists, emojis, URLs out; `$`/`USD`/`UF`/`%` named, currency
word from `features.voice.currency`) and the synthesizer is told the language
(`language_code`, reusing `VOICE_STT_LANG`); (US4) a missing or oversized rendition degrades
to a sentence-cut narration within the cap (now 900 = the 60 s tier) with the closing phrase,
and the acknowledgement gains one whitelisted token (`voice_text trimmed to N chars`). The
written reply and the no-voice acknowledgement stay byte-identical to v0.24.0. Four rewritten
constants + frozen `_V2` twins + `upgrade_voice_v2_to_v3` (all-or-nothing, fail-silent) with
the v1→v2 upgrader re-pointed at the twins; a committed golden v2 fixture keeps the oracle
non-tautological. No privilege, no image package change; DOCKER_E2E run for real on this
host. VERSION 0.24.0 → 0.25.0.

## Technical Context

**Language/Version**: Python 3 (image-baked patcher; `__main__` guard, `main(argv)` at
`:1632`), TypeScript-on-bun (patched plugin hunks; upstream `telegram/0.0.6` on the fleet),
bash 3.2+/5.x (`setup.sh` sanitizer + backfill; bats)

**Primary Dependencies**: none new. ElevenLabs TTS (existing; body gains `language_code`),
grammY (unchanged), JavaScriptCore regex features under bun: `\p{Extended_Pictographic}` +
`u` flag, lookbehind, `\u{…}` — measured under host bun 1.3.12 (research R4), re-verified
in-container by E9

**Storage**: none — two new `agent.yml` fields (rendered to compose environment); per-reply
in-memory values only; nothing under `.state/` changes

**Testing**: host bats (`apply-telegram-patches.bats` 92 → +034 section; `voice-config.bats`
9 → +sanitizer/backfill/defaults; `docker-render.bats`, `schema.bats`, `local-render.bats`,
`regenerate.bats`); golden fixtures v1 (033) + **v2 (new, generated once from the v0.24.0
patcher at `3534c6b`)**; `DOCKER_E2E=1 tests/docker-e2e-voice.bats` self-seeding, 8 → 12
(E9 normalizer table under bun, E10 sign-off/budget, E11 `language_code` line, E12 golden
v2 → v3 in-container) — RUN on this host (docker compose v5.3.1, arm64); live gate on linus
then donna (quickstart §3)

**Target Platform**: docker mode (Alpine aarch64 pods on ferrari). Local mode: inert (no voice
runtime values rendered; the two fields exist in `agent.yml`, nothing reads them)

**Project Type**: launcher feature — patcher group bump + config surface + tests + docs

**Performance Goals**: zero added latency on the text path; on the voice path a dozen regex
passes over ≤ 900 characters before synthesis (sub-millisecond) — the 30 s synthesis budget
is untouched

**Constraints**: written reply byte-identical; no-voice acknowledgement byte-identical to
v0.24.0 (FR-010); acknowledgement/stderr whitelist +1 token (FR-012); in-place v2→v3
all-or-nothing, fail-silent, convergent from pristine/v1/v2 (FR-011); no wizard prompt
(FR-014); every TS backslash doubled in Python literals, every `\uXXXX` verified byte-for-byte,
every `re.subn` replacement a `lambda` (research D14); compose interpolates `$` in
`environment:` values and YAML double quotes break on `"`/`\` → render-time stripping (D8);
no byte-level truncation of the phrase on any host (default + WARN instead of a cut)

**Scale/Scope**: 3 docker agents; linus and donna take v2→v3; rodri-cenco-admin (pending
0.19.0 → current) lands v3 fresh in its own upgrade

## Constitution Check

*Source: `.specify/memory/constitution.md` (v1.0.1). Evaluated pre-Phase-0 and re-checked
post-design (Phase 1) — both passes recorded here.*

- [x] **I. Single Source of Truth** — PASS (both passes). The two new fields live in
  `agent.yml`, are written by the wizard heredoc with localized defaults, backfilled by
  `--regenerate` under `has()` guards, sanitized at render time into DEDICATED derived
  placeholders (`VOICE_SIGNOFF`, `VOICE_CURRENCY`, mold `VOICE_STT_LANG`) and rendered
  unconditionally into `docker-compose.yml` — two consecutive `--regenerate` runs are
  byte-identical (regenerate-safety gate). Language reuses the existing `VOICE_STT_LANG`
  derivation (no second copy of the same truth). The cap default change is a runtime knob
  default, documented in `.env.example`.
- [x] **II. Least-Privilege (NON-NEGOTIABLE)** — PASS. No capability, mount, socket or
  privilege change; the hunks use only what 032/033 already used. The data reaching the
  model gains one whitelisted token; nothing new reaches the network except one documented
  JSON field (`language_code`) on an existing request.
- [x] **III. Test-First, Host-Runnable** — PASS. Every behaviour is asserted on the patched
  text by host bats before the constants are written; the v2 ground truth is a committed
  golden fixture generated once by the real v0.24.0 patcher (033 D8 anti-tautology rule,
  extended one version); the normalizer/cut/sign-off behaviour under bun is asserted in
  DOCKER_E2E (E9/E10) which is RUN on this host, not deferred; negatives use bats-live forms
  (`run …; [ "$status" -ne 0 ]` / counts); `shellcheck -S error` for the new `setup.sh`
  helpers; sourced libs untouched.
- [x] **IV. Idempotent, Fail-Silent Lifecycle** — PASS. Marker-gated (`MARKER_VOICE` v3
  short-circuits); `upgrade_voice_v2_to_v3` is all-or-nothing on four exact anchors and
  leaves v2 in place (WARN) on any miss; `apply_voice` refuses v1/v2/v3 files; fresh-apply
  anchor drift still rolls the whole group back (032 behaviour); the reply block's
  try/catch/finally shape is preserved; the sanitizer never fails a render (default + WARN).
- [x] **V. Workspace-Is-the-Agent** — PASS. No state written; the plugin file under
  `.state/` is re-patched at boot as today; the acknowledgement/stderr never carry the spoken
  text, a token or a URL; the boot log carries the sign-off LENGTH, not the phrase; backups
  untouched (`agent.yml` with the new fields rides `backup/config` as before).
- [x] **VI. Reproducible, Pinned Dependencies** — PASS. No pins touched; VERSION 0.24.0 →
  0.25.0 (MINOR, 028/031/033 precedent: plugin behaviour change + marker bump, verified
  against `origin/main` first); CHANGELOG + README ("Round-trip voice" bullet: spoken style,
  closing phrase, two fields, cap 900) + CLAUDE.md patch section (voice group v3).

**Post-design re-check (Phase 1)**: unchanged, 6/6 PASS. Two risks named rather than
violations: (1) a TS syntax slip in a v3 hunk flaps the channel at boot — bounded by E6
(parse under bun) run before deploy and the linus-first order; (2) the provider's reading of
dotted figures on the fallback path is unmeasurable here — bounded by D9 (digits never
rewritten, language passed) and named as a one-line follow-up if the live gate says so.

**Adversarial review of this plan (2026-09-18, workflow `wf_75f8266f-62e`)**: 4 lenses
(patcher mechanics / runtime semantics under bun / config surface + bash portability / test
oracles + spec coverage), 21 findings, one refuter per finding (25 agents; 2 refuters hit the
weekly limit — both findings duplicate confirmed ones). **0 refuted, 19 confirmed by reading
and executing.** The three HIGH that survived and changed the design: the figure pattern split
`$1500` into `150 … 0` (closed with `(?!\d)`, 8 new cases); horizontal rules, table separator
rows, skin-tone and keycap emojis survived normalization (two new passes + extended class, 9
new cases); an empty `signoff` was both "opt-out" and "default" in the spec (now: default +
WARN, per decision D3) and the "real newline" sanitizer case could never run (multi-line YAML
aborts the render for every field — out of scope). MEDIUMs that changed the design: the cut
could land inside a phrase the agent wrote and a +1 reserve overflowed the cap (strip before
the cut, reserve +2, `;:` → `.`); E10 could not execute the pipeline from the reply block
(`_voiceSpokenAssemble` moved to the helpers); the omission nag silently changed its basis
(narrated text, as in 033); `$lang`/`warn` did not exist in `regenerate()`; YAML `null`
rendered the word "null" (raw `yq … // ""` input); `${#v}` bytes vs chars across the CI
matrix (`local LC_ALL=C`); no host oracle for the silently-transformed Python escapes `\1`/`\b`
(G15/G16 + M10/M11); the e2e agent is `en`/`Alice` (env pinned per invocation); the wizard
heredoc had no oracle (`wizard_answers lang=/nick=`); the churn map had a false positive
(`:945`) and two omissions (`:1053 :1060`); M5 credited the wrong oracle (G2d added). All 21
remediated across spec/research/data-model/contracts/quickstart before this plan closed —
table in research.md "Review remediation". Every design change was re-measured under bun
(research R4: 38/38 + 10 assembly invariants). Constitution gates unaffected (6/6).

## Project Structure

### Documentation (this feature)

```text
specs/034-voice-spoken-style/
├── plan.md                                  # this file
├── research.md                              # Phase 0 — R1..R5 measured, D1..D14 decisions
├── data-model.md                            # Phase 1 — config, runtime constants, rendition, ack, state machine, sanitizer, symbol table
├── quickstart.md                            # Phase 1 — §0 fixture, §1 host + 9 mutations, §2 DOCKER_E2E, §3 live gate, §4 rollback
├── contracts/
│   ├── spoken-style-contract.md             # exact v3 instructions line + voice_text description + oracles (US1)
│   ├── spoken-text-pipeline.md              # helpers v3, normalizer passes, cut, sign-off, synth body, reply-block order, E9/E10 (US3/US4/US2)
│   ├── voice-style-config-and-render.md     # agent.yml fields, defaults, backfill, sanitizer, compose, docs (US2)
│   └── voice-group-v3-upgrade.md            # constants, upgrader, re-pointing, main wiring, fixtures, G1-G14, rollback
├── checklists/requirements.md
└── tasks.md                                 # Phase 2 — /speckit-tasks (not created here)
```

### Source Code (repository root) — touchpoints

```text
docker/scripts/apply_telegram_typing_patch.py   # MARKER_VOICE v3 + MARKER_VOICE_V2; *_V2 twins of four constants; v3 constants
                                                #   (helpers: cap 900, new consts + 4 helpers, _voiceTruncate removed, synth body
                                                #   language_code; reply block pipeline + trim note; schema description; instructions
                                                #   template literal); upgrade_voice_v2_to_v3(); upgrade_voice_v1_to_v2 re-pointed
                                                #   at _V2 twins; apply_voice gate; main() wiring + parts; docstring
setup.sh                                        # voice_signoff_default / voice_currency_default; heredoc fields (no prompt);
                                                #   regenerate() has()-backfill of both; voice_phrase_effective sanitizer;
                                                #   VOICE_SIGNOFF / VOICE_CURRENCY derived placeholders (next to VOICE_STT_LANG)
modules/docker-compose.yml.tpl                  # +2 unconditional lines TELEGRAM_VOICE_SIGNOFF / TELEGRAM_VOICE_CURRENCY
modules/env-example.tpl                         # cap comment/default 1200 → 900 (the two fields are NOT listed — agent.yml-sourced)
tests/fixtures/telegram-server-voice-v2.ts      # NEW golden — v0.24.0 patcher output over pristine (git show 3534c6b:…), committed
tests/fixtures/sample-agent{,-with-vault}.yml   # + signoff / currency fields
tests/apply-telegram-patches.bats               # v2 oracles → v3 where they assert the current version (RED first); v2 counts kept
                                                #   where they assert the golden v2; _voiceTruncate oracles (:812 :815) → pipeline
                                                #   oracles; 033 phrase oracles (:830 :945 :1052) → v3 phrase; new 034 section
                                                #   (G1-G13, contract C1/C2, pipeline order, trim grammar, whitelist, no-voice identity)
tests/helper.bash                               # wizard_answers gains optional kv lang= / nick= (defaults en/Alice; block markers kept)
tests/voice-config.bats                         # wizard heredoc es/mixed/en (agent.yml template with literal {nickname}), backfill with
                                                #   exact localized values + clean stderr, has()-preservation, sanitizer table (quotes,
                                                #   $, backslash, braces, tab/CR, null, over-long ASCII → default + WARN), nickname
                                                #   empty, two regenerates byte-identical, documented multi-line negative
tests/docker-render.bats                        # "five" → "seven" TELEGRAM_VOICE_* lines, +2 assertions
tests/schema.bats                               # known_external += VOICE_SIGNOFF VOICE_CURRENCY
tests/docker-e2e-voice.bats                     # markers/awk range → v3; E9 normalizer table; E10 sign-off/budget; E11 synth body; E12 golden v2 → v3
README.md                                       # Round-trip voice bullet: spoken style, closing phrase, fields, cap 900
CHANGELOG.md                                    # [Unreleased] Added/Changed
VERSION                                         # 0.24.0 → 0.25.0
CLAUDE.md                                       # "Telegram plugin patch" section: voice group v3
```

Untouched by design: `scripts/lib/*` (render engine, schema — no new boolean), `wizard.sh` /
`wizard-gum.sh`, `docker/Dockerfile`, `docker/scripts/start_services.sh`, `handleInbound`,
the inbound STT hunk, the `message:text` wrap, `tests/local-render.bats` (its 032 oracle
passes by construction; re-run), `tests/e2e-smoke.bats`.

**Structure Decision**: patcher group bump (one file) + the 032 config-surface mold
(`setup.sh` heredoc/backfill/sanitizer, compose template, fixtures, host bats) + docs per the
028/031/032/033 precedent.

## Design summary (from research.md — decisions the tasks implement)

| # | Decision | Spec link |
| --- | --- | --- |
| D1 | v2→v3: four rewritten constants with frozen `_V2` twins; `upgrade_voice_v2_to_v3` all-or-nothing; `upgrade_voice_v1_to_v2` re-pointed at the twins; gate + `main()` wiring | FR-011, SC-007 |
| D2 | Contract line as a template literal interpolating cap / language name / currency word; `voice_text` description rewritten; 033 substrings kept, the under-specified phrase replaced | FR-001, US1 |
| D3 | Module-level `_voiceSpokenAssemble`: normalize → empty sentence → sign-off strip → sentence cut (budget = cap − (signoff + 2), floor cap/2) → sign-off append; reply block calls it; omission nag and trim note on the NARRATED length | FR-003, FR-008, FR-009, SC-009 |
| D4 | `_voiceSpokenNormalize`: 15 ordered regex passes (incl. horizontal rules, table separator rows, skin tones/keycaps), figure group closed with `(?!\d)`, symbol naming in a fixed order, localized word table | FR-005, FR-006, SC-003 |
| D5 | `_voiceSentenceCut` (terminator → space → hard) + `VOICE_EMPTY_SENTENCE` | FR-008, edge cases |
| D6 | One language signal (`VOICE_STT_LANG`) for the synth body, the contract and the word table; `mixed` → Spanish defaults | FR-007, SC-005 |
| D7 | `_voiceSignoffStrip` before the cut, `_voiceSignoffAppend` (with `;:` → `.`) after it; key = NFD/case/punctuation-insensitive | FR-003, SC-001 |
| D8 | Two fields, localized defaults, no prompt, `has()` backfill with `_vlang` read inside `regenerate()`, sanitizer fed from the raw `yq … // ""` value (`local LC_ALL=C`; strip `" \ $ { }`; empty/null/over 120-40 BYTES → default + `echo WARN >&2`), derived placeholders, two unconditional compose lines, `.env.example` cap only | FR-002, FR-004, FR-013, FR-014 |
| D9 | Digits never rewritten; `language_code` steers provider normalization; dotted-figure reading measured live (§3.4); follow-up named | FR-006, SC-004 |
| D10 | Cap default 900 = maximum tier; nag derivation unchanged (¼ cap, on the narrated length) | FR-016, clarification |
| D11 | Golden v2 fixture + fidelity test + G2d intermediate-state oracle; convergence pristine == v1 == v2 → v3 | FR-011, SC-007 |
| D12 | Three tiers; DOCKER_E2E run for real with env pinned per bun invocation (harness agent is `en`/`Alice`); `wizard_answers lang=/nick=` for the heredoc oracle; E9-E12 | SC-001..009 |
| D13 | VERSION 0.25.0; docs; linus-first deploy | VI |
| D14 | Literal rules made precise: valid Python escapes (`\1`, `\b`, …) transform silently → G15/G16 oracles on the patched OUTPUT + M10/M11 | 032/033 bug class |
| D15 | Harness facts stated in the tests (en/Alice agent; empty env phrase = no phrase; explicit cap) | SC-001..003 |

## Phase 2 handoff (for /speckit-tasks)

- Test-first order: (0) generate + commit the golden v2 fixture (quickstart §0), record its
  sha; suite must stay 1368/0 before anything else; (1) churn the 033 oracles to v3 where
  they assert a file that WENT THROUGH the patcher (`:812 :815 :830 :1052 :1053 :1060
  :1075 :1076 :1140`, marker counts `:637 :651 :782 :867 :880 :930 :967`, e2e `:96 :156
  :169 :228 :246`) and confirm RED; do NOT touch `:945` (G4's mutant on the golden v1) nor
  `:950`; extend 033 G4 with a `patch v3` count 0; (2) write the 034 host tests RED
  (G1-G16, contract C1/C2, helper/reply-block order, trim grammar, config heredoc/backfill/
  sanitizer incl. `wizard_answers lang=/nick=`, compose +2, schema); (3) constants + twins +
  upgrader + re-pointing + `setup.sh` + templates + fixtures + helper GREEN; (4) e2e E9-E12 +
  marker/range/env updates, RUN under `DOCKER_E2E=1`; (5) docs + VERSION + CHANGELOG +
  CLAUDE.md; (6) the thirteen mutation spot-checks (quickstart §1); (7) full suite in bash
  3.2 and 5.x; shellcheck; py_compile; source byte audit + output control-byte audit.
- Deploy-deferred (declared, not a gate deviation): live SC-001..006 on linus then donna
  (quickstart §3), including the D9 measurement. Rollback in quickstart §4.
- Do not merge with the pending rodri-cenco-admin fleet upgrade; that agent lands v3 fresh.

## Complexity Tracking

No constitution violation to justify. (Unlike 033, the DOCKER_E2E gate is RUN before merge:
this host has a docker daemon.)

## Adversarial review

Recorded above (Constitution Check, "Adversarial review of this plan") and in research.md
"Review remediation" (21 rows). Remediation closed 2026-09-18; no open finding.
