#!/usr/bin/env bats
# Tests for docker/scripts/apply_telegram_typing_patch.py — three independent
# hunk groups (typing / offset / stderr) applied to a synthetic server.ts
# fixture that mimics the upstream claude-plugins-official/telegram source.
#
# The offset group has 4 sub-hunks (helpers / replay / mark / ack); a
# single MARKER_OFFSET gates the whole group, so anchor drift on any one
# of them rolls back the others. See the patcher docstring for rationale.

load helper

PATCHER="$REPO_ROOT/docker/scripts/apply_telegram_typing_patch.py"

setup() {
  setup_tmp_dir
  # Synthetic server.ts containing the anchors the patcher targets:
  #   1. `const TOKEN = process.env.TELEGRAM_BOT_TOKEN`        → stderr hunk
  #   2. `let botUsername = ''`                                → typing+offset+voice helpers
  #   3. `  const chat_id = String(ctx.chat!.id)` (2-sp ind.)  → offset mark hunk
  #   4. `  // Typing indicator — signals "processing" ...`    → typing hunk2
  #   5. `      case 'reply': {`                               → typing hunk3
  #   6. `        const result = …\n          sentIds.length === 1` → offset ack hunk
  #   7. `      await bot.start({`                             → offset replay hunk
  #   8. `bot.on('message:voice', ...)` (real 0.0.6 shape)      → voice hunk V1
  #   9. `bot.on('message:text', ...)` (real 0.0.6 shape)       → voice hunk V6
  #  10. `        return { content: [...text: result...] }`    → voice hunk V2
  #  11. reply tool inputSchema (real ListToolsRequestSchema shape) → voice hunk V3
  #  12. `    instructions: [`                                 → voice hunk V4
  #
  # The fixture is extracted verbatim to tests/fixtures/telegram-server-pristine.ts
  # (033) so the DOCKER_E2E harness can seed the same source into a container.
  cp "$REPO_ROOT/tests/fixtures/telegram-server-pristine.ts" "$TMP_TEST_DIR/server.ts"
}

teardown() { teardown_tmp_dir; }

@test "patcher applies all 6 markers on a fresh fixture" {
  run python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  [ "$status" -eq 0 ]
  grep -q "agentic-pod-launcher: typing refresh patch v6" "$TMP_TEST_DIR/server.ts"
  grep -q "agentic-pod-launcher: offset persistence patch v1" "$TMP_TEST_DIR/server.ts"
  grep -q "agentic-pod-launcher: pending-reply marker patch v1" "$TMP_TEST_DIR/server.ts"
  grep -q "agentic-pod-launcher: stderr-capture patch v1" "$TMP_TEST_DIR/server.ts"
  grep -q "agentic-pod-launcher: primary lock patch v1" "$TMP_TEST_DIR/server.ts"
  grep -q "agentic-pod-launcher: askq-guard give-up delivery patch v1" "$TMP_TEST_DIR/server.ts"
}

# ── 028 US1: pending-reply marker hunks (contracts/pending-reply-marker.md) ───────

@test "028 pending-marker: helpers declare _markPendingReply / _clearPendingReply + file path" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  grep -q "function _markPendingReply(chatId: string | number, updateId: number): void" "$TMP_TEST_DIR/server.ts"
  grep -q "function _clearPendingReply(): void" "$TMP_TEST_DIR/server.ts"
  grep -q "/home/agent/.claude/channels/telegram/pending-reply.json" "$TMP_TEST_DIR/server.ts"
}

@test "028 pending-marker: write injected in handleInbound, clear injected in case 'reply'" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  grep -A 4 "  const chat_id = String(ctx.chat!.id)" "$TMP_TEST_DIR/server.ts" \
    | grep -q "_markPendingReply(chat_id, ctx.update.update_id)"
  grep -B 4 "        const result =" "$TMP_TEST_DIR/server.ts" \
    | grep -q "_clearPendingReply()"
}

# ── 028 US2: honest timeout message (typing v5) ──────────────────────────────────

@test "028 US2: fresh install carries the honest timeout message, not an OAuth assertion" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  # names more than one cause + a diagnostic …
  grep -q "sin usar la herramienta de envío" "$TMP_TEST_DIR/server.ts"
  grep -q "agentctl doctor" "$TMP_TEST_DIR/server.ts"
  # … and does NOT assert OAuth as the definite cause (negative last).
  ! grep -q "Es probable que el OAuth de Claude haya expirado o haya un error de conectividad" "$TMP_TEST_DIR/server.ts"
}

@test "028/031: a v4-patched server.ts cascades through v5 all the way to v6" {
  # Fresh → v6, then revert marker + comment + message to simulate an existing v4 agent.
  # The full cascade (v4→v5→v6) must run in one pass — the v5 step is no longer
  # the end state now that 031 adds v6 on top.
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  perl -0pi -e 's/typing refresh patch v6/typing refresh patch v4/g; s/telegram-typing v6 — names interactive-prompt cause/telegram-typing v4 — anti-zombie/g' "$TMP_TEST_DIR/server.ts"
  perl -0pi -e 's/⚠️ Llevo más de \$\{minutes\} min sin entregar la respuesta a este chat\. Puede deberse a: una respuesta larga aún en curso, a que respondí sin usar la herramienta de envío, a que el login de Claude haya expirado, o a que la sesión quedó bloqueada en un menú interactivo que el canal no puede responder\. Revisa: agentctl doctor\./⚠️ Tardé más de \${minutes} min en responder. Es probable que el OAuth de Claude haya expirado o haya un error de conectividad. Revisa: agentctl doctor./g' "$TMP_TEST_DIR/server.ts"
  grep -q "typing refresh patch v4" "$TMP_TEST_DIR/server.ts"
  run grep -q "typing refresh patch v6" "$TMP_TEST_DIR/server.ts"; [ "$status" -ne 0 ]
  # re-run → v4→v5→v6 cascade
  run python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  [ "$status" -eq 0 ]
  grep -q "typing refresh patch v6" "$TMP_TEST_DIR/server.ts"
  grep -q "sin usar la herramienta de envío" "$TMP_TEST_DIR/server.ts"
  grep -q "bloqueada en un menú interactivo" "$TMP_TEST_DIR/server.ts"
  run grep -q "typing refresh patch v4" "$TMP_TEST_DIR/server.ts"; [ "$status" -ne 0 ]
  ! grep -q "Es probable que el OAuth de Claude haya expirado" "$TMP_TEST_DIR/server.ts"
}

@test "patcher is idempotent — second run is a no-op" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  local sha1
  sha1=$(shasum "$TMP_TEST_DIR/server.ts" | awk '{print $1}')
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  local sha2
  sha2=$(shasum "$TMP_TEST_DIR/server.ts" | awk '{print $1}')
  [ "$sha1" = "$sha2" ]
}

@test "patcher exits 0 and doesn't touch file when path doesn't exist" {
  run python3 "$PATCHER" "$TMP_TEST_DIR/nonexistent.ts"
  [ "$status" -eq 0 ]
}

@test "offset patch: helpers declare _pendingUpdates Map and ack/mark fns" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  grep -q "const _pendingUpdates = new Map<string | number, number>()" "$TMP_TEST_DIR/server.ts"
  grep -q "function _markPending(chatId: string | number, updateId: number): void" "$TMP_TEST_DIR/server.ts"
  grep -q "function _ackPending(chatId: string | number): void" "$TMP_TEST_DIR/server.ts"
}

@test "offset patch: _saveOffset writes update_id + 1 (not update_id)" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  grep -q "offset: updateId + 1" "$TMP_TEST_DIR/server.ts"
}

@test "offset patch: _markPending injected after handleInbound chat_id binding" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  # OFFSET_MARK is a 2-line block (marker comment + the _markPending call) inserted
  # after the chat_id binding. 028's pending-reply marker also anchors on that line
  # (independent patch), so widen the window to -A 4 to clear both blocks.
  grep -A 4 "  const chat_id = String(ctx.chat!.id)" "$TMP_TEST_DIR/server.ts" \
    | grep -q "_markPending(chat_id, ctx.update.update_id)"
}

@test "offset patch: _ackPending injected immediately before const result in case 'reply'" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  # The ack line appears before `const result =` in case 'reply'. 028's pending
  # marker also clears before that line (independent patch), so widen to -B 3.
  grep -B 3 "        const result =" "$TMP_TEST_DIR/server.ts" \
    | grep -q "_ackPending(chat_id)"
}

@test "offset patch: replay block uses bot.api.getUpdates with offset before bot.start" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  grep -q "bot.api.getUpdates({ offset: _resume" "$TMP_TEST_DIR/server.ts"
  # Replay block must be ABOVE await bot.start.
  local resume_line start_line
  resume_line=$(grep -n "bot.api.getUpdates({ offset: _resume" "$TMP_TEST_DIR/server.ts" | head -1 | cut -d: -f1)
  start_line=$(grep -n "await bot.start({" "$TMP_TEST_DIR/server.ts" | head -1 | cut -d: -f1)
  [ "$resume_line" -lt "$start_line" ]
}

@test "offset patch: no leftover bot.use middleware from old pre-ack-on-reply design" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  # The pre-v2 middleware approach (`bot.use(async (ctx, next) => { await next(); _saveOffset(...) })`)
  # is REMOVED. If it ever leaks back in, _saveOffset would advance offset before
  # claude replies → reverts the reliability fix.
  ! grep -q "bot.use(async (ctx, next) => {" "$TMP_TEST_DIR/server.ts"
}

@test "stderr patch: registers process.on('uncaughtException')" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  grep -q "process.on('uncaughtException'" "$TMP_TEST_DIR/server.ts"
  grep -q "process.on('unhandledRejection'" "$TMP_TEST_DIR/server.ts"
}

@test "stderr patch: writes to /workspace/scripts/heartbeat/logs/telegram-mcp-stderr.log" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  grep -q "/workspace/scripts/heartbeat/logs/telegram-mcp-stderr.log" "$TMP_TEST_DIR/server.ts"
}

@test "typing patch: _typingKeepAlive replaces sendChatAction at the call site" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  grep -q "_typingKeepAlive(chat_id)" "$TMP_TEST_DIR/server.ts"
  grep -q "_typingStop(chat_id)" "$TMP_TEST_DIR/server.ts"
}

@test "anchor drift: missing typing-hunk2 anchor → typing skipped, offset+stderr still apply" {
  # Break the typing hunk2 anchor (the sendChatAction comment) but leave
  # the others intact. Typing must NOT apply (no marker), offset+stderr MUST.
  sed -i.bak 's|// Typing indicator — signals "processing"|// REMOVED|' "$TMP_TEST_DIR/server.ts"
  rm -f "$TMP_TEST_DIR/server.ts.bak"
  run python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  [ "$status" -eq 0 ]
  ! grep -q "agentic-pod-launcher: typing refresh patch v6" "$TMP_TEST_DIR/server.ts"
  grep -q "agentic-pod-launcher: offset persistence patch v1" "$TMP_TEST_DIR/server.ts"
  grep -q "agentic-pod-launcher: stderr-capture patch v1" "$TMP_TEST_DIR/server.ts"
}

@test "anchor drift: missing const TOKEN anchor → stderr skipped, typing+offset still apply" {
  # Mangle the stderr anchor; typing+offset have independent anchors.
  sed -i.bak 's|const TOKEN = process.env|const NOT_TOKEN = process.env|' "$TMP_TEST_DIR/server.ts"
  rm -f "$TMP_TEST_DIR/server.ts.bak"
  run python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  [ "$status" -eq 0 ]
  grep -q "agentic-pod-launcher: typing refresh patch v6" "$TMP_TEST_DIR/server.ts"
  grep -q "agentic-pod-launcher: offset persistence patch v1" "$TMP_TEST_DIR/server.ts"
  ! grep -q "agentic-pod-launcher: stderr-capture patch v1" "$TMP_TEST_DIR/server.ts"
}

@test "anchor drift: missing handleInbound chat_id anchor → offset group skipped (rolls back B1+B2)" {
  # Drop the handleInbound chat_id binding. apply_offset must detect the B3
  # anchor miss and skip the WHOLE offset group — no marker, no leftover B1
  # helpers in the file. typing+stderr stay independent.
  sed -i.bak 's|  const chat_id = String(ctx.chat!.id)|  // anchor removed|' "$TMP_TEST_DIR/server.ts"
  rm -f "$TMP_TEST_DIR/server.ts.bak"
  run python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  [ "$status" -eq 0 ]
  ! grep -q "agentic-pod-launcher: offset persistence patch v1" "$TMP_TEST_DIR/server.ts"
  ! grep -q "_pendingUpdates" "$TMP_TEST_DIR/server.ts"
  grep -q "agentic-pod-launcher: typing refresh patch v6" "$TMP_TEST_DIR/server.ts"
  grep -q "agentic-pod-launcher: stderr-capture patch v1" "$TMP_TEST_DIR/server.ts"
}

@test "anchor drift: missing case 'reply' result anchor → offset group skipped (rolls back B1+B2+B3)" {
  # Mangle the `const result =` line. apply_offset must skip the whole offset
  # group — any partial application would leave _markPending without a paired
  # _ackPending and the offset would silently never advance.
  sed -i.bak 's|        const result =|        const NOT_result =|' "$TMP_TEST_DIR/server.ts"
  rm -f "$TMP_TEST_DIR/server.ts.bak"
  run python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  [ "$status" -eq 0 ]
  ! grep -q "agentic-pod-launcher: offset persistence patch v1" "$TMP_TEST_DIR/server.ts"
  ! grep -q "_pendingUpdates" "$TMP_TEST_DIR/server.ts"
  ! grep -q "_markPending" "$TMP_TEST_DIR/server.ts"
}

@test "primary patch: mtime-fresh guard injected before SIGTERM" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  # Guard must appear BETWEEN process.kill(stale, 0) and SIGTERM. Use grep -A
  # to capture the lines after the liveness probe; the next non-comment lines
  # should reference statSync(PID_FILE).mtimeMs and process.exit(0).
  grep -A 8 "    process.kill(stale, 0)" "$TMP_TEST_DIR/server.ts" \
    | grep -q "statSync(PID_FILE).mtimeMs"
  grep -A 8 "    process.kill(stale, 0)" "$TMP_TEST_DIR/server.ts" \
    | grep -q "exiting as secondary"
  grep -A 8 "    process.kill(stale, 0)" "$TMP_TEST_DIR/server.ts" \
    | grep -q "process.exit(0)"
}

@test "primary patch: heartbeat setInterval injected after writeFileSync(PID_FILE, ...)" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  # The heartbeat interval must appear after the initial PID_FILE write.
  grep -A 5 "writeFileSync(PID_FILE, String(process.pid))" "$TMP_TEST_DIR/server.ts" \
    | grep -q "setInterval(() => {"
  grep -A 5 "writeFileSync(PID_FILE, String(process.pid))" "$TMP_TEST_DIR/server.ts" \
    | grep -q "5000"
  grep -A 5 "writeFileSync(PID_FILE, String(process.pid))" "$TMP_TEST_DIR/server.ts" \
    | grep -q ".unref()"
}

@test "primary patch: 30s freshness threshold matches the heartbeat interval (5s) with safety margin" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  # Sanity check: the guard's 30000ms threshold and the heartbeat's 5000ms
  # interval ratio is 6:1. A primary that paused its event loop for >30s is
  # genuinely wedged and should be replaced; this prevents secondary takeover
  # from a transiently slow primary while still failing-over from a frozen one.
  grep -q "_ageMs < 30000" "$TMP_TEST_DIR/server.ts"
  grep -q "}, 5000).unref()" "$TMP_TEST_DIR/server.ts"
}

@test "anchor drift: missing process.kill(stale, 0) anchor → primary patch skipped (rolls back C1)" {
  # Mangle the kill-0 liveness probe. apply_primary must skip the whole
  # group — without C1 the heartbeat-only C2 would still let secondaries
  # SIGTERM the primary on every spawn.
  sed -i.bak 's|    process.kill(stale, 0)|    // anchor removed|' "$TMP_TEST_DIR/server.ts"
  rm -f "$TMP_TEST_DIR/server.ts.bak"
  run python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  [ "$status" -eq 0 ]
  ! grep -q "agentic-pod-launcher: primary lock patch v1" "$TMP_TEST_DIR/server.ts"
  ! grep -q "_ageMs" "$TMP_TEST_DIR/server.ts"
  # Other patches still apply (independent groups).
  grep -q "agentic-pod-launcher: offset persistence patch v1" "$TMP_TEST_DIR/server.ts"
  grep -q "agentic-pod-launcher: typing refresh patch v6" "$TMP_TEST_DIR/server.ts"
}

# ─── typing v3: cap removal + observability ──────────────────────────────────
# v1 had `_TYPING_MAX_MS = 120000` + a setTimeout that called _typingStop after
# the cap. v2 removed both — typing keeps running until `case 'reply'` fires
# _typingStop or the bun process dies. v3 adds observability: each tick logs
# to stderr every 5 invocations, sendChatAction errors are surfaced instead
# of swallowed by `.catch(() => {})`. These tests pin the v3 behavior and
# protect the v1→v2→v3 in-place upgrade path on already-patched server.ts.

@test "typing v4: helpers contain no v1-style _TYPING_MAX_MS = 120000 cap" {
  run python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  [ "$status" -eq 0 ]
  # v1 had `const _TYPING_MAX_MS = 120000`; v2/v3 stripped it. v4 introduces
  # `_TYPING_MAX_DURATION_MS` (a longer name), so the v1 pattern must not
  # appear, but the v4 cap must.
  ! grep -q "_TYPING_MAX_MS = 120000" "$TMP_TEST_DIR/server.ts"
  grep -q "_TYPING_MAX_DURATION_MS" "$TMP_TEST_DIR/server.ts"
}

@test "typing v4: cap is checked inline (not via setTimeout)" {
  run python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  [ "$status" -eq 0 ]
  # v1 used `setTimeout(() => _typingStop, ...)` for the cap. v4 checks
  # `Date.now() - started > _TYPING_MAX_DURATION_MS` inside the
  # setInterval callback instead — keeps the cap accurate per-tick and
  # lets us send a user-facing warning before stopping.
  ! grep -qE "setTimeout\(\(\) => _typingStop" "$TMP_TEST_DIR/server.ts"
  grep -q "elapsed > _TYPING_MAX_DURATION_MS" "$TMP_TEST_DIR/server.ts"
}

@test "typing v4: aborted timeout sends user-facing warning + stderr log" {
  run python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  [ "$status" -eq 0 ]
  # When the cap fires, the helper sends a Telegram message + writes to stderr.
  grep -q 'bot.api.sendMessage(chat_id, warnMsg)' "$TMP_TEST_DIR/server.ts"
  grep -q "typing aborted after" "$TMP_TEST_DIR/server.ts"
  # Env-var override exposed.
  grep -q "TELEGRAM_TYPING_MAX_MS" "$TMP_TEST_DIR/server.ts"
}

@test "typing v4: helpers log a tick to stderr every 5 calls (preserved from v3)" {
  run python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  [ "$status" -eq 0 ]
  grep -q "typing tick" "$TMP_TEST_DIR/server.ts"
  grep -q "_typingTickCounts" "$TMP_TEST_DIR/server.ts"
}

@test "typing v4: helpers surface sendChatAction errors instead of swallowing them (preserved from v3)" {
  run python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  [ "$status" -eq 0 ]
  grep -q "sendChatAction failed" "$TMP_TEST_DIR/server.ts"
  ! grep -qE "sendChatAction\([^)]+\)\.catch\(\(\) => \{\}\)" "$TMP_TEST_DIR/server.ts"
}

@test "typing v1→v2→v3 upgrade: rewrites already-patched server.ts in place" {
  # Synthesize a v1-patched server.ts inline (the v2 patcher can't emit v1,
  # so we can't roundtrip through the script). The helper strings below
  # mirror what the v1 patch would have produced verbatim — v1 and v2 differ
  # only in the cap (constant + setTimeout block) and the inline comment.
  cat > "$TMP_TEST_DIR/server.v1.ts" <<'TS'
#!/usr/bin/env bun
import { Bot } from 'grammy'

const TOKEN = process.env.TELEGRAM_BOT_TOKEN
const bot = new Bot(TOKEN!)
let botUsername = ''

// agentic-pod-launcher: typing refresh patch v1
const _typingIntervals = new Map<string | number, ReturnType<typeof setInterval>>()
const _TYPING_REFRESH_MS = 4000
const _TYPING_MAX_MS = 120000
function _typingKeepAlive(chat_id: string | number): void {
  _typingStop(chat_id)
  const send = () => { void bot.api.sendChatAction(chat_id, 'typing').catch(() => {}) }
  send()
  const timer = setInterval(send, _TYPING_REFRESH_MS)
  _typingIntervals.set(chat_id, timer)
  const cap = setTimeout(() => _typingStop(chat_id), _TYPING_MAX_MS)
  ;(cap as { unref?: () => void }).unref?.()
}
function _typingStop(chat_id: string | number): void {
  const t = _typingIntervals.get(chat_id)
  if (t) { clearInterval(t); _typingIntervals.delete(chat_id) }
}

async function handleInbound(ctx: any) {
  const chat_id = String(ctx.chat!.id)
  // Typing indicator — refreshed every 4s until reply fires, 120s hard cap.
  // Patched by agentic-pod-launcher (telegram-typing v1).
  _typingKeepAlive(chat_id)
}
TS

  # Sanity: the synthetic fixture really looks like v1.
  grep -q "typing refresh patch v1" "$TMP_TEST_DIR/server.v1.ts"
  grep -q "_TYPING_MAX_MS" "$TMP_TEST_DIR/server.v1.ts"

  # Run the patcher: it should detect v1 and cascade v1→v2→v3→v4→v5→v6 in place.
  run python3 "$PATCHER" "$TMP_TEST_DIR/server.v1.ts"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "typing-upgrade-v1"
  echo "$output" | grep -q "typing-upgrade-v2"
  echo "$output" | grep -q "typing-upgrade-v3"
  echo "$output" | grep -q "typing-upgrade-v4"
  echo "$output" | grep -q "typing-upgrade-v5"

  # Post-upgrade: marker bumped to v6 (cascade v1→…→v6), v1 cap stripped,
  # comment refreshed, v3 instrumentation preserved, v4 anti-zombie cap in place,
  # v6 message naming the interactive-prompt cause.
  ! grep -q "typing refresh patch v1" "$TMP_TEST_DIR/server.v1.ts"
  ! grep -q "typing refresh patch v2" "$TMP_TEST_DIR/server.v1.ts"
  ! grep -q "typing refresh patch v3" "$TMP_TEST_DIR/server.v1.ts"
  ! grep -q "typing refresh patch v4" "$TMP_TEST_DIR/server.v1.ts"
  ! grep -q "typing refresh patch v5" "$TMP_TEST_DIR/server.v1.ts"
  grep -q "typing refresh patch v6" "$TMP_TEST_DIR/server.v1.ts"
  ! grep -q "_TYPING_MAX_MS = 120000" "$TMP_TEST_DIR/server.v1.ts"
  grep -q "_TYPING_MAX_DURATION_MS" "$TMP_TEST_DIR/server.v1.ts"
  ! grep -qE "setTimeout\(\(\) => _typingStop" "$TMP_TEST_DIR/server.v1.ts"
  grep -q "aborts after _TYPING_MAX_DURATION_MS" "$TMP_TEST_DIR/server.v1.ts"
  grep -q "typing tick" "$TMP_TEST_DIR/server.v1.ts"
  grep -q "sendChatAction failed" "$TMP_TEST_DIR/server.v1.ts"
}

@test "typing v2→v3→v4 upgrade: rewrites a v2-patched server.ts in place" {
  # Synthesize a v2-patched fixture (v2 = v1 with the cap removed). Same
  # shape the v1→v2 upgrade would have produced, but starting from v2 so
  # only the v2→v3 step needs to run.
  cat > "$TMP_TEST_DIR/server.v2.ts" <<'TS'
#!/usr/bin/env bun
import { Bot } from 'grammy'

const TOKEN = process.env.TELEGRAM_BOT_TOKEN
const bot = new Bot(TOKEN!)
let botUsername = ''

// agentic-pod-launcher: typing refresh patch v2
const _typingIntervals = new Map<string | number, ReturnType<typeof setInterval>>()
const _TYPING_REFRESH_MS = 4000
function _typingKeepAlive(chat_id: string | number): void {
  _typingStop(chat_id)
  const send = () => { void bot.api.sendChatAction(chat_id, 'typing').catch(() => {}) }
  send()
  const timer = setInterval(send, _TYPING_REFRESH_MS)
  _typingIntervals.set(chat_id, timer)
}
function _typingStop(chat_id: string | number): void {
  const t = _typingIntervals.get(chat_id)
  if (t) { clearInterval(t); _typingIntervals.delete(chat_id) }
}

async function handleInbound(ctx: any) {
  const chat_id = String(ctx.chat!.id)
  // Typing indicator — refreshed every 4s until reply fires (no cap; stops on reply or process exit).
  // Patched by agentic-pod-launcher (telegram-typing v2).
  _typingKeepAlive(chat_id)
}
TS

  # Sanity: it really is v2.
  grep -q "typing refresh patch v2" "$TMP_TEST_DIR/server.v2.ts"
  ! grep -q "typing tick" "$TMP_TEST_DIR/server.v2.ts"

  # Run the patcher: should detect v2 and run v2→v3→v4→v5→v6 cascade.
  run python3 "$PATCHER" "$TMP_TEST_DIR/server.v2.ts"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "typing-upgrade-v2"
  echo "$output" | grep -q "typing-upgrade-v3"
  echo "$output" | grep -q "typing-upgrade-v4"
  echo "$output" | grep -q "typing-upgrade-v5"
  ! echo "$output" | grep -q "typing-upgrade-v1"

  # Post-upgrade: v6 marker (cascade v2→…→v6), v3 instrumentation preserved,
  # v4 cap in place, call-site comment refreshed to v6, interactive-prompt-cause message.
  ! grep -q "typing refresh patch v2" "$TMP_TEST_DIR/server.v2.ts"
  ! grep -q "typing refresh patch v3" "$TMP_TEST_DIR/server.v2.ts"
  ! grep -q "typing refresh patch v4" "$TMP_TEST_DIR/server.v2.ts"
  ! grep -q "typing refresh patch v5" "$TMP_TEST_DIR/server.v2.ts"
  grep -q "typing refresh patch v6" "$TMP_TEST_DIR/server.v2.ts"
  grep -q "typing tick" "$TMP_TEST_DIR/server.v2.ts"
  grep -q "sendChatAction failed" "$TMP_TEST_DIR/server.v2.ts"
  grep -q "_TYPING_MAX_DURATION_MS" "$TMP_TEST_DIR/server.v2.ts"
  grep -q "telegram-typing v6 — names interactive-prompt cause" "$TMP_TEST_DIR/server.v2.ts"
}

@test "typing v3→v4 upgrade: rewrites a v3-patched server.ts in place" {
  # Synthesize a v3-patched fixture (v3 = v2 with stderr instrumentation).
  cat > "$TMP_TEST_DIR/server.v3.ts" <<'TS'
#!/usr/bin/env bun
import { Bot } from 'grammy'

const TOKEN = process.env.TELEGRAM_BOT_TOKEN
const bot = new Bot(TOKEN!)
let botUsername = ''

// agentic-pod-launcher: typing refresh patch v3
const _typingIntervals = new Map<string | number, ReturnType<typeof setInterval>>()
const _typingTickCounts = new Map<string | number, number>()
const _TYPING_REFRESH_MS = 4000
function _typingKeepAlive(chat_id: string | number): void {
  _typingStop(chat_id)
  _typingTickCounts.set(chat_id, 0)
  const send = () => {
    const tick = (_typingTickCounts.get(chat_id) ?? 0) + 1
    _typingTickCounts.set(chat_id, tick)
    bot.api.sendChatAction(chat_id, 'typing')
      .then(() => {
        if (tick === 1 || tick % 5 === 0) {
          process.stderr.write(`telegram channel: typing tick ${tick} for chat ${chat_id}\n`)
        }
      })
      .catch((err: any) => {
        const msg = err && (err.message || err.description || String(err))
        process.stderr.write(`telegram channel: sendChatAction failed for chat ${chat_id} tick ${tick}: ${msg}\n`)
      })
  }
  send()
  const timer = setInterval(send, _TYPING_REFRESH_MS)
  _typingIntervals.set(chat_id, timer)
}
function _typingStop(chat_id: string | number): void {
  const t = _typingIntervals.get(chat_id)
  if (t) { clearInterval(t); _typingIntervals.delete(chat_id) }
  _typingTickCounts.delete(chat_id)
}

async function handleInbound(ctx: any) {
  const chat_id = String(ctx.chat!.id)
  // Typing indicator — refreshed every 4s until reply fires (no cap; stops on reply or process exit).
  // Patched by agentic-pod-launcher (telegram-typing v3 — instrumented).
  _typingKeepAlive(chat_id)
}
TS

  # Sanity: it really is v3.
  grep -q "typing refresh patch v3" "$TMP_TEST_DIR/server.v3.ts"
  ! grep -q "_TYPING_MAX_DURATION_MS" "$TMP_TEST_DIR/server.v3.ts"

  # Run the patcher: should detect v3 and run the v3→v4→v5→v6 steps.
  run python3 "$PATCHER" "$TMP_TEST_DIR/server.v3.ts"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "typing-upgrade-v3"
  echo "$output" | grep -q "typing-upgrade-v4"
  echo "$output" | grep -q "typing-upgrade-v5"
  ! echo "$output" | grep -q "typing-upgrade-v1"
  ! echo "$output" | grep -q "typing-upgrade-v2"

  # Post-upgrade: v6 marker (cascade v3→…→v6), v4 cap in place, instrumentation
  # preserved, call-site comment at v6.
  ! grep -q "typing refresh patch v3" "$TMP_TEST_DIR/server.v3.ts"
  ! grep -q "typing refresh patch v4" "$TMP_TEST_DIR/server.v3.ts"
  ! grep -q "typing refresh patch v5" "$TMP_TEST_DIR/server.v3.ts"
  grep -q "typing refresh patch v6" "$TMP_TEST_DIR/server.v3.ts"
  grep -q "_TYPING_MAX_DURATION_MS" "$TMP_TEST_DIR/server.v3.ts"
  grep -q "TELEGRAM_TYPING_MAX_MS" "$TMP_TEST_DIR/server.v3.ts"
  grep -q "telegram-typing v6 — names interactive-prompt cause" "$TMP_TEST_DIR/server.v3.ts"
  grep -q "typing tick" "$TMP_TEST_DIR/server.v3.ts"
  grep -q "sendChatAction failed" "$TMP_TEST_DIR/server.v3.ts"
}

# ─── 031: AskUserQuestion guard give-up delivery + typing v6 ────────────────

@test "patcher applies the 6th marker (askq give-up hunk) on a fresh fixture" {
  run python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  [ "$status" -eq 0 ]
  grep -q "agentic-pod-launcher: askq-guard give-up delivery patch v1" "$TMP_TEST_DIR/server.ts"
}

@test "031: typing marker is bumped to v6" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  grep -q "agentic-pod-launcher: typing refresh patch v6" "$TMP_TEST_DIR/server.ts"
  ! grep -q "agentic-pod-launcher: typing refresh patch v5" "$TMP_TEST_DIR/server.ts"
}

@test "031: typing v6 warning names the interactive-prompt cause, still no single definite cause" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  grep -q "sin usar la herramienta de envío" "$TMP_TEST_DIR/server.ts"
  grep -q "bloqueada en un menú interactivo" "$TMP_TEST_DIR/server.ts"
  grep -q "agentctl doctor" "$TMP_TEST_DIR/server.ts"
  ! grep -q "Es probable que el OAuth de Claude haya expirado o haya un error de conectividad" "$TMP_TEST_DIR/server.ts"
}

@test "031: a v5-patched server.ts ratchets to v6 with the interactive-prompt cause" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  perl -0pi -e 's/typing refresh patch v6/typing refresh patch v5/g; s/telegram-typing v6 — names interactive-prompt cause/telegram-typing v5 — honest timeout/g' "$TMP_TEST_DIR/server.ts"
  perl -0pi -e 's/a que el login de Claude haya expirado, o a que la sesión quedó bloqueada en un menú interactivo que el canal no puede responder\. Revisa: agentctl doctor\./o a que el login de Claude haya expirado. Revisa: agentctl doctor./g' "$TMP_TEST_DIR/server.ts"
  grep -q "typing refresh patch v5" "$TMP_TEST_DIR/server.ts"
  run grep -q "typing refresh patch v6" "$TMP_TEST_DIR/server.ts"; [ "$status" -ne 0 ]
  run python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  [ "$status" -eq 0 ]
  grep -q "typing refresh patch v6" "$TMP_TEST_DIR/server.ts"
  grep -q "bloqueada en un menú interactivo" "$TMP_TEST_DIR/server.ts"
  run grep -q "typing refresh patch v5" "$TMP_TEST_DIR/server.ts"; [ "$status" -ne 0 ]
}

@test "031 give-up: helpers declare the read/send/clear function reading askq-guard-giveup.json" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  grep -q "_ASKQ_GIVEUP_FILE" "$TMP_TEST_DIR/server.ts"
  grep -q "askq-guard-giveup.json" "$TMP_TEST_DIR/server.ts"
  grep -q "function _checkAskqGiveup" "$TMP_TEST_DIR/server.ts"
}

@test "031 give-up: check is wired into the typing keep-alive tick AND its start (next-turn safety net)" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  # Trigger 1: inside the setInterval send() callback (every tick).
  grep -B2 -A2 "bot.api.sendChatAction(chat_id, 'typing')" "$TMP_TEST_DIR/server.ts" \
    | grep -q "_checkAskqGiveup" || \
  grep -B10 "bot.api.sendChatAction(chat_id, 'typing')" "$TMP_TEST_DIR/server.ts" \
    | grep -q "_checkAskqGiveup"
  # Trigger 2: at _typingKeepAlive start (fires on the next inbound turn).
  grep -A3 "function _typingKeepAlive(chat_id: string | number): void {" "$TMP_TEST_DIR/server.ts" \
    | grep -q "_checkAskqGiveup"
}

@test "031 give-up: delivers via bot.api.sendMessage and deletes the marker (delete-on-send)" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  grep -A 20 "function _checkAskqGiveup" "$TMP_TEST_DIR/server.ts" | grep -q "bot.api.sendMessage"
  grep -A 20 "function _checkAskqGiveup" "$TMP_TEST_DIR/server.ts" | grep -q "rmSync(_ASKQ_GIVEUP_FILE"
}

@test "031 give-up: never includes question text or a secret — only a fixed message" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  ! grep -qi "tool_input\|questions\[" "$TMP_TEST_DIR/server.ts"
}

@test "031 give-up: idempotent re-run is a no-op" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  local sha1
  sha1=$(shasum "$TMP_TEST_DIR/server.ts" | awk '{print $1}')
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  local sha2
  sha2=$(shasum "$TMP_TEST_DIR/server.ts" | awk '{print $1}')
  [ "$sha1" = "$sha2" ]
}

@test "anchor drift: missing typingKeepAlive anchor → askq give-up hunk skipped, others still apply" {
  sed -i.bak 's|function _typingKeepAlive|function _renamedTypingKeepAlive|' "$TMP_TEST_DIR/server.ts"
  rm -f "$TMP_TEST_DIR/server.ts.bak"
  run python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  [ "$status" -eq 0 ]
  ! grep -q "agentic-pod-launcher: askq-guard give-up delivery patch v1" "$TMP_TEST_DIR/server.ts"
  grep -q "agentic-pod-launcher: offset persistence patch v1" "$TMP_TEST_DIR/server.ts"
  grep -q "agentic-pod-launcher: stderr-capture patch v1" "$TMP_TEST_DIR/server.ts"
}

@test "typing v6: idempotent re-run on already-v6 server.ts is a no-op" {
  # First run: install v6 fresh.
  run python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  [ "$status" -eq 0 ]
  local v6_count_before
  v6_count_before=$(grep -c "typing refresh patch v6" "$TMP_TEST_DIR/server.ts")
  [ "$v6_count_before" -eq 1 ]

  # Second run: should be a no-op (output empty, file unchanged).
  run python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  [ "$status" -eq 0 ]
  local v6_count_after
  v6_count_after=$(grep -c "typing refresh patch v6" "$TMP_TEST_DIR/server.ts")
  [ "$v6_count_before" -eq "$v6_count_after" ]
}

# ── 032 US1: inbound voice → transcript (contracts/voice-inbound-stt.md) ─────────

@test "032 inbound: marker present exactly once on a fresh fixture" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  local count
  count=$(grep -c "agentic-pod-launcher: telegram voice roundtrip patch v3" "$TMP_TEST_DIR/server.ts")
  [ "$count" -eq 1 ]
}

@test "032 inbound: double-apply is idempotent (voice marker count stable, file unchanged)" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  local sha1
  sha1=$(shasum "$TMP_TEST_DIR/server.ts" | awk '{print $1}')
  run python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  [ "$status" -eq 0 ]
  local sha2
  sha2=$(shasum "$TMP_TEST_DIR/server.ts" | awk '{print $1}')
  [ "$sha1" = "$sha2" ]
  local count
  count=$(grep -c "agentic-pod-launcher: telegram voice roundtrip patch v3" "$TMP_TEST_DIR/server.ts")
  [ "$count" -eq 1 ]
}

@test "032 inbound: anchor drift on message:voice handler → voice skipped, other groups still apply" {
  sed -i.bak "s|bot.on('message:voice', async ctx => {|bot.on('message:voicex', async ctx => {|" "$TMP_TEST_DIR/server.ts"
  rm -f "$TMP_TEST_DIR/server.ts.bak"
  run python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  [ "$status" -eq 0 ]
  [ "$(grep -c "agentic-pod-launcher: telegram voice roundtrip patch v3" "$TMP_TEST_DIR/server.ts")" -eq 0 ]
  grep -q "agentic-pod-launcher: offset persistence patch v1" "$TMP_TEST_DIR/server.ts"
  grep -q "agentic-pod-launcher: pending-reply marker patch v1" "$TMP_TEST_DIR/server.ts"
  grep -q "agentic-pod-launcher: askq-guard give-up delivery patch v1" "$TMP_TEST_DIR/server.ts"
}

@test "032 inbound: DM-only pre-check (incl. dmPolicy guard) appears before any fetch/getFile call" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  local dm_line file_line fetch_line
  dm_line=$(grep -n "access.dmPolicy !== 'disabled'" "$TMP_TEST_DIR/server.ts" | head -1 | cut -d: -f1)
  file_line=$(grep -n "ctx.api.getFile(voice.file_id)" "$TMP_TEST_DIR/server.ts" | head -1 | cut -d: -f1)
  fetch_line=$(grep -n "const res = await fetch(url" "$TMP_TEST_DIR/server.ts" | head -1 | cut -d: -f1)
  [ -n "$dm_line" ]
  [ "$dm_line" -lt "$file_line" ]
  [ "$dm_line" -lt "$fetch_line" ]
}

@test "032 inbound: pipeline is detached — void(async) scheduling, handler never awaits the STT helper" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  grep -q "void (async () => {" "$TMP_TEST_DIR/server.ts"
  local async_line transcribe_line
  async_line=$(grep -n "void (async () => {" "$TMP_TEST_DIR/server.ts" | head -1 | cut -d: -f1)
  transcribe_line=$(grep -n "await _voiceTranscribe(buf" "$TMP_TEST_DIR/server.ts" | head -1 | cut -d: -f1)
  [ "$transcribe_line" -gt "$async_line" ]
  # No top-level (handler-scope) await of the STT helper outside the IIFE.
  ! grep -qE "^  const transcript = await _voiceTranscribe" "$TMP_TEST_DIR/server.ts"
}

@test "032 inbound: typing action fires before the detached download+STT pipeline" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  local voice_start async_start
  voice_start=$(grep -n "^bot.on('message:voice'" "$TMP_TEST_DIR/server.ts" | head -1 | cut -d: -f1)
  async_start=$(grep -n "void (async () => {" "$TMP_TEST_DIR/server.ts" | head -1 | cut -d: -f1)
  local typing_lines l found
  typing_lines=$(grep -n "void bot.api.sendChatAction(chat_id, 'typing')" "$TMP_TEST_DIR/server.ts" | cut -d: -f1)
  found=0
  for l in $typing_lines; do
    if [ "$l" -gt "$voice_start" ] && [ "$l" -lt "$async_start" ]; then
      found=1
    fi
  done
  [ "$found" -eq 1 ]
}

@test "032 inbound: caps are absent-metadata-safe and the over-cap floor is distinguishable" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  grep -q "voice.duration && voice.duration > VOICE_MAX_NOTE_SECONDS" "$TMP_TEST_DIR/server.ts"
  grep -q "voice.file_size && voice.file_size > VOICE_MAX_BYTES" "$TMP_TEST_DIR/server.ts"
  grep -q "buf.length > VOICE_MAX_BYTES" "$TMP_TEST_DIR/server.ts"
  grep -q "voice stt skip: over-cap" "$TMP_TEST_DIR/server.ts"
  grep -q "(voice note over the transcription limit)" "$TMP_TEST_DIR/server.ts"
}

@test "032 inbound: every failure path converges on the placeholder call (fail-open floor)" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  # Exact count (mutation target): inactive, not-DM, duration-cap,
  # file_size-cap, post-download-cap, empty-transcript, and the generic
  # network/timeout catch — 7 call sites total. Dropping any one of them
  # (e.g. the catch block) must fail this test.
  local count
  count=$(grep -c "await placeholder(" "$TMP_TEST_DIR/server.ts")
  [ "$count" -eq 7 ]
  grep -q "ctx.message.caption ?? '(voice message)'" "$TMP_TEST_DIR/server.ts"
  # The generic network/timeout catch specifically must fall through to the
  # placeholder — not just swallow the error and go silent.
  grep -A 4 "^    } catch (err) {" "$TMP_TEST_DIR/server.ts" | grep -q "await placeholder()"
}

@test "032 inbound: stt failure lines never interpolate a raw error object or a URL" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  awk '/^bot\.on\(.message:voice./{f=1} f{print; if (/^\}\)$/) exit}' \
    "$TMP_TEST_DIR/server.ts" > "$TMP_TEST_DIR/voice_inbound_snippet.txt"
  run grep -q '${err}' "$TMP_TEST_DIR/voice_inbound_snippet.txt"
  [ "$status" -ne 0 ]
  run grep -q '${url}' "$TMP_TEST_DIR/voice_inbound_snippet.txt"
  [ "$status" -ne 0 ]
  # The handler legitimately builds a file/bot${TOKEN} URL for the getFile
  # download (never logged) — the real invariant is "never in a stderr line".
  [ "$(grep 'process.stderr.write' "$TMP_TEST_DIR/voice_inbound_snippet.txt" | grep -c 'file/bot')" -eq 0 ]
  grep -q 'voice stt fail: ${cls} status=${status}' "$TMP_TEST_DIR/voice_inbound_snippet.txt"
}

@test "032 inbound: the voice handler never calls sendMessage or ctx.reply — no transcript echo" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  awk '/^bot\.on\(.message:voice./{f=1} f{print; if (/^\}\)$/) exit}' \
    "$TMP_TEST_DIR/server.ts" > "$TMP_TEST_DIR/voice_inbound_snippet.txt"
  run grep -q 'sendMessage(' "$TMP_TEST_DIR/voice_inbound_snippet.txt"
  [ "$status" -ne 0 ]
  ! grep -q 'ctx.reply(' "$TMP_TEST_DIR/voice_inbound_snippet.txt"
}

@test "032 inbound: config/WARN line sits at module scope, before any bot.on handler" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  local config_line first_handler_line
  config_line=$(grep -n "voice active mode=" "$TMP_TEST_DIR/server.ts" | head -1 | cut -d: -f1)
  first_handler_line=$(grep -n "^bot.on(" "$TMP_TEST_DIR/server.ts" | head -1 | cut -d: -f1)
  [ -n "$config_line" ]
  [ "$config_line" -lt "$first_handler_line" ]
}

@test "032 inbound/V6: voice-origin is set only on success, cleared when a typed message arrives" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  local count
  count=$(grep -c "_voiceOriginSet(chat_id)" "$TMP_TEST_DIR/server.ts")
  [ "$count" -eq 1 ]
  local voice_start set_line
  voice_start=$(grep -n "^bot.on('message:voice'" "$TMP_TEST_DIR/server.ts" | head -1 | cut -d: -f1)
  set_line=$(grep -n "_voiceOriginSet(chat_id)" "$TMP_TEST_DIR/server.ts" | head -1 | cut -d: -f1)
  [ "$set_line" -gt "$voice_start" ]
  grep -q "_voiceOriginClear(String(ctx.chat!.id))" "$TMP_TEST_DIR/server.ts"
}

@test "032 inbound: typing cascade v1→…→v6 is unaffected by the voice group" {
  # Simulate an existing v4-patched agent, same technique as the 028/031 cascade test
  # (test "028/031: a v4-patched server.ts cascades through v5 all the way to v6").
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  perl -0pi -e 's/typing refresh patch v6/typing refresh patch v4/g; s/telegram-typing v6 — names interactive-prompt cause/telegram-typing v4 — anti-zombie/g' "$TMP_TEST_DIR/server.ts"
  perl -0pi -e 's/⚠️ Llevo más de \$\{minutes\} min sin entregar la respuesta a este chat\. Puede deberse a: una respuesta larga aún en curso, a que respondí sin usar la herramienta de envío, a que el login de Claude haya expirado, o a que la sesión quedó bloqueada en un menú interactivo que el canal no puede responder\. Revisa: agentctl doctor\./⚠️ Tardé más de \${minutes} min en responder. Es probable que el OAuth de Claude haya expirado o haya un error de conectividad. Revisa: agentctl doctor./g' "$TMP_TEST_DIR/server.ts"
  run python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  [ "$status" -eq 0 ]
  grep -q "typing refresh patch v6" "$TMP_TEST_DIR/server.ts"
  local voice_count
  voice_count=$(grep -c "agentic-pod-launcher: telegram voice roundtrip patch v3" "$TMP_TEST_DIR/server.ts")
  [ "$voice_count" -eq 1 ]
}

# ── 032 US2: reply → voice bubble (contracts/voice-outbound-tts.md) ──────────────

@test "032 outbound: voice block anchors AFTER the 028 marker-clear/offset-ack site, before return" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  local ack_line clear_line result_line consume_line return_line
  ack_line=$(grep -n "_ackPending(chat_id)" "$TMP_TEST_DIR/server.ts" | head -1 | cut -d: -f1)
  clear_line=$(grep -n "_clearPendingReply()" "$TMP_TEST_DIR/server.ts" | head -1 | cut -d: -f1)
  result_line=$(grep -n "        const result =" "$TMP_TEST_DIR/server.ts" | head -1 | cut -d: -f1)
  consume_line=$(grep -n "_voiceOriginConsume(chat_id)" "$TMP_TEST_DIR/server.ts" | head -1 | cut -d: -f1)
  return_line=$(grep -n "return { content: \[{ type: 'text', text: result + _voiceOutcome }\] }" "$TMP_TEST_DIR/server.ts" | head -1 | cut -d: -f1)
  [ "$ack_line" -lt "$result_line" ]
  [ "$clear_line" -lt "$result_line" ]
  [ "$result_line" -lt "$consume_line" ]
  [ "$consume_line" -lt "$return_line" ]
}

@test "032 outbound: consume-on-read — the origin flag is deleted before synthesis is attempted" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  local consume_line synth_line
  consume_line=$(grep -n "_voiceOriginConsume(chat_id)" "$TMP_TEST_DIR/server.ts" | head -1 | cut -d: -f1)
  synth_line=$(grep -n "await _voiceSynthesize(spoken" "$TMP_TEST_DIR/server.ts" | head -1 | cut -d: -f1)
  [ "$consume_line" -lt "$synth_line" ]
}

@test "034 US4: sentence cut + assembler replace the 032 truncation helper" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  [ "$(grep -cF "function _voiceSentenceCut(text: string, budget: number): { out: string; trimmed: boolean }" "$TMP_TEST_DIR/server.ts")" -eq 1 ]
  [ "$(grep -cF "function _voiceSpokenAssemble(raw: string): { spoken: string; narrated: string; trimmed: boolean }" "$TMP_TEST_DIR/server.ts")" -eq 1 ]
  grep -q "TELEGRAM_VOICE_SPOKEN_CHAR_CAP" "$TMP_TEST_DIR/server.ts"
  run grep -q "_voiceTruncate" "$TMP_TEST_DIR/server.ts"
  [ "$status" -ne 0 ]
}

@test "032 outbound: reply tool inputSchema gains the optional voice_text property" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  grep -A 3 "voice_text: {" "$TMP_TEST_DIR/server.ts" | grep -q "type: 'string'"
  local voice_text_line required_line
  voice_text_line=$(grep -n "voice_text: {" "$TMP_TEST_DIR/server.ts" | head -1 | cut -d: -f1)
  required_line=$(grep -n "        required: \['chat_id', 'text'\]," "$TMP_TEST_DIR/server.ts" | head -1 | cut -d: -f1)
  [ "$voice_text_line" -lt "$required_line" ]
}

@test "032 outbound: instructions array gains the voice-reply convention line" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  grep -A 2 "    instructions: \[" "$TMP_TEST_DIR/server.ts" | grep -q 'attachment_kind="voice"'
  grep -qF 'ALWAYS include voice_text: a spoken SUMMARY of your answer' "$TMP_TEST_DIR/server.ts"
}

@test "032 outbound: format strategy is OggS sniff with a single-budget mp3 fallback" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  grep -q "opus_48000_64" "$TMP_TEST_DIR/server.ts"
  grep -q "buf.toString('ascii', 0, 4) === 'OggS'" "$TMP_TEST_DIR/server.ts"
  grep -q "mp3_44100_128" "$TMP_TEST_DIR/server.ts"
  # One shared 30s deadline for the whole synthesis step (reply-block scoped).
  local voice_timer_count
  voice_timer_count=$(grep -c "_voiceTimer = setTimeout(() => _voiceController.abort(), 30000)" "$TMP_TEST_DIR/server.ts")
  [ "$voice_timer_count" -eq 1 ]
}

@test "032 outbound: sendVoice appears only in the patched voice group, never in the baseline" {
  run grep -q "sendVoice" "$TMP_TEST_DIR/server.ts"
  [ "$status" -ne 0 ]
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  local count
  count=$(grep -c "bot.api.sendVoice(chat_id" "$TMP_TEST_DIR/server.ts")
  [ "$count" -eq 1 ]
}

@test "032 outbound: a synthesis/send failure never throws — it logs and falls through to return" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  awk '/agentic-pod-launcher: voice roundtrip outbound synthesis/{f=1} f{print; if (/^        \}$/) exit}' \
    "$TMP_TEST_DIR/server.ts" > "$TMP_TEST_DIR/voice_outbound_snippet.txt"
  run grep -q '^\s*throw ' "$TMP_TEST_DIR/voice_outbound_snippet.txt"
  [ "$status" -ne 0 ]
  grep -q "voice tts fail: \${cls} status=\${status}" "$TMP_TEST_DIR/voice_outbound_snippet.txt"
  ! grep -q '${err}' "$TMP_TEST_DIR/voice_outbound_snippet.txt"
}

# ── 033: voice group v2 upgrade (contracts/voice-group-v2-upgrade.md C5) ──

@test "033 G1: fresh install lands v2 directly (marker, no v1, sentinel present)" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  [ "$(grep -c "agentic-pod-launcher: telegram voice roundtrip patch v3" "$TMP_TEST_DIR/server.ts")" -eq 1 ]
  [ "$(grep -c "agentic-pod-launcher: telegram voice roundtrip patch v2" "$TMP_TEST_DIR/server.ts")" -eq 0 ]
  [ "$(grep -c "agentic-pod-launcher: telegram voice roundtrip patch v1" "$TMP_TEST_DIR/server.ts")" -eq 0 ]
  [ "$(grep -c "voice helpers end (033)" "$TMP_TEST_DIR/server.ts")" -eq 1 ]
}

@test "033 G2: upgrading the golden v1 fixture converges byte-for-byte with a fresh v2 install" {
  cp "$REPO_ROOT/tests/fixtures/telegram-server-voice-v1.ts" "$TMP_TEST_DIR/golden.ts"
  python3 "$PATCHER" "$TMP_TEST_DIR/golden.ts"
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  local sha_golden sha_fresh
  sha_golden=$(shasum -a 256 "$TMP_TEST_DIR/golden.ts" | awk '{print $1}')
  sha_fresh=$(shasum -a 256 "$TMP_TEST_DIR/server.ts" | awk '{print $1}')
  [ "$sha_golden" = "$sha_fresh" ]
  [ "$(grep -c "agentic-pod-launcher: telegram voice roundtrip patch v3" "$TMP_TEST_DIR/golden.ts")" -eq 1 ]
}

@test "033 G2b: the patcher's _V1 twins are byte-faithful to the committed golden v1 fixture" {
  python3 -B - "$PATCHER" "$REPO_ROOT/tests/fixtures/telegram-server-voice-v1.ts" <<'PY'
import sys, os
sys.path.insert(0, os.path.dirname(sys.argv[1]))
import apply_telegram_typing_patch as p
golden = open(sys.argv[2]).read()
assert p.MARKER_VOICE_V1 in golden, "MARKER_VOICE_V1 not found in golden fixture"
assert p.VOICE_HELPERS_V1 in golden, "VOICE_HELPERS_V1 not found in golden fixture"
assert p.VOICE_TEXT_WRAP_V1 in golden, "VOICE_TEXT_WRAP_V1 not found in golden fixture"
assert (p.VOICE_REPLY_BLOCK_V1 + p._REPLY_RETURN_V1) in golden, "VOICE_REPLY_BLOCK_V1 + _REPLY_RETURN_V1 not found in golden fixture"
assert p.VOICE_SCHEMA_PROPERTY_V1 in golden, "VOICE_SCHEMA_PROPERTY_V1 not found in golden fixture"
assert p.VOICE_INSTRUCTIONS_LINE_V1 in golden, "VOICE_INSTRUCTIONS_LINE_V1 not found in golden fixture"
PY
}

@test "033 G2c: replacing v2 constants with their _V1 twins then re-patching converges back to the fresh v2 output" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  cp "$TMP_TEST_DIR/server.ts" "$TMP_TEST_DIR/roundtrip.ts"
  python3 -B - "$PATCHER" "$TMP_TEST_DIR/roundtrip.ts" <<'PY'
import sys, os
sys.path.insert(0, os.path.dirname(sys.argv[1]))
import apply_telegram_typing_patch as p
path = sys.argv[2]
src = open(path).read()
src = src.replace(p.VOICE_REPLY_BLOCK + p._REPLY_RETURN_V2, p.VOICE_REPLY_BLOCK_V1 + p._REPLY_RETURN_V1)
src = src.replace(p.VOICE_HELPERS, p.VOICE_HELPERS_V1)
src = src.replace(p.VOICE_TEXT_WRAP, p.VOICE_TEXT_WRAP_V1)
src = src.replace(p.VOICE_SCHEMA_PROPERTY, p.VOICE_SCHEMA_PROPERTY_V1)
src = src.replace(p.VOICE_INSTRUCTIONS_LINE, p.VOICE_INSTRUCTIONS_LINE_V1)
open(path, "w").write(src)
PY
  grep -q "agentic-pod-launcher: telegram voice roundtrip patch v1" "$TMP_TEST_DIR/roundtrip.ts"
  python3 "$PATCHER" "$TMP_TEST_DIR/roundtrip.ts"
  local sha_fresh sha_roundtrip
  sha_fresh=$(shasum -a 256 "$TMP_TEST_DIR/server.ts" | awk '{print $1}')
  sha_roundtrip=$(shasum -a 256 "$TMP_TEST_DIR/roundtrip.ts" | awk '{print $1}')
  [ "$sha_fresh" = "$sha_roundtrip" ]
}

@test "033 G3: a second patcher run on an already-v2 file is a byte-identical no-op (fresh and upgraded)" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  local sha1
  sha1=$(shasum -a 256 "$TMP_TEST_DIR/server.ts" | awk '{print $1}')
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  local sha2
  sha2=$(shasum -a 256 "$TMP_TEST_DIR/server.ts" | awk '{print $1}')
  [ "$sha1" = "$sha2" ]
  [ "$(grep -c "agentic-pod-launcher: telegram voice roundtrip patch v3" "$TMP_TEST_DIR/server.ts")" -eq 1 ]

  cp "$REPO_ROOT/tests/fixtures/telegram-server-voice-v1.ts" "$TMP_TEST_DIR/golden.ts"
  python3 "$PATCHER" "$TMP_TEST_DIR/golden.ts"
  local sha3
  sha3=$(shasum -a 256 "$TMP_TEST_DIR/golden.ts" | awk '{print $1}')
  python3 "$PATCHER" "$TMP_TEST_DIR/golden.ts"
  local sha4
  sha4=$(shasum -a 256 "$TMP_TEST_DIR/golden.ts" | awk '{print $1}')
  [ "$sha3" = "$sha4" ]
  [ "$(grep -c "agentic-pod-launcher: telegram voice roundtrip patch v3" "$TMP_TEST_DIR/golden.ts")" -eq 1 ]
}

@test "033 G4: out-of-band edit to the golden's instructions line blocks the upgrade; other six groups stay unaffected" {
  cp "$REPO_ROOT/tests/fixtures/telegram-server-voice-v1.ts" "$TMP_TEST_DIR/golden.ts"
  perl -0pi -e "s/include voice_text with a concise speakable version of your answer\\./include voice_text somehow./" "$TMP_TEST_DIR/golden.ts"
  run python3 "$PATCHER" "$TMP_TEST_DIR/golden.ts"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "voice v1→v2 upgrade: hunk 5 anchor not found"
  [ "$(grep -c "agentic-pod-launcher: telegram voice roundtrip patch v1" "$TMP_TEST_DIR/golden.ts")" -eq 1 ]
  [ "$(grep -c "agentic-pod-launcher: telegram voice roundtrip patch v2" "$TMP_TEST_DIR/golden.ts")" -eq 0 ]
  [ "$(grep -c "agentic-pod-launcher: telegram voice roundtrip patch v3" "$TMP_TEST_DIR/golden.ts")" -eq 0 ]
  [ "$(grep -c "voice_text: {" "$TMP_TEST_DIR/golden.ts")" -eq 1 ]
  grep -q "agentic-pod-launcher: offset persistence patch v1" "$TMP_TEST_DIR/golden.ts"
  grep -q "agentic-pod-launcher: pending-reply marker patch v1" "$TMP_TEST_DIR/golden.ts"
  grep -q "agentic-pod-launcher: stderr-capture patch v1" "$TMP_TEST_DIR/golden.ts"
  grep -q "agentic-pod-launcher: primary lock patch v1" "$TMP_TEST_DIR/golden.ts"
  grep -q "agentic-pod-launcher: askq-guard give-up delivery patch v1" "$TMP_TEST_DIR/golden.ts"
  grep -q "agentic-pod-launcher: typing refresh patch v6" "$TMP_TEST_DIR/golden.ts"
}

@test "033 G6: typing cascade v4→v6 and the voice v1→v2 upgrade both complete in a single pass" {
  cp "$REPO_ROOT/tests/fixtures/telegram-server-voice-v1.ts" "$TMP_TEST_DIR/golden.ts"
  perl -0pi -e 's/typing refresh patch v6/typing refresh patch v4/g; s/telegram-typing v6 — names interactive-prompt cause/telegram-typing v4 — anti-zombie/g' "$TMP_TEST_DIR/golden.ts"
  perl -0pi -e 's/⚠️ Llevo más de \$\{minutes\} min sin entregar la respuesta a este chat\. Puede deberse a: una respuesta larga aún en curso, a que respondí sin usar la herramienta de envío, a que el login de Claude haya expirado, o a que la sesión quedó bloqueada en un menú interactivo que el canal no puede responder\. Revisa: agentctl doctor\./⚠️ Tardé más de \${minutes} min en responder. Es probable que el OAuth de Claude haya expirado o haya un error de conectividad. Revisa: agentctl doctor./g' "$TMP_TEST_DIR/golden.ts"
  run python3 "$PATCHER" "$TMP_TEST_DIR/golden.ts"
  [ "$status" -eq 0 ]
  grep -q "typing refresh patch v6" "$TMP_TEST_DIR/golden.ts"
  [ "$(grep -c "agentic-pod-launcher: telegram voice roundtrip patch v3" "$TMP_TEST_DIR/golden.ts")" -eq 1 ]
  [ "$(grep -c "agentic-pod-launcher: telegram voice roundtrip patch v1" "$TMP_TEST_DIR/golden.ts")" -eq 0 ]
}

# ── 033 US1: reply acknowledgement carries the voice outcome (contracts/reply-voice-outcome.md C1-C4) ──

@test "033 US1(a): _voiceOutcome is declared right after the synthesis comment, before the voice gate, and fed into the return" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  local comment_line let_line if_line return_line
  comment_line=$(grep -n "agentic-pod-launcher: voice roundtrip outbound synthesis" "$TMP_TEST_DIR/server.ts" | head -1 | cut -d: -f1)
  let_line=$(grep -n "let _voiceOutcome = ''" "$TMP_TEST_DIR/server.ts" | head -1 | cut -d: -f1)
  if_line=$(grep -n "if (VOICE_ACTIVE && VOICE_REPLY_MODE !== 'never')" "$TMP_TEST_DIR/server.ts" | head -1 | cut -d: -f1)
  return_line=$(grep -n "return { content: \[{ type: 'text', text: result + _voiceOutcome }\] }" "$TMP_TEST_DIR/server.ts" | head -1 | cut -d: -f1)
  [ -n "$let_line" ]
  [ "$comment_line" -lt "$let_line" ]
  [ "$let_line" -lt "$if_line" ]
  [ "$if_line" -lt "$return_line" ]
}

@test "033 US1(b): the outcome assignments match the exact sent/failed templates" {
  # The `\n` is a JS escape INSIDE the template literal (becomes a real
  # newline only when the TS runs) — the source line itself is single-line,
  # same convention as every other stderr.write(...\n) call in this file.
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  grep -qF '_voiceOutcome = `\nvoice: sent (fmt=${fmt}, chars=${spoken.length}, ms=${_voiceMs})`' "$TMP_TEST_DIR/server.ts"
  grep -qF '_voiceOutcome = `\nvoice: failed (step=${_voiceStep}, cls=${cls}, status=${status})`' "$TMP_TEST_DIR/server.ts"
}

@test "033 US1(c): the step marker flips to send between synthesis and the Telegram call; the fail line names it" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  local synth_line step_line send_line
  synth_line=$(grep -n "await _voiceSynthesize(spoken" "$TMP_TEST_DIR/server.ts" | head -1 | cut -d: -f1)
  step_line=$(grep -n "_voiceStep = 'send'" "$TMP_TEST_DIR/server.ts" | head -1 | cut -d: -f1)
  send_line=$(grep -n "bot.api.sendVoice(chat_id" "$TMP_TEST_DIR/server.ts" | head -1 | cut -d: -f1)
  [ -n "$step_line" ]
  [ "$synth_line" -lt "$step_line" ]
  [ "$step_line" -lt "$send_line" ]
  grep -qF 'telegram channel: voice tts fail: ${cls} status=${status} step=${_voiceStep} chat=${chat_id}' "$TMP_TEST_DIR/server.ts"
}

@test "033 US1(d): sendVoice passes the synthesis AbortController's signal (grammY confirmed, research D3)" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  grep -qF 'bot.api.sendVoice(chat_id, new InputFile(buf, `voice.${fmt}`), undefined, _voiceController.signal)' "$TMP_TEST_DIR/server.ts"
}

@test "033 US1(e): the outcome/reply block never leaks a raw error, a URL, the spoken text, the voice id, or a file/bot path" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  awk '/agentic-pod-launcher: voice roundtrip outbound synthesis/{f=1} f{print; if (/^        return \{ content/) exit}' \
    "$TMP_TEST_DIR/server.ts" > "$TMP_TEST_DIR/voice_reply_block.txt"
  run grep -q '${err}' "$TMP_TEST_DIR/voice_reply_block.txt"
  [ "$status" -ne 0 ]
  run grep -q '${url}' "$TMP_TEST_DIR/voice_reply_block.txt"
  [ "$status" -ne 0 ]
  run grep -q '${spoken}' "$TMP_TEST_DIR/voice_reply_block.txt"
  [ "$status" -ne 0 ]
  run grep -q '${text}' "$TMP_TEST_DIR/voice_reply_block.txt"
  [ "$status" -ne 0 ]
  run grep -q '${VOICE_ID}' "$TMP_TEST_DIR/voice_reply_block.txt"
  [ "$status" -ne 0 ]
  run grep -q 'file/bot' "$TMP_TEST_DIR/voice_reply_block.txt"
  [ "$status" -ne 0 ]
}

@test "033 US1(f): _voiceErrClass reads a grammY error_code null-safely" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  grep -qF "typeof err === 'object' && err !== null && typeof (err as { error_code?: unknown }).error_code === 'number'" "$TMP_TEST_DIR/server.ts"
}

@test "033 US1(g): byte-identity guard — exactly two _voiceOutcome assignments (the let declaration and any nag += are excluded)" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  [ "$(grep -cE '^ *_voiceOutcome = ' "$TMP_TEST_DIR/server.ts")" -eq 2 ]
}

# ── 033 US2: contract wording v2 (contracts/reply-voice-outcome.md C5) ──

@test "033 US2: the instructions line and voice_text description state the v2 facts, on a fresh install and on the upgraded golden" {
  cp "$REPO_ROOT/tests/fixtures/telegram-server-voice-v1.ts" "$TMP_TEST_DIR/golden.ts"
  python3 "$PATCHER" "$TMP_TEST_DIR/golden.ts"
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  local f
  for f in "$TMP_TEST_DIR/golden.ts" "$TMP_TEST_DIR/server.ts"; do
    grep -qF 'AUTOMATICALLY sends your reply as a voice note too' "$f"
    grep -qF 'explicitly asks for an audio reply' "$f"
    grep -qF 'never tell the user you cannot send audio' "$f"
    grep -qF 'answer in ONE reply call' "$f"
    grep -qF 'ALWAYS include voice_text: a spoken SUMMARY of your answer' "$f"
    grep -qF 'a cleaned, sentence-cut version of your text is read aloud and the reply result says so' "$f"
    grep -qF 'do not repeat it to the user' "$f"
    grep -qF 'tell the user once, briefly, that the audio did not go out this time' "$f"
    grep -qF 'set voice_force: true on that reply' "$f"
    grep -A 2 "    instructions: \[" "$f" | grep -q 'attachment_kind="voice"'
    [ "$(grep -c 'arrive transcribed — the message text IS the transcription. When replying to them, include voice_text' "$f")" -eq 0 ]
    grep -qF 'voice note or explicit audio request' "$f"
    grep -qF 'cleaned, sentence-cut version of `text` is read aloud' "$f"
    grep -qF 'reports the omission' "$f"
  done
}

# ── 033 US3: omission observability (research D4) ──

@test "033 US3: stderr record nested under _voiceFromText, nag gated by the derived threshold" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  grep -qF 'const _voiceFromText = !(voiceTextArg && voiceTextArg.trim())' "$TMP_TEST_DIR/server.ts"
  awk '/agentic-pod-launcher: voice roundtrip outbound synthesis/{f=1} f{print; if (/^        return \{ content/) exit}' \
    "$TMP_TEST_DIR/server.ts" > "$TMP_TEST_DIR/voice_reply_block.txt"
  local sent_line fromtext_if_line omission_line nag_if_line nag_append_line catch_line
  sent_line=$(grep -n 'voice: sent' "$TMP_TEST_DIR/voice_reply_block.txt" | head -1 | cut -d: -f1)
  fromtext_if_line=$(grep -n 'if (_voiceFromText) {' "$TMP_TEST_DIR/voice_reply_block.txt" | head -1 | cut -d: -f1)
  omission_line=$(grep -n 'voice tts spoke ${_voiceAsm.narrated.length} chars without voice_text' "$TMP_TEST_DIR/voice_reply_block.txt" | head -1 | cut -d: -f1)
  nag_if_line=$(grep -n 'if (_voiceAsm.narrated.length > VOICE_OMISSION_NAG_CHARS)' "$TMP_TEST_DIR/voice_reply_block.txt" | head -1 | cut -d: -f1)
  nag_append_line=$(grep -n 'voice_text omitted' "$TMP_TEST_DIR/voice_reply_block.txt" | head -1 | cut -d: -f1)
  catch_line=$(grep -n '} catch (err) {' "$TMP_TEST_DIR/voice_reply_block.txt" | head -1 | cut -d: -f1)
  [ -n "$fromtext_if_line" ] && [ -n "$omission_line" ] && [ -n "$nag_if_line" ] && [ -n "$nag_append_line" ] && [ -n "$catch_line" ]
  [ "$sent_line" -lt "$fromtext_if_line" ]
  [ "$fromtext_if_line" -lt "$omission_line" ]
  [ "$omission_line" -lt "$nag_if_line" ]
  [ "$nag_if_line" -lt "$nag_append_line" ]
  [ "$nag_append_line" -lt "$catch_line" ]
  grep -qF 'const VOICE_OMISSION_NAG_CHARS = Math.floor(VOICE_SPOKEN_CHAR_CAP / 4)' "$TMP_TEST_DIR/server.ts"
  [ "$(grep -c '> 300' "$TMP_TEST_DIR/server.ts")" -eq 0 ]
  [ "$(grep -c 'process.env.TELEGRAM_VOICE_OMISSION' "$TMP_TEST_DIR/server.ts")" -eq 0 ]
}

# ── 033 US4: explicit audio request — matcher (contracts/explicit-audio-request.md C1) ──

@test "033 US4(a): the fixed phrase table declares all 23 Spanish and 15 English request forms" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  grep -qF 'const VOICE_REQUEST_PHRASES: readonly string[] = [' "$TMP_TEST_DIR/server.ts"
  local phrase
  for phrase in \
    "responde con audio" "respondeme con audio" "responde en audio" "respondeme en audio" \
    "responde por audio" "respondeme por audio" "contesta con audio" "contestame con audio" \
    "contesta en audio" "contestame en audio" "contesta por audio" "contestame por audio" \
    "responde con voz" "respondeme con voz" "contesta con voz" "responde con una nota de voz" \
    "mandame un audio" "mandame audio" "mandame una nota de voz" "enviame un audio" \
    "enviame una nota de voz" "responde hablando" "respondeme hablando" \
    "reply with audio" "respond with audio" "answer with audio" "reply with voice" \
    "respond with voice" "answer with voice" "reply in audio" "respond in audio" \
    "answer in audio" "send me an audio" "send me a voice note" "send me a voice message" \
    "send a voice note" "reply with a voice note" "reply with a voice message"; do
    grep -qF "'$phrase'" "$TMP_TEST_DIR/server.ts"
  done
}

@test "033 US4(b): the normaliser strips combining marks and typographic quotes as escape sequences, not glyphs" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  grep -qF "function _voiceNormalize(" "$TMP_TEST_DIR/server.ts"
  grep -qF ".normalize('NFD')" "$TMP_TEST_DIR/server.ts"
  grep -qF '[\u0300-\u036f]' "$TMP_TEST_DIR/server.ts"
  grep -qF '[\u2018\u2019\u02bc\u00b4\`]' "$TMP_TEST_DIR/server.ts"
  grep -qF '.toLowerCase()' "$TMP_TEST_DIR/server.ts"
}

@test "033 US4(c): the matcher scans every occurrence with a word-boundary and negation guard" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  grep -qF "function _voiceRequestMatch(" "$TMP_TEST_DIR/server.ts"
  grep -qF 't.indexOf(p)' "$TMP_TEST_DIR/server.ts"
  grep -qF 't.indexOf(p, i + 1)' "$TMP_TEST_DIR/server.ts"
  grep -qF '[a-z0-9]' "$TMP_TEST_DIR/server.ts"
  grep -qF '_VOICE_REQUEST_NEGATION.test(t.slice(0, i))' "$TMP_TEST_DIR/server.ts"
}

@test "033 US4(d): the negation regex matches the contract verbatim" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  grep -qF "const _VOICE_REQUEST_NEGATION = /(?:^|[\s,;:—-])(?:no|nunca|jamas|sin|don't|dont|do not|never|stop)\b[^.!?\n]{0,30}\$/" "$TMP_TEST_DIR/server.ts"
}

@test "033 US4(e): the sentinel closes the helpers block after every voice helper and before the first bot.on handler" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  local sentinel_line first_bot_on_line
  sentinel_line=$(grep -n "voice helpers end (033)" "$TMP_TEST_DIR/server.ts" | head -1 | cut -d: -f1)
  first_bot_on_line=$(grep -n "^bot\.on(" "$TMP_TEST_DIR/server.ts" | head -1 | cut -d: -f1)
  local last_helper_line
  last_helper_line=$(grep -n "function _voiceRequestMatch\|function _voiceCooldownConsume\|function _voiceNormalize\|function _voiceSpokenNormalize\|function _voiceSentenceCut\|function _voiceKey\|function _voiceSignoffStrip\|function _voiceSignoffAppend\|function _voiceSpokenAssemble" "$TMP_TEST_DIR/server.ts" | tail -1 | cut -d: -f1)
  [ -n "$sentinel_line" ] && [ -n "$first_bot_on_line" ] && [ -n "$last_helper_line" ]
  [ "$last_helper_line" -lt "$sentinel_line" ]
  [ "$sentinel_line" -lt "$first_bot_on_line" ]
}

@test "033 US4(f) / G11: backslash literals reach the TS output (research D10)" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  grep -qF '[\u0300' "$TMP_TEST_DIR/server.ts"
  grep -qF '\s+' "$TMP_TEST_DIR/server.ts"
}

# ── 033 US4: wrap gating, voice_force, cooldown (contracts/explicit-audio-request.md C2/C3, reply-voice-outcome.md C7) ──

@test "033 US4(g): the message:text wrap gates the request match behind the full 032 DM gate, in order" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  awk '/^bot\.on\(.message:text./{f=1} f{print; if (/^\}\)$/) exit}' \
    "$TMP_TEST_DIR/server.ts" > "$TMP_TEST_DIR/voice_text_wrap.txt"
  grep -qF '_voiceOriginClear(String(ctx.chat!.id))' "$TMP_TEST_DIR/voice_text_wrap.txt"
  grep -qF 'const access = loadAccess()' "$TMP_TEST_DIR/voice_text_wrap.txt"
  grep -qF "ctx.chat?.type === 'private'" "$TMP_TEST_DIR/voice_text_wrap.txt"
  grep -qF "access.dmPolicy !== 'disabled'" "$TMP_TEST_DIR/voice_text_wrap.txt"
  grep -qF 'ctx.from != null' "$TMP_TEST_DIR/voice_text_wrap.txt"
  grep -qF 'access.allowFrom.includes(String(ctx.from.id))' "$TMP_TEST_DIR/voice_text_wrap.txt"
  grep -qF "if (VOICE_ACTIVE && VOICE_REPLY_MODE !== 'never' && isDm && _voiceRequestMatch(ctx.message.text))" "$TMP_TEST_DIR/voice_text_wrap.txt"
  grep -qF '_voiceOriginSet(String(ctx.chat!.id))' "$TMP_TEST_DIR/voice_text_wrap.txt"
  grep -qF 'telegram channel: voice request detected chat=' "$TMP_TEST_DIR/voice_text_wrap.txt"
  grep -qF 'await handleInbound(ctx, ctx.message.text, undefined)' "$TMP_TEST_DIR/voice_text_wrap.txt"
  local clear_line access_line if_line set_line stderr_line handle_line
  clear_line=$(grep -n '_voiceOriginClear' "$TMP_TEST_DIR/voice_text_wrap.txt" | head -1 | cut -d: -f1)
  access_line=$(grep -n 'const access = loadAccess()' "$TMP_TEST_DIR/voice_text_wrap.txt" | head -1 | cut -d: -f1)
  if_line=$(grep -n '_voiceRequestMatch(ctx.message.text)' "$TMP_TEST_DIR/voice_text_wrap.txt" | head -1 | cut -d: -f1)
  set_line=$(grep -n '_voiceOriginSet(String(ctx.chat!.id))' "$TMP_TEST_DIR/voice_text_wrap.txt" | head -1 | cut -d: -f1)
  stderr_line=$(grep -n 'voice request detected' "$TMP_TEST_DIR/voice_text_wrap.txt" | head -1 | cut -d: -f1)
  handle_line=$(grep -n 'await handleInbound' "$TMP_TEST_DIR/voice_text_wrap.txt" | head -1 | cut -d: -f1)
  [ "$clear_line" -lt "$access_line" ]
  [ "$access_line" -lt "$if_line" ]
  [ "$if_line" -lt "$set_line" ]
  [ "$set_line" -lt "$stderr_line" ]
  [ "$stderr_line" -lt "$handle_line" ]
  [ "$(grep -c 'const chat_id' "$TMP_TEST_DIR/voice_text_wrap.txt")" -eq 0 ]
}

@test "033 US4(h): _voiceOriginSet(chat_id) still occurs exactly once (032 oracle preserved)" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  [ "$(grep -c '_voiceOriginSet(chat_id)' "$TMP_TEST_DIR/server.ts")" -eq 1 ]
}

@test "033 US4(i): voice_force is added to the reply schema after voice_text, before required" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  grep -qF "voice_force: {" "$TMP_TEST_DIR/server.ts"
  grep -qF "Set ONLY when the user asked for an audio reply in wording the channel did not recognise" "$TMP_TEST_DIR/server.ts"
  local voice_text_line voice_force_line required_line
  voice_text_line=$(grep -n "voice_text: {" "$TMP_TEST_DIR/server.ts" | head -1 | cut -d: -f1)
  voice_force_line=$(grep -n "voice_force: {" "$TMP_TEST_DIR/server.ts" | head -1 | cut -d: -f1)
  required_line=$(grep -n "        required: \['chat_id', 'text'\]," "$TMP_TEST_DIR/server.ts" | head -1 | cut -d: -f1)
  [ "$voice_text_line" -lt "$voice_force_line" ]
  [ "$voice_force_line" -lt "$required_line" ]
}

@test "033 US4(j): voice_force is read strictly and is a third trigger alongside mode always / fresh origin" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  grep -qF "const _voiceForce = args.voice_force === true" "$TMP_TEST_DIR/server.ts"
  grep -qF "if (VOICE_REPLY_MODE === 'always' || _voiceFresh || _voiceForce)" "$TMP_TEST_DIR/server.ts"
  [ "$(grep -c 'Boolean(args.voice_force)' "$TMP_TEST_DIR/server.ts")" -eq 0 ]
}

@test "033 US4(k): a failure in mode always sets a one-shot cooldown, consumed before the next synthesis" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  grep -qF "const _voiceCooldown = new Map<string, number>()" "$TMP_TEST_DIR/server.ts"
  grep -qF "function _voiceCooldownConsume(chatId: string): boolean" "$TMP_TEST_DIR/server.ts"
  grep -qF "_VOICE_ORIGIN_TTL_MS" "$TMP_TEST_DIR/server.ts"
  awk '/agentic-pod-launcher: voice roundtrip outbound synthesis/{f=1} f{print; if (/^        return \{ content/) exit}' \
    "$TMP_TEST_DIR/server.ts" > "$TMP_TEST_DIR/voice_reply_block.txt"
  grep -qF "if (VOICE_REPLY_MODE === 'always') _voiceCooldown.set(chat_id, Date.now())" "$TMP_TEST_DIR/voice_reply_block.txt"
  grep -qF "if (VOICE_REPLY_MODE === 'always' && _voiceCooldownConsume(chat_id))" "$TMP_TEST_DIR/voice_reply_block.txt"
  grep -qF "telegram channel: voice skip: cooldown after failure chat=" "$TMP_TEST_DIR/voice_reply_block.txt"
  local skip_line synth_line set_line catch_line
  skip_line=$(grep -n "_voiceCooldownConsume(chat_id)" "$TMP_TEST_DIR/voice_reply_block.txt" | head -1 | cut -d: -f1)
  synth_line=$(grep -n "await _voiceSynthesize(spoken" "$TMP_TEST_DIR/voice_reply_block.txt" | head -1 | cut -d: -f1)
  catch_line=$(grep -n '} catch (err) {' "$TMP_TEST_DIR/voice_reply_block.txt" | head -1 | cut -d: -f1)
  set_line=$(grep -n "_voiceCooldown.set(chat_id, Date.now())" "$TMP_TEST_DIR/voice_reply_block.txt" | head -1 | cut -d: -f1)
  [ "$skip_line" -lt "$synth_line" ]
  [ "$catch_line" -lt "$set_line" ]
}

@test "033 US1(h): FR-008 — both outcome assignments live inside the try/catch, none after the finally" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  awk '/agentic-pod-launcher: voice roundtrip outbound synthesis/{f=1} f{print; if (/^        return \{ content/) exit}' \
    "$TMP_TEST_DIR/server.ts" > "$TMP_TEST_DIR/voice_reply_block.txt"
  local try_line sent_line catch_line failed_line finally_line
  try_line=$(grep -n '^ *try {$' "$TMP_TEST_DIR/voice_reply_block.txt" | head -1 | cut -d: -f1)
  sent_line=$(grep -n 'voice: sent' "$TMP_TEST_DIR/voice_reply_block.txt" | head -1 | cut -d: -f1)
  catch_line=$(grep -n '} catch (err)' "$TMP_TEST_DIR/voice_reply_block.txt" | head -1 | cut -d: -f1)
  failed_line=$(grep -n 'voice: failed' "$TMP_TEST_DIR/voice_reply_block.txt" | head -1 | cut -d: -f1)
  finally_line=$(grep -n '} finally {' "$TMP_TEST_DIR/voice_reply_block.txt" | head -1 | cut -d: -f1)
  [ -n "$try_line" ] && [ -n "$sent_line" ] && [ -n "$catch_line" ] && [ -n "$failed_line" ] && [ -n "$finally_line" ]
  [ "$try_line" -lt "$sent_line" ]
  [ "$sent_line" -lt "$catch_line" ]
  [ "$catch_line" -lt "$failed_line" ]
  [ "$failed_line" -lt "$finally_line" ]
  # The extracted snippet's last line is the case's `return` statement,
  # which legitimately references _voiceOutcome (FR-002) — exclude it; the
  # check is "no THIRD assignment sneaks in after finally".
  [ "$(awk -v n="$finally_line" 'NR>n' "$TMP_TEST_DIR/voice_reply_block.txt" | grep -v 'return { content' | grep -c '_voiceOutcome')" -eq 0 ]
}

# ── 034: voice group v3 upgrade (contracts/voice-group-v3-upgrade.md C6) ──
#
# Golden v2 fixture = tests/fixtures/telegram-server-voice-v2.ts, generated ONCE
# by the real v0.24.0 patcher (main @ 3534c6b) over the pristine fixture
# (research D11, sha 5dc01bf3…cef0). Never regenerated by a test.

@test "034 G1: fresh install lands v3 directly (marker v3 once, no v2, no v1, seven groups, sentinel)" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  [ "$(grep -c "agentic-pod-launcher: telegram voice roundtrip patch v3" "$TMP_TEST_DIR/server.ts")" -eq 1 ]
  [ "$(grep -c "agentic-pod-launcher: telegram voice roundtrip patch v2" "$TMP_TEST_DIR/server.ts")" -eq 0 ]
  [ "$(grep -c "agentic-pod-launcher: telegram voice roundtrip patch v1" "$TMP_TEST_DIR/server.ts")" -eq 0 ]
  [ "$(grep -c "voice helpers end (033)" "$TMP_TEST_DIR/server.ts")" -eq 1 ]
  grep -q "agentic-pod-launcher: typing refresh patch v6" "$TMP_TEST_DIR/server.ts"
  grep -q "agentic-pod-launcher: offset persistence patch v1" "$TMP_TEST_DIR/server.ts"
  grep -q "agentic-pod-launcher: stderr-capture patch v1" "$TMP_TEST_DIR/server.ts"
  grep -q "agentic-pod-launcher: primary lock patch v1" "$TMP_TEST_DIR/server.ts"
  grep -q "agentic-pod-launcher: pending-reply marker patch v1" "$TMP_TEST_DIR/server.ts"
  grep -q "agentic-pod-launcher: askq-guard give-up delivery patch v1" "$TMP_TEST_DIR/server.ts"
}

@test "034 G2: upgrading the golden v2 fixture converges byte-for-byte with a fresh v3 install" {
  cp "$REPO_ROOT/tests/fixtures/telegram-server-voice-v2.ts" "$TMP_TEST_DIR/golden2.ts"
  python3 "$PATCHER" "$TMP_TEST_DIR/golden2.ts"
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  local sha_golden sha_fresh
  sha_golden=$(shasum -a 256 "$TMP_TEST_DIR/golden2.ts" | awk '{print $1}')
  sha_fresh=$(shasum -a 256 "$TMP_TEST_DIR/server.ts" | awk '{print $1}')
  [ "$sha_golden" = "$sha_fresh" ]
  [ "$(grep -c "agentic-pod-launcher: telegram voice roundtrip patch v3" "$TMP_TEST_DIR/golden2.ts")" -eq 1 ]
}

@test "034 G2b: the patcher's _V2 twins are byte-faithful to the committed golden v2 fixture (anti-tautology guards)" {
  python3 -B - "$PATCHER" "$REPO_ROOT/tests/fixtures/telegram-server-voice-v2.ts" <<'PY'
import sys, os
sys.path.insert(0, os.path.dirname(sys.argv[1]))
import apply_telegram_typing_patch as p
golden = open(sys.argv[2]).read()
assert p.MARKER_VOICE_V2 in golden, "MARKER_VOICE_V2 not found in golden v2 fixture"
assert p.VOICE_HELPERS_V2 in golden, "VOICE_HELPERS_V2 not found in golden v2 fixture"
assert (p.VOICE_REPLY_BLOCK_V2 + p._REPLY_RETURN_V2) in golden, "VOICE_REPLY_BLOCK_V2 + _REPLY_RETURN_V2 not found in golden v2 fixture"
assert p.VOICE_SCHEMA_PROPERTY_V2 in golden, "VOICE_SCHEMA_PROPERTY_V2 not found in golden v2 fixture"
assert p.VOICE_INSTRUCTIONS_LINE_V2 in golden, "VOICE_INSTRUCTIONS_LINE_V2 not found in golden v2 fixture"
# anti-tautology: the live helpers must differ from the frozen twin, and the
# twin must carry the v2 marker text (a copy built with the v3 marker would
# still be "in golden"-false, but this pins the intent).
assert p.VOICE_HELPERS_V2 != p.VOICE_HELPERS, "VOICE_HELPERS_V2 is identical to the live VOICE_HELPERS"
assert p.MARKER_VOICE_V2 in p.VOICE_HELPERS_V2, "VOICE_HELPERS_V2 does not carry the v2 marker"
PY
}

@test "034 G2c: the golden v1 fixture cascades v1→v2→v3 and converges byte-for-byte with a fresh v3 install" {
  cp "$REPO_ROOT/tests/fixtures/telegram-server-voice-v1.ts" "$TMP_TEST_DIR/golden1.ts"
  python3 "$PATCHER" "$TMP_TEST_DIR/golden1.ts"
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  local sha_golden sha_fresh
  sha_golden=$(shasum -a 256 "$TMP_TEST_DIR/golden1.ts" | awk '{print $1}')
  sha_fresh=$(shasum -a 256 "$TMP_TEST_DIR/server.ts" | awk '{print $1}')
  [ "$sha_golden" = "$sha_fresh" ]
  [ "$(grep -c "agentic-pod-launcher: telegram voice roundtrip patch v3" "$TMP_TEST_DIR/golden1.ts")" -eq 1 ]
  [ "$(grep -c "agentic-pod-launcher: telegram voice roundtrip patch v2" "$TMP_TEST_DIR/golden1.ts")" -eq 0 ]
  [ "$(grep -c "agentic-pod-launcher: telegram voice roundtrip patch v1" "$TMP_TEST_DIR/golden1.ts")" -eq 0 ]
}

@test "034 G2d: intermediate state — v1→v2 yields exactly the golden v2, v2→v3 yields exactly the fresh v3 (upgraders run separately)" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  python3 -B - "$PATCHER" "$REPO_ROOT/tests/fixtures/telegram-server-voice-v1.ts" "$REPO_ROOT/tests/fixtures/telegram-server-voice-v2.ts" "$TMP_TEST_DIR/server.ts" <<'PY'
import sys, os
sys.path.insert(0, os.path.dirname(sys.argv[1]))
import apply_telegram_typing_patch as p
golden1 = open(sys.argv[2]).read()
golden2 = open(sys.argv[3]).read()
fresh3 = open(sys.argv[4]).read()
out12, ok12 = p.upgrade_voice_v1_to_v2(golden1)
assert ok12, "upgrade_voice_v1_to_v2 refused the golden v1"
assert out12 == golden2, "upgrade_voice_v1_to_v2(golden v1) != golden v2 (the re-pointed v1→v2 does not reproduce v0.24.0 output)"
out23, ok23 = p.upgrade_voice_v2_to_v3(golden2)
assert ok23, "upgrade_voice_v2_to_v3 refused the golden v2"
assert out23 == fresh3, "upgrade_voice_v2_to_v3(golden v2) != fresh v3 install"
assert p.VOICE_HELPERS_V2 != p.VOICE_HELPERS
assert p.MARKER_VOICE_V2 in p.VOICE_HELPERS_V2
PY
}

@test "034 G3: a second patcher run on an already-v3 file is a byte-identical no-op that logs the truthful no-change line (fresh and upgraded)" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  local sha1
  sha1=$(shasum -a 256 "$TMP_TEST_DIR/server.ts" | awk '{print $1}')
  run python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'all patch groups already present'
  local sha2
  sha2=$(shasum -a 256 "$TMP_TEST_DIR/server.ts" | awk '{print $1}')
  [ "$sha1" = "$sha2" ]
  [ "$(grep -c "agentic-pod-launcher: telegram voice roundtrip patch v3" "$TMP_TEST_DIR/server.ts")" -eq 1 ]

  cp "$REPO_ROOT/tests/fixtures/telegram-server-voice-v2.ts" "$TMP_TEST_DIR/golden2.ts"
  python3 "$PATCHER" "$TMP_TEST_DIR/golden2.ts"
  local sha3
  sha3=$(shasum -a 256 "$TMP_TEST_DIR/golden2.ts" | awk '{print $1}')
  run python3 "$PATCHER" "$TMP_TEST_DIR/golden2.ts"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'all patch groups already present'
  local sha4
  sha4=$(shasum -a 256 "$TMP_TEST_DIR/golden2.ts" | awk '{print $1}')
  [ "$sha3" = "$sha4" ]
  [ "$(grep -c "agentic-pod-launcher: telegram voice roundtrip patch v3" "$TMP_TEST_DIR/golden2.ts")" -eq 1 ]
}

@test "034 G4: out-of-band edit to a v2 constant in the golden v2 blocks the v2→v3 upgrade; file stays v2, other six groups unaffected" {
  cp "$REPO_ROOT/tests/fixtures/telegram-server-voice-v2.ts" "$TMP_TEST_DIR/golden2.ts"
  # Mutate ONE line of the frozen VOICE_HELPERS_V2 text (the 033 derived threshold).
  perl -0pi -e 's/const VOICE_OMISSION_NAG_CHARS = Math\.floor\(VOICE_SPOKEN_CHAR_CAP \/ 4\)/const VOICE_OMISSION_NAG_CHARS = 300/' "$TMP_TEST_DIR/golden2.ts"
  grep -qF 'const VOICE_OMISSION_NAG_CHARS = 300' "$TMP_TEST_DIR/golden2.ts"
  run python3 "$PATCHER" "$TMP_TEST_DIR/golden2.ts"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'voice v2→v3 upgrade'
  [ "$(grep -c "agentic-pod-launcher: telegram voice roundtrip patch v2" "$TMP_TEST_DIR/golden2.ts")" -eq 1 ]
  [ "$(grep -c "agentic-pod-launcher: telegram voice roundtrip patch v3" "$TMP_TEST_DIR/golden2.ts")" -eq 0 ]
  [ "$(grep -c "voice_text: {" "$TMP_TEST_DIR/golden2.ts")" -eq 1 ]
  # ALL-OR-NOTHING (quickstart M6 caught this oracle as blind, 2026-09-18): the
  # marker lives in the helpers pair, so a partial upgrade that skips the missing
  # pair and applies the other three would still leave `patch v2` = 1 / `patch v3`
  # = 0 and still print the WARN. Assert that NONE of the other three v3
  # constants landed and the v2 text is still in place.
  [ "$(grep -cF 'ALWAYS include voice_text: a spoken SUMMARY' "$TMP_TEST_DIR/golden2.ts" || true)" -eq 0 ]
  [ "$(grep -cF 'Spoken SUMMARY of this reply' "$TMP_TEST_DIR/golden2.ts" || true)" -eq 0 ]
  [ "$(grep -cF '_voiceSpokenAssemble(' "$TMP_TEST_DIR/golden2.ts" || true)" -eq 0 ]
  grep -qF 'include voice_text with a concise speakable version' "$TMP_TEST_DIR/golden2.ts"
  grep -qF '_voiceTruncate(text, VOICE_SPOKEN_CHAR_CAP)' "$TMP_TEST_DIR/golden2.ts"
  grep -q "agentic-pod-launcher: offset persistence patch v1" "$TMP_TEST_DIR/golden2.ts"
  grep -q "agentic-pod-launcher: pending-reply marker patch v1" "$TMP_TEST_DIR/golden2.ts"
  grep -q "agentic-pod-launcher: stderr-capture patch v1" "$TMP_TEST_DIR/golden2.ts"
  grep -q "agentic-pod-launcher: primary lock patch v1" "$TMP_TEST_DIR/golden2.ts"
  grep -q "agentic-pod-launcher: askq-guard give-up delivery patch v1" "$TMP_TEST_DIR/golden2.ts"
  grep -q "agentic-pod-launcher: typing refresh patch v6" "$TMP_TEST_DIR/golden2.ts"
}

@test "034 G5: apply_voice never double-inserts — re-running on fresh v3, upgraded v1 and upgraded v2 keeps every voice marker and voice_text at exactly one" {
  cp "$REPO_ROOT/tests/fixtures/telegram-server-voice-v1.ts" "$TMP_TEST_DIR/golden1.ts"
  cp "$REPO_ROOT/tests/fixtures/telegram-server-voice-v2.ts" "$TMP_TEST_DIR/golden2.ts"
  local f
  for f in "$TMP_TEST_DIR/server.ts" "$TMP_TEST_DIR/golden1.ts" "$TMP_TEST_DIR/golden2.ts"; do
    python3 "$PATCHER" "$f"
    python3 "$PATCHER" "$f"
    [ "$(grep -c "agentic-pod-launcher: telegram voice roundtrip patch v3" "$f")" -eq 1 ]
    [ "$(grep -c "agentic-pod-launcher: telegram voice roundtrip patch v2" "$f")" -eq 0 ]
    [ "$(grep -c "agentic-pod-launcher: telegram voice roundtrip patch v1" "$f")" -eq 0 ]
    [ "$(grep -c "voice_text: {" "$f")" -eq 1 ]
    [ "$(grep -c "voice helpers end (033)" "$f")" -eq 1 ]
  done
}

# ── 034 US1: spoken-style contract (contracts/spoken-style-contract.md) ──

@test "034 US1(a): the instructions line is a template literal stating the v3 contract clauses" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  local f="$TMP_TEST_DIR/server.ts"
  grep -qF 'ALWAYS include voice_text: a spoken SUMMARY of your answer' "$f"
  grep -qF 'a spoken SUMMARY of your answer, never your text read aloud' "$f"
  grep -qF 'about 30 seconds (~450 characters) by default' "$f"
  grep -qF '${VOICE_SPOKEN_CHAR_CAP} characters, the hard limit' "$f"
  grep -qF 'never enumerate a list item by item' "$f"
  grep -qF 'plain spoken prose in ${VOICE_SPOKEN_LANG_NAME}' "$f"
  grep -qF 'follow every amount with its currency name (${VOICE_CURRENCY}' "$f"
  grep -qF 'Do NOT write a closing phrase' "$f"
  grep -qF 'cut at a sentence and the result says so' "$f"
  # kept 032/033 substrings
  grep -qF 'never tell the user you cannot send audio' "$f"
  grep -qF 'only the first reply of the exchange is spoken' "$f"
  grep -qF 'set voice_force: true on that reply' "$f"
  # structurally a template literal: the element starts with a backtick and ends with backtick+comma
  local line
  line=$(grep -F 'ALWAYS include voice_text: a spoken SUMMARY of your answer' "$f" | head -1 | sed -e 's/^[[:space:]]*//')
  [ "${line:0:1}" = '`' ]
  [ "${line: -2}" = '`,' ]
}

@test "034 US1(b): the voice_text description states the v3 facts (summary, limit, no closing phrase, omission fallback)" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  local f="$TMP_TEST_DIR/server.ts"
  grep -qF 'Spoken SUMMARY of this reply' "$f"
  grep -qF 'never above the spoken limit stated in the channel instructions' "$f"
  grep -qF 'no closing phrase (the channel appends it)' "$f"
  grep -qF 'cleaned, sentence-cut version of `text` is read aloud' "$f"
}

@test "034 US1(c) / G12: the replaced 033 phrases are gone from the patched file" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  run grep -qF 'include voice_text with a concise speakable version' "$TMP_TEST_DIR/server.ts"
  [ "$status" -ne 0 ]
  run grep -qF 'your full text is read aloud up to the cap' "$TMP_TEST_DIR/server.ts"
  [ "$status" -ne 0 ]
  run grep -qF 'Strongly recommended: when omitted' "$TMP_TEST_DIR/server.ts"
  [ "$status" -ne 0 ]
}

@test "034 US1(d) / G6: the five v3 constants exist once each, before the sentinel, in TDZ-safe order" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  local f="$TMP_TEST_DIR/server.ts"
  awk '/telegram voice roundtrip patch v3/{f=1} f{print} /voice helpers end \(033\)/{exit}' "$f" > "$TMP_TEST_DIR/helpers.txt"
  [ "$(grep -cF "const VOICE_SIGNOFF = (process.env.TELEGRAM_VOICE_SIGNOFF ?? '').trim()" "$TMP_TEST_DIR/helpers.txt")" -eq 1 ]
  [ "$(grep -cF "const _VOICE_WORDS = VOICE_STT_LANG === 'en'" "$TMP_TEST_DIR/helpers.txt")" -eq 1 ]
  [ "$(grep -cF "const VOICE_CURRENCY = (process.env.TELEGRAM_VOICE_CURRENCY ?? '').trim() ||" "$TMP_TEST_DIR/helpers.txt")" -eq 1 ]
  [ "$(grep -cF "const VOICE_SPOKEN_LANG_NAME = VOICE_STT_LANG === 'es' ? 'Spanish' : VOICE_STT_LANG === 'en' ? 'English' : 'the language the user wrote in'" "$TMP_TEST_DIR/helpers.txt")" -eq 1 ]
  [ "$(grep -cF "const VOICE_EMPTY_SENTENCE = _VOICE_WORDS.empty" "$TMP_TEST_DIR/helpers.txt")" -eq 1 ]
  # each constant appears exactly once in the WHOLE file too (never duplicated by a twin leak)
  [ "$(grep -cF "const VOICE_SIGNOFF = " "$f")" -eq 1 ]
  [ "$(grep -cF "const VOICE_EMPTY_SENTENCE = " "$f")" -eq 1 ]
  # TDZ order (analyze U1): the const must be declared BEFORE the boot-log block reads it,
  # and VOICE_STT_LANG before the word table that reads it.
  local signoff_line bootlog_line sttlang_line words_line
  signoff_line=$(grep -nF 'const VOICE_SIGNOFF =' "$TMP_TEST_DIR/helpers.txt" | head -1 | cut -d: -f1)
  bootlog_line=$(grep -nF 'voice active mode=' "$TMP_TEST_DIR/helpers.txt" | head -1 | cut -d: -f1)
  sttlang_line=$(grep -nF 'const VOICE_STT_LANG' "$TMP_TEST_DIR/helpers.txt" | head -1 | cut -d: -f1)
  words_line=$(grep -nF 'const _VOICE_WORDS' "$TMP_TEST_DIR/helpers.txt" | head -1 | cut -d: -f1)
  [ -n "$signoff_line" ] && [ -n "$bootlog_line" ] && [ -n "$sttlang_line" ] && [ -n "$words_line" ]
  [ "$signoff_line" -lt "$bootlog_line" ]
  [ "$sttlang_line" -lt "$words_line" ]
}

@test "034 US1(e) / G7: the spoken cap default is 900 in the v3 helpers, 1200 is gone; boot log reports the sign-off LENGTH only" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  awk '/telegram voice roundtrip patch v3/{f=1} f{print} /voice helpers end \(033\)/{exit}' "$TMP_TEST_DIR/server.ts" > "$TMP_TEST_DIR/helpers.txt"
  [ "$(grep -cF ': 900' "$TMP_TEST_DIR/helpers.txt")" -eq 1 ]
  [ "$(grep -cF ': 1200' "$TMP_TEST_DIR/helpers.txt" || true)" -eq 0 ]
  grep -qF 'signoff=${VOICE_SIGNOFF.length}chars' "$TMP_TEST_DIR/helpers.txt"
  run grep -qF 'signoff=${VOICE_SIGNOFF}' "$TMP_TEST_DIR/helpers.txt"
  [ "$status" -ne 0 ]
}

@test "034 US1(f): anti-tautology — the live schema property and instructions line differ from their frozen _V2 twins" {
  python3 -B - "$PATCHER" <<'PY'
import sys, os
sys.path.insert(0, os.path.dirname(sys.argv[1]))
import apply_telegram_typing_patch as p
assert p.VOICE_SCHEMA_PROPERTY_V2 != p.VOICE_SCHEMA_PROPERTY, "VOICE_SCHEMA_PROPERTY still equals its _V2 twin"
assert p.VOICE_INSTRUCTIONS_LINE_V2 != p.VOICE_INSTRUCTIONS_LINE, "VOICE_INSTRUCTIONS_LINE still equals its _V2 twin"
PY
}

# ── 034 US3: spoken-safe normalization + language (pipeline C2/C5/C9) ──

@test "034 US3(a): _voiceSpokenNormalize is declared once, before the sentinel, with the closed figure group (CANON-FIG)" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  local f="$TMP_TEST_DIR/server.ts"
  [ "$(grep -cF 'function _voiceSpokenNormalize(input: string): string' "$f")" -eq 1 ]
  local fn_line sentinel_line
  fn_line=$(grep -nF 'function _voiceSpokenNormalize(input: string): string' "$f" | head -1 | cut -d: -f1)
  sentinel_line=$(grep -nF 'voice helpers end (033)' "$f" | head -1 | cut -d: -f1)
  [ -n "$fn_line" ] && [ -n "$sentinel_line" ]
  [ "$fn_line" -lt "$sentinel_line" ]
  # ONE backslash in the TS text: the /…/.source + String.raw form (analyze I2)
  [ "$(grep -cF 'const _VOICE_FIG = /(?:\d{1,3}(?:[.,\s]\d{3})*(?:[.,]\d+)?|\d+(?:[.,]\d+)?)(?!\d)/.source' "$f")" -eq 1 ]
}

@test "034 US3(b) / G8: the synthesis body carries the language_code spread exactly once (CANON-B); language_code appears exactly twice in the file" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  local f="$TMP_TEST_DIR/server.ts"
  [ "$(grep -cF 'body: JSON.stringify({ text, model_id: VOICE_TTS_MODEL, ...(VOICE_STT_LANG ? { language_code: VOICE_STT_LANG } : {}) }),' "$f")" -eq 1 ]
  # STT form.append + the synth body — nothing else
  [ "$(grep -c 'language_code' "$f")" -eq 2 ]
  grep -qF "if (VOICE_STT_LANG) form.append('language_code', VOICE_STT_LANG)" "$f"
}

@test "034 US3(c) / G15: every new TS sequence containing a valid Python escape reaches the OUTPUT verbatim (research D14)" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  local f="$TMP_TEST_DIR/server.ts"
  grep -qF '\bhttps?:' "$f"
  [ "$(grep -cF '(.+?)\1/g' "$f")" -eq 1 ]
  grep -qF '(?<=\S)\1/g' "$f"
  grep -qF '/\r\n?/g' "$f"
  grep -qF '[^`\n]*' "$f"
  grep -qF '[^\]\n]*' "$f"
  grep -qF '[ \t]' "$f"
  grep -qF '(?!\d)' "$f"
  grep -qF '\u{1F1E6}-\u{1F1FF}' "$f"
  grep -qF '\u{1F3FB}-\u{1F3FF}' "$f"
  grep -qF '\u{20E3}' "$f"
  grep -qF '\u{FE0F}' "$f"
  grep -qF '\u{200D}' "$f"
}

@test "034 US3(d) / G16: zero control bytes in the patched OUTPUT (a silently transformed \\1 or \\b shows up only there)" {
  # Control: the pristine has none, so the oracle itself is known-good.
  run bash -c "LC_ALL=C grep -c \$'[\x01-\x08\x0b\x0c\x0e-\x1f]' '$REPO_ROOT/tests/fixtures/telegram-server-pristine.ts'"
  [ "$output" = "0" ]
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  run bash -c "LC_ALL=C grep -c \$'[\x01-\x08\x0b\x0c\x0e-\x1f]' '$TMP_TEST_DIR/server.ts'"
  [ "$output" = "0" ]
}

@test "034 US3(e): the normalization passes run in the contract order (rules → emphasis → lists → pipes → table rows → pictographs → symbols → stray \$)" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  awk '/function _voiceSpokenNormalize\(input: string\): string/{f=1} f{print} f&&/^}$/{exit}' "$TMP_TEST_DIR/server.ts" > "$TMP_TEST_DIR/normalize.txt"
  [ -s "$TMP_TEST_DIR/normalize.txt" ]
  local l_rule l_strong l_list l_pipe l_table l_picto l_r1 l_r5 l_dollar
  l_rule=$(grep -nF '(?:[-*_=][ \t]*){3,}' "$TMP_TEST_DIR/normalize.txt" | head -1 | cut -d: -f1)
  l_strong=$(grep -nF '(\*\*|__)(.+?)\1/g' "$TMP_TEST_DIR/normalize.txt" | head -1 | cut -d: -f1)
  l_list=$(grep -nF '[-*+•]' "$TMP_TEST_DIR/normalize.txt" | head -1 | cut -d: -f1)
  l_pipe=$(grep -nF '.replace(/\|/g,' "$TMP_TEST_DIR/normalize.txt" | head -1 | cut -d: -f1)
  l_table=$(grep -nF '[-:][-: \t]*$' "$TMP_TEST_DIR/normalize.txt" | head -1 | cut -d: -f1)
  l_picto=$(grep -nF 'Extended_Pictographic' "$TMP_TEST_DIR/normalize.txt" | head -1 | cut -d: -f1)
  l_r1=$(grep -nF 'String.raw`(?:US\$|USD)\s*(${_VOICE_FIG})`' "$TMP_TEST_DIR/normalize.txt" | head -1 | cut -d: -f1)
  l_r5=$(grep -nF 'String.raw`(?:CLP\s*\$?|\$)\s*(${_VOICE_FIG})`' "$TMP_TEST_DIR/normalize.txt" | head -1 | cut -d: -f1)
  # single quotes: inside double quotes bash would collapse \$ to $ and the oracle would never match
  l_dollar=$(grep -nF '.replace(/\$/g,' "$TMP_TEST_DIR/normalize.txt" | head -1 | cut -d: -f1)
  [ -n "$l_rule" ] && [ -n "$l_strong" ] && [ -n "$l_list" ] && [ -n "$l_pipe" ] && [ -n "$l_table" ] && [ -n "$l_picto" ] && [ -n "$l_r1" ] && [ -n "$l_r5" ] && [ -n "$l_dollar" ]
  [ "$l_rule" -lt "$l_strong" ]
  [ "$l_strong" -lt "$l_list" ]
  [ "$l_list" -lt "$l_pipe" ]
  [ "$l_pipe" -lt "$l_table" ]
  [ "$l_table" -lt "$l_picto" ]
  [ "$l_picto" -lt "$l_r1" ]
  [ "$l_r1" -lt "$l_r5" ]
  [ "$l_r5" -lt "$l_dollar" ]
  # the seven symbol rules are all String.raw template literals (one backslash in the TS)
  [ "$(grep -cF 'new RegExp(String.raw`' "$TMP_TEST_DIR/normalize.txt")" -eq 7 ]
}

# ── 034 US2: sign-off helpers (pipeline C4) ──

@test "034 US2(h1): _voiceKey / _voiceSignoffStrip / _voiceSignoffAppend are declared once each, in that order, before the sentinel" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  local f="$TMP_TEST_DIR/server.ts"
  [ "$(grep -cF 'function _voiceKey(s: string): string' "$f")" -eq 1 ]
  [ "$(grep -cF 'function _voiceSignoffStrip(spoken: string, signoff: string): string' "$f")" -eq 1 ]
  [ "$(grep -cF 'function _voiceSignoffAppend(spoken: string, signoff: string): string' "$f")" -eq 1 ]
  local l_key l_strip l_append l_sentinel
  l_key=$(grep -nF 'function _voiceKey(' "$f" | head -1 | cut -d: -f1)
  l_strip=$(grep -nF 'function _voiceSignoffStrip(' "$f" | head -1 | cut -d: -f1)
  l_append=$(grep -nF 'function _voiceSignoffAppend(' "$f" | head -1 | cut -d: -f1)
  l_sentinel=$(grep -nF 'voice helpers end (033)' "$f" | head -1 | cut -d: -f1)
  [ -n "$l_key" ] && [ -n "$l_strip" ] && [ -n "$l_append" ] && [ -n "$l_sentinel" ]
  [ "$l_key" -lt "$l_strip" ]
  [ "$l_strip" -lt "$l_append" ]
  [ "$l_append" -lt "$l_sentinel" ]
}

@test "034 US2(h2): _voiceKey strips combining marks and trailing punctuation as ESCAPE TEXT (never glyphs); zero combining-mark bytes in the output" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  awk '/function _voiceKey\(s: string\): string/{f=1} f{print} f&&/^}$/{exit}' "$TMP_TEST_DIR/server.ts" > "$TMP_TEST_DIR/key.txt"
  grep -qF ".normalize('NFD').replace(/[\u0300-\u036f]/g, '')" "$TMP_TEST_DIR/key.txt"
  grep -qF ".replace(/[.!?,;:\u2026]+$/g, '')" "$TMP_TEST_DIR/key.txt"
  grep -qF '.toLowerCase()' "$TMP_TEST_DIR/key.txt"
  run bash -c "LC_ALL=C grep -c \$'\xcc\x80' '$TMP_TEST_DIR/server.ts'"
  [ "$output" = "0" ]
  # no real ellipsis glyph in the helpers either (033 rule)
  run bash -c "LC_ALL=C grep -c \$'\xe2\x80\xa6' '$TMP_TEST_DIR/key.txt'"
  [ "$output" = "0" ]
}

@test "034 US2(h3): _voiceSignoffStrip bounds its scan to 3x the sign-off length and matches the longest key-equal suffix" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  awk '/function _voiceSignoffStrip\(/{f=1} f{print} f&&/^}$/{exit}' "$TMP_TEST_DIR/server.ts" > "$TMP_TEST_DIR/strip.txt"
  grep -qF 'Math.max(0, s.length - 3 * signoff.length)' "$TMP_TEST_DIR/strip.txt"
  grep -qF '_voiceKey(s.slice(j)) === k' "$TMP_TEST_DIR/strip.txt"
  grep -qF 'if (!signoff) return s' "$TMP_TEST_DIR/strip.txt"
  grep -qF '!_voiceKey(s).endsWith(k)' "$TMP_TEST_DIR/strip.txt"
}

@test "034 US2(h4): _voiceSignoffAppend dedupes by key, turns a trailing ;: into a period BEFORE choosing the separator, and is a no-op with an empty phrase" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  awk '/function _voiceSignoffAppend\(/{f=1} f{print} f&&/^}$/{exit}' "$TMP_TEST_DIR/server.ts" > "$TMP_TEST_DIR/append.txt"
  grep -qF 'if (!signoff) return s' "$TMP_TEST_DIR/append.txt"
  grep -qF 'if (k && _voiceKey(s).endsWith(k)) return s' "$TMP_TEST_DIR/append.txt"
  local l_semi l_sep
  l_semi=$(grep -nF "s = s.replace(/[;:]+$/, '.')" "$TMP_TEST_DIR/append.txt" | head -1 | cut -d: -f1)
  l_sep=$(grep -nF "const sep = /[.!?]$/.test(s)" "$TMP_TEST_DIR/append.txt" | head -1 | cut -d: -f1)
  [ -n "$l_semi" ] && [ -n "$l_sep" ]
  [ "$l_semi" -lt "$l_sep" ]
  grep -qF 'return s + sep + signoff' "$TMP_TEST_DIR/append.txt"
}

# ── 034 US4: assembly + reply block (pipeline C6/C7) ──

@test "034 US4(a): _voiceSpokenAssemble runs normalize → empty sentence → strip → budget → cut → append, in that order, before the sentinel" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  awk '/function _voiceSpokenAssemble\(raw: string\)/{f=1} f{print} f&&/^}$/{exit}' "$TMP_TEST_DIR/server.ts" > "$TMP_TEST_DIR/asm.txt"
  [ -s "$TMP_TEST_DIR/asm.txt" ]
  local l_norm l_empty l_strip l_budget l_cut l_append
  l_norm=$(grep -nF '_voiceSpokenNormalize(' "$TMP_TEST_DIR/asm.txt" | head -1 | cut -d: -f1)
  l_empty=$(grep -nF 'VOICE_EMPTY_SENTENCE' "$TMP_TEST_DIR/asm.txt" | head -1 | cut -d: -f1)
  l_strip=$(grep -nF '_voiceSignoffStrip(' "$TMP_TEST_DIR/asm.txt" | head -1 | cut -d: -f1)
  l_budget=$(grep -nF 'Math.max(VOICE_SPOKEN_CHAR_CAP - (VOICE_SIGNOFF ? VOICE_SIGNOFF.length + 2 : 0), Math.floor(VOICE_SPOKEN_CHAR_CAP / 2))' "$TMP_TEST_DIR/asm.txt" | head -1 | cut -d: -f1)
  l_cut=$(grep -nF '_voiceSentenceCut(' "$TMP_TEST_DIR/asm.txt" | head -1 | cut -d: -f1)
  l_append=$(grep -nF '_voiceSignoffAppend(' "$TMP_TEST_DIR/asm.txt" | head -1 | cut -d: -f1)
  [ -n "$l_norm" ] && [ -n "$l_empty" ] && [ -n "$l_strip" ] && [ -n "$l_budget" ] && [ -n "$l_cut" ] && [ -n "$l_append" ]
  [ "$l_norm" -lt "$l_empty" ]
  [ "$l_empty" -lt "$l_strip" ]
  [ "$l_strip" -lt "$l_budget" ]
  [ "$l_budget" -lt "$l_cut" ]
  [ "$l_cut" -lt "$l_append" ]
  # the whole function sits before the sentinel
  local l_fn l_sentinel
  l_fn=$(grep -nF 'function _voiceSpokenAssemble(' "$TMP_TEST_DIR/server.ts" | head -1 | cut -d: -f1)
  l_sentinel=$(grep -nF 'voice helpers end (033)' "$TMP_TEST_DIR/server.ts" | head -1 | cut -d: -f1)
  [ "$l_fn" -lt "$l_sentinel" ]
  # the cut helper's sentence-terminator regex and its word-boundary fallback
  grep -qF '[.!?;](?=\s|$)' "$TMP_TEST_DIR/server.ts"
  grep -qF "if (at < budget / 4) at = head.lastIndexOf(' ')" "$TMP_TEST_DIR/server.ts"
}

@test "034 US4(b): the reply block builds the rendition through the assembler, synthesizes its spoken text, and reports omission/trim on the NARRATED length" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  awk '/agentic-pod-launcher: voice roundtrip outbound synthesis/{f=1} f{print; if (/^        return \{ content/) exit}' \
    "$TMP_TEST_DIR/server.ts" > "$TMP_TEST_DIR/reply.txt"
  local l_asm l_spoken l_synth l_o l_n l_t l_else
  l_asm=$(grep -nF 'const _voiceAsm = _voiceSpokenAssemble(_voiceFromText ? text : (voiceTextArg as string).trim())' "$TMP_TEST_DIR/reply.txt" | head -1 | cut -d: -f1)
  l_spoken=$(grep -nF 'const spoken = _voiceAsm.spoken' "$TMP_TEST_DIR/reply.txt" | head -1 | cut -d: -f1)
  l_synth=$(grep -nF '_voiceSynthesize(spoken' "$TMP_TEST_DIR/reply.txt" | head -1 | cut -d: -f1)
  l_o=$(grep -nF 'voice tts spoke ${_voiceAsm.narrated.length} chars without voice_text' "$TMP_TEST_DIR/reply.txt" | head -1 | cut -d: -f1)
  l_n=$(grep -nF 'if (_voiceAsm.narrated.length > VOICE_OMISSION_NAG_CHARS)' "$TMP_TEST_DIR/reply.txt" | head -1 | cut -d: -f1)
  l_t=$(grep -nF '_voiceOutcome += `; voice_text trimmed to ${_voiceAsm.narrated.length} chars`' "$TMP_TEST_DIR/reply.txt" | head -1 | cut -d: -f1)
  l_else=$(grep -nF '} else if (_voiceAsm.trimmed) {' "$TMP_TEST_DIR/reply.txt" | head -1 | cut -d: -f1)
  [ -n "$l_asm" ] && [ -n "$l_spoken" ] && [ -n "$l_synth" ] && [ -n "$l_o" ] && [ -n "$l_n" ] && [ -n "$l_t" ] && [ -n "$l_else" ]
  [ "$l_asm" -lt "$l_spoken" ]
  [ "$l_spoken" -lt "$l_synth" ]
  [ "$l_o" -lt "$l_n" ]
  [ "$l_n" -lt "$l_t" ]
  [ "$((l_else + 1))" -eq "$l_t" ]
  # the omission nag still names the count read aloud; the spoken (sign-off included) length stays in the ok line and CANON-S
  grep -qF '; voice_text omitted — ${_voiceAsm.narrated.length} chars of text were read aloud' "$TMP_TEST_DIR/reply.txt"
  grep -qF 'voice tts ok chat=${chat_id} chars=${spoken.length} fmt=${fmt} ms=${_voiceMs}' "$TMP_TEST_DIR/reply.txt"
  grep -qF '_voiceOutcome = `\nvoice: sent (fmt=${fmt}, chars=${spoken.length}, ms=${_voiceMs})`' "$TMP_TEST_DIR/reply.txt"
  # the v2 ternary is gone
  run grep -qF '? _voiceTruncate(text, VOICE_SPOKEN_CHAR_CAP)' "$TMP_TEST_DIR/reply.txt"
  [ "$status" -ne 0 ]
}

@test "034 US4(c) / G11 / G10: whitelist on the reply block (no raw error, URL, spoken text, voice id, file/bot path) and the 033 byte-identity guard" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  awk '/agentic-pod-launcher: voice roundtrip outbound synthesis/{f=1} f{print; if (/^        return \{ content/) exit}' \
    "$TMP_TEST_DIR/server.ts" > "$TMP_TEST_DIR/reply.txt"
  local bad
  for bad in '${err' '${url' '${spoken}' '${text' '${VOICE_ID' 'file/bot' '_voiceAsm.spoken}' '_voiceAsm.narrated}'; do
    run grep -qF "$bad" "$TMP_TEST_DIR/reply.txt"
    [ "$status" -ne 0 ]
  done
  # G10 (033): exactly two `_voiceOutcome = ` assignments (sent / failed); the += lines are nags
  [ "$(grep -c '^ *_voiceOutcome = ' "$TMP_TEST_DIR/reply.txt")" -eq 2 ]
  grep -qF "let _voiceOutcome = ''" "$TMP_TEST_DIR/reply.txt"
  grep -qF "return { content: [{ type: 'text', text: result + _voiceOutcome }] }" "$TMP_TEST_DIR/reply.txt"
}

@test "034 US4(d): anti-tautology — the live reply block differs from its frozen _V2 twin" {
  python3 -B - "$PATCHER" <<'PY'
import sys, os
sys.path.insert(0, os.path.dirname(sys.argv[1]))
import apply_telegram_typing_patch as p
assert p.VOICE_REPLY_BLOCK_V2 + p._REPLY_RETURN_V2 != p.VOICE_REPLY_BLOCK + p._REPLY_RETURN_V2, "VOICE_REPLY_BLOCK still equals its _V2 twin"
assert '_voiceTruncate' not in p.VOICE_HELPERS, "_voiceTruncate still in the live helpers"
assert '_voiceTruncate' in p.VOICE_HELPERS_V2 and '_voiceTruncate' in p.VOICE_HELPERS_V1, "the frozen twins must keep _voiceTruncate"
PY
}
