# Heartbeat Observability + CLI — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the four blocking bugs in the heartbeat pipeline (interval propagation, malformed crontab, crond privilege drop, legacy `launch.sh`) and introduce a structured trace (`runs.jsonl` + `state.json`) plus a single CLI (`heartbeatctl`) that lets the agent or a human inspect and mutate the heartbeat with atomic rollback against `agent.yml`.

**Architecture:** Image-baked code (`docker/scripts/heartbeatctl`, `docker/scripts/lib/*.sh`) paired with workspace-owned data (`/workspace/scripts/heartbeat/{state.json,logs/runs.jsonl,heartbeat.conf}`). `agent.yml` is the single source of truth; all mutations go through `heartbeatctl` → `yq -i` → regenerate conf + crontab → busybox crond auto-reloads (≤60s) or on SIGHUP. Notifier drivers emit JSON fragments that embed directly into `runs.jsonl`.

**Tech Stack:** bash 4+, busybox crond (Alpine), `yq` v4, `jq`, `bats-core`, tmux, `claude` CLI, `su-exec`, `tini`.

---

## File structure

**New files (launcher repo):**

- `docker/scripts/heartbeatctl` — the CLI (single bash script, dispatch table). ~500 lines.
- `docker/scripts/lib/interval.sh` — pure function `interval_to_cron`. Sourced by heartbeatctl.
- `docker/scripts/lib/state.sh` — pure functions `gen_run_id`, `append_run_line`, `write_state_json`, `rotate_runs_jsonl`. Sourced by `heartbeat.sh` and `heartbeatctl`.
- `tests/interval-to-cron.bats`
- `tests/state-lib.bats`
- `tests/heartbeatctl.bats`
- `tests/heartbeat-runs-jsonl.bats`
- `tests/docker-e2e-heartbeat.bats`

**Modified files:**

- `docker/crontab.tpl` — drop `agent` user field.
- `docker/entrypoint.sh` — chown workspace heartbeat dir, launch crond as root, symlink heartbeatctl, invoke `heartbeatctl reload` after dropping to agent.
- `docker/Dockerfile` — `COPY` `heartbeatctl` + `lib/*.sh`, `chmod +x`, create symlink placeholder.
- `docker/scripts/start_services.sh` — remove crond launch; add crond-liveness check in watchdog.
- `scripts/heartbeat/heartbeat.sh` — full rewrite to emit `runs.jsonl` + `state.json`, use new notifier contract, handle `skipped` state.
- `scripts/heartbeat/notifiers/none.sh` — rewrite to JSON contract.
- `scripts/heartbeat/notifiers/log.sh` — rewrite to JSON contract.
- `scripts/heartbeat/notifiers/telegram.sh` — rewrite to JSON contract.
- `tests/notifiers.bats` — updated assertions for the JSON contract.
- `docs/architecture.md` — new section for heartbeatctl + data contracts.
- `CHANGELOG.md` — entry.

**Runtime paths (after deploy):**

- Image: `/opt/agent-admin/scripts/heartbeatctl`, `/opt/agent-admin/scripts/lib/*.sh`.
- Image symlink: `/usr/local/bin/heartbeatctl` → `/opt/agent-admin/scripts/heartbeatctl`.
- Workspace: `/workspace/scripts/heartbeat/{heartbeat.sh,heartbeat.conf,state.json,notifiers/,logs/runs.jsonl,logs/cron.log}`.

---

## Task 1: Fix crontab template — drop the user field

**Files:**
- Modify: `docker/crontab.tpl`
- Modify: `docker/entrypoint.sh:20-25` (default `HEARTBEAT_CRON` needs no other change; keep the envsubst step so crond has a safe default if `heartbeatctl reload` fails).
- Test: `tests/docker-render.bats` (add one assertion)

- [ ] **Step 1: Add the failing test**

Append to `tests/docker-render.bats`:

```bash
@test "crontab.tpl renders without a user field (busybox user-crontab format)" {
  export HEARTBEAT_CRON="*/2 * * * *"
  local rendered
  rendered=$(envsubst < "$REPO_ROOT/docker/crontab.tpl")
  # Must NOT contain the token "agent " in the executable position.
  # Valid format: "<5 time fields> /workspace/scripts/heartbeat/heartbeat.sh ..."
  [[ "$rendered" == *"*/2 * * * * /workspace/scripts/heartbeat/heartbeat.sh"* ]]
  [[ "$rendered" != *"* agent /workspace"* ]]
}
```

- [ ] **Step 2: Run the test; expect failure**

```bash
bats tests/docker-render.bats -f "crontab.tpl renders without a user field"
```

Expected: FAIL (current template has the `agent` token).

- [ ] **Step 3: Fix the template**

Replace `docker/crontab.tpl` contents with:

```
# Cron for in-container agent heartbeat.
# /etc/crontabs/agent is a busybox user crontab — the user is implicit in
# the filename, so the entry is "<schedule> <command>" with no user field.
# Rendered at container startup: envsubst < /opt/agent-admin/crontab.tpl > /etc/crontabs/agent
${HEARTBEAT_CRON} /workspace/scripts/heartbeat/heartbeat.sh >> /workspace/scripts/heartbeat/logs/cron.log 2>&1
```

- [ ] **Step 4: Re-run the test; expect pass**

```bash
bats tests/docker-render.bats -f "crontab.tpl renders without a user field"
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add docker/crontab.tpl tests/docker-render.bats
git commit -m "fix(crontab): drop user field from busybox user-crontab template"
```

---

## Task 2: Interval-to-cron converter library

**Files:**
- Create: `docker/scripts/lib/interval.sh`
- Create: `tests/interval-to-cron.bats`

- [ ] **Step 1: Write the failing tests**

Create `tests/interval-to-cron.bats`:

```bash
#!/usr/bin/env bats

load helper

setup() {
  source "$REPO_ROOT/docker/scripts/lib/interval.sh"
}

@test "interval_to_cron 1m -> every minute" {
  run interval_to_cron 1m
  [ "$status" -eq 0 ]; [ "$output" = "* * * * *" ]
}
@test "interval_to_cron 2m -> */2 * * * *" {
  run interval_to_cron 2m
  [ "$status" -eq 0 ]; [ "$output" = "*/2 * * * *" ]
}
@test "interval_to_cron 15m -> */15 * * * *" {
  run interval_to_cron 15m
  [ "$status" -eq 0 ]; [ "$output" = "*/15 * * * *" ]
}
@test "interval_to_cron 30m -> */30 * * * *" {
  run interval_to_cron 30m
  [ "$status" -eq 0 ]; [ "$output" = "*/30 * * * *" ]
}
@test "interval_to_cron 1h -> 0 * * * *" {
  run interval_to_cron 1h
  [ "$status" -eq 0 ]; [ "$output" = "0 * * * *" ]
}
@test "interval_to_cron 2h -> 0 */2 * * *" {
  run interval_to_cron 2h
  [ "$status" -eq 0 ]; [ "$output" = "0 */2 * * *" ]
}
@test "interval_to_cron 24h -> 0 0 * * * (daily)" {
  run interval_to_cron 24h
  [ "$status" -eq 0 ]; [ "$output" = "0 0 * * *" ]
}
@test "interval_to_cron rejects sub-minute (30s)" {
  run interval_to_cron 30s
  [ "$status" -ne 0 ]
  [[ "$output" == *"busybox cron"* || "$output" == *"accepted"* ]]
}
@test "interval_to_cron rejects 60s" {
  run interval_to_cron 60s
  [ "$status" -ne 0 ]
}
@test "interval_to_cron rejects 45m (not a divisor of 60)" {
  run interval_to_cron 45m
  [ "$status" -ne 0 ]
}
@test "interval_to_cron rejects 7m" {
  run interval_to_cron 7m
  [ "$status" -ne 0 ]
}
@test "interval_to_cron rejects 5h (not a divisor of 24)" {
  run interval_to_cron 5h
  [ "$status" -ne 0 ]
}
@test "interval_to_cron rejects empty" {
  run interval_to_cron ""
  [ "$status" -ne 0 ]
}
@test "interval_to_cron rejects foo" {
  run interval_to_cron foo
  [ "$status" -ne 0 ]
}
@test "interval_to_cron rejects -2m" {
  run interval_to_cron -2m
  [ "$status" -ne 0 ]
}
@test "interval_to_cron rejects uppercase 2M" {
  run interval_to_cron 2M
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run tests; expect all to fail with "interval_to_cron: command not found"**

```bash
bats tests/interval-to-cron.bats
```

Expected: all FAIL (function does not exist yet).

- [ ] **Step 3: Implement the converter**

Create `docker/scripts/lib/interval.sh`:

```bash
#!/bin/bash
# interval_to_cron — convert a simple interval string to a 5-field cron expression.
#
# Accepted inputs:
#   Nm where N in {1, 2, 3, 4, 5, 6, 10, 12, 15, 20, 30}
#   Nh where N in {1, 2, 3, 4, 6, 8, 12}
#   24h (once per day at 00:00 UTC)
#
# Rejected: anything else, including "Ns", "60s", "45m", "5h".
# Sub-minute is rejected because busybox cron resolution is 1 minute.

# Print cron expression to stdout and return 0 on success; print a one-line
# error to stderr and return non-zero on failure.
interval_to_cron() {
  local input="${1:-}"

  if ! [[ "$input" =~ ^[1-9][0-9]*[mh]$ ]]; then
    echo "interval_to_cron: invalid format '$input' — expected Nm or Nh (e.g. 2m, 15m, 1h). Sub-minute (s) not accepted; busybox cron resolution is 1 minute." >&2
    return 2
  fi

  local num="${input%[mh]}"
  local unit="${input: -1}"

  if [ "$unit" = "m" ]; then
    case "$num" in
      1|2|3|4|5|6|10|12|15|20|30)
        if [ "$num" = "1" ]; then
          echo "* * * * *"
        else
          echo "*/$num * * * *"
        fi
        return 0
        ;;
      *)
        echo "interval_to_cron: minute value '$num' not in accepted set {1,2,3,4,5,6,10,12,15,20,30}" >&2
        return 3
        ;;
    esac
  fi

  if [ "$unit" = "h" ]; then
    case "$num" in
      1)  echo "0 * * * *";     return 0 ;;
      2|3|4|6|8|12) echo "0 */$num * * *"; return 0 ;;
      24) echo "0 0 * * *";     return 0 ;;
      *)
        echo "interval_to_cron: hour value '$num' not in accepted set {1,2,3,4,6,8,12,24}" >&2
        return 3
        ;;
    esac
  fi
}
```

- [ ] **Step 4: Run tests; expect all to pass**

```bash
bats tests/interval-to-cron.bats
```

Expected: 16 passed.

- [ ] **Step 5: Commit**

```bash
git add docker/scripts/lib/interval.sh tests/interval-to-cron.bats
git commit -m "feat(heartbeat): add interval_to_cron converter with divisor-table validation"
```

---

## Task 3: State library — run_id, state.json writer, runs.jsonl appender, rotation

**Files:**
- Create: `docker/scripts/lib/state.sh`
- Create: `tests/state-lib.bats`

- [ ] **Step 1: Write the failing tests**

Create `tests/state-lib.bats`:

```bash
#!/usr/bin/env bats

load helper

setup() {
  setup_tmp_dir
  source "$REPO_ROOT/docker/scripts/lib/state.sh"
  export HEARTBEAT_DIR="$TMP_TEST_DIR"
  mkdir -p "$HEARTBEAT_DIR/logs"
}

teardown() { teardown_tmp_dir; }

@test "gen_run_id matches YYYYMMDDHHMMSS-XXXX format" {
  local id
  id=$(gen_run_id)
  [[ "$id" =~ ^[0-9]{14}-[0-9a-f]{4}$ ]]
}

@test "gen_run_id is unique across rapid calls" {
  local a b
  a=$(gen_run_id); b=$(gen_run_id)
  [ "$a" != "$b" ]
}

@test "append_run_line writes a valid JSON line to runs.jsonl" {
  append_run_line "$HEARTBEAT_DIR/logs/runs.jsonl" '{"ts":"2026-04-19T01:30:00Z","run_id":"20260419013000-a3f2","status":"ok","duration_ms":100}'
  [ -f "$HEARTBEAT_DIR/logs/runs.jsonl" ]
  run jq -e '.status == "ok"' "$HEARTBEAT_DIR/logs/runs.jsonl"
  [ "$status" -eq 0 ]
}

@test "append_run_line appends — existing lines preserved" {
  echo '{"ts":"old","status":"ok"}' > "$HEARTBEAT_DIR/logs/runs.jsonl"
  append_run_line "$HEARTBEAT_DIR/logs/runs.jsonl" '{"ts":"new","status":"ok"}'
  [ "$(wc -l < "$HEARTBEAT_DIR/logs/runs.jsonl")" = "2" ]
}

@test "write_state_json rewrites atomically (never leaves partial file)" {
  local f="$HEARTBEAT_DIR/state.json"
  write_state_json "$f" '{"schema":1,"enabled":true,"interval":"2m"}'
  run jq -e '.interval == "2m"' "$f"
  [ "$status" -eq 0 ]
  # temp sibling must be gone
  [ ! -f "${f}.tmp" ]
}

@test "write_state_json overwrites prior content" {
  local f="$HEARTBEAT_DIR/state.json"
  write_state_json "$f" '{"schema":1,"interval":"1h"}'
  write_state_json "$f" '{"schema":1,"interval":"2m"}'
  run jq -r '.interval' "$f"
  [ "$status" -eq 0 ]; [ "$output" = "2m" ]
}

@test "rotate_runs_jsonl is no-op when file under threshold" {
  local f="$HEARTBEAT_DIR/logs/runs.jsonl"
  echo "small" > "$f"
  rotate_runs_jsonl "$f" 1000000
  [ -f "$f" ]
  [ ! -f "${f}.1" ]
}

@test "rotate_runs_jsonl shifts files when over threshold" {
  local f="$HEARTBEAT_DIR/logs/runs.jsonl"
  # 1KB threshold, create 2KB file
  head -c 2048 /dev/urandom > "$f"
  rotate_runs_jsonl "$f" 1024
  [ ! -f "$f" ] || [ ! -s "$f" ]   # primary gone or empty
  [ -f "${f}.1" ]
}

@test "rotate_runs_jsonl maintains max 3 gz generations" {
  local f="$HEARTBEAT_DIR/logs/runs.jsonl"
  # Prepopulate .1 .2.gz .3.gz with distinct content
  echo "one"   > "${f}.1"
  echo "two"   | gzip > "${f}.2.gz"
  echo "three" | gzip > "${f}.3.gz"
  head -c 2048 /dev/urandom > "$f"
  rotate_runs_jsonl "$f" 1024
  [ -f "${f}.1" ]
  [ -f "${f}.2.gz" ]
  [ -f "${f}.3.gz" ]
  # .4 must NOT exist
  [ ! -f "${f}.4.gz" ]
}
```

- [ ] **Step 2: Run tests; expect all to fail**

```bash
bats tests/state-lib.bats
```

Expected: all FAIL.

- [ ] **Step 3: Implement the library**

Create `docker/scripts/lib/state.sh`:

```bash
#!/bin/bash
# state.sh — helpers for heartbeat state and trace files.
#
# All functions are pure in the sense that their only side effects are to
# files they are explicitly given as arguments. Callers (heartbeat.sh,
# heartbeatctl) compose them.

# gen_run_id — YYYYMMDDHHMMSS-XXXX where XXXX is 4 random hex chars.
# Collision probability within the same second: ~1/65536. Good enough for
# a single-agent heartbeat that runs at most every minute.
gen_run_id() {
  local ts suf
  ts=$(date -u +%Y%m%d%H%M%S)
  # $RANDOM is 0..32767 (15-bit). Mask to 4 hex chars.
  suf=$(printf '%04x' $((RANDOM & 0xFFFF)))
  printf '%s-%s\n' "$ts" "$suf"
}

# append_run_line FILE JSON_STRING
# Appends a single line to runs.jsonl. Caller is responsible for JSON validity;
# we do a last-line sanity check with jq to avoid silently corrupting the file.
append_run_line() {
  local file="$1" line="$2"
  if ! printf '%s' "$line" | jq empty >/dev/null 2>&1; then
    echo "append_run_line: refusing to write non-JSON line to $file" >&2
    return 1
  fi
  mkdir -p "$(dirname "$file")"
  printf '%s\n' "$line" >> "$file"
}

# write_state_json FILE JSON_STRING
# Atomic: write to FILE.tmp then rename. jq-validated before the rename.
write_state_json() {
  local file="$1" content="$2"
  if ! printf '%s' "$content" | jq empty >/dev/null 2>&1; then
    echo "write_state_json: refusing to write non-JSON to $file" >&2
    return 1
  fi
  mkdir -p "$(dirname "$file")"
  printf '%s\n' "$content" > "${file}.tmp"
  mv "${file}.tmp" "$file"
}

# rotate_runs_jsonl FILE THRESHOLD_BYTES
# If FILE >= THRESHOLD_BYTES, rotate:
#   .3.gz deleted
#   .2.gz → .3.gz
#   .1 → .2.gz (gzip on the way)
#   FILE → .1
# New FILE will be created on next append.
rotate_runs_jsonl() {
  local file="$1" threshold="$2"
  [ -f "$file" ] || return 0
  local size
  size=$(stat -c %s "$file" 2>/dev/null || stat -f %z "$file" 2>/dev/null || echo 0)
  [ "$size" -lt "$threshold" ] && return 0

  [ -f "${file}.3.gz" ] && rm -f "${file}.3.gz"
  [ -f "${file}.2.gz" ] && mv "${file}.2.gz" "${file}.3.gz"
  if [ -f "${file}.1" ]; then
    gzip -f "${file}.1"
    mv "${file}.1.gz" "${file}.2.gz"
  fi
  mv "$file" "${file}.1"
}
```

- [ ] **Step 4: Run tests; expect all to pass**

```bash
bats tests/state-lib.bats
```

Expected: 9 passed.

- [ ] **Step 5: Commit**

```bash
git add docker/scripts/lib/state.sh tests/state-lib.bats
git commit -m "feat(heartbeat): add state-lib helpers (run_id, jsonl append, atomic state.json, rotation)"
```

---

## Task 4: Rewrite notifier contract (none, log, telegram)

**Files:**
- Modify: `scripts/heartbeat/notifiers/none.sh`
- Modify: `scripts/heartbeat/notifiers/log.sh`
- Modify: `scripts/heartbeat/notifiers/telegram.sh`
- Modify: `tests/notifiers.bats`

New contract (same for all three):
- Invocation: `notifiers/<ch>.sh <run_id> <status>`, with the message body on **stdin**.
- Output: one JSON object on stdout: `{"channel":"<name>","ok":true|false,"latency_ms":<int>,"error":null|"<msg>"}`.
- Exit: always `0`. Failures are reported in the JSON.

- [ ] **Step 1: Update the failing tests first**

Replace `tests/notifiers.bats` with:

```bash
#!/usr/bin/env bats

load helper

setup() { setup_tmp_dir; }
teardown() { teardown_tmp_dir; }

@test "none.sh emits ok=true, latency=0, channel=none" {
  run bash "$REPO_ROOT/scripts/heartbeat/notifiers/none.sh" "run-1" "ok" <<<"hello"
  [ "$status" -eq 0 ]
  run jq -r '.channel' <<<"$output"; [ "$output" = "none" ]
  run jq -r '.ok' <<<"$output"; [ "$output" = "true" ]
  run jq -r '.latency_ms' <<<"$output"; [ "$output" = "0" ]
  run jq -r '.error' <<<"$output"; [ "$output" = "null" ]
}

@test "log.sh writes message to \$NOTIFY_LOG_FILE and returns ok=true" {
  export NOTIFY_LOG_FILE="$TMP_TEST_DIR/notifications.log"
  run bash "$REPO_ROOT/scripts/heartbeat/notifiers/log.sh" "run-2" "ok" <<<"hola"
  [ "$status" -eq 0 ]
  run jq -r '.ok' <<<"$output"; [ "$output" = "true" ]
  grep -q "hola" "$NOTIFY_LOG_FILE"
  grep -q "run-2" "$NOTIFY_LOG_FILE"
}

@test "log.sh reports ok=false when log file cannot be written" {
  export NOTIFY_LOG_FILE="/this/path/does/not/exist/notifications.log"
  run bash "$REPO_ROOT/scripts/heartbeat/notifiers/log.sh" "run-3" "ok" <<<"msg"
  [ "$status" -eq 0 ]
  run jq -r '.ok' <<<"$output"; [ "$output" = "false" ]
  run jq -r '.error' <<<"$output"; [[ "$output" == *"cannot"* || "$output" == *"write"* || "$output" == *"No such"* ]]
}

@test "telegram.sh reports ok=false when token/chat_id missing" {
  unset NOTIFY_BOT_TOKEN NOTIFY_CHAT_ID
  run bash "$REPO_ROOT/scripts/heartbeat/notifiers/telegram.sh" "run-4" "ok" <<<"msg"
  [ "$status" -eq 0 ]
  run jq -r '.ok' <<<"$output"; [ "$output" = "false" ]
  run jq -r '.error' <<<"$output"; [[ "$output" == *"token"* || "$output" == *"chat"* ]]
}

@test "telegram.sh exits 0 even on network failure" {
  export NOTIFY_BOT_TOKEN="00000:FAKE"
  export NOTIFY_CHAT_ID="1"
  export NOTIFY_TELEGRAM_API_BASE="http://127.0.0.1:1"   # deliberately dead
  run bash "$REPO_ROOT/scripts/heartbeat/notifiers/telegram.sh" "run-5" "ok" <<<"msg"
  [ "$status" -eq 0 ]
  run jq -r '.ok' <<<"$output"; [ "$output" = "false" ]
}
```

- [ ] **Step 2: Run notifier tests; expect all to fail**

```bash
bats tests/notifiers.bats
```

Expected: FAIL (current notifiers emit different shapes).

- [ ] **Step 3: Rewrite `scripts/heartbeat/notifiers/none.sh`**

```bash
#!/usr/bin/env bash
# none — no-op notifier. Reads stdin (ignored). Emits the standard JSON envelope.
set -euo pipefail
cat >/dev/null || true    # drain stdin so caller does not SIGPIPE
printf '{"channel":"none","ok":true,"latency_ms":0,"error":null}\n'
```

- [ ] **Step 4: Rewrite `scripts/heartbeat/notifiers/log.sh`**

```bash
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
if ! mkdir -p "$(dirname "$NOTIFY_LOG_FILE")" 2>/tmp/notify-log.err; then
  ok="false"; err=$(jq -Rs . </tmp/notify-log.err)
elif ! printf '[%s] [%s] [%s] %s\n' "$ts" "$RUN_ID" "$STATUS" "$msg" >> "$NOTIFY_LOG_FILE" 2>/tmp/notify-log.err; then
  ok="false"; err=$(jq -Rs . </tmp/notify-log.err)
fi
rm -f /tmp/notify-log.err

end_ns=$(date +%s%N 2>/dev/null || date +%s000000000)
latency_ms=$(( (end_ns - start_ns) / 1000000 ))

printf '{"channel":"log","ok":%s,"latency_ms":%d,"error":%s}\n' "$ok" "$latency_ms" "$err"
exit 0
```

- [ ] **Step 5: Rewrite `scripts/heartbeat/notifiers/telegram.sh`**

```bash
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
  printf '{"channel":"telegram","ok":false,"latency_ms":%d,"error":"NOTIFY_BOT_TOKEN or NOTIFY_CHAT_ID not set"}\n' "$latency_ms"
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
```

- [ ] **Step 6: Run notifier tests; expect all to pass**

```bash
bats tests/notifiers.bats
```

Expected: 5 passed.

- [ ] **Step 7: Commit**

```bash
git add scripts/heartbeat/notifiers/ tests/notifiers.bats
git commit -m "feat(heartbeat): rewrite notifiers to emit standard JSON envelope on stdout"
```

---

## Task 5: Rewrite `scripts/heartbeat/heartbeat.sh`

**Files:**
- Modify: `scripts/heartbeat/heartbeat.sh`
- Create: `tests/heartbeat-runs-jsonl.bats`

Key behaviors the rewrite must preserve:
- Reads `heartbeat.conf` for prompt/timeout/retries/notifier channel.
- Launches `claude --print "$PROMPT"` inside a tmux session.
- Uses `HEARTBEAT_DONE` sentinel in the session log to detect success.
- Retries on failure (`HEARTBEAT_RETRIES`).

Key behaviors the rewrite **adds**:
- Generates a `run_id` and uses it for tmux session naming (`<agent>-hb-<run_id>`).
- If a prior `<agent>-hb-*` session exists → status `skipped`, write record, exit 0.
- Emits one line to `logs/runs.jsonl` using the contract.
- Updates `state.json` atomically at end of run (with `last_run`, `counters`, `next_run_estimate` derived from the `HEARTBEAT_CRON` in conf — pure cron eval; if `HEARTBEAT_CRON` is unset, `next_run_estimate` is `null`).
- Invokes the notifier per the new contract; embeds returned JSON verbatim.
- Rotates `runs.jsonl` at 10MB.

- [ ] **Step 1: Write the failing integration test**

Create `tests/heartbeat-runs-jsonl.bats`:

```bash
#!/usr/bin/env bats

load helper

setup() {
  setup_tmp_dir
  # Simulate the workspace layout
  export WORKSPACE="$TMP_TEST_DIR"
  cp -R "$REPO_ROOT/scripts/heartbeat" "$WORKSPACE/"
  export AGENT_YML="$WORKSPACE/agent.yml"
  cat > "$AGENT_YML" <<YML
agent:
  name: testbot
deployment:
  workspace: $WORKSPACE
claude:
  config_dir: $TMP_TEST_DIR/.claude
features:
  heartbeat:
    enabled: true
    interval: "2m"
    timeout: 5
    retries: 0
    default_prompt: "echo ok"
notifications:
  channel: none
YML
  # Stub claude with a shell that writes HEARTBEAT_DONE and exits 0
  mkdir -p "$TMP_TEST_DIR/bin"
  cat > "$TMP_TEST_DIR/bin/claude" <<'CL'
#!/bin/bash
echo "STUB CLAUDE: $*"
# heartbeat.sh writes "; echo HEARTBEAT_DONE >> $log" after the claude invocation,
# so we just need to succeed.
exit 0
CL
  chmod +x "$TMP_TEST_DIR/bin/claude"
  export PATH="$TMP_TEST_DIR/bin:$PATH"
  # Render heartbeat.conf
  cat > "$WORKSPACE/heartbeat/heartbeat.conf" <<CONF
HEARTBEAT_INTERVAL="2m"
HEARTBEAT_CRON="*/2 * * * *"
HEARTBEAT_TIMEOUT="5"
HEARTBEAT_RETRIES="0"
HEARTBEAT_PROMPT="echo ok"
HEARTBEAT_ENABLED="true"
NOTIFY_CHANNEL="none"
NOTIFY_SUCCESS_EVERY="1"
CONF
  export HEARTBEAT_STATE_LIB="$REPO_ROOT/docker/scripts/lib/state.sh"
}
teardown() { teardown_tmp_dir; }

@test "heartbeat.sh writes one runs.jsonl line on success" {
  # heartbeat.sh reads its dir from its own location, so we invoke from the
  # copied location inside WORKSPACE
  run bash "$WORKSPACE/heartbeat/heartbeat.sh"
  [ "$status" -eq 0 ]
  [ -f "$WORKSPACE/heartbeat/logs/runs.jsonl" ]
  [ "$(wc -l < "$WORKSPACE/heartbeat/logs/runs.jsonl")" = "1" ]
  run jq -r '.status' "$WORKSPACE/heartbeat/logs/runs.jsonl"
  [ "$status" -eq 0 ]; [ "$output" = "ok" ]
  run jq -r '.trigger' "$WORKSPACE/heartbeat/logs/runs.jsonl"
  [ "$output" = "cron" ]
  run jq -r '.notifier.channel' "$WORKSPACE/heartbeat/logs/runs.jsonl"
  [ "$output" = "none" ]
}

@test "heartbeat.sh writes state.json with counters and last_run" {
  run bash "$WORKSPACE/heartbeat/heartbeat.sh"
  [ -f "$WORKSPACE/heartbeat/state.json" ]
  run jq -e '.schema == 1 and .enabled == true and .interval == "2m" and .cron == "*/2 * * * *"' "$WORKSPACE/heartbeat/state.json"
  [ "$status" -eq 0 ]
  run jq -r '.last_run.status' "$WORKSPACE/heartbeat/state.json"
  [ "$output" = "ok" ]
  run jq -r '.counters.total_runs' "$WORKSPACE/heartbeat/state.json"
  [ "$output" = "1" ]
  run jq -r '.counters.ok' "$WORKSPACE/heartbeat/state.json"
  [ "$output" = "1" ]
  run jq -r '.counters.consecutive_failures' "$WORKSPACE/heartbeat/state.json"
  [ "$output" = "0" ]
}

@test "heartbeat.sh increments counters across runs" {
  bash "$WORKSPACE/heartbeat/heartbeat.sh"
  bash "$WORKSPACE/heartbeat/heartbeat.sh"
  run jq -r '.counters.total_runs' "$WORKSPACE/heartbeat/state.json"
  [ "$output" = "2" ]
  [ "$(wc -l < "$WORKSPACE/heartbeat/logs/runs.jsonl")" = "2" ]
}

@test "heartbeat.sh records status=skipped when a prior session is still active" {
  # Start a fake tmux session matching the naming pattern and leave it alive
  tmux new-session -d -s "testbot-hb-99999999999999-zzzz" "sleep 30"
  run bash "$WORKSPACE/heartbeat/heartbeat.sh"
  [ "$status" -eq 0 ]
  run jq -r '.status' "$WORKSPACE/heartbeat/logs/runs.jsonl"
  [ "$output" = "skipped" ]
  # skipped must NOT bump consecutive_failures
  run jq -r '.counters.consecutive_failures' "$WORKSPACE/heartbeat/state.json"
  [ "$output" = "0" ]
  tmux kill-session -t "testbot-hb-99999999999999-zzzz" 2>/dev/null || true
}

@test "heartbeat.sh rotates runs.jsonl when size >= 10MB" {
  # Pre-populate runs.jsonl with 11MB of valid-ish lines
  mkdir -p "$WORKSPACE/heartbeat/logs"
  for i in $(seq 1 110); do
    printf '{"filler":"'"$(head -c 99000 /dev/urandom | base64 | tr -d '\n' | head -c 98000)"'"}\n'
  done > "$WORKSPACE/heartbeat/logs/runs.jsonl"
  run bash "$WORKSPACE/heartbeat/heartbeat.sh"
  [ -f "$WORKSPACE/heartbeat/logs/runs.jsonl.1" ]
  # New runs.jsonl should have exactly one fresh line
  [ "$(wc -l < "$WORKSPACE/heartbeat/logs/runs.jsonl")" = "1" ]
}
```

- [ ] **Step 2: Run the tests; expect all to fail**

```bash
bats tests/heartbeat-runs-jsonl.bats
```

Expected: all FAIL (current heartbeat.sh emits history.log, not runs.jsonl/state.json).

- [ ] **Step 3: Rewrite `scripts/heartbeat/heartbeat.sh`**

Replace the entire file with:

```bash
#!/usr/bin/env bash
# heartbeat — one tick of the scheduled agent heartbeat.
# Emits a line to logs/runs.jsonl and updates state.json atomically.
# Contract detailed in docs/superpowers/specs/2026-04-19-heartbeat-observability-cli-design.md

set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
AGENT_NAME="$(basename "$WORKSPACE_DIR")"
CONF_FILE="$SCRIPT_DIR/heartbeat.conf"
LOG_DIR="$SCRIPT_DIR/logs"
RUNS_FILE="$LOG_DIR/runs.jsonl"
STATE_FILE="$SCRIPT_DIR/state.json"
SESSION_LOG_DIR="$LOG_DIR/sessions"
ROTATE_THRESHOLD_BYTES="${ROTATE_THRESHOLD_BYTES:-10485760}"   # 10 MB

# Source the state lib. In the container it lives in the image; in tests we
# allow an override via HEARTBEAT_STATE_LIB.
STATE_LIB="${HEARTBEAT_STATE_LIB:-/opt/agent-admin/scripts/lib/state.sh}"
# shellcheck source=/dev/null
source "$STATE_LIB"

mkdir -p "$LOG_DIR" "$SESSION_LOG_DIR"

# Load config
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
TRIGGER="${HEARTBEAT_TRIGGER:-cron}"   # 'cron' | 'manual' (set by heartbeatctl test)

# Override prompt via CLI
while [ "$#" -gt 0 ]; do
  case "$1" in
    --prompt) HEARTBEAT_PROMPT="$2"; shift 2 ;;
    --trigger) TRIGGER="$2"; shift 2 ;;
    *) shift ;;
  esac
done

iso8601() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now_ms() { date +%s%N 2>/dev/null | cut -c1-13 || echo $(( $(date +%s) * 1000 )); }

# ── Skipped check: if any prior <agent>-hb-* session is alive, this tick is skipped
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
    claude_exit_code=-1   # timeout sentinel
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

# ── Main
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

# Notifier policy: always on failure; on success, honor NOTIFY_SUCCESS_EVERY
case "$status" in
  ok)
    # rate-limit successes: if NOTIFY_SUCCESS_EVERY>1 and prior state.counters.ok % N != 0 -> skip
    notify_this=true
    if [ -f "$STATE_FILE" ] && [ "${NOTIFY_SUCCESS_EVERY:-1}" -gt 1 ]; then
      prev_ok=$(jq -r '.counters.ok // 0' "$STATE_FILE" 2>/dev/null || echo 0)
      [ $(( (prev_ok + 1) % NOTIFY_SUCCESS_EVERY )) -ne 0 ] && notify_this=false
    fi
    [ "$notify_this" = true ] && invoke_notifier "ok" "Heartbeat OK ($TRIGGER) — ${duration_ms}ms"
    ;;
  timeout) invoke_notifier "timeout" "Heartbeat TIMEOUT (${duration_ms}ms) — check $session log" ;;
  error)   invoke_notifier "error"   "Heartbeat ERROR (exit=$claude_exit_code)" ;;
  skipped) : ;;   # no notifier for skipped
esac

# ── Build runs.jsonl line
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

append_run_line "$RUNS_FILE" "$line"
rotate_runs_jsonl "$RUNS_FILE" "$ROTATE_THRESHOLD_BYTES"

# ── Update state.json
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

# success_rate_24h: tail runs.jsonl last 24h, ratio of ok
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
    rate=$(awk -v o="$ok24" -v t="$total24" 'BEGIN{printf "%.4f", o/t}')
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

# Keep the last 20 session logs — cheap housekeeping
ls -1t "$SESSION_LOG_DIR"/*.log 2>/dev/null | tail -n +21 | xargs rm -f 2>/dev/null || true

exit 0
```

- [ ] **Step 4: Run the integration tests; expect all to pass**

```bash
bats tests/heartbeat-runs-jsonl.bats
```

Expected: 5 passed. (The rotation test creates ~11MB of data; allow up to ~30s.)

- [ ] **Step 5: Commit**

```bash
git add scripts/heartbeat/heartbeat.sh tests/heartbeat-runs-jsonl.bats
git commit -m "feat(heartbeat): rewrite runner to emit runs.jsonl + state.json with rotation and skipped detection"
```

---

## Task 6: `heartbeatctl` skeleton + `help` + `show`

**Files:**
- Create: `docker/scripts/heartbeatctl`
- Create: `tests/heartbeatctl.bats`

The CLI is a single dispatch script. This task lays the skeleton and ships two read-only commands. Subsequent tasks layer more subcommands into the same file.

- [ ] **Step 1: Write failing tests**

Create `tests/heartbeatctl.bats`:

```bash
#!/usr/bin/env bats

load helper

setup() {
  setup_tmp_dir
  export WORKSPACE="$TMP_TEST_DIR"
  mkdir -p "$WORKSPACE/heartbeat/logs" "$WORKSPACE/heartbeat/notifiers"
  # minimal agent.yml
  cat > "$WORKSPACE/agent.yml" <<YML
agent:
  name: testbot
features:
  heartbeat:
    enabled: true
    interval: "2m"
    timeout: 300
    retries: 1
    default_prompt: "Check"
notifications:
  channel: log
YML
  # minimal heartbeat.conf
  cat > "$WORKSPACE/heartbeat/heartbeat.conf" <<CONF
HEARTBEAT_ENABLED="true"
HEARTBEAT_INTERVAL="2m"
HEARTBEAT_CRON="*/2 * * * *"
HEARTBEAT_TIMEOUT="300"
HEARTBEAT_RETRIES="1"
HEARTBEAT_PROMPT="Check"
NOTIFY_CHANNEL="log"
NOTIFY_SUCCESS_EVERY="1"
CONF
  export HEARTBEATCTL_WORKSPACE="$WORKSPACE"
  export HEARTBEATCTL_CRONTAB_FILE="$TMP_TEST_DIR/crontab-agent"
  export HEARTBEATCTL_LIB_DIR="$REPO_ROOT/docker/scripts/lib"
  # write a baseline crontab
  printf '*/30 * * * * /workspace/scripts/heartbeat/heartbeat.sh >> /workspace/scripts/heartbeat/logs/cron.log 2>&1\n' > "$HEARTBEATCTL_CRONTAB_FILE"
}
teardown() { teardown_tmp_dir; }

@test "help prints all command groups" {
  run bash "$REPO_ROOT/docker/scripts/heartbeatctl" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"status"* ]]
  [[ "$output" == *"reload"* ]]
  [[ "$output" == *"set-interval"* ]]
}

@test "no args prints help" {
  run bash "$REPO_ROOT/docker/scripts/heartbeatctl"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status"* ]]
}

@test "show dumps conf and crontab and agent.yml heartbeat section" {
  run bash "$REPO_ROOT/docker/scripts/heartbeatctl" show
  [ "$status" -eq 0 ]
  [[ "$output" == *"HEARTBEAT_INTERVAL"* ]]
  [[ "$output" == *"*/30"* ]]           # from the crontab
  [[ "$output" == *"interval: \"2m\""* ]] # from agent.yml
}
```

- [ ] **Step 2: Run tests; expect all to fail**

```bash
bats tests/heartbeatctl.bats
```

Expected: FAIL (script does not exist).

- [ ] **Step 3: Create `docker/scripts/heartbeatctl` skeleton**

```bash
#!/usr/bin/env bash
# heartbeatctl — inspect, control, and mutate the heartbeat.
# Image-baked, workspace-reading. Spec: docs/superpowers/specs/2026-04-19-*.md

set -u

# Overridable paths for tests.
WORKSPACE="${HEARTBEATCTL_WORKSPACE:-/workspace}"
HEARTBEAT_DIR="$WORKSPACE/scripts/heartbeat"
AGENT_YML="$WORKSPACE/agent.yml"
CONF_FILE="$HEARTBEAT_DIR/heartbeat.conf"
STATE_FILE="$HEARTBEAT_DIR/state.json"
RUNS_FILE="$HEARTBEAT_DIR/logs/runs.jsonl"
CRONTAB_FILE="${HEARTBEATCTL_CRONTAB_FILE:-/etc/crontabs/agent}"
LIB_DIR="${HEARTBEATCTL_LIB_DIR:-/opt/agent-admin/scripts/lib}"

# shellcheck source=/dev/null
[ -f "$LIB_DIR/interval.sh" ] && source "$LIB_DIR/interval.sh"
# shellcheck source=/dev/null
[ -f "$LIB_DIR/state.sh" ]    && source "$LIB_DIR/state.sh"

cmd_help() {
  cat <<EOF
heartbeatctl — manage the agent heartbeat.

Read:
  status [--json]         Print human or machine-readable state.
  logs   [-n N] [--json]  Tail logs/runs.jsonl. Default N=20.
  show                    Dump heartbeat.conf + installed crontab + agent.yml section.

Control:
  test   [--prompt "..."] Run one heartbeat now (trigger=manual).
  pause                   Comment crontab line, set enabled=false in agent.yml.
  resume                  Inverse of pause.
  reload                  Re-read agent.yml, regenerate conf + crontab, SIGHUP crond.

Mutate (all atomic with rollback against agent.yml.prev):
  set-interval  <Nm|Nh>
  set-prompt    "<str>"     (or pipe via stdin with no arg)
  set-notifier  <none|log|telegram>
  set-timeout   <seconds>
  set-retries   <0..5>

Exit codes:
  0  success
  1  validation error
  2  operational error (filesystem, yq, crond)

Spec: docs/superpowers/specs/2026-04-19-heartbeat-observability-cli-design.md
EOF
}

cmd_show() {
  echo "=== heartbeat.conf ($CONF_FILE) ==="
  if [ -f "$CONF_FILE" ]; then cat "$CONF_FILE"; else echo "(missing)"; fi
  echo
  echo "=== crontab ($CRONTAB_FILE) ==="
  if [ -f "$CRONTAB_FILE" ]; then cat "$CRONTAB_FILE"; else echo "(missing)"; fi
  echo
  echo "=== agent.yml :: features.heartbeat + notifications ==="
  if [ -f "$AGENT_YML" ]; then
    yq '{features: {heartbeat: .features.heartbeat}, notifications: .notifications}' "$AGENT_YML"
  else
    echo "(missing)"
  fi
}

main() {
  local sub="${1:-help}"; shift || true
  case "$sub" in
    help|-h|--help|"") cmd_help ;;
    show) cmd_show ;;
    *) echo "heartbeatctl: unknown command '$sub' (see 'heartbeatctl help')" >&2; exit 1 ;;
  esac
}

main "$@"
```

Make executable:

```bash
chmod +x docker/scripts/heartbeatctl
```

- [ ] **Step 4: Run tests; expect them to pass**

```bash
bats tests/heartbeatctl.bats
```

Expected: 3 passed.

- [ ] **Step 5: Commit**

```bash
git add docker/scripts/heartbeatctl tests/heartbeatctl.bats
git commit -m "feat(heartbeatctl): skeleton + help + show commands"
```

---

## Task 7: `heartbeatctl reload`

**Files:**
- Modify: `docker/scripts/heartbeatctl`
- Modify: `modules/heartbeat-conf.tpl` (no structural change, but may need `HEARTBEAT_ENABLED` and `HEARTBEAT_CRON` fields)
- Modify: `tests/heartbeatctl.bats`

`reload` is the core mutation: it reads `agent.yml`, regenerates `heartbeat.conf` (directly, without `setup.sh`), rewrites `/etc/crontabs/agent`, ensures `logs/` exists, and sends SIGHUP to crond if it's running. It's invoked on entrypoint boot and by every mutating subcommand.

- [ ] **Step 1: Extend `modules/heartbeat-conf.tpl`**

The current template (check its content first with `cat modules/heartbeat-conf.tpl`). Ensure it includes `HEARTBEAT_ENABLED` and `HEARTBEAT_CRON`. If not, modify to:

```
# Heartbeat — Configuration for {{AGENT_NAME}}
# Generated by setup.sh / heartbeatctl reload. Do not edit by hand — use
# `heartbeatctl set-*` (writes agent.yml + regenerates this file).

HEARTBEAT_ENABLED="{{FEATURES_HEARTBEAT_ENABLED}}"
HEARTBEAT_INTERVAL="{{FEATURES_HEARTBEAT_INTERVAL}}"
HEARTBEAT_CRON=""
HEARTBEAT_TIMEOUT="{{FEATURES_HEARTBEAT_TIMEOUT}}"
HEARTBEAT_RETRIES="{{FEATURES_HEARTBEAT_RETRIES}}"
NOTIFY_SUCCESS_EVERY="1"
HEARTBEAT_PROMPT="{{FEATURES_HEARTBEAT_DEFAULT_PROMPT}}"

NOTIFY_CHANNEL="{{NOTIFICATIONS_CHANNEL}}"
NOTIFY_BOT_TOKEN="${NOTIFY_BOT_TOKEN:-}"
NOTIFY_CHAT_ID="${NOTIFY_CHAT_ID:-}"
```

`HEARTBEAT_CRON` is intentionally left empty in the template — `heartbeatctl reload` computes and writes it. This avoids render-time / runtime divergence.

- [ ] **Step 2: Add failing tests**

Append to `tests/heartbeatctl.bats`:

```bash
@test "reload rewrites heartbeat.conf with HEARTBEAT_CRON derived from interval" {
  run bash "$REPO_ROOT/docker/scripts/heartbeatctl" reload
  [ "$status" -eq 0 ]
  grep -q 'HEARTBEAT_CRON="\*/2 \* \* \* \*"' "$WORKSPACE/heartbeat/heartbeat.conf"
  grep -q 'HEARTBEAT_INTERVAL="2m"' "$WORKSPACE/heartbeat/heartbeat.conf"
}

@test "reload rewrites crontab with new schedule and no user field" {
  run bash "$REPO_ROOT/docker/scripts/heartbeatctl" reload
  [ "$status" -eq 0 ]
  grep -q '^\*/2 \* \* \* \* /workspace/scripts/heartbeat/heartbeat.sh' "$HEARTBEATCTL_CRONTAB_FILE"
  # must not contain "agent" as argv[0]
  ! grep -qE '^[^#]*\* agent ' "$HEARTBEATCTL_CRONTAB_FILE"
}

@test "reload creates logs/ dir if missing" {
  rm -rf "$WORKSPACE/heartbeat/logs"
  run bash "$REPO_ROOT/docker/scripts/heartbeatctl" reload
  [ -d "$WORKSPACE/heartbeat/logs" ]
}

@test "reload fails cleanly when interval is invalid in agent.yml" {
  yq -i '.features.heartbeat.interval = "45m"' "$WORKSPACE/agent.yml"
  run bash "$REPO_ROOT/docker/scripts/heartbeatctl" reload
  [ "$status" -ne 0 ]
  [[ "$output" == *"interval"* || "$output" == *"accepted"* ]]
}
```

- [ ] **Step 3: Run tests; expect them to fail**

```bash
bats tests/heartbeatctl.bats -f "reload"
```

Expected: 4 FAIL.

- [ ] **Step 4: Add `cmd_reload` to `heartbeatctl`**

Insert above `main()`:

```bash
# Read a key from agent.yml, returning empty string on missing.
_yq() { yq "${1}" "$AGENT_YML" 2>/dev/null | sed 's/^null$//'; }

cmd_reload() {
  [ -f "$AGENT_YML" ] || { echo "heartbeatctl: $AGENT_YML missing" >&2; return 2; }

  local enabled interval timeout retries prompt channel cron
  enabled=$(_yq '.features.heartbeat.enabled // true')
  interval=$(_yq '.features.heartbeat.interval // "30m"')
  timeout=$(_yq '.features.heartbeat.timeout // 300')
  retries=$(_yq '.features.heartbeat.retries // 1')
  prompt=$(_yq '.features.heartbeat.default_prompt // "Check status and report"')
  channel=$(_yq '.notifications.channel // "none"')

  # Validate + derive cron
  if ! cron=$(interval_to_cron "$interval" 2>&1); then
    echo "heartbeatctl: $cron" >&2
    return 1
  fi

  # Ensure destination dirs exist
  mkdir -p "$HEARTBEAT_DIR/logs"

  # Rewrite heartbeat.conf atomically
  local tmp_conf
  tmp_conf=$(mktemp)
  cat > "$tmp_conf" <<CONF
# Heartbeat — generated by \`heartbeatctl reload\`. Do not edit by hand.
HEARTBEAT_ENABLED="$enabled"
HEARTBEAT_INTERVAL="$interval"
HEARTBEAT_CRON="$cron"
HEARTBEAT_TIMEOUT="$timeout"
HEARTBEAT_RETRIES="$retries"
NOTIFY_SUCCESS_EVERY="1"
HEARTBEAT_PROMPT="$(printf '%s' "$prompt" | sed 's/"/\\"/g')"
NOTIFY_CHANNEL="$channel"
NOTIFY_BOT_TOKEN="\${NOTIFY_BOT_TOKEN:-}"
NOTIFY_CHAT_ID="\${NOTIFY_CHAT_ID:-}"
CONF
  mv "$tmp_conf" "$CONF_FILE"

  # Rewrite crontab (or comment out if disabled)
  local line
  if [ "$enabled" = "true" ]; then
    line="$cron /workspace/scripts/heartbeat/heartbeat.sh >> /workspace/scripts/heartbeat/logs/cron.log 2>&1"
  else
    line="# paused: $cron /workspace/scripts/heartbeat/heartbeat.sh >> /workspace/scripts/heartbeat/logs/cron.log 2>&1"
  fi
  mkdir -p "$(dirname "$CRONTAB_FILE")"
  local tmp_ct; tmp_ct=$(mktemp)
  cat > "$tmp_ct" <<CT
# Cron for in-container agent heartbeat. Managed by heartbeatctl.
$line
CT
  mv "$tmp_ct" "$CRONTAB_FILE"

  # SIGHUP crond if we can reach it
  if command -v pgrep >/dev/null 2>&1; then
    pkill -HUP -x crond 2>/dev/null || true
  fi

  echo "heartbeatctl: reloaded (interval=$interval cron='$cron' enabled=$enabled channel=$channel)"
}
```

Add to the dispatch in `main()`:

```bash
    reload) cmd_reload ;;
```

- [ ] **Step 5: Run tests; expect them to pass**

```bash
bats tests/heartbeatctl.bats -f "reload"
```

Expected: 4 passed.

- [ ] **Step 6: Commit**

```bash
git add docker/scripts/heartbeatctl modules/heartbeat-conf.tpl tests/heartbeatctl.bats
git commit -m "feat(heartbeatctl): add reload (derives cron from agent.yml, rewrites conf + crontab)"
```

---

## Task 8: `heartbeatctl status` (pretty + --json) and `logs`

**Files:**
- Modify: `docker/scripts/heartbeatctl`
- Modify: `tests/heartbeatctl.bats`

- [ ] **Step 1: Add failing tests**

Append to `tests/heartbeatctl.bats`:

```bash
@test "status --json emits state.json verbatim, enriched with crond" {
  # Seed a state.json
  cat > "$WORKSPACE/heartbeat/state.json" <<'JS'
{"schema":1,"enabled":true,"interval":"2m","cron":"*/2 * * * *","prompt":"Check","notifier_channel":"log","last_run":{"ts":"2026-04-19T01:30:00Z","run_id":"x","status":"ok","duration_ms":1000},"counters":{"total_runs":5,"ok":5,"timeout":0,"error":0,"consecutive_failures":0,"success_rate_24h":1},"next_run_estimate":null,"crond":{"alive":null,"pid":null},"updated_at":"2026-04-19T01:30:00Z"}
JS
  run bash "$REPO_ROOT/docker/scripts/heartbeatctl" status --json
  [ "$status" -eq 0 ]
  run jq -r '.interval' <<<"$output"
  [ "$output" = "2m" ]
  # crond.alive must be a boolean (true or false), not null
  run jq -r '.crond.alive | type' <<<"$output"
  [ "$output" = "boolean" ]
}

@test "status (pretty) contains key fields" {
  cat > "$WORKSPACE/heartbeat/state.json" <<'JS'
{"schema":1,"enabled":true,"interval":"2m","cron":"*/2 * * * *","prompt":"Check","notifier_channel":"log","last_run":{"ts":"2026-04-19T01:30:00Z","run_id":"x","status":"ok","duration_ms":1000},"counters":{"total_runs":5,"ok":5,"timeout":0,"error":0,"consecutive_failures":0,"success_rate_24h":1},"next_run_estimate":null,"crond":{"alive":null,"pid":null},"updated_at":"2026-04-19T01:30:00Z"}
JS
  run bash "$REPO_ROOT/docker/scripts/heartbeatctl" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"2m"* ]]
  [[ "$output" == *"*/2"* ]]
  [[ "$output" == *"5"* ]]
  [[ "$output" == *"ok"* ]]
}

@test "status prints schema error on unknown schema" {
  echo '{"schema":99}' > "$WORKSPACE/heartbeat/state.json"
  run bash "$REPO_ROOT/docker/scripts/heartbeatctl" status
  [ "$status" -ne 0 ]
  [[ "$output" == *"schema"* ]]
}

@test "logs default 20 emits tail of runs.jsonl as table" {
  for i in $(seq 1 30); do
    printf '{"ts":"2026-04-19T01:%02d:00Z","run_id":"r-%02d","status":"ok","duration_ms":100,"attempt":1,"trigger":"cron","prompt":"p%02d"}\n' "$((i%60))" "$i" "$i"
  done > "$WORKSPACE/heartbeat/logs/runs.jsonl"
  run bash "$REPO_ROOT/docker/scripts/heartbeatctl" logs
  [ "$status" -eq 0 ]
  # Should include r-30 (latest) and NOT r-01 (too old under default N=20)
  [[ "$output" == *"r-30"* ]]
  [[ "$output" != *"r-01"* ]]
}

@test "logs --json emits raw lines" {
  printf '{"ts":"t","status":"ok"}\n' > "$WORKSPACE/heartbeat/logs/runs.jsonl"
  run bash "$REPO_ROOT/docker/scripts/heartbeatctl" logs --json
  [ "$status" -eq 0 ]
  run jq -r '.status' <<<"$output"
  [ "$output" = "ok" ]
}
```

- [ ] **Step 2: Run tests; expect them to fail**

```bash
bats tests/heartbeatctl.bats -f "status|logs"
```

Expected: 5 FAIL.

- [ ] **Step 3: Add `cmd_status` and `cmd_logs`**

Insert above `main()`:

```bash
_crond_pid() {
  # Best-effort: return pid of crond, empty if not running
  pgrep -x crond 2>/dev/null | head -1
}

_enrich_state() {
  # Read state.json, overlay crond {alive,pid}, emit to stdout
  local state_raw
  state_raw=$(cat "$STATE_FILE" 2>/dev/null || echo '{}')
  local pid alive
  pid=$(_crond_pid)
  if [ -n "$pid" ]; then alive=true; else alive=false; fi
  printf '%s' "$state_raw" | jq -c --arg pid "$pid" --argjson alive "$alive" '
    .crond = {alive:$alive, pid:($pid | if . == "" then null else tonumber end)}
  '
}

cmd_status() {
  [ -f "$STATE_FILE" ] || { echo "heartbeatctl: $STATE_FILE missing — has the heartbeat ever run? try 'heartbeatctl reload'" >&2; return 2; }
  local schema
  schema=$(jq -r '.schema // 0' "$STATE_FILE" 2>/dev/null || echo 0)
  if [ "$schema" != "1" ]; then
    echo "heartbeatctl: unknown state.json schema '$schema' — refusing to parse" >&2
    return 1
  fi

  local enriched
  enriched=$(_enrich_state)

  if [ "${1:-}" = "--json" ]; then
    printf '%s\n' "$enriched"
    return 0
  fi

  # Pretty
  printf '%s' "$enriched" | jq -r '
    def ago(t): (now - ((t|fromdateiso8601))) | tostring + "s ago";
    "heartbeat: " + (if .enabled then "ENABLED" else "PAUSED" end)
    + "\n  interval: " + .interval + "   cron: " + .cron
    + "\n  prompt:   " + (.prompt | .[0:120] + (if length > 120 then "…" else "" end))
    + "\n  notifier: " + .notifier_channel
    + "\n  last run: " + .last_run.status + "  @ " + .last_run.ts + "  (" + (.last_run.duration_ms|tostring) + "ms, attempt " + (.last_run.attempt|tostring) + ")"
    + "\n  counters: runs=" + (.counters.total_runs|tostring)
      + " ok=" + (.counters.ok|tostring)
      + " timeout=" + (.counters.timeout|tostring)
      + " error=" + (.counters.error|tostring)
      + " streak_fail=" + (.counters.consecutive_failures|tostring)
      + (if .counters.success_rate_24h then "  24h=" + ((.counters.success_rate_24h*100|floor)|tostring) + "%" else "" end)
    + "\n  crond:    " + (if .crond.alive then "alive (pid " + (.crond.pid|tostring) + ")" else "DOWN" end)
    + "\n  updated:  " + .updated_at'
  echo

  # Tail of last 5 runs
  if [ -f "$RUNS_FILE" ]; then
    echo "recent runs:"
    tail -5 "$RUNS_FILE" | jq -r '"  " + .ts + "  " + .status + "  " + (.duration_ms|tostring) + "ms  " + (.prompt | .[0:60])'
  fi
}

cmd_logs() {
  local n=20 json=false
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -n) n="$2"; shift 2 ;;
      --json) json=true; shift ;;
      *) echo "logs: unknown flag '$1'" >&2; return 1 ;;
    esac
  done
  [ -f "$RUNS_FILE" ] || { echo "heartbeatctl: no runs yet"; return 0; }
  if [ "$json" = true ]; then
    tail -n "$n" "$RUNS_FILE"
  else
    printf '%-21s  %-8s  %-7s  %-5s  %s\n' "TS" "STATUS" "DUR" "ATTMPT" "PROMPT"
    tail -n "$n" "$RUNS_FILE" | jq -r '
      [.ts, .status, ((.duration_ms|tostring)+"ms"), (.attempt|tostring), (.prompt|.[0:60])]
      | @tsv' | awk -F'\t' '{printf "%-21s  %-8s  %-7s  %-5s  %s\n", $1,$2,$3,$4,$5}'
  fi
}
```

Add to `main()` dispatch:

```bash
    status) cmd_status "$@" ;;
    logs)   cmd_logs   "$@" ;;
```

- [ ] **Step 4: Run tests; expect them to pass**

```bash
bats tests/heartbeatctl.bats -f "status|logs"
```

Expected: 5 passed.

- [ ] **Step 5: Commit**

```bash
git add docker/scripts/heartbeatctl tests/heartbeatctl.bats
git commit -m "feat(heartbeatctl): add status (pretty + --json) and logs commands"
```

---

## Task 9: `heartbeatctl test`, `pause`, `resume`

**Files:**
- Modify: `docker/scripts/heartbeatctl`
- Modify: `tests/heartbeatctl.bats`

- [ ] **Step 1: Add failing tests**

Append to `tests/heartbeatctl.bats`:

```bash
@test "pause comments crontab line and sets enabled=false in agent.yml" {
  bash "$REPO_ROOT/docker/scripts/heartbeatctl" reload
  run bash "$REPO_ROOT/docker/scripts/heartbeatctl" pause
  [ "$status" -eq 0 ]
  grep -q '^# paused:' "$HEARTBEATCTL_CRONTAB_FILE"
  run yq -r '.features.heartbeat.enabled' "$WORKSPACE/agent.yml"
  [ "$output" = "false" ]
}

@test "resume reverses pause — crontab uncommented, enabled=true" {
  bash "$REPO_ROOT/docker/scripts/heartbeatctl" reload
  bash "$REPO_ROOT/docker/scripts/heartbeatctl" pause
  run bash "$REPO_ROOT/docker/scripts/heartbeatctl" resume
  [ "$status" -eq 0 ]
  grep -q '^\*/2 \* \* \* \*' "$HEARTBEATCTL_CRONTAB_FILE"
  ! grep -q '^# paused:' "$HEARTBEATCTL_CRONTAB_FILE"
  run yq -r '.features.heartbeat.enabled' "$WORKSPACE/agent.yml"
  [ "$output" = "true" ]
}

@test "pause is idempotent" {
  bash "$REPO_ROOT/docker/scripts/heartbeatctl" reload
  bash "$REPO_ROOT/docker/scripts/heartbeatctl" pause
  run bash "$REPO_ROOT/docker/scripts/heartbeatctl" pause
  [ "$status" -eq 0 ]
  # Exactly one paused line, no double-commenting
  local n
  n=$(grep -c '^# paused:' "$HEARTBEATCTL_CRONTAB_FILE")
  [ "$n" = "1" ]
}

@test "test runs heartbeat.sh with trigger=manual and writes a run line" {
  # Stub claude for this test
  mkdir -p "$TMP_TEST_DIR/bin"
  printf '#!/bin/bash\nexit 0\n' > "$TMP_TEST_DIR/bin/claude"
  chmod +x "$TMP_TEST_DIR/bin/claude"
  # Copy heartbeat runner into workspace (it was not there in the minimal fixture)
  cp "$REPO_ROOT/scripts/heartbeat/heartbeat.sh" "$WORKSPACE/heartbeat/"
  cp -R "$REPO_ROOT/scripts/heartbeat/notifiers" "$WORKSPACE/heartbeat/"
  export PATH="$TMP_TEST_DIR/bin:$PATH"
  export HEARTBEAT_STATE_LIB="$REPO_ROOT/docker/scripts/lib/state.sh"
  run bash "$REPO_ROOT/docker/scripts/heartbeatctl" test
  [ "$status" -eq 0 ]
  [ -f "$WORKSPACE/heartbeat/logs/runs.jsonl" ]
  run jq -r '.trigger' "$WORKSPACE/heartbeat/logs/runs.jsonl"
  [ "$output" = "manual" ]
}
```

- [ ] **Step 2: Run tests; expect them to fail**

```bash
bats tests/heartbeatctl.bats -f "pause|resume|test "
```

Expected: 4 FAIL.

- [ ] **Step 3: Add `cmd_pause`, `cmd_resume`, `cmd_test`**

Insert above `main()`:

```bash
cmd_pause() {
  # 1) Set enabled=false in agent.yml
  local prev; prev="$AGENT_YML.prev"
  cp "$AGENT_YML" "$prev"
  yq -i '.features.heartbeat.enabled = false' "$AGENT_YML" || {
    cp "$prev" "$AGENT_YML"; rm -f "$prev"; echo "pause: yq failed" >&2; return 2
  }
  # 2) reload with new state
  if ! cmd_reload; then
    cp "$prev" "$AGENT_YML"; rm -f "$prev"
    cmd_reload >/dev/null 2>&1 || true
    return 2
  fi
  rm -f "$prev"
  echo "heartbeatctl: paused"
}

cmd_resume() {
  local prev; prev="$AGENT_YML.prev"
  cp "$AGENT_YML" "$prev"
  yq -i '.features.heartbeat.enabled = true' "$AGENT_YML" || {
    cp "$prev" "$AGENT_YML"; rm -f "$prev"; echo "resume: yq failed" >&2; return 2
  }
  if ! cmd_reload; then
    cp "$prev" "$AGENT_YML"; rm -f "$prev"
    cmd_reload >/dev/null 2>&1 || true
    return 2
  fi
  rm -f "$prev"
  echo "heartbeatctl: resumed"
}

cmd_test() {
  local prompt=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --prompt) prompt="$2"; shift 2 ;;
      *) echo "test: unknown flag '$1'" >&2; return 1 ;;
    esac
  done
  local runner="$HEARTBEAT_DIR/heartbeat.sh"
  [ -x "$runner" ] || { echo "heartbeatctl: $runner missing or not executable" >&2; return 2; }
  HEARTBEAT_TRIGGER=manual \
  HEARTBEAT_STATE_LIB="${HEARTBEAT_STATE_LIB:-$LIB_DIR/state.sh}" \
    bash "$runner" ${prompt:+--prompt "$prompt"}
}
```

Add to `main()` dispatch:

```bash
    pause)  cmd_pause ;;
    resume) cmd_resume ;;
    test)   shift; cmd_test "$@" ;;
```

- [ ] **Step 4: Run tests; expect them to pass**

```bash
bats tests/heartbeatctl.bats -f "pause|resume|test "
```

Expected: 4 passed.

- [ ] **Step 5: Commit**

```bash
git add docker/scripts/heartbeatctl tests/heartbeatctl.bats
git commit -m "feat(heartbeatctl): add test/pause/resume with atomic rollback"
```

---

## Task 10: Mutation commands (`set-interval`, `set-prompt`, `set-notifier`, `set-timeout`, `set-retries`)

**Files:**
- Modify: `docker/scripts/heartbeatctl`
- Modify: `tests/heartbeatctl.bats`

All mutations share the same transactional wrapper. Validate → back up `agent.yml` → `yq -i` → `reload` → on success delete backup, on failure restore backup + reload and exit non-zero.

- [ ] **Step 1: Add failing tests**

Append to `tests/heartbeatctl.bats`:

```bash
@test "set-interval 15m updates agent.yml and heartbeat.conf" {
  run bash "$REPO_ROOT/docker/scripts/heartbeatctl" set-interval 15m
  [ "$status" -eq 0 ]
  run yq -r '.features.heartbeat.interval' "$WORKSPACE/agent.yml"
  [ "$output" = "15m" ]
  grep -q 'HEARTBEAT_CRON="\*/15 \* \* \* \*"' "$WORKSPACE/heartbeat/heartbeat.conf"
}

@test "set-interval 45m rejected — agent.yml untouched" {
  local before
  before=$(yq -r '.features.heartbeat.interval' "$WORKSPACE/agent.yml")
  run bash "$REPO_ROOT/docker/scripts/heartbeatctl" set-interval 45m
  [ "$status" -ne 0 ]
  run yq -r '.features.heartbeat.interval' "$WORKSPACE/agent.yml"
  [ "$output" = "$before" ]
  [ ! -f "$WORKSPACE/agent.yml.prev" ]
}

@test "set-prompt updates the prompt and conf" {
  run bash "$REPO_ROOT/docker/scripts/heartbeatctl" set-prompt "Report CPU load"
  [ "$status" -eq 0 ]
  run yq -r '.features.heartbeat.default_prompt' "$WORKSPACE/agent.yml"
  [ "$output" = "Report CPU load" ]
  grep -q 'HEARTBEAT_PROMPT="Report CPU load"' "$WORKSPACE/heartbeat/heartbeat.conf"
}

@test "set-notifier log updates channel" {
  run bash "$REPO_ROOT/docker/scripts/heartbeatctl" set-notifier log
  [ "$status" -eq 0 ]
  run yq -r '.notifications.channel' "$WORKSPACE/agent.yml"
  [ "$output" = "log" ]
  grep -q 'NOTIFY_CHANNEL="log"' "$WORKSPACE/heartbeat/heartbeat.conf"
}

@test "set-notifier bogus rejected" {
  run bash "$REPO_ROOT/docker/scripts/heartbeatctl" set-notifier carrier-pigeon
  [ "$status" -ne 0 ]
}

@test "set-timeout validates integer range" {
  run bash "$REPO_ROOT/docker/scripts/heartbeatctl" set-timeout 5
  [ "$status" -ne 0 ]
  run bash "$REPO_ROOT/docker/scripts/heartbeatctl" set-timeout 120
  [ "$status" -eq 0 ]
  run yq -r '.features.heartbeat.timeout' "$WORKSPACE/agent.yml"
  [ "$output" = "120" ]
}

@test "set-retries validates 0..5" {
  run bash "$REPO_ROOT/docker/scripts/heartbeatctl" set-retries 2
  [ "$status" -eq 0 ]
  run bash "$REPO_ROOT/docker/scripts/heartbeatctl" set-retries 10
  [ "$status" -ne 0 ]
  run bash "$REPO_ROOT/docker/scripts/heartbeatctl" set-retries -1
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run tests; expect them to fail**

```bash
bats tests/heartbeatctl.bats -f "set-"
```

Expected: 7 FAIL.

- [ ] **Step 3: Add mutation functions**

Insert above `main()`:

```bash
# _mutate EXPR VALIDATOR VALUE
# Runs validator(value) first; if 0, backs up agent.yml, applies yq -i EXPR,
# runs reload, and on any failure restores agent.yml and reloads with the
# prior state. EXPR uses $V for the value (single-quoted).
_mutate() {
  local expr="$1" validator="$2" value="$3"
  if ! "$validator" "$value"; then return 1; fi
  local prev="$AGENT_YML.prev"
  cp "$AGENT_YML" "$prev"
  if ! V="$value" yq -i "$expr" "$AGENT_YML"; then
    cp "$prev" "$AGENT_YML"; rm -f "$prev"
    echo "heartbeatctl: yq mutation failed" >&2; return 2
  fi
  if ! cmd_reload; then
    cp "$prev" "$AGENT_YML"; rm -f "$prev"
    cmd_reload >/dev/null 2>&1 || true
    echo "heartbeatctl: reload failed after mutation — rolled back" >&2
    return 2
  fi
  rm -f "$prev"
}

# Validators (return 0 on valid, non-zero + stderr message on invalid)
_v_interval() {
  interval_to_cron "$1" >/dev/null 2>&1 || { echo "invalid interval: $1 (see 'heartbeatctl help')" >&2; return 1; }
}
_v_notifier() {
  case "$1" in none|log|telegram) return 0 ;;
    *) echo "invalid notifier: $1 (none|log|telegram)" >&2; return 1 ;;
  esac
}
_v_timeout() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]] && [ "$1" -ge 10 ] || { echo "timeout must be integer >= 10" >&2; return 1; }
}
_v_retries() {
  [[ "$1" =~ ^[0-5]$ ]] || { echo "retries must be integer 0..5" >&2; return 1; }
}
_v_prompt() {
  local len=${#1}
  [ "$len" -gt 0 ] && [ "$len" -le 4000 ] || { echo "prompt must be 1..4000 chars" >&2; return 1; }
}

cmd_set_interval() { _mutate '.features.heartbeat.interval = strenv(V)' _v_interval "$1"; }
cmd_set_notifier() { _mutate '.notifications.channel = strenv(V)'     _v_notifier "$1"; }
cmd_set_timeout()  { _mutate '.features.heartbeat.timeout = (strenv(V)|tonumber)' _v_timeout "$1"; }
cmd_set_retries()  { _mutate '.features.heartbeat.retries = (strenv(V)|tonumber)' _v_retries "$1"; }

cmd_set_prompt() {
  local v="${1:-}"
  if [ -z "$v" ] && [ ! -t 0 ]; then v=$(cat); fi
  _mutate '.features.heartbeat.default_prompt = strenv(V)' _v_prompt "$v"

  # Warn if telegram without secrets
  if [ "$(yq -r '.notifications.channel' "$AGENT_YML")" = "telegram" ]; then
    if ! grep -q '^NOTIFY_BOT_TOKEN=' "$WORKSPACE/.env" 2>/dev/null || \
       ! grep -q '^NOTIFY_CHAT_ID=' "$WORKSPACE/.env" 2>/dev/null; then
      echo "heartbeatctl: WARN — notifications.channel=telegram but .env missing NOTIFY_BOT_TOKEN/NOTIFY_CHAT_ID" >&2
    fi
  fi
}
```

Add to `main()` dispatch:

```bash
    set-interval) shift; cmd_set_interval "${1:-}" ;;
    set-prompt)   shift; cmd_set_prompt   "${1:-}" ;;
    set-notifier) shift; cmd_set_notifier "${1:-}" ;;
    set-timeout)  shift; cmd_set_timeout  "${1:-}" ;;
    set-retries)  shift; cmd_set_retries  "${1:-}" ;;
```

- [ ] **Step 4: Run tests; expect them to pass**

```bash
bats tests/heartbeatctl.bats -f "set-"
```

Expected: 7 passed.

- [ ] **Step 5: Run the full heartbeatctl suite to catch regressions**

```bash
bats tests/heartbeatctl.bats
```

Expected: all tasks' tests passing together.

- [ ] **Step 6: Commit**

```bash
git add docker/scripts/heartbeatctl tests/heartbeatctl.bats
git commit -m "feat(heartbeatctl): add set-* mutations with atomic rollback against agent.yml"
```

---

## Task 11: Wire into Docker — Dockerfile, entrypoint, start_services

**Files:**
- Modify: `docker/Dockerfile`
- Modify: `docker/entrypoint.sh`
- Modify: `docker/scripts/start_services.sh`

- [ ] **Step 1: Modify the Dockerfile to ship heartbeatctl + libs**

Add to `docker/Dockerfile` after the existing `COPY scripts/wizard-container.sh ...` block:

```dockerfile
# Heartbeat CLI and helper libs (image-baked, stable code).
COPY scripts/heartbeatctl /opt/agent-admin/scripts/heartbeatctl
COPY scripts/lib/interval.sh /opt/agent-admin/scripts/lib/interval.sh
COPY scripts/lib/state.sh    /opt/agent-admin/scripts/lib/state.sh
RUN chmod +x /opt/agent-admin/scripts/heartbeatctl \
  && ln -s /opt/agent-admin/scripts/heartbeatctl /usr/local/bin/heartbeatctl
```

Place these lines before the `WORKDIR /workspace` line.

- [ ] **Step 2: Modify `docker/entrypoint.sh`**

Current contents add crond + chown. Replace the relevant block so that:
1. The existing chown of `/home/agent` stays.
2. New: chown `/workspace/scripts/heartbeat` to `agent:agent` if the dir exists.
3. Existing envsubst of crontab.tpl stays (safe default until reload).
4. **New: launch `crond -b` as ROOT** (before the su-exec handoff).
5. After su-exec, have `start_services.sh` call `heartbeatctl reload` as its first step.

Full updated `docker/entrypoint.sh`:

```bash
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

# 2. Ensure workspace heartbeat dir is agent-owned (idempotent)
if [ -d "$WORKSPACE/scripts/heartbeat" ]; then
  log "chowning $WORKSPACE/scripts/heartbeat to agent:agent"
  chown -R agent:agent "$WORKSPACE/scripts/heartbeat"
fi

# 3. Render a safe-default crontab so crond has something to watch until
#    heartbeatctl reload overwrites it.
if [ -f /opt/agent-admin/crontab.tpl ]; then
  export HEARTBEAT_CRON="${HEARTBEAT_CRON:-*/30 * * * *}"
  envsubst < /opt/agent-admin/crontab.tpl > "$CRONTAB_DST"
  chmod 0644 "$CRONTAB_DST"
  log "crontab rendered (default)"
fi

# 4. Start crond as ROOT so it can setgid on job dispatch.
if ! pgrep -x crond >/dev/null 2>&1; then
  crond -b -L /workspace/claude.cron.log
  log "crond started (root)"
fi

# 5. Refresh CONTAINER.md
if [ -x /opt/agent-admin/scripts/write_container_info.sh ]; then
  su-exec agent /opt/agent-admin/scripts/write_container_info.sh || log "WARN: container-info refresh failed (non-fatal)"
fi

# 6. Drop to agent and hand off to the supervisor.
log "starting services"
exec su-exec agent /opt/agent-admin/scripts/start_services.sh
```

- [ ] **Step 3: Modify `docker/scripts/start_services.sh`**

- Remove the crond launch (now in entrypoint).
- As the first action, invoke `heartbeatctl reload` so the crontab reflects `agent.yml`.
- Add a crond-liveness check to the watchdog: if crond dies, exit 1 (Docker restarts the container).

Find the existing crond launch in start_services.sh and remove it. Add at the top, after loading any config:

```bash
# Reload the heartbeat schedule from agent.yml. Tolerate reload failure —
# the default crontab from entrypoint is still in place.
if command -v heartbeatctl >/dev/null 2>&1; then
  heartbeatctl reload || echo "WARN: heartbeatctl reload failed, using default crontab" >&2
fi
```

In the watchdog loop, add the crond check:

```bash
# (inside the existing "while true" loop, alongside tmux/claude checks)
if ! pgrep -x crond >/dev/null 2>&1; then
  echo "CRITICAL: crond died — exiting container (docker restart policy will revive)"
  exit 1
fi
```

- [ ] **Step 4: Sanity-check the Dockerfile with a build (no e2e yet)**

```bash
docker build -t agent-admin:test ./docker
```

Expected: builds without errors.

- [ ] **Step 5: Commit**

```bash
git add docker/Dockerfile docker/entrypoint.sh docker/scripts/start_services.sh
git commit -m "feat(docker): wire heartbeatctl, move crond launch to root, add chown for heartbeat dir"
```

---

## Task 12: Docker e2e test

**Files:**
- Create: `tests/docker-e2e-heartbeat.bats`

- [ ] **Step 1: Write the e2e test**

Create `tests/docker-e2e-heartbeat.bats`:

```bash
#!/usr/bin/env bats
# Docker e2e: scaffolds a test agent, boots it, waits for one real heartbeat
# tick, asserts runs.jsonl shape.
#
# Skipped by default (slow + requires Docker). Enable with DOCKER_E2E=1.

load helper

setup() {
  if [ "${DOCKER_E2E:-0}" != "1" ]; then skip "set DOCKER_E2E=1 to run"; fi
  setup_tmp_dir
  export DEST="$TMP_TEST_DIR/agent-e2e"
  export AGENT_NAME="hb-e2e"
}
teardown() {
  if [ -d "$DEST" ]; then
    (cd "$DEST" && docker compose down -v --remove-orphans || true)
  fi
  teardown_tmp_dir
}

@test "fresh scaffold → container boot → 1-minute cron tick → runs.jsonl has ok entry" {
  # 1) non-interactive scaffold: write agent.yml directly, skip wizard
  mkdir -p "$DEST"
  cat > "$DEST/agent.yml" <<YML
version: 1
agent: {name: $AGENT_NAME, display_name: "e2e 🧪", role: "test", vibe: "terse"}
user: {name: "Tester", nickname: "Tester", timezone: "UTC", email: "t@e.x", language: "en"}
deployment: {host: "test", workspace: "$DEST", install_service: false, claude_cli: "claude"}
docker: {image_tag: "agent-admin:e2e", uid: $(id -u), gid: $(id -g), state_volume: "${AGENT_NAME}-state", base_image: "alpine:3.20"}
claude: {config_dir: "/home/agent/.claude", profile_new: true}
notifications: {channel: none}
features:
  heartbeat: {enabled: true, interval: "1m", timeout: 30, retries: 0, default_prompt: "echo pong"}
mcps: {defaults: [], atlassian: [], github: {enabled: false, email: ""}}
plugins: []
YML
  cp -R "$REPO_ROOT/modules" "$REPO_ROOT/scripts" "$REPO_ROOT/docker" "$DEST/"
  cp "$REPO_ROOT/setup.sh" "$DEST/"
  chmod +x "$DEST/setup.sh"

  # 2) regenerate derived files
  (cd "$DEST" && ./setup.sh --regenerate --non-interactive)

  # 3) build + up (no telegram, so no wizard block)
  (cd "$DEST" && docker compose build)
  # write a stub claude so the container doesn't need /login
  docker run --rm -v "$DEST:/workspace" agent-admin:e2e sh -c \
    'mkdir -p /workspace/stubs && printf "#!/bin/sh\nexit 0\n" > /workspace/stubs/claude && chmod +x /workspace/stubs/claude'
  # Stub: override PATH in a drop-in so heartbeat.sh finds our stub first
  # (simpler: create an .env entry PATH=/workspace/stubs:... — but setup's
  # entrypoint would complain. For e2e, we accept a real claude failure and
  # assert status=error instead.)

  (cd "$DEST" && docker compose up -d)

  # 4) wait up to 90s for the first tick
  local deadline=$(( $(date +%s) + 90 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if [ -f "$DEST/scripts/heartbeat/logs/runs.jsonl" ]; then break; fi
    sleep 5
  done
  [ -f "$DEST/scripts/heartbeat/logs/runs.jsonl" ]
  # Accept ok OR error (claude stub may not be on PATH inside the container);
  # the point is that the run executed and a line was written.
  run jq -r '.status' "$DEST/scripts/heartbeat/logs/runs.jsonl"
  [ "$status" -eq 0 ]
  [[ "$output" == "ok" || "$output" == "error" ]]
  run jq -r '.trigger' "$DEST/scripts/heartbeat/logs/runs.jsonl"
  [ "$output" = "cron" ]
}
```

- [ ] **Step 2: Run the test in the opt-in mode**

```bash
DOCKER_E2E=1 bats tests/docker-e2e-heartbeat.bats
```

Expected: PASS (takes ~2 minutes). If claude is unavailable inside the container, the assertion `status == "error"` still passes — what we're really verifying is that the cron → heartbeat.sh → runs.jsonl chain is intact.

- [ ] **Step 3: Commit**

```bash
git add tests/docker-e2e-heartbeat.bats
git commit -m "test(heartbeat): add docker e2e — cron tick writes runs.jsonl"
```

---

## Task 13: Docs + changelog

**Files:**
- Modify: `docs/architecture.md`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Add a heartbeat section to `docs/architecture.md`**

Append the following section before `## See Also`:

```markdown
## Heartbeat Pipeline

The heartbeat is a single scheduled task per agent. `/etc/crontabs/agent`
is rendered by `heartbeatctl reload` from `agent.yml`. Busybox crond runs
as root so it can `setgid(agent)` when dispatching the job; `heartbeat.sh`
runs as `agent`.

```
/etc/crontabs/agent (busybox user crontab, no user field)
     │  every N min
     ▼
heartbeat.sh (as agent)
  ├─ gen_run_id  →  20260419013000-a3f2
  ├─ tmux new -d -s <agent>-hb-<run_id>  "claude --print <prompt>"
  ├─ wait until HEARTBEAT_DONE or timeout
  ├─ notifiers/<channel>.sh <run_id> <status> → JSON envelope
  ├─ append_run_line   → logs/runs.jsonl
  ├─ write_state_json  → state.json (atomic)
  └─ rotate_runs_jsonl → gz rotation at 10MB
```

Inspection and mutation go through a single CLI:

```bash
heartbeatctl status            # pretty, reads state.json + pgrep crond
heartbeatctl status --json     # raw state.json, enriched with crond.alive
heartbeatctl logs -n 50        # tail runs.jsonl as table
heartbeatctl test              # run one tick now, trigger=manual
heartbeatctl pause / resume    # toggle enabled in agent.yml + crontab
heartbeatctl reload            # re-render conf + crontab from agent.yml
heartbeatctl set-interval 2m   # yq -i on agent.yml + reload (atomic rollback)
```

`agent.yml` is the single source of truth. Every mutation backs up to
`agent.yml.prev`, applies via `yq -i`, then regenerates derived files; any
failure restores the backup and re-runs `reload` against the prior state.
```

- [ ] **Step 2: Append to `CHANGELOG.md`**

```markdown
## [Unreleased]

- fix(heartbeat): propagate `HEARTBEAT_INTERVAL` into the cron schedule
  (`heartbeatctl reload` derives `*/N * * * *` from `agent.yml`).
- fix(heartbeat): drop the user field from `/etc/crontabs/agent` — busybox
  user-crontabs implicit the user via filename.
- fix(heartbeat): launch `crond` as root from the entrypoint so job
  dispatch can `setgid(agent)` cleanly; `start_services.sh` only monitors.
- fix(heartbeat): entrypoint chowns `/workspace/scripts/heartbeat` on boot
  to match `agent` UID/GID on the host.
- feat(heartbeat): `runs.jsonl` structured trace (one JSON line per run)
  with `run_id` correlation, `notifier` envelope embedded, size-based gz
  rotation at 10MB keeping 3 generations.
- feat(heartbeat): `state.json` atomic snapshot of last run + counters
  (`total_runs`, `ok`, `timeout`, `error`, `consecutive_failures`,
  `success_rate_24h`), enriched with live `crond.alive`/`pid` at read time.
- feat(heartbeatctl): single CLI with `status`, `logs`, `show`, `test`,
  `pause`, `resume`, `reload`, and mutable `set-interval`/`set-prompt`/
  `set-notifier`/`set-timeout`/`set-retries`. All mutations are atomic
  against `agent.yml` with rollback on failure.
- feat(notifiers): standardized JSON-envelope contract on stdout
  (`{channel, ok, latency_ms, error}`); notifiers always exit 0.
```

- [ ] **Step 3: Commit**

```bash
git add docs/architecture.md CHANGELOG.md
git commit -m "docs: document heartbeat pipeline + heartbeatctl; changelog for base-pipeline fixes"
```

---

## Self-Review

**Spec coverage:**
- Bugs 1–6 covered by Tasks 1, 7, 11 (interval propagation via reload; crontab user field dropped; crond root; chown; logs/ created by reload; launch.sh is documented as naturally dropped via re-scaffold).
- `runs.jsonl` contract: Task 5.
- `state.json` contract: Task 5 (writer) + Task 8 (status enrichment).
- Notifier contract: Task 4.
- CLI reference (status/logs/show/test/pause/resume/reload/set-*): Tasks 6, 7, 8, 9, 10.
- Rotation policy: Task 3 (lib) + Task 5 (invocation).
- Lifecycle scenarios: exercised in Tasks 5, 11, 12.
- File-level impact matrix: Tasks 1–11 cover every row.
- Test strategy: Tasks 2, 3, 4, 5, 6–10 (heartbeatctl), 12 (e2e) cover every listed file.

**Placeholder scan:** no TBDs. Every step has executable code or an exact command.

**Type consistency:**
- Library function names used consistently across tasks: `interval_to_cron`, `gen_run_id`, `append_run_line`, `write_state_json`, `rotate_runs_jsonl`.
- CLI command names match the spec: `status`, `logs`, `show`, `test`, `pause`, `resume`, `reload`, `set-interval`, `set-prompt`, `set-notifier`, `set-timeout`, `set-retries`.
- Env var names consistent: `HEARTBEATCTL_WORKSPACE`, `HEARTBEATCTL_CRONTAB_FILE`, `HEARTBEATCTL_LIB_DIR`, `HEARTBEAT_STATE_LIB`, `HEARTBEAT_TRIGGER`, `NOTIFY_TELEGRAM_API_BASE`.
- JSON field names match the spec: `ts`, `run_id`, `trigger`, `status`, `attempt`, `duration_ms`, `claude_exit_code`, `prompt`, `tmux_session`, `notifier.{channel,ok,latency_ms,error}`; state fields `schema`, `enabled`, `interval`, `cron`, `prompt`, `notifier_channel`, `last_run`, `counters.{total_runs,ok,timeout,error,consecutive_failures,success_rate_24h}`, `next_run_estimate`, `crond.{alive,pid}`, `updated_at`.
- Return-code conventions consistent: 0 success, 1 validation, 2 operational.
