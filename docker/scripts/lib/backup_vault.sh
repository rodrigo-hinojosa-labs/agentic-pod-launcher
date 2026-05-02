# Library: helpers for the vault backup primitive.
# Mirrors backup_identity.sh in shape: pure helpers + commit/push flow.
# Source of truth for the vault path is agent.yml's vault.path (default
# .state/.vault). Bind-mount maps that to /home/agent/.vault inside the
# container — vault_resolve_root handles the translation.

# Resolve the in-container vault root from agent.yml.
# stdout: absolute path under /home/agent. Empty if vault not enabled.
vault_resolve_root() {
  local agent_yml="${1:-/workspace/agent.yml}"
  [ -f "$agent_yml" ] || return 0
  local enabled vault_path
  enabled=$(yq -r '.vault.enabled // false' "$agent_yml" 2>/dev/null)
  [ "$enabled" = "true" ] || return 0
  vault_path=$(yq -r '.vault.path // ".state/.vault"' "$agent_yml" 2>/dev/null)
  if [ "$vault_path" = ".state/.vault" ]; then
    printf '/home/agent/.vault\n'
  else
    # The bind-mount /workspace/.state → /home/agent strips the .state/
    # prefix. For non-default paths we rebase under /home/agent/ the
    # same way start_services.sh does it.
    printf '/home/agent/%s\n' "${vault_path#.state/}"
  fi
}

# Patterns to exclude from staging. Glob-style, evaluated by `find`.
# Keep alphabetical for review; deduplicate with backup_vault_exclude_args.
vault_exclude_patterns() {
  cat <<'EOF'
.git
.obsidian/cache
.obsidian/workspace*.json
.obsidian/.trash
.trash
*.sync-conflict-*
EOF
}

# Build a `find ... -prune` argument vector that drops every excluded
# path from the walk. Stdout: argv-like, one token per line. Uses
# `printf -- '%s\n' VAL` because some patterns and flags begin with `-`,
# which printf would otherwise interpret as a flag.
_vault_find_exclude_args() {
  local first=1 pat
  while IFS= read -r pat; do
    [ -z "$pat" ] && continue
    if [ "$first" -eq 1 ]; then
      printf -- '%s\n' '('
      first=0
    else
      printf -- '%s\n' '-o'
    fi
    printf -- '%s\n%s\n' '-name' "$pat"
  done < <(vault_exclude_patterns)
  if [ "$first" -eq 0 ]; then
    printf -- '%s\n%s\n%s\n' ')' '-prune' '-o'
  fi
}

# List every markdown file under $vault_dir that should be backed up,
# null-separated for safe handling of paths with spaces.
vault_list_markdown() {
  local vault_dir="${1:?vault_list_markdown: need vault dir}"
  [ -d "$vault_dir" ] || return 0
  local args=()
  while IFS= read -r line; do
    args+=("$line")
  done < <(_vault_find_exclude_args)
  find "$vault_dir" "${args[@]}" -type f -name '*.md' -print0 2>/dev/null \
    | LC_ALL=C sort -z
}

# Stable hash over the vault's markdown content. Filenames (relative to
# vault_dir) and content both contribute — a rename is a real change.
# Output: sha256 hex.
vault_hash() {
  local vault_dir="${1:?vault_hash: need vault dir}"
  [ -d "$vault_dir" ] || { printf 'EMPTY\n' | _vault_sha256 | awk '{print $1}'; return; }
  {
    while IFS= read -r -d '' path; do
      printf 'FILE %s\n' "${path#$vault_dir/}"
      cat "$path"
      printf '\nEND\n'
    done < <(vault_list_markdown "$vault_dir")
  } | _vault_sha256 | awk '{print $1}'
}

# Portable sha256 (same pattern as backup_identity.sh).
_vault_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum
  else
    shasum -a 256
  fi
}

# Read the last vault-backup hash from vault-backup.json, empty if absent.
vault_last_hash() {
  local state_file="$1"
  [ -f "$state_file" ] || { echo ""; return; }
  jq -r '.hash // ""' "$state_file" 2>/dev/null
}

# Prepare a per-branch local clone for staging. Cache dir is one level
# deeper than identity's (we share the parent base, separate branch dirs).
vault_prepare_clone() {
  local fork_url="$1"
  local cache_base="${VAULT_BACKUP_CACHE_DIR:-/home/agent/.cache/agent-backup}"
  local dir="$cache_base/vault-clone"
  mkdir -p "$cache_base"

  if [ ! -d "$dir/.git" ]; then
    git clone --no-checkout "$fork_url" "$dir" >/dev/null 2>&1
  fi
  (cd "$dir" && git fetch origin backup/vault >/dev/null 2>&1 || true)
  printf '%s\n' "$dir"
}

# Stage the markdown subset into a worktree under $clone_dir, commit, push.
# $1 = local clone dir, $2 = vault dir.
# STDOUT: "<sha>" on commit+push, "-" if nothing changed.
vault_commit_and_push() {
  local clone_dir="$1" vault_dir="$2"
  local stage="$clone_dir/_stage"

  (cd "$clone_dir" && git worktree remove --force "$stage" 2>/dev/null) || true
  rm -rf "$stage"

  local orphan=0
  if git -C "$clone_dir" rev-parse --verify --quiet origin/backup/vault >/dev/null; then
    git -C "$clone_dir" worktree add -B backup/vault "$stage" origin/backup/vault >/dev/null 2>&1
  else
    orphan=1
    mkdir -p "$stage"
    git -C "$stage" init -q
    git -C "$stage" symbolic-ref HEAD refs/heads/backup/vault
    git -C "$stage" remote add origin "$(git -C "$clone_dir" config --get remote.origin.url)"
  fi

  # Wipe stage's tracked tree (except .git) so deletes propagate to next
  # commit. Without this, a removed note in vault stays in backup/vault.
  if [ "$orphan" -eq 0 ]; then
    find "$stage" -mindepth 1 -maxdepth 1 ! -name '.git' -exec rm -rf {} +
  fi

  # Copy every staged markdown over, preserving directory layout.
  local rel target_dir
  while IFS= read -r -d '' path; do
    rel="${path#$vault_dir/}"
    target_dir="$stage/$(dirname "$rel")"
    mkdir -p "$target_dir"
    cp -a "$path" "$stage/$rel"
  done < <(vault_list_markdown "$vault_dir")

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
  msg="vault snapshot $ts"
  git -C "$stage" -c user.email=vault-backup@localhost -c user.name=vault-backup \
       commit -m "$msg" >/dev/null
  if ! git -C "$stage" push origin backup/vault >/dev/null 2>&1; then
    echo "backup-vault: push failed" >&2
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

# Write vault-backup.json atomically.
vault_write_state() {
  local state_file="$1" hash="$2" commit="$3" push_ts="$4"
  local dir tmp
  dir=$(dirname "$state_file")
  mkdir -p "$dir"
  tmp=$(mktemp "$dir/.vault-backup.json.XXXXXX")
  jq -n \
    --arg hash "$hash" \
    --arg commit "$commit" \
    --arg push "$push_ts" \
    '{hash:$hash, last_commit:$commit, last_push:$push}' \
    > "$tmp"
  mv "$tmp" "$state_file"
}
