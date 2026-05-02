#!/usr/bin/env bats
load 'helper'

setup() {
  export HEARTBEATCTL_WORKSPACE="$BATS_TEST_TMPDIR/ws"
  export HEARTBEATCTL_LIB_DIR="$BATS_TEST_DIRNAME/../docker/scripts/lib"
  export HEARTBEATCTL_CRONTAB_FILE="$BATS_TEST_TMPDIR/crontab"
  mkdir -p "$HEARTBEATCTL_WORKSPACE/scripts/heartbeat"
  export CONFIG_BACKUP_CACHE_DIR="$BATS_TEST_TMPDIR/backup-cache"

  # Local bare repo as "remote"
  export FORK_BARE="$BATS_TEST_TMPDIR/fork.git"
  git init --bare --initial-branch=main "$FORK_BARE" >/dev/null 2>&1

  cat > "$HEARTBEATCTL_WORKSPACE/agent.yml" <<YAML
agent:
  name: testagent
  display_name: "Test Agent"
scaffold:
  fork:
    url: "$FORK_BARE"
features:
  identity_backup:
    enabled: false
  config_backup:
    enabled: true
YAML

  export GIT_AUTHOR_NAME=test
  export GIT_AUTHOR_EMAIL=test@example
  export GIT_COMMITTER_NAME=test
  export GIT_COMMITTER_EMAIL=test@example

  HEARTBEATCTL="$BATS_TEST_DIRNAME/../docker/scripts/heartbeatctl"
}

@test "backup-config --help lists the flags" {
  run bash "$HEARTBEATCTL" backup-config --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"backup-config"* ]]
  [[ "$output" == *"--dry-run"* ]]
}

@test "backup-config rejects unknown flags" {
  run bash "$HEARTBEATCTL" backup-config --bogus
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown flag"* ]]
}

@test "first config backup creates orphan branch + pushes single commit" {
  run bash "$HEARTBEATCTL" backup-config
  [ "$status" -eq 0 ]
  [[ "$output" == *"pushed"* ]]

  run git --git-dir="$FORK_BARE" rev-parse backup/config
  [ "$status" -eq 0 ]

  run git --git-dir="$FORK_BARE" ls-tree -r --name-only backup/config
  [[ "$output" == *"agent.yml"* ]]
}

@test "second config backup is no-op when agent.yml unchanged" {
  run bash "$HEARTBEATCTL" backup-config
  [ "$status" -eq 0 ]

  run bash "$HEARTBEATCTL" backup-config
  [ "$status" -eq 0 ]
  [[ "$output" == *"no changes since last backup"* ]]
}

@test "config backup creates a new commit when agent.yml changes" {
  run bash "$HEARTBEATCTL" backup-config
  [ "$status" -eq 0 ]
  local sha1
  sha1=$(git --git-dir="$FORK_BARE" rev-parse backup/config)

  yq -i '.agent.display_name = "Renamed Agent"' "$HEARTBEATCTL_WORKSPACE/agent.yml"

  run bash "$HEARTBEATCTL" backup-config
  [ "$status" -eq 0 ]
  local sha2
  sha2=$(git --git-dir="$FORK_BARE" rev-parse backup/config)

  [ "$sha1" != "$sha2" ]
}

@test "backup-config --dry-run does not push" {
  run bash "$HEARTBEATCTL" backup-config --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"dry-run"* ]]

  run git --git-dir="$FORK_BARE" rev-parse --verify backup/config
  [ "$status" -ne 0 ]
}

@test "backup-config no-ops when agent.yml is missing" {
  rm "$HEARTBEATCTL_WORKSPACE/agent.yml"
  run bash "$HEARTBEATCTL" backup-config
  [ "$status" -eq 0 ]
  [[ "$output" == *"missing"* ]] || [[ "$output" == *"nothing to back up"* ]]
}

@test "reload emits config backup cron line by default" {
  # config_backup.enabled defaults to true when unset; explicitly drop
  # the key to verify the default kicks in.
  yq -i 'del(.features.config_backup)' "$HEARTBEATCTL_WORKSPACE/agent.yml"
  run bash "$HEARTBEATCTL" reload
  [ "$status" -eq 0 ]

  run cat "$HEARTBEATCTL_CRONTAB_FILE"
  [[ "$output" == *"heartbeatctl backup-config"* ]]
  [[ "$output" == *"30 3"* ]]
}

@test "reload omits config backup line when config_backup.enabled=false" {
  yq -i '.features.config_backup.enabled = false' "$HEARTBEATCTL_WORKSPACE/agent.yml"
  run bash "$HEARTBEATCTL" reload
  [ "$status" -eq 0 ]

  run cat "$HEARTBEATCTL_CRONTAB_FILE"
  [[ "$output" != *"backup-config"* ]]
}

@test "config_hash is deterministic + content-sensitive" {
  source "$BATS_TEST_DIRNAME/../docker/scripts/lib/backup_config.sh"
  local h1 h2 h3
  h1=$(config_hash "$HEARTBEATCTL_WORKSPACE/agent.yml")
  h2=$(config_hash "$HEARTBEATCTL_WORKSPACE/agent.yml")
  [ "$h1" = "$h2" ]
  [ -n "$h1" ]

  yq -i '.agent.role = "changed"' "$HEARTBEATCTL_WORKSPACE/agent.yml"
  h3=$(config_hash "$HEARTBEATCTL_WORKSPACE/agent.yml")
  [ "$h1" != "$h3" ]
}
