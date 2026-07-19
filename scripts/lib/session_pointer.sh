# shellcheck shell=bash
# Library: locate and retire Claude Code's Remote Control session pointer, and
# record/read why the previous agent process stopped (022 local session
# lifecycle). Pure function definitions only — no side effects at source time.
#
# WHY THIS EXISTS. With `--spawn=session` the agent process exits *when its
# session ends*, `Restart=always` revives it, and the new process finds a
# pointer whose writer is dead. Claude Code treats a dead writer as "reuse the
# environment AND the sessionId" — so it re-announces a session the relay has
# already closed and the agent is unreachable, with every health signal green.
# One bad reuse contaminates every later start until the file is gone or the
# vendor's 4h mtime TTL expires.
#
# The discriminator the pointer lacks is *why* the previous process stopped,
# and systemd knows it. Exited on its own => the session ended => retire the
# pointer. Killed => restart/reboot/stop => the session may still be live
# server-side and the vendor's reuse restores the same client link (measured
# twice on live hardware, 2026-07-18) => leave it alone.
#
# The pointer and the marker are UNTRUSTED input: nothing here may execute
# file content — no `.`, no eval, no command substitution over file text. 021
# set this precedent when --restore-from-fork began decrypting a remote
# `.env.age` into the workspace (scripts/lib/env_file.sh:5-10).
#
# Contract: specs/022-local-session-lifecycle/contracts/session-pointer-hygiene.md
# Bash 3.2 compatible (the host test suite runs on macOS's stock bash).

# ── Pointer location ────────────────────────────────────────────────────────

# session_pointer_slug WORKSPACE_ABS → the naive project slug.
# The vendor's FS() replaces EVERY non-alphanumeric with '-', not just '/'.
# Above 200 chars it truncates and appends a proprietary base-36 hash we cannot
# reproduce; session_pointer_path's glob fallback covers that case instead.
#
# Feed the input with `printf '%s'`, never `echo`: `tr -c` complements the set,
# so a trailing newline would itself become an extra '-'.
session_pointer_slug() {
  printf '%s' "$1" | tr -c 'a-zA-Z0-9' '-'
  printf '\n'
}

# session_pointer_path WORKSPACE_ABS CLAUDE_CONFIG_DIR → the pointer path.
#   rc 0 = determined, path on stdout
#   rc 1 = CANNOT DETERMINE (warn, and let the caller favour availability)
#   rc 2 = the location is valid but no pointer exists (healthy: no session yet)
#
# The rc 1 vs rc 2 split is load-bearing: rc 2 is a fresh agent that must never
# be reported broken; rc 1 is an unknown that must never be silently green.
session_pointer_path() {
  local ws="$1" cfg="$2" slug dir cand count first

  # Step 1 MUST come first. If it came last it would be unreachable: an unset or
  # bogus config dir makes the step-3 glob match zero and return 2 ("healthy, no
  # session"), the exact false green FR-006 forbids.
  [ -n "$cfg" ] || return 1
  [ -d "$cfg" ] || return 1
  # A VALID config dir whose projects/ has not been created yet is a different
  # thing entirely: Claude Code only creates it once a session runs, so a
  # freshly logged-in agent legitimately has none. Reporting that as "cannot
  # determine" made the doctor warn on every healthy fresh workspace — a false
  # alarm caught by the 021 regression tests, and precisely what FR-006 forbids.
  [ -d "$cfg/projects" ] || return 2
  ls "$cfg/projects" >/dev/null 2>&1 || return 1

  slug=$(session_pointer_slug "$ws")
  dir="$cfg/projects/$slug"
  if [ -d "$dir" ]; then
    if [ -f "$dir/bridge-pointer.json" ]; then
      printf '%s\n' "$dir/bridge-pointer.json"
      return 0
    fi
    return 2
  fi

  # Step 3: the slug directory is absent — including every workspace path over
  # 200 chars. Act only on an unambiguous single candidate; never guess.
  count=0
  first=""
  for cand in "$cfg"/projects/*/bridge-pointer.json; do
    [ -f "$cand" ] || continue
    count=$((count + 1))
    [ -n "$first" ] || first="$cand"
  done
  if [ "$count" -eq 1 ]; then
    printf '%s\n' "$first"
    return 0
  fi
  [ "$count" -eq 0 ] && return 2
  return 1
}

# session_pointer_retire POINTER_PATH → rc 0 renamed, rc 1 could not.
#
# The ONLY mutation of vendor state in this feature, and it is a rename, never
# a write. Claude Code exits with a split-brain error if it re-reads a pointer
# carrying a pid that is not its own, so nothing here may ever create one.
# A fixed retired name keeps the artifact bounded and forensically useful.
session_pointer_retire() {
  local p="$1" d
  [ -f "$p" ] || return 1
  d=$(dirname "$p")
  mv -f "$p" "$d/bridge-pointer.retired.json" 2>/dev/null || return 1
  return 0
}

# ── Exit marker ─────────────────────────────────────────────────────────────

# session_exit_marker_path WORKSPACE → the marker path.
# Lives beside the other local-mode state (qmd-index.json, wiki-graph.json,
# *-backup.json). Deliberately NOT under .state/: backup_identity.sh:72,152-157
# encrypts paths there and would start pushing this to the agent's fork.
session_exit_marker_path() {
  printf '%s\n' "$1/scripts/heartbeat/session-exit.json"
}

# Minimal JSON string escaping: backslash and double quote. The values stored
# are short systemd tokens; nothing else needs escaping on one line.
_session_json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# session_exit_marker_write WORKSPACE RESULT EXIT_CODE EXIT_STATUS
# Always rc 0, even when it cannot write — this runs from ExecStopPost and may
# never turn a shutdown into a failure (Principle IV).
#
# Written with printf, not jq: jq can be absent on the agent host and this path
# must not depend on it. The three systemd values are stored verbatim, never
# interpreted; interpretation belongs to session_decide.
session_exit_marker_write() {
  local ws="$1" result="$2" code="$3" status="$4" f d tmp ts
  f=$(session_exit_marker_path "$ws")
  d=$(dirname "$f")
  [ -d "$d" ] || return 0
  [ -w "$d" ] || return 0
  tmp="${d}/.session-exit.json.tmp.$$"
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || ts=""
  printf '{"schema":1,"service_result":"%s","exit_code":"%s","exit_status":"%s","ts":"%s"}\n' \
    "$(_session_json_escape "$result")" \
    "$(_session_json_escape "$code")" \
    "$(_session_json_escape "$status")" \
    "$ts" > "$tmp" 2>/dev/null || {
    rm -f "$tmp" 2>/dev/null
    return 0
  }
  mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  return 0
}

# Extract the exit_code field without executing anything.
_session_marker_field() {
  sed -n 's/.*"exit_code"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1" 2>/dev/null | head -1
}

# _session_marker_has_field FILE → rc 0 when the key is present and complete.
# A truncated or unrecognized shape must read as "cannot determine", never as
# an empty-but-valid value, and never as a crash.
_session_marker_has_field() {
  grep -q '"exit_code"[[:space:]]*:[[:space:]]*"' "$1" 2>/dev/null
}

# session_exit_marker_read WORKSPACE → exit_code on stdout.
#   rc 0 = read; rc 1 = absent, unreadable, or unparseable. Does NOT consume.
session_exit_marker_read() {
  local f
  f=$(session_exit_marker_path "$1")
  [ -f "$f" ] || return 1
  _session_marker_has_field "$f" || return 1
  printf '%s\n' "$(_session_marker_field "$f")"
  return 0
}

# session_exit_marker_consume WORKSPACE → exit_code on stdout, and removes it.
#   rc 0 = there was a usable marker; rc 1 = there was not.
#
# Consuming with `mv` rather than read-then-remove is what makes two concurrent
# starts safe: only one wins the rename. The loser sees "no marker" and falls
# through to "cannot determine", which favours availability (FR-014). The net
# result of the race is never corrupt state.
session_exit_marker_consume() {
  local ws="$1" f d tmp val rc
  f=$(session_exit_marker_path "$ws")
  [ -f "$f" ] || return 1
  d=$(dirname "$f")
  tmp="${d}/.session-exit.consumed.$$"
  mv "$f" "$tmp" 2>/dev/null || return 1
  rc=0
  _session_marker_has_field "$tmp" || rc=1
  val=$(_session_marker_field "$tmp")
  rm -f "$tmp" 2>/dev/null
  [ "$rc" -eq 0 ] && printf '%s\n' "$val"
  return "$rc"
}

# ── The decision ────────────────────────────────────────────────────────────

# session_decide MARKER_VALUE POINTER_STATE → retire | keep | noop
# Pure: touches no filesystem. This is the testable heart of the feature.
#
#   any      + absent   → noop    the agent has not announced a session yet
#   exited   + present  → retire  the process left on its own ⇒ the session ended
#   killed   + present  → keep    systemd killed it ⇒ the session may be alive
#   dumped   + present  → retire  died abnormally on its own ⇒ not demonstrably alive
#   ""/other + present  → retire  cannot determine ⇒ availability over continuity
#   any      + unknown  → noop    we do not know WHICH file we would touch
#
# The asymmetry between the two "cannot determine" rows is deliberate and must
# be preserved: not knowing WHY it died costs a new client link; not knowing
# WHICH file costs corrupting another workspace's state.
#
# `killed` is a single-value allowlist on purpose. Any future systemd value we
# have not reasoned about lands in the retire branch, which is the safe side.
session_decide() {
  local marker="$1" state="$2"
  if [ "$state" != "present" ]; then
    printf 'noop\n'
    return 0
  fi
  if [ "$marker" = "killed" ]; then
    printf 'keep\n'
  else
    printf 'retire\n'
  fi
  return 0
}
