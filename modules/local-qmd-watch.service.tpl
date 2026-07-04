[Unit]
Description=QMD inotify watcher for the local vault ({{AGENT_NAME}})
After=network-online.target

[Service]
Type=simple
User={{OPERATOR_USER}}
WorkingDirectory={{DEPLOYMENT_WORKSPACE}}
# Degrade cleanly when inotify-tools is absent: a failed ExecCondition leaves the
# unit inactive (condition not met) WITHOUT triggering Restart — so it never
# restart-loops into `failed`; the reindex timer is the backstop. A wrapper that
# merely "exits clean" would restart-loop under Restart=always and hit the start
# limit, so the guard MUST be the condition, not the exit code.
ExecCondition=/bin/sh -c 'command -v inotifywait'
ExecStart={{DEPLOYMENT_WORKSPACE}}/scripts/local/agent-qmd-watch.sh
Restart=always
RestartSec=2
StartLimitIntervalSec=300
StartLimitBurst=5

[Install]
WantedBy=multi-user.target
