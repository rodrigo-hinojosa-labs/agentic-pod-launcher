#!/usr/bin/env bash
# Healthcheck for the local Remote Control session — distinguishes "process
# alive" from "connected and controllable" from "login expired".
# Rendered from modules/local-healthcheck.sh.tpl — do not hand-edit.
# Exit: 0=OK, 1=WARN, 2=DEGRADED. Never crashes (degrades gracefully).
set -uo pipefail   # deliberately NOT -e: evaluate every check, then report.

AGENT_NAME="{{AGENT_NAME}}"
WORKSPACE="{{DEPLOYMENT_WORKSPACE}}"
UNIT="agent-${AGENT_NAME}.service"
CONFIG_DIR="${WORKSPACE}/.state/.claude"
CREDS="${CONFIG_DIR}/.credentials.json"
# Optional notify config (NOTIFY_BOT_TOKEN, NOTIFY_CHAT_ID). Never versioned.
NOTIFY_ENV="${WORKSPACE}/.state/healthcheck-notify.env"
EXPIRY_WARN_MS=$((24 * 60 * 60 * 1000))   # warn when <24h of login remains

status="OK"
reason=""
_demote() {   # _demote LEVEL MESSAGE — keep the worst level seen
  case "$1" in
    DEGRADED) status="DEGRADED" ;;
    WARN) [ "$status" = "OK" ] && status="WARN" ;;
  esac
  reason="${reason:+$reason; }$2"
}

# 1. Process alive?
if ! systemctl is-active --quiet "$UNIT"; then
  _demote DEGRADED "unit not active"
fi

# 2. Journal signals (last 10 min): auth failure vs. a live connection.
journal=$(journalctl -u "$UNIT" --since "-10 min" --no-pager 2>/dev/null || true)
if printf '%s\n' "$journal" | grep -qE 'API Error: 401|Please run /login'; then
  _demote DEGRADED "auth error in journal (401 / please run /login)"
fi
if ! printf '%s\n' "$journal" | grep -qE 'session url|connected|polling'; then
  _demote WARN "no connection signal in journal (alive but maybe not controllable)"
fi

# 3. Credential expiry — needs jq + readable creds; degrade gracefully if not.
if command -v jq >/dev/null 2>&1 && [ -r "$CREDS" ]; then
  now_ms=$(( $(date +%s) * 1000 ))
  exp=$(jq -r '[.. | .expiresAt? // empty] | first // empty' "$CREDS" 2>/dev/null)
  if printf '%s' "$exp" | grep -qE '^[0-9]+$'; then
    if [ "$exp" -le "$now_ms" ]; then
      _demote DEGRADED "login expired"
    elif [ "$((exp - now_ms))" -le "$EXPIRY_WARN_MS" ]; then
      _demote WARN "login expiring within 24h"
    fi
  else
    _demote WARN "could not read expiresAt from credentials"
  fi
else
  _demote WARN "jq or credentials unavailable — expiry not checked"
fi

echo "agent-${AGENT_NAME} healthcheck: ${status}${reason:+ (${reason})}"

# 4. Optional notify on DEGRADED. Token NEVER on argv/journal: curl reads the
#    request (URL + token + body) from stdin via --config -.
if [ "$status" = "DEGRADED" ] && [ -r "$NOTIFY_ENV" ]; then
  # shellcheck source=/dev/null
  . "$NOTIFY_ENV"
  if [ -n "${NOTIFY_BOT_TOKEN:-}" ] && [ -n "${NOTIFY_CHAT_ID:-}" ] && command -v curl >/dev/null 2>&1; then
    printf 'url = "https://api.telegram.org/bot%s/sendMessage"\ndata-urlencode = "chat_id=%s"\ndata-urlencode = "text=agent-%s DEGRADED: %s"\n' \
      "$NOTIFY_BOT_TOKEN" "$NOTIFY_CHAT_ID" "$AGENT_NAME" "$reason" \
      | curl -s --config - >/dev/null 2>&1 || true
  fi
fi

case "$status" in
  OK)       exit 0 ;;
  WARN)     exit 1 ;;
  DEGRADED) exit 2 ;;
esac
