#!/usr/bin/env bats
# 015 Foundational: shared observability helpers for the RAG maintenance runners.
#   - redact_secrets: mask credentials before any stderr/env dump reaches a log or
#     state file (Principle V — secrets never logged).
#   - scratch_dir: ensure a host-backed scratch dir under a base, echoing it, so
#     the runners can route TMPDIR off the small tmpfs /tmp (US3).
# Host-runnable: pure text/dir functions, no Docker, no network.

load 'helper'

setup() {
  setup_tmp_dir
  load_lib rag_obs
}

teardown() { teardown_tmp_dir; }

@test "redact_secrets: masks Anthropic keys/oauth tokens" {
  out=$(printf 'ANTHROPIC_API_KEY=sk-ant-oat01-AbC123_def-456 trailing\n' | redact_secrets)
  echo "$out" | grep -q 'REDACTED' && ! echo "$out" | grep -q 'AbC123_def-456'
}

@test "redact_secrets: masks GitHub tokens" {
  out=$(printf 'token ghp_AbCdEf0123456789XyZ tail\n' | redact_secrets)
  echo "$out" | grep -q 'REDACTED' && ! echo "$out" | grep -q 'ghp_AbCdEf0123456789XyZ'
}

@test "redact_secrets: masks Telegram-style bot tokens" {
  out=$(printf 'BOT=8835512065:AAExampleTokenValue1234567890abcdef done\n' | redact_secrets)
  echo "$out" | grep -q 'REDACTED' && ! echo "$out" | grep -q 'AAExampleTokenValue1234567890abcdef'
}

@test "redact_secrets: masks uppercase *_TOKEN/*_KEY assignments generically" {
  out=$(printf 'TELEGRAM_BOT_TOKEN=plainish_value_9x8y\n' | redact_secrets)
  echo "$out" | grep -q 'REDACTED' && ! echo "$out" | grep -q 'plainish_value_9x8y'
}

@test "redact_secrets: leaves non-secret text intact" {
  out=$(printf 'cache_root=/home/agent/.cache/qmd coll=vault TMPDIR=/x/tmp\n' | redact_secrets)
  [ "$out" = 'cache_root=/home/agent/.cache/qmd coll=vault TMPDIR=/x/tmp' ]
}

@test "scratch_dir: creates a host-backed dir under BASE and echoes it" {
  base="$TMP_TEST_DIR/cache"; mkdir -p "$base"
  d=$(scratch_dir "$base")
  [ "$d" = "$base/tmp" ] && [ -d "$d" ]
}

@test "scratch_dir: degrades to TMPDIR when BASE is not writable" {
  d=$(TMPDIR=/tmp scratch_dir "/proc/nonexistent-xyz/cannot")
  [ "$d" = "/tmp" ]
}

@test "scratch_dir: degrades to TMPDIR when BASE is empty" {
  d=$(TMPDIR=/tmp scratch_dir "")
  [ "$d" = "/tmp" ]
}

@test "rag_obs.sh: sourcing has no side effects (BASH_SOURCE-safe)" {
  out=$(bash -c "source '$REPO_ROOT/scripts/lib/rag_obs.sh'; echo SOURCED_OK")
  [ "$out" = "SOURCED_OK" ]
}
