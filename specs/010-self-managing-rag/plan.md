# Implementation Plan: Self-Managing RAG (auto-setup + auto-reindex del vault QMD)

**Branch**: `010-self-managing-rag` | **Date**: 2026-06-28 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `specs/010-self-managing-rag/spec.md`

## Summary

When `vault.qmd.enabled` is true in `agent.yml`, make the QMD semantic-search engine over the agent's Obsidian vault self-managing: auto-download the embedding model + build the index at first boot (backgrounded, idempotent, fail-silent), and keep the index fresh automatically via a **dual trigger** — an inotify watcher (immediate, debounced) plus a `*/5` cron backstop — both routed through a single flock-guarded, hash-debounced `heartbeatctl qmd-reindex`. Pin the engine to a reproducible version sourced from `agent.yml` and validate the new config keys. When QMD is disabled, every path is a no-op.

Technical approach is fully resolved in [research.md](./research.md) (D1–D9). Key correction from Phase 0: the engine pins to **`@tobilu/qmd@2.5.3`** (latest stable); the previously-assumed `0.4.4` does not exist on npm.

## Technical Context

**Language/Version**: Bash (Alpine busybox + bash 5); host launcher bash 4+. Runtime engine `@tobilu/qmd@2.5.3` via `bunx` (bun 1.3.14, already in image).

**Primary Dependencies**: `inotify-tools` (NEW apk pkg, for `inotifywait`); `flock` (already in image, `Dockerfile:45`); `bun`/`bunx` (already in image); `yq`/`jq` (already in image). No host-side dependency changes.

**Storage**: QMD index `~/.cache/qmd/index.sqlite` + models `~/.cache/qmd/models/` → resolve under `<workspace>/.state/.cache/qmd/` via the `/home/agent` bind-mount (durable, Principle V). State file `scripts/heartbeat/qmd-index.json` (atomic, schema like `vault-backup.json`).

**Testing**: `bats` host-side (no Docker) for all unit/contract coverage; `DOCKER_E2E=1`-gated bats for first-boot setup + reindex + inotify-under-bind-mount. `shellcheck -S error` clean.

**Target Platform**: Alpine 3.24 container (cap_drop ALL + 3 caps + no-new-privileges), running on Linux (Ferrari RPi5 production) and macOS dev hosts. inotify fires on the Linux node; macOS dev degrades to the cron backstop.

**Project Type**: Single project — the launcher repo with its three code paths (host launcher / image-baked / workspace-templated). This feature touches image-baked + host-render + schema, not the workspace-templated heartbeat scripts.

**Performance Goals**: Index reflects a vault change <60s via watcher (SC-002), ≤5 min via cron backstop (SC-003); ingest burst of N notes → 1 embed pass (SC-004); boot not delayed by the model download (backgrounded, D4).

**Constraints**: Fail-silent, timeout-bounded, never hang the supervisor before the watchdog (Principle IV); no new container capability/mount/socket (Principle II); survives `--regenerate` (Principle I); opt-in zero-touch — zero cost when disabled (FR-012); single-sourced pin, no duplicate (Principle VI); CHANGELOG + VERSION 0.4.3→0.4.4.

**Scale/Scope**: ~3 new files (`qmd_index.sh`, `qmd_watch.sh`, plus tests), ~6 edited files (`start_services.sh`, `heartbeatctl`, `Dockerfile`, `mcp-json.tpl`, `schema.sh`, `setup.sh`), CHANGELOG/VERSION, doc touch-ups. Vault sizes: tens to low-hundreds of markdown notes.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-checked after Phase 1 design.*
*Source: `.specify/memory/constitution.md` (v1.0.0).*

- [x] **I. Single Source of Truth** — `vault.qmd.{enabled,version,schedule}` live in `agent.yml`; the QMD MCP line and the lib's `bunx` calls both read the version from `agent.yml` (no hardcoded literal in two places, D2). `mcp-json.tpl` re-renders under `--regenerate`; `qmd_index.sh`/`qmd_watch.sh`/`start_services.sh` are image-baked. No derived file is hand-edited. **PASS**
- [x] **II. Least-Privilege (NON-NEGOTIABLE)** — `inotifywait` + `flock` + `bunx` run as `agent`; `inotify_add_watch` needs no capability for readable files; no new mount/socket; cap set unchanged. DOCKER_E2E asserts inotify fires under the existing cap set. **PASS** (verify-in-e2e noted)
- [x] **III. Test-First, Host-Runnable** — host bats for setup idempotence, reindex hash-debounce, flock concurrency, watcher coalesce, cron line, schema; written before implementation. Default suite stays Docker-free; model-download + inotify-under-bind-mount gated behind `DOCKER_E2E=1`. `shellcheck` clean; new libs guard side-effects at source-time (BASH_SOURCE pattern). **PASS**
- [x] **IV. Idempotent, Fail-Silent** — setup guarded by sentinel + `index.sqlite` presence (not mtime); reindex by content hash + flock; every `bunx`/`qmd` boot call timeout-bounded and fail-silent; watcher self-degrades if `inotifywait` absent; cron logs to its own file. Supervisor never blocks on the model download (backgrounded). **PASS**
- [x] **V. Workspace-Is-the-Agent** — model/index/state live under bind-mounted `.state/` (`~/.cache/qmd`, `scripts/heartbeat/qmd-index.json`); never committed or logged; survive `down -v`/rebuild. No new backup branch; the existing `backup/vault` already covers the markdown (the derived index is regenerable, intentionally NOT backed up). **PASS**
- [x] **VI. Reproducible, Pinned** — pin `@tobilu/qmd@2.5.3` single-sourced via `agent.yml` (D1/D2); no new duplicate literal; CHANGELOG + VERSION 0.4.3→0.4.4; bun stays pinned. **PASS**

**Result**: All six PASS. No violations → Complexity Tracking empty.

## Project Structure

### Documentation (this feature)

```text
specs/010-self-managing-rag/
├── spec.md              # /speckit-specify output
├── plan.md              # this file
├── research.md          # Phase 0 — D1..D9 (done)
├── data-model.md        # Phase 1 — entities + state shapes
├── quickstart.md        # Phase 1 — validation scenarios
├── contracts/
│   ├── qmd-cli.md       # qmd_index.sh / qmd_watch.sh / heartbeatctl qmd-reindex contracts
│   └── agent-yml-schema.md  # vault.qmd.* schema + render contract
└── checklists/
    └── requirements.md  # /speckit-specify quality checklist (16/16)
```

### Source Code (repository root)

```text
# Image-baked (docker/ → /opt/agent-admin/ at build; read-only at runtime)
docker/
├── Dockerfile                      # + apk inotify-tools; + COPY qmd_index.sh, qmd_watch.sh (+chmod)
├── scripts/
│   ├── start_services.sh           # + setup_qmd_if_needed (boot, backgrounded); + start/respawn qmd_watch
│   ├── qmd_watch.sh                # NEW — inotifywait -m + debounce → heartbeatctl qmd-reindex
│   ├── heartbeatctl                # + cmd_qmd_reindex; + cron line in cmd_reload; + dispatch + help
│   └── lib/
│       └── qmd_index.sh            # NEW — qmd_setup_if_needed, qmd_reindex (flock+hash), state helpers

# Host-side render (single source agent.yml)
modules/mcp-json.tpl                # @latest → @{{VAULT_QMD_VERSION}}
scripts/lib/schema.sh               # + vault.qmd.{enabled,version,schedule} validation
setup.sh                            # + vault.qmd.version default in the agent.yml heredoc

# Tests (host-first; DOCKER_E2E gated)
tests/
├── qmd-index.bats                  # NEW — reindex idempotence/flock/state
├── qmd-setup.bats                  # NEW — setup idempotence
├── qmd-watch.bats                  # NEW — debounce/coalesce
├── qmd-reindex-cmd.bats            # NEW — cron line + dispatch
├── schema.bats / mcp-json.bats / scaffold.bats   # EDIT — pin assertions + vault.qmd schema
└── docker-e2e-*.bats               # EDIT/NEW — QMD first-boot setup + reindex + inotify

# Release discipline
CHANGELOG.md · VERSION (0.4.3 → 0.4.4)
docs/architecture.md                # note auto-setup + dual-trigger reindex
```

**Structure Decision**: Single-project launcher repo. The feature is overwhelmingly **image-baked** (boot/supervisor/lib), with a small **host-render** slice (template pin + schema + setup default sourced from `agent.yml`). It does NOT touch the workspace-templated heartbeat runner, the backup primitives, the auth/login flow, or the channel contract. Two new libs (`qmd_index.sh`, `qmd_watch.sh`) each need their Dockerfile COPY (the 008/009 lesson) and BASH_SOURCE side-effect guards.

## Complexity Tracking

> No constitution violations. Section intentionally empty.

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|--------------------------------------|
| — | — | — |
