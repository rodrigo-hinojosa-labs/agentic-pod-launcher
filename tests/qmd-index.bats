#!/usr/bin/env bats
# US2 (010-self-managing-rag): qmd_reindex is hash-debounced (skips embed when
# the vault is unchanged), runs update+embed when it changed, and is
# flock-guarded against concurrent runs. Host-side, no Docker.
#
# Engine seam (019, post-016 contract): _qmd_run executes
# $(_qmd_prefix)/node_modules/.bin/qmd directly — a PATH `bunx` stub is dead
# code. Tests stub via helper.bash::install_qmd_stub{,_fail} (fake engine
# binary in the managed prefix + pre-seeded .installed-hash + no-op `bun` for
# the guards). See specs/019-fix-qmd-test-drift/contracts/qmd-test-seam.md.

load helper

setup() {
  setup_tmp_dir
  export HOME="$TMP_TEST_DIR/home"; mkdir -p "$HOME"
  export QMD_CACHE_HOME="$TMP_TEST_DIR/cache/qmd"; mkdir -p "$QMD_CACHE_HOME"
  export QMD_VAULT_DIR="$TMP_TEST_DIR/vault"; mkdir -p "$QMD_VAULT_DIR/wiki"
  printf '# note\nhello\n' > "$QMD_VAULT_DIR/wiki/a.md"
  export QMD_INDEX_STATE_FILE="$TMP_TEST_DIR/qmd-index.json"
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

@test "qmd_reindex skips embed when the vault is unchanged AND fully embedded" {
  # 018/FR-004: "unchanged" alone is no longer sufficient to skip — it must
  # ALSO be fully embedded (pending=0), or a large first-time embed that hit
  # the session cap would never resume (see contracts/embed-completion.md).
  install_qmd_stub
  local h; h=$(vault_hash "$QMD_VAULT_DIR")
  qmd_write_state "$QMD_INDEX_STATE_FILE" "$h" "indexed" 0
  : > "$QMD_STUB_LOG"
  run qmd_reindex "$AGENT_YML"
  [ "$status" -eq 0 ]
  [ ! -s "$QMD_STUB_LOG" ]
  run jq -r '.last_status' "$QMD_INDEX_STATE_FILE"
  [ "$output" = "skipped" ]
}

@test "qmd_reindex runs update+embed and records indexed when the vault changed" {
  install_qmd_stub
  qmd_write_state "$QMD_INDEX_STATE_FILE" "STALEHASH" "indexed"
  : > "$QMD_STUB_LOG"
  run qmd_reindex "$AGENT_YML"
  [ "$status" -eq 0 ]
  grep -q "update" "$QMD_STUB_LOG"
  grep -q "embed" "$QMD_STUB_LOG"
  # The stub emits the 018 completion signal on `embed`, so the multi-pass
  # loop finishes in one pass: indexed + pending=0 (018 schema).
  run jq -r '.last_status' "$QMD_INDEX_STATE_FILE"
  [ "$output" = "indexed" ]
  run jq -r '.pending' "$QMD_INDEX_STATE_FILE"
  [ "$output" = "0" ]
  run jq -r '.hash' "$QMD_INDEX_STATE_FILE"
  [ "$output" != "STALEHASH" ]
}

@test "qmd_reindex increments runs and writes a well-formed state file" {
  install_qmd_stub
  run qmd_reindex "$AGENT_YML"
  [ "$status" -eq 0 ]
  run jq -r '.runs' "$QMD_INDEX_STATE_FILE"
  [ "$output" = "1" ]
  run jq -e '.hash and .last_run and .last_status and (.runs|type=="number")' "$QMD_INDEX_STATE_FILE"
  [ "$status" -eq 0 ]
}

# ── 037 US2: automatic one-time collection migration (before the hash guard) ─

@test "037: inherited index (no sentinel) migrates first tick: remove->add(wiki mask)->update->sentinel->cleanup, no embed at Pending:0" {
  install_qmd_stub
  mkdir -p "$QMD_CACHE_HOME"; : > "$QMD_CACHE_HOME/index.sqlite"
  run qmd_reindex "$AGENT_YML"
  [ "$status" -eq 0 ]
  local log; log=$(cat "$QMD_STUB_LOG")
  # order: remove, add (wiki mask), update, cleanup — sentinel write is a
  # plain file (not a qmd subcommand) between update and cleanup.
  local i_remove i_add i_update i_cleanup
  i_remove=$(grep -n '^collection remove' "$QMD_STUB_LOG" | head -1 | cut -d: -f1)
  i_add=$(grep -n '^collection add' "$QMD_STUB_LOG" | head -1 | cut -d: -f1)
  i_update=$(grep -n '^update$' "$QMD_STUB_LOG" | head -1 | cut -d: -f1)
  i_cleanup=$(grep -n '^cleanup$' "$QMD_STUB_LOG" | head -1 | cut -d: -f1)
  [ -n "$i_remove" ] && [ -n "$i_add" ] && [ -n "$i_update" ] && [ -n "$i_cleanup" ]
  [ "$i_remove" -lt "$i_add" ]
  [ "$i_add" -lt "$i_update" ]
  [ "$i_update" -lt "$i_cleanup" ]
  grep -qF -- "collection add $QMD_VAULT_DIR --name vault --mask wiki/**/*.md" "$QMD_STUB_LOG"
  ! grep -q '^embed$' "$QMD_STUB_LOG"
  [ -f "$QMD_CACHE_HOME/.qmd-collection-wiki" ]
  [ "$(jq -r '.migration' "$QMD_INDEX_STATE_FILE")" = "done" ]
}

@test "037: inherited index WITH pending embeds runs embed after cleanup" {
  install_qmd_stub
  mkdir -p "$QMD_CACHE_HOME"; : > "$QMD_CACHE_HOME/index.sqlite"
  QMD_STUB_PENDING=3 run qmd_reindex "$AGENT_YML"
  [ "$status" -eq 0 ]
  grep -q '^embed$' "$QMD_STUB_LOG"
}

@test "037: second reindex tick after migration touches no collection/cleanup again" {
  install_qmd_stub
  mkdir -p "$QMD_CACHE_HOME"; : > "$QMD_CACHE_HOME/index.sqlite"
  qmd_reindex "$AGENT_YML"
  : > "$QMD_STUB_LOG"
  run qmd_reindex "$AGENT_YML"
  [ "$status" -eq 0 ]
  ! grep -q '^collection' "$QMD_STUB_LOG"
  ! grep -q '^cleanup$' "$QMD_STUB_LOG"
}

@test "037: interrupted migration (add fails once) leaves sentinel absent, migration pending, error state, hash untouched" {
  install_qmd_stub
  mkdir -p "$QMD_CACHE_HOME"; : > "$QMD_CACHE_HOME/index.sqlite"
  qmd_write_state "$QMD_INDEX_STATE_FILE" "PRIORHASH" "indexed" 0
  QMD_STUB_FAIL_ONCE=add run qmd_reindex "$AGENT_YML"
  [ "$status" -eq 0 ]
  [ ! -f "$QMD_CACHE_HOME/.qmd-collection-wiki" ]
  [ "$(qmd_collection_migration_state)" = "pending" ]
  [ "$(jq -r '.last_status' "$QMD_INDEX_STATE_FILE")" = "error" ]
  [ "$(jq -r '.hash' "$QMD_INDEX_STATE_FILE")" = "PRIORHASH" ]
  ! grep -q '^update$' "$QMD_STUB_LOG"
  ! grep -q '^embed$' "$QMD_STUB_LOG"
  # next tick completes the migration
  run qmd_reindex "$AGENT_YML"
  [ "$status" -eq 0 ]
  [ -f "$QMD_CACHE_HOME/.qmd-collection-wiki" ]
  [ "$(qmd_collection_migration_state)" = "done" ]
}

@test "037: no index.sqlite at all -> reindex issues no 'collection remove'" {
  install_qmd_stub
  run qmd_reindex "$AGENT_YML"
  [ "$status" -eq 0 ]
  ! grep -q '^collection remove' "$QMD_STUB_LOG"
  [ "$(jq -r '.migration' "$QMD_INDEX_STATE_FILE")" = "n/a" ]
}

@test "qmd_reindex records last_status=error and preserves the prior hash on engine failure" {
  install_qmd_stub_fail
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
  install_qmd_stub
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
  install_qmd_stub
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

# ── 018 (qmd-embed-completion): qmd_write_state's optional 4th `pending` arg ──
# See specs/018-qmd-embed-completion/contracts/reindex-state.md.

@test "qmd_write_state with a 4th arg writes an integer pending field" {
  qmd_write_state "$QMD_INDEX_STATE_FILE" "HASHA" "partial" 700
  run jq -r '.pending' "$QMD_INDEX_STATE_FILE"
  [ "$output" = "700" ]
  run jq -e '.pending | type == "number"' "$QMD_INDEX_STATE_FILE"
  [ "$status" -eq 0 ]
}

@test "qmd_write_state 3-arg form (back-compat) still works and existence-check still passes" {
  run qmd_write_state "$QMD_INDEX_STATE_FILE" "HASHA" "indexed"
  [ "$status" -eq 0 ]
  run jq -e '.hash and .last_run and .last_status and (.runs|type=="number")' "$QMD_INDEX_STATE_FILE"
  [ "$status" -eq 0 ]
}

@test "qmd_write_state 3-arg form leaves pending absent (unknown) on a brand-new file" {
  qmd_write_state "$QMD_INDEX_STATE_FILE" "HASHA" "indexed"
  run jq -e 'has("pending")' "$QMD_INDEX_STATE_FILE"
  [ "$status" -ne 0 ]
}

@test "qmd_write_state 3-arg form carries forward the prior pending value" {
  qmd_write_state "$QMD_INDEX_STATE_FILE" "HASHA" "partial" 700
  qmd_write_state "$QMD_INDEX_STATE_FILE" "HASHA" "error"
  run jq -r '.pending' "$QMD_INDEX_STATE_FILE"
  [ "$output" = "700" ]
}

@test "qmd_write_state indexed status always pairs with pending=0" {
  qmd_write_state "$QMD_INDEX_STATE_FILE" "HASHA" "indexed" 0
  run jq -r '.pending' "$QMD_INDEX_STATE_FILE"
  [ "$output" = "0" ]
}
