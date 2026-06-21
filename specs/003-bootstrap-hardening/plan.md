# Implementation Plan: Bootstrap hardening

**Branch**: `003-bootstrap-hardening` | **Date**: 2026-06-20 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `specs/003-bootstrap-hardening/spec.md`

## Summary

Nine surgical fixes to the agent bootstrap, grouped by severity (P1/P2/P3), all sized against
existing seams (no re-architecture). P1 makes silent failures loud or automatic (login→plugins
auto-install via a watchdog auth-marker flip; a pre-creation fork-public warning; plugin-install
retry + distinct logging surfaced in `doctor`/NEXT_STEPS). P2 validates inputs (destination,
agent-name normalization) and pins the quickstart doc to the canonical wizard order with a test.
P3 removes noise/data-loss edges (no identity-backup spam when fork-less; CLAUDE.md refresh
preserves all sections; multi-line persona via `agent.yml.role_file`). Mechanism decisions were
resolved via `/refine` and recorded in [research.md](./research.md). 8/9 stories are covered by
host `bats` with no Docker; only **H** needs `DOCKER_E2E=1` for its behavioral assertion (and even
H gets a host prompt-text test, so the default suite stays Docker-free).

## Technical Context

**Language/Version**: Bash 4+ (host launcher: `setup.sh`, `scripts/lib/*.sh`); busybox `ash`/POSIX sh + `claude`/`tmux`/`crond` (image-baked: `docker/scripts/*`); Python 3 only where already present.

**Primary Dependencies**: `yq` v4+, `jq`, `git`, `gh`, `bats-core` (host); `claude` CLI, `tmux`, busybox `crond` (container). No new dependencies introduced.

**Storage**: `agent.yml` (single source of truth) → derived files via `scripts/lib/render.sh`; durable `.state/` bind-mount. New runtime artifact: `.state/plugin-install-failures.jsonl` (Story C).

**Testing**: `bats tests/` (default suite, host, NO Docker daemon). `DOCKER_E2E=1` opt-in for Story H behavior only. `shellcheck -S error` gate on all touched shell.

**Target Platform**: macOS/Linux host (launcher) + Alpine 3.x container (agent runtime).

**Project Type**: CLI / bash tooling that scaffolds Dockerized Claude agents (three code paths: host launcher, image-baked, workspace-templated).

**Performance Goals**: N/A — surgical changes; watchdog tick stays O(1) file-stat per ~2s.

**Constraints**: No weakening of the least-privilege container model; every behavior survives `./setup.sh --regenerate`; default test suite must not require Docker.

**Scale/Scope**: 9 stories; ~5 host shell libs/functions added or extracted, ~6 new/changed bats files, 2 doc updates, 1 image-baked prompt rewrite, 1 `DOCKER_E2E` test.

## Constitution Check

*GATE: passed before Phase 0; re-checked after Phase 1 design (below). Source: `.specify/memory/constitution.md` (v1.0.0).*

- [x] **I. Single Source of Truth** — PASS. B writes `fork.enabled/private` and I writes `role_file` into `agent.yml` **before** rendering; both survive `--regenerate` (I re-reads `role_file` content each render). No derived file is hand-edited. C's failure list is runtime state, not a derived/template file.
- [x] **II. Least-Privilege (NON-NEGOTIABLE)** — PASS (no change). Every touched path is wizard logic, watchdog shell, prompt text, render, docs, or tests. No `cap_*`, mount, socket, or `-u agent` change.
- [x] **III. Test-First, Host-Runnable** — PASS. 8/9 stories: host `bats` via the `START_SERVICES_NO_RUN=1`/`load_lib` source-and-mock patterns already in the repo. H: host **prompt-text** test in the default suite + a `DOCKER_E2E=1` behavioral test (gated, not required by `bats tests/`). All new shell stays `shellcheck -S error` clean; sourced libs guard init.
- [x] **IV. Idempotent, Fail-Silent Lifecycle** — PASS. A re-install is idempotent (`.installed-ok` sentinel); C retry is bounded (3) and continues the boot on exhaustion (fail-loud via `doctor`, not fail-stuck); G is a pure early-exit; H keeps the 90s timeout + skip-on-error. B intentionally **fails loud** on a visibility-probe error (the correct failure mode for a pre-creation safety check — it must not silently proceed).
- [x] **V. Workspace-Is-the-Agent** — PASS. C's `plugin-install-failures.jsonl` lives under `.state/` (gitignored, durable, bind-mounted, read by host `agentctl doctor`). No secrets logged; no state committed.
- [x] **VI. Reproducible, Pinned Dependencies** — N/A for deps (no version changes). CHANGELOG/VERSION discipline applies: user-facing changes (B warning, E confirm prompt, I `--role-file`, F doc) recorded in `CHANGELOG.md`; `VERSION` bumped at feature completion.

**Result: PASS, no violations → Complexity Tracking empty.**

## Project Structure

### Documentation (this feature)

```text
specs/003-bootstrap-hardening/
├── plan.md              # This file
├── spec.md              # Feature spec (refined)
├── research.md          # Phase 0 — decisions + grounded code map
├── data-model.md        # Phase 1 — entities
├── quickstart.md        # Phase 1 — how to verify each tier
├── contracts/           # Phase 1 — interface contracts
│   ├── agent-yml-role_file.md
│   ├── doctor-failed-plugins.md
│   └── wizard-canonical-order.md
└── tasks.md             # Phase 2 (/speckit-tasks — not created here)
```

### Source Code (repository root) — files this feature touches

```text
# Host-side launcher (Bash 4+)
setup.sh                              # B fork-warning; D destination validation wiring; E normalize+confirm; I --role-file flag + agent.yml heredoc
scripts/lib/wizard-validators.sh      # D validate_destination_path(); E normalize_agent_name()
scripts/lib/wizard.sh                 # B gh_get_repo_visibility() helper (or inline near fork block)
scripts/lib/render.sh                 # I role_file → AGENT_ROLE_MULTILINE
scripts/lib/schema.sh                 # I optional role_file path leaf
scripts/agentctl                      # C cmd_doctor surfaces failed plugins
modules/claude-md.tpl                 # I conditional multiline role injection
modules/next-steps.en.tpl             # C failed-plugins retry section

# Image-baked (docker/) — POSIX sh
docker/scripts/start_services.sh      # A watchdog auth-flip; C ensure_plugin_installed_one/all; G _check_identity_backup early-exit
docker/scripts/lib/plugin-install.sh  # C (NEW) retry_plugin_install_bounded()
docker/scripts/wizard-container.sh    # H rewrite claude --print refresh prompt

# Docs
docs/agentic-quickstart.es.md         # F insert 6 optional-MCP step
docs/agentic-quickstart.en.md         # F insert 6 optional-MCP step

# Tests (bats) — default suite host, no Docker (except H's DOCKER_E2E case)
tests/watchdog-auth-flip-detection.bats   # A (NEW)
tests/fork-commands.bats                  # B (extend)
tests/start-services-plugin-install.bats  # C (NEW)
tests/wizard-validators.bats              # D (extend)
tests/agent-name-normalization.bats       # E (NEW)
tests/quickstart-doc.bats                 # F (extend)
tests/start-services-watchdog.bats        # G (extend)
tests/wizard-container-refresh.bats       # H host prompt-text test (NEW)
tests/docker-e2e-claude-md-refresh.bats   # H DOCKER_E2E behavior (NEW)
tests/render.bats                         # I (extend) role_file render
tests/fixtures/sample-agent-with-vault.yml # I add role_file field
CHANGELOG.md · VERSION                    # cross-cutting
```

**Structure Decision**: No new top-level structure — the feature edits the three existing code
paths in place (host launcher / image-baked / templates) plus their bats coverage. New shell
logic is extracted into sourceable functions/libs precisely so the default suite can unit-test it
without Docker (Principle III).

## Complexity Tracking

> No constitution violations. Section intentionally empty.
