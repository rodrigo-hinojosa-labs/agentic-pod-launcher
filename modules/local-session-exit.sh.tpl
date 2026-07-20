#!/usr/bin/env bash
# 022-local-session-lifecycle (US1): record WHY this agent process stopped.
# Invoked as ExecStopPost=- on the session unit, so systemd hands us
# $SERVICE_RESULT, $EXIT_CODE and $EXIT_STATUS (systemd.service(5)).
#
# Why this exists: the session pointer Claude Code leaves behind carries no
# "ended" field, and a dead writer process is exactly what makes the next start
# REUSE the stored session. The only local signal that separates "the session
# ended" from "systemd killed us mid-session" is the exit cause, and systemd is
# the authority on it. This script does nothing but persist that verdict;
# interpreting it belongs to agent-session-check.sh at the next start.
#
# Never blocks a shutdown: the ExecStopPost= directive carries its own '-'
# prefix and this script also exits 0 unconditionally (belt and braces, the
# 021 convention).
# Rendered from modules/local-session-exit.sh.tpl — do not hand-edit.

AGENT_NAME="{{AGENT_NAME}}"
WORKSPACE="{{DEPLOYMENT_WORKSPACE}}"

# shellcheck source=/dev/null
. "${WORKSPACE}/scripts/lib/session_pointer.sh" 2>/dev/null

if command -v session_exit_marker_write >/dev/null 2>&1; then
  # Values are stored verbatim, never interpreted here. An absent variable is
  # written as an empty string, which the next start reads as "cannot
  # determine" and resolves in favour of availability (FR-014).
  session_exit_marker_write \
    "$WORKSPACE" \
    "${SERVICE_RESULT:-}" \
    "${EXIT_CODE:-}" \
    "${EXIT_STATUS:-}"
else
  echo "agent-${AGENT_NAME} session-exit: WARN: session_pointer.sh unavailable; exit cause not recorded" >&2
fi

exit 0
