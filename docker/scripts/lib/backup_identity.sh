# shellcheck shell=bash
# Library: helpers for the identity backup primitive.
# Sourced by heartbeatctl and tests. Pure functions where possible; the
# file operations (cp, git) live here but the orchestration (the flow)
# lives in heartbeatctl's cmd_backup_identity.

# Run a git network command in a non-interactive environment, capped at
# 60s when timeout(1) is available. The agent runs unattended
# (watchdog + cron); without these guards, git asks for a username on
# stdin when credentials are missing or the fork URL is unreachable —
# that prompt blocks forever and deadlocks the watchdog (which then
# can't respawn the tmux session the user needs to /login). The
# timeout is a second-line defense for a hung TLS handshake or DNS
# that ignores the prompt guard. timeout(1) is GNU coreutils, present
# on Alpine (production) but not on macOS by default (tests) — fall
# back to a plain invocation so the lib stays portable; the outer
# safeguard in start_services.sh::_trigger_identity_backup applies
# anyway in the production code path.
_identity_git() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 60 env GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/true git "$@"
  else
    env GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/true git "$@"
  fi
}

# Emit the whitelist of identity-relevant paths (relative to the state
# dir). STDOUT: one path per line. Order matters for hashing — keep
# sorted.
identity_whitelist() {
  local state_dir="${1:?identity_whitelist: need state dir}"
  cat <<EOF
.claude.json
.claude/settings.json
.claude/channels/telegram/access.json
.claude/plugins/config
EOF
}

# Compute a stable hash over the whitelist contents PLUS the .env file
# (when present) and the recipient identity. Missing files are skipped
# (their absence is part of the hash — a file disappearing counts as a
# change). Including .env + recipient means partial↔full transitions and
# .env edits both trigger a re-backup; without them, _bi_run would skip.
# Output: sha256 hex.
#
# $1 = state dir, $2 (optional) = recipient string ("" for partial mode),
# $3 (optional, 046) = the secrets file to hash. Without it, the one in the state
# dir, as before 046. The repo path passes the workspace-root file
# (identity_secrets_file), the one a real agent actually has (research M13).
identity_hash() {
  local state_dir="${1:?identity_hash: need state dir}"
  local recipient="${2:-}"
  local secrets="${3:-$state_dir/.env}"
  local path full
  {
    while IFS= read -r path; do
      full="$state_dir/$path"
      printf 'BEGIN %s\n' "$path"
      if [ -f "$full" ]; then
        cat "$full"
      elif [ -d "$full" ]; then
        find "$full" -type f 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
          printf 'FILE %s\n' "${f#$state_dir/}"
          cat "$f"
        done
      else
        printf 'MISSING\n'
      fi
      printf '\nEND %s\n' "$path"
    done < <(identity_whitelist "$state_dir")

    # .env content (when present) — part of the hash so .env edits trigger
    # a backup even though .env isn't in the whitelist.
    printf 'BEGIN .env\n'
    if [ -f "$secrets" ]; then
      cat "$secrets"
    else
      printf 'MISSING\n'
    fi
    printf '\nEND .env\n'

    # Recipient — toggling encryption mode is a meaningful change.
    printf 'RECIPIENT %s\n' "$recipient"
  } | _identity_sha256 | awk '{print $1}'
}

# Portable sha256: prefer sha256sum (Linux/Alpine), fall back to shasum -a 256 (macOS).
_identity_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum
  else
    shasum -a 256
  fi
}

# Read the last-backup hash from identity-backup.json, empty if absent.
identity_last_hash() {
  local state_file="$1"
  [ -f "$state_file" ] || { echo ""; return; }
  jq -r '.hash // ""' "$state_file" 2>/dev/null
}

# Prepare a local clone of the fork for staging backups. Reused across
# invocations. Returns the clone dir on stdout.
identity_prepare_clone() {
  local fork_url="$1"
  local cache_base="${IDENTITY_BACKUP_CACHE_DIR:-/home/agent/.cache/identity-backup}"
  local dir="$cache_base/clone"
  mkdir -p "$cache_base"

  if [ ! -d "$dir/.git" ]; then
    _identity_git clone --no-checkout "$fork_url" "$dir" >/dev/null 2>&1
  fi
  (cd "$dir" && _identity_git fetch origin backup/identity >/dev/null 2>&1 || true)
  printf '%s\n' "$dir"
}

# Stage the whitelist into a worktree under $clone_dir, then commit + push.
# $1 = local clone dir, $2 = state dir, $3 = recipient (may be empty)
# STDOUT: "<sha> <mode>" where mode is "full" or "partial".
# A leading "- " in place of <sha> indicates "no change after staging".
identity_commit_and_push() {
  local clone_dir="$1" state_dir="$2" recipient="$3"
  local stage="$clone_dir/_stage"
  local mode
  [ -n "$recipient" ] && mode="full" || mode="partial"

  # Detach any stale worktree at $stage from a previous run before nuking it,
  # otherwise git refuses to add a new worktree at the same path.
  (cd "$clone_dir" && git worktree remove --force "$stage" 2>/dev/null) || true
  rm -rf "$stage"

  local orphan=0
  if git -C "$clone_dir" rev-parse --verify --quiet origin/backup/identity >/dev/null; then
    git -C "$clone_dir" worktree add -B backup/identity "$stage" origin/backup/identity >/dev/null 2>&1
  else
    # First backup: orphan branch from scratch. Worktree-on-empty-clone is
    # fragile (no HEAD to detach from), so we init a self-contained repo at
    # $stage and push directly to the fork.
    orphan=1
    mkdir -p "$stage"
    git -C "$stage" init -q
    git -C "$stage" symbolic-ref HEAD refs/heads/backup/identity
    git -C "$stage" remote add origin "$(git -C "$clone_dir" config --get remote.origin.url)"
  fi

  local path
  while IFS= read -r path; do
    if [ -e "$state_dir/$path" ]; then
      mkdir -p "$stage/$(dirname "$path")"
      cp -a "$state_dir/$path" "$stage/$path"
    fi
  done < <(identity_whitelist "$state_dir")

  if [ -n "$recipient" ] && [ -f "$state_dir/.env" ]; then
    printf '%s\n' "$recipient" > "$stage/.recipient.tmp"
    age -R "$stage/.recipient.tmp" -o "$stage/.env.age" "$state_dir/.env"
    rm -f "$stage/.recipient.tmp"
  else
    rm -f "$stage/.env.age"
  fi

  git -C "$stage" add -A
  if git -C "$stage" diff --cached --quiet; then
    if [ "$orphan" -eq 1 ]; then
      rm -rf "$stage"
    else
      (cd "$clone_dir" && git worktree remove --force "$stage" 2>/dev/null) || rm -rf "$stage"
    fi
    printf '- %s\n' "$mode"
    return 0
  fi

  local msg ts sha
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  msg="identity snapshot $ts"
  git -C "$stage" -c user.email=identity-backup@localhost -c user.name=identity-backup \
       commit -m "$msg" >/dev/null
  if ! _identity_git -C "$stage" push origin backup/identity >/dev/null 2>&1; then
    echo "backup-identity: push failed" >&2
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
  printf '%s %s\n' "$sha" "$mode"
}

# Write identity-backup.json atomically.
identity_write_state() {
  local state_file="$1" hash="$2" mode="$3" commit="$4" push_ts="$5"
  local dir tmp
  dir=$(dirname "$state_file")
  mkdir -p "$dir"
  tmp=$(mktemp "$dir/.identity-backup.json.XXXXXX")
  jq -n \
    --arg hash "$hash" \
    --arg mode "$mode" \
    --arg commit "$commit" \
    --arg push "$push_ts" \
    '{hash:$hash, mode:$mode, last_commit:$commit, last_push:$push}' \
    > "$tmp"
  mv "$tmp" "$state_file"
}

# ── 046: the repo path (an associated private repository) ───────────────────
#
# Contract: specs/046-agent-backup-repo/contracts/backup-units.md (U1, U2). The
# fork path above is untouched: these functions are only called by heartbeatctl
# when backup_dest_resolve answers `repo`. They keep this unit's own cache, tree,
# commit and push (constitution, Principle V); what they share (credential,
# privacy, mark, lock, record) lives in backup_dest.sh and never commits.

# identity_secrets_file TYPE WORKSPACE STATE_DIR -> the secrets file this unit reads.
# With the repo type, the workspace root (where every real agent keeps it, M13);
# otherwise the state dir, as before 046. heartbeatctl and the supervisor both
# call it, so both compute the same hash.
identity_secrets_file() {
  local type="$1" workspace="$2" state_dir="$3"
  if [ "$type" = "repo" ]; then
    printf '%s/.env\n' "$workspace"
  else
    printf '%s/.env\n' "$state_dir"
  fi
}

# git for this unit's repo path (C2): no prompt, the agent's askpass, no global or
# system git config (D32), C locale, and `timeout -k 10` when timeout(1) exists.
# Descriptor 9 (the unit lock) is closed for the child.
_identity_repo_git() {
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

# identity_repo_prepare URL REMOTE_HEAD -> stdout: the cache dir (a normal repo,
# distinct from the fork path's clone). An empty REMOTE_HEAD means the branch does
# not exist remotely: the cache is created again, empty, and the branch is born
# with one commit (D35). rc 2 when the fetch fails.
identity_repo_prepare() {
  local url="$1" remote_head="$2"
  local base="${IDENTITY_BACKUP_CACHE_DIR:-/home/agent/.cache/identity-backup}"
  local dir="$base/identity-repo"
  mkdir -p "$base" || return 2
  # 048: with BACKUP_REPO_TARGET=main the cache is local only: it keeps its own
  # history (its tree is what goes into main) and never fetches backup/identity.
  if [ "${BACKUP_REPO_TARGET:-}" = "main" ] && [ -d "$dir/.git" ]; then
    # 048: a fresh local history each run, so the cache never accumulates every past
    # store (046 got the same by fetching the branch at depth 1). The worktree, with
    # store/ and the block map next to it, is kept.
    rm -rf "$dir/.git"
    _identity_repo_git -C "$dir" init -q > /dev/null 2>&1 || return 2
    _identity_repo_git -C "$dir" symbolic-ref HEAD refs/heads/backup/identity || return 2
  fi
  if [ ! -d "$dir/.git" ] || { [ -z "$remote_head" ] && [ "${BACKUP_REPO_TARGET:-}" != "main" ]; }; then
    rm -rf "$dir"
    mkdir -p "$dir" || return 2
    _identity_repo_git -C "$dir" init -q > /dev/null 2>&1 || return 2
    _identity_repo_git -C "$dir" symbolic-ref HEAD refs/heads/backup/identity || return 2
    _identity_repo_git -C "$dir" remote add origin "$url" || return 2
  else
    _identity_repo_git -C "$dir" remote set-url origin "$url" > /dev/null 2>&1 \
      || _identity_repo_git -C "$dir" remote add origin "$url" > /dev/null 2>&1 || return 2
  fi
  if [ -n "$remote_head" ] && [ "${BACKUP_REPO_TARGET:-}" != "main" ]; then
    _identity_repo_git -C "$dir" fetch -q --depth 1 origin \
      "+refs/heads/backup/identity:refs/remotes/origin/backup/identity" > /dev/null 2>&1 || return 2
    _identity_repo_git -C "$dir" checkout -q -f -B backup/identity \
      refs/remotes/origin/backup/identity > /dev/null 2>&1 || return 2
  fi
  find "$dir" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} + 2> /dev/null
  printf '%s\n' "$dir"
}

# identity_repo_commit_and_push DIR STATE_DIR RECIPIENT SECRETS AGENT
# stdout: "<sha> <mode>", or "- <mode>" when the tree equals the remote head.
# rc 2 when the push fails, 3 when the tree cannot be built.
# The secrets file is encrypted straight from its path: it is never copied in
# plaintext into the cache or the tree (I8).
identity_repo_commit_and_push() {
  local dir="$1" state_dir="$2" recipient="$3" secrets="$4" agent="$5"
  local mode path sha
  if [ -n "$recipient" ]; then mode="full"; else mode="partial"; fi
  while IFS= read -r path; do
    if [ -e "$state_dir/$path" ]; then
      mkdir -p "$(dirname "$dir/$path")" || return 3
      cp -a "$state_dir/$path" "$dir/$path" || return 3
    fi
  done < <(identity_whitelist "$state_dir")
  if [ -n "$recipient" ] && [ -f "$secrets" ]; then
    printf '%s\n' "$recipient" > "$dir/.git/agentic-recipient" || return 3
    if ! age -R "$dir/.git/agentic-recipient" -o "$dir/.env.age" "$secrets" 2> /dev/null; then
      rm -f "$dir/.git/agentic-recipient" "$dir/.env.age"
      return 3
    fi
    rm -f "$dir/.git/agentic-recipient"
  fi
  backup_dest_mark_json "$agent" identity > "$dir/.agentic-pod-backup.json" || return 3
  _identity_repo_git -C "$dir" add -A > /dev/null 2>&1 || return 3
  if _identity_repo_git -C "$dir" rev-parse --verify -q HEAD > /dev/null 2>&1 \
     && _identity_repo_git -C "$dir" diff --cached --quiet > /dev/null 2>&1; then
    printf -- '- %s\n' "$mode"
    return 0
  fi
  _identity_repo_git -C "$dir" -c user.email=identity-backup@localhost -c user.name=identity-backup \
    commit -q -m "identity snapshot $(date -u +%Y-%m-%dT%H:%M:%SZ)" > /dev/null 2>&1 || return 3
  # 048: with BACKUP_REPO_TARGET=main the commit stays local; heartbeatctl publishes
  # its tree into main (backup_main.sh).
  if [ "${BACKUP_REPO_TARGET:-}" != "main" ]; then
    _identity_repo_git -C "$dir" push -q origin HEAD:refs/heads/backup/identity > /dev/null 2>&1 || return 2
  fi
  sha=$(_identity_repo_git -C "$dir" rev-parse HEAD 2> /dev/null) || return 3
  printf '%s %s\n' "$sha" "$mode"
}

# identity_repo_write_state FILE HASH MODE COMMIT PUSH: merges these four fields,
# keeping the record of the last attempt (backup_dest_record). Atomic.
identity_repo_write_state() {
  local f="$1" hash="$2" mode="$3" commit="$4" push="$5" dir tmp base='{}'
  dir=$(dirname "$f")
  mkdir -p "$dir"
  if [ -s "$f" ] && jq -e 'type == "object"' "$f" > /dev/null 2>&1; then
    base=$(cat "$f")
  fi
  tmp=$(mktemp "$dir/.identity-backup.json.XXXXXX")
  if jq --arg hash "$hash" --arg mode "$mode" --arg commit "$commit" --arg push "$push" \
        '. + {hash:$hash, mode:$mode, last_commit:$commit, last_push:$push}' <<< "$base" > "$tmp"; then
    mv -f "$tmp" "$f"
  else
    rm -f "$tmp"
  fi
}
