#!/usr/bin/env bats
# Tests for docker/scripts/apply_telegram_typing_patch.py — three independent
# hunk groups (typing / offset / stderr) applied to a synthetic server.ts
# fixture that mimics the upstream claude-plugins-official/telegram source.

load helper

PATCHER="$REPO_ROOT/docker/scripts/apply_telegram_typing_patch.py"

setup() {
  setup_tmp_dir
  # Synthetic server.ts containing the 4 anchors the patcher targets:
  #   1. `const TOKEN = process.env.TELEGRAM_BOT_TOKEN`  → stderr hunk
  #   2. `let botUsername = ''`                          → typing+offset helpers
  #   3. `const bot = new Bot(TOKEN)`                    → offset middleware
  #   4. `await bot.start({`                             → offset replay
  #   5. `// Typing indicator — signals "processing" ...` → typing hunk2
  #   6. `case 'reply': { const chat_id = args.chat_id as string` → typing hunk3
  # Synthetic fixture mirrors upstream indentation. The typing-patch hunk2
  # anchor expects 2-space indent on the comment + sendChatAction lines (that
  # context is a single-callback function body in upstream server.ts, not a
  # switch case). The reply-handler hunk3 anchor uses 8-space indent
  # (`case 'reply': { const chat_id = ... ` inside a switch — matches upstream).
  cat > "$TMP_TEST_DIR/server.ts" <<'TS'
#!/usr/bin/env bun
import { Bot } from 'grammy'
import { readFileSync } from 'fs'

const TOKEN = process.env.TELEGRAM_BOT_TOKEN
if (!TOKEN) {
  process.stderr.write('TELEGRAM_BOT_TOKEN required\n')
  process.exit(1)
}

const bot = new Bot(TOKEN)
let botUsername = ''

bot.on('message', async (ctx) => {
  const chat_id = ctx.chat.id
  // Typing indicator — signals "processing" until we reply (or ~5s elapses).
  void bot.api.sendChatAction(chat_id, 'typing').catch(() => {})
  await ctx.reply('echo')
})

async function handleReply(args: any) {
  switch (args.tool) {
    case 'reply': {
        const chat_id = args.chat_id as string
        await bot.api.sendMessage(chat_id, 'reply')
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

@test "patcher applies all 3 markers on a fresh fixture" {
  run python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  [ "$status" -eq 0 ]
  grep -q "agentic-pod-launcher: typing refresh patch v1" "$TMP_TEST_DIR/server.ts"
  grep -q "agentic-pod-launcher: offset persistence patch v1" "$TMP_TEST_DIR/server.ts"
  grep -q "agentic-pod-launcher: stderr-capture patch v1" "$TMP_TEST_DIR/server.ts"
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

@test "offset patch: _saveOffset writes update_id + 1 (not update_id)" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  grep -q "offset: updateId + 1" "$TMP_TEST_DIR/server.ts"
}

@test "offset patch: middleware uses await next() before _saveOffset" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  # The middleware block must call await next() before the save — confirms
  # at-least-once semantics (save happens AFTER handler delivers to MCP).
  grep -A 2 "post-handler middleware" "$TMP_TEST_DIR/server.ts" | grep -q "await next()"
}

@test "offset patch: replay block uses bot.api.getUpdates with offset" {
  python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  grep -q "bot.api.getUpdates({ offset: _resume" "$TMP_TEST_DIR/server.ts"
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
  ! grep -q "agentic-pod-launcher: typing refresh patch v1" "$TMP_TEST_DIR/server.ts"
  grep -q "agentic-pod-launcher: offset persistence patch v1" "$TMP_TEST_DIR/server.ts"
  grep -q "agentic-pod-launcher: stderr-capture patch v1" "$TMP_TEST_DIR/server.ts"
}

@test "anchor drift: missing const TOKEN anchor → stderr skipped, typing+offset still apply" {
  # Mangle the stderr anchor; typing+offset have independent anchors.
  sed -i.bak 's|const TOKEN = process.env|const NOT_TOKEN = process.env|' "$TMP_TEST_DIR/server.ts"
  rm -f "$TMP_TEST_DIR/server.ts.bak"
  run python3 "$PATCHER" "$TMP_TEST_DIR/server.ts"
  [ "$status" -eq 0 ]
  grep -q "agentic-pod-launcher: typing refresh patch v1" "$TMP_TEST_DIR/server.ts"
  grep -q "agentic-pod-launcher: offset persistence patch v1" "$TMP_TEST_DIR/server.ts"
  ! grep -q "agentic-pod-launcher: stderr-capture patch v1" "$TMP_TEST_DIR/server.ts"
}
