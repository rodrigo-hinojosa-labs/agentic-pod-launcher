#!/usr/bin/env bats

load helper

setup() {
  if [ "${DOCKER_E2E:-0}" != "1" ]; then
    skip "set DOCKER_E2E=1 to run (requires a working docker daemon)"
  fi
  command -v docker >/dev/null 2>&1 || skip "docker not on PATH"
  docker info >/dev/null 2>&1 || skip "docker daemon not reachable"
  setup_tmp_dir
  mkdir -p "$TMP_TEST_DIR/installer"
  cp -r "$REPO_ROOT/scripts" "$REPO_ROOT/modules" "$REPO_ROOT/docker" "$TMP_TEST_DIR/installer/"
  cp "$REPO_ROOT/setup.sh" "$TMP_TEST_DIR/installer/"
  [ -f "$REPO_ROOT/.gitignore" ] && cp "$REPO_ROOT/.gitignore" "$TMP_TEST_DIR/installer/"
  [ -f "$REPO_ROOT/LICENSE" ] && cp "$REPO_ROOT/LICENSE" "$TMP_TEST_DIR/installer/"
}

teardown() {
  if [ -n "${E2E_AGENT_DIR:-}" ] && [ -d "$E2E_AGENT_DIR" ]; then
    (cd "$E2E_AGENT_DIR" && docker compose down -v 2>/dev/null || true)
  fi
  teardown_tmp_dir
}

@test "E2E: scaffold + build + up + healthcheck" {
  E2E_AGENT_DIR="$TMP_TEST_DIR/e2e-agent"
  export E2E_AGENT_DIR

  cd "$TMP_TEST_DIR/installer"
  wizard_answers name=e2ebot display=E2EBot | ./setup.sh --destination "$E2E_AGENT_DIR"

  [ -f "$E2E_AGENT_DIR/docker-compose.yml" ]

  # Pre-seed .env so the container skips the wizard and goes straight to steady state.
  cat > "$E2E_AGENT_DIR/.env" <<'ENV'
TELEGRAM_BOT_TOKEN=00000:fake
TELEGRAM_CHAT_ID=0
ENV
  chmod 0600 "$E2E_AGENT_DIR/.env"

  cd "$E2E_AGENT_DIR"
  run docker compose build
  [ "$status" -eq 0 ]

  run docker compose up -d
  [ "$status" -eq 0 ]

  # Wait up to 30s for the container to be running.
  local i=0
  while [ $i -lt 30 ]; do
    if docker inspect --format '{{.State.Running}}' e2ebot 2>/dev/null | grep -q "true"; then
      break
    fi
    sleep 1
    i=$((i+1))
  done
  [ "$(docker inspect --format '{{.State.Running}}' e2ebot)" = "true" ]

  # State lives in <workspace>/.state as a bind-mount (since PR #3); the
  # workspace IS the agent. Verify the bind-mount is in place from both
  # sides: directory exists on host and the container sees /home/agent
  # populated.
  [ -d "$E2E_AGENT_DIR/.state" ]
  run docker exec -u agent e2ebot test -d /home/agent
  [ "$status" -eq 0 ]

  # Tmux session eventually comes up (claude may fail without real credentials,
  # which is fine — the session is what we care about in the smoke).
  i=0
  while [ $i -lt 20 ]; do
    if docker exec -u agent e2ebot tmux has-session -t agent 2>/dev/null; then
      break
    fi
    sleep 1
    i=$((i+1))
  done
  run docker exec -u agent e2ebot tmux has-session -t agent
  [ "$status" -eq 0 ]

  # Teardown: down -v must leave no container behind. State bind-mount
  # survives intentionally (the workspace owns the data, not docker) and
  # is removed only by deleting the workspace directory.
  docker compose down -v
  ! docker inspect e2ebot 2>/dev/null
  [ -d "$E2E_AGENT_DIR/.state" ]
}
