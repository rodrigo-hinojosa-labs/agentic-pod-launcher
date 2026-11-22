#!/usr/bin/env bats
#
# 048 (US3, contract R): --restore-from-repo reads each unit from .agent-backup/<u>/
# of main, and falls back to its backup/<u> branch. R9 of 046 over the new root is
# covered by tests/backup-repo-restore.bats (TR08, TR11, TR12, TR13), whose forged
# content now goes into main.

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
  br_keys
  br_server_token "$BR_TOKEN"
  br_server_mode
  unset BR_PAT RESTORE_IDENTITY_KEY
  export BACKUP_MAIN_RETRY_SLEEP=0
  TRM_HOME="$BATS_TEST_TMPDIR/restore-home"
  mkdir -p "$TRM_HOME"
}

_trm_origin() {
  br_workspace
  local url
  url=$(br_new_repo "$1")
  br_seed_work "$1"
  br_set_repo "$url"
  yq -i ".backup.identity.recipient = \"$BR_KEY_A_PUB\"" "$BR_WS/agent.yml"
  local u
  for u in config identity vault memory history; do
    br_unit "$u" > /dev/null
  done
  TRM_BARE=$(br_bare "$1")
}

# _trm_restore DEST: restore_from_fork of the origin into DEST, with the key.
_trm_restore() {
  ( export HOME="$TRM_HOME" GIT_TERMINAL_PROMPT=0 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
    # shellcheck source=/dev/null
    source "$REPO_ROOT/setup.sh" > /dev/null 2>&1 || true
    RESTORE_IDENTITY_KEY="$BR_KEY_A"
    restore_from_fork "$TRM_BARE" "$1" ) 2>&1
}

# _trm_to_branch NAME UNIT: moves the unit's directory of main to a 046-style
# backup/<unit> branch (same tree), and removes it from main.
_trm_to_branch() {
  local bare tree commit work
  bare=$(br_bare "$1")
  tree=$(_br_git -C "$bare" rev-parse "refs/heads/main:.agent-backup/$2")
  commit=$(printf 'legacy\n' | _br_git -C "$bare" commit-tree "$tree")
  _br_git -C "$bare" update-ref "refs/heads/backup/$2" "$commit"
  work="$BATS_TEST_TMPDIR/to-branch-$RANDOM"
  _br_git clone -q "$bare" "$work"
  rm -rf "$work/.agent-backup/$2"
  _br_git -C "$work" add -A
  _br_git -C "$work" commit -q -m "move $2 to its branch"
  _br_git -C "$work" push -q origin HEAD:refs/heads/main
  rm -rf "$work"
}

# _trm_listing DIR: "<sha256>  <relative path>" of every file restored (sorted),
# without the scratch directory of the restore.
_trm_listing() {
  ( cd "$1" && find . -type f ! -path './.restore-tmp/*' | LC_ALL=C sort | while read -r f; do
      printf '%s  %s\n' "$(br_sha256 "$f")" "$f"
    done )
}

@test "TRM01 a restore from main and one from the branches leave the same files with the same hashes (SC-003)" {
  _trm_origin trm01
  run _trm_restore "$BATS_TEST_TMPDIR/from-main"
  [ "$status" -eq 0 ]
  grep -qF 'restore: agent.yml restored from backup/config (from main)' <<< "$output"
  grep -qF 'restore: identity restored into' <<< "$output"
  [ "$(grep -c '(from main)' <<< "$output")" -ge 5 ]
  local u
  for u in config identity vault memory history; do _trm_to_branch trm01 "$u"; done
  run _trm_restore "$BATS_TEST_TMPDIR/from-branches"
  [ "$status" -eq 0 ]
  if grep -qF '(from main)' <<< "$output"; then false; fi
  [ "$(_trm_listing "$BATS_TEST_TMPDIR/from-main")" = "$(_trm_listing "$BATS_TEST_TMPDIR/from-branches")" ]
  [ -n "$(_trm_listing "$BATS_TEST_TMPDIR/from-main")" ]
}

@test "TRM02 a repository with the backups only in branches restores as 046 did" {
  _trm_origin trm02
  local u
  for u in config identity vault memory history; do _trm_to_branch trm02 "$u"; done
  run _trm_restore "$BATS_TEST_TMPDIR/d"
  [ "$status" -eq 0 ]
  grep -qF 'restore: agent.yml restored from backup/config' <<< "$output"
  grep -qF 'restore: summary — restored: config, identity, vault, memory, history' <<< "$output"
  if grep -qF '(from main)' <<< "$output"; then false; fi
}

@test "TRM03 a mixed repository restores each unit from where it is, and says so" {
  _trm_origin trm03
  _trm_to_branch trm03 history
  run _trm_restore "$BATS_TEST_TMPDIR/d"
  [ "$status" -eq 0 ]
  grep -qE 'restore: memory restored into .* \(from main\)$' <<< "$output"
  grep -qE 'restore: history restored into .*files\)$' <<< "$output"
  grep -qF 'restore: summary — restored: config, identity, vault, memory, history' <<< "$output"
}

@test "TRM05 a directory in main without a valid mark falls back to the branch, with its line" {
  _trm_origin trm05
  # A copy of the vault in its branch, and a main directory that lost its mark.
  local bare tree commit work
  bare=$(br_bare trm05)
  tree=$(_br_git -C "$bare" rev-parse "refs/heads/main:.agent-backup/vault")
  commit=$(printf 'legacy\n' | _br_git -C "$bare" commit-tree "$tree")
  _br_git -C "$bare" update-ref refs/heads/backup/vault "$commit"
  work="$BATS_TEST_TMPDIR/nomark"
  _br_git clone -q "$bare" "$work"
  rm -f "$work/.agent-backup/vault/.agentic-pod-backup.json"
  _br_git -C "$work" add -A && _br_git -C "$work" commit -q -m nomark && _br_git -C "$work" push -q origin HEAD:main
  run _trm_restore "$BATS_TEST_TMPDIR/d"
  [ "$status" -eq 0 ]
  grep -qF '⚠ restore: .agent-backup/vault in main has no valid mark — trying backup/vault' <<< "$output"
  grep -qE 'restore: vault restored into .*/\.state/\.vault/$' <<< "$output"
  [ -f "$BATS_TEST_TMPDIR/d/.state/.vault/wiki/concepts/page.md" ]
}
