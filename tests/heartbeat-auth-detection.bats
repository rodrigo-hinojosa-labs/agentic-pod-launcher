#!/usr/bin/env bats
# Tests for the heartbeat auth-error detection (Phase A1 of OAuth resilience).
#
# Regression: 2026-05-03 22:30 in linus, claude --print returned an
# "API Error: 401 authentication_error" body with exit code 0 because
# the OAuth access token expired. The heartbeat wrapper counted it as
# status=ok, sent a misleading [ok] notification to Telegram, and the
# state.json's last_run reported success. This test guards against
# that regression.
#
# Strategy: stub claude with a script that prints one of the auth-failure
# patterns and exits 0 (mirroring the actual CLI behavior). Assert that
# the heartbeat overrides status=ok→error and persists error_kind="auth_failed"
# in runs.jsonl + state.json.

load helper

setup() {
  setup_tmp_dir
  export WORKSPACE="$TMP_TEST_DIR/testbot"
  mkdir -p "$WORKSPACE/scripts"
  cp -R "$REPO_ROOT/scripts/heartbeat" "$WORKSPACE/scripts/"
  export AGENT_YML="$WORKSPACE/agent.yml"
  cat > "$AGENT_YML" <<YML
agent:
  name: testbot
deployment:
  workspace: $WORKSPACE
claude:
  config_dir: $TMP_TEST_DIR/.claude
features:
  heartbeat:
    enabled: true
    interval: "2m"
    timeout: 5
    retries: 0
    default_prompt: "ping"
notifications:
  channel: none
YML
  mkdir -p "$TMP_TEST_DIR/bin"
  cat > "$WORKSPACE/scripts/heartbeat/heartbeat.conf" <<CONF
HEARTBEAT_INTERVAL="2m"
HEARTBEAT_CRON="*/2 * * * *"
HEARTBEAT_TIMEOUT="5"
HEARTBEAT_RETRIES="0"
HEARTBEAT_PROMPT="ping"
HEARTBEAT_ENABLED="true"
NOTIFY_CHANNEL="none"
NOTIFY_SUCCESS_EVERY="1"
CONF
  export HEARTBEAT_STATE_LIB="$REPO_ROOT/docker/scripts/lib/state.sh"
  export PATH="$TMP_TEST_DIR/bin:$PATH"
}

teardown() { teardown_tmp_dir; }

# Helper: install a claude stub that prints $1 to stdout, exits 0.
_stub_claude_with_output() {
  local output="$1"
  cat > "$TMP_TEST_DIR/bin/claude" <<CLAUDE
#!/bin/bash
printf '%s\n' "$output"
exit 0
CLAUDE
  chmod +x "$TMP_TEST_DIR/bin/claude"
}

@test "heartbeat: status=ok when claude returns normal output" {
  _stub_claude_with_output "all systems normal"
  run bash "$WORKSPACE/scripts/heartbeat/heartbeat.sh"
  [ "$status" -eq 0 ]
  local last_status last_kind
  last_status=$(jq -r '.status' "$WORKSPACE/scripts/heartbeat/logs/runs.jsonl" | tail -1)
  last_kind=$(jq -r '.error_kind // "null"' "$WORKSPACE/scripts/heartbeat/logs/runs.jsonl" | tail -1)
  [ "$last_status" = "ok" ]
  [ "$last_kind" = "null" ]
}

@test "heartbeat: detects 'API Error: 401' and marks status=error + error_kind=auth_failed" {
  _stub_claude_with_output 'Failed to authenticate. API Error: 401 {"type":"error","error":{"type":"authentication_error","message":"Invalid authentication credentials"}}'
  run bash "$WORKSPACE/scripts/heartbeat/heartbeat.sh"
  [ "$status" -eq 0 ]
  local last_status last_kind last_cec
  last_status=$(jq -r '.status' "$WORKSPACE/scripts/heartbeat/logs/runs.jsonl" | tail -1)
  last_kind=$(jq -r '.error_kind' "$WORKSPACE/scripts/heartbeat/logs/runs.jsonl" | tail -1)
  last_cec=$(jq -r '.claude_exit_code' "$WORKSPACE/scripts/heartbeat/logs/runs.jsonl" | tail -1)
  [ "$last_status" = "error" ]
  [ "$last_kind" = "auth_failed" ]
  [ "$last_cec" = "1" ]
}

@test "heartbeat: detects 'authentication_error' alone in output" {
  _stub_claude_with_output '{"error":{"type":"authentication_error"}}'
  run bash "$WORKSPACE/scripts/heartbeat/heartbeat.sh"
  [ "$status" -eq 0 ]
  jq -e 'select(.status == "error" and .error_kind == "auth_failed")' \
    "$WORKSPACE/scripts/heartbeat/logs/runs.jsonl" >/dev/null
}

@test "heartbeat: detects 'Please run /login' banner" {
  _stub_claude_with_output 'Please run /login'
  run bash "$WORKSPACE/scripts/heartbeat/heartbeat.sh"
  [ "$status" -eq 0 ]
  jq -e 'select(.status == "error" and .error_kind == "auth_failed")' \
    "$WORKSPACE/scripts/heartbeat/logs/runs.jsonl" >/dev/null
}

@test "heartbeat: case-insensitive match (claude prints API Error in mixed case)" {
  _stub_claude_with_output 'api error: 401 something'
  run bash "$WORKSPACE/scripts/heartbeat/heartbeat.sh"
  [ "$status" -eq 0 ]
  local last_kind
  last_kind=$(jq -r '.error_kind' "$WORKSPACE/scripts/heartbeat/logs/runs.jsonl" | tail -1)
  [ "$last_kind" = "auth_failed" ]
}

@test "heartbeat: state.json::last_run carries error_kind through" {
  _stub_claude_with_output 'API Error: 401 invalid'
  run bash "$WORKSPACE/scripts/heartbeat/heartbeat.sh"
  [ "$status" -eq 0 ]
  jq -e '.last_run.status == "error" and .last_run.error_kind == "auth_failed"' \
    "$WORKSPACE/scripts/heartbeat/state.json" >/dev/null
}

@test "heartbeat: ok output that mentions '401' in unrelated context still marked ok" {
  # Edge case: a normal claude reply that happens to contain "401" but
  # NOT in the auth_error patterns. Should NOT trigger override.
  _stub_claude_with_output "Found 401 issues in your repo"
  run bash "$WORKSPACE/scripts/heartbeat/heartbeat.sh"
  [ "$status" -eq 0 ]
  local last_status
  last_status=$(jq -r '.status' "$WORKSPACE/scripts/heartbeat/logs/runs.jsonl" | tail -1)
  [ "$last_status" = "ok" ]
}
