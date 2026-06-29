#!/usr/bin/env bats
# US2 (010-self-managing-rag): qmd_reindex is hash-debounced (skips embed when
# the vault is unchanged), runs update+embed when it changed, and is
# flock-guarded against concurrent runs. Host-side, no Docker — `bunx` stubbed.

load helper

setup() {
  setup_tmp_dir
  export HOME="$TMP_TEST_DIR/home"; mkdir -p "$HOME"
  export QMD_CACHE_HOME="$TMP_TEST_DIR/cache/qmd"; mkdir -p "$QMD_CACHE_HOME"
  export QMD_VAULT_DIR="$TMP_TEST_DIR/vault"; mkdir -p "$QMD_VAULT_DIR"
  printf '# note\nhello\n' > "$QMD_VAULT_DIR/a.md"
  export QMD_INDEX_STATE_FILE="$TMP_TEST_DIR/qmd-index.json"
  export QMD_STUB_LOG="$TMP_TEST_DIR/bunx.log"; : > "$QMD_STUB_LOG"
  mkdir -p "$TMP_TEST_DIR/bin"
  AGENT_YML="$TMP_TEST_DIR/agent.yml"
  cat > "$AGENT_YML" <<YAML
vault:
  enabled: true
  qmd:
    enabled: true
    version: "2.5.3"
YAML
  # shellcheck source=/dev/null
  source "$REPO_ROOT/docker/scripts/lib/qmd_index.sh"
}

teardown() { teardown_tmp_dir; }

_install_bunx() {
  cat > "$TMP_TEST_DIR/bin/bunx" <<EOF
#!/bin/sh
echo "\$@" >> "$QMD_STUB_LOG"
exit 0
EOF
  chmod +x "$TMP_TEST_DIR/bin/bunx"
  export PATH="$TMP_TEST_DIR/bin:$PATH"
}

_install_bunx_fail() {
  cat > "$TMP_TEST_DIR/bin/bunx" <<EOF
#!/bin/sh
echo "\$@" >> "$QMD_STUB_LOG"
exit 1
EOF
  chmod +x "$TMP_TEST_DIR/bin/bunx"
  export PATH="$TMP_TEST_DIR/bin:$PATH"
}

@test "qmd_reindex skips embed when the vault is unchanged" {
  _install_bunx
  local h; h=$(vault_hash "$QMD_VAULT_DIR")
  qmd_write_state "$QMD_INDEX_STATE_FILE" "$h" "indexed"
  : > "$QMD_STUB_LOG"
  run qmd_reindex "$AGENT_YML"
  [ "$status" -eq 0 ]
  [ ! -s "$QMD_STUB_LOG" ]
  run jq -r '.last_status' "$QMD_INDEX_STATE_FILE"
  [ "$output" = "skipped" ]
}

@test "qmd_reindex runs update+embed and records indexed when the vault changed" {
  _install_bunx
  qmd_write_state "$QMD_INDEX_STATE_FILE" "STALEHASH" "indexed"
  : > "$QMD_STUB_LOG"
  run qmd_reindex "$AGENT_YML"
  [ "$status" -eq 0 ]
  grep -q "update" "$QMD_STUB_LOG"
  grep -q "embed" "$QMD_STUB_LOG"
  run jq -r '.last_status' "$QMD_INDEX_STATE_FILE"
  [ "$output" = "indexed" ]
  run jq -r '.hash' "$QMD_INDEX_STATE_FILE"
  [ "$output" != "STALEHASH" ]
}

@test "qmd_reindex increments runs and writes a well-formed state file" {
  _install_bunx
  run qmd_reindex "$AGENT_YML"
  [ "$status" -eq 0 ]
  run jq -r '.runs' "$QMD_INDEX_STATE_FILE"
  [ "$output" = "1" ]
  run jq -e '.hash and .last_run and .last_status and (.runs|type=="number")' "$QMD_INDEX_STATE_FILE"
  [ "$status" -eq 0 ]
}

@test "qmd_reindex records last_status=error and preserves the prior hash on bunx failure" {
  _install_bunx_fail
  qmd_write_state "$QMD_INDEX_STATE_FILE" "STALEHASH" "indexed"
  : > "$QMD_STUB_LOG"
  run qmd_reindex "$AGENT_YML"
  [ "$status" -eq 0 ]
  # update (or embed) failed → state must record the failure and keep the old
  # hash so the next tick retries (it doesn't mark the vault as indexed).
  run jq -r '.last_status' "$QMD_INDEX_STATE_FILE"
  [ "$output" = "error" ]
  run jq -r '.hash' "$QMD_INDEX_STATE_FILE"
  [ "$output" = "STALEHASH" ]
}

@test "qmd_reindex is a no-op when vault.qmd.enabled=false" {
  _install_bunx
  yq -i '.vault.qmd.enabled = false' "$AGENT_YML"
  : > "$QMD_STUB_LOG"
  run qmd_reindex "$AGENT_YML"
  [ "$status" -eq 0 ]
  [ ! -s "$QMD_STUB_LOG" ]
}

# FR-007 concurrency guard. flock is absent on macOS dev hosts (this test then
# reports `# skip`), so the lock path is exercised only where flock exists:
# Linux CI (.github/workflows) and the Alpine container (production). A local
# `ok ... # skip` here is NOT concurrency coverage — that lives in CI/e2e.
@test "qmd_reindex skips when the reindex lock is already held" {
  command -v flock >/dev/null 2>&1 || skip "flock not available on host (covered in Linux CI + container)"
  _install_bunx
  qmd_write_state "$QMD_INDEX_STATE_FILE" "STALEHASH" "indexed"
  flock -x "$QMD_CACHE_HOME/.reindex.lock" -c "sleep 5" &
  local holder=$!
  sleep 0.3
  : > "$QMD_STUB_LOG"
  run qmd_reindex "$AGENT_YML"
  kill "$holder" 2>/dev/null || true
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "already running"
  [ ! -s "$QMD_STUB_LOG" ]
}
