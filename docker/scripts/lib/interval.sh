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
