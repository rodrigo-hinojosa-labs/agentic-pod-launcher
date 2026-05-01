#!/usr/bin/env bats
# Tests for scripts/agentctl — host-side wrapper for `docker exec -u agent
# NAME ...` patterns. The CLI never actually invokes docker in the tests:
# we override DOCKER_BIN with a recorder that captures argv into a file,
# and assert the recorded args.

load helper

AGENTCTL="$REPO_ROOT/scripts/agentctl"

setup() {
  setup_tmp_dir
  # Recorder: writes "$@" to $RECORD_FILE on each call.
  cat > "$TMP_TEST_DIR/docker" <<REC
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$TMP_TEST_DIR/recorded"
REC
  chmod +x "$TMP_TEST_DIR/docker"
  export PATH="$TMP_TEST_DIR:$PATH"
}

teardown() { teardown_tmp_dir; }

@test "agentctl --help lists the main subcommands" {
  run "$AGENTCTL" --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "attach"
  echo "$output" | grep -q "logs"
  echo "$output" | grep -q "status"
  echo "$output" | grep -q "heartbeat"
  echo "$output" | grep -q "mcp"
  echo "$output" | grep -q "shell"
  echo "$output" | grep -q "run"
}

@test "agentctl unknown-subcommand exits 1 with a hint" {
  run "$AGENTCTL" totallymadeup
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "unknown subcommand"
  echo "$output" | grep -q "Try 'agentctl help'"
}

@test "agentctl errors clearly when no agent name can be resolved" {
  cd "$TMP_TEST_DIR"
  unset AGENT_NAME
  run "$AGENTCTL" status
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "cannot resolve agent name"
  echo "$output" | grep -q "Pass -a NAME"
}

@test "agentctl resolves agent name from -a flag (highest priority)" {
  cd "$TMP_TEST_DIR"
  run "$AGENTCTL" -a custom-agent status
  [ "$status" -eq 0 ]
  grep -q "^custom-agent$" "$TMP_TEST_DIR/recorded"
  grep -q "^heartbeatctl$" "$TMP_TEST_DIR/recorded"
}

@test "agentctl resolves agent name from AGENT_NAME env var" {
  cd "$TMP_TEST_DIR"
  AGENT_NAME=env-agent run "$AGENTCTL" status
  [ "$status" -eq 0 ]
  grep -q "^env-agent$" "$TMP_TEST_DIR/recorded"
}

@test "agentctl resolves agent name from agent.yml in cwd" {
  cd "$TMP_TEST_DIR"
  cat > agent.yml <<'YML'
agent:
  name: yaml-agent
YML
  unset AGENT_NAME
  run "$AGENTCTL" status
  [ "$status" -eq 0 ]
  grep -q "^yaml-agent$" "$TMP_TEST_DIR/recorded"
}

@test "agentctl logs default tails /workspace/claude.log" {
  cd "$TMP_TEST_DIR"
  AGENT_NAME=test run "$AGENTCTL" logs -n 50
  [ "$status" -eq 0 ]
  grep -q "^/workspace/claude.log$" "$TMP_TEST_DIR/recorded"
  grep -q "^tail$" "$TMP_TEST_DIR/recorded"
  grep -q "^-n$" "$TMP_TEST_DIR/recorded"
  grep -q "^50$" "$TMP_TEST_DIR/recorded"
}

@test "agentctl logs --stderr tails the telegram stderr log" {
  cd "$TMP_TEST_DIR"
  AGENT_NAME=test run "$AGENTCTL" logs --stderr -f
  [ "$status" -eq 0 ]
  grep -q "telegram-mcp-stderr.log" "$TMP_TEST_DIR/recorded"
  grep -q "^-f$" "$TMP_TEST_DIR/recorded"
}

@test "agentctl heartbeat passes args through to heartbeatctl" {
  cd "$TMP_TEST_DIR"
  AGENT_NAME=test run "$AGENTCTL" heartbeat set-interval 5m
  [ "$status" -eq 0 ]
  grep -q "^heartbeatctl$" "$TMP_TEST_DIR/recorded"
  grep -q "^set-interval$" "$TMP_TEST_DIR/recorded"
  grep -q "^5m$" "$TMP_TEST_DIR/recorded"
}

@test "agentctl heartbeat without subcommand errors with hint" {
  cd "$TMP_TEST_DIR"
  AGENT_NAME=test run "$AGENTCTL" heartbeat
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "missing subcommand"
}

@test "agentctl run passes the command verbatim" {
  cd "$TMP_TEST_DIR"
  AGENT_NAME=test run "$AGENTCTL" run ls /workspace
  [ "$status" -eq 0 ]
  grep -q "^ls$" "$TMP_TEST_DIR/recorded"
  grep -q "^/workspace$" "$TMP_TEST_DIR/recorded"
}

@test "agentctl run without args errors" {
  cd "$TMP_TEST_DIR"
  AGENT_NAME=test run "$AGENTCTL" run
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "missing command"
}

@test "agentctl shell uses -u agent by default" {
  cd "$TMP_TEST_DIR"
  AGENT_NAME=test run "$AGENTCTL" shell
  [ "$status" -eq 0 ]
  grep -q "^-u$" "$TMP_TEST_DIR/recorded"
  grep -q "^agent$" "$TMP_TEST_DIR/recorded"
  grep -q "^bash$" "$TMP_TEST_DIR/recorded"
}

@test "agentctl shell --root drops the -u agent flag" {
  cd "$TMP_TEST_DIR"
  AGENT_NAME=test run "$AGENTCTL" shell --root
  [ "$status" -eq 0 ]
  grep -q "^bash$" "$TMP_TEST_DIR/recorded"
  ! grep -q "^-u$" "$TMP_TEST_DIR/recorded"
}

@test "agentctl mcp default delegates to 'claude mcp list'" {
  cd "$TMP_TEST_DIR"
  AGENT_NAME=test run "$AGENTCTL" mcp
  [ "$status" -eq 0 ]
  grep -q "^claude$" "$TMP_TEST_DIR/recorded"
  grep -q "^mcp$" "$TMP_TEST_DIR/recorded"
  grep -q "^list$" "$TMP_TEST_DIR/recorded"
}
