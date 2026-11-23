# shellcheck shell=bash
# 049-telegram-stderr-log-bound: run the stderr-capture block of the Telegram patcher under bun.
#
# Loaded by tests/telegram-stderr-hook.bats (`load helper-stderr-hook`, right after
# `load helper`). Contracts: specs/049-telegram-stderr-log-bound/contracts/stderr-hook-v2.md.
#
# Rules of this file:
#   - bash 3.2 and 5.x: no [[ ]], mapfile, associative arrays, local -n or ${v,,}.
#   - nothing happens when it is loaded: it only defines functions.
#   - the block under test is never retyped here: stderr_hook_build imports the patcher and
#     takes the exact text of STDERR_HOOK_V1 or STDERR_HOOK, so a test can only pass against
#     what the patcher really inserts into server.ts.
#   - every bun this file starts is recorded in $BATS_TEST_TMPDIR/stderr-hook-pids, and
#     stderr_hook_reap (called from teardown) kills whatever is still alive. The v1 loop never
#     ends by itself and writes about 10 MB/s (research M2): a leaked bun fills the disk.

# Path of the patcher the block is taken from. A mutation run points it at a copy.
STDERR_HOOK_PATCHER_DEFAULT="docker/scripts/apply_telegram_typing_patch.py"

stderr_hook_patcher() {
  if [ -n "${STDERR_HOOK_PATCHER:-}" ]; then
    printf '%s\n' "$STDERR_HOOK_PATCHER"
  else
    printf '%s\n' "$REPO_ROOT/$STDERR_HOOK_PATCHER_DEFAULT"
  fi
}

stderr_hook_require_bun() {
  if ! command -v bun >/dev/null 2>&1; then
    skip "bun not on PATH: the stderr hook behavior is covered by the local gate and DOCKER_E2E (049 research D6)"
  fi
}

# stderr_hook_build <V1|V2> <out.ts> <log>
# Writes the block to <out.ts> with the production log path replaced by <log>. The caller
# appends the vendor handlers and its own driver afterwards.
stderr_hook_build() {
  local which="$1" out="$2" log="$3" attr
  case "$which" in
    V1) attr=STDERR_HOOK_V1 ;;
    V2) attr=STDERR_HOOK ;;
    *) echo "stderr_hook_build: unknown block '$which'" >&2; return 2 ;;
  esac
  python3 -I - "$(stderr_hook_patcher)" "$attr" "$out" "$log" <<'PY'
import importlib.util, json, sys
patcher, attr, out, log = sys.argv[1:5]
spec = importlib.util.spec_from_file_location("apl_patcher", patcher)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
block = getattr(mod, attr)
prod = "'/workspace/scripts/heartbeat/logs/telegram-mcp-stderr.log'"
if block.count(prod) != 1:
    sys.exit("stderr_hook_build: production log path literal not found exactly once in " + attr)
with open(out, "w") as fh:
    fh.write(block.replace(prod, json.dumps(log)))
PY
}

_stderr_hook_record_pid() {
  printf '%s\n' "$1" >> "$BATS_TEST_TMPDIR/stderr-hook-pids"
}

_stderr_hook_alive() {
  kill -0 "$1" 2>/dev/null
}

# stderr_hook_run_closed_pipe <ts> <seconds>
# Runs bun with its stderr on a pipe whose reader (`true`) exits at once, so every write to
# stderr meets a closed pipe. In `cmd | true &` the $! is the PID of `true`, not of bun, so the
# PID comes from a file written by `sh` right before it execs bun (exec keeps the PID).
# Returns 0 when bun exited by itself before the deadline, 1 when it had to be killed, and 2
# when bun never started. On return, bun is dead in every case.
stderr_hook_run_closed_pipe() {
  local ts="$1" secs="$2" pidf pid ticks limit
  pidf="$BATS_TEST_TMPDIR/stderr-hook-pid.$$.$RANDOM"
  rm -f "$pidf"
  # shellcheck disable=SC2016
  sh -c 'echo $$ > "$1"; exec bun "$2"' _ "$pidf" "$ts" 2>&1 >/dev/null 3>&- 4>&- | true &
  ticks=0
  while [ ! -s "$pidf" ] && [ "$ticks" -lt 50 ]; do
    sleep 0.1
    ticks=$((ticks + 1))
  done
  if [ ! -s "$pidf" ]; then
    return 2
  fi
  pid=$(cat "$pidf")
  _stderr_hook_record_pid "$pid"
  limit=$((secs * 10))
  ticks=0
  while _stderr_hook_alive "$pid" && [ "$ticks" -lt "$limit" ]; do
    sleep 0.1
    ticks=$((ticks + 1))
  done
  if ! _stderr_hook_alive "$pid"; then
    return 0
  fi
  _stderr_hook_kill "$pid"
  return 1
}

_stderr_hook_kill() {
  local pid="$1" ticks=0
  kill "$pid" 2>/dev/null || true
  while _stderr_hook_alive "$pid" && [ "$ticks" -lt 20 ]; do
    sleep 0.1
    ticks=$((ticks + 1))
  done
  if _stderr_hook_alive "$pid"; then
    kill -9 "$pid" 2>/dev/null || true
    ticks=0
    while _stderr_hook_alive "$pid" && [ "$ticks" -lt 20 ]; do
      sleep 0.1
      ticks=$((ticks + 1))
    done
  fi
}

# stderr_hook_run_healthy <ts> <stderr-out>
# Runs bun in the foreground with its stderr on a file. Returns bun's status.
stderr_hook_run_healthy() {
  bun "$1" 2>"$2" >/dev/null 3>&- 4>&-
}

# Called from teardown: no bun started by this file outlives its test, and no big test log
# stays behind.
stderr_hook_reap() {
  local list="$BATS_TEST_TMPDIR/stderr-hook-pids" pid pidf
  if [ -f "$list" ]; then
    while IFS= read -r pid; do
      if [ -n "$pid" ] && _stderr_hook_alive "$pid"; then
        _stderr_hook_kill "$pid"
      fi
    done < "$list"
  fi
  # Defence in depth: also every PID that `sh` wrote right before exec'ing bun. If the runner
  # ever records the wrong PID (mutation M12 of 049: the pipe's last process), a looping bun
  # still dies here instead of outliving the test and holding bats open while it fills the disk.
  for pidf in "$BATS_TEST_TMPDIR"/stderr-hook-pid.*; do
    [ -s "$pidf" ] || continue
    pid=$(cat "$pidf")
    if [ -n "$pid" ] && _stderr_hook_alive "$pid"; then
      _stderr_hook_kill "$pid"
    fi
  done
  find "$BATS_TEST_TMPDIR" -type f -size +1024k -exec rm -f {} + 2>/dev/null || true
}
