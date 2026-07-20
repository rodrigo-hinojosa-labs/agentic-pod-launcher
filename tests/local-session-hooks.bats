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
  chmod +x "$WS/agent-session-exit.sh" "$WS/agent-session-check.sh"

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

@test "S1 check-hook: marker=exited + pointer → pointer retired, content preserved" {
  local p
  p=$(_mk_pointer)
  _write_marker exited
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

@test "S3 check-hook: no marker + pointer → retired (indeterminacy favours availability)" {
  local p
  p=$(_mk_pointer)
  run "$WS/agent-session-check.sh"
  [ "$status" -eq 0 ]
  [ -f "$(dirname "$p")/bridge-pointer.retired.json" ]
  if [ -f "$p" ]; then false; fi
}

@test "S4 check-hook: a truncated marker is treated as indeterminate, never a crash" {
  local p
  p=$(_mk_pointer)
  printf '{"schema":1,"exit_c' > "$MARKER"
  run "$WS/agent-session-check.sh"
  [ "$status" -eq 0 ]
  [ -f "$(dirname "$p")/bridge-pointer.retired.json" ]
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

@test "S6 check-hook: running twice is idempotent (FR-004)" {
  local p
  p=$(_mk_pointer)
  _write_marker exited
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
  _write_marker exited
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
