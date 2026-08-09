# Contract: Pending-reply marker (Telegram plugin patch)

The marker is the channel-origin + unreplied signal the Stop hook consumes. It is
written by two new hunks in `apply_telegram_typing_patch.py`, mirroring the existing
offset-persistence hunks (same file family, same ack-on-reply timing).

## File

- Path (container): `/home/agent/.claude/channels/telegram/pending-reply.json`
  (host: `<workspace>/.state/.claude/channels/telegram/pending-reply.json`; `/home/agent` ↔ `.state`).
- Shape: `{ "chat_id": <string|number>, "update_id": <number>, "ts": <epoch_ms> }`.
- Contains NO secrets and NO message text.

## Lifecycle (mirrors offset persistence)

| Event | Existing hook point | New action |
| --- | --- | --- |
| inbound message | `handleInbound`, at `_markPending(chat_id, update_id)` (`OFFSET_MARK`) | ALSO write `pending-reply.json` = `{chat_id, update_id, ts: Date.now()}` |
| successful reply | `case 'reply'`, at `_ackPending(chat_id)` (`OFFSET_ACK`) | ALSO delete `pending-reply.json` for that chat |

- **Idempotency / marker gating**: a NEW patch marker (e.g.
  `MARKER_PENDING = "agentic-pod-launcher: pending-reply marker patch v1"`) gates the
  two hunks so the patcher is a no-op if already applied and fail-silent on anchor
  drift (logs WARN, skips only this patch) — the established `apply_telegram_typing_patch.py`
  convention.
- **Latest-wins**: like `_markPending`, a burst collapses to the newest `update_id`.
- **Crash-safety**: writes best-effort (`try/catch`, like `_saveOffset`); a failed
  write leaves no marker → the guard simply doesn't fire (fail-safe direction).

## Why on disk (not the existing in-memory `_pendingUpdates` Map)

The plugin already tracks pending in memory (`_pendingUpdates`), but that lives in
the `bun server.ts` process; the Stop hook runs in the Claude process and cannot
read it. A tiny disk marker is the cross-process handoff — and it is exactly the
same pattern the offset patch already uses (`last-offset.json`).

## Test coverage

- `tests/apply-telegram-patches.bats`: applying the patch to a fixture `server.ts`
  inserts both hunks (write on inbound anchor, delete on reply anchor), is
  idempotent (second run no-ops on the marker), and fail-silent when an anchor is
  edited out-of-band.
- DOCKER_E2E (integration): an inbound that IS replied to leaves no marker; an
  inbound answered as TUI text leaves the marker present at Stop time.
