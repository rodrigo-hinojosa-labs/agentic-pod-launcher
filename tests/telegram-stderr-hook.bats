#!/usr/bin/env bats
# 049-telegram-stderr-log-bound: behavior of the stderr-capture block of the Telegram patcher,
# run for real under bun. The block is taken from the patcher by import (never retyped), with
# only the production log path replaced by a test path.
#
# Contract: specs/049-telegram-stderr-log-bound/contracts/stderr-hook-v2.md (H1 to H10, H2a).
# Without bun on PATH the whole file skips with a reason: the CI runners have no bun, so this
# behavior is covered by the local gate in both bash and by DOCKER_E2E (research D6).

load helper
load helper-stderr-hook

VENDOR="$REPO_ROOT/tests/fixtures/stderr-hook/vendor-handlers.ts"

setup() {
  stderr_hook_require_bun
  W="$BATS_TEST_TMPDIR/w"
  mkdir -p "$W/logs"
  LOG="$W/logs/telegram-mcp-stderr.log"
  DRIVERS="$BATS_TEST_TMPDIR/drivers"
  mkdir -p "$DRIVERS"
  _write_drivers
}

teardown() {
  chmod 700 "$W/logs" 2>/dev/null || true
  stderr_hook_reap
}

# The drivers read everything from the environment, so one text serves every test.
_write_drivers() {
  # N writes of 48 bytes each: 40 x TAG + a 7-digit counter + LF.
  cat > "$DRIVERS/writes.ts" <<'TS'
const _wN = Number(process.env.W_N || '0')
const _wTag = (process.env.W_TAG || 'x').slice(0, 1)
for (let i = 0; i < _wN; i++) process.stderr.write(_wTag.repeat(40) + String(i).padStart(7, '0') + '\n')
TS
  # The loop of #139: one write to a closed stderr at 300 ms; the vendor handler reports the
  # EPIPE by writing to stderr again. If the event loop is still alive at 1200 ms, the exit
  # timer leaves a flag and ends the process.
  cat > "$DRIVERS/loop.ts" <<'TS'
setTimeout(() => { process.stderr.write('telegram channel: first write\n') }, 300)
setTimeout(() => {
  try { require('node:fs').writeFileSync(process.env.EXIT_FLAG || '/dev/null', 'exited\n') } catch {}
  process.exit(0)
}, 1200)
TS
}

# _ts <V1|V2> <out.ts> [part...]: the block, then each part appended in order.
_ts() {
  local which="$1" out="$2"
  shift 2
  stderr_hook_build "$which" "$out" "$LOG" || return 1
  local part
  for part in "$@"; do
    cat "$part" >> "$out"
  done
}

_size() {
  if [ -f "$1" ]; then
    wc -c < "$1" | tr -d ' '
  else
    echo 0
  fi
}

# Lines that are not exactly 40 x one of [xyzs] + 7 digits. Counts every generation present.
_malformed() {
  local f total=0 n
  for f in "$LOG" "$LOG.1" "$LOG.2"; do
    [ -f "$f" ] || continue
    n=$(LC_ALL=C grep -cvE '^(x{40}|y{40}|z{40}|s{40})[0-9]{7}$' "$f" || true)
    total=$((total + n))
  done
  echo "$total"
}

# --- harness self-test (tasks T005) -------------------------------------------------------

@test "049 harness: the closed-pipe runner kills bun itself, not the pipe's last process" {
  # The v1 block plus the vendor handlers loop forever on a closed stderr (research M2). The
  # runner must return with that bun dead and the log no longer growing; otherwise a test run
  # leaves a process filling the disk at about 10 MB/s.
  _ts V1 "$BATS_TEST_TMPDIR/v1-loop.ts" "$VENDOR" "$DRIVERS/loop.ts"
  export EXIT_FLAG="$BATS_TEST_TMPDIR/exited"
  run stderr_hook_run_closed_pipe "$BATS_TEST_TMPDIR/v1-loop.ts" 2
  [ "$status" -eq 1 ]
  local pid
  pid=$(tail -1 "$BATS_TEST_TMPDIR/stderr-hook-pids")
  [ -n "$pid" ]
  if kill -0 "$pid" 2>/dev/null; then false; fi
  local a b
  a=$(_size "$LOG")
  sleep 0.5
  b=$(_size "$LOG")
  [ "$a" -eq "$b" ]
  [ ! -f "$EXIT_FLAG" ]
}

# --- User Story 1: the log never exceeds a disk cap ------------------------------------

@test "049 H4: with U=100000, 100000 writes keep current + .1 + .2 under 3U + 3 writes" {
  _ts V2 "$BATS_TEST_TMPDIR/h4.ts" "$DRIVERS/writes.ts"
  TELEGRAM_STDERR_LOG_MAX_BYTES=100000 W_N=100000 W_TAG=x \
    stderr_hook_run_healthy "$BATS_TEST_TMPDIR/h4.ts" /dev/null
  local total
  total=$(( $(_size "$LOG") + $(_size "$LOG.1") + $(_size "$LOG.2") ))
  echo "total=$total" >&3
  [ "$total" -lt $((300000 + 3 * 48)) ]
  # The newest line is in the current file.
  [ "$(tail -1 "$LOG")" = "$(printf 'x%.0s' $(seq 1 40))0099999" ]
  # Only the current file and two generations exist: a .3 would fall outside the sum above.
  [ "$(cd "$W/logs" && ls -1 | sort | tr '\n' ' ')" = "telegram-mcp-stderr.log telegram-mcp-stderr.log.1 telegram-mcp-stderr.log.2 " ]
}

@test "049 H5: an inherited log of 50U keeps only its last U bytes in .1" {
  # 49991 bytes of 'a' then TAILMARK and LF: 50000 bytes, ending in a known marker.
  head -c 49991 /dev/zero | tr '\0' 'a' > "$LOG"
  printf 'TAILMARK\n' >> "$LOG"
  [ "$(_size "$LOG")" -eq 50000 ]
  cat > "$DRIVERS/one.ts" <<'TS'
process.stderr.write('NEW\n')
TS
  _ts V2 "$BATS_TEST_TMPDIR/h5.ts" "$DRIVERS/one.ts"
  TELEGRAM_STDERR_LOG_MAX_BYTES=1000 stderr_hook_run_healthy "$BATS_TEST_TMPDIR/h5.ts" /dev/null
  [ "$(_size "$LOG.1")" -eq 1000 ]
  [ "$(tail -c 9 "$LOG.1")" = "TAILMARK" ]
  [ "$(cat "$LOG")" = "NEW" ]
  [ ! -f "$LOG.1.tmp" ]
}

@test "049 H6: an invalid threshold (0, -5, abc, empty, 10M, 1e7) behaves as exactly 10485760" {
  # 2400 writes of 4096 bytes = 9830400 bytes: above 9 MiB and below 10 MiB. No rotation proves
  # the default is not smaller (a 1 MiB default would rotate), and H4 proves a valid value is
  # honoured. 10M and 1e7 are prefixes that Number.parseInt would read as 10 and 1.
  cat > "$DRIVERS/big.ts" <<'TS'
const _bN = Number(process.env.W_N || '0')
const _bLine = 'x'.repeat(4095) + '\n'
for (let i = 0; i < _bN; i++) process.stderr.write(_bLine)
TS
  _ts V2 "$BATS_TEST_TMPDIR/h6.ts" "$DRIVERS/big.ts"
  local v
  for v in 0 -5 abc '' 10M 1e7; do
    rm -f "$LOG" "$LOG.1" "$LOG.2"
    TELEGRAM_STDERR_LOG_MAX_BYTES="$v" W_N=2400 \
      stderr_hook_run_healthy "$BATS_TEST_TMPDIR/h6.ts" /dev/null
    echo "value='$v' size=$(_size "$LOG") gen1=$(_size "$LOG.1")" >&3
    [ "$(_size "$LOG")" -eq 9830400 ]
    [ ! -f "$LOG.1" ]
  done
}

@test "049 H7: a shell hook appending during rotation succeeds and leaves no malformed line" {
  _ts V2 "$BATS_TEST_TMPDIR/h7.ts" "$DRIVERS/writes.ts"
  local line i rc
  line="$(printf 's%.0s' $(seq 1 40))"
  (
    i=0
    while [ "$i" -lt 3000 ]; do
      printf '%s%07d\n' "$line" "$i" >> "$LOG" || exit 1
      i=$((i + 1))
    done
  ) &
  local shpid=$!
  TELEGRAM_STDERR_LOG_MAX_BYTES=20000 W_N=20000 W_TAG=x \
    stderr_hook_run_healthy "$BATS_TEST_TMPDIR/h7.ts" /dev/null
  rc=0
  wait "$shpid" || rc=$?
  [ "$rc" -eq 0 ]
  [ "$(_malformed)" -eq 0 ]
}

@test "049 H8: with the log directory not writable, the write still reaches stderr and bun exits 0" {
  cat > "$DRIVERS/one.ts" <<'TS'
process.stderr.write('STILL-FORWARDED\n')
TS
  _ts V2 "$BATS_TEST_TMPDIR/h8.ts" "$DRIVERS/one.ts"
  chmod 500 "$W/logs"
  run stderr_hook_run_healthy "$BATS_TEST_TMPDIR/h8.ts" "$BATS_TEST_TMPDIR/h8.err"
  chmod 700 "$W/logs"
  [ "$status" -eq 0 ]
  grep -qx 'STILL-FORWARDED' "$BATS_TEST_TMPDIR/h8.err"
  [ ! -f "$LOG" ]
}

@test "049 H10: two channel processes rotating the same log both exit 0 and corrupt no line" {
  _ts V2 "$BATS_TEST_TMPDIR/h10.ts" "$DRIVERS/writes.ts"
  TELEGRAM_STDERR_LOG_MAX_BYTES=20000 W_N=5000 W_TAG=y \
    bun "$BATS_TEST_TMPDIR/h10.ts" 2>/dev/null >/dev/null 3>&- 4>&- &
  local p1=$!
  TELEGRAM_STDERR_LOG_MAX_BYTES=20000 W_N=5000 W_TAG=z \
    bun "$BATS_TEST_TMPDIR/h10.ts" 2>/dev/null >/dev/null 3>&- 4>&- &
  local p2=$! r1=0 r2=0
  wait "$p1" || r1=$?
  wait "$p2" || r2=$?
  [ "$r1" -eq 0 ]
  [ "$r2" -eq 0 ]
  [ "$(_malformed)" -eq 0 ]
  local total
  total=$(( $(_size "$LOG") + $(_size "$LOG.1") + $(_size "$LOG.2") ))
  echo "total=$total" >&3
  [ "$total" -lt $((60000 + 3 * 48 + 2 * 48)) ]
}

# --- User Story 2: a closed stderr does not start a loop -----------------------------

@test "049 H1 (v1 leg, harness proof): the v1 block plus the vendor handlers loop on a closed stderr" {
  # Reproduces #139 with the real v1 text: in 1 s the log passes 1 MB and the exit timer never
  # runs, because the loop starves the event loop. If this ever turns green-by-silence, the
  # live leg below proves nothing.
  _ts V1 "$BATS_TEST_TMPDIR/h1v1.ts" "$VENDOR" "$DRIVERS/loop.ts"
  export EXIT_FLAG="$BATS_TEST_TMPDIR/exited"
  run stderr_hook_run_closed_pipe "$BATS_TEST_TMPDIR/h1v1.ts" 1
  [ "$status" -eq 1 ]
  [ "$(_size "$LOG")" -gt 1048576 ]
  [ ! -f "$EXIT_FLAG" ]
}

@test "049 H1 (live): a closed stderr leaves one [stderr-closed] line, no EPIPE loop, and a live event loop" {
  _ts V2 "$BATS_TEST_TMPDIR/h1.ts" "$VENDOR" "$DRIVERS/loop.ts"
  export EXIT_FLAG="$BATS_TEST_TMPDIR/exited"
  run stderr_hook_run_closed_pipe "$BATS_TEST_TMPDIR/h1.ts" 5
  [ "$status" -eq 0 ]
  [ -f "$EXIT_FLAG" ]
  [ "$(grep -c '\[stderr-closed\] EPIPE - forwarding to stderr stopped, log only$' "$LOG")" -eq 1 ]
  [ "$(grep -c 'telegram channel: uncaught exception: Error: EPIPE' "$LOG" || true)" -eq 0 ]
  grep -qx 'telegram channel: first write' "$LOG"
}

@test "049 H2: after the cut, N writes land in the log once each and never reach the original write" {
  # A spy wraps the real stderr write BEFORE the block, so the block captures it as its
  # original write: any forwarding after the cut shows up as a call on the spy.
  cat > "$DRIVERS/spy.ts" <<'TS'
let _spyCalls = 0
const _spyReal = process.stderr.write.bind(process.stderr)
process.stderr.write = ((...a: any[]) => { _spyCalls++; return (_spyReal as any)(...a) }) as any
TS
  cat > "$DRIVERS/h2.ts" <<'TS'
const _h2fs = require('node:fs')
setTimeout(() => { process.stderr.write('first\n') }, 100)
const _h2wait = setInterval(() => {
  let s = ''
  try { s = _h2fs.readFileSync(process.env.LOG_PATH, 'utf8') } catch {}
  if (!s.includes('[stderr-closed]')) return
  clearInterval(_h2wait)
  _spyCalls = 0
  for (let i = 0; i < 1000; i++) process.stderr.write('after ' + i + '\n')
  setTimeout(() => { _h2fs.writeFileSync(process.env.SIDE, 'calls=' + _spyCalls + '\n'); process.exit(0) }, 200)
}, 20)
setTimeout(() => { _h2fs.writeFileSync(process.env.SIDE, 'timeout\n'); process.exit(3) }, 3000)
TS
  stderr_hook_build V2 "$BATS_TEST_TMPDIR/h2.hook" "$LOG"
  cat "$DRIVERS/spy.ts" "$BATS_TEST_TMPDIR/h2.hook" "$VENDOR" "$DRIVERS/h2.ts" > "$BATS_TEST_TMPDIR/h2.ts"
  export LOG_PATH="$LOG" SIDE="$BATS_TEST_TMPDIR/side"
  run stderr_hook_run_closed_pipe "$BATS_TEST_TMPDIR/h2.ts" 6
  [ "$status" -eq 0 ]
  [ "$(cat "$SIDE")" = "calls=0" ]
  [ "$(grep -c '^after [0-9]*$' "$LOG")" -eq 1000 ]
  [ "$(grep -c '\[stderr-closed\]' "$LOG")" -eq 1 ]
}

@test "049 H2a: a burst of writes in one tick against a closed stderr leaves exactly one notice" {
  cat > "$DRIVERS/h2a.ts" <<'TS'
setTimeout(() => { for (let i = 0; i < 50; i++) process.stderr.write('burst ' + i + '\n') }, 100)
setTimeout(() => {
  try { require('node:fs').writeFileSync(process.env.EXIT_FLAG || '/dev/null', 'exited\n') } catch {}
  process.exit(0)
}, 900)
TS
  _ts V2 "$BATS_TEST_TMPDIR/h2a.ts" "$VENDOR" "$DRIVERS/h2a.ts"
  export EXIT_FLAG="$BATS_TEST_TMPDIR/exited"
  run stderr_hook_run_closed_pipe "$BATS_TEST_TMPDIR/h2a.ts" 5
  [ "$status" -eq 0 ]
  [ "$(grep -c '^burst [0-9]*$' "$LOG")" -eq 50 ]
  [ "$(grep -c '\[stderr-closed\]' "$LOG")" -eq 1 ]
}

@test "049 H3: with a healthy stderr under the threshold, log and stderr are byte-identical to v1" {
  cat > "$DRIVERS/h3.ts" <<'TS'
process.stderr.write('alpha\n')
process.stderr.write(new TextEncoder().encode('beta ñ —\n'))
process.stderr.write('gamma', () => {})
process.stderr.write('\n')
process.stderr.write('telegram channel: uncaught exception: Error: not really\n')
TS
  mkdir -p "$W/v1" "$W/v2"
  stderr_hook_build V1 "$BATS_TEST_TMPDIR/h3v1.ts" "$W/v1/log"
  cat "$DRIVERS/h3.ts" >> "$BATS_TEST_TMPDIR/h3v1.ts"
  stderr_hook_build V2 "$BATS_TEST_TMPDIR/h3v2.ts" "$W/v2/log"
  cat "$DRIVERS/h3.ts" >> "$BATS_TEST_TMPDIR/h3v2.ts"
  stderr_hook_run_healthy "$BATS_TEST_TMPDIR/h3v1.ts" "$W/v1/err"
  stderr_hook_run_healthy "$BATS_TEST_TMPDIR/h3v2.ts" "$W/v2/err"
  [ -s "$W/v1/log" ]
  cmp "$W/v1/log" "$W/v2/log"
  cmp "$W/v1/err" "$W/v2/err"
  cmp "$W/v2/log" "$W/v2/err"
}

@test "049 H9: a stream error with another code leaves one [stderr-error] line and keeps forwarding" {
  cat > "$DRIVERS/h9.ts" <<'TS'
setTimeout(() => {
  process.stderr.emit('error', Object.assign(new Error('x'), { code: 'EAGAIN' }))
  process.stderr.write('after-eagain\n')
  setTimeout(() => process.exit(0), 100)
}, 50)
TS
  _ts V2 "$BATS_TEST_TMPDIR/h9.ts" "$DRIVERS/h9.ts"
  run stderr_hook_run_healthy "$BATS_TEST_TMPDIR/h9.ts" "$BATS_TEST_TMPDIR/h9.err"
  [ "$status" -eq 0 ]
  [ "$(grep -c '\] \[stderr-error\] EAGAIN$' "$LOG")" -eq 1 ]
  grep -qx 'after-eagain' "$BATS_TEST_TMPDIR/h9.err"
  [ "$(grep -c '\[stderr-closed\]' "$LOG" || true)" -eq 0 ]
}

@test "049 H2b: two closed-destination errors still leave exactly one notice (FR-007, the once-guard)" {
  # bun 1.3.12 emits a single 'error' per stream however many writes fail (measured on
  # 23-11-2026: 50 failed writes, 1 event), so H2a alone cannot see a missing once-guard
  # (mutation M3 survived it). A second path to the cut exists (a synchronous throw, another
  # runtime): drive the cut twice by hand and demand one notice.
  cat > "$DRIVERS/h2b.ts" <<'TS'
setTimeout(() => {
  process.stderr.emit('error', Object.assign(new Error('a'), { code: 'EPIPE' }))
  process.stderr.emit('error', Object.assign(new Error('b'), { code: 'ERR_STREAM_DESTROYED' }))
  process.stderr.write('after-two-cuts\n')
  setTimeout(() => process.exit(0), 100)
}, 50)
TS
  _ts V2 "$BATS_TEST_TMPDIR/h2b.ts" "$DRIVERS/h2b.ts"
  run stderr_hook_run_healthy "$BATS_TEST_TMPDIR/h2b.ts" "$BATS_TEST_TMPDIR/h2b.err"
  [ "$status" -eq 0 ]
  [ "$(grep -c '\[stderr-closed\]' "$LOG")" -eq 1 ]
  grep -q '\[stderr-closed\] EPIPE - forwarding' "$LOG"
  grep -qx 'after-two-cuts' "$LOG"
  # Cut means cut: the write after the cut reaches the log only, not the captured stderr.
  if grep -q 'after-two-cuts' "$BATS_TEST_TMPDIR/h2b.err"; then false; fi
}

@test "049 H5b: when the tail copy cannot be written, the oversized inherited log is still dropped" {
  # Found by the 049 independent review: with the .1.tmp write failing (ENOSPC is the expected
  # case, the very state #139 leaves behind), the old file was never removed, so it stayed
  # oversized and every write re-read a threshold of bytes. Losing the tail is acceptable.
  head -c 49991 /dev/zero | tr '\0' 'a' > "$LOG"
  printf 'TAILMARK\n' >> "$LOG"
  mkdir "$LOG.1.tmp"
  cat > "$DRIVERS/one.ts" <<'TS'
process.stderr.write('NEW\n')
TS
  _ts V2 "$BATS_TEST_TMPDIR/h5b.ts" "$DRIVERS/one.ts"
  TELEGRAM_STDERR_LOG_MAX_BYTES=1000 stderr_hook_run_healthy "$BATS_TEST_TMPDIR/h5b.ts" /dev/null
  [ "$(cat "$LOG")" = "NEW" ]
}
