#!/bin/bash
# mcp-health.sh — surface MCP server configuration and runtime status
# in a single doctor table. Two layers, intentionally separate:
#
#   1. env validation   reads .mcp.json statically and confirms every
#                       referenced ${VAR} has a value in .env. Cheap,
#                       deterministic, runs even when claude isn't up.
#
#   2. runtime query    calls `claude mcp list --json` and reports per-
#                       MCP connection status. Only meaningful post-
#                       /login; otherwise gracefully skipped.
#
# Why two layers: a missing env var is a configuration bug the user can
# fix in seconds (edit .env, agentctl restart). A failing runtime
# connection is a different class of issue (server crashed at init, MCP
# crashes mid-session, upstream timeout). Conflating them in one row
# obscures which knob to turn.
#
# Image-baked at /opt/agent-admin/scripts/lib/mcp-health.sh. Pure
# functions; no side effects at source time.

# mcp_health_validate_env MCP_JSON ENV_FILE
#
# Parse MCP_JSON (typically /workspace/.mcp.json), enumerate every
# server with an `env` block, resolve each `${VAR}` reference against
# ENV_FILE, and print per-server status.
#
# Output format:
#   ✓ <server>          all env vars set
#   ✗ <server>          MISSING_VAR1, MISSING_VAR2 not in .env
#   ⊝ <server>          no env block (no secrets required)
#
# Returns the worst exit code observed:
#   0 — all servers OK or skip
#   1 — at least one server has missing env vars
#   2 — MCP_JSON itself missing or unparseable
mcp_health_validate_env() {
  local mcp_json="$1" env_file="$2"
  if [ ! -f "$mcp_json" ]; then
    printf '  ⊝ MCP env validation: %s missing (skipped)\n' "$mcp_json"
    return 2
  fi
  if ! jq empty "$mcp_json" 2>/dev/null; then
    printf '  ✗ MCP env validation: %s is not valid JSON\n' "$mcp_json"
    return 2
  fi

  # Build a lookup of which env vars are set+non-empty in .env. Single
  # pass over the file rather than O(servers × vars) greps. Empty / file-
  # missing → empty set, every reference becomes a miss (correct).
  local env_keys=""
  if [ -f "$env_file" ]; then
    env_keys=$(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$env_file" 2>/dev/null \
      | awk -F= '$2 != "" { print $1 }')
  fi

  local worst=0

  # jq -r emits one line per server: "<name>|VAR1 VAR2 VAR3" where VAR*
  # are the env var names referenced as ${VAR} in the server's env block.
  # Servers with no env block emit "<name>|".
  local line server vars
  while IFS='|' read -r server vars; do
    [ -z "$server" ] && continue
    if [ -z "$vars" ]; then
      printf '  ⊝ %-22s no env block (no secrets required)\n' "$server"
      continue
    fi

    local missing=""
    local v
    for v in $vars; do
      # The var name is what we extracted; check membership in env_keys.
      if ! printf '%s\n' "$env_keys" | grep -qx "$v"; then
        missing="${missing}${missing:+, }$v"
      fi
    done

    if [ -z "$missing" ]; then
      printf '  ✓ %-22s env vars set (%s)\n' "$server" "$(printf '%s' "$vars" | tr ' ' ',')"
    else
      printf '  ✗ %-22s missing in .env: %s\n' "$server" "$missing"
      worst=1
    fi
  done < <(jq -r '
    .mcpServers // {} | to_entries[]
    | .key as $s
    | (.value.env // {}) | to_entries
    | map(.value | capture("\\$\\{(?<v>[A-Za-z_][A-Za-z0-9_]*)\\}").v) | unique | join(" ")
    | $s + "|" + .
  ' "$mcp_json")

  return "$worst"
}

# mcp_health_query_running [CLAUDE_BIN] [CLAUDE_CONFIG_DIR]
#
# Call `claude mcp list --json` (or fall back to plain `mcp list` and
# parse) to enumerate currently-connected MCPs. Only meaningful when
# claude is authenticated and a session has been launched at least once
# (the MCP cache is per-session).
#
# Output format:
#   ✓ N MCPs connected
#   ✗ <server>          failed to start (timeout / unauthenticated / etc.)
#
# Returns:
#   0 — all listed MCPs healthy
#   1 — at least one MCP failed at runtime
#   2 — claude unavailable or call failed (skip — not a hard error)
mcp_health_query_running() {
  local claude_bin="${1:-claude}"
  local config_dir="${2:-${HOME:-/home/agent}/.claude}"

  if ! command -v "$claude_bin" >/dev/null 2>&1; then
    printf '  ⊝ MCP runtime status: %s not on PATH (skipped)\n' "$claude_bin"
    return 2
  fi

  # Hard ceiling on the call. If claude is wedged or the MCP probe
  # itself blocks (rare, but observed during plugin install storms),
  # we surface a skip rather than block doctor for minutes.
  local out rc=0
  if command -v timeout >/dev/null 2>&1; then
    out=$(CLAUDE_CONFIG_DIR="$config_dir" timeout 10 "$claude_bin" mcp list --json 2>&1) || rc=$?
  elif command -v gtimeout >/dev/null 2>&1; then
    out=$(CLAUDE_CONFIG_DIR="$config_dir" gtimeout 10 "$claude_bin" mcp list --json 2>&1) || rc=$?
  else
    out=$(CLAUDE_CONFIG_DIR="$config_dir" "$claude_bin" mcp list --json 2>&1) || rc=$?
  fi

  if [ "$rc" -ne 0 ]; then
    printf '  ⊝ MCP runtime status: claude not authenticated yet (skipped)\n'
    return 2
  fi
  if ! printf '%s' "$out" | jq empty >/dev/null 2>&1; then
    # Some claude versions don't support --json; fall back to a less
    # structured parse if needed. For now, skip gracefully.
    printf '  ⊝ MCP runtime status: unable to parse `claude mcp list` output (skipped)\n'
    return 2
  fi

  # Expected schema (claude 2.x): array of {name, status, ...} or object
  # with mcps[] field. Try both. If neither matches, skip.
  local total ok_count fail_count
  total=$(printf '%s' "$out" | jq -r '
    if type == "array" then length
    elif .mcps then (.mcps | length)
    elif .servers then (.servers | length)
    else 0 end' 2>/dev/null)
  if [ -z "$total" ] || [ "$total" = "0" ]; then
    printf '  ⊝ MCP runtime status: 0 MCPs reported by claude\n'
    return 2
  fi

  ok_count=$(printf '%s' "$out" | jq -r '
    [ if type == "array" then .[]
      elif .mcps then .mcps[]
      elif .servers then .servers[]
      else empty end
    | select((.status // .state // "") | test("connected|ok|ready"; "i")) ] | length' 2>/dev/null)
  fail_count=$((total - ok_count))

  if [ "$fail_count" -eq 0 ]; then
    printf '  ✓ %s MCP(s) connected\n' "$total"
    return 0
  fi
  # Print one line per failed MCP for actionable detail.
  printf '%s' "$out" | jq -r '
    if type == "array" then .[]
    elif .mcps then .mcps[]
    elif .servers then .servers[]
    else empty end
    | select((.status // .state // "") | test("connected|ok|ready"; "i") | not)
    | "  ✗ " + (.name // .id // "unknown") + "          " +
      (.status // .state // .error // "unknown failure")' 2>/dev/null
  return 1
}

# mcp_health_summary AGENT_YML ENV_FILE [MCP_JSON]
#
# Top-level entry point used by `heartbeatctl doctor`. Renders both
# layers (env validation + runtime query) sequentially with header
# rows. Returns the worst-of-both exit code.
#
# MCP_JSON defaults to <workspace>/.mcp.json (sibling of AGENT_YML).
mcp_health_summary() {
  local agent_yml="$1" env_file="$2" mcp_json="${3:-}"
  if [ -z "$mcp_json" ]; then
    mcp_json="$(dirname "$agent_yml")/.mcp.json"
  fi

  local env_rc=0 run_rc=0
  printf 'MCP env validation:\n'
  mcp_health_validate_env "$mcp_json" "$env_file" || env_rc=$?

  printf '\nMCP runtime status:\n'
  mcp_health_query_running || run_rc=$?

  # Worst of {env_rc, run_rc}. env_rc=2 (mcp.json missing) is treated as
  # informational ⊝ — still fine to report, but doesn't elevate doctor
  # to error. Real errors (rc=1) on either layer dominate.
  if [ "$env_rc" = "1" ] || [ "$run_rc" = "1" ]; then
    return 1
  fi
  return 0
}

# Source-time guard, parallel with safe-exec.sh and token-health.sh.
if [ "${MCP_HEALTH_NO_RUN:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi
