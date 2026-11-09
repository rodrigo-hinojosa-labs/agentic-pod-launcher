#!/usr/bin/env bats
# 017: sqlite-vec musl swap + qmd/sqlite-vec version guardrail.
#
# The prebuilt sqlite-vec-linux-<x64|arm64>/vec0.so are GLIBC and cannot dlopen on musl
# (they need __memcpy_chk@GLIBC, and ld-linux on arm64). On musl we bake a musl-compiled
# vec0.so at image build and swap it into the managed prefix, onto the package of the
# machine's architecture (042). These host tests assert the swap LOGIC (gate by musl +
# baked artifact, architecture, idempotency, fail-silent) with mock files — the real
# compile + embed is exercised by DOCKER_E2E.

load helper

setup() {
  setup_tmp_dir
  load_lib qmd_index
  PREFIX="$TMP_TEST_DIR/pkg"
  SV_DIR="$PREFIX/node_modules/sqlite-vec-linux-arm64"
  mkdir -p "$SV_DIR"
  printf 'GLIBC-PREBUILT' > "$SV_DIR/vec0.so"   # stand-in for the glibc prebuilt
  # Mock musl loader (present == musl) and baked musl artifact.
  export QMD_MUSL_LOADER="$TMP_TEST_DIR/ld-musl"; : > "$QMD_MUSL_LOADER"
  export QMD_VEC0_MUSL_SO="$TMP_TEST_DIR/vec0-musl.so"; printf 'MUSL-BUILD' > "$QMD_VEC0_MUSL_SO"
  # 042: the machine architecture is a seam too, like the two above, so this oracle holds on any
  # host: the CI runs it on ubuntu amd64 and on macOS arm64, where `uname -m` says x86_64 and arm64.
  # The default is the arm64 layout the original tests were written for; the x64 tests override it.
  export QMD_MACHINE_ARCH=aarch64
}

teardown() {
  teardown_tmp_dir
}

# 042: _mk_pkg SUFFIX — a fake glibc package of one architecture under the prefix. The content names
# the suffix so a test can tell which package got swapped and which one was left alone.
_mk_pkg() {
  mkdir -p "$PREFIX/node_modules/sqlite-vec-linux-$1"
  printf 'GLIBC-PREBUILT-%s' "$1" > "$PREFIX/node_modules/sqlite-vec-linux-$1/vec0.so"
}

# 042: _fake_uname VALUE — put a `uname` first on PATH that logs every call to $TMP_TEST_DIR/uname.calls,
# answers VALUE to `-m` and defers to the real one for anything else. It exercises the production path
# (no QMD_MACHINE_ARCH) and lets a test assert that glibc never asks. Call it once per test.
_fake_uname() {
  local value="$1" real bindir="$TMP_TEST_DIR/fakebin"
  real="$(command -v uname)"
  mkdir -p "$bindir"
  {
    printf '#!/bin/sh\n'
    printf 'echo "$*" >> "%s/uname.calls"\n' "$TMP_TEST_DIR"
    printf 'if [ "$1" = "-m" ]; then echo "%s"; exit 0; fi\n' "$value"
    printf 'exec "%s" "$@"\n' "$real"
  } > "$bindir/uname"
  chmod +x "$bindir/uname"
  PATH="$bindir:$PATH"
}

# 042: _failing_uname — a `uname` first on PATH that complains on stderr and exits 1, like a broken binary.
# It goes with the strict mode the callers run under, to prove the swap never aborts on it (invariant I5)
# and never lets its complaint into the output (invariant I6).
_failing_uname() {
  local bindir="$TMP_TEST_DIR/failbin"
  mkdir -p "$bindir"
  printf '#!/bin/sh\necho "uname: boom" >&2\nexit 1\n' > "$bindir/uname"
  chmod +x "$bindir/uname"
  PATH="$bindir:$PATH"
}

# --- US1: swap logic ---------------------------------------------------------

@test "swap replaces the glibc prebuilt with the musl build on musl + artifact present" {
  run _qmd_swap_sqlite_vec "$PREFIX"
  [ "$status" -eq 0 ]
  # 042 (FR-002): arm64 keeps printing today's line, byte for byte, and nothing else.
  [ "$output" = "[qmd] sqlite-vec: swapped glibc prebuilt for musl build" ]
  run cat "$SV_DIR/vec0.so"
  [ "$output" = "MUSL-BUILD" ]
}

@test "swap is a no-op on glibc (musl loader absent)" {
  export QMD_MUSL_LOADER="$TMP_TEST_DIR/does-not-exist"
  run _qmd_swap_sqlite_vec "$PREFIX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run cat "$SV_DIR/vec0.so"
  [ "$output" = "GLIBC-PREBUILT" ]
}

@test "swap on musl with the baked artifact absent logs + continues (fail-silent), prebuilt untouched" {
  export QMD_VEC0_MUSL_SO="$TMP_TEST_DIR/absent-artifact.so"
  # The line 017 wrote, whole and alone (FR-002). Its dash is the em dash that 017 used; it is built from its
  # bytes so that the source of this file stays ASCII where it matters.
  local abs before
  abs="[qmd] sqlite-vec: musl build absent ($QMD_VEC0_MUSL_SO) $(printf '\342\200\224') vector embed unavailable, lexical index intact"
  before="$(find "$PREFIX" | LC_ALL=C sort)"
  run _qmd_swap_sqlite_vec "$PREFIX"
  [ "$status" -eq 0 ]
  # 042: "unavailable" is now also in the new lines, so it no longer says which branch logged; the whole
  # line, with the path of the missing artifact, does.
  [ "$output" = "$abs" ]
  run cat "$SV_DIR/vec0.so"
  [ "$output" = "GLIBC-PREBUILT" ]
  [ "$(find "$PREFIX" | LC_ALL=C sort)" = "$before" ]
  # The same on an amd64 image built without the toolchain (QMD_NATIVE_TOOLCHAIN=0): the x64 package is there
  # and the baked build is not. Before 042 this exact case was silent, and the induced breakage of the
  # nightly runs it.
  export QMD_MACHINE_ARCH=x86_64
  rm -rf "$PREFIX/node_modules"
  _mk_pkg x64
  before="$(find "$PREFIX" | LC_ALL=C sort)"
  run _qmd_swap_sqlite_vec "$PREFIX"
  [ "$status" -eq 0 ]
  [ "$output" = "$abs" ]
  run cat "$PREFIX/node_modules/sqlite-vec-linux-x64/vec0.so"
  [ "$output" = "GLIBC-PREBUILT-x64" ]
  [ "$(find "$PREFIX" | LC_ALL=C sort)" = "$before" ]
}

@test "swap is idempotent (second call is a no-op, content stays the musl build)" {
  _qmd_swap_sqlite_vec "$PREFIX"
  run _qmd_swap_sqlite_vec "$PREFIX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run cat "$SV_DIR/vec0.so"
  [ "$output" = "MUSL-BUILD" ]
}

@test "swap with no sqlite-vec package at all logs that none was found" {
  # 042: this path used to be silent (#107). Now it says what was looked for and what was there.
  rm -rf "$SV_DIR"
  run _qmd_swap_sqlite_vec "$PREFIX"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "no sqlite-vec-linux-arm64 package"
  echo "$output" | grep -q "found: none"
  echo "$output" | grep -q "vector embed unavailable, lexical index intact"
  # D3 is decided before D4: with the baked build absent too, the line still names the missing package.
  export QMD_VEC0_MUSL_SO="$TMP_TEST_DIR/absent-artifact.so"
  run _qmd_swap_sqlite_vec "$PREFIX"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "no sqlite-vec-linux-arm64 package"
  if echo "$output" | grep -q "musl build absent"; then false; fi
}

# --- 042: the swap follows the architecture of the machine ---------------------------------
# The package npm/bun lays down is sqlite-vec-linux-x64 on amd64 and sqlite-vec-linux-arm64 on arm64.
# The swap used to know only the arm64 one, so on amd64 it silently left the glibc binary in place
# (issue #107). Contract: specs/042-qmd-sqlite-vec-x64/contracts/{swap-sqlite-vec,host-oracle}.md.

@test "x64 layout (the one measured in run 39069243972): the x64 package is swapped" {
  export QMD_MACHINE_ARCH=x86_64
  rm -rf "$PREFIX/node_modules"
  _mk_pkg x64
  # A read-only prebuilt (a package cache can leave it so): the copy has to replace it all the same.
  chmod 444 "$PREFIX/node_modules/sqlite-vec-linux-x64/vec0.so"
  run _qmd_swap_sqlite_vec "$PREFIX"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "swapped glibc prebuilt for musl build"
  run cat "$PREFIX/node_modules/sqlite-vec-linux-x64/vec0.so"
  [ "$output" = "MUSL-BUILD" ]
  # Invariant I2: the only file in the prefix is the vec0.so of the package (no backup, no stray copy).
  [ "$(cd "$PREFIX" && find . -type f | LC_ALL=C sort)" = "./node_modules/sqlite-vec-linux-x64/vec0.so" ]
}

@test "both packages present: only the one of the machine's architecture is swapped" {
  # The prefix is rebuilt on every round: after the first swap the package is already musl and a
  # later round would pass without proving anything.
  local arch want other
  for arch in x86_64 aarch64; do
    case "$arch" in
      x86_64) want=x64; other=arm64 ;;
      *) want=arm64; other=x64 ;;
    esac
    rm -rf "$PREFIX/node_modules"
    _mk_pkg x64
    _mk_pkg arm64
    export QMD_MACHINE_ARCH="$arch"
    run _qmd_swap_sqlite_vec "$PREFIX"
    [ "$status" -eq 0 ]
    run cat "$PREFIX/node_modules/sqlite-vec-linux-$want/vec0.so"
    [ "$output" = "MUSL-BUILD" ]
    run cat "$PREFIX/node_modules/sqlite-vec-linux-$other/vec0.so"
    [ "$output" = "GLIBC-PREBUILT-$other" ]
  done
}

@test "architecture names: x86_64 and amd64 select x64, aarch64 and arm64 select arm64" {
  # uname -m says x86_64 and aarch64 on Linux and arm64 on macOS; amd64 is accepted for robustness.
  local arch want other
  for arch in x86_64 amd64 aarch64 arm64; do
    case "$arch" in
      x86_64|amd64) want=x64; other=arm64 ;;
      *) want=arm64; other=x64 ;;
    esac
    rm -rf "$PREFIX/node_modules"
    _mk_pkg x64
    _mk_pkg arm64
    export QMD_MACHINE_ARCH="$arch"
    run _qmd_swap_sqlite_vec "$PREFIX"
    [ "$status" -eq 0 ]
    run cat "$PREFIX/node_modules/sqlite-vec-linux-$want/vec0.so"
    [ "$output" = "MUSL-BUILD" ]
    run cat "$PREFIX/node_modules/sqlite-vec-linux-$other/vec0.so"
    [ "$output" = "GLIBC-PREBUILT-$other" ]
  done
}

@test "only a foreign package present: logs what it found and touches nothing" {
  # A workspace carried from an arm64 host to an x86_64 one keeps the arm64 package. It must not be
  # written to (the baked build is for this machine), and the log must say what was there.
  local before
  export QMD_MACHINE_ARCH=x86_64
  rm -rf "$PREFIX/node_modules"
  _mk_pkg arm64
  before="$(find "$PREFIX" | LC_ALL=C sort)"
  run _qmd_swap_sqlite_vec "$PREFIX"
  [ "$status" -eq 0 ]
  # The whole line (contract section 5), which is one line only: the sqlite-vec: prefix, the package looked
  # for, what was there and the closing. The two new lines are ASCII only: no em dash, no colour sequence.
  [ "$output" = "[qmd] sqlite-vec: no sqlite-vec-linux-x64 package in the managed prefix (found: sqlite-vec-linux-arm64) - vector embed unavailable, lexical index intact" ]
  if LC_ALL=C grep -q '[^ -~]' <<< "$output"; then false; fi
  run cat "$PREFIX/node_modules/sqlite-vec-linux-arm64/vec0.so"
  [ "$output" = "GLIBC-PREBUILT-arm64" ]
  # Nothing was created or removed anywhere in the prefix (invariant I2).
  [ "$(find "$PREFIX" | LC_ALL=C sort)" = "$before" ]
}

@test "unsupported architecture: logs it and touches nothing" {
  # A defensive branch: the image is only built for x86_64 and aarch64, but if a machine ever says
  # anything else (or uname fails and prints nothing) the log must say so, not add one more silent path.
  local arch before
  before="$(find "$PREFIX" | LC_ALL=C sort)"
  # Besides riscv64 and the empty answer: names that a prefix glob (x86*, amd*, aarch*, arm*) would accept, a
  # big-endian aarch64, a 32-bit userland and the upper-case spelling. Exact names only select a package.
  for arch in riscv64 "" armv7l aarch64_be x86 amd i686 X86_64; do
    export QMD_MACHINE_ARCH="$arch"
    run _qmd_swap_sqlite_vec "$PREFIX"
    [ "$status" -eq 0 ]
    # The whole line, and one line only; ASCII only (contract section 5).
    [ "$output" = "[qmd] sqlite-vec: no musl build for machine architecture '$arch' (supported: x86_64, aarch64) - vector embed unavailable, lexical index intact" ]
    if LC_ALL=C grep -q '[^ -~]' <<< "$output"; then false; fi
    [ "$(find "$PREFIX" | LC_ALL=C sort)" = "$before" ]
    run cat "$SV_DIR/vec0.so"
    [ "$output" = "GLIBC-PREBUILT" ]
  done
}

@test "glibc with the x64 layout is a no-op, silent and does not ask uname" {
  # Local mode (glibc): the prebuilt loads as it is. The function must not even ask the machine
  # for its architecture there (invariant I4): the fake uname logs every call.
  export QMD_MUSL_LOADER="$TMP_TEST_DIR/does-not-exist"
  unset QMD_MACHINE_ARCH
  rm -rf "$PREFIX/node_modules"
  _mk_pkg x64
  _fake_uname x86_64
  run _qmd_swap_sqlite_vec "$PREFIX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run cat "$PREFIX/node_modules/sqlite-vec-linux-x64/vec0.so"
  [ "$output" = "GLIBC-PREBUILT-x64" ]
  [ ! -e "$TMP_TEST_DIR/uname.calls" ]
}

@test "x64 swap is idempotent and the second run prints nothing" {
  export QMD_MACHINE_ARCH=x86_64
  rm -rf "$PREFIX/node_modules"
  _mk_pkg x64
  # The first call must prove the swap happened (content and log line); without that, against the
  # original function both calls are silent and this test would pass on nothing.
  run _qmd_swap_sqlite_vec "$PREFIX"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "swapped glibc prebuilt for musl build"
  run cat "$PREFIX/node_modules/sqlite-vec-linux-x64/vec0.so"
  [ "$output" = "MUSL-BUILD" ]
  run _qmd_swap_sqlite_vec "$PREFIX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run cat "$PREFIX/node_modules/sqlite-vec-linux-x64/vec0.so"
  [ "$output" = "MUSL-BUILD" ]
}

@test "a failing copy logs swap failed and still returns 0" {
  [ "$(id -u)" -ne 0 ] || skip "root ignores file modes"
  local dir="$PREFIX/node_modules/sqlite-vec-linux-x64"
  export QMD_MACHINE_ARCH=x86_64
  rm -rf "$PREFIX/node_modules"
  _mk_pkg x64
  chmod 444 "$dir/vec0.so"
  chmod 555 "$dir"
  # stdout alone and stderr in a file (`run` would merge them): this is the one branch the stdout test cannot
  # reach as root, and its line must not leak onto the protocol channel of the MCP server either.
  local out rc=0 err="$TMP_TEST_DIR/stderr.txt"
  out="$(_qmd_swap_sqlite_vec "$PREFIX" 2>"$err")" || rc=$?
  # Restore the modes right away: a failing assertion below must not leave a tree that the teardown
  # cannot delete.
  chmod 755 "$dir"
  chmod 644 "$dir/vec0.so"
  [ "$rc" -eq 0 ]
  [ -z "$out" ]
  # The whole line and nothing else: cp's own complaint must not leak next to it (invariant I6). Its dash is
  # the em dash that 017 used.
  [ "$(cat "$err")" = "[qmd] sqlite-vec: swap failed (cp) $(printf '\342\200\224') vector embed may be unavailable" ]
  run cat "$dir/vec0.so"
  [ "$output" = "GLIBC-PREBUILT-x64" ]
  # With the modes back, the next call retries and succeeds: the failure leaves no stamp behind.
  run _qmd_swap_sqlite_vec "$PREFIX"
  [ "$status" -eq 0 ]
  [ "$output" = "[qmd] sqlite-vec: swapped glibc prebuilt for musl build" ]
  run cat "$dir/vec0.so"
  [ "$output" = "MUSL-BUILD" ]
}

@test "without the seam, the architecture comes from uname -m (x86_64)" {
  # The production path: no QMD_MACHINE_ARCH, the answer comes from a (fake) uname on PATH.
  unset QMD_MACHINE_ARCH
  rm -rf "$PREFIX/node_modules"
  _mk_pkg x64
  _fake_uname x86_64
  run _qmd_swap_sqlite_vec "$PREFIX"
  [ "$status" -eq 0 ]
  run cat "$PREFIX/node_modules/sqlite-vec-linux-x64/vec0.so"
  [ "$output" = "MUSL-BUILD" ]
  grep -q -- "-m" "$TMP_TEST_DIR/uname.calls"
}

@test "without the seam, the architecture comes from uname -m (aarch64)" {
  unset QMD_MACHINE_ARCH
  rm -rf "$PREFIX/node_modules"
  _mk_pkg arm64
  _fake_uname aarch64
  run _qmd_swap_sqlite_vec "$PREFIX"
  [ "$status" -eq 0 ]
  run cat "$PREFIX/node_modules/sqlite-vec-linux-arm64/vec0.so"
  [ "$output" = "MUSL-BUILD" ]
}

@test "the upgrade checklist names both package layouts" {
  # The checklist is what a person reads when qmd or sqlite-vec is bumped. The swap follows the
  # architecture now, so it has to name both packages and the rule sqlite-vec's loader uses to build
  # the package name (index.cjs: platformPackageName), or the next bump re-checks only arm64.
  local doc="$REPO_ROOT/docs/qmd-upgrade-checklist.md" item
  # The names are looked for inside that item, not in the whole document: the 017 note at the top of the
  # file names both packages too and would keep this green after the item lost them. The item runs from
  # its first line to the next one.
  item="$(awk '/\*\*017 swap path\*\*/ {f=1; print; next} f && /^- \[/ {exit} f' "$doc")"
  [ -n "$item" ]
  grep -Fq 'sqlite-vec-linux-x64' <<< "$item"
  grep -Fq 'sqlite-vec-linux-arm64' <<< "$item"
  grep -Fq 'sqlite-vec-${os}-${arch}' <<< "$item"
}

# --- 042, added by the independent review (T020): promises of the contract that nothing pinned ------------

@test "the log goes to stderr only: stdout stays empty in every branch" {
  # The qmd MCP server runs the swap in its own process (qmd_mcp_exec) and its stdout is the protocol
  # channel, so a log line on stdout would corrupt it. `run` merges the two streams: here stdout is
  # captured alone and stderr goes to a file, which must hold the branch's line, or an empty stdout
  # would prove nothing. The fifth line (D7, a failed copy) needs a non-root user and lives in the test of
  # the failing copy.
  local out err="$TMP_TEST_DIR/stderr.txt"
  # D6: the swap happens
  out="$(_qmd_swap_sqlite_vec "$PREFIX" 2>"$err")"
  [ -z "$out" ]
  grep -q "swapped glibc prebuilt for musl build" "$err"
  # D3: no package of this architecture
  rm -rf "$PREFIX/node_modules"
  out="$(_qmd_swap_sqlite_vec "$PREFIX" 2>"$err")"
  [ -z "$out" ]
  grep -q "no sqlite-vec-linux-arm64 package" "$err"
  # D4: the baked build is absent
  _mk_pkg arm64
  export QMD_VEC0_MUSL_SO="$TMP_TEST_DIR/absent-artifact.so"
  out="$(_qmd_swap_sqlite_vec "$PREFIX" 2>"$err")"
  [ -z "$out" ]
  grep -q "musl build absent" "$err"
  # D2: an architecture the image is not built for
  export QMD_MACHINE_ARCH=riscv64
  out="$(_qmd_swap_sqlite_vec "$PREFIX" 2>"$err")"
  [ -z "$out" ]
  grep -q "no musl build for machine architecture 'riscv64'" "$err"
}

@test "the swap always hands control back to a strict-mode caller, with its variables untouched" {
  # The callers run the swap under set -euo pipefail, in their own shell (start_services.sh). Whatever the
  # branch, it must end in a normal return (invariant I5): never an exit, never a failing status, never the
  # complaint of a broken uname next to the log line (I6), and never a change to the caller's own
  # variables (arch, suffix, target, dir and found are local). `run` executes in a subshell and merges the
  # streams, so each branch goes through a child bash that prints those five variables after the call.
  local branch dir="$PREFIX/node_modules/sqlite-vec-linux-x64"
  for branch in glibc unsupported missing-package missing-build already-swapped swapped copy-fails broken-uname; do
    # a fresh x64 prefix on musl, with the baked build, for every branch
    export QMD_MUSL_LOADER="$TMP_TEST_DIR/ld-musl" QMD_VEC0_MUSL_SO="$TMP_TEST_DIR/vec0-musl.so" QMD_MACHINE_ARCH=x86_64
    chmod -R u+w "$PREFIX" 2>/dev/null || true
    rm -rf "$PREFIX/node_modules"
    _mk_pkg x64
    case "$branch" in
      glibc) export QMD_MUSL_LOADER="$TMP_TEST_DIR/does-not-exist" ;;
      unsupported) export QMD_MACHINE_ARCH=riscv64 ;;
      missing-package) rm -rf "$PREFIX/node_modules" ;;
      missing-build) export QMD_VEC0_MUSL_SO="$TMP_TEST_DIR/absent-artifact.so" ;;
      already-swapped) cp "$QMD_VEC0_MUSL_SO" "$dir/vec0.so" ;;
      copy-fails)
        [ "$(id -u)" -ne 0 ] || continue
        chmod 444 "$dir/vec0.so"
        chmod 555 "$dir" ;;
      broken-uname) unset QMD_MACHINE_ARCH; _failing_uname ;;
    esac
    run bash -c 'set -euo pipefail; . "$1"; arch=S suffix=S target=S dir=S found=S; _qmd_swap_sqlite_vec "$2"; echo "survived:$arch$suffix$target$dir$found"' _ "$REPO_ROOT/scripts/lib/qmd_index.sh" "$PREFIX"
    # Modes back before any assertion: a failure must not leave a tree that the teardown cannot delete.
    chmod 755 "$dir" 2>/dev/null || true
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "^survived:SSSSS$"
    if [ "$branch" = broken-uname ]; then
      # The L-ARCH line of an empty answer and the survived line, nothing of the uname's complaint.
      [ "${#lines[@]}" -eq 2 ]
      echo "$output" | grep -q "no musl build for machine architecture ''"
      if echo "$output" | grep -q "uname: boom"; then false; fi
    fi
  done
}

@test "a package directory without its vec0.so counts as missing, and found: lists the package directories only" {
  # Decision D3 looks at the FILE, not at the directory (an interrupted install leaves the directory
  # behind): the swap must not create a vec0.so there. found: is the bare names of the sqlite-vec-linux-*
  # directories, separated by one space, in glob order. The rest of a real prefix stays out: the sqlite-vec
  # wrapper package (qmd depends on it), an unrelated package, and a regular file with a matching name.
  export QMD_MACHINE_ARCH=x86_64
  rm -rf "$PREFIX/node_modules"
  _mk_pkg arm64
  mkdir -p "$PREFIX/node_modules/sqlite-vec-linux-x64" "$PREFIX/node_modules/sqlite-vec" "$PREFIX/node_modules/@tobilu/qmd"
  : > "$PREFIX/node_modules/sqlite-vec-linux-stray"
  run _qmd_swap_sqlite_vec "$PREFIX"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  echo "$output" | grep -q "no sqlite-vec-linux-x64 package"
  echo "$output" | grep -Fq "(found: sqlite-vec-linux-arm64 sqlite-vec-linux-x64)"
  if [ -e "$PREFIX/node_modules/sqlite-vec-linux-x64/vec0.so" ]; then false; fi
  run cat "$PREFIX/node_modules/sqlite-vec-linux-arm64/vec0.so"
  [ "$output" = "GLIBC-PREBUILT-arm64" ]
}

# --- US3: version guardrail --------------------------------------------------

@test "qmd pin default is the known-good 2.5.3" {
  run qmd_pkg "$TMP_TEST_DIR/no-agent.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "@tobilu/qmd@2.5.3" ]
}

@test "Dockerfile pins SQLITE_VEC_VERSION to the known-good 0.1.9 (paired with qmd 2.5.3)" {
  # Guardrail: if qmd is bumped past 2.5.3, its transitive sqlite-vec may change and
  # the musl compile shim (research R2) must be re-verified. This test fixes the
  # known-good pair so a bump can't slip through silently.
  local qmd_ver sv_ver
  qmd_ver="$(qmd_pkg "$TMP_TEST_DIR/no-agent.yml")"
  [ "$qmd_ver" = "@tobilu/qmd@2.5.3" ]
  run grep -Eq '^ARG SQLITE_VEC_VERSION=0\.1\.9$' "$REPO_ROOT/docker/Dockerfile"
  [ "$status" -eq 0 ]
}
