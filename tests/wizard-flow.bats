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
  local answers
  answers=$(wizard_answers name=my-test display="TestAgent 🤖" role="Test role" vibe=Direct)
  run ./setup.sh --destination "$dest" <<<"$answers"
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
