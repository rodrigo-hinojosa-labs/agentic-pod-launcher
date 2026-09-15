#!/usr/bin/env bats
#
# 032/033 DOCKER_E2E — the boot-installed plugin patcher actually lands the
# voice roundtrip v2 hunks in the pinned image's plugin copy, and the compose
# environment: delivers the sanitized TELEGRAM_VOICE_* vars to the container.
# Skipped by default (needs a docker daemon). Enable with DOCKER_E2E=1.
# Contracts: specs/033-voice-reply-feedback/contracts/{reply-voice-outcome,
# explicit-audio-request,voice-group-v2-upgrade}.md
#
# SELF-SEEDING (033 research row 8 / analyze finding F2, HIGH): the image
# ships NO plugin at all — claude-plugins-official/telegram is installed
# post-login by start_services.sh via `claude plugin install`, and
# `docker compose run --entrypoint sh` bypasses that entrypoint entirely. The
# 032-era version of this file located server.ts with `find … -name
# server.ts`, which could never succeed under this harness. Every test here
# instead copies a committed fixture (tests/fixtures/telegram-server-{
# pristine,voice-v1}.ts, bind-mounted at /workspace/.e2e/) into the plugin
# cache path and runs the image-baked patcher on it directly — the object
# under test is the patcher + the image's python3/bun, not the marketplace
# installer (that path is covered by tests/docker-e2e-postlogin.bats).

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

  # Self-seeding fixtures + the seed script every test invokes. The seed
  # script never interpolates a shell variable inside the single-quoted
  # `compose run -c '...'` bodies below — it takes its fixture name as its
  # own $1 (default: the pristine fixture).
  mkdir -p "$E2E_AGENT_DIR/.e2e"
  cp "$REPO_ROOT/tests/fixtures/telegram-server-pristine.ts" "$E2E_AGENT_DIR/.e2e/"
  cp "$REPO_ROOT/tests/fixtures/telegram-server-voice-v1.ts" "$E2E_AGENT_DIR/.e2e/"
  # NOTE: apply_telegram_typing_patch.py's log() writes its "applied ..."
  # summary to STDOUT (not stderr) — redirect the patcher's own stdout to a
  # side file so the caller's `server=$(sh seed.sh)` only ever captures the
  # final path (a caller that also needs the patcher's log reads
  # /tmp/patch.log separately, e.g. E7 below).
  cat > "$E2E_AGENT_DIR/.e2e/seed.sh" <<'SEED'
#!/bin/sh
set -e
fixture="${1:-telegram-server-pristine.ts}"
d="$HOME/.claude/plugins/cache/claude-plugins-official/telegram/0.0.6"
mkdir -p "$d"
cp "/workspace/.e2e/$fixture" "$d/server.ts"
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

# ── E1: the baked plugin patcher yields the v2 marker + the v2-only symbols ─

@test "E2E 033: the patched plugin server.ts carries the v2 voice marker + voice_force + the outcome return" {
  run docker compose run --rm -T --user agent --entrypoint sh voicebot -c '
    set -e
    server=$(sh /workspace/.e2e/seed.sh)
    v2count=$(grep -c "agentic-pod-launcher: telegram voice roundtrip patch v2" "$server" || true)
    v1count=$(grep -c "agentic-pod-launcher: telegram voice roundtrip patch v1" "$server" || true)
    echo "V2COUNT=$v2count"
    echo "V1COUNT=$v1count"
    grep -q "bot.on(.message:voice., async ctx => {" "$server"
    grep -q "void (async () => {" "$server"
    grep -q "voice_text: {" "$server"
    grep -q "voice_force: {" "$server"
    grep -q "attachment_kind=\"voice\"" "$server"
    grep -q "bot.api.sendVoice(chat_id" "$server"
    grep -q "text: result + _voiceOutcome" "$server"
    grep -q "voice helpers end (033)" "$server"
    grep -q "_voiceOriginClear(String(ctx.chat!.id))" "$server"
  '
  echo "$output"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'V2COUNT=1'
  echo "$output" | grep -qx 'V1COUNT=0'
}

# ── E2: compose environment delivers the five sanitized TELEGRAM_VOICE_* vars ─

@test "E2E 033: compose environment delivers the five sanitized TELEGRAM_VOICE_* vars" {
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

# ── E3: no-key fault injection — the module-scope WARN line, text stays intact

@test "E2E 033: without ELEVENLABS_API_KEY, boot logs the one-time WARN and text stays intact" {
  run docker compose run --rm -T --user agent -e ELEVENLABS_API_KEY= --entrypoint sh voicebot -c '
    set -e
    server=$(sh /workspace/.e2e/seed.sh)
    grep -q "voice inactive" "$server"
    # the plugin file itself still parses as plausible JS/TS — no syntax
    # break from the patcher (grep-only proxy here; E6 below does a real
    # bun parse check).
    grep -q "bot.on(.message:text., async ctx => {" "$server"
  '
  echo "$output"
  [ "$status" -eq 0 ]
}

# ── E4: idempotent boot — the v2 marker count stays 1 across a re-run ───────

@test "E2E 033: re-running the patcher inside the same container is a byte-identical no-op (idempotent boot)" {
  run docker compose run --rm -T --user agent --entrypoint sh voicebot -c '
    set -e
    server=$(sh /workspace/.e2e/seed.sh)
    sha1=$(sha256sum "$server" | cut -d" " -f1)
    python3 /opt/agent-admin/scripts/apply_telegram_typing_patch.py "$server"
    sha2=$(sha256sum "$server" | cut -d" " -f1)
    [ "$sha1" = "$sha2" ]
    grep -c "agentic-pod-launcher: telegram voice roundtrip patch v2" "$server"
  '
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | tail -1)" = "1" ]
}

# ── E5: the matcher's real behaviour under bun (host tests only check text) ─

@test "E2E 033: the explicit-request matcher behaves correctly under bun for every contract example" {
  run docker compose run --rm -T --user agent --entrypoint sh voicebot -c '
    set -e
    server=$(sh /workspace/.e2e/seed.sh)
    awk "/telegram voice roundtrip patch v2/{f=1} f{print} /voice helpers end \\(033\\)/{exit}" "$server" > /tmp/helpers.ts
    cat >> /tmp/helpers.ts <<TS
const positives = [
  "RESPONDE CON AUDIO",
  "Respóndeme con audio por favor",
  "hola, ¿me respondes? responde en audio",
  "reply with audio please",
  "Mándame un audio con el resumen",
  "contéstame por audio",
  "send me a voice note with the summary",
]
const negatives = [
  "el audio de ayer se cortó",
  "no respondas con audio",
  "no me mandes audio",
  "no responde con audio",
  "responde con texto",
  "audio",
  "prefiero texto, sin audio",
  "don" + String.fromCharCode(8217) + "t reply with audio",
  "please don" + String.fromCharCode(8217) + "t ever reply with audio",
  "respondecon audio",
]
let fail = 0
for (const s of positives) { if (!_voiceRequestMatch(s)) { console.log("MISSING POSITIVE: " + s); fail++ } }
for (const s of negatives) { if (_voiceRequestMatch(s)) { console.log("FALSE POSITIVE: " + s); fail++ } }
console.log(fail === 0 ? "ALL_OK" : "FAIL_COUNT=" + fail)
TS
    TELEGRAM_VOICE_ENABLED=true ELEVENLABS_API_KEY=x bun /tmp/helpers.ts
  '
  echo "$output"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "ALL_OK"
}

# ── E6: the patched server.ts still parses as valid TypeScript under bun ────

@test "E2E 033: the patched server.ts parses cleanly under bun (no syntax break from the patcher)" {
  run docker compose run --rm -T --user agent --entrypoint sh voicebot -c '
    set -e
    server=$(sh /workspace/.e2e/seed.sh)
    bun -e "
      const t = new Bun.Transpiler({ loader: \"ts\" })
      const src = await Bun.file(process.argv[1]).text()
      t.transformSync(src)
      console.log(\"parse-ok\")
    " "$server"
  '
  echo "$output"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "parse-ok"
}

# ── E7: the in-container upgrade of a real v1-patched (032) source to v2 ────

@test "E2E 033: seeding the golden v1 fixture and running the boot patcher upgrades it to v2 in place" {
  run docker compose run --rm -T --user agent --entrypoint sh voicebot -c '
    set -e
    server=$(sh /workspace/.e2e/seed.sh telegram-server-voice-v1.ts)
    v2count=$(grep -c "agentic-pod-launcher: telegram voice roundtrip patch v2" "$server" || true)
    v1count=$(grep -c "agentic-pod-launcher: telegram voice roundtrip patch v1" "$server" || true)
    echo "V2COUNT=$v2count"
    echo "V1COUNT=$v1count"
    grep -q "voice-upgrade-v1→v2" /tmp/patch.log
  '
  echo "$output"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'V2COUNT=1'
  echo "$output" | grep -qx 'V1COUNT=0'
}

# ── E8: _voiceErrClass maps a grammY error_code / stt-status / AbortError ───

@test "E2E 033: _voiceErrClass classifies a grammY error_code, an stt-status error, and an AbortError" {
  run docker compose run --rm -T --user agent --entrypoint sh voicebot -c '
    set -e
    server=$(sh /workspace/.e2e/seed.sh)
    awk "/telegram voice roundtrip patch v2/{f=1} f{print} /voice helpers end \\(033\\)/{exit}" "$server" > /tmp/helpers.ts
    cat >> /tmp/helpers.ts <<TS
console.log(JSON.stringify([
  _voiceErrClass({ error_code: 400 }),
  _voiceErrClass(new Error("tts-status-404")),
  _voiceErrClass(Object.assign(new Error("x"), { name: "AbortError" })),
]))
TS
    bun /tmp/helpers.ts
  '
  echo "$output"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx '\[{"cls":"transport","status":"400"},{"cls":"transport","status":"404"},{"cls":"timeout","status":""}\]'
}
