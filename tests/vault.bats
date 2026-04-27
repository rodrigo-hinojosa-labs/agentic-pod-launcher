#!/usr/bin/env bats

load 'helper'

setup() {
  load_lib vault
  setup_tmp_dir
  SKELETON="$REPO_ROOT/modules/vault-skeleton"
}

teardown() {
  teardown_tmp_dir
}

# --- skeleton structure -----------------------------------------------------

@test "skeleton: required top-level entries exist" {
  [ -d "$SKELETON/raw_sources" ]
  [ -d "$SKELETON/wiki" ]
  [ -d "$SKELETON/_templates" ]
  [ -f "$SKELETON/index.md" ]
  [ -f "$SKELETON/log.md" ]
  [ -f "$SKELETON/CLAUDE.md" ]
}

@test "skeleton: raw_sources has README" {
  [ -f "$SKELETON/raw_sources/README.md" ]
}

@test "skeleton: wiki has the six Karpathy page-type subdirs" {
  for t in summaries entities concepts comparisons overviews synthesis; do
    [ -d "$SKELETON/wiki/$t" ] || { echo "missing: wiki/$t"; return 1; }
  done
}

@test "skeleton: _templates has one file per page type plus source" {
  for t in source summary entity concept comparison overview synthesis; do
    [ -f "$SKELETON/_templates/$t.md" ] || { echo "missing: _templates/$t.md"; return 1; }
  done
}

@test "skeleton: page templates have valid YAML frontmatter with the right type" {
  for t in summary entity concept comparison overview synthesis; do
    local f="$SKELETON/_templates/$t.md"
    [ -f "$f" ] || { echo "missing: $f"; return 1; }
    head -1 "$f" | grep -q '^---$' || { echo "$f: no opening ---"; return 1; }
    local fm type_val
    fm=$(awk '/^---$/{c++; if(c==2) exit; next} c==1{print}' "$f")
    [ -n "$fm" ] || { echo "$f: empty frontmatter"; return 1; }
    type_val=$(printf '%s\n' "$fm" | yq '.type' 2>/dev/null)
    [ "$type_val" = "$t" ] || { echo "$f: type=$type_val, expected $t"; return 1; }
  done
}

@test "skeleton: log.md contains SCAFFOLD_DATE placeholder pre-seed" {
  grep -q 'SCAFFOLD_DATE' "$SKELETON/log.md"
}

@test "skeleton: index.md has all six section headers" {
  for h in Summaries Entities Concepts Comparisons Overviews Synthesis; do
    grep -qE "^## $h\$" "$SKELETON/index.md" || { echo "missing header: $h"; return 1; }
  done
}

# --- vault_ensure_paths -----------------------------------------------------

@test "vault_ensure_paths: creates the directory" {
  run vault_ensure_paths "$TMP_TEST_DIR/v1"
  [ "$status" -eq 0 ]
  [ -d "$TMP_TEST_DIR/v1" ]
}

@test "vault_ensure_paths: idempotent when dir exists" {
  mkdir -p "$TMP_TEST_DIR/v2"
  echo "preexisting" > "$TMP_TEST_DIR/v2/file"
  run vault_ensure_paths "$TMP_TEST_DIR/v2"
  [ "$status" -eq 0 ]
  [ -f "$TMP_TEST_DIR/v2/file" ]
}

@test "vault_ensure_paths: errors on missing arg" {
  run vault_ensure_paths
  [ "$status" -ne 0 ]
}

# --- vault_seed_if_empty ----------------------------------------------------

@test "vault_seed_if_empty: copies skeleton into empty target" {
  local target="$TMP_TEST_DIR/seeded"
  run vault_seed_if_empty "$target" "$SKELETON" "2026-04-26"
  [ "$status" -eq 0 ]
  [ -f "$target/CLAUDE.md" ]
  [ -f "$target/index.md" ]
  [ -f "$target/log.md" ]
  [ -d "$target/wiki/concepts" ]
  [ -f "$target/_templates/summary.md" ]
}

@test "vault_seed_if_empty: replaces SCAFFOLD_DATE in log.md with provided date" {
  local target="$TMP_TEST_DIR/seeded2"
  run vault_seed_if_empty "$target" "$SKELETON" "2026-04-26"
  [ "$status" -eq 0 ]
  ! grep -q 'SCAFFOLD_DATE' "$target/log.md"
  grep -q '\[2026-04-26\] init' "$target/log.md"
}

@test "vault_seed_if_empty: no-op when target has content" {
  local target="$TMP_TEST_DIR/already-there"
  mkdir -p "$target"
  echo "user content" > "$target/notes.md"
  run vault_seed_if_empty "$target" "$SKELETON" "2026-04-26"
  [ "$status" -eq 0 ]
  [ -f "$target/notes.md" ]
  [ ! -f "$target/CLAUDE.md" ]
}

@test "vault_seed_if_empty: errors on missing skeleton" {
  run vault_seed_if_empty "$TMP_TEST_DIR/x" "$TMP_TEST_DIR/nonexistent-skeleton"
  [ "$status" -ne 0 ]
}

# --- vault_log_append -------------------------------------------------------

@test "vault_log_append: appends a Karpathy-format entry" {
  local target="$TMP_TEST_DIR/with-log"
  vault_seed_if_empty "$target" "$SKELETON" "2026-04-26"
  run vault_log_append "$target" "ingest" "Karpathy LLM Wiki" "2026-05-01"
  [ "$status" -eq 0 ]
  grep -qE '^## \[2026-05-01\] ingest \| Karpathy LLM Wiki$' "$target/log.md"
}

@test "vault_log_append: errors when log.md is missing" {
  mkdir -p "$TMP_TEST_DIR/no-log"
  run vault_log_append "$TMP_TEST_DIR/no-log" "ingest" "X"
  [ "$status" -ne 0 ]
}

@test "vault_log_append: errors on missing args" {
  run vault_log_append "$TMP_TEST_DIR" "" ""
  [ "$status" -ne 0 ]
}
