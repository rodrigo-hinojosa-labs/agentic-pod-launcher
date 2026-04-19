#!/usr/bin/env bash
# heartbeat — one tick of the scheduled agent heartbeat.
# Emits a line to logs/runs.jsonl and updates state.json atomically.

set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
AGENT_NAME="$(basename "$WORKSPACE_DIR")"
CONF_FILE="$SCRIPT_DIR/heartbeat.conf"
LOG_DIR="$SCRIPT_DIR/logs"
RUNS_FILE="$LOG_DIR/runs.jsonl"
STATE_FILE="$SCRIPT_DIR/state.json"
SESSION_LOG_DIR="$LOG_DIR/sessions"
ROTATE_THRESHOLD_BYTES="${ROTATE_THRESHOLD_BYTES:-10485760}"

STATE_LIB="${HEARTBEAT_STATE_LIB:-/opt/agent-admin/scripts/lib/state.sh}"
# shellcheck source=/dev/null
source "$STATE_LIB"

mkdir -p "$LOG_DIR" "$SESSION_LOG_DIR"

if [ ! -f "$CONF_FILE" ]; then
  echo "[heartbeat] ERROR: $CONF_FILE not found" >&2
  exit 1
fi
# shellcheck source=/dev/null
source "$CONF_FILE"

HEARTBEAT_TIMEOUT="${HEARTBEAT_TIMEOUT:-300}"
HEARTBEAT_RETRIES="${HEARTBEAT_RETRIES:-1}"
HEARTBEAT_PROMPT="${HEARTBEAT_PROMPT:-Check status and report}"
NOTIFY_CHANNEL="${NOTIFY_CHANNEL:-none}"
HEARTBEAT_CRON="${HEARTBEAT_CRON:-}"
TRIGGER="${HEARTBEAT_TRIGGER:-cron}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --prompt) HEARTBEAT_PROMPT="$2"; shift 2 ;;
    --trigger) TRIGGER="$2"; shift 2 ;;
    *) shift ;;
  esac
done

iso8601() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now_ms() { date +%s%N 2>/dev/null | cut -c1-13 || echo $(( $(date +%s) * 1000 )); }

is_prior_session_alive() {
  tmux list-sessions 2>/dev/null | grep -q "^${AGENT_NAME}-hb-"
}

run_id=$(gen_run_id)
session="${AGENT_NAME}-hb-${run_id}"
ts=$(iso8601)
started_ms=$(now_ms)

notifier_json='{"channel":"none","ok":true,"latency_ms":0,"error":null}'

invoke_notifier() {
  local status="$1" msg="$2"
  local path="$SCRIPT_DIR/notifiers/${NOTIFY_CHANNEL}.sh"
  [ -x "$path" ] || path="$SCRIPT_DIR/notifiers/none.sh"
  local out
  out=$(printf '%s' "$msg" | bash "$path" "$run_id" "$status" 2>/dev/null) || out='{"channel":"error","ok":false,"latency_ms":0,"error":"notifier script failed"}'
  if printf '%s' "$out" | jq empty >/dev/null 2>&1; then
    notifier_json="$out"
  else
    notifier_json='{"channel":"error","ok":false,"latency_ms":0,"error":"notifier emitted non-JSON"}'
  fi
}

run_claude_session() {
  local attempt="$1"
  local sess="${session}-a${attempt}"
  local log_file="$SESSION_LOG_DIR/${sess}.log"
  local start=$(date +%s)

  if ! command -v claude >/dev/null 2>&1; then
    echo "claude not found" > "$log_file"
    claude_exit_code=-2
    duration_ms=$(( ($(date +%s) - start) * 1000 ))
    return 1
  fi

  tmux new-session -d -s "$sess" -c "$WORKSPACE_DIR" \
    "claude --print \"$HEARTBEAT_PROMPT\" > \"$log_file\" 2>&1; echo HEARTBEAT_DONE >> \"$log_file\""

  local waited=0
  while [ "$waited" -lt "$HEARTBEAT_TIMEOUT" ]; do
    if ! tmux has-session -t "$sess" 2>/dev/null; then break; fi
    if [ -f "$log_file" ] && grep -q HEARTBEAT_DONE "$log_file" 2>/dev/null; then break; fi
    sleep 1; waited=$(( waited + 1 ))
  done

  duration_ms=$(( ($(date +%s) - start) * 1000 ))

  if [ "$waited" -ge "$HEARTBEAT_TIMEOUT" ]; then
    tmux kill-session -t "$sess" 2>/dev/null || true
    claude_exit_code=-1
    return 2
  fi

  if grep -q HEARTBEAT_DONE "$log_file" 2>/dev/null; then
    tmux kill-session -t "$sess" 2>/dev/null || true
    claude_exit_code=0
    return 0
  fi

  tmux kill-session -t "$sess" 2>/dev/null || true
  claude_exit_code=1
  return 1
}

status="error"
attempt=0
duration_ms=0
claude_exit_code=0

if is_prior_session_alive; then
  status="skipped"
  claude_exit_code=0
  duration_ms=0
else
  max_attempts=$(( HEARTBEAT_RETRIES + 1 ))
  for attempt in $(seq 1 "$max_attempts"); do
    rc=0
    run_claude_session "$attempt" || rc=$?
    if [ "$rc" -eq 0 ]; then status="ok"; break
    elif [ "$rc" -eq 2 ]; then status="timeout"
    else status="error"
    fi
    [ "$attempt" -lt "$max_attempts" ] && sleep 5
  done
fi

case "$status" in
  ok)
    notify_this=true
    if [ -f "$STATE_FILE" ] && [ "${NOTIFY_SUCCESS_EVERY:-1}" -gt 1 ]; then
      prev_ok=$(jq -r '.counters.ok // 0' "$STATE_FILE" 2>/dev/null || echo 0)
      [ $(( (prev_ok + 1) % NOTIFY_SUCCESS_EVERY )) -ne 0 ] && notify_this=false
    fi
    [ "$notify_this" = true ] && invoke_notifier "ok" "Heartbeat OK ($TRIGGER) — ${duration_ms}ms"
    ;;
  timeout) invoke_notifier "timeout" "Heartbeat TIMEOUT (${duration_ms}ms) — check $session log" ;;
  error)   invoke_notifier "error"   "Heartbeat ERROR (exit=$claude_exit_code)" ;;
  skipped) : ;;
esac

prompt_json=$(printf '%s' "$HEARTBEAT_PROMPT" | jq -Rs .)
line=$(jq -cn \
  --arg ts "$ts" --arg run_id "$run_id" --arg trigger "$TRIGGER" \
  --arg status "$status" --argjson attempt "$attempt" \
  --argjson duration_ms "$duration_ms" \
  --argjson cec "$claude_exit_code" \
  --arg sess "$session" \
  --argjson notifier "$notifier_json" \
  '{ts:$ts, run_id:$run_id, trigger:$trigger, status:$status, attempt:$attempt,
    duration_ms:$duration_ms, claude_exit_code:$cec,
    prompt:'"$prompt_json"',
    tmux_session:$sess, notifier:$notifier}')

rotate_runs_jsonl "$RUNS_FILE" "$ROTATE_THRESHOLD_BYTES"
append_run_line "$RUNS_FILE" "$line"

prev_counters=$(jq -c '.counters // {total_runs:0,ok:0,timeout:0,error:0,consecutive_failures:0,success_rate_24h:null}' "$STATE_FILE" 2>/dev/null || echo '{"total_runs":0,"ok":0,"timeout":0,"error":0,"consecutive_failures":0,"success_rate_24h":null}')

new_counters=$(jq -cn \
  --argjson prev "$prev_counters" \
  --arg status "$status" \
  '{
     total_runs: ($prev.total_runs + (if $status == "skipped" then 0 else 1 end)),
     ok:        ($prev.ok + (if $status == "ok" then 1 else 0 end)),
     timeout:   ($prev.timeout + (if $status == "timeout" then 1 else 0 end)),
     error:     ($prev.error + (if $status == "error" then 1 else 0 end)),
     consecutive_failures:
       (if $status == "ok" or $status == "skipped" then 0
        else ($prev.consecutive_failures + 1) end),
     success_rate_24h: null
   }')

# success_rate_24h computation: tail runs.jsonl, filter last 24h, ratio of ok
if [ -f "$RUNS_FILE" ]; then
  cutoff=$(date -u -d '24 hours ago' +%s 2>/dev/null || date -v-24H -u +%s)
  total24=$(awk -v c="$cutoff" 'BEGIN{n=0}
    { if (match($0,/"ts":"[^"]+"/)) {
        t=substr($0,RSTART+6,RLENGTH-7);
        gsub(/[-:TZ]/," ",t);
        cmd="date -u -d \""t"\" +%s 2>/dev/null || date -u -j -f \"%Y %m %d %H %M %S\" \""t"\" +%s 2>/dev/null";
        cmd | getline epoch; close(cmd);
        if (epoch+0 >= c) n++
      }
    } END{print n}' "$RUNS_FILE")
  ok24=$(awk -v c="$cutoff" 'BEGIN{n=0}
    /"status":"ok"/ { if (match($0,/"ts":"[^"]+"/)) {
        t=substr($0,RSTART+6,RLENGTH-7);
        gsub(/[-:TZ]/," ",t);
        cmd="date -u -d \""t"\" +%s 2>/dev/null || date -u -j -f \"%Y %m %d %H %M %S\" \""t"\" +%s 2>/dev/null";
        cmd | getline epoch; close(cmd);
        if (epoch+0 >= c) n++
      }
    } END{print n}' "$RUNS_FILE")
  if [ "$total24" -gt 0 ]; then
    rate=$(LC_NUMERIC=C awk -v o="$ok24" -v t="$total24" 'BEGIN{printf "%.4f", o/t}')
    new_counters=$(printf '%s' "$new_counters" | jq -c --argjson r "$rate" '.success_rate_24h=$r')
  fi
fi

state=$(jq -cn \
  --arg schema 1 \
  --arg interval "${HEARTBEAT_INTERVAL:-}" \
  --arg cron "$HEARTBEAT_CRON" \
  --arg prompt "$HEARTBEAT_PROMPT" \
  --arg channel "$NOTIFY_CHANNEL" \
  --argjson last_run "$line" \
  --argjson counters "$new_counters" \
  --arg enabled "${HEARTBEAT_ENABLED:-true}" \
  --arg updated_at "$(iso8601)" \
  '{schema:1, enabled:($enabled=="true"), interval:$interval, cron:$cron,
    prompt:$prompt, notifier_channel:$channel,
    last_run:$last_run, counters:$counters,
    next_run_estimate:null,
    crond:{alive:null,pid:null},
    updated_at:$updated_at}')

write_state_json "$STATE_FILE" "$state"

ls -1t "$SESSION_LOG_DIR"/*.log 2>/dev/null | tail -n +21 | xargs rm -f 2>/dev/null || true

exit 0
