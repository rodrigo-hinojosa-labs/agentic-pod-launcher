#!/usr/bin/env bats
# 011-local-standalone-mode (US3): agentctl degrades honestly in local mode.
# Docker-only subcommands must fail with a systemctl hint and NEVER invoke
# docker; status/doctor must read systemd (stubbed) instead of the container.

load helper

setup() {
  setup_tmp_dir
  cp -r "$REPO_ROOT/scripts" "$TMP_TEST_DIR/"
  cat > "$TMP_TEST_DIR/agent.yml" << 'YML'
version: 1
agent:
  name: locbot
user: {timezone: UTC, email: a@b.com}
deployment:
  workspace: "."
  mode: local
docker: {uid: 1000, gid: 1000, image_tag: "x:latest", base_image: "alpine:3.20"}
notifications: {channel: none}
features: {heartbeat: {enabled: true, interval: "30m", timeout: 300, retries: 1, default_prompt: "ok"}}
YML
  # Stub bin: docker writes a marker if ever called (it must NOT be in local mode).
  mkdir -p "$TMP_TEST_DIR/bin"
  export DOCKER_MARKER="$TMP_TEST_DIR/docker-was-called"
  cat > "$TMP_TEST_DIR/bin/docker" << 'SH'
#!/usr/bin/env bash
echo "called: $*" >> "$DOCKER_MARKER"
exit 0
SH
  cat > "$TMP_TEST_DIR/bin/systemctl" << 'SH'
#!/usr/bin/env bash
# is-active --quiet → active (0). is-failed --quiet → NOT failed (1) by default,
# unless SYSTEMCTL_WATCH_FAILED is set (a test simulating a failed watcher).
case "$*" in
  *is-active*) exit 0 ;;
  *is-failed*qmd-watch*) [ "${SYSTEMCTL_WATCH_FAILED:-0}" = 1 ] && exit 0 || exit 1 ;;
  *is-failed*) exit 1 ;;
  *) exit 0 ;;
esac
SH
  cat > "$TMP_TEST_DIR/bin/journalctl" << 'SH'
#!/usr/bin/env bash
echo "session url: https://claude.ai/code/abc connected"
exit 0
SH
  cat > "$TMP_TEST_DIR/bin/claude" << 'SH'
#!/usr/bin/env bash
case "$*" in
  *--version*) echo "2.1.99 (Claude Code)" ;;
esac
exit 0
SH
  chmod +x "$TMP_TEST_DIR/bin/"*
  export PATH="$TMP_TEST_DIR/bin:$PATH"
  # A present login so status/doctor see it.
  mkdir -p "$TMP_TEST_DIR/.state/.claude"
  printf '{"expiresAt":99999999999999}\n' > "$TMP_TEST_DIR/.state/.claude/.credentials.json"
  chmod 600 "$TMP_TEST_DIR/.state/.claude/.credentials.json"
}

teardown() { teardown_tmp_dir; }

@test "local mode: 'up' errors with a systemctl hint and never calls docker" {
  cd "$TMP_TEST_DIR"
  run ./scripts/agentctl up
  [ "$status" -ne 0 ]
  [[ "$output" == *"systemctl"* ]]
  [[ "$output" == *"local"* ]]
  [ ! -f "$DOCKER_MARKER" ]
}

@test "local mode: 'attach' and 'logs' also degrade without docker" {
  cd "$TMP_TEST_DIR"
  run ./scripts/agentctl attach
  [ "$status" -ne 0 ]
  [[ "$output" == *"journalctl"* || "$output" == *"systemctl"* ]]
  run ./scripts/agentctl logs -f
  [ "$status" -ne 0 ]
  [ ! -f "$DOCKER_MARKER" ]
}

@test "local mode: 'status' reads systemd (stub), not docker" {
  cd "$TMP_TEST_DIR"
  run ./scripts/agentctl status
  [ "$status" -eq 0 ]
  [[ "$output" == *"active"* ]]
  [ ! -f "$DOCKER_MARKER" ]
}

@test "local mode: 'doctor' uses systemctl + login checks, not docker" {
  cd "$TMP_TEST_DIR"
  run ./scripts/agentctl doctor
  [[ "$output" == *"local mode"* ]]
  [[ "$output" == *"active"* ]]
  [ ! -f "$DOCKER_MARKER" ]
}

@test "local status: reports vault/RAG units + index when qmd is present (012 FR-013)" {
  cd "$TMP_TEST_DIR"
  mkdir -p scripts/local .state/.cache/qmd
  : > scripts/local/agent-qmd-reindex.sh
  : > scripts/local/agent-vault-backup.sh
  : > .state/.cache/qmd/index.sqlite
  run ./scripts/agentctl status
  [ "$status" -eq 0 ]
  [[ "$output" == *"vault/RAG"* ]]
  [[ "$output" == *"qmd reindex timer"* ]]
  [[ "$output" == *"qmd index"* ]]
  [[ "$output" == *"present"* ]]
  [[ "$output" == *"vault backup timer"* ]]
}

@test "local status: NO vault/RAG block when qmd/backup absent (FR-010/FR-013)" {
  cd "$TMP_TEST_DIR"
  run ./scripts/agentctl status
  [ "$status" -eq 0 ]
  ! [[ "$output" == *"vault/RAG"* ]]
}

@test "local doctor: reports QMD index + last reindex + backup freshness from state files (FR-013)" {
  cd "$TMP_TEST_DIR"
  mkdir -p scripts/local scripts/heartbeat .state/.cache/qmd
  : > scripts/local/agent-qmd-reindex.sh
  : > scripts/local/agent-vault-backup.sh
  : > .state/.cache/qmd/index.sqlite
  printf '{"last_run":"2026-07-04T10:00:00Z","last_status":"indexed"}\n' > scripts/heartbeat/qmd-index.json
  printf '{"last_push":"2026-07-04T09:00:00Z","last_commit":"abc123"}\n' > scripts/heartbeat/vault-backup.json
  run ./scripts/agentctl doctor
  [[ "$output" == *"QMD index present"* ]]
  [[ "$output" == *"QMD last reindex: 2026-07-04T10:00:00Z"* ]]
  # 013: backup is reported via the shared freshness check (label "Backup vault").
  [[ "$output" == *"Backup vault"* ]]
}

@test "local doctor: last_status=error degrades to warn with exit 1 (013 FR-009/SC-005)" {
  cd "$TMP_TEST_DIR"
  mkdir -p scripts/local scripts/heartbeat .state/.cache/qmd
  : > scripts/local/agent-qmd-reindex.sh
  : > .state/.cache/qmd/index.sqlite
  printf '{"last_run":"2026-07-05T10:00:00Z","last_status":"error"}\n' > scripts/heartbeat/qmd-index.json
  run ./scripts/agentctl doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"errored"* ]]
  # must NOT report a false ✓ for the reindex
  ! [[ "$output" == *"QMD last reindex: 2026-07-05T10:00:00Z (error)"*"✓"* ]]
}

@test "local doctor: a failed qmd-watch unit warns with exit 1, never a false pass (013 FR-011/SC-005)" {
  cd "$TMP_TEST_DIR"
  mkdir -p scripts/local .state/.cache/qmd
  : > scripts/local/agent-qmd-reindex.sh
  : > .state/.cache/qmd/index.sqlite
  SYSTEMCTL_WATCH_FAILED=1 run ./scripts/agentctl doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"watcher"* && "$output" == *"failed"* ]]
}

@test "local doctor: stale vault backup (>25h) warns with exit 1 (013 FR-009)" {
  cd "$TMP_TEST_DIR"
  mkdir -p scripts/local scripts/heartbeat
  : > scripts/local/agent-vault-backup.sh
  printf '{"last_push":"2026-06-01T00:00:00Z"}\n' > scripts/heartbeat/vault-backup.json
  run ./scripts/agentctl doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"Backup vault"* && "$output" == *"stale"* ]]
}

@test "local doctor: all-sane exits 0 (013 FR-009)" {
  cd "$TMP_TEST_DIR"
  # no qmd/backup artifacts → no vault/RAG checks; unit active + login present.
  run ./scripts/agentctl doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"Local checks passed"* ]]
}

@test "local status: shows last_run freshness + schedule fallback marker (013 FR-013)" {
  cd "$TMP_TEST_DIR"
  mkdir -p scripts/local scripts/heartbeat .state/.cache/qmd
  : > scripts/local/agent-qmd-reindex.sh
  : > .state/.cache/qmd/index.sqlite
  printf '{"last_run":"2026-07-05T12:00:00Z","last_status":"indexed"}\n' > scripts/heartbeat/qmd-index.json
  printf 'original=*/10 8-20 * * *\napplied=*-*-* *:0/5:00\n' > scripts/heartbeat/qmd-schedule.fallback
  run ./scripts/agentctl status
  [ "$status" -eq 0 ]
  [[ "$output" == *"qmd last reindex"* && "$output" == *"2026-07-05T12:00:00Z"* ]]
  [[ "$output" == *"fallback"* ]]
}

@test "local heartbeat qmd-reindex: runs the workspace entrypoint, not a Docker error (013 FR-010/T022)" {
  cd "$TMP_TEST_DIR"
  mkdir -p scripts/local
  cat > scripts/local/agent-qmd-reindex.sh << 'SH'
#!/usr/bin/env bash
echo "REINDEX_RAN args=$*" >> "$TMP_TEST_DIR/reindex.log"
SH
  chmod +x scripts/local/agent-qmd-reindex.sh
  export TMP_TEST_DIR
  run ./scripts/agentctl heartbeat qmd-reindex
  [ "$status" -eq 0 ]
  ! [[ "$output" == *"Docker-mode command"* ]]
  grep -q "REINDEX_RAN" "$TMP_TEST_DIR/reindex.log"
}

@test "local heartbeat qmd-reindex --dry-run: refused, never runs a real reindex (013 D8/T022)" {
  cd "$TMP_TEST_DIR"
  mkdir -p scripts/local
  cat > scripts/local/agent-qmd-reindex.sh << 'SH'
#!/usr/bin/env bash
echo "REINDEX_RAN" >> "$TMP_TEST_DIR/reindex.log"
SH
  chmod +x scripts/local/agent-qmd-reindex.sh
  export TMP_TEST_DIR
  run ./scripts/agentctl heartbeat qmd-reindex --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not support --dry-run"* ]]
  [ ! -f "$TMP_TEST_DIR/reindex.log" ]
}

@test "local heartbeat backup-vault --dry-run: runs the entrypoint with the flag (013 FR-010/T022)" {
  cd "$TMP_TEST_DIR"
  mkdir -p scripts/local
  cat > scripts/local/agent-vault-backup.sh << 'SH'
#!/usr/bin/env bash
echo "BACKUP_RAN args=$*" >> "$TMP_TEST_DIR/backup.log"
SH
  chmod +x scripts/local/agent-vault-backup.sh
  export TMP_TEST_DIR
  run ./scripts/agentctl heartbeat backup-vault --dry-run
  [ "$status" -eq 0 ]
  grep -q "BACKUP_RAN args=--dry-run" "$TMP_TEST_DIR/backup.log"
}

@test "local heartbeat kick-channel (no local equivalent): still degrades as Docker-only (013 FR-010)" {
  cd "$TMP_TEST_DIR"
  run ./scripts/agentctl heartbeat kick-channel
  [ "$status" -ne 0 ]
  [[ "$output" == *"Docker-mode command"* || "$output" == *"systemctl"* ]]
  [ ! -f "$DOCKER_MARKER" ]
}
