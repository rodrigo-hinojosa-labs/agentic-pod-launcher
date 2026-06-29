#!/usr/bin/env bats
# 011-local-standalone-mode (US3): the local healthcheck distinguishes
# alive / connected / expired, degrades gracefully without jq/creds, and the
# notify path keeps the token off argv (G3). Also asserts the login helper's
# version gate (G3/FR-014). Host-runnable with systemctl/journalctl stubs.

load helper

setup() {
  setup_tmp_dir
  load_lib render
  load_lib yaml
  yaml_require_yq >/dev/null
  command -v jq >/dev/null || skip "jq not installed"

  cat > "$TMP_TEST_DIR/agent.yml" << YML
version: 1
agent: {name: locbot, display_name: "LocBot", role: "r", vibe: "v"}
user: {name: A, nickname: A, timezone: UTC, email: a@b.com, language: en}
deployment: {host: rpi5, workspace: "$TMP_TEST_DIR", install_service: false, claude_cli: claude, mode: local}
docker: {image_tag: "x:latest", uid: 1000, gid: 1000, base_image: "alpine:3.20"}
notifications: {channel: none}
features: {heartbeat: {enabled: true, interval: "30m", timeout: 300, retries: 1, default_prompt: "ok"}}
YML
  render_load_context "$TMP_TEST_DIR/agent.yml" >/dev/null

  # Render the healthcheck under test.
  render_to_file "$REPO_ROOT/modules/local-healthcheck.sh.tpl" "$TMP_TEST_DIR/hc.sh"
  chmod +x "$TMP_TEST_DIR/hc.sh"

  # Stubs: systemctl is-active honors $STUB_ACTIVE; journalctl echoes $STUB_JOURNAL.
  mkdir -p "$TMP_TEST_DIR/bin"
  cat > "$TMP_TEST_DIR/bin/systemctl" << 'SH'
#!/usr/bin/env bash
case "$*" in *is-active*) exit "${STUB_ACTIVE:-0}" ;; *) exit 0 ;; esac
SH
  cat > "$TMP_TEST_DIR/bin/journalctl" << 'SH'
#!/usr/bin/env bash
printf '%s\n' "${STUB_JOURNAL:-}"
exit 0
SH
  chmod +x "$TMP_TEST_DIR/bin/"*
  export PATH="$TMP_TEST_DIR/bin:$PATH"

  CREDS_DIR="$TMP_TEST_DIR/.state/.claude"
  mkdir -p "$CREDS_DIR"
}

teardown() { teardown_tmp_dir; }

_write_creds() {  # _write_creds <expiresAt-ms>
  printf '{"claudeAiOauth":{"expiresAt":%s}}\n' "$1" > "$CREDS_DIR/.credentials.json"
}

@test "healthcheck OK: active + connected + valid login → exit 0" {
  _write_creds 99999999999999
  STUB_ACTIVE=0 STUB_JOURNAL="session url: https://x connected polling" run "$TMP_TEST_DIR/hc.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "healthcheck WARN: active + valid login but no connection signal → exit 1" {
  _write_creds 99999999999999
  STUB_ACTIVE=0 STUB_JOURNAL="just some boot noise" run "$TMP_TEST_DIR/hc.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"WARN"* ]]
  [[ "$output" == *"no connection signal"* ]]
}

@test "healthcheck WARN: login expiring within 24h → exit 1" {
  _write_creds "$(( ($(date +%s) + 1800) * 1000 ))"
  STUB_ACTIVE=0 STUB_JOURNAL="connected" run "$TMP_TEST_DIR/hc.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"expiring"* ]]
}

@test "healthcheck DEGRADED: 401 in journal → exit 2" {
  _write_creds 99999999999999
  STUB_ACTIVE=0 STUB_JOURNAL="API Error: 401 unauthorized" run "$TMP_TEST_DIR/hc.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"DEGRADED"* ]]
}

@test "healthcheck DEGRADED: login expired → exit 2" {
  _write_creds "$(( ($(date +%s) - 100) * 1000 ))"
  STUB_ACTIVE=0 STUB_JOURNAL="connected" run "$TMP_TEST_DIR/hc.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"expired"* ]]
}

@test "healthcheck DEGRADED: unit inactive → exit 2" {
  _write_creds 99999999999999
  STUB_ACTIVE=3 STUB_JOURNAL="connected" run "$TMP_TEST_DIR/hc.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"not active"* ]]
}

@test "healthcheck graceful degrade: credentials missing → WARN, no crash" {
  rm -f "$CREDS_DIR/.credentials.json"
  STUB_ACTIVE=0 STUB_JOURNAL="connected" run "$TMP_TEST_DIR/hc.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"credentials unavailable"* ]]
}

@test "G3: notify path keeps the token off argv (curl --config -)" {
  # Static guarantee on the rendered script: token flows via stdin config, never
  # as a curl command-line argument.
  grep -q 'curl -s --config -' "$TMP_TEST_DIR/hc.sh"
  ! grep -qE 'curl[^|]*(-d|--data|--header)[^|]*NOTIFY_BOT_TOKEN' "$TMP_TEST_DIR/hc.sh"
}

@test "G3/FR-014: login helper rejects Claude Code < 2.1.51" {
  export CLAUDE_BIN=claude   # render the helper to use the PATH stub below
  render_to_file "$REPO_ROOT/modules/local-login.sh.tpl" "$TMP_TEST_DIR/login.sh"
  chmod +x "$TMP_TEST_DIR/login.sh"
  cat > "$TMP_TEST_DIR/bin/claude" << 'SH'
#!/usr/bin/env bash
case "$*" in *--version*) echo "1.9.0 (Claude Code)" ;; esac
exit 0
SH
  chmod +x "$TMP_TEST_DIR/bin/claude"
  run "$TMP_TEST_DIR/login.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"2.1.51"* ]]
}
