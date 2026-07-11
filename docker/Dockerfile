# syntax=docker/dockerfile:1.6
# Base image — overridable via build arg (recorded in agent.yml docker.base_image
# and passed through by docker-compose). Default tracks the latest stable Alpine;
# keep in sync with scripts/lib/versions.sh (a bats drift-guard enforces it).
ARG BASE_IMAGE=alpine:3.24.1
FROM ${BASE_IMAGE}

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
      age \
      flock \
      inotify-tools \
      tzdata

# 016 (BUG 4): qmd's native deps (node-llama-cpp embeddings, better-sqlite3) build
# from source at RUNTIME via `bun install` — no musl prebuild exists, and the
# .state bind-mount masks anything baked under /home/agent, so the toolchain must
# live in the FINAL image (a throwaway builder stage cannot help). Gated by a
# build-arg so the DOCKER_E2E RED test can build a toolchain-less image. `apk cmake`
# on PATH makes node-llama-cpp use it (never its glibc xpack download). bigstack.so
# (8MB pthread stacks) mitigates the musl std::regex/stack SIGSEGV at embed time.
ARG QMD_NATIVE_TOOLCHAIN=1
# 017: sqlite-vec (the vec0 vector extension for `qmd embed`) ships only a GLIBC
# prebuilt that cannot dlopen under musl — the THIRD native module of the embed
# path, missed by 016. Compile it for musl from the pinned amalgamation and bake
# it here; qmd_index.sh swaps it into the managed prefix at runtime. Same gate as
# the toolchain (a QMD_NATIVE_TOOLCHAIN=0 build omits it → DOCKER_E2E RED).
ARG SQLITE_VEC_VERSION=0.1.9
COPY bigstack.c /opt/agent-admin/bigstack.c
COPY scripts/build-sqlite-vec.sh /opt/agent-admin/scripts/build-sqlite-vec.sh
RUN if [ "$QMD_NATIVE_TOOLCHAIN" = "1" ]; then \
      apk add --no-cache build-base cmake linux-headers libgomp; \
      gcc -shared -fPIC -o /opt/agent-admin/bigstack.so /opt/agent-admin/bigstack.c -ldl; \
      SQLITE_VEC_VERSION="$SQLITE_VEC_VERSION" sh /opt/agent-admin/scripts/build-sqlite-vec.sh; \
    fi

# Install gum from the charmbracelet tap alternative: use the static binary.
ARG GUM_VERSION=0.17.0
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
ARG UV_VERSION=0.11.22
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
# UV_PYTHON_PREFERENCE=only-system: uv >=0.8.0 validates that discovered
# interpreters match the python preference and may otherwise auto-download a
# managed CPython, which would defeat the warm /opt/uv cache and break the
# offline MCP handshake. Pin uv to the apk-installed system python3.
ENV UV_TOOL_DIR=/opt/uv/tools \
    UV_CACHE_DIR=/opt/uv/cache \
    UV_PYTHON_PREFERENCE=only-system
RUN mkdir -p /opt/uv \
 && uv tool install --python python3 mcp-atlassian \
 && uv tool install --python python3 mcp-server-fetch \
 && uv tool install --python python3 mcp-server-time \
 && chown -R ${UID}:${GID} /opt/uv

# Install bun (required by the official telegram plugin which ships a bun-
# runtime MCP server, and useful for any other modern JS tooling).
ARG BUN_VERSION=1.3.14
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
    # 013 FR-016: the bun zip ships only `bun`, but qmd_index.sh and the qmd MCP
    # invoke `bunx` — without this symlink QMD in docker never ran against real
    # binaries (the e2e stubs bunx, which masked the gap since feature 010). The
    # local bootstrap already makes the same symlink into ~/.local/bin.
    ln -sf /usr/local/bin/bun /usr/local/bin/bunx; \
    rm -rf /tmp/bun.zip "/tmp/bun-linux-${bun_arch}-musl"; \
    apk del .bun-unpack; \
    bun --version; \
    bunx --version

# Install GitHub's official github-mcp-server Go binary (feature 004/US3),
# replacing the deprecated `npx @modelcontextprotocol/server-github`. The Linux
# release assets are STATICALLY linked (verified `file` → "statically linked"),
# so they run on Alpine/musl with no extra apk packages — exactly like the
# gum/uv/bun blocks. Baked into /usr/local/bin (outside /home/agent, so the
# .state bind-mount can't shadow it) and invoked `github-mcp-server stdio`,
# authenticating via GITHUB_PERSONAL_ACCESS_TOKEN. Pinned via ARG (tracked in
# scripts/lib/versions.sh; a bats drift-guard enforces ARG==floor). Checksum
# verified before use.
ARG GH_MCP_VERSION=1.4.0
RUN set -eux; \
    arch=$(uname -m); \
    case "$arch" in \
      x86_64) gh_arch="x86_64" ;; \
      aarch64) gh_arch="arm64" ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    cd /tmp; \
    base="https://github.com/github/github-mcp-server/releases/download/v${GH_MCP_VERSION}"; \
    curl -fsSL -O "${base}/github-mcp-server_Linux_${gh_arch}.tar.gz"; \
    curl -fsSL -O "${base}/github-mcp-server_${GH_MCP_VERSION}_checksums.txt"; \
    grep "github-mcp-server_Linux_${gh_arch}.tar.gz" "github-mcp-server_${GH_MCP_VERSION}_checksums.txt" | sha256sum -c -; \
    tar -xzf "github-mcp-server_Linux_${gh_arch}.tar.gz" github-mcp-server; \
    mv github-mcp-server /usr/local/bin/github-mcp-server; \
    chmod +x /usr/local/bin/github-mcp-server; \
    rm -f "github-mcp-server_Linux_${gh_arch}.tar.gz" "github-mcp-server_${GH_MCP_VERSION}_checksums.txt"; \
    github-mcp-server --version

# Install Claude Code CLI globally so both root (for first-run chown) and
# the `agent` user can invoke it. Pinned via build arg so rebuilds are
# reproducible — override with `docker build --build-arg CLAUDE_CODE_VERSION=...`
# or pass through compose's `build.args` to track upstream releases.
ARG CLAUDE_CODE_VERSION=2.1.170
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

# Pre-warm the npm-based MCP servers the template wires via npx (filesystem,
# vault). Same rationale as the uv /opt block above: a download inside Claude's
# MCP handshake window times out, and on macOS Docker Desktop the npm cache's
# thousands of small-file create/rename/rmdir ops fail outright on the VirtioFS
# bind-mount that backs /home/agent (errno -35 / ENOTEMPTY). NPM_CONFIG_CACHE
# moves BOTH the content cache (_cacache) and the npx install dir (_npx) to
# /opt/npm-cache — off the bind-mount — and PREFER_OFFLINE lets the runtime npx
# resolve the warmed version with no registry round-trip. `npm exec -- true`
# downloads each package without launching its stdio server (which would hang
# the build); `|| true` keeps the warm fail-soft. Pinned via ARG (tracked in
# scripts/lib/versions.sh; a bats drift-guard enforces ARG==floor) so the
# runtime spec matches the warmed spec — a version mismatch silently defeats
# the warm hit. Numeric chown like the uv block (the agent user does not exist
# yet). These ENV vars are inherited by every container process.
ARG MCP_FILESYSTEM_VERSION=2026.1.14
ARG MCP_VAULT_VERSION=0.12.0
ENV NPM_CONFIG_CACHE=/opt/npm-cache \
    NPM_CONFIG_PREFER_OFFLINE=true
RUN set -eux; \
    mkdir -p /opt/npm-cache; \
    npm exec -y --package="@modelcontextprotocol/server-filesystem@${MCP_FILESYSTEM_VERSION}" -- true || true; \
    npm exec -y --package="@bitbonsai/mcpvault@${MCP_VAULT_VERSION}" -- true || true; \
    chown -R ${UID}:${GID} /opt/npm-cache

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
COPY scripts/qmd_watch.sh /opt/agent-admin/scripts/qmd_watch.sh
# 016 (T036): the qmd MCP server launches from the managed prefix via this wrapper
# (qmd_index.sh::qmd_mcp_exec), not `bunx` — .mcp.json's qmd command points here.
COPY scripts/qmd-mcp /opt/agent-admin/scripts/qmd-mcp
RUN chmod +x /opt/agent-admin/entrypoint.sh \
             /opt/agent-admin/scripts/start_services.sh \
             /opt/agent-admin/scripts/wizard-container.sh \
             /opt/agent-admin/scripts/write_container_info.sh \
             /opt/agent-admin/scripts/apply_telegram_typing_patch.py \
             /opt/agent-admin/scripts/qmd_watch.sh \
             /opt/agent-admin/scripts/qmd-mcp

# Heartbeat CLI and helper libs (image-baked, stable code).
COPY scripts/heartbeatctl /opt/agent-admin/scripts/heartbeatctl
COPY scripts/lib/interval.sh /opt/agent-admin/scripts/lib/interval.sh
COPY scripts/lib/state.sh    /opt/agent-admin/scripts/lib/state.sh
COPY scripts/lib/backup_identity.sh /opt/agent-admin/scripts/lib/backup_identity.sh
COPY scripts/lib/backup_vault.sh    /opt/agent-admin/scripts/lib/backup_vault.sh
COPY scripts/lib/backup_config.sh   /opt/agent-admin/scripts/lib/backup_config.sh
COPY scripts/lib/token_health.sh    /opt/agent-admin/scripts/lib/token_health.sh
COPY scripts/lib/plugin-install.sh /opt/agent-admin/scripts/lib/plugin-install.sh
COPY scripts/lib/qmd_index.sh       /opt/agent-admin/scripts/lib/qmd_index.sh
COPY scripts/lib/wiki_graph.sh      /opt/agent-admin/scripts/lib/wiki_graph.sh
COPY scripts/lib/rag_obs.sh         /opt/agent-admin/scripts/lib/rag_obs.sh
COPY scripts/check_token_health.sh  /opt/agent-admin/scripts/check_token_health.sh
RUN chmod +x /opt/agent-admin/scripts/heartbeatctl \
              /opt/agent-admin/scripts/check_token_health.sh \
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
# feature 014: schema-delta dir for the additive upgrade of pre-populated vaults
# (start_services.sh::seed_vault_if_needed → vault_seed_missing). Mirrored into
# docker/ by setup.sh::mirror_catalog_to_docker before the build.
COPY modules/vault-deltas/ /opt/agent-admin/modules/vault-deltas/

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
