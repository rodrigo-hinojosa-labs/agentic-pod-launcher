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
  cat > "$TMP_TEST_DIR/server.ts" <<'TS'
#!/usr/bin/env bun
import { Bot, InputFile } from 'grammy'
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

function loadAccess(): any {
  return { dmPolicy: 'open', allowFrom: ['111'], groups: {} }
}

async function handleInbound(ctx: any, text?: string, downloadImage?: any, attachment?: any) {
  const from = ctx.from!
  const chat_id = String(ctx.chat!.id)
  const msgId = ctx.message?.message_id
  // Typing indicator — signals "processing" until we reply (or ~5s elapses).
  void bot.api.sendChatAction(chat_id, 'typing').catch(() => {})
}

bot.on('message', async (ctx: any) => {
  await handleInbound(ctx)
})

bot.on('message:text', async ctx => {
  await handleInbound(ctx, ctx.message.text, undefined)
})

bot.on('message:voice', async ctx => {
  const voice = ctx.message.voice
  const text = ctx.message.caption ?? '(voice message)'
  await handleInbound(ctx, text, undefined, {
    kind: 'voice',
    file_id: voice.file_id,
    size: voice.file_size,
    mime: voice.mime_type,
  })
})

const mcp = {
  setRequestHandler: (_schema: any, _handler: any) => {},
}

mcp.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: 'reply',
      description: 'Reply on Telegram.',
      inputSchema: {
        type: 'object',
        properties: {
          chat_id: { type: 'string' },
          text: { type: 'string' },
          reply_to: {
            type: 'string',
            description: 'Message ID to thread under.',
          },
          files: {
            type: 'array',
            items: { type: 'string' },
            description: 'Absolute file paths to attach.',
          },
          format: {
            type: 'string',
            enum: ['text', 'markdownv2'],
            description: 'Rendering mode.',
          },
        },
        required: ['chat_id', 'text'],
      },
    },
  ],
}))

const mcpServer = new Server(
  { name: 'telegram', version: '1.0.0' },
  {
    capabilities: { tools: {} },
    instructions: [
      'The sender reads Telegram, not this session.',
      '',
      'Access is managed by the /telegram:access skill.',
    ].join('\n'),
  },
)

async function handleReply(args: any) {
  switch (args.tool) {
      case 'reply': {
        const chat_id = args.chat_id as string
        const text = args.text as string
        const files = (args.files as string[] | undefined) ?? []
        const sentIds: number[] = []
        try {
          for (let i = 0; i < 1; i++) {
            const sent = await bot.api.sendMessage(chat_id, text)
            sentIds.push(sent.message_id)
          }
        } catch (err) {
          throw err
        }

        for (const f of files) {
          const sent = await bot.api.sendDocument(chat_id, f)
          sentIds.push(sent.message_id)
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
  count=$(grep -c "agentic-pod-launcher: telegram voice roundtrip patch v1" "$TMP_TEST_DIR/server.ts")
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
  count=$(grep -c "agentic-pod-launcher: telegram voice roundtrip patch v1" "$TMP_TEST_DIR/server.ts")
  [ "$count" -eq 1 ]
}

@test "032 inbound: anchor drift on message:voice handler → voice skipped, other groups still apply" {
  sed -i.bak "s|bot.on('message:voice', async ctx => {|bot.on('message:voicex', async ctx => {|" "$TMP_TEST_DIR/server.ts"
  rm -f "$TMP_TEST_DIR/server.ts.bak"
  run python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  [ "$status" -eq 0 ]
  ! grep -q "agentic-pod-launcher: telegram voice roundtrip patch v1" "$TMP_TEST_DIR/server.ts"
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
  ! grep -q '${err}' "$TMP_TEST_DIR/voice_inbound_snippet.txt"
  ! grep -q '${url}' "$TMP_TEST_DIR/voice_inbound_snippet.txt"
  ! grep -q 'file/bot' "$TMP_TEST_DIR/voice_inbound_snippet.txt"
  grep -q 'voice stt fail: ${cls} status=${status}' "$TMP_TEST_DIR/voice_inbound_snippet.txt"
}

@test "032 inbound: the voice handler never calls sendMessage or ctx.reply — no transcript echo" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  awk '/^bot\.on\(.message:voice./{f=1} f{print; if (/^\}\)$/) exit}' \
    "$TMP_TEST_DIR/server.ts" > "$TMP_TEST_DIR/voice_inbound_snippet.txt"
  ! grep -q 'sendMessage(' "$TMP_TEST_DIR/voice_inbound_snippet.txt"
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
  voice_count=$(grep -c "agentic-pod-launcher: telegram voice roundtrip patch v1" "$TMP_TEST_DIR/server.ts")
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
  return_line=$(grep -n "return { content: \[{ type: 'text', text: result }\] }" "$TMP_TEST_DIR/server.ts" | head -1 | cut -d: -f1)
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
  ! grep -q "sendVoice" "$TMP_TEST_DIR/server.ts"
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  local count
  count=$(grep -c "bot.api.sendVoice(chat_id" "$TMP_TEST_DIR/server.ts")
  [ "$count" -eq 1 ]
}

@test "032 outbound: a synthesis/send failure never throws — it logs and falls through to return" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  awk '/agentic-pod-launcher: voice roundtrip outbound synthesis/{f=1} f{print; if (/^        \}$/) exit}' \
    "$TMP_TEST_DIR/server.ts" > "$TMP_TEST_DIR/voice_outbound_snippet.txt"
  ! grep -q '^\s*throw ' "$TMP_TEST_DIR/voice_outbound_snippet.txt"
  grep -q "voice tts fail: \${cls} status=\${status}" "$TMP_TEST_DIR/voice_outbound_snippet.txt"
  ! grep -q '${err}' "$TMP_TEST_DIR/voice_outbound_snippet.txt"
}
