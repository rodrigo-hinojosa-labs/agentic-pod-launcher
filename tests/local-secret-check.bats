#!/usr/bin/env bats
# 021-local-secret-delivery (US3/T014): the boot-time secret-check script
# (modules/local-secret-check.sh.tpl -> scripts/local/agent-secret-check.sh).
# Same detection logic as agentctl doctor's _local_secrets_doctor, wired as
# ExecStartPre=- on the session unit (contract U3). Must NEVER fail the boot:
# always exits 0, regardless of what it finds.

load helper

setup() {
  setup_tmp_dir
  load_lib render
  load_lib yaml
  yaml_require_yq >/dev/null
  command -v jq >/dev/null || skip "jq not installed"

  WS="$TMP_TEST_DIR"
  mkdir -p "$WS/scripts/lib" "$WS/modules/mcps"
  cp "$REPO_ROOT/scripts/lib/env_file.sh" "$WS/scripts/lib/"
  cp "$REPO_ROOT/scripts/lib/mcp-catalog.sh" "$WS/scripts/lib/"
  cp "$REPO_ROOT/modules/mcps/"*.yml "$WS/modules/mcps/"

  cat > "$WS/agent.yml" << 'YML'
version: 1
agent: {name: locbot, display_name: "LocBot", role: "r", vibe: "v"}
user: {name: A, nickname: A, timezone: UTC, email: a@b.com, language: en}
deployment: {host: rpi5, workspace: WORKSPACE_PLACEHOLDER, install_service: false, claude_cli: claude, mode: local}
docker: {image_tag: "x:latest", uid: 1000, gid: 1000, base_image: "alpine:3.20"}
notifications: {channel: none}
features: {heartbeat: {enabled: true, interval: "30m", timeout: 300, retries: 1, default_prompt: "ok"}}
mcps:
  defaults: [fetch, git, filesystem]
  atlassian: []
  github: {enabled: false}
YML
  sed -i.bak "s#WORKSPACE_PLACEHOLDER#$WS#" "$WS/agent.yml"
  rm -f "$WS/agent.yml.bak"

  render_load_context "$WS/agent.yml" >/dev/null
  render_to_file "$REPO_ROOT/modules/local-secret-check.sh.tpl" "$WS/agent-secret-check.sh"
  chmod +x "$WS/agent-secret-check.sh"
}

teardown() { teardown_tmp_dir; }

@test "secret-check: .env missing → WARN on stderr, still exits 0" {
  run "$TMP_TEST_DIR/agent-secret-check.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN"* && "$output" == *".env not found"* ]]
}

@test "secret-check: a required secret is empty → WARN naming the variable, still exits 0" {
  cat > "$TMP_TEST_DIR/agent.yml" << YML
version: 1
agent: {name: locbot, display_name: "LocBot", role: "r", vibe: "v"}
user: {name: A, nickname: A, timezone: UTC, email: a@b.com, language: en}
deployment: {host: rpi5, workspace: "$TMP_TEST_DIR", install_service: false, claude_cli: claude, mode: local}
docker: {image_tag: "x:latest", uid: 1000, gid: 1000, base_image: "alpine:3.20"}
notifications: {channel: none}
features: {heartbeat: {enabled: true, interval: "30m", timeout: 300, retries: 1, default_prompt: "ok"}}
mcps:
  defaults: [fetch, git, filesystem, firecrawl]
  atlassian: []
  github: {enabled: false}
YML
  printf 'FIRECRAWL_API_KEY=\n' > "$TMP_TEST_DIR/.env"
  run "$TMP_TEST_DIR/agent-secret-check.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN"* && "$output" == *"FIRECRAWL_API_KEY"* ]]
}

@test "secret-check: a healthy .env with no required secrets → no WARN output" {
  printf 'CLAUDE_CODE_OAUTH_TOKEN=x\n' > "$TMP_TEST_DIR/.env"
  run "$TMP_TEST_DIR/agent-secret-check.sh"
  [ "$status" -eq 0 ]
  if printf '%s' "$output" | grep -q 'WARN'; then false; fi
}

@test "secret-check: a lint-dirty .env → WARN naming line+key, value never printed, still exits 0" {
  printf 'GITHUB_PAT=ghp_supersecrettoken12345\\\n' > "$TMP_TEST_DIR/.env"
  run "$TMP_TEST_DIR/agent-secret-check.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"GITHUB_PAT"* ]]
  if printf '%s' "$output" | grep -q 'ghp_supersecrettoken12345'; then false; fi
}
