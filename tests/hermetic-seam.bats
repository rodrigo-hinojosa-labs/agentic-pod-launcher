#!/usr/bin/env bats
# 025-hermetic-ci-suite: guard tests for the shared hermeticity seam in
# tests/helper.bash. install_claude_stub / install_bun_stub let tests force a
# deterministic fake binary instead of depending on whatever the host happens
# to have installed (or not) — the root cause of the 16-test CI drift measured
# in specs/025-hermetic-ci-suite/research.md.

load helper

setup() {
  setup_tmp_dir
  # setup.sh guards main() behind BASH_SOURCE, so sourcing just defines functions.
  source "$REPO_ROOT/setup.sh" >/dev/null 2>&1 || true
}
teardown() { teardown_tmp_dir; }

@test "install_claude_stub prints an absolute, executable path" {
  run install_claude_stub
  [ "$status" -eq 0 ]
  local p="$output"
  [ "${p#/}" != "$p" ]          # absolute (does not equal itself with leading / stripped)
  [ -x "$p" ]
}

@test "install_claude_stub is resolvable by setup.sh's own resolve_claude_bin" {
  local p
  p=$(install_claude_stub)
  run resolve_claude_bin "$p" "$TMP_TEST_DIR"
  [ "$status" -eq 0 ]
  [ "$output" = "$p" ]
}

@test "install_claude_stub does not leak a fixed dev-box path" {
  local p
  p=$(install_claude_stub)
  [[ "$p" == "$TMP_TEST_DIR"* || "$p" == "$BATS_TEST_TMPDIR"* ]]
}

@test "install_bun_stub prints a directory containing an executable bun" {
  run install_bun_stub
  [ "$status" -eq 0 ]
  local d="$output"
  [ -x "$d/bun" ]
}

@test "install_bun_stub satisfies a 'command -v bun' guard once prepended to PATH" {
  local d
  d=$(install_bun_stub)
  PATH="$d:$PATH" command -v bun >/dev/null
}

@test "sourcing helper.bash has no side effects (Principle III)" {
  run bash -c "source '$REPO_ROOT/tests/helper.bash'; echo ok"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}
