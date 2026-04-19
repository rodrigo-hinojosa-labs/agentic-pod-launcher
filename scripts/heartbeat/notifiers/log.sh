#!/usr/bin/env bash
# log — append message to $NOTIFY_LOG_FILE (default: ./logs/notifications.log
# relative to this script). Emits the standard JSON envelope. Always exits 0.
set -u

RUN_ID="${1:-unknown}"
STATUS="${2:-unknown}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NOTIFY_LOG_FILE="${NOTIFY_LOG_FILE:-$SCRIPT_DIR/../logs/notifications.log}"

msg=$(cat)
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
start_ns=$(date +%s%N 2>/dev/null || date +%s000000000)

err="null"
ok="true"
log_dir="$(dirname "$NOTIFY_LOG_FILE")"
if ! mkdir -p "$log_dir" 2>/tmp/notify-log.err; then
  ok="false"
  sys_err=$(cat /tmp/notify-log.err)
  err=$(printf 'cannot write to %s: %s' "$NOTIFY_LOG_FILE" "$sys_err" | jq -Rs .)
elif ! printf '[%s] [%s] [%s] %s\n' "$ts" "$RUN_ID" "$STATUS" "$msg" >> "$NOTIFY_LOG_FILE" 2>/tmp/notify-log.err; then
  ok="false"
  sys_err=$(cat /tmp/notify-log.err)
  err=$(printf 'cannot write to %s: %s' "$NOTIFY_LOG_FILE" "$sys_err" | jq -Rs .)
fi
rm -f /tmp/notify-log.err

end_ns=$(date +%s%N 2>/dev/null || date +%s000000000)
latency_ms=$(( (end_ns - start_ns) / 1000000 ))

printf '{"channel":"log","ok":%s,"latency_ms":%d,"error":%s}\n' "$ok" "$latency_ms" "$err"
exit 0
