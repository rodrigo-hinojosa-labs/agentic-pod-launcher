#!/usr/bin/env bats
load 'helper'

setup() {
  # shellcheck source=/dev/null
  source "$BATS_TEST_DIRNAME/../scripts/lib/wizard-validators.sh"
}

# normalize_agent_name maps a human-typed name to a valid DNS label:
# lowercase, spaces→hyphens, collapse consecutive hyphens, trim ends.

@test "normalize_agent_name maps spaces+capitals to a hyphenated lowercase name" {
  run normalize_agent_name "Rodri Cenco Admin"
  [ "$status" -eq 0 ]
  [ "$output" = "rodri-cenco-admin" ]
}

@test "normalize_agent_name collapses runs of spaces and hyphens to a single hyphen" {
  run normalize_agent_name "my  --  agent"
  [ "$status" -eq 0 ]
  [ "$output" = "my-agent" ]
}

@test "normalize_agent_name trims a leading hyphen produced by a leading space" {
  run normalize_agent_name " -leading"
  [ "$status" -eq 0 ]
  [ "$output" = "leading" ]
}

@test "normalize_agent_name is idempotent on an already-normalized name" {
  run normalize_agent_name "rodri-cenco-admin"
  [ "$status" -eq 0 ]
  [ "$output" = "rodri-cenco-admin" ]
}
