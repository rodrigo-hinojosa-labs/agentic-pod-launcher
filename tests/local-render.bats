#!/usr/bin/env bats
# 011-local-standalone-mode (US2): render the local systemd artifacts from an
# agent.yml with mode=local and assert the production-verified invariants
# (contracts/systemd-remote-control.md). Host-runnable; no systemd needed.

load helper

setup() {
  setup_tmp_dir
  load_lib render
  load_lib yaml
  yaml_require_yq >/dev/null
  cat > "$TMP_TEST_DIR/agent.yml" << 'YML'
version: 1
agent:
  name: locbot
  display_name: "LocBot"
  role: "r"
  vibe: "v"
user:
  name: "A"
  nickname: "A"
  timezone: "UTC"
  email: "a@b.com"
  language: "en"
deployment:
  host: "rpi5"
  workspace: "/home/op/agents/locbot"
  install_service: true
  claude_cli: "claude"
  mode: local
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
YML
  render_load_context "$TMP_TEST_DIR/agent.yml" >/dev/null
  # Operator/host context resolved on the target host at render time (mirrors
  # what setup.sh exports in the local branch of regenerate/install_service).
  export OPERATOR_USER="op"
  export OPERATOR_HOME="/home/op"
  export HOST_NAME="rpi5"
  export CLAUDE_BIN="/usr/local/bin/claude"
}

teardown() { teardown_tmp_dir; }

@test "systemd unit: User is the resolved operator (never root by default)" {
  render_to_file "$REPO_ROOT/modules/systemd-remote-control.service.tpl" "$TMP_TEST_DIR/unit"
  grep -q '^User=op$' "$TMP_TEST_DIR/unit"
}

@test "systemd unit: ExecStart uses the absolute claude path + stable <host>-<name>" {
  render_to_file "$REPO_ROOT/modules/systemd-remote-control.service.tpl" "$TMP_TEST_DIR/unit"
  grep -q '^ExecStart=/usr/local/bin/claude remote-control --name rpi5-locbot --spawn=session --verbose$' "$TMP_TEST_DIR/unit"
}

@test "systemd unit: Restart=always (NOT on-failure)" {
  render_to_file "$REPO_ROOT/modules/systemd-remote-control.service.tpl" "$TMP_TEST_DIR/unit"
  grep -qE '^Restart=always$' "$TMP_TEST_DIR/unit"
  ! grep -qE '^Restart=on-failure' "$TMP_TEST_DIR/unit"
}

@test "systemd unit: ExecCondition guards on .credentials.json" {
  render_to_file "$REPO_ROOT/modules/systemd-remote-control.service.tpl" "$TMP_TEST_DIR/unit"
  grep -q 'ExecCondition=' "$TMP_TEST_DIR/unit"
  grep -q '.credentials.json' "$TMP_TEST_DIR/unit"
}

@test "systemd unit: ExecStart is remote-control --spawn=session, never skip-permissions" {
  render_to_file "$REPO_ROOT/modules/systemd-remote-control.service.tpl" "$TMP_TEST_DIR/unit"
  grep -q 'remote-control' "$TMP_TEST_DIR/unit"
  grep -q -- '--name' "$TMP_TEST_DIR/unit"
  grep -q -- '--spawn=session' "$TMP_TEST_DIR/unit"
  ! grep -q -- '--dangerously-skip-permissions' "$TMP_TEST_DIR/unit"
}

@test "systemd unit: WorkingDirectory is the workspace (never /)" {
  render_to_file "$REPO_ROOT/modules/systemd-remote-control.service.tpl" "$TMP_TEST_DIR/unit"
  grep -q '^WorkingDirectory=/home/op/agents/locbot$' "$TMP_TEST_DIR/unit"
}

@test "systemd unit: EnvironmentFile points at .state/remote-control.env" {
  render_to_file "$REPO_ROOT/modules/systemd-remote-control.service.tpl" "$TMP_TEST_DIR/unit"
  grep -q '^EnvironmentFile=/home/op/agents/locbot/.state/remote-control.env$' "$TMP_TEST_DIR/unit"
}

@test "systemd unit: restart budget + RestartSec present" {
  render_to_file "$REPO_ROOT/modules/systemd-remote-control.service.tpl" "$TMP_TEST_DIR/unit"
  grep -q '^RestartSec=10$' "$TMP_TEST_DIR/unit"
  grep -q '^StartLimitIntervalSec=300$' "$TMP_TEST_DIR/unit"
  grep -q '^StartLimitBurst=5$' "$TMP_TEST_DIR/unit"
}

@test "env file: CLAUDE_CONFIG_DIR under .state/.claude + autoupdater off, NO api key" {
  render_to_file "$REPO_ROOT/modules/remote-control.env.tpl" "$TMP_TEST_DIR/env"
  grep -q '^CLAUDE_CONFIG_DIR=/home/op/agents/locbot/.state/.claude$' "$TMP_TEST_DIR/env"
  grep -q '^DISABLE_AUTOUPDATER=1$' "$TMP_TEST_DIR/env"
  grep -q '^HOME=/home/op$' "$TMP_TEST_DIR/env"
  ! grep -q 'ANTHROPIC_API_KEY' "$TMP_TEST_DIR/env"
}

@test "env file: PATH prepends the operator ~/.local/bin so systemd finds uv/npx/github-mcp-server (RC-B)" {
  # The unit inherits systemd's minimal default PATH (/usr/local/bin:/usr/bin:…),
  # which excludes the operator's ~/.local/bin, nvm node, etc. Without this line
  # every MCP runtime spawn fails with ENOENT under the unit (validated on
  # mclaren). agent-bootstrap.sh funnels all runtimes into ~/.local/bin.
  render_to_file "$REPO_ROOT/modules/remote-control.env.tpl" "$TMP_TEST_DIR/env"
  grep -qE '^PATH=/home/op/\.local/bin:' "$TMP_TEST_DIR/env"
  # still includes the system dirs the unit needs
  grep -qE '^PATH=[^[:space:]]*:/usr/local/bin:/usr/bin:/bin' "$TMP_TEST_DIR/env"
}
