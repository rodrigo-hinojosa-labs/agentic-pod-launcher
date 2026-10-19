#!/bin/sh
# vec0-libc.sh - tell whether the sqlite-vec extension under a qmd prefix was built for musl
# or for glibc, whatever the CPU architecture (041-nightly-qmd-embed, FR-003; contract:
# specs/041-nightly-qmd-embed/contracts/embed-test.md section 4).
#
# The check it replaces looked at the linux-arm64 package only and printed MUSL when the file
# was missing, so on an amd64 runner it passed on nothing. Here a missing file is a failure.
#
# usage: vec0-libc.sh PREFIX
#   looks for PREFIX/node_modules/sqlite-vec-linux-*/vec0.so and prints one line:
#     MUSL <path>     rc 0   exactly one library, with no GLIBC_ symbol version
#     GLIBC <path>    rc 1   exactly one library, with a GLIBC_ symbol version
#     ABSENT          rc 2   no library at all
#     AMBIGUOUS <n>   rc 3   more than one library
#   and, with no argument or one that is not a directory, "usage: vec0-libc.sh PREFIX" (rc 64).
#
# POSIX sh and ASCII only: it runs inside the Alpine container (busybox) and on the host.
# No pipe on purpose: grep -q on the file itself, so nothing can close a pipe early.

if [ $# -ne 1 ] || [ ! -d "$1" ]; then
  echo "usage: vec0-libc.sh PREFIX" >&2
  exit 64
fi

n=0
found=""
for f in "$1"/node_modules/sqlite-vec-linux-*/vec0.so; do
  if [ -f "$f" ]; then
    n=$((n + 1))
    found="$f"
  fi
done

case "$n" in
  0)
    echo "ABSENT"
    exit 2
    ;;
  1) ;;
  *)
    echo "AMBIGUOUS $n"
    exit 3
    ;;
esac

if LC_ALL=C grep -q 'GLIBC_' "$found"; then
  echo "GLIBC $found"
  exit 1
fi
echo "MUSL $found"
exit 0
