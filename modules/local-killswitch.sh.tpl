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
# 022 (US3/S28): the identity the unit actually announces to claude.ai/code.
# This used to be recomposed as $(hostname)-${AGENT_NAME} at RUN time, which
# stops matching the moment the name is configurable — handing the operator a
# false label to search for in the very screen they use to kill the agent
# remotely. The unit NAME is unrelated: it always derives from AGENT_NAME.
SESSION_NAME="{{DEPLOYMENT_SESSION_NAME}}"
# Companion units (present only when their feature is enabled). A kill switch
# must halt ALL agent activity — otherwise the vault-backup timer keeps pushing to
# the fork with the operator's credentials and the healthcheck keeps notifying,
# hours after the operator thought the agent was stopped (013 FR-008). Stopping is
# best-effort (`|| true`) so hosts missing any unit never error out.
AUX_UNITS="agent-${AGENT_NAME}-qmd-reindex.timer agent-${AGENT_NAME}-qmd-watch.service"
AUX_UNITS="$AUX_UNITS agent-${AGENT_NAME}-vault-backup.timer agent-${AGENT_NAME}-healthcheck.timer"
AUX_UNITS="$AUX_UNITS agent-${AGENT_NAME}-wiki-graph.timer"

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
echo "(session identity: ${SESSION_NAME})."
