#!/usr/bin/env bats
# 048 (US6, contract D3): the docker doctor reads the heartbeat state from where
# heartbeat.sh writes it (scripts/heartbeat/state.json) and from the fields it
# writes (.last_run.status, .ts, .duration_ms). Before 048 it read
# scripts/heartbeat/logs/state.json and .last_run.ended_at, which never exist, so an
# agent with 1818 runs ok showed "Heartbeat enabled but no run recorded yet".

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
features:
  heartbeat:
    enabled: true
YAML
  mkdir -p "$TMP_TEST_DIR/scripts/heartbeat/logs"

  # docker shim: healthy for every check; `exec ... sh -c CMD` runs CMD on the
  # host with /workspace mapped to the test workspace, so the doctor reads the
  # files this test writes.
  cat > "$TMP_TEST_DIR/docker" <<SHIM
#!/usr/bin/env bash
case "\$1" in
  info)    exit 0 ;;
  ps)      echo "abc123def456"; exit 0 ;;
  inspect) echo "running"; exit 0 ;;
  exec)
    while [ \$# -gt 0 ] && [ "\$1" != "sh" ]; do shift; done
    [ "\$1" = "sh" ] && [ "\$2" = "-c" ] || exit 0
    cmd="\$3"
    cmd="\${cmd//\/workspace/$TMP_TEST_DIR}"
    sh -c "\$cmd"
    exit \$? ;;
  *)       exit 0 ;;
esac
SHIM
  chmod +x "$TMP_TEST_DIR/docker"
  export PATH="$TMP_TEST_DIR:$PATH"
}

teardown() { teardown_tmp_dir; }

_state() {
  cat > "$TMP_TEST_DIR/scripts/heartbeat/state.json" <<JSON
{"schema":1,"enabled":true,"last_run":{"status":"$1","ts":"2026-11-21T15:00:00Z","duration_ms":21000,"attempt":1}}
JSON
}

@test "TD11 doctor: heartbeat state in scripts/heartbeat/state.json -> last run reported" {
  _state ok
  cd "$TMP_TEST_DIR"
  AGENT_NAME=testagent run "$AGENTCTL" doctor
  echo "$output" | grep -qF "Heartbeat last run: ok @ 2026-11-21T15:00:00Z (21000ms)"
  if echo "$output" | grep -q "no run recorded yet"; then false; fi
}

@test "TD12 doctor: no heartbeat state -> the pre-048 warning" {
  cd "$TMP_TEST_DIR"
  AGENT_NAME=testagent run "$AGENTCTL" doctor
  echo "$output" | grep -q "Heartbeat enabled but no run recorded yet"
}

@test "TD13 doctor: last run failed -> the pre-048 failure" {
  _state error
  cd "$TMP_TEST_DIR"
  AGENT_NAME=testagent run "$AGENTCTL" doctor
  echo "$output" | grep -q "Heartbeat last run: error"
}

@test "TD14 doctor: a stale logs/state.json is ignored" {
  cat > "$TMP_TEST_DIR/scripts/heartbeat/logs/state.json" <<JSON
{"schema":1,"last_run":{"status":"ok","ended_at":"1999-01-01T00:00:00Z","duration_ms":1}}
JSON
  cd "$TMP_TEST_DIR"
  AGENT_NAME=testagent run "$AGENTCTL" doctor
  echo "$output" | grep -q "Heartbeat enabled but no run recorded yet"
}
