#!/usr/bin/env bats
#
# 048 (US2, contract W): the agent's work clone does not show .agent-backup/, does
# not download its history, and a commit of the agent cannot change it.

load helper
load helper-backup-repo

setup_file() {
  br_require || return 1
  br_start_server
}

teardown_file() { br_stop_server; }

setup() {
  setup_tmp_dir
  br_require
  br_tools_path
  br_sentinels
  br_server_token "$BR_TOKEN"
  br_server_mode
  export GITHUB_PAT="$BR_TOKEN" BACKUP_DEST_ALLOW_HTTP=1
  export AGENT_REPO_DIR="$BATS_TEST_TMPDIR/agent-repo"
  export AGENT_REPO_CREDENTIAL_HELPER="$REPO_ROOT/docker/scripts/git-credential-agent.sh"
  export AGENT_REPO_LOG="$BATS_TEST_TMPDIR/agent-repo.log"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/docker/scripts/lib/backup_dest.sh"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/docker/scripts/lib/agent_repo.sh"
}

teardown() { teardown_tmp_dir; }

# _tw_repo NAME: a repository whose main holds work and a .agent-backup/ tree.
_tw_repo() {
  TW_URL=$(br_new_repo "$1")
  br_seed_work "$1"
  local seed="$BATS_TEST_TMPDIR/tw-seed-$1"
  _br_git clone -q "$(br_bare "$1")" "$seed"
  mkdir -p "$seed/.agent-backup/vault"
  printf '{"schema":1,"agent":"repo-bot","unit":"vault"}\n' > "$seed/.agent-backup/vault/.agentic-pod-backup.json"
  head -c 300000 /dev/urandom > "$seed/.agent-backup/vault/big.bin"
  _br_git -C "$seed" add -A && _br_git -C "$seed" commit -q -m "backup(vault): repo-bot [skip ci]"
  _br_git -C "$seed" push -q origin HEAD:refs/heads/main
  rm -rf "$seed"
  cat > "$TMP_TEST_DIR/agent.yml" << EOF
agent:
  name: repo-bot
user:
  name: "Agent User"
  email: "agent@example.invalid"
deployment:
  mode: docker
backup:
  repo:
    url: "$TW_URL"
EOF
}

_tw_git() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$AGENT_REPO_DIR" -c user.name=a -c user.email=a@b "$@"; }

@test "TW01 a new work clone shows the work files and not .agent-backup/, and never downloaded its blobs" {
  _tw_repo tw01
  agent_repo_ensure "$TMP_TEST_DIR/agent.yml"
  [ -f "$AGENT_REPO_DIR/README-work.md" ]
  [ -f "$AGENT_REPO_DIR/src/app.txt" ]
  [ ! -e "$AGENT_REPO_DIR/.agent-backup" ]
  local blob
  blob=$(_br_git -C "$(br_bare tw01)" rev-parse "main:.agent-backup/vault/big.bin")
  if GIT_NO_LAZY_FETCH=1 _tw_git cat-file -e "$blob" 2> /dev/null; then false; fi
}

@test "TW02 a commit of the agent with work changes does not touch .agent-backup/" {
  _tw_repo tw02
  agent_repo_ensure "$TMP_TEST_DIR/agent.yml"
  printf 'my feature\n' > "$AGENT_REPO_DIR/feature.txt"
  _tw_git add -A
  _tw_git commit -q -m "feat: mine"
  [ "$(_tw_git diff --name-only HEAD~1 HEAD)" = "feature.txt" ]
  [ "$(_tw_git rev-parse HEAD:.agent-backup/vault)" = "$(_br_git -C "$(br_bare tw02)" rev-parse main:.agent-backup/vault)" ]
}

@test "TW03 forcing a path under .agent-backup/ into a commit is refused by the launcher's hook" {
  _tw_repo tw03
  agent_repo_ensure "$TMP_TEST_DIR/agent.yml"
  mkdir -p "$AGENT_REPO_DIR/.agent-backup/vault"
  printf 'x\n' > "$AGENT_REPO_DIR/.agent-backup/vault/evil.md"
  _tw_git add -f --sparse .agent-backup/vault/evil.md
  run _tw_git commit -q -m "tamper"
  [ "$status" -ne 0 ]
  grep -qF '.agent-backup/ belongs to the launcher' <<< "$output"
}

@test "TW04 a pre-commit hook that is not the launcher's is left as it is" {
  _tw_repo tw04
  agent_repo_ensure "$TMP_TEST_DIR/agent.yml"
  printf '#!/bin/sh\n# my own hook\nexit 0\n' > "$AGENT_REPO_DIR/.git/hooks/pre-commit"
  agent_repo_ensure "$TMP_TEST_DIR/agent.yml"
  grep -qx '# my own hook' "$AGENT_REPO_DIR/.git/hooks/pre-commit"
  grep -qF 'pre-commit hook' "$AGENT_REPO_LOG"
}

@test "TW05 with a fork or no destination agent_repo_ensure does nothing" {
  _tw_repo tw05
  yq -i '.backup.repo.url = ""' "$TMP_TEST_DIR/agent.yml"
  agent_repo_ensure "$TMP_TEST_DIR/agent.yml"
  [ ! -e "$AGENT_REPO_DIR" ]
}

@test "TW06 an existing 046 work clone gets the new settings on repair: .agent-backup/ leaves its tree" {
  _tw_repo tw06
  GIT_CONFIG_GLOBAL=/dev/null git clone -q "$(br_bare tw06)" "$AGENT_REPO_DIR"
  [ -d "$AGENT_REPO_DIR/.agent-backup" ]
  agent_repo_ensure "$TMP_TEST_DIR/agent.yml"
  [ ! -e "$AGENT_REPO_DIR/.agent-backup" ]
  [ -f "$AGENT_REPO_DIR/README-work.md" ]
  [ "$(_tw_git config --get remote.origin.partialclonefilter)" = "blob:none" ]
  grep -qF '# agentic-pod-launcher: agent-backup guard' "$AGENT_REPO_DIR/.git/hooks/pre-commit"
}
