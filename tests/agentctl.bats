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
  echo "$output" | grep -q "doctor"
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

# ─── Doctor + friendly errors ────────────────────────────────────────────
# These tests use a richer docker shim that returns different exit codes
# per subcommand, so the doctor can walk its dependency chain (daemon → ps
# -a → inspect → exec) realistically.

# Helper: install a parameterized docker shim. Set DOCKER_INFO_RC=1 to
# simulate "daemon down". Set CONTAINER_EXISTS=0 to simulate "container
# does not exist".
_install_docker_shim() {
  local info_rc="${DOCKER_INFO_RC:-0}"
  local container_exists="${CONTAINER_EXISTS:-1}"
  cat > "$TMP_TEST_DIR/docker" <<SHIM
#!/usr/bin/env bash
case "\$1" in
  info)   exit $info_rc ;;
  ps)     [ "$container_exists" = "1" ] && echo "abc123def456" ; exit 0 ;;
  inspect) echo "running" ; exit 0 ;;
  exec)   exit 0 ;;
  *)      printf '%s\n' "\$@" > "$TMP_TEST_DIR/recorded" ; exit 0 ;;
esac
SHIM
  chmod +x "$TMP_TEST_DIR/docker"
}

@test "agentctl doctor: friendly error when Docker daemon is down" {
  cd "$TMP_TEST_DIR"
  DOCKER_INFO_RC=1 _install_docker_shim
  AGENT_NAME=test run "$AGENTCTL" doctor
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "Docker daemon"
  # OS-aware hint must mention the right path. Both branches accepted to
  # keep the test portable across Linux/macOS bats hosts.
  echo "$output" | grep -qE "Docker Desktop|systemctl start docker"
}

@test "agentctl status: friendly error when Docker daemon is down" {
  cd "$TMP_TEST_DIR"
  DOCKER_INFO_RC=1 _install_docker_shim
  AGENT_NAME=test run "$AGENTCTL" status
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "cannot reach the Docker daemon"
}

@test "agentctl doctor: reports container missing when 'docker ps' returns empty" {
  cd "$TMP_TEST_DIR"
  CONTAINER_EXISTS=0 _install_docker_shim
  AGENT_NAME=ghost run "$AGENTCTL" doctor
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "Docker daemon running"
  echo "$output" | grep -q "Container 'ghost' does not exist"
  echo "$output" | grep -q "agentctl up"
}

@test "agentctl doctor: prints diagnostic header with the resolved agent name" {
  cd "$TMP_TEST_DIR"
  _install_docker_shim
  AGENT_NAME=specific-name run "$AGENTCTL" doctor
  echo "$output" | grep -q "diagnosing specific-name"
}

# ─── .state bind-mount source guard (cmd_up) + doctor check ──────────────
# Root cause: a missing .state/ (a transient Docker Desktop file-sharing
# glitch on macOS, or a fresh clone) makes `docker compose up` mount a
# phantom empty /home/agent — the container boots "healthy" but /login can't
# persist. cmd_up pre-creates .state before up; doctor surfaces a missing or
# non-writable one instead of letting the agent ghost silently.

@test "agentctl up pre-creates .state when missing" {
  cd "$TMP_TEST_DIR"
  printf 'services: {}\n' > docker-compose.yml
  rm -rf .state
  AGENT_NAME=test run "$AGENTCTL" up
  [ "$status" -eq 0 ]
  [ -d "$TMP_TEST_DIR/.state" ]
}

@test "agentctl up leaves an existing .state untouched" {
  cd "$TMP_TEST_DIR"
  printf 'services: {}\n' > docker-compose.yml
  mkdir -p .state
  printf 'keep\n' > .state/sentinel
  AGENT_NAME=test run "$AGENTCTL" up
  [ "$status" -eq 0 ]
  [ -f "$TMP_TEST_DIR/.state/sentinel" ]
}

@test "agentctl up still runs 'docker compose up -d' after the guard" {
  cd "$TMP_TEST_DIR"
  printf 'services: {}\n' > docker-compose.yml
  rm -rf .state
  AGENT_NAME=test run "$AGENTCTL" up
  [ "$status" -eq 0 ]
  grep -q "^compose$" "$TMP_TEST_DIR/recorded"
  grep -q "^up$" "$TMP_TEST_DIR/recorded"
  grep -q "^-d$" "$TMP_TEST_DIR/recorded"
}

@test "agentctl up does not create .state outside a workspace (no compose file)" {
  cd "$TMP_TEST_DIR"
  rm -f docker-compose.yml
  rm -rf .state
  AGENT_NAME=test run "$AGENTCTL" up
  [ ! -d "$TMP_TEST_DIR/.state" ]
}

@test "agentctl doctor: fails when .state is missing" {
  cd "$TMP_TEST_DIR"
  _install_docker_shim
  printf 'agent:\n  name: test\n' > agent.yml
  rm -rf .state
  AGENT_NAME=test run "$AGENTCTL" doctor
  echo "$output" | grep -q "State dir"
}

@test "agentctl doctor: passes when .state is present and writable" {
  cd "$TMP_TEST_DIR"
  _install_docker_shim
  printf 'agent:\n  name: test\n' > agent.yml
  mkdir -p .state
  AGENT_NAME=test run "$AGENTCTL" doctor
  echo "$output" | grep -q "State dir .state/ present"
}
