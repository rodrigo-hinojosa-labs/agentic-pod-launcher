#!/usr/bin/env bats
load 'helper'

# Exercise fetch_github_ssh_key against a mock HTTP endpoint. Uses `python3 -m
# http.server` in a child process serving a fixture file.

setup() {
  PORT=$((10000 + RANDOM % 50000))
  FIXTURE_DIR="$BATS_TEST_TMPDIR/keys-fixture"
  mkdir -p "$FIXTURE_DIR"

  SCRIPT_DIR="$BATS_TEST_DIRNAME/.."
  SSH_KEYS_URL_TEMPLATE="http://localhost:$PORT/%s.keys"
  export SSH_KEYS_URL_TEMPLATE

  (cd "$FIXTURE_DIR" && python3 -m http.server "$PORT" >/dev/null 2>&1) &
  SERVER_PID=$!
  for i in $(seq 1 20); do
    curl -fsSL "http://localhost:$PORT/" >/dev/null 2>&1 && break
    sleep 0.1
  done
}

teardown() {
  [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null || true
}

@test "fetch_github_ssh_key returns ed25519 when available" {
  cat > "$FIXTURE_DIR/alice.keys" <<EOF
ssh-rsa AAAAB3NzaC1yc2EAAAAD... alice@legacy
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample alice@modern
EOF
  source "$SCRIPT_DIR/setup.sh" >/dev/null 2>&1 || true
  run fetch_github_ssh_key alice
  [ "$status" -eq 0 ]
  [[ "$output" == ssh-ed25519* ]]
}

@test "fetch_github_ssh_key falls back to rsa when no ed25519" {
  cat > "$FIXTURE_DIR/bob.keys" <<EOF
ssh-rsa AAAAB3NzaC1yc2EAAAAD... bob@legacy
EOF
  source "$SCRIPT_DIR/setup.sh" >/dev/null 2>&1 || true
  run fetch_github_ssh_key bob
  [ "$status" -eq 0 ]
  [[ "$output" == ssh-rsa* ]]
}

@test "fetch_github_ssh_key returns non-zero on 404" {
  source "$SCRIPT_DIR/setup.sh" >/dev/null 2>&1 || true
  run fetch_github_ssh_key nonexistent-user
  [ "$status" -ne 0 ]
}

@test "fetch_github_ssh_key returns non-zero on empty response" {
  : > "$FIXTURE_DIR/ghost.keys"
  source "$SCRIPT_DIR/setup.sh" >/dev/null 2>&1 || true
  run fetch_github_ssh_key ghost
  [ "$status" -ne 0 ]
}
