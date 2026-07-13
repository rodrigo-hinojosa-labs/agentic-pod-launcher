# Adding a notifier

Heartbeat notifications are pluggable. This doc covers the notifier contract and
every registration point a new channel (e.g. Discord, Slack, email) must touch.
Verified against v0.12.0.

**Mode applicability:** heartbeat ticks are scheduled by the container's `crond`
(`docker/crontab.tpl` runs `/workspace/scripts/heartbeat/heartbeat.sh`), so notifiers
fire in **docker mode only**. Local mode has no heartbeat scheduler — there is no
`local-heartbeat` unit template in `modules/` and no heartbeat entry in
`scripts/lib/local_schedule.sh` (local mode's own systemd units cover qmd reindex,
vault backup, wiki-graph and healthcheck; the healthcheck pings Telegram directly from
`modules/local-healthcheck.sh.tpl`, bypassing this notifier contract entirely).

## The contract

A notifier is a **standalone executable script**, not a sourced function.
`invoke_notifier` in `scripts/heartbeat/heartbeat.sh` runs it per tick as:

```bash
printf '%s' "$msg" | bash notifiers/${NOTIFY_CHANNEL}.sh "$run_id" "$status"
```

- `$1` = run id, `$2` = status (`ok`, `timeout` or `error`). The **message arrives on
  stdin**, not as an argument. On `ok` the message is claude's own stdout from the tick;
  on `timeout`/`error` it is a canned one-liner. A fourth status, `skipped` (a prior
  heartbeat session was still alive), does **not** invoke the notifier at all — the tick
  records the default `none` envelope.
- The script must **always exit 0** and print a one-line JSON envelope on stdout:
  `{"channel": "<name>", "ok": true|false, "latency_ms": <int>, "error": null|"<string>"}`.
  Delivery failures are reported inside the envelope (`ok: false` + `error`), never via exit code.
- stderr is discarded. A non-zero exit is recorded as `"notifier script failed"`;
  stdout that fails `jq empty` is recorded as `"notifier emitted non-JSON"`. Either way
  the error envelope — not yours — lands in the tick's `logs/runs.jsonl` record
  (`notifier` field) and `state.json`'s `last_run`.
- If `notifiers/${NOTIFY_CHANNEL}.sh` is missing or not executable, `heartbeat.sh`
  silently falls back to `none.sh` — `chmod +x` your driver.

`NOTIFY_CHANNEL` comes from `scripts/heartbeat/heartbeat.conf`, rendered from
`agent.yml` `.notifications.channel` (`modules/heartbeat-conf.tpl`, and rewritten by
`heartbeatctl reload`). The shipped drivers — `none.sh`, `log.sh`, `telegram.sh` in
`scripts/heartbeat/notifiers/` — are the reference implementations (as of v0.12.0).

## 1. Create the driver

Create `scripts/heartbeat/notifiers/<channel>.sh` modeled on `log.sh` or `telegram.sh`:

```bash
#!/usr/bin/env bash
# discord — post message to a Discord webhook. Always exits 0.
set -u

RUN_ID="${1:-unknown}"
STATUS="${2:-unknown}"
msg=$(cat)   # message arrives on stdin

start_ns=$(date +%s%N 2>/dev/null || date +%s000000000)

if [ -z "${NOTIFY_DISCORD_WEBHOOK:-}" ]; then
  printf '{"channel":"discord","ok":false,"latency_ms":0,"error":"missing webhook"}\n'
  exit 0
fi

http_code=$(jq -cn --arg c "[$RUN_ID] [$STATUS] $msg" '{content:$c}' \
  | curl -sS --max-time 10 -o /dev/null -w '%{http_code}' \
    -H "Content-Type: application/json" -d @- "$NOTIFY_DISCORD_WEBHOOK" 2>/dev/null || true)

end_ns=$(date +%s%N 2>/dev/null || date +%s000000000)
latency_ms=$(( (end_ns - start_ns) / 1000000 ))

case "$http_code" in
  2*) printf '{"channel":"discord","ok":true,"latency_ms":%d,"error":null}\n' "$latency_ms" ;;
  *)  printf '{"channel":"discord","ok":false,"latency_ms":%d,"error":"HTTP %s"}\n' "$latency_ms" "${http_code:-000}" ;;
esac
exit 0
```

Make it executable (`chmod +x`). Notifier scripts are **workspace-templated**: the
scaffold copies the launcher's `scripts/` tree verbatim into the workspace (`cp -R`,
then `chmod +x` on every `scripts/**/*.sh`). Docker mode: the workspace is bind-mounted
at `/workspace`, so driver changes need **no image rebuild** — the next tick picks them up.

## 2. Extend the schema enum

`scripts/lib/schema.sh` hard-codes the allowed channels in `_SCHEMA_ENUMS` (as of v0.12.0):

```bash
'.notifications.channel=none,log,telegram'
```

Add your channel here. `setup.sh` sources `schema.sh` (line 11) but only *runs* the
validator (`validate_agent_yml_required` → `agent_yml_validate`) under `--regenerate` and
`--non-interactive` — the interactive wizard path writes `agent.yml` itself and never
validates it. So a missing enum entry does not break the scaffold run; it surfaces later,
when an `agent.yml` carrying `channel: discord` fails validation and `--regenerate` aborts.

This validator is host-side and mode-agnostic: `scripts/lib/schema.sh` is the only copy
(the Dockerfile never bakes it into the image), so one edit covers both modes. The
container has no view of this enum — `heartbeatctl` carries its own allowlist, which is
why step 3 is a separate edit.

## 3. Extend `heartbeatctl`

Docker mode only — `heartbeatctl` is the in-container CLI, and local-mode workspaces
never receive the `docker/` tree at all (the scaffold skips it), nor a heartbeat unit.

`_v_notifier` in `docker/scripts/heartbeatctl` allowlists `none|log|telegram` (as of
v0.12.0); extend the `case` (and the `set-notifier <none|log|telegram>` usage line) or
`heartbeatctl set-notifier discord` is rejected with `invalid notifier`.

Unlike the driver, `heartbeatctl` is **image-baked** at `/opt/agent-admin` — this change
requires an image rebuild (`docker compose build`), while the driver from step 1 does not.

## 4. Register in the wizard

The wizard is shared by both modes, but the heartbeat section only matters for docker
mode. `setup.sh` lists the channels in four places (~line numbers as of v0.12.0) — update
all of them:

- the channel help text under `▸ Heartbeat notifications` (~line 615);
- the prompt: `notify_channel=$(ask_choice "Heartbeat notification channel" "none" "none log telegram")` (~line 626);
- the review summary line `13) Heartbeat notif:` (~line 905);
- the review/edit menu entry `13)` (~line 1027).

The answer is written to `agent.yml` as `.notifications.channel` (~line 1173). Inside the
conditional branch for your channel (see the `telegram` branch right after the prompt),
collect any credentials and write them to `.env`.

## 5. Add env vars to the `.env` template

Add a conditional block for your channel's secrets to `modules/env-example.tpl`:

```text
{{#if NOTIFICATIONS_CHANNEL_IS_DISCORD}}
# Discord notifications
NOTIFY_DISCORD_WEBHOOK=
{{/if}}
```

Then derive the flag in `setup.sh::regenerate()` under `# Derived env vars not in YAML`,
next to the existing `NOTIFICATIONS_CHANNEL_IS_TELEGRAM` export (the scaffold path calls
`regenerate()`, so one export covers both first-run and `--regenerate`).

Docker mode: compose loads the workspace `.env` into the container environment
(`env_file: ./.env`). Drivers read their secrets straight from that environment —
`telegram.sh` takes `NOTIFY_BOT_TOKEN` / `NOTIFY_CHAT_ID` from env, `log.sh` takes the
optional `NOTIFY_LOG_FILE` — so a `NOTIFY_DISCORD_WEBHOOK` in `.env` needs no further
wiring. `heartbeat.conf` merely passes the two Telegram vars through; a new channel's
vars need no `heartbeat-conf.tpl` change.

## 6. Add a test

`tests/notifiers.bats` tests the real contract — run the script with run id/status
args and the message on stdin, then assert the envelope with `jq`:

```bash
@test "discord.sh reports ok=false when webhook missing" {
  unset NOTIFY_DISCORD_WEBHOOK
  run bash "$REPO_ROOT/scripts/heartbeat/notifiers/discord.sh" "run-1" "ok" <<<"hello"
  [ "$status" -eq 0 ]
  json="$output"
  run jq -r '.channel' <<<"$json"; [ "$output" = "discord" ]
  run jq -r '.ok' <<<"$json"; [ "$output" = "false" ]
}
```

Do not `source` the script or call a `notify_*` function — nothing in the runtime does.
`tests/heartbeatctl.bats` also asserts that an unknown channel is rejected
(`set-notifier carrier-pigeon`); a new channel makes that allowlist longer, not weaker.

## 7. Document it

Add an entry here describing the channel and its credential requirements.

## Switching channels after scaffold

The wizard is only the scaffold-time path. **Docker mode**, on a running workspace:

```bash
./scripts/agentctl heartbeat set-notifier discord
```

`agentctl heartbeat …` is a proxy for `docker exec -u agent <agent> heartbeatctl …`.
`set-notifier` validates against `_v_notifier` (step 3), writes `.notifications.channel`
to `agent.yml` (with `agent.yml.prev` rollback), and auto-runs `reload`, which rewrites
`heartbeat.conf`'s `NOTIFY_CHANNEL` — no separate reload needed. See
[heartbeatctl.md](heartbeatctl.md).

**Local mode:** there is no equivalent. `agentctl heartbeat` in a local workspace only
accepts `qmd-reindex`, `backup-vault` and `wiki-graph`; anything else (including
`set-notifier`) exits 2 with the systemd hint. Changing `.notifications.channel` by hand
in `agent.yml` + `./setup.sh --regenerate` still rewrites `heartbeat.conf` (the render is
gated on `features.heartbeat.enabled`, not on mode), but nothing schedules a tick — see
the mode note at the top.
