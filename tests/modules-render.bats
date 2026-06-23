#!/usr/bin/env bats

load helper

setup() {
  setup_tmp_dir
  load_lib yaml
  load_lib render
  FIXTURE="$TMP_TEST_DIR/agent.yml"
  cat > "$FIXTURE" << 'EOF'
version: 1
agent:
  name: my-bot
  display_name: "MyBot 🤖"
  role: "r"
  vibe: "v"
user:
  name: "A"
  nickname: "A"
  timezone: "UTC"
  email: "a@b.com"
  language: "en"
deployment:
  host: "h"
  workspace: "/home/a/wk"
  install_service: true
notifications:
  channel: telegram
features:
  heartbeat:
    enabled: true
    interval: "30m"
    timeout: 300
    retries: 1
    default_prompt: "ok"
mcps:
  atlassian: []
  github:
    enabled: false
EOF
  render_load_context "$FIXTURE"
  export NOTIFICATIONS_CHANNEL_IS_TELEGRAM=true
  export HOME_DIR="/Users/test"
}

teardown() { teardown_tmp_dir; }

@test "env-example includes telegram and omits github" {
  result=$(render_template "$REPO_ROOT/modules/env-example.tpl")
  [[ "$result" == *"NOTIFY_BOT_TOKEN="* ]]
  [[ "$result" != *"GITHUB_PAT="* ]]
}

# 006-headless-bootstrap US1: the headless-auth token must be discoverable in
# the rendered .env skeleton (always, unconditionally) and never with a value.
@test "env-example exposes CLAUDE_CODE_OAUTH_TOKEN (headless auth) with no value" {
  result=$(render_template "$REPO_ROOT/modules/env-example.tpl")
  # grep-based (a failing intermediate [[ ]] does NOT fail a bats test here):
  # the variable must be present and never carry a baked value.
  printf '%s' "$result" | grep -q 'CLAUDE_CODE_OAUTH_TOKEN=' \
    && ! printf '%s' "$result" | grep -q 'CLAUDE_CODE_OAUTH_TOKEN=sk-'
}

@test "systemd.service has workspace and docker compose" {
  result=$(render_template "$REPO_ROOT/modules/systemd.service.tpl")
  [[ "$result" == *"WorkingDirectory=/home/a/wk"* ]]
  [[ "$result" == *"docker compose up -d"* ]]
}

@test "heartbeat-conf has interval" {
  result=$(render_template "$REPO_ROOT/modules/heartbeat-conf.tpl")
  [[ "$result" == *'HEARTBEAT_INTERVAL="30m"'* ]]
  [[ "$result" == *'NOTIFY_CHANNEL="telegram"'* ]]
}

# --- Feature 004 US1: vault npx MCP spec is pinned (warm-cache match) ------

@test "mcp-json renders the vault MCP with a pinned spec (no @latest)" {
  export VAULT_MCP_ENABLED=true
  result=$(render_template "$REPO_ROOT/modules/mcp-json.tpl")
  # Last expression is the real assert (bats intermediate-cmd quirk): the
  # pinned spec must be present and the @latest dist-tag form must be gone —
  # @latest defeats the build-time warm hit even under prefer-offline.
  printf '%s' "$result" | grep -q '@bitbonsai/mcpvault@0.12.0' \
    && ! printf '%s' "$result" | grep -q '@bitbonsai/mcpvault@latest'
}

@test "mcp-json vault pin is single-sourced from the versions.sh floor (drift guard)" {
  load_lib versions
  local tpl="$REPO_ROOT/modules/mcp-json.tpl"
  grep -q "@bitbonsai/mcpvault@${AGENTIC_FLOOR_MCP_VAULT}" "$tpl" \
    && ! grep -q '@bitbonsai/mcpvault@latest' "$tpl"
}

# --- Feature 004 US3: github MCP uses the maintained github-mcp-server binary -

@test "mcp-json renders the github MCP via the maintained github-mcp-server binary (stdio)" {
  export MCPS_GITHUB_ENABLED=true
  result=$(render_template "$REPO_ROOT/modules/mcp-json.tpl")
  printf '%s' "$result" | grep -q '"command": "github-mcp-server"' \
    && printf '%s' "$result" | grep -q '"stdio"' \
    && printf '%s' "$result" | grep -q '"GITHUB_PERSONAL_ACCESS_TOKEN": "${GITHUB_PAT}"'
}

@test "mcp-json github MCP drops the deprecated @modelcontextprotocol/server-github" {
  export MCPS_GITHUB_ENABLED=true
  result=$(render_template "$REPO_ROOT/modules/mcp-json.tpl")
  printf '%s' "$result" | grep -q '"github"' \
    && ! printf '%s' "$result" | grep -q '@modelcontextprotocol/server-github'
}
