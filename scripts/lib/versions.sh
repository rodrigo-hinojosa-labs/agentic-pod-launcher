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
