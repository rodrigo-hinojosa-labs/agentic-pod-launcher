#!/usr/bin/env bats
# 012-local-vault-rag (US3, FR-007/008): the local vault backup entrypoint pushes
# the vault's markdown to the fork's backup/vault orphan branch using the shared
# backup_vault.sh primitives, resolving the vault under the workspace (no
# /home/agent rebase). Host-runnable: the "fork" is a local bare git repo.

load helper

setup() {
  setup_tmp_dir
  load_lib render
  load_lib yaml
  yaml_require_yq >/dev/null
  command -v jq >/dev/null || skip "jq not installed"

  WS="$TMP_TEST_DIR/ws"
  mkdir -p "$WS/scripts/local" "$WS/scripts/lib" "$WS/scripts/heartbeat" "$WS/.state/.vault/wiki/summaries" "$WS/.state/.vault/.obsidian"
  cp "$REPO_ROOT/scripts/lib/backup_vault.sh" "$WS/scripts/lib/"

  printf '# Index\n' > "$WS/.state/.vault/index.md"
  printf '# Memex\n' > "$WS/.state/.vault/wiki/summaries/memex.md"
  echo '{"layout":"x"}' > "$WS/.state/.vault/.obsidian/workspace.json"

  FORK_BARE="$TMP_TEST_DIR/fork.git"
  git init --bare --initial-branch=main "$FORK_BARE" >/dev/null 2>&1
  export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example
  export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example
  export VAULT_BACKUP_CACHE_DIR="$TMP_TEST_DIR/backup-cache"

  _write_agent_yml "$FORK_BARE"

  render_load_context "$TMP_TEST_DIR/agent.yml" >/dev/null 2>&1 || true
  export DEPLOYMENT_WORKSPACE="$WS" AGENT_NAME=locbot OPERATOR_USER=op
  export LOCAL_VAULT_DIR="$WS/.state/.vault"
  export BACKUP_TIMER_ONCALENDAR="*-*-* *:00:00"
  ENTRY="$WS/scripts/local/agent-vault-backup.sh"
  render_to_file "$REPO_ROOT/modules/local-vault-backup.sh.tpl" "$ENTRY"; chmod +x "$ENTRY"
}

teardown() { teardown_tmp_dir; }

# _write_agent_yml [FORK_URL]  — omit FORK_URL for the no-fork case.
_write_agent_yml() {
  local fork="${1:-}"
  cat > "$TMP_TEST_DIR/agent.yml" << YML
version: 1
agent: {name: locbot}
deployment: {workspace: "$WS", mode: local}
scaffold: {fork: {url: "$fork"}}
vault: {enabled: true, path: .state/.vault}
YML
  cp "$TMP_TEST_DIR/agent.yml" "$WS/agent.yml"
}

@test "first backup pushes a commit to backup/vault (workspace vault, no rebase)" {
  run "$ENTRY"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'pushed'
  git --git-dir="$FORK_BARE" rev-parse backup/vault >/dev/null 2>&1
}

@test "second backup with no change is a hash no-op (no new commit)" {
  "$ENTRY" >/dev/null 2>&1
  local sha1; sha1=$(git --git-dir="$FORK_BARE" rev-parse backup/vault)
  run "$ENTRY"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi 'no changes since last backup'
  local sha2; sha2=$(git --git-dir="$FORK_BARE" rev-parse backup/vault)
  [ "$sha1" = "$sha2" ]
}

@test "excludes .obsidian/workspace*.json from the backup" {
  "$ENTRY" >/dev/null 2>&1
  # the pushed tree must NOT contain .obsidian/workspace.json
  run git --git-dir="$FORK_BARE" ls-tree -r --name-only backup/vault
  echo "$output" | grep -q 'index.md'
  ! echo "$output" | grep -q '.obsidian/workspace.json'
}

@test "no fork configured -> clean no-op, exit 0" {
  _write_agent_yml ""     # empty fork url
  run "$ENTRY"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi 'no .*fork.url\|nothing to back up'
}

@test "state file records the backup under scripts/heartbeat" {
  "$ENTRY" >/dev/null 2>&1
  [ -f "$WS/scripts/heartbeat/vault-backup.json" ]
  [ -n "$(jq -r '.last_commit // ""' "$WS/scripts/heartbeat/vault-backup.json")" ]
}

@test "entrypoint bakes VAULT_ROOT_OVERRIDE to the workspace vault (no /home/agent)" {
  grep -q "^export VAULT_ROOT_OVERRIDE=\"$WS/.state/.vault\"$" "$ENTRY"
  # the OVERRIDE line itself must not point at the container path
  ! grep -qE '^export VAULT_ROOT_OVERRIDE=.*/home/agent' "$ENTRY"
}

@test "backup timer: OnCalendar from BACKUP_TIMER_ONCALENDAR, oneshot service" {
  render_to_file "$REPO_ROOT/modules/local-vault-backup.timer.tpl" "$TMP_TEST_DIR/timer"
  grep -q '^OnCalendar=\*-\*-\* \*:00:00$' "$TMP_TEST_DIR/timer"
  grep -q '^Unit=agent-locbot-vault-backup.service$' "$TMP_TEST_DIR/timer"
  render_to_file "$REPO_ROOT/modules/local-vault-backup.service.tpl" "$TMP_TEST_DIR/svc"
  grep -q '^Type=oneshot$' "$TMP_TEST_DIR/svc"
  grep -q "^ExecStart=$WS/scripts/local/agent-vault-backup.sh$" "$TMP_TEST_DIR/svc"
}
