---
description: Scaffold a new agent end-to-end via setup.sh — single-prompt agentic mode
allowed-tools: Read, Bash, Glob, Grep
---

You are running inside the **agentic-pod-launcher** repo. The user wants to scaffold a new agent without answering 30+ interactive prompts. You drive `./setup.sh` for them.

## Steps

1. **Load context** (read both — they're the source of truth, kept in sync by every PR):
   - `docs/agentic-quickstart.es.md` — full prompt order, field semantics, security caveats. The user's preferred language is Spanish; default to it for any human-facing message you produce.
   - `tests/helper.bash` — look specifically at the `wizard_answers()` function. The order of `printf` statements there is the **canonical** wizard prompt order. If anything in the doc disagrees with `wizard_answers()`, the function wins.
   - Optionally: skim `setup.sh` lines 187–478 if you need to confirm a specific prompt's text or default.

2. **Ask the user for the minimum required values in ONE single message.** Use this template (fill the `?` slots; everything else has a safe default):

   ```
   Para scaffoldear el agente necesito 4 valores obligatorios + algunos opcionales:

   Obligatorios:
   - AGENT_NAME (lowercase, sin espacios): ?
   - DISPLAY_NAME (con emoji opcional): ?
   - ROLE (una línea, qué hace este agente): ?
   - USER_NAME (tu nombre completo): ?
   - EMAIL: ?

   Opcionales (Enter para aceptar defaults):
   - DESTINATION (default: $HOME/Claude/Agents/<agent_name>): ?
   - VIBE (default: "Direct, useful, no drama"): ?
   - LANGUAGE (es/en/mixed, default: es): ?

   Fork de GitHub (default: y, requiere PAT):
   - FORK_ENABLED (y/n): ?
   - FORK_OWNER (si y): ?
   - FORK_PAT (si y, ghp_…, NUNCA lo invento): ?

   Vault de conocimiento (default: y/y/y/n):
   - VAULT_ENABLED (y/n): ?
   - VAULT_QMD_ENABLED (hybrid search, +300MB la 1ra vez, default n): ?

   Heartbeat notifications (default: none):
   - NOTIFY_CHANNEL (none/log/telegram): ?
   ```

   If `NOTIFY_CHANNEL=telegram` and the user didn't pre-supply `NOTIFY_BOT_TOKEN`+`NOTIFY_CHAT_ID`, offer to defer the channel (set to `none`) and configure later via `heartbeatctl set-notifier`. Same for `GITHUB_MCP_PAT` if `GITHUB_MCP_ENABLED=y`.

3. **Apply defaults** for everything the user didn't override:
   - `NICKNAME` = first word of `USER_NAME`
   - `TIMEZONE` = `$(timedatectl show --property=Timezone --value 2>/dev/null || readlink /etc/localtime | sed 's|.*zoneinfo/||' || echo UTC)`. On macOS without `timedatectl`, the second path or `date +%Z` works; if you can't compute it confidently, ask.
   - `INSTALL_SERVICE` = `n` on macOS (the wizard skips the prompt anyway), `y` on Linux
   - `FORK_NAME` = `${AGENT_NAME}-agent`
   - `FORK_PRIVATE` = `y`
   - `TEMPLATE_URL` = `https://github.com/rodrigo-hinojosa-labs/agentic-pod-launcher`
   - `HEARTBEAT_ENABLED` = `y`, `HEARTBEAT_INTERVAL` = `30m`, `HEARTBEAT_PROMPT` = the long default in the doc
   - `USE_DEFAULT_PRINCIPLES` = `y`
   - `VAULT_SEED_SKELETON` = `y`, `VAULT_MCP_ENABLED` = `y`
   - All five optional plugins (`code-simplifier`, `commit-commands`, `github`, `skill-creator`, `superpowers`) = `n` unless the user asked for them

4. **Pre-flight checks** (stop and report on failure — do not silently work around):
   - `command -v yq && yq --version` (must be v4+)
   - `command -v git`
   - If `FORK_ENABLED=y`: `command -v gh` AND `GH_TOKEN=$FORK_PAT gh api user` returns a login
   - `[ ! -e "$DESTINATION" ]` — destination must not exist
   - On macOS, warn if `Docker.app` isn't running (the user will need it to `docker compose build` later, but it's not blocking the wizard).

5. **Build the wizard stdin** with `printf`, in this exact order (mirror of `wizard_answers()`). Skip the `install_service` line if `uname -s` ≠ Linux:

   ```
   identity:    AGENT_NAME, DISPLAY_NAME, ROLE, VIBE
   about you:   USER_NAME, NICKNAME, TIMEZONE, EMAIL, LANGUAGE
   service:     INSTALL_SERVICE   (Linux only)
   fork:        FORK_ENABLED [y → FORK_OWNER, FORK_NAME, FORK_PRIVATE, TEMPLATE_URL, FORK_PAT]
   notify:      NOTIFY_CHANNEL [telegram → NOTIFY_BOT_TOKEN, "n" (skip auto-discover), NOTIFY_CHAT_ID]
   atlassian:   ATLASSIAN_ENABLED  (always "n" for this slash flow — defer to later)
   github mcp:  GITHUB_MCP_ENABLED [y → GITHUB_MCP_EMAIL, GITHUB_MCP_PAT]
   heartbeat:   HEARTBEAT_ENABLED [y → HEARTBEAT_INTERVAL, HEARTBEAT_PROMPT]
   principles:  USE_DEFAULT_PRINCIPLES
   vault:       VAULT_ENABLED [y → VAULT_SEED_SKELETON, VAULT_MCP_ENABLED, VAULT_QMD_ENABLED]
   plugins:     PLUGIN_CODE_SIMPLIFIER, PLUGIN_COMMIT_COMMANDS, PLUGIN_GITHUB,
                PLUGIN_SKILL_CREATOR, PLUGIN_SUPERPOWERS    (alphabetical)
   action:      "proceed"
   ```

6. **Run** `./setup.sh --destination "$DESTINATION"` with that stdin piped in. Capture stdout+stderr; show it if anything fails. Never use `--non-interactive` from this slash command — that flag requires a pre-existing `agent.yml`, which is a different flow.

7. **On failure**, show the full error and stop. Do not edit `agent.yml` or any rendered file to "fix" anything without user confirmation. Common fixable errors: `yq` missing → `brew install yq` / `apt install yq`. `gh api user` failing → wrong PAT or expired token. `$DESTINATION` exists → user must `rm -rf` or pick a new path.

8. **On success**:
   - `cat $DESTINATION/NEXT_STEPS.md` and show it.
   - Summarize: live branch (e.g. `<host>-<agent>-v1/live`), fork URL (if applicable), pending actions (`docker compose build && docker compose up -d`, `/login` inside tmux, Telegram pairing, MCP validation).

## Hard rules

- **Never fabricate secrets.** PATs, Telegram bot tokens, chat IDs, Atlassian API tokens — if missing, ask or defer the feature. Inventing one looks like the wizard worked, then breaks at runtime with a confusing error.
- **Don't silently mutate `agent.yml`.** Everything is rendered from it; edits get clobbered on `--regenerate`. If a value is wrong, re-run the wizard or ask the user.
- **Respect `--destination` collision.** If the path exists, stop. The wizard refuses to overwrite by design.
- **Stay in Spanish for human-facing messages** unless the user has signaled otherwise. The repo's user is Spanish-speaking; their conventions are documented in `.claude-personal` memory.
