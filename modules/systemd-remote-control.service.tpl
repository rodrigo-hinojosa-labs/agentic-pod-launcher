[Unit]
Description=Claude Code Remote Control ({{AGENT_NAME}})
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=simple
User={{OPERATOR_USER}}
WorkingDirectory={{DEPLOYMENT_WORKSPACE}}
# 021: the workspace .env FIRST (021-local-secret-delivery) — in systemd the
# LATER EnvironmentFile wins, so remote-control.env's PATH/HOME/
# CLAUDE_CONFIG_DIR always beat a stray line in .env (a clobbered PATH is the
# historical 203/EXEC failure). The leading `-` makes a missing/unreadable/
# invalid .env a silent no-op instead of a unit start failure — this IS
# FR-004, enforced by systemd itself. This one line is what delivers every
# catalog-MCP secret: Claude Code expands ${VAR} in .mcp.json from its own
# process environment and spawns the MCP servers itself.
EnvironmentFile=-{{DEPLOYMENT_WORKSPACE}}/.env
EnvironmentFile={{DEPLOYMENT_WORKSPACE}}/.state/remote-control.env
ExecCondition=/usr/bin/test -r {{DEPLOYMENT_WORKSPACE}}/.state/.claude/.credentials.json
# Boot-time secret warning (021 US3) — never blocks startup (the `-` prefix +
# the script's own unconditional exit 0 both guard against that).
ExecStartPre=-{{DEPLOYMENT_WORKSPACE}}/scripts/local/agent-secret-check.sh
# 022: retire a session pointer that names an ALREADY-ENDED session, before
# remote-control reads it. With --spawn=session the process exits when its
# session ends; Restart=always then revives it, and Claude Code reads a dead
# pointer-writer as "reuse the environment AND the sessionId" — so it
# re-announces a session the relay already closed and the agent goes silently
# unreachable. This runs ONCE per start, never against a live session, and acts
# on the verdict systemd recorded below. Same double belt as the line above.
ExecStartPre=-{{DEPLOYMENT_WORKSPACE}}/scripts/local/agent-session-check.sh
# 022 (US3): the client-visible name comes from agent.yml
# (deployment.session_name), not from $(hostname) composed at render time. The
# QUOTES are load-bearing: a name with spaces would otherwise split into several
# argv entries and --spawn=session would land as the value of --name.
ExecStart={{CLAUDE_BIN}} remote-control --name "{{DEPLOYMENT_SESSION_NAME}}" --spawn=session --verbose
# 022: persist WHY we stopped ($SERVICE_RESULT/$EXIT_CODE/$EXIT_STATUS). It is
# the only local signal that separates "the session ended" (process exited on
# its own => retire the pointer) from "systemd killed us" (=> keep it; the
# session can still be live server-side and the vendor's reuse restores the
# same client link — measured on hardware).
ExecStopPost=-{{DEPLOYMENT_WORKSPACE}}/scripts/local/agent-session-exit.sh
Restart=always
RestartSec=10
# Permission prompts stay enabled (the dangerous skip flag is intentionally absent).

[Install]
WantedBy=multi-user.target
