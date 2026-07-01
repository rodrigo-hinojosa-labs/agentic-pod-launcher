# shellcheck shell=bash
# Library: local-mode .claude.json onboarding pre-seed + workspace trust-merge.
#
# Sourced by BOTH the rendered scripts/local/agent-login.sh (runtime) and
# tests/local-trust-merge.bats. Pure functions — sourcing has NO side effects
# (Principle III). Requires: jq.
#
# Why these steps, in this order, around the OAuth login:
#   1. local_seed_onboarding BEFORE login — without hasCompletedOnboarding the
#      first non-TTY claude invocation re-enters onboarding. Never clobber an
#      existing value.
#   2. local_merge_trust AFTER login — the login rewrites .claude.json and
#      resets per-project trust; without hasTrustDialogAccepted, `claude
#      remote-control` exits 1 ("Workspace not trusted") and the unit
#      restart-loops (gotcha #2). The merge preserves every other key and is
#      idempotent by EXACT equality, never substring (gotcha #4).
#   3. local_seed_remote_control AFTER login — the login also resets
#      remoteDialogSeen; without it `claude remote-control` blocks on an
#      interactive "Enable Remote Control? (y/n)" prompt under systemd (no TTY),
#      so the session never becomes controllable (gotcha #7). Never clobber.

# local_seed_onboarding FILE
#   Ensure hasCompletedOnboarding=true exists in FILE, WITHOUT overwriting an
#   existing value (true OR false). Creates FILE as {} when absent. Idempotent.
local_seed_onboarding() {
  local file="${1:?local_seed_onboarding: need .claude.json path}"
  [ -f "$file" ] || printf '{}\n' > "$file"
  # Present (any value) → leave untouched.
  if jq -e 'has("hasCompletedOnboarding")' "$file" >/dev/null 2>&1; then
    return 0
  fi
  local tmp
  tmp=$(mktemp) || return 1
  if jq '. + {hasCompletedOnboarding: true}' "$file" > "$tmp"; then
    mv "$tmp" "$file"
  else
    rm -f "$tmp"
    return 1
  fi
}

# local_seed_remote_control FILE
#   Ensure remoteDialogSeen=true exists in FILE, WITHOUT overwriting an existing
#   value (true OR false). Creates FILE as {} when absent. Idempotent.
#
#   Without this, `claude remote-control` prints an interactive
#   "Enable Remote Control? (y/n)" prompt on first run. Under systemd there is no
#   TTY to answer it, so the process blocks forever, never registers as
#   controllable, and the session shows offline in the app (validated on
#   mclaren). Seeding the flag the login already persists on a manual "y" makes
#   the unit come up controllable from the very first boot.
local_seed_remote_control() {
  local file="${1:?local_seed_remote_control: need .claude.json path}"
  [ -f "$file" ] || printf '{}\n' > "$file"
  # Present (any value) → leave untouched.
  if jq -e 'has("remoteDialogSeen")' "$file" >/dev/null 2>&1; then
    return 0
  fi
  local tmp
  tmp=$(mktemp) || return 1
  if jq '. + {remoteDialogSeen: true}' "$file" > "$tmp"; then
    mv "$tmp" "$file"
  else
    rm -f "$tmp"
    return 1
  fi
}

# local_merge_trust FILE WORKSPACE
#   Set projects["<WORKSPACE>"].hasTrustDialogAccepted=true, preserving every
#   other key and project. Creates the structure as needed. Idempotent: if the
#   merged JSON equals the current file (exact deep equality), FILE is left
#   byte-untouched (no rewrite) so re-running is a true no-op.
local_merge_trust() {
  local file="${1:?local_merge_trust: need .claude.json path}"
  local ws="${2:?local_merge_trust: need workspace path}"
  [ -f "$file" ] || printf '{}\n' > "$file"
  local tmp
  tmp=$(mktemp) || return 1
  if ! jq --arg ws "$ws" '
        .projects = (.projects // {})
        | .projects[$ws] = ((.projects[$ws] // {}) + {hasTrustDialogAccepted: true})
      ' "$file" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  # Exact deep-equality idempotency (NOT substring — gotcha #4): only replace
  # when the content actually changed.
  if jq -en --slurpfile a "$tmp" --slurpfile b "$file" '($a[0]) == ($b[0])' >/dev/null 2>&1; then
    rm -f "$tmp"
    return 0
  fi
  mv "$tmp" "$file"
}
