# Quickstart — Agentic mode (English)

Instead of answering the interactive wizard, you clone the repo, open a Claude Code session in the cloned directory, and paste a single prompt that drives `./setup.sh` end-to-end.

## When to use this mode

- You're already working inside Claude Code and don't want to drop to the shell.
- You want to reproduce the same agent across multiple hosts with identical configuration.
- You prefer reviewing the configuration block in one place before running.

## Shortcut: the `/quickstart` slash command

If you don't want to paste two blocks, open `claude` inside the repo and type `/quickstart`. The command loads the Spanish counterpart of this doc (`docs/agentic-quickstart.es.md` — same content, same structure) + `tests/helper.bash::wizard_answers()` as reference, asks you for the minimum required values in a single message (`AGENT_NAME`, `USER_NAME`, `EMAIL`, `DESTINATION`, optionally `FORK_*` and `VAULT_*`), applies sensible defaults to the rest, and runs the wizard. It's the shortest path from a Claude Code session to a scaffolded agent.

The rest of this document is still useful: it covers the inputs in detail (helpful for auditing, or when you want a single copy-paste block instead of using the slash).

## Prerequisites

Pins and versions below are as of v0.12.0.

- `git` and `claude` installed. `git` is the only hard host requirement `setup.sh` will not auto-install.
- `yq` v4+ and `gh`: optional. If missing, `setup.sh` auto-vendors them into `scripts/vendor/bin/` on first run — `yaml_require_yq` downloads mikefarah/yq v4+, and `ensure_gh` downloads a pinned gh v2.62.0. A `gh` already on `PATH` is used as-is with **no version check**, so make sure it's ≥ 2.40: `scaffold_with_fork` needs `gh repo edit --accept-visibility-change-consequences`, which older builds don't have. On Debian/Ubuntu, **don't run `apt install yq`** — that package is the v3 Python wrapper (incompatible syntax); the launcher detects that and vendors the right binary anyway. To pre-install manually, use `brew install yq` (macOS) or grab the binary from [github.com/mikefarah/yq](https://github.com/mikefarah/yq#install).
- Only if you enable the fork (prompt 14): a GitHub Personal Access Token with `repo` scope (plus `delete_repo` if you plan to use `--delete-fork` later), and push access to the fork owner (your personal account or an org you belong to).
- Local mode only: a Linux host with systemd, plus `jq` and Claude Code ≥ 2.1.51 on the host (the `--login` helper gates on both). Docker mode works on macOS and Linux.

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
5. Claude validates prerequisites, runs `./setup.sh`, and shows you the rendered `NEXT_STEPS.md` when done. That file branches on the deployment mode: the docker version covers `docker compose build`/`up` + in-container login; the local version covers `./setup.sh --login` + systemd units.

---

## The wizard's prompt order (canonical, as of v0.12.0)

The wizard asks up to 52 prompts. The table below mirrors the canonical order the test suite enforces (`tests/helper.bash::wizard_answers()`); conditional prompts list their trigger in "Asked when". Prompts marked "always" fire on every run. Piped stdin must answer exactly the prompts that fire, in this order — nothing more, nothing less.

**The deployment-mode prompt is FIRST, on all platforms** (feature 011, `setup.sh:451`). Any stdin recipe that starts with the agent name is desynced from line one: `ask_choice` loops until it reads a line that is exactly `docker` or `local`, so it would swallow `AGENT_NAME`, `DISPLAY_NAME`, … until one of them happened to match.

| # | Prompt | Asked when | Default | Meaning |
|---|--------|------------|---------|---------|
| 1 | Deployment mode | always (FIRST, all platforms) | `docker` | Choice between `docker` (isolated least-privilege container, recommended) and `local` (host systemd, Linux only). The whole wizard + render branch on it. Choosing `local` prints a security warning: the agent runs as your login user, no container isolation, MFA mandatory. |
| 2 | Agent name (lowercase, no spaces) | always | `my-agent` | Machine identifier, normalized to a DNS-ish label (lowercase, spaces to hyphens). Used for filenames, branches, container names, systemd units. |
| 3 | Use '<normalized>'? | only if normalization changed the input | y | Confirms the normalized name; `n` loops back to re-ask. Never fires if you pipe an already-valid name. |
| 4 | Display name (with emoji) | always | `MyAgent 🤖` | Human-facing display name. |
| 5 | Role description | always | `Admin assistant for my ecosystem` | One-line role (a multi-line persona can come from `--role-file` instead). |
| 6 | Vibe / personality (one line) | always | `Direct, useful, no drama` | One-line personality written into `agent.yml` / CLAUDE.md. |
| 7 | Your full name | always | none — repeats until non-empty | Operator's full name; its first word becomes the nickname default. |
| 8 | Nickname | always | first word of full name | How the agent addresses you. |
| 9 | Timezone | always | auto-detected (`timedatectl` / `/etc/localtime`, fallback `UTC`) | Validated IANA timezone; drives cron/heartbeat scheduling. |
| 10 | Primary email | always | none — validated, required | Reused later as the default for Atlassian / GitHub MCP email sub-prompts. |
| 11 | Preferred language | always | `en` | Choice among `es en mixed`. |
| 12 | Agent destination directory | only if `--destination` was NOT passed | `<installer-parent>/agents/<agent_name>` | Workspace path. The agentic recipe below always passes `--destination`, so **do not emit a stdin line for this prompt**. |
| 13 | Install as system service? | Linux only (macOS prints a skip notice, forces false) | y | Host systemd unit. On macOS the stream has one fewer answer. |
| 14 | Create a GitHub fork for this agent? | always | y | Enables template-sync fork; `n` skips prompts 15-19. |
| 15 | Fork owner (user or org) | fork = y | `your-github-user-or-org` | GitHub owner of the agent's fork. |
| 16 | Fork repo name | fork = y | `<agent>-agent` | Unique per agent; the hostname lives in the branch name, not the repo. |
| 17 | Make the fork private? (recommended) | fork = y | y | A fork of a PUBLIC template cannot be private on GitHub. The wizard probes the template's visibility (`fork_resolve_visibility`, `scripts/lib/fork.sh`) and, on a public+private conflict, branches on the run mode: interactive (TTY) → it lets you pick `proceed-public` or `disable-fork`; **non-interactive (piped stdin — the agentic path) → it DISABLES the fork entirely** (notice on stderr, exit 0), unless you export `FORK_ACCEPT_PUBLIC=1`, which creates it public. This repo's default template **is public**: on the piped path answer `n` here, or answer `y` and export `FORK_ACCEPT_PUBLIC=1` — both yield a PUBLIC fork. A genuinely private fork requires `TEMPLATE_URL` to point at a private template. |
| 18 | Template repo URL | fork = y | this repo's GitHub URL | Upstream used for fork creation and `--sync-template`. |
| 19 | GitHub PAT for fork | fork = y | none (secret, no echo) | `repo` scope (+ `delete_repo` for `--delete-fork`). Fork-only; independent from the GitHub MCP PAT. |
| 20 | Heartbeat notification channel | always | `none` | Choice among `none log telegram`. One-way status pings — NOT the two-way Telegram chat plugin. |
| 21 | Heartbeat bot token (or skip) | channel = telegram | empty = skip (fill `NOTIFY_BOT_TOKEN` in `.env` later) | Non-empty input must pass the token format check; empty skips prompts 22-23 entirely. |
| 22 | Auto-discover chat id by messaging the bot now? | telegram AND token non-empty | y | `y` waits for Enter then polls the Telegram API; piped runs should answer `n` (manual paste path). |
| 23 | Chat ID (or skip) | telegram AND token non-empty AND (auto-discover = n OR discovery failed) | empty = skip (fill `NOTIFY_CHAT_ID` in `.env` later) | Manual chat-id paste. |
| 24 | Install aws? | always (optional MCP 1/6, alphabetical catalog order) | n | No secret sub-prompt. |
| 25 | Install firecrawl? | always (optional MCP 2/6) | n | If `y`, one secret sub-prompt follows: `FIRECRAWL_API_KEY (or skip)`. |
| 26 | Install google-calendar? | always (optional MCP 3/6) | n | If `y`, one secret sub-prompt follows: `GOOGLE_OAUTH_CREDENTIALS (or skip)`. |
| 27 | Install playwright? | always (optional MCP 4/6) | n | No secret. |
| 28 | Install time? | always (optional MCP 5/6) | n | No secret. |
| 29 | Install tree-sitter? | always (optional MCP 6/6) | n | No secret. |
| 30 | Enable Atlassian MCP? | always | n | `y` enters a per-workspace loop of prompts 31-35. |
| 31 | Workspace alias | atlassian = y (per workspace) | none — required | Unique id; uppercased into `ATLASSIAN_<ALIAS>_*` env var names. |
| 32 | Atlassian URL | atlassian = y (per workspace) | none — URL-validated | Base site URL; `/wiki` is appended for Confluence vars. |
| 33 | Email (Atlassian) | atlassian = y (per workspace) | your primary email | Confluence/Jira username for this workspace. |
| 34 | API token (or skip) | atlassian = y (per workspace) | empty = skip (fill `ATLASSIAN_<ALIAS>_TOKEN` in `.env` later) | Workspace API token. |
| 35 | Add another Atlassian workspace? | atlassian = y (after each workspace) | n | `n` exits the loop. |
| 36 | Enable GitHub MCP? | always | n | `y` triggers prompts 37-38. Independent from the fork token. |
| 37 | GitHub account email | github MCP = y | your primary email | Identity for the GitHub MCP. |
| 38 | GitHub PAT for MCP (or skip) | github MCP = y | empty = skip (fill it in `.env` later) | The PAT the GitHub MCP server uses for API calls. |
| 39 | Enable heartbeat (periodic auto-execution)? | always | y | `n` skips prompts 40-41. |
| 40 | Default interval (Nm/Nh or 5-field cron) | heartbeat = y | `30m` | Validated interval/cron. |
| 41 | Default prompt | heartbeat = y | `Status check — return a short plain-text report (uptime, notable issues). No tool use; your stdout is forwarded verbatim to the notifier.` | The prompt each heartbeat tick sends. |
| 42 | Use default opinionated agent principles? (recommended) | always | y | Shipped principles block for CLAUDE.md. |
| 43 | Enable knowledge vault? | always | y | Per-agent Obsidian-style vault at `.state/.vault/` (Karpathy three-layer pattern). `n` skips prompts 44-46. |
| 44 | Seed initial vault structure? | vault = y | y | Scaffolds templates, schema, log. |
| 45 | Register MCPVault server (@bitbonsai/mcpvault)? | vault = y | y | Registers the vault MCP in `.mcp.json`. |
| 46 | Enable QMD hybrid search? | vault = y | n | BM25+vector+rerank; ~300MB embedding model downloaded on first use. |
| 47 | Install code-simplifier? | always (optional plugin 1/5, alphabetical) | n | The 5 always-on plugins (telegram, claude-mem, context7, claude-md-management, security-guidance) are never asked about. |
| 48 | Install commit-commands? | always (optional plugin 2/5) | n | |
| 49 | Install github? | always (optional plugin 3/5) | n | Claude Code plugin — distinct from the GitHub MCP (prompt 36). |
| 50 | Install skill-creator? | always (optional plugin 4/5) | n | |
| 51 | Install superpowers? | always (optional plugin 5/5) | n | |
| 52 | Action | always (after the summary screen) | `proceed` | Choice among `proceed edit abort`; `edit` asks "Edit which field number?" and re-shows the summary. Pipe the literal `proceed`. |

Counts as of v0.12.0: 6 optional catalog MCPs, 5 optional plugins — both lists are derived from `modules/mcps/*.yml` / `modules/plugins/*.yml` and sorted alphabetically, so adding a catalog file changes the count and order. The wizard renders through `gum` when stdin is a TTY, but piped stdin (the agentic path) always takes the plain-`read` fallback — order and semantics are identical.

---

## Block 1 — Configuration (fill in before pasting)

```bash
# ── Deployment mode (asked FIRST by the wizard) ───────
DEPLOYMENT_MODE="docker"               # docker | local — local = host systemd, Linux only, no container isolation

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
FORK_PRIVATE="n"                       # HEADS UP: the TEMPLATE_URL below is PUBLIC, and a fork of a public repo
                                       # CANNOT be private. With "y" + a public template, the piped (non-interactive)
                                       # run DISABLES the fork entirely and carries on. Leave "n" (public fork), or
                                       # set "y" plus FORK_ACCEPT_PUBLIC="1" — same result. Plain "y" only works if
                                       # TEMPLATE_URL points at a PRIVATE repo.
FORK_ACCEPT_PUBLIC="0"                 # 1 = accept a PUBLIC fork when you asked for a private one. It is an
                                       # ENVIRONMENT variable exported to setup.sh, NOT a stdin line.
TEMPLATE_URL="https://github.com/rodrigo-hinojosa-labs/agentic-pod-launcher"   # public
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
   has apt's v3; `ensure_gh` downloads a pinned gh v2.62.0). If `gh` IS on
   PATH, `ensure_gh` accepts it without checking the version — warn me if
   `gh --version` is < 2.40 and FORK_ENABLED="y" (the fork flow needs
   `--accept-visibility-change-consequences`).
2. If FORK_ENABLED="y" and `gh` is already on PATH, export GH_TOKEN=$FORK_PAT
   and verify `gh api user` returns a valid login. If `gh` is missing, skip
   this — `ensure_gh` vendors it during the wizard and the auth check happens
   there.
   FORK VISIBILITY (critical on this path): because stdin is piped, the wizard
   runs NON-interactive. If FORK_PRIVATE="y" and TEMPLATE_URL is a public repo,
   `fork_resolve_visibility` (scripts/lib/fork.sh) disables the fork entirely —
   the scaffold still exits successfully and `git init` still leaves a local
   `<agent>/live` branch, but there is NO fork, no remote, no pushed versioned
   branch (`<host>-<agent>-vN/live`) and no fork backup.
   Before running: if FORK_PRIVATE="y", the template is public
   (check with `gh api repos/<owner>/<repo> --jq .visibility`) and
   FORK_ACCEPT_PUBLIC is not "1", stop and ask me to choose between a public
   fork (FORK_PRIVATE="n" or FORK_ACCEPT_PUBLIC="1") and a private TEMPLATE_URL.
3. Verify $DESTINATION does not exist (`[ ! -e $DESTINATION ]`). If it does, stop.
4. Verify DEPLOYMENT_MODE is exactly "docker" or "local". If it is "local"
   and `uname -s` is not Linux, stop — local mode is Linux/systemd only.
5. If any required value is empty, stop and ask me for the missing ones:
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
truth; if this doc and that function ever disagree, READ THE FUNCTION AND
FOLLOW IT — tests/quickstart-doc.bats only guards part of the sync: the
block markers in wizard_answers(), catalog-MCP coverage, and ES/EN token
parity — not the line-by-line order):

  0. Deployment mode (1 line):      DEPLOYMENT_MODE   ← asked FIRST on all
                                    platforms (feature 011). Literal "docker"
                                    or "local"; anything else re-prompts and
                                    desyncs every following line.
  1. Identity (4 lines):            AGENT_NAME, DISPLAY_NAME, ROLE, VIBE
                                    (a pre-validated AGENT_NAME never triggers
                                    the "Use '<normalized>'?" confirm — do NOT
                                    emit a line for it)
  2. About you (5 lines):           USER_NAME, NICKNAME (empty→first name),
                                    TIMEZONE (empty→auto), EMAIL, LANGUAGE
  3. install_service (Linux only):  INSTALL_SERVICE   ← skip if `uname -s` ≠ Linux
  4. Fork (1 + 5 sub if y):         FORK_ENABLED [if y: FORK_OWNER, FORK_NAME
                                    (empty→<agent>-agent), FORK_PRIVATE,
                                    TEMPLATE_URL, FORK_PAT]
  5. Heartbeat notif (1 + sub):     NOTIFY_CHANNEL [if telegram: NOTIFY_BOT_TOKEN
                                    + auto-discover prompt = "n" + NOTIFY_CHAT_ID;
                                    an EMPTY token skips both follow-ups]
  6. Catalog MCPs (6 opt, alpha):   MCPS_AWS_ENABLED, MCPS_FIRECRAWL_ENABLED,
                                    MCPS_GOOGLE_CALENDAR_ENABLED, MCPS_PLAYWRIGHT_ENABLED,
                                    MCPS_TIME_ENABLED, MCPS_TREE_SITTER_ENABLED
                                    [a "y" adds at most ONE secret line:
                                    firecrawl → FIRECRAWL_API_KEY,
                                    google-calendar → GOOGLE_OAUTH_CREDENTIALS;
                                    the other four have none; empty = fill .env later]
  7. Atlassian MCP (1 + loop if y): ATLASSIAN_ENABLED [if y: per workspace
                                    name|url|email|token + "n" to end loop]
  8. GitHub MCP (1 + sub if y):     GITHUB_MCP_ENABLED [if y: GITHUB_MCP_EMAIL,
                                    GITHUB_MCP_PAT]
  9. Heartbeat schedule (1 + sub):  HEARTBEAT_ENABLED [if y: HEARTBEAT_INTERVAL,
                                    HEARTBEAT_PROMPT]
 10. Principles (1):                USE_DEFAULT_PRINCIPLES
 11. Vault (1 + 3 sub if y):        VAULT_ENABLED [if y: VAULT_SEED_SKELETON,
                                    VAULT_MCP_ENABLED, VAULT_QMD_ENABLED]
 12. Optional plugins (5, alpha):   PLUGIN_CODE_SIMPLIFIER, PLUGIN_COMMIT_COMMANDS,
                                    PLUGIN_GITHUB, PLUGIN_SKILL_CREATOR,
                                    PLUGIN_SUPERPOWERS
 13. Review action (1):             "proceed"   ← literal, no quotes in the printf

EXECUTION:
14. Pipe that stdin to `./setup.sh --destination $DESTINATION` and capture
    stdout+stderr. If FORK_ACCEPT_PUBLIC="1", export it into setup.sh's
    environment (`FORK_ACCEPT_PUBLIC=1 ./setup.sh …`) — it is an env var, NOT a
    stdin line. Because --destination is passed, the wizard never asks for the
    destination — do NOT emit a line for it. DO NOT use --non-interactive
    (that requires a pre-existing agent.yml — different flow).
15. If ANY scaffold step fails (clone, fork creation, fetch, rebase,
    docker-compose render), show me the full error and stop. Don't try to
    "fix" it by silently mutating agent.yml.
16. On success:
    - If stderr contains "disabling the fork to avoid exposing data", the
      scaffold landed with NO fork (public/private conflict resolved against
      it). Say so explicitly: there IS a local `<agent>/live` branch, but do
      NOT report a fork URL or a pushed versioned branch — neither exists.
    - Print the `NEXT_STEPS.md` rendered into $DESTINATION.
    - Summarize per deployment mode:
      · docker mode: live branch created, fork URL (if applicable), pending
        commands — `docker compose build`, `./scripts/agentctl up`, `/login`
        inside tmux (attach via `./scripts/agentctl attach`), Telegram pairing,
        MCP validation.
      · local mode: live branch created, fork URL (if applicable), pending
        commands — `./setup.sh --login` (one-time host OAuth + installs any
        staged systemd units), then verify with `systemctl status
        agent-<name>.service` and `./scripts/agentctl status`.

Don't ask for confirmation between pre-flight and stdin-build steps —
proceed unless a required value is missing or a validation fails.
```

---

## Field reference — required vs default vs never-fabricate

| Category | Fields | Notes |
|---|---|---|
| **Required** (wizard rejects empty input) | `USER_NAME`, `EMAIL` | `USER_NAME` repeats until non-empty; `EMAIL` is validated with no default. |
| **Effectively required** (generic default you almost never want) | `AGENT_NAME` (falls back to `my-agent`), `DESTINATION` (falls back to `<installer-parent>/agents/<name>`) | Empty input is *accepted* — as the fallback default. Treat both as required so you don't scaffold `my-agent` by accident. |
| **Conditionally required** | `FORK_OWNER` + `FORK_PAT` (if fork=y), `NOTIFY_BOT_TOKEN` + `NOTIFY_CHAT_ID` (if telegram), `GITHUB_MCP_PAT` (if GitHub MCP) | Only when you enable the feature. |
| **Safe default** | `DEPLOYMENT_MODE` (`docker`), `VIBE`, `NICKNAME` (auto from first name), `TIMEZONE` (auto), `LANGUAGE` (`en`), `INSTALL_SERVICE` (Linux=`y`), `FORK_NAME` (`<agent>-agent`), `NOTIFY_CHANNEL` (`none`), `HEARTBEAT_*` (30m, default prompt), `USE_DEFAULT_PRINCIPLES` (`y`), `VAULT_*` (all `y` except QMD=`n`) | Accept the default if you have no explicit preference. |
| **Default that is NOT safe on the piped path** | `FORK_PRIVATE` (wizard default: `y`) | Against this repo's public template, `y` without `FORK_ACCEPT_PUBLIC=1` disables the fork on every non-interactive run. See prompt 17. |
| **NEVER fabricate** | `FORK_PAT`, `NOTIFY_BOT_TOKEN`, `NOTIFY_CHAT_ID`, `GITHUB_MCP_PAT`, `FIRECRAWL_API_KEY`, `GOOGLE_OAUTH_CREDENTIALS`, every `ATLASSIAN_*` token | User secrets. If missing and the feature requires them, disable the feature or stop and ask. |

---

## Validations applied by the wizard

The wizard (both interactive and agentic) validates inputs before accepting them. If the slash command pipes an invalid value, the wizard re-prompts and hangs waiting for input that never arrives — so the slash command **must validate before piping**:

| Field | Rule | Valid example | Invalid example |
|---|---|---|---|
| `DEPLOYMENT_MODE` | Must be literally `docker` or `local` (choice prompt: any other value re-prompts and desyncs the pipe) | `docker`, `local` | `Docker`, `container`, `k8s` |
| `AGENT_NAME` | DNS label: lowercase + digits + hyphens, no leading/trailing hyphen, no double hyphen, 1..63 chars | `my-agent`, `agent01` | `My_Agent`, `-agent`, `agent--01` |
| `EMAIL` (any) | Matches `user@host.tld` (simplified RFC 5322) | `alice@example.com` | `alice@example`, `not-an-email` |
| `TIMEZONE` | Must exist under `/usr/share/zoneinfo/` or match `Region/City` pattern | `America/Santiago`, `UTC` | `Chile time`, `2 hours ago` |
| `HEARTBEAT_INTERVAL` | `Nm` / `Nh` or 5-field cron expression | `30m`, `2h`, `0 * * * *` | `30 minutes`, `every hour` |
| `NOTIFY_BOT_TOKEN` (if non-empty) | `<digits>:<base64-like 25+>` | `123456789:AAEhBP0...` | `my-token`, `123:short` |
| `*_URL` (Atlassian, fork) | http(s) only, no whitespace | `https://acme.atlassian.net` | `acme.atlassian.net`, `ftp://...` |
| Atlassian workspace alias | Letters, digits, underscore only (interpolated into `ATLASSIAN_<ALIAS>_TOKEN`; a hyphen produces an invalid systemd variable name) | `work`, `cenco_corp` | `cenco-corp`, `my team` |
| `UID`/`GID` | Non-negative integer (auto-detected, never asked) | `1000`, `501` | `-1`, `abc` |

The same re-prompt-on-mismatch behavior applies to every choice prompt: `LANGUAGE` (`es`/`en`/`mixed`), `NOTIFY_CHANNEL` (`none`/`log`/`telegram`) and the final action (`proceed`/`edit`/`abort`).

If the slash command can't validate locally (e.g. the token is opaque), pipe the raw value and let the wizard reject it. If the wizard re-prompts, the piped stdin desyncs — catch that case by reporting "wizard rejected X — re-run quickstart with a valid value".

---

## After the scaffold: first boot, per mode

The scaffold leaves a workspace at `$DESTINATION` with a mode-specific `NEXT_STEPS.md`. Summary of both paths (the rendered file is the authoritative, per-agent version):

### Docker mode (default)

Build, then boot:

```bash
cd "$DESTINATION"
docker compose build
./scripts/agentctl up          # == docker compose up -d
```

Authenticate once. `NEXT_STEPS.md` presents two paths, and the **headless token is the recommended one** — on macOS the interactive credential does not persist across boots (VirtioFS cache incoherence on the `~/.claude` bind-mount), so Claude reverts to "Not logged in" on every boot:

```bash
claude setup-token                      # on the HOST; authorize, paste the code in the terminal
$EDITOR "$DESTINATION/.env"             # set CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-…
./scripts/agentctl up                   # boots already authenticated — no /login needed
```

Fallback (interactive `/login`, inside the container's tmux session):

```bash
./scripts/agentctl attach      # retry-loop wrapper around docker exec -u agent … tmux attach
```

Pick a theme, confirm trust on `/workspace`, run `/login`, authorize in the browser, paste the code back, then `/exit`. Credentials land in `$DESTINATION/.state/` (bind-mounted to the container's `/home/agent`) and survive rebuilds. The watchdog respawns the session; re-attach with the same command. Detach without killing the container with `Ctrl-b d`.

Daily driving:

```bash
./scripts/agentctl status      # heartbeat dashboard
./scripts/agentctl logs -f     # tail claude.log
./scripts/agentctl doctor      # full system diagnostic (exit 0 clean / 1 warnings / 2 failures)
```

### Local mode (Linux/systemd)

No container, no `docker compose`. The scaffold rendered `scripts/local/` helpers (login, bootstrap, healthcheck, kill-switch, plus the qmd/vault/wiki-graph entrypoints when those features are on) and either installed the systemd units — if passwordless `sudo -n` worked at scaffold time — or staged them in the workspace for later. One manual step does the rest:

```bash
cd "$DESTINATION"
./setup.sh --login
```

`--login` refuses to run in a docker-mode workspace (it reads `deployment.mode` from `agent.yml`), and it is idempotent — re-running it is safe. In order, `scripts/local/agent-login.sh`:

1. Gates on Claude Code ≥ 2.1.51 and `jq` on the host (Remote Control requires both) and pre-seeds the onboarding flags.
2. Runs the guided one-time **full-scope OAuth login** — it opens Claude Code, you run `/login`, complete the browser flow, then `/exit`. Skipped if `.state/.claude/.credentials.json` already exists. The inference-only token from `claude setup-token` does NOT work here (Remote Control rejects it), which is why this step is interactive. Headless host: tunnel the OAuth callback port over SSH first.
3. Re-applies workspace trust and pre-accepts the "Enable Remote Control?" prompt (the login resets both; without them the unit blocks on a prompt with no TTY).
4. Provisions the MCP runtimes into `~/.local/bin` via `scripts/local/agent-bootstrap.sh` — uv/uvx, bun, github-mcp-server, with version pins mirroring the docker image's Dockerfile ARGs.
5. **Installs and enables the units — this is the step that prompts for `sudo`** (they are system units under `/etc/systemd/system`): `agent-<agent_name>.service`, the ~5-min healthcheck timer, and, when the corresponding feature is enabled, the qmd reindex timer + `qmd-watch` watcher service, the vault-backup timer, and the wiki-graph timer. It then kicks off a background first-run QMD index build and wiki-graph derive.

Verify (on the host):

```bash
systemctl is-active agent-<agent_name>.service        # expect: active
journalctl -u agent-<agent_name>.service -f           # look for the session-url / connected signal
systemctl list-timers 'agent-<agent_name>-*'          # healthcheck + qmd/vault/wiki-graph timers
systemctl is-active agent-<agent_name>-qmd-watch.service   # the vault watcher is a service, not a timer
./scripts/agentctl status                             # unit state + connection signal + login + RAG freshness
./scripts/agentctl doctor                             # local diagnostic (exit 0 clean / 1 warnings / 2 failures)
```

You drive the agent from claude.ai/code and the mobile app — "active" is not the same as "controllable", which is why `status` and `doctor` both look for a recent connection signal in the journal. Docker-only `agentctl` subcommands (`up`, `start`, `stop`, `restart`, `ps`, `attach`, `shell`, `run`, `logs`, `mcp`) refuse to run in local mode: they exit 2 with a `systemctl`/`journalctl` hint instead of touching Docker. `status` and `doctor` work in both modes (local mode reads systemd instead of the container); `heartbeat` degrades to three maintenance actions that have a local equivalent — `heartbeat qmd-reindex`, `heartbeat backup-vault`, `heartbeat wiki-graph` — and exits 2 on anything else. Emergency stop: `./scripts/local/agent-killswitch.sh`.

---

## Security

⚠ The PAT lives in the Claude session's context. If your memory system (`claude-mem`, similar plugins) indexes sessions, **treat the token as compromised** and revoke it at https://github.com/settings/tokens when you're done. Generate a new one for ongoing use.

Local mode adds its own risk surface: the agent runs as **your login user** with no container isolation, so whoever controls the claude.ai account effectively controls the host. The wizard prints this warning when you pick `local`; MFA on the account is mandatory.

## Alternative: interactive wizard

If you prefer the traditional terminal-prompt flow, run `./setup.sh` and answer each question by hand — see the [Quickstart](../README.md#quickstart) section of the README.

---

## Telegram (two-way chat)

Once the agent is up and running, if you want to DM it from your phone: configure the official channel from the `telegram@claude-plugins-official` plugin (one of the 5 always-on plugins — the wizard never asks about it). It enables DMs to the agent from Telegram with pairing + allowlist access control.

Complements the heartbeat: heartbeat = the agent reaches out to you; Telegram = you reach out to the agent.

**Docker mode: the scaffolded flow already does most of this for you.** The rendered `NEXT_STEPS.md` (steps 3-4) covers it: after you authenticate, the supervisor launches an in-container wizard that asks for the BotFather token, writes `/workspace/.env` (0600), and the watchdog then relaunches Claude with `--channels plugin:telegram@claude-plugins-official`. You only do the pairing. The manual recipe below is for configuring the channel by hand — which is the local-mode path, and the fallback if the in-container wizard didn't run.

### Requirements

- `bun` on the system (the plugin's MCP server is TypeScript and starts via `bun run`). **Without `bun`, the server dies silently when spawned and the `telegram__*` tools never appear.**
  - Docker mode: already baked into the image (bun 1.3.14, pinned in `docker/Dockerfile`) — nothing to do.
  - Local mode: `./setup.sh --login` installs the same pinned bun into `~/.local/bin` via `scripts/local/agent-bootstrap.sh`. To install it yourself: `curl -fsSL https://bun.sh/install | bash`.
- Plugin enabled in the agent's `settings.json` (docker: `/home/agent/.claude`, local: `<workspace>/.state/.claude`):
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
