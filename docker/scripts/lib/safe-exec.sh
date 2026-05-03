#!/bin/bash
# safe-exec.sh — primitives for running auxiliary subsystems without
# blocking the watchdog or hanging on interactive prompts.
#
# Image-baked at /opt/agent-admin/scripts/lib/safe-exec.sh. Sourced by
# start_services.sh and the per-subsystem health libs (token-health,
# mcp-health, future identity-backup). Tests source it directly.
#
# Pattern: only function definitions, no side effects at source time.
# Matches scripts/lib/vault.sh and docker/scripts/lib/state.sh.
#
# Why these four primitives, no more:
#   - safe_run_bg     non-blocking dispatch with timeout + dedup
#   - with_git_noninteractive   stop git from ever asking stdin for creds
#   - safe_curl       network call with bounded latency, never hangs
#   - log_aux_fail    structured record so doctor + status can surface it
#
# Anything an aux subsystem needs is composable from these. If a future
# feature wants exponential backoff or per-subsystem state, build it on
# top — don't add it here.

# ── Paths and tunables (overridable in tests) ─────────────────────────
# AUX_LOG: append-only JSONL of aux failures. Same directory and
# rotation policy as the heartbeat runs.jsonl so doctor/status can
# read both with the same primitives.
SAFE_EXEC_AUX_LOG="${SAFE_EXEC_AUX_LOG:-/workspace/scripts/heartbeat/logs/aux.jsonl}"
SAFE_EXEC_LOCK_DIR="${SAFE_EXEC_LOCK_DIR:-/tmp/safe-exec}"
SAFE_EXEC_AUX_LOG_THRESHOLD_BYTES="${SAFE_EXEC_AUX_LOG_THRESHOLD_BYTES:-10485760}"

# ── timeout binary detection ──────────────────────────────────────────
# Alpine + most Linux: `timeout` (coreutils or busybox). macOS: optional
# `gtimeout` via brew coreutils. Detection runs once per shell at first
# call so we don't pay a fork on every safe_run_bg.
_safe_exec_timeout_bin=""
_safe_exec_resolve_timeout() {
  if [ -n "$_safe_exec_timeout_bin" ]; then return 0; fi
  if command -v timeout >/dev/null 2>&1; then
    _safe_exec_timeout_bin="timeout"
  elif command -v gtimeout >/dev/null 2>&1; then
    _safe_exec_timeout_bin="gtimeout"
  fi
}

# _safe_exec_iso8601 → UTC ISO 8601 timestamp (matches runs.jsonl format).
_safe_exec_iso8601() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# log_aux_fail SUBSYSTEM REASON [RETRY_IN_SEC]
#
# Append a JSON line describing an auxiliary subsystem failure. Always
# returns 0 — failure to log is not itself a failure of the caller's
# operation. Caller never has to check the return.
#
# Schema (pinned; doctor/status parse these fields):
#   {ts, subsystem, reason, retry_in_sec, pid}
#
# Rotation: handled by rotate_runs_jsonl from state.sh if available
# (image-baked sibling). When safe-exec.sh is sourced standalone in
# tests where state.sh isn't loaded, rotation silently no-ops — the
# tests don't generate enough volume to need it.
log_aux_fail() {
  local subsystem="$1" reason="$2" retry="${3:-null}"
  local ts pid_field
  ts=$(_safe_exec_iso8601)
  pid_field="${BASHPID:-$$}"

  local log_dir
  log_dir=$(dirname "$SAFE_EXEC_AUX_LOG")
  mkdir -p "$log_dir" 2>/dev/null || true

  # Best-effort rotation (image path); ignore if the helper isn't loaded
  # (e.g. unit tests sourcing safe-exec.sh in isolation).
  if command -v rotate_runs_jsonl >/dev/null 2>&1; then
    rotate_runs_jsonl "$SAFE_EXEC_AUX_LOG" "$SAFE_EXEC_AUX_LOG_THRESHOLD_BYTES" 2>/dev/null || true
  fi

  # Build the JSON via jq so reason can contain quotes / newlines / etc.
  # without corrupting the line. Falls back to a hand-built minimal line
  # if jq is missing — never crash on the log path.
  local line
  if command -v jq >/dev/null 2>&1; then
    line=$(jq -cn \
      --arg ts "$ts" \
      --arg subsystem "$subsystem" \
      --arg reason "$reason" \
      --argjson pid "$pid_field" \
      --argjson retry_in_sec "${retry:-null}" \
      '{ts:$ts, subsystem:$subsystem, reason:$reason, retry_in_sec:$retry_in_sec, pid:$pid}' \
      2>/dev/null)
  fi
  if [ -z "$line" ]; then
    line=$(printf '{"ts":"%s","subsystem":"%s","reason":"failed","retry_in_sec":null,"pid":%s}' \
      "$ts" "$subsystem" "$pid_field")
  fi

  printf '%s\n' "$line" >> "$SAFE_EXEC_AUX_LOG" 2>/dev/null || true

  # Mirror to stderr so the failure also shows up in `docker logs` for
  # interactive debugging — the container's stderr is what the human
  # sees first. Never block on the mirror.
  printf '[safe-exec] %s: %s\n' "$subsystem" "$reason" >&2 2>/dev/null || true

  return 0
}

# with_git_noninteractive CMD...
#
# Run a command with every interactive credential prompt disabled. If
# git/ssh/sudo would fall back to a TTY prompt, they will exit non-zero
# in milliseconds instead of hanging on read(stdin).
#
# Variables set:
#   GIT_TERMINAL_PROMPT=0     git refuses to prompt for username/password
#   GIT_ASKPASS=/bin/true     git refuses to invoke an external ASKPASS
#   SSH_ASKPASS=/bin/true     ssh refuses likewise
#   GCM_INTERACTIVE=Never     Git Credential Manager (if installed) opaque-fails
#   GIT_HTTP_LOW_SPEED_LIMIT/TIME  abort hung HTTP transfers fast
#
# Returns the wrapped command's exit code. Pure wrapper; no side effects
# beyond the env it sets for the child.
with_git_noninteractive() {
  GIT_TERMINAL_PROMPT=0 \
  GIT_ASKPASS=/bin/true \
  SSH_ASKPASS=/bin/true \
  GCM_INTERACTIVE=Never \
  GIT_HTTP_LOW_SPEED_LIMIT=1000 \
  GIT_HTTP_LOW_SPEED_TIME=10 \
    "$@"
}

# safe_curl URL [CURL_OPTS...]
#
# Wrap curl with a hard ceiling on latency. Always prints the HTTP status
# code on stdout (000 on connection failure / DNS error / timeout) so
# callers can branch without parsing curl's exit code matrix.
#
# Body is written to a temp file and printed to stderr (truncated to 512
# bytes) — stdout is ONLY the code. Caller can `head -c 512 -` etc. on
# the captured stderr if they want the body.
#
# Always returns 0; transport failures are visible via code=000.
safe_curl() {
  local url="$1"; shift
  local resp_file
  resp_file=$(mktemp 2>/dev/null) || resp_file="/tmp/safe_curl.$$"
  : > "$resp_file"

  local code
  code=$(curl -sS --max-time 10 -o "$resp_file" -w '%{http_code}' "$url" "$@" 2>/dev/null || true)
  [ -z "$code" ] && code="000"

  printf '%s' "$code"
  head -c 512 "$resp_file" 2>/dev/null >&2
  rm -f "$resp_file" 2>/dev/null || true
  return 0
}

# safe_run_bg NAME TIMEOUT_SEC CMD...
#
# Run CMD in the background with three guarantees:
#
#   1. Non-blocking dispatch. The caller returns within ~1ms regardless
#      of how long CMD takes. The watchdog can call this from its 2s poll
#      and never stall.
#
#   2. Bounded execution. If `timeout` is available, CMD is killed after
#      TIMEOUT_SEC (SIGTERM, then SIGKILL after 5s). Without `timeout`
#      (test hosts), CMD runs to completion — but tests should run with
#      coreutils' timeout/gtimeout installed for full coverage.
#
#   3. Dedup. If another invocation of the same NAME is already in
#      flight, this call exits early with a "skipped: already running"
#      log line. Uses flock(LOCK_NB) on /tmp/safe-exec/NAME.lock.
#
# All outcomes (success, fail, timeout, skip) are visible via aux.jsonl
# — caller never has to check return codes. Stdout of CMD is discarded;
# stderr is captured (first 512 bytes) into the failure record so post-
# mortems don't require shelling into the container.
#
# NAME conventions: short kebab-case identifier; one per logical
# subsystem (e.g. "plugin-install", "token-health", "backup-identity").
# Used as the dedup key and as the subsystem field in aux.jsonl.
safe_run_bg() {
  local name="$1" timeout_sec="$2"; shift 2

  if [ -z "$name" ] || [ -z "$timeout_sec" ] || [ "$#" -eq 0 ]; then
    log_aux_fail "safe_run_bg" "usage: safe_run_bg NAME TIMEOUT_SEC CMD..."
    return 0
  fi

  mkdir -p "$SAFE_EXEC_LOCK_DIR" 2>/dev/null || true
  local lockfile="$SAFE_EXEC_LOCK_DIR/${name}.lock"
  local errfile="$SAFE_EXEC_LOCK_DIR/${name}.err.$$"

  # Resolve the timeout binary lazily; reused for the lifetime of the shell.
  _safe_exec_resolve_timeout

  # Background subshell so the caller does not wait. The subshell holds
  # the lock; if a second call lands while we're running, it acquires
  # nothing and emits "skipped: already running" then exits. flock with
  # `-n` (non-blocking) is the dedup mechanic.
  (
    if command -v flock >/dev/null 2>&1; then
      exec 9>"$lockfile"
      if ! flock -n 9; then
        log_aux_fail "$name" "skipped: already running"
        exit 0
      fi
    fi

    : > "$errfile" 2>/dev/null || true

    # `|| rc=$?` is the load-bearing idiom here. Without it, callers running
    # under `set -e` (notably bats tests) would see the subshell exit on the
    # very first non-zero command — the whole point of safe_run_bg is to
    # observe non-zero outcomes and route them to log_aux_fail, so we have
    # to explicitly disarm set -e for the dispatched command.
    local rc=0
    if [ -n "$_safe_exec_timeout_bin" ]; then
      "$_safe_exec_timeout_bin" --kill-after=5 "$timeout_sec" "$@" >/dev/null 2>"$errfile" || rc=$?
    else
      "$@" >/dev/null 2>"$errfile" || rc=$?
    fi

    if [ "$rc" -eq 0 ]; then
      :  # success: silent — only failures are interesting
    elif [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
      local err
      err=$(head -c 256 "$errfile" 2>/dev/null)
      log_aux_fail "$name" "timeout after ${timeout_sec}s: ${err:-(no stderr)}"
    else
      local err
      err=$(head -c 256 "$errfile" 2>/dev/null)
      log_aux_fail "$name" "exit=$rc: ${err:-(no stderr)}"
    fi

    rm -f "$errfile" 2>/dev/null || true
  ) &

  return 0
}

# Tests source this file with SAFE_EXEC_NO_RUN=1 set so they can call
# functions without the dispatcher running anything at source time.
# Currently unused (no side-effecting code at source time), reserved
# for symmetry with start_services.sh::START_SERVICES_NO_RUN.
if [ "${SAFE_EXEC_NO_RUN:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi
