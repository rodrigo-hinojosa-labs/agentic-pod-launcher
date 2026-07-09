#!/usr/bin/env bats
# 011-local-standalone-mode (MCP runtimes): the rendered scripts/local/
# agent-bootstrap.sh provisions, into the operator's ~/.local/bin, exactly the
# MCP runtimes referenced by the workspace .mcp.json — so the systemd session
# can spawn them. Docker bakes uv/node/bun/github-mcp-server into the image;
# local mode has to install them on the host (validated on mclaren: all five
# project MCPs → ✘ Failed to connect because uvx/npx/github-mcp-server were
# absent from every PATH).
#
# Host-runnable: the download/extract machinery is exercised only on the real
# Linux host (mclaren gate). Here we test the DECISION logic — which runtimes a
# given .mcp.json plans — via BOOTSTRAP_DRY_RUN=1, which prints a plan and does
# nothing. The dry-run guard sits at the top of the same provision_* functions
# the real path calls, so the .mcp.json→runtime mapping is faithfully covered.

load helper

setup() {
  setup_tmp_dir
  command -v jq >/dev/null || skip "jq not installed"
  load_lib render
  load_lib yaml
  yaml_require_yq >/dev/null

  WS="$TMP_TEST_DIR/ws"; mkdir -p "$WS"
  export OPERATOR_HOME="$TMP_TEST_DIR/home"; mkdir -p "$OPERATOR_HOME/.local/bin"

  cat > "$TMP_TEST_DIR/agent.yml" << YML
version: 1
deployment:
  workspace: "$WS"
  mode: local
YML
  render_load_context "$TMP_TEST_DIR/agent.yml" >/dev/null

  BOOT="$WS/agent-bootstrap.sh"
  render_to_file "$REPO_ROOT/modules/local-bootstrap.sh.tpl" "$BOOT"
  chmod +x "$BOOT"
}

teardown() { teardown_tmp_dir; }

# Write a .mcp.json with the given server entries (JSON object body).
_write_mcp() { printf '{ "mcpServers": { %s } }\n' "$1" > "$WS/.mcp.json"; }

@test "bootstrap: rendered script is valid bash" {
  bash -n "$BOOT"
}

@test "bootstrap dry-run: plans uv + one uv-tool per uvx MCP (deduped)" {
  _write_mcp '
    "fetch": {"command":"uvx","args":["mcp-server-fetch"]},
    "git": {"command":"uvx","args":["mcp-server-git","--repository","/x"]},
    "atlassian-work": {"command":"uvx","args":["mcp-atlassian"]}
  '
  run env BOOTSTRAP_DRY_RUN=1 "$BOOT"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^PLAN uv$'
  echo "$output" | grep -q '^PLAN uv-tool mcp-server-fetch$'
  echo "$output" | grep -q '^PLAN uv-tool mcp-server-git$'
  echo "$output" | grep -q '^PLAN uv-tool mcp-atlassian$'
  # no node / github / bun for a uvx-only config
  ! echo "$output" | grep -q '^PLAN node-links'
  ! echo "$output" | grep -q '^PLAN github-mcp-server'
  ! echo "$output" | grep -q '^PLAN bun'
}

@test "bootstrap dry-run: plans node-links when an npx MCP is present" {
  _write_mcp '
    "filesystem": {"command":"npx","args":["-y","@modelcontextprotocol/server-filesystem","/x"]}
  '
  run env BOOTSTRAP_DRY_RUN=1 "$BOOT"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^PLAN node-links'
  ! echo "$output" | grep -q '^PLAN uv$'
}

@test "bootstrap dry-run: plans github-mcp-server when the github MCP is present" {
  _write_mcp '
    "github": {"command":"github-mcp-server","args":["stdio"]}
  '
  run env BOOTSTRAP_DRY_RUN=1 "$BOOT"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^PLAN github-mcp-server [0-9]+\.[0-9]+\.[0-9]+$'
}

@test "bootstrap dry-run: plans bun when a bunx MCP is present" {
  _write_mcp '
    "qmd": {"command":"bunx","args":["@tobilu/qmd@2.5.3","mcp"]}
  '
  run env BOOTSTRAP_DRY_RUN=1 "$BOOT"
  [ "$status" -eq 0 ]
  # 015 US2: the plan line now carries the resolved libc variant + asset.
  echo "$output" | grep -qE '^PLAN bun [0-9]+\.[0-9]+\.[0-9]+ \((glibc|musl)\) asset=bun-linux-[a-z0-9]+(-musl)?\.zip$'
}

@test "bootstrap dry-run: glibc host selects the glibc bun asset (US2)" {
  _write_mcp '"qmd": {"command":"bunx","args":["@tobilu/qmd@2.5.3","mcp"]}'
  run env BOOTSTRAP_DRY_RUN=1 AGENTIC_LIBC=glibc "$BOOT"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^PLAN bun [0-9.]+ \(glibc\) asset=bun-linux-[a-z0-9]+\.zip$'
  # glibc asset MUST NOT be the -musl build
  ! echo "$output" | grep -qE 'asset=bun-linux-[a-z0-9]+-musl\.zip'
}

@test "bootstrap dry-run: musl host selects the musl bun asset (US2, docker parity)" {
  _write_mcp '"qmd": {"command":"bunx","args":["@tobilu/qmd@2.5.3","mcp"]}'
  run env BOOTSTRAP_DRY_RUN=1 AGENTIC_LIBC=musl "$BOOT"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^PLAN bun [0-9.]+ \(musl\) asset=bun-linux-[a-z0-9]+-musl\.zip$'
}

@test "bootstrap dry-run: full config plans every runtime it references" {
  _write_mcp '
    "fetch": {"command":"uvx","args":["mcp-server-fetch"]},
    "filesystem": {"command":"npx","args":["-y","@modelcontextprotocol/server-filesystem","/x"]},
    "github": {"command":"github-mcp-server","args":["stdio"]},
    "qmd": {"command":"bunx","args":["@tobilu/qmd@2.5.3","mcp"]}
  '
  run env BOOTSTRAP_DRY_RUN=1 "$BOOT"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^PLAN uv$'
  echo "$output" | grep -q '^PLAN node-links'
  echo "$output" | grep -qE '^PLAN github-mcp-server '
  echo "$output" | grep -qE '^PLAN bun '
}

@test "bootstrap dry-run: writes nothing into ~/.local/bin" {
  _write_mcp '"fetch": {"command":"uvx","args":["mcp-server-fetch"]}'
  run env BOOTSTRAP_DRY_RUN=1 "$BOOT"
  [ "$status" -eq 0 ]
  # dry-run is side-effect free
  [ -z "$(ls -A "$OPERATOR_HOME/.local/bin")" ]
}

@test "bootstrap: missing .mcp.json is a clean no-op, not a crash" {
  [ ! -f "$WS/.mcp.json" ]
  run env BOOTSTRAP_DRY_RUN=1 "$BOOT"
  [ "$status" -eq 0 ]
}
