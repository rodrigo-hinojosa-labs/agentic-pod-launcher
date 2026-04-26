# Getting Started

Each agent runs inside its own Docker container with all state stored under the workspace directory (`<workspace>/.state/`, bind-mounted to `/home/agent`). Teardown is clean and reversible: `./setup.sh --uninstall --nuke` removes all traces of the agent from the host.

See [Docker Architecture](architecture.md) for the technical design.

## Prerequisites

- Docker v24+ (for `compose v2` integration)
- Docker Compose v2 (bundled with Docker Desktop; available separately on Linux)
- ~2GB disk for the image and the workspace combined
- Bash 4+ on the host (for the installer wizard)

## Scaffold

Run the installer wizard:

```bash
./setup.sh                          # interactive — prompts for destination
./setup.sh --destination ~/my-agent # skip the destination prompt
```

The wizard is interactive and runs on the host:

1. Agent name (e.g. `claude-dev`).
2. Personality and description.
3. Optional MCPs (Playwright, GitHub, Atlassian, etc.).
4. Notification channel (Telegram).

**Important:** Sensitive tokens (Telegram bot token, chat ID, GitHub PAT) are **not** requested here. They are deferred to the container's first-run wizard.

Output:

- `~/agents/<name>/` — workspace with `agent.yml`, `docker-compose.yml`, and scripts.
- `/etc/systemd/system/agent-<name>.service` — host unit to manage the container.
- On-screen instructions for next steps.

## First Boot

After scaffolding, start the agent:

```bash
cd ~/agents/<name>
docker compose build
docker compose up -d
```

The in-container supervisor (`start_services.sh`) runs as PID 1 and launches Claude Code inside a detached tmux session. To reach the user-facing session, use `docker exec` + `tmux attach` — NOT `docker attach`, which only shows supervisor logs:

```bash
docker exec -it -u agent <name> tmux attach -t agent
```

Detach from tmux without killing the session with `Ctrl-b d` (standard tmux binding).

## 1. Log in to Claude

Inside the tmux session:

1. Pick a theme (Enter accepts the default) and confirm trust on `/workspace`.
2. `/login` → opens an OAuth URL → paste the returned code. Credentials persist under `<workspace>/.state/` on the host (bind-mounted to `/home/agent` inside the container).
3. `/exit` (or Ctrl-D). Claude shuts down; the watchdog detects the session ended and re-evaluates.
4. **Wait ~2–3 seconds** before re-attaching. The supervisor polls every 2s; re-attaching immediately after `/exit` can show `no sessions` while the next session is still spinning up. Retry is harmless.

## 2. Enter your Telegram bot token

Re-attach:

```bash
docker exec -it -u agent <name> tmux attach -t agent
```

The supervisor now sees an authenticated profile with no `TELEGRAM_BOT_TOKEN` in `/workspace/.env`, so it launches the in-container wizard (interactive via `gum` prompts):

- **Telegram bot token** — paste the token from @BotFather. The `telegram@claude-plugins-official` plugin uses dynamic pairing, so no chat id is needed.
- **GitHub PAT** — optional, only if the host wizard didn't capture it.
- **Atlassian workspace tokens** — one prompt per workspace declared in `agent.yml` that still has an empty token.

The wizard writes `/workspace/.env` (0600) and exits. The watchdog respawns, now with token in hand:

1. Auto-installs `telegram@claude-plugins-official` (idempotent) if not already cached.
2. Syncs `TELEGRAM_BOT_TOKEN` from `/workspace/.env` to the channel-scoped `/home/agent/.claude/channels/telegram/.env` (where the plugin's MCP server actually reads it).
3. Launches Claude with `--channels plugin:telegram@claude-plugins-official`.
4. The plugin's `bun server.ts` starts polling Telegram.

**Wait ~2–3 seconds** again before re-attaching — same watchdog gap as after `/exit`.

## 3. Pair your Telegram account

Re-attach one more time:

```bash
docker exec -it -u agent <name> tmux attach -t agent
```

Then:

1. DM the bot from Telegram — it replies with a 6-character pairing code.
2. In the Claude session: `/telegram:access pair <code>` (accept the `access.json` overwrite prompt).
3. Send a test DM from your phone — it should reach Claude and trigger a reply.

Detach with `Ctrl-b d`.

## Daily Use

Connect to the agent's tmux session:

```bash
ssh <host>
docker exec -it -u agent <name> tmux attach -t agent
```

This gives you an interactive Claude session. Detach with `Ctrl-b d` (standard tmux binding).

All agent output and interaction happens inside the container. There is no host-side tmux or CLI state.

## Upgrade

When you update the template:

```bash
# Tag the current image as backup
docker tag agent-admin:latest agent-admin:prev

# Update the template repo
cd agent-admin-template
git pull

# Rebuild and restart the container
cd ~/agents/<name>
docker compose build
docker compose up -d
```

The workspace (including `.state/`) is on the host as a bind-mount, so all agent data, login, and pairing survive the rebuild untouched.

## Rollback

If the new image is unstable:

```bash
docker tag agent-admin:prev agent-admin:latest
docker compose up -d
```

The container restarts with the previous image. No state is lost.

## Rotating Secrets

To update Telegram tokens or GitHub PAT without rebuilding:

```bash
# Edit the .env file on the host
nano ~/agents/<name>/.env

# Restart the container (applies new env vars)
docker compose restart
```

The agent picks up new tokens on the next connection attempt. Changes take effect immediately; no rebuild needed.

## Teardown

To remove the agent completely:

```bash
cd ~/agents/<name>
./setup.sh --uninstall --yes
```

This:

1. Stops the container with `docker compose down` (state under `.state/` is preserved — `docker compose down -v` is no-op since state lives in the workspace, not a named volume).
2. Removes the host systemd unit (Linux only).
3. Keeps the workspace directory, including `agent.yml`, `.env`, and `.state/` so a re-install carries login + pairing.

To also delete agent.yml/.env/.state:

```bash
./setup.sh --uninstall --purge --yes
```

To also delete the workspace directory itself:

```bash
./setup.sh --uninstall --nuke --yes
```

After `--nuke`, no traces of the agent remain on the host (no dotfiles, no systemd units, no leftover state).

## Troubleshooting

### Every Telegram message triggers a permission prompt

In steady state, Claude is launched with `--dangerously-skip-permissions` so
tool calls (including `mcp__plugin_telegram_telegram__reply`) don't stall on
approval prompts for every Telegram message. If you're still seeing prompts,
your container is running a pre-fix image — `docker compose build &&
docker compose up -d --force-recreate` will pick up the updated launch line.

The flag is scoped to the `--channels` launch only. The pre-`/login`
session (before you authenticate) still respects permission prompts,
because that's the interactive phase where you want the confirmations.

### `docker attach <name>` hangs with no output

`docker attach` connects to the container's PID 1 stdio. PID 1 is the supervisor (`start_services.sh`), which runs its watchdog loop silently once the tmux session is up — so attach just hangs, no prompt, no UI.

The user-facing Claude session lives inside a detached tmux session owned by the `agent` user. Use this instead:

```bash
docker exec -it -u agent <name> tmux attach -t agent
```

If you accidentally ran `docker attach` and are stuck, detach with `Ctrl-p Ctrl-q` (NOT `Ctrl-c`, which would kill the container).

### `docker exec … tmux attach -t agent` says "no sessions"

`docker exec` runs as root by default, and tmux keeps a per-UID socket at `/tmp/tmux-<uid>/default`. The session is owned by the `agent` user (UID 501 by default), so a root-owned exec looks at `/tmp/tmux-0/` and correctly reports no sessions there. Always pass `-u agent`:

```bash
docker exec -it -u agent <name> tmux attach -t agent
```

### `plugin:telegram:telegram · ✘ failed` (no pairing code sent)

Two possible causes:

1. **Plugin not installed yet.** On a fresh container Claude is launched with `--channels plugin:telegram@claude-plugins-official` but the plugin hasn't been `/plugin install`'d. Run the one-time setup from "One-time Claude authentication and plugin setup" above, then `docker compose restart` so Claude re-launches with the plugin active (in-place `/reload-plugins` reloads skills/commands but doesn't always re-hook the `--channels` poller).
2. **`bun` missing from the image.** The plugin's MCP server is a bun script. The shipped Dockerfile installs bun; if you built a custom image without it, `/mcp` will show the plugin as failed. Run `docker exec <name> bun --version` to confirm.

Verify with `/mcp` inside the Claude session — look for the line `plugin:telegram:telegram · ✔ connected`.

### `uvx: not found` on `time` / `fetch` / `atlassian-*` MCPs

These MCPs run via `uvx` (astral's `uv` Python runner). The shipped Dockerfile installs `uv` statically. Check:

```bash
docker exec <name> uvx --version
```

If missing and you're running a custom-built image, rebuild from the template's Dockerfile or add the `uv` install step manually.

### `docker attach` doesn't respond to keystrokes

`docker attach` is connected but the wizard (gum-driven) needs a TTY. The shipped `docker-compose.yml.tpl` sets `stdin_open: true` and `tty: true` — if you wrote a custom compose without these, input will silently drop. Add them and recreate:

```bash
docker compose up -d --force-recreate
```

**Always detach with `Ctrl-p Ctrl-q`.** `Ctrl-c` sends SIGINT and kills the container.

### `addgroup: gid '<N>' in use` at build time

macOS users have GID 20 (`staff`) and alpine ships a system group at GID 20 (`dialout`). The Dockerfile handles this by deleting the conflicting group/user before creating `agent`. If you modified the group-creation stanza, put the delete-then-create logic back (see `docker/Dockerfile`).

### Telegram bot responds with only the welcome text (no pairing code)

The bot polls via long-poll. If it sends only `"This bot bridges Telegram to a Claude Code session. To pair: …"` and never emits a code, the plugin's MCP server isn't running. Check:

```bash
docker exec <name> ps -ef | grep -E "bun|telegram"
docker exec -u agent <name> tmux send-keys -t agent '/mcp' Enter
docker exec -u agent <name> tmux capture-pane -t agent -p | tail -30
```

Look for `plugin:telegram:telegram · ✔ connected`. If `✘ failed`, apply the fix in the first entry above.

### `🔐 Permission: mcp__plugin_telegram_telegram__reply: not authorized`

The bot surfaces this when Claude tries to reply but the MCP tool call wasn't pre-authorized. Inside the Claude session, when prompted "Do you want to proceed?", pick **option 2** ("Yes, and always allow access to telegram/ from this project"). This writes a setting under the project that skips future prompts. If your pairing already happened and you want persistent approval, run any `/telegram:access …` command once more and accept option 2.

### UID mismatch (permission errors in logs)

If you see permission errors on bind-mount files, verify that `docker.uid` in `agent.yml` matches the host user:

```bash
id -u  # your user ID on the host
grep "docker:" ~/agents/<name>/agent.yml  # should contain matching UID
```

If they differ:

```bash
# Edit agent.yml and update docker.uid to match your user ID
nano ~/agents/<name>/agent.yml
docker compose build
docker compose up -d --force-recreate
```

### Container logs

```bash
docker logs <name>
docker logs -f <name>           # follow in real time
docker exec <name> cat /workspace/claude.log       # tmux pane capture
docker exec <name> cat /workspace/claude.cron.log  # crond heartbeat log
```

### Wizard re-fires on every restart

Means `/workspace/.env` is missing, empty, or doesn't contain `TELEGRAM_BOT_TOKEN=<non-empty>`. Verify:

```bash
ls -la ~/agents/<name>/.env       # should be 0600
grep "^TELEGRAM_BOT_TOKEN=" ~/agents/<name>/.env
```

If the value is present but the wizard still fires, check that the bind-mount path matches: `docker exec <name> cat /workspace/.env` should show the same content.

### `3 MCP servers failed` / `4 MCP servers failed` at launch

`/mcp` inside the Claude session lists each server with its connection state. Ignore failures from `claude.ai`-scoped servers (those require external auth you haven't configured); the ones to care about are `plugin:telegram:telegram`, `atlassian-*`, `github`, `playwright`. Most failures trace back to missing env vars in `/workspace/.env` (Atlassian token, GitHub PAT) or missing binaries (`bun`, `uvx`).
