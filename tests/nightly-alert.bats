#!/usr/bin/env bats
# 040-nightly-red-alert: oracle for the nightly notice.
#
# Contracts: specs/040-nightly-red-alert/contracts/alert-oracle.md (AO: N00-N31),
# alert-script.md (AS), alert-workflow.md (AW) and notice-format.md (NF).
#
# The nightly docker-e2e run was red for 155 of 158 scheduled nights and nobody
# was told. This file runs the REAL text of .github/scripts/nightly-alert.sh
# against a fake `gh` that keeps state (issues, labels, comments, a call log) and
# whose flag whitelist is exactly what the real gh 2.102.0 accepts, so the oracle
# cannot approve a call the real gh would reject. A check that cannot fail is not
# evidence (025, 039): N00 calibrates the fake, the vacuity guards demand the
# script's own `::notice::` line next to every "no action" claim, and every
# mutation of the table in quickstart.md has a test that must fall.
#
# Test seams (the workflow defines none of them):
#   ALERT_SCRIPT / ALERT_WORKFLOW  paths under test; a mutation is applied to a copy
#   NIGHTLY_ALERT_NOW              the script's "now" (T1/T2/T3 below); no test
#                                  depends on the clock or on midnight UTC
#   SIGPIPE_MODE                   ignore (default: what the GitHub runner hands the
#                                  script) or default; set with perl right before exec
#   FAKE_GH_FAIL                   comma list of gh operations that must fail
#
# Rules this file lives by (it is the code that enforces them):
#   - bash 3.2 and 5.x: no mapfile, no associative arrays, no ${v,,}.
#   - never `producer | head` / `producer | grep -q`: assertions on $output use
#     case/grep on a here-string or a file, never a pipe that can close early.
#   - a negative assertion is `_lacks` or `run ...; [ "$status" -ne 0 ]`, never an
#     intermediate `!` (bats does not turn it into a failure); no intermediate
#     `[[ ]]` (dead in bash 3.2).
#   - ASCII only, payloads by file and never by argv.

load helper

# `run -N` (an expected exit status) needs bats 1.5; CI installs 1.11.
bats_require_minimum_version 1.5.0

ALERT_SCRIPT="${ALERT_SCRIPT:-$REPO_ROOT/.github/scripts/nightly-alert.sh}"
ALERT_WORKFLOW="${ALERT_WORKFLOW:-$REPO_ROOT/.github/workflows/docker-e2e.yml}"
FIX="$REPO_ROOT/tests/fixtures/nightly-alert"
CIFIX="$REPO_ROOT/tests/fixtures/ci"
T1=1792497600   # 20-10-2026 12:00 UTC
T2=1792584000   # 21-10-2026 12:00 UTC
T3=1792670400   # 22-10-2026 12:00 UTC
# The one place SIGPIPE is set: perl applies the disposition named by its first
# argument and then execs the rest (an ignored signal survives exec; a bash reset
# of it is refused). _alert and the N17 probe both go through it.
SIGPIPE_PERL='$SIG{PIPE} = shift @ARGV; exec @ARGV'

setup() {
  setup_tmp_dir
  export FAKE_GH_STATE="$TMP_TEST_DIR/gh-state"
  mkdir -p "$FAKE_GH_STATE" "$TMP_TEST_DIR/bin" "$TMP_TEST_DIR/tmp" "$TMP_TEST_DIR/work"
  printf '[]\n' > "$FAKE_GH_STATE/issues.json"
  : > "$FAKE_GH_STATE/labels.txt"
  : > "$FAKE_GH_STATE/calls.log"
  cp "$FIX/gh" "$TMP_TEST_DIR/bin/gh"
  chmod +x "$TMP_TEST_DIR/bin/gh"
  unset FAKE_GH_FAIL SIGPIPE_MODE
}
teardown() { teardown_tmp_dir; }

# -- harness ------------------------------------------------------------------

# _has TEXT NEEDLE / _lacks TEXT NEEDLE: substring assertions with no pipe.
# Copied from tests/ci-workflows.bats (039), together with _extract_run below.
_has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
_lacks() { ! _has "$1" "$2"; }

# _extract_run FILE JOB NAME: print the `run:` text of the step called NAME in
# job JOB. The step must match exactly once and have text, or this fails with a
# message that says why: an oracle that cannot find its subject must not pass.
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

# _alert SUBCOMMAND [ARG ...] [VAR=value ...]: run the script under test the way the
# runner does -- a clean environment (env -i) holding only what the job passes, the
# fake gh in front of PATH, in $TMP_TEST_DIR/work (where e2e.tap lives), with the
# SIGPIPE disposition SIGPIPE_MODE asks for set by perl right before exec (an
# ignored signal survives exec; a bash reset of it is refused). The interpreter is
# the bash that runs bats (3.2.57 or 5.x: the dual gate applies to the script too).
# Arguments that look like VAR=value go to the environment (later ones win over the
# defaults); any other argument goes to the script after the subcommand (`simulate
# red`). Leaves $status and $output (stdout and stderr merged).
_alert() {
  local sub="$1" a run_id=1001 sig nl=$'\n'
  local -a envs=() sargs=()
  shift
  for a in "$@"; do
    case "$a" in
      RUN_ID=*) run_id="${a#RUN_ID=}"; envs[${#envs[@]}]="$a" ;;
      [A-Za-z_]*=*) envs[${#envs[@]}]="$a" ;;
      *) sargs[${#sargs[@]}]="$a" ;;
    esac
  done
  case "${SIGPIPE_MODE:-ignore}" in
    ignore)  sig=IGNORE ;;
    default) sig=DEFAULT ;;
    *) echo "_alert: SIGPIPE_MODE must be ignore or default" >&2; return 1 ;;
  esac
  if [ ! -f "$ALERT_SCRIPT" ]; then
    echo "nightly-alert oracle: the script under test does not exist: $ALERT_SCRIPT" >&2
    return 1
  fi
  mkdir -p "$TMP_TEST_DIR/work"
  cd "$TMP_TEST_DIR/work"
  run env -i \
    "PATH=$TMP_TEST_DIR/bin:$PATH" "HOME=$TMP_TEST_DIR" "TMPDIR=$TMP_TEST_DIR/tmp" LC_ALL=C \
    "FAKE_GH_STATE=$FAKE_GH_STATE" "FAKE_GH_FAIL=${FAKE_GH_FAIL:-}" \
    GH_TOKEN=fake-token GH_REPO=o/r ASSIGNEE=maint \
    EVENT=schedule TRIAL= RUN_RESULT=failure FAILED_STEP=run_suite \
    "SUMMARY=total=48 executed=48 skipped=0 failed=2" \
    "FAILED_TESTS=beta failing test 1${nl}beta failing test 2" \
    RUN_ID=1001 RUN_ATTEMPT=1 "RUN_URL=https://github.com/o/r/actions/runs/$run_id" \
    "NIGHTLY_ALERT_NOW=$T1" "GITHUB_OUTPUT=$TMP_TEST_DIR/github_output" \
    ${envs[@]+"${envs[@]}"} \
    perl -e "$SIGPIPE_PERL" "$sig" "$BASH" "$ALERT_SCRIPT" "$sub" ${sargs[@]+"${sargs[@]}"}
  # a gh call the real gh 2.102.0 would reject makes the fake answer 64, which the script
  # only turns into a warning: unless the test says so, that is a failure of the test that
  # provoked it, not something to read between the lines
  if grep -q '^UNSUPPORTED' "$FAKE_GH_STATE/calls.log"; then
    echo "nightly-alert oracle: the script made a gh call the real gh does not accept:" >&2
    grep '^UNSUPPORTED' "$FAKE_GH_STATE/calls.log" >&2
    return 1
  fi
}

# _gho_parse: parse $GITHUB_OUTPUT the way the runner does (name=value on one line,
# or name<<DELIMITER, the value, and a line equal to DELIMITER) into one file per
# output under $TMP_TEST_DIR/outs. A heredoc that is never closed leaves
# __UNTERMINATED__ there, which the tests refuse. Whichever comes first on a line,
# `=` or `<<`, decides the form (the runner's rule).
_gho_parse() {
  local file="$TMP_TEST_DIR/github_output" dir="$TMP_TEST_DIR/outs"
  local line name="" delim="" val="" first=0 pre_eq pre_hd has_eq has_hd
  rm -rf "$dir"
  mkdir -p "$dir"
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    if [ -n "$delim" ]; then
      if [ "$line" = "$delim" ]; then
        printf '%s' "$val" > "$dir/$name"
        delim=""
      elif [ "$first" = 1 ]; then
        val="$line"
        first=0
      else
        val="$val"$'\n'"$line"
      fi
      continue
    fi
    if [ -z "$line" ]; then continue; fi
    pre_eq="${line%%=*}"
    pre_hd="${line%%<<*}"
    has_eq=0
    has_hd=0
    if [ "$pre_eq" != "$line" ]; then has_eq=1; fi
    if [ "$pre_hd" != "$line" ]; then has_hd=1; fi
    if [ "$has_hd" = 1 ] && { [ "$has_eq" = 0 ] || [ "${#pre_hd}" -lt "${#pre_eq}" ]; }; then
      name="$pre_hd"
      delim="${line#*<<}"
      first=1
      val=""
    elif [ "$has_eq" = 1 ]; then
      printf '%s' "${line#*=}" > "$dir/$pre_eq"
    fi
  done < "$file"
  if [ -n "$delim" ]; then : > "$dir/__UNTERMINATED__"; fi
  return 0
}

# _gho NAME: the value of a parsed output (empty if the output does not exist).
_gho() {
  if [ -f "$TMP_TEST_DIR/outs/$1" ]; then cat "$TMP_TEST_DIR/outs/$1"; fi
}

# _gho_names: the names of the parsed outputs, sorted, space separated.
_gho_names() {
  local f out=""
  for f in "$TMP_TEST_DIR"/outs/*; do
    [ -e "$f" ] || continue
    out="$out $(basename "$f")"
  done
  printf '%s\n' "${out# }"
}

# _collect STEPS_FILE [TAP_FILE]: run `collect` with the steps context in STEPS_FILE
# and, if given, TAP_FILE copied to e2e.tap; the outputs end up parsed for _gho.
_collect() {
  local json
  : > "$TMP_TEST_DIR/github_output"
  rm -f "$TMP_TEST_DIR/work/e2e.tap"
  if [ -n "${2:-}" ]; then cp "$2" "$TMP_TEST_DIR/work/e2e.tap"; fi
  json=$(cat "$1")
  _alert collect "STEPS_JSON=$json"
  _gho_parse
}

# _suite_summary TAP_FILE: the text after `e2e summary: ` printed by the REAL
# "Run docker-e2e suite" step of the workflow under test, run against a fake bats
# that prints TAP_FILE. Fails (and so does the test) if the step prints no summary.
_suite_summary() {
  local dir="$TMP_TEST_DIR/suite-run" out line
  mkdir -p "$dir/tests" "$TMP_TEST_DIR/fakebats"
  : > "$dir/tests/docker-e2e-x.bats"
  cat > "$TMP_TEST_DIR/fakebats/bats" <<'STUB'
#!/bin/sh
cat "$FAKE_TAP"
exit 0
STUB
  chmod +x "$TMP_TEST_DIR/fakebats/bats"
  _extract_run "$ALERT_WORKFLOW" e2e "Run docker-e2e suite" > "$TMP_TEST_DIR/suite.sh" || return 1
  out=$(cd "$dir" && env "PATH=$TMP_TEST_DIR/fakebats:$PATH" "FAKE_TAP=$1" DOCKER_E2E=1 bash -e "$TMP_TEST_DIR/suite.sh") || true
  while IFS= read -r line; do
    case "$line" in
      'e2e summary: '*) printf '%s\n' "${line#e2e summary: }"; return 0 ;;
    esac
  done <<< "$out"
  echo "_suite_summary: the suite step printed no 'e2e summary:' line" >&2
  return 1
}

# -- the fake gh and its state --------------------------------------------------

# _fake ARGS...: call the fake gh directly with the environment gh needs.
_fake() {
  env -i "PATH=$PATH" "FAKE_GH_STATE=$FAKE_GH_STATE" "FAKE_GH_FAIL=${FAKE_GH_FAIL:-}" \
    GH_TOKEN=t GH_REPO=o/r "$TMP_TEST_DIR/bin/gh" "$@"
}

# _seed_issue NUMBER GH_STATE MARKER_STATE TOTAL [LABEL [ROWS]]: plant an issue the
# way the script writes it (NF section 3), without going through gh, so calls.log
# stays clean. GH_STATE is OPEN or CLOSED. MARKER_STATE is open or resolved for a
# valid marker; none for a body edited by hand that lost it; broken for a marker
# that no longer matches the NF expression. LABEL defaults to nightly-red. ROWS (1
# by default) is how many nights the table already lists, newest first: run 900,
# run 899, ...
_seed_issue() {
  local n="$1" st="$2" ms="$3" total="$4" label="${5:-nightly-red}" rows="${6:-1}" title bodyf first i
  title="docker-e2e nightly en rojo"
  if [ "$label" = "nightly-red-trial" ]; then title="[ensayo] docker-e2e nightly en rojo"; fi
  bodyf="$TMP_TEST_DIR/seed-body-$n.md"
  case "$ms" in
    open|resolved) first="<!-- nightly-red:v1 state=$ms total=$total first=2026-10-20 -->" ;;
    broken)        first="<!-- nightly-red:v1 state=open total=abc -->" ;;
    none)          first="Alguien edito este aviso a mano." ;;
    *) echo "_seed_issue: unknown marker state '$ms'" >&2; return 1 ;;
  esac
  {
    printf '%s\n' "$first"
    printf '# docker-e2e nightly en rojo\n\n'
    printf 'Racha de **%s** noches programadas seguidas en rojo, desde el 20-10-2026 (UTC). Ultima: [run 900](https://github.com/o/r/actions/runs/900).\n\n' "$total"
    printf 'Este aviso se cierra solo cuando una noche programada vuelve a verde. Si lo cierras a mano mientras sigue en rojo, se reabre la noche siguiente.\n\n'
    printf '## Ultimas noches\n\n'
    printf '| Noche (UTC) | Corrida | Paso que fallo |\n|---|---|---|\n'
    i=0
    while [ "$i" -lt "$rows" ]; do
      printf '| 20-10-2026 | [run %s](https://github.com/o/r/actions/runs/%s) | `run_suite` |\n' "$((900 - i))" "$((900 - i))"
      i=$((i + 1))
    done
    printf '\n'
    printf '## Ultima noche\n\n'
    printf -- '- Resumen de la suite: `total=48 executed=48 skipped=0 failed=2`\n'
    printf -- '- Tests que fallaron (2):\n\n'
    printf '~~~text\nbeta failing test 1\nbeta failing test 2\n~~~\n'
  } > "$bodyf"
  jq --argjson n "$n" --arg st "$st" --arg t "$title" --rawfile b "$bodyf" --arg l "$label" '
    . + [{number: $n, state: $st, stateReason: (if $st == "CLOSED" then "COMPLETED" else null end),
          title: $t, body: $b, labels: [{name: $l}], assignees: [{login: "maint"}],
          comments: [], url: ("https://github.com/fake/repo/issues/" + ($n | tostring))}]
  ' "$FAKE_GH_STATE/issues.json" > "$FAKE_GH_STATE/issues.tmp"
  mv "$FAKE_GH_STATE/issues.tmp" "$FAKE_GH_STATE/issues.json"
  if ! grep -qx -- "$label" "$FAKE_GH_STATE/labels.txt"; then printf '%s\n' "$label" >> "$FAKE_GH_STATE/labels.txt"; fi
}

# _issue_field NUMBER JQ_EXPR: a field of an issue in the fake's state, raw.
_issue_field() {
  jq -r --argjson n "$1" ".[] | select(.number == \$n) | $2" "$FAKE_GH_STATE/issues.json"
}

# _issue_count: how many issues the fake holds.
_issue_count() { jq 'length' "$FAKE_GH_STATE/issues.json"; }

# _count_calls VERB: how many calls.log lines carry that verb.
_count_calls() {
  local n
  n=$(grep -c "^$1"$'\t' "$FAKE_GH_STATE/calls.log" 2>/dev/null) || n=0
  printf '%s\n' "$n"
}

# _mutating_calls: the calls.log lines that change something on GitHub.
_mutating_calls() {
  grep -E '^(create|edit|comment|reopen|close|label-create)'$'\t' "$FAKE_GH_STATE/calls.log" || true
}

# _rows BODY: the night rows of the table in a notice body, in the order they appear.
_rows() {
  grep -E '^\| [0-9]{2}-[0-9]{2}-[0-9]{4} \| ' <<< "$1" || true
}

# _fence BODY: the lines between the opening ~~~text and the first closing ~~~.
_fence() {
  local line inside=0
  while IFS= read -r line; do
    if [ "$inside" = 1 ]; then
      if [ "$line" = "~~~" ]; then return 0; fi
      printf '%s\n' "$line"
    elif [ "$line" = "~~~text" ]; then
      inside=1
    fi
  done <<< "$1"
}

# _early_closers FILE: print the lines that pipe into a consumer able to close the
# pipe before its producer is done (the rules of the 039 ratchet: head; grep with q
# or -m; sed with an Nq script; awk with exit). `||` lists are not pipes.
_early_closers() {
  grep -E '[^|][|][[:space:]]*(head([[:space:]]|$)|grep[[:space:]]+(-[A-Za-z]*[qm]|--quiet|--silent|--max-count)|sed[[:space:]]+(-n[[:space:]]+)?["'"'"']?[0-9$]*q|awk[^|]*[^A-Za-z_]exit)' "$1" || true
}

# _only_printable FILE: how many bytes of FILE are neither printable ASCII nor a
# newline (control characters, tabs, anything above 127). The notice must have none.
_only_printable() {
  local n
  n=$(LC_ALL=C tr -d '\040-\176\n' < "$1" | wc -c)
  printf '%s\n' "${n//[[:space:]]/}"
}

# -- N00: calibration of the instrument ------------------------------------------

@test "N00 el gh falso: exige FAKE_GH_STATE, registra cada llamada y rechaza lo que el gh real no acepta" {
  local b="$TMP_TEST_DIR/b.md"
  printf 'cuerpo\n' > "$b"
  # without the state directory it refuses to run: a test must not run against a
  # phantom state
  run -99 env -i "PATH=$PATH" GH_TOKEN=t GH_REPO=o/r "$TMP_TEST_DIR/bin/gh" issue list --json number
  # without a token it fails like the real gh in Actions
  run -4 env -i "PATH=$PATH" "FAKE_GH_STATE=$FAKE_GH_STATE" GH_REPO=o/r "$TMP_TEST_DIR/bin/gh" issue list --json number
  # a listing is recorded in calls.log and answers an empty array
  run -0 _fake issue list --label nightly-red --state all --limit 1 --json number,state
  [ "$output" = "[]" ]
  grep -q "^list"$'\t' "$FAKE_GH_STATE/calls.log"
  # a flag the real gh does not take (here --jq, which the script must not use) and
  # an unknown subcommand are refused with 64 and written as UNSUPPORTED
  run -64 _fake issue list --label x --state all --limit 1 --json number --jq '.[]'
  run -64 _fake pr list
  [ "$(_count_calls UNSUPPORTED)" = "2" ]
  # an issue cannot carry a label that does not exist; the refusal changes nothing
  run -1 _fake issue create --title T --label nightly-red --body-file "$b"
  [ "$(_issue_count)" = "0" ]
  run -0 _fake label create nightly-red --color D93F0B --description d
  run -1 _fake label create nightly-red --color D93F0B --description d
  run -0 _fake issue create --title T --label nightly-red --assignee maint --body-file "$b"
  [ "$output" = "https://github.com/fake/repo/issues/1" ]
  [ "$(_issue_field 1 .state)" = "OPEN" ]
  [ "$(_issue_field 1 '.assignees[0].login')" = "maint" ]
  # an injected failure exits 1 and leaves the state alone
  FAKE_GH_FAIL=create run -1 _fake issue create --title T2 --label nightly-red --body-file "$b"
  [ "$(_issue_count)" = "1" ]
  FAKE_GH_FAIL=create_assignee run -1 _fake issue create --title T2 --label nightly-red --assignee maint --body-file "$b"
  [ "$(_issue_count)" = "1" ]
  FAKE_GH_FAIL=create_assignee run -0 _fake issue create --title T2 --label nightly-red --body-file "$b"
  [ "$(_issue_count)" = "2" ]
  # listing: newest first, --limit applied, only the requested fields, state filter
  run -0 _fake issue list --label nightly-red --state all --limit 1 --json number,title
  [ "$output" = '[{"number":2,"title":"T2"}]' ]
  run -0 _fake issue close 1 --reason completed
  run -0 _fake issue list --label nightly-red --state open --json number
  [ "$output" = '[{"number":2}]' ]
  run -0 _fake issue list --label nightly-red --state closed --json number,state
  [ "$output" = '[{"number":1,"state":"CLOSED"}]' ]
  # every call above, including the refused ones, left a line
  [ "$(_count_calls close)" = "1" ]
  [ "$(_count_calls label-create)" = "2" ]
}

# -- US1: the first red night leaves a notice -----------------------------------

@test "N01 rojo nuevo: crea la etiqueta y el issue con titulo, etiqueta, asignado y cuerpo completo" {
  _alert notify
  [ "$status" -eq 0 ]
  # the first thing it does is look for the latest notice of its mode, any state
  [ "$(head -n 1 "$FAKE_GH_STATE/calls.log")" = $'list\t--label nightly-red --state all --limit 1 --json number,state,body,url' ]
  [ "$(_count_calls label-create)" = "1" ]
  grep -qx 'nightly-red' "$FAKE_GH_STATE/labels.txt"
  [ "$(_count_calls create)" = "1" ]
  grep -q $'^create\t--title docker-e2e nightly en rojo --label nightly-red --assignee maint$' "$FAKE_GH_STATE/calls.log"
  [ "$(_issue_count)" = "1" ]
  [ "$(_issue_field 1 .title)" = "docker-e2e nightly en rojo" ]
  [ "$(_issue_field 1 '.labels[0].name')" = "nightly-red" ]
  [ "$(_issue_field 1 '.assignees[0].login')" = "maint" ]
  [ "$(_issue_field 1 .state)" = "OPEN" ]
  local body
  body=$(_issue_field 1 .body)
  # first line: the marker, written from scratch with the script's own values
  [ "${body%%$'\n'*}" = '<!-- nightly-red:v1 state=open total=1 first=2026-10-20 -->' ]
  _has "$body" 'Racha de **1**'
  _has "$body" 'desde el 20-10-2026'
  # the link to the run, the row of the night, the failed step, the suite summary
  _has "$body" '[run 1001](https://github.com/o/r/actions/runs/1001)'
  _has "$body" '| 20-10-2026 | [run 1001](https://github.com/o/r/actions/runs/1001) | `run_suite` |'
  _has "$body" '- Resumen de la suite: `total=48 executed=48 skipped=0 failed=2`'
  _has "$body" 'Tests que fallaron (2):'
  # the failed tests sit inside a fenced block
  _has "$body" $'~~~text\nbeta failing test 1\nbeta failing test 2\n~~~'
  # the script says what it decided, and never prints the token
  _has "$output" '::notice::nightly-alert: modo=real resultado=failure accion=crea'
  _lacks "$output" 'fake-token'
  _lacks "$body" 'fake-token'
}

@test "N02 rojo sin resumen: el aviso dice que no hay resumen ni tests y nombra el paso" {
  _alert notify FAILED_STEP=verify_deps SUMMARY= FAILED_TESTS=
  [ "$status" -eq 0 ]
  [ "$(_issue_count)" = "1" ]
  local body
  body=$(_issue_field 1 .body)
  [ "${body%%$'\n'*}" = '<!-- nightly-red:v1 state=open total=1 first=2026-10-20 -->' ]
  _has "$body" 'Resumen de la suite: no disponible'
  _has "$body" 'Tests que fallaron: ninguno informado'
  _has "$body" '| 20-10-2026 | [run 1001](https://github.com/o/r/actions/runs/1001) | `verify_deps` |'
  # nothing was invented to fill the gap
  _lacks "$body" 'total=48'
  _lacks "$body" '~~~text'
}

@test "N18 collect: el paso fallido sale de toJSON(steps), vacio si no hay fallo o el JSON no sirve" {
  _collect "$FIX/steps-suite-red.json"
  [ "$status" -eq 0 ]
  [ "$(_gho failed_step)" = "run_suite" ]
  _collect "$FIX/steps-verify-red.json"
  [ "$status" -eq 0 ]
  [ "$(_gho failed_step)" = "verify_deps" ]
  # a cancelled step also names the step (the notice says where the night stopped)
  _collect "$FIX/steps-cancelled.json"
  [ "$status" -eq 0 ]
  [ "$(_gho failed_step)" = "run_suite" ]
  # a green night has no failed step, and the output still exists (empty)
  _collect "$FIX/steps-green.json"
  [ "$status" -eq 0 ]
  [ -z "$(_gho failed_step)" ]
  [ -f "$TMP_TEST_DIR/outs/failed_step" ]
  # text that is not JSON is a missing datum, not an error: exit 0 and an empty field
  _collect "$FIX/steps-invalid.txt"
  [ "$status" -eq 0 ]
  [ -z "$(_gho failed_step)" ]
  # the three outputs of the job are always produced, whatever the input
  [ "$(_gho_names)" = "failed_step failed_tests summary" ]
  [ ! -e "$TMP_TEST_DIR/outs/__UNTERMINATED__" ]
}

@test "N19 paridad: el summary de collect es identico al que imprime el paso real de la suite" {
  local name tap want got seen=""
  for name in tap-mixed tap-failing tap-all-skip tap-empty; do
    tap="$CIFIX/$name.tap"
    want=$(_suite_summary "$tap")
    [ -n "$want" ]
    _collect "$FIX/steps-green.json" "$tap"
    [ "$status" -eq 0 ]
    got=$(_gho summary)
    if [ "$got" != "$want" ]; then
      echo "# $name: collect says '$got' but the suite step says '$want'" >&3
      false
    fi
    seen="$seen|$want"
  done
  # the parity is not trivially true: the literals the suite step prints today, and
  # four different strings, so a collect that computed the same thing four times fails
  _has "$seen" '|total=3 executed=2 skipped=1 failed=0'
  _has "$seen" '|total=2 executed=2 skipped=0 failed=1'
  _has "$seen" '|total=3 executed=0 skipped=3 failed=0'
  _has "$seen" '|total=0 executed=0 skipped=0 failed=0'
  # no e2e.tap at all (the run died before the suite): no summary, not a made-up one
  _collect "$FIX/steps-verify-red.json"
  [ -z "$(_gho summary)" ]
}

@test "N20 collect: los nombres de test no rompen el formato de GITHUB_OUTPUT" {
  local tap="$TMP_TEST_DIR/hostile.tap" d1 d2
  # names that look like other outputs, like a heredoc opener, like the usual
  # delimiters and with a carriage return: none may inject an output or close the
  # value early
  {
    printf '1..6\n'
    printf 'ok 1 fine\n'
    printf 'not ok 2 failed_step=pwned\n'
    printf 'not ok 3 EOF\n'
    printf 'not ok 4 summary<<GHADELIM\n'
    printf 'not ok 5 a=b<<c\n'
    printf 'not ok 6 with\rreturn\n'
  } > "$tap"
  _collect "$FIX/steps-suite-red.json" "$tap"
  [ "$status" -eq 0 ]
  [ ! -e "$TMP_TEST_DIR/outs/__UNTERMINATED__" ]
  [ "$(_gho_names)" = "failed_step failed_tests summary" ]
  [ "$(_gho failed_step)" = "run_suite" ]
  [ "$(_gho summary)" = "total=6 executed=6 skipped=0 failed=5" ]
  [ "$(_gho failed_tests)" = $'failed_step=pwned\nEOF\nsummary<<GHADELIM\na=b<<c\nwithreturn' ]
  # the delimiter is random: two runs do not share it, and it is long enough that
  # a test name cannot guess it
  d1=$(grep '^failed_tests<<' "$TMP_TEST_DIR/github_output") || d1=""
  [ -n "$d1" ]
  _collect "$FIX/steps-suite-red.json" "$tap"
  d2=$(grep '^failed_tests<<' "$TMP_TEST_DIR/github_output") || d2=""
  [ -n "$d2" ]
  d1="${d1#*<<}"
  d2="${d2#*<<}"
  [ "$d1" != "$d2" ]
  [ "${#d1}" -ge 16 ]
  [ "${#d2}" -ge 16 ]
}

# -- US2: the notice cannot change the verdict of the night ------------------------

# _reset_state: empty the fake's state between the cases of one test.
_reset_state() {
  printf '[]\n' > "$FAKE_GH_STATE/issues.json"
  : > "$FAKE_GH_STATE/labels.txt"
  : > "$FAKE_GH_STATE/calls.log"
}

@test "N12 fallas de gh: con cada llamada fallando por turnos el script sale con 0 y avisa; sin asignado el aviso se crea igual" {
  local op body
  # a night with no notice yet: a failure to list, to create the label or to create
  # the issue leaves nothing published, says so, and does not touch the exit code
  for op in list label create; do
    _reset_state
    FAKE_GH_FAIL="$op"
    _alert notify
    [ "$status" -eq 0 ]
    _has "$output" '::warning::nightly-alert:'
    [ "$(_issue_count)" = "0" ]
  done
  # without a decision there is nothing to change: a failed list makes no mutating call
  _reset_state
  FAKE_GH_FAIL=list
  _alert notify
  [ -z "$(_mutating_calls)" ]
  # a failed assignment (FR-019): the notice is created anyway, without assignee,
  # with a warning
  _reset_state
  FAKE_GH_FAIL=create_assignee
  _alert notify
  [ "$status" -eq 0 ]
  _has "$output" '::warning::nightly-alert:'
  [ "$(_issue_count)" = "1" ]
  [ "$(_issue_field 1 '.assignees | length')" = "0" ]
  [ "$(_issue_field 1 '.labels[0].name')" = "nightly-red" ]
  [ "$(_count_calls create)" = "2" ]
  # an open notice and a new red night: a failed edit or comment still lets the
  # other one through
  for op in edit comment; do
    _reset_state
    _seed_issue 1 OPEN open 1
    FAKE_GH_FAIL="$op"
    _alert notify RUN_ID=1002
    [ "$status" -eq 0 ]
    _has "$output" '::warning::nightly-alert:'
    [ "$(_count_calls edit)" = "1" ]
    [ "$(_count_calls comment)" = "1" ]
  done
  # a notice closed by hand and a red night: a failed reopen does not stop the rest
  _reset_state
  _seed_issue 1 CLOSED open 1
  FAKE_GH_FAIL=reopen
  _alert notify RUN_ID=1002
  [ "$status" -eq 0 ]
  _has "$output" '::warning::nightly-alert:'
  [ "$(_count_calls reopen)" = "1" ]
  [ "$(_count_calls edit)" = "1" ]
  [ "$(_count_calls comment)" = "1" ]
  # an open notice and a green night: a failed close still leaves the body and the comment
  _reset_state
  _seed_issue 1 OPEN open 2
  FAKE_GH_FAIL=close
  _alert notify RUN_RESULT=success RUN_ID=1003
  [ "$status" -eq 0 ]
  _has "$output" '::warning::nightly-alert:'
  [ "$(_count_calls close)" = "1" ]
  [ "$(_count_calls edit)" = "1" ]
  [ "$(_count_calls comment)" = "1" ]
  # a green night over an open notice whose marker cannot be rewritten must NOT close it:
  # a closed notice still marked open would be reopened as "closed by hand" and carry the
  # old streak on. It stays open and the next green night does the whole job
  _reset_state
  _seed_issue 1 OPEN open 2
  FAKE_GH_FAIL=edit
  _alert notify RUN_RESULT=success RUN_ID=1004
  [ "$status" -eq 0 ]
  _has "$output" '::warning::nightly-alert:'
  [ "$(_count_calls close)" = "0" ]
  [ "$(_count_calls comment)" = "0" ]
  [ "$(_issue_field 1 .state)" = "OPEN" ]
  unset FAKE_GH_FAIL
  _alert notify RUN_RESULT=success RUN_ID=1005
  [ "$status" -eq 0 ]
  [ "$(_issue_field 1 .state)" = "CLOSED" ]
  body=$(_issue_field 1 .body)
  [ "${body%%$'\n'*}" = '<!-- nightly-red:v1 state=resolved total=2 first=2026-10-20 -->' ]
  unset FAKE_GH_FAIL
}

@test "N23 AW-1: el job alert es aparte, depende de e2e, corre con always() en programadas y ensayos y tiene tope de 5 minutos" {
  local f="$ALERT_WORKFLOW" want
  [ "$(yq '.jobs | has("alert")' "$f")" = "true" ]
  [ "$(yq '.jobs.alert.needs' "$f")" = "e2e" ]
  [ "$(yq '.jobs.alert["timeout-minutes"]' "$f")" = "5" ]
  want="\${{ always() && (github.event_name == 'schedule' || (github.event_name == 'workflow_dispatch' && inputs.alert_trial)) }}"
  [ "$(yq '.jobs.alert.if' "$f")" = "$want" ]
  # FR-010: the suite job does not wait for anything, so the first identifiable
  # failure of a run stays the suite step and never the notice
  [ "$(yq '.jobs.e2e | has("needs")' "$f")" = "false" ]
}

@test "N24 AW-2: el job alert pide exactamente contents read e issues write" {
  [ "$(yq '.jobs | has("alert")' "$ALERT_WORKFLOW")" = "true" ]
  [ "$(yq -o=json -I=0 '.jobs.alert.permissions | sort_keys(..)' "$ALERT_WORKFLOW")" = '{"contents":"read","issues":"write"}' ]
}

@test "N25 AW-3: ni el nivel del workflow ni el job de la suite reciben issues" {
  # the notice job exists: otherwise "nobody else has issues" would be true of any workflow
  [ "$(yq '.jobs | has("alert")' "$ALERT_WORKFLOW")" = "true" ]
  [ "$(yq -o=json -I=0 '.permissions | sort_keys(..)' "$ALERT_WORKFLOW")" = '{"contents":"read"}' ]
  [ "$(yq '.jobs.e2e | has("permissions")' "$ALERT_WORKFLOW")" = "false" ]
}

@test "N26 AW-4: el paso que publica el aviso no puede cambiar el color de la corrida y recibe todo por entorno" {
  local f="$ALERT_WORKFLOW" step coe runtext pair name want
  step='.jobs.alert.steps[] | select(.name == "Publish the nightly notice")'
  coe='.["continue-on-error"]'
  [ "$(yq "[$step] | length" "$f")" = "1" ]
  [ "$(yq "$step | $coe" "$f")" = "true" ]
  # a hung gh must end as a failed STEP, which continue-on-error absorbs, before the 5
  # minutes of the job turn it into a failed JOB (and the whole run red)
  [ "$(yq "$step | .[\"timeout-minutes\"]" "$f")" = "3" ]
  # the checkout of the script is part of the notice machinery too: if it fails, the night
  # keeps its colour
  [ "$(yq '.jobs.alert.steps[] | select(.name == "Checkout") | .["continue-on-error"]' "$f")" = "true" ]
  runtext=$(_extract_run "$f" alert "Publish the nightly notice")
  [ "$runtext" = ".github/scripts/nightly-alert.sh notify" ]
  # values from outside never go inside run: (command injection through a test name)
  _lacks "$runtext" '${{'
  # every datum the script reads arrives through env with exactly the expression that
  # feeds it. The behaviour tests set these variables themselves, so a typo here, or an
  # expression swapped for another, would leave the notice mute with every other test green
  for pair in \
    'GH_TOKEN|${{ github.token }}' \
    'GH_REPO|${{ github.repository }}' \
    'EVENT|${{ github.event_name }}' \
    'TRIAL|${{ inputs.alert_trial }}' \
    'RUN_RESULT|${{ needs.e2e.result }}' \
    'FAILED_STEP|${{ needs.e2e.outputs.failed_step }}' \
    'SUMMARY|${{ needs.e2e.outputs.summary }}' \
    'FAILED_TESTS|${{ needs.e2e.outputs.failed_tests }}' \
    'RUN_ID|${{ github.run_id }}' \
    'RUN_ATTEMPT|${{ github.run_attempt }}' \
    'RUN_URL|${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}' \
    'ASSIGNEE|rodrigo-hinojosa'; do
    name="${pair%%|*}"
    want="${pair#*|}"
    if [ "$(yq "$step | .[\"env\"].$name" "$f")" != "$want" ]; then
      echo "# env $name is '$(yq "$step | .[\"env\"].$name" "$f")', expected '$want'" >&3
      false
    fi
  done
  # and nothing else is passed
  [ "$(yq "$step | .[\"env\"] | keys | length" "$f")" = "12" ]
  # FR-010: the notice is not a step of the suite job
  [ "$(yq '[.jobs.e2e.steps[] | select(.name == "Publish the nightly notice")] | length' "$f")" = "0" ]
}

@test "N27 AW-5: el workflow no referencia ningun secreto (SC-007)" {
  local n
  # the file parses and has the suite job: the count below is about a real workflow
  [ -n "$(yq '.name' "$ALERT_WORKFLOW")" ]
  [ "$(yq '.jobs | has("e2e")' "$ALERT_WORKFLOW")" = "true" ]
  n=$(grep -c 'secrets\.' "$ALERT_WORKFLOW" || true)
  [ "$n" = "0" ]
}

@test "N28 AW-6: workflow_dispatch tiene las entradas del ensayo con su tipo, valores y defecto" {
  local f="$ALERT_WORKFLOW" inputs='.on.workflow_dispatch.inputs'
  [ "$(yq "$inputs.alert_trial.type" "$f")" = "boolean" ]
  [ "$(yq "$inputs.alert_trial.default" "$f")" = "false" ]
  [ "$(yq "$inputs.trial_outcome.type" "$f")" = "choice" ]
  [ "$(yq "$inputs.trial_outcome.default" "$f")" = "red" ]
  [ "$(yq "$inputs.trial_outcome.options | join(\",\")" "$f")" = "red,green,timeout" ]
  # the schedule stays as it was
  [ "$(yq '.on.schedule[0].cron' "$f")" = "0 5 * * *" ]
}

@test "N30 AW-8: collect es el ultimo paso con always(), las salidas del job salen de el y todos los pasos tienen id" {
  local f="$ALERT_WORKFLOW" last='.jobs.e2e.steps[-1]' name
  [ "$(yq "$last.id" "$f")" = "collect" ]
  [ "$(yq "$last.if" "$f")" = '${{ always() }}' ]
  # the script exits 0 always; this covers the one thing it cannot, failing to start
  # (a lost executable bit): the notice machinery must not turn a green night red
  [ "$(yq "$last"'["continue-on-error"]' "$f")" = "true" ]
  [ "$(yq "$last.env.STEPS_JSON" "$f")" = '${{ toJSON(steps) }}' ]
  [ "$(yq "$last.run" "$f")" = ".github/scripts/nightly-alert.sh collect" ]
  for name in failed_step summary failed_tests; do
    [ "$(yq ".jobs.e2e.outputs.$name" "$f")" = "\${{ steps.collect.outputs.$name }}" ]
  done
  [ "$(yq '.jobs.e2e.steps | map(select(has("id") | not)) | length' "$f")" = "0" ]
  # the ids the notice reports as "the step that failed", in the order of the job
  # (the trial step `simulate`, when present, sits between run_suite and collect:
  # N29 owns its position)
  [ "$(yq '.jobs.e2e.steps | map(.id) | map(select(. != "simulate")) | join(",")' "$f")" = "checkout,install_yq,install_bats,verify_deps,run_suite,collect" ]
}

@test "N31 AW-9: el workflow referencia el script y el script existe, es ejecutable y empieza con el shebang" {
  local f="$ALERT_WORKFLOW" refs path first
  refs=$(yq '[.jobs[].steps[] | select(.run != null) | .run | select(test("nightly-alert[.]sh"))] | length' "$f")
  [ "$refs" -ge 2 ]
  # every path the workflow runs is the repository script
  path=$(yq '[.jobs[].steps[] | select(.run != null) | .run | select(test("nightly-alert[.]sh")) | sub(" .*$"; "")] | unique | join(",")' "$f")
  [ "$path" = ".github/scripts/nightly-alert.sh" ]
  [ -f "$ALERT_SCRIPT" ]
  [ -x "$ALERT_SCRIPT" ]
  IFS= read -r first < "$ALERT_SCRIPT"
  [ "$first" = '#!/usr/bin/env bash' ]
}

# -- US3: a streak is one notice and it turns itself off with the green -------------

@test "N03 rojo repetido: con un aviso abierto no se crea otro; total +1, una fila y un comentario nuevos" {
  local body
  _alert notify
  [ "$status" -eq 0 ]
  _alert notify RUN_ID=1002 "NIGHTLY_ALERT_NOW=$T2"
  [ "$status" -eq 0 ]
  _has "$output" '::notice::nightly-alert: modo=real resultado=failure accion=actualiza'
  [ "$(_issue_count)" = "1" ]
  [ "$(_count_calls create)" = "1" ]
  [ "$(_count_calls edit)" = "1" ]
  [ "$(_count_calls comment)" = "1" ]
  [ "$(_issue_field 1 .state)" = "OPEN" ]
  body=$(_issue_field 1 .body)
  [ "${body%%$'\n'*}" = '<!-- nightly-red:v1 state=open total=2 first=2026-10-20 -->' ]
  _has "$body" 'Racha de **2**'
  # newest night first, the first night kept
  [ "$(_rows "$body")" = $'| 21-10-2026 | [run 1002](https://github.com/o/r/actions/runs/1002) | `run_suite` |\n| 20-10-2026 | [run 1001](https://github.com/o/r/actions/runs/1001) | `run_suite` |' ]
  [ "$(_issue_field 1 '.comments | length')" = "1" ]
  _has "$(_issue_field 1 '.comments[0].body')" 'Noche 2 de la racha: [run 1002](https://github.com/o/r/actions/runs/1002)'
  # the same when a person saved the body in the web editor, which sends CRLF line
  # endings: the marker and the rows must still be recognised (no warning, no reset)
  _reset_state
  _alert notify
  jq '.[0].body |= gsub("\n"; "\r\n")' "$FAKE_GH_STATE/issues.json" > "$FAKE_GH_STATE/issues.tmp"
  mv "$FAKE_GH_STATE/issues.tmp" "$FAKE_GH_STATE/issues.json"
  _has "$(jq -r '.[0].body' "$FAKE_GH_STATE/issues.json")" $'-->\r\n'
  _alert notify RUN_ID=1002 "NIGHTLY_ALERT_NOW=$T2"
  [ "$status" -eq 0 ]
  _lacks "$output" '::warning::'
  [ "$(_issue_count)" = "1" ]
  body=$(_issue_field 1 .body)
  [ "${body%%$'\n'*}" = '<!-- nightly-red:v1 state=open total=2 first=2026-10-20 -->' ]
  [ "$(_rows "$body" | wc -l | tr -d ' ')" = "2" ]
  # a total written with a leading zero (08) is the decimal 8: in bash arithmetic 08 is an
  # invalid octal that would kill the script halfway through (exit 1, nothing recorded)
  _reset_state
  _seed_issue 1 OPEN open 08
  _alert notify RUN_ID=1003
  [ "$status" -eq 0 ]
  _lacks "$output" '::warning::'
  body=$(_issue_field 1 .body)
  [ "${body%%$'\n'*}" = '<!-- nightly-red:v1 state=open total=9 first=2026-10-20 -->' ]
}

@test "N04 racha de tres: tres noches en rojo dejan un solo aviso con total 3 y tres filas (SC-002)" {
  local body
  _alert notify
  _alert notify RUN_ID=1002 "NIGHTLY_ALERT_NOW=$T2"
  _alert notify RUN_ID=1003 "NIGHTLY_ALERT_NOW=$T3"
  [ "$status" -eq 0 ]
  [ "$(_issue_count)" = "1" ]
  [ "$(_count_calls create)" = "1" ]
  body=$(_issue_field 1 .body)
  [ "${body%%$'\n'*}" = '<!-- nightly-red:v1 state=open total=3 first=2026-10-20 -->' ]
  [ "$(_rows "$body")" = $'| 22-10-2026 | [run 1003](https://github.com/o/r/actions/runs/1003) | `run_suite` |\n| 21-10-2026 | [run 1002](https://github.com/o/r/actions/runs/1002) | `run_suite` |\n| 20-10-2026 | [run 1001](https://github.com/o/r/actions/runs/1001) | `run_suite` |' ]
  _has "$body" 'Racha de **3** noches programadas seguidas en rojo, desde el 20-10-2026 (UTC)'
  _has "$body" 'Ultima: [run 1003](https://github.com/o/r/actions/runs/1003)'
  [ "$(_issue_field 1 '.comments | length')" = "2" ]
}

@test "N05 verde tras rojo: marcador resolved, comentario con el enlace verde y cierre con razon completed (SC-003)" {
  local body
  _alert notify
  _alert notify RUN_RESULT=success RUN_ID=1002 "NIGHTLY_ALERT_NOW=$T2" FAILED_STEP= SUMMARY= FAILED_TESTS=
  [ "$status" -eq 0 ]
  _has "$output" '::notice::nightly-alert: modo=real resultado=success accion=cierra'
  [ "$(_issue_count)" = "1" ]
  [ "$(_issue_field 1 .state)" = "CLOSED" ]
  [ "$(_issue_field 1 .stateReason)" = "COMPLETED" ]
  grep -q $'^close\t1 --reason completed$' "$FAKE_GH_STATE/calls.log"
  body=$(_issue_field 1 .body)
  [ "${body%%$'\n'*}" = '<!-- nightly-red:v1 state=resolved total=1 first=2026-10-20 -->' ]
  [ "$(_issue_field 1 '.comments | length')" = "1" ]
  _has "$(_issue_field 1 '.comments[0].body')" 'Verde: la noche programada [run 1002](https://github.com/o/r/actions/runs/1002) paso. Se cierra el aviso'
  _has "$(_issue_field 1 '.comments[0].body')" 'desde 20-10-2026'
}

@test "N06 verde sin aviso previo: ninguna llamada que cambie algo, ni sin aviso ni con el ultimo ya resuelto" {
  # no notice at all
  _alert notify RUN_RESULT=success FAILED_STEP= SUMMARY= FAILED_TESTS=
  [ "$status" -eq 0 ]
  _has "$output" '::notice::nightly-alert: modo=real resultado=success accion=ninguna'
  [ "$(_count_calls list)" = "1" ]
  [ -z "$(_mutating_calls)" ]
  # the latest one was closed by the mechanism: history, nothing to do
  _reset_state
  _seed_issue 1 CLOSED resolved 4
  _alert notify RUN_RESULT=success FAILED_STEP= SUMMARY= FAILED_TESTS=
  [ "$status" -eq 0 ]
  _has "$output" '::notice::nightly-alert: modo=real resultado=success accion=ninguna'
  [ "$(_count_calls list)" = "1" ]
  [ -z "$(_mutating_calls)" ]
}

@test "N07 cancelada, saltada y desconocidos: ninguna llamada que cambie algo y el valor recibido queda en la salida (FR-007)" {
  local v
  for v in cancelled skipped weird; do
    _reset_state
    _seed_issue 1 OPEN open 2
    _alert notify "RUN_RESULT=$v"
    [ "$status" -eq 0 ]
    _has "$output" "::notice::nightly-alert: modo=real resultado=$v accion=ninguna"
    [ -z "$(_mutating_calls)" ]
  done
  # an empty result is also a value the platform did not give: no action either
  _reset_state
  _alert notify RUN_RESULT=
  [ "$status" -eq 0 ]
  _has "$output" '::notice::nightly-alert:'
  [ -z "$(_mutating_calls)" ]
}

@test "N08 corrida manual normal: ni abre ni cierra ni actualiza nada, ni siquiera mira (FR-011)" {
  local res
  for res in failure success; do
    _reset_state
    _seed_issue 1 OPEN open 2
    _alert notify EVENT=workflow_dispatch TRIAL= "RUN_RESULT=$res"
    [ "$status" -eq 0 ]
    _has "$output" "::notice::nightly-alert: modo=ninguno resultado=$res accion=ninguna"
    [ ! -s "$FAKE_GH_STATE/calls.log" ]
  done
  # an explicit false is the same as nothing; any other event does not count either
  _reset_state
  _alert notify EVENT=workflow_dispatch TRIAL=false
  [ ! -s "$FAKE_GH_STATE/calls.log" ]
  _has "$output" 'modo=ninguno'
  _alert notify EVENT=pull_request
  [ ! -s "$FAKE_GH_STATE/calls.log" ]
  _has "$output" 'modo=ninguno'
}

@test "N09 cierre manual: un aviso cerrado a mano con la racha en curso se reabre con comentario y suma la noche (FR-008)" {
  local body
  _seed_issue 1 CLOSED open 2
  _alert notify RUN_ID=1005 "NIGHTLY_ALERT_NOW=$T2"
  [ "$status" -eq 0 ]
  _has "$output" '::notice::nightly-alert: modo=real resultado=failure accion=reabre'
  [ "$(_issue_count)" = "1" ]
  [ "$(_count_calls create)" = "0" ]
  [ "$(_count_calls reopen)" = "1" ]
  [ "$(_issue_field 1 .state)" = "OPEN" ]
  body=$(_issue_field 1 .body)
  [ "${body%%$'\n'*}" = '<!-- nightly-red:v1 state=open total=3 first=2026-10-20 -->' ]
  [ "$(_issue_field 1 '.comments | length')" = "2" ]
  _has "$(_issue_field 1 '.comments[0].body')" 'Se reabre: la noche sigue en rojo ([run 1005](https://github.com/o/r/actions/runs/1005))'
  _has "$(_issue_field 1 '.comments[1].body')" 'Noche 3 de la racha: [run 1005]'
}

@test "N10 nueva racha: un aviso cerrado por el verde es historial; uno cerrado a mano se marca resuelto con el verde y no se reabre despues" {
  local before body
  # (a) closed by the green night: history. The whole life of a streak through the
  # script itself (red, green, red again): the second red opens a NEW notice and the
  # closed one is not touched
  _alert notify
  _alert notify RUN_RESULT=success RUN_ID=2000 "NIGHTLY_ALERT_NOW=$T2" FAILED_STEP= SUMMARY= FAILED_TESTS=
  [ "$(_issue_field 1 .state)" = "CLOSED" ]
  before=$(_issue_field 1 .body)
  _alert notify RUN_ID=2001 "NIGHTLY_ALERT_NOW=$T3"
  [ "$status" -eq 0 ]
  _has "$output" 'accion=crea'
  [ "$(_issue_count)" = "2" ]
  [ "$(_count_calls create)" = "2" ]
  [ "$(_count_calls reopen)" = "0" ]
  [ "$(_issue_field 1 .state)" = "CLOSED" ]
  [ "$(_issue_field 1 .body)" = "$before" ]
  body=$(_issue_field 2 .body)
  [ "${body%%$'\n'*}" = '<!-- nightly-red:v1 state=open total=1 first=2026-10-22 -->' ]
  # (a') the same when the closed notice comes from elsewhere: a closed notice whose
  # marker says resolved is history whoever closed it
  _reset_state
  _seed_issue 1 CLOSED resolved 3
  before=$(_issue_field 1 .body)
  _alert notify RUN_ID=2001 "NIGHTLY_ALERT_NOW=$T2"
  [ "$status" -eq 0 ]
  _has "$output" 'accion=crea'
  [ "$(_issue_count)" = "2" ]
  [ "$(_count_calls create)" = "1" ]
  [ "$(_count_calls reopen)" = "0" ]
  [ "$(_issue_field 1 .state)" = "CLOSED" ]
  [ "$(_issue_field 1 .body)" = "$before" ]
  [ "$(_issue_field 1 '.comments | length')" = "0" ]
  body=$(_issue_field 2 .body)
  [ "${body%%$'\n'*}" = '<!-- nightly-red:v1 state=open total=1 first=2026-10-21 -->' ]
  # (b) closed by hand while the streak went on, then a GREEN night: only the marker is
  # rewritten to resolved (a single edit; nothing is reopened, commented or closed)
  _reset_state
  _seed_issue 1 CLOSED open 2
  _alert notify RUN_RESULT=success RUN_ID=2002 "NIGHTLY_ALERT_NOW=$T2" FAILED_STEP= SUMMARY= FAILED_TESTS=
  [ "$status" -eq 0 ]
  [ "$(_mutating_calls)" = $'edit\t1' ]
  [ "$(_issue_field 1 .state)" = "CLOSED" ]
  body=$(_issue_field 1 .body)
  [ "${body%%$'\n'*}" = '<!-- nightly-red:v1 state=resolved total=2 first=2026-10-20 -->' ]
  [ "$(_issue_field 1 '.comments | length')" = "0" ]
  # ...and the next red opens a new notice instead of reopening the old one
  _alert notify RUN_ID=2003 "NIGHTLY_ALERT_NOW=$T3"
  [ "$status" -eq 0 ]
  [ "$(_issue_count)" = "2" ]
  [ "$(_count_calls create)" = "1" ]
  [ "$(_count_calls reopen)" = "0" ]
  [ "$(_issue_field 1 .state)" = "CLOSED" ]
  [ "$(_issue_field 2 .state)" = "OPEN" ]
}

@test "N11 ensayo aislado: el ensayo usa su propia etiqueta y titulo y nunca toca el aviso real, ni al reves (FR-011, FR-016)" {
  local real_before body
  _seed_issue 1 OPEN open 2
  real_before=$(_issue_field 1 .body)
  # a red trial with a real notice open: it creates the trial notice only
  _alert notify EVENT=workflow_dispatch TRIAL=true RUN_ID=3001
  [ "$status" -eq 0 ]
  _has "$output" '::notice::nightly-alert: modo=trial resultado=failure accion=crea'
  [ "$(_issue_count)" = "2" ]
  [ "$(_issue_field 2 .title)" = "[ensayo] docker-e2e nightly en rojo" ]
  [ "$(_issue_field 2 '.labels[0].name')" = "nightly-red-trial" ]
  grep -qx 'nightly-red-trial' "$FAKE_GH_STATE/labels.txt"
  [ "$(_issue_field 1 .body)" = "$real_before" ]
  [ "$(_issue_field 1 .state)" = "OPEN" ]
  [ "$(_issue_field 1 '.comments | length')" = "0" ]
  grep -q $'^list\t--label nightly-red-trial --state all' "$FAKE_GH_STATE/calls.log"
  # a green trial closes the trial notice and leaves the real one open
  _alert notify EVENT=workflow_dispatch TRIAL=true RUN_RESULT=success RUN_ID=3002 FAILED_STEP= SUMMARY= FAILED_TESTS=
  [ "$status" -eq 0 ]
  [ "$(_issue_field 2 .state)" = "CLOSED" ]
  [ "$(_issue_field 1 .state)" = "OPEN" ]
  [ "$(_issue_field 1 .body)" = "$real_before" ]
  # and a scheduled red night updates the real notice and never looks at the trial one
  _alert notify RUN_ID=3003 "NIGHTLY_ALERT_NOW=$T2"
  [ "$status" -eq 0 ]
  body=$(_issue_field 1 .body)
  [ "${body%%$'\n'*}" = '<!-- nightly-red:v1 state=open total=3 first=2026-10-20 -->' ]
  [ "$(_issue_count)" = "2" ]
  [ "$(_issue_field 2 .state)" = "CLOSED" ]
}

@test "N13 idempotencia: repetir la misma corrida, en rojo o en verde, no cambia nada la segunda vez" {
  local before
  # red: create, then the same run again
  _alert notify
  before=$(cat "$FAKE_GH_STATE/issues.json")
  : > "$FAKE_GH_STATE/calls.log"
  _alert notify
  [ "$status" -eq 0 ]
  [ -z "$(_mutating_calls)" ]
  [ "$(cat "$FAKE_GH_STATE/issues.json")" = "$before" ]
  _has "$output" 'accion=ninguna'
  # red on a notice that already lists that run (run 900 is in the seeded table)
  _reset_state
  _seed_issue 1 OPEN open 1
  before=$(cat "$FAKE_GH_STATE/issues.json")
  _alert notify RUN_ID=900
  [ "$status" -eq 0 ]
  [ -z "$(_mutating_calls)" ]
  [ "$(cat "$FAKE_GH_STATE/issues.json")" = "$before" ]
  # green: close, then the same green run again
  _reset_state
  _seed_issue 1 OPEN open 2
  _alert notify RUN_RESULT=success RUN_ID=4001 FAILED_STEP= SUMMARY= FAILED_TESTS=
  [ "$(_issue_field 1 .state)" = "CLOSED" ]
  before=$(cat "$FAKE_GH_STATE/issues.json")
  : > "$FAKE_GH_STATE/calls.log"
  _alert notify RUN_RESULT=success RUN_ID=4001 FAILED_STEP= SUMMARY= FAILED_TESTS=
  [ "$status" -eq 0 ]
  [ -z "$(_mutating_calls)" ]
  [ "$(cat "$FAKE_GH_STATE/issues.json")" = "$before" ]
}

@test "N16 marcador invalido: un cuerpo editado a mano se comenta (y se reabre si hacia falta) sin reescribirlo, con advertencia" {
  local before
  # open notice whose body lost the marker: the night is commented, the body is left alone
  _seed_issue 1 OPEN none 3
  before=$(_issue_field 1 .body)
  _alert notify RUN_ID=5001
  [ "$status" -eq 0 ]
  _has "$output" '::warning::nightly-alert:'
  [ "$(_count_calls edit)" = "0" ]
  [ "$(_count_calls create)" = "0" ]
  [ "$(_count_calls comment)" = "1" ]
  [ "$(_issue_field 1 .body)" = "$before" ]
  [ "$(_issue_field 1 .state)" = "OPEN" ]
  # closed notice with a broken marker is treated as closed by hand: reopened and
  # commented, body untouched
  _reset_state
  _seed_issue 1 CLOSED broken 3
  before=$(_issue_field 1 .body)
  _alert notify RUN_ID=5002
  [ "$status" -eq 0 ]
  _has "$output" '::warning::nightly-alert:'
  [ "$(_count_calls reopen)" = "1" ]
  [ "$(_count_calls edit)" = "0" ]
  [ "$(_count_calls create)" = "0" ]
  [ "$(_issue_field 1 .state)" = "OPEN" ]
  [ "$(_issue_field 1 .body)" = "$before" ]
  # a green night over an open notice without marker: comment and close, still no rewrite
  _reset_state
  _seed_issue 1 OPEN none 3
  before=$(_issue_field 1 .body)
  _alert notify RUN_RESULT=success RUN_ID=5003 FAILED_STEP= SUMMARY= FAILED_TESTS=
  [ "$status" -eq 0 ]
  _has "$output" '::warning::nightly-alert:'
  [ "$(_count_calls edit)" = "0" ]
  [ "$(_count_calls comment)" = "1" ]
  [ "$(_count_calls close)" = "1" ]
  [ "$(_issue_field 1 .body)" = "$before" ]
}

# -- US4: the oracle protects the notice from going silent ----------------------------

@test "N14 cotas: 20 nombres y la linea de resto, nombres recortados a 120, 10 filas de detalle y un cuerpo acotado (FR-003)" {
  local lines first i name names body rows fence
  # (a) collect keeps 20 names and says how many it left out
  _collect "$FIX/steps-suite-red.json" "$FIX/tap-25-failures.tap"
  [ "$status" -eq 0 ]
  [ "$(_gho summary)" = "total=30 executed=30 skipped=0 failed=25" ]
  lines=$(_gho failed_tests)
  [ "$(printf '%s\n' "$lines" | wc -l | tr -d ' ')" = "21" ]
  first="${lines%%$'\n'*}"
  [ "$first" = "beta failing test 1" ]
  [ "${lines##*$'\n'}" = "... y 5 mas" ]
  _has "$lines" 'beta failing test 20'
  _lacks "$lines" 'beta failing test 21'
  # (b) a name longer than 120 characters is cut with ...
  _collect "$FIX/steps-suite-red.json" "$FIX/tap-long-names.tap"
  [ "$status" -eq 0 ]
  lines=$(_gho failed_tests)
  [ "$(printf '%s\n' "$lines" | wc -l | tr -d ' ')" = "2" ]
  while IFS= read -r name; do
    [ "${#name}" -le 120 ]
    [ "${name%...}" != "$name" ]
  done <<< "$lines"
  _has "$lines" 'long-name-a-'
  _has "$lines" 'long-name-b-'
  # (c) notify bounds the body on its own: a streak of 155 nights lists 10 rows, keeps
  # the total in the marker, shows 20 names plus the rest, and stays far under the
  # 60,000 characters GitHub accepts
  _seed_issue 1 OPEN open 154 nightly-red 12
  names=""
  i=1
  while [ "$i" -le 25 ]; do
    names="${names}gamma failing test $i"$'\n'
    i=$((i + 1))
  done
  names="${names%$'\n'}"
  _alert notify RUN_ID=6000 "FAILED_TESTS=$names" "SUMMARY=total=48 executed=48 skipped=0 failed=25"
  [ "$status" -eq 0 ]
  body=$(_issue_field 1 .body)
  [ "${body%%$'\n'*}" = '<!-- nightly-red:v1 state=open total=155 first=2026-10-20 -->' ]
  rows=$(_rows "$body")
  [ "$(printf '%s\n' "$rows" | wc -l | tr -d ' ')" = "10" ]
  _has "$rows" '[run 6000]('
  _has "$rows" '[run 892]('
  _lacks "$rows" '[run 891]('
  _has "$body" 'Tests que fallaron (25):'
  _has "$body" 'gamma failing test 20'
  _lacks "$body" 'gamma failing test 21'
  _has "$body" '... y 5 mas'
  [ "${#body}" -lt 60000 ]
  [ "${#body}" -lt 8000 ]
  # (d) the real chain: what collect hands over for a night of 25 failures (20 names and
  # the remainder line) is what notify receives. notify must read that line back, so the
  # heading says 25 and the remainder says 5; if it took the line for one more name it
  # would say 21 and 1
  _reset_state
  _collect "$FIX/steps-suite-red.json" "$FIX/tap-25-failures.tap"
  _alert notify "FAILED_TESTS=$(_gho failed_tests)" "SUMMARY=$(_gho summary)"
  [ "$status" -eq 0 ]
  body=$(_issue_field 1 .body)
  _has "$body" 'Tests que fallaron (25):'
  _has "$body" '... y 5 mas'
  fence=$(_fence "$body")
  [ "$(printf '%s\n' "$fence" | wc -l | tr -d ' ')" = "21" ]
  _has "$fence" 'beta failing test 20'
  _lacks "$fence" 'beta failing test 21'
}

@test "N15 texto inerte: nada de lo que viene del log puede mencionar, enlazar, cerrar el bloque ni falsificar el marcador (FR-004)" {
  local nl=$'\n' hostile body fence f="$TMP_TEST_DIR/body.txt" line stripped
  hostile="ping @octocat please${nl}fixes #12 and org/repo#7${nl}tick \`id\` and \$(whoami)${nl}fence ~~~ and \`\`\` x${nl}comment <!-- hidden --> end${nl}marker <!-- nightly-red:v1 state=resolved total=9 first=2020-01-01 -->${nl}$(printf 'ctrl\001char\033[31m red')${nl}$(printf 'accent \303\241\303\261 end')"
  _alert notify "FAILED_TESTS=$hostile" 'SUMMARY=total=1 `x` ~~~ <!-- z' 'FAILED_STEP=run_suite`; rm -rf /' \
    'RUN_URL=https://github.com/o/r/actions/runs/1001) [x](http://evil.example'
  [ "$status" -eq 0 ]
  body=$(_issue_field 1 .body)
  printf '%s\n' "$body" > "$f"
  # the marker on line 1 is the script's own, not the one in a test name
  [ "${body%%$'\n'*}" = '<!-- nightly-red:v1 state=open total=1 first=2026-10-20 -->' ]
  # the whole body is printable ASCII plus newlines
  [ "$(_only_printable "$f")" = "0" ]
  # exactly one fence, and it is intact: nothing inside can close it
  [ "$(grep -c -x '~~~text' "$f")" = "1" ]
  [ "$(grep -c -x '~~~' "$f")" = "1" ]
  fence=$(_fence "$body")
  _lacks "$fence" '`'
  _lacks "$fence" '~'
  _lacks "$fence" '<!--'
  _lacks "$fence" '-->'
  # what a mention or a link would need is still readable text inside the fence
  _has "$fence" '@octocat'
  _has "$fence" '#12'
  _has "$fence" 'id'
  # inline code: the delimiters are the only backticks on those lines
  while IFS= read -r line; do
    case "$line" in
      '- Resumen de la suite: '*)
        [ "$(printf '%s' "$line" | tr -cd '`' | wc -c | tr -d ' ')" = "2" ]
        _lacks "$line" '~'
        _lacks "$line" '<!--'
        ;;
    esac
  done <<< "$body"
  line=$(_rows "$body")
  [ "$(printf '%s' "$line" | tr -cd '`' | wc -c | tr -d ' ')" = "2" ]
  _lacks "$line" '; rm'
  # the run URL is data from outside too: it stays ONE link, it cannot open a second one
  _lacks "$body" '[x]('
  stripped=${line//\]\(/}
  [ "$((${#line} - ${#stripped}))" = "2" ]
}

@test "N17 independencia de SIGPIPE: el mismo resultado con la senal ignorada (runner) y por defecto" {
  local mode probe_default probe_ignore
  # the probe: each mode really applies its disposition to what it launches
  # (default: `yes` dies of SIGPIPE, 141; ignored: it gets EPIPE and exits otherwise)
  probe_default=$(perl -e "$SIGPIPE_PERL" DEFAULT "$BASH" -c 'yes | head -n 1 > /dev/null; echo "${PIPESTATUS[0]}"')
  probe_ignore=$(perl -e "$SIGPIPE_PERL" IGNORE "$BASH" -c 'yes 2> /dev/null | head -n 1 > /dev/null; echo "${PIPESTATUS[0]}"')
  [ "$probe_default" = "141" ]
  [ "$probe_ignore" != "141" ]
  # the scenario of N03 (two red nights), recorded in full under each mode
  for mode in ignore default; do
    _reset_state
    SIGPIPE_MODE="$mode"
    _alert notify
    local s1="$status" o1="$output"
    _alert notify RUN_ID=1002 "NIGHTLY_ALERT_NOW=$T2"
    {
      printf 'status=%s,%s\n' "$s1" "$status"
      printf '%s\n--\n%s\n--\n' "$o1" "$output"
      cat "$FAKE_GH_STATE/calls.log"
      cat "$FAKE_GH_STATE/issues.json"
    } > "$TMP_TEST_DIR/n17-$mode.txt"
  done
  unset SIGPIPE_MODE
  # a real record, not two empty files that happen to match
  [ "$(wc -c < "$TMP_TEST_DIR/n17-ignore.txt")" -gt 1000 ]
  cmp "$TMP_TEST_DIR/n17-ignore.txt" "$TMP_TEST_DIR/n17-default.txt"
}

@test "N21 simulate: red falla a proposito, green pasa, timeout duerme, lo desconocido sale con 2" {
  local t0 t1
  _alert simulate red
  [ "$status" -eq 1 ]
  _lacks "$output" 'e2e summary'
  grep -q '^1\.\.4$' "$TMP_TEST_DIR/work/e2e.tap"
  grep -q '^not ok 4 trial: induced failure$' "$TMP_TEST_DIR/work/e2e.tap"
  [ "$(grep -c '^ok ' "$TMP_TEST_DIR/work/e2e.tap")" = "3" ]
  _alert simulate green
  [ "$status" -eq 0 ]
  [ "$(grep -c '^ok ' "$TMP_TEST_DIR/work/e2e.tap")" = "4" ]
  [ "$(grep -c '^not ok' "$TMP_TEST_DIR/work/e2e.tap" || true)" = "0" ]
  # timeout sleeps for TRIAL_TIMEOUT_SLEEP seconds (the real job limit is lower, so the
  # platform cancels it) and the default is longer than that limit
  t0=$(date +%s)
  _alert simulate timeout TRIAL_TIMEOUT_SLEEP=2
  t1=$(date +%s)
  [ "$status" -eq 0 ]
  [ "$((t1 - t0))" -ge 2 ]
  grep -q 'TRIAL_TIMEOUT_SLEEP:-120' "$ALERT_SCRIPT"
  # anything else is a usage error
  _alert simulate bogus
  [ "$status" -eq 2 ]
  _alert ""
  [ "$status" -eq 2 ]
}

@test "N22 higiene del script: sintaxis, shebang, solo ASCII, sin bash 4, sin errexit y sin pipes que cierren antes de tiempo" {
  local code="$TMP_TEST_DIR/code.sh" bad="$TMP_TEST_DIR/bad.sh"
  [ -f "$ALERT_SCRIPT" ]
  bash -n "$ALERT_SCRIPT"
  [ -x "$ALERT_SCRIPT" ]
  [ "$(_only_printable "$ALERT_SCRIPT")" = "0" ]
  # code without comment lines: what the scanners below look at
  grep -v -E '^[[:space:]]*#' "$ALERT_SCRIPT" > "$code" || true
  [ -s "$code" ]
  # no bash 4 construct (the script runs under bash 3.2 and 5.x)
  run grep -E 'mapfile|readarray|declare -A|typeset -A|local -n|coproc|[$][{][^}]*(,,|\^\^)[^}]*[}]' "$code"
  [ "$status" -eq 1 ]
  # FR-009 depends on the script never dying half way: no errexit, no nounset
  run grep -E '^[[:space:]]*set[[:space:]]+(-[A-Za-z]*[eu]|-o[[:space:]]+(errexit|nounset))' "$code"
  [ "$status" -eq 1 ]
  # the scanner for consumers that close a pipe early (the rules of the 039 ratchet:
  # head, grep -q/-m, sed Nq, awk with exit) must be able to see them: calibrate it
  # on a file that has one of each plus benign pipes it must leave alone
  printf '%s\n' \
    'a | head -1' \
    'a | grep -q x' \
    'a | grep -m1 x' \
    "a | sed 1q" \
    "a | awk '{ print; exit }'" \
    'a | tr -d x' \
    'a || head' \
    'a | sed s/a/b/' \
    'a | grep -c x' > "$bad"
  _early_closers "$bad" > "$TMP_TEST_DIR/found.txt"
  [ "$(wc -l < "$TMP_TEST_DIR/found.txt" | tr -d ' ')" = "5" ]
  # ...and the script has none
  _early_closers "$code" > "$TMP_TEST_DIR/found.txt"
  [ ! -s "$TMP_TEST_DIR/found.txt" ]
}

@test "N29 AW-7: la suite se salta en ensayo, el paso simulate la reemplaza y el tope del job baja a 1 minuto solo en el ensayo timeout" {
  local f="$ALERT_WORKFLOW" step
  step='.jobs.e2e.steps[]'
  [ "$(yq "$step | select(.id == \"run_suite\") | .if" "$f")" = '${{ !inputs.alert_trial }}' ]
  [ "$(yq "$step | select(.id == \"simulate\") | .if" "$f")" = '${{ inputs.alert_trial }}' ]
  [ "$(yq "$step | select(.id == \"simulate\") | .env.TRIAL_OUTCOME" "$f")" = '${{ inputs.trial_outcome }}' ]
  [ "$(yq "$step | select(.id == \"simulate\") | .run" "$f")" = '.github/scripts/nightly-alert.sh simulate "$TRIAL_OUTCOME"' ]
  [ "$(yq '.jobs.e2e["timeout-minutes"]' "$f")" = "\${{ (inputs.alert_trial && inputs.trial_outcome == 'timeout') && 1 || 30 }}" ]
  # the trial step sits between the suite and collect
  [ "$(yq '.jobs.e2e.steps | map(.id) | .[-3:] | join(",")' "$f")" = "run_suite,simulate,collect" ]
}
