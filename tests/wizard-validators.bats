#!/usr/bin/env bats
load 'helper'

setup() {
  # shellcheck source=/dev/null
  source "$BATS_TEST_DIRNAME/../scripts/lib/wizard-validators.sh"
}

# ── validate_email ──────────────────────────────────────────

@test "validate_email accepts standard addresses" {
  validate_email "alice@example.com"
  validate_email "alice+tag@example.co"
  validate_email "user.name@sub.example.org"
  validate_email "rodrigo.andres.hinojosa.acuna@gmail.com"
}

@test "validate_email rejects missing @" {
  run validate_email "not-an-email"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a valid email"* ]]
}

@test "validate_email rejects missing TLD" {
  run validate_email "alice@example"
  [ "$status" -eq 1 ]
}

@test "validate_email rejects whitespace" {
  run validate_email "alice @example.com"
  [ "$status" -eq 1 ]
}

# ── validate_telegram_token ─────────────────────────────────

@test "validate_telegram_token accepts BotFather-style tokens" {
  validate_telegram_token "123456789:AAEhBP0av5XO2BAi3Yfb-DLp7iE"
  validate_telegram_token "9999999999:abcdefghijklmnopqrstuvwxyz0123456789ABC"
}

@test "validate_telegram_token rejects missing colon" {
  run validate_telegram_token "123456789AAEhBP0av5XO2BAi3Yfb_DLp7iE"
  [ "$status" -eq 1 ]
}

@test "validate_telegram_token rejects body shorter than 25 chars" {
  run validate_telegram_token "12345:tooShort"
  [ "$status" -eq 1 ]
}

@test "validate_telegram_token rejects letters before colon" {
  run validate_telegram_token "abc:AAEhBP0av5XO2BAi3Yfb_DLp7iE"
  [ "$status" -eq 1 ]
}

# ── validate_timezone ───────────────────────────────────────

@test "validate_timezone accepts well-known IANA zones" {
  validate_timezone "UTC"
  validate_timezone "America/Santiago"
  validate_timezone "Europe/Madrid"
}

@test "validate_timezone rejects free-form text" {
  run validate_timezone "hace 2 horas"
  [ "$status" -eq 1 ]
}

@test "validate_timezone rejects 'Chile time' style names" {
  run validate_timezone "Chile time"
  [ "$status" -eq 1 ]
}

# ── validate_cron_or_interval ───────────────────────────────

@test "validate_cron_or_interval accepts short forms" {
  validate_cron_or_interval "30m"
  validate_cron_or_interval "2h"
  validate_cron_or_interval "5m"
}

@test "validate_cron_or_interval accepts 5-field cron" {
  validate_cron_or_interval "0 * * * *"
  validate_cron_or_interval "*/15 * * * *"
  validate_cron_or_interval "30 3 * * *"
}

@test "validate_cron_or_interval rejects natural language" {
  run validate_cron_or_interval "every hour"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a valid interval"* ]]
}

@test "validate_cron_or_interval rejects 4-field cron" {
  run validate_cron_or_interval "0 * * *"
  [ "$status" -eq 1 ]
}

@test "validate_cron_or_interval rejects misspelled units" {
  run validate_cron_or_interval "30min"
  [ "$status" -eq 1 ]
}

# ── validate_agent_name ─────────────────────────────────────

@test "validate_agent_name accepts simple names" {
  validate_agent_name "myagent"
  validate_agent_name "test-agent"
  validate_agent_name "agent01"
  validate_agent_name "a"
}

@test "validate_agent_name rejects uppercase" {
  run validate_agent_name "MyAgent"
  [ "$status" -eq 1 ]
}

@test "validate_agent_name rejects leading hyphen" {
  run validate_agent_name "-agent"
  [ "$status" -eq 1 ]
}

@test "validate_agent_name rejects trailing hyphen" {
  run validate_agent_name "agent-"
  [ "$status" -eq 1 ]
}

@test "validate_agent_name rejects underscores" {
  run validate_agent_name "my_agent"
  [ "$status" -eq 1 ]
}

@test "validate_agent_name rejects names longer than 63" {
  run validate_agent_name "a23456789012345678901234567890123456789012345678901234567890123456"
  [ "$status" -eq 1 ]
  [[ "$output" == *"1..63"* ]]
}

@test "validate_agent_name rejects double hyphens" {
  run validate_agent_name "my--agent"
  [ "$status" -eq 1 ]
  [[ "$output" == *"double hyphens"* ]]
}

# ── validate_url ────────────────────────────────────────────

@test "validate_url accepts https" {
  validate_url "https://example.com"
  validate_url "https://my-org.atlassian.net"
  validate_url "https://github.com/user/repo.git"
}

@test "validate_url accepts http for local dev" {
  validate_url "http://localhost:8080"
}

@test "validate_url rejects bare host" {
  run validate_url "example.com"
  [ "$status" -eq 1 ]
}

@test "validate_url rejects ftp scheme" {
  run validate_url "ftp://example.com"
  [ "$status" -eq 1 ]
}

@test "validate_url rejects whitespace" {
  run validate_url "https://example .com"
  [ "$status" -eq 1 ]
  [[ "$output" == *"whitespace"* ]]
}

# ── validate_uid_gid ────────────────────────────────────────

@test "validate_uid_gid accepts non-negative integers" {
  validate_uid_gid "0"
  validate_uid_gid "1000"
  validate_uid_gid "501"
}

@test "validate_uid_gid rejects negatives" {
  run validate_uid_gid "-1"
  [ "$status" -eq 1 ]
}

@test "validate_uid_gid rejects letters" {
  run validate_uid_gid "abc"
  [ "$status" -eq 1 ]
}

@test "validate_uid_gid rejects empty" {
  run validate_uid_gid ""
  [ "$status" -eq 1 ]
}

# ── validate_workspace_path ─────────────────────────────────

@test "validate_workspace_path accepts an absolute path with writable parent" {
  validate_workspace_path "$BATS_TEST_TMPDIR/myagent"
}

@test "validate_workspace_path rejects relative paths" {
  run validate_workspace_path "myagent"
  [ "$status" -eq 1 ]
  [[ "$output" == *"absolute"* ]]
}

@test "validate_workspace_path rejects path traversal" {
  run validate_workspace_path "/tmp/foo/../../etc/passwd"
  [ "$status" -eq 1 ]
  [[ "$output" == *".."* ]]
}

@test "validate_workspace_path rejects parent that does not exist" {
  run validate_workspace_path "/this/path/almost/certainly/does/not/exist/myagent"
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not exist"* ]]
}
