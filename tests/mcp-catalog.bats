#!/usr/bin/env bats
# Drift + smoke tests for the MCP catalog at modules/mcps/<id>.yml.
# Same defensive pattern as plugin-catalog.bats and schema.bats.

load helper

setup() {
  load_lib mcp-catalog
  setup_tmp_dir
}

teardown() { teardown_tmp_dir; }

@test "mcp-catalog: descriptors exist for the expected default + optional set" {
  SCRIPT_DIR="$REPO_ROOT"
  local defaults optional
  defaults=$(mcp_catalog_list default | tr '\n' ' ')
  optional=$(mcp_catalog_list optional | tr '\n' ' ')
  # Always-on triplet — these are the low-overhead, no-auth MCPs that
  # almost every agent benefits from.
  [ "$defaults" = "fetch filesystem git " ]
  # 6 opt-in MCPs covering web/scheduling/cloud/code intelligence/etc.
  # Order is alphabetical (sort), not curated importance.
  [ "$optional" = "aws firecrawl google-calendar playwright time tree-sitter " ]
}

@test "mcp-catalog: every descriptor has the required schema keys" {
  SCRIPT_DIR="$REPO_ROOT"
  local id field val
  for id in $(mcp_catalog_list default) $(mcp_catalog_list optional); do
    for field in id spec type description when_useful when_overhead requires_secret; do
      val=$(mcp_catalog_get "$id" "$field")
      if [ -z "$val" ]; then
        echo "Missing/empty .${field} in modules/mcps/${id}.yml" >&2
        return 1
      fi
    done
  done
}

@test "mcp-catalog: descriptors with requires_secret=true also set secret_env_var + secret_doc_url" {
  SCRIPT_DIR="$REPO_ROOT"
  local id req env_var
  for id in $(mcp_catalog_list optional); do
    req=$(mcp_catalog_get "$id" requires_secret)
    [ "$req" = "true" ] || continue
    env_var=$(mcp_catalog_get "$id" secret_env_var)
    if [ -z "$env_var" ]; then
      echo "${id}: requires_secret=true but secret_env_var is empty" >&2
      return 1
    fi
    # secret_doc_url is recommended but not strictly enforced — some auth
    # flows (like AWS local credentials) don't need a doc link. Don't fail
    # on missing secret_doc_url; require only secret_env_var when
    # requires_secret=true.
  done
}

@test "mcp-catalog: id_to_envvar produces the canonical MCPS_<ID>_ENABLED form" {
  [ "$(mcp_catalog_id_to_envvar fetch)" = "MCPS_FETCH_ENABLED" ]
  [ "$(mcp_catalog_id_to_envvar git)" = "MCPS_GIT_ENABLED" ]
  [ "$(mcp_catalog_id_to_envvar google-calendar)" = "MCPS_GOOGLE_CALENDAR_ENABLED" ]
  [ "$(mcp_catalog_id_to_envvar tree-sitter)" = "MCPS_TREE_SITTER_ENABLED" ]
}

@test "mcp-catalog: every optional MCP has a matching {{#if MCPS_<ID>_ENABLED}} block in mcp-json.tpl" {
  SCRIPT_DIR="$REPO_ROOT"
  local id envvar
  for id in $(mcp_catalog_list optional); do
    envvar=$(mcp_catalog_id_to_envvar "$id")
    if ! grep -qF "{{#if ${envvar}}}" "$REPO_ROOT/modules/mcp-json.tpl"; then
      echo "Optional MCP ${id} has no {{#if ${envvar}}} guard in modules/mcp-json.tpl" >&2
      echo "Either add the conditional block or change the descriptor to type: default." >&2
      return 1
    fi
  done
}

@test "mcp-catalog: every default MCP has an unconditional block in mcp-json.tpl (always-on)" {
  SCRIPT_DIR="$REPO_ROOT"
  local id envvar
  for id in $(mcp_catalog_list default); do
    # Defaults must NOT be wrapped in a {{#if MCPS_<ID>_ENABLED}} block.
    envvar=$(mcp_catalog_id_to_envvar "$id")
    if grep -qF "{{#if ${envvar}}}" "$REPO_ROOT/modules/mcp-json.tpl"; then
      echo "Default MCP ${id} is gated by {{#if ${envvar}}} — defaults must be unconditional." >&2
      return 1
    fi
    # And must appear in the JSON skeleton.
    if ! grep -q "\"${id}\":" "$REPO_ROOT/modules/mcp-json.tpl"; then
      echo "Default MCP ${id} is missing from modules/mcp-json.tpl" >&2
      return 1
    fi
  done
}
