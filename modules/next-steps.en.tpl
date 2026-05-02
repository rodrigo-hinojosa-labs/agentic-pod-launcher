# {{AGENT_DISPLAY_NAME}} — next steps (Docker mode)

Your agent is scaffolded as a Docker container at `{{DEPLOYMENT_WORKSPACE}}`.

## 1. Build and launch

```bash
cd {{DEPLOYMENT_WORKSPACE}}
docker compose build
docker compose up -d
```

The container starts and the supervisor launches Claude Code inside a detached tmux session. Attach with `agentctl attach` — the wrapper has an internal retry-loop (15s max) that waits for the supervisor to finish respawning the session:

```bash
./scripts/agentctl attach
```

> **Note**: `agentctl` is a host-side wrapper for `docker exec -u agent {{AGENT_NAME}} ...`. Resolves the container name from `agent.yml` (cwd) or the `-a NAME` flag. Subcommands: `attach`, `logs [-f]`, `status`, `heartbeat <sub>`, `mcp [list]`, `shell [--root]`, `up`, `stop`, `restart`, `ps`, `run <cmd…>`. Raw equivalent (if you'd rather type it out): `docker exec -it -u agent {{AGENT_NAME}} tmux attach -t agent`.

Detach without killing the container: `Ctrl-b d` (standard tmux binding).

## 2. Log in to Claude (one-time)

Inside the tmux session:

1. Pick a theme (Enter accepts the default) and confirm trust on `/workspace`.
2. Run `/login`, open the URL in your browser, authorize, paste the code back. Credentials land in `{{DEPLOYMENT_WORKSPACE}}/.state/` (bind-mounted to the container's `/home/agent`) and survive rebuilds.
3. Type `/exit` (or Ctrl-D). Claude closes; the watchdog notices and re-evaluates what to launch next.
4. Re-connect with `./scripts/agentctl attach` — the internal retry-loop waits for the supervisor.

## 3. Enter your Telegram bot token

Re-attach to the tmux session:

```bash
./scripts/agentctl attach
```

The supervisor now detects the authenticated profile and launches the in-container wizard:

- `Telegram bot token (from @BotFather):` — paste your token.
- `Add a GitHub Personal Access Token (for gh / MCP)?` — optional.
- For each Atlassian workspace declared in `agent.yml`, paste the API token (or press Enter to skip).

The wizard writes `/workspace/.env` (0600) and exits. The watchdog sees the session die, re-decides, and this time launches Claude with `--channels plugin:telegram@claude-plugins-official`. The plugin's MCP server (`bun server.ts`) starts automatically and begins polling Telegram.

## 4. Pair your Telegram account

Re-attach once more:

```bash
./scripts/agentctl attach
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
./scripts/agentctl attach

# Heartbeat status
./scripts/agentctl status

# Tail Claude's log
./scripts/agentctl logs -f

# Rotate a secret
$EDITOR {{DEPLOYMENT_WORKSPACE}}/.env
./scripts/agentctl restart

# Upgrade to a new template version
cd {{DEPLOYMENT_WORKSPACE}}
git pull                                 # if your workspace is a fork
docker compose build && ./scripts/agentctl restart
```

### Full `agentctl` cheatsheet

```bash
# Container lifecycle
./scripts/agentctl up                    # docker compose up -d
./scripts/agentctl stop                  # docker compose stop (state preserved)
./scripts/agentctl restart               # stop + up
./scripts/agentctl ps                    # container status

# Interactive session
./scripts/agentctl attach                # tmux attach (15s retry-loop)
./scripts/agentctl shell                 # bash inside container (as agent)
./scripts/agentctl shell --root          # bash as root (debugging)
./scripts/agentctl run <cmd…>            # arbitrary command (as agent)

# Observability
./scripts/agentctl logs                  # tail claude.log
./scripts/agentctl logs -f               # follow
./scripts/agentctl logs --stderr         # forensic tail of Telegram MCP stderr
./scripts/agentctl status                # heartbeat status (alias)
./scripts/agentctl doctor                # 12 dependency-ordered checks

# MCP servers
./scripts/agentctl mcp                   # claude mcp list (servers + state)

# Heartbeat (proxies to heartbeatctl)
./scripts/agentctl heartbeat status      # last run + counters
./scripts/agentctl heartbeat test        # one manual tick
./scripts/agentctl heartbeat logs        # last 20 runs
./scripts/agentctl heartbeat pause       # pause the cron
./scripts/agentctl heartbeat resume      # resume
./scripts/agentctl heartbeat set-interval 5m
./scripts/agentctl heartbeat set-prompt "..."
./scripts/agentctl heartbeat kick-channel  # respawn tmux when Telegram ghosts
./scripts/agentctl heartbeat backup-identity
./scripts/agentctl heartbeat backup-vault
./scripts/agentctl heartbeat backup-config
```

> **Agent-name resolution**: `agentctl` reads `agent.yml` from the current working directory (or the `-a NAME` flag) to know which container to target. If you change directories or run multiple agents, pass `-a <name>` explicitly.

{{PLUGINS_BLOCK}}

## Teardown

```bash
./setup.sh --uninstall --yes             # stops container, removes host unit (state under .state/ is preserved)
./setup.sh --uninstall --purge --yes     # also deletes agent.yml/.env/.state/
./setup.sh --uninstall --nuke --yes      # also deletes this entire workspace directory
```

## Troubleshooting

### When something is off: run `agentctl doctor` first

Before anything else:

```bash
./scripts/agentctl doctor
```

Runs 12 checks in dependency order (Docker daemon → container → health → agent.yml → tmux → crond → Telegram plugin → heartbeat → vault → patches) and reports `✓` / `⚠` / `✗` per subsystem with an actionable hint when something fails. The fastest way to know what's broken without running 8 commands.

### The agent stops responding on Telegram ("ghosting")

Symptom: you send Telegram messages to the chat bot, the agent replies once after a restart and then goes silent. `ps` shows `bun server.ts` and `claude` still alive, but messages do not reach Claude. It is a known bug in the MCP bridge inside `claude-plugins-official/telegram` (upstream, not this repo).

**Recovery:**

```bash
./scripts/agentctl heartbeat kick-channel
```

This kills the `agent` tmux session; the watchdog in `start_services.sh` respawns it in ~2 seconds with a freshly reconnected plugin. Your next Telegram message should go through.

The watchdog also auto-detects when `bun server.ts` dies (a different failure mode) and respawns without intervention. `kick-channel` is for the case where bun is alive but the bridge is hung.

**Example flow:**

```bash
# From your terminal, when the agent stops responding:
./scripts/agentctl heartbeat kick-channel
# heartbeatctl: killed tmux session 'agent' — watchdog will respawn in ~2s

# Send "hello" on Telegram. Agent replies.
```

### Other useful `heartbeatctl` commands

```bash
./scripts/agentctl status                        # dashboard + last run
./scripts/agentctl heartbeat logs                # last 20 runs
./scripts/agentctl heartbeat test                # manual tick now
./scripts/agentctl heartbeat pause               # pause heartbeat
./scripts/agentctl heartbeat resume              # resume
./scripts/agentctl heartbeat set-interval 5m     # change interval
```

Full reference (all subcommands, validation rules, propagation timing): [docs/heartbeatctl.md](docs/heartbeatctl.md).

### Other common issues

#### `docker exec ... tmux attach -t agent` says "no sessions"

Two distinct causes, both handled by `agentctl attach` instead of the raw command:

1. **Missing `-u agent`**: `docker exec` defaults to root, and tmux keeps its socket per-UID in `/tmp/tmux-<uid>/`. The session lives under the `agent` UID (501 by default), so root looks at `/tmp/tmux-0/` and correctly reports empty. `agentctl attach` always passes `-u agent`. Raw equivalent: `docker exec -it -u agent {{AGENT_NAME}} tmux attach -t agent`.

2. **Watchdog timing**: the supervisor polls every 2s and respawns the tmux session after `/login`, `/exit`, channel restart, or any process crash. Between "died" and "respawn complete" there's a 5–15s window with no `agent` session. Attaching during that window returns `no sessions`. `agentctl attach` polls every 1s for up to 15s and connects as soon as the supervisor finishes the respawn.

   If 15s pass without success, something deeper is wrong:

   ```bash
   ./scripts/agentctl logs -n 100             # tail Claude's log
   docker logs {{AGENT_NAME}} | tail -50      # supervisor logs
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
