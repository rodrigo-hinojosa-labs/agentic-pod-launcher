#!/usr/bin/env bats
#
# 030 — warm cache for out-of-catalog MCPs. Derivation (mcp_warm_targets) is a
# pure function over the effective .mcp.json; the warmer (mcp_warm_run) is
# fail-soft, idempotent, and reads no secrets.
# Contract: specs/030-mcp-warm-cache/contracts/warm-derivation.md + boot-integration.md

load helper

setup() {
  setup_tmp_dir
  load_lib mcp_warm
  MCP_JSON="$TMP_TEST_DIR/.mcp.json"
}

teardown() { teardown_tmp_dir; }

# uv/npm stubs on PATH: log every call; exit code controllable via $1.
_install_warm_stubs() {
  local rc="${1:-0}" dir="$TMP_TEST_DIR/bin"
  mkdir -p "$dir"
  cat > "$dir/uv" <<EOF
#!/bin/sh
echo "uv \$*" >> "$TMP_TEST_DIR/warm.log"
exit ${rc}
EOF
  cat > "$dir/npm" <<EOF
#!/bin/sh
echo "npm \$*" >> "$TMP_TEST_DIR/warm.log"
exit ${rc}
EOF
  chmod +x "$dir/uv" "$dir/npm"
  export PATH="$dir:$PATH"
}

# ── Derivation: all catalog + overlay shapes (contract C1-C3, cases 1-10) ────

@test "030: mcp_warm_targets derives uvx/npx across every shape (cases 1-10)" {
  cat > "$MCP_JSON" <<'EOF'
{
  "mcpServers": {
    "fetch":      { "command": "uvx", "args": ["mcp-server-fetch"] },
    "git":        { "command": "uvx", "args": ["mcp-server-git", "--repository", "/workspace"] },
    "filesystem": { "command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "/home/agent"] },
    "playwright": { "command": "npx", "args": ["@playwright/mcp@latest"] },
    "google-workspace": { "command": "/workspace/.custom/seed-google-creds.sh", "args": ["uvx", "workspace-mcp"] },
    "firecrawl":  { "command": "npx", "args": ["-y", "firecrawl-mcp"] },
    "open-meteo": { "command": "npx", "args": ["-p", "open-meteo-mcp@2.0.1", "open-meteo-mcp"] },
    "mcpvault":   { "command": "npx", "args": ["-y", "@bitbonsai/mcpvault@0.12.0", "/vault"] },
    "github":     { "command": "github-mcp-server", "args": ["stdio"] },
    "qmd":        { "command": "/opt/agent-admin/scripts/qmd-mcp", "args": [] }
  }
}
EOF
  run mcp_warm_targets "$MCP_JSON"
  [ "$status" -eq 0 ]
  # exact, sorted set — github + qmd omitted (no uvx/npx token)
  expected=$(printf '%s\n' \
    "npx	@bitbonsai/mcpvault@0.12.0" \
    "npx	@modelcontextprotocol/server-filesystem" \
    "npx	@playwright/mcp@latest" \
    "npx	firecrawl-mcp" \
    "npx	open-meteo-mcp@2.0.1" \
    "uvx	mcp-server-fetch" \
    "uvx	mcp-server-git" \
    "uvx	workspace-mcp" | sort)
  [ "$output" = "$expected" ]
}

@test "030: the incident case (google-workspace wrapper) is derived (case 5)" {
  cat > "$MCP_JSON" <<'EOF'
{ "mcpServers": { "google-workspace": {
  "command": "/workspace/.custom/seed-google-creds.sh", "args": ["uvx", "workspace-mcp"] } } }
EOF
  run mcp_warm_targets "$MCP_JSON"
  [ "$status" -eq 0 ]
  [ "$output" = "uvx	workspace-mcp" ]
}

@test "030: npx -p takes the package after the flag, not the bin name (case 7)" {
  cat > "$MCP_JSON" <<'EOF'
{ "mcpServers": { "om": { "command": "npx", "args": ["-p", "open-meteo-mcp@2.0.1", "open-meteo-mcp"] } } }
EOF
  run mcp_warm_targets "$MCP_JSON"
  [ "$output" = "npx	open-meteo-mcp@2.0.1" ]
}

@test "030: binaries and wrappers-to-baked are omitted (cases 9,10)" {
  cat > "$MCP_JSON" <<'EOF'
{ "mcpServers": {
  "github": { "command": "github-mcp-server", "args": ["stdio"] },
  "qmd":    { "command": "/opt/agent-admin/scripts/qmd-mcp", "args": [] } } }
EOF
  run mcp_warm_targets "$MCP_JSON"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "030: duplicate (runtime,package) is deduped (case 11)" {
  cat > "$MCP_JSON" <<'EOF'
{ "mcpServers": {
  "a": { "command": "uvx", "args": ["mcp-server-fetch"] },
  "b": { "command": "uvx", "args": ["mcp-server-fetch"] } } }
EOF
  run mcp_warm_targets "$MCP_JSON"
  [ "$output" = "uvx	mcp-server-fetch" ]
}

@test "030: absent .mcp.json → zero lines, rc 0 (case 12)" {
  run mcp_warm_targets "$TMP_TEST_DIR/nope.json"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ── Robustness (contract C4) ─────────────────────────────────────────────────

@test "030: empty mcpServers → zero lines, rc 0" {
  echo '{ "mcpServers": {} }' > "$MCP_JSON"
  run mcp_warm_targets "$MCP_JSON"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "030: a server without args does not abort derivation" {
  cat > "$MCP_JSON" <<'EOF'
{ "mcpServers": {
  "weird": { "command": "npx" },
  "ok":    { "command": "uvx", "args": ["mcp-server-fetch"] } } }
EOF
  run mcp_warm_targets "$MCP_JSON"
  [ "$status" -eq 0 ]
  [ "$output" = "uvx	mcp-server-fetch" ]
}

# ── General / derived, no hardcode (US2 / SC-002) ────────────────────────────

@test "030: mixed catalog+overlay derives ALL uvx/npx with no hardcoded list" {
  cat > "$MCP_JSON" <<'EOF'
{ "mcpServers": {
  "atlassian": { "command": "uvx", "args": ["mcp-atlassian"] },
  "gws":       { "command": "/w/seed.sh", "args": ["uvx", "workspace-mcp"] },
  "brave":     { "command": "npx", "args": ["-y", "@brave/brave-search-mcp-server@2.1.0"] } } }
EOF
  run mcp_warm_targets "$MCP_JSON"
  echo "$output" | grep -q '^uvx	mcp-atlassian$'
  echo "$output" | grep -q '^uvx	workspace-mcp$'
  echo "$output" | grep -q '^npx	@brave/brave-search-mcp-server@2.1.0$'
}

# ── Warmer: fail-soft + idempotent + no secrets (US3 / FR-005/006/007/008) ───

@test "030: mcp_warm_run warms each target and returns 0 (uv/npm stubs)" {
  _install_warm_stubs 0
  cat > "$MCP_JSON" <<'EOF'
{ "mcpServers": {
  "fetch": { "command": "uvx", "args": ["mcp-server-fetch"] },
  "fs":    { "command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "/x"] } } }
EOF
  run mcp_warm_run "$MCP_JSON"
  [ "$status" -eq 0 ]
  grep -q 'uv tool install' "$TMP_TEST_DIR/warm.log"
  grep -q 'npm exec' "$TMP_TEST_DIR/warm.log"
}

@test "030: mcp_warm_run is fail-soft — a failing warmer does not abort (FR-007/008/SC-004)" {
  _install_warm_stubs 1   # every warm fails
  cat > "$MCP_JSON" <<'EOF'
{ "mcpServers": { "fetch": { "command": "uvx", "args": ["mcp-server-fetch"] } } }
EOF
  run mcp_warm_run "$MCP_JSON"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'mcp-server-fetch'          # trace names the package
  echo "$output" | grep -qi 'will resolve on first use'
}

@test "030: mcp_warm_run is idempotent — safe to re-run (FR-005)" {
  _install_warm_stubs 0
  cat > "$MCP_JSON" <<'EOF'
{ "mcpServers": { "fetch": { "command": "uvx", "args": ["mcp-server-fetch"] } } }
EOF
  run mcp_warm_run "$MCP_JSON"
  [ "$status" -eq 0 ]
  run mcp_warm_run "$MCP_JSON"   # second pass, same input
  [ "$status" -eq 0 ]
}

@test "030: mcp_warm.sh reads no secrets (FR-006/SC-005)" {
  # static guarantee: the CODE (comments excluded) must never touch .env /
  # credentials / keys / age files. Comments may mention them to document the
  # no-secrets property, so strip comment lines before asserting.
  run bash -c "grep -vE '^[[:space:]]*#' '$REPO_ROOT/scripts/lib/mcp_warm.sh' | grep -nE '\\.env|GOOGLE_OAUTH|credential|id_rsa|\\.age|\\.ssh'"
  [ "$status" -ne 0 ]   # no matches in code
}

@test "030: sourcing mcp_warm.sh has no side effects" {
  # sourcing (done in setup via load_lib) must not run anything; a fresh source
  # produces no output and rc 0.
  run bash -c "source '$REPO_ROOT/scripts/lib/mcp_warm.sh'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
