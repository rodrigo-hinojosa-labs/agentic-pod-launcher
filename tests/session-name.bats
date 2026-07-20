#!/usr/bin/env bats
# 022-local-session-lifecycle (US3): `_resolve_session_name` — the default for
# the client-visible agent name, and the safety belt that keeps a render from
# ever emitting `--name ""`.
#
# Contract: specs/022-local-session-lifecycle/contracts/session-name-resolution.md
# (§1 the rule, §6 scenarios N2-N5/N7b). Host-runnable: setup.sh guards main()
# behind BASH_SOURCE, so sourcing it just defines functions — same seam
# tests/claude-cli-resolution.bats:18 uses.

load 'helper'

setup() {
  setup_tmp_dir
  SCRIPT_DIR="$BATS_TEST_DIRNAME/.."
  source "$SCRIPT_DIR/setup.sh" >/dev/null 2>&1 || true
  load_lib yaml
  yaml_require_yq >/dev/null
}

teardown() { teardown_tmp_dir; }

# ─── The resolution rule (N2-N5 + boundaries) ──────────────────────────────

@test "022/N2: agent already prefixed by the host resolves to the agent name alone" {
  run _resolve_session_name "mclaren-admin" "mclaren"
  [ "$status" -eq 0 ]
  [ "$output" = "mclaren-admin" ]
}

@test "022/N3: an unrelated host is prepended" {
  run _resolve_session_name "locbot" "rpi5"
  [ "$status" -eq 0 ]
  [ "$output" = "rpi5-locbot" ]
}

@test "022/N4: a hyphen-bounded prefix is not repeated" {
  run _resolve_session_name "rpi5-bot" "rpi5"
  [ "$status" -eq 0 ]
  [ "$output" = "rpi5-bot" ]
}

@test "022/N5: only the first dot-label of the host is used, normalized" {
  run _resolve_session_name "locbot" "My Pi.local"
  [ "$status" -eq 0 ]
  [ "$output" = "my-pi-locbot" ]
}

# The boundary the contract calls out explicitly: a BARE prefix test would
# collapse rpi5+rpi5x to "rpi5x", losing the host segment. The frontier hyphen
# is what makes the prefix branch safe.
@test "022: a bare (non hyphen-bounded) prefix is NOT treated as a match" {
  run _resolve_session_name "rpi5x" "rpi5"
  [ "$status" -eq 0 ]
  [ "$output" = "rpi5-rpi5x" ]
}

@test "022/C7: agent name equal to the host segment does not stutter" {
  run _resolve_session_name "mclaren" "mclaren"
  [ "$status" -eq 0 ]
  [ "$output" = "mclaren" ]
}

# C8 + the yq trap: an ABSENT .deployment.host makes `yq -r '.deployment.host'`
# print the literal string "null". Reading it without `// ""` would resolve
# "null-locbot" — a plausible-looking identity nobody asked for.
@test "022/C8: an empty host segment yields the agent name alone" {
  run _resolve_session_name "locbot" ""
  [ "$status" -eq 0 ]
  [ "$output" = "locbot" ]
}

@test "022/C8: the literal string 'null' from yq is treated as an absent host" {
  run _resolve_session_name "locbot" "null"
  [ "$status" -eq 0 ]
  [ "$output" = "locbot" ]
}

@test "022: a host that normalizes to nothing yields the agent name alone" {
  run _resolve_session_name "locbot" "---"
  [ "$status" -eq 0 ]
  [ "$output" = "locbot" ]
}

@test "022: an uppercase host is lowercased" {
  run _resolve_session_name "locbot" "RPi5"
  [ "$status" -eq 0 ]
  [ "$output" = "rpi5-locbot" ]
}

# ─── N7b: the safety belt inside _export_local_context ─────────────────────

@test "022/N7b: _export_local_context fills an empty DEPLOYMENT_SESSION_NAME with the default" {
  mkdir -p "$TMP_TEST_DIR/bin"
  printf '#!/bin/sh\necho claude\n' > "$TMP_TEST_DIR/bin/claude"
  chmod +x "$TMP_TEST_DIR/bin/claude"
  export DEPLOYMENT_CLAUDE_CLI="$TMP_TEST_DIR/bin/claude"
  export AGENT_NAME="locbot"
  export DEPLOYMENT_HOST="rpi5"
  export DEPLOYMENT_SESSION_NAME=""

  _export_local_context
  [ "$DEPLOYMENT_SESSION_NAME" = "rpi5-locbot" ]
}

@test "022/N7b: a configured DEPLOYMENT_SESSION_NAME is never overwritten by the belt" {
  mkdir -p "$TMP_TEST_DIR/bin"
  printf '#!/bin/sh\necho claude\n' > "$TMP_TEST_DIR/bin/claude"
  chmod +x "$TMP_TEST_DIR/bin/claude"
  export DEPLOYMENT_CLAUDE_CLI="$TMP_TEST_DIR/bin/claude"
  export AGENT_NAME="locbot"
  export DEPLOYMENT_HOST="rpi5"
  export DEPLOYMENT_SESSION_NAME="bitacora"

  _export_local_context
  [ "$DEPLOYMENT_SESSION_NAME" = "bitacora" ]
}
