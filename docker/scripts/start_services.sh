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

# Plugin descriptor catalog — drives ensure_all_plugins_installed and
# pre_accept_extra_marketplaces. Image-baked at /opt/agent-admin/.
# shellcheck source=/dev/null
[ -f /opt/agent-admin/scripts/lib/plugin-catalog.sh ] \
  && source /opt/agent-admin/scripts/lib/plugin-catalog.sh

# Vault helpers (image-baked). Provides vault_ensure_paths,
# vault_seed_if_empty, vault_log_append. Sourced no-op if missing.
# shellcheck source=/dev/null
[ -f /opt/agent-admin/scripts/lib/vault.sh ] \
  && source /opt/agent-admin/scripts/lib/vault.sh

# Backup-identity helpers (image-baked). Provides identity_whitelist,
# identity_hash, identity_prepare_clone, identity_commit_and_push,
# identity_write_state. Sourced no-op if missing.
# shellcheck source=/dev/null
[ -f /opt/agent-admin/scripts/lib/backup_identity.sh ] \
  && source /opt/agent-admin/scripts/lib/backup_identity.sh

# Plugin-install retry + failure tracking (Story C). Image path first; fall
# back to the repo-relative path so host bats tests that source this script get
# retry_plugin_install_bounded / _plugin_*_failure too.
# shellcheck source=/dev/null
if [ -f /opt/agent-admin/scripts/lib/plugin-install.sh ]; then
  source /opt/agent-admin/scripts/lib/plugin-install.sh
elif [ -f "$(dirname "${BASH_SOURCE[0]}")/lib/plugin-install.sh" ]; then
  source "$(dirname "${BASH_SOURCE[0]}")/lib/plugin-install.sh"
fi

# seed_vault_if_needed — at first boot, copy the skeleton into the per-agent
# vault dir if vault.enabled + vault.seed_skeleton and the target is empty.
# Honors vault.force_reseed: when true, the existing vault is moved aside to
# `<vault_root>.backup-<timestamp>` and re-seeded; the flag is then auto-reset
# to false in agent.yml so the next boot is a no-op.
# Always (re)create the convenience symlink /home/agent/vault → real path.
seed_vault_if_needed() {
  local agent_yml="/workspace/agent.yml"
  [ -f "$agent_yml" ] || return 0
  local vault_enabled vault_path vault_seed vault_force_reseed
  vault_enabled=$(yq -r '.vault.enabled // false' "$agent_yml")
  [ "$vault_enabled" = "true" ] || return 0

  vault_path=$(yq -r '.vault.path // ".state/.vault"' "$agent_yml")
  vault_seed=$(yq -r '.vault.seed_skeleton // false' "$agent_yml")
  vault_force_reseed=$(yq -r '.vault.force_reseed // false' "$agent_yml")

  # The bind-mount maps <workspace>/.state/ → /home/agent/, so .state/.vault
  # lives at /home/agent/.vault inside the container. For non-default paths,
  # strip the .state/ prefix and rebase under /home/agent/.
  local vault_root="/home/agent/.vault"
  if [ "$vault_path" != ".state/.vault" ]; then
    vault_root="/home/agent/${vault_path#.state/}"
  fi

  if command -v vault_ensure_paths >/dev/null 2>&1; then
    vault_ensure_paths "$vault_root" || log "WARN: vault_ensure_paths failed"
  else
    mkdir -p "$vault_root"
  fi

  if [ "$vault_seed" = "true" ] && [ -d /opt/agent-admin/modules/vault-skeleton ]; then
    if [ "$vault_force_reseed" = "true" ] \
        && command -v vault_backup_and_reseed >/dev/null 2>&1; then
      log "vault: force_reseed=true; backing up existing vault and re-seeding"
      if vault_backup_and_reseed "$vault_root" /opt/agent-admin/modules/vault-skeleton; then
        log "vault: re-seed complete; backup at ${vault_root}.backup-*"
        # Auto-reset the flag so we don't re-seed every boot. Matches the
        # heartbeatctl pattern of in-place agent.yml mutations via yq -i.
        if yq -i '.vault.force_reseed = false' "$agent_yml" 2>/dev/null; then
          log "vault: reset .vault.force_reseed to false in agent.yml"
        else
          log "WARN vault: failed to reset .vault.force_reseed — set it manually"
        fi
      else
        log "WARN vault: vault_backup_and_reseed failed; skipping flag reset"
      fi
    elif command -v vault_seed_if_empty >/dev/null 2>&1; then
      vault_seed_if_empty "$vault_root" /opt/agent-admin/modules/vault-skeleton \
        && log "vault: skeleton ready at $vault_root"
    fi
  fi

  if [ -d "$vault_root" ] && [ ! -e /home/agent/vault ]; then
    ln -s "$vault_root" /home/agent/vault \
      && log "vault: symlink /home/agent/vault → $vault_root"
  fi
}

# Boot-time side effects (heartbeat schedule reload + stale telegram
# pairing cleanup + vault seed) live in this function so the script can be
# sourced in tests without firing them. Called from the runtime block below.
boot_side_effects() {
  # Reload the heartbeat schedule from agent.yml. Tolerate reload failure —
  # the default crontab from entrypoint is still in place.
  if command -v heartbeatctl >/dev/null 2>&1; then
    heartbeatctl reload || echo "WARN: heartbeatctl reload failed, using default crontab" >&2
  fi

  # The claude-plugins-official/telegram plugin persists access state
  # (allowFrom + pending) across container restarts. If a `pending` code
  # from a previous session survives the restart, the plugin can reply
  # "Pairing required" to an already-paired sender before the in-memory
  # allowFrom check catches up — visible to users as a flaky first
  # message after restart. Clearing pending on each boot is safe: any
  # in-flight pairing is invalidated (user just retries), already-paired
  # allowFrom is preserved.
  local telegram_access_json="/home/agent/.claude/channels/telegram/access.json"
  if [ -f "$telegram_access_json" ] && command -v jq >/dev/null 2>&1; then
    local tmp_access
    tmp_access=$(mktemp)
    if jq '.pending = {}' "$telegram_access_json" > "$tmp_access" 2>/dev/null; then
      mv "$tmp_access" "$telegram_access_json"
      chmod 0600 "$telegram_access_json"
      log "cleared stale telegram pairing pending"
    else
      rm -f "$tmp_access"
    fi
  fi

  # Seed the per-agent vault if configured. Idempotent — no-op once seeded.
  seed_vault_if_needed || log "WARN: seed_vault_if_needed failed (non-fatal)"
}

# ── 2. Config ─────────────────────────────────────────────
SESSION="agent"
WORKDIR="/workspace"
CLAUDE_CONFIG_DIR_VAL="/home/agent/.claude"
REQUIRED_CHANNEL_PLUGIN="telegram@claude-plugins-official"
# Official Claude plugin marketplace — single-sourced so ensure_official_marketplace
# (registration) and plugin_cache_dir_for (cache key) agree on the name. Headless
# token auth skips the interactive onboarding that used to seed it, so the
# supervisor registers it explicitly at boot.
OFFICIAL_MARKETPLACE_NAME="claude-plugins-official"
OFFICIAL_MARKETPLACE_SOURCE="anthropics/claude-plugins-official"

# Watchdog runtime state — lives on tmpfs (/tmp) so it resets every
# container start. CHANNEL_MARKER is touched by start_session after a
# successful --channels launch and read by channel_plugin_alive; this
# replaces the previous `pgrep -f -- "--channels "` heuristic which
# false-positived on any process whose argv contained the substring.
WATCHDOG_RUNTIME_DIR="/tmp/agent-watchdog"
CHANNEL_MARKER="$WATCHDOG_RUNTIME_DIR/session.channels-mode"

MAX_CRASHES=5
WINDOW=300
# Crash budget is a sliding 300s window: each entry is a unix timestamp.
# crash_budget_check (defined below) drops entries older than now-WINDOW
# and exits the watchdog when MAX_CRASHES still fit in the trailing window.
CRASH_TIMES=""

# Post-login plugin-install budget (feature 004/US2). After the /login
# credential flip the watchdog keeps retrying plugin install each tick until
# every plugin carries its .installed-ok sentinel OR this many seconds elapse —
# instead of the single post-flip attempt that races the auth-ready moment and
# gives up. Overridable (small value in tests).
PLUGIN_POSTLOGIN_BUDGET="${PLUGIN_POSTLOGIN_BUDGET:-120}"

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

ensure_plugin_installed_one() {
  local spec="$1"
  local cache
  cache=$(plugin_cache_dir_for "$spec")
  # Cache must be both present AND complete. `claude plugin install` can
  # leave a half-extracted dir (network blip, OOM, container kill mid-
  # install) — without the sentinel, every subsequent boot would re-run
  # post-install hooks on a broken cache and quietly fail-silent.
  if [ -d "$cache" ] && [ -f "$cache/.installed-ok" ]; then
    apply_plugin_post_hooks "$spec" "$cache"
    _trigger_identity_backup "post-plugin-check"
    if command -v _plugin_clear_failure >/dev/null 2>&1; then _plugin_clear_failure "$spec"; fi
    return 0
  fi
  if [ -d "$cache" ]; then
    log "plugin cache for $spec is missing .installed-ok sentinel — clearing for re-install"
    rm -rf "$cache"
  fi
  log "attempting to install plugin: $spec"

  # Story C: bounded retry + distinct not-auth/failed outcomes + a sanitized
  # residual-failure record surfaced by `agentctl doctor` and NEXT_STEPS. Falls
  # back to the legacy single-attempt path when the lib isn't sourced.
  if command -v retry_plugin_install_bounded >/dev/null 2>&1; then
    local reason rc
    reason=$(retry_plugin_install_bounded "$spec") && rc=0 || rc=$?
    case "$rc" in
      0)
        [ -d "$cache" ] && : > "$cache/.installed-ok"
        apply_plugin_post_hooks "$spec" "$cache"
        _trigger_identity_backup "post-plugin-install"
        _plugin_clear_failure "$spec"
        return 0 ;;
      2) return 1 ;;                                   # not authenticated — expected skip
      *) _plugin_record_failure "$spec" "$reason"; return 1 ;;
    esac
  fi

  # Legacy fallback (plugin-install lib unavailable).
  if CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR_VAL" claude plugin install "$spec" >/dev/null 2>&1; then
    log "plugin installed: $spec"
    [ -d "$cache" ] && : > "$cache/.installed-ok"
    apply_plugin_post_hooks "$spec" "$cache"
    _trigger_identity_backup "post-plugin-install"
    return 0
  fi
  log "plugin install skipped (not authenticated yet or install failed): $spec"
  return 1
}

# ensure_all_plugins_installed — install every plugin listed in
# /workspace/agent.yml's plugins[]. Idempotent: each plugin guards its
# cache with a .installed-ok sentinel. One plugin failing must not block
# the rest (a third-party marketplace going 404 should not stop the
# channel plugin from booting).
ensure_all_plugins_installed() {
  command -v plugin_catalog_specs >/dev/null 2>&1 || {
    # Catalog lib not loaded (image-baked path missing in tests). Fall back
    # to legacy single-plugin behavior so the channel keeps working.
    ensure_plugin_installed_one "$REQUIRED_CHANNEL_PLUGIN" || true
    return 0
  }
  local spec
  while IFS= read -r spec; do
    [ -z "$spec" ] && continue
    ensure_plugin_installed_one "$spec" || true
  done < <(plugin_catalog_specs /workspace/agent.yml)
}

# Best-effort backup trigger. Never fails the caller even if backup errors.
#
# Background + 90s outer timeout because the watchdog must NEVER block
# on backup IO. The lib already wraps each git call with timeout 60 +
# GIT_TERMINAL_PROMPT=0, but a hung TLS handshake before git starts, or
# heartbeatctl's own bookkeeping (state file write, jq), could still
# stall — this is the defense in depth. The pgrep guard avoids stacking
# multiple concurrent triggers when watchdog ticks fire while a slow
# clone is still finishing.
_trigger_identity_backup() {
  local reason="$1"
  command -v heartbeatctl >/dev/null 2>&1 || return 0
  if pgrep -f "heartbeatctl backup-identity" >/dev/null 2>&1; then
    return 0
  fi
  (
    if timeout 90 heartbeatctl backup-identity >/dev/null 2>&1; then
      log "identity backup triggered ($reason)"
    else
      log "identity backup trigger failed ($reason) — non-fatal"
    fi
  ) &
}

# apply_plugin_post_hooks SPEC CACHE — run any per-plugin post-install hook
# declared by the descriptor (modules/plugins/<id>.yml::post_install_hook).
# Fail-silent: a missing descriptor or missing hook is a no-op. Hooks that
# error must log a warning and return 0 so the plugin stays usable.
#
# Hooks currently registered:
#   telegram_typing_patch → refresh Telegram "typing..." action every ~4s
#     while Claude processes, instead of upstream's single-shot
#     sendChatAction that auto-expires at 5s.
apply_plugin_post_hooks() {
  local spec="$1"
  local cache="$2"
  command -v _plugin_catalog_id_for_spec >/dev/null 2>&1 || return 0
  local id
  id=$(_plugin_catalog_id_for_spec "$spec" 2>/dev/null) || return 0
  local hook
  hook=$(plugin_catalog_get "$id" post_install_hook 2>/dev/null)
  [ -z "$hook" ] && return 0
  case "$hook" in
    telegram_typing_patch) _hook_telegram_typing_patch "$spec" "$cache" ;;
    *) log "apply_plugin_post_hooks: unknown hook '$hook' declared by descriptor for '$spec'" ;;
  esac
  return 0
}

_hook_telegram_typing_patch() {
  local spec="$1" cache="$2"
  local patcher=/opt/agent-admin/scripts/apply_telegram_typing_patch.py
  [ -f "$patcher" ] || { log "_hook_telegram_typing_patch: $patcher missing, skipping"; return 0; }
  local server_ts
  for server_ts in "$cache"/*/server.ts; do
    [ -f "$server_ts" ] || continue
    python3 "$patcher" "$server_ts" 2>&1 | while IFS= read -r line; do
      log "$line"
    done
  done
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

  mkdir -p "$(dirname "$channel_env")" \
    || { log "ensure_channel_env_synced: mkdir failed for $(dirname "$channel_env")"; return 1; }
  umask 077
  if [ -f "$channel_env" ]; then
    # Preserve other lines, replace/add the target key. Use \x01 (SOH)
    # as the sed delimiter — control char that no plausible env value
    # (token, URL, file path) can contain, so future channels with
    # `|`/`/`/`#` in their values won't break this sync.
    if grep -q "^${workspace_key}=" "$channel_env"; then
      local SEP=$'\x01'
      sed -i "s${SEP}^${workspace_key}=.*${SEP}${workspace_key}=${token}${SEP}" "$channel_env" \
        || { log "ensure_channel_env_synced: sed failed on $channel_env"; return 1; }
    else
      echo "${workspace_key}=${token}" >> "$channel_env" \
        || { log "ensure_channel_env_synced: append failed on $channel_env"; return 1; }
    fi
  else
    echo "${workspace_key}=${token}" > "$channel_env" \
      || { log "ensure_channel_env_synced: write failed on $channel_env"; return 1; }
  fi
  chmod 0600 "$channel_env" \
    || { log "ensure_channel_env_synced: chmod failed on $channel_env"; return 1; }
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

# Whether the container env carries a non-empty CLAUDE_CODE_OAUTH_TOKEN (from
# `claude setup-token`, delivered via docker-compose env_file). When present,
# claude authenticates from the environment, so the supervisor must not fall
# back to the bare-claude /login path. NEVER echo the value (secret hygiene).
has_oauth_token() {
  [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]
}

# Pre-configure the user's Claude settings for headless operation:
#   - skipDangerousModePermissionPrompt=true — dismiss the one-time
#     `--dangerously-skip-permissions` warning dialog so the first launch
#     doesn't hang waiting for a y/N the user can't press (they only
#     interact via Telegram).
#   - permissions.defaultMode=auto — start every session in auto mode.
#     Critical: plan mode blocks ALL tool execution (Claude only proposes
#     plans, never acts), which means it never calls the telegram reply
#     MCP tool — so the agent looks like it ghosts every Telegram message.
#     auto is the only sane default for a chat-driven agent. Users who
#     want plan-style behavior for sensitive tasks can switch in-session
#     with /plan; the next message reverts to auto on session restart.
# Both heartbeat and interactive sessions read from the same settings.json
# (heartbeat's isolated config dir symlinks this file), so setting these
# once here covers both launch paths.
pre_accept_bypass_permissions() {
  local settings="$HOME/.claude/settings.json"
  # Create settings.json if absent so the headless defaults apply on first boot —
  # the bind-mount config dir may have no settings yet before claude's first run
  # (previously this early-returned and never seeded on a fresh agent).
  if [ ! -f "$settings" ]; then
    mkdir -p "$(dirname "$settings")" 2>/dev/null || true
    echo '{}' > "$settings" 2>/dev/null || return 0
  fi
  local need_skip need_mode
  need_skip=$(jq -r '.skipDangerousModePermissionPrompt // false' "$settings" 2>/dev/null || echo "false")
  need_mode=$(jq -r '.permissions.defaultMode // ""' "$settings" 2>/dev/null || echo "")
  if [ "$need_skip" = "true" ] && [ "$need_mode" = "auto" ]; then
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

# pre_seed_onboarding — pre-populate ~/.claude/.claude.json so the first-run
# onboarding (theme picker + per-project trust dialog) doesn't block the headless
# tmux session. These keys live in .claude.json, NOT settings.json (adding them
# to settings.json trips a schema error). Creates the file if absent; idempotent
# jq-merge that preserves an existing theme; fail-silent — never block boot.
pre_seed_onboarding() {
  command -v jq >/dev/null 2>&1 || return 0
  local cfg="${CLAUDE_CONFIG_DIR_VAL}/.claude.json"
  local workdir="${WORKDIR:-/workspace}"
  mkdir -p "$(dirname "$cfg")" 2>/dev/null || true
  [ -f "$cfg" ] || echo '{}' > "$cfg" 2>/dev/null || return 0
  local tmp
  tmp=$(mktemp) || return 0
  if jq --arg wd "$workdir" '
        .hasCompletedOnboarding = true
        | .theme = (.theme // "dark")
        | .projects = ((.projects // {}) | .[$wd] = ((.[$wd] // {}) + {hasTrustDialogAccepted: true}))
      ' "$cfg" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$cfg"
    chmod 0644 "$cfg" 2>/dev/null || true
  else
    rm -f "$tmp"
    log "WARN: failed to pre-seed onboarding in $cfg"
  fi
}

# pre_accept_extra_marketplaces — register every third-party marketplace
# declared by a plugin descriptor into ~/.claude/settings.json's
# extraKnownMarketplaces map. claude resolves @<marketplace> in plugin
# specs against this map, so without the registration `claude plugin
# install claude-mem@thedotmack` errors with "unknown marketplace".
#
# Idempotent: existing entries are merged (right side wins for managed
# keys, untouched for unrelated keys). Safe to re-run on every boot.
pre_accept_extra_marketplaces() {
  command -v plugin_catalog_specs >/dev/null 2>&1 || return 0
  local settings="$HOME/.claude/settings.json"
  [ -f "$settings" ] || return 0
  local specs
  specs=$(plugin_catalog_specs /workspace/agent.yml | tr '\n' ' ')
  [ -z "${specs// /}" ] && return 0
  local mkts_json
  # shellcheck disable=SC2086
  mkts_json=$(plugin_catalog_marketplaces_json $specs)
  [ "$mkts_json" = "{}" ] && return 0
  log "registering extra marketplaces: $(printf '%s' "$mkts_json" | jq -c .)"
  local tmp
  tmp=$(mktemp)
  if jq --argjson m "$mkts_json" \
    '.extraKnownMarketplaces = ((.extraKnownMarketplaces // {}) * $m)' \
    "$settings" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$settings"
    chmod 0644 "$settings"
  else
    rm -f "$tmp"
    log "WARN: failed to merge extraKnownMarketplaces into $settings"
  fi
}

# ensure_official_marketplace — register the official Claude plugin marketplace
# so @claude-plugins-official plugins (incl. the channel) can install. Headless
# token auth skips the interactive onboarding that used to seed it. Idempotent
# (guarded by `marketplace list`) and fail-silent: a slow/failed git clone over
# the VirtioFS bind-mount must never block or crash the watchdog tick.
ensure_official_marketplace() {
  command -v claude >/dev/null 2>&1 || return 0
  if CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR_VAL" claude plugin marketplace list 2>/dev/null \
       | grep -q "$OFFICIAL_MARKETPLACE_NAME"; then
    return 0   # already registered
  fi
  log "registering official marketplace: $OFFICIAL_MARKETPLACE_SOURCE"
  if CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR_VAL" \
       claude plugin marketplace add "$OFFICIAL_MARKETPLACE_SOURCE" --scope user >/dev/null 2>&1; then
    log "official marketplace registered: $OFFICIAL_MARKETPLACE_NAME"
  else
    log "WARN: official marketplace registration failed (will retry next tick)"
  fi
  return 0
}

# Build the next tmux command based on current state. Three cases:
#   A. Not authenticated → bare `claude` so the user can `/login`.
#   B. Authenticated, no Telegram bot token yet → interactive wizard to
#      collect it. Writes /workspace/.env then exits; watchdog re-decides.
#   C. Authenticated and token present → `claude --channels plugin:...` with
#      the channel-scoped .env synced beforehand.
next_tmux_cmd() {
  local base="CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR_VAL claude"

  # Best-effort: register third-party marketplaces and install all plugins
  # declared in agent.yml. Pre-/login this is mostly a no-op (plugin
  # install needs auth), but on subsequent respawns it picks up the
  # full catalog (5 defaults + any opt-ins the user selected at scaffold).
  pre_accept_extra_marketplaces
  ensure_official_marketplace
  ensure_all_plugins_installed

  if ! _channel_plugin_ready && ! has_oauth_token; then
    # Case A: channel plugin not yet usable (no /login, or install failed) AND
    # no headless token. Fall back to bare claude so the user can /login.
    # With CLAUDE_CODE_OAUTH_TOKEN present, claude is already authenticated, so
    # we never park at a /login prompt — drop through to Case B/C and let
    # ensure_all_plugins_installed keep retrying on subsequent respawns.
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
  # can't escape to the host beyond what the bind-mount already exposes.
  #
  # --continue makes claude resume the most recent session in /workspace
  # instead of starting a fresh conversation on every watchdog respawn.
  # Guarded by a session-file check: --continue errors out when no prior
  # session exists (first boot), which would trap the watchdog in a
  # respawn loop.
  ensure_channel_env_synced "telegram" "TELEGRAM_BOT_TOKEN" || true
  local continue_flag=""
  local project_dir="${CLAUDE_CONFIG_DIR_VAL}/projects/-workspace"
  if ls "$project_dir"/*.jsonl >/dev/null 2>&1; then
    continue_flag="--continue "
  fi
  echo "$base ${continue_flag}--channels plugin:$REQUIRED_CHANNEL_PLUGIN --dangerously-skip-permissions"
}

# _channel_plugin_ready — true if the channel plugin's cache exists and
# has the .installed-ok sentinel. Used by next_tmux_cmd to gate the
# Case A → Case B/C transition; replaces the old approach of using
# ensure_plugin_installed's exit code as the readiness signal (which
# coupled "did the install run" with "is the plugin usable").
_channel_plugin_ready() {
  local cache
  cache=$(plugin_cache_dir_for "$REQUIRED_CHANNEL_PLUGIN")
  [ -d "$cache" ] && [ -f "$cache/.installed-ok" ]
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
  pre_seed_onboarding

  local cmd
  cmd=$(next_tmux_cmd)
  log "launching: $cmd"

  # Reset the channel marker — a fresh launch may or may not be a
  # --channels session, depending on which case next_tmux_cmd picked.
  # Marker is set only after verify_channel_healthy succeeds below.
  mkdir -p "$WATCHDOG_RUNTIME_DIR" 2>/dev/null || true
  rm -f "$CHANNEL_MARKER"

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
    : > "$CHANNEL_MARKER"
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
  # Marker file is touched by start_session only after a successful
  # --channels launch (verify_channel_healthy passed). This replaces
  # the old `pgrep -f -- "--channels "` heuristic, which matched any
  # process with `--channels ` in argv (including the watchdog itself
  # if it spawned subshells with that substring).
  if [ -f "$CHANNEL_MARKER" ]; then
    pgrep -f "bun server.ts" >/dev/null 2>&1
  else
    return 0
  fi
}

# crash_budget_check NOW CURRENT_TIMES → prints surviving timestamps and
# returns 0 if the budget still has room (count < MAX_CRASHES), else 1.
# Sliding window: drops entries older than NOW-WINDOW. Pure: caller
# captures stdout, checks exit code, decides whether to exit.
crash_budget_check() {
  local now="$1"
  local current="$2"
  local cutoff=$(( now - WINDOW ))
  local kept=""
  local count=0
  local t
  for t in $current; do
    if [ "$t" -gt "$cutoff" ]; then
      kept="$kept $t"
      count=$(( count + 1 ))
    fi
  done
  printf '%s' "$kept"
  [ "$count" -lt "$MAX_CRASHES" ]
}

# Bridge watchdog: detects the silent-stuck case where bun is alive
# and polling Telegram, but its MCP notifications aren't reaching
# Claude's session (an upstream plugin bug). The channel_plugin_alive
# check above only catches cases where bun itself died; this watchdog
# covers the much more common "bun alive, bridge broken" state.
#
# Mechanic:
#   - Peek the most recent Telegram message via getUpdates with a
#     negative offset (safe, does NOT confirm/claim the message so
#     bun's own polling is unaffected — documented in Telegram Bot
#     API: "Negative values of offset retrieve the last updates not
#     confirming any").
#   - If the message is 20-300s old and its text does not appear
#     anywhere in Claude's tmux pane AND Claude is not currently
#     processing something (no spinner), count as suspicious.
#   - After 3 consecutive suspicions (~15s of consistent stuck state)
#     kick the session. The existing respawn logic brings up a fresh
#     bun + claude and the bridge is restored.
#   - 60s cooldown after each kick prevents a stuck loop from
#     restarting too fast.
#
# Skipped whenever: Claude is busy (has a spinner in the pane), the
# latest message is very fresh (<20s, bun may not have polled yet),
# or the latest message is very old (>300s, already water under the
# bridge).
# NOTE: A bridge_watchdog auto-kicker was attempted here (commit 3c5465f /
# fcb6744) but reverted. The detection heuristic (tmux pane scrape +
# Telegram API peek) produced false positives that killed the session
# every ~2 minutes during normal operation, with the kick log lines
# silently lost from the backgrounded subshell's stderr — making the
# behavior look like Claude was crashing on its own.
#
# For now the silent-stuck bridge case (bun alive, MCP notifications
# dropped before reaching Claude) requires manual recovery:
#
#   docker exec -u agent <agent> heartbeatctl kick-channel
#
# channel_plugin_alive (above) still handles the case where bun
# itself dies; that one is reliably detectable from outside.

# Auth banner detect: every 60s, scan the tail of /workspace/claude.log
# for "Please run /login" / "API Error: 401" / "authentication_error".
# When detected on a fresh run (or after 24h of persistence), emit a
# warning via the configured notifier so the user finds out within a
# minute instead of waiting for the next heartbeat tick (up to 30 min).
# State file at /workspace/scripts/heartbeat/auth-status.json with shape:
#   {status: "detected"|"ok", first_seen_at: <iso>, last_warned_at: <iso|null>}
# Reuses the same iso↔epoch helpers and notifier dispatch as the
# heartbeat. Idempotent: repeated detections within 24h stay silent.
_last_auth_check=0

_auth_banner_iso_now() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
_auth_banner_iso_to_epoch() {
  local ts="$1"
  [ -z "$ts" ] || [ "$ts" = "null" ] && return 0
  if date -d "$ts" +%s 2>/dev/null; then return 0; fi
  date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null || true
}

_emit_auth_warning() {
  local kind="$1"   # "detected" or "recovered"
  local agent_yml="${AUTH_BANNER_AGENT_YML_OVERRIDE:-/workspace/agent.yml}"
  local notifiers_dir="${AUTH_BANNER_NOTIFIERS_OVERRIDE:-/workspace/scripts/heartbeat/notifiers}"
  local channel="none"
  if [ -f "$agent_yml" ] && command -v yq >/dev/null 2>&1; then
    channel=$(yq -r '.notifications.channel // "none"' "$agent_yml" 2>/dev/null)
    [ "$channel" = "null" ] && channel="none"
  fi
  [ "$channel" = "none" ] && return 0
  local notifier="${notifiers_dir}/${channel}.sh"
  [ -x "$notifier" ] || return 0
  local msg
  if [ "$kind" = "recovered" ]; then
    msg="[auth-banner] Claude OAuth recuperado — la sesión ya no muestra 'Please run /login'."
  else
    msg="[auth-banner] ⚠ Claude Code muestra 'Please run /login' (API 401). Conéctate: agentctl attach → /login → completa OAuth desde el browser. Mientras tanto el heartbeat reporta error_kind=auth_failed."
  fi
  printf '%s' "$msg" | "$notifier" "auth-banner-${kind}" "warn" >/dev/null 2>&1 || true
}

_write_auth_state() {
  local file="$1" status="$2" first_seen="$3" last_warned="$4"
  local dir tmp
  dir=$(dirname "$file")
  mkdir -p "$dir" 2>/dev/null || true
  tmp=$(mktemp "$dir/.auth-status.json.XXXXXX") || return 0
  jq -n \
    --arg status "$status" \
    --arg first "$first_seen" \
    --arg last "$last_warned" \
    '{status:$status,
      first_seen_at:(if $first == "" then null else $first end),
      last_warned_at:(if $last == "" then null else $last end)}' \
    > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
  mv "$tmp" "$file" 2>/dev/null || rm -f "$tmp"
}

_check_auth_banner() {
  local now
  now=$(date +%s)
  if [ $((now - _last_auth_check)) -lt 60 ]; then
    return 0
  fi
  _last_auth_check=$now

  local claude_log="${AUTH_BANNER_LOG_OVERRIDE:-/workspace/claude.log}"
  local state_file="${AUTH_BANNER_STATE_OVERRIDE:-/workspace/scripts/heartbeat/auth-status.json}"
  [ -f "$claude_log" ] || return 0

  local detected=0
  if tail -n 50 "$claude_log" 2>/dev/null \
       | grep -qiE 'Please run /login|API Error: 401|authentication_error'; then
    detected=1
  fi

  local prev_status="" prev_warned="" prev_first=""
  if [ -f "$state_file" ]; then
    prev_status=$(jq -r '.status // ""'         "$state_file" 2>/dev/null)
    prev_warned=$(jq -r '.last_warned_at // ""' "$state_file" 2>/dev/null)
    prev_first=$(jq -r '.first_seen_at // ""'   "$state_file" 2>/dev/null)
  fi
  [ "$prev_status"  = "null" ] && prev_status=""
  [ "$prev_warned"  = "null" ] && prev_warned=""
  [ "$prev_first"   = "null" ] && prev_first=""

  if [ "$detected" -eq 1 ]; then
    local should_warn=0
    if [ "$prev_status" != "detected" ]; then
      # Transition ok→detected (or first-ever detection) — warn.
      should_warn=1
    elif [ -n "$prev_warned" ]; then
      local last_epoch
      last_epoch=$(_auth_banner_iso_to_epoch "$prev_warned")
      if [ -n "$last_epoch" ] && [ $((now - last_epoch)) -gt 86400 ]; then
        should_warn=1
      fi
    else
      should_warn=1
    fi

    local first_at iso_now
    iso_now=$(_auth_banner_iso_now)
    first_at="$prev_first"
    [ -z "$first_at" ] && first_at="$iso_now"

    if [ "$should_warn" -eq 1 ]; then
      _emit_auth_warning "detected"
      log "auth-banner detected in claude.log — warning emitted via notifier"
      _write_auth_state "$state_file" "detected" "$first_at" "$iso_now"
    else
      _write_auth_state "$state_file" "detected" "$first_at" "$prev_warned"
    fi
  else
    # Banner not present. If we previously detected, this is a recovery.
    if [ "$prev_status" = "detected" ]; then
      _emit_auth_warning "recovered"
      log "auth-banner cleared in claude.log — recovery emitted via notifier"
      _write_auth_state "$state_file" "ok" "" ""
    fi
  fi
}

# _identity_backup_fork_configured → 0 if agent.yml carries a scaffold.fork.url
# (a backup target exists), non-zero otherwise. Mirrors heartbeatctl::_bi_run's
# fork-presence guard so a fork-less agent never attempts a backup. The
# agent.yml path is overridable for host tests (cf. AUTH_BANNER_AGENT_YML_OVERRIDE).
_identity_backup_fork_configured() {
  local agent_yml="${IDENTITY_BACKUP_AGENT_YML_OVERRIDE:-/workspace/agent.yml}"
  local fork_url
  fork_url=$(yq '.scaffold.fork.url // ""' "$agent_yml" 2>/dev/null)
  [ "$fork_url" = "null" ] && fork_url=""
  [ -n "$fork_url" ]
}

# Backup-identity: every 60s, compare identity hash vs last-backup hash.
# Fires the primitive when they differ. Throttled to avoid bursts.
_last_backup_check=0
_check_identity_backup() {
  local now
  now=$(date +%s)
  if [ $((now - _last_backup_check)) -lt 60 ]; then
    return 0
  fi
  _last_backup_check=$now

  # Fork-less agents have nowhere to back up to — skip the hash check and the
  # per-tick trigger entirely so the supervisor log stays quiet (FR-G1). This
  # must come before any hashing or _trigger_identity_backup call.
  _identity_backup_fork_configured || return 0

  if [ -f /opt/agent-admin/scripts/lib/backup_identity.sh ]; then
    # shellcheck source=/dev/null
    source /opt/agent-admin/scripts/lib/backup_identity.sh
  else
    return 0
  fi

  local state_dir="/workspace/.state"
  [ -d "$state_dir" ] || return 0

  local current last state_file recipient
  state_file="/workspace/scripts/heartbeat/identity-backup.json"
  recipient=$(yq '.backup.identity.recipient // ""' /workspace/agent.yml 2>/dev/null)
  [ "$recipient" = "null" ] && recipient=""
  current=$(identity_hash "$state_dir" "$recipient" 2>/dev/null || echo "")
  last=$(identity_last_hash "$state_file" 2>/dev/null || echo "")

  [ -z "$current" ] && return 0
  if [ "$current" != "$last" ]; then
    _trigger_identity_backup "watchdog-hash-change"
  fi
}

# ── Auth-flip detection (Story A) ─────────────────────────
# After /login, claude writes the OAuth credential file. In the bare-claude
# (Case A) state the session is alive and channel_plugin_alive returns OK
# (no channel marker), so the watchdog `continue`s forever and never respawns
# — meaning the post-login plugin install + --channels attach never happen
# unless the operator manually /exits. This detects the absent->present
# credential flip and kicks the session so the watchdog respawns it (which
# re-runs ensure_all_plugins_installed + re-decides next_tmux_cmd). File
# existence only — NO tmux-pane scraping (CLAUDE.md forbids it).
_auth_marker_file() {
  echo "${AUTH_MARKER_OVERRIDE:-$CLAUDE_CONFIG_DIR_VAL/.credentials.json}"
}

# -1 = baseline not yet established; the first tick only records state so an
# agent that boots already-authenticated is never needlessly kicked.
_prev_auth_present=-1
# Post-login plugin-install retry deadline (unix ts). 0 = not armed. Armed by
# _check_auth_flip on the credential flip; cleared by _post_login_plugin_retry
# on completion or budget exhaustion.
_post_login_deadline=0
_check_auth_flip() {
  # Env-token auth (CLAUDE_CODE_OAUTH_TOKEN) writes no .credentials.json, so the
  # agent is already authenticated at baseline — pin _prev_auth_present so the
  # absent->present file flip can never fire a spurious kill-session.
  if has_oauth_token; then _prev_auth_present=1; return 0; fi
  local present=0
  if [ -f "$(_auth_marker_file)" ]; then present=1; fi

  if [ "$_prev_auth_present" -eq -1 ]; then
    _prev_auth_present=$present
    return 0
  fi

  if [ "$_prev_auth_present" -eq 0 ] && [ "$present" -eq 1 ]; then
    log "auth credential appeared (/login complete) — kicking session to install plugins + attach channel"
    # Arm the post-login retry budget so the watchdog keeps trying the install
    # past this single kick until the profile is operative (FR-003/FR-005).
    _post_login_deadline=$(( $(date +%s) + PLUGIN_POSTLOGIN_BUDGET ))
    tmux kill-session -t "$SESSION" 2>/dev/null || true
  fi
  _prev_auth_present=$present
}

# _all_plugins_installed — 0 only when every catalog plugin carries its
# .installed-ok sentinel. Drives _post_login_plugin_retry's completion check.
# Falls back to the required channel plugin's readiness when the catalog lib
# isn't loaded (host tests / minimal images).
_all_plugins_installed() {
  if command -v plugin_catalog_specs >/dev/null 2>&1; then
    local spec cache
    while IFS= read -r spec; do
      [ -z "$spec" ] && continue
      cache=$(plugin_cache_dir_for "$spec")
      { [ -d "$cache" ] && [ -f "$cache/.installed-ok" ]; } || return 1
    done < <(plugin_catalog_specs /workspace/agent.yml)
    return 0
  fi
  _channel_plugin_ready
}

# _post_login_plugin_retry — non-blocking, tick-based post-login install retry
# (feature 004/US2). Called once per watchdog tick. While the deadline is armed
# and not every plugin is installed, it re-runs the idempotent install (each
# attempt returns in ~1s, so the 2s poll is not starved). On completion it kicks
# the session exactly once (so the respawn attaches --channels) and clears the
# deadline; on budget exhaustion it clears the deadline WITHOUT re-kicking
# (residual failures were already recorded by ensure_plugin_installed_one for
# `agentctl doctor`). No per-tick re-kick → the crash budget (5/300s) is safe.
_post_login_plugin_retry() {
  [ "${_post_login_deadline:-0}" -eq 0 ] && return 0

  if _all_plugins_installed; then
    log "post-login: all plugins installed — kicking session once to attach --channels"
    tmux kill-session -t "$SESSION" 2>/dev/null || true
    _post_login_deadline=0
    return 0
  fi

  local now
  now=$(date +%s)
  if [ "$now" -ge "$_post_login_deadline" ]; then
    log "post-login: plugin-install budget (${PLUGIN_POSTLOGIN_BUDGET}s) exhausted — residual failures left for agentctl doctor"
    _post_login_deadline=0
    return 0
  fi

  ensure_all_plugins_installed || true
  return 0
}

# ── 6. Watchdog ───────────────────────────────────────────
# Poll every 2s so the re-attach gap between Claude dying (/exit) and the
# next tmux session coming up is barely noticeable. Cheap check — just
# `tmux has-session`.
_run_watchdog() {
  while true; do
    sleep 2
    if ! pgrep -x crond >/dev/null 2>&1; then
      echo "CRITICAL: crond died — exiting container (docker restart policy will revive)"
      exit 1
    fi

    # Best-effort backup check (throttled internally to one per 60s).
    _check_identity_backup

    # Best-effort auth-banner check (throttled internally to one per 60s).
    # Detects when claude.log shows the "Please run /login" banner and
    # emits a warning via the configured notifier — orthogonal to the
    # heartbeat-based detection (which has up to 30 min latency).
    _check_auth_banner

    # Story A: detect the unauthenticated->authenticated credential flip
    # (operator completed /login) and kick the session so the watchdog
    # respawns it — installing plugins + attaching --channels without a
    # manual /exit or restart. File-existence only; no tmux-pane scraping.
    _check_auth_flip

    # Feature 004/US2: keep retrying the post-login plugin install (bounded by
    # PLUGIN_POSTLOGIN_BUDGET) until every plugin carries .installed-ok, then
    # kick once so the respawn attaches --channels. Non-blocking (one pass per
    # tick); no per-tick re-kick, so the crash budget stays untouched.
    _post_login_plugin_retry

    if session_alive && channel_plugin_alive; then
      continue
    fi

    if session_alive && ! channel_plugin_alive; then
      log "channel plugin (bun server.ts) died — killing tmux for respawn"
      tmux kill-session -t "$SESSION" 2>/dev/null || true
      sleep 1
    fi

    now=$(date +%s)
    CRASH_TIMES="$(crash_budget_check "$now" "$CRASH_TIMES $now")" || {
      log "CRITICAL: $MAX_CRASHES crashes in ${WINDOW}s — exiting for Docker to restart"
      exit 1
    }

    # Recount for the log line — cheap, runs at most every 2s.
    local crash_count=0
    for _t in $CRASH_TIMES; do crash_count=$(( crash_count + 1 )); done
    log "tmux session ended (crash $crash_count/${MAX_CRASHES} in trailing ${WINDOW}s) — respawning"
    start_session || log "WARN: respawn failed, watchdog will retry in 2s"
  done
}

main() {
  boot_side_effects

  log "starting tmux session '$SESSION'"
  if ! start_session; then
    log "ERROR: initial tmux session failed to start"
    exit 1
  fi

  _run_watchdog
}

# Tests source this script with START_SERVICES_NO_RUN=1 set so they can
# call functions (notably crash_budget_check) in isolation without
# triggering the runtime watchdog loop. The BASH_SOURCE guard provides
# the same protection for `source` cases that don't set the env var.
if [ "${START_SERVICES_NO_RUN:-0}" != "1" ] && [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
