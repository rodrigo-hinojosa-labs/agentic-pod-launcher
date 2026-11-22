# shellcheck shell=bash
# Library (046): the agent's work clone of its associated repository.
#
# Contract: specs/046-agent-backup-repo/contracts/agent-surface.md (A4, A5) and
# data-model.md (section 7). Sourced by start_services.sh and heartbeatctl; no side
# effects at load time. It needs backup_dest_resolve (backup_dest.sh) to be loaded.
#
# The clone is the agent's: the launcher never commits or pushes in it. It only
# creates it, keeps two settings in place (the backup/* branches are never fetched,
# and the credential helper answers only for the repository's server) and leaves
# the agent on a work branch, never on a backup/* one. Every failure is logged and
# never stops the boot or the config unit.

# agent_repo_dir -> the clone path. heartbeatctl does not define WORKDIR and runs
# under `set -u`, hence the cascade.
agent_repo_dir() {
  printf '%s\n' "${AGENT_REPO_DIR:-${WORKDIR:-${HEARTBEATCTL_WORKSPACE:-/workspace}}/agent-repo}"
}

_agent_repo_log() {
  local log="${AGENT_REPO_LOG:-${WORKDIR:-${HEARTBEATCTL_WORKSPACE:-/workspace}}/scripts/heartbeat/logs/agent-repo.log}"
  mkdir -p "$(dirname "$log")" 2> /dev/null || return 0
  printf '[%s] agent-repo: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$log" 2> /dev/null || true
}

_agent_repo_git() {
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 LC_ALL=C git "$@" 9>&-
}

# The server part of the repository URL (scheme://host[:port]), for the helper key.
_agent_repo_server() {
  local url="$1" rest
  rest="${url#*://}"
  printf '%s://%s\n' "${url%%://*}" "${rest%%/*}"
}

# The two settings the clone always carries (data-model.md, section 7).
_agent_repo_settings() {
  local dir="$1" url="$2" helper
  helper="${AGENT_REPO_CREDENTIAL_HELPER:-/opt/agent-admin/scripts/git-credential-agent.sh}"
  if ! _agent_repo_git -C "$dir" remote get-url origin > /dev/null 2>&1; then
    _agent_repo_git -C "$dir" remote add origin "$url" || return 1
  fi
  _agent_repo_git -C "$dir" config --unset-all remote.origin.fetch > /dev/null 2>&1 || true
  _agent_repo_git -C "$dir" config --add remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*' || return 1
  _agent_repo_git -C "$dir" config --add remote.origin.fetch '^refs/heads/backup/*' || return 1
  # An empty helper first resets the list collected from the global and system
  # configs (a credential.helper=store there would write the token in plaintext).
  local key
  key="credential.$(_agent_repo_server "$url").helper"
  _agent_repo_git -C "$dir" config --unset-all "$key" > /dev/null 2>&1 || true
  _agent_repo_git -C "$dir" config --add "$key" "" || return 1
  _agent_repo_git -C "$dir" config --add "$key" "$helper" || return 1
  _agent_repo_main_settings "$dir"
  return 0
}

# 048 (contract W): the backups live in .agent-backup/ of main. The clone leaves that
# directory out of its tree (sparse checkout), never downloads blobs it does not
# check out (blob:none promisor), and a launcher hook refuses a commit that stages a
# path under it. A pre-commit hook that is not the launcher's is never replaced.
_agent_repo_main_settings() {
  local dir="$1" hook
  _agent_repo_git -C "$dir" config core.repositoryformatversion 1 || return 1
  _agent_repo_git -C "$dir" config extensions.partialClone origin || return 1
  _agent_repo_git -C "$dir" config remote.origin.promisor true || return 1
  _agent_repo_git -C "$dir" config remote.origin.partialclonefilter blob:none || return 1
  _agent_repo_git -C "$dir" config core.sparseCheckout true || return 1
  _agent_repo_git -C "$dir" config core.sparseCheckoutCone false || return 1
  mkdir -p "$dir/.git/info" || return 1
  printf '/*\n!/.agent-backup/\n' > "$dir/.git/info/sparse-checkout" || return 1
  if _agent_repo_git -C "$dir" rev-parse --verify -q HEAD > /dev/null 2>&1; then
    _agent_repo_git -C "$dir" sparse-checkout reapply > /dev/null 2>&1 \
      || _agent_repo_log "could not reapply the sparse checkout in $dir"
  fi
  hook="$dir/.git/hooks/pre-commit"
  mkdir -p "$dir/.git/hooks" || return 1
  if [ -e "$hook" ] && ! grep -qF '# agentic-pod-launcher: agent-backup guard' "$hook" 2> /dev/null; then
    _agent_repo_log "$hook is not the launcher's pre-commit hook - leaving it alone (no .agent-backup/ guard)"
    return 0
  fi
  cat > "$hook" << 'HOOK'
#!/bin/sh
# agentic-pod-launcher: agent-backup guard
# The launcher's backups live in .agent-backup/ of main; a work commit never
# changes them.
if git -c core.quotePath=false diff --cached --name-only | grep -q '^\.agent-backup/'; then
  echo ".agent-backup/ belongs to the launcher's backups - unstage it (git restore --staged .agent-backup)" >&2
  exit 1
fi
exit 0
HOOK
  chmod +x "$hook" || return 1
  return 0
}

_agent_repo_capped() {
  local secs="${AGENT_REPO_FETCH_TIMEOUT_S:-120}"
  if command -v timeout > /dev/null 2>&1; then
    timeout -k 10 "$secs" "$@"
  else
    "$@"
  fi
}

# agent_repo_ensure [AGENT_YML]: creates or repairs the work clone (A4). rc 0 always.
agent_repo_ensure() {
  local yml="${1:-${BACKUP_DEST_AGENT_YML:-/workspace/agent.yml}}"
  command -v backup_dest_resolve > /dev/null 2>&1 || return 0
  local dest url
  dest=$(backup_dest_resolve "$yml")
  [ "${dest%%$'\t'*}" = "repo" ] || return 0
  url="${dest#*$'\t'}"
  if [ -z "${GITHUB_PAT:-}" ]; then
    _agent_repo_log "no GITHUB_PAT in the environment - the work clone was not touched"
    return 0
  fi
  local dir
  dir=$(agent_repo_dir)
  if [ -e "$dir" ]; then
    if [ -d "$dir/.git" ]; then
      _agent_repo_settings "$dir" "$url" || _agent_repo_log "could not update the settings of $dir"
    else
      _agent_repo_log "$dir exists and is not a git repository - leaving it alone"
    fi
    return 0
  fi

  if ! _agent_repo_create "$dir" "$url" "$yml"; then
    rm -rf "$dir"
    _agent_repo_log "could not create the work clone at $dir - it will be retried"
  fi
  return 0
}

_agent_repo_create() {
  local dir="$1" url="$2" yml="$3" heads default work branch name email
  mkdir -p "$dir" || return 1
  _agent_repo_git -C "$dir" init -q || return 1
  _agent_repo_settings "$dir" "$url" || return 1
  # GITHUB_PAT reaches the helper through the inherited environment, never argv (I2).
  heads=$(_agent_repo_capped env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 \
            git -C "$dir" ls-remote --symref origin 2> /dev/null) || return 1
  default=$(printf '%s\n' "$heads" | awk '$1 == "ref:" && $3 == "HEAD" { sub("^refs/heads/", "", $2); print $2; exit }')
  work=$(printf '%s\n' "$heads" | awk '$1 != "ref:" && $2 ~ /^refs\/heads\// { sub("^refs/heads/", "", $2); print $2 }' \
           | grep -v '^backup/' | LC_ALL=C sort)
  branch=""
  if [ -n "$default" ] && printf '%s\n' "$work" | grep -qxF -- "$default"; then
    branch="$default"
  elif printf '%s\n' "$work" | grep -qx 'main'; then
    branch="main"
  elif [ -n "$work" ]; then
    branch=$(printf '%s\n' "$work" | head -n 1)
  fi
  name=$(yq -r '.user.name // ""' "$yml" 2> /dev/null)
  email=$(yq -r '.user.email // ""' "$yml" 2> /dev/null)
  [ -n "$name" ] && [ "$name" != "null" ] && _agent_repo_git -C "$dir" config user.name "$name"
  [ -n "$email" ] && [ "$email" != "null" ] && _agent_repo_git -C "$dir" config user.email "$email"
  if [ -z "$branch" ]; then
    # Empty remote, or only backup/* branches: a local main without commits.
    _agent_repo_git -C "$dir" symbolic-ref HEAD refs/heads/main || return 1
    return 0
  fi
  _agent_repo_capped env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 \
    git -C "$dir" fetch -q --filter=blob:none origin > /dev/null 2>&1 || return 1
  _agent_repo_git -C "$dir" checkout -q -B "$branch" --track "refs/remotes/origin/$branch" > /dev/null 2>&1 || return 1
  return 0
}
