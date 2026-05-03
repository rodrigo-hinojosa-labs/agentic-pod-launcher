#!/usr/bin/env bats
# Tests for token-health integration in heartbeatctl:
#   - reload writes the hourly cron line for check_token_health.sh
#   - features.token_health.enabled=false drops the line
#   - status enriches output with token-health rows when state files exist
#   - token-check dispatches to the runner

load helper

setup() {
  setup_tmp_dir
  export WORKSPACE="$TMP_TEST_DIR"
  mkdir -p "$WORKSPACE/scripts/heartbeat/logs" \
           "$WORKSPACE/scripts/heartbeat/notifiers" \
           "$WORKSPACE/scripts/heartbeat/token-health"

  cat > "$WORKSPACE/agent.yml" <<YML
agent:
  name: testbot
features:
  heartbeat:
    enabled: true
    interval: "2m"
    timeout: 300
    retries: 1
    default_prompt: "Check"
notifications:
  channel: log
YML

  cat > "$WORKSPACE/scripts/heartbeat/heartbeat.conf" <<CONF
HEARTBEAT_ENABLED="true"
HEARTBEAT_INTERVAL="2m"
HEARTBEAT_CRON="*/2 * * * *"
HEARTBEAT_TIMEOUT="300"
HEARTBEAT_RETRIES="1"
HEARTBEAT_PROMPT="Check"
NOTIFY_CHANNEL="log"
NOTIFY_SUCCESS_EVERY="1"
CONF

  export HEARTBEATCTL_WORKSPACE="$WORKSPACE"
  export HEARTBEATCTL_CRONTAB_FILE="$TMP_TEST_DIR/crontab-agent"
  export HEARTBEATCTL_LIB_DIR="$REPO_ROOT/docker/scripts/lib"
}

teardown() { teardown_tmp_dir; }

@test "reload: token-health cron line is written by default (hourly)" {
  run bash "$REPO_ROOT/docker/scripts/heartbeatctl" reload
  [ "$status" -eq 0 ]
  grep -q '^0 \* \* \* \* /opt/agent-admin/scripts/check_token_health.sh' \
    "$HEARTBEATCTL_CRONTAB_FILE"
}

@test "reload: features.token_health.enabled=false drops the cron line" {
  yq -i '.features.token_health.enabled = false' "$WORKSPACE/agent.yml"
  run bash "$REPO_ROOT/docker/scripts/heartbeatctl" reload
  [ "$status" -eq 0 ]
  ! grep -q 'check_token_health.sh' "$HEARTBEATCTL_CRONTAB_FILE"
}

@test "reload: features.token_health.schedule overrides cadence" {
  yq -i '.features.token_health.schedule = "*/15 * * * *"' "$WORKSPACE/agent.yml"
  run bash "$REPO_ROOT/docker/scripts/heartbeatctl" reload
  [ "$status" -eq 0 ]
  grep -q '^\*/15 \* \* \* \* /opt/agent-admin/scripts/check_token_health.sh' \
    "$HEARTBEATCTL_CRONTAB_FILE"
}

@test "status: emits token-health section when state files exist" {
  # Minimum state.json so cmd_status doesn't bail on missing schema.
  cat > "$WORKSPACE/scripts/heartbeat/state.json" <<'JS'
{
  "schema": 1,
  "enabled": true,
  "interval": "2m",
  "cron": "*/2 * * * *",
  "prompt": "Check",
  "notifier_channel": "log",
  "last_run": {"status":"ok","ts":"2026-05-02T22:00:00Z","duration_ms":100,"attempt":1},
  "counters": {"total_runs":1,"ok":1,"timeout":0,"error":0,"consecutive_failures":0},
  "updated_at": "2026-05-02T22:00:00Z"
}
JS
  cat > "$WORKSPACE/scripts/heartbeat/token-health/github.json" <<'JS'
{"id":"github","kind":"github_pat","status":"ok",
 "last_check":"2026-05-02T22:00:00Z","http_code":"200","latency_ms":142,
 "consecutive_failures":0,"first_failure_at":null,
 "last_warned_at":null,"error":null}
JS

  run bash "$REPO_ROOT/docker/scripts/heartbeatctl" status
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "token health:"
  echo "$output" | grep -qE "github +ok"
}

@test "token-check: dispatches to the configured runner" {
  # Stub runner so we don't need a live container.
  cat > "$TMP_TEST_DIR/fake-runner.sh" <<'RUN'
#!/bin/sh
echo "fake-runner ran"
RUN
  chmod +x "$TMP_TEST_DIR/fake-runner.sh"

  HEARTBEATCTL_TOKEN_RUNNER="$TMP_TEST_DIR/fake-runner.sh" \
    run bash "$REPO_ROOT/docker/scripts/heartbeatctl" token-check
  [ "$status" -eq 0 ]
  [[ "$output" == *"fake-runner ran"* ]]
}

@test "token-check: fails loud when runner missing" {
  HEARTBEATCTL_TOKEN_RUNNER="/nonexistent/path" \
    run bash "$REPO_ROOT/docker/scripts/heartbeatctl" token-check
  [ "$status" -eq 2 ]
  [[ "$output" == *"runner not found"* ]]
}
