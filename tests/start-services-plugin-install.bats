#!/usr/bin/env bats
# Story C (003-bootstrap-hardening): plugin install distinguishes "not
# authenticated" (expected skip) from a real "install failed", retries the
# latter a bounded number of times, persists residual failures to
# .state/plugin-install-failures.jsonl with a SANITIZED error (no secrets,
# Principle V / FR-C4), and clears the entry on a later success.
#
# Pure shell, host-only (Principle III): we source docker/scripts/lib/
# plugin-install.sh directly and stub `claude`. No Docker.

load helper

setup() {
  setup_tmp_dir
  export PLUGIN_FAILURES_FILE="$TMP_TEST_DIR/failures.jsonl"
  export PLUGIN_INSTALL_BACKOFF_UNIT=0   # no real sleeping in tests
  export CLAUDE_CONFIG_DIR_VAL="$TMP_TEST_DIR/.claude"
  mkdir -p "$TMP_TEST_DIR/bin"
  cat > "$TMP_TEST_DIR/bin/claude" <<STUB
#!/bin/bash
# Stub: \`claude plugin install <spec>\`. Behavior driven by CLAUDE_STUB_MODE.
n=\$(cat "$TMP_TEST_DIR/attempts" 2>/dev/null || echo 0); n=\$((n+1)); echo "\$n" > "$TMP_TEST_DIR/attempts"
case "\${CLAUDE_STUB_MODE:-ok}" in
  ok)   exit 0 ;;
  auth) echo "Error: Not authenticated. Please run /login" >&2; exit 1 ;;
  no-marketplace) echo 'Error: Plugin "telegram" not found in marketplace "claude-plugins-official". Your local copy may be out of date' >&2; exit 1 ;;
  fail) echo "Error: network blip" >&2; exit 1 ;;
  fail-then-ok) if [ "\$n" -lt "\${CLAUDE_STUB_SUCCEED_AT:-2}" ]; then echo "transient" >&2; exit 1; else exit 0; fi ;;
  secret) echo "fatal: install failed with token ghp_ABCDEF1234567890SECRET in URL" >&2; exit 1 ;;
esac
STUB
  chmod +x "$TMP_TEST_DIR/bin/claude"
  export PATH="$TMP_TEST_DIR/bin:$PATH"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/docker/scripts/lib/plugin-install.sh"
}

teardown() { teardown_tmp_dir; }

@test "retry_plugin_install_bounded returns 0 on success (single attempt)" {
  export CLAUDE_STUB_MODE=ok
  run retry_plugin_install_bounded "telegram@x" 3
  [ "$status" -eq 0 ]
  [ "$(cat "$TMP_TEST_DIR/attempts")" -eq 1 ]
}

@test "retry_plugin_install_bounded returns 2 (skipped) and does NOT retry when not authenticated" {
  export CLAUDE_STUB_MODE=auth
  run retry_plugin_install_bounded "telegram@x" 3
  [ "$status" -eq 2 ]
  [ "$(cat "$TMP_TEST_DIR/attempts")" -eq 1 ]   # no retry on auth-skip
}

# 006-headless-bootstrap US4: a "marketplace not found" error is a transient
# skip (the marketplace gets registered by ensure_official_marketplace), NOT a
# failure to retry 3x, and NOT to be conflated with "not authenticated".
@test "retry_plugin_install_bounded returns 2 and does NOT retry when the marketplace is not registered" {
  export CLAUDE_STUB_MODE=no-marketplace
  run retry_plugin_install_bounded "telegram@x" 3
  [ "$status" -eq 2 ]
  [ "$(cat "$TMP_TEST_DIR/attempts")" -eq 1 ]   # no retry — deterministic, not transient network
  [[ "$output" != *"not authenticated"* ]]
}

@test "retry_plugin_install_bounded retries up to max then returns 1 (failed)" {
  export CLAUDE_STUB_MODE=fail
  run retry_plugin_install_bounded "telegram@x" 3
  [ "$status" -eq 1 ]
  [ "$(cat "$TMP_TEST_DIR/attempts")" -eq 3 ]
  [ -n "$output" ]   # prints a (sanitized) reason for the caller to record
}

@test "retry_plugin_install_bounded succeeds on a later attempt (fail-then-ok)" {
  export CLAUDE_STUB_MODE=fail-then-ok CLAUDE_STUB_SUCCEED_AT=2
  run retry_plugin_install_bounded "telegram@x" 3
  [ "$status" -eq 0 ]
  [ "$(cat "$TMP_TEST_DIR/attempts")" -eq 2 ]
}

@test "retry_plugin_install_bounded redacts a token from the failure reason" {
  export CLAUDE_STUB_MODE=secret
  run retry_plugin_install_bounded "telegram@x" 1
  [ "$status" -eq 1 ]
  [[ "$output" != *"ghp_ABCDEF1234567890SECRET"* ]]
  [[ "$output" == *"REDACTED"* ]]
}

@test "_plugin_sanitize_error truncates to the first line and redacts tokens" {
  run _plugin_sanitize_error "boom ghp_ABCDEF1234567890SECRET here
second line should be dropped"
  [[ "$output" != *"ghp_ABCDEF1234567890SECRET"* ]]
  [[ "$output" != *"second line"* ]]
}

@test "_plugin_record_failure writes one jsonl line; _plugin_clear_failure removes it" {
  _plugin_record_failure "telegram@x" "boom"
  [ -f "$PLUGIN_FAILURES_FILE" ]
  [ "$(grep -c '"spec":"telegram@x"' "$PLUGIN_FAILURES_FILE")" -eq 1 ]
  # Re-recording the same spec must not duplicate (clear-then-append).
  _plugin_record_failure "telegram@x" "boom again"
  [ "$(grep -c '"spec":"telegram@x"' "$PLUGIN_FAILURES_FILE")" -eq 1 ]
  _plugin_clear_failure "telegram@x"
  [ "$(grep -c '"spec":"telegram@x"' "$PLUGIN_FAILURES_FILE" || true)" -eq 0 ]
}

@test "_plugin_list_failures yields the recorded specs" {
  _plugin_record_failure "a@m" "e1"
  _plugin_record_failure "b@m" "e2"
  run _plugin_list_failures
  [ "$status" -eq 0 ]
  [[ "$output" == *"a@m"* ]]
  [[ "$output" == *"b@m"* ]]
}
