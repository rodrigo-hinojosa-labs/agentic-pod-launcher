#!/usr/bin/env bats
#
# 029 — claude.mcp_timeout_ms: configurable MCP startup-handshake window
# (env var MCP_TIMEOUT), single source of truth in agent.yml, rendered to both
# modes. Covers the render-time sanitiser (positive int → value, else 120000),
# the has()-guarded backfill, idempotency, and the single-source invariant.
# Contract: specs/029-mcp-handshake-timeout/contracts/mcp-timeout-contract.md

load helper

setup() {
  setup_tmp_dir
  cp -r "$REPO_ROOT/scripts" "$REPO_ROOT/modules" "$TMP_TEST_DIR/"
  cp "$REPO_ROOT/setup.sh" "$TMP_TEST_DIR/"
  touch "$TMP_TEST_DIR/.env"
  CLAUDE_STUB=$(install_claude_stub)
}

teardown() { teardown_tmp_dir; }

# Minimal schema-valid docker-mode agent.yml. $1 controls claude.mcp_timeout_ms:
#   a value ("90000") → emit that value; "OMIT" → no field; "NULL" → empty value.
_write_agent_yml() {
  local tmo="$1"
  local claude_block='claude:
  config_dir: "/home/agent/.claude"
  profile_new: true'
  case "$tmo" in
    OMIT) : ;;
    NULL) claude_block="${claude_block}
  mcp_timeout_ms:" ;;
    *)    claude_block="${claude_block}
  mcp_timeout_ms: ${tmo}" ;;
  esac
  cat > "$TMP_TEST_DIR/agent.yml" << EOF
version: 1
agent:
  name: mcp-bot
  display_name: "MCP"
  role: "r"
  vibe: "v"
  use_default_principles: true
user:
  name: "A"
  nickname: "A"
  timezone: "UTC"
  email: "a@b.com"
  language: "en"
deployment:
  host: "h"
  workspace: "/tmp/mcp-bot"
  install_service: false
  mode: docker
docker:
  image_tag: "agent-admin:latest"
  uid: 1000
  gid: 1000
  base_image: "alpine:3.20"
${claude_block}
notifications:
  channel: none
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
plugins:
  - telegram@claude-plugins-official
EOF
}

# ── Render: valid value flows through to the docker artifact ─────────────────

@test "029: --regenerate renders MCP_TIMEOUT from claude.mcp_timeout_ms into compose environment" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml 90000
  echo 'n' | ./setup.sh --regenerate
  grep -qE '^[[:space:]]*MCP_TIMEOUT: "90000"$' docker-compose.yml
}

# ── Sanitiser: invalid values degrade to the 120000 default (never ≤0) ───────

@test "029: non-numeric mcp_timeout_ms degrades to 120000 in the artifact" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml '"abc"'
  echo 'n' | ./setup.sh --regenerate
  grep -qE '^[[:space:]]*MCP_TIMEOUT: "120000"$' docker-compose.yml
}

@test "029: mcp_timeout_ms=0 degrades to 120000 in the artifact (never <=0)" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml 0
  echo 'n' | ./setup.sh --regenerate
  grep -qE '^[[:space:]]*MCP_TIMEOUT: "120000"$' docker-compose.yml
}

@test "029: negative mcp_timeout_ms degrades to 120000" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml -5
  echo 'n' | ./setup.sh --regenerate
  grep -qE '^[[:space:]]*MCP_TIMEOUT: "120000"$' docker-compose.yml
}

@test "029: empty mcp_timeout_ms degrades to 120000" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml NULL
  echo 'n' | ./setup.sh --regenerate
  grep -qE '^[[:space:]]*MCP_TIMEOUT: "120000"$' docker-compose.yml
}

@test "029: oversized mcp_timeout_ms (>7 digits) degrades to 120000" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml 99999999
  echo 'n' | ./setup.sh --regenerate
  grep -qE '^[[:space:]]*MCP_TIMEOUT: "120000"$' docker-compose.yml
}

# ── Backfill (has()-guarded, patrón 028) ─────────────────────────────────────

@test "029: --regenerate backfills claude.mcp_timeout_ms=120000 when absent" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml OMIT
  [ "$(yq -r '(.claude | has("mcp_timeout_ms"))' agent.yml)" = "false" ]
  echo 'n' | ./setup.sh --regenerate
  [ "$(yq -r '.claude.mcp_timeout_ms' agent.yml)" = "120000" ]
}

@test "029: default 120000 applies out-of-the-box when unset (US2)" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml OMIT
  echo 'n' | ./setup.sh --regenerate
  grep -qE '^[[:space:]]*MCP_TIMEOUT: "120000"$' docker-compose.yml
}

@test "029: backfill does NOT overwrite an operator's mcp_timeout_ms=0 (has() not //)" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml 0
  echo 'n' | ./setup.sh --regenerate
  # agent.yml keeps the operator's 0; only the rendered artifact is degraded
  [ "$(yq -r '.claude.mcp_timeout_ms' agent.yml)" = "0" ]
}

@test "029: two --regenerate passes are byte-stable for claude.mcp_timeout_ms (modulo meta timestamp)" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml OMIT
  echo 'n' | ./setup.sh --regenerate
  # meta.regenerated_at changes every run by design; exclude it and assert the
  # rest (incl. the backfilled claude.mcp_timeout_ms) is byte-stable.
  yq 'del(.meta.regenerated_at)' agent.yml > pass1.yml
  echo 'n' | ./setup.sh --regenerate
  yq 'del(.meta.regenerated_at)' agent.yml > pass2.yml
  diff -q pass1.yml pass2.yml
}

# ── Single source: neither template hardcodes the literal ────────────────────

@test "029: single-source — both templates use the placeholder, not a literal" {
  # docker + local templates both reference {{CLAUDE_MCP_TIMEOUT_MS}} and never
  # a hardcoded number next to MCP_TIMEOUT (FR-004 / C5.1).
  grep -q 'MCP_TIMEOUT: "{{CLAUDE_MCP_TIMEOUT_MS}}"' "$REPO_ROOT/modules/docker-compose.yml.tpl"
  grep -q 'MCP_TIMEOUT={{CLAUDE_MCP_TIMEOUT_MS}}' "$REPO_ROOT/modules/remote-control.env.tpl"
}

@test "029: changing the value re-renders the compose artifact to the new value" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml 90000
  echo 'n' | ./setup.sh --regenerate
  grep -qE '^[[:space:]]*MCP_TIMEOUT: "90000"$' docker-compose.yml
  yq -i '.claude.mcp_timeout_ms = 150000' agent.yml
  echo 'n' | ./setup.sh --regenerate
  grep -qE '^[[:space:]]*MCP_TIMEOUT: "150000"$' docker-compose.yml
}
