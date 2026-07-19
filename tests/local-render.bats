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

# ─── 021-local-secret-delivery: workspace .env delivery ─────────────────────
# contracts/secret-delivery.md invariants U1-U4.

@test "systemd unit (U2): workspace .env is loaded with the '-' (ignore-if-missing) prefix" {
  render_to_file "$REPO_ROOT/modules/systemd-remote-control.service.tpl" "$TMP_TEST_DIR/unit"
  grep -q '^EnvironmentFile=-/home/op/agents/locbot/.env$' "$TMP_TEST_DIR/unit"
}

@test "systemd unit (U1): the .env line comes BEFORE remote-control.env (later file wins in systemd)" {
  # Load-bearing on the LINE NUMBER, not just presence: remote-control.env's
  # PATH/HOME/CLAUDE_CONFIG_DIR must always beat a stray line in .env, or every
  # MCP spawn ENOENTs (the historical 203/EXEC failure). A comment can't
  # enforce this — only a numeric ordering assertion can.
  render_to_file "$REPO_ROOT/modules/systemd-remote-control.service.tpl" "$TMP_TEST_DIR/unit"
  local env_line rc_line
  env_line=$(grep -n '^EnvironmentFile=-/home/op/agents/locbot/\.env$' "$TMP_TEST_DIR/unit" | cut -d: -f1)
  rc_line=$(grep -n '^EnvironmentFile=/home/op/agents/locbot/\.state/remote-control\.env$' "$TMP_TEST_DIR/unit" | cut -d: -f1)
  [ -n "$env_line" ]
  [ -n "$rc_line" ]
  [ "$env_line" -lt "$rc_line" ]
}

@test "systemd unit (U3): ExecStartPre runs the boot secret-check, ignore-if-failed" {
  render_to_file "$REPO_ROOT/modules/systemd-remote-control.service.tpl" "$TMP_TEST_DIR/unit"
  grep -q '^ExecStartPre=-/home/op/agents/locbot/scripts/local/agent-secret-check\.sh$' "$TMP_TEST_DIR/unit"
}

@test "systemd unit: never uses the unsafe Environment= directive for secrets" {
  render_to_file "$REPO_ROOT/modules/systemd-remote-control.service.tpl" "$TMP_TEST_DIR/unit"
  if grep -qE '^Environment=' "$TMP_TEST_DIR/unit"; then false; fi
}

# ─── 022-local-session-lifecycle: session pointer hygiene ───────────────────
# contracts/session-pointer-hygiene.md §3.1 (ordering) and §2.

@test "022 unit: a second ExecStartPre runs the session check, ignore-if-failed" {
  render_to_file "$REPO_ROOT/modules/systemd-remote-control.service.tpl" "$TMP_TEST_DIR/unit"
  grep -q '^ExecStartPre=-/home/op/agents/locbot/scripts/local/agent-session-check\.sh$' "$TMP_TEST_DIR/unit"
}

@test "022 unit: the session check runs AFTER the 021 secret check" {
  # Ordering is load-bearing on the line number: systemd runs multiple
  # ExecStartPre= sequentially in declaration order, and the session check must
  # not displace 021's boot warning.
  render_to_file "$REPO_ROOT/modules/systemd-remote-control.service.tpl" "$TMP_TEST_DIR/unit"
  local secret_line session_line
  secret_line=$(grep -n '^ExecStartPre=-.*agent-secret-check\.sh$' "$TMP_TEST_DIR/unit" | cut -d: -f1)
  session_line=$(grep -n '^ExecStartPre=-.*agent-session-check\.sh$' "$TMP_TEST_DIR/unit" | cut -d: -f1)
  [ -n "$secret_line" ]
  [ -n "$session_line" ]
  [ "$secret_line" -lt "$session_line" ]
}

@test "022 unit: both session hooks run BEFORE ExecStart reads the pointer" {
  render_to_file "$REPO_ROOT/modules/systemd-remote-control.service.tpl" "$TMP_TEST_DIR/unit"
  local session_line exec_line
  session_line=$(grep -n '^ExecStartPre=-.*agent-session-check\.sh$' "$TMP_TEST_DIR/unit" | cut -d: -f1)
  exec_line=$(grep -n '^ExecStart=' "$TMP_TEST_DIR/unit" | cut -d: -f1)
  [ -n "$session_line" ]
  [ -n "$exec_line" ]
  [ "$session_line" -lt "$exec_line" ]
}

@test "022 unit: ExecStopPost records the exit cause, ignore-if-failed" {
  render_to_file "$REPO_ROOT/modules/systemd-remote-control.service.tpl" "$TMP_TEST_DIR/unit"
  grep -q '^ExecStopPost=-/home/op/agents/locbot/scripts/local/agent-session-exit\.sh$' "$TMP_TEST_DIR/unit"
}

@test "022 unit: the 021 EnvironmentFile pair keeps its order after the new directives" {
  # Regression guard for SC-008: inserting directives must not reorder these.
  render_to_file "$REPO_ROOT/modules/systemd-remote-control.service.tpl" "$TMP_TEST_DIR/unit"
  local env_line rc_line
  env_line=$(grep -n '^EnvironmentFile=-/home/op/agents/locbot/\.env$' "$TMP_TEST_DIR/unit" | cut -d: -f1)
  rc_line=$(grep -n '^EnvironmentFile=/home/op/agents/locbot/\.state/remote-control\.env$' "$TMP_TEST_DIR/unit" | cut -d: -f1)
  [ "$env_line" -lt "$rc_line" ]
}

@test "U4: the healthcheck timer's service unit has NO EnvironmentFile for .env" {
  render_to_file "$REPO_ROOT/modules/local-healthcheck.service.tpl" "$TMP_TEST_DIR/hc.service"
  if grep -q 'EnvironmentFile' "$TMP_TEST_DIR/hc.service"; then false; fi
}

@test "U4: the qmd-reindex unit has NO EnvironmentFile" {
  render_to_file "$REPO_ROOT/modules/local-qmd-reindex.service.tpl" "$TMP_TEST_DIR/u"
  if grep -q 'EnvironmentFile' "$TMP_TEST_DIR/u"; then false; fi
}

@test "U4: the qmd-watch unit has NO EnvironmentFile" {
  render_to_file "$REPO_ROOT/modules/local-qmd-watch.service.tpl" "$TMP_TEST_DIR/u"
  if grep -q 'EnvironmentFile' "$TMP_TEST_DIR/u"; then false; fi
}

@test "U4: the vault-backup unit has NO EnvironmentFile" {
  render_to_file "$REPO_ROOT/modules/local-vault-backup.service.tpl" "$TMP_TEST_DIR/u"
  if grep -q 'EnvironmentFile' "$TMP_TEST_DIR/u"; then false; fi
}

@test "U4: the wiki-graph unit has NO EnvironmentFile" {
  render_to_file "$REPO_ROOT/modules/local-wiki-graph.service.tpl" "$TMP_TEST_DIR/u"
  if grep -q 'EnvironmentFile' "$TMP_TEST_DIR/u"; then false; fi
}

@test "021 T014: local-secret-check.sh.tpl renders, carries the render header, and never hardcodes 'do not hand-edit' as a lie" {
  render_to_file "$REPO_ROOT/modules/local-secret-check.sh.tpl" "$TMP_TEST_DIR/agent-secret-check.sh"
  grep -q 'Rendered from modules/local-secret-check.sh.tpl' "$TMP_TEST_DIR/agent-secret-check.sh"
  grep -q '^WORKSPACE="/home/op/agents/locbot"$' "$TMP_TEST_DIR/agent-secret-check.sh"
  grep -q '^exit 0$' "$TMP_TEST_DIR/agent-secret-check.sh"
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
