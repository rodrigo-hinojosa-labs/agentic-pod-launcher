#!/usr/bin/env bats

load helper

setup() {
  setup_tmp_dir
  # Copy entire repo (simulating a fresh clone)
  cp -r "$REPO_ROOT/." "$TMP_TEST_DIR/"
  cd "$TMP_TEST_DIR"
  # Remove any state from the current working copy
  rm -f agent.yml .env CLAUDE.md .mcp.json .env.example
}

teardown() { teardown_tmp_dir; }

@test "E2E: fresh wizard with defaults produces functional agent" {
  cd "$TMP_TEST_DIR"
  local dest="$TMP_TEST_DIR/e2e-bot-dest"
  # Using --destination to scaffold to a known path
  # Answers (--destination skips the workspace prompt):
  # 1. agent name (e2e-bot)
  # 2. agent display (E2EBot 🤖)
  # 3. agent role (Test role)
  # 4. agent vibe (Test vibe)
  # 5. user full name (Test User)
  # 6. user nickname (Test)
  # 7. timezone (UTC)
  # 8. email (test@example.com)
  # Prompt order (host auto-detected, workspace from --destination):
  #  1  agent_name          → e2e-bot
  #  2  agent_display       → E2EBot 🤖
  #  3  agent_role          → Test role
  #  4  agent_vibe          → Test vibe
  #  5  user_name           → Test User
  #  6  user_nick           → Test
  #  7  user_tz             → UTC
  #  8  user_email          → test@example.com
  #  9  user_lang           → en
  # 10  deploy_svc          → n  (Linux only; macOS skips this prompt)
  # 11  fork_enabled        → n
  # 12  notify_channel      → none
  # 13  atlassian?          → n
  # 14  github?             → n
  # 15  hb_enabled          → y
  # 16  hb_interval         → 30m
  # 17  hb_prompt           → Test prompt
  # 18  use_defaults        → y
  # 19  review              → proceed
  local answers
  answers=(
    "e2e-bot" "E2EBot 🤖" "Test role" "Test vibe"
    "Test User" "Test" "UTC" "test@example.com" "en"
  )
  [ "$(uname -s)" = "Linux" ] && answers+=("n")
  answers+=("n" "none" "n" "n" "y" "30m" "Test prompt" "y" "proceed")
  run bash -c "printf '%s\n' \"\${@}\" | ./setup.sh --destination \"${dest}\"" -- "${answers[@]}"
  [ "$status" -eq 0 ]

  # agent.yml should be MOVED to destination
  [ ! -f agent.yml ]
  [ -f "$dest/agent.yml" ]
  [ -f "$dest/.env" ]

  # Content checks for agent.yml
  [ "$(yq '.agent.name' "$dest/agent.yml")" = "e2e-bot" ]
  [ "$(yq '.agent.display_name' "$dest/agent.yml")" = "E2EBot 🤖" ]
  [ "$(yq '.user.name' "$dest/agent.yml")" = "Test User" ]
  [ "$(yq '.user.nickname' "$dest/agent.yml")" = "Test" ]
  # deployment.host is auto-detected from hostname; just verify it's non-empty
  [ -n "$(yq '.deployment.host' "$dest/agent.yml")" ]
  [ "$(yq '.notifications.channel' "$dest/agent.yml")" = "none" ]
  [ "$(yq '.features.heartbeat.enabled' "$dest/agent.yml")" = "true" ]
  [ "$(yq '.features.heartbeat.interval' "$dest/agent.yml")" = "30m" ]
  [ "$(yq '.features.heartbeat.default_prompt' "$dest/agent.yml")" = "Test prompt" ]

  # Verify all derived files exist in destination
  [ -f "$dest/CLAUDE.md" ]
  [ -f "$dest/.mcp.json" ]
  [ -f "$dest/.env.example" ]
  [ -f "$dest/scripts/heartbeat/heartbeat.conf" ]

  # CLAUDE.md should contain agent display name
  grep -q "E2EBot" "$dest/CLAUDE.md"

  # .mcp.json should be valid JSON
  jq . "$dest/.mcp.json" > /dev/null

  # heartbeat.conf should have the interval
  grep -q 'HEARTBEAT_INTERVAL="30m"' "$dest/scripts/heartbeat/heartbeat.conf"

  # Git repo on correct branch
  [ "$(git -C "$dest" rev-parse --abbrev-ref HEAD)" = "e2e-bot/live" ]

  # Now run regenerate from within destination to prove it's self-contained
  run bash -c "echo 'n' | '$dest/setup.sh' --regenerate"
  [ "$status" -eq 0 ]
}
