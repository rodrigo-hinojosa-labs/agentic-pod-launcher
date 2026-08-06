# shellcheck shell=bash
# Library: managed toolchain versions — default channels + best-effort
# upstream resolver.
#
# The launcher ships only CHANNEL intent here (not frozen version
# numbers as the source of truth). "Latest stable of the moment" is
# resolved to a concrete version and recorded into agent.yml's docker:
# block at scaffold / --regenerate / `agentctl versions --upgrade`.
# The image build consumes the recorded concrete versions, so builds are
# reproducible and the running container never auto-updates.
#
# Sourcing this file has no side effects (only assignments + function
# defs) — safe to source from setup.sh, scripts/agentctl, and tests.
#
# See specs/001-deps-upgrade/ for the full design.

# Default channels per managed component. Override via the environment
# to test or to retarget (e.g. AGENTIC_CHANNEL_CLAUDE_CODE=latest).
#   stable  — track the upstream stable channel (Claude Code npm dist-tag)
#   latest  — track the latest non-prerelease release
AGENTIC_CHANNEL_CLAUDE_CODE="${AGENTIC_CHANNEL_CLAUDE_CODE:-stable}"
AGENTIC_CHANNEL_ALPINE="${AGENTIC_CHANNEL_ALPINE:-latest}"
AGENTIC_CHANNEL_UV="${AGENTIC_CHANNEL_UV:-latest}"
AGENTIC_CHANNEL_BUN="${AGENTIC_CHANNEL_BUN:-latest}"
AGENTIC_CHANNEL_GUM="${AGENTIC_CHANNEL_GUM:-latest}"

# Documented last-known floor — used ONLY when upstream is unreachable
# during resolution (offline first scaffold, network blip). This is a
# safety net, NOT the source of truth: the normal path resolves live.
# Keep these consistent with the docker/Dockerfile ARG defaults (a bats
# drift-guard enforces it).
AGENTIC_FLOOR_CLAUDE_CODE="2.1.170"
AGENTIC_FLOOR_ALPINE="3.24.1"
AGENTIC_FLOOR_UV="0.11.22"
AGENTIC_FLOOR_BUN="1.3.14"
AGENTIC_FLOOR_GUM="0.17.0"

# Image-baked MCP servers (feature 004-macos-bootstrap-hardening). These are
# HARD pins, not channel-resolved like the toolchain above: each is baked into
# the image OFF the .state bind-mount (npm pre-warm into /opt/npm-cache for the
# two npm packages; a static Go binary in /usr/local/bin for github-mcp-server)
# to dodge the macOS VirtioFS small-file pathology that fails npx MCP handshakes.
# The Dockerfile ARG defaults MUST equal these — a bats drift-guard enforces it.
# Bump deliberately (re-confirm against the npm registry / GitHub releases).
AGENTIC_FLOOR_MCP_FILESYSTEM="2026.1.14"
AGENTIC_FLOOR_MCP_VAULT="0.12.0"
AGENTIC_FLOOR_GH_MCP="1.4.0"

# uvx (Python tool-runner) MCP servers + the `mcp` protocol library
# (feature 027-declarative-scaffold-parity). These are HARD pins for the
# LOCAL-mode runtime provisioner (modules/local-bootstrap.sh.tpl → the rendered
# scripts/local/agent-bootstrap.sh), injected at render time so the standalone
# provisioner carries literal versions (it cannot source this lib at runtime).
#
# Why pinned: an unpinned `uv tool install mcp-server-fetch` on a fresh scaffold
# resolves the newest server together with a newer `mcp` SDK that renamed
# McpError→MCPError, so fetch/git fail at import (measured on ferrari, 2026-08-05:
# `ImportError: cannot import name 'McpError'`). The combo below is the one the
# working mclaren host runs and the ferrari manual fix restored
# (`--with mcp==1.28.1`); see specs/027-declarative-scaffold-parity/research.md.
# Docker mode is unaffected (it bakes its own uvx tools in docker/Dockerfile —
# that path has the identical latent drift, tracked as a separate follow-up).
# Bump deliberately (re-confirm the four form a mutually-compatible set:
# `uv tool install <pkg>==<ver> --with mcp==<lib>` connects).
AGENTIC_FLOOR_MCP_FETCH="2026.6.4"
AGENTIC_FLOOR_MCP_GIT="2026.6.16"
AGENTIC_FLOOR_MCP_ATLASSIAN="0.21.1"
AGENTIC_FLOOR_MCP_LIB="1.28.1"

# _versions_fetch URL -> stdout
# Best-effort HTTP GET (curl). Dependency-injection seam: tests override
# this to return fixture payloads with no live network. Returns non-zero
# / empty on failure so the caller falls back to the floor.
_versions_fetch() {
  curl -fsSL --max-time "${AGENTIC_HTTP_TIMEOUT:-4}" "$1" 2>/dev/null
}

# versions_resolve COMPONENT -> stdout (concrete version)
# Resolves a component's channel to a concrete latest-stable version via
# a best-effort upstream query. On success echoes the version, returns 0.
# On any failure echoes the documented floor and returns 1. Unknown
# component returns 2.
#   claude_code -> npm `stable` dist-tag (NOT latest/next/prerelease)
#   uv|bun|gum  -> GitHub releases/latest tag (prereleases excluded)
#   alpine      -> latest-stable release version
versions_resolve() {
  local component="${1:?versions_resolve: need component}" raw="" out=""
  local floor_var="AGENTIC_FLOOR_$(printf '%s' "$component" | tr '[:lower:]' '[:upper:]')"

  case "$component" in
    claude_code|uv|bun|gum|alpine) ;;
    *) echo "versions_resolve: unknown component: $component" >&2; return 2 ;;
  esac

  # Forced offline (offline scaffold / deterministic tests): use the floor
  # and never touch the network.
  if [ -n "${AGENTIC_VERSIONS_OFFLINE:-}" ]; then
    printf '%s' "${!floor_var:-}"
    return 0
  fi

  case "$component" in
    claude_code)
      raw=$(_versions_fetch "https://registry.npmjs.org/@anthropic-ai/claude-code") \
        && out=$(printf '%s' "$raw" | jq -r '."dist-tags".stable // empty' 2>/dev/null) ;;
    uv)
      raw=$(_versions_fetch "https://api.github.com/repos/astral-sh/uv/releases/latest") \
        && out=$(printf '%s' "$raw" | jq -r '.tag_name // empty' 2>/dev/null) ;;
    bun)
      raw=$(_versions_fetch "https://api.github.com/repos/oven-sh/bun/releases/latest") \
        && out=$(printf '%s' "$raw" | jq -r '(.tag_name // "") | ltrimstr("bun-v")' 2>/dev/null) ;;
    gum)
      raw=$(_versions_fetch "https://api.github.com/repos/charmbracelet/gum/releases/latest") \
        && out=$(printf '%s' "$raw" | jq -r '(.tag_name // "") | ltrimstr("v")' 2>/dev/null) ;;
    alpine)
      raw=$(_versions_fetch "https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64/latest-releases.yaml") \
        && out=$(printf '%s' "$raw" | sed -n 's/^[[:space:]]*version:[[:space:]]*//p' | head -1) ;;
  esac

  if [ -n "$out" ] && [ "$out" != "null" ]; then
    printf '%s' "$out"
    return 0
  fi

  # Offline / parse failure: fall back to the documented floor.
  printf '%s' "${!floor_var:-}"
  return 1
}
