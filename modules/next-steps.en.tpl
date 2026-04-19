# {{AGENT_DISPLAY_NAME}} — next steps (Docker mode)

Your agent is scaffolded as a Docker container at `{{DEPLOYMENT_WORKSPACE}}`.

## 1. Build and launch

```bash
cd {{DEPLOYMENT_WORKSPACE}}
docker compose build
docker compose up -d
```

The container starts and the supervisor launches Claude Code inside a detached tmux session. Attach to it (not `docker attach` — that shows supervisor logs; the user-facing session lives in tmux):

```bash
docker exec -it -u agent {{AGENT_NAME}} tmux attach -t agent
```

Detach without killing the container: `Ctrl-b d` (standard tmux binding).

## 2. Log in to Claude (one-time)

Inside the tmux session:

1. Pick a theme (Enter accepts the default) and confirm trust on `/workspace`.
2. Run `/login`, open the URL in your browser, authorize, paste the code back. Credentials land on the named state volume (`{{AGENT_NAME}}-state`) and survive rebuilds.
3. Type `/exit` (or Ctrl-D). Claude closes; the watchdog notices and re-evaluates what to launch next.
4. **Wait ~2–3 seconds** for the supervisor to detect the exit and spin up the next tmux session (the Telegram wizard). If you re-attach too fast, you'll see `no sessions` — just retry.

## 3. Enter your Telegram bot token

Re-attach to the tmux session:

```bash
docker exec -it -u agent {{AGENT_NAME}} tmux attach -t agent
```

The supervisor now detects the authenticated profile and launches the in-container wizard:

- `Telegram bot token (from @BotFather):` — paste your token.
- `Add a GitHub Personal Access Token (for gh / MCP)?` — optional.
- For each Atlassian workspace declared in `agent.yml`, paste the API token (or press Enter to skip).

The wizard writes `/workspace/.env` (0600) and exits. The watchdog sees the session die, re-decides, and this time launches Claude with `--channels plugin:telegram@claude-plugins-official`. The plugin's MCP server (`bun server.ts`) starts automatically and begins polling Telegram.

**Wait ~2–3 seconds** again before re-attaching — same gap as after `/exit`.

## 4. Pair your Telegram account

Re-attach once more:

```bash
docker exec -it -u agent {{AGENT_NAME}} tmux attach -t agent
```

Then:

1. DM your bot from Telegram — it replies with a 6-character pairing code.
2. In the Claude session: `/telegram:access pair <code>` (approve the `access.json` overwrite prompt).
3. Your chat id is now on the allowlist; the bot will confirm with "you're in".
4. Send another DM to verify — it reaches Claude, Claude replies.

Detach with `Ctrl-b d`.

## Daily use

```bash
# Reconnect to the session
docker exec -it -u agent {{AGENT_NAME}} tmux attach -t agent

# Rotate a secret
$EDITOR {{DEPLOYMENT_WORKSPACE}}/.env
docker compose restart

# Upgrade to a new template version
cd {{DEPLOYMENT_WORKSPACE}}
git pull                                 # if your workspace is a fork
docker compose build && docker compose up -d
```

## Teardown

```bash
./setup.sh --uninstall --yes             # stops container, removes named volume + host unit
./setup.sh --uninstall --nuke --yes      # also deletes this workspace directory
```

## Troubleshooting

### The agent stops responding on Telegram ("ghosting")

Symptom: you send Telegram messages to the chat bot, the agent replies once after a restart and then goes silent. `ps` shows `bun server.ts` and `claude` still alive, but messages do not reach Claude. It is a known bug in the MCP bridge inside `claude-plugins-official/telegram` (upstream, not this repo).

**Recovery:**

```bash
docker exec -u agent {{AGENT_NAME}} heartbeatctl kick-channel
```

This kills the `agent` tmux session; the watchdog in `start_services.sh` respawns it in ~2 seconds with a freshly reconnected plugin. Your next Telegram message should go through.

The watchdog also auto-detects when `bun server.ts` dies (a different failure mode) and respawns without intervention. `kick-channel` is for the case where bun is alive but the bridge is hung.

**Example flow:**

```bash
# From your terminal, when the agent stops responding:
docker exec -u agent {{AGENT_NAME}} heartbeatctl kick-channel
# heartbeatctl: killed tmux session 'agent' — watchdog will respawn in ~2s

# Send "hello" on Telegram. Agent replies.
```

### Other useful `heartbeatctl` commands

```bash
docker exec -u agent {{AGENT_NAME}} heartbeatctl status   # dashboard + last run
docker exec -u agent {{AGENT_NAME}} heartbeatctl logs     # last 20 runs
docker exec -u agent {{AGENT_NAME}} heartbeatctl test     # manual tick now
docker exec -u agent {{AGENT_NAME}} heartbeatctl pause    # pause heartbeat
docker exec -u agent {{AGENT_NAME}} heartbeatctl resume   # resume
docker exec -u agent {{AGENT_NAME}} heartbeatctl set-interval 5m   # change interval
```

Full reference (all subcommands, validation rules, propagation timing): [docs/heartbeatctl.md](docs/heartbeatctl.md).

### Other issues

Plugin not connected on first boot, permission prompts, crond silent, UID mismatch, etc. live in [docs/getting-started.md](docs/getting-started.md).
