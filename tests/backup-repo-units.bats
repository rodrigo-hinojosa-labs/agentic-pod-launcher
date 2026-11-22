#!/usr/bin/env bats
#
# 046: las cinco unidades de respaldo con un repositorio asociado (identity, vault,
# config, memory e history), su cron, el supervisor, y que el camino del fork y el de
# un agente sin destino no cambian.
#
# Contratos: specs/046-agent-backup-repo/contracts/backup-units.md (U1 a U9),
# destination-and-credential.md (C1 a C8) y block-store.md. Lo que significa cada
# prueba: seccion V2 de specs/046-agent-backup-repo/contracts/evidence.md (TU01 a
# TU40).
#
# Reglas (tasks.md de 046): ningun [[ ]] ni ! intermedio; los mensajes que se
# afirman son los de la tabla de U1 de backup-units.md, la unica fuente; una prueba
# no detecta la sonda anonima contando peticiones auth=none; cada doble usa un
# valor distinto por fuente; un criterio nombra pruebas enteras.

load helper
load helper-backup-repo

setup_file() {
  br_require || return 1
  br_start_server
}

teardown_file() { br_stop_server; }

setup() {
  br_require
  br_tools_path
  br_sentinels
  br_server_token "$BR_TOKEN"
  br_server_mode
  unset BR_PAT BR_VAULT_DIR
}

# ── TU31: lo horneado tiene su COPY (nace en verde) ─────────────────────────

@test "TU31: every file under docker/scripts has its COPY line in the Dockerfile" {
  local files f rel n=0
  files=$(cd "$REPO_ROOT" && git ls-files --cached --others --exclude-standard docker/scripts)
  for f in $files; do
    rel="${f#docker/}"
    n=$((n + 1))
    if ! grep -qE "^COPY ${rel//./\\.}[[:space:]]" "$REPO_ROOT/docker/Dockerfile"; then
      echo "no COPY line for $rel in docker/Dockerfile" >&2
      false
    fi
  done
  [ "$n" -ge 15 ]
}

# ── Ayudantes de este archivo ───────────────────────────────────────────────

# _tu_repo NOMBRE [--empty]: un workspace nuevo asociado a un repositorio nuevo.
_tu_repo() {
  br_workspace
  local url
  url=$(br_new_repo "$1" "${2:-}")
  br_set_repo "$url"
  TU_URL="$url"
  TU_REPO="$1"
}

# _tu_msg UNIDAD RESULTADO: el mensaje de la tabla de U1 (backup-units.md).
_tu_msg() {
  local u="$1"
  case "$2" in
    no-credential)  printf 'backup-%s: no GITHUB_PAT in the environment - cannot push to the agent repository' "$u" ;;
    no-recipient)   printf 'backup-%s: no encryption key (backup.identity.recipient) - nothing pushed' "$u" ;;
    not-private)    printf 'backup-%s: the repository is public - refusing to push' "$u" ;;
    unverified)     printf 'backup-%s: could not verify that the repository is private - refusing to push' "$u" ;;
    foreign-branch) printf 'backup-%s: branch backup/%s exists and is not a launcher backup - refusing to write' "$u" "$u" ;;
    other-agent)    printf 'backup-%s: branch backup/%s belongs to another agent - refusing to write' "$u" "$u" ;;
    unreachable)    printf 'backup-%s: repository unreachable (credential, network or missing repository)' "$u" ;;
    push-failed)    printf 'backup-%s: push failed' "$u" ;;
    locked)         printf 'backup-%s: another run holds the lock - skipping' "$u" ;;
    nothing)        printf 'backup-%s: nothing to back up yet' "$u" ;;
    no-main)        printf 'backup-%s: the repository has no main branch - nothing pushed' "$u" ;;
    foreign-dir)    printf 'backup-%s: .agent-backup/%s exists in main and is not a launcher backup - refusing to write' "$u" "$u" ;;
    other-agent-dir) printf 'backup-%s: .agent-backup/%s in main belongs to another agent - refusing to write' "$u" "$u" ;;
  esac
}

# 048: _tu_main_edit NAME SCRIPT: a commit on main of the test repository made by
# "someone else", running SCRIPT (sh) in a clone of main.
_tu_main_edit() {
  local seed="$BATS_TEST_TMPDIR/edit-$1-$RANDOM"
  _br_git clone -q "$(br_bare "$1")" "$seed"
  (cd "$seed" && sh -c "$2")
  _br_git -C "$seed" add -A
  _br_git -C "$seed" commit -q -m "edited by someone else"
  _br_git -C "$seed" push -q origin HEAD:refs/heads/main
  rm -rf "$seed"
}

# 048: _tu_unit_rev NAME UNIT N: the Nth newest commit of main that touches the
# unit's directory (1 = the newest).
_tu_unit_rev() {
  _br_git -C "$(br_bare "$1")" rev-list refs/heads/main -- ".agent-backup/$2" | sed -n "${3}p"
}

_tu_mtime() { perl -e 'print((stat shift)[9])' "$1"; }

# ── US1: identity llega al repositorio ──────────────────────────────────────

@test "TU01: backup-identity reaches the associated repository with its ownership mark and state, also an empty one" {
  _tu_repo tu01
  br_argv_spy
  run br_unit identity
  [ "$status" -eq 0 ]
  grep -qE '^backup-identity: [0-9a-f]{8} pushed \(partial\)$' <<< "$output"
  # I2: every git of the unit ran through timeout, and the token is in no argument.
  grep -qF 'push' "$BR_ARGV_LOG"
  if grep -qF -- "$BR_TOKEN" "$BR_ARGV_LOG"; then false; fi
  local mark
  mark=$(br_branch_show tu01 backup/identity .agentic-pod-backup.json)
  [ "$(jq -r '.schema' <<< "$mark")" = "1" ]
  [ "$(jq -r '.agent' <<< "$mark")" = "repo-bot" ]
  [ "$(jq -r '.unit' <<< "$mark")" = "identity" ]
  [ -n "$(br_state identity hash)" ]
  [ "$(br_state identity last_commit)" = "$(br_branch_head tu01 backup/identity)" ]
  br_state identity last_push | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
  [ -n "$(br_state identity last_attempt)" ]
  [ "$(br_state identity last_result)" = "ok" ]
  br_branch_files tu01 backup/identity | grep -qx '.claude.json'

  # Segunda pierna (048): un repositorio vacio no tiene main, asi que no se escribe
  # nada y se dice (antes, 046 creaba la rama huerfana).
  _tu_repo tu01e --empty
  run br_unit identity
  [ "$status" -eq 0 ]
  [ "$output" = "$(_tu_msg identity no-main)" ]
  [ "$(br_state identity last_result)" = "no-main" ]
  [ "$(br_log_count '/tu01e\.git/.*service=receive-pack')" -eq 0 ]
}

@test "TU02: a second cycle without changes creates no commit, also with --gc" {
  _tu_repo tu02
  br_unit identity > /dev/null
  local n1 h
  n1=$(br_branch_commits tu02 backup/identity)
  h=$(br_state identity hash)
  run br_unit identity
  [ "$status" -eq 0 ]
  [ "$output" = "backup-identity: no changes since last backup (hash $h)" ]
  [ "$(br_branch_commits tu02 backup/identity)" = "$n1" ]
  [ "$(br_state identity last_result)" = "no-change" ]
  run br_unit identity --gc
  [ "$status" -eq 0 ]
  if grep -qF 'no fork url' <<< "$output"; then false; fi
  [ "$output" = "backup-identity: no changes since last backup (hash $h)" ]
  [ "$(br_branch_commits tu02 backup/identity)" = "$n1" ]
  [ "$(br_state identity last_result)" = "no-change" ]
}

@test "TU24: with the real layout, identity encrypts the root secrets file and never carries it in plaintext" {
  br_keys
  _tu_repo tu24
  yq -i ".backup.identity.recipient = \"$BR_KEY_A_PUB\"" "$BR_WS/agent.yml"
  [ -f "$BR_SECRETS_FILE" ]
  [ ! -e "$BR_WS/.state/${BR_SECRETS_FILE##*/}" ]
  run br_unit identity
  [ "$status" -eq 0 ]
  grep -qE '^backup-identity: [0-9a-f]{8} pushed \(full\)$' <<< "$output"
  br_branch_files tu24 backup/identity | grep -qxF "$BR_SECRETS_AGE"
  br_branch_show tu24 backup/identity "$BR_SECRETS_AGE" > "$BATS_TEST_TMPDIR/secrets.age"
  age -d -i "$BR_KEY_A" -o "$BATS_TEST_TMPDIR/secrets.dec" "$BATS_TEST_TMPDIR/secrets.age"
  [ "$(br_sha256 "$BATS_TEST_TMPDIR/secrets.dec")" = "$(br_sha256 "$BR_SECRETS_FILE")" ]
  if br_branch_has tu24 backup/identity "$BR_SENT_SECRETS"; then false; fi
  if grep -rqF -- "$BR_SENT_SECRETS" "$BR_CACHE"; then false; fi
  [ "$(br_state identity mode)" = "full" ]

  # Sin llave: modo partial y ninguna copia cifrada.
  _tu_repo tu24b
  run br_unit identity
  [ "$status" -eq 0 ]
  grep -qE '^backup-identity: [0-9a-f]{8} pushed \(partial\)$' <<< "$output"
  if br_branch_files tu24b backup/identity | grep -qxF "$BR_SECRETS_AGE"; then false; fi
  if br_branch_has tu24b backup/identity "$BR_SENT_SECRETS"; then false; fi
  [ "$(br_state identity mode)" = "partial" ]
}

# ── US1: lo que impide el respaldo ──────────────────────────────────────────

@test "TU13: without GITHUB_PAT each unit ends in no-credential, exit 0, without a single request" {
  local u before
  for u in identity vault config; do
    _tu_repo "tu13$u"
    before=$(wc -l < "$BR_SRV_LOG")
    BR_PAT=""
    run br_unit "$u"
    unset BR_PAT
    [ "$status" -eq 0 ]
    [ "$output" = "$(_tu_msg "$u" no-credential)" ]
    [ "$(wc -l < "$BR_SRV_LOG")" -eq "$before" ]
    [ "$(br_state "$u" last_result)" = "no-credential" ]
    [ "$(br_state "$u" attempt_hash)" = "" ]
  done
  # A --dry-run without the credential says so and records nothing: the supervisor
  # and backup-status read that record.
  for u in identity vault config memory history; do
    _tu_repo "tu13d$u"
    BR_PAT=""
    run br_unit "$u" --dry-run
    unset BR_PAT
    [ "$status" -eq 0 ]
    [ "$output" = "$(_tu_msg "$u" no-credential)" ]
    [ ! -e "$BR_WS/scripts/heartbeat/$u-backup.json" ]
    [ ! -e "$BR_WS/scripts/heartbeat/backup-dest.json" ]
  done
}

@test "TU14: with a wrong credential each unit ends in unreachable with exit 2" {
  local u
  for u in identity vault config; do
    _tu_repo "tu14$u"
    BR_PAT="wrong-$BR_TOKEN"
    run br_unit "$u"
    unset BR_PAT
    [ "$status" -eq 2 ]
    [ "$output" = "$(_tu_msg "$u" unreachable)" ]
    [ "$(br_state "$u" last_result)" = "unreachable" ]
    [ -n "$(br_state "$u" attempt_hash)" ]
    [ -z "$(br_branch_head "tu14$u" "backup/$u")" ]
  done
}

@test "TU15: a public repository is refused: not-private, exit 0, and no push request" {
  local u
  br_server_mode anon-read
  for u in identity vault config; do
    _tu_repo "tu15$u"
    run br_unit "$u"
    [ "$status" -eq 0 ]
    [ "$output" = "$(_tu_msg "$u" not-private)" ]
    [ "$(br_log_count "/tu15$u\\.git/.*service=receive-pack")" -eq 0 ]
    [ "$(br_state "$u" last_result)" = "not-private" ]
  done
}

@test "TU17: a backup branch without the ownership mark is never written; the unit backs up into main (048)" {
  local u head
  for u in identity vault config; do
    _tu_repo "tu17$u"
    br_seed_branch "tu17$u" "backup/$u" NONE
    head=$(_br_git -C "$(br_bare "tu17$u")" rev-parse "refs/heads/backup/$u")
    run br_unit "$u"
    [ "$status" -eq 0 ]
    grep -qE "^backup-$u: [0-9a-f]{8} pushed" <<< "$output"
    [ "$(_br_git -C "$(br_bare "tu17$u")" rev-parse "refs/heads/backup/$u")" = "$head" ]
    [ -n "$(br_main_tree "tu17$u" "$u")" ]
    [ "$(br_state "$u" last_result)" = "ok" ]
  done
}

@test "TU18: a backup branch marked by another agent is never written; a directory of another agent in main is refused (048)" {
  local u head
  for u in identity vault config; do
    _tu_repo "tu18$u"
    br_seed_branch "tu18$u" "backup/$u" "{\"schema\":1,\"agent\":\"someone-else\",\"unit\":\"$u\"}"
    head=$(_br_git -C "$(br_bare "tu18$u")" rev-parse "refs/heads/backup/$u")
    _tu_main_edit "tu18$u" "mkdir -p .agent-backup/$u && printf '{\"schema\":1,\"agent\":\"someone-else\",\"unit\":\"$u\"}\n' > .agent-backup/$u/.agentic-pod-backup.json"
    run br_unit "$u"
    [ "$status" -eq 0 ]
    [ "$output" = "$(_tu_msg "$u" other-agent-dir)" ]
    [ "$(_br_git -C "$(br_bare "tu18$u")" rev-parse "refs/heads/backup/$u")" = "$head" ]
    [ "$(br_state "$u" last_result)" = "other-agent" ]
  done
}

@test "TU22: a unit that fails does not stop the others, and an unreachable verdict is not reused" {
  _tu_repo tu22
  br_server_mode deny-push
  run br_unit identity
  [ "$status" -eq 2 ]
  grep -qxF "$(_tu_msg identity push-failed)" <<< "$output"
  [ "$(br_state identity last_result)" = "push-failed" ]
  br_server_mode
  run br_unit vault
  [ "$status" -eq 0 ]
  grep -qE '^backup-vault: [0-9a-f]{8} pushed$' <<< "$output"
  run br_unit config
  [ "$status" -eq 0 ]
  grep -qE '^backup-config: [0-9a-f]{8} pushed$' <<< "$output"

  # Segunda pierna: unreachable, se corrige la credencial, y la siguiente funciona.
  BACKUP_DEST_NOW=1800000000
  export BACKUP_DEST_NOW
  BR_PAT="wrong-$BR_TOKEN"
  run br_unit identity
  unset BR_PAT
  [ "$status" -eq 2 ]
  [ "$(br_dest_field verdict)" = "unreachable" ]
  BACKUP_DEST_NOW=1800000100
  run br_unit identity
  [ "$status" -eq 0 ]
  grep -qE '^backup-identity: [0-9a-f]{8} pushed \(partial\)$' <<< "$output"
  [ "$(br_dest_field verdict)" = "private" ]
  [ "$(br_dest_field anon_checked_epoch)" = "1800000100" ]
}

@test "TU23: a deleted backup directory is recreated, a modified one gets the unit tree back, an unmarked one is not written (048)" {
  _tu_repo tu23
  br_unit config > /dev/null
  local files1 head
  files1=$(br_branch_files tu23 backup/config)
  grep -qx 'agent.yml' <<< "$files1"

  # Pierna 1: alguien borra el directorio de main; el ciclo lo recrea igual.
  _tu_main_edit tu23 'rm -rf .agent-backup/config'
  run br_unit config
  [ "$status" -eq 0 ]
  grep -qE '^backup-config: [0-9a-f]{8} pushed$' <<< "$output"
  [ "$(br_branch_files tu23 backup/config)" = "$files1" ]

  # Pierna 2: un commit ajeno que conserva la marca; el ciclo deja el arbol de la unidad.
  _tu_main_edit tu23 'printf "not ours\n" > .agent-backup/config/intruder.txt'
  run br_unit config
  [ "$status" -eq 0 ]
  grep -qF 'backup-config: .agent-backup/config in main was changed outside the launcher - restoring it' <<< "$output"
  [ "$(br_branch_files tu23 backup/config)" = "$files1" ]

  # Pierna 3: sin la marca, no se escribe.
  _tu_main_edit tu23 'rm -f .agent-backup/config/.agentic-pod-backup.json; printf "still not ours\n" > .agent-backup/config/intruder.txt'
  head=$(_br_git -C "$(br_bare tu23)" rev-parse refs/heads/main)
  run br_unit config
  [ "$status" -eq 0 ]
  [ "$output" = "$(_tu_msg config foreign-dir)" ]
  [ "$(_br_git -C "$(br_bare tu23)" rev-parse refs/heads/main)" = "$head" ]
}

@test "TU26: a credential that stops working is seen on the next cycle without content changes" {
  _tu_repo tu26
  br_unit config > /dev/null
  [ "$(br_state config last_result)" = "ok" ]
  br_server_token "rotated-$BR_TOKEN"
  run br_unit config
  [ "$status" -eq 2 ]
  [ "$output" = "$(_tu_msg config unreachable)" ]
  br_server_token "$BR_TOKEN"
  run br_unit config
  [ "$status" -eq 0 ]
  [ "$output" = "backup-config: no changes since last backup (hash $(br_state config hash))" ]
}

# ── US1: el supervisor ──────────────────────────────────────────────────────

# _tu_supervisor: carga start_services.sh en modo de prueba, con el workspace del
# arnes, y reemplaza el disparador por uno que anota cada llamada.
_tu_supervisor() {
  export START_SERVICES_NO_RUN=1
  export WORKDIR="$BR_WS"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  export IDENTITY_BACKUP_WORKSPACE_OVERRIDE="$BR_WS"
  export BACKUP_DEST_ALLOW_HTTP=1
  # shellcheck source=/dev/null
  source "$REPO_ROOT/docker/scripts/start_services.sh"
  TU_CALLS="$BATS_TEST_TMPDIR/trigger-calls"
  : > "$TU_CALLS"
  _trigger_identity_backup() { printf '%s\n' "$1" >> "$TU_CALLS"; }
}

_tu_check() {
  _last_backup_check=0
  _check_identity_backup
}

_tu_calls() { wc -l < "$TU_CALLS" | tr -d ' '; }

# Corre _check_identity_backup en un bash nuevo, bajo set -euo pipefail, como lo
# llama el supervisor. Imprime rc=<codigo> al final.
_tu_check_strict() {
  bash -c 'set -euo pipefail
    calls="$2"
    START_SERVICES_NO_RUN=1 source "$1"
    _trigger_identity_backup() { echo call >> "$calls"; }
    _last_backup_check=0
    _check_identity_backup
    echo "rc=$?"' _ "$REPO_ROOT/docker/scripts/start_services.sh" "$TU_CALLS"
}

@test "TU25: a change in the root secrets file makes the supervisor trigger identity; after a good backup it does not" {
  _tu_repo tu25
  _tu_supervisor
  _tu_check
  [ "$(_tu_calls)" = "1" ]
  br_unit identity > /dev/null
  [ "$(br_state identity last_result)" = "ok" ]
  : > "$TU_CALLS"
  _tu_check
  [ "$(_tu_calls)" = "0" ]
  printf 'ANOTHER=%s\n' "$RANDOM" >> "$BR_SECRETS_FILE"
  _tu_check
  [ "$(_tu_calls)" = "1" ]
  # With the repository and identity disabled explicitly, the supervisor does not
  # trigger it either, whatever changes (backup-status says disabled).
  : > "$TU_CALLS"
  yq -i '.features.identity_backup.enabled = false' "$BR_WS/agent.yml"
  printf 'YET_ANOTHER=%s\n' "$RANDOM" >> "$BR_SECRETS_FILE"
  _tu_check
  [ "$(_tu_calls)" = "0" ]
}

@test "TU34: after a failed attempt the supervisor waits 900 s for the same content, tolerates a broken state and caps the trigger" {
  _tu_repo tu34
  _tu_supervisor
  local t0=1800000000
  # Un intento fallido (unreachable) con el contenido actual.
  BR_PAT="wrong-$BR_TOKEN"
  BACKUP_DEST_NOW=$t0 br_unit identity > /dev/null || true
  unset BR_PAT
  [ "$(br_state identity last_result)" = "unreachable" ]
  BACKUP_DEST_NOW=$((t0 + 60))
  export BACKUP_DEST_NOW
  _tu_check
  [ "$(_tu_calls)" = "0" ]
  BACKUP_DEST_NOW=$((t0 + 901))
  _tu_check
  [ "$(_tu_calls)" = "1" ]
  : > "$TU_CALLS"
  printf 'NEW=%s\n' "$RANDOM" >> "$BR_SECRETS_FILE"
  BACKUP_DEST_NOW=$((t0 + 61))
  _tu_check
  [ "$(_tu_calls)" = "1" ]

  # Tras un no-credential, que no deja attempt_hash: tampoco insiste.
  : > "$TU_CALLS"
  BR_PAT=""
  BACKUP_DEST_NOW=$((t0 + 1000))
  br_unit identity > /dev/null
  unset BR_PAT
  [ "$(br_state identity last_result)" = "no-credential" ]
  [ "$(br_state identity attempt_hash)" = "" ]
  BACKUP_DEST_NOW=$((t0 + 1060))
  _tu_check
  [ "$(_tu_calls)" = "0" ]

  # Un estado truncado y un last_attempt_epoch que no es un numero: rc 0 y dispara.
  printf '{"hash": "trunc' > "$BR_WS/scripts/heartbeat/identity-backup.json"
  run _tu_check_strict
  [ "$status" -eq 0 ]
  grep -qx 'rc=0' <<< "$output"
  [ "$(_tu_calls)" = "1" ]
  : > "$TU_CALLS"
  jq -n '{hash:"x", last_result:"unreachable", attempt_hash:"", last_attempt_epoch:"not-a-number"}' \
    > "$BR_WS/scripts/heartbeat/identity-backup.json"
  run _tu_check_strict
  [ "$status" -eq 0 ]
  grep -qx 'rc=0' <<< "$output"
  [ "$(_tu_calls)" = "1" ]
  unset BACKUP_DEST_NOW

  # El tope del disparador: con repositorio, -k 10 300; con fork, 90.
  local spy="$BATS_TEST_TMPDIR/spy"
  mkdir -p "$spy"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/timeout.log"\nexit 0\n' "$spy" > "$spy/timeout"
  printf '#!/bin/sh\nexit 0\n' > "$spy/heartbeatctl"
  chmod +x "$spy/timeout" "$spy/heartbeatctl"
  run bash -c 'PATH="$1:$PATH"; START_SERVICES_NO_RUN=1 source "$2"; _trigger_identity_backup test; wait' \
    _ "$spy" "$REPO_ROOT/docker/scripts/start_services.sh"
  grep -qx -- '-k 10 300 heartbeatctl backup-identity' "$spy/timeout.log"
  : > "$spy/timeout.log"
  yq -i '.backup.repo.url = "" | .scaffold.fork.url = "https://github.com/example/fork-bot.git"' "$BR_WS/agent.yml"
  run bash -c 'PATH="$1:$PATH"; START_SERVICES_NO_RUN=1 source "$2"; _trigger_identity_backup test; wait' \
    _ "$spy" "$REPO_ROOT/docker/scripts/start_services.sh"
  grep -qx -- '90 heartbeatctl backup-identity' "$spy/timeout.log"
}

# ── US1: topes, candado y git aislado ───────────────────────────────────────

@test "TU36: a push the server never answers ends within its limit as push-failed, records it and releases the lock" {
  local u t0
  export BACKUP_GIT_TIMEOUT_S=2
  for u in identity vault; do
    _tu_repo "tu36$u"
    br_server_mode stall-push
    t0=$(date +%s)
    run br_unit "$u"
    [ "$status" -eq 2 ]
    [ $(( $(date +%s) - t0 )) -lt 30 ]
    grep -qxF "$(_tu_msg "$u" push-failed)" <<< "$output"
    [ "$(br_state "$u" last_result)" = "push-failed" ]
    [ -n "$(br_state "$u" attempt_hash)" ]
    br_server_mode
    run br_unit "$u"
    [ "$status" -eq 0 ]
    grep -qE "^backup-$u: [0-9a-f]{8} pushed" <<< "$output"
  done
}

@test "TU37: with the unit lock taken, a run says so, exits 0 and writes nothing; once released, the next run works" {
  _tu_repo tu37
  local lock="$BR_WS/scripts/heartbeat/.backup-identity.lock" before
  exec 7> "$lock"
  flock -n 7
  before=$(wc -l < "$BR_SRV_LOG")
  run br_unit identity
  [ "$status" -eq 0 ]
  [ "$output" = "$(_tu_msg identity locked)" ]
  [ ! -e "$BR_WS/scripts/heartbeat/identity-backup.json" ]
  [ "$(wc -l < "$BR_SRV_LOG")" -eq "$before" ]
  flock -u 7
  exec 7>&-
  run br_unit identity
  [ "$status" -eq 0 ]
  grep -qE '^backup-identity: [0-9a-f]{8} pushed \(partial\)$' <<< "$output"
  # --gc runs git gc on the cache only under the lock: with the lock taken, an
  # unreachable object survives; once released, gc prunes it.
  local cache="$BR_CACHE/identity/identity-repo" obj
  obj=$(printf 'loose %s\n' "$RANDOM" | _br_git -C "$cache" hash-object -w --stdin)
  [ -f "$cache/.git/objects/${obj:0:2}/${obj:2}" ]
  exec 7> "$lock"
  flock -n 7
  run br_unit identity --gc
  [ "$status" -eq 0 ]
  [ "$output" = "$(_tu_msg identity locked)" ]
  [ -f "$cache/.git/objects/${obj:0:2}/${obj:2}" ]
  flock -u 7
  exec 7>&-
  run br_unit identity --gc
  [ "$status" -eq 0 ]
  [ ! -e "$cache/.git/objects/${obj:0:2}/${obj:2}" ]
}

@test "TU38: a hostile ~/.gitconfig (insteadOf and mandatory signing) does not change a backup to the repository" {
  _tu_repo tu38
  mkdir -p "$BATS_TEST_TMPDIR/home"
  cat > "$BATS_TEST_TMPDIR/home/.gitconfig" << EOF
[url "http://127.0.0.1:1/"]
	insteadOf = $BR_BASE_URL/
[commit]
	gpgsign = true
[gpg]
	program = /bin/false
EOF
  local u
  for u in identity vault config; do
    run br_unit "$u"
    [ "$status" -eq 0 ]
    grep -qE "^backup-$u: [0-9a-f]{8} pushed" <<< "$output"
    [ -n "$(br_branch_head tu38 "backup/$u")" ]
  done
}

# ── US1: el camino del fork y el de un agente sin destino no cambian ────────

@test "TU19: without any destination the messages, exit codes and files are the ones of main" {
  br_workspace
  run br_unit identity
  [ "$status" -eq 0 ]
  [ "$output" = "backup-identity: agent.yml has no scaffold.fork.url — fork-less agent, nothing to back up to" ]
  run br_unit vault
  [ "$status" -eq 0 ]
  [ "$output" = "backup-vault: agent.yml has no scaffold.fork.url — nothing to back up to" ]
  run br_unit config
  [ "$status" -eq 0 ]
  [ "$output" = "backup-config: agent.yml has no scaffold.fork.url — nothing to back up to" ]
  [ "$(ls -A "$BR_WS/scripts/heartbeat" | tr '\n' ' ')" = "logs " ]
}

@test "TU20: with a fork nothing changes: no mark, no attempt record, and the fork never receives the credential" {
  br_workspace
  local bare="$BATS_TEST_TMPDIR/fork.git"
  _br_git init -q --bare "$bare"
  yq -i ".scaffold.fork.url = \"$bare\"" "$BR_WS/agent.yml"
  run br_unit identity
  [ "$status" -eq 0 ]
  grep -qE '^backup-identity: [0-9a-f]{8} pushed \(partial\)$' <<< "$output"
  if _br_git -C "$bare" show refs/heads/backup/identity:.agentic-pod-backup.json > /dev/null 2>&1; then false; fi
  [ "$(br_state identity last_attempt)" = "" ]
  [ "$(br_state identity last_result)" = "" ]
  [ ! -e "$BR_WS/scripts/heartbeat/backup-dest.json" ]

  # Con el fork en el servidor de prueba: ninguna peticion auth=ok y la corrida falla
  # como en main, que imprime "push failed" y, por su `return $?` dentro de un
  # `if !`, sale con 0 (comportamiento de main, que esta feature no cambia).
  br_workspace
  yq -i ".scaffold.fork.url = \"$(br_new_repo tu20)\"" "$BR_WS/agent.yml"
  run br_unit identity
  grep -qxF 'backup-identity: push failed' <<< "$output"
  [ "$(br_log_count '/tu20\.git/.* auth=ok$')" -eq 0 ]
  [ "$(br_log_count '/tu20\.git/')" -ge 1 ]
}

@test "TU05: with a fork, backup/config carries only agent.yml" {
  br_workspace
  local bare="$BATS_TEST_TMPDIR/fork.git"
  _br_git init -q --bare "$bare"
  yq -i ".scaffold.fork.url = \"$bare\"" "$BR_WS/agent.yml"
  run br_unit config
  [ "$status" -eq 0 ]
  [ "$(_br_git -C "$bare" ls-tree -r --name-only refs/heads/backup/config)" = "agent.yml" ]
}

# ── US1: las ramas de trabajo no se tocan ───────────────────────────────────

@test "TU03: after 10 cycles of the units, the work branches keep their heads and there is exactly one backup branch per unit" {
  br_keys
  _tu_repo tu03
  yq -i ".backup.identity.recipient = \"$BR_KEY_A_PUB\"" "$BR_WS/agent.yml"
  br_seed_branch tu03 002-feature NONE feature.txt "a work branch"
  local heads_before i u
  heads_before=$(br_work_heads tu03)
  [ -n "$heads_before" ]
  for i in 1 2 3 4 5 6 7 8 9 10; do
    printf '{"cycle":%s}\n' "$i" > "$BR_WS/.state/.claude/settings.json"
    printf '# Page %s\n' "$i" > "$BR_WS/.state/.vault/wiki/concepts/cycle.md"
    yq -i ".agent.vibe = \"cycle $i\"" "$BR_WS/agent.yml"
    printf 'cycle %s\n' "$i" >> "$BR_WS/.state/.claude/projects/-workspace/memory/MEMORY.md"
    printf '{"cycle":%s}\n' "$i" >> "$BR_WS/.state/.claude/projects/-workspace/0000-session.jsonl"
    for u in identity vault config memory history; do
      br_unit "$u" > /dev/null
    done
  done
  # 048: main receives the backup commits, so its head moves; every work commit
  # stays an ancestor, the other work branches keep their heads, and no backup/*
  # branch exists: one directory per unit in main.
  local ref sha
  while read -r ref sha; do
    if [ "$ref" = "refs/heads/main" ]; then
      br_is_ancestor tu03 "$sha"
    else
      [ "$(_br_git -C "$(br_bare tu03)" rev-parse "$ref")" = "$sha" ]
    fi
  done <<< "$heads_before"
  [ -z "$(br_backup_refs tu03)" ]
  [ "$(_br_git -C "$(br_bare tu03)" ls-tree --name-only refs/heads/main:.agent-backup | tr '\n' ' ')" = "README.md config history identity memory vault " ]
  [ "$(br_force_count tu03)" -eq 0 ]
}

@test "TU06: without the sensitive mark, backup/vault carries the markdown in plaintext, with its structure" {
  _tu_repo tu06
  run br_unit vault
  [ "$status" -eq 0 ]
  br_branch_files tu06 backup/vault | grep -qx 'wiki/concepts/page.md'
  br_branch_show tu06 backup/vault wiki/concepts/page.md | grep -qF -- "$BR_SENT_VAULT"
  [ "$(jq -r '.unit' <<< "$(br_branch_show tu06 backup/vault .agentic-pod-backup.json)")" = "vault" ]
}

@test "TU29: with a repository the daily identity line exists unless disabled explicitly, and a hot change keeps it" {
  local line='/usr/local/bin/heartbeatctl backup-identity >> /workspace/scripts/heartbeat/logs/backup-identity.log 2>&1'
  _tu_repo tu29
  yq -i 'del(.features.identity_backup)' "$BR_WS/agent.yml"
  br_ctl reload > /dev/null
  grep -qF -- "$line" "$BR_WS/crontab.out"
  yq -i '.features.identity_backup.enabled = false' "$BR_WS/agent.yml"
  br_ctl reload > /dev/null
  if grep -qF -- "$line" "$BR_WS/crontab.out"; then false; fi
  # Con fork y sin la clave, no la tiene, como hoy.
  yq -i 'del(.features.identity_backup) | .backup.repo.url = "" | .scaffold.fork.url = "https://github.com/example/f.git"' "$BR_WS/agent.yml"
  br_ctl reload > /dev/null
  if grep -qF -- "$line" "$BR_WS/crontab.out"; then false; fi
  # Segunda pierna: un cambio en caliente conserva la URL y la linea.
  yq -i ".backup.repo.url = \"$TU_URL\" | .scaffold.fork.url = \"\"" "$BR_WS/agent.yml"
  br_ctl reload > /dev/null
  br_ctl set-interval 15m > /dev/null
  [ "$(yq -r '.backup.repo.url' "$BR_WS/agent.yml")" = "$TU_URL" ]
  grep -qF -- "$line" "$BR_WS/crontab.out"
}

@test "TU33: a plaintext unit that lost its state creates no commit, rebuilds the state, and then does no fetch" {
  local u cache n m1
  for u in config vault; do
    _tu_repo "tu33$u"
    br_unit "$u" > /dev/null
    n=$(br_branch_commits "tu33$u" "backup/$u")
    rm -f "$BR_WS/scripts/heartbeat/$u-backup.json"
    rm -rf "$BR_CACHE"
    run br_unit "$u"
    [ "$status" -eq 0 ]
    [ "$(br_branch_commits "tu33$u" "backup/$u")" = "$n" ]
    [ -n "$(br_state "$u" hash)" ]
    [ "$(br_state "$u" last_commit)" = "$(br_branch_head "tu33$u" "backup/$u")" ]
    br_state "$u" last_push | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
    # 048: the unit cache is local; the fetches happen in the publishing clone.
    cache="$BR_CACHE/agent-backup/$u-main"
    [ -f "$cache/FETCH_HEAD" ]
    cp "$cache/FETCH_HEAD" "$BATS_TEST_TMPDIR/fh.before"
    m1=$(_tu_mtime "$cache/FETCH_HEAD")
    sleep 1
    run br_unit "$u"
    [ "$status" -eq 0 ]
    [ "$output" = "backup-$u: no changes since last backup (hash $(br_state "$u" hash))" ]
    cmp -s "$cache/FETCH_HEAD" "$BATS_TEST_TMPDIR/fh.before"
    [ "$(_tu_mtime "$cache/FETCH_HEAD")" = "$m1" ]
  done

  # La pierna del almacen: history pierde su estado y su cache. Sin la cache tampoco
  # hay mapa de bloques, asi que ese ciclo cifra todo de nuevo (D37; el operador
  # acepto ese costo el 15-11-2026): los mismos bloques, todos con nombre nuevo, y
  # los viejos fuera de la rama. El ciclo que sigue termina en no-change.
  br_keys
  _tu_repo tu33h
  yq -i ".backup.identity.recipient = \"$BR_KEY_A_PUB\"" "$BR_WS/agent.yml"
  br_unit history > /dev/null
  [ "$(br_state history last_result)" = "ok" ]
  local before_blocks bare
  bare=$(br_bare tu33h)
  before_blocks=$(br_branch_files tu33h backup/history | grep -c '^store/blocks/' || true)
  [ "$before_blocks" -ge 1 ]
  rm -f "$BR_WS/scripts/heartbeat/history-backup.json"
  rm -rf "$BR_CACHE"
  run br_unit history
  [ "$status" -eq 0 ]
  [ "$(br_branch_files tu33h backup/history | grep -c '^store/blocks/' || true)" = "$before_blocks" ]
  local c_new c_old
  c_new=$(_tu_unit_rev tu33h history 1)
  c_old=$(_tu_unit_rev tu33h history 2)
  [ "$(_br_git -C "$bare" diff --name-only --diff-filter=A "$c_old" "$c_new" -- .agent-backup/history/store/blocks | wc -l | tr -d ' ')" = "$before_blocks" ]
  [ "$(_br_git -C "$bare" diff --name-only --diff-filter=D "$c_old" "$c_new" -- .agent-backup/history/store/blocks | wc -l | tr -d ' ')" = "$before_blocks" ]
  run br_unit history
  [ "$status" -eq 0 ]
  [ "$output" = "backup-history: no changes since last backup (hash $(br_state history hash))" ]
}

# ── US2: config ampliada ────────────────────────────────────────────────────

@test "TU04: with a repository, backup/config carries agent.yml, CLAUDE.md, the persona and the compose override, not the .bak copies" {
  _tu_repo tu04
  printf 'services: {}\n' > "$BR_WS/docker-compose.override.yml"
  printf 'old persona\n' > "$BR_WS/personas/repo-bot.md.bak-20261101"
  run br_unit config
  [ "$status" -eq 0 ]
  local files
  files=$(br_branch_files tu04 backup/config)
  grep -qx 'agent.yml' <<< "$files"
  grep -qx 'CLAUDE.md' <<< "$files"
  grep -qx 'personas/repo-bot.md' <<< "$files"
  grep -qx 'docker-compose.override.yml' <<< "$files"
  if grep -q 'bak' <<< "$files"; then false; fi
  br_head_has tu04 backup/config "$BR_SENT_PERSONA"
  local n
  n=$(br_branch_commits tu04 backup/config)
  printf 'a new rule\n' >> "$BR_WS/personas/repo-bot.md"
  run br_unit config
  [ "$status" -eq 0 ]
  [ "$(br_branch_commits tu04 backup/config)" = "$((n + 1))" ]
}

@test "TU27: with a repository, backup/config carries the closed list of the workspace .claude/ and nothing else from it" {
  _tu_repo tu27
  local c="$BR_WS/.claude"
  mkdir -p "$c/skills/registro" "$c/commands" "$c/agents" "$c/hooks" "$c/output-styles" "$c/worktrees/w1"
  printf '{}\n' > "$c/settings.json"
  printf '# skill\n' > "$c/skills/registro/SKILL.md"
  printf 'cmd\n' > "$c/commands/do.md"
  printf 'agent\n' > "$c/agents/helper.md"
  printf 'hook\n' > "$c/hooks/pre.sh"
  printf 'style\n' > "$c/output-styles/terse.md"
  printf '{}\n' > "$c/settings.local.json"
  printf 'lock\n' > "$c/scheduled_tasks.lock"
  printf 'wt\n' > "$c/worktrees/w1/file"
  printf 'loose\n' > "$c/other.txt"
  run br_unit config
  [ "$status" -eq 0 ]
  local files
  files=$(br_branch_files tu27 backup/config | grep '^\.claude/' || true)
  [ "$files" = "$(printf '%s\n' .claude/agents/helper.md .claude/commands/do.md .claude/hooks/pre.sh \
    .claude/output-styles/terse.md .claude/settings.json .claude/skills/registro/SKILL.md)" ]
}

@test "TU32: with a repository, --configure-key prints the key fingerprint and the encrypted-units line, and identity runs in full mode" {
  br_keys
  _tu_repo tu32
  local fp
  fp=$(ssh-keygen -lf "$BR_KEY_A.pub" | awk '{print $2}')
  run br_unit identity --configure-key "$BR_KEY_A_PUB"
  [ "$status" -eq 0 ]
  grep -qxF "backup-identity: key fingerprint $fp (br-operator-a)" <<< "$output"
  grep -qxF 'backup-identity: encrypted units re-encrypt for this key on their next run (full upload)' <<< "$output"
  [ "$(br_state identity mode)" = "full" ]
  # Con fork, la salida es la de hoy: sin la linea de la huella.
  br_workspace
  local bare="$BATS_TEST_TMPDIR/fork.git"
  _br_git init -q --bare "$bare"
  yq -i ".scaffold.fork.url = \"$bare\"" "$BR_WS/agent.yml"
  run br_unit identity --configure-key "$BR_KEY_A_PUB"
  [ "$status" -eq 0 ]
  grep -qxF 'backup-identity: recipient updated' <<< "$output"
  if grep -qF 'key fingerprint' <<< "$output"; then false; fi
}

@test "TU35: in a sensitive agent backup/config carries only the mark, agent.yml and store/, and without a key it ends in no-recipient" {
  br_keys
  _tu_repo tu35
  yq -i ".backup.sensitive = true | .backup.identity.recipient = \"$BR_KEY_A_PUB\"" "$BR_WS/agent.yml"
  run br_unit config
  [ "$status" -eq 0 ]
  [ "$(br_branch_files tu35 backup/config | cut -d/ -f1 | LC_ALL=C sort -u | tr '\n' ' ')" = ".agentic-pod-backup.json agent.yml store " ]
  if br_branch_has tu35 backup/config "$BR_SENT_PERSONA"; then false; fi
  br_unpack tu35 backup/config "$BR_KEY_A" "$BATS_TEST_TMPDIR/out"
  grep -qF -- "$BR_SENT_PERSONA" "$BATS_TEST_TMPDIR/out/personas/repo-bot.md"
  # Sin llave publica: no-recipient, codigo 0 y ningun empuje.
  _tu_repo tu35b
  yq -i '.backup.sensitive = true' "$BR_WS/agent.yml"
  run br_unit config
  [ "$status" -eq 0 ]
  [ "$output" = "$(_tu_msg config no-recipient)" ]
  [ "$(br_log_count '/tu35b\.git/.*service=receive-pack')" -eq 0 ]
}

# ── US2: el vault cifrado ───────────────────────────────────────────────────

@test "TU07: in a sensitive agent backup/vault carries only the mark and store/, and with a fork instead it is not pushed" {
  br_keys
  _tu_repo tu07
  yq -i ".backup.identity.recipient = \"$BR_KEY_A_PUB\"" "$BR_WS/agent.yml"
  br_unit vault > /dev/null
  br_branch_files tu07 backup/vault | grep -qx 'wiki/concepts/page.md'
  yq -i '.backup.sensitive = true' "$BR_WS/agent.yml"
  run br_unit vault
  [ "$status" -eq 0 ]
  grep -qE '^backup-vault: [0-9a-f]{8} pushed$' <<< "$output"
  [ "$(br_branch_files tu07 backup/vault | cut -d/ -f1 | LC_ALL=C sort -u | tr '\n' ' ')" = ".agentic-pod-backup.json store " ]
  if br_branch_files tu07 backup/vault | grep -q '\.md$'; then false; fi
  if br_head_has tu07 backup/vault "$BR_SENT_VAULT"; then false; fi
  br_unpack tu07 backup/vault "$BR_KEY_A" "$BATS_TEST_TMPDIR/out"
  grep -qF -- "$BR_SENT_VAULT" "$BATS_TEST_TMPDIR/out/wiki/concepts/page.md"

  # Con la marca y un fork en vez de repositorio: el mensaje de U1, codigo 0, nada en el fork.
  br_workspace
  local bare="$BATS_TEST_TMPDIR/fork.git"
  _br_git init -q --bare "$bare"
  yq -i ".scaffold.fork.url = \"$bare\" | .backup.sensitive = true" "$BR_WS/agent.yml"
  run br_unit vault
  [ "$status" -eq 0 ]
  [ "$output" = "backup-vault: this agent is marked as sensitive and has no agent repository - not pushing the vault in plaintext" ]
  [ -z "$(_br_git -C "$bare" for-each-ref refs/heads)" ]
}

# Only called on failure: preserve the unit, actual message and result for TU16.
_tu16_diagnostic() {
  local unit="$1" check="$2" expected="$3" last_result
  last_result=$(br_state "$unit" last_result 2>/dev/null) || last_result="<unreadable>"
  printf '%s\000' "$unit" "$check" "$status" "$expected" "$output" "$last_result" "${BR_TOKEN:-}" |
    python3 -c 'import json,sys
parts=sys.stdin.buffer.read().split(b"\0")
keys=("unit","check","status","expected","received","last_result")
record={key:parts[i].decode("utf-8","backslashreplace") for i,key in enumerate(keys)}
sentinel=parts[6].decode("utf-8","backslashreplace")
if sentinel:
    record={key:value.replace(sentinel,"<redacted-test-token>") for key,value in record.items()}
print("TU16_DIAG "+json.dumps(record,ensure_ascii=True))'
}

@test "TU16: without a public key the encrypted units end in no-recipient with no push, and identity runs partial" {
  local u
  _tu_repo tu16
  yq -i '.backup.sensitive = true' "$BR_WS/agent.yml"
  for u in vault config memory history; do
    run br_unit "$u"
    [ "$status" -eq 0 ] || { _tu16_diagnostic "$u" exit-status "$(_tu_msg "$u" no-recipient)"; return 1; }
    [ "$output" = "$(_tu_msg "$u" no-recipient)" ] || { _tu16_diagnostic "$u" message "$(_tu_msg "$u" no-recipient)"; return 1; }
    [ "$(br_state "$u" last_result)" = "no-recipient" ] || { _tu16_diagnostic "$u" last-result "$(_tu_msg "$u" no-recipient)"; return 1; }
  done
  [ "$(br_log_count '/tu16\.git/.*service=receive-pack')" -eq 0 ] || { _tu16_diagnostic "$u" receive-pack-count "$(_tu_msg "$u" no-recipient)"; return 1; }
  run br_unit identity
  [ "$status" -eq 0 ] || { _tu16_diagnostic identity exit-status 'backup-identity: [0-9a-f]{8} pushed (partial)'; return 1; }
  grep -qE '^backup-identity: [0-9a-f]{8} pushed \(partial\)$' <<< "$output" || { _tu16_diagnostic identity message 'backup-identity: [0-9a-f]{8} pushed (partial)'; return 1; }
}

# ── US2: memory ─────────────────────────────────────────────────────────────

@test "TU08: without the mark backup/memory carries the auto memory in plaintext and claude-mem only in store/" {
  br_keys
  _tu_repo tu08
  yq -i ".backup.identity.recipient = \"$BR_KEY_A_PUB\"" "$BR_WS/agent.yml"
  run br_unit memory
  [ "$status" -eq 0 ]
  grep -qE '^backup-memory: [0-9a-f]{8} pushed$' <<< "$output"
  local files
  files=$(br_branch_files tu08 backup/memory)
  grep -qx 'auto-memory/-workspace/MEMORY.md' <<< "$files"
  grep -q '^store/manifest.json.age$' <<< "$files"
  br_head_has tu08 backup/memory "$BR_SENT_AUTOMEM"
  if br_branch_has tu08 backup/memory "$BR_SENT_CLAUDEMEM"; then false; fi
  [ -n "$(br_state memory store_recipient)" ]
  # Un cambio que solo toca la auto-memoria crea un commit nuevo.
  local n
  n=$(br_branch_commits tu08 backup/memory)
  printf 'one more fact\n' >> "$BR_WS/.state/.claude/projects/-workspace/memory/MEMORY.md"
  run br_unit memory
  [ "$status" -eq 0 ]
  [ "$(br_branch_commits tu08 backup/memory)" = "$((n + 1))" ]
}

@test "TU09: with the sensitive mark backup/memory carries no auto memory in plaintext" {
  br_keys
  _tu_repo tu09
  yq -i ".backup.identity.recipient = \"$BR_KEY_A_PUB\" | .backup.sensitive = true" "$BR_WS/agent.yml"
  run br_unit memory
  [ "$status" -eq 0 ]
  if br_branch_files tu09 backup/memory | grep -q '^auto-memory/'; then false; fi
  if br_branch_has tu09 backup/memory "$BR_SENT_AUTOMEM"; then false; fi
  br_unpack tu09 backup/memory "$BR_KEY_A" "$BATS_TEST_TMPDIR/out"
  grep -qF -- "$BR_SENT_AUTOMEM" "$BATS_TEST_TMPDIR/out/auto-memory/-workspace/MEMORY.md"
}

@test "TU10: a claude-mem database in WAL mode is backed up from the consistent copy, rows of its -wal included" {
  br_keys
  _tu_repo tu10
  yq -i ".backup.identity.recipient = \"$BR_KEY_A_PUB\"" "$BR_WS/agent.yml"
  local db="$BR_WS/.state/.claude-mem/wal.db" ready="$BATS_TEST_TMPDIR/writer.ready"
  # Un escritor que deja filas confirmadas solo en el -wal y se queda abierto.
  python3 - "$db" "$ready" > /dev/null 2>&1 3>&- 4>&- << 'PY' &
import sqlite3, sys, time
c = sqlite3.connect(sys.argv[1])
c.execute("PRAGMA journal_mode=wal")
c.execute("PRAGMA wal_autocheckpoint=0")
c.execute("CREATE TABLE t (body TEXT)")
c.executemany("INSERT INTO t VALUES (?)", [("wal-row",) for _ in range(300)])
c.commit()
open(sys.argv[2], "w").write("ready")
time.sleep(60)
PY
  local writer=$! i
  for i in $(seq 1 100); do [ -f "$ready" ] && break; sleep 0.1; done
  [ -f "$ready" ]
  [ -s "$db-wal" ]
  # Una copia en bruto del archivo principal no trae esas filas.
  cp "$db" "$BATS_TEST_TMPDIR/raw.db"
  [ "$(python3 -c 'import sqlite3,sys
try:
    print(sqlite3.connect(sys.argv[1]).execute("select count(*) from t").fetchone()[0])
except Exception:
    print("none")' "$BATS_TEST_TMPDIR/raw.db")" != "300" ]
  run br_unit memory
  kill "$writer" 2> /dev/null || true
  wait "$writer" 2> /dev/null || true
  [ "$status" -eq 0 ]
  br_unpack tu10 backup/memory "$BR_KEY_A" "$BATS_TEST_TMPDIR/out"
  [ "$(python3 -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("select count(*) from t").fetchone()[0])' "$BATS_TEST_TMPDIR/out/claude-mem/wal.db")" = "300" ]
  # A damaged database stops the unit, and its log line says why (the tool's own
  # message, which carries no content).
  printf 'SQLite format 3\000%s\n' "damaged-$RANDOM" > "$BR_WS/.state/.claude-mem/bad.db"
  run br_unit memory
  [ "$status" -eq 2 ]
  grep -qxF 'backup-memory: could not build the backup (hash)' <<< "$output"
  grep -qxF 'backup_store: sqlite snapshot failed' <<< "$output"
}

@test "TU28: extra paths travel encrypted under extra/, and every entry outside the rule is skipped with its reason" {
  br_keys
  _tu_repo tu28
  mkdir -p "$BR_WS/.state/extra-data" "$BR_WS/.custom/.git" "$BATS_TEST_TMPDIR/outside" "$BR_WS/a/.git/b"
  printf '%s state\n' "$BR_SENT_EXTRA" > "$BR_WS/.state/extra-data/f.txt"
  printf 'git internals %s\n' "$BR_SENT_EXTRA" > "$BR_WS/.custom/.git/HEAD"
  ln -s "$BATS_TEST_TMPDIR/outside" "$BR_WS/linkout"
  yq -i ".backup.identity.recipient = \"$BR_KEY_A_PUB\"" "$BR_WS/agent.yml"
  yq -i '.backup.extra_paths = [".custom", ".state/extra-data", "/abs/path", "../up", "missing-dir", ".", ".state", "./.state", ".state/", ".state/.cache/x", "agent-repo", "a/.git/b", "linkout", "scripts", "personas", "setup.sh"]' "$BR_WS/agent.yml"
  run br_unit memory
  [ "$status" -eq 0 ]
  local e
  # scripts, personas and setup.sh are launcher paths (memory_extra_path_reserved).
  for e in "/abs/path|not relative" "../up|not relative" "missing-dir|missing" ".|not allowed" \
           ".state|not allowed" "./.state|not allowed" ".state/|not allowed" ".state/.cache/x|not allowed" \
           "agent-repo|not allowed" "a/.git/b|not allowed" "linkout|outside the workspace" \
           "scripts|not allowed" "personas|not allowed" "setup.sh|not allowed"; do
    grep -qxF "backup-memory: skipping extra path '${e%%|*}' (${e#*|})" <<< "$output"
  done
  if br_branch_has tu28 backup/memory "$BR_SENT_EXTRA"; then false; fi
  br_unpack tu28 backup/memory "$BR_KEY_A" "$BATS_TEST_TMPDIR/out"
  grep -qF -- "$BR_SENT_EXTRA" "$BATS_TEST_TMPDIR/out/extra/.custom/data.txt"
  grep -qF -- "$BR_SENT_EXTRA" "$BATS_TEST_TMPDIR/out/extra/.state/extra-data/f.txt"
  [ ! -e "$BATS_TEST_TMPDIR/out/extra/.custom/.git" ]
  # The /login login file never travels, not even inside a declared extra path.
  local login=".credentials.json"
  printf '{"login":"%s"}\n' "$BR_SENT_SECRETS" > "$BR_WS/.state/.claude/$login"
  yq -i '.backup.extra_paths = [".state/.claude"]' "$BR_WS/agent.yml"
  run br_unit memory
  [ "$status" -eq 0 ]
  rm -rf "$BATS_TEST_TMPDIR/out"
  br_unpack tu28 backup/memory "$BR_KEY_A" "$BATS_TEST_TMPDIR/out"
  [ -f "$BATS_TEST_TMPDIR/out/extra/.state/.claude/settings.json" ]
  [ ! -e "$BATS_TEST_TMPDIR/out/extra/.state/.claude/$login" ]
  if grep -rqF -- "$BR_SENT_SECRETS" "$BATS_TEST_TMPDIR/out"; then false; fi
}

@test "TU30: a second memory cycle where only volatile claude-mem files changed creates no commit" {
  br_keys
  _tu_repo tu30
  yq -i ".backup.identity.recipient = \"$BR_KEY_A_PUB\"" "$BR_WS/agent.yml"
  local cm="$BR_WS/.state/.claude-mem"
  mkdir -p "$cm/logs"
  _tu_volatile() {
    printf '%s\n' "$1" > "$cm/worker.pid"
    printf '{"beat":%s}\n' "$1" > "$cm/worker-heartbeat.json"
    printf '{"sup":%s}\n' "$1" > "$cm/supervisor.json"
    printf '{"tel":%s}\n' "$1" > "$cm/telemetry.json"
    printf 'log %s\n' "$1" > "$cm/logs/worker.log"
  }
  _tu_volatile 1
  br_unit memory > /dev/null
  local n
  n=$(br_branch_commits tu30 backup/memory)
  _tu_volatile 2
  run br_unit memory
  [ "$status" -eq 0 ]
  [ "$(br_branch_commits tu30 backup/memory)" = "$n" ]
  grep -q '^backup-memory: no changes since last backup' <<< "$output"
}

@test "TU39: memory and history refuse a missing credential, a public repository and foreign branches; no sources and a stalled push" {
  br_keys
  local u
  for u in memory history; do
    _tu_repo "tu39a$u"
    yq -i ".backup.identity.recipient = \"$BR_KEY_A_PUB\"" "$BR_WS/agent.yml"
    BR_PAT=""
    run br_unit "$u"
    unset BR_PAT
    [ "$output" = "$(_tu_msg "$u" no-credential)" ]
    br_server_mode anon-read
    run br_unit "$u"
    br_server_mode
    [ "$output" = "$(_tu_msg "$u" not-private)" ]
    _tu_main_edit "tu39a$u" "mkdir -p .agent-backup/$u && printf 'x\n' > .agent-backup/$u/x.txt"
    run br_unit "$u"
    [ "$output" = "$(_tu_msg "$u" foreign-dir)" ]
    _tu_repo "tu39b$u"
    yq -i ".backup.identity.recipient = \"$BR_KEY_A_PUB\"" "$BR_WS/agent.yml"
    _tu_main_edit "tu39b$u" "mkdir -p .agent-backup/$u && printf '{\"schema\":1,\"agent\":\"someone-else\",\"unit\":\"$u\"}\n' > .agent-backup/$u/.agentic-pod-backup.json"
    run br_unit "$u"
    [ "$output" = "$(_tu_msg "$u" other-agent-dir)" ]
    [ "$(br_log_count "/tu39[ab]$u\\.git/.*service=receive-pack")" -eq 0 ]
  done
  # memory sin ninguna fuente.
  _tu_repo tu39c
  yq -i ".backup.identity.recipient = \"$BR_KEY_A_PUB\"" "$BR_WS/agent.yml"
  rm -rf "$BR_WS/.state/.claude/projects" "$BR_WS/.state/.claude-mem"
  run br_unit memory
  [ "$status" -eq 0 ]
  [ "$output" = "$(_tu_msg memory nothing)" ]
  [ "$(br_state memory last_result)" = "nothing-to-back-up" ]
  # history con un empuje que el servidor no responde.
  _tu_repo tu39d
  yq -i ".backup.identity.recipient = \"$BR_KEY_A_PUB\"" "$BR_WS/agent.yml"
  export BACKUP_PUSH_TIMEOUT_S=2
  br_server_mode stall-push
  local t0
  t0=$(date +%s)
  run br_unit history
  br_server_mode
  [ "$status" -eq 2 ]
  [ $(( $(date +%s) - t0 )) -lt 30 ]
  grep -qxF "$(_tu_msg history push-failed)" <<< "$output"
}

# ── US2: history ────────────────────────────────────────────────────────────

@test "TU11: backup/history carries only the mark and store/, complete lines only, and never the memory directories" {
  br_keys
  _tu_repo tu11
  yq -i ".backup.identity.recipient = \"$BR_KEY_A_PUB\"" "$BR_WS/agent.yml"
  printf '{"line":"half' >> "$BR_WS/.state/.claude/projects/-workspace/0000-session.jsonl"
  # Solo projects/<proyecto>/memory/ es de memory: un memory/ mas hondo es historial.
  mkdir -p "$BR_WS/.state/.claude/projects/-workspace/sub/memory"
  printf '{"nested":"%s"}\n' "$BR_SENT_HISTORY" > "$BR_WS/.state/.claude/projects/-workspace/sub/memory/n.jsonl"
  run br_unit history
  [ "$status" -eq 0 ]
  [ "$(br_branch_files tu11 backup/history | cut -d/ -f1 | LC_ALL=C sort -u | tr '\n' ' ')" = ".agentic-pod-backup.json store " ]
  if br_branch_has tu11 backup/history "$BR_SENT_HISTORY"; then false; fi
  br_unpack tu11 backup/history "$BR_KEY_A" "$BATS_TEST_TMPDIR/out"
  local restored="$BATS_TEST_TMPDIR/out/projects/-workspace/0000-session.jsonl"
  grep -qF -- "$BR_SENT_HISTORY" "$restored"
  if grep -qF 'half' "$restored"; then false; fi
  [ "$(tail -c 1 "$restored" | od -An -c | tr -d ' ')" = '\n' ]
  [ ! -e "$BATS_TEST_TMPDIR/out/projects/-workspace/memory" ]
  [ -f "$BATS_TEST_TMPDIR/out/projects/-workspace/sub/memory/n.jsonl" ]
}

@test "TU12: a growing history uploads few blocks: at most two new blocks per changed file" {
  br_keys
  _tu_repo tu12
  yq -i ".backup.identity.recipient = \"$BR_KEY_A_PUB\"" "$BR_WS/agent.yml"
  export BACKUP_STORE_BLOCK_SIZE=4096
  python3 -c 'import sys
with open(sys.argv[1], "a") as fh:
    for i in range(400):
        fh.write("{\"turn\":%d,\"text\":\"%s\"}\n" % (i, "x" * 60))' "$BR_WS/.state/.claude/projects/-workspace/0000-session.jsonl"
  br_unit history > /dev/null
  printf '{"turn":"new-1"}\n{"turn":"new-2"}\n' >> "$BR_WS/.state/.claude/projects/-workspace/0000-session.jsonl"
  run br_unit history
  [ "$status" -eq 0 ]
  local added
  added=$(_br_git -C "$(br_bare tu12)" diff --name-only --diff-filter=A "$(_tu_unit_rev tu12 history 2)" "$(_tu_unit_rev tu12 history 1)" -- .agent-backup/history/store/blocks | wc -l | tr -d ' ')
  [ "$added" -ge 1 ]
  [ "$added" -le 2 ]
}

@test "TU40: after --configure-key the next store cycle re-encrypts everything, and a replaced recipient in the branch makes it rotate" {
  br_keys
  _tu_repo tu40
  yq -i ".backup.identity.recipient = \"$BR_KEY_A_PUB\"" "$BR_WS/agent.yml"
  br_unit history > /dev/null
  local r1
  r1=$(br_state history store_recipient)
  [ -n "$r1" ]
  br_unit identity --configure-key "$BR_KEY_B_PUB" > /dev/null
  run br_unit history
  [ "$status" -eq 0 ]
  local bare
  bare=$(br_bare tu40)
  # Todos los bloques cambian: el nombre es el SHA-256 del archivo cifrado (D37), asi
  # que cada bloque de la cabeza nueva es un archivo nuevo y ninguno viejo queda.
  local total added kept c_new c_old
  c_new=$(_tu_unit_rev tu40 history 1)
  c_old=$(_tu_unit_rev tu40 history 2)
  total=$(_br_git -C "$bare" ls-tree -r --name-only "$c_new" -- .agent-backup/history/store/blocks | wc -l | tr -d ' ')
  added=$(_br_git -C "$bare" diff --name-only --diff-filter=A "$c_old" "$c_new" -- .agent-backup/history/store/blocks | wc -l | tr -d ' ')
  kept=$(comm -12 <(_br_git -C "$bare" ls-tree -r --name-only "$c_old" -- .agent-backup/history/store/blocks | LC_ALL=C sort) \
                  <(_br_git -C "$bare" ls-tree -r --name-only "$c_new" -- .agent-backup/history/store/blocks | LC_ALL=C sort) | wc -l | tr -d ' ')
  [ "$total" -ge 1 ]
  [ "$added" = "$total" ]
  [ "$kept" = "0" ]
  [ "$(br_state history store_recipient)" != "$r1" ]
  br_unpack tu40 backup/history "$BR_KEY_B" "$BATS_TEST_TMPDIR/out-b"
  if br_unpack tu40 backup/history "$BR_KEY_A" "$BATS_TEST_TMPDIR/out-a"; then false; fi

  # Segunda pierna (048): alguien reemplaza store/recipient en main y conserva la
  # marca. La cache de la unidad es local, asi que nada de main decide a quien se
  # cifra: el ciclo restaura el directorio con el destinatario del operador.
  age-keygen -o "$BATS_TEST_TMPDIR/foreign.key" 2> /dev/null
  _tu_main_edit tu40 "age-keygen -y '$BATS_TEST_TMPDIR/foreign.key' > .agent-backup/history/store/recipient"
  run br_unit history
  [ "$status" -eq 0 ]
  grep -qF 'backup-history: .agent-backup/history in main was changed outside the launcher - restoring it' <<< "$output"
  if br_branch_show tu40 backup/history store/recipient | grep -qF "$(age-keygen -y "$BATS_TEST_TMPDIR/foreign.key")"; then false; fi
  local f n=0 clone="$BATS_TEST_TMPDIR/tu40-head"
  br_clone_branch tu40 backup/history "$clone"
  while IFS= read -r f; do
    n=$((n + 1))
    if age -d -i "$BATS_TEST_TMPDIR/foreign.key" "$f" > /dev/null 2>&1; then
      echo "the foreign key opens $f" >&2
      false
    fi
  done < <(find "$clone/store" -type f -name '*.age' ! -name key.age)
  [ "$n" -ge 2 ]
}

# ── US2: el cron de las unidades nuevas ─────────────────────────────────────

@test "TU21: the crontab gains the two new lines only with a repository, and is byte-identical to main with none or a fork" {
  br_workspace
  # Sin destino: el agent.yml de tests/heartbeatctl.bats y su crontab dorado.
  cat > "$BR_WS/agent.yml" << 'YML'
agent:
  name: testbot
features:
  heartbeat:
    enabled: true
    interval: "2m"
    timeout: 300
    retries: 1
    default_prompt: "Check"
notifications:
  channel: log
YML
  br_ctl reload > /dev/null
  cmp -s "$BR_WS/crontab.out" "$REPO_ROOT/tests/fixtures/crontab-v0.26.0.golden"
  # Con fork: el crontab dorado de main para el mismo agent.yml.
  cp "$BR_FIXTURES/agent-fork.yml" "$BR_WS/agent.yml"
  br_ctl reload > /dev/null
  cmp -s "$BR_WS/crontab.out" "$BR_FIXTURES/crontab-fork.golden"
  # Con repositorio e identity deshabilitada: exactamente dos lineas mas.
  yq -i '.scaffold.fork.url = "" | .backup.repo.url = "https://github.com/example/fork-bot-repo" | .features.identity_backup.enabled = false' "$BR_WS/agent.yml"
  br_ctl reload > /dev/null
  cp "$BR_WS/crontab.out" "$BATS_TEST_TMPDIR/with-repo"
  yq -i '.backup.repo.url = ""' "$BR_WS/agent.yml"
  br_ctl reload > /dev/null
  diff "$BR_WS/crontab.out" "$BATS_TEST_TMPDIR/with-repo" | grep '^>' > "$BATS_TEST_TMPDIR/added" || true
  [ "$(cat "$BATS_TEST_TMPDIR/added")" = "$(printf '%s\n' \
    '> 40 3 * * * /usr/local/bin/heartbeatctl backup-memory >> /workspace/scripts/heartbeat/logs/backup-memory.log 2>&1' \
    '> 50 3 * * * /usr/local/bin/heartbeatctl backup-history >> /workspace/scripts/heartbeat/logs/backup-history.log 2>&1')" ]
  [ "$(diff "$BR_WS/crontab.out" "$BATS_TEST_TMPDIR/with-repo" | grep -c '^<' || true)" = "0" ]
  # Una unidad deshabilitada no tiene su linea; un schedule invalido tampoco, con aviso.
  yq -i '.backup.repo.url = "https://github.com/example/fork-bot-repo" | .features.memory_backup.enabled = false | .features.history_backup.schedule = "99 * * * *"' "$BR_WS/agent.yml"
  run br_ctl reload
  [ "$status" -eq 0 ]
  if grep -qF 'backup-memory' "$BR_WS/crontab.out"; then false; fi
  if grep -qF 'backup-history' "$BR_WS/crontab.out"; then false; fi
  grep -qF 'features.history_backup.schedule' <<< "$output"
  if grep -qF '99 * * * *' <<< "$output"; then false; fi
  # Se admite */N en el minuto.
  yq -i '.features.history_backup.schedule = "*/15 * * * *"' "$BR_WS/agent.yml"
  br_ctl reload > /dev/null
  grep -qF '*/15 * * * * /usr/local/bin/heartbeatctl backup-history' "$BR_WS/crontab.out"
}
