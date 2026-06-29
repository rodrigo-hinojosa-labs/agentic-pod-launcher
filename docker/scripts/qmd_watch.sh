#!/usr/bin/env bash
# qmd_watch.sh — inotify watcher that debounces vault changes into a single
# `heartbeatctl qmd-reindex`. Image-baked; started by start_services.sh when
# vault.qmd.enabled. A filesystem watcher captures EVERY change regardless of
# source (MCPVault, the agent's native Write/Edit, Syncthing). Degrades to the
# cron backstop if inotifywait is unavailable. The 2s watchdog respawns it if
# its PID dies (deterministic liveness — NOT the reverted heuristic watchdog).
set -uo pipefail

# Source the qmd lib for _qmd_log/_qmd_enabled/qmd_vault_dir. Image path first,
# repo-relative fallback so host bats tests can source/run it.
# shellcheck source=/dev/null
if [ -f /opt/agent-admin/scripts/lib/qmd_index.sh ]; then
  source /opt/agent-admin/scripts/lib/qmd_index.sh
elif [ -f "$(dirname "${BASH_SOURCE[0]}")/lib/qmd_index.sh" ]; then
  # shellcheck source=/dev/null
  source "$(dirname "${BASH_SOURCE[0]}")/lib/qmd_index.sh"
fi

QMD_WATCH_DEBOUNCE="${QMD_WATCH_DEBOUNCE:-15}"
QMD_WATCH_AGENT_YML="${QMD_WATCH_AGENT_YML:-/workspace/agent.yml}"
# Backoff before returning on an inotifywait exit, so the watchdog's 2s respawn
# can't become a fork-storm if inotifywait fails instantly (e.g. ENOSPC /
# max_user_watches on a large vault). Tests set 0 to stay fast.
QMD_WATCH_ERROR_BACKOFF="${QMD_WATCH_ERROR_BACKOFF:-5}"

qmd_watch_main() {
  local agent_yml="$QMD_WATCH_AGENT_YML"
  if ! _qmd_enabled "$agent_yml"; then
    _qmd_log "watch: qmd disabled — exiting"
    return 0
  fi
  local vault_dir
  vault_dir=$(qmd_vault_dir "$agent_yml")
  if [ -z "$vault_dir" ] || [ ! -d "$vault_dir" ]; then
    _qmd_log "watch: vault dir unresolved/missing ($vault_dir) — exiting"
    return 0
  fi
  local watch_bin="${QMD_INOTIFYWAIT:-inotifywait}"
  if ! command -v "$watch_bin" >/dev/null 2>&1; then
    _qmd_log "watch: inotifywait unavailable — relying on cron backstop"
    return 0
  fi
  local reindex_cmd="${QMD_REINDEX_CMD:-heartbeatctl qmd-reindex}"
  _qmd_log "watch: watching $vault_dir (debounce ${QMD_WATCH_DEBOUNCE}s)"

  # Coalesce a burst of events into ONE reindex: read events with a debounce
  # timeout; when the window elapses quiet AND a change is pending, fire once.
  # read rc>128 = timeout (quiet window), rc<=128 (EOF) = inotifywait ended.
  local dirty=0 line rc
  while true; do
    if IFS= read -r -t "$QMD_WATCH_DEBOUNCE" line; then
      dirty=1
    else
      rc=$?
      if [ "$rc" -gt 128 ]; then
        if [ "$dirty" -eq 1 ]; then
          _qmd_log "watch: change settled — triggering reindex"
          $reindex_cmd >/dev/null 2>&1 || true
          dirty=0
        fi
      else
        # EOF: inotifywait ended (killed, or a hard error like ENOSPC). Flush any
        # pending change, then back off before returning so the watchdog's 2s
        # respawn can't become a fork-storm when inotifywait fails instantly
        # (Principle IV — degrade, don't spin). The */5 cron backstop keeps the
        # index fresh while the watcher is backed off.
        if [ "$dirty" -eq 1 ]; then
          _qmd_log "watch: stream ended with pending change — flushing reindex"
          $reindex_cmd >/dev/null 2>&1 || true
        fi
        _qmd_log "watch: inotifywait stream ended — backing off ${QMD_WATCH_ERROR_BACKOFF}s then exiting for respawn"
        [ "$QMD_WATCH_ERROR_BACKOFF" != "0" ] && sleep "$QMD_WATCH_ERROR_BACKOFF" 2>/dev/null
        break
      fi
    fi
  done < <("$watch_bin" -r -m -q -e modify,create,delete,move "$vault_dir" 2>/dev/null)
}

# Auto-run when executed; stay inert when sourced (tests may source for unit
# checks). QMD_WATCH_NO_RUN=1 forces inert even when executed.
if [ "${QMD_WATCH_NO_RUN:-0}" != "1" ] && [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  qmd_watch_main
fi
