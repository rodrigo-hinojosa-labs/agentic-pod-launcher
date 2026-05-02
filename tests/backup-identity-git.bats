#!/usr/bin/env bats
load 'helper'

setup() {
  export HEARTBEATCTL_WORKSPACE="$BATS_TEST_TMPDIR/ws"
  export HEARTBEATCTL_LIB_DIR="$BATS_TEST_DIRNAME/../docker/scripts/lib"
  export HEARTBEATCTL_CRONTAB_FILE="$BATS_TEST_TMPDIR/crontab"
  mkdir -p "$HEARTBEATCTL_WORKSPACE/scripts/heartbeat"
  export IDENTITY_STATE_DIR="$HEARTBEATCTL_WORKSPACE/.state"
  export IDENTITY_BACKUP_CACHE_DIR="$BATS_TEST_TMPDIR/backup-cache"

  # Local bare repo as "remote"
  export FORK_BARE="$BATS_TEST_TMPDIR/fork.git"
  git init --bare --initial-branch=main "$FORK_BARE" >/dev/null 2>&1

  # Seed minimal state
  mkdir -p "$IDENTITY_STATE_DIR/.claude/channels/telegram" \
           "$IDENTITY_STATE_DIR/.claude/plugins/config"
  echo '{"defaultMode":"auto"}' > "$IDENTITY_STATE_DIR/.claude/settings.json"
  echo '{"userID":"u1"}' > "$IDENTITY_STATE_DIR/.claude.json"
  echo '{"allowFrom":["123"]}' > "$IDENTITY_STATE_DIR/.claude/channels/telegram/access.json"

  cat > "$HEARTBEATCTL_WORKSPACE/agent.yml" <<YAML
agent:
  name: testagent
scaffold:
  fork:
    url: "$FORK_BARE"
backup:
  identity:
    recipient: null
features:
  identity_backup:
    enabled: true
YAML

  export GIT_AUTHOR_NAME=test
  export GIT_AUTHOR_EMAIL=test@example
  export GIT_COMMITTER_NAME=test
  export GIT_COMMITTER_EMAIL=test@example

  HEARTBEATCTL="$BATS_TEST_DIRNAME/../docker/scripts/heartbeatctl"
}

@test "first backup creates orphan branch + pushes single commit" {
  run bash "$HEARTBEATCTL" backup-identity
  [ "$status" -eq 0 ]
  [[ "$output" == *"pushed"* ]]

  run git --git-dir="$FORK_BARE" rev-parse backup/identity
  [ "$status" -eq 0 ]

  run git --git-dir="$FORK_BARE" ls-tree -r --name-only backup/identity
  [[ "$output" == *".claude.json"* ]]
  [[ "$output" == *".claude/settings.json"* ]]
  [[ "$output" == *".claude/channels/telegram/access.json"* ]]

  [[ "$output" != *".env.age"* ]]
}

@test "second backup after state change creates second commit" {
  run bash "$HEARTBEATCTL" backup-identity
  [ "$status" -eq 0 ]
  local sha1
  sha1=$(git --git-dir="$FORK_BARE" rev-parse backup/identity)

  echo '{"allowFrom":["123","456"]}' > "$IDENTITY_STATE_DIR/.claude/channels/telegram/access.json"

  run bash "$HEARTBEATCTL" backup-identity
  [ "$status" -eq 0 ]
  local sha2
  sha2=$(git --git-dir="$FORK_BARE" rev-parse backup/identity)

  [ "$sha1" != "$sha2" ]
  run git --git-dir="$FORK_BARE" log --format=%s backup/identity
  [ "$(echo "$output" | wc -l)" -ge 2 ]
}

@test "full mode encrypts .env to .env.age when recipient is configured" {
  local keypair
  keypair="$BATS_TEST_TMPDIR/age.key"
  age-keygen -o "$keypair" 2>/dev/null
  local pubkey
  pubkey=$(grep '^# public key:' "$keypair" | cut -d: -f2 | tr -d ' ')

  yq -i ".backup.identity.recipient = \"$pubkey\"" "$HEARTBEATCTL_WORKSPACE/agent.yml"

  echo 'TELEGRAM_BOT_TOKEN=secret-abc' > "$IDENTITY_STATE_DIR/.env"

  run bash "$HEARTBEATCTL" backup-identity
  [ "$status" -eq 0 ]
  [[ "$output" == *"(full)"* ]]

  run git --git-dir="$FORK_BARE" ls-tree -r --name-only backup/identity
  [[ "$output" == *".env.age"* ]]
  ! echo "$output" | grep -qE '^\.env$'

  git --git-dir="$FORK_BARE" show "backup/identity:.env.age" > "$BATS_TEST_TMPDIR/env.age"
  run age -d -i "$keypair" -o "$BATS_TEST_TMPDIR/env.plain" "$BATS_TEST_TMPDIR/env.age"
  [ "$status" -eq 0 ]
  run cat "$BATS_TEST_TMPDIR/env.plain"
  [ "$output" = "TELEGRAM_BOT_TOKEN=secret-abc" ]
}

@test "transition partial -> full adds .env.age, removes from partial if any" {
  run bash "$HEARTBEATCTL" backup-identity
  run git --git-dir="$FORK_BARE" ls-tree -r --name-only backup/identity
  [[ "$output" != *".env.age"* ]]

  local keypair pubkey
  keypair="$BATS_TEST_TMPDIR/age.key"
  age-keygen -o "$keypair" 2>/dev/null
  pubkey=$(grep '^# public key:' "$keypair" | cut -d: -f2 | tr -d ' ')
  yq -i ".backup.identity.recipient = \"$pubkey\"" "$HEARTBEATCTL_WORKSPACE/agent.yml"
  echo 'TOK=x' > "$IDENTITY_STATE_DIR/.env"

  run bash "$HEARTBEATCTL" backup-identity
  [ "$status" -eq 0 ]
  run git --git-dir="$FORK_BARE" ls-tree -r --name-only backup/identity
  [[ "$output" == *".env.age"* ]]
}

@test "transition full -> partial removes .env.age from next commit" {
  local keypair pubkey
  keypair="$BATS_TEST_TMPDIR/age.key"
  age-keygen -o "$keypair" 2>/dev/null
  pubkey=$(grep '^# public key:' "$keypair" | cut -d: -f2 | tr -d ' ')
  yq -i ".backup.identity.recipient = \"$pubkey\"" "$HEARTBEATCTL_WORKSPACE/agent.yml"
  echo 'TOK=x' > "$IDENTITY_STATE_DIR/.env"
  run bash "$HEARTBEATCTL" backup-identity
  run git --git-dir="$FORK_BARE" ls-tree -r --name-only backup/identity
  [[ "$output" == *".env.age"* ]]

  yq -i '.backup.identity.recipient = null' "$HEARTBEATCTL_WORKSPACE/agent.yml"
  echo '{"defaultMode":"default"}' > "$IDENTITY_STATE_DIR/.claude/settings.json"
  run bash "$HEARTBEATCTL" backup-identity
  [ "$status" -eq 0 ]

  run git --git-dir="$FORK_BARE" ls-tree -r --name-only backup/identity
  [[ "$output" != *".env.age"* ]]
}

@test "no-op backup when state unchanged" {
  run bash "$HEARTBEATCTL" backup-identity
  [ "$status" -eq 0 ]
  local sha1
  sha1=$(git --git-dir="$FORK_BARE" rev-parse backup/identity)

  run bash "$HEARTBEATCTL" backup-identity
  [ "$status" -eq 0 ]
  [[ "$output" == *"no changes"* ]]
  local sha2
  sha2=$(git --git-dir="$FORK_BARE" rev-parse backup/identity)
  [ "$sha1" = "$sha2" ]
}
