#!/usr/bin/env bash
# Provision the MCP runtimes the workspace .mcp.json references, into the
# operator's ~/.local/bin — so the systemd Remote Control session can spawn
# them. Rendered from modules/local-bootstrap.sh.tpl — do not hand-edit (use
# ./setup.sh --regenerate). Idempotent + best-effort: a failed optional install
# warns and continues; the script always exits 0 so it never blocks --login.
#
# Why this exists: docker mode bakes uv/uvx, node/npx, github-mcp-server and bun
# into the image. Local mode runs Claude directly on the host, where none of that
# is present by default AND the systemd unit inherits a minimal PATH. Validated
# on mclaren: all five project MCPs → "✘ Failed to connect" because uvx/npx/
# github-mcp-server were absent from every PATH. This installs exactly what the
# rendered .mcp.json asks for; remote-control.env pins PATH at ~/.local/bin so
# the unit finds them.
#
# Version pins mirror docker/Dockerfile ARGs (uv 0.11.22 / bun 1.3.14 /
# github-mcp-server 1.4.0). Keep them in sync when the Dockerfile bumps.
#
# BOOTSTRAP_DRY_RUN=1 prints the provisioning plan (one `PLAN …` line per action)
# and does nothing — this is what the host-side bats suite asserts. The real
# download/extract path is exercised on the Linux host (mclaren gate).
set -uo pipefail

WORKSPACE="{{DEPLOYMENT_WORKSPACE}}"
TARGET_BIN="{{OPERATOR_HOME}}/.local/bin"
MCP_JSON="${WORKSPACE}/.mcp.json"

UV_VERSION="0.11.22"
BUN_VERSION="1.3.14"
GH_MCP_VERSION="1.4.0"

DRY_RUN="${BOOTSTRAP_DRY_RUN:-0}"

log()  { printf '  %s\n' "$*"; }
warn() { printf '  WARNING: %s\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

# uv/uvx — required by every uvx MCP (fetch, git, atlassian, time). Static musl
# tarball (runs on any Linux), same asset the Dockerfile uses.
provision_uv() {
  if [ "$DRY_RUN" = 1 ]; then echo "PLAN uv"; return 0; fi
  if have uvx && have uv; then log "uv present ($(uv --version 2>/dev/null || echo '?'))"; return 0; fi
  local arch uv_arch tmp
  arch="$(uname -m)"
  case "$arch" in
    x86_64)        uv_arch="x86_64-unknown-linux-musl" ;;
    aarch64|arm64) uv_arch="aarch64-unknown-linux-musl" ;;
    *) warn "unsupported arch for uv: $arch"; return 1 ;;
  esac
  tmp="$(mktemp -d)" || return 1
  log "installing uv ${UV_VERSION} (${uv_arch}) → ${TARGET_BIN}"
  if curl -fsSL "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-${uv_arch}.tar.gz" \
       | tar -xz -C "$tmp" --strip-components=1; then
    if mv "$tmp/uv" "$tmp/uvx" "$TARGET_BIN/" && chmod +x "$TARGET_BIN/uv" "$TARGET_BIN/uvx"; then
      log "uv installed"
    else
      warn "uv install: could not move binaries into ${TARGET_BIN}"
    fi
  else
    warn "uv download failed (${UV_VERSION})"
  fi
  rm -rf "$tmp"
}

# Warm the uv tool cache for each uvx package the .mcp.json references, so the
# first MCP handshake does not race a PyPI download (the Dockerfile pre-installs
# the same tools into /opt/uv for the same reason).
provision_uv_tools() {
  local pkgs pkg py_flag
  pkgs="$(jq -r '.mcpServers // {} | to_entries[] | select(.value.command=="uvx") | .value.args[0] // empty' "$MCP_JSON" 2>/dev/null | sort -u)"
  [ -n "$pkgs" ] || return 0
  py_flag=""
  have python3 && py_flag="--python python3"
  for pkg in $pkgs; do
    if [ "$DRY_RUN" = 1 ]; then echo "PLAN uv-tool $pkg"; continue; fi
    have uv || { warn "uv missing — cannot warm ${pkg}"; continue; }
    log "warming uv tool: ${pkg}"
    # shellcheck disable=SC2086
    uv tool install $py_flag "$pkg" >/dev/null 2>&1 || warn "uv tool install ${pkg} failed (will resolve on first use)"
  done
}

# node/npx — required by npx MCPs (filesystem, playwright, …). We do NOT install
# node; we symlink the operator's existing node (nvm or system) into ~/.local/bin
# so the unit's minimal PATH can reach it. nvm's node stays first in the
# operator's own interactive PATH, so this symlink only "wins" for the unit.
provision_node_links() {
  if [ "$DRY_RUN" = 1 ]; then echo "PLAN node-links"; return 0; fi
  # Load nvm (its shell hook is not sourced in a non-login/non-interactive shell).
  if [ -s "{{OPERATOR_HOME}}/.nvm/nvm.sh" ]; then
    # shellcheck source=/dev/null
    . "{{OPERATOR_HOME}}/.nvm/nvm.sh" >/dev/null 2>&1 || true
  fi
  local node_bin node_dir f
  node_bin="$(command -v node 2>/dev/null || true)"
  if [ -z "$node_bin" ]; then
    warn "node not found — install Node.js (or nvm); the npx-based MCP (filesystem) will not start"
    return 1
  fi
  node_bin="$(readlink -f "$node_bin" 2>/dev/null || echo "$node_bin")"
  node_dir="$(dirname "$node_bin")"
  if [ "$node_dir" = "$TARGET_BIN" ]; then
    log "node already resolves inside ${TARGET_BIN}"
    return 0
  fi
  for f in node npm npx; do
    [ -e "$node_dir/$f" ] && ln -sf "$node_dir/$f" "$TARGET_BIN/$f"
  done
  log "node linked from ${node_dir} → ${TARGET_BIN} ($("$TARGET_BIN/node" --version 2>/dev/null || echo '?'))"
}

# github-mcp-server — GitHub's official Go binary (statically linked). Pinned +
# checksum-verified, exactly like the Dockerfile.
provision_github_mcp() {
  if [ "$DRY_RUN" = 1 ]; then echo "PLAN github-mcp-server ${GH_MCP_VERSION}"; return 0; fi
  if have github-mcp-server; then log "github-mcp-server present"; return 0; fi
  local arch gh_arch tmp base asset
  arch="$(uname -m)"
  case "$arch" in
    x86_64)        gh_arch="x86_64" ;;
    aarch64|arm64) gh_arch="arm64" ;;
    *) warn "unsupported arch for github-mcp-server: $arch"; return 1 ;;
  esac
  tmp="$(mktemp -d)" || return 1
  base="https://github.com/github/github-mcp-server/releases/download/v${GH_MCP_VERSION}"
  asset="github-mcp-server_Linux_${gh_arch}.tar.gz"
  log "installing github-mcp-server ${GH_MCP_VERSION} (${gh_arch}) → ${TARGET_BIN}"
  if ( cd "$tmp" \
        && curl -fsSL -O "${base}/${asset}" \
        && curl -fsSL -O "${base}/github-mcp-server_${GH_MCP_VERSION}_checksums.txt" \
        && grep "$asset" "github-mcp-server_${GH_MCP_VERSION}_checksums.txt" | sha256sum -c - >/dev/null 2>&1 \
        && tar -xzf "$asset" github-mcp-server ); then
    if mv "$tmp/github-mcp-server" "$TARGET_BIN/github-mcp-server" && chmod +x "$TARGET_BIN/github-mcp-server"; then
      log "github-mcp-server installed"
    else
      warn "github-mcp-server: could not move binary into ${TARGET_BIN}"
    fi
  else
    warn "github-mcp-server download/checksum/extract failed (${GH_MCP_VERSION})"
  fi
  rm -rf "$tmp"
}

# bun/bunx — required only by the qmd MCP (bunx). Static musl zip; needs unzip.
provision_bun() {
  if [ "$DRY_RUN" = 1 ]; then echo "PLAN bun ${BUN_VERSION}"; return 0; fi
  if have bun && have bunx; then log "bun present"; return 0; fi
  have unzip || { warn "unzip not found — cannot install bun (qmd MCP will not start); install it (e.g. apt-get install unzip)"; return 1; }
  local arch bun_arch tmp
  arch="$(uname -m)"
  case "$arch" in
    x86_64)        bun_arch="x64" ;;
    aarch64|arm64) bun_arch="aarch64" ;;
    *) warn "unsupported arch for bun: $arch"; return 1 ;;
  esac
  tmp="$(mktemp -d)" || return 1
  log "installing bun ${BUN_VERSION} (${bun_arch}) → ${TARGET_BIN}"
  if ( cd "$tmp" \
        && curl -fsSL -o bun.zip "https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION}/bun-linux-${bun_arch}-musl.zip" \
        && unzip -q bun.zip ); then
    if mv "$tmp/bun-linux-${bun_arch}-musl/bun" "$TARGET_BIN/bun" && chmod +x "$TARGET_BIN/bun"; then
      ln -sf "$TARGET_BIN/bun" "$TARGET_BIN/bunx"
      log "bun installed"
    else
      warn "bun: could not move binary into ${TARGET_BIN}"
    fi
  else
    warn "bun download/unzip failed (${BUN_VERSION})"
  fi
  rm -rf "$tmp"
}

main() {
  command -v jq >/dev/null 2>&1 || { warn "jq is required for bootstrap"; return 0; }
  if [ ! -f "$MCP_JSON" ]; then
    log "no .mcp.json at ${MCP_JSON} — no MCP runtimes to provision"
    return 0
  fi
  [ "$DRY_RUN" = 1 ] || mkdir -p "$TARGET_BIN"

  local cmds
  cmds="$(jq -r '.mcpServers // {} | to_entries[] | .value.command // empty' "$MCP_JSON" 2>/dev/null | sort -u)"

  printf '%s\n' "$cmds" | grep -qx "uvx"              && { provision_uv; provision_uv_tools; }
  printf '%s\n' "$cmds" | grep -qx "npx"              && provision_node_links
  printf '%s\n' "$cmds" | grep -qx "github-mcp-server" && provision_github_mcp
  printf '%s\n' "$cmds" | grep -qx "bunx"             && provision_bun

  return 0
}

main "$@"
exit 0
