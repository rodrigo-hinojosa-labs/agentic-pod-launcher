#!/usr/bin/env bats

load helper

setup() {
  setup_tmp_dir
  cp -r "$REPO_ROOT/scripts" "$TMP_TEST_DIR/"
  cp "$REPO_ROOT/setup.sh" "$TMP_TEST_DIR/"
}

teardown() { teardown_tmp_dir; }

@test "setup.sh --help prints usage" {
  cd "$TMP_TEST_DIR"
  run ./setup.sh --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
  [[ "$output" == *"--regenerate"* ]]
  [[ "$output" == *"--reset"* ]]
  [[ "$output" == *"--non-interactive"* ]]
}

@test "setup.sh --non-interactive without agent.yml fails" {
  cd "$TMP_TEST_DIR"
  run ./setup.sh --non-interactive
  [ "$status" -ne 0 ]
  [[ "$output" == *"agent.yml not found"* ]]
}
