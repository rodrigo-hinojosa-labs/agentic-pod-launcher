# syntax=docker/dockerfile:1.6
FROM alpine:3.20

ARG UID=1000
ARG GID=1000

# Disable Claude Code's built-in auto-updater. Claude runs as `agent` and
# cannot rename /usr/local/lib/node_modules/@anthropic-ai/claude-code
# (root-owned from the `npm install -g` below), so every auto-update
# attempt floods claude.log with EACCES errors and correlates with
# occasional bun plugin deaths. Version bumps should be intentional:
# rebuild the image to pick up a newer claude-code.
ENV DISABLE_AUTOUPDATER=1

# Runtime packages. `tini` for PID 1, `bash` for scripts, `tmux` for the
# persistent session, `nodejs`/`npm` for the claude CLI, `git` for repo ops,
# `curl` for bootstrapping, `perl` for the template engine, `yq`/`jq` for
# config, `busybox-extras` for `crond`, `gum` for the in-container wizard.
# `python3` is required as the interpreter for `uvx`-spawned MCP servers
# (mcp-server-fetch, mcp-server-time, mcp-atlassian); without it, uv errors
# with "No interpreter found in managed installations or search path" and
# every uvx-based MCP fails its handshake.
RUN apk add --no-cache \
      bash \
      tini \
      tmux \
      nodejs \
      npm \
      git \
      curl \
      perl \
      jq \
      yq \
      gettext \
      busybox-extras \
      shadow \
      su-exec \
      ca-certificates \
      python3 \
      flock

# Install gum from the charmbracelet tap alternative: use the static binary.
ARG GUM_VERSION=0.14.5
RUN set -eux; \
    arch=$(uname -m); \
    case "$arch" in \
      x86_64) gum_arch="x86_64" ;; \
      aarch64) gum_arch="arm64" ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    mkdir -p /tmp/gum; \
    curl -fsSL "https://github.com/charmbracelet/gum/releases/download/v${GUM_VERSION}/gum_${GUM_VERSION}_Linux_${gum_arch}.tar.gz" \
      | tar -xz -C /tmp/gum --strip-components=1; \
    mv /tmp/gum/gum /usr/local/bin/gum; \
    rm -rf /tmp/gum

# Install uv / uvx (required by MCPs that ship as Python packages —
# time, fetch, mcp-atlassian). Without this, those MCPs fail at startup
# with "uvx: not found".
ARG UV_VERSION=0.5.14
RUN set -eux; \
    arch=$(uname -m); \
    case "$arch" in \
      x86_64) uv_arch="x86_64-unknown-linux-musl" ;; \
      aarch64) uv_arch="aarch64-unknown-linux-musl" ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    mkdir -p /tmp/uv; \
    curl -fsSL "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-${uv_arch}.tar.gz" \
      | tar -xz -C /tmp/uv --strip-components=1; \
    mv /tmp/uv/uv /tmp/uv/uvx /usr/local/bin/; \
    chmod +x /usr/local/bin/uv /usr/local/bin/uvx; \
    rm -rf /tmp/uv; \
    uv --version

# Pre-install the Python-based MCPs the template wires via uvx (fetch, time,
# atlassian). Without this, the first invocation of each triggers a PyPI
# download inside Claude's MCP handshake window; the handshake times out and
# the server is marked failed before the install finishes. Installing into
# /opt/uv (outside /home/agent) keeps the warm cache safe from the named
# state volume that mounts over /home/agent at runtime. The ENV vars are
# inherited by every container process, so when the agent user runs
# `uvx mcp-atlassian`, uv finds the pre-installed tool instead of
# re-downloading.
ENV UV_TOOL_DIR=/opt/uv/tools \
    UV_CACHE_DIR=/opt/uv/cache
RUN mkdir -p /opt/uv \
 && uv tool install --python python3 mcp-atlassian \
 && uv tool install --python python3 mcp-server-fetch \
 && uv tool install --python python3 mcp-server-time \
 && chown -R ${UID}:${GID} /opt/uv

# Install bun (required by the official telegram plugin which ships a bun-
# runtime MCP server, and useful for any other modern JS tooling).
ARG BUN_VERSION=1.1.38
RUN set -eux; \
    apk add --no-cache libgcc libstdc++; \
    apk add --no-cache --virtual .bun-unpack unzip; \
    arch=$(uname -m); \
    case "$arch" in \
      x86_64) bun_arch="x64" ;; \
      aarch64) bun_arch="aarch64" ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION}/bun-linux-${bun_arch}-musl.zip" \
      -o /tmp/bun.zip; \
    unzip -q /tmp/bun.zip -d /tmp; \
    mv "/tmp/bun-linux-${bun_arch}-musl/bun" /usr/local/bin/bun; \
    chmod +x /usr/local/bin/bun; \
    rm -rf /tmp/bun.zip "/tmp/bun-linux-${bun_arch}-musl"; \
    apk del .bun-unpack; \
    bun --version

# Install Claude Code CLI globally so both root (for first-run chown) and
# the `agent` user can invoke it. Pinned via build arg so rebuilds are
# reproducible — override with `docker build --build-arg CLAUDE_CODE_VERSION=...`
# or pass through compose's `build.args` to track upstream releases.
ARG CLAUDE_CODE_VERSION=2.1.119
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

# Create the non-root agent user matching host UID/GID.
# Release pre-existing groups/users that already hold the target GID/UID
# (e.g. alpine ships dialout=20, which collides with mac's staff=20) so
# `agent` can claim the exact host numeric ownership — required for bind-
# mount writes to show the expected owner on the host.
RUN set -eux; \
    if getent group "$GID" >/dev/null; then \
      delgroup "$(getent group "$GID" | cut -d: -f1)"; \
    fi; \
    if getent passwd "$UID" >/dev/null; then \
      deluser "$(getent passwd "$UID" | cut -d: -f1)"; \
    fi; \
    addgroup -g "$GID" agent; \
    adduser -D -u "$UID" -G agent -s /bin/bash agent

# Copy in the in-image scripts (baked at build time, read-only at runtime).
COPY entrypoint.sh /opt/agent-admin/entrypoint.sh
COPY crontab.tpl /opt/agent-admin/crontab.tpl
COPY scripts/start_services.sh /opt/agent-admin/scripts/start_services.sh
COPY scripts/wizard-container.sh /opt/agent-admin/scripts/wizard-container.sh
COPY scripts/write_container_info.sh /opt/agent-admin/scripts/write_container_info.sh
COPY scripts/apply_telegram_typing_patch.py /opt/agent-admin/scripts/apply_telegram_typing_patch.py
RUN chmod +x /opt/agent-admin/entrypoint.sh \
             /opt/agent-admin/scripts/start_services.sh \
             /opt/agent-admin/scripts/wizard-container.sh \
             /opt/agent-admin/scripts/write_container_info.sh \
             /opt/agent-admin/scripts/apply_telegram_typing_patch.py

# Heartbeat CLI and helper libs (image-baked, stable code).
COPY scripts/heartbeatctl /opt/agent-admin/scripts/heartbeatctl
COPY scripts/lib/interval.sh /opt/agent-admin/scripts/lib/interval.sh
COPY scripts/lib/state.sh    /opt/agent-admin/scripts/lib/state.sh
# Fault-tolerance primitives + the per-subsystem health libs that
# compose on top. Sourced best-effort by heartbeatctl and
# start_services.sh — keep in sync with the source guards there if
# the path ever moves.
COPY scripts/lib/safe-exec.sh    /opt/agent-admin/scripts/lib/safe-exec.sh
COPY scripts/lib/token-health.sh /opt/agent-admin/scripts/lib/token-health.sh
COPY scripts/lib/mcp-health.sh   /opt/agent-admin/scripts/lib/mcp-health.sh
RUN chmod +x /opt/agent-admin/scripts/heartbeatctl \
  && ln -s /opt/agent-admin/scripts/heartbeatctl /usr/local/bin/heartbeatctl

# Plugin catalog. plugin-catalog.sh is shared between host-side scaffold
# and container runtime. Build context is ./docker/, so setup.sh mirrors
# scripts/lib/plugin-catalog.sh and modules/plugins/ into docker/ before
# `docker compose build`. See `setup.sh::mirror_catalog_to_docker`.
COPY scripts/lib/plugin-catalog.sh /opt/agent-admin/scripts/lib/plugin-catalog.sh
COPY modules/plugins/ /opt/agent-admin/modules/plugins/

# Vault assets. Same mirroring scheme as plugin-catalog.sh. The skeleton is
# the source of truth for the per-agent vault, copied into <vault_path> at
# first boot if vault.enabled and vault.seed_skeleton are true (and the dir
# is empty). vault.sh is sourced by start_services.sh for boot-time seed.
COPY scripts/lib/vault.sh /opt/agent-admin/scripts/lib/vault.sh
COPY modules/vault-skeleton/ /opt/agent-admin/modules/vault-skeleton/

# MCP catalog. Same mirroring scheme as plugin-catalog.sh — descriptors
# at modules/mcps/<id>.yml power the wizard prompts and identify which
# MCP servers each agent has enabled. Mirrored into docker/ by
# setup.sh::mirror_catalog_to_docker.
COPY scripts/lib/mcp-catalog.sh /opt/agent-admin/scripts/lib/mcp-catalog.sh
COPY modules/mcps/ /opt/agent-admin/modules/mcps/

# Sanity check: the COPYs above succeed even if the source dirs are
# present-but-empty (e.g. a future bug in mirror_catalog_to_docker that
# creates the dir but skips the contents). Catch that here so the agent
# doesn't boot with a half-baked image and silently fail at first run —
# which is exactly the kind of bug the rsync→cp -R fix in PR #17 surfaced.
RUN test -f /opt/agent-admin/modules/vault-skeleton/CLAUDE.md \
 && test -d /opt/agent-admin/modules/vault-skeleton/wiki \
 && test "$(ls -A /opt/agent-admin/modules/plugins/*.yml 2>/dev/null | wc -l)" -gt 0 \
 && test "$(ls -A /opt/agent-admin/modules/mcps/*.yml 2>/dev/null | wc -l)" -gt 0 \
 || (echo "ERROR: image build is missing mirrored assets. Run './setup.sh --regenerate' from the workspace root before 'docker compose build'." >&2; exit 1)

# Workspace is bind-mounted at runtime; /home/agent is a named volume.
WORKDIR /workspace

# tini is PID 1; entrypoint.sh runs as root briefly, drops to agent.
ENTRYPOINT ["/sbin/tini", "--", "/opt/agent-admin/entrypoint.sh"]
