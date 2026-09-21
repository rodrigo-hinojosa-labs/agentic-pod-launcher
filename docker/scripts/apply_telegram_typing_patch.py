#!/usr/bin/env python3
"""
Patch the upstream claude-plugins-official/telegram `server.ts` with five
independent fixes that improve Telegram chat reliability + observability:

1. Typing refresh patch (v3) — refreshes the "typing..." action every 4s
   while Claude is processing, instead of upstream's single-shot
   sendChatAction that auto-expires after ~5s. The action persists until
   `case 'reply'` fires (signalling the session finished processing) or the
   bun process exits — there is no fixed time cap. v3 adds observability:
   the setInterval logs a tick to stderr every 5 invocations (~20s), and
   sendChatAction errors that v1/v2 silently swallowed are now surfaced
   to /workspace/scripts/heartbeat/logs/telegram-mcp-stderr.log. Includes
   in-place upgraders for files at v1 (cap removal + bump to v2) and at v2
   (helper rewrite + bump to v3). The cascade runs on every boot, so any
   already-patched server.ts ratchets up to v3 transparently.

2. Offset persistence patch (v1) — persists the Telegram update_id offset
   to ~/.claude/channels/telegram/last-offset.json on each successful
   reply (ack-on-reply, not ack-on-inbound) and replays from disk on
   startup. Makes message loss impossible regardless of how often
   `bun server.ts` crashes: the next getUpdates call uses the persisted
   offset, so any updates Telegram still has in its 24h buffer that
   weren't yet replied are re-delivered. Four hunks: helpers (B1),
   replay-before-bot.start (B2), mark-pending in handleInbound (B3),
   ack-pending in case 'reply' (B4).

3. Stderr-capture patch (v1) — tees process.stderr to
   /workspace/scripts/heartbeat/logs/telegram-mcp-stderr.log AND wires
   uncaught/unhandled handlers that append the trace there. Without this,
   bun crashes leave no forensic evidence (the stderr the existing
   handlers write to is consumed by claude's MCP transport and dropped).

4. Primary lock patch (v1) — turns upstream's "any new instance kills any
   stale PID" into "primary-secondary with mtime heartbeat". Without this,
   any time claude spawns a sub-claude that loads the telegram plugin
   (claude-mem worker, Task subagent, etc.), the sub-claude's bun runs
   the stale-poller block at startup, sees the live primary's PID,
   SIGTERMs it, takes over polling for a few seconds, then dies when the
   sub-claude exits — leaving the main session's MCP transport pointing
   at a dead bun and Telegram messages effectively undeliverable until
   the watchdog respawn cycle catches up. Two hunks: a guard before the
   SIGTERM that exits cleanly if PID_FILE was modified within 30s (live
   primary), and a setInterval that refreshes PID_FILE every 5s so
   secondaries see a recent mtime.

5. Pending-reply marker patch (v1, feature 028) — writes a tiny
   pending-reply.json on inbound and deletes it on the reply tool, as the
   channel-origin + unreplied signal the reply-guard Stop hook reads at
   turn-end. The typing patch also ratchets v4 → v5 here, rewording the
   timeout warning so it no longer asserts OAuth as the cause.

6. AskUserQuestion guard give-up delivery patch (v1, feature 031) — checks
   the askq-guard-giveup.json marker (written by the PreToolUse guard hook
   when it stops redirecting a channel turn away from the console-only
   interactive prompt) on every typing keep-alive tick AND at the start of
   the next inbound turn's keep-alive, delivers exactly one give-up chat
   message via the existing bot.api.sendMessage path, and deletes the
   marker (delete-on-send makes the two triggers mutually exclusive — never
   double-sent). The hook itself never sends to the channel (Principle II);
   only this plugin-side check does, deterministically, independent of
   whether the model complies. The typing patch also ratchets v5 → v6 here,
   naming "blocked in an interactive prompt the channel can't answer" among
   the timeout warning's possible causes.

7. Telegram voice roundtrip patch (v3 — 032 v1, 033 v2, 034 v3) — closes the voice loop
   asynchronously over the existing channel. Six hunks under one marker:
   V1 replaces the `bot.on('message:voice')` handler body with a DM-only
   read-only pre-check, absent-metadata-safe caps, and a DETACHED
   download+STT pipeline (ElevenLabs Scribe v2) — the handler never awaits
   the network work because grammY processes updates sequentially and an
   in-handler await would freeze the whole channel; on any failure it falls
   back to today's exact placeholder. V2 extends `case 'reply'` with a
   voice-synthesis block anchored AFTER the 028 marker-clear/offset-ack site
   (immediately before the case's return), so a synthesis crash can't strand
   the marker or the offset ack; failures never throw, they just skip the
   voice bubble. V3/V4 add the optional `voice_text` reply-tool property and
   an instructions-array line steering the agent to provide it for
   voice-originated exchanges. V5 adds the module-scope helpers (config read
   + a ONE-TIME boot line, redacting stderr helpers, the in-memory
   voice-origin map, the TTS format sniff cache). V6 wraps
   `bot.on('message:text')` to clear the voice-origin flag when the operator
   types instead of speaking. Everything fails open to v0.22.0 behaviour.
   v2 (033) feeds the voice outcome back into the reply acknowledgement and
   honours explicit audio requests; v3 (034) makes the spoken rendition a
   summarized narration: spoken-safe normalization (markdown/emoji/URL
   removal, currency/percent symbols named), language passed to the TTS,
   a configured closing phrase appended exactly once, and a sentence-boundary
   cut at the spoken cap. In-place upgraders cascade v1 → v2 → v3 on every
   boot against the frozen `_V1` / `_V2` twins of each constant.

Each patch is independently idempotent (own marker comment) and fail-silent
on anchor drift (logs WARN to stderr, skips THAT patch only, leaves the
others free to apply). A single run applies whichever patches haven't yet
been applied; repeated runs are no-ops if all markers are present.

Usage:
    apply_telegram_typing_patch.py /path/to/server.ts
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

MARKER_TYPING = "agentic-pod-launcher: typing refresh patch v6"
MARKER_TYPING_V5 = "agentic-pod-launcher: typing refresh patch v5"
MARKER_TYPING_V4 = "agentic-pod-launcher: typing refresh patch v4"
MARKER_TYPING_V3 = "agentic-pod-launcher: typing refresh patch v3"
MARKER_TYPING_V2 = "agentic-pod-launcher: typing refresh patch v2"
MARKER_TYPING_V1 = "agentic-pod-launcher: typing refresh patch v1"
MARKER_OFFSET = "agentic-pod-launcher: offset persistence patch v1"
MARKER_STDERR = "agentic-pod-launcher: stderr-capture patch v1"
MARKER_PRIMARY = "agentic-pod-launcher: primary lock patch v1"
MARKER_PENDING = "agentic-pod-launcher: pending-reply marker patch v1"
MARKER_ASKQ_GIVEUP = "agentic-pod-launcher: askq-guard give-up delivery patch v1"
MARKER_VOICE_V1 = "agentic-pod-launcher: telegram voice roundtrip patch v1"
MARKER_VOICE_V2 = "agentic-pod-launcher: telegram voice roundtrip patch v2"
MARKER_VOICE = "agentic-pod-launcher: telegram voice roundtrip patch v3"

# The seven patch groups at their CURRENT version — main() counts these on the
# no-change path so the boot log says whether the file is fully patched or
# some group's anchors were not found (034).
ALL_MARKERS = (
    MARKER_TYPING,
    MARKER_OFFSET,
    MARKER_STDERR,
    MARKER_PRIMARY,
    MARKER_PENDING,
    MARKER_ASKQ_GIVEUP,
    MARKER_VOICE,
)

# V3 helpers — used by the v2→v3 upgrade ONLY. Fresh installs and v3→v4
# upgrades use TYPING_HELPERS (v4 — anti-zombie). Without this separation,
# v2→v3 would jump straight to v4 and the v3→v4 step would no-op,
# mis-stamping the upgrade history.
TYPING_HELPERS_V3 = (
    "\n// " + MARKER_TYPING_V3 + "\n"
    "const _typingIntervals = new Map<string | number, ReturnType<typeof setInterval>>()\n"
    "const _typingTickCounts = new Map<string | number, number>()\n"
    "const _TYPING_REFRESH_MS = 4000\n"
    "function _typingKeepAlive(chat_id: string | number): void {\n"
    "  _typingStop(chat_id)\n"
    "  _typingTickCounts.set(chat_id, 0)\n"
    "  const send = () => {\n"
    "    const tick = (_typingTickCounts.get(chat_id) ?? 0) + 1\n"
    "    _typingTickCounts.set(chat_id, tick)\n"
    "    bot.api.sendChatAction(chat_id, 'typing')\n"
    "      .then(() => {\n"
    "        if (tick === 1 || tick % 5 === 0) {\n"
    "          process.stderr.write(`telegram channel: typing tick ${tick} for chat ${chat_id}\\n`)\n"
    "        }\n"
    "      })\n"
    "      .catch((err: any) => {\n"
    "        const msg = err && (err.message || err.description || String(err))\n"
    "        process.stderr.write(`telegram channel: sendChatAction failed for chat ${chat_id} tick ${tick}: ${msg}\\n`)\n"
    "      })\n"
    "  }\n"
    "  send()\n"
    "  const timer = setInterval(send, _TYPING_REFRESH_MS)\n"
    "  _typingIntervals.set(chat_id, timer)\n"
    "}\n"
    "function _typingStop(chat_id: string | number): void {\n"
    "  const t = _typingIntervals.get(chat_id)\n"
    "  if (t) { clearInterval(t); _typingIntervals.delete(chat_id) }\n"
    "  _typingTickCounts.delete(chat_id)\n"
    "}\n"
)

# 028 (US2): the typing-timeout warning line. v4 asserted OAuth as the likely
# cause; v5 states the real uncertainty (a long turn still in progress, an answer
# produced WITHOUT calling the reply tool, or an expired login) so the operator is
# not sent down the wrong diagnostic path. _V4_WARNMSG must match the v4 source
# byte-for-byte so the v4→v5 upgrade and the TYPING_HELPERS_V4 derivation can swap it.
_V4_WARNMSG = (
    "      const warnMsg = `⚠️ Tardé más de ${minutes} min en responder. "
    "Es probable que el OAuth de Claude haya expirado o haya un error de conectividad. "
    "Revisa: agentctl doctor.`\n"
)
_V5_WARNMSG = (
    "      const warnMsg = `⚠️ Llevo más de ${minutes} min sin entregar la respuesta "
    "a este chat. Puede deberse a: una respuesta larga aún en curso, a que respondí "
    "sin usar la herramienta de envío, o a que el login de Claude haya expirado. "
    "Revisa: agentctl doctor.`\n"
)
# 031 (US2): v6 adds one more possible cause — a turn blocked in the console-only
# AskUserQuestion prompt the channel can't answer (the failure mode 031's
# PreToolUse guard intercepts; this warning still fires in the degraded path where
# the guard is absent/disabled/its anchors drifted). Still no single definite cause.
_V6_WARNMSG = (
    "      const warnMsg = `⚠️ Llevo más de ${minutes} min sin entregar la respuesta "
    "a este chat. Puede deberse a: una respuesta larga aún en curso, a que respondí "
    "sin usar la herramienta de envío, a que el login de Claude haya expirado, o a que "
    "la sesión quedó bloqueada en un menú interactivo que el canal no puede responder. "
    "Revisa: agentctl doctor.`\n"
)

TYPING_HELPERS = (
    "\n// " + MARKER_TYPING + "\n"
    "const _typingIntervals = new Map<string | number, ReturnType<typeof setInterval>>()\n"
    "const _typingTickCounts = new Map<string | number, number>()\n"
    "const _typingStartedAt = new Map<string | number, number>()\n"
    "const _TYPING_REFRESH_MS = 4000\n"
    "// v4: hard cap on typing duration. After _TYPING_MAX_DURATION_MS without\n"
    "// case 'reply' firing, abort the setInterval, send a user-facing message\n"
    "// to the chat, and log to stderr. Default 5 min; override via env var.\n"
    "// This prevents the \"zombie typing\" UX seen when claude is blocked on\n"
    "// /login (OAuth expired) — without v4 the user sees the bot \"thinking\"\n"
    "// for hours while the agent is dead.\n"
    "const _TYPING_MAX_DURATION_MS = (() => {\n"
    "  const raw = process.env.TELEGRAM_TYPING_MAX_MS\n"
    "  const n = raw ? parseInt(raw, 10) : NaN\n"
    "  return Number.isFinite(n) && n > 0 ? n : 300000\n"
    "})()\n"
    "function _typingKeepAlive(chat_id: string | number): void {\n"
    "  _typingStop(chat_id)\n"
    "  _typingTickCounts.set(chat_id, 0)\n"
    "  _typingStartedAt.set(chat_id, Date.now())\n"
    "  const send = () => {\n"
    "    const tick = (_typingTickCounts.get(chat_id) ?? 0) + 1\n"
    "    _typingTickCounts.set(chat_id, tick)\n"
    "    const started = _typingStartedAt.get(chat_id) ?? Date.now()\n"
    "    const elapsed = Date.now() - started\n"
    "    if (elapsed > _TYPING_MAX_DURATION_MS) {\n"
    "      // Abort: stop typing, notify the user, log forensics. The\n"
    "      // typical cause is OAuth expired (claude blocked on /login)\n"
    "      // or a stuck MCP — both require operator intervention. v3\n"
    "      // would have left the typing tick spinning indefinitely.\n"
    "      _typingStop(chat_id)\n"
    "      const minutes = Math.round(elapsed / 60000)\n"
    + _V6_WARNMSG +
    "      bot.api.sendMessage(chat_id, warnMsg)\n"
    "        .catch((err: any) => {\n"
    "          const msg = err && (err.message || err.description || String(err))\n"
    "          process.stderr.write(`telegram channel: timeout-warn sendMessage failed for chat ${chat_id}: ${msg}\\n`)\n"
    "        })\n"
    "      process.stderr.write(`telegram channel: typing aborted after ${minutes}m (${tick} ticks) for chat ${chat_id}\\n`)\n"
    "      return\n"
    "    }\n"
    "    bot.api.sendChatAction(chat_id, 'typing')\n"
    "      .then(() => {\n"
    "        // Beat every 5 ticks (~20s) so the stderr log shows the\n"
    "        // setInterval is alive without saturating it on short replies.\n"
    "        if (tick === 1 || tick % 5 === 0) {\n"
    "          process.stderr.write(`telegram channel: typing tick ${tick} for chat ${chat_id}\\n`)\n"
    "        }\n"
    "      })\n"
    "      .catch((err: any) => {\n"
    "        // v1/v2 silently swallowed errors here. v3+ surfaces them so\n"
    "        // rate limits, network failures, or token issues become\n"
    "        // visible in /workspace/scripts/heartbeat/logs/telegram-mcp-stderr.log.\n"
    "        const msg = err && (err.message || err.description || String(err))\n"
    "        process.stderr.write(`telegram channel: sendChatAction failed for chat ${chat_id} tick ${tick}: ${msg}\\n`)\n"
    "      })\n"
    "  }\n"
    "  send()\n"
    "  const timer = setInterval(send, _TYPING_REFRESH_MS)\n"
    "  _typingIntervals.set(chat_id, timer)\n"
    "}\n"
    "function _typingStop(chat_id: string | number): void {\n"
    "  const t = _typingIntervals.get(chat_id)\n"
    "  if (t) { clearInterval(t); _typingIntervals.delete(chat_id) }\n"
    "  _typingTickCounts.delete(chat_id)\n"
    "  _typingStartedAt.delete(chat_id)\n"
    "}\n"
)

# 028 (US2): the v4 helper block = the latest block with the marker + message
# reverted to v4. Injected by the v3→v4 upgrade ONLY, so a v3 file lands at v4
# (then v4→v5→v6 swap the message twice more), preserving the no-mis-stamp
# upgrade history (mirrors TYPING_HELPERS_V3). MARKER_TYPING/_V6_WARNMSG are the
# CURRENT latest (v6) — this derivation always reverts from whatever "latest" is.
TYPING_HELPERS_V4 = TYPING_HELPERS.replace(
    MARKER_TYPING, MARKER_TYPING_V4
).replace(_V6_WARNMSG, _V4_WARNMSG)

OFFSET_HELPERS = (
    "\n// " + MARKER_OFFSET + "\n"
    "const _OFFSET_FILE = '/home/agent/.claude/channels/telegram/last-offset.json'\n"
    "const _pendingUpdates = new Map<string | number, number>()\n"
    "function _loadOffset(): number {\n"
    "  try {\n"
    "    const fs = require('node:fs')\n"
    "    if (!fs.existsSync(_OFFSET_FILE)) return 0\n"
    "    const j = JSON.parse(fs.readFileSync(_OFFSET_FILE, 'utf8'))\n"
    "    return typeof j.offset === 'number' && j.offset > 0 ? j.offset : 0\n"
    "  } catch { return 0 }\n"
    "}\n"
    "function _saveOffset(updateId: number): void {\n"
    "  try {\n"
    "    const fs = require('node:fs')\n"
    "    const path = require('node:path')\n"
    "    fs.mkdirSync(path.dirname(_OFFSET_FILE), { recursive: true })\n"
    "    fs.writeFileSync(_OFFSET_FILE, JSON.stringify({ offset: updateId + 1, ts: Date.now() }))\n"
    "  } catch {}\n"
    "}\n"
    "function _markPending(chatId: string | number, updateId: number): void {\n"
    "  // Latest-wins per chat. Bursts of msgs collapse to the newest update_id;\n"
    "  // ack-on-reply then advances offset past the burst, which is correct as long as\n"
    "  // claude has consumed all of them via the MCP notifications already dispatched.\n"
    "  _pendingUpdates.set(chatId, updateId)\n"
    "}\n"
    "function _ackPending(chatId: string | number): void {\n"
    "  const updateId = _pendingUpdates.get(chatId)\n"
    "  if (typeof updateId === 'number') {\n"
    "    _saveOffset(updateId)\n"
    "    _pendingUpdates.delete(chatId)\n"
    "  }\n"
    "}\n"
)

OFFSET_REPLAY = (
    "      // " + MARKER_OFFSET + " — replay-from-disk before bot.start\n"
    "      {\n"
    "        const _resume = _loadOffset()\n"
    "        if (_resume > 0) {\n"
    "          try { await bot.api.getUpdates({ offset: _resume, limit: 1, timeout: 0 }) } catch {}\n"
    "        }\n"
    "      }\n"
)

OFFSET_MARK = (
    "  // " + MARKER_OFFSET + " — mark pending update for ack-on-reply\n"
    "  if (typeof ctx.update?.update_id === 'number') _markPending(chat_id, ctx.update.update_id)\n"
)

OFFSET_ACK = (
    "        // " + MARKER_OFFSET + " — ack pending update; advances disk offset only after a successful reply\n"
    "        _ackPending(chat_id)\n"
)

# 028: pending-reply marker. A tiny disk file that says "a channel message is
# awaiting a reply" — written on inbound, deleted on the reply tool. It is the
# ORIGIN + unreplied signal the reply-guard Stop hook reads at turn-end (the Stop
# payload carries no turn origin; the hook runs in the claude process and cannot
# read this plugin's in-memory _pendingUpdates Map). Same file family + ack-on-reply
# timing as the offset patch; independent marker so it applies/skips on its own.
PENDING_HELPERS = (
    "\n// " + MARKER_PENDING + "\n"
    "const _PENDING_REPLY_FILE = '/home/agent/.claude/channels/telegram/pending-reply.json'\n"
    "function _markPendingReply(chatId: string | number, updateId: number): void {\n"
    "  try {\n"
    "    const fs = require('node:fs')\n"
    "    const path = require('node:path')\n"
    "    fs.mkdirSync(path.dirname(_PENDING_REPLY_FILE), { recursive: true })\n"
    "    fs.writeFileSync(_PENDING_REPLY_FILE, JSON.stringify({ chat_id: chatId, update_id: updateId, ts: Date.now() }))\n"
    "  } catch {}\n"
    "}\n"
    "function _clearPendingReply(): void {\n"
    "  try {\n"
    "    const fs = require('node:fs')\n"
    "    fs.rmSync(_PENDING_REPLY_FILE, { force: true })\n"
    "  } catch {}\n"
    "}\n"
)

PENDING_MARK = (
    "  // " + MARKER_PENDING + " — record the channel turn as awaiting a reply\n"
    "  if (typeof ctx.update?.update_id === 'number') _markPendingReply(chat_id, ctx.update.update_id)\n"
)

PENDING_CLEAR = (
    "        // " + MARKER_PENDING + " — the reply tool fired; clear the awaiting-reply marker\n"
    "        _clearPendingReply()\n"
)

# 031: AskUserQuestion guard give-up delivery. The PreToolUse hook (a separate
# as-`agent` process) writes askq-guard-giveup.json when it stops redirecting a
# channel turn away from the console-only interactive prompt (Q1: the hook itself
# never gains channel-send capability). This plugin-side check — wired into the
# EXISTING typing keep-alive, which already owns bot.api.sendMessage — reads the
# marker, delivers exactly one give-up message, and deletes it. Two call sites
# (both inserted below): every keep-alive tick (the common path — the guard's
# terminal deny keeps the turn running, so a tick reliably follows the write) and
# at keep-alive START for the next inbound turn (the safety net for the narrow
# race where a marker is written after the last tick of the current turn).
# Delete-on-send is the idempotency key: whichever trigger runs first clears the
# marker, so the two can never double-send.
ASKQ_GIVEUP_HELPERS = (
    "\n// " + MARKER_ASKQ_GIVEUP + "\n"
    "const _ASKQ_GIVEUP_FILE = '/home/agent/.claude/channels/telegram/askq-guard-giveup.json'\n"
    "function _checkAskqGiveup(): void {\n"
    "  try {\n"
    "    const fs = require('node:fs')\n"
    "    if (!fs.existsSync(_ASKQ_GIVEUP_FILE)) return\n"
    "    const j = JSON.parse(fs.readFileSync(_ASKQ_GIVEUP_FILE, 'utf8'))\n"
    "    fs.rmSync(_ASKQ_GIVEUP_FILE, { force: true })\n"
    "    const chatId = j.chat_id\n"
    "    if (!chatId) return\n"
    "    const giveupMsg = 'Intenté abrir un menú interactivo que no puedo mostrarte por acá; no pude completar la acción. ¿Me lo confirmas por mensaje?'\n"
    "    bot.api.sendMessage(chatId, giveupMsg)\n"
    "      .catch((err: any) => {\n"
    "        const msg = err && (err.message || err.description || String(err))\n"
    "        process.stderr.write(`telegram channel: askq-guard give-up sendMessage failed for chat ${chatId}: ${msg}\\n`)\n"
    "      })\n"
    "  } catch {}\n"
    "}\n"
)

ASKQ_GIVEUP_TICK_CHECK = (
    "    _checkAskqGiveup()\n"
    "    bot.api.sendChatAction(chat_id, 'typing')\n"
)

ASKQ_GIVEUP_START_CHECK = (
    "function _typingKeepAlive(chat_id: string | number): void {\n"
    "  _checkAskqGiveup()\n"
)

PRIMARY_GUARD = (
    "    // " + MARKER_PRIMARY + " — exit cleanly if PID_FILE mtime is fresh (live primary)\n"
    "    try {\n"
    "      const _ageMs = Date.now() - statSync(PID_FILE).mtimeMs\n"
    "      if (_ageMs < 30000) {\n"
    "        process.stderr.write(`telegram channel: primary pid=${stale} active (heartbeat ${Math.round(_ageMs/1000)}s ago); exiting as secondary\\n`)\n"
    "        process.exit(0)\n"
    "      }\n"
    "    } catch {}\n"
)

PRIMARY_HEARTBEAT = (
    "// " + MARKER_PRIMARY + " — refresh PID_FILE mtime so secondary instances detect us\n"
    "setInterval(() => {\n"
    "  try { writeFileSync(PID_FILE, String(process.pid)) } catch {}\n"
    "}, 5000).unref()\n"
)

STDERR_HOOK = (
    "// " + MARKER_STDERR + "\n"
    "try {\n"
    "  const _STDERR_LOG = '/workspace/scripts/heartbeat/logs/telegram-mcp-stderr.log'\n"
    "  const _origWrite = process.stderr.write.bind(process.stderr)\n"
    "  process.stderr.write = ((chunk: any, ...rest: any[]) => {\n"
    "    try {\n"
    "      const fs = require('node:fs')\n"
    "      const path = require('node:path')\n"
    "      fs.mkdirSync(path.dirname(_STDERR_LOG), { recursive: true })\n"
    "      fs.appendFileSync(_STDERR_LOG, typeof chunk === 'string' ? chunk : Buffer.from(chunk))\n"
    "    } catch {}\n"
    "    return _origWrite(chunk, ...rest)\n"
    "  }) as typeof process.stderr.write\n"
    "  process.on('uncaughtException', (e: Error) => {\n"
    "    try {\n"
    "      const fs = require('node:fs')\n"
    "      fs.appendFileSync(_STDERR_LOG, `[${new Date().toISOString()}] [uncaught] ${e.stack || e}\\n`)\n"
    "    } catch {}\n"
    "  })\n"
    "  process.on('unhandledRejection', (r: unknown) => {\n"
    "    try {\n"
    "      const fs = require('node:fs')\n"
    "      fs.appendFileSync(_STDERR_LOG, `[${new Date().toISOString()}] [unhandled] ${r}\\n`)\n"
    "    } catch {}\n"
    "  })\n"
    "} catch {}\n"
)


# 033: frozen v1 (032) twins of the five voice constants the v1→v2 upgrader
# rewrites. Each is a byte-for-byte copy of what 032 shipped — NEVER edited
# again — so `upgrade_voice_v1_to_v2` can find them verbatim in an
# already-patched file and the golden fixture's fidelity is checkable
# against them (contracts/voice-group-v2-upgrade.md C1, C5 G2b).
VOICE_HELPERS_V1 = (
    "\n// " + MARKER_VOICE_V1 + "\n"
    "const VOICE_ENABLED = process.env.TELEGRAM_VOICE_ENABLED === 'true'\n"
    "const VOICE_KEY = process.env.ELEVENLABS_API_KEY ?? ''\n"
    "const VOICE_ACTIVE = VOICE_ENABLED && VOICE_KEY.length > 0\n"
    "const VOICE_REPLY_MODE = (['auto', 'always', 'never'].includes(process.env.TELEGRAM_VOICE_REPLY_MODE ?? '')\n"
    "  ? (process.env.TELEGRAM_VOICE_REPLY_MODE as 'auto' | 'always' | 'never')\n"
    "  : 'auto')\n"
    "const VOICE_ID = process.env.TELEGRAM_VOICE_ID || 'Rachel'\n"
    "const VOICE_STT_LANG = process.env.TELEGRAM_VOICE_STT_LANG ?? ''\n"
    "const VOICE_MAX_NOTE_SECONDS = Number(process.env.TELEGRAM_VOICE_MAX_NOTE_SECONDS) > 0\n"
    "  ? Number(process.env.TELEGRAM_VOICE_MAX_NOTE_SECONDS)\n"
    "  : 300\n"
    "const VOICE_SPOKEN_CHAR_CAP = Number(process.env.TELEGRAM_VOICE_SPOKEN_CHAR_CAP) > 0\n"
    "  ? Number(process.env.TELEGRAM_VOICE_SPOKEN_CHAR_CAP)\n"
    "  : 1200\n"
    "const VOICE_API_BASE = 'https://api.elevenlabs.io'\n"
    "const VOICE_STT_MODEL = 'scribe_v2'\n"
    "const VOICE_TTS_MODEL = 'eleven_flash_v2_5'\n"
    "const VOICE_MAX_BYTES = 20 * 1024 * 1024\n"
    "if (!VOICE_ENABLED) {\n"
    "  process.stderr.write('telegram channel: voice disabled (TELEGRAM_VOICE_ENABLED != true)\\n')\n"
    "} else if (!VOICE_KEY) {\n"
    "  process.stderr.write('telegram channel: voice inactive — ELEVENLABS_API_KEY missing\\n')\n"
    "} else {\n"
    "  process.stderr.write(`telegram channel: voice active mode=${VOICE_REPLY_MODE} caps=${VOICE_MAX_NOTE_SECONDS}s/${VOICE_SPOKEN_CHAR_CAP}chars\\n`)\n"
    "}\n"
    "const _voiceOrigin = new Map<string, number>()\n"
    "const _VOICE_ORIGIN_TTL_MS = 5 * 60 * 1000\n"
    "function _voiceOriginSet(chatId: string): void {\n"
    "  _voiceOrigin.set(chatId, Date.now())\n"
    "}\n"
    "function _voiceOriginConsume(chatId: string): boolean {\n"
    "  const ts = _voiceOrigin.get(chatId)\n"
    "  _voiceOrigin.delete(chatId)\n"
    "  if (ts == null) return false\n"
    "  return Date.now() - ts < _VOICE_ORIGIN_TTL_MS\n"
    "}\n"
    "function _voiceOriginClear(chatId: string): void {\n"
    "  _voiceOrigin.delete(chatId)\n"
    "}\n"
    "let _voiceTtsFormat: 'unknown' | 'ogg-ok' | 'mp3-fallback' = 'unknown'\n"
    "function _voiceErrClass(err: unknown): { cls: string; status: string } {\n"
    "  if (err instanceof Error && err.name === 'AbortError') return { cls: 'timeout', status: '' }\n"
    "  const msg = err instanceof Error ? err.message : ''\n"
    "  const m = /-status-(\\d+)$/.exec(msg)\n"
    "  if (m) return { cls: 'transport', status: m[1] }\n"
    "  return { cls: 'transport', status: '' }\n"
    "}\n"
    "async function _voiceTranscribe(buf: Buffer, signal: AbortSignal): Promise<string> {\n"
    "  const form = new FormData()\n"
    "  form.append('file', new Blob([buf]), 'voice.ogg')\n"
    "  form.append('model_id', VOICE_STT_MODEL)\n"
    "  if (VOICE_STT_LANG) form.append('language_code', VOICE_STT_LANG)\n"
    "  const res = await fetch(`${VOICE_API_BASE}/v1/speech-to-text`, {\n"
    "    method: 'POST',\n"
    "    headers: { 'xi-api-key': VOICE_KEY },\n"
    "    body: form,\n"
    "    signal,\n"
    "  })\n"
    "  if (!res.ok) throw new Error(`stt-status-${res.status}`)\n"
    "  const j = (await res.json()) as { text?: string }\n"
    "  return (j.text ?? '').trim()\n"
    "}\n"
    "async function _voiceSynthesize(text: string, signal: AbortSignal): Promise<{ buf: Buffer; fmt: 'ogg' | 'mp3' }> {\n"
    "  async function _voiceTtsRequest(fmt: string): Promise<Buffer> {\n"
    "    const res = await fetch(`${VOICE_API_BASE}/v1/text-to-speech/${VOICE_ID}?output_format=${fmt}`, {\n"
    "      method: 'POST',\n"
    "      headers: { 'xi-api-key': VOICE_KEY, 'content-type': 'application/json' },\n"
    "      body: JSON.stringify({ text, model_id: VOICE_TTS_MODEL }),\n"
    "      signal,\n"
    "    })\n"
    "    if (!res.ok) throw new Error(`tts-status-${res.status}`)\n"
    "    return Buffer.from(await res.arrayBuffer())\n"
    "  }\n"
    "  if (_voiceTtsFormat !== 'mp3-fallback') {\n"
    "    const buf = await _voiceTtsRequest('opus_48000_64')\n"
    "    if (buf.length >= 4 && buf.toString('ascii', 0, 4) === 'OggS') {\n"
    "      _voiceTtsFormat = 'ogg-ok'\n"
    "      return { buf, fmt: 'ogg' }\n"
    "    }\n"
    "  }\n"
    "  const buf = await _voiceTtsRequest('mp3_44100_128')\n"
    "  _voiceTtsFormat = 'mp3-fallback'\n"
    "  return { buf, fmt: 'mp3' }\n"
    "}\n"
    "function _voiceTruncate(text: string, cap: number): string {\n"
    "  if (text.length <= cap) return text\n"
    "  const cut = text.lastIndexOf(' ', cap)\n"
    "  const at = cut > cap / 2 ? cut : cap\n"
    "  return text.slice(0, at) + '…'\n"
    "}\n"
)

# 034: frozen v2 twin of VOICE_HELPERS — the exact text the v0.24.0 patcher
# wrote (built with MARKER_VOICE_V2). Never edited again: `upgrade_voice_v2_to_v3`
# finds it verbatim in an already-patched file, the re-pointed
# `upgrade_voice_v1_to_v2` writes it, and the golden v2 fixture's fidelity
# test asserts it byte-for-byte (contracts/voice-group-v3-upgrade.md C1, G2b).
VOICE_HELPERS_V2 = (
    "\n// " + MARKER_VOICE_V2 + "\n"
    "const VOICE_ENABLED = process.env.TELEGRAM_VOICE_ENABLED === 'true'\n"
    "const VOICE_KEY = process.env.ELEVENLABS_API_KEY ?? ''\n"
    "const VOICE_ACTIVE = VOICE_ENABLED && VOICE_KEY.length > 0\n"
    "const VOICE_REPLY_MODE = (['auto', 'always', 'never'].includes(process.env.TELEGRAM_VOICE_REPLY_MODE ?? '')\n"
    "  ? (process.env.TELEGRAM_VOICE_REPLY_MODE as 'auto' | 'always' | 'never')\n"
    "  : 'auto')\n"
    "const VOICE_ID = process.env.TELEGRAM_VOICE_ID || 'Rachel'\n"
    "const VOICE_STT_LANG = process.env.TELEGRAM_VOICE_STT_LANG ?? ''\n"
    "const VOICE_MAX_NOTE_SECONDS = Number(process.env.TELEGRAM_VOICE_MAX_NOTE_SECONDS) > 0\n"
    "  ? Number(process.env.TELEGRAM_VOICE_MAX_NOTE_SECONDS)\n"
    "  : 300\n"
    "const VOICE_SPOKEN_CHAR_CAP = Number(process.env.TELEGRAM_VOICE_SPOKEN_CHAR_CAP) > 0\n"
    "  ? Number(process.env.TELEGRAM_VOICE_SPOKEN_CHAR_CAP)\n"
    "  : 1200\n"
    "const VOICE_API_BASE = 'https://api.elevenlabs.io'\n"
    "const VOICE_STT_MODEL = 'scribe_v2'\n"
    "const VOICE_TTS_MODEL = 'eleven_flash_v2_5'\n"
    "const VOICE_MAX_BYTES = 20 * 1024 * 1024\n"
    "if (!VOICE_ENABLED) {\n"
    "  process.stderr.write('telegram channel: voice disabled (TELEGRAM_VOICE_ENABLED != true)\\n')\n"
    "} else if (!VOICE_KEY) {\n"
    "  process.stderr.write('telegram channel: voice inactive — ELEVENLABS_API_KEY missing\\n')\n"
    "} else {\n"
    "  process.stderr.write(`telegram channel: voice active mode=${VOICE_REPLY_MODE} caps=${VOICE_MAX_NOTE_SECONDS}s/${VOICE_SPOKEN_CHAR_CAP}chars\\n`)\n"
    "}\n"
    "const _voiceOrigin = new Map<string, number>()\n"
    "const _VOICE_ORIGIN_TTL_MS = 5 * 60 * 1000\n"
    "function _voiceOriginSet(chatId: string): void {\n"
    "  _voiceOrigin.set(chatId, Date.now())\n"
    "}\n"
    "function _voiceOriginConsume(chatId: string): boolean {\n"
    "  const ts = _voiceOrigin.get(chatId)\n"
    "  _voiceOrigin.delete(chatId)\n"
    "  if (ts == null) return false\n"
    "  return Date.now() - ts < _VOICE_ORIGIN_TTL_MS\n"
    "}\n"
    "function _voiceOriginClear(chatId: string): void {\n"
    "  _voiceOrigin.delete(chatId)\n"
    "}\n"
    "let _voiceTtsFormat: 'unknown' | 'ogg-ok' | 'mp3-fallback' = 'unknown'\n"
    "function _voiceErrClass(err: unknown): { cls: string; status: string } {\n"
    "  if (err instanceof Error && err.name === 'AbortError') return { cls: 'timeout', status: '' }\n"
    "  if (typeof err === 'object' && err !== null && typeof (err as { error_code?: unknown }).error_code === 'number') {\n"
    "    return { cls: 'transport', status: String((err as { error_code: number }).error_code) }\n"
    "  }\n"
    "  const msg = err instanceof Error ? err.message : ''\n"
    "  const m = /-status-(\\d+)$/.exec(msg)\n"
    "  if (m) return { cls: 'transport', status: m[1] }\n"
    "  return { cls: 'transport', status: '' }\n"
    "}\n"
    "async function _voiceTranscribe(buf: Buffer, signal: AbortSignal): Promise<string> {\n"
    "  const form = new FormData()\n"
    "  form.append('file', new Blob([buf]), 'voice.ogg')\n"
    "  form.append('model_id', VOICE_STT_MODEL)\n"
    "  if (VOICE_STT_LANG) form.append('language_code', VOICE_STT_LANG)\n"
    "  const res = await fetch(`${VOICE_API_BASE}/v1/speech-to-text`, {\n"
    "    method: 'POST',\n"
    "    headers: { 'xi-api-key': VOICE_KEY },\n"
    "    body: form,\n"
    "    signal,\n"
    "  })\n"
    "  if (!res.ok) throw new Error(`stt-status-${res.status}`)\n"
    "  const j = (await res.json()) as { text?: string }\n"
    "  return (j.text ?? '').trim()\n"
    "}\n"
    "async function _voiceSynthesize(text: string, signal: AbortSignal): Promise<{ buf: Buffer; fmt: 'ogg' | 'mp3' }> {\n"
    "  async function _voiceTtsRequest(fmt: string): Promise<Buffer> {\n"
    "    const res = await fetch(`${VOICE_API_BASE}/v1/text-to-speech/${VOICE_ID}?output_format=${fmt}`, {\n"
    "      method: 'POST',\n"
    "      headers: { 'xi-api-key': VOICE_KEY, 'content-type': 'application/json' },\n"
    "      body: JSON.stringify({ text, model_id: VOICE_TTS_MODEL }),\n"
    "      signal,\n"
    "    })\n"
    "    if (!res.ok) throw new Error(`tts-status-${res.status}`)\n"
    "    return Buffer.from(await res.arrayBuffer())\n"
    "  }\n"
    "  if (_voiceTtsFormat !== 'mp3-fallback') {\n"
    "    const buf = await _voiceTtsRequest('opus_48000_64')\n"
    "    if (buf.length >= 4 && buf.toString('ascii', 0, 4) === 'OggS') {\n"
    "      _voiceTtsFormat = 'ogg-ok'\n"
    "      return { buf, fmt: 'ogg' }\n"
    "    }\n"
    "  }\n"
    "  const buf = await _voiceTtsRequest('mp3_44100_128')\n"
    "  _voiceTtsFormat = 'mp3-fallback'\n"
    "  return { buf, fmt: 'mp3' }\n"
    "}\n"
    "function _voiceTruncate(text: string, cap: number): string {\n"
    "  if (text.length <= cap) return text\n"
    "  const cut = text.lastIndexOf(' ', cap)\n"
    "  const at = cut > cap / 2 ? cut : cap\n"
    "  return text.slice(0, at) + '…'\n"
    "}\n"
    "const VOICE_OMISSION_NAG_CHARS = Math.floor(VOICE_SPOKEN_CHAR_CAP / 4)\n"
    "const VOICE_REQUEST_PHRASES: readonly string[] = [\n"
    "  'responde con audio', 'respondeme con audio', 'responde en audio', 'respondeme en audio',\n"
    "  'responde por audio', 'respondeme por audio', 'contesta con audio', 'contestame con audio',\n"
    "  'contesta en audio', 'contestame en audio', 'contesta por audio', 'contestame por audio',\n"
    "  'responde con voz', 'respondeme con voz', 'contesta con voz', 'responde con una nota de voz',\n"
    "  'mandame un audio', 'mandame audio', 'mandame una nota de voz', 'enviame un audio',\n"
    "  'enviame una nota de voz', 'responde hablando', 'respondeme hablando',\n"
    "  'reply with audio', 'respond with audio', 'answer with audio', 'reply with voice',\n"
    "  'respond with voice', 'answer with voice', 'reply in audio', 'respond in audio',\n"
    "  'answer in audio', 'send me an audio', 'send me a voice note', 'send me a voice message',\n"
    "  'send a voice note', 'reply with a voice note', 'reply with a voice message',\n"
    "]\n"
    "const _VOICE_REQUEST_NEGATION = /(?:^|[\\s,;:—-])(?:no|nunca|jamas|sin|don't|dont|do not|never|stop)\\b[^.!?\\n]{0,30}$/\n"
    "function _voiceNormalize(s: string): string {\n"
    "  return s\n"
    "    .normalize('NFD')\n"
    "    .replace(/[\\u0300-\\u036f]/g, '')\n"
    "    .replace(/[\\u2018\\u2019\\u02bc\\u00b4\\`]/g, \"'\")\n"
    "    .toLowerCase()\n"
    "    .replace(/\\s+/g, ' ')\n"
    "    .trim()\n"
    "}\n"
    "function _isVoiceWordChar(ch: string | undefined): boolean {\n"
    "  return ch != null && /[a-z0-9]/.test(ch)\n"
    "}\n"
    "function _voiceRequestMatch(text: string): boolean {\n"
    "  const t = _voiceNormalize(text)\n"
    "  for (const p of VOICE_REQUEST_PHRASES) {\n"
    "    let i = t.indexOf(p)\n"
    "    while (i >= 0) {\n"
    "      const before = i > 0 ? t[i - 1] : undefined\n"
    "      const after = i + p.length < t.length ? t[i + p.length] : undefined\n"
    "      if (!_isVoiceWordChar(before) && !_isVoiceWordChar(after) && !_VOICE_REQUEST_NEGATION.test(t.slice(0, i))) {\n"
    "        return true\n"
    "      }\n"
    "      i = t.indexOf(p, i + 1)\n"
    "    }\n"
    "  }\n"
    "  return false\n"
    "}\n"
    "const _voiceCooldown = new Map<string, number>()\n"
    "function _voiceCooldownConsume(chatId: string): boolean {\n"
    "  const ts = _voiceCooldown.get(chatId)\n"
    "  _voiceCooldown.delete(chatId)\n"
    "  if (ts == null) return false\n"
    "  return Date.now() - ts < _VOICE_ORIGIN_TTL_MS\n"
    "}\n"
    "// agentic-pod-launcher: voice helpers end (033)\n"
)

# 032: voice roundtrip. Module-scope helpers — config read (with a ONE-TIME
# boot-time line so fault-injection e2e can observe it, emitted before any
# token/network use), a redacting error-class helper (never the key, never a
# raw error object, never a URL — the getFile download URL embeds the
# Telegram BOT TOKEN), the STT/TTS fetch helpers, the in-memory voice-origin
# map (consume-on-read, 5-minute TTL), the TTS format sniff cache, and the
# reply-fallback truncation helper.
#
# 033 v2: identical helpers plus the omission-nag threshold, the explicit
# audio-request matcher, and the failure cooldown map (added by later hunks
# in this same feature, not duplicated here) — closed by the sentinel
# comment `voice helpers end (033)` so the DOCKER_E2E harness can extract
# exactly this block for behavioural testing under bun.
#
# 034 v3: the spoken-style constants (sign-off, currency, language name,
# empty sentence; cap default 900), `_voiceSpokenNormalize`, the sign-off
# helpers (`_voiceKey` / `_voiceSignoffStrip` / `_voiceSignoffAppend`),
# `_voiceSentenceCut` and `_voiceSpokenAssemble`; `language_code` in the TTS
# body; `_voiceTruncate` removed. The sentinel text is an END marker, kept
# verbatim on purpose.
VOICE_HELPERS = (
    "\n// " + MARKER_VOICE + "\n"
    "const VOICE_ENABLED = process.env.TELEGRAM_VOICE_ENABLED === 'true'\n"
    "const VOICE_KEY = process.env.ELEVENLABS_API_KEY ?? ''\n"
    "const VOICE_ACTIVE = VOICE_ENABLED && VOICE_KEY.length > 0\n"
    "const VOICE_REPLY_MODE = (['auto', 'always', 'never'].includes(process.env.TELEGRAM_VOICE_REPLY_MODE ?? '')\n"
    "  ? (process.env.TELEGRAM_VOICE_REPLY_MODE as 'auto' | 'always' | 'never')\n"
    "  : 'auto')\n"
    "const VOICE_ID = process.env.TELEGRAM_VOICE_ID || 'Rachel'\n"
    "const VOICE_STT_LANG = process.env.TELEGRAM_VOICE_STT_LANG ?? ''\n"
    "const VOICE_MAX_NOTE_SECONDS = Number(process.env.TELEGRAM_VOICE_MAX_NOTE_SECONDS) > 0\n"
    "  ? Number(process.env.TELEGRAM_VOICE_MAX_NOTE_SECONDS)\n"
    "  : 300\n"
    "const VOICE_SPOKEN_CHAR_CAP = Number(process.env.TELEGRAM_VOICE_SPOKEN_CHAR_CAP) > 0\n"
    "  ? Number(process.env.TELEGRAM_VOICE_SPOKEN_CHAR_CAP)\n"
    "  : 900\n"
    "const VOICE_API_BASE = 'https://api.elevenlabs.io'\n"
    "const VOICE_STT_MODEL = 'scribe_v2'\n"
    "const VOICE_TTS_MODEL = 'eleven_flash_v2_5'\n"
    "const VOICE_MAX_BYTES = 20 * 1024 * 1024\n"
    # 034: spoken-style constants. Declared HERE — after the config reads and
    # BEFORE the boot-log block below, which reads VOICE_SIGNOFF.length: a
    # `const` sits in its temporal dead zone until its line runs, so placing
    # these after that block throws ReferenceError at module load under bun
    # and flaps the channel (analyze U1). VOICE_STT_LANG (above) feeds the
    # word table and the language name.
    "const VOICE_SIGNOFF = (process.env.TELEGRAM_VOICE_SIGNOFF ?? '').trim()\n"
    "const _VOICE_WORDS = VOICE_STT_LANG === 'en'\n"
    "  ? { dollars: 'dollars', percent: 'percent', uf: 'unidades de fomento', empty: 'The details are in the text message.' }\n"
    "  : { dollars: 'dólares', percent: 'por ciento', uf: 'unidades de fomento', empty: 'El detalle va en el mensaje de texto.' }\n"
    "const VOICE_CURRENCY = (process.env.TELEGRAM_VOICE_CURRENCY ?? '').trim() || (VOICE_STT_LANG === 'en' ? 'Chilean pesos' : 'pesos chilenos')\n"
    "const VOICE_SPOKEN_LANG_NAME = VOICE_STT_LANG === 'es' ? 'Spanish' : VOICE_STT_LANG === 'en' ? 'English' : 'the language the user wrote in'\n"
    "const VOICE_EMPTY_SENTENCE = _VOICE_WORDS.empty\n"
    "if (!VOICE_ENABLED) {\n"
    "  process.stderr.write('telegram channel: voice disabled (TELEGRAM_VOICE_ENABLED != true)\\n')\n"
    "} else if (!VOICE_KEY) {\n"
    "  process.stderr.write('telegram channel: voice inactive — ELEVENLABS_API_KEY missing\\n')\n"
    "} else {\n"
    "  process.stderr.write(`telegram channel: voice active mode=${VOICE_REPLY_MODE} caps=${VOICE_MAX_NOTE_SECONDS}s/${VOICE_SPOKEN_CHAR_CAP}chars signoff=${VOICE_SIGNOFF.length}chars\\n`)\n"
    "}\n"
    # 034 (US3): spoken-safe normalization — pipeline contract C2, 15 ordered
    # passes. Digits are NEVER rewritten; only symbols adjacent to a figure are
    # named (the figure group is closed by (?!\d) so `$1500` stays whole). The
    # figure group is `/…/.source` and the seven symbol rules are `String.raw`
    # template literals: ONE backslash in the TS text (analyze I2). In THIS
    # Python literal every TS backslash is doubled; `\1`, `\b`, `\t`, `\r`,
    # `\n` would otherwise be transformed silently (research D14 — G15/G16).
    "const _VOICE_FIG = /(?:\\d{1,3}(?:[.,\\s]\\d{3})*(?:[.,]\\d+)?|\\d+(?:[.,]\\d+)?)(?!\\d)/.source\n"
    "function _voiceSpokenNormalize(input: string): string {\n"
    "  let t = input.replace(/\\r\\n?/g, '\\n')\n"
    "  t = t.replace(/```[\\s\\S]*?```/g, ' ')\n"
    "  t = t.replace(/`([^`\\n]*)`/g, '$1')\n"
    "  t = t.replace(/\\[([^\\]\\n]*)\\]\\((?:[^)\\s]+)\\)/g, '$1')\n"
    "  t = t.replace(/\\bhttps?:\\/\\/\\S+/gi, ' ')\n"
    "  t = t.replace(/^[ \\t]{0,3}#{1,6}[ \\t]+/gm, '')\n"
    "  t = t.replace(/^[ \\t]*(?:[-*_=][ \\t]*){3,}[ \\t]*$/gm, '')\n"
    "  t = t.replace(/(\\*\\*|__)(.+?)\\1/g, '$2')\n"
    "  t = t.replace(/(\\*|_)(?=\\S)(.+?)(?<=\\S)\\1/g, '$2')\n"
    "  t = t.replace(/~~(.+?)~~/g, '$1')\n"
    "  t = t.replace(/^[ \\t]*(?:[-*+•]|\\d+[.)])[ \\t]+/gm, '')\n"
    "  t = t.replace(/^[ \\t]*>[ \\t]?/gm, '')\n"
    "  t = t.replace(/\\|/g, ' ')\n"
    "  t = t.replace(/^[ \\t]*[-:][-: \\t]*$/gm, '')\n"
    "  t = t.replace(/[\\p{Extended_Pictographic}\\u{1F1E6}-\\u{1F1FF}\\u{1F3FB}-\\u{1F3FF}\\u{20E3}\\u{FE0F}\\u{200D}]/gu, '')\n"
    "  t = t.replace(new RegExp(String.raw`(?:US\\$|USD)\\s*(${_VOICE_FIG})`, 'g'), `$1 ${_VOICE_WORDS.dollars}`)\n"
    "  t = t.replace(new RegExp(String.raw`(${_VOICE_FIG})\\s*USD\\b`, 'g'), `$1 ${_VOICE_WORDS.dollars}`)\n"
    "  t = t.replace(new RegExp(String.raw`\\bUF\\s*(${_VOICE_FIG})`, 'g'), `$1 ${_VOICE_WORDS.uf}`)\n"
    "  t = t.replace(new RegExp(String.raw`(${_VOICE_FIG})\\s*UF\\b`, 'g'), `$1 ${_VOICE_WORDS.uf}`)\n"
    "  t = t.replace(new RegExp(String.raw`(?:CLP\\s*\\$?|\\$)\\s*(${_VOICE_FIG})`, 'g'), `$1 ${VOICE_CURRENCY}`)\n"
    "  t = t.replace(new RegExp(String.raw`(${_VOICE_FIG})\\s*CLP\\b`, 'g'), `$1 ${VOICE_CURRENCY}`)\n"
    "  t = t.replace(new RegExp(String.raw`(${_VOICE_FIG})\\s*%`, 'g'), `$1 ${_VOICE_WORDS.percent}`)\n"
    "  t = t.replace(/\\$/g, ' ')\n"
    "  t = t.split('\\n').map(l => l.trim()).filter(l => l.length > 0)\n"
    "    .map(l => (/[.!?;:]$/.test(l) ? l : l + '.')).join(' ')\n"
    "  t = t.replace(/\\s+([.,;:!?])/g, '$1').replace(/\\s{2,}/g, ' ').trim()\n"
    "  return t\n"
    "}\n"
    # 034 (US2): closing-phrase helpers — pipeline contract C4. Accent/case/
    # punctuation-insensitive key; strip a copy the model wrote at the END of its
    # rendition (scan bounded to 3x the phrase length); append exactly once.
    "function _voiceKey(s: string): string {\n"
    "  return s.normalize('NFD').replace(/[\\u0300-\\u036f]/g, '').toLowerCase()\n"
    "    .replace(/[.!?,;:\\u2026]+$/g, '').replace(/\\s+/g, ' ').trim()\n"
    "}\n"
    "// Remove a copy of the sign-off the model wrote at the END of its rendition (any case,\n"
    "// accents, punctuation): the longest suffix whose key equals the sign-off key. Scan bounded\n"
    "// to where such a suffix can start (last 3 x signoff.length characters).\n"
    "function _voiceSignoffStrip(spoken: string, signoff: string): string {\n"
    "  const s = spoken.trim()\n"
    "  if (!signoff) return s\n"
    "  const k = _voiceKey(signoff)\n"
    "  if (!k || !_voiceKey(s).endsWith(k)) return s\n"
    "  const from = Math.max(0, s.length - 3 * signoff.length)\n"
    "  for (let j = from; j <= s.length; j++) {\n"
    "    if (_voiceKey(s.slice(j)) === k) return s.slice(0, j).trim()\n"
    "  }\n"
    "  return s\n"
    "}\n"
    "function _voiceSignoffAppend(spoken: string, signoff: string): string {\n"
    "  let s = spoken.trim()\n"
    "  if (!signoff) return s\n"
    "  const k = _voiceKey(signoff)\n"
    "  if (k && _voiceKey(s).endsWith(k)) return s\n"
    "  s = s.replace(/[;:]+$/, '.')\n"
    "  const sep = /[.!?]$/.test(s) ? ' ' : (s.length ? '. ' : '')\n"
    "  return s + sep + signoff\n"
    "}\n"
    # 034 (US4): sentence-boundary cut (C3) and the whole assembly (C6) —
    # normalize → empty sentence → strip a model-written sign-off → budget
    # cap−(signoff+2) floored at cap/2 → cut → append the sign-off once. A
    # MODULE-LEVEL helper so DOCKER_E2E executes it for real (E10); the reply
    # block only calls it. Replaces the 032 character-level `_voiceTruncate`.
    "function _voiceSentenceCut(text: string, budget: number): { out: string; trimmed: boolean } {\n"
    "  if (text.length <= budget) return { out: text, trimmed: false }\n"
    "  const head = text.slice(0, budget)\n"
    "  const m = head.match(/^[\\s\\S]*[.!?;](?=\\s|$)/)\n"
    "  let at = m ? m[0].length : -1\n"
    "  if (at < budget / 4) at = head.lastIndexOf(' ')\n"
    "  if (at <= 0) at = budget\n"
    "  return { out: text.slice(0, at).trim(), trimmed: true }\n"
    "}\n"
    "function _voiceSpokenAssemble(raw: string): { spoken: string; narrated: string; trimmed: boolean } {\n"
    "  let t = _voiceSpokenNormalize(raw)\n"
    "  if (!t) t = VOICE_EMPTY_SENTENCE\n"
    "  t = _voiceSignoffStrip(t, VOICE_SIGNOFF)\n"
    "  if (!t) t = VOICE_EMPTY_SENTENCE\n"
    "  const budget = Math.max(VOICE_SPOKEN_CHAR_CAP - (VOICE_SIGNOFF ? VOICE_SIGNOFF.length + 2 : 0), Math.floor(VOICE_SPOKEN_CHAR_CAP / 2))\n"
    "  const cut = _voiceSentenceCut(t, budget)\n"
    "  return { spoken: _voiceSignoffAppend(cut.out, VOICE_SIGNOFF), narrated: cut.out, trimmed: cut.trimmed }\n"
    "}\n"
    "const _voiceOrigin = new Map<string, number>()\n"
    "const _VOICE_ORIGIN_TTL_MS = 5 * 60 * 1000\n"
    "function _voiceOriginSet(chatId: string): void {\n"
    "  _voiceOrigin.set(chatId, Date.now())\n"
    "}\n"
    "function _voiceOriginConsume(chatId: string): boolean {\n"
    "  const ts = _voiceOrigin.get(chatId)\n"
    "  _voiceOrigin.delete(chatId)\n"
    "  if (ts == null) return false\n"
    "  return Date.now() - ts < _VOICE_ORIGIN_TTL_MS\n"
    "}\n"
    "function _voiceOriginClear(chatId: string): void {\n"
    "  _voiceOrigin.delete(chatId)\n"
    "}\n"
    "let _voiceTtsFormat: 'unknown' | 'ogg-ok' | 'mp3-fallback' = 'unknown'\n"
    "function _voiceErrClass(err: unknown): { cls: string; status: string } {\n"
    "  if (err instanceof Error && err.name === 'AbortError') return { cls: 'timeout', status: '' }\n"
    "  if (typeof err === 'object' && err !== null && typeof (err as { error_code?: unknown }).error_code === 'number') {\n"
    "    return { cls: 'transport', status: String((err as { error_code: number }).error_code) }\n"
    "  }\n"
    "  const msg = err instanceof Error ? err.message : ''\n"
    "  const m = /-status-(\\d+)$/.exec(msg)\n"
    "  if (m) return { cls: 'transport', status: m[1] }\n"
    "  return { cls: 'transport', status: '' }\n"
    "}\n"
    "async function _voiceTranscribe(buf: Buffer, signal: AbortSignal): Promise<string> {\n"
    "  const form = new FormData()\n"
    "  form.append('file', new Blob([buf]), 'voice.ogg')\n"
    "  form.append('model_id', VOICE_STT_MODEL)\n"
    "  if (VOICE_STT_LANG) form.append('language_code', VOICE_STT_LANG)\n"
    "  const res = await fetch(`${VOICE_API_BASE}/v1/speech-to-text`, {\n"
    "    method: 'POST',\n"
    "    headers: { 'xi-api-key': VOICE_KEY },\n"
    "    body: form,\n"
    "    signal,\n"
    "  })\n"
    "  if (!res.ok) throw new Error(`stt-status-${res.status}`)\n"
    "  const j = (await res.json()) as { text?: string }\n"
    "  return (j.text ?? '').trim()\n"
    "}\n"
    "async function _voiceSynthesize(text: string, signal: AbortSignal): Promise<{ buf: Buffer; fmt: 'ogg' | 'mp3' }> {\n"
    "  async function _voiceTtsRequest(fmt: string): Promise<Buffer> {\n"
    "    const res = await fetch(`${VOICE_API_BASE}/v1/text-to-speech/${VOICE_ID}?output_format=${fmt}`, {\n"
    "      method: 'POST',\n"
    "      headers: { 'xi-api-key': VOICE_KEY, 'content-type': 'application/json' },\n"
    "      body: JSON.stringify({ text, model_id: VOICE_TTS_MODEL, ...(VOICE_STT_LANG ? { language_code: VOICE_STT_LANG } : {}) }),\n"
    "      signal,\n"
    "    })\n"
    "    if (!res.ok) throw new Error(`tts-status-${res.status}`)\n"
    "    return Buffer.from(await res.arrayBuffer())\n"
    "  }\n"
    "  if (_voiceTtsFormat !== 'mp3-fallback') {\n"
    "    const buf = await _voiceTtsRequest('opus_48000_64')\n"
    "    if (buf.length >= 4 && buf.toString('ascii', 0, 4) === 'OggS') {\n"
    "      _voiceTtsFormat = 'ogg-ok'\n"
    "      return { buf, fmt: 'ogg' }\n"
    "    }\n"
    "  }\n"
    "  const buf = await _voiceTtsRequest('mp3_44100_128')\n"
    "  _voiceTtsFormat = 'mp3-fallback'\n"
    "  return { buf, fmt: 'mp3' }\n"
    "}\n"
    "const VOICE_OMISSION_NAG_CHARS = Math.floor(VOICE_SPOKEN_CHAR_CAP / 4)\n"
    "const VOICE_REQUEST_PHRASES: readonly string[] = [\n"
    "  'responde con audio', 'respondeme con audio', 'responde en audio', 'respondeme en audio',\n"
    "  'responde por audio', 'respondeme por audio', 'contesta con audio', 'contestame con audio',\n"
    "  'contesta en audio', 'contestame en audio', 'contesta por audio', 'contestame por audio',\n"
    "  'responde con voz', 'respondeme con voz', 'contesta con voz', 'responde con una nota de voz',\n"
    "  'mandame un audio', 'mandame audio', 'mandame una nota de voz', 'enviame un audio',\n"
    "  'enviame una nota de voz', 'responde hablando', 'respondeme hablando',\n"
    "  'reply with audio', 'respond with audio', 'answer with audio', 'reply with voice',\n"
    "  'respond with voice', 'answer with voice', 'reply in audio', 'respond in audio',\n"
    "  'answer in audio', 'send me an audio', 'send me a voice note', 'send me a voice message',\n"
    "  'send a voice note', 'reply with a voice note', 'reply with a voice message',\n"
    "]\n"
    "const _VOICE_REQUEST_NEGATION = /(?:^|[\\s,;:—-])(?:no|nunca|jamas|sin|don't|dont|do not|never|stop)\\b[^.!?\\n]{0,30}$/\n"
    "function _voiceNormalize(s: string): string {\n"
    "  return s\n"
    "    .normalize('NFD')\n"
    "    .replace(/[\\u0300-\\u036f]/g, '')\n"
    "    .replace(/[\\u2018\\u2019\\u02bc\\u00b4\\`]/g, \"'\")\n"
    "    .toLowerCase()\n"
    "    .replace(/\\s+/g, ' ')\n"
    "    .trim()\n"
    "}\n"
    "function _isVoiceWordChar(ch: string | undefined): boolean {\n"
    "  return ch != null && /[a-z0-9]/.test(ch)\n"
    "}\n"
    "function _voiceRequestMatch(text: string): boolean {\n"
    "  const t = _voiceNormalize(text)\n"
    "  for (const p of VOICE_REQUEST_PHRASES) {\n"
    "    let i = t.indexOf(p)\n"
    "    while (i >= 0) {\n"
    "      const before = i > 0 ? t[i - 1] : undefined\n"
    "      const after = i + p.length < t.length ? t[i + p.length] : undefined\n"
    "      if (!_isVoiceWordChar(before) && !_isVoiceWordChar(after) && !_VOICE_REQUEST_NEGATION.test(t.slice(0, i))) {\n"
    "        return true\n"
    "      }\n"
    "      i = t.indexOf(p, i + 1)\n"
    "    }\n"
    "  }\n"
    "  return false\n"
    "}\n"
    "const _voiceCooldown = new Map<string, number>()\n"
    "function _voiceCooldownConsume(chatId: string): boolean {\n"
    "  const ts = _voiceCooldown.get(chatId)\n"
    "  _voiceCooldown.delete(chatId)\n"
    "  if (ts == null) return false\n"
    "  return Date.now() - ts < _VOICE_ORIGIN_TTL_MS\n"
    "}\n"
    "// agentic-pod-launcher: voice helpers end (033)\n"
)

# 032 V1: full replacement of the upstream `bot.on('message:voice')` handler
# body. Cheap checks first (activation, DM-only pre-check, caps), then ONE
# fire-and-forget typing action, then a DETACHED download+STT pipeline — the
# handler itself never awaits it (grammY processes updates sequentially; an
# in-handler 30s await would freeze the whole channel). Any failure path
# converges on the SAME placeholder call upstream used, so a broken voice
# pipeline degrades to exactly today's behaviour.
VOICE_HANDLER = (
    "bot.on('message:voice', async ctx => {\n"
    "  // agentic-pod-launcher: voice roundtrip inbound pipeline (032)\n"
    "  const voice = ctx.message.voice\n"
    "  const chat_id = String(ctx.chat!.id)\n"
    "  const placeholder = async (suffix?: string) => {\n"
    "    await handleInbound(ctx, (ctx.message.caption ?? '(voice message)') + (suffix ?? ''), undefined, {\n"
    "      kind: 'voice',\n"
    "      file_id: voice.file_id,\n"
    "      size: voice.file_size,\n"
    "      mime: voice.mime_type,\n"
    "    })\n"
    "  }\n"
    "  if (!VOICE_ACTIVE) {\n"
    "    await placeholder()\n"
    "    return\n"
    "  }\n"
    "  const access = loadAccess()\n"
    "  const from = ctx.from\n"
    "  const isDm =\n"
    "    ctx.chat?.type === 'private' &&\n"
    "    access.dmPolicy !== 'disabled' &&\n"
    "    from != null &&\n"
    "    access.allowFrom.includes(String(from.id))\n"
    "  if (!isDm) {\n"
    "    await placeholder()\n"
    "    return\n"
    "  }\n"
    "  if (voice.duration && voice.duration > VOICE_MAX_NOTE_SECONDS) {\n"
    "    process.stderr.write(`telegram channel: voice stt skip: over-cap chat=${chat_id} dur=${voice.duration}s\\n`)\n"
    "    await placeholder(' (voice note over the transcription limit)')\n"
    "    return\n"
    "  }\n"
    "  if (voice.file_size && voice.file_size > VOICE_MAX_BYTES) {\n"
    "    process.stderr.write(`telegram channel: voice stt skip: over-cap chat=${chat_id} size=${voice.file_size}\\n`)\n"
    "    await placeholder(' (voice note over the transcription limit)')\n"
    "    return\n"
    "  }\n"
    "  void bot.api.sendChatAction(chat_id, 'typing').catch(() => {\n"
    "    process.stderr.write('telegram channel: voice typing indicator failed\\n')\n"
    "  })\n"
    "  void (async () => {\n"
    "    const started = Date.now()\n"
    "    const controller = new AbortController()\n"
    "    const timer = setTimeout(() => controller.abort(), 30000)\n"
    "    try {\n"
    "      const file = await ctx.api.getFile(voice.file_id)\n"
    "      if (!file.file_path) throw new Error('no-file-path')\n"
    "      const url = `https://api.telegram.org/file/bot${TOKEN}/${file.file_path}`\n"
    "      const res = await fetch(url, { signal: controller.signal })\n"
    "      if (!res.ok) throw new Error(`download-status-${res.status}`)\n"
    "      const buf = Buffer.from(await res.arrayBuffer())\n"
    "      if (buf.length > VOICE_MAX_BYTES) {\n"
    "        process.stderr.write(`telegram channel: voice stt skip: over-cap chat=${chat_id} bytes=${buf.length}\\n`)\n"
    "        await placeholder(' (voice note over the transcription limit)')\n"
    "        return\n"
    "      }\n"
    "      const transcript = await _voiceTranscribe(buf, controller.signal)\n"
    "      if (!transcript) {\n"
    "        process.stderr.write(`telegram channel: voice stt fail: empty chat=${chat_id}\\n`)\n"
    "        await placeholder()\n"
    "        return\n"
    "      }\n"
    "      process.stderr.write(`telegram channel: voice stt ok chat=${chat_id} dur=${voice.duration ?? 0}s chars=${transcript.length} ms=${Date.now() - started}\\n`)\n"
    "      _voiceOriginSet(chat_id)\n"
    "      await handleInbound(ctx, transcript, undefined, {\n"
    "        kind: 'voice',\n"
    "        file_id: voice.file_id,\n"
    "        size: voice.file_size,\n"
    "        mime: voice.mime_type,\n"
    "      })\n"
    "    } catch (err) {\n"
    "      const { cls, status } = _voiceErrClass(err)\n"
    "      process.stderr.write(`telegram channel: voice stt fail: ${cls} status=${status} chat=${chat_id}\\n`)\n"
    "      await placeholder()\n"
    "    } finally {\n"
    "      clearTimeout(timer)\n"
    "    }\n"
    "  })()\n"
    "})\n"
)

# 033: frozen v1 twin — see VOICE_HELPERS_V1.
VOICE_TEXT_WRAP_V1 = (
    "bot.on('message:text', async ctx => {\n"
    "  // agentic-pod-launcher: voice roundtrip (032) — typed message ends the voice-origin exchange\n"
    "  _voiceOriginClear(String(ctx.chat!.id))\n"
    "  await handleInbound(ctx, ctx.message.text, undefined)\n"
    "})\n"
)

# 032 V6 / 033 US4: a typed message ends a voice-originated exchange — clear
# the origin flag first (verbatim 032 line, oracle-preserved) — then, if the
# message itself is an explicit audio request, mark a FRESH voice origin
# under the same 032 DM gate (private chat, DM policy not disabled, sender
# allowed) plus the feature/mode switches, so "responde con audio" behaves
# exactly like an inbound voice note for the next reply (contract
# explicit-audio-request.md C2).
VOICE_TEXT_WRAP = (
    "bot.on('message:text', async ctx => {\n"
    "  // agentic-pod-launcher: voice roundtrip (032) — typed message ends the voice-origin exchange\n"
    "  _voiceOriginClear(String(ctx.chat!.id))\n"
    "  // agentic-pod-launcher: explicit audio request (033)\n"
    "  const access = loadAccess()\n"
    "  const isDm =\n"
    "    ctx.chat?.type === 'private' &&\n"
    "    access.dmPolicy !== 'disabled' &&\n"
    "    ctx.from != null &&\n"
    "    access.allowFrom.includes(String(ctx.from.id))\n"
    "  if (VOICE_ACTIVE && VOICE_REPLY_MODE !== 'never' && isDm && _voiceRequestMatch(ctx.message.text)) {\n"
    "    _voiceOriginSet(String(ctx.chat!.id))\n"
    "    process.stderr.write(`telegram channel: voice request detected chat=${ctx.chat!.id}\\n`)\n"
    "  }\n"
    "  await handleInbound(ctx, ctx.message.text, undefined)\n"
    "})\n"
)

# 033: frozen v1 twins — see VOICE_HELPERS_V1. `_REPLY_RETURN_V1` is the
# pristine upstream return line hunk4 prepended VOICE_REPLY_BLOCK_V1 before
# (never rewritten); the pair is matched CONTIGUOUS in an already-patched
# file (contract voice-group-v2-upgrade.md C1).
VOICE_REPLY_BLOCK_V1 = (
    "        // agentic-pod-launcher: voice roundtrip outbound synthesis (032)\n"
    "        if (VOICE_ACTIVE && VOICE_REPLY_MODE !== 'never') {\n"
    "          const _voiceFresh = _voiceOriginConsume(chat_id)\n"
    "          if (VOICE_REPLY_MODE === 'always' || _voiceFresh) {\n"
    "            const voiceTextArg = args.voice_text as string | undefined\n"
    "            const spoken = voiceTextArg && voiceTextArg.trim()\n"
    "              ? voiceTextArg.trim()\n"
    "              : _voiceTruncate(text, VOICE_SPOKEN_CHAR_CAP)\n"
    "            const _voiceStarted = Date.now()\n"
    "            const _voiceController = new AbortController()\n"
    "            const _voiceTimer = setTimeout(() => _voiceController.abort(), 30000)\n"
    "            try {\n"
    "              const { buf, fmt } = await _voiceSynthesize(spoken, _voiceController.signal)\n"
    "              await bot.api.sendVoice(chat_id, new InputFile(buf, `voice.${fmt}`))\n"
    "              process.stderr.write(`telegram channel: voice tts ok chat=${chat_id} chars=${spoken.length} fmt=${fmt} ms=${Date.now() - _voiceStarted}\\n`)\n"
    "            } catch (err) {\n"
    "              const { cls, status } = _voiceErrClass(err)\n"
    "              process.stderr.write(`telegram channel: voice tts fail: ${cls} status=${status} chat=${chat_id}\\n`)\n"
    "            } finally {\n"
    "              clearTimeout(_voiceTimer)\n"
    "            }\n"
    "          }\n"
    "        }\n"
)
_REPLY_RETURN_V1 = "        return { content: [{ type: 'text', text: result }] }\n"
_REPLY_RETURN_V2 = "        return { content: [{ type: 'text', text: result + _voiceOutcome }] }\n"

# 034: frozen v2 twin — see VOICE_HELPERS_V2. Paired CONTIGUOUS with _REPLY_RETURN_V2.
VOICE_REPLY_BLOCK_V2 = (
    "        // agentic-pod-launcher: voice roundtrip outbound synthesis (032)\n"
    "        let _voiceOutcome = ''\n"
    "        if (VOICE_ACTIVE && VOICE_REPLY_MODE !== 'never') {\n"
    "          const _voiceFresh = _voiceOriginConsume(chat_id)\n"
    "          const _voiceForce = args.voice_force === true\n"
    "          if (VOICE_REPLY_MODE === 'always' || _voiceFresh || _voiceForce) {\n"
    "            if (VOICE_REPLY_MODE === 'always' && _voiceCooldownConsume(chat_id)) {\n"
    "              process.stderr.write(`telegram channel: voice skip: cooldown after failure chat=${chat_id}\\n`)\n"
    "            } else {\n"
    "            const voiceTextArg = args.voice_text as string | undefined\n"
    "            const _voiceFromText = !(voiceTextArg && voiceTextArg.trim())\n"
    "            const spoken = _voiceFromText\n"
    "              ? _voiceTruncate(text, VOICE_SPOKEN_CHAR_CAP)\n"
    "              : (voiceTextArg as string).trim()\n"
    "            const _voiceStarted = Date.now()\n"
    "            let _voiceStep: 'synth' | 'send' = 'synth'\n"
    "            const _voiceController = new AbortController()\n"
    "            const _voiceTimer = setTimeout(() => _voiceController.abort(), 30000)\n"
    "            try {\n"
    "              const { buf, fmt } = await _voiceSynthesize(spoken, _voiceController.signal)\n"
    "              _voiceStep = 'send'\n"
    "              await bot.api.sendVoice(chat_id, new InputFile(buf, `voice.${fmt}`), undefined, _voiceController.signal)\n"
    "              const _voiceMs = Date.now() - _voiceStarted\n"
    "              process.stderr.write(`telegram channel: voice tts ok chat=${chat_id} chars=${spoken.length} fmt=${fmt} ms=${_voiceMs}\\n`)\n"
    "              _voiceOutcome = `\\nvoice: sent (fmt=${fmt}, chars=${spoken.length}, ms=${_voiceMs})`\n"
    "              if (_voiceFromText) {\n"
    "                process.stderr.write(`telegram channel: voice tts spoke ${spoken.length} chars without voice_text chat=${chat_id}\\n`)\n"
    "                if (spoken.length > VOICE_OMISSION_NAG_CHARS) {\n"
    "                  _voiceOutcome += `; voice_text omitted — ${spoken.length} chars of text were read aloud`\n"
    "                }\n"
    "              }\n"
    "            } catch (err) {\n"
    "              const { cls, status } = _voiceErrClass(err)\n"
    "              if (VOICE_REPLY_MODE === 'always') _voiceCooldown.set(chat_id, Date.now())\n"
    "              process.stderr.write(`telegram channel: voice tts fail: ${cls} status=${status} step=${_voiceStep} chat=${chat_id}\\n`)\n"
    "              _voiceOutcome = `\\nvoice: failed (step=${_voiceStep}, cls=${cls}, status=${status})`\n"
    "            } finally {\n"
    "              clearTimeout(_voiceTimer)\n"
    "            }\n"
    "            }\n"
    "          }\n"
    "        }\n"
)

# 032 V2: voice-synthesis block in `case 'reply'`, anchored on the case's
# final return — i.e. AFTER the 028 marker-clear/offset-ack site and the
# files loop (remediated 2026-09-06: a crash here can no longer strand the
# marker or the offset ack). Consume-on-read happens before synthesis is
# attempted; a failure here never throws — it only costs the voice bubble.
#
# 033 (US1/US3/US4): extends the 032 body to build `_voiceOutcome` — the
# fed-back acknowledgement line the agent reads, in the SAME turn, to learn
# what its own voice did (spec 033 FR-001..FR-003, FR-008). `_voiceOutcome`
# is declared empty right after the comment and concatenated onto `result`
# at the case's return (via `_REPLY_RETURN_V2`); when the voice step never
# runs it stays `''`, so the acknowledgement is byte-identical to v0.23.0
# (FR-002). `_voiceStep` discriminates synthesis from the Telegram send so a
# failure names which leg broke (contract reply-voice-outcome.md C1/C3).
#
# 034 (US4): the rendition — voice_text or, when omitted, `text` — goes
# through `_voiceSpokenAssemble` (spoken-safe normalization, sign-off strip,
# sentence-boundary cut at the budget, sign-off appended once); `spoken` is
# what the synthesizer gets. The 033 omission record and nag are re-based on
# the NARRATED length (sign-off excluded — the 033 meaning), and a `voice_text`
# the channel had to cut earns the new `; voice_text trimmed to N chars` note.
# Everything else is byte-identical to v2 (pipeline contract C6/C7).
VOICE_REPLY_BLOCK = (
    "        // agentic-pod-launcher: voice roundtrip outbound synthesis (032)\n"
    "        let _voiceOutcome = ''\n"
    "        if (VOICE_ACTIVE && VOICE_REPLY_MODE !== 'never') {\n"
    "          const _voiceFresh = _voiceOriginConsume(chat_id)\n"
    "          const _voiceForce = args.voice_force === true\n"
    "          if (VOICE_REPLY_MODE === 'always' || _voiceFresh || _voiceForce) {\n"
    "            if (VOICE_REPLY_MODE === 'always' && _voiceCooldownConsume(chat_id)) {\n"
    "              process.stderr.write(`telegram channel: voice skip: cooldown after failure chat=${chat_id}\\n`)\n"
    "            } else {\n"
    "            const voiceTextArg = args.voice_text as string | undefined\n"
    "            const _voiceFromText = !(voiceTextArg && voiceTextArg.trim())\n"
    "            const _voiceAsm = _voiceSpokenAssemble(_voiceFromText ? text : (voiceTextArg as string).trim())\n"
    "            const spoken = _voiceAsm.spoken\n"
    "            const _voiceStarted = Date.now()\n"
    "            let _voiceStep: 'synth' | 'send' = 'synth'\n"
    "            const _voiceController = new AbortController()\n"
    "            const _voiceTimer = setTimeout(() => _voiceController.abort(), 30000)\n"
    "            try {\n"
    "              const { buf, fmt } = await _voiceSynthesize(spoken, _voiceController.signal)\n"
    "              _voiceStep = 'send'\n"
    "              await bot.api.sendVoice(chat_id, new InputFile(buf, `voice.${fmt}`), undefined, _voiceController.signal)\n"
    "              const _voiceMs = Date.now() - _voiceStarted\n"
    "              process.stderr.write(`telegram channel: voice tts ok chat=${chat_id} chars=${spoken.length} fmt=${fmt} ms=${_voiceMs}\\n`)\n"
    "              _voiceOutcome = `\\nvoice: sent (fmt=${fmt}, chars=${spoken.length}, ms=${_voiceMs})`\n"
    "              if (_voiceFromText) {\n"
    "                process.stderr.write(`telegram channel: voice tts spoke ${_voiceAsm.narrated.length} chars without voice_text chat=${chat_id}\\n`)\n"
    "                if (_voiceAsm.narrated.length > VOICE_OMISSION_NAG_CHARS) {\n"
    "                  _voiceOutcome += `; voice_text omitted — ${_voiceAsm.narrated.length} chars of text were read aloud`\n"
    "                }\n"
    "              } else if (_voiceAsm.trimmed) {\n"
    "                _voiceOutcome += `; voice_text trimmed to ${_voiceAsm.narrated.length} chars`\n"
    "              }\n"
    "            } catch (err) {\n"
    "              const { cls, status } = _voiceErrClass(err)\n"
    "              if (VOICE_REPLY_MODE === 'always') _voiceCooldown.set(chat_id, Date.now())\n"
    "              process.stderr.write(`telegram channel: voice tts fail: ${cls} status=${status} step=${_voiceStep} chat=${chat_id}\\n`)\n"
    "              _voiceOutcome = `\\nvoice: failed (step=${_voiceStep}, cls=${cls}, status=${status})`\n"
    "            } finally {\n"
    "              clearTimeout(_voiceTimer)\n"
    "            }\n"
    "            }\n"
    "          }\n"
    "        }\n"
)

# 033: frozen v1 twin — see VOICE_HELPERS_V1.
VOICE_SCHEMA_PROPERTY_V1 = (
    "          voice_text: {\n"
    "            type: 'string',\n"
    "            description:\n"
    "              'Optional spoken-style rendition of this reply, used to synthesize the voice bubble when the exchange is voice-originated. Plain speakable prose — no markdown, no code. When omitted, a truncated version of `text` is spoken.',\n"
    "          },\n"
)

# 034: frozen v2 twin — see VOICE_HELPERS_V2.
VOICE_SCHEMA_PROPERTY_V2 = (
    "          voice_text: {\n"
    "            type: 'string',\n"
    "            description:\n"
    "              'Spoken-style rendition of this reply, synthesized as the voice bubble whenever the exchange is voice-originated (voice note or explicit audio request) or voice_force is set. Plain speakable prose — no markdown, no code, no lists. Strongly recommended: when omitted, `text` itself is read aloud up to the spoken cap and the reply result reports the omission.',\n"
    "          },\n"
    "          voice_force: {\n"
    "            type: 'boolean',\n"
    "            description:\n"
    "              'Force this reply to also be sent as a voice bubble even though the user typed. Set ONLY when the user asked for an audio reply in wording the channel did not recognise. Never set it by default.',\n"
    "          },\n"
)

# 032 V3 / 033 US2/US4: optional voice_text property plus voice_force — the
# strict per-reply escape hatch for wording the fixed phrase table doesn't
# recognise (contract reply-voice-outcome.md C5, explicit-audio-request.md
# C3). voice_text's v3 description (034) states the spoken-style contract:
# a SUMMARY in the configured language under the spoken limit, no closing
# phrase (the channel appends it), and the cleaned sentence-cut fallback
# when omitted (contract spoken-style-contract.md C2).
VOICE_SCHEMA_PROPERTY = (
    "          voice_text: {\n"
    "            type: 'string',\n"
    "            description:\n"
    "              'Spoken SUMMARY of this reply, synthesized as the voice bubble whenever the exchange is voice-originated (voice note or explicit audio request) or voice_force is set. Plain spoken prose in the configured language, about 30 seconds (~450 characters) by default and never above the spoken limit stated in the channel instructions; no markdown, code, lists, emojis or URLs; figures in words, every amount followed by its currency name; no closing phrase (the channel appends it). When omitted, a cleaned, sentence-cut version of `text` is read aloud and the reply result reports the omission.',\n"
    "          },\n"
    "          voice_force: {\n"
    "            type: 'boolean',\n"
    "            description:\n"
    "              'Force this reply to also be sent as a voice bubble even though the user typed. Set ONLY when the user asked for an audio reply in wording the channel did not recognise. Never set it by default.',\n"
    "          },\n"
)

# 033: frozen v1 twin — see VOICE_HELPERS_V1.
VOICE_INSTRUCTIONS_LINE_V1 = (
    "      'Messages whose meta carries attachment_kind=\"voice\" arrive transcribed — the message text IS the transcription. When replying to them, include voice_text with a concise speakable version of your answer.',\n"
)

# 034: frozen v2 twin — see VOICE_HELPERS_V2.
VOICE_INSTRUCTIONS_LINE_V2 = (
    "      'Voice replies: when a message arrives transcribed (meta attachment_kind=\"voice\") or the user explicitly asks for an audio reply, this channel AUTOMATICALLY sends your reply as a voice note too — never tell the user you cannot send audio, and answer in ONE reply call (only the first reply of the exchange is spoken). Always include voice_text with a concise speakable version of your answer (plain prose, no markdown, no lists); if you omit it, your full text is read aloud up to the cap. The reply result carries a \"voice:\" line for your own awareness (sent/failed) — do not repeat it to the user; if it says failed, tell the user once, briefly, that the audio did not go out this time, and do not retry. If the user asks for audio in wording the channel did not recognise, set voice_force: true on that reply.',\n"
)

# 032 V4 / 033 US2 / 034 US1: one instructions-array line. v3 is a TEMPLATE
# LITERAL (backticks) interpolating three module-level constants declared by
# the helpers hunk (anchored at `let botUsername`, line 25 upstream — well
# before the `instructions:` array at line 97): the hard limit
# ${VOICE_SPOKEN_CHAR_CAP}, the language name ${VOICE_SPOKEN_LANG_NAME} and
# the currency word ${VOICE_CURRENCY}. It states the spoken-style contract
# (summary not dictation, 30/45/60 s tiers, plain prose, figures in words with
# the currency named, configured language, the channel — not the model —
# appends the closing phrase, omission/trim consequences) on top of the 033
# facts (automatic on voice notes AND explicit requests, never claim
# inability, one reply, outcome line is for the agent, one honest failure
# mention, voice_force) — contract spoken-style-contract.md C1.
VOICE_INSTRUCTIONS_LINE = (
    "      `Voice replies: when a message arrives transcribed (meta attachment_kind=\"voice\") or the user explicitly asks for an audio reply, this channel AUTOMATICALLY sends your reply as a voice note too — never tell the user you cannot send audio, and answer in ONE reply call (only the first reply of the exchange is spoken). ALWAYS include voice_text: a spoken SUMMARY of your answer, never your text read aloud — about 30 seconds (~450 characters) by default, up to ~45 seconds (~700) or at most ~60 seconds (${VOICE_SPOKEN_CHAR_CAP} characters, the hard limit) only when the amount of information warrants it; never enumerate a list item by item. Write it as plain spoken prose in ${VOICE_SPOKEN_LANG_NAME}: no markdown, code, lists, emojis or URLs; say figures, dates and percentages in words and follow every amount with its currency name (${VOICE_CURRENCY} for a bare amount). Do NOT write a closing phrase — the channel appends the configured sign-off itself. If you omit voice_text, a cleaned, sentence-cut version of your text is read aloud and the reply result says so; a voice_text over the limit is cut at a sentence and the result says so. The reply result carries a \"voice:\" line for your own awareness (sent/failed) — do not repeat it to the user; if it says failed, tell the user once, briefly, that the audio did not go out this time, and do not retry. If the user asks for audio in wording the channel did not recognise, set voice_force: true on that reply.`,\n"
)


def log(msg: str) -> None:
    print(f"[apply_telegram_typing_patch] {msg}", flush=True)


def warn(msg: str) -> None:
    # Anchor drift is operationally significant: the patch silently no-ops
    # and the plugin keeps default behavior. Emit on stderr so log scrapers
    # can flag it distinctly from the success path on stdout.
    print(f"[apply_telegram_typing_patch] WARN: {msg}", file=sys.stderr, flush=True)


def upgrade_typing_v1_to_v2(src: str) -> tuple[str, bool]:
    """Migrate a server.ts already patched with typing v1 to v2 in-place.

    The only behavioral diff between v1 and v2 is the 120s hard cap on the
    typing refresh interval (v1 had it, v2 doesn't — typing now persists for
    as long as the session is processing, stopping only on `case 'reply'` or
    process exit). Removing those exact 3 lines + bumping the marker is enough
    to upgrade an existing patched file without re-running the full patcher.

    Defensive: if the v1 helpers were edited out-of-band, the surgical regexes
    won't match and we leave the file untouched (returning False). Caller logs
    a warning so the operator notices the drift.

    This function is the v1→v2 step of the upgrade chain. After it runs,
    `upgrade_typing_v2_to_v3` picks up to add the v3 instrumentation.

    Returns (new_src, applied).
    """
    if MARKER_TYPING_V2 in src or MARKER_TYPING in src:  # already at v2 or beyond
        return src, False
    if MARKER_TYPING_V1 not in src:                      # never patched → no-op
        return src, False

    # 1) Remove the cap constant declaration.
    new_src, n1 = re.subn(r"const _TYPING_MAX_MS = 120000\n", "", src, count=1)
    # 2) Remove the cap setTimeout block (2 lines: setTimeout + unref).
    new_src, n2 = re.subn(
        r"  const cap = setTimeout\(\(\) => _typingStop\(chat_id\), _TYPING_MAX_MS\)\n"
        r"  ;\(cap as \{ unref\?: \(\) => void \}\)\.unref\?\.\(\)\n",
        "", new_src, count=1,
    )
    if n1 != 1 or n2 != 1:
        warn("v1→v2 upgrade anchors not found (helpers may have been edited out-of-band) — leaving v1 in place")
        return src, False

    # 3) Bump marker to v2 (NOT v3 — the v2→v3 upgrader runs next and
    #    handles the marker bump + helper rewrite together).
    new_src = new_src.replace(MARKER_TYPING_V1, MARKER_TYPING_V2)
    # 4) Update the inline comment at the call site to v2 wording.
    new_src = new_src.replace(
        "// Typing indicator — refreshed every 4s until reply fires, 120s hard cap.\n"
        "  // Patched by agentic-pod-launcher (telegram-typing v1).\n",
        "// Typing indicator — refreshed every 4s until reply fires (no cap; stops on reply or process exit).\n"
        "  // Patched by agentic-pod-launcher (telegram-typing v2).\n",
    )
    return new_src, True


def upgrade_typing_v2_to_v3(src: str) -> tuple[str, bool]:
    """Migrate a server.ts already patched with typing v2 to v3 in-place.

    The behavioral diff between v2 and v3 is observability: v3's _typingKeepAlive
    instruments each setInterval tick (logs every 5 ticks to stderr, tee'd to
    /workspace/scripts/heartbeat/logs/telegram-mcp-stderr.log) and surfaces
    sendChatAction errors instead of silently swallowing them via
    `.catch(() => {})`. The runtime contract is unchanged: same setInterval
    cadence, no cap, _typingStop only on `case 'reply'`.

    Implementation: the v2 helper block has a known shape. We delete the entire
    v2 marker line + helper functions, then inject the fresh TYPING_HELPERS
    block (which carries the v3 marker). The call-site swap and `_typingStop`
    in `case 'reply'` from earlier patches are unchanged so we don't touch them.

    Defensive: if the v2 marker isn't followed by the expected helper shape,
    the regex won't match and we leave the file at v2.

    Returns (new_src, applied).
    """
    if MARKER_TYPING in src:                # already at v3
        return src, False
    if MARKER_TYPING_V2 not in src:         # not at v2 → caller may have a v1 to upgrade first, or never patched
        return src, False

    # Remove the v2 marker comment + the v2 helper block (everything from the
    # v2 marker line through the end of `_typingStop`'s closing brace). The
    # v2 shape is:
    #   // agentic-pod-launcher: typing refresh patch v2
    #   const _typingIntervals = ...
    #   const _TYPING_REFRESH_MS = 4000
    #   function _typingKeepAlive(...) { ... }
    #   function _typingStop(...) { ... }
    pattern = (
        r"\n// " + re.escape(MARKER_TYPING_V2) + r"\n"
        r"const _typingIntervals[^\n]*\n"
        r"const _TYPING_REFRESH_MS = 4000\n"
        r"function _typingKeepAlive\(chat_id: string \| number\): void \{\n"
        r"(?:[^\n]*\n)+?"  # function body lines
        r"\}\n"
        r"function _typingStop\(chat_id: string \| number\): void \{\n"
        r"(?:[^\n]*\n)+?"
        r"\}\n"
    )
    new_src, n = re.subn(pattern, TYPING_HELPERS_V3, src, count=1)
    if n != 1:
        warn("v2→v3 upgrade anchors not found (helpers may have been edited out-of-band) — leaving v2 in place")
        return src, False

    # Update the inline comment at the call site to match v3 wording.
    new_src = new_src.replace(
        "// Typing indicator — refreshed every 4s until reply fires (no cap; stops on reply or process exit).\n"
        "  // Patched by agentic-pod-launcher (telegram-typing v2).\n",
        "// Typing indicator — refreshed every 4s until reply fires (no cap; stops on reply or process exit).\n"
        "  // Patched by agentic-pod-launcher (telegram-typing v3 — instrumented).\n",
    )
    return new_src, True


def upgrade_typing_v3_to_v4(src: str) -> tuple[str, bool]:
    """Migrate a server.ts already patched with typing v3 to v4 in-place.

    The behavioral diff between v3 and v4 is the anti-zombie timeout: v3's
    setInterval kept refreshing the typing indicator forever if `case 'reply'`
    never fired (typical OAuth-expired scenario). v4 caps the indicator at
    `_TYPING_MAX_DURATION_MS` (default 5 min, overridable via env
    TELEGRAM_TYPING_MAX_MS), aborts cleanly, sends the user a "tardé >Nm"
    message, and logs to stderr.

    Implementation: same shape as v2→v3 — replace the entire v3 helper block
    (from the v3 marker through the `_typingStop` closing brace) with the
    fresh TYPING_HELPERS block which carries the v4 marker.

    Defensive: if the v3 helper shape was edited out-of-band, the regex
    won't match and we leave the file at v3.

    Returns (new_src, applied).
    """
    if MARKER_TYPING in src:                # already at v4
        return src, False
    if MARKER_TYPING_V3 not in src:         # not at v3 → caller may have a v1/v2 to upgrade first
        return src, False

    # Remove the v3 marker comment + the v3 helper block. v3 shape:
    #   // agentic-pod-launcher: typing refresh patch v3
    #   const _typingIntervals = ...
    #   const _typingTickCounts = ...
    #   const _TYPING_REFRESH_MS = 4000
    #   function _typingKeepAlive(...) { ... }
    #   function _typingStop(...) { ... }
    pattern = (
        r"\n// " + re.escape(MARKER_TYPING_V3) + r"\n"
        r"const _typingIntervals[^\n]*\n"
        r"const _typingTickCounts[^\n]*\n"
        r"const _TYPING_REFRESH_MS = 4000\n"
        r"function _typingKeepAlive\(chat_id: string \| number\): void \{\n"
        r"(?:[^\n]*\n)+?"  # function body
        r"\}\n"
        r"function _typingStop\(chat_id: string \| number\): void \{\n"
        r"(?:[^\n]*\n)+?"
        r"\}\n"
    )
    new_src, n = re.subn(pattern, TYPING_HELPERS_V4, src, count=1)
    if n != 1:
        warn("v3→v4 upgrade anchors not found (helpers may have been edited out-of-band) — leaving v3 in place")
        return src, False

    # Update the inline comment at the call site.
    new_src = new_src.replace(
        "// Typing indicator — refreshed every 4s until reply fires (no cap; stops on reply or process exit).\n"
        "  // Patched by agentic-pod-launcher (telegram-typing v3 — instrumented).\n",
        "// Typing indicator — refreshed every 4s until reply fires; aborts after _TYPING_MAX_DURATION_MS (default 5min) with user-facing warning.\n"
        "  // Patched by agentic-pod-launcher (telegram-typing v4 — anti-zombie).\n",
    )
    return new_src, True


def upgrade_typing_v4_to_v5(src: str) -> tuple[str, bool]:
    """Migrate a server.ts already patched with typing v4 to v5 in-place.

    The behavioral diff between v4 and v5 is ONLY the timeout warning wording: v4
    asserted "es probable que el OAuth de Claude haya expirado"; v5 states the real
    uncertainty (a long turn still running, an answer produced WITHOUT calling the
    reply tool, or an expired login) + the diagnostic. Surgical, like v1→v2: swap the
    warnMsg line + bump the marker, without re-injecting the whole helper block.

    Defensive: if the v4 warnMsg was edited out-of-band the swap won't match and we
    leave the file at v4 (WARN). Returns (new_src, applied).
    """
    if MARKER_TYPING_V5 in src or MARKER_TYPING in src:  # already at v5 or beyond
        return src, False
    if MARKER_TYPING_V4 not in src:         # not at v4 → a v1/v2/v3 must upgrade first
        return src, False

    new_src = src.replace(_V4_WARNMSG, _V5_WARNMSG)
    if new_src == src:
        warn("v4→v5 upgrade: warnMsg anchor not found (message may have been edited out-of-band) — leaving v4 in place")
        return src, False

    # Bump the helper marker v4 → v5 and the call-site comment.
    new_src = new_src.replace(MARKER_TYPING_V4, MARKER_TYPING_V5)
    new_src = new_src.replace(
        "  // Patched by agentic-pod-launcher (telegram-typing v4 — anti-zombie).\n",
        "  // Patched by agentic-pod-launcher (telegram-typing v5 — honest timeout).\n",
    )
    return new_src, True


def upgrade_typing_v5_to_v6(src: str) -> tuple[str, bool]:
    """Migrate a server.ts already patched with typing v5 to v6 in-place (031).

    The behavioral diff between v5 and v6 is ONLY the timeout warning wording: v6
    additionally names "la sesión quedó bloqueada en un menú interactivo que el canal
    no puede responder" among the possible causes, still asserting no single definite
    one. Surgical, like v4→v5: swap the warnMsg line + bump the marker, without
    re-injecting the whole helper block.

    Defensive: if the v5 warnMsg was edited out-of-band the swap won't match and we
    leave the file at v5 (WARN). Returns (new_src, applied).
    """
    if MARKER_TYPING in src:                # already at v6
        return src, False
    if MARKER_TYPING_V5 not in src:         # not at v5 → a v1/v2/v3/v4 must upgrade first
        return src, False

    new_src = src.replace(_V5_WARNMSG, _V6_WARNMSG)
    if new_src == src:
        warn("v5→v6 upgrade: warnMsg anchor not found (message may have been edited out-of-band) — leaving v5 in place")
        return src, False

    # Bump the helper marker v5 → v6 and the call-site comment.
    new_src = new_src.replace(MARKER_TYPING_V5, MARKER_TYPING)
    new_src = new_src.replace(
        "  // Patched by agentic-pod-launcher (telegram-typing v5 — honest timeout).\n",
        "  // Patched by agentic-pod-launcher (telegram-typing v6 — names interactive-prompt cause).\n",
    )
    return new_src, True


def apply_typing(src: str) -> tuple[str, bool]:
    """Insert typing-refresh helpers + the call-site swap. Returns (new_src, applied)."""
    if MARKER_TYPING in src:
        return src, False
    new_src, n1 = re.subn(
        r"(let botUsername = ''\n)",
        r"\1" + TYPING_HELPERS,
        src,
        count=1,
    )
    if n1 != 1:
        warn("typing hunk1 anchor (let botUsername) not found — skipping typing patch (plugin keeps default typing behavior)")
        return src, False
    new_src, n2 = re.subn(
        r"  // Typing indicator — signals \"processing\" until we reply \(or ~5s elapses\)\.\n"
        r"  void bot\.api\.sendChatAction\(chat_id, 'typing'\)\.catch\(\(\) => \{\}\)",
        (
            "  // Typing indicator — refreshed every 4s until reply fires; aborts after _TYPING_MAX_DURATION_MS (default 5min) with user-facing warning.\n"
            "  // Patched by agentic-pod-launcher (telegram-typing v6 — names interactive-prompt cause).\n"
            "  _typingKeepAlive(chat_id)"
        ),
        new_src,
        count=1,
    )
    if n2 != 1:
        warn("typing hunk2 anchor (sendChatAction call) not found — skipping typing patch (plugin keeps default typing behavior)")
        return src, False
    new_src, n3 = re.subn(
        r"(case 'reply': \{\n"
        r"        const chat_id = args\.chat_id as string\n)",
        r"\1        _typingStop(chat_id) // agentic-pod-launcher: stop typing refresh\n",
        new_src,
        count=1,
    )
    if n3 != 1:
        warn("typing hunk3 anchor (reply case chat_id) not found — skipping typing patch (plugin keeps default typing behavior)")
        return src, False
    return new_src, True


def apply_offset(src: str) -> tuple[str, bool]:
    """Persist Telegram update_id offset to disk + replay on startup, ack-on-reply.

    Four hunks, all gated by MARKER_OFFSET:
      B1 — helpers + pendingUpdates Map (top-level declarations).
      B2 — pre-poll getUpdates with persisted offset before bot.start.
      B3 — _markPending in handleInbound right after chat_id is bound.
      B4 — _ackPending in case 'reply' right before the reply tool returns
            success, gated on the chunk loop having completed without throw.

    Why ack-on-reply (not on inbound delivery): an earlier middleware-based
    save advanced the offset as soon as bun forwarded the inbound to claude
    via MCP. If bun then died before claude could call the `reply` MCP tool
    (heartbeat-driven SIGTERM, MCP idle close, watchdog respawn, ...), the
    on-disk offset said "processed" so Telegram never redelivered, and the
    user got no answer. Acking only on a successful reply means Telegram
    redelivers anything claude didn't manage to reply to — at-least-once
    end-to-end instead of just at-least-once on inbound.

    Returns (new_src, applied).
    """
    if MARKER_OFFSET in src:
        return src, False
    # Hunk B1: helpers — anchor on `let botUsername = ''`. If the typing
    # patch already inserted after that line, this lands BETWEEN the original
    # line and the typing block. Order doesn't matter (both are top-level
    # declarations referencing `bot` which is created earlier on line 86).
    new_src, n1 = re.subn(
        r"(let botUsername = ''\n)",
        r"\1" + OFFSET_HELPERS,
        src,
        count=1,
    )
    if n1 != 1:
        warn("offset hunk1 anchor (let botUsername) not found — skipping offset patch (message loss across crashes will continue)")
        return src, False
    # Hunk B2: pre-position Telegram cursor server-side BEFORE bot.start.
    # Grammy's bot.start does not accept an offset option (PollingOptions
    # only exposes limit/timeout/allowed_updates/drop_pending_updates/onStart),
    # so we fire one synchronous getUpdates with the persisted offset right
    # before bot.start to confirm everything < offset and have Telegram
    # return updates >= offset on the next poll.
    new_src, n2 = re.subn(
        r"(      await bot\.start\(\{\n)",
        OFFSET_REPLAY + r"\1",
        new_src,
        count=1,
    )
    if n2 != 1:
        warn("offset hunk2 anchor (await bot.start) not found — skipping offset patch (message loss across crashes will continue)")
        return src, False
    # Hunk B3: mark the inbound as pending in handleInbound, right after
    # chat_id is bound. Every inbound (text/photo/document/voice/...) flows
    # through handleInbound, so this single injection covers all of them.
    # `ctx.update.update_id` is always populated for bot updates.
    new_src, n3 = re.subn(
        r"(  const chat_id = String\(ctx\.chat!\.id\)\n)",
        r"\1" + OFFSET_MARK,
        new_src,
        count=1,
    )
    if n3 != 1:
        warn("offset hunk3 anchor (handleInbound chat_id) not found — skipping offset patch (message loss across crashes will continue)")
        return src, False
    # Hunk B4: ack the pending update in case 'reply', gated on the chunk
    # loop having completed without throw (anchor right before `const result`,
    # which only runs after the for-loop's catch block didn't re-throw and
    # any file attachments were sent). On reply error, the catch re-throws
    # before we get here — offset stays unadvanced, Telegram redelivers next
    # time bun reattaches. The `chat_id` in scope here is the reply tool's
    # `args.chat_id as string`, the same key shape used by _markPending.
    new_src, n4 = re.subn(
        r"(        const result =\n          sentIds\.length === 1\n)",
        OFFSET_ACK + r"\1",
        new_src,
        count=1,
    )
    if n4 != 1:
        warn("offset hunk4 anchor (case 'reply' result) not found — skipping offset patch (message loss across crashes will continue)")
        return src, False
    return new_src, True


def apply_pending_marker(src: str) -> tuple[str, bool]:
    """Write/clear the pending-reply marker (028). Returns (new_src, applied).

    Three hunks, all gated by MARKER_PENDING and fail-silent on anchor drift:
      P1 — helpers (_markPendingReply / _clearPendingReply), anchored on
            `let botUsername = ''` (same top-level anchor as typing/offset; all
            stack after that line, order-independent).
      P2 — write the marker in handleInbound, at the same `chat_id` binding the
            offset patch marks pending at (so every inbound is covered).
      P3 — clear the marker in case 'reply', right before the offset ack site, so
            a successful reply removes the awaiting-reply signal.

    The Stop hook (scripts/hooks/stop-redeliver.sh) keys on this marker's existence.
    If any anchor drifts, this patch skips (WARN) and the reply guard degrades to a
    no-op (marker never appears → hook never fires) — safe, not broken.
    """
    if MARKER_PENDING in src:
        return src, False
    new_src, n1 = re.subn(
        r"(let botUsername = ''\n)",
        r"\1" + PENDING_HELPERS,
        src,
        count=1,
    )
    if n1 != 1:
        warn("pending-marker hunk1 anchor (let botUsername) not found — skipping pending-reply marker patch (reply guard has no channel-origin signal)")
        return src, False
    new_src, n2 = re.subn(
        r"(  const chat_id = String\(ctx\.chat!\.id\)\n)",
        r"\1" + PENDING_MARK,
        new_src,
        count=1,
    )
    if n2 != 1:
        warn("pending-marker hunk2 anchor (handleInbound chat_id) not found — skipping pending-reply marker patch")
        return src, False
    new_src, n3 = re.subn(
        r"(        const result =\n          sentIds\.length === 1\n)",
        PENDING_CLEAR + r"\1",
        new_src,
        count=1,
    )
    if n3 != 1:
        warn("pending-marker hunk3 anchor (case 'reply' result) not found — skipping pending-reply marker patch")
        return src, False
    return new_src, True


def apply_askq_giveup(src: str) -> tuple[str, bool]:
    """Wire the AskUserQuestion guard give-up delivery into the typing keep-alive
    (031). Returns (new_src, applied).

    Three hunks, all gated by MARKER_ASKQ_GIVEUP and rolled back together on any
    anchor miss (an unpaired trigger would silently never deliver a give-up, or
    would try to send from a helper that was never injected):
      G1 — helpers (_checkAskqGiveup / _ASKQ_GIVEUP_FILE), anchored on
            `let botUsername = ''` (same top-level anchor as every other patch;
            all stack after that line, order-independent).
      G2 — check on every keep-alive tick, anchored on the sendChatAction call
            inside the (already-installed, v4/v5/v6-shape) typing helpers.
      G3 — check at the START of _typingKeepAlive, the safety net for a marker
            written after the current turn's last tick.

    Runs AFTER the typing upgrade cascade + apply_typing in main(), so by the
    time this fires the file's typing helpers are always in their final v6-era
    shape (v4→v5→v6 are surgical text swaps that don't touch these anchors).
    """
    if MARKER_ASKQ_GIVEUP in src:
        return src, False
    new_src, n1 = re.subn(
        r"(let botUsername = ''\n)",
        r"\1" + ASKQ_GIVEUP_HELPERS,
        src,
        count=1,
    )
    if n1 != 1:
        warn("askq give-up hunk1 anchor (let botUsername) not found — skipping askq-guard give-up patch (give-up would never be delivered)")
        return src, False
    new_src, n2 = re.subn(
        r"    bot\.api\.sendChatAction\(chat_id, 'typing'\)\n",
        ASKQ_GIVEUP_TICK_CHECK,
        new_src,
        count=1,
    )
    if n2 != 1:
        warn("askq give-up hunk2 anchor (sendChatAction tick) not found — skipping askq-guard give-up patch")
        return src, False
    new_src, n3 = re.subn(
        r"function _typingKeepAlive\(chat_id: string \| number\): void \{\n",
        ASKQ_GIVEUP_START_CHECK,
        new_src,
        count=1,
    )
    if n3 != 1:
        warn("askq give-up hunk3 anchor (_typingKeepAlive start) not found — skipping askq-guard give-up patch")
        return src, False
    return new_src, True


def apply_stderr(src: str) -> tuple[str, bool]:
    """Tee process.stderr to disk + log uncaught/unhandled. Returns (new_src, applied)."""
    if MARKER_STDERR in src:
        return src, False
    # Anchor BEFORE `const TOKEN = process.env.TELEGRAM_BOT_TOKEN`. That sits
    # right after the import block + .env loader try/catch, and BEFORE the
    # `if (!TOKEN) { process.stderr.write(...); process.exit(1) }` block,
    # so a missing-token death also gets captured in the stderr log.
    new_src, n = re.subn(
        r"(\nconst TOKEN = )",
        "\n" + STDERR_HOOK + r"\1",
        src,
        count=1,
    )
    if n != 1:
        warn("stderr hunk anchor (const TOKEN =) not found — skipping stderr-capture patch (no forensic evidence on next crash)")
        return src, False
    return new_src, True


def apply_primary(src: str) -> tuple[str, bool]:
    """Turn the upstream stale-poller block into a primary-secondary lock.

    Two hunks, both gated by MARKER_PRIMARY:
      C1 — guard before `process.kill(stale, 'SIGTERM')`. Reads
            statSync(PID_FILE).mtimeMs; if the file was modified within
            the last 30s, the existing PID is a live primary refreshing
            its heartbeat (see C2) and we are a secondary instance —
            spawned by a sub-claude (claude-mem worker, Task subagent),
            a heartbeat session, or any other claude process that loaded
            the telegram plugin. Exit cleanly without taking over.
      C2 — append a setInterval that re-writes PID_FILE every 5s so
            the file's mtime stays fresh while we run.

    Without this, every sub-claude spawn results in: new bun → SIGTERM
    primary → primary dies mid-turn → user gets no reply. The watchdog
    eventually catches the dead bun and respawns, but the active turn's
    reply is gone.

    Returns (new_src, applied).
    """
    if MARKER_PRIMARY in src:
        return src, False
    # Hunk C1: insert mtime guard between the kill(stale, 0) liveness probe
    # and the SIGTERM. The probe throws when the PID is dead — if we reach
    # past it, stale is alive AND we either need to take over (mtime stale)
    # OR step aside (mtime fresh).
    new_src, n1 = re.subn(
        r"(    process\.kill\(stale, 0\)\n)",
        r"\1" + PRIMARY_GUARD,
        src,
        count=1,
    )
    if n1 != 1:
        warn("primary hunk1 anchor (process.kill(stale, 0)) not found — skipping primary-lock patch (sub-claude bun spawns will continue to kill primary)")
        return src, False
    # Hunk C2: append the heartbeat setInterval after the initial PID_FILE
    # write. A blank line separates it from the surrounding upstream code
    # for readability.
    new_src, n2 = re.subn(
        r"(writeFileSync\(PID_FILE, String\(process\.pid\)\)\n)",
        r"\1" + "\n" + PRIMARY_HEARTBEAT,
        new_src,
        count=1,
    )
    if n2 != 1:
        warn("primary hunk2 anchor (writeFileSync PID_FILE) not found — skipping primary-lock patch (sub-claude bun spawns will continue to kill primary)")
        return src, False
    return new_src, True


def upgrade_voice_v1_to_v2(src: str) -> tuple[str, bool]:
    """Migrate a server.ts already patched with voice v1 (032) to v2 (033) in-place.

    Five ordered pairs, each an exact-substring match: helpers, text wrap,
    reply block + its return line (rewritten together — v2 changes the
    return expression to feed `_voiceOutcome` back to the agent), schema
    property, instructions line. All-or-nothing: if any `old` text isn't
    found EXACTLY once, the whole upgrade aborts (WARN) and the file stays
    at v1 rather than landing half-upgraded with helpers referencing symbols
    a stale reply block or wrap doesn't know about.

    Defensive: if a v1 constant was edited out-of-band (an operator hand-fix,
    a future patch drifting an anchor), `work.count(old) != 1` catches it —
    both "not found" and "found more than once" are refused, since a
    non-unique match could rewrite the wrong occurrence.

    Returns (new_src, applied).
    """
    if MARKER_VOICE in src or MARKER_VOICE_V2 in src:   # already at v2 or beyond
        return src, False
    if MARKER_VOICE_V1 not in src:     # never patched with voice → nothing to upgrade
        return src, False

    # 034: re-pointed to the frozen _V2 twins — this upgrader now produces EXACTLY
    # the v0.24.0 output (golden v2) and `upgrade_voice_v2_to_v3` takes it the
    # rest of the way; the cascade v1→v2→v3 runs in one boot.
    pairs = (
        (VOICE_HELPERS_V1, VOICE_HELPERS_V2),
        (VOICE_TEXT_WRAP_V1, VOICE_TEXT_WRAP),
        (VOICE_REPLY_BLOCK_V1 + _REPLY_RETURN_V1, VOICE_REPLY_BLOCK_V2 + _REPLY_RETURN_V2),
        (VOICE_SCHEMA_PROPERTY_V1, VOICE_SCHEMA_PROPERTY_V2),
        (VOICE_INSTRUCTIONS_LINE_V1, VOICE_INSTRUCTIONS_LINE_V2),
    )
    work = src
    for n, (old, new) in enumerate(pairs, 1):
        if work.count(old) != 1:
            warn(f"voice v1→v2 upgrade: hunk {n} anchor not found (edited out-of-band?) — leaving v1 in place")
            return src, False
        work = work.replace(old, new, 1)
    return work, True


def upgrade_voice_v2_to_v3(src: str) -> tuple[str, bool]:
    """Migrate a server.ts already patched with voice v2 (033) to v3 (034) in-place.

    Four ordered pairs (helpers, reply block, schema property, instructions
    line — the text wrap is unchanged between v2 and v3), each an exact
    substring match against the frozen `_V2` twins. All-or-nothing with the
    same defensive `work.count(old) != 1` rule as the v1→v2 upgrader: any
    miss (edited out-of-band, duplicated) aborts the whole upgrade with a
    WARN and leaves the file at v2 — functional, just not v3.

    Plain `str.replace`, never a regex: the constants carry backslash
    sequences (research D14) and must reach the file verbatim.

    Returns (new_src, applied).
    """
    if MARKER_VOICE_V2 not in src:     # not at v2 (pristine, v1, or already v3)
        return src, False
    pairs = (
        (VOICE_HELPERS_V2, VOICE_HELPERS),
        (VOICE_REPLY_BLOCK_V2, VOICE_REPLY_BLOCK),
        (VOICE_SCHEMA_PROPERTY_V2, VOICE_SCHEMA_PROPERTY),
        (VOICE_INSTRUCTIONS_LINE_V2, VOICE_INSTRUCTIONS_LINE),
    )
    work = src
    for n, (old, new) in enumerate(pairs, 1):
        if work.count(old) != 1:
            warn(f"voice v2→v3 upgrade: constant {n} not found exactly once (edited out-of-band?) — leaving v2 in place")
            return src, False
        work = work.replace(old, new, 1)
    return work, True


def apply_voice(src: str) -> tuple[str, bool]:
    """Close the voice loop over the Telegram channel (032). Returns (new_src, applied).

    Six hunks, all gated by MARKER_VOICE and rolled back together on any anchor
    miss (an unpaired hunk would mean helpers reference undefined symbols, or a
    handler replacement missing its dependencies):
      V5 — module-scope helpers (config read + ONE-TIME boot line, redacting
            error-class helper, STT/TTS fetch helpers, voice-origin map,
            format-sniff cache, truncation helper), anchored on
            `let botUsername = ''` (same top-level anchor as every other
            group; all stack after that line, order-independent).
      V1 — replace the `bot.on('message:voice')` handler body: DM-only
            read-only pre-check, absent-metadata-safe caps, fire-and-forget
            typing action, then a DETACHED download+STT pipeline (the handler
            itself never awaits it). Any failure falls back to today's exact
            placeholder call.
      V6 — wrap `bot.on('message:text')`: clear the voice-origin flag first,
            then the upstream body runs unchanged.
      V2 — voice-synthesis block in `case 'reply'`, anchored on the case's
            final `return` — i.e. AFTER the 028 marker-clear/offset-ack site
            and the files loop.
      V3 — optional `voice_text` property in the reply tool's inputSchema.
      V4 — one instructions-array line steering the agent to provide
            voice_text when replying to a voice-originated message.

    Runs independently of the typing cascade and every other group; if any
    anchor has drifted, the whole group skips (WARN) and the plugin keeps
    today's exact behaviour (voice never activates).
    """
    # NOTE: every substitution below uses a lambda replacement, never a raw
    # string. The voice constants contain literal backslash sequences
    # (`\n` inside JS template-literal stderr writes, `\d` inside a JS
    # regex) — passed as a plain `re.subn` replacement string, Python's own
    # template-escape parser reinterprets those: `\n` silently becomes a
    # real newline and `\d` is a hard "bad escape" crash (same bug class as
    # 023's bash `${var//pattern/replacement}` footgun, different language).
    # A lambda receives the match object and returns the string verbatim —
    # zero escape processing, so the constants stay editable JS without an
    # escaping ritual.
    if MARKER_VOICE in src or MARKER_VOICE_V1 in src or MARKER_VOICE_V2 in src:
        # Already applied at some version (a refused upgrade leaves v1/v2 in
        # place on purpose). No log here — main() emits the single truthful
        # no-change line for the whole run.
        return src, False
    new_src, n1 = re.subn(
        r"(let botUsername = ''\n)",
        lambda m: m.group(1) + VOICE_HELPERS,
        src,
        count=1,
    )
    if n1 != 1:
        warn("voice hunk1 (helpers) anchor (let botUsername) not found — skipping voice patch (voice roundtrip stays disabled)")
        return src, False
    new_src, n2 = re.subn(
        r"bot\.on\('message:voice', async ctx => \{\n"
        r"  const voice = ctx\.message\.voice\n"
        r"  const text = ctx\.message\.caption \?\? '\(voice message\)'\n"
        r"  await handleInbound\(ctx, text, undefined, \{\n"
        r"    kind: 'voice',\n"
        r"    file_id: voice\.file_id,\n"
        r"    size: voice\.file_size,\n"
        r"    mime: voice\.mime_type,\n"
        r"  \}\)\n"
        r"\}\)\n",
        lambda m: VOICE_HANDLER,
        new_src,
        count=1,
    )
    if n2 != 1:
        warn("voice hunk2 (message:voice handler) anchor not found — skipping voice patch (voice roundtrip stays disabled)")
        return src, False
    new_src, n3 = re.subn(
        r"bot\.on\('message:text', async ctx => \{\n"
        r"  await handleInbound\(ctx, ctx\.message\.text, undefined\)\n"
        r"\}\)\n",
        lambda m: VOICE_TEXT_WRAP,
        new_src,
        count=1,
    )
    if n3 != 1:
        warn("voice hunk3 (message:text wrap) anchor not found — skipping voice patch (voice roundtrip stays disabled)")
        return src, False
    new_src, n4 = re.subn(
        r"        return \{ content: \[\{ type: 'text', text: result \}\] \}\n",
        lambda m: VOICE_REPLY_BLOCK + _REPLY_RETURN_V2,
        new_src,
        count=1,
    )
    if n4 != 1:
        warn("voice hunk4 (case 'reply' voice block) anchor not found — skipping voice patch (voice roundtrip stays disabled)")
        return src, False
    new_src, n5 = re.subn(
        r"(        \},\n        required: \['chat_id', 'text'\],\n)",
        lambda m: VOICE_SCHEMA_PROPERTY + m.group(1),
        new_src,
        count=1,
    )
    if n5 != 1:
        warn("voice hunk5 (reply inputSchema voice_text) anchor not found — skipping voice patch (voice roundtrip stays disabled)")
        return src, False
    new_src, n6 = re.subn(
        r"(    instructions: \[\n)",
        lambda m: m.group(1) + VOICE_INSTRUCTIONS_LINE,
        new_src,
        count=1,
    )
    if n6 != 1:
        warn("voice hunk6 (instructions line) anchor not found — skipping voice patch (voice roundtrip stays disabled)")
        return src, False
    return new_src, True


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        log("usage: apply_telegram_typing_patch.py <server.ts>")
        return 2

    path = Path(argv[1])
    if not path.is_file():
        log(f"server.ts not found at {path} — skipping")
        return 0

    src = path.read_text()
    new_src = src

    # Run the typing upgrades BEFORE apply_typing, in cascade:
    #   v1 → v2 (cap removed) → v3 (instrumented) → v4 (anti-zombie timeout)
    #     → v5 (honest timeout message, no OAuth assertion)
    #     → v6 (names the interactive-prompt cause, 031)
    # If a step's source marker isn't present, that step is a no-op and the
    # next step picks up. apply_typing then short-circuits on the v6 marker
    # if anything ran. If no markers were present at all, apply_typing
    # installs v6 fresh.
    new_src, tu1 = upgrade_typing_v1_to_v2(new_src)
    new_src, tu2 = upgrade_typing_v2_to_v3(new_src)
    new_src, tu3 = upgrade_typing_v3_to_v4(new_src)
    new_src, tu4 = upgrade_typing_v4_to_v5(new_src)
    new_src, tu5 = upgrade_typing_v5_to_v6(new_src)
    new_src, t = apply_typing(new_src)
    new_src, o = apply_offset(new_src)
    new_src, pm = apply_pending_marker(new_src)
    new_src, s = apply_stderr(new_src)
    new_src, p = apply_primary(new_src)
    # 031: give-up delivery wiring runs LAST — it anchors on the typing helpers'
    # final (post-cascade/post-apply_typing) shape, which by this point is stable
    # regardless of which upgrade path the file took.
    new_src, ag = apply_askq_giveup(new_src)
    # 032/033: voice roundtrip runs last and independently — its anchors (the
    # message:voice/message:text handlers, the reply case's final return,
    # the reply tool schema, the instructions array) are untouched by every
    # patch above. The v1→v2 upgrade runs before the fresh-install path so
    # an already-patched (v1) file is migrated in place rather than skipped
    # as "already has MARKER_VOICE_V1" — apply_voice's own gate then treats
    # a still-v1 file (upgrade refused, out-of-band edit) as "leave it".
    new_src, vu1 = upgrade_voice_v1_to_v2(new_src)
    new_src, vu2 = upgrade_voice_v2_to_v3(new_src)
    new_src, v = apply_voice(new_src)

    if not (tu1 or tu2 or tu3 or tu4 or tu5 or t or o or pm or s or p or ag or vu1 or vu2 or v):
        # Either everything is already patched, or some set of anchors missed.
        # 034: say which — a silent no-op was indistinguishable from a refused
        # upgrade in the boot log (analyze I3). Never writes the file.
        present = sum(1 for m in ALL_MARKERS if m in src)
        if present == len(ALL_MARKERS):
            log(f"no changes to {path}: all patch groups already present")
        else:
            log(f"no changes to {path}: {present}/{len(ALL_MARKERS)} patch groups present, remaining anchors not found (see WARN lines above)")
        return 0

    # Atomic write: temp file in same dir, then rename.
    tmp = path.with_suffix(path.suffix + ".apl-tmp")
    tmp.write_text(new_src)
    tmp.replace(path)
    parts = []
    if tu1:
        parts.append("typing-upgrade-v1→v2")
    if tu2:
        parts.append("typing-upgrade-v2→v3")
    if tu3:
        parts.append("typing-upgrade-v3→v4")
    if tu4:
        parts.append("typing-upgrade-v4→v5")
    if tu5:
        parts.append("typing-upgrade-v5→v6")
    if t:
        parts.append("typing")
    if o:
        parts.append("offset")
    if pm:
        parts.append("pending-marker")
    if s:
        parts.append("stderr")
    if p:
        parts.append("primary")
    if ag:
        parts.append("askq-giveup")
    if vu1:
        parts.append("voice-upgrade-v1→v2")
    if vu2:
        parts.append("voice-upgrade-v2→v3")
    if v:
        parts.append("voice")
    log(f"applied {'+'.join(parts)} patch(es) to {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
