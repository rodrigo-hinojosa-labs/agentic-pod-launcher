# Quickstart — Agentic mode (English)

Instead of answering the interactive wizard, you clone the repo, open a Claude Code session in the cloned directory, and paste a single prompt that drives `./setup.sh` end-to-end.

## When to use this mode

- You're already working inside Claude Code and don't want to drop to the shell.
- You want to reproduce the same agent across multiple hosts with identical configuration.
- You prefer reviewing the configuration block in one place before running.

## Prerequisites

- `git`, `yq`, `gh`, and `claude` installed.
- A GitHub Personal Access Token with `repo` scope (and `delete_repo` if you plan to use `--delete-fork` later).
- Push access to the fork owner (your personal account or an org you belong to).

## Steps

1. Clone the repo and enter it:
   ```bash
   git clone https://github.com/rodrigo-hinojosa-labs/agent-admin-template.git
   cd agent-admin-template
   ```
2. Open Claude Code:
   ```bash
   claude
   ```
3. Fill in the configuration block below with your values.
4. Paste the configuration block followed by the instruction block into the Claude session.
5. Claude validates prerequisites, runs `./setup.sh`, and shows you the rendered `NEXT_STEPS.md` when done.

---

## Block 1 — Configuration (fill in before pasting)

```
AGENT_NAME="linus"
DISPLAY_NAME="Linus 🐧"
ROLE="Admin assistant for my ecosystem"
VIBE="Direct, useful, no drama"

USER_NAME="Your Full Name"       # used in CLAUDE.md and agent.yml
NICKNAME="You"                   # how the agent should address you
TIMEZONE="America/Santiago"      # IANA timezone — adjust to your own
EMAIL="you@example.com"
LANGUAGE="en"                    # es | en | mixed

HOST=""                          # empty = hostname -s of the current host
DESTINATION="$HOME/Claude/Agents/linus"
INSTALL_SERVICE="y"              # y | n

# Claude profile: left empty, the wizard auto-inherits $CLAUDE_CONFIG_DIR
# from the current session. Override only if you want a specific existing
# profile or a new isolated one (the wizard's multi-candidate prompt accepts
# a number; set this to that number, e.g. "1" for first candidate).
CLAUDE_PROFILE_CHOICE=""         # empty = auto, "1"..."N" = pick candidate

FORK_ENABLED="y"                 # y | n — if n, all FORK_* are ignored
FORK_OWNER="your-github-user-or-org"   # user or organization
FORK_NAME=""                     # empty = <agent>-agent (shared across hosts; branches carry the host)
FORK_PRIVATE="y"
TEMPLATE_URL="https://github.com/rodrigo-hinojosa-labs/agent-admin-template"
FORK_PAT=""                      # ghp_... with repo scope

HEARTBEAT_NOTIF="none"           # none | log | telegram
ATLASSIAN_ENABLED="n"
GITHUB_MCP_ENABLED="n"
GITHUB_MCP_EMAIL=""              # if ENABLED=y
GITHUB_MCP_PAT=""                # if ENABLED=y — may reuse FORK_PAT

HEARTBEAT_ENABLED="n"
HEARTBEAT_INTERVAL="30m"
HEARTBEAT_PROMPT="Check status and report"
USE_DEFAULT_PRINCIPLES="y"
```

## Block 2 — Instructions (paste as-is after block 1)

```
Run the agent-admin-template wizard using the values above.

Before running:
1. Confirm `yq`, `git`, and `gh` are on PATH.
2. If FORK_ENABLED="y", export GH_TOKEN=$FORK_PAT and verify `gh api user` returns a valid login.
3. Verify $DESTINATION does not already exist.
4. If any required value is empty (AGENT_NAME, USER_NAME, EMAIL, or — when FORK_ENABLED=y — FORK_OWNER and FORK_PAT), stop and ask me for the missing values before continuing.

Then:
5. Build the wizard stdin with `printf`, honoring the exact prompt order:
   - Agent identity: AGENT_NAME, DISPLAY_NAME, ROLE, VIBE
   - About you: USER_NAME, NICKNAME, TIMEZONE, EMAIL, LANGUAGE
   - Deployment: HOST, DESTINATION, INSTALL_SERVICE
   - Claude profile: only prompted when multiple ~/.claude* dirs exist AND $CLAUDE_CONFIG_DIR is unset. If prompted, pass CLAUDE_PROFILE_CHOICE (default "1" = first existing profile)
   - Fork: FORK_ENABLED [if y: FORK_OWNER, FORK_NAME, FORK_PRIVATE, TEMPLATE_URL, FORK_PAT]
   - Heartbeat notifications: HEARTBEAT_NOTIF
   - MCPs: ATLASSIAN_ENABLED [if y: atlassian loop], GITHUB_MCP_ENABLED [if y: email + PAT]
   - Features: HEARTBEAT_ENABLED [if y: INTERVAL, PROMPT]
   - Principles: USE_DEFAULT_PRINCIPLES
   - Action: "" (proceed)

6. Pipe that stdin to `./setup.sh` and capture stdout+stderr.
7. If any scaffold step fails (fork creation, fetch, rebase), show me the full error and stop — do not silently "fix" by mutating agent.yml without asking.
8. On success, print the `NEXT_STEPS.md` rendered into $DESTINATION and summarize:
   - The live branch created (e.g. `<host>-<agent>-v1/live`)
   - The fork URL
   - What's still pending (initial push, SSH/MCP validation, plugin install)

Don't ask for confirmation between steps — proceed unless a required value is missing or a validation fails.
```

---

## Security

⚠ The PAT lives in the Claude session's context. If your memory system (`claude-mem`, similar plugins) indexes sessions, **treat the token as compromised** and revoke it at https://github.com/settings/tokens when you're done. Generate a new one for ongoing use.

## Alternative: interactive wizard

If you prefer the traditional terminal-prompt flow, run `./setup.sh` and answer each question by hand — see the [Quick start](../README.md#quick-start) section of the README.

---

## Telegram (two-way chat)

Once the agent is up and running, if you want to DM it from your phone: configure the official channel from the `telegram@claude-plugins-official` plugin. It enables DMs to the agent from Telegram with pairing + allowlist access control.

Complements the heartbeat: heartbeat = the agent reaches out to you; Telegram = you reach out to the agent.

### Requirements

- `bun` installed on the system (the plugin's MCP server is TypeScript and starts via `bun run`). **Without `bun`, the server dies silently when spawned and the `telegram__*` tools never appear.**
  ```bash
  curl -fsSL https://bun.sh/install | bash
  ```
- Plugin enabled in `~/.claude/settings.json`:
  ```json
  "enabledPlugins": { "telegram@claude-plugins-official": true }
  ```

### Steps

1. **Create the bot** → talk to [@BotFather](https://t.me/BotFather) → `/newbot` → copy the token (`123456789:AAH...`).
2. **Save the token** → inside the Claude session: `/telegram:configure <token>`. It lands in `~/.claude/channels/telegram/.env` with 600 perms.
3. **Restart Claude Code fully.** `/reload-plugins` is not enough if `bun` was installed in the same session — the parent process's PATH doesn't refresh.
4. **Pairing** → DM the bot from Telegram. The bot replies with a code. Approve it with `/telegram:access pair <code>`.
5. **Lockdown** → `/telegram:access policy allowlist` to restrict the channel to the IDs you've already captured. Pairing is transient, **not a final policy**: if you leave it on, anyone who DMs the bot gets through.

### Gotchas

- **`bun` install order**: if you install it AFTER starting Claude Code, the in-memory process can't see the binary on PATH. Full restart, not reload — always.
- **Open pairing**: while in pairing mode, the channel accepts new IDs. Close it with `allowlist` as soon as your chat_id(s) are approved.
- **Two different things**: this plugin is for two-way chat. If you also want the heartbeat to ping you via Telegram, that's the heartbeat's `telegram` driver (configured in the wizard, separate bot).
