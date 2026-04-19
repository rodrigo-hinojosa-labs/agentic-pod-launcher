#!/bin/bash
# In-container supervisor. Runs as the `agent` user (entrypoint drops privs).
# Responsibilities:
#   1. Start crond so the heartbeat fires on schedule.
#   2. Before each claude launch, try to auto-install the required plugins
#      (idempotent; silently no-ops if the user hasn't /login'd yet).
#   3. Launch the persistent tmux session running claude. Enable `--channels`
#      only if the channel plugin is actually present; otherwise the plugin
#      MCP server would error at startup and spam the watchdog.
#   4. Watchdog loop: respawn tmux/claude on death, exit to Docker on
#      excessive crashes. Post-login, the first respawn auto-installs the
#      plugin and the second respawn attaches --channels.

set -euo pipefail

# Always write logs to stderr so functions that `echo` a value for
# capture (e.g. build_claude_cmd via $(...)) aren't polluted.
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [start_services] $*" >&2; }

# ── 1. Heartbeat schedule reload ──────────────────────────
# Reload the heartbeat schedule from agent.yml. Tolerate reload failure —
# the default crontab from entrypoint is still in place.
if command -v heartbeatctl >/dev/null 2>&1; then
  heartbeatctl reload || echo "WARN: heartbeatctl reload failed, using default crontab" >&2
fi

# ── 1b. Clear stale telegram pairing pending ──────────────
# The claude-plugins-official/telegram plugin persists access state
# (allowFrom + pending) across container restarts. If a `pending` code
# from a previous session survives the restart, the plugin can reply
# "Pairing required" to an already-paired sender before the in-memory
# allowFrom check catches up — visible to users as a flaky first
# message after restart. Clearing pending on each boot is safe: any
# in-flight pairing is invalidated (user just retries), already-paired
# allowFrom is preserved.
telegram_access_json="/home/agent/.claude/channels/telegram/access.json"
if [ -f "$telegram_access_json" ] && command -v jq >/dev/null 2>&1; then
  tmp_access=$(mktemp)
  if jq '.pending = {}' "$telegram_access_json" > "$tmp_access" 2>/dev/null; then
    mv "$tmp_access" "$telegram_access_json"
    chmod 0600 "$telegram_access_json"
    log "cleared stale telegram pairing pending"
  else
    rm -f "$tmp_access"
  fi
fi

# ── 2. Config ─────────────────────────────────────────────
SESSION="agent"
WORKDIR="/workspace"
CLAUDE_CONFIG_DIR_VAL="/home/agent/.claude"
REQUIRED_CHANNEL_PLUGIN="telegram@claude-plugins-official"

MAX_CRASHES=5
WINDOW=300
CRASH_COUNT=0
WINDOW_START=$(date +%s)

# ── 3. Plugin auto-install ────────────────────────────────
# `claude plugin install` requires an authenticated profile. On first boot
# (before the user runs /login inside tmux) it will fail — that's fine; we
# swallow the error and launch claude without --channels so the user can
# actually get through /login. On the next watchdog respawn (after /login),
# the install succeeds and --channels attaches automatically.
plugin_cache_dir_for() {
  # telegram@claude-plugins-official → /home/agent/.claude/plugins/cache/claude-plugins-official/telegram
  local spec="$1"
  local name="${spec%@*}"
  local marketplace="${spec#*@}"
  echo "$HOME/.claude/plugins/cache/$marketplace/$name"
}

ensure_plugin_installed() {
  local spec="$1"
  local cache
  cache=$(plugin_cache_dir_for "$spec")
  if [ -d "$cache" ]; then
    return 0
  fi
  log "attempting to install plugin: $spec"
  if CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR_VAL" claude plugin install "$spec" >/dev/null 2>&1; then
    log "plugin installed: $spec"
    return 0
  fi
  log "plugin install skipped (not authenticated yet or install failed): $spec"
  return 1
}

# Channel plugins (e.g. telegram) read their bot token from a channel-
# scoped .env at ~/.claude/channels/<channel>/.env — not from the
# workspace .env. Sync it on demand so the user never has to run
# `/telegram:configure <token>` manually.
ensure_channel_env_synced() {
  local channel="$1"
  local workspace_key="$2"
  local channel_env="$HOME/.claude/channels/${channel}/.env"

  if [ -f "$channel_env" ] && grep -q "^${workspace_key}=" "$channel_env" 2>/dev/null; then
    return 0
  fi

  local token
  token=$(grep "^${workspace_key}=" /workspace/.env 2>/dev/null | head -1 | cut -d= -f2-)
  [ -z "$token" ] && return 1

  mkdir -p "$(dirname "$channel_env")"
  umask 077
  if [ -f "$channel_env" ]; then
    # Preserve other lines, replace/add the target key.
    if grep -q "^${workspace_key}=" "$channel_env"; then
      sed -i "s|^${workspace_key}=.*|${workspace_key}=${token}|" "$channel_env"
    else
      echo "${workspace_key}=${token}" >> "$channel_env"
    fi
  else
    echo "${workspace_key}=${token}" > "$channel_env"
  fi
  chmod 0600 "$channel_env"
  log "synced ${workspace_key} from /workspace/.env → ${channel_env}"
}

# ── 4. Launch-decision helpers ────────────────────────────
# Whether /workspace/.env contains a non-empty TELEGRAM_BOT_TOKEN.
has_telegram_token() {
  [ -f /workspace/.env ] || return 1
  local val
  val=$(grep "^TELEGRAM_BOT_TOKEN=" /workspace/.env 2>/dev/null | head -1 | cut -d= -f2-)
  [ -n "$val" ]
}

# Pre-configure the user's Claude settings for headless operation:
#   - skipDangerousModePermissionPrompt=true — dismiss the one-time
#     `--dangerously-skip-permissions` warning dialog so the first launch
#     doesn't hang waiting for a y/N the user can't press (they only
#     interact via Telegram).
#   - permissions.defaultMode=auto — start every session in auto mode
#     (Claude prefers action over clarifying questions). Matches the
#     agent's intended "pick up Telegram messages and just do things"
#     behavior without the user having to run `/auto` every session.
# Both heartbeat and interactive sessions read from the same settings.json
# (heartbeat's isolated config dir symlinks this file), so setting these
# once here covers both launch paths.
pre_accept_bypass_permissions() {
  local settings="$HOME/.claude/settings.json"
  [ -f "$settings" ] || return 0
  local need_skip need_auto
  need_skip=$(jq -r '.skipDangerousModePermissionPrompt // false' "$settings" 2>/dev/null || echo "false")
  need_auto=$(jq -r '.permissions.defaultMode // ""' "$settings" 2>/dev/null || echo "")
  if [ "$need_skip" = "true" ] && [ "$need_auto" = "auto" ]; then
    return 0
  fi
  log "pre-configuring headless settings (skip-perms prompt + defaultMode=auto) in $settings"
  local tmp
  tmp=$(mktemp)
  if jq '
    .skipDangerousModePermissionPrompt = true
    | .permissions = ((.permissions // {}) + {defaultMode: "auto"})
  ' "$settings" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$settings"
  else
    rm -f "$tmp"
  fi
}

# Build the next tmux command based on current state. Three cases:
#   A. Not authenticated → bare `claude` so the user can `/login`.
#   B. Authenticated, no Telegram bot token yet → interactive wizard to
#      collect it. Writes /workspace/.env then exits; watchdog re-decides.
#   C. Authenticated and token present → `claude --channels plugin:...` with
#      the channel-scoped .env synced beforehand.
next_tmux_cmd() {
  local base="CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR_VAL claude"
  if ! ensure_plugin_installed "$REQUIRED_CHANNEL_PLUGIN"; then
    # Case A: still not authenticated (or install genuinely failed).
    echo "$base"
    return
  fi
  if ! has_telegram_token; then
    # Case B: authenticated, need the bot token.
    log "authenticated profile detected with no Telegram token — launching wizard"
    echo "/opt/agent-admin/scripts/wizard-container.sh"
    return
  fi
  # Case C: steady state with channel attached. Skip permission prompts —
  # the agent's only interactive driver in steady state is the remote
  # Telegram user (you), so an approval prompt would just stall every
  # reply. The container is the security boundary; tool calls inside it
  # can't escape to the host beyond what the bind-mount + named volume
  # already expose.
  ensure_channel_env_synced "telegram" "TELEGRAM_BOT_TOKEN" || true
  echo "$base --channels plugin:$REQUIRED_CHANNEL_PLUGIN --dangerously-skip-permissions"
}

# ── 5. tmux session lifecycle ─────────────────────────────
# After a --channels launch the plugin's MCP server (bun server.ts) should
# appear as a child of claude within a few seconds. If it doesn't, the
# session is in an unrecoverable state — typically:
#   - claude is hung on an interactive dialog (e.g. a skip-permissions
#     prompt we couldn't pre-accept),
#   - bun cached stale channel state from a previous boot, or
#   - the plugin MCP failed to init and its retry loop got wedged.
# In any of those cases the right move is to kill the session and let the
# watchdog respawn with fresh state. We give it up to 20s.
verify_channel_healthy() {
  local timeout=20
  local elapsed=0
  while [ "$elapsed" -lt "$timeout" ]; do
    if pgrep -f "bun server.ts" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  return 1
}

start_session() {
  # Pre-accept the bypass-permissions dialog unconditionally so ANY launch
  # that ends up passing --dangerously-skip-permissions boots cleanly,
  # regardless of which case next_tmux_cmd picked.
  pre_accept_bypass_permissions

  local cmd
  cmd=$(next_tmux_cmd)
  log "launching: $cmd"
  tmux kill-session -t "$SESSION" 2>/dev/null || true
  sleep 1
  tmux new-session -d -s "$SESSION" -c "$WORKDIR" "$cmd"
  tmux pipe-pane -t "$SESSION" "cat >> /workspace/claude.log"
  sleep 2
  tmux has-session -t "$SESSION" 2>/dev/null || return 1

  if [[ "$cmd" == *"--channels "* ]]; then
    if ! verify_channel_healthy; then
      log "WARN: --channels launched but bun server.ts never appeared within 20s — killing for respawn"
      tmux kill-session -t "$SESSION" 2>/dev/null || true
      return 1
    fi
    log "channel plugin healthy — bun server.ts running"
  fi
  return 0
}

# Session is "alive" when the tmux session still exists. Whatever is running
# inside it (claude, the wizard) is the supervisor's concern — this just
# tells the watchdog when it needs to re-decide. Dropping the pgrep claude
# check also prevents false positives during the Telegram wizard phase.
session_alive() {
  tmux has-session -t "$SESSION" 2>/dev/null
}

# When the session was launched with --channels, the bun plugin server
# should stay alive for the session's lifetime. If bun dies silently
# (plugin crash, upstream stdin close, etc.), claude keeps running but
# stops receiving Telegram messages — visible to the user as the agent
# ghosting. Detect this and respawn the session so a fresh plugin
# attaches.
channel_plugin_alive() {
  # Only enforce if the session was launched with --channels. We detect
  # that by checking whether any current tmux pane's command contains
  # --channels — cheaper than re-parsing the launch command.
  if pgrep -f -- "--channels " >/dev/null 2>&1; then
    pgrep -f "bun server.ts" >/dev/null 2>&1
  else
    return 0
  fi
}

log "starting tmux session '$SESSION'"
if ! start_session; then
  log "ERROR: initial tmux session failed to start"
  exit 1
fi

# ── 6. Watchdog ───────────────────────────────────────────
# Poll every 2s so the re-attach gap between Claude dying (/exit) and the
# next tmux session coming up is barely noticeable. Cheap check — just
# `tmux has-session`.
while true; do
  sleep 2
  if ! pgrep -x crond >/dev/null 2>&1; then
    echo "CRITICAL: crond died — exiting container (docker restart policy will revive)"
    exit 1
  fi
  if session_alive && channel_plugin_alive; then
    continue
  fi

  if session_alive && ! channel_plugin_alive; then
    log "channel plugin (bun server.ts) died — killing tmux for respawn"
    tmux kill-session -t "$SESSION" 2>/dev/null || true
    sleep 1
  fi

  now=$(date +%s)
  if [ $(( now - WINDOW_START )) -gt $WINDOW ]; then
    CRASH_COUNT=0
    WINDOW_START=$now
  fi
  CRASH_COUNT=$(( CRASH_COUNT + 1 ))

  if [ $CRASH_COUNT -ge $MAX_CRASHES ]; then
    log "CRITICAL: $MAX_CRASHES crashes in ${WINDOW}s — exiting for Docker to restart"
    exit 1
  fi

  log "tmux session ended (crash $CRASH_COUNT/${MAX_CRASHES} in window) — respawning"
  start_session || log "WARN: respawn failed, watchdog will retry in 2s"
done
