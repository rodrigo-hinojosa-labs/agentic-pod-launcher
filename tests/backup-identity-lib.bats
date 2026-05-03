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

# Regression: in May 2026 a missing fork PAT caused git clone to block
# on a stdin username prompt, deadlocking the watchdog and preventing
# tmux respawn — user couldn't /login. Fix: GIT_TERMINAL_PROMPT=0 on
# every network git call. This test stubs git via PATH and asserts the
# env var is exported when _identity_git fires.
@test "_identity_git sets GIT_TERMINAL_PROMPT=0 + GIT_ASKPASS" {
  local stub="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$stub"
  cat > "$stub/git" <<'EOF'
#!/bin/sh
echo "TERM=${GIT_TERMINAL_PROMPT:-unset}"
echo "ASK=${GIT_ASKPASS:-unset}"
EOF
  chmod +x "$stub/git"
  PATH="$stub:$PATH" run _identity_git fake-cmd
  [ "$status" -eq 0 ]
  [[ "$output" == *"TERM=0"* ]]
  [[ "$output" == *"ASK=/bin/true"* ]]
}

@test "_identity_git falls back to plain git when timeout(1) absent" {
  # Drop a stub PATH that hides timeout(1) — must NOT make _identity_git
  # error out (env vars still apply, just no upper bound).
  local stub="$BATS_TEST_TMPDIR/bin-no-timeout"
  mkdir -p "$stub"
  cat > "$stub/git" <<'EOF'
#!/bin/sh
echo "ran ${GIT_TERMINAL_PROMPT}"
EOF
  chmod +x "$stub/git"
  # Build a minimal PATH with only the stub + sh primitives, no timeout.
  PATH="$stub:/bin:/usr/bin" run _identity_git foo
  # If timeout(1) wasn't found in the host's /bin /usr/bin, we exercise
  # the fallback branch. If it was, the timeout-wrapped branch runs —
  # both should produce TERM=0 in the output.
  [ "$status" -eq 0 ]
  [[ "$output" == *"ran 0"* ]]
}
