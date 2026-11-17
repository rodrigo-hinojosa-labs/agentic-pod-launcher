# shellcheck shell=bash
# Library (046): the history backup unit (backup/history), repo path only.
#
# Contract: specs/046-agent-backup-repo/contracts/backup-units.md (U1, U6) and
# data-model.md (section 5). Sourced by heartbeatctl and the tests; no side effects
# at load time. This unit keeps its own branch, clone cache, hash, staging and commit
# (constitution, Principle V). Everything it carries goes to store/, always
# encrypted.
#
# Source: <state>/.claude/projects/** minus the memory/ directories (those are the
# memory unit's). The heartbeat's isolated config dir is not under it.

_history_repo_git() {
  local secs="${BACKUP_PUSH_TIMEOUT_S:-900}" askpass="/bin/true"
  if command -v backup_dest_askpass > /dev/null 2>&1; then
    askpass=$(backup_dest_askpass repo)
  fi
  if command -v timeout > /dev/null 2>&1; then
    timeout -k 10 "$secs" env GIT_TERMINAL_PROMPT=0 GIT_ASKPASS="$askpass" \
      GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 LC_ALL=C git "$@" 9>&-
  else
    env GIT_TERMINAL_PROMPT=0 GIT_ASKPASS="$askpass" \
      GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 LC_ALL=C git "$@" 9>&-
  fi
}

history_cache_base() {
  printf '%s\n' "${HISTORY_BACKUP_CACHE_DIR:-/home/agent/.cache/agent-backup}"
}

# history_build_map STATE_DIR MAP: the NUL-separated map (projects/<project>/...).
history_build_map() {
  local state="$1" map="$2" root f
  root="$state/.claude/projects"
  : > "$map"
  [ -d "$root" ] || return 0
  local rel rest
  while IFS= read -r -d '' f; do
    rel="${f#"$root"/}"
    rest="${rel#*/}"
    # Only <project>/memory/ belongs to the memory unit; a deeper memory/ is history.
    case "$rest" in memory/*) continue ;; esac
    printf '%s\0%s\0' "projects/$rel" "$f" >> "$map"
  done < <(find "$root" -type d -name .git -prune -o -type f \
             ! -name '*-wal' ! -name '*-shm' ! -name '*-journal' -print0 2> /dev/null | LC_ALL=C sort -z)
  return 0
}

history_repo_prepare() {
  local url="$1" remote_head="$2"
  local base dir
  base=$(history_cache_base)
  dir="$base/history-repo"
  mkdir -p "$base" || return 2
  if [ -z "$remote_head" ] || [ ! -d "$dir/.git" ]; then
    rm -rf "$dir"
    mkdir -p "$dir" || return 2
    _history_repo_git -C "$dir" init -q > /dev/null 2>&1 || return 2
    _history_repo_git -C "$dir" symbolic-ref HEAD refs/heads/backup/history || return 2
    _history_repo_git -C "$dir" remote add origin "$url" || return 2
  else
    _history_repo_git -C "$dir" remote set-url origin "$url" > /dev/null 2>&1 \
      || _history_repo_git -C "$dir" remote add origin "$url" > /dev/null 2>&1 || return 2
  fi
  if [ -n "$remote_head" ]; then
    _history_repo_git -C "$dir" fetch -q --depth 1 origin \
      "+refs/heads/backup/history:refs/remotes/origin/backup/history" > /dev/null 2>&1 || return 2
    _history_repo_git -C "$dir" checkout -q -f -B backup/history \
      refs/remotes/origin/backup/history > /dev/null 2>&1 || return 2
  fi
  find "$dir" -mindepth 1 -maxdepth 1 ! -name .git ! -name store -exec rm -rf {} + 2> /dev/null
  printf '%s\n' "$dir"
}

history_repo_commit_and_push() {
  local dir="$1" agent="$2" sha
  backup_dest_mark_json "$agent" history > "$dir/.agentic-pod-backup.json" || return 3
  _history_repo_git -C "$dir" add -A > /dev/null 2>&1 || return 3
  if _history_repo_git -C "$dir" rev-parse --verify -q HEAD > /dev/null 2>&1 \
     && _history_repo_git -C "$dir" diff --cached --quiet > /dev/null 2>&1; then
    printf -- '-\n'
    return 0
  fi
  _history_repo_git -C "$dir" -c user.email=history-backup@localhost -c user.name=history-backup \
    commit -q -m "history snapshot $(date -u +%Y-%m-%dT%H:%M:%SZ)" > /dev/null 2>&1 || return 3
  _history_repo_git -C "$dir" push -q origin HEAD:refs/heads/backup/history > /dev/null 2>&1 || return 2
  sha=$(_history_repo_git -C "$dir" rev-parse HEAD 2> /dev/null) || return 3
  printf '%s\n' "$sha"
}

history_repo_write_state() {
  local f="$1" hash="$2" commit="$3" push="$4" recip="$5" dir tmp base='{}'
  dir=$(dirname "$f")
  mkdir -p "$dir"
  if [ -s "$f" ] && jq -e 'type == "object"' "$f" > /dev/null 2>&1; then
    base=$(cat "$f")
  fi
  tmp=$(mktemp "$dir/.history-backup.json.XXXXXX")
  if jq --arg hash "$hash" --arg commit "$commit" --arg push "$push" --arg recip "$recip" \
        '. + {hash:$hash, last_commit:$commit, last_push:$push, store_recipient:$recip}' \
        <<< "$base" > "$tmp"; then
    mv -f "$tmp" "$f"
  else
    rm -f "$tmp"
  fi
}
