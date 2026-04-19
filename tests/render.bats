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
