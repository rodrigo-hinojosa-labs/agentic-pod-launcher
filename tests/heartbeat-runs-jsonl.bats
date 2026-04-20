#!/usr/bin/env bats

load helper

setup() {
  setup_tmp_dir
  # Simulate the workspace layout.
  # WORKSPACE must be named "testbot" so that basename($WORKSPACE) == AGENT_NAME
  # used for tmux session detection in heartbeat.sh.
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
    default_prompt: "echo ok"
notifications:
  channel: none
YML
  # Stub claude
  mkdir -p "$TMP_TEST_DIR/bin"
  cat > "$TMP_TEST_DIR/bin/claude" <<'CL'
#!/bin/bash
echo "STUB CLAUDE: $*"
exit 0
CL
  chmod +x "$TMP_TEST_DIR/bin/claude"
  export PATH="$TMP_TEST_DIR/bin:$PATH"
  # heartbeat.conf
  cat > "$WORKSPACE/scripts/heartbeat/heartbeat.conf" <<CONF
HEARTBEAT_INTERVAL="2m"
HEARTBEAT_CRON="*/2 * * * *"
HEARTBEAT_TIMEOUT="5"
HEARTBEAT_RETRIES="0"
HEARTBEAT_PROMPT="echo ok"
HEARTBEAT_ENABLED="true"
NOTIFY_CHANNEL="none"
NOTIFY_SUCCESS_EVERY="1"
CONF
  export HEARTBEAT_STATE_LIB="$REPO_ROOT/docker/scripts/lib/state.sh"
}
teardown() { teardown_tmp_dir; }

@test "heartbeat.sh writes one runs.jsonl line on success" {
  run bash "$WORKSPACE/scripts/heartbeat/heartbeat.sh"
  [ "$status" -eq 0 ]
  [ -f "$WORKSPACE/scripts/heartbeat/logs/runs.jsonl" ]
  [ "$(wc -l < "$WORKSPACE/scripts/heartbeat/logs/runs.jsonl" | tr -d ' ')" = "1" ]
  run jq -r '.status' "$WORKSPACE/scripts/heartbeat/logs/runs.jsonl"
  [ "$status" -eq 0 ]; [ "$output" = "ok" ]
  run jq -r '.trigger' "$WORKSPACE/scripts/heartbeat/logs/runs.jsonl"
  [ "$output" = "cron" ]
  run jq -r '.notifier.channel' "$WORKSPACE/scripts/heartbeat/logs/runs.jsonl"
  [ "$output" = "none" ]
}

@test "heartbeat.sh writes state.json with counters and last_run" {
  run bash "$WORKSPACE/scripts/heartbeat/heartbeat.sh"
  [ -f "$WORKSPACE/scripts/heartbeat/state.json" ]
  run jq -e '.schema == 1 and .enabled == true and .interval == "2m" and .cron == "*/2 * * * *"' "$WORKSPACE/scripts/heartbeat/state.json"
  [ "$status" -eq 0 ]
  run jq -r '.last_run.status' "$WORKSPACE/scripts/heartbeat/state.json"
  [ "$output" = "ok" ]
  run jq -r '.counters.total_runs' "$WORKSPACE/scripts/heartbeat/state.json"
  [ "$output" = "1" ]
  run jq -r '.counters.ok' "$WORKSPACE/scripts/heartbeat/state.json"
  [ "$output" = "1" ]
  run jq -r '.counters.consecutive_failures' "$WORKSPACE/scripts/heartbeat/state.json"
  [ "$output" = "0" ]
}

@test "heartbeat.sh increments counters across runs" {
  bash "$WORKSPACE/scripts/heartbeat/heartbeat.sh"
  bash "$WORKSPACE/scripts/heartbeat/heartbeat.sh"
  run jq -r '.counters.total_runs' "$WORKSPACE/scripts/heartbeat/state.json"
  [ "$output" = "2" ]
  [ "$(wc -l < "$WORKSPACE/scripts/heartbeat/logs/runs.jsonl" | tr -d ' ')" = "2" ]
}

@test "heartbeat.sh records status=skipped when a prior session is still active" {
  tmux new-session -d -s "testbot-hb-99999999999999-zzzz" "sleep 30"
  run bash "$WORKSPACE/scripts/heartbeat/heartbeat.sh"
  [ "$status" -eq 0 ]
  run jq -r '.status' "$WORKSPACE/scripts/heartbeat/logs/runs.jsonl"
  [ "$output" = "skipped" ]
  run jq -r '.counters.consecutive_failures' "$WORKSPACE/scripts/heartbeat/state.json"
  [ "$output" = "0" ]
  tmux kill-session -t "testbot-hb-99999999999999-zzzz" 2>/dev/null || true
}

@test "heartbeat.sh rotates runs.jsonl when size >= 10MB" {
  mkdir -p "$WORKSPACE/scripts/heartbeat/logs"
  # Pre-populate with >10MB of filler lines
  for i in $(seq 1 110); do
    printf '{"filler":"%s"}\n' "$(head -c 98000 /dev/urandom | base64 | tr -d '\n' | head -c 98000)"
  done > "$WORKSPACE/scripts/heartbeat/logs/runs.jsonl"
  run bash "$WORKSPACE/scripts/heartbeat/heartbeat.sh"
  [ -f "$WORKSPACE/scripts/heartbeat/logs/runs.jsonl.1" ]
  [ "$(wc -l < "$WORKSPACE/scripts/heartbeat/logs/runs.jsonl" | tr -d ' ')" = "1" ]
}
