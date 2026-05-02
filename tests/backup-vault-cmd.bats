#!/usr/bin/env bats
load 'helper'

setup() {
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
vault:
  enabled: true
  path: .state/.vault
features:
  identity_backup:
    enabled: false
  heartbeat:
    enabled: true
    interval: 30m
YAML

  HEARTBEATCTL="$BATS_TEST_DIRNAME/../docker/scripts/heartbeatctl"
}

@test "backup-vault --help lists the subcommand flags" {
  run bash "$HEARTBEATCTL" backup-vault --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"backup-vault"* ]]
  [[ "$output" == *"--dry-run"* ]]
  [[ "$output" == *"--gc"* ]]
}

@test "backup-vault rejects unknown flags" {
  run bash "$HEARTBEATCTL" backup-vault --bogus
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown flag"* ]]
}

@test "backup-vault no-ops when vault dir does not exist yet" {
  export VAULT_BACKUP_DIR="$BATS_TEST_TMPDIR/missing-vault"
  run bash -c "VAULT_BACKUP_DIR=$VAULT_BACKUP_DIR bash $HEARTBEATCTL backup-vault"
  [ "$status" -eq 0 ]
  [[ "$output" == *"does not exist"* ]] || [[ "$output" == *"vault not enabled"* ]]
}

@test "backup-vault no-ops when vault is disabled in agent.yml" {
  yq -i '.vault.enabled = false' "$HEARTBEATCTL_WORKSPACE/agent.yml"
  run bash "$HEARTBEATCTL" backup-vault
  [ "$status" -eq 0 ]
  [[ "$output" == *"vault not enabled"* ]]
}

@test "reload emits vault backup cron line when vault.enabled=true (default schedule)" {
  run bash "$HEARTBEATCTL" reload
  [ "$status" -eq 0 ]

  run cat "$HEARTBEATCTL_CRONTAB_FILE"
  [[ "$output" == *"heartbeatctl backup-vault"* ]]
  [[ "$output" == *"0 * * * *"* ]]
}

@test "reload uses vault.backup_schedule override when set" {
  yq -i '.vault.backup_schedule = "*/15 * * * *"' "$HEARTBEATCTL_WORKSPACE/agent.yml"
  run bash "$HEARTBEATCTL" reload
  [ "$status" -eq 0 ]

  run cat "$HEARTBEATCTL_CRONTAB_FILE"
  [[ "$output" == *"heartbeatctl backup-vault"* ]]
  [[ "$output" == *"*/15 * * * *"* ]]
}

@test "reload omits vault backup line when vault.enabled=false" {
  yq -i '.vault.enabled = false' "$HEARTBEATCTL_WORKSPACE/agent.yml"
  run bash "$HEARTBEATCTL" reload
  [ "$status" -eq 0 ]

  run cat "$HEARTBEATCTL_CRONTAB_FILE"
  [[ "$output" != *"backup-vault"* ]]
}

@test "main switch dispatches backup-vault to cmd_backup_vault" {
  # No --help, no flags → defaults to run mode, which immediately
  # short-circuits on "vault not enabled" if VAULT_BACKUP_DIR is unset
  # and agent.yml says enabled but the path doesn't exist. Either way
  # we expect a clean exit 0 — we're testing the dispatch, not the run.
  yq -i '.vault.enabled = false' "$HEARTBEATCTL_WORKSPACE/agent.yml"
  run bash "$HEARTBEATCTL" backup-vault
  [ "$status" -eq 0 ]
  [[ "$output" == *"vault"* ]]
}
