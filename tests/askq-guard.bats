#!/usr/bin/env bats
#
# 031 US1 — the PreToolUse AskUserQuestion guard (scripts/hooks/askq-guard.sh) and
# its settings.json install helper (scripts/hooks/install-askq-guard-hook.sh).
# Renders both templates and exercises the rendered scripts against fixtures —
# fully host-runnable, no Docker, no live agent.
# Oracle: contracts/pretooluse-guard-io.md (decision table C1–C6) +
# contracts/hook-install-and-config.md (settings merge).

load helper

setup() {
  setup_tmp_dir
  load_lib render
  # Render the hook at max_attempts=1 (default), a max_attempts=2 variant, and a
  # disabled variant. render_to_file substitutes the FEATURES_ASKUSERQUESTION_GUARD_*
  # env vars produced by render_load_context (then overridden per variant).
  render_load_context "$REPO_ROOT/tests/fixtures/sample-agent-with-vault.yml"
  export FEATURES_ASKUSERQUESTION_GUARD_ENABLED=true FEATURES_ASKUSERQUESTION_GUARD_MAX_ATTEMPTS=1
  render_to_file "$REPO_ROOT/modules/askq-guard.sh.tpl"         "$TMP_TEST_DIR/hook.sh"
  export FEATURES_ASKUSERQUESTION_GUARD_MAX_ATTEMPTS=2
  render_to_file "$REPO_ROOT/modules/askq-guard.sh.tpl"         "$TMP_TEST_DIR/hook-max2.sh"
  export FEATURES_ASKUSERQUESTION_GUARD_ENABLED=false FEATURES_ASKUSERQUESTION_GUARD_MAX_ATTEMPTS=1
  render_to_file "$REPO_ROOT/modules/askq-guard.sh.tpl"         "$TMP_TEST_DIR/hook-disabled.sh"
  render_to_file "$REPO_ROOT/modules/askq-guard-install.sh.tpl" "$TMP_TEST_DIR/install.sh"
  chmod +x "$TMP_TEST_DIR"/hook*.sh "$TMP_TEST_DIR/install.sh"

  MARKER="$TMP_TEST_DIR/pending-reply.json"
  STATE="$TMP_TEST_DIR/state"
  STDERR_LOG="$TMP_TEST_DIR/stderr.log"
  export REPLY_GUARD_MARKER="$MARKER" REPLY_GUARD_STATE_DIR="$STATE" REPLY_GUARD_STDERR_LOG="$STDERR_LOG"

  # A channel message awaiting a reply (the 028 origin marker).
  _mark_present() { printf '{"chat_id":"12345","update_id":7,"ts":1000}' > "$MARKER"; }
  _mark_absent()  { rm -f "$MARKER"; }

  PAYLOAD_AUQ='{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","prompt_id":"p1","tool_input":{"questions":["SECRET_QUESTION_MARKER pick one"]}}'
  PAYLOAD_OTHER='{"hook_event_name":"PreToolUse","tool_name":"Bash","prompt_id":"p1"}'
}

teardown() { teardown_tmp_dir; }

# ── Decision table (contracts/pretooluse-guard-io.md) ───────────────────────────

@test "031 US1 C1: disabled guard → exit 0, no output even with marker + AskUserQuestion" {
  _mark_present
  run bash "$TMP_TEST_DIR/hook-disabled.sh" <<<"$PAYLOAD_AUQ"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "031 US1 C2: empty/non-JSON stdin → exit 0, no output" {
  _mark_present
  run bash "$TMP_TEST_DIR/hook.sh" <<<'this is not json at all'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "031 US1 C3: tool_name != AskUserQuestion → exit 0, no output, never fires" {
  _mark_present
  run bash "$TMP_TEST_DIR/hook.sh" <<<"$PAYLOAD_OTHER"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -f "$STDERR_LOG" ] || [ "$(grep -c 'askq-guard' "$STDERR_LOG")" -eq 0 ]
}

@test "031 US1 C4: marker absent (console/local/replied) → FAIL OPEN, no output" {
  _mark_absent
  run bash "$TMP_TEST_DIR/hook.sh" <<<"$PAYLOAD_AUQ"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -f "$STDERR_LOG" ] || [ "$(grep -c 'askq-guard' "$STDERR_LOG")" -eq 0 ]
}

@test "031 US1 C5: marker present + under cap → deny+redirect JSON + one stderr line + counter increment" {
  _mark_present
  run bash "$TMP_TEST_DIR/hook.sh" <<<"$PAYLOAD_AUQ"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"permissionDecision":"deny"'
  echo "$output" | grep -q 'plugin:telegram:telegram'
  # never echoes the question content back
  ! echo "$output" | grep -q 'SECRET_QUESTION_MARKER'
  [ "$(grep -c 'askq-guard: redirected' "$STDERR_LOG")" -eq 1 ]
  grep -q 'chat 12345' "$STDERR_LOG"
  [ "$(cat "$STATE/askq-guard-attempts/p1")" = "1" ]
  [ ! -f "$STATE/askq-guard-giveup.json" ]
}

@test "031 US1 C6: marker present + at cap → deny+TERMINAL give-up JSON (never allow), give-up marker written once" {
  _mark_present
  run bash "$TMP_TEST_DIR/hook.sh" <<<"$PAYLOAD_AUQ"   # attempt 1 → redirect
  echo "$output" | grep -q '"permissionDecision":"deny"'
  run bash "$TMP_TEST_DIR/hook.sh" <<<"$PAYLOAD_AUQ"   # attempt 2 → over cap (max=1) → terminal give-up
  [ "$status" -eq 0 ]
  # C6 MUST still be a deny — the prompt must never open on a confirmed channel turn.
  echo "$output" | grep -q '"permissionDecision":"deny"'
  echo "$output" | grep -q 'Do not call this tool again'
  [ "$(grep -c 'askq-guard: gave up' "$STDERR_LOG")" -eq 1 ]
  [ -f "$STATE/askq-guard-giveup.json" ]
  [ "$(jq -r '.chat_id' "$STATE/askq-guard-giveup.json")" = "12345" ]
  [ "$(jq -r '.prompt_id' "$STATE/askq-guard-giveup.json")" = "p1" ]
}

@test "031 US1 C6: give-up marker written exactly once across repeated over-cap calls" {
  _mark_present
  bash "$TMP_TEST_DIR/hook.sh" <<<"$PAYLOAD_AUQ" >/dev/null   # attempt 1
  bash "$TMP_TEST_DIR/hook.sh" <<<"$PAYLOAD_AUQ" >/dev/null   # over cap, writes marker
  local first_ts
  first_ts=$(jq -r '.ts' "$STATE/askq-guard-giveup.json")
  run bash "$TMP_TEST_DIR/hook.sh" <<<"$PAYLOAD_AUQ"          # still over cap, must not rewrite
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"permissionDecision":"deny"'
  [ "$(jq -r '.ts' "$STATE/askq-guard-giveup.json")" = "$first_ts" ]
}

# ── max_attempts > 1 (counter path) ─────────────────────────────────────────────

@test "031 US1: max_attempts=2 redirects twice then gives up (terminal deny, per-prompt counter)" {
  _mark_present
  run bash "$TMP_TEST_DIR/hook-max2.sh" <<<"$PAYLOAD_AUQ"   # attempt 1
  echo "$output" | grep -q '"permissionDecision":"deny"'
  echo "$output" | grep -q 'plugin:telegram:telegram'
  run bash "$TMP_TEST_DIR/hook-max2.sh" <<<"$PAYLOAD_AUQ"   # attempt 2
  echo "$output" | grep -q '"permissionDecision":"deny"'
  echo "$output" | grep -q 'plugin:telegram:telegram'
  run bash "$TMP_TEST_DIR/hook-max2.sh" <<<"$PAYLOAD_AUQ"   # over cap → terminal give-up, still a deny
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"permissionDecision":"deny"'
  echo "$output" | grep -q 'Do not call this tool again'
}

# ── Privacy / fail-silent (Principles IV/V) ─────────────────────────────────────

@test "031 US1: the guard never posts to the channel itself — only emits stdout deny + stderr trace" {
  _mark_present
  run bash "$TMP_TEST_DIR/hook.sh" <<<"$PAYLOAD_AUQ"
  ! echo "$output" | grep -qi 'sendMessage\|bot.api'
}

@test "031 US1: jq absent → exit 0, no output (fail-silent)" {
  _mark_present
  local fakepath
  fakepath="$TMP_TEST_DIR/no-jq-path"
  mkdir -p "$fakepath"
  for b in bash cat mkdir printf tr date; do
    real=$(command -v "$b")
    [ -n "$real" ] && ln -sf "$real" "$fakepath/$b"
  done
  run env PATH="$fakepath" bash "$TMP_TEST_DIR/hook.sh" <<<"$PAYLOAD_AUQ"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ── settings.json install helper (contracts/hook-install-and-config.md) ─────────

@test "031 US1 settings-merge: additive + non-clobbering (permissions + foreign hooks survive)" {
  local s="$TMP_TEST_DIR/settings.json"
  cat > "$s" <<'JSON'
{"permissions":{"defaultMode":"auto"},"skipDangerousModePermissionPrompt":true,
 "hooks":{"Stop":[{"hooks":[{"type":"command","command":"stop-redeliver.sh"}]}],
          "PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"foreign.sh"}]}]}}
JSON
  run bash "$TMP_TEST_DIR/install.sh" "$s" "/workspace/scripts/hooks/askq-guard.sh"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.permissions.defaultMode' "$s")" = "auto" ]
  [ "$(jq -r '.skipDangerousModePermissionPrompt' "$s")" = "true" ]
  [ "$(jq -r '.hooks.Stop[0].hooks[0].command' "$s")" = "stop-redeliver.sh" ]
  [ "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$s")" = "foreign.sh" ]
  [ "$(jq '.hooks.PreToolUse | length' "$s")" -eq 2 ]
  [ "$(jq -r '.hooks.PreToolUse[1].matcher' "$s")" = "AskUserQuestion" ]
  [ "$(jq -r '.hooks.PreToolUse[1].hooks[0].command' "$s")" = "/workspace/scripts/hooks/askq-guard.sh" ]
}

@test "031 US1 settings-merge: idempotent (second run does not duplicate the entry)" {
  local s="$TMP_TEST_DIR/settings.json"
  printf '{"permissions":{"defaultMode":"auto"}}\n' > "$s"
  bash "$TMP_TEST_DIR/install.sh" "$s" "/workspace/scripts/hooks/askq-guard.sh"
  bash "$TMP_TEST_DIR/install.sh" "$s" "/workspace/scripts/hooks/askq-guard.sh"
  [ "$(jq '.hooks.PreToolUse | length' "$s")" -eq 1 ]
  [ "$(jq -r '.permissions.defaultMode' "$s")" = "auto" ]
}

@test "031 US1 settings-merge: absent settings.json is created with just the PreToolUse entry" {
  local s="$TMP_TEST_DIR/new-settings.json"
  rm -f "$s"
  run bash "$TMP_TEST_DIR/install.sh" "$s" "/workspace/scripts/hooks/askq-guard.sh"
  [ "$status" -eq 0 ]
  [ -f "$s" ]
  [ "$(jq '.hooks.PreToolUse | length' "$s")" -eq 1 ]
  [ "$(jq -r '.hooks.PreToolUse[0].matcher' "$s")" = "AskUserQuestion" ]
}
