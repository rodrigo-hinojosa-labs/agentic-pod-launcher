#!/usr/bin/env bats
# Feature 004 US3 (DOCKER_E2E) — the GitHub MCP runs via GitHub's official
# github-mcp-server Go binary (statically linked, baked into /usr/local/bin),
# replacing the deprecated @modelcontextprotocol/server-github npx package.
#
# Skipped by default (slow + requires Docker). Enable with DOCKER_E2E=1.
# Builds the image from the repo docker/ context and probes the binary; the
# full MCP handshake with a live token is left to a real scaffold.

load helper

setup() {
  if [ "${DOCKER_E2E:-0}" != "1" ]; then skip "set DOCKER_E2E=1 to run"; fi
  TMPDIR=/tmp setup_tmp_dir
  export DEST="$TMP_TEST_DIR/agent-github-e2e"
  export AGENT_NAME="github-e2e"
}

teardown() {
  if [ -d "$DEST" ]; then
    (cd "$DEST" && docker compose down -v --remove-orphans || true)
  fi
  teardown_tmp_dir
}

@test "github-mcp-server: pinned binary runs in the built image and .mcp.json uses stdio form" {
  mkdir -p "$DEST"
  cat > "$DEST/agent.yml" <<YML
version: 1
agent: {name: $AGENT_NAME, display_name: "github e2e 🐙", role: "test", vibe: "terse"}
user: {name: "Tester", nickname: "Tester", timezone: "UTC", email: "t@e.x", language: "en"}
deployment: {host: "test", workspace: "$DEST", install_service: false, claude_cli: "claude"}
docker: {image_tag: "agent-admin:github-e2e", uid: $(id -u), gid: $(id -g), state_volume: "${AGENT_NAME}-state", base_image: "alpine:3.24.1"}
claude: {config_dir: "/home/agent/.claude", profile_new: true}
notifications: {channel: none}
features:
  heartbeat: {enabled: true, interval: "30m", timeout: 30, retries: 0, default_prompt: "echo pong"}
mcps: {defaults: [], atlassian: [], github: {enabled: true, email: "t@e.x"}}
vault: {enabled: false}
plugins: []
YML
  cp -R "$REPO_ROOT/modules" "$REPO_ROOT/scripts" "$REPO_ROOT/docker" "$DEST/"
  cp "$REPO_ROOT/setup.sh" "$DEST/"
  chmod +x "$DEST/setup.sh"
  (cd "$DEST" && ./setup.sh --regenerate --non-interactive)
  touch "$DEST/.env"; chmod 0600 "$DEST/.env"

  (cd "$DEST" && docker compose build)

  # 1) the statically-linked binary runs on Alpine/musl (exit 0). Override the
  #    image ENTRYPOINT (tini→entrypoint.sh→watchdog) so the CMD actually runs.
  run bash -c "cd '$DEST' && docker compose run --rm --entrypoint github-mcp-server -u agent '$AGENT_NAME' --version"
  [ "$status" -eq 0 ]

  # 2) it lives off the bind-mount so a .state clone can't shadow it.
  run bash -c "cd '$DEST' && docker compose run --rm --entrypoint sh -u agent '$AGENT_NAME' -lc 'command -v github-mcp-server'"
  [[ "$output" == *"/usr/local/bin/github-mcp-server"* ]]

  # 3) the rendered host-side .mcp.json uses the binary stdio form, not npx.
  [ -f "$DEST/.mcp.json" ]
  [ "$(jq -r '.mcpServers.github.command' "$DEST/.mcp.json")" = "github-mcp-server" ]
  [ "$(jq -r '.mcpServers.github.args[0]' "$DEST/.mcp.json")" = "stdio" ]
  run jq -e '.mcpServers.github.env.GITHUB_PERSONAL_ACCESS_TOKEN' "$DEST/.mcp.json"
  [ "$status" -eq 0 ]
}
