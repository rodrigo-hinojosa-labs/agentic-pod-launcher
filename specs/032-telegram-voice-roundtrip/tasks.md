# Tasks: Round-trip voice over the Telegram channel (async voice notes)

**Input**: Design documents from `specs/032-telegram-voice-roundtrip/`
**Prerequisites**: plan.md, research.md (D1-D9), data-model.md, contracts/ (C1-C15), quickstart.md
**Branch**: `032-telegram-voice-roundtrip` (from main `076bb4e`, v0.22.0 → target 0.23.0)

**Discipline** (constitution III — test-first is mandatory, not optional): every phase
runs RED (tests written and failing for the right reason) before its implementation
tasks, and closes with an explicit GREEN checkpoint. The six existing patch groups'
tests are a regression floor throughout.

## Phase 1: Setup

- [X] T001 Baseline + gates: run `bats tests/` and record the green baseline count; verify `git show origin/main:VERSION` is `0.22.0` before any bump (023 lesson); re-check gate E3 — the pinned telegram plugin is still 0.0.7 with no upstream voice support (issue #989 / plugin changelog) and the cached `server.ts` anchors for V1-V6 (`bot.on('message:voice'`, `bot.on('message:text'`, `case 'reply'`, reply inputSchema, `instructions:` array, `loadAccess`) still match the shapes assumed in research.md D1/D9. Record results in this file's notes.
  - Notes: `origin/main` VERSION confirmed `0.22.0` (matches local). Real upstream server.ts (marketplace cache, plugin version `0.0.6` — one point release below the `0.0.7` the plan assumed, but no version pin exists anywhere in the launcher's patcher/Dockerfile, so this is not a blocker) confirms every anchor byte-for-byte: `bot.on('message:voice', ...)` at the shape `{ const voice = ctx.message.voice; const text = ctx.message.caption ?? '(voice message)'; await handleInbound(ctx, text, undefined, {kind:'voice',...}) }`, `bot.on('message:text', ...)`, `case 'reply': {` with `const result =` immediately before the case's `return { content: [{ type: 'text', text: result }] }`, the reply tool's `inputSchema` (unique `required: ['chat_id', 'text']`), and `access.dmPolicy`/`access.allowFrom` in `loadAccess()`'s `Access` shape. D1/D9 assumptions hold. Baseline suite: 1299 ok / 0 not ok pre-032 (own clean run).
- [X] T002 Extend the synthetic fixture heredoc in `tests/apply-telegram-patches.bats` with upstream-shaped anchors for the voice hunks (review HIGH): `bot.on('message:voice')` handler byte-mirroring server.ts:837-847, a `bot.on('message:text')` handler, a `loadAccess()` stub, the reply case's files loop + `const result =` + `return { content:` region, the reply tool inputSchema block, and the `instructions:` array. CHECKPOINT: the existing 43 tests still pass byte-identically (the shared `const result =` anchor must still match exactly once) before any voice test is added.
  - Notes: checkpoint confirmed — 43/43 green immediately after the fixture extension, before any voice test existed.

## Phase 2: Foundational (blocking prerequisites)

- [X] T003 Add `features.voice.enabled` to `_SCHEMA_BOOLEANS` in `scripts/lib/schema.sh` AND add the full `features.voice` block (`enabled: false`, `reply_mode: auto`, `voice_id: ""`, `provider: elevenlabs`) to both `tests/fixtures/sample-agent.yml` and `tests/fixtures/sample-agent-with-vault.yml` (schema.bats placeholder-drift guard — the exact trap 031's baseline caught; do both in one task so schema.bats never sees a half-state).

## Phase 3: User Story 1 — A spoken instruction is understood and acted on (P1) — MVP

**Goal**: inbound voice note → transcript announced to the agent; every failure degrades
to today's placeholder. Contracts C1-C5c; hunks V1, V5, V6.

**Independent test**: `bats tests/apply-telegram-patches.bats` voice-inbound tests pass
against the patched fixture; no outbound/TTS code required.

- [X] T004 [US1] RED — add the inbound voice-group tests to `tests/apply-telegram-patches.bats` (~12, per contract C1-C5c test hooks): prefixed `MARKER_VOICE` present exactly once; double-apply idempotent; anchor-drifted fixture ⇒ WARN + untouched file (group rollback); DM-only pre-check INCLUDING the `dmPolicy !== 'disabled'` guard appears before any `getFile`/`fetch`; detached shape (`void (async` scheduling, no handler-level `await` of the STT helper); `sendChatAction` typing line at pipeline start; AbortController/timeout present; placeholder call textually present (fail-open floor); caps comparisons + `over-cap` literal + post-download buffer check + absent-`file_size` classification; stderr lines carry `telegram channel: voice` prefixes and interpolate ONLY whitelisted fields (chat/dur/chars/ms/class/status — no `${err}`, no URL-bearing variable, no `file/bot` substring in any interpolation; analyze C1); no-echo: the V1 hunk contains NO `sendMessage`/`ctx.reply(` call (analyze E4); the one-time config/WARN emission sits at MODULE scope, outside any handler (analyze E5); V6 `message:text` wrap with `VoiceOrigin.delete`; placeholder path does NOT set VoiceOrigin; typing cascade v1→…→v6 tests unaffected. Verify all new tests FAIL (patcher has no voice group yet).
  - Delivered as 12 tests (44-56 in the file's final numbering). RED confirmed (patcher had no `apply_voice` yet), then implemented alongside per the actual patcher shape.
- [X] T005 [US1] Patcher scaffolding in `docker/scripts/apply_telegram_typing_patch.py`: `MARKER_VOICE = "agentic-pod-launcher: telegram voice roundtrip patch v1"`, constants (`VOICE_STT_MODEL = "scribe_v2"`, default stock voice id, API base; `VOICE_TTS_MODEL` lands in T010 — US2 material, analyze F7), the V5 helpers hunk (config read + ONE-TIME module-scope config/WARN line before any token/network use; redacting stderr helpers — derived class + numeric status only; VoiceOrigin map with 5-min TTL; sniff cache; STT fetch helper honoring empty `TELEGRAM_VOICE_STT_LANG` = omit `language_code`), `apply_voice(src)` skeleton with all-or-nothing group rollback, `main()` wiring independent of the typing cascade, and the module docstring's numbered list extended to 7 groups.
  - **Self-caught bug (same class as 023's bash `&` footgun, different language):** the six voice constants used as `re.subn` replacement strings contain literal `\n`/`\d` sequences (JS template-literal newlines, a JS regex) — Python's own replacement-template parser reinterprets those (`\n` silently becomes a real newline, `\d` is a hard "bad escape" crash). Fixed structurally: every `re.subn` in `apply_voice` uses a `lambda m: ...` replacement (zero escape processing), not a raw string — mirrors the spirit of 023's `_render_replace_all`.
- [X] T006 [US1] V1 hunk: replace the `bot.on('message:voice')` handler body per contracts C1-C5 — enabled/key check → DM-only read-only pre-check (`chat.type==='private'` + `dmPolicy!=='disabled'` + sender in `allowFrom` via `loadAccess()`) → absent-metadata-safe caps → fire-and-forget `sendChatAction('typing')` → DETACHED pipeline (`void (async () => …)()`, single 30 s AbortController over download+STT, post-download size cap before the paid POST) → success: `handleInbound(ctx, transcript, undefined, {kind:'voice', …})` + `VoiceOrigin[chat] = now`; ANY failure: today's exact placeholder arguments (+ `(voice note over the transcription limit)` annotation for over-cap).
- [X] T007 [US1] V6 hunk: wrap `bot.on('message:text')` — `VoiceOrigin.delete(chat_id)` first, then fall through to the upstream body unchanged (contract C5c).
- [X] T008 [US1] GREEN checkpoint: full `bats tests/apply-telegram-patches.bats` passes (43 pre-existing + T004's inbound set); double-apply idempotent; drift-rollback verified; zero changes to the six existing groups' assertions.
  - 56/56 green.

## Phase 4: User Story 2 — The answer comes back as a playable voice bubble (P2)

**Goal**: replies to voice-originated exchanges carry a native voice bubble alongside
the full text; voice failures never lose the answer. Contracts C6-C10; hunks V2, V3, V4.

**Independent test**: outbound voice tests in `tests/apply-telegram-patches.bats` pass;
inbound (US1) already green.

- [X] T009 [US2] RED — add the outbound voice-group tests to `tests/apply-telegram-patches.bats` (~8, per contract C6-C10 test hooks): voice block anchored AFTER the marker-clear/ack region (after `const result =`, before `return { content:`) — mutation-guard assertions that moving it between chunks and files, or letting a voice error throw, break; reply-mode gate expression + consume-on-read (`delete` before the synthesis call); truncation helper (word-boundary + ellipsis + `TELEGRAM_VOICE_SPOKEN_CHAR_CAP`); `voice_text` in the patched reply inputSchema; instructions line present; `OggS` sniff + `mp3_44100_128` fallback + single shared 30 s deadline; `sendVoice` only in the patched file; `voice tts ok`/`voice tts fail` stderr prefixes with no raw `${err}`. Verify they FAIL.
  - Delivered as 8 tests (57-64). Two authoring bugs caught and fixed during GREEN: a `${err}`-shaped grep context window too narrow, and a literal-quote mismatch in the instructions-line assertion.
- [X] T010 [US2] V2 hunk in `docker/scripts/apply_telegram_typing_patch.py` (+ the `VOICE_TTS_MODEL = "eleven_flash_v2_5"` constant, moved here from T005 — analyze F7): the voice-send block anchored immediately before the reply case's `return { content:` (downstream of the 028 clear/offset-ack sites) per C6/C9 — active/mode/VoiceOrigin gate, consume-on-read, `spoken := voice_text ?? truncate(text, cap)`, TTS helper call with opus-first + sniff + one-time mp3 fallback under ONE 30 s budget, `bot.api.sendVoice` (message_id logged, NOT added to the result), all failures caught → one stderr line → normal tool result (never throws).
- [X] T011 [US2] V3 + V4 hunks: optional `voice_text` property in the reply tool inputSchema (description per data-model §6) and the instructions-array line (voice convention: `attachment_kind="voice"` messages arrive transcribed; provide `voice_text` — with the substantive answer in the first reply — when answering them).
- [X] T012 [US2] GREEN checkpoint: full `bats tests/apply-telegram-patches.bats` green (inbound + outbound sets); idempotency and rollback still hold with all six hunks present.
  - 64/64 green.

## Phase 5: User Story 3 — Declared, opt-in, regenerate-safe (P3)

**Goal**: `features.voice` in agent.yml drives everything; disabled backfill; docker-only
wizard offer; sanitized env delivery; local mode inert. Contracts C11-C15.

**Independent test**: `bats tests/voice-config.bats` + the docker-render/local-render
additions pass on a workspace scaffolded/regenerated from fixtures.

- [X] T013 [P] [US3] RED — create `tests/voice-config.bats` (~9, contracts C11-C14): `--regenerate` on a pre-032 agent.yml backfills the DISABLED block (`has()`-guarded, never `//`); operator's explicit `enabled: true` / custom `reply_mode` / explicit `false` survive untouched; sanitizers render `reply_mode: bogus` → `auto` and `user.language: mixed` → `TELEGRAM_VOICE_STT_LANG: ""` while the SAME `mixed` agent's regenerated `CLAUDE.md` still says `mixed` (`USER_LANGUAGE` untouched — analyze F1); `.env.example` gains the `ELEVENLABS_API_KEY=` name-only line + the two tuning knobs; two consecutive `--regenerate` runs byte-identical (SC-005). Use `install_claude_stub` (hermetic seam, 025). Verify FAIL.
  - Delivered as 9 tests, all green on first implementation pass.
- [X] T014 [P] [US3] RED — add render oracles: in `tests/docker-render.bats` assert the five `TELEGRAM_VOICE_*` `environment:` lines with sanitized values; in `tests/local-render.bats` add the FR-011 oracle (a voice-ENABLED `deployment.mode: local` agent.yml renders NO `TELEGRAM_VOICE_` string in any local RUNTIME artifact — units, rendered scripts, `.mcp.json`, `remote-control.env`; `.env.example` exempt by design). Verify FAIL.
- [X] T015 [US3] `setup.sh` — declarative surface: `features.voice` block in the wizard heredoc (defaults per data-model §1) + docker-mode-gated wizard prompts (`ask_yn` offer, default no; on yes → `enabled: true` + `ask` for `voice_id`; prompts live in setup.sh only — `wizard.sh`/`wizard-gum.sh` untouched) + update the three wizard touchpoints in the same task: `wizard_answers` helper, the e2e-smoke prompt array, and `known_external` in `tests/schema.bats` (local-mode answer streams gain NO voice prompt).
  - The e2e-smoke prompt array needed NO edit: verified live that its answer stream already runs dry before the vault/optional-plugins/review prompts and relies on `ask_yn`'s own EOF→default fallback — a new docker-only EOF-defaulted prompt in between doesn't change that (test still green). Verified BOTH modes manually end-to-end: docker consumes one extra `n` at the right spot; local asks nothing and still backfills the disabled block.
- [X] T016 [US3] `setup.sh` — backfill in `regenerate()`: `has("voice")`-guarded on `.features`, absent ⇒ write the full disabled block verbatim, present ⇒ untouched (mirror the 028/031 backfill shape; NEVER `//`).
- [X] T017 [US3] `setup.sh` — render sanitizers + re-exports after `render_load_context` (029 `mcp_timeout_effective` mold): `FEATURES_VOICE_REPLY_MODE` ∈ {auto,always,never} else `auto`; `FEATURES_VOICE_PROVIDER` → `elevenlabs`; `FEATURES_VOICE_VOICE_ID` trimmed; STT lang from `user.language` ∈ {es,en} else empty, exported as the DEDICATED derived placeholder `VOICE_STT_LANG` — NEVER re-export `USER_LANGUAGE` itself (`modules/claude-md.tpl` consumes it; analyze F1) (contract C12).
- [X] T018 [US3] Templates: five unconditional `TELEGRAM_VOICE_*` lines in `modules/docker-compose.yml.tpl` `environment:` (beside `TZ`/`MCP_TIMEOUT`; the STT-lang line reads `{{VOICE_STT_LANG}}`, not `{{USER_LANGUAGE}}` — analyze F1) and the `ELEVENLABS_API_KEY=` + `TELEGRAM_VOICE_MAX_NOTE_SECONDS` + `TELEGRAM_VOICE_SPOKEN_CHAR_CAP` name-only documented lines in `modules/env-example.tpl`; add `{{VOICE_STT_LANG}}` to `known_external` in `tests/schema.bats`.
- [X] T019 [US3] GREEN checkpoint: `bats tests/voice-config.bats tests/docker-render.bats tests/local-render.bats tests/schema.bats` all green; double-`--regenerate` byte-identical on a fixture workspace; a docker-mode fixture scaffold carries the sanitized env and a local-mode one passes the runtime-inertness oracle.
  - 9+72+5 = 86/86 green across the four files.

## Phase 6: Polish & cross-cutting

- [X] T020 [P] Create `tests/docker-e2e-voice.bats` (DOCKER_E2E=1 gated, model `tests/docker-e2e-askq-guard.bats`, ~4 tests): image builds; the baked patcher yields the prefixed voice marker + V1-V6 hunks inside the pinned image's plugin copy; compose env delivery (`docker compose run --rm -T --user agent … env | grep '^TELEGRAM_VOICE_'` asserts the five sanitized vars); no-key fault injection observes the V5 module-scope WARN line. Must parse and skip cleanly without a docker daemon.
  - 4 tests, parses and skips cleanly confirmed (no docker daemon in this environment).
- [X] T021 [P] `shellcheck -S error` with the exact CI command over every touched shell file — rc=0.
  - rc=0, exact CI find+xargs command reproduced verbatim.
- [X] T022 Mutation spot-checks (6/6, each must break ≥1 test, then restore): (a) remove the inbound fail-open try/catch; (b) move the V2 block between chunks and files; (c) drop the `dmPolicy` guard from the pre-check; (d) revert the backfill to enabled-by-default; (e) make the voice block re-throw on TTS failure; (f) set VoiceOrigin on the placeholder path. Record which tests each mutation broke.
  - (a) broke "fail-open floor" — but only after strengthening it from `-ge 4` to an exact `-eq 7` count + a dedicated catch-block assertion (the original threshold was too weak to notice one dropped call site). (b) broke "voice block anchors AFTER…". (c) broke "DM-only pre-check…". (d) broke 2 tests in voice-config.bats (the backfill test + the disabled-unconditional-render test). (e) broke "a synthesis/send failure never throws…". (f) broke "voice-origin is set only on success…". All 6 reverted cleanly (byte-identical to pre-mutation via file backup diff).
- [X] T023 Full suite gate: `bats tests/` green under bash 5.x AND bash 3.2.57 (`PATH=/bin:$PATH`), byte-identical output (documented pre-existing bash-conditional skips excepted); delta vs T001's baseline fully accounted for by the new tests.
  - bash 3.2.57: **1336 ok / 0 not ok** (two separate runs, both clean). bash 5.3.15: 1334/2 when run CONCURRENTLY with the 3.2.57 pass (both flakes are `tests/heartbeat-auth-detection.bats`, a documented pre-existing contention flake — confirmed 7/7 green in isolation), then **1336/0** in a clean solo re-run — byte-identical to 3.2.57. Delta vs the 1299 pre-032 baseline (T001) = +37, matching the new test count (20 in apply-telegram-patches.bats + 9 voice-config.bats + 2 docker-render.bats + 1 local-render.bats + 1 schema.bats known_external + 4 docker-e2e-voice.bats = 37).
- [X] T024 Version + docs: `VERSION` 0.22.0 → 0.23.0 (re-verify `origin/main` first); `CHANGELOG.md` entry (US1/US2/US3, opt-in semantics, cost note, caps + env overrides, DM-only v1, detached pipeline); `README.md` "Two-way Telegram chat" section gains the voice subsection (7th patch group, key name, quickstart pointer).
  - `origin/main` re-verified `0.22.0` both before and after. CHANGELOG + README done.
- [ ] T025 DEFERRED to the v0.23.0 deploy (docker host + operator key): run `DOCKER_E2E=1 bats tests/docker-e2e-voice.bats`; close gate E1 with the first real synthesis (`fmt=ogg` vs `fmt=mp3` per quickstart §4, ~$0.001).
- [ ] T026 DEFERRED to the v0.23.0 deploy (ferrari, live agent): SC-001 full voice round trip per quickstart §2 — including its SC-002 timing step (send-to-`voice stt ok` delta + interleaved text during a long note proves non-blocking), the SC-003 multi-client render check (unconditional, both `fmt=ogg|mp3`), the SC-006 provider-usage cost check (≤$0.05), and the FR-001 no-echo observation; fault-injection table §3 (SC-004/SC-007, incl. the group-chat DM-only row); E2 Chilean-Spanish A/B (§5, non-blocking).

## Dependencies

```text
T001 → T002 → {T003}
T003 → US1: T004 → T005 → T006 → T007 → T008
US1 → US2: T009 → T010 → T011 → T012          (same files: patcher + patches.bats)
T003 → US3: {T013, T014} → T015 → T016 → T017 → T018 → T019
            (US3 touches setup.sh/templates/config tests — independent of the patcher,
             may proceed in parallel with US1/US2 after T003)
{US2, US3} → Polish: {T020, T021} → T022 → T023 → T024 → {T025, T026 deferred}
```

## Parallel opportunities

- T013 + T014 ([P], different test files).
- The whole US3 phase vs US1/US2 (disjoint file sets after T003).
- T020 + T021 ([P], new e2e file vs shellcheck).

## Implementation strategy

MVP = Phase 3 (US1): inbound transcription alone already delivers hands-free
instruction-giving with zero outbound risk. US2 completes the loop; US3 makes it
operable fleet-wide. T025/T026 are deploy-gated by design (no docker daemon / live
agent here) and ride the pending fleet upgrade — they do not block the PR, mirroring
031's T022/T023 precedent.
