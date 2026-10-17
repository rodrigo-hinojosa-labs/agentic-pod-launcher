#!/usr/bin/env bats
# 041-nightly-qmd-embed: host oracle for the qmd embed phase of the nightly.
#
# Contract: specs/041-nightly-qmd-embed/contracts/host-oracle.md
#   W  structure of the workflow (static, with yq)
#   F  the fetch script (a fake curl, plus one leg with the real curl on 127.0.0.1)
#   V  vec0-libc.sh, the libc check of the vector extension
#   K  the skip semantics of the real test (a nested bats, docker and curl stubbed)
#   G  identity guards (the model table, the qmd pin, the upgrade checklist)
#   P  the phase marks of the real test, and what its teardown and workspace leave behind
#
# Why it exists: the nightly passed `qmd real (016)` without ever running its embed
# phase, and nothing in the host suite could see it. A check that cannot fail is not
# evidence, so every test here has a mutation that turns it red
# (specs/041-nightly-qmd-embed/quickstart.md section 3).
#
# Rules this file lives by (it is the code that enforces them):
#   - bash 3.2 and 5.x: no mapfile, no associative arrays, no ${v,,}.
#   - no network: the only real curl talks to 127.0.0.1. Nothing here reaches Docker.
#   - never `producer | head` / `producer | grep -q`: assertions on $output use
#     case/grep on a here-string, never a pipe that can close early.
#   - a negative assertion is `_lacks` or `run ...; [ "$status" -ne 0 ]`, never an
#     intermediate `!`, which bats does not turn into a failure; no intermediate [[ ]].
#   - a background process (the local HTTP server) is started with fds 3 and 4 closed,
#     or bats waits for it forever, and is stopped in teardown.
#   - nothing big travels through argv or the environment: models are files.

load helper

# `run --separate-stderr` needs bats 1.5; CI installs 1.11.
bats_require_minimum_version 1.5.0

WF_FILE="$REPO_ROOT/.github/workflows/docker-e2e.yml"
FETCH="$REPO_ROOT/.github/scripts/fetch-qmd-models.sh"
FAKE_CURL="$REPO_ROOT/tests/fixtures/qmd-e2e/fake-curl"
VEC0="$REPO_ROOT/tests/fixtures/qmd-e2e/vec0-libc.sh"
E2E_FILE="$REPO_ROOT/tests/docker-e2e-qmd.bats"
UPGRADE_DOC="$REPO_ROOT/docs/qmd-upgrade-checklist.md"

# sha256 of the `run:` text of the two steps 039 froze (research M13). Same bytes
# with yq 4.44.3 (the CI) and 4.52.5.
SHA_VERIFY=22d71bf880487e37158734312834a7c7d56b504c111b2ffe5f5f84a7a35e2abc
SHA_SUITE=8c473b2e742d763a49bccd64d785305f3ba059d6087172d81af12ba1b120ca08

setup() {
  setup_tmp_dir
  SRV_PID=""
  GH_ENV_FILE="$TMP_TEST_DIR/github.env"
  FAKE_CURL_LOG="$TMP_TEST_DIR/curl.log"
  FAKE_SLEEP_LOG="$TMP_TEST_DIR/sleep.log"
  FAKE_CURL_PLAN=""
  : > "$GH_ENV_FILE"
  : > "$FAKE_CURL_LOG"
  : > "$FAKE_SLEEP_LOG"
  _mk_stubs
}

teardown() {
  _http_down
  teardown_tmp_dir
}

# ── harness ──────────────────────────────────────────────────────────────────

# _has TEXT NEEDLE / _lacks TEXT NEEDLE: substring assertions with no pipe.
_has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
_lacks() { ! _has "$1" "$2"; }

# _sha256_stdin / _sha256_file FILE: the hex digest, with whichever tool the host has.
_sha256_stdin() {
  local h
  if command -v sha256sum >/dev/null 2>&1; then h=$(sha256sum); else h=$(shasum -a 256); fi
  printf '%s\n' "${h%% *}"
}
_sha256_file() {
  local h
  if command -v sha256sum >/dev/null 2>&1; then h=$(sha256sum "$1"); else h=$(shasum -a 256 "$1"); fi
  printf '%s\n' "${h%% *}"
}

# _step_n FILE JOB NAME: how many steps of JOB are called NAME.
_step_n() { NAME="$3" yq ".jobs.${2}.steps | map(select(.name == strenv(NAME))) | length" "$1"; }

# _step_get FILE JOB NAME EXPR: print EXPR evaluated on the step called NAME. The step
# must match exactly once, or this fails with a message that says why: an oracle that
# cannot find its subject must not pass (the same rule as _extract_run in 039).
_step_get() {
  local n
  n=$(_step_n "$1" "$2" "$3") || return 1
  if [ "$n" != "1" ]; then
    echo "_step_get: step '$3' matched $n times in $(basename "$1") job '$2' (expected exactly 1)" >&2
    return 1
  fi
  NAME="$3" yq ".jobs.${2}.steps[] | select(.name == strenv(NAME)) | ${4}" "$1"
}

# _ascii_clean TEXT: succeed only when TEXT is printable ASCII (and newlines).
_ascii_clean() {
  local f="$TMP_TEST_DIR/ascii.chk" n
  printf '%s\n' "$1" > "$f"
  n=$(LC_ALL=C grep -c '[^ -~]' "$f" || true)
  [ "$n" = "0" ]
}

# _mk_fake_models: two small fake models, the alternate table that describes them and
# the tree a local HTTP server serves. Sets SRV (document root), M1_FILE, M2_FILE,
# M1_BYTES, M2_BYTES, M1_SHA, M2_SHA and TABLE. The names follow the local-name rule
# of data-model section 1 (hf_<user>_<file> when the file starts with the repo name).
_mk_fake_models() {
  SRV="$TMP_TEST_DIR/srv"
  local d1="$SRV/acme/fakeembed-GGUF/resolve/main" d2="$SRV/acme/fakeexpand-GGUF/resolve/main"
  mkdir -p "$d1" "$d2"
  M1_FILE="$d1/fakeembed-Q8.gguf"
  M2_FILE="$d2/fakeexpand-q4.gguf"
  printf 'embed-model-%0990d' 0 > "$M1_FILE"
  printf 'expand-model-%01990d' 0 > "$M2_FILE"
  M1_BYTES=$(( $(wc -c < "$M1_FILE") ))
  M2_BYTES=$(( $(wc -c < "$M2_FILE") ))
  M1_SHA=$(_sha256_file "$M1_FILE")
  M2_SHA=$(_sha256_file "$M2_FILE")
  TABLE="$TMP_TEST_DIR/fake.table"
  printf '%s\n' \
    "embed|acme/fakeembed-GGUF|fakeembed-Q8.gguf|hf_acme_fakeembed-Q8.gguf|$M1_BYTES|$M1_SHA" \
    "expand|acme/fakeexpand-GGUF|fakeexpand-q4.gguf|hf_acme_fakeexpand-q4.gguf|$M2_BYTES|$M2_SHA" > "$TABLE"
}

# _mk_stubs: the two directories a run of the fetch script puts in front of PATH. The
# sleep stub records its argument and returns at once, so the default back-off (10 and
# 30 s) can be asserted without waiting for it; the curl stub is the fake curl.
_mk_stubs() {
  STUB_SLEEP="$TMP_TEST_DIR/stub-sleep"
  STUB_CURL="$TMP_TEST_DIR/stub-curl"
  mkdir -p "$STUB_SLEEP" "$STUB_CURL"
  cat > "$STUB_SLEEP/sleep" <<'STUB'
#!/bin/sh
# Fake sleep (041 oracle): records its argument and returns at once.
printf '%s\n' "${1:-}" >> "${FAKE_SLEEP_LOG:-/dev/null}"
exit 0
STUB
  chmod +x "$STUB_SLEEP/sleep"
  cp "$FAKE_CURL" "$STUB_CURL/curl"
  chmod +x "$STUB_CURL/curl"
}

# _run_fetch [VAR=value ...]: run the fetch script the way the workflow does: a clean
# environment, the script executed through its shebang (so a missing exec bit fails
# here too), the stub directories in front of PATH. USE_FAKE_CURL=0 leaves the real
# curl; GH_ENV_FILE="" runs without GITHUB_ENV. Leaves $status, $output and $stderr,
# and asserts that both streams are printable ASCII on every run.
_run_fetch() {
  local path="$STUB_SLEEP"
  if [ "${USE_FAKE_CURL:-1}" = "1" ]; then path="$STUB_CURL:$path"; fi
  local -a envv
  envv=("PATH=$path:$PATH" "HOME=$TMP_TEST_DIR" "TMPDIR=$TMP_TEST_DIR" \
        "RUNNER_TEMP=$TMP_TEST_DIR/runner-temp" "FAKE_CURL_LOG=$FAKE_CURL_LOG" \
        "FAKE_CURL_PLAN=${FAKE_CURL_PLAN:-}" "FAKE_SLEEP_LOG=$FAKE_SLEEP_LOG")
  if [ -n "${GH_ENV_FILE:-}" ]; then envv+=("GITHUB_ENV=$GH_ENV_FILE"); fi
  run --separate-stderr env -i "${envv[@]}" "$@" "$FETCH"
  _ascii_clean "$output"
  _ascii_clean "$stderr"
}

# _http_up: serve $SRV on 127.0.0.1 at a port the kernel picks; sets SRV_PORT and
# SRV_PID. Fds 3 and 4 are closed in the child (see the header).
_http_up() {
  local log="$TMP_TEST_DIR/http.log" i=0
  python3 -u -m http.server 0 --bind 127.0.0.1 --directory "$SRV" > "$log" 2>&1 3>&- 4>&- &
  SRV_PID=$!
  SRV_PORT=""
  while [ "$i" -lt 100 ]; do
    SRV_PORT=$(sed -n 's/^.*port \([0-9][0-9]*\).*$/\1/p' "$log")
    if [ -n "$SRV_PORT" ]; then return 0; fi
    sleep 0.1
    i=$((i + 1))
  done
  echo "_http_up: the server did not report its port" >&2
  return 1
}

_http_down() {
  if [ -n "${SRV_PID:-}" ]; then
    kill "$SRV_PID" 2>/dev/null || true
    wait "$SRV_PID" 2>/dev/null || true
    SRV_PID=""
  fi
}

# _k_stubs: a docker and a curl that record the call and fail. A closed gate must never
# reach either of them, so the log has to stay empty (section K).
_k_stubs() {
  K_STUBS="$TMP_TEST_DIR/k-stubs"
  K_LOG="$TMP_TEST_DIR/k-stubs.log"
  local t
  mkdir -p "$K_STUBS" "$TMP_TEST_DIR/ktmp"
  : > "$K_LOG"
  for t in docker curl; do
    cat > "$K_STUBS/$t" <<STUB
#!/bin/sh
echo "$t \$*" >> "$K_LOG"
exit 99
STUB
    chmod +x "$K_STUBS/$t"
  done
}

# _real_bats: the path of the `bats` LAUNCHER. A running bats puts its own libexec
# directory first in PATH, and the `bats` found there is the inner script, which needs a
# function only the launcher exports: started through PATH from a clean environment it
# dies with "bats_readlinkf: command not found". So the launcher is looked up skipping
# that directory.
_real_bats() {
  local p IFS=:
  for p in $PATH; do
    if [ "$p" = "${BATS_LIBEXEC:-}" ]; then continue; fi
    if [ -x "$p/bats" ]; then printf '%s\n' "$p/bats"; return 0; fi
  done
  echo "_real_bats: no bats launcher found in PATH" >&2
  return 1
}

# _run_k [VAR=value ...]: run ONLY the 041 test of tests/docker-e2e-qmd.bats in a nested
# bats, in a clean environment, with DOCKER_E2E=1 and the stubs in front of PATH.
# --print-output-on-failure so the message of a failing gate reaches $output.
_run_k() {
  local bats_bin
  bats_bin=$(_real_bats)
  run env -i "PATH=$K_STUBS:$PATH" "HOME=$TMP_TEST_DIR" "TMPDIR=$TMP_TEST_DIR/ktmp" DOCKER_E2E=1 "$@" \
    "$bats_bin" --tap --print-output-on-failure "$E2E_FILE" -f 'qmd real \(041\)'
}

# ── K: the skip semantics of the real test (FR-005, FR-006, FR-014) ───────────

@test "K1: with the gate closed the 041 test is skipped with the default reason and never reaches docker or curl" {
  _k_stubs
  _run_k
  _has "$output" "ok 1 qmd real (041): embed phase"
  _has "$output" "# skip"
  _has "$output" "QMD_EMBED_E2E=1"
  _has "$output" ".github/scripts/fetch-qmd-models.sh"
  [ ! -s "$K_LOG" ]
  # the gate opens on the value 1 and on nothing else: 0 and the empty string are closed too
  local v
  for v in 0 ""; do
    _run_k "QMD_EMBED_E2E=$v"
    _has "$output" "ok 1 qmd real (041): embed phase"
    _has "$output" "# skip embed phase needs QMD_EMBED_E2E=1"
    [ ! -s "$K_LOG" ]
  done
}

@test "K2: QMD_EMBED_SKIP_REASON turns the test into a skip that carries that reason, before any docker call" {
  _k_stubs
  _run_k QMD_EMBED_E2E=1 "QMD_EMBED_SKIP_REASON=fase apagada #123"
  _has "$output" "ok 1 qmd real (041): embed phase"
  _has "$output" "# skip fase apagada #123"
  [ ! -s "$K_LOG" ]
  # a reason shows when the gate is closed as well: the skip of a night with an open defect
  # must not depend on how the gate was closed
  _run_k QMD_EMBED_E2E=0 "QMD_EMBED_SKIP_REASON=fase apagada #123"
  _has "$output" "# skip fase apagada #123"
  [ ! -s "$K_LOG" ]
}

@test "K3: the gate open without QMD_E2E_MODELS_DIR is a harness error that names the variable, not a skip" {
  _k_stubs
  _run_k QMD_EMBED_E2E=1
  _has "$output" "not ok 1 qmd real (041): embed phase"
  _has "$output" "QMD_E2E_MODELS_DIR"
  _lacks "$output" "# skip"
  [ ! -s "$K_LOG" ]
}

@test "K4: qmd real (016) keeps its name and loses the embed gate, and the 041 test is the next one in the file" {
  local name n body next
  name='@test "qmd real (016): native deps compile with toolchain; RED without it (SC-003)" {'
  n=$(grep -c -F -x -- "$name" "$E2E_FILE" || true)
  [ "$n" = "1" ]
  body=$(awk '/^@test "qmd real \(016\)/{f=1; next} /^@test /{f=0} f{print}' "$E2E_FILE")
  [ -n "$body" ]
  _lacks "$body" "QMD_EMBED_E2E"
  next=$(awk '/^@test "qmd real \(016\)/{s=1; next} s && /^@test /{print; exit}' "$E2E_FILE")
  _has "$next" "qmd real (041): embed phase"
}

# ── F: the fetch script (FR-007 to FR-012) ───────────────────────────────────

# _plan RULE...: write the fake curl plan, one rule per argument (host-oracle section 2).
_plan() {
  printf '%s\n' "$@" > "$TMP_TEST_DIR/curl.plan"
  FAKE_CURL_PLAN="$TMP_TEST_DIR/curl.plan"
}

# _calls PATTERN: how many curl calls went to a URL that matches PATTERN.
_calls() { grep -c "^http.*$1" "$FAKE_CURL_LOG" || true; }

# _ncalls: how many curl calls there were in total (the fake curl closes each one with a
# line of three dashes). Not `_calls http`: that pattern needs "http" twice in one line, so
# it counts zero even when curl was called, and an assertion of zero on it can never fail.
_ncalls() { grep -c '^---$' "$FAKE_CURL_LOG" || true; }

# _env_value KEY: the value GITHUB_ENV got for KEY (empty when it did not).
_env_value() { sed -n "s/^${1}=//p" "$GH_ENV_FILE"; }

# The two seams every F test with the fake curl needs: a local base URL that is only
# validated (nothing listens on it) and the alternate table of the fake models.
_fake_seams() { FSEAMS=("QMD_MODELS_BASE_URL=http://127.0.0.1:9" "QMD_MODELS_TABLE=$TABLE"); }

@test "F1: two models that are served fine -> rc 0, the dir in GITHUB_ENV, verified files and the log lines of FR-011" {
  _mk_fake_models; _fake_seams
  _plan "fakeembed|*|ok:$M1_FILE" "fakeexpand|*|ok:$M2_FILE"
  _run_fetch "${FSEAMS[@]}"
  [ "$status" -eq 0 ]
  local dir="$TMP_TEST_DIR/runner-temp/qmd-models"
  [ "$(cat "$GH_ENV_FILE")" = "QMD_E2E_MODELS_DIR=$dir" ]
  [ "$(_sha256_file "$dir/hf_acme_fakeembed-Q8.gguf")" = "$M1_SHA" ]
  [ "$(_sha256_file "$dir/hf_acme_fakeexpand-q4.gguf")" = "$M2_SHA" ]
  [ "$(printf '%s\n' "$output" | grep -c -E "^qmd model embed: ok file=hf_acme_fakeembed-Q8[.]gguf bytes=$M1_BYTES attempts=1 elapsed_s=[0-9]+\$")" = "1" ]
  [ "$(printf '%s\n' "$output" | grep -c -E "^qmd model expand: ok file=hf_acme_fakeexpand-q4[.]gguf bytes=$M2_BYTES attempts=1 elapsed_s=[0-9]+\$")" = "1" ]
  _has "$output" "qmd models: ok total_bytes=$((M1_BYTES + M2_BYTES)) elapsed_s="
  [ "$(printf '%s\n' "$output" | grep -c 'free_kb=[0-9][0-9]*')" = "2" ]
  [ "$(printf '%s\n' "$output" | grep -c -E '^qmd models: ok total_bytes=[0-9]+ elapsed_s=[0-9]+ free_kb=[0-9]+$')" = "1" ]
  [ -z "$(find "$dir" -name '*.part')" ]
  [ "$(find "$dir" -type f | wc -l | tr -d ' ')" = "2" ]
  # QMD_MODELS_DIR moves the directory (the operator recipe of the upgrade checklist uses it)
  rm -rf "$dir"
  : > "$GH_ENV_FILE"
  _run_fetch "${FSEAMS[@]}" "QMD_MODELS_DIR=$TMP_TEST_DIR/custom-models"
  [ "$status" -eq 0 ]
  [ "$(cat "$GH_ENV_FILE")" = "QMD_E2E_MODELS_DIR=$TMP_TEST_DIR/custom-models" ]
  [ -f "$TMP_TEST_DIR/custom-models/hf_acme_fakeembed-Q8.gguf" ]
  [ ! -e "$dir" ]
}

@test "F2: a transient failure that yields to a retry does not redden the night" {
  _mk_fake_models; _fake_seams
  _plan "fakeembed|*|ok:$M1_FILE" "fakeexpand|1|fail:28" "fakeexpand|*|ok:$M2_FILE"
  _run_fetch "${FSEAMS[@]}"
  [ "$status" -eq 0 ]
  _has "$output" "qmd model expand: ok file=hf_acme_fakeexpand-q4.gguf bytes=$M2_BYTES attempts=2 elapsed_s="
  [ "$(printf '%s\n' "$output" | grep -c 'qmd model expand: attempt 1/3 failed')" = "1" ]
  _lacks "$output" "attempt 2/3 failed"
  [ -z "$(_env_value QMD_EMBED_SKIP_REASON)" ]
  [ -n "$(_env_value QMD_E2E_MODELS_DIR)" ]
  [ "$(_calls fakeexpand)" = "2" ]
}

@test "F3: a persistent failure -> rc 1 after three attempts, the second model untouched, the error names fetch_models" {
  _mk_fake_models; _fake_seams
  _plan "fakeembed|*|pfail:22" "fakeexpand|*|ok:$M2_FILE"
  _run_fetch "${FSEAMS[@]}"
  [ "$status" -eq 1 ]
  [ "$(_calls fakeembed)" = "3" ]
  [ "$(_calls fakeexpand)" = "0" ]
  [ "$(_ncalls)" = "3" ]
  [ "$(cat "$FAKE_SLEEP_LOG")" = $'10\n30' ]
  _has "$output" "::error::"
  local reason
  reason=$(_env_value QMD_EMBED_SKIP_REASON)
  _has "$reason" "embed: "
  _has "$reason" "curl exit 22 (http 404)"
  _has "$reason" "fetch_models"
  _has "$output" "$reason"
  [ -z "$(_env_value QMD_E2E_MODELS_DIR)" ]
  [ -z "$(find "$TMP_TEST_DIR/runner-temp/qmd-models" -name '*.part')" ]
}

@test "F4: a body of the wrong size fails every attempt and the reason says so" {
  _mk_fake_models; _fake_seams
  _plan "fakeembed|*|grow:$M1_FILE"
  _run_fetch "${FSEAMS[@]}"
  [ "$status" -eq 1 ]
  [ "$(_calls fakeembed)" = "3" ]
  _has "$(_env_value QMD_EMBED_SKIP_REASON)" "size $((M1_BYTES + 1)) != $M1_BYTES"
  [ -z "$(_env_value QMD_E2E_MODELS_DIR)" ]
  [ -z "$(find "$TMP_TEST_DIR/runner-temp/qmd-models" -name '*.part')" ]
  # and the other way round: a body one byte short is no better (a truncated download is the
  # case that really happens, and the one a "bigger than expected" check would let through)
  : > "$GH_ENV_FILE"
  : > "$FAKE_CURL_LOG"
  _plan "fakeembed|*|shrink:$M1_FILE"
  _run_fetch "${FSEAMS[@]}"
  [ "$status" -eq 1 ]
  [ "$(_calls fakeembed)" = "3" ]
  _has "$(_env_value QMD_EMBED_SKIP_REASON)" "size $((M1_BYTES - 1)) != $M1_BYTES"
  [ -z "$(find "$TMP_TEST_DIR/runner-temp/qmd-models" -name '*.part')" ]
}

@test "F5: the same size with another sha256 means the model changed at origin: one attempt, its own reason" {
  _mk_fake_models; _fake_seams
  _plan "fakeembed|*|flip:$M1_FILE" "fakeexpand|*|ok:$M2_FILE"
  _run_fetch "${FSEAMS[@]}"
  [ "$status" -eq 1 ]
  [ "$(_calls fakeembed)" = "1" ]
  [ "$(_calls fakeexpand)" = "0" ]
  local reason
  reason=$(_env_value QMD_EMBED_SKIP_REASON)
  _has "$reason" "cambio en origen"
  _has "$reason" "sha256 "
  _has "$reason" "!= $M1_SHA"
  _has "$reason" "paso fetch_models"
  [ "$(printf '%s\n' "$reason" | grep -c -E "sha256 [0-9a-f]{64} != $M1_SHA")" = "1" ]
  _lacks "$reason" "sha256 $M1_SHA != $M1_SHA"
  [ -z "$(_env_value QMD_E2E_MODELS_DIR)" ]
  [ -z "$(find "$TMP_TEST_DIR/runner-temp/qmd-models" -name '*.part')" ]
}

@test "F8: a base URL that is neither Hugging Face nor 127.0.0.1:<port> is refused by its own check, before any network call" {
  _mk_fake_models
  _plan "fakeembed|*|ok:$M1_FILE" "fakeexpand|*|ok:$M2_FILE"
  local base
  # no alternate table here: with one, the table check would refuse the same bases by itself
  # and the base check could be deleted without any test noticing. "http://127.0.0.1:@a.io"
  # has the shape of a local base, but "127.0.0.1:" would be a user name and the host a.io.
  for base in "https://evil.example.org" "http://huggingface.co" "https://huggingface.co.evil.org" \
              "http://127.0.0.1" "http://127.0.0.1:123456" "http://127.0.0.1:@a.io" "http://localhost:1234" \
              "https://127.0.0.1:1234"; do
    : > "$GH_ENV_FILE"
    : > "$FAKE_CURL_LOG"
    _run_fetch "QMD_MODELS_BASE_URL=$base"
    [ "$status" -eq 1 ]
    [ "$(_ncalls)" = "0" ]
    _has "$(_env_value QMD_EMBED_SKIP_REASON)" "configuracion invalida"
    _has "$(_env_value QMD_EMBED_SKIP_REASON)" "QMD_MODELS_BASE_URL"
  done
}

@test "F9: an alternate table with the real base URL, a malformed table and a directory that cannot be created are all refused before any network call" {
  _mk_fake_models
  _plan "fakeembed|*|ok:$M1_FILE" "fakeexpand|*|ok:$M2_FILE"
  _run_fetch "QMD_MODELS_TABLE=$TABLE"
  [ "$status" -eq 1 ]
  [ "$(_ncalls)" = "0" ]
  _has "$(_env_value QMD_EMBED_SKIP_REASON)" "configuracion invalida"
  [ -z "$(_env_value QMD_E2E_MODELS_DIR)" ]
  # a table that is not well formed is refused even against a local base: a short sum, a sum
  # that is not hexadecimal, a size that is not a number, a size with a leading zero (shell
  # arithmetic would read it as octal and abort after the download)
  local row
  for row in "embed|acme/fakeembed-GGUF|fakeembed-Q8.gguf|hf_acme_fakeembed-Q8.gguf|1002|deadbeef" \
             "embed|acme/fakeembed-GGUF|fakeembed-Q8.gguf|hf_acme_fakeembed-Q8.gguf|1002|$(printf '%064d' 0 | tr 0 z)" \
             "embed|acme/fakeembed-GGUF|fakeembed-Q8.gguf|hf_acme_fakeembed-Q8.gguf|12ab|$(printf '%064d' 0)" \
             "embed|acme/fakeembed-GGUF|fakeembed-Q8.gguf|hf_acme_fakeembed-Q8.gguf|01002|$(printf '%064d' 0)"; do
    printf '%s\n' "$row" > "$TMP_TEST_DIR/bad.table"
    : > "$GH_ENV_FILE"
    : > "$FAKE_CURL_LOG"
    _run_fetch "QMD_MODELS_BASE_URL=http://127.0.0.1:9" "QMD_MODELS_TABLE=$TMP_TEST_DIR/bad.table"
    [ "$status" -eq 1 ]
    [ "$(_ncalls)" = "0" ]
    _has "$(_env_value QMD_EMBED_SKIP_REASON)" "configuracion invalida"
  done
  # a models directory that cannot be created is a configuration error, not a download that
  # fails three times for a reason nobody can read
  : > "$TMP_TEST_DIR/a-file"
  : > "$GH_ENV_FILE"
  : > "$FAKE_CURL_LOG"
  _fake_seams
  _run_fetch "${FSEAMS[@]}" "QMD_MODELS_DIR=$TMP_TEST_DIR/a-file/models"
  [ "$status" -eq 1 ]
  [ "$(_ncalls)" = "0" ]
  _has "$(_env_value QMD_EMBED_SKIP_REASON)" "QMD_MODELS_DIR"
  # the same failure with the default directory (QMD_MODELS_DIR not set): the reason must not
  # blame a variable nobody defined
  : > "$GH_ENV_FILE"
  : > "$FAKE_CURL_LOG"
  _run_fetch "${FSEAMS[@]}" "RUNNER_TEMP=$TMP_TEST_DIR/a-file/rt"
  [ "$status" -eq 1 ]
  [ "$(_ncalls)" = "0" ]
  _has "$(_env_value QMD_EMBED_SKIP_REASON)" "configuracion invalida"
  _lacks "$(_env_value QMD_EMBED_SKIP_REASON)" "QMD_MODELS_DIR"
}

@test "F10: a hung download is cut by the budget, and the wait between attempts never outlasts what is left of it" {
  _mk_fake_models; _fake_seams
  _plan "fakeembed|*|hang:30"
  local t0 t1 v reason
  t0=$(date +%s)
  _run_fetch "${FSEAMS[@]}" "QMD_FETCH_BUDGET_S=3" "QMD_FETCH_BACKOFF_S=0 0"
  t1=$(date +%s)
  [ "$status" -eq 1 ]
  [ $((t1 - t0)) -lt 8 ]
  reason=$(_env_value QMD_EMBED_SKIP_REASON)
  # the reason keeps both facts: the budget ran out (and how big it was) and what the last
  # attempt died of
  _has "$reason" "budget (3s)"
  _has "$reason" "curl exit 28"
  awk '/^--max-time$/{getline v; print v}' "$FAKE_CURL_LOG" > "$TMP_TEST_DIR/maxtimes"
  [ -s "$TMP_TEST_DIR/maxtimes" ]
  while read -r v; do
    [ "$v" -le 3 ]
    [ "$v" -ge 1 ]
  done < "$TMP_TEST_DIR/maxtimes"
  # the transfer that timed out left a partial file: none survives the exit
  [ -z "$(find "$TMP_TEST_DIR/runner-temp/qmd-models" -name '*.part')" ]
  # with a budget of 5 s and the default back-off (10 s, then 30 s) each wait is cut to what is
  # left of the budget; a 10 s or a 30 s wait would run far past the end of it. The clock ticks
  # in whole seconds, so the cut waits are asserted as "at most 5", not as an exact value.
  : > "$GH_ENV_FILE"
  : > "$FAKE_CURL_LOG"
  : > "$FAKE_SLEEP_LOG"
  _plan "fakeembed|*|pfail:22"
  _run_fetch "${FSEAMS[@]}" "QMD_FETCH_BUDGET_S=5"
  [ "$status" -eq 1 ]
  [ -s "$FAKE_SLEEP_LOG" ]
  while read -r v; do
    [ "$v" -le 5 ]
    [ "$v" -ge 1 ]
  done < "$FAKE_SLEEP_LOG"
}

@test "F11: with the real curl against a local server the models are fetched and verified; with the server gone it fails after the attempts" {
  _mk_fake_models
  _http_up
  USE_FAKE_CURL=0
  _run_fetch "QMD_MODELS_BASE_URL=http://127.0.0.1:$SRV_PORT" "QMD_MODELS_TABLE=$TABLE"
  [ "$status" -eq 0 ]
  local dir="$TMP_TEST_DIR/runner-temp/qmd-models"
  [ "$(_sha256_file "$dir/hf_acme_fakeembed-Q8.gguf")" = "$M1_SHA" ]
  [ "$(_sha256_file "$dir/hf_acme_fakeexpand-q4.gguf")" = "$M2_SHA" ]
  [ "$(cat "$GH_ENV_FILE")" = "QMD_E2E_MODELS_DIR=$dir" ]
  _http_down
  : > "$GH_ENV_FILE"
  rm -rf "$dir"
  _run_fetch "QMD_MODELS_BASE_URL=http://127.0.0.1:$SRV_PORT" "QMD_MODELS_TABLE=$TABLE"
  [ "$status" -eq 1 ]
  _has "$output" "attempt 3/3 failed"
  _has "$(_env_value QMD_EMBED_SKIP_REASON)" "exit 7"
  # curl says why in its own words (that is what --show-error is for): it reaches the job log
  _has "$stderr" "curl: (7)"
}

@test "F12: without GITHUB_ENV the script gives the same result and writes nothing, and a GITHUB_ENV it cannot write fails this step" {
  _mk_fake_models; _fake_seams
  _plan "fakeembed|*|ok:$M1_FILE" "fakeexpand|*|ok:$M2_FILE"
  GH_ENV_FILE=""
  mkdir -p "$TMP_TEST_DIR/cwd"
  cd "$TMP_TEST_DIR/cwd"
  _run_fetch "${FSEAMS[@]}"
  [ "$status" -eq 0 ]
  _has "$output" "qmd models: ok total_bytes="
  [ -z "$(ls -A "$TMP_TEST_DIR/cwd")" ]
  # a GITHUB_ENV that exists but cannot be written (a directory: that fails even as root) is a
  # failure of THIS step. If the script exited 0 the next step would run without the variable
  # and the red would be blamed on the suite instead of on the fetch.
  mkdir -p "$TMP_TEST_DIR/env-is-a-dir"
  GH_ENV_FILE="$TMP_TEST_DIR/env-is-a-dir"
  _plan "fakeembed|*|ok:$M1_FILE" "fakeexpand|*|ok:$M2_FILE"
  # in Spanish: the redirection error is printed by bash itself, and bash translates it ("linea")
  # when it has the catalog; the script must keep its output in plain ASCII anyway
  _run_fetch "${FSEAMS[@]}" "LANG=es_CL.UTF-8" "LC_ALL=es_CL.UTF-8"
  [ "$status" -eq 1 ]
  _has "$output" "::error::"
  _has "$output" "GITHUB_ENV"
  # and the script pins its own locale: the leg above only shows it where bash has a catalog for
  # the language of the machine (this Mac in Spanish), the line itself shows it everywhere
  [ "$(grep -c -x -F -- 'LC_ALL=C' "$FETCH")" = "1" ]
  [ "$(grep -c -x -F -- 'export LC_ALL' "$FETCH")" = "1" ]
  # the open-defect branch has the same rule: its reason is its only output, and a step that ends
  # green without it leaves the next one with the gate open and no reason to skip
  : > "$FAKE_CURL_LOG"
  _run_fetch "${FSEAMS[@]}" "QMD_EMBED_DEFECT=#12 vec0 x64" "LANG=es_CL.UTF-8" "LC_ALL=es_CL.UTF-8"
  [ "$status" -eq 1 ]
  _has "$output" "::error::"
  _has "$output" "GITHUB_ENV"
  _lacks "$output" "::warning::"
  [ "$(_ncalls)" = "0" ]
}

@test "F13: with the real base URL and table the curl call carries the hardening flags and the exact URL" {
  _mk_fake_models
  _plan "embeddinggemma|*|ok:$M1_FILE"
  _run_fetch
  [ "$status" -eq 1 ]
  local first mt
  first=$(awk '/^---$/{exit} {printf "%s ", $0}' "$FAKE_CURL_LOG")
  _has "$first" "--fail "
  _has "$first" "--location "
  _has "$first" "--proto =https "
  _has "$first" "--proto-redir =https "
  _has "$first" "--speed-limit 1048576 "
  _has "$first" "--speed-time 30 "
  _has "$first" "https://huggingface.co/ggml-org/embeddinggemma-300M-GGUF/resolve/main/embeddinggemma-300M-Q8_0.gguf?download=true "
  mt=$(awk '/^--max-time$/{getline v; print v; exit}' "$FAKE_CURL_LOG")
  [ "$mt" -ge 470 ]
  [ "$mt" -le 480 ]
  [ "$(_calls embeddinggemma)" = "3" ]
  [ "$(_calls qmd-query-expansion)" = "0" ]
}

# ── G: identity guards (FR-012) ──────────────────────────────────────────────

@test "G2: every row of the model table follows the local-name rule, with positive sizes and 64-hex sums" {
  local rows="$TMP_TEST_DIR/rows.txt" name repo file lname bytes sha user stem n=0
  grep -E '^[a-z]+\|[^|]+\|[^|]+\|[^|]+\|[0-9]+\|[0-9a-f]{64}$' "$FETCH" > "$rows" || true
  [ -s "$rows" ]
  while IFS='|' read -r name repo file lname bytes sha; do
    n=$((n + 1))
    user="${repo%%/*}"
    stem="${repo#*/}"
    # node-llama-cpp 3.18.1 (parseModelUri.js, doesFilenameMatchExactModelName): the repo name
    # must end in "-gguf" in any case, and the file must start with the repo name without it.
    case "$(printf '%s' "$stem" | tr '[:upper:]' '[:lower:]')" in
      *-gguf) stem="${stem%?????}" ;;
      *) echo "# row $name: the repo name '$stem' does not end in -gguf (the local-name rule is not modelled for it)" >&3; false ;;
    esac
    case "$(printf '%s' "$file" | tr '[:upper:]' '[:lower:]')" in
      "$(printf '%s' "$stem" | tr '[:upper:]' '[:lower:]')"*) ;;
      *) echo "# row $name: file '$file' does not start with the repo name '$stem' (the local-name rule is not modelled for it)" >&3; false ;;
    esac
    [ "$lname" = "hf_${user}_${file}" ]
    case "$bytes" in ''|*[!0-9]*|0) echo "# row $name: bytes '$bytes' is not a positive integer" >&3; false ;; esac
    [ "${#sha}" = "64" ]
  done < "$rows"
  [ "$n" -ge 2 ]
}

@test "G1: the qmd version the model table was checked for is the qmd pin, and the e2e workspace takes the pin from qmd_pkg" {
  local pin tv fn n
  load_lib qmd_index
  pin=$(qmd_pkg "$TMP_TEST_DIR/none.yml")
  pin="${pin##*@}"
  tv=$(sed -n 's/^QMD_MODELS_QMD_VERSION=//p' "$FETCH")
  [ -n "$tv" ]
  if [ "$tv" != "$pin" ]; then
    echo "# QMD_MODELS_QMD_VERSION=$tv but the qmd pin is $pin: review the model table of fetch-qmd-models.sh (docs/qmd-upgrade-checklist.md)" >&3
    false
  fi
  # the workspace the nightly really boots must run that same pin, not a copy of it
  fn=$(awk '/^_qmd_real_ws\(\) \{/{f=1} f{print} f && /^\}/{exit}' "$E2E_FILE")
  [ -n "$fn" ]
  _has "$fn" "qmd_pkg"
  n=$(printf '%s\n' "$fn" | grep -c -E 'version: "[0-9]' || true)
  [ "$n" = "0" ]
}

@test "G3: the upgrade checklist tells to review the model table, how to run the embed phase and which heading to look for in a red run" {
  local doc cite e2e
  doc=$(cat "$UPGRADE_DOC")
  _has "$doc" ".github/scripts/fetch-qmd-models.sh"
  _has "$doc" "QMD_E2E_MODELS_DIR"
  _has "$doc" "QMD_MODELS_QMD_VERSION"
  # the two commands of the recipe
  _has "$doc" "QMD_MODELS_DIR="
  _has "$doc" "QMD_EMBED_E2E=1 QMD_E2E_MODELS_DIR="
  # how to read a red run: the heading it tells to look for is a line the e2e file prints
  cite=$(sed -n 's/.*starts with `\(# --- state at the failure[^`]*\)`.*/\1/p' "$UPGRADE_DOC")
  [ -n "$cite" ]
  e2e=$(cat "$E2E_FILE")
  _has "$e2e" "$cite"
}

# ── W: the structure of the workflow (FR-001, FR-007, FR-008, FR-018, FR-019) ─

@test "W1: the fetch step exists once, between verify_deps and the suite, runs the script and cannot hide a failure" {
  local name="Fetch the qmd models" names line iv=-1 if_=-1 is=-1 i=0
  [ "$(_step_n "$WF_FILE" e2e "$name")" = "1" ]
  [ "$(_step_get "$WF_FILE" e2e "$name" .id)" = "fetch_models" ]
  [ "$(_step_get "$WF_FILE" e2e "$name" .run)" = ".github/scripts/fetch-qmd-models.sh" ]
  [ "$(_step_get "$WF_FILE" e2e "$name" 'has("continue-on-error")')" = "false" ]
  [ "$(_step_get "$WF_FILE" e2e "$name" .if)" = "null" ]
  names=$(yq '.jobs.e2e.steps[].name' "$WF_FILE")
  while IFS= read -r line; do
    case "$line" in
      "Verify deps + docker") iv=$i ;;
      "Fetch the qmd models") if_=$i ;;
      "Run docker-e2e suite") is=$i ;;
    esac
    i=$((i + 1))
  done <<< "$names"
  [ "$iv" -ge 0 ]
  [ "$iv" -lt "$if_" ]
  [ "$if_" -lt "$is" ]
}

@test "W2: Verify deps + docker has id verify_deps and its run text is the one 039 froze" {
  local got
  [ "$(_step_get "$WF_FILE" e2e "Verify deps + docker" .id)" = "verify_deps" ]
  # with continue-on-error a dead Docker would leave this step "failure" with a "success"
  # conclusion, the suite would be skipped by its if: and the night would be green with no test run
  [ "$(_step_get "$WF_FILE" e2e "Verify deps + docker" 'has("continue-on-error")')" = "false" ]
  got=$(_step_get "$WF_FILE" e2e "Verify deps + docker" .run | _sha256_stdin)
  [ "$got" = "$SHA_VERIFY" ]
}

@test "W3: the run text of Run docker-e2e suite is the one 039 froze" {
  local got
  got=$(_step_get "$WF_FILE" e2e "Run docker-e2e suite" .run | _sha256_stdin)
  [ "$got" = "$SHA_SUITE" ]
}

@test "W5: the suite runs when only the fetch failed (its if is the one agreed) and cannot hide a failure" {
  local want="\${{ !cancelled() && steps.verify_deps.outcome == 'success' }}"
  [ "$(_step_get "$WF_FILE" e2e "Run docker-e2e suite" .if)" = "$want" ]
  [ "$(_step_get "$WF_FILE" e2e "Run docker-e2e suite" 'has("continue-on-error")')" = "false" ]
}

@test "W7: no workflow defines the script's test seams, permissions stay contents: read and the e2e job has no secrets" {
  local f n hits=0 seams probe
  seams='QMD_MODELS_DIR|QMD_MODELS_BASE_URL|QMD_MODELS_TABLE|QMD_FETCH_ATTEMPTS|QMD_FETCH_BACKOFF_S|QMD_FETCH_BUDGET_S'
  # the scan must be able to see a seam: calibrate it on one
  [ "$(printf '%s\n' '        QMD_MODELS_BASE_URL: https://x' | grep -c -E "$seams")" = "1" ]
  n=0
  for f in "$REPO_ROOT"/.github/workflows/*.yml; do
    n=$((n + 1))
    hits=$((hits + $(grep -c -E "$seams" "$f" || true)))
  done
  [ "$n" -ge 3 ]
  [ "$hits" = "0" ]
  [ "$(yq '.permissions.contents' "$WF_FILE")" = "read" ]
  [ "$(yq '.permissions | keys | length' "$WF_FILE")" = "1" ]
  # nor at job level: a permissions block on the e2e job would widen what the whole job can do
  [ "$(yq '.jobs.e2e | has("permissions")' "$WF_FILE")" = "false" ]
  # the secrets scan, calibrated on a job that does use one
  probe="$TMP_TEST_DIR/probe.yml"
  printf 'jobs:\n  e2e:\n    steps:\n      - run: echo ${{ secrets.X }}\n' > "$probe"
  [ "$(yq '[.jobs.e2e | .. | select(tag == "!!str") | select(test("secrets"))] | length' "$probe")" = "1" ]
  [ "$(yq '[.jobs.e2e | .. | select(tag == "!!str") | select(test("secrets"))] | length' "$WF_FILE")" = "0" ]
}

@test "W8: the fetch script is executable on disk and, once tracked, has mode 100755 in the index" {
  local mode
  [ -f "$FETCH" ]
  [ -x "$FETCH" ]
  if git -C "$REPO_ROOT" ls-files --error-unmatch ".github/scripts/fetch-qmd-models.sh" >/dev/null 2>&1; then
    mode=$(git -C "$REPO_ROOT" ls-files -s ".github/scripts/fetch-qmd-models.sh")
    mode="${mode%% *}"
    [ "$mode" = "100755" ]
  fi
}

@test "W4: the suite step opens both gates, DOCKER_E2E and QMD_EMBED_E2E" {
  [ "$(_step_get "$WF_FILE" e2e "Run docker-e2e suite" '.["env"].DOCKER_E2E')" = "1" ]
  [ "$(_step_get "$WF_FILE" e2e "Run docker-e2e suite" '.["env"].QMD_EMBED_E2E')" = "1" ]
}

@test "W6: the fetch step declares QMD_EMBED_DEFECT, empty or in the registered format" {
  local name="Fetch the qmd models" v n re
  re='^(#[0-9]+ +[!-~][ -~]*|https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/issues/[0-9]+( [ -~]+)?)$'
  # the pattern accepts a registered defect and refuses what is not one
  [ "$(printf '%s\n' '#12 vec0 x64' | grep -c -E "$re")" = "1" ]
  [ "$(printf '%s\n' 'apagado' | grep -c -E "$re")" = "0" ]
  # a reason made only of spaces names nothing: the script refuses it (F7), so this pattern must too
  [ "$(printf '%s\n' '#12   ' | grep -c -E "$re")" = "0" ]
  [ "$(_step_get "$WF_FILE" e2e "$name" '.["env"] | has("QMD_EMBED_DEFECT")')" = "true" ]
  v=$(_step_get "$WF_FILE" e2e "$name" '.["env"].QMD_EMBED_DEFECT')
  if [ -n "$v" ]; then
    n=$(printf '%s\n' "$v" | grep -c -E "$re" || true)
    [ "$n" = "1" ]
  fi
}

# ── F (continued): the open-defect switch (FR-014) ───────────────────────────

@test "F6: a registered open defect switches the phase off: rc 0, no download, a reason that names the defect, a warning" {
  _mk_fake_models
  _plan "http|*|ok:$M1_FILE"
  local value
  for value in "#123 vec0 x64" "https://github.com/o/r/issues/45 vec0 x64" "https://github.com/o/r/issues/45"; do
    : > "$GH_ENV_FILE"
    : > "$FAKE_CURL_LOG"
    _run_fetch "QMD_EMBED_DEFECT=$value"
    [ "$status" -eq 0 ]
    [ "$(_ncalls)" = "0" ]
    _has "$(_env_value QMD_EMBED_SKIP_REASON)" "fase del embed apagada por defecto abierto: $value"
    _has "$output" "::warning::"
    [ -z "$(_env_value QMD_E2E_MODELS_DIR)" ]
  done
}

@test "F7: a defect that names no issue, or is not plain ASCII, is a configuration error and downloads nothing" {
  _mk_fake_models
  _plan "http|*|ok:$M1_FILE"
  local value
  for value in "sin issue" "#123" "#123 " "#12   " "#abc motivo" "issue 123 vec0" "#123 motivo $(printf '\303\251')" \
               "https://example.org/o/r/issues/45 vec0" "https://github.com/o/r/issues/" \
               "$(printf '#123 x\nINJECTED=1')" "$(printf '#123 x\n::warning::y')" "$(printf '#123 x\r')"; do
    : > "$GH_ENV_FILE"
    : > "$FAKE_CURL_LOG"
    _run_fetch "QMD_EMBED_DEFECT=$value"
    [ "$status" -eq 1 ]
    [ "$(_ncalls)" = "0" ]
    _has "$(_env_value QMD_EMBED_SKIP_REASON)" "configuracion invalida"
    [ -z "$(_env_value QMD_E2E_MODELS_DIR)" ]
    # the reason is the ONLY line the script adds to GITHUB_ENV: a value with a line break must
    # never become a second variable
    [ "$(grep -c '' "$GH_ENV_FILE")" = "1" ]
  done
}

# ── V: vec0-libc.sh, the libc check of the vector extension (FR-003) ─────────

# _vec_prefix ARCH:KIND...: build $VPREFIX with one node_modules/sqlite-vec-linux-<ARCH>/vec0.so
# per argument. KIND glibc gives the library a GLIBC_ symbol version, anything else does not.
_vec_prefix() {
  local spec arch kind
  VPREFIX="$TMP_TEST_DIR/prefix"
  mkdir -p "$VPREFIX/node_modules"
  for spec in "$@"; do
    arch="${spec%%:*}"
    kind="${spec#*:}"
    mkdir -p "$VPREFIX/node_modules/sqlite-vec-linux-$arch"
    if [ "$kind" = "glibc" ]; then
      printf 'ELF fake library\0GLIBC_2.17\0memcpy@GLIBC_2.14\0' > "$VPREFIX/node_modules/sqlite-vec-linux-$arch/vec0.so"
    else
      printf 'ELF fake library\0built against musl, no versioned symbols (unlike GLIBC)\0' > "$VPREFIX/node_modules/sqlite-vec-linux-$arch/vec0.so"
    fi
  done
}

@test "V1: an arm64 extension without GLIBC_ symbols is musl" {
  _vec_prefix arm64:musl
  run sh "$VEC0" "$VPREFIX"
  [ "$status" -eq 0 ]
  [ "${output%% *}" = "MUSL" ]
}

@test "V2: the answer does not depend on the CPU architecture: an x64 extension without GLIBC_ symbols is musl too" {
  _vec_prefix x64:musl
  run sh "$VEC0" "$VPREFIX"
  [ "$status" -eq 0 ]
  [ "${output%% *}" = "MUSL" ]
}

@test "V3: an x64 extension with GLIBC_ symbols is glibc and fails" {
  _vec_prefix x64:glibc
  run sh "$VEC0" "$VPREFIX"
  [ "$status" -eq 1 ]
  [ "${output%% *}" = "GLIBC" ]
}

@test "V4: no extension at all is ABSENT and fails, it does not pass in silence" {
  _vec_prefix
  run sh "$VEC0" "$VPREFIX"
  [ "$status" -eq 2 ]
  [ "$output" = "ABSENT" ]
}

@test "V5: two extensions are ambiguous and fail" {
  _vec_prefix arm64:musl x64:musl
  run sh "$VEC0" "$VPREFIX"
  [ "$status" -eq 3 ]
  [ "$output" = "AMBIGUOUS 2" ]
}

@test "V6: no argument, or an argument that is not a directory, is a usage error" {
  run sh "$VEC0"
  [ "$status" -eq 64 ]
  _has "$output" "usage: vec0-libc.sh PREFIX"
  run sh "$VEC0" "$TMP_TEST_DIR/not-a-directory"
  [ "$status" -eq 64 ]
  _has "$output" "usage: vec0-libc.sh PREFIX"
}

# ── P: the phase marks of the real test (FR-004) ─────────────────────────────

@test "P1: the 041 test marks its eight phases once each and in order, and each phase runs its command and asserts its result" {
  local all="$TMP_TEST_DIR/body-all" code="$TMP_TEST_DIR/body-code" names total i=0 start end seg
  local -a phases anchors
  awk '/^@test "qmd real \(041\)/{f=1; next} /^@test /{f=0} f{print}' "$E2E_FILE" > "$all"
  awk '$0 !~ /^[[:space:]]*#/ {print}' "$all" > "$code"
  [ -s "$code" ]
  # the old assertion looked at one architecture only and passed on a missing file
  _lacks "$(cat "$all")" "sqlite-vec-linux-arm64"
  # the marks are TAP comments on fd 3: on stdout they would be lost in the output bats captures
  [ "$(grep -c -F -x -- '_embed_phase() { echo "# qmd embed phase: $1" >&3; }' "$E2E_FILE")" = "1" ]
  names=$(awk '$1 == "_embed_phase" {printf "%s ", $2}' "$code")
  [ "$names" = "models-seed boot setup vector-extension reindex semantic-search mcp models-untouched " ]
  phases=(models-seed boot setup vector-extension reindex semantic-search mcp models-untouched)
  anchors=('seed-marker' 'docker compose up -d' '.qmd-setup-ok' 'vec0-libc.sh' 'heartbeatctl qmd-reindex' 'vsearch' 'qmd-mcp' '-newer')
  total=$(wc -l < "$code" | tr -d ' ')
  while [ "$i" -lt 8 ]; do
    start=$(awk -v p="${phases[$i]}" '$1 == "_embed_phase" && $2 == p {print NR; exit}' "$code")
    if [ "$i" -lt 7 ]; then
      end=$(awk -v p="${phases[$((i + 1))]}" '$1 == "_embed_phase" && $2 == p {print NR; exit}' "$code")
    else
      end=$((total + 1))
    fi
    [ "$end" -gt "$start" ]
    seg=$(sed -n "${start},$((end - 1))p" "$code")
    if ! _has "$seg" "${anchors[$i]}"; then
      echo "# phase ${phases[$i]}: the anchor '${anchors[$i]}' is not between its mark and the next one" >&3
      false
    fi
    # What each phase must ASSERT, not only run: this test cannot run without Docker, so a line
    # deleted from its body is something no other test would ever notice.
    case "${phases[$i]}" in
      models-seed)
        _has "$seg" '[ "$seeded" -lt 1 ]' ;;
      boot)
        # the vault is pre-seeded under wiki/: qmd indexes wiki/**/*.md only (since 037), and a
        # page at the vault root, where the old Tier 2 wrote its document, is never indexed
        _has "$seg" '.state/.vault/wiki/'
        _has "$seg" '[ "$status" -ne 0 ]' ;;
      setup)
        _has "$seg" '[ "$setup_done" -ne 1 ]'
        _has "$seg" 'grep -q HAVE_MODEL'
        # an operator value with a leading zero ('08') is octal to $(( )) unless it is normalized
        _has "$seg" '10#' ;;
      vector-extension)
        _has "$seg" '[ "${output%% *}" = "MUSL" ]' ;;
      reindex)
        _has "$seg" '/.vault/wiki/concepts/gatos.md'
        _has "$seg" "grep -qE 'ok|indexed'"
        _has "$seg" '[ "$output" = "0" ]'
        # bounded inside the container: a hang ends THIS phase, not the whole job at its cap
        _has "$seg" 'timeout -k 10 600'
        _has "$seg" 'qmd-reindex did not finish'
        # and how long it ran: a 137 long before the limit is a kill from outside, not a hang
        _has "$seg" 'SECONDS - t0' ;;
      semantic-search)
        _has "$seg" "grep -qi 'gato'"
        _has "$seg" 'timeout -k 10 300'
        _has "$seg" 'vsearch did not finish'
        _has "$seg" 'SECONDS - t0' ;;
      mcp)
        _has "$seg" 'BUG-4 signature' ;;
      models-untouched)
        _has "$seg" 'qmd downloaded or rewrote a model'
        # ls and find print one line per file: each of the three lists of the report (seeded, now,
        # newer) needs a '#' on every line it prints, so none of them may go back to a bare echo
        if [ "$(printf '%s\n' "$seg" | grep -c -F -- '_embed_note')" -lt 3 ]; then
          echo "# phase models-untouched: the three lists of the report must be printed through _embed_note" >&3
          false
        fi ;;
    esac
    # the phases that report a failure end the test right after the report
    case "${phases[$i]}" in
      models-seed|boot|setup|vector-extension|reindex|semantic-search|mcp|models-untouched)
        if [ "$(printf '%s\n' "$seg" | grep -c -x -F -- '    false')" -lt 1 ]; then
          echo "# phase ${phases[$i]}: its failure branch no longer ends the test (no 'false' after the report)" >&3
          false
        fi ;;
    esac
    i=$((i + 1))
  done
}

@test "P2: a failed 041 test leaves the evidence a first real run needs, and the real-qmd workspace keeps the cron out of the run" {
  local td="$TMP_TEST_DIR/teardown-body" fn="$TMP_TEST_DIR/probe-body" ws="$TMP_TEST_DIR/ws-body"
  local tcode fcode wcode call down
  awk '/^teardown\(\) \{/{f=1} f{print} f && /^\}/{exit}' "$E2E_FILE" > "$td"
  awk '/^_embed_failure_state\(\) \{/{f=1} f{print} f && /^\}/{exit}' "$E2E_FILE" > "$fn"
  awk '/^_qmd_real_ws\(\) \{/{f=1} f{print} f && /^\}/{exit}' "$E2E_FILE" > "$ws"
  [ -s "$td" ]
  [ -s "$fn" ]
  [ -s "$ws" ]
  tcode=$(awk '$0 !~ /^[[:space:]]*#/ {print}' "$td")
  fcode=$(awk '$0 !~ /^[[:space:]]*#/ {print}' "$fn")
  wcode=$(awk '$0 !~ /^[[:space:]]*#/ {print}' "$ws")
  # the probes run under the failure guard, once, and before the project goes down
  _has "$tcode" 'BATS_TEST_COMPLETED'
  [ "$(printf '%s\n' "$tcode" | grep -c -x -F -- '    _embed_failure_state')" = "1" ]
  call=$(printf '%s\n' "$tcode" | awk '$1 == "_embed_failure_state" {print NR; exit}')
  down=$(printf '%s\n' "$tcode" | awk '/docker compose down/ {print NR; exit}')
  [ -n "$call" ]
  [ -n "$down" ]
  [ "$call" -lt "$down" ]
  # what the probes read: free disk, the container's own verdict, and from inside it the CPU,
  # the vector extension the install laid down and the memory counters of its cgroup
  _has "$fcode" 'df -Pk'
  _has "$fcode" 'docker inspect'
  _has "$fcode" 'OOMKilled'
  _has "$fcode" 'RestartCount'
  _has "$fcode" 'exec -T -u agent'
  _has "$fcode" 'uname -m'
  _has "$fcode" 'vec0-libc.sh'
  _has "$fcode" 'memory.events'
  # the output of the reindex and of the semantic search stays in files inside the container and
  # in its state file; a failure that is not a timeout (rc 91, stalled, a segfault of vsearch)
  # names its cause only there, and the workspace is gone when the job ends
  _has "$fcode" 'qmd-index.json'
  _has "$fcode" 'qmd-reindex.out'
  _has "$fcode" 'vsearch.out'
  # every probe tolerates failure: none may turn the red it reports on into a different one
  local pat
  for pat in 'df -Pk' 'docker compose ps' 'docker inspect' 'docker compose exec'; do
    if [ "$(printf '%s\n' "$fcode" | grep -F -- "$pat" | grep -c -F -- '|| true')" -lt 1 ]; then
      echo "# P2: the probe '$pat' no longer tolerates failure (no '|| true' on its line)" >&3
      false
    fi
  done
  # a reindex tick of cron between the end of the setup and the reindex phase would take the lock
  # and fail a healthy run: the workspace of the real-qmd tests schedules a date that never exists
  _has "$wcode" 'schedule: "0 0 31 2 *"'
  _lacks "$wcode" '*/5'
}
