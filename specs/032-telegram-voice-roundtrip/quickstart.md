# Quickstart: enabling and validating round-trip voice (032)

## 1. Enable on an existing agent (post-upgrade to v0.23.0)

```bash
cd <workspace>
# 1. Declare it (agent.yml is the source of truth)
yq -i '.features.voice.enabled = true' agent.yml
yq -i '.features.voice.voice_id = "<elevenlabs-voice-id>"' agent.yml   # optional
# 2. Provide the key (never in agent.yml)
#    Add to .env:  ELEVENLABS_API_KEY=<value>
# 3. Re-render + restart (docker mode)
./setup.sh --regenerate
docker compose build && ./scripts/agentctl up   # respect the 409 cadence: stop, wait ~150s, up
```

Optional `.env` tuning: `TELEGRAM_VOICE_MAX_NOTE_SECONDS` (default 300),
`TELEGRAM_VOICE_SPOKEN_CHAR_CAP` (default 1200).

## 2. Smoke test (SC-001, SC-002, SC-003, SC-006)

Run this in the paired **DM** — voice transcription is DM-only in v1; a group voice
note takes the placeholder path by design.

1. Send a voice note: "resume en una frase el estado del heartbeat".
2. Expect: agent acts on the instruction (proof STT worked — no typing needed), reply
   arrives as text + a playable voice bubble; **no transcript echo message appears in
   the chat** (FR-001).
3. `./scripts/agentctl logs --stderr` shows `voice stt ok ...` and `voice tts ok ...
   fmt=<ogg|mp3>` lines.
4. **SC-002 timing**: compare the note's send time vs the `voice stt ok ... ms=` line
   (≤10 s for a ≤60 s note, target ~3 s); during a LONG note, send a text message and
   verify it is processed while the transcription is still in flight (non-blocking).
5. **SC-003 render**: the bubble plays as a native voice note (waveform, speed
   controls) on at least two official clients (phone + desktop) — regardless of
   `fmt=ogg|mp3`.
6. **SC-006 cost**: after the round trip, check the provider's usage dashboard — the
   exchange should cost ≤ $0.05 (analytic estimate ~$0.03).

## 3. Fault-injection validation (SC-004, SC-007)

| Check | How | Expect |
|---|---|---|
| No key | remove `ELEVENLABS_API_KEY`, restart | boot WARN once; voice note ⇒ today's placeholder; text channel intact |
| Provider down | temporarily set an invalid key | `voice stt fail: ... status=401` line; placeholder path; reply text-only |
| Over-cap | send a >5 min note | `voice stt skip: over-cap`; placeholder annotated |
| Disabled | `enabled: false` + regenerate + restart | zero voice behaviour, zero per-message log noise (one module-scope config line at boot only) |
| Group chat | send a voice note in a group the agent is in | placeholder path, NO STT/API spend (DM-only by design, v1) |

## 4. E1 confirmation (first enablement, ~$0.001)

The first `voice tts ok` line's `fmt=` value answers the opus-container unknown:
`fmt=ogg` ⇒ ElevenLabs opus is Ogg-contained (primary path); `fmt=mp3` ⇒ the sniff
fell back (also fine). In BOTH cases run the §2 step-5 multi-client render check
(SC-003). Record the outcome in the deploy log.

## 5. E2 accent A/B (recommended, non-blocking)

Transcribe 5-10 real Chilean-Spanish notes; if Scribe v2 misses domain words, try the
`keyterms` option (provider helper) before considering the Groq alternative.

## 6. Rollback

`yq -i '.features.voice.enabled = false' agent.yml && ./setup.sh --regenerate` +
restart. The patch group stays applied but inert; removing the key alone also
deactivates (with a boot WARN).
