# Contract: Stop-hook registration merge (`settings.json`)

The launcher registers the Stop hook by additively merging one entry into the USER
`settings.json` before the session starts — docker at boot, local at login. The
merge is idempotent and non-clobbering.

## The merge (jq)

```sh
# $cmd = the absolute command string, rendered per-mode:
#   docker: /workspace/scripts/hooks/stop-redeliver.sh
#   local : <workspace>/scripts/hooks/stop-redeliver.sh
jq --arg cmd "$cmd" '
    .hooks = (.hooks // {})
  | .hooks.Stop = (.hooks.Stop // [])
  | if (.hooks.Stop | any(.hooks[]?; .command == $cmd)) then .
    else .hooks.Stop += [{ hooks: [ { type: "command", command: $cmd } ] }] end
' "$settings" > "$tmp" && mv "$tmp" "$settings"
```

- The entry shape `{hooks:[{type:"command",command}]}` is **measured to fire** (the
  Phase-0 capture used exactly this and the Stop hook ran). `matcher` is optional and
  omitted.
- **Idempotent**: the `any(... .command == $cmd)` guard means re-running boot/login
  never duplicates the entry.
- **Non-clobbering**: only `.hooks.Stop` is touched. It shares no top-level key with
  `pre_accept_bypass_permissions` (`.skipDangerousModePermissionPrompt`,
  `.permissions`), `pre_accept_extra_marketplaces` (`.extraKnownMarketplaces`), or
  heartbeat (`.enabledPlugins`); jq re-emits the whole object, so untouched keys pass
  through. Any pre-existing `.hooks.Stop` entries are preserved (append, not replace).
- **Guards**: `[ -f "$settings" ] || return 0`; `command -v jq || return 0`; write to
  a tmp file then `mv` (atomic); on jq failure, drop the tmp and return 0
  (fail-silent).

## Where it runs

| Mode | Location | File written | Trigger |
| --- | --- | --- | --- |
| docker | `pre_install_stop_hook()` in `docker/scripts/start_services.sh`, called in `start_session()` right after `pre_accept_bypass_permissions` | `/home/agent/.claude/settings.json` | every boot + every watchdog respawn (self-healing) |
| local | jq step in `modules/local-login.sh.tpl` (→ `agent-login.sh`), after `CONFIG_DIR` exists | `<workspace>/.state/.claude/settings.json` | every `./setup.sh --login` (durable under `.state`) |

## Heartbeat isolation (companion)

`scripts/heartbeat/heartbeat.sh` (`ensure_heartbeat_config_dir`) builds the cron
config from the shared `settings.json`; its isolation jq must additionally
`del(.hooks.Stop)` so the redelivery hook never fires on plugin-less cron ticks. The
hook is also fail-silent on an absent marker, so a stray fire is a harmless no-op —
belt and suspenders.

## Gating (byte-identical for non-channel agents)

The render of `scripts/hooks/stop-redeliver.sh` and the injection are gated on the
Telegram plugin being present in `plugins[]` (`enabled` derived, `features.reply_guard`).
A non-channel docker agent's `--regenerate` and boot stay byte-identical (FR-012).

## Test coverage

- Host bats: the jq merge is unit-testable — apply to a fixture `settings.json` that
  already carries `permissions` + a foreign `hooks.PreToolUse`, assert `.hooks.Stop`
  gains exactly one entry, the foreign keys/hooks survive, and a second apply is a
  no-op.
- DOCKER_E2E: after boot, `~/.claude/settings.json` has the Stop entry and the
  `permissions`/`skipDangerousModePermissionPrompt` writes intact.
