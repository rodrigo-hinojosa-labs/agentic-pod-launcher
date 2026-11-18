#!/usr/bin/env bats

load helper
load helper-local-healthcheck

setup() {
  setup_tmp_dir
  hc_fixture_setup
  NOW=2000000000000
  CREDS="$HC_WS/.state/.claude/.credentials.json"
  hc_fixture_credentials "$((NOW+3600000))" "$((NOW+2592000000))"
}

teardown() { hc_fixture_teardown; teardown_tmp_dir; }

auth_class() {
  run hc_fixture_call hc_auth_snapshot "$CREDS" "$NOW"
  [ "$status" -eq 0 ] || return
  [ "$(printf '%s' "$output" | jq -r .auth_class)" = "$1" ]
}

credentials_edit() {
  local v
  v=$(jq "$1" "$CREDS") || return
  printf '%s\n' "$v" > "$CREDS"
}

journal_class() {
  run hc_fixture_call hc_journal_snapshot agent-test.service renewable "$HC_FIX/capture" 1025000
  [ "$status" -eq 0 ] || return
  [ "$(printf '%s' "$output" | jq -r .journal_class)" = "$1" ]
}

journal_tail_deadline() {
  printf '%s\n' "$2" 'ordinary trailing event' > "$HC_FIX/journal"
  cat > "$HC_FIX/overrides.sh" <<'SH'
_hc_before() {
  [ "${terminal:-false}" = false ] && [ "${unknown_401:-false}" = false ]
}
SH
  journal_class "$1" || return
  run hc_fixture_call hc_observe "$HC_WS" agent-test.service "$NOW" 1060000
  [ "$status" -eq 0 ] || return
  [ "$(printf '%s' "$output" | jq -r .health)" = DEGRADED ]
  printf '%s\n' "$output" | jq -e '.reason_codes|index("journal_unknown")!=null' >/dev/null
}

@test "047 A01: complete future access and renewal are renewable" {
  auth_class renewable
}

@test "047 A02: expired access with distant renewal stays renewable" {
  credentials_edit ".claudeAiOauth.expiresAt=$((NOW-1))"
  auth_class renewable
}

@test "047 A03: exact two cleared tokens and numeric zero mean login_lost" {
  printf '%s\n' '{"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":0}}' > "$CREDS"
  auth_class login_lost
}

@test "047 A04: only one cleared token is incomplete" {
  local key
  for key in accessToken refreshToken; do
    hc_fixture_credentials "$((NOW+3600000))" "$((NOW+2592000000))"
    credentials_edit ".claudeAiOauth.$key=\"\""
    auth_class incomplete || return
  done
}

@test "047 A05: missing null or non-string tokens are incomplete" {
  local key value
  for key in accessToken refreshToken; do
    for value in null 0 true '[]' '{}'; do
      hc_fixture_credentials "$((NOW+3600000))" "$((NOW+2592000000))"
      credentials_edit ".claudeAiOauth.$key=$value"
      auth_class incomplete || return
    done
    credentials_edit "del(.claudeAiOauth.$key)"
    auth_class incomplete || return
  done
}

@test "047 A06: invalid JSON and non-object OAuth roots stay incomplete" {
  local value
  for value in broken '[]' null '{}' '{"claudeAiOauth":[]}' '{"claudeAiOauth":null}'; do
    printf '%s\n' "$value" > "$CREDS"
    auth_class incomplete || return
  done
  hc_fixture_credentials "$((NOW+3600000))" "$((NOW+2592000000))"
  local valid order
  valid=$(cat "$CREDS")
  for order in first last twice; do
    case "$order" in
      first) printf '%s\n{}\n' "$valid" > "$CREDS" ;;
      last) printf '{}\n%s\n' "$valid" > "$CREDS" ;;
      twice) printf '%s\n%s\n' "$valid" "$valid" > "$CREDS" ;;
    esac
    run hc_fixture_cli
    [ "$status" -eq 1 ] || return
    auth_class incomplete || return
  done
}

@test "047 A07: missing unreadable nonregular credentials or jq are incomplete" {
  rm "$CREDS"
  auth_class incomplete
  mkdir "$CREDS"
  auth_class incomplete
  rmdir "$CREDS"
  hc_fixture_credentials "$((NOW+3600000))" "$((NOW+2592000000))"
  chmod 000 "$CREDS"
  auth_class incomplete
  chmod 600 "$CREDS"
  mv "$HC_BIN/jq" "$HC_BIN/jq.hidden"
  run hc_fixture_call hc_auth_snapshot "$CREDS" "$NOW"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"incomplete"'* ]] || return 1
}

@test "047 A08: both timestamps require positive safe integers" {
  local key value
  for key in expiresAt refreshTokenExpiresAt; do
    for value in null '"2000000000000"' true 1.5 0 -1 9007199254740992; do
      hc_fixture_credentials "$((NOW+3600000))" "$((NOW+2592000000))"
      credentials_edit ".claudeAiOauth.$key=$value"
      auth_class incomplete || return
    done
    credentials_edit "del(.claudeAiOauth.$key)"
    auth_class incomplete || return
  done
}

@test "047 A09: mcpOAuth timestamps never replace claudeAiOauth fields" {
  credentials_edit '{mcpOAuth:{expiresAt:1,refreshTokenExpiresAt:1},claudeAiOauth:(.claudeAiOauth|.expiresAt=.refreshTokenExpiresAt)}'
  auth_class renewable
  credentials_edit '.mcpOAuth={expiresAt:1,refreshTokenExpiresAt:1}'
  auth_class renewable
  credentials_edit 'del(.claudeAiOauth.refreshTokenExpiresAt) | .mcpOAuth.refreshTokenExpiresAt=9007199254740991'
  auth_class incomplete
}

@test "047 A10: expired renewal degrades even while access is future" {
  credentials_edit ".claudeAiOauth.refreshTokenExpiresAt=$((NOW-1))"
  auth_class renewal_expired
  [[ "$output" != *'login_lost'* ]] || return 1
}

@test "047 A11: unrelated extra fields do not affect renewable classification" {
  credentials_edit '.extra={expiresAt:0} | .claudeAiOauth.scope="synthetic"'
  auth_class renewable
}

@test "047 A12: incomplete login with an expired-looking date is still unknown" {
  credentials_edit '.claudeAiOauth={expiresAt:1,refreshTokenExpiresAt:1}'
  auth_class incomplete
}

@test "047 A13: classifiers return only closed non-secret fields" {
  run hc_fixture_call hc_auth_snapshot "$CREDS" "$NOW"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e 'keys==["auth_class","cause","renewal_remaining_ms"]' >/dev/null
  [[ "$output" != *'fictional-access-sentinel'* ]] || return 1
  [[ "$output" != *'fictional-refresh-sentinel'* ]] || return 1
  # jq receives the filename, never token values via --arg/argv.
  jq -e -s 'any(.[]; .source=="product" and .tool=="jq") and all(.[]|select(.source=="product"); .secret_in_argv==false and .secret_in_env==false)' "$HC_FIX/calls.jsonl" >/dev/null
}

@test "047 A14: thirty full evaluations with expired access remain OK without notices" {
  hc_fixture_credentials 1 9007199254740991
  local n
  for n in $(seq 1 30); do
    run hc_fixture_cli
    [ "$status" -eq 0 ] || return
    [[ "$output" == *'healthcheck: OK'* ]] || return 1
  done
  [ ! -e "$HC_FIX/transport.jsonl" ]
  [ ! -e "$HC_WS/.state/local-healthcheck.json" ]
}

@test "047 A15: integer boundaries and timestamp units are not guessed" {
  hc_fixture_credentials 1 9007199254740991
  auth_class renewable
  hc_fixture_credentials "$NOW" 2000000000
  auth_class renewal_expired
  hc_fixture_credentials "$NOW" 9007199254740992
  auth_class incomplete
}

@test "047 A16: seven days plus one millisecond has no expiry warning" {
  hc_fixture_credentials 1 "$((NOW+604800001))"
  auth_class renewable
}

@test "047 A17: exactly seven days and every positive smaller boundary warn" {
  local ttl
  for ttl in 604800000 604799999 3600000 1; do
    hc_fixture_credentials 1 "$((NOW+ttl))"
    auth_class renewal_expiring || return
    [ "$(printf '%s' "$output" | jq .renewal_remaining_ms)" -eq "$ttl" ] || return
  done
}

@test "047 A18: renewal at now or in the past is expired" {
  hc_fixture_credentials "$((NOW+3600000))" "$NOW"
  auth_class renewal_expired
  hc_fixture_credentials "$((NOW+3600000))" "$((NOW-1))"
  auth_class renewal_expired
}

@test "047 A19: remaining duration rounds up days hours and subhour label" {
  local pair ttl expected
  for pair in '604800000:7d' '86400001:2d' '86400000:1d' '86399999:24h' '3600001:2h' '3600000:1h' '3599999:<1h' '1:<1h'; do
    ttl=${pair%%:*}; expected=${pair#*:}
    hc_fixture_credentials "$((NOW+3600000))" "$((NOW+ttl))"
    run hc_fixture_cli
    [ "$status" -eq 1 ] || return
    [[ "$output" == *"login renewal expiring in $expected"* ]] || return 1
  done
}

@test "047 A20: new login removes expiry while unrelated WARN is retained" {
  hc_fixture_credentials "$((NOW+3600000))" "$((NOW-1))"
  run hc_fixture_cli
  [ "$status" -eq 2 ]
  [[ "$output" == *'login renewal expired'* ]] || return 1
  hc_fixture_credentials 1 "$((NOW+2592000000))"
  hc_fixture_setting qmd_failed true
  run hc_fixture_cli
  [ "$status" -eq 1 ]
  [[ "$output" == *'watcher failed'* ]] || return 1
  [[ "$output" != *'login renewal expired'* && "$output" != *'login renewal expiring'* ]] || return 1
}

@test "047 J01: an empty successful journal is clear" { journal_class clear; }

@test "047 J02: failed missing or timed-out journal is unknown" {
  run hc_fixture_call hc_journal_snapshot agent-test.service renewable "$HC_FIX/expired-capture" 1000000
  [ "$status" -eq 0 ]
  [[ "$output" == *'"unknown"'* ]] || return 1
  [ ! -e "$HC_FIX/expired-capture" ]
  hc_fixture_setting journal_rc 1
  journal_class unknown
  hc_fixture_setting journal_rc 124
  journal_class unknown
  mv "$HC_BIN/journalctl" "$HC_BIN/journalctl.hidden"
  journal_class unknown
}

@test "047 J03: either terminal login phrase defeats future timestamps" {
  local phrase
  for phrase in 'Please run /login' 'You must be logged in to use Remote Control'; do
    printf '%s\n' "$phrase" > "$HC_FIX/journal"
    journal_class terminal || return
  done
}

@test "047 J04: the known access expiry event is not terminal" {
  printf '%s\n' 'Authentication failed (401): OAuth access token has expired' > "$HC_FIX/journal"
  journal_class clear
}

@test "047 J05: known access event cannot promote incomplete login" {
  printf '%s\n' 'Authentication failed (401): OAuth access token has expired' > "$HC_FIX/journal"
  run hc_fixture_call hc_journal_snapshot agent-test.service incomplete "$HC_FIX/capture" 1025000
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .journal_class)" = clear ]
  # The independent auth result must remain WARN in the composed observation.
  printf '{}\n' > "$CREDS"
  run hc_fixture_cli
  [ "$status" -eq 1 ]
  [[ "$output" == *'cannot verify login renewal'* ]] || return 1
}

@test "047 J06: unknown authentication and refresh 401 remain degraded evidence" {
  local phrase
  for phrase in 'API Error: 401' 'Authentication failed (401): unrecognized' 'Failed to refresh session: 401'; do
    printf '%s\n' "$phrase" > "$HC_FIX/journal"
    journal_class unclassified_401 || return
    [[ "$output" != *'revoked'* ]] || return 1
  done
}

@test "047 J07: refresh failure alone is unverified rather than lost login" {
  printf '%s\n' 'Failed to refresh session: temporary network failure' > "$HC_FIX/journal"
  journal_class refresh_unverified
}

@test "047 J08: terminal and access exception in either order remain terminal" {
  printf '%s\n' 'Please run /login' 'Authentication failed (401): OAuth access token has expired' > "$HC_FIX/journal"
  journal_class terminal
  journal_tail_deadline terminal 'Please run /login'
  printf '%s\n' 'Authentication failed (401): OAuth access token has expired' 'Please run /login' > "$HC_FIX/journal"
  journal_class terminal
}

@test "047 J09: unknown 401 and access exception in either order remain unclassified" {
  printf '%s\n' 'API Error: 401' 'Authentication failed (401): OAuth access token has expired' > "$HC_FIX/journal"
  journal_class unclassified_401
  printf '%s\n' 'Authentication failed (401): OAuth access token has expired' 'API Error: 401' > "$HC_FIX/journal"
  journal_class unclassified_401
  journal_tail_deadline unclassified_401 'API Error: 401'
}

@test "047 J10: large journal files classify beginning/end without argv or SIGPIPE" {
  local position
  for position in first last; do
    python3 - "$HC_FIX/journal" "$position" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1]);pad=('x'*100+'\n')*1800
p.write_text(('Please run /login\n'+pad) if sys.argv[2]=='first' else (pad+'Please run /login\n'))
PY
    journal_class terminal || return
  done
  jq -e -s 'all(.[]; .tool!="journalctl" or (.args|index("2000")!=null))' "$HC_FIX/calls.jsonl" >/dev/null
}
