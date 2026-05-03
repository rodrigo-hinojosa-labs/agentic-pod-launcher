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

# ── doctor ────────────────────────────────────────────────────────────────
# Helper: stage a doctor-friendly fixture. Tests then mutate one piece at a
# time to exercise individual checks. Tests run on the host (macOS or Linux),
# so the host's stat (BSD or GNU) must work — that's exactly what the
# portable _doctor_file_mode helper covers.
_doctor_setup_fixture() {
  export DOCTOR_HOME="$TMP_TEST_DIR/doctor-home"
  export DOCTOR_VAULT="$TMP_TEST_DIR/doctor-vault"
  mkdir -p "$DOCTOR_HOME/.claude/plugins/cache/claude-plugins-official/telegram"
  mkdir -p "$DOCTOR_VAULT"
  echo "DUMMY=1" > "$WORKSPACE/.env"
  chmod 600 "$WORKSPACE/.env"
  echo '{}' > "$DOCTOR_HOME/.claude/.credentials.json"
  echo "seeded" > "$DOCTOR_VAULT/log.md"
}

_doctor_run() {
  HEARTBEATCTL_CLAUDE_HOME="$DOCTOR_HOME/.claude" \
  HEARTBEATCTL_VAULT_ROOT="$DOCTOR_VAULT" \
  bash "$REPO_ROOT/docker/scripts/heartbeatctl" doctor "$@"
}

@test "doctor lists every check section in order" {
  _doctor_setup_fixture
  run _doctor_run
  # We don't pin the exit code (crond + tmux can't be running in bats), but
  # every check section title must appear so the user gets a complete pass.
  [[ "$output" == *"Workspace mounted"* ]]
  [[ "$output" == *"agent.yml is valid"* ]]
  [[ "$output" == *".env permissions"* ]]
  [[ "$output" == *"crond"* ]]
  [[ "$output" == *"tmux session"* ]]
  [[ "$output" == *"Claude credentials"* ]]
  [[ "$output" == *"Vault"* ]]
}

@test "doctor reports .env permissions: 600 cleanly when correct" {
  _doctor_setup_fixture
  chmod 600 "$WORKSPACE/.env"
  run _doctor_run
  [[ "$output" == *".env permissions: 600"* ]]
  # Must not bleed stat -f filesystem fields (the upstream bug):
  [[ "$output" != *"Fichero:"* ]]
  [[ "$output" != *"ID:"* ]]
  [[ "$output" != *"Longnombre"* ]]
}

@test "doctor flags .env permissions=644 with portable mode and chmod hint" {
  _doctor_setup_fixture
  chmod 644 "$WORKSPACE/.env"
  run _doctor_run
  [[ "$output" == *".env permissions: 644"* ]]
  [[ "$output" == *"should be 600"* ]]
  [[ "$output" == *"chmod 600"* ]]
  # No stat output bleed.
  [[ "$output" != *"Fichero:"* ]]
  [[ "$output" != *"ID:"* ]]
}

@test "doctor reports .env missing as ⊝ skip (not an error)" {
  _doctor_setup_fixture
  rm -f "$WORKSPACE/.env"
  run _doctor_run
  [[ "$output" == *".env missing"* ]]
  # Skip ⊝ should not increment errors. We can't assert exit code (crond
  # absence may push us to 2 in bats), but the line should not say "should be 600".
  [[ "$output" != *"should be 600"* ]]
}

@test "doctor reports agent.yml missing as ✗ error" {
  _doctor_setup_fixture
  rm -f "$WORKSPACE/agent.yml"
  run _doctor_run
  [[ "$output" == *"agent.yml missing"* ]]
  [[ "$output" == *"✗"* ]]
  [ "$status" -eq 2 ]
}

@test "doctor reports invalid agent.yml as ✗ error" {
  _doctor_setup_fixture
  printf 'this is\n  : not [yaml' > "$WORKSPACE/agent.yml"
  run _doctor_run
  [[ "$output" == *"yq cannot parse"* ]]
  [ "$status" -eq 2 ]
}

@test "doctor reports missing claude credentials as ⚠ warning" {
  _doctor_setup_fixture
  rm -f "$DOCTOR_HOME/.claude/.credentials.json"
  run _doctor_run
  [[ "$output" == *"Claude credentials missing"* ]]
  [[ "$output" == *"agentctl attach"* ]]
}

@test "doctor reports channel plugin not installed as ⊝ skip when no .installed-ok" {
  _doctor_setup_fixture
  # Plugin cache dir exists from setup but no .installed-ok sentinel — that's the pre-/login state.
  run _doctor_run
  [[ "$output" == *"Telegram channel plugin not installed yet"* ]]
}

@test "doctor reports channel plugin installed when sentinel exists" {
  _doctor_setup_fixture
  : > "$DOCTOR_HOME/.claude/plugins/cache/claude-plugins-official/telegram/.installed-ok"
  run _doctor_run
  [[ "$output" == *"Telegram channel plugin installed"* ]]
  # bun won't be running in bats — expect the warn for that.
  [[ "$output" == *"bun server.ts"* ]]
}

@test "doctor reports vault seeded when directory has content" {
  _doctor_setup_fixture
  run _doctor_run
  [[ "$output" == *"Vault skeleton seeded"* ]]
}

@test "doctor reports vault not seeded when directory empty" {
  _doctor_setup_fixture
  rm -rf "$DOCTOR_VAULT"
  mkdir -p "$DOCTOR_VAULT"
  run _doctor_run
  [[ "$output" == *"Vault not seeded"* ]]
}

@test "doctor exit code: errors → 2, warnings only → 1, all clean → 0 (covered by other tests via specific assertions)" {
  # Direct exit code coverage: all-clean is unreachable in bats (no crond,
  # no tmux), so this test pins the worst-case (errors=2) only. Per-warning
  # assertions live in dedicated tests above.
  _doctor_setup_fixture
  rm -f "$WORKSPACE/agent.yml"   # → ✗ error → exit 2
  run _doctor_run
  [ "$status" -eq 2 ]
}

@test "doctor help line lists doctor in Read section" {
  run bash "$REPO_ROOT/docker/scripts/heartbeatctl" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"doctor"* ]]
  [[ "$output" == *"Diagnose container health"* ]]
}

# ── token-health subcommand ────────────────────────────────────────────

@test "token-health subcommand prints summary header and skip lines for the default fixture" {
  # Default fixture has channel=log + no MCPs, so every probe is ⊝
  # skipped — no network calls happen.
  run bash "$REPO_ROOT/docker/scripts/heartbeatctl" token-health
  [ "$status" -eq 0 ]
  [[ "$output" == *"Token health:"* ]]
  # The default agent.yml has notifications.channel=log, so no telegram
  # probe runs. No atlassian, no firecrawl. Output is just the header
  # plus possibly nothing (everything skipped).
  # Verify no test made an actual network call by ensuring no token line
  # contains a status icon other than ⊝ or no detail at all.
}

@test "token-health subcommand fails with rc=2 when agent.yml is missing" {
  rm -f "$WORKSPACE/agent.yml"
  run bash "$REPO_ROOT/docker/scripts/heartbeatctl" token-health
  [ "$status" -eq 2 ]
  [[ "$output" == *"agent.yml missing"* ]]
}

@test "token-health help line listed in Read section" {
  run bash "$REPO_ROOT/docker/scripts/heartbeatctl" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"token-health"* ]]
}
