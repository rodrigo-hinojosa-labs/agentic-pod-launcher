# Contract — reply acknowledgement with voice outcome (US1, US2, US3)

Consumer: the agent (Claude Code session) via the `plugin:telegram:telegram` `reply` tool
result. Producer: the patched plugin `server.ts`, `case 'reply'`, voice group **v2**.

## C1. Acknowledgement grammar

```text
<ack> := <sent-line> [ "\n" <voice-line> ]
<sent-line> := "sent (id: " <int> ")" | "sent " <int> " parts (ids: " <int> { ", " <int> } ")"
<voice-line> := "voice: sent (fmt=" <fmt> ", chars=" <int> ", ms=" <int> ")" [ <nag> ]
              | "voice: failed (step=" <step> ", cls=" <cls> ", status=" <digits-or-empty> ")"
<nag>  := "; voice_text omitted — " <int> " chars of text were read aloud"
<fmt>  := "ogg" | "mp3"
<step> := "synth" | "send"
<cls>  := "timeout" | "transport"
```

- The `<voice-line>` is present **iff** the outbound voice step ran (voice active, mode
  not `never`, and mode `always` OR fresh voice origin OR `voice_force === true`, and —
  in mode `always` only — no failure cooldown pending for the chat, C7).
- When absent, `<ack>` is byte-identical to the v0.23.0 acknowledgement (FR-002). Test
  oracle: the return expression is `result + _voiceOutcome` and `_voiceOutcome` is
  initialised to `''` before the voice `if`.
- `<nag>` is present iff the spoken text came from `text` (no non-blank `voice_text`)
  AND `chars > VOICE_OMISSION_NAG_CHARS` (= `floor(cap / 4)`, 300 by default).

## C2. Field whitelist (FR-003)

Allowed inside `<voice-line>`: `fmt`, `chars`, `ms`, `step`, `cls`, `status` — each from
the closed sets above or a non-negative integer. Forbidden anywhere in the acknowledgement:
the spoken text, `err`/`err.message`, any URL, the bot token, `chat_id`, `voice_id`,
message ids other than those already in `<sent-line>`.

Test oracle (host bats, on the extracted reply block) — **positive form is primary**:
every `_voiceOutcome` assignment matches one of the templates above verbatim (`grep -F`
on the exact JS template strings). Secondary negatives, written as
`run grep -q PATTERN snippet; [ "$status" -ne 0 ]` (never a bare intermediate `! grep`):
no `${err`, `${url`, `${spoken}` (note: `${spoken.length}` is allowed), `${text`,
`${VOICE_ID`, `file/bot` inside the block.

## C3. Stderr correlation (SC-001)

For the same turn the stderr capture carries:

```text
telegram channel: voice tts ok chat=<id> chars=<n> fmt=<fmt> ms=<n>
telegram channel: voice tts spoke <n> chars without voice_text chat=<id>      # only when from text
telegram channel: voice tts fail: <cls> status=<digits|empty> step=<step> chat=<id>
telegram channel: voice skip: cooldown after failure chat=<id>                # mode always only, C7
```

`chars`, `fmt`, `ms`, `cls`, `status`, `step` are the same values as in the acknowledgement.
The `fail` line keeps the 032 prefix `voice tts fail: ${cls} status=${status}` unchanged
and inserts `step=` before `chat=` (one field order everywhere).

## C4. Fail-silent (FR-008) and the two legs

- Every operand of the two templates is a primitive already computed (`fmt`, numbers,
  `_voiceStep`, `cls`, `status`); template assembly cannot throw. The 032
  try/catch/finally shape is preserved; no code path between the voice block and the
  `return` can raise.
- `_voiceErrClass` v2 reads `error_code` null-safely with exactly this line (**CANON-E**,
  pasted identically in tasks T009(f)/T011): `if (typeof err === 'object' && err !== null
  && typeof (err as { error_code?: unknown }).error_code === 'number') return { cls:
  'transport', status: String((err as { error_code: number }).error_code) }`; otherwise
  the 032 rules (`AbortError` → timeout; `-status-NNN` suffix → transport/NNN; else
  transport/empty).
- `bot.api.sendVoice(chat_id, new InputFile(buf, …), undefined, _voiceController.signal)`
  — the same 30 s budget bounds both legs, so `step=send, cls=timeout` is reachable.
  **Verified (T008, research D3)**: grammY's `sendVoice(chat_id, voice, other?,
  signal?)` accepts the trailing `AbortSignal` (confirmed against the published
  package's typings, offline, since production access needed operator re-auth).
- A throw inside `process.stderr.write` (closed pipe) has the same exposure as in 032 and
  is out of scope.

## C5. Contract wording (instructions array, single line — v2)

```text
Voice replies: when a message arrives transcribed (meta attachment_kind="voice") or the
user explicitly asks for an audio reply, this channel AUTOMATICALLY sends your reply as a
voice note too — never tell the user you cannot send audio, and answer in ONE reply call
(only the first reply of the exchange is spoken). Always include voice_text with a concise
speakable version of your answer (plain prose, no markdown, no lists); if you omit it, your
full text is read aloud up to the cap. The reply result carries a "voice:" line for your own
awareness (sent/failed) — do not repeat it to the user; if it says failed, tell the user
once, briefly, that the audio did not go out this time, and do not retry. If the user asks
for audio in wording the channel did not recognise, set voice_force: true on that reply.
```

(One JS string literal; line breaks above are for reading. Preserved 032 substrings:
`attachment_kind="voice"`, `include voice_text with a concise speakable version`.)

`voice_text` description (v2):

```text
Spoken-style rendition of this reply, synthesized as the voice bubble whenever the exchange
is voice-originated (voice note or explicit audio request) or voice_force is set. Plain
speakable prose — no markdown, no code, no lists. Strongly recommended: when omitted, `text`
itself is read aloud up to the spoken cap and the reply result reports the omission.
```

`voice_force` property (new):

```text
voice_force: { type: 'boolean', description: 'Force this reply to also be sent as a voice
bubble even though the user typed. Set ONLY when the user asked for an audio reply in
wording the channel did not recognise. Never set it by default.' }
```

Read as `args.voice_force === true` — `"true"`, `1` or any non-boolean is ignored with no
feedback (FR-013).

## C6. Behavioural rules the agent is held to (tested live, SC-002)

1. Never claims it cannot send audio in a voice-originated exchange.
2. Provides `voice_text` on voice-originated replies (omission rate ≤ 1/10, SC-003).
3. On `voice: failed`, mentions it once, briefly; never re-sends the reply to retry.
4. Never relays the `voice:` line verbatim.
5. Sets `voice_force` only for unrecognised audio-request wording; never by default.
6. Answers a voice-expected exchange in one reply call.

## C7. Failure cooldown (mode `always` only — research D13)

- On a `failed` outcome, if `VOICE_REPLY_MODE === 'always'`:
  `_voiceCooldown.set(chat_id, Date.now())`.
- At the top of the synthesis branch (after `_voiceOriginConsume`, before
  `_voiceSynthesize`): `if (VOICE_REPLY_MODE === 'always' && _voiceCooldownConsume(chat_id))`
  → write `telegram channel: voice skip: cooldown after failure chat=<id>` to stderr and
  skip synthesis. No outcome line (the step did not run; FR-002 holds).
- `_voiceCooldownConsume` is delete-on-read with the same 5-minute freshness as the voice
  origin. In mode `auto` nothing is set or read.
- Effect: the agent's one-sentence failure mention goes out text-only and cannot produce a
  second failure; the loop the spec names cannot form. The next user message tries voice
  again.
