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
