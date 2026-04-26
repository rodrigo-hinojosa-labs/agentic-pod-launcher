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
2. Run `/login`, open the URL in your browser, authorize, paste the code back. Credentials land in `{{DEPLOYMENT_WORKSPACE}}/.state/` (bind-mounted to the container's `/home/agent`) and survive rebuilds.
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

{{PLUGINS_BLOCK}}

## Teardown

```bash
./setup.sh --uninstall --yes             # stops container, removes host unit (state under .state/ is preserved)
./setup.sh --uninstall --purge --yes     # also deletes agent.yml/.env/.state/
./setup.sh --uninstall --nuke --yes      # also deletes this entire workspace directory
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

### Other common issues

#### `docker exec ... tmux attach -t agent` says "no sessions"

`docker exec` defaults to root, and tmux keeps its socket per-UID in `/tmp/tmux-<uid>/`. The session lives under the `agent` UID (501 by default), so root looks at `/tmp/tmux-0/` and correctly reports empty. Always pass `-u agent`:

```bash
docker exec -it -u agent {{AGENT_NAME}} tmux attach -t agent
```

#### `docker attach {{AGENT_NAME}}` hangs with no output

`docker attach` connects to PID 1's stdio, which is `start_services.sh` running its watchdog silently. Use `tmux attach` via `docker exec` (above). If you accidentally ran `docker attach` and got stuck, detach with `Ctrl-p Ctrl-q` — NOT `Ctrl-c`, which kills the container.

#### Telegram plugin not connected (`plugin:telegram:telegram · ✘ failed`)

Two usual causes:

1. **Plugin not installed yet** — on first boot claude launches with `--channels` but the plugin cache isn't populated. Run `docker compose restart` after `/login` so the watchdog installs the plugin and re-launches. Inside tmux, `/mcp` shows each server's status: look for `✔ connected`.
2. **`bun` missing from the image** — the plugin MCP server runs on bun. The launcher's image installs it; if you built a custom image without bun, confirm:

```bash
docker exec {{AGENT_NAME}} bun --version
```

#### The token wizard re-fires on every restart

Means `/workspace/.env` is missing or lacks `TELEGRAM_BOT_TOKEN=<non-empty>`. Check:

```bash
ls -la {{DEPLOYMENT_WORKSPACE}}/.env           # must be 0600
grep "^TELEGRAM_BOT_TOKEN=" {{DEPLOYMENT_WORKSPACE}}/.env
docker exec {{AGENT_NAME}} cat /workspace/.env | grep TELEGRAM
```

All three should agree. If the last one differs, the bind-mount is wrong.

#### UID mismatch (permission errors on bind-mount files)

Happens when `docker.uid` in `agent.yml` doesn't match your host UID:

```bash
id -u                                              # your UID
grep "uid:" {{DEPLOYMENT_WORKSPACE}}/agent.yml     # should match
```

If they differ, edit `agent.yml`, then `./setup.sh --regenerate && docker compose build && docker compose up -d --force-recreate`.

#### Container logs

```bash
docker logs {{AGENT_NAME}}                                    # supervisor (tail)
docker logs -f {{AGENT_NAME}}                                 # follow live
docker exec {{AGENT_NAME}} cat /workspace/claude.log          # tmux capture
docker exec {{AGENT_NAME}} cat /workspace/claude.cron.log     # crond log
docker exec -u agent {{AGENT_NAME}} heartbeatctl logs         # runs.jsonl
```

#### "N MCP servers failed" at launch

Inside the agent run `/mcp` to see each server's state. Focus on the ones that matter: `plugin:telegram:telegram`, `atlassian-*`, `github`, `playwright`. Typical causes: missing env vars in `.env` (Atlassian tokens, GitHub PAT) or missing binaries (`bun`, `uvx`).
