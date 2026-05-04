#!/usr/bin/env bats
# Doctor check 19 (claude_oauth) — Phase A2.3 of OAuth resilience.
# Mirror of agentctl-doctor-token-health.bats: stub docker so doctor
# reaches the token-health block, then drop a fake claude_oauth.json
# state file in scripts/heartbeat/token-health/ and assert the output.

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
  ps)      echo "abc123"; exit 0 ;;
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

@test "doctor: claude_oauth ok → ✓ pass" {
  cd "$TMP_TEST_DIR"
  local ts
  ts=$(_iso_ago 600)
  cat > scripts/heartbeat/token-health/claude_oauth.json <<JSON
{"id":"claude_oauth","kind":"claude_oauth","status":"ok",
 "last_check":"$ts","http_code":"000","latency_ms":0,
 "consecutive_failures":0,"first_failure_at":null,
 "last_warned_at":null,"error":null}
JSON

  AGENT_NAME=testagent run "$AGENTCTL" doctor
  echo "$output" | grep -qE "✓ Token claude_oauth: ok"
}

@test "doctor: claude_oauth status=auth_fail (expired) → ✗" {
  cd "$TMP_TEST_DIR"
  local ts
  ts=$(_iso_ago 600)
  cat > scripts/heartbeat/token-health/claude_oauth.json <<JSON
{"id":"claude_oauth","kind":"claude_oauth","status":"auth_fail",
 "last_check":"$ts","http_code":"000","latency_ms":0,
 "consecutive_failures":2,"first_failure_at":"$ts",
 "last_warned_at":"$ts","error":"expired 3600s ago"}
JSON

  AGENT_NAME=testagent run "$AGENTCTL" doctor
  echo "$output" | grep -qE "✗ Token claude_oauth: auth-fail"
}

@test "doctor: claude_oauth state file absent → no check emitted" {
  cd "$TMP_TEST_DIR"
  # No claude_oauth.json file → doctor should NOT print anything for it.
  AGENT_NAME=testagent run "$AGENTCTL" doctor
  ! echo "$output" | grep -q "Token claude_oauth"
}

@test "doctor: claude_oauth stale last_check (>2h) → ⚠ warn" {
  cd "$TMP_TEST_DIR"
  local ts
  ts=$(_iso_ago 14400)   # 4h ago
  cat > scripts/heartbeat/token-health/claude_oauth.json <<JSON
{"id":"claude_oauth","kind":"claude_oauth","status":"ok",
 "last_check":"$ts","http_code":"000","latency_ms":0,
 "consecutive_failures":0,"first_failure_at":null,
 "last_warned_at":null,"error":null}
JSON

  AGENT_NAME=testagent run "$AGENTCTL" doctor
  echo "$output" | grep -qE "⚠ Token claude_oauth: last probe [0-9]+h ago — stale"
}
