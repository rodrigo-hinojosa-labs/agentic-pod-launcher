#!/usr/bin/env bats
#
# 032/033/034 DOCKER_E2E — the boot-installed plugin patcher actually lands the
# voice roundtrip v3 hunks in the pinned image's plugin copy, and the compose
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
# pristine,voice-v1,voice-v2}.ts, bind-mounted at /workspace/.e2e/) into the plugin
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
  cp "$REPO_ROOT/tests/fixtures/telegram-server-voice-v2.ts" "$E2E_AGENT_DIR/.e2e/"
  # 034: the committed normalization table (39 entries, plain TS data) E9 runs under bun.
  cp "$REPO_ROOT/tests/fixtures/voice-spoken-cases.ts" "$E2E_AGENT_DIR/.e2e/"
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

# ── E1: the baked plugin patcher yields the v3 marker + the v2/v3 symbols ───

@test "E2E 034: the patched plugin server.ts carries the v3 voice marker (no v2, no v1) + voice_force + the outcome return" {
  run docker compose run --rm -T --user agent --entrypoint sh voicebot -c '
    set -e
    server=$(sh /workspace/.e2e/seed.sh)
    v3count=$(grep -c "agentic-pod-launcher: telegram voice roundtrip patch v3" "$server" || true)
    v2count=$(grep -c "agentic-pod-launcher: telegram voice roundtrip patch v2" "$server" || true)
    v1count=$(grep -c "agentic-pod-launcher: telegram voice roundtrip patch v1" "$server" || true)
    echo "V3COUNT=$v3count"
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
  echo "$output" | grep -qx 'V3COUNT=1'
  echo "$output" | grep -qx 'V2COUNT=0'
  echo "$output" | grep -qx 'V1COUNT=0'
}

# ── E2: compose environment delivers the seven sanitized TELEGRAM_VOICE_* vars ─
# The harness agent is user.language=en / user.nickname=Alice by construction
# (wizard_answers defaults), so the 034 lines carry the English defaults.

@test "E2E 034: compose environment delivers the seven sanitized TELEGRAM_VOICE_* vars" {
  run docker compose run --rm -T --user agent --entrypoint sh voicebot -c \
    "env | grep '^TELEGRAM_VOICE_' | sort"
  echo "$output"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'TELEGRAM_VOICE_ENABLED=true'
  echo "$output" | grep -qx 'TELEGRAM_VOICE_REPLY_MODE=always'
  echo "$output" | grep -qx 'TELEGRAM_VOICE_ID=e2e-voice-id'
  echo "$output" | grep -qx 'TELEGRAM_VOICE_PROVIDER=elevenlabs'
  echo "$output" | grep -q '^TELEGRAM_VOICE_STT_LANG='
  echo "$output" | grep -qx 'TELEGRAM_VOICE_SIGNOFF=That is all the information. Over and out, Alice.'
  echo "$output" | grep -qx 'TELEGRAM_VOICE_CURRENCY=Chilean pesos'
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

# ── E4: idempotent boot — the v3 marker count stays 1 across a re-run ───────

@test "E2E 033: re-running the patcher inside the same container is a byte-identical no-op (idempotent boot)" {
  run docker compose run --rm -T --user agent --entrypoint sh voicebot -c '
    set -e
    server=$(sh /workspace/.e2e/seed.sh)
    sha1=$(sha256sum "$server" | cut -d" " -f1)
    python3 /opt/agent-admin/scripts/apply_telegram_typing_patch.py "$server"
    sha2=$(sha256sum "$server" | cut -d" " -f1)
    [ "$sha1" = "$sha2" ]
    echo "V3COUNT=$(grep -c "agentic-pod-launcher: telegram voice roundtrip patch v3" "$server" || true)"
  '
  echo "$output"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "V3COUNT=1"
}

# ── E5: the matcher's real behaviour under bun (host tests only check text) ─

@test "E2E 033: the explicit-request matcher behaves correctly under bun for every contract example" {
  run docker compose run --rm -T --user agent --entrypoint sh voicebot -c '
    set -e
    server=$(sh /workspace/.e2e/seed.sh)
    awk "/telegram voice roundtrip patch v3/{f=1} f{print} /voice helpers end \\(033\\)/{exit}" "$server" > /tmp/helpers.ts
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

# ── E7: the in-container upgrade of a real v1-patched (032) source to v3 ────

@test "E2E 034: seeding the golden v1 fixture and running the boot patcher upgrades it to v3 in place (v1→v2→v3 cascade)" {
  run docker compose run --rm -T --user agent --entrypoint sh voicebot -c '
    set -e
    server=$(sh /workspace/.e2e/seed.sh telegram-server-voice-v1.ts)
    echo "V3COUNT=$(grep -c "agentic-pod-launcher: telegram voice roundtrip patch v3" "$server" || true)"
    echo "V2COUNT=$(grep -c "agentic-pod-launcher: telegram voice roundtrip patch v2" "$server" || true)"
    echo "V1COUNT=$(grep -c "agentic-pod-launcher: telegram voice roundtrip patch v1" "$server" || true)"
    grep -q "voice-upgrade-v1→v2" /tmp/patch.log
    grep -q "voice-upgrade-v2→v3" /tmp/patch.log
  '
  echo "$output"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'V3COUNT=1'
  echo "$output" | grep -qx 'V2COUNT=0'
  echo "$output" | grep -qx 'V1COUNT=0'
}

# ── E8: _voiceErrClass maps a grammY error_code / stt-status / AbortError ───

@test "E2E 033: _voiceErrClass classifies a grammY error_code, an stt-status error, and an AbortError" {
  run docker compose run --rm -T --user agent --entrypoint sh voicebot -c '
    set -e
    server=$(sh /workspace/.e2e/seed.sh)
    awk "/telegram voice roundtrip patch v3/{f=1} f{print} /voice helpers end \\(033\\)/{exit}" "$server" > /tmp/helpers.ts
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

# ── E9 (034): the spoken-safe normalizer's real behaviour under bun ─────────
#
# Harness rules (pipeline contract C8, analyze U4): the test body is ONE
# single-quoted `-c '…'` string, so every inner value uses DOUBLE quotes; the
# runner TS goes through a QUOTED heredoc (the fixture carries `$1500` and
# backticks). The harness agent is `en`/`Alice` by construction, so each bun
# invocation pins its full TELEGRAM_VOICE_* environment on the command line —
# an EMPTY TELEGRAM_VOICE_STT_LANG selects the Spanish table (38 entries) and
# `en` the single English case.

@test "E2E 034: _voiceSpokenNormalize matches the committed cases fixture under bun (Spanish table + English case)" {
  run docker compose run --rm -T --user agent --entrypoint sh voicebot -c '
    set -e
    server=$(sh /workspace/.e2e/seed.sh)
    awk "/telegram voice roundtrip patch v3/{f=1} f{print} /voice helpers end \\(033\\)/{exit}" "$server" > /tmp/helpers.ts
    cat /workspace/.e2e/voice-spoken-cases.ts >> /tmp/helpers.ts
    cat >> /tmp/helpers.ts <<"TS"
const _e9lang = process.env.TELEGRAM_VOICE_STT_LANG || undefined
let e9fail = 0
let e9run = 0
for (const c of VOICE_SPOKEN_CASES) {
  if ((c.lang ?? undefined) !== _e9lang) continue
  e9run++
  const got = _voiceSpokenNormalize(c.in)
  if (got !== c.want) {
    e9fail++
    console.log("FAIL | " + JSON.stringify(c.in) + " got=" + JSON.stringify(got) + " want=" + JSON.stringify(c.want))
  }
}
console.log("CASES_RUN=" + e9run)
console.log(e9fail === 0 ? "ALL_OK" : "FAIL_COUNT=" + e9fail)
TS
    echo "RUN_ES"
    TELEGRAM_VOICE_STT_LANG= TELEGRAM_VOICE_CURRENCY= TELEGRAM_VOICE_SIGNOFF="Eso es toda la información. Cambio y fuera, Rodri." TELEGRAM_VOICE_SPOKEN_CHAR_CAP=900 TELEGRAM_VOICE_ENABLED=true ELEVENLABS_API_KEY=x bun /tmp/helpers.ts
    echo "RUN_EN"
    TELEGRAM_VOICE_STT_LANG=en TELEGRAM_VOICE_CURRENCY= TELEGRAM_VOICE_SIGNOFF="That is all the information. Over and out, Alice." TELEGRAM_VOICE_SPOKEN_CHAR_CAP=900 TELEGRAM_VOICE_ENABLED=true ELEVENLABS_API_KEY=x bun /tmp/helpers.ts
  '
  echo "$output"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "CASES_RUN=38"
  echo "$output" | grep -qx "CASES_RUN=1"
  [ "$(echo "$output" | grep -cx "ALL_OK")" -eq 2 ]
  [ "$(echo "$output" | grep -c "^FAIL" || true)" -eq 0 ]
}

# ── E11 (034): the synth body carries the language_code spread (C5) ─────────
# Textual by design — there is no network in e2e; SC-005's "present when es|en,
# absent with mixed" is the runtime spread this line encodes, asserted on the
# seeded, patched server.ts.

@test "E2E 034: the seeded server.ts synth body carries the language_code spread (C5)" {
  run docker compose run --rm -T --user agent --entrypoint sh voicebot -c '
    set -e
    server=$(sh /workspace/.e2e/seed.sh)
    echo "BCOUNT=$(grep -cF "body: JSON.stringify({ text, model_id: VOICE_TTS_MODEL, ...(VOICE_STT_LANG ? { language_code: VOICE_STT_LANG } : {}) })," "$server" || true)"
    echo "LCOUNT=$(grep -c language_code "$server" || true)"
  '
  echo "$output"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "BCOUNT=1"
  echo "$output" | grep -qx "LCOUNT=2"
}

# ── E10 (034): _voiceSpokenAssemble executed for real — budget, once-only, sentence-boundary, trim ─
# Cases (a)-(q) of pipeline contract C8. The TS is appended through a QUOTED
# heredoc and uses double quotes only (the test body is a single-quoted -c
# string). Two invocations: the default cap (900, where (i) applies) and a
# 300 cap ((p): the same (j)-(n)/(q) invariants at a different budget).

@test "E2E 034: _voiceSpokenAssemble holds the budget, once-only, sentence-boundary and trim invariants under bun" {
  run docker compose run --rm -T --user agent --entrypoint sh voicebot -c '
    set -e
    server=$(sh /workspace/.e2e/seed.sh)
    awk "/telegram voice roundtrip patch v3/{f=1} f{print} /voice helpers end \\(033\\)/{exit}" "$server" > /tmp/helpers.ts
    cat >> /tmp/helpers.ts <<"TS"
const SO = VOICE_SIGNOFF
const EMPTY = VOICE_EMPTY_SENTENCE
const CAP = VOICE_SPOKEN_CHAR_CAP
const BUDGET = Math.max(CAP - (SO.length + 2), Math.floor(CAP / 2))
let e10fail = 0
const check = (name: string, cond: boolean, extra?: string) => { if (!cond) { e10fail++; console.log("FAIL " + name + " " + (extra ?? "")) } }
const countKey = (s: string) => { const k = _voiceKey(SO); const t = _voiceKey(s); let n = 0; let i = t.indexOf(k); while (i >= 0) { n++; i = t.indexOf(k, i + 1) } return n }
let r = _voiceSpokenAssemble("Todo listo con el reporte.")
check("a", r.spoken === "Todo listo con el reporte. " + SO && countKey(r.spoken) === 1, r.spoken)
r = _voiceSpokenAssemble("Todo listo con el reporte. " + SO)
check("b", r.spoken === "Todo listo con el reporte. " + SO && countKey(r.spoken) === 1, r.spoken)
r = _voiceSpokenAssemble("Todo listo con el reporte. " + SO.toUpperCase())
check("c", r.spoken === "Todo listo con el reporte. " + SO && countKey(r.spoken) === 1, r.spoken)
r = _voiceSpokenAssemble("Todo listo con el reporte")
check("d", r.spoken === "Todo listo con el reporte. " + SO, r.spoken)
r = _voiceSpokenAssemble("Todo listo. eso es toda la informacion. cambio y fuera, rodri")
check("e", r.spoken === "Todo listo. " + SO && countKey(r.spoken) === 1, r.spoken)
r = _voiceSpokenAssemble("Todo listo. Cambio y fuera, Rodri.")
check("f", r.spoken === "Todo listo. Cambio y fuera, Rodri. " + SO && countKey(r.spoken) === 1, r.spoken)
r = _voiceSpokenAssemble("```\nonly code\n```")
check("g", r.spoken === EMPTY + " " + SO && r.narrated === EMPTY, r.spoken)
r = _voiceSpokenAssemble(SO)
check("h", r.spoken === EMPTY + " " + SO, r.spoken)
if (CAP === 900) {
  const body = Array.from({ length: 28 }, () => "Frase de relleno número uno.").join(" ")
  r = _voiceSpokenAssemble(body + " " + SO)
  check("i", body.length === 811 && countKey(r.spoken) === 1 && r.trimmed === false && r.spoken === body + " " + SO, "bodyLen=" + body.length + " trimmed=" + r.trimmed)
}
r = _voiceSpokenAssemble("x".repeat(BUDGET - 1) + ";")
check("j", r.spoken.length <= CAP && !/[;:]\. /.test(r.spoken) && r.trimmed === false, "len=" + r.spoken.length)
r = _voiceSpokenAssemble("y".repeat(BUDGET - 1) + ":")
check("k", r.spoken.length <= CAP && r.trimmed === false, "len=" + r.spoken.length)
r = _voiceSpokenAssemble("z".repeat(2000))
check("l", r.spoken.length <= CAP && r.trimmed === true && r.spoken.endsWith(SO), "len=" + r.spoken.length)
const lh = Array.from({ length: 60 }, (_, i) => "- Punto " + (i + 1) + " con detalle.").join("\n")
r = _voiceSpokenAssemble(lh)
check("m", lh.length >= 1400 && r.spoken.length <= CAP && r.trimmed === true && r.spoken.endsWith(SO) && /[.!?;]$/.test(r.narrated) && !r.narrated.includes("- Punto"), "len=" + r.spoken.length + " narratedEnd=" + JSON.stringify(r.narrated.slice(-12)))
const os = Array.from({ length: 250 }, () => "palabra").join(" ") + "."
r = _voiceSpokenAssemble(os)
check("n", os.length >= 1500 && r.spoken.length <= CAP && r.trimmed === true && !r.narrated.endsWith(" ") && r.narrated.endsWith("palabra"), "len=" + r.spoken.length)
check("o", _voiceSignoffAppend("Hola", "") === "Hola")
const sents = Array.from({ length: 40 }, (_, i) => "Oración número " + (i + 1) + " con contenido de prueba.")
const prose = sents.join(" ")
r = _voiceSpokenAssemble(prose)
let acc = ""
let k = 0
while (k < sents.length && (acc + (acc ? " " : "") + sents[k]).length <= BUDGET) { acc = acc + (acc ? " " : "") + sents[k]; k++ }
check("q", prose.length > CAP && r.trimmed === true && r.narrated === acc && /[.!?;]$/.test(r.narrated), "narrated=" + r.narrated.length + " expected=" + acc.length + " prose=" + prose.length)
console.log(e10fail === 0 ? "E10_OK cap=" + CAP + " budget=" + BUDGET + " qlen=" + acc.length : "E10_FAIL count=" + e10fail)
TS
    TELEGRAM_VOICE_STT_LANG= TELEGRAM_VOICE_CURRENCY= TELEGRAM_VOICE_SIGNOFF="Eso es toda la información. Cambio y fuera, Rodri." TELEGRAM_VOICE_SPOKEN_CHAR_CAP=900 TELEGRAM_VOICE_ENABLED=true ELEVENLABS_API_KEY=x bun /tmp/helpers.ts
    TELEGRAM_VOICE_STT_LANG= TELEGRAM_VOICE_CURRENCY= TELEGRAM_VOICE_SIGNOFF="Eso es toda la información. Cambio y fuera, Rodri." TELEGRAM_VOICE_SPOKEN_CHAR_CAP=300 TELEGRAM_VOICE_ENABLED=true ELEVENLABS_API_KEY=x bun /tmp/helpers.ts
  '
  echo "$output"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^E10_OK cap=900 budget=848 qlen=807"
  echo "$output" | grep -q "^E10_OK cap=300 budget=248 "
  [ "$(echo "$output" | grep -c "^FAIL" || true)" -eq 0 ]
}

# ── E12 (034): the in-container upgrade of a real v2-patched (033) source to v3 ─
# Second run must be a sha no-op that logs the truthful CANON-L1 line
# (`all patch groups already present`) — a v0.24.0 patcher was silent there.

@test "E2E 034: seeding the golden v2 fixture and running the boot patcher upgrades it to v3 in place; a second run is a logged no-op" {
  run docker compose run --rm -T --user agent --entrypoint sh voicebot -c '
    set -e
    server=$(sh /workspace/.e2e/seed.sh telegram-server-voice-v2.ts)
    echo "V3COUNT=$(grep -c "agentic-pod-launcher: telegram voice roundtrip patch v3" "$server" || true)"
    echo "V2COUNT=$(grep -c "agentic-pod-launcher: telegram voice roundtrip patch v2" "$server" || true)"
    echo "V1COUNT=$(grep -c "agentic-pod-launcher: telegram voice roundtrip patch v1" "$server" || true)"
    grep -q "voice-upgrade-v2→v3" /tmp/patch.log
    echo "V12COUNT=$(grep -c "voice-upgrade-v1→v2" /tmp/patch.log || true)"
    sha1=$(sha256sum "$server" | cut -d" " -f1)
    python3 /opt/agent-admin/scripts/apply_telegram_typing_patch.py "$server" > /tmp/patch2.log 2>&1
    sha2=$(sha256sum "$server" | cut -d" " -f1)
    [ "$sha1" = "$sha2" ]
    echo "L1COUNT=$(grep -c "all patch groups already present" /tmp/patch2.log || true)"
  '
  echo "$output"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "V3COUNT=1"
  echo "$output" | grep -qx "V2COUNT=0"
  echo "$output" | grep -qx "V1COUNT=0"
  echo "$output" | grep -qx "V12COUNT=0"
  echo "$output" | grep -qx "L1COUNT=1"
}
