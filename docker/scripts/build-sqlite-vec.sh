#!/bin/sh
# 017: compile the sqlite-vec loadable extension (vec0) for musl and bake it into
# the image at /opt/agent-admin/sqlite-vec/vec0.so.
#
# The npm prebuilt (node_modules/sqlite-vec-linux-arm64/vec0.so) is a GLIBC binary
# (needs ld-linux-aarch64.so.1 + fortified __memcpy_chk/__fread_chk@GLIBC_2.17) and
# CANNOT dlopen under musl → `qmd embed`/`vsearch` fail. sqlite-vec is a single-file
# C amalgamation; compiling it for musl is exactly what upstream does to produce its
# prebuilts, just retargeted. qmd_index.sh::_qmd_swap_sqlite_vec swaps this build
# into the managed prefix at runtime.
#
# Invoked from docker/Dockerfile under the QMD_NATIVE_TOOLCHAIN gate (needs the
# build-base `cc` already installed). Not sourced — run directly.
set -eu

VERSION="${SQLITE_VEC_VERSION:-0.1.9}"
# Integrity pin for the amalgamation tarball (research R2 / contracts). Bump this
# together with VERSION when the qmd/sqlite-vec pin changes (guardrail enforces it).
SHA256="3acd67cb4aff080c7050926fd3cf8227905fe5b7ee3829d8ee5024ab1283cf61"
URL="https://github.com/asg017/sqlite-vec/releases/download/v${VERSION}/sqlite-vec-${VERSION}-amalgamation.tar.gz"
OUT="/opt/agent-admin/sqlite-vec/vec0.so"

# sqlite3ext.h / sqlite3.h for the extension-loading API (build-only; removed below).
apk add --no-cache sqlite-dev

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cd "$work"

wget -q "$URL" -O amalg.tar.gz
# fail-loud on a checksum mismatch — never bake an unverified artifact.
echo "${SHA256}  amalg.tar.gz" | sha256sum -c -
tar xzf amalg.tar.gz

# The amalgamation typedefs the BSD names (u_int8_t/u_int16_t/u_int64_t) on Linux,
# which musl does not expose and for which sqlite-vec never includes <sys/types.h>.
# Map them to the C99 names so those typedefs become legal no-ops (research R2).
# -I/usr/include picks up sqlite3ext.h from sqlite-dev.
cc -O2 -fPIC -shared \
   -Du_int8_t=uint8_t -Du_int16_t=uint16_t -Du_int64_t=uint64_t \
   -I/usr/include -I. sqlite-vec.c -o vec0.so -lm

# Guard: refuse to bake anything that still links GLIBC (would not load on musl).
if strings vec0.so | grep -q 'GLIBC_'; then
  echo "build-sqlite-vec: compiled vec0.so links GLIBC — aborting" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT")"
install -m 0644 vec0.so "$OUT"

# Drop the build-only headers to keep the single-stage image lean.
apk del sqlite-dev >/dev/null 2>&1 || true

echo "build-sqlite-vec: baked musl vec0.so (v${VERSION}) -> $OUT"
