#!/usr/bin/env bash
# Local-mode vault backup entrypoint. Rendered from modules/local-vault-backup.sh.tpl
# — do not hand-edit (use ./setup.sh --regenerate). Snapshots the vault's markdown
# to the backup/vault orphan branch of the agent's fork, using the shared
# backup_vault.sh primitives (same hash-idempotency, exclusions, orphan-branch
# push). Resolves the vault under the workspace (VAULT_ROOT_OVERRIDE, no
# /home/agent rebase). Uses the operator's git credentials (HTTPS helper / SSH
# key already configured on the host). Always exits 0.
set -uo pipefail

WORKSPACE="{{DEPLOYMENT_WORKSPACE}}"
AGENT_YML="${WORKSPACE}/agent.yml"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export VAULT_ROOT_OVERRIDE="{{LOCAL_VAULT_DIR}}"
export VAULT_BACKUP_STATE_FILE="${WORKSPACE}/scripts/heartbeat/vault-backup.json"
export VAULT_BACKUP_CACHE_DIR="${VAULT_BACKUP_CACHE_DIR:-$HOME/.cache/agent-backup}"

mkdir -p "$(dirname "$VAULT_BACKUP_STATE_FILE")" 2>/dev/null || true

# shellcheck source=/dev/null
. "${SCRIPT_DIR}/../lib/backup_vault.sh"

# Orchestration mirrors heartbeatctl::_bv_run (the heavy lifting — hash, clone,
# commit, state — is the shared lib; only this thin sequence is local).
_lvb_run() {
  local dry_run=0
  [ "${1:-}" = "--dry-run" ] && dry_run=1
  local vault_dir fork_url current_hash last_hash clone_dir sha
  vault_dir=$(vault_resolve_root "$AGENT_YML")
  [ -n "$vault_dir" ] || { echo "backup-vault: vault not enabled — nothing to back up"; return 0; }
  [ -d "$vault_dir" ] || { echo "backup-vault: vault dir $vault_dir does not exist yet — skipping"; return 0; }
  fork_url=$(yq -r '.scaffold.fork.url // ""' "$AGENT_YML" 2>/dev/null)
  current_hash=$(vault_hash "$vault_dir")
  last_hash=$(vault_last_hash "$VAULT_BACKUP_STATE_FILE")
  if [ -n "$last_hash" ] && [ "$current_hash" = "$last_hash" ]; then
    echo "backup-vault: no changes since last backup (hash $last_hash)"
    return 0
  fi
  if [ "$dry_run" -eq 1 ]; then
    echo "backup-vault: dry-run (no push) — would change from ${last_hash:-<none>} to $current_hash"
    return 0
  fi
  if [ -z "$fork_url" ]; then
    echo "backup-vault: agent.yml has no scaffold.fork.url — nothing to back up to"
    return 0
  fi
  clone_dir=$(vault_prepare_clone "$fork_url")
  if ! sha=$(vault_commit_and_push "$clone_dir" "$vault_dir"); then
    return 0
  fi
  if [ "$sha" = "-" ]; then
    echo "backup-vault: no changes after stage-diff (hash $current_hash)"
    vault_write_state "$VAULT_BACKUP_STATE_FILE" "$current_hash" "" ""
    return 0
  fi
  vault_write_state "$VAULT_BACKUP_STATE_FILE" "$current_hash" "$sha" \
    "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  printf 'backup-vault: %s pushed\n' "${sha:0:8}"
}

_lvb_run "$@"
exit 0
