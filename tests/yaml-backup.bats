#!/usr/bin/env bats
load 'helper'

setup() {
  AGENT_YML="$BATS_TEST_DIRNAME/fixtures/sample-agent.yml"
}

@test "sample-agent.yml declares backup.identity.recipient (may be null)" {
  run yq '.backup.identity.recipient' "$AGENT_YML"
  [ "$status" -eq 0 ]
  # accept both "null" and empty string for "not yet configured"
  [[ "$output" == "null" ]] || [ -z "$output" ]
}

@test "sample-agent.yml declares features.identity_backup.enabled" {
  run yq '.features.identity_backup.enabled' "$AGENT_YML"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ] || [ "$output" = "false" ]
}

@test "sample-agent.yml declares features.identity_backup.schedule" {
  run yq '.features.identity_backup.schedule' "$AGENT_YML"
  [ "$status" -eq 0 ]
  # default schedule "30 3 * * *"
  [[ "$output" =~ [0-9]+\ [0-9]+\ \*\ \*\ \* ]]
}

@test "sample-agent.yml declares vault.enabled" {
  run yq '.vault.enabled' "$AGENT_YML"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ] || [ "$output" = "false" ]
}

@test "sample-agent.yml declares vault.backup_schedule" {
  run yq '.vault.backup_schedule' "$AGENT_YML"
  [ "$status" -eq 0 ]
  # 5-field cron expression — any valid pattern
  [[ "$output" =~ [\*0-9/]+\ [\*0-9/]+\ [\*0-9/]+\ [\*0-9/]+\ [\*0-9/]+ ]]
}

@test "sample-agent.yml declares features.config_backup.enabled" {
  run yq '.features.config_backup.enabled' "$AGENT_YML"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ] || [ "$output" = "false" ]
}

@test "sample-agent.yml declares features.config_backup.schedule" {
  run yq '.features.config_backup.schedule' "$AGENT_YML"
  [ "$status" -eq 0 ]
  [[ "$output" =~ [0-9]+\ [0-9]+\ \*\ \*\ \* ]]
}
