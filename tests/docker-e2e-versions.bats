#!/usr/bin/env bats
# Docker e2e (US1, T014): the documented `docker compose build` actually
# honors the toolchain versions recorded in agent.yml's docker: block —
# proving the resolve-and-record → compose build-arg → Dockerfile ARG →
# runtime chain end to end.
#
# Skipped by default: slow, needs a docker daemon AND network (the build
# downloads claude-code/uv/bun/gum and warms the uvx MCP cache). Enable
# with DOCKER_E2E=1.
#
# Two tests, mirroring the spec's independent-test ("record a version,
# build, the container reports it; repeat with a second version"):
#   1. wizard scaffold records the offline floor (current latest-stable);
#      build; assert claude/uv/bun/gum/alpine in the image match what
#      agent.yml records, and the three Python MCPs (mcp-atlassian,
#      mcp-server-fetch, mcp-server-time) are pre-installed via uvx
#      (research.md high-risk: uv 0.11 + Python 3.14 warm /opt/uv cache).
#   2. a second, *pinned* claude_code_version distinct from the Dockerfile
#      default flows through the build-arg and is the version that lands —
#      proving the passthrough drives the install, not the baked default.

load helper

# A real, previously-shipped Claude Code release, deliberately different from
# the current Dockerfile ARG default, so test 2 distinguishes "build-arg
# honored" from "default happened to match".
SECOND_CLAUDE_VERSION="2.1.119"

setup() {
  if [ "${DOCKER_E2E:-0}" != "1" ]; then
    skip "set DOCKER_E2E=1 to run (requires a docker daemon + network)"
  fi
  command -v docker >/dev/null 2>&1 || skip "docker not on PATH"
  docker info >/dev/null 2>&1 || skip "docker daemon not reachable"
  # Docker Desktop's bind-mount layer is most reliable under /tmp on macOS.
  TMPDIR=/tmp setup_tmp_dir
  mkdir -p "$TMP_TEST_DIR/installer"
  cp -r "$REPO_ROOT/scripts" "$REPO_ROOT/modules" "$REPO_ROOT/docker" "$TMP_TEST_DIR/installer/"
  cp "$REPO_ROOT/setup.sh" "$TMP_TEST_DIR/installer/"
  [ -f "$REPO_ROOT/.gitignore" ] && cp "$REPO_ROOT/.gitignore" "$TMP_TEST_DIR/installer/"
  [ -f "$REPO_ROOT/LICENSE" ] && cp "$REPO_ROOT/LICENSE" "$TMP_TEST_DIR/installer/"
}

teardown() {
  if [ -n "${E2E_AGENT_DIR:-}" ] && [ -d "$E2E_AGENT_DIR" ]; then
    (cd "$E2E_AGENT_DIR" && docker compose down -v --remove-orphans 2>/dev/null || true)
  fi
  teardown_tmp_dir
}

# Minimal .env so `docker compose build|run` (env_file: ./.env) is satisfied.
_seed_env() {
  cat > "$1/.env" <<'ENV'
TELEGRAM_BOT_TOKEN=00000:fake
TELEGRAM_CHAT_ID=0
ENV
  chmod 0600 "$1/.env"
}

@test "E2E: documented build honors recorded toolchain versions + bakes uvx MCPs" {
  E2E_AGENT_DIR="$TMP_TEST_DIR/verbot"
  export E2E_AGENT_DIR

  cd "$TMP_TEST_DIR/installer"
  # The suite runs offline (helper sets AGENTIC_VERSIONS_OFFLINE=1), so the
  # wizard records the documented floor (== current latest-stable) into
  # agent.yml. The build below still pulls the real artifacts over the
  # network; only resolution is floored, so recorded == installed.
  #
  # Note: the floor equals the Dockerfile ARG defaults (a drift-guard keeps
  # them in sync), so this test proves the documented build yields a working
  # image whose tools match agent.yml AND that the uvx MCPs are pre-installed
  # — it does NOT by itself prove the build-arg overrode the default (the
  # values coincide). The second test, with a version != the default, is what
  # proves the passthrough actually drives the install.
  wizard_answers name=verbot display=VerBot | ./setup.sh --destination "$E2E_AGENT_DIR"
  [ -f "$E2E_AGENT_DIR/agent.yml" ]
  [ -f "$E2E_AGENT_DIR/docker-compose.yml" ]
  _seed_env "$E2E_AGENT_DIR"

  cd "$E2E_AGENT_DIR"

  # Drive the assertions from the recorded SSOT (not hardcoded), so this
  # stays correct across future bumps.
  local v_claude v_uv v_bun v_gum base v_alpine
  v_claude=$(yq -r '.docker.claude_code_version' agent.yml)
  v_uv=$(yq -r '.docker.uv_version' agent.yml)
  v_bun=$(yq -r '.docker.bun_version' agent.yml)
  v_gum=$(yq -r '.docker.gum_version' agent.yml)
  base=$(yq -r '.docker.base_image' agent.yml)
  v_alpine=${base#alpine:}
  [ -n "$v_claude" ] && [ "$v_claude" != "null" ]
  [ -n "$v_alpine" ] && [ "$v_alpine" != "null" ]

  run docker compose build
  [ "$status" -eq 0 ]

  # One throwaway container with the entrypoint overridden (no boot, no
  # watchdog, no credentials needed) — probe every baked tool at once.
  # Run as `agent`: under the least-privilege model (cap_drop: ALL, no
  # CAP_DAC_OVERRIDE) root cannot read the agent-owned /opt/uv cache, so
  # `uv tool list` errors as root — same reason every docker exec uses -u agent.
  run docker compose run --rm -T --user agent --entrypoint sh verbot -c '
    echo "CLAUDE=$(claude --version 2>&1)"
    echo "UV=$(uv --version 2>&1)"
    echo "BUN=$(bun --version 2>&1)"
    echo "GUM=$(gum --version 2>&1)"
    echo "ALPINE=$(cat /etc/alpine-release 2>&1)"
    echo "TOOLS=$(uv tool list 2>&1)"
  '
  echo "$output"   # surfaced by bats only on failure — aids diagnosis
  [ "$status" -eq 0 ]

  # Declared versions are honored by the documented build (SC-001/SC-004).
  echo "$output" | grep -q "^CLAUDE=.*${v_claude}"
  echo "$output" | grep -q "^UV=.*${v_uv}"
  echo "$output" | grep -q "^BUN=.*${v_bun}"
  echo "$output" | grep -q "^GUM=.*${v_gum}"
  echo "$output" | grep -q "^ALPINE=.*${v_alpine}"

  # The three Python MCPs are pre-installed via uvx (warm /opt/uv cache
  # survived under uv 0.11 + Python 3.14).
  echo "$output" | grep -q "mcp-atlassian"
  echo "$output" | grep -q "mcp-server-fetch"
  echo "$output" | grep -q "mcp-server-time"
}

@test "E2E: a second pinned claude_code_version overrides the Dockerfile default" {
  E2E_AGENT_DIR="$TMP_TEST_DIR/verbot2"
  export E2E_AGENT_DIR

  cd "$TMP_TEST_DIR/installer"
  wizard_answers name=verbot2 display=VerBot2 | ./setup.sh --destination "$E2E_AGENT_DIR"
  [ -f "$E2E_AGENT_DIR/agent.yml" ]

  cd "$E2E_AGENT_DIR"

  # Pin Claude Code to a real, older release distinct from the Dockerfile
  # ARG default. --regenerate preserves it via the backfill's non-null guard
  # (it only fills MISSING *_version fields), so the recorded value survives
  # and renders into the build-arg. The channel=pinned write documents intent
  # and is the lever that also protects it from `agentctl versions --upgrade`.
  yq -i ".docker.claude_code_version = \"$SECOND_CLAUDE_VERSION\"" agent.yml
  yq -i '.docker.toolchain_channels.claude_code = "pinned"' agent.yml
  ./setup.sh --regenerate --non-interactive
  _seed_env "$E2E_AGENT_DIR"

  # Fast guard before paying for a build: the rendered build-arg must carry
  # the pinned version (catches a regenerate/passthrough regression early).
  run yq -r '.services.verbot2.build.args.CLAUDE_CODE_VERSION' docker-compose.yml
  [ "$status" -eq 0 ]
  [ "$output" = "$SECOND_CLAUDE_VERSION" ]

  run docker compose build
  [ "$status" -eq 0 ]

  run docker compose run --rm -T --entrypoint /usr/local/bin/claude verbot2 --version
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$SECOND_CLAUDE_VERSION"* ]]
}
