#!/usr/bin/env bash
# telegram — send message to Telegram Bot API. Always exits 0; failures
# are reported in the JSON envelope.
set -u

RUN_ID="${1:-unknown}"
STATUS="${2:-unknown}"

API_BASE="${NOTIFY_TELEGRAM_API_BASE:-https://api.telegram.org}"
TOKEN="${NOTIFY_BOT_TOKEN:-}"
CHAT="${NOTIFY_CHAT_ID:-}"

msg=$(cat)

start_ns=$(date +%s%N 2>/dev/null || date +%s000000000)

if [ -z "$TOKEN" ] || [ -z "$CHAT" ]; then
  end_ns=$(date +%s%N 2>/dev/null || date +%s000000000)
  latency_ms=$(( (end_ns - start_ns) / 1000000 ))
  printf '{"channel":"telegram","ok":false,"latency_ms":%d,"error":"missing token or chat_id"}\n' "$latency_ms"
  exit 0
fi

resp_file=$(mktemp)
http_code=$(curl -sS --max-time 10 -o "$resp_file" -w '%{http_code}' \
  -X POST "${API_BASE}/bot${TOKEN}/sendMessage" \
  --data-urlencode "chat_id=${CHAT}" \
  --data-urlencode "text=[$RUN_ID] [$STATUS] $msg" 2>/dev/null || echo "000")

end_ns=$(date +%s%N 2>/dev/null || date +%s000000000)
latency_ms=$(( (end_ns - start_ns) / 1000000 ))

if [ "$http_code" = "200" ]; then
  printf '{"channel":"telegram","ok":true,"latency_ms":%d,"error":null}\n' "$latency_ms"
else
  body=$(jq -Rs . < "$resp_file" 2>/dev/null || echo '"unreadable body"')
  printf '{"channel":"telegram","ok":false,"latency_ms":%d,"error":"HTTP %s: %s"}\n' "$latency_ms" "$http_code" "$(printf '%s' "$body" | head -c 200 | sed 's/"/\\"/g')"
fi

rm -f "$resp_file"
exit 0
