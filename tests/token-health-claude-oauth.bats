#!/usr/bin/env bats
# Tests for probe_claude_oauth (Phase A2.1 of OAuth resilience).
# File-local probe — no curl mocks needed; only fixtures of the cred file.

load 'helper'

setup() {
  LIB="$BATS_TEST_DIRNAME/../docker/scripts/lib/token_health.sh"
  # shellcheck source=/dev/null
  source "$LIB"
  CRED_DIR="$BATS_TEST_TMPDIR/.claude"
  CRED="$CRED_DIR/.credentials.json"
  mkdir -p "$CRED_DIR"
}

# Helper: write a cred file with an explicit expiresAt (ms epoch).
_write_cred() {
  local expires_ms="$1"
  jq -n --argjson exp "$expires_ms" \
    '{claudeAiOauth:{accessToken:"sk-ant-oat01-fake",refreshToken:"sk-ant-ort01-fake",expiresAt:$exp,scopes:["user:profile"]}}' \
    > "$CRED"
}

@test "probe_claude_oauth: missing cred file → skipped" {
  rm -f "$CRED"
  run probe_claude_oauth "$CRED"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^skipped 000 0 missing cred file'
}

@test "probe_claude_oauth: malformed JSON → skipped" {
  echo "not json at all" > "$CRED"
  run probe_claude_oauth "$CRED"
  echo "$output" | grep -q '^skipped 000 0 malformed expiresAt'
}

@test "probe_claude_oauth: missing expiresAt field → skipped" {
  jq -n '{claudeAiOauth:{accessToken:"x",refreshToken:"y"}}' > "$CRED"
  run probe_claude_oauth "$CRED"
  echo "$output" | grep -q '^skipped 000 0 malformed expiresAt'
}

@test "probe_claude_oauth: non-numeric expiresAt → skipped" {
  jq -n '{claudeAiOauth:{expiresAt:"yesterday"}}' > "$CRED"
  run probe_claude_oauth "$CRED"
  echo "$output" | grep -q '^skipped 000 0 malformed expiresAt'
}

@test "probe_claude_oauth: token expired 1h ago → auth_fail with seconds delta" {
  local now_ms=$(( $(date -u +%s) * 1000 ))
  local expired_ms=$(( now_ms - 3600 * 1000 ))
  _write_cred "$expired_ms"
  run probe_claude_oauth "$CRED"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^auth_fail 000 0 expired [0-9]+s ago'
  # Sanity: the delta in "expired Ns ago" should be ~3600 (allow drift).
  # Output shape: "auth_fail 000 0 expired 3600s ago" — extract the
  # number right before "s ago".
  local delta
  delta=$(echo "$output" | grep -oE 'expired [0-9]+s' | grep -oE '[0-9]+')
  [ "$delta" -ge 3500 ]
  [ "$delta" -le 3700 ]
}

@test "probe_claude_oauth: token expires in 10 min → auth_fail (early warn)" {
  local now_ms=$(( $(date -u +%s) * 1000 ))
  local soon_ms=$(( now_ms + 600 * 1000 ))   # 10 min ahead
  _write_cred "$soon_ms"
  run probe_claude_oauth "$CRED"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^auth_fail 000 0 expires in [0-9]+m'
  local mins
  mins=$(echo "$output" | grep -oE '[0-9]+' | tail -1)
  [ "$mins" -ge 9 ]
  [ "$mins" -le 10 ]
}

@test "probe_claude_oauth: token expires in 31 min → ok (above margin)" {
  local now_ms=$(( $(date -u +%s) * 1000 ))
  local soon_ms=$(( now_ms + 1860 * 1000 ))   # 31 min ahead
  _write_cred "$soon_ms"
  run probe_claude_oauth "$CRED"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^ok 000 0'
}

@test "probe_claude_oauth: token expires in 24h → ok" {
  local now_ms=$(( $(date -u +%s) * 1000 ))
  local later_ms=$(( now_ms + 86400 * 1000 ))
  _write_cred "$later_ms"
  run probe_claude_oauth "$CRED"
  echo "$output" | grep -q '^ok 000 0'
}

@test "probe_claude_oauth: defaults to ~/.claude/.credentials.json when no arg" {
  # We don't want to clobber the real cred file; verify the default path
  # at least doesn't crash and emits one of the expected status keywords.
  HOME="$BATS_TEST_TMPDIR/fakehome" run probe_claude_oauth
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^(skipped|ok|auth_fail) '
}

# ── token_health_format_warning hint for claude_oauth ─────────────

@test "format_warning: claude_oauth points at agentctl attach + /login" {
  run token_health_format_warning "claude_oauth" "claude_oauth" "expired 600s ago"
  echo "$output" | grep -q "claude_oauth"
  echo "$output" | grep -q "expired 600s ago"
  echo "$output" | grep -q "agentctl attach"
  echo "$output" | grep -q "/login"
  # Should NOT mention setup.sh --regenerate (that's for env-based tokens)
  ! echo "$output" | grep -q "setup.sh --regenerate"
}
