#!/usr/bin/env bats
# 043-e2e-lock-race-hardening: host oracle for the manual reindex of the qmd e2e tests.
#
# Contract: specs/043-e2e-lock-race-hardening/contracts/host-oracle.md
#   L  the wait (qmd_e2e_reindex_wait), against a fake exec and a fake clock
#   X  the effect check (qmd_e2e_reindex_effect): its decisions against a fake exec (X1 to X5),
#      and in X6 the read the container runs, executed for real on the host
#   O  the lock-owner probe (qmd_e2e_lock_owners), run on the host itself
#   B  the bodies of the call sites in tests/docker-e2e-qmd.bats, read from the file
#   D  guards: the busy mark is the product's text, and the helper is bash 3.2 clean
#
# Why it exists: the manual `heartbeatctl qmd-reindex` of the e2e tests can lose the
# non-blocking .reindex.lock, and losing it is the product's design (it prints
# `already running` and exits 0). The reindex phase of `qmd real (041)` went red that way on
# the night of 29-10-2026 (run 40865079036, #112), and the retry loop of test 13 of 037
# aborts when engine-calls.log does not exist yet (#109). The sites now wait through one
# shared helper, tests/helper-qmd-e2e.bash, and this file proves it on the host. A check
# that cannot fail is not evidence: every test here has a mutation that turns it red
# (host-oracle.md section 5).
#
# Rules this file lives by (it is the code that enforces them):
#   - bash 3.2 and 5.x: no mapfile, no associative arrays, no ${v,,}.
#   - no network and no Docker: the exec is a function, and the clock is a file.
#   - never `producer | grep -q`: assertions use case on a variable, or grep on a file.
#   - a negative assertion is `_lacks` or `if cmd; then false; fi`, never an intermediate
#     `!` (dead in both bash) nor an intermediate [[ ]] (dead in bash 3.2).
#   - a background process (the lock holder of O1) is started with fds 3 and 4 closed,
#     or bats waits for it forever, and it is killed in teardown.
#   - nothing big travels through argv or the environment.
#   - the helper is loaded by the tests that exercise it (_use_helper), never by setup, so
#     the B tests fail on the content of the e2e file and not on a missing helper.

load helper

# `run` inside the helper is plain; the version floor matches the other host oracles.
bats_require_minimum_version 1.5.0

E2E_FILE="$REPO_ROOT/tests/docker-e2e-qmd.bats"
HELPER_FILE="$REPO_ROOT/tests/helper-qmd-e2e.bash"
PRODUCT_LIB="$REPO_ROOT/scripts/lib/qmd_index.sh"

setup() {
  setup_tmp_dir
  PLAN_DIR="$TMP_TEST_DIR/plan"
  CALLS_LOG="$TMP_TEST_DIR/calls.log"
  ATTEMPTS_ARGS="$TMP_TEST_DIR/attempts.args"
  CLOCK_FILE="$TMP_TEST_DIR/clock"
  SLEEP_LOG="$TMP_TEST_DIR/sleep.log"
  FD3_FILE="$TMP_TEST_DIR/fd3.txt"
  STDOUT_FILE="$TMP_TEST_DIR/stdout.txt"
  HOLDER_PID=""
  HOLDER2_PID=""
  RC=0
  mkdir -p "$PLAN_DIR"
  : > "$CALLS_LOG"
  : > "$ATTEMPTS_ARGS"
  : > "$SLEEP_LOG"
  : > "$FD3_FILE"
  : > "$STDOUT_FILE"
  echo 0 > "$CLOCK_FILE"
  echo 0 > "$PLAN_DIR/next"
  echo 0 > "$PLAN_DIR/planned"
}

teardown() {
  local p
  for p in "${HOLDER_PID:-}" "${HOLDER2_PID:-}"; do
    if [ -n "$p" ]; then
      kill "$p" 2>/dev/null || true
      wait "$p" 2>/dev/null || true
    fi
  done
  teardown_tmp_dir
}

# ── harness ──────────────────────────────────────────────────────────────────

# _has TEXT NEEDLE / _lacks TEXT NEEDLE: substring assertions with no pipe
# (tests/qmd-embed-nightly.bats).
_has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
_lacks() { ! _has "$1" "$2"; }

# _count FILE NEEDLE: how many lines of FILE contain NEEDLE (0 when none, never an error).
_count() { grep -c -F -- "$2" "$1" || true; }

# _line_with TEXT NEEDLE: the first line of TEXT that contains NEEDLE (empty when none), read
# with no pipe and no early exit.
_line_with() {
  local l
  while IFS= read -r l; do
    case "$l" in *"$2"*) printf '%s\n' "$l"; return 0 ;; esac
  done <<< "$1"
  return 0
}

# _use_helper: load the helper under test, then replace its two seams with the fake clock:
# now prints the counter in CLOCK_FILE, and sleep N records N in SLEEP_LOG and adds it to
# the counter. A function defined after the `load` wins, in bash 3.2 and 5.x alike.
_use_helper() {
  load helper-qmd-e2e
  _qmd_e2e_now() { cat "$CLOCK_FILE"; }
  _qmd_e2e_sleep() {
    local t
    echo "$1" >> "$SLEEP_LOG"
    t=$(cat "$CLOCK_FILE")
    echo $((t + $1)) > "$CLOCK_FILE"
  }
}

# fake_exec ARGS...: the exec of the sites (in_container, inc) without Docker. It sorts each
# call by its text, in this order: a reindex attempt (heartbeatctl qmd-reindex), the effect
# check (vault_hash) or the owner probe (/proc). Attempt N answers with aN.status and aN.out
# from PLAN_DIR, and the last planned answer repeats when the plan runs out; the effect and
# the probe answer from fixed files. Every call is logged in CALLS_LOG, and the arguments of
# every attempt go to ATTEMPTS_ARGS. Attempt 501 logs `runaway` and answers as a free lock,
# which stops a wait that has no deadline; every L test asserts there was no runaway.
fake_exec() {
  local all="$*" n k
  case "$all" in
    *"heartbeatctl qmd-reindex"*)
      echo attempt >> "$CALLS_LOG"
      printf '%s\n' "$all" >> "$ATTEMPTS_ARGS"
      n=$(( $(cat "$PLAN_DIR/next") + 1 ))
      echo "$n" > "$PLAN_DIR/next"
      if [ "$n" -gt 500 ]; then
        echo runaway >> "$CALLS_LOG"
        printf 'ok\n'
        return 0
      fi
      k=$(cat "$PLAN_DIR/planned")
      if [ "$k" -eq 0 ]; then
        printf 'ok\n'
        return 0
      fi
      if [ "$n" -lt "$k" ]; then k="$n"; fi
      cat "$PLAN_DIR/a$k.out"
      return "$(cat "$PLAN_DIR/a$k.status")"
      ;;
    *vault_hash*)
      echo effect >> "$CALLS_LOG"
      if [ -f "$PLAN_DIR/effect.status" ]; then
        cat "$PLAN_DIR/effect.out"
        return "$(cat "$PLAN_DIR/effect.status")"
      fi
      printf 'STATE absent\n'
      return 0
      ;;
    */proc*)
      echo probe >> "$CALLS_LOG"
      if [ -f "$PLAN_DIR/probe.status" ]; then
        cat "$PLAN_DIR/probe.out"
        return "$(cat "$PLAN_DIR/probe.status")"
      fi
      printf 'pid 99 fd 9 cmd=[sleep 30 ]\n'
      return 0
      ;;
    *)
      echo "unknown" >> "$CALLS_LOG"
      return 99
      ;;
  esac
}

# _plan_attempt N STATUS OUTPUT / _plan_probe STATUS OUTPUT / _plan_effect STATUS OUTPUT:
# the answers of fake_exec. OUTPUT may span several lines.
_plan_attempt() {
  printf '%s\n' "$2" > "$PLAN_DIR/a$1.status"
  printf '%s\n' "$3" > "$PLAN_DIR/a$1.out"
  if [ "$1" -gt "$(cat "$PLAN_DIR/planned")" ]; then echo "$1" > "$PLAN_DIR/planned"; fi
}
_plan_probe() {
  printf '%s\n' "$1" > "$PLAN_DIR/probe.status"
  if [ -n "$2" ]; then printf '%s\n' "$2" > "$PLAN_DIR/probe.out"; else : > "$PLAN_DIR/probe.out"; fi
}
_plan_effect() {
  printf '%s\n' "$1" > "$PLAN_DIR/effect.status"
  printf '%s\n' "$2" > "$PLAN_DIR/effect.out"
}

# The ASCII stand-in of the product's skip line (the product writes an em dash).
BUSY_OUT='[qmd] reindex: already running - skip'

# _call_wait SITE / _call_effect SITE [EXEC]: call the helper the way the sites do, inside an ||
# list (bash does not apply errexit within a function called there, which is also the case
# at the sites: U1 of the analysis), with fd 3 and stdout in files of their own. The return
# code lands in RC; the REINDEX_* globals stay set for the assertions. EXEC defaults to fake_exec.
_call_wait() {
  RC=0
  qmd_e2e_reindex_wait fake_exec "$1" 3>"$FD3_FILE" >"$STDOUT_FILE" || RC=$?
}
_call_effect() {
  RC=0
  qmd_e2e_reindex_effect "${2:-fake_exec}" "$1" 3>"$FD3_FILE" >"$STDOUT_FILE" || RC=$?
}

# real_effect_exec ARGS...: the exec of the 041 site for the read of the effect, without Docker. The
# helper calls it as `bash -lc SCRIPT`; it runs the same script with bash -c (a login profile is not
# hermetic on a host), with the library of the repo, the state file STATE_FILE and the vault
# VAULT_DIR of the test (QMD_INDEX_STATE_FILE and QMD_VAULT_DIR are the product's own seams).
real_effect_exec() {
  [ "$1" = "bash" ] || return 99
  [ "$2" = "-lc" ] || return 99
  QMD_E2E_LIB_DIR="$REPO_ROOT/scripts/lib" QMD_INDEX_STATE_FILE="$STATE_FILE" QMD_VAULT_DIR="$VAULT_DIR" bash -c "$3"
}

# _repo_vault_hash DIR: the hash the product computes for DIR (scripts/lib/backup_vault.sh).
_repo_vault_hash() { bash -c '. "$1/scripts/lib/backup_vault.sh"; vault_hash "$2"' _ "$REPO_ROOT" "$1"; }

# _reset_attempts: a new scenario inside the same test (the plan of attempts, the logs and
# the clock start over; the answers of the probe and of the effect stay).
_reset_attempts() {
  rm -f "$PLAN_DIR"/a*.status "$PLAN_DIR"/a*.out
  echo 0 > "$PLAN_DIR/next"
  echo 0 > "$PLAN_DIR/planned"
  : > "$CALLS_LOG"
  : > "$ATTEMPTS_ARGS"
  : > "$SLEEP_LOG"
  : > "$FD3_FILE"
  : > "$STDOUT_FILE"
  echo 0 > "$CLOCK_FILE"
}

# _no_runaway: the fake exec never reached attempt 501, and every call was one it knows.
_no_runaway() { [ "$(_count "$CALLS_LOG" runaway)" = "0" ] && [ "$(_count "$CALLS_LOG" unknown)" = "0" ]; }

# Extractors for the B tests, in the mould of P1 and P2 of tests/qmd-embed-nightly.bats.
# All anchors are ASCII. Each prints the text on stdout; the callers keep it in a variable.
_body_041() { awk '/^@test "qmd real \(041\)/{f=1; next} /^@test /{f=0} f{print}' "$E2E_FILE"; }
_body_037_migrate() { awk '/^@test "qmd e2e \(037\): a legacy/{f=1; next} /^@test /{f=0} f{print}' "$E2E_FILE"; }
_body_first_boot() { awk '/^@test "qmd e2e: first-boot/{f=1; next} /^@test /{f=0} f{print}' "$E2E_FILE"; }
# _fn_body NAME: the body of the top-level function NAME, from `NAME() {` to the first `}`
# at the start of a line.
_fn_body() { awk -v n="$1" '$0 ~ ("^" n "\\(\\) \\{") {f=1} f{print} f && /^\}/{exit}' "$E2E_FILE"; }
# _code: stdin without its comment lines.
_code() { awk '$0 !~ /^[[:space:]]*#/ {print}'; }
# _phase_seg PHASE NEXT: stdin between the marks `_embed_phase PHASE` and `_embed_phase NEXT`.
_phase_seg() { awk -v p="$1" -v q="$2" '$1 == "_embed_phase" && $2 == p {f=1; next} $1 == "_embed_phase" && $2 == q {f=0} f{print}'; }
# _first_boot_phase3: stdin between the comment headers of phase 3 and phase 4 of test 12.
_first_boot_phase3() { awk '/Phase 3: cron-path reindex/{f=1; next} /Phase 4: inotify-under-bind-mount/{f=0} f{print}'; }

# ── L: the wait (qmd_e2e_reindex_wait) ───────────────────────────────────────

@test "L1: with the lock free, one attempt, no wait, no probe, nothing on stdout, and the attempt is the 041 command" {
  _use_helper
  _plan_attempt 1 0 'ok'
  _call_wait "reindex phase"
  [ "$RC" -eq 0 ]
  [ "$REINDEX_ATTEMPTS" -eq 1 ]
  [ "$REINDEX_WAITED_S" -eq 0 ]
  [ "$REINDEX_STATUS" -eq 0 ]
  [ "$REINDEX_OUTPUT" = 'ok' ]
  [ ! -s "$SLEEP_LOG" ]
  [ "$(_count "$CALLS_LOG" probe)" = "0" ]
  [ ! -s "$STDOUT_FILE" ]
  [ ! -s "$FD3_FILE" ]
  # I13: the exact command of tests/docker-e2e-qmd.bats:875 before 043 (the cap of 600 s, the
  # output rewritten with > in /tmp/qmd-reindex.out and printed back)
  [ "$(wc -l < "$ATTEMPTS_ARGS" | tr -d ' ')" = "1" ]
  [ "$(cat "$ATTEMPTS_ARGS")" = 'sh -c timeout -k 10 600 /usr/local/bin/heartbeatctl qmd-reindex > /tmp/qmd-reindex.out 2>&1; rc=$?; cat /tmp/qmd-reindex.out; exit $rc' ]
  _no_runaway
}

@test "L2: busy twice and free on the third: three attempts, two waits of 2 s, the third output, one probe and R-BUSY" {
  _use_helper
  local fd3
  _plan_attempt 1 0 "$BUSY_OUT"
  _plan_attempt 2 0 "$BUSY_OUT"
  _plan_attempt 3 0 'indexed run'
  _call_wait "reindex phase"
  [ "$RC" -eq 0 ]
  [ "$REINDEX_ATTEMPTS" -eq 3 ]
  [ "$REINDEX_WAITED_S" -eq 4 ]
  [ "$REINDEX_STATUS" -eq 0 ]
  [ "$REINDEX_OUTPUT" = 'indexed run' ]
  [ "$(tr '\n' ' ' < "$SLEEP_LOG")" = "2 2 " ]
  [ "$(_count "$CALLS_LOG" probe)" = "1" ]
  fd3=$(cat "$FD3_FILE")
  _has "$fd3" '#   reindex lock busy (reindex phase): the first attempt lost the lock; owners:'
  _has "$fd3" '#   pid 99 fd 9 cmd=[sleep 30 ]'
  [ ! -s "$STDOUT_FILE" ]
  _no_runaway
}

@test "L3: busy past the deadline: return 1 on the fourth attempt, three waits, R-EXPIRED with the last output and a second probe" {
  _use_helper
  local fd3
  export QMD_E2E_REINDEX_LOCK_WAIT_S=6
  _plan_attempt 1 0 "$BUSY_OUT"
  _plan_probe 0 'pid 4242 fd 9 cmd=[sleep 60 ]'
  _call_wait "test 13 tick 1"
  [ "$RC" -eq 1 ]
  [ "$REINDEX_ATTEMPTS" -eq 4 ]
  [ "$REINDEX_WAITED_S" -eq 6 ]
  [ "$(tr '\n' ' ' < "$SLEEP_LOG")" = "2 2 2 " ]
  [ "$(_count "$CALLS_LOG" probe)" = "2" ]
  fd3=$(cat "$FD3_FILE")
  _has "$fd3" '#   reindex (test 13 tick 1): the reindex lock stayed busy for 6 s (4 attempts) and the reindex never ran'
  _has "$fd3" '#   last output of qmd-reindex:'
  _has "$fd3" "#   $BUSY_OUT"
  _has "$fd3" '#   lock owners at the end of the wait:'
  _has "$fd3" '#   pid 4242 fd 9 cmd=[sleep 60 ]'
  [ ! -s "$STDOUT_FILE" ]
  _no_runaway
}

@test "L4: a reindex that fails for another reason is not retried and keeps its status and output" {
  _use_helper
  _plan_attempt 1 5 'boom'
  _call_wait "reindex phase"
  [ "$RC" -eq 0 ]
  [ "$REINDEX_ATTEMPTS" -eq 1 ]
  [ "$REINDEX_STATUS" -eq 5 ]
  [ "$REINDEX_OUTPUT" = 'boom' ]
  [ ! -s "$SLEEP_LOG" ]
  [ "$(_count "$CALLS_LOG" probe)" = "0" ]
  _no_runaway
}

@test "L5: a cap exceeded on the first attempt (124, 137 or 143) returns 3, with no wait and no retry" {
  _use_helper
  local st
  for st in 124 137 143; do
    _reset_attempts
    _plan_attempt 1 "$st" 'still embedding'
    _call_wait "reindex phase"
    [ "$RC" -eq 3 ]
    [ "$REINDEX_STATUS" -eq "$st" ]
    [ "$REINDEX_ATTEMPTS" -eq 1 ]
    [ ! -s "$SLEEP_LOG" ]
    [ "$(_count "$CALLS_LOG" attempt)" = "1" ]
  done
  _no_runaway
}

@test "L6: the effective deadline of QMD_E2E_REINDEX_LOCK_WAIT_S (unset, empty, junk, out of range, leading zero, valid)" {
  _use_helper
  local v got
  got=$(unset QMD_E2E_REINDEX_LOCK_WAIT_S; _qmd_e2e_lock_wait_s)
  [ "$got" = "120" ]
  for v in '' abc 99999 0 3601; do
    got=$(export QMD_E2E_REINDEX_LOCK_WAIT_S="$v"; _qmd_e2e_lock_wait_s)
    if [ "$got" != "120" ]; then
      echo "# L6: the value '$v' gave '$got', not 120" >&3
      false
    fi
  done
  got=$(export QMD_E2E_REINDEX_LOCK_WAIT_S=08; _qmd_e2e_lock_wait_s)
  [ "$got" = "8" ]
  got=$(export QMD_E2E_REINDEX_LOCK_WAIT_S=7; _qmd_e2e_lock_wait_s)
  [ "$got" = "7" ]
  got=$(export QMD_E2E_REINDEX_LOCK_WAIT_S=3600; _qmd_e2e_lock_wait_s)
  [ "$got" = "3600" ]
}

@test "L7: a probe that fails changes neither the return nor the count of attempts, at the first contention or at expiry" {
  _use_helper
  _plan_probe 1 ''
  _plan_attempt 1 0 "$BUSY_OUT"
  _plan_attempt 2 0 'ran'
  _call_wait "test 12 phase 3"
  [ "$RC" -eq 0 ]
  [ "$REINDEX_ATTEMPTS" -eq 2 ]
  [ "$REINDEX_OUTPUT" = 'ran' ]
  [ "$(_count "$CALLS_LOG" probe)" = "1" ]
  _reset_attempts
  export QMD_E2E_REINDEX_LOCK_WAIT_S=4
  _plan_attempt 1 0 "$BUSY_OUT"
  _call_wait "test 12 phase 3"
  [ "$RC" -eq 1 ]
  [ "$REINDEX_ATTEMPTS" -eq 3 ]
  [ "$(_count "$CALLS_LOG" probe)" = "2" ]
  _no_runaway
}

@test "L8: an exec that fails with no output is not read as a busy lock" {
  _use_helper
  _plan_attempt 1 1 ''
  _call_wait "test 13 tick 2"
  [ "$RC" -eq 0 ]
  [ "$REINDEX_ATTEMPTS" -eq 1 ]
  [ "$REINDEX_STATUS" -eq 1 ]
  [ ! -s "$SLEEP_LOG" ]
  _no_runaway
}

@test "L9: the output of an attempt does not carry the one before it" {
  _use_helper
  _plan_attempt 1 0 "$BUSY_OUT"
  _plan_attempt 2 0 'second run'
  _call_wait "reindex phase"
  [ "$RC" -eq 0 ]
  # the whole output is the second one, so nothing of the busy first attempt is left in it
  [ "$REINDEX_OUTPUT" = 'second run' ]
  _no_runaway
}

@test "L10: the wait reads the time and sleeps only through the seams, never through date or sleep" {
  _use_helper
  local fb="$TMP_TEST_DIR/fakebin" direct="$TMP_TEST_DIR/direct.log"
  mkdir -p "$fb"
  : > "$direct"
  printf '#!/bin/sh\necho "date $*" >> "%s"\nexec /bin/date "$@"\n' "$direct" > "$fb/date"
  printf '#!/bin/sh\necho "sleep $*" >> "%s"\nexit 0\n' "$direct" > "$fb/sleep"
  chmod +x "$fb/date" "$fb/sleep"
  _plan_attempt 1 0 "$BUSY_OUT"
  _plan_attempt 2 0 "$BUSY_OUT"
  _plan_attempt 3 0 'ran'
  PATH="$fb:$PATH" _call_wait "reindex phase"
  [ "$RC" -eq 0 ]
  [ "$REINDEX_ATTEMPTS" -eq 3 ]
  # only the arguments the helper would pass count: anything else is bats or the shell
  [ "$(_count "$direct" 'date +%s')" = "0" ]
  [ "$(_count "$direct" 'sleep 2')" = "0" ]
  _no_runaway
}

# ── X: the effect (qmd_e2e_reindex_effect) ───────────────────────────────────

@test "X1: indexed, pending 0 and the hash of the vault: the effect is there (noise before the STATE line is ignored)" {
  _use_helper
  _plan_effect 0 'Welcome to the agent container
STATE present indexed 0 abc123 abc123'
  _call_effect "reindex phase"
  [ "$RC" -eq 0 ]
  [ "$(_count "$CALLS_LOG" effect)" = "1" ]
  [ ! -s "$STDOUT_FILE" ]
  [ ! -s "$FD3_FILE" ]
}

@test "X2: skipped, pending 0 and the hash of the vault: another legitimate reindex did the work" {
  _use_helper
  _plan_effect 0 'STATE present skipped 0 abc123 abc123'
  _call_effect "reindex phase"
  [ "$RC" -eq 0 ]
  [ ! -s "$FD3_FILE" ]
}

@test "X3: a state hash that is not the hash of the vault fails and names both, with indexed and with skipped, and a hash that could not be read fails as such" {
  _use_helper
  local st fd3 pair
  for st in indexed skipped; do
    _plan_effect 0 "STATE present $st 0 oldhash111 newhash222"
    _call_effect "reindex phase"
    [ "$RC" -eq 1 ]
    fd3=$(cat "$FD3_FILE")
    _has "$fd3" '#   reindex effect (reindex phase):'
    _has "$fd3" 'oldhash111'
    _has "$fd3" 'newhash222'
  done
  # a field the container could not read comes back as -: two of them are no match, and one of
  # them is no stale index either
  for pair in '- -' 'abc123 -' '- abc123'; do
    _plan_effect 0 "STATE present indexed 0 $pair"
    _call_effect "reindex phase"
    [ "$RC" -eq 1 ]
    fd3=$(cat "$FD3_FILE")
    _has "$fd3" '#   reindex effect (reindex phase): the hash could not be read'
  done
}

@test "X4: error, partial and stalled fail and name the state, with pending 0 and equal hashes" {
  _use_helper
  local st fd3
  for st in error partial stalled; do
    _plan_effect 0 "STATE present $st 0 h1 h1"
    _call_effect "reindex phase"
    [ "$RC" -eq 1 ]
    fd3=$(cat "$FD3_FILE")
    _has "$fd3" '#   reindex effect (reindex phase):'
    _has "$fd3" "$st"
  done
}

@test "X5: pending 3 and pending absent fail and mention pending" {
  _use_helper
  local p fd3
  for p in 3 -; do
    _plan_effect 0 "STATE present indexed $p h1 h1"
    _call_effect "reindex phase"
    [ "$RC" -eq 1 ]
    fd3=$(cat "$FD3_FILE")
    _has "$fd3" '#   reindex effect (reindex phase):'
    _has "$fd3" 'pending'
  done
}

@test "X6: the read of the effect, run for real on the host: an absent state file is named as such, the index of the vault passes, and pending or a stale hash fail" {
  _use_helper
  local fd3 h
  VAULT_DIR="$TMP_TEST_DIR/vault"
  STATE_FILE="$TMP_TEST_DIR/qmd-index.json"
  mkdir -p "$VAULT_DIR/wiki/concepts"
  printf -- '---\ntitle: gatos\n---\nEl gato duerme sobre el teclado.\n' > "$VAULT_DIR/wiki/concepts/gatos.md"
  # 1. no state file: named as absent, with no text of jq
  _call_effect "reindex phase" real_effect_exec
  [ "$RC" -eq 1 ]
  fd3=$(cat "$FD3_FILE")
  _has "$fd3" '#   reindex effect (reindex phase): qmd-index.json is absent'
  _lacks "$fd3" 'jq'
  # 2. the index of this vault as the product writes it (vault_hash of the same directory)
  h=$(_repo_vault_hash "$VAULT_DIR")
  [ -n "$h" ]
  printf '{"last_status":"indexed","pending":0,"hash":"%s"}\n' "$h" > "$STATE_FILE"
  _call_effect "reindex phase" real_effect_exec
  [ "$RC" -eq 0 ]
  [ ! -s "$FD3_FILE" ]
  [ ! -s "$STDOUT_FILE" ]
  # 3. pending left: the fields of the STATE line come in their order
  printf '{"last_status":"indexed","pending":3,"hash":"%s"}\n' "$h" > "$STATE_FILE"
  _call_effect "reindex phase" real_effect_exec
  [ "$RC" -eq 1 ]
  fd3=$(cat "$FD3_FILE")
  _has "$fd3" "pending is '3', not 0"
  # 4. a page written after the index: the vault hash is computed now, not read from the state file
  printf '{"last_status":"indexed","pending":0,"hash":"%s"}\n' "$h" > "$STATE_FILE"
  printf -- '---\ntitle: perros\n---\nEl perro ladra.\n' > "$VAULT_DIR/wiki/concepts/perros.md"
  _call_effect "reindex phase" real_effect_exec
  [ "$RC" -eq 1 ]
  fd3=$(cat "$FD3_FILE")
  _has "$fd3" "the state file covers the vault hash $h, not the current one"
}

# ── O: the lock-owner probe (qmd_e2e_lock_owners) ────────────────────────────

@test "O1: a real process holding the lock file is named with its pid, fd and command, on one line cut at 120 characters (Linux only)" {
  # The helper loads before the skip: on macOS the red of this test before the helper existed
  # is the missing file, like L, X and D (A3 of the analysis); its behaviour runs on Linux.
  _use_helper
  [ "$(uname -s)" = "Linux" ] || skip "no /proc on $(uname -s)"
  local cache="$TMP_TEST_DIR/qmd" lock out i=0
  mkdir -p "$cache"
  lock="$cache/.reindex.lock"
  : > "$lock"
  ( exec 9>"$lock"; exec sleep 60 ) 3>&- 4>&- &
  HOLDER_PID=$!
  while [ ! -e "/proc/$HOLDER_PID/fd/9" ] && [ "$i" -lt 20 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "/proc/$HOLDER_PID/fd/9" ]
  local_exec() { "$@"; }
  export QMD_CACHE_HOME="$cache"
  out=$(qmd_e2e_lock_owners local_exec)
  _has "$out" "pid $HOLDER_PID fd 9 cmd=[sleep 60"
  # a holder whose command line spans lines (a shell running a script, as `sh -c` does: an
  # injection run of T035 printed the whole script of its holder) is still one line of the
  # report, cut at 120 characters
  local l cmd
  perl -e 'open(my $f, ">>", $ARGV[0]) or die "open: $!"; sleep 60;
# the second line of this command line' "$lock" 3>&- 4>&- &
  HOLDER2_PID=$!
  i=0
  while [ "$i" -lt 20 ]; do
    out=$(qmd_e2e_lock_owners local_exec)
    if _has "$out" "pid $HOLDER2_PID fd "; then break; fi
    sleep 0.1
    i=$((i + 1))
  done
  _has "$out" "pid $HOLDER2_PID fd "
  while IFS= read -r l; do
    case "$l" in
      "pid "*) ;;
      *) echo "# O1: a line of the report is not an owner line: $l" >&3; false ;;
    esac
  done <<< "$out"
  l=$(_line_with "$out" "pid $HOLDER2_PID fd ")
  cmd=${l#*cmd=[}
  cmd=${cmd%]}
  [ "${#cmd}" -le 120 ]
}

@test "O2: with no holder the probe says none found, lock file absent or no /proc here, and exits 0" {
  _use_helper
  local cache="$TMP_TEST_DIR/qmd" out rc
  mkdir -p "$cache"
  local_exec() { "$@"; }
  export QMD_CACHE_HOME="$cache"
  if [ "$(uname -s)" = "Linux" ]; then
    : > "$cache/.reindex.lock"
    rc=0
    out=$(qmd_e2e_lock_owners local_exec) || rc=$?
    [ "$rc" -eq 0 ]
    _has "$out" "none found"
    rm -f "$cache/.reindex.lock"
    rc=0
    out=$(qmd_e2e_lock_owners local_exec) || rc=$?
    [ "$rc" -eq 0 ]
    _has "$out" "lock file absent ($cache/.reindex.lock)"
  else
    rc=0
    out=$(qmd_e2e_lock_owners local_exec) || rc=$?
    [ "$rc" -eq 0 ]
    _has "$out" "no /proc here"
  fi
}

# ── B: the bodies of the call sites, read from tests/docker-e2e-qmd.bats ─────

@test "B1: the reindex phase of 041 waits through the helper, checks the effect in an if, keeps its cap report and fails after each report" {
  local code seg n
  code=$(_body_041 | _code)
  [ -n "$code" ]
  seg=$(printf '%s\n' "$code" | _phase_seg reindex semantic-search)
  [ -n "$seg" ]
  _has "$seg" 'qmd_e2e_reindex_wait inc'
  _has "$seg" 'if ! qmd_e2e_reindex_effect inc'
  _has "$seg" '/.vault/wiki/concepts/gatos.md'
  _has "$seg" 'qmd-reindex did not finish'
  _has "$seg" 'SECONDS - t0'
  _has "$seg" '[ "$output" = "0" ]'
  # one bare `false` after the cap report, one after return 1 and one after the effect
  n=$(printf '%s\n' "$seg" | grep -c -x -F -- '    false' || true)
  if [ "$n" -lt 3 ]; then
    echo "# B1: the phase has $n bare 'false' lines after its reports, not 3" >&3
    false
  fi
  _lacks "$seg" 'heartbeatctl qmd-reindex'
  _lacks "$seg" "grep -qE 'ok|indexed'"
}

@test "B6: the e2e file loads the helper once, after load helper" {
  local n l1 l2
  n=$(grep -c -x -F -- 'load helper-qmd-e2e' "$E2E_FILE" || true)
  [ "$n" = "1" ]
  l1=$(awk '$0 == "load helper" {print NR; exit}' "$E2E_FILE")
  l2=$(awk '$0 == "load helper-qmd-e2e" {print NR; exit}' "$E2E_FILE")
  # no guard for l2: n is 1, so the line exists (grep -x and awk == match the same lines)
  [ -n "$l1" ]
  [ "$l2" -gt "$l1" ]
}

@test "B2: test 13 waits through the helper in its loop and in its second tick, which must have run, and teardown dumps its logs" {
  local code td line n a d
  code=$(_body_037_migrate | _code)
  [ -n "$code" ]
  n=$(printf '%s\n' "$code" | grep -c -F -- 'qmd_e2e_reindex_wait in_container' || true)
  [ "$n" = "2" ]
  # the loop: a deadline (1) or a cap (3) ends the test, the helper already reported
  _has "$code" 'qmd_e2e_reindex_wait in_container "test 13 tick 1" || rc1=$?'
  _has "$code" 'if [ "$rc1" -ne 0 ]; then
      false
    fi'
  # ...and a tick that ran but failed for another reason ends it too, with its output (the
  # product's reindex always exits 0, so a status other than 0 is the exec, the cap or the shell)
  _has "$code" 'if [ "$REINDEX_STATUS" -ne 0 ]; then
      _qmd_e2e_note "test 13 tick 1: qmd-reindex exited $REINDEX_STATUS; its output:" "$REINDEX_OUTPUT"
      false
    fi'
  # ...and its read of the engine log tolerates a log that does not exist yet (#109)
  line=$(_line_with "$code" 'cat "$HOME/.cache/qmd/engine-calls.log"')
  [ -n "$line" ]
  _has "$line" '|| true'
  _has "$code" '+ 45 ))'
  # the second tick must have run: a lost lock exits 0 too, so only the return proves it (FR-007)
  _has "$code" 'qmd_e2e_reindex_wait in_container "test 13 tick 2" || rc2=$?'
  _has "$code" '[ "$rc2" -eq 0 ]'
  _has "$code" '[ "$REINDEX_STATUS" -eq 0 ]'
  _lacks "$code" 'heartbeatctl qmd-reindex'
  # FR-006: when test 13 fails, wherever it fails, teardown dumps the logs of its container, under
  # the failure guard and before the project goes down
  td=$(_fn_body teardown | _code)
  line=$(_line_with "$td" 'agent-qmd-migrate-e2e/docker-compose.yml')
  _has "$line" 'BATS_TEST_COMPLETED'
  read -r a d <<< "$(printf '%s\n' "$td" | awk '/agent-qmd-migrate-e2e/ && /docker compose logs/ && !a {a=NR} /docker compose down/ && !d {d=NR} END {print a+0, d+0}')"
  [ "$a" -gt 0 ]
  [ "$d" -gt "$a" ]
}

@test "B3: phase 3 of test 12 waits through the helper, requires its return and keeps its assertions on the state file" {
  local seg
  seg=$(_body_first_boot | _first_boot_phase3 | _code)
  [ -n "$seg" ]
  _has "$seg" 'local rc3=0'
  _has "$seg" 'qmd_e2e_reindex_wait in_container "test 12 phase 3" || rc3=$?'
  _has "$seg" '[ "$rc3" -eq 0 ]'
  _has "$seg" '[ "$REINDEX_STATUS" -eq 0 ]'
  # the two reads of the state file and the check on each, line by line
  _has "$seg" 'jq -r .last_status /workspace/scripts/heartbeat/qmd-index.json'
  _has "$seg" "grep -qE '^(indexed|skipped)\$'"
  _has "$seg" 'jq -r .runs /workspace/scripts/heartbeat/qmd-index.json'
  _has "$seg" '[ "$runs_after_cron" -ge 1 ]'
  _lacks "$seg" 'heartbeatctl qmd-reindex'
}

@test "B5: no code line of the e2e file runs heartbeatctl qmd-reindex; the only call lives in the helper, on one line" {
  local n
  n=$(_code < "$E2E_FILE" | grep -c -F -- 'heartbeatctl qmd-reindex' || true)
  if [ "$n" != "0" ]; then
    echo "# B5: the e2e file still runs heartbeatctl qmd-reindex on $n code lines:" >&3
    _code < "$E2E_FILE" | grep -F -- 'heartbeatctl qmd-reindex' | sed 's/^/#   /' >&3 || true
    false
  fi
  n=$(_code < "$HELPER_FILE" | grep -c -F -- 'heartbeatctl qmd-reindex' || true)
  [ "$n" = "1" ]
}

@test "B4: the failure state of 041 names the owners of the lock and the head of qmd-setup.err, each probe tolerant, after the heading the checklist cites" {
  local fn line h1 h2
  fn=$(_fn_body _embed_failure_state | _code)
  [ -n "$fn" ]
  _has "$fn" '# --- reindex lock owners (who has .reindex.lock open: pid, fd and command) ---'
  line=$(_line_with "$fn" 'QMD_E2E_LOCK_OWNERS_SH')
  [ -n "$line" ]
  _has "$line" 'exec -T -u agent'
  _has "$line" '|| true'
  _has "$fn" 'head -n 3 "$HOME/.cache/qmd/tmp/qmd-setup.err"'
  # the heading that docs/qmd-upgrade-checklist.md cites (G3 guards the citation) stays the first
  read -r h1 h2 <<< "$(printf '%s\n' "$fn" | awk '/# --- state at the failure: disk, container verdict, vector extension ---/ && !a {a=NR} /# --- reindex lock owners/ && !b {b=NR} END {print a+0, b+0}')"
  [ "$h1" -gt 0 ]
  [ "$h2" -gt "$h1" ]
}

# ── D: guards ────────────────────────────────────────────────────────────────

@test "D1: the busy mark of the helper is the text the product writes after reindex:" {
  _use_helper
  [ "$QMD_E2E_LOCK_BUSY_MARK" = "already running" ]
  grep -F -q -- "reindex: $QMD_E2E_LOCK_BUSY_MARK" "$PRODUCT_LIB"
}

@test "D2: the helper passes bash -n and holds no bash 4 construct, no dead negation and no pipe into grep -q, and its probe never opens the lock" {
  _use_helper
  local code bad pat n
  bash -n "$HELPER_FILE"
  code=$(_code < "$HELPER_FILE")
  bad=""
  for pat in '[[' 'mapfile' 'readarray' 'declare -A' 'local -n' '|&' '| grep -q' 'coproc' ',,}' '^^}'; do
    if _has "$code" "$pat"; then bad="$bad [$pat]"; fi
  done
  n=$(printf '%s\n' "$code" | awk '/^[[:space:]]*![[:space:]]/ {c++} END {print c+0}')
  if [ "$n" != "0" ]; then bad="$bad [a line that starts with !, $n times]"; fi
  # the probe only reads /proc: taking the lock for an instant could make the run it observes lose
  # it (contracts/lock-owner-dump.md section 1), and opening the file for writing is a step from that
  for pat in 'flock' '>"$lock"' '> "$lock"' '9>'; do
    if _has "$QMD_E2E_LOCK_OWNERS_SH" "$pat"; then bad="$bad [the probe holds $pat]"; fi
  done
  if [ -n "$bad" ]; then
    echo "# D2: the helper holds:$bad" >&3
    false
  fi
}
