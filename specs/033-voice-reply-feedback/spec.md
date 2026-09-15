# Feature Specification: Voice reply feedback — the channel tells the agent what its voice did, and honours explicit audio requests

**Feature Branch**: `033-voice-reply-feedback`

**Created**: 2026-09-13

**Status**: Draft

**Input**: User description: "The Telegram voice channel (032, v0.23.0) lies to the user about its own outbound capability and inconsistently omits the spoken rendition. Measured in production on 2026-09-13: the agent opened a reply with 'the outbound audio is still not available in this plugin' while, in the same turn, the plugin synthesized and sent a 76-second voice bubble reading 1,138 characters of a numbered list aloud. Root cause: the reply tool's result never mentions the voice outcome, so the agent acts blind and a pre-032 `--continue` history outweighs one instructions line. Fix: a deterministic feedback line in the reply result (US1), an honest rewrite of the channel's stated contract via a marker bump v1→v2 (US2), and observability of spoken-rendition omission (US3). Real-time conversation is a separate feature (034). No new config, no new privileges, image-baked patcher only. Scope extended by the operator the same day (US4): a typed message that explicitly asks for audio ('responde con audio') must make the next reply spoken, strictly — the plugin guarantees it, not the agent; typed messages that do not ask keep today's text-only default."

## Measured defect (input to this spec, verified 2026-09-13)

Agent `linus` (docker, ferrari), Telegram chat, 13:43–13:44 -03. Source: the plugin's own
stderr capture (`logs/telegram-mcp-stderr.log`) and the live patched `server.ts`.

1. The operator sends an 8-second voice note. Log: `voice stt ok ... dur=8s chars=94 ms=3685`.
2. The agent replies in text and OPENS with: "Va por texto — el audio saliente sigue sin estar
   disponible en este plugin." followed by a five-item numbered list.
3. Same turn, the log reads `voice tts ok ... chars=1138 fmt=ogg ms=10687`: the plugin DID
   synthesize and send a native voice bubble (01:16, 786.5 KB), visible in the chat right
   after the text. The agent asserted a limitation that does not exist, and that assertion
   reached the operator.
4. The 1,138 characters spoken equal the full reply text — a list formatted for the eyes,
   read aloud for 76 seconds. Earlier turns of the same agent that day show `chars=29` and
   `chars=233`: the agent CAN produce a short spoken rendition; it omits it inconsistently.
   Today's log cannot tell whether a spoken rendition was supplied (it does not record
   that) — which is what US3 fixes.
5. The 032 instructions line and the outbound voice block are both applied in the live
   plugin source (verified by line). This is not a patch-application failure.

**Root cause.** The reply tool's result is only `sent (id: N)` / `sent N parts (...)`. The
032 outbound voice step runs after that string is built and before it is returned; it logs
to stderr and never touches what the agent sees. The agent has no evidence — in its own
context — that the voice went out, how much was spoken, or that synthesis failed. In a
resumed session whose history predates v0.23.0 (every docker agent upgraded on 2026-09-12),
the agent's own older belief ("I cannot send audio") outweighs one line buried in the
channel's instructions array. Same defect class as 028 (a truthful-looking but false message
reached the user) and 031: the remedy is a deterministic signal, not more prompting.

## Clarifications

### Session 2026-09-13

- Q: When the outcome line says the voice FAILED and the user got text only, what should
  the agent do with that information? → A: Mention it briefly to the user — the channel
  contract instructs the agent to add one short, honest sentence (in a brief follow-up or
  its next reply) that the audio did not go out this time; at most once per failure, no
  retry. No plugin-authored message, no new mechanism.
- Q: Omission nag threshold (US3) — from how much reply text read aloud without a spoken
  rendition does the acknowledgement warn the agent? → A: A fixed fraction of the
  spoken-length cap, no knob (the plan fixes the fraction; a quarter of the cap is the
  working value). The stderr omission record is emitted for every omission regardless of
  threshold, so the rate stays fully measurable.
- Q: Failure granularity in the outcome line — does it distinguish which step failed? →
  A: Yes — a `step` field (`synth` for the speech provider, `send` for the Telegram
  delivery) joins the whitelist, on both the acknowledgement line and the stderr line, so
  a provider/key problem and a Telegram rejection are distinguishable without reading code.
- Q: SC-003 acceptance number (spoken-rendition omission rate after the contract rewrite,
  measured by the US3 record over 10 voice exchanges on a live agent)? → A: At most 1 in
  10. One isolated omission is model noise; two is a signal the wording is insufficient.

Scope extension requested by the operator in the same session — a typed explicit request
for audio must produce a spoken reply, strictly (US4):

- Q: When the operator types "responde con audio", how long does the effect last? → A:
  The next reply only — identical to sending a voice note (one-reply scope, consumed on
  read, same expiry as the 032 voice origin). A persistent runtime "audio mode" was
  rejected: it would be a runtime mode switch that Principle I requires to be written to
  `agent.yml`, i.e. a separate feature.
- Q: How is the explicit request recognised? → A: A fixed, documented phrase set matched
  by the plugin (Spanish and English, case- and accent-insensitive, anywhere in the
  message) — deterministic and testable — PLUS an explicit force-voice flag on the reply
  so the agent can honour phrasings outside the set. The flag is a separate boolean, not
  the mere presence of a spoken rendition, so a bubble can never go out by accident.

### Session 2026-09-13 (post-plan adversarial remediation)

An adversarial review of the plan against the real patcher and tests (workflow
`wf_e99b3212-83d`, 4 reviewers; details in `research.md` §Review remediation) changed the
following spec-level statements:

- **Failure loop in mode `always` is mechanised, not promised** — a one-shot per-chat
  cooldown after a failed voice attempt (FR-012); the earlier "e2e MUST confirm no loop"
  had no tier that could run it.
- **Explicit-request gate = the 032 inbound gate** (private chat, DM policy not disabled,
  sender allowed), not `private` alone (FR-011).
- **Strictness has one documented limit**: only the first reply call of an exchange is
  spoken (consume-on-read); the contract steers a single reply; SC-007 is measured on the
  first reply (edge case added).
- **Typographic apostrophes** (`don’t`) are normalised before the negation guard; nine
  Chilean-Spanish and four English request forms added to the phrase table.
- FR-009 reworded: the suite stays green with the enumerated v1-literal oracles moved to
  v2; FR-013: non-boolean `voice_force` is ignored.

### Session 2026-09-14 (post-analyze)

`/speckit-analyze` (workflow `wf_d975526e-1ca`, 3 lenses, 24 unique findings — 1
constitution-form, 5 HIGH, 9 MEDIUM, 9 LOW) changed these spec statements; the rest was
task/plan alignment:

- **Independent Tests of US1/US3/US4 reworded** to what the verification tiers actually
  prove (host structural oracles; matcher and error-class behaviour under bun in e2e; the
  reply path itself on a live agent, linus first). The earlier "replay with the provider
  stubbed" described a harness no task builds.
- **SC-004** now names its two provable legs (host structure + live agent with voice off);
  **SC-006** splits into the synthesis leg (live fault injection) and the send leg
  (structural step-flip oracle + error-class behaviour test) — Telegram rejecting a bubble
  is not reproducible on demand.
- **FR-001 / US1**: `ms` is the round-trip (synthesis + send), not "synthesis time".

## User Scenarios & Testing *(mandatory)*

### User Story 1 - The agent learns, in the same turn, what its voice did (Priority: P1)

The agent replies to a voice-originated message. The channel's reply acknowledgement now
also states the voice outcome: that a voice bubble was sent (and how long it was), or that
synthesis failed and only text went out. The agent stops guessing about its own
capability: it has observed evidence, every turn, in its own context.

**Why this priority**: It is the deterministic fix for the measured lie. Observed evidence
in the current turn beats stale belief from a resumed history, and it needs no change to
what the agent is told up-front. It is valuable alone: even with today's instructions,
an agent that reads "voice: sent" once will not claim it cannot send audio next turn.

**Independent Test**: On the patched plugin source, the acknowledgement expression is
`result + _voiceOutcome` with `_voiceOutcome` initialised empty before the voice step, and
the only two assignments are the exact `sent`/`failed` templates inside the existing
try/catch (host oracles — byte-identity when the step does not run follows by
construction). The error-class helper's behaviour is exercised under bun in e2e. The
outcome line itself is observed on a live agent (quickstart §3.2): one voice note → the
tool result and the stderr line agree on length and format.

**Acceptance Scenarios**:

1. **Given** a voice-originated exchange and a working speech provider, **When** the agent
   replies, **Then** the reply result includes one voice-outcome line stating the bubble
   was sent, its audio format, spoken length and round-trip time (synthesis + send) — and
   the same values appear in the plugin's stderr line for that turn.
2. **Given** a voice-originated exchange and a failing speech provider, **When** the agent
   replies, **Then** the text reply is delivered as today and the reply result includes
   one voice-outcome line stating the failure by step (synthesis or send), class and
   status only — no raw error text, no URL, no credential — and the agent, per the contract, tells the user in one
   short honest sentence that the audio did not go out this time (once, no retry).
3. **Given** the voice feature disabled, the reply mode `never`, a typed-message exchange
   (no explicit audio request, no force flag), or an expired voice origin, **When** the
   agent replies, **Then** the reply result is byte-for-byte what v0.23.0 returns (no
   outcome line, no extra whitespace).
4. **Given** the outcome line is present, **When** the agent composes its next reply,
   **Then** nothing in the channel's contract invites it to relay the diagnostic line to
   the user (the line is addressed to the agent, not the chat).

---

### User Story 2 - The channel's stated contract tells the truth about outbound voice (Priority: P1)

The description of the channel the agent reads at session start says plainly what happens:
in a voice-originated exchange the plugin sends the reply as a voice bubble automatically;
the agent must never tell the user it cannot send audio; if the agent omits the spoken
rendition, its full reply text is read aloud up to the cap. Agents already running the
previous wording are upgraded in place at next boot, with no operator step.

**Why this priority**: US1 corrects the agent after the first voice turn; US2 prevents the
first-turn lie and the long read-aloud from happening at all. Both are P1 because the
measured defect needs both halves: evidence (US1) and an honest contract (US2). This is
the same remedy shape 028 used for the typing warning (marker bump, honest rewrite).

**Independent Test**: Apply the patcher to (a) a pristine upstream fixture and (b) a
fixture already carrying the v1 voice group; in both, assert the instructions text and
the spoken-rendition field description carry the new statements and the v1 wording is
gone; apply a second time and assert byte-identical output.

**Acceptance Scenarios**:

1. **Given** a pristine plugin source, **When** the patcher runs, **Then** the channel
   contract carries the truthful wording (automatic voice on voice-originated exchanges;
   never claim inability; omission consequence) and the group is marked at its new version.
2. **Given** a plugin source already patched at the previous voice version (today's whole
   docker fleet), **When** the patcher runs at boot, **Then** the wording is replaced in
   place, the group is marked at the new version, and every other patch group is untouched.
3. **Given** an already-upgraded source, **When** the patcher runs again, **Then** the
   output is byte-identical (idempotent).
4. **Given** the previous wording was edited out-of-band so its anchor no longer matches,
   **When** the patcher runs, **Then** it logs a warning and leaves the file at the highest
   version it can recognise — the plugin keeps working with voice as before.

---

### User Story 3 - Omitting the spoken rendition is observable and corrected in-turn (Priority: P2)

When the agent replies to a voice-originated message without supplying a spoken rendition,
and the reply text is long enough that reading it aloud is a poor experience, the channel
records the omission (how many characters of reply text were read aloud) in its stderr
log and tells the agent in the reply result. The operator can measure the omission rate
from the log; the agent gets the correction while the exchange is still fresh.

**Why this priority**: It turns "the agent sometimes omits it" from a suspicion into a
number, and closes the loop on the second half of the measured defect (the 76-second
list). It depends on US1's outcome line existing; without US1/US2 it would only measure,
not fix.

**Independent Test**: On the patched plugin source, the omission stderr line and the nag
clause are nested under the "spoken text came from `text`" condition, in that order, with
the nag additionally gated by the threshold derived from the spoken cap (no literal, no
knob) — host oracles. The rate itself is measured on a live agent over 10 voice exchanges
(quickstart §3.4).

**Acceptance Scenarios**:

1. **Given** a voice-originated exchange, **When** the agent replies with no spoken
   rendition and reply text above the nag threshold, **Then** stderr records one omission
   line with the character count and the reply result's outcome line says the spoken
   rendition was omitted and how many characters of reply text were read aloud.
2. **Given** the same exchange with reply text at or below the threshold, **When** the
   agent replies without a spoken rendition, **Then** the reply result carries the plain
   "sent" outcome with no omission nag; stderr still records the omission for measurement.
3. **Given** the agent supplies a non-empty spoken rendition, **When** it replies, **Then**
   no omission line is produced anywhere.

---

### User Story 4 - An explicit request for audio is honoured, strictly (Priority: P2)

The operator types a message that asks for a spoken answer — "responde con audio",
"reply with audio", or another phrase from a fixed, documented set — and the next reply
arrives as a voice bubble (with the full text, as always), exactly as if the operator had
sent a voice note. Typed messages that do not ask for audio keep today's default: text
only. The effect lasts one reply. When the request is worded outside the fixed set, the
agent can still honour it by explicitly forcing voice on that reply.

**Why this priority**: Requested by the operator on 2026-09-13 as the other half of
"voice mode": today a voice note is the only way to get a spoken answer, and the plugin is
the only party that can guarantee one — the agent cannot be trusted to remember it can
(the measured defect). Independent of US1–US3 (it adds a trigger, not feedback), but it
inherits US1's outcome line and US2's contract, which is why it ships in the same group
version.

**Independent Test**: The phrase matcher (normalisation, whole-word match over every
occurrence, negation guard) is executed under bun in e2e against the positive and negative
tables of the contract. On the patched source, host oracles assert the typed-message wrap
marks the exchange only behind the 032 DM gate, voice active and mode not `never`; that
the force flag is read strictly and is the third trigger; and that a spoken rendition
alone triggers nothing. The end-to-end effect (typed request → bubble; plain text → none;
`voice_force` → bubble) is observed on a live agent (quickstart §3.5, §3.7).

**Acceptance Scenarios**:

1. **Given** mode `auto` and a working provider, **When** the operator types a message
   containing a phrase from the fixed set (any case, with or without accents, anywhere in
   the message), **Then** the reply is delivered with a voice bubble plus the full text and
   the outcome line reports it — regardless of how the agent wrote its reply.
2. **Given** the same setup, **When** the operator types a message with no such phrase,
   **Then** the reply is text only and the reply result is byte-identical to v0.23.0
   (default unchanged).
3. **Given** a reply already spoken because of an explicit request, **When** the operator's
   next typed message has no request, **Then** that next reply is text only (one-reply
   scope).
4. **Given** the operator asks for audio in words outside the fixed set, **When** the agent
   sets the force-voice flag on its reply, **Then** the reply is spoken; **When** the agent
   instead only supplies a spoken rendition without the flag, **Then** nothing is spoken
   (no accidental bubble).
5. **Given** mode `never` or the feature disabled, **When** the operator asks for audio by
   phrase or the agent sets the flag, **Then** no voice is attempted and the reply result is
   byte-identical to v0.23.0 (mode and feature switch win).

---

### Edge Cases

- **Voice not applicable**: feature disabled, no speech key, mode `never`, typed exchange
  with neither an explicit audio request nor the force flag, expired voice origin — the
  reply result is byte-identical to v0.23.0. This is the regression guard for every agent
  that never turned voice on.
- **Synthesis or send failure**: the outcome line reports failure by step (`synth` or
  `send`), class and status only; the text reply is unaffected; the 028 pending-reply marker was already cleared
  before the voice step (032 ordering preserved).
- **Whitespace-only spoken rendition**: treated as omitted (032 already does this); US3
  counts it as an omission.
- **Over-long spoken rendition**: 032 speaks a supplied rendition as-is (only the fallback
  from reply text is capped); this feature does not change that, but the outcome line
  reports the spoken length so the agent can self-correct.
- **Mode `always` on a typed exchange**: a bubble is sent, so the outcome line is present —
  consistent rule: the line appears whenever the voice step ran.
- **Assembling the outcome line fails** (unexpected value, string error): the reply result
  must still be returned with at least today's `sent` acknowledgement — feedback can never
  strand a reply or throw out of the tool handler.
- **Redaction**: the outcome line enters the model's context and the session transcript.
  It may carry only whitelisted fields (error class, numeric status, audio format,
  character count, milliseconds). Never a raw error message, never a file URL (Telegram
  file URLs embed the bot token), never the spoken text itself.
- **Fleet upgrade**: every docker agent is at the previous voice version today; the in-place
  upgrade must be exercised by a fixture that reproduces that state, not only by the
  pristine path.
- **Anchor drift on the return line**: the outcome line changes what the reply handler
  returns; if upstream later reshapes that line, the voice group fails silent as a whole
  (group-scoped rollback, as in 032) — voice degrades, the text channel never breaks.
- **The agent parrots the diagnostic**: the contract wording must make clear the outcome
  line is for the agent's own awareness, not something to repeat verbatim to the user;
  the only thing it relays is the one-sentence failure mention (clarified 2026-09-13).
- **Failure mention in mode `always` during a provider outage**: the agent's brief
  "audio did not go out" follow-up is itself a reply, which in mode `always` would
  trigger a new voice attempt that fails again and re-arms the loop. Mechanised (post-plan
  remediation, FR-012): after a failed attempt in mode `always` the plugin skips
  synthesis once for that chat (one-shot cooldown, logged, no outcome line), so the
  mention goes out text-only and cannot fail; the next user message tries voice again.
  In mode `auto` the follow-up is text-only anyway (the voice origin was consumed).
- **Two reply calls in one turn**: the voice origin is consumed by the first reply call,
  so an agent that answers "un momento…" and then the real answer speaks only the first.
  Known limit of consume-on-read (the plugin cannot see turn end); the contract steers
  "answer in ONE reply when voice is expected" and SC-007 counts the first reply of each
  exchange.
- **Heartbeat isolation and local mode**: unchanged — cron ticks load no plugins; local
  (Remote Control) mode installs nothing active (032's FR-011 stands).
- **Request phrase inside a longer message**: matches (substring, case- and
  accent-insensitive). A message that merely mentions audio without asking ("el audio de
  ayer se cortó") is the known false-positive class; the fixed set is phrased as
  imperative requests to keep it rare, the plan fixes the list, and a test enumerates
  negatives that must NOT match.
- **Explicit request in a group chat or from an unpaired sender**: never marked — the
  request gate is exactly the 032 inbound pre-check (private chat, DM policy not
  disabled, sender in the allow list), so a chat 032 would not transcribe is not marked
  by a typed request either.
- **Force flag on an exchange that is already voice-originated**: redundant; exactly one
  bubble goes out.
- **Restart between the request and the reply**: the one-reply mark lives in memory and is
  lost with the restart → the reply is text only, fail-open (032 behaviour); no outcome
  line is produced, so the agent cannot claim voice was sent.
- **Explicit request while the provider is down**: voice is attempted anyway (strict) and
  fails → outcome `failed` → the agent mentions it once (clarified 2026-09-13).

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Whenever the outbound voice step runs for a reply, the reply acknowledgement
  returned to the agent MUST include exactly one voice-outcome line stating either
  success (audio format, spoken character count, round-trip time — synthesis plus send)
  or failure (failed step — synthesis or send —, error class, numeric status).
- **FR-002**: Whenever the outbound voice step does NOT run (feature disabled, no key,
  mode `never`, typed exchange with neither an explicit audio request nor the force flag,
  expired voice origin), the reply acknowledgement MUST be byte-identical to the v0.23.0
  acknowledgement.
- **FR-003**: The voice-outcome line MUST contain only whitelisted fields (failed step
  `synth`|`send`, error class, numeric status, audio format, character count,
  milliseconds) — never raw error text,
  URLs, credentials, or the spoken text — and the test oracle MUST assert the whitelist,
  not merely the absence of a raw error interpolation.
- **FR-004**: The channel contract the agent reads (its instructions and the spoken-
  rendition field description) MUST state, in plain terms: that in a voice-originated
  exchange the reply is ALSO sent as a voice bubble automatically; that the agent MUST
  NOT tell the user it cannot send audio; that omitting the spoken rendition causes the
  full reply text to be read aloud up to the cap; that the voice-outcome line is
  feedback for the agent, not content to relay verbatim; and that when the outcome
  reports a failure the agent tells the user, in one short honest sentence, that the
  audio did not go out this time — at most once per failure, never retrying the voice
  (clarified 2026-09-13). The contract MUST also state that an explicit typed request for
  audio makes the next reply spoken automatically (so a spoken rendition is expected
  there too), and that the force-voice flag is to be set only when the user asked for
  audio in words the fixed phrase set does not cover.
- **FR-005**: The change (contract wording, outcome line, explicit-request trigger and
  force-voice flag) MUST ship as one version bump of the existing voice patch group with
  an in-place upgrade from the previous version: pristine source → new version
  directly; previous-version source → upgraded in place; already-upgraded source →
  byte-identical (idempotent); unrecognised prior edits → warning, file left at the
  highest recognised version. The upgrade MUST be group-scoped (no coupling to any other
  patch group's cascade) and MUST fail silent on anchor drift.
- **FR-006**: When the voice step speaks the reply text because no spoken rendition was
  supplied, the plugin MUST record one stderr line naming the character count read aloud,
  and — when that count exceeds a nag threshold — the voice-outcome line MUST also state
  that the spoken rendition was omitted and how many characters were read aloud.
- **FR-007**: This feature MUST introduce no new field in `agent.yml`, no wizard prompt,
  no schema change, and no new runtime tuning variable. The nag threshold MUST be a fixed
  value derived from the spoken-length cap (a fraction of it; the plan fixes the exact
  fraction — clarified 2026-09-13), so an operator who raises the cap raises the
  threshold with it and nothing new needs documenting.
- **FR-008**: Building the voice-outcome line MUST be fail-silent: any error while
  composing it MUST leave the v0.23.0 acknowledgement intact and MUST NOT throw out of
  the reply handler.
- **FR-009**: With voice not applicable, the channel's observable behaviour and the output
  of the other six patch groups MUST remain byte-identical, and the existing test suite
  MUST stay green — the oracles that pin the previous voice version's literals or the
  pristine return line are moved to the new version's expectations (enumerated in the
  plan); no test is deleted (zero regression).
- **FR-010**: Local (Remote Control) mode MUST remain inert — nothing new is installed or
  rendered there.
- **FR-011**: A typed message containing one of a fixed, documented set of explicit
  audio-request phrases (Spanish and English; matched case- and accent-insensitively,
  anywhere in the message) MUST mark the exchange as voice-originated exactly as an
  inbound voice note does — same one-reply scope, same expiry, consumed on the next reply
  — so that in mode `auto` the next reply is spoken. The phrase set is fixed in the plugin
  and documented; it is not configurable (FR-007). The request is recognised only where
  the 032 inbound pre-check would transcribe a voice note (private chat, DM policy not
  disabled, sender allowed) and only while voice is active and the mode is not `never`.
- **FR-012**: When an exchange is voice-originated — by voice note or by explicit request
  — and the mode is `auto` or `always`, the plugin MUST speak the reply regardless of the
  agent's reply content; the agent has no opt-out. A failure to do so is reported (FR-001)
  and mentioned to the user (FR-004). In mode `never`, or with the feature disabled, the
  request has no effect and the acknowledgement stays byte-identical (FR-002). In mode
  `always`, after a failed voice attempt the plugin MUST skip synthesis exactly once for
  that chat (a one-shot cooldown: logged, no outcome line, expires like the voice origin)
  so that the agent's failure mention cannot itself fail and re-arm the loop.
- **FR-013**: The reply contract MUST gain an explicit boolean to force a voice bubble on
  the current reply; when set on a typed exchange in mode `auto`, the plugin MUST speak
  the reply. Absent, `false`, or any non-boolean value MUST have no effect; mode `never`
  and the feature switch override it. The presence of a spoken rendition alone MUST NOT
  trigger voice. The
  channel contract MUST steer the agent to set the flag only when the user asked for
  audio in words the fixed set does not cover.
- **FR-014**: Typed messages that neither contain a request phrase nor receive a forced
  reply MUST remain text-only in mode `auto` — the default is unchanged from v0.23.0
  ("never audio unless spoken to or asked").

### Key Entities

- **Voice outcome**: the result of one outbound voice attempt — `sent` (format, spoken
  characters, milliseconds) or `failed` (step `synth`|`send`, error class, numeric
  status) — plus whether the
  spoken text came from a supplied rendition or from the reply text fallback. Exists only
  when the voice step ran.
- **Reply acknowledgement**: the text the channel returns to the agent after a reply —
  today's "sent" line, extended by the voice-outcome line when applicable.
- **Voice patch group version**: the marker that identifies which wording and behaviour a
  plugin source carries; bumped by this feature, upgradeable in place.
- **Omission record**: a stderr line counting characters of reply text read aloud without
  a spoken rendition; the measurable basis for the omission rate.
- **Voice origin**: the per-chat, one-reply mark that makes the next reply spoken; set by
  an inbound voice note (032) or by an explicit audio-request phrase (this feature);
  consumed on read, expires as in 032.
- **Force-voice flag**: an explicit per-reply boolean the agent sets to speak a reply on a
  typed exchange; distinct from the spoken rendition, which never triggers voice by itself.
- **Explicit request phrase set**: a fixed, documented list of imperative request phrases
  (Spanish and English), matched case- and accent-insensitively; not configurable.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: In end-to-end runs with the speech provider available, 100% of replies to
  voice-originated messages return an acknowledgement whose voice-outcome line matches
  the plugin's stderr line for that turn (same spoken length, same audio format).
- **SC-002**: On a live agent whose resumed history predates v0.23.0 (linus today), across
  5 consecutive voice notes the agent makes 0 claims of being unable to send audio in
  replies 2 through 5.
- **SC-003**: The spoken-rendition omission rate becomes measurable from the stderr log
  alone (no such measurement exists today); after the contract rewrite, at most 1 in 10
  voice-originated replies over a 10-exchange sample on a live agent reads the reply text
  aloud without a spoken rendition (target confirmed 2026-09-13).
- **SC-004**: An agent with voice disabled (or without a speech key) returns a reply
  acknowledgement byte-identical to v0.23.0 — verified structurally in the host suite
  (empty initial outcome, single concatenation at the return, no assignment outside the
  voice step) and on a live agent with voice off (one typed exchange adds no `voice:`
  line to its transcript and no `voice tts` line to stderr).
- **SC-005**: The patcher applied to a previous-version source yields the new version and
  is byte-identical on a second pass; applied to pristine source it yields the new version
  directly; all seven patch groups remain present afterwards.
- **SC-006**: (a) Synthesis leg, live fault injection (invalid voice id): the
  acknowledgement and the stderr line name `step=synth`, the error class and the numeric
  status only, with 0 occurrences of raw error text, URLs, or credentials in the
  transcript and stderr. (b) Send leg — Telegram rejecting a bubble is not reproducible on
  demand: proven by the structural oracle that the step marker flips between synthesis and
  send, plus the error-class helper mapping a Telegram-style `error_code` to
  `transport/<code>` under bun.
- **SC-007**: With the provider available, 10 typed messages each containing a phrase from
  the fixed set yield 10 first-replies with a voice bubble (100%) on a live agent,
  regardless of how the agent composed each reply.
- **SC-008**: 10 typed messages with no request phrase (and no forced reply) yield 0 voice
  bubbles and 10 acknowledgements byte-identical to v0.23.0.
- **SC-009**: In end-to-end, a reply carrying the force-voice flag on a plain typed
  exchange yields a voice bubble 100% of the time; a reply carrying only a spoken
  rendition yields 0 bubbles.

## Assumptions

- **Fleet state**: every docker agent (donna, linus) runs the previous voice version;
  rodri-cenco-admin (still on 0.19.0) will reach the new version directly when upgraded.
  The in-place upgrade path is therefore the production path, not a corner case.
- **Outcome line format**: exact wording and field order are design (plan/contract), not
  spec content; the spec fixes the field whitelist and the presence/absence rule.
- **Nag threshold**: DECIDED (clarified 2026-09-13) — a fixed fraction of the
  spoken-length cap with no knob; a quarter of the cap is the working value and the plan
  fixes it. The stderr omission record is emitted regardless of threshold so the rate is
  measurable for any length.
- **Mode `auto` is extended, not replaced**: "voice answers voice" becomes "voice answers
  voice OR an explicit request OR a forced reply"; typed messages without either stay
  text-only. Caps, truncation of the fallback, TTS format, voice-origin expiry, STT/TTS
  models, and "text always accompanies voice" (032) all stand.
- **Explicit request phrase set**: fixed in the plugin and documented in the README;
  Spanish and English; imperative request forms; matched case- and accent-insensitively
  anywhere in the message; the plan fixes the exact list and its negative examples.
- **Persistent "audio mode" rejected** (clarified 2026-09-13): a runtime switch that
  outlives one reply would have to be written to `agent.yml` (Principle I) — a separate
  feature if ever wanted.
- **Docker-only active behaviour**: the whole change is in the image-baked plugin patcher,
  re-applied at every boot; end-to-end verification under `DOCKER_E2E=1` is required
  (precedent 028/031/032).
- **Version bump**: MINOR (0.23.0 → 0.24.0), precedent 028/031 — plugin behaviour change
  plus marker bump; CHANGELOG and the README's Telegram hooks section updated.
- **No new privileges, no image changes**: the container privilege model, Dockerfile,
  compose template, `agent.yml`, schema and wizard are untouched.
- **Out of scope**: real-time conversation / any channel outside Telegram (feature 034,
  separate spec); transcript echo (032 decision stands); changes to the inbound
  transcription path (the typed-message path IS touched, only to recognise the request
  phrases); group-chat voice behaviour; a persistent runtime voice mode.
