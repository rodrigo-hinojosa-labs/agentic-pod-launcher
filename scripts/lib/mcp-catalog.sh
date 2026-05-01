#!/usr/bin/env bash
# mcp-catalog.sh — read declarative MCP server descriptors at modules/mcps/<id>.yml.
#
# Used by:
#   - setup.sh (host-side scaffold) — emit prompts + render context vars
#   - tests/mcp-catalog.bats — schema + behavior tests
#
# Schema parallel to scripts/lib/plugin-catalog.sh — keep them in sync if
# either side grows new conventions.
#
# Test override: set MCP_CATALOG_DIR to an alternate path. Otherwise the
# function probes (a) $SCRIPT_DIR/modules/mcps (host scaffold context),
# (b) /opt/agent-admin/modules/mcps (image-baked context).

# Print the active catalog dir.
mcp_catalog_dir() {
  if [ -n "${MCP_CATALOG_DIR:-}" ]; then
    printf '%s\n' "$MCP_CATALOG_DIR"
    return 0
  fi
  if [ -n "${SCRIPT_DIR:-}" ] && [ -d "$SCRIPT_DIR/modules/mcps" ]; then
    printf '%s\n' "$SCRIPT_DIR/modules/mcps"
    return 0
  fi
  if [ -d /opt/agent-admin/modules/mcps ]; then
    printf '%s\n' /opt/agent-admin/modules/mcps
    return 0
  fi
  printf '%s\n' /opt/agent-admin/modules/mcps
  return 1
}

# mcp_catalog_list TYPE → emit IDs of MCPs matching `type:` (default | optional).
# Output sorted alphabetically. Caller must handle empty output.
mcp_catalog_list() {
  local want_type="$1"
  local dir
  dir=$(mcp_catalog_dir) || return 1
  local f id type
  for f in "$dir"/*.yml; do
    [ -f "$f" ] || continue
    type=$(yq -r '.type' "$f" 2>/dev/null)
    [ "$type" = "$want_type" ] || continue
    id=$(yq -r '.id' "$f" 2>/dev/null)
    [ -n "$id" ] && [ "$id" != "null" ] && printf '%s\n' "$id"
  done | sort
}

# mcp_catalog_get ID FIELD → emit the field value (no trailing newline).
# FIELD may be a dotted path (".secret_doc_url") or a top-level name ("spec").
# Empty output on missing field (yq's literal "null" is normalized to "").
mcp_catalog_get() {
  local id="$1" field="$2"
  local dir
  dir=$(mcp_catalog_dir) || return 1
  local f="$dir/$id.yml"
  [ -f "$f" ] || { echo "mcp_catalog_get: no descriptor for '$id' in $dir" >&2; return 1; }
  local expr
  case "$field" in
    .*) expr="$field" ;;
    *)  expr=".$field" ;;
  esac
  local val
  val=$(yq -r "$expr" "$f" 2>/dev/null)
  [ "$val" = "null" ] && val=""
  printf '%s' "$val"
}

# mcp_catalog_id_to_envvar ID → emit the canonical env var name used by the
# render template to gate the `{{#if MCPS_<ID>_ENABLED}}` block.
# Examples:
#   fetch              → MCPS_FETCH_ENABLED
#   sequential-thinking → MCPS_SEQUENTIAL_THINKING_ENABLED
#   google-calendar    → MCPS_GOOGLE_CALENDAR_ENABLED
mcp_catalog_id_to_envvar() {
  local id="$1"
  printf 'MCPS_%s_ENABLED' "$(echo "$id" | tr '[:lower:]-' '[:upper:]_')"
}
