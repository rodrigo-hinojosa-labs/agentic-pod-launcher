#!/usr/bin/env bash
# check_token_health.sh — periodic probe of free-tier auth endpoints to
# detect expired/revoked tokens before the user notices via a broken
# Claude tool call.
#
# Invoked by:
#   - cron (hourly, scheduled in heartbeatctl::cmd_reload)
#   - heartbeatctl token-check (ad-hoc trigger)
#   - tests (with TH_*_OVERRIDE env vars + curl stub on PATH)
#
# Reads tokens directly from the environment (passed through by
# docker-compose env_file: ./.env). Does NOT touch .mcp.json or the
# Claude session — purely observational + notifier-driven.

set -u

WORKSPACE="${TH_WORKSPACE_OVERRIDE:-/workspace}"
HEARTBEAT_DIR="$WORKSPACE/scripts/heartbeat"
TH_DIR="$HEARTBEAT_DIR/token-health"
WARNINGS_LOG="$TH_DIR/warnings.jsonl"
AGENT_YML="$WORKSPACE/agent.yml"

LIB_DIR="${TH_LIB_DIR_OVERRIDE:-/opt/agent-admin/scripts/lib}"
NOTIFIERS_DIR="${TH_NOTIFIERS_DIR_OVERRIDE:-$HEARTBEAT_DIR/notifiers}"

DEDUP_SECS="${TH_DEDUP_SECS:-86400}"   # default 24h between repeated warns

# shellcheck source=/dev/null
source "$LIB_DIR/token_health.sh"

mkdir -p "$TH_DIR"

# Read NOTIFY_CHANNEL from agent.yml (the source of truth — env is for
# secrets, yaml for config). Defaults to 'none' if missing.
notify_channel="none"
if [ -f "$AGENT_YML" ] && command -v yq >/dev/null 2>&1; then
  notify_channel=$(yq -r '.notifications.channel // "none"' "$AGENT_YML" 2>/dev/null)
  [ "$notify_channel" = "null" ] && notify_channel="none"
fi

# Emit a warning/recovery via the configured notifier. Append a
# structured record to warnings.jsonl regardless (dedup history lives
# there). Notifier failures don't abort — token-health must never
# break the cron tick.
_emit() {
  local id="$1" kind="$2" transition="$3" msg="$4"
  local ts notifier
  ts=$(_th_now_iso)

  # Append to warnings.jsonl (single source of truth for history).
  jq -nc --arg ts "$ts" --arg id "$id" --arg kind "$kind" \
        --arg transition "$transition" --arg msg "$msg" \
    '{ts:$ts, id:$id, kind:$kind, transition:$transition, message:$msg}' \
    >> "$WARNINGS_LOG" 2>/dev/null || true

  # Fire the notifier. Skip when channel=none (no-op channel).
  if [ "$notify_channel" = "none" ]; then return 0; fi
  notifier="$NOTIFIERS_DIR/${notify_channel}.sh"
  if [ -x "$notifier" ]; then
    printf '%s' "$msg" | "$notifier" "token-health-$id" "$transition" \
      >/dev/null 2>&1 || true
  fi
}

# Run a single token check end-to-end:
#   1. Run probe → status http_code latency_ms [error]
#   2. Read previous state (or {} if never probed).
#   3. Decide warn/recover/silent via token_health_decide_action.
#   4. Persist new state. Append warning if applicable.
# $1 = id (logical name, used as state file slug + warning message id)
# $2 = kind (github_pat|telegram_bot|atlassian)
# $3 = probe outcome line (from probe_*)
_check_one() {
  local id="$1" kind="$2" probe_line="$3"
  local status http_code latency_ms error
  read -r status http_code latency_ms error <<<"$probe_line"
  # `read` consumes the rest of the line into the last var; reconstruct
  # the multi-word error message.
  error=$(printf '%s' "$probe_line" | awk '{for(i=4;i<=NF;i++) printf "%s%s", $i, (i==NF?"":" ")}')

  local state_file="$TH_DIR/${id}.json"
  local prev_state prev_status prev_first_failure prev_last_warned
  prev_state=$(token_health_read_state "$state_file")
  prev_status=$(printf '%s' "$prev_state" | jq -r '.status // ""')
  prev_first_failure=$(printf '%s' "$prev_state" | jq -r '.first_failure_at // ""')
  prev_last_warned=$(printf '%s' "$prev_state" | jq -r '.last_warned_at // ""')

  local now_iso now_epoch last_warn_epoch action
  now_iso=$(_th_now_iso)
  now_epoch=$(_th_now_epoch)
  last_warn_epoch=$(_th_iso_to_epoch "$prev_last_warned")

  action=$(token_health_decide_action \
    "$prev_status" "$status" "$last_warn_epoch" "$now_epoch" "$DEDUP_SECS")

  # Update consecutive_failures counter. ok / skipped reset; everything
  # else increments.
  local prev_streak streak
  prev_streak=$(printf '%s' "$prev_state" | jq -r '.consecutive_failures // 0')
  case "$status" in
    ok|skipped) streak=0 ;;
    *)          streak=$((prev_streak + 1)) ;;
  esac

  # first_failure_at sticks around for the duration of a failure run.
  local first_failure
  if [ "$status" = "ok" ] || [ "$status" = "skipped" ]; then
    first_failure=""
  elif [ -n "$prev_first_failure" ]; then
    first_failure="$prev_first_failure"
  else
    first_failure="$now_iso"
  fi

  # last_warned_at advances when we emit a warning, otherwise persists.
  local last_warned="$prev_last_warned"
  case "$action" in
    warn)    last_warned="$now_iso" ;;
    recover) last_warned="" ;;
  esac

  # Persist new state.
  local new_state
  new_state=$(jq -nc \
    --arg id "$id" \
    --arg kind "$kind" \
    --arg last_check "$now_iso" \
    --arg status "$status" \
    --arg http_code "$http_code" \
    --argjson latency_ms "$latency_ms" \
    --argjson streak "$streak" \
    --arg first_failure "$first_failure" \
    --arg last_warned "$last_warned" \
    --arg error "$error" \
    '{
      id:$id, kind:$kind, last_check:$last_check, status:$status,
      http_code:$http_code, latency_ms:$latency_ms,
      consecutive_failures:$streak,
      first_failure_at:(if $first_failure=="" then null else $first_failure end),
      last_warned_at:(if $last_warned=="" then null else $last_warned end),
      error:(if $error=="" then null else $error end)
    }')
  token_health_write_state "$state_file" "$new_state"

  # Emit (if needed). Returns 0 always — emit failures are best-effort.
  case "$action" in
    warn)
      _emit "$id" "$kind" "warn" \
        "$(token_health_format_warning "$id" "$kind" "${error:-$status}")"
      ;;
    recover)
      _emit "$id" "$kind" "recover" \
        "$(token_health_format_recovery "$id" "$kind")"
      ;;
  esac

  # Stdout summary so the cron log captures one line per check.
  printf '[%s] %s %s (%s) http=%s lat=%sms action=%s\n' \
    "$now_iso" "$id" "$status" "$kind" "$http_code" "$latency_ms" "$action"
}

# ── Main flow: probe each token kind ────────────────────────────────

_run_all() {
  # GitHub PAT — only when configured. The MCP only emits this var when
  # GITHUB_MCP_ENABLED, so absence is "feature off" not "secret missing".
  if [ -n "${GITHUB_PAT:-}" ]; then
    _check_one "github" "github_pat" "$(probe_github_pat "$GITHUB_PAT")"
  fi

  # Telegram bot — only probe if the heartbeat notifier is set to
  # telegram. has_telegram_token-style guard mirrors start_services.sh.
  if [ "$notify_channel" = "telegram" ] && [ -n "${NOTIFY_BOT_TOKEN:-}" ]; then
    _check_one "telegram" "telegram_bot" "$(probe_telegram_bot "$NOTIFY_BOT_TOKEN")"
  fi

  # Atlassian workspaces — discovered from env, one probe per workspace.
  local line name url email token
  while IFS='|' read -r name url email token; do
    [ -z "$name" ] && continue
    _check_one "atlassian-$name" "atlassian" \
      "$(probe_atlassian "$url" "$email" "$token")"
  done < <(discover_atlassian_workspaces)

  # Claude Code OAuth — file-local check, only when the cred file exists.
  # The agent's interactive claude session writes/reads ~/.claude/.credentials.json
  # on /login. Probe is read-only: it inspects expiresAt vs now and warns
  # early (≤30 min before expiry) so the user has time to /login before the
  # next heartbeat actually fails with API 401.
  local claude_cred="${TH_CLAUDE_CRED_OVERRIDE:-$HOME/.claude/.credentials.json}"
  if [ -f "$claude_cred" ]; then
    _check_one "claude_oauth" "claude_oauth" "$(probe_claude_oauth "$claude_cred")"
  fi
}

# Allow sourcing for tests without running.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  _run_all
fi
