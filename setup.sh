#!/usr/bin/env bash
# setup.sh — Wizard + regenerate orchestrator for agentic-pod-launcher

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/scripts/lib/yaml.sh"
source "$SCRIPT_DIR/scripts/lib/render.sh"
source "$SCRIPT_DIR/scripts/lib/plugin-catalog.sh"
source "$SCRIPT_DIR/scripts/lib/mcp-catalog.sh"
source "$SCRIPT_DIR/scripts/lib/schema.sh"
source "$SCRIPT_DIR/scripts/lib/local_schedule.sh"
source "$SCRIPT_DIR/scripts/lib/versions.sh"
source "$SCRIPT_DIR/scripts/lib/fork.sh"

# Launcher version, surfaced in agent.yml::meta and `agentctl doctor` so
# scaffolded workspaces can advertise which launcher rev produced them.
# VERSION is a plain-text file at the repo root, hand-maintained alongside
# CHANGELOG entries. Use input redirection (no pipe) so a missing VERSION
# under `set -euo pipefail` falls through to the "unknown" fallback rather
# than killing the script before parse_args runs.
LAUNCHER_VERSION="unknown"
if [ -f "$SCRIPT_DIR/VERSION" ]; then
  LAUNCHER_VERSION="$(tr -d '[:space:]' < "$SCRIPT_DIR/VERSION")"
  [ -z "$LAUNCHER_VERSION" ] && LAUNCHER_VERSION="unknown"
fi

GUM=""  # populated by ensure_gum

# require_tool TOOL [DOC_URL]
# Bail out with an OS-aware install hint if a CLI tool is missing. Centralises
# what would otherwise be ad-hoc `command -v X &>/dev/null || echo "install X"`
# scattered through the script. Keeps every "missing tool" path producing the
# same friendly message shape.
require_tool() {
  local tool="$1" doc_url="${2:-}"
  command -v "$tool" >/dev/null 2>&1 && return 0
  echo "ERROR: $tool is required but was not found in PATH." >&2
  echo "" >&2
  echo "Install it:" >&2
  case "$tool" in
    yq)
      # main() calls yaml_require_yq before this branch can fire, so it's
      # mostly defensive. Keep it free of `apt install yq` because Debian/
      # Ubuntu's package is python-yq v3 (Python wrapper, incompatible
      # syntax), not mikefarah's Go binary.
      echo "  • macOS:  brew install yq" >&2
      echo "  • Linux:  https://github.com/mikefarah/yq#install" >&2
      echo "            (do NOT use apt install yq — that's the v3 Python wrapper)" >&2
      echo "  • Auto:   re-run ./setup.sh — yaml_require_yq vendors v4+ for you" >&2
      ;;
    jq)
      echo "  • macOS:  brew install jq" >&2
      echo "  • Linux:  apt install jq | dnf install jq" >&2
      echo "  • Other:  https://stedolan.github.io/jq/download/" >&2
      ;;
    gh)
      echo "  • macOS:  brew install gh" >&2
      echo "  • Linux:  apt install gh   (or follow https://cli.github.com/)" >&2
      echo "  • Auth:   gh auth login   (after install)" >&2
      ;;
    git)
      echo "  • macOS:  xcode-select --install   (or brew install git)" >&2
      echo "  • Linux:  apt install git | dnf install git" >&2
      ;;
    docker)
      echo "  • macOS:  https://docs.docker.com/desktop/install/mac-install/" >&2
      echo "  • Linux:  https://docs.docker.com/engine/install/" >&2
      ;;
    *)
      [ -n "$doc_url" ] && echo "  • Docs: $doc_url" >&2
      ;;
  esac
  exit 1
}

# Detect which claude CLI variant is installed. Preference order:
# claude-enterprise > claude-personal > claude. Falls back to "claude"
# if none are found (user will install it later).
# Resolve a configured Claude CLI reference to an ABSOLUTE, executable path.
# Echoes the absolute path and returns 0; returns 1 (nothing on stdout) if it
# cannot resolve. systemd resolves a unit's ExecStart against the manager PATH
# (it ignores Environment=PATH), so a bare `claude` — native installer puts it at
# ~/.local/bin/claude, outside that PATH — yields status=203/EXEC. The unit MUST
# carry an absolute path. Prefer a stable symlink (survives Claude Code updates).
#   $1 = configured value (may be absolute or a bare name); default `claude`
#   $2 = the agent operator's HOME (defaults to $HOME) — probe THAT home, not the
#        home of whoever runs --regenerate (root-vs-operator edge case).
resolve_claude_bin() {
  local cli="${1:-claude}" home="${2:-$HOME}" c p
  # 1) already absolute + executable -> use as-is.
  if [ "${cli#/}" != "$cli" ] && [ -x "$cli" ]; then printf '%s\n' "$cli"; return 0; fi
  # 2) a bare name currently on PATH (command -v yields an absolute path for a file).
  if [ "${cli#/}" = "$cli" ]; then
    c=$(command -v "$cli" 2>/dev/null) && [ "${c#/}" != "$c" ] && [ -x "$c" ] \
      && { printf '%s\n' "$c"; return 0; }
  fi
  # 3) known candidate names on PATH.
  for c in claude-enterprise claude-personal claude; do
    p=$(command -v "$c" 2>/dev/null) && [ "${p#/}" != "$p" ] && [ -x "$p" ] \
      && { printf '%s\n' "$p"; return 0; }
  done
  # 4) native-installer / local-install absolute candidates under the agent HOME.
  for c in "$home/.local/bin/claude" "$home/.claude/local/claude"; do
    [ -x "$c" ] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}

# Scaffold-time detection: persist an ABSOLUTE path in agent.yml when Claude is
# already installed. If it is not yet installed, fall back to the bare literal so
# the scaffold does not hard-fail — the local-mode render (_export_local_context)
# re-resolves and FAILS LOUD if it is still unresolvable at unit-emit time.
detect_claude_cli() {
  local abs
  abs=$(resolve_claude_bin "claude" "$HOME") && { printf '%s\n' "$abs"; return 0; }
  echo "claude"
}

# Principle I: persist the resolved absolute path back to agent.yml so a headless
# re-regenerate (where `command -v claude` fails) never re-derives a bare literal.
# Writes only when the value actually changed. Best-effort (yq may be absent in
# an odd context) — the render-time guard is the real safety net.
_persist_claude_cli() {
  local agent_yml="$1" resolved="$2" current
  [ -f "$agent_yml" ] || return 0
  [ -n "$resolved" ] || return 0
  command -v yq >/dev/null 2>&1 || return 0
  current=$(yq -r '.deployment.claude_cli // ""' "$agent_yml" 2>/dev/null)
  [ "$current" = "$resolved" ] && return 0
  yq -i ".deployment.claude_cli = \"$resolved\"" "$agent_yml" 2>/dev/null || true
}

# 022 (US3/FR-009): the DEFAULT for the client-visible session name
# (`claude remote-control --name <v>`). Only computed when agent.yml carries no
# explicit deployment.session_name; the explicit value always wins, verbatim.
#
# Two things this fixes. (a) The old value was composed in the template as
# {{HOST_NAME}}-{{AGENT_NAME}} with HOST_NAME=$(hostname) at render time, so an
# agent named after its host read `mclaren-mclaren-admin` — and moving the
# workspace to another machine silently changed the agent's identity. (b) It
# lived nowhere in agent.yml, so it was neither configurable nor reproducible
# by re-rendering (Principle I).
#
# The host is normalized with the normalize_agent_name rules
# (scripts/lib/wizard-validators.sh:100-108) applied to its FIRST dot-label: a
# FQDN or an mDNS `.local` would otherwise yield `mclaren.local-mclaren-admin`
# and break the prefix test. agent_name needs no normalization — validate_agent_name
# already guarantees lowercase/digits/hyphens.
#
# The prefix test carries a FRONTIER HYPHEN on purpose. A bare prefix would make
# host `rpi5` + agent `rpi5x` resolve to `rpi5x`, dropping the host segment on a
# false positive.
_resolve_session_name() {
  local agent_name="$1" host="${2:-}" seg
  seg="${host%%.*}"
  # yq prints the literal string "null" for an ABSENT path; reading it without
  # `// ""` upstream would otherwise resolve a plausible-looking "null-locbot".
  [ "$seg" = "null" ] && seg=""
  seg=$(printf '%s' "$seg" | tr '[:upper:]' '[:lower:]')
  seg="${seg// /-}"
  seg=$(printf '%s' "$seg" | tr -s '-')
  seg="${seg#-}"
  seg="${seg%-}"

  [ -n "$seg" ] || { printf '%s\n' "$agent_name"; return 0; }
  [ "$agent_name" != "$seg" ] || { printf '%s\n' "$agent_name"; return 0; }
  case "$agent_name" in
    "$seg"-*) printf '%s\n' "$agent_name"; return 0 ;;
  esac
  printf '%s\n' "${seg}-${agent_name}"
}

# Fetch a user's preferred SSH public key from GitHub.
# Prefers ssh-ed25519, falls back to ssh-rsa. Returns the full key line
# (type + base64 + comment) on stdout, or non-zero on failure / no keys.
#
# SSH_KEYS_URL_TEMPLATE allows tests to override the endpoint. In production
# it resolves to https://github.com/<user>.keys.
fetch_github_ssh_key() {
  local owner="$1"
  local url_tpl="${SSH_KEYS_URL_TEMPLATE:-https://github.com/%s.keys}"
  local url
  # shellcheck disable=SC2059  # the template IS the format
  url=$(printf "$url_tpl" "$owner")

  local body
  if ! body=$(curl -fsSL --max-time 10 "$url" 2>/dev/null); then
    return 1
  fi
  [ -n "$body" ] || return 1

  local key
  key=$(printf '%s\n' "$body" | grep -m 1 '^ssh-ed25519 ' || true)
  [ -z "$key" ] && key=$(printf '%s\n' "$body" | grep -m 1 '^ssh-rsa ' || true)
  [ -n "$key" ] || return 1

  printf '%s\n' "$key"
}

# Given a path to an agent.yml, populate backup.identity.recipient by
# fetching the fork owner's GitHub SSH keys. Falls back to leaving it null
# + warning when no key is available (Fallback A4 — partial backup mode).
configure_identity_backup() {
  local agent_yml="$1"
  local owner
  owner=$(yq '.scaffold.fork.owner // ""' "$agent_yml" 2>/dev/null)

  if [ -z "$owner" ] || [ "$owner" = "null" ]; then
    echo "▸ Identity backup: skipping (no scaffold.fork.owner — fork-less agent)"
    return 0
  fi

  local key
  if key=$(fetch_github_ssh_key "$owner"); then
    yq -i ".backup.identity.recipient = \"$key\"" "$agent_yml"
    echo "  ✓ identity backup: using SSH key from github.com/$owner.keys"
  else
    echo "  ⚠ identity backup: no SSH key at github.com/$owner.keys — running in partial mode (plaintext-only, .env excluded)"
    echo "    Run 'heartbeatctl backup-identity --configure-key <path>' later to enable .env encryption."
  fi
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
  # Single-sourced from scripts/lib/versions.sh so the host gum and the
  # image-baked gum can't drift (a bats invariant enforces it). Fail loud if
  # versions.sh wasn't sourced rather than fall back to a stale literal.
  local version="${AGENTIC_FLOOR_GUM:?scripts/lib/versions.sh must be sourced}"
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

# Ensure gh is available. Returns 0 if found or downloaded; 1 otherwise.
# Pattern mirrors ensure_gum / yaml_bootstrap_yq — vendor into scripts/vendor/bin/
# instead of telling the user to apt/brew install it. Pinned because
# scaffold_with_fork() depends on flags introduced in gh ≥2.40
# (`--accept-visibility-change-consequences` on `gh repo edit`).
#
# Naming caveats baked in (release-page reality, not arbitrary choices):
#   - gh tarballs name macOS as "macOS" (capitalized), not "darwin".
#   - gh uses "armv6" for 32-bit ARM (covers RPi Zero/2/3 armv7l/armv6l).
#   - macOS asset is .zip; Linux is .tar.gz.
ensure_gh() {
  command -v gh &>/dev/null && return 0

  local vendor_dir="$SCRIPT_DIR/scripts/vendor/bin"
  if [ -x "$vendor_dir/gh" ]; then
    export PATH="$vendor_dir:$PATH"
    hash -r 2>/dev/null || true
    return 0
  fi

  local version="2.62.0"
  local os arch pkg_os ext
  os=$(uname -s | tr '[:upper:]' '[:lower:]')
  case "$(uname -m)" in
    x86_64|amd64)  arch="amd64" ;;
    arm64|aarch64) arch="arm64" ;;
    armv7l|armv6l) arch="armv6" ;;
    i386|i686)     arch="386" ;;
    *)
      echo "WARN: gh auto-download not supported for arch '$(uname -m)'." >&2
      return 1
      ;;
  esac
  case "$os" in
    darwin) pkg_os="macOS"; ext="zip" ;;
    linux)  pkg_os="linux"; ext="tar.gz" ;;
    *)
      echo "WARN: gh auto-download not supported for OS '$os'." >&2
      return 1
      ;;
  esac

  local pkg="gh_${version}_${pkg_os}_${arch}"
  local url="https://github.com/cli/cli/releases/download/v${version}/${pkg}.${ext}"

  mkdir -p "$vendor_dir"
  echo "▸ Bootstrapping gh v${version} (${os}/${arch}, one-time, ~10MB)..." >&2
  if ! curl -sL --fail "$url" -o "$vendor_dir/gh.archive" 2>/dev/null; then
    echo "WARN: gh download failed ($url)." >&2
    rm -f "$vendor_dir/gh.archive"
    return 1
  fi

  if [ "$ext" = "zip" ]; then
    if ! command -v unzip &>/dev/null; then
      echo "WARN: unzip is required to extract gh on macOS — install with 'brew install unzip' or grab gh manually from https://cli.github.com/" >&2
      rm -f "$vendor_dir/gh.archive"
      return 1
    fi
    (cd "$vendor_dir" && unzip -qo gh.archive && mv "${pkg}/bin/gh" gh && rm -rf "${pkg}")
  else
    tar -xzf "$vendor_dir/gh.archive" -C "$vendor_dir" --strip-components=2 "${pkg}/bin/gh" 2>/dev/null \
      || { tar -xzf "$vendor_dir/gh.archive" -C "$vendor_dir" \
            && mv "$vendor_dir/${pkg}/bin/gh" "$vendor_dir/gh" \
            && rm -rf "$vendor_dir/${pkg}"; }
  fi
  rm -f "$vendor_dir/gh.archive"

  if [ -x "$vendor_dir/gh" ]; then
    echo "  ✓ gh installed at $vendor_dir/gh" >&2
    export PATH="$vendor_dir:$PATH"
    hash -r 2>/dev/null || true
    return 0
  fi
  echo "WARN: gh extraction failed." >&2
  return 1
}

# Decide which wizard helper set to load. Prefer gum when:
# - stdin is a TTY (interactive user, not piped test input)
# - and gum can be installed/found
# Validators (validate_email, validate_telegram_token, etc.) are pure
# helpers shared by both wizard variants — sourced unconditionally.
load_wizard_helpers() {
  source "$SCRIPT_DIR/scripts/lib/wizard-validators.sh"
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
RESTORE_FORK_URL=""
RESTORE_IDENTITY_KEY=""
ROLE_FILE=""

print_usage() {
  cat << 'EOF'
Usage: ./setup.sh [options]

Options:
  (no flags)           Interactive wizard on first run; regenerate on subsequent runs.
  --regenerate         Re-render derived files from agent.yml (keeps CLAUDE.md).
  --login              (local mode) Run the guided one-time full-scope OAuth
                       login + workspace trust + enable the systemd session.
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
  --role-file PATH     (wizard only) Use a multi-line persona file as the agent role.
                       Copied into the workspace; injected verbatim into CLAUDE.md.
  --in-place           (wizard only) Skip scaffold — generate files in the current
                       directory (legacy behavior).
  --version, -V        Print the launcher version and exit.
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
      --login) MODE="login"; shift ;;
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
      --role-file) ROLE_FILE="$2"; shift 2 ;;
      --in-place) IN_PLACE=true; shift ;;
      --restore-from-fork) RESTORE_FORK_URL="$2"; shift 2 ;;
      --identity-key) RESTORE_IDENTITY_KEY="$2"; shift 2 ;;
      --backup) MODE="backup"; shift ;;
      --version|-V) printf '%s\n' "$LAUNCHER_VERSION"; exit 0 ;;
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

  # ── 0. Deployment mode (011) ────────────────────────
  # Asked FIRST so the two flows stay cleanly separated from the start: the
  # whole wizard + render branch on this choice. docker (recommended) is the
  # least-privilege container; local runs directly on the host via systemd.
  echo "▸ Deployment mode"
  echo "  • docker  — isolated, least-privilege container (recommended)."
  echo "  • local   — runs directly on this host via systemd (Linux/systemd only)."
  local deploy_mode
  deploy_mode=$(ask_choice "Deployment mode" "docker" "docker local")
  if [ "$deploy_mode" = "local" ]; then
    echo ""
    echo "  ⚠ LOCAL MODE SECURITY WARNING"
    echo "    The agent runs as YOUR login user and inherits your privileges and"
    echo "    secrets (files, SSH keys, tokens). There is NO container isolation —"
    echo "    this breaks the least-privilege model the docker mode enforces."
    echo "    Whoever controls the claude.ai account controls this host: MFA is"
    echo "    MANDATORY. Local mode is Linux/systemd only."
  fi
  echo ""

  # ── 1. Identity ─────────────────────────────────────
  echo "▸ Agent identity"
  local agent_name agent_display agent_role agent_vibe
  # Normalize the raw input toward a valid DNS label (lowercase, spaces→
  # hyphens, collapse/trim hyphens) so the user's "My Agent" becomes
  # "my-agent". When normalization changes the value we show the result and
  # ask for confirmation; the validator then enforces the remaining rules,
  # surfacing a clear error instead of failing silently in `docker compose
  # build` later.
  local _raw_input
  while true; do
    _raw_input=$(ask "Agent name (lowercase, no spaces)" "my-agent")
    agent_name=$(normalize_agent_name "$_raw_input")
    if [ "$agent_name" != "$_raw_input" ]; then
      echo "  ↳ normalized to: $agent_name"
      if [ "$(ask_yn "Use '$agent_name'?" "y")" != "true" ]; then
        continue
      fi
    fi
    if validate_agent_name "$agent_name"; then
      break
    fi
  done
  agent_display=$(ask "Display name (with emoji)" "MyAgent 🤖")
  agent_role=$(ask "Role description" "Admin assistant for my ecosystem")
  agent_vibe=$(ask "Vibe / personality (one line)" "Direct, useful, no drama")
  # Optional multi-line persona via --role-file. Validate up front and fail
  # loud — a missing file must never silently degrade to the one-line role.
  if [ -n "$ROLE_FILE" ]; then
    if [ ! -f "$ROLE_FILE" ]; then
      echo "  ✗ --role-file not found: $ROLE_FILE" >&2
      exit 1
    fi
    echo "  ↳ persona file: $ROLE_FILE (copied into the workspace as personas/${agent_name}.md)"
  fi
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
  user_tz=$(ask_validated "Timezone" validate_timezone "$tz_default")
  user_email=$(ask_validated "Primary email" validate_email)
  user_lang=$(ask_choice "Preferred language" "en" "es en mixed")
  echo ""

  # ── 3. Deployment ───────────────────────────────────
  echo "▸ Deployment"
  local deploy_host deploy_ws deploy_svc
  deploy_host=$(hostname)
  echo "  Host machine: $deploy_host (used only for fork branch naming;"
  echo "  the agent itself runs inside the container)"
  if [ -n "$DESTINATION" ]; then
    # Non-interactive: validate the flag up front and fail loud — a bad
    # --destination can't be re-prompted, so a silent accept would scaffold
    # to a nonsense path.
    deploy_ws=$(normalize_destination_path "$DESTINATION")
    if ! validate_destination_path "$deploy_ws"; then
      echo "  ✗ Invalid --destination: $DESTINATION" >&2
      exit 1
    fi
    echo "  Agent destination directory: $deploy_ws (from --destination flag)"
  else
    # Default: <parent-of-installer>/agents/<agent_name> — groups agents
    # under a single sibling "agents/" folder next to the installer clone.
    local installer_parent default_dest _raw_dest
    installer_parent=$(dirname "$SCRIPT_DIR")
    default_dest="${installer_parent}/agents/${agent_name}"
    while true; do
      _raw_dest=$(ask "Agent destination directory" "$default_dest")
      deploy_ws=$(normalize_destination_path "$_raw_dest")
      if [ "$deploy_ws" != "$_raw_dest" ]; then
        echo "  ↳ expanded to: $deploy_ws"
      fi
      if validate_destination_path "$deploy_ws"; then
        break
      fi
    done
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
  if [ "$deploy_mode" = "local" ]; then
    echo "  Local mode: the agent's Claude config + login live on the host under"
    echo "  <workspace>/.state/.claude (gitignored). Run the one-time full-scope"
    echo "  login after scaffolding with: ./setup.sh --login"
  else
    echo "  Profile lives at /home/agent/.claude inside the container"
    echo "  (isolated on the named state volume — run /login inside tmux once"
    echo "  after first boot)."
  fi
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
    ensure_gh || require_tool gh
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

    # Story B: a fork of a PUBLIC template can't be private (GitHub 422). Probe
    # the template's visibility and, on a public+private conflict, warn and let
    # the operator choose; in a non-interactive run, default to disable-fork
    # rather than silently expose data (FR-B4). Fail loud if the probe fails.
    local _fork_decision
    if ! _fork_decision=$(fork_resolve_visibility "$template_url" "$fork_enabled" "$fork_private" "$fork_token"); then
      echo "  ✗ Could not determine the template repo's visibility (gh api failed)." >&2
      echo "    Refusing to create a fork blind — check the template URL / token and retry." >&2
      exit 1
    fi
    fork_enabled="${_fork_decision%% *}"
    fork_private="${_fork_decision##* }"
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
    while true; do
      notify_bot_token=$(ask_secret "Heartbeat bot token (or skip)")
      # Empty = skip (fill .env later). Non-empty must look like a real token.
      [ -z "$notify_bot_token" ] && break
      if validate_telegram_token "$notify_bot_token"; then
        break
      fi
    done

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
  # Always-on (zero config, low overhead): driven by the catalog at
  # modules/mcps/*.yml where type=default. Listed once for the user's awareness.
  local _default_ids _default_csv
  _default_ids=$(mcp_catalog_list default | tr '\n' ',' | sed 's/,$//' | tr ',' ' ')
  _default_csv=$(echo "$_default_ids" | tr ' ' ',' | sed 's/,/, /g')
  echo "  Always on (low overhead): $_default_csv"
  echo ""
  echo "  The following are opt-in — Enter to skip:"
  echo ""

  # Iterate optional MCPs from the catalog. Same pattern as the optional
  # plugins block: pre-collect IDs into a plain array first so ask_yn inside
  # the loop reads its y/n answers from the user's stdin (not from the IDs
  # stream that `done < <(...)` would redirect into the loop body).
  local _opt_mcp_ids=()
  local _opt_mcp_id _mcp_desc _mcp_useful _mcp_overhead _mcp_secret_env _mcp_secret_url
  while IFS= read -r _opt_mcp_id; do
    [ -z "$_opt_mcp_id" ] && continue
    _opt_mcp_ids+=("$_opt_mcp_id")
  done < <(mcp_catalog_list optional)
  # Track which optional MCPs the user enabled. We export the canonical
  # MCPS_<ID>_ENABLED env var for each so the renderer (mcp-json.tpl) can
  # gate its `{{#if}}` block, and we collect them into an array used by the
  # agent.yml heredoc to persist mcps.defaults.
  local active_optional_mcps=()
  local mcp_secret_env_lines=""
  for _opt_mcp_id in "${_opt_mcp_ids[@]}"; do
    _mcp_desc=$(mcp_catalog_get "$_opt_mcp_id" description)
    _mcp_useful=$(mcp_catalog_get "$_opt_mcp_id" when_useful)
    _mcp_overhead=$(mcp_catalog_get "$_opt_mcp_id" when_overhead)
    _mcp_secret_env=$(mcp_catalog_get "$_opt_mcp_id" secret_env_var)
    _mcp_secret_url=$(mcp_catalog_get "$_opt_mcp_id" secret_doc_url)
    echo "  · ${_opt_mcp_id}"
    echo "    ${_mcp_desc}"
    echo "    Útil: ${_mcp_useful}"
    echo "    Overhead: ${_mcp_overhead}"
    local _envvar
    _envvar=$(mcp_catalog_id_to_envvar "$_opt_mcp_id")
    if [ "$(ask_yn "    Install ${_opt_mcp_id}?" "n")" = "true" ]; then
      eval "export ${_envvar}=true"
      active_optional_mcps+=("$_opt_mcp_id")
      # If the MCP needs a secret in .env, prompt for it now (mirrors the
      # Telegram/Atlassian pattern: empty input is OK — leaves the user to
      # fill it later in .env).
      if [ -n "$_mcp_secret_env" ]; then
        if [ -n "$_mcp_secret_url" ]; then
          echo "    Secret: ${_mcp_secret_env} — generate at ${_mcp_secret_url}"
        else
          echo "    Secret: ${_mcp_secret_env}"
        fi
        echo "    (Press Enter to skip — fill ${_mcp_secret_env} in .env later.)"
        local _secret_val
        _secret_val=$(ask_secret "    ${_mcp_secret_env} (or skip)")
        if [ -n "$_secret_val" ]; then
          mcp_secret_env_lines="${mcp_secret_env_lines}${_mcp_secret_env}=${_secret_val}
"
        else
          mcp_secret_env_lines="${mcp_secret_env_lines}${_mcp_secret_env}=
"
        fi
      fi
    else
      eval "export ${_envvar}=false"
    fi
    echo ""
  done

  local atlassian_entries=""
  local atlassian_env_vars=""
  if [ "$(ask_yn 'Enable Atlassian MCP?' 'n')" = "true" ]; then
    while true; do
      local ws_name ws_url ws_email ws_token
      ws_name=$(ask_validated "Workspace alias (e.g. personal, work) — unique identifier for this Atlassian account" validate_atlassian_alias)
      ws_url=$(ask_validated "Atlassian URL (e.g. https://yourco.atlassian.net)" validate_url)
      ws_email=$(ask_validated "Email" validate_email "$user_email")
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
    github_email=$(ask_validated "GitHub account email" validate_email "$user_email")
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
    hb_interval=$(ask_validated "Default interval (Nm/Nh or 5-field cron)" validate_cron_or_interval "30m")
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
  local vault_enabled vault_seed vault_mcp_enabled vault_qmd_enabled
  vault_enabled=$(ask_yn "Enable knowledge vault?" "y")
  vault_seed=false
  vault_mcp_enabled=false
  vault_qmd_enabled=false
  if [ "$vault_enabled" = "true" ]; then
    vault_seed=$(ask_yn "  Seed initial vault structure (templates, schema, log)?" "y")
    vault_mcp_enabled=$(ask_yn "  Register MCPVault server (@bitbonsai/mcpvault)?" "y")
    vault_qmd_enabled=$(ask_yn "  Enable QMD hybrid search (BM25+vector+rerank, ~300MB embedding model on first use)?" "n")
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
  # Helper for the summary block: ofusca un secret si está seteado, marca
  # "(unset)" si está vacío. Local al while loop para no contaminar el shell.
  _mask() {
    if [ -n "$1" ]; then echo "********"; else echo "(unset)"; fi
  }
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
    if [ "$notify_channel" = "telegram" ]; then
      echo "     Bot token:        $(_mask "$notify_bot_token")"
      echo "     Chat id:          ${notify_chat_id:-(unset)}"
    fi
    echo " 14) Heartbeat enabled: $hb_enabled"
    [ "$hb_enabled" = "true" ] && echo " 15) Heartbeat interval: $hb_interval"
    [ "$hb_enabled" = "true" ] && echo " 16) Heartbeat prompt:   $hb_prompt"
    echo " 17) Default princ:     $use_defaults"
    echo "     Vault enabled:    $vault_enabled"
    [ "$vault_enabled" = "true" ] && echo "     Vault seed:       $vault_seed"
    [ "$vault_enabled" = "true" ] && echo "     Vault MCP:        $vault_mcp_enabled"
    [ "$vault_enabled" = "true" ] && echo "     Vault QMD:        $vault_qmd_enabled"
    echo " 18) GitHub fork:       $fork_enabled"
    if [ "$fork_enabled" = "true" ]; then
      echo " 19) Fork owner:        $fork_owner"
      echo " 20) Fork name:         $fork_name"
      echo " 21) Fork private:      $fork_private"
      echo " 22) Template URL:      $template_url"
      echo " 23) Fork PAT:          $(_mask "$fork_token")"
    fi
    echo ""
    # Atlassian — full detail per workspace (URL, email, masked token).
    if [ -n "$atlassian_entries" ]; then
      echo "  Atlassian:"
      local _line _key _upper _ws_lower _ws_url _ws_email _ws_tok
      while IFS= read -r _line; do
        case "$_line" in
          ATLASSIAN_*_TOKEN=*)
            _key="${_line%%=*}"
            _ws_tok="${_line#*=}"
            _upper="${_key#ATLASSIAN_}"
            _upper="${_upper%_TOKEN}"
            _ws_lower=$(echo "$_upper" | tr '[:upper:]' '[:lower:]')
            _ws_url=$(printf '%s\n' "$atlassian_env_vars" | sed -n "s|^ATLASSIAN_${_upper}_JIRA_URL=||p")
            _ws_email=$(printf '%s\n' "$atlassian_env_vars" | sed -n "s|^ATLASSIAN_${_upper}_JIRA_USERNAME=||p")
            echo "     · $_ws_lower"
            echo "       URL:    $_ws_url"
            echo "       Email:  $_ws_email"
            echo "       Token:  $(_mask "$_ws_tok")"
            ;;
        esac
      done <<< "$atlassian_env_vars"
    else
      echo "  Atlassian:       disabled"
    fi
    # GitHub MCP — email + masked PAT when enabled.
    if [ "$github_enabled" = "true" ]; then
      echo "  GitHub MCP:"
      echo "     Email:            $github_email"
      echo "     PAT:              $(_mask "$github_pat")"
    else
      echo "  GitHub MCP:      disabled"
    fi
    # MCP servers — always-on defaults from catalog + opt-in selections.
    echo "  MCP servers:"
    local _mcp_default_csv
    _mcp_default_csv=$(mcp_catalog_list default | paste -sd, - | sed 's/,/, /g')
    echo "     Always-on:        $_mcp_default_csv"
    if [ "${#active_optional_mcps[@]}" -gt 0 ]; then
      local _csv_active
      _csv_active=$(printf '%s,' "${active_optional_mcps[@]}" | sed 's/,$//' | sed 's/,/, /g')
      echo "     Opt-in:           $_csv_active"
      # Show secret env vars captured for those MCPs (each masked).
      local _secret_line _secret_key _secret_val
      while IFS= read -r _secret_line; do
        [ -z "$_secret_line" ] && continue
        _secret_key="${_secret_line%%=*}"
        _secret_val="${_secret_line#*=}"
        echo "       $_secret_key:        $(_mask "$_secret_val")"
      done <<< "$mcp_secret_env_lines"
    else
      echo "     Opt-in:           (none)"
    fi
    # Plugins — always-on catalog defaults + opt-in selections.
    echo "  Plugins:"
    local _plug_default_csv
    _plug_default_csv=$(plugin_catalog_list default | paste -sd, - | sed 's/,/, /g')
    echo "     Always-on:        $_plug_default_csv"
    if [ "${#opt_plugins[@]}" -gt 0 ]; then
      local _csv_optp
      _csv_optp=$(printf '%s,' "${opt_plugins[@]}" | sed 's/,$//' | sed 's/,/, /g')
      echo "     Opt-in:           $_csv_optp"
    else
      echo "     Opt-in:           (none)"
    fi
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
          1) while true; do
                local _ed_name
                _ed_name=$(ask "Agent name (lowercase, no spaces)" "$agent_name")
                agent_name=$(normalize_agent_name "$_ed_name")
                validate_agent_name "$agent_name" && break
              done ;;
          2) agent_display=$(ask "Display name (with emoji)" "$agent_display") ;;
          3) agent_role=$(ask "Role description" "$agent_role") ;;
          4) agent_vibe=$(ask "Vibe / personality (one line)" "$agent_vibe") ;;
          5) user_name=$(ask "Your full name" "$user_name") ;;
          6) user_nick=$(ask "Nickname" "$user_nick") ;;
          7) user_tz=$(ask "Timezone" "$user_tz") ;;
          8) user_email=$(ask "Primary email" "$user_email") ;;
          9) user_lang=$(ask_choice "Preferred language" "$user_lang" "es en mixed") ;;
          10) deploy_host=$(ask "Host machine name" "$deploy_host") ;;
          11) while true; do
                local _ed_raw
                _ed_raw=$(ask "Agent destination directory" "$deploy_ws")
                deploy_ws=$(normalize_destination_path "$_ed_raw")
                validate_destination_path "$deploy_ws" && break
              done ;;
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
  # Resolve-and-record: resolve each toolchain channel to a concrete latest
  # stable version and bake it into agent.yml's docker: block (the per-agent
  # source of truth the build reads). Best-effort; offline falls back to the
  # documented floor in scripts/lib/versions.sh.
  echo "▸ Resolving latest stable toolchain versions..." >&2
  local _v_alpine _v_claude _v_uv _v_bun _v_gum
  _v_alpine=$(versions_resolve alpine) || true
  _v_claude=$(versions_resolve claude_code) || true
  _v_uv=$(versions_resolve uv) || true
  _v_bun=$(versions_resolve bun) || true
  _v_gum=$(versions_resolve gum) || true
  local docker_yaml="  image_tag: \"agentic-pod:latest\"
  uid: $(id -u)
  gid: $(id -g)
  base_image: \"alpine:${_v_alpine}\"
  claude_code_version: \"${_v_claude}\"
  uv_version: \"${_v_uv}\"
  bun_version: \"${_v_bun}\"
  gum_version: \"${_v_gum}\"
  toolchain_channels:
    claude_code: \"${AGENTIC_CHANNEL_CLAUDE_CODE}\"
    alpine: \"${AGENTIC_CHANNEL_ALPINE}\"
    uv: \"${AGENTIC_CHANNEL_UV}\"
    bun: \"${AGENTIC_CHANNEL_BUN}\"
    gum: \"${AGENTIC_CHANNEL_GUM}\""
  if [ -n "$atlassian_entries" ]; then
    atlassian_yaml="  atlassian:
$atlassian_entries"
  else
    atlassian_yaml="  atlassian: []"
  fi

  # Render mcps.defaults: catalog defaults always-on (fetch, git, filesystem)
  # + any optional MCPs the user enabled in the wizard. The list is what
  # the renderer reads to gate the .mcp.json blocks; persisting it in
  # agent.yml keeps `--regenerate` deterministic (same selections, same render).
  local mcps_defaults_yaml=""
  local _mcp_id
  while IFS= read -r _mcp_id; do
    [ -z "$_mcp_id" ] && continue
    mcps_defaults_yaml="${mcps_defaults_yaml}    - ${_mcp_id}
"
  done < <(mcp_catalog_list default)
  # Guard against `set -u` when the user picked no optional MCPs (empty array).
  if [ "${#active_optional_mcps[@]}" -gt 0 ]; then
    for _mcp_id in "${active_optional_mcps[@]}"; do
      mcps_defaults_yaml="${mcps_defaults_yaml}    - ${_mcp_id}
"
    done
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

  # Optional persona: when --role-file is set, store the workspace-relative
  # path (the file itself is copied in by scaffold_destination). The key is
  # omitted entirely when unset — schema rejects an empty role_file.
  local role_file_yaml=""
  if [ -n "$ROLE_FILE" ]; then
    role_file_yaml=$'\n'"  role_file: \"personas/${agent_name}.md\""
  fi

  # ── Write agent.yml ─────────────────────────────────
  cat > "$agent_yml" << EOF
# Generated by setup.sh (launcher v$LAUNCHER_VERSION) on $(date '+%Y-%m-%d %H:%M:%S')
# Edit this file and run ./setup.sh --regenerate to update derived files.
version: 1

meta:
  launcher_version: "$LAUNCHER_VERSION"
  scaffolded_at: "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

agent:
  name: $agent_name
  display_name: "$agent_display"
  role: "$agent_role"$role_file_yaml
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
  mode: "$deploy_mode"
  session_name: "$(_resolve_session_name "$agent_name" "$deploy_host")"

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
$mcps_defaults_yaml$atlassian_yaml
  github:
    enabled: $github_enabled
    email: "$github_email"

vault:
  enabled: $vault_enabled
  path: .state/.vault
  seed_skeleton: $vault_seed
  force_reseed: false
  initial_sources: []
  mcp:
    enabled: $vault_mcp_enabled
    server: vault
  qmd:
    enabled: $vault_qmd_enabled
    version: "2.5.3"
    schedule: "*/5 * * * *"
  schema:
    frontmatter_required: true
    log_format: "## [{date}] {op} | {title}"

$plugins_yaml
EOF

  cat > "$env_file" << EOF
# Generated by setup.sh on $(date '+%Y-%m-%d %H:%M:%S')
# NEVER commit this file.

# Claude headless auth — paste the token from 'claude setup-token' (run on host).
# Set this to boot fully operational without interactive /login.
CLAUDE_CODE_OAUTH_TOKEN=

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
  # Optional-MCP secrets collected during the wizard. Emit even when empty
  # so the variable name is visible in .env and the user can fill it later.
  [ -n "$mcp_secret_env_lines" ] && echo "$mcp_secret_env_lines" >> "$env_file"
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
      intro="Los siguientes plugins se instalan automáticamente cuando completes \`/login\` dentro del tmux. Cada uno aporta capacidades distintas — el campo \`agent.yml.plugins[]\` es la fuente de verdad y puedes editarlo a mano si quieres agregar/quitar (luego \`./setup.sh --regenerate\`)."
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

  # Deployment mode (011): NEXT_STEPS branches docker vs local. render_next_steps
  # is its own render path (not regenerate), so derive the flag here too.
  local _ns_mode
  _ns_mode=$(yq -r '.deployment.mode // "docker"' "$dest/agent.yml")
  if [ "$_ns_mode" = "local" ]; then
    export DEPLOYMENT_MODE_IS_DOCKER=false
  else
    export DEPLOYMENT_MODE_IS_DOCKER=true
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
#
# Validates that everything ended up where the Dockerfile expects. If the
# function silently broke (typo, permission, or future refactor), the user
# sees a clear error here instead of a cryptic "COPY failed: file not found"
# during `docker compose build`.
mirror_catalog_to_docker() {
  local dest="$1"
  local src_lib="$dest/scripts/lib/plugin-catalog.sh"
  local src_plugins="$dest/modules/plugins"
  local src_vault_lib="$dest/scripts/lib/vault.sh"
  local src_vault_skel="$dest/modules/vault-skeleton"
  local src_mcp_lib="$dest/scripts/lib/mcp-catalog.sh"
  local src_mcps="$dest/modules/mcps"
  # feature 012: qmd/backup libs are canonical host-side (scripts/lib, scripts)
  # and mirrored into docker/ so the Dockerfile COPY still finds them.
  local src_qmd_index="$dest/scripts/lib/qmd_index.sh"
  local src_backup_vault="$dest/scripts/lib/backup_vault.sh"
  local src_qmd_watch="$dest/scripts/qmd_watch.sh"
  # feature 014: the wiki-graph runner lib + the schema-delta dir for the additive
  # upgrade, mirrored so the Dockerfile COPY finds them.
  local src_wiki_graph="$dest/scripts/lib/wiki_graph.sh"
  local src_vault_deltas="$dest/modules/vault-deltas"
  # feature 015: shared observability helper (redact + host-backed scratch),
  # sourced by qmd_index.sh and wiki_graph.sh — mirrored so the image finds it.
  local src_rag_obs="$dest/scripts/lib/rag_obs.sh"
  [ -f "$src_lib" ] || return 0
  [ -d "$src_plugins" ] || return 0
  mkdir -p "$dest/docker/scripts/lib" "$dest/docker/modules"
  cp "$src_lib" "$dest/docker/scripts/lib/plugin-catalog.sh"
  rm -rf "$dest/docker/modules/plugins"
  cp -R "$src_plugins" "$dest/docker/modules/plugins"
  if [ -f "$src_vault_lib" ]; then
    cp "$src_vault_lib" "$dest/docker/scripts/lib/vault.sh"
  fi
  if [ -f "$src_qmd_index" ]; then
    cp "$src_qmd_index" "$dest/docker/scripts/lib/qmd_index.sh"
  fi
  if [ -f "$src_backup_vault" ]; then
    cp "$src_backup_vault" "$dest/docker/scripts/lib/backup_vault.sh"
  fi
  if [ -f "$src_wiki_graph" ]; then
    cp "$src_wiki_graph" "$dest/docker/scripts/lib/wiki_graph.sh"
  fi
  if [ -f "$src_rag_obs" ]; then
    cp "$src_rag_obs" "$dest/docker/scripts/lib/rag_obs.sh"
  fi
  if [ -d "$src_vault_deltas" ]; then
    rm -rf "$dest/docker/modules/vault-deltas"
    cp -R "$src_vault_deltas" "$dest/docker/modules/vault-deltas"
  fi
  if [ -f "$src_qmd_watch" ]; then
    cp "$src_qmd_watch" "$dest/docker/scripts/qmd_watch.sh"
  fi
  if [ -d "$src_vault_skel" ]; then
    rm -rf "$dest/docker/modules/vault-skeleton"
    cp -R "$src_vault_skel" "$dest/docker/modules/vault-skeleton"
  fi
  if [ -f "$src_mcp_lib" ]; then
    cp "$src_mcp_lib" "$dest/docker/scripts/lib/mcp-catalog.sh"
  fi
  if [ -d "$src_mcps" ]; then
    rm -rf "$dest/docker/modules/mcps"
    cp -R "$src_mcps" "$dest/docker/modules/mcps"
  fi

  # Post-mirror validation. Each entry below is required by the Dockerfile;
  # missing any of them means the build will fail later with a less-clear
  # error. Surface it here, with paths.
  local missing=""
  [ -f "$dest/docker/scripts/lib/plugin-catalog.sh" ] \
    || missing="${missing}\n  - docker/scripts/lib/plugin-catalog.sh"
  [ -f "$dest/docker/scripts/lib/vault.sh" ] \
    || missing="${missing}\n  - docker/scripts/lib/vault.sh"
  [ -f "$dest/docker/scripts/lib/qmd_index.sh" ] \
    || missing="${missing}\n  - docker/scripts/lib/qmd_index.sh"
  [ -f "$dest/docker/scripts/lib/rag_obs.sh" ] \
    || missing="${missing}\n  - docker/scripts/lib/rag_obs.sh"
  [ -f "$dest/docker/scripts/lib/wiki_graph.sh" ] \
    || missing="${missing}\n  - docker/scripts/lib/wiki_graph.sh"
  [ -f "$dest/docker/scripts/lib/backup_vault.sh" ] \
    || missing="${missing}\n  - docker/scripts/lib/backup_vault.sh"
  [ -f "$dest/docker/scripts/qmd_watch.sh" ] \
    || missing="${missing}\n  - docker/scripts/qmd_watch.sh"
  [ -f "$dest/docker/scripts/lib/mcp-catalog.sh" ] \
    || missing="${missing}\n  - docker/scripts/lib/mcp-catalog.sh"
  if [ ! -d "$dest/docker/modules/plugins" ] \
    || [ -z "$(ls -A "$dest/docker/modules/plugins" 2>/dev/null)" ]; then
    missing="${missing}\n  - docker/modules/plugins/ (empty or missing)"
  fi
  if [ ! -d "$dest/docker/modules/mcps" ] \
    || [ -z "$(ls -A "$dest/docker/modules/mcps" 2>/dev/null)" ]; then
    missing="${missing}\n  - docker/modules/mcps/ (empty or missing)"
  fi
  [ -f "$dest/docker/modules/vault-skeleton/CLAUDE.md" ] \
    || missing="${missing}\n  - docker/modules/vault-skeleton/CLAUDE.md"
  if [ -n "$missing" ]; then
    echo "ERROR: mirror_catalog_to_docker did not populate everything required by the Dockerfile:" >&2
    printf '%b\n' "$missing" >&2
    echo "" >&2
    echo "If this is a fresh clone of the launcher, run from the launcher root:" >&2
    echo "  ./setup.sh --regenerate" >&2
    echo "Otherwise, check that scripts/lib/{plugin-catalog,vault,mcp-catalog}.sh and modules/{plugins,mcps,vault-skeleton}/ exist." >&2
    return 1
  fi
}

# Clone a single backup branch into a tmp dir. STDOUT: tmp dir path on
# success, empty on missing-branch (treated as a normal "fresh install"
# state by callers — they decide whether to warn).
_restore_clone_branch() {
  local fork_url="$1" branch="$2"
  local tmp
  tmp=$(mktemp -d)
  if ! git clone --branch "$branch" --single-branch --depth 1 \
         "$fork_url" "$tmp" >/dev/null 2>&1; then
    rm -rf "$tmp"
    return 1
  fi
  printf '%s\n' "$tmp"
}

# Decrypt $1 (.env.age) into $2 (.env path) using whichever SSH key works.
# RESTORE_IDENTITY_KEY override is tried first; otherwise the standard pair.
_restore_decrypt_env() {
  local age_in="$1" env_out="$2"
  [ -f "$age_in" ] || return 0
  local identity_files=(
    "${RESTORE_IDENTITY_KEY:-}"
    "$HOME/.ssh/id_ed25519"
    "$HOME/.ssh/id_rsa"
  )
  local idfile
  for idfile in "${identity_files[@]}"; do
    [ -z "$idfile" ] && continue
    [ -f "$idfile" ] || continue
    if age -d -i "$idfile" -o "$env_out" "$age_in" 2>/dev/null; then
      echo "  ✓ restore: decrypted .env with $idfile"
      return 0
    fi
  done
  echo "  ⚠ restore: .env.age present but could not decrypt — pass --identity-key <path> or regenerate .env via wizard"
  return 0
}

# Restore from the agent's fork by pulling the three backup branches in
# order: config (agent.yml) first so vault.path is known, then identity
# (login + pairing + plugins + .env.age), then vault (markdown). Each
# branch is independently optional — missing branches log a clear notice
# and continue, supporting partial-state forks too.
restore_from_fork() {
  local fork_url="$1"
  local dest="$2"

  mkdir -p "$dest/.state/.claude"

  # 1. Config — agent.yml lands at workspace root.
  local cfg_tmp
  if cfg_tmp=$(_restore_clone_branch "$fork_url" "backup/config"); then
    if [ -f "$cfg_tmp/agent.yml" ]; then
      cp -a "$cfg_tmp/agent.yml" "$dest/agent.yml"
      echo "  ✓ restore: agent.yml restored from backup/config"
    fi
    rm -rf "$cfg_tmp"
  else
    echo "  ⚠ restore: no backup/config branch — keeping any existing agent.yml at $dest"
  fi

  # 2. Identity — .claude/* + optional .env.age decrypt.
  local id_tmp
  if id_tmp=$(_restore_clone_branch "$fork_url" "backup/identity"); then
    [ -f "$id_tmp/.claude.json" ] && cp -a "$id_tmp/.claude.json" "$dest/.state/.claude.json"
    if [ -d "$id_tmp/.claude" ]; then
      cp -a "$id_tmp/.claude/." "$dest/.state/.claude/"
    fi
    _restore_decrypt_env "$id_tmp/.env.age" "$dest/.env"
    echo "  ✓ restore: identity restored into $dest/.state/"
    rm -rf "$id_tmp"
  else
    echo "  ⚠ restore: no backup/identity branch at $fork_url — skipping (fresh install)"
  fi

  # 3. Vault — markdown subset, target dir resolved from the freshly
  #    restored agent.yml's vault.path (default .state/.vault).
  local vault_tmp vault_path
  if vault_tmp=$(_restore_clone_branch "$fork_url" "backup/vault"); then
    if [ -f "$dest/agent.yml" ]; then
      vault_path=$(yq -r '.vault.path // ".state/.vault"' "$dest/agent.yml" 2>/dev/null)
    else
      vault_path=".state/.vault"
    fi
    [ "$vault_path" = "null" ] && vault_path=".state/.vault"
    mkdir -p "$dest/$vault_path"
    # Copy the markdown tree without dot-files that don't exist in the
    # branch anyway (the vault backup stages only *.md files).
    if [ -n "$(ls -A "$vault_tmp" 2>/dev/null)" ]; then
      ( cd "$vault_tmp" && find . -type f -name '*.md' -print0 \
          | while IFS= read -r -d '' f; do
              local rel="${f#./}"
              mkdir -p "$dest/$vault_path/$(dirname "$rel")"
              cp -a "$f" "$dest/$vault_path/$rel"
            done
      )
    fi
    echo "  ✓ restore: vault restored into $dest/$vault_path/"
    rm -rf "$vault_tmp"
  else
    echo "  ⚠ restore: no backup/vault branch — keeping any existing vault at $dest"
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

  # Deployment mode (011): scaffold runs BEFORE regenerate exports DEPLOYMENT_MODE,
  # so read it straight from agent.yml. Local mode ships NO Docker build context.
  local _scaffold_mode
  _scaffold_mode=$(yq -r '.deployment.mode // "docker"' "$agent_yml")

  if [ "$IN_PLACE" = true ]; then
    echo "▸ --in-place mode: skipping destination scaffold"
    return 0
  fi

  if [ "$dest" = "$src_dir" ]; then
    echo "▸ Destination equals current directory: running in-place"
    return 0
  fi

  # Fail-loud backstop: a hand-edited agent.yml (the regenerate/restore paths
  # read the workspace directly) could carry a malformed destination —
  # relative, an embedded ~, or '..'. The wizard validates at input time; this
  # guards the paths that bypass it.
  if ! validate_destination_path "$dest"; then
    echo "ERROR: deployment.workspace in agent.yml is not a valid destination: $dest" >&2
    exit 1
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
    echo "" >&2
    echo "  Choose a different path with --destination, OR remove the existing one:" >&2
    echo "    rm -rf \"$dest\"" >&2
    echo "" >&2
    echo "  If that path has a running agent, stop it first:" >&2
    echo "    cd \"$dest\" && docker compose down -v" >&2
    exit 1
  fi

  echo ""
  echo "▸ Scaffolding destination: $dest"
  mkdir -p "$dest"

  # Copy system files (installer → destination). VERSION ships with the
  # launcher and must reach the dest so `--regenerate` from inside the
  # workspace can stamp meta.launcher_version against the same value
  # the wizard used during scaffold.
  local item
  for item in setup.sh VERSION .gitignore LICENSE; do
    [ -e "$src_dir/$item" ] && cp "$src_dir/$item" "$dest/"
  done
  for item in modules scripts docker; do
    # Local mode has no Docker build context — don't carry the docker/ tree.
    [ "$item" = "docker" ] && [ "$_scaffold_mode" = "local" ] && continue
    [ -d "$src_dir/$item" ] && cp -R "$src_dir/$item" "$dest/"
  done
  # Story I: copy the --role-file persona into the workspace so it travels
  # with clone / backup / --restore-from-fork (FR-I2). agent.yml stores the
  # workspace-relative path personas/<name>.md that render.sh re-reads.
  if [ -n "$ROLE_FILE" ] && [ -f "$ROLE_FILE" ]; then
    local _aname
    _aname=$(yq '.agent.name' "$agent_yml")
    mkdir -p "$dest/personas"
    cp "$ROLE_FILE" "$dest/personas/${_aname}.md"
  fi
  # Ensure setup.sh is executable
  chmod +x "$dest/setup.sh"
  find "$dest/scripts" -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true
  # Host-side CLIs without a .sh suffix that ship in scripts/ — agentctl is
  # the wrapper for `docker exec -u agent NAME ...` patterns. Keep this list
  # explicit (one chmod per binary-style script) so a missed git filemode
  # doesn't leave the workspace with a non-executable wrapper.
  [ -f "$dest/scripts/agentctl" ] && chmod +x "$dest/scripts/agentctl"
  if [ -d "$dest/docker" ]; then
    find "$dest/docker" -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true
  fi

  # Mirror catalog files into docker/ build context. Source-of-truth lives
  # at scripts/lib/plugin-catalog.sh + modules/plugins/. The Dockerfile's
  # build context is ./docker/, so it cannot COPY from outside that tree
  # — we duplicate inside it. Refreshed on every regenerate. Skipped for
  # local mode (no Docker build context).
  if [ "$_scaffold_mode" != "local" ]; then
    mirror_catalog_to_docker "$dest"
  fi

  # Pre-create .state/ — bind-mounted to /home/agent inside the container.
  # Host-owner (current user) matches the agent user's UID/GID via the
  # Dockerfile build args, so the bind-mount shows up agent-owned inside
  # without any runtime chown dance.
  mkdir -p "$dest/.state"

  # Pre-create scripts/heartbeat/logs/ for the same reason. The container's
  # entrypoint runs as root with cap_drop: ALL (only CHOWN/SETUID/SETGID
  # granted, no DAC_OVERRIDE). Without DAC_OVERRIDE, root inside cannot
  # mkdir into /workspace/scripts/heartbeat/ (host-owned 1000:1000, mode 775
  # → "other" is r-x for non-owner non-group root). Creating logs/ here on
  # the host means the entrypoint's `mkdir -p` is a no-op and the container
  # boots cleanly instead of restart-looping with EACCES.
  mkdir -p "$dest/scripts/heartbeat/logs"

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

  # Configure identity backup recipient (non-fatal — graceful fallback if
  # the owner has no SSH key on GitHub).
  configure_identity_backup "$dest/agent.yml" || true

  # Optional: restore from an existing fork's backup/identity branch
  if [ -n "${RESTORE_FORK_URL:-}" ]; then
    echo ""
    echo "▸ Restoring identity from $RESTORE_FORK_URL..."
    restore_from_fork "$RESTORE_FORK_URL" "$dest"
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

  # Bump meta.launcher_version + meta.regenerated_at so doctor can show
  # what's running today vs. what scaffolded the workspace. Legacy agents
  # (scaffolded before VERSION was introduced) get the meta block on their
  # first regenerate; their original scaffolded_at is unrecoverable, so we
  # leave that field unset rather than guessing.
  if [ -f "$agent_yml" ]; then
    local _now
    _now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    yq -i ".meta.launcher_version = \"$LAUNCHER_VERSION\"" "$agent_yml"
    yq -i ".meta.regenerated_at = \"$_now\"" "$agent_yml"

    # Backfill missing toolchain versions for legacy agents (scaffolded
    # before this feature). Only MISSING fields are filled, so a plain
    # --regenerate stays deterministic (existing recorded versions are left
    # untouched; moving them forward is the explicit `agentctl versions
    # --upgrade`). Best-effort; offline falls back to the documented floor.
    local _comp _existing _resolved
    for _comp in claude_code uv bun gum; do
      _existing=$(yq -r ".docker.${_comp}_version // \"\"" "$agent_yml")
      if [ -z "$_existing" ] || [ "$_existing" = "null" ]; then
        _resolved=$(versions_resolve "$_comp") || true
        [ -n "$_resolved" ] && yq -i ".docker.${_comp}_version = \"$_resolved\"" "$agent_yml"
      fi
    done
    local _base
    _base=$(yq -r '.docker.base_image // ""' "$agent_yml")
    if [ -z "$_base" ] || [ "$_base" = "null" ]; then
      local _a; _a=$(versions_resolve alpine) || true
      [ -n "$_a" ] && yq -i ".docker.base_image = \"alpine:$_a\"" "$agent_yml"
    fi

    # Backfill vault.qmd.version for a pre-010 workspace that opted into QMD
    # before the pin existed (enabled=true, no version). modules/mcp-json.tpl
    # renders `@tobilu/qmd@{{VAULT_QMD_VERSION}}` with no inline default, so an
    # absent key would render a broken `@tobilu/qmd@`. Writing the floor into
    # agent.yml keeps it the single source of truth (Principle I) and makes the
    # rendered pin valid (contracts/agent-yml-schema.md). The 2.5.3 floor mirrors
    # qmd_index.sh::qmd_pkg's runtime default — keep the two in sync.
    local _qmd_en _qmd_ver
    _qmd_en=$(yq -r '.vault.qmd.enabled // false' "$agent_yml")
    if [ "$_qmd_en" = "true" ]; then
      _qmd_ver=$(yq -r '.vault.qmd.version // ""' "$agent_yml")
      if [ -z "$_qmd_ver" ] || [ "$_qmd_ver" = "null" ]; then
        yq -i '.vault.qmd.version = "2.5.3"' "$agent_yml"
      fi
    fi

    # Backfill deployment.mode for a pre-011 workspace (no mode key = docker by
    # design). Writing the explicit default keeps agent.yml the single source of
    # truth (Principle I) and makes the docker-vs-local branch deterministic on
    # every regenerate. An existing value (docker|local) is left untouched.
    local _dep_mode
    _dep_mode=$(yq -r '.deployment.mode // ""' "$agent_yml")
    if [ -z "$_dep_mode" ] || [ "$_dep_mode" = "null" ]; then
      yq -i '.deployment.mode = "docker"' "$agent_yml"
    fi

    # 022 (US3/FR-012/FR-015): backfill deployment.session_name for a pre-022
    # workspace so it resolves EXACTLY like a fresh scaffold. Persisting it (as
    # opposed to recomputing it on every render) is what makes the name editable
    # by hand, survivable across --regenerate, and independent of the hostname of
    # whatever machine happens to run the render (Principle I). An existing value
    # — default or operator-chosen — is never touched, which is what makes a
    # second --regenerate a byte-for-byte no-op.
    #
    # Must stay INSIDE this `[ -f "$agent_yml" ]` block and BEFORE the
    # render_load_context below, or the value would not reach this same pass.
    local _sess_name _sess_host _sess_agent
    _sess_name=$(yq -r '.deployment.session_name // ""' "$agent_yml")
    if [ -z "$_sess_name" ] || [ "$_sess_name" = "null" ]; then
      _sess_host=$(yq -r '.deployment.host // ""' "$agent_yml")
      _sess_agent=$(yq -r '.agent.name // ""' "$agent_yml")
      if [ -n "$_sess_agent" ] && [ "$_sess_agent" != "null" ]; then
        yq -i ".deployment.session_name = \"$(_resolve_session_name "$_sess_agent" "$_sess_host")\"" "$agent_yml"
      fi
    fi
  fi

  echo "▸ Loading context from agent.yml"
  render_load_context "$agent_yml"

  # Deployment mode (011): single source of truth in agent.yml. Default docker
  # (legacy + backfill above). DEPLOYMENT_MODE_IS_DOCKER gates the {{#if}} /
  # {{#unless}} blocks in the templates and the docker-vs-local render branch.
  export DEPLOYMENT_MODE
  DEPLOYMENT_MODE="$(yq -r '.deployment.mode // "docker"' "$agent_yml")"
  if [ "$DEPLOYMENT_MODE" = "local" ]; then
    export DEPLOYMENT_MODE_IS_DOCKER=false
  else
    export DEPLOYMENT_MODE_IS_DOCKER=true
  fi

  # feature 012: absolute vault dir in the workspace, for the local vault/qmd
  # entrypoints (US2/US3). Docker mode ignores it.
  export LOCAL_VAULT_DIR
  LOCAL_VAULT_DIR="$SCRIPT_DIR/$(yq -r '.vault.path // ".state/.vault"' "$agent_yml")"
  # Mode-resolved vault path for the vault MCP arg in mcp-json.tpl. The render
  # engine does NOT support a mode {{#if}} nested inside the {{#if VAULT_MCP_ENABLED}}
  # block, so we precompute the resolved path here (template stays dumb). Docker
  # keeps its byte-identical /home/agent/.vault (the pre-existing quirk: docker
  # does not template vault.path in the MCP); local resolves under the workspace.
  export VAULT_MCP_PATH GCAL_CREDS_PATH
  if [ "$DEPLOYMENT_MODE_IS_DOCKER" = true ]; then
    VAULT_MCP_PATH="/home/agent/.vault"
    GCAL_CREDS_PATH="/home/agent/.gcal/gcp-oauth.keys.json"
  else
    VAULT_MCP_PATH="$LOCAL_VAULT_DIR"
    # google-calendar creds live under .state (durable, workspace-local) — same
    # rebase rule as the vault; /home/agent/.gcal doesn't exist on the host.
    GCAL_CREDS_PATH="$SCRIPT_DIR/.state/.gcal/gcp-oauth.keys.json"
  fi
  # 013 (RC1/FR-001): the qmd MCP server (the READER) must resolve the SAME index
  # storage as the reindex writer. The qmd binary honors XDG_CACHE_HOME +
  # QMD_CONFIG_DIR (verified against the 2.5.3 tarball) — not QMD_CACHE_HOME. We
  # precompute the env object per mode (the render engine can't nest a mode
  # {{#if}} inside {{#if VAULT_QMD_ENABLED}}) and render it as `"env": {{QMD_MCP_ENV}}`.
  # Docker emits exactly `{}` → byte-identical to v0.6.0. Fixing only the writer
  # (not this) would leave the MCP reading ~operator/.cache/qmd where qmd
  # auto-creates a silently EMPTY sqlite → RAG permanently blank, no error.
  export QMD_MCP_ENV
  if [ "$DEPLOYMENT_MODE_IS_DOCKER" = true ]; then
    QMD_MCP_ENV="{}"
  else
    QMD_MCP_ENV="{\"XDG_CACHE_HOME\": \"$SCRIPT_DIR/.state/.cache\", \"QMD_CONFIG_DIR\": \"$SCRIPT_DIR/.state/.config/qmd\"}"
  fi
  # 016 (T036): the qmd MCP server (the READER Claude uses to search) must launch
  # from the SAME managed bun-install prefix as the reindex — via a wrapper that
  # reuses qmd_index.sh::qmd_mcp_exec — NOT `bunx`, which recompiles tree-sitter
  # and aborts on Alpine musl (BUG 4). Precomputed per mode (same no-nested-{{#if}}
  # constraint as the env). Docker: the image-baked wrapper. Local: the rendered
  # workspace wrapper (which also fixes PATH + QMD_CACHE_HOME so its prefix matches
  # the reindex writer's — the .mcp.json env only carries XDG_CACHE_HOME).
  export QMD_MCP_COMMAND
  if [ "$DEPLOYMENT_MODE_IS_DOCKER" = true ]; then
    QMD_MCP_COMMAND="/opt/agent-admin/scripts/qmd-mcp"
  else
    QMD_MCP_COMMAND="$SCRIPT_DIR/scripts/local/agent-qmd-mcp.sh"
  fi
  # 012 (FR-012): systemd OnCalendar for the local qmd/backup timers, converted
  # from the cron schedules in agent.yml (single source). Unsupported cron forms
  # fall back to the feature defaults + a warning (cron_to_systemd_calendar).
  export QMD_TIMER_ONCALENDAR BACKUP_TIMER_ONCALENDAR
  # 013 (FR-013/D10): capture the OnCalendar AND the CRON_FALLBACK signal from the
  # SAME subshell — command substitution runs in a subshell, so the global set
  # inside cron_to_systemd_calendar would be lost otherwise. The function prints
  # the OnCalendar on line 1; we append the flag and split. Comparing stdout to
  # the default is ambiguous ("*/5 * * * *" converts exactly to the default), so
  # the explicit flag is the only reliable signal.
  local _qmd_sched _qmd_sched_raw _qmd_fallback
  _qmd_sched="$(yq -r '.vault.qmd.schedule // ""' "$agent_yml")"
  _qmd_sched_raw="$(cron_to_systemd_calendar "$_qmd_sched" '*-*-* *:0/5:00'; printf 'FALLBACK=%s' "$CRON_FALLBACK")"
  QMD_TIMER_ONCALENDAR="${_qmd_sched_raw%%$'\n'FALLBACK=*}"
  _qmd_fallback="${_qmd_sched_raw##*FALLBACK=}"
  BACKUP_TIMER_ONCALENDAR="$(cron_to_systemd_calendar "$(yq -r '.vault.backup_schedule // ""' "$agent_yml")" '*-*-* *:00:00')"

  # 013 (FR-013/D10): persist a consultable marker when the qmd schedule fell back
  # to the default (a non-convertible custom cron), so status/doctor can report it
  # instead of a warning that scrolled past in the regenerate output. Docker mode
  # removes it unconditionally (a local→docker mode switch must not leave the
  # marker orphaned — analyze C1). Derived purely by --regenerate (Principle I).
  local _qmd_fallback_marker="$SCRIPT_DIR/scripts/heartbeat/qmd-schedule.fallback"
  if [ "$DEPLOYMENT_MODE_IS_DOCKER" = false ] && [ "${_qmd_fallback:-0}" = 1 ]; then
    mkdir -p "$(dirname "$_qmd_fallback_marker")" 2>/dev/null || true
    {
      printf 'original=%s\n' "$_qmd_sched"
      printf 'applied=%s\n' "$QMD_TIMER_ONCALENDAR"
      printf 'at=%s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    } > "$_qmd_fallback_marker" 2>/dev/null || true
  else
    rm -f "$_qmd_fallback_marker" 2>/dev/null || true
  fi

  # 014 (FR-012/D4): wiki-graph runner enable flag + schedule + local OnCalendar.
  # enabled: default-true when the vault is on; only an explicit `false` disables.
  # schedule default 20 */6 * * * — offset :20 to dodge the vault-backup :00 and
  # identity/config 03:30 estampida (research R11). The default value lives HERE
  # (analyze M7: schema.sh only validates shape), plus yq `//` fallbacks below.
  export WIKI_GRAPH_ENABLED WIKI_GRAPH_SCHEDULE WIKI_GRAPH_TIMER_ONCALENDAR
  local _wg_en_raw
  _wg_en_raw="$(yq -r '.vault.wiki_graph.enabled' "$agent_yml" 2>/dev/null)"
  if [ "${VAULT_ENABLED:-false}" = true ] && [ "$_wg_en_raw" != false ]; then
    WIKI_GRAPH_ENABLED=true
  else
    WIKI_GRAPH_ENABLED=false
  fi
  WIKI_GRAPH_SCHEDULE="$(yq -r '.vault.wiki_graph.schedule // "20 */6 * * *"' "$agent_yml")"
  { [ -z "$WIKI_GRAPH_SCHEDULE" ] || [ "$WIKI_GRAPH_SCHEDULE" = null ]; } && WIKI_GRAPH_SCHEDULE="20 */6 * * *"
  local _wg_sched_raw _wg_fallback
  _wg_sched_raw="$(cron_to_systemd_calendar "$WIKI_GRAPH_SCHEDULE" '*-*-* 0/6:20:00'; printf 'FALLBACK=%s' "$CRON_FALLBACK")"
  WIKI_GRAPH_TIMER_ONCALENDAR="${_wg_sched_raw%%$'\n'FALLBACK=*}"
  _wg_fallback="${_wg_sched_raw##*FALLBACK=}"
  local _wg_fallback_marker="$SCRIPT_DIR/scripts/heartbeat/wiki-graph-schedule.fallback"
  if [ "$DEPLOYMENT_MODE_IS_DOCKER" = false ] && [ "${_wg_fallback:-0}" = 1 ]; then
    mkdir -p "$(dirname "$_wg_fallback_marker")" 2>/dev/null || true
    {
      printf 'original=%s\n' "$WIKI_GRAPH_SCHEDULE"
      printf 'applied=%s\n' "$WIKI_GRAPH_TIMER_ONCALENDAR"
      printf 'at=%s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    } > "$_wg_fallback_marker" 2>/dev/null || true
  else
    rm -f "$_wg_fallback_marker" 2>/dev/null || true
  fi

  # Mode-switch warning (FR-005a): detect a prior generation in the OTHER mode by
  # its on-disk artifacts and warn that they are now orphaned — WITHOUT deleting
  # them (safe + traceable; the user removes them deliberately).
  if [ "$DEPLOYMENT_MODE_IS_DOCKER" = true ] && [ -d "$SCRIPT_DIR/scripts/local" ]; then
    echo ""
    echo "WARNING: switching to docker mode — these LOCAL-mode artifacts are now"
    echo "         orphaned and were NOT deleted:"
    echo "           - scripts/local/ (login, healthcheck, kill-switch helpers)"
    echo "         A previously installed systemd unit (agent-${AGENT_NAME}.service)"
    echo "         is also left in place; remove it with 'systemctl disable --now"
    echo "         agent-${AGENT_NAME}.service' if you no longer want it."
    echo ""
  elif [ "$DEPLOYMENT_MODE_IS_DOCKER" != true ] && [ -f "$SCRIPT_DIR/docker-compose.yml" ]; then
    echo ""
    echo "WARNING: switching to local mode — these DOCKER-mode artifacts are now"
    echo "         orphaned and were NOT deleted:"
    echo "           - docker-compose.yml"
    echo "           - docker/ (build context + mirrored plugin catalog)"
    echo "         Remove them manually if you no longer want the docker setup."
    echo ""
  fi

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

  # Derive MCPS_<ID>_ENABLED env vars from agent.yml.mcps.defaults so the
  # mcp-json.tpl `{{#if}}` blocks fire correctly under `--regenerate` (which
  # arrives here without the wizard's exports). Always-on MCPs (fetch, git,
  # filesystem) are hardcoded in the template — these env vars only gate
  # the optional ones (playwright, time, firecrawl, google-calendar, aws,
  # tree-sitter).
  local _regen_mcp_id _regen_envvar
  while IFS= read -r _regen_mcp_id; do
    [ -z "$_regen_mcp_id" ] && continue
    _regen_envvar=$(mcp_catalog_id_to_envvar "$_regen_mcp_id")
    eval "export ${_regen_envvar}=true"
  done < <(yq -r '.mcps.defaults[]?' "$agent_yml" 2>/dev/null)
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

  # Docker-only artifacts (011): the compose file + the mirrored build context
  # are rendered ONLY in docker mode. Local mode skips them entirely (no Docker)
  # — this is the branch that keeps docker mode byte-identical (SC-002) while
  # local mode produces zero Docker files.
  if [ "$DEPLOYMENT_MODE_IS_DOCKER" = true ]; then
    # Render docker-compose.yml
    render_to_file "$modules_dir/docker-compose.yml.tpl" "$SCRIPT_DIR/docker-compose.yml"
    echo "  ✓ docker-compose.yml"

    # Mirror plugin catalog into docker/ build context. Picks up descriptor
    # changes (modules/plugins/<id>.yml) on every regenerate so the next
    # `docker compose build` bakes the latest set into the image.
    mirror_catalog_to_docker "$SCRIPT_DIR"
    echo "  ✓ docker/scripts/lib/plugin-catalog.sh + docker/modules/plugins/"
  fi

  # heartbeat.conf
  if [ "${FEATURES_HEARTBEAT_ENABLED:-false}" = "true" ]; then
    render_to_file "$modules_dir/heartbeat-conf.tpl" "$SCRIPT_DIR/scripts/heartbeat/heartbeat.conf"
    echo "  ✓ scripts/heartbeat/heartbeat.conf"
  fi

  # Ensure logs/ exists on the host so the container entrypoint's
  # `mkdir -p` is a no-op (see scaffold_destination for the full reason).
  # Unconditional and idempotent — covers `--regenerate` on workspaces
  # scaffolded before this fix.
  [ -d "$SCRIPT_DIR/scripts/heartbeat" ] && mkdir -p "$SCRIPT_DIR/scripts/heartbeat/logs"

  # Local-mode artifacts (011): rendered ONLY when mode=local. The systemd unit
  # itself is installed by install_service (it needs sudo for a system unit);
  # here we render the workspace-side pieces (EnvironmentFile + login/kill-switch
  # helpers). The healthcheck is added by US3.
  if [ "$DEPLOYMENT_MODE_IS_DOCKER" != true ]; then
    if ! _export_local_context; then
      echo "" >&2
      echo "✗ Regeneration aborted: unresolved Claude CLI (see error above)." >&2
      return 1
    fi
    # US1/Principle I: persist the resolved absolute path so future headless
    # regenerates never re-derive a bare literal.
    _persist_claude_cli "$agent_yml" "$CLAUDE_BIN"
    render_to_file "$modules_dir/remote-control.env.tpl"   "$SCRIPT_DIR/.state/remote-control.env"
    chmod 0640 "$SCRIPT_DIR/.state/remote-control.env" 2>/dev/null || true
    render_to_file "$modules_dir/local-login.sh.tpl"       "$SCRIPT_DIR/scripts/local/agent-login.sh"
    render_to_file "$modules_dir/local-killswitch.sh.tpl"  "$SCRIPT_DIR/scripts/local/agent-killswitch.sh"
    render_to_file "$modules_dir/local-healthcheck.sh.tpl" "$SCRIPT_DIR/scripts/local/agent-healthcheck.sh"
    render_to_file "$modules_dir/local-secret-check.sh.tpl" "$SCRIPT_DIR/scripts/local/agent-secret-check.sh"
    # 022 (US1): the session-pointer hygiene pair. agent-session-exit.sh runs as
    # ExecStopPost and records WHY the process stopped; agent-session-check.sh
    # runs as the second ExecStartPre and retires a pointer that names a session
    # which already ended. Both always exit 0.
    render_to_file "$modules_dir/local-session-exit.sh.tpl"  "$SCRIPT_DIR/scripts/local/agent-session-exit.sh"
    render_to_file "$modules_dir/local-session-check.sh.tpl" "$SCRIPT_DIR/scripts/local/agent-session-check.sh"
    render_to_file "$modules_dir/local-bootstrap.sh.tpl"   "$SCRIPT_DIR/scripts/local/agent-bootstrap.sh"
    # US2 (FR-004/005/006): QMD reindex entrypoint + watcher wrapper, rendered
    # only when qmd is enabled. Their systemd units are installed by install_service.
    if [ "$(yq -r '.vault.qmd.enabled // false' "$agent_yml")" = "true" ]; then
      render_to_file "$modules_dir/local-qmd-reindex.sh.tpl" "$SCRIPT_DIR/scripts/local/agent-qmd-reindex.sh"
      render_to_file "$modules_dir/local-qmd-watch.sh.tpl"   "$SCRIPT_DIR/scripts/local/agent-qmd-watch.sh"
      # 016 (T036): the qmd MCP server wrapper — Claude's search READER launches
      # from the managed prefix via this, not `bunx` (.mcp.json → QMD_MCP_COMMAND).
      render_to_file "$modules_dir/local-qmd-mcp.sh.tpl"     "$SCRIPT_DIR/scripts/local/agent-qmd-mcp.sh"
    fi
    # US3 (FR-007): vault backup entrypoint, rendered when vault is enabled.
    if [ "$(yq -r '.vault.enabled // false' "$agent_yml")" = "true" ]; then
      render_to_file "$modules_dir/local-vault-backup.sh.tpl" "$SCRIPT_DIR/scripts/local/agent-vault-backup.sh"
      # 014 (FR-012/013): wiki-graph runner entrypoint — default-on when the vault
      # is on (opt out via vault.wiki_graph.enabled=false, i.e. WIKI_GRAPH_ENABLED).
      if [ "${WIKI_GRAPH_ENABLED:-false}" = "true" ]; then
        render_to_file "$modules_dir/local-wiki-graph.sh.tpl" "$SCRIPT_DIR/scripts/local/agent-wiki-graph.sh"
      fi
    fi
    chmod +x "$SCRIPT_DIR"/scripts/local/*.sh 2>/dev/null || true
    echo "  ✓ local artifacts (.state/remote-control.env, scripts/local/)"
    # US1/FR-001: seed the vault skeleton host-side (docker seeds at container
    # boot; local has no boot, so we do it here). Closes 011's FR-004 gap.
    _seed_vault_local "$agent_yml"
  fi

  if [ "${DEPLOYMENT_INSTALL_SERVICE:-false}" = "true" ]; then
    install_service "$agent_name" "$workspace"
  fi

  # 013 (D13/analyze G3): in local mode, if QMD is enabled but the operator
  # declined to install the systemd service, the RAG has NO automatic trigger —
  # the reindex timer + watcher aren't installed, so the index never builds or
  # refreshes on its own. Warn explicitly instead of degrading silently.
  if [ "$DEPLOYMENT_MODE_IS_DOCKER" = false ] \
     && [ "${VAULT_QMD_ENABLED:-false}" = "true" ] \
     && [ "${DEPLOYMENT_INSTALL_SERVICE:-false}" != "true" ]; then
    echo ""
    echo "WARNING: QMD (RAG) is enabled but the systemd service was not installed."
    echo "         The reindex timer + watcher won't run, so the index will not build"
    echo "         or refresh automatically. Install later with: ./setup.sh --login"
    echo "         (or run ./scripts/local/agent-qmd-reindex.sh --setup-only by hand)."
  fi

  echo ""
  echo "✓ Regeneration complete."
  maybe_print_plugin_hints
}

# Resolve operator/host context for local-mode render placeholders. In local
# mode the identity is the CURRENT login user (D6), and these values are derived
# on the target host at render time (Principle I) — re-resolved on --regenerate.
# Idempotent; safe to call more than once.
# Seed the vault skeleton into the workspace for local mode (US1/FR-001). Mirrors
# the container's seed_vault_if_needed but resolves the vault under the workspace
# (LOCAL_VAULT_DIR, no /home/agent rebase), uses the host skeleton, and creates
# no /home/agent symlink. Idempotent; honors seed_skeleton + force_reseed (resets
# the flag in agent.yml on a forced reseed, matching the container path).
_seed_vault_local() {
  local agent_yml="$1"
  [ -f "$agent_yml" ] || return 0
  [ "$(yq -r '.vault.enabled // false' "$agent_yml")" = "true" ] || return 0

  local skeleton="$SCRIPT_DIR/modules/vault-skeleton"
  local vault_root="$LOCAL_VAULT_DIR" today
  today="$(date +%Y-%m-%d)"
  # shellcheck source=/dev/null
  . "$SCRIPT_DIR/scripts/lib/vault.sh"
  vault_ensure_paths "$vault_root" || { echo "  WARNING: vault_ensure_paths failed for $vault_root" >&2; return 0; }

  [ "$(yq -r '.vault.seed_skeleton // false' "$agent_yml")" = "true" ] || return 0
  [ -d "$skeleton" ] || { echo "  WARNING: vault skeleton not found: $skeleton" >&2; return 0; }

  if [ "$(yq -r '.vault.force_reseed // false' "$agent_yml")" = "true" ]; then
    if vault_backup_and_reseed "$vault_root" "$skeleton" "$today"; then
      yq -i '.vault.force_reseed = false' "$agent_yml" 2>/dev/null || true
      echo "  ✓ vault re-seeded (force_reseed) → $vault_root (previous kept at ${vault_root}.backup-*)"
    fi
  else
    vault_seed_if_empty "$vault_root" "$skeleton" "$today" \
      && echo "  ✓ vault skeleton ready → $vault_root"
  fi
  # 014 (FR-016/017): additive upgrade for an ALREADY-populated vault — add
  # wiki/normalization/ + the schema delta without overwriting or touching the
  # vault's CLAUDE.md. Clean no-op on a fresh seed (fresh-scaffold guard in the
  # lib). Runs on scaffold and every --regenerate.
  local deltas="$SCRIPT_DIR/modules/vault-deltas"
  if command -v vault_seed_missing >/dev/null 2>&1 && [ -d "$deltas" ]; then
    vault_seed_missing "$vault_root" "$skeleton" "$deltas" "$today" \
      && echo "  ✓ vault additive upgrade checked → $vault_root"
  fi
}

_export_local_context() {
  export OPERATOR_USER OPERATOR_HOME HOST_NAME CLAUDE_BIN
  OPERATOR_USER="$(id -un)"
  OPERATOR_HOME="$HOME"
  HOST_NAME="$(hostname)"

  # 022 (US3/N7b): safety belt. render.sh substitutes an UNDEFINED {{VAR}} with
  # the empty string, so a context without DEPLOYMENT_SESSION_NAME would emit a
  # unit reading `--name ""` — an agent with no name in claude.ai/code, and no
  # error anywhere. This is the only correct choke point: _export_local_context
  # is called from BOTH regenerate() and install_service(), and it is
  # install_service that renders the unit. Next to _persist_claude_cli it would
  # be skipped by any run that installs the unit without passing through
  # regenerate(). Never overwrites a value that is already set.
  export DEPLOYMENT_SESSION_NAME
  if [ -z "${DEPLOYMENT_SESSION_NAME:-}" ] || [ "${DEPLOYMENT_SESSION_NAME:-}" = "null" ]; then
    DEPLOYMENT_SESSION_NAME="$(_resolve_session_name "${AGENT_NAME:-agent}" "${DEPLOYMENT_HOST:-}")"
  fi
  local _cli="${DEPLOYMENT_CLAUDE_CLI:-claude}"
  # US1/FR-001/003: resolve to an absolute, executable path against the operator
  # HOME (NOT the --regenerate shell's PATH). Fail LOUD rather than emit a unit
  # whose ExecStart systemd cannot resolve (status=203/EXEC, restart-loop).
  if ! CLAUDE_BIN="$(resolve_claude_bin "$_cli" "$OPERATOR_HOME")"; then
    echo "" >&2
    echo "ERROR: could not resolve an absolute, executable path to the Claude CLI." >&2
    echo "       Configured deployment.claude_cli='${_cli}'." >&2
    echo "       Install Claude Code (the native installer puts it at ~/.local/bin/claude)" >&2
    echo "       or set deployment.claude_cli to an absolute path in agent.yml, then re-run" >&2
    echo "       ./setup.sh --regenerate. Refusing to emit a systemd unit with a" >&2
    echo "       non-executable ExecStart (it would fail with status=203/EXEC)." >&2
    return 1
  fi
}

# Render + install a system-wide systemd unit. Docker mode wraps `docker compose
# up -d`; local mode (011) installs the persistent `claude remote-control`
# session unit. Both go to /etc/systemd/system/agent-<name>.service (A1: local
# v1 is a SYSTEM unit, no `systemd --user`/linger). Requires sudo to install; if
# the user did not grant it, we print the rendered file + manual instructions.
install_service() {
  local agent_name="$1" workspace="$2"
  local modules_dir="$SCRIPT_DIR/modules"
  # Overridable for host-side tests (mirrors LOGIN_SYSTEMD_DIR in
  # local-login.sh.tpl); production default is the real system path.
  local systemd_dir="${SETUP_SYSTEMD_DIR:-/etc/systemd/system}"
  local unit_file="${systemd_dir}/agent-${agent_name}.service"
  local staged tpl
  staged=$(mktemp)
  # Bind $staged into the trap body at set-time (double quotes), not at
  # fire-time (single quotes). With set -u, fire-time expansion blew up
  # because the trap runs after install_service returns and the local has
  # already gone out of scope, killing run_wizard before render_next_steps
  # and the initial-commit step.
  trap "rm -f '$staged'" RETURN
  if [ "${DEPLOYMENT_MODE_IS_DOCKER:-true}" = true ]; then
    tpl="$modules_dir/systemd.service.tpl"
  else
    if ! _export_local_context; then
      echo "" >&2
      echo "✗ Service install aborted: unresolved Claude CLI (see error above)." >&2
      return 1
    fi
    tpl="$modules_dir/systemd-remote-control.service.tpl"
  fi
  render_to_file "$tpl" "$staged"

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

  # Local mode also ships a healthcheck timer (US3). Install it alongside the
  # session unit so the agent is observable out of the box; stage it if no sudo.
  if [ "${DEPLOYMENT_MODE_IS_DOCKER:-true}" != true ]; then
    local hc_svc="${systemd_dir}/agent-${agent_name}-healthcheck.service"
    local hc_tmr="${systemd_dir}/agent-${agent_name}-healthcheck.timer"
    local staged_svc staged_tmr
    staged_svc=$(mktemp); staged_tmr=$(mktemp)
    render_to_file "$modules_dir/local-healthcheck.service.tpl" "$staged_svc"
    render_to_file "$modules_dir/local-healthcheck.timer.tpl"   "$staged_tmr"
    if sudo -n true 2>/dev/null; then
      sudo cp "$staged_svc" "$hc_svc"
      sudo cp "$staged_tmr" "$hc_tmr"
      sudo systemctl daemon-reload
      sudo systemctl enable --now "agent-${agent_name}-healthcheck.timer" \
        && echo "  ✓ healthcheck timer installed + enabled (~5 min)"
    else
      cp "$staged_svc" "$SCRIPT_DIR/scripts/local/agent-${agent_name}-healthcheck.service"
      cp "$staged_tmr" "$SCRIPT_DIR/scripts/local/agent-${agent_name}-healthcheck.timer"
      echo "  ◦ healthcheck units staged in scripts/local/ (sudo unavailable)"
    fi
    rm -f "$staged_svc" "$staged_tmr"
  fi

  # US2 (012): QMD RAG units — reindex service+timer and the inotify watcher.
  # Only when qmd is enabled. Same staged-if-no-sudo pattern; --login installs
  # the staged copies. VAULT_QMD_ENABLED is exported by render_load_context.
  if [ "${DEPLOYMENT_MODE_IS_DOCKER:-true}" != true ] && [ "${VAULT_QMD_ENABLED:-false}" = "true" ]; then
    local q_ri_svc="agent-${agent_name}-qmd-reindex.service"
    local q_ri_tmr="agent-${agent_name}-qmd-reindex.timer"
    local q_wa_svc="agent-${agent_name}-qmd-watch.service"
    local s_ri_svc s_ri_tmr s_wa_svc
    s_ri_svc=$(mktemp); s_ri_tmr=$(mktemp); s_wa_svc=$(mktemp)
    render_to_file "$modules_dir/local-qmd-reindex.service.tpl" "$s_ri_svc"
    render_to_file "$modules_dir/local-qmd-reindex.timer.tpl"   "$s_ri_tmr"
    render_to_file "$modules_dir/local-qmd-watch.service.tpl"   "$s_wa_svc"
    if sudo -n true 2>/dev/null; then
      sudo cp "$s_ri_svc" "${systemd_dir}/$q_ri_svc"
      sudo cp "$s_ri_tmr" "${systemd_dir}/$q_ri_tmr"
      sudo cp "$s_wa_svc" "${systemd_dir}/$q_wa_svc"
      sudo systemctl daemon-reload
      sudo systemctl enable --now "$q_ri_tmr" "$q_wa_svc" \
        && echo "  ✓ qmd reindex timer + watcher installed + enabled"
    else
      cp "$s_ri_svc" "$SCRIPT_DIR/scripts/local/$q_ri_svc"
      cp "$s_ri_tmr" "$SCRIPT_DIR/scripts/local/$q_ri_tmr"
      cp "$s_wa_svc" "$SCRIPT_DIR/scripts/local/$q_wa_svc"
      echo "  ◦ qmd units staged in scripts/local/ (sudo unavailable)"
    fi
    rm -f "$s_ri_svc" "$s_ri_tmr" "$s_wa_svc"
  fi

  # US3 (012): vault backup timer + service, when vault is enabled. Same staged
  # pattern; --login installs staged copies. VAULT_ENABLED from render_load_context.
  if [ "${DEPLOYMENT_MODE_IS_DOCKER:-true}" != true ] && [ "${VAULT_ENABLED:-false}" = "true" ]; then
    local b_svc="agent-${agent_name}-vault-backup.service"
    local b_tmr="agent-${agent_name}-vault-backup.timer"
    local s_b_svc s_b_tmr
    s_b_svc=$(mktemp); s_b_tmr=$(mktemp)
    render_to_file "$modules_dir/local-vault-backup.service.tpl" "$s_b_svc"
    render_to_file "$modules_dir/local-vault-backup.timer.tpl"   "$s_b_tmr"
    if sudo -n true 2>/dev/null; then
      sudo cp "$s_b_svc" "${systemd_dir}/$b_svc"
      sudo cp "$s_b_tmr" "${systemd_dir}/$b_tmr"
      sudo systemctl daemon-reload
      sudo systemctl enable --now "$b_tmr" \
        && echo "  ✓ vault backup timer installed + enabled"
    else
      cp "$s_b_svc" "$SCRIPT_DIR/scripts/local/$b_svc"
      cp "$s_b_tmr" "$SCRIPT_DIR/scripts/local/$b_tmr"
      echo "  ◦ vault backup units staged in scripts/local/ (sudo unavailable)"
    fi
    rm -f "$s_b_svc" "$s_b_tmr"
  fi

  # 014 (FR-012): wiki-graph derive+lint timer + service — default-on when the
  # vault is on (WIKI_GRAPH_ENABLED). Same staged-if-no-sudo pattern; --login
  # installs staged copies. All 013 lessons live in the wrapper, not the unit.
  if [ "${DEPLOYMENT_MODE_IS_DOCKER:-true}" != true ] && [ "${WIKI_GRAPH_ENABLED:-false}" = "true" ]; then
    local wg_svc="agent-${agent_name}-wiki-graph.service"
    local wg_tmr="agent-${agent_name}-wiki-graph.timer"
    local s_wg_svc s_wg_tmr
    s_wg_svc=$(mktemp); s_wg_tmr=$(mktemp)
    render_to_file "$modules_dir/local-wiki-graph.service.tpl" "$s_wg_svc"
    render_to_file "$modules_dir/local-wiki-graph.timer.tpl"   "$s_wg_tmr"
    if sudo -n true 2>/dev/null; then
      sudo cp "$s_wg_svc" "${systemd_dir}/$wg_svc"
      sudo cp "$s_wg_tmr" "${systemd_dir}/$wg_tmr"
      sudo systemctl daemon-reload
      sudo systemctl enable --now "$wg_tmr" \
        && echo "  ✓ wiki-graph timer installed + enabled"
    else
      cp "$s_wg_svc" "$SCRIPT_DIR/scripts/local/$wg_svc"
      cp "$s_wg_tmr" "$SCRIPT_DIR/scripts/local/$wg_tmr"
      echo "  ◦ wiki-graph units staged in scripts/local/ (sudo unavailable)"
    fi
    rm -f "$s_wg_svc" "$s_wg_tmr"
  fi
}

# Validate that agent.yml has all the fields the rest of setup.sh +
# heartbeatctl + the docker-compose template expect to read. Fails
# fast with a punch-list rather than producing half-rendered files
# downstream. Used by --non-interactive and --regenerate so an
# accidentally-truncated agent.yml never silently produces a broken
# scaffold.
validate_agent_yml_required() {
  # Thin wrapper around agent_yml_validate (scripts/lib/schema.sh) so the
  # existing call sites in main() keep working. The schema lib now owns
  # the source of truth for required fields, enums, and boolean checks;
  # both --regenerate and --non-interactive flow through this helper.
  if ! agent_yml_validate "$1"; then
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
  # Remove ALL local companion units, not just the session unit: the healthcheck
  # (011) and the qmd/backup units (012). Guarded per-unit so absent ones are
  # skipped. Fixes the earlier gap where the healthcheck timer survived uninstall.
  local _local_units="agent-${agent_name}.service"
  _local_units="$_local_units agent-${agent_name}-healthcheck.timer agent-${agent_name}-healthcheck.service"
  _local_units="$_local_units agent-${agent_name}-qmd-reindex.timer agent-${agent_name}-qmd-reindex.service agent-${agent_name}-qmd-watch.service"
  _local_units="$_local_units agent-${agent_name}-vault-backup.timer agent-${agent_name}-vault-backup.service"
  _local_units="$_local_units agent-${agent_name}-wiki-graph.timer agent-${agent_name}-wiki-graph.service"
  local _any_unit=false _u
  for _u in $_local_units; do [ -f "/etc/systemd/system/$_u" ] && _any_unit=true; done
  if [ "$_any_unit" = true ]; then
    if sudo -n true 2>/dev/null; then
      for _u in $_local_units; do
        if [ -f "/etc/systemd/system/$_u" ]; then
          sudo systemctl disable --now "$_u" 2>/dev/null || true
          sudo rm -f "/etc/systemd/system/$_u" && echo "  ✓ removed /etc/systemd/system/$_u" || true
        fi
      done
      sudo systemctl daemon-reload 2>/dev/null || true
    else
      echo "  ◦ local systemd units present — remove manually with sudo (agent-${agent_name}*.{service,timer})"
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
    # 013 (FR-004/D12): read the deployment mode BEFORE removing agent.yml. In
    # local mode the vault backup clone cache lives OUTSIDE the workspace, under
    # the operator's ~/.cache — a copy of the vault markdown that would survive
    # --purge/--nuke (data remanence). Docker keeps its clone inside .state
    # (removed below). The qmd index/config now live under .state too (013 RC1)
    # and vanish with the workspace; pre-013 legacy residue in ~/.cache/qmd stays
    # untouched — manual cleanup, never an automatic rm in the operator's $HOME.
    local _uninst_mode
    _uninst_mode=$(yq -r '.deployment.mode // "docker"' "$agent_yml" 2>/dev/null || echo docker)
    rm -f "$agent_yml" && echo "  ✓ agent.yml" || true
    rm -f "$env_file" && echo "  ✓ .env" || true
    rm -rf "$SCRIPT_DIR/.state" && echo "  ✓ .state/ (login, pairing, sessions, plugin cache)" || true
    if [ "$_uninst_mode" = "local" ]; then
      local _vclone="${VAULT_BACKUP_CACHE_DIR:-$HOME/.cache/agent-backup}/vault-clone"
      [ -e "$_vclone" ] && rm -rf "$_vclone" && echo "  ✓ ~/.cache/agent-backup/vault-clone (local backup cache)" || true
    fi
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

# Trigger an identity backup inside the container. Requires a scaffolded
# workspace (agent.yml + a running container with the agent's name).
cmd_backup() {
  local agent_yml="$SCRIPT_DIR/agent.yml"
  [ -f "$agent_yml" ] || { echo "ERROR: agent.yml not found at $agent_yml" >&2; exit 1; }
  local agent_name
  agent_name=$(yq '.agent.name' "$agent_yml" 2>/dev/null)
  [ -z "$agent_name" ] || [ "$agent_name" = "null" ] && {
    echo "ERROR: cannot read agent.name from agent.yml" >&2
    exit 1
  }
  echo "▸ Triggering identity backup for $agent_name..."
  docker exec -u agent "$agent_name" heartbeatctl backup-identity
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
    login)
      if [ ! -f "$agent_yml" ]; then
        echo "ERROR: agent.yml not found; run wizard first" >&2
        exit 1
      fi
      local _login_mode
      _login_mode=$(yq -r '.deployment.mode // "docker"' "$agent_yml")
      if [ "$_login_mode" != "local" ]; then
        echo "ERROR: --login is only for local mode (deployment.mode=local); this" >&2
        echo "       workspace is '${_login_mode}'. Docker agents log in inside the" >&2
        echo "       container (see NEXT_STEPS.md)." >&2
        exit 1
      fi
      local _login_helper="$SCRIPT_DIR/scripts/local/agent-login.sh"
      if [ ! -x "$_login_helper" ]; then
        echo "ERROR: login helper not found ($_login_helper); run ./setup.sh --regenerate first." >&2
        exit 1
      fi
      "$_login_helper"
      ;;
    uninstall)
      uninstall
      ;;
    sync-template)
      sync_template
      ;;
    backup)
      cmd_backup
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

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
