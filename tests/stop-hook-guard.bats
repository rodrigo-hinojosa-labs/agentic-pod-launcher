#!/usr/bin/env bats
#
# 028 US1 — the Stop-hook reply guard (scripts/hooks/stop-redeliver.sh) and its
# settings.json install helper (scripts/hooks/install-stop-hook.sh). Renders both
# templates and exercises the rendered scripts against fixtures — fully host-runnable,
# no Docker, no live agent. Oracle: contracts/stop-hook-io.md + contracts/settings-merge.md.

load helper

setup() {
  setup_tmp_dir
  load_lib render
  # Render the hook at max_attempts=1 (default), a max_attempts=2 variant, and a
  # disabled variant. render_to_file substitutes the FEATURES_REPLY_GUARD_* env
  # vars produced by render_load_context (then overridden per variant).
  render_load_context "$REPO_ROOT/tests/fixtures/sample-agent-with-vault.yml"
  render_to_file "$REPO_ROOT/modules/stop-hook.sh.tpl"          "$TMP_TEST_DIR/hook.sh"
  export FEATURES_REPLY_GUARD_MAX_ATTEMPTS=2
  render_to_file "$REPO_ROOT/modules/stop-hook.sh.tpl"          "$TMP_TEST_DIR/hook-max2.sh"
  export FEATURES_REPLY_GUARD_ENABLED=false FEATURES_REPLY_GUARD_MAX_ATTEMPTS=1
  render_to_file "$REPO_ROOT/modules/stop-hook.sh.tpl"          "$TMP_TEST_DIR/hook-disabled.sh"
  render_to_file "$REPO_ROOT/modules/stop-hook-install.sh.tpl"  "$TMP_TEST_DIR/install.sh"
  chmod +x "$TMP_TEST_DIR"/hook*.sh "$TMP_TEST_DIR/install.sh"

  MARKER="$TMP_TEST_DIR/pending-reply.json"
  STATE="$TMP_TEST_DIR/state"
  STDERR_LOG="$TMP_TEST_DIR/stderr.log"
  export REPLY_GUARD_MARKER="$MARKER" REPLY_GUARD_STATE_DIR="$STATE" REPLY_GUARD_STDERR_LOG="$STDERR_LOG"

  # A channel message awaiting a reply.
  _mark_present() { printf '{"chat_id":"12345","update_id":7,"ts":1000}' > "$MARKER"; }
  _mark_absent()  { rm -f "$MARKER"; }
  # A payload whose answer carries a marker string we assert never leaks into output.
  PAYLOAD_ANSWER='{"stop_hook_active":false,"last_assistant_message":"SECRET_ANSWER_MARKER the reply text","prompt_id":"p1"}'
  PAYLOAD_ACTIVE='{"stop_hook_active":true,"last_assistant_message":"SECRET_ANSWER_MARKER the reply text","prompt_id":"p1"}'
  PAYLOAD_EMPTY='{"stop_hook_active":false,"last_assistant_message":"","prompt_id":"p1"}'
}

teardown() { teardown_tmp_dir; }

# ── Decision table (contracts/stop-hook-io.md) ──────────────────────────────────

@test "028 US1 case1: channel turn WITH reply tool called (marker absent) → no re-injection" {
  _mark_absent
  run bash "$TMP_TEST_DIR/hook.sh" <<<"$PAYLOAD_ANSWER"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "028 US1 case2: channel turn WITHOUT reply (marker present, not active) → exactly one block + stderr line" {
  _mark_present
  run bash "$TMP_TEST_DIR/hook.sh" <<<"$PAYLOAD_ANSWER"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"decision":"block"'
  echo "$output" | grep -q 'plugin:telegram:telegram'
  # privacy: the answer text is NEVER echoed into the re-injection
  ! echo "$output" | grep -q 'SECRET_ANSWER_MARKER'
  # exactly one greppable stderr line, naming the chat + attempt
  [ "$(grep -c 'reply-guard: re-injected' "$STDERR_LOG")" -eq 1 ]
  grep -q 'chat 12345' "$STDERR_LOG"
}

@test "028 US1 case3: console turn (no marker) even with a full payload → never fires" {
  _mark_absent
  run bash "$TMP_TEST_DIR/hook.sh" <<<"$PAYLOAD_ANSWER"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -f "$STDERR_LOG" ] || [ "$(grep -c 'reply-guard' "$STDERR_LOG")" -eq 0 ]
}

@test "028 US1 case4: loop guard — marker present but stop_hook_active=true → gives up, no block" {
  _mark_present
  run bash "$TMP_TEST_DIR/hook.sh" <<<"$PAYLOAD_ACTIVE"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ── Fail-silent (Principle IV) ──────────────────────────────────────────────────

@test "028 US1 fail-silent: malformed stdin with marker present → exit 0, no output" {
  _mark_present
  run bash "$TMP_TEST_DIR/hook.sh" <<<'this is not json at all'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "028 US1 fail-silent: disabled guard (enabled=false) → exit 0, no output even with marker" {
  _mark_present
  run bash "$TMP_TEST_DIR/hook-disabled.sh" <<<"$PAYLOAD_ANSWER"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "028 US1: empty answer with marker present → no spurious reply" {
  _mark_present
  run bash "$TMP_TEST_DIR/hook.sh" <<<"$PAYLOAD_EMPTY"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ── max_attempts > 1 (counter path) ─────────────────────────────────────────────

@test "028 US1: max_attempts=2 fires twice then gives up (per-prompt counter)" {
  _mark_present
  run bash "$TMP_TEST_DIR/hook-max2.sh" <<<"$PAYLOAD_ACTIVE"   # attempt 1 (active ignored when max>1)
  echo "$output" | grep -q '"decision":"block"'
  run bash "$TMP_TEST_DIR/hook-max2.sh" <<<"$PAYLOAD_ACTIVE"   # attempt 2
  echo "$output" | grep -q '"decision":"block"'
  run bash "$TMP_TEST_DIR/hook-max2.sh" <<<"$PAYLOAD_ACTIVE"   # over cap → give up
  [ -z "$output" ]
}

# ── settings.json install helper (contracts/settings-merge.md) ───────────────────

@test "028 US1 settings-merge: additive + non-clobbering (permissions + foreign hook survive)" {
  local s="$TMP_TEST_DIR/settings.json"
  cat > "$s" <<'JSON'
{"permissions":{"defaultMode":"auto"},"skipDangerousModePermissionPrompt":true,
 "hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"foreign.sh"}]}]}}
JSON
  run bash "$TMP_TEST_DIR/install.sh" "$s" "/workspace/scripts/hooks/stop-redeliver.sh"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.permissions.defaultMode' "$s")" = "auto" ]
  [ "$(jq -r '.skipDangerousModePermissionPrompt' "$s")" = "true" ]
  [ "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$s")" = "foreign.sh" ]
  [ "$(jq '.hooks.Stop | length' "$s")" -eq 1 ]
  [ "$(jq -r '.hooks.Stop[0].hooks[0].command' "$s")" = "/workspace/scripts/hooks/stop-redeliver.sh" ]
}

@test "028 US1 settings-merge: idempotent (second run does not duplicate the Stop entry)" {
  local s="$TMP_TEST_DIR/settings.json"
  printf '{"permissions":{"defaultMode":"auto"}}\n' > "$s"
  bash "$TMP_TEST_DIR/install.sh" "$s" "/workspace/scripts/hooks/stop-redeliver.sh"
  bash "$TMP_TEST_DIR/install.sh" "$s" "/workspace/scripts/hooks/stop-redeliver.sh"
  [ "$(jq '.hooks.Stop | length' "$s")" -eq 1 ]
  [ "$(jq -r '.permissions.defaultMode' "$s")" = "auto" ]
}

@test "028 US1 settings-merge: absent settings.json is created with just the Stop hook" {
  local s="$TMP_TEST_DIR/new-settings.json"
  rm -f "$s"
  run bash "$TMP_TEST_DIR/install.sh" "$s" "/workspace/scripts/hooks/stop-redeliver.sh"
  [ "$status" -eq 0 ]
  [ -f "$s" ]
  [ "$(jq '.hooks.Stop | length' "$s")" -eq 1 ]
}
