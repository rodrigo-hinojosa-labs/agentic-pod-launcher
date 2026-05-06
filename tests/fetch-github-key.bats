#!/usr/bin/env bats
load 'helper'

# Exercise fetch_github_ssh_key against fixture files via `file://`. The
# previous implementation spawned `python3 -m http.server` per test;
# leftover children blocked bats's post-suite cleanup for ~13 min in CI.
# `file://` keeps the curl path under test (same scheme parsing, same
# header handling) without any background process.

setup() {
  FIXTURE_DIR="$BATS_TEST_TMPDIR/keys-fixture"
  mkdir -p "$FIXTURE_DIR"

  SCRIPT_DIR="$BATS_TEST_DIRNAME/.."
  SSH_KEYS_URL_TEMPLATE="file://$FIXTURE_DIR/%s.keys"
  export SSH_KEYS_URL_TEMPLATE
}

teardown() { :; }

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
