#!/usr/bin/env bats
# US1 (010-self-managing-rag): qmd_setup_if_needed downloads model + builds the
# initial index at first boot, idempotently and fail-silent. Host-side, no
# Docker.
#
# Engine seam (019, post-016 contract): _qmd_run executes
# $(_qmd_prefix)/node_modules/.bin/qmd directly — a PATH `bunx` stub is dead
# code. Tests stub via helper.bash::install_qmd_stub{,_fail} (fake engine
# binary in the managed prefix + pre-seeded .installed-hash + no-op `bun` for
# the guards); the success stub fakes index.sqlite on `collection`.
# See specs/019-fix-qmd-test-drift/contracts/qmd-test-seam.md.

load helper

setup() {
  setup_tmp_dir
  export HOME="$TMP_TEST_DIR/home"; mkdir -p "$HOME"
  export QMD_CACHE_HOME="$TMP_TEST_DIR/cache/qmd"
  export QMD_VAULT_DIR="$TMP_TEST_DIR/vault"; mkdir -p "$QMD_VAULT_DIR"
  printf '# note\nhello\n' > "$QMD_VAULT_DIR/a.md"
  export QMD_STUB_LOG="$TMP_TEST_DIR/engine.log"; : > "$QMD_STUB_LOG"
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
  source "$REPO_ROOT/scripts/lib/qmd_index.sh"
}

teardown() { teardown_tmp_dir; }

@test "qmd_setup_if_needed runs collection add + update + embed and writes the sentinel" {
  install_qmd_stub
  run qmd_setup_if_needed "$AGENT_YML"
  [ "$status" -eq 0 ]
  grep -q "collection add" "$QMD_STUB_LOG"
  grep -q "update" "$QMD_STUB_LOG"
  grep -q "embed" "$QMD_STUB_LOG"
  [ -f "$QMD_CACHE_HOME/.qmd-setup-ok" ]
  [ -f "$QMD_CACHE_HOME/index.sqlite" ]
}

@test "qmd_setup_if_needed is a no-op when sentinel + index already present" {
  install_qmd_stub
  qmd_setup_if_needed "$AGENT_YML"
  : > "$QMD_STUB_LOG"
  run qmd_setup_if_needed "$AGENT_YML"
  [ "$status" -eq 0 ]
  [ ! -s "$QMD_STUB_LOG" ]
}

@test "qmd_setup_if_needed no-ops when vault.qmd.enabled=false" {
  install_qmd_stub
  yq -i '.vault.qmd.enabled = false' "$AGENT_YML"
  run qmd_setup_if_needed "$AGENT_YML"
  [ "$status" -eq 0 ]
  [ ! -s "$QMD_STUB_LOG" ]
}

@test "qmd_setup_if_needed no-ops when vault.enabled=false even if qmd.enabled=true" {
  # _qmd_enabled requires BOTH flags — QMD without a vault is meaningless and
  # would otherwise churn a watcher with no vault dir (contracts/qmd-cli.md:21).
  install_qmd_stub
  yq -i '.vault.enabled = false' "$AGENT_YML"
  run qmd_setup_if_needed "$AGENT_YML"
  [ "$status" -eq 0 ]
  [ ! -s "$QMD_STUB_LOG" ]
}

@test "qmd_setup_if_needed refreshes (update + embed, no re-add) when sentinel missing though index present" {
  install_qmd_stub
  mkdir -p "$QMD_CACHE_HOME"; : > "$QMD_CACHE_HOME/index.sqlite"
  run qmd_setup_if_needed "$AGENT_YML"
  [ "$status" -eq 0 ]
  # Collection already exists (index present) → skip re-add; update+embed only.
  grep -q "update" "$QMD_STUB_LOG"
  grep -q "embed" "$QMD_STUB_LOG"
  if grep -q "collection add" "$QMD_STUB_LOG"; then false; fi
  [ -f "$QMD_CACHE_HOME/.qmd-setup-ok" ]
}

@test "qmd_setup_if_needed is fail-silent and writes no sentinel on engine failure" {
  install_qmd_stub_fail
  run qmd_setup_if_needed "$AGENT_YML"
  [ "$status" -eq 0 ]
  [ ! -f "$QMD_CACHE_HOME/.qmd-setup-ok" ]
}

# _install_qmd_stub_slow — seam variant for the flock test: the winner holds
# the lock long enough (sleep on `collection`) for a concurrent call to
# contend (013 FR-015).
_install_qmd_stub_slow() {
  _qmd_stub_prefix_seed "2.5.3"
  cat > "$QMD_CACHE_HOME/pkg/node_modules/.bin/qmd" <<EOF
#!/bin/sh
echo "\$@" >> "$QMD_STUB_LOG"
case "\$1" in
  collection) sleep 1; mkdir -p "$QMD_CACHE_HOME"; : > "$QMD_CACHE_HOME/index.sqlite" ;;
  embed)  echo "✓ All content hashes already have embeddings" ;;
  status) echo "Pending: 0 need embedding" ;;
esac
exit 0
EOF
  chmod +x "$QMD_CACHE_HOME/pkg/node_modules/.bin/qmd"
}

@test "qmd_setup_if_needed serializes concurrent setups under flock — only one collection add (013 FR-015/T014)" {
  command -v flock >/dev/null 2>&1 || skip "flock not available (macOS dev host)"
  _install_qmd_stub_slow
  # Two concurrent setups against a fresh cache: the flock winner runs the full
  # add→update→embed; the loser must skip (no duplicate ~300MB model / re-add).
  qmd_setup_if_needed "$AGENT_YML" &
  qmd_setup_if_needed "$AGENT_YML" &
  wait
  [ "$(grep -c 'collection add' "$QMD_STUB_LOG")" -eq 1 ]
}

@test "qmd_setup_if_needed sentinel-hit is a fast path that never reaches the lock (013 FR-015/T014)" {
  install_qmd_stub
  qmd_setup_if_needed "$AGENT_YML"          # build index + sentinel
  run qmd_setup_if_needed "$AGENT_YML"      # second call: sentinel present
  [ "$status" -eq 0 ]
  # takes the pre-lock fast path ("already done"), never the lock path.
  echo "$output" | grep -q "already done"
  if echo "$output" | grep -q "already running"; then false; fi
}
