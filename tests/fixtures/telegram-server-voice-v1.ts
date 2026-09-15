#!/usr/bin/env bun
import { Bot, InputFile } from 'grammy'
import { readFileSync, writeFileSync, statSync, mkdirSync } from 'fs'

// agentic-pod-launcher: stderr-capture patch v1
try {
  const _STDERR_LOG = '/workspace/scripts/heartbeat/logs/telegram-mcp-stderr.log'
  const _origWrite = process.stderr.write.bind(process.stderr)
  process.stderr.write = ((chunk: any, ...rest: any[]) => {
    try {
      const fs = require('node:fs')
      const path = require('node:path')
      fs.mkdirSync(path.dirname(_STDERR_LOG), { recursive: true })
      fs.appendFileSync(_STDERR_LOG, typeof chunk === 'string' ? chunk : Buffer.from(chunk))
    } catch {}
    return _origWrite(chunk, ...rest)
  }) as typeof process.stderr.write
  process.on('uncaughtException', (e: Error) => {
    try {
      const fs = require('node:fs')
      fs.appendFileSync(_STDERR_LOG, `[${new Date().toISOString()}] [uncaught] ${e.stack || e}
`)
    } catch {}
  })
  process.on('unhandledRejection', (r: unknown) => {
    try {
      const fs = require('node:fs')
      fs.appendFileSync(_STDERR_LOG, `[${new Date().toISOString()}] [unhandled] ${r}
`)
    } catch {}
  })
} catch {}

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
    // agentic-pod-launcher: primary lock patch v1 — exit cleanly if PID_FILE mtime is fresh (live primary)
    try {
      const _ageMs = Date.now() - statSync(PID_FILE).mtimeMs
      if (_ageMs < 30000) {
        process.stderr.write(`telegram channel: primary pid=${stale} active (heartbeat ${Math.round(_ageMs/1000)}s ago); exiting as secondary
`)
        process.exit(0)
      }
    } catch {}
    process.stderr.write(`telegram channel: replacing stale poller pid=${stale}\n`)
    process.kill(stale, 'SIGTERM')
  }
} catch {}
writeFileSync(PID_FILE, String(process.pid))

// agentic-pod-launcher: primary lock patch v1 — refresh PID_FILE mtime so secondary instances detect us
setInterval(() => {
  try { writeFileSync(PID_FILE, String(process.pid)) } catch {}
}, 5000).unref()

const bot = new Bot(TOKEN)
let botUsername = ''

// agentic-pod-launcher: telegram voice roundtrip patch v1
const VOICE_ENABLED = process.env.TELEGRAM_VOICE_ENABLED === 'true'
const VOICE_KEY = process.env.ELEVENLABS_API_KEY ?? ''
const VOICE_ACTIVE = VOICE_ENABLED && VOICE_KEY.length > 0
const VOICE_REPLY_MODE = (['auto', 'always', 'never'].includes(process.env.TELEGRAM_VOICE_REPLY_MODE ?? '')
  ? (process.env.TELEGRAM_VOICE_REPLY_MODE as 'auto' | 'always' | 'never')
  : 'auto')
const VOICE_ID = process.env.TELEGRAM_VOICE_ID || 'Rachel'
const VOICE_STT_LANG = process.env.TELEGRAM_VOICE_STT_LANG ?? ''
const VOICE_MAX_NOTE_SECONDS = Number(process.env.TELEGRAM_VOICE_MAX_NOTE_SECONDS) > 0
  ? Number(process.env.TELEGRAM_VOICE_MAX_NOTE_SECONDS)
  : 300
const VOICE_SPOKEN_CHAR_CAP = Number(process.env.TELEGRAM_VOICE_SPOKEN_CHAR_CAP) > 0
  ? Number(process.env.TELEGRAM_VOICE_SPOKEN_CHAR_CAP)
  : 1200
const VOICE_API_BASE = 'https://api.elevenlabs.io'
const VOICE_STT_MODEL = 'scribe_v2'
const VOICE_TTS_MODEL = 'eleven_flash_v2_5'
const VOICE_MAX_BYTES = 20 * 1024 * 1024
if (!VOICE_ENABLED) {
  process.stderr.write('telegram channel: voice disabled (TELEGRAM_VOICE_ENABLED != true)\n')
} else if (!VOICE_KEY) {
  process.stderr.write('telegram channel: voice inactive — ELEVENLABS_API_KEY missing\n')
} else {
  process.stderr.write(`telegram channel: voice active mode=${VOICE_REPLY_MODE} caps=${VOICE_MAX_NOTE_SECONDS}s/${VOICE_SPOKEN_CHAR_CAP}chars\n`)
}
const _voiceOrigin = new Map<string, number>()
const _VOICE_ORIGIN_TTL_MS = 5 * 60 * 1000
function _voiceOriginSet(chatId: string): void {
  _voiceOrigin.set(chatId, Date.now())
}
function _voiceOriginConsume(chatId: string): boolean {
  const ts = _voiceOrigin.get(chatId)
  _voiceOrigin.delete(chatId)
  if (ts == null) return false
  return Date.now() - ts < _VOICE_ORIGIN_TTL_MS
}
function _voiceOriginClear(chatId: string): void {
  _voiceOrigin.delete(chatId)
}
let _voiceTtsFormat: 'unknown' | 'ogg-ok' | 'mp3-fallback' = 'unknown'
function _voiceErrClass(err: unknown): { cls: string; status: string } {
  if (err instanceof Error && err.name === 'AbortError') return { cls: 'timeout', status: '' }
  const msg = err instanceof Error ? err.message : ''
  const m = /-status-(\d+)$/.exec(msg)
  if (m) return { cls: 'transport', status: m[1] }
  return { cls: 'transport', status: '' }
}
async function _voiceTranscribe(buf: Buffer, signal: AbortSignal): Promise<string> {
  const form = new FormData()
  form.append('file', new Blob([buf]), 'voice.ogg')
  form.append('model_id', VOICE_STT_MODEL)
  if (VOICE_STT_LANG) form.append('language_code', VOICE_STT_LANG)
  const res = await fetch(`${VOICE_API_BASE}/v1/speech-to-text`, {
    method: 'POST',
    headers: { 'xi-api-key': VOICE_KEY },
    body: form,
    signal,
  })
  if (!res.ok) throw new Error(`stt-status-${res.status}`)
  const j = (await res.json()) as { text?: string }
  return (j.text ?? '').trim()
}
async function _voiceSynthesize(text: string, signal: AbortSignal): Promise<{ buf: Buffer; fmt: 'ogg' | 'mp3' }> {
  async function _voiceTtsRequest(fmt: string): Promise<Buffer> {
    const res = await fetch(`${VOICE_API_BASE}/v1/text-to-speech/${VOICE_ID}?output_format=${fmt}`, {
      method: 'POST',
      headers: { 'xi-api-key': VOICE_KEY, 'content-type': 'application/json' },
      body: JSON.stringify({ text, model_id: VOICE_TTS_MODEL }),
      signal,
    })
    if (!res.ok) throw new Error(`tts-status-${res.status}`)
    return Buffer.from(await res.arrayBuffer())
  }
  if (_voiceTtsFormat !== 'mp3-fallback') {
    const buf = await _voiceTtsRequest('opus_48000_64')
    if (buf.length >= 4 && buf.toString('ascii', 0, 4) === 'OggS') {
      _voiceTtsFormat = 'ogg-ok'
      return { buf, fmt: 'ogg' }
    }
  }
  const buf = await _voiceTtsRequest('mp3_44100_128')
  _voiceTtsFormat = 'mp3-fallback'
  return { buf, fmt: 'mp3' }
}
function _voiceTruncate(text: string, cap: number): string {
  if (text.length <= cap) return text
  const cut = text.lastIndexOf(' ', cap)
  const at = cut > cap / 2 ? cut : cap
  return text.slice(0, at) + '…'
}

// agentic-pod-launcher: askq-guard give-up delivery patch v1
const _ASKQ_GIVEUP_FILE = '/home/agent/.claude/channels/telegram/askq-guard-giveup.json'
function _checkAskqGiveup(): void {
  try {
    const fs = require('node:fs')
    if (!fs.existsSync(_ASKQ_GIVEUP_FILE)) return
    const j = JSON.parse(fs.readFileSync(_ASKQ_GIVEUP_FILE, 'utf8'))
    fs.rmSync(_ASKQ_GIVEUP_FILE, { force: true })
    const chatId = j.chat_id
    if (!chatId) return
    const giveupMsg = 'Intenté abrir un menú interactivo que no puedo mostrarte por acá; no pude completar la acción. ¿Me lo confirmas por mensaje?'
    bot.api.sendMessage(chatId, giveupMsg)
      .catch((err: any) => {
        const msg = err && (err.message || err.description || String(err))
        process.stderr.write(`telegram channel: askq-guard give-up sendMessage failed for chat ${chatId}: ${msg}
`)
      })
  } catch {}
}

// agentic-pod-launcher: pending-reply marker patch v1
const _PENDING_REPLY_FILE = '/home/agent/.claude/channels/telegram/pending-reply.json'
function _markPendingReply(chatId: string | number, updateId: number): void {
  try {
    const fs = require('node:fs')
    const path = require('node:path')
    fs.mkdirSync(path.dirname(_PENDING_REPLY_FILE), { recursive: true })
    fs.writeFileSync(_PENDING_REPLY_FILE, JSON.stringify({ chat_id: chatId, update_id: updateId, ts: Date.now() }))
  } catch {}
}
function _clearPendingReply(): void {
  try {
    const fs = require('node:fs')
    fs.rmSync(_PENDING_REPLY_FILE, { force: true })
  } catch {}
}

// agentic-pod-launcher: offset persistence patch v1
const _OFFSET_FILE = '/home/agent/.claude/channels/telegram/last-offset.json'
const _pendingUpdates = new Map<string | number, number>()
function _loadOffset(): number {
  try {
    const fs = require('node:fs')
    if (!fs.existsSync(_OFFSET_FILE)) return 0
    const j = JSON.parse(fs.readFileSync(_OFFSET_FILE, 'utf8'))
    return typeof j.offset === 'number' && j.offset > 0 ? j.offset : 0
  } catch { return 0 }
}
function _saveOffset(updateId: number): void {
  try {
    const fs = require('node:fs')
    const path = require('node:path')
    fs.mkdirSync(path.dirname(_OFFSET_FILE), { recursive: true })
    fs.writeFileSync(_OFFSET_FILE, JSON.stringify({ offset: updateId + 1, ts: Date.now() }))
  } catch {}
}
function _markPending(chatId: string | number, updateId: number): void {
  // Latest-wins per chat. Bursts of msgs collapse to the newest update_id;
  // ack-on-reply then advances offset past the burst, which is correct as long as
  // claude has consumed all of them via the MCP notifications already dispatched.
  _pendingUpdates.set(chatId, updateId)
}
function _ackPending(chatId: string | number): void {
  const updateId = _pendingUpdates.get(chatId)
  if (typeof updateId === 'number') {
    _saveOffset(updateId)
    _pendingUpdates.delete(chatId)
  }
}

// agentic-pod-launcher: typing refresh patch v6
const _typingIntervals = new Map<string | number, ReturnType<typeof setInterval>>()
const _typingTickCounts = new Map<string | number, number>()
const _typingStartedAt = new Map<string | number, number>()
const _TYPING_REFRESH_MS = 4000
// v4: hard cap on typing duration. After _TYPING_MAX_DURATION_MS without
// case 'reply' firing, abort the setInterval, send a user-facing message
// to the chat, and log to stderr. Default 5 min; override via env var.
// This prevents the "zombie typing" UX seen when claude is blocked on
// /login (OAuth expired) — without v4 the user sees the bot "thinking"
// for hours while the agent is dead.
const _TYPING_MAX_DURATION_MS = (() => {
  const raw = process.env.TELEGRAM_TYPING_MAX_MS
  const n = raw ? parseInt(raw, 10) : NaN
  return Number.isFinite(n) && n > 0 ? n : 300000
})()
function _typingKeepAlive(chat_id: string | number): void {
  _checkAskqGiveup()
  _typingStop(chat_id)
  _typingTickCounts.set(chat_id, 0)
  _typingStartedAt.set(chat_id, Date.now())
  const send = () => {
    const tick = (_typingTickCounts.get(chat_id) ?? 0) + 1
    _typingTickCounts.set(chat_id, tick)
    const started = _typingStartedAt.get(chat_id) ?? Date.now()
    const elapsed = Date.now() - started
    if (elapsed > _TYPING_MAX_DURATION_MS) {
      // Abort: stop typing, notify the user, log forensics. The
      // typical cause is OAuth expired (claude blocked on /login)
      // or a stuck MCP — both require operator intervention. v3
      // would have left the typing tick spinning indefinitely.
      _typingStop(chat_id)
      const minutes = Math.round(elapsed / 60000)
      const warnMsg = `⚠️ Llevo más de ${minutes} min sin entregar la respuesta a este chat. Puede deberse a: una respuesta larga aún en curso, a que respondí sin usar la herramienta de envío, a que el login de Claude haya expirado, o a que la sesión quedó bloqueada en un menú interactivo que el canal no puede responder. Revisa: agentctl doctor.`
      bot.api.sendMessage(chat_id, warnMsg)
        .catch((err: any) => {
          const msg = err && (err.message || err.description || String(err))
          process.stderr.write(`telegram channel: timeout-warn sendMessage failed for chat ${chat_id}: ${msg}
`)
        })
      process.stderr.write(`telegram channel: typing aborted after ${minutes}m (${tick} ticks) for chat ${chat_id}
`)
      return
    }
    _checkAskqGiveup()
    bot.api.sendChatAction(chat_id, 'typing')
      .then(() => {
        // Beat every 5 ticks (~20s) so the stderr log shows the
        // setInterval is alive without saturating it on short replies.
        if (tick === 1 || tick % 5 === 0) {
          process.stderr.write(`telegram channel: typing tick ${tick} for chat ${chat_id}
`)
        }
      })
      .catch((err: any) => {
        // v1/v2 silently swallowed errors here. v3+ surfaces them so
        // rate limits, network failures, or token issues become
        // visible in /workspace/scripts/heartbeat/logs/telegram-mcp-stderr.log.
        const msg = err && (err.message || err.description || String(err))
        process.stderr.write(`telegram channel: sendChatAction failed for chat ${chat_id} tick ${tick}: ${msg}
`)
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
  _typingStartedAt.delete(chat_id)
}

function loadAccess(): any {
  return { dmPolicy: 'open', allowFrom: ['111'], groups: {} }
}

async function handleInbound(ctx: any, text?: string, downloadImage?: any, attachment?: any) {
  const from = ctx.from!
  const chat_id = String(ctx.chat!.id)
  // agentic-pod-launcher: pending-reply marker patch v1 — record the channel turn as awaiting a reply
  if (typeof ctx.update?.update_id === 'number') _markPendingReply(chat_id, ctx.update.update_id)
  // agentic-pod-launcher: offset persistence patch v1 — mark pending update for ack-on-reply
  if (typeof ctx.update?.update_id === 'number') _markPending(chat_id, ctx.update.update_id)
  const msgId = ctx.message?.message_id
  // Typing indicator — refreshed every 4s until reply fires; aborts after _TYPING_MAX_DURATION_MS (default 5min) with user-facing warning.
  // Patched by agentic-pod-launcher (telegram-typing v6 — names interactive-prompt cause).
  _typingKeepAlive(chat_id)
}

bot.on('message', async (ctx: any) => {
  await handleInbound(ctx)
})

bot.on('message:text', async ctx => {
  // agentic-pod-launcher: voice roundtrip (032) — typed message ends the voice-origin exchange
  _voiceOriginClear(String(ctx.chat!.id))
  await handleInbound(ctx, ctx.message.text, undefined)
})

bot.on('message:voice', async ctx => {
  // agentic-pod-launcher: voice roundtrip inbound pipeline (032)
  const voice = ctx.message.voice
  const chat_id = String(ctx.chat!.id)
  const placeholder = async (suffix?: string) => {
    await handleInbound(ctx, (ctx.message.caption ?? '(voice message)') + (suffix ?? ''), undefined, {
      kind: 'voice',
      file_id: voice.file_id,
      size: voice.file_size,
      mime: voice.mime_type,
    })
  }
  if (!VOICE_ACTIVE) {
    await placeholder()
    return
  }
  const access = loadAccess()
  const from = ctx.from
  const isDm =
    ctx.chat?.type === 'private' &&
    access.dmPolicy !== 'disabled' &&
    from != null &&
    access.allowFrom.includes(String(from.id))
  if (!isDm) {
    await placeholder()
    return
  }
  if (voice.duration && voice.duration > VOICE_MAX_NOTE_SECONDS) {
    process.stderr.write(`telegram channel: voice stt skip: over-cap chat=${chat_id} dur=${voice.duration}s\n`)
    await placeholder(' (voice note over the transcription limit)')
    return
  }
  if (voice.file_size && voice.file_size > VOICE_MAX_BYTES) {
    process.stderr.write(`telegram channel: voice stt skip: over-cap chat=${chat_id} size=${voice.file_size}\n`)
    await placeholder(' (voice note over the transcription limit)')
    return
  }
  void bot.api.sendChatAction(chat_id, 'typing').catch(() => {
    process.stderr.write('telegram channel: voice typing indicator failed\n')
  })
  void (async () => {
    const started = Date.now()
    const controller = new AbortController()
    const timer = setTimeout(() => controller.abort(), 30000)
    try {
      const file = await ctx.api.getFile(voice.file_id)
      if (!file.file_path) throw new Error('no-file-path')
      const url = `https://api.telegram.org/file/bot${TOKEN}/${file.file_path}`
      const res = await fetch(url, { signal: controller.signal })
      if (!res.ok) throw new Error(`download-status-${res.status}`)
      const buf = Buffer.from(await res.arrayBuffer())
      if (buf.length > VOICE_MAX_BYTES) {
        process.stderr.write(`telegram channel: voice stt skip: over-cap chat=${chat_id} bytes=${buf.length}\n`)
        await placeholder(' (voice note over the transcription limit)')
        return
      }
      const transcript = await _voiceTranscribe(buf, controller.signal)
      if (!transcript) {
        process.stderr.write(`telegram channel: voice stt fail: empty chat=${chat_id}\n`)
        await placeholder()
        return
      }
      process.stderr.write(`telegram channel: voice stt ok chat=${chat_id} dur=${voice.duration ?? 0}s chars=${transcript.length} ms=${Date.now() - started}\n`)
      _voiceOriginSet(chat_id)
      await handleInbound(ctx, transcript, undefined, {
        kind: 'voice',
        file_id: voice.file_id,
        size: voice.file_size,
        mime: voice.mime_type,
      })
    } catch (err) {
      const { cls, status } = _voiceErrClass(err)
      process.stderr.write(`telegram channel: voice stt fail: ${cls} status=${status} chat=${chat_id}\n`)
      await placeholder()
    } finally {
      clearTimeout(timer)
    }
  })()
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
          voice_text: {
            type: 'string',
            description:
              'Optional spoken-style rendition of this reply, used to synthesize the voice bubble when the exchange is voice-originated. Plain speakable prose — no markdown, no code. When omitted, a truncated version of `text` is spoken.',
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
      'Messages whose meta carries attachment_kind="voice" arrive transcribed — the message text IS the transcription. When replying to them, include voice_text with a concise speakable version of your answer.',
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
        _typingStop(chat_id) // agentic-pod-launcher: stop typing refresh
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

        // agentic-pod-launcher: offset persistence patch v1 — ack pending update; advances disk offset only after a successful reply
        _ackPending(chat_id)
        // agentic-pod-launcher: pending-reply marker patch v1 — the reply tool fired; clear the awaiting-reply marker
        _clearPendingReply()
        const result =
          sentIds.length === 1
            ? `sent (id: ${sentIds[0]})`
            : `sent ${sentIds.length} parts`
        // agentic-pod-launcher: voice roundtrip outbound synthesis (032)
        if (VOICE_ACTIVE && VOICE_REPLY_MODE !== 'never') {
          const _voiceFresh = _voiceOriginConsume(chat_id)
          if (VOICE_REPLY_MODE === 'always' || _voiceFresh) {
            const voiceTextArg = args.voice_text as string | undefined
            const spoken = voiceTextArg && voiceTextArg.trim()
              ? voiceTextArg.trim()
              : _voiceTruncate(text, VOICE_SPOKEN_CHAR_CAP)
            const _voiceStarted = Date.now()
            const _voiceController = new AbortController()
            const _voiceTimer = setTimeout(() => _voiceController.abort(), 30000)
            try {
              const { buf, fmt } = await _voiceSynthesize(spoken, _voiceController.signal)
              await bot.api.sendVoice(chat_id, new InputFile(buf, `voice.${fmt}`))
              process.stderr.write(`telegram channel: voice tts ok chat=${chat_id} chars=${spoken.length} fmt=${fmt} ms=${Date.now() - _voiceStarted}\n`)
            } catch (err) {
              const { cls, status } = _voiceErrClass(err)
              process.stderr.write(`telegram channel: voice tts fail: ${cls} status=${status} chat=${chat_id}\n`)
            } finally {
              clearTimeout(_voiceTimer)
            }
          }
        }
        return { content: [{ type: 'text', text: result }] }
      }
  }
}

async function main() {
  for (let attempt = 1; ; attempt++) {
    try {
      // agentic-pod-launcher: offset persistence patch v1 — replay-from-disk before bot.start
      {
        const _resume = _loadOffset()
        if (_resume > 0) {
          try { await bot.api.getUpdates({ offset: _resume, limit: 1, timeout: 0 }) } catch {}
        }
      }
      await bot.start({
        onStart: () => {}
      })
      break
    } catch (e) {
      // retry
    }
  }
}
