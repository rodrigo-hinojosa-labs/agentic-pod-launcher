#!/usr/bin/env bash
# setup.sh — Wizard + regenerate orchestrator for agentic-pod-launcher

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/scripts/lib/yaml.sh"
source "$SCRIPT_DIR/scripts/lib/render.sh"
source "$SCRIPT_DIR/scripts/lib/plugin-catalog.sh"

GUM=""  # populated by ensure_gum

# Detect which claude CLI variant is installed. Preference order:
# claude-enterprise > claude-personal > claude. Falls back to "claude"
# if none are found (user will install it later).
detect_claude_cli() {
  for bin in claude-enterprise claude-personal claude; do
    if command -v "$bin" &>/dev/null; then
      echo "$bin"
      return 0
    fi
  done
  echo "claude"
}

# Ensure gum is available. Returns 0 if found or downloaded; 1 otherwise.
# On success, $GUM points to a usable gum binary.
ensure_gum() {
  # 1. Prefer an already-installed gum on PATH.
  if command -v gum &>/dev/null; then
    GUM="gum"
    return 0
  fi

  # 2. Check vendor dir (previous auto-download).
  local vendor_bin="$SCRIPT_DIR/scripts/vendor/bin/gum"
  if [ -x "$vendor_bin" ]; then
    GUM="$vendor_bin"
    return 0
  fi

  # 3. Auto-download from GitHub releases.
  local version="0.14.5"
  local os arch
  os=$(uname -s | tr '[:upper:]' '[:lower:]')
  arch=$(uname -m)
  case "$arch" in
    x86_64|amd64) arch="x86_64" ;;
    arm64|aarch64) arch="arm64" ;;
    *)
      echo "WARN: gum auto-download not supported for arch '$arch'; falling back to plain wizard." >&2
      return 1
      ;;
  esac
  case "$os" in
    darwin|linux) ;;
    *)
      echo "WARN: gum auto-download not supported for OS '$os'; falling back to plain wizard." >&2
      return 1
      ;;
  esac

  local pkg="gum_${version}_${os}_${arch}"
  local url="https://github.com/charmbracelet/gum/releases/download/v${version}/${pkg}.tar.gz"
  local vendor_dir="$SCRIPT_DIR/scripts/vendor/bin"

  mkdir -p "$vendor_dir"
  echo "▸ Bootstrapping gum v${version} (one-time, ~5MB)..." >&2
  if ! curl -sL --fail "$url" -o "$vendor_dir/gum.tar.gz" 2>/dev/null; then
    echo "WARN: gum download failed; falling back to plain wizard." >&2
    rm -f "$vendor_dir/gum.tar.gz"
    return 1
  fi
  # Extract just the gum binary (inside pkg dir)
  tar -xzf "$vendor_dir/gum.tar.gz" -C "$vendor_dir" --strip-components=1 "${pkg}/gum" 2>/dev/null || {
    # Fallback: extract all, then move
    tar -xzf "$vendor_dir/gum.tar.gz" -C "$vendor_dir"
    if [ -f "$vendor_dir/${pkg}/gum" ]; then
      mv "$vendor_dir/${pkg}/gum" "$vendor_dir/gum"
      rm -rf "$vendor_dir/${pkg}"
    fi
  }
  rm -f "$vendor_dir/gum.tar.gz"

  if [ -x "$vendor_dir/gum" ]; then
    GUM="$vendor_dir/gum"
    echo "  ✓ gum installed at $vendor_dir/gum" >&2
    return 0
  fi
  echo "WARN: gum extraction failed; falling back to plain wizard." >&2
  return 1
}

# Decide which wizard helper set to load. Prefer gum when:
# - stdin is a TTY (interactive user, not piped test input)
# - and gum can be installed/found
load_wizard_helpers() {
  if [ -t 0 ] && ensure_gum; then
    source "$SCRIPT_DIR/scripts/lib/wizard-gum.sh"
  else
    source "$SCRIPT_DIR/scripts/lib/wizard.sh"
  fi
}

MODE="auto"
FORCE_CLAUDE_MD=false
UNINSTALL_PURGE=false
UNINSTALL_DELETE_FORK=false
UNINSTALL_YES=false
UNINSTALL_NUKE=false
DESTINATION=""
IN_PLACE=false

print_usage() {
  cat << 'EOF'
Usage: ./setup.sh [options]

Options:
  (no flags)           Interactive wizard on first run; regenerate on subsequent runs.
  --regenerate         Re-render derived files from agent.yml (keeps CLAUDE.md).
  --force-claude-md    With --regenerate, also overwrite CLAUDE.md.
  --sync-template      Pull template improvements into this fork. Fetches
                       upstream/main, fast-forwards local main, pushes it to
                       origin, and rebases the live branch on top.
  --non-interactive    Fail if agent.yml missing; no prompts.
  --reset              Delete agent.yml and re-run the wizard.
  --uninstall          Remove installed services, agent scripts, timers, tmux
                       sessions, and generated files inside the repo.
                       Preserves agent.yml and .env unless --purge is given.
  --purge              With --uninstall, also remove agent.yml and .env.
  --nuke               With --uninstall, also remove the agent workspace
                       directory itself (and its parent if left empty).
                       Implies --purge.
  --yes                With --uninstall, skip the confirmation prompt.
  --delete-fork        With --uninstall, also delete the GitHub fork created
                       by the wizard. Requires --yes (the deletion is
                       irreversible and affects other hosts cloned from it).
                       Needs a PAT with delete_repo scope in .env.
  --destination PATH   (wizard only) Use PATH instead of prompting for the destination.
  --in-place           (wizard only) Skip scaffold — generate files in the current
                       directory (legacy behavior).
  --help               Show this message.

Files:
  agent.yml            Source of truth (user-owned, gitignored by default).
  .env                 Secrets (user-owned, gitignored).
  CLAUDE.md            Generated once; user-owned after.
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --regenerate) MODE="regenerate"; shift ;;
      --reset) MODE="reset"; shift ;;
      --non-interactive) MODE="non-interactive"; shift ;;
      --force-claude-md) FORCE_CLAUDE_MD=true; shift ;;
      --uninstall) MODE="uninstall"; shift ;;
      --sync-template) MODE="sync-template"; shift ;;
      --purge) UNINSTALL_PURGE=true; shift ;;
      --delete-fork) UNINSTALL_DELETE_FORK=true; shift ;;
      --nuke) UNINSTALL_NUKE=true; UNINSTALL_PURGE=true; shift ;;
      --yes|-y) UNINSTALL_YES=true; shift ;;
      --destination) DESTINATION="$2"; shift 2 ;;
      --in-place) IN_PLACE=true; shift ;;
      --help|-h) print_usage; exit 0 ;;
      *) echo "Unknown option: $1" >&2; print_usage; exit 1 ;;
    esac
  done
}

run_wizard() {
  local agent_yml="$SCRIPT_DIR/agent.yml"
  local env_file="$SCRIPT_DIR/.env"

  echo ""
  echo "═══════════════════════════════════════════════════"
  echo " agentic-pod-launcher — Interactive Setup"
  echo "═══════════════════════════════════════════════════"
  echo ""
  echo " Tips:"
  echo "   · defaults are pre-filled — Enter to accept"
  echo "   · Ctrl+U clears the field to type your own"
  echo "   · Ctrl+C aborts the wizard"
  echo ""

  # ── 1. Identity ─────────────────────────────────────
  echo "▸ Agent identity"
  local agent_name agent_display agent_role agent_vibe
  agent_name=$(ask "Agent name (lowercase, no spaces)" "my-agent")
  # Force lowercase + strip spaces — used for filenames, branches, service
  # names. If the user typed otherwise, normalize silently and show it back.
  local agent_name_raw="$agent_name"
  agent_name=$(echo "$agent_name" | tr '[:upper:]' '[:lower:]' | tr -d ' ')
  if [ "$agent_name" != "$agent_name_raw" ]; then
    echo "  ↳ normalized to: $agent_name"
  fi
  agent_display=$(ask "Display name (with emoji)" "MyAgent 🤖")
  agent_role=$(ask "Role description" "Admin assistant for my ecosystem")
  agent_vibe=$(ask "Vibe / personality (one line)" "Direct, useful, no drama")
  echo ""

  # ── 2. User ─────────────────────────────────────────
  echo "▸ About you"
  local user_name user_nick first_name tz_default user_tz user_email user_lang
  user_name=$(ask_required "Your full name")
  first_name="${user_name%% *}"
  user_nick=$(ask "Nickname (how the agent should address you)" "$first_name")
  tz_default="UTC"
  if command -v timedatectl &>/dev/null; then
    tz_default=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "UTC")
  elif [ -L /etc/localtime ]; then
    tz_default=$(readlink /etc/localtime | sed 's|.*zoneinfo/||')
  fi
  user_tz=$(ask "Timezone" "$tz_default")
  user_email=$(ask_required "Primary email")
  user_lang=$(ask_choice "Preferred language" "en" "es en mixed")
  echo ""

  # ── 3. Deployment ───────────────────────────────────
  echo "▸ Deployment"
  local deploy_host deploy_ws deploy_svc
  deploy_host=$(hostname)
  echo "  Host machine: $deploy_host (used only for fork branch naming;"
  echo "  the agent itself runs inside the container)"
  if [ -n "$DESTINATION" ]; then
    deploy_ws="$DESTINATION"
    echo "  Agent destination directory: $deploy_ws (from --destination flag)"
  else
    # Default: <parent-of-installer>/agents/<agent_name> — groups agents
    # under a single sibling "agents/" folder next to the installer clone.
    local installer_parent default_dest
    installer_parent=$(dirname "$SCRIPT_DIR")
    default_dest="${installer_parent}/agents/${agent_name}"
    deploy_ws=$(ask "Agent destination directory" "$default_dest")
  fi
  if [ "$(uname -s)" != "Linux" ]; then
    deploy_svc=false
    echo "  Host systemd unit: skipped on $(uname -s) (only applicable on Linux;"
    echo "  Docker Desktop handles container restart on login via 'unless-stopped')."
  else
    deploy_svc=$(ask_yn "Install as system service?" "y")
  fi
  echo ""

  # ── 3.1 Claude profile ──────────────────────────────
  echo "▸ Claude profile"
  local claude_config_dir="/home/agent/.claude"
  local claude_profile_new="true"
  echo "  Profile lives at /home/agent/.claude inside the container"
  echo "  (isolated on the named state volume — run /login inside tmux once"
  echo "  after first boot)."
  echo ""

  # ── 3.5 GitHub fork (template sync) ─────────────────
  echo "▸ GitHub fork (template sync)"
  echo "  Creating a fork lets you:"
  echo "    - push this agent to its own GitHub repo"
  echo "    - pull template improvements later via ./setup.sh --sync-template"
  echo ""
  local fork_enabled fork_owner="" fork_name="" fork_private="true" fork_token=""
  local template_url="https://github.com/rodrigo-hinojosa-labs/agentic-pod-launcher"
  fork_enabled=$(ask_yn "Create a GitHub fork for this agent?" "y")
  if [ "$fork_enabled" = "true" ]; then
    if ! command -v gh &>/dev/null; then
      echo "  ✗ gh CLI not found — install it first: https://cli.github.com/"
      exit 1
    fi
    local host_lc agent_lc default_fork
    host_lc=$(echo "$deploy_host" | tr '[:upper:]' '[:lower:]')
    agent_lc=$(echo "$agent_name" | tr '[:upper:]' '[:lower:]')
    # Repo es único por agente (compartido entre máquinas); el hostname vive
    # en el nombre de la branch (ver scaffold_with_fork). Strip "-agent" si ya
    # lo trae para evitar "foo-agent-agent".
    default_fork="${agent_lc%-agent}-agent"
    fork_owner=$(ask "Fork owner (user or org)" "your-github-user-or-org")
    fork_name=$(ask "Fork repo name" "$default_fork")
    fork_private=$(ask_yn "Make the fork private? (recommended)" "y")
    template_url=$(ask "Template repo URL" "$template_url")
    echo "  PAT needs 'repo' scope (and 'delete_repo' if you'll use --delete-fork)."
    fork_token=$(ask_secret "GitHub Personal Access Token for fork")
  fi
  echo ""

  # ── 4. Heartbeat notifications ──────────────────────
  echo "▸ Heartbeat notifications"
  echo "  When the heartbeat runs, where should it report status?"
  echo "    none     — silent (default)"
  echo "    log      — append to scripts/heartbeat/logs/notifications.log"
  echo "    telegram — standalone notifier bot (one-way status pings)"
  echo ""
  echo "  NOTE: This is ONLY for heartbeat pings. For two-way Telegram chat"
  echo "        with your agent, install the plugin separately after setup:"
  echo "          claude plugin install telegram@claude-plugins-official"
  echo ""
  local notify_channel notify_bot_token="" notify_chat_id=""
  notify_channel=$(ask_choice "Heartbeat notification channel" "none" "none log telegram")
  if [ "$notify_channel" = "telegram" ]; then
    echo "  Heartbeat will use a dedicated bot (separate from the chat plugin)."
    echo "  Create it at @BotFather and copy its token."
    echo "  (Press Enter to skip — fill NOTIFY_BOT_TOKEN in .env later.)"
    notify_bot_token=$(ask_secret "Heartbeat bot token (or skip)")

    # If we got a token, offer to auto-discover the chat id via the Telegram
    # Bot API's getUpdates endpoint. The user just needs to DM the bot once.
    if [ -n "$notify_bot_token" ]; then
      echo ""
      echo "  To send pings the notifier needs your chat id. You can either"
      echo "  paste it now (get it from @userinfobot or a prior DM), or let"
      echo "  the wizard auto-discover it by having you message the bot once."
      echo ""
      if [ "$(ask_yn 'Auto-discover chat id by messaging the bot now?' 'y')" = "true" ]; then
        echo ""
        echo "  → Open Telegram, send ANY message to your notifier bot,"
        echo "    then come back here and press Enter."
        read -r _ 2>/dev/null || true
        notify_chat_id=$(curl -s --max-time 10 \
          "https://api.telegram.org/bot${notify_bot_token}/getUpdates" 2>/dev/null \
          | jq -r '.result | map(select(.message.chat.type=="private")) | last | .message.chat.id // empty' 2>/dev/null || true)
        if [ -n "$notify_chat_id" ]; then
          echo "  ✓ Detected chat id: $notify_chat_id"
        else
          echo "  ⚠  Could not detect a chat id (no recent DM to the bot, or"
          echo "     getUpdates returned empty — maybe another process already"
          echo "     consumed the updates). You can paste it manually:"
          notify_chat_id=$(ask "Chat ID (or skip to fill in .env later)" "")
        fi
      else
        notify_chat_id=$(ask "Chat ID (or skip to fill in .env later)" "")
      fi
    fi

    if [ -z "$notify_bot_token" ] || [ -z "$notify_chat_id" ]; then
      echo ""
      echo "  ⚠  Telegram credentials incomplete — heartbeat pings are disabled"
      echo "     until you fill the missing value(s) in .env:"
      [ -z "$notify_bot_token" ] && echo "       NOTIFY_BOT_TOKEN=..."
      [ -z "$notify_chat_id" ]   && echo "       NOTIFY_CHAT_ID=..."
    fi
  fi
  echo ""

  # ── 5. MCPs ─────────────────────────────────────────
  echo "▸ MCP servers"
  echo "  Pre-configured (zero config): playwright, fetch, time, sequential-thinking"
  echo ""
  local atlassian_entries=""
  local atlassian_env_vars=""
  if [ "$(ask_yn 'Enable Atlassian MCP?' 'n')" = "true" ]; then
    while true; do
      local ws_name ws_url ws_email ws_token
      ws_name=$(ask_required "Workspace alias (e.g. personal, work) — unique identifier for this Atlassian account")
      ws_url=$(ask_required "Atlassian URL (e.g. https://yourco.atlassian.net)")
      ws_email=$(ask "Email" "$user_email")
      echo "  API token for this workspace — generate one at"
      echo "  https://id.atlassian.com/manage-profile/security/api-tokens"
      local _upper_hint
      _upper_hint=$(echo "$ws_name" | tr '[:lower:]' '[:upper:]')
      echo "  (Press Enter to skip — fill ATLASSIAN_${_upper_hint}_TOKEN in .env later.)"
      ws_token=$(ask_secret "API token (or skip)")
      atlassian_entries="${atlassian_entries}  - name: ${ws_name}
    url: \"${ws_url}\"
    email: \"${ws_email}\"
"
      local upper
      upper=$(echo "$ws_name" | tr '[:lower:]' '[:upper:]')
      # Emit one block per workspace: 4 non-secret env vars (URLs + usernames
      # for Confluence and Jira) plus the shared API token. mcp-atlassian
      # reads the non-prefixed CONFLUENCE_*/JIRA_* vars; `.mcp.json` maps
      # each MCP instance to its namespaced ATLASSIAN_<NAME>_* equivalent.
      atlassian_env_vars="${atlassian_env_vars}ATLASSIAN_${upper}_CONFLUENCE_URL=${ws_url}/wiki
ATLASSIAN_${upper}_CONFLUENCE_USERNAME=${ws_email}
ATLASSIAN_${upper}_JIRA_URL=${ws_url}
ATLASSIAN_${upper}_JIRA_USERNAME=${ws_email}
ATLASSIAN_${upper}_TOKEN=${ws_token}
"
      if [ "$(ask_yn 'Add another Atlassian workspace?' 'n')" = "false" ]; then
        break
      fi
    done
  fi

  local github_enabled="false" github_email="" github_pat=""
  if [ "$(ask_yn 'Enable GitHub MCP?' 'n')" = "true" ]; then
    github_enabled="true"
    github_email=$(ask "GitHub account email" "$user_email")
    echo "  This is the PAT the GitHub MCP server uses to call the API — it is"
    echo "  independent from any fork token you may have given earlier."
    echo "  (Press Enter to skip — fill GITHUB_PAT in .env later.)"
    github_pat=$(ask_secret "GitHub Personal Access Token for MCP (or skip)")
  fi
  echo ""

  # ── 6. Features ─────────────────────────────────────
  echo "▸ Features"
  local hb_enabled hb_interval hb_prompt
  hb_enabled=$(ask_yn "Enable heartbeat (periodic auto-execution)?" "y")
  hb_interval="30m"
  hb_prompt="Status check — return a short plain-text report (uptime, notable issues). No tool use; your stdout is forwarded verbatim to the notifier."
  if [ "$hb_enabled" = "true" ]; then
    hb_interval=$(ask "Default interval" "30m")
    hb_prompt=$(ask "Default prompt" "Status check — return a short plain-text report (uptime, notable issues). No tool use; your stdout is forwarded verbatim to the notifier.")
  fi
  echo ""

  # ── 7. Principles ───────────────────────────────────
  echo "▸ Agent principles"
  local use_defaults
  use_defaults=$(ask_yn "Use default opinionated agent principles? (recommended)" "y")
  echo ""

  # ── 7.5 Knowledge vault (Karpathy LLM Wiki) ────────
  echo "▸ Knowledge vault"
  echo "  Per-agent Obsidian-style vault at .state/.vault/. Three-layer Karpathy"
  echo "  pattern (raw_sources / wiki / schema). Coexists with claude-mem."
  echo ""
  local vault_enabled vault_seed vault_mcp_enabled
  vault_enabled=$(ask_yn "Enable knowledge vault?" "y")
  vault_seed=false
  vault_mcp_enabled=false
  if [ "$vault_enabled" = "true" ]; then
    vault_seed=$(ask_yn "  Seed initial vault structure (templates, schema, log)?" "y")
    vault_mcp_enabled=$(ask_yn "  Register MCPVault server (@bitbonsai/mcpvault)?" "y")
  fi
  echo ""

  # ── 8. Optional plugins ─────────────────────────────
  # Iterate the optional descriptors and let the user opt in. Defaults
  # (telegram, claude-mem, context7, claude-md-management, security-guidance)
  # are always installed and not asked about here.
  echo "▸ Optional plugins"
  echo "  Pre-configurados always-on (5): telegram, claude-mem, context7,"
  echo "  claude-md-management, security-guidance. NEXT_STEPS.md detalla impacto."
  echo ""
  echo "  Los siguientes son opcionales — Enter para 'no':"
  echo ""
  local opt_plugins=()
  # Pre-collect IDs into an array. We CANNOT iterate via
  # `while ... done < <(plugin_catalog_list optional)` because that
  # redirects the loop's stdin to the IDs stream — and ask_yn inside
  # the loop body would then read its y/n answers from the IDs list
  # instead of the user's stdin. Reading IDs first into a plain array
  # leaves stdin pointing at the user.
  local _opt_ids=()
  local _opt_id _opt_desc _opt_useful _opt_overhead _opt_confirm _opt_spec _opt_conflicts
  while IFS= read -r _opt_id; do
    [ -z "$_opt_id" ] && continue
    _opt_ids+=("$_opt_id")
  done < <(plugin_catalog_list optional)
  if [ "${#_opt_ids[@]}" -gt 0 ]; then
    for _opt_id in "${_opt_ids[@]}"; do
      _opt_desc=$(plugin_catalog_get "$_opt_id" description)
      _opt_useful=$(plugin_catalog_get "$_opt_id" when_useful)
      _opt_overhead=$(plugin_catalog_get "$_opt_id" when_overhead)
      echo "  · ${_opt_id}"
      echo "    ${_opt_desc}"
      echo "    Útil: ${_opt_useful}"
      echo "    Overhead: ${_opt_overhead}"
      if [ "$(ask_yn "    Install ${_opt_id}?" "n")" = "true" ]; then
        _opt_confirm=$(plugin_catalog_get "$_opt_id" requires_explicit_confirm)
        _opt_spec=$(plugin_catalog_get "$_opt_id" spec)
        if [ "$_opt_confirm" = "true" ]; then
          _opt_conflicts=$(yq -r '.conflicts[]?' "$SCRIPT_DIR/modules/plugins/${_opt_id}.yml" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
          echo "    ⚠  ${_opt_id} entra en conflicto con: ${_opt_conflicts:-(none)}"
          if [ "$(ask_yn "    Confirm installing ${_opt_id} (overrides those fields)?" "n")" = "true" ]; then
            opt_plugins+=("$_opt_spec")
          else
            echo "    skipped: ${_opt_id}"
          fi
        else
          opt_plugins+=("$_opt_spec")
        fi
      fi
      echo ""
    done
  fi

  # ── Review loop ──────────────────────────────────────
  while true; do
    echo ""
    echo "═══════════════════════════════════════════════════"
    echo " Summary"
    echo "═══════════════════════════════════════════════════"
    echo "  1) Agent name:        $agent_name"
    echo "  2) Display name:      $agent_display"
    echo "  3) Role:              $agent_role"
    echo "  4) Vibe:              $agent_vibe"
    echo "  5) User name:         $user_name"
    echo "  6) Nickname:          $user_nick"
    echo "  7) Timezone:          $user_tz"
    echo "  8) Email:             $user_email"
    echo "  9) Language:          $user_lang"
    echo " 10) Host:              $deploy_host"
    echo " 11) Destination:       $deploy_ws"
    echo " 12) Install service:   $deploy_svc"
    echo "     Claude profile:   $claude_config_dir$([ "$claude_profile_new" = true ] && echo " (new — /login required)")"
    echo " 13) Heartbeat notif:   $notify_channel"
    echo " 14) Heartbeat enabled: $hb_enabled"
    [ "$hb_enabled" = "true" ] && echo " 15) Heartbeat interval: $hb_interval"
    [ "$hb_enabled" = "true" ] && echo " 16) Heartbeat prompt:   $hb_prompt"
    echo " 17) Default princ:     $use_defaults"
    echo "     Vault enabled:    $vault_enabled"
    [ "$vault_enabled" = "true" ] && echo "     Vault seed:       $vault_seed"
    [ "$vault_enabled" = "true" ] && echo "     Vault MCP:        $vault_mcp_enabled"
    echo " 18) GitHub fork:       $fork_enabled"
    if [ "$fork_enabled" = "true" ]; then
      echo " 19) Fork owner:        $fork_owner"
      echo " 20) Fork name:         $fork_name"
      echo " 21) Fork private:      $fork_private"
      echo " 22) Template URL:      $template_url"
      echo " 23) Fork PAT:          $([ -n "$fork_token" ] && echo "********" || echo "(unset)")"
    fi
    echo ""
    echo "  Atlassian:       $([ -n "$atlassian_entries" ] && echo "configured" || echo "disabled")"
    echo "  GitHub MCP:      $github_enabled"
    echo ""

    local action
    action=$(ask_choice "Action" "proceed" "proceed edit abort")
    case "$action" in
      proceed) break ;;
      abort)
        echo "Aborted."
        exit 0
        ;;
      edit)
        local field
        field=$(ask "Edit which field number?" "1")
        case "$field" in
          1) agent_name=$(ask "Agent name (lowercase, no spaces)" "$agent_name") ;;
          2) agent_display=$(ask "Display name (with emoji)" "$agent_display") ;;
          3) agent_role=$(ask "Role description" "$agent_role") ;;
          4) agent_vibe=$(ask "Vibe / personality (one line)" "$agent_vibe") ;;
          5) user_name=$(ask "Your full name" "$user_name") ;;
          6) user_nick=$(ask "Nickname" "$user_nick") ;;
          7) user_tz=$(ask "Timezone" "$user_tz") ;;
          8) user_email=$(ask "Primary email" "$user_email") ;;
          9) user_lang=$(ask_choice "Preferred language" "$user_lang" "es en mixed") ;;
          10) deploy_host=$(ask "Host machine name" "$deploy_host") ;;
          11) deploy_ws=$(ask "Agent destination directory" "$deploy_ws") ;;
          12) deploy_svc=$(ask_yn "Install as system service?" "$([ "$deploy_svc" = true ] && echo y || echo n)") ;;
          13) notify_channel=$(ask_choice "Heartbeat notification channel" "$notify_channel" "none log telegram") ;;
          14) hb_enabled=$(ask_yn "Enable heartbeat?" "$([ "$hb_enabled" = true ] && echo y || echo n)") ;;
          15) hb_interval=$(ask "Heartbeat interval" "$hb_interval") ;;
          16) hb_prompt=$(ask "Heartbeat default prompt" "$hb_prompt") ;;
          17) use_defaults=$(ask_yn "Use default principles?" "$([ "$use_defaults" = true ] && echo y || echo n)") ;;
          18) fork_enabled=$(ask_yn "Create a GitHub fork?" "$([ "$fork_enabled" = true ] && echo y || echo n)") ;;
          19) fork_owner=$(ask "GitHub username (owner of the fork)" "$fork_owner") ;;
          20) fork_name=$(ask "Fork repo name" "$fork_name") ;;
          21) fork_private=$(ask_yn "Make the fork private?" "$([ "$fork_private" = true ] && echo y || echo n)") ;;
          22) template_url=$(ask "Template repo URL" "$template_url") ;;
          23) fork_token=$(ask_secret "GitHub Personal Access Token for fork") ;;
          *) echo "  Invalid field: $field" ;;
        esac
        ;;
    esac
  done

  # ── Build YAML fragments before the heredoc ─────────
  local atlassian_yaml plugins_yaml
  local docker_yaml="  image_tag: \"agentic-pod:latest\"
  uid: $(id -u)
  gid: $(id -g)
  base_image: \"alpine:3.20\""
  if [ -n "$atlassian_entries" ]; then
    atlassian_yaml="  atlassian:
$atlassian_entries"
  else
    atlassian_yaml="  atlassian: []"
  fi

  # Render the plugins list: 5 always-on defaults from the catalog + any
  # opt-in descriptors the user selected in the "Optional plugins" wizard
  # section above. Adding a new default is a one-file change (drop a YAML
  # descriptor); adding a new opt-in is the same plus the user gets to pick.
  plugins_yaml="plugins:"
  local _id _spec
  while IFS= read -r _id; do
    [ -z "$_id" ] && continue
    _spec=$(plugin_catalog_get "$_id" spec)
    [ -n "$_spec" ] && plugins_yaml="${plugins_yaml}
  - ${_spec}"
  done < <(plugin_catalog_list default)
  if [ "${#opt_plugins[@]}" -gt 0 ]; then
    local _o
    for _o in "${opt_plugins[@]}"; do
      plugins_yaml="${plugins_yaml}
  - ${_o}"
    done
  fi

  # ── Write agent.yml ─────────────────────────────────
  cat > "$agent_yml" << EOF
# Generated by setup.sh on $(date '+%Y-%m-%d %H:%M:%S')
# Edit this file and run ./setup.sh --regenerate to update derived files.
version: 1

agent:
  name: $agent_name
  display_name: "$agent_display"
  role: "$agent_role"
  vibe: "$agent_vibe"
  use_default_principles: $use_defaults

user:
  name: "$user_name"
  nickname: "$user_nick"
  timezone: "$user_tz"
  email: "$user_email"
  language: "$user_lang"

deployment:
  host: "$deploy_host"
  workspace: "$deploy_ws"
  install_service: $deploy_svc
  claude_cli: "$(detect_claude_cli)"

claude:
  config_dir: "$claude_config_dir"
  profile_new: $claude_profile_new

docker:
$docker_yaml

scaffold:
  template_url: "$template_url"
  fork:
    enabled: $fork_enabled
    owner: "$fork_owner"
    name: "$fork_name"
    private: $fork_private
    url: ""

notifications:
  channel: $notify_channel

features:
  heartbeat:
    enabled: $hb_enabled
    interval: "$hb_interval"
    timeout: 300
    retries: 1
    default_prompt: "$hb_prompt"

mcps:
  defaults:
    - playwright
    - fetch
    - time
    - sequential-thinking
$atlassian_yaml
  github:
    enabled: $github_enabled
    email: "$github_email"

vault:
  enabled: $vault_enabled
  path: .state/.vault
  seed_skeleton: $vault_seed
  initial_sources: []
  mcp:
    enabled: $vault_mcp_enabled
    server: vault
  schema:
    frontmatter_required: true
    log_format: "## [{date}] {op} | {title}"

$plugins_yaml
EOF

  cat > "$env_file" << EOF
# Generated by setup.sh on $(date '+%Y-%m-%d %H:%M:%S')
# NEVER commit this file.

EOF
  if [ "$notify_channel" = "telegram" ]; then
    cat >> "$env_file" << EOF
NOTIFY_BOT_TOKEN=$notify_bot_token
NOTIFY_CHAT_ID=$notify_chat_id

EOF
  fi
  [ -n "$atlassian_env_vars" ] && echo "$atlassian_env_vars" >> "$env_file"
  [ "$github_enabled" = "true" ] && echo "GITHUB_PAT=$github_pat" >> "$env_file"
  [ "$fork_enabled" = "true" ] && [ -n "$fork_token" ] && echo "GITHUB_FORK_PAT=$fork_token" >> "$env_file"
  chmod 0600 "$env_file"

  echo ""
  echo "✓ agent.yml and .env written"
  echo ""

  local src_dir="$SCRIPT_DIR"
  scaffold_destination
  regenerate

  local final_branch=""
  if [ "$IN_PLACE" != true ] && [ -d "$SCRIPT_DIR/.git" ]; then
    (
      cd "$SCRIPT_DIR"
      git add -A
      git -c user.email="setup@agentic-pod-launcher.local" -c user.name="agentic-pod-launcher" \
        commit -q -m "chore: initial agent scaffold from agentic-pod-launcher"
    )
    final_branch=$(cd "$SCRIPT_DIR" && git symbolic-ref --short HEAD 2>/dev/null || echo "unknown")
    echo "  ✓ initial commit on $final_branch"
  fi

  if [ "$IN_PLACE" != true ]; then
    render_next_steps "$SCRIPT_DIR"
    echo ""
    echo "The installer clone ($src_dir) is no longer needed and can be deleted."
  fi
}

# Pull template improvements into the fork: fetch upstream/main,
# fast-forward local main, push to origin, rebase the live branch on top.
# Must be run from a scaffolded agent directory (agent.yml present).
sync_template() {
  local dest="$SCRIPT_DIR"
  [ ! -f "$dest/agent.yml" ] && { echo "ERROR: agent.yml not found; run wizard first" >&2; exit 1; }
  [ ! -d "$dest/.git" ]      && { echo "ERROR: not a git repo: $dest" >&2; exit 1; }

  local fork_enabled
  fork_enabled=$(yq '.scaffold.fork.enabled // false' "$dest/agent.yml")
  if [ "$fork_enabled" != "true" ]; then
    echo "ERROR: --sync-template requires a fork-based agent (scaffold.fork.enabled=true)" >&2
    echo "       This agent was scaffolded in legacy mode without a template upstream." >&2
    exit 1
  fi

  cd "$dest"

  # Ensure a local git identity so the rebase can write commits even when
  # the host has no global git config.
  if [ -z "$(git config user.email)" ]; then
    git config user.email "$(yq '.user.email' "$dest/agent.yml")"
  fi
  if [ -z "$(git config user.name)" ]; then
    git config user.name "$(yq '.user.name' "$dest/agent.yml")"
  fi

  # Abort if the working tree is dirty — rebasing would corrupt unsaved work.
  if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "ERROR: working tree has uncommitted changes. Commit or stash first." >&2
    exit 1
  fi

  local live_branch
  live_branch=$(git symbolic-ref --short HEAD)
  if ! [[ "$live_branch" =~ /live$ ]]; then
    echo "ERROR: expected to be on a live branch (matching */live), got: $live_branch" >&2
    exit 1
  fi

  echo "▸ Fetching upstream..."
  git fetch upstream -q

  echo "▸ Fast-forwarding local main to upstream/main..."
  git checkout main -q
  if ! git merge --ff-only upstream/main -q; then
    echo "ERROR: local main diverged from upstream/main." >&2
    echo "       Resolve manually: git log main..upstream/main" >&2
    git checkout "$live_branch" -q
    exit 1
  fi

  echo "▸ Pushing updated main to origin..."
  git push origin main -q

  echo "▸ Rebasing $live_branch on updated main..."
  git checkout "$live_branch" -q
  if ! git rebase main; then
    echo "" >&2
    echo "⚠ Rebase hit a conflict. Resolve with:" >&2
    echo "    git status           # see conflicting files" >&2
    echo "    # edit files, then:" >&2
    echo "    git add <files>" >&2
    echo "    git rebase --continue" >&2
    exit 1
  fi

  echo ""
  echo "✓ $live_branch is now rebased on the latest template."
  echo "  Inspect the diff: git log --oneline main..$live_branch"
  echo "  Push when ready:  git push --force-with-lease origin $live_branch"
}

# Build the markdown block listing every installed plugin with description
# + impact, localized to es | en. Used by render_next_steps to inject
# {{PLUGINS_BLOCK}} into the NEXT_STEPS.md template. Reads agent.yml's
# plugins[] and looks up each spec in the catalog.
build_plugins_block() {
  local agent_yml="$1"
  local lang="${2:-en}"
  local heading intro footer
  case "$lang" in
    es|mixed)
      heading="## Plugins instalados"
      intro="Los siguientes plugins se instalan automáticamente cuando completes \`/login\` dentro del tmux. Cada uno aporta capacidades distintas — el campo \`agent.yml.plugins[]\` es la fuente de verdad y podés editarlo a mano si querés agregar/quitar (luego \`./setup.sh --regenerate\`)."
      footer="Para desinstalar uno desde una sesión: \`claude plugin uninstall <spec>\`."
      ;;
    *)
      heading="## Installed plugins"
      intro="The following plugins auto-install on the agent's first \`/login\` inside tmux. Each adds distinct capabilities — \`agent.yml.plugins[]\` is the source of truth and you can edit it by hand to add/remove (then \`./setup.sh --regenerate\`)."
      footer="To uninstall one from a session: \`claude plugin uninstall <spec>\`."
      ;;
  esac
  local block="${heading}"$'\n\n'"${intro}"$'\n\n'
  local spec id desc impact
  while IFS= read -r spec; do
    [ -z "$spec" ] && continue
    id=$(_plugin_catalog_id_for_spec "$spec" 2>/dev/null) || continue
    desc=$(plugin_catalog_get "$id" description)
    impact=$(plugin_catalog_get "$id" impact)
    block+="- **${id}** — \`${spec}\`"$'\n'
    block+="    - ${desc}"$'\n'
    block+="    - Impact: ${impact}"$'\n\n'
  done < <(plugin_catalog_specs "$agent_yml")
  block+="${footer}"$'\n'
  printf '%s' "$block"
}

# Render NEXT_STEPS.md from the i18n template matching user.language and
# print it to stdout. Templates live at modules/next-steps.{es,en}.tpl.
render_next_steps() {
  local dest="$1"
  local lang template
  lang=$(yq '.user.language // "en"' "$dest/agent.yml")
  case "$lang" in
    es|mixed) template="$dest/modules/next-steps.es.tpl" ;;
    *)        template="$dest/modules/next-steps.en.tpl" ;;
  esac
  [ ! -f "$template" ] && return 0

  # Helper boolean derived from notifications.channel for {{#unless}}
  local notif_channel
  notif_channel=$(yq '.notifications.channel // "none"' "$dest/agent.yml")
  if [ "$notif_channel" = "telegram" ]; then
    export NOTIF_IS_TELEGRAM="true"
  else
    export NOTIF_IS_TELEGRAM="false"
  fi

  render_load_context "$dest/agent.yml"
  # Expand $HOME / ~ in the stored profile path for display
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    export CLAUDE_CONFIG_DIR=$(eval echo "$CLAUDE_CONFIG_DIR")
  fi
  export CLAUDE_PROFILE_NEW="${CLAUDE_PROFILE_NEW:-false}"
  # Pre-render the plugins block from the catalog (descriptors give us
  # localized description + impact per plugin). The template engine's
  # {{#each}} works on flat scalar arrays; descriptors are nested objects,
  # so we build the markdown here in bash and inject as a {{PLUGINS_BLOCK}}
  # placeholder. Keeps the template engine simple.
  export PLUGINS_BLOCK
  PLUGINS_BLOCK=$(build_plugins_block "$dest/agent.yml" "$lang")
  render_to_file "$template" "$dest/NEXT_STEPS.md"

  echo ""
  echo "═══════════════════════════════════════════════════"
  echo " Next steps (also saved to $dest/NEXT_STEPS.md)"
  echo "═══════════════════════════════════════════════════"
  cat "$dest/NEXT_STEPS.md"
}

# Fork the template on GitHub, init the destination git repo pointing at it,
# and create a versioned live branch named {host}-{agent}-v{N}/live.
# Requires gh CLI, a PAT in .env (GITHUB_FORK_PAT), and owner/name in agent.yml.
scaffold_with_fork() {
  local dest="$1" agent_lc="$2" host_lc="$3"
  local fork_owner fork_name fork_private template_url token priv_flag
  fork_owner=$(yq '.scaffold.fork.owner' "$dest/agent.yml")
  fork_name=$(yq '.scaffold.fork.name' "$dest/agent.yml")
  fork_private=$(yq '.scaffold.fork.private // true' "$dest/agent.yml")
  template_url=$(yq '.scaffold.template_url' "$dest/agent.yml")
  token=""
  [ -f "$dest/.env" ] && token=$(grep -E '^GITHUB_FORK_PAT=' "$dest/.env" | cut -d= -f2- || true)

  # Detect if fork_owner is an org (different from the authenticated user).
  # GitHub forbids same-user parent+fork, so we must forward --org when the
  # fork target is different from the PAT's user.
  local gh_user org_flag=""
  gh_user=$(GH_TOKEN="$token" gh api user --jq .login 2>/dev/null || echo "")
  if [ -n "$gh_user" ] && [ "$gh_user" != "$fork_owner" ]; then
    org_flag="--org $fork_owner"
  fi

  echo "  ▸ Creating fork ${fork_owner}/${fork_name} from ${template_url}..."
  local fork_stderr
  fork_stderr=$(GH_TOKEN="$token" gh repo fork "$template_url" \
    --fork-name "$fork_name" --default-branch-only --clone=false $org_flag 2>&1 >/dev/null) || {
    if echo "$fork_stderr" | grep -qiE "already exists|name already"; then
      echo "  ✓ fork already exists — reusing"
    else
      echo "  ✗ fork creation failed:" >&2
      echo "$fork_stderr" | sed 's/^/    /' >&2
      exit 1
    fi
  }
  [ -n "${fork_stderr:-}" ] || echo "  ✓ fork created"

  # gh repo fork can't set visibility at creation time — forks inherit the
  # upstream's visibility. If the user asked for private, flip it now.
  if [ "$fork_private" = "true" ]; then
    if GH_TOKEN="$token" gh repo edit "${fork_owner}/${fork_name}" --visibility private --accept-visibility-change-consequences >/dev/null 2>&1; then
      echo "  ✓ fork set to private"
    else
      echo "  ⚠ could not set fork to private automatically — do it manually at"
      echo "     https://github.com/${fork_owner}/${fork_name}/settings"
    fi
  fi

  # Query existing branches to compute next version. Retry because newly
  # created forks may not be immediately queryable.
  local existing_version="" attempt
  for attempt in 1 2 3; do
    existing_version=$(GH_TOKEN="$token" gh api \
      "repos/${fork_owner}/${fork_name}/branches?per_page=100" --jq '.[].name' 2>/dev/null \
      | grep -E "^${host_lc}-${agent_lc}-[0-9]+/live$" \
      | sed -E "s|.*-([0-9]+)/live$|\1|" \
      | sort -n | tail -1 || true)
    [ $? -eq 0 ] && break
    sleep 2
  done
  local version=$(( ${existing_version:-0} + 1 ))
  local branch="${host_lc}-${agent_lc}-${version}/live"
  local fork_url="https://github.com/${fork_owner}/${fork_name}"

  # Use HTTPS + PAT for origin so the scaffold works without relying on
  # any particular SSH key setup. The PAT is already in .env (gitignored).
  # Users who prefer SSH can switch with: git remote set-url origin git@...
  local origin_url="https://x-access-token:${token}@github.com/${fork_owner}/${fork_name}.git"
  (
    cd "$dest"
    git init -q
    git remote add origin "$origin_url"
    git remote add upstream "${template_url}.git"
    # Fetch main from the fork so the live branch has shared history with
    # upstream. Required for --sync-template to rebase cleanly.
    local fetch_err
    if fetch_err=$(git fetch origin main --depth=1 2>&1); then
      # Working tree already has the template files (we just copied them).
      # Point main at FETCH_HEAD and populate the index without rewriting
      # files — a plain checkout would abort on "untracked would overwrite".
      git update-ref refs/heads/main FETCH_HEAD
      git symbolic-ref HEAD refs/heads/main
      git reset --mixed -q HEAD
      git checkout -b "$branch" -q
      # Persist a local git identity so future commits/rebases don't depend
      # on a global --user.email being set on whatever host the agent lands on.
      git config user.email "$(yq '.user.email' "$dest/agent.yml")"
      git config user.name  "$(yq '.user.name'  "$dest/agent.yml")"
    else
      echo "  ⚠ could not fetch origin/main:" >&2
      echo "$fetch_err" | sed 's/^/      /' >&2
      echo "    falling back to orphan live branch — sync-template will need manual fixup"
      git checkout -b "$branch" -q
    fi
  )
  yq -i ".scaffold.fork.url = \"${fork_url}\"" "$dest/agent.yml"
  yq -i ".scaffold.fork.branch = \"${branch}\"" "$dest/agent.yml"

  echo "  ✓ fork ready: $fork_url"
  echo "  ✓ remotes: origin (fork) + upstream (template)"
  echo "  ✓ branch: $branch"
}

# Mirror plugin-catalog.sh, modules/plugins/, vault.sh and modules/vault-skeleton/
# into docker/ so the Dockerfile (build context ./docker/) can COPY them.
# Idempotent — overwrites the docker/ copy on each call.
mirror_catalog_to_docker() {
  local dest="$1"
  local src_lib="$dest/scripts/lib/plugin-catalog.sh"
  local src_plugins="$dest/modules/plugins"
  local src_vault_lib="$dest/scripts/lib/vault.sh"
  local src_vault_skel="$dest/modules/vault-skeleton"
  [ -f "$src_lib" ] || return 0
  [ -d "$src_plugins" ] || return 0
  mkdir -p "$dest/docker/scripts/lib" "$dest/docker/modules"
  cp "$src_lib" "$dest/docker/scripts/lib/plugin-catalog.sh"
  rm -rf "$dest/docker/modules/plugins"
  cp -R "$src_plugins" "$dest/docker/modules/plugins"
  if [ -f "$src_vault_lib" ]; then
    cp "$src_vault_lib" "$dest/docker/scripts/lib/vault.sh"
  fi
  if [ -d "$src_vault_skel" ]; then
    rm -rf "$dest/docker/modules/vault-skeleton"
    cp -R "$src_vault_skel" "$dest/docker/modules/vault-skeleton"
  fi
}

# Copy system files to the destination, move agent.yml/.env, chdir, git init.
# If IN_PLACE=true or destination == SCRIPT_DIR, skip (user chose in-place mode).
scaffold_destination() {
  local src_dir="$SCRIPT_DIR"
  local agent_yml="$SCRIPT_DIR/agent.yml"
  local env_file="$SCRIPT_DIR/.env"

  # Resolve destination from agent.yml
  local dest
  dest=$(yq '.deployment.workspace' "$agent_yml")
  # Expand $HOME / ~
  dest=$(eval echo "$dest")

  if [ "$IN_PLACE" = true ]; then
    echo "▸ --in-place mode: skipping destination scaffold"
    return 0
  fi

  if [ "$dest" = "$src_dir" ]; then
    echo "▸ Destination equals current directory: running in-place"
    return 0
  fi

  # Safety: never scaffold to $HOME itself
  if [ "$dest" = "$HOME" ]; then
    echo "ERROR: destination cannot be \$HOME itself ($HOME)" >&2
    echo "       Choose a subdirectory like \$HOME/Claude/Agents/{agent-name}" >&2
    exit 1
  fi

  # Safety: destination must not already exist
  if [ -e "$dest" ]; then
    echo "ERROR: destination already exists: $dest" >&2
    echo "       Choose a fresh path, or remove the existing one first." >&2
    exit 1
  fi

  echo ""
  echo "▸ Scaffolding destination: $dest"
  mkdir -p "$dest"

  # Copy system files (installer → destination)
  local item
  for item in setup.sh .gitignore LICENSE; do
    [ -e "$src_dir/$item" ] && cp "$src_dir/$item" "$dest/"
  done
  for item in modules scripts docker; do
    [ -d "$src_dir/$item" ] && cp -R "$src_dir/$item" "$dest/"
  done
  # Ensure setup.sh is executable
  chmod +x "$dest/setup.sh"
  find "$dest/scripts" -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true
  if [ -d "$dest/docker" ]; then
    find "$dest/docker" -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true
  fi

  # Mirror catalog files into docker/ build context. Source-of-truth lives
  # at scripts/lib/plugin-catalog.sh + modules/plugins/. The Dockerfile's
  # build context is ./docker/, so it cannot COPY from outside that tree
  # — we duplicate inside it. Refreshed on every regenerate.
  mirror_catalog_to_docker "$dest"

  # Pre-create .state/ — bind-mounted to /home/agent inside the container.
  # Host-owner (current user) matches the agent user's UID/GID via the
  # Dockerfile build args, so the bind-mount shows up agent-owned inside
  # without any runtime chown dance.
  mkdir -p "$dest/.state"

  # Move agent.yml + .env (transactional: copy, verify, delete source)
  cp "$agent_yml" "$dest/agent.yml" && [ -f "$dest/agent.yml" ] && rm "$agent_yml"
  if [ -f "$env_file" ]; then
    cp "$env_file" "$dest/.env" && [ -f "$dest/.env" ] && rm "$env_file"
  fi

  echo "  ✓ system files copied"
  echo "  ✓ agent.yml and .env moved"

  # Git init — fork-aware branch naming
  local fork_enabled agent_lc host_lc
  fork_enabled=$(yq '.scaffold.fork.enabled // false' "$dest/agent.yml")
  agent_lc=$(yq '.agent.name' "$dest/agent.yml" | tr '[:upper:]' '[:lower:]')
  host_lc=$(yq '.deployment.host' "$dest/agent.yml" | tr '[:upper:]' '[:lower:]')

  if [ "$fork_enabled" = "true" ]; then
    scaffold_with_fork "$dest" "$agent_lc" "$host_lc"
  else
    local branch="${agent_lc}/live"
    (
      cd "$dest"
      git init -b "$branch" -q 2>/dev/null || git init -q
      if [ "$(git symbolic-ref --short HEAD 2>/dev/null)" != "$branch" ]; then
        git checkout -b "$branch" -q 2>/dev/null || true
      fi
    )
    echo "  ✓ git init (branch: $branch)"
  fi

  # Redirect all subsequent operations to $dest
  SCRIPT_DIR="$dest"
  cd "$dest"
}

regenerate() {
  local agent_yml="$SCRIPT_DIR/agent.yml"
  local modules_dir="$SCRIPT_DIR/modules"
  local os
  os=$(uname -s | tr '[:upper:]' '[:lower:]')  # darwin | linux

  echo "▸ Loading context from agent.yml"
  render_load_context "$agent_yml"

  # Warn if agent.yml workspace differs from current directory (post-scaffold)
  local yml_workspace
  yml_workspace=$(eval echo "${DEPLOYMENT_WORKSPACE:-}")
  local current_dir
  current_dir=$(cd "$SCRIPT_DIR" && pwd)
  local yml_resolved
  yml_resolved=$(cd "$yml_workspace" 2>/dev/null && pwd || echo "$yml_workspace")

  if [ "$IN_PLACE" != true ] && [ -f "$SCRIPT_DIR/agent.yml" ] && [ -n "$yml_workspace" ] && [ "$yml_resolved" != "$current_dir" ]; then
    echo ""
    echo "WARNING: agent.yml's deployment.workspace ($yml_workspace) differs from the"
    echo "         current directory ($current_dir). The workspace field is fixed at"
    echo "         scaffold time; regenerate does NOT relocate files. If you want to"
    echo "         move the agent, uninstall here and re-run the installer."
    echo ""
  fi

  # Derived env vars not in YAML
  export HOME_DIR="$HOME"
  export OS="$os"
  if [ "${NOTIFICATIONS_CHANNEL:-none}" = "telegram" ]; then
    export NOTIFICATIONS_CHANNEL_IS_TELEGRAM=true
  else
    export NOTIFICATIONS_CHANNEL_IS_TELEGRAM=false
  fi
  # Claude profile: expand $HOME / ~ in the stored path. Backwards compat:
  # agents written before the claude.* section default to ~/.claude-personal.
  if [ -z "${CLAUDE_CONFIG_DIR:-}" ]; then
    export CLAUDE_CONFIG_DIR="$HOME/.claude-personal"
    export CLAUDE_PROFILE_NEW="false"
  else
    export CLAUDE_CONFIG_DIR=$(eval echo "$CLAUDE_CONFIG_DIR")
    export CLAUDE_PROFILE_NEW="${CLAUDE_PROFILE_NEW:-false}"
  fi
  export TELEGRAM_STATE_DIR="${CLAUDE_CONFIG_DIR}/channels/telegram-${AGENT_NAME}"

  local agent_name="$AGENT_NAME"
  local workspace
  workspace=$(eval echo "$DEPLOYMENT_WORKSPACE")

  echo "▸ Rendering modules"

  # CLAUDE.md — only if missing or --force-claude-md
  if [ ! -f "$SCRIPT_DIR/CLAUDE.md" ] || [ "$FORCE_CLAUDE_MD" = true ]; then
    if [ -f "$SCRIPT_DIR/CLAUDE.md" ] && [ "$FORCE_CLAUDE_MD" = true ]; then
      if [ "$(ask_yn 'Overwrite existing CLAUDE.md? THIS IS DESTRUCTIVE' 'n')" = "false" ]; then
        echo "  skipping CLAUDE.md (preserved)"
      else
        render_to_file "$modules_dir/claude-md.tpl" "$SCRIPT_DIR/CLAUDE.md"
        echo "  ✓ CLAUDE.md (overwritten)"
      fi
    else
      render_to_file "$modules_dir/claude-md.tpl" "$SCRIPT_DIR/CLAUDE.md"
      echo "  ✓ CLAUDE.md"
    fi
  else
    echo "  ◦ CLAUDE.md (preserved — use --force-claude-md to overwrite)"
  fi

  # .mcp.json
  render_to_file "$modules_dir/mcp-json.tpl" "$SCRIPT_DIR/.mcp.json"
  echo "  ✓ .mcp.json"

  # .env.example
  render_to_file "$modules_dir/env-example.tpl" "$SCRIPT_DIR/.env.example"
  echo "  ✓ .env.example"

  # Render docker-compose.yml
  render_to_file "$modules_dir/docker-compose.yml.tpl" "$SCRIPT_DIR/docker-compose.yml"
  echo "  ✓ docker-compose.yml"

  # Mirror plugin catalog into docker/ build context. Picks up descriptor
  # changes (modules/plugins/<id>.yml) on every regenerate so the next
  # `docker compose build` bakes the latest set into the image.
  mirror_catalog_to_docker "$SCRIPT_DIR"
  echo "  ✓ docker/scripts/lib/plugin-catalog.sh + docker/modules/plugins/"

  # heartbeat.conf
  if [ "${FEATURES_HEARTBEAT_ENABLED:-false}" = "true" ]; then
    render_to_file "$modules_dir/heartbeat-conf.tpl" "$SCRIPT_DIR/scripts/heartbeat/heartbeat.conf"
    echo "  ✓ scripts/heartbeat/heartbeat.conf"
  fi

  if [ "${DEPLOYMENT_INSTALL_SERVICE:-false}" = "true" ]; then
    install_service "$agent_name" "$workspace"
  fi

  echo ""
  echo "✓ Regeneration complete."
  maybe_print_plugin_hints
}

# Render a system-wide systemd unit that wraps `docker compose up -d`.
# This requires sudo to install; if the user did not grant it, we print the
# rendered file and instructions for a manual install.
install_service() {
  local agent_name="$1" workspace="$2"
  local modules_dir="$SCRIPT_DIR/modules"
  local unit_file="/etc/systemd/system/agent-${agent_name}.service"
  local staged
  staged=$(mktemp)
  trap 'rm -f "$staged"' RETURN
  render_to_file "$modules_dir/systemd.service.tpl" "$staged"

  if sudo -n true 2>/dev/null; then
    sudo cp "$staged" "$unit_file"
    sudo systemctl daemon-reload
    echo "  ✓ $unit_file"
    echo "  → enable with: sudo systemctl enable --now agent-${agent_name}.service"
  else
    cp "$staged" "$SCRIPT_DIR/agent-${agent_name}.service"
    echo "  ◦ agent-${agent_name}.service staged in workspace (sudo unavailable)"
    echo "    install manually: sudo cp ./agent-${agent_name}.service ${unit_file}"
    echo "                      sudo systemctl daemon-reload && sudo systemctl enable --now agent-${agent_name}.service"
  fi
}

# Validate that agent.yml has all the fields the rest of setup.sh +
# heartbeatctl + the docker-compose template expect to read. Fails
# fast with a punch-list rather than producing half-rendered files
# downstream. Used by --non-interactive and --regenerate so an
# accidentally-truncated agent.yml never silently produces a broken
# scaffold.
validate_agent_yml_required() {
  local yml="$1"
  local required=(
    ".agent.name"
    ".deployment.workspace"
    ".features.heartbeat.interval"
    ".features.heartbeat.timeout"
    ".features.heartbeat.retries"
    ".features.heartbeat.default_prompt"
    ".notifications.channel"
    ".docker.uid"
    ".docker.gid"
    ".docker.image_tag"
    ".docker.base_image"
  )
  local missing=()
  local key val
  for key in "${required[@]}"; do
    val=$(yq "$key" "$yml" 2>/dev/null)
    if [ -z "$val" ] || [ "$val" = "null" ]; then
      missing+=("$key")
    fi
  done
  if [ ${#missing[@]} -gt 0 ]; then
    echo "ERROR: agent.yml is missing required field(s):" >&2
    printf '  - %s\n' "${missing[@]}" >&2
    echo "" >&2
    echo "Run ./setup.sh --reset to re-collect, or edit agent.yml by hand." >&2
    return 1
  fi
  return 0
}

# Print (do not execute) suggested plugin install commands so the user can run
# them on their own terms.
maybe_print_plugin_hints() {
  local agent_yml="$SCRIPT_DIR/agent.yml"
  local plugin_count
  plugin_count=$(yq '.plugins | length' "$agent_yml" 2>/dev/null || echo 0)
  [ "$plugin_count" -le 0 ] && return 0

  echo ""
  echo "▸ Suggested Claude Code plugins (install at your discretion):"
  local i p
  for i in $(seq 0 $((plugin_count - 1))); do
    p=$(yq ".plugins[$i]" "$agent_yml")
    echo "    claude plugin install $p"
  done
}

# Undo what install_service + regenerate created. Always safe to re-run.
# Preserves agent.yml and .env unless --purge is set.
uninstall() {
  local agent_yml="$SCRIPT_DIR/agent.yml"
  local env_file="$SCRIPT_DIR/.env"

  if [ ! -f "$agent_yml" ]; then
    echo "ERROR: agent.yml not found in $SCRIPT_DIR" >&2
    # Heuristic: if this directory has modules/ + scripts/lib/ but no agent.yml,
    # it's an installer clone, not an agent destination.
    if [ -d "$SCRIPT_DIR/modules" ] && [ -d "$SCRIPT_DIR/scripts/lib" ]; then
      echo "" >&2
      echo "This looks like the installer clone. The agent's files were scaffolded" >&2
      echo "to a destination elsewhere — uninstall must be run from that directory." >&2
      echo "" >&2
      echo "Try:" >&2
      echo "  cd <your-agent-workspace>" >&2
      echo "  ./setup.sh --uninstall" >&2
    else
      echo "       (If you manually deleted agent.yml but files linger, remove them by hand.)" >&2
    fi
    exit 1
  fi

  render_load_context "$agent_yml"
  local agent_name="${AGENT_NAME:-}"
  if [ -z "$agent_name" ]; then
    echo "ERROR: agent.name missing from agent.yml; cannot identify what to uninstall." >&2
    exit 1
  fi

  echo ""
  echo "═══════════════════════════════════════════════════"
  echo " Uninstall — ${agent_name}"
  echo "═══════════════════════════════════════════════════"
  echo ""
  echo "This will remove:"
  echo "  - docker compose down (stops container; state in .state/ preserved)"
  echo "  - /etc/systemd/system/agent-${agent_name}.service (if present)"
  echo "  - Generated repo files: CLAUDE.md, .mcp.json, .env.example,"
  echo "    scripts/heartbeat/heartbeat.conf, scripts/heartbeat/logs/"
  if [ "$UNINSTALL_PURGE" = true ]; then
    echo "  - agent.yml (source of truth)"
    echo "  - .env (secrets)"
    echo "  - .state/ (login, pairing, sessions, plugin cache)"
  else
    echo ""
    echo "Preserved (pass --purge to also remove):"
    echo "  - agent.yml"
    echo "  - .env"
    echo "  - .state/ (login, pairing, sessions)"
  fi
  if [ "$UNINSTALL_NUKE" = true ]; then
    echo "  - $SCRIPT_DIR (entire workspace directory)"
    echo "  - its parent directory if left empty"
  fi
  echo ""

  if [ "$UNINSTALL_YES" != true ]; then
    if [ "$(ask_yn 'Continue?' 'n')" != "true" ]; then
      echo "Aborted."
      exit 0
    fi
  fi

  echo ""
  echo "▸ Stopping services"

  # --- Docker teardown ---
  # State now lives at ${SCRIPT_DIR}/.state (bind-mount), so `down -v`
  # has nothing to wipe — plain `down` is enough. State removal happens
  # below via --purge or --nuke (workspace delete).
  if command -v docker &>/dev/null; then
    (cd "$SCRIPT_DIR" && docker compose down 2>/dev/null) && \
      echo "  ✓ docker compose down (container stopped; state in .state/ preserved)" || \
      echo "  ⚠ docker compose down failed or already down"
  else
    echo "  ⚠ docker not on PATH — skipping container teardown"
  fi
  local unit_file="/etc/systemd/system/agent-${agent_name}.service"
  if [ -f "$unit_file" ]; then
    if sudo -n true 2>/dev/null; then
      sudo systemctl disable --now "agent-${agent_name}.service" 2>/dev/null || true
      sudo rm -f "$unit_file" && echo "  ✓ removed $unit_file" || true
      sudo systemctl daemon-reload 2>/dev/null || true
    else
      echo "  ◦ $unit_file present — remove manually with sudo"
    fi
  fi
  rm -f "$SCRIPT_DIR/docker-compose.yml" && echo "  ✓ docker-compose.yml" || true

  # ── Delete the GitHub fork (opt-in, irreversible) ────────────────
  if [ "$UNINSTALL_DELETE_FORK" = true ]; then
    if [ "$UNINSTALL_YES" != true ]; then
      echo "ERROR: --delete-fork requires --yes (the deletion is irreversible)." >&2
      exit 1
    fi
    local fork_enabled fork_owner fork_name fork_token=""
    fork_enabled=$(yq '.scaffold.fork.enabled // false' "$agent_yml")
    if [ "$fork_enabled" != "true" ]; then
      echo "⚠ --delete-fork ignored: agent was not scaffolded with a fork"
    else
      fork_owner=$(yq '.scaffold.fork.owner' "$agent_yml")
      fork_name=$(yq '.scaffold.fork.name' "$agent_yml")
      [ -f "$env_file" ] && fork_token=$(grep -E '^GITHUB_FORK_PAT=' "$env_file" | cut -d= -f2- || true)
      if [ -z "$fork_token" ]; then
        echo "⚠ GITHUB_FORK_PAT missing from .env — cannot delete the fork automatically"
        echo "  Delete it manually at https://github.com/${fork_owner}/${fork_name}/settings"
      else
        echo ""
        echo "▸ Deleting GitHub fork ${fork_owner}/${fork_name}..."
        if GH_TOKEN="$fork_token" gh repo delete "${fork_owner}/${fork_name}" --yes >/dev/null 2>&1; then
          echo "  ✓ fork deleted"
        else
          echo "  ✗ fork deletion failed (PAT needs delete_repo scope)" >&2
        fi
      fi
    fi
  fi

  echo ""
  echo "▸ Removing generated repo files"
  rm -f "$SCRIPT_DIR/CLAUDE.md" && echo "  ✓ CLAUDE.md" || true
  rm -f "$SCRIPT_DIR/.mcp.json" && echo "  ✓ .mcp.json" || true
  rm -f "$SCRIPT_DIR/.env.example" && echo "  ✓ .env.example" || true
  rm -f "$SCRIPT_DIR/scripts/heartbeat/heartbeat.conf" && echo "  ✓ scripts/heartbeat/heartbeat.conf" || true
  rm -rf "$SCRIPT_DIR/scripts/heartbeat/logs" && echo "  ✓ scripts/heartbeat/logs/" || true

  if [ "$UNINSTALL_PURGE" = true ]; then
    echo ""
    echo "▸ Purging source of truth, secrets, and state"
    rm -f "$agent_yml" && echo "  ✓ agent.yml" || true
    rm -f "$env_file" && echo "  ✓ .env" || true
    rm -rf "$SCRIPT_DIR/.state" && echo "  ✓ .state/ (login, pairing, sessions, plugin cache)" || true
  fi

  # ── Nuke: remove the workspace itself (and walk up if empty) ─────
  if [ "$UNINSTALL_NUKE" = true ]; then
    echo ""
    echo "▸ Nuking workspace"
    local workspace_dir="$SCRIPT_DIR"
    local parent_dir
    parent_dir=$(dirname "$workspace_dir")
    # Step out of the workspace before deleting it.
    cd "$parent_dir"
    if command -v trash &>/dev/null; then
      trash "$workspace_dir" 2>/dev/null && echo "  ✓ trashed $workspace_dir" || \
        { rm -rf "$workspace_dir" && echo "  ✓ removed $workspace_dir"; }
    else
      rm -rf "$workspace_dir" && echo "  ✓ removed $workspace_dir"
    fi
    # Walk up: if the parent is empty AND under $HOME AND not $HOME itself, remove it too.
    if [ -d "$parent_dir" ] && \
       [ "$parent_dir" != "$HOME" ] && \
       [ "$(cd "$parent_dir" && ls -A)" = "" ] && \
       [[ "$parent_dir" == "$HOME"/* ]]; then
      rmdir "$parent_dir" 2>/dev/null && echo "  ✓ removed empty parent $parent_dir" || true
    fi
  fi

  echo ""
  echo "✓ Uninstall complete."
  if [ "$UNINSTALL_PURGE" != true ] && [ "$UNINSTALL_NUKE" != true ]; then
    echo "  agent.yml, .env, and .state/ preserved — run ./setup.sh to"
    echo "  reinstall; login + Telegram pairing will carry over."
  fi
}

main() {
  parse_args "$@"
  yaml_require_yq || exit 1
  load_wizard_helpers

  local agent_yml="$SCRIPT_DIR/agent.yml"

  case "$MODE" in
    reset)
      echo "Resetting: removing agent.yml"
      rm -f "$agent_yml"
      run_wizard
      ;;
    non-interactive)
      if [ ! -f "$agent_yml" ]; then
        echo "ERROR: agent.yml not found; cannot run in --non-interactive mode" >&2
        exit 1
      fi
      validate_agent_yml_required "$agent_yml" || exit 1
      regenerate
      ;;
    regenerate)
      if [ ! -f "$agent_yml" ]; then
        echo "ERROR: agent.yml not found; run wizard first" >&2
        exit 1
      fi
      validate_agent_yml_required "$agent_yml" || exit 1
      regenerate
      ;;
    uninstall)
      uninstall
      ;;
    sync-template)
      sync_template
      ;;
    auto)
      if [ -f "$agent_yml" ]; then
        regenerate
      else
        run_wizard
      fi
      ;;
  esac
}

main "$@"
