#!/usr/bin/env bats
# Tests for scripts/lib/plugin-catalog.sh — descriptor reads, marketplace
# aggregation, agent.yml plugin list lookup.

load helper

setup() {
  setup_tmp_dir
  # Source the lib directly. Tests run on host (no /opt/agent-admin); we
  # point PLUGIN_CATALOG_DIR at the repo's modules/plugins/ for read tests
  # and override per-test for write tests.
  source "$REPO_ROOT/scripts/lib/plugin-catalog.sh"
  export PLUGIN_CATALOG_DIR="$REPO_ROOT/modules/plugins"
}

teardown() { teardown_tmp_dir; }

@test "plugin_catalog_list default emits the 5 default ids" {
  run plugin_catalog_list default
  [ "$status" -eq 0 ]
  local n
  n=$(printf '%s\n' "$output" | grep -c .)
  [ "$n" -eq 5 ]
  [[ "$output" == *"telegram"* ]]
  [[ "$output" == *"claude-mem"* ]]
  [[ "$output" == *"context7"* ]]
  [[ "$output" == *"claude-md-management"* ]]
  [[ "$output" == *"security-guidance"* ]]
}

@test "plugin_catalog_list optional emits 0 (PR1 has no opt-in yet)" {
  run plugin_catalog_list optional
  [ "$status" -eq 0 ]
  [ -z "$(printf '%s' "$output" | tr -d '[:space:]')" ]
}

@test "plugin_catalog_get reads top-level field by name" {
  run plugin_catalog_get telegram spec
  [ "$status" -eq 0 ]
  [ "$output" = "telegram@claude-plugins-official" ]
}

@test "plugin_catalog_get reads nested field via dotted expression" {
  run plugin_catalog_get claude-mem .marketplace.repo
  [ "$status" -eq 0 ]
  [ "$output" = "thedotmack/claude-mem" ]
}

@test "plugin_catalog_get returns empty for missing field (not literal 'null')" {
  run plugin_catalog_get telegram .marketplace.source
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "plugin_catalog_get returns post_install_hook for telegram" {
  run plugin_catalog_get telegram post_install_hook
  [ "$status" -eq 0 ]
  [ "$output" = "telegram_typing_patch" ]
}

@test "plugin_catalog_marketplaces_json emits {} when only @claude-plugins-official specs" {
  run plugin_catalog_marketplaces_json telegram@claude-plugins-official context7@claude-plugins-official
  [ "$status" -eq 0 ]
  [ "$output" = "{}" ]
}

@test "plugin_catalog_marketplaces_json includes thedotmack for claude-mem" {
  local json
  json=$(plugin_catalog_marketplaces_json claude-mem@thedotmack)
  [ "$(jq -r '.thedotmack.source.source' <<< "$json")" = "github" ]
  [ "$(jq -r '.thedotmack.source.repo' <<< "$json")" = "thedotmack/claude-mem" ]
}

@test "plugin_catalog_specs reads agent.yml.plugins[]" {
  cat > "$TMP_TEST_DIR/agent.yml" <<'YML'
plugins:
  - foo@bar
  - baz@qux
YML
  run plugin_catalog_specs "$TMP_TEST_DIR/agent.yml"
  [ "$status" -eq 0 ]
  [[ "$output" == *"foo@bar"* ]]
  [[ "$output" == *"baz@qux"* ]]
}

@test "plugin_catalog_specs is empty (not error) on missing file" {
  run plugin_catalog_specs "$TMP_TEST_DIR/nonexistent.yml"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "all 5 default descriptors have required fields" {
  local id
  for id in telegram claude-mem context7 claude-md-management security-guidance; do
    yq -e '.id and .spec and (.type == "default") and .description and .impact and .when_useful and .when_overhead' \
      "$REPO_ROOT/modules/plugins/$id.yml" >/dev/null
  done
}
