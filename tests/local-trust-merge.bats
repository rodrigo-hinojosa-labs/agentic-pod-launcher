#!/usr/bin/env bats
# 011-local-standalone-mode (US2): idempotent .claude.json trust-merge +
# non-destructive onboarding pre-seed (scripts/lib/local_trust.sh). These are
# the units the rendered agent-login.sh relies on (gotcha #4: exact-equality,
# not substring; the login rewrites .claude.json and resets trust, so the merge
# must run after login and preserve everything else).

load helper

setup() {
  setup_tmp_dir
  load_lib local_trust
  command -v jq >/dev/null || skip "jq not installed"
}

teardown() { teardown_tmp_dir; }

@test "trust-merge: sets hasTrustDialogAccepted on the workspace, preserves other keys" {
  local f="$TMP_TEST_DIR/.claude.json"
  cat > "$f" << 'JSON'
{
  "someGlobal": "keepme",
  "projects": {
    "/other/proj": { "hasTrustDialogAccepted": true, "extra": 1 }
  }
}
JSON
  run local_merge_trust "$f" "/home/op/agents/locbot"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.projects["/home/op/agents/locbot"].hasTrustDialogAccepted' "$f")" = "true" ]
  # other keys + other projects untouched
  [ "$(jq -r '.someGlobal' "$f")" = "keepme" ]
  [ "$(jq -r '.projects["/other/proj"].extra' "$f")" = "1" ]
  [ "$(jq -r '.projects["/other/proj"].hasTrustDialogAccepted' "$f")" = "true" ]
}

@test "trust-merge: re-running is a byte-exact no-op (gotcha #4)" {
  local f="$TMP_TEST_DIR/.claude.json"
  printf '{"projects":{}}\n' > "$f"
  local_merge_trust "$f" "/home/op/agents/locbot"
  cp "$f" "$f.after1"
  local_merge_trust "$f" "/home/op/agents/locbot"
  # Second run must not change the file at all.
  cmp "$f" "$f.after1"
}

@test "trust-merge: creates the file when absent" {
  local f="$TMP_TEST_DIR/.claude.json"
  [ ! -f "$f" ]
  run local_merge_trust "$f" "/home/op/agents/locbot"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.projects["/home/op/agents/locbot"].hasTrustDialogAccepted' "$f")" = "true" ]
}

@test "onboarding pre-seed: sets hasCompletedOnboarding=true when absent" {
  local f="$TMP_TEST_DIR/.claude.json"
  printf '{"someKey":"v"}\n' > "$f"
  run local_seed_onboarding "$f"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.hasCompletedOnboarding' "$f")" = "true" ]
  [ "$(jq -r '.someKey' "$f")" = "v" ]
}

@test "onboarding pre-seed: does NOT overwrite an existing onboarding value" {
  local f="$TMP_TEST_DIR/.claude.json"
  printf '{"hasCompletedOnboarding":false}\n' > "$f"
  run local_seed_onboarding "$f"
  [ "$status" -eq 0 ]
  # left as the operator had it (false), not clobbered to true
  [ "$(jq -r '.hasCompletedOnboarding' "$f")" = "false" ]
}

@test "remote-control pre-seed: sets remoteDialogSeen=true when absent, preserves keys" {
  local f="$TMP_TEST_DIR/.claude.json"
  printf '{"someKey":"v"}\n' > "$f"
  run local_seed_remote_control "$f"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.remoteDialogSeen' "$f")" = "true" ]
  [ "$(jq -r '.someKey' "$f")" = "v" ]
}

@test "remote-control pre-seed: does NOT overwrite an existing value" {
  local f="$TMP_TEST_DIR/.claude.json"
  printf '{"remoteDialogSeen":false}\n' > "$f"
  run local_seed_remote_control "$f"
  [ "$status" -eq 0 ]
  # left as the operator had it (false), not clobbered
  [ "$(jq -r '.remoteDialogSeen' "$f")" = "false" ]
}

@test "remote-control pre-seed: creates the file when absent" {
  local f="$TMP_TEST_DIR/.claude.json"
  [ ! -f "$f" ]
  run local_seed_remote_control "$f"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.remoteDialogSeen' "$f")" = "true" ]
}
