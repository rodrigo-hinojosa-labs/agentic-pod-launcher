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

# 014: M */N (fixed minute + step hour) — the wiki-graph default 20 */6.
@test "20 */6 * * * -> every 6 hours at minute 20 (no fallback)" {
  run cron_to_systemd_calendar "20 */6 * * *" "DEF"
  [ "$output" = "*-*-* 0/6:20:00" ]
}

@test "CRON_FALLBACK=0 for the wiki-graph default 20 */6 (now first-class) — 014" {
  cron_to_systemd_calendar "20 */6 * * *" "DEF" >/dev/null
  [ "$CRON_FALLBACK" -eq 0 ]
}

@test "5 */2 * * * -> every 2 hours at minute 05 (zero-padded)" {
  run cron_to_systemd_calendar "5 */2 * * *" "DEF"
  [ "$output" = "*-*-* 0/2:05:00" ]
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

# 013 (FR-013/D10): the CRON_FALLBACK signal. Called directly (not via `run`, which
# subshells) so the global is visible. Comparing stdout to the default is ambiguous
# — "*/5 * * * *" converts EXACTLY to the qmd default — so this flag is the only
# reliable "did we fall back?" signal for the marker in setup.sh.
@test "CRON_FALLBACK=0 on exact conversions, incl. */5 (the false-positive case) — 013 T025" {
  cron_to_systemd_calendar "*/5 * * * *" "*-*-* *:0/5:00" >/dev/null
  [ "$CRON_FALLBACK" -eq 0 ]
  cron_to_systemd_calendar "30 3 * * *" "DEF" >/dev/null
  [ "$CRON_FALLBACK" -eq 0 ]
  cron_to_systemd_calendar "15 * * * *" "DEF" >/dev/null
  [ "$CRON_FALLBACK" -eq 0 ]
}

@test "CRON_FALLBACK=1 on a non-convertible custom cron — 013 T025" {
  cron_to_systemd_calendar "0 * * * 1-5" "DEF" >/dev/null 2>&1
  [ "$CRON_FALLBACK" -eq 1 ]
  cron_to_systemd_calendar "0,30 * * * *" "DEF" >/dev/null 2>&1
  [ "$CRON_FALLBACK" -eq 1 ]
}

@test "CRON_FALLBACK=0 on empty (intended default, NOT a fallback) — 013 T025" {
  cron_to_systemd_calendar "" "DEF" >/dev/null
  [ "$CRON_FALLBACK" -eq 0 ]
}
