#!/usr/bin/env bats
# Story H behavioral proof (opt-in). The host test tests/wizard-container-refresh.bats
# asserts the refresh PROMPT wording; this exercises the real image-baked
# refresh_claude_md() inside a booted container against a stub `claude` that
# simulates the LLM edit, proving the file is PRESERVED (operator section
# survives byte-for-byte) and only ADDED to (a Commands section appears).
#
# A real, authenticated claude is not available in CI, and the refresh only
# fires post-/login, so we drive refresh_claude_md() directly via docker exec
# with a stub `claude`/`gum` on PATH (bind-mounted through the workspace).

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

@test "E2E: CLAUDE.md refresh preserves existing sections and only adds missing ones" {
  E2E_AGENT_DIR="$TMP_TEST_DIR/e2e-refresh"
  export E2E_AGENT_DIR

  cd "$TMP_TEST_DIR/installer"
  wizard_answers name=e2erefresh display=E2ERefresh | ./setup.sh --destination "$E2E_AGENT_DIR"
  [ -f "$E2E_AGENT_DIR/docker-compose.yml" ]

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
    docker inspect --format '{{.State.Running}}' e2erefresh 2>/dev/null | grep -q "true" && break
    sleep 1; i=$((i+1))
  done
  [ "$(docker inspect --format '{{.State.Running}}' e2erefresh)" = "true" ]

  # Operator-authored CLAUDE.md with a section the refresh must NOT touch.
  cat > "$E2E_AGENT_DIR/CLAUDE.md" <<'MD'
# CLAUDE.md

## Identity

- **Role:** test agent

## Operator Notes

OPERATOR_MARKER — this hand-written section must survive byte-for-byte.
MD

  # Stub claude + gum in a workspace dir (bind-mounted into the container).
  # The claude stub simulates the LLM's Edit: append a Commands section while
  # leaving existing content untouched. The gum stub runs the command after '--'.
  mkdir -p "$E2E_AGENT_DIR/.stub"
  cat > "$E2E_AGENT_DIR/.stub/claude" <<'STUB'
#!/bin/sh
printf '\n## Commands\n\nstub-added commands section.\n' >> /workspace/CLAUDE.md
STUB
  cat > "$E2E_AGENT_DIR/.stub/gum" <<'STUB'
#!/bin/sh
while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done
[ "$1" = "--" ] && shift
exec "$@"
STUB
  chmod +x "$E2E_AGENT_DIR/.stub/claude" "$E2E_AGENT_DIR/.stub/gum"

  # Drive the real image-baked refresh function with the stubs on PATH.
  run docker exec -u agent e2erefresh bash -c \
    'WIZARD_CONTAINER_NO_RUN=1 . /opt/agent-admin/scripts/wizard-container.sh; CLAUDE_MD=/workspace/CLAUDE.md PATH=/workspace/.stub:$PATH refresh_claude_md'
  [ "$status" -eq 0 ]

  # The operator section survived verbatim, and a Commands section was added.
  grep -q "OPERATOR_MARKER — this hand-written section must survive byte-for-byte." "$E2E_AGENT_DIR/CLAUDE.md"
  grep -q "## Operator Notes" "$E2E_AGENT_DIR/CLAUDE.md"
  grep -q "## Commands" "$E2E_AGENT_DIR/CLAUDE.md"
}
