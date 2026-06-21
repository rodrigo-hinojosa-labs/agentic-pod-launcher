#!/usr/bin/env bash
# Fork helpers — GitHub template visibility probe + the public-fork conflict
# resolution (Story B, 003-bootstrap-hardening). Sourced unconditionally by
# setup.sh (before the gum/plain wizard split) so the logic is available in both
# prompt backends; also sourced directly by tests. No side effects at load.

# gh_get_repo_visibility TEMPLATE_URL [TOKEN]
# Prints "public" | "private" on success; returns non-zero (no output) on any
# probe failure (bad URL, gh missing, network, private repo without access).
gh_get_repo_visibility() {
  local url="$1" token="${2:-}"
  command -v gh >/dev/null 2>&1 || return 1
  local slug
  slug=$(printf '%s' "$url" | sed -E 's#^[a-z]+://[^/]+/##; s#\.git$##; s#/+$##')
  case "$slug" in
    */*) : ;;            # looks like owner/repo
    *)   return 1 ;;
  esac
  local vis
  vis=$(GH_TOKEN="$token" gh api "repos/$slug" --jq '.visibility' 2>/dev/null) || return 1
  [ -n "$vis" ] && [ "$vis" != "null" ] || return 1
  printf '%s' "$vis"
}

# _fork_is_noninteractive — true when stdin has no controlling TTY, or when
# FORK_NONINTERACTIVE forces it. Lets the piped/agentic flow avoid an ask_choice
# that would desync the stdin stream.
_fork_is_noninteractive() {
  case "${FORK_NONINTERACTIVE:-auto}" in
    1) return 0 ;;
    0) return 1 ;;
    *) [ ! -t 0 ] ;;
  esac
}

# fork_resolve_visibility TEMPLATE_URL ENABLED PRIVATE [TOKEN]
# Resolves the "private fork of a public template" conflict. Prints the resolved
# decision to stdout as "<enabled> <private>"; warnings/notice go to stderr.
#   - fork disabled, or private not requested → echo inputs unchanged (no probe).
#   - private template → fork can be private → echo unchanged.
#   - public template + private requested → CONFLICT:
#       interactive     → warn + ask_choice (proceed-public | disable-fork).
#       non-interactive → disable-fork + a logged notice (FR-B4), unless
#                         FORK_ACCEPT_PUBLIC=1 (then proceed public).
#   - probe failure → return 1 (caller MUST fail loud; never silently proceed).
fork_resolve_visibility() {
  local url="$1" enabled="$2" private="$3" token="${4:-}"

  if [ "$enabled" != "true" ] || [ "$private" != "true" ]; then
    printf '%s %s' "$enabled" "$private"
    return 0
  fi

  local vis
  vis=$(gh_get_repo_visibility "$url" "$token") || return 1
  if [ "$vis" != "public" ]; then
    printf '%s %s' "$enabled" "$private"   # private template → no conflict
    return 0
  fi

  # Conflict: a fork of a public repo will be PUBLIC.
  {
    echo "  ⚠  A fork of a public repository CANNOT be private on GitHub."
    echo "     You asked for a private fork of ${url}, but the fork would be PUBLIC."
  } >&2

  if _fork_is_noninteractive; then
    if [ "${FORK_ACCEPT_PUBLIC:-0}" = "1" ]; then
      echo "     FORK_ACCEPT_PUBLIC=1 — creating the fork PUBLIC as requested." >&2
      printf 'true false'
    else
      echo "     Non-interactive run — disabling the fork to avoid exposing data." >&2
      echo "     (set FORK_ACCEPT_PUBLIC=1 to create it public anyway.)" >&2
      printf 'false false'
    fi
    return 0
  fi

  local choice
  choice=$(ask_choice "How do you want to proceed?" "disable-fork" "proceed-public disable-fork")
  if [ "$choice" = "proceed-public" ]; then
    printf 'true false'
  else
    echo "     Fork disabled." >&2
    printf 'false false'
  fi
}
