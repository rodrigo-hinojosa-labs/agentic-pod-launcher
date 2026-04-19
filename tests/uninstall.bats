#!/usr/bin/env bats

load helper

setup() {
  setup_tmp_dir
  cp -r "$REPO_ROOT/scripts" "$REPO_ROOT/modules" "$TMP_TEST_DIR/"
  cp "$REPO_ROOT/setup.sh" "$TMP_TEST_DIR/"
  cat > "$TMP_TEST_DIR/agent.yml" << 'EOF'
version: 1
agent:
  name: uninst-bot
  display_name: "UninstBot"
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
  workspace: "/tmp/uninst-bot"
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
plugins: []
EOF
  touch "$TMP_TEST_DIR/.env"
}

teardown() { teardown_tmp_dir; }

@test "--uninstall --yes removes generated files but preserves agent.yml and .env" {
  cd "$TMP_TEST_DIR"
  ./setup.sh --non-interactive >/dev/null
  [ -f CLAUDE.md ]
  [ -f .mcp.json ]
  [ -f scripts/heartbeat/heartbeat.conf ]

  run ./setup.sh --uninstall --yes
  [ "$status" -eq 0 ]
  [ ! -f CLAUDE.md ]
  [ ! -f .mcp.json ]
  [ ! -f .env.example ]
  [ ! -f scripts/heartbeat/heartbeat.conf ]
  [ -f agent.yml ]
  [ -f .env ]
}

@test "--uninstall --purge --yes also removes agent.yml and .env" {
  cd "$TMP_TEST_DIR"
  ./setup.sh --non-interactive >/dev/null
  run ./setup.sh --uninstall --purge --yes
  [ "$status" -eq 0 ]
  [ ! -f agent.yml ]
  [ ! -f .env ]
  [ ! -f CLAUDE.md ]
}

@test "--uninstall without agent.yml fails clearly" {
  cd "$TMP_TEST_DIR"
  rm -f agent.yml
  run ./setup.sh --uninstall --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"agent.yml not found"* ]]
}

@test "--uninstall prompts for confirmation when --yes is not passed" {
  cd "$TMP_TEST_DIR"
  ./setup.sh --non-interactive >/dev/null
  # Answer 'n' to abort — files should remain
  run bash -c "echo 'n' | ./setup.sh --uninstall"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Aborted."* ]]
  [ -f CLAUDE.md ]
}
