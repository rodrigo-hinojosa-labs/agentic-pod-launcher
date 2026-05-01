#!/usr/bin/env bats

load helper

setup() {
  setup_tmp_dir
  load_lib yaml
  load_lib render
}

teardown() { teardown_tmp_dir; }

@test ".mcp.json has 3 always-on defaults (fetch, git, filesystem) and one atlassian workspace" {
  cat > "$TMP_TEST_DIR/agent.yml" << 'EOF'
version: 1
user:
  timezone: "America/Santiago"
mcps:
  atlassian:
    - name: personal
      url: "https://personal.atlassian.net"
      email: "a@b.com"
  github:
    enabled: false
EOF
  render_load_context "$TMP_TEST_DIR/agent.yml"
  result=$(render_template "$REPO_ROOT/modules/mcp-json.tpl")
  echo "$result" | jq . > /dev/null
  # Always-on (no flag needed in env): fetch, git, filesystem.
  [ "$(echo "$result" | jq -r '.mcpServers.fetch.command')" = "uvx" ]
  [ "$(echo "$result" | jq -r '.mcpServers.fetch.args[0]')" = "mcp-server-fetch" ]
  [ "$(echo "$result" | jq -r '.mcpServers.git.command')" = "uvx" ]
  [ "$(echo "$result" | jq -r '.mcpServers.git.args[0]')" = "mcp-server-git" ]
  [ "$(echo "$result" | jq -r '.mcpServers.git.args[2]')" = "/workspace" ]
  [ "$(echo "$result" | jq -r '.mcpServers.filesystem.command')" = "npx" ]
  [ "$(echo "$result" | jq -r '.mcpServers.filesystem.args[0]')" = "-y" ]
  [ "$(echo "$result" | jq -r '.mcpServers.filesystem.args[1]')" = "@modelcontextprotocol/server-filesystem" ]
  [ "$(echo "$result" | jq -r '.mcpServers.filesystem.args[2]')" = "/home/agent" ]
  # Optional (env-gated) defaults are absent when no MCPS_*_ENABLED is set.
  [ "$(echo "$result" | jq -r '.mcpServers.playwright // "absent"')" = "absent" ]
  [ "$(echo "$result" | jq -r '.mcpServers.time // "absent"')" = "absent" ]
  [ "$(echo "$result" | jq -r '.mcpServers["sequential-thinking"] // "absent"')" = "absent" ]
  # Atlassian workspace iterated from agent.yml.
  [ "$(echo "$result" | jq -r '.mcpServers["atlassian-personal"].env.CONFLUENCE_URL')" = '${ATLASSIAN_PERSONAL_CONFLUENCE_URL}' ]
  [ "$(echo "$result" | jq -r '.mcpServers["atlassian-personal"].env.CONFLUENCE_USERNAME')" = '${ATLASSIAN_PERSONAL_CONFLUENCE_USERNAME}' ]
  [ "$(echo "$result" | jq -r '.mcpServers["atlassian-personal"].env.CONFLUENCE_API_TOKEN')" = '${ATLASSIAN_PERSONAL_TOKEN}' ]
  [ "$(echo "$result" | jq -r '.mcpServers["atlassian-personal"].env.JIRA_URL')" = '${ATLASSIAN_PERSONAL_JIRA_URL}' ]
  [ "$(echo "$result" | jq -r '.mcpServers["atlassian-personal"].env.JIRA_USERNAME')" = '${ATLASSIAN_PERSONAL_JIRA_USERNAME}' ]
  [ "$(echo "$result" | jq -r '.mcpServers["atlassian-personal"].env.JIRA_API_TOKEN')" = '${ATLASSIAN_PERSONAL_TOKEN}' ]
  [ "$(echo "$result" | jq -r '.mcpServers.github // "absent"')" = "absent" ]
}

@test ".mcp.json includes optional MCPs when MCPS_*_ENABLED env vars are set" {
  cat > "$TMP_TEST_DIR/agent.yml" << 'EOF'
version: 1
user:
  timezone: "America/Santiago"
mcps:
  atlassian: []
  github:
    enabled: false
EOF
  render_load_context "$TMP_TEST_DIR/agent.yml"
  export MCPS_PLAYWRIGHT_ENABLED=true
  export MCPS_TIME_ENABLED=true
  export MCPS_FIRECRAWL_ENABLED=true
  result=$(render_template "$REPO_ROOT/modules/mcp-json.tpl")
  echo "$result" | jq . > /dev/null
  [ "$(echo "$result" | jq -r '.mcpServers.playwright.command')" = "npx" ]
  [ "$(echo "$result" | jq -r '.mcpServers.time.args[1]')" = "--local-timezone=America/Santiago" ]
  [ "$(echo "$result" | jq -r '.mcpServers.firecrawl.command')" = "npx" ]
  [ "$(echo "$result" | jq -r '.mcpServers.firecrawl.env.FIRECRAWL_API_KEY')" = '${FIRECRAWL_API_KEY}' ]
  unset MCPS_PLAYWRIGHT_ENABLED MCPS_TIME_ENABLED MCPS_FIRECRAWL_ENABLED
}

@test ".mcp.json has github when enabled" {
  cat > "$TMP_TEST_DIR/agent.yml" << 'EOF'
version: 1
user:
  timezone: "UTC"
mcps:
  atlassian: []
  github:
    enabled: true
EOF
  render_load_context "$TMP_TEST_DIR/agent.yml"
  result=$(render_template "$REPO_ROOT/modules/mcp-json.tpl")
  echo "$result" | jq . > /dev/null
  [ "$(echo "$result" | jq -r '.mcpServers.github.command')" = "npx" ]
}

@test ".mcp.json has vault MCP when vault.mcp.enabled is true" {
  cat > "$TMP_TEST_DIR/agent.yml" << 'EOF'
version: 1
user:
  timezone: "UTC"
mcps:
  atlassian: []
  github:
    enabled: false
vault:
  enabled: true
  mcp:
    enabled: true
EOF
  render_load_context "$TMP_TEST_DIR/agent.yml"
  result=$(render_template "$REPO_ROOT/modules/mcp-json.tpl")
  echo "$result" | jq . > /dev/null
  [ "$(echo "$result" | jq -r '.mcpServers.vault.command')" = "npx" ]
  [ "$(echo "$result" | jq -r '.mcpServers.vault.args[0]')" = "-y" ]
  [ "$(echo "$result" | jq -r '.mcpServers.vault.args[1]')" = "@bitbonsai/mcpvault@latest" ]
  [ "$(echo "$result" | jq -r '.mcpServers.vault.args[2]')" = "/home/agent/.vault" ]
  [ "$(echo "$result" | jq -r '.mcpServers.vault.env')" = "{}" ]
}

@test ".mcp.json omits vault MCP when vault.mcp.enabled is false" {
  cat > "$TMP_TEST_DIR/agent.yml" << 'EOF'
version: 1
user:
  timezone: "UTC"
mcps:
  atlassian: []
  github:
    enabled: false
vault:
  enabled: true
  mcp:
    enabled: false
EOF
  render_load_context "$TMP_TEST_DIR/agent.yml"
  result=$(render_template "$REPO_ROOT/modules/mcp-json.tpl")
  echo "$result" | jq . > /dev/null
  [ "$(echo "$result" | jq -r '.mcpServers.vault // "absent"')" = "absent" ]
}

@test ".mcp.json omits vault MCP when vault block is absent entirely" {
  cat > "$TMP_TEST_DIR/agent.yml" << 'EOF'
version: 1
user:
  timezone: "UTC"
mcps:
  atlassian: []
  github:
    enabled: false
EOF
  render_load_context "$TMP_TEST_DIR/agent.yml"
  result=$(render_template "$REPO_ROOT/modules/mcp-json.tpl")
  echo "$result" | jq . > /dev/null
  [ "$(echo "$result" | jq -r '.mcpServers.vault // "absent"')" = "absent" ]
}

@test ".mcp.json renders valid JSON with atlassian + github + vault all enabled" {
  cat > "$TMP_TEST_DIR/agent.yml" << 'EOF'
version: 1
user:
  timezone: "UTC"
mcps:
  atlassian:
    - name: work
      url: "https://work.atlassian.net"
      email: "x@y.com"
  github:
    enabled: true
vault:
  enabled: true
  mcp:
    enabled: true
EOF
  render_load_context "$TMP_TEST_DIR/agent.yml"
  result=$(render_template "$REPO_ROOT/modules/mcp-json.tpl")
  echo "$result" | jq . > /dev/null
  [ "$(echo "$result" | jq -r '.mcpServers["atlassian-work"].command')" = "uvx" ]
  [ "$(echo "$result" | jq -r '.mcpServers.github.command')" = "npx" ]
  [ "$(echo "$result" | jq -r '.mcpServers.vault.command')" = "npx" ]
}

@test ".mcp.json renders valid JSON with the sample-agent-with-vault fixture" {
  cp "$REPO_ROOT/tests/fixtures/sample-agent-with-vault.yml" "$TMP_TEST_DIR/agent.yml"
  render_load_context "$TMP_TEST_DIR/agent.yml"
  result=$(render_template "$REPO_ROOT/modules/mcp-json.tpl")
  echo "$result" | jq . > /dev/null
  [ "$(echo "$result" | jq -r '.mcpServers.vault.command')" = "npx" ]
}

@test ".mcp.json has QMD server when vault.qmd.enabled is true" {
  cat > "$TMP_TEST_DIR/agent.yml" << 'EOF'
version: 1
user:
  timezone: "UTC"
mcps:
  atlassian: []
  github:
    enabled: false
vault:
  enabled: true
  mcp:
    enabled: true
  qmd:
    enabled: true
EOF
  render_load_context "$TMP_TEST_DIR/agent.yml"
  result=$(render_template "$REPO_ROOT/modules/mcp-json.tpl")
  echo "$result" | jq . > /dev/null
  [ "$(echo "$result" | jq -r '.mcpServers.qmd.command')" = "bunx" ]
  [ "$(echo "$result" | jq -r '.mcpServers.qmd.args[0]')" = "@tobilu/qmd@latest" ]
  [ "$(echo "$result" | jq -r '.mcpServers.qmd.args[1]')" = "mcp" ]
  [ "$(echo "$result" | jq -r '.mcpServers.qmd.env')" = "{}" ]
}

@test ".mcp.json omits QMD server when vault.qmd.enabled is false" {
  cat > "$TMP_TEST_DIR/agent.yml" << 'EOF'
version: 1
user:
  timezone: "UTC"
mcps:
  atlassian: []
  github:
    enabled: false
vault:
  enabled: true
  mcp:
    enabled: true
  qmd:
    enabled: false
EOF
  render_load_context "$TMP_TEST_DIR/agent.yml"
  result=$(render_template "$REPO_ROOT/modules/mcp-json.tpl")
  echo "$result" | jq . > /dev/null
  [ "$(echo "$result" | jq -r '.mcpServers.qmd // "absent"')" = "absent" ]
  [ "$(echo "$result" | jq -r '.mcpServers.vault.command')" = "npx" ]
}

@test ".mcp.json renders valid JSON with vault MCP + QMD both enabled" {
  cat > "$TMP_TEST_DIR/agent.yml" << 'EOF'
version: 1
user:
  timezone: "UTC"
mcps:
  atlassian:
    - name: work
      url: "https://work.atlassian.net"
      email: "x@y.com"
  github:
    enabled: true
vault:
  enabled: true
  mcp:
    enabled: true
  qmd:
    enabled: true
EOF
  render_load_context "$TMP_TEST_DIR/agent.yml"
  result=$(render_template "$REPO_ROOT/modules/mcp-json.tpl")
  echo "$result" | jq . > /dev/null
  [ "$(echo "$result" | jq -r '.mcpServers["atlassian-work"].command')" = "uvx" ]
  [ "$(echo "$result" | jq -r '.mcpServers.github.command')" = "npx" ]
  [ "$(echo "$result" | jq -r '.mcpServers.vault.command')" = "npx" ]
  [ "$(echo "$result" | jq -r '.mcpServers.qmd.command')" = "bunx" ]
}
