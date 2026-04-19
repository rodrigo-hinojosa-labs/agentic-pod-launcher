#!/bin/sh
# Container entrypoint. Runs as root to fix volume ownership and start crond,
# then drops to `agent` via su-exec.
set -eu

WORKSPACE=/workspace
AGENT_HOME=/home/agent
CRONTAB_DST=/etc/crontabs/agent

log() { printf '[entrypoint] %s\n' "$*"; }

# 1. First-run volume init
if [ "$(stat -c %U /home/agent)" = "root" ]; then
  log "chowning /home/agent to agent:agent (first-run volume init)"
  chown -R agent:agent /home/agent
fi

# 2. Ensure workspace heartbeat dir is agent-owned (idempotent)
if [ -d "$WORKSPACE/scripts/heartbeat" ]; then
  log "chowning $WORKSPACE/scripts/heartbeat to agent:agent"
  chown -R agent:agent "$WORKSPACE/scripts/heartbeat"
fi

# 3. Render a safe-default crontab so crond has something to watch until
#    heartbeatctl reload overwrites it.
if [ -f /opt/agent-admin/crontab.tpl ]; then
  export HEARTBEAT_CRON="${HEARTBEAT_CRON:-*/30 * * * *}"
  envsubst < /opt/agent-admin/crontab.tpl > "$CRONTAB_DST"
  chmod 0644 "$CRONTAB_DST"
  log "crontab rendered (default)"
fi

# 4. Start crond as ROOT so it can setgid on job dispatch.
if ! pgrep -x crond >/dev/null 2>&1; then
  crond -b -L /workspace/claude.cron.log
  log "crond started (root)"
fi

# 5. Refresh CONTAINER.md
if [ -x /opt/agent-admin/scripts/write_container_info.sh ]; then
  su-exec agent /opt/agent-admin/scripts/write_container_info.sh || log "WARN: container-info refresh failed (non-fatal)"
fi

# 6. Drop to agent and hand off to the supervisor.
log "starting services"
exec su-exec agent /opt/agent-admin/scripts/start_services.sh
