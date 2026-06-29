#!/usr/bin/env bats
# US2/US3 (010-self-managing-rag): `heartbeatctl reload` emits the qmd-reindex
# cron backstop line guarded by vault.qmd.enabled (honoring vault.qmd.schedule),
# and the `qmd-reindex` subcommand dispatches. Host-side, no Docker — mirrors
# tests/backup-vault-cmd.bats.

load helper

setup() {
  export HEARTBEATCTL_WORKSPACE="$BATS_TEST_TMPDIR/ws"
  export HEARTBEATCTL_LIB_DIR="$BATS_TEST_DIRNAME/../docker/scripts/lib"
  export HEARTBEATCTL_CRONTAB_FILE="$BATS_TEST_TMPDIR/crontab"
  mkdir -p "$HEARTBEATCTL_WORKSPACE/scripts/heartbeat"

  cat > "$HEARTBEATCTL_WORKSPACE/agent.yml" <<YAML
agent:
  name: testagent
features:
  heartbeat:
    enabled: true
    interval: 30m
vault:
  enabled: true
  path: .state/.vault
  qmd:
    enabled: true
    version: "2.5.3"
    schedule: "*/5 * * * *"
YAML

  HEARTBEATCTL="$BATS_TEST_DIRNAME/../docker/scripts/heartbeatctl"
}

@test "reload emits qmd-reindex cron line when vault.qmd.enabled=true (default */5)" {
  run bash "$HEARTBEATCTL" reload
  [ "$status" -eq 0 ]
  run cat "$HEARTBEATCTL_CRONTAB_FILE"
  echo "$output" | grep -qF "heartbeatctl qmd-reindex"
  echo "$output" | grep -qF "*/5 * * * *"
}

@test "reload uses vault.qmd.schedule override" {
  yq -i '.vault.qmd.schedule = "*/10 * * * *"' "$HEARTBEATCTL_WORKSPACE/agent.yml"
  run bash "$HEARTBEATCTL" reload
  [ "$status" -eq 0 ]
  run cat "$HEARTBEATCTL_CRONTAB_FILE"
  echo "$output" | grep -qF "qmd-reindex"
  echo "$output" | grep -qF "*/10 * * * *"
}

@test "reload omits qmd-reindex line when vault.qmd.enabled=false" {
  yq -i '.vault.qmd.enabled = false' "$HEARTBEATCTL_WORKSPACE/agent.yml"
  run bash "$HEARTBEATCTL" reload
  [ "$status" -eq 0 ]
  run cat "$HEARTBEATCTL_CRONTAB_FILE"
  ! echo "$output" | grep -q "qmd-reindex"
}

@test "qmd-reindex --help lists the subcommand and flag" {
  run bash "$HEARTBEATCTL" qmd-reindex --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF "qmd-reindex"
  echo "$output" | grep -qF -- "--dry-run"
}

@test "qmd-reindex --dry-run reports 'would reindex' when no prior index state exists" {
  export QMD_VAULT_DIR="$BATS_TEST_TMPDIR/vault"; mkdir -p "$QMD_VAULT_DIR"
  printf '# note\nhello\n' > "$QMD_VAULT_DIR/a.md"
  export QMD_INDEX_STATE_FILE="$BATS_TEST_TMPDIR/qmd-index.json"  # intentionally absent
  run bash "$HEARTBEATCTL" qmd-reindex --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "would reindex"
}

@test "qmd-reindex --dry-run reports 'vault unchanged' when the recorded hash matches" {
  export QMD_VAULT_DIR="$BATS_TEST_TMPDIR/vault"; mkdir -p "$QMD_VAULT_DIR"
  printf '# note\nhello\n' > "$QMD_VAULT_DIR/a.md"
  export QMD_INDEX_STATE_FILE="$BATS_TEST_TMPDIR/qmd-index.json"
  # Pre-seed the state with the CURRENT vault hash so the dry-run sees no change.
  # shellcheck source=/dev/null
  source "$BATS_TEST_DIRNAME/../docker/scripts/lib/qmd_index.sh"
  local h; h=$(vault_hash "$QMD_VAULT_DIR")
  qmd_write_state "$QMD_INDEX_STATE_FILE" "$h" "indexed"
  run bash "$HEARTBEATCTL" qmd-reindex --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "vault unchanged"
}

@test "qmd-reindex rejects unknown flags" {
  run bash "$HEARTBEATCTL" qmd-reindex --bogus
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi "unknown flag"
}
