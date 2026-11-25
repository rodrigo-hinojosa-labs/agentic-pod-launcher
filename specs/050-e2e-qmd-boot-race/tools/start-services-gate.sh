#!/bin/bash
# Reproduction-only supervisor mount. No product file is changed by this tool.
# Source with BOOT_RACE_WRAPPER_NO_RUN=1 to inspect the helpers without booting.

_boot_race_log() {
  printf '[boot-race-gate] %s\n' "$*" >&2
}

_boot_race_error() {
  _boot_race_log "$*"
  if [ -n "${_BOOT_RACE_CONTROL:-}" ] && [ -d "$_BOOT_RACE_CONTROL/.wrapper-claimed" ]; then
    printf '%s\n' "$*" > "$_BOOT_RACE_CONTROL/error"
  fi
}

_boot_race_write() {
  local name="$1" value="$2" temporary
  temporary="$_BOOT_RACE_CONTROL/.$name.$$.tmp"
  printf '%s\n' "$value" > "$temporary"
  mv "$temporary" "$_BOOT_RACE_CONTROL/$name"
}

_boot_race_write_pid() {
  local name="$1" temporary
  temporary="$_BOOT_RACE_CONTROL/.$name.$$.tmp"
  # A direct child sees this shell as PPID. $$ names the original shell in
  # background subshells, while BASHPID is unavailable on bash 3.2.
  sh -c 'printf "%s\n" "$PPID"' > "$temporary"
  mv "$temporary" "$_BOOT_RACE_CONTROL/$name"
}

_boot_race_sha256() {
  local digest
  if command -v sha256sum >/dev/null 2>&1; then
    digest=$(sha256sum "$1")
  else
    digest=$(shasum -a 256 "$1")
  fi
  printf '%s\n' "${digest%% *}"
}

_boot_race_initialize() {
  local original="${BOOT_RACE_ORIGINAL:-/workspace/.e2e/050/start_services.original.sh}"
  local control="${BOOT_RACE_CONTROL_DIR:-/workspace/.e2e/050/control}"
  local timeout="${BOOT_RACE_SIGNAL_TIMEOUT_S:-90}" expected="${BOOT_RACE_ORIGINAL_SHA256:-}"
  local probe="${BOOT_RACE_HOST_PROBE:-0}" mode=container user uid gid digest entry
  case "${BOOT_RACE_ORDER:-}" in early|late) ;; *) _boot_race_error 'BOOT_RACE_ORDER must be early or late'; return 64 ;; esac
  case "$timeout" in ''|*[!0-9]*|0|0*) _boot_race_error 'signal timeout must be an integer from 1 to 90'; return 64 ;; esac
  if [ "${#timeout}" -gt 2 ] || [ "$timeout" -gt 90 ]; then
    _boot_race_error 'signal timeout must be an integer from 1 to 90'; return 64
  fi
  case "$expected" in ''|*[!0-9a-f]*) _boot_race_error 'expected original SHA-256 must be 64 lowercase hex characters'; return 64 ;; esac
  if [ "${#expected}" -ne 64 ]; then _boot_race_error 'expected original SHA-256 must be 64 lowercase hex characters'; return 64; fi
  case "$original:$control" in /*:/*) ;; *) _boot_race_error 'original and control paths must be absolute'; return 64 ;; esac
  if [ ! -f "$original" ] || [ -L "$original" ] || [ ! -d "$control" ] || [ -L "$control" ]; then
    _boot_race_error 'original must be a regular file and control a fresh directory, without symlinks'; return 64
  fi
  user=$(id -un); uid=$(id -u); gid=$(id -g)
  case "$probe" in
    0)
      if [ "$user" != agent ] || [ "$uid" -eq 0 ]; then _boot_race_error 'wrapper must run as the non-root agent user'; return 64; fi
      if [ "$original" != /workspace/.e2e/050/start_services.original.sh ] || [ "$control" != /workspace/.e2e/050/control ]; then
        _boot_race_error 'container control and original must use the fixed /workspace/.e2e/050 paths'; return 64
      fi
      ;;
    1)
      mode=host-probe
      case "$original:$control" in /workspace/*:*|*:/workspace/*) _boot_race_error 'host probes must use synthetic paths outside /workspace'; return 64 ;; esac
      if ! grep -Fx '# BOOT_RACE_HOST_PROBE_ORIGINAL=1' "$original" >/dev/null; then
        _boot_race_error 'host probe requires an explicitly marked synthetic original'; return 64
      fi
      ;;
    *) _boot_race_error 'BOOT_RACE_HOST_PROBE must be 0 or explicitly 1'; return 64 ;;
  esac
  digest=$(_boot_race_sha256 "$original")
  if [ "$digest" != "$expected" ]; then _boot_race_error 'original supervisor SHA-256 mismatch'; return 65; fi
  for entry in "$control"/* "$control"/.[!.]* "$control"/..?*; do
    if [ -e "$entry" ] || [ -L "$entry" ]; then _boot_race_error 'control directory is not empty; refusing reused evidence'; return 65; fi
  done
  mkdir "$control/.wrapper-claimed"
  _BOOT_RACE_CONTROL="$control"
  _BOOT_RACE_ORIGINAL="$original"
  _BOOT_RACE_TIMEOUT="$timeout"
  _BOOT_RACE_MODE="$mode"
  printf 'mode=%s\nuser=%s\nuid=%s\ngid=%s\n' "$mode" "$user" "$uid" "$gid" > "$control/identity"
  _boot_race_write original.sha256 "$digest"
  : > "$control/setup.log"
}

_boot_race_stop_setup() {
  local pid="${_BOOT_RACE_SETUP_PID:-}" count=0
  [ -n "$pid" ] || return 0
  # The setup job has its own process group; descendants cannot escape cleanup
  # merely by outliving their immediate shell. No other boot job joins it.
  kill -TERM -- "-$pid" 2>/dev/null || true
  while kill -0 -- "-$pid" 2>/dev/null && [ "$count" -lt 20 ]; do
    sleep 0.05
    count=$((count + 1))
  done
  kill -KILL -- "-$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  _BOOT_RACE_SETUP_PID=
}

_boot_race_setup_signal() {
  _boot_race_error "setup gate interrupted by $1"
  _boot_race_stop_setup
  exit "$2"
}

_boot_race_wait_release() {
  local started="$SECONDS"
  while [ ! -f "$_BOOT_RACE_CONTROL/release" ]; do
    if [ "$((SECONDS - started))" -ge "$_BOOT_RACE_TIMEOUT" ]; then
      _boot_race_error "timed out waiting for release after ${_BOOT_RACE_TIMEOUT}s"
      return 124
    fi
    sleep 0.05
  done
  if [ -L "$_BOOT_RACE_CONTROL/release" ]; then _boot_race_error 'release must not be a symlink'; return 65; fi
}

_boot_race_setup() {
  local setup_pid rc=0 started monitor_was_set=0
  if ! mkdir "$_BOOT_RACE_CONTROL/.setup-claimed" 2>/dev/null; then
    _boot_race_error 'setup gate was entered more than once'; return 65
  fi
  _BOOT_RACE_SETUP_PID=
  trap '_boot_race_stop_setup' EXIT
  trap '_boot_race_setup_signal INT 130' INT
  trap '_boot_race_setup_signal TERM 143' TERM
  trap '_boot_race_setup_signal HUP 129' HUP
  _boot_race_write_pid entered
  if [ "$BOOT_RACE_ORDER" = late ]; then _boot_race_wait_release; fi
  case "$-" in *m*) monitor_was_set=1 ;; esac
  # Give only this child a private group, then restore normal noninteractive
  # execution in it. The real function is a plain command, never an if/|| test:
  # those contexts disable errexit throughout sourced functions in bash.
  set -m
  (
    set +m
    _boot_race_real_setup "$@"
  ) >> "$_BOOT_RACE_CONTROL/setup.log" 2>&1 &
  setup_pid=$!
  _BOOT_RACE_SETUP_PID="$setup_pid"
  if [ "$monitor_was_set" -eq 0 ]; then set +m; fi
  started="$SECONDS"
  while kill -0 "$setup_pid" 2>/dev/null; do
    if [ "$((SECONDS - started))" -ge "$_BOOT_RACE_TIMEOUT" ]; then
      _boot_race_error "timed out waiting for setup returned after ${_BOOT_RACE_TIMEOUT}s"
      _boot_race_stop_setup
      return 124
    fi
    sleep 0.05
  done
  wait "$setup_pid" || rc=$?
  # A successful function can still leave a timeout watchdog behind. Retire
  # only descendants in our setup group before announcing its final outcome.
  _boot_race_stop_setup
  # Replay the exact captured stream into docker logs as well as the artifact.
  cat "$_BOOT_RACE_CONTROL/setup.log" >&2
  _boot_race_write returned "$rc"
  return "$rc"
}

_boot_race_main_cleanup() {
  local pid owned_jobs count
  # The original main can exit immediately after dispatch, before entered is
  # written. Use the shell's own job table rather than evidence file contents.
  # This wrapper owns these original-boot jobs in its isolated reproduction.
  owned_jobs=$(jobs -p)
  for pid in $owned_jobs; do kill -TERM "$pid" 2>/dev/null || true; done
  for pid in $owned_jobs; do
    count=0
    while kill -0 "$pid" 2>/dev/null && [ "$count" -lt 40 ]; do
      sleep 0.05
      count=$((count + 1))
    done
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
}

_boot_race_main_signal() {
  _boot_race_error "supervisor interrupted by $1"
  _boot_race_main_cleanup
  exit "$2"
}

_boot_race_main() {
  local definition incoming_umask
  set -euo pipefail
  incoming_umask=$(umask)
  umask 077
  _boot_race_initialize
  # Restrict evidence creation without changing the original boot's file modes.
  umask "$incoming_umask"
  # Hash and identity are checked before any code from the source is executed.
  # shellcheck source=/dev/null
  START_SERVICES_NO_RUN=1 source "$_BOOT_RACE_ORIGINAL"
  if ! declare -F qmd_setup_if_needed >/dev/null || ! declare -F main >/dev/null; then
    _boot_race_error 'original supervisor did not define setup and main'; return 65
  fi
  definition=$(declare -f qmd_setup_if_needed)
  # Rename only the declaration emitted by bash, preserving the entire body.
  definition="_boot_race_real_setup${definition#qmd_setup_if_needed}"
  eval "$definition"
  qmd_setup_if_needed() { _boot_race_setup "$@"; }
  trap '_boot_race_main_cleanup' EXIT
  trap '_boot_race_main_signal INT 130' INT
  trap '_boot_race_main_signal TERM 143' TERM
  trap '_boot_race_main_signal HUP 129' HUP
  _boot_race_write_pid boot-called
  main "$@"
}

if [ "${BOOT_RACE_WRAPPER_NO_RUN:-0}" != 1 ] && [ "${BASH_SOURCE[0]}" = "$0" ]; then
  _boot_race_main "$@"
fi
