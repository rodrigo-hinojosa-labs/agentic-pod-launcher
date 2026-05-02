#!/usr/bin/env bats
load 'helper'

setup() {
  PORT=$((10000 + RANDOM % 50000))
  FIXTURE_DIR="$BATS_TEST_TMPDIR/keys-fixture"
  mkdir -p "$FIXTURE_DIR"

  SCRIPT_DIR="$BATS_TEST_DIRNAME/.."
  export SSH_KEYS_URL_TEMPLATE="http://localhost:$PORT/%s.keys"

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
