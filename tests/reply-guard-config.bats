#!/usr/bin/env bats
#
# 028 — features.reply_guard toggle backfill (agent.yml as single source of truth).
# A pre-028 workspace has no features.reply_guard block; --regenerate must backfill
# it, deriving `enabled` from whether the Telegram plugin is in plugins[] (the reply
# path the guard protects). An operator's existing block survives untouched.

load helper

setup() {
  setup_tmp_dir
  cp -r "$REPO_ROOT/scripts" "$REPO_ROOT/modules" "$TMP_TEST_DIR/"
  cp "$REPO_ROOT/setup.sh" "$TMP_TEST_DIR/"
  touch "$TMP_TEST_DIR/.env"
  CLAUDE_STUB=$(install_claude_stub)
}

teardown() { teardown_tmp_dir; }

# Emit a minimal, schema-valid agent.yml (docker mode) with a given plugins block
# and no features.reply_guard. $1 = channel, $2 = plugins YAML lines.
_write_agent_yml() {
  local channel="$1" plugins="$2"
  cat > "$TMP_TEST_DIR/agent.yml" << EOF
version: 1
agent:
  name: rg-bot
  display_name: "RG"
  role: "r"
  vibe: "v"
  use_default_principles: true
user:
  name: "A"
  nickname: "A"
  timezone: "UTC"
  email: "a@b.com"
  language: "en"
deployment:
  host: "h"
  workspace: "/tmp/rg-bot"
  install_service: false
docker:
  image_tag: "agent-admin:latest"
  uid: 1000
  gid: 1000
  base_image: "alpine:3.20"
notifications:
  channel: ${channel}
features:
  heartbeat:
    enabled: true
    interval: "30m"
    timeout: 300
    retries: 1
    default_prompt: "ok"
mcps:
  atlassian: []
  github:
    enabled: false
${plugins}
EOF
}

@test "028: --regenerate backfills reply_guard.enabled=true when telegram plugin present" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml telegram "plugins:
  - telegram@claude-plugins-official
  - claude-mem@thedotmack"
  [ "$(yq -r '.features | has("reply_guard")' agent.yml)" = "false" ]
  echo 'n' | ./setup.sh --regenerate
  [ "$(yq -r '.features.reply_guard.enabled' agent.yml)" = "true" ]
  [ "$(yq -r '.features.reply_guard.max_attempts' agent.yml)" = "1" ]
}

@test "028: --regenerate backfills reply_guard.enabled=false when no telegram plugin" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml none "plugins:
  - claude-mem@thedotmack"
  echo 'n' | ./setup.sh --regenerate
  [ "$(yq -r '.features.reply_guard.enabled' agent.yml)" = "false" ]
  [ "$(yq -r '.features.reply_guard.max_attempts' agent.yml)" = "1" ]
}

@test "028: --regenerate preserves an operator-set reply_guard block (enabled:false, max_attempts:2)" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml telegram "plugins:
  - telegram@claude-plugins-official"
  yq -i '.features.reply_guard.enabled = false' agent.yml
  yq -i '.features.reply_guard.max_attempts = 2' agent.yml
  echo 'n' | ./setup.sh --regenerate
  # operator wins: neither field is clobbered by the backfill
  [ "$(yq -r '.features.reply_guard.enabled' agent.yml)" = "false" ]
  [ "$(yq -r '.features.reply_guard.max_attempts' agent.yml)" = "2" ]
}
