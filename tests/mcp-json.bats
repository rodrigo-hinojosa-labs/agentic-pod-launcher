#!/usr/bin/env bats

load helper

setup() {
  setup_tmp_dir
  load_lib yaml
  load_lib render
}

teardown() { teardown_tmp_dir; }

@test ".mcp.json has defaults and one atlassian workspace" {
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
  [ "$(echo "$result" | jq -r '.mcpServers.playwright.command')" = "npx" ]
  [ "$(echo "$result" | jq -r '.mcpServers.time.args[1]')" = "--local-timezone=America/Santiago" ]
  [ "$(echo "$result" | jq -r '.mcpServers["atlassian-personal"].env.CONFLUENCE_URL')" = '${ATLASSIAN_PERSONAL_CONFLUENCE_URL}' ]
  [ "$(echo "$result" | jq -r '.mcpServers["atlassian-personal"].env.CONFLUENCE_USERNAME')" = '${ATLASSIAN_PERSONAL_CONFLUENCE_USERNAME}' ]
  [ "$(echo "$result" | jq -r '.mcpServers["atlassian-personal"].env.CONFLUENCE_API_TOKEN')" = '${ATLASSIAN_PERSONAL_TOKEN}' ]
  [ "$(echo "$result" | jq -r '.mcpServers["atlassian-personal"].env.JIRA_URL')" = '${ATLASSIAN_PERSONAL_JIRA_URL}' ]
  [ "$(echo "$result" | jq -r '.mcpServers["atlassian-personal"].env.JIRA_USERNAME')" = '${ATLASSIAN_PERSONAL_JIRA_USERNAME}' ]
  [ "$(echo "$result" | jq -r '.mcpServers["atlassian-personal"].env.JIRA_API_TOKEN')" = '${ATLASSIAN_PERSONAL_TOKEN}' ]
  [ "$(echo "$result" | jq -r '.mcpServers.github // "absent"')" = "absent" ]
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
