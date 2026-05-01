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
  #   2. `let botUsername = ''`                                → typing+offset helpers
  #   3. `  const chat_id = String(ctx.chat!.id)` (2-sp ind.)  → offset mark hunk
  #   4. `  // Typing indicator — signals "processing" ...`    → typing hunk2
  #   5. `      case 'reply': {`                               → typing hunk3
  #   6. `        const result = …\n          sentIds.length === 1` → offset ack hunk
  #   7. `      await bot.start({`                             → offset replay hunk
  cat > "$TMP_TEST_DIR/server.ts" <<'TS'
#!/usr/bin/env bun
import { Bot } from 'grammy'
import { readFileSync, writeFileSync, statSync, mkdirSync } from 'fs'

const TOKEN = process.env.TELEGRAM_BOT_TOKEN
if (!TOKEN) {
  process.stderr.write('TELEGRAM_BOT_TOKEN required\n')
  process.exit(1)
}

const STATE_DIR = '/tmp/test'
const PID_FILE = '/tmp/test/bot.pid'
mkdirSync(STATE_DIR, { recursive: true, mode: 0o700 })
try {
  const stale = parseInt(readFileSync(PID_FILE, 'utf8'), 10)
  if (stale > 1 && stale !== process.pid) {
    process.kill(stale, 0)
    process.stderr.write(`telegram channel: replacing stale poller pid=${stale}\n`)
    process.kill(stale, 'SIGTERM')
  }
} catch {}
writeFileSync(PID_FILE, String(process.pid))

const bot = new Bot(TOKEN)
let botUsername = ''

async function handleInbound(ctx: any) {
  const from = ctx.from!
  const chat_id = String(ctx.chat!.id)
  const msgId = ctx.message?.message_id
  // Typing indicator — signals "processing" until we reply (or ~5s elapses).
  void bot.api.sendChatAction(chat_id, 'typing').catch(() => {})
}

bot.on('message', async (ctx: any) => {
  await handleInbound(ctx)
})

async function handleReply(args: any) {
  switch (args.tool) {
      case 'reply': {
        const chat_id = args.chat_id as string
        const text = args.text as string
        const sentIds: number[] = []
        try {
          for (let i = 0; i < 1; i++) {
            const sent = await bot.api.sendMessage(chat_id, text)
            sentIds.push(sent.message_id)
          }
        } catch (err) {
          throw err
        }

        const result =
          sentIds.length === 1
            ? `sent (id: ${sentIds[0]})`
            : `sent ${sentIds.length} parts`
        return { content: [{ type: 'text', text: result }] }
      }
  }
}

async function main() {
  for (let attempt = 1; ; attempt++) {
    try {
      await bot.start({
        onStart: () => {}
      })
      break
    } catch (e) {
      // retry
    }
  }
}
TS
}

teardown() { teardown_tmp_dir; }

@test "patcher applies all 4 markers on a fresh fixture" {
  run python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  [ "$status" -eq 0 ]
  grep -q "agentic-pod-launcher: typing refresh patch v2" "$TMP_TEST_DIR/server.ts"
  grep -q "agentic-pod-launcher: offset persistence patch v1" "$TMP_TEST_DIR/server.ts"
  grep -q "agentic-pod-launcher: stderr-capture patch v1" "$TMP_TEST_DIR/server.ts"
  grep -q "agentic-pod-launcher: primary lock patch v1" "$TMP_TEST_DIR/server.ts"
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
  # right after the chat_id binding. -A 2 covers both lines.
  grep -A 2 "  const chat_id = String(ctx.chat!.id)" "$TMP_TEST_DIR/server.ts" \
    | grep -q "_markPending(chat_id, ctx.update.update_id)"
}

@test "offset patch: _ackPending injected immediately before const result in case 'reply'" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  # The ack line must appear right before `const result =` in case 'reply'.
  # grep -B 1 the result line and confirm previous line calls _ackPending.
  grep -B 1 "        const result =" "$TMP_TEST_DIR/server.ts" \
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
  ! grep -q "agentic-pod-launcher: typing refresh patch v2" "$TMP_TEST_DIR/server.ts"
  grep -q "agentic-pod-launcher: offset persistence patch v1" "$TMP_TEST_DIR/server.ts"
  grep -q "agentic-pod-launcher: stderr-capture patch v1" "$TMP_TEST_DIR/server.ts"
}

@test "anchor drift: missing const TOKEN anchor → stderr skipped, typing+offset still apply" {
  # Mangle the stderr anchor; typing+offset have independent anchors.
  sed -i.bak 's|const TOKEN = process.env|const NOT_TOKEN = process.env|' "$TMP_TEST_DIR/server.ts"
  rm -f "$TMP_TEST_DIR/server.ts.bak"
  run python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  [ "$status" -eq 0 ]
  grep -q "agentic-pod-launcher: typing refresh patch v2" "$TMP_TEST_DIR/server.ts"
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
  grep -q "agentic-pod-launcher: typing refresh patch v2" "$TMP_TEST_DIR/server.ts"
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
  grep -q "agentic-pod-launcher: typing refresh patch v2" "$TMP_TEST_DIR/server.ts"
}
