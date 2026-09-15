# Contract — explicit audio request (US4)

Producer: the operator typing in a direct chat. Consumer: the patched plugin's
`message:text` wrap (voice group v2), which marks the exchange voice-originated exactly as
a voice note would.

## C1. Recognition

```text
normalize(s) := NFD(s) → strip U+0300..U+036F → map U+2018, U+2019, U+02BC, U+00B4, ` to "'"
                → lowercase → collapse whitespace → trim
match(text) :=
  t = normalize(text)
  ∃ p ∈ PHRASES, ∃ occurrence i of p in t (ALL occurrences are scanned, not only the first):
      char before i (if any) ∉ [a-z0-9]        # whole-word start
    ∧ char after i+len(p) (if any) ∉ [a-z0-9]   # whole-word end
    ∧ ¬ NEGATION.test(t[0:i])                   # same clause, ≤30 chars back, no negation token
NEGATION := /(?:^|[\s,;:—-])(?:no|nunca|jamas|sin|don't|dont|do not|never|stop)\b[^.!?\n]{0,30}$/
```

`PHRASES` (fixed, module-scope, normalised forms — imperative request forms only):

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

Positive examples (must match): `RESPONDE CON AUDIO`, `Respóndeme con audio por favor`,
`hola, ¿me respondes? responde en audio`, `reply with audio please`, `Mándame un audio con
el resumen`, `contéstame por audio`, `send me a voice note with the summary`.

Negative examples (must NOT match): `el audio de ayer se cortó`, `no respondas con audio`,
`no me mandes audio`, `no responde con audio` (negated statement), `responde con texto`,
`audio`, `prefiero texto, sin audio`, `don’t reply with audio` (U+2019), `please don't
ever reply with audio`, `respondecon audio` (no word boundary).

Both tables live in the host test (structure/content) and in e2e E5 (behaviour under bun).

## C2. Effect

In the `message:text` wrap, after the existing (verbatim) `_voiceOriginClear`:

```text
const access = loadAccess()
const isDm = ctx.chat?.type === 'private' && access.dmPolicy !== 'disabled'
          && ctx.from != null && access.allowFrom.includes(String(ctx.from.id))   # the 032 three-part gate
if (VOICE_ACTIVE && VOICE_REPLY_MODE !== 'never' && isDm && _voiceRequestMatch(ctx.message.text)) {
  _voiceOriginSet(String(ctx.chat!.id))        # same setter, scope and TTL as a voice note; no local `chat_id`
  stderr: "telegram channel: voice request detected chat=<id>"
}
```

- One reply only: the origin is consumed by the FIRST `reply` call after it; a following
  plain typed message clears it (032 behaviour).
- Mode `never` / voice inactive: the mark is never set (gated), acknowledgement
  byte-identical (FR-012, FR-002).
- Scope: exactly the 032 inbound gate — private chat, DM policy not disabled, sender in
  the allow list, with the same `ctx.from != null` guard (four conjuncts; "three-part"
  elsewhere refers to the three policy checks) — a chat 032 would refuse to transcribe is
  never marked by a typed request either. Group chats: not recognised.
- Restart between request and reply: mark lost → text-only, fail-open.

## C3. Strictness (FR-012) and its one known limit

When the mark is fresh (or mode is `always`, or `voice_force` is set) the plugin
synthesises and sends the bubble irrespective of the agent's reply content. The agent has
no opt-out. The only non-voice outcomes are a reported failure (`voice: failed …`, which
the agent then mentions once) and, in mode `always` only, the one-shot cooldown after a
failure (contract reply-voice-outcome.md C7).

**Known limit (review R3, documented, not hidden)**: consume-on-read means the FIRST
`reply` of a turn carries the voice. An agent that answers in two `reply` calls ("un
momento…" then the answer) speaks the first. The channel contract steers "answer in ONE
reply when voice is expected"; SC-007 is measured on the first reply of each exchange.
The plugin cannot detect turn end, so this is not mechanised.

## C4. Documentation surface

The phrase table is user-facing and MUST appear in the README's "Round-trip voice" bullet
(or a sub-table directly below it) — it is the operator's contract for what words trigger
audio. Not configurable in v2 of the group.
