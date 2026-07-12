#!/usr/bin/env bats
# 018 (qmd-embed-completion): qmd's own `embed` session caps at ~30 minutes
# (see specs/018-qmd-embed-completion/research.md R1) — a large vault's first
# embed run stops partway. `_qmd_embed_until_complete` loops around that cap
# (never patches the engine) inside ONE `_qmd_reindex_locked` invocation until
# coverage is complete, no forward progress is made, or QMD_EMBED_MAX_PASSES is
# hit. The amended unchanged-vault guard resumes when embeddings are still
# pending instead of skipping forever.
#
# Host-side, no Docker, no real qmd/bun. `_qmd_run` is REDEFINED per-test as a
# bash function (NOT the stale `bunx`-stub pattern used by the pre-016
# qmd-index.bats/qmd-setup.bats tests — 016 rewired qmd invocation to a
# managed `bun install` prefix, so a `bunx` stub no longer intercepts
# anything; see tests/qmd-index.bats for that known pre-existing gap). This
# stubs the actual seam the loop calls (`_qmd_run "$pkg" embed|status|update`)
# so passes/pending/stalls are fully deterministic and hermetic.

load helper

setup() {
  setup_tmp_dir
  export HOME="$TMP_TEST_DIR/home"; mkdir -p "$HOME"
  export QMD_CACHE_HOME="$TMP_TEST_DIR/cache/qmd"; mkdir -p "$QMD_CACHE_HOME"
  export QMD_VAULT_DIR="$TMP_TEST_DIR/vault"; mkdir -p "$QMD_VAULT_DIR"
  printf '# note\nhello\n' > "$QMD_VAULT_DIR/a.md"
  export QMD_INDEX_STATE_FILE="$TMP_TEST_DIR/qmd-index.json"
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
  # A real `bun` on PATH would make `_qmd_reindex_locked`'s `command -v bun`
  # guard pass on any host — good, we want that branch exercised — but we
  # never want the REAL bun/qmd to run. `_qmd_run` below is redefined per
  # test to intercept every invocation before it reaches `_qmd_ensure_prefix`.
  command -v bun >/dev/null 2>&1 || { local d="$TMP_TEST_DIR/bin"; mkdir -p "$d"; printf '#!/bin/sh\nexit 0\n' > "$d/bun"; chmod +x "$d/bun"; export PATH="$d:$PATH"; }
}

teardown() { teardown_tmp_dir; }

# ---- stub builder -----------------------------------------------------
# _stub_passes "embed_out1|pending1|rc1" "embed_out2|pending2|rc2" ...
# Each triplet describes ONE embed pass: the text `qmd embed` would print,
# the pending count `qmd status` would report immediately after, and the
# exit code of that embed invocation. `update` always no-ops successfully.
# NOTE: `_qmd_embed_until_complete` captures `_qmd_run`'s output via command
# substitution (`out=$(_qmd_run ...)`), which forks a subshell — a plain bash
# variable set inside that call would NOT survive back to the loop. The pass
# counter therefore lives in a FILE ($TMP_TEST_DIR/embed_call_count), which
# persists across subshells like any other on-disk test fixture.
_stub_passes() {
  local dir="$TMP_TEST_DIR/passes"
  mkdir -p "$dir"
  rm -f "$TMP_TEST_DIR/embed_call_count"
  local i=0 spec
  for spec in "$@"; do
    i=$((i + 1))
    printf '%s' "$spec" > "$dir/$i"
  done
  printf '%s' "$i" > "$dir/.count"
  cat > "$TMP_TEST_DIR/qmd_run_stub.sh" <<'EOF'
_qmd_run() {
  local pkg="$1"; shift
  local dir="$TMP_TEST_DIR/passes"
  local counter="$TMP_TEST_DIR/embed_call_count"
  case "$1" in
    update) return 0 ;;
    embed)
      local n=0
      [ -f "$counter" ] && n=$(cat "$counter")
      n=$((n + 1))
      printf '%s' "$n" > "$counter"
      local f="$dir/$n"
      [ -f "$f" ] || f="$dir/$(cat "$dir/.count")"
      local spec; spec=$(cat "$f")
      local out="${spec%%|*}"
      printf '%s\n' "$out"
      local rc; rc=$(printf '%s' "$spec" | awk -F'|' '{print $3}')
      return "${rc:-0}"
      ;;
    status)
      local n=0
      [ -f "$counter" ] && n=$(cat "$counter")
      [ "$n" -lt 1 ] && n=1
      local f="$dir/$n"
      [ -f "$f" ] || f="$dir/$(cat "$dir/.count")"
      local spec; spec=$(cat "$f")
      local pending; pending=$(printf '%s' "$spec" | awk -F'|' '{print $2}')
      printf 'Vectors:  0 embedded\n'
      printf 'Pending:  %s need embedding\n' "$pending"
      return 0
      ;;
  esac
}
EOF
  # shellcheck source=/dev/null
  source "$TMP_TEST_DIR/qmd_run_stub.sh"
}

# ============================================================
# Foundational: _qmd_pending_count
# ============================================================

@test "_qmd_pending_count parses the Pending line from qmd status" {
  _stub_passes "irrelevant|437|0"
  run _qmd_pending_count "pkg"
  [ "$status" -eq 0 ]
  [ "$output" = "437" ]
}

@test "_qmd_pending_count returns empty and non-zero when status has no Pending line" {
  _qmd_run() { printf 'nothing useful here\n'; return 0; }
  run _qmd_pending_count "pkg"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "_qmd_pending_count returns empty and non-zero when status fails" {
  _qmd_run() { return 1; }
  run _qmd_pending_count "pkg"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

# ============================================================
# US1 (P1): multi-pass completion
# ============================================================

@test "US1: embed completes across multiple passes when a later pass reports pending=0" {
  _stub_passes \
    "Embedded 859 chunks … Session expired|700|0" \
    "Embedded 700 chunks|0|0"
  run _qmd_embed_until_complete "pkg" "$QMD_INDEX_STATE_FILE" "HASHA" "HASHA"
  [ "$status" -eq 0 ]
  run cat "$TMP_TEST_DIR/embed_call_count"
  [ "$output" = "2" ]
  run jq -r '.last_status' "$QMD_INDEX_STATE_FILE"
  [ "$output" = "indexed" ]
  run jq -r '.pending' "$QMD_INDEX_STATE_FILE"
  [ "$output" = "0" ]
  run jq -r '.hash' "$QMD_INDEX_STATE_FILE"
  [ "$output" = "HASHA" ]
}

@test "US1: embed stops immediately when qmd reports all content already embedded" {
  _stub_passes "All content hashes already have embeddings|0|0"
  run _qmd_embed_until_complete "pkg" "$QMD_INDEX_STATE_FILE" "HASHA" "HASHA"
  [ "$status" -eq 0 ]
  run jq -r '.last_status' "$QMD_INDEX_STATE_FILE"
  [ "$output" = "indexed" ]
}

@test "US1: _qmd_reindex_locked runs update once then loops embed across passes on a changed vault" {
  _stub_passes \
    "Embedded 859 chunks … Session expired|700|0" \
    "Embedded 700 chunks|0|0"
  qmd_write_state "$QMD_INDEX_STATE_FILE" "STALEHASH" "indexed" 0
  local current; current=$(vault_hash "$QMD_VAULT_DIR")
  run _qmd_reindex_locked "$AGENT_YML" "$QMD_VAULT_DIR"
  [ "$status" -eq 0 ]
  run jq -r '.last_status' "$QMD_INDEX_STATE_FILE"
  [ "$output" = "indexed" ]
  run jq -r '.hash' "$QMD_INDEX_STATE_FILE"
  [ "$output" = "$current" ]
}

# ============================================================
# US2 (P2): resume on unchanged vault
# ============================================================

@test "US2: unchanged vault with pending>0 resumes embedding (no update call)" {
  local current; current=$(vault_hash "$QMD_VAULT_DIR")
  qmd_write_state "$QMD_INDEX_STATE_FILE" "$current" "partial" 700
  _stub_passes "Embedded 700 chunks|0|0"
  run _qmd_reindex_locked "$AGENT_YML" "$QMD_VAULT_DIR"
  [ "$status" -eq 0 ]
  run jq -r '.last_status' "$QMD_INDEX_STATE_FILE"
  [ "$output" = "indexed" ]
  run jq -r '.pending' "$QMD_INDEX_STATE_FILE"
  [ "$output" = "0" ]
}

@test "US2: unchanged vault with pending=0 skips embedding entirely" {
  local current; current=$(vault_hash "$QMD_VAULT_DIR")
  qmd_write_state "$QMD_INDEX_STATE_FILE" "$current" "indexed" 0
  _qmd_run() { echo "SHOULD NOT BE CALLED" >&2; return 1; }
  run _qmd_reindex_locked "$AGENT_YML" "$QMD_VAULT_DIR"
  [ "$status" -eq 0 ]
  run jq -r '.last_status' "$QMD_INDEX_STATE_FILE"
  [ "$output" = "skipped" ]
}

@test "US2: unchanged vault with NO recorded pending (pre-018 state) resumes rather than skipping" {
  local current; current=$(vault_hash "$QMD_VAULT_DIR")
  # 3-arg legacy write — no pending key at all (unknown).
  qmd_write_state "$QMD_INDEX_STATE_FILE" "$current" "indexed"
  run jq -e 'has("pending")' "$QMD_INDEX_STATE_FILE"
  [ "$status" -ne 0 ]
  _stub_passes "All content hashes already have embeddings|0|0"
  run _qmd_reindex_locked "$AGENT_YML" "$QMD_VAULT_DIR"
  [ "$status" -eq 0 ]
  run jq -r '.last_status' "$QMD_INDEX_STATE_FILE"
  [ "$output" = "indexed" ]
}

# ============================================================
# US3 (P3): bounded + observable
# ============================================================

@test "US3: stall (pending never decreases) stops the loop and records stalled" {
  _stub_passes \
    "Embedded 10 chunks|500|0" \
    "Embedded 0 chunks|500|0" \
    "Embedded 0 chunks|500|0"
  run _qmd_embed_until_complete "pkg" "$QMD_INDEX_STATE_FILE" "HASHA" "HASHA"
  [ "$status" -eq 0 ]
  run jq -r '.last_status' "$QMD_INDEX_STATE_FILE"
  [ "$output" = "stalled" ]
  run jq -r '.pending' "$QMD_INDEX_STATE_FILE"
  [ "$output" = "500" ]
}

@test "US3: pass cap terminates a loop that always makes tiny progress" {
  export QMD_EMBED_MAX_PASSES=2
  _stub_passes \
    "Embedded 1 chunk|999|0" \
    "Embedded 1 chunk|998|0" \
    "Embedded 1 chunk|997|0" \
    "Embedded 1 chunk|996|0"
  run _qmd_embed_until_complete "pkg" "$QMD_INDEX_STATE_FILE" "HASHA" "HASHA"
  [ "$status" -eq 0 ]
  run jq -r '.last_status' "$QMD_INDEX_STATE_FILE"
  [ "$output" = "partial" ]
  run jq -r '.pending' "$QMD_INDEX_STATE_FILE"
  [ "$output" = "998" ]
  run cat "$TMP_TEST_DIR/embed_call_count"
  [ "$output" = "2" ]
}

@test "US3: a hard embed failure (non-zero rc) records error and preserves the prior hash" {
  cat > "$TMP_TEST_DIR/qmd_run_stub.sh" <<'EOF'
_qmd_run() {
  local pkg="$1"; shift
  case "$1" in
    update) return 0 ;;
    embed) return 1 ;;
  esac
}
EOF
  # shellcheck source=/dev/null
  source "$TMP_TEST_DIR/qmd_run_stub.sh"
  qmd_write_state "$QMD_INDEX_STATE_FILE" "OLDHASH" "indexed" 0
  run _qmd_embed_until_complete "pkg" "$QMD_INDEX_STATE_FILE" "NEWHASH" "OLDHASH"
  [ "$status" -eq 0 ]
  run jq -r '.last_status' "$QMD_INDEX_STATE_FILE"
  [ "$output" = "error" ]
  run jq -r '.hash' "$QMD_INDEX_STATE_FILE"
  [ "$output" = "OLDHASH" ]
}

@test "US3: every terminal outcome records a numeric pending count" {
  _stub_passes "All content hashes already have embeddings|0|0"
  run _qmd_embed_until_complete "pkg" "$QMD_INDEX_STATE_FILE" "HASHA" "HASHA"
  run jq -e '.pending | type == "number"' "$QMD_INDEX_STATE_FILE"
  [ "$status" -eq 0 ]
}
