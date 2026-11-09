# shellcheck shell=bash
# 043-e2e-lock-race-hardening: the manual reindex of the qmd e2e tests, waiting for
# .reindex.lock instead of assuming it is free.
#
# Loaded by tests/docker-e2e-qmd.bats (`load helper-qmd-e2e`, right after `load helper`) and, on
# the host, by tests/qmd-e2e-lock.bats (from _use_helper), which proves it without Docker.
# Contracts: specs/043-e2e-lock-race-hardening/contracts/{reindex-wait,lock-owner-dump}.md.
#
# Why: the product takes .reindex.lock with `flock -n`, and a run that loses it prints
# `[qmd] reindex: already running - skip` (with an em dash) and returns 0 on purpose, so that
# neither the cron nor the watcher can break anything (scripts/lib/qmd_index.sh, qmd_reindex).
# A manual reindex that loses it does nothing, and only its text says so. The reindex phase of
# `qmd real (041)` went red that way on the night of 29-10-2026 (run 40865079036, #112).
#
# Rules of this file:
#   - bash 3.2 and 5.x: no [[ ]], mapfile, associative arrays, local -n, |&, coproc or ${v,,}.
#   - nothing happens when it is loaded: it only defines constants and functions (K1 to K4 of
#     tests/qmd-embed-nightly.bats load the whole e2e file under env -i).
#   - it writes only on fd 3, as TAP comments; qmd_e2e_lock_owners is the exception, because
#     its caller captures its lines from stdout.
#   - it does not depend on set -e: the sites and the oracle call it inside an || list or the
#     condition of an if, where bash does not apply errexit within the function, so every
#     command that may fail is handled with an if or an explicit || true, and every return is
#     explicit.
#   - the time is read only through _qmd_e2e_now and waited only through _qmd_e2e_sleep, the
#     two seams the host oracle replaces with a fake clock.
#
# The cap of each attempt is the one 041 measured on busybox 1.37 (Alpine 3.24): a plain
# timeout sends TERM only, so a child that ignores it blocks the timeout as long as the child
# lives, and -k 10 adds the KILL; the exit status is 143 after TERM and 137 after KILL, never
# GNU's 124 (the three count as a cap exceeded). The output goes to a file inside the container
# that each attempt rewrites (>) and prints back: an orphan cannot hold the pipe of docker exec
# open, and an attempt never shows the output of the one before it.

# ── part 1: constants, seams, notes and the deadline ─────────────────────────

# The text of the product's skip line after "reindex: " (D1 compares the two).
QMD_E2E_LOCK_BUSY_MARK='already running'
# Seconds between two attempts while the lock is busy (fixed: the oracle uses a fake sleep).
QMD_E2E_LOCK_CADENCE_S=2
# The command of one attempt, expanded by the shell inside the container (I13: L1 compares it).
# shellcheck disable=SC2016
QMD_E2E_REINDEX_CMD='timeout -k 10 600 /usr/local/bin/heartbeatctl qmd-reindex > /tmp/qmd-reindex.out 2>&1; rc=$?; cat /tmp/qmd-reindex.out; exit $rc'

# _qmd_e2e_now / _qmd_e2e_sleep SECONDS: the two seams of time.
_qmd_e2e_now() { date +%s; }
_qmd_e2e_sleep() { sleep "$1"; }

# _qmd_e2e_note TEXT...: every non-empty argument, which may span lines, as TAP comments on
# fd 3, with a '#' and three spaces before each line (the mould of _embed_note in
# tests/docker-e2e-qmd.bats).
_qmd_e2e_note() {
  local a
  for a in "$@"; do
    if [ -z "$a" ]; then continue; fi
    printf '%s\n' "$a" | sed 's/^/#   /' >&3
  done
  return 0
}

# _qmd_e2e_lock_wait_s: the effective deadline in seconds, from QMD_E2E_REINDEX_LOCK_WAIT_S,
# normalized like QMD_E2E_SETUP_DEADLINE_S in tests/docker-e2e-qmd.bats: empty, not a number or
# longer than four digits give 120; the value goes through 10# (a leading zero is not octal);
# 0 or more than 3600 give 120.
_qmd_e2e_lock_wait_s() {
  local w="${QMD_E2E_REINDEX_LOCK_WAIT_S:-}"
  case "$w" in
    ''|*[!0-9]*|?????*) w=120 ;;
    *) w=$((10#$w)) ;;
  esac
  if [ "$w" -le 0 ] || [ "$w" -gt 3600 ]; then w=120; fi
  printf '%s\n' "$w"
  return 0
}

# ── part 2: the lock-owner probe ─────────────────────────────────────────────

# The probe (contracts/lock-owner-dump.md section 1): a POSIX sh script, run inside the container
# as agent (busybox ash) or on a Linux host. It walks /proc/*/fd with readlink and names every
# descriptor that points at the lock: pid, fd and the command line (NULs and newlines turned into
# spaces, so that an owner is one line even when it runs a script with `sh -c`, cut at 120
# characters). It skips in silence the processes it cannot read (those of root, as agent,
# and one that ends between finding its descriptor and reading its command line: the group takes
# the error of that redirection, which would otherwise reach the caller before 2>/dev/null applies),
# never takes the lock (taking it for an instant could make another process lose the race, the
# watcher's reindex included), writes no file and needs neither lsof nor fuser. At most 10 lines,
# counted in the loop (cutting a pipe short is a race under pipefail), and it always exits 0. It
# has no single quote: it lives between single quotes here.
# shellcheck disable=SC2016
QMD_E2E_LOCK_OWNERS_SH='lock="${QMD_CACHE_HOME:-$HOME/.cache/qmd}/.reindex.lock"
if [ ! -d /proc ]; then echo "no /proc here"; exit 0; fi
if [ ! -e "$lock" ]; then echo "lock file absent ($lock)"; exit 0; fi
real=$(readlink -f "$lock" 2>/dev/null) || real="$lock"
n=0
for fd in /proc/[0-9]*/fd/*; do
  t=$(readlink "$fd" 2>/dev/null) || continue
  if [ "$t" != "$lock" ] && [ "$t" != "$real" ]; then continue; fi
  p=${fd#/proc/}
  pid=${p%%/*}
  cmd=$( { tr "\000\n" "  " < "/proc/$pid/cmdline"; } 2>/dev/null | cut -c1-120)
  echo "pid $pid fd ${fd##*/} cmd=[$cmd]"
  n=$((n + 1))
  if [ "$n" -ge 10 ]; then break; fi
done
if [ "$n" -eq 0 ]; then echo "none found"; fi
exit 0'

# qmd_e2e_lock_owners EXEC_FN: the lines of the probe, run through EXEC_FN (in_container and inc
# pass -u agent: Principle II). It prints on stdout, for its caller to capture, and returns 0 even
# when the exec fails, so that naming the owner can never turn a red into another one.
qmd_e2e_lock_owners() {
  local out
  out=$("$1" sh -c "$QMD_E2E_LOCK_OWNERS_SH" 2>&1) || true
  if [ -n "$out" ]; then printf '%s\n' "$out"; fi
  return 0
}

# ── part 3: the wait ─────────────────────────────────────────────────────────

# qmd_e2e_reindex_wait EXEC_FN SITE: run the manual reindex through EXEC_FN and, while its output
# says the lock is held by another run, try again every QMD_E2E_LOCK_CADENCE_S seconds until the
# deadline (contracts/reindex-wait.md sections 2 to 4). SITE names the call site in the reports.
# Returns:
#   0  the last attempt did not lose the lock: it ran, or it failed for another reason that the
#      site judges by REINDEX_STATUS (a lost lock exits 0 too: only this return proves a run)
#   1  the lock stayed busy until the deadline; R-EXPIRED is already out on fd 3
#   3  an attempt hit its cap (124, 137 or 143); the site prints the report of 041
# Leaves REINDEX_STATUS and REINDEX_OUTPUT (of the last attempt), REINDEX_ATTEMPTS and
# REINDEX_WAITED_S (the start of the last attempt minus the start of the first). They are
# globals, set at entry, so nothing is left from an earlier wait; the sites read them, never
# $status or $output, which the next `run` overwrites.
qmd_e2e_reindex_wait() {
  local exec_fn="$1" site="$2" deadline first now elapsed owners probed=0
  REINDEX_STATUS=0
  REINDEX_OUTPUT=""
  REINDEX_ATTEMPTS=0
  REINDEX_WAITED_S=0
  deadline=$(_qmd_e2e_lock_wait_s)
  first=$(_qmd_e2e_now)
  while :; do
    now=$(_qmd_e2e_now)
    # read by the sites (and by L2 and L3), not here
    # shellcheck disable=SC2034
    REINDEX_WAITED_S=$((now - first))
    REINDEX_ATTEMPTS=$((REINDEX_ATTEMPTS + 1))
    run "$exec_fn" sh -c "$QMD_E2E_REINDEX_CMD"
    # status and output are set by the `run` of bats
    # shellcheck disable=SC2154
    REINDEX_STATUS=$status
    # shellcheck disable=SC2154
    REINDEX_OUTPUT=$output
    case "$REINDEX_STATUS" in
      124|137|143) return 3 ;;
    esac
    case "$REINDEX_OUTPUT" in
      *"$QMD_E2E_LOCK_BUSY_MARK"*) ;;
      *) return 0 ;;
    esac
    if [ "$probed" -eq 0 ]; then
      probed=1
      owners=$(qmd_e2e_lock_owners "$exec_fn")
      _qmd_e2e_note "reindex lock busy ($site): the first attempt lost the lock; owners:" "$owners"
    fi
    now=$(_qmd_e2e_now)
    elapsed=$((now - first))
    if [ "$elapsed" -ge "$deadline" ]; then
      owners=$(qmd_e2e_lock_owners "$exec_fn")
      _qmd_e2e_note "reindex ($site): the reindex lock stayed busy for $elapsed s ($REINDEX_ATTEMPTS attempts) and the reindex never ran" \
        "last output of qmd-reindex:" "$REINDEX_OUTPUT" \
        "lock owners at the end of the wait:" "$owners"
      return 1
    fi
    _qmd_e2e_sleep "$QMD_E2E_LOCK_CADENCE_S"
  done
}

# ── part 4: the effect ───────────────────────────────────────────────────────

# The read of the effect (data-model.md section 3): a bash script (vault_hash uses bash
# constructs) run inside the container with `bash -lc`, which prints one line:
#   STATE absent                                         (no qmd-index.json)
#   STATE present STATUS PENDING STATE_HASH VAULT_HASH
# with no space inside a field and `-` for a field that is absent or null. The vault is the one
# the product resolves from agent.yml (qmd_vault_dir), the directory _qmd_reindex_locked hashes.
# The paths are the image's: the state file of qmd_state_file (QMD_INDEX_STATE_FILE, the product's
# own seam, wins when set) and the library under /opt/agent-admin (QMD_E2E_LIB_DIR wins when set).
# Neither is set inside the container; X6 of tests/qmd-e2e-lock.bats sets both to run this same
# script on the host. A library that does not load leaves vault_hash undefined, so the vault field
# comes back as - and the report says the hash could not be read.
# It has no single quote: it lives between single quotes here.
# shellcheck disable=SC2016
QMD_E2E_EFFECT_SH='f=${QMD_INDEX_STATE_FILE:-/workspace/scripts/heartbeat/qmd-index.json}
if [ ! -f "$f" ]; then echo "STATE absent"; exit 0; fi
. "${QMD_E2E_LIB_DIR:-/opt/agent-admin/scripts/lib}/qmd_index.sh"
s=$(jq -r ".last_status // \"-\"" "$f" 2>/dev/null) || s=-
p=$(jq -r ".pending // \"-\"" "$f" 2>/dev/null) || p=-
h=$(jq -r ".hash // \"-\"" "$f" 2>/dev/null) || h=-
v=$(vault_hash "$(qmd_vault_dir /workspace/agent.yml)" 2>/dev/null) || v=-
echo "STATE present ${s:--} ${p:--} ${h:--} ${v:--}"'

# qmd_e2e_reindex_effect EXEC_FN SITE: the effect of the reindex, decided here from the STATE line
# (the last line that starts with "STATE ": a login shell may print something first), in this
# order: the state file exists; last_status is indexed or skipped (skipped: another legitimate
# reindex did the work first); pending is 0; both hashes could be read; and the hash of the state
# file is the hash of the vault as it is now. Returns 0 when all of it holds and 1 when not, with
# R-EFFECT on fd 3 naming what failed. It never asks qmd and never prints on stdout.
qmd_e2e_reindex_effect() {
  local exec_fn="$1" site="$2" out l line="" kind st pend hst hv cond="" extra=""
  out=$("$exec_fn" bash -lc "$QMD_E2E_EFFECT_SH" 2>&1) || true
  while IFS= read -r l; do
    case "$l" in "STATE "*) line="$l" ;; esac
  done <<< "$out"
  read -r _ kind st pend hst hv <<< "$line"
  if [ -z "$line" ]; then
    cond="no STATE line came back from the container; its output:"
    extra="$out"
  elif [ "$kind" = "absent" ]; then
    cond="qmd-index.json is absent"
  else
    case "$st" in
      indexed|skipped) ;;
      *) cond="last_status is '$st', not indexed or skipped" ;;
    esac
    if [ -z "$cond" ] && [ "$pend" != "0" ]; then cond="pending is '$pend', not 0"; fi
    # a hash the container could not read comes back as -, and two of them are no match
    if [ -z "$cond" ] && { [ "$hst" = "-" ] || [ "$hv" = "-" ]; }; then
      cond="the hash could not be read (state file: $hst, vault: $hv)"
    fi
    if [ -z "$cond" ] && [ "$hst" != "$hv" ]; then
      cond="the state file covers the vault hash $hst, not the current one, $hv"
    fi
  fi
  if [ -n "$cond" ]; then
    _qmd_e2e_note "reindex effect ($site): $cond" "$extra"
    return 1
  fi
  return 0
}
