# Library: helpers for the config backup primitive.
# Snapshots agent.yml (no secrets, no encryption needed) to the
# 'backup/config' orphan branch on the agent's fork. Restoration uses
# this branch first to recover the agent.yml + run setup.sh --regenerate
# before pulling identity and vault.

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
    git clone --no-checkout "$fork_url" "$dir" >/dev/null 2>&1
  fi
  (cd "$dir" && git fetch origin backup/config >/dev/null 2>&1 || true)
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
  if ! git -C "$stage" push origin backup/config >/dev/null 2>&1; then
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
