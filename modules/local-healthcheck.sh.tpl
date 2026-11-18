#!/usr/bin/env bash
# Rendered local healthcheck. Exit 0=OK, 1=WARN, 2=DEGRADED.
# Main captures uptime before loading libraries or notification configuration.
_HC_CLI_DIR="${BASH_SOURCE[0]%/*}"

_hc_fallback() {
  local name="$1" unit="$2" reason="$3" rc health=WARN
  if command -v timeout >/dev/null 2>&1; then
    timeout -k 1 3 systemctl is-active --quiet "$unit" >/dev/null 2>&1
    rc=$?
    if [ "$rc" -eq 3 ]; then health=DEGRADED; reason="unit not active; $reason"; fi
  fi
  printf 'agent-%s healthcheck: %s (%s)\n' "$name" "$health" "$reason"
  case "$health" in DEGRADED) return 2 ;; *) return 1 ;; esac
}

hc_main() {
  local name="$1" workspace="$2" hc_proc_root="${3:-/proc}" hc_cgroup_root="${4:-/sys/fs/cgroup}"
  local raw rest start global_deadline helper parser _hc_env_ok=false
  local snapshot health=OK reasons='' code message unit="agent-${1}.service" ttl duration
  local hc_last_snapshot=''
  unset NOTIFY_BOT_TOKEN NOTIFY_CHAT_ID
  { IFS=' ' read -r raw rest < "$hc_proc_root/uptime"; } 2>/dev/null || raw=''
  helper="$_HC_CLI_DIR/agent-healthcheck-lib.sh"
  if [ ! -f "$helper" ] || [ ! -r "$helper" ]; then
    _hc_fallback "$name" "$unit" 'healthcheck library unavailable'
    return $?
  fi
  # shellcheck source=/dev/null
  . "$helper"
  start=$(exec 9>&-; hc_uptime_ms "$raw") || {
    _hc_fallback "$name" "$unit" 'cannot verify monotonic clock'
    return $?
  }
  global_deadline=$((start+60000))
  parser="$workspace/scripts/lib/env_file.sh"
  if [ -f "$parser" ] && [ -r "$parser" ]; then
    # shellcheck source=/dev/null
    . "$parser" && _hc_env_ok=true
  fi
  hc_notice_run "$workspace" "$unit" "$global_deadline" >/dev/null
  snapshot=$hc_last_snapshot
  case "$snapshot" in
    *'"health":"DEGRADED"'*) health=DEGRADED ;;
    *'"health":"WARN"'*) health=WARN ;;
    *'"health":"OK"'*) health=OK ;;
    *) health=WARN; reasons='observation unavailable' ;;
  esac
  reasons=$(_hc_reason_text "$snapshot")
  if [ "$_hc_env_ok" != true ]; then
    [ "$health" != OK ] || health=WARN
    reasons="${reasons:+$reasons; }env file parser unavailable"
  fi
  printf 'agent-%s healthcheck: %s%s\n' "$name" "$health" "${reasons:+ ($reasons)}"
  case "$health" in OK) return 0 ;; WARN) return 1 ;; *) return 2 ;; esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -uo pipefail
  hc_main "{{AGENT_NAME}}" "{{DEPLOYMENT_WORKSPACE}}" /proc /sys/fs/cgroup
fi
