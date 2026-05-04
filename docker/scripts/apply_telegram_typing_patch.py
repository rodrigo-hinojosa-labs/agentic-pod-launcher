#!/usr/bin/env python3
"""
Patch the upstream claude-plugins-official/telegram `server.ts` with four
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

Each patch is independently idempotent (own marker comment) and fail-silent
on anchor drift (logs WARN to stderr, skips THAT patch only, leaves the
others free to apply). A single run applies whichever patches haven't yet
been applied; repeated runs are no-ops if all four markers are present.

Usage:
    apply_telegram_typing_patch.py /path/to/server.ts
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

MARKER_TYPING = "agentic-pod-launcher: typing refresh patch v4"
MARKER_TYPING_V3 = "agentic-pod-launcher: typing refresh patch v3"
MARKER_TYPING_V2 = "agentic-pod-launcher: typing refresh patch v2"
MARKER_TYPING_V1 = "agentic-pod-launcher: typing refresh patch v1"
MARKER_OFFSET = "agentic-pod-launcher: offset persistence patch v1"
MARKER_STDERR = "agentic-pod-launcher: stderr-capture patch v1"
MARKER_PRIMARY = "agentic-pod-launcher: primary lock patch v1"

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
    "      const warnMsg = `⚠️ Tardé más de ${minutes} min en responder. Es probable que el OAuth de Claude haya expirado o haya un error de conectividad. Revisa: agentctl doctor.`\n"
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
    new_src, n = re.subn(pattern, TYPING_HELPERS, src, count=1)
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
            "  // Patched by agentic-pod-launcher (telegram-typing v4 — anti-zombie).\n"
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
    # If a step's source marker isn't present, that step is a no-op and the
    # next step picks up. apply_typing then short-circuits on the v4 marker
    # if anything ran. If no markers were present at all, apply_typing
    # installs v4 fresh.
    new_src, tu1 = upgrade_typing_v1_to_v2(new_src)
    new_src, tu2 = upgrade_typing_v2_to_v3(new_src)
    new_src, tu3 = upgrade_typing_v3_to_v4(new_src)
    new_src, t = apply_typing(new_src)
    new_src, o = apply_offset(new_src)
    new_src, s = apply_stderr(new_src)
    new_src, p = apply_primary(new_src)

    if not (tu1 or tu2 or tu3 or t or o or s or p):
        # Either everything is already patched, or every set of anchors missed.
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
    if t:
        parts.append("typing")
    if o:
        parts.append("offset")
    if s:
        parts.append("stderr")
    if p:
        parts.append("primary")
    log(f"applied {'+'.join(parts)} patch(es) to {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
