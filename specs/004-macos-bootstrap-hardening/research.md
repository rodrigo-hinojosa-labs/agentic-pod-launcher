# Phase 0 Research: 004-macos-bootstrap-hardening

All three fixes are image-baked (`docker/`). Verification facts below were checked against the npm registry, GitHub releases, npm v11 docs, and the repo source (not assumed) — see each "Verified" note. The unverifiable bits (live MCP handshake, exact binary stdout) are explicitly deferred to `DOCKER_E2E`.

---

## US1 (P1) — npx MCPs warm off the bind-mount

**Decision**: Warm the npm cache at a fixed off-bind-mount path during the image build, then point runtime npx at it.
1. `ENV NPM_CONFIG_CACHE=/opt/npm-cache` (moves BOTH `_cacache` and the `_npx` install dir off `/home/agent`) + `ENV NPM_CONFIG_PREFER_OFFLINE=true`.
2. A `RUN` step that executes `npx -y <pkg@pinned>` once per **default** npx MCP package so `_cacache` + `_npx` land warm.
3. `chown -R ${UID}:${GID} /opt/npm-cache` (numeric, like the uv block — works before the agent user exists).
4. In `modules/mcp-json.tpl`, **pin** the vault spec (drop `@latest`) so the runtime spec string equals the build-time warmed spec — the `_npx` dir is keyed by resolved spec, and `@latest` forces a registry dist-tag lookup that defeats the warm hit even under prefer-offline.

**Scope correction (verified)**: the default npx MCPs rendered by `mcp-json.tpl` are **`filesystem`** (always) and **`vault`** (conditional on `VAULT_MCP_ENABLED`). **`context7` is a PLUGIN** (`modules/plugins/context7.yml` → `context7@claude-plugins-official`), not an `mcp-json` npx MCP — P1's mcp-json/Dockerfile warm does not target it (the spec wrongly listed it). Opt-in catalog npx MCPs (playwright, firecrawl, google-calendar) are out of default-warm scope per the spec; `prefer-offline` (not hard `--offline`) keeps a network fallback for them.

**Rationale**: `npx -y` does NOT consult globally `-g`-installed packages (npm v11 docs) — so `npm install -g` + PATH cannot guarantee a network skip. cacache is content-addressed; `--prefer-offline` bypasses staleness checks when the version is cached. Mirrors the proven uv `/opt` pattern (Dockerfile ~95-102) that already cures the handshake-window timeout for Python MCPs.

**Alternatives**: (a) `npm install -g` — rejected (npx ignores globals). (c) install + call the bin directly (`mcp-server-filesystem`, `mcpvault` — bin names verified) — viable and most bulletproof, **kept as fallback** if DOCKER_E2E shows prefer-offline still does a metadata round-trip for an exact-pinned cached spec (known npm bug npm/cli#7295). Hard `npx --offline` in the template — rejected (breaks future opt-in npx MCPs).

**Verified**: `@modelcontextprotocol/server-filesystem` NOT deprecated (latest 2026.1.14, bin `mcp-server-filesystem`); `@bitbonsai/mcpvault` NOT deprecated (latest 0.12.0, bin `mcpvault`); `@modelcontextprotocol/server-github` IS deprecated (confirms US3). npx resolution facts per npm v11 docs.

**Risks**: (1) spec mismatch `@latest` vs pinned silently defeats the warm hit — pin both sides identically (the single most likely failure mode). (2) prefer-offline metadata round-trip bug → fallback to direct-bin. (3) chown timing → numeric `${UID}:${GID}`. (4) a server bin that hangs on stdio during the build warm → guard with `|| true` + `--help`/`--version` or `npm exec -- true`. (5) Principle VI drift → record the npm MCP pins so the existing Dockerfile-vs-`versions.sh` drift guard covers them.

---

## US2 (P2) — post-login plugin-install resilience

**Decision**: Add a **non-blocking, tick-based** post-login retry in the watchdog, not a blocking loop and not a per-tick re-kick.
- Today: `_check_auth_flip` (start_services.sh:824) detects the credential flip and `tmux kill-session`s once; the respawn runs `ensure_all_plugins_installed` **exactly once**. If the profile isn't operative yet, `retry_plugin_install_bounded` matches the `not authenticated` regex (plugin-install.sh:38) and returns 2 (no-retry); the watchdog never re-runs the install (no further respawn), so plugins stay uninstalled.
- Fix: when `_check_auth_flip` fires, set `_post_login_deadline = now + PLUGIN_POSTLOGIN_BUDGET` (default **120s**). A new `_post_login_plugin_retry` runs each 2s watchdog tick: while `now < deadline` and not all plugins carry their `.installed-ok` sentinel, call `ensure_all_plugins_installed` (idempotent — installed plugins short-circuit on the sentinel). When all are installed → `tmux kill-session` **once** so the respawn launches with `--channels`, then clear the deadline. When the deadline elapses → clear the deadline (residual failures were already recorded by `ensure_plugin_installed_one`/`_plugin_record_failure` for `agentctl doctor`).

**Rationale**: each failed-by-not-auth install returns in ~1s, so per-tick retries don't materially block the 2s poll (crond-death detection lag stays small and only during the ≤120s window). No per-tick re-kick → no churn against the crash budget (5/300s). `not authenticated` stays a *transient* signal post-flip because the tick simply tries again next cycle; once the profile is operative the install succeeds and the single kick attaches the channel.

**Alternatives**: (1) blocking 120s loop inside the lib — rejected (starves crond-death detection for up to 120s). (2) re-kick each tick (the research agent's first idea) — rejected (hits the crash budget). (3) drop the not-auth regex entirely — rejected (it correctly suppresses pre-login noise; only the *post-flip* window needs the transient treatment, which the deadline provides).

**Test seams**: `plugin-install.sh` is sourced directly by host bats. `start_services.sh` has the `START_SERVICES_NO_RUN=1` + `AUTH_MARKER_OVERRIDE` + mocked-`claude` seams (used by the Story A tests) — `_post_login_plugin_retry` and an `_all_plugins_installed` helper are host-testable with a `claude` stub + sentinel files + a `tmux` stub. Full real post-login flow → DOCKER_E2E.

**Risks**: re-kick churn (mitigated: kick once, only on success). A plugin that legitimately never installs (dead marketplace) must still let the deadline elapse and record the failure — covered by the existing record path.

---

## US3 (P3) — GitHub MCP → official Go binary

**Decision**: Bake GitHub's official `github-mcp-server` Go binary (pinned `v1.4.0`) into `/usr/local/bin` and invoke it via stdio.
1. Dockerfile stanza modeled on the gum/uv/bun blocks: map `uname -m` → release arch (`x86_64`→`x86_64`, `aarch64`→`arm64`), download `github-mcp-server_Linux_${arch}.tar.gz` + `github-mcp-server_${VERSION}_checksums.txt` from the `v${GH_MCP_VERSION}` release, `sha256sum -c`, extract the single `github-mcp-server` binary to `/usr/local/bin`, `chmod +x`, run `github-mcp-server --version` as a build sanity check. Pin via `ARG GH_MCP_VERSION=1.4.0`.
2. `modules/mcp-json.tpl` github block: `command` `npx`→`github-mcp-server`, `args` `["-y","@modelcontextprotocol/server-github"]`→`["stdio"]`. **Keep** `env.GITHUB_PERSONAL_ACCESS_TOKEN: ${GITHUB_PAT}` verbatim (and the `{{#if MCPS_GITHUB_ENABLED}}` guard).
3. **Keep** the `.env` var name `GITHUB_PAT` — the server reads `GITHUB_PERSONAL_ACCESS_TOKEN`, which the template already maps from `${GITHUB_PAT}`; renaming would churn `check_token_health.sh`, `token_health.sh`, `setup.sh`, `wizard-container.sh`, `env-example.tpl`, and their bats for no gain.

**Rationale / biggest unknown RESOLVED**: the musl/Alpine question is moot — both Linux v1.4.0 assets are **statically-linked** ELF (`file` reports "statically linked, stripped" for x86-64 and aarch64), so they run on Alpine 3.24 with no extra apk packages, exactly like gum/uv/bun. No node_modules, no runtime download in the handshake window. Single ~23MB binary in `/usr/local/bin` (outside `/home/agent`, so the `.state` bind-mount can't shadow it).

**Alternatives**: (1) pre-warm the deprecated npx package — rejected (it's deprecated AND errors "Permission denied"). (2) official Docker image `ghcr.io/github/github-mcp-server` — rejected (needs docker-in-docker / socket mount → violates the least-privilege model). (3) `go install` at build — rejected (pulls a Go toolchain for one binary). (4) rename `GITHUB_PAT` — rejected (gratuitous cross-file churn).

**Verified** (commands run / sources fetched 2026-06-21): npm package deprecated on all 13 versions incl. latest 2025.4.8. Latest official release `v1.4.0` (2026-06-18); assets `github-mcp-server_Linux_{arm64,x86_64}.tar.gz` + `github-mcp-server_1.4.0_checksums.txt`. Both Linux binaries statically linked (`file`); checksums validate (`sha256sum -c`). stdio invocation `github-mcp-server stdio`; auth env `GITHUB_PERSONAL_ACCESS_TOKEN`; version via `--version` flag (only `stdio`/`http` subcommands registered in `cmd/github-mcp-server/main.go@v1.4.0`). Optional scoping flags `--read-only` / `GITHUB_TOOLSETS` exist (not enabled by default).

**Risks**: version-drift guard (`versions.bats` expects Dockerfile ARG defaults to track `versions.sh` floors) — either add a `gh_mcp` channel/floor to `versions.sh` or scope the guard for a hard pin. `--version` exact stdout/exit and live MCP handshake → DOCKER_E2E (could not exec a Linux ELF on the macOS host). GoReleaser asset-name stability pinned by the ARG.

---

## Cross-cutting decisions

- **Pinning (Principle VI)**: record the npm MCP versions (`server-filesystem`, `mcpvault`) and `github-mcp-server` as build ARGs AND in the repo's version-tracking (`versions.sh` floors or an explicit pin path) so the existing Dockerfile-vs-`versions.sh` drift-guard bats test stays meaningful. Decide per-tool: channel-resolved (like uv/bun) vs hard pin.
- **Source of truth (Principle I)**: every `.mcp.json` change is rendered from `agent.yml` via `mcp-json.tpl`; the vault pin and the github command/args are template edits, so they survive `--regenerate`.
- **CHANGELOG/VERSION (FR-010)**: one `### Fixed`/`### Changed` block covering all three; bump `VERSION` 0.2.1 → next.
- **Verification split**: default no-Docker bats assert the Dockerfile/template *shape* (env vars set, warm step present, github command flipped, vault unpinned-`@latest` gone, retry budget knob); `DOCKER_E2E=1` asserts the *behavior* (npx MCPs connect warm, github binary runs, plugins install post-login).
