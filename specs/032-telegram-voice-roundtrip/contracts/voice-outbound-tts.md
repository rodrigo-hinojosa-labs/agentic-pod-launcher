# Contract: reply → voice bubble (patch hunks V2 + V3 + V4)

Scope: the voice extension of the plugin's `reply` tool (`case 'reply'`), the tool's
inputSchema, and the channel instructions. Text delivery semantics are upstream and
unchanged.

## C6 — Ordering invariant: text first, marker/ack next, voice best-effort last

*(Remediated 2026-09-06: the 028 marker-clear and the offset-ack hunks anchor
immediately before the reply case's `const result =` — i.e. AFTER the files loop. The
voice block therefore anchors AFTER that site, immediately before the case's
`return { content:` — never between chunks and files.)*

Consequences (load-bearing, mutation-tested):

- The full reply text AND the file attachments are ALWAYS delivered, and the 028
  `pending-reply.json` clear + offset ack happen with timing byte-identical to today,
  BEFORE any synthesis is attempted (FR-004/FR-005). A crash during synthesis can no
  longer strand the marker or un-acked offset (which would have caused Telegram
  redelivery + a duplicate turn — the exact window the review caught in the
  chunks-then-voice draft).
- A synthesis/send failure costs nothing but the bubble: log one stderr line, return
  the tool's normal success result (the tool call MUST NOT throw for a voice-only
  failure — mutation target).
- The voice bubble's `message_id` is NOT counted in the tool's result string (the
  result was already computed upstream of the voice block; the bubble is a best-effort
  extra).

## C7 — When does a reply speak?

```
active   = TELEGRAM_VOICE_ENABLED=true AND key present
speaks   = active AND mode != 'never' AND
           (mode == 'always' OR (mode == 'auto' AND VoiceOrigin[chat_id] fresh))
```

- `VoiceOrigin[chat_id]` is **consumed (deleted) the moment it is read — BEFORE
  synthesis**; a TTS/send failure does NOT restore it (one paid attempt per voice
  exchange; the failed exchange stays text-only). Fresh = age < TTL (5 min). A typed
  message from the chat clears it earlier (inbound contract C5c/V6).
- `mode` values outside {auto,always,never} were already sanitized to `auto` at render;
  the hunk still defaults unknowns to `auto` (defense in depth).
- Multi-reply turns — **known v1 limitation (documented, accepted)**: `case 'reply'`
  has no turn awareness; in `auto` mode the FIRST reply to the chat after transcription
  consumes the flag and speaks — if the agent sends an interim acknowledgement first,
  the ack is what gets voiced. The V4 instructions steer the agent to reply to voice
  with the substantive answer (and its `voice_text`) in the first reply; revisit with a
  voice_text-aware consumption rule only if practice shows the ack pattern is common.
  In `always` mode every reply speaks.

## C8 — What is spoken

`spoken := args.voice_text` if it is a non-empty string, else `truncate(args.text,
TELEGRAM_VOICE_SPOKEN_CHAR_CAP)` (default 1200; truncation cuts at the last word
boundary before the cap and appends an ellipsis). The full `text` was already sent —
speaking is always a rendition, never the only delivery.

## C9 — Synthesis + send

- TTS: `POST {API_BASE}/v1/text-to-speech/{voice_id}?output_format=<fmt>` with
  `model_id=VOICE_TTS_MODEL`, body `{text: spoken}`, header `xi-api-key`; `voice_id`
  from `TELEGRAM_VOICE_ID`, else the patcher's stock default constant.
- Format strategy (research D4): first attempt `opus_48000_64`; sniff bytes 0-3 for
  `OggS` → send `InputFile(buffer, 'voice.ogg')`; otherwise re-request
  `mp3_44100_128` → send `InputFile(buffer, 'voice.mp3')`. Outcome cached per process
  (`ogg-ok | mp3-fallback`) so the double-request happens at most once per boot.
- Send: `bot.api.sendVoice(chat_id, input, { ...reply_parameters like the files loop })`;
  its `message_id` is logged but NOT added to the already-computed tool result (C6).
- ONE hard 30 s budget covers the WHOLE synthesis step — both format attempts
  (opus + the one-time mp3 re-request) share the same deadline, never 2×30 s
  (remediated 2026-09-06); timeout/error ⇒ C6's failure behaviour.
- Stderr on success: `telegram channel: voice tts ok chat=<id> chars=<n> fmt=<ogg|mp3>
  ms=<elapsed>`; on failure: `voice tts fail: <class> status=<code>` (no bodies/key).

## C10 — Agent-facing surface (V3 + V4)

- **V3 — reply tool inputSchema** gains optional `voice_text` (string): "spoken-style
  rendition used for the voice bubble when the exchange is voice-originated; plain
  speakable prose, no markdown/code; omitted ⇒ a truncated version of `text` is spoken".
- **V4 — instructions array** gains one line: messages whose meta carries
  `attachment_kind="voice"` arrive transcribed (the message text IS the transcription);
  when replying to them, include `voice_text` with a concise speakable version of the
  answer.
- Backward/limbo safety: an agent that ignores `voice_text` (older CLAUDE.md, other
  models) still produces a voice bubble via the truncation floor; an agent that sends
  `voice_text` while the feature is inactive loses nothing (the field is ignored by the
  unpatched/inactive path — it is additive and optional).

## Test hooks

- Textual assertion: the voice block appears AFTER the marker-clear/ack site (i.e.
  after the fixture's `const result =` region) and before the case's return; mutation
  targets: moving it between chunks and files, or letting a voice error throw, must
  each break ≥1 test (the throw mutation also guards the marker/ack staying upstream).
- The reply-mode gate expression (active/mode/VoiceOrigin conditional) and the
  consume-on-read (`delete` before the synthesis call) are textually present (mutation:
  moving the delete to the success branch must break a test).
- The truncation helper (word-boundary cut + ellipsis + `TELEGRAM_VOICE_SPOKEN_CHAR_CAP`
  env read) is present.
- `voice_text` present in the patched tool schema; instructions line present.
- `OggS` sniff + `mp3_44100_128` fallback + the single shared deadline are present in
  the hunk.
- `sendVoice` appears ONLY inside the voice group (patched file), never in the unpatched
  baseline fixture.
- Stderr prefixes `telegram channel: voice tts ok` / `voice tts fail` greppable; no raw
  `${err}` interpolation in the voice stderr lines.
