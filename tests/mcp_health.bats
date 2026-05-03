#!/usr/bin/env bats

load helper

setup() {
  setup_tmp_dir
  source "$REPO_ROOT/docker/scripts/lib/mcp-health.sh"
}
teardown() { teardown_tmp_dir; }

# Helper: write a representative .mcp.json for a test, plus a .env
# with the variables the test scenario expects to be present.
_setup_mcp_json() {
  cat > "$TMP_TEST_DIR/.mcp.json" <<'JSON'
{
  "mcpServers": {
    "fetch": {
      "command": "uvx",
      "args": ["mcp-server-fetch"]
    },
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/home/agent"]
    },
    "firecrawl": {
      "command": "npx",
      "args": ["-y", "firecrawl-mcp"],
      "env": {
        "FIRECRAWL_API_KEY": "${FIRECRAWL_API_KEY}"
      }
    },
    "atlassian-personal": {
      "command": "uvx",
      "args": ["mcp-atlassian"],
      "env": {
        "CONFLUENCE_URL": "${ATLASSIAN_PERSONAL_CONFLUENCE_URL}",
        "JIRA_URL": "${ATLASSIAN_PERSONAL_JIRA_URL}",
        "CONFLUENCE_API_TOKEN": "${ATLASSIAN_PERSONAL_TOKEN}",
        "JIRA_API_TOKEN": "${ATLASSIAN_PERSONAL_TOKEN}"
      }
    }
  }
}
JSON
}

# ── mcp_health_validate_env ────────────────────────────────────────────

@test "validate_env: ✓ on servers without env block" {
  _setup_mcp_json
  : > "$TMP_TEST_DIR/.env"
  run mcp_health_validate_env "$TMP_TEST_DIR/.mcp.json" "$TMP_TEST_DIR/.env"
  [[ "$output" == *"⊝ fetch"* ]]
  [[ "$output" == *"⊝ filesystem"* ]]
  [[ "$output" == *"no env block"* ]]
}

@test "validate_env: ✓ when all referenced vars are set in .env" {
  _setup_mcp_json
  cat > "$TMP_TEST_DIR/.env" <<'ENV'
FIRECRAWL_API_KEY=fc-key
ATLASSIAN_PERSONAL_CONFLUENCE_URL=https://x.atlassian.net/wiki
ATLASSIAN_PERSONAL_JIRA_URL=https://x.atlassian.net
ATLASSIAN_PERSONAL_TOKEN=atl-tok
ENV
  run mcp_health_validate_env "$TMP_TEST_DIR/.mcp.json" "$TMP_TEST_DIR/.env"
  [ "$status" -eq 0 ]
  [[ "$output" == *"✓ firecrawl"* ]]
  [[ "$output" == *"✓ atlassian-personal"* ]]
}

@test "validate_env: ✗ when a referenced var is missing" {
  _setup_mcp_json
  # FIRECRAWL_API_KEY missing.
  : > "$TMP_TEST_DIR/.env"
  run mcp_health_validate_env "$TMP_TEST_DIR/.mcp.json" "$TMP_TEST_DIR/.env"
  [ "$status" -eq 1 ]
  [[ "$output" == *"✗ firecrawl"* ]]
  [[ "$output" == *"FIRECRAWL_API_KEY"* ]]
  [[ "$output" == *"missing in .env"* ]]
}

@test "validate_env: ✗ when one of multiple vars is missing (others set)" {
  _setup_mcp_json
  # Set one of the four atlassian vars, leave the other three missing.
  cat > "$TMP_TEST_DIR/.env" <<'ENV'
ATLASSIAN_PERSONAL_TOKEN=atl-tok
ENV
  run mcp_health_validate_env "$TMP_TEST_DIR/.mcp.json" "$TMP_TEST_DIR/.env"
  [ "$status" -eq 1 ]
  [[ "$output" == *"✗ atlassian-personal"* ]]
  [[ "$output" == *"ATLASSIAN_PERSONAL_CONFLUENCE_URL"* ]]
  [[ "$output" == *"ATLASSIAN_PERSONAL_JIRA_URL"* ]]
}

@test "validate_env: ✗ counts empty values as missing" {
  _setup_mcp_json
  # Var declared but empty — same risk as missing entirely.
  cat > "$TMP_TEST_DIR/.env" <<'ENV'
FIRECRAWL_API_KEY=
ATLASSIAN_PERSONAL_CONFLUENCE_URL=https://x.atlassian.net/wiki
ATLASSIAN_PERSONAL_JIRA_URL=https://x.atlassian.net
ATLASSIAN_PERSONAL_TOKEN=atl-tok
ENV
  run mcp_health_validate_env "$TMP_TEST_DIR/.mcp.json" "$TMP_TEST_DIR/.env"
  [ "$status" -eq 1 ]
  [[ "$output" == *"✗ firecrawl"* ]]
}

@test "validate_env: skip on missing .mcp.json (rc=2)" {
  run mcp_health_validate_env "$TMP_TEST_DIR/does-not-exist.json" "$TMP_TEST_DIR/.env"
  [ "$status" -eq 2 ]
  [[ "$output" == *"missing"* ]]
  [[ "$output" == *"skipped"* ]]
}

@test "validate_env: rc=2 on malformed .mcp.json" {
  printf 'this is { not valid json' > "$TMP_TEST_DIR/.mcp.json"
  : > "$TMP_TEST_DIR/.env"
  run mcp_health_validate_env "$TMP_TEST_DIR/.mcp.json" "$TMP_TEST_DIR/.env"
  [ "$status" -eq 2 ]
  [[ "$output" == *"not valid JSON"* ]]
}

@test "validate_env: rc=1 (not 2) when .env missing — every secret is a miss" {
  _setup_mcp_json
  run mcp_health_validate_env "$TMP_TEST_DIR/.mcp.json" "$TMP_TEST_DIR/no-such-env"
  [ "$status" -eq 1 ]
  [[ "$output" == *"✗ firecrawl"* ]]
  [[ "$output" == *"✗ atlassian-personal"* ]]
}

# ── mcp_health_query_running ───────────────────────────────────────────

@test "query_running: ⊝ skip when claude binary not found" {
  run mcp_health_query_running "claude-does-not-exist-xyz"
  [ "$status" -eq 2 ]
  [[ "$output" == *"⊝"* ]]
  [[ "$output" == *"not on PATH"* ]]
}

@test "query_running: ⊝ skip when claude returns non-zero (e.g. unauthenticated)" {
  # Stub claude with a script that exits 1.
  local stub="$TMP_TEST_DIR/stub-claude"
  cat > "$stub" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$stub"
  run mcp_health_query_running "$stub" "$TMP_TEST_DIR/.fakeclaudeconfig"
  [ "$status" -eq 2 ]
  [[ "$output" == *"⊝"* ]]
  [[ "$output" == *"not authenticated"* ]]
}

@test "query_running: ✓ when claude returns a healthy MCP list" {
  local stub="$TMP_TEST_DIR/stub-claude"
  cat > "$stub" <<'SH'
#!/usr/bin/env bash
echo '[{"name":"fetch","status":"connected"},{"name":"filesystem","status":"connected"}]'
SH
  chmod +x "$stub"
  run mcp_health_query_running "$stub" "$TMP_TEST_DIR/.fakeclaudeconfig"
  [ "$status" -eq 0 ]
  [[ "$output" == *"✓ 2 MCP(s) connected"* ]]
}

@test "query_running: ✗ for each MCP that is not connected" {
  local stub="$TMP_TEST_DIR/stub-claude"
  cat > "$stub" <<'SH'
#!/usr/bin/env bash
echo '[{"name":"fetch","status":"connected"},{"name":"firecrawl","status":"failed","error":"401 Unauthorized"}]'
SH
  chmod +x "$stub"
  run mcp_health_query_running "$stub" "$TMP_TEST_DIR/.fakeclaudeconfig"
  [ "$status" -eq 1 ]
  [[ "$output" == *"✗ firecrawl"* ]]
  # Healthy MCPs should not get their own ✗ row.
  [[ "$output" != *"✗ fetch"* ]]
}

@test "query_running: ⊝ skip when claude returns non-JSON" {
  local stub="$TMP_TEST_DIR/stub-claude"
  cat > "$stub" <<'SH'
#!/usr/bin/env bash
echo "human-readable output, not JSON"
SH
  chmod +x "$stub"
  run mcp_health_query_running "$stub" "$TMP_TEST_DIR/.fakeclaudeconfig"
  [ "$status" -eq 2 ]
  [[ "$output" == *"unable to parse"* ]]
}

# ── mcp_health_summary ─────────────────────────────────────────────────

@test "summary: emits both 'env validation' and 'runtime status' headers" {
  _setup_mcp_json
  : > "$TMP_TEST_DIR/.env"
  cat > "$TMP_TEST_DIR/agent.yml" <<'YML'
agent:
  name: test
YML
  run mcp_health_summary "$TMP_TEST_DIR/agent.yml" "$TMP_TEST_DIR/.env"
  [[ "$output" == *"MCP env validation:"* ]]
  [[ "$output" == *"MCP runtime status:"* ]]
}

@test "summary: rc=1 when env validation finds missing vars (even if runtime skip)" {
  _setup_mcp_json
  # FIRECRAWL_API_KEY missing → env validation rc=1 → summary rc=1
  : > "$TMP_TEST_DIR/.env"
  cat > "$TMP_TEST_DIR/agent.yml" <<'YML'
agent:
  name: test
YML
  run mcp_health_summary "$TMP_TEST_DIR/agent.yml" "$TMP_TEST_DIR/.env"
  [ "$status" -eq 1 ]
}
