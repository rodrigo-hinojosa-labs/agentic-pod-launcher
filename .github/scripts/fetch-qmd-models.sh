#!/usr/bin/env bash
# fetch-qmd-models.sh - fetch and verify the two qmd models the nightly embed phase uses.
#
# 041-nightly-qmd-embed. Contract: specs/041-nightly-qmd-embed/contracts/fetch-models-script.md
# (inputs, algorithm, outputs, invariants) and data-model.md sections 1 to 3.
#
# Why a step of its own: a Hugging Face or network failure must read as INFRASTRUCTURE (this
# step turns red), never as a regression of the embed. Retries are bounded, a total budget
# caps the whole fetch, and every file is accepted only when its size and sha256 match the
# table below. Nothing here is a runtime component of the launcher: it never runs on an agent.
#
# What it leaves for the next steps of the job, through $GITHUB_ENV (one KEY=value line):
#   QMD_E2E_MODELS_DIR       the directory with both verified models      (outcome ok)
#   QMD_EMBED_SKIP_REASON    why the embed phase must be skipped          (every other outcome)
# Exit status: 0 for ok, 1 for a failed fetch, a model that changed at origin or a bad
# configuration. No `set -e`: every exit status is decided on purpose. ASCII only, bash 3.2+.
set -u
# One language and plain ASCII whatever the locale of the machine: the reasons that leave this
# script travel through GITHUB_ENV and the job log as printable ASCII, and bash translates its
# own messages (a failed redirection, for one) into the language of the user when it has the
# catalog, even from a clean environment on macOS. The oracle checks the ASCII of every run.
LC_ALL=C
export LC_ALL

# ---------------------------------------------------------------------------------------
# The model table: the single source of the identity of the models (FR-012, research D5).
# name|repo|file|local_name|bytes|sha256
# local_name is the name node-llama-cpp gives the file in the models directory
# (hf_<user>_<file> when the file starts with the repo name), so qmd finds it without a
# download. A bump of the qmd pin means re-checking this table (docs/qmd-upgrade-checklist.md).
# ---------------------------------------------------------------------------------------
read -r -d '' MODEL_TABLE <<'TABLE'
embed|ggml-org/embeddinggemma-300M-GGUF|embeddinggemma-300M-Q8_0.gguf|hf_ggml-org_embeddinggemma-300M-Q8_0.gguf|333590944|b5ce9d77a3fc4b3b39ccb5643c36777911cc4eb46a66962eadfa3f5f60490d63
expand|tobil/qmd-query-expansion-1.7B-gguf|qmd-query-expansion-1.7B-q4_k_m.gguf|hf_tobil_qmd-query-expansion-1.7B-q4_k_m.gguf|1282438912|000dfb1c06efa6a049e9f64ba921c3740e2454f62abab6fa10e77bd30bb2bcc0
TABLE

# The version of qmd the table above was checked for. It is NOT a pin of qmd: the pin lives in
# agent.yml (vault.qmd.version) with its floor in qmd_pkg(). This line only records which
# version the table belongs to, and tests/qmd-embed-nightly.bats (G1) fails when the two drift
# apart, so a bump of the pin cannot leave stale models in the nightly without anyone noticing.
# shellcheck disable=SC2034  # read by the guard G1, not by this script
QMD_MODELS_QMD_VERSION=2.5.3

BASE_DEFAULT="https://huggingface.co"
FAIL_REASON=""
DRIFT_REASON=""

# ---- small helpers -----------------------------------------------------------------------

now() { date +%s; }

# emit_env KEY VALUE: append KEY=VALUE to $GITHUB_ENV, when there is one. It returns the status
# of the write (the status of the if is that of its last command, or 0 when no branch ran): a
# GITHUB_ENV that cannot be written is for the caller to report, because a step that ends green
# without its output makes the next step fail with a message that blames the wrong step.
emit_env() {
  if [ -n "${GITHUB_ENV:-}" ]; then
    printf '%s=%s\n' "$1" "$2" >> "$GITHUB_ENV"
  fi
}

# stop_with_error REASON: the reason goes to the next steps and to the job log, then exit 1.
stop_with_error() {
  emit_env QMD_EMBED_SKIP_REASON "$1"
  printf '::error::%s\n' "$1"
  exit 1
}

# emit_env_or_stop KEY VALUE: write one output for the next steps, or end this step in red when the
# write fails. A step that ends green without its output makes the next one fail with a message
# that blames the wrong step (the suite, not this fetch).
emit_env_or_stop() {
  if ! emit_env "$1" "$2"; then
    stop_with_error "no se pudo escribir $1 en GITHUB_ENV (paso fetch_models)"
  fi
}

# fail_config DETAIL: a bad configuration is refused before any network call. DETAIL names
# the variable, never its value (a value could carry anything into a one-line ASCII reason).
fail_config() {
  stop_with_error "configuracion invalida del paso fetch_models: $1"
}

# int_in_range VALUE MIN MAX: succeed when VALUE is a plain decimal integer in [MIN, MAX].
int_in_range() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "${#1}" -le 9 ] || return 1
  [ "$((10#$1))" -ge "$2" ] && [ "$((10#$1))" -le "$3" ]
}

# valid_backoff WORDS: one or more waits, each a whole number of seconds from 0 to 300.
valid_backoff() {
  local t n=0
  for t in $1; do
    int_in_range "$t" 0 300 || return 1
    n=$((n + 1))
  done
  [ "$n" -ge 1 ]
}

# backoff_for K: the wait after the K-th failed attempt; the last word when there are fewer.
backoff_for() {
  local k="$1" i=0 w="" t
  for t in $BACKOFF; do
    i=$((i + 1))
    w="$t"
    if [ "$i" -eq "$k" ]; then break; fi
  done
  printf '%s' "$((10#$w))"
}

# free_kb DIR: the free space of the filesystem that holds DIR, in KiB ("unknown" when df
# does not say). The last line of `df -Pk` is the one that matters.
free_kb() {
  local out line
  if ! out=$(df -Pk "$1" 2>/dev/null); then
    printf 'unknown'
    return 0
  fi
  line="${out##*$'\n'}"
  # shellcheck disable=SC2086  # splitting the df line into its columns is the point
  set -- $line
  printf '%s' "${4:-unknown}"
}

size_of() {
  local n
  n=$(wc -c < "$1" 2>/dev/null) || n=0
  printf '%s' "$((n + 0))"
}

sha256_of() {
  local out
  if command -v sha256sum >/dev/null 2>&1; then
    out=$(sha256sum "$1" 2>/dev/null)
  else
    out=$(shasum -a 256 "$1" 2>/dev/null)
  fi
  printf '%s' "${out%% *}"
}

# ---- configuration (contract section 3) --------------------------------------------------

# The base URL is either Hugging Face or a local server (the host oracle). Anything else is
# refused: a seam must not be able to point the nightly at an arbitrary host.
BASE="${QMD_MODELS_BASE_URL:-$BASE_DEFAULT}"
base_kind=""
case "$BASE" in
  "$BASE_DEFAULT") base_kind=real ;;
  http://127.0.0.1:*)
    port="${BASE#http://127.0.0.1:}"
    case "$port" in
      ''|*[!0-9]*) ;;
      *) if [ "${#port}" -le 5 ]; then base_kind=local; fi ;;
    esac
    ;;
esac
if [ -z "$base_kind" ]; then
  fail_config "QMD_MODELS_BASE_URL no es https://huggingface.co ni http://127.0.0.1:<puerto>"
fi

# An alternate table only makes sense against a local server (the host oracle serves fake
# models). With the real base it would mean downloading something other than the pinned models.
if [ -n "${QMD_MODELS_TABLE:-}" ]; then
  if [ "$base_kind" != "local" ]; then
    fail_config "QMD_MODELS_TABLE solo se acepta con una base http://127.0.0.1:<puerto>"
  fi
  if [ ! -f "$QMD_MODELS_TABLE" ]; then
    fail_config "QMD_MODELS_TABLE no es un archivo"
  fi
  MODEL_TABLE=$(cat "$QMD_MODELS_TABLE")
fi

# Every row: six fields, a positive whole number of bytes (no leading zero: shell arithmetic would
# read it as octal) and a 64-character lowercase sha256.
rows=0
while IFS='|' read -r r_name r_repo r_file r_local r_bytes r_sha; do
  if [ -z "$r_name" ]; then continue; fi
  rows=$((rows + 1))
  if [ -z "$r_repo" ] || [ -z "$r_file" ] || [ -z "$r_local" ]; then
    fail_config "la tabla de modelos tiene una fila incompleta"
  fi
  case "$r_bytes" in ''|*[!0-9]*|0*) fail_config "la tabla de modelos tiene una fila con bytes invalidos" ;; esac
  case "$r_sha" in *[!0-9a-f]*) fail_config "la tabla de modelos tiene una fila con sha256 invalido" ;; esac
  if [ "${#r_sha}" -ne 64 ]; then
    fail_config "la tabla de modelos tiene una fila con sha256 invalido"
  fi
done <<< "$MODEL_TABLE"
if [ "$rows" -lt 1 ]; then
  fail_config "la tabla de modelos esta vacia"
fi

ATTEMPTS=3
if int_in_range "${QMD_FETCH_ATTEMPTS:-}" 1 5; then ATTEMPTS=$((10#$QMD_FETCH_ATTEMPTS)); fi
BACKOFF="10 30"
if valid_backoff "${QMD_FETCH_BACKOFF_S:-}"; then BACKOFF="$QMD_FETCH_BACKOFF_S"; fi
BUDGET=480
if int_in_range "${QMD_FETCH_BUDGET_S:-}" 1 3600; then BUDGET=$((10#$QMD_FETCH_BUDGET_S)); fi

if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
  fail_config "falta sha256sum o shasum para verificar los modelos"
fi
if ! command -v curl >/dev/null 2>&1; then
  fail_config "falta curl para descargar los modelos"
fi

# A recorded open defect switches the embed phase off (FR-014): nothing is downloaded, the
# night stays green and the skip carries the defect and its follow-up. The value must name
# the follow-up, as '#<issue> <short reason>' or as the URL of a GitHub issue (with an
# optional reason), in printable ASCII on one line; anything else is a configuration error,
# so "off" can never be a quiet way to hide a red.
defect_valid() {
  local v="$1" ref rest n
  case "$v" in *$'\n'*) return 1 ;; esac
  n=$(printf '%s\n' "$v" | LC_ALL=C grep -c -v -E '^[ -~]+$' || true)
  [ "$n" = "0" ] || return 1
  ref="${v%% *}"
  rest=""
  case "$v" in *' '*) rest="${v#* }" ;; esac
  n=$(printf '%s\n' "$ref" | LC_ALL=C grep -c -E '^#[0-9]+$' || true)
  if [ "$n" = "1" ]; then
    # '#123' alone, or '#123' followed by nothing but spaces, names no reason
    rest="${rest// /}"
    [ -n "$rest" ]
    return
  fi
  n=$(printf '%s\n' "$ref" | LC_ALL=C grep -c -E '^https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/issues/[0-9]+$' || true)
  [ "$n" = "1" ]
}
if [ -n "${QMD_EMBED_DEFECT:-}" ]; then
  if ! defect_valid "$QMD_EMBED_DEFECT"; then
    fail_config "QMD_EMBED_DEFECT debe ser vacio, '#<issue> <motivo>' o la URL de un issue de GitHub"
  fi
  defect_reason="fase del embed apagada por defecto abierto: $QMD_EMBED_DEFECT"
  emit_env_or_stop QMD_EMBED_SKIP_REASON "$defect_reason"
  printf '::warning::%s\n' "$defect_reason"
  exit 0
fi

DIR="${QMD_MODELS_DIR:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/qmd-models}"
if ! mkdir -p "$DIR" 2>/dev/null; then
  # name the variable only when the operator set it: the default directory comes from the runner
  if [ -n "${QMD_MODELS_DIR:-}" ]; then
    fail_config "QMD_MODELS_DIR no se pudo crear"
  fi
  fail_config "el directorio por defecto de los modelos no se pudo crear (RUNNER_TEMP o TMPDIR sin permiso de escritura)"
fi
# A transfer that breaks leaves a half-written .part behind. Whatever the way out (success,
# failure, a bad configuration found later, a SIGTERM of the runner), none survives: the next
# step must find either verified models or nothing, never a partial file with a model's name.
trap 'rm -f "$DIR"/*.part' EXIT
printf 'qmd models: dir=%s free_kb=%s\n' "$DIR" "$(free_kb "$DIR")"

START=$(now)
DEADLINE=$((START + BUDGET))

# ---- the download of one model -----------------------------------------------------------

# run_curl URL OUT MAXTIME: prints the HTTP code and returns curl's status. --fail makes an
# HTTP error a failed attempt, the stall limit (under 1 MiB/s for 30 s) cuts a crawl early,
# and the protocol flags keep the transfer on https (or on http only for the local oracle).
run_curl() {
  if [ "$base_kind" = "real" ]; then
    curl --fail --location --silent --show-error --speed-limit 1048576 --speed-time 30 \
      --max-time "$3" --proto =https --proto-redir =https \
      --output "$2" --write-out '%{http_code}' "$1" < /dev/null
  else
    curl --fail --location --silent --show-error --speed-limit 1048576 --speed-time 30 \
      --max-time "$3" --proto =http \
      --output "$2" --write-out '%{http_code}' "$1" < /dev/null
  fi
}

# fetch_model NAME REPO FILE LOCAL_NAME BYTES SHA256
# Returns 0 when the file is in place and verified, 1 when the attempts or the budget ran
# out (FAIL_REASON says why), 2 when the file has the right size but another sha256: it
# changed at origin, which is no transient failure, so there is no retry (DRIFT_REASON).
fetch_model() {
  local name="$1" repo="$2" file="$3" lname="$4" bytes="$5" sha="$6"
  local url="$BASE/$repo/resolve/main/$file?download=true"
  local part="$DIR/$lname.part" final="$DIR/$lname"
  local k=1 mstart code rc remaining pause size got last_err=""
  mstart=$(now)
  while [ "$k" -le "$ATTEMPTS" ]; do
    remaining=$((DEADLINE - $(now)))
    if [ "$remaining" -le 0 ]; then
      # keep what the last attempt died of: "budget" alone reads like a table problem, not a slow link
      last_err="budget (${BUDGET}s)${last_err:+ tras: $last_err}"
      break
    fi
    rm -f "$part"
    code=$(run_curl "$url" "$part" "$remaining")
    rc=$?
    if [ "$rc" -ne 0 ]; then
      last_err="curl exit $rc"
      case "$code" in 000|'') ;; *) last_err="$last_err (http $code)" ;; esac
    else
      size=$(size_of "$part")
      if [ "$size" -ne "$bytes" ]; then
        last_err="size $size != $bytes"
      else
        got=$(sha256_of "$part")
        if [ "$got" = "$sha" ]; then
          mv -f "$part" "$final"
          printf 'qmd model %s: ok file=%s bytes=%s attempts=%s elapsed_s=%s\n' \
            "$name" "$lname" "$bytes" "$k" "$(( $(now) - mstart ))"
          return 0
        fi
        DRIFT_REASON="el modelo $name cambio en origen (bytes iguales, sha256 $got != $sha): revisar la tabla del paso fetch_models"
        return 2
      fi
    fi
    printf 'qmd model %s: attempt %s/%s failed: %s\n' "$name" "$k" "$ATTEMPTS" "$last_err"
    if [ "$k" -lt "$ATTEMPTS" ]; then
      pause=$(backoff_for "$k")
      remaining=$((DEADLINE - $(now)))
      if [ "$pause" -gt "$remaining" ]; then pause="$remaining"; fi
      if [ "$pause" -gt 0 ]; then sleep "$pause"; fi
    fi
    k=$((k + 1))
  done
  FAIL_REASON="$name: $last_err"
  return 1
}

# ---- main --------------------------------------------------------------------------------

ok_total=0
while IFS='|' read -r name repo file lname bytes sha; do
  if [ -z "$name" ]; then continue; fi
  fetch_model "$name" "$repo" "$file" "$lname" "$bytes" "$sha"
  case $? in
    0) ok_total=$((ok_total + bytes)) ;;
    2)
      stop_with_error "$DRIFT_REASON"
      ;;
    *)
      stop_with_error "no se pudieron obtener los modelos de qmd ($FAIL_REASON; paso fetch_models)"
      ;;
  esac
done <<< "$MODEL_TABLE"

printf 'qmd models: ok total_bytes=%s elapsed_s=%s free_kb=%s\n' \
  "$ok_total" "$(( $(now) - START ))" "$(free_kb "$DIR")"
emit_env_or_stop QMD_E2E_MODELS_DIR "$DIR"
exit 0
