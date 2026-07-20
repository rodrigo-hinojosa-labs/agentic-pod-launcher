#!/usr/bin/env bash
# 022-local-session-lifecycle (US1): retire a session pointer that points at a
# session which has already ended, BEFORE `claude remote-control` starts and
# re-announces it. Invoked as the second ExecStartPre=- on the session unit,
# after 021's agent-secret-check.sh.
#
# The failure this prevents, measured on live hardware 2026-07-18: with
# --spawn=session the process exits WHEN ITS SESSION ENDS, Restart=always
# revives it, and the new process finds a pointer whose writer is dead. Claude
# Code reads a dead writer as "reuse the environment AND the sessionId", so it
# re-announces a session the relay already closed. Every health signal stays
# green — systemctl active, zero restarts, no journal errors, and a :443 socket
# ESTABLISHED with real bidirectional traffic — while the agent is unusable.
# One bad reuse contaminates every later start until the file is gone.
#
# What it does NOT do: it never runs against a live session, never polls, and
# never writes a pointer. It reads a verdict systemd itself produced, once per
# service start. That is what keeps it clear of the reverted bridge watchdog
# (commit ebfe35f), which scraped tmux panes on a loop and killed healthy
# sessions every ~2 minutes.
#
# Never blocks startup: the ExecStartPre= directive carries its own '-' prefix
# and this script also exits 0 unconditionally.
# Rendered from modules/local-session-check.sh.tpl — do not hand-edit.

AGENT_NAME="{{AGENT_NAME}}"
WORKSPACE="{{DEPLOYMENT_WORKSPACE}}"
# Local mode pins CLAUDE_CONFIG_DIR here (modules/remote-control.env.tpl:6);
# agent.yml's claude.config_dir is docker-only and deliberately ignored.
CONFIG_DIR="${WORKSPACE}/.state/.claude"

_warn() { echo "agent-${AGENT_NAME} session-check: WARN: $1" >&2; }
_info() { echo "agent-${AGENT_NAME} session-check: $1" >&2; }

# shellcheck source=/dev/null
. "${WORKSPACE}/scripts/lib/session_pointer.sh" 2>/dev/null

command -v session_decide >/dev/null 2>&1 || exit 0

# Consume (not just read) the marker: a stale verdict must never rule a future
# start, and consuming via an atomic rename is what makes two concurrent starts
# safe — only one wins, the loser falls through to "cannot determine".
marker=$(session_exit_marker_consume "$WORKSPACE" 2>/dev/null) || marker=""

pointer=$(session_pointer_path "$WORKSPACE" "$CONFIG_DIR" 2>/dev/null)
case "$?" in
  0) state="present" ;;
  2) state="absent"  ;;   # valid location, no session announced yet
  *) state="unknown" ;;   # cannot determine WHICH file we would touch
esac

case "$(session_decide "$marker" "$state")" in
  retire)
    if session_pointer_retire "$pointer"; then
      _info "retired a stale session pointer (previous exit_code=${marker:-unknown}); a fresh session will be announced"
    else
      _warn "could not retire the stale session pointer at ${pointer}"
    fi
    ;;
  keep)
    # The previous process was killed by systemd, so the session may still be
    # live server-side; Claude Code's own reuse then restores the same client
    # link. Measured twice on hardware. Touching it here would be the
    # "always renew" regression SC-009 exists to forbid.
    :
    ;;
  noop)
    [ "$state" = "unknown" ] && \
      _warn "cannot determine which session pointer belongs to this workspace; leaving everything untouched"
    ;;
esac

exit 0
