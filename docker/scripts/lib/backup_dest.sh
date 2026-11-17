# shellcheck shell=bash
# Library (046): where the agent's backups go, with which credential, and whether
# that destination may receive them.
#
# Contract: specs/046-agent-backup-repo/contracts/destination-and-credential.md
# (C1 to C8). Sourced by heartbeatctl, by start_services.sh and by the tests. It
# has no side effects at load time.
#
# This is shared, NON-committing code (constitution, Principle V): it never stages
# a tree, never commits, never pushes and never hashes a unit's content. The only
# thing it writes into a unit's state file is the record of its last attempt
# (backup_dest_record). Each unit keeps its own branch, clone cache, hash, staging
# and commit code in its own library.
#
# Test seams: BACKUP_DEST_AGENT_YML, BACKUP_DEST_STATE_FILE, BACKUP_DEST_ALLOW_HTTP,
# BACKUP_DEST_NOW, BACKUP_PROBE_TIMEOUT_S and BACKUP_ASKPASS_OVERRIDE.

# The heartbeat directory: where backup-dest.json, the unit state files and the
# unit locks live. One seam (BACKUP_DEST_STATE_FILE) moves all of them.
_backup_dest_state_file() {
  printf '%s\n' "${BACKUP_DEST_STATE_FILE:-/workspace/scripts/heartbeat/backup-dest.json}"
}

_backup_dest_hb_dir() {
  local f
  f=$(_backup_dest_state_file)
  printf '%s\n' "${f%/*}"
}

_backup_dest_now() {
  if [ -n "${BACKUP_DEST_NOW:-}" ]; then
    printf '%s\n' "$BACKUP_DEST_NOW"
  else
    date +%s
  fi
}

# Seconds since the epoch -> ISO 8601 in UTC ending in Z (GNU/BusyBox, then BSD).
_backup_dest_iso() {
  local e="$1"
  date -u -d "@$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -r "$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || printf '1970-01-01T00:00:00Z\n'
}

_backup_dest_is_uint() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# Run a command capped at N seconds with `timeout -k 10 N` when timeout(1) exists.
# Without timeout (the Mac) it runs uncapped: the image has it (research M20) and
# the host tests put their own on the PATH. Descriptor 9 (a unit's run lock) is
# closed for the child, so a straggler can never keep the lock (lesson of 044).
_backup_dest_capped() {
  local secs="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout -k 10 "$secs" "$@" 9>&-
  else
    "$@" 9>&-
  fi
}

# ── C1: the destination rule ────────────────────────────────────────────────

# backup_dest_resolve [AGENT_YML] -> "<type>\t<url>", type repo | fork | none.
# The agent's repository wins, else its fork, else nothing. Read-only, rc 0 always.
backup_dest_resolve() {
  local f="${1:-${BACKUP_DEST_AGENT_YML:-/workspace/agent.yml}}"
  local repo="" fork=""
  if [ -r "$f" ]; then
    repo=$(yq -r '.backup.repo.url // ""' "$f" 2>/dev/null) || repo=""
    fork=$(yq -r '.scaffold.fork.url // ""' "$f" 2>/dev/null) || fork=""
  fi
  [ "$repo" = "null" ] && repo=""
  [ "$fork" = "null" ] && fork=""
  if [ -n "$repo" ]; then
    printf 'repo\t%s\n' "$repo"
  elif [ -n "$fork" ]; then
    printf 'fork\t%s\n' "$fork"
  else
    printf 'none\t\n'
  fi
  return 0
}

# ── C2: the push credential ─────────────────────────────────────────────────

# backup_dest_askpass TYPE -> the askpass git must use. Only the repo type with a
# non-empty GITHUB_PAT gets the real one; everything else gets /bin/true, which is
# exactly what the fork path has always used.
backup_dest_askpass() {
  if [ "${1:-}" = "repo" ] && [ -n "${GITHUB_PAT:-}" ]; then
    printf '%s\n' "${BACKUP_ASKPASS_OVERRIDE:-/opt/agent-admin/scripts/git-askpass-agent.sh}"
  else
    printf '/bin/true\n'
  fi
}

# backup_dest_url_ok URL: the rule of backup.repo.url (data-model.md, section 1),
# minus the empty value (an empty URL is "no repository", never a destination).
# The same rule lives in scripts/lib/schema.sh and scripts/lib/wizard-validators.sh;
# all of them are checked against tests/fixtures/backup-repo/url-cases.tsv.
backup_dest_url_ok() {
  local url="${1:-}" name
  local re_gh='^https://github\.com/[A-Za-z0-9][A-Za-z0-9-]*/([A-Za-z0-9._-]+)$'
  local re_local='^http://(127\.0\.0\.1|localhost|host\.docker\.internal)(:[0-9]+)?(/[^[:space:]]*)?$'
  [ -n "$url" ] || return 1
  case "$url" in *[[:space:]]*|*@*) return 1 ;; esac
  if [[ "$url" =~ $re_gh ]]; then
    name="${BASH_REMATCH[1]}"
    name="${name%.git}"
    case "$name" in ''|.|..) return 1 ;; esac
    return 0
  fi
  if [ "${BACKUP_DEST_ALLOW_HTTP:-}" = "1" ] && [[ "$url" =~ $re_local ]]; then
    return 0
  fi
  return 1
}

# ── C3: privacy and the heads of the repository ─────────────────────────────

_backup_dest_allow_unverified() {
  local f="${BACKUP_DEST_AGENT_YML:-/workspace/agent.yml}" v=""
  [ -r "$f" ] && v=$(yq -r '.backup.repo.allow_unverified // false' "$f" 2>/dev/null)
  [ "$v" = "true" ]
}

_backup_dest_write_record() {
  local url="$1" verdict="$2" now="$3" anon_epoch="$4"
  local state dir tmp anon_iso=""
  state=$(_backup_dest_state_file)
  dir="${state%/*}"
  mkdir -p "$dir" 2>/dev/null || return 0
  _backup_dest_is_uint "$anon_epoch" && anon_iso=$(_backup_dest_iso "$anon_epoch")
  _backup_dest_is_uint "$anon_epoch" || anon_epoch=0
  tmp=$(mktemp "$dir/.backup-dest.json.XXXXXX" 2>/dev/null) || return 0
  if jq -n \
      --arg url "$url" \
      --arg verdict "$verdict" \
      --arg checked_at "$(_backup_dest_iso "$now")" \
      --argjson checked_epoch "$now" \
      --arg anon_checked_at "$anon_iso" \
      --argjson anon_checked_epoch "$anon_epoch" \
      '{url:$url, verdict:$verdict, checked_at:$checked_at, checked_epoch:$checked_epoch,
        anon_checked_at:$anon_checked_at, anon_checked_epoch:$anon_checked_epoch}' > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$state"
  else
    rm -f "$tmp"
  fi
}

# backup_dest_verify URL [HEADS_FILE] -> private | unverified-allowed | unverified |
# public | unreachable. Updates backup-dest.json; with HEADS_FILE, leaves there the
# output of the authenticated query (ls-remote --heads). rc 0 always.
backup_dest_verify() {
  local url="${1:-}" heads_out="${2:-}"
  local now limit hb
  now=$(_backup_dest_now)
  limit="${BACKUP_PROBE_TIMEOUT_S:-60}"
  _backup_dest_is_uint "$limit" || limit=60
  hb=$(_backup_dest_hb_dir)
  mkdir -p "$hb" 2>/dev/null || true

  # Step 0: a URL outside the rule is never contacted.
  if ! backup_dest_url_ok "$url"; then
    _backup_dest_write_record "$url" unreachable "$now" 0
    printf 'unreachable\n'
    return 0
  fi

  # Step 1: the anonymous probe, unless a fresh "private" probe of this same URL
  # exists. The 24-hour window counts from the last probe, never from the last run.
  local state prev_url="" prev_verdict="" prev_anon=""
  state=$(_backup_dest_state_file)
  if [ -s "$state" ]; then
    prev_url=$(jq -r '.url // ""' "$state" 2>/dev/null) || prev_url=""
    prev_verdict=$(jq -r '.verdict // ""' "$state" 2>/dev/null) || prev_verdict=""
    prev_anon=$(jq -r '.anon_checked_epoch // ""' "$state" 2>/dev/null) || prev_anon=""
  fi
  local anon="" anon_epoch=""
  if [ "$prev_url" = "$url" ] && [ "$prev_verdict" = "private" ] \
     && _backup_dest_is_uint "$prev_anon" && [ $((now - prev_anon)) -lt 86400 ] \
     && [ $((now - prev_anon)) -ge 0 ]; then
    anon="auth-required"
    anon_epoch="$prev_anon"
  else
    local err="$hb/.backup-dest.probe.$$" rc=0
    _backup_dest_capped "$limit" env LC_ALL=C GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/true \
      GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
      git -c credential.helper= ls-remote --heads "$url" > /dev/null 2> "$err" < /dev/null || rc=$?
    anon_epoch="$now"
    if [ "$rc" -eq 0 ]; then
      rm -f "$err"
      _backup_dest_write_record "$url" public "$now" "$anon_epoch"
      printf 'public\n'
      return 0
    fi
    if grep -qE 'Authentication failed|could not read Username|terminal prompts disabled' "$err" 2>/dev/null; then
      anon="auth-required"
    else
      anon="unknown"
    fi
    rm -f "$err"
  fi

  # Step 2: the authenticated query, every run.
  local heads="${heads_out:-$hb/.backup-dest.heads.$$}" arc=0
  _backup_dest_capped "$limit" env LC_ALL=C GIT_TERMINAL_PROMPT=0 \
    GIT_ASKPASS="$(backup_dest_askpass repo)" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    git -c credential.helper= ls-remote --heads "$url" > "$heads" 2> /dev/null < /dev/null || arc=$?
  [ -n "$heads_out" ] || rm -f "$heads"

  # Step 3: the verdict.
  local verdict
  if [ "$arc" -ne 0 ]; then
    verdict="unreachable"
  elif [ "$anon" = "auth-required" ]; then
    verdict="private"
  elif _backup_dest_allow_unverified; then
    verdict="unverified-allowed"
  else
    verdict="unverified"
  fi
  _backup_dest_write_record "$url" "$verdict" "$now" "$anon_epoch"
  printf '%s\n' "$verdict"
  return 0
}

# backup_dest_branch_head HEADS_FILE BRANCH -> the commit of refs/heads/BRANCH, or
# empty when the branch is not in the file (or the file does not exist).
backup_dest_branch_head() {
  local heads="$1" branch="$2"
  [ -r "$heads" ] || return 0
  awk -v ref="refs/heads/$branch" '$2 == ref { print $1; exit }' "$heads" 2>/dev/null
  return 0
}

# ── C4: the ownership mark ──────────────────────────────────────────────────

# backup_dest_check_owner CLONE_DIR BRANCH AGENT UNIT -> new | ok | foreign | other-agent.
# Reads origin/BRANCH:.agentic-pod-backup.json without checking anything out.
backup_dest_check_owner() {
  local clone="$1" branch="$2" agent="$3" unit="$4" mark a u
  if ! GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
       git -C "$clone" rev-parse --verify --quiet "refs/remotes/origin/$branch" > /dev/null 2>&1; then
    printf 'new\n'
    return 0
  fi
  if ! mark=$(GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
              git -C "$clone" show "refs/remotes/origin/$branch:.agentic-pod-backup.json" 2>/dev/null); then
    printf 'foreign\n'
    return 0
  fi
  a=$(jq -r '.agent // ""' <<< "$mark" 2>/dev/null) || a=""
  u=$(jq -r '.unit // ""' <<< "$mark" 2>/dev/null) || u=""
  if [ -z "$a" ] && [ -z "$u" ]; then
    printf 'foreign\n'
  elif [ "$a" = "$agent" ] && [ "$u" = "$unit" ]; then
    printf 'ok\n'
  else
    printf 'other-agent\n'
  fi
  return 0
}

# backup_dest_mark_json AGENT UNIT -> the content of .agentic-pod-backup.json.
# Shared so every unit writes the same shape; writing it into a tree is the unit's.
backup_dest_mark_json() {
  jq -n --arg agent "$1" --arg unit "$2" '{schema:1, agent:$agent, unit:$unit}'
}

# ── C5: the record of the last attempt ──────────────────────────────────────

# backup_dest_record UNIT RESULT [ATTEMPTED_HASH]: merges last_attempt,
# last_attempt_epoch, last_result and attempt_hash into <hb>/UNIT-backup.json,
# keeping every other field. Atomic (temporary file and mv). Never touches hash,
# last_commit or last_push: those belong to the unit.
backup_dest_record() {
  local unit="$1" result="$2" attempted="${3:-}"
  local hb f tmp now base='{}'
  hb=$(_backup_dest_hb_dir)
  f="$hb/$unit-backup.json"
  mkdir -p "$hb" 2>/dev/null || return 0
  now=$(_backup_dest_now)
  _backup_dest_is_uint "$now" || now=0
  if [ -s "$f" ] && jq -e 'type == "object"' "$f" > /dev/null 2>&1; then
    base=$(cat "$f")
  fi
  tmp=$(mktemp "$hb/.$unit-backup.json.XXXXXX" 2>/dev/null) || return 0
  if jq --arg iso "$(_backup_dest_iso "$now")" --argjson epoch "$now" \
        --arg result "$result" --arg attempted "$attempted" \
        '. + {last_attempt:$iso, last_attempt_epoch:$epoch, last_result:$result, attempt_hash:$attempted}' \
        <<< "$base" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$f"
  else
    rm -f "$tmp"
  fi
  return 0
}

# ── C7: one lock per unit ───────────────────────────────────────────────────

_BACKUP_DEST_LOCK_OPEN=0

# backup_dest_lock UNIT: opens descriptor 9 on <hb>/.backup-<unit>.lock and takes it
# with `flock -n 9`. rc 1 when another run holds it; rc 0 without a lock when the
# host has no flock (the Mac; the image has it).
backup_dest_lock() {
  local unit="$1" hb
  command -v flock > /dev/null 2>&1 || return 0
  hb=$(_backup_dest_hb_dir)
  mkdir -p "$hb" 2>/dev/null || return 0
  exec 9> "$hb/.backup-$unit.lock" || return 0
  _BACKUP_DEST_LOCK_OPEN=1
  if ! flock -n 9; then
    exec 9>&-
    _BACKUP_DEST_LOCK_OPEN=0
    return 1
  fi
  return 0
}

# backup_dest_unlock: releases the lock explicitly. Without the explicit release, a
# straggler child (BusyBox timeout's watchdog) keeps the open file description and
# the lock for about one more second (lesson of 044).
backup_dest_unlock() {
  [ "$_BACKUP_DEST_LOCK_OPEN" = "1" ] || return 0
  flock -u 9 2> /dev/null || true
  exec 9>&-
  _BACKUP_DEST_LOCK_OPEN=0
  return 0
}
