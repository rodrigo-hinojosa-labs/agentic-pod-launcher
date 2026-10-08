#!/usr/bin/env bats
# 039-fix-nightly-e2e-sigpipe: oracle for the CI workflows.
#
# Contracts: specs/039-fix-nightly-e2e-sigpipe/contracts/workflow-step-oracle.md
# (WSO: O1-O5 and R1-R3) and contracts/suite-step.md (SS: S1-S6).
#
# The nightly docker-e2e job died on every night measured in its "Verify deps +
# docker" step: `docker info | head -10` under `set -o pipefail` -> head closes the pipe
# after 10 lines, docker keeps writing, takes SIGPIPE and pipefail hands the
# step a 141 BEFORE the e2e suite starts. Nothing in the host suite could see it.
# This file runs the REAL `run:` text of a workflow step (extracted with yq, not
# copied) under `bash -e` against a fake `docker`, and sweeps every workflow for
# the pattern. A check that cannot fail is not evidence, so the harness proves
# itself: O2 runs the same mechanism on a frozen copy of the defective step and
# demands the 141.
#
# Rules this file lives by (it is the code that enforces them):
#   - bash 3.2 and 5.x: no mapfile, no associative arrays, no ${v,,}.
#   - never `producer | head` / `producer | grep -q`: assertions on $output use
#     case/grep on a here-string, never a pipe that can close early.
#   - a negative assertion is `_lacks` or `run ...; [ "$status" -ne 0 ]`, never
#     an intermediate `!`, which bats does not turn into a failure.

load helper

# `run -N` (an expected exit status) needs bats 1.5; CI installs 1.11.
bats_require_minimum_version 1.5.0

WF="$REPO_ROOT/.github/workflows"
FIX="$REPO_ROOT/tests/fixtures/ci"

setup() {
  setup_tmp_dir
  # The directory the extracted steps run in: the suite step globs tests/*.bats
  # relative to it, so it holds one e2e-looking file the glob must take and one
  # file it must not (SS section 7).
  mkdir -p "$TMP_TEST_DIR/run/tests"
  : > "$TMP_TEST_DIR/run/tests/docker-e2e-x.bats"
  : > "$TMP_TEST_DIR/run/tests/other.bats"
  _make_stubs "$TMP_TEST_DIR/stubs"
}
teardown() { teardown_tmp_dir; }

# ── harness ──────────────────────────────────────────────────────────────────

# _has TEXT NEEDLE / _lacks TEXT NEEDLE: substring assertions with no pipe.
_has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
_lacks() { ! _has "$1" "$2"; }

# _extract_run FILE JOB NAME: print the `run:` text of the step called NAME in
# job JOB. The step must match exactly once and have text, or this fails with a
# message that says why: an oracle that cannot find its subject must not pass.
# Always uses the normal PATH (never the stub directory).
_extract_run() {
  local file="$1" job="$2" name="$3" n out
  n=$(NAME="$name" yq ".jobs.${job}.steps | map(select(.name == strenv(NAME))) | length" "$file") || return 1
  if [ "$n" != "1" ]; then
    echo "_extract_run: step '$name' matched $n times in $(basename "$file") job '$job' (expected exactly 1)" >&2
    return 1
  fi
  out=$(NAME="$name" yq ".jobs.${job}.steps[] | select(.name == strenv(NAME)) | .run" "$file") || return 1
  if [ -z "$out" ] || [ "$out" = "null" ]; then
    echo "_extract_run: step '$name' in $(basename "$file") has no run: text" >&2
    return 1
  fi
  printf '%s\n' "$out"
}

# _extract_env FILE JOB NAME VAR: print the value of VAR in the step's env map.
_extract_env() {
  NAME="$3" yq ".jobs.${2}.steps[] | select(.name == strenv(NAME)) | .[\"env\"].${4}" "$1"
}

# _make_stubs DIR: the tools a step may call, as scripts that only identify
# themselves, plus the fake docker of WSO section 3. The server version (27.5.1)
# differs from the client one (28.0.4) ON PURPOSE: with the same value,
# `docker --version` alone would satisfy an assertion on the server and the step
# could stop asking for ServerVersion without any test noticing.
_make_stubs() {
  local dir="$1" tool
  mkdir -p "$dir"
  for tool in bats yq jq git tmux; do
    printf '#!/bin/sh\necho "%s stub 1.0"\n' "$tool" > "$dir/$tool"
    chmod +x "$dir/$tool"
  done
  cat > "$dir/docker" <<'STUB'
#!/bin/bash
# Fake docker (039 oracle). `info` writes in two batches, one echo per line,
# with a pause between them: the shape that makes a consumer closing after 10
# lines hand the writer a SIGPIPE. STUB_LOG gets one marker line per batch.
down() {
  echo "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?" >&2
  exit 1
}
case "${1:-}" in
  --version) echo "Docker version 28.0.4, build b8034c0" ;;
  compose)   echo "Docker Compose version v2.38.2" ;;
  info)
    [ "${STUB_DOCKER_DOWN:-0}" = "1" ] && down
    if [ "${2:-}" = "--format" ]; then
      t="${3:-}"
      t=${t//'{{.ServerVersion}}'/27.5.1}
      t=${t//'{{.OperatingSystem}}'/Ubuntu 24.04.2 LTS}
      t=${t//'{{.Architecture}}'/x86_64}
      t=${t//'{{.CgroupVersion}}'/2}
      t=${t//'{{.Driver}}'/overlayfs}
      case "$t" in
        *'{{'*) echo "template parsing error: unresolved field in: ${3:-}" >&2; exit 1 ;;
      esac
      echo "$t"
      exit 0
    fi
    echo "info-chunk client 14" >> "${STUB_LOG:-/dev/null}"
    i=1; while [ "$i" -le 14 ]; do echo "client line $i"; i=$((i + 1)); done
    sleep "${STUB_INFO_DELAY:-0.3}"
    echo "info-chunk server 40" >> "${STUB_LOG:-/dev/null}"
    i=1; while [ "$i" -le 40 ]; do echo "server line $i"; i=$((i + 1)); done
    ;;
esac
STUB
  chmod +x "$dir/docker"
}

# _run_step [-N] SCRIPTFILE [VAR=val ...]: run an extracted step the way the
# runner does (`bash -e FILE`), in $TMP_TEST_DIR/run, with the stub directory in
# front of PATH. A sentinel line is appended to a COPY: a script that dies before
# its end never prints it. The interpreter is the bash that runs bats (3.2.57 or
# 5.x: the dual gate applies to the oracle too). An optional leading -N is the
# exit status the step is EXPECTED to end with (bats warns on an unexpected-looking
# 127; S5 expects it on purpose). Leaves $status and $output.
_run_step() {
  local expect=""
  case "${1:-}" in -[0-9]*) expect="$1"; shift ;; esac
  local script="$1"
  shift
  local copy="$TMP_TEST_DIR/step-under-test.sh"
  cp "$script" "$copy"
  printf '\necho __ORACLE_REACHED_END__\n' >> "$copy"
  cd "$TMP_TEST_DIR/run"
  run ${expect:+"$expect"} env "$@" "PATH=${STEP_STUBS:-$TMP_TEST_DIR/stubs}:$PATH" "$BASH" -e "$copy"
}

# _write_ratchet_jq FILE: the scanner program (WSO section 5). Lines of every
# `run:` that pipe into a consumer able to close the pipe before its producer is
# done: head; grep with q or -m; sed with an Nq script or -n plus a q command;
# awk with exit. Comment lines and `||` lists are ignored. Reports
# file<TAB>step<TAB>N:line, N being the line inside the run: text. Known limit:
# a backslash continuation is judged per physical line.
_write_ratchet_jq() {
  cat > "$1" <<'JQ'
def words: [splits("[ \t]+")] | map(select(length > 0));
def unquote: gsub("^[\"']+|[\"']+$"; "");
def closes($seg):
  ($seg | sub("^[ \t({!]+"; "")) as $raw
  | ($raw | sub("[ \t]*(\\|\\||&&|;).*$"; "")) as $cut
  | ($raw | sub("[ \t]*(\\|\\||&&).*$"; "")) as $cut2
  | ($cut | words | map(unquote)) as $cw
  | ($cut2 | words | map(unquote)) as $rw
  | ($cw[0] // "") as $cmd
  | if $cmd == "head" then true
    elif $cmd == "grep" then
      ($cw[1:] | any(test("^-[A-Za-z]*[qm][A-Za-z0-9]*$") or test("^--(quiet|silent|max-count)")))
    elif $cmd == "sed" then
      ($cw[1:] | any(test("^[0-9$]*q$")))
      or (($rw[1:] | any(test("^-[A-Za-z]*n"))) and ($rw[1:] | any(test("(^|[;{ ])q([;} ]|$)"))))
    elif $cmd == "awk" then ($cut2 | test("(^|[^A-Za-z_])exit([^A-Za-z_]|$)"))
    else false end;
(.jobs // {}) | .[] | (.steps // []) | .[]
| select(.run != null)
| . as $step
| ($step.run | split("\n")) as $lines
| range(0; $lines | length) as $i
| $lines[$i] as $line
| select($line | test("^[ \t]*#") | not)
| ($line | [splits("(?<![|])[|](?![|])&?")]) as $segs
| select(($segs | length) > 1)
| select($segs[1:] | any(closes(.)))
| [$file, ($step.name // "(sin nombre)"), "\($i + 1):\($line)"] | @tsv
JQ
}

# _ratchet_scan YAML...: print one finding per offending line. A workflow that
# does not parse fails the scan (it never reads as "no findings").
_ratchet_scan() {
  local jqf="$TMP_TEST_DIR/ratchet.jq"
  _write_ratchet_jq "$jqf"
  (
    set -o pipefail
    for f in "$@"; do
      yq -o=json '.' "$f" | jq -r --arg file "$(basename "$f")" -f "$jqf" || exit 1
    done
  )
}

# ── the harness proves it can fail (they pass today) ─────────────────────────

@test "O1: the real verification step is found exactly once, with text" {
  run _extract_run "$WF/docker-e2e.yml" e2e "Verify deps + docker"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  _has "$output" "docker"
  # the extraction itself must be able to fail: a step that does not exist is
  # an error, never an empty pass
  run _extract_run "$WF/docker-e2e.yml" e2e "no such step"
  [ "$status" -ne 0 ]
}

@test "O5: the fake docker writes two batches with a pause between them" {
  local log="$TMP_TEST_DIR/stub.log" n first second
  : > "$log"
  run env "STUB_LOG=$log" "$TMP_TEST_DIR/stubs/docker" info
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 54 ]
  grep -q '^info-chunk client 14$' "$log"
  grep -q '^info-chunk server 40$' "$log"
  first=$(grep -n '^info-chunk client' "$log" | cut -d: -f1)
  second=$(grep -n '^info-chunk server' "$log" | cut -d: -f1)
  [ "$first" -lt "$second" ]
  n=$(sed -n 's/^info-chunk client //p' "$log")
  [ "$n" -gt 10 ]
  grep -q 'sleep' "$TMP_TEST_DIR/stubs/docker"
}

@test "O2: the harness catches the defect: the frozen da22a06 step ends in 141" {
  _run_step "$FIX/step-verify-with-defect.sh"
  [ "$status" -eq 141 ]
  _lacks "$output" "__ORACLE_REACHED_END__"
  # the 141 comes from `docker info | head -10` and not from anything else:
  # head printed exactly ten lines of the first batch and closed the pipe
  _has "$output" "client line 10"
  _lacks "$output" "client line 11"
}

@test "R1: the scanner reports every consumer that closes the pipe early" {
  local name
  run _ratchet_scan "$FIX/ratchet-bad.yml"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 7 ]
  for name in 'head -1' 'head -n 3' 'grep -q' 'grep -m1' 'sed 1q' 'sed -n 1q' 'awk exit'; do
    grep -qF "ratchet-bad.yml"$'\t'"$name"$'\t' <<< "$output"
  done
  # a workflow that does not parse is an error, never "no findings"
  printf 'a: [unclosed\n' > "$TMP_TEST_DIR/broken.yml"
  run _ratchet_scan "$TMP_TEST_DIR/broken.yml"
  [ "$status" -ne 0 ]
}

@test "R2: the scanner leaves benign pipes alone" {
  local steps
  # the fixture really has run: steps for the scanner to look at
  steps=$(yq '[.jobs[].steps[] | select(.run != null)] | length' "$FIX/ratchet-good.yml")
  [ "$steps" -ge 7 ]
  run _ratchet_scan "$FIX/ratchet-good.yml"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ── US1: the verification step (O3 is RED until the workflow is fixed) ───────

@test "O3: with a healthy Docker the real verification step reaches its end and shows server and arch" {
  _extract_run "$WF/docker-e2e.yml" e2e "Verify deps + docker" > "$TMP_TEST_DIR/verify.sh"
  _run_step "$TMP_TEST_DIR/verify.sh"
  [ "$status" -eq 0 ]
  _has "$output" "__ORACLE_REACHED_END__"
  _has "$output" "Docker version"
  _has "$output" "Docker Compose version"
  # the fake server (27.5.1) differs from the client (28.0.4): these tokens can
  # only come from a step that asked the engine for them
  _has "$output" "server=27.5.1"
  _has "$output" "arch=x86_64"
}

@test "O4: with Docker down the real verification step still fails loudly (FR-003)" {
  _extract_run "$WF/docker-e2e.yml" e2e "Verify deps + docker" > "$TMP_TEST_DIR/verify.sh"
  _run_step "$TMP_TEST_DIR/verify.sh" STUB_DOCKER_DOWN=1
  [ "$status" -ne 0 ]
  _lacks "$output" "__ORACLE_REACHED_END__"
  _has "$output" "Cannot connect to the Docker daemon"
}

# ── US1: the suite step (S1-S4 are RED until the workflow is restructured) ───

# _suite_stubs: a fake bats in front of the trivial stubs. It records its
# arguments, one per line, in $FAKE_ARGS, prints the canned TAP in $FAKE_TAP and
# exits with $FAKE_RC.
_suite_stubs() {
  mkdir -p "$TMP_TEST_DIR/fakebats"
  cat > "$TMP_TEST_DIR/fakebats/bats" <<'STUB'
#!/bin/sh
printf '%s\n' "$@" > "$FAKE_ARGS"
if [ -n "${FAKE_TAP:-}" ]; then cat "$FAKE_TAP"; fi
exit "${FAKE_RC:-0}"
STUB
  chmod +x "$TMP_TEST_DIR/fakebats/bats"
  export STEP_STUBS="$TMP_TEST_DIR/fakebats:$TMP_TEST_DIR/stubs"
}

# _run_suite TAPFILE RC [-N]: the real "Run docker-e2e suite" step against the
# fake bats. The arguments bats received end up in $TMP_TEST_DIR/bats-args.txt.
_run_suite() {
  _suite_stubs
  _extract_run "$WF/docker-e2e.yml" e2e "Run docker-e2e suite" > "$TMP_TEST_DIR/suite.sh"
  _run_step ${3:+"$3"} "$TMP_TEST_DIR/suite.sh" "FAKE_ARGS=$TMP_TEST_DIR/bats-args.txt" "FAKE_TAP=${1:-}" "FAKE_RC=$2"
}

@test "S1: every e2e skipped with bats exiting 0 is a RED run (SC-007)" {
  _run_suite "$FIX/tap-all-skip.tap" 0
  [ "$status" -eq 1 ]
  _has "$output" "e2e summary: total=3 executed=0 skipped=3 failed=0"
  _has "$output" "::error::"
  _lacks "$output" "__ORACLE_REACHED_END__"
}

@test "S2: an empty test list with bats exiting 0 is a RED run" {
  _run_suite "$FIX/tap-empty.tap" 0
  [ "$status" -eq 1 ]
  _has "$output" "e2e summary: total=0 executed=0 skipped=0 failed=0"
  _lacks "$output" "__ORACLE_REACHED_END__"
}

@test "S3: a run that executed tests passes, counts them, and gives bats every e2e file and only those (FR-004)" {
  _run_suite "$FIX/tap-mixed.tap" 0
  [ "$status" -eq 0 ]
  _has "$output" "e2e summary: total=3 executed=2 skipped=1 failed=0"
  _has "$output" "__ORACLE_REACHED_END__"
  # what bats was asked to run: TAP output, the e2e glob, nothing else
  grep -qxF -- '--tap' "$TMP_TEST_DIR/bats-args.txt"
  grep -qxF 'tests/docker-e2e-x.bats' "$TMP_TEST_DIR/bats-args.txt"
  run grep -qF 'tests/other.bats' "$TMP_TEST_DIR/bats-args.txt"
  [ "$status" -ne 0 ]
}

@test "S4: a failing test makes the step exit with the code of bats and be counted" {
  _run_suite "$FIX/tap-failing.tap" 1
  [ "$status" -eq 1 ]
  _has "$output" "e2e summary: total=2 executed=2 skipped=0 failed=1"
  _lacks "$output" "__ORACLE_REACHED_END__"
}

@test "S5: when bats cannot even start (127) the step reports 127, not a disguised empty green" {
  _run_suite "" 127 -127
  [ "$status" -eq 127 ]
  _lacks "$output" "ningun e2e se ejecuto"
  _lacks "$output" "__ORACLE_REACHED_END__"
}

@test "S6: the suite step carries DOCKER_E2E=1 in its env (without it all 48 e2e skip)" {
  run _extract_env "$WF/docker-e2e.yml" e2e "Run docker-e2e suite" DOCKER_E2E
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

# ── US2: the ratchet over every workflow ─────────────────────────────────────

@test "R3: no step of any workflow pipes into a consumer that closes the pipe early" {
  local f steps n=0 l
  # the sweep cannot be vacuous: at least three workflow files, each with at
  # least one run: step for the scanner to look at
  for f in "$WF"/*.yml; do
    n=$((n + 1))
    steps=$(yq '[.jobs[].steps[] | select(.run != null)] | length' "$f")
    [ "$steps" -ge 1 ]
  done
  [ "$n" -ge 3 ]
  run _ratchet_scan "$WF"/*.yml
  [ "$status" -eq 0 ]
  if [ -n "$output" ]; then
    echo "# consumers that close the pipe early (file, step, line:text):" >&3
    for l in "${lines[@]}"; do echo "#   $l" >&3; done
    false
  fi
}
