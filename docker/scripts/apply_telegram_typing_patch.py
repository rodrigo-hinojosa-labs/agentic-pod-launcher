#!/usr/bin/env python3
"""
Patch the upstream claude-plugins-official/telegram `server.ts` so the
"typing..." Telegram action is refreshed every 4s while Claude is
processing, instead of firing once and auto-expiring after ~5s.

Idempotent (marker-based). Fail-silent on upstream drift: if any of the
three anchors does not match, the script logs a warning and exits 0
WITHOUT writing anything (so the plugin keeps its default behavior).

Usage:
    apply_telegram_typing_patch.py /path/to/server.ts
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

MARKER = "agentic-pod-launcher: typing refresh patch v1"

HELPERS = (
    "\n// " + MARKER + "\n"
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


def log(msg: str) -> None:
    print(f"[apply_telegram_typing_patch] {msg}", flush=True)


def warn(msg: str) -> None:
    # Anchor drift is operationally significant: the plugin keeps its
    # default behavior (typing indicator drops after 5s, looks like the
    # agent ghosts). Emit on stderr so log scrapers can flag it
    # distinctly from the success path on stdout.
    print(f"[apply_telegram_typing_patch] WARN: {msg}", file=sys.stderr, flush=True)


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        log("usage: apply_telegram_typing_patch.py <server.ts>")
        return 2

    path = Path(argv[1])
    if not path.is_file():
        log(f"server.ts not found at {path} — skipping")
        return 0

    src = path.read_text()

    if MARKER in src:
        # Already patched
        return 0

    # Hunk 1: inject helpers right after the `let botUsername = ''` line.
    # This sits just below `const bot = new Bot(TOKEN)` so the helpers can
    # reference `bot` directly from module scope.
    new_src, n1 = re.subn(
        r"(let botUsername = ''\n)",
        r"\1" + HELPERS,
        src,
        count=1,
    )
    if n1 != 1:
        warn("hunk1 anchor (let botUsername) not found — skipping patch (plugin keeps default typing behavior)")
        return 0

    # Hunk 2: replace the single sendChatAction call with _typingKeepAlive.
    # Anchors on the verbatim comment + call. The em-dash (—) is matched
    # as a plain character, encoded utf-8 in the source file.
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
        warn("hunk2 anchor (sendChatAction call) not found — skipping patch (plugin keeps default typing behavior)")
        return 0

    # Hunk 3: inside the `reply` tool handler, stop the typing refresh as
    # soon as we know the chat_id to reply to. This fires BEFORE the first
    # sendMessage so the user sees typing stop the instant the reply
    # starts, and we avoid a ghost refresh tick colliding with the reply.
    new_src, n3 = re.subn(
        r"(case 'reply': \{\n"
        r"        const chat_id = args\.chat_id as string\n)",
        r"\1        _typingStop(chat_id) // agentic-pod-launcher: stop typing refresh\n",
        new_src,
        count=1,
    )
    if n3 != 1:
        warn("hunk3 anchor (reply case chat_id) not found — skipping patch (plugin keeps default typing behavior)")
        return 0

    # Atomic write: temp file in same dir, then rename.
    tmp = path.with_suffix(path.suffix + ".apl-tmp")
    tmp.write_text(new_src)
    tmp.replace(path)
    log(f"applied typing refresh patch to {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
