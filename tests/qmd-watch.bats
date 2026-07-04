#!/usr/bin/env bats
# US2 (010-self-managing-rag): qmd_watch.sh debounces a burst of inotify events
# into a single reindex, and degrades cleanly when inotifywait is unavailable.
# Host-side, no Docker — inotifywait + the reindex command are stubbed.

load helper

WATCH="$BATS_TEST_DIRNAME/../scripts/qmd_watch.sh"

setup() {
  setup_tmp_dir
  export HOME="$TMP_TEST_DIR/home"; mkdir -p "$HOME"
  export QMD_VAULT_DIR="$TMP_TEST_DIR/vault"; mkdir -p "$QMD_VAULT_DIR"
  export QMD_WATCH_AGENT_YML="$TMP_TEST_DIR/agent.yml"
  cat > "$QMD_WATCH_AGENT_YML" <<YAML
vault:
  enabled: true
  qmd:
    enabled: true
YAML
  export QMD_WATCH_DEBOUNCE=2
  export QMD_WATCH_ERROR_BACKOFF=0   # don't sleep on stream-end during tests
  export COUNT_FILE="$TMP_TEST_DIR/count"; : > "$COUNT_FILE"
  mkdir -p "$TMP_TEST_DIR/bin"
  # counting reindex command
  cat > "$TMP_TEST_DIR/bin/countreindex" <<EOF
#!/bin/sh
echo x >> "$COUNT_FILE"
EOF
  chmod +x "$TMP_TEST_DIR/bin/countreindex"
  export QMD_REINDEX_CMD="$TMP_TEST_DIR/bin/countreindex"
}

teardown() { teardown_tmp_dir; }

_install_inotifywait_burst() {
  # Emits a burst of events then exits (EOF) — the watcher should flush exactly
  # one reindex.
  cat > "$TMP_TEST_DIR/bin/inotifywait" <<'EOF'
#!/bin/sh
i=0
while [ "$i" -lt 20 ]; do echo "$PWD MODIFY note$i.md"; i=$((i + 1)); done
exit 0
EOF
  chmod +x "$TMP_TEST_DIR/bin/inotifywait"
  export QMD_INOTIFYWAIT="$TMP_TEST_DIR/bin/inotifywait"
}

_install_inotifywait_quiet_then_exit() {
  # Emit a couple of events, then go quiet PAST the debounce window before
  # exiting — forces the read-timeout (rc>128) flush path, not the EOF path.
  # The events are emitted from a SUBSHELL whose exit flushes stdio immediately:
  # sh block-buffers a pipe, so plain echoes would otherwise reach the watcher
  # only at process exit (after the sleep) and fire the EOF path by mistake.
  cat > "$TMP_TEST_DIR/bin/inotifywait" <<'EOF'
#!/bin/sh
( echo "$PWD MODIFY note0.md"; echo "$PWD MODIFY note1.md" )
sleep 3
exit 0
EOF
  chmod +x "$TMP_TEST_DIR/bin/inotifywait"
  export QMD_INOTIFYWAIT="$TMP_TEST_DIR/bin/inotifywait"
}

@test "qmd_watch coalesces a burst of events into a single reindex" {
  _install_inotifywait_burst
  run bash "$WATCH"
  [ "$status" -eq 0 ]
  local n; n=$(wc -l < "$COUNT_FILE" | tr -d ' ')
  [ "$n" -eq 1 ]
}

@test "qmd_watch fires exactly one reindex via the debounce-quiet (timeout) path" {
  # The watcher tells a debounce timeout from EOF by read's exit code (>128 =
  # timeout). bash <4 (e.g. macOS /bin/bash 3.2) returns 1 for BOTH and cannot
  # exercise this branch; the container runs bash 5 where it works, and
  # DOCKER_E2E covers it end-to-end. Skip rather than assert a path this bash
  # can't reach — mirrors the flock skip in qmd-index.bats.
  bash -c 'sleep 3 | { IFS= read -r -t 1 _; [ "$?" -gt 128 ]; }' \
    || skip "host bash returns 1 (not >128) on read timeout — needs bash 4+ (container runs bash 5)"
  _install_inotifywait_quiet_then_exit
  run bash "$WATCH"
  [ "$status" -eq 0 ]
  local n; n=$(wc -l < "$COUNT_FILE" | tr -d ' ')
  [ "$n" -eq 1 ]
  # "change settled" is logged only on the rc>128 timeout branch (not on EOF),
  # so this proves the quiet-window path fired rather than the stream-end flush.
  echo "$output" | grep -q "change settled"
}

@test "qmd_watch degrades to exit 0 when inotifywait is unavailable" {
  export QMD_INOTIFYWAIT="$TMP_TEST_DIR/bin/does-not-exist-inotifywait"
  run bash "$WATCH"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "inotifywait unavailable"
  [ ! -s "$COUNT_FILE" ]
}

@test "qmd_watch exits 0 (no watch) when vault.qmd.enabled=false" {
  _install_inotifywait_burst
  yq -i '.vault.qmd.enabled = false' "$QMD_WATCH_AGENT_YML"
  run bash "$WATCH"
  [ "$status" -eq 0 ]
  [ ! -s "$COUNT_FILE" ]
}
