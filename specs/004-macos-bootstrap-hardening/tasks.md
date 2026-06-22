---
feature: 004-macos-bootstrap-hardening
branch: 004-macos-bootstrap-hardening
---

# Tasks: macOS bootstrap hardening (MCP + plugin reliability)

**Spec**: [spec.md](./spec.md) · **Plan**: [plan.md](./plan.md) · **Research**: [research.md](./research.md) · **Quickstart**: [quickstart.md](./quickstart.md)

TDD is requested (SC-004: each failure reproduced red, each fix proven green). Test tasks precede implementation within every story. Image-baked behavior is gated behind `DOCKER_E2E=1`; the default `bats tests/` suite must never require Docker.

## Format: `[ID] [P?] [Story] Description with file path`

- **[P]** = parallelizable (different file, no dependency on an incomplete task).
- All paths are repo-root-relative.

## Path Conventions

Single-project launcher. Image-baked code in `docker/`; render templates in `modules/`; shared libs in `scripts/lib/`; tests in `tests/`.

---

## Phase 1: Setup (Shared Infrastructure)

- [X] T001 Record the three pinned versions resolved in research (server-filesystem `2026.1.14`, mcpvault `0.12.0`, github-mcp-server `1.4.0`) as the canonical values to plumb into build ARGs and `scripts/lib/versions.sh`; re-confirm each against its registry/release before coding (npm registry for the two npm packages, `api.github.com/repos/github/github-mcp-server/releases/latest` for the binary).

---

## Phase 2: Foundational (Blocking Prerequisites)

**Why blocking**: both US1 and US3 add Dockerfile build ARGs that the existing Dockerfile-vs-`versions.sh` drift-guard expects to track `versions.sh`. Establish the pin source + guard first so the story ARGs land green.

- [X] T002 Add pin entries for the three packages to `scripts/lib/versions.sh` (floors/channels mirroring the uv/bun/gum pattern: `server-filesystem`, `mcpvault`, `github-mcp-server`), so each Dockerfile ARG default has a tracked source of truth.
- [X] T003 Extend `tests/versions.bats` (red→green) to assert the three new pins exist in `versions.sh` and that the drift-guard covers the new Dockerfile ARG defaults (or is explicitly scoped for hard pins). `shellcheck -S error scripts/lib/versions.sh` clean.

**Checkpoint**: pin source + drift-guard in place; US1 and US3 ARGs can reference them.

---

## Phase 3: User Story 1 — npx MCPs warm off the bind-mount (Priority: P1) 🎯 MVP

**Goal**: default npx MCP servers (`filesystem`, `vault`) connect on a fresh macOS scaffold from a warm image cache, no in-handshake download. (`context7` is a plugin — out of scope.)

**Independent test**: `claude mcp list` on a fresh macOS scaffold shows `filesystem` + `vault` Connected; the warm `_cacache`/`_npx` live under `/opt/npm-cache`, not `/home/agent`.

### Tests for User Story 1 (write first — must fail)

- [X] T004 [P] [US1] Add a Dockerfile shape test in `tests/docker-setup.bats` (or a new `tests/docker-npm-prewarm.bats`) asserting the Dockerfile sets `ENV NPM_CONFIG_CACHE=/opt/npm-cache` (off `/home/agent`), `ENV NPM_CONFIG_PREFER_OFFLINE=true`, a build-time warm `RUN` invoking each default npx MCP package pinned via ARG, and a numeric `chown ${UID}:${GID}` of `/opt/npm-cache`. (red)
- [X] T005 [P] [US1] Add a render test in `tests/modules-render.bats` asserting the rendered `.mcp.json` vault entry is a pinned spec (no `@latest`) and equals the build-time warmed spec string. (red)
- [X] T006 [P] [US1] Add a `DOCKER_E2E` case in `tests/docker-e2e-vault.bats` (or `docker-e2e-smoke.bats`) asserting `su-exec agent npx -y <pinned filesystem/vault spec> --help` resolves with no network (offline probe, exit 0, no `errno -35`) from the built image. (red, opt-in)

### Implementation for User Story 1

- [X] T007 [US1] In `docker/Dockerfile`, add `ARG` defaults for the two npm MCP versions (referencing T002), `ENV NPM_CONFIG_CACHE=/opt/npm-cache NPM_CONFIG_PREFER_OFFLINE=true`, `mkdir -p /opt/npm-cache`, a warm `RUN` (`npx -y "<pkg>@<ver>" --help || true` per package; use `npm exec -y --package=<pkg@ver> -- true` for any bin that hangs/lacks `--help`), and numeric `chown -R ${UID}:${GID} /opt/npm-cache`. Place after the node/npm apk layer. (green for T004/T006)
- [X] T008 [US1] In `modules/mcp-json.tpl`, pin the vault spec — `@bitbonsai/mcpvault@latest` → `@bitbonsai/mcpvault@<ver>` (rendered from `agent.yml` so it survives `--regenerate`); keep the filesystem spec bare-but-warmed-identically. (green for T005)
- [X] T009 [US1] Run `bats tests/` (default) + `shellcheck -S error` on touched shell; confirm T004/T005 green and the existing suite stays green.

**Checkpoint**: US1 independently testable — npx MCPs warm.

---

## Phase 4: User Story 2 — plugins install automatically after login (Priority: P2)

**Goal**: after `/login`, declared plugins install on their own within a ~120s budget; the channel attaches; no manual `plugin install`.

**Independent test**: with the `START_SERVICES_NO_RUN=1` + `AUTH_MARKER_OVERRIDE` + mocked-`claude` seams, the credential flip drives retries to completion and a single kick; in `DOCKER_E2E`, a simulated flip installs all plugins with no manual step.

### Tests for User Story 2 (write first — must fail)

- [X] T010 [P] [US2] Add `tests/start-services-postlogin-retry.bats` asserting: `_check_auth_flip` arms a `~120s` deadline (env knob `PLUGIN_POSTLOGIN_BUDGET`, settable to a small value in tests); `_post_login_plugin_retry` is idempotent (no-ops once all `.installed-ok` sentinels exist); it kicks the tmux session exactly once on completion and clears the deadline; on deadline elapse it clears without re-kicking and leaves residual failures recorded. Use a `claude` stub that fails not-auth for N ticks then succeeds, a `tmux` stub recording kills, and sentinel files. (red)
- [X] T011 [P] [US2] Add/extend a `DOCKER_E2E` case (`tests/docker-e2e-smoke.bats` or new `docker-e2e-postlogin.bats`) that boots a container, drops a mocked `.credentials.json`, and asserts all declared plugins reach `.installed-ok` within the budget with no manual install and the channel attaches. (red, opt-in)

### Implementation for User Story 2

- [X] T012 [US2] In `docker/scripts/start_services.sh`, add `PLUGIN_POSTLOGIN_BUDGET` (default 120, override-able), an `_all_plugins_installed` helper (every catalog plugin carries `.installed-ok`), and `_post_login_plugin_retry` (non-blocking: while within deadline and not all installed → `ensure_all_plugins_installed`; on all-installed → `tmux kill-session` once + clear deadline; on elapse → clear deadline). (green for T010)
- [X] T013 [US2] In `docker/scripts/start_services.sh`, arm the deadline inside `_check_auth_flip` on the absent→present flip (keep the existing single kick), and call `_post_login_plugin_retry` once per `_run_watchdog` tick (after `_check_auth_flip`, before the session/channel checks). Ensure no per-tick re-kick (crash-budget safe). (green for T010/T011)
- [X] T014 [US2] `shellcheck -S error docker/scripts/start_services.sh`; confirm T010 green and the existing `start-services-*` / story-A tests stay green (no regression to the auth-flip behavior).

**Checkpoint**: US2 independently testable — post-login plugins self-install.

---

## Phase 5: User Story 3 — GitHub MCP uses a maintained server (Priority: P3)

**Goal**: the GitHub MCP connects via the official `github-mcp-server` Go binary instead of the deprecated npx package.

**Independent test**: rendered `.mcp.json` github block is the binary stdio form; `github-mcp-server --version` runs in the built image; with a token, the handshake succeeds.

### Tests for User Story 3 (write first — must fail)

- [X] T015 [P] [US3] Extend `tests/modules-render.bats` asserting the rendered github MCP block uses `command: "github-mcp-server"`, `args: ["stdio"]`, keeps `env.GITHUB_PERSONAL_ACCESS_TOKEN: ${GITHUB_PAT}`, and contains no `npx` / `@modelcontextprotocol/server-github`. (red)
- [X] T016 [P] [US3] Add a Dockerfile shape test (in T004's file) asserting the `github-mcp-server` download stanza exists: `ARG GH_MCP_VERSION`, arch mapping (`x86_64`/`aarch64`→`x86_64`/`arm64`), download + `sha256sum -c` checksum verify, extract to `/usr/local/bin`, `chmod +x`. (red)
- [X] T017 [P] [US3] Add a `DOCKER_E2E` case asserting `github-mcp-server --version` runs (exit 0) in the built image, and (with a test `GITHUB_PAT`) the github MCP appears Connected in `claude mcp list`. (red, opt-in)

### Implementation for User Story 3

- [X] T018 [US3] In `docker/Dockerfile`, add `ARG GH_MCP_VERSION` (referencing T002) + a `RUN` stanza modeled on the gum block: arch-map, download `github-mcp-server_Linux_${arch}.tar.gz` + `github-mcp-server_${VERSION}_checksums.txt` from the `v${GH_MCP_VERSION}` release, `sha256sum -c`, extract the `github-mcp-server` binary to `/usr/local/bin`, `chmod +x`, run `github-mcp-server --version` as a build sanity check. (green for T016/T017)
- [X] T019 [US3] In `modules/mcp-json.tpl`, replace the github block `command`/`args` (`npx`/`["-y","@modelcontextprotocol/server-github"]` → `github-mcp-server`/`["stdio"]`), preserving the `{{#if MCPS_GITHUB_ENABLED}}` guard, the `env` block (`GITHUB_PERSONAL_ACCESS_TOKEN: ${GITHUB_PAT}`), and the surrounding comma. (green for T015)
- [X] T020 [US3] `bats tests/` (default) + `shellcheck`; confirm T015/T016 green and the suite stays green.

**Checkpoint**: US3 independently testable — github MCP on the maintained binary.

---

## Phase 6: Polish & Cross-Cutting

- [X] T021 [P] Add a `CHANGELOG.md` `### Fixed`/`### Changed` block under `[Unreleased]` covering P1 (npm pre-warm), P2 (post-login retry), P3 (github MCP migration), framed as observable behavior (FR-010).
- [X] T022 [P] Bump `VERSION` 0.2.1 → 0.3.0 (three behavior fixes; minor per the repo's accumulation pattern — confirm with maintainer if a patch is preferred).
- [X] T023 Run the full default suite `bats tests/` (0 fail) + `shellcheck -S error` on all touched shell files; fix any regression.
- [X] T024 Run the image-baked verification `DOCKER_E2E=1 bats tests/docker-e2e-*.bats` (real build + boot): assert SC-001 (filesystem/vault connected warm), SC-002 (github connected), SC-003 (post-login plugins auto-install).
- [X] T025 Verify `./setup.sh --regenerate` on a scaffolded workspace preserves the vault pin and github command/args (FR-007), and confirm no Linux regression for SC-005 (default suite is host-OS-agnostic; note the DOCKER_E2E Linux run as a follow-up if not run here).

---

## Dependencies & Execution Order

- **Setup (T001)** → **Foundational (T002–T003)** must complete before story ARGs land.
- **US1 (T004–T009)**, **US2 (T010–T014)**, **US3 (T015–T020)** are independent stories and can be implemented in any order after Foundational; the refine decision is to ship them together (one PR) in priority order P1→P2→P3.
- **Cross-file contention**: `docker/Dockerfile` is touched by US1 (T007) and US3 (T018) — different stanzas, same file, so T007 and T018 are **not** `[P]` with each other. `modules/mcp-json.tpl` is touched by US1 (T008, vault) and US3 (T019, github) — different blocks, same file, also not `[P]` together.
- **Polish (T021–T025)** after all stories.

## Parallel Opportunities

- All **test-writing** tasks within a story are `[P]` (distinct test files): T004/T005/T006; T010/T011; T015/T016/T017.
- Across stories, the test-writing tasks are `[P]` with each other (distinct files) once Foundational is done.
- T021 and T022 are `[P]` (CHANGELOG vs VERSION).
- Same-file implementation tasks (Dockerfile, mcp-json.tpl) are serialized.

## Implementation Strategy

MVP = **US1** (npx MCPs warm) — highest impact, lowest risk, mirrors the proven uv pattern. Ship US1→US2→US3 in one PR (one image rebuild). Each story is independently testable per its checkpoint, so a partial landing still leaves a coherent, verifiable increment.
