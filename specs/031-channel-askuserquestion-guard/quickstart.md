# Quickstart / validation: AskUserQuestion channel guard (031)

## What it does

A Telegram-configured agent, mid-turn, that reaches for the `AskUserQuestion` tool no
longer hangs invisibly: a `PreToolUse` hook intercepts the call, denies it, and the
agent asks the question(s) as a normal Telegram reply. If the agent keeps insisting past
`max_attempts`, the operator gets one explicit give-up message instead of silence.

## Enable / configure (`agent.yml`, single source of truth)

```yaml
features:
  askuserquestion_guard:
    enabled: true        # auto-derived when a telegram@ plugin is present
    max_attempts: 1      # redirections before giving up
```

Apply: `./setup.sh --regenerate` (renders `scripts/hooks/askq-guard.sh` + installer;
byte-identical on re-run). Full activation follows the agent's next restart (docker) /
next `--login` (local), the channel through which the launcher re-applies managed
settings.

## Host validation (no Docker)

- `bats tests/askq-guard.bats` — the hook over fixture payloads:
  - channel turn (marker present) calling AskUserQuestion → deny+redirect JSON emitted,
    one stderr line;
  - console turn (marker absent) → **fail open**, no output;
  - `tool_name != AskUserQuestion` → no output;
  - loop guard → after `max_attempts`, stops *redirecting* but keeps denying with a
    terminal give-up reason (the prompt never opens) and writes the give-up marker once.
- `bats tests/askq-guard-config.bats` — backfill/derive/preserve in `--regenerate`.
- `bats tests/apply-telegram-patches.bats` — typing patch reaches **v6**; give-up hunk
  present; idempotent; fail-silent on anchor drift.
- Whole suite green on bash 3.2.57 AND 5.x; `shellcheck -S error` clean.

## The measured proof (already captured, research.md D0)

On real Claude Code 2.1.223 (≈ the image), an interactive session that calls
`AskUserQuestion` DID fire `PreToolUse`; the deny surfaced in the TUI and the model
redirected to a text answer on its own. That is the end-to-end behaviour, measured — not
assumed.

## Docker / live gates (deferred to deploy)

- `DOCKER_E2E=1 bats tests/docker-e2e-askq-guard.bats` on a Docker host: boot registers
  the PreToolUse hook, the baked patcher yields the v6 warning + give-up hunk.
- **Ferrari (donna)**: recreate; from Telegram, drive a turn that would call
  AskUserQuestion and confirm the question arrives as a text reply (not a silent hang).

## Diagnose

- Guard firing: `askq-guard: redirected AskUserQuestion …` in
  `scripts/heartbeat/logs/telegram-mcp-stderr.log`.
- Give-up: `askq-guard: gave up after …` in the same log + the operator's give-up chat
  message.
- Not firing when it should: check `features.askuserquestion_guard.enabled` in
  `agent.yml`, that the Telegram plugin is present, and that
  `~/.claude/channels/telegram/pending-reply.json` exists during a live channel turn
  (the origin signal).
