# Data Model: Channel reply-delivery guard (028)

No database. The "data" is a handful of files + one config block + the ephemeral
turn-end payload. Each entity below lists its shape, owner, lifecycle, and the
validation/idempotency rule that governs it.

## 1. Pending-reply marker (the origin + unreplied signal)

- **File**: `<workspace>/.state/.claude/channels/telegram/pending-reply.json`
  (inside the container: `/home/agent/.claude/channels/telegram/pending-reply.json`,
  `/home/agent` ↔ `.state`; same family as the existing `last-offset.json`).
- **Owner / writer**: the Telegram plugin (`server.ts`, via the patch).
- **Shape**: `{ "chat_id": <string|number>, "update_id": <number>, "ts": <epoch_ms> }`.
- **Lifecycle**:
  - *Created / overwritten* on inbound, in `handleInbound` right where
    `_markPending(chat_id, update_id)` already runs (latest-wins per chat).
  - *Deleted* on a successful reply, in `case 'reply'` where `_ackPending` already
    runs (ack-on-reply, mirroring offset persistence).
- **Invariant**: existence ⟺ "a channel message is awaiting a reply". This is the
  single fact the Stop hook keys on.
- **Reader**: the Stop-hook script (existence check + optional `ts`/`update_id` for
  the stale-marker correlation).
- **Secret rule**: contains no secrets and no message text — only ids + a timestamp.

## 2. Stop-hook turn-end payload (ephemeral, read-only)

- **Source**: Claude Code, on stdin, when a turn ends. MEASURED shape:
  `{ session_id, prompt_id, transcript_path, cwd, permission_mode, effort,
     hook_event_name:"Stop", stop_hook_active, last_assistant_message,
     background_tasks, session_crons }`.
- **Fields the guard uses**:
  - `stop_hook_active` (bool) — false ⇒ first Stop this turn (eligible to nudge);
    true ⇒ already nudged ⇒ give up (loop guard).
  - `last_assistant_message` (string) — the undelivered answer; used to (a) decide
    there IS an answer to deliver and (b) craft the corrective `reason`.
  - `transcript_path` (string) — available for the optional deterministic
    "was the reply tool called this turn?" cross-check.
- **NOT present**: any turn-origin field. This absence is the whole reason entity 1
  exists.

## 3. Reply-guard config (`features.reply_guard`)

- **Source of truth**: `agent.yml`.
  ```yaml
  features:
    reply_guard:
      enabled: true        # default: derived from telegram-plugin presence in plugins[]
      max_attempts: 1       # default 1 (clarified); >1 needs an attempt counter
  ```
- **Flattening**: `render_load_context` → `FEATURES_REPLY_GUARD_ENABLED`,
  `FEATURES_REPLY_GUARD_MAX_ATTEMPTS` (automatic; not `known_external`).
- **Derived-default rule**: `enabled` = `true` iff `plugins[]` contains an entry
  matching `^telegram@`. Set at the wizard heredoc AND backfilled in `regenerate()`
  (before `render_load_context`) so legacy/hand-edited agents converge.
- **Consumers**: `modules/stop-hook.sh.tpl` bakes `{{FEATURES_REPLY_GUARD_ENABLED}}`
  and `{{FEATURES_REPLY_GUARD_MAX_ATTEMPTS}}` directly into the rendered hook script
  (no intermediate `.conf` file); the `regenerate()` render + the settings.json
  injection are gated on `enabled`.
- **Validation**: `.features.reply_guard.enabled` ∈ `_SCHEMA_BOOLEANS`
  (fail-loud on `yes`/typo); `max_attempts` stays optional/backfilled (not a
  required leaf), like `vault.qmd.version`.

## 4. Loop / attempt state

- **Default (max_attempts = 1)**: no extra state — `stop_hook_active` alone bounds
  it to one nudge (block once; on the next Stop, `stop_hook_active == true` ⇒ exit 0).
- **If max_attempts > 1**: a tiny per-turn counter file keyed by `prompt_id`
  (`<state>/channels/telegram/reply-guard-attempts/<prompt_id>`), incremented per
  fire, compared to `max_attempts`, cleared when the marker is deleted (reply) or on
  give-up. Only built if/when a config sets `max_attempts > 1`.

## 5. Stop-hook registration (in `settings.json`)

- **File**: `~/.claude/settings.json` (docker) / `<workspace>/.state/.claude/settings.json`
  (local).
- **Shape added** (measured to fire in the capture):
  ```json
  { "hooks": { "Stop": [ { "hooks": [ { "type": "command",
        "command": "<abs path to scripts/hooks/stop-redeliver.sh>" } ] } ] } }
  ```
- **Owner**: the launcher — merged additively (jq) at docker boot (`start_services.sh`)
  / local login (`agent-login.sh`); idempotent (skips if the command already present);
  touches only `.hooks.Stop`, so it never clobbers `permissions` /
  `skipDangerousModePermissionPrompt` / `extraKnownMarketplaces` / `enabledPlugins`.
- **Heartbeat isolation**: `ensure_heartbeat_config_dir` must `del(.hooks.Stop)` so
  cron ticks never carry the hook.

## Entity relationships (flow)

```text
inbound Telegram msg ──▶ plugin writes pending-reply.json  (entity 1)
                              │
agent produces answer ────────┤
   ├─ calls plugin:telegram:telegram ─▶ plugin deletes pending-reply.json ─▶ Stop: marker absent ⇒ no-op
   └─ answers as TUI text (bug) ──────▶ marker persists ──▶ Stop hook (entity 2):
                                            marker present AND stop_hook_active=false
                                              ⇒ {decision:block, reason:"resend via the tool"} + stderr log
                                            marker present AND stop_hook_active=true
                                              ⇒ exit 0 (gave up; US2 warning covers it)
```
