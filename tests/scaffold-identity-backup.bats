#!/usr/bin/env bats
load 'helper'

# Exercise scaffold's GitHub-key lookup against fixture files via
# `file://`. Same migration as fetch-github-key.bats: spawning
# `python3 -m http.server` per test left children that blocked bats's
# post-suite cleanup in CI. `file://` reuses curl's full request path
# without any background process.

setup() {
  FIXTURE_DIR="$BATS_TEST_TMPDIR/keys-fixture"
  mkdir -p "$FIXTURE_DIR"

  SCRIPT_DIR="$BATS_TEST_DIRNAME/.."
  export SSH_KEYS_URL_TEMPLATE="file://$FIXTURE_DIR/%s.keys"
}

teardown() { :; }

@test "scaffold populates backup.identity.recipient when GitHub key exists" {
  cat > "$FIXTURE_DIR/alice.keys" <<EOF
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample alice@modern
EOF
  local dest="$BATS_TEST_TMPDIR/agent"
  source "$SCRIPT_DIR/setup.sh" >/dev/null 2>&1 || true

  mkdir -p "$dest"
  cat > "$dest/agent.yml" <<YAML
scaffold:
  fork:
    owner: alice
backup:
  identity:
    recipient: null
YAML

  run configure_identity_backup "$dest/agent.yml"
  [ "$status" -eq 0 ]

  run yq '.backup.identity.recipient' "$dest/agent.yml"
  [[ "$output" == ssh-ed25519* ]]
}

@test "scaffold leaves recipient null + warns when GitHub has no keys" {
  : > "$FIXTURE_DIR/ghost.keys"
  local dest="$BATS_TEST_TMPDIR/agent"
  source "$SCRIPT_DIR/setup.sh" >/dev/null 2>&1 || true

  mkdir -p "$dest"
  cat > "$dest/agent.yml" <<YAML
scaffold:
  fork:
    owner: ghost
backup:
  identity:
    recipient: null
YAML

  run configure_identity_backup "$dest/agent.yml"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no SSH key"* ]] || [[ "$output" == *"partial"* ]]

  run yq '.backup.identity.recipient' "$dest/agent.yml"
  [ "$output" = "null" ]
}
