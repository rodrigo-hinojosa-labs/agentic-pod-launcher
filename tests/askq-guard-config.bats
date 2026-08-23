#!/usr/bin/env bats
#
# 031 — features.askuserquestion_guard toggle backfill (agent.yml as single source
# of truth). A pre-031 workspace has no features.askuserquestion_guard block;
# --regenerate must backfill it, deriving `enabled` from whether the Telegram plugin
# is in plugins[] (the channel the guard protects). An operator's existing block
# survives untouched. Mirrors tests/reply-guard-config.bats (028).

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
# and no features.askuserquestion_guard. $1 = channel, $2 = plugins YAML lines.
_write_agent_yml() {
  local channel="$1" plugins="$2"
  cat > "$TMP_TEST_DIR/agent.yml" << EOF
version: 1
agent:
  name: aq-bot
  display_name: "AQ"
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
  workspace: "/tmp/aq-bot"
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

@test "031: --regenerate backfills askuserquestion_guard.enabled=true when telegram plugin present" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml telegram "plugins:
  - telegram@claude-plugins-official
  - claude-mem@thedotmack"
  [ "$(yq -r '.features | has("askuserquestion_guard")' agent.yml)" = "false" ]
  echo 'n' | ./setup.sh --regenerate
  [ "$(yq -r '.features.askuserquestion_guard.enabled' agent.yml)" = "true" ]
  [ "$(yq -r '.features.askuserquestion_guard.max_attempts' agent.yml)" = "1" ]
}

@test "031: --regenerate backfills askuserquestion_guard.enabled=false when no telegram plugin" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml none "plugins:
  - claude-mem@thedotmack"
  echo 'n' | ./setup.sh --regenerate
  [ "$(yq -r '.features.askuserquestion_guard.enabled' agent.yml)" = "false" ]
  [ "$(yq -r '.features.askuserquestion_guard.max_attempts' agent.yml)" = "1" ]
}

@test "031: --regenerate preserves an operator-set askuserquestion_guard block (enabled:false, max_attempts:2)" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml telegram "plugins:
  - telegram@claude-plugins-official"
  yq -i '.features.askuserquestion_guard.enabled = false' agent.yml
  yq -i '.features.askuserquestion_guard.max_attempts = 2' agent.yml
  echo 'n' | ./setup.sh --regenerate
  # operator wins: neither field is clobbered by the backfill
  [ "$(yq -r '.features.askuserquestion_guard.enabled' agent.yml)" = "false" ]
  [ "$(yq -r '.features.askuserquestion_guard.max_attempts' agent.yml)" = "2" ]
}

@test "031: enabled → scripts/hooks/askq-guard.sh + installer rendered" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml telegram "plugins:
  - telegram@claude-plugins-official"
  echo 'n' | ./setup.sh --regenerate
  [ -x "$TMP_TEST_DIR/scripts/hooks/askq-guard.sh" ]
  [ -x "$TMP_TEST_DIR/scripts/hooks/install-askq-guard-hook.sh" ]
}

@test "031: disabled (no telegram) → scripts/hooks/askq-guard.sh NOT rendered" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml none "plugins:
  - claude-mem@thedotmack"
  echo 'n' | ./setup.sh --regenerate
  [ ! -e "$TMP_TEST_DIR/scripts/hooks/askq-guard.sh" ]
}

@test "031: two --regenerate runs render askq-guard.sh + installer byte-identical (SC-006)" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml telegram "plugins:
  - telegram@claude-plugins-official"
  echo 'n' | ./setup.sh --regenerate
  cp scripts/hooks/askq-guard.sh scripts/hooks/askq-guard.sh.first
  cp scripts/hooks/install-askq-guard-hook.sh scripts/hooks/install-askq-guard-hook.sh.first
  echo 'n' | ./setup.sh --regenerate
  diff scripts/hooks/askq-guard.sh scripts/hooks/askq-guard.sh.first
  diff scripts/hooks/install-askq-guard-hook.sh scripts/hooks/install-askq-guard-hook.sh.first
}
