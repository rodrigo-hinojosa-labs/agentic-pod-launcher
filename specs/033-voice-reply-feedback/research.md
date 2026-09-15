# Phase 0 Research — 033 voice reply feedback + explicit audio requests

All findings below were verified by reading the launcher code on branch
`033-voice-reply-feedback` (main = `a7eb2e5`, v0.23.0) and the live patched plugin on
`linus` (plugin `telegram/0.0.6`, ferrari) on 2026-09-13. Nothing here is inferred from
documentation alone. Items marked **NOT VERIFIED** are measured by a task, not assumed.

**Adversarial review (2026-09-13, workflow `wf_e99b3212-83d`, 4 reviewers × 1 dimension,
refute-verify):** 32 findings (3 HIGH, 12 MEDIUM, 17 LOW after dedup). The session
token limit killed 20 of 32 refuters; the 12 that ran refuted nothing. The two HIGH
clusters were re-verified by hand against the code (both stand) and every HIGH/MEDIUM
plus the actionable LOWs were remediated in this file, the contracts, the spec, the plan
and the quickstart — see §Review remediation at the end. Nothing was left as "known".

## Measured baseline (what exists today)

| Fact | Where | Consequence for the design |
| --- | --- | --- |
| The reply acknowledgement is `const result = sentIds.length === 1 ? \`sent (id: …)\` : \`sent N parts (ids: …)\`` and the case ends with `return { content: [{ type: 'text', text: result }] }` | live `server.ts:874-901`; fixture `tests/apply-telegram-patches.bats:29+` | `result` is `const`; the outcome must be a separate `let` concatenated at the return. When empty, `result + ''` is byte-identical (FR-002) |
| 032 hunk V2 (`VOICE_REPLY_BLOCK`) is inserted immediately BEFORE that return line by `re.subn` on the return-line regex (`patcher:1294-1302`), and the return line itself is left untouched | `apply_voice()` | A v1-patched file still contains the pristine return line, so a v2 fresh-apply would double-insert unless `apply_voice` also gates on the v1 marker |
| `apply_voice` short-circuits only on `MARKER_VOICE in src` (`patcher:1254`) — there is no upgrade path for the voice group; the typing group has five (`upgrade_typing_v1_to_v2 … v5_to_v6`, `:695-919`), each gated `MARKER_<next> in src → no-op`, `MARKER_<this> not in src → no-op`, exact `.replace(old, new)` with `new == src → warn + leave in place` | patcher | The v1→v2 upgrader follows the typing shape exactly; the marker line lives INSIDE `VOICE_HELPERS` (`"\n// " + MARKER_VOICE + "\n"`, `:445`), so replacing the helpers block bumps the marker |
| Synthesis and Telegram delivery share ONE `try/catch` (`_voiceSynthesize` then `bot.api.sendVoice`, `:654-663`); `sendVoice` receives NO AbortSignal, so the 30 s budget bounds only the synth leg; `_voiceErrClass` recognises only `AbortError` and the `-status-NNN` suffix of the plugin's own fetch errors (`:486-492`) — a grammY `GrammyError` (has `error_code: number`) falls to `{cls:'transport', status:''}` | `VOICE_HELPERS`, `VOICE_REPLY_BLOCK` | A `step` variable flipped between the two awaits discriminates synth vs send with no second try/catch; `_voiceErrClass` gains a null-safe numeric `error_code` read; `sendVoice` gets the same signal so `step=send, cls=timeout` is reachable and the budget bounds both legs |
| `_voiceOrigin` is a module-scope `Map<string, number>`; `_voiceOriginSet/Consume/Clear` exist (`:471-484`); hunk V6 wraps `message:text` to `_voiceOriginClear(String(ctx.chat!.id))` then `handleInbound` (`:629-635`); `_voiceOriginConsume` is delete-on-read, so the FIRST `reply` call of a turn consumes it | patcher | The explicit request reuses `_voiceOriginSet` verbatim (one-reply scope, consume-on-read, 5-min TTL — spec Q5) from inside the V6 wrap, after the clear. **Consequence named (review R3):** an agent that sends two `reply` calls in one turn gets voice on the first only — 032 behaviour, now documented in the contract and steered by the instructions ("answer in ONE reply when voice is expected"); SC-007 is measured on the first reply of each exchange |
| The 032 inbound DM gate is three-part: `ctx.chat?.type === 'private' && access.dmPolicy !== 'disabled' && access.allowFrom.includes(String(from.id))` via read-only `loadAccess()` (`:562-568`) | `VOICE_HANDLER` | The explicit-request gate reuses the SAME three-part check (review F7/R5) — exact parity, not just `'private'` |
| The spoken-length cap is `VOICE_SPOKEN_CHAR_CAP` (env `TELEGRAM_VOICE_SPOKEN_CHAR_CAP`, default 1200, `:457-459`) | helpers | The nag threshold derives from it: `Math.floor(VOICE_SPOKEN_CHAR_CAP / 4)` = 300 by default (spec Q2) |
| The patcher is importable: `if __name__ == "__main__":` guard at `:1402`; bats defines `PATCHER="$REPO_ROOT/docker/scripts/apply_telegram_typing_patch.py"` (`apply-telegram-patches.bats:12`); `REPO_ROOT` is set in `tests/helper.bash:4` | patcher, tests | Tests may `import` the constants (with `python3 -B` and the path passed as `argv`, never via `$VAR` inside a quoted heredoc — review F6/PM-5) |
| CI checks out with `actions/checkout@v6` at default (shallow) depth (`.github/workflows/test.yml:43`) | CI | `git show a7eb2e5:…` is unavailable in CI → the v1 ground truth must be a **committed fixture** generated once on the dev host (D8) |
| **The docker image does NOT contain the Telegram plugin** (`grep claude-plugins-official docker/Dockerfile` → nothing); it is installed post-login by `start_services.sh` (`claude plugin install`, `:325`). `docker-e2e-voice.bats` (and `docker-e2e-askq-guard.bats`) run `docker compose run --entrypoint sh`, which bypasses `entrypoint.sh`/`start_services.sh`, then `find … -name server.ts` | Dockerfile, e2e files, `start_services.sh:273-325` | **Review F2 (HIGH, verified):** the inherited E1/E3/E4 could never pass — `test -n "$server"` fails before any assertion. Every 033 e2e case is **self-seeding**: it copies a committed fixture into the plugin cache path inside the container, then runs the image-baked patcher with the image's `python3` and checks with the image's `bun` (D11) |
| bats intermediate `! cmd` lines do not fail a test (bash `set -e` semantics; measured by a refuter on bats 1.13.0 under bash 3.2.57 and 5.3.15; memory note `bats-intermediate-double-bracket-quirk`). Dead negatives today: `apply-telegram-patches.bats:804, 876-878, 886, 984, 995` | tests | **Review PM-2 (MEDIUM, confirmed):** every negative oracle in 033 uses `run grep -q …; [ "$status" -ne 0 ]` or a `grep -c … -eq 0` count; the dead 032 negatives are repaired in the same file edit — and repairing `:878` exposes that its assertion was WRONG, not just dead: the inbound handler legitimately builds the `file/bot${TOKEN}` URL (`:593`); the intent is "never in a stderr line", so the repaired oracle greps only `process.stderr.write` lines |
| Existing oracles that pin v1 literals or the pristine return line — **corrected enumeration (review F3)**: `apply-telegram-patches.bats:781, :795, :921` (marker v1 count → v2, go RED first), `:934` (pristine return line → `result + _voiceOutcome`, goes RED), `:804` (negative marker grep → flipped to a v2 count, NO RED expected — it passes trivially either way); `docker-e2e-voice.bats:64`+`:74`, `:113`+`:117` (grep and its consumer). **Preserved by construction** (must NOT change): `:902` (`_voiceOriginSet(chat_id)` count == 1 — the v2 wrap calls `_voiceOriginSet(String(ctx.chat!.id))` inline and must not bind a local named `chat_id`), `:908` and e2e `:70` (`_voiceOriginClear(String(ctx.chat!.id))` verbatim), `:968-969` (instructions substrings) | tests | Four host oracles go RED at T004 (`:781 :795 :921 :934`); `:804` is flipped without RED; the two e2e greps (`:64`, `:113`) are rewritten by T021 and cannot RED on the host; four invariants the v2 constants keep |
| The fleet: donna, linus at v1 (plugin 0.0.6); rodri-cenco-admin at launcher 0.19.0 (no voice group yet) | live | The in-place upgrade is the production path for two agents; rodri-cenco-admin lands v2 fresh |
| The 032 plan's Technical Context says "upstream telegram plugin 0.0.7"; the installed plugin on the fleet is `0.0.6` and the fixture is labelled "real 0.0.6 shape" | live + fixture | Doc drift, no design impact (anchors unchanged); noted so the 033 plan does not repeat it |
| What the **v0.23.0 patcher does to a v2 file** (rollback): `apply_voice` gate `MARKER_VOICE(v1) in src` is false → hunk1 inserts v1 helpers after `let botUsername` → hunk2's anchor is the UPSTREAM `message:voice` body (`:1266-1275`), which v1/v2 replaced → `n2 != 1` → WARN and `return src, False` — the group is **skipped and the v2 file is left intact** (working copy discarded) | `apply_voice()` | **Review PM-3/F5/F7 (verified):** rolling the image back does NOT double-apply; it leaves v2 in place and functional. A true downgrade requires deleting the plugin cache dir so the plugin reinstalls pristine and v0.23.0 patches it v1 (quickstart §4 corrected) |

## Decisions

### D1 — Feedback channel: append to the reply acknowledgement string

**Decision**: declare `let _voiceOutcome = ''` immediately before the voice `if`, assign it
inside the try (success) and catch (failure), and change the case's return to
`text: result + _voiceOutcome`. Nothing else in the acknowledgement changes.

**Rationale**: `result` is `const`; concatenation at the return is the smallest change,
and `''` concatenation is byte-identical when the voice step did not run — FR-002
falls out of the construction rather than a branch. The agent reads tool results as
text; a trailing line is the most reliable place for it to land in the model's context.

**Alternatives considered**: a second `content` item (changes the result shape for every
reply, harder to prove byte-identity); MCP `_meta` on the result (not reliably surfaced to
the model); a separate stderr-only signal (that is the status quo — it never reaches the
agent).

### D2 — Outcome line grammar (contract `contracts/reply-voice-outcome.md`)

```text
\nvoice: sent (fmt=<ogg|mp3>, chars=<n>, ms=<n>)
\nvoice: sent (fmt=<ogg|mp3>, chars=<n>, ms=<n>); voice_text omitted — <n> chars of text were read aloud
\nvoice: failed (step=<synth|send>, cls=<timeout|transport>, status=<digits|empty>)
```

Whitelist: `fmt` (from the sniff cache, two literals), `chars`/`ms` (numbers), `step` (two
literals), `cls` (two literals from `_voiceErrClass`), `status` (digits or empty). The
spoken text, `err`, URLs and ids never enter the line. The leading `\n` separates it from
`sent (id: N)`.

### D3 — Step discrimination without a second try/catch; the send leg gets the budget

**Decision**: `let _voiceStep: 'synth' | 'send' = 'synth'` before the `try`; set
`_voiceStep = 'send'` right after `_voiceSynthesize` resolves and before
`bot.api.sendVoice`. `sendVoice` receives the same `_voiceController.signal` as its
trailing `signal` argument (grammY `Api` methods take `(…, other?, signal?)`).

**Verified 2026-09-14 (T008)**: the ferrari SSH tunnel needed a Cloudflare Access
re-auth only the operator can complete, so the check was done independently and
without touching production — `npm pack grammy` (published v1.46.0) downloaded and
inspected offline: `out/core/api.d.ts:295`
`` sendVoice(chat_id: number | string, voice: InputFile | string, other?: Other<R, "sendVoice", "chat_id" | "voice">, signal?: AbortSignal): Promise<...> ``
— the trailing `signal?: AbortSignal` parameter is present and stable (bun does not
type-check TS, it only strips types, so even a slightly older pinned grammY
accepting-but-ignoring a 4th arg is harmless at runtime). CONFIRMED: the 4-argument
call is used. The catch reports
`step=${_voiceStep}` on both the stderr line and the outcome line; on stderr it is
inserted **before** `chat=`, so the line reads
`voice tts fail: ${cls} status=${status} step=${_voiceStep} chat=${chat_id}` — the 032
prefix `voice tts fail: ${cls} status=${status}` stays intact for existing greps (review
F8: one field order everywhere). `_voiceErrClass` v2 additionally returns
`{cls:'transport', status:String(code)}` when `typeof err === 'object' && err !== null
&& typeof (err as {error_code?: unknown}).error_code === 'number'` (null-safe, review R4).

**Alternatives**: two nested try/catch blocks (more code, same information, and the
`finally` for the timer would have to be duplicated or hoisted).

### D4 — Omission observability and nag threshold

**Decision**: `const _voiceFromText = !(voiceTextArg && voiceTextArg.trim())`. On success,
when `_voiceFromText`: always write
`telegram channel: voice tts spoke ${spoken.length} chars without voice_text chat=${chat_id}`
to stderr (the measurable record, FR-006), and when `spoken.length > VOICE_OMISSION_NAG_CHARS`
append the nag clause to the outcome line. `VOICE_OMISSION_NAG_CHARS =
Math.floor(VOICE_SPOKEN_CHAR_CAP / 4)` is a module-scope constant — no env variable, no
`agent.yml` field (FR-007, spec Q2). With the default cap it is 300 characters; an operator
who raises the cap raises the threshold with it.

**Oracles must assert USE, not presence (review F5)**: the nag condition line
`spoken.length > VOICE_OMISSION_NAG_CHARS` exists inside the reply block, the constant is
defined as `Math.floor(VOICE_SPOKEN_CHAR_CAP / 4)`, and no literal `> 300` appears; the
step oracle asserts the line order synthesize < `_voiceStep = 'send'` < sendVoice AND that
the catch line contains `step=${_voiceStep}`.

**Alternatives**: `TELEGRAM_VOICE_OMISSION_NAG_CHARS` knob (rejected in clarify: one more
compose/render surface for a knob nobody would turn); nag on every omission (rejected:
trains the agent to write `voice_text` for a 20-character answer where reading `text` is
correct).

### D5 — Explicit audio request: fixed phrase table + negation guard, matched in the V6 wrap

**Decision**: helpers gain `VOICE_REQUEST_PHRASES` (fixed, module-scope), `_voiceNormalize`
(NFD → strip combining marks U+0300–U+036F → map typographic apostrophes U+2018/U+2019/
U+02BC/U+00B4/backtick to `'` (review F4/F2-spec: iOS/Android emit `don’t`) → lowercase →
collapse whitespace) and `_voiceRequestMatch(text)`: for each phrase, scan **every**
occurrence (loop on `indexOf` from the previous index, review R6); an occurrence counts
when both neighbours are non-alphanumeric (whole word) and the same-clause prefix does
not end in a negation — `NEGATION = /(?:^|[\s,;:—-])(?:no|nunca|jamas|sin|don't|dont|do
not|never|stop)\b[^.!?\n]{0,30}$/` applied to `t.slice(0, i)` (a negation token within
the same clause, at most 30 characters before the phrase, covers "please don't ever reply
with audio" and "no, mejor no respondas con audio"). The V6 wrap v2 keeps
`_voiceOriginClear(String(ctx.chat!.id))` verbatim and then, when
`VOICE_ACTIVE && VOICE_REPLY_MODE !== 'never' && isDm && _voiceRequestMatch(ctx.message.text)`
— `isDm` being the 032 three-part check via `loadAccess()` (review F7/R5/F6-spec: the
contract's "mode never: never set" and "DM-only mirrors 032" become literally true) —
calls `_voiceOriginSet(String(ctx.chat!.id))` and logs
`telegram channel: voice request detected chat=<id>`. The wrap binds no local named
`chat_id` (review R9: the 032 oracle `:902` counts `_voiceOriginSet(chat_id)` exactly
once). `handleInbound` is untouched (FR-011).

Phrase table (imperative request forms; normalised — accents irrelevant at match time;
Chilean forms added per review F3-spec):

| Spanish | English |
| --- | --- |
| responde con audio | reply with audio |
| respondeme con audio | respond with audio |
| responde en audio | answer with audio |
| respondeme en audio | reply with voice |
| responde por audio | respond with voice |
| respondeme por audio | answer with voice |
| contesta con audio | reply in audio |
| contestame con audio | respond in audio |
| contesta en audio | answer in audio |
| contestame en audio | send me an audio |
| contesta por audio | send me a voice note |
| contestame por audio | send me a voice message |
| responde con voz | send a voice note |
| respondeme con voz | reply with a voice note |
| contesta con voz | reply with a voice message |
| responde con una nota de voz | |
| mandame un audio | |
| mandame audio | |
| mandame una nota de voz | |
| enviame un audio | |
| enviame una nota de voz | |
| responde hablando | |
| respondeme hablando | |

Negatives that MUST NOT match (test table, host structural + e2e behavioural): "el audio
de ayer se cortó", "no respondas con audio", "no me mandes audio", "no responde con
audio" (negated statement), "responde con texto", "audio", "prefiero texto, sin audio",
"don’t reply with audio" (U+2019), "please don't ever reply with audio", "respondecon
audio" (no boundary).

**Rationale**: deterministic, documented, testable; matches the operator's word
"estrictamente" (spec Q6). Parity with the 032 gate means a chat 032 would refuse to
transcribe is never marked by a typed request either.

**Alternatives**: free regex on `audio|voz` (false positives on any sentence mentioning
audio); agent-only recognition (rejected in clarify — the non-determinism this feature
removes).

### D6 — Force flag: `voice_force` boolean on the reply tool

**Decision**: inputSchema property `voice_force: { type: 'boolean', description: … }`
right after `voice_text`; in the reply block `const _voiceForce = args.voice_force === true`
(strict — `"true"`, `1` or any non-boolean is ignored with no feedback, documented in
FR-013, review R8) and the condition becomes
`VOICE_REPLY_MODE === 'always' || _voiceFresh || _voiceForce`. `_voiceOriginConsume` is
still called first (consume-on-read preserved). Mode `never` and `!VOICE_ACTIVE` short-
circuit before the flag is read (FR-013). The presence of `voice_text` alone still never
triggers voice (spec Q6).

**Naming**: `voice_force` sits beside `voice_text`; a bare `voice` was rejected as a likely
future upstream collision.

### D7 — Upgrade mechanism v1 → v2: exact-constant replacement, all-or-nothing

**Decision**: keep the v1 constants as `VOICE_HELPERS_V1`, `VOICE_TEXT_WRAP_V1`,
`VOICE_REPLY_BLOCK_V1`, `VOICE_SCHEMA_PROPERTY_V1`, `VOICE_INSTRUCTIONS_LINE_V1` (verbatim
copies of today's strings — their fidelity is pinned by a golden fixture, D8) plus
`MARKER_VOICE_V1`; bump `MARKER_VOICE` to
`"agentic-pod-launcher: telegram voice roundtrip patch v2"`. New
`upgrade_voice_v1_to_v2(src)`:

1. `MARKER_VOICE in src` → `(src, False)`; `MARKER_VOICE_V1 not in src` → `(src, False)`.
2. Five ordered pairs `(old, new)`: helpers; text wrap; `VOICE_REPLY_BLOCK_V1 + RETURN_V1`
   → `VOICE_REPLY_BLOCK + RETURN_V2` (the return line is part of the reply pair because v2
   rewrites it); schema property; instructions line. For each: `work.count(old) != 1` →
   `warn("voice v1→v2 upgrade: hunk N anchor not found (edited out-of-band?) — leaving v1 in place")`
   and return `(src, False)` — nothing partially applied; else `.replace(old, new, 1)`.
3. Return `(work, True)`.

`apply_voice` (fresh) gates on `MARKER_VOICE in src or MARKER_VOICE_V1 in src` so a v1
file whose upgrade was refused is left at v1 (FR-005 scenario 4) and never double-patched;
its hunk4 now replaces the matched return line with `VOICE_REPLY_BLOCK + RETURN_V2`
instead of prepending. `VOICE_HANDLER` (inbound STT) is byte-identical between v1 and v2
— not part of the upgrade. `VOICE_HELPERS` v2 ends with the sentinel comment
`// agentic-pod-launcher: voice helpers end (033)` so e2e E5 can extract the helpers
block by two fixed lines. `main()` calls `upgrade_voice_v1_to_v2` immediately before
`apply_voice`, adds its flag to the "anything applied" check and `voice-upgrade-v1→v2`
to the parts list.

**Rationale**: the changed regions are large and exactly known (they are the patcher's own
constants), so verbatim `.replace` is both the simplest and the strictest anchor — the
`TYPING_HELPERS_V4 = TYPING_HELPERS.replace(...)` technique generalised. Group-scoped:
no other group's marker or anchor is touched; all-or-nothing preserves Principle IV.

**Alternatives**: strip-and-reapply (needs reverse anchors for six hunks including
restoring the upstream `message:voice` body — fragile); regex partial rewrites (the diff
spans five regions; regexes over them would be write-only).

### D8 — Ground truth for the upgrade: two committed fixtures, one golden

**Problem found in review (F1/PM-1, HIGH, verified)**: the first draft's oracle
"reverse-replace the v2 constants with `_V1`, upgrade, compare sha with fresh v2" is a
tautology — both directions consume the same `_V1` Python strings, so a `_V1` twin that
differs by one byte from what v0.23.0 actually wrote on the fleet still passes, and on the
fleet the upgrade would fail silently (WARN, stays v1, keeps lying). The typing precedent
avoided this by synthesising v1 text independent of the patcher
(`apply-telegram-patches.bats:470-474`).

**Decision**:

1. `tests/fixtures/telegram-server-pristine.ts` — the inline heredoc of
   `apply-telegram-patches.bats` extracted byte-for-byte to a file; `setup()` copies it
   instead of embedding it (one source for host tests AND e2e seeding).
2. `tests/fixtures/telegram-server-voice-v1.ts` — **golden**: generated ONCE on the dev
   host by running the real v0.23.0 patcher (`git show a7eb2e5:docker/scripts/
   apply_telegram_typing_patch.py`) over fixture 1, committed. CI never needs git history.
   Generated 2026-09-14 (T002); sha256
   `61cc28e337b9d23b703cb58686d5ebb3cdd2239d1c14b7e1bbb45869465dfb6c`; all seven v0.23.0
   markers present (typing v6 ×1, offset ×4, pending-marker ×3, stderr ×1, primary ×2,
   askq-giveup ×1, voice v1 ×1); the CURRENT (still-v1) patcher is confirmed a no-op on it.
3. Oracles (contract C5): **G2** `sha256(patcher(golden_v1)) == sha256(patcher(pristine))`
   — real convergence, independent of the `_V1` twins (a wrong twin makes the upgrade
   refuse → v1 marker survives → sha differs → RED); **G2b** fidelity: each `_V1`
   constant is a substring of the golden file (`python3 -B - "$PATCHER" "$GOLDEN"
   <<'PY' … assert p.VOICE_HELPERS_V1 in golden …`); **G2c** (secondary) the
   reverse-replace round trip. Mutation 7 in quickstart: alter one byte of
   `VOICE_HELPERS_V1` → G2 and G2b RED.
4. Import hygiene (F6/PM-5): `python3 -B` (no `__pycache__` in the build context / git
   tree), paths passed as `argv` into a quoted heredoc (`$REPO_ROOT` is invisible inside
   `<<'PY'`), `sys.path.insert(0, dirname(argv[1]))`.

### D9 — Contract wording (instructions line, `voice_text` and `voice_force` descriptions)

Single instructions line (the anchor `instructions: [\n` + one line is preserved, and the
032 oracle `grep -A 2 "instructions: \[" | grep 'attachment_kind="voice"'` keeps
matching). The v2 line keeps the 032 substring `include voice_text with a concise
speakable version` so that oracle stays valid too. Full text in
`contracts/reply-voice-outcome.md` §C5. It states, in order: automatic voice on
voice-originated exchanges AND explicit requests; never claim inability; answer in ONE
reply when voice is expected (review R3); always include `voice_text`, omission
consequence; the `voice:` line is for the agent, not to relay; on `failed`, one brief
honest mention, no retry; `voice_force` only for unrecognised wording.

### D10 — Backslashes in the Python literals (032 bug class, pre-empted)

The v2 helpers contain JS regexes with escape classes. In the Python source every
backslash destined for the TypeScript output MUST be doubled so the TS receives a
literal backslash; and every `re.subn` replacement stays a `lambda` (032's fix). Written
out — the Python literal must contain the two-character sequence backslash-backslash
before each of: `u0300`, `u036f` (the combining-mark range), `u2018`, `u2019`, `u02bc`,
`s` (whitespace class), `d`, `b`, and the `n` inside JS template-literal stderr writes.
Oracle (host): the emitted TS contains, as fixed strings (`grep -F`), the seven-character
sequence `[\u0300` and the four-character sequence `\s+` — a single-backslash literal in
the Python source would have turned the first into a real combining mark and the second
into a bare `s`. (Review R1/PM-4/F9 caught that the first draft of this very section had
already swallowed its own escapes — the doc now spells the sequences out instead of
showing them.)

### D11 — Verification tiers and what each proves

| Tier | Proves | Cannot prove |
| --- | --- | --- |
| Host bats (hermetic, `python3` only) | hunk structure, exact wording, whitelist (positive template greps primary, live negatives secondary), threshold derivation and USE, step order and USE, upgrade convergence on the golden, `_V1` fidelity, idempotency, fail-silent, phrase-table content, backslash literals | that the TS parses or that the matcher behaves |
| `DOCKER_E2E=1` (bun + python3 in the image), **self-seeding** — each test copies `tests/fixtures/telegram-server-pristine.ts` (or the golden v1) from the bind-mounted workspace into `$HOME/.claude/plugins/cache/claude-plugins-official/telegram/0.0.6/server.ts`, then runs `/opt/agent-admin/scripts/apply_telegram_typing_patch.py` — the image-baked patcher and the image toolchain are the objects under test, not the marketplace install | (E1-E4, rewritten) markers/hunks on the seeded file; (E5) the matcher's behaviour under bun on the positive/negative tables, extracted between the v2 marker line and the `voice helpers end (033)` sentinel; (E6) the whole patched `server.ts` parses (**NOT VERIFIED which bun API is the parse-only check — candidate `new Bun.Transpiler({loader:'ts'}).transformSync(src)`; the e2e task measures it**); (E7) the in-container upgrade of the golden v1 → v2 ×1; (E8) `_voiceErrClass({error_code: 400})` → `transport/400` under bun | a real reply through MCP (no bot runs in the harness) |
| Live (linus/donna) | SC-001/002/003/007/008/009 and the synth leg of SC-006 (bad `voice_id` → `failed (step=synth, cls=transport, status=404)`) | the send leg of SC-006 (Telegram rejecting a bubble is not reproducible on demand) — covered by structure (step flip position) + E8 |

### D12 — Version, docs, and the parse-failure blast radius

- VERSION 0.23.0 → **0.24.0** (MINOR; 028/031 precedent for a marker bump with behaviour
  change). CHANGELOG under `[Unreleased]`: Added (explicit request, `voice_force`,
  outcome line, failure cooldown) + Changed (voice group v2, instructions; e2e harness
  now self-seeding; dead 032 negatives repaired). README Telegram section: the 7th hook
  bullet gains the v2 behaviours and the phrase table (user-facing contract). CLAUDE.md's
  Telegram patch section gains the v2 note.
- **Risk named**: a TypeScript syntax error in any v2 hunk makes `bun server.ts` exit at
  boot → the watchdog respawns → crash budget → container exit/restart loop. Mitigation
  ordered: (1) e2e E6 parse check on the seeded, patched file; (2) the deploy quickstart
  boots ONE agent (linus) first and watches for `channel plugin healthy` before touching
  donna.

### D13 — Failure cooldown in mode `always` (review R2/F4-spec: the loop needed a mechanism, not a promise)

**Problem**: spec edge case "Failure mention in mode `always` during a provider outage"
required "the end-to-end fault-injection run MUST confirm no follow-up loop forms" — no
tier in D11 can run a conversation, so the requirement had no oracle, and the contract
wording alone cannot bound a loop that each new failure re-arms.

**Decision**: a one-shot, per-chat, in-memory cooldown that only exists in mode `always`:
`_voiceCooldown: Map<string, number>`; on a `failed` outcome with
`VOICE_REPLY_MODE === 'always'`, `_voiceCooldown.set(chat_id, Date.now())`; at the top of
the synthesis branch, `if (VOICE_REPLY_MODE === 'always' && _voiceCooldownConsume(chat_id))`
(delete-on-read, 5-min TTL like the origin) → skip synthesis, log
`telegram channel: voice skip: cooldown after failure chat=<id>`, no outcome line (the
step did not run — FR-002 holds). Effect: failed reply → the agent's one-sentence mention
goes out text-only without producing another failure → the agent stops. The next user
message tries voice again (transient outages self-heal; persistent ones cost one attempt
per user turn, never per agent message). Mode `auto` needs nothing: the mention is not
voice-originated and cannot re-arm. Host oracle: structure (set on failure gated on
`always`; consume before synthesize); e2e: none needed beyond structure; live: observable
in the fault-injection step of quickstart §3.6 as a single `voice skip: cooldown` line.

**Alternatives**: contract-only ("mention once, never retry") — unverifiable and re-armed
by every new failure; a global "voice off after N failures" — changes mode semantics the
spec fixed.

## Review remediation (2026-09-13, `wf_e99b3212-83d`)

| Finding (dim) | Sev | Verdict | Remediated where |
| --- | --- | --- | --- |
| F1/PM-1/F1-spec — sha oracle tautological | HIGH | verified by hand | D8 (golden fixture + fidelity test), contract C5 G2/G2b, quickstart mutation 7, plan |
| F2 — e2e cannot find a `server.ts` under `--entrypoint sh` | HIGH | verified by hand (Dockerfile has no plugin; `start_services.sh:325` installs it) | D11 self-seeding, contract C5 G7, quickstart §2, plan (fixtures) |
| PM-2 — intermediate `! grep -q` dead; :878 also wrong | MEDIUM | confirmed by refuter (lowered to MEDIUM) | baseline row, contract C2/C5 assertion forms, plan task list |
| PM-3/F5-spec/F7 — rollback note wrong (v0.23.0 skips, does not double-apply) | MEDIUM | verified by hand | baseline row, quickstart §4 |
| F3 — oracle enumeration errors (:70 not v1; :74/:117 consumers; :804 no RED; :902 invariant) | MEDIUM | accepted | baseline row, contract C1 invariant, plan handoff |
| F4/F2-spec — curly apostrophe defeats the negation guard | MEDIUM | accepted | D5 normalisation, contract C1, negatives table |
| F5 — mutations 2/3 matched by presence-only greps | MEDIUM | accepted | D4 (USE oracles), contract C5, quickstart §1 |
| F3-spec — Chilean phrase forms missing | MEDIUM | accepted | D5 table (+9 ES, +4 EN) |
| F4-spec/R2 — `always` loop had no oracle | MEDIUM | accepted | D13 cooldown, spec edge case + FR, contracts, data-model |
| R3 — strictness vs consume-on-first-reply | MEDIUM | accepted (documented + steered) | baseline row, D9, contract C3, spec edge case, SC-007 wording |
| R1/PM-4/F9 — D10 self-corrupted | MEDIUM/LOW | accepted | D10 rewritten with spelled-out sequences + wider oracle |
| F6/PM-5 — heredoc `$REPO_ROOT`, `__pycache__` | LOW | accepted | D8 item 4 |
| R4 — `error_code` null-safety | LOW | accepted | D3 |
| R5/F6-spec — mode `never` gate on the wrap | LOW | accepted | D5 gate |
| R6 — negation window / multiple occurrences | LOW | accepted | D5 |
| R7 — send leg unbounded, `send/timeout` unreachable | LOW | accepted (verify grammY signal param) | D3 |
| R8 — non-boolean `voice_force` | LOW | accepted (documented) | D6, spec FR-013 |
| R9 — `_voiceOriginSet(chat_id)` count oracle | LOW | accepted | D5, contract C1 |
| F7-spec — "DM-only mirrors 032" inexact | LOW | accepted | D5 gate parity |
| F8-spec — stderr field order | LOW | accepted | D3 |
| F10-spec — FR-009 "unchanged" vs oracle churn | LOW | accepted | spec FR-009 wording |
| F11-spec — busybox grep `\|`, transcript path | LOW | accepted | quickstart §3.2 (`grep -E`) |
| F7 (tests) — rollback | LOW | same as PM-3 | quickstart §4 |
