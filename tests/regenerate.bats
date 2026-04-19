#!/usr/bin/env bats

load helper

setup() {
  setup_tmp_dir
  cp -r "$REPO_ROOT/scripts" "$REPO_ROOT/modules" "$TMP_TEST_DIR/"
  cp "$REPO_ROOT/setup.sh" "$TMP_TEST_DIR/"
  cat > "$TMP_TEST_DIR/agent.yml" << 'EOF'
version: 1
agent:
  name: regen-bot
  display_name: "RegenBot"
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
  workspace: "/tmp/regen-bot"
  install_service: false
notifications:
  channel: none
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
plugins:
  - claude-mem@thedotmack
EOF
  touch "$TMP_TEST_DIR/.env"
}

teardown() { teardown_tmp_dir; }

@test "--regenerate produces expected files" {
  cd "$TMP_TEST_DIR"
  # Pipe 'n' to the plugin prompt so we skip actual plugin install
  run bash -c "echo 'n' | ./setup.sh --regenerate"
  [ "$status" -eq 0 ]
  [ -f CLAUDE.md ]
  [ -f .mcp.json ]
  [ -f .env.example ]
  [ -f scripts/heartbeat/heartbeat.conf ]
  grep -q "RegenBot" CLAUDE.md
  jq . .mcp.json > /dev/null
}

@test "--regenerate preserves existing CLAUDE.md" {
  cd "$TMP_TEST_DIR"
  echo 'n' | ./setup.sh --regenerate
  echo "USER EDIT" >> CLAUDE.md
  echo 'n' | ./setup.sh --regenerate
  grep -q "USER EDIT" CLAUDE.md
}

@test "--regenerate is idempotent" {
  cd "$TMP_TEST_DIR"
  echo 'n' | ./setup.sh --regenerate
  cp .mcp.json .mcp.json.first
  echo 'n' | ./setup.sh --regenerate
  diff .mcp.json .mcp.json.first
}

@test "--non-interactive regenerate skips plugin prompt" {
  cd "$TMP_TEST_DIR"
  run ./setup.sh --non-interactive
  [ "$status" -eq 0 ]
  [ -f .mcp.json ]
}
