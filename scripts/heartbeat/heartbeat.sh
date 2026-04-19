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
HEARTBEAT_PROMPT="${HEARTBEAT_PROMPT:-Status check — return a short plain-text report (uptime, notable issues). No tool use; your stdout is forwarded verbatim to the notifier.}"
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

# sh_sq — wrap a string in single-quotes safely for shell consumption by
# replacing every embedded ' with '\''. The result is a single token that
# any POSIX shell will pass verbatim to its argv. Verified with round-trip
# eval against embedded single quotes, double quotes, backslashes, and $.
sh_sq() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

is_prior_session_alive() {
  tmux list-sessions 2>/dev/null | grep -q "^${AGENT_NAME}-hb-"
}

run_id=$(gen_run_id)
session="${AGENT_NAME}-hb-${run_id}"
ts=$(iso8601)
last_session_log=""

notifier_json='{"channel":"none","ok":true,"latency_ms":0,"error":null}'

# claude_output FILE → prints the model's response from a session log,
# stripping the HEARTBEAT_DONE sentinel and capping length so it fits
# typical notifier constraints (Telegram: 4096 chars, log file: any).
# Falls back to a minimal OK line if the log is missing or empty.
claude_output() {
  local file="${1:-}"
  local max_chars="${2:-3500}"
  if [ -z "$file" ] || [ ! -f "$file" ]; then
    printf 'Heartbeat OK (%s) — %dms (no output)\n' "$TRIGGER" "$duration_ms"
    return
  fi
  # Drop the sentinel, drop any ANSI escapes that claude --print may emit
  # under a tmux-allocated TTY, trim trailing whitespace, cap length.
  local body
  body=$(grep -v '^HEARTBEAT_DONE$' "$file" \
    | sed $'s/\x1b\\[[0-9;?]*[a-zA-Z]//g' \
    | awk 'NF || p {print; p=1}' \
    | sed -e :a -e '/^[[:space:]]*$/{$d;N;ba' -e '}')
  if [ -z "$body" ]; then
    printf 'Heartbeat OK (%s) — %dms (empty output)\n' "$TRIGGER" "$duration_ms"
    return
  fi
  if [ "${#body}" -gt "$max_chars" ]; then
    body="${body:0:$max_chars}…"
  fi
  printf '%s\n' "$body"
}

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

# ensure_heartbeat_config_dir — prepare an isolated CLAUDE_CONFIG_DIR for
# the ephemeral heartbeat session so it never touches the interactive
# agent session (its channels/bot.pid, session history, MCP auth cache,
# etc.). We symlink the files that must be shared (OAuth credentials,
# user settings, plugin cache) and give the heartbeat its own empty
# channels/sessions/cache dirs. Idempotent — re-running fixes missing
# links but never clobbers existing real files.
ensure_heartbeat_config_dir() {
  local src="$HOME/.claude"
  local dst="$HOME/.claude-heartbeat"
  [ -d "$src" ] || return 1
  mkdir -p "$dst"
  # Share auth, config, user-level settings, plugin cache.
  local f
  for f in .credentials.json .claude.json settings.json plugins; do
    if [ -e "$src/$f" ]; then
      ln -sfn "$src/$f" "$dst/$f"
    fi
  done
  # Isolate runtime state. An empty dir per-heartbeat ensures no cross-
  # contamination with the interactive agent's live channels plugin
  # (bot.pid, access.json).
  mkdir -p "$dst/channels" "$dst/sessions" "$dst/cache"
  printf '%s\n' "$dst"
}

run_claude_session() {
  local attempt="$1"
  local sess="${session}-a${attempt}"
  local log_file="$SESSION_LOG_DIR/${sess}.log"
  # Track the last session's log path globally so the notifier can
  # forward claude's actual response instead of a generic "OK".
  last_session_log="$log_file"
  local start=$(date +%s)

  if ! command -v claude >/dev/null 2>&1; then
    echo "claude not found" > "$log_file"
    claude_exit_code=-2
    duration_ms=$(( ($(date +%s) - start) * 1000 ))
    return 1
  fi

  # Build the shell snippet with each variable that could contain prompt
  # characters ("; `, etc.) single-quote-escaped. tmux will pass this to
  # the default shell via `-c`, and without the escaping a prompt like
  # `hi"; rm -rf /; echo "bye` would be interpreted as a command.
  local prompt_sq log_sq cfg_sq
  prompt_sq=$(sh_sq "$HEARTBEAT_PROMPT")
  log_sq=$(sh_sq "$log_file")
  # Prepare the isolated heartbeat config dir; fall back to the shared
  # dir if the isolation step fails for any reason (prefer a working
  # heartbeat over a pristine interactive-session config).
  local cfg_dir
  cfg_dir=$(ensure_heartbeat_config_dir 2>/dev/null || true)
  [ -n "$cfg_dir" ] || cfg_dir="$HOME/.claude"
  cfg_sq=$(sh_sq "$cfg_dir")
  # The heartbeat launches an ephemeral, non-interactive claude, so we:
  #   - --dangerously-skip-permissions: no human is there to approve
  #     tool prompts. Safe because the config dir is isolated, the run
  #     is short-lived, and stdout is forwarded to the notifier verbatim.
  #   - --permission-mode auto: override the user-level
  #     `permissions.defaultMode: plan` that start_services.sh sets for
  #     the interactive agent session. Plan mode makes sense when a
  #     human reviews proposed changes; for a cron tick with nobody
  #     watching, auto just runs the prompt and exits.
  tmux new-session -d -s "$sess" -c "$WORKSPACE_DIR" \
    "CLAUDE_CONFIG_DIR=$cfg_sq claude --print --dangerously-skip-permissions --permission-mode auto $prompt_sq > $log_sq 2>&1; echo HEARTBEAT_DONE >> $log_sq"

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
    if [ "$notify_this" = true ]; then
      # Forward claude's actual response instead of a canned OK — this is
      # the point of a custom HEARTBEAT_PROMPT. The canned fallback fires
      # only when the session log is missing or empty.
      invoke_notifier "ok" "$(claude_output "$last_session_log")"
    fi
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
