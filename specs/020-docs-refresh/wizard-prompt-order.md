# Canonical Wizard Prompt Order (v0.12.0)

Phase 0 artifact — the SC-002 oracle. Extracted from
`tests/helper.bash::wizard_answers()` (the order the suite enforces) and verified
against `scripts/lib/wizard.sh` / `setup.sh` prompt wording. Both agentic
quickstarts MUST mirror this table one-to-one (FR-003).

| # | Prompt | Asked when | Default | Semantics | Source |
|---|--------|------------|---------|-----------|--------|
| 1 | Deployment mode | always (asked FIRST on all platforms, feature 011) | docker | ask_choice between 'docker' (isolated least-privilege container, recommended) and 'local' (host systemd, Linux only); the whole wizard + render branches on this choice. | setup.sh:451 |
| 2 | Agent name (lowercase, no spaces) | always | my-agent | Machine identifier normalized to a DNS-ish label (lowercase, spaces to hyphens) used for filenames, branches, container names, and systemd units. | setup.sh:474 |
| 3 | Use '<normalized>'? (normalization confirm) | only when normalize_agent_name changed the raw input | y | ask_yn confirming the normalized agent name; 'n' loops back to re-ask the name. | setup.sh:478 |
| 4 | Display name (with emoji) | always | MyAgent 🤖 | Human-facing display name for the agent. | setup.sh:486 |
| 5 | Role description | always | Admin assistant for my ecosystem | One-line role description (a multi-line persona can come from --role-file instead). | setup.sh:487 |
| 6 | Vibe / personality (one line) | always | Direct, useful, no drama | One-line personality descriptor written into agent.yml / CLAUDE.md. | setup.sh:488 |
| 7 | Your full name | always | (none — ask_required, repeats until non-empty) | Operator's full name; its first word becomes the nickname default. | setup.sh:503 |
| 8 | Nickname (how the agent should address you) | always | first word of full name | How the agent addresses the user in conversation. | setup.sh:505 |
| 9 | Timezone | always | auto-detected via timedatectl or /etc/localtime, fallback UTC | ask_validated with validate_timezone; drives cron/heartbeat scheduling context. | setup.sh:512 |
| 10 | Primary email | always | (none — ask_validated with validate_email, required) | User email, later reused as the default for Atlassian and GitHub MCP email sub-prompts. | setup.sh:513 |
| 11 | Preferred language | always | en | ask_choice among 'es en mixed' — the language the agent replies in. | setup.sh:514 |
| 12 | Agent destination directory | only when --destination flag was NOT passed (the canonical test path passes it, so wizard_answers never answers this) | <parent-of-installer>/agents/<agent_name> | Workspace path to scaffold into; normalized/expanded and validated in a re-prompt loop. | setup.sh:540 |
| 13 | Install as system service? | Linux only (macOS prints a skip notice and forces false) | y | ask_yn for installing a host systemd unit; wizard_answers auto-detects via uname and answers 'n' on Linux. | setup.sh:555 (skip: setup.sh:550-553; helper.bash:138) |
| 14 | Create a GitHub fork for this agent? | always | y | ask_yn enabling template-sync fork; canonical test path answers 'n' which skips all 5 fork sub-prompts. | setup.sh:582 |
| 15 | Fork owner (user or org) | fork = y | your-github-user-or-org | GitHub owner for the agent's fork repo. | setup.sh:592 |
| 16 | Fork repo name | fork = y | <agent_name%-agent>-agent | Fork repo name, unique per agent (hostname lives in the branch name, not the repo). | setup.sh:593 |
| 17 | Make the fork private? (recommended) | fork = y | y | ask_yn; a fork of a PUBLIC template cannot be private — fork_resolve_visibility may override after probing. | setup.sh:594 |
| 18 | Template repo URL | fork = y | https://github.com/rodrigo-hinojosa-labs/agentic-pod-launcher | Upstream template URL used for fork creation and --sync-template. | setup.sh:595 |
| 19 | GitHub Personal Access Token for fork | fork = y | (none — ask_secret, no echo) | PAT with 'repo' scope (plus 'delete_repo' for --delete-fork) used only for fork operations. | setup.sh:597 |
| 20 | Heartbeat notification channel | always | none | ask_choice among 'none log telegram' — where heartbeat pings report (one-way; NOT the two-way Telegram chat plugin). | setup.sh:626 |
| 21 | Heartbeat bot token (or skip) | channel = telegram | empty = skip (fill NOTIFY_BOT_TOKEN in .env later) | ask_secret in a loop; non-empty must pass validate_telegram_token, empty breaks out and later triggers the 'credentials incomplete' warning. | setup.sh:632 |
| 22 | Auto-discover chat id by messaging the bot now? | channel = telegram AND bot token non-empty | y | ask_yn; 'y' waits for Enter then polls the Telegram getUpdates API for the chat id; 'n' takes the manual paste path (canonical test path answers 'n'). | setup.sh:648 (press-Enter read: setup.sh:652) |
| 23 | Chat ID (or skip to fill in .env later) | channel = telegram AND token non-empty AND (auto-discover = n, OR auto-discovery failed) | empty = skip (fill NOTIFY_CHAT_ID in .env later) | Manual Telegram chat id paste; empty leaves pings disabled until .env is completed. | setup.sh:665 (failure fallback: setup.sh:662) |
| 24 | Install aws? (optional MCP 1/6) | always (catalog iteration, alphabetical) | n | ask_yn opt-in for the aws MCP from modules/mcps/aws.yml; no secret sub-prompt (secret_env_var null). | setup.sh:719 (order: scripts/lib/mcp-catalog.sh:46 sort) |
| 25 | Install firecrawl? (optional MCP 2/6) | always | n | ask_yn opt-in; if 'y', a secret sub-prompt 'FIRECRAWL_API_KEY (or skip)' (ask_secret) follows immediately. | setup.sh:719 (secret sub-prompt: setup.sh:733; modules/mcps/firecrawl.yml) |
| 26 | Install google-calendar? (optional MCP 3/6) | always | n | ask_yn opt-in; if 'y', secret sub-prompt 'GOOGLE_OAUTH_CREDENTIALS (or skip)' follows. | setup.sh:719 (secret sub-prompt: setup.sh:733; modules/mcps/google-calendar.yml) |
| 27 | Install playwright? (optional MCP 4/6) | always | n | ask_yn opt-in; no secret. | setup.sh:719 |
| 28 | Install time? (optional MCP 5/6) | always | n | ask_yn opt-in; no secret. | setup.sh:719 |
| 29 | Install tree-sitter? (optional MCP 6/6) | always | n | ask_yn opt-in; no secret. | setup.sh:719 |
| 30 | Enable Atlassian MCP? | always | n | ask_yn; 'y' enters a per-workspace loop of 5 sub-prompts (alias, URL, email, token, add-another). | setup.sh:750 |
| 31 | Workspace alias (e.g. personal, work) | atlassian = y (per workspace) | (none — ask_required) | Unique identifier for this Atlassian account; uppercased into ATLASSIAN_<ALIAS>_* env var names. | setup.sh:753 |
| 32 | Atlassian URL (e.g. https://yourco.atlassian.net) | atlassian = y (per workspace) | (none — ask_validated validate_url) | Base Atlassian site URL; /wiki is appended for Confluence env vars. | setup.sh:754 |
| 33 | Email (Atlassian) | atlassian = y (per workspace) | user's primary email | Account email for this workspace (Confluence/Jira username). | setup.sh:755 |
| 34 | API token (or skip) (Atlassian) | atlassian = y (per workspace) | empty = skip (fill ATLASSIAN_<ALIAS>_TOKEN in .env later) | ask_secret for the workspace API token. | setup.sh:761 |
| 35 | Add another Atlassian workspace? | atlassian = y (after each workspace) | n | ask_yn loop control; 'n' exits the workspace loop. | setup.sh:778 |
| 36 | Enable GitHub MCP? | always | n | ask_yn; 'y' triggers 2 sub-prompts (email, PAT) — this PAT is independent from the fork token. | setup.sh:785 |
| 37 | GitHub account email | github MCP = y | user's primary email | ask_validated email for the GitHub MCP identity. | setup.sh:787 |
| 38 | GitHub Personal Access Token for MCP (or skip) | github MCP = y | empty = skip (fill GITHUB_PAT in .env later) | ask_secret for the API PAT the GitHub MCP server uses. | setup.sh:791 |
| 39 | Enable heartbeat (periodic auto-execution)? | always | y | ask_yn gate for the heartbeat feature; canonical test path answers 'y'. | setup.sh:798 |
| 40 | Default interval (Nm/Nh or 5-field cron) | heartbeat = y | 30m | ask_validated with validate_cron_or_interval; canonical test path answers '30m'. | setup.sh:802 |
| 41 | Default prompt (heartbeat) | heartbeat = y | Status check — return a short plain-text report (uptime, notable issues). No tool use; your stdout is forwarded verbatim to the notifier. | The prompt each heartbeat tick sends to the agent; canonical test path answers 'ok'. | setup.sh:803 |
| 42 | Use default opinionated agent principles? (recommended) | always | y | ask_yn choosing the shipped principles block for CLAUDE.md. | setup.sh:810 |
| 43 | Enable knowledge vault? | always | y (NOTE: wizard_answers' common path answers 'n' despite the wizard default being y) | ask_yn gate for the per-agent Obsidian-style vault at .state/.vault/ (Karpathy three-layer pattern). | setup.sh:819 (helper.bash:96,174-180) |
| 44 | Seed initial vault structure (templates, schema, log)? | vault = y | y | ask_yn to scaffold the initial vault directory skeleton. | setup.sh:824 |
| 45 | Register MCPVault server (@bitbonsai/mcpvault)? | vault = y | y | ask_yn to register the vault MCP server in .mcp.json. | setup.sh:825 |
| 46 | Enable QMD hybrid search (BM25+vector+rerank, ~300MB embedding model on first use)? | vault = y | n | ask_yn for QMD semantic search; 'y' in wizard_answers implies vault=on (helper.bash:129). | setup.sh:826 |
| 47 | Install code-simplifier? (optional plugin 1/5) | always (catalog iteration, alphabetical) | n | ask_yn opt-in plugin; the 5 always-on plugins (telegram, claude-mem, context7, claude-md-management, security-guidance) are never asked about. | setup.sh:862 (order: scripts/lib/plugin-catalog.sh:44 sort) |
| 48 | Install commit-commands? (optional plugin 2/5) | always | n | ask_yn opt-in plugin. | setup.sh:862 |
| 49 | Install github? (optional plugin 3/5) | always | n | ask_yn opt-in plugin (distinct from the GitHub MCP asked earlier). | setup.sh:862 |
| 50 | Install skill-creator? (optional plugin 4/5) | always | n | ask_yn opt-in plugin. | setup.sh:862 |
| 51 | Install superpowers? (optional plugin 5/5) | always | n | ask_yn opt-in plugin; the only one wizard_answers parameterizes (superpowers=on\|off, helper.bash:183). | setup.sh:862 |
| 52 | Action (review loop) | always (after the summary screen; repeats until proceed/abort) | proceed | ask_choice among 'proceed edit abort'; 'edit' triggers the sub-prompt 'Edit which field number?' (default 1, setup.sh:1003) then re-shows the summary. | setup.sh:994 |

**Notes**:
- Canonical answer stream = tests/helper.bash::wizard_answers (lines 107-186): deployment_mode, name, display, role, vibe, Alice, Alice, UTC, a@b.com, en, [n if Linux], n (fork), notify channel [+telegram extras], n x6 (MCPs), n n (atlassian+github), y 30m ok (heartbeat), y (principles), vault block (n | y y y y/n), n x4 + superpowers (plugins), proceed.
- The destination prompt (setup.sh:540) is part of the wizard but the canonical test path always passes --destination, so wizard_answers never emits an answer for it (helper.bash:88-89). Agentic quickstarts that pass --destination must likewise NOT answer it.
- Optional MCP order is derived, not hardcoded: mcp_catalog_list iterates modules/mcps/*.yml where type=optional and pipes through `sort` (scripts/lib/mcp-catalog.sh:40-46). Current sorted set (verified via grep of modules/mcps/): aws, firecrawl, google-calendar, playwright, time, tree-sitter. Adding a catalog file changes the count and order — helper.bash:163-167 and the e2e answer arrays must be updated in lockstep (see memory 'wizard prompt test touchpoints').
- Optional plugin order is likewise sorted (scripts/lib/plugin-catalog.sh:33-44): code-simplifier, commit-commands, github, skill-creator, superpowers. All five currently have requires_explicit_confirm: false (verified via grep of modules/plugins/*.yml), so the conflict-confirm sub-prompt at setup.sh:868 never fires today.
- MCP secret sub-prompts (setup.sh:733) only fire when the parent Install? was 'y' AND the catalog entry has secret_env_var: firecrawl → FIRECRAWL_API_KEY, google-calendar → GOOGLE_OAUTH_CREDENTIALS (all others null). Empty input is accepted (fill .env later).
- Conditional prompts that shift positions: (a) 'Use <normalized>?' only when the agent name got normalized; (b) install_service only on Linux — on macOS the stream has one fewer answer; (c) fork=y adds 5 sub-prompts; (d) telegram adds 1-3 sub-prompts (token; then auto-discover y/n + chat id only if token non-empty — empty token skips straight to the 'credentials incomplete' warning, helper.bash:141-156); (e) atlassian=y adds 5 per workspace (looped); (f) github MCP=y adds 2; (g) heartbeat=n skips interval+prompt; (h) vault=n collapses the vault block to 1 answer.
- Sections with NO prompt (informational only): host machine echo (setup.sh:520-522), Claude profile (setup.sh:559-572), always-on MCP listing (setup.sh:686), always-on plugin listing (setup.sh:835-836).
- Wizard defaults vs canonical test answers differ on: fork (default y, test answers n), vault (default y, test answers n), notification channel (both none), MCPs/plugins (both n). Quickstarts mirroring the *wizard UX* should use the setup.sh defaults column; quickstarts mirroring the *test stream* should use the wizard_answers values.
- gum caveat: when stdin is a TTY and gum is available, prompts render via scripts/lib/wizard-gum.sh instead of plain read, but the order and semantics are identical; piped stdin (the agentic path) always takes the plain-read scripts/lib/wizard.sh fallback (CLAUDE.md gotcha + wizard.sh:1-2).
- Not covered by the canonical stream (helper.bash:100-104): --in-place mode adds a workspace-path prompt; those paths need a custom heredoc.
