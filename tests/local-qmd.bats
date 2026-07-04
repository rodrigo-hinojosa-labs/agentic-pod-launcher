#!/usr/bin/env bats
# 012-local-vault-rag (US2, FR-004/005/006): the local QMD pipeline — reindex
# entrypoint (self-healing double hook), reindex timer/service, and inotify
# watcher unit. Host-runnable: the entrypoint sources a STUB qmd_index.sh so we
# test the wiring (env + call sequence + --setup-only), not the lib internals
# (those are covered by qmd-setup.bats / qmd-index.bats). Units are asserted from
# their rendered text.

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
vault: {enabled: true, seed_skeleton: true, path: .state/.vault, qmd: {enabled: true, version: "2.5.3", schedule: "*/5 * * * *"}}
YML
  render_load_context "$TMP_TEST_DIR/agent.yml" >/dev/null
  export DEPLOYMENT_WORKSPACE="$WS"
  export AGENT_NAME=locbot
  export OPERATOR_USER=op
  export LOCAL_VAULT_DIR="$WS/.state/.vault"
  export QMD_TIMER_ONCALENDAR="*-*-* *:0/5:00"

  # Stub qmd_index.sh: record which fn ran + the env the entrypoint set.
  cat > "$WS/scripts/lib/qmd_index.sh" << 'SH'
qmd_setup_if_needed() { echo "setup|$QMD_CACHE_HOME|$QMD_VAULT_DIR|$QMD_INDEX_STATE_FILE|$VAULT_ROOT_OVERRIDE" >> "$QMD_TEST_LOG"; }
qmd_reindex() { echo "reindex|$1" >> "$QMD_TEST_LOG"; }
SH
  export QMD_TEST_LOG="$TMP_TEST_DIR/qmd.log"

  ENTRY="$WS/scripts/local/agent-qmd-reindex.sh"
  render_to_file "$REPO_ROOT/modules/local-qmd-reindex.sh.tpl" "$ENTRY"; chmod +x "$ENTRY"
  WATCH="$WS/scripts/local/agent-qmd-watch.sh"
  render_to_file "$REPO_ROOT/modules/local-qmd-watch.sh.tpl" "$WATCH"; chmod +x "$WATCH"
}

teardown() { teardown_tmp_dir; }

@test "entrypoint --setup-only: runs setup only, not reindex, exits 0" {
  run "$WS/scripts/local/agent-qmd-reindex.sh" --setup-only
  [ "$status" -eq 0 ]
  grep -q '^setup|' "$QMD_TEST_LOG"
  ! grep -q '^reindex|' "$QMD_TEST_LOG"
}

@test "entrypoint (timer path): runs setup-if-needed THEN reindex, exits 0" {
  run "$WS/scripts/local/agent-qmd-reindex.sh"
  [ "$status" -eq 0 ]
  # order: setup line before reindex line
  local setup_ln reindex_ln
  setup_ln=$(grep -n '^setup|' "$QMD_TEST_LOG" | head -1 | cut -d: -f1)
  reindex_ln=$(grep -n '^reindex|' "$QMD_TEST_LOG" | head -1 | cut -d: -f1)
  [ -n "$setup_ln" ] && [ -n "$reindex_ln" ] && [ "$setup_ln" -lt "$reindex_ln" ]
}

@test "entrypoint bakes workspace-durable QMD env (cache under .state, no /home/agent)" {
  "$WS/scripts/local/agent-qmd-reindex.sh" --setup-only
  local line; line=$(grep '^setup|' "$QMD_TEST_LOG" | head -1)
  echo "$line" | grep -q "|$WS/.state/.cache/qmd|"
  echo "$line" | grep -q "|$WS/.state/.vault|"
  echo "$line" | grep -q "|$WS/scripts/heartbeat/qmd-index.json|"
  ! echo "$line" | grep -q '/home/agent'
}

@test "entrypoint creates the cache + state dirs" {
  "$WS/scripts/local/agent-qmd-reindex.sh" --setup-only
  [ -d "$WS/.state/.cache/qmd" ]
  [ -d "$WS/scripts/heartbeat" ]
}

@test "reindex timer: OnCalendar comes from QMD_TIMER_ONCALENDAR, Persistent" {
  render_to_file "$REPO_ROOT/modules/local-qmd-reindex.timer.tpl" "$TMP_TEST_DIR/timer"
  grep -q '^OnCalendar=\*-\*-\* \*:0/5:00$' "$TMP_TEST_DIR/timer"
  grep -q '^Persistent=true$' "$TMP_TEST_DIR/timer"
  grep -q '^Unit=agent-locbot-qmd-reindex.service$' "$TMP_TEST_DIR/timer"
}

@test "reindex service: oneshot, runs the entrypoint as the operator" {
  render_to_file "$REPO_ROOT/modules/local-qmd-reindex.service.tpl" "$TMP_TEST_DIR/svc"
  grep -q '^Type=oneshot$' "$TMP_TEST_DIR/svc"
  grep -q '^User=op$' "$TMP_TEST_DIR/svc"
  grep -q "^ExecStart=$WS/scripts/local/agent-qmd-reindex.sh$" "$TMP_TEST_DIR/svc"
}

@test "watch service: ExecCondition on inotifywait + Restart=always (C1 degradation)" {
  render_to_file "$REPO_ROOT/modules/local-qmd-watch.service.tpl" "$TMP_TEST_DIR/watch-svc"
  grep -q "^ExecCondition=/bin/sh -c 'command -v inotifywait'$" "$TMP_TEST_DIR/watch-svc"
  grep -q '^Restart=always$' "$TMP_TEST_DIR/watch-svc"
  grep -q '^RestartSec=2$' "$TMP_TEST_DIR/watch-svc"
  grep -q "^ExecStart=$WS/scripts/local/agent-qmd-watch.sh$" "$TMP_TEST_DIR/watch-svc"
}

@test "watch wrapper: wires QMD_REINDEX_CMD to the local entrypoint + agent.yml" {
  local w="$WS/scripts/local/agent-qmd-watch.sh"
  # WORKSPACE is rendered to the concrete path; the rest reference shell vars.
  grep -q "^WORKSPACE=\"$WS\"$" "$w"
  grep -q 'QMD_REINDEX_CMD="${SCRIPT_DIR}/agent-qmd-reindex.sh"' "$w"
  grep -q 'QMD_WATCH_AGENT_YML="${WORKSPACE}/agent.yml"' "$w"
  grep -q 'exec bash "${WORKSPACE}/scripts/qmd_watch.sh"' "$w"
}
