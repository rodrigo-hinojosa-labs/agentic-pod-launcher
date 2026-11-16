#!/bin/bash
# Punto de control de 046: corre un conjunto de suites en bash 5.x y en 3.2, en
# secuencia, y deja un resumen por bash en <out>/<tag>.sum.
# Uso: run_checkpoint.sh <tag> <suite> [<suite>...]
set -u
S="${BR046_WORK:-$HOME/.cache/agentic-046}"
W="${BR046_REPO:-$(cd "$(dirname "$0")/../../.." && pwd)}"
tag="$1"
shift
mkdir -p "$S/checkpoints"
cd "$W" || exit 1
export PATH=/opt/homebrew/bin:$PATH
for b in bash5 bash32; do
  out="$S/checkpoints/$tag-$b"
  t0=$(date +%s)
  if [ "$b" = "bash32" ]; then
    PATH=/bin:$PATH bats "$@" > "$out.tap" 2> "$out.err"
  else
    bats "$@" > "$out.tap" 2> "$out.err"
  fi
  rc=$?
  {
    echo "rc=$rc secs=$(( $(date +%s) - t0 ))"
    head -1 "$out.tap"
    echo "ok=$(grep -c '^ok ' "$out.tap")"
    echo "notok=$(grep -c '^not ok ' "$out.tap")"
    grep '^not ok ' "$out.tap"
  } > "$out.sum"
done
echo done > "$S/checkpoints/$tag.done"
