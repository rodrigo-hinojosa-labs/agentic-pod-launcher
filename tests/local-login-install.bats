#!/usr/bin/env bats
# 011-local-standalone-mode (US2): the rendered agent-login.sh must INSTALL the
# staged systemd unit when it isn't yet under the systemd dir. The scaffold
# stages the unit in the workspace when `sudo -n` is unavailable
# (install_service, setup.sh), so a fresh `--login` lands on a staged-but-not-
# installed unit. Regression validated on mclaren: login succeeded but the
# service stayed not-found/inactive because the helper only `enable`d an
# already-installed unit and never copied the staged one into place.
#
# Host-runnable: no real systemd. `claude`/`sudo`/`systemctl` are stubbed on
# PATH; the systemd dir is redirected via LOGIN_SYSTEMD_DIR (same injection
# pattern as heartbeatctl's HEARTBEATCTL_* overrides).

load helper

setup() {
  setup_tmp_dir
  command -v jq >/dev/null || skip "jq not installed"
  load_lib render
  load_lib yaml
  yaml_require_yq >/dev/null

  WS="$TMP_TEST_DIR/ws"
  mkdir -p "$WS/scripts/local" "$WS/scripts/lib" "$WS/.state/.claude"
  cp "$REPO_ROOT/scripts/lib/local_trust.sh" "$WS/scripts/lib/"

  cat > "$TMP_TEST_DIR/agent.yml" << YML
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
  workspace: "$WS"
  install_service: true
  claude_cli: "claude"
  mode: local
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

  BIN="$TMP_TEST_DIR/bin"; mkdir -p "$BIN"
  # claude stub: report a Remote-Control-capable version; login is a no-op
  # (never reached — we pre-seed .credentials.json below).
  cat > "$BIN/claude" << 'SH'
#!/usr/bin/env bash
case "$1" in
  --version) echo "2.1.181 (Claude Code)" ;;
  *) : ;;
esac
SH
  # systemctl stub: append every invocation to a log, succeed.
  cat > "$BIN/systemctl" << SH
#!/usr/bin/env bash
echo "systemctl \$*" >> "$TMP_TEST_DIR/systemctl.log"
SH
  # sudo stub: drop the "sudo" prefix and exec the rest.
  cat > "$BIN/sudo" << 'SH'
#!/usr/bin/env bash
exec "$@"
SH
  chmod +x "$BIN/claude" "$BIN/systemctl" "$BIN/sudo"
  export PATH="$BIN:$PATH"
  export CLAUDE_BIN="$BIN/claude"

  export LOGIN_SYSTEMD_DIR="$TMP_TEST_DIR/systemd"
  mkdir -p "$LOGIN_SYSTEMD_DIR"

  LOGIN="$WS/scripts/local/agent-login.sh"
  render_to_file "$REPO_ROOT/modules/local-login.sh.tpl" "$LOGIN"
  chmod +x "$LOGIN"

  # Pre-seed credentials so the interactive OAuth branch is skipped.
  echo '{}' > "$WS/.state/.claude/.credentials.json"
}

teardown() { teardown_tmp_dir; }

@test "login: installs the staged unit when it isn't under the systemd dir" {
  # Scaffold staged the unit in the workspace root (setup.sh install_service).
  printf 'STAGED-UNIT\n' > "$WS/agent-locbot.service"
  [ ! -f "$LOGIN_SYSTEMD_DIR/agent-locbot.service" ]

  run "$LOGIN"
  [ "$status" -eq 0 ]

  # The staged unit was copied into the systemd dir...
  [ -f "$LOGIN_SYSTEMD_DIR/agent-locbot.service" ]
  grep -q 'STAGED-UNIT' "$LOGIN_SYSTEMD_DIR/agent-locbot.service"
  # ...the daemon was reloaded and the unit enabled+started.
  grep -q 'daemon-reload' "$TMP_TEST_DIR/systemctl.log"
  grep -q 'enable --now agent-locbot.service' "$TMP_TEST_DIR/systemctl.log"
}

@test "login: does NOT clobber an already-installed unit, still enables it" {
  printf 'INSTALLED\n' > "$LOGIN_SYSTEMD_DIR/agent-locbot.service"
  printf 'STAGED-DIFFERENT\n' > "$WS/agent-locbot.service"

  run "$LOGIN"
  [ "$status" -eq 0 ]

  # Installed copy is left untouched (idempotent — matches the original
  # enable-only behavior when the unit is already in place).
  grep -q 'INSTALLED' "$LOGIN_SYSTEMD_DIR/agent-locbot.service"
  ! grep -q 'STAGED-DIFFERENT' "$LOGIN_SYSTEMD_DIR/agent-locbot.service"
  grep -q 'enable --now agent-locbot.service' "$TMP_TEST_DIR/systemctl.log"
}

@test "login: neither installed nor staged -> warns, no enable, exits clean" {
  [ ! -f "$LOGIN_SYSTEMD_DIR/agent-locbot.service" ]
  [ ! -f "$WS/agent-locbot.service" ]

  run "$LOGIN"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'not installed'
  [ ! -f "$TMP_TEST_DIR/systemctl.log" ] || ! grep -q 'enable --now' "$TMP_TEST_DIR/systemctl.log"
}

@test "login: re-applies workspace trust after login (preserved behavior)" {
  printf 'STAGED-UNIT\n' > "$WS/agent-locbot.service"
  run "$LOGIN"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.projects["'"$WS"'"].hasTrustDialogAccepted' "$WS/.state/.claude/.claude.json")" = "true" ]
}

@test "login: pre-seeds remoteDialogSeen so the unit doesn't hang on the Enable-Remote-Control prompt" {
  printf 'STAGED-UNIT\n' > "$WS/agent-locbot.service"
  run "$LOGIN"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.remoteDialogSeen' "$WS/.state/.claude/.claude.json")" = "true" ]
}

@test "login: runs agent-bootstrap.sh (MCP runtimes) before enabling the unit" {
  printf 'STAGED-UNIT\n' > "$WS/agent-locbot.service"
  # Stub the bootstrap so we can observe that it ran, and when, relative to the
  # unit enable. It shares the systemctl.log so line order = execution order.
  cat > "$WS/scripts/local/agent-bootstrap.sh" << SH
#!/usr/bin/env bash
echo "BOOTSTRAP-RAN" >> "$TMP_TEST_DIR/systemctl.log"
SH
  chmod +x "$WS/scripts/local/agent-bootstrap.sh"

  run "$LOGIN"
  [ "$status" -eq 0 ]

  grep -q 'BOOTSTRAP-RAN' "$TMP_TEST_DIR/systemctl.log"
  # Runtimes must be provisioned BEFORE the unit's first start.
  boot_line=$(grep -n 'BOOTSTRAP-RAN' "$TMP_TEST_DIR/systemctl.log" | head -1 | cut -d: -f1)
  enable_line=$(grep -n 'enable --now agent-locbot.service' "$TMP_TEST_DIR/systemctl.log" | head -1 | cut -d: -f1)
  [ -n "$boot_line" ] && [ -n "$enable_line" ] && [ "$boot_line" -lt "$enable_line" ]
}

@test "login: absent agent-bootstrap.sh is skipped cleanly (older workspace)" {
  printf 'STAGED-UNIT\n' > "$WS/agent-locbot.service"
  [ ! -f "$WS/scripts/local/agent-bootstrap.sh" ]
  run "$LOGIN"
  [ "$status" -eq 0 ]
  grep -q 'enable --now agent-locbot.service' "$TMP_TEST_DIR/systemctl.log"
}

@test "login: installs + enables the staged healthcheck timer/service (US3)" {
  printf 'STAGED-UNIT\n' > "$WS/agent-locbot.service"
  # install_service stages the healthcheck units under scripts/local/ when
  # sudo -n was unavailable at scaffold time.
  printf 'HC-SVC\n' > "$WS/scripts/local/agent-locbot-healthcheck.service"
  printf 'HC-TMR\n' > "$WS/scripts/local/agent-locbot-healthcheck.timer"
  [ ! -f "$LOGIN_SYSTEMD_DIR/agent-locbot-healthcheck.timer" ]

  run "$LOGIN"
  [ "$status" -eq 0 ]

  [ -f "$LOGIN_SYSTEMD_DIR/agent-locbot-healthcheck.service" ]
  [ -f "$LOGIN_SYSTEMD_DIR/agent-locbot-healthcheck.timer" ]
  grep -q 'HC-TMR' "$LOGIN_SYSTEMD_DIR/agent-locbot-healthcheck.timer"
  grep -q 'enable --now agent-locbot-healthcheck.timer' "$TMP_TEST_DIR/systemctl.log"
}

@test "login: installs healthcheck even when the main unit is already in place" {
  # mclaren's exact case: main unit already installed, healthcheck still staged.
  printf 'INSTALLED\n' > "$LOGIN_SYSTEMD_DIR/agent-locbot.service"
  printf 'HC-SVC\n' > "$WS/scripts/local/agent-locbot-healthcheck.service"
  printf 'HC-TMR\n' > "$WS/scripts/local/agent-locbot-healthcheck.timer"

  run "$LOGIN"
  [ "$status" -eq 0 ]
  [ -f "$LOGIN_SYSTEMD_DIR/agent-locbot-healthcheck.timer" ]
  grep -q 'enable --now agent-locbot-healthcheck.timer' "$TMP_TEST_DIR/systemctl.log"
}

@test "login: does NOT clobber an already-installed healthcheck timer" {
  printf 'STAGED-UNIT\n' > "$WS/agent-locbot.service"
  printf 'INSTALLED-TMR\n' > "$LOGIN_SYSTEMD_DIR/agent-locbot-healthcheck.timer"
  printf 'STAGED-TMR-DIFFERENT\n' > "$WS/scripts/local/agent-locbot-healthcheck.timer"

  run "$LOGIN"
  [ "$status" -eq 0 ]
  grep -q 'INSTALLED-TMR' "$LOGIN_SYSTEMD_DIR/agent-locbot-healthcheck.timer"
  ! grep -q 'STAGED-TMR-DIFFERENT' "$LOGIN_SYSTEMD_DIR/agent-locbot-healthcheck.timer"
}
