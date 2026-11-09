#!/usr/bin/env bats
# 044 (#116): .reindex.lock must be free the moment a section that holds it returns.
#
# Defect: BusyBox's timeout leaves a watchdog child that inherits fd 9 (the lock) and lives about a
# second after the command ends, so the flock stays taken that long after qmd_setup_if_needed and
# qmd_reindex return. A reindex that arrives in that second loses the lock and skips on purpose.
# Fix: `flock -u 9 2>/dev/null || true` as the LAST command of each section subshell (no trap).
#
# Contracts: specs/044-qmd-lock-fd-leak/contracts/{lock-release,host-oracle,evidence-protocol}.md.
# Host-side, no Docker: tests/fixtures/qmd-lock/timeout imitates BusyBox's watchdog and
# tests/fixtures/qmd-lock/flock (perl) stands in for util-linux flock on a host that has none.
#
# Assertion rules of this file (bash 3.2 and 5.x): no intermediate `[[ ]]` or `!` (both are dead
# mid-body in some bash); use `[ ]`, `grep -q`, `case`, `run`, or `if cmd; then false; fi`.
# Each probing test takes ONE probe right after the function returns (_probe_now) and ends with
# `[ "$PROBE_RC" -eq 0 ]` as its LAST line, so the RED against the old code falls on that line.

load helper

setup() {
  setup_tmp_dir
  export HOME="$TMP_TEST_DIR/home"; mkdir -p "$HOME"
  export QMD_CACHE_HOME="$TMP_TEST_DIR/cache/qmd"; mkdir -p "$QMD_CACHE_HOME"
  export QMD_VAULT_DIR="$TMP_TEST_DIR/vault"; mkdir -p "$QMD_VAULT_DIR/wiki"
  printf '# note\nhello\n' > "$QMD_VAULT_DIR/wiki/a.md"
  export QMD_INDEX_STATE_FILE="$TMP_TEST_DIR/qmd-index.json"
  export QMD_STUB_LOG="$TMP_TEST_DIR/engine.log"; : > "$QMD_STUB_LOG"
  AGENT_YML="$TMP_TEST_DIR/agent.yml"
  cat > "$AGENT_YML" <<YAML
vault:
  enabled: true
  qmd:
    enabled: true
    version: "2.5.3"
YAML

  # lockbin goes first on PATH with the fake timeout. The fake flock goes there ONLY when the host
  # has none (decided BEFORE PATH is touched); a host with neither flock nor perl fails loudly.
  mkdir -p "$TMP_TEST_DIR/lockbin"
  cp "$REPO_ROOT/tests/fixtures/qmd-lock/timeout" "$TMP_TEST_DIR/lockbin/timeout"
  if ! command -v flock >/dev/null 2>&1; then
    if ! command -v perl >/dev/null 2>&1; then
      echo "qmd-lock-release: this host has neither flock nor perl; the oracle cannot run" >&2
      return 1
    fi
    cp "$REPO_ROOT/tests/fixtures/qmd-lock/flock" "$TMP_TEST_DIR/lockbin/flock"
  fi
  export PATH="$TMP_TEST_DIR/lockbin:$PATH"

  export FAKE_TIMEOUT_LINGER=3
  export FAKE_TIMEOUT_PIDFILE="$TMP_TEST_DIR/watchdogs.pid"
  unset FAKE_TIMEOUT_ONLY QMD_STUB_FAIL_ONCE

  # shellcheck source=/dev/null
  source "$REPO_ROOT/scripts/lib/qmd_index.sh"
  # The lock path comes from the product function, so the probe cannot look at another file.
  LOCK="$(qmd_cache_root)/.reindex.lock"
}

# Kill the PIDs listed in FILE that are still a `sleep` (a fake-timeout watchdog or the external
# owner of L5), then forget them. The `sleep` check keeps a recycled PID from being killed.
_kill_pidfile() {
  local f="$1" p
  if [ -f "$f" ]; then
    while read -r p; do
      if [ -n "$p" ]; then
        case "$(ps -o comm= -p "$p" 2>/dev/null)" in
          *sleep*) kill "$p" 2>/dev/null || true ;;
        esac
      fi
    done < "$f"
    : > "$f"
  fi
}

# The watchdogs are not children of the test, so `wait` cannot reach them: kill them by PID, and
# the external owner of the lock (L5), before the temp dir goes.
teardown() {
  _kill_pidfile "$TMP_TEST_DIR/watchdogs.pid"
  _kill_pidfile "$TMP_TEST_DIR/owner.pid"
  teardown_tmp_dir
}

# One probe: the exit code of a single non-blocking attempt to take the lock from a new description.
_probe_now() {
  PROBE_RC=0
  flock -n "$LOCK" true || PROBE_RC=$?
}

# How many watchdogs the fake timeout left (0 when the file does not exist).
_watchdogs() {
  if [ -f "$FAKE_TIMEOUT_PIDFILE" ]; then
    wc -l < "$FAKE_TIMEOUT_PIDFILE" | tr -d ' '
  else
    echo 0
  fi
}

# The body of a function of scripts/lib/qmd_index.sh: from `^NAME() {` to the first `^}`.
_fn_body() {
  awk -v n="$1" '
    index($0, n "() {") == 1 { on = 1 }
    on { print }
    on && /^}/ { exit }
  ' "$REPO_ROOT/scripts/lib/qmd_index.sh"
}

# --- G2: harness self-test (FR-007) ---------------------------------------------------------
@test "G2 the harness can produce the defect: a bare section leaves the lock held, and no watchdog leaves it free" {
  # With the watchdog (3 s): a minimal section written HERE, with no `flock -u 9`, holds the lock
  # after it returns because the watchdog inherited fd 9.
  ( flock -n 9 || exit 91; timeout 900 true ) 9>"$LOCK"
  _probe_now
  [ "$(_watchdogs)" -eq 1 ]
  # 1 is the conflict code of both flocks: the lock is TAKEN, not a probe that failed otherwise.
  [ "$PROBE_RC" -eq 1 ]

  # Without the watchdog the same section leaves it free. A second lock file keeps this part
  # independent of the 3 s watchdog of the first one.
  local lock2="$TMP_TEST_DIR/g2b.lock"
  FAKE_TIMEOUT_LINGER=0
  ( flock -n 9 || exit 91; timeout 900 true ) 9>"$lock2"
  PROBE_RC=0
  flock -n "$lock2" true || PROBE_RC=$?
  [ "$(_watchdogs)" -eq 1 ]
  [ "$PROBE_RC" -eq 0 ]
}

# Number of engine invocations the stub recorded.
_engine_calls() { wc -l < "$QMD_STUB_LOG" | tr -d ' '; }

# --- US1: the lock is free the moment a section returns --------------------------------------

@test "L1 qmd_setup_if_needed leaves the lock free when the first-boot section ends (FR-001)" {
  install_qmd_stub
  rm -f "$(qmd_cache_root)/index.sqlite" "$(qmd_cache_root)/.qmd-setup-ok"
  run qmd_setup_if_needed "$AGENT_YML"
  _probe_now
  [ "$status" -eq 0 ]
  [ "$(_engine_calls)" -eq 3 ]
  grep -q '^collection add ' "$QMD_STUB_LOG"
  grep -q '^update$' "$QMD_STUB_LOG"
  grep -q '^embed$' "$QMD_STUB_LOG"
  [ -f "$(qmd_cache_root)/.qmd-setup-ok" ]
  [ "$(_watchdogs)" -eq 3 ]
  [ "$PROBE_RC" -eq 0 ]
}

@test "L2 qmd_reindex leaves the lock free after a changed-vault reindex (FR-001)" {
  install_qmd_stub
  qmd_write_state "$QMD_INDEX_STATE_FILE" STALEHASH indexed
  : > "$QMD_STUB_LOG"
  run qmd_reindex "$AGENT_YML"
  _probe_now
  [ "$status" -eq 0 ]
  [ "$(_engine_calls)" -eq 2 ]
  grep -q '^update$' "$QMD_STUB_LOG"
  grep -q '^embed$' "$QMD_STUB_LOG"
  [ "$(jq -r '.last_status' "$QMD_INDEX_STATE_FILE")" = "indexed" ]
  [ "$(_watchdogs)" -eq 2 ]
  [ "$PROBE_RC" -eq 0 ]
}

@test "L3 qmd_reindex leaves the lock free after a reindex that also runs the 037 migration (FR-001)" {
  install_qmd_stub
  : > "$(qmd_cache_root)/index.sqlite"
  : > "$QMD_STUB_DIR/collections/vault"
  rm -f "$(qmd_cache_root)/.qmd-collection-wiki"
  [ "$(qmd_collection_migration_state)" = "pending" ]
  qmd_write_state "$QMD_INDEX_STATE_FILE" STALE indexed
  : > "$QMD_STUB_LOG"
  run qmd_reindex "$AGENT_YML"
  _probe_now
  [ "$status" -eq 0 ]
  # remove, add, update, cleanup, status (the pending count), then the reindex's update and embed.
  [ "$(_engine_calls)" -eq 7 ]
  [ "$(sed -n '1p' "$QMD_STUB_LOG")" = "collection remove vault" ]
  grep -q '^cleanup$' "$QMD_STUB_LOG"
  [ -f "$(qmd_cache_root)/.qmd-collection-wiki" ]
  [ "$(_watchdogs)" -eq 7 ]
  [ "$PROBE_RC" -eq 0 ]
}

@test "L4 the lock is free after a setup whose bun install left a watchdog (FR-006)" {
  # The watchdog is left ONLY by `bun`, so the single watchdog is the one of `bun install`.
  export FAKE_TIMEOUT_ONLY=bun
  install_qmd_stub
  rm -f "$(qmd_cache_root)/pkg/.installed-hash" "$(qmd_cache_root)/index.sqlite" "$(qmd_cache_root)/.qmd-setup-ok"
  run qmd_setup_if_needed "$AGENT_YML"
  _probe_now
  [ "$status" -eq 0 ]
  [ -s "$(qmd_cache_root)/pkg/.installed-hash" ]
  [ "$(_watchdogs)" -eq 1 ]
  [ "$PROBE_RC" -eq 0 ]
}

@test "L7 the lock is free after an early return of the section (update fails, retry next boot) (FR-001)" {
  export QMD_STUB_FAIL_ONCE=update
  install_qmd_stub
  rm -f "$(qmd_cache_root)/index.sqlite" "$(qmd_cache_root)/.qmd-setup-ok"
  run qmd_setup_if_needed "$AGENT_YML"
  _probe_now
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF "setup: 'update' failed/timed out"
  echo "$output" | grep -qF "retry next boot"
  [ ! -f "$(qmd_cache_root)/.qmd-setup-ok" ]
  [ "$(_engine_calls)" -eq 2 ]
  [ "$(_watchdogs)" -eq 2 ]
  [ "$PROBE_RC" -eq 0 ]
}

# --- G1: structural guard of the fix (lock-release.md I1, I3, I6) ----------------------------

# _g1_check FUNCTION SECTION_CALL_PREFIX: in the body of FUNCTION (indentation removed), the line
# `flock -u 9 2>/dev/null || true` appears exactly once, after the first call of the section that
# follows `if ! flock -n 9; then`, before the line that closes the subshell, and the function has
# no trap at all (the discarded design: it released the lock on a SIGTERM while a child still ran).
_g1_check() {
  local fn="$1" call="$2" body="$TMP_TEST_DIR/g1-$1.txt" n lock_line call_line u_line close_line
  _fn_body "$fn" | sed 's/^[[:space:]]*//' > "$body"
  [ -s "$body" ]
  n=$(grep -c -x -F 'flock -u 9 2>/dev/null || true' "$body" || true)
  [ "$n" -eq 1 ]
  # No other release anywhere in the function's code (comments excluded), inline ones included:
  # the loser's branch must not release either (M7 hid its release inside the `if` line).
  n=$(awk '!/^#/ && index($0, "flock -u") { c++ } END { print c + 0 }' "$body")
  [ "$n" -eq 1 ]
  lock_line=$(awk '/^if ! flock -n 9; then/ { print NR; exit }' "$body")
  [ -n "$lock_line" ]
  call_line=$(NEEDLE="$call" awk -v s="$lock_line" 'NR > s && index($0, ENVIRON["NEEDLE"]) == 1 { print NR; exit }' "$body")
  [ -n "$call_line" ]
  u_line=$(awk '$0 == "flock -u 9 2>/dev/null || true" { print NR; exit }' "$body")
  close_line=$(NEEDLE=') 9>"$lock"' awk -v s="$lock_line" 'NR > s && index($0, ENVIRON["NEEDLE"]) == 1 { print NR; exit }' "$body")
  [ -n "$close_line" ]
  [ "$u_line" -gt "$call_line" ]
  [ "$u_line" -lt "$close_line" ]
  # It is the LAST command of the subshell: the very next line is the one that closes it.
  [ "$close_line" -eq $((u_line + 1)) ]
  # No trap anywhere in the code (comments excluded), at the start of a line or after `;`, `(`, `then`.
  n=$(awk '!/^#/ && /(^|[^[:alnum:]_])trap([^[:alnum:]_]|$)/ { c++ } END { print c + 0 }' "$body")
  [ "$n" -eq 0 ]
}

@test "G1 each locked section releases fd 9 as its last step, after the section call and before the subshell closes, with no trap" {
  _g1_check qmd_setup_if_needed '_qmd_setup_locked "'
  _g1_check qmd_reindex '_qmd_reindex_locked "'
}

# --- L5 / L6: the lock semantics do not change (FR-002). Born green on purpose --------------

@test "L5 a reindex that finds the lock held skips with rc 0, runs nothing and leaves the owner's lock alone (FR-002)" {
  # An external owner takes the lock and keeps it. It BLOCKS for the lock (no -n): the wait loop
  # below probes with `flock -n`, and a probe that holds the lock for an instant would otherwise
  # make a non-blocking owner lose the race and exit without ever owning it.
  ( exec >/dev/null 2>&1 3>&-; exec 9>"$LOCK"; flock -x 9 || exit 1; exec sleep 30 ) &
  echo "$!" > "$TMP_TEST_DIR/owner.pid"
  local i=0
  while [ "$i" -lt 50 ]; do
    if ! flock -n "$LOCK" true; then break; fi
    sleep 0.1
    i=$((i + 1))
  done
  # Precondition: the lock is TAKEN (rc 1, the conflict code), not a probe that failed otherwise.
  local pre=0
  flock -n "$LOCK" true || pre=$?
  [ "$pre" -eq 1 ]

  install_qmd_stub
  qmd_write_state "$QMD_INDEX_STATE_FILE" STALEHASH indexed
  : > "$QMD_STUB_LOG"
  run qmd_reindex "$AGENT_YML"
  _probe_now
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF "reindex: already running"
  [ ! -s "$QMD_STUB_LOG" ]
  [ "$(_watchdogs)" -eq 0 ]
  [ "$PROBE_RC" -eq 1 ]
}

@test "L6 the section still holds the lock while it runs: the engine cannot take it from a new description (FR-002)" {
  install_qmd_stub
  local bin="$QMD_CACHE_HOME/pkg/node_modules/.bin"
  mv "$bin/qmd" "$bin/qmd.stub"
  cat > "$bin/qmd" <<EOF
#!/bin/sh
if flock -n "$LOCK" true; then echo inner=0 >> "$TMP_TEST_DIR/inner.log"; else echo inner=1 >> "$TMP_TEST_DIR/inner.log"; fi
exec "$bin/qmd.stub" "\$@"
EOF
  chmod +x "$bin/qmd"
  qmd_write_state "$QMD_INDEX_STATE_FILE" STALEHASH indexed
  run qmd_reindex "$AGENT_YML"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.last_status' "$QMD_INDEX_STATE_FILE")" = "indexed" ]
  [ "$(grep -c '^inner=1$' "$TMP_TEST_DIR/inner.log" || true)" -eq 2 ]
  [ "$(grep -c '^inner=0$' "$TMP_TEST_DIR/inner.log" || true)" -eq 0 ]
}

# --- US2: nothing else changes ---------------------------------------------------------------

# _l8_run LINGER: one reindex from the same initial state, with the fake watchdog living LINGER s.
# Leaves a summary of everything observable in L8_SUMMARY.
_l8_run() {
  FAKE_TIMEOUT_LINGER="$1"
  rm -f "$QMD_STUB_DIR/failonce.done"
  qmd_write_state "$QMD_INDEX_STATE_FILE" STALEHASH indexed
  : > "$QMD_STUB_LOG"
  run qmd_reindex "$AGENT_YML"
  L8_SUMMARY=$(printf 'status=%s\nlog=%s\nlast=%s\npending=%s\nhash=%s\n' \
    "$status" "$(cat "$QMD_STUB_LOG")" \
    "$(jq -r '.last_status' "$QMD_INDEX_STATE_FILE")" \
    "$(jq -r '.pending' "$QMD_INDEX_STATE_FILE")" \
    "$(jq -r '.hash' "$QMD_INDEX_STATE_FILE")")
}

# Kill the watchdogs of the fake timeout and wait (up to 2 s) until the lock is free again, so the
# next scenario starts from a free lock.
_release_watchdogs() {
  local i=0
  _kill_pidfile "$FAKE_TIMEOUT_PIDFILE"
  while [ "$i" -lt 20 ]; do
    if flock -n "$LOCK" true; then break; fi
    sleep 0.1
    i=$((i + 1))
  done
}

# L8 is an equivalence guard, not a detector of the fix: no mutation of the catalog turns it red (the
# watchdog changes nothing outside the lock). It pins what must NOT change (FR-004), on the success
# path and on the error path, and it proves the fake timeout was really in use on each run.
@test "L8 the watchdog changes nothing observable: same rc, engine calls and state with and without it (FR-004)" {
  install_qmd_stub

  # Success path: update + embed, 2 engine calls through the fake timeout.
  _l8_run 0
  local without="$L8_SUMMARY"
  [ "$(_watchdogs)" -eq 0 ]
  _l8_run 3
  local with="$L8_SUMMARY"
  [ "$(_watchdogs)" -eq 2 ]
  [ "$without" = "$with" ]
  echo "$with" | grep -q '^status=0$'
  echo "$with" | grep -q '^last=indexed$'
  echo "$with" | grep -q '^pending=0$'
  _release_watchdogs

  # Error path: `update` fails once, 1 engine call, the state records the error.
  export QMD_STUB_FAIL_ONCE=update
  _l8_run 0
  local err_without="$L8_SUMMARY"
  [ "$(_watchdogs)" -eq 0 ]
  _l8_run 3
  local err_with="$L8_SUMMARY"
  [ "$(_watchdogs)" -eq 1 ]
  [ "$err_without" = "$err_with" ]
  echo "$err_with" | grep -q '^status=0$'
  echo "$err_with" | grep -q '^last=error$'
}
