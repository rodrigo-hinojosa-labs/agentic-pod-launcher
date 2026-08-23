# Data Model: Channel interactive-prompt (AskUserQuestion) guard

**Feature**: 031-channel-askuserquestion-guard | **Date**: 2026-08-19

This feature is filesystem-and-signals, not a database. The "entities" are the data
artifacts the guard reads and writes. All paths are under the agent's
`~/.claude/channels/telegram/` (bind-mounted `.state/`, Principle V).

## 1. PreToolUse hook input (read; provided by Claude Code)

The JSON Claude Code pipes to the hook on stdin before a tool runs. Fields present
(measured on 2.1.223, `permission_mode=auto`):

| Field | Type | Use in 031 |
|---|---|---|
| `hook_event_name` | string | Always `"PreToolUse"`. |
| `tool_name` | string | Guard fires only when `== "AskUserQuestion"`. |
| `tool_input` | object | `{questions:[…]}` for AUQ; not needed by the guard (redirect is generic). |
| `prompt_id` | string | Primary loop-guard counter key. |
| `session_id` | string | Fallback counter key. |
| `tool_use_id` | string | Available; not required. |
| `permission_mode` | string | Observed `auto`; not a decision input. |
| `cwd`, `transcript_path`, `effort` | string/obj | Present; unused. |
| *(origin)* | — | **Absent.** No field distinguishes channel vs console (see origin marker). |

Validation: if stdin is empty or not JSON → fail-silent no-op (exit 0). `jq` absent →
no-op.

## 2. Origin marker `pending-reply.json` (read; owned by the 028 plugin patch)

- **Path**: `${REPLY_GUARD_MARKER:-${HOME}/.claude/channels/telegram/pending-reply.json}`
- **Owner/lifecycle**: written by the Telegram plugin on inbound, deleted on the reply
  tool (028, `apply_telegram_typing_patch.py` `MARKER_PENDING`). Present during a
  blocked/in-flight channel turn.
- **Meaning for 031**: present ⇒ the current turn is channel-originated and unreplied ⇒
  guard is eligible. Absent/unreadable ⇒ console / local relay / already-replied ⇒
  **fail open** (allow the prompt).
- **Fields used**: `.chat_id` (for the give-up marker and the stderr trace). Never
  logged beyond the chat id.

## 3. Attempt counter (read/write; owned by 031)

- **Path**: `${state}/askq-guard-attempts/<key>` where `<key>` is `prompt_id`
  sanitized to `[A-Za-z0-9._-]` (fallback `session_id`, then `unknown`).
- **Value**: a small integer, the number of **redirections** already issued for this
  turn (C5 outputs). It bounds redirections, not interceptions.
- **Transitions**: absent/non-numeric → 0; while `n < max_attempts` each interception
  emits a redirect and does `n → n+1`. At `n >= max_attempts` the guard stops
  redirecting and instead emits the **terminal give-up deny** (C6) and writes the
  give-up marker once (entity 4). The prompt is never allowed to open on either path —
  what changes at the cap is the deny *reason* (redirect → terminal), not whether the
  guard denies.
- **Note**: with `max_attempts = 1` (default) the counter is effectively a one-shot;
  the file still records the single attempt so a same-turn retry lands in C6.

## 4. Give-up marker `askq-guard-giveup.json` (write by 031 hook; read/clear by plugin)

- **Path**: `${state}/askq-guard-giveup.json`
- **Written by**: the hook, once, the first time the attempt counter reaches
  `max_attempts` (write only if absent, so repeated C6 fires never rewrite or spam it).
- **Fields**: `{ chat_id, prompt_id, ts }` — chat id to address the message, prompt id
  for idempotency, timestamp. No secrets, no question text.
- **Read/cleared by**: the plugin-side patch (the typing keep-alive already owning
  `bot.api.sendMessage`), at two pinned triggers — **on every keep-alive tick** (the
  in-turn path; the C6 terminal deny keeps the turn running, so a tick reliably fires
  after the marker is written) and **on keep-alive (re)start for the next inbound turn**
  (the safety net for a marker written after the last tick). It delivers exactly one
  give-up chat message and deletes the marker; delete-on-send makes the two triggers
  mutually exclusive (whichever runs first clears it). Deterministic, independent of
  model compliance (Principle II: the hook never sends to the channel). See contract
  `giveup-and-warning.md` A.

## 5. stderr trace (append-only; observability)

- **Path**: `${REPLY_GUARD_STDERR_LOG:-/workspace/scripts/heartbeat/logs/telegram-mcp-stderr.log}`
  (the same sink 028 and the typing instrumentation use).
- **Content**: one line per interception — `askq-guard: redirected AskUserQuestion
  (chat <id>, attempt <n>)`; one line on give-up. Never the question text, never a
  secret (Principle V).

## 6. Config (`agent.yml`; single source of truth)

```yaml
features:
  askuserquestion_guard:
    enabled: <bool>       # derived: telegram plugin present in plugins[]
    max_attempts: <int>   # default 1
```

- Flattened by `render.sh` to `FEATURES_ASKUSERQUESTION_GUARD_ENABLED` /
  `FEATURES_ASKUSERQUESTION_GUARD_MAX_ATTEMPTS`, baked into the rendered hook via
  `{{…}}` (no `.conf`, mirrors 028).
- Backfilled in `regenerate()` with `has()` (not `//`, to preserve an operator `0`/false),
  `enabled` derived from a `^telegram@` entry in `plugins[]`.
- Disabled ⇒ the hook is not rendered / no-ops; an agent with no channel gains nothing
  (SC-006).

## Relationships

```
Claude Code ──PreToolUse(AskUserQuestion)──▶ [askq-guard hook]
                                               │ reads pending-reply.json (origin)
                                               │ reads/writes attempt counter
                                               ├─ present + under cap ─▶ deny+redirect (stdout) + stderr line
                                               ├─ present + at cap ────▶ deny+terminal give-up (stdout) + write giveup marker once + stderr line
                                               └─ absent ──────────────▶ fail open (allow)
                                             (prompt never opens on either present-path → no hang)

[plugin typing keep-alive] ──on each tick AND on next-turn (re)start──▶ reads askq-guard-giveup.json
                            ──if present──▶ bot.api.sendMessage(chat) + delete marker (once)
                            ──(v6)──▶ warning names the interactive-prompt cause
```
