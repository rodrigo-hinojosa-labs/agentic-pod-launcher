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
