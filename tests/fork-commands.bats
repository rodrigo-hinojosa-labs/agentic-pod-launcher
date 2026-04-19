#!/usr/bin/env bats
# Tests for --sync-template and --delete-fork command gating.
# These only exercise the preconditions that don't require network or a real
# GitHub PAT; end-to-end behavior is validated manually against a live fork.

load helper

setup() {
  setup_tmp_dir
  mkdir -p "$TMP_TEST_DIR/agent"
  cp -r "$REPO_ROOT/scripts" "$REPO_ROOT/modules" "$TMP_TEST_DIR/agent/"
  cp "$REPO_ROOT/setup.sh" "$TMP_TEST_DIR/agent/"
}

teardown() { teardown_tmp_dir; }

write_agent_yml() {
  local fork_enabled="$1"
  cat > "$TMP_TEST_DIR/agent/agent.yml" << EOF
version: 1
agent:
  name: test-agent
user:
  name: "Test User"
  email: "test@example.com"
  language: en
deployment:
  host: testhost
  workspace: $TMP_TEST_DIR/agent
scaffold:
  fork:
    enabled: $fork_enabled
    owner: test-org
    name: test-agent-testhost
EOF
}

@test "--sync-template fails when agent.yml is missing" {
  cd "$TMP_TEST_DIR/agent"
  run ./setup.sh --sync-template
  [ "$status" -ne 0 ]
  [[ "$output" == *"agent.yml not found"* ]]
}

@test "--sync-template fails when .git is missing" {
  write_agent_yml true
  cd "$TMP_TEST_DIR/agent"
  run ./setup.sh --sync-template
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a git repo"* ]]
}

@test "--sync-template fails on legacy agents without fork" {
  write_agent_yml false
  cd "$TMP_TEST_DIR/agent"
  git init -q
  run ./setup.sh --sync-template
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires a fork-based agent"* ]]
}

@test "--delete-fork requires --yes" {
  write_agent_yml true
  cd "$TMP_TEST_DIR/agent"
  # Pipe 'y' to pass the interactive confirmation so we hit the
  # --delete-fork specific check rather than the generic abort.
  run bash -c "echo y | ./setup.sh --uninstall --delete-fork"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--delete-fork requires --yes"* ]]
}
