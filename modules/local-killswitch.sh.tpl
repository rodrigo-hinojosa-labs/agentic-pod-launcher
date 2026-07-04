#!/usr/bin/env bash
# Kill switch for the local Remote Control session.
# Rendered from modules/local-killswitch.sh.tpl — do not hand-edit.
#
# With Restart=always, an explicit `systemctl stop` does NOT relaunch the unit
# (only a crash/clean-exit triggers Restart) — so stop IS a valid kill switch.
# Pass --disable to also prevent start at boot.
set -euo pipefail

AGENT_NAME="{{AGENT_NAME}}"
UNIT="agent-${AGENT_NAME}.service"
# Companion units (present only when their feature is enabled). A kill switch
# should halt qmd activity too; stopping is best-effort and never errors out.
AUX_UNITS="agent-${AGENT_NAME}-qmd-reindex.timer agent-${AGENT_NAME}-qmd-watch.service"

echo "▸ Stopping ${UNIT} (Restart=always: an explicit stop does NOT relaunch)…"
sudo systemctl stop "$UNIT" && echo "  ✓ stopped"

for _aux in $AUX_UNITS; do
  sudo systemctl stop "$_aux" 2>/dev/null && echo "  ✓ stopped ${_aux}" || true
done

if [ "${1:-}" = "--disable" ]; then
  sudo systemctl disable "$UNIT" && echo "  ✓ disabled (won't start at boot)"
  for _aux in $AUX_UNITS; do
    sudo systemctl disable "$_aux" 2>/dev/null && echo "  ✓ disabled ${_aux}" || true
  done
fi

echo ""
echo "Remote alternative: toggle Remote Control OFF for this agent in claude.ai/code"
echo "(session identity: $(hostname)-${AGENT_NAME})."
