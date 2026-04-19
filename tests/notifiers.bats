#!/usr/bin/env bats

load helper

setup() { setup_tmp_dir; }
teardown() { teardown_tmp_dir; }

@test "notify_none is silent" {
  source "$REPO_ROOT/scripts/heartbeat/notifiers/none.sh"
  run notify_none "hello"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "notify_log writes to notifications.log" {
  export LOG_DIR="$TMP_TEST_DIR"
  source "$REPO_ROOT/scripts/heartbeat/notifiers/log.sh"
  notify_log "test message"
  [ -f "$TMP_TEST_DIR/notifications.log" ]
  grep -q "test message" "$TMP_TEST_DIR/notifications.log"
}

@test "notify_telegram is no-op without credentials" {
  unset NOTIFY_BOT_TOKEN NOTIFY_CHAT_ID
  source "$REPO_ROOT/scripts/heartbeat/notifiers/telegram.sh"
  run notify_telegram "hello"
  [ "$status" -eq 0 ]
}
