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

echo "▸ Stopping ${UNIT} (Restart=always: an explicit stop does NOT relaunch)…"
sudo systemctl stop "$UNIT" && echo "  ✓ stopped"

if [ "${1:-}" = "--disable" ]; then
  sudo systemctl disable "$UNIT" && echo "  ✓ disabled (won't start at boot)"
fi

echo ""
echo "Remote alternative: toggle Remote Control OFF for this agent in claude.ai/code"
echo "(session identity: $(hostname)-${AGENT_NAME})."
