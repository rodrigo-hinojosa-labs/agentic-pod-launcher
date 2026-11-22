#!/usr/bin/env bats
#
# 048 (US4, contract L): a unit deletes its legacy backup/<unit> branch only after
# verifying that main holds its directory, and only when the branch carries this
# agent's mark. Rules as in backup-main-units.bats.

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
  export BACKUP_MAIN_RETRY_SLEEP=0
  br_keys
  br_workspace
}

_tl_repo() {
  TL_URL=$(br_new_repo "$1")
  br_seed_work "$1"
  br_set_repo "$TL_URL"
  yq -i ".backup.identity.recipient = \"$BR_KEY_A_PUB\"" "$BR_WS/agent.yml"
}

_tl_mark() { printf '{"schema":1,"agent":"%s","unit":"%s"}' "$1" "$2"; }

_tl_has_branch() {
  _br_git -C "$(br_bare "$1")" rev-parse --verify -q "refs/heads/backup/$2" > /dev/null 2>&1
}

@test "TL01 a marked legacy branch is deleted only after main holds the unit, never before (SC-008)" {
  _tl_repo tl01
  br_seed_branch tl01 backup/vault "$(_tl_mark repo-bot vault)" page.md "old backup"
  # The push to main fails: the branch must survive.
  br_server_mode deny-push
  run br_unit vault
  br_server_mode
  [ "$status" -eq 2 ]
  _tl_has_branch tl01 vault
  # Now it works: main gets the directory, then the branch goes.
  run br_unit vault
  [ "$status" -eq 0 ]
  grep -qF 'backup-vault: legacy branch backup/vault deleted (its backup is in main)' <<< "$output"
  [ -n "$(br_main_tree tl01 vault)" ]
  if _tl_has_branch tl01 vault; then false; fi
  br_state vault legacy_branch | grep -qE '^deleted [0-9]{4}-'
}

@test "TL02 a legacy branch without a mark, or of another agent or unit, survives 10 cycles" {
  _tl_repo tl02
  br_seed_branch tl02 backup/vault NONE page.md "not ours"
  br_seed_branch tl02 backup/config "$(_tl_mark someone-else config)" agent.yml "x: 1"
  br_seed_branch tl02 backup/memory "$(_tl_mark repo-bot vault)" x.txt "wrong unit"
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    printf '# %s\n' "$i" > "$BR_WS/.state/.vault/wiki/concepts/c.md"
    br_unit vault > /dev/null 2>&1
    br_unit config > /dev/null 2>&1
    br_unit memory > /dev/null 2>&1
  done
  _tl_has_branch tl02 vault
  _tl_has_branch tl02 config
  _tl_has_branch tl02 memory
  [ "$(br_state vault legacy_branch)" = "kept: no-mark" ]
  [ "$(br_state config legacy_branch)" = "kept: other-agent" ]
  [ "$(br_state memory legacy_branch)" = "kept: other-agent" ]
}

@test "TL03 the deletion travels alone: the push that deletes carries no other reference" {
  _tl_repo tl03
  br_seed_branch tl03 backup/vault "$(_tl_mark repo-bot vault)" page.md "old"
  br_unit vault > /dev/null
  # The server logs the refs of every push: the one that deletes the branch names
  # that ref alone.
  local line
  line=$(grep -E '^push-refs tl03\.git .*refs/heads/backup/vault' "$BR_SRV_LOG")
  [ "$line" = "push-refs tl03.git refs/heads/backup/vault" ]
  if _tl_has_branch tl03 vault; then false; fi
  [ "$(br_force_count tl03)" -eq 0 ]
}

@test "TL04 each unit decides on its own branch: deleting one leaves the others" {
  _tl_repo tl04
  br_seed_branch tl04 backup/vault "$(_tl_mark repo-bot vault)" page.md "old"
  br_seed_branch tl04 backup/config "$(_tl_mark repo-bot config)" agent.yml "x: 1"
  br_unit vault > /dev/null
  if _tl_has_branch tl04 vault; then false; fi
  _tl_has_branch tl04 config
  br_unit config > /dev/null
  if _tl_has_branch tl04 config; then false; fi
}

@test "TL05 when the verification after the push fails the branch is kept, and the next cycle deletes it" {
  _tl_repo tl05
  br_seed_branch tl05 backup/vault "$(_tl_mark repo-bot vault)" page.md "old"
  # Someone changes the unit's directory right after the push (inject on the NEXT
  # push would not do it), simulated by a fetch that sees a different tree: the
  # tree check of the verification is what decides.
  BACKUP_MAIN_VERIFY_FAIL=1 run br_unit vault
  [ "$status" -eq 0 ]
  _tl_has_branch tl05 vault
  [ "$(br_state vault legacy_branch)" = "kept: not-verified" ]
  run br_unit vault
  if _tl_has_branch tl05 vault; then false; fi
}

@test "TL06 a failed deletion keeps the branch recorded as delete-failed" {
  _tl_repo tl06
  br_seed_branch tl06 backup/vault "$(_tl_mark repo-bot vault)" page.md "old"
  BACKUP_MAIN_DELETE_FAIL=1 run br_unit vault
  [ "$status" -eq 0 ]
  _tl_has_branch tl06 vault
  [ "$(br_state vault legacy_branch)" = "kept: delete-failed" ]
}

@test "TL07 the unit cache survives the deletion (it is the local cache of the main path)" {
  _tl_repo tl07
  br_seed_branch tl07 backup/vault "$(_tl_mark repo-bot vault)" page.md "old"
  br_unit vault > /dev/null
  [ -d "$BR_CACHE/agent-backup/vault-repo/.git" ]
  run br_unit vault
  grep -q '^backup-vault: no changes since last backup' <<< "$output"
}

@test "TL08 between the first write in main and the deletion, both places hold a restorable backup" {
  _tl_repo tl08
  br_seed_branch tl08 backup/vault "$(_tl_mark repo-bot vault)" page.md "old"
  BACKUP_MAIN_DELETE_FAIL=1 br_unit vault > /dev/null
  _tl_has_branch tl08 vault
  [ -n "$(br_main_tree tl08 vault)" ]
  br_main_show tl08 .agent-backup/vault/.agentic-pod-backup.json | jq -e '.unit == "vault"'
  _br_git -C "$(br_bare tl08)" show refs/heads/backup/vault:.agentic-pod-backup.json | jq -e '.unit == "vault"'
}
