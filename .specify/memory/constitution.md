<!--
SYNC IMPACT REPORT
==================
Version change: (template / unversioned) → 1.0.0
Bump rationale: Initial ratification — first concrete constitution replacing the
  unfilled template. MAJOR baseline (1.0.0).

Principles defined (6):
  I.   Single Source of Truth (agent.yml)
  II.  Least-Privilege Container Model (NON-NEGOTIABLE)
  III. Test-First, Host-Runnable (bats)
  IV.  Idempotent, Fail-Silent Lifecycle
  V.   Workspace-Is-the-Agent; Durable, Never-Committed State
  VI.  Reproducible, Intentionally-Pinned Dependencies

Added sections:
  - Platform & Toolchain Constraints
  - Development Workflow & Quality Gates
  - Governance

Removed sections: none (template placeholders all replaced).

Templates requiring updates:
  ✅ .specify/templates/plan-template.md — Constitution Check gates wired to the
     six principles (replaced "[Gates determined based on constitution file]").
  ✅ .specify/templates/spec-template.md — reviewed; generic, no constitution-
     specific tokens to change.
  ✅ .specify/templates/tasks-template.md — reviewed; generic, no constitution-
     specific tokens to change. (Note: this repo is test-first per Principle III,
     so bats test tasks are NOT optional for behavior changes — see plan gate.)

Follow-up TODOs: none. All placeholders resolved; dates set to 2026-06-18.
-->

# agentic-pod-launcher Constitution

`agentic-pod-launcher` is a bash wizard that scaffolds self-contained, Dockerized
Claude Code agents. The launcher clone is disposable after scaffolding; the
scaffolded workspace IS the agent. These principles encode the load-bearing
invariants that keep scaffolding deterministic, the runtime self-healing, and
agent state durable. They are binding on all changes to this repository.

## Core Principles

### I. Single Source of Truth (agent.yml)

`agent.yml` is the single source of truth for every scaffolded agent. Every
derived file — `docker-compose.yml`, `.mcp.json`, `CLAUDE.md`,
`scripts/heartbeat/heartbeat.conf`, the `.env` skeleton, `NEXT_STEPS.md` — MUST be
rendered from `agent.yml` via `scripts/lib/render.sh` and its templates under
`modules/`.

- Derived files MUST NOT be hand-edited with the expectation that the edit
  survives; a change that must persist MUST be made in the template + `agent.yml`
  (or in the runtime mutation path), never in the rendered output.
- Runtime mutations (`heartbeatctl set-*`, `drop-plugin`, etc.) MUST write
  `agent.yml` first — with an atomic `agent.yml.prev` backup and rollback on
  failure — and only then regenerate derived files.
- Every change MUST survive `./setup.sh --regenerate`. If a behavior cannot be
  reproduced by re-rendering from `agent.yml`, the design is wrong.

**Rationale**: Determinism and recoverability. The whole system is a pure
function of `agent.yml`; preserving that lets `--regenerate`, `--restore-from-fork`,
and migrations work without bespoke state reconciliation.

### II. Least-Privilege Container Model (NON-NEGOTIABLE)

The container privilege model is inviolable and MUST NOT be weakened for
convenience. `docker-compose.yml` ships `cap_drop: ALL`, `cap_add` of only
`[CHOWN, SETUID, SETGID]`, and `no-new-privileges`, with no Docker socket and no
inbound ports.

- Every `docker exec` into an agent container MUST pass `-u agent`; `agentctl`
  enforces this and direct `root` exec MUST NOT be used to write agent-owned files.
- `crond` runs as root solely so it can `setgid(agent)` when dispatching jobs;
  crontabs MUST be root-owned (busybox `crond` silently rejects otherwise).
- New capabilities, privileged mounts, or socket access MUST be justified in
  Complexity Tracking and are presumed rejected.

**Rationale**: The agent runs untrusted-ish autonomous workloads with OAuth
tokens on disk. Minimal capabilities + non-root runtime is the primary
containment boundary.

### III. Test-First, Host-Runnable (bats)

Behavior changes are test-first. New or changed behavior MUST ship with `bats`
coverage under `tests/`, and tests SHOULD be written before the implementation
they cover.

- The default suite (`bats tests/`) MUST run on the host with no Docker daemon.
  Docker-dependent end-to-end tests MUST be gated behind `DOCKER_E2E=1` and MUST
  NOT be required for the default suite to pass.
- Shared libraries sourced by both runtime CLIs (e.g. `heartbeatctl`) and tests
  MUST guard initialization with `BASH_SOURCE`-style checks so that sourcing has
  no side effects.
- Shell code MUST pass the repo's `shellcheck` gate (`-S error`).

**Rationale**: A fast, hermetic, host-runnable suite is what makes the launcher
safe to change rapidly; Docker-gated e2e covers the integration seams without
slowing the inner loop.

### IV. Idempotent, Fail-Silent Lifecycle

Boot, patch, install, and backup steps MUST be safely re-runnable and MUST
degrade gracefully rather than crash the supervisor or heartbeat.

- Idempotency MUST be enforced by explicit guards: sentinels (`.installed-ok`),
  marker comments (plugin-patch / SPECKIT markers), or content hashes — never by
  mtime alone.
- Plugin patches and other transforms against upstream code MUST fail-silent
  (log a warning, leave default behavior intact) when their anchor regexes drift.
- Notifiers MUST always exit 0 and emit their `{channel, ok, latency_ms, error}`
  JSON envelope; a notifier MUST NOT be able to crash a heartbeat tick.

**Rationale**: The supervisor restarts things on a 2-second poll and a crash
budget; any step that can hard-fail or double-apply turns recovery into an
outage.

### V. Workspace-Is-the-Agent; Durable, Never-Committed State

All agent state — OAuth login, Telegram pairing, sessions, plugin cache,
channels state, heartbeat logs, the vault — lives under the bind-mounted
`<workspace>/.state/`. The workspace directory IS the agent.

- `.state/` is gitignored, contains secrets/tokens, and MUST NEVER be committed
  or logged.
- State MUST survive `docker compose down -v`, image rebuilds, and
  `setup.sh --uninstall` (non-`--purge`/`--nuke`).
- Backups are three INDEPENDENT orphan branches (`backup/identity`,
  `backup/vault`, `backup/config`) with sha256 content idempotency and per-branch
  clone caches. They MUST NOT be merged into a shared primitive; each MUST be able
  to be absent without breaking the others; changes MUST preserve
  `setup.sh --restore-from-fork` (restore order: config → identity → vault).

**Rationale**: Portability (rsync the dir), disaster recovery (rehydrate from a
fork without re-login), and a clean separation of threat models across backup
branches.

### VI. Reproducible, Intentionally-Pinned Dependencies

Dependencies MUST be upgradeable deliberately, not by silent drift. A versioned
dependency SHOULD have a single source of truth rather than the same literal
duplicated across `docker/Dockerfile`, `setup.sh`, `agent.yml`, and CI.

- Image-baked toolchain versions (Claude Code, Alpine base, `uv`, `bun`, `gum`)
  MUST be pinned to explicit versions; Claude Code's in-container auto-updater
  MUST remain disabled (`DISABLE_AUTOUPDATER=1`) so version changes are
  intentional image rebuilds.
- When a chosen version must reach the build, it MUST be plumbed through (e.g.
  compose `build.args`) rather than relying on a hardcoded Dockerfile default the
  documented build path cannot override.
- New duplicate pins MUST NOT be introduced; existing duplicates SHOULD be
  consolidated when touched.
- User-facing changes MUST be recorded in `CHANGELOG.md` and reflected in the
  launcher `VERSION` file; `meta.launcher_version` (surfaced by `agentctl doctor`)
  tracks the launcher revision that scaffolded/regenerated a workspace.

**Rationale**: Reproducible builds and painless, auditable upgrades. Drift
between duplicated pins is a latent bug; a deliberate, single-sourced pin makes
"upgrade Claude Code" a one-line, reviewable change.

## Platform & Toolchain Constraints

- **Host (launcher)**: `bash` 4+, `git`, `jq`, BSD/GNU `sed`; `yq` v4+
  (auto-vendored to `scripts/vendor/bin/` when missing/old); `gum` optional with a
  non-gum `read`-based fallback in `scripts/lib/wizard.sh` (no gum-only behavior).
- **Image**: Alpine-based, single-stage; UID/GID baked at build from the host;
  the macOS GID-20 (`staff`) vs Alpine `dialout` collision handling in the
  Dockerfile MUST be preserved.
- **Cross-platform**: the wizard MUST tolerate both macOS (BSD) and Linux (GNU)
  `sed`, and detect the host timezone on both.
- **Render engine**: templates use `{{var}}`, `{{#if}}`/`{{#unless}}`, and
  `{{#each}}` blocks resolved by `scripts/lib/render.sh`; new fields flattened from
  YAML follow the existing `section.key → $SECTION_KEY` convention. Identifiers
  used as filenames/branches/container names MUST be normalized (lowercase, no
  spaces) the same way `agent_name` is.

## Development Workflow & Quality Gates

- **Regenerate-safety gate**: any new derived output MUST be produced by
  `--regenerate` from `agent.yml`; hand-authored runtime files are not allowed to
  drift from their templates.
- **Test gate**: `bats tests/` (host, no Docker) MUST pass; Docker-e2e
  (`DOCKER_E2E=1`) MUST pass for changes touching `docker/` or boot/supervisor
  behavior. `shellcheck` MUST be clean.
- **Privilege gate**: changes under `docker/` MUST be reviewed against Principle
  II before merge.
- **Documentation gate**: user-facing changes update `CHANGELOG.md` and, when the
  launcher contract changes, the relevant `docs/` reference and `VERSION`.
- **Scope discipline**: keep units small and single-purpose; the three backup
  primitives stay independent (Principle V); do not re-introduce reverted designs
  (e.g. the bridge watchdog) without first solving their documented failure mode.

## Governance

This constitution supersedes ad-hoc practice for this repository. It governs how
the launcher is changed, not the personality of any scaffolded agent (that lives
in `modules/claude-md.tpl` and each agent's own `agent.yml`).

- **Amendments**: proposed via PR that edits this file, states the version bump
  and rationale, and updates any dependent templates in `.specify/templates/` in
  the same change. Principle additions/removals/redefinitions require explicit
  justification.
- **Versioning policy**: semantic versioning of this document — MAJOR for
  backward-incompatible governance/principle changes, MINOR for a new principle or
  materially expanded guidance, PATCH for clarifications and wording.
- **Compliance review**: every PR and `/speckit-plan` Constitution Check MUST
  verify alignment with these principles; violations MUST be recorded in the
  plan's Complexity Tracking with a justification and the rejected simpler
  alternative, or the change MUST be revised.
- **Runtime guidance**: `CLAUDE.md` (repo root) remains the operational guide for
  working in this codebase and is read alongside this constitution.

**Version**: 1.0.0 | **Ratified**: 2026-06-18 | **Last Amended**: 2026-06-18
