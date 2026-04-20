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

# 2. Ensure workspace heartbeat dir is agent-owned (idempotent). Includes
#    a pre-mkdir of logs/ so it exists at chown-time — on macOS Docker
#    Desktop, dirs mkdir'd later via the bind-mount translation layer
#    can end up visible as root:root inside the container even though
#    the host stores 501:20. That discrepancy breaks cron redirects
#    (`heartbeat.sh >> logs/cron.log` fails with EACCES). Creating +
#    chowning in the root phase sidesteps the issue.
if [ -d "$WORKSPACE/scripts/heartbeat" ]; then
  log "chowning $WORKSPACE/scripts/heartbeat to agent:agent"
  mkdir -p "$WORKSPACE/scripts/heartbeat/logs"
  chown -R agent:agent "$WORKSPACE/scripts/heartbeat"
fi

# 3. Render a safe-default crontab so crond has something to watch until
#    heartbeatctl reload writes the real one.
#
#    Ownership note (important): busybox crond *silently skips* any file
#    in /etc/crontabs/ that is not owned by root. The filename controls
#    which user the job runs as; the ownership is a security check.
#    So /etc/crontabs/agent stays root-owned 0644, and heartbeatctl
#    (which runs as agent) cannot write there directly. Instead, it
#    writes to a workspace staging path that the sync loop below
#    copies into /etc/crontabs/ under root identity.
STAGING_CRONTAB="$WORKSPACE/scripts/heartbeat/.crontab.staging"
if [ -f /opt/agent-admin/crontab.tpl ]; then
  export HEARTBEAT_CRON="${HEARTBEAT_CRON:-*/30 * * * *}"
  rm -f "$CRONTAB_DST"
  envsubst < /opt/agent-admin/crontab.tpl > "$CRONTAB_DST"
  chmod 0644 "$CRONTAB_DST"
  # Stays root:root — required by busybox crond.
  log "crontab rendered (default, root-owned)"
fi

# 4. Root-privileged sync loop: pick up heartbeatctl's staging writes.
#    Runs in the background for the lifetime of the container; crond
#    rescans mtimes every minute, so a mutation via `heartbeatctl
#    set-interval 2m` takes effect within ~1 minute (sync tick + crond
#    tick). No SIGHUP — busybox crond dies on SIGHUP.
#
#    Comparison uses byte-identity (cmp -s), not mtime. busybox sh's
#    `-nt` rounds to whole seconds, and entrypoint + heartbeatctl
#    reload can both write within the same second at container start,
#    making mtime-based detection miss the update.
(
  while true; do
    sleep 15
    if [ -f "$STAGING_CRONTAB" ] && \
       ! cmp -s "$STAGING_CRONTAB" "$CRONTAB_DST"; then
      cp "$STAGING_CRONTAB" "$CRONTAB_DST" 2>/dev/null && \
        chmod 0644 "$CRONTAB_DST" 2>/dev/null
    fi
  done
) &
log "crontab-sync loop started (pid $!)"

# 5. Start crond as ROOT so it can setgid on job dispatch.
if ! pgrep -x crond >/dev/null 2>&1; then
  crond -b -L /workspace/claude.cron.log
  log "crond started (root)"
fi

# 6. Refresh CONTAINER.md
if [ -x /opt/agent-admin/scripts/write_container_info.sh ]; then
  su-exec agent /opt/agent-admin/scripts/write_container_info.sh || log "WARN: container-info refresh failed (non-fatal)"
fi

# 7. Drop to agent and hand off to the supervisor.
log "starting services"
exec su-exec agent /opt/agent-admin/scripts/start_services.sh
