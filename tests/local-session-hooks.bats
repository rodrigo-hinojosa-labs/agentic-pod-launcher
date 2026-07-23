#!/usr/bin/env bats
# 022-local-session-lifecycle (US1): the two rendered boot hooks —
#   modules/local-session-exit.sh.tpl  -> scripts/local/agent-session-exit.sh  (ExecStopPost=-)
#   modules/local-session-check.sh.tpl -> scripts/local/agent-session-check.sh (ExecStartPre=-)
# Contract: specs/022-local-session-lifecycle/contracts/session-pointer-hygiene.md §2-§3.
#
# systemd is simulated exactly, and only, by (a) exporting $SERVICE_RESULT /
# $EXIT_CODE / $EXIT_STATUS and (b) invoking the script. That IS the whole
# ExecStopPost contract, so every branch is reachable on a macOS host with no
# systemd (Principle III).
#
# Both hooks must ALWAYS exit 0: the unit directives carry a '-' prefix and the
# scripts exit 0 unconditionally — belt and braces, the 021 convention.
#
# Bats hazard: a negated assertion mid-body does NOT fail a test here. Negatives
# go last as `if … grep -q …; then false; fi`.

load helper

setup() {
  setup_tmp_dir
  load_lib render
  load_lib yaml
  yaml_require_yq >/dev/null

  WS="$TMP_TEST_DIR"
  CFG="$WS/.state/.claude"
  mkdir -p "$WS/scripts/lib" "$WS/scripts/heartbeat" "$CFG/projects"
  cp "$REPO_ROOT/scripts/lib/session_pointer.sh" "$WS/scripts/lib/"

  cat > "$WS/agent.yml" << 'YML'
version: 1
agent: {name: locbot, display_name: "LocBot", role: "r", vibe: "v"}
user: {name: A, nickname: A, timezone: UTC, email: a@b.com, language: en}
deployment: {host: rpi5, workspace: WORKSPACE_PLACEHOLDER, install_service: false, claude_cli: claude, mode: local}
docker: {image_tag: "x:latest", uid: 1000, gid: 1000, base_image: "alpine:3.20"}
notifications: {channel: none}
features: {heartbeat: {enabled: true, interval: "30m", timeout: 300, retries: 1, default_prompt: "ok"}}
YML
  sed -i.bak "s#WORKSPACE_PLACEHOLDER#$WS#" "$WS/agent.yml"
  rm -f "$WS/agent.yml.bak"

  render_load_context "$WS/agent.yml" >/dev/null
  render_to_file "$REPO_ROOT/modules/local-session-exit.sh.tpl"  "$WS/agent-session-exit.sh"
  render_to_file "$REPO_ROOT/modules/local-session-check.sh.tpl" "$WS/agent-session-check.sh"
  # 024: the ExecStop hook, which runs BEFORE agent-session-exit.sh.
  render_to_file "$REPO_ROOT/modules/local-session-stop.sh.tpl"  "$WS/agent-session-stop.sh"
  chmod +x "$WS/agent-session-exit.sh" "$WS/agent-session-check.sh" "$WS/agent-session-stop.sh"

  MARKER="$WS/scripts/heartbeat/session-exit.json"
  export WS CFG MARKER
}

teardown() {
  # Restore any mode we tightened, or teardown_tmp_dir cannot clean up.
  chmod -R u+rwX "$TMP_TEST_DIR" 2>/dev/null || true
  teardown_tmp_dir
}

# Create the pointer under the naive slug for WS.
_mk_pointer() {
  local slug dir
  slug=$(printf '%s' "$WS" | tr -c 'a-zA-Z0-9' '-')
  dir="$CFG/projects/$slug"
  mkdir -p "$dir"
  printf '{"sessionId":"session_01AAA","environmentId":"env_x","source":"standalone","pid":123,"procStart":"456"}\n' \
    > "$dir/bridge-pointer.json"
  printf '%s\n' "$dir/bridge-pointer.json"
}

_write_marker() {  # _write_marker EXIT_CODE
  printf '{"schema":1,"service_result":"x","exit_code":"%s","exit_status":"0","ts":"t"}\n' "$1" > "$MARKER"
}

_write_marker_cause() {  # _write_marker_cause STOP_CAUSE  (024)
  printf '{"schema":1,"service_result":"x","exit_code":"exited","exit_status":"0","stop_cause":"%s","ts":"t"}\n' "$1" > "$MARKER"
}

# ─── T012 / S8-S10: agent-session-exit.sh (ExecStopPost) ─────────────────

@test "S8 exit-hook: stores systemd's three values verbatim with schema 1" {
  SERVICE_RESULT=success EXIT_CODE=exited EXIT_STATUS=0 run "$WS/agent-session-exit.sh"
  [ "$status" -eq 0 ]
  run cat "$MARKER"
  printf '%s' "$output" | grep -q '"schema":1'
  printf '%s' "$output" | grep -q '"service_result":"success"'
  printf '%s' "$output" | grep -q '"exit_code":"exited"'
  printf '%s' "$output" | grep -q '"exit_status":"0"'
}

@test "S8 exit-hook: a signal-killed stop is recorded as killed" {
  SERVICE_RESULT=signal EXIT_CODE=killed EXIT_STATUS=TERM run "$WS/agent-session-exit.sh"
  [ "$status" -eq 0 ]
  grep -q '"exit_code":"killed"' "$MARKER"
}

@test "S9 exit-hook: with none of the three variables set, still exits 0 and writes" {
  run env -u SERVICE_RESULT -u EXIT_CODE -u EXIT_STATUS "$WS/agent-session-exit.sh"
  [ "$status" -eq 0 ]
  [ -f "$MARKER" ]
  grep -q '"exit_code":""' "$MARKER"
}

@test "S9 exit-hook: leaves no un-mv'ed temp file behind" {
  SERVICE_RESULT=success EXIT_CODE=exited EXIT_STATUS=0 "$WS/agent-session-exit.sh"
  run ls -A "$WS/scripts/heartbeat/"
  [ "$status" -eq 0 ]
  [ "$output" = "session-exit.json" ]
}

@test "S10 exit-hook: an unwritable state dir still exits 0 and stays silent on stdout" {
  chmod 0500 "$WS/scripts/heartbeat"
  SERVICE_RESULT=success EXIT_CODE=exited EXIT_STATUS=0 run "$WS/agent-session-exit.sh"
  chmod 0700 "$WS/scripts/heartbeat"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

# ─── T013 / S1-S3: agent-session-check.sh, the core decision ─────────────

@test "S1 check-hook: cause=session-ended + pointer → pointer retired, content preserved" {
  local p
  p=$(_mk_pointer)
  # 024: a bare exit_code no longer decides. The cause does.
  _write_marker_cause session-ended
  run "$WS/agent-session-check.sh"
  [ "$status" -eq 0 ]
  [ -f "$(dirname "$p")/bridge-pointer.retired.json" ]
  grep -q 'session_01AAA' "$(dirname "$p")/bridge-pointer.retired.json"
  if [ -f "$p" ]; then false; fi
}

@test "S2 check-hook: marker=killed + pointer → pointer untouched, byte-identical" {
  local p before
  p=$(_mk_pointer)
  before="$TMP_TEST_DIR/before.json"
  cp "$p" "$before"
  _write_marker killed
  run "$WS/agent-session-check.sh"
  [ "$status" -eq 0 ]
  [ -f "$p" ]
  cmp -s "$before" "$p"
  # Continuity preserved — measured twice on live hardware. FR-014 / SC-009.
  if [ -f "$(dirname "$p")/bridge-pointer.retired.json" ]; then false; fi
}

@test "S3/024-C4 check-hook: no marker + pointer → KEPT (indeterminacy must not destroy work)" {
  # POLICY INVERSION, deliberate (024 FR-004). Under 022 this retired: an
  # unknown cause was resolved in favour of announcing a fresh session. The
  # hardware gate showed what that costs — because `killed` almost never occurs
  # with a process that traps SIGTERM, "unknown" was the common path, and every
  # restart silently destroyed the operator's open conversation.
  # Over-keeping costs a dead conversation they can SEE and fix with a restart;
  # over-retiring costs their work with no warning at all.
  local p
  p=$(_mk_pointer)
  run "$WS/agent-session-check.sh"
  [ "$status" -eq 0 ]
  [ -f "$p" ]
  if [ -f "$(dirname "$p")/bridge-pointer.retired.json" ]; then false; fi
}

@test "S4/024-C5 check-hook: a truncated marker is indeterminate → KEPT, never a crash" {
  # Same policy inversion as S3. The "never a crash" half is unchanged.
  local p
  p=$(_mk_pointer)
  printf '{"schema":1,"exit_c' > "$MARKER"
  run "$WS/agent-session-check.sh"
  [ "$status" -eq 0 ]
  [ -f "$p" ]
  if printf '%s' "$output" | grep -qi 'syntax error'; then false; fi
}

# ─── T014 / S5, S6, S11, S14: the degradation branches ───────────────────

@test "S5 check-hook: no pointer at all → exit 0, nothing created, no WARN" {
  _write_marker exited
  run "$WS/agent-session-check.sh"
  [ "$status" -eq 0 ]
  # A freshly scaffolded agent that has never logged in must never look broken.
  run bash -c "find '$CFG/projects' -type f | wc -l | tr -d ' '"
  [ "$output" = "0" ]
  if printf '%s' "$output" | grep -q 'WARN'; then false; fi
}

@test "S6 check-hook: running twice is idempotent" {
  local p
  p=$(_mk_pointer)
  _write_marker_cause session-ended
  run "$WS/agent-session-check.sh"
  [ "$status" -eq 0 ]
  run "$WS/agent-session-check.sh"
  [ "$status" -eq 0 ]
  # Still exactly one retired file, still no live pointer.
  run bash -c "ls '$(dirname "$p")' | grep -c retired"
  [ "$output" = "1" ]
}

@test "S11 check-hook: an unwritable pointer dir → exit 0, WARN, pointer intact" {
  local p d
  p=$(_mk_pointer)
  d=$(dirname "$p")
  # 024: reaching the retire branch now requires an explicit cause. Under 022 a
  # bare `exited` meant retire; today it means "cannot determine" => keep, so
  # feeding it here would never attempt the rename this test is about.
  _write_marker_cause session-ended
  chmod 0500 "$d"
  run "$WS/agent-session-check.sh"
  chmod 0700 "$d"
  [ "$status" -eq 0 ]
  [ -f "$p" ]
  printf '%s' "$output" | grep -q 'WARN'
}

@test "S14 check-hook: two candidate pointers → exit 0, WARN, neither touched" {
  mkdir -p "$CFG/projects/-cand-a" "$CFG/projects/-cand-b"
  printf '{"a":1}\n' > "$CFG/projects/-cand-a/bridge-pointer.json"
  printf '{"b":2}\n' > "$CFG/projects/-cand-b/bridge-pointer.json"
  _write_marker exited
  run "$WS/agent-session-check.sh"
  [ "$status" -eq 0 ]
  [ -f "$CFG/projects/-cand-a/bridge-pointer.json" ]
  [ -f "$CFG/projects/-cand-b/bridge-pointer.json" ]
  printf '%s' "$output" | grep -q 'WARN'
  printf '%s' "$output" | grep -q 'cannot determine'
}

@test "check-hook: a missing shared lib degrades to exit 0, never a hard failure" {
  rm -f "$WS/scripts/lib/session_pointer.sh"
  _write_marker exited
  run "$WS/agent-session-check.sh"
  [ "$status" -eq 0 ]
}

# ─── T015 / S15: the split-brain guard ───────────────────────────────────

@test "S15 check-hook: never creates a bridge-pointer.json that did not exist" {
  # Claude Code exits with a split-brain error if it re-reads a pointer whose
  # pid is not its own, so this hook may only ever MOVE the file.
  _write_marker exited
  "$WS/agent-session-check.sh" >/dev/null 2>&1
  _write_marker killed
  "$WS/agent-session-check.sh" >/dev/null 2>&1
  rm -f "$MARKER"
  "$WS/agent-session-check.sh" >/dev/null 2>&1
  run bash -c "find '$CFG/projects' -name 'bridge-pointer.json' | wc -l | tr -d ' '"
  [ "$output" = "0" ]
}

@test "S15 check-hook: with a live pointer and marker=killed, still creates nothing new" {
  local p
  p=$(_mk_pointer)
  _write_marker killed
  "$WS/agent-session-check.sh" >/dev/null 2>&1
  run bash -c "find '$CFG/projects' -name 'bridge-pointer*.json' | wc -l | tr -d ' '"
  [ "$output" = "1" ]
  [ -f "$p" ]
}

# ─── Round trip: the exit hook feeds the check hook ──────────────────────

@test "round-trip: a killed stop then a start preserves the pointer" {
  local p before
  p=$(_mk_pointer)
  before="$TMP_TEST_DIR/before.json"
  cp "$p" "$before"
  SERVICE_RESULT=signal EXIT_CODE=killed EXIT_STATUS=TERM "$WS/agent-session-exit.sh"
  run "$WS/agent-session-check.sh"
  [ "$status" -eq 0 ]
  cmp -s "$before" "$p"
}

@test "round-trip: a self-exit then a start retires the pointer" {
  local p
  p=$(_mk_pointer)
  # 024: "the process exited on its own" is now declared by the ExecStop hook,
  # which systemd runs first. ExecStopPost alone no longer implies it — that is
  # precisely the conflation that made a restart destroy live conversations.
  SERVICE_RESULT=success EXIT_CODE=exited EXIT_STATUS=0 "$WS/agent-session-stop.sh"
  SERVICE_RESULT=success EXIT_CODE=exited EXIT_STATUS=0 "$WS/agent-session-exit.sh"
  run "$WS/agent-session-check.sh"
  [ "$status" -eq 0 ]
  if [ -f "$p" ]; then false; fi
}

@test "round-trip: the marker is consumed, so a second start is indeterminate" {
  _mk_pointer >/dev/null
  SERVICE_RESULT=signal EXIT_CODE=killed EXIT_STATUS=TERM "$WS/agent-session-exit.sh"
  "$WS/agent-session-check.sh" >/dev/null 2>&1
  # The marker must be gone: a stale one would let an old verdict rule a
  # future start.
  if [ -f "$MARKER" ]; then false; fi
}

# ─── 024-fix-session-restart-retire ─────────────────────────────────────────
# The third hook: modules/local-session-stop.sh.tpl -> agent-session-stop.sh (ExecStop=-)
#
# systemd is simulated exactly as above — by exporting the variables it exports
# and invoking the script. The values below are the MEASURED ones (contract §1.2,
# 15/15): inside ExecStop, $EXIT_CODE is EMPTY when systemd initiates the stop
# and POPULATED when the process had already exited on its own.

@test "024/C1 stop-hook: an empty EXIT_CODE (systemd restart) records cause=external" {
  SERVICE_RESULT=success run env -u EXIT_CODE -u EXIT_STATUS "$WS/agent-session-stop.sh"
  [ "$status" -eq 0 ]
  grep -q '"stop_cause":"external"' "$MARKER"
}

@test "024/C2 stop-hook: a populated EXIT_CODE (the session ended) records cause=session-ended" {
  SERVICE_RESULT=success EXIT_CODE=exited EXIT_STATUS=0 run "$WS/agent-session-stop.sh"
  [ "$status" -eq 0 ]
  grep -q '"stop_cause":"session-ended"' "$MARKER"
}

@test "024 stop-hook: always exits 0, even with an unwritable state dir" {
  chmod a-w "$WS/scripts/heartbeat"
  SERVICE_RESULT=success run env -u EXIT_CODE "$WS/agent-session-stop.sh"
  chmod u+w "$WS/scripts/heartbeat"
  [ "$status" -eq 0 ]
}

@test "024/C1 restart flow: a systemd-initiated restart KEEPS a live session pointer" {
  # The measured defect, end to end. Before 024 this retired the pointer and
  # killed the operator's open conversation.
  ptr=$(_mk_pointer)
  SERVICE_RESULT=success env -u EXIT_CODE -u EXIT_STATUS "$WS/agent-session-stop.sh"
  SERVICE_RESULT=success EXIT_CODE=exited EXIT_STATUS=0 "$WS/agent-session-exit.sh"
  CLAUDE_CONFIG_DIR="$CFG" run "$WS/agent-session-check.sh"
  [ "$status" -eq 0 ]
  [ -f "$ptr" ]
  if [ -f "$(dirname "$ptr")/bridge-pointer.retired.json" ]; then false; fi
}

@test "024/C2 session-ended flow: a session that ended on its own RETIRES the pointer" {
  ptr=$(_mk_pointer)
  SERVICE_RESULT=success EXIT_CODE=exited EXIT_STATUS=0 "$WS/agent-session-stop.sh"
  SERVICE_RESULT=success EXIT_CODE=exited EXIT_STATUS=0 "$WS/agent-session-exit.sh"
  CLAUDE_CONFIG_DIR="$CFG" run "$WS/agent-session-check.sh"
  [ "$status" -eq 0 ]
  [ -f "$(dirname "$ptr")/bridge-pointer.retired.json" ]
  if [ -f "$ptr" ]; then false; fi
}

@test "024/C3 failure flow: exiting alone with a failure code RETIRES (systemd skips ExecStop)" {
  # MEASURED: exiting alone with code 3 makes systemd skip ExecStop entirely,
  # so no stop_cause is ever written and service_result=exit-code is the signal.
  ptr=$(_mk_pointer)
  SERVICE_RESULT=exit-code EXIT_CODE=exited EXIT_STATUS=3 "$WS/agent-session-exit.sh"
  CLAUDE_CONFIG_DIR="$CFG" run "$WS/agent-session-check.sh"
  [ "$status" -eq 0 ]
  [ -f "$(dirname "$ptr")/bridge-pointer.retired.json" ]
}

@test "024/C9 old unit: no ExecStop hook at all (upgrade half-applied) KEEPS the pointer" {
  # An installed unit that predates 024 never invokes the stop hook. It must
  # degrade to keeping, never to destroying a conversation.
  ptr=$(_mk_pointer)
  SERVICE_RESULT=success EXIT_CODE=exited EXIT_STATUS=0 "$WS/agent-session-exit.sh"
  CLAUDE_CONFIG_DIR="$CFG" run "$WS/agent-session-check.sh"
  [ "$status" -eq 0 ]
  [ -f "$ptr" ]
}

@test "024/C10 race: the second start sees no marker and KEEPS the pointer" {
  ptr=$(_mk_pointer)
  SERVICE_RESULT=success env -u EXIT_CODE "$WS/agent-session-stop.sh"
  SERVICE_RESULT=success EXIT_CODE=exited EXIT_STATUS=0 "$WS/agent-session-exit.sh"
  CLAUDE_CONFIG_DIR="$CFG" "$WS/agent-session-check.sh"   # winner consumes
  CLAUDE_CONFIG_DIR="$CFG" run "$WS/agent-session-check.sh"  # loser
  [ "$status" -eq 0 ]
  [ -f "$ptr" ]
}
