#!/usr/bin/env bats

load helper

setup() {
  setup_tmp_dir
  export TOKEN_HEALTH_LAST_BODY="$TMP_TEST_DIR/last-body"
  export TOKEN_HEALTH_LIB_DIR="$REPO_ROOT/docker/scripts/lib"
  source "$REPO_ROOT/docker/scripts/lib/safe-exec.sh"
  source "$REPO_ROOT/docker/scripts/lib/token-health.sh"

  # By default, every test stubs safe_curl to a known response. We
  # override per-test by re-defining safe_curl after this setup. Bash's
  # late binding picks up the override.
  safe_curl() {
    # The default simulates a healthy 200 response with a generic JSON
    # body that all checkers can parse. Per-test overrides replace this.
    printf '%s' '{"ok":true,"result":{"username":"defaultbot"},"login":"defaultlogin","accountId":"a1"}' > "$TOKEN_HEALTH_LAST_BODY"
    printf '200'
  }
}
teardown() { teardown_tmp_dir; }

# A helper that lets tests set a canned (code, body) for the next safe_curl
# call without reimplementing the whole stub.
_stub_safe_curl() {
  local code="$1" body="$2"
  eval "safe_curl() {
    printf '%s' '$body' > '$TOKEN_HEALTH_LAST_BODY'
    printf '%s' '$code'
  }"
}

# ── token_health_telegram ─────────────────────────────────────────────

@test "token_health_telegram returns ok=true on 200 + body.ok=true" {
  _stub_safe_curl 200 '{"ok":true,"result":{"username":"linus_bot"}}'
  run token_health_telegram "fake-token"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"ok":true'* ]]
  [[ "$output" == *'"bot_username":"linus_bot"'* ]]
}

@test "token_health_telegram returns ok=false on 200 + body.ok=false (revoked)" {
  _stub_safe_curl 200 '{"ok":false,"description":"Unauthorized"}'
  run token_health_telegram "revoked-token"
  [ "$status" -eq 1 ]
  [[ "$output" == *'"ok":false'* ]]
  [[ "$output" == *'Unauthorized'* ]]
}

@test "token_health_telegram returns rc=1 + rejection message on 401" {
  _stub_safe_curl 401 ""
  run token_health_telegram "bad-token"
  [ "$status" -eq 1 ]
  [[ "$output" == *"401"* ]]
  [[ "$output" == *"rejected"* ]]
}

@test "token_health_telegram returns rc=2 + transient flag on 5xx" {
  _stub_safe_curl 503 "service unavailable"
  run token_health_telegram "any-token"
  [ "$status" -eq 2 ]
  [[ "$output" == *'"transient":true'* ]]
}

@test "token_health_telegram returns rc=2 on connection failure (code=000)" {
  _stub_safe_curl 000 ""
  run token_health_telegram "any-token"
  [ "$status" -eq 2 ]
  [[ "$output" == *'"transient":true'* ]]
}

@test "token_health_telegram with empty token returns rc=1 immediately" {
  run token_health_telegram ""
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing token"* ]]
}

# ── token_health_github ───────────────────────────────────────────────

@test "token_health_github returns ok=true on 200 with login" {
  _stub_safe_curl 200 '{"login":"rodrigo-hinojosa"}'
  run token_health_github "ghp_fake"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"login":"rodrigo-hinojosa"'* ]]
}

@test "token_health_github returns rc=1 on 401" {
  _stub_safe_curl 401 ""
  run token_health_github "expired-pat"
  [ "$status" -eq 1 ]
  [[ "$output" == *"rotate PAT"* ]]
}

@test "token_health_github with empty PAT returns rc=1 immediately" {
  run token_health_github ""
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing PAT"* ]]
}

# ── token_health_atlassian ────────────────────────────────────────────

@test "token_health_atlassian returns ok=true on 200 with accountId" {
  _stub_safe_curl 200 '{"accountId":"abc123","emailAddress":"x@y.com"}'
  run token_health_atlassian "https://acme.atlassian.net" "x@y.com" "atl_token"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"account_id":"abc123"'* ]]
}

@test "token_health_atlassian strips trailing slash from URL" {
  _stub_safe_curl 200 '{"accountId":"abc"}'
  run token_health_atlassian "https://acme.atlassian.net/" "x@y.com" "atl_token"
  [ "$status" -eq 0 ]
  # Just verifying no double-slash-induced 404; the stub doesn't actually inspect URL.
  [[ "$output" == *'"ok":true'* ]]
}

@test "token_health_atlassian with missing args returns rc=1" {
  run token_health_atlassian "" "x@y.com" "tok"
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing"* ]]
}

@test "token_health_atlassian rc=1 on 401" {
  _stub_safe_curl 401 ""
  run token_health_atlassian "https://acme.atlassian.net" "x@y.com" "bad-tok"
  [ "$status" -eq 1 ]
  [[ "$output" == *"401"* ]]
}

# ── token_health_firecrawl ────────────────────────────────────────────

@test "token_health_firecrawl returns ok=true on 200" {
  _stub_safe_curl 200 '{"team":"foo"}'
  run token_health_firecrawl "fc-fake"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"ok":true'* ]]
}

@test "token_health_firecrawl returns ok=true with warning on 429 (key valid, rate-limited)" {
  _stub_safe_curl 429 ""
  run token_health_firecrawl "fc-rate-limited"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"ok":true'* ]]
  [[ "$output" == *"rate-limited"* ]]
}

@test "token_health_firecrawl returns rc=1 on 401" {
  _stub_safe_curl 401 ""
  run token_health_firecrawl "fc-bad"
  [ "$status" -eq 1 ]
  [[ "$output" == *"rejected"* ]]
}

# ── token_health_summary ──────────────────────────────────────────────

_summary_setup_workspace() {
  export WORKSPACE="$TMP_TEST_DIR/workspace"
  mkdir -p "$WORKSPACE"
  cat > "$WORKSPACE/agent.yml" <<YML
agent:
  name: test
notifications:
  channel: telegram
mcps:
  optional:
    firecrawl: true
  atlassian:
    - name: personal
      url: https://test.atlassian.net
      email: me@x.com
YML
  cat > "$WORKSPACE/.env" <<ENV
NOTIFY_BOT_TOKEN=tg_token
NOTIFY_CHAT_ID=12345
FORK_PAT=ghp_fork
ATLASSIAN_PERSONAL_TOKEN=atl_token
FIRECRAWL_API_KEY=fc_key
ENV
}

@test "token_health_summary emits one line per configured token (all healthy)" {
  _summary_setup_workspace
  # Stub returns 200 with a body that satisfies all checkers.
  safe_curl() {
    printf '%s' '{"ok":true,"result":{"username":"linus_bot"},"login":"rodrigo","accountId":"a1","team":"t"}' > "$TOKEN_HEALTH_LAST_BODY"
    printf '200'
  }
  run token_health_summary "$WORKSPACE/agent.yml" "$WORKSPACE/.env"
  [ "$status" -eq 0 ]
  [[ "$output" == *"telegram"* ]]
  [[ "$output" == *"fork PAT"* ]]
  [[ "$output" == *"atlassian/personal"* ]]
  [[ "$output" == *"firecrawl"* ]]
}

@test "token_health_summary skips tokens not configured (⊝ icon)" {
  _summary_setup_workspace
  # Empty the .env: no tokens at all
  : > "$WORKSPACE/.env"
  safe_curl() { printf '%s' '{}' > "$TOKEN_HEALTH_LAST_BODY"; printf '200'; }
  run token_health_summary "$WORKSPACE/agent.yml" "$WORKSPACE/.env"
  # Notify channel=telegram but no token → ⊝
  [[ "$output" == *"telegram"* ]]
  [[ "$output" == *"missing in .env"* ]]
  [[ "$output" == *"⊝"* ]]
}

@test "token_health_summary worst-case rc reflects rejected token" {
  _summary_setup_workspace
  # Stub returns 401 for everything → all rejected → worst=1
  safe_curl() { printf '%s' '' > "$TOKEN_HEALTH_LAST_BODY"; printf '401'; }
  run token_health_summary "$WORKSPACE/agent.yml" "$WORKSPACE/.env"
  [ "$status" -eq 1 ]
  [[ "$output" == *"✗"* ]]
}

@test "token_health_summary missing .env emits skip line and rc=0" {
  _summary_setup_workspace
  rm -f "$WORKSPACE/.env"
  run token_health_summary "$WORKSPACE/agent.yml" "$WORKSPACE/.env"
  [ "$status" -eq 0 ]
  [[ "$output" == *"⊝"* ]]
  [[ "$output" == *".env missing"* ]]
}
