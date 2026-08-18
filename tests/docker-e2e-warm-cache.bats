#!/usr/bin/env bats
#
# 030 DOCKER_E2E — the boot warm cache actually makes an overlay-shaped MCP
# resolvable offline. Skipped by default (needs a docker daemon + network for the
# build; the offline proof itself uses uv's offline flag, not a namespace cut —
# `docker compose run` has no --network). Enable with DOCKER_E2E=1.
# Contract: specs/030-mcp-warm-cache/contracts/docker-e2e-tiers.md
#
# Deferred: not run in this environment (no docker daemon). Ships ready for the
# Docker-host gate (tasks.md T025). The ferrari hardware gate (recreate donna with
# PyPI cut → google-workspace connects) is the separate SC-001 gate (T026).

load helper

setup() {
  if [ "${DOCKER_E2E:-0}" != "1" ]; then
    skip "set DOCKER_E2E=1 to run (requires a docker daemon + network)"
  fi
  command -v docker >/dev/null 2>&1 || skip "docker not on PATH"
  docker info >/dev/null 2>&1 || skip "docker daemon not reachable"
  TMPDIR=/tmp setup_tmp_dir
  mkdir -p "$TMP_TEST_DIR/installer"
  cp -r "$REPO_ROOT/scripts" "$REPO_ROOT/modules" "$REPO_ROOT/docker" "$TMP_TEST_DIR/installer/"
  cp "$REPO_ROOT/setup.sh" "$TMP_TEST_DIR/installer/"
  [ -f "$REPO_ROOT/.gitignore" ] && cp "$REPO_ROOT/.gitignore" "$TMP_TEST_DIR/installer/"
  [ -f "$REPO_ROOT/LICENSE" ] && cp "$REPO_ROOT/LICENSE" "$TMP_TEST_DIR/installer/"

  cd "$TMP_TEST_DIR/installer"
  E2E_AGENT_DIR="$TMP_TEST_DIR/agent"; export E2E_AGENT_DIR
  wizard_answers name=warmbot display=WarmBot | ./setup.sh --destination "$E2E_AGENT_DIR"
  [ -f "$E2E_AGENT_DIR/docker-compose.yml" ]
  # scaffold runs the mirror → the image lib must be present for the COPY.
  [ -f "$E2E_AGENT_DIR/docker/scripts/lib/mcp_warm.sh" ]
  cat > "$E2E_AGENT_DIR/.env" <<'ENV'
TELEGRAM_BOT_TOKEN=00000:fake
TELEGRAM_CHAT_ID=0
ENV
  chmod 0600 "$E2E_AGENT_DIR/.env"
  cd "$E2E_AGENT_DIR"
  run docker compose build
  [ "$status" -eq 0 ]
}

teardown() {
  if [ -n "${E2E_AGENT_DIR:-}" ] && [ -d "$E2E_AGENT_DIR" ]; then
    (cd "$E2E_AGENT_DIR" && docker compose down -v --remove-orphans 2>/dev/null || true)
  fi
  teardown_tmp_dir
}

# ── E1/E2/E4: warm covers the wrapper-shaped uvx MCP; offline before/after ───

@test "E2E 030: mcp_warm_run makes an overlay wrapper MCP (workspace-mcp) resolvable offline" {
  # A throwaway container as `agent` (root can't read the agent-owned /opt/uv).
  # 1. workspace-mcp is NOT baked by the build (only the catalog is) → cold (E2/E4 RED).
  # 2. derive+warm from a crafted .mcp.json using the WRAPPER shape (command=seed.sh,
  #    args=[uvx, workspace-mcp]) — the exact case the old selector missed.
  # 3. after the warm, workspace-mcp is installed and resolves offline (E1 GREEN).
  run docker compose run --rm -T --user agent --entrypoint sh warmbot -c '
    set -e
    echo "COLD=$(uv tool list 2>&1 | grep -c workspace-mcp || true)"
    mkdir -p /tmp/w
    cat > /tmp/w/.mcp.json <<JSON
{ "mcpServers": {
  "gws":   { "command": "/tmp/w/seed-google-creds.sh", "args": ["uvx", "workspace-mcp"] },
  "fetch": { "command": "uvx", "args": ["mcp-server-fetch"] } } }
JSON
    . /opt/agent-admin/scripts/lib/mcp_warm.sh
    # derivation covers the wrapper shape
    echo "TARGETS=[$(mcp_warm_targets /tmp/w/.mcp.json | tr "\n" ";")]"
    mcp_warm_run /tmp/w/.mcp.json
    echo "WARM=$(uv tool list 2>&1 | grep -c workspace-mcp || true)"
    echo "OFFLINE=$(UV_OFFLINE=1 uvx workspace-mcp --help >/dev/null 2>&1 && echo ok || uv tool list 2>&1 | grep -q workspace-mcp && echo ok || echo fail)"
    echo "UVDIR=$(test -d /opt/uv && echo ok || echo fail)"
    echo "NPMDIR=$(test -d /opt/npm-cache && echo ok || echo fail)"
  '
  echo "$output"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^COLD=0'                                  # not pre-baked (E2/E4)
  echo "$output" | grep -q 'uvx	workspace-mcp'                        # derivation saw the wrapper
  echo "$output" | grep -qE '^WARM=[1-9]'                              # installed after warm (E1)
  echo "$output" | grep -q '^OFFLINE=ok'                              # resolves without network
  echo "$output" | grep -q '^UVDIR=ok'                               # cache off the mount (FR-004)
  echo "$output" | grep -q '^NPMDIR=ok'
}

# ── E3: catalog stays pre-warmed (no regression) + warm is idempotent ────────

@test "E2E 030: catalog stays pre-warmed and a second warm is a no-op (FR-005/FR-009)" {
  run docker compose run --rm -T --user agent --entrypoint sh warmbot -c '
    set -e
    echo "CATALOG=$(uv tool list 2>&1 | grep -c mcp-atlassian || true)"
    mkdir -p /tmp/w
    echo "{ \"mcpServers\": { \"fetch\": { \"command\": \"uvx\", \"args\": [\"mcp-server-fetch\"] } } }" > /tmp/w/.mcp.json
    . /opt/agent-admin/scripts/lib/mcp_warm.sh
    mcp_warm_run /tmp/w/.mcp.json; echo "RUN1=$?"
    mcp_warm_run /tmp/w/.mcp.json; echo "RUN2=$?"   # idempotent no-op
  '
  echo "$output"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^CATALOG=[1-9]'   # mcp-atlassian still baked (FR-009)
  echo "$output" | grep -q '^RUN1=0'
  echo "$output" | grep -q '^RUN2=0'
}

# ── Boot wiring reached the image ────────────────────────────────────────────

@test "E2E 030: the baked start_services.sh calls pre_warm_mcps before the tmux launch" {
  run docker compose run --rm -T --user agent --entrypoint sh warmbot -c '
    grep -n "pre_warm_mcps" /opt/agent-admin/scripts/start_services.sh
    grep -q "scripts/lib/mcp_warm.sh" /opt/agent-admin/scripts/start_services.sh && echo SOURCED
    test -f /opt/agent-admin/scripts/lib/mcp_warm.sh && echo BAKED
  '
  echo "$output"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'SOURCED'
  echo "$output" | grep -q 'BAKED'
  echo "$output" | grep -q 'pre_warm_mcps'
}
