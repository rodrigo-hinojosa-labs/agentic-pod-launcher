#!/usr/bin/env bats
#
# 048 (US2, contract P): when main refuses a direct push because of a protection, the
# unit opens a pull request and merges it with the agent's credential; if the merge
# is not possible, it closes it, deletes its branch and fails visibly.

load helper
load helper-backup-repo

setup_file() {
  br_require || return 1
  br_start_server
  GH_DIR="${BATS_FILE_TMPDIR:?}/gh-api"
  mkdir -p "$GH_DIR"
  : > "$GH_DIR/requests.log"
  printf 'merge-ok\n' > "$GH_DIR/mode"
  GH_API_ROOT="$BR_SRV_DIR/repos" GH_API_MODE_FILE="$GH_DIR/mode" GH_API_PORT_FILE="$GH_DIR/port" \
  GH_API_LOG="$GH_DIR/requests.log" GH_API_TOKEN_FILE="$BR_TOKEN_FILE" \
    python3 "$BR_FIXTURES/gh-api-server.py" > "$GH_DIR/server.out" 2>&1 3>&- 4>&- &
  printf '%s\n' "$!" > "$GH_DIR/pid"
  local i
  for i in $(seq 1 100); do [ -s "$GH_DIR/port" ] && break; sleep 0.1; done
  [ -s "$GH_DIR/port" ] || { cat "$GH_DIR/server.out" >&2; return 1; }
  export GH_DIR
}

teardown_file() {
  [ -f "${GH_DIR:-}/pid" ] && kill "$(cat "$GH_DIR/pid")" 2> /dev/null || true
  br_stop_server
}

setup() {
  br_require
  br_tools_path
  br_sentinels
  br_server_token "$BR_TOKEN"
  br_server_mode
  unset BR_PAT
  export BACKUP_MAIN_RETRY_SLEEP=0
  export BACKUP_GH_API_BASE="http://127.0.0.1:$(cat "$GH_DIR/port")"
  printf 'merge-ok\n' > "$GH_DIR/mode"
  br_keys
  br_workspace
}

_tp_repo() {
  TP_URL=$(br_new_repo "$1")
  br_seed_work "$1"
  br_set_repo "$TP_URL"
}

_tp_branches() { _br_git -C "$(br_bare "$1")" for-each-ref --format='%(refname:short)' 'refs/heads/agent-backup-pr/*'; }

@test "TP01 protected main, merge allowed: the backup reaches main through a pull request and no temporary branch is left" {
  _tp_repo tp01
  br_server_mode protected-main
  run br_unit vault
  br_server_mode
  [ "$status" -eq 0 ]
  grep -qE '^backup-vault: [0-9a-f]{8} pushed$' <<< "$output"
  [ -n "$(br_main_tree tp01 vault)" ]
  [ -z "$(_tp_branches tp01)" ]
  grep -qE '^201 POST /repos/tp01/pulls auth=ok' "$GH_DIR/requests.log"
  grep -qE '^200 PUT /repos/tp01/pulls/[0-9]+/merge auth=ok' "$GH_DIR/requests.log"
}

@test "TP02 protected main, merge refused: main unchanged, the pull request closed, no temporary branch, main-protected" {
  _tp_repo tp02
  local before
  before=$(_br_git -C "$(br_bare tp02)" rev-parse main)
  printf 'merge-405\n' > "$GH_DIR/mode"
  br_server_mode protected-main
  run br_unit vault
  br_server_mode
  [ "$status" -eq 2 ]
  [ "$output" = "backup-vault: main is protected and the pull request could not be merged - nothing pushed" ]
  [ "$(_br_git -C "$(br_bare tp02)" rev-parse main)" = "$before" ]
  [ -z "$(_tp_branches tp02)" ]
  grep -qE '^200 PATCH /repos/tp02/pulls/[0-9]+ auth=ok state=closed$' "$GH_DIR/requests.log"
  [ "$(br_state vault last_result)" = "main-protected" ]
}

@test "TP03 the token never reaches argv, and the curl config file is 0600 when used" {
  _tp_repo tp03
  local spy="$BATS_TEST_TMPDIR/spy" real
  real=$(command -v curl)
  mkdir -p "$spy"
  cat > "$spy/curl" << EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$BATS_TEST_TMPDIR/curl.argv"
prev=""
for a in "\$@"; do
  if [ "\$prev" = "-K" ]; then
    if [ "\$(uname)" = Darwin ]; then stat -f '%Lp' "\$a"; else stat -c '%a' "\$a"; fi >> "$BATS_TEST_TMPDIR/curl.mode"
  fi
  prev="\$a"
done
exec "$real" "\$@"
EOF
  chmod +x "$spy/curl"
  br_server_mode protected-main
  PATH="$spy:$PATH" run br_unit vault
  br_server_mode
  [ "$status" -eq 0 ]
  [ -s "$BATS_TEST_TMPDIR/curl.argv" ]
  if grep -qF "$BR_TOKEN" "$BATS_TEST_TMPDIR/curl.argv"; then false; fi
  [ "$(sort -u "$BATS_TEST_TMPDIR/curl.mode")" = "600" ]
}

@test "TP04 a rejection because main moved never takes the pull request path" {
  _tp_repo tp04
  : > "$GH_DIR/requests.log"
  br_server_mode inject-once
  run br_unit vault
  br_server_mode
  [ "$status" -eq 0 ]
  [ ! -s "$GH_DIR/requests.log" ]
}

@test "TP05 an API base other than api.github.com or the local test server is ignored" {
  # shellcheck source=/dev/null
  source "$BR_LIB_DIR/backup_pr.sh"
  BACKUP_GH_API_BASE="https://evil.example" run _backup_pr_api_base
  [ "$output" = "https://api.github.com" ]
  BACKUP_GH_API_BASE="http://127.0.0.1:x9" run _backup_pr_api_base
  [ "$output" = "https://api.github.com" ]
  BACKUP_GH_API_BASE="http://127.0.0.1:8080" run _backup_pr_api_base
  [ "$output" = "http://127.0.0.1:8080" ]
  run _backup_pr_repo_path "https://github.com/o/r.git"
  [ "$output" = "o/r" ]
}

@test "TS502 the config unit records the repository size at most once a day, and backup-status shows it" {
  _tp_repo ts502
  : > "$GH_DIR/requests.log"
  br_unit config > /dev/null
  yq -i '.agent.vibe = "changed"' "$BR_WS/agent.yml"
  br_unit config > /dev/null
  [ "$(grep -cE '^200 GET /repos/ts502 auth=ok' "$GH_DIR/requests.log")" -eq 1 ]
  [ "$(jq -r '.repo_size_kb' "$BR_WS/scripts/heartbeat/backup-repo-size.json")" = "4321" ]
  run br_ctl backup-status --json
  [ "$(jq -r '.repo_size_kb' <<< "$output")" = "4321" ]
}

@test "TP06 the merge is pinned to the backup commit: a pull request branch moved before the merge is refused (409) and nothing reaches main" {
  _tp_repo tp06
  local before
  before=$(_br_git -C "$(br_bare tp06)" rev-parse main)
  printf 'merge-moved\n' > "$GH_DIR/mode"
  br_server_mode protected-main
  run br_unit vault
  br_server_mode
  [ "$status" -eq 2 ]
  [ "$(_br_git -C "$(br_bare tp06)" rev-parse main)" = "$before" ]
  grep -qE '^409 PUT /repos/tp06/pulls/[0-9]+/merge auth=ok$' "$GH_DIR/requests.log"
  [ -z "$(_tp_branches tp06)" ]
}

