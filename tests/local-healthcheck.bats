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

  # Stubs: systemctl is-active honors $STUB_ACTIVE and reports MainPID via
  # $STUB_MAINPID; journalctl echoes $STUB_JOURNAL (used only for the 401 check
  # now); ss echoes $STUB_SS. The connection signal comes from a live
  # ESTABLISHED :443 socket owned by the session PID, NOT the journal — a healthy
  # --spawn=session is silent, so the old journal grep false-WARNed every tick.
  mkdir -p "$TMP_TEST_DIR/bin"
  cat > "$TMP_TEST_DIR/bin/systemctl" << 'SH'
#!/usr/bin/env bash
case "$*" in
  *is-active*)          exit "${STUB_ACTIVE:-0}" ;;
  *show*MainPID*)       echo "${STUB_MAINPID:-1234}" ;;
  # is-failed --quiet: NOT failed (1) by default; a test sets STUB_WATCH_FAILED=1.
  *is-failed*qmd-watch*)  [ "${STUB_WATCH_FAILED:-0}" = 1 ] && exit 0 || exit 1 ;;
  *is-failed*wiki-graph*) [ "${STUB_WG_FAILED:-0}" = 1 ] && exit 0 || exit 1 ;;
  *is-failed*)          exit 1 ;;
  *)                    exit 0 ;;
esac
SH
  cat > "$TMP_TEST_DIR/bin/journalctl" << 'SH'
#!/usr/bin/env bash
printf '%s\n' "${STUB_JOURNAL:-}"
exit 0
SH
  cat > "$TMP_TEST_DIR/bin/ss" << 'SH'
#!/usr/bin/env bash
printf '%s\n' "${STUB_SS:-}"
exit 0
SH
  chmod +x "$TMP_TEST_DIR/bin/"*
  export PATH="$TMP_TEST_DIR/bin:$PATH"

  # Default: a live relay socket owned by the default MainPID. Most tests are
  # "connected" and exercise OTHER dimensions; connection-specific tests override
  # STUB_SS / STUB_MAINPID inline.
  export STUB_MAINPID=1234
  export STUB_SS='ESTAB 0 0 10.0.0.2:55000 1.2.3.4:443 users:(("claude",pid=1234,fd=5))'

  CREDS_DIR="$TMP_TEST_DIR/.state/.claude"
  mkdir -p "$CREDS_DIR"
}

teardown() { teardown_tmp_dir; }

_write_creds() {  # _write_creds <expiresAt-ms>
  printf '{"claudeAiOauth":{"expiresAt":%s}}\n' "$1" > "$CREDS_DIR/.credentials.json"
}

@test "healthcheck OK: active + live relay socket + valid login → exit 0 (silent journal)" {
  # THE regression this fix encodes: the journal is EMPTY (a healthy
  # --spawn=session emits no 'session url/connected/polling'), yet the live
  # ESTABLISHED :443 socket proves the session is controllable → OK, not WARN.
  _write_creds 99999999999999
  STUB_ACTIVE=0 STUB_JOURNAL="" run "$TMP_TEST_DIR/hc.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "healthcheck WARN: active + valid login but NO live relay socket → exit 1" {
  _write_creds 99999999999999
  STUB_ACTIVE=0 STUB_SS="" run "$TMP_TEST_DIR/hc.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"WARN"* ]]
  [[ "$output" == *"no live relay connection"* ]]
}

@test "healthcheck WARN: a :443 socket exists but not owned by the session PID → exit 1" {
  _write_creds 99999999999999
  STUB_ACTIVE=0 STUB_SS='ESTAB 0 0 10.0.0.2:40000 5.6.7.8:443 users:(("other",pid=9999,fd=7))' \
    run "$TMP_TEST_DIR/hc.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no live relay connection"* ]]
}

@test "healthcheck graceful: MainPID unknown → WARN cannot verify, no crash" {
  _write_creds 99999999999999
  STUB_ACTIVE=0 STUB_MAINPID=0 run "$TMP_TEST_DIR/hc.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot verify connection"* ]]
}

@test "healthcheck WARN: a failed qmd-watch unit → WARN, never DEGRADED (013 FR-011/T023)" {
  # active + connected + valid login, but the watcher unit is failed. The timer
  # still backstops freshness, so this is a WARN (exit 1), not DEGRADED (exit 2).
  _write_creds 99999999999999
  STUB_ACTIVE=0 STUB_WATCH_FAILED=1 run "$TMP_TEST_DIR/hc.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"WARN"* ]]
  [[ "$output" == *"watcher failed"* ]]
  ! [[ "$output" == *"DEGRADED"* ]]
}

@test "healthcheck: a healthy (non-failed) watcher adds no warning (013 FR-011)" {
  # default STUB_WATCH_FAILED unset → is-failed returns 1 → no qmd warning.
  _write_creds 99999999999999
  STUB_ACTIVE=0 run "$TMP_TEST_DIR/hc.sh"
  [ "$status" -eq 0 ]
  ! [[ "$output" == *"watcher failed"* ]]
}

@test "healthcheck WARN: a failed wiki-graph unit → WARN, never DEGRADED (014/T022)" {
  _write_creds 99999999999999
  STUB_ACTIVE=0 STUB_WG_FAILED=1 run "$TMP_TEST_DIR/hc.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"WARN"* ]]
  [[ "$output" == *"wiki-graph runner failed"* ]]
  ! [[ "$output" == *"DEGRADED"* ]]
}

@test "healthcheck: a healthy (non-failed) wiki-graph unit adds no warning (014)" {
  _write_creds 99999999999999
  STUB_ACTIVE=0 run "$TMP_TEST_DIR/hc.sh"
  [ "$status" -eq 0 ]
  ! [[ "$output" == *"wiki-graph runner failed"* ]]
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
