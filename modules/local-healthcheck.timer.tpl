[Unit]
Description=Run the Remote Control healthcheck every ~5 min ({{AGENT_NAME}})

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Unit=agent-{{AGENT_NAME}}-healthcheck.service

[Install]
WantedBy=timers.target
