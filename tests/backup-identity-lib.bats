#!/usr/bin/env bats
load 'helper'

setup() {
  LIB="$BATS_TEST_DIRNAME/../docker/scripts/lib/backup_identity.sh"
  # shellcheck source=/dev/null
  source "$LIB"

  # Synthetic .state/ tree
  export STATE_DIR="$BATS_TEST_TMPDIR/state"
  mkdir -p "$STATE_DIR/.claude/channels/telegram" \
           "$STATE_DIR/.claude/plugins/config"
  echo '{"permissions":{"defaultMode":"auto"}}' > "$STATE_DIR/.claude/settings.json"
  echo '{"allowFrom":["123"]}' > "$STATE_DIR/.claude/channels/telegram/access.json"
  echo '{"userID":"u1"}' > "$STATE_DIR/.claude.json"
  echo 'FOO=bar' > "$STATE_DIR/.env"
}

@test "identity_whitelist emits known paths (relative to STATE_DIR)" {
  run identity_whitelist "$STATE_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *".claude.json"* ]]
  [[ "$output" == *".claude/settings.json"* ]]
  [[ "$output" == *".claude/channels/telegram/access.json"* ]]
  [[ "$output" == *".claude/plugins/config"* ]]
}

@test "identity_hash is deterministic for the same inputs" {
  local h1 h2
  h1=$(identity_hash "$STATE_DIR")
  h2=$(identity_hash "$STATE_DIR")
  [ -n "$h1" ]
  [ "$h1" = "$h2" ]
}

@test "identity_hash changes when a whitelisted file changes" {
  local h1
  h1=$(identity_hash "$STATE_DIR")
  echo '{"allowFrom":["123","456"]}' > "$STATE_DIR/.claude/channels/telegram/access.json"
  local h2
  h2=$(identity_hash "$STATE_DIR")
  [ "$h1" != "$h2" ]
}

@test "identity_hash is stable when an excluded file changes" {
  local h1
  h1=$(identity_hash "$STATE_DIR")
  mkdir -p "$STATE_DIR/.claude/projects/-workspace"
  echo "junk" > "$STATE_DIR/.claude/projects/-workspace/session.jsonl"
  local h2
  h2=$(identity_hash "$STATE_DIR")
  [ "$h1" = "$h2" ]
}
