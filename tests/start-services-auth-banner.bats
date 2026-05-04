#!/usr/bin/env bats
# Tests for _check_auth_banner — Phase B1 of OAuth resilience.
# Source start_services.sh in test-only mode (START_SERVICES_NO_RUN=1)
# and exercise the function with synthetic claude.log fixtures.

load helper

setup() {
  setup_tmp_dir
  export START_SERVICES_NO_RUN=1
  export WORKDIR="$TMP_TEST_DIR"
  export HOME="$TMP_TEST_DIR/home"
  mkdir -p "$HOME"

  # Synthetic workspace tree
  CLAUDE_LOG="$TMP_TEST_DIR/claude.log"
  STATE_FILE="$TMP_TEST_DIR/auth-status.json"
  NOTIFIER_DIR="$TMP_TEST_DIR/notifiers"
  AGENT_YML="$TMP_TEST_DIR/agent.yml"
  mkdir -p "$NOTIFIER_DIR"

  # Stub notifier that records all invocations. NOTIFY_OUT must be
  # exported because the notifier runs as a subshell from inside the
  # _emit_auth_warning function — non-exported vars would not survive.
  export NOTIFY_OUT="$TMP_TEST_DIR/notify.log"
  cat > "$NOTIFIER_DIR/log.sh" <<'NOTIFIER'
#!/bin/sh
printf '%s %s %s\n' "$1" "$2" "$(cat)" >> "$NOTIFY_OUT"
NOTIFIER
  chmod +x "$NOTIFIER_DIR/log.sh"

  # agent.yml with channel=log so the notifier dispatch picks our stub
  cat > "$AGENT_YML" <<YAML
notifications:
  channel: log
YAML

  # shellcheck source=/dev/null
  source "$REPO_ROOT/docker/scripts/start_services.sh"

  # Reset internal throttle state (sourced as 0 already, but defensive)
  _last_auth_check=0

  # Override paths used by _check_auth_banner. The function reads
  # /workspace/claude.log, /workspace/scripts/heartbeat/auth-status.json
  # and the notifier dir + agent.yml. We can't easily redirect all of
  # those from outside, so we patch the function's references via the
  # AUTH_BANNER_LOG_OVERRIDE / AUTH_BANNER_STATE_OVERRIDE env vars.
  export AUTH_BANNER_LOG_OVERRIDE="$CLAUDE_LOG"
  export AUTH_BANNER_STATE_OVERRIDE="$STATE_FILE"
  export AUTH_BANNER_AGENT_YML_OVERRIDE="$AGENT_YML"
  export AUTH_BANNER_NOTIFIERS_OVERRIDE="$NOTIFIER_DIR"
}

teardown() {
  teardown_tmp_dir
}

# Helper: clobber the banner check throttle so the next call always runs.
_reset_throttle() { _last_auth_check=0; }

# Helper: replace the hard-coded /workspace paths with our overrides
# inside the function (we use sed on a temp copy of the function body
# during initial source; but since the function is already sourced and
# uses literal strings, we override at runtime by redefining functions).
# Since redefining is messy, we instead test with absolute paths that
# the function uses — for that we need the test to set up the structure
# at /workspace inside the bats tmpdir. The simplest way: monkey-patch
# _check_auth_banner to use our override env vars. That's what the
# AUTH_BANNER_*_OVERRIDE env vars do (already plumbed in src).

@test "_check_auth_banner: claude.log absent → no-op, no state file" {
  rm -f "$CLAUDE_LOG" "$STATE_FILE"
  _reset_throttle
  _check_auth_banner
  [ ! -f "$STATE_FILE" ]
}

@test "_check_auth_banner: claude.log without banner → no-op" {
  echo "Just a normal claude run output, all good." > "$CLAUDE_LOG"
  rm -f "$STATE_FILE" "$NOTIFY_OUT"
  _reset_throttle
  _check_auth_banner
  [ ! -f "$STATE_FILE" ]
  [ ! -s "$NOTIFY_OUT" ] || [ "$(wc -l < "$NOTIFY_OUT")" -eq 0 ]
}

@test "_check_auth_banner: 'Please run /login' detected → state=detected + warning emitted" {
  cat > "$CLAUDE_LOG" <<'EOF'
some pre-banner output
Please run /login · API Error: 401 {"type":"error","error":{"type":"authentication_error"}}
more output after
EOF
  rm -f "$STATE_FILE" "$NOTIFY_OUT"
  _reset_throttle
  _check_auth_banner
  [ -f "$STATE_FILE" ]
  jq -e '.status == "detected"' "$STATE_FILE"
  jq -e '.first_seen_at != null and .last_warned_at != null' "$STATE_FILE"
  grep -q "auth-banner-detected warn" "$NOTIFY_OUT"
  grep -q "Please run /login" "$NOTIFY_OUT"
}

@test "_check_auth_banner: re-run within 24h with banner still present → silent (no second warn)" {
  cat > "$CLAUDE_LOG" <<'EOF'
Please run /login · API Error: 401
EOF

  # First detection — emits warn.
  rm -f "$STATE_FILE" "$NOTIFY_OUT"
  _reset_throttle
  _check_auth_banner
  local first_warn_count
  first_warn_count=$(wc -l < "$NOTIFY_OUT" | tr -d ' ')
  [ "$first_warn_count" -ge 1 ]

  # Second invocation immediately after — the throttle (60s) is the
  # outer guard, but we reset it. The dedup (24h since last_warned_at)
  # should keep us silent.
  _reset_throttle
  _check_auth_banner

  local second_count
  second_count=$(wc -l < "$NOTIFY_OUT" | tr -d ' ')
  [ "$second_count" = "$first_warn_count" ]   # No new warning emitted
}

@test "_check_auth_banner: dedup expires after 24h → re-warn" {
  # Pre-seed state with last_warned_at 25h ago.
  local old_iso
  old_iso=$(date -u -d "25 hours ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || date -u -v-25H +"%Y-%m-%dT%H:%M:%SZ")
  cat > "$STATE_FILE" <<EOF
{"status":"detected","first_seen_at":"$old_iso","last_warned_at":"$old_iso"}
EOF
  cat > "$CLAUDE_LOG" <<'EOF'
Please run /login · API Error: 401
EOF
  rm -f "$NOTIFY_OUT"
  _reset_throttle
  _check_auth_banner
  grep -q "auth-banner-detected warn" "$NOTIFY_OUT"
}

@test "_check_auth_banner: banner cleared after detection → recovery emitted" {
  # Pre-seed state with status=detected.
  local now_iso
  now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  cat > "$STATE_FILE" <<EOF
{"status":"detected","first_seen_at":"$now_iso","last_warned_at":"$now_iso"}
EOF
  echo "Healthy claude output, no banner." > "$CLAUDE_LOG"
  rm -f "$NOTIFY_OUT"
  _reset_throttle
  _check_auth_banner

  jq -e '.status == "ok"' "$STATE_FILE"
  jq -e '.last_warned_at == null' "$STATE_FILE"
  grep -q "auth-banner-recovered warn" "$NOTIFY_OUT"
}

@test "_check_auth_banner: throttle prevents two scans within 60s" {
  echo "Please run /login" > "$CLAUDE_LOG"
  rm -f "$STATE_FILE" "$NOTIFY_OUT"
  _reset_throttle
  _check_auth_banner
  # _last_auth_check was set to current time; second call should bail at the throttle.
  _check_auth_banner
  # State file written once; notifier called once.
  [ "$(wc -l < "$NOTIFY_OUT" | tr -d ' ')" -le 1 ]
}
