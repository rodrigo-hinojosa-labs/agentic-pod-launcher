# shellcheck shell=bash
# Library: the workspace CLAUDE.md against the template that rendered it (038).
# Pure function definitions only - no side effects at source time, no yq, nothing
# that writes. It is sourced by `setup.sh` (the --regenerate decision), by the rendered
# SessionStart hook (scripts/hooks/upgrade-notice.sh) and by `agentctl doctor`, so it
# must run with nothing but cmp/test on PATH.
#
# Three files, always compared with `cmp -s` (never mtime, never a hash - sha256sum vs
# shasum would differ between Linux and macOS, and the baseline doubles as the base of
# the diff the agent needs):
#   C  <ws>/CLAUDE.md                                what Claude Code loads
#   U  <ws>/.state/launcher/claude-md.upstream.md    the render of TODAY's template
#   B  <ws>/.state/launcher/claude-md.baseline.md    the render that C incorporates
#
# Both functions ALWAYS exit 0 and print exactly one token (plus a newline), so a
# caller under `set -e` can use `$(...)` without a guard. Contract:
# specs/038-schema-delta-boot-nudge/contracts/claude-md-refresh.md
# Bash 3.2 compatible (the host test suite runs on macOS's stock bash).

# claude_md_state C U B
#   unknown              no readable upstream render (a pre-038 workspace that has not
#                        run --regenerate yet): nothing can be compared, say nothing
#   in_sync              C is byte-identical to U
#   customized           C differs from U and B equals U: the differences are the
#                        operator's own edits, and the template has not moved since
#   pending_template     C differs from U and B is an OLDER render: the template moved
#                        since the last render C incorporates; `diff B U` is exactly
#                        what changed
#   pending_no_baseline  C differs from U and there is no B (every agent today), or C
#                        does not exist: provenance unknown, so the conservative answer
claude_md_state() {
  local c="${1:-}" u="${2:-}" b="${3:-}"
  if [ -z "$u" ] || [ ! -f "$u" ] || [ ! -r "$u" ]; then
    printf '%s\n' unknown
    return 0
  fi
  if [ -z "$c" ] || [ ! -f "$c" ]; then
    printf '%s\n' pending_no_baseline
    return 0
  fi
  if cmp -s "$c" "$u"; then
    printf '%s\n' in_sync
  elif [ -n "$b" ] && [ -f "$b" ]; then
    if cmp -s "$b" "$u"; then
      printf '%s\n' customized
    else
      printf '%s\n' pending_template
    fi
  else
    printf '%s\n' pending_no_baseline
  fi
  return 0
}

# claude_md_regenerate_decision C U B FORCE LAUNCHER_OWN
# FORCE and LAUNCHER_OWN are the literal strings true/false, already resolved by the
# caller (FORCE = the operator CONFIRMED --force-claude-md; LAUNCHER_OWN = local mode and
# C is the launcher's own dev doc, 027). Anything other than `true` counts as false.
# First rule that applies:
#   render    C does not exist, or FORCE, or LAUNCHER_OWN
#   preserve  there is no readable U (the caller could not write the current render)
#   adopt     C equals U but B is absent or stale: only move the baseline forward
#   noop      C equals U and B equals U
#   refresh   C equals B (nobody edited it) and differs from U: rewrite it from U
#   preserve  anything else: C has edits of its own, never overwritten (FR-007)
claude_md_regenerate_decision() {
  local c="${1:-}" u="${2:-}" b="${3:-}" force="${4:-false}" own="${5:-false}"
  if [ ! -f "$c" ] || [ "$force" = "true" ] || [ "$own" = "true" ]; then
    printf '%s\n' render
    return 0
  fi
  if [ ! -f "$u" ] || [ ! -r "$u" ]; then
    printf '%s\n' preserve
    return 0
  fi
  if cmp -s "$c" "$u"; then
    if [ -f "$b" ] && cmp -s "$b" "$u"; then
      printf '%s\n' noop
    else
      printf '%s\n' adopt
    fi
    return 0
  fi
  if [ -f "$b" ] && cmp -s "$c" "$b"; then
    printf '%s\n' refresh
  else
    printf '%s\n' preserve
  fi
  return 0
}
