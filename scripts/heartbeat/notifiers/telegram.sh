#!/usr/bin/env bash
notify_telegram() {
  local msg="$1"
  [ -z "${NOTIFY_BOT_TOKEN:-}" ] && return 0
  [ -z "${NOTIFY_CHAT_ID:-}" ] && return 0
  curl -s -X POST "https://api.telegram.org/bot${NOTIFY_BOT_TOKEN}/sendMessage" \
    -d chat_id="${NOTIFY_CHAT_ID}" \
    -d text="$msg" > /dev/null 2>&1 || true
}
