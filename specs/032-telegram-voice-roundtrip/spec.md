# Feature Specification: Round-trip voice over the Telegram channel (async voice notes)

**Feature Branch**: `032-telegram-voice-roundtrip`

**Created**: 2026-09-06

**Status**: Draft

**Input**: User description: "The operator wants to interact with their agents by voice: dictate instructions and hear responses. Today the official Telegram channel plugin half-receives voice notes (the agent gets an audio file it cannot 'listen' to — nothing transcribes it) and cannot reply with voice at all (no voice-bubble send path; an audio attachment goes out as a plain document). Close the loop asynchronously over the existing channel: inbound voice note → transcription → the agent processes the instruction as text; agent reply → speech synthesis → a playable voice bubble back in the chat. Architecture already chosen by the operator (Option A of the 2026-09-06 analysis): a new patch group in the launcher's existing plugin patcher, with ElevenLabs as the initial speech provider for both directions, declared in agent.yml with secrets in .env. Real behaviour is docker/Telegram; local mode installs nothing active (the Remote Control relay is not the Telegram plugin)."

## Architecture decision (input to this spec, made by the operator 2026-09-06)

Four options were evaluated against a 7-researcher analysis of current official docs; the
operator chose **Option A — asynchronous voice notes over the existing channel, implemented
as a new patch group of the launcher's plugin patcher**:

- The agents' turns take 10–120+ s (tool use, MCPs). Every real-time voice platform
  evaluated (ElevenLabs Agents custom-LLM, OpenAI Realtime, Deepgram/Vapi/Retell,
  Pipecat/LiveKit) assumes sub-second streaming turns and none has a Telegram transport;
  Telegram voice notes are file-based and asynchronous — they match the agents' turn model
  with no timeout at all.
- ElevenLabs Agents' native Telegram integration is text-only (drops incoming voice notes)
  and registers a webhook that would evict the plugin's long-polling on the same bot token.
- Discarded alternatives: agent-side tools without a plugin patch (outbound voice would
  bypass the 028 reply-guard or degrade to a document attachment); a separate bridge bot
  (duplicates the agent's identity, loses the native channel).
- Initial speech provider: **ElevenLabs for both STT and TTS** (one vendor, one API key;
  at personal scale the cost difference vs alternatives is cents/month), with the provider
  recorded declaratively so it can be swapped later without re-architecting.

## Clarifications

### Session 2026-09-06

- Q: How is the voice feature enabled across the fleet? → A: Explicit opt-in — the
  backfill writes the block **disabled** for existing workspaces; the wizard offers it
  (default off) when the Telegram plugin is present *(wizard gate later superseded by
  the post-plan remediation below: the offer is gated on docker deployment mode — see
  FR-006)*. Enabling is an explicit operator act: `enabled: true` plus the speech key
  in `.env`. Nobody spends per-message money without deciding to (deliberate departure
  from 028/031's on-by-default guards).
- Q: How is the SPOKEN version of a long reply produced? → A: Agent proposes, plugin
  bounds — the reply contract gains an optional spoken-rendition field the agent fills
  with a voice-suitable version (steered by the channel prompt); when absent, the plugin
  synthesizes the reply text truncated at the spoken-length cap (default ~1,200
  characters). Best UX with a deterministic floor.
- Q: Reply-mode semantics and text accompaniment? → A: Default `auto` — voice answers
  voice-originated messages, typed messages get text only; `always` and `never` exist.
  The voice bubble is ALWAYS accompanied by the full reply text (accessibility, search,
  traceability).
- Q: Should the operator see the transcription of their own voice note echoed in the
  chat? → A: No echo — the transcript goes to the agent only; the agent's reply already
  reveals what was understood. The plugin posts no extra messages.

### Session 2026-09-06 (post-plan adversarial remediation)

An adversarial design review (4 independent reviewers against the real plugin source,
patcher, and launcher code) found and remediated the following before tasks:

- **Transcription runs detached from the update pipeline** — the channel processes
  updates sequentially, so an in-handler 30 s STT await would have frozen ALL chats and
  permission buttons; FR-002 and SC-002 now pin the non-blocking requirement and the
  10 s-typical / 30 s-hard numbers. Trade-off accepted: a transcribed note may announce
  after a later text from the same chat.
- **Transcription is DM-only in v1** — the side-effect-free paid-call pre-check is only
  exactly equivalent to the gate for private chats; group voice notes take the
  placeholder path by design (edge case updated; the earlier "same gate rules in
  groups" wording was wrong for transcription).
- **The wizard gate is deployment mode, not plugin presence** — the Telegram plugin is
  a mandatory default in every scaffold, so "when telegram selected" discriminated
  nothing; FR-006 now gates the wizard offer on docker mode.
- **Language hint sanitized** — `user.language: mixed` is a legal wizard value but not a
  language code; render maps only `es|en` through, anything else becomes empty
  (autodetect), so a `mixed` agent cannot be dead-on-arrival.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A spoken instruction is understood and acted on (Priority: P1)

The operator, away from a keyboard, records a voice note in the agent's Telegram chat:
"revisa el estado del heartbeat y mándame un resumen". The agent receives the instruction
as text — transcribed automatically before the message reaches it — knows it arrived as
voice, and processes it exactly as if it had been typed.

**Why this priority**: This is the half of the loop that unlocks hands-free operation, and
it is valuable entirely on its own — even with text-only replies, the operator can drive
the agent by voice. It is also the half where today's behaviour is actively broken: the
agent currently receives "(voice message)" plus an audio file it cannot interpret, so a
spoken instruction is silently lost unless the operator re-types it.

**Independent Test**: Send a real voice note to a paired agent; verify the agent's turn
starts from the transcribed text (visible in its reply behaviour) without the operator
typing anything. Deliverable and testable with no voice-out at all.

**Acceptance Scenarios**:

1. **Given** a paired chat and a configured speech key, **When** the operator sends a
   voice note with a clear spoken instruction, **Then** the agent receives the
   transcription as the message text, marked as voice-originated, and acts on the
   instruction without any extra operator step.
2. **Given** the transcription service is unreachable or the key is absent, **When** a
   voice note arrives, **Then** the channel behaves exactly as today (placeholder text +
   downloadable attachment reference) and text messaging is unaffected — the feature
   degrades, the channel never breaks.
3. **Given** a voice note longer/larger than the configured cap, **When** it arrives,
   **Then** it is not sent for transcription; the operator gets today's placeholder
   behaviour and the agent is told the note exceeded the voice limit.

---

### User Story 2 - The agent's answer comes back as a playable voice bubble (Priority: P2)

The operator who spoke to the agent hears the answer: the agent's reply arrives in the
chat as a native, playable Telegram voice bubble (with the reply text also available), so
the whole exchange can happen eyes-free.

**Why this priority**: Completes the round trip. Depends on US1 being useful (an agent
that can't understand voice has nothing to say back to it), and voice-out without
voice-in has little standalone value for this operator.

**Independent Test**: With voice replies enabled, trigger an agent reply to a
voice-originated message and verify the chat receives a playable voice bubble (not a
document, not a music-player track) whose audio matches the reply content.

**Acceptance Scenarios**:

1. **Given** voice replies are enabled in the default mode, **When** the agent replies to
   a voice-originated message, **Then** the operator receives a native playable voice
   bubble carrying the spoken reply, and the reply text remains available in the chat.
2. **Given** the same configuration, **When** the agent replies to a typed message,
   **Then** the reply is text only (voice answers voice; text answers text — default
   mode).
3. **Given** speech synthesis fails or the key is missing, **When** the agent replies to
   a voice-originated message, **Then** the text reply is delivered normally and the
   failure is logged — the answer is never lost to a voice error.
4. **Given** a very long reply, **Then** the spoken version respects a bounded length
   (voice-suitable rendition or cap) while the full text remains in the chat.

---

### User Story 3 - The operator turns it on, off, and survives regeneration (Priority: P3)

The operator declares the voice feature per agent in the agent's single configuration
source: enable/disable it, choose the voice, adjust the reply mode and caps. The setting
survives `--regenerate`, pre-032 workspaces get a sensible backfill, and a cloned
workspace picks the behaviour up on its next boot — no hand-edits anywhere.

**Why this priority**: This is the launcher's contract (declarative, idempotent,
regenerate-safe) applied to the new feature; without it the feature exists but is not
operable fleet-wide.

**Independent Test**: Toggle the feature in a scaffolded workspace's configuration, run
regeneration twice, and verify byte-identical derived output, correct on/off behaviour,
and that a workspace lacking the block gets it backfilled without clobbering operator
edits.

**Acceptance Scenarios**:

1. **Given** a pre-032 workspace, **When** the operator regenerates, **Then** the voice
   block is backfilled **disabled** (enabling is an explicit operator act — clarified
   2026-09-06) and an operator's explicit prior setting is never overwritten.
2. **Given** the feature disabled, **When** voice notes arrive or replies go out,
   **Then** behaviour is byte-for-byte today's behaviour (no transcription, no voice
   bubbles, no new log noise beyond a one-time "disabled" trace).
3. **Given** an agent whose workspace was cloned/restored, **When** it boots, **Then**
   the voice behaviour is applied automatically at boot exactly like the six existing
   plugin patch groups.

---

### Edge Cases

- **Missing/invalid speech key**: inbound falls back to today's placeholder + attachment;
  outbound falls back to text-only; each failure is logged once per turn, not spammed.
- **STT provider outage or timeout**: the voice note must still reach the agent (fallback
  placeholder) within a bounded delay — the transcription step cannot hang the inbound
  pipeline indefinitely.
- **Oversized audio**: notes above the transcription cap (duration/size, see Assumptions)
  skip STT with an explicit marker; Telegram's own 20 MB bot-download cap is the hard
  outer bound.
- **Non-voice audio**: music files/audio documents (`message:audio`, documents) are NOT
  transcribed — only voice notes (walkie-talkie bubbles) enter the voice pipeline.
- **Unpaired/gated senders**: the existing pairing gate must run BEFORE any download or
  paid transcription call — a stranger's voice note must not spend API credits.
- **Interaction with the 028 reply guard**: a voice reply must travel the plugin's reply
  path so the pending-reply marker clears; voice delivery failure must not leave the
  marker stuck (text fallback clears it).
- **Interaction with typing v6**: the typing indicator should cover the synthesis time;
  transcription happens before the agent's turn starts (before typing begins), adding a
  bounded pre-turn delay.
- **Heartbeat isolation**: cron ticks load no plugins (isolated config), so voice must
  add nothing there; nothing new to strip.
- **Group chats**: transcription is **DM-only in v1** (remediated 2026-09-06): the
  paid-call pre-check can only be made side-effect-free and exactly equivalent to the
  gate for private chats; a group voice note takes the placeholder path (today's
  behaviour) by design. Group text behaviour is untouched.
- **Transcripts that look like permission replies**: the channel's permission-reply
  intercept matches short patterns like "yes abcde" on message text; a transcript could
  theoretically match and be consumed by it. Accepted edge in v1 (the pattern requires
  an exact English y/yes/n/no + 5-letter token — implausible from Spanish dictation);
  logged when a voice-originated text ends at the intercept.
- **Long replies**: spoken rendition is bounded (see Assumptions); the full text is
  always delivered.
- **Rapid succession of voice notes**: each is transcribed independently and detached
  from the update pipeline, so a slow transcription never delays other messages; the
  trade-off is that a transcribed note may be announced to the agent after a
  later-arriving text from the same chat (accepted, documented — remediated
  2026-09-06).
- **Patch anchor drift**: if a future plugin update moves the anchors, the voice group
  must fail silent (log + leave the plugin working without voice), like the existing six
  groups.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Inbound Telegram voice notes MUST be transcribed automatically before the
  message is announced to the agent, so the agent's turn starts from the spoken words as
  text; the message MUST carry a machine-readable signal that it originated as voice
  (so the agent can adapt its reply) and MUST retain the attachment reference (so the raw
  audio remains downloadable as today). The transcript is delivered to the agent only —
  the plugin MUST NOT echo it into the chat as an extra message.
- **FR-002**: Transcription MUST be fail-open: on missing key, provider error, timeout,
  or an over-cap note, the inbound message MUST degrade to today's exact behaviour
  (placeholder text + attachment id) within a bounded delay, and text messaging MUST be
  unaffected in all cases — including while a transcription is in flight: an STT call
  MUST NOT block the processing of other channel messages (the channel's update pipeline
  is sequential; the transcription runs detached from it — remediated 2026-09-06). The
  failure reason MUST be logged to the plugin's existing stderr capture.
- **FR-003**: The agent's replies MUST be deliverable as native playable Telegram voice
  bubbles (not documents, not music-player tracks), generated by speech synthesis from
  reply text, in the agent's configured voice.
- **FR-004**: Voice replies MUST travel through the plugin's existing reply path so the
  028 pending-reply marker clears on send; a synthesis or voice-send failure MUST fall
  back to the normal text reply (which also clears the marker) — an answer is never lost
  to a voice error.
- **FR-005**: The default reply mode MUST be `auto` ("voice answers voice"): replies to
  voice-originated messages carry voice + the full reply text; replies to typed messages
  remain text-only. The mode MUST be configurable per agent (auto / always / never), and
  in every mode a voice bubble is ALWAYS accompanied by the full reply text — voice-only
  delivery does not exist (clarified 2026-09-06).
- **FR-006**: The feature MUST be declared per agent in `agent.yml` under a
  `features.voice` block (enabled flag, provider, voice selection, reply mode, caps —
  exact field set is design), following the established toggle pattern: schema-validated
  booleans, `has()`-guarded backfill on regenerate that never clobbers an operator's
  explicit values, and byte-identical double-regenerate. The backfill default and the
  wizard default are both **disabled** (explicit opt-in — clarified 2026-09-06); the
  wizard offers the feature on docker-mode scaffolds (the Telegram plugin is a mandatory
  default, so deployment mode is the real discriminator — remediated 2026-09-06) and,
  when declined, still documents the `.env` key name needed to enable it later.
- **FR-007**: Speech-provider credentials MUST live only in the workspace `.env`
  (key NAME documented; value never in `agent.yml`, templates, logs, or repo), reaching
  the plugin via the existing container env delivery.
- **FR-008**: The behaviour MUST be applied at boot by the launcher's plugin patcher as a
  new, independent patch group: own marker, idempotent re-application, fail-silent on
  anchor drift with group-scoped rollback, no coupling to the typing-group upgrade
  cascade. A cloned/restored workspace picks it up on next boot.
- **FR-009**: Voice-note transcription MUST be bounded by a configurable cap (duration
  and/or size) with a sensible default, and the pairing/access gate MUST run before any
  download or paid API call.
- **FR-010**: The spoken rendition of a reply is produced "agent proposes, plugin
  bounds" (clarified 2026-09-06): the reply contract MUST accept an optional
  spoken-rendition field the agent fills with a voice-suitable version (steered by the
  channel prompt); when the field is absent, the plugin MUST synthesize the reply text
  truncated at the spoken-length cap (default ~1,200 characters). The full reply text
  MUST always be delivered regardless of what is spoken.
- **FR-011**: Local (Remote Control) mode MUST remain inert: no active voice behaviour,
  no errors introduced; the configuration block may exist but drives nothing (same
  declared pattern as 028/031).
- **FR-012**: Observability: each voice pipeline step (transcription start/result/fail,
  synthesis start/result/fail, voice send fail → text fallback) MUST emit one concise
  stderr line via the plugin's existing capture, sufficient to diagnose a broken pipeline
  from `logs/telegram-mcp-stderr.log` alone.
- **FR-013**: With the feature disabled (or in any failure mode), the existing test suite
  and the channel's observable behaviour MUST remain unchanged — zero regressions to the
  text channel, the six existing patch groups, and the 028/031 guards.

### Key Entities

- **Voice note (inbound)**: a Telegram walkie-talkie audio bubble; attributes: file id,
  duration, size, mime; subject to the 20 MB bot-download cap and the configured
  transcription cap.
- **Transcript**: the text produced from a voice note; becomes the message text the agent
  sees; carries a voice-origin marker; never silently replaces the attachment reference.
- **Voice reply**: synthesized audio of (a bounded rendition of) the agent's reply text,
  delivered as a native voice bubble alongside the text.
- **Voice configuration (`features.voice`)**: per-agent declarative block — enabled,
  provider, voice selection, reply mode, caps; single source of truth, regenerate-safe.
- **Speech credential**: the provider API key, named in `.env` only.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An operator can complete a full task by voice alone — send a spoken
  instruction, receive a spoken answer — with zero typed input, on a real paired agent.
- **SC-002**: For a voice note of ≤60 s, the transcription step adds no more than 10 s
  before that message's turn begins under normal conditions (target ~3 s typical), with
  a 30 s hard never-hang bound (FR-002's timeout); other channel messages are processed
  normally while a transcription is in flight.
- **SC-003**: The voice reply renders as a playable native voice bubble on official
  Telegram clients (iOS/Android/Desktop), not as a file/document.
- **SC-004**: With the feature disabled, the key missing, or the provider down, the
  channel's observable behaviour is identical to v0.22.0 (existing bats suite green and
  byte-identical patcher output for the six existing groups).
- **SC-005**: The configuration survives two consecutive regenerations byte-identically,
  a pre-032 workspace gets a correct backfill, and a cloned workspace exhibits voice
  behaviour on its next boot with no manual step.
- **SC-006**: A typical round trip (60 s inbound note + ~500-character spoken reply)
  costs at most $0.05 in provider fees.
- **SC-007**: A broken voice pipeline is diagnosable from the plugin stderr log alone
  (each failure names its step and reason) — verified by fault-injection during e2e.

## Assumptions

*(Remaining defaults not pinned by the description or the 2026-09-06 clarify session —
the enable default, reply-mode semantics, spoken-rendition mechanism and no-echo
behaviour are DECIDED there, not here.)*

- **Provider default**: ElevenLabs for both STT (current Scribe model) and TTS (current
  Flash-tier model) under one API key; the provider field exists from day one so an
  alternative (e.g. an OpenAI-compatible Whisper endpoint) can be added later without
  schema change. Model ids are design-time pins (Principle VI), not spec content.
- **Spoken-length cap value**: the ~1,200-character default of the plugin-side
  truncation floor (FR-010) is a design-tunable value, not a contract; the plan fixes
  the exact number and whether it is operator-configurable.
- **Transcription cap default**: notes over a default duration (order of 5 minutes)
  or over Telegram's 20 MB download cap are not transcribed.
- **Docker-only active behaviour**: the real pipeline exists in docker/Telegram mode;
  local mode is declared-but-inert. DOCKER_E2E is expected to be REQUIRED (the patcher
  and possibly the image package set are image-baked).
- **Two empirical unknowns are Phase-0 gates, not spec blockers**: (1) whether the
  provider's opus output is a container Telegram accepts directly for voice bubbles —
  with two known no-transcode fallbacks (provider MP3 is also accepted for voice bubbles
  per Bot API 10.3; ffmpeg exists for Alpine aarch64 as last resort, and adding it would
  touch the image); (2) Chilean-Spanish accuracy A/B between the chosen provider and the
  named alternative (recommended, non-blocking).
- **Upstream check before implementation**: re-verify that the official plugin still
  lacks voice support (issue #989 open, plugin version unchanged) at implementation
  time; an upstream voice feature would change the patch baseline.
- **Out of scope**: real-time calls (infeasible for bots on Bot API 10.3), group-specific
  voice behaviour, voice for the heartbeat/notifier path, local-mode active voice, voice
  cloning setup flows (a cloned voice id is just a value in the voice field).
