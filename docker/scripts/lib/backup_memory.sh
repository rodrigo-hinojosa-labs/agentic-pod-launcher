# shellcheck shell=bash
# Library (046): the memory backup unit (backup/memory), repo path only.
#
# Contract: specs/046-agent-backup-repo/contracts/backup-units.md (U1, U5) and
# data-model.md (section 5). Sourced by heartbeatctl and the tests; no side effects
# at load time. This unit keeps its own branch, clone cache, hash, staging and commit
# (constitution, Principle V). It runs only with an associated repository: a fork
# never receives it.
#
# Sources:
#   <state>/.claude/projects/<project>/memory/**  -> auto-memory/<project>/...
#   <state>/.claude-mem/** (minus volatile files)  -> claude-mem/...      (always store/)
#   <workspace>/<each backup.extra_paths entry>    -> extra/<entry>/...   (always store/)
# The auto memory travels in plaintext in an unmarked agent and in store/ in a
# sensitive one.

# git for this unit (C2). fetch and push use the long cap (C6): after a restore the
# whole store comes down.
_memory_repo_git() {
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

memory_cache_base() {
  printf '%s\n' "${MEMORY_BACKUP_CACHE_DIR:-/home/agent/.cache/agent-backup}"
}

# memory_extra_path_reserved PATH: rc 0 when PATH (normalized, relative to the
# workspace) is one the launcher owns, renders or keeps elsewhere: an extra path never
# backs it up and a restore never writes it. The single source of that list for the
# memory unit and for setup.sh restore_from_fork (constitution 1.1.0, E-rules).
memory_extra_path_reserved() {
  case "$1" in
    ''|.|.state|.state/.cache|.state/.cache/*|agent-repo|agent-repo/*|.restore-tmp|.restore-tmp/*) return 0 ;;
    setup.sh|VERSION|agent.yml|agent.yml.prev|CLAUDE.md|NEXT_STEPS.md|.mcp.json|.gitignore) return 0 ;;
    docker-compose.yml|docker-compose.override.yml|.env|.env.*) return 0 ;;
    scripts|scripts/*|docker|docker/*|modules|modules/*|tests|tests/*|personas|personas/*|.github|.github/*) return 0 ;;
  esac
  return 1
}

# memory_extra_path_check WORKSPACE RAW -> stdout: the normalized entry; rc 1 with
# the reason on stdout (not relative | not allowed | outside the workspace | missing).
# The rule of backup.extra_paths (data-model.md, section 1), plus the resolution.
memory_extra_path_check() {
  local ws="$1" p="$2" seg real wreal
  while :; do
    case "$p" in
      ./*) p="${p#./}" ;;
      */) p="${p%/}" ;;
      *) break ;;
    esac
  done
  case "$p" in
    /*) printf 'not relative\n'; return 1 ;;
  esac
  local rest="$p/"
  while [ -n "$rest" ]; do
    seg="${rest%%/*}"
    rest="${rest#*/}"
    if [ "$seg" = ".." ]; then printf 'not relative\n'; return 1; fi
    if [ "$seg" = ".git" ]; then printf 'not allowed\n'; return 1; fi
  done
  if memory_extra_path_reserved "$p"; then
    printf 'not allowed\n'
    return 1
  fi
  if [ ! -e "$ws/$p" ] && [ ! -L "$ws/$p" ]; then
    printf 'missing\n'
    return 1
  fi
  wreal=$(cd "$ws" 2> /dev/null && pwd -P) || { printf 'missing\n'; return 1; }
  if [ -L "$ws/$p" ]; then
    real=$(cd "$(dirname "$ws/$p")" 2> /dev/null && cd "$(dirname "$(readlink "$ws/$p")")" 2> /dev/null && pwd -P) || real=""
    case "$real/" in
      "$wreal"/*) printf 'not allowed\n' ;;
      *) printf 'outside the workspace\n' ;;
    esac
    return 1
  fi
  if [ -d "$ws/$p" ]; then
    real=$(cd "$ws/$p" 2> /dev/null && pwd -P) || real=""
  else
    real=$(cd "$(dirname "$ws/$p")" 2> /dev/null && pwd -P) || real=""
  fi
  case "$real/" in
    "$wreal"/*) ;;
    *) printf 'outside the workspace\n'; return 1 ;;
  esac
  printf '%s\n' "$p"
}

# _memory_find_files ROOT [claude-mem]: every regular file under ROOT, NUL-separated,
# without following symlinks and without .git directories, and never the login file
# that /login leaves (it travels in no backup). With claude-mem, the volatile files of
# data-model.md section 5 are left out too.
_memory_find_files() {
  local root="$1" kind="${2:-}"
  [ -d "$root" ] || { [ -f "$root" ] && printf '%s\0' "$root"; return 0; }
  if [ "$kind" = "claude-mem" ]; then
    find "$root" \( -name .git -o -path "$root/logs" -o -path "$root/backups" -o -path "$root/run" \) -prune -o \
      -type f ! -name '*.pid' ! -name 'telemetry*.json' ! -name '*heartbeat*.json' \
      ! -name '*health*.json' ! -name 'supervisor.json' ! -name '*-wal' ! -name '*-shm' \
      ! -name '*-journal' ! -name '.credentials.json' -print0 2> /dev/null
  else
    find "$root" -name .git -prune -o -type f ! -name '*-wal' ! -name '*-shm' ! -name '*-journal' \
      ! -name '.credentials.json' -print0 2> /dev/null
  fi
}

# memory_build_maps STATE_DIR WORKSPACE SENSITIVE EXTRA_LIST PLAIN_MAP STORE_MAP ALL_MAP
# Writes the three NUL-separated maps (logical, source). EXTRA_LIST is a file with
# one backup.extra_paths entry per line. Prints one line per skipped extra path.
memory_build_maps() {
  local state="$1" ws="$2" sensitive="$3" extra_list="$4" plain="$5" store="$6" all="$7"
  : > "$plain"; : > "$store"; : > "$all"
  local proj f rel target
  if [ -d "$state/.claude/projects" ]; then
    for proj in "$state/.claude/projects"/*/; do
      [ -d "${proj}memory" ] || continue
      proj="${proj%/}"
      while IFS= read -r -d '' f; do
        rel="auto-memory/${proj##*/}/${f#"$proj"/memory/}"
        if [ "$sensitive" = "true" ]; then target="$store"; else target="$plain"; fi
        printf '%s\0%s\0' "$rel" "$f" >> "$target"
        printf '%s\0%s\0' "$rel" "$f" >> "$all"
      done < <(_memory_find_files "$proj/memory" | LC_ALL=C sort -z)
    done
  fi
  if [ -d "$state/.claude-mem" ]; then
    while IFS= read -r -d '' f; do
      rel="claude-mem/${f#"$state"/.claude-mem/}"
      printf '%s\0%s\0' "$rel" "$f" >> "$store"
      printf '%s\0%s\0' "$rel" "$f" >> "$all"
    done < <(_memory_find_files "$state/.claude-mem" claude-mem | LC_ALL=C sort -z)
  fi
  local raw norm
  if [ -s "$extra_list" ]; then
    while IFS= read -r raw || [ -n "$raw" ]; do
      if ! norm=$(memory_extra_path_check "$ws" "$raw"); then
        printf "backup-memory: skipping extra path '%s' (%s)\n" "$raw" "$norm"
        continue
      fi
      while IFS= read -r -d '' f; do
        rel="extra/${f#"$ws"/}"
        printf '%s\0%s\0' "$rel" "$f" >> "$store"
        printf '%s\0%s\0' "$rel" "$f" >> "$all"
      done < <(_memory_find_files "$ws/$norm" | LC_ALL=C sort -z)
    done < "$extra_list"
  fi
  return 0
}

# memory_repo_prepare URL REMOTE_HEAD -> stdout: the cache dir. store/ survives the
# wipe of the tree (block reuse).
memory_repo_prepare() {
  local url="$1" remote_head="$2"
  local base dir
  base=$(memory_cache_base)
  dir="$base/memory-repo"
  mkdir -p "$base" || return 2
  if [ -z "$remote_head" ] || [ ! -d "$dir/.git" ]; then
    rm -rf "$dir"
    mkdir -p "$dir" || return 2
    _memory_repo_git -C "$dir" init -q > /dev/null 2>&1 || return 2
    _memory_repo_git -C "$dir" symbolic-ref HEAD refs/heads/backup/memory || return 2
    _memory_repo_git -C "$dir" remote add origin "$url" || return 2
  else
    _memory_repo_git -C "$dir" remote set-url origin "$url" > /dev/null 2>&1 \
      || _memory_repo_git -C "$dir" remote add origin "$url" > /dev/null 2>&1 || return 2
  fi
  if [ -n "$remote_head" ]; then
    _memory_repo_git -C "$dir" fetch -q --depth 1 origin \
      "+refs/heads/backup/memory:refs/remotes/origin/backup/memory" > /dev/null 2>&1 || return 2
    _memory_repo_git -C "$dir" checkout -q -f -B backup/memory \
      refs/remotes/origin/backup/memory > /dev/null 2>&1 || return 2
  fi
  find "$dir" -mindepth 1 -maxdepth 1 ! -name .git ! -name store -exec rm -rf {} + 2> /dev/null
  printf '%s\n' "$dir"
}

# memory_repo_stage_plain DIR PLAIN_MAP: copies the plaintext part into the tree.
memory_repo_stage_plain() {
  local dir="$1" map="$2" rel src
  while IFS= read -r -d '' rel && IFS= read -r -d '' src; do
    [ -f "$src" ] || continue
    mkdir -p "$(dirname "$dir/$rel")" || return 3
    cp -p "$src" "$dir/$rel" || return 3
  done < "$map"
  return 0
}

# memory_repo_commit_and_push DIR AGENT -> "<sha>" or "-"; rc 2 push failed, 3 error.
memory_repo_commit_and_push() {
  local dir="$1" agent="$2" sha
  backup_dest_mark_json "$agent" memory > "$dir/.agentic-pod-backup.json" || return 3
  _memory_repo_git -C "$dir" add -A > /dev/null 2>&1 || return 3
  if _memory_repo_git -C "$dir" rev-parse --verify -q HEAD > /dev/null 2>&1 \
     && _memory_repo_git -C "$dir" diff --cached --quiet > /dev/null 2>&1; then
    printf -- '-\n'
    return 0
  fi
  _memory_repo_git -C "$dir" -c user.email=memory-backup@localhost -c user.name=memory-backup \
    commit -q -m "memory snapshot $(date -u +%Y-%m-%dT%H:%M:%SZ)" > /dev/null 2>&1 || return 3
  _memory_repo_git -C "$dir" push -q origin HEAD:refs/heads/backup/memory > /dev/null 2>&1 || return 2
  sha=$(_memory_repo_git -C "$dir" rev-parse HEAD 2> /dev/null) || return 3
  printf '%s\n' "$sha"
}

# memory_repo_write_state FILE HASH COMMIT PUSH STORE_RECIPIENT: merges the unit
# fields, keeping the record of the last attempt. Atomic.
memory_repo_write_state() {
  local f="$1" hash="$2" commit="$3" push="$4" recip="$5" dir tmp base='{}'
  dir=$(dirname "$f")
  mkdir -p "$dir"
  if [ -s "$f" ] && jq -e 'type == "object"' "$f" > /dev/null 2>&1; then
    base=$(cat "$f")
  fi
  tmp=$(mktemp "$dir/.memory-backup.json.XXXXXX")
  if jq --arg hash "$hash" --arg commit "$commit" --arg push "$push" --arg recip "$recip" \
        '. + {hash:$hash, last_commit:$commit, last_push:$push, store_recipient:$recip}' \
        <<< "$base" > "$tmp"; then
    mv -f "$tmp" "$f"
  else
    rm -f "$tmp"
  fi
}
