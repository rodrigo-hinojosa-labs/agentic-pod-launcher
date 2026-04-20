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
  [ "$(wc -l < "$HEARTBEAT_DIR/logs/runs.jsonl" | tr -d ' ')" = "2" ]
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
  [ ! -f "$f" ]   # primary moved to .1; must be gone, not just empty
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
