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
# $1 = state dir, $2 (optional) = recipient string ("" for partial mode).
identity_hash() {
  local state_dir="${1:?identity_hash: need state dir}"
  local recipient="${2:-}"
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
    if [ -f "$state_dir/.env" ]; then
      cat "$state_dir/.env"
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
