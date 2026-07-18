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
ExecStart={{CLAUDE_BIN}} remote-control --name {{HOST_NAME}}-{{AGENT_NAME}} --spawn=session --verbose
Restart=always
RestartSec=10
# Permission prompts stay enabled (the dangerous skip flag is intentionally absent).

[Install]
WantedBy=multi-user.target
