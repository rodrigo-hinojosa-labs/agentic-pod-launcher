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
  # Docker mode is the production default; the mode boolean is always exported by
  # regenerate() before .mcp.json is rendered. Declare it so the git/filesystem
  # container paths (/workspace, /home/agent) are asserted for the docker branch.
  export DEPLOYMENT_MODE_IS_DOCKER=true
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
  # Atlassian workspace iterated from agent.yml.
  # 021: every secret ref carries a :- default (an unset var must not fail
  # the whole .mcp.json parse — see modules/mcp-json.tpl).
  [ "$(echo "$result" | jq -r '.mcpServers["atlassian-personal"].env.CONFLUENCE_URL')" = '${ATLASSIAN_PERSONAL_CONFLUENCE_URL:-}' ]
  [ "$(echo "$result" | jq -r '.mcpServers["atlassian-personal"].env.CONFLUENCE_USERNAME')" = '${ATLASSIAN_PERSONAL_CONFLUENCE_USERNAME:-}' ]
  [ "$(echo "$result" | jq -r '.mcpServers["atlassian-personal"].env.CONFLUENCE_API_TOKEN')" = '${ATLASSIAN_PERSONAL_TOKEN:-}' ]
  [ "$(echo "$result" | jq -r '.mcpServers["atlassian-personal"].env.JIRA_URL')" = '${ATLASSIAN_PERSONAL_JIRA_URL:-}' ]
  [ "$(echo "$result" | jq -r '.mcpServers["atlassian-personal"].env.JIRA_USERNAME')" = '${ATLASSIAN_PERSONAL_JIRA_USERNAME:-}' ]
  [ "$(echo "$result" | jq -r '.mcpServers["atlassian-personal"].env.JIRA_API_TOKEN')" = '${ATLASSIAN_PERSONAL_TOKEN:-}' ]
  [ "$(echo "$result" | jq -r '.mcpServers.github // "absent"')" = "absent" ]
}

@test ".mcp.json (local mode) points git + filesystem at the host workspace, not container paths" {
  # RC-C: in docker mode git targets /workspace and filesystem /home/agent (the
  # container mount points). In local mode those paths do not exist on the host —
  # they must resolve to the real deployment.workspace or the MCPs fail to connect
  # (validated on mclaren: `git --repository /workspace` → ✘ Failed to connect).
  cat > "$TMP_TEST_DIR/agent.yml" << 'EOF'
version: 1
user:
  timezone: "UTC"
deployment:
  workspace: "/home/op/agents/locbot"
  mode: local
mcps:
  atlassian: []
  github:
    enabled: false
EOF
  render_load_context "$TMP_TEST_DIR/agent.yml"
  export DEPLOYMENT_MODE_IS_DOCKER=false
  result=$(render_template "$REPO_ROOT/modules/mcp-json.tpl")
  echo "$result" | jq . > /dev/null
  # git repository + filesystem root are remapped to the host workspace.
  [ "$(echo "$result" | jq -r '.mcpServers.git.args[2]')" = "/home/op/agents/locbot" ]
  [ "$(echo "$result" | jq -r '.mcpServers.filesystem.args[2]')" = "/home/op/agents/locbot" ]
  # container paths must NOT leak into local mode
  [ "$(echo "$result" | jq -r '.mcpServers.git.args[2]')" != "/workspace" ]
  [ "$(echo "$result" | jq -r '.mcpServers.filesystem.args[2]')" != "/home/agent" ]
  # command + package unchanged across modes
  [ "$(echo "$result" | jq -r '.mcpServers.git.command')" = "uvx" ]
  [ "$(echo "$result" | jq -r '.mcpServers.filesystem.command')" = "npx" ]
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
  [ "$(echo "$result" | jq -r '.mcpServers.firecrawl.env.FIRECRAWL_API_KEY')" = '${FIRECRAWL_API_KEY:-}' ]
  unset MCPS_PLAYWRIGHT_ENABLED MCPS_TIME_ENABLED MCPS_FIRECRAWL_ENABLED
}

@test ".mcp.json google-calendar creds path is mode-resolved (012 T032)" {
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
  export MCPS_GOOGLE_CALENDAR_ENABLED=true
  # docker
  export GCAL_CREDS_PATH="/home/agent/.gcal/gcp-oauth.keys.json"
  local docker_result; docker_result=$(render_template "$REPO_ROOT/modules/mcp-json.tpl")
  echo "$docker_result" | jq . > /dev/null
  [ "$(echo "$docker_result" | jq -r '.mcpServers["google-calendar"].env.GOOGLE_OAUTH_CREDENTIALS')" = "/home/agent/.gcal/gcp-oauth.keys.json" ]
  # local
  export GCAL_CREDS_PATH="/home/op/agents/locbot/.state/.gcal/gcp-oauth.keys.json"
  local local_result; local_result=$(render_template "$REPO_ROOT/modules/mcp-json.tpl")
  [ "$(echo "$local_result" | jq -r '.mcpServers["google-calendar"].env.GOOGLE_OAUTH_CREDENTIALS')" = "/home/op/agents/locbot/.state/.gcal/gcp-oauth.keys.json" ]
  unset MCPS_GOOGLE_CALENDAR_ENABLED GCAL_CREDS_PATH
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
  [ "$(echo "$result" | jq -r '.mcpServers.github.command')" = "github-mcp-server" ]
  [ "$(echo "$result" | jq -r '.mcpServers.github.args[0]')" = "stdio" ]
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
  # docker mode resolves the vault MCP arg to /home/agent/.vault (precomputed in
  # setup.sh; byte-identical to before).
  export VAULT_MCP_PATH="/home/agent/.vault"
  result=$(render_template "$REPO_ROOT/modules/mcp-json.tpl")
  echo "$result" | jq . > /dev/null
  [ "$(echo "$result" | jq -r '.mcpServers.vault.command')" = "npx" ]
  [ "$(echo "$result" | jq -r '.mcpServers.vault.args[0]')" = "-y" ]
  [ "$(echo "$result" | jq -r '.mcpServers.vault.args[1]')" = "@bitbonsai/mcpvault@0.12.0" ]
  [ "$(echo "$result" | jq -r '.mcpServers.vault.args[2]')" = "/home/agent/.vault" ]
  [ "$(echo "$result" | jq -r '.mcpServers.vault.env')" = "{}" ]
}

@test ".mcp.json (local mode) points the vault MCP at the workspace vault, not /home/agent (012 T009)" {
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
  # local mode: setup.sh sets VAULT_MCP_PATH to the resolved workspace vault dir.
  export VAULT_MCP_PATH="/home/op/agents/locbot/.state/.vault"
  result=$(render_template "$REPO_ROOT/modules/mcp-json.tpl")
  echo "$result" | jq . > /dev/null
  [ "$(echo "$result" | jq -r '.mcpServers.vault.command')" = "npx" ]
  [ "$(echo "$result" | jq -r '.mcpServers.vault.args[2]')" = "/home/op/agents/locbot/.state/.vault" ]
  [ "$(echo "$result" | jq -r '.mcpServers.vault.args[2]')" != "/home/agent/.vault" ]
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
  [ "$(echo "$result" | jq -r '.mcpServers.github.command')" = "github-mcp-server" ]
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
    version: "2.5.3"
EOF
  render_load_context "$TMP_TEST_DIR/agent.yml"
  # docker mode: setup.sh precomputes QMD_MCP_ENV="{}" and the image-baked wrapper
  # path (016 T036: the MCP launches from the managed prefix, never `bunx`).
  export QMD_MCP_ENV="{}"
  export QMD_MCP_COMMAND="/opt/agent-admin/scripts/qmd-mcp"
  result=$(render_template "$REPO_ROOT/modules/mcp-json.tpl")
  echo "$result" | jq . > /dev/null
  [ "$(echo "$result" | jq -r '.mcpServers.qmd.command')" = "/opt/agent-admin/scripts/qmd-mcp" ]
  [ "$(echo "$result" | jq -r '.mcpServers.qmd.args | length')" = "0" ]
  [ "$(echo "$result" | jq -r '.mcpServers.qmd.env')" = "{}" ]
  # regression guard: the pre-016 bunx invocation must be gone (it repeats BUG 4).
  [ "$(echo "$result" | jq -r '.mcpServers.qmd.command')" != "bunx" ]
  unset QMD_MCP_ENV QMD_MCP_COMMAND
}

@test ".mcp.json (local mode) qmd env pins XDG_CACHE_HOME + QMD_CONFIG_DIR under the workspace (013 US1/T003)" {
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
    version: "2.5.3"
EOF
  render_load_context "$TMP_TEST_DIR/agent.yml"
  # local mode: setup.sh sets the reader env so the MCP resolves the SAME storage
  # as the reindex writer (the atomic pair — fixing only one silently empties RAG).
  export QMD_MCP_ENV='{"XDG_CACHE_HOME": "/home/op/agents/locbot/.state/.cache", "QMD_CONFIG_DIR": "/home/op/agents/locbot/.state/.config/qmd"}'
  result=$(render_template "$REPO_ROOT/modules/mcp-json.tpl")
  echo "$result" | jq . > /dev/null
  [ "$(echo "$result" | jq -r '.mcpServers.qmd.env.XDG_CACHE_HOME')" = "/home/op/agents/locbot/.state/.cache" ]
  [ "$(echo "$result" | jq -r '.mcpServers.qmd.env.QMD_CONFIG_DIR')" = "/home/op/agents/locbot/.state/.config/qmd" ]
  # must NOT leak the container/home default
  [ "$(echo "$result" | jq -r '.mcpServers.qmd.env.XDG_CACHE_HOME')" != "/home/agent/.cache" ]
  unset QMD_MCP_ENV
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
    version: "2.5.3"
EOF
  render_load_context "$TMP_TEST_DIR/agent.yml"
  export QMD_MCP_ENV="{}"
  export QMD_MCP_COMMAND="/opt/agent-admin/scripts/qmd-mcp"
  result=$(render_template "$REPO_ROOT/modules/mcp-json.tpl")
  echo "$result" | jq . > /dev/null
  [ "$(echo "$result" | jq -r '.mcpServers["atlassian-work"].command')" = "uvx" ]
  [ "$(echo "$result" | jq -r '.mcpServers.github.command')" = "github-mcp-server" ]
  [ "$(echo "$result" | jq -r '.mcpServers.vault.command')" = "npx" ]
  [ "$(echo "$result" | jq -r '.mcpServers.qmd.command')" = "/opt/agent-admin/scripts/qmd-mcp" ]
  unset QMD_MCP_ENV QMD_MCP_COMMAND
}

@test ".mcp.json (local mode) qmd command is the rendered workspace wrapper, not bunx (016 T036)" {
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
    version: "2.5.3"
EOF
  render_load_context "$TMP_TEST_DIR/agent.yml"
  # local mode: setup.sh precomputes the workspace wrapper path (which reuses
  # qmd_index.sh::qmd_mcp_exec against the managed prefix) — never `bunx`.
  export QMD_MCP_ENV='{"XDG_CACHE_HOME": "/home/op/agents/locbot/.state/.cache", "QMD_CONFIG_DIR": "/home/op/agents/locbot/.state/.config/qmd"}'
  export QMD_MCP_COMMAND="/home/op/agents/locbot/scripts/local/agent-qmd-mcp.sh"
  result=$(render_template "$REPO_ROOT/modules/mcp-json.tpl")
  echo "$result" | jq . > /dev/null
  [ "$(echo "$result" | jq -r '.mcpServers.qmd.command')" = "/home/op/agents/locbot/scripts/local/agent-qmd-mcp.sh" ]
  [ "$(echo "$result" | jq -r '.mcpServers.qmd.args | length')" = "0" ]
  # regression guard: never bunx (it repeats BUG 4 on Alpine and splits the prefix).
  [ "$(echo "$result" | jq -r '.mcpServers.qmd.command')" != "bunx" ]
  unset QMD_MCP_ENV QMD_MCP_COMMAND
}
