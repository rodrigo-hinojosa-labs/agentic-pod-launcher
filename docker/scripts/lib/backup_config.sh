# shellcheck shell=bash
# Library: helpers for the config backup primitive.
# Snapshots agent.yml (no secrets, no encryption needed) to the
# 'backup/config' orphan branch on the agent's fork. Restoration uses
# this branch first to recover the agent.yml + run setup.sh --regenerate
# before pulling identity and vault.

# Non-interactive git wrapper (60s cap when timeout(1) is available).
# Same rationale as _identity_git / _vault_git: prevents a
# missing-credential prompt from deadlocking the cron / watchdog.
# timeout(1) absence is tolerated for portability with macOS host tests.
_config_git() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 60 env GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/true git "$@"
  else
    env GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/true git "$@"
  fi
}

# Stable hash over agent.yml content. Trivial — single file, no walk.
config_hash() {
  local agent_yml="${1:?config_hash: need agent.yml path}"
  if [ ! -f "$agent_yml" ]; then
    printf 'MISSING\n' | _config_sha256 | awk '{print $1}'
    return
  fi
  _config_sha256 < "$agent_yml" | awk '{print $1}'
}

_config_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum
  else
    shasum -a 256
  fi
}

# Read the last config-backup hash from config-backup.json.
config_last_hash() {
  local state_file="$1"
  [ -f "$state_file" ] || { echo ""; return; }
  jq -r '.hash // ""' "$state_file" 2>/dev/null
}

config_prepare_clone() {
  local fork_url="$1"
  local cache_base="${CONFIG_BACKUP_CACHE_DIR:-/home/agent/.cache/agent-backup}"
  local dir="$cache_base/config-clone"
  mkdir -p "$cache_base"

  if [ ! -d "$dir/.git" ]; then
    _config_git clone --no-checkout "$fork_url" "$dir" >/dev/null 2>&1
  fi
  (cd "$dir" && _config_git fetch origin backup/config >/dev/null 2>&1 || true)
  printf '%s\n' "$dir"
}

# Stage agent.yml into a worktree and commit + push.
# $1 = local clone dir, $2 = agent.yml path.
# STDOUT: "<sha>" on commit+push, "-" if nothing changed.
config_commit_and_push() {
  local clone_dir="$1" agent_yml="$2"
  local stage="$clone_dir/_stage"

  (cd "$clone_dir" && git worktree remove --force "$stage" 2>/dev/null) || true
  rm -rf "$stage"

  local orphan=0
  if git -C "$clone_dir" rev-parse --verify --quiet origin/backup/config >/dev/null; then
    git -C "$clone_dir" worktree add -B backup/config "$stage" origin/backup/config >/dev/null 2>&1
  else
    orphan=1
    mkdir -p "$stage"
    git -C "$stage" init -q
    git -C "$stage" symbolic-ref HEAD refs/heads/backup/config
    git -C "$stage" remote add origin "$(git -C "$clone_dir" config --get remote.origin.url)"
  fi

  cp -a "$agent_yml" "$stage/agent.yml"

  git -C "$stage" add -A
  if git -C "$stage" diff --cached --quiet; then
    if [ "$orphan" -eq 1 ]; then
      rm -rf "$stage"
    else
      (cd "$clone_dir" && git worktree remove --force "$stage" 2>/dev/null) || rm -rf "$stage"
    fi
    printf -- '-\n'
    return 0
  fi

  local msg ts sha
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  msg="config snapshot $ts"
  git -C "$stage" -c user.email=config-backup@localhost -c user.name=config-backup \
       commit -m "$msg" >/dev/null
  if ! _config_git -C "$stage" push origin backup/config >/dev/null 2>&1; then
    echo "backup-config: push failed" >&2
    if [ "$orphan" -eq 1 ]; then
      rm -rf "$stage"
    else
      (cd "$clone_dir" && git worktree remove --force "$stage" 2>/dev/null) || rm -rf "$stage"
    fi
    return 2
  fi

  sha=$(git -C "$stage" rev-parse HEAD)
  if [ "$orphan" -eq 1 ]; then
    rm -rf "$stage"
  else
    (cd "$clone_dir" && git worktree remove --force "$stage" 2>/dev/null) || rm -rf "$stage"
  fi
  printf '%s\n' "$sha"
}

config_write_state() {
  local state_file="$1" hash="$2" commit="$3" push_ts="$4"
  local dir tmp
  dir=$(dirname "$state_file")
  mkdir -p "$dir"
  tmp=$(mktemp "$dir/.config-backup.json.XXXXXX")
  jq -n \
    --arg hash "$hash" \
    --arg commit "$commit" \
    --arg push "$push_ts" \
    '{hash:$hash, last_commit:$commit, last_push:$push}' \
    > "$tmp"
  mv "$tmp" "$state_file"
}

# ── 046: the repo path (an associated private repository) ───────────────────
#
# Contract: specs/046-agent-backup-repo/contracts/backup-units.md (U1, U3). Only
# heartbeatctl calls these, and only when backup_dest_resolve answers `repo`. They
# keep this unit's own cache, tree, commit and push (constitution, Principle V).

_config_repo_git() {
  local secs="${BACKUP_GIT_TIMEOUT_S:-60}" askpass="/bin/true"
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

# config_repo_prepare URL REMOTE_HEAD [KEEP_STORE] -> stdout: the cache dir.
config_repo_prepare() {
  local url="$1" remote_head="$2" keep_store="${3:-0}"
  local base="${CONFIG_BACKUP_CACHE_DIR:-/home/agent/.cache/agent-backup}"
  local dir="$base/config-repo"
  mkdir -p "$base" || return 2
  if [ -z "$remote_head" ] || [ ! -d "$dir/.git" ]; then
    rm -rf "$dir"
    mkdir -p "$dir" || return 2
    _config_repo_git -C "$dir" init -q > /dev/null 2>&1 || return 2
    _config_repo_git -C "$dir" symbolic-ref HEAD refs/heads/backup/config || return 2
    _config_repo_git -C "$dir" remote add origin "$url" || return 2
  else
    _config_repo_git -C "$dir" remote set-url origin "$url" > /dev/null 2>&1 \
      || _config_repo_git -C "$dir" remote add origin "$url" > /dev/null 2>&1 || return 2
  fi
  if [ -n "$remote_head" ]; then
    _config_repo_git -C "$dir" fetch -q --depth 1 origin \
      "+refs/heads/backup/config:refs/remotes/origin/backup/config" > /dev/null 2>&1 || return 2
    _config_repo_git -C "$dir" checkout -q -f -B backup/config \
      refs/remotes/origin/backup/config > /dev/null 2>&1 || return 2
  fi
  if [ "$keep_store" = "1" ]; then
    find "$dir" -mindepth 1 -maxdepth 1 ! -name .git ! -name store -exec rm -rf {} + 2> /dev/null
  else
    find "$dir" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} + 2> /dev/null
  fi
  printf '%s\n' "$dir"
}

# config_repo_commit_and_push DIR AGENT -> "<sha>" or "-"; rc 2 push failed, 3 error.
# The tree is already staged by the caller.
config_repo_commit_and_push() {
  local dir="$1" agent="$2" sha
  backup_dest_mark_json "$agent" config > "$dir/.agentic-pod-backup.json" || return 3
  _config_repo_git -C "$dir" add -A > /dev/null 2>&1 || return 3
  if _config_repo_git -C "$dir" rev-parse --verify -q HEAD > /dev/null 2>&1 \
     && _config_repo_git -C "$dir" diff --cached --quiet > /dev/null 2>&1; then
    printf -- '-\n'
    return 0
  fi
  _config_repo_git -C "$dir" -c user.email=config-backup@localhost -c user.name=config-backup \
    commit -q -m "config snapshot $(date -u +%Y-%m-%dT%H:%M:%SZ)" > /dev/null 2>&1 || return 3
  _config_repo_git -C "$dir" push -q origin HEAD:refs/heads/backup/config > /dev/null 2>&1 || return 2
  sha=$(_config_repo_git -C "$dir" rev-parse HEAD 2> /dev/null) || return 3
  printf '%s\n' "$sha"
}

# config_repo_write_state FILE HASH COMMIT PUSH [STORE_RECIPIENT]: merges the unit
# fields, keeping the record of the last attempt. Atomic.
config_repo_write_state() {
  local f="$1" hash="$2" commit="$3" push="$4" recip="${5-__keep__}" dir tmp base='{}'
  dir=$(dirname "$f")
  mkdir -p "$dir"
  if [ -s "$f" ] && jq -e 'type == "object"' "$f" > /dev/null 2>&1; then
    base=$(cat "$f")
  fi
  tmp=$(mktemp "$dir/.config-backup.json.XXXXXX")
  if jq --arg hash "$hash" --arg commit "$commit" --arg push "$push" --arg recip "$recip" \
        '. + {hash:$hash, last_commit:$commit, last_push:$push}
         + (if $recip == "__keep__" then {} else {store_recipient:$recip} end)' <<< "$base" > "$tmp"; then
    mv -f "$tmp" "$f"
  else
    rm -f "$tmp"
  fi
}

# config_build_maps WORKSPACE AGENT_YML SENSITIVE AGENT PLAIN_MAP STORE_MAP ALL_MAP
# The extended config tree of the repo path (U3, data-model section 5): agent.yml,
# CLAUDE.md, personas/ without the *.bak* copies, docker-compose.override.yml if it
# exists, and the closed list of the workspace's .claude/. In a sensitive agent only
# agent.yml stays in plaintext; everything else goes to the store map.
config_build_maps() {
  local ws="$1" yml="$2" sensitive="$3" agent="$4" plain="$5" store="$6" all="$7"
  : > "$plain"; : > "$store"; : > "$all"
  _cfg_add() {  # LOGICAL SOURCE [plain]
    local target="$store"
    if [ "${3:-}" = "plain" ] || [ "$sensitive" != "true" ]; then target="$plain"; fi
    printf '%s\0%s\0' "$1" "$2" >> "$target"
    printf '%s\0%s\0' "$1" "$2" >> "$all"
  }
  [ -f "$yml" ] && _cfg_add agent.yml "$yml" plain
  [ -f "$ws/CLAUDE.md" ] && _cfg_add CLAUDE.md "$ws/CLAUDE.md"
  local f rel item
  if [ -d "$ws/personas" ]; then
    while IFS= read -r -d '' f; do
      rel="${f#"$ws"/}"
      case "${f##*/}" in *.bak*) continue ;; esac
      _cfg_add "$rel" "$f"
    done < <(find "$ws/personas" -type f -print0 2> /dev/null | LC_ALL=C sort -z)
  fi
  [ -f "$ws/docker-compose.override.yml" ] && _cfg_add docker-compose.override.yml "$ws/docker-compose.override.yml"
  [ -f "$ws/.claude/settings.json" ] && _cfg_add .claude/settings.json "$ws/.claude/settings.json"
  for item in skills commands agents hooks output-styles; do
    [ -d "$ws/.claude/$item" ] || continue
    while IFS= read -r -d '' f; do
      rel="${f#"$ws"/}"
      _cfg_add "$rel" "$f"
    done < <(find "$ws/.claude/$item" -name .git -prune -o -type f -print0 2> /dev/null | LC_ALL=C sort -z)
  done
  unset -f _cfg_add
  return 0
}

# config_repo_stage_plain DIR PLAIN_MAP: copies the plaintext part into the tree.
config_repo_stage_plain() {
  local dir="$1" map="$2" rel src
  while IFS= read -r -d '' rel && IFS= read -r -d '' src; do
    [ -f "$src" ] || continue
    mkdir -p "$(dirname "$dir/$rel")" || return 3
    cp -p "$src" "$dir/$rel" || return 3
  done < "$map"
  return 0
}
