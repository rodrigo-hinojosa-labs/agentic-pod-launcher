#!/bin/sh
# Container entrypoint. Runs as root (per compose config -- no `user:` key)
# so it can fix volume ownership, then drops to `agent` via su-exec.
set -eu

WORKSPACE=/workspace
AGENT_HOME=/home/agent
CRONTAB_DST=/etc/crontabs/agent

log() { printf '[entrypoint] %s\n' "$*"; }

# 1. First-run volume init: chown /home/agent if it is still root-owned.
if [ "$(stat -c %U /home/agent)" = "root" ]; then
  log "chowning /home/agent to agent:agent (first-run volume init)"
  chown -R agent:agent /home/agent
fi

# 2. Render /etc/crontabs/agent from the image-baked template. Requires
#    HEARTBEAT_CRON to be available (set below from HEARTBEAT_INTERVAL).
if [ -f /opt/agent-admin/crontab.tpl ]; then
  export HEARTBEAT_CRON="${HEARTBEAT_CRON:-*/30 * * * *}"
  envsubst < /opt/agent-admin/crontab.tpl > "$CRONTAB_DST"
  chmod 0644 "$CRONTAB_DST"
  log "crontab rendered"
fi

# 3. Refresh /workspace/CONTAINER.md with live runtime details. Cheap, runs
#    as agent (the workspace is bind-mounted with agent-owned perms). The
#    agent reads it through CLAUDE.md's pointer so it knows, with real
#    data, that it runs inside this container.
if [ -x /opt/agent-admin/scripts/write_container_info.sh ]; then
  su-exec agent /opt/agent-admin/scripts/write_container_info.sh || log "WARN: container-info refresh failed (non-fatal)"
fi

# 4. Drop to `agent` and hand off to the supervisor. The supervisor is the
#    authority on what to launch next: a bare Claude session so the user can
#    `/login` first, the Telegram wizard once the profile is authenticated
#    but missing the bot token, or a channel-enabled Claude once everything
#    is in place. Keeping that decision in start_services.sh (not here)
#    means the watchdog can re-evaluate on every respawn without a full
#    container restart.
log "starting services"
exec su-exec agent /opt/agent-admin/scripts/start_services.sh
