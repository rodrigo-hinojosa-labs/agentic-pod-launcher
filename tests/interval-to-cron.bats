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
  [[ "$output" == *"{1,2,3,4,5,6,10,12,15,20,30}"* ]]
}
@test "interval_to_cron rejects 7m" {
  run interval_to_cron 7m
  [ "$status" -ne 0 ]
}
@test "interval_to_cron rejects 5h (not a divisor of 24)" {
  run interval_to_cron 5h
  [ "$status" -ne 0 ]
  [[ "$output" == *"{1,2,3,4,6,8,12,24}"* ]]
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

@test "interval_to_cron 3m -> */3 * * * *" {
  run interval_to_cron 3m
  [ "$status" -eq 0 ]; [ "$output" = "*/3 * * * *" ]
}
@test "interval_to_cron 4m -> */4 * * * *" {
  run interval_to_cron 4m
  [ "$status" -eq 0 ]; [ "$output" = "*/4 * * * *" ]
}
@test "interval_to_cron 5m -> */5 * * * *" {
  run interval_to_cron 5m
  [ "$status" -eq 0 ]; [ "$output" = "*/5 * * * *" ]
}
@test "interval_to_cron 6m -> */6 * * * *" {
  run interval_to_cron 6m
  [ "$status" -eq 0 ]; [ "$output" = "*/6 * * * *" ]
}
@test "interval_to_cron 10m -> */10 * * * *" {
  run interval_to_cron 10m
  [ "$status" -eq 0 ]; [ "$output" = "*/10 * * * *" ]
}
@test "interval_to_cron 12m -> */12 * * * *" {
  run interval_to_cron 12m
  [ "$status" -eq 0 ]; [ "$output" = "*/12 * * * *" ]
}
@test "interval_to_cron 20m -> */20 * * * *" {
  run interval_to_cron 20m
  [ "$status" -eq 0 ]; [ "$output" = "*/20 * * * *" ]
}
@test "interval_to_cron 3h -> 0 */3 * * *" {
  run interval_to_cron 3h
  [ "$status" -eq 0 ]; [ "$output" = "0 */3 * * *" ]
}
@test "interval_to_cron 4h -> 0 */4 * * *" {
  run interval_to_cron 4h
  [ "$status" -eq 0 ]; [ "$output" = "0 */4 * * *" ]
}
@test "interval_to_cron 6h -> 0 */6 * * *" {
  run interval_to_cron 6h
  [ "$status" -eq 0 ]; [ "$output" = "0 */6 * * *" ]
}
@test "interval_to_cron 8h -> 0 */8 * * *" {
  run interval_to_cron 8h
  [ "$status" -eq 0 ]; [ "$output" = "0 */8 * * *" ]
}
@test "interval_to_cron 12h -> 0 */12 * * *" {
  run interval_to_cron 12h
  [ "$status" -eq 0 ]; [ "$output" = "0 */12 * * *" ]
}
