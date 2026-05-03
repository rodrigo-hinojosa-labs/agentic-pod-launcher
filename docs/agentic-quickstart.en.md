# Quickstart — Agentic mode (English)

Instead of answering the interactive wizard, you clone the repo, open a Claude Code session in the cloned directory, and paste a single prompt that drives `./setup.sh` end-to-end.

## When to use this mode

- You're already working inside Claude Code and don't want to drop to the shell.
- You want to reproduce the same agent across multiple hosts with identical configuration.
- You prefer reviewing the configuration block in one place before running.

## Shortcut: the `/quickstart` slash command

If you don't want to paste two blocks, open `claude` inside the repo and type `/quickstart`. The command loads this doc + `tests/helper.bash::wizard_answers()` as reference, asks you for the minimum required values in a single message (`AGENT_NAME`, `USER_NAME`, `EMAIL`, `DESTINATION`, optionally `FORK_*` and `VAULT_*`), applies sensible defaults to the rest, and runs the wizard. It's the shortest path from a Claude Code session to a scaffolded agent.

The rest of this document is still useful: it covers the inputs in detail (helpful for auditing, or when you want a single copy-paste block instead of using the slash).

## Prerequisites

- `git` and `claude` installed.
- `yq` v4+ and `gh`: optional. If missing, `setup.sh` auto-vendors them into `scripts/vendor/bin/` on first run (`yaml_require_yq` downloads mikefarah/yq v4+; `ensure_gh` downloads gh ≥ 2.40). On Debian/Ubuntu, **don't run `apt install yq`** — that package is the v3 Python wrapper (incompatible syntax); the launcher detects that and vendors the right binary anyway. To pre-install manually, use `brew install yq` (macOS) or grab the binary from [github.com/mikefarah/yq](https://github.com/mikefarah/yq#install).
- A GitHub Personal Access Token with `repo` scope (and `delete_repo` if you plan to use `--delete-fork` later).
- Push access to the fork owner (your personal account or an org you belong to).

## Steps

1. Clone the repo and enter it:
   ```bash
   git clone https://github.com/rodrigo-hinojosa-labs/agentic-pod-launcher.git
   cd agentic-pod-launcher
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

```bash
# ── Agent identity ────────────────────────────────────
AGENT_NAME="linus"                     # lowercase, no spaces (normalized anyway)
DISPLAY_NAME="Linus 🐧"                 # emoji optional
ROLE="Admin assistant for my ecosystem"
VIBE="Direct, useful, no drama"

# ── About you ─────────────────────────────────────────
USER_NAME="Your Full Name"             # used in CLAUDE.md and agent.yml
NICKNAME=""                            # empty = first word of USER_NAME
TIMEZONE=""                            # empty = auto (timedatectl/readlink) → "America/Santiago"
EMAIL="you@example.com"
LANGUAGE="en"                          # es | en | mixed

# ── Deployment ────────────────────────────────────────
DESTINATION="$HOME/Claude/Agents/linus"     # must NOT exist yet
INSTALL_SERVICE="y"                    # Linux only — wizard skips this prompt on macOS

# ── GitHub fork (template sync) ───────────────────────
FORK_ENABLED="y"                       # y | n — if n, all FORK_* are ignored
FORK_OWNER="your-github-user-or-org"   # user or organization
FORK_NAME=""                           # empty = <agent>-agent (shared cross-host; branches carry the host)
FORK_PRIVATE="y"
TEMPLATE_URL="https://github.com/rodrigo-hinojosa-labs/agentic-pod-launcher"
FORK_PAT=""                            # ghp_... with repo scope (NEVER make this up)

# ── Heartbeat — notifications ─────────────────────────
NOTIFY_CHANNEL="none"                  # none | log | telegram
NOTIFY_BOT_TOKEN=""                    # only if NOTIFY_CHANNEL=telegram
NOTIFY_CHAT_ID=""                      # only if NOTIFY_CHANNEL=telegram

# ── MCPs ──────────────────────────────────────────────
ATLASSIAN_ENABLED="n"                  # if y → loop of workspaces (see format below)
# Format: each workspace is "name|url|email|token", space-separated.
# Empty email = falls back to $EMAIL. Empty token = filled in .env later.
# Example: ATLASSIAN_WORKSPACES="work|https://acme.atlassian.net|me@acme.com|atl_xxx personal|https://me.atlassian.net||"
ATLASSIAN_WORKSPACES=""

GITHUB_MCP_ENABLED="n"                 # GitHub MCP (≠ from fork; separate PAT)
GITHUB_MCP_EMAIL=""                    # empty = $EMAIL when ENABLED=y
GITHUB_MCP_PAT=""                      # ghp_... — may reuse FORK_PAT if you want

# ── Heartbeat — schedule + prompt ─────────────────────
HEARTBEAT_ENABLED="y"                  # y = wizard asks the next two; n = skip
HEARTBEAT_INTERVAL="30m"               # 5m, 30m, 1h, 6h, 1d, etc.
HEARTBEAT_PROMPT="Status check — return a short plain-text report (uptime, notable issues). No tool use; your stdout is forwarded verbatim to the notifier."

# ── Principles ────────────────────────────────────────
USE_DEFAULT_PRINCIPLES="y"             # y = paste opinionated defaults; n = start blank

# ── Knowledge vault (Karpathy LLM Wiki) ───────────────
VAULT_ENABLED="y"                      # Obsidian-style vault at .state/.vault/
VAULT_SEED_SKELETON="y"                # 3-layer skeleton (raw_sources/wiki/schema)
VAULT_MCP_ENABLED="y"                  # register MCPVault (@bitbonsai/mcpvault)
VAULT_QMD_ENABLED="n"                  # hybrid search BM25+vector — downloads ~300MB on first use

# ── Optional plugins (5; alphabetical wizard order) ───
PLUGIN_CODE_SIMPLIFIER="n"
PLUGIN_COMMIT_COMMANDS="n"
PLUGIN_GITHUB="n"
PLUGIN_SKILL_CREATOR="n"
PLUGIN_SUPERPOWERS="n"
```

## Block 2 — Instructions (paste as-is after block 1)

```
Run the agentic-pod-launcher wizard using the values above.

PRE-FLIGHT — before touching setup.sh:
1. Confirm `git` is on PATH (required, no auto-install). Do NOT block on `yq`
   or `gh` being absent — `setup.sh` vendors them into `scripts/vendor/bin/`
   itself (`yaml_require_yq` downloads mikefarah/yq v4+ even if the system
   has apt's v3; `ensure_gh` downloads gh ≥ 2.40).
2. If FORK_ENABLED="y" and `gh` is already on PATH, export GH_TOKEN=$FORK_PAT
   and verify `gh api user` returns a valid login. If `gh` is missing, skip
   this — `ensure_gh` vendors it during the wizard and the auth check happens
   there.
3. Verify $DESTINATION does not exist (`[ ! -e $DESTINATION ]`). If it does, stop.
4. If any required value is empty, stop and ask me for the missing ones:
   - AGENT_NAME, USER_NAME, EMAIL — always required
   - FORK_OWNER, FORK_PAT — only if FORK_ENABLED="y"
   - NOTIFY_BOT_TOKEN, NOTIFY_CHAT_ID — only if NOTIFY_CHANNEL="telegram"
   - GITHUB_MCP_PAT — only if GITHUB_MCP_ENABLED="y"

RULE — NEVER fabricate secrets (PATs, bot tokens, chat IDs, Atlassian API
tokens). If one is missing and the feature requires it, offer me two options:
(a) I provide it and we retry, (b) we disable that feature (e.g. set
NOTIFY_CHANNEL=none) and configure it later via heartbeatctl or a wizard re-run.

STDIN BUILD — use `printf` and respect this EXACT order (mirror of
`tests/helper.bash::wizard_answers()`, which is the canonical source of
truth, kept in sync by every PR):

  1. Identity (4 lines):            AGENT_NAME, DISPLAY_NAME, ROLE, VIBE
  2. About you (5 lines):           USER_NAME, NICKNAME (empty→first name),
                                    TIMEZONE (empty→auto), EMAIL, LANGUAGE
  3. install_service (Linux only):  INSTALL_SERVICE   ← skip if `uname -s` ≠ Linux
  4. Fork (1 + sub if y):           FORK_ENABLED [if y: FORK_OWNER, FORK_NAME
                                    (empty→<agent>-agent), FORK_PRIVATE,
                                    TEMPLATE_URL, FORK_PAT]
  5. Heartbeat notif (1 + sub):     NOTIFY_CHANNEL [if telegram: NOTIFY_BOT_TOKEN
                                    + auto-discover prompt = "n" + NOTIFY_CHAT_ID]
  6. Atlassian MCP (1 + loop if y): ATLASSIAN_ENABLED [if y: per workspace
                                    name|url|email|token + "n" to end loop]
  7. GitHub MCP (1 + sub if y):     GITHUB_MCP_ENABLED [if y: GITHUB_MCP_EMAIL,
                                    GITHUB_MCP_PAT]
  8. Heartbeat schedule (1 + sub):  HEARTBEAT_ENABLED [if y: HEARTBEAT_INTERVAL,
                                    HEARTBEAT_PROMPT]
  9. Principles (1):                USE_DEFAULT_PRINCIPLES
 10. Vault (1 + 3 sub if y):        VAULT_ENABLED [if y: VAULT_SEED_SKELETON,
                                    VAULT_MCP_ENABLED, VAULT_QMD_ENABLED]
 11. Optional plugins (5, alpha):   PLUGIN_CODE_SIMPLIFIER, PLUGIN_COMMIT_COMMANDS,
                                    PLUGIN_GITHUB, PLUGIN_SKILL_CREATOR,
                                    PLUGIN_SUPERPOWERS
 12. Review action (1):             "proceed"   ← literal, no quotes in the printf

EXECUTION:
13. Pipe that stdin to `./setup.sh --destination $DESTINATION` and capture
    stdout+stderr. DO NOT use --non-interactive (that requires a pre-existing
    agent.yml — different flow).
14. If ANY scaffold step fails (clone, fork creation, fetch, rebase,
    docker-compose render), show me the full error and stop. Don't try to
    "fix" it by silently mutating agent.yml.
15. On success:
    - Print the `NEXT_STEPS.md` rendered into $DESTINATION.
    - Summarize: live branch created, fork URL (if applicable), pending
      commands (initial push, /login, Telegram pairing, MCP validation).

Don't ask for confirmation between pre-flight and stdin-build steps —
proceed unless a required value is missing or a validation fails.
```

---

## Field reference — required vs default vs never-fabricate

| Category | Fields | Notes |
|---|---|---|
| **Required** (no safe default) | `AGENT_NAME`, `USER_NAME`, `EMAIL`, `DESTINATION` | Wizard rejects empty input here. |
| **Conditionally required** | `FORK_OWNER` + `FORK_PAT` (if fork=y), `NOTIFY_BOT_TOKEN` + `NOTIFY_CHAT_ID` (if telegram), `GITHUB_MCP_PAT` (if GitHub MCP) | Only when you enable the feature. |
| **Safe default** | `VIBE`, `NICKNAME` (auto from first name), `TIMEZONE` (auto), `LANGUAGE` (`en`), `INSTALL_SERVICE` (Linux=`y`), `FORK_NAME` (`<agent>-agent`), `FORK_PRIVATE` (`y`), `NOTIFY_CHANNEL` (`none`), `HEARTBEAT_*` (30m, default prompt), `USE_DEFAULT_PRINCIPLES` (`y`), `VAULT_*` (all `y` except QMD=`n`) | Accept the default if you have no explicit preference. |
| **NEVER fabricate** | `FORK_PAT`, `NOTIFY_BOT_TOKEN`, `NOTIFY_CHAT_ID`, `GITHUB_MCP_PAT`, every `ATLASSIAN_*` token | User secrets. If missing and the feature requires them, disable the feature or stop and ask. |

---

## Validations applied by the wizard

The wizard (both interactive and agentic) validates inputs before accepting them. If the slash command pipes an invalid value, the wizard re-prompts and hangs waiting for input that never arrives — so the slash command **must validate before piping**:

| Field | Rule | Valid example | Invalid example |
|---|---|---|---|
| `AGENT_NAME` | DNS label: lowercase + digits + hyphens, no leading/trailing hyphen, no double hyphen, 1..63 chars | `my-agent`, `agent01` | `My_Agent`, `-agent`, `agent--01` |
| `EMAIL` (any) | Matches `user@host.tld` (simplified RFC 5322) | `alice@example.com` | `alice@example`, `not-an-email` |
| `TIMEZONE` | Must exist under `/usr/share/zoneinfo/` or match `Region/City` pattern | `America/Santiago`, `UTC` | `Chile time`, `2 hours ago` |
| `HEARTBEAT_INTERVAL` | `Nm` / `Nh` or 5-field cron expression | `30m`, `2h`, `0 * * * *` | `30 minutes`, `every hour` |
| `NOTIFY_BOT_TOKEN` (if non-empty) | `<digits>:<base64-like 25+>` | `123456789:AAEhBP0...` | `my-token`, `123:short` |
| `*_URL` (Atlassian, fork) | http(s) only, no whitespace | `https://acme.atlassian.net` | `acme.atlassian.net`, `ftp://...` |
| `UID`/`GID` | Non-negative integer (auto-detected, never asked) | `1000`, `501` | `-1`, `abc` |

If the slash command can't validate locally (e.g. the token is opaque), pipe the raw value and let the wizard reject it. If the wizard re-prompts, the piped stdin desyncs — catch that case by reporting "wizard rejected X — re-run quickstart with a valid value".

---

## Security

⚠ The PAT lives in the Claude session's context. If your memory system (`claude-mem`, similar plugins) indexes sessions, **treat the token as compromised** and revoke it at https://github.com/settings/tokens when you're done. Generate a new one for ongoing use.

## Alternative: interactive wizard

If you prefer the traditional terminal-prompt flow, run `./setup.sh` and answer each question by hand — see the [Quickstart](../README.md#quickstart) section of the README.

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
