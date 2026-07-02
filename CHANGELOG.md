# Changelog

## [Unreleased]

### Added
- **Local standalone mode** (`011-local-standalone-mode`): a second wizard
  **deployment mode** (`deployment.mode: docker|local` in `agent.yml`). Docker
  (recommended) is **byte-identical** to before; local (opt-in, security-warned,
  **Linux/systemd only**) renders the agent config base directly on the host —
  no `docker-compose.yml`/Dockerfile — and persists a `claude remote-control`
  session under systemd. Specced with GitHub Spec Kit under
  `specs/011-local-standalone-mode/`. **VERSION 0.4.4 → 0.5.0.**
  - **(US1)** Wizard mode choice (`docker` first/recommended, `local` second with
    an explicit security warning). `deployment.mode` is the single source of
    truth — validated by `schema.sh` (enum `docker|local`, optional, legacy-safe),
    backfilled to `docker` on `--regenerate`, and surfaced as
    `DEPLOYMENT_MODE_IS_DOCKER` to the render engine. Local scaffolds skip ALL
    Docker artifacts (no compose, no `docker/` build context); `CLAUDE.md` and
    `NEXT_STEPS` are mode-aware. A mode switch on `--regenerate` **warns** about
    the now-orphaned artifacts of the previous mode and never deletes them
    (FR-005a).
  - **(US2)** Persistent Remote Control session via a **system** systemd unit
    (`/etc/systemd/system/agent-<name>.service`): `Type=simple`,
    `Restart=always`/`RestartSec=10`, restart budget 5/300s, `ExecCondition` on
    `.credentials.json` (stays inactive — not failed — until login),
    `WorkingDirectory`=workspace, `EnvironmentFile`, `User`=the operator's login
    user, `ExecStart=claude remote-control --name <hostname>-<name>
    --spawn=session --verbose`; **never** `--dangerously-skip-permissions`. A
    guided one-time login helper (`./setup.sh --login`) verifies Claude Code
    ≥ 2.1.51, pre-seeds onboarding non-destructively, launches the full-scope
    OAuth login, then applies an idempotent, exact-equality `.claude.json`
    trust-merge (`scripts/lib/local_trust.sh`), **pre-accepts the "Enable Remote
    Control? (y/n)" prompt** (seeds `remoteDialogSeen=true`, non-destructively) —
    without it the headless unit blocks forever on that interactive prompt (no
    TTY), never registers, and shows offline in the app (gotcha #7, validated on
    mclaren) — and **installs the staged systemd session unit and the healthcheck
    timer/service if they aren't in place yet** — the scaffold stages them in the
    workspace when `sudo -n` is unavailable, so `--login` (the first
    interactive-sudo context) copies them into the systemd dir and enables them
    instead of leaving a staged-but-inactive unit + an inactive ~5-min
    healthcheck timer (both regressions validated on a sudo-prompt host). Plus an
    `EnvironmentFile` (`CLAUDE_CONFIG_DIR` under `.state/.claude`,
    `DISABLE_AUTOUPDATER=1`, no API key) and a kill-switch helper.
  - **(US3)** Healthcheck (systemd timer ~5 min) distinguishing
    alive/connected/expired (`systemctl is-active` + journal 401/connection
    signals + `expiresAt` via `jq`), degrading gracefully without `jq`/creds;
    optional notify keeps the token off argv (`curl --config -`). `agentctl`
    degrades honestly in local mode — Docker-only subcommands error with a
    `systemctl`/`journalctl` hint (never touching docker) and `status`/`doctor`
    read systemd + the on-disk login.
  - **(MCP runtimes)** Local mode now makes the workspace MCP servers actually
    **runnable** on the host. Docker bakes uv/node/bun/`github-mcp-server` into
    the image; local mode rendered `.mcp.json` but never provisioned them, so
    every project MCP failed to connect (validated on mclaren:
    `fetch`/`git`/`filesystem`/`atlassian`/`github` → "✘ Failed to connect" —
    `uvx`/`npx`/`github-mcp-server` absent from every PATH). Three fixes:
    **(a)** `.mcp.json` remaps the container paths `git --repository /workspace`
    and `filesystem /home/agent` to the real `deployment.workspace` in local mode
    (keyed on `DEPLOYMENT_MODE_IS_DOCKER`; docker byte-identical); **(b)** the
    session `EnvironmentFile` pins `PATH` at the operator's `~/.local/bin` (the
    unit otherwise inherits systemd's minimal PATH, which excludes every runtime);
    **(c)** a new rendered `scripts/local/agent-bootstrap.sh` provisions exactly
    the runtimes the `.mcp.json` references — uv/uvx (+ warm `uv tool install`),
    node/npx symlinks (nvm or system), `github-mcp-server` (checksum-verified),
    bun — into `~/.local/bin`. Idempotent + best-effort (never blocks login), run
    by `--login` before the unit is enabled; `BOOTSTRAP_DRY_RUN=1` prints the plan
    for the host-side bats suite. Version pins mirror the Dockerfile
    (uv 0.11.22 / bun 1.3.14 / github-mcp-server 1.4.0). Vault/qmd container
    paths in local mode are a follow-up.
  - SECURITY: local mode is a justified, opt-in violation of the least-privilege
    container model (Principle II) — it runs as the operator's user and inherits
    their privileges/secrets; the wizard warns explicitly and MFA is mandatory.
    Secrets (`.credentials.json`, `*.env`) live under `.state/` and are never
    committed. Linux/systemd integration is validated by a documented manual host
    gate (not exercisable by DOCKER_E2E on macOS).
- **Self-managing RAG** (`010-self-managing-rag`): when `vault.qmd.enabled=true`,
  the QMD semantic-search engine over the agent's Obsidian vault now sets itself
  up and stays fresh with zero manual steps (opt-in; zero cost when disabled).
  Specced with GitHub Spec Kit under `specs/010-self-managing-rag/`.
  - **(US1)** Auto-setup at boot: `qmd_setup_if_needed`
    (`docker/scripts/lib/qmd_index.sh`) downloads the embedding model + builds the
    index on first boot, run **backgrounded + timeout-bounded** from
    `boot_side_effects` so it never blocks the watchdog (Principle IV). Idempotent
    by sentinel + `index.sqlite` presence. Model/index live under
    `~/.cache/qmd/` → durable in `.state` (download at first boot, since the
    bind-mount shadows a pre-baked home).
  - **(US2)** Dual-trigger auto-reindex: an inotify watcher
    (`docker/scripts/qmd_watch.sh`, new `inotify-tools` dependency) with ~15s
    debounce for immediacy, plus a `*/5` cron backstop line in `heartbeatctl
    reload` — both route through one `heartbeatctl qmd-reindex` → `qmd_reindex`,
    which is `flock`-guarded (concurrency-safe) and hash-debounced (reuses
    `backup_vault.sh::vault_hash`; skips the costly embed when the vault is
    unchanged). The watcher captures changes from MCPVault, native Write/Edit,
    and Syncthing; it is respawned by a deterministic PID-liveness check in the
    2s watchdog poll (NOT the reverted heuristic bridge watchdog). State in
    `scripts/heartbeat/qmd-index.json`.
  - **(US3)** Reproducible pin: `@tobilu/qmd` is pinned to **`2.5.3`** (the
    floating `@latest` is gone), single-sourced via `agent.yml`
    `vault.qmd.version` (rendered into `.mcp.json` and read by the lib — no
    duplicate pin, Principle VI). `schema.sh` now validates
    `vault.qmd.{enabled,version,schedule}`.
  - NOTE: the previously-assumed `@tobilu/qmd@0.4.4` does not exist on npm; the
    research phase corrected the pin to the actual latest stable, `2.5.3`.
    `inotify` under the macOS VirtioFS bind-mount may not deliver host-origin
    events; the cron backstop covers that. The derived index is intentionally
    NOT added to `backup/vault` (it is regenerable from the markdown).
- **Headless bootstrap** (`006-headless-bootstrap`): a scaffolded agent boots
  fully operational WITHOUT interactive `/login`, which does not persist in the
  headless container — VirtioFS cache incoherence on the `~/.claude` bind-mount
  drops the credential, so `/login` completes server-side ("Login successful")
  but reverts to "Not logged in" on every boot. Specced with GitHub Spec Kit
  under `specs/006-headless-bootstrap/`.
  - **(US1)** Headless auth via `CLAUDE_CODE_OAUTH_TOKEN` (from `claude
    setup-token`) placed in `.env`, which docker-compose injects via `env_file`
    — no dependency on `~/.claude` persistence. The supervisor recognizes the
    token (`has_oauth_token`): `next_tmux_cmd` never falls back to the
    bare-claude `/login` path when a token is present, and `_check_auth_flip`
    treats the agent as already-authenticated (no spurious session kick from a
    stray `.credentials.json`). The generated `.env` and `.env.example` carry a
    `CLAUDE_CODE_OAUTH_TOKEN=` placeholder; the token stays out of `agent.yml`.
    NEXT_STEPS (en/es) document the headless path as recommended, `/login` as
    fallback.
  - **(US2)** The official marketplace `anthropics/claude-plugins-official` is
    registered idempotently at boot (`ensure_official_marketplace`) before
    installing plugins — headless token auth skips the interactive onboarding
    that used to seed it, so without this no `@claude-plugins-official` plugin
    (incl. the Telegram channel) could install.
  - **(US3)** First-run onboarding (theme picker + per-directory trust) is
    pre-seeded in `~/.claude/.claude.json` (`pre_seed_onboarding`), and
    `settings.json` is now created when absent, so the headless TUI session
    isn't blocked before the first launch.
  - **(US4)** The watchdog log distinguishes "marketplace not found" from "not
    authenticated" (`retry_plugin_install_bounded`), instead of the catch-all
    that conflated the two and burned the retry budget.
  - The token lives only in `.env` (0600, and encrypted `.env.age` in identity
    backup); relocating `~/.claude` to a named volume is out of scope (it would
    re-introduce the `down -v` login-wipe that PR #3 removed).

### Fixed
- **Third-party marketplace plugin install at boot**
  (`009-fix-extra-marketplace-install`): a plugin declared in `agent.yml` that
  lives in a third-party marketplace (e.g. `claude-mem@thedotmack`) was never
  auto-installed at boot — found during the 2026-06-23 declarative re-scaffold of
  rodri-cenco-admin (5/6 plugins installed, claude-mem did not). Root cause
  (runtime log + code): a registration asymmetry. The official marketplace is
  registered with `claude plugin marketplace add` AND confirmed via
  `marketplace list` (`ensure_official_marketplace`), but third-party
  marketplaces were only merged into `settings.json`'s `extraKnownMarketplaces`
  by `pre_accept_extra_marketplaces` (no `add`, no confirm). So the immediate
  `claude plugin install claude-mem@thedotmack` errored "marketplace not found",
  `retry_plugin_install_bounded` returned 2 (skip, no retry), and because the
  steady-state tmux session never respawns, `ensure_all_plugins_installed` never
  re-ran → the plugin stayed permanently absent.
  - **(US1)** New `ensure_extra_marketplaces` in `docker/scripts/start_services.sh`
    resolves each declared third-party marketplace with a confirmed
    `claude plugin marketplace add <repo>` (mirror of `ensure_official_marketplace`),
    chained in `next_tmux_cmd` before the install loop, so the plugin installs at
    boot with no manual `plugin install`.
  - **(US2)** Each `claude` call in the new helper is bounded by
    `timeout ${MARKETPLACE_CMD_TIMEOUT:-12}` (degrades to a direct call if absent)
    and is idempotent + fail-silent (guarded by `marketplace list`; always
    returns 0) — a slow git clone over VirtioFS can never hang the boot before
    the watchdog (Principle IV).
  - **(US3)** `tests/docker-e2e-postlogin.bats` now declares a third-party plugin
    and its `claude` stub models marketplace resolution (a plugin only installs
    once its marketplace was `add`-ed), closing the E2E gap that hid the bug
    (the suite previously exercised only `@claude-plugins-official`).
  - Test-first host-side: `tests/start-services-extra-marketplace.bats` (registers
    when absent, idempotent when resolved, bounded when claude hangs, degrades
    without `timeout`, no-op without claude). No changes to
    `setup.sh`/`modules/`/`scripts/lib/` (the marketplace derivation already
    exists via `plugin_catalog_marketplaces_json`).
- **Post-login plugin auto-install path** (`008-fix-postlogin-plugin-install`):
  full DOCKER_E2E validation after #61/#62 surfaced `docker-e2e-postlogin`
  failing (channel plugin never auto-installed after the credential flip). Three
  chained defects, root-caused with runtime evidence (hung container process
  tree) + static analysis:
  - **(US1)** Feature 006's `ensure_official_marketplace` runs
    `claude plugin marketplace list | grep` in the boot path; the e2e `claude`
    stub (from 004) only handled `plugin install` and fell through to
    `exec sleep 86400`, so the pipe hung the supervisor before tmux/the watchdog
    ever started → 0 installs. The stub now handles the whole `plugin` family
    (`marketplace list/add`, `plugin list`) non-blocking; only the interactive
    session sleeps.
  - **(US2)** Hardened `ensure_official_marketplace` to bound its `claude` calls
    with `timeout` (configurable via `MARKETPLACE_CMD_TIMEOUT`, degrades to a
    direct call if `timeout` is absent), so a wedged CLI can never hang the boot
    before the watchdog can recover it (Principle IV).
  - **(US3)** `docker/scripts/lib/plugin-install.sh` (defines
    `retry_plugin_install_bounded`) reached the workspace via the wholesale
    `docker/` copy but the Dockerfile never `COPY`d it into the image, so the
    bounded retry (004 US2) and the marketplace-not-found classification (006
    US4) were dead code and the supervisor used the legacy single-attempt path.
    Added the missing `COPY` line (the lib is image-only — `mirror_catalog_to_docker`
    is not involved). Test-first host-side for US2/US3; validated with a rebuild
    + the full DOCKER_E2E suite. Specced under `specs/008-fix-postlogin-plugin-install/`.
- **MCP render-contract test drift** (`007-fix-mcp-test-drift`): the default
  `bats` suite was at 668 tests / 6 failing on `main` because six assertions
  still encoded the pre-#59 MCP contract. PR #59 deliberately migrated the
  `github` MCP from `npx @modelcontextprotocol/server-github` to the native
  image-baked `github-mcp-server` (args `["stdio"]`) and pinned the `vault` MCP
  from `@bitbonsai/mcpvault@latest` to `@bitbonsai/mcpvault@0.12.0` (sourced from
  `AGENTIC_FLOOR_MCP_VAULT` in `scripts/lib/versions.sh`); the templates were
  correct, the assertions were stale. Aligned the assertions in
  `tests/mcp-json.bats` (github + vault), `tests/regenerate.bats` and
  `tests/scaffold.bats` to the shipped contract — test-only, no template/runtime
  change — returning the suite to fully green. Out of scope: collapsing the
  duplicated `0.12.0` literal (template vs `versions.sh`) into a single source
  (pre-existing Principle VI debt). Specced under `specs/007-fix-mcp-test-drift/`.
- **Schema validation accepts a present boolean `false`** (`005-fix-schema-false`):
  `agent_yml_validate` no longer rejects a valid `agent.yml` whose required boolean
  leaf is set to `false` (e.g. `features.heartbeat.enabled: false`) with "missing
  required field" — which blocked `./setup.sh --regenerate` for any agent that
  disables a feature. Root cause: `_schema_get` read via `yq "$path // \"\""`, and
  yq's `//` alternative operator collapses a present `false` to `""`, so the
  required-leaf check saw it as absent. Now reads raw and normalizes only a literal
  `null` to empty, so a present `false` survives while genuinely-absent/`null` leaves
  are still flagged. Re-applies the orphaned `002-fix-schema-bool` that never reached
  `main`.
- **macOS bootstrap hardening** (`004-macos-bootstrap-hardening`): three image-baked
  fixes so a from-scratch macOS (Docker Desktop / VirtioFS bind-mount) scaffold
  reaches a fully functional agent with no manual repair, even though the container
  already reports `healthy`. Specced with GitHub Spec Kit under
  `specs/004-macos-bootstrap-hardening/`.
  - **(P1)** npx-based MCP servers (`filesystem`, `vault`) now connect on macOS. The
    Node package-runner cache is relocated off the `/home/agent` `.state` bind-mount
    to an image path (`NPM_CONFIG_CACHE=/opt/npm-cache` + `PREFER_OFFLINE`) AND the
    default packages are pre-warmed into it at build time — mirroring the existing uv
    `/opt` pattern — so they no longer hit the VirtioFS small-file pathology
    (`errno -35` / `ENOTEMPTY`) nor download inside Claude's MCP handshake window. The
    `vault` spec is pinned so the runtime `npx` resolves the warmed version.
  - **(P2)** After `/login`, declared plugins now install on their own. The watchdog
    keeps retrying the post-login plugin install (non-blocking, ~120s budget) until
    every plugin carries its `.installed-ok` sentinel, then kicks once to attach the
    channel — instead of the single post-flip attempt that raced the auth-ready
    moment and gave up, leaving plugins uninstalled until a manual `plugin install`.
    On budget exhaustion it terminates and records the residual failure for
    `agentctl doctor` (never loops unbounded).
  - **(P3)** The GitHub MCP now runs GitHub's official `github-mcp-server` Go binary
    (statically linked, baked into `/usr/local/bin`, invoked `github-mcp-server stdio`)
    instead of the deprecated `@modelcontextprotocol/server-github` npx package. The
    `GITHUB_PAT` / `GITHUB_PERSONAL_ACCESS_TOKEN` wiring is unchanged. Survives
    `./setup.sh --regenerate`.

### Added
- **Bootstrap hardening** (`003-bootstrap-hardening`): fail-loud / validate / sync
  fixes across the scaffold→boot→login→plugins→channel path (9 stories, 3 tiers,
  specced with GitHub Spec Kit under `specs/003-bootstrap-hardening/`).
  - **(A)** After `/login`, the supervisor watchdog detects the auth-credential
    flip (appearance of `~/.claude/.credentials.json`) and **actively kicks** the
    tmux session, so plugins install and the channel attaches with no manual
    `docker restart` and without the operator having to `/exit`.
  - **(B)** `setup.sh` probes the template repo visibility and warns — before
    creating anything — when a public template would yield a public fork after a
    private fork was requested; the operator chooses proceed-public or
    disable-fork. Non-interactive runs default to **disable-fork** (never a
    surprise-public fork). New `scripts/lib/fork.sh`.
  - **(C)** Bounded plugin-install retry (3 attempts, short fixed backoff). A
    residual failure is recorded to `.state/plugin-install-failures.jsonl` with
    the error text truncated to its first line and token-scrubbed, and is surfaced
    by `agentctl doctor` with a copy-paste retry command (distinct from an
    expected "not authenticated" skip). New `docker/scripts/lib/plugin-install.sh`.
  - **(D)** Destination paths are validated up front: a non-absolute path, a `~`
    anywhere but position 0, and `..` are rejected; a leading `~` is expanded; a
    `/home/…` path on macOS warns that the home dir is under `/Users/`.
    `validate_destination_path` + `normalize_destination_path` in
    `scripts/lib/wizard-validators.sh`.
  - **(E)** Agent-name normalization maps spaces→hyphens, collapses consecutive
    hyphens, and trims leading/trailing hyphens, then confirms the normalized
    value before it is used for filenames/branches/the container name.
  - **(F)** A host test fails when the agentic-quickstart wizard-order docs drift
    from the canonical prompt sequence; the 6 optional catalog MCPs (aws,
    firecrawl, google-calendar, playwright, time, tree-sitter) are now documented
    in both locales.
  - **(G)** Fork-less agents no longer spam a per-tick "identity backup
    triggered" line: the watchdog skips the identity-backup hash check entirely
    when `agent.yml` has no `scaffold.fork.url` (mirrors `heartbeatctl::_bi_run`).
  - **(H)** The in-container CLAUDE.md refresh now preserves every pre-existing
    `##` section header verbatim and only ADDS missing command/architecture/test
    sections — an operator-injected section survives byte-for-byte; the prompt no
    longer names a fixed section list. The refresh logic is now a sourceable
    `refresh_claude_md` function (host-testable) in `docker/scripts/wizard-container.sh`.
  - **(I)** Optional multi-line persona via `agent.yml` `agent.role_file`,
    populated by a `--role-file PATH` wizard flag. The renderer reads the file and
    injects it verbatim into CLAUDE.md's `## Identity` (in place of the one-line
    role), re-reading the content on every `--regenerate`. Persona files supplied
    from outside the workspace are copied in (`personas/<name>.md`) so they travel
    with clone / backup / `--restore-from-fork`.
- **Reproducible in-container dependency upgrades** (`001-deps-upgrade`). The
  image toolchain — Claude Code, the Alpine base, `uv`, `bun`, `gum` — tracks the
  latest stable of the moment from a single declared place that the documented
  build honors, with no hardcoded version literals and no drift.
  - `scripts/lib/versions.sh`: default channels (Claude Code → `stable`, others →
    latest stable) + a best-effort upstream resolver (`versions_resolve`) with an
    offline floor. `AGENTIC_VERSIONS_OFFLINE=1` forces the floor (offline scaffold
    / deterministic tests).
  - `setup.sh` resolves each channel and **records** the concrete version into
    `agent.yml`'s `docker:` block (`claude_code_version`, `uv_version`,
    `bun_version`, `gum_version`, `base_image`, `toolchain_channels`) at scaffold;
    `--regenerate` backfills only missing fields (deterministic). `ensure_gum` is
    single-sourced from `versions.sh`.
  - `docker-compose.yml` forwards the recorded versions as `build.args`; the
    Dockerfile is build-arg driven (`FROM ${BASE_IMAGE}`) and adds
    `ENV UV_PYTHON_PREFERENCE=only-system` (uv ≥0.8 guard).
  - `agentctl versions [--check] [--json] [--upgrade]`: list recorded versions +
    channels, compare against upstream (best-effort, degrades to `unknown`
    offline), or re-resolve non-pinned channels and record them (skips `pinned`,
    writes `agent.yml.prev`). `agentctl doctor` gains a recorded-toolchain line.
  - `agent.yml` schema validates `docker.toolchain_channels.*` ∈
    {`stable`,`latest`,`pinned`} (absent = legacy-safe).
  - Specced with GitHub Spec Kit under `specs/001-deps-upgrade/` against a new
    project constitution (`.specify/memory/constitution.md`).

### Changed
- Bumped the baked toolchain to latest stable: Claude Code 2.1.119 → **2.1.170**
  (`stable`), Alpine 3.20 → **3.24.1** (Node 24, Python 3.14, apk v3, busybox
  1.37), `uv` 0.5.14 → **0.11.22**, `bun` 1.1.38 → **1.3.14**, `gum` 0.14.5 →
  **0.17.0**.

### Fixed
- **`.state/` bind-mount guard** (`agentctl up` + `agentctl doctor`): on macOS a
  transient Docker Desktop file-sharing glitch (or a fresh clone) could leave the
  workspace `.state/` absent, so `docker compose up` mounted a phantom empty
  `/home/agent` and the container booted **`healthy` over a broken bind-mount** —
  `/login` could not persist and the vault never seeded. `agentctl up` now
  pre-creates `.state/` (idempotent, only inside a real workspace) before composing
  up, and `agentctl doctor` **fails** when `.state/` is missing (warns when present
  but not writable) instead of letting the agent ghost silently.
- `scripts/lib/wizard-gum.sh`: gum ≥0.15 changed the Esc exit code for
  `input`/`choose` from 2 to 1; the wizard abort check is now widget-scoped so Esc
  aborts input/choose while `gum confirm`'s legitimate "no" (rc 1) still works.

## [0.1.0] - 2026-05-06

First tagged baseline. Cuts the `[Unreleased]` accumulation that had been
running since the initial import; subsequent changes will land under a
new `[Unreleased]` heading and graduate to a numbered release on cut.

### Added
- `VERSION` file at the repo root (semver, hand-maintained alongside
  CHANGELOG entries) plus a `meta:` block in scaffolded `agent.yml`.
  `setup.sh` stamps `meta.launcher_version` + `meta.scaffolded_at` on
  first scaffold and refreshes `meta.launcher_version` +
  `meta.regenerated_at` on every `--regenerate`. `agentctl doctor`
  surfaces "Launcher version: vX.Y.Z (scaffolded …, regenerated …)" as a
  new check between agent.yml-valid and the .env-perms check; legacy
  agents lacking the meta block get a hint to regenerate. `setup.sh
  --version` / `-V` prints the version and exits.
- watchdog detects `Please run /login` banner in `claude.log` and emits an
  immediate warning via the configured notifier. Closes the gap between
  "OAuth expires" and "user gets warned" — without this, the user only
  finds out at the next heartbeat (up to 30 min lag) or by attaching the
  tmux session manually. New function `_check_auth_banner` in
  `start_services.sh` is throttled to 1× per 60s, reads the last 50 lines
  of `claude.log`, persists a state file at
  `<workspace>/scripts/heartbeat/auth-status.json` with `{status,
  first_seen_at, last_warned_at}`, and dedups warnings 24h. When the
  banner clears (post-/login), emits a recovery message + resets the
  state. Test-only env vars `AUTH_BANNER_LOG_OVERRIDE`,
  `AUTH_BANNER_STATE_OVERRIDE`, `AUTH_BANNER_AGENT_YML_OVERRIDE`,
  `AUTH_BANNER_NOTIFIERS_OVERRIDE` enable bats coverage without touching
  `/workspace/`. Phase B1 of the OAuth resilience plan.
- Telegram plugin patch v4 (anti-zombie typing). Closes the UX hole
  where the bot would show "typing…" forever when claude was blocked on
  `/login` (OAuth expired) — observed during the 2026-05-03 incident
  with 415+ stranded typing ticks. v4 caps the indicator at
  `_TYPING_MAX_DURATION_MS` (default 5 min, override via env
  `TELEGRAM_TYPING_MAX_MS`), aborts the `setInterval`, sends the user a
  message ("⚠️ Tardé más de Nm en responder. Es probable que el OAuth
  de Claude haya expirado. Revisa: agentctl doctor."), and logs to
  stderr (tee'd to `telegram-mcp-stderr.log` by the v3 stderr patch).
  Idempotent upgrade cascade: v1→v2→v3→v4. The v3 helper block remains
  available as `TYPING_HELPERS_V3` so v2→v3 upgrades land on v3 first
  before `upgrade_typing_v3_to_v4` lifts them to v4 — preserves accurate
  upgrade-step logging. Phase B2 of the OAuth resilience plan.

### Fixed
- heartbeat reports `status: ok` when claude returns API 401 in stdout.
  When the OAuth access token expires inside the container, `claude --print`
  emits the API error JSON (`{"type":"authentication_error",...}`) to stdout
  and exits 0. The heartbeat wrapper trusted exit code and counted the run
  as success, sending a misleading `[ok]` notification while the agent was
  effectively dead. Fix: post-check the session log for `API Error: 401` /
  `authentication_error` / `Please run /login` and override `status` to
  `error` with new field `error_kind: "auth_failed"` (persisted in
  `runs.jsonl` and `state.json::last_run`). Detected on Linus/Ferrari at
  2026-05-03 22:30 –04. Phase A1 of the OAuth resilience plan.

### Added
- token-health probe for Claude Code OAuth. New file-local probe
  `probe_claude_oauth` reads `~/.claude/.credentials.json` (path overridable
  via `TH_CLAUDE_CRED_OVERRIDE`), extracts `claudeAiOauth.expiresAt` (epoch
  ms), and classifies: missing/malformed → `skipped`, expired → `auth_fail`
  with `expired Ns ago`, expires in <30 min → `auth_fail` with `expires in
  Nm` (early warning), else `ok`. The probe is purely local (no network
  call to Anthropic) because the OAuth flow does not expose a free /me
  endpoint suitable for repeated polling. Wired into the existing token-
  health pipeline: hourly cron in `check_token_health.sh::_run_all`,
  state file at `<workspace>/scripts/heartbeat/token-health/claude_oauth.json`,
  doctor check 19 in `agentctl::cmd_doctor` (only fires if the state file
  exists). Warning hint points at `agentctl attach → /login`. Phase A2 of
  the OAuth resilience plan. Same dedup (24h) and warn/recover/silent
  state machine as the other token-health probes.

### Fixed
- timezone in container falls back to UTC even when `agent.yml::user.timezone`
  is set. The Alpine base image ships without `tzdata` and the compose
  template never passed `TZ` to the container — `date`, bash, and any
  tool reading `/etc/localtime` all rendered timestamps in UTC, which
  surfaced as the agent (Linus on Ferrari) repeatedly logging "GMT-4"
  metadata while heartbeats stamped UTC. Three-line fix: (1) Dockerfile
  installs `tzdata` so `/usr/share/zoneinfo/<region>/<city>` exists;
  (2) `modules/docker-compose.yml.tpl` adds `environment: TZ:
  "{{USER_TIMEZONE}}"` rendered from the user's wizard answer; (3)
  `entrypoint.sh` symlinks `/etc/localtime → /usr/share/zoneinfo/$TZ`
  on boot for C tools that read the binary file directly. Defensive:
  silent no-op if `$TZ` is unset or names a missing zoneinfo file —
  never fails the boot over a bad string. Regression test in
  `tests/docker-render.bats` asserts the rendered compose file contains
  the TZ env var matching the fixture's `user.timezone`.
- watchdog deadlock on first-boot before /login. When the fork URL
  needed auth (private repo) and `.env` had no PAT yet, the
  watchdog-triggered identity backup ran `git clone` synchronously
  without `GIT_TERMINAL_PROMPT=0` — git asked for a username on stdin,
  blocked forever, and the watchdog never came back to respawn the
  tmux session the user needed to /login. Fix layered in three places:
  (1) `_identity_git`/`_vault_git`/`_config_git` wrappers in each
  backup lib set `GIT_TERMINAL_PROMPT=0 + GIT_ASKPASS=/bin/true` and a
  60s `timeout(1)` cap (when available — falls back gracefully on
  macOS hosts without coreutils for tests); (2)
  `start_services.sh::_trigger_identity_backup` now backgrounds the
  call with a 90s outer `timeout` + a `pgrep` reentrancy guard so the
  watchdog can never block on backup IO; (3) regression tests in
  `tests/backup-identity-lib.bats` (env exported correctly, fallback
  branch works) and `tests/start-services-watchdog.bats` (trigger
  returns in <3s with a 30s-sleeping stub heartbeatctl, reentrancy
  guard short-circuits when previous run is still in flight). Reported
  on Ferrari (Raspberry Pi) right after PR #41 + #42 landed; the bug
  predates both — workaround on existing installs is to add
  `GIT_TERMINAL_PROMPT=0` to `.env` and restart the container.

### Added
- token-health: hourly probe of free-tier auth endpoints to catch
  expired/revoked tokens *before* Claude tries to use them and dies
  with a 401 mid-task. Three probes today: GitHub PAT (`/user`),
  Telegram bot (`/getMe`), Atlassian token per workspace
  (`/rest/api/3/myself`). Firecrawl + Google Calendar are deliberately
  skipped from cron (cost + OAuth refresh fragility). State files at
  `<workspace>/scripts/heartbeat/token-health/<id>.json` mirror the
  backup-freshness pattern; `agentctl doctor` gains 3 checks (16-18)
  that surface auth failures as ✗ and stale probes as ⚠. Warnings
  flow through the configured heartbeat notifier with a 24h dedup so
  Telegram doesn't get 168 reminders for a week-old expired PAT.
  Override the cadence via `features.token_health.schedule`; opt out
  with `features.token_health.enabled=false`. New file
  `docker/scripts/lib/token_health.sh` (probes + state I/O), new
  runner `docker/scripts/check_token_health.sh`, new heartbeatctl
  subcommand `token-check` (also via `agentctl heartbeat token-check`).
  Status enrichment shows one line per probed token. The runner never
  modifies `.mcp.json` or disables MCPs — purely observational, so a
  flaky probe can't degrade the running session.
- doctor: backup-freshness checks. `agentctl doctor` now reads the three
  state files at `<workspace>/scripts/heartbeat/{identity,vault,config}-
  backup.json` and reports `pushed Nh ago` for each. Marks the check as
  ⚠ when the last push is older than the expected cadence × 2 (identity
  48h, vault 25h, config 8d) — clear surface for "the cron stopped
  pushing days ago and you didn't notice". Three new bash helpers:
  `_epoch_from_iso` (portable ISO 8601 → epoch on macOS BSD date and
  Linux GNU date), `_humanize_delta`, `_check_backup_freshness`.
  Thresholds overridable per-invocation via env vars
  `DOCTOR_IDENTITY_MAX_AGE_HOURS`, `DOCTOR_VAULT_MAX_AGE_HOURS`,
  `DOCTOR_CONFIG_MAX_AGE_DAYS`.
- heartbeatctl: `cmd_status` now also enriches `vault backup` and
  `config backup` (was identity-only) — closes a colateral gap where
  the two state files existed but never surfaced via the CLI. The
  doctor and status now read the same data and report consistently.
- backup: vault backup primitive — `heartbeatctl backup-vault` snapshots
  the vault's markdown subset to a `backup/vault` orphan branch on the
  fork, hourly by default (override via `vault.backup_schedule` in
  `agent.yml`). Excludes Obsidian per-device noise (`.obsidian/
  workspace*.json`, `cache/`, `.trash/`, `*.sync-conflict-*`) so
  Syncthing-induced churn doesn't pollute the snapshots. Idempotent via
  sha256 hash over content + filenames; deletes propagate (the staged
  tree is wiped before each commit so removed notes drop out of the
  next snapshot). Helpers in `docker/scripts/lib/backup_vault.sh`.
- backup: config backup primitive — `heartbeatctl backup-config`
  snapshots `agent.yml` (plaintext, no secrets) to a `backup/config`
  orphan branch. Daily at 03:30 by default. Disable via
  `features.config_backup.enabled=false` in `agent.yml`.
- restore: `setup.sh --restore-from-fork <url>` now pulls all three
  backup branches in order — `backup/config` first (so `vault.path` is
  known), then `backup/identity`, then `backup/vault`. Each branch is
  independently optional: a partial fork still rehydrates whatever's
  available with a clear "no backup/X branch" notice for the rest.
- telegram: persist Telegram `update_id` offset to disk on each successful
  reply (`/home/agent/.claude/channels/telegram/last-offset.json`) and
  replay from disk on plugin startup via a synchronous
  `bot.api.getUpdates({ offset })` call before `bot.start()`. Ack-on-reply
  semantics: a `_pendingUpdates` Map is populated in `handleInbound`
  (right after `chat_id` is bound) and drained in the `case 'reply'` MCP
  tool dispatcher only after `bot.api.sendMessage` returns successfully.
  Net effect: if bun dies between an inbound being forwarded to claude
  via MCP and claude calling the `reply` tool back, the offset stays
  put — Telegram re-delivers the update on the next `bot.start()`. This
  fixes the silent "message acknowledged but never replied" failure
  mode that the prior pre-handler middleware shipped on the abandoned
  `feat/telegram-reliability` branch had. Four hunks: helpers (B1),
  replay-before-bot.start (B2), mark-pending in handleInbound (B3),
  ack-pending in case 'reply' (B4). Marker:
  `agentic-pod-launcher: offset persistence patch v1`.
- telegram: primary-secondary lock to prevent sub-claude bun spawns from
  killing the live primary. Upstream's stale-poller block sends `SIGTERM`
  to whatever PID is in `bot.pid` whenever a new bun starts — designed
  to clean up a crashed predecessor. But every claude session that loads
  the telegram plugin (heartbeat-driven `claude --print`, claude-mem's
  observer worker, Task subagents...) spawns its own `bun server.ts` that
  hits the same code path and SIGTERMs the interactive session's bun
  mid-turn. The primary-lock patch (a) refreshes `bot.pid`'s mtime every
  5s via `setInterval`, and (b) makes the stale-poller exit cleanly
  (`process.exit(0)`) when it sees a recent (`< 30s`) mtime — any new
  instance that finds a fresh primary gives up instead of taking over.
  Marker: `agentic-pod-launcher: primary lock patch v1`.
- heartbeat: `ensure_heartbeat_config_dir` no longer symlinks
  `settings.json` or `plugins/` into `~/.claude-heartbeat`. Instead it
  writes a real `settings.json` with `enabledPlugins: {}` and
  `extraKnownMarketplaces: {}` (preserving auth-mode + skip-perms-prompt
  from the source) and creates an empty `plugins/` directory. Without
  this, the heartbeat's `claude --print` inherited the agent's
  `enabledPlugins.telegram@... = true` and spawned a sub-bun on every
  cron tick (i.e. every 30 minutes) that took over the bot poller and
  killed the interactive session's bun. With the primary-lock patch
  above as belt-and-suspenders, but this one prevents the spawn at all.
- telegram: tee `process.stderr` to
  `/workspace/scripts/heartbeat/logs/telegram-mcp-stderr.log` plus
  register `process.on('uncaughtException')` and
  `process.on('unhandledRejection')` handlers that append the trace
  there. Without this, bun crashes left no forensic evidence (the MCP
  transport drops the existing handlers' stderr writes). Marker:
  `agentic-pod-launcher: stderr-capture patch v1`.
- heartbeatctl: new `drop-plugin <spec>` subcommand. Atomic
  `yq -i '.plugins -= [strenv(V)]'` mutation against `agent.yml` with
  backup/restore on failure. Idempotent. Useful for evicting a
  known-broken plugin without manual `yq` invocations.

### Removed
- catalog: `caveman@JuliusBrussee` opt-in plugin removed from the
  default catalog. The repo `JuliusBrussee/caveman` ships a single
  Claude Code skill, not a plugin marketplace (no `marketplace.json`
  at root) — `claude plugin install caveman@JuliusBrussee` failed on
  every container respawn, leaving "1 MCP server failed" in the
  status panel and ~1s of churn per crash cycle. Existing agents:
  `docker exec -u agent <name> heartbeatctl drop-plugin
  caveman@JuliusBrussee` then `kick-channel` to apply.

### Changed
- docker: agent state (login, Telegram pairing, sessions, plugin cache)
  moved from a docker-managed named volume (`<agent>-state`, living in
  `/var/lib/docker/volumes/`) to a bind-mount inside the workspace at
  `<workspace>/.state/`. The workspace directory is now self-contained
  — `rsync` / `cp -r` of the workspace is a full agent migration. Side
  effects: `docker compose down -v` no longer wipes the agent's state;
  `setup.sh --uninstall` no longer removes state either (use `--purge`
  to remove `agent.yml` + `.env` + `.state/`, or `--nuke` to delete the
  whole workspace). `.state/` is gitignored at the template level. For
  existing agents, migrate with
  `docker run --rm -v <agent>-state:/src -v $(pwd)/.state:/dst alpine
  cp -a /src/. /dst/` before editing `docker-compose.yml` to reference
  `./.state:/home/agent`.

### Fixed
- heartbeat: `HEARTBEAT_INTERVAL` now propagates into the cron schedule
  via `heartbeatctl reload` (derives `*/N * * * *` from `agent.yml`).
- heartbeat: dropped the user field from `/etc/crontabs/agent` — busybox
  user-crontabs have the user implicit in the filename.
- heartbeat: `crond` is launched as root from `entrypoint.sh` so job
  dispatch can `setgid(agent)` cleanly. `start_services.sh` monitors
  rather than launches.
- heartbeat: `entrypoint.sh` chowns `/workspace/scripts/heartbeat` on
  boot so the agent uid matches the bind-mount.
- heartbeat: crontab write order adjusted for `cap_drop: ALL` — chmod
  while root-owned, then chown to agent (CAP_FOWNER not available).
- heartbeatctl: crontab is written directly (not via mv) because agent
  can overwrite the file but not rename into `/etc/crontabs/`.

### Added
- backup: identity backup via git orphan branch. `heartbeatctl
  backup-identity` snapshots login / pairing / plugin list / settings
  / age-encrypted .env to `backup/identity` on the agent's fork.
  Three triggers (manual, post-plugin-install + 60s watchdog hash
  check, daily cron at 03:30). Restore via
  `setup.sh --destination <path> --restore-from-fork <fork-url>`.
  age encryption uses the fork owner's SSH key from
  `github.com/<owner>.keys` — no extra secrets. A4 fallback (partial
  mode, plaintext-only) kicks in when no key is available; user can
  upgrade via `heartbeatctl backup-identity --configure-key <key>`.
  Design: `docs/superpowers/specs/2026-04-22-identity-backup-design.md`.
- telegram plugin: post-install patch
  (`docker/scripts/apply_telegram_typing_patch.py`) keeps the Telegram
  "typing…" chat action refreshed every 4s while Claude is processing a
  message. Upstream (`claude-plugins-official/telegram`) fires
  `sendChatAction` once on inbound and Telegram auto-expires the action
  at ~5s, so users saw "typing…" stop mid-processing on any reply that
  needed an MCP call or more than a few seconds of thought. Patch adds
  a refresh `setInterval` with a 120s hard cap + cleanup at the start of
  the `reply` tool handler. Idempotent via marker comment; fail-silent if
  any of the three anchor regexes miss (upstream drift) so the plugin
  keeps its default behavior. Applied by
  `start_services.sh:apply_plugin_patches` on every boot against the
  plugin copy in the state volume.
- heartbeat: structured `runs.jsonl` trace, one JSON object per run with
  `run_id` correlation, embedded notifier envelope, size-based gz
  rotation at 10MB keeping 3 generations.
- heartbeat: atomic `state.json` snapshot (schema 1) of last run +
  counters (`total_runs`, `ok`, `timeout`, `error`,
  `consecutive_failures`, `success_rate_24h`), enriched with live
  `crond.alive` / `pid` at read time.
- heartbeat: ephemeral runner uses an isolated `CLAUDE_CONFIG_DIR`
  (`/home/agent/.claude-heartbeat`) with selective symlinks to auth +
  plugins so cron ticks don't step on the interactive session's
  channels/state.
- heartbeat: notifier message is now Claude's actual output (session
  log captured + ANSI stripped + capped at 3500 chars), not the canned
  "Heartbeat OK Nms" string. Empty/missing log falls back to the
  canned line.
- heartbeat: ephemeral runner adds `--dangerously-skip-permissions
  --permission-mode auto` so the cron-driven session can call tools
  without a human to approve them.
- heartbeatctl: single CLI with `status` (pretty + `--json`), `logs`,
  `show`, `test`, `pause`, `resume`, `reload`, `kick-channel`, and
  mutable `set-interval`, `set-prompt`, `set-notifier`, `set-timeout`,
  `set-retries`. All mutations are atomic against `agent.yml` with
  rollback on failure.
- heartbeatctl `kick-channel`: one-command recovery for the upstream
  `claude-plugins-official/telegram` MCP-bridge stall (bun stays alive
  and polls Telegram, but its `notifications/claude/channel` messages
  stop reaching Claude). Kills the tmux session; the supervisor
  watchdog respawns it in ~2s with a fresh plugin attachment.
- start_services.sh: `pre_accept_bypass_permissions` writes
  `skipDangerousModePermissionPrompt: true` and
  `permissions.defaultMode: "auto"` to `~/.claude/settings.json` on
  every boot, so the first-launch warning dialog never blocks and
  every session starts in auto mode without `/auto`.
- start_services.sh: clears stale `pending` entries in the telegram
  plugin's `access.json` on every boot (mitigates the upstream
  re-prompt-after-restart bug).
- start_services.sh: watchdog now also exits the container if `crond`
  dies, and respawns the tmux session if `bun server.ts` (the
  channel plugin) is missing.
- entrypoint.sh: root-privileged sync loop copies the
  heartbeatctl-managed staging crontab into `/etc/crontabs/` because
  busybox crond silently rejects non-root-owned crontabs. Uses
  `cmp -s` instead of `-nt` (busybox sh's mtime comparison rounds
  to whole seconds and missed sub-second writes).
- wizard: defaults are pre-filled for one-Enter accept, with `Ctrl+U`
  to clear and `Ctrl+C` to abort the whole wizard cleanly. Tips
  printed once at the top of the banner.
- wizard: at the Telegram-token step, the in-container wizard runs
  `claude --print` once with a targeted prompt to enrich the
  template-rendered `CLAUDE.md` with workspace-specific commands /
  architecture / test conventions. Bounded by `timeout 90`; falls
  back to template-only on failure.
- notifiers: standardized JSON-envelope contract on stdout
  (`{channel, ok, latency_ms, error}`); always exit 0. Race-free
  per-invocation tempfiles.
- docs: `docs/heartbeatctl.md` (full CLI reference), updated
  `docs/architecture.md` (heartbeat pipeline + privilege model),
  `NEXT_STEPS.md` template includes inline troubleshooting (no
  more dead links to `docs/`), `CLAUDE.md` template documents
  self-service permission-mode switching for the agent.
- tests: `interval-to-cron.bats`, `state-lib.bats`,
  `heartbeat-runs-jsonl.bats`, `heartbeatctl.bats`, opt-in
  `docker-e2e-heartbeat.bats` (set `DOCKER_E2E=1`). Suite is at
  ~160 tests.

### Security
- heartbeat.sh: prompt is shell-escaped (`sh_sq` helper) before
  embedding into the tmux command, preventing injection via a
  mutated prompt.
- telegram notifier: HTTP error bodies are JSON-escaped with `jq -n`
  instead of manual `sed`, preventing malformed JSON output on
  upstream errors.

### Known limitations
- Telegram chat may go silent: the upstream
  `claude-plugins-official/telegram` plugin's MCP bridge can wedge
  while bun is still alive and polling. Recovery: `docker exec
  -u agent <agent> heartbeatctl kick-channel`. An auto-detection
  watchdog was attempted (commits 3c5465f / fcb6744) and reverted
  in `ebfe35f` because tmux pane scraping produces too many false
  positives. Tracked for upstream report.

See `docs/superpowers/specs/2026-04-19-heartbeat-observability-cli-design.md`
for the original design spec.

## [0.1.0] — 2026-04-19

Initial import from `agent-admin-template@feature/docker-mode`
(927fffca700b111b84ae32f70b49b230c781aaf1). Docker-only template: no `--docker` flag, no host-mode
paths, single-user-per-container model.

See `docs/architecture.md` for the design.
