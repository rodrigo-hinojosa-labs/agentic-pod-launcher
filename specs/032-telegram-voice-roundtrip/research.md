# Phase 0 Research: 032-telegram-voice-roundtrip

**Date**: 2026-09-06. Primary evidence: the 7-researcher documentation sweep run this
session (workflow `wf_b1eb3359-319`, 157 tool calls over official docs — Telegram Bot
API 10.3, ElevenLabs API reference, Anthropic docs, prior art) plus direct reads of the
cached upstream plugin (`telegram/0.0.7/server.ts`) and the launcher's patcher/test
suite. Facts below are labeled by confidence where it matters.

## D1 — Inbound anchor and hunk shape

**Decision**: The voice group replaces the body of the upstream `bot.on('message:voice')`
handler (server.ts:837-847 in 0.0.7). `handleInbound` is NOT modified.

**Rationale**: The handler is small, self-contained, and already receives everything the
pipeline needs (`ctx`, `voice.file_id`, `voice.file_size`, `voice.mime_type`,
`voice.duration`). Replacing its body keeps the hunk's anchor surface minimal (one
`bot.on('message:voice'` block) and leaves the far larger, frequently-anchored
`handleInbound` untouched — the same "smallest stable anchor" principle the six existing
groups follow. On any internal failure the hunk calls `handleInbound` with byte-identical
arguments to today's handler (placeholder `'(voice message)'` or caption + attachment
meta), which IS the fail-open contract (FR-002).

**Alternatives considered**: (a) extending `handleInbound` with a lazy-transcript
callback (like the photo handler's post-gate `downloadImage` seam) — rejected: the seam
returns an `image_path` for meta, not message text; rerouting it would modify
`handleInbound`'s announce block, a much bigger anchor with three sibling groups nearby.
(b) A generic pre-`handleInbound` middleware — rejected: grammY middleware ordering with
the other handlers adds unpredictable interactions; no precedent in the existing groups.

## D2 — Paid-call authorization: allowlist pre-check without `gate()`

**Decision** *(tightened by the 2026-09-06 adversarial review)*: Before downloading or
transcribing, the hunk performs a READ-ONLY authorization check pinned to the ONE case
where it is exactly equivalent to `gate()` without side effects:
`positive ⟺ ctx.chat.type === 'private' AND access.dmPolicy !== 'disabled' AND
access.allowFrom includes the sender`. It never calls `gate()` itself. Anything else —
groups included — skips transcription and falls through to today's placeholder path
(where `handleInbound`'s own `gate()` remains the single authority). **Transcription is
therefore DM-only in v1, by design.**

**Rationale**: FR-009 requires authorization before any paid API call, but `gate()`'s
pairing branch has side effects (pairing-code issuance, resend tracking) — running it
twice per message would double-trigger that machinery. The naive membership-only test
both over-approximates (a DM with `dmPolicy: 'disabled'` would pay for STT and then be
dropped) and under-approximates the gate (group authorization runs on
`groups[id].allowFrom` + mention rules that depend on `botUsername` being resolved —
not reproducible read-only). Restricting the positive case to the private-chat triple
makes "no credits spent on messages the gate won't deliver" exact; group voice notes
degrade to the placeholder, which the spec now declares as a v1 non-goal.

**Alternatives considered**: (a) calling `gate()` early — rejected (side effects,
double-invocation unsafe); (b) mirroring the full group branch read-only — rejected for
v1 (fragile duplication of mention/botUsername logic; revisit only if group voice is
ever asked for).

## D3 — Voice-origin signal to the agent: reuse existing meta, zero new fields

**Decision**: No new notification meta. The agent's voice-origin signal is the existing
`attachment_kind: 'voice'` meta (already delivered today) combined with content that is
the transcript instead of the `'(voice message)'` placeholder. The instructions-array
hunk documents the convention to the agent: "a message with attachment_kind=voice
carries its transcription as the message text; reply with voice_text populated".

**Rationale**: The meta block is built inside `handleInbound` (server.ts:970-991) from a
fixed `AttachmentMeta` shape — adding fields means patching `handleInbound` (see D1
rationale against). The `attachment_kind` field already distinguishes voice perfectly,
and the placeholder-vs-transcript distinction is unambiguous (the placeholder is a fixed
literal). The attachment reference (`attachment_file_id`) keeps flowing, so FR-001's
"raw audio remains downloadable" holds with zero work.

## D4 — TTS output format: runtime container sniff, MP3 fallback, no ffmpeg

**Decision**: Request `opus_48000_64` from the TTS endpoint. Inspect the first bytes of
the response: if they are the Ogg magic `OggS`, send as `voice.ogg` (canonical Telegram
voice format). Otherwise re-request as `mp3_44100_128` and send as `voice.mp3` — Bot API
10.3 accepts ".OGG encoded with OPUS, or in .MP3 format, or in .M4A format" for
`sendVoice` (verified-official-doc, 2026-09-06 sweep). Cache the sniff outcome
in-process so the fallback re-request happens at most once per boot. No ffmpeg is added
to the image.

**Rationale**: The one hard empirical unknown from the analysis (does ElevenLabs'
`opus_48000_*` come in an Ogg container? — undocumented; OpenClaw sends it straight to
`sendVoice`, suggesting yes, but that is verified-secondary) becomes a 4-line runtime
branch instead of a design blocker. Either answer yields a working voice bubble without
transcoding, so the Dockerfile stays untouched — which keeps this feature's image-baked
surface confined to the patcher and keeps DOCKER_E2E scope small.

**Alternatives considered**: (a) MP3-only — simplest, but ~4x heavier audio and
non-canonical (waveform/UX parity on all clients is undocumented for MP3); keep as the
fallback, not the primary. (b) `apk add ffmpeg` + transcode — rejected: a new image
package + boot dependency to solve a problem two documented no-transcode routes already
solve. Revisit only if BOTH routes fail on real clients (quickstart validation step).

## D5 — Voice-origin persistence: in-memory map, deliberately not a file

**Decision** *(semantics pinned by the 2026-09-06 adversarial review)*: The reply-side
"was this chat's last inbound voice?" flag lives in an in-process
`Map<chat_id, {ts}>` written on successful transcription. **Consume-on-read**: the reply
hunk deletes the entry the moment it reads it, BEFORE synthesis is attempted — a TTS
failure does NOT restore it (that exchange stays text-only; no repeated paid retries).
To keep the declared semantics honest ("LAST inbound was voice"), a sixth micro-hunk
(V6) clears the chat's entry in the `message:text` handler — a typed message switches
the exchange back to text, so a later reply cannot voice-ify it. TTL 5 minutes as
defense-in-depth for the inbound kinds V6 does not cover (photo/document). It is NOT
persisted to disk.

**Rationale**: The only loss scenario is a plugin restart between a voice inbound and
the agent's reply — the cost is one text-only reply (fail-open, self-healing on the next
voice note). Persisting it would mean either extending 028's `pending-reply.json` schema
(cross-group coupling the patcher design forbids — groups must roll back independently)
or a new state file with lifecycle/cleanup semantics. Consume-on-read (vs
consume-on-success) bounds spend to one synthesis attempt per voice exchange and was the
divergence the review caught between two artifacts — now pinned everywhere. Without V6,
"voice answers voice" was really "a voice existed in the last TTL window": the sequence
voice-note → typed correction ("mejor olvídalo, te escribo") → reply would have produced
an unsolicited voice bubble.

## D6 — Per-agent config delivery: compose `environment:` from `agent.yml` (029 pattern)

**Decision**: `agent.yml` gains `features.voice.{enabled, reply_mode, voice_id,
provider}`. Render maps them (sanitized) to compose `environment:` entries
`TELEGRAM_VOICE_ENABLED`, `TELEGRAM_VOICE_REPLY_MODE`, `TELEGRAM_VOICE_ID`,
`TELEGRAM_VOICE_PROVIDER`, plus `TELEGRAM_VOICE_STT_LANG` derived from the existing
`user.language`. Secrets and tuning knobs ride `.env` (compose `env_file`):
`ELEVENLABS_API_KEY` (required to activate), optional `TELEGRAM_VOICE_MAX_NOTE_SECONDS`
(default 300) and `TELEGRAM_VOICE_SPOKEN_CHAR_CAP` (default 1200) — same channel as
`TELEGRAM_TYPING_MAX_MS` and `CHANNEL_HEALTH_TIMEOUT`.

**Rationale**: The patcher bakes static code; per-agent values must arrive at runtime.
029 established exactly this route for `MCP_TIMEOUT` (agent.yml → sanitized placeholder →
compose `environment:`), and the typing patch already reads `process.env` tuning from
`.env`. Effective enablement is `TELEGRAM_VOICE_ENABLED=true` AND key present — a
missing key with the flag on degrades to inert with one boot-time stderr WARN (never a
crash), satisfying FR-002 and the clarified opt-in semantics.

**Sanitization** (render-time, `mcp_timeout_effective` mold): `enabled` →
schema-validated boolean; `reply_mode` → one of `auto|always|never`, anything else →
`auto`; `voice_id` → non-empty trimmed token (else a documented default stock voice id
constant); `provider` → `elevenlabs` (only value in v1; field exists for future swap);
**`TELEGRAM_VOICE_STT_LANG`** → `es|en` pass through, ANYTHING else — including the
wizard-legal `user.language: mixed` — renders as the empty string, and the STT helper
omits `language_code` when empty (autodetect). Without this sanitizer a `mixed` agent
would send an invalid language code on every STT call and the feature would be
dead-on-arrival for a first-class wizard configuration (2026-09-06 review, HIGH).
Delivery (analyze F1): the sanitized value exports as a DEDICATED derived placeholder
`{{VOICE_STT_LANG}}` — `USER_LANGUAGE` is never re-exported, because `claude-md.tpl`
also consumes it and must keep rendering the operator's literal choice (`mixed`
included); the new external placeholder joins `known_external` in schema.bats.

**Unconditional compose lines**: the five `TELEGRAM_VOICE_*` entries render
unconditionally (exact `MCP_TIMEOUT` precedent — no `{{#if}}` exists in that template
today and no flattened var expresses plugin presence). A non-telegram or voice-disabled
agent simply carries inert env (`TELEGRAM_VOICE_ENABLED: "false"`); no
"no-telegram renders no voice env" test is promised (the earlier draft's promise
contradicted this — dropped).

**Wizard gate**: the offer is gated on **deployment mode = docker** (asked first in the
wizard), NOT on telegram-plugin presence — telegram is a mandatory `type: default`
plugin present in every scaffold, so the plugin check discriminates nothing (2026-09-06
review). Local-mode answer streams gain no voice prompt. The prompts live in
`setup.sh`'s wizard section using the existing `ask_yn`/`ask` primitives —
`wizard.sh`/`wizard-gum.sh` are generic primitive libraries and are NOT touched.

## D7 — Model pins and provider abstraction

**Decision**: Model ids are named constants in the patcher: `VOICE_STT_MODEL =
"scribe_v2"`, `VOICE_TTS_MODEL = "eleven_flash_v2_5"` — one definition site each
(Principle VI). `provider` accepts only `elevenlabs` in v1; the STT/TTS calls live in
two dedicated helper functions in the hunk so a future provider is a new branch in those
helpers, not a re-architecture.

**Rationale**: Verified 2026-09-06: `scribe_v1` and `eleven_turbo_v2*` are deprecated;
Scribe v2 accepts Telegram's OGG/Opus directly (multipart `file` + `model_id`, header
`xi-api-key`); `eleven_flash_v2_5` is the cheap/fast tier ($0.05/1k chars, 32 langs incl.
Spanish). Cost per typical round trip ≈ $0.03 (SC-006 headroom vs the $0.05 bound).
Groq's OpenAI-compatible Whisper endpoint remains the documented alternative if E2 (accent
A/B) disappoints — a provider-helper branch, no schema change.

## D8 — Observability

**Decision**: One stderr line per pipeline step, prefixed `telegram channel: voice`,
via the existing stderr-capture path (`telegram-mcp-stderr.log`): transcription start
(with duration/size), transcription ok (chars, ms), transcription fail (reason class —
never the key, never raw response bodies), synthesis ok/fail, sendVoice fail → text-only
note, and a single boot-time line stating the effective config (enabled/mode/caps —
values only, no secrets).

**Rationale**: FR-012/SC-007 require diagnosing a dead pipeline from the log alone; the
typing patch v3+ set the precedent (fire-and-forget `.catch(() => {})` was the v1/v2
anti-pattern that hid everything). Redaction rule (extended 2026-09-06): the ElevenLabs
key, **the getFile download URL (it embeds the Telegram BOT TOKEN:
`api.telegram.org/file/bot<TOKEN>/…`)**, raw error objects, and response bodies never
reach the log — voice log lines interpolate only a derived error class + numeric HTTP
status. A bats hook asserts the hunk's stderr lines contain no raw `${err}`-style
interpolation (the adjacent upstream photo handler does exactly that and must not be
imitated).

## D9 — Detached inbound pipeline (added by the 2026-09-06 adversarial review)

**Decision**: The voice handler does NOT await the STT pipeline inside the update
handler. It performs the cheap synchronous checks (activation, DM-only pre-check, caps),
fires one fire-and-forget `sendChatAction('typing')` for sender feedback, schedules the
download+STT work detached (`void (async () => { … })()` with the 30 s AbortController),
and returns immediately. The detached continuation calls `handleInbound` with the
transcript (or the placeholder on failure) when it completes.

**Rationale**: grammY processes updates SEQUENTIALLY under the plugin's `bot.start()`
("handle updates sequentially" — one `await handleUpdate` per update before the next
`getUpdates`). An in-handler 30 s await would freeze the ENTIRE channel: texts from
other chats, commands, and the permission Allow/Deny callbacks of 028/031. Three burst
notes = up to 90 s of frozen channel — a direct FR-002 violation the original draft
missed. Detaching bounds the blast radius to the note itself. Accepted trade-off
(documented in the spec edge case): a transcribed note may be announced AFTER a
later-arriving text of the same chat; V6 (D5) makes the origin-flag semantics safe
under that reordering. The typing action at STT start closes the
zero-feedback window (up to 30 s of silence otherwise — the ack reaction and the
typing keep-alive only start inside `handleInbound`, i.e. after transcription).

## Empirical gates

- **E1 (opus container)** — neutralized by D4's runtime branch. A ~$0.001 confirmation
  call ships as an implementation task (runs with the operator's key when provisioning
  the first agent; asserts `OggS` or exercises the MP3 fallback deliberately).
- **E2 (Chilean-Spanish accuracy A/B)** — deferred to the deploy quickstart:
  transcribe 5-10 real notes; if Scribe v2 underperforms, Groq `whisper-large-v3-turbo`
  is the drop-in alternative via the provider helpers. Non-blocking by design.
- **E3 (upstream re-check)** — at implementation start, re-verify the pinned plugin
  version still lacks voice (issue #989 / plugin changelog); an upstream voice feature
  would change the patch baseline and this plan would be revisited.

## Test strategy (host-first, mirroring 031; hardened by the 2026-09-06 review)

- **Fixture extension is its own explicit task** (review HIGH): the synthetic fixture in
  `tests/apply-telegram-patches.bats` contains NONE of the anchors the voice hunks need
  (no `message:voice` handler, no `loadAccess()`, no files-loop/result region shaped
  like upstream, no reply inputSchema, no instructions array, no `message:text`
  handler for V6). The fixture heredoc gains upstream-shaped anchors for V1-V6 FIRST,
  with a checkpoint that the existing 43 tests stay green after the extension (the
  shared `const result =` anchor must still match exactly once).
- `tests/apply-telegram-patches.bats` gains ~20 voice-group tests (≈12 inbound at
  T004 + ≈8 outbound at T009 — tasks.md counts are authoritative; 43 → ~63): marker
  presence
  (full prefixed string), idempotent double-apply, anchor-drift fail-silent (mutated
  fixture), rollback leaves pre-032 groups intact, and hunk content assertions: DM-only
  pre-check (including the `dmPolicy` guard) BEFORE any fetch; the detached-pipeline
  shape (`void (async` scheduling — the handler must not await STT);
  `sendChatAction('typing')` at STT start; text chunks + marker-clear/ack site upstream
  of the voice block (V2 anchors after them); `voice_text` in the reply schema;
  instructions line; `OggS` sniff + mp3 fallback; caps comparison + `over-cap` literal;
  truncation helper with cap env + ellipsis; reply-mode gate expression +
  consume-on-read; stderr line prefixes (`telegram channel: voice stt ok`,
  `voice tts fail`) with NO raw `${err}` interpolation; V6 clear in the text handler;
  typing cascade v1→…→v6 unaffected by the voice group and vice versa. (Closes the
  five FR-oracle gaps the review found: FR-005/007/009/010/012.)
- NEW `tests/voice-config.bats` (~9): backfill writes disabled block; operator's
  explicit `enabled: true` / custom `reply_mode` survive regenerate; compose
  `environment:` renders sanitized values (invalid `reply_mode` → `auto`;
  `user.language: mixed` → `TELEGRAM_VOICE_STT_LANG: ""`); env-example gains the
  `ELEVENLABS_API_KEY=` name-only line; double-regenerate byte-identical.
- **FR-011 local-inert oracle** (review HIGH): +1 in `tests/local-render.bats` (029
  precedent): a voice-enabled agent.yml in `deployment.mode: local` renders no
  `TELEGRAM_VOICE_` string in any local RUNTIME artifact (units, scripts, .mcp.json,
  remote-control.env); `.env.example` documentation lines are exempt by design.
- `tests/docker-render.bats`: assert the new `environment:` lines.
- `tests/fixtures/sample-agent{,-with-vault}.yml`: gain the `features.voice` block
  (schema.bats placeholder-drift guard — the exact trap 031's T001 baseline caught).
- Wizard touchpoints (per the documented gotcha): `wizard_answers` helper, e2e-smoke
  prompt array, `known_external` in schema.bats — all updated in the same task that
  adds the wizard prompt; local-mode answer streams gain NO voice prompt (mode-gated).
- NEW `tests/docker-e2e-voice.bats` (DOCKER_E2E=1 gated, ~4): image builds; the baked
  patcher yields the voice marker + hunks inside the pinned image's plugin copy;
  compose env delivery (`docker compose run … env | grep ^TELEGRAM_VOICE_` asserts the
  five sanitized vars reach the container — 032 adds a baked reader, unlike 029);
  fault-injection (no key) boots inert with the WARN line — implementable because V5
  pins the one-time config line at MODULE scope, before any token/network use.
- Mutation spot-checks (6): revert fail-open try/catch (inbound); revert
  text-before-voice ordering; revert the DM-only pre-check (drop the dmPolicy guard);
  revert backfill-disabled default; make the voice block throw on TTS failure (must
  break the no-throw/marker-downstream tests); set VoiceOrigin on the placeholder path
  (must break the origin-only-on-success test). Each must break ≥1 test.
