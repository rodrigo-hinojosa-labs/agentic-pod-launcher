#!/bin/bash
# state.sh — helpers for heartbeat state and trace files.
#
# All functions are pure in the sense that their only side effects are to
# files they are explicitly given as arguments. Callers (heartbeat.sh,
# heartbeatctl) compose them.

# gen_run_id — YYYYMMDDHHMMSS-XXXX where XXXX is 4 random hex chars.
# bash $RANDOM is 15-bit (0..32767), so the suffix lives in 0x0000..0x7fff —
# same-second collision probability is ~1/32768. Good enough for a single-
# agent heartbeat that runs at most every minute.
gen_run_id() {
  local ts suf
  ts=$(date -u +%Y%m%d%H%M%S)
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
