#!/usr/bin/env bats
# 015 US1: the local systemd unit's ExecStart MUST be an absolute, executable
# path, independent of the PATH of the shell that ran --regenerate. systemd
# resolves ExecStart against the manager PATH (it ignores the unit's
# Environment=PATH), so a bare `claude` — where the native installer puts it at
# ~/.local/bin/claude, outside that PATH — breaks with status=203/EXEC.
#
# The render side (absolute CLAUDE_BIN -> absolute ExecStart) is covered by
# local-render.bats; here we test the RESOLUTION that must feed it an absolute
# value even when `command -v claude` fails, plus the fail-loud and the
# agent.yml write-back (Principle I).
load 'helper'

setup() {
  setup_tmp_dir
  SCRIPT_DIR="$BATS_TEST_DIRNAME/.."
  # setup.sh guards main() behind BASH_SOURCE, so sourcing just defines functions.
  source "$SCRIPT_DIR/setup.sh" >/dev/null 2>&1 || true
  load_lib yaml
  yaml_require_yq >/dev/null

  # Fake operator HOME with claude ONLY in ~/.local/bin (native installer layout).
  FAKE_HOME="$TMP_TEST_DIR/home"
  mkdir -p "$FAKE_HOME/.local/bin"
  printf '#!/bin/sh\necho claude\n' > "$FAKE_HOME/.local/bin/claude"
  chmod +x "$FAKE_HOME/.local/bin/claude"

  EMPTY_HOME="$TMP_TEST_DIR/empty"
  mkdir -p "$EMPTY_HOME"
}

teardown() { teardown_tmp_dir; }

@test "resolve_claude_bin: finds ~/.local/bin/claude when not on PATH (C1)" {
  local saved="$PATH"
  PATH="/usr/bin:/bin"
  run resolve_claude_bin claude "$FAKE_HOME"
  PATH="$saved"
  [ "$status" -eq 0 ]
  [ "$output" = "$FAKE_HOME/.local/bin/claude" ]
}

@test "resolve_claude_bin: honors an already-absolute executable value (C2)" {
  run resolve_claude_bin "$FAKE_HOME/.local/bin/claude" "$FAKE_HOME"
  [ "$status" -eq 0 ]
  [ "$output" = "$FAKE_HOME/.local/bin/claude" ]
}

@test "resolve_claude_bin: re-resolves a bare literal to absolute (C3)" {
  local saved="$PATH"
  PATH="/usr/bin:/bin"
  run resolve_claude_bin "claude" "$FAKE_HOME"
  PATH="$saved"
  [ "$status" -eq 0 ]
  [ "$output" = "$FAKE_HOME/.local/bin/claude" ]
}

@test "resolve_claude_bin: fails (non-zero, empty) when nothing resolves (C4)" {
  local saved="$PATH"
  PATH="/usr/bin:/bin"
  run resolve_claude_bin claude "$EMPTY_HOME"
  PATH="$saved"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "_export_local_context: CLAUDE_BIN absolute when claude only in ~/.local/bin (C1)" {
  local saved="$PATH" savedh="$HOME"
  PATH="/usr/bin:/bin"; HOME="$FAKE_HOME"; export DEPLOYMENT_CLAUDE_CLI="claude"
  _export_local_context
  local rc=$?
  PATH="$saved"; HOME="$savedh"; unset DEPLOYMENT_CLAUDE_CLI
  [ "$rc" -eq 0 ]
  [ "$CLAUDE_BIN" = "$FAKE_HOME/.local/bin/claude" ]
}

@test "_export_local_context: fails loud with an actionable message when unresolvable (C4)" {
  local saved="$PATH" savedh="$HOME"
  PATH="/usr/bin:/bin"; HOME="$EMPTY_HOME"; export DEPLOYMENT_CLAUDE_CLI="claude"
  run _export_local_context
  PATH="$saved"; HOME="$savedh"; unset DEPLOYMENT_CLAUDE_CLI
  # fail-loud: non-zero return + an actionable 203/EXEC message (never a silent
  # bare-literal unit). resolve_claude_bin returning empty on failure (test 4)
  # guarantees CLAUDE_BIN is never the bare `claude`.
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '203/EXEC'
}

@test "detect_claude_cli: returns an absolute path when claude is installed (C1)" {
  local saved="$PATH" savedh="$HOME"
  PATH="/usr/bin:/bin"; HOME="$FAKE_HOME"
  run detect_claude_cli
  PATH="$saved"; HOME="$savedh"
  [ "$status" -eq 0 ]
  [ "$output" = "$FAKE_HOME/.local/bin/claude" ]
}

@test "_persist_claude_cli: writes the resolved absolute path back to agent.yml (C3/Principle I)" {
  cat > "$TMP_TEST_DIR/agent.yml" <<'YML'
deployment:
  mode: local
  claude_cli: "claude"
YML
  _persist_claude_cli "$TMP_TEST_DIR/agent.yml" "/home/op/.local/bin/claude"
  run yq -r '.deployment.claude_cli' "$TMP_TEST_DIR/agent.yml"
  [ "$output" = "/home/op/.local/bin/claude" ]
}

@test "_persist_claude_cli: no-op when the value is already correct" {
  cat > "$TMP_TEST_DIR/agent.yml" <<'YML'
deployment:
  mode: local
  claude_cli: "/home/op/.local/bin/claude"
YML
  local before; before=$(cat "$TMP_TEST_DIR/agent.yml")
  _persist_claude_cli "$TMP_TEST_DIR/agent.yml" "/home/op/.local/bin/claude"
  local after; after=$(cat "$TMP_TEST_DIR/agent.yml")
  [ "$before" = "$after" ]
}
