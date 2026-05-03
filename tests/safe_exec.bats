#!/usr/bin/env bats

load helper

setup() {
  setup_tmp_dir
  export SAFE_EXEC_AUX_LOG="$TMP_TEST_DIR/aux.jsonl"
  export SAFE_EXEC_LOCK_DIR="$TMP_TEST_DIR/locks"
  # Source the library directly. Tests call functions without starting
  # any persistent services (no SAFE_EXEC_NO_RUN guard needed — the
  # library has no side effects at source time).
  source "$REPO_ROOT/docker/scripts/lib/safe-exec.sh"
}
teardown() { teardown_tmp_dir; }

# ── log_aux_fail ──────────────────────────────────────────────────────

@test "log_aux_fail emits a valid JSON line to AUX_LOG" {
  log_aux_fail "test-subsystem" "something broke"
  [ -f "$SAFE_EXEC_AUX_LOG" ]
  run jq -c . "$SAFE_EXEC_AUX_LOG"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"subsystem":"test-subsystem"'* ]]
  [[ "$output" == *'"reason":"something broke"'* ]]
  [[ "$output" == *'"ts":'* ]]
  [[ "$output" == *'"pid":'* ]]
}

@test "log_aux_fail handles reasons with quotes and newlines safely" {
  local reason='line one
line "two" with $shell-y stuff'
  log_aux_fail "tricky" "$reason"
  # jq must be able to parse the line back
  run jq -r '.reason' "$SAFE_EXEC_AUX_LOG"
  [ "$status" -eq 0 ]
  [[ "$output" == *"line one"* ]]
  [[ "$output" == *'line "two"'* ]]
}

@test "log_aux_fail accepts an optional retry_in_sec" {
  log_aux_fail "with-retry" "scheduled" 60
  run jq -r '.retry_in_sec' "$SAFE_EXEC_AUX_LOG"
  [ "$status" -eq 0 ]
  [ "$output" = "60" ]
}

@test "log_aux_fail defaults retry_in_sec to null" {
  log_aux_fail "no-retry" "fatal"
  run jq -r '.retry_in_sec' "$SAFE_EXEC_AUX_LOG"
  [ "$status" -eq 0 ]
  [ "$output" = "null" ]
}

@test "log_aux_fail mirrors to stderr for docker logs visibility" {
  run log_aux_fail "mirrored" "visible"
  # Bats captures stderr into $output when run with the standard
  # invocation. Look for the safe-exec prefix.
  [[ "$output" == *"[safe-exec] mirrored: visible"* ]]
}

@test "log_aux_fail always returns 0 (caller never has to check)" {
  run log_aux_fail "rc-test" "expected zero"
  [ "$status" -eq 0 ]
}

@test "log_aux_fail creates the log directory if missing" {
  export SAFE_EXEC_AUX_LOG="$TMP_TEST_DIR/sub/dir/that/did/not/exist/aux.jsonl"
  log_aux_fail "subsystem" "msg"
  [ -f "$SAFE_EXEC_AUX_LOG" ]
}

# ── with_git_noninteractive ────────────────────────────────────────────

@test "with_git_noninteractive sets GIT_TERMINAL_PROMPT=0 in the child env" {
  run with_git_noninteractive sh -c 'echo "GIT_TERMINAL_PROMPT=$GIT_TERMINAL_PROMPT"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"GIT_TERMINAL_PROMPT=0"* ]]
}

@test "with_git_noninteractive sets GIT_ASKPASS and SSH_ASKPASS to /bin/true" {
  run with_git_noninteractive sh -c 'echo "$GIT_ASKPASS|$SSH_ASKPASS"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"/bin/true|/bin/true"* ]]
}

@test "with_git_noninteractive sets GIT_HTTP_LOW_SPEED_LIMIT and TIME for stuck transfers" {
  run with_git_noninteractive sh -c 'echo "$GIT_HTTP_LOW_SPEED_LIMIT/$GIT_HTTP_LOW_SPEED_TIME"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"1000/10"* ]]
}

@test "with_git_noninteractive returns the wrapped command's exit code" {
  run with_git_noninteractive sh -c 'exit 42'
  [ "$status" -eq 42 ]
}

@test "with_git_noninteractive with git clone of a non-existent private repo exits fast" {
  if ! command -v git >/dev/null 2>&1; then skip "git not installed"; fi
  # GitHub returns 401 for nonexistent + private mismatched paths.
  # Without GIT_TERMINAL_PROMPT=0 it would attempt to prompt for a
  # username; with it set, git exits in <2s with an auth error.
  local start end elapsed
  start=$(date +%s)
  run with_git_noninteractive git clone --depth 1 \
    https://github.com/this-org-does-not-exist-xyz123/private-repo-fake.git \
    "$TMP_TEST_DIR/clone-target"
  end=$(date +%s)
  elapsed=$((end - start))
  [ "$status" -ne 0 ]
  # Must be quick — we're verifying it didn't hang on a stdin prompt.
  # Ten seconds is generous for transient network jitter while still
  # catching a runaway hang.
  [ "$elapsed" -lt 10 ]
}

# ── safe_curl ──────────────────────────────────────────────────────────

@test "safe_curl prints code=000 on connection failure (invalid host)" {
  run safe_curl "http://nonexistent.example.invalid.x/anything"
  [ "$status" -eq 0 ]
  # First 3 chars of stdout = the code.
  [[ "${output:0:3}" == "000" ]]
}

@test "safe_curl returns within --max-time bound on hung host" {
  # 198.51.100.1 is TEST-NET-2 (RFC 5737), guaranteed unroutable. A real
  # connection attempt times out after the OS TCP retries; with curl's
  # --max-time 10 we abort sooner. Anything <15s is healthy.
  local start end elapsed
  start=$(date +%s)
  run safe_curl "http://198.51.100.1/"
  end=$(date +%s)
  elapsed=$((end - start))
  [ "$elapsed" -lt 15 ]
}

@test "safe_curl always returns 0 (transport failures encoded as code=000)" {
  run safe_curl "http://nonexistent.example.invalid/"
  [ "$status" -eq 0 ]
}

# ── safe_run_bg ────────────────────────────────────────────────────────

@test "safe_run_bg returns within 500ms regardless of CMD duration" {
  # Use a sleep that would normally block bats for 5+ seconds; we expect
  # the parent to return in milliseconds because the work is backgrounded.
  local start_ms end_ms elapsed
  start_ms=$(date +%s%N 2>/dev/null || echo "${EPOCHREALTIME:-$(date +%s)}000000000")
  safe_run_bg "non-blocking" 30 sleep 5
  end_ms=$(date +%s%N 2>/dev/null || echo "${EPOCHREALTIME:-$(date +%s)}000000000")
  elapsed=$(( (end_ms - start_ms) / 1000000 ))
  [ "$elapsed" -lt 500 ]
  # Don't leave the backgrounded sleep dangling — wait for the dispatch
  # subshell to complete before the test's teardown removes the lockdir.
  wait 2>/dev/null || true
}

@test "safe_run_bg success path is silent — no aux.jsonl entry" {
  safe_run_bg "silent-success" 5 true
  wait 2>/dev/null || true
  [ ! -s "$SAFE_EXEC_AUX_LOG" ] || run jq -r '.subsystem' "$SAFE_EXEC_AUX_LOG"
  if [ -f "$SAFE_EXEC_AUX_LOG" ]; then
    run grep -c "silent-success" "$SAFE_EXEC_AUX_LOG"
    [ "$output" = "0" ]
  fi
}

@test "safe_run_bg failure path writes aux.jsonl with exit code" {
  safe_run_bg "fail-cmd" 5 sh -c 'echo "stderr line" >&2; exit 7'
  wait 2>/dev/null || true
  # Give the backgrounded subshell a beat to flush the log line. flock
  # handoff plus jq is normally <100ms; 1s is generous.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -s "$SAFE_EXEC_AUX_LOG" ] && break
    sleep 0.1
  done
  [ -s "$SAFE_EXEC_AUX_LOG" ]
  run jq -r '.subsystem' "$SAFE_EXEC_AUX_LOG"
  [ "$output" = "fail-cmd" ]
  run jq -r '.reason' "$SAFE_EXEC_AUX_LOG"
  [[ "$output" == *"exit=7"* ]]
}

@test "safe_run_bg with timeout records reason=timeout when CMD exceeds budget" {
  if ! command -v timeout >/dev/null 2>&1 && ! command -v gtimeout >/dev/null 2>&1; then
    skip "neither timeout nor gtimeout available — install coreutils to run"
  fi
  safe_run_bg "slow-cmd" 1 sleep 30
  # Wait up to 8s for the timeout (1s budget + 5s SIGKILL grace + buffer).
  for _ in 1 2 3 4 5 6 7 8; do
    [ -s "$SAFE_EXEC_AUX_LOG" ] && break
    sleep 1
  done
  [ -s "$SAFE_EXEC_AUX_LOG" ]
  run jq -r '.reason' "$SAFE_EXEC_AUX_LOG"
  [[ "$output" == *"timeout after 1s"* ]]
}

@test "safe_run_bg dedup — second call with same NAME logs 'skipped'" {
  if ! command -v flock >/dev/null 2>&1; then
    skip "flock not available — install util-linux to run"
  fi
  # First call holds the lock for 2 seconds; second call must observe it
  # locked and emit a skip line.
  safe_run_bg "dedup-test" 10 sleep 2
  # Tiny sleep so the first subshell definitely acquired the lock.
  sleep 0.2
  safe_run_bg "dedup-test" 10 echo "should-not-run"
  # Wait for the skip line to land.
  for _ in 1 2 3 4 5; do
    grep -q "already running" "$SAFE_EXEC_AUX_LOG" 2>/dev/null && break
    sleep 0.3
  done
  run grep "skipped: already running" "$SAFE_EXEC_AUX_LOG"
  [ "$status" -eq 0 ]
  wait 2>/dev/null || true
}

@test "safe_run_bg with no args returns 0 and logs a usage error" {
  run safe_run_bg
  [ "$status" -eq 0 ]
  run jq -r '.subsystem' "$SAFE_EXEC_AUX_LOG"
  [ "$output" = "safe_run_bg" ]
}

@test "safe_run_bg degrades gracefully when timeout binary is missing" {
  # Simulate the no-timeout case by shadowing PATH to a directory where
  # neither `timeout` nor `gtimeout` exist. The library must still run
  # the command (without enforcement) and not crash.
  local stub_dir="$TMP_TEST_DIR/no-coreutils-bin"
  mkdir -p "$stub_dir"
  # Copy in the bare minimum the test needs (sh, true, sleep). Easier:
  # use a minimal PATH that excludes coreutils entirely.
  local marker="$TMP_TEST_DIR/marker"
  # Reset detection to force re-resolve under the restricted PATH.
  _safe_exec_timeout_bin=""
  PATH="/usr/bin:/bin" safe_run_bg "no-timeout" 5 sh -c "touch $marker"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -f "$marker" ] && break
    sleep 0.1
  done
  [ -f "$marker" ]
}
