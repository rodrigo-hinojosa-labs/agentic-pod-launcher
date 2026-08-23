# Contract: give-up delivery + typing warning v6 (image-baked plugin patch)

Both live in `docker/scripts/apply_telegram_typing_patch.py` (docker scope, image-baked;
takes effect on rebuild). Idempotent via version/marker comments, fail-silent on anchor
drift (Principle IV).

## A. Give-up message delivery (US1 give-up path, Q2)

The plugin's typing keep-alive already owns the channel send path
(`bot.api.sendMessage(chat_id, warnMsg)`, `apply_telegram_typing_patch.py:165`). A new
patch hunk makes it check for the give-up marker `askq-guard-giveup.json`
(data-model.md §4) and deliver it.

**Delivery trigger (pinned — do not leave to "tick or turn end").** The check runs at
two points, so a give-up is never lost to a timing race (SC-001):

1. **On every keep-alive tick** — the primary path. The marker is written mid-turn by
   the hook (during a PreToolUse, while the model is still working and the typing
   indicator is therefore active), so at least one tick fires between the marker write
   and the turn's `_typingStop`. This delivers the message in-turn in the common case.
2. **On keep-alive (re)start for the next inbound turn** — the safety net. If a marker
   was written in the narrow window after the last tick and before turn end (so tick #1
   never saw it), the next turn's keep-alive startup picks it up and delivers it before
   doing anything else. This closes the "turn ended before its tick" race.

At either trigger, if the marker is present and its `chat_id` matches: send exactly one
message — *"Intenté abrir un menú interactivo que no puedo mostrarte por acá; no pude
completar la acción. ¿Me lo confirmas por mensaje?"* (wording is an implementation
detail) — then delete the marker. Deletion is the idempotency key: one message per
give-up, and the two triggers can never double-send because the first to run clears the
marker. Never include the question text or a secret.

Note: because the C6 guard decision is now a terminal **deny** (the prompt never opens,
`pretooluse-guard-io.md` C6), the turn keeps running after the marker is written — the
model gets the terminal reason and produces text or ends. That makes trigger 1 the
overwhelmingly common path; trigger 2 exists only for the pathological same-instant
race.

Invariants:
- The **hook never sends** (Q1 / Principle II); only the plugin, via its existing path,
  sends. No new capability.
- Fail-silent: a malformed/absent marker is a no-op on both triggers.
- Exactly one delivery per marker, guaranteed by delete-on-send across both triggers.

## B. Typing warning v6 (US2)

Bump `MARKER_TYPING` v5 → v6 and add `upgrade_typing_v5_to_v6`, mirroring the
`upgrade_typing_v4_to_v5` cascade (`apply_telegram_typing_patch.py:522`). The warning
string (around `:114-121`) gains one cause without asserting a single definite one:

- Before (v5): names slow-turn / answered-without-the-tool / expired-login + a
  diagnostic.
- After (v6): additionally names *"la sesión quedó bloqueada en un menú interactivo que
  el canal no puede responder"*.

Invariants:
- Idempotent: v6 marker prevents re-apply; the cascade `v1→…→v6` ratchets any prior
  version up transparently on boot.
- Fail-silent if the `warnMsg` anchor drifted (logs WARN, leaves the file at the highest
  matching version).
- Docker-only; does not change local-mode behaviour.

## C. Coverage (bats, mirrors `tests/apply-telegram-patches.bats`)

| Test | Expect |
|---|---|
| patcher applied to a v5 fixture | `MARKER_TYPING` becomes v6; warning names the interactive-prompt cause |
| patcher applied twice | idempotent (no second v6 apply) |
| `warnMsg` anchor removed | fail-silent WARN, no crash, file left at highest match |
| give-up hunk anchor present | give-up read/send/clear hunk inserted, gated by its own marker |

## D. DOCKER_E2E (gated, deferred to a Docker host — tasks T-final)

On the pinned image: (E1) boot registers `.hooks.PreToolUse` with matcher
`AskUserQuestion` and the rendered `askq-guard.sh` is present; (E2) the baked
`apply_telegram_typing_patch.py` yields a v6 warning; (E3) the give-up hunk is present in
the patched `server.ts`. The live interactive interception itself is re-confirmed by the
ferrari deploy gate (recreate donna; a channel turn that calls AskUserQuestion is
redirected to a text reply).
