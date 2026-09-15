# Contract — voice patch group v1 → v2 (FR-005)

Producer/consumer: `docker/scripts/apply_telegram_typing_patch.py`, run at every boot by
`start_services.sh::apply_plugin_patches` against
`~/.claude/plugins/cache/claude-plugins-official/telegram/*/server.ts`.

## C1. Constants

| Constant | v1 (kept verbatim as `_V1`) | v2 |
| --- | --- | --- |
| `MARKER_VOICE_V1` / `MARKER_VOICE` | `…telegram voice roundtrip patch v1` | `…telegram voice roundtrip patch v2` |
| `VOICE_HELPERS` | 032 block | + null-safe `error_code` read in `_voiceErrClass`; + `VOICE_OMISSION_NAG_CHARS`; + `VOICE_REQUEST_PHRASES`, `_voiceNormalize`, `_voiceRequestMatch`; + `_voiceCooldown` map + `_voiceCooldownConsume`; marker line bumped; ends with the sentinel line `// agentic-pod-launcher: voice helpers end (033)` |
| `VOICE_HANDLER` | 032 | **unchanged** (not part of the upgrade) |
| `VOICE_TEXT_WRAP` | clear → handleInbound | clear → gated request check/set → handleInbound; `_voiceOriginClear(String(ctx.chat!.id))` kept verbatim |
| `VOICE_REPLY_BLOCK` + return | block; pristine return kept | `let _voiceOutcome = ''`; cooldown check (mode `always`); `_voiceForce`; `_voiceFromText`; `_voiceStep`; signal on `sendVoice`; outcome assignments; return `result + _voiceOutcome` |
| `VOICE_SCHEMA_PROPERTY` | `voice_text` | `voice_text` (new description) + `voice_force` |
| `VOICE_INSTRUCTIONS_LINE` | 032 line | v2 line (contract C5 of reply-voice-outcome.md) |

`_REPLY_RETURN_V1 = "        return { content: [{ type: 'text', text: result }] }\n"`,
`_REPLY_RETURN_V2 = "        return { content: [{ type: 'text', text: result + _voiceOutcome }] }\n"`.

**Invariants the v2 constants MUST keep** (existing 032 oracles rely on them):

- the text wrap contains the exact substring `_voiceOriginClear(String(ctx.chat!.id))`
  (`apply-telegram-patches.bats:908`, `docker-e2e-voice.bats:70`);
- the text wrap calls `_voiceOriginSet(String(ctx.chat!.id))` inline and binds NO local
  named `chat_id`, so `_voiceOriginSet(chat_id)` still occurs exactly once in the file
  (`:902`);
- the instructions line contains `attachment_kind="voice"` and
  `include voice_text with a concise speakable version` (`:968-969`).

## C2. `upgrade_voice_v1_to_v2(src) -> (src, applied)`

```text
if MARKER_VOICE in src:        return src, False          # already v2 or beyond
if MARKER_VOICE_V1 not in src: return src, False          # nothing to upgrade
for n, (old, new) in enumerate(PAIRS, 1):                 # helpers, wrap, reply+return, schema, instructions
    if work.count(old) != 1:
        warn(f"voice v1→v2 upgrade: hunk {n} anchor not found (edited out-of-band?) — leaving v1 in place")
        return src, False                                 # all-or-nothing
    work = work.replace(old, new, 1)
return work, True
```

## C3. `apply_voice(src)` (fresh install) changes

- Gate: `if MARKER_VOICE in src or MARKER_VOICE_V1 in src: return src, False`.
- Hunk 4: the return-line regex now **replaces** the matched line with
  `VOICE_REPLY_BLOCK + _REPLY_RETURN_V2` (v1 prepended the block and kept the line).
- Hunks 1, 2, 3, 5, 6: same anchors as v1; v2 constants.
- All six substitutions remain `lambda m: …` replacements (032 rule).

## C4. `main()` wiring

`upgrade_voice_v1_to_v2` runs immediately before `apply_voice` (after `apply_askq_giveup`);
its flag joins the `if not (… or v)` early-return and appends `voice-upgrade-v1→v2` to the
parts list. Order relative to every other group is unchanged.

## C5. Fixtures and guarantees (tested)

**Fixtures (committed, `tests/fixtures/`)**:

- `telegram-server-pristine.ts` — the former inline heredoc of
  `apply-telegram-patches.bats`, extracted byte-for-byte; `setup()` now `cp`s it.
- `telegram-server-voice-v1.ts` — **golden**: `python3 <(git show
  a7eb2e5:docker/scripts/apply_telegram_typing_patch.py) telegram-server-pristine.ts`,
  generated once on the dev host and committed (CI is shallow; the file is the ground
  truth for what v0.23.0 wrote).

**Assertion forms** (review PM-2 — bats does not fail on an intermediate `! cmd`): every
negative check is written `run grep -q PATTERN FILE; [ "$status" -ne 0 ]` or
`[ "$(grep -c PATTERN FILE)" -eq 0 ]`, never a bare `! grep` unless it is the last line.
The dead 032 negatives at `:804, :876-878, :886, :984, :995` are repaired in the same
edit; `:878` (`file/bot`) is narrowed to `process.stderr.write` lines because the inbound
handler legitimately builds that URL.

| # | Scenario | Expected | Oracle |
| --- | --- | --- | --- |
| G1 | pristine fixture | v2 marker ×1; `voice_force`; `result + _voiceOutcome`; instructions v2; sentinel `voice helpers end (033)` | grep / count |
| G2 | golden v1 fixture | v2 marker ×1, v1 ×0, **sha256 == patcher(pristine)** | shasum (independent of the `_V1` twins) |
| G2b | `_V1` fidelity | each of the five `_V1` constants and `MARKER_VOICE_V1` is a substring of the golden file | `python3 -B - "$PATCHER" "$GOLDEN" <<'PY'` |
| G2c | reverse-replace round trip (secondary) | upgrade(reverse(fresh v2)) == fresh v2 | shasum |
| G3 | second run on v2 (both fixtures) | byte-identical AND v2 marker ×1 in both | shasum + count |
| G4 | golden v1 with the instructions line edited out-of-band | exit 0, stdout contains `voice v1→v2 upgrade: hunk 5 anchor not found` (US2 scenario 4 WARN), v1 marker kept, v2 count 0, `voice_text: {` ×1, other six groups present | run + grep + count |
| G5 | anchor drift on the pristine `message:voice` handler | voice group skipped (v2 marker count 0 — flipped from the dead v1 negative at `:804`, no RED expected on flip), six other groups applied | count |
| G6 | typing cascade v4→v6 on the golden v1 file | typing reaches v6 AND voice reaches v2 in one pass | grep |
| G7 | `DOCKER_E2E` E7: seed golden v1 into the plugin cache path inside the container, run `/opt/agent-admin/scripts/apply_telegram_typing_patch.py` | v2 ×1, v1 ×0 | count |
| G8 | step USE | line order: `await _voiceSynthesize` < `_voiceStep = 'send'` < `bot.api.sendVoice`; the catch's stderr line contains `step=${_voiceStep}`; `sendVoice(` call passes `_voiceController.signal` | line numbers + grep |
| G9 | threshold USE | `Math.floor(VOICE_SPOKEN_CHAR_CAP / 4)` defines the constant; `spoken.length > VOICE_OMISSION_NAG_CHARS` appears in the reply block; no `> 300` literal | grep / count |
| G10 | cooldown structure | `_voiceCooldown.set(chat_id` inside the catch gated by `VOICE_REPLY_MODE === 'always'`; `_voiceCooldownConsume(chat_id)` line precedes `await _voiceSynthesize` | line numbers |
| G11 | backslash literals | patched TS contains the fixed strings `[\u0300` and `\s+` | `grep -F` |

## C6. Python-literal rule (research D10)

Every backslash destined for the TS output is doubled in the Python literal; oracle G11.
