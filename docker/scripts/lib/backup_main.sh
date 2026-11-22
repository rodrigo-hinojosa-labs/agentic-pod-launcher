# shellcheck shell=bash
# Library (048): publishing a unit's already-staged tree into `.agent-backup/<unit>/`
# of the main branch of the agent's associated repository.
#
# Contract: specs/048-fleet-backup-main/contracts/main-backup.md (M2 steps 2, 3, 7,
# 8 and 9) and legacy-migration.md. Sourced by heartbeatctl and by the tests; no side
# effects at load time. Needs backup_dest.sh (askpass, capped runner).
#
# Shared code allowed by the constitution (Principle V, 1.2.0): it builds a commit
# over the tip of main from a tree that the unit itself staged and committed in its
# own cache, and it deletes a unit's legacy backup/<unit> branch after verifying.
# It never stages a unit's files and never hashes a unit's content.
#
# The publishing clone (<base>/<unit>-main) is a BARE partial clone of main with
# blob:none and depth 1: it only ever holds trees, the unit's own objects (through
# an alternate pointing at the unit's cache) and the one blob of each ownership
# mark it reads. Test seams: BACKUP_MAIN_ATTEMPTS, BACKUP_MAIN_RETRY_SLEEP,
# BACKUP_MAIN_VERIFY_FAIL and BACKUP_MAIN_DELETE_FAIL. Measured in 048 T002: building the commit with mktree --missing and
# pushing it triggers no lazy fetch of the other units' blobs.

_BACKUP_MAIN_REF="refs/remotes/origin/main"

# _backup_main_git DIR ARGS...: git on the publishing clone, with the repo
# credential, no global or system config, bounded by BACKUP_GIT_TIMEOUT_S.
_backup_main_git() {
  local dir="$1"
  shift
  local askpass="/bin/true"
  if command -v backup_dest_askpass > /dev/null 2>&1; then
    askpass=$(backup_dest_askpass repo)
  fi
  _backup_dest_capped "${_BACKUP_MAIN_SECS:-${BACKUP_GIT_TIMEOUT_S:-60}}" env GIT_TERMINAL_PROMPT=0 GIT_ASKPASS="$askpass" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 LC_ALL=C git -C "$dir" "$@"
}

# backup_main_prepare BASE UNIT URL UNIT_CACHE -> stdout: the publishing clone dir.
# Creates or repairs <BASE>/<UNIT>-main and points its alternate at UNIT_CACHE's
# objects, so the commits the unit made in its own cache are visible here.
backup_main_prepare() {
  local base="$1" unit="$2" url="$3" ucache="$4"
  local dir="$base/$unit-main"
  mkdir -p "$base" || return 2
  if [ ! -f "$dir/HEAD" ]; then
    rm -rf "$dir"
    mkdir -p "$dir" || return 2
    _backup_main_git "$dir" init -q --bare > /dev/null 2>&1 || return 2
  fi
  _backup_main_git "$dir" config remote.origin.url "$url" || return 2
  _backup_main_git "$dir" config remote.origin.promisor true || return 2
  _backup_main_git "$dir" config remote.origin.partialclonefilter blob:none || return 2
  _backup_main_git "$dir" config extensions.partialClone origin || return 2
  backup_main_link "$dir" "$ucache" || return 2
  printf '%s\n' "$dir"
}

# backup_main_link DIR UNIT_CACHE: points the publishing clone's alternate at the
# unit cache's objects (once that cache exists), so the unit's commits are visible.
backup_main_link() {
  local dir="$1" ucache="$2"
  mkdir -p "$dir/objects/info" || return 1
  if [ -d "$ucache/.git/objects" ]; then
    printf '%s\n' "$ucache/.git/objects" > "$dir/objects/info/alternates" || return 1
  fi
  return 0
}

# backup_main_fetch DIR -> stdout: the sha of the remote main tip; rc 2 on failure.
backup_main_fetch() {
  local dir="$1"
  _backup_main_git "$dir" fetch -q --depth 1 --filter=blob:none origin \
    "+refs/heads/main:$_BACKUP_MAIN_REF" > /dev/null 2>&1 || return 2
  _backup_main_git "$dir" rev-parse --verify -q "$_BACKUP_MAIN_REF" 2> /dev/null || return 2
}

# backup_main_tree DIR UNIT [REF] -> the tree id of .agent-backup/<unit> in REF
# (default: the fetched main), or nothing when it does not exist. Reads trees only.
backup_main_tree() {
  local dir="$1" unit="$2" ref="${3:-$_BACKUP_MAIN_REF}"
  _backup_main_git "$dir" rev-parse --verify -q "$ref:.agent-backup/$unit" 2> /dev/null || true
}

# backup_main_owner DIR UNIT AGENT -> new | ok | foreign | other-agent, for the
# directory .agent-backup/<unit> of the fetched main. Reads one blob (the mark).
backup_main_owner() {
  local dir="$1" unit="$2" agent="$3" mark a u
  if [ -z "$(backup_main_tree "$dir" "$unit")" ]; then
    printf 'new\n'
    return 0
  fi
  if ! _backup_main_git "$dir" rev-parse --verify -q \
         "$_BACKUP_MAIN_REF:.agent-backup/$unit/.agentic-pod-backup.json" > /dev/null 2>&1; then
    printf 'foreign\n'
    return 0
  fi
  # The path exists (a tree lookup, local): a failure now is the lazy fetch of its blob.
  if ! mark=$(_backup_main_git "$dir" cat-file blob \
                "$_BACKUP_MAIN_REF:.agent-backup/$unit/.agentic-pod-backup.json" 2> /dev/null); then
    printf 'unreachable\n'
    return 0
  fi
  a=$(jq -r '.agent // ""' <<< "$mark" 2> /dev/null) || a=""
  u=$(jq -r '.unit // ""' <<< "$mark" 2> /dev/null) || u=""
  if [ -z "$a" ] && [ -z "$u" ]; then
    printf 'foreign\n'
  elif [ "$a" = "$agent" ] && [ "$u" = "$unit" ]; then
    printf 'ok\n'
  else
    printf 'other-agent\n'
  fi
  return 0
}

# _backup_main_replace_entry TREE_LISTING NAME MODE TYPE OID -> the listing with the
# entry NAME replaced (or added, or removed when OID is empty), sorted by name.
_backup_main_replace_entry() {
  local listing="$1" name="$2" mode="$3" type="$4" oid="$5"
  {
    printf '%s' "$listing" | awk -F'\t' -v n="$name" 'NF && $2 != n'
    [ -n "$oid" ] && printf '%s %s %s\t%s\n' "$mode" "$type" "$oid" "$name"
  } | LC_ALL=C sort -t "$(printf '\t')" -k2,2
}

# backup_main_build_commit DIR UNIT AGENT UNIT_TREE [README_FILE] -> the new commit.
# Its tree is the fetched main tip with .agent-backup/<UNIT> replaced by UNIT_TREE
# (and .agent-backup/README.md by README_FILE's content, for the config unit). Its
# parent is the fetched tip. Nothing outside those entries changes, and no blob
# outside them is read: the trees are rebuilt with ls-tree and mktree --missing.
backup_main_build_commit() {
  local dir="$1" unit="$2" agent="$3" utree="$4" readme="${5:-}"
  local tip ab_listing ab root_listing root msg readme_blob=""
  tip=$(_backup_main_git "$dir" rev-parse --verify -q "$_BACKUP_MAIN_REF") || return 3
  # A failed ls-tree (a timeout, a corrupt object) must never look like an absent
  # .agent-backup: that would drop the other units' directories from main.
  # (`<rev>:<path>^{tree}` would read "^{tree}" as part of the path: ask the type.)
  if [ "$(_backup_main_git "$dir" cat-file -t "$tip:.agent-backup" 2> /dev/null)" = "tree" ]; then
    ab_listing=$(_backup_main_git "$dir" ls-tree "$tip:.agent-backup") || return 3
  else
    ab_listing=""
  fi
  ab_listing=$(_backup_main_replace_entry "$ab_listing" "$unit" 040000 tree "$utree")
  if [ -n "$readme" ]; then
    readme_blob=$(_backup_main_git "$dir" hash-object -w --stdin < "$readme") || return 3
    ab_listing=$(_backup_main_replace_entry "$ab_listing" README.md 100644 blob "$readme_blob")
  fi
  ab=$(printf '%s\n' "$ab_listing" | _backup_main_git "$dir" mktree --missing) || return 3
  root_listing=$(_backup_main_git "$dir" ls-tree "$tip") || return 3
  root_listing=$(_backup_main_replace_entry "$root_listing" .agent-backup 040000 tree "$ab")
  root=$(printf '%s\n' "$root_listing" | _backup_main_git "$dir" mktree --missing) || return 3
  msg=$(printf 'backup(%s): %s %s [skip ci]\n\nAgentic-Pod-Backup: %s/%s\n' \
          "$unit" "$agent" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$agent" "$unit")
  printf '%s\n' "$msg" | GIT_AUTHOR_NAME=agentic-pod-backup GIT_AUTHOR_EMAIL=backup@agentic-pod.invalid \
    GIT_COMMITTER_NAME=agentic-pod-backup GIT_COMMITTER_EMAIL=backup@agentic-pod.invalid \
    _backup_main_git "$dir" commit-tree "$root" -p "$tip" || return 3
}

# backup_main_push_secs UNIT -> the push limit of the unit (046: memory and history
# keep BACKUP_PUSH_TIMEOUT_S, 900 s; the others BACKUP_GIT_TIMEOUT_S, 60 s).
backup_main_push_secs() {
  case "${1:-}" in
    memory|history) printf '%s\n' "${BACKUP_PUSH_TIMEOUT_S:-900}" ;;
    *)              printf '%s\n' "${BACKUP_GIT_TIMEOUT_S:-60}" ;;
  esac
}

# backup_main_push DIR COMMIT [UNIT] -> rc 0 pushed, 3 not a fast-forward (main moved),
# 4 refused by a protection (GH006, GH013 or their wording), 2 any other failure.
# Never forces. The server's message goes to <dir>/push.err (never the credential).
backup_main_push() {
  local dir="$1" commit="$2" unit="${3:-}" err secs
  err="$dir/push.err"
  # The large units keep the push limit 046 gave them (BACKUP_PUSH_TIMEOUT_S, 900 s).
  secs=$(backup_main_push_secs "$unit")
  if _BACKUP_MAIN_SECS="$secs" _backup_main_git "$dir" push -q origin "$commit:refs/heads/main" > /dev/null 2> "$err"; then
    return 0
  fi
  if grep -qiE 'GH006|GH013|protected branch|Repository rule violations' "$err" 2> /dev/null; then
    return 4
  fi
  if grep -qiE 'non-fast-forward|fetch first|\[rejected\]|cannot lock ref|failed to update ref|incorrect old value provided|stale info' "$err" 2> /dev/null; then
    return 3
  fi
  return 2
}

# backup_main_publish DIR UNIT AGENT UNIT_TREE [README_FILE] -> stdout: the commit
# pushed. Rebuilds the commit on the new tip and retries up to BACKUP_MAIN_ATTEMPTS
# (5) times when main moved, waiting 1 to 5 s between attempts. rc 0 pushed, 3 main
# kept moving, 4 protected, 2 other failure.
backup_main_publish() {
  local dir="$1" unit="$2" agent="$3" utree="$4" readme="${5:-}"
  local attempts="${BACKUP_MAIN_ATTEMPTS:-5}" i=1 commit rc
  while :; do
    commit=$(backup_main_build_commit "$dir" "$unit" "$agent" "$utree" "$readme") || return 2
    rc=0
    backup_main_push "$dir" "$commit" "$unit" || rc=$?
    case "$rc" in
      0) printf '%s\n' "$commit"; return 0 ;;
      3) ;;
      *) return "$rc" ;;
    esac
    [ "$i" -ge "$attempts" ] && return 3
    i=$((i + 1))
    sleep "${BACKUP_MAIN_RETRY_SLEEP:-$(( (RANDOM % 5) + 1 ))}"
    backup_main_fetch "$dir" > /dev/null || return 2
  done
}

# backup_main_verify DIR UNIT UNIT_TREE: rc 0 when, after a fresh fetch, the remote
# main holds exactly UNIT_TREE at .agent-backup/<unit> (contract M2 step 9).
backup_main_verify() {
  local dir="$1" unit="$2" utree="$3"
  [ "${BACKUP_MAIN_VERIFY_FAIL:-0}" = "1" ] && return 1
  backup_main_fetch "$dir" > /dev/null || return 1
  [ "$(backup_main_tree "$dir" "$unit")" = "$utree" ]
}

# ── Contract L: the legacy backup/<unit> branch ─────────────────────────────

# backup_main_legacy_owner DIR UNIT AGENT -> ok | no-mark | other-agent | unreachable
# for the branch backup/<unit>: fetches its tip (trees only) and reads its mark.
backup_main_legacy_owner() {
  local dir="$1" unit="$2" agent="$3" ref="refs/remotes/origin/backup/$2" mark a u
  if ! _backup_main_git "$dir" fetch -q --depth 1 --filter=blob:none origin \
         "+refs/heads/backup/$unit:$ref" > /dev/null 2>&1; then
    printf 'unreachable\n'
    return 0
  fi
  if ! _backup_main_git "$dir" rev-parse --verify -q "$ref:.agentic-pod-backup.json" > /dev/null 2>&1; then
    printf 'no-mark\n'
    return 0
  fi
  if ! mark=$(_backup_main_git "$dir" cat-file blob "$ref:.agentic-pod-backup.json" 2> /dev/null); then
    printf 'unreachable\n'
    return 0
  fi
  a=$(jq -r '.agent // ""' <<< "$mark" 2> /dev/null) || a=""
  u=$(jq -r '.unit // ""' <<< "$mark" 2> /dev/null) || u=""
  if [ "$a" = "$agent" ] && [ "$u" = "$unit" ]; then
    printf 'ok\n'
  elif [ -z "$a" ] && [ -z "$u" ]; then
    printf 'no-mark\n'
  else
    printf 'other-agent\n'
  fi
  return 0
}

# backup_main_delete_branch DIR UNIT: deletes refs/heads/backup/<unit> on the remote,
# alone in its push. rc 0 deleted, 2 failed.
backup_main_delete_branch() {
  local dir="$1" unit="$2" tip
  [ "${BACKUP_MAIN_DELETE_FAIL:-0}" = "1" ] && return 2
  # With a lease on the tip whose mark was read: a branch that changed since is kept.
  tip=$(_backup_main_git "$dir" rev-parse --verify -q "refs/remotes/origin/backup/$unit" 2> /dev/null) || return 2
  _backup_main_git "$dir" push -q "--force-with-lease=refs/heads/backup/$unit:$tip" origin \
    ":refs/heads/backup/$unit" > /dev/null 2> "$dir/delete.err" || return 2
  _backup_main_git "$dir" update-ref -d "refs/remotes/origin/backup/$unit" > /dev/null 2>&1 || true
  return 0
}
