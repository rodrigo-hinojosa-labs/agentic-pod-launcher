#!/usr/bin/env bats
# Tests for docker/scripts/lib/token_health.sh — pure functions.
# Curl is stubbed via PATH override (see _stub_curl). Each test wires
# its own stub so we can assert each probe sends the right URL + headers.

load 'helper'

setup() {
  LIB="$BATS_TEST_DIRNAME/../docker/scripts/lib/token_health.sh"
  # shellcheck source=/dev/null
  source "$LIB"

  STUB_DIR="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_DIR"
  ORIG_PATH="$PATH"
}

teardown() {
  PATH="$ORIG_PATH"
}

# Write a curl stub that echoes a fixed http_code and records its
# argv to $STUB_DIR/curl.argv for later assertion. The stub respects
# the -w '%{http_code}' contract — it echoes the http_code on stdout
# (curl uses -o /dev/null so no body output).
_stub_curl() {
  local code="$1"
  cat > "$STUB_DIR/curl" <<STUB
#!/bin/sh
printf '%s\n' "\$@" > "$STUB_DIR/curl.argv"
printf '%s' "$code"
exit 0
STUB
  chmod +x "$STUB_DIR/curl"
  PATH="$STUB_DIR:$ORIG_PATH"
}

# ── Probe outcome classification ────────────────────────────────────

@test "_th_run_probe: 200 → ok" {
  _stub_curl 200
  run _th_run_probe "https://example.com/probe"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^ok 200 [0-9]+'
}

@test "_th_run_probe: 401 → auth_fail" {
  _stub_curl 401
  run _th_run_probe "https://example.com/probe"
  echo "$output" | grep -qE '^auth_fail 401 [0-9]+ HTTP 401'
}

@test "_th_run_probe: 403 → auth_fail" {
  _stub_curl 403
  run _th_run_probe "https://example.com/probe"
  echo "$output" | grep -q '^auth_fail 403'
}

@test "_th_run_probe: 500 → network" {
  _stub_curl 500
  run _th_run_probe "https://example.com/probe"
  echo "$output" | grep -q '^network 500'
}

@test "_th_run_probe: curl returning empty (000) → network" {
  cat > "$STUB_DIR/curl" <<'STUB'
#!/bin/sh
printf ''
exit 6
STUB
  chmod +x "$STUB_DIR/curl"
  PATH="$STUB_DIR:$ORIG_PATH"

  run _th_run_probe "https://example.com/probe"
  echo "$output" | grep -q '^network 000'
}

# ── Per-probe shape ─────────────────────────────────────────────────

@test "probe_github_pat: empty token → skipped" {
  run probe_github_pat ""
  echo "$output" | grep -q '^skipped 000 0 empty token'
}

@test "probe_github_pat: passes Authorization header" {
  _stub_curl 200
  run probe_github_pat "ghp_xxx"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^ok 200'
  grep -q '^Authorization: token ghp_xxx$' "$STUB_DIR/curl.argv"
  grep -q '^https://api.github.com/user$' "$STUB_DIR/curl.argv"
}

@test "probe_telegram_bot: empty token → skipped" {
  run probe_telegram_bot ""
  echo "$output" | grep -q '^skipped 000 0 empty token'
}

@test "probe_telegram_bot: hits /bot<TOKEN>/getMe with override base" {
  _stub_curl 200
  TH_TELEGRAM_API_BASE="https://stub.example" run probe_telegram_bot "9876:abcDEF"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^ok 200'
  grep -q '^https://stub.example/bot9876:abcDEF/getMe$' "$STUB_DIR/curl.argv"
}

@test "probe_atlassian: missing inputs → skipped" {
  run probe_atlassian "" "alice@x" "tk"
  echo "$output" | grep -q '^skipped 000 0 missing url/email/token'
  run probe_atlassian "https://x" "" "tk"
  echo "$output" | grep -q '^skipped'
  run probe_atlassian "https://x" "alice@x" ""
  echo "$output" | grep -q '^skipped'
}

@test "probe_atlassian: builds /rest/api/3/myself URL + basic auth" {
  _stub_curl 200
  run probe_atlassian "https://acme.atlassian.net/" "alice@acme.com" "atl_xxx"
  [ "$status" -eq 0 ]
  # Trailing slash on URL must be stripped before joining the path.
  grep -q '^https://acme.atlassian.net/rest/api/3/myself$' "$STUB_DIR/curl.argv"
  # -u <user>:<token> args appear contiguously.
  grep -q '^alice@acme.com:atl_xxx$' "$STUB_DIR/curl.argv"
}

# ── Atlassian env discovery ─────────────────────────────────────────

@test "discover_atlassian_workspaces: no env → empty output" {
  run discover_atlassian_workspaces
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "discover_atlassian_workspaces: one workspace" {
  export ATLASSIAN_WORK_TOKEN="atl_xxx"
  export ATLASSIAN_WORK_JIRA_URL="https://work.atlassian.net"
  export ATLASSIAN_WORK_JIRA_USERNAME="alice@work.com"

  run discover_atlassian_workspaces
  [ "$status" -eq 0 ]
  # Name lower-cased, fields pipe-delimited.
  [ "$output" = "work|https://work.atlassian.net|alice@work.com|atl_xxx" ]

  unset ATLASSIAN_WORK_TOKEN ATLASSIAN_WORK_JIRA_URL ATLASSIAN_WORK_JIRA_USERNAME
}

@test "discover_atlassian_workspaces: two workspaces, sorted" {
  export ATLASSIAN_WORK_TOKEN="atk1"
  export ATLASSIAN_WORK_JIRA_URL="https://work.atlassian.net"
  export ATLASSIAN_WORK_JIRA_USERNAME="alice@work.com"
  export ATLASSIAN_PERSONAL_TOKEN="atk2"
  export ATLASSIAN_PERSONAL_JIRA_URL="https://me.atlassian.net"
  export ATLASSIAN_PERSONAL_JIRA_USERNAME="alice@me.com"

  run discover_atlassian_workspaces
  [ "$status" -eq 0 ]
  # env|grep|sort emits PERSONAL before WORK alphabetically.
  echo "$output" | head -1 | grep -q '^personal|'
  echo "$output" | tail -1 | grep -q '^work|'

  unset ATLASSIAN_WORK_TOKEN ATLASSIAN_WORK_JIRA_URL ATLASSIAN_WORK_JIRA_USERNAME
  unset ATLASSIAN_PERSONAL_TOKEN ATLASSIAN_PERSONAL_JIRA_URL ATLASSIAN_PERSONAL_JIRA_USERNAME
}

# ── State file roundtrip ────────────────────────────────────────────

@test "token_health_read_state: missing file returns {}" {
  run token_health_read_state "$BATS_TEST_TMPDIR/missing.json"
  [ "$output" = "{}" ]
}

@test "token_health_write_state: atomic — never half-written" {
  local f="$BATS_TEST_TMPDIR/state/github.json"
  token_health_write_state "$f" '{"id":"github","status":"ok"}'
  [ -f "$f" ]
  jq -e '.status == "ok"' "$f" >/dev/null

  # No leftover .tmp files in the dir.
  [ "$(find "$(dirname "$f")" -maxdepth 1 -name '.*.XXXXXX' | wc -l)" -eq 0 ]
}

# ── Transition decisions ────────────────────────────────────────────
# token_health_decide_action prev new last_warn_epoch now_epoch dedup_secs
# Output: warn|recover|silent

@test "decide_action: first probe ok → silent" {
  run token_health_decide_action "" "ok" "" 1700000000 86400
  [ "$output" = "silent" ]
}

@test "decide_action: first probe auth_fail → warn" {
  run token_health_decide_action "" "auth_fail" "" 1700000000 86400
  [ "$output" = "warn" ]
}

@test "decide_action: ok→auth_fail → warn (token just expired)" {
  run token_health_decide_action "ok" "auth_fail" "" 1700000000 86400
  [ "$output" = "warn" ]
}

@test "decide_action: auth_fail→ok → recover (user fixed it)" {
  run token_health_decide_action "auth_fail" "ok" 1699900000 1700000000 86400
  [ "$output" = "recover" ]
}

@test "decide_action: persistent auth_fail within dedup window → silent" {
  # last_warn was 1h ago, dedup is 24h → still silent.
  run token_health_decide_action "auth_fail" "auth_fail" \
    "$((1700000000 - 3600))" 1700000000 86400
  [ "$output" = "silent" ]
}

@test "decide_action: persistent auth_fail past dedup window → warn (re-remind)" {
  # last_warn was 25h ago, dedup is 24h → warn again.
  run token_health_decide_action "auth_fail" "auth_fail" \
    "$((1700000000 - 90000))" 1700000000 86400
  [ "$output" = "warn" ]
}

@test "decide_action: ok→network is silent (transient blip)" {
  run token_health_decide_action "ok" "network" "" 1700000000 86400
  [ "$output" = "silent" ]
}

@test "decide_action: persistent network past dedup → warn" {
  run token_health_decide_action "network" "network" \
    "$((1700000000 - 90000))" 1700000000 86400
  [ "$output" = "warn" ]
}

# ── Message formatting ──────────────────────────────────────────────

@test "format_warning: includes id, kind, error, and a regen hint URL" {
  run token_health_format_warning "github" "github_pat" "HTTP 401"
  echo "$output" | grep -q "github"
  echo "$output" | grep -q "github_pat"
  echo "$output" | grep -q "HTTP 401"
  echo "$output" | grep -q "https://github.com/settings/tokens"
  echo "$output" | grep -q "setup.sh --regenerate"
}

@test "format_warning: telegram_bot points at BotFather" {
  run token_health_format_warning "telegram" "telegram_bot" "HTTP 401"
  echo "$output" | grep -q "BotFather"
}

@test "format_warning: atlassian points at id.atlassian.com tokens page" {
  run token_health_format_warning "atlassian-work" "atlassian" "HTTP 401"
  echo "$output" | grep -q "id.atlassian.com/manage-profile/security/api-tokens"
}

@test "format_recovery: distinct shape from warning" {
  run token_health_format_recovery "github" "github_pat"
  echo "$output" | grep -q "recovered"
  echo "$output" | grep -q "github"
}

# ── 048: Atlassian probe falls back to Confluence when Jira is absent ─

# A curl stub that answers by URL: JIRA_CODE for .../rest/api/3/myself and
# CONF_CODE for .../wiki/rest/api/user/current; every URL is logged, one per
# line, to curl.calls so a test can count the requests.
_stub_curl_route() {
  local jira="$1" conf="$2"
  cat > "$STUB_DIR/curl" <<STUB
#!/bin/sh
url=""
for a in "\$@"; do url="\$a"; done
printf '%s\n' "\$url" >> "$STUB_DIR/curl.calls"
case "\$url" in
  */wiki/rest/api/user/current) printf '%s' "$conf" ;;
  */rest/api/3/myself) printf '%s' "$jira" ;;
  *) printf '000' ;;
esac
exit 0
STUB
  chmod +x "$STUB_DIR/curl"
  : > "$STUB_DIR/curl.calls"
  PATH="$STUB_DIR:$ORIG_PATH"
}

@test "TD01 probe_atlassian: Jira 200 -> ok, one request, Confluence never asked" {
  _stub_curl_route 200 200
  run probe_atlassian "https://acme.atlassian.net" "a@x" "tk"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^ok 200 [0-9]+ ?$'
  [ "$(wc -l < "$STUB_DIR/curl.calls" | tr -d ' ')" = "1" ]
  if grep -q '/wiki/' "$STUB_DIR/curl.calls"; then false; fi
}

@test "TD02 probe_atlassian: Jira 401/403 -> auth_fail, Confluence never asked" {
  local c
  for c in 401 403; do
    _stub_curl_route "$c" 200
    run probe_atlassian "https://acme.atlassian.net" "a@x" "tk"
    echo "$output" | grep -qE "^auth_fail $c [0-9]+ HTTP $c\$"
    [ "$(wc -l < "$STUB_DIR/curl.calls" | tr -d ' ')" = "1" ]
  done
}

@test "TD03 probe_atlassian: Jira 5xx or no answer -> network, Confluence never asked" {
  local c
  for c in 500 503 000; do
    _stub_curl_route "$c" 200
    run probe_atlassian "https://acme.atlassian.net" "a@x" "tk"
    echo "$output" | grep -q '^network '
    [ "$(wc -l < "$STUB_DIR/curl.calls" | tr -d ' ')" = "1" ]
  done
}

@test "TD04 probe_atlassian: Jira 404 + Confluence 200 -> ok via confluence" {
  _stub_curl_route 404 200
  run probe_atlassian "https://acme.atlassian.net" "a@x" "tk"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^ok 200 [0-9]+ via confluence$'
  [ "$(wc -l < "$STUB_DIR/curl.calls" | tr -d ' ')" = "2" ]
  grep -qx 'https://acme.atlassian.net/wiki/rest/api/user/current' "$STUB_DIR/curl.calls"
}

@test "TD05 probe_atlassian: Jira 404 + Confluence 401/403 -> auth_fail naming confluence" {
  local c
  for c in 401 403; do
    _stub_curl_route 404 "$c"
    run probe_atlassian "https://acme.atlassian.net" "a@x" "tk"
    echo "$output" | grep -qE "^auth_fail $c [0-9]+ confluence HTTP $c\$"
  done
}

@test "TD06 probe_atlassian: Jira 404 + Confluence 404/5xx/none -> network naming both" {
  _stub_curl_route 404 404
  run probe_atlassian "https://acme.atlassian.net" "a@x" "tk"
  echo "$output" | grep -qE '^network 404 [0-9]+ jira HTTP 404, confluence HTTP 404$'
  _stub_curl_route 404 502
  run probe_atlassian "https://acme.atlassian.net" "a@x" "tk"
  echo "$output" | grep -qE '^network 502 [0-9]+ jira HTTP 404, confluence HTTP 502$'
  _stub_curl_route 404 000
  run probe_atlassian "https://acme.atlassian.net" "a@x" "tk"
  echo "$output" | grep -qE '^network 000 [0-9]+ jira HTTP 404, confluence curl exit'
}

@test "TD07 probe_atlassian: a configured URL ending in /wiki does not double /wiki" {
  _stub_curl_route 404 200
  run probe_atlassian "https://acme.atlassian.net/wiki/" "a@x" "tk"
  echo "$output" | grep -q '^ok 200 .* via confluence$'
  grep -qx 'https://acme.atlassian.net/rest/api/3/myself' "$STUB_DIR/curl.calls"
  grep -qx 'https://acme.atlassian.net/wiki/rest/api/user/current' "$STUB_DIR/curl.calls"
}
