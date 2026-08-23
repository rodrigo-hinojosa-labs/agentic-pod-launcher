# Contract: PreToolUse guard I/O (`scripts/hooks/askq-guard.sh`)

Rendered from `modules/askq-guard.sh.tpl`. Runs as `agent`. Registered under
`.hooks.PreToolUse` with `matcher:"AskUserQuestion"`. Fail-silent (exit 0 on every
path). Contract verified against the measured 2.1.223 payload (research.md D0).

## Input (stdin: PreToolUse JSON)

Relevant fields: `tool_name`, `prompt_id` (fallback `session_id`). See data-model.md §1.

## Config (baked at render time)

- `_ENABLED` = `{{FEATURES_ASKUSERQUESTION_GUARD_ENABLED}}` — `"true"` else no-op.
- `_MAX` = `{{FEATURES_ASKUSERQUESTION_GUARD_MAX_ATTEMPTS}}` — non-numeric/absent → 1.

## Decision table

| # | Condition | Output (stdout) | Exit | stderr |
|---|---|---|---|---|
| C1 | `_ENABLED != true` | *(nothing)* | 0 | — |
| C2 | `jq` absent / stdin empty / not JSON | *(nothing → allow)* | 0 | — |
| C3 | `tool_name != AskUserQuestion` | *(nothing → allow)* | 0 | — |
| C4 | marker `pending-reply.json` **absent** (console / local / replied) | *(nothing → allow)* — **FAIL OPEN** | 0 | — |
| C5 | marker present, attempts `< _MAX` | deny+**redirect** JSON (below); increment counter | 0 | `askq-guard: redirected AskUserQuestion (chat <id>, attempt <n>)` |
| C6 | marker present, attempts `>= _MAX` | deny+**terminal give-up** JSON (below); write give-up marker (once, if absent) | 0 | `askq-guard: gave up after <n> (chat <id>) — interactive prompt not answerable in channel` |

**C5 deny JSON — redirect** (exit 0). Invites the model onto the reply tool:

```json
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"You are answering a Telegram channel turn. AskUserQuestion opens a console-only menu the operator cannot see or answer. Ask your question(s) as ordinary text by calling the plugin:telegram:telegram tool now, with the options spelled out."}}
```

**C6 deny JSON — terminal give-up** (exit 0). Tells the model to STOP retrying the tool:

```json
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"AskUserQuestion cannot be answered from a Telegram channel, and you have already been redirected the maximum number of times this turn. Do not call this tool again. Answer the operator in plain text via the plugin:telegram:telegram tool, or end your turn. The operator is being told separately that an unsupported interactive prompt was attempted."}}
```

Fallback if `jq` construction fails: a fixed literal of the same shape (never echoes
input, never a secret).

**Key subtlety (C6) — deny-terminal, not allow.** At the cap the guard MUST NOT
allow the tool through: allowing it would open the console-only menu and reintroduce
the exact silent hang this feature prevents (violating SC-001). Instead it keeps
**denying** — so the prompt never opens — but swaps the *redirect* reason for a
*terminal* one ("do not call this tool again"). What is bounded is the number of
**redirections** (`max_attempts`), not the number of interceptions: the interception
continues for the rest of the turn, which is precisely what guarantees no hang. This
is not the loop the loop-guard exists to prevent — a loop is the model retrying AUQ in
response to a *redirect*; the terminal reason no longer invites a retry, and each deny
is O(1) with no state growth. The give-up marker is written once (only if absent) so
the plugin delivers exactly one honest give-up message (contract
`giveup-and-warning.md`), independent of whether the model complies.

## Loop guard

No `stop_hook_active` exists for PreToolUse (measured). The counter file
`${state}/askq-guard-attempts/<prompt_id>` is the bound on **redirections** (C5). Key
sanitized to `[A-Za-z0-9._-]`. Past the cap the guard does not keep incrementing or
redirecting; it emits the terminal C6 deny and writes the give-up marker once. The
prompt never opens on any path, so the turn cannot hang while the guard is active.

## Invariants

- Exits 0 on EVERY path (Principle IV) — never crashes the session.
- Reads no secret; logs only chat id + attempt count (Principle V).
- Emits a deny decision in C5 (redirect) and C6 (terminal give-up); C1–C4 are
  silent-allow (fail open, spec FR-004). The console-only prompt is never allowed to
  open once a channel origin is confirmed (C5/C6) — that is what forecloses the hang.
- Never posts to the channel itself (Q1 / Principle II); the give-up chat message is
  the plugin's job, triggered by the give-up marker.
