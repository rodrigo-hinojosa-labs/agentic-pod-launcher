#!/usr/bin/env bash
notify_log() {
  local msg="$1"
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  mkdir -p "${LOG_DIR:-/tmp}"
  echo "[$ts] $msg" >> "${LOG_DIR:-/tmp}/notifications.log"
}
