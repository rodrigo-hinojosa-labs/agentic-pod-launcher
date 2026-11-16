#!/usr/bin/env bats
#
# 046: la regla de destino, la credencial, la comprobacion de privacidad, la marca
# de pertenencia y el registro del intento (docker/scripts/lib/backup_dest.sh y
# docker/scripts/git-askpass-agent.sh).
#
# Contrato: specs/046-agent-backup-repo/contracts/destination-and-credential.md
# (C1 a C8). Lo que significa cada prueba: seccion V2 de
# specs/046-agent-backup-repo/contracts/evidence.md (TD01 a TD18).
#
# Un solo servidor git de prueba por archivo (setup_file / teardown_file). Cada
# prueba fija su credencial y sus modos en setup(). Ninguna prueba detecta la sonda
# anonima contando peticiones auth=none: toda operacion autenticada de git empieza
# con una peticion sin credencial. Se mira anon_checked_epoch y el codigo de las
# respuestas.

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
  export GITHUB_PAT="$BR_TOKEN"
  export BACKUP_DEST_STATE_FILE="$BATS_TEST_TMPDIR/hb/backup-dest.json"
  export BACKUP_DEST_AGENT_YML="$BATS_TEST_TMPDIR/agent.yml"
  export BACKUP_DEST_ALLOW_HTTP=1
  export BACKUP_ASKPASS_OVERRIDE="$REPO_ROOT/docker/scripts/git-askpass-agent.sh"
  unset BACKUP_DEST_NOW BACKUP_PROBE_TIMEOUT_S
  mkdir -p "$BATS_TEST_TMPDIR/hb"
  printf 'backup:\n  repo:\n    url: ""\n    allow_unverified: false\n' > "$BACKUP_DEST_AGENT_YML"
}

_td_lib() {
  # shellcheck source=/dev/null
  source "$REPO_ROOT/docker/scripts/lib/backup_dest.sh"
}

_td_allow_unverified() {
  yq -i ".backup.repo.allow_unverified = $1" "$BACKUP_DEST_AGENT_YML"
}

# ── C1: regla de destino ────────────────────────────────────────────────────

@test "TD01: backup_dest_resolve gives repo with only a repository, and the repository wins over a fork" {
  _td_lib
  local f="$BATS_TEST_TMPDIR/a.yml"
  printf 'backup:\n  repo:\n    url: "https://github.com/o/r"\n' > "$f"
  [ "$(backup_dest_resolve "$f")" = "$(printf 'repo\thttps://github.com/o/r')" ]
  printf 'backup:\n  repo:\n    url: "https://github.com/o/r"\nscaffold:\n  fork:\n    url: "https://github.com/o/fork"\n' > "$f"
  [ "$(backup_dest_resolve "$f")" = "$(printf 'repo\thttps://github.com/o/r')" ]
  # Sin argumento, la costura BACKUP_DEST_AGENT_YML.
  cp "$f" "$BACKUP_DEST_AGENT_YML"
  [ "$(backup_dest_resolve)" = "$(printf 'repo\thttps://github.com/o/r')" ]
}

@test "TD02: backup_dest_resolve gives fork with only a fork" {
  _td_lib
  local f="$BATS_TEST_TMPDIR/a.yml"
  printf 'backup:\n  repo:\n    url: ""\nscaffold:\n  fork:\n    url: "https://github.com/o/fork"\n' > "$f"
  [ "$(backup_dest_resolve "$f")" = "$(printf 'fork\thttps://github.com/o/fork')" ]
  printf 'scaffold:\n  fork:\n    url: "https://github.com/o/fork"\n' > "$f"
  [ "$(backup_dest_resolve "$f")" = "$(printf 'fork\thttps://github.com/o/fork')" ]
}

@test "TD03: backup_dest_resolve gives none with empty values, null values and a missing agent.yml" {
  _td_lib
  local f="$BATS_TEST_TMPDIR/a.yml"
  printf 'backup:\n  repo:\n    url: ""\nscaffold:\n  fork:\n    url: ""\n' > "$f"
  [ "$(backup_dest_resolve "$f")" = "$(printf 'none\t')" ]
  printf 'backup:\n  repo:\n    url: null\nscaffold:\n  fork:\n    url: null\n' > "$f"
  [ "$(backup_dest_resolve "$f")" = "$(printf 'none\t')" ]
  printf 'agent:\n  name: x\n' > "$f"
  [ "$(backup_dest_resolve "$f")" = "$(printf 'none\t')" ]
  run backup_dest_resolve "$BATS_TEST_TMPDIR/absent.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'none\t')" ]
}

# ── C2: credencial ──────────────────────────────────────────────────────────

@test "TD04: backup_dest_askpass picks the askpass only for repo with a non-empty GITHUB_PAT" {
  _td_lib
  GITHUB_PAT="$BR_TOKEN"
  [ "$(backup_dest_askpass repo)" = "$BACKUP_ASKPASS_OVERRIDE" ]
  GITHUB_PAT=""
  [ "$(backup_dest_askpass repo)" = "/bin/true" ]
  unset GITHUB_PAT
  [ "$(backup_dest_askpass repo)" = "/bin/true" ]
  GITHUB_PAT="$BR_TOKEN"
  [ "$(backup_dest_askpass fork)" = "/bin/true" ]
  [ "$(backup_dest_askpass none)" = "/bin/true" ]
  # Sin la costura, la ruta horneada.
  unset BACKUP_ASKPASS_OVERRIDE
  [ "$(backup_dest_askpass repo)" = "/opt/agent-admin/scripts/git-askpass-agent.sh" ]
}

@test "TD05: the askpass answers x-access-token and GITHUB_PAT, and prints nothing else" {
  local ap="$REPO_ROOT/docker/scripts/git-askpass-agent.sh"
  [ -x "$ap" ]
  run env GITHUB_PAT="$BR_TOKEN" sh "$ap" "Username for 'https://github.com': "
  [ "$status" -eq 0 ]
  [ "$output" = "x-access-token" ]
  run env GITHUB_PAT="$BR_TOKEN" sh "$ap" "Password for 'https://x-access-token@github.com': "
  [ "$status" -eq 0 ]
  [ "$output" = "$BR_TOKEN" ]
  run env GITHUB_PAT="$BR_TOKEN" sh "$ap" "Are you sure you want to continue connecting (yes/no)? "
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  env GITHUB_PAT="$BR_TOKEN" sh "$ap" "Password for x: " 2> "$BATS_TEST_TMPDIR/err" > /dev/null
  [ ! -s "$BATS_TEST_TMPDIR/err" ]
}

# ── C3: privacidad ──────────────────────────────────────────────────────────

@test "TD06: a repository that asks for a credential and accepts the token is private" {
  _td_lib
  local url
  url=$(br_new_repo "td06")
  run backup_dest_verify "$url"
  [ "$status" -eq 0 ]
  [ "$output" = "private" ]
  [ "$(br_log_count '^401 .*/td06\.git/.* auth=none$')" -ge 1 ]
  [ "$(br_log_count '^200 .*/td06\.git/.* auth=ok$')" -ge 1 ]
  [ "$(jq -r '.verdict' "$BACKUP_DEST_STATE_FILE")" = "private" ]
  [ "$(jq -r '.url' "$BACKUP_DEST_STATE_FILE")" = "$url" ]
}

@test "TD07: a repository that answers without a credential is public" {
  _td_lib
  local url
  url=$(br_new_repo "td07")
  br_server_mode anon-read
  run backup_dest_verify "$url"
  [ "$output" = "public" ]
  [ "$(jq -r '.verdict' "$BACKUP_DEST_STATE_FILE")" = "public" ]
}

@test "TD08: a wrong credential and a closed port are unreachable" {
  _td_lib
  local url
  url=$(br_new_repo "td08")
  GITHUB_PAT="wrong-$BR_TOKEN"
  run backup_dest_verify "$url"
  [ "$output" = "unreachable" ]
  GITHUB_PAT="$BR_TOKEN"
  run backup_dest_verify "http://127.0.0.1:1/td08.git"
  [ "$output" = "unreachable" ]
  [ "$(jq -r '.verdict' "$BACKUP_DEST_STATE_FILE")" = "unreachable" ]
}

@test "TD09: a probe that fails for another reason, with allow_unverified, is unverified-allowed and the probe did run" {
  _td_lib
  local url
  url=$(br_new_repo "td09")
  _td_allow_unverified true
  export BACKUP_DEST_NOW=1800000000
  br_server_mode anon-error-once
  run backup_dest_verify "$url"
  [ "$output" = "unverified-allowed" ]
  [ "$(br_log_count '^500 .*/td09\.git/')" -eq 1 ]
  [ "$(jq -r '.anon_checked_epoch' "$BACKUP_DEST_STATE_FILE")" = "1800000000" ]
  [ "$(jq -r '.verdict' "$BACKUP_DEST_STATE_FILE")" = "unverified-allowed" ]
}

@test "TD10: the anonymous probe is not repeated within 24 hours of the last probe, is repeated after, and a URL change forces it" {
  _td_lib
  local url other t0=1800000000
  url=$(br_new_repo "td10")
  other=$(br_new_repo "td10b")
  _nonvalid() { grep -c -v ' auth=ok$' "$BR_SRV_LOG" || true; }

  BACKUP_DEST_NOW=$t0 backup_dest_verify "$url" > "$BATS_TEST_TMPDIR/v"
  [ "$(cat "$BATS_TEST_TMPDIR/v")" = "private" ]
  [ "$(jq -r '.anon_checked_epoch' "$BACKUP_DEST_STATE_FILE")" = "$t0" ]

  BACKUP_DEST_NOW=$((t0 + 3600)) backup_dest_verify "$url" > "$BATS_TEST_TMPDIR/v"
  [ "$(cat "$BATS_TEST_TMPDIR/v")" = "private" ]
  [ "$(jq -r '.anon_checked_epoch' "$BACKUP_DEST_STATE_FILE")" = "$t0" ]
  [ "$(jq -r '.checked_epoch' "$BACKUP_DEST_STATE_FILE")" = "$((t0 + 3600))" ]

  local before after23 after25
  before=$(_nonvalid)
  BACKUP_DEST_NOW=$((t0 + 82800)) backup_dest_verify "$url" > "$BATS_TEST_TMPDIR/v"
  [ "$(cat "$BATS_TEST_TMPDIR/v")" = "private" ]
  [ "$(jq -r '.anon_checked_epoch' "$BACKUP_DEST_STATE_FILE")" = "$t0" ]
  [ "$(jq -r '.checked_epoch' "$BACKUP_DEST_STATE_FILE")" = "$((t0 + 82800))" ]
  after23=$(_nonvalid)

  BACKUP_DEST_NOW=$((t0 + 90000)) backup_dest_verify "$url" > "$BATS_TEST_TMPDIR/v"
  [ "$(cat "$BATS_TEST_TMPDIR/v")" = "private" ]
  [ "$(jq -r '.anon_checked_epoch' "$BACKUP_DEST_STATE_FILE")" = "$((t0 + 90000))" ]
  after25=$(_nonvalid)
  # La corrida de t0+25 h hizo la sonda: gano mas peticiones sin credencial valida
  # que la de t0+23 h, que no la hizo.
  [ $((after25 - after23)) -gt $((after23 - before)) ]

  # Un cambio de URL fuerza la sonda.
  BACKUP_DEST_NOW=$((t0 + 93600)) backup_dest_verify "$other" > "$BATS_TEST_TMPDIR/v"
  [ "$(cat "$BATS_TEST_TMPDIR/v")" = "private" ]
  [ "$(jq -r '.anon_checked_epoch' "$BACKUP_DEST_STATE_FILE")" = "$((t0 + 93600))" ]
  [ "$(jq -r '.url' "$BACKUP_DEST_STATE_FILE")" = "$other" ]
}

@test "TD11: every URL the rule rejects is unreachable without a single request" {
  _td_lib
  local seam url expected rows=0 before
  while IFS=$'\t' read -r seam url expected; do
    case "$seam" in ''|'#'*) continue ;; esac
    [ "$expected" = "reject" ] || continue
    rows=$((rows + 1))
    if [ "$seam" = "on" ]; then export BACKUP_DEST_ALLOW_HTTP=1; else unset BACKUP_DEST_ALLOW_HTTP; fi
    before=$(wc -l < "$BR_SRV_LOG")
    out=$(backup_dest_verify "$url")
    if [ "$out" != "unreachable" ]; then
      echo "verdict [$out] for rejected URL [$url] (seam $seam)" >&2
      false
    fi
    [ "$(wc -l < "$BR_SRV_LOG")" -eq "$before" ]
    if backup_dest_url_ok "$url"; then
      echo "backup_dest_url_ok accepted [$url] (seam $seam)" >&2
      false
    fi
  done < "$BR_FIXTURES/url-cases.tsv"
  [ "$rows" -ge 8 ]
  # Y las que acepta, las acepta.
  while IFS=$'\t' read -r seam url expected; do
    case "$seam" in ''|'#'*) continue ;; esac
    [ "$expected" = "accept" ] || continue
    [ "$url" = "<empty>" ] && continue
    if [ "$seam" = "on" ]; then export BACKUP_DEST_ALLOW_HTTP=1; else unset BACKUP_DEST_ALLOW_HTTP; fi
    backup_dest_url_ok "$url"
  done < "$BR_FIXTURES/url-cases.tsv"
}

# ── C4: marca de pertenencia ────────────────────────────────────────────────

@test "TD12: backup_dest_check_owner gives new, ok, foreign and other-agent" {
  _td_lib
  local bare="$BATS_TEST_TMPDIR/owner.git" seed="$BATS_TEST_TMPDIR/seed" clone="$BATS_TEST_TMPDIR/clone"
  _br_git init -q --bare "$bare"
  _br_git init -q "$seed"
  _mark() {  # rama, contenido de la marca o NONE
    _br_git -C "$seed" checkout -q --orphan "$1"
    _br_git -C "$seed" rm -rq --cached . 2>/dev/null || true
    rm -f "$seed"/* "$seed/.agentic-pod-backup.json"
    printf 'x\n' > "$seed/file"
    if [ "$2" != "NONE" ]; then printf '%s\n' "$2" > "$seed/.agentic-pod-backup.json"; fi
    _br_git -C "$seed" add -A
    _br_git -C "$seed" commit -q -m "$1"
    _br_git -C "$seed" push -q "$bare" "HEAD:refs/heads/$1"
  }
  _mark backup/identity '{"schema":1,"agent":"repo-bot","unit":"identity"}'
  _mark backup/vault NONE
  _mark backup/config '{"schema":1,"agent":"another-bot","unit":"config"}'
  _mark backup/memory '{"schema":1,"agent":"repo-bot","unit":"history"}'
  _br_git init -q "$clone"
  _br_git -C "$clone" remote add origin "$bare"
  _br_git -C "$clone" fetch -q origin '+refs/heads/backup/*:refs/remotes/origin/backup/*'

  [ "$(backup_dest_check_owner "$clone" backup/identity repo-bot identity)" = "ok" ]
  [ "$(backup_dest_check_owner "$clone" backup/history repo-bot history)" = "new" ]
  [ "$(backup_dest_check_owner "$clone" backup/vault repo-bot vault)" = "foreign" ]
  [ "$(backup_dest_check_owner "$clone" backup/config repo-bot config)" = "other-agent" ]
  [ "$(backup_dest_check_owner "$clone" backup/memory repo-bot memory)" = "other-agent" ]
}

# ── C5: registro del intento ────────────────────────────────────────────────

@test "TD13: backup_dest_record keeps the unit fields, records the attempt atomically and leaves no temporary file" {
  _td_lib
  local hb="$BATS_TEST_TMPDIR/hb" f="$BATS_TEST_TMPDIR/hb/identity-backup.json"
  jq -n '{hash:"h1", mode:"full", last_commit:"c1", last_push:"2026-11-01T00:00:00Z", store_recipient:"age1x"}' > "$f"
  BACKUP_DEST_NOW=1800000123 backup_dest_record identity unreachable hash-tried
  [ "$(jq -r '.hash' "$f")" = "h1" ]
  [ "$(jq -r '.mode' "$f")" = "full" ]
  [ "$(jq -r '.last_commit' "$f")" = "c1" ]
  [ "$(jq -r '.last_push' "$f")" = "2026-11-01T00:00:00Z" ]
  [ "$(jq -r '.store_recipient' "$f")" = "age1x" ]
  [ "$(jq -r '.last_result' "$f")" = "unreachable" ]
  [ "$(jq -r '.attempt_hash' "$f")" = "hash-tried" ]
  [ "$(jq -r '.last_attempt_epoch' "$f")" = "1800000123" ]
  jq -r '.last_attempt' "$f" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
  # Sin el hash, attempt_hash queda vacio.
  BACKUP_DEST_NOW=1800000200 backup_dest_record identity no-credential
  [ "$(jq -r '.attempt_hash' "$f")" = "" ]
  [ "$(jq -r '.last_result' "$f")" = "no-credential" ]
  [ "$(jq -r '.hash' "$f")" = "h1" ]
  # Un estado que no existia se crea.
  backup_dest_record memory nothing-to-back-up
  [ "$(jq -r '.last_result' "$hb/memory-backup.json")" = "nothing-to-back-up" ]
  # Ningun temporal en el directorio.
  [ "$(ls -A "$hb" | LC_ALL=C sort | tr '\n' ' ')" = "identity-backup.json memory-backup.json " ]
}

# ── I2: la credencial no queda en ningun lado ───────────────────────────────

@test "TD14: the credential sentinel never lands in the server log, the destination record, a clone config or the git trace" {
  _td_lib
  local url clone="$BATS_TEST_TMPDIR/clone" trace="$BATS_TEST_TMPDIR/trace.txt"
  url=$(br_new_repo "td14")
  GIT_TRACE="$trace" backup_dest_verify "$url" > "$BATS_TEST_TMPDIR/v"
  [ "$(cat "$BATS_TEST_TMPDIR/v")" = "private" ]
  # Un clon hecho con el mismo entorno de C2.
  env GIT_TERMINAL_PROMPT=0 GIT_ASKPASS="$(backup_dest_askpass repo)" \
      GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TRACE="$trace" \
      git clone -q "$url" "$clone"
  [ -f "$clone/README.md" ]
  [ -s "$trace" ]
  local f
  for f in "$BR_SRV_LOG" "$BACKUP_DEST_STATE_FILE" "$clone/.git/config" "$trace"; do
    if grep -qF -- "$BR_TOKEN" "$f"; then
      echo "credential sentinel found in $f" >&2
      false
    fi
  done
  # El centinela es real: el askpass lo entrega.
  [ "$(GITHUB_PAT="$BR_TOKEN" sh "$BACKUP_ASKPASS_OVERRIDE" 'Password for x')" = "$BR_TOKEN" ]
}

@test "TD15: backup_dest_branch_head gives the commit of the requested branch, and empty when it does not exist" {
  _td_lib
  local heads="$BATS_TEST_TMPDIR/heads"
  printf '%s\trefs/heads/main\n%s\trefs/heads/backup/identity\n%s\trefs/heads/backup/identity-old\n' \
    1111111111111111111111111111111111111111 2222222222222222222222222222222222222222 \
    3333333333333333333333333333333333333333 > "$heads"
  [ "$(backup_dest_branch_head "$heads" backup/identity)" = "2222222222222222222222222222222222222222" ]
  [ "$(backup_dest_branch_head "$heads" main)" = "1111111111111111111111111111111111111111" ]
  [ "$(backup_dest_branch_head "$heads" backup/vault)" = "" ]
  [ "$(backup_dest_branch_head "$BATS_TEST_TMPDIR/absent" main)" = "" ]
  # Con el archivo que deja backup_dest_verify.
  local url
  url=$(br_new_repo "td15")
  backup_dest_verify "$url" "$BATS_TEST_TMPDIR/heads2" > /dev/null
  [ "$(backup_dest_branch_head "$BATS_TEST_TMPDIR/heads2" main)" = "$(br_branch_head td15 main)" ]
  [ -n "$(br_branch_head td15 main)" ]
}

@test "TD16: a probe that fails for another reason, or times out, without allow_unverified is unverified, and is not reused" {
  _td_lib
  local url
  url=$(br_new_repo "td16")
  BACKUP_DEST_NOW=1800000000
  export BACKUP_DEST_NOW
  br_server_mode anon-error-once
  run backup_dest_verify "$url"
  [ "$output" = "unverified" ]
  [ "$(jq -r '.anon_checked_epoch' "$BACKUP_DEST_STATE_FILE")" = "1800000000" ]

  export BACKUP_PROBE_TIMEOUT_S=2
  BACKUP_DEST_NOW=1800000100
  br_server_mode stall-anon-once
  run backup_dest_verify "$url"
  [ "$output" = "unverified" ]
  [ "$(jq -r '.anon_checked_epoch' "$BACKUP_DEST_STATE_FILE")" = "1800000100" ]

  # La corrida siguiente, sin el modo, vuelve a hacer la sonda y da private.
  BACKUP_DEST_NOW=1800000200
  br_server_mode
  run backup_dest_verify "$url"
  [ "$output" = "private" ]
  [ "$(jq -r '.anon_checked_epoch' "$BACKUP_DEST_STATE_FILE")" = "1800000200" ]
}

@test "TD17: allow_unverified never turns a public repository into an accepted one" {
  _td_lib
  local url
  url=$(br_new_repo "td17")
  _td_allow_unverified true
  br_server_mode anon-read
  run backup_dest_verify "$url"
  [ "$output" = "public" ]
}

@test "TD18: an authenticated query the server never answers ends within its limit as unreachable" {
  _td_lib
  local url t0
  url=$(br_new_repo "td18")
  export BACKUP_PROBE_TIMEOUT_S=2
  br_server_mode stall-auth
  t0=$(date +%s)
  run backup_dest_verify "$url"
  [ "$output" = "unreachable" ]
  [ $(( $(date +%s) - t0 )) -lt 15 ]
}
