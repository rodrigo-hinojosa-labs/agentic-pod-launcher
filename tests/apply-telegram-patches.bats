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
  count=$(grep -c "agentic-pod-launcher: telegram voice roundtrip patch v2" "$TMP_TEST_DIR/server.ts")
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
  count=$(grep -c "agentic-pod-launcher: telegram voice roundtrip patch v2" "$TMP_TEST_DIR/server.ts")
  [ "$count" -eq 1 ]
}

@test "032 inbound: anchor drift on message:voice handler → voice skipped, other groups still apply" {
  sed -i.bak "s|bot.on('message:voice', async ctx => {|bot.on('message:voicex', async ctx => {|" "$TMP_TEST_DIR/server.ts"
  rm -f "$TMP_TEST_DIR/server.ts.bak"
  run python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  [ "$status" -eq 0 ]
  [ "$(grep -c "agentic-pod-launcher: telegram voice roundtrip patch v2" "$TMP_TEST_DIR/server.ts")" -eq 0 ]
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
  voice_count=$(grep -c "agentic-pod-launcher: telegram voice roundtrip patch v2" "$TMP_TEST_DIR/server.ts")
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

@test "032 outbound: truncation helper honors the char cap with word-boundary + ellipsis" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  grep -q "function _voiceTruncate(text: string, cap: number): string" "$TMP_TEST_DIR/server.ts"
  grep -q "text.lastIndexOf(' ', cap)" "$TMP_TEST_DIR/server.ts"
  grep -q "TELEGRAM_VOICE_SPOKEN_CHAR_CAP" "$TMP_TEST_DIR/server.ts"
  grep -q "_voiceTruncate(text, VOICE_SPOKEN_CHAR_CAP)" "$TMP_TEST_DIR/server.ts"
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
  grep -q "include voice_text with a concise speakable version" "$TMP_TEST_DIR/server.ts"
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
  [ "$(grep -c "agentic-pod-launcher: telegram voice roundtrip patch v2" "$TMP_TEST_DIR/server.ts")" -eq 1 ]
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
  [ "$(grep -c "agentic-pod-launcher: telegram voice roundtrip patch v2" "$TMP_TEST_DIR/golden.ts")" -eq 1 ]
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
  [ "$(grep -c "agentic-pod-launcher: telegram voice roundtrip patch v2" "$TMP_TEST_DIR/server.ts")" -eq 1 ]

  cp "$REPO_ROOT/tests/fixtures/telegram-server-voice-v1.ts" "$TMP_TEST_DIR/golden.ts"
  python3 "$PATCHER" "$TMP_TEST_DIR/golden.ts"
  local sha3
  sha3=$(shasum -a 256 "$TMP_TEST_DIR/golden.ts" | awk '{print $1}')
  python3 "$PATCHER" "$TMP_TEST_DIR/golden.ts"
  local sha4
  sha4=$(shasum -a 256 "$TMP_TEST_DIR/golden.ts" | awk '{print $1}')
  [ "$sha3" = "$sha4" ]
  [ "$(grep -c "agentic-pod-launcher: telegram voice roundtrip patch v2" "$TMP_TEST_DIR/golden.ts")" -eq 1 ]
}

@test "033 G4: out-of-band edit to the golden's instructions line blocks the upgrade; other six groups stay unaffected" {
  cp "$REPO_ROOT/tests/fixtures/telegram-server-voice-v1.ts" "$TMP_TEST_DIR/golden.ts"
  perl -0pi -e "s/include voice_text with a concise speakable version of your answer\\./include voice_text somehow./" "$TMP_TEST_DIR/golden.ts"
  run python3 "$PATCHER" "$TMP_TEST_DIR/golden.ts"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "voice v1→v2 upgrade: hunk 5 anchor not found"
  [ "$(grep -c "agentic-pod-launcher: telegram voice roundtrip patch v1" "$TMP_TEST_DIR/golden.ts")" -eq 1 ]
  [ "$(grep -c "agentic-pod-launcher: telegram voice roundtrip patch v2" "$TMP_TEST_DIR/golden.ts")" -eq 0 ]
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
  [ "$(grep -c "agentic-pod-launcher: telegram voice roundtrip patch v2" "$TMP_TEST_DIR/golden.ts")" -eq 1 ]
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
    grep -qF 'include voice_text with a concise speakable version' "$f"
    grep -qF 'your full text is read aloud up to the cap' "$f"
    grep -qF 'do not repeat it to the user' "$f"
    grep -qF 'tell the user once, briefly, that the audio did not go out this time' "$f"
    grep -qF 'set voice_force: true on that reply' "$f"
    grep -A 2 "    instructions: \[" "$f" | grep -q 'attachment_kind="voice"'
    [ "$(grep -c 'arrive transcribed — the message text IS the transcription. When replying to them, include voice_text' "$f")" -eq 0 ]
    grep -qF 'voice note or explicit audio request' "$f"
    grep -qF 'Strongly recommended: when omitted' "$f"
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
  omission_line=$(grep -n 'voice tts spoke ${spoken.length} chars without voice_text' "$TMP_TEST_DIR/voice_reply_block.txt" | head -1 | cut -d: -f1)
  nag_if_line=$(grep -n 'if (spoken.length > VOICE_OMISSION_NAG_CHARS)' "$TMP_TEST_DIR/voice_reply_block.txt" | head -1 | cut -d: -f1)
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
  last_helper_line=$(grep -n "function _voiceRequestMatch\|function _voiceCooldownConsume\|function _voiceTruncate\|function _voiceNormalize" "$TMP_TEST_DIR/server.ts" | tail -1 | cut -d: -f1)
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
