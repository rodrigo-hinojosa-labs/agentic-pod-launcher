# Implementation Plan: Round-trip voice over the Telegram channel (async voice notes)

**Branch**: `032-telegram-voice-roundtrip` | **Date**: 2026-09-06 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/032-telegram-voice-roundtrip/spec.md`

## Summary

Close the voice loop over the existing Telegram channel, asynchronously: a new
**"voice" patch group** in the image-baked plugin patcher
(`docker/scripts/apply_telegram_typing_patch.py`) transcribes inbound voice notes via
the ElevenLabs STT API before the message is announced to the agent (the transcript
becomes the message content; the existing `attachment_kind: 'voice'` meta is the
voice-origin signal), and extends the plugin's `reply` tool to synthesize a spoken
rendition (agent-provided `voice_text`, else a truncated fallback) and deliver it as a
native `sendVoice` bubble alongside the full text. Everything is declared in
`agent.yml` (`features.voice`, opt-in, disabled by default), the API key lives only in
`.env`, per-agent settings reach the plugin through the compose `environment:` block
(029 precedent), and every failure mode fails open to today's exact behaviour.

## Technical Context

**Language/Version**: bash 3.2+/5.x (launcher host code), Python 3 (image-baked patcher),
TypeScript-on-bun (the patched plugin hunks — upstream telegram plugin 0.0.7, grammY)

**Primary Dependencies**: ElevenLabs STT (`POST /v1/speech-to-text`, model `scribe_v2`)
and TTS (`POST /v1/text-to-speech/{voice_id}`, model `eleven_flash_v2_5`) — HTTPS via
bun's built-in `fetch`, no new packages; Telegram Bot API 10.3 `sendVoice`

**Storage**: none new — in-memory per-process voice-origin map only; no `.state/` schema
changes; no files persisted by the voice pipeline (audio buffers held in memory)

**Testing**: bats (host, hermetic — patcher hunks via `tests/apply-telegram-patches.bats`
pattern; config/render via `tests/askq-guard-config.bats` pattern); `DOCKER_E2E=1` gated
e2e (patcher is image-baked → REQUIRED per constitution gate)

**Target Platform**: docker mode (Alpine aarch64/x86_64 pods) is the active behaviour;
local (Remote Control) mode is declared-inert (no Telegram plugin in the relay)

**Project Type**: launcher feature — patcher group + `agent.yml` schema + render
touchpoints + wizard prompt

**Performance Goals**: STT adds ≤10 s before turn start for ≤60 s notes (SC-002; hard
client timeout on the STT call); TTS covered by the typing indicator during the reply

**Constraints**: fail-open everywhere (broken voice ⇒ v0.22.0 behaviour, never a broken
channel); the STT pipeline runs DETACHED from the sequential update loop (an in-handler
await would freeze the whole channel — research D9); DM-only authorization pre-check
before any paid API call; voice replies travel the `reply` tool path with the voice
block anchored downstream of the 028 marker-clear/offset-ack; no new container
privileges; no ffmpeg / no Dockerfile package change (format strategy avoids
transcoding — see research.md D4)

**Scale/Scope**: personal fleet (3 docker agents today); ~$0.03 per round trip; caps:
notes ≤ default 300 s / 20 MB (Telegram getFile hard cap), spoken rendition ≤ 1,200
chars fallback truncation

## Constitution Check

*Source: `.specify/memory/constitution.md` (v1.0.1). Each gate evaluated pre-Phase-0 and
re-checked post-design (Phase 1) — both passes recorded here.*

- [x] **I. Single Source of Truth** — PASS. `features.voice.*` lives in `agent.yml`
  (wizard heredoc + `has()`-guarded backfill, never `//`); per-agent values render into
  `docker-compose.yml` `environment:` via `{{FEATURES_VOICE_*}}` placeholders (029
  `MCP_TIMEOUT` precedent); nothing hand-edited; two consecutive `--regenerate` runs are
  byte-identical (SC-005 test).
- [x] **II. Least-Privilege (NON-NEGOTIABLE)** — PASS. No new capabilities, mounts,
  sockets, or privilege changes. The voice hunks use only the plugin's existing
  `bot.api` (adding `sendVoice`, same privilege class as the existing `sendMessage`/
  `sendPhoto`) plus outbound HTTPS `fetch` from the same process that already talks to
  `api.telegram.org`. The API key is read from `process.env`, never written to disk or
  logs.
- [x] **III. Test-First, Host-Runnable** — PASS. All patcher/config/render behaviour
  covered by host bats (patched output asserted textually, no bun/docker needed);
  `DOCKER_E2E=1` gated e2e for the image-baked path; shellcheck on any touched shell;
  tests written before hunks (tasks will order RED→GREEN). **Declared deviation
  (analyze D1)**: the DOCKER_E2E RUN itself is deploy-deferred (tasks T025 — no docker
  daemon in the dev environment), the same openly-recorded pattern as 016/028/031; the
  e2e file ships parse-clean and gated, and the deferral rides the v0.23.0 deploy.
- [x] **IV. Idempotent, Fail-Silent Lifecycle** — PASS. One new patch group with its own
  marker (`MARKER_VOICE`), applied at boot by the existing `apply_plugin_patches` flow;
  idempotent by marker; anchor drift ⇒ WARN + group-scoped no-op (plugin keeps working
  without voice); runtime failures inside the hunks are caught and degrade to text-only
  behaviour. Independent of the typing v1→v6 upgrade cascade.
- [x] **V. Workspace-Is-the-Agent** — PASS. No `.state/` layout changes; the plugin
  cache patch is re-applied on every boot exactly like the six existing groups (clone ⇒
  patched on next boot); the new secret lives in `.env` (already excluded from the
  config backup branch; included in identity's encrypted `.env.age` by existing design).
- [x] **VI. Reproducible, Pinned Dependencies** — PASS. Provider model ids
  (`scribe_v2`, `eleven_flash_v2_5`) are explicit constants in the patcher (single
  definition site each); no new toolchain, no new duplicate pins, no Dockerfile change.
  `VERSION` bumps MINOR (precedent 028/031) + `CHANGELOG.md` + README Telegram section.

**Post-design re-check (Phase 1)**: all six gates remain PASS; no Complexity Tracking
entries needed.

## Project Structure

### Documentation (this feature)

```text
specs/032-telegram-voice-roundtrip/
├── spec.md
├── checklists/requirements.md
├── plan.md              # This file
├── research.md          # Phase 0 — decisions D1-D9 + empirical gates E1-E3
├── data-model.md        # Phase 1 — config block, env contract, runtime entities
├── quickstart.md        # Phase 1 — enablement + live validation runbook
├── contracts/
│   ├── voice-inbound-stt.md      # C1-C5c: voice handler hunks (V1/V5/V6) behaviour
│   ├── voice-outbound-tts.md     # C6-C10: reply tool voice extension (V2/V3/V4)
│   └── voice-config-and-render.md # C11-C15: agent.yml/schema/render/wizard/backfill
└── tasks.md             # Phase 2 (/speckit-tasks — not created here)
```

### Source Code (repository root)

```text
docker/scripts/apply_telegram_typing_patch.py   # +7th group: MARKER_VOICE (prefixed),
                                                # VOICE_* constants, apply_voice() with
                                                # hunks V1-V6, main() wiring
setup.sh                                        # features.voice heredoc + wizard prompts
                                                # (ask_yn/ask primitives, docker-mode
                                                # gated), backfill in regenerate(),
                                                # env sanitizers incl. STT lang
scripts/lib/schema.sh                           # features.voice.enabled in _SCHEMA_BOOLEANS
modules/docker-compose.yml.tpl                  # environment: TELEGRAM_VOICE_* lines
                                                # (unconditional, MCP_TIMEOUT precedent)
modules/env-example.tpl                         # ELEVENLABS_API_KEY + tuning knobs
                                                # documented (names only; single tested
                                                # vehicle for the declined-wizard case)
tests/apply-telegram-patches.bats               # fixture heredoc EXTENDED with V1-V6
                                                # anchors (own task; 43 stay green),
                                                # +~20 voice tests (43 → ~63; tasks.md
                                                # T004/T009 counts are authoritative)
tests/voice-config.bats                         # NEW: backfill/render/sanitizer tests
tests/local-render.bats                         # +1: FR-011 local runtime-artifact
                                                # inertness oracle (029 precedent)
tests/docker-render.bats                        # +compose environment assertions
tests/fixtures/sample-agent.yml                 # +features.voice block
tests/fixtures/sample-agent-with-vault.yml      # +features.voice block
tests/docker-e2e-voice.bats                     # NEW: DOCKER_E2E-gated (~4: build, baked
                                                # hunks, compose env delivery, no-key
                                                # fault injection)
CHANGELOG.md / README.md / VERSION              # docs + MINOR bump 0.22.0 → 0.23.0
```

**Structure Decision**: launcher-repo single project; the runtime behaviour ships as
patcher hunks (image-baked), the declarative surface as `setup.sh`/schema/template
touchpoints — the exact split 028/031 used, plus 029's compose-environment delivery for
per-agent values.

## Design outline (what each contract pins down)

1. **Inbound (contracts/voice-inbound-stt.md)** — the voice group REPLACES the body of
   the upstream `bot.on('message:voice')` handler. New flow (remediated 2026-09-06):
   enabled/key check → **DM-only read-only pre-check** (`chat.type==='private'` +
   `dmPolicy!=='disabled'` + sender in `allowFrom`, via `loadAccess()` — never
   `gate()`, whose pairing path has side effects; transcription is DM-only in v1) →
   caps (absent-metadata-safe; real size cap post-download) → fire ONE
   `sendChatAction('typing')` → **detached pipeline** (the handler never awaits STT —
   grammY processes updates sequentially, so an in-handler await would freeze the whole
   channel): `getFile` download → STT call (multipart, `scribe_v2`, sanitized language
   hint, single 30 s AbortController) → on success call
   `handleInbound(ctx, transcript, undefined, {kind:'voice', ...})` and record
   voice-origin; on ANY failure call `handleInbound` with today's exact placeholder
   arguments. `handleInbound` itself is NOT modified; the agent's voice-origin signal
   is the existing `attachment_kind: 'voice'` meta + non-placeholder content. A V6
   micro-hunk clears the chat's voice-origin when a typed message arrives.
2. **Outbound (contracts/voice-outbound-tts.md)** — a hunk in `case 'reply'` anchored
   AFTER the 028 marker-clear / offset-ack site (immediately before the case's return),
   so text + files + marker/ack timing stay byte-identical to today: if active and the
   mode says speak (`always`, or `auto` with a fresh voice-origin flag —
   **consume-on-read**, deleted before synthesis, never restored on failure),
   synthesize `args.voice_text ?? truncate(text, cap)` under a single 30 s budget and
   `sendVoice` it; failures log one stderr line and never fail the tool call. The reply
   tool's inputSchema gains optional `voice_text`; the channel instructions array gains
   one line steering the agent to provide it when answering voice. Voice-origin map is
   in-memory (TTL 5 min; restart ⇒ one text-only reply, fail-open).
3. **Format strategy (research D4)** — request `opus_48000_64`; sniff the response's
   first bytes for `OggS`: container confirmed ⇒ send as `.ogg`; otherwise fall back to
   `mp3_44100_128` (Bot API 10.3 accepts MP3 for voice bubbles). No ffmpeg, no image
   change; the empirical unknown becomes a runtime branch instead of a blocker.
4. **Config & render (contracts/voice-config-and-render.md)** — `features.voice.
   {enabled,reply_mode,voice_id,provider}` in `agent.yml`; render-time sanitization
   (029 `mcp_timeout_effective` mold); compose `environment:` carries
   `TELEGRAM_VOICE_ENABLED`, `TELEGRAM_VOICE_REPLY_MODE`, `TELEGRAM_VOICE_ID`,
   `TELEGRAM_VOICE_PROVIDER` and `TELEGRAM_VOICE_STT_LANG` (derived from
   `user.language`, sanitized: only `es|en` pass, `mixed`/other → empty = autodetect,
   delivered via the DEDICATED derived placeholder `{{VOICE_STT_LANG}}` —
   `USER_LANGUAGE` is untouched because `claude-md.tpl` consumes it; the new external
   placeholder joins schema.bats `known_external`); `.env` carries
   `ELEVENLABS_API_KEY` (+ optional tuning overrides
   `TELEGRAM_VOICE_MAX_NOTE_SECONDS`, `TELEGRAM_VOICE_SPOKEN_CHAR_CAP`, same channel as
   `TELEGRAM_TYPING_MAX_MS`). Wizard offers the block on docker-mode scaffolds only
   (telegram is a mandatory default plugin — deployment mode is the discriminator),
   default off; backfill writes the disabled block.

## Phase 0 gates resolved in research.md

- D1-D9 design decisions (anchors, DM-only gate-before-pay, origin signal, format
  strategy, origin persistence + V6 clear, config delivery + sanitizers, model pins,
  redacting observability, detached inbound pipeline).
- **Adversarial design review (2026-09-06, 4 independent reviewers against the real
  plugin/patcher/launcher code): 4 HIGH + 12 MEDIUM findings — ALL remediated across
  spec/plan/research/data-model/contracts before tasks.** Highest-impact fixes: the
  detached pipeline (grammY processes updates sequentially — an in-handler STT await
  would have frozen the whole channel), the `user.language: mixed` STT-lang sanitizer
  (feature would have been dead-on-arrival on `mixed` agents), the V2 anchor moved
  downstream of the 028 marker-clear/offset-ack (a crash during synthesis could have
  caused Telegram redelivery + duplicate turns), and the test-fixture anchor extension
  (planned tests would have WARN-skipped silently against the current fixture).
- Empirical gate E1 (opus container) — neutralized by design (runtime sniff + MP3
  fallback); a cheap confirmation test remains as an implementation task with the
  operator's key.
- Empirical gate E2 (Chilean-Spanish STT A/B) — deferred to the deploy quickstart,
  non-blocking (provider field allows swap).
- Upstream re-check (plugin version / issue #989) — implementation-time task.

## Complexity Tracking

*No constitution violations — table intentionally empty.*
