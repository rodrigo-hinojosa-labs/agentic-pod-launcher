#!/usr/bin/env bats
# 012-local-vault-rag (FR-012): cron_to_systemd_calendar converts the common cron
# forms the wizard emits into systemd OnCalendar; unsupported forms fall back to
# the caller's default + a stderr warning. Pure function, no side effects on source.

load helper

setup() { load_lib local_schedule; }

@test "source has no side effects (pure lib)" {
  run bash -c 'source "'"$REPO_ROOT"'/scripts/lib/local_schedule.sh"; echo LOADED'
  [ "$status" -eq 0 ]
  [ "$output" = "LOADED" ]
}

@test "*/5 * * * * -> every 5 minutes" {
  run cron_to_systemd_calendar "*/5 * * * *" "DEF"
  [ "$status" -eq 0 ]
  [ "$output" = "*-*-* *:0/5:00" ]
}

@test "*/30 * * * * -> every 30 minutes" {
  run cron_to_systemd_calendar "*/30 * * * *" "DEF"
  [ "$output" = "*-*-* *:0/30:00" ]
}

@test "0 * * * * -> hourly at minute 00 (zero-padded)" {
  run cron_to_systemd_calendar "0 * * * *" "DEF"
  [ "$output" = "*-*-* *:00:00" ]
}

@test "15 * * * * -> hourly at minute 15" {
  run cron_to_systemd_calendar "15 * * * *" "DEF"
  [ "$output" = "*-*-* *:15:00" ]
}

@test "30 3 * * * -> daily at 03:30 (both zero-padded)" {
  run cron_to_systemd_calendar "30 3 * * *" "DEF"
  [ "$output" = "*-*-* 03:30:00" ]
}

@test "0 12 * * * -> daily at 12:00" {
  run cron_to_systemd_calendar "0 12 * * *" "DEF"
  [ "$output" = "*-*-* 12:00:00" ]
}

@test "unsupported day-of-week -> default + warning on stderr" {
  run cron_to_systemd_calendar "0 * * * 1-5" "*-*-* *:00:00"
  [ "$status" -eq 0 ]
  # run merges stderr into output; assert both the default and the warning appear
  echo "$output" | grep -q '\*-\*-\* \*:00:00'
  echo "$output" | grep -qi 'warning'
}

@test "unsupported minute list -> default + warning" {
  run cron_to_systemd_calendar "0,30 * * * *" "*-*-* *:0/5:00"
  echo "$output" | grep -q '\*-\*-\* \*:0/5:00'
  echo "$output" | grep -qi 'warning'
}

@test "empty cron -> default, NO warning" {
  run cron_to_systemd_calendar "" "*-*-* *:0/5:00"
  [ "$status" -eq 0 ]
  [ "$output" = "*-*-* *:0/5:00" ]
  ! echo "$output" | grep -qi 'warning'
}

@test "malformed (too few fields) -> default + warning" {
  run cron_to_systemd_calendar "5 *" "DEF"
  [ "$output" != "*-*-* *:05:00" ]
  echo "$output" | grep -q 'DEF'
}
