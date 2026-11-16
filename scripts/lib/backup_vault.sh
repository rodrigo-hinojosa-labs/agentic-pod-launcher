# shellcheck shell=bash
# Library: helpers for the vault backup primitive.
# Mirrors backup_identity.sh in shape: pure helpers + commit/push flow.
# Source of truth for the vault path is agent.yml's vault.path (default
# .state/.vault). Bind-mount maps that to /home/agent/.vault inside the
# container — vault_resolve_root handles the translation.

# Non-interactive git wrapper (60s cap when timeout(1) is available).
# Same rationale as _identity_git in backup_identity.sh: cron +
# watchdog can't survive a git stdin prompt when fork creds are
# missing. timeout(1) absence is tolerated for portability with macOS
# host tests.
_vault_git() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 60 env GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/true git "$@"
  else
    env GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/true git "$@"
  fi
}

# Resolve the vault root from agent.yml.
# stdout: absolute path. Docker: rebased under /home/agent (bind-mount). Local
# mode (012) sets VAULT_ROOT_OVERRIDE to the real workspace path, which wins
# outright — no /home/agent rebase, since there is no bind-mount on the host.
# Empty if vault not enabled (and no override given).
vault_resolve_root() {
  # Additive override: local-mode entrypoints export the resolved workspace
  # vault path. Non-empty → return it verbatim (no rebase). Docker never sets it,
  # so its rebase contract (fixed by the tests below) is untouched.
  if [ -n "${VAULT_ROOT_OVERRIDE:-}" ]; then
    printf '%s\n' "$VAULT_ROOT_OVERRIDE"
    return 0
  fi
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
    _vault_git clone --no-checkout "$fork_url" "$dir" >/dev/null 2>&1
  fi
  (cd "$dir" && _vault_git fetch origin backup/vault >/dev/null 2>&1 || true)
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
  if ! _vault_git -C "$stage" push origin backup/vault >/dev/null 2>&1; then
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

# ── 046: the repo path (an associated private repository, docker mode) ──────
#
# Contract: specs/046-agent-backup-repo/contracts/backup-units.md (U1, U4). Only
# heartbeatctl calls these, and only when backup_dest_resolve answers `repo`;
# local mode never reaches them. They keep this unit's own cache, tree, commit and
# push (constitution, Principle V).

_vault_repo_git() {
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

# vault_repo_prepare URL REMOTE_HEAD [KEEP_STORE] -> stdout: the cache dir. With
# KEEP_STORE=1 the store/ directory survives the wipe of the tree (block reuse).
vault_repo_prepare() {
  local url="$1" remote_head="$2" keep_store="${3:-0}"
  local base="${VAULT_BACKUP_CACHE_DIR:-/home/agent/.cache/agent-backup}"
  local dir="$base/vault-repo"
  mkdir -p "$base" || return 2
  if [ -z "$remote_head" ] || [ ! -d "$dir/.git" ]; then
    rm -rf "$dir"
    mkdir -p "$dir" || return 2
    _vault_repo_git -C "$dir" init -q > /dev/null 2>&1 || return 2
    _vault_repo_git -C "$dir" symbolic-ref HEAD refs/heads/backup/vault || return 2
    _vault_repo_git -C "$dir" remote add origin "$url" || return 2
  else
    _vault_repo_git -C "$dir" remote set-url origin "$url" > /dev/null 2>&1 \
      || _vault_repo_git -C "$dir" remote add origin "$url" > /dev/null 2>&1 || return 2
  fi
  if [ -n "$remote_head" ]; then
    _vault_repo_git -C "$dir" fetch -q --depth 1 origin \
      "+refs/heads/backup/vault:refs/remotes/origin/backup/vault" > /dev/null 2>&1 || return 2
    _vault_repo_git -C "$dir" checkout -q -f -B backup/vault \
      refs/remotes/origin/backup/vault > /dev/null 2>&1 || return 2
  fi
  if [ "$keep_store" = "1" ]; then
    find "$dir" -mindepth 1 -maxdepth 1 ! -name .git ! -name store -exec rm -rf {} + 2> /dev/null
  else
    find "$dir" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} + 2> /dev/null
  fi
  printf '%s\n' "$dir"
}

# vault_repo_stage_markdown DIR VAULT_DIR: copies the markdown subset, with its
# structure, into the tree (the plaintext form of the unit).
vault_repo_stage_markdown() {
  local dir="$1" vault_dir="$2" path rel
  while IFS= read -r -d '' path; do
    rel="${path#"$vault_dir"/}"
    mkdir -p "$(dirname "$dir/$rel")" || return 3
    cp -a "$path" "$dir/$rel" || return 3
  done < <(vault_list_markdown "$vault_dir")
  return 0
}

# vault_repo_commit_and_push DIR AGENT -> "<sha>" or "-"; rc 2 push failed, 3 error.
# The tree is already staged by the caller (markdown or store/).
vault_repo_commit_and_push() {
  local dir="$1" agent="$2" sha
  backup_dest_mark_json "$agent" vault > "$dir/.agentic-pod-backup.json" || return 3
  _vault_repo_git -C "$dir" add -A > /dev/null 2>&1 || return 3
  if _vault_repo_git -C "$dir" rev-parse --verify -q HEAD > /dev/null 2>&1 \
     && _vault_repo_git -C "$dir" diff --cached --quiet > /dev/null 2>&1; then
    printf -- '-\n'
    return 0
  fi
  _vault_repo_git -C "$dir" -c user.email=vault-backup@localhost -c user.name=vault-backup \
    commit -q -m "vault snapshot $(date -u +%Y-%m-%dT%H:%M:%SZ)" > /dev/null 2>&1 || return 3
  _vault_repo_git -C "$dir" push -q origin HEAD:refs/heads/backup/vault > /dev/null 2>&1 || return 2
  sha=$(_vault_repo_git -C "$dir" rev-parse HEAD 2> /dev/null) || return 3
  printf '%s\n' "$sha"
}

# vault_repo_write_state FILE HASH COMMIT PUSH [STORE_RECIPIENT]: merges the unit
# fields, keeping the record of the last attempt. Atomic.
vault_repo_write_state() {
  local f="$1" hash="$2" commit="$3" push="$4" recip="${5-__keep__}" dir tmp base='{}'
  dir=$(dirname "$f")
  mkdir -p "$dir"
  if [ -s "$f" ] && jq -e 'type == "object"' "$f" > /dev/null 2>&1; then
    base=$(cat "$f")
  fi
  tmp=$(mktemp "$dir/.vault-backup.json.XXXXXX")
  if jq --arg hash "$hash" --arg commit "$commit" --arg push "$push" --arg recip "$recip" \
        '. + {hash:$hash, last_commit:$commit, last_push:$push}
         + (if $recip == "__keep__" then {} else {store_recipient:$recip} end)' <<< "$base" > "$tmp"; then
    mv -f "$tmp" "$f"
  else
    rm -f "$tmp"
  fi
}
