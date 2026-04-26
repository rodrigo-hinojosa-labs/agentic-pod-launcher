#!/usr/bin/env bats

load helper

setup() {
  load_lib yaml
  load_lib render
  FIXTURE="$REPO_ROOT/tests/fixtures/sample-agent.yml"
  render_load_context "$FIXTURE"
}

@test "render_template substitutes simple placeholders" {
  export USER_NAME="Alice Example"
  export AGENT_DISPLAY_NAME="TestAgent 🤖"
  export DEPLOYMENT_WORKSPACE="/tmp/work"
  result=$(render_template "$REPO_ROOT/tests/fixtures/simple.tpl")
  [[ "$result" == *"Hello Alice Example"* ]]
  [[ "$result" == *"welcome to TestAgent 🤖"* ]]
  [[ "$result" == *"workspace is /tmp/work"* ]]
}

@test "render_template includes {{#if}} block when true" {
  export FEATURES_HEARTBEAT_ENABLED=true
  export FEATURES_HEARTBEAT_INTERVAL="15m"
  export MCPS_GITHUB_ENABLED=false
  result=$(render_template "$REPO_ROOT/tests/fixtures/conditional.tpl")
  [[ "$result" == *"Heartbeat runs every 15m"* ]]
  [[ "$result" == *"GitHub MCP is disabled"* ]]
  [[ "$result" == *"Core content"* ]]
  [[ "$result" == *"End."* ]]
}

@test "render_template excludes {{#if}} block when false" {
  export FEATURES_HEARTBEAT_ENABLED=false
  export MCPS_GITHUB_ENABLED=true
  result=$(render_template "$REPO_ROOT/tests/fixtures/conditional.tpl")
  [[ "$result" != *"Heartbeat runs every"* ]]
  [[ "$result" != *"GitHub MCP is disabled"* ]]
}

@test "render_template expands {{#each}} over array" {
  result=$(render_template "$REPO_ROOT/tests/fixtures/loop.tpl")
  [[ "$result" == *"- work at https://work.atlassian.net (alice@work.com)"* ]]
  [[ "$result" == *"- personal at https://personal.atlassian.net (alice@personal.com)"* ]]
  [[ "$result" == *"Done."* ]]
}

@test "render_template preserves literal \$1 and \\1 in field values" {
  # Regression: perl's s/.../$repl/ used to interpolate $1, $2 (capture
  # refs) and \1, \2 (backrefs) inside the replacement string, so a
  # field value containing those would be silently corrupted. The
  # current engine routes the replacement through ENV{REPL} with /e
  # so the value is treated as literal data.
  local tmp_yml="$BATS_TEST_TMPDIR/yml.yml"
  local tmp_tpl="$BATS_TEST_TMPDIR/tpl.tpl"
  cat > "$tmp_yml" <<'YML'
version: 1
mcps:
  atlassian:
    - name: q1
      url: 'https://q1.example/path?ref=$1&v=\1'
      email: '$2-test@example.com'
YML
  cat > "$tmp_tpl" <<'TPL'
{{#each MCPS_ATLASSIAN}}
- {{name}}: {{url}} ({{email}})
{{/each}}
TPL
  render_load_context "$tmp_yml"
  result=$(render_template "$tmp_tpl")
  [[ "$result" == *'https://q1.example/path?ref=$1&v=\1'* ]]
  [[ "$result" == *'$2-test@example.com'* ]]
}
