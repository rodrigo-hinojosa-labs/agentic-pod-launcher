#!/usr/bin/env bash
# Guided one-time login + trust + enable for the local Remote Control session.
# Rendered from modules/local-login.sh.tpl — do not hand-edit (use ./setup.sh
# --regenerate). Idempotent: safe to re-run.
set -euo pipefail

WORKSPACE="{{DEPLOYMENT_WORKSPACE}}"
AGENT_NAME="{{AGENT_NAME}}"
CLAUDE_BIN="{{CLAUDE_BIN}}"
UNIT="agent-${AGENT_NAME}.service"
CONFIG_DIR="${WORKSPACE}/.state/.claude"
CLAUDE_JSON="${CONFIG_DIR}/.claude.json"
MIN_VERSION="2.1.51"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Pure version compare: prints "ge" when A >= B (per-component numeric), else "lt".
_ver_ge() {
  awk -v a="$1" -v b="$2" 'BEGIN{
    na=split(a,A,"."); nb=split(b,B,".");
    n=(na>nb)?na:nb;
    for(i=1;i<=n;i++){x=A[i]+0; y=B[i]+0;
      if(x>y){print "ge"; exit} if(x<y){print "lt"; exit}}
    print "ge"
  }'
}

# 1. Hard requirement: Claude Code >= MIN_VERSION (Remote Control gate).
raw=$("$CLAUDE_BIN" --version 2>/dev/null || true)
ver=$(printf '%s' "$raw" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
if [ -z "$ver" ] || [ "$(_ver_ge "$ver" "$MIN_VERSION")" != "ge" ]; then
  echo "ERROR: Claude Code >= ${MIN_VERSION} is required for Remote Control (found: ${ver:-none})." >&2
  echo "       Update Claude Code, then re-run: ./setup.sh --login" >&2
  exit 1
fi

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required for the login helper." >&2; exit 1; }

# Trust/onboarding helpers (sourced AFTER the version+jq gates so a stale Claude
# fails fast without needing the lib present).
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/../lib/local_trust.sh"

export CLAUDE_CONFIG_DIR="$CONFIG_DIR"
mkdir -p "$CONFIG_DIR"

# 2. Pre-seed onboarding BEFORE login (non-destructive — never clobbers a value).
local_seed_onboarding "$CLAUDE_JSON"

# 3. One-time full-scope OAuth login. Inference-only tokens are rejected by
#    Remote Control, so this is interactive and manual. On a headless host,
#    tunnel the OAuth callback port over SSH (ssh -L <port>:localhost:<port>)
#    and complete the browser flow on your laptop.
if [ -r "${CONFIG_DIR}/.credentials.json" ]; then
  echo "◦ Existing credentials found in ${CONFIG_DIR} — skipping login; re-applying trust."
else
  echo "▸ Launching Claude Code for a one-time full-scope login."
  echo "  Inside the session: run '/login', complete the browser OAuth, then '/exit'."
  echo "  (Headless: tunnel the callback port over SSH first.)"
  "$CLAUDE_BIN" || true
fi

# 4. AFTER login: re-apply the workspace trust (the login rewrites .claude.json
#    and resets per-project trust). Idempotent, exact-equality (gotcha #4).
local_merge_trust "$CLAUDE_JSON" "$WORKSPACE"
echo "  ✓ workspace trust applied for ${WORKSPACE}"

# 5. Enable + start the system unit (system unit → needs sudo). With
#    Restart=always the ExecCondition keeps it inactive (not failed) until the
#    credentials exist, so enabling before login is safe too.
if [ -f "/etc/systemd/system/${UNIT}" ]; then
  if sudo systemctl enable --now "$UNIT"; then
    echo "  ✓ ${UNIT} enabled + started"
    echo "  → check it: systemctl status ${UNIT} ; journalctl -u ${UNIT} -f"
  fi
else
  echo "WARNING: ${UNIT} is not installed under /etc/systemd/system." >&2
  echo "         Re-run ./setup.sh (with install_service=true) to install it," >&2
  echo "         then: sudo systemctl enable --now ${UNIT}" >&2
fi
