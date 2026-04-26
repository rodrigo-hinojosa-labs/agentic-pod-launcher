#!/usr/bin/env bats
# Tests for crash_budget_check sliding-window logic in start_services.sh.
# We source the script with START_SERVICES_NO_RUN=1 so the runtime block
# (boot_side_effects + tmux launch + watchdog loop) is skipped — only
# the function definitions and config globals load.

load helper

setup() {
  setup_tmp_dir
  # Source the supervisor in test-only mode.
  export START_SERVICES_NO_RUN=1
  # Workspace and HOME so any function references resolve to tmp paths
  # rather than /workspace or /home/agent (image-bound paths).
  export WORKDIR="$TMP_TEST_DIR"
  export HOME="$TMP_TEST_DIR/home"
  mkdir -p "$HOME"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/docker/scripts/start_services.sh"
}

teardown() { teardown_tmp_dir; }

@test "crash_budget_check accepts 4 crashes spread over 600s (sliding window)" {
  # Five crashes, but four are >300s old. crash_budget_check trims those
  # and reports just the recent one as in-window; budget should still
  # have room.
  local now=10000
  local times="9100 9200 9300 9400 9999"  # last is within 300s of now
  run crash_budget_check "$now" "$times"
  [ "$status" -eq 0 ]
  # Output is just the surviving timestamps.
  [[ "$output" == *"9999"* ]]
  [[ "$output" != *"9100"* ]]
}

@test "crash_budget_check exits when 5 crashes fit within trailing 300s" {
  local now=10000
  local times="9800 9850 9900 9950 9999"  # all within 300s
  run crash_budget_check "$now" "$times"
  [ "$status" -ne 0 ]
}

@test "crash_budget_check accepts 5 crashes spread over 1500s (none recent)" {
  # A crashy week ago doesn't poison today's budget.
  local now=10000
  local times="8500 8800 9000 9200 9500"  # all > 300s old
  run crash_budget_check "$now" "$times"
  [ "$status" -eq 0 ]
  # All entries should be dropped.
  [ -z "$(echo "$output" | tr -d ' ')" ]
}

@test "crash_budget_check is the strict-equality sliding boundary at exactly 300s" {
  # An entry exactly at now-WINDOW (the boundary) is dropped (kept ones
  # must be strictly NEWER than cutoff). 4 newer + 1 boundary = 4 in window.
  local now=10000
  local times="9700 9800 9850 9900 9950"  # 9700 == now - WINDOW
  run crash_budget_check "$now" "$times"
  [ "$status" -eq 0 ]
  [[ "$output" != *"9700"* ]]
  [[ "$output" == *"9800"* ]]
}

@test "crash_budget_check tolerates empty input" {
  local now=10000
  run crash_budget_check "$now" ""
  [ "$status" -eq 0 ]
  [ -z "$(echo "$output" | tr -d ' ')" ]
}

@test "channel_plugin_alive returns 0 when no marker file exists" {
  rm -f "$CHANNEL_MARKER"
  run channel_plugin_alive
  [ "$status" -eq 0 ]
}

@test "channel_plugin_alive returns 1 when marker present but bun absent" {
  mkdir -p "$WATCHDOG_RUNTIME_DIR"
  : > "$CHANNEL_MARKER"
  # Stub pgrep so a real bun server.ts on the developer's machine
  # (e.g. another agent's plugin) doesn't make this non-deterministic.
  mkdir -p "$TMP_TEST_DIR/bin"
  cat > "$TMP_TEST_DIR/bin/pgrep" <<'STUB'
#!/bin/bash
exit 1
STUB
  chmod +x "$TMP_TEST_DIR/bin/pgrep"
  PATH="$TMP_TEST_DIR/bin:$PATH" run channel_plugin_alive
  [ "$status" -ne 0 ]
}

@test "channel_plugin_alive returns 0 when marker present and bun running" {
  mkdir -p "$WATCHDOG_RUNTIME_DIR"
  : > "$CHANNEL_MARKER"
  mkdir -p "$TMP_TEST_DIR/bin"
  cat > "$TMP_TEST_DIR/bin/pgrep" <<'STUB'
#!/bin/bash
echo "12345"
exit 0
STUB
  chmod +x "$TMP_TEST_DIR/bin/pgrep"
  PATH="$TMP_TEST_DIR/bin:$PATH" run channel_plugin_alive
  [ "$status" -eq 0 ]
}
