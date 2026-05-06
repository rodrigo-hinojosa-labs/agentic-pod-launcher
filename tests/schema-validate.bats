#!/usr/bin/env bats
# Direct unit tests for scripts/lib/schema.sh::agent_yml_validate.
# Exercises required-fields, enums, booleans, and YAML parse errors
# without going through setup.sh.

load helper

setup() {
  setup_tmp_dir
  load_lib schema
  load_lib yaml
  yaml_require_yq >/dev/null
}

teardown() { teardown_tmp_dir; }

# Minimal "happy path" agent.yml that should always validate. Tests
# below mutate one field at a time off this baseline.
_write_valid_yml() {
  cat > "$TMP_TEST_DIR/agent.yml" <<'YML'
version: 1
agent:
  name: validbot
user:
  timezone: UTC
  email: a@b.com
deployment:
  workspace: "/tmp/validbot"
docker:
  uid: 1000
  gid: 1000
  image_tag: "agent-admin:latest"
  base_image: "alpine:3.20"
notifications:
  channel: none
features:
  heartbeat:
    enabled: true
    interval: "30m"
    timeout: 300
    retries: 1
    default_prompt: "ok"
YML
}

@test "agent_yml_validate: happy path returns 0 silently" {
  _write_valid_yml
  run agent_yml_validate "$TMP_TEST_DIR/agent.yml"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "agent_yml_validate: missing file → 1 with clear error" {
  run agent_yml_validate "$TMP_TEST_DIR/does-not-exist.yml"
  [ "$status" -eq 1 ]
  [[ "$output" == *"file not found"* ]]
}

@test "agent_yml_validate: malformed YAML → 1 with parse error" {
  cat > "$TMP_TEST_DIR/agent.yml" <<'YML'
this is: [not valid yaml
YML
  run agent_yml_validate "$TMP_TEST_DIR/agent.yml"
  [ "$status" -eq 1 ]
  [[ "$output" == *"malformed YAML"* ]]
}

@test "agent_yml_validate: missing top-level block → reported" {
  _write_valid_yml
  yq -i 'del(.notifications)' "$TMP_TEST_DIR/agent.yml"
  run agent_yml_validate "$TMP_TEST_DIR/agent.yml"
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing required field: .notifications"* ]]
}

@test "agent_yml_validate: missing leaf value → reported" {
  _write_valid_yml
  yq -i 'del(.user.email)' "$TMP_TEST_DIR/agent.yml"
  run agent_yml_validate "$TMP_TEST_DIR/agent.yml"
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing required field: .user.email"* ]]
}

@test "agent_yml_validate: empty leaf value treated as missing" {
  _write_valid_yml
  yq -i '.user.email = ""' "$TMP_TEST_DIR/agent.yml"
  run agent_yml_validate "$TMP_TEST_DIR/agent.yml"
  [ "$status" -eq 1 ]
  [[ "$output" == *".user.email"* ]]
}

@test "agent_yml_validate: notifications.channel enum violation → reported" {
  _write_valid_yml
  yq -i '.notifications.channel = "telegrampls"' "$TMP_TEST_DIR/agent.yml"
  run agent_yml_validate "$TMP_TEST_DIR/agent.yml"
  [ "$status" -eq 1 ]
  [[ "$output" == *"channel must be one of"* ]]
  [[ "$output" == *"telegrampls"* ]]
}

@test "agent_yml_validate: notifications.channel valid enum values pass" {
  _write_valid_yml
  for v in none log telegram; do
    yq -i ".notifications.channel = \"$v\"" "$TMP_TEST_DIR/agent.yml"
    run agent_yml_validate "$TMP_TEST_DIR/agent.yml"
    [ "$status" -eq 0 ] || { echo "channel=$v failed: $output"; return 1; }
  done
}

@test "agent_yml_validate: heartbeat.enabled bool typo (yes) → reported" {
  _write_valid_yml
  # yq writes the literal string "yes" so the YAML stays a string, not
  # the YAML 1.1 truthy alias yq normalises away in some modes.
  yq -i '.features.heartbeat.enabled = "yes"' "$TMP_TEST_DIR/agent.yml"
  run agent_yml_validate "$TMP_TEST_DIR/agent.yml"
  [ "$status" -eq 1 ]
  [[ "$output" == *"heartbeat.enabled must be a YAML boolean"* ]]
}

@test "agent_yml_validate: aggregates multiple errors in one run" {
  _write_valid_yml
  yq -i 'del(.user.email) | del(.user.timezone) | .notifications.channel = "bogus"' \
    "$TMP_TEST_DIR/agent.yml"
  run agent_yml_validate "$TMP_TEST_DIR/agent.yml"
  [ "$status" -eq 1 ]
  # Error count line: "agent.yml schema validation failed (3 issue(s)):"
  [[ "$output" == *"3 issue"* ]]
  [[ "$output" == *".user.email"* ]]
  [[ "$output" == *".user.timezone"* ]]
  [[ "$output" == *"channel must be one of"* ]]
}
