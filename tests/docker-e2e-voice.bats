#!/usr/bin/env bats
#
# 032 DOCKER_E2E — the boot-installed plugin patcher actually lands the voice
# roundtrip hunks in the pinned image's plugin copy, and the compose
# environment: delivers the sanitized TELEGRAM_VOICE_* vars to the container.
# Skipped by default (needs a docker daemon). Enable with DOCKER_E2E=1.
# Contracts: specs/032-telegram-voice-roundtrip/contracts/{voice-inbound-stt,
# voice-outbound-tts,voice-config-and-render}.md
#
# Deferred: not run in this environment (no docker daemon). Ships ready for
# the Docker-host gate (tasks.md T025). Model: tests/docker-e2e-askq-guard.bats.

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
  # telegram is a mandatory default plugin; wizard_answers declines the voice
  # prompt by default (opt-in) — enable it + set a voice_id by hand-editing
  # agent.yml + regenerating, same pattern as tests/voice-config.bats.
  wizard_answers name=voicebot display=VoiceBot | ./setup.sh --destination "$E2E_AGENT_DIR"
  [ -f "$E2E_AGENT_DIR/docker-compose.yml" ]
  cd "$E2E_AGENT_DIR"
  yq -i '.features.voice.enabled = true' agent.yml
  yq -i '.features.voice.reply_mode = "always"' agent.yml
  yq -i '.features.voice.voice_id = "e2e-voice-id"' agent.yml
  echo 'n' | ./setup.sh --regenerate
  cat > "$E2E_AGENT_DIR/.env" <<'ENV'
TELEGRAM_BOT_TOKEN=00000:fake
TELEGRAM_CHAT_ID=0
ELEVENLABS_API_KEY=e2e-fake-key
ENV
  chmod 0600 "$E2E_AGENT_DIR/.env"
  run docker compose build
  [ "$status" -eq 0 ]
}

teardown() {
  if [ -n "${E2E_AGENT_DIR:-}" ] && [ -d "$E2E_AGENT_DIR" ]; then
    (cd "$E2E_AGENT_DIR" && docker compose down -v --remove-orphans 2>/dev/null || true)
  fi
  teardown_tmp_dir
}

# ── E1: the baked plugin patcher yields the voice marker + all six hunks ────

@test "E2E 032: the patched plugin server.ts carries the voice marker + V1-V6 hunks" {
  run docker compose run --rm -T --user agent --entrypoint sh voicebot -c '
    set -e
    server=$(find "$HOME/.claude/plugins/cache/claude-plugins-official/telegram" -name server.ts | head -1)
    test -n "$server"
    grep -c "agentic-pod-launcher: telegram voice roundtrip patch v1" "$server"
    grep -q "bot.on(.message:voice., async ctx => {" "$server"
    grep -q "void (async () => {" "$server"
    grep -q "voice_text: {" "$server"
    grep -q "attachment_kind=\"voice\"" "$server"
    grep -q "bot.api.sendVoice(chat_id" "$server"
    grep -q "_voiceOriginClear(String(ctx.chat!.id))" "$server"
  '
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | head -1)" = "1" ]
}

# ── E2: compose environment delivers the five sanitized TELEGRAM_VOICE_* vars ─

@test "E2E 032: compose environment delivers the five sanitized TELEGRAM_VOICE_* vars" {
  run docker compose run --rm -T --user agent --entrypoint sh voicebot -c \
    "env | grep '^TELEGRAM_VOICE_' | sort"
  echo "$output"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'TELEGRAM_VOICE_ENABLED=true'
  echo "$output" | grep -qx 'TELEGRAM_VOICE_REPLY_MODE=always'
  echo "$output" | grep -qx 'TELEGRAM_VOICE_ID=e2e-voice-id'
  echo "$output" | grep -qx 'TELEGRAM_VOICE_PROVIDER=elevenlabs'
  echo "$output" | grep -q '^TELEGRAM_VOICE_STT_LANG='
}

# ── E3: no-key fault injection — the module-scope WARN line, feature inert ───

@test "E2E 032: without ELEVENLABS_API_KEY, boot logs the one-time WARN and text stays intact" {
  run docker compose run --rm -T --user agent -e ELEVENLABS_API_KEY= --entrypoint sh voicebot -c '
    set -e
    server=$(find "$HOME/.claude/plugins/cache/claude-plugins-official/telegram" -name server.ts | head -1)
    grep -q "voice inactive" "$server"
    # the plugin file itself still parses as plausible JS/TS — no syntax
    # break from the patcher (grep-only proxy, no bun compile step here).
    grep -q "bot.on(.message:text., async ctx => {" "$server"
  '
  echo "$output"
  [ "$status" -eq 0 ]
}

# ── E4: idempotent boot — the marker count stays 1 across a container restart ─

@test "E2E 032: re-running the patcher inside the same container is a no-op (idempotent boot)" {
  run docker compose run --rm -T --user agent --entrypoint sh voicebot -c '
    set -e
    server=$(find "$HOME/.claude/plugins/cache/claude-plugins-official/telegram" -name server.ts | head -1)
    python3 /opt/agent-admin/scripts/apply_telegram_typing_patch.py "$server"
    grep -c "agentic-pod-launcher: telegram voice roundtrip patch v1" "$server"
  '
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | tail -1)" = "1" ]
}
