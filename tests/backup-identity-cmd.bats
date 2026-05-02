#!/usr/bin/env bats
load 'helper'

setup() {
  # Isolated workspace
  export HEARTBEATCTL_WORKSPACE="$BATS_TEST_TMPDIR/ws"
  export HEARTBEATCTL_LIB_DIR="$BATS_TEST_DIRNAME/../docker/scripts/lib"
  export HEARTBEATCTL_CRONTAB_FILE="$BATS_TEST_TMPDIR/crontab"
  mkdir -p "$HEARTBEATCTL_WORKSPACE/scripts/heartbeat"

  cat > "$HEARTBEATCTL_WORKSPACE/agent.yml" <<YAML
agent:
  name: testagent
scaffold:
  fork:
    url: ""
backup:
  identity:
    recipient: null
features:
  identity_backup:
    enabled: true
YAML

  export IDENTITY_STATE_DIR="$HEARTBEATCTL_WORKSPACE/.state"
  mkdir -p "$IDENTITY_STATE_DIR"

  HEARTBEATCTL="$BATS_TEST_DIRNAME/../docker/scripts/heartbeatctl"
}

@test "backup-identity exits 0 silently when state is empty (no identity files)" {
  run bash "$HEARTBEATCTL" backup-identity
  [ "$status" -eq 0 ]
  [[ "$output" == *"no identity"* ]] || [ -z "$output" ]
}

@test "backup-identity --help lists the subcommand flags" {
  run bash "$HEARTBEATCTL" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"backup-identity"* ]]
}

@test "status includes identity backup summary when state file exists" {
  mkdir -p "$HEARTBEATCTL_WORKSPACE/scripts/heartbeat"
  cat > "$HEARTBEATCTL_WORKSPACE/scripts/heartbeat/identity-backup.json" <<EOF
{"hash":"deadbeef","mode":"full","last_commit":"abc1234","last_push":"2026-04-22T01:00:00Z"}
EOF
  cat > "$HEARTBEATCTL_WORKSPACE/scripts/heartbeat/state.json" <<EOF
{"schema":1,"enabled":true,"interval":"30m","cron":"*/30 * * * *","prompt":"x","notifier_channel":"none","last_run":{"status":"ok","ts":"2026-04-22T01:00:00Z","duration_ms":100,"attempt":1},"counters":{"total_runs":1,"ok":1,"timeout":0,"error":0,"consecutive_failures":0},"updated_at":"2026-04-22T01:00:00Z"}
EOF

  run bash "$HEARTBEATCTL" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"identity backup"* ]]
  [[ "$output" == *"full"* ]]
  [[ "$output" == *"abc1234"* ]]
}

@test "status warns when identity backup is in partial mode" {
  mkdir -p "$HEARTBEATCTL_WORKSPACE/scripts/heartbeat"
  cat > "$HEARTBEATCTL_WORKSPACE/scripts/heartbeat/identity-backup.json" <<EOF
{"hash":"xyz","mode":"partial","last_commit":"","last_push":""}
EOF
  cat > "$HEARTBEATCTL_WORKSPACE/scripts/heartbeat/state.json" <<EOF
{"schema":1,"enabled":true,"interval":"30m","cron":"*/30 * * * *","prompt":"x","notifier_channel":"none","last_run":{"status":"ok","ts":"2026-04-22T01:00:00Z","duration_ms":100,"attempt":1},"counters":{"total_runs":1,"ok":1,"timeout":0,"error":0,"consecutive_failures":0},"updated_at":"2026-04-22T01:00:00Z"}
EOF

  run bash "$HEARTBEATCTL" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"partial"* ]]
  [[ "$output" == *"--configure-key"* ]]
}

@test "--configure-key accepts a pubkey string and updates agent.yml" {
  local pubkey="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample key"
  run bash "$HEARTBEATCTL" backup-identity --configure-key "$pubkey"
  [ "$status" -eq 0 ]

  run yq '.backup.identity.recipient' "$HEARTBEATCTL_WORKSPACE/agent.yml"
  [[ "$output" == "ssh-ed25519"* ]]
}

@test "--configure-key accepts a path to a pubkey file" {
  local keyfile="$BATS_TEST_TMPDIR/id.pub"
  echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample file-key" > "$keyfile"
  run bash "$HEARTBEATCTL" backup-identity --configure-key "$keyfile"
  [ "$status" -eq 0 ]

  run yq '.backup.identity.recipient' "$HEARTBEATCTL_WORKSPACE/agent.yml"
  [[ "$output" == "ssh-ed25519"* ]]
  [[ "$output" == *"file-key"* ]]
}

@test "--configure-key rejects invalid key strings" {
  run bash "$HEARTBEATCTL" backup-identity --configure-key "not a key"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid"* ]]
}

@test "--disable sets features.identity_backup.enabled to false" {
  run bash "$HEARTBEATCTL" backup-identity --disable
  [ "$status" -eq 0 ]
  run yq '.features.identity_backup.enabled' "$HEARTBEATCTL_WORKSPACE/agent.yml"
  [ "$output" = "false" ]
}

@test "--dry-run stages without pushing" {
  mkdir -p "$IDENTITY_STATE_DIR/.claude/channels/telegram" "$IDENTITY_STATE_DIR/.claude/plugins/config"
  echo '{}' > "$IDENTITY_STATE_DIR/.claude/settings.json"
  echo '{}' > "$IDENTITY_STATE_DIR/.claude.json"
  echo '{}' > "$IDENTITY_STATE_DIR/.claude/channels/telegram/access.json"

  yq -i '.scaffold.fork.url = ""' "$HEARTBEATCTL_WORKSPACE/agent.yml"

  run bash "$HEARTBEATCTL" backup-identity --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"dry-run"* ]] || [[ "$output" == *"no push"* ]]
}

@test "reload emits identity backup cron line when enabled" {
  run bash "$HEARTBEATCTL" reload
  [ "$status" -eq 0 ]

  run cat "$HEARTBEATCTL_CRONTAB_FILE"
  [[ "$output" == *"heartbeatctl backup-identity"* ]]
  [[ "$output" == *"30 3"* ]]
}

@test "reload omits backup line when identity_backup.enabled=false" {
  yq -i '.features.identity_backup.enabled = false' "$HEARTBEATCTL_WORKSPACE/agent.yml"
  run bash "$HEARTBEATCTL" reload
  [ "$status" -eq 0 ]

  run cat "$HEARTBEATCTL_CRONTAB_FILE"
  [[ "$output" != *"backup-identity"* ]]
}

@test "backup-identity skips when hash matches last state" {
  mkdir -p "$IDENTITY_STATE_DIR/.claude/channels/telegram"
  echo '{}' > "$IDENTITY_STATE_DIR/.claude/settings.json"
  echo '{}' > "$IDENTITY_STATE_DIR/.claude.json"
  echo '{"allowFrom":[]}' > "$IDENTITY_STATE_DIR/.claude/channels/telegram/access.json"
  mkdir -p "$IDENTITY_STATE_DIR/.claude/plugins/config"

  source "$BATS_TEST_DIRNAME/../docker/scripts/lib/backup_identity.sh"
  local h
  h=$(identity_hash "$IDENTITY_STATE_DIR")
  mkdir -p "$HEARTBEATCTL_WORKSPACE/scripts/heartbeat"
  printf '{"hash":"%s","mode":"partial","last_commit":"abc","last_push":"2026-04-22T00:00:00Z"}\n' \
    "$h" > "$HEARTBEATCTL_WORKSPACE/scripts/heartbeat/identity-backup.json"

  run bash "$HEARTBEATCTL" backup-identity
  [ "$status" -eq 0 ]
  [[ "$output" == *"no changes"* ]]
}
