#!/usr/bin/env bats
#
# 031 DOCKER_E2E — the boot-installed PreToolUse hook actually lands in the
# pinned image's settings.json, and the image-baked plugin patcher yields the
# v6 typing warning + the askq give-up hunk. Skipped by default (needs a
# docker daemon). Enable with DOCKER_E2E=1.
# Contract: specs/031-channel-askuserquestion-guard/contracts/giveup-and-warning.md D
#
# Deferred: not run in this environment (no docker daemon). Ships ready for the
# Docker-host gate (tasks.md T022). The live-interception ferrari deploy gate
# (recreate donna; a channel turn calling AskUserQuestion redirects to text) is
# the separate SC-001 gate (T023). Model: tests/docker-e2e-warm-cache.bats.

load helper

setup() {
  if [ "${DOCKER_E2E:-0}" != "1" ]; then
    skip "set DOCKER_E2E=1 to run (requires a docker daemon)"
  fi
  command -v docker >/dev/null 2>&1 || skip "docker not on PATH"
  docker info >/dev/null 2>&1 || skip "docker daemon not reachable"
  TMPDIR=/tmp setup_tmp_dir
  mkdir -p "$TMP_TEST_DIR/installer"
  cp -r "$REPO_ROOT/scripts" "$REPO_ROOT/modules" "$REPO_ROOT/docker" "$TMP_TEST_DIR/installer/"
  cp "$REPO_ROOT/setup.sh" "$TMP_TEST_DIR/installer/"
  [ -f "$REPO_ROOT/.gitignore" ] && cp "$REPO_ROOT/.gitignore" "$TMP_TEST_DIR/installer/"
  [ -f "$REPO_ROOT/LICENSE" ] && cp "$REPO_ROOT/LICENSE" "$TMP_TEST_DIR/installer/"

  cd "$TMP_TEST_DIR/installer"
  E2E_AGENT_DIR="$TMP_TEST_DIR/agent"; export E2E_AGENT_DIR
  # telegram is a mandatory default plugin → askuserquestion_guard.enabled=true
  # on any fresh scaffold, no special plugin selection needed.
  wizard_answers name=askqbot display=AskQBot | ./setup.sh --destination "$E2E_AGENT_DIR"
  [ -f "$E2E_AGENT_DIR/docker-compose.yml" ]
  [ -x "$E2E_AGENT_DIR/scripts/hooks/askq-guard.sh" ]
  [ -x "$E2E_AGENT_DIR/scripts/hooks/install-askq-guard-hook.sh" ]
  cat > "$E2E_AGENT_DIR/.env" <<'ENV'
TELEGRAM_BOT_TOKEN=00000:fake
TELEGRAM_CHAT_ID=0
ENV
  chmod 0600 "$E2E_AGENT_DIR/.env"
  cd "$E2E_AGENT_DIR"
  run docker compose build
  [ "$status" -eq 0 ]
}

teardown() {
  if [ -n "${E2E_AGENT_DIR:-}" ] && [ -d "$E2E_AGENT_DIR" ]; then
    (cd "$E2E_AGENT_DIR" && docker compose down -v --remove-orphans 2>/dev/null || true)
  fi
  teardown_tmp_dir
}

# ── E1: boot registers .hooks.PreToolUse with matcher AskUserQuestion ────────

@test "E2E 031: pre_install_askq_hook registers PreToolUse+AskUserQuestion in settings.json at boot" {
  run docker compose run --rm -T --user agent --entrypoint sh askqbot -c '
    set -e
    grep -n "pre_install_askq_hook" /opt/agent-admin/scripts/start_services.sh
    /workspace/scripts/hooks/install-askq-guard-hook.sh \
      "$HOME/.claude/settings.json" "/workspace/scripts/hooks/askq-guard.sh"
    jq -c ".hooks.PreToolUse" "$HOME/.claude/settings.json"
  '
  echo "$output"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "pre_install_askq_hook"
  echo "$output" | grep -q '"matcher":"AskUserQuestion"'
  echo "$output" | grep -q '"command":"/workspace/scripts/hooks/askq-guard.sh"'
}

# ── E1b: the guard fires against a real fixture payload inside the image ────

@test "E2E 031: the baked askq-guard.sh denies+redirects a channel AskUserQuestion call" {
  run docker compose run --rm -T --user agent --entrypoint sh askqbot -c '
    set -e
    mkdir -p "$HOME/.claude/channels/telegram"
    echo "{\"chat_id\":\"1\",\"update_id\":1,\"ts\":1}" > "$HOME/.claude/channels/telegram/pending-reply.json"
    echo "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"AskUserQuestion\",\"prompt_id\":\"e2e1\"}" \
      | /workspace/scripts/hooks/askq-guard.sh
  '
  echo "$output"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"permissionDecision":"deny"'
  echo "$output" | grep -q "plugin:telegram:telegram"
}

# ── E2/E3: the baked plugin patcher yields v6 warning + give-up hunk ─────────

@test "E2E 031: the patched plugin server.ts carries typing v6 + the askq give-up hunk" {
  run docker compose run --rm -T --user agent --entrypoint sh askqbot -c '
    set -e
    server=$(find "$HOME/.claude/plugins/cache/claude-plugins-official/telegram" -name server.ts | head -1)
    test -n "$server"
    grep -q "typing refresh patch v6" "$server"
    grep -q "askq-guard give-up delivery patch v1" "$server"
    grep -q "bloqueada en un menú interactivo" "$server"
  '
  echo "$output"
  [ "$status" -eq 0 ]
}
