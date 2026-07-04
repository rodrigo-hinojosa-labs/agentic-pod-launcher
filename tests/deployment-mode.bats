#!/usr/bin/env bats
# 011-local-standalone-mode (US1): deployment.mode branching in setup.sh.
#
# Host-runnable (no Docker). Drives the regenerate path with a seeded agent.yml
# so we can assert: docker mode stays byte-identical (compose + mirror render),
# local mode skips ALL Docker artifacts while still rendering the config base,
# and a mode switch on --regenerate WARNS about orphans without deleting them
# (FR-005a / G1).

load helper

setup() {
  setup_tmp_dir
  cp -r "$REPO_ROOT/scripts" "$REPO_ROOT/modules" "$TMP_TEST_DIR/"
  cp "$REPO_ROOT/setup.sh" "$TMP_TEST_DIR/"
  touch "$TMP_TEST_DIR/.env"
}

teardown() { teardown_tmp_dir; }

# Seed an agent.yml with the given deployment.mode (default docker).
_seed_agent_yml() {
  local mode="${1:-docker}"
  cat > "$TMP_TEST_DIR/agent.yml" << EOF
version: 1
agent:
  name: mode-bot
  display_name: "ModeBot"
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
  workspace: "/tmp/mode-bot"
  install_service: false
  claude_cli: "claude"
  mode: ${mode}
docker:
  image_tag: "agent-admin:latest"
  uid: 1000
  gid: 1000
  base_image: "alpine:3.20"
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
vault:
  enabled: true
  path: .state/.vault
  seed_skeleton: true
  mcp:
    enabled: true
    server: vault
plugins: []
EOF
}

@test "deployment.mode=docker: regenerate renders compose + docker mirror (byte-identical path)" {
  cd "$TMP_TEST_DIR"
  _seed_agent_yml docker
  run bash -c "echo 'n' | ./setup.sh --regenerate"
  [ "$status" -eq 0 ]
  [ -f docker-compose.yml ]
  [ -f docker/scripts/lib/plugin-catalog.sh ]
  # config base also present
  [ -f CLAUDE.md ]
  [ -f .mcp.json ]
  [ -f scripts/heartbeat/heartbeat.conf ]
}

@test "deployment.mode=local: regenerate skips compose + mirror, still renders base" {
  cd "$TMP_TEST_DIR"
  _seed_agent_yml local
  run bash -c "echo 'n' | ./setup.sh --regenerate"
  [ "$status" -eq 0 ]
  # NO Docker artifacts
  [ ! -f docker-compose.yml ]
  [ ! -f docker/scripts/lib/plugin-catalog.sh ]
  # config base IS present
  [ -f CLAUDE.md ]
  [ -f .mcp.json ]
  [ -f scripts/heartbeat/heartbeat.conf ]
  jq . .mcp.json > /dev/null
}

@test "mode switch docker→local warns about orphaned compose and does NOT delete it (FR-005a/G1)" {
  cd "$TMP_TEST_DIR"
  _seed_agent_yml docker
  echo 'n' | ./setup.sh --regenerate
  [ -f docker-compose.yml ]
  # Switch to local and regenerate.
  yq -i '.deployment.mode = "local"' agent.yml
  run bash -c "echo 'n' | ./setup.sh --regenerate"
  [ "$status" -eq 0 ]
  # A warning that lists the orphaned docker artifact…
  [[ "$output" == *"docker-compose.yml"* ]]
  echo "$output" | grep -qiE "orphan|huérfan|no longer|previous mode|leftover"
  # …but the file is NOT deleted.
  [ -f docker-compose.yml ]
}
