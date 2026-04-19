# Cron for in-container agent heartbeat.
# Rendered at container startup: envsubst < /opt/agent-admin/crontab.tpl > /etc/crontabs/agent
${HEARTBEAT_CRON} agent /workspace/scripts/heartbeat/heartbeat.sh >> /workspace/scripts/heartbeat/logs/cron.log 2>&1
