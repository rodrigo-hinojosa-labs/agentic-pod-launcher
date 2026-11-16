"""Audita solo las lineas agregadas por la rama (git diff contra la base).

Cuenta cada caracter no ASCII de las lineas agregadas y marca como problema:
marcas combinantes (U+0300-U+036F), caracteres de control y emojis/simbolos
fuera del plano basico. Uso: audit_added.py <worktree> <base> <path>...
"""
import collections
import subprocess
import sys
import unicodedata

wt, base, paths = sys.argv[1], sys.argv[2], sys.argv[3:]
out = subprocess.run(["git", "-C", wt, "diff", "-U0", base, "--"] + paths,
                     capture_output=True, text=True, check=True).stdout
counts = collections.Counter()
bad = []
cur = None
for line in out.splitlines():
    if line.startswith("+++ "):
        cur = line[6:]
        continue
    if not line.startswith("+") or line.startswith("+++"):
        continue
    for ch in line[1:]:
        o = ord(ch)
        if o < 128:
            if o < 32 and ch != "\t":
                bad.append((cur, "control U+%04X" % o))
            continue
        counts[ch] += 1
        if 0x300 <= o <= 0x36F or o > 0xFFFF or unicodedata.category(ch) == "So" and o >= 0x1F000:
            bad.append((cur, "U+%04X %s" % (o, unicodedata.name(ch, "?"))))
for ch, n in sorted(counts.items(), key=lambda x: -x[1]):
    print("%6d U+%04X %s" % (n, ord(ch), unicodedata.name(ch, "?")))
print("problems:", len(bad))
for b in bad[:40]:
    print("  ", b)
