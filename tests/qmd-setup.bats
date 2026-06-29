#!/usr/bin/env bats
# US1 (010-self-managing-rag): qmd_setup_if_needed downloads model + builds the
# initial index at first boot, idempotently and fail-silent. Host-side, no
# Docker — `bunx` is stubbed; the stub fakes index.sqlite on `collection add`.

load helper

setup() {
  setup_tmp_dir
  export HOME="$TMP_TEST_DIR/home"; mkdir -p "$HOME"
  export QMD_CACHE_HOME="$TMP_TEST_DIR/cache/qmd"
  export QMD_VAULT_DIR="$TMP_TEST_DIR/vault"; mkdir -p "$QMD_VAULT_DIR"
  printf '# note\nhello\n' > "$QMD_VAULT_DIR/a.md"
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
case "\$2" in collection) mkdir -p "$QMD_CACHE_HOME"; : > "$QMD_CACHE_HOME/index.sqlite" ;; esac
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

@test "qmd_setup_if_needed runs collection add + update + embed and writes the sentinel" {
  _install_bunx
  run qmd_setup_if_needed "$AGENT_YML"
  [ "$status" -eq 0 ]
  grep -q "collection add" "$QMD_STUB_LOG"
  grep -q "update" "$QMD_STUB_LOG"
  grep -q "embed" "$QMD_STUB_LOG"
  [ -f "$QMD_CACHE_HOME/.qmd-setup-ok" ]
  [ -f "$QMD_CACHE_HOME/index.sqlite" ]
}

@test "qmd_setup_if_needed is a no-op when sentinel + index already present" {
  _install_bunx
  qmd_setup_if_needed "$AGENT_YML"
  : > "$QMD_STUB_LOG"
  run qmd_setup_if_needed "$AGENT_YML"
  [ "$status" -eq 0 ]
  [ ! -s "$QMD_STUB_LOG" ]
}

@test "qmd_setup_if_needed no-ops when vault.qmd.enabled=false" {
  _install_bunx
  yq -i '.vault.qmd.enabled = false' "$AGENT_YML"
  run qmd_setup_if_needed "$AGENT_YML"
  [ "$status" -eq 0 ]
  [ ! -s "$QMD_STUB_LOG" ]
}

@test "qmd_setup_if_needed no-ops when vault.enabled=false even if qmd.enabled=true" {
  # _qmd_enabled requires BOTH flags — QMD without a vault is meaningless and
  # would otherwise churn a watcher with no vault dir (contracts/qmd-cli.md:21).
  _install_bunx
  yq -i '.vault.enabled = false' "$AGENT_YML"
  run qmd_setup_if_needed "$AGENT_YML"
  [ "$status" -eq 0 ]
  [ ! -s "$QMD_STUB_LOG" ]
}

@test "qmd_setup_if_needed refreshes (update + embed, no re-add) when sentinel missing though index present" {
  _install_bunx
  mkdir -p "$QMD_CACHE_HOME"; : > "$QMD_CACHE_HOME/index.sqlite"
  run qmd_setup_if_needed "$AGENT_YML"
  [ "$status" -eq 0 ]
  # Collection already exists (index present) → skip re-add; update+embed only.
  grep -q "update" "$QMD_STUB_LOG"
  grep -q "embed" "$QMD_STUB_LOG"
  ! grep -q "collection add" "$QMD_STUB_LOG"
  [ -f "$QMD_CACHE_HOME/.qmd-setup-ok" ]
}

@test "qmd_setup_if_needed is fail-silent and writes no sentinel on bunx failure" {
  _install_bunx_fail
  run qmd_setup_if_needed "$AGENT_YML"
  [ "$status" -eq 0 ]
  [ ! -f "$QMD_CACHE_HOME/.qmd-setup-ok" ]
}
