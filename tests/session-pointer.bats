#!/usr/bin/env bats
# 022-local-session-lifecycle: scripts/lib/session_pointer.sh — the shared
# source of truth for the boot hook AND the doctor. Contract:
# specs/022-local-session-lifecycle/contracts/session-pointer-hygiene.md §1.
#
# Host-runnable, no systemd. systemd is nothing more than three exported
# variables ($SERVICE_RESULT/$EXIT_CODE/$EXIT_STATUS) plus an invocation, so
# every branch of the decision is reachable from a plain shell.
#
# Bats hazard (see tests/agentctl-local.bats:407): a negated `! [[ … ]]` or
# `!`-pipeline mid-body does NOT fail a test here. Load-bearing negatives go
# last as `if … grep -q …; then false; fi`, or use `run` + status.

load helper

setup() {
  setup_tmp_dir
  load_lib session_pointer
  # A workspace + a Claude config dir shaped like the real one
  # (modules/remote-control.env.tpl:6 → <ws>/.state/.claude).
  WS="$TMP_TEST_DIR/ws"
  CFG="$WS/.state/.claude"
  mkdir -p "$WS/scripts/heartbeat" "$CFG/projects"
  export WS CFG
}

teardown() { teardown_tmp_dir; }

# Helper: create the pointer for WS under its naive slug.
_mk_pointer() {  # _mk_pointer [SESSION_ID]
  local slug dir
  slug=$(session_pointer_slug "$WS")
  dir="$CFG/projects/$slug"
  mkdir -p "$dir"
  printf '{"sessionId":"%s","environmentId":"env_x","source":"standalone","pid":123,"procStart":"456"}\n' \
    "${1:-session_01AAA}" > "$dir/bridge-pointer.json"
  printf '%s\n' "$dir/bridge-pointer.json"
}

# ─── T004 / S12: session_pointer_slug ────────────────────────────────────

@test "S12 slug: every non-alphanumeric becomes a hyphen, no trailing hyphen" {
  run session_pointer_slug '/tmp/a b.c_d/ws-1'
  [ "$status" -eq 0 ]
  # Exact string. The measured trap: `echo | tr -c` turns the trailing newline
  # into an extra '-' (contract §1.1). Input must be fed with printf '%s'.
  [ "$output" = "-tmp-a-b-c-d-ws-1" ]
}

@test "S12 slug: a plain path maps like the vendor's FS() does" {
  run session_pointer_slug '/home/op/agents/locbot'
  [ "$status" -eq 0 ]
  [ "$output" = "-home-op-agents-locbot" ]
}

@test "slug: dots and underscores are replaced, not preserved" {
  run session_pointer_slug '/a/b.c/d_e'
  [ "$status" -eq 0 ]
  [ "$output" = "-a-b-c-d-e" ]
}

# ─── T005: session_pointer_path — the rc 0 / 1 / 2 trichotomy ────────────

@test "path: pointer present under the naive slug → rc 0 and the path" {
  local expected
  expected=$(_mk_pointer)
  run session_pointer_path "$WS" "$CFG"
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}

@test "path: slug dir exists but no pointer → rc 2 (healthy, no session yet)" {
  mkdir -p "$CFG/projects/$(session_pointer_slug "$WS")"
  run session_pointer_path "$WS" "$CFG"
  [ "$status" -eq 2 ]
  [ "$output" = "" ]
}

@test "path: empty CLAUDE_CONFIG_DIR → rc 1 (cannot determine), never rc 2" {
  # Step 1 must come FIRST. If it were last it would be unreachable: an absent
  # config dir makes the glob match 0 and return 2 — the false green FR-006
  # forbids (contract §1.2).
  run session_pointer_path "$WS" ""
  [ "$status" -eq 1 ]
}

@test "path: a CLAUDE_CONFIG_DIR that does not exist → rc 1" {
  run session_pointer_path "$WS" "$TMP_TEST_DIR/no-such-config"
  [ "$status" -eq 1 ]
}

@test "path: a valid config dir whose projects/ does not exist yet → rc 2, not rc 1" {
  # Claude Code creates projects/ only once a session runs, so a freshly
  # logged-in agent legitimately has none. Calling that "cannot determine" made
  # the doctor warn on every healthy fresh workspace (caught by the 021
  # regression tests). It is "no session yet" — FR-006.
  local fresh="$TMP_TEST_DIR/fresh-cfg"
  mkdir -p "$fresh"
  run session_pointer_path "$WS" "$fresh"
  [ "$status" -eq 2 ]
}

@test "S13 path: slug dir absent, exactly one pointer elsewhere → rc 0, that path" {
  # Stands in for a workspace path over 200 chars, where the vendor truncates
  # and appends a proprietary base-36 hash we cannot reproduce.
  mkdir -p "$CFG/projects/-some-other-truncated-slug"
  printf '{}\n' > "$CFG/projects/-some-other-truncated-slug/bridge-pointer.json"
  run session_pointer_path "$WS" "$CFG"
  [ "$status" -eq 0 ]
  [ "$output" = "$CFG/projects/-some-other-truncated-slug/bridge-pointer.json" ]
}

@test "S14 path: slug dir absent, two candidate pointers → rc 1, never guess" {
  mkdir -p "$CFG/projects/-cand-a" "$CFG/projects/-cand-b"
  printf '{}\n' > "$CFG/projects/-cand-a/bridge-pointer.json"
  printf '{}\n' > "$CFG/projects/-cand-b/bridge-pointer.json"
  run session_pointer_path "$WS" "$CFG"
  [ "$status" -eq 1 ]
  [ "$output" = "" ]
}

@test "path: slug dir absent and zero pointers anywhere → rc 2" {
  run session_pointer_path "$WS" "$CFG"
  [ "$status" -eq 2 ]
}

# ─── T006: session_decide — the whole truth table (contract §1.8) ────────

@test "S-decide: pointer absent → noop, whatever the marker says" {
  run session_decide exited absent
  [ "$status" -eq 0 ]
  [ "$output" = "noop" ]
  run session_decide killed absent
  [ "$output" = "noop" ]
  run session_decide "" absent
  [ "$output" = "noop" ]
}

@test "S-decide: exited + present → retire (the session ended)" {
  run session_decide exited present
  [ "$status" -eq 0 ]
  [ "$output" = "retire" ]
}

@test "S-decide: killed + present → keep (continuity, measured on hardware)" {
  # systemd killed it (restart/reboot/stop); the server-side session can still
  # be alive and the vendor's reuse restores the same client link. Measured
  # twice on mclaren 2026-07-18. FR-014 / SC-009.
  run session_decide killed present
  [ "$status" -eq 0 ]
  [ "$output" = "keep" ]
}

@test "S-decide: dumped + present → retire" {
  run session_decide dumped present
  [ "$output" = "retire" ]
}

@test "S-decide: empty or unknown marker + present → retire (availability wins)" {
  run session_decide "" present
  [ "$output" = "retire" ]
  run session_decide something-new present
  [ "$output" = "retire" ]
}

@test "S-decide: pointer unknown → noop, whatever the marker says" {
  # The deliberate asymmetry: not knowing WHY it died means clear (cost = a new
  # link); not knowing WHICH FILE means touch nothing (cost = corrupting
  # another workspace's state).
  run session_decide exited unknown
  [ "$output" = "noop" ]
  run session_decide killed unknown
  [ "$output" = "noop" ]
  run session_decide "" unknown
  [ "$output" = "noop" ]
}

# ─── T007: the exit marker — write / read / consume ──────────────────────

@test "marker path: is under scripts/heartbeat, never under .state" {
  run session_exit_marker_path "$WS"
  [ "$status" -eq 0 ]
  [ "$output" = "$WS/scripts/heartbeat/session-exit.json" ]
  # Guardrail: backup_identity.sh:72,152-157 encrypts paths under .state and
  # would start pushing this to the fork.
  if printf '%s' "$output" | grep -q '/\.state/'; then false; fi
}

@test "S8 marker: the three systemd values are stored verbatim with schema 1" {
  session_exit_marker_write "$WS" success exited 0
  run cat "$WS/scripts/heartbeat/session-exit.json"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q '"schema":1'
  printf '%s' "$output" | grep -q '"service_result":"success"'
  printf '%s' "$output" | grep -q '"exit_code":"exited"'
  printf '%s' "$output" | grep -q '"exit_status":"0"'
}

@test "S8 marker: round-trips through read" {
  session_exit_marker_write "$WS" success exited 0
  run session_exit_marker_read "$WS"
  [ "$status" -eq 0 ]
  [ "$output" = "exited" ]
}

@test "S8 marker: killed is read back as killed" {
  session_exit_marker_write "$WS" signal killed 15
  run session_exit_marker_read "$WS"
  [ "$status" -eq 0 ]
  [ "$output" = "killed" ]
}

@test "S9 marker: all-empty inputs still write a valid marker, exit 0" {
  run session_exit_marker_write "$WS" "" "" ""
  [ "$status" -eq 0 ]
  [ -f "$WS/scripts/heartbeat/session-exit.json" ]
  run cat "$WS/scripts/heartbeat/session-exit.json"
  printf '%s' "$output" | grep -q '"exit_code":""'
}

@test "S9 marker: no un-mv'ed temp file is left behind" {
  session_exit_marker_write "$WS" "" "" ""
  run ls "$WS/scripts/heartbeat/"
  [ "$status" -eq 0 ]
  [ "$output" = "session-exit.json" ]
}

@test "S4 marker: a truncated marker reads as rc 1, with no shell parse noise" {
  printf '{"schema":1,"exit_c' > "$WS/scripts/heartbeat/session-exit.json"
  run session_exit_marker_read "$WS"
  [ "$status" -eq 1 ]
  [ "$output" = "" ]
}

@test "marker: an absent marker reads as rc 1" {
  run session_exit_marker_read "$WS"
  [ "$status" -eq 1 ]
}

@test "marker: an unrecognized shape reads as rc 1, never a crash" {
  printf 'not json at all\n' > "$WS/scripts/heartbeat/session-exit.json"
  run session_exit_marker_read "$WS"
  [ "$status" -eq 1 ]
}

@test "S6 marker: consume returns the value and removes the file" {
  session_exit_marker_write "$WS" success exited 0
  run session_exit_marker_consume "$WS"
  [ "$status" -eq 0 ]
  [ "$output" = "exited" ]
  if [ -f "$WS/scripts/heartbeat/session-exit.json" ]; then false; fi
}

@test "S6 marker: a second consume reports rc 1 (idempotent, FR-004)" {
  session_exit_marker_write "$WS" success exited 0
  session_exit_marker_consume "$WS" >/dev/null
  run session_exit_marker_consume "$WS"
  [ "$status" -eq 1 ]
}

@test "marker: consume leaves no private temp file behind" {
  session_exit_marker_write "$WS" success exited 0
  session_exit_marker_consume "$WS" >/dev/null
  run ls -A "$WS/scripts/heartbeat/"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

# ─── T008 / S7: session_pointer_retire ───────────────────────────────────

@test "retire: renames the pointer to the fixed retired name" {
  local p
  p=$(_mk_pointer session_01KEEPME)
  run session_pointer_retire "$p"
  [ "$status" -eq 0 ]
  [ -f "$(dirname "$p")/bridge-pointer.retired.json" ]
  grep -q 'session_01KEEPME' "$(dirname "$p")/bridge-pointer.retired.json"
  if [ -f "$p" ]; then false; fi
}

@test "S7 retire: an existing retired file is overwritten, never multiplied" {
  local p d
  p=$(_mk_pointer session_01NEW)
  d=$(dirname "$p")
  printf '{"sessionId":"session_01OLD"}\n' > "$d/bridge-pointer.retired.json"
  run session_pointer_retire "$p"
  [ "$status" -eq 0 ]
  # Exactly one retired file, holding the NEW content.
  run bash -c "ls '$d' | grep -c 'retired'"
  [ "$output" = "1" ]
  grep -q 'session_01NEW' "$d/bridge-pointer.retired.json"
}

@test "retire: a missing pointer is rc 1, not a crash" {
  run session_pointer_retire "$CFG/projects/nope/bridge-pointer.json"
  [ "$status" -eq 1 ]
}

@test "S11 retire: an unwritable directory is rc 1 and leaves the pointer intact" {
  local p d
  p=$(_mk_pointer)
  d=$(dirname "$p")
  chmod 0500 "$d"
  run session_pointer_retire "$p"
  chmod 0700 "$d"
  [ "$status" -eq 1 ]
  [ -f "$p" ]
}

# ─── T009: sourcing has no side effects (Principle III) ──────────────────

@test "lib: sourcing under set -u produces no output and creates no file" {
  run bash -c "set -u; cd '$TMP_TEST_DIR'; . '$REPO_ROOT/scripts/lib/session_pointer.sh'; echo READY"
  [ "$status" -eq 0 ]
  [ "$output" = "READY" ]
}

@test "lib: never executes file content (no source/eval over untrusted input)" {
  # The pointer and the marker can arrive from a REMOTE origin: 021 established
  # this when --restore-from-fork began decrypting a .env.age into the
  # workspace. Same rule applies here (scripts/lib/env_file.sh:5-10).
  #
  # Comment lines are stripped first: this asserts something about CODE, and the
  # header prose legitimately discusses sourcing. Also catches `. file`.
  run bash -c "grep -vE '^[[:space:]]*#' '$REPO_ROOT/scripts/lib/session_pointer.sh' \
    | grep -nE '(^|[^a-zA-Z_.])(eval|source)[[:space:]]|^[[:space:]]*\\.[[:space:]]'"
  [ "$status" -ne 0 ]
}

# ─── 024-fix-session-restart-retire ─────────────────────────────────────────
# Oracle: specs/024-fix-session-restart-retire/contracts/session-stop-classification.md §3.1
#
# Every value fed to session_decide below was MEASURED against real systemd
# (research.md R2, 5 scenarios x 3 repetitions = 15/15), not chosen by hand.
# That distinction is the whole reason the 022 defect survived a green suite:
# its tests asserted that the rule implemented what the author believed, not
# that what the author believed was true.

@test "024/C1 session_decide keeps the pointer when systemd initiated the stop (restart)" {
  # MEASURED: within ExecStop, systemctl restart leaves EXIT_CODE empty because
  # systemd runs ExecStop BEFORE killing the process. This is the regression
  # 024 fixes: 022 read exit_code from ExecStopPost, which says "exited" here
  # AND when the session ended on its own.
  run session_decide_cause external present
  [ "$status" -eq 0 ]
  [ "$output" = "keep" ]
}

@test "024/C2 session_decide retires the pointer when the session ended on its own" {
  run session_decide_cause session-ended present
  [ "$status" -eq 0 ]
  [ "$output" = "retire" ]
}

@test "024/C3 session_decide retires when the process exited on its own with a failure" {
  # MEASURED: exiting alone with code 3 makes systemd SKIP ExecStop entirely,
  # so there is no stop_cause; service_result=exit-code is what remains.
  run session_decide_cause exit-code-failure present
  [ "$status" -eq 0 ]
  [ "$output" = "retire" ]
}

@test "024/C4 session_decide keeps the pointer when the cause is absent (conservative default)" {
  # FR-004. This is the OPPOSITE of the pre-024 default and is the heart of the
  # feature: over-keeping costs a dead conversation the operator can SEE and
  # fix with a restart; over-retiring costs their work with no warning.
  run session_decide_cause "" present
  [ "$status" -eq 0 ]
  [ "$output" = "keep" ]
}

@test "024/C6 session_decide keeps the pointer on an unknown cause value" {
  run session_decide_cause some-future-systemd-token present
  [ "$status" -eq 0 ]
  [ "$output" = "keep" ]
}

@test "024/C7 session_decide is noop when there is no pointer" {
  run session_decide_cause session-ended absent
  [ "$status" -eq 0 ]
  [ "$output" = "noop" ]
}

@test "024/C8 session_decide is noop when the pointer path is unknown" {
  run session_decide_cause external unknown
  [ "$status" -eq 0 ]
  [ "$output" = "noop" ]
}

@test "024/C9 session_decide keeps the pointer for a unit that predates ExecStop" {
  # Backward compatibility: an installed unit without the ExecStop directive
  # never writes stop_cause. A half-applied upgrade must degrade to keeping.
  run session_decide_cause "" present
  [ "$status" -eq 0 ]
  [ "$output" = "keep" ]
}

@test "024 marker: stop_cause is read back when present" {
  session_exit_marker_write "$WS" success exited 0 external
  run session_exit_marker_read_cause "$WS"
  [ "$status" -eq 0 ]
  [ "$output" = "external" ]
}

@test "024 marker: an absent stop_cause reads as rc 1, never as an empty valid value" {
  # The pre-024 writer produced markers with no stop_cause at all. Reading one
  # must say "cannot determine" (rc 1), which C4 then resolves as keep.
  session_exit_marker_write "$WS" success exited 0
  run session_exit_marker_read_cause "$WS"
  [ "$status" -eq 1 ]
}

@test "024 marker: a truncated stop_cause reads as rc 1" {
  printf '{"schema":1,"service_result":"success","stop_cause":"exte' \
    > "$WS/scripts/heartbeat/session-exit.json"
  run session_exit_marker_read_cause "$WS"
  [ "$status" -eq 1 ]
}

@test "024 marker: ExecStopPost merges its fields and PRESERVES the cause ExecStop wrote" {
  # The load-bearing invariant of the single-marker design: two writers, one
  # file. If ExecStopPost overwrote the file wholesale, the cause would be lost
  # and C1 would silently regress to retiring live sessions.
  session_exit_marker_write "$WS" "" "" "" external          # ExecStop first
  session_exit_marker_write "$WS" success exited 0           # then ExecStopPost
  run session_exit_marker_read_cause "$WS"
  [ "$status" -eq 0 ]
  [ "$output" = "external" ]
  run session_exit_marker_read "$WS"
  [ "$status" -eq 0 ]
  [ "$output" = "exited" ]
}

@test "024 marker: consume returns the cause and removes the file exactly once" {
  session_exit_marker_write "$WS" success exited 0 session-ended
  run session_exit_marker_consume_cause "$WS"
  [ "$status" -eq 0 ]
  [ "$output" = "session-ended" ]
  run session_exit_marker_consume_cause "$WS"
  [ "$status" -eq 1 ]
}
