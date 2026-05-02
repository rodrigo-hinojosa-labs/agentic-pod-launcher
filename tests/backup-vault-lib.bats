#!/usr/bin/env bats
load 'helper'

setup() {
  LIB="$BATS_TEST_DIRNAME/../docker/scripts/lib/backup_vault.sh"
  # shellcheck source=/dev/null
  source "$LIB"

  export VAULT_DIR="$BATS_TEST_TMPDIR/vault"
  mkdir -p "$VAULT_DIR/wiki/summaries" \
           "$VAULT_DIR/raw_sources" \
           "$VAULT_DIR/.obsidian" \
           "$VAULT_DIR/.trash"

  cat > "$VAULT_DIR/index.md" <<EOF
# Index
- [[wiki/summaries/memex]] — first ingest
EOF
  cat > "$VAULT_DIR/wiki/summaries/memex.md" <<EOF
# Memex
Vannevar Bush's hypertext predecessor.
EOF
  cat > "$VAULT_DIR/raw_sources/wikipedia-memex.md" <<EOF
# Wikipedia: Memex (raw)
EOF
  # Files that should be excluded:
  echo '{"layout":"two-column"}' > "$VAULT_DIR/.obsidian/workspace.json"
  echo 'cached blob' > "$VAULT_DIR/.obsidian/cache-blob.bin"
  cat > "$VAULT_DIR/.trash/old-note.md" <<EOF
# Deleted note
EOF
  cat > "$VAULT_DIR/wiki/summaries/memex.md.sync-conflict-20260501-mac.md" <<EOF
# Conflict copy
EOF
}

@test "vault_list_markdown skips excluded paths" {
  run bash -c '
    set -u
    LIB="'"$LIB"'"
    # shellcheck source=/dev/null
    source "$LIB"
    while IFS= read -r -d "" p; do
      printf "%s\n" "$p"
    done < <(vault_list_markdown "'"$VAULT_DIR"'")
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"index.md"* ]]
  [[ "$output" == *"wiki/summaries/memex.md"* ]]
  [[ "$output" == *"raw_sources/wikipedia-memex.md"* ]]
  [[ "$output" != *".trash"* ]]
  [[ "$output" != *"sync-conflict"* ]]
  [[ "$output" != *".obsidian"* ]]
}

@test "vault_hash is deterministic for the same inputs" {
  local h1 h2
  h1=$(vault_hash "$VAULT_DIR")
  h2=$(vault_hash "$VAULT_DIR")
  [ -n "$h1" ]
  [ "$h1" = "$h2" ]
}

@test "vault_hash changes when a markdown file changes" {
  local h1
  h1=$(vault_hash "$VAULT_DIR")
  echo "Updated content" >> "$VAULT_DIR/wiki/summaries/memex.md"
  local h2
  h2=$(vault_hash "$VAULT_DIR")
  [ "$h1" != "$h2" ]
}

@test "vault_hash is stable when an excluded file changes" {
  local h1
  h1=$(vault_hash "$VAULT_DIR")
  echo '{"layout":"three-column"}' > "$VAULT_DIR/.obsidian/workspace.json"
  echo "different content" > "$VAULT_DIR/.trash/old-note.md"
  local h2
  h2=$(vault_hash "$VAULT_DIR")
  [ "$h1" = "$h2" ]
}

@test "vault_hash is stable when an unrelated extension is added" {
  # Only *.md files contribute to the hash. Adding a non-markdown file
  # at the vault root must not change it.
  local h1
  h1=$(vault_hash "$VAULT_DIR")
  echo "csv,data,here" > "$VAULT_DIR/data.csv"
  local h2
  h2=$(vault_hash "$VAULT_DIR")
  [ "$h1" = "$h2" ]
}

@test "vault_hash detects a new markdown file" {
  local h1
  h1=$(vault_hash "$VAULT_DIR")
  cat > "$VAULT_DIR/wiki/summaries/another.md" <<EOF
# Another
EOF
  local h2
  h2=$(vault_hash "$VAULT_DIR")
  [ "$h1" != "$h2" ]
}

@test "vault_hash detects a deleted markdown file" {
  local h1
  h1=$(vault_hash "$VAULT_DIR")
  rm "$VAULT_DIR/wiki/summaries/memex.md"
  local h2
  h2=$(vault_hash "$VAULT_DIR")
  [ "$h1" != "$h2" ]
}

@test "vault_resolve_root reads vault.path from agent.yml" {
  local agent_yml="$BATS_TEST_TMPDIR/agent.yml"
  cat > "$agent_yml" <<YAML
vault:
  enabled: true
  path: .state/.vault
YAML
  run vault_resolve_root "$agent_yml"
  [ "$status" -eq 0 ]
  [ "$output" = "/home/agent/.vault" ]
}

@test "vault_resolve_root rebases non-default path under /home/agent" {
  local agent_yml="$BATS_TEST_TMPDIR/agent.yml"
  cat > "$agent_yml" <<YAML
vault:
  enabled: true
  path: .state/notes/personal
YAML
  run vault_resolve_root "$agent_yml"
  [ "$status" -eq 0 ]
  [ "$output" = "/home/agent/notes/personal" ]
}

@test "vault_resolve_root prints nothing when vault is disabled" {
  local agent_yml="$BATS_TEST_TMPDIR/agent.yml"
  cat > "$agent_yml" <<YAML
vault:
  enabled: false
  path: .state/.vault
YAML
  run vault_resolve_root "$agent_yml"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
