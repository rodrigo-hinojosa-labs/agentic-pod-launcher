# Contract: inbound voice → transcript (patch hunks V1 + V5 helpers + V6)

Scope: behaviour of the replaced `bot.on('message:voice')` handler inside the patched
plugin, plus the V6 origin-clear wrap of `message:text`. Upstream `handleInbound` is NOT
modified (research D1). *Remediated 2026-09-06 after the adversarial design review:
DM-only pre-check, detached pipeline, absent-metadata caps, redaction, C-id renumber.*

## C1 — Activation gate (cheap checks first, paid calls last)

Order of checks, each falling through to **C5 (placeholder path)** when not satisfied:

1. `TELEGRAM_VOICE_ENABLED === 'true'` and `ELEVENLABS_API_KEY` non-empty.
2. **DM-only read-only pre-check** (research D2): positive ⟺
   `ctx.chat.type === 'private'` AND `access.dmPolicy !== 'disabled'` AND the sender is
   in `access.allowFrom` (via `loadAccess()`). `gate()` is NEVER called here — it stays
   the single authority inside `handleInbound`. Group chats are NEVER transcribed in v1
   (declared non-goal, C5b); uncertain ⇒ no paid call.
3. Caps (absent-metadata-safe, review fix): `voice.duration`, when present and > 0,
   must be ≤ `TELEGRAM_VOICE_MAX_NOTE_SECONDS` (default 300) — absent/0 duration
   PASSES; `voice.file_size`, when present, must be ≤ 20 MB — absent file_size PASSES
   the pre-download check, and the REAL size cap is enforced post-download on the
   buffer length BEFORE the paid STT POST (the download is free; the transcription is
   what costs). Over-cap notes take the placeholder path with a distinguishable stderr
   reason (`over-cap`) and the placeholder text appends `(voice note over the
   transcription limit)` so the agent can tell the operator why it cannot hear it.

## C2 — Detached download + STT pipeline (research D9)

- The handler NEVER awaits the network pipeline: after C1 passes it fires ONE
  fire-and-forget `bot.api.sendChatAction(chat_id, 'typing').catch(() => {})` (sender
  feedback during transcription — the upstream typing/ack only start inside
  `handleInbound`, i.e. after STT) and schedules the rest detached
  (`void (async () => { … })()`), returning immediately. The channel's sequential
  update loop is never blocked by a transcription (FR-002).
- Detached pipeline: `ctx.api.getFile(file_id)` + fetch of the file URL (in-memory
  buffer, never written to disk) → post-download size check (C1.3) → STT:
  `POST {API_BASE}/v1/speech-to-text`, multipart `file` (the OGG/Opus bytes as-is, no
  transcoding), `model_id=VOICE_STT_MODEL`, `language_code=TELEGRAM_VOICE_STT_LANG`
  ONLY when the var is non-empty (empty ⇒ omitted ⇒ provider autodetect); header
  `xi-api-key`.
- One hard timeout covers download+STT combined: **30 s** (AbortController) — the
  never-hang bound. SC-002's 10 s bound applies to ≤60 s notes under normal conditions
  and is validated at the e2e/quickstart gate; the 30 s bound is what the code enforces.
- No retries in v1 (a failed note degrades; the operator can resend).
- **Ordering trade-off (accepted, spec edge case)**: because the pipeline is detached, a
  transcribed note may be announced to the agent after a later-arriving text from the
  same chat.

## C3 — Success path

- `text := transcript` (trimmed). Empty/whitespace transcript ⇒ treated as failure (C5).
- Call `handleInbound(ctx, transcript, undefined, {kind:'voice', file_id, size, mime})`
  — identical attachment meta to today, so `attachment_file_id` keeps flowing and
  `attachment_kind: 'voice'` remains the agent's voice-origin signal (research D3).
- Record `VoiceOrigin[chat_id] = {ts: now}` (consumed by the outbound contract per its
  C7 — consume-on-read; TTL 5 min; cleared by V6 on a later typed message).
- Stderr: `telegram channel: voice stt ok chat=<id> dur=<s>s chars=<n> ms=<elapsed>`.

## C4 — Failure classes (all fail-open)

| Class | Trigger | Behaviour |
|---|---|---|
| inactive | disabled / no key | C5 + ONE module-scope boot-time config line (V5 emits it before any token/network use; never per-message spam) |
| unauthorized | DM-only pre-check not positive (incl. all groups) | C5 silently (gate() in handleInbound decides drop/pair — no double messaging) |
| over-cap | duration/size above caps (pre- or post-download) | C5 + `voice stt skip: over-cap` line + placeholder annotated |
| transport | getFile/fetch/STT non-2xx/timeout | C5 + `voice stt fail: <class> status=<code>` line |
| empty | blank transcript | C5 + `voice stt fail: empty` line |

**Redaction (hardened, review fix)**: stderr lines interpolate ONLY a derived error
class + numeric HTTP status. Never the ElevenLabs key, never raw error objects, and
never the getFile URL — it embeds the **Telegram bot token**
(`api.telegram.org/file/bot<TOKEN>/…`); the adjacent upstream photo handler's
`${err}`-interpolation pattern MUST NOT be imitated.

## C5 — Placeholder path (the fail-open floor)

Byte-equivalent to the unpatched handler: `handleInbound(ctx, caption ?? '(voice
message)', undefined, {kind:'voice', file_id, size, mime})` (over-cap adds the
annotation from C1.3). `VoiceOrigin` is NOT set (a reply to an untranscribed note is
text-only — the agent couldn't hear it, speaking back would be incoherent).

## C5b — Non-goals and accepted edges of the inbound hunk

- **Groups: transcription is DM-only in v1.** Group voice notes always take C5. The
  side-effect-free pre-check cannot mirror the group authorization branch (group
  allowlists + mention rules depending on the resolved bot username) — revisit only if
  group voice is ever requested.
- `message:audio`, documents, video notes: untouched (music/files are not voice
  instructions).
- No transcript echo into the chat (clarified 2026-09-06).
- No persistence of audio or transcripts beyond the notification to the agent.
- **Permission-reply intercept collision (accepted edge)**: `handleInbound` runs the
  permission-reply regex on its text argument; a transcript matching the exact English
  pattern `y|yes|n|no + 5-letter token` would be consumed by the intercept instead of
  announced. Implausible from Spanish dictation (punctuation and language break the
  match); when a voice-origin flag exists and the turn ends at the intercept, one
  stderr line records it.

## C5c — V6: origin clear on typed text

The `message:text` handler is wrapped: `VoiceOrigin.delete(chat_id)` first, then the
upstream body runs unchanged. A typed message means the operator switched back to text;
a later reply must not carry an unsolicited voice bubble (research D5).

## Test hooks (host bats, textual assertions on patched output)

- DM-only pre-check — including the `dmPolicy !== 'disabled'` guard — appears BEFORE
  any `fetch(`/`getFile` call in the hunk (mutation target: dropping the dmPolicy guard
  must break a test).
- Detached shape: the handler body schedules with `void (async` and does NOT `await`
  the STT helper at handler level (mutation target).
- `sendChatAction` typing line present at pipeline start.
- Timeout/AbortController present; `catch` wraps the paid section and lands on the
  placeholder call; the placeholder call remains textually present (fail-open floor).
- Caps: the comparison expressions + the `over-cap` literal + the post-download buffer
  check are present; a test covers the absent-`file_size` case classification.
- Redaction (strengthened per analyze C1): the voice hunk's stderr template literals
  interpolate ONLY the whitelisted fields (chat id, duration, chars, ms, error class,
  numeric status) — no `${err}`, no URL-bearing variable, no `file/bot` substring in
  any interpolation (mutation target).
- No-echo (analyze E4): the V1 hunk contains NO `sendMessage`/`ctx.reply(` call — the
  transcript can only reach the agent notification, never the chat.
- One-time WARN placement (analyze E5): the config/WARN emission sits at MODULE scope
  in the V5 helpers block (outside any handler function), making per-message emission
  structurally impossible.
- V6: the `message:text` wrap with `VoiceOrigin.delete` present; placeholder path does
  NOT set VoiceOrigin (mutation target: setting it there must break a test).
- Marker `MARKER_VOICE` (full prefixed string) present exactly once; double-apply
  idempotent; anchor-drifted fixture leaves the file untouched except a WARN (group
  rollback).
