#!/usr/bin/env bash
# Local-mode qmd MCP server entrypoint. Rendered from modules/local-qmd-mcp.sh.tpl
# — do not hand-edit (use ./setup.sh --regenerate). Launches the qmd MCP stdio
# server (the READER Claude searches with) from the SAME managed bun-install
# prefix + storage as the reindex writer, via qmd_index.sh::qmd_mcp_exec.
#
# 016 (T036): NOT `bunx @tobilu/qmd mcp` — that recompiles tree-sitter and aborts
# on musl, and even on glibc it would resolve a DIFFERENT prefix than the reindex.
# .mcp.json points its qmd `command` here (QMD_MCP_COMMAND).
set -uo pipefail

WORKSPACE="{{DEPLOYMENT_WORKSPACE}}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# PATH (parity with local-qmd-reindex): systemd's minimal PATH excludes the
# operator's ~/.local/bin (where the bootstrap installs bun/bunx) and the vendored
# yq. Claude launches this MCP with the .mcp.json env, which carries NO PATH — set
# it here so `command -v bun` inside qmd_mcp_exec resolves.
export PATH="{{OPERATOR_HOME}}/.local/bin:${WORKSPACE}/scripts/vendor/bin:$PATH"

# Storage env contract (013 RC1): the qmd BINARY honors XDG_CACHE_HOME +
# QMD_CONFIG_DIR; the bash lib's qmd_cache_root() (→ the bun-install prefix) reads
# QMD_CACHE_HOME. Set all three so the MCP reader resolves the SAME prefix AND the
# SAME index.sqlite as the reindex writer (fixing only one silently empties RAG).
export XDG_CACHE_HOME="${WORKSPACE}/.state/.cache"
export QMD_CONFIG_DIR="${WORKSPACE}/.state/.config/qmd"
export QMD_CACHE_HOME="${WORKSPACE}/.state/.cache/qmd"

mkdir -p "$QMD_CACHE_HOME" "$QMD_CONFIG_DIR" 2>/dev/null || true

# shellcheck source=/dev/null
. "${SCRIPT_DIR}/../lib/qmd_index.sh"

# EXECs the server (never returns); pin resolved from agent.yml (single source).
qmd_mcp_exec "$(qmd_pkg "${WORKSPACE}/agent.yml")"
