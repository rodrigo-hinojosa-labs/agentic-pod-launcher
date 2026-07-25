#!/usr/bin/env bash
# 024-fix-session-restart-retire (US1): classify WHY this agent process is
# stopping, while systemd still knows. Invoked as ExecStop=- on the session unit.
#
# READ THIS BEFORE CHANGING THE CLASSIFICATION — it is the part that a
# plausible-sounding assumption gets wrong:
#
#   ExecStop runs in BOTH cases. It is NOT "systemd is stopping us". It runs
#   when the operator stops or restarts the service AND when the main process
#   already exited on its own. That hypothesis was tested against real systemd
#   and REFUTED (contracts/session-stop-classification.md §2).
#
# What actually separates the two is TIMING, not the fact that this ran:
# systemd only populates $EXIT_CODE/$EXIT_STATUS once the main process has
# died. So at this point:
#
#   $EXIT_CODE populated -> the process had already exited by itself
#                           => its session ended => the pointer is stale
#   $EXIT_CODE empty     -> systemd is initiating the stop and the process is
#                           still alive => the session may survive => keep it
#
# Measured on real systemd, 5 scenarios x 3 repetitions, 15/15 consistent,
# including the Restart=always variant this unit uses (research.md R2).
#
# The predecessor of this hook read $EXIT_CODE from ExecStopPost instead, where
# BOTH cases report "exited" (Claude Code traps SIGTERM and exits 0). That is
# why restarting the service used to kill the operator's live conversation.
#
# One measured edge: when the process exits on its own with a NON-ZERO code,
# systemd skips ExecStop altogether, so no cause is recorded. The next start
# reads that absence and falls back to service_result — see agent-session-check.sh.
#
# Never blocks a shutdown: the ExecStop= directive carries its own '-' prefix
# and this script also exits 0 unconditionally (the 021 convention).
# Rendered from modules/local-session-stop.sh.tpl — do not hand-edit.

AGENT_NAME="{{AGENT_NAME}}"
WORKSPACE="{{DEPLOYMENT_WORKSPACE}}"

# shellcheck source=/dev/null
. "${WORKSPACE}/scripts/lib/session_pointer.sh" 2>/dev/null

if command -v session_classify_stop >/dev/null 2>&1; then
  _cause=$(session_classify_stop "${EXIT_CODE:-}")
  # Writes ONLY the cause. agent-session-exit.sh runs next and merges systemd's
  # exit fields into this same marker, preserving what we wrote here.
  session_exit_marker_write "$WORKSPACE" "" "" "" "$_cause"
else
  echo "agent-${AGENT_NAME} session-stop: WARN: session_pointer.sh unavailable; stop cause not recorded" >&2
fi

exit 0
