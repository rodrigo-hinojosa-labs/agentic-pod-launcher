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
