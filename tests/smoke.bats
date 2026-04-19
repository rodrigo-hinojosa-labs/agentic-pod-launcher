#!/usr/bin/env bats

load helper

@test "test harness loads" {
  [ -d "$REPO_ROOT" ]
}
