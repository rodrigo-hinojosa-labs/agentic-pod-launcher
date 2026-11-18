#!/usr/bin/env bats

load helper
load helper-local-healthcheck

setup() {
  setup_tmp_dir
  hc_fixture_setup
  hc_fixture_notice
  STATE="$HC_WS/.state/local-healthcheck.json"
}
teardown() { hc_fixture_teardown; teardown_tmp_dir; }

evaluate() {
  run hc_fixture_evaluate
  printf 'status=%s\n%s\n' "$status" "$output" >> "$HC_FIX/evaluations.log"
  if case "$(jq -r .health "$HC_FIX/snapshot.json")" in
    OK) [ "$status" -eq 0 ] ;;
    WARN) [ "$status" -eq 1 ] ;;
    DEGRADED) [ "$status" -eq 2 ] ;;
    *) false ;;
  esac; then return 0; fi
  notice_failure
  return 1
}
notice_failure() {
  printf 'notice assertion failure; evaluation history:\n'
  [ ! -f "$HC_FIX/evaluations.log" ] || cat "$HC_FIX/evaluations.log"
  printf '\ncurrent ledger:\n'
  [ ! -f "$STATE" ] || cat "$STATE"
  printf '\nexpired synthetic commands (name, elapsed, term, grace, status):\n'
  [ ! -f "$HC_FIX/timeout-failures.tsv" ] || cat "$HC_FIX/timeout-failures.tsv"
}
calls_are() {
  local count=0
  [ ! -f "$HC_FIX/curl-count" ] || count=$(cat "$HC_FIX/curl-count")
  if [ "$count" -eq "$1" ] 2>/dev/null; then return 0; fi
  printf 'transport count: actual=%s expected=%s\nlast CLI output:\n%s\n' "$count" "$1" "${output:-}"
  notice_failure
  [ ! -f "$HC_FIX/calls.jsonl" ] || tail -n 40 "$HC_FIX/calls.jsonl"
  return 1
}
confirmed() {
  if [ -f "$STATE" ] && jq -e '.pending==null and .episode.notified==true' "$STATE" >/dev/null; then return 0; fi
  notice_failure
  return 1
}
pending() {
  if [ -f "$STATE" ] && jq -e '.pending.phase=="inflight" and .pending.retry_remaining_s>0' "$STATE" >/dev/null; then return 0; fi
  notice_failure
  return 1
}
epoch() { hc_fixture_setting epoch_s "$1"; }
seed_confirmed() {
  printf '%s\n' '{"schema":1,"identity":"DEGRADED","event_version":1,"episode":{"id":1,"notified":true},"pending":null}' > "$STATE"
  chmod 600 "$STATE"
}

@test "047 N01: invalid schema fields types ranges and oversized records reset privately" {
  local value
  for value in '{"schema":2}' '{"schema":1,"extra":true}' '[]' null \
    '{"schema":1,"identity":"NONE","event_version":0,"episode":null,"pending":null} {"schema":1,"identity":"NONE","event_version":0,"episode":null,"pending":null}'; do
    printf '%s\n' "$value" > "$STATE"
    chmod 600 "$STATE"
    evaluate
    [[ "$output" == *state_reset* ]] || return 1
    confirmed || return
    jq -e 'keys==["episode","event_version","identity","pending","schema"] and .schema==1' "$STATE" >/dev/null || return
  done
  python3 - "$STATE" <<'PY'
from pathlib import Path
import sys
Path(sys.argv[1]).write_text(' '*17000+'{}')
PY
  evaluate
  [[ "$output" == *state_reset* ]] || return 1
  local mode
  mode=$(stat -c %a "$STATE" 2>/dev/null) || mode=$(stat -f %Lp "$STATE")
  [ "$mode" = 600 ]
  [ "$(wc -c < "$STATE")" -le 16384 ]
  local before
  before=$(cat "$HC_FIX/curl-count")
  chmod 644 "$STATE"
  hc_fixture_snapshot NONE
  evaluate
  [[ "$output" == *state_unavailable* ]] || return 1
  calls_are "$before"
}

@test "047 N02: cross-field inconsistencies reset and version overflow suspends" {
  local edit
  for edit in '.episode.notified=false' '.episode.id=2' '.identity="NONE"' '.event_version=-1'; do
    seed_confirmed
    jq "$edit" "$STATE" > "$HC_FIX/next"
    mv "$HC_FIX/next" "$STATE"; chmod 600 "$STATE"
    evaluate
    [[ "$output" == *state_reset* ]] || return 1
    confirmed || return
  done
  for edit in '.pending.kind="RECOVERY" | .episode.notified=false' '.pending.kind="WARN_EXPIRY"' '.pending.version=2' '.pending.clock_seen_s=-1' '.pending.attempted_at_s=2 | .pending.clock_seen_s=1' '.pending.phase="ready" | .pending.attempted_at_s=0' '.pending.retry_remaining_s=1801'; do
    printf '%s\n' '{"schema":1,"identity":"DEGRADED","event_version":1,"episode":{"id":1,"notified":false},"pending":{"version":1,"kind":"DEGRADED","phase":"inflight","attempted_at_s":0,"clock_seen_s":0,"retry_remaining_s":1800}}' > "$STATE"
    jq "$edit" "$STATE" > "$HC_FIX/next"
    mv "$HC_FIX/next" "$STATE"; chmod 600 "$STATE"
    evaluate
    [[ "$output" == *state_reset* ]] || return 1
    confirmed || return
  done
  seed_confirmed
  jq '.event_version=9007199254740990' "$STATE" > "$HC_FIX/next"
  mv "$HC_FIX/next" "$STATE"; chmod 600 "$STATE"
  hc_fixture_snapshot NONE
  local before
  before=$(cat "$HC_FIX/curl-count")
  evaluate
  [ "$(cat "$HC_FIX/curl-count")" = "$before" ]
  [[ "$output" == *state_unavailable* ]] || return 1
  jq '.pending={version:.event_version,kind:"DEGRADED",phase:"inflight",attempted_at_s:0,clock_seen_s:0,retry_remaining_s:0}' "$STATE" > "$HC_FIX/next"
  mv "$HC_FIX/next" "$STATE"; chmod 600 "$STATE"
  hc_fixture_snapshot DEGRADED
  evaluate
  [ "$(cat "$HC_FIX/curl-count")" = "$before" ]
  [[ "$output" == *state_unavailable* ]] || return 1
  seed_confirmed
  jq '.event_version=9007199254740989' "$STATE" > "$HC_FIX/next"
  mv "$HC_FIX/next" "$STATE"; chmod 600 "$STATE"
  hc_fixture_snapshot NONE
  evaluate
  calls_are "$before"
  [[ "$output" == *state_unavailable* ]] || return 1
}

@test "047 N03: WARN from another component has NONE identity and no alarm" {
  hc_fixture_setting qmd_failed true
  run hc_fixture_cli
  [ "$status" -eq 1 ]
  [[ "$output" == *'watcher failed'* ]] || return 1
  calls_are 0
}

@test "047 N04: first expiry warning and thirty repeats confirm only once" {
  hc_fixture_snapshot WARN_EXPIRY
  local n
  for n in $(seq 1 31); do evaluate || return; done
  calls_are 1
  confirmed
  [ "$(jq .event_version "$STATE")" -eq 1 ]
}

@test "047 N05: thirty W then thirty D and recovery confirm three notices" {
  local identity n
  for identity in WARN_EXPIRY DEGRADED; do
    hc_fixture_snapshot "$identity"
    for n in $(seq 1 30); do evaluate || return; done
    case "$identity" in WARN_EXPIRY) calls_are 1 ;; DEGRADED) calls_are 2 ;; esac || return
    confirmed || return
  done
  hc_fixture_snapshot NONE
  evaluate
  calls_are 3
  jq -e '.episode==null and .pending==null and .event_version==3' "$STATE" >/dev/null
}

@test "047 N06: D to expiry warning is one partial recovery with episode retained" {
  evaluate
  hc_fixture_snapshot WARN_EXPIRY
  evaluate
  calls_are 2
  confirmed
  [ "$(jq -r .identity "$STATE")" = WARN_EXPIRY ]
  jq -e -s '.[1].event=="RECOVERY_WARN" and .[1].health_warn' "$HC_FIX/transport.jsonl" >/dev/null
  [[ "$output" != *'healthcheck: OK'* ]] || return 1
  hc_fixture_snapshot NONE; evaluate
  hc_fixture_snapshot DEGRADED; evaluate
  hc_fixture_snapshot WARN_OTHER; evaluate
  calls_are 5
  jq -e -s '.[4].event=="RECOVERY" and .[4].health_warn' "$HC_FIX/transport.jsonl" >/dev/null
  jq -e -s '.[4].qmd_warning_in_text and .[1].expiry_detail' "$HC_FIX/transport.jsonl" >/dev/null
  jq -e '.episode==null' "$STATE" >/dev/null
  hc_fixture_setting curl_rc 7
  hc_fixture_snapshot DEGRADED; evaluate
  hc_fixture_setting curl_rc 0
  hc_fixture_snapshot WARN_EXPIRY; evaluate
  calls_are 7
  jq -e -s '.[6].event=="WARN_EXPIRY"' "$HC_FIX/transport.jsonl" >/dev/null
}

@test "047 N07: D W D creates another version when reentering degradation" {
  evaluate
  hc_fixture_snapshot WARN_EXPIRY; evaluate
  hc_fixture_snapshot DEGRADED; evaluate
  calls_are 3
  [ "$(jq .event_version "$STATE")" -eq 3 ]
}

@test "047 N08: changed reasons in the same identity do not send again" {
  evaluate
  jq -c '.reason_codes=["renewal_expired"] | .auth_class="renewal_expired"' "$HC_FIX/snapshot.json" > "$HC_FIX/next"
  mv "$HC_FIX/next" "$HC_FIX/snapshot.json"
  evaluate
  calls_are 1
}

@test "047 N09: a new process after confirmed delivery does not repeat" {
  evaluate
  evaluate
  calls_are 1
  confirmed
}

@test "047 N10: confirmed recovery closes episode and the next alarm opens another" {
  evaluate
  hc_fixture_snapshot NONE; evaluate
  hc_fixture_snapshot DEGRADED; evaluate
  calls_are 3
  jq -e '.episode.id==3 and .episode.notified and .event_version==3' "$STATE" >/dev/null
}

@test "047 N11: resolution before any confirmation is silent and cancels pending" {
  hc_fixture_setting curl_rc 7
  evaluate
  pending
  hc_fixture_snapshot NONE
  evaluate
  calls_are 1
  jq -e '.episode==null and .pending==null' "$STATE" >/dev/null
}

@test "047 N12: recovery debt survives NONE failed D failed NONE" {
  evaluate
  hc_fixture_setting curl_rc 7
  hc_fixture_snapshot NONE; evaluate
  hc_fixture_snapshot DEGRADED; evaluate
  hc_fixture_snapshot NONE; evaluate
  calls_are 4
  jq -e '.episode.notified and .pending.kind=="RECOVERY"' "$STATE" >/dev/null
}

@test "047 N13: a new transition cancels stale pending without inheriting retry wait" {
  hc_fixture_setting curl_rc 7
  evaluate
  hc_fixture_snapshot WARN_EXPIRY
  evaluate
  calls_are 2
  jq -e '.pending.kind=="WARN_EXPIRY" and .pending.version==2' "$STATE" >/dev/null
}

@test "047 N14: attempts only at 0 30 60 minutes and at the exact retry boundary" {
  hc_fixture_setting curl_rc 7
  local minute
  for minute in 0 5 25 30 55 60 65; do
    [ "$minute" -ne 60 ] || hc_fixture_setting curl_rc 0
    epoch "$((minute*60))"; evaluate || return
  done
  calls_are 3
  confirmed
  epoch 7200; evaluate; calls_are 3
  # Separate episode to check 1799 versus 1800 seconds without real waiting.
  hc_fixture_snapshot NONE; evaluate
  hc_fixture_snapshot DEGRADED
  hc_fixture_setting curl_rc 7
  epoch 9000; evaluate
  epoch 10799; evaluate; calls_are 5
  epoch 10800; evaluate; calls_are 6
}

@test "047 N15: backward epoch correction never credits the same time twice" {
  hc_fixture_setting curl_rc 7
  local t expected
  for t in 0 600 300 1200 1500; do
    epoch "$t"; evaluate || return
    case "$t" in 0) expected=1800 ;; 600|300) expected=1200 ;; 1200) expected=600 ;; 1500) expected=300 ;; esac
    [ "$(jq .pending.retry_remaining_s "$STATE")" -eq "$expected" ] || return
  done
  calls_are 1
  [ "$(jq .pending.clock_seen_s "$STATE")" -eq 1500 ]
}

@test "047 N16: restart preserves retry reservation and high-water time" {
  hc_fixture_setting curl_rc 7
  epoch 1000; evaluate
  epoch 1600; evaluate
  epoch 1200; evaluate
  calls_are 1
  jq -e '.pending.clock_seen_s==1600 and .pending.retry_remaining_s==1200' "$STATE" >/dev/null
}

@test "047 N17: absent and corrupt records are diagnosed without replaying data" {
  evaluate
  [[ "$output" == *state_reset* ]] || return 1
  printf 'invalid external payload\n' > "$STATE"
  evaluate
  [[ "$output" == *state_reset* ]] || return 1
  [[ "$output" != *'external payload'* ]] || return 1
  calls_are 2
  cp "$STATE" "$HC_FIX/confirmed-before"
  hc_fixture_setting jq_validate_once_rc 124
  evaluate
  calls_are 2
  cmp "$STATE" "$HC_FIX/confirmed-before"
  [[ "$output" == *state_unavailable* && "$output" != *state_reset* ]] || return 1
}

@test "047 N18: failure of either precommit flush or rename prevents all network" {
  local operation
  for operation in write file_flush rename directory_flush; do
    rm -f "$STATE" "$HC_FIX/sync-count" "$HC_FIX/mv-count" "$HC_FIX/sync-prior.json" "$HC_FIX/sync-results.jsonl"
    rm -f "$HC_FIX/overrides.sh" "$HC_FIX/write-fault-hit"
    hc_fixture_setting sync_fail_at '[]'
    hc_fixture_setting mv_fail_at '[]'
    case "$operation" in
      write) hc_fixture_write_fault ;;
      file_flush) hc_fixture_setting sync_fail_at '[1]' ;;
      rename) hc_fixture_setting mv_fail_at '[1]' ;;
      directory_flush) hc_fixture_setting sync_fail_at '[2]' ;;
    esac
    evaluate; calls_are 0
    [[ "$output" == *state_failure* ]] || return 1
    case "$operation" in
      write) [ -f "$HC_FIX/write-fault-hit" ] ;;
      file_flush) jq -e -s '.[-1].kind=="file" and .[-1].rc==1' "$HC_FIX/sync-results.jsonl" >/dev/null ;;
      rename) [ "$(cat "$HC_FIX/mv-count")" -eq 1 ] ;;
      directory_flush) jq -e -s '.[-1].kind=="dir" and .[-1].rc==1' "$HC_FIX/sync-results.jsonl" >/dev/null ;;
    esac || return
  done
}

@test "047 N19: ack then failed final rename leaves durable inflight" {
  hc_fixture_setting mv_fail_at '[2]'
  evaluate
  calls_are 1
  pending
  [[ "$output" != *'notify: confirmed'* ]] || return 1
}

@test "047 N20: visible final rename needs an adoption flush before reuse" {
  hc_fixture_setting sync_fail_at '[4]'
  evaluate
  calls_are 1
  [[ "$output" == *state_failure* ]] || return 1
  confirmed
  hc_fixture_setting sync_fail_at '[]'
  evaluate
  calls_are 1
  jq -e -s '.[-2].kind=="file" and .[-1].kind=="dir" and .[-1].rc==0' "$HC_FIX/sync-results.jsonl" >/dev/null
}

@test "047 N21: old inflight checkpoint remains uncertain after restart" {
  hc_fixture_setting mv_fail_at '[2]'
  epoch 0; evaluate
  pending
  hc_fixture_setting mv_fail_at '[]'
  epoch 1799; evaluate; calls_are 1
  epoch 1800; evaluate; calls_are 2
  confirmed
}

@test "047 N22: failed repeated adoption never uses a visible confirmation for recovery" {
  seed_confirmed
  hc_fixture_snapshot NONE
  hc_fixture_setting sync_fail_at '[1,2,3]'
  evaluate; calls_are 0
  evaluate; calls_are 0
  evaluate; calls_are 0
  jq -e -s --arg path "$STATE" '[.[]|select(.source=="product" and .tool=="sync" and .args==[$path])]|length==3' "$HC_FIX/calls.jsonl" >/dev/null
  hc_fixture_setting sync_fail_at '[]'
  evaluate; calls_are 1
  jq -e '.episode==null and .pending==null' "$STATE" >/dev/null
}

@test "047 N23: overlapping controller loses real flock and cannot write or send" {
  cat > "$HC_FIX/curl-hook" <<'SH'
touch "$HC_FIX/curl-ready"
while [ ! -f "$HC_FIX/curl-release" ]; do sleep 0.02; done
SH
  hc_fixture_spawn "$HC_FIX/first.out"
  local first=$HC_SPAWN_PID n=0
  while [ ! -f "$HC_FIX/curl-ready" ] && [ "$n" -lt 200 ]; do sleep 0.02; n=$((n+1)); done
  [ -f "$HC_FIX/curl-ready" ]
  [ -f "$STATE" ]
  cp "$STATE" "$HC_FIX/state-before"
  hc_fixture_snapshot WARN_OTHER
  evaluate
  [[ "$output" == *notify_busy* ]] || return 1
  [[ "$output" == *WARN* ]] || return 1
  cmp "$STATE" "$HC_FIX/state-before"
  touch "$HC_FIX/curl-release"
  wait "$first" || [ "$?" -eq 2 ]
  calls_are 1
  confirmed
}

@test "047 N24: absent persistence tools suspend sends without inventing health" {
  local tool
  hc_fixture_setting sync_version '"sync (BusyBox)"'
  evaluate
  calls_are 0
  [[ "$output" == *state_unavailable* ]] || return 1
  hc_fixture_setting sync_version '"sync (GNU coreutils) synthetic"'
  hc_fixture_setting sync_version_rc 1
  evaluate
  calls_are 0
  [[ "$output" == *state_unavailable* ]] || return 1
  hc_fixture_setting sync_version_rc 0
  for tool in flock sync timeout; do
    mv "$HC_BIN/$tool" "$HC_BIN/$tool.hidden"
    evaluate
    calls_are 0
    [[ "$output" == *state_unavailable* || "$output" == *budget_exhausted* ]] || return 1
    mv "$HC_BIN/$tool.hidden" "$HC_BIN/$tool"
  done
  mv "$HC_BIN/curl" "$HC_BIN/curl.hidden"
  evaluate
  calls_are 0
  [[ "$output" == *transport_unavailable* ]] || return 1
  mv "$HC_BIN/curl.hidden" "$HC_BIN/curl"
  printf '%s\n' '{"ActiveState":"inactive","ControlGroup":"/agent-test.service","InvocationID":"one","MainPID":"0"}' > "$HC_FIX/unit.json"
  mv "$HC_BIN/jq" "$HC_BIN/jq.hidden"
  run hc_fixture_cli
  local observed_status="$status" observed_output="$output"
  mv "$HC_BIN/jq.hidden" "$HC_BIN/jq"
  [ "$observed_status" -eq 2 ]
  [[ "$observed_output" == *'cannot verify login renewal'* && "$observed_output" == *state_unavailable* ]] || return 1
  calls_are 0
}

@test "047 N25: child has no fd9 and killed controller cannot strand the stable lock" {
  evaluate
  jq -e -s 'all(.[]; .fd9_open==false)' "$HC_FIX/transport.jsonl" >/dev/null
  # A real lock probe on the same stable file must succeed after the controller.
  run flock -n "$HC_WS/.state/.local-healthcheck.lock" true
  [ "$status" -eq 0 ]
  [ -f "$HC_WS/.state/.local-healthcheck.lock" ]
  hc_fixture_snapshot WARN_EXPIRY
  cat > "$HC_FIX/curl-hook" <<'SH'
printf '%s\n' "$$" > "$HC_FIX/hook-pid"
touch "$HC_FIX/transport-ready"
while [ ! -f "$HC_FIX/transport-release" ]; do sleep 0.02; done
SH
  hc_fixture_spawn "$HC_FIX/killed.out"
  local controller=$HC_SPAWN_PID n=0 child
  while [ ! -f "$HC_FIX/transport-ready" ] && [ "$n" -lt 200 ]; do sleep 0.02; n=$((n+1)); done
  [ -f "$HC_FIX/transport-ready" ]
  child=$(cat "$HC_FIX/hook-pid")
  printf '%s\n' "$child" >> "$HC_FIX/owned-pids"
  kill -KILL "$controller"
  wait "$controller" 2>/dev/null || true
  run flock -n "$HC_WS/.state/.local-healthcheck.lock" true
  local probe_status="$status"
  # Release even after a failed oracle so the test never strands its child.
  touch "$HC_FIX/transport-release"
  n=0
  while kill -0 "$child" 2>/dev/null && [ "$n" -lt 200 ]; do sleep 0.02; n=$((n+1)); done
  [ "$probe_status" -eq 0 ]
  if kill -0 "$child" 2>/dev/null; then return 1; fi
  pending
}

@test "047 N26: ack requires curl rc0 HTTP200 JSON and ok true together" {
  local key value
  for key in curl_rc curl_http curl_body; do
    case "$key" in curl_rc) value=7 ;; curl_http) value=503 ;; curl_body) value='"{\"ok\":false}"' ;; esac
    hc_fixture_setting "$key" "$value"
    evaluate
    pending
    [[ "$output" != *'notify: confirmed'* ]] || return 1
    hc_fixture_setting curl_rc 0
    hc_fixture_setting curl_http 200
    hc_fixture_setting curl_body '"{\"ok\":true}"'
    epoch "$((2000000000+1800*$(cat "$HC_FIX/curl-count")))"
  done
  hc_fixture_setting curl_body '"not JSON"'
  evaluate; pending
}

@test "047 N27: received request with lost response is not a confirmation" {
  hc_fixture_setting curl_rc 28
  evaluate
  calls_are 1
  pending
  [[ "$output" != *'notify: confirmed'* ]] || return 1
}

@test "047 N28: curl uses safe stdin config bounded flags and rejects controls" {
  evaluate
  jq -e -s 'any(.[]; .tool=="curl" and .args[0]=="-q" and .args[(.args|index("--connect-timeout"))+1]=="5" and .args[(.args|index("--max-time"))+1]=="15" and .args[(.args|index("--retry"))+1]=="0") and all(.[]; .secret_in_argv==false)' "$HC_FIX/calls.jsonl" >/dev/null
  printf '%s\n' 'NOTIFY_BOT_TOKEN=fictional-notify-token' 'NOTIFY_CHAT_ID=fictional-chat"\path' > "$HC_WS/.env"
  hc_fixture_snapshot NONE
  evaluate
  calls_are 2
  jq -e -s '.[1].escaped_chat_roundtrip' "$HC_FIX/transport.jsonl" >/dev/null
  printf '%s\t%s\n' 'NOTIFY_BOT_TOKEN="bad' 'token"' > "$HC_WS/.env"
  printf '%s\n' 'NOTIFY_CHAT_ID=fictional-chat' >> "$HC_WS/.env"
  hc_fixture_snapshot DEGRADED
  evaluate
  calls_are 2
}

@test "047 N29: fictional secrets never enter argv child env output or durable state" {
  export NOTIFY_BOT_TOKEN=fictional-notify-token NOTIFY_CHAT_ID=fictional-chat
  printf 'OTHER_SECRET=fictional-other-secret\n' >> "$HC_WS/.env"
  evaluate
  [[ "$output" != *fictional-notify-token* && "$output" != *fictional-chat* && "$output" != *fictional-other-secret* ]] || return 1
  jq -e -s 'all(.[]|select(.source=="product"); .secret_in_env==false and .secret_in_argv==false)' "$HC_FIX/calls.jsonl" >/dev/null
  jq -e -s 'all(.[]; .fictional_token and .fictional_chat and (.other_secret|not))' "$HC_FIX/transport.jsonl" >/dev/null
  if grep -F 'fictional-' "$STATE"; then return 1; fi
  local path inventory
  inventory=$(find "$HC_WS/.state" -mindepth 1 -print)
  while IFS= read -r path; do
    case "$path" in
      "$HC_WS/.state/.claude"|"$HC_WS/.state/.claude/.credentials.json"|"$STATE"|"$HC_WS/.state/.local-healthcheck.lock") ;;
      *) printf 'unexpected state artifact\n' >&2; return 1 ;;
    esac
  done <<< "$inventory"
}

@test "047 N30: strict timeout executes succeeds and kills then reaps TERM-resistant child" {
  mkdir "$HC_FIX/clock-probe"
  cat > "$HC_FIX/clock-probe/ClockJump.pm" <<'PL'
package ClockJump;
require Time::HiRes;
my $real=\&Time::HiRes::time;
my $calls=0;
no warnings qw(redefine prototype);
*Time::HiRes::time=sub () { return $real->()+(++$calls>1 ? 10 : 0) };
1;
PL
  # Simulate a wall-clock jump in this child only, without changing the host.
  run env "PERL5LIB=$HC_FIX/clock-probe" PERL5OPT=-MClockJump \
    timeout -k 0.1 1 "$HC_BASH" -c 'sleep 0.05; printf monotonic-success'
  [ "$status" -eq 0 ]
  [ "$output" = monotonic-success ]
  # The private Python must be the selected interpreter itself, not a selector
  # executable that starts a second interpreter for each spy invocation.
  run python3 -c 'import os,sys; sys.exit(0 if os.path.samefile(sys.executable,sys.argv[1]) else 1)' "$(readlink "$HC_BIN/python3")"
  [ "$status" -eq 0 ]
  run timeout --unrecognized 1 true
  [ "$status" -eq 125 ]
  run timeout -k 0.1 1 "$HC_BASH" -c 'printf success'
  [ "$status" -eq 0 ]
  [ "$output" = success ]
  run timeout -k 0.1 0.1 "$HC_BASH" -c 'trap "" TERM; printf "%s\n" "$$" > "$HC_FIX/timeout-child"; while :; do sleep 1; done' 3>&- 4>&-
  [ "$status" -eq 124 ]
  local pid
  pid=$(cat "$HC_FIX/timeout-child")
  hc_fixture_wait_gone "$pid"
  # Regression for a parent that exits on TERM before its resistant child.
  cat > "$HC_FIX/resistant-tree.pl" <<'PL'
use strict;
my $child=fork();
if (!$child) {
  $SIG{TERM}='IGNORE';
  open my $out,'>',$ARGV[0] or die;
  print $out "$$\n"; close $out;
  while (1) {sleep 1}
}
while (1) {sleep 1}
PL
  run timeout -k 0.1 0.1 perl "$HC_FIX/resistant-tree.pl" "$HC_FIX/tree-child" 3>&- 4>&-
  [ "$status" -eq 124 ]
  pid=$(cat "$HC_FIX/tree-child")
  printf '%s\n' "$pid" >> "$HC_FIX/owned-pids"
  hc_fixture_wait_gone "$pid"
  cat > "$HC_FIX/curl-hook" <<'SH'
trap '' TERM
printf '%s\n' "$$" > "$HC_FIX/transport-child"
while :; do sleep 1; done
SH
  # Exercise the product controller, not only the timeout fixture. An explicit
  # short internal deadline keeps this test fast without a public CLI knob.
  hc_fixture_setting curl_ignore_term true
  run timeout -k 0.2 8 "$HC_BASH" -c '
    source "$1"
    source "$HC_WS/scripts/lib/env_file.sh"
    hc_proc_root="$HC_PROC"
    hc_observe() { cat "$HC_FIX/snapshot.json"; }
    hc_notice_run "$HC_WS" agent-test.service 1002000
  ' _ "$HC_WS/scripts/local/agent-healthcheck-lib.sh" 3>&- 4>&-
  [ "$status" -eq 0 ]
  [[ "$output" == *'DEGRADED'* ]] || return 1
  pending
  pid=$(cat "$HC_FIX/transport-child")
  printf '%s\n' "$pid" >> "$HC_FIX/owned-pids"
  hc_fixture_wait_gone "$pid"
}

@test "047 N31: strict flush ordering and full CLI global deadline include prior costs" {
  local scratch="$HC_WS/.state/flush-test"
  printf '{}\n' > "$scratch"; chmod 600 "$scratch"
  run sync -f "$scratch"; [ "$status" -eq 97 ]
  run sync "$HC_WS/.state"; [ "$status" -eq 97 ]
  run sync "$scratch"; [ "$status" -eq 0 ]
  run sync "$HC_WS/.state"; [ "$status" -eq 0 ]
  hc_fixture_setting sync_fail_at '[5]'
  run sync "$scratch"; [ "$status" -eq 1 ]
  run sync "$HC_WS/.state"; [ "$status" -eq 97 ]
  hc_fixture_setting sync_fail_at '[]'
  rm "$scratch"
  # The full production CLI runs with a parser that consumes known monotonic
  # time per read. No service mock can renew the global deadline after config.
  cat >> "$HC_WS/scripts/lib/env_file.sh" <<'SH'
env_file_get() {
  local tick rest
  read -r tick rest < "$HC_PROC/uptime"
  tick=${tick%%.*}
  printf '%s.00 0\n' "$((tick+20))" > "$HC_PROC/uptime"
  [ -r "$2" ] || return 0
  case "$1" in NOTIFY_BOT_TOKEN) printf fictional-notify-token ;; NOTIFY_CHAT_ID) printf fictional-chat ;; esac
}
SH
  cat > "$HC_FIX/systemctl-hook" <<'SH'
printf '1060.00 0\n' > "$HC_PROC/uptime"
SH
  local configured tick rest
  for configured in yes no; do
    printf '1000.00 0\n' > "$HC_PROC/uptime"
    rm -f "$HC_FIX/calls.jsonl"
    [ "$configured" != no ] || rm "$HC_WS/.env"
    run hc_fixture_cli
    [ "$status" -eq 1 ] || return
    read -r tick rest < "$HC_PROC/uptime"
    [ "${tick%%.*}" -le 1060 ] || return
    calls_are 0 || return
    jq -e -s 'all(.[]|select(.source=="product"); .mono_ms<1060000)' "$HC_FIX/calls.jsonl" >/dev/null || return
  done
  hc_fixture_notice
  cp "$REPO_ROOT/scripts/lib/env_file.sh" "$HC_WS/scripts/lib/env_file.sh"
  rm "$HC_FIX/systemctl-hook"
  printf '%s\n' '{"ActiveState":"inactive","ControlGroup":"/agent-test.service","InvocationID":"one","MainPID":"0"}' > "$HC_FIX/unit.json"
  cat > "$HC_FIX/journalctl-hook" <<'SH'
printf '1020.00 0\n' > "$HC_PROC/uptime"
SH
  # Notice time starts after observation, and is capped at thirty seconds.
  local end
  for end in 1045 1050; do
    printf '1000.00 0\n' > "$HC_PROC/uptime"
    rm -f "$STATE" "$HC_FIX/curl-count" "$HC_FIX/calls.jsonl"
    printf 'printf "%s.00 0\\n" > "$HC_PROC/uptime"\n' "$end" > "$HC_FIX/curl-hook"
    run hc_fixture_cli
    [ "$status" -eq 2 ] || return
    calls_are 1 || return
    if [ "$end" -eq 1045 ]; then confirmed || return; else pending || return; fi
    jq -e -s 'all(.[]|select(.source=="product"); .mono_ms<1050000)' "$HC_FIX/calls.jsonl" >/dev/null || return
  done
  # Forty seconds in configuration plus observation cannot renew t0+60.
  cat >> "$HC_WS/scripts/lib/env_file.sh" <<'SH'
env_file_get() {
  local tick rest
  read -r tick rest < "$HC_PROC/uptime"
  printf '%s.00 0\n' "$((${tick%%.*}+20))" > "$HC_PROC/uptime"
  case "$1" in NOTIFY_BOT_TOKEN) printf fictional-notify-token ;; NOTIFY_CHAT_ID) printf fictional-chat ;; esac
}
SH
  printf '1000.00 0\n' > "$HC_PROC/uptime"
  printf 'printf "1045.00 0\\n" > "$HC_PROC/uptime"\n' > "$HC_FIX/journalctl-hook"
  printf 'printf "1060.00 0\\n" > "$HC_PROC/uptime"\n' > "$HC_FIX/curl-hook"
  rm -f "$STATE" "$HC_FIX/curl-count" "$HC_FIX/calls.jsonl"
  run hc_fixture_cli
  [ "$status" -eq 2 ]
  calls_are 1
  pending
  jq -e -s 'all(.[]|select(.source=="product"); .mono_ms<1060000)' "$HC_FIX/calls.jsonl" >/dev/null
  # A bounded flush consuming the last notice seconds still leaves time to
  # remove its temporary. The timeout fixture reports its actual total cap.
  cp "$REPO_ROOT/scripts/lib/env_file.sh" "$HC_WS/scripts/lib/env_file.sh"
  printf '1000.00 0\n' > "$HC_PROC/uptime"
  printf 'printf "1020.00 0\\n" > "$HC_PROC/uptime"\n' > "$HC_FIX/journalctl-hook"
  printf '[ "$1" -ne 2 ] || printf "1048.00 0\\n" > "$HC_PROC/uptime"\n' > "$HC_FIX/date-hook"
  rm -f "$HC_FIX/date-count"
  rm -f "$STATE" "$HC_FIX/curl-count" "$HC_FIX/calls.jsonl" "$HC_FIX/curl-hook"
  cat > "$HC_FIX/sync-hook" <<'SH'
[ "$2" != --version ] || exit 0
read -r cap < "$HC_FIX/timeout-budget-sync"
read -r raw rest < "$HC_PROC/uptime"
whole=${raw%%.*}; fraction=${raw#*.}; fraction=${fraction}000; fraction=${fraction:0:3}
now=$((10#$whole*1000+10#$fraction+cap))
printf '%s.%03d 0\n' "$((now/1000))" "$((now%1000))" > "$HC_PROC/uptime"
sleep 5
SH
  run hc_fixture_cli
  [ "$status" -eq 2 ]
  calls_are 0
  local file
  for file in "$HC_WS/.state"/.local-healthcheck.*; do
    [ "$file" = "$HC_WS/.state/.local-healthcheck.lock" ] || [ ! -e "$file" ] || return 1
  done
  # Expiry during journalctl must not start an external cleanup afterwards.
  rm -f "$STATE" "$HC_FIX/date-hook" "$HC_FIX/sync-hook" "$HC_FIX/curl-count" "$HC_FIX/calls.jsonl"
  printf '1000.00 0\n' > "$HC_PROC/uptime"
  cat >> "$HC_WS/scripts/lib/env_file.sh" <<'SH'
env_file_get() {
  local raw rest
  read -r raw rest < "$HC_PROC/uptime"
  printf '%s.00 0\n' "$((${raw%%.*}+20))" > "$HC_PROC/uptime"
  case "$1" in NOTIFY_BOT_TOKEN) printf fictional-notify-token ;; NOTIFY_CHAT_ID) printf fictional-chat ;; esac
}
SH
  printf 'printf "1060.00 0\\n" > "$HC_PROC/uptime"\n' > "$HC_FIX/journalctl-hook"
  run hc_fixture_cli
  [ "$status" -eq 2 ]
  calls_are 0
  jq -e -s 'all(.[]|select(.source=="product"); .mono_ms<1060000)' "$HC_FIX/calls.jsonl" >/dev/null
}

@test "047 N32: absent incomplete notification config creates no state or traffic" {
  rm "$HC_WS/.env"
  evaluate
  [ ! -e "$STATE" ]; calls_are 0
  printf 'NOTIFY_BOT_TOKEN=fictional-notify-token\n' > "$HC_WS/.env"
  evaluate
  [ ! -e "$STATE" ]; calls_are 0
}

@test "047 N33: readable legacy wins unreadable falls back and values never execute" {
  printf 'NOTIFY_BOT_TOKEN=legacy-fictional\nNOTIFY_CHAT_ID=fictional-chat\n' > "$HC_WS/.state/healthcheck-notify.env"
  evaluate
  jq -e -s '.[0].fictional_token==false' "$HC_FIX/transport.jsonl" >/dev/null
  chmod 000 "$HC_WS/.state/healthcheck-notify.env"
  hc_fixture_snapshot NONE; evaluate
  jq -e -s '.[1].fictional_token==true' "$HC_FIX/transport.jsonl" >/dev/null
  printf 'UNUSED=$(touch %s/canary)\n' "$HC_FIX" >> "$HC_WS/.env"
  hc_fixture_snapshot DEGRADED; evaluate
  [ ! -e "$HC_FIX/canary" ]
}

@test "047 N34: reenabled delivery reconciles current state without replay" {
  evaluate
  mv "$HC_WS/.env" "$HC_WS/.env.disabled"
  hc_fixture_snapshot NONE; evaluate
  hc_fixture_snapshot WARN_EXPIRY; evaluate
  calls_are 1
  mv "$HC_WS/.env.disabled" "$HC_WS/.env"
  evaluate
  calls_are 2
  [ "$(jq -r .identity "$STATE")" = WARN_EXPIRY ]
}

@test "047 N35: unexpected state and lock filesystem types suspend all sends" {
  mkdir "$STATE"
  evaluate; calls_are 0
  rmdir "$STATE"
  rm "$HC_WS/.state/.local-healthcheck.lock"
  mkdir "$HC_WS/.state/.local-healthcheck.lock"
  evaluate; calls_are 0
  rmdir "$HC_WS/.state/.local-healthcheck.lock"
  ln -s "$HC_FIX/journal" "$STATE"
  evaluate; calls_are 0
}

@test "047 N36: transport diagnostics use closed codes without changing health" {
  hc_fixture_setting curl_body '"{\"ok\":false,\"description\":\"raw external secret text\"}"'
  evaluate
  [[ "$output" == *'healthcheck: DEGRADED'* ]] || return 1
  [[ "$output" == *'notify: api_failure'* ]] || return 1
  [[ "$output" != *'raw external secret text'* ]] || return 1
  local filter before
  cat > "$HC_FIX/jq-hook" <<'SH'
if [ "$#" -eq 3 ] && [ "$3" = "$(cat "$HC_FIX/fail-filter")" ]; then exit 124; fi
SH
  for filter in .state .action .pending.kind .event_version .health; do
    rm -f "$STATE"
    before=$(cat "$HC_FIX/curl-count")
    printf '%s\n' "$filter" > "$HC_FIX/fail-filter"
    evaluate
    calls_are "$before"
    [[ "$output" == *'healthcheck: DEGRADED'* ]] || return 1
    [[ "$output" == *'notify: state_unavailable'* ]] || return 1
  done
  rm "$HC_FIX/jq-hook"
  cat > "$HC_FIX/mktemp-hook" <<'SH'
case "$*" in *'.healthcheck-response.'*) exit 1 ;; esac
SH
  rm -f "$STATE"
  evaluate
  calls_are "$before"
  [[ "$output" == *'notify: state_unavailable'* ]] || return 1
  rm "$HC_FIX/mktemp-hook"
  cat > "$HC_FIX/rm-hook" <<'SH'
case "$*" in *'.healthcheck-response.'*) exit 1 ;; esac
SH
  rm -f "$STATE"
  evaluate
  calls_are "$before"
  [[ "$output" == *'notify: state_unavailable'* ]] || return 1
}
