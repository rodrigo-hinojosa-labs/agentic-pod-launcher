#!/usr/bin/env bats
#
# 037 — vault.review.{project_days,area_days}, vault.archive.candidate_days:
# same molde as tests/mcp-handshake-timeout.bats (029). Two independent
# surfaces read these keys: setup.sh --regenerate (WARN-only, no render
# target) and scripts/lib/wiki_graph.sh (writes .graph/policy.json at
# runtime — the actual consumer). Both are covered here.
# Contract: specs/037-second-brain-rag/contracts/agent-yml-config-037.md

load helper

setup() {
  setup_tmp_dir
  cp -r "$REPO_ROOT/scripts" "$REPO_ROOT/modules" "$TMP_TEST_DIR/"
  cp "$REPO_ROOT/setup.sh" "$TMP_TEST_DIR/"
  touch "$TMP_TEST_DIR/.env"
  CLAUDE_STUB=$(install_claude_stub)
  load_lib wiki_graph
}

teardown() { teardown_tmp_dir; }

# Minimal schema-valid docker-mode agent.yml. $1 controls
# vault.review.project_days: a value ("14") -> emit it; "OMIT" -> no field;
# "NULL" -> empty value.
_write_agent_yml() {
  local pd="$1"
  local vault_block='vault:
  enabled: true
  path: .state/.vault
  seed_skeleton: true'
  case "$pd" in
    OMIT) : ;;
    NULL) vault_block="${vault_block}
  review:
    project_days:" ;;
    *)    vault_block="${vault_block}
  review:
    project_days: ${pd}" ;;
  esac
  cat > "$TMP_TEST_DIR/agent.yml" << EOF
version: 1
agent:
  name: review-bot
  display_name: "ReviewBot"
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
  workspace: "/tmp/review-bot"
  install_service: false
  mode: docker
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
  - telegram@claude-plugins-official
${vault_block}
EOF
}

# ── setup.sh --regenerate: WARN by key, never by value ───────────────────────

@test "037: valid vault.review.project_days=14 regenerates with no WARN" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml 14
  run bash -c "echo 'n' | ./setup.sh --regenerate"
  [ "$status" -eq 0 ]
  [[ "$output" != *"vault.review.project_days"* ]]
  [ "$(yq -r '.vault.review.project_days' agent.yml)" = "14" ]
}

@test "037: vault.review.project_days=abc WARNs by key, agent.yml keeps the operator's value" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml '"abc"'
  run bash -c "echo 'n' | ./setup.sh --regenerate"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN"* ]]
  [[ "$output" == *"vault.review.project_days"* ]]
  [[ "$output" != *"abc"* ]]
  [ "$(yq -r '.vault.review.project_days' agent.yml)" = "abc" ]
}

@test "037: vault.review.project_days=0 WARNs (never a valid day count)" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml 0
  run bash -c "echo 'n' | ./setup.sh --regenerate"
  [[ "$output" == *"WARN"* ]]
  [[ "$output" == *"vault.review.project_days"* ]]
  [[ "$output" != *$'project_days, using default 0'* ]]
}

@test "037: vault.review.project_days=99999 (oversized) WARNs" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml 99999
  run bash -c "echo 'n' | ./setup.sh --regenerate"
  [[ "$output" == *"WARN"* ]]
  [[ "$output" == *"vault.review.project_days"* ]]
  [[ "$output" != *"99999"* ]]
}

@test "037: vault.review.project_days=NULL does not WARN (empty is 'absent', not invalid)" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml NULL
  run bash -c "echo 'n' | ./setup.sh --regenerate"
  [ "$status" -eq 0 ]
  [[ "$output" != *"vault.review.project_days"* ]]
}

@test "037: vault.review.project_days=OMIT backfills to 7, no WARN" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml OMIT
  run bash -c "echo 'n' | ./setup.sh --regenerate"
  [ "$status" -eq 0 ]
  [[ "$output" != *"vault.review.project_days"* ]]
  [ "$(yq -r '.vault.review.project_days' agent.yml)" = "7" ]
}

# ── wiki_graph.sh: policy.json always gets a valid 1..3650 value ────────────

_run_wg() {
  local ay="$1"
  VAULT_TMP="$TMP_TEST_DIR/wgvault"
  mkdir -p "$VAULT_TMP/wiki"
  WIKI_GRAPH_VAULT_DIR="$VAULT_TMP" WIKI_GRAPH_STATE_FILE="$TMP_TEST_DIR/wg.json" \
    WIKI_GRAPH_LOCK="$TMP_TEST_DIR/.wg.lock" wiki_graph_run "$ay"
}

@test "037: policy.json.review.project_days is 14 for a valid value, 7 for garbage/absent" {
  for v in 14 OMIT NULL '"abc"' 0 99999; do
    _write_agent_yml "$v"
    _run_wg "$TMP_TEST_DIR/agent.yml" >/dev/null 2>&1
    local got; got=$(jq -r '.review.project_days' "$VAULT_TMP/.graph/policy.json")
    if [ "$v" = "14" ]; then
      [ "$got" = "14" ] || { echo "v=$v got=$got (expected 14)" >&2; return 1; }
    else
      [ "$got" = "7" ] || { echo "v=$v got=$got (expected 7)" >&2; return 1; }
    fi
  done
}

@test "037: WIKI_GRAPH_REVIEW_PROJECT_DAYS=3 wins over agent.yml (test seam)" {
  _write_agent_yml 14
  WIKI_GRAPH_REVIEW_PROJECT_DAYS=3 _run_wg "$TMP_TEST_DIR/agent.yml" >/dev/null 2>&1
  [ "$(jq -r '.review.project_days' "$VAULT_TMP/.graph/policy.json")" = "3" ]
}

@test "037: area_days and candidate_days follow the same rule (spot check)" {
  cat > "$TMP_TEST_DIR/agent2.yml" << 'EOF'
vault:
  enabled: true
  review: {area_days: "bogus"}
  archive: {candidate_days: 45}
EOF
  _run_wg "$TMP_TEST_DIR/agent2.yml" >/dev/null 2>&1
  [ "$(jq -r '.review.area_days' "$VAULT_TMP/.graph/policy.json")" = "30" ]
  [ "$(jq -r '.archive.candidate_days' "$VAULT_TMP/.graph/policy.json")" = "45" ]
}
