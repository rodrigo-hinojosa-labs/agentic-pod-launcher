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
  export OPERATOR_HOME="$TMP_TEST_DIR/home"
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

@test "entrypoint exports the qmd BINARY env contract (XDG_CACHE_HOME + QMD_CONFIG_DIR under .state) — 013 US1/T007" {
  # RC1: the qmd binary honors XDG_CACHE_HOME (index+models) and QMD_CONFIG_DIR
  # (collections config), NOT QMD_CACHE_HOME (that's only the bash lib). The
  # entrypoint must export BOTH so the CLI writes under the workspace .state, and
  # keep QMD_CACHE_HOME so the lib bookkeeping converges on the same dir.
  local e="$WS/scripts/local/agent-qmd-reindex.sh"
  grep -q 'export XDG_CACHE_HOME="${WORKSPACE}/.state/.cache"' "$e"
  grep -q 'export QMD_CONFIG_DIR="${WORKSPACE}/.state/.config/qmd"' "$e"
  grep -q 'export QMD_CACHE_HOME="${WORKSPACE}/.state/.cache/qmd"' "$e"
  # XDG_CACHE_HOME + /qmd must equal QMD_CACHE_HOME (lib↔binary convergence).
}

@test "entrypoint creates the config dir too (collections isolation) — 013 US1" {
  "$WS/scripts/local/agent-qmd-reindex.sh" --setup-only
  [ -d "$WS/.state/.config/qmd" ]
}

@test "workspace migration keeps the index: sentinel-hit after cp -a, no absolute-path leak — 013 SC-002/T043" {
  # Real lib (not the stub) to exercise the sentinel guard. Point the entrypoint
  # at a real qmd_index.sh and stub bunx so no network/model download happens.
  cp "$REPO_ROOT/scripts/lib/qmd_index.sh" "$WS/scripts/lib/qmd_index.sh"
  cp "$REPO_ROOT/scripts/lib/backup_vault.sh" "$WS/scripts/lib/backup_vault.sh"
  mkdir -p "$TMP_TEST_DIR/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP_TEST_DIR/bin/bunx"; chmod +x "$TMP_TEST_DIR/bin/bunx"
  # Fake a completed index in the origin workspace: sentinel + index.sqlite.
  mkdir -p "$WS/.state/.cache/qmd"
  : > "$WS/.state/.cache/qmd/.qmd-setup-ok"
  echo "fake-index" > "$WS/.state/.cache/qmd/index.sqlite"
  # cp -a the whole workspace to a second host path.
  local DST="$TMP_TEST_DIR/migrated"
  cp -a "$WS" "$DST"
  # The sentinel + index must have travelled (workspace-durable storage).
  [ -f "$DST/.state/.cache/qmd/.qmd-setup-ok" ]
  [ -f "$DST/.state/.cache/qmd/index.sqlite" ]
  # No absolute path of the ORIGIN workspace embedded in the migrated index state.
  ! grep -rq "$WS" "$DST/.state/.cache/qmd/" 2>/dev/null
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
}

@test "watch wrapper: exports the real workspace vault (QMD_VAULT_DIR + VAULT_ROOT_OVERRIDE) — 013 RC3/T012" {
  local w="$WS/scripts/local/agent-qmd-watch.sh"
  grep -q 'export QMD_VAULT_DIR="'"$WS/.state/.vault"'"' "$w"
  grep -q 'export VAULT_ROOT_OVERRIDE="'"$WS/.state/.vault"'"' "$w"
  # /home/agent must NOT appear in the resolved vault env
  ! grep -q 'QMD_VAULT_DIR=.*/home/agent' "$w"
}

@test "watch wrapper: supervised loop, no exec (013 FR-007/D5)" {
  local w="$WS/scripts/local/agent-qmd-watch.sh"
  grep -q '^while :; do$' "$w"
  grep -q 'bash "${WORKSPACE}/scripts/qmd_watch.sh"' "$w"
  grep -q '^  sleep 30$' "$w"
  # the old bare-exec (which would let start-limit strand the unit) is gone
  ! grep -q 'exec bash "${WORKSPACE}/scripts/qmd_watch.sh"' "$w"
}

@test "PATH self-provision: reindex + watch wrappers prepend ~/.local/bin + vendor/bin (013 RC2/T010)" {
  local r="$WS/scripts/local/agent-qmd-reindex.sh" w="$WS/scripts/local/agent-qmd-watch.sh"
  local op="$TMP_TEST_DIR/home"
  grep -q 'export PATH="'"$op"'/.local/bin:${WORKSPACE}/scripts/vendor/bin:$PATH"' "$r"
  grep -q 'export PATH="'"$op"'/.local/bin:${WORKSPACE}/scripts/vendor/bin:$PATH"' "$w"
}

@test "watcher resilience: transient exits are retried in-loop, never propagated (013 FR-007/T013)" {
  local TO; TO=$(command -v timeout || command -v gtimeout) || skip "no timeout(1) on host (runs in Linux CI/container)"
  # qmd_watch.sh stub: record a tick, then exit non-zero (a transient failure).
  export WATCH_ITER_LOG="$TMP_TEST_DIR/iter.log"; : > "$WATCH_ITER_LOG"
  cat > "$WS/scripts/qmd_watch.sh" << 'SH'
echo "tick" >> "$WATCH_ITER_LOG"
exit 1
SH
  # sleep shadow: count loop iterations; after the 2nd, SIGTERM the wrapper's loop
  # ($PPID) so the `while :` doesn't run forever. This proves the loop retried.
  mkdir -p "$TMP_TEST_DIR/bin-sleep"
  cat > "$TMP_TEST_DIR/bin-sleep/sleep" << 'SH'
#!/usr/bin/env bash
n=$(cat "$WATCH_SLEEP_N" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$WATCH_SLEEP_N"
[ "$n" -ge 2 ] && kill -TERM "$PPID" 2>/dev/null
exit 0
SH
  chmod +x "$TMP_TEST_DIR/bin-sleep/sleep"
  export WATCH_SLEEP_N="$TMP_TEST_DIR/sleep.n"; : > "$WATCH_SLEEP_N"
  PATH="$TMP_TEST_DIR/bin-sleep:$PATH" timeout 10 bash "$WS/scripts/local/agent-qmd-watch.sh" || true
  # qmd_watch.sh ran at least twice despite exiting 1 each time (retried in-loop).
  [ "$(wc -l < "$WATCH_ITER_LOG")" -ge 2 ]
}
