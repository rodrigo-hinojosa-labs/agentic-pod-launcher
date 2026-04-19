#!/usr/bin/env bats

load helper

setup() { setup_tmp_dir; }
teardown() { teardown_tmp_dir; }

@test "none.sh emits ok=true, latency=0, channel=none" {
  run bash "$REPO_ROOT/scripts/heartbeat/notifiers/none.sh" "run-1" "ok" <<<"hello"
  [ "$status" -eq 0 ]
  json="$output"
  run jq -r '.channel' <<<"$json"; [ "$output" = "none" ]
  run jq -r '.ok' <<<"$json"; [ "$output" = "true" ]
  run jq -r '.latency_ms' <<<"$json"; [ "$output" = "0" ]
  run jq -r '.error' <<<"$json"; [ "$output" = "null" ]
}

@test "log.sh writes message to \$NOTIFY_LOG_FILE and returns ok=true" {
  export NOTIFY_LOG_FILE="$TMP_TEST_DIR/notifications.log"
  run bash "$REPO_ROOT/scripts/heartbeat/notifiers/log.sh" "run-2" "ok" <<<"hola"
  [ "$status" -eq 0 ]
  run jq -r '.ok' <<<"$output"; [ "$output" = "true" ]
  grep -q "hola" "$NOTIFY_LOG_FILE"
  grep -q "run-2" "$NOTIFY_LOG_FILE"
}

@test "log.sh reports ok=false when log file cannot be written" {
  export NOTIFY_LOG_FILE="/this/path/does/not/exist/notifications.log"
  run bash "$REPO_ROOT/scripts/heartbeat/notifiers/log.sh" "run-3" "ok" <<<"msg"
  [ "$status" -eq 0 ]
  json="$output"
  run jq -r '.ok' <<<"$json"; [ "$output" = "false" ]
  run jq -r '.error' <<<"$json"; [[ "$output" == *"cannot"* || "$output" == *"write"* || "$output" == *"No such"* ]]
}

@test "telegram.sh reports ok=false when token/chat_id missing" {
  unset NOTIFY_BOT_TOKEN NOTIFY_CHAT_ID
  run bash "$REPO_ROOT/scripts/heartbeat/notifiers/telegram.sh" "run-4" "ok" <<<"msg"
  [ "$status" -eq 0 ]
  json="$output"
  run jq -r '.ok' <<<"$json"; [ "$output" = "false" ]
  run jq -r '.error' <<<"$json"; [[ "$output" == *"token"* || "$output" == *"chat"* ]]
}

@test "telegram.sh exits 0 even on network failure" {
  export NOTIFY_BOT_TOKEN="00000:FAKE"
  export NOTIFY_CHAT_ID="1"
  export NOTIFY_TELEGRAM_API_BASE="http://127.0.0.1:1"
  run bash "$REPO_ROOT/scripts/heartbeat/notifiers/telegram.sh" "run-5" "ok" <<<"msg"
  [ "$status" -eq 0 ]
  run jq -r '.ok' <<<"$output"; [ "$output" = "false" ]
}
