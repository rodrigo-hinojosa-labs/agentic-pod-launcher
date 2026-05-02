#!/usr/bin/env bats
# Opt-in: DOCKER_E2E=1 bats tests/docker-e2e-backup-identity.bats
load 'helper'

setup() {
  [ "${DOCKER_E2E:-0}" = "1" ] || skip "set DOCKER_E2E=1 to run"
}

@test "watchdog fires identity backup within 90s of an access.json mutation" {
  # Placeholder: the full e2e setup spins a container with a mock fork
  # URL and exercises the watchdog. Implementation details left to the
  # operator — this test establishes the contract.
  skip "requires full docker harness — tracked in Task 16 follow-up"
}
