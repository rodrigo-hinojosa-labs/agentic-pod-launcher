#!/usr/bin/env bash
# nightly-alert.sh -- the red-night notice of the docker-e2e nightly
# (040-nightly-red-alert). Contracts: specs/040-nightly-red-alert/contracts/
# alert-script.md (this file), notice-format.md (what it writes) and
# alert-workflow.md (how the workflow calls it).
#
#   nightly-alert.sh collect                      facts of the run -> job outputs
#   nightly-alert.sh simulate red|green|timeout   trial outcome, no suite
#   nightly-alert.sh notify                       open / update / close the notice
#
# Rules of this file (alert-script.md section 1, checked by tests/nightly-alert.bats):
# bash 3.2 and 5.x; ASCII only; no `set -e` and no `set -u` on purpose, because a
# failure of the notice must never decide the exit code of the night (FR-009);
# no pipe whose consumer can close before its producer is done; every payload goes
# through a file and never through argv or the environment. The push to Telegram
# (amendment 1, telegram-push.md) follows the same rules: its token lives in a 0600
# curl config file, never on a command line.

export LC_ALL=C

TMP_DIR=""
cleanup() {
  if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then rm -rf "$TMP_DIR"; fi
}
trap cleanup EXIT

# make_tmp: the private directory for bodies and gh output, created once.
make_tmp() {
  if [ -n "$TMP_DIR" ]; then return 0; fi
  TMP_DIR=$(mktemp -d 2>/dev/null) || TMP_DIR=""
  [ -n "$TMP_DIR" ]
}

say_notice() { printf '::notice::nightly-alert: %s\n' "$*"; }
warn() { printf '::warning::nightly-alert: %s\n' "$*"; }

usage() {
  echo "usage: nightly-alert.sh collect | simulate red|green|timeout | notify" >&2
}

# san TEXT [MAX]: TEXT as one line of printable ASCII that is inert in GitHub markdown
# (NF section 6): control characters out, anything above ASCII becomes ?, backticks
# and tildes become apostrophes (nothing can close a code span or a fence), the HTML
# comment delimiters are neutralised until none is left, and the line is cut to MAX
# (120 by default) ending in "...". It only substitutes constants: no replacement
# string here is built from the text itself.
san() {
  local s="$1" max="${2:-120}" bt='`' ap="'" tl='~'
  s=${s//[[:cntrl:]]/}
  s=${s//[^ -~]/?}
  s=${s//"$bt"/"$ap"}
  s=${s//"$tl"/"$ap"}
  while case "$s" in *'<!--'*|*'-->'*) true ;; *) false ;; esac; do
    s=${s//"<!--"/"<!-"}
    s=${s//"-->"/"->"}
  done
  if [ "${#s}" -gt "$max" ]; then s="${s:0:$((max - 3))}..."; fi
  printf '%s' "$s"
}

# limit_names RAW: the failed test names as the notice and the job output show them
# (FR-003). RAW is one name per line, possibly ending in the "... y N mas" line that
# collect leaves when it already cut the list. Sets NAMES (at most 20 names, each one
# sanitised and cut to 120 characters, one per line), NAMES_N (how many are in NAMES)
# and EXTRA (how many more failed that NAMES does not list).
limit_names() {
  local line k
  NAMES=""
  NAMES_N=0
  EXTRA=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '... y '*' mas')
        k="${line#... y }"
        k="${k% mas}"
        case "$k" in
          ''|*[!0-9]*) ;;
          *)
            if [ "${#k}" -le 9 ]; then
              EXTRA=$((EXTRA + 10#$k))
              continue
            fi
            ;;
        esac
        ;;
    esac
    line=$(san "$line")
    if [ -z "$line" ]; then continue; fi
    if [ "$NAMES_N" -ge 20 ]; then
      EXTRA=$((EXTRA + 1))
      continue
    fi
    if [ -n "$NAMES" ]; then NAMES="$NAMES"$'\n'"$line"; else NAMES="$line"; fi
    NAMES_N=$((NAMES_N + 1))
  done <<< "$1"
}

# emit LINE: one line of the job outputs (GITHUB_OUTPUT, or stdout when unset).
emit() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s\n' "$1" >> "$GITHUB_OUTPUT"
  else
    printf '%s\n' "$1"
  fi
}

# rand_delim: a delimiter no test name can guess, for multi-line outputs.
rand_delim() {
  local d
  d=$(od -An -N12 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
  if [ -z "$d" ]; then d="$RANDOM$RANDOM$RANDOM$$"; fi
  printf 'ghadelim_%s' "$d"
}

# -- collect ----------------------------------------------------------------------

collect() {
  local failed="" summary="" names="" raw="" total skipped nfailed executed line name delim

  if [ -n "${STEPS_JSON:-}" ] && make_tmp; then
    printf '%s' "$STEPS_JSON" > "$TMP_DIR/steps.json"
    failed=$(jq -r 'to_entries | map(select(.key != "collect" and (.value.outcome == "failure" or .value.outcome == "cancelled"))) | (.[0].key // "")' "$TMP_DIR/steps.json" 2>/dev/null) || failed=""
    failed=${failed//[^A-Za-z0-9_-]/}
  fi

  if [ -f e2e.tap ] && make_tmp; then
    total=$(grep -c -E '^(ok|not ok) [0-9]+' e2e.tap || true)
    skipped=$(grep -c -E '^ok [0-9]+ .*# skip' e2e.tap || true)
    nfailed=$(grep -c -E '^not ok [0-9]+' e2e.tap || true)
    executed=$((total - skipped))
    summary="total=$total executed=$executed skipped=$skipped failed=$nfailed"
    grep -E '^not ok [0-9]+ ' e2e.tap > "$TMP_DIR/notok.txt" || true
    while IFS= read -r line || [ -n "$line" ]; do
      name=${line#not ok }
      name=${name#* }
      raw="$raw$name"$'\n'
    done < "$TMP_DIR/notok.txt"
    limit_names "$raw"
    names="$NAMES"
    if [ "$EXTRA" -gt 0 ]; then names="$names"$'\n'"... y $EXTRA mas"; fi
  fi

  emit "failed_step=$failed"
  emit "summary=$summary"
  delim=$(rand_delim)
  emit "failed_tests<<$delim"
  if [ -n "$names" ]; then emit "$names"; fi
  emit "$delim"
  return 0
}

# -- notify -----------------------------------------------------------------------

# night_iso: the date of the night in UTC (YYYY-MM-DD). NIGHTLY_ALERT_NOW, seconds
# since the epoch, replaces the clock; the tests use it (GNU date takes -d @N, BSD
# date takes -r N).
night_iso() {
  local n="${NIGHTLY_ALERT_NOW:-}"
  case "$n" in
    ''|*[!0-9]*) date -u +%Y-%m-%d ;;
    *) date -u -d "@$n" +%Y-%m-%d 2>/dev/null || date -u -r "$n" +%Y-%m-%d ;;
  esac
}

# iso_to_dmy YYYY-MM-DD: the same date as DD-MM-YYYY, the form for people.
iso_to_dmy() {
  printf '%s-%s-%s' "${1:8:2}" "${1:5:2}" "${1:0:4}"
}

# nights_word N: "noche" for 1, "noches" otherwise.
nights_word() {
  if [ "$1" = 1 ]; then printf 'noche'; else printf 'noches'; fi
}

# gh_limited ARGS...: gh with a time limit. A gh that stalls (the API accepts the call and
# never answers) must not take the push to Telegram with it: the step has 3 minutes in all
# and the push comes after every gh call, so a stall would turn a red night silent, the
# failure this feature exists to end. Each call is cut at GH_CALL_TIMEOUT seconds (30 by
# default); the caller's redirections apply to gh. It returns what gh returned, or 143 when
# it had to be cut. A coreutils `timeout` is not used because macOS does not have one and
# the tests run there. GH_CALL_TIMEOUT and GH_BUDGET only exist as seams for the tests.
gh_limited() {
  local per="${GH_CALL_TIMEOUT:-30}" pid ticks=0 max
  case "$per" in ''|*[!0-9]*|???????*) per=30 ;; esac
  per=$((10#$per))
  if [ "$per" -eq 0 ]; then per=30; fi
  max=$((per * 20))
  gh "$@" &
  pid=$!
  while kill -0 "$pid" 2> /dev/null; do
    if [ "$ticks" -ge "$max" ]; then
      kill "$pid" 2> /dev/null
      break
    fi
    sleep 0.05
    ticks=$((ticks + 1))
  done
  wait "$pid" 2> /dev/null
}

# gh_budget_spent: true once the run has used up GH_BUDGET seconds (100 by default) on the
# way to the push: from then on no further gh call is started, so the push still has the
# time that is left of the step. SECONDS counts from the start of the script.
gh_budget_spent() {
  local b="${GH_BUDGET:-100}"
  case "$b" in ''|*[!0-9]*|???????*) b=100 ;; esac
  [ "$SECONDS" -ge "$((10#$b))" ]
}

# gh_run ACTION OUTFILE ARGS...: run gh with its stdout in OUTFILE. A failure is
# announced here, with the first line gh complained about, and returned to the
# caller; it is never fatal.
gh_run() {
  local action="$1" out="$2" rc errline=""
  shift 2
  if gh_budget_spent; then
    : > "$out"
    warn "no se pudo $action: se agoto el tiempo de las llamadas a gh"
    return 124
  fi
  gh_limited "$@" > "$out" 2> "$TMP_DIR/gh.err"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ -r "$TMP_DIR/gh.err" ]; then IFS= read -r errline < "$TMP_DIR/gh.err"; fi
    warn "no se pudo $action: gh salio con $rc: $(san "$errline")"
  fi
  return "$rc"
}

# parse_marker LINE: sets M_VALID (1 or 0) and, when valid, M_STATE, M_TOTAL and
# M_FIRST (NF section 2). Anything that does not match the expression is invalid. The
# total has at most 9 digits and is read as a DECIMAL: in bash arithmetic 08 is an
# invalid octal that would kill the script, and more digits would overflow in silence.
parse_marker() {
  local re='^<!-- nightly-red:v1 state=(open|resolved) total=([0-9]{1,9}) first=([0-9]{4}-[0-9]{2}-[0-9]{2}) -->$'
  M_VALID=0
  M_STATE=""
  M_TOTAL=0
  M_FIRST=""
  if [[ $1 =~ $re ]]; then
    M_VALID=1
    M_STATE="${BASH_REMATCH[1]}"
    M_TOTAL=$((10#${BASH_REMATCH[2]}))
    M_FIRST="${BASH_REMATCH[3]}"
  fi
}

# step_cell: the failed step as the table and the comments show it.
step_cell() {
  if [ -n "$STEP_S" ]; then printf '`%s`' "$STEP_S"; else printf -- '-'; fi
}

# night_row: the table row of this night (NF section 3).
night_row() {
  printf '| %s | [run %s](%s) | %s |\n' "$NIGHT_DMY" "$RUN_ID" "$RUN_URL" "$(step_cell)"
}

# build_rows KEEP_OLD: rows.md holds this night's row and, when KEEP_OLD is 1, the rows
# the notice already had, newest first. Only rows of the exact shape the script writes
# are carried over: whatever a person typed into the table is dropped.
build_rows() {
  night_row > "$TMP_DIR/rows.md"
  if [ "$1" = 1 ]; then
    printf '%s\n' "$OLD_BODY" > "$TMP_DIR/old-body.md"
    grep -E '^\| [0-9]{2}-[0-9]{2}-[0-9]{4} \| \[run [0-9]+\]\(https?://[^ )]*\) \| (`[A-Za-z0-9_-]+`|-) \|$' "$TMP_DIR/old-body.md" > "$TMP_DIR/old-rows.md" || true
    awk 'NR <= 9' "$TMP_DIR/old-rows.md" >> "$TMP_DIR/rows.md"
  fi
}

# write_body OUTFILE: the notice body of NF section 3. The caller sets B_STATE,
# B_TOTAL, B_FIRST (the marker) and has built rows.md; the facts of the night are
# TITLE, RUN_ID, RUN_URL, SUM_S, NAMES and NAMES_N.
write_body() {
  local out="$1" dmy intro
  dmy=$(iso_to_dmy "$B_FIRST")
  if [ "$B_TOTAL" = 1 ]; then
    intro="Racha de **1** noche programada en rojo, desde el $dmy (UTC)."
  else
    intro="Racha de **$B_TOTAL** noches programadas seguidas en rojo, desde el $dmy (UTC)."
  fi
  {
    printf '<!-- nightly-red:v1 state=%s total=%s first=%s -->\n' "$B_STATE" "$B_TOTAL" "$B_FIRST"
    printf '# %s\n\n' "$TITLE"
    printf '%s Ultima: [run %s](%s).\n\n' "$intro" "$RUN_ID" "$RUN_URL"
    printf 'Este aviso se cierra solo cuando una noche programada vuelve a verde. Si lo cierras a mano mientras sigue en rojo, se reabre la noche siguiente. El cuerpo se regenera cada noche: deja tus notas como comentarios.\n\n'
    printf '## Ultimas noches\n\n'
    printf '| Noche (UTC) | Corrida | Paso que fallo |\n|---|---|---|\n'
    cat "$TMP_DIR/rows.md"
    printf '\n## Ultima noche\n\n'
    if [ -n "$SUM_S" ]; then
      printf -- '- Resumen de la suite: `%s`\n' "$SUM_S"
    else
      printf -- '- Resumen de la suite: no disponible (la corrida fallo antes de la suite o no dejo e2e.tap)\n'
    fi
    if [ "$NAMES_N" -gt 0 ]; then
      printf -- '- Tests que fallaron (%s):\n\n' "$((NAMES_N + EXTRA))"
      printf '~~~text\n%s\n' "$NAMES"
      if [ "$EXTRA" -gt 0 ]; then printf '... y %s mas\n' "$EXTRA"; fi
      printf '~~~\n'
    else
      printf -- '- Tests que fallaron: ninguno informado\n'
    fi
  } > "$out"
}

# ensure_label: the label is the identity of the notice. Creating it is only needed
# the very first time; an error here (it already exists, or no permission) is
# reported and ignored, because a missing label shows up in the next call anyway.
ensure_label() {
  if gh_budget_spent || ! gh_limited label create "$1" --color "$2" --description "$3" > /dev/null 2> "$TMP_DIR/gh.err"; then
    say_notice "la etiqueta $1 no se creo (ya existe, o no hay permiso): se sigue"
  fi
}

# create_notice BODYFILE: create the issue, assigned to ASSIGNEE. If the assignment
# is what fails (FR-019) the notice is published anyway, without assignee, and the
# problem is announced: a notice nobody is assigned to still beats no notice.
create_notice() {
  if [ -n "${ASSIGNEE:-}" ]; then
    if gh_run "crear el aviso" "$TMP_DIR/create.out" issue create --title "$TITLE" --label "$LABEL" --assignee "$ASSIGNEE" --body-file "$1"; then
      return 0
    fi
    if gh_run "crear el aviso sin asignado" "$TMP_DIR/create.out" issue create --title "$TITLE" --label "$LABEL" --body-file "$1"; then
      warn "el aviso se creo sin asignado: no se pudo asignar a $ASSIGNEE"
      return 0
    fi
    return 1
  fi
  gh_run "crear el aviso" "$TMP_DIR/create.out" issue create --title "$TITLE" --label "$LABEL" --body-file "$1"
}

# night_comment: the one-line comment for a red night added to a streak (NF section 4).
night_comment() {
  local sum="no disponible"
  if [ -n "$SUM_S" ]; then sum="\`$SUM_S\`"; fi
  if [ "$M_VALID" = 1 ]; then
    printf 'Noche %s de la racha: [run %s](%s). Paso que fallo: %s. Resumen: %s.\n' "$B_TOTAL" "$RUN_ID" "$RUN_URL" "$(step_cell)" "$sum"
  else
    printf 'Noche en rojo: [run %s](%s). Paso que fallo: %s. Resumen: %s. El marcador de este aviso no es valido (alguien edito el cuerpo), asi que el cuerpo no se reescribe.\n' "$RUN_ID" "$RUN_URL" "$(step_cell)" "$sum"
  fi
}

# green_comment: the comment that closes a streak (NF section 4).
green_comment() {
  if [ "$M_VALID" = 1 ]; then
    printf 'Verde: la noche programada [run %s](%s) paso. Se cierra el aviso (racha de %s %s, desde %s).\n' "$RUN_ID" "$RUN_URL" "$M_TOTAL" "$(nights_word "$M_TOTAL")" "$(iso_to_dmy "$M_FIRST")"
  else
    printf 'Verde: la noche programada [run %s](%s) paso. Se cierra el aviso.\n' "$RUN_ID" "$RUN_URL"
  fi
}

# reopen_comment: the comment that goes with a reopened notice (NF section 4).
reopen_comment() {
  printf 'Se reabre: la noche sigue en rojo ([run %s](%s)). El aviso se habia cerrado a mano mientras la racha seguia.' "$RUN_ID" "$RUN_URL"
}

# -- the five things notify can do to a notice -------------------------------------

REOPENED=0

# do_create: the first night of a streak (the previous notice, if any, is history).
do_create() {
  if [ -z "$U_NUM" ]; then ensure_label "$LABEL" "$COLOR" "$LDESC"; fi
  B_STATE=open
  B_TOTAL=1
  B_FIRST="$NIGHT"
  build_rows 0
  write_body "$TMP_DIR/body.md"
  create_notice "$TMP_DIR/body.md"
}

# do_update REOPEN: one more night in the streak that the open (or hand-closed)
# notice tracks. REOPEN is 1 when the notice must be reopened first. With a marker
# that no longer parses the body is left exactly as the person wrote it: the night
# is only commented.
do_update() {
  REOPENED=0
  if [ "$1" = 1 ]; then
    if gh_run "reabrir el aviso" /dev/null issue reopen "$U_NUM" --comment "$(reopen_comment)"; then REOPENED=1; fi
  fi
  if [ "$M_VALID" = 1 ]; then
    B_STATE=open
    B_TOTAL=$((M_TOTAL + 1))
    B_FIRST="$M_FIRST"
    build_rows 1
    write_body "$TMP_DIR/body.md"
    gh_run "actualizar el aviso" /dev/null issue edit "$U_NUM" --body-file "$TMP_DIR/body.md"
  else
    warn "el marcador del aviso #$U_NUM no es valido: se comenta la noche y el cuerpo no se reescribe"
  fi
  night_comment > "$TMP_DIR/comment.md"
  gh_run "comentar la noche" /dev/null issue comment "$U_NUM" --body-file "$TMP_DIR/comment.md"
}

# rewrite_marker STATE: old-body.md with only its first line replaced by the marker
# of the same streak in STATE.
rewrite_marker() {
  printf '%s\n' "$OLD_BODY" > "$TMP_DIR/old-body.md"
  awk 'NR > 1' "$TMP_DIR/old-body.md" > "$TMP_DIR/old-rest.md"
  {
    printf '<!-- nightly-red:v1 state=%s total=%s first=%s -->\n' "$1" "$M_TOTAL" "$M_FIRST"
    cat "$TMP_DIR/old-rest.md"
  } > "$TMP_DIR/body.md"
}

# do_close: a green night over an open notice: mark it resolved, say why, close it.
# If the marker cannot be rewritten the notice is NOT closed: a closed notice that still
# says state=open would be taken for one closed by hand and the next red night would
# reopen it and carry the old streak on. It stays open, and the next green night does
# the whole job again. It returns 0 only when the notice really got closed, because the
# recovery message follows exactly that (FR-020): a night that could not close the notice
# says nothing, and the next green night, which repeats the job, says it once.
do_close() {
  if [ "$M_VALID" = 1 ]; then
    rewrite_marker resolved
    if ! gh_run "marcar el aviso como resuelto" /dev/null issue edit "$U_NUM" --body-file "$TMP_DIR/body.md"; then
      warn "el aviso #$U_NUM sigue abierto: no se pudo marcar como resuelto y la proxima noche verde lo reintenta"
      return 1
    fi
  else
    warn "el marcador del aviso #$U_NUM no es valido: se cierra con un comentario y el cuerpo no se reescribe"
  fi
  green_comment > "$TMP_DIR/comment.md"
  gh_run "comentar el cierre" /dev/null issue comment "$U_NUM" --body-file "$TMP_DIR/comment.md"
  gh_run "cerrar el aviso" /dev/null issue close "$U_NUM" --reason completed
}

# do_resolve: a green night over a notice that a person closed by hand while the
# streak was on: only its marker changes (a single edit), so the next red night
# opens a new notice instead of reopening an old one.
do_resolve() {
  rewrite_marker resolved
  gh_run "marcar el aviso como resuelto" /dev/null issue edit "$U_NUM" --body-file "$TMP_DIR/body.md"
}

# -- the push to Telegram (amendment 1) ---------------------------------------------------
# Contract: specs/040-nightly-red-alert/contracts/telegram-push.md. The notice on the
# issue is the state and the history of the streak; this is what reaches the maintainer
# where they look. Nothing in this section can change the exit code of the script (FR-009).

TG_TOKEN=""
TG_CHAT=""
TG_WHY=""
TG_MSG=""
TG_PRE=""

# tg_redact TEXT: TEXT with the bot token, if it is in there, replaced by ***. It runs on
# anything that is about to be printed and could carry it (the error line of curl, the
# description of an answer) BEFORE that text is cut to its length: cutting first could
# leave half a token that no longer matches. Only a token that passed tg_check is ever
# used as a pattern, and that shape (digits, a colon, letters, digits, - and _) holds no
# glob character; the replacement is a constant.
tg_redact() {
  local t="$1"
  if [ -n "$TG_TOKEN" ]; then t=${t//"$TG_TOKEN"/"***"}; fi
  printf '%s' "$t"
}

# tg_check: sets TG_WHY to the reason the push cannot go out, or to "" when it can. Both
# secrets are checked against the shape of a real bot token and of a real chat id before
# one byte of them is written anywhere: that shape holds no quote, backslash, space or
# newline, so neither can break out of the curl config file. The endpoint is held to the
# same rule. The warning names the variable and never repeats what it held.
tg_check() {
  local re_token='^[0-9]{3,20}:[A-Za-z0-9_-]{20,80}$'
  local re_chat='^(-?[0-9]{1,20}|@[A-Za-z0-9_]{5,32})$'
  local re_base='^(https://api\.telegram\.org|http://127\.0\.0\.1:[0-9]{1,5})$'
  TG_WHY=""
  if [ -z "$TG_TOKEN" ]; then
    TG_WHY="falta TELEGRAM_BOT_TOKEN"
  elif [ -z "$TG_CHAT" ]; then
    TG_WHY="falta TELEGRAM_CHAT_ID"
  elif ! [[ $TG_TOKEN =~ $re_token ]]; then
    TG_WHY="TELEGRAM_BOT_TOKEN tiene un formato inesperado"
  elif ! [[ $TG_CHAT =~ $re_chat ]]; then
    TG_WHY="TELEGRAM_CHAT_ID tiene un formato inesperado"
  elif ! [[ ${TELEGRAM_API_BASE:-https://api.telegram.org} =~ $re_base ]]; then
    # the token travels to this address: only the Telegram API (or, for the tests, the local
    # server) may receive it, and whatever is here goes into the curl config file
    TG_WHY="TELEGRAM_API_BASE no es la API de Telegram"
  fi
}

# clean_url TEXT: TEXT reduced to the characters of a URL, the same set as RUN_URL.
clean_url() {
  local keep='A-Za-z0-9._~:/?#@!&*+,;=%-'
  printf '%s' "${1//[^$keep]/}"
}

# created_url: the URL gh printed for the issue it has just created (the last line of
# its output), or nothing.
created_url() {
  local line="" last=""
  if [ -r "$TMP_DIR/create.out" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      if [ -n "$line" ]; then last="$line"; fi
    done < "$TMP_DIR/create.out"
  fi
  case "$last" in
    https://*) clean_url "$last" ;;
  esac
}

# tg_add LINE: one more line of the message.
tg_add() {
  if [ -n "$TG_MSG" ]; then TG_MSG="$TG_MSG"$'\n'"$1"; else TG_MSG="$1"; fi
}

# tg_text KIND ISSUE_URL: sets TG_MSG, the message of KIND (telegram-push.md section 3).
# Plain text of printable ASCII; every datum that comes from outside went through san,
# the step id and the URLs through their own filters, so nothing in it can be markup. The
# streak line comes from the marker of the notice and is left out when the marker is not
# valid: a number nobody can verify is not printed. A green night has no step and no
# summary to report.
tg_text() {
  local kind="$1" issue_url="$2" red=1 nl=$'\n'
  TG_MSG=""
  case "$kind" in
    rojo-nuevo)
      tg_add "docker-e2e nightly EN ROJO"
      tg_add "Racha: noche 1 (desde $NIGHT_DMY)"
      ;;
    rojo-sigue|rojo-reabierto)
      if [ "$kind" = rojo-sigue ]; then
        tg_add "docker-e2e nightly SIGUE EN ROJO"
      else
        tg_add "docker-e2e nightly SIGUE EN ROJO (aviso reabierto)"
      fi
      # a marker that already says "resolved" on an open notice (its close failed after the
      # rest went through) belongs to a streak that ended: no number is better than a wrong one
      if [ "$M_VALID" = 1 ] && [ "$M_STATE" = open ]; then
        tg_add "Racha: noche $((M_TOTAL + 1)) (desde $(iso_to_dmy "$M_FIRST"))"
      fi
      ;;
    rojo-sin-aviso)
      # the notice could not even be looked up: nothing is known about the streak
      tg_add "docker-e2e nightly EN ROJO"
      ;;
    verde)
      red=0
      tg_add "docker-e2e nightly VOLVIO A VERDE"
      if [ "$M_VALID" = 1 ]; then
        tg_add "La racha duro $M_TOTAL $(nights_word "$M_TOTAL") (desde $(iso_to_dmy "$M_FIRST"))"
      fi
      ;;
  esac
  if [ "$red" = 1 ]; then
    if [ -n "$STEP_S" ]; then tg_add "Paso que fallo: $STEP_S"; fi
    if [ -n "$SUM_S" ]; then tg_add "Resumen: $SUM_S"; fi
  fi
  tg_add "Corrida: $RUN_URL"
  if [ -n "$issue_url" ]; then tg_add "Aviso: $issue_url"; fi
  # the guarantee does not rest on every field above: whatever is left that is not
  # printable ASCII or the newline between two lines becomes a question mark. A trial is
  # told apart from a real night by a prefix on the first line (FR-020).
  TG_MSG=${TG_MSG//[^$nl -~]/?}
  TG_MSG="${TG_PRE}${TG_MSG}"
}

# tg_push KIND ISSUE_URL: send the message of KIND to the maintainer's chat, once. The
# token is written to a curl config file of mode 0600 in the private temp directory (the
# trap removes it) and curl is started as `curl -K file`, so it never appears on a
# command line; the message goes in as text@file. Success is HTTP 200 with "ok": true.
tg_push() {
  local kind="$1" issue_url="${2:-}" base max http rc errline desc why
  tg_check
  if [ -n "$TG_WHY" ]; then
    warn "empuje por Telegram omitido: $TG_WHY"
    return 0
  fi
  tg_text "$kind" "$issue_url"
  printf '%s' "$TG_MSG" > "$TMP_DIR/tg-text.txt"
  base="${TELEGRAM_API_BASE:-https://api.telegram.org}"
  max="${TELEGRAM_MAX_TIME:-15}"
  case "$max" in ''|*[!0-9]*|???????*) max=15 ;; esac
  max=$((10#$max))
  if [ "$max" -eq 0 ]; then max=15; fi
  : > "$TMP_DIR/tg.conf"
  chmod 600 "$TMP_DIR/tg.conf"
  {
    printf 'silent\nshow-error\n'
    printf 'max-time = "%s"\n' "$max"
    printf 'output = "%s/tg-response.json"\n' "$TMP_DIR"
    printf 'write-out = "%%{http_code}"\n'
    printf 'url = "%s/bot%s/sendMessage"\n' "$base" "$TG_TOKEN"
    printf 'data-urlencode = "chat_id=%s"\n' "$TG_CHAT"
    printf 'data-urlencode = "text@%s/tg-text.txt"\n' "$TMP_DIR"
    printf 'data-urlencode = "link_preview_options={\\"is_disabled\\":true}"\n'
    # the recovery is the one message that must not ring (FR-023)
    if [ "$kind" = verde ]; then printf 'data-urlencode = "disable_notification=true"\n'; fi
  } >> "$TMP_DIR/tg.conf"
  http=$(curl -K "$TMP_DIR/tg.conf" 2> "$TMP_DIR/tg-curl.err")
  rc=$?
  if [ "$rc" -eq 0 ] && [ "$http" = 200 ] && jq -e '.ok == true' "$TMP_DIR/tg-response.json" > /dev/null 2>&1; then
    say_notice "telegram enviado (tipo=$kind)"
    return 0
  fi
  # whatever went wrong is one warning with the reason and nothing else: the notice is
  # already on the issue and the exit code of the script stays 0 (R22: one attempt only)
  if [ "$rc" -ne 0 ]; then
    errline=""
    if [ -r "$TMP_DIR/tg-curl.err" ]; then IFS= read -r errline < "$TMP_DIR/tg-curl.err"; fi
    why="curl salio con $rc: $(san "$(tg_redact "$errline")")"
  else
    desc=$(jq -r '.description // empty' "$TMP_DIR/tg-response.json" 2> /dev/null) || desc=""
    why="HTTP $(san "$http" 3)"
    if [ -n "$desc" ]; then why="$why $(san "$(tg_redact "$desc")")"; fi
  fi
  warn "no se pudo enviar el empuje por Telegram (tipo=$kind): $(tg_redact "$why")"
  return 0
}

notify() {
  local mode class plan action reason result_s url_keep created

  # the two secrets of the push: read once into shell variables and taken out of the
  # environment, so gh, jq and date, which never need them, do not inherit them
  TG_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
  TG_CHAT="${TELEGRAM_CHAT_ID:-}"
  unset TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID

  # the run id is a number and the run URL stays one inert link: both go into a markdown
  # link, so whatever else the variables carry (spaces, brackets, parentheses, quotes)
  # is not part of them
  RUN_ID="${RUN_ID//[^0-9]/}"
  if [ -z "$RUN_ID" ]; then RUN_ID=0; fi
  RUN_URL="${RUN_URL:-}"
  if [ -z "$RUN_URL" ] && [ -n "${GH_REPO:-}" ]; then
    RUN_URL="https://github.com/$GH_REPO/actions/runs/$RUN_ID"
  fi
  url_keep='A-Za-z0-9._~:/?#@!&*+,;=%-'
  RUN_URL="${RUN_URL//[^$url_keep]/}"
  result_s=$(san "${RUN_RESULT:-}")

  # who may move which notice: scheduled runs the real one, trial runs the trial one,
  # a normal manual run nothing (FR-011)
  case "${EVENT:-}" in
    schedule) mode=real ;;
    workflow_dispatch)
      if [ "${TRIAL:-}" = "true" ]; then mode=trial; else mode=ninguno; fi ;;
    *) mode=ninguno ;;
  esac
  case "${RUN_RESULT:-}" in
    success) class=green ;;
    failure) class=red ;;
    *) class=none ;;
  esac
  TG_PRE=""
  if [ "$mode" = trial ]; then TG_PRE="[ensayo] "; fi
  if [ "$mode" = ninguno ]; then
    say_notice "modo=ninguno resultado=$result_s accion=ninguna motivo=corrida manual normal, no mueve el aviso"
    return 0
  fi
  if [ "$class" = none ]; then
    say_notice "modo=$mode resultado=$result_s accion=ninguna motivo=ni verde ni rojo (cancelada, saltada u otro valor)"
    return 0
  fi

  if [ "$mode" = trial ]; then
    LABEL=nightly-red-trial
    COLOR=FBCA04
    LDESC="Ensayo del aviso del nightly"
    TITLE="[ensayo] docker-e2e nightly en rojo"
  else
    LABEL=nightly-red
    COLOR=D93F0B
    LDESC="Nightly docker-e2e en rojo (aviso automatico)"
    TITLE="docker-e2e nightly en rojo"
  fi

  # a step id is a word: whatever else the variable carries is not part of it
  STEP_S=$(san "${FAILED_STEP:-}")
  STEP_S=${STEP_S//[^A-Za-z0-9_-]/}
  SUM_S=$(san "${SUMMARY:-}")
  limit_names "${FAILED_TESTS:-}"
  NIGHT=$(night_iso)
  NIGHT_DMY=$(iso_to_dmy "$NIGHT")

  if ! make_tmp; then
    warn "no se pudo crear el directorio temporal"
    return 0
  fi

  # the latest notice of this mode, whatever its state. Without it nothing can be
  # decided: say so and stop (exit 0 all the same).
  if ! gh_run "buscar el aviso" "$TMP_DIR/list.json" issue list --label "$LABEL" --state all --limit 1 --json number,state,body,url; then
    if [ "$class" = red ]; then tg_push rojo-sin-aviso ""; fi
    return 0
  fi
  if ! jq -e 'type == "array"' "$TMP_DIR/list.json" > /dev/null 2>&1; then
    warn "no se pudo buscar el aviso: gh no devolvio una lista"
    if [ "$class" = red ]; then tg_push rojo-sin-aviso ""; fi
    return 0
  fi
  U_NUM=$(jq -r '.[0].number // empty' "$TMP_DIR/list.json")
  U_STATE=$(jq -r '.[0].state // empty' "$TMP_DIR/list.json")
  U_URL=$(clean_url "$(jq -r '.[0].url // empty' "$TMP_DIR/list.json")")
  OLD_BODY=$(jq -r '.[0].body // ""' "$TMP_DIR/list.json")
  # GitHub keeps the line endings it was given, and the web editor sends CRLF: a notice
  # that a person saved there must still be recognised
  OLD_BODY=${OLD_BODY//$'\r'/}
  parse_marker "${OLD_BODY%%$'\n'*}"

  # the decision table (data-model.md section 5)
  plan=none
  reason=""
  if [ "$class" = red ]; then
    if [ -z "$U_NUM" ]; then
      plan=create
    elif [ "$U_STATE" = OPEN ]; then
      case "$OLD_BODY" in
        *"[run $RUN_ID]("*) reason="la noche ya esta registrada" ;;
        *) plan=update ;;
      esac
    elif [ "$M_VALID" = 1 ] && [ "$M_STATE" = resolved ]; then
      plan=create
      reason="racha nueva: el aviso anterior se cerro con el verde"
    else
      plan=reopen
      reason="el aviso se cerro a mano con la racha en curso"
    fi
  else
    if [ -z "$U_NUM" ]; then
      reason="no hay aviso"
    elif [ "$U_STATE" = OPEN ]; then
      plan=close
    elif [ "$M_VALID" = 1 ] && [ "$M_STATE" = open ]; then
      plan=resolve
      reason="cerrado a mano: solo se marca como resuelto"
    else
      reason="el ultimo aviso ya esta resuelto"
    fi
  fi
  case "$plan" in
    create)  action=crea ;;
    update)  action=actualiza ;;
    reopen)  action=reabre ;;
    close)   action=cierra ;;
    resolve) action=actualiza ;;
    *)       action=ninguna ;;
  esac
  say_notice "modo=$mode resultado=$result_s accion=$action${reason:+ motivo=$reason}"

  case "$plan" in
    create)
      if do_create; then created=$(created_url); else created=""; fi
      tg_push rojo-nuevo "$created"
      ;;
    update)
      do_update 0
      tg_push rojo-sigue "$U_URL"
      ;;
    reopen)
      # the message says "reabierto" only if gh did reopen the notice
      do_update 1
      if [ "$REOPENED" = 1 ]; then tg_push rojo-reabierto "$U_URL"; else tg_push rojo-sigue "$U_URL"; fi
      ;;
    close)
      if do_close; then tg_push verde "$U_URL"; fi
      ;;
    resolve) do_resolve ;;
  esac
  return 0
}

# -- simulate ---------------------------------------------------------------------

# simulate OUTCOME: stands in for the suite in a trial run (the workflow skips the
# suite and calls this instead), so every path of the notice can be exercised for real
# without spending the ~15 minutes of the suite. It leaves an e2e.tap that says it is a
# trial and prints nothing that reads like a result of the real suite.
#   red      a TAP with one failure; exits 1 on purpose
#   green    a TAP with no failure; exits 0
#   timeout  sleeps TRIAL_TIMEOUT_SLEEP seconds (120 by default), longer than the 1
#            minute limit the workflow gives the job in this case, so the platform
#            has to end it
simulate() {
  case "${1:-}" in
    red)
      printf '1..4\nok 1 trial passing 1\nok 2 trial passing 2\nok 3 trial passing 3\nnot ok 4 trial: induced failure\n' > e2e.tap
      echo "trial: simulated outcome red (no suite ran); exiting 1 on purpose"
      return 1
      ;;
    green)
      printf '1..4\nok 1 trial passing 1\nok 2 trial passing 2\nok 3 trial passing 3\nok 4 trial passing 4\n' > e2e.tap
      echo "trial: simulated outcome green (no suite ran)"
      return 0
      ;;
    timeout)
      printf '1..1\n' > e2e.tap
      echo "trial: simulated outcome timeout (no suite ran); sleeping ${TRIAL_TIMEOUT_SLEEP:-120} seconds on purpose"
      sleep "${TRIAL_TIMEOUT_SLEEP:-120}"
      return 0
      ;;
    *)
      usage
      return 2
      ;;
  esac
}

# -- dispatch ---------------------------------------------------------------------

case "${1:-}" in
  collect)  collect; exit 0 ;;
  notify)   notify; exit 0 ;;
  simulate) simulate "${2:-}"; exit $? ;;
  *) usage; exit 2 ;;
esac
