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

# 5. Install (if needed) + enable + start the system unit (system unit → needs
#    sudo). With Restart=always the ExecCondition keeps it inactive (not failed)
#    until the credentials exist, so enabling before login is safe too.
#    SYSTEMD_DIR is overridable for host-side tests (LOGIN_SYSTEMD_DIR);
#    production default is the real system path.
SYSTEMD_DIR="${LOGIN_SYSTEMD_DIR:-/etc/systemd/system}"
UNIT_PATH="${SYSTEMD_DIR}/${UNIT}"
STAGED_UNIT="${WORKSPACE}/${UNIT}"

# install_service stages the unit in the workspace root when `sudo -n` was
# unavailable at scaffold time. A fresh --login is the first interactive sudo
# context, so install the staged copy here instead of leaving the operator with
# a staged-but-inactive unit (regression validated on a sudo-prompt host).
if [ ! -f "$UNIT_PATH" ] && [ -f "$STAGED_UNIT" ]; then
  echo "▸ Installing staged unit ${UNIT} (needs sudo)…"
  if sudo cp "$STAGED_UNIT" "$UNIT_PATH" && sudo systemctl daemon-reload; then
    echo "  ✓ ${UNIT} installed under ${SYSTEMD_DIR}"
  else
    echo "WARNING: could not install ${UNIT}; copy it manually:" >&2
    echo "         sudo cp ${STAGED_UNIT} ${UNIT_PATH} && sudo systemctl daemon-reload" >&2
  fi
fi

if [ -f "$UNIT_PATH" ]; then
  if sudo systemctl enable --now "$UNIT"; then
    echo "  ✓ ${UNIT} enabled + started"
    echo "  → check it: systemctl status ${UNIT} ; journalctl -u ${UNIT} -f"
  fi
else
  echo "WARNING: ${UNIT} is not installed under ${SYSTEMD_DIR} and no staged copy" >&2
  echo "         was found at ${STAGED_UNIT}. Re-run ./setup.sh --regenerate to" >&2
  echo "         re-stage it, then re-run ./setup.sh --login." >&2
fi

# 6. Healthcheck units (US3): install + enable the staged timer/service the
#    same way as the main unit. install_service stages these under
#    scripts/local/ when `sudo -n` was unavailable; the main unit and the
#    healthcheck are staged independently, so a --login that only installed the
#    session unit left the ~5-min observability timer inactive.
HC_SVC="agent-${AGENT_NAME}-healthcheck.service"
HC_TMR="agent-${AGENT_NAME}-healthcheck.timer"
HC_STAGED_DIR="${WORKSPACE}/scripts/local"
for _hc in "$HC_SVC" "$HC_TMR"; do
  if [ ! -f "${SYSTEMD_DIR}/${_hc}" ] && [ -f "${HC_STAGED_DIR}/${_hc}" ]; then
    sudo cp "${HC_STAGED_DIR}/${_hc}" "${SYSTEMD_DIR}/${_hc}" || true
  fi
done
if [ -f "${SYSTEMD_DIR}/${HC_TMR}" ]; then
  sudo systemctl daemon-reload || true
  if sudo systemctl enable --now "$HC_TMR"; then
    echo "  ✓ ${HC_TMR} enabled (~5 min healthcheck)"
  fi
fi
