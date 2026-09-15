# Tasks: Voice reply feedback + explicit audio requests (voice group v2)

**Input**: Design documents from `/specs/033-voice-reply-feedback/`

**Prerequisites**: plan.md, spec.md, research.md (D1–D13 + review remediation), data-model.md, contracts/{reply-voice-outcome, explicit-audio-request, voice-group-v2-upgrade}.md, quickstart.md

**Tests**: MANDATORY (constitution Principle III — test-first). Every behaviour task is preceded by a RED bats task. All negative assertions use bats-live forms (`run grep -q …; [ "$status" -ne 0 ]` or `[ "$(grep -c …)" -eq 0 ]`), never a bare intermediate `! grep` (memory note `bats-intermediate-double-bracket-quirk`; research baseline row 10).

**Organization**: Tasks are grouped by user story. All production code lives in ONE file (`docker/scripts/apply_telegram_typing_patch.py`) and its two test files, so stories are implemented sequentially on that file; each story still has its own RED→GREEN oracles and is independently verifiable.

**Line numbers**: the `:NNN` references in research.md/contracts are PRE-T001. T001 removes ~150 lines from `tests/apply-telegram-patches.bats` (the heredoc). From T004 on, locate existing tests by their `@test` NAME, quoted below.

**Post-analyze (2026-09-14, `wf_d975526e-1ca`)**: 24 findings remediated in this file and the sibling artifacts — see spec.md Clarifications "post-analyze" note. Canonical strings that MUST be identical across test and implementation tasks are marked **CANON**.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1–US4)
- Include exact file paths in descriptions

## Path Conventions

- Patcher (image-baked): `docker/scripts/apply_telegram_typing_patch.py`
- Host tests: `tests/apply-telegram-patches.bats`; fixtures: `tests/fixtures/`
- Gated e2e: `tests/docker-e2e-voice.bats`
- Docs: `README.md`, `CHANGELOG.md`, `VERSION`, `CLAUDE.md`
- Scratch: `SCRATCH=$(mktemp -d)` (or the session scratchpad); never inside the repo

---

## Phase 1: Setup (fixtures + baseline)

**Purpose**: Establish the two committed fixtures the whole feature's oracles rest on, and a measured GREEN baseline.

- [X] T001 Extract the inline `server.ts` heredoc from `tests/apply-telegram-patches.bats` `setup()` — ONLY the first heredoc (`cat > "$TMP_TEST_DIR/server.ts" <<'TS'` … `TS`, pre-edit lines 30–175; the three later `server.v1/v2/v3.ts` heredocs are typing fixtures and stay inline) — byte-for-byte into `tests/fixtures/telegram-server-pristine.ts`; replace it with `cp "$REPO_ROOT/tests/fixtures/telegram-server-pristine.ts" "$TMP_TEST_DIR/server.ts"`; keep the 12-anchor comment block above it. Verify: `git show HEAD:tests/apply-telegram-patches.bats | awk '/<<.TS.$/{f=1;next} /^TS$/{if(f)exit} f' | shasum -a 256` equals `shasum -a 256 tests/fixtures/telegram-server-pristine.ts` (146 lines — the first heredoc only; the naive `f=0` form concatenates all four heredocs, 249 lines), and `bats tests/apply-telegram-patches.bats` is still 64/64 GREEN.
- [X] T002 Generate the GOLDEN v1 fixture `tests/fixtures/telegram-server-voice-v1.ts` (research D8): `SCRATCH=$(mktemp -d); git show a7eb2e5:docker/scripts/apply_telegram_typing_patch.py > "$SCRATCH/patcher-v0.23.0.py"`; `cp tests/fixtures/telegram-server-pristine.ts tests/fixtures/telegram-server-voice-v1.ts`; `python3 -B "$SCRATCH/patcher-v0.23.0.py" tests/fixtures/telegram-server-voice-v1.ts`. Verify: `grep -c "telegram voice roundtrip patch v1"` = 1, `grep -c "typing refresh patch v6"` ≥ 1, all seven v0.23.0 markers present, and running the CURRENT patcher (`docker/scripts/apply_telegram_typing_patch.py`, still v1) on a copy is a no-op (sha unchanged). Record the file's sha256 in `specs/033-voice-reply-feedback/research.md` D8.
- [X] T003 Baseline: run `bats tests/` under bash 5.x AND `PATH=/bin:$PATH bats tests/` (3.2.57); record ok/not-ok counts and any pre-existing flakes (expected: the known `heartbeat-auth-detection.bats` contention flake only) in `specs/033-voice-reply-feedback/tasks.md` under Notes. Run `shellcheck -S error` with the exact CI command; must be rc=0.

**Checkpoint**: two fixtures committed-ready, suite GREEN with the fixture-based `setup()`, baseline numbers recorded.

---

## Phase 2: Foundational (oracle churn, dead negatives, marker bump + upgrade path)

**Purpose**: The v1→v2 group bump and its upgrader are the backbone every story ships on. Must be GREEN before any story's hunks are written.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

- [X] T004 Move the existing v1-pinned oracles in `tests/apply-telegram-patches.bats` to v2 expectations and confirm they go RED: in `@test "032 inbound: marker present exactly once on a fresh fixture"`, `@test "032 inbound: double-apply is idempotent (voice marker count stable, file unchanged)"` and `@test "032 inbound: typing cascade v1→…→v6 is unaffected by the voice group"` change the literal `patch v1` → `patch v2`; in `@test "032 outbound: voice block anchors AFTER the 028 marker-clear/offset-ack site, before return"` change the return-line grep to `text: result + _voiceOutcome }`; in `@test "032 inbound: anchor drift on message:voice handler → voice skipped, other groups still apply"` replace the dead `! grep -q "…patch v1"` with `[ "$(grep -c "telegram voice roundtrip patch v2" "$TMP_TEST_DIR/server.ts")" -eq 0 ]` (stays GREEN — no RED expected). Do NOT touch `tests/docker-e2e-voice.bats` here (T021 owns that file). Run: exactly 4 RED in the host file.
- [X] T005 Repair the dead 032 negatives in `tests/apply-telegram-patches.bats` to live forms — in `@test "032 inbound: stt failure lines never interpolate a raw error object or a URL"` rewrite the three `! grep -q` lines as `run grep -q PATTERN file; [ "$status" -ne 0 ]`, and NARROW the `file/bot` check to stderr lines only (`grep 'process.stderr.write' snippet | grep -c 'file/bot'` = 0 — the handler legitimately builds the URL, research row 10); in `@test "032 inbound: the voice handler never calls sendMessage or ctx.reply — no transcript echo"` (first line), `@test "032 outbound: sendVoice appears only in the patched voice group, never in the baseline"` (first line) and the test containing `! grep -q '^\s*throw '` rewrite each intermediate negative to the `run …; [ "$status" -ne 0 ]` form. Run the file: must be GREEN except the 4 RED from T004 — any NEW red means an assertion was wrong, not just dead: investigate before weakening.
- [X] T006 Write the Foundational 033 tests in a new section `# ── 033: voice group v2 upgrade (contracts/voice-group-v2-upgrade.md C5) ──` of `tests/apply-telegram-patches.bats`: G1 (markers + sentinel ONLY — the other C5 G1 items are owned by T009/T013/T017/T020) fresh pristine → `patch v2` count 1, `patch v1` count 0, `voice helpers end (033)` count 1; G2 `cp "$REPO_ROOT/tests/fixtures/telegram-server-voice-v1.ts" golden.ts; python3 "$PATCHER" golden.ts; python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"; shasum equal`; G2b fidelity via `python3 -B - "$PATCHER" "$REPO_ROOT/tests/fixtures/telegram-server-voice-v1.ts" <<'PY'` (inside: `import sys, os; sys.path.insert(0, os.path.dirname(sys.argv[1])); import apply_telegram_typing_patch as p; golden = open(sys.argv[2]).read()`) asserting `MARKER_VOICE_V1`, `VOICE_HELPERS_V1`, `VOICE_TEXT_WRAP_V1`, `VOICE_REPLY_BLOCK_V1 + _REPLY_RETURN_V1`, `VOICE_SCHEMA_PROPERTY_V1`, `VOICE_INSTRUCTIONS_LINE_V1` are each a substring of `golden`; G2c reverse round trip (fresh v2 → replace v2 constants by `_V1` twins via the same import → patcher → sha equals fresh); G3 second run on both upgraded files byte-identical AND `patch v2` count 1 in both; G4 golden with its instructions line edited out-of-band (`sed` the 032 sentence to a different string), `run python3 "$PATCHER" golden.ts` → exit 0, `echo "$output" | grep -q 'voice v1→v2 upgrade: hunk 5 anchor not found'`, `patch v1` count 1, `patch v2` count 0, `voice_text: {` count 1, other six markers present; G6 golden with the typing marker reverted to v4 (the perl technique of `@test "028/031: a v4-patched server.ts cascades through v5 all the way to v6"`) → one pass yields typing v6 AND voice v2. Run: G1, G2, G2b, G2c, G3 (v2 count), G4 (WARN grep), G6 RED; the remaining sub-assertions of G3/G4 are trivially GREEN before T007 by construction — that is expected.
- [X] T007 Implement the group bump and upgrader in `docker/scripts/apply_telegram_typing_patch.py`: add `MARKER_VOICE_V1 = "agentic-pod-launcher: telegram voice roundtrip patch v1"` and set `MARKER_VOICE` to `…patch v2`; BEFORE editing any voice constant, copy the current `VOICE_HELPERS`, `VOICE_TEXT_WRAP`, `VOICE_REPLY_BLOCK`, `VOICE_SCHEMA_PROPERTY`, `VOICE_INSTRUCTIONS_LINE` verbatim as `*_V1` (the `_V1` helpers block keeps the literal v1 marker text, not `MARKER_VOICE`); add `_REPLY_RETURN_V1` / `_REPLY_RETURN_V2`; append the sentinel line `// agentic-pod-launcher: voice helpers end (033)\n` to `VOICE_HELPERS` (v2); write `upgrade_voice_v1_to_v2(src)` exactly as contract C2 (five ordered pairs, `count(old) != 1` → `warn(f"voice v1→v2 upgrade: hunk {n} anchor not found (edited out-of-band?) — leaving v1 in place")` + return `(src, False)`, all-or-nothing); change `apply_voice` gate to `if MARKER_VOICE in src or MARKER_VOICE_V1 in src`; change hunk 4 to `lambda m: VOICE_REPLY_BLOCK + _REPLY_RETURN_V2` (replace, not prepend); wire `upgrade_voice_v1_to_v2` in `main()` immediately before `apply_voice`, add its flag to the early-return check and `voice-upgrade-v1→v2` to `parts`; extend the module docstring (voice group v2 + upgrade). At this point v2 content = v1 content + marker + return line + sentinel. Run: T006 GREEN; T004's four oracles GREEN; the whole host file GREEN.

**Checkpoint**: `bats tests/apply-telegram-patches.bats` GREEN; the golden v1 upgrades in place and converges byte-for-byte with a fresh install; a wrong `_V1` twin is detectable (mutation 7 of quickstart §1: flip one byte of `VOICE_HELPERS_V1` → G2 and G2b RED, then revert).

---

## Phase 3: User Story 1 — The agent learns, in the same turn, what its voice did (Priority: P1) 🎯 MVP

**Goal**: The `reply` acknowledgement carries a deterministic `voice: sent (…)` / `voice: failed (step=…, cls=…, status=…)` line whenever the voice step ran, byte-identical otherwise (FR-001, FR-002, FR-003, FR-008; contract reply-voice-outcome.md C1–C4).

**Independent Test**: on the patched pristine fixture, the reply block declares `let _voiceOutcome = ''` as the first statement after the (032) comment, assigns exactly the two contract templates inside the existing try/catch, flips `_voiceStep` between synthesize and send, passes the abort signal to `sendVoice` (if T008 confirms the parameter), and the return is `result + _voiceOutcome`; whitelist positives present, live negatives absent.

### Pre-check (read-only, decides the exact strings T009 pins)

- [X] T008 [US1] Verify the grammY `signal` parameter claim (research D3, NOT VERIFIED) BEFORE writing any oracle: on ferrari, `ssh ssh-ferrari "docker exec -u agent linus sh -lc 'grep -n \"sendVoice\" ~/.claude/plugins/cache/claude-plugins-official/telegram/*/node_modules/grammy/out/core/api.d.ts | head'"` (or wherever the plugin's grammy typings live — `find … -name api.d.ts`); confirm a trailing `signal?: AbortSignal` parameter on `sendVoice`. Record the result (with the typings path and grammY version) in `specs/033-voice-reply-feedback/research.md` D3 and in contract reply-voice-outcome.md C4. If CONFIRMED: T009(d)/T010 use the 4-argument call. If ABSENT: T009(d) asserts the 2-argument call `bot.api.sendVoice(chat_id, new InputFile(buf, \`voice.${fmt}\`))`, T010 keeps it, and C4 + contract C5 G8 record "send leg unbounded by the 30 s budget".

### Tests for User Story 1 (write FIRST, confirm RED)

- [X] T009 [US1] Add to `tests/apply-telegram-patches.bats` section `# ── 033 US1: reply acknowledgement carries the voice outcome ──`, all line-number checks on the block extracted with `awk '/agentic-pod-launcher: voice roundtrip outbound synthesis/{f=1} f{print; if (/^        return \{ content/) exit}'`: (a) the (032) comment line < `let _voiceOutcome = ''` < `if (VOICE_ACTIVE && VOICE_REPLY_MODE !== 'never')` < `return { content: [{ type: 'text', text: result + _voiceOutcome }] }`; (b) `grep -F` the exact success template **CANON-S** `` _voiceOutcome = `\nvoice: sent (fmt=${fmt}, chars=${spoken.length}, ms=${_voiceMs})` `` and the exact failure template **CANON-F** `` _voiceOutcome = `\nvoice: failed (step=${_voiceStep}, cls=${cls}, status=${status})` ``; (c) G8: line order `await _voiceSynthesize(spoken` < `_voiceStep = 'send'` < `bot.api.sendVoice(chat_id` and the stderr fail line is exactly `` `telegram channel: voice tts fail: ${cls} status=${status} step=${_voiceStep} chat=${chat_id}\n` ``; (d) per T008: the 4-argument `sendVoice(chat_id, new InputFile(buf, \`voice.${fmt}\`), undefined, _voiceController.signal)` OR the 2-argument form; (e) whitelist negatives on the extracted block, each as `run grep -q … snippet; [ "$status" -ne 0 ]`: `${err`, `${url`, `${spoken}` (literal — `${spoken.length}` does not match it), `${text`, `${VOICE_ID`, `file/bot`; (f) `_voiceErrClass` contains the substring **CANON-E** `typeof err === 'object' && err !== null && typeof (err as { error_code?: unknown }).error_code === 'number'`; (g) `[ "$(grep -c '^ *_voiceOutcome = ' "$TMP_TEST_DIR/server.ts")" -eq 2 ]` (the `let` line starts with `let`; `+=` is not `= `) — byte-identity guard; (h) FR-008 structure: within the extracted block, `try {` < CANON-S line < `} catch (err)` < CANON-F line < `} finally {`, and no `_voiceOutcome` line after `} finally {`. Run: RED.

### Implementation for User Story 1

- [X] T010 [US1] Rewrite `VOICE_REPLY_BLOCK` (v2) in `docker/scripts/apply_telegram_typing_patch.py` per research D1–D3: the (032) comment line stays first, `let _voiceOutcome = ''` is the FIRST statement after it (still inside the constant, so G2c contiguity holds); inside the branch `const _voiceStarted`, `let _voiceStep: 'synth' | 'send' = 'synth'`; try → synthesize → `_voiceStep = 'send'` → `sendVoice` in the form T008 decided → `const _voiceMs = Date.now() - _voiceStarted` → existing `voice tts ok` stderr line (using `_voiceMs`) → **CANON-S**; catch → `_voiceErrClass(err)` → stderr `voice tts fail: ${cls} status=${status} step=${_voiceStep} chat=${chat_id}` → **CANON-F**; finally unchanged. Keep `_voiceOriginConsume(chat_id)` before synthesis. Every `\n` inside JS template literals is `\\n` in the Python literal. Run T009(a)(b)(c)(d)(e)(g)(h) → GREEN; T006 G2/G2c still GREEN.
- [X] T011 [US1] Extend `_voiceErrClass` inside `VOICE_HELPERS` (v2) in `docker/scripts/apply_telegram_typing_patch.py` per contract C4 with exactly this line after the `AbortError` check: `if (typeof err === 'object' && err !== null && typeof (err as { error_code?: unknown }).error_code === 'number') return { cls: 'transport', status: String((err as { error_code: number }).error_code) }` (contains **CANON-E**); keep the `-status-(\d+)$` rule (`\\d` in the Python literal). Run: T009(f) GREEN.

**Checkpoint**: US1 GREEN on host; byte-identity when the voice step does not run is guarded by T009(a)(g)(h).

---

## Phase 4: User Story 2 — The channel's stated contract tells the truth about outbound voice (Priority: P1)

**Goal**: The instructions line and the `voice_text` description state the facts (automatic voice on voice notes AND explicit requests, never claim inability, ONE reply, omission consequence, `voice:` line not relayed, one failure mention, `voice_force` for unrecognised wording); the fleet's v1 files are upgraded in place (FR-004, FR-005; contract reply-voice-outcome.md C5).

**Independent Test**: patched pristine AND upgraded golden both carry the v2 wording verbatim and no v1 wording; the 032 substrings are preserved.

### Tests for User Story 2 (write FIRST, confirm RED)

- [X] T012 [US2] Add to `tests/apply-telegram-patches.bats` section `# ── 033 US2: contract wording v2 ──`: on BOTH the patched pristine and the upgraded golden: `grep -F` each mandatory clause of contract C5 — `AUTOMATICALLY sends your reply as a voice note too`, `explicitly asks for an audio reply` (FR-004 explicit-request clause), `never tell the user you cannot send audio`, `answer in ONE reply call`, `include voice_text with a concise speakable version` (032 substring preserved), `your full text is read aloud up to the cap`, `do not repeat it to the user`, `tell the user once, briefly, that the audio did not go out this time`, `set voice_force: true on that reply`; `grep -A 2 "    instructions: \["` still finds `attachment_kind="voice"` (032 oracle preserved); the v1 instructions sentence `arrive transcribed — the message text IS the transcription. When replying to them, include voice_text` count = 0 (live form); the `voice_text` description contains `voice note or explicit audio request`, `Strongly recommended: when omitted` and `reports the omission`. Run: RED.

### Implementation for User Story 2

- [X] T013 [US2] Replace `VOICE_INSTRUCTIONS_LINE` (v2) and the `voice_text` description inside `VOICE_SCHEMA_PROPERTY` (v2) in `docker/scripts/apply_telegram_typing_patch.py` with the exact texts of contract reply-voice-outcome.md C5 (one JS string literal each; keep the `      '…',\n` shape so the `instructions: [\n` anchor + single-line oracle holds). Run T012 → GREEN; T006 G2/G2b/G2c GREEN (the `_V1` twins untouched).

**Checkpoint**: US1 + US2 GREEN; upgraded golden == fresh pristine byte-for-byte.

---

## Phase 5: User Story 3 — Omitting the spoken rendition is observable and corrected in-turn (Priority: P2)

**Goal**: Every synthesis that read `text` (no non-blank `voice_text`) writes an omission record to stderr; above `floor(cap/4)` the acknowledgement names it (FR-006, FR-007; research D4).

**Independent Test**: on the patched pristine, `_voiceFromText` is derived from `voiceTextArg`, the stderr omission line exists and is nested under `if (_voiceFromText) {`, the nag clause is gated by `spoken.length > VOICE_OMISSION_NAG_CHARS`, the constant is `Math.floor(VOICE_SPOKEN_CHAR_CAP / 4)`, and no `> 300` literal exists.

### Tests for User Story 3 (write FIRST, confirm RED)

- [X] T014 [US3] Add to `tests/apply-telegram-patches.bats` section `# ── 033 US3: omission observability ──` (line orders on the block extracted as in T009): `const _voiceFromText = !(voiceTextArg && voiceTextArg.trim())` present; order CANON-S line < `if (_voiceFromText) {` < stderr line `` `telegram channel: voice tts spoke ${spoken.length} chars without voice_text chat=${chat_id}\n` `` < `if (spoken.length > VOICE_OMISSION_NAG_CHARS)` < nag append `` _voiceOutcome += `; voice_text omitted — ${spoken.length} chars of text were read aloud` `` < `} catch (err)` (US3-3: no omission line without `_voiceFromText`; FR-008: all inside the try); G9: `const VOICE_OMISSION_NAG_CHARS = Math.floor(VOICE_SPOKEN_CHAR_CAP / 4)` in the helpers and `[ "$(grep -c '> 300' "$TMP_TEST_DIR/server.ts")" -eq 0 ]`; `[ "$(grep -c 'process.env.TELEGRAM_VOICE_OMISSION' "$TMP_TEST_DIR/server.ts")" -eq 0 ]` (FR-007). Run: RED.

### Implementation for User Story 3

- [X] T015 [US3] Implement in `docker/scripts/apply_telegram_typing_patch.py`: add `const VOICE_OMISSION_NAG_CHARS = Math.floor(VOICE_SPOKEN_CHAR_CAP / 4)` to `VOICE_HELPERS` (v2, before the sentinel); in `VOICE_REPLY_BLOCK` (v2) derive `spoken` from `_voiceFromText` (`_voiceFromText ? _voiceTruncate(text, VOICE_SPOKEN_CHAR_CAP) : (voiceTextArg as string).trim()`), and immediately after the CANON-S assignment, still inside the try, add `if (_voiceFromText) { stderr omission line; if (spoken.length > VOICE_OMISSION_NAG_CHARS) { _voiceOutcome += … } }` exactly as research D4. Run T014 → GREEN; T009(g)(h) still GREEN (the `+=` is not `= `; nothing after `} finally`).

**Checkpoint**: US1–US3 GREEN.

---

## Phase 6: User Story 4 — An explicit request for audio is honoured, strictly (Priority: P2)

**Goal**: A typed DM containing a phrase from the fixed table marks the exchange voice-originated (same gate as 032, one reply, mode ≠ `never`); `voice_force` is a strict third trigger; a one-shot cooldown in mode `always` breaks the failure→mention→failure loop (FR-011–FR-014, FR-012 cooldown; contracts explicit-audio-request.md C1–C3, reply-voice-outcome.md C7; research D5, D6, D13).

**Independent Test**: on the patched pristine: phrase table complete, normaliser and matcher present with negation guard and all-occurrence scan, backslash escapes emitted literally, wrap gated on the 032 DM gate (null-guarded `ctx.from`) + `VOICE_ACTIVE` + mode ≠ `never`, `_voiceOriginSet(String(ctx.chat!.id))` inline, `_voiceOriginSet(chat_id)` still exactly once, `voice_force` property + strict read + `|| _voiceForce`, cooldown set-on-failure gated on `always` and consumed before synthesis. Behaviour of the matcher itself is proven under bun in E5 (T022).

### Tests for User Story 4 (write FIRST, confirm RED)

- [X] T016 [US4] Add to `tests/apply-telegram-patches.bats` section `# ── 033 US4: explicit audio request (matcher + wrap) ──`: (a) `const VOICE_REQUEST_PHRASES: readonly string[] = [` present and each of the 23 Spanish and 15 English phrases of contract explicit-audio-request.md C1 appears as a quoted element (loop `for p in …; do grep -F -q "'$p'" …; done`); (b) `function _voiceNormalize(` contains `.normalize('NFD')`, the ESCAPED class as fixed strings `[\u0300-\u036f]` and `[\u2018\u2019\u02bc\u00b4\`]` (the TS carries escape sequences, not glyphs — research D10), `.toLowerCase()`; (c) `function _voiceRequestMatch(` contains a loop advancing `indexOf(p, ` from the previous index (all occurrences), the boundary test `/[a-z0-9]/`, and `_VOICE_REQUEST_NEGATION.test(t.slice(0, i))`; (d) `const _VOICE_REQUEST_NEGATION = /(?:^|[\s,;:—-])(?:no|nunca|jamas|sin|don't|dont|do not|never|stop)\b[^.!?\n]{0,30}$/` present verbatim (`grep -F`, single-quoted); (e) the sentinel `// agentic-pod-launcher: voice helpers end (033)` line number > every `_voice*` helper definition and < the first `bot.on(` line; (f) G11 backslash literals: `grep -F '[\u0300'` and `grep -F '\s+'` on the patched pristine both match. Run: RED.
- [X] T017 [US4] Add to the same section: (g) the `message:text` wrap, extracted with `awk '/^bot\.on\(.message:text./{f=1} f{print; if (/^\}\)$/) exit}'`, contains in order `_voiceOriginClear(String(ctx.chat!.id))` (verbatim, 032 oracle), `const access = loadAccess()`, an `isDm` expression with `ctx.chat?.type === 'private'`, `access.dmPolicy !== 'disabled'`, `ctx.from != null`, `access.allowFrom.includes(String(ctx.from.id))`, then `if (VOICE_ACTIVE && VOICE_REPLY_MODE !== 'never' && isDm && _voiceRequestMatch(ctx.message.text))`, `_voiceOriginSet(String(ctx.chat!.id))`, the stderr line `telegram channel: voice request detected chat=`, then `await handleInbound(ctx, ctx.message.text, undefined)`; (h) `[ "$(grep -c '_voiceOriginSet(chat_id)' "$TMP_TEST_DIR/server.ts")" -eq 1 ]` (032 oracle preserved) and `[ "$(grep -c 'const chat_id' wrap_snippet)" -eq 0 ]`; (i) `voice_force: {` appears after `voice_text: {` and before `required: ['chat_id', 'text']`, with `type: 'boolean'` and the C5 description substring `Set ONLY when the user asked for an audio reply in wording the channel did not recognise`; (j) `const _voiceForce = args.voice_force === true` and the condition `if (VOICE_REPLY_MODE === 'always' || _voiceFresh || _voiceForce)`; `[ "$(grep -c 'Boolean(args.voice_force)' "$TMP_TEST_DIR/server.ts")" -eq 0 ]`; (k) G10 cooldown: `const _voiceCooldown = new Map<string, number>()`, `function _voiceCooldownConsume(chatId: string): boolean` using `_VOICE_ORIGIN_TTL_MS`, in the catch `if (VOICE_REPLY_MODE === 'always') _voiceCooldown.set(chat_id, Date.now())`, and in the branch the line `if (VOICE_REPLY_MODE === 'always' && _voiceCooldownConsume(chat_id))` precedes `await _voiceSynthesize` and is followed by the stderr line `telegram channel: voice skip: cooldown after failure chat=`. Run: RED.

### Implementation for User Story 4

- [X] T018 [US4] Implement the matcher in `VOICE_HELPERS` (v2) of `docker/scripts/apply_telegram_typing_patch.py` per research D5 / contract C1: `VOICE_REQUEST_PHRASES` (23 ES + 15 EN, normalised forms), `_VOICE_REQUEST_NEGATION`, `_voiceNormalize` (NFD → strip `[\u0300-\u036f]` → map `[\u2018\u2019\u02bc\u00b4\`]` to `'` → lowercase → collapse whitespace → trim — the regex classes are written with `\uXXXX` escapes in the TS, i.e. `\\u0300` etc. in the Python literal), `_voiceRequestMatch` (per phrase: `let i = t.indexOf(p); while (i >= 0) { boundary + negation checks; if ok return true; i = t.indexOf(p, i + 1) }`), `_voiceCooldown` + `_voiceCooldownConsume` — all BEFORE the sentinel. Every backslash doubled in the Python literal (`\\u0300`, `\\u036f`, `\\u2018`, `\\u2019`, `\\u02bc`, `\\u00b4`, `\\s`, `\\b`, `\\n`). Run T016 → GREEN.
- [X] T019 [US4] Rewrite `VOICE_TEXT_WRAP` (v2) in `docker/scripts/apply_telegram_typing_patch.py` per contract C2: keep the 032 comment and `_voiceOriginClear(String(ctx.chat!.id))` verbatim; add `// agentic-pod-launcher: explicit audio request (033)`, `const access = loadAccess()`, `const isDm = …` (four conjuncts incl. `ctx.from != null`), the gated `if` with `_voiceOriginSet(String(ctx.chat!.id))` and the `voice request detected` stderr line; then the unchanged `await handleInbound(ctx, ctx.message.text, undefined)`. No local named `chat_id`. Run T017(g)(h) → GREEN.
- [X] T020 [US4] In `docker/scripts/apply_telegram_typing_patch.py`, add the `voice_force` property to `VOICE_SCHEMA_PROPERTY` (v2) after `voice_text` (contract C5 text) and, in `VOICE_REPLY_BLOCK` (v2), `const _voiceForce = args.voice_force === true`, the extended condition, the cooldown consume line (before `_voiceStarted`/synthesis, mode `always` only) with its stderr line, and the cooldown set in the catch (mode `always` only, before CANON-F) — per contract C7. Run T017(i)(j)(k) → GREEN; T009/T014 still GREEN; T006 G2/G2c GREEN.

**Checkpoint**: all four stories GREEN on host; `bats tests/apply-telegram-patches.bats` = 64 + T006 (7) + T009 (1–2) + T012 (1) + T014 (1) + T016/T017 (2–3) ≈ 77–78 tests; upgraded golden == fresh pristine.

---

## Phase 7: DOCKER_E2E harness (self-seeding) — parse-clean, gated, deploy-deferred RUN

**Purpose**: Make the image-baked path testable at all (research row 8: the inherited harness could never find a plugin file) and add the behavioural checks only bun can give.

- [X] T021 [P] Rewrite `tests/docker-e2e-voice.bats` (single owner of this file): `setup()` copies `tests/fixtures/telegram-server-pristine.ts` and `tests/fixtures/telegram-server-voice-v1.ts` into `$E2E_AGENT_DIR/.e2e/` (bind-mounted at `/workspace/.e2e/`) and writes `$E2E_AGENT_DIR/.e2e/seed.sh` (`d="$HOME/.claude/plugins/cache/claude-plugins-official/telegram/0.0.6"; mkdir -p "$d"; cp "/workspace/.e2e/${1:-telegram-server-pristine.ts}" "$d/server.ts"; python3 /opt/agent-admin/scripts/apply_telegram_typing_patch.py "$d/server.ts"; echo "$d/server.ts"`); every `docker compose run --rm -T --user agent --entrypoint sh voicebot -c '…'` block starts with `server=$(sh /workspace/.e2e/seed.sh)` (no variable interpolation inside the single-quoted script). Rewrite E1 (`patch v2` count 1, `patch v1` count 0, `voice_force: {`, `text: result + _voiceOutcome`, sentinel, `_voiceOriginClear(String(ctx.chat!.id))`), E2 unchanged, E3 (no-key WARN on the seeded+patched file), E4 (second patcher run → v2 count still 1). Keep the `DOCKER_E2E` skip guard; `bats tests/docker-e2e-voice.bats` without the variable must report all tests skipped, no parse error.
- [X] T022 [P] Add E5 and E8 to `tests/docker-e2e-voice.bats`: after seeding, `awk '/telegram voice roundtrip patch v2/{f=1} f{print} /voice helpers end \(033\)/{exit}' "$server" > /tmp/helpers.ts`; E5 appends a tail that asserts `_voiceRequestMatch` returns true for every positive and false for every negative example of contract explicit-audio-request.md C1 (the `don’t` case written as `'don’t reply with audio'` in the tail), then `TELEGRAM_VOICE_ENABLED=true ELEVENLABS_API_KEY=x bun /tmp/helpers.ts`; E8 appends instead `console.log(JSON.stringify([_voiceErrClass({ error_code: 400 }), _voiceErrClass(new Error('tts-status-404')), _voiceErrClass(Object.assign(new Error('x'), { name: 'AbortError' }))]))` and asserts the output equals `[{"cls":"transport","status":"400"},{"cls":"transport","status":"404"},{"cls":"timeout","status":""}]`.
- [X] T023 [P] Add E6 (parse-only) and E7 (golden upgrade) to `tests/docker-e2e-voice.bats`: E6 runs `bun -e "const t = new Bun.Transpiler({ loader: 'ts' }); t.transformSync(await Bun.file(process.argv[1]).text()); console.log('parse-ok')" "$server"` and asserts `parse-ok` — the FIRST real DOCKER_E2E run measures whether `Bun.Transpiler` is available in the pinned bun; if not, record the alternative in `specs/033-voice-reply-feedback/research.md` D11 and adapt; E7 runs `server=$(sh /workspace/.e2e/seed.sh telegram-server-voice-v1.ts)` and asserts v2 count 1, v1 count 0, and that the seed output/patcher log line contains `voice-upgrade-v1→v2`.

**Checkpoint**: `bats tests/docker-e2e-voice.bats` parses and skips cleanly on the host; the real run is the deploy gate (T029).

---

## Phase 8: Polish, docs, gates

- [X] T024 [P] Update `README.md` "Two-way Telegram chat (docker mode)" — the **Round-trip voice** bullet gains: the `voice:` acknowledgement line (sent/failed, what the agent does on failure), the explicit audio request (with the ES/EN phrase table as a sub-table directly below the bullet, contract explicit-audio-request.md C4), `voice_force`, the omission nag, and the mode-`always` cooldown; keep "seven behaviors"/"seven hooks" counts unchanged (same group, v2).
- [X] T025 [P] Add the `CHANGELOG.md` `[Unreleased]` entry — **Added**: explicit audio request (phrase table, DM gate parity), `voice_force`, voice-outcome acknowledgement line with `step`, omission record + nag, mode-`always` failure cooldown; **Changed**: voice patch group v1→v2 with in-place upgrade (`upgrade_voice_v1_to_v2`), instructions/`voice_text` wording, `sendVoice` bounded by the 30 s budget (if T008 confirmed); **Tests**: fixtures `tests/fixtures/telegram-server-{pristine,voice-v1}.ts`, e2e harness now self-seeding (the 032 E1/E3/E4 could never locate a plugin file), dead 032 negative assertions repaired (`file/bot` narrowed to stderr lines).
- [X] T026 [P] Bump `VERSION` 0.23.0 → 0.24.0 AFTER verifying `git show origin/main:VERSION` is still `0.23.0` (lesson 023: a rebase can auto-merge VERSION without a textual conflict).
- [X] T027 [P] Update `CLAUDE.md` "Telegram plugin patch" section: the voice group is now **v2** (`MARKER_VOICE`), upgraded in place from v1 by `upgrade_voice_v1_to_v2`; summarise the outcome line, explicit request, `voice_force`, cooldown; note the golden fixture and the self-seeding e2e; then use `git add -f CLAUDE.md` (gitignored at root).
- [X] T028 Gates on the host: (1) the eight mutation spot-checks of `specs/033-voice-reply-feedback/quickstart.md` §1 — each must go RED then GREEN on revert, record the test names that caught each; (2) `bats tests/` full suite under bash 5.x and `PATH=/bin:$PATH bats tests/` (3.2.57) — counts must equal T003 baseline + new tests, 0 new not-ok; this run is also the FR-010 oracle (the 032 test in `tests/local-render.bats` asserting zero `TELEGRAM_VOICE_` in local runtime artifacts stays GREEN); (3) `shellcheck -S error` exact CI command rc=0; (4) `python3 -B -m py_compile docker/scripts/apply_telegram_typing_patch.py`; (5) `git status` shows no `__pycache__`; (6) `git diff --stat` touches only the plan.md §Project Structure source files PLUS `specs/033-voice-reply-feedback/**` and `.specify/feature.json` — in particular nothing under `modules/`, `setup.sh`, `scripts/lib/` (FR-010). Record results in tasks.md Notes.
- [ ] T029 PARTIALLY CLOSED (2026-09-14) — the `DOCKER_E2E=1 bats tests/docker-e2e-voice.bats` leg is DONE (8/8 GREEN, this host has a working Docker daemon; see the Phase 7 note above), including the E6 bun-parse measurement (`Bun.Transpiler` works). REMAINING, DEPLOY-DEFERRED (precedent 016/028/031/032, blocked today by a Cloudflare Access re-auth on the ferrari SSH tunnel that only the operator can complete): the live gate per `specs/033-voice-reply-feedback/quickstart.md` §3 on **linus first** (watch `channel plugin healthy`), then donna: SC-001, SC-002 (5 voice notes), SC-003 (10-exchange omission rate ≤ 1/10), SC-004 live leg (an agent with `features.voice.enabled: false` or no key: one typed exchange → `grep -c 'voice: ' ~/.claude/projects/*/*.jsonl` unchanged), SC-006 synth leg + cooldown (bad `voice_id`, mode `always` on one agent only; the send leg is covered by E8 + G8), SC-007/008 (10 typed requests, 10 plain), SC-009 (`voice_force`). Not part of the merge gate; rides the v0.24.0 fleet deploy. rodri-cenco-admin (0.19.0) lands v2 fresh in its own upgrade — do not mix.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: T001 → T002 (golden needs the pristine file) → T003.
- **Foundational (Phase 2)**: T004 → T005 → T006 → T007, all on the same two files; BLOCKS every story.
- **User Stories (Phases 3–6)**: sequential on `docker/scripts/apply_telegram_typing_patch.py` in priority order US1 → US2 → US3 → US4 (same file; each story's tests are independent oracles). Inside US1, T008 (read-only pre-check) MUST precede T009.
- **E2E harness (Phase 7)**: T021–T023 are [P] with Phases 3–6 (different file, skipped locally) but their assertions target the FINAL v2 text — run them last for content review.
- **Polish (Phase 8)**: T024–T027 [P] after Phase 6; T028 after everything; T029 deploy-deferred.

### User Story Dependencies

- **US1 (P1)**: needs Phase 2 only. MVP: the measured lie is fixed by US1 alone (evidence in the acknowledgement).
- **US2 (P1)**: needs Phase 2; its instructions sentence about `voice_force` is inert until US4 lands (both ship in the same PR).
- **US3 (P2)**: needs US1's `_voiceOutcome` success branch (T010).
- **US4 (P2)**: needs US1's reply block shape (T010) for the flag/cooldown lines; the matcher/wrap parts (T018, T019) are independent of US1–US3.

### Within Each User Story

- RED test task → implementation task → checkpoint (T006 G2/G2c must stay GREEN after every constant edit — they are the convergence guard).

### Parallel Opportunities

- T021, T022, T023 (e2e file) alongside Phases 3–6.
- T024, T025, T026, T027 (four different docs files) together after Phase 6.

---

## Parallel Example: Phase 8 docs

```bash
# Four different files, no shared state:
Task: "Update README.md Round-trip voice bullet + phrase table"      # T024
Task: "Add CHANGELOG.md [Unreleased] entry"                          # T025
Task: "Bump VERSION 0.23.0 → 0.24.0 after checking origin/main"      # T026
Task: "Update CLAUDE.md Telegram plugin patch section (git add -f)"  # T027
```

---

## Implementation Strategy

### MVP First (Phase 1 + 2 + US1)

1. Fixtures + baseline (T001–T003).
2. Oracle churn, dead-negative repair, marker bump + upgrader (T004–T007) — the group is now v2 with an in-place upgrade path and a non-tautological convergence oracle.
3. US1 (T008–T011): the acknowledgement tells the agent what its voice did.
4. **STOP and VALIDATE**: `bats tests/apply-telegram-patches.bats` GREEN; mutation 1/2/7.

### Incremental Delivery

- Add US2 (T012–T013): honest contract wording → the first-turn lie is prevented, not just corrected.
- Add US3 (T014–T015): omission measurable.
- Add US4 (T016–T020): explicit request, `voice_force`, cooldown.
- Add Phase 7 harness, Phase 8 docs/gates → PR against main; T029 rides the deploy.

---

## Notes

- Every `re.subn` replacement in the patcher stays a `lambda` (032 rule); every TS backslash is doubled in the Python literal (research D10, oracle G11 in T016(f)).
- CANON strings (CANON-S, CANON-F, CANON-E) are written once in T009 and must be pasted identically by T010/T011 — a spelling drift between test and implementation was the analyze-stage HIGH X4.
- Existing 032 oracles preserved by construction (do NOT edit): `_voiceOriginSet(chat_id)` count == 1, `_voiceOriginClear(String(ctx.chat!.id))` verbatim, the two instructions substrings, `grep -A 2 "instructions: \["` shape.
- A new RED after T005 that is not one of the four T004 REDs means a 032 assertion was wrong, not just dead — investigate; expected candidate: the `file/bot` check (already narrowed in T005).
- Baseline (T003) and gate results (T028) are recorded here at execution time.
- **T003 baseline (2026-09-14)**: `bats tests/` = 1343 ok / 0 not ok (captured after T001-T007: fixtures externalized to `tests/fixtures/`, v1→v2 marker bump + upgrader landed; `tests/apply-telegram-patches.bats` alone was 71/71 at that point). `shellcheck -S error` (exact CI command) rc=0. No pre-existing flakes observed in this run.
- **T008**: ferrari SSH needed a Cloudflare Access re-auth only the operator can complete; verified the grammY `signal` parameter offline instead (`npm pack grammy@1.46.0`, inspected `out/core/api.d.ts` — confirmed, see research.md D3). Live fleet confirmation remains a nice-to-have for the deploy, not a blocker.
- **Phase 3-4 (US1-US2) checkpoint (2026-09-14)**: `bats tests/apply-telegram-patches.bats` = 80/80 GREEN on first correct implementation attempt (two test-authoring bugs caught and fixed before GREEN: a `grep -F` pattern with an embedded literal newline is not portable — this host's `grep` is `ugrep`, which ORs the two lines instead of requiring adjacency; and an FR-008 "nothing after finally" check needs to exclude the case's own `return` line, which legitimately references `_voiceOutcome` by design).
- **Phase 5-6 (US3-US4) checkpoint (2026-09-14)**: `bats tests/apply-telegram-patches.bats` = 92/92 GREEN. One test-authoring bug caught before GREEN: the fixed-string oracle for the typographic-quote class was written without the escaping backslash before the closing backtick (`[‘...´\`]` vs the emitted `\`]`), a second instance of the same "escape sequence vs literal" trap as G11 — fixed by matching the actual emitted bytes.
- **T028 gates (2026-09-14), ALL GREEN**: (1) all 8 mutation spot-checks from quickstart.md §1 run against the live implementation (save pristine → mutate → `bats tests/apply-telegram-patches.bats` → confirm RED → restore pristine → confirm byte-identical to the saved copy) — every one caught by the test named in the quickstart, mutation 4 additionally confirmed behaviorally under bun via `DOCKER_E2E=1 bats tests/docker-e2e-voice.bats --filter matcher` (3/3 predicted false positives reproduced), mutation 7 (flip one byte of `VOICE_HELPERS_V1`) caught not only G2/G2b as predicted but cascaded to G3/G4/G6/US2 too — the corrupted `_V1` twin fails `work.count(old) != 1` on the very first pair, aborting the whole upgrade, so every test depending on the golden reaching v2 goes red with it; this is the tautology guard (research D8) empirically proven, not just designed. (2) `bats tests/` = **1368 ok / 0 not ok** under both default bash (5.3.15) and `PATH=/bin:$PATH` (3.2.57) — byte-identical counts, no new flakes; this run is also the FR-010 oracle (`tests/local-render.bats`'s zero-`TELEGRAM_VOICE_`-in-local-artifacts test stays green, confirmed by the 0-not-ok result). (3) `shellcheck -S error` (exact CI command) rc=0 — no shell files touched by this feature, run anyway per the gate. (4) `python3 -B -m py_compile` on the patcher: OK. (5) no `__pycache__` anywhere in the tree. (6) `git status`/`git diff --stat` scope: exactly `.specify/feature.json`, `CHANGELOG.md`, `CLAUDE.md`, `README.md`, `VERSION`, `docker/scripts/apply_telegram_typing_patch.py`, `tests/apply-telegram-patches.bats`, `tests/docker-e2e-voice.bats` (modified) plus `specs/033-voice-reply-feedback/**` and the two new `tests/fixtures/telegram-server-*.ts` (untracked, to be added) — nothing under `modules/`, `setup.sh`, or `scripts/lib/`, matching plan.md §Project Structure exactly.
- **Phase 7 (DOCKER_E2E) — RUN FOR REAL, not deferred (2026-09-14)**: this host has a working Docker daemon (`docker compose v5.3.1`, arm64), so `DOCKER_E2E=1 bats tests/docker-e2e-voice.bats` was executed to completion: **8/8 GREEN**, closing the DOCKER_E2E leg of T029 ahead of the deploy. Two real bugs found and fixed via direct container reproduction (not guessed): (1) `apply_telegram_typing_patch.py`'s `log()` writes its summary to STDOUT, not stderr — `seed.sh`'s `server=$(sh seed.sh)` was capturing BOTH the log line and the path, corrupting `$server`; fixed by redirecting the patcher's own invocation to `/tmp/patch.log` inside `seed.sh`. (2) `grep -c PATTERN file` exits 1 when the count is 0 (even though it prints "0") — under `set -e` inside the container script, asserting a count of 0 (the v1-marker-must-be-absent checks in E1/E7) killed the script before later checks ran; fixed with `$(grep -c … || true)`. (3) `docker compose run`'s own progress lines ("Container … Creating/Created") land in bats' `$output` BEFORE the script's own stdout, so positional `sed -n '1p'/'2p'` extraction silently read the wrong line; fixed by labeling each count (`V2COUNT=`/`V1COUNT=`) and matching with `grep -qx`. Remaining DEPLOY-ONLY leg of T029: the live fleet gate on linus/donna (blocked today by a Cloudflare Access re-auth only the operator can complete) and rodri-cenco-admin's own 0.19.0→0.24.0 upgrade.
