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
  # Answers: identity x4, user x5, deployment x2 (host, install_service=n),
  # notifications: telegram, <empty bot token>, <empty chat id>,
  # mcps x2 (atlassian=n, github=n), heartbeat y + interval + prompt,
  # principles y, confirm y
  run ./setup.sh --destination "$dest" <<EOF
tg-bot
TgBot
r
v
Alice
Alice
UTC
a@b.com
en
host
n
n
telegram


n
n
y
30m
ok
y
proceed
EOF
  [ "$status" -eq 0 ]
  [[ "$output" == *"Telegram credentials incomplete"* ]]
  [ -f "$dest/.env" ]
  # agent.yml should still have channel: telegram
  [ "$(yq '.notifications.channel' "$dest/agent.yml")" = "telegram" ]
  # .env should have empty NOTIFY_* placeholders so user can fill in later
  grep -q "^NOTIFY_BOT_TOKEN=$" "$dest/.env"
  grep -q "^NOTIFY_CHAT_ID=$" "$dest/.env"
}
