# shellcheck shell=bash
# Library: cron → systemd OnCalendar conversion for local-mode timers (012).
#
# Sourced by BOTH setup.sh (render-time, to compute {{QMD_TIMER_ONCALENDAR}} /
# {{BACKUP_TIMER_ONCALENDAR}}) and tests/local-schedule.bats. Pure function —
# sourcing has NO side effects (Principle III). No dependencies.
#
# agent.yml keeps schedules in cron syntax (single source, shared with docker's
# crond). Local mode converts the COMMON forms the wizard emits; any other form
# falls back to the caller's default OnCalendar string + a stderr warning, so a
# hand-edited exotic cron degrades visibly instead of producing an invalid timer.

# cron_to_systemd_calendar CRON_EXPR DEFAULT_ONCALENDAR → stdout: OnCalendar
#   Supported:  "*/N * * * *" → "*-*-* *:0/N:00"   (every N minutes)
#               "M * * * *"   → "*-*-* *:MM:00"    (hourly at minute M)
#               "M H * * *"   → "*-*-* HH:MM:00"   (daily at H:M)
#   Empty CRON_EXPR → DEFAULT, no warning (the "use default" case).
#   Anything else   → DEFAULT + a WARNING on stderr. Always rc 0.
cron_to_systemd_calendar() {
  local cron="${1:-}" default="${2:-}"
  # Empty → default, silently (this is the "no schedule set, use default" path).
  if [ -z "$cron" ]; then
    printf '%s\n' "$default"
    return 0
  fi

  local min hr dom mon dow extra
  read -r min hr dom mon dow extra <<< "$cron"

  local re_step='^\*/([0-9]+)$'
  local re_num='^[0-9]+$'

  # Only whole-field wildcards for day-of-month / month / day-of-week are
  # supported; and never a 6th field.
  if [ -n "$extra" ] || [ "$dom" != "*" ] || [ "$mon" != "*" ] || [ "$dow" != "*" ]; then
    _cron_fallback "$cron" "$default"
    return 0
  fi

  # */N * * * *  → every N minutes
  if [[ "$min" =~ $re_step ]] && [ "$hr" = "*" ]; then
    printf '*-*-* *:0/%s:00\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  # M * * * *  → hourly at minute M
  if [[ "$min" =~ $re_num ]] && [ "$hr" = "*" ]; then
    printf '*-*-* *:%02d:00\n' "$((10#$min))"
    return 0
  fi
  # M H * * *  → daily at H:M
  if [[ "$min" =~ $re_num ]] && [[ "$hr" =~ $re_num ]]; then
    printf '*-*-* %02d:%02d:00\n' "$((10#$hr))" "$((10#$min))"
    return 0
  fi

  _cron_fallback "$cron" "$default"
}

_cron_fallback() {
  printf 'WARNING: unsupported cron schedule "%s" — using default OnCalendar "%s"\n' "$1" "$2" >&2
  printf '%s\n' "$2"
}
