#!/usr/bin/env bats
#
# 030 US1 — docker boot warm: start_services.sh sources scripts/lib/mcp_warm.sh
# (mirrored into the image) and runs pre_warm_mcps synchronously BEFORE claude
# launches its MCPs. Also asserts the mirror/COPY wiring so the image ships the
# lib (gotcha docker-lib-needs-explicit-copy).
# Contract: specs/030-mcp-warm-cache/contracts/boot-integration.md

load helper

setup() {
  setup_tmp_dir
  export START_SERVICES_NO_RUN=1
  export HOME="$TMP_TEST_DIR/home"
  mkdir -p "$HOME"
  unset CLAUDE_CODE_OAUTH_TOKEN
  # uv/npm stubs on PATH: log calls, exit code via $MCP_WARM_STUB_RC (default 0).
  local bin="$TMP_TEST_DIR/bin"
  mkdir -p "$bin"
  cat > "$bin/uv" <<EOF
#!/bin/sh
echo "uv \$*" >> "$TMP_TEST_DIR/warm.log"
exit \${MCP_WARM_STUB_RC:-0}
EOF
  cat > "$bin/npm" <<EOF
#!/bin/sh
echo "npm \$*" >> "$TMP_TEST_DIR/warm.log"
exit \${MCP_WARM_STUB_RC:-0}
EOF
  chmod +x "$bin/uv" "$bin/npm"
  export PATH="$bin:$PATH"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/docker/scripts/start_services.sh"
  # start_services.sh sets WORKDIR=/workspace unconditionally at load; override
  # AFTER sourcing so pre_warm_mcps reads our tmp .mcp.json, not the image path.
  export WORKDIR="$TMP_TEST_DIR"
}

teardown() { teardown_tmp_dir; }

# ── The lib is sourced by the supervisor (mirror/source cascade resolves) ─────

@test "030 US1: start_services.sh sources mcp_warm — mcp_warm_run is defined" {
  run type -t mcp_warm_run
  [ "$status" -eq 0 ]
  [ "$output" = "function" ]
}

# ══ 036 US1: the pruner runs BEFORE the warm ═════════════════════════════════
#
# BEHAVIOURAL oracle, not a naive one. The obvious test — "assert the pruner is
# called" — cannot fail for the mutation it is supposed to catch: moving the
# call after mcp_warm_run still calls it, and mcp_warm_run has no early return
# that would skip it (that early return belongs to mcp_warm_targets,
# mcp_warm.sh:62, inside a process substitution). So the oracle has to observe
# the CONSEQUENCE of the order instead.
#
# The consequence is the live incident itself: a dangling link holding the
# executable name makes `uv tool install` exit 2 instantly. Prune first and the
# install succeeds; prune after (or never) and it fails. The stub below keys its
# exit code on exactly that, so the two orders produce different warm summaries.
_install_collision_uv_stub() {
  cat > "$TMP_TEST_DIR/bin/uv" <<EOF
#!/bin/sh
echo "uv \$*" >> "$TMP_TEST_DIR/warm.log"
# Reproduce uv's real behaviour: refuse while the executable name is taken.
if [ -L "\$HOME/.local/bin/workspace-cli" ] || [ -e "\$HOME/.local/bin/workspace-cli" ]; then
  exit 2
fi
exit 0
EOF
  chmod +x "$TMP_TEST_DIR/bin/uv"
}

@test "036 US1: a dangling link colliding with a declared package still ends warm (pruner runs first)" {
  mkdir -p "$HOME/.local/bin"
  ln -s /opt/uv/tools/workspace-mcp/bin/workspace-cli "$HOME/.local/bin/workspace-cli"
  _install_collision_uv_stub
  cat > "$WORKDIR/.mcp.json" <<'EOF'
{ "mcpServers": { "gws": { "command": "uvx", "args": ["workspace-mcp"] } } }
EOF
  run pre_warm_mcps
  [ "$status" -eq 0 ]
  # Pruner-before → the install succeeds → 1/1 warm, no CANON-W1.
  run bash -c "printf '%s\n' \"\$1\" | grep -cF 'mcp_warm: warm cache: 1/1 warm, 0 failed'" _ "$output"
  [ "$output" = "1" ]
}

@test "036 US1: the same collision reports CANON-W1 when the link is NOT pruned (the mutation's shape)" {
  # Pins that the previous test is discriminating rather than vacuous: with the
  # link left in place, the identical stub yields the exact failure the incident
  # produced. If this ever goes green alongside a broken order, the oracle above
  # has stopped proving anything.
  mkdir -p "$HOME/.local/bin"
  ln -s /opt/uv/tools/workspace-mcp/bin/workspace-cli "$HOME/.local/bin/workspace-cli"
  _install_collision_uv_stub
  cat > "$WORKDIR/.mcp.json" <<'EOF'
{ "mcpServers": { "gws": { "command": "uvx", "args": ["workspace-mcp"] } } }
EOF
  run mcp_warm_run "$WORKDIR/.mcp.json"   # warm WITHOUT pruning
  [ "$status" -eq 0 ]
  run bash -c "printf '%s\n' \"\$1\" | grep -cF 'mcp_warm: warn: uvx workspace-mcp failed (exit 2) — will resolve on first use'" _ "$output"
  [ "$output" = "1" ]
}

@test "036 US1: stale links are pruned even for an agent with zero uvx/npx targets (C14 oracle c)" {
  mkdir -p "$HOME/.local/bin"
  ln -s /opt/uv/tools/gone/bin/gone "$HOME/.local/bin/gone"
  # Only a baked binary: the derivation yields no targets at all.
  cat > "$WORKDIR/.mcp.json" <<'EOF'
{ "mcpServers": { "time": { "command": "mcp-server-time", "args": [] } } }
EOF
  run pre_warm_mcps
  [ "$status" -eq 0 ]
  [ ! -L "$HOME/.local/bin/gone" ]
}

# ── pre_warm_mcps warms the packages the effective .mcp.json declares ─────────

@test "030 US1: pre_warm_mcps warms uvx and npx packages from WORKDIR/.mcp.json" {
  cat > "$WORKDIR/.mcp.json" <<'EOF'
{ "mcpServers": {
  "fetch": { "command": "uvx", "args": ["mcp-server-fetch"] },
  "gws":   { "command": "/w/seed.sh", "args": ["uvx", "workspace-mcp"] },
  "fs":    { "command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "/x"] } } }
EOF
  run pre_warm_mcps
  [ "$status" -eq 0 ]
  grep -q 'mcp-server-fetch' "$TMP_TEST_DIR/warm.log"
  grep -q 'workspace-mcp' "$TMP_TEST_DIR/warm.log"          # the incident package
  grep -q 'server-filesystem' "$TMP_TEST_DIR/warm.log"
}

@test "030 US1: pre_warm_mcps is fail-soft — returns 0 even when the warmer fails" {
  cat > "$WORKDIR/.mcp.json" <<'EOF'
{ "mcpServers": { "fetch": { "command": "uvx", "args": ["mcp-server-fetch"] } } }
EOF
  MCP_WARM_STUB_RC=1 run pre_warm_mcps
  [ "$status" -eq 0 ]
}

@test "030 US1: pre_warm_mcps with no .mcp.json does not abort" {
  rm -f "$WORKDIR/.mcp.json"
  run pre_warm_mcps
  [ "$status" -eq 0 ]
}

# ── Ordering: pre_warm_mcps runs before the tmux launch (pre-claude) ──────────

@test "030 US1: pre_warm_mcps is invoked in start_session before tmux new-session" {
  local src="$REPO_ROOT/docker/scripts/start_services.sh"
  local call_ln launch_ln
  call_ln=$(grep -n '^\s*pre_warm_mcps\s*$' "$src" | head -1 | cut -d: -f1)
  launch_ln=$(grep -n 'tmux new-session' "$src" | head -1 | cut -d: -f1)
  [ -n "$call_ln" ]
  [ -n "$launch_ln" ]
  [ "$call_ln" -lt "$launch_ln" ]
}

# ── Mirror/COPY wiring (B8): the lib reaches the image ────────────────────────

@test "030 US1: setup.sh mirrors mcp_warm.sh into docker/scripts/lib" {
  grep -q 'mcp_warm.sh' "$REPO_ROOT/setup.sh"
  # a validation entry guards the mirror like the other required libs
  grep -qE 'docker/scripts/lib/mcp_warm.sh' "$REPO_ROOT/setup.sh"
}

@test "030 US1: Dockerfile COPYs mcp_warm.sh into the image lib dir" {
  grep -qE '^COPY[[:space:]]+scripts/lib/mcp_warm.sh[[:space:]]+/opt/agent-admin/scripts/lib/mcp_warm.sh' "$REPO_ROOT/docker/Dockerfile"
}

@test "030 US1: start_services.sh sources mcp_warm.sh (image + repo-relative fallback)" {
  grep -q 'scripts/lib/mcp_warm.sh' "$REPO_ROOT/docker/scripts/start_services.sh"
}
