#!/usr/bin/env bats
# Feature 004 — Dockerfile shape assertions for the image-baked MCP fixes.
# These are no-Docker "shape" tests (grep the Dockerfile) per constitution
# Principle III; runtime behavior is covered by the opt-in DOCKER_E2E suite.
#
# US1 (npm pre-warm): the npm cache must live off the /home/agent bind-mount
# and the default npx MCP packages must be warmed into it at build time.
# US3 (github binary): the deprecated npx github MCP is replaced by the
# official statically-linked github-mcp-server Go binary in /usr/local/bin.

load helper

DF() { printf '%s' "$REPO_ROOT/docker/Dockerfile"; }

# --- US1: npm pre-warm off the bind-mount ---------------------------------

@test "US1: Dockerfile relocates the npm cache off the /home/agent bind-mount" {
  grep -Eq '(ENV|^)\s*NPM_CONFIG_CACHE=/opt/npm-cache' "$(DF)"
}

@test "US1: Dockerfile enables npm prefer-offline for warm-cache resolution" {
  grep -Eq 'NPM_CONFIG_PREFER_OFFLINE=true' "$(DF)"
}

@test "US1: Dockerfile declares pinned ARGs for the two npm MCP packages" {
  grep -Eq '^ARG MCP_FILESYSTEM_VERSION=' "$(DF)" \
    && grep -Eq '^ARG MCP_VAULT_VERSION=' "$(DF)"
}

@test "US1: Dockerfile warms both default npx MCP packages at build time" {
  # The warm RUN references each package so its tarball + metadata land in
  # the off-bind-mount cache (filesystem stays bare in the template, vault
  # is pinned — both are warmed via their ARG).
  grep -q '@modelcontextprotocol/server-filesystem' "$(DF)" \
    && grep -q '@bitbonsai/mcpvault' "$(DF)"
}

@test "US1: Dockerfile chowns the npm cache to the numeric agent uid/gid" {
  # Numeric chown like the uv block — works before the agent user exists.
  grep -Eq 'chown -R \$\{UID\}:\$\{GID\} /opt/npm-cache' "$(DF)"
}

# --- US3: github-mcp-server Go binary baked into /usr/local/bin -------------

@test "US3: Dockerfile pins github-mcp-server to the versions.sh floor (drift guard)" {
  load_lib versions
  grep -Eq "^ARG GH_MCP_VERSION=${AGENTIC_FLOOR_GH_MCP}\$" "$(DF)"
}

@test "US3: Dockerfile downloads the github-mcp-server binary with checksum verify" {
  # Modeled on the gum/uv/bun blocks: arch-mapped release asset, sha256 verify,
  # extract to /usr/local/bin (off /home/agent so the bind-mount can't shadow it).
  grep -q 'github-mcp-server_Linux_' "$(DF)" \
    && grep -q 'sha256sum -c' "$(DF)" \
    && grep -q '/usr/local/bin' "$(DF)"
}
