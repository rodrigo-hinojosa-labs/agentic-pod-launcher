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

@test "reload writes crontab atomically (no .tmp lingers after success)" {
  run bash "$REPO_ROOT/docker/scripts/heartbeatctl" reload
  [ "$status" -eq 0 ]
  [ -f "$HEARTBEATCTL_CRONTAB_FILE" ]
  [ ! -f "${HEARTBEATCTL_CRONTAB_FILE}.tmp" ]
  # Same atomicity for heartbeat.conf — write_state_json-style mv.
  [ ! -f "$WORKSPACE/scripts/heartbeat/heartbeat.conf.tmp" ]
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

@test "pause comments crontab line and sets enabled=false in agent.yml" {
  bash "$REPO_ROOT/docker/scripts/heartbeatctl" reload
  run bash "$REPO_ROOT/docker/scripts/heartbeatctl" pause
  [ "$status" -eq 0 ]
  grep -q '^# paused:' "$HEARTBEATCTL_CRONTAB_FILE"
  run yq -r '.features.heartbeat.enabled' "$WORKSPACE/agent.yml"
  [ "$output" = "false" ]
}

@test "resume reverses pause — crontab uncommented, enabled=true" {
  bash "$REPO_ROOT/docker/scripts/heartbeatctl" reload
  bash "$REPO_ROOT/docker/scripts/heartbeatctl" pause
  run bash "$REPO_ROOT/docker/scripts/heartbeatctl" resume
  [ "$status" -eq 0 ]
  grep -q '^\*/2 \* \* \* \*' "$HEARTBEATCTL_CRONTAB_FILE"
  ! grep -q '^# paused:' "$HEARTBEATCTL_CRONTAB_FILE"
  run yq -r '.features.heartbeat.enabled' "$WORKSPACE/agent.yml"
  [ "$output" = "true" ]
}

@test "pause is idempotent" {
  bash "$REPO_ROOT/docker/scripts/heartbeatctl" reload
  bash "$REPO_ROOT/docker/scripts/heartbeatctl" pause
  run bash "$REPO_ROOT/docker/scripts/heartbeatctl" pause
  [ "$status" -eq 0 ]
  local n
  n=$(grep -c '^# paused:' "$HEARTBEATCTL_CRONTAB_FILE")
  [ "$n" = "1" ]
}

@test "test runs heartbeat.sh with trigger=manual and writes a run line" {
  mkdir -p "$TMP_TEST_DIR/bin"
  printf '#!/bin/bash\nexit 0\n' > "$TMP_TEST_DIR/bin/claude"
  chmod +x "$TMP_TEST_DIR/bin/claude"
  cp "$REPO_ROOT/scripts/heartbeat/heartbeat.sh" "$WORKSPACE/scripts/heartbeat/"
  cp -R "$REPO_ROOT/scripts/heartbeat/notifiers" "$WORKSPACE/scripts/heartbeat/"
  export PATH="$TMP_TEST_DIR/bin:$PATH"
  export HEARTBEAT_STATE_LIB="$REPO_ROOT/docker/scripts/lib/state.sh"
  run bash "$REPO_ROOT/docker/scripts/heartbeatctl" test
  [ "$status" -eq 0 ]
  [ -f "$WORKSPACE/scripts/heartbeat/logs/runs.jsonl" ]
  run jq -r '.trigger' "$WORKSPACE/scripts/heartbeat/logs/runs.jsonl"
  [ "$output" = "manual" ]
}

@test "set-interval 15m updates agent.yml and heartbeat.conf" {
  run bash "$REPO_ROOT/docker/scripts/heartbeatctl" set-interval 15m
  [ "$status" -eq 0 ]
  run yq -r '.features.heartbeat.interval' "$WORKSPACE/agent.yml"
  [ "$output" = "15m" ]
  grep -q 'HEARTBEAT_CRON="\*/15 \* \* \* \*"' "$WORKSPACE/scripts/heartbeat/heartbeat.conf"
}

@test "set-interval 45m rejected — agent.yml untouched" {
  local before
  before=$(yq -r '.features.heartbeat.interval' "$WORKSPACE/agent.yml")
  run bash "$REPO_ROOT/docker/scripts/heartbeatctl" set-interval 45m
  [ "$status" -ne 0 ]
  run yq -r '.features.heartbeat.interval' "$WORKSPACE/agent.yml"
  [ "$output" = "$before" ]
  [ ! -f "$WORKSPACE/agent.yml.prev" ]
}

@test "set-prompt updates the prompt and conf" {
  run bash "$REPO_ROOT/docker/scripts/heartbeatctl" set-prompt "Report CPU load"
  [ "$status" -eq 0 ]
  run yq -r '.features.heartbeat.default_prompt' "$WORKSPACE/agent.yml"
  [ "$output" = "Report CPU load" ]
  grep -q 'HEARTBEAT_PROMPT="Report CPU load"' "$WORKSPACE/scripts/heartbeat/heartbeat.conf"
}

@test "set-notifier log updates channel" {
  run bash "$REPO_ROOT/docker/scripts/heartbeatctl" set-notifier log
  [ "$status" -eq 0 ]
  run yq -r '.notifications.channel' "$WORKSPACE/agent.yml"
  [ "$output" = "log" ]
  grep -q 'NOTIFY_CHANNEL="log"' "$WORKSPACE/scripts/heartbeat/heartbeat.conf"
}

@test "set-notifier bogus rejected" {
  run bash "$REPO_ROOT/docker/scripts/heartbeatctl" set-notifier carrier-pigeon
  [ "$status" -ne 0 ]
}

@test "set-timeout validates integer range" {
  run bash "$REPO_ROOT/docker/scripts/heartbeatctl" set-timeout 5
  [ "$status" -ne 0 ]
  run bash "$REPO_ROOT/docker/scripts/heartbeatctl" set-timeout 120
  [ "$status" -eq 0 ]
  run yq -r '.features.heartbeat.timeout' "$WORKSPACE/agent.yml"
  [ "$output" = "120" ]
}

@test "set-retries validates 0..5" {
  run bash "$REPO_ROOT/docker/scripts/heartbeatctl" set-retries 2
  [ "$status" -eq 0 ]
  run bash "$REPO_ROOT/docker/scripts/heartbeatctl" set-retries 10
  [ "$status" -ne 0 ]
  run bash "$REPO_ROOT/docker/scripts/heartbeatctl" set-retries -1
  [ "$status" -ne 0 ]
}

@test "drop-plugin without spec arg fails with exit 1" {
  run bash "$REPO_ROOT/docker/scripts/heartbeatctl" drop-plugin
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing <spec>"* ]]
}

@test "drop-plugin removes a present spec from agent.yml.plugins[]" {
  yq -i '.plugins = ["telegram@claude-plugins-official", "caveman@JuliusBrussee", "claude-mem@thedotmack"]' "$WORKSPACE/agent.yml"
  run bash "$REPO_ROOT/docker/scripts/heartbeatctl" drop-plugin caveman@JuliusBrussee
  [ "$status" -eq 0 ]
  run yq -r '.plugins | length' "$WORKSPACE/agent.yml"
  [ "$output" = "2" ]
  ! yq -r '.plugins[]' "$WORKSPACE/agent.yml" | grep -q "caveman"
  yq -r '.plugins[]' "$WORKSPACE/agent.yml" | grep -q "telegram@claude-plugins-official"
  yq -r '.plugins[]' "$WORKSPACE/agent.yml" | grep -q "claude-mem@thedotmack"
}

@test "drop-plugin is idempotent — no-op when spec absent" {
  yq -i '.plugins = ["telegram@claude-plugins-official"]' "$WORKSPACE/agent.yml"
  run bash "$REPO_ROOT/docker/scripts/heartbeatctl" drop-plugin caveman@JuliusBrussee
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to drop"* ]]
  run yq -r '.plugins | length' "$WORKSPACE/agent.yml"
  [ "$output" = "1" ]
}

@test "drop-plugin help lists drop-plugin in Control section" {
  run bash "$REPO_ROOT/docker/scripts/heartbeatctl" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"drop-plugin"* ]]
}
