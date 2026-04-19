# Adding a notifier

Heartbeat notifications are pluggable. To add a new channel (e.g. Discord, Slack, email):

## 1. Create the driver

Create `scripts/heartbeat/notifiers/<channel>.sh` that implements a function `notify_<channel>()` taking `$1` as the message:

```bash
#!/usr/bin/env bash
# scripts/heartbeat/notifiers/discord.sh
notify_discord() {
  local msg="$1"
  [ -z "${NOTIFY_DISCORD_WEBHOOK:-}" ] && return 0
  curl -s -H "Content-Type: application/json" \
    -d "{\"content\":\"$msg\"}" \
    "$NOTIFY_DISCORD_WEBHOOK" > /dev/null 2>&1 || true
}
```

## 2. Register in the wizard

In `setup.sh`, the notifications step uses `ask_choice` with a space-separated list of channels. Add your channel name:

```bash
notify_channel=$(ask_choice "Notification channel" "none" "none log telegram discord")
```

Inside the conditional branch for your channel, prompt for any credentials and write them to `.env`.

## 3. Add env vars to `.env` template

Update `modules/env-example.tpl` with a conditional block for your channel's secrets:

```
{{#if NOTIFICATIONS_CHANNEL_IS_DISCORD}}
# Discord notifications
NOTIFY_DISCORD_WEBHOOK=
{{/if}}
```

Add an `export NOTIFICATIONS_CHANNEL_IS_DISCORD=...` in `setup.sh`'s `regenerate()` function next to the existing `NOTIFICATIONS_CHANNEL_IS_TELEGRAM` line.

## 4. Add a test

In `tests/notifiers.bats`:

```bash
@test "notify_discord is no-op without webhook" {
  unset NOTIFY_DISCORD_WEBHOOK
  source "$REPO_ROOT/scripts/heartbeat/notifiers/discord.sh"
  run notify_discord "hello"
  [ "$status" -eq 0 ]
}
```

## 5. Document it

Add an entry here describing the channel and its credential requirements.
