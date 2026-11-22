# shellcheck shell=bash
# Library (048): the pull-request path, when main of the agent's repository refuses a
# direct push because of a protection.
#
# Contract: specs/048-fleet-backup-main/contracts/pr-fallback.md (P1 to P3). Sourced
# by heartbeatctl and by the tests; no side effects at load time. Needs
# backup_main.sh (_backup_main_git).
#
# The token reaches curl only through a configuration file of mode 0600 (-K),
# created and removed inside the call: never in argv, a URL, a log or a state file.
# Test seam: BACKUP_GH_API_BASE (only https://api.github.com or
# http://127.0.0.1:<port>).

_backup_pr_api_base() {
  local base="${BACKUP_GH_API_BASE:-https://api.github.com}"
  case "$base" in
    https://api.github.com) ;;
    http://127.0.0.1:[0-9]*)
      case "${base#http://127.0.0.1:}" in *[!0-9]*|'') base="https://api.github.com" ;; esac ;;
    *) base="https://api.github.com" ;;
  esac
  printf '%s\n' "$base"
}

# _backup_pr_repo_path URL -> "<owner>/<name>" for a github.com URL, or the path of
# the URL without .git for any other host (the test server).
_backup_pr_repo_path() {
  local u="$1" rest
  rest="${u#*://}"
  rest="${rest#*/}"
  rest="${rest%.git}"
  rest="${rest%/}"
  printf '%s\n' "$rest"
}

# _backup_pr_call CFG METHOD URL [JSON] -> stdout: "<http code> <body>". rc 0 always.
_backup_pr_call() {
  local cfg="$1" method="$2" url="$3" data="${4:-}" out code
  out=$(mktemp "${TMPDIR:-/tmp}/backup-pr.XXXXXX") || { printf '000 \n'; return 0; }
  if [ -n "$data" ]; then
    code=$(printf '%s' "$data" | curl -sS -K "$cfg" --max-time 20 -X "$method" \
             -H 'Accept: application/vnd.github+json' -H 'Content-Type: application/json' \
             --data-binary @- -o "$out" -w '%{http_code}' "$url" 2> /dev/null) || code="000"
  else
    code=$(curl -sS -K "$cfg" --max-time 20 -X "$method" \
             -H 'Accept: application/vnd.github+json' \
             -o "$out" -w '%{http_code}' "$url" 2> /dev/null) || code="000"
  fi
  printf '%s %s\n' "${code:-000}" "$(tr -d '\n' < "$out" 2> /dev/null)"
  rm -f "$out"
  return 0
}

# backup_pr_merge DIR UNIT AGENT COMMIT URL -> rc 0 when the pull request with
# COMMIT was merged into main; rc 4 otherwise (closed, and its branch deleted).
backup_pr_merge() {
  local dir="$1" unit="$2" agent="$3" commit="$4" url="$5"
  local started branch base repo cfg resp code number subject rc=4
  # An unpredictable name, and the merge pinned to COMMIT (sha): a branch moved by
  # someone else between the push and the merge is refused by GitHub (409).
  branch="agent-backup-pr/$unit-$(date +%s)-$(od -An -N6 -tx1 /dev/urandom 2> /dev/null | tr -d ' \n')"
  # The branch carries the whole pack again (a protection refuses after receiving
  # it), so it keeps the unit's push limit; the API budget starts after it.
  _BACKUP_MAIN_SECS="$(backup_main_push_secs "$unit")" _backup_main_git "$dir" push -q origin \
    "$commit:refs/heads/$branch" > /dev/null 2>&1 || return 4
  started=$(date +%s)
  base=$(_backup_pr_api_base)
  repo=$(_backup_pr_repo_path "$url")
  cfg=$(mktemp "${TMPDIR:-/tmp}/backup-pr-cfg.XXXXXX") || { backup_pr_drop_branch "$dir" "$branch"; return 4; }
  chmod 600 "$cfg"
  printf 'header = "Authorization: Bearer %s"\n' "${GITHUB_PAT:-}" > "$cfg"
  subject=$(_backup_main_git "$dir" log -1 --format=%s "$commit" 2> /dev/null || printf 'backup(%s)' "$unit")
  resp=$(_backup_pr_call "$cfg" POST "$base/repos/$repo/pulls" \
           "$(jq -nc --arg t "$subject" --arg h "$branch" \
                --arg b "Automated backup of $agent/$unit by agentic-pod-launcher. It changes only .agent-backup/$unit/." \
                '{title:$t, head:$h, base:"main", body:$b}')")
  code="${resp%% *}"
  number=$(jq -r '.number // empty' <<< "${resp#* }" 2> /dev/null) || number=""
  if [ "$code" = "201" ] && [ -n "$number" ] && [ $(( $(date +%s) - started )) -lt 90 ]; then
    resp=$(_backup_pr_call "$cfg" PUT "$base/repos/$repo/pulls/$number/merge" \
             "$(jq -nc --arg sha "$commit" '{merge_method:"merge", sha:$sha}')")
    code="${resp%% *}"
    if [ "$code" = "200" ]; then
      rc=0
    else
      _backup_pr_call "$cfg" PATCH "$base/repos/$repo/pulls/$number" '{"state":"closed"}' > /dev/null
    fi
  fi
  rm -f "$cfg"
  backup_pr_drop_branch "$dir" "$branch"
  BACKUP_PR_LAST="${number:-} ${code:-000}"
  return "$rc"
}

# backup_pr_drop_branch DIR BRANCH: deletes the temporary branch (best effort).
backup_pr_drop_branch() {
  _backup_main_git "$1" push -q origin ":refs/heads/$2" > /dev/null 2>&1 || true
}
