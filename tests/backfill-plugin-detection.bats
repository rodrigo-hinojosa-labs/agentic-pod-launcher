#!/usr/bin/env bats
#
# The plugin-presence derivation shared by the reply_guard (028) and
# askuserquestion_guard (031) backfills must not depend on winning a race.
#
# MEASURED DEFECT (this host, 2026-09-21). Both backfills asked the question as
#
#     if yq -r '.plugins[]?' "$agent_yml" 2>/dev/null | grep -qE '^telegram@'; then
#
# and setup.sh:4 declares `set -euo pipefail`. `grep -q` exits the instant it
# matches line 1; yq still has line 2 to write, takes EPIPE and dies with 141.
# pipefail then hands that 141 to the `if`, which takes the else branch — so a
# successful match is silently reported as "no telegram plugin". Over 300 runs of
# the real pipeline with the real two-entry plugins list:
#
#     bash 5.3.15 -> PIPESTATUS "141 0" in 18/300 (6.0%)
#     bash 3.2.57 -> PIPESTATUS "141 0" in 22/300 (7.3%)
#
# The grep stage was 0 — it matched — every single time.
#
# The consequence is not a flaky test, it is a permanent wrong value: both
# backfills are has()-guarded, so they write once and are never revisited. A
# `false` born of this race disables the guard that 028/031 exist to install, and
# no later --regenerate repairs it.
#
# HOW THESE TESTS MAKE IT DETERMINISTIC: the yq stub below replays the plugins
# query one line at a time with a gap. That is the shape the real yq already has
# (it is line-buffered); the sleep only removes the timing luck, so the ~7%
# becomes 100%. Any implementation that reads the producer to completion passes;
# any implementation whose consumer can close the pipe early fails.

load helper

setup() {
  setup_tmp_dir
  cp -r "$REPO_ROOT/scripts" "$REPO_ROOT/modules" "$TMP_TEST_DIR/"
  cp "$REPO_ROOT/setup.sh" "$TMP_TEST_DIR/"
  touch "$TMP_TEST_DIR/.env"
  CLAUDE_STUB=$(install_claude_stub)
}

teardown() { teardown_tmp_dir; }

# A yq that delegates to the real one for everything EXCEPT the plugins query the
# backfills use. For that query it emits the real output line by line, pausing in
# between, so a consumer that closes the pipe after the first line reliably
# SIGPIPEs the writer.
_install_slow_plugins_yq() {
  local real bin
  real=$(command -v yq)
  bin="$TMP_TEST_DIR/stub-bin"
  mkdir -p "$bin"
  cat > "$bin/yq" <<EOF
#!/bin/sh
for _a in "\$@"; do
  if [ "\$_a" = '.plugins[]?' ]; then
    "$real" "\$@" > "$TMP_TEST_DIR/.plugins.out" 2>/dev/null || exit \$?
    while IFS= read -r _l; do
      printf '%s\n' "\$_l"
      sleep 0.2
    done < "$TMP_TEST_DIR/.plugins.out"
    exit 0
  fi
done
exec "$real" "\$@"
EOF
  chmod +x "$bin/yq"
  export PATH="$bin:$PATH"
}

# Minimal schema-valid agent.yml (docker mode) carrying neither guard block, so
# both backfills run. $1 = plugins YAML lines.
_write_agent_yml() {
  cat > "$TMP_TEST_DIR/agent.yml" << EOF
version: 1
agent:
  name: bp-bot
  display_name: "BP"
  role: "r"
  vibe: "v"
  use_default_principles: true
user:
  name: "A"
  nickname: "A"
  timezone: "UTC"
  email: "a@b.com"
  language: "en"
deployment:
  host: "h"
  workspace: "$TMP_TEST_DIR"
  install_service: false
docker:
  image_tag: "agent-admin:latest"
  uid: 1000
  gid: 1000
  base_image: "alpine:3.20"
notifications:
  channel: telegram
features:
  heartbeat:
    enabled: true
    interval: "30m"
    timeout: 300
    retries: 1
    default_prompt: "ok"
mcps:
  atlassian: []
  github:
    enabled: false
$1
EOF
}

# ── The derivation survives a producer that writes incrementally ──────────────

@test "backfill: a slow-writing yq still yields askuserquestion_guard.enabled=true (SIGPIPE race)" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml "plugins:
  - telegram@claude-plugins-official
  - claude-mem@thedotmack"
  _install_slow_plugins_yq
  echo 'n' | ./setup.sh --regenerate
  [ "$(command yq -r '.features.askuserquestion_guard.enabled' agent.yml)" = "true" ]
}

@test "backfill: a slow-writing yq still yields reply_guard.enabled=true (SIGPIPE race)" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml "plugins:
  - telegram@claude-plugins-official
  - claude-mem@thedotmack"
  _install_slow_plugins_yq
  echo 'n' | ./setup.sh --regenerate
  [ "$(command yq -r '.features.reply_guard.enabled' agent.yml)" = "true" ]
}

# ── The fix must not invert the sense: absence still derives false ────────────

@test "backfill: no telegram plugin still derives enabled=false under the slow producer" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml "plugins:
  - claude-mem@thedotmack
  - other@marketplace"
  _install_slow_plugins_yq
  echo 'n' | ./setup.sh --regenerate
  [ "$(command yq -r '.features.askuserquestion_guard.enabled' agent.yml)" = "false" ]
  [ "$(command yq -r '.features.reply_guard.enabled' agent.yml)" = "false" ]
}

@test "backfill: a plugin merely ending in telegram@ does not count as the channel" {
  cd "$TMP_TEST_DIR"
  # `^telegram@` anchored at the start of a line: `nottelegram@x` must NOT match.
  _write_agent_yml "plugins:
  - nottelegram@claude-plugins-official
  - claude-mem@thedotmack"
  _install_slow_plugins_yq
  echo 'n' | ./setup.sh --regenerate
  [ "$(command yq -r '.features.askuserquestion_guard.enabled' agent.yml)" = "false" ]
  [ "$(command yq -r '.features.reply_guard.enabled' agent.yml)" = "false" ]
}

# ── Anti-drift: the vulnerable shape must not come back ───────────────────────

@test "backfill: setup.sh pipes no yq output into an early-exiting consumer" {
  # Counted, not `grep -q`-negated: an intermediate negated pipeline does not fail
  # a bats test, it just evaluates (documented repo gotcha). The pattern catches
  # `yq … | grep -q…`, which is the exact shape that took the 141.
  #
  # Comment lines are stripped first, on purpose: agent_yml_has_plugin's own
  # docstring quotes the forbidden shape verbatim so the next reader knows exactly
  # what not to write. Deleting that explanation to satisfy a grep would trade the
  # documentation for the test — so the test learns to read code only.
  run bash -c "sed 's/[[:space:]]*#.*//' '$REPO_ROOT/setup.sh' | grep -cE 'yq[^|]*\| *grep -[a-zA-Z]*q' || true"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}
