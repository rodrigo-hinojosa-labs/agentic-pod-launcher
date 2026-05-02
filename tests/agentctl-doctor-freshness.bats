#!/usr/bin/env bats
# Tests for `agentctl doctor`'s backup freshness checks (12 → 15 checks).
# Strategy: stub a docker shim that reports "everything healthy" so the
# doctor reaches the freshness blocks at the end. Then drop fake state
# files in the workspace's scripts/heartbeat/ and assert the right
# pass/warn output.

load helper

AGENTCTL="$REPO_ROOT/scripts/agentctl"

setup() {
  setup_tmp_dir
  # Workspace lives in TMP_TEST_DIR so `_resolve_workspace` finds it via
  # the cwd path (agent.yml present → pwd -P).
  cat > "$TMP_TEST_DIR/agent.yml" <<YAML
agent:
  name: testagent
notifications:
  channel: none
vault:
  enabled: false
YAML
  mkdir -p "$TMP_TEST_DIR/scripts/heartbeat"

  # docker shim: every check the doctor runs returns "healthy". Doctor
  # walks 1→12 normally and reaches the freshness blocks (13→15). Without
  # this, the early-exit guards (daemon down, container missing) bail out.
  cat > "$TMP_TEST_DIR/docker" <<'SHIM'
#!/usr/bin/env bash
case "$1" in
  info)    exit 0 ;;
  ps)      echo "abc123def456"; exit 0 ;;
  inspect) echo "running"; exit 0 ;;
  exec)    exit 0 ;;
  *)       exit 0 ;;
esac
SHIM
  chmod +x "$TMP_TEST_DIR/docker"
  export PATH="$TMP_TEST_DIR:$PATH"
}

teardown() { teardown_tmp_dir; }

# Helper: build an ISO 8601 UTC timestamp `delta_seconds` ago.
_iso_ago() {
  local delta="$1"
  local then now
  now=$(date -u +%s)
  then=$((now - delta))
  if date -u -d "@$then" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null; then return 0; fi
  date -u -j -f "%s" "$then" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null
}

@test "freshness: state files absent → all 3 checks ⚠ (never pushed)" {
  cd "$TMP_TEST_DIR"
  AGENT_NAME=testagent run "$AGENTCTL" doctor
  echo "$output" | grep -q "Backup identity: never pushed yet"
  echo "$output" | grep -q "Backup vault: never pushed yet"
  echo "$output" | grep -q "Backup config: never pushed yet"
}

@test "freshness: recent timestamp → ✓ pass with humanized delta" {
  cd "$TMP_TEST_DIR"
  local ts
  ts=$(_iso_ago 600)  # 10 minutes ago
  cat > "$TMP_TEST_DIR/scripts/heartbeat/identity-backup.json" <<JSON
{"hash":"abc","mode":"full","last_commit":"deadbeef","last_push":"$ts"}
JSON

  AGENT_NAME=testagent run "$AGENTCTL" doctor
  echo "$output" | grep -qE "✓ Backup identity: pushed [0-9]+m ago \(full mode\)"
}

@test "freshness: stale timestamp → ⚠ warn" {
  cd "$TMP_TEST_DIR"
  local ts
  ts=$(_iso_ago 360000)  # 100 hours ago
  cat > "$TMP_TEST_DIR/scripts/heartbeat/identity-backup.json" <<JSON
{"hash":"abc","mode":"full","last_commit":"deadbeef","last_push":"$ts"}
JSON

  AGENT_NAME=testagent run "$AGENTCTL" doctor
  echo "$output" | grep -qE "⚠ Backup identity: pushed [0-9]+(d|h) ago — stale"
}

@test "freshness: env var threshold override is respected" {
  cd "$TMP_TEST_DIR"
  local ts
  ts=$(_iso_ago 120)  # 2 minutes ago
  cat > "$TMP_TEST_DIR/scripts/heartbeat/identity-backup.json" <<JSON
{"hash":"abc","mode":"full","last_commit":"deadbeef","last_push":"$ts"}
JSON

  # 0h threshold → "anything older than now" is stale → check warns.
  DOCTOR_IDENTITY_MAX_AGE_HOURS=0 AGENT_NAME=testagent \
    run "$AGENTCTL" doctor
  echo "$output" | grep -qE "⚠ Backup identity: pushed [0-9]+m ago — stale"
}

@test "freshness: vault state file with malformed last_push → ⚠ parse warning" {
  cd "$TMP_TEST_DIR"
  cat > "$TMP_TEST_DIR/scripts/heartbeat/vault-backup.json" <<JSON
{"hash":"abc","last_commit":"deadbeef","last_push":"yesterday at 5pm"}
JSON

  AGENT_NAME=testagent run "$AGENTCTL" doctor
  echo "$output" | grep -q "Backup vault: could not parse last_push"
}

@test "freshness: _epoch_from_iso parses ISO 8601 UTC correctly" {
  # Source the script in a noop way that exposes the helper without
  # invoking main. The agentctl script uses `cmd_$1` dispatch, so just
  # sourcing it is safe (no side effects beyond function definitions).
  source "$AGENTCTL" >/dev/null 2>&1 || true

  local epoch
  epoch=$(_epoch_from_iso "2026-05-02T03:30:00Z")
  [ -n "$epoch" ]
  # Cross-platform sanity: date 2026-05-02T03:30:00Z is between
  # 1777686000 (2026-05-02T00:00:00Z) and 1777800000 (2026-05-03T07:40:00Z).
  [ "$epoch" -gt 1777680000 ]
  [ "$epoch" -lt 1777800000 ]
}

@test "freshness: _humanize_delta produces coarse-grained output" {
  source "$AGENTCTL" >/dev/null 2>&1 || true
  [ "$(_humanize_delta 30)" = "30s" ]
  [ "$(_humanize_delta 600)" = "10m" ]
  [ "$(_humanize_delta 7200)" = "2h" ]
  [ "$(_humanize_delta 90000)" = "1d" ]
}
