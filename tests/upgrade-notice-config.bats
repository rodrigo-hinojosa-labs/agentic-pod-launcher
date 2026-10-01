#!/usr/bin/env bats
#
# 038 - features.upgrade_notice toggle (agent.yml as single source of truth). A pre-038
# workspace has no features.upgrade_notice block; --regenerate must backfill
# `enabled: true` (the notice is base behaviour, not opt-in) WITHOUT clobbering an
# operator's explicit value. The backfill is has()-guarded, never `//`: yq's `//`
# collapses an explicit `false` exactly like null, so a `//` backfill would silently
# re-enable a notice the operator turned off. Mirrors tests/askq-guard-config.bats (031).
# Contract: specs/038-schema-delta-boot-nudge/data-model.md section 2.

load helper

setup() {
  setup_tmp_dir
  cp -r "$REPO_ROOT/scripts" "$REPO_ROOT/modules" "$TMP_TEST_DIR/"
  cp "$REPO_ROOT/setup.sh" "$TMP_TEST_DIR/"
  CLAUDE_STUB=$(install_claude_stub)
  load_lib schema
  load_lib yaml
  yaml_require_yq >/dev/null
}

teardown() { teardown_tmp_dir; }

# A minimal, schema-valid docker-mode agent.yml with NO features.upgrade_notice block.
_write_agent_yml() {
  cat > "$TMP_TEST_DIR/agent.yml" << 'YML'
version: 1
agent:
  name: un-bot
  display_name: "UN"
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
  workspace: "/tmp/un-bot"
  install_service: false
docker:
  image_tag: "agent-admin:latest"
  uid: 1000
  gid: 1000
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
mcps:
  atlassian: []
  github:
    enabled: false
plugins:
  - claude-mem@thedotmack
YML
}

# --- backfill -------------------------------------------------------------------

@test "038: --regenerate backfills features.upgrade_notice.enabled=true on a pre-038 agent.yml" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml
  [ "$(yq -r '.features | has("upgrade_notice")' agent.yml)" = "false" ]
  echo 'n' | ./setup.sh --regenerate
  [ "$(yq -r '.features.upgrade_notice.enabled' agent.yml)" = "true" ]
}

@test "038: an operator's explicit enabled:false survives two --regenerate runs (has(), not //)" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml
  yq -i '.features.upgrade_notice.enabled = false' agent.yml
  echo 'n' | ./setup.sh --regenerate
  [ "$(yq -r '.features.upgrade_notice.enabled' agent.yml)" = "false" ]
  echo 'n' | ./setup.sh --regenerate
  [ "$(yq -r '.features.upgrade_notice.enabled' agent.yml)" = "false" ]
}

@test "038: an explicit enabled:true is left as is" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml
  yq -i '.features.upgrade_notice.enabled = true' agent.yml
  echo 'n' | ./setup.sh --regenerate
  [ "$(yq -r '.features.upgrade_notice.enabled' agent.yml)" = "true" ]
}

@test "038: the backfill adds exactly one key under upgrade_notice (no stray fields)" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml
  echo 'n' | ./setup.sh --regenerate
  [ "$(yq -r '.features.upgrade_notice | keys | join(",")' agent.yml)" = "enabled" ]
}

@test "038: a second --regenerate leaves agent.yml unchanged apart from meta.regenerated_at" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml
  echo 'n' | ./setup.sh --regenerate
  yq 'del(.meta.regenerated_at)' agent.yml > first.yml
  echo 'n' | ./setup.sh --regenerate
  yq 'del(.meta.regenerated_at)' agent.yml > second.yml
  cmp -s first.yml second.yml
}

# --- schema -----------------------------------------------------------------------

@test "038: agent_yml_validate accepts true and false" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml
  yq -i '.features.upgrade_notice.enabled = true' agent.yml
  run agent_yml_validate "$TMP_TEST_DIR/agent.yml"
  [ "$status" -eq 0 ]
  yq -i '.features.upgrade_notice.enabled = false' agent.yml
  run agent_yml_validate "$TMP_TEST_DIR/agent.yml"
  [ "$status" -eq 0 ]
}

@test "038: agent_yml_validate rejects a non-boolean enabled (yes)" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml
  yq -i '.features.upgrade_notice.enabled = "yes"' agent.yml
  run agent_yml_validate "$TMP_TEST_DIR/agent.yml"
  [ "$status" -eq 1 ]
  [[ "$output" == *"features.upgrade_notice.enabled must be a YAML boolean"* ]]
}

# --- fixtures and the wizard --------------------------------------------------------

@test "038: both sample fixtures carry features.upgrade_notice.enabled (schema.bats needs the placeholder produced)" {
  [ "$(yq -r '.features.upgrade_notice.enabled' "$REPO_ROOT/tests/fixtures/sample-agent.yml")" = "true" ]
  [ "$(yq -r '.features.upgrade_notice.enabled' "$REPO_ROOT/tests/fixtures/sample-agent-with-vault.yml")" = "true" ]
}

@test "038: a freshly scaffolded agent (wizard) gets the switch on, its baseline and the hook, with nothing pending (SC-007)" {
  mkdir -p "$TMP_TEST_DIR/installer"
  cp -r "$REPO_ROOT/scripts" "$REPO_ROOT/modules" "$REPO_ROOT/docker" "$TMP_TEST_DIR/installer/"
  cp "$REPO_ROOT/setup.sh" "$TMP_TEST_DIR/installer/"
  cd "$TMP_TEST_DIR/installer"
  local dest="$TMP_TEST_DIR/scaffolded"
  wizard_answers name=unbot display=UNBot | ./setup.sh --destination "$dest"
  [ -f "$dest/agent.yml" ]
  [ "$(yq -r '.features.upgrade_notice.enabled' "$dest/agent.yml")" = "true" ]
  # a new workspace starts with today's render recorded as both the upstream render and the baseline
  cmp -s "$dest/CLAUDE.md" "$dest/.state/launcher/claude-md.upstream.md"
  cmp -s "$dest/CLAUDE.md" "$dest/.state/launcher/claude-md.baseline.md"
  # the hook and its installer are rendered, and the hook has nothing to say
  [ -x "$dest/scripts/hooks/upgrade-notice.sh" ]
  [ -x "$dest/scripts/hooks/install-upgrade-notice-hook.sh" ]
  run env "$dest/scripts/hooks/upgrade-notice.sh" < /dev/null
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
