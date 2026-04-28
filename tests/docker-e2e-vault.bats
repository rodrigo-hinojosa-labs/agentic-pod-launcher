#!/usr/bin/env bats
# Docker e2e: scaffolds a test agent with vault enabled, boots it, asserts
# that the per-agent Karpathy LLM Wiki vault is seeded into /home/agent/.vault/
# from /opt/agent-admin/modules/vault-skeleton/, the convenience symlink
# /home/agent/vault is created, and .mcp.json carries the vault MCP server.
#
# Skipped by default (slow + requires Docker). Enable with DOCKER_E2E=1.
#
# Pattern follows tests/docker-e2e-heartbeat.bats: write agent.yml directly
# (skips the wizard), regenerate derived files non-interactively, install a
# claude stub on PATH so the watchdog doesn't crash-loop trying to launch
# the real CLI we don't ship in the test image.

load helper

setup() {
  if [ "${DOCKER_E2E:-0}" != "1" ]; then skip "set DOCKER_E2E=1 to run"; fi
  TMPDIR=/tmp setup_tmp_dir
  export DEST="$TMP_TEST_DIR/agent-vault-e2e"
  export AGENT_NAME="vault-e2e"
}

teardown() {
  if [ -d "$DEST" ]; then
    (cd "$DEST" && docker compose down -v --remove-orphans || true)
  fi
  teardown_tmp_dir
}

@test "vault e2e: seed populated, symlink created, mcp.json carries vault server" {
  # 1) prepare a workspace with agent.yml + all source dirs
  mkdir -p "$DEST"
  cat > "$DEST/agent.yml" <<YML
version: 1
agent: {name: $AGENT_NAME, display_name: "vault e2e 🧪", role: "test", vibe: "terse"}
user: {name: "Tester", nickname: "Tester", timezone: "UTC", email: "t@e.x", language: "en"}
deployment: {host: "test", workspace: "$DEST", install_service: false, claude_cli: "claude"}
docker: {image_tag: "agent-admin:vault-e2e", uid: $(id -u), gid: $(id -g), state_volume: "${AGENT_NAME}-state", base_image: "alpine:3.20"}
claude: {config_dir: "/home/agent/.claude", profile_new: true}
notifications: {channel: none}
features:
  heartbeat: {enabled: true, interval: "30m", timeout: 30, retries: 0, default_prompt: "echo pong"}
mcps: {defaults: [], atlassian: [], github: {enabled: false, email: ""}}
vault:
  enabled: true
  path: .state/.vault
  seed_skeleton: true
  initial_sources: []
  mcp:
    enabled: true
    server: vault
  schema:
    frontmatter_required: true
    log_format: "## [{date}] {op} | {title}"
plugins: []
YML
  cp -R "$REPO_ROOT/modules" "$REPO_ROOT/scripts" "$REPO_ROOT/docker" "$DEST/"
  cp "$REPO_ROOT/setup.sh" "$DEST/"
  chmod +x "$DEST/setup.sh"

  # 2) regenerate derived files (renders docker-compose.yml + .mcp.json + CLAUDE.md
  #    + mirrors vault-skeleton/ + vault.sh into docker/ for the build context)
  (cd "$DEST" && ./setup.sh --regenerate --non-interactive)

  # 3) seed an empty .env (compose requires the file to exist)
  touch "$DEST/.env"
  chmod 0600 "$DEST/.env"

  # 4) claude stub so the watchdog respawn loop stays alive long enough for
  #    boot_side_effects → seed_vault_if_needed to run. The stub never exits
  #    so the watchdog sees a long-running tmux session.
  mkdir -p "$DEST/bin"
  cat > "$DEST/bin/claude" <<'CL'
#!/bin/bash
# vault e2e stub — sleep forever so the watchdog stops respawning
exec sleep 86400
CL
  chmod +x "$DEST/bin/claude"

  # 5) bind-mount the stub onto /usr/local/bin/claude inside the container
  python3 - "$DEST/docker-compose.yml" <<'PY'
import sys
path = sys.argv[1]
txt = open(path).read()
needle = '      - ./:/workspace'
inject = '      - ./bin/claude:/usr/local/bin/claude:ro'
if inject not in txt:
    txt = txt.replace(needle, needle + '\n' + inject, 1)
open(path, 'w').write(txt)
PY

  # 6) build + up
  (cd "$DEST" && docker compose build)
  (cd "$DEST" && docker compose up -d)

  # 7) wait up to 60s for seed_vault_if_needed to run via boot_side_effects.
  #    The seed fires synchronously during start_services.sh's first pass.
  #    We probe inside the container rather than on the host because macOS
  #    Docker Desktop's bind-mount propagation is async and asserts on
  #    `<host>/.state/...` can race the host fsync.
  local deadline=$(( $(date +%s) + 60 ))
  local seeded=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if (cd "$DEST" && docker compose exec -T -u agent "$AGENT_NAME" \
          test -f /home/agent/.vault/CLAUDE.md) 2>/dev/null; then
      seeded=1
      break
    fi
    sleep 2
  done
  if [ "$seeded" -ne 1 ]; then
    echo "--- container logs ---" >&2
    (cd "$DEST" && docker compose logs --tail=80 2>&1) >&2 || true
    echo "--- vault dir inside container ---" >&2
    (cd "$DEST" && docker compose exec -T -u agent "$AGENT_NAME" \
        ls -la /home/agent/.vault/ 2>&1) >&2 || true
  fi
  [ "$seeded" -eq 1 ]

  # 8) skeleton seeded — assertions inside the container
  in_container() {
    (cd "$DEST" && docker compose exec -T -u agent "$AGENT_NAME" "$@")
  }
  run in_container test -f /home/agent/.vault/CLAUDE.md
  [ "$status" -eq 0 ]
  run in_container grep -q Karpathy /home/agent/.vault/CLAUDE.md
  [ "$status" -eq 0 ]
  run in_container test -d /home/agent/.vault/raw_sources
  [ "$status" -eq 0 ]
  run in_container test -d /home/agent/.vault/wiki/concepts
  [ "$status" -eq 0 ]
  run in_container test -d /home/agent/.vault/wiki/synthesis
  [ "$status" -eq 0 ]
  run in_container test -f /home/agent/.vault/_templates/summary.md
  [ "$status" -eq 0 ]

  # 9) SCAFFOLD_DATE was replaced with a real date in log.md
  run in_container sh -c '! grep -q SCAFFOLD_DATE /home/agent/.vault/log.md'
  [ "$status" -eq 0 ]
  run in_container sh -c 'grep -qE "## \[[0-9]{4}-[0-9]{2}-[0-9]{2}\] init" /home/agent/.vault/log.md'
  [ "$status" -eq 0 ]

  # 10) symlink /home/agent/vault → /home/agent/.vault exists inside the container
  run in_container sh -c '[ -L /home/agent/vault ] && [ "$(readlink /home/agent/vault)" = /home/agent/.vault ]'
  [ "$status" -eq 0 ]

  # 11) .mcp.json (host-side, written by setup.sh --regenerate) carries the
  #     vault server with the right args. This file is at the workspace root,
  #     not under .state/, so host visibility is direct (no bind-mount race).
  [ -f "$DEST/.mcp.json" ]
  run jq -e '.mcpServers.vault' "$DEST/.mcp.json"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.mcpServers.vault.command' "$DEST/.mcp.json")" = "npx" ]
  [ "$(jq -r '.mcpServers.vault.args[1]' "$DEST/.mcp.json")" = "@bitbonsai/mcpvault@latest" ]
  [ "$(jq -r '.mcpServers.vault.args[2]' "$DEST/.mcp.json")" = "/home/agent/.vault" ]

  # 12) idempotency: a second boot must NOT re-seed an existing vault.
  #     Drop a marker inside the container, restart, confirm marker survived.
  in_container sh -c 'echo user-content-marker > /home/agent/.vault/raw_sources/user-note.md'
  (cd "$DEST" && docker compose restart)
  # Wait for the container to be ready again
  local ready_deadline=$(( $(date +%s) + 30 ))
  while [ "$(date +%s)" -lt "$ready_deadline" ]; do
    if (cd "$DEST" && docker compose exec -T -u agent "$AGENT_NAME" \
          test -f /home/agent/.vault/raw_sources/user-note.md) 2>/dev/null; then
      break
    fi
    sleep 2
  done
  run in_container grep -q "user-content-marker" /home/agent/.vault/raw_sources/user-note.md
  [ "$status" -eq 0 ]
}
