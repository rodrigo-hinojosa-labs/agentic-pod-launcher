#!/usr/bin/env bats
# US1/US2 (010-self-managing-rag): the supervisor starts the QMD inotify watcher
# only when enabled, and respawns it on a deterministic PID-liveness check.
# Host-side, no Docker — start_services.sh is sourced with START_SERVICES_NO_RUN.

load helper

setup() {
  setup_tmp_dir
  export START_SERVICES_NO_RUN=1
  export HOME="$TMP_TEST_DIR/home"; mkdir -p "$HOME"
  export QMD_WATCH_PIDFILE="$TMP_TEST_DIR/qmd-watch.pid"
  export QMD_WATCH_SCRIPT="$TMP_TEST_DIR/qmd_watch_stub.sh"
  cat > "$QMD_WATCH_SCRIPT" <<'EOF'
#!/bin/sh
sleep 30
EOF
  chmod +x "$QMD_WATCH_SCRIPT"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/docker/scripts/start_services.sh"
}

teardown() {
  if [ -f "$QMD_WATCH_PIDFILE" ]; then
    kill "$(cat "$QMD_WATCH_PIDFILE" 2>/dev/null)" 2>/dev/null || true
  fi
  teardown_tmp_dir
}

@test "qmd_watch_start is a no-op when qmd is disabled" {
  _qmd_enabled() { return 1; }
  run qmd_watch_start
  [ "$status" -eq 0 ]
  [ ! -f "$QMD_WATCH_PIDFILE" ]
}

@test "qmd_watch_start launches the watcher and writes a live pidfile when enabled" {
  _qmd_enabled() { return 0; }
  qmd_watch_start
  [ -f "$QMD_WATCH_PIDFILE" ]
  local pid; pid=$(cat "$QMD_WATCH_PIDFILE")
  kill -0 "$pid"
}

@test "qmd_watch_respawn_if_needed restarts a dead watcher when enabled" {
  _qmd_enabled() { return 0; }
  echo 999999 > "$QMD_WATCH_PIDFILE"
  qmd_watch_respawn_if_needed
  local pid; pid=$(cat "$QMD_WATCH_PIDFILE")
  [ "$pid" != "999999" ]
  kill -0 "$pid"
}

@test "qmd_watch_respawn_if_needed leaves the pidfile untouched when disabled" {
  _qmd_enabled() { return 1; }
  echo 999999 > "$QMD_WATCH_PIDFILE"
  run qmd_watch_respawn_if_needed
  [ "$status" -eq 0 ]
  [ "$(cat "$QMD_WATCH_PIDFILE")" = "999999" ]
}
