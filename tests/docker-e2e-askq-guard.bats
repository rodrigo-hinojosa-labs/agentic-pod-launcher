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
#
# 039-fix-nightly-e2e-sigpipe: these tests had never run on a machine with Docker
# (the nightly died before the suite, and the first manual run found two harness
# defects, neither a product bug). E1 now creates ~/.claude itself, because
# `--entrypoint sh` skips the boot that normally does and the fail-silent
# installer then writes nothing. E3 now self-seeds the plugin like
# tests/docker-e2e-voice.bats does, because the image ships no plugin at all
# (it is installed post-login). What each test asserts is unchanged.

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

  # E3 self-seeds (039): copy the committed pristine plugin source into the
  # workspace so the container can place it in the plugin cache and run the
  # image-baked patcher on it. The seed script never interpolates a shell
  # variable inside the single-quoted `compose run -c '...'` bodies below.
  # NOTE: the patcher's log() writes to STDOUT, so it goes to a side file and the
  # caller's `server=$(sh seed.sh)` only ever captures the final path.
  mkdir -p "$E2E_AGENT_DIR/.e2e"
  cp "$REPO_ROOT/tests/fixtures/telegram-server-pristine.ts" "$E2E_AGENT_DIR/.e2e/"
  cat > "$E2E_AGENT_DIR/.e2e/seed.sh" <<'SEED'
#!/bin/sh
set -e
d="$HOME/.claude/plugins/cache/claude-plugins-official/telegram/0.0.6"
mkdir -p "$d"
cp /workspace/.e2e/telegram-server-pristine.ts "$d/server.ts"
python3 /opt/agent-admin/scripts/apply_telegram_typing_patch.py "$d/server.ts" > /tmp/patch.log 2>&1
echo "$d/server.ts"
SEED

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
    # the real boot creates ~/.claude before pre_install_askq_hook runs; with
    # --entrypoint sh the boot is skipped, and the fail-silent installer would
    # write nothing (039)
    mkdir -p "$HOME/.claude"
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
    server=$(sh /workspace/.e2e/seed.sh)
    test -n "$server"
    grep -q "typing refresh patch v6" "$server"
    grep -q "askq-guard give-up delivery patch v1" "$server"
    grep -q "bloqueada en un menú interactivo" "$server"
  '
  echo "$output"
  [ "$status" -eq 0 ]
}
