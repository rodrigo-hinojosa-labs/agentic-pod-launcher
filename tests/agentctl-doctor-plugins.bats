#!/usr/bin/env bats
# Story C (003-bootstrap-hardening): `agentctl doctor` surfaces plugins that
# failed to install — reading the bind-mounted .state/plugin-install-failures
# .jsonl the supervisor writes — each with a copy-paste retry command (FR-C3).
# Host-only; agentctl is sourced with AGENTCTL_NO_RUN=1 (no Docker, Principle III).

load helper

setup() {
  setup_tmp_dir
  export AGENTCTL_NO_RUN=1
  # shellcheck source=/dev/null
  source "$REPO_ROOT/scripts/agentctl"
  _doctor_fail_count=0
  _doctor_warn_count=0
  WS="$TMP_TEST_DIR/ws"
  mkdir -p "$WS/.state"
}

teardown() { teardown_tmp_dir; }

@test "_doctor_check_plugin_failures: pass when no failures file" {
  run _doctor_check_plugin_failures "$WS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"✓"* ]]
  [[ "$output" != *"✗"* ]]
}

@test "_doctor_check_plugin_failures: pass when failures file is empty" {
  : > "$WS/.state/plugin-install-failures.jsonl"
  run _doctor_check_plugin_failures "$WS"
  [[ "$output" == *"✓"* ]]
  [[ "$output" != *"✗"* ]]
}

@test "_doctor_check_plugin_failures: reports each failed plugin + retry command" {
  cat > "$WS/.state/plugin-install-failures.jsonl" <<'JSONL'
{"spec":"claude-mem@thedotmack","error":"boom","ts":"2026-06-20T14:18:22Z"}
{"spec":"superpowers@claude-plugins-official","error":"net","ts":"2026-06-20T14:18:30Z"}
JSONL
  run _doctor_check_plugin_failures "$WS"
  [[ "$output" == *"✗"* ]]
  [[ "$output" == *"claude-mem@thedotmack"* ]]
  [[ "$output" == *"superpowers@claude-plugins-official"* ]]
  [[ "$output" == *"plugin install claude-mem@thedotmack"* ]]   # retry command present
}
