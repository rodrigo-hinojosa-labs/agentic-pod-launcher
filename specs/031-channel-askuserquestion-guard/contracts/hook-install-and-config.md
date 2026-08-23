# Contract: hook registration + `agent.yml` config

## settings.json registration (additive, idempotent)

The PreToolUse hook is registered exactly like 028's Stop hook, but under a different
event and with a matcher. Reuses the `modules/stop-hook-install.sh.tpl` jq-merge shape
(generalized to take an event + optional matcher, or a sibling installer — a tasks
decision). Required merge result:

```json
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "AskUserQuestion",
        "hooks": [ { "type": "command", "command": "<abs>/scripts/hooks/askq-guard.sh" } ] }
    ]
  }
}
```

Invariants (mirror 028's installer):
- Touch ONLY `.hooks.PreToolUse`; never clobber `permissions`,
  `skipDangerousModePermissionPrompt`, `enabledPlugins`, `.hooks.Stop`, or any existing
  PreToolUse entry.
- Idempotent: re-running does not duplicate the entry (guard on the command string).
- Fail-silent, exit 0; base `{}` if settings.json absent.

## Install invocation points (both modes, like 028)

- **Docker boot**: `docker/scripts/start_services.sh` — alongside
  `pre_install_stop_hook` (after `pre_accept_bypass_permissions`). Gated on
  `FEATURES_ASKUSERQUESTION_GUARD_ENABLED`.
- **Local login**: `scripts/local/agent-login.sh` — same install call.
- **Heartbeat isolation**: the isolated heartbeat config already drops `.hooks.Stop`;
  it MUST also drop `.hooks.PreToolUse` so cron ticks never carry the guard.

## `agent.yml` config (single source of truth, Principle I)

```yaml
features:
  askuserquestion_guard:
    enabled: <bool>        # default derived from telegram plugin presence
    max_attempts: <int>    # default 1
```

- **Heredoc default** in `setup.sh` wizard output (mirrors `features.reply_guard` at
  `setup.sh:1230`).
- **Backfill in `regenerate()`** using `has()` (NOT `//` — preserves an operator's
  explicit `false`/`0`), pattern of `setup.sh:2072-2083`. `enabled` derived from a
  `^telegram@` entry in `plugins[]`.
- **Render gate**: the hook script + installer are rendered only when
  `FEATURES_ASKUSERQUESTION_GUARD_ENABLED=true` (pattern `setup.sh:2337-2345`).
- **Regenerate-safety**: two `--regenerate` runs produce byte-identical output; an
  agent without a Telegram channel renders no guard (SC-006).

## Config test matrix (host bats, mirrors `tests/reply-guard-config.bats`)

| Case | Expect |
|---|---|
| pre-031 workspace, telegram plugin present, `--regenerate` | backfills `enabled=true`, `max_attempts=1` |
| pre-031 workspace, no telegram plugin, `--regenerate` | backfills `enabled=false` |
| operator-set `enabled:false, max_attempts:2` preserved across `--regenerate` | unchanged (`has()` guard) |
| enabled → `scripts/hooks/askq-guard.sh` + installer rendered; disabled → absent | render gate |
