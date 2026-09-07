# Data Model: 032-telegram-voice-roundtrip

## 1. `features.voice` block (agent.yml — single source of truth)

```yaml
features:
  voice:
    enabled: false        # boolean (schema-validated). Opt-in — backfill & wizard default.
    reply_mode: auto      # auto | always | never (invalid → auto at render)
    voice_id: ""          # ElevenLabs voice id; empty → patcher's default stock voice
    provider: elevenlabs  # only accepted value in v1; exists for future swap
```

- **Backfill** (pre-032 workspace, on `--regenerate`): `has("voice")`-guarded — absent ⇒
  write the block above verbatim (disabled); present ⇒ untouched (operator wins, even
  `enabled: false` + edits). NEVER `//` defaults (would clobber explicit falsy values).
- **Wizard**: offered only on **docker-mode scaffolds** (`deployment.mode == docker` —
  the telegram plugin is a mandatory default in every scaffold, so plugin presence
  discriminates nothing; contract C13, analyze remediation F2); default answer "no"
  keeps `enabled: false`; answering "yes" sets `enabled: true` and prompts for
  `voice_id` (optional, blank = default voice). Either way the block is always written
  (schema completeness — fixtures/schema.bats assert it).
- **Schema**: `features.voice.enabled` joins `_SCHEMA_BOOLEANS` in
  `scripts/lib/schema.sh`.

## 2. Render outputs (derived — must survive `--regenerate` byte-identically)

`modules/docker-compose.yml.tpl` `environment:` block gains (docker mode only):

```yaml
      TELEGRAM_VOICE_ENABLED: "{{FEATURES_VOICE_ENABLED}}"
      TELEGRAM_VOICE_REPLY_MODE: "{{FEATURES_VOICE_REPLY_MODE}}"
      TELEGRAM_VOICE_ID: "{{FEATURES_VOICE_VOICE_ID}}"
      TELEGRAM_VOICE_PROVIDER: "{{FEATURES_VOICE_PROVIDER}}"
      TELEGRAM_VOICE_STT_LANG: "{{VOICE_STT_LANG}}"
```

Values are sanitized at render time in `setup.sh` (re-export after
`render_load_context`, 029 precedent): `reply_mode` ∉ {auto,always,never} → `auto`;
`provider` ≠ `elevenlabs` → `elevenlabs`; `voice_id` trimmed; **STT lang: only
`es|en` pass through — `mixed` (wizard-legal) or anything else renders empty**
(empty ⇒ the STT helper omits `language_code`, i.e. autodetect). The STT lang travels
through a **dedicated derived placeholder `{{VOICE_STT_LANG}}`** exported by the
sanitizer — `USER_LANGUAGE` itself is NEVER re-exported/sanitized, because
`modules/claude-md.tpl` also consumes it and a `mixed` agent's CLAUDE.md must keep
saying `mixed` (analyze remediation F1). `{{VOICE_STT_LANG}}` joins `known_external`
in `tests/schema.bats` (documented wizard-touchpoint trap). The five lines render
UNCONDITIONALLY (MCP_TIMEOUT precedent — no template conditional exists and no flattened
var expresses plugin presence); a voice-disabled or non-telegram agent carries inert
env. `.env` example template documents `ELEVENLABS_API_KEY=` (name only) and the two
optional tuning knobs; those documentation lines render in both modes (local RUNTIME
artifacts stay untouched — see contract C12).

## 3. Runtime environment contract (what the patched plugin reads)

| Variable | Source | Default when absent/invalid | Meaning |
|---|---|---|---|
| `TELEGRAM_VOICE_ENABLED` | compose environment (agent.yml) | `false` | master switch |
| `ELEVENLABS_API_KEY` | `.env` via env_file | — (feature inert + one boot WARN) | auth for STT+TTS |
| `TELEGRAM_VOICE_REPLY_MODE` | compose environment | `auto` | auto/always/never |
| `TELEGRAM_VOICE_ID` | compose environment | patcher constant (stock voice) | TTS voice |
| `TELEGRAM_VOICE_PROVIDER` | compose environment | `elevenlabs` | provider selector |
| `TELEGRAM_VOICE_STT_LANG` | compose environment (user.language) | unset → autodetect | STT language hint |
| `TELEGRAM_VOICE_MAX_NOTE_SECONDS` | `.env` (optional) | `300` | transcription cap |
| `TELEGRAM_VOICE_SPOKEN_CHAR_CAP` | `.env` (optional) | `1200` | truncation floor for TTS |

Effective activation = `ENABLED=true` AND key present. Anything else ⇒ the hunks are
pass-through (today's behaviour) with a single boot-time stderr line naming why.

## 4. Runtime entities (in-process, no persistence)

- **VoiceOrigin map**: `Map<chat_id, {ts}>` — set on successful transcription;
  **consume-on-read**: the reply hunk deletes the entry when it reads it, BEFORE
  synthesis (a TTS failure does NOT restore it — that exchange stays text-only, one
  paid attempt max); cleared by V6 when a typed message arrives from the same chat;
  TTL 5 min as defense for inbound kinds V6 doesn't cover. Lost on restart ⇒ one
  text-only reply (accepted degradation, research D5).
- **TTS format cache**: per-process tri-state `unknown | ogg-ok | mp3-fallback` — set by
  the first synthesis's `OggS` sniff (research D4).
- **Audio buffers**: in-memory only; never written under `/workspace` or `.state/`.

## 5. Patcher additions (image-baked)

- `MARKER_VOICE = "agentic-pod-launcher: telegram voice roundtrip patch v1"` — one
  marker for the whole group (the `agentic-pod-launcher: ` prefix is the namespace
  convention every existing marker carries and the tests grep for).
- Constants: `VOICE_STT_MODEL = "scribe_v2"`, `VOICE_TTS_MODEL = "eleven_flash_v2_5"`,
  default stock voice id, API base URL.
- `apply_voice(src) -> (new_src, applied)` — six hunks, all-or-nothing with
  group-scoped rollback on any anchor miss (fail-silent WARN):
  V1 `message:voice` handler body replacement (cheap checks + typing action +
     DETACHED download/STT pipeline — research D9; the handler never awaits STT)
  V2 `case 'reply'` voice-send block — anchored AFTER the 028 marker-clear / offset-ack
     site (immediately before the `return { content:` of the reply case), so the
     marker/ack timing stays byte-identical to today; the voice bubble's message_id is
     NOT counted in the tool's result string (best-effort extra)
  V3 reply tool inputSchema `voice_text` property
  V4 instructions-array line (voice convention for the agent)
  V5 module-level helpers block (config read + ONE-TIME config/WARN line emitted at
     MODULE scope — before any token/network use, so fault-injection e2e can observe
     it; STT/TTS fetch helpers; origin map; sniff cache; redacting stderr helpers)
  V6 `message:text` handler wrap: clears VoiceOrigin[chat] (typed message ⇒ the
     exchange is text again), then falls through to the upstream body
- `main()` wiring: `apply_voice` runs independently of the typing cascade; bookkeeping
  mirrors the six existing groups (marker check ⇒ skip as already-applied).

## 6. Reply tool contract change (agent-visible)

`reply` inputSchema gains:

```json
"voice_text": {
  "type": "string",
  "description": "Optional spoken-style rendition of this reply, used to synthesize the voice bubble when the exchange is voice-originated. Plain speakable prose — no markdown, no code. When omitted, a truncated version of `text` is spoken."
}
```

Instructions line (V4) tells the agent: messages with `attachment_kind="voice"` carry
their transcription as the message text; when replying to them, provide `voice_text`.

## 7. State-transition summary (inbound)

```
voice note arrives (handler returns immediately — pipeline is DETACHED, D9)
  → not a private chat / dmPolicy disabled / not allowlisted ──→ placeholder path
  → disabled / no key / over caps ────────────────────────────→ placeholder path + 1 stderr line
  → typing action fired; detached: download or STT error/timeout → placeholder path + 1 stderr line
  → transcript ok → handleInbound(transcript, voice meta) + VoiceOrigin[chat] = now

typed text arrives (V6) → VoiceOrigin[chat] cleared, upstream handler unchanged
```

(outbound — inside `case 'reply'`; V2 sits AFTER the marker-clear/ack site)

```
reply tool fires (chat, text, voice_text?)
  → text chunks sent; files sent; 028 marker cleared + offset acked (upstream + existing
    groups, byte-identical timing to today)
  → inactive, or mode=never, or (mode=auto AND no fresh VoiceOrigin) ──→ return (text only)
  → VoiceOrigin CONSUMED NOW (read+delete, before synthesis)
  → synthesize voice_text ?? truncate(text, cap)   [single 30 s budget, both formats]
      → TTS/send error ──→ 1 stderr line, return normal result (flag NOT restored;
                            exchange stays text-only)
      → sendVoice ok ───→ voice bubble delivered (message_id not in result count)
```
