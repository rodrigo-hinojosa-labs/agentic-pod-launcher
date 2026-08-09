# Contract: Stop-hook I/O (`scripts/hooks/stop-redeliver.sh`)

The hook is a bash script invoked by Claude Code at turn-end with the Stop payload
on **stdin** and no args. It decides whether to re-inject a corrective instruction.
This contract is the oracle for `tests/stop-hook-guard.bats`.

## Inputs

- **stdin**: JSON (measured shape) — the fields the hook reads:
  - `stop_hook_active` (bool)
  - `last_assistant_message` (string, may be empty)
  - `transcript_path` (string; optional cross-check)
- **Environment / config**: reads the rendered runtime conf (`REPLY_GUARD_ENABLED`,
  `REPLY_GUARD_MAX_ATTEMPTS`) and locates the marker at
  `<state>/channels/telegram/pending-reply.json`. The state root is resolved from a
  known env/config (test-injectable, e.g. `REPLY_GUARD_STATE_DIR`).

## Decision table

| Marker present? | `stop_hook_active` | answer present? | Output | Exit |
| --- | --- | --- | --- | --- |
| no | any | any | (nothing) | 0 |
| yes | true | any | (nothing) | 0 — already nudged, give up (loop guard) |
| yes | false | yes | `{"decision":"block","reason":"…resend via plugin:telegram:telegram now"}` on stdout + one stderr line | 0 |
| yes | false | no (empty `last_assistant_message`) | (nothing) | 0 — nothing to deliver |
| guard disabled (`REPLY_GUARD_ENABLED != true`) | any | any | (nothing) | 0 |
| any error (bad JSON, missing conf, unreadable marker, no jq) | — | — | (nothing) | 0 — **fail-silent** |

- The `reason` MUST instruct the agent to resend its last answer through the
  `plugin:telegram:telegram` tool. It MUST NOT contain the message text verbatim
  beyond what is necessary, and MUST NOT contain secrets.
- The stderr line is a single fixed-format entry (e.g.
  `reply-guard: re-injected reply-tool nudge (chat <id>, attempt N)`) written to the
  plugin stderr sink, so it is greppable and never echoes the answer text.

## Output protocol (measured + doc-confirmed)

- **Re-inject**: `exit 0` with `{"decision":"block","reason":"…"}` on **stdout**.
  Claude Code continues the turn and feeds `reason` to the agent as context.
- **Do nothing**: `exit 0` with empty stdout.
- The hook MUST NEVER `exit` non-zero (that would surface a blocking error to the
  session; fail-silent is exit 0).

## Loop guard

- Default `max_attempts = 1`: rely solely on `stop_hook_active`. First Stop with a
  present marker → block (attempt 1). Claude re-runs the turn; the next Stop has
  `stop_hook_active == true` → the hook exits 0 → the turn ends. Bounded.
- `max_attempts > 1`: additionally consult a per-`prompt_id` attempt counter file;
  block only while `count < max_attempts`; still honour `stop_hook_active` as the
  hard backstop.

## Required test cases (FR-010 → `tests/stop-hook-guard.bats`)

1. **Channel turn, reply tool called** → marker ABSENT (plugin deleted it) →
   hook emits nothing, exit 0. *(no corrective action)*
2. **Channel turn, reply NOT called** → marker PRESENT, `stop_hook_active=false`,
   `last_assistant_message` non-empty → hook emits `{"decision":"block",…}` exactly
   once + one stderr line, exit 0. *(exactly one re-injection)*
3. **Console turn** → marker ABSENT → hook emits nothing, exit 0. *(never fires)*
4. **Loop guard** → marker PRESENT, `stop_hook_active=true` → hook emits nothing,
   exit 0. *(gives up after max attempts, no second re-inject)*

Plus fail-silent coverage: malformed stdin / missing conf / disabled toggle → exit
0, no output.
