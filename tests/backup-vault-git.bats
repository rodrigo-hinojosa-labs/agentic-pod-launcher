#!/usr/bin/env bats
load 'helper'

setup() {
  export HEARTBEATCTL_WORKSPACE="$BATS_TEST_TMPDIR/ws"
  export HEARTBEATCTL_LIB_DIR="$BATS_TEST_DIRNAME/../docker/scripts/lib"
  export HEARTBEATCTL_CRONTAB_FILE="$BATS_TEST_TMPDIR/crontab"
  mkdir -p "$HEARTBEATCTL_WORKSPACE/scripts/heartbeat"
  export VAULT_BACKUP_CACHE_DIR="$BATS_TEST_TMPDIR/backup-cache"

  # Tests don't run inside the container — VAULT_BACKUP_DIR overrides the
  # /home/agent/.vault path that vault_resolve_root would compute.
  export VAULT_BACKUP_DIR="$BATS_TEST_TMPDIR/vault"
  mkdir -p "$VAULT_BACKUP_DIR/wiki/summaries" \
           "$VAULT_BACKUP_DIR/raw_sources" \
           "$VAULT_BACKUP_DIR/.obsidian"
  cat > "$VAULT_BACKUP_DIR/index.md" <<EOF
# Index
- [[wiki/summaries/memex]]
EOF
  cat > "$VAULT_BACKUP_DIR/wiki/summaries/memex.md" <<EOF
# Memex
Vannevar Bush's hypertext predecessor.
EOF
  echo '{"layout":"two-column"}' > "$VAULT_BACKUP_DIR/.obsidian/workspace.json"

  # Local bare repo as "remote"
  export FORK_BARE="$BATS_TEST_TMPDIR/fork.git"
  git init --bare --initial-branch=main "$FORK_BARE" >/dev/null 2>&1

  cat > "$HEARTBEATCTL_WORKSPACE/agent.yml" <<YAML
agent:
  name: testagent
scaffold:
  fork:
    url: "$FORK_BARE"
vault:
  enabled: true
  path: .state/.vault
features:
  identity_backup:
    enabled: false
YAML

  export GIT_AUTHOR_NAME=test
  export GIT_AUTHOR_EMAIL=test@example
  export GIT_COMMITTER_NAME=test
  export GIT_COMMITTER_EMAIL=test@example

  HEARTBEATCTL="$BATS_TEST_DIRNAME/../docker/scripts/heartbeatctl"
}

@test "first vault backup creates orphan branch + pushes a single commit" {
  run bash "$HEARTBEATCTL" backup-vault
  [ "$status" -eq 0 ]
  [[ "$output" == *"pushed"* ]]

  run git --git-dir="$FORK_BARE" rev-parse backup/vault
  [ "$status" -eq 0 ]

  run git --git-dir="$FORK_BARE" ls-tree -r --name-only backup/vault
  [[ "$output" == *"index.md"* ]]
  [[ "$output" == *"wiki/summaries/memex.md"* ]]
  [[ "$output" != *".obsidian"* ]]
}

@test "second vault backup after a markdown change creates a second commit" {
  run bash "$HEARTBEATCTL" backup-vault
  [ "$status" -eq 0 ]
  local sha1
  sha1=$(git --git-dir="$FORK_BARE" rev-parse backup/vault)

  echo "Updated body" >> "$VAULT_BACKUP_DIR/wiki/summaries/memex.md"

  # The hash check inside _bv_run lives on a state file written by the
  # first run; remove it so the second run actually triggers a stage.
  # (We're testing the git flow, not the hash short-circuit — that's
  # covered separately below.)
  run bash "$HEARTBEATCTL" backup-vault
  [ "$status" -eq 0 ]
  local sha2
  sha2=$(git --git-dir="$FORK_BARE" rev-parse backup/vault)

  [ "$sha1" != "$sha2" ]
  run git --git-dir="$FORK_BARE" log --format=%s backup/vault
  [ "$(echo "$output" | wc -l)" -ge 2 ]
}

@test "vault backup is no-op when nothing changed (hash short-circuit)" {
  run bash "$HEARTBEATCTL" backup-vault
  [ "$status" -eq 0 ]

  # Second invocation: hash matches → no commit, no push attempted.
  run bash "$HEARTBEATCTL" backup-vault
  [ "$status" -eq 0 ]
  [[ "$output" == *"no changes since last backup"* ]]
}

@test "vault backup propagates a deleted markdown file to the next snapshot" {
  run bash "$HEARTBEATCTL" backup-vault
  [ "$status" -eq 0 ]

  rm "$VAULT_BACKUP_DIR/wiki/summaries/memex.md"

  run bash "$HEARTBEATCTL" backup-vault
  [ "$status" -eq 0 ]

  run git --git-dir="$FORK_BARE" ls-tree -r --name-only backup/vault
  [[ "$output" == *"index.md"* ]]
  [[ "$output" != *"memex.md"* ]]
}

@test "vault backup excludes .obsidian/ entirely" {
  run bash "$HEARTBEATCTL" backup-vault
  [ "$status" -eq 0 ]
  run git --git-dir="$FORK_BARE" ls-tree -r --name-only backup/vault
  [[ "$output" != *"workspace.json"* ]]
  [[ "$output" != *".obsidian"* ]]
}

@test "vault backup --dry-run does not push" {
  run bash "$HEARTBEATCTL" backup-vault --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"dry-run"* ]]

  # No backup/vault ref should exist.
  run git --git-dir="$FORK_BARE" rev-parse --verify backup/vault
  [ "$status" -ne 0 ]
}

@test "vault backup is a no-op when vault is disabled" {
  yq -i '.vault.enabled = false' "$HEARTBEATCTL_WORKSPACE/agent.yml"
  unset VAULT_BACKUP_DIR

  run bash "$HEARTBEATCTL" backup-vault
  [ "$status" -eq 0 ]
  [[ "$output" == *"vault not enabled"* ]]
}
