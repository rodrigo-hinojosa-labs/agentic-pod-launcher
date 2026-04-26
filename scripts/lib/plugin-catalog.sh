#!/usr/bin/env bash
# plugin-catalog.sh — read declarative plugin descriptors at modules/plugins/<id>.yml.
#
# Used by:
#   - setup.sh (host-side scaffold) — emit defaults into agent.yml
#   - start_services.sh (image-baked) — iterate agent.yml.plugins[] at runtime
#   - tests/plugin-catalog.bats — schema + behavior tests
#
# Test override: set PLUGIN_CATALOG_DIR to an alternate path. Otherwise the
# function probes (a) $SCRIPT_DIR/modules/plugins (host scaffold context),
# (b) /opt/agent-admin/modules/plugins (image-baked context).

# Print the active catalog dir.
plugin_catalog_dir() {
  if [ -n "${PLUGIN_CATALOG_DIR:-}" ]; then
    printf '%s\n' "$PLUGIN_CATALOG_DIR"
    return 0
  fi
  if [ -n "${SCRIPT_DIR:-}" ] && [ -d "$SCRIPT_DIR/modules/plugins" ]; then
    printf '%s\n' "$SCRIPT_DIR/modules/plugins"
    return 0
  fi
  if [ -d /opt/agent-admin/modules/plugins ]; then
    printf '%s\n' /opt/agent-admin/modules/plugins
    return 0
  fi
  printf '%s\n' /opt/agent-admin/modules/plugins
  return 1
}

# plugin_catalog_list TYPE → emit IDs of plugins matching `type:` (default | optional).
# Output sorted alphabetically. Caller must handle empty output (no plugins of that type).
plugin_catalog_list() {
  local want_type="$1"
  local dir
  dir=$(plugin_catalog_dir) || return 1
  local f id type
  for f in "$dir"/*.yml; do
    [ -f "$f" ] || continue
    type=$(yq -r '.type' "$f" 2>/dev/null)
    [ "$type" = "$want_type" ] || continue
    id=$(yq -r '.id' "$f" 2>/dev/null)
    [ -n "$id" ] && [ "$id" != "null" ] && printf '%s\n' "$id"
  done | sort
}

# plugin_catalog_get ID FIELD → emit the field value (no trailing newline).
# FIELD may be a dotted path (".marketplace.repo") or a top-level name ("spec").
# Empty output on missing field (yq's literal "null" is normalized to "").
plugin_catalog_get() {
  local id="$1" field="$2"
  local dir
  dir=$(plugin_catalog_dir) || return 1
  local f="$dir/$id.yml"
  [ -f "$f" ] || { echo "plugin_catalog_get: no descriptor for '$id' in $dir" >&2; return 1; }
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

# _plugin_catalog_id_for_spec SPEC → emit the descriptor id whose .spec matches SPEC.
# Returns 1 if no descriptor matches.
_plugin_catalog_id_for_spec() {
  local spec="$1"
  local dir
  dir=$(plugin_catalog_dir) || return 1
  local f cur_spec id
  for f in "$dir"/*.yml; do
    [ -f "$f" ] || continue
    cur_spec=$(yq -r '.spec' "$f" 2>/dev/null)
    if [ "$cur_spec" = "$spec" ]; then
      id=$(yq -r '.id' "$f" 2>/dev/null)
      printf '%s\n' "$id"
      return 0
    fi
  done
  return 1
}

# plugin_catalog_marketplaces_json [SPEC...] → emit a single JSON object suitable
# for merging into ~/.claude/settings.json::extraKnownMarketplaces.
# Each SPEC is a full plugin spec (e.g. claude-mem@thedotmack); we look up its
# descriptor and extract the marketplace block. Plugins without a marketplace
# (i.e. @claude-plugins-official) contribute nothing. Output: "{}" if none.
# Marketplace key = the substring after '@' in the spec (matches Claude Code's
# extraKnownMarketplaces convention).
plugin_catalog_marketplaces_json() {
  local out='{}'
  local spec id source repo mkt_key
  for spec in "$@"; do
    [ -n "$spec" ] || continue
    id=$(_plugin_catalog_id_for_spec "$spec" 2>/dev/null) || continue
    source=$(plugin_catalog_get "$id" '.marketplace.source')
    repo=$(plugin_catalog_get "$id" '.marketplace.repo')
    [ -z "$source" ] && continue
    [ -z "$repo" ] && continue
    mkt_key="${spec#*@}"
    out=$(printf '%s' "$out" | jq --arg k "$mkt_key" --arg s "$source" --arg r "$repo" \
      '. + {($k): {source: {source: $s, repo: $r}}}')
  done
  printf '%s\n' "$out"
}

# plugin_catalog_specs AGENT_YML → emit one spec per line from agent.yml.plugins[].
# Empty output (no error) if file missing or list empty. Used at runtime in
# start_services.sh.
plugin_catalog_specs() {
  local yml="$1"
  [ -f "$yml" ] || return 0
  yq -r '.plugins[]?' "$yml" 2>/dev/null
}
