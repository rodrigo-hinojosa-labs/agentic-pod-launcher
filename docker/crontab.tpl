# Cron for in-container agent heartbeat.
# /etc/crontabs/agent is a busybox user crontab — the user is implicit in
# the filename, so the entry is "<schedule> <command>" with no user field.
# Rendered at container startup: envsubst < /opt/agent-admin/crontab.tpl > /etc/crontabs/agent
${HEARTBEAT_CRON} /workspace/scripts/heartbeat/heartbeat.sh >> /workspace/scripts/heartbeat/logs/cron.log 2>&1
