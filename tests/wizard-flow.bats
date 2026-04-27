#!/usr/bin/env bats

load helper

setup() {
  setup_tmp_dir
  cp -r "$REPO_ROOT/scripts" "$REPO_ROOT/modules" "$TMP_TEST_DIR/"
  cp "$REPO_ROOT/setup.sh" "$TMP_TEST_DIR/"
  [ -f "$REPO_ROOT/.gitignore" ] && cp "$REPO_ROOT/.gitignore" "$TMP_TEST_DIR/"
  [ -f "$REPO_ROOT/LICENSE" ] && cp "$REPO_ROOT/LICENSE" "$TMP_TEST_DIR/"
}

teardown() { teardown_tmp_dir; }

@test "wizard scaffolds destination with all files" {
  cd "$TMP_TEST_DIR"
  local dest="$TMP_TEST_DIR/my-test-agent"
  # --destination skips the deployment prompt, so one fewer answer needed
  run ./setup.sh --destination "$dest" <<EOF
my-test
TestAgent 🤖
Test role
Direct
Alice Example
Alice
UTC
alice@example.com
en
testhost
n
n
none
n
n
y
15m
Check status
y
n
proceed
EOF
  [ "$status" -eq 0 ]
  [ ! -f agent.yml ]  # should be MOVED to destination
  [ -f "$dest/agent.yml" ]
  [ -f "$dest/.env" ]
  [ -f "$dest/CLAUDE.md" ]
  [ -f "$dest/.mcp.json" ]
  [ -f "$dest/setup.sh" ]
  [ -d "$dest/modules" ]
  [ -d "$dest/scripts/lib" ]
  [ "$(yq '.agent.name' "$dest/agent.yml")" = "my-test" ]
  [ "$(git -C "$dest" rev-parse --abbrev-ref HEAD)" = "my-test/live" ]
}
