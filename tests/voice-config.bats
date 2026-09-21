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

@test "032/034: the seven TELEGRAM_VOICE_* lines render even when voice is disabled (unconditional, MCP_TIMEOUT precedent)" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml
  echo 'n' | ./setup.sh --regenerate
  [ "$(yq -r '.features.voice.enabled' agent.yml)" = "false" ]
  grep -q 'TELEGRAM_VOICE_ENABLED: "false"' docker-compose.yml
  grep -q 'TELEGRAM_VOICE_REPLY_MODE: "auto"' docker-compose.yml
  grep -q 'TELEGRAM_VOICE_ID: ""' docker-compose.yml
  grep -q 'TELEGRAM_VOICE_PROVIDER: "elevenlabs"' docker-compose.yml
  grep -q 'TELEGRAM_VOICE_SIGNOFF: "' docker-compose.yml
  grep -q 'TELEGRAM_VOICE_CURRENCY: "' docker-compose.yml
}

# ── 034: signoff + currency (contracts/voice-style-config-and-render.md) ──
#
# Wizard tests drive the REAL wizard (mirror of tests/scaffold.bats::run_wizard_with_dest:
# cd into the installer copy setup() made, pipe wizard_answers into ./setup.sh
# --destination). They assert agent.yml carries the TEMPLATE with a literal
# {nickname} — the sanitizer's fallback would mask an omitted heredoc field in
# the compose output. --regenerate tests follow tests/deployment-mode.bats.

_regen() { echo 'n' | ./setup.sh --regenerate; }

@test "034 US2(a1): wizard writes the Spanish sign-off template + currency for user.language=es; compose carries the nickname-substituted phrase" {
  cd "$TMP_TEST_DIR"
  wizard_answers name=voice-bot display=VoiceBot lang=es nick=Rodri | ./setup.sh --destination "$TMP_TEST_DIR/ws"
  [ -f "$TMP_TEST_DIR/ws/agent.yml" ]
  [ "$(yq -r '.features.voice.signoff' ws/agent.yml)" = "Eso es toda la información. Cambio y fuera, {nickname}." ]
  [ "$(yq -r '.features.voice.currency' ws/agent.yml)" = "pesos chilenos" ]
  grep -qF 'TELEGRAM_VOICE_SIGNOFF: "Eso es toda la información. Cambio y fuera, Rodri."' ws/docker-compose.yml
  grep -qF 'TELEGRAM_VOICE_CURRENCY: "pesos chilenos"' ws/docker-compose.yml
}

@test "034 US2(a2): wizard writes the Spanish defaults for user.language=mixed (clarify 2026-09-15)" {
  cd "$TMP_TEST_DIR"
  wizard_answers name=voice-bot display=VoiceBot lang=mixed nick=Rodri | ./setup.sh --destination "$TMP_TEST_DIR/ws"
  [ "$(yq -r '.features.voice.signoff' ws/agent.yml)" = "Eso es toda la información. Cambio y fuera, {nickname}." ]
  [ "$(yq -r '.features.voice.currency' ws/agent.yml)" = "pesos chilenos" ]
  grep -qF 'TELEGRAM_VOICE_SIGNOFF: "Eso es toda la información. Cambio y fuera, Rodri."' ws/docker-compose.yml
}

@test "034 US2(a3): wizard writes the English sign-off template + currency for user.language=en" {
  cd "$TMP_TEST_DIR"
  wizard_answers name=voice-bot display=VoiceBot lang=en nick=Alice | ./setup.sh --destination "$TMP_TEST_DIR/ws"
  [ "$(yq -r '.features.voice.signoff' ws/agent.yml)" = "That is all the information. Over and out, {nickname}." ]
  [ "$(yq -r '.features.voice.currency' ws/agent.yml)" = "Chilean pesos" ]
  grep -qF 'TELEGRAM_VOICE_SIGNOFF: "That is all the information. Over and out, Alice."' ws/docker-compose.yml
  grep -qF 'TELEGRAM_VOICE_CURRENCY: "Chilean pesos"' ws/docker-compose.yml
}

@test "034 US2(b1): --regenerate backfills the exact localized signoff/currency on a 032-shaped features.voice block (es), stderr clean" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml es
  yq -i '.features.voice = {"enabled": false, "reply_mode": "auto", "voice_id": "", "provider": "elevenlabs"}' agent.yml
  [ "$(yq -r '.features.voice | has("signoff")' agent.yml)" = "false" ]
  run bash -c "echo n | ./setup.sh --regenerate 2>&1"
  [ "$status" -eq 0 ]
  [ "$(yq -r '.features.voice.signoff' agent.yml)" = "Eso es toda la información. Cambio y fuera, {nickname}." ]
  [ "$(yq -r '.features.voice.currency' agent.yml)" = "pesos chilenos" ]
  [ "$(yq -r '.features.voice.enabled' agent.yml)" = "false" ]
  [ "$(echo "$output" | grep -c 'unbound variable\|command not found' || true)" -eq 0 ]
}

@test "034 US2(b2): --regenerate backfills the English defaults for user.language=en" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml en
  yq -i '.features.voice = {"enabled": false, "reply_mode": "auto", "voice_id": "", "provider": "elevenlabs"}' agent.yml
  run bash -c "echo n | ./setup.sh --regenerate 2>&1"
  [ "$status" -eq 0 ]
  [ "$(yq -r '.features.voice.signoff' agent.yml)" = "That is all the information. Over and out, {nickname}." ]
  [ "$(yq -r '.features.voice.currency' agent.yml)" = "Chilean pesos" ]
  [ "$(echo "$output" | grep -c 'unbound variable\|command not found' || true)" -eq 0 ]
}

@test "034 US2(b3): a pre-032 agent.yml (no features.voice at all) gets all six fields in one --regenerate" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml es
  _regen
  [ "$(yq -r '.features.voice.enabled' agent.yml)" = "false" ]
  [ "$(yq -r '.features.voice.provider' agent.yml)" = "elevenlabs" ]
  [ "$(yq -r '.features.voice.signoff' agent.yml)" = "Eso es toda la información. Cambio y fuera, {nickname}." ]
  [ "$(yq -r '.features.voice.currency' agent.yml)" = "pesos chilenos" ]
}

@test "034 US2(c): an operator's own phrase survives two --regenerate runs; agent.yml and docker-compose.yml are byte-identical between runs" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml es
  _regen
  yq -i '.features.voice.signoff = "Mi frase, {nickname}"' agent.yml
  yq -i '.user.nickname = "Rodri"' agent.yml
  _regen
  cp agent.yml agent.yml.first
  cp docker-compose.yml docker-compose.yml.first
  _regen
  [ "$(yq -r '.features.voice.signoff' agent.yml)" = "Mi frase, {nickname}" ]
  grep -qF 'TELEGRAM_VOICE_SIGNOFF: "Mi frase, Rodri"' docker-compose.yml
  # meta.regenerated_at changes per run — compare agent.yml without the meta block
  diff <(yq 'del(.meta)' agent.yml) <(yq 'del(.meta)' agent.yml.first)
  cmp docker-compose.yml docker-compose.yml.first
}

@test "034 US2(d1): sanitizer — default phrase with nickname Rodri, then an empty nickname drops the comma and the name" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml es
  yq -i '.user.nickname = "Rodri"' agent.yml
  _regen
  grep -qF 'TELEGRAM_VOICE_SIGNOFF: "Eso es toda la información. Cambio y fuera, Rodri."' docker-compose.yml
  yq -i '.user.nickname = ""' agent.yml
  _regen
  grep -qF 'TELEGRAM_VOICE_SIGNOFF: "Eso es toda la información. Cambio y fuera."' docker-compose.yml
}

@test "034 US2(d2): sanitizer — {nickname} substitution, quotes/backslash/dollar/braces deleted, tab/CR flattened" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml es
  yq -i '.user.nickname = "Rodri"' agent.yml
  _regen
  yq -i '.features.voice.signoff = "Listo, {nickname}"' agent.yml
  _regen
  grep -qF 'TELEGRAM_VOICE_SIGNOFF: "Listo, Rodri"' docker-compose.yml
  SIGNOFF_RAW='Con "comillas" y $dolar y {llaves} y \ barra' yq -i '.features.voice.signoff = strenv(SIGNOFF_RAW)' agent.yml
  _regen
  grep -qF 'TELEGRAM_VOICE_SIGNOFF: "Con comillas y dolar y llaves y barra"' docker-compose.yml
  # Feed REAL control bytes through strenv, never yq's own escape handling.
  # Measured 2026-09-19: `yq '.x = "a\tb"'` is version-dependent — v4.52.5
  # turns \t and \r into control bytes, while v4.44.3 (the version CI pins,
  # .github/workflows/test.yml:50) writes them as literal backslash sequences,
  # which the sanitizer then strips as backslashes, yielding "Conttab yrretorno".
  # The same commit was therefore green on this host and red in CI with nothing
  # in the repo declaring why — the 023 class of defect. strenv with real bytes
  # is byte-identical across both versions and cross-readable, so the oracle
  # tests the SANITIZER instead of yq's expression parser.
  local ctrl
  ctrl=$(printf 'Con\ttab y\rretorno')
  SIGNOFF_CTRL="$ctrl" yq -i '.features.voice.signoff = strenv(SIGNOFF_CTRL)' agent.yml
  # Guard: the field really holds one tab and one CR before regenerating. Without
  # this, a future yq that stops writing control bytes would make the assertion
  # below fail for an unrelated reason.
  run bash -c 'yq -r ".features.voice.signoff" agent.yml | LC_ALL=C tr -dc "\t\r" | wc -c | tr -d " "'
  [ "$output" = "2" ]
  run bash -c "echo n | ./setup.sh --regenerate 2>&1"
  [ "$status" -eq 0 ]
  grep -qF 'TELEGRAM_VOICE_SIGNOFF: "Con tab y retorno"' docker-compose.yml
}

@test "034 US2(d3): sanitizer — over-long (121 ASCII bytes), empty and explicit null fall back to the localized default with a WARN naming the field" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml es
  yq -i '.user.nickname = "Rodri"' agent.yml
  _regen
  local long
  long=$(printf 'x%.0s' $(seq 1 121))
  [ "${#long}" -eq 121 ]
  yq -i ".features.voice.signoff = \"$long\"" agent.yml
  run bash -c "echo n | ./setup.sh --regenerate 2>&1"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'WARN: features.voice.signoff'
  grep -qF 'TELEGRAM_VOICE_SIGNOFF: "Eso es toda la información. Cambio y fuera, Rodri."' docker-compose.yml
  # agent.yml keeps the operator's literal (never rewritten by the sanitizer)
  [ "$(yq -r '.features.voice.signoff' agent.yml)" = "$long" ]

  yq -i '.features.voice.signoff = ""' agent.yml
  run bash -c "echo n | ./setup.sh --regenerate 2>&1"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'WARN: features.voice.signoff'
  grep -qF 'TELEGRAM_VOICE_SIGNOFF: "Eso es toda la información. Cambio y fuera, Rodri."' docker-compose.yml

  yq -i '.features.voice.signoff = null' agent.yml
  run bash -c "echo n | ./setup.sh --regenerate 2>&1"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'WARN: features.voice.signoff'
  grep -qF 'TELEGRAM_VOICE_SIGNOFF: "Eso es toda la información. Cambio y fuera, Rodri."' docker-compose.yml
  # never the word "null" in the rendered phrase
  run grep -qF 'TELEGRAM_VOICE_SIGNOFF: "null"' docker-compose.yml
  [ "$status" -ne 0 ]
}

@test "034 US2(d4): sanitizer — currency null falls back with a WARN naming currency; a custom currency word passes through" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml es
  _regen
  yq -i '.features.voice.currency = null' agent.yml
  run bash -c "echo n | ./setup.sh --regenerate 2>&1"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'WARN: features.voice.currency'
  grep -qF 'TELEGRAM_VOICE_CURRENCY: "pesos chilenos"' docker-compose.yml
  yq -i '.features.voice.currency = "pesos"' agent.yml
  run bash -c "echo n | ./setup.sh --regenerate 2>&1"
  [ "$status" -eq 0 ]
  grep -qF 'TELEGRAM_VOICE_CURRENCY: "pesos"' docker-compose.yml
  [ "$(echo "$output" | grep -c 'WARN: features.voice.currency' || true)" -eq 0 ]
}

@test "034 US2(e): documented negative — a multi-line signoff aborts --regenerate (pre-existing render-wide behaviour, not a 034 feature)" {
  # render_load_context aborts on ANY multi-line string field (measured during the
  # 034 review); the second line is multi-word so the abort is deterministic. The
  # sanitizer only ever sees single-line scalars — tab/CR are its whole control-byte
  # surface (d2 above).
  cd "$TMP_TEST_DIR"
  _write_agent_yml es
  _regen
  yq -i '.features.voice.signoff = "Línea uno\nlínea dos"' agent.yml
  run bash -c "echo n | ./setup.sh --regenerate 2>&1"
  [ "$status" -ne 0 ]
}

@test "034 US2(g): .env.example documents the 900 cap and never lists the two agent.yml-sourced style fields" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml
  _regen
  grep -q 'TELEGRAM_VOICE_SPOKEN_CHAR_CAP=900' .env.example
  run grep -q 'TELEGRAM_VOICE_SIGNOFF' .env.example
  [ "$status" -ne 0 ]
  run grep -q 'TELEGRAM_VOICE_CURRENCY' .env.example
  [ "$status" -ne 0 ]
}
