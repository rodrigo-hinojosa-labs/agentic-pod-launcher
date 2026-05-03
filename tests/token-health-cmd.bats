#!/usr/bin/env bats
# Tests for docker/scripts/check_token_health.sh — end-to-end runner.
# Stubs curl + the configured notifier via PATH override and
# TH_*_OVERRIDE env vars. Exercises state file writes, transitions,
# and warning emission without hitting any real API.

load 'helper'

RUNNER="$BATS_TEST_DIRNAME/../docker/scripts/check_token_health.sh"

setup() {
  setup_tmp_dir
  WS="$TMP_TEST_DIR/workspace"
  HB="$WS/scripts/heartbeat"
  TH="$HB/token-health"
  NOTIFIERS="$HB/notifiers"
  STUB_DIR="$TMP_TEST_DIR/bin"
  mkdir -p "$WS" "$HB" "$TH" "$NOTIFIERS" "$STUB_DIR"

  # Minimal agent.yml — runner only reads notifications.channel.
  cat > "$WS/agent.yml" <<YAML
agent:
  name: testagent
notifications:
  channel: log
YAML

  # log notifier stub: append a line to a log so we can assert emission.
  cat > "$NOTIFIERS/log.sh" <<'NOTIFIER'
#!/bin/sh
echo "$1 $2 $(cat)" >> "$NOTIFY_OUT"
NOTIFIER
  chmod +x "$NOTIFIERS/log.sh"

  # telegram notifier stub (used when channel is telegram).
  cp "$NOTIFIERS/log.sh" "$NOTIFIERS/telegram.sh"

  ORIG_PATH="$PATH"
  export NOTIFY_OUT="$TMP_TEST_DIR/notify.log"

  # Default: yq is needed to read agent.yml. If the host has it, great;
  # otherwise the runner falls back to channel="none" which still allows
  # most assertions.
}

teardown() {
  PATH="$ORIG_PATH"
  unset GITHUB_PAT NOTIFY_BOT_TOKEN
  unset ATLASSIAN_WORK_TOKEN ATLASSIAN_WORK_JIRA_URL ATLASSIAN_WORK_JIRA_USERNAME
  unset ATLASSIAN_PERSONAL_TOKEN ATLASSIAN_PERSONAL_JIRA_URL ATLASSIAN_PERSONAL_JIRA_USERNAME
  teardown_tmp_dir
}

# Stub curl returning a fixed http_code. This is the same shape used in
# tests/token-health-lib.bats — keeping behavior consistent.
_stub_curl() {
  local code="$1"
  cat > "$STUB_DIR/curl" <<STUB
#!/bin/sh
printf '%s' "$code"
exit 0
STUB
  chmod +x "$STUB_DIR/curl"
  PATH="$STUB_DIR:$ORIG_PATH"
}

# Helper: invoke the runner with the canonical overrides pointing at the
# tmpdir tree. All env vars the runner cares about must already be set.
_run_runner() {
  TH_WORKSPACE_OVERRIDE="$WS" \
  TH_LIB_DIR_OVERRIDE="$BATS_TEST_DIRNAME/../docker/scripts/lib" \
  TH_NOTIFIERS_DIR_OVERRIDE="$NOTIFIERS" \
  TH_DEDUP_SECS="${TH_DEDUP_SECS:-86400}" \
  run "$RUNNER"
}

@test "runner: no tokens set → no state files written" {
  _run_runner
  [ "$status" -eq 0 ]
  [ "$(find "$TH" -name '*.json' | wc -l)" -eq 0 ]
}

@test "runner: GitHub PAT ok → state=ok, no notifier emission" {
  _stub_curl 200
  export GITHUB_PAT="ghp_xxx"
  _run_runner
  [ "$status" -eq 0 ]
  [ -f "$TH/github.json" ]
  jq -e '.status == "ok"' "$TH/github.json"
  jq -e '.consecutive_failures == 0' "$TH/github.json"
  # No notifier output for the silent transition.
  [ ! -s "$NOTIFY_OUT" ] || [ "$(wc -l < "$NOTIFY_OUT")" -eq 0 ]
}

@test "runner: GitHub PAT 401 → state=auth_fail + warn emitted" {
  _stub_curl 401
  export GITHUB_PAT="ghp_expired"
  _run_runner
  [ "$status" -eq 0 ]
  jq -e '.status == "auth_fail"' "$TH/github.json"
  jq -e '.consecutive_failures == 1' "$TH/github.json"
  jq -e '.first_failure_at != null' "$TH/github.json"
  jq -e '.last_warned_at != null' "$TH/github.json"
  # Notifier was invoked with id=token-health-github status=warn.
  grep -q "token-health-github warn" "$NOTIFY_OUT"
  grep -q "github.com/settings/tokens" "$NOTIFY_OUT"
  # warnings.jsonl has one entry.
  [ -f "$TH/warnings.jsonl" ]
  [ "$(wc -l < "$TH/warnings.jsonl")" -eq 1 ]
  jq -e '.transition == "warn"' < "$TH/warnings.jsonl"
}

@test "runner: telegram skipped when NOTIFY_CHANNEL != telegram" {
  # channel is 'log' from setup(); the bot token is set but should not
  # be probed.
  _stub_curl 200
  export NOTIFY_BOT_TOKEN="123:abc"
  _run_runner
  [ ! -f "$TH/telegram.json" ]
}

@test "runner: telegram probed when channel=telegram" {
  # Switch channel to telegram in agent.yml.
  cat > "$WS/agent.yml" <<YAML
agent:
  name: testagent
notifications:
  channel: telegram
YAML
  _stub_curl 200
  export NOTIFY_BOT_TOKEN="123:abc"
  _run_runner
  [ "$status" -eq 0 ]
  [ -f "$TH/telegram.json" ]
  jq -e '.status == "ok"' "$TH/telegram.json"
}

@test "runner: atlassian workspace discovery → one state file per workspace" {
  _stub_curl 200
  export ATLASSIAN_WORK_TOKEN="atk1"
  export ATLASSIAN_WORK_JIRA_URL="https://work.atlassian.net"
  export ATLASSIAN_WORK_JIRA_USERNAME="alice@work.com"
  export ATLASSIAN_PERSONAL_TOKEN="atk2"
  export ATLASSIAN_PERSONAL_JIRA_URL="https://me.atlassian.net"
  export ATLASSIAN_PERSONAL_JIRA_USERNAME="alice@me.com"

  _run_runner
  [ "$status" -eq 0 ]
  [ -f "$TH/atlassian-work.json" ]
  [ -f "$TH/atlassian-personal.json" ]
  jq -e '.status == "ok"' "$TH/atlassian-work.json"
  jq -e '.kind == "atlassian"' "$TH/atlassian-work.json"
}

@test "runner: fail→ok transitions emit recovery message" {
  # Seed a prior failure state.
  cat > "$TH/github.json" <<JSON
{"id":"github","kind":"github_pat","status":"auth_fail",
 "consecutive_failures":3,"first_failure_at":"2026-05-01T00:00:00Z",
 "last_warned_at":"2026-05-01T00:00:00Z","error":"HTTP 401",
 "last_check":"2026-05-01T00:00:00Z","http_code":"401","latency_ms":100}
JSON

  _stub_curl 200
  export GITHUB_PAT="ghp_renewed"
  _run_runner
  [ "$status" -eq 0 ]
  jq -e '.status == "ok"' "$TH/github.json"
  jq -e '.consecutive_failures == 0' "$TH/github.json"
  jq -e '.first_failure_at == null' "$TH/github.json"
  jq -e '.last_warned_at == null' "$TH/github.json"
  # Recovery message went to the notifier.
  grep -q "token-health-github recover" "$NOTIFY_OUT"
  grep -q "recovered" "$NOTIFY_OUT"
}

@test "runner: persistent auth_fail within dedup window → no re-warn" {
  # Pre-seed: failure that was warned 1h ago. Dedup is 24h → silent.
  local now_iso one_hour_ago
  now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  one_hour_ago=$(date -u -d "1 hour ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
                 || date -u -v-1H +"%Y-%m-%dT%H:%M:%SZ")
  cat > "$TH/github.json" <<JSON
{"id":"github","kind":"github_pat","status":"auth_fail",
 "consecutive_failures":1,"first_failure_at":"$one_hour_ago",
 "last_warned_at":"$one_hour_ago","error":"HTTP 401",
 "last_check":"$one_hour_ago","http_code":"401","latency_ms":100}
JSON

  _stub_curl 401
  export GITHUB_PAT="ghp_still_expired"
  _run_runner
  [ "$status" -eq 0 ]
  # Silent: no new notifier line.
  [ ! -s "$NOTIFY_OUT" ] || [ "$(wc -l < "$NOTIFY_OUT")" -eq 0 ]
  # Streak ticks up.
  jq -e '.consecutive_failures == 2' "$TH/github.json"
}

@test "runner: persistent auth_fail past dedup → re-warn" {
  # Pre-seed: failure warned 25h ago. With default 24h dedup, expect warn.
  local now_iso old_warn
  now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  old_warn=$(date -u -d "25 hours ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
             || date -u -v-25H +"%Y-%m-%dT%H:%M:%SZ")
  cat > "$TH/github.json" <<JSON
{"id":"github","kind":"github_pat","status":"auth_fail",
 "consecutive_failures":24,"first_failure_at":"$old_warn",
 "last_warned_at":"$old_warn","error":"HTTP 401",
 "last_check":"$old_warn","http_code":"401","latency_ms":100}
JSON

  _stub_curl 401
  export GITHUB_PAT="ghp_still_expired"
  _run_runner
  [ "$status" -eq 0 ]
  grep -q "token-health-github warn" "$NOTIFY_OUT"
  jq -e '.consecutive_failures == 25' "$TH/github.json"
}

@test "runner: notifier failure does not abort the cron tick" {
  # Make the log notifier fail.
  cat > "$NOTIFIERS/log.sh" <<'NOTIFIER'
#!/bin/sh
exit 1
NOTIFIER
  chmod +x "$NOTIFIERS/log.sh"

  _stub_curl 401
  export GITHUB_PAT="ghp_xxx"
  _run_runner
  [ "$status" -eq 0 ]
  # State file was still written despite notifier failure.
  jq -e '.status == "auth_fail"' "$TH/github.json"
}
