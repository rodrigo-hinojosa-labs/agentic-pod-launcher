#!/usr/bin/env bats
# Tests for `agentctl doctor`'s token-health checks (16-18).
# Mirror of agentctl-doctor-freshness.bats: stub the docker shim so the
# doctor reaches the token-health block, then drop fake state files in
# scripts/heartbeat/token-health/ and assert the expected output.

load helper

AGENTCTL="$REPO_ROOT/scripts/agentctl"

setup() {
  setup_tmp_dir
  cat > "$TMP_TEST_DIR/agent.yml" <<YAML
agent:
  name: testagent
notifications:
  channel: none
vault:
  enabled: false
YAML
  mkdir -p "$TMP_TEST_DIR/scripts/heartbeat/token-health"

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

_iso_ago() {
  local delta="$1"
  local then now
  now=$(date -u +%s)
  then=$((now - delta))
  if date -u -d "@$then" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null; then return 0; fi
  date -u -j -f "%s" "$then" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null
}

@test "token-health: no state files → no token checks emitted" {
  cd "$TMP_TEST_DIR"
  AGENT_NAME=testagent run "$AGENTCTL" doctor
  # When the dir exists but no files, the loop just produces nothing.
  ! echo "$output" | grep -q "Token github"
  ! echo "$output" | grep -q "Token telegram"
}

@test "token-health: github status=ok → ✓ pass" {
  cd "$TMP_TEST_DIR"
  local ts
  ts=$(_iso_ago 600)
  cat > "$TMP_TEST_DIR/scripts/heartbeat/token-health/github.json" <<JSON
{"id":"github","kind":"github_pat","status":"ok",
 "last_check":"$ts","http_code":"200","latency_ms":142,
 "consecutive_failures":0,"first_failure_at":null,
 "last_warned_at":null,"error":null}
JSON

  AGENT_NAME=testagent run "$AGENTCTL" doctor
  echo "$output" | grep -qE "✓ Token github: ok \(probed [0-9]+m ago, 142ms\)"
}

@test "token-health: github status=auth_fail → ✗ fail" {
  cd "$TMP_TEST_DIR"
  local ts
  ts=$(_iso_ago 600)
  cat > "$TMP_TEST_DIR/scripts/heartbeat/token-health/github.json" <<JSON
{"id":"github","kind":"github_pat","status":"auth_fail",
 "last_check":"$ts","http_code":"401","latency_ms":98,
 "consecutive_failures":1,"first_failure_at":"$ts",
 "last_warned_at":"$ts","error":"HTTP 401"}
JSON

  AGENT_NAME=testagent run "$AGENTCTL" doctor
  echo "$output" | grep -qE "✗ Token github: auth-fail \(HTTP 401"
  echo "$output" | grep -q "Regenerate the token"
}

@test "token-health: stale last_check → ⚠ warn even if status=ok" {
  cd "$TMP_TEST_DIR"
  # 4h ago — default DOCTOR_TOKEN_MAX_AGE_HOURS=2 → stale.
  local ts
  ts=$(_iso_ago 14400)
  cat > "$TMP_TEST_DIR/scripts/heartbeat/token-health/github.json" <<JSON
{"id":"github","kind":"github_pat","status":"ok",
 "last_check":"$ts","http_code":"200","latency_ms":100,
 "consecutive_failures":0,"first_failure_at":null,
 "last_warned_at":null,"error":null}
JSON

  AGENT_NAME=testagent run "$AGENTCTL" doctor
  echo "$output" | grep -qE "⚠ Token github: last probe [0-9]+h ago — stale"
}

@test "token-health: env override DOCTOR_TOKEN_MAX_AGE_HOURS=0 forces stale" {
  cd "$TMP_TEST_DIR"
  local ts
  ts=$(_iso_ago 600)
  cat > "$TMP_TEST_DIR/scripts/heartbeat/token-health/github.json" <<JSON
{"id":"github","kind":"github_pat","status":"ok",
 "last_check":"$ts","http_code":"200","latency_ms":100,
 "consecutive_failures":0,"first_failure_at":null,
 "last_warned_at":null,"error":null}
JSON

  DOCTOR_TOKEN_MAX_AGE_HOURS=0 AGENT_NAME=testagent run "$AGENTCTL" doctor
  echo "$output" | grep -qE "⚠ Token github: last probe [0-9]+m ago — stale"
}

@test "token-health: status=network → ⚠ degraded (not fatal)" {
  cd "$TMP_TEST_DIR"
  local ts
  ts=$(_iso_ago 600)
  cat > "$TMP_TEST_DIR/scripts/heartbeat/token-health/github.json" <<JSON
{"id":"github","kind":"github_pat","status":"network",
 "last_check":"$ts","http_code":"000","latency_ms":10000,
 "consecutive_failures":1,"first_failure_at":"$ts",
 "last_warned_at":null,"error":"curl exit 28 (DNS/TLS/timeout)"}
JSON

  AGENT_NAME=testagent run "$AGENTCTL" doctor
  echo "$output" | grep -qE "⚠ Token github: network error"
}

@test "token-health: atlassian — multiple workspaces produce one line each" {
  cd "$TMP_TEST_DIR"
  local ts
  ts=$(_iso_ago 600)
  for name in work personal; do
    cat > "$TMP_TEST_DIR/scripts/heartbeat/token-health/atlassian-${name}.json" <<JSON
{"id":"atlassian-$name","kind":"atlassian","status":"ok",
 "last_check":"$ts","http_code":"200","latency_ms":110,
 "consecutive_failures":0,"first_failure_at":null,
 "last_warned_at":null,"error":null}
JSON
  done

  AGENT_NAME=testagent run "$AGENTCTL" doctor
  echo "$output" | grep -q "Token atlassian-work: ok"
  echo "$output" | grep -q "Token atlassian-personal: ok"
}
