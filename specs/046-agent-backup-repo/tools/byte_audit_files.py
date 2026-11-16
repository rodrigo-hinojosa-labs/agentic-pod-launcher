#!/usr/bin/env python3
"""Audit whole files for bytes the repo's docs must not carry.

Flags: combining marks (U+0300-U+036F), control bytes other than tab and newline,
non-breaking or zero-width spaces, emoji and pictographs, and any non-ASCII
character outside the Spanish letters and the punctuation the docs use.
Exit 0 when clean, 1 when anything was found.
"""
import sys
import unicodedata

# U+2192 is allowed because spec-kit's Clarifications format is "- Q: ... → A: ...".
# The four box-drawing glyphs are the spec-kit plan template's directory trees.
ALLOWED = set("áéíóúÁÉÍÓÚñÑüÜ¿¡«»—–·…→") | {"─", "│", "├", "└"}


def audit(path):
    bad = []
    with open(path, "rb") as fh:
        raw = fh.read()
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        return [f"{path}: not valid UTF-8 ({exc})"]
    for lineno, line in enumerate(text.split("\n"), 1):
        for col, ch in enumerate(line, 1):
            cp = ord(ch)
            if ch == "\t":
                continue
            if cp < 0x20 or cp == 0x7F:
                bad.append(f"{path}:{lineno}:{col}: control byte U+{cp:04X}")
            elif 0x0300 <= cp <= 0x036F:
                bad.append(f"{path}:{lineno}:{col}: combining mark U+{cp:04X}")
            elif cp > 0x7E and ch not in ALLOWED:
                name = unicodedata.name(ch, "UNKNOWN")
                bad.append(f"{path}:{lineno}:{col}: U+{cp:04X} {name}")
    if not text.endswith("\n"):
        bad.append(f"{path}: no trailing newline")
    return bad


def main(paths):
    problems = []
    for p in paths:
        problems.extend(audit(p))
    for line in problems:
        print(line)
    print(f"audited {len(paths)} file(s): {len(problems)} finding(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
