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
EnvironmentFile={{DEPLOYMENT_WORKSPACE}}/.state/remote-control.env
ExecCondition=/usr/bin/test -r {{DEPLOYMENT_WORKSPACE}}/.state/.claude/.credentials.json
ExecStart={{CLAUDE_BIN}} remote-control --name {{HOST_NAME}}-{{AGENT_NAME}} --spawn=session --verbose
Restart=always
RestartSec=10
# Permission prompts stay enabled (the dangerous skip flag is intentionally absent).

[Install]
WantedBy=multi-user.target
