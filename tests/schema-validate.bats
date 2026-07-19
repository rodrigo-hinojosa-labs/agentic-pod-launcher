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

# 005-fix-schema-false: a required boolean leaf set to its valid `false` value
# must validate — it is PRESENT, not missing. Regression: `yq '$path // ""'`
# collapsed a present `false` to "" so the required-leaf check wrongly flagged
# it as a missing field, blocking --regenerate for any feature-disabled agent.
@test "agent_yml_validate: required boolean leaf set to false validates (not 'missing')" {
  _write_valid_yml
  yq -i '.features.heartbeat.enabled = false' "$TMP_TEST_DIR/agent.yml"
  run agent_yml_validate "$TMP_TEST_DIR/agent.yml"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "agent_yml_validate: genuinely absent required boolean leaf still reported missing" {
  _write_valid_yml
  yq -i 'del(.features.heartbeat.enabled)' "$TMP_TEST_DIR/agent.yml"
  run agent_yml_validate "$TMP_TEST_DIR/agent.yml"
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing required field: .features.heartbeat.enabled"* ]]
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

@test "agent_yml_validate: valid toolchain channel passes" {
  _write_valid_yml
  yq -i '.docker.toolchain_channels.claude_code = "pinned"' "$TMP_TEST_DIR/agent.yml"
  run agent_yml_validate "$TMP_TEST_DIR/agent.yml"
  [ "$status" -eq 0 ]
}

@test "agent_yml_validate: invalid toolchain channel → reported" {
  _write_valid_yml
  yq -i '.docker.toolchain_channels.claude_code = "bleeding"' "$TMP_TEST_DIR/agent.yml"
  run agent_yml_validate "$TMP_TEST_DIR/agent.yml"
  [ "$status" -eq 1 ]
  [[ "$output" == *"toolchain_channels"* ]]
  [[ "$output" == *"bleeding"* ]]
}

@test "agent_yml_validate: absent toolchain_channels still validates (legacy-safe)" {
  _write_valid_yml
  run agent_yml_validate "$TMP_TEST_DIR/agent.yml"
  [ "$status" -eq 0 ]
}

@test "agent_yml_validate: role_file present and non-empty validates" {
  _write_valid_yml
  yq -i '.agent.role_file = "personas/validbot.md"' "$TMP_TEST_DIR/agent.yml"
  run agent_yml_validate "$TMP_TEST_DIR/agent.yml"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "agent_yml_validate: role_file present but empty → reported" {
  _write_valid_yml
  yq -i '.agent.role_file = ""' "$TMP_TEST_DIR/agent.yml"
  run agent_yml_validate "$TMP_TEST_DIR/agent.yml"
  [ "$status" -eq 1 ]
  [[ "$output" == *"role_file"* ]]
}

# 010-self-managing-rag: vault.qmd.* validation.
@test "agent_yml_validate: vault.qmd.enabled bool typo (ture) → reported" {
  _write_valid_yml
  yq -i '.vault.qmd.enabled = "ture"' "$TMP_TEST_DIR/agent.yml"
  run agent_yml_validate "$TMP_TEST_DIR/agent.yml"
  [ "$status" -eq 1 ]
  [[ "$output" == *"vault.qmd.enabled must be a YAML boolean"* ]]
}

@test "agent_yml_validate: vault.qmd.enabled=false validates (present, not missing)" {
  _write_valid_yml
  yq -i '.vault.qmd.enabled = false' "$TMP_TEST_DIR/agent.yml"
  run agent_yml_validate "$TMP_TEST_DIR/agent.yml"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "agent_yml_validate: vault.enabled bool typo → reported (012 T031)" {
  _write_valid_yml
  yq -i '.vault.enabled = "yep"' "$TMP_TEST_DIR/agent.yml"
  run agent_yml_validate "$TMP_TEST_DIR/agent.yml"
  [ "$status" -eq 1 ]
  [[ "$output" == *"vault.enabled must be a YAML boolean"* ]]
}

@test "agent_yml_validate: vault.mcp.enabled bool typo → reported (012 T031)" {
  _write_valid_yml
  yq -i '.vault.mcp.enabled = 1' "$TMP_TEST_DIR/agent.yml"
  run agent_yml_validate "$TMP_TEST_DIR/agent.yml"
  [ "$status" -eq 1 ]
  [[ "$output" == *"vault.mcp.enabled must be a YAML boolean"* ]]
}

@test "agent_yml_validate: vault.path present but empty → reported (012 T031)" {
  _write_valid_yml
  yq -i '.vault.path = ""' "$TMP_TEST_DIR/agent.yml"
  run agent_yml_validate "$TMP_TEST_DIR/agent.yml"
  [ "$status" -eq 1 ]
  [[ "$output" == *"vault.path"* ]]
}

@test "agent_yml_validate: vault.enabled/path absent still validates (legacy-safe, 012 T031)" {
  _write_valid_yml
  yq -i 'del(.vault)' "$TMP_TEST_DIR/agent.yml"
  run agent_yml_validate "$TMP_TEST_DIR/agent.yml"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "agent_yml_validate: vault.qmd.version present but empty → reported" {
  _write_valid_yml
  yq -i '.vault.qmd.version = ""' "$TMP_TEST_DIR/agent.yml"
  run agent_yml_validate "$TMP_TEST_DIR/agent.yml"
  [ "$status" -eq 1 ]
  [[ "$output" == *"vault.qmd.version"* ]]
}

@test "agent_yml_validate: well-formed vault.qmd block validates" {
  _write_valid_yml
  yq -i '.vault.enabled = true | .vault.qmd.enabled = true | .vault.qmd.version = "2.5.3" | .vault.qmd.schedule = "*/5 * * * *"' "$TMP_TEST_DIR/agent.yml"
  run agent_yml_validate "$TMP_TEST_DIR/agent.yml"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "agent_yml_validate: vault.qmd.enabled=true without version validates (regenerate backfills the pin)" {
  # The pre-010 upgrade path: QMD opted in, no version key yet. Schema must NOT
  # block this — setup.sh --regenerate backfills vault.qmd.version=2.5.3 so the
  # rendered pin stays valid (contracts/agent-yml-schema.md). Fail-loud here
  # would break the documented zero-touch upgrade.
  _write_valid_yml
  yq -i '.vault.enabled = true | .vault.qmd.enabled = true' "$TMP_TEST_DIR/agent.yml"
  run agent_yml_validate "$TMP_TEST_DIR/agent.yml"
  [ "$status" -eq 0 ]
}

@test "agent_yml_validate: absent vault.qmd still validates (legacy-safe)" {
  _write_valid_yml
  run agent_yml_validate "$TMP_TEST_DIR/agent.yml"
  [ "$status" -eq 0 ]
}

# 011-local-standalone-mode: deployment.mode enum (docker|local). Optional +
# enum-checked: absent is valid (legacy = docker), a present value must be in
# the enum. NOT added to required-leaves (backfilled on --regenerate).
@test "agent_yml_validate: deployment.mode=docker validates" {
  _write_valid_yml
  yq -i '.deployment.mode = "docker"' "$TMP_TEST_DIR/agent.yml"
  run agent_yml_validate "$TMP_TEST_DIR/agent.yml"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "agent_yml_validate: deployment.mode=local validates" {
  _write_valid_yml
  yq -i '.deployment.mode = "local"' "$TMP_TEST_DIR/agent.yml"
  run agent_yml_validate "$TMP_TEST_DIR/agent.yml"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "agent_yml_validate: deployment.mode bogus value → reported" {
  _write_valid_yml
  yq -i '.deployment.mode = "kubernetes"' "$TMP_TEST_DIR/agent.yml"
  run agent_yml_validate "$TMP_TEST_DIR/agent.yml"
  [ "$status" -eq 1 ]
  [[ "$output" == *"deployment.mode must be one of"* ]]
  [[ "$output" == *"kubernetes"* ]]
}

@test "agent_yml_validate: absent deployment.mode validates (legacy-safe)" {
  _write_valid_yml
  run agent_yml_validate "$TMP_TEST_DIR/agent.yml"
  [ "$status" -eq 0 ]
}

# 022-local-session-lifecycle (US3/N9): deployment.session_name is an optional
# string leaf — absent is the norm (the default is backfilled on --regenerate),
# but a key that IS present must carry a real value. An empty one would render
# `--name ""` into the unit and hand the operator an unnamed agent.
@test "agent_yml_validate: deployment.session_name present and non-empty validates" {
  _write_valid_yml
  yq -i '.deployment.session_name = "bitacora"' "$TMP_TEST_DIR/agent.yml"
  run agent_yml_validate "$TMP_TEST_DIR/agent.yml"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "agent_yml_validate: deployment.session_name present but empty → reported" {
  _write_valid_yml
  yq -i '.deployment.session_name = ""' "$TMP_TEST_DIR/agent.yml"
  run agent_yml_validate "$TMP_TEST_DIR/agent.yml"
  [ "$status" -eq 1 ]
  [[ "$output" == *"session_name"* ]]
}

@test "agent_yml_validate: deployment.session_name absent is fine (the default case)" {
  _write_valid_yml
  run agent_yml_validate "$TMP_TEST_DIR/agent.yml"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
