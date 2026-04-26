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

@test "setup.sh --non-interactive rejects agent.yml missing required field" {
  cd "$TMP_TEST_DIR"
  cat > agent.yml <<'YML'
version: 1
agent:
  name: testbot
deployment:
  workspace: "/tmp/testbot"
docker:
  image_tag: "agent-admin:latest"
  uid: 1000
  gid: 1000
  base_image: "alpine:3.20"
notifications:
  channel: none
features:
  heartbeat:
    enabled: true
    interval: "30m"
    timeout: 300
    retries: 1
    # default_prompt deliberately omitted
YML
  run ./setup.sh --non-interactive
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing required field"* ]]
  [[ "$output" == *"default_prompt"* ]]
}
