# Data Model — 033 voice reply feedback + explicit audio requests

No persisted state is added. Every entity below is in-process (the plugin's module scope)
or a string that travels through the reply tool result. Nothing under `.state/` changes.

## 1. Voice outcome (per reply, transient)

Produced only when the outbound voice step ran; otherwise absent (the acknowledgement is
byte-identical to v0.23.0).

| Field | Type | Values | Source |
| --- | --- | --- | --- |
| `status` | enum | `sent` \| `failed` | try/catch branch |
| `fmt` | enum | `ogg` \| `mp3` | `_voiceSynthesize` return (sniff cache) |
| `chars` | integer | `spoken.length` | spoken string (rendition or truncated fallback) |
| `ms` | integer | `Date.now() - _voiceStarted` | measured |
| `from_text` | boolean | true when no non-blank `voice_text` was supplied | `_voiceFromText` |
| `step` | enum | `synth` \| `send` | `_voiceStep`, flipped after synthesis resolves |
| `cls` | enum | `timeout` \| `transport` | `_voiceErrClass` |
| `status` | string | digits or empty | `_voiceErrClass` (`-status-NNN` suffix or grammY `error_code`) |

Rendering (contract `reply-voice-outcome.md`):

- `sent` → `\nvoice: sent (fmt=…, chars=…, ms=…)`; when `from_text && chars > NAG` →
  `; voice_text omitted — <chars> chars of text were read aloud` appended.
- `failed` → `\nvoice: failed (step=…, cls=…, status=…)`.

Invariants: only whitelisted fields are rendered; the spoken text, error message, URL,
`chat_id` and message ids never appear in the line (they may appear in stderr as today —
`chat_id` does; secrets never).

## 2. Omission record (stderr, per omitted rendition)

`telegram channel: voice tts spoke <chars> chars without voice_text chat=<chat_id>` —
written on every successful synthesis whose spoken text came from `text` (regardless of
threshold). Measurable basis for SC-003:

```text
omission_rate = count("without voice_text") / count("voice tts ok")
```

## 3. Nag threshold (module-scope constant)

`VOICE_OMISSION_NAG_CHARS = Math.floor(VOICE_SPOKEN_CHAR_CAP / 4)` → 300 with the default
cap (1200). Derived, not configurable (FR-007). Only gates the nag clause in the outcome
line, never the stderr record.

## 4. Voice origin (existing, semantics extended)

`_voiceOrigin: Map<chat_id, timestamp>` (032). Setters now:

| Setter | Where | Condition |
| --- | --- | --- |
| inbound voice note (032) | `message:voice` handler after a successful transcript | unchanged |
| explicit request (033) | `message:text` wrap, after `_voiceOriginClear` | `VOICE_ACTIVE && VOICE_REPLY_MODE !== 'never' && isDm && _voiceRequestMatch(text)` — `isDm` is the 032 three-part gate (`private` + `dmPolicy !== 'disabled'` + sender in `allowFrom`) |

Consumer unchanged: `_voiceOriginConsume(chat_id)` in the reply case — delete-on-read,
fresh iff `now - ts < 5 min`. One-reply scope for both sources (spec Q5); the FIRST
`reply` call of a turn consumes it (documented limit, contract explicit-audio-request.md
C3). Lost on process restart (in-memory) → fail-open to text.

## 4b. Failure cooldown (mode `always` only, research D13)

`_voiceCooldown: Map<chat_id, timestamp>`. Set on a `failed` outcome when
`VOICE_REPLY_MODE === 'always'`; consumed (delete-on-read, 5-min freshness) at the top of
the synthesis branch in mode `always`, skipping synthesis once and logging
`voice skip: cooldown after failure`. Never set or read in mode `auto`. Breaks the
"failure → mention → failure" loop deterministically.

## 5. Explicit request phrase set (module-scope constant)

`VOICE_REQUEST_PHRASES: readonly string[]` — normalised (NFD, marks stripped, typographic
apostrophes mapped to `'`, lowercase) imperative forms in Spanish (23) and English (15)
(table in `research.md` D5 and `contracts/explicit-audio-request.md`). Match = whole-word
substring of the normalised message, every occurrence scanned, with a same-clause negation
guard (≤30 chars back). Not configurable; documented in README.

## 6. Force-voice flag (reply tool input)

`voice_force?: boolean` on the `reply` tool's inputSchema. Read as
`args.voice_force === true` (strict — any non-boolean is ignored silently). Effect: adds a third trigger to the synthesis
condition in mode `auto`. No effect in mode `never` or when voice is inactive. Independent
of `voice_text` (which never triggers voice by itself).

## 7. Voice patch group version (marker)

| Constant | Value | Role |
| --- | --- | --- |
| `MARKER_VOICE_V1` | `agentic-pod-launcher: telegram voice roundtrip patch v1` | detected by the upgrader; gates `apply_voice` too |
| `MARKER_VOICE` | `agentic-pod-launcher: telegram voice roundtrip patch v2` | current; embedded in `VOICE_HELPERS` line 1 |

State transitions of a plugin `server.ts` at boot (`main()` order: typing cascade → typing
→ offset → pending → stderr → primary → askq → **voice upgrade v1→v2** → voice fresh):

```text
pristine ──apply_voice──────────────► v2
v1 ───────upgrade_voice_v1_to_v2────► v2        (all five hunks matched)
v1 (edited out-of-band) ─────────────► v1 (WARN; apply_voice refuses: v1 marker present)
v2 ──────────────────────────────────► v2        (both functions no-op; file byte-identical)
v2 ──(v0.23.0 patcher, rollback)─────► v2        (its apply_voice fails hunk 2, WARN, file left intact)
```

Ground truth for the `v1` row in tests: the committed golden fixture
`tests/fixtures/telegram-server-voice-v1.ts` (generated once by the real v0.23.0 patcher),
not the `_V1` constants themselves (research D8).

## 8. Reply acknowledgement (tool result text)

`result` (unchanged `const`) `+ _voiceOutcome` (`''` when the voice step did not run).
Consumers: the agent (model context), the session transcript. No other reader.
