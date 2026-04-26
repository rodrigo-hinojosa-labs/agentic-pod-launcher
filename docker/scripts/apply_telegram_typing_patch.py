#!/usr/bin/env python3
"""
Patch the upstream claude-plugins-official/telegram `server.ts` with three
independent fixes that improve Telegram chat reliability + observability:

1. Typing refresh patch (v1) — refreshes the "typing..." action every 4s
   while Claude is processing, instead of upstream's single-shot
   sendChatAction that auto-expires after ~5s.

2. Offset persistence patch (v1) — persists the Telegram update_id offset
   to ~/.claude/channels/telegram/last-offset.json after every processed
   message and replays from disk on startup. Makes message loss impossible
   regardless of how often `bun server.ts` crashes: the next getUpdates
   call uses the persisted offset, so any updates Telegram still has in
   its 24h buffer are re-delivered.

3. Stderr-capture patch (v1) — tees process.stderr to
   /workspace/scripts/heartbeat/logs/telegram-mcp-stderr.log AND wires
   uncaught/unhandled handlers that append the trace there. Without this,
   bun crashes leave no forensic evidence (the stderr the existing
   handlers write to is consumed by claude's MCP transport and dropped).

Each patch is independently idempotent (own marker comment) and fail-silent
on anchor drift (logs WARN to stderr, skips THAT patch only, leaves the
other two free to apply). A single run applies whichever patches haven't
yet been applied; repeated runs are no-ops if all three markers are
present.

Usage:
    apply_telegram_typing_patch.py /path/to/server.ts
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

MARKER_TYPING = "agentic-pod-launcher: typing refresh patch v1"
MARKER_OFFSET = "agentic-pod-launcher: offset persistence patch v1"
MARKER_STDERR = "agentic-pod-launcher: stderr-capture patch v1"

TYPING_HELPERS = (
    "\n// " + MARKER_TYPING + "\n"
    "const _typingIntervals = new Map<string | number, ReturnType<typeof setInterval>>()\n"
    "const _TYPING_REFRESH_MS = 4000\n"
    "const _TYPING_MAX_MS = 120000\n"
    "function _typingKeepAlive(chat_id: string | number): void {\n"
    "  _typingStop(chat_id)\n"
    "  const send = () => { void bot.api.sendChatAction(chat_id, 'typing').catch(() => {}) }\n"
    "  send()\n"
    "  const timer = setInterval(send, _TYPING_REFRESH_MS)\n"
    "  _typingIntervals.set(chat_id, timer)\n"
    "  const cap = setTimeout(() => _typingStop(chat_id), _TYPING_MAX_MS)\n"
    "  ;(cap as { unref?: () => void }).unref?.()\n"
    "}\n"
    "function _typingStop(chat_id: string | number): void {\n"
    "  const t = _typingIntervals.get(chat_id)\n"
    "  if (t) { clearInterval(t); _typingIntervals.delete(chat_id) }\n"
    "}\n"
)

OFFSET_HELPERS = (
    "\n// " + MARKER_OFFSET + "\n"
    "const _OFFSET_FILE = '/home/agent/.claude/channels/telegram/last-offset.json'\n"
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
)

OFFSET_MIDDLEWARE = (
    "\n// " + MARKER_OFFSET + " — post-handler middleware\n"
    "bot.use(async (ctx, next) => {\n"
    "  await next()\n"
    "  if (typeof ctx.update?.update_id === 'number') _saveOffset(ctx.update.update_id)\n"
    "})\n"
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
            "  // Typing indicator — refreshed every 4s until reply fires, 120s hard cap.\n"
            "  // Patched by agentic-pod-launcher (telegram-typing v1).\n"
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
    """Persist Telegram update_id offset to disk + replay on startup. Returns (new_src, applied)."""
    if MARKER_OFFSET in src:
        return src, False
    # Hunk B1: offset helpers — anchor on `let botUsername = ''`. If the
    # typing patch already inserted there, this lands BETWEEN the original
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
    # Hunk B2: post-handler middleware. Anchor on `const bot = new Bot(TOKEN)`,
    # insert AFTER. `await next()` first guarantees the handler completed
    # (message delivered to claude via MCP) before we save the offset, which
    # makes resume strictly at-least-once even on hard kill.
    new_src, n2 = re.subn(
        r"(const bot = new Bot\(TOKEN\)\n)",
        r"\1" + OFFSET_MIDDLEWARE,
        new_src,
        count=1,
    )
    if n2 != 1:
        warn("offset hunk2 anchor (const bot = new Bot) not found — skipping offset patch (message loss across crashes will continue)")
        return src, False
    # Hunk B3: pre-position Telegram cursor server-side BEFORE bot.start.
    # Grammy's bot.start does not accept an offset option (PollingOptions
    # only exposes limit/timeout/allowed_updates/drop_pending_updates/onStart),
    # so we fire one synchronous getUpdates with the persisted offset right
    # before bot.start to confirm everything < offset and have Telegram
    # return updates >= offset on the next poll.
    new_src, n3 = re.subn(
        r"(      await bot\.start\(\{\n)",
        OFFSET_REPLAY + r"\1",
        new_src,
        count=1,
    )
    if n3 != 1:
        warn("offset hunk3 anchor (await bot.start) not found — skipping offset patch (message loss across crashes will continue)")
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

    new_src, t = apply_typing(new_src)
    new_src, o = apply_offset(new_src)
    new_src, s = apply_stderr(new_src)

    if not (t or o or s):
        # Either everything is already patched, or every set of anchors missed.
        return 0

    # Atomic write: temp file in same dir, then rename.
    tmp = path.with_suffix(path.suffix + ".apl-tmp")
    tmp.write_text(new_src)
    tmp.replace(path)
    parts = []
    if t:
        parts.append("typing")
    if o:
        parts.append("offset")
    if s:
        parts.append("stderr")
    log(f"applied {'+'.join(parts)} patch(es) to {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
