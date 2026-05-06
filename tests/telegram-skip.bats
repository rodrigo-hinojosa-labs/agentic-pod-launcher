#!/usr/bin/env bats

load helper

setup() {
  setup_tmp_dir
  mkdir -p "$TMP_TEST_DIR/installer"
  cp -r "$REPO_ROOT/scripts" "$REPO_ROOT/modules" "$TMP_TEST_DIR/installer/"
  cp "$REPO_ROOT/setup.sh" "$TMP_TEST_DIR/installer/"
  [ -f "$REPO_ROOT/.gitignore" ] && cp "$REPO_ROOT/.gitignore" "$TMP_TEST_DIR/installer/"
  [ -f "$REPO_ROOT/LICENSE" ] && cp "$REPO_ROOT/LICENSE" "$TMP_TEST_DIR/installer/"
}

teardown() { teardown_tmp_dir; }

@test "telegram channel allows skipping bot token and chat id" {
  local dest="$TMP_TEST_DIR/tg-skip"
  cd "$TMP_TEST_DIR/installer"
  # Use the wizard_answers helper (with notify=telegram + empty
  # notify_bot) so the stdin sequence stays in sync with setup.sh
  # whenever new wizard prompts are added. The previous hand-rolled
  # heredoc went stale when PR #37 introduced the optional-MCPs
  # catalog, causing the wizard to hang on stdin (the test ran fine
  # locally on already-warmed shells but timed out in CI at 15m).
  local stdin
  stdin=$(wizard_answers name=tg-bot display=TgBot notify=telegram)
  run ./setup.sh --destination "$dest" <<< "$stdin"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Telegram credentials incomplete"* ]]
  [ -f "$dest/.env" ]
  # agent.yml should still have channel: telegram
  [ "$(yq '.notifications.channel' "$dest/agent.yml")" = "telegram" ]
  # .env should have empty NOTIFY_* placeholders so user can fill in later
  grep -q "^NOTIFY_BOT_TOKEN=$" "$dest/.env"
  grep -q "^NOTIFY_CHAT_ID=$" "$dest/.env"
}
