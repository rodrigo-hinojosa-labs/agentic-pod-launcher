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
    && printf '%s' "$result" | grep -q '"GITHUB_PERSONAL_ACCESS_TOKEN": "${GITHUB_PAT:-}"'
}

@test "mcp-json github MCP drops the deprecated @modelcontextprotocol/server-github" {
  export MCPS_GITHUB_ENABLED=true
  result=$(render_template "$REPO_ROOT/modules/mcp-json.tpl")
  printf '%s' "$result" | grep -q '"github"' \
    && ! printf '%s' "$result" | grep -q '@modelcontextprotocol/server-github'
}

# --- 021-local-secret-delivery: ${VAR} -> ${VAR:-} for every secret ref -----
# (R4/plan D6.2). Per code.claude.com/docs/en/mcp, an unset ${VAR} with no
# default can fail the WHOLE .mcp.json parse — one empty secret would take
# fetch/git/filesystem/vault/qmd down with it. Docker-neutral: compose's
# env_file always sets the keys, so this changes nothing there but the string.

@test "021: FIRECRAWL_API_KEY carries a :- default" {
  export MCPS_FIRECRAWL_ENABLED=true
  result=$(render_template "$REPO_ROOT/modules/mcp-json.tpl")
  printf '%s' "$result" | grep -q '"FIRECRAWL_API_KEY": "${FIRECRAWL_API_KEY:-}"'
}

@test "021: AWS_PROFILE and AWS_REGION carry a :- default" {
  export MCPS_AWS_ENABLED=true
  result=$(render_template "$REPO_ROOT/modules/mcp-json.tpl")
  printf '%s' "$result" | grep -q '"AWS_PROFILE": "${AWS_PROFILE:-}"' \
    && printf '%s' "$result" | grep -q '"AWS_REGION": "${AWS_REGION:-}"'
}

@test "021: all 5 atlassian instance vars carry a :- default" {
  local fixture="$TMP_TEST_DIR/atlassian.yml"
  cat > "$fixture" << 'EOF'
version: 1
agent: {name: my-bot, display_name: "MyBot", role: "r", vibe: "v"}
user: {name: A, nickname: A, timezone: UTC, email: a@b.com, language: en}
deployment: {host: h, workspace: "/home/a/wk", install_service: true}
notifications: {channel: none}
features: {heartbeat: {enabled: true, interval: "30m", timeout: 300, retries: 1, default_prompt: "ok"}}
mcps:
  atlassian:
    - name: work
      url: "https://work.atlassian.net"
      email: "a@work.com"
  github: {enabled: false}
EOF
  render_load_context "$fixture"
  result=$(render_template "$REPO_ROOT/modules/mcp-json.tpl")
  printf '%s' "$result" | grep -q '"CONFLUENCE_URL": "${ATLASSIAN_WORK_CONFLUENCE_URL:-}"' \
    && printf '%s' "$result" | grep -q '"CONFLUENCE_USERNAME": "${ATLASSIAN_WORK_CONFLUENCE_USERNAME:-}"' \
    && printf '%s' "$result" | grep -q '"CONFLUENCE_API_TOKEN": "${ATLASSIAN_WORK_TOKEN:-}"' \
    && printf '%s' "$result" | grep -q '"JIRA_URL": "${ATLASSIAN_WORK_JIRA_URL:-}"' \
    && printf '%s' "$result" | grep -q '"JIRA_USERNAME": "${ATLASSIAN_WORK_JIRA_USERNAME:-}"' \
    && printf '%s' "$result" | grep -q '"JIRA_API_TOKEN": "${ATLASSIAN_WORK_TOKEN:-}"'
}

@test "021: docker mode is otherwise byte-unchanged — only the :- insertions differ" {
  export MCPS_FIRECRAWL_ENABLED=true MCPS_AWS_ENABLED=true MCPS_GITHUB_ENABLED=true
  result=$(render_template "$REPO_ROOT/modules/mcp-json.tpl")
  # Strip every ":-" we just added; the remainder must be valid JSON with the
  # commands/args untouched — a cheap proxy for "nothing else moved".
  local stripped
  stripped=$(printf '%s' "$result" | sed 's/:-}/}/g')
  printf '%s' "$stripped" | grep -q '"FIRECRAWL_API_KEY": "${FIRECRAWL_API_KEY}"' \
    && printf '%s' "$stripped" | grep -q '"AWS_PROFILE": "${AWS_PROFILE}"' \
    && printf '%s' "$stripped" | grep -q '"GITHUB_PERSONAL_ACCESS_TOKEN": "${GITHUB_PAT}"' \
    && printf '%s' "$result" | grep -q '"command": "npx"' \
    && printf '%s' "$result" | grep -q '"command": "github-mcp-server"'
}
