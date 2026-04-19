#!/usr/bin/env bats

load helper

setup() {
  setup_tmp_dir
  export WORKSPACE="$TMP_TEST_DIR"
  mkdir -p "$WORKSPACE/scripts/heartbeat/logs" "$WORKSPACE/scripts/heartbeat/notifiers"
  # minimal agent.yml
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
  # minimal heartbeat.conf
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
  # baseline crontab
  printf '*/30 * * * * /workspace/scripts/heartbeat/heartbeat.sh >> /workspace/scripts/heartbeat/logs/cron.log 2>&1\n' > "$HEARTBEATCTL_CRONTAB_FILE"
}
teardown() { teardown_tmp_dir; }

@test "help prints all command groups" {
  run bash "$REPO_ROOT/docker/scripts/heartbeatctl" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"status"* ]]
  [[ "$output" == *"reload"* ]]
  [[ "$output" == *"set-interval"* ]]
}

@test "no args prints help" {
  run bash "$REPO_ROOT/docker/scripts/heartbeatctl"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status"* ]]
}

@test "show dumps conf and crontab and agent.yml heartbeat section" {
  run bash "$REPO_ROOT/docker/scripts/heartbeatctl" show
  [ "$status" -eq 0 ]
  [[ "$output" == *"HEARTBEAT_INTERVAL"* ]]
  [[ "$output" == *"*/30"* ]]           # from the crontab
  [[ "$output" == *"interval: \"2m\""* ]] # from agent.yml
}

@test "reload rewrites heartbeat.conf with HEARTBEAT_CRON derived from interval" {
  run bash "$REPO_ROOT/docker/scripts/heartbeatctl" reload
  [ "$status" -eq 0 ]
  grep -q 'HEARTBEAT_CRON="\*/2 \* \* \* \*"' "$WORKSPACE/scripts/heartbeat/heartbeat.conf"
  grep -q 'HEARTBEAT_INTERVAL="2m"' "$WORKSPACE/scripts/heartbeat/heartbeat.conf"
}

@test "reload rewrites crontab with new schedule and no user field" {
  run bash "$REPO_ROOT/docker/scripts/heartbeatctl" reload
  [ "$status" -eq 0 ]
  grep -q '^\*/2 \* \* \* \* /workspace/scripts/heartbeat/heartbeat.sh' "$HEARTBEATCTL_CRONTAB_FILE"
  # must not contain "agent" as argv[0]
  ! grep -qE '^[^#]*\* agent ' "$HEARTBEATCTL_CRONTAB_FILE"
}

@test "reload creates logs/ dir if missing" {
  rm -rf "$WORKSPACE/scripts/heartbeat/logs"
  run bash "$REPO_ROOT/docker/scripts/heartbeatctl" reload
  [ -d "$WORKSPACE/scripts/heartbeat/logs" ]
}

@test "reload fails cleanly when interval is invalid in agent.yml" {
  yq -i '.features.heartbeat.interval = "45m"' "$WORKSPACE/agent.yml"
  run bash "$REPO_ROOT/docker/scripts/heartbeatctl" reload
  [ "$status" -ne 0 ]
  [[ "$output" == *"interval"* || "$output" == *"accepted"* ]]
}

@test "reload comments crontab when enabled=false in agent.yml" {
  yq -i '.features.heartbeat.enabled = false' "$WORKSPACE/agent.yml"
  run bash "$REPO_ROOT/docker/scripts/heartbeatctl" reload
  [ "$status" -eq 0 ]
  grep -q '^# paused:' "$HEARTBEATCTL_CRONTAB_FILE"
  ! grep -qE '^\*/2' "$HEARTBEATCTL_CRONTAB_FILE"
}

@test "status --json emits state.json verbatim, enriched with crond" {
  cat > "$WORKSPACE/scripts/heartbeat/state.json" <<'JS'
{"schema":1,"enabled":true,"interval":"2m","cron":"*/2 * * * *","prompt":"Check","notifier_channel":"log","last_run":{"ts":"2026-04-19T01:30:00Z","run_id":"x","status":"ok","duration_ms":1000},"counters":{"total_runs":5,"ok":5,"timeout":0,"error":0,"consecutive_failures":0,"success_rate_24h":1},"next_run_estimate":null,"crond":{"alive":null,"pid":null},"updated_at":"2026-04-19T01:30:00Z"}
JS
  run bash "$REPO_ROOT/docker/scripts/heartbeatctl" status --json
  [ "$status" -eq 0 ]
  json="$output"
  run jq -r '.interval' <<<"$json"
  [ "$output" = "2m" ]
  # crond.alive must be a boolean, not null
  run jq -r '.crond.alive | type' <<<"$json"
  [ "$output" = "boolean" ]
}

@test "status (pretty) contains key fields" {
  cat > "$WORKSPACE/scripts/heartbeat/state.json" <<'JS'
{"schema":1,"enabled":true,"interval":"2m","cron":"*/2 * * * *","prompt":"Check","notifier_channel":"log","last_run":{"ts":"2026-04-19T01:30:00Z","run_id":"x","status":"ok","duration_ms":1000,"attempt":1,"prompt":"Check"},"counters":{"total_runs":5,"ok":5,"timeout":0,"error":0,"consecutive_failures":0,"success_rate_24h":1},"next_run_estimate":null,"crond":{"alive":null,"pid":null},"updated_at":"2026-04-19T01:30:00Z"}
JS
  run bash "$REPO_ROOT/docker/scripts/heartbeatctl" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"2m"* ]]
  [[ "$output" == *"*/2"* ]]
  [[ "$output" == *"5"* ]]
  [[ "$output" == *"ok"* ]]
}

@test "status prints schema error on unknown schema" {
  echo '{"schema":99}' > "$WORKSPACE/scripts/heartbeat/state.json"
  run bash "$REPO_ROOT/docker/scripts/heartbeatctl" status
  [ "$status" -ne 0 ]
  [[ "$output" == *"schema"* ]]
}

@test "logs default 20 emits tail of runs.jsonl as table" {
  for i in $(seq 1 30); do
    printf '{"ts":"2026-04-19T01:%02d:00Z","run_id":"r-%02d","status":"ok","duration_ms":100,"attempt":1,"trigger":"cron","prompt":"p%02d"}\n' "$((i%60))" "$i" "$i"
  done > "$WORKSPACE/scripts/heartbeat/logs/runs.jsonl"
  run bash "$REPO_ROOT/docker/scripts/heartbeatctl" logs
  [ "$status" -eq 0 ]
  [[ "$output" == *"r-30"* ]]
  [[ "$output" != *"r-01"* ]]
}

@test "logs --json emits raw lines" {
  printf '{"ts":"t","status":"ok"}\n' > "$WORKSPACE/scripts/heartbeat/logs/runs.jsonl"
  run bash "$REPO_ROOT/docker/scripts/heartbeatctl" logs --json
  [ "$status" -eq 0 ]
  run jq -r '.status' <<<"$output"
  [ "$output" = "ok" ]
}
