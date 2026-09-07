#!/usr/bin/env bats
#
# 032 — features.voice declarative surface (agent.yml as single source of
# truth). Unlike 028/031 there is NO plugin-derived enabled=true backfill
# path: voice is explicit opt-in (spends money, needs a new secret), so the
# backfilled value is always disabled. Mirrors tests/askq-guard-config.bats.

load helper

setup() {
  setup_tmp_dir
  cp -r "$REPO_ROOT/scripts" "$REPO_ROOT/modules" "$TMP_TEST_DIR/"
  cp "$REPO_ROOT/setup.sh" "$TMP_TEST_DIR/"
  touch "$TMP_TEST_DIR/.env"
  CLAUDE_STUB=$(install_claude_stub)
}

teardown() { teardown_tmp_dir; }

# Emit a minimal, schema-valid docker-mode agent.yml with no features.voice
# block. $1 = user.language (default en).
_write_agent_yml() {
  local lang="${1:-en}"
  cat > "$TMP_TEST_DIR/agent.yml" << EOF
version: 1
agent:
  name: voice-bot
  display_name: "VoiceBot"
  role: "r"
  vibe: "v"
  use_default_principles: true
user:
  name: "A"
  nickname: "A"
  timezone: "UTC"
  email: "a@b.com"
  language: "${lang}"
deployment:
  host: "h"
  workspace: "/tmp/voice-bot"
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
plugins:
  - telegram@claude-plugins-official
EOF
}

@test "032: --regenerate backfills the disabled features.voice block on a pre-032 agent.yml" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml
  [ "$(yq -r '.features | has("voice")' agent.yml)" = "false" ]
  echo 'n' | ./setup.sh --regenerate
  [ "$(yq -r '.features.voice.enabled' agent.yml)" = "false" ]
  [ "$(yq -r '.features.voice.reply_mode' agent.yml)" = "auto" ]
  [ "$(yq -r '.features.voice.voice_id' agent.yml)" = "" ]
  [ "$(yq -r '.features.voice.provider' agent.yml)" = "elevenlabs" ]
}

@test "032: an operator's explicit enabled:true + custom reply_mode survive --regenerate untouched" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml
  echo 'n' | ./setup.sh --regenerate
  yq -i '.features.voice.enabled = true' agent.yml
  yq -i '.features.voice.reply_mode = "always"' agent.yml
  yq -i '.features.voice.voice_id = "custom-voice-id"' agent.yml
  echo 'n' | ./setup.sh --regenerate
  [ "$(yq -r '.features.voice.enabled' agent.yml)" = "true" ]
  [ "$(yq -r '.features.voice.reply_mode' agent.yml)" = "always" ]
  [ "$(yq -r '.features.voice.voice_id' agent.yml)" = "custom-voice-id" ]
}

@test "032: an operator's explicit enabled:false survives --regenerate untouched (not re-derived)" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml
  echo 'n' | ./setup.sh --regenerate
  yq -i '.features.voice.enabled = false' agent.yml
  yq -i '.features.voice.reply_mode = "never"' agent.yml
  echo 'n' | ./setup.sh --regenerate
  [ "$(yq -r '.features.voice.enabled' agent.yml)" = "false" ]
  [ "$(yq -r '.features.voice.reply_mode' agent.yml)" = "never" ]
}

@test "032: an invalid reply_mode sanitizes to auto in the rendered compose environment" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml
  echo 'n' | ./setup.sh --regenerate
  yq -i '.features.voice.reply_mode = "bogus"' agent.yml
  echo 'n' | ./setup.sh --regenerate
  # agent.yml itself keeps the operator's literal (hand-edit is not silently fixed)
  [ "$(yq -r '.features.voice.reply_mode' agent.yml)" = "bogus" ]
  # but the RENDERED environment never carries invalid config to the plugin
  grep -q 'TELEGRAM_VOICE_REPLY_MODE: "auto"' docker-compose.yml
}

@test "032: user.language=mixed renders TELEGRAM_VOICE_STT_LANG empty while CLAUDE.md still says mixed (analyze F1)" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml mixed
  echo 'n' | ./setup.sh --regenerate
  grep -q 'TELEGRAM_VOICE_STT_LANG: ""' docker-compose.yml
  # USER_LANGUAGE itself is never re-sanitized — claude-md.tpl must keep
  # rendering the operator's literal choice for a mixed agent.
  grep -qi "mixed" CLAUDE.md
}

@test "032: user.language=es passes through to TELEGRAM_VOICE_STT_LANG unchanged" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml es
  echo 'n' | ./setup.sh --regenerate
  grep -q 'TELEGRAM_VOICE_STT_LANG: "es"' docker-compose.yml
}

@test "032: .env.example documents ELEVENLABS_API_KEY + the two tuning knobs (name-only)" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml
  echo 'n' | ./setup.sh --regenerate
  grep -q '^ELEVENLABS_API_KEY=$' .env.example
  grep -q 'TELEGRAM_VOICE_MAX_NOTE_SECONDS' .env.example
  grep -q 'TELEGRAM_VOICE_SPOKEN_CHAR_CAP' .env.example
  # never a real value — just the documented name/comment
  ! grep -qE '^TELEGRAM_VOICE_MAX_NOTE_SECONDS=[0-9]' .env.example
}

@test "032: two consecutive --regenerate runs produce a byte-identical docker-compose.yml (SC-005)" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml
  echo 'n' | ./setup.sh --regenerate
  cp docker-compose.yml docker-compose.yml.first
  echo 'n' | ./setup.sh --regenerate
  diff docker-compose.yml docker-compose.yml.first
}

@test "032: the five TELEGRAM_VOICE_* lines render even when voice is disabled (unconditional, MCP_TIMEOUT precedent)" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml
  echo 'n' | ./setup.sh --regenerate
  [ "$(yq -r '.features.voice.enabled' agent.yml)" = "false" ]
  grep -q 'TELEGRAM_VOICE_ENABLED: "false"' docker-compose.yml
  grep -q 'TELEGRAM_VOICE_REPLY_MODE: "auto"' docker-compose.yml
  grep -q 'TELEGRAM_VOICE_ID: ""' docker-compose.yml
  grep -q 'TELEGRAM_VOICE_PROVIDER: "elevenlabs"' docker-compose.yml
}
