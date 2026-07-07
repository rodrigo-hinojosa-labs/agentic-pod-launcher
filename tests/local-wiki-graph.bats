#!/usr/bin/env bats
# 014 (US4, FR-012/013): the local wiki-graph pipeline — the derive+lint
# entrypoint wrapper (PATH self-provision + vault env, all 013 lessons day-1) and
# its systemd service/timer. Host-runnable: the wrapper sources a STUB
# wiki_graph.sh so we test the WIRING (env + PATH order + exit 0), not the lib
# internals (covered by wiki-graph.bats). Units are asserted from rendered text.

load helper

setup() {
  setup_tmp_dir
  load_lib render
  load_lib yaml
  yaml_require_yq >/dev/null

  WS="$TMP_TEST_DIR/ws"
  mkdir -p "$WS/scripts/local" "$WS/scripts/lib" "$WS/scripts/heartbeat" "$WS/.state/.vault"

  cat > "$TMP_TEST_DIR/agent.yml" << YML
version: 1
agent: {name: locbot, display_name: "L", role: "r", vibe: "v"}
user: {name: A, nickname: A, timezone: UTC, email: a@b.com, language: en}
deployment: {host: rpi5, workspace: "$WS", install_service: false, claude_cli: claude, mode: local}
notifications: {channel: none}
vault: {enabled: true, seed_skeleton: true, path: .state/.vault, wiki_graph: {enabled: true, schedule: "20 */6 * * *"}}
YML
  render_load_context "$TMP_TEST_DIR/agent.yml" >/dev/null
  export DEPLOYMENT_WORKSPACE="$WS"
  export AGENT_NAME=locbot
  export OPERATOR_USER=op
  export OPERATOR_HOME="$TMP_TEST_DIR/home"
  export LOCAL_VAULT_DIR="$WS/.state/.vault"
  export WIKI_GRAPH_TIMER_ONCALENDAR="*-*-* 0/6:20:00"

  # Stub wiki_graph.sh: record the env the wrapper set for the runner.
  cat > "$WS/scripts/lib/wiki_graph.sh" << 'SH'
wiki_graph_run() { echo "run|$1|PATH=$PATH|VRO=$VAULT_ROOT_OVERRIDE|WGVD=$WIKI_GRAPH_VAULT_DIR|SF=$WIKI_GRAPH_STATE_FILE|LK=$WIKI_GRAPH_LOCK" >> "$WG_TEST_LOG"; }
SH
  export WG_TEST_LOG="$TMP_TEST_DIR/wg.log"

  ENTRY="$WS/scripts/local/agent-wiki-graph.sh"
  render_to_file "$REPO_ROOT/modules/local-wiki-graph.sh.tpl" "$ENTRY"; chmod +x "$ENTRY"
}

teardown() { teardown_tmp_dir; }

@test "wrapper: exits 0 and runs wiki_graph_run against the workspace agent.yml" {
  run "$WS/scripts/local/agent-wiki-graph.sh"
  [ "$status" -eq 0 ]
  grep -q "^run|$WS/agent.yml|" "$WG_TEST_LOG"
}

@test "wrapper: PATH self-provides ~/.local/bin + vendor/bin (013 RC2 lesson, day-1)" {
  "$WS/scripts/local/agent-wiki-graph.sh"
  grep -q "PATH=$OPERATOR_HOME/.local/bin:$WS/scripts/vendor/bin:" "$WG_TEST_LOG"
}

@test "wrapper: the PATH export is the FIRST export in the rendered file" {
  # first `export` line must be PATH (before any vault-env export)
  local first
  first=$(grep -nE '^export ' "$WS/scripts/local/agent-wiki-graph.sh" | head -1)
  [[ "$first" == *"export PATH="* ]]
}

@test "wrapper: exports the vault env (VAULT_ROOT_OVERRIDE + WIKI_GRAPH_VAULT_DIR)" {
  "$WS/scripts/local/agent-wiki-graph.sh"
  grep -q "VRO=$LOCAL_VAULT_DIR|WGVD=$LOCAL_VAULT_DIR|" "$WG_TEST_LOG"
}

@test "wrapper: state file + lock live under heartbeat/, NEVER in the vault (Syncthing)" {
  "$WS/scripts/local/agent-wiki-graph.sh"
  grep -q "SF=$WS/scripts/heartbeat/wiki-graph.json|LK=$WS/scripts/heartbeat/.wiki-graph.lock" "$WG_TEST_LOG"
  # the lock/state paths must not be under the vault dir
  ! grep -qE "SF=$LOCAL_VAULT_DIR|LK=$LOCAL_VAULT_DIR" "$WG_TEST_LOG"
}

@test "service unit: Type=oneshot, runs the wrapper as the operator" {
  local svc="$TMP_TEST_DIR/wg.service"
  render_to_file "$REPO_ROOT/modules/local-wiki-graph.service.tpl" "$svc"
  grep -q '^Type=oneshot' "$svc"
  grep -q '^User=op' "$svc"
  grep -q "ExecStart=$WS/scripts/local/agent-wiki-graph.sh" "$svc"
}

@test "timer unit: OnCalendar from the schedule, wired to the service" {
  local tmr="$TMP_TEST_DIR/wg.timer"
  render_to_file "$REPO_ROOT/modules/local-wiki-graph.timer.tpl" "$tmr"
  grep -q '^OnCalendar=\*-\*-\* 0/6:20:00' "$tmr"
  grep -q '^Unit=agent-locbot-wiki-graph.service' "$tmr"
  grep -q '^WantedBy=timers.target' "$tmr"
}
