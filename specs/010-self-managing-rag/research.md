# Phase 0 — Research: Self-Managing RAG (010)

**Date**: 2026-06-28 · **Branch**: `010-self-managing-rag`

Resolves the unknowns flagged by the spec and the brainstorm. Every decision is grounded in the npm registry, the package README, the repo's own code, or `docs/architecture.md`.

---

## D1 — QMD stable version to pin

**Decision**: Pin to **`@tobilu/qmd@2.5.3`** (the current `latest` dist-tag and most recent stable).

**Rationale**: The npm registry (`https://registry.npmjs.org/@tobilu/qmd`, fetched 2026-06-28) lists published versions `0.9.0, 1.0.0, 1.0.5, 1.0.6, 1.0.7, 1.1.1, 1.1.2, 1.1.5, 1.1.6, 2.0.0, 2.0.1, 2.1.0, 2.5.1, 2.5.2, 2.5.3`. `latest` = **2.5.3**; all entries are non-prerelease. The 2.5.3 README confirms the CLI surface this feature depends on — `collection add/remove/rename/list`, `embed`, `update`, `search`/`vsearch`/`query`, `status`, `cleanup`, `mcp` — matching the setup contract documented in `docs/architecture.md:263` (`collection add` + `update` + `embed`).

**Correction of a prior assumption**: The spec's Assumptions and an internal memory claimed the stable release was **v0.4.4**. **No 0.4.x version exists** on npm; `bunx @tobilu/qmd@0.4.4` would fail to resolve. The spec assumption and the memory are corrected to 2.5.3. This is exactly the drift a research-first phase exists to catch.

**Alternatives considered**:
- *Stay on `@latest`* — rejected: violates Principle VI (reproducibility); two scaffolds of the same `agent.yml` could differ.
- *Pin an older major (1.x / 2.0.1)* — rejected: 2.5.3 is the maintained head with the same documented CLI; no evidence an older line is more stable. The pin is trivially adjustable later if a 2.5.3 regression surfaces (the spec already hedges this).

---

## D2 — Single source of truth for the QMD version pin (Principle VI)

**Decision**: Store the version once in `agent.yml` as **`vault.qmd.version`** (default `"2.5.3"`, written by `setup.sh`). Both consumers read it from there:
- `modules/mcp-json.tpl` renders `"@tobilu/qmd@{{VAULT_QMD_VERSION}}"` (replacing the literal `@latest`).
- `docker/scripts/lib/qmd_index.sh` reads `yq -r '.vault.qmd.version // "2.5.3"' /workspace/agent.yml` for its `bunx` setup/reindex calls.

**Rationale**: Principle VI forbids new duplicate pins; Principle I makes `agent.yml` the single source of truth. Hardcoding `@tobilu/qmd@2.5.3` in *both* the template and the lib would be a duplicate pin. Routing both through `agent.yml` keeps one literal (the `setup.sh` default), re-renders correctly under `--regenerate`, and lets the schema validate it.

**Alternatives considered**:
- *Hardcode in template + lib* — rejected: duplicate pin (Principle VI).
- *Add to `scripts/lib/versions.sh`* — rejected: `versions.sh` is host build-time tooling for image-baked toolchain ARGs; QMD is a runtime `bunx` package, not built into the image, and the template renders host-side from `agent.yml`, not from `versions.sh`.

---

## D3 — Where QMD stores the model + index, and how it persists

**Decision**: Rely on QMD's defaults — index at `~/.cache/qmd/index.sqlite`, embedding models at `~/.cache/qmd/models/`. Inside the container `~` = `/home/agent`, and `<workspace>/.state/` bind-mounts to `/home/agent/`, so both land at `<workspace>/.state/.cache/qmd/` and **persist across restarts/rebuilds with no extra wiring** (Principle V). No `XMD_CACHE_HOME`/`QMD_CACHE_HOME` override needed.

**Rationale**: Confirmed from the 2.5.3 README (storage paths + `XMD_CACHE_HOME` override env). Because the model/index live under the durable agent home, the "workspace-is-the-agent" durability is automatic; the cache survives `docker compose down -v` and image rebuilds like the rest of `.state`.

**Consequence — why the model must download at first boot (not be pre-baked)**: The image can't pre-bake the ~300MB model under `/home/agent/.cache`, because the `.state` bind-mount **shadows** `/home/agent` at runtime (same reason `docker/Dockerfile:160-182` pre-warms npm MCPs into `/opt/npm-cache`, off the bind-mount, not under home). Pre-baking under `/opt` + `XMD_CACHE_HOME` was considered and rejected: it bloats every image by ~300MB even for QMD-disabled agents (violates opt-in zero-touch, FR-012) and the env-var spelling is uncertain in the README. First-boot download into `.state` is the correct path.

---

## D4 — Auto-setup placement and non-blocking execution (US1, FR-011)

**Decision**: A `qmd_setup_if_needed()` (in `qmd_index.sh`, sourced by `start_services.sh`) runs from `boot_side_effects()` **immediately after `seed_vault_if_needed`**, but **backgrounded inside a timeout-bounded subshell** (mirroring `_trigger_identity_backup`'s `( timeout N … ) &` pattern). Boot continues and the watchdog starts without waiting on the ~300MB download.

**Rationale**: FR-011 + Principle IV forbid hanging the supervisor before the watchdog. A synchronous ~300MB HuggingFace download in `boot_side_effects` would delay watchdog start by minutes. Backgrounding it (with an outer `timeout`, e.g. 900s, and `GIT/HF` non-interactive) keeps boot fast and self-healing. Idempotency guard: a sentinel `<vault .cache>/qmd/.qmd-setup-ok` plus presence of `index.sqlite` — on subsequent boots setup short-circuits (FR-003, hash/sentinel not mtime).

**Degradation while setup runs (first boot only)**: The `qmd` MCP server in `.mcp.json` may fail its first handshake until the model+index exist; keyword search (`@bitbonsai/mcpvault`) keeps working, and semantic search comes online once setup finishes and the next session attaches. This is the graceful-degradation path (US1 scenario 3, Principle IV), not an error.

**Bun cache warm side-effect**: Running `bunx @tobilu/qmd@2.5.3 …` during setup warms bun's package cache (`~/.bun`, under `.state`), so the later `bunx @tobilu/qmd@2.5.3 mcp` MCP launch resolves offline — analogous to the uv/npm pre-warm rationale.

---

## D5 — Reindex routine: single entry point, flock-guarded, hash-debounced (US2, FR-004/005/007/008)

**Decision**: One idempotent routine `qmd_reindex` in `docker/scripts/lib/qmd_index.sh`, invoked through a **single command** `heartbeatctl qmd-reindex` (new subcommand, molded on `cmd_backup_vault`). Both triggers call that command:
- **Concurrency**: `qmd_reindex` takes a non-blocking `flock` on `<vault .cache>/qmd/.reindex.lock`; if held, it logs "reindex already running — skip" and returns 0 (FR-007). `flock` is already in the image (`docker/Dockerfile:45`).
- **Hash-debounce**: reuse the vault content hash from `backup_vault.sh::vault_hash` (sha256 over markdown filenames+content). If the current hash equals the last recorded hash in `qmd-index.json`, skip the costly `embed` (FR-008). Else run `bunx @tobilu/qmd@<ver> update && … embed`, then write the new hash.
- **State**: atomic `qmd-index.json` under `scripts/heartbeat/` (`{hash, last_run, last_status, runs}`), same shape/atomic-write as `vault-backup.json` (FR-010).

**Rationale**: A single command shared by cron and watcher means one code path, one lock, one state file — no divergence. Reusing `vault_hash` avoids a second hashing implementation and guarantees the index-freshness criterion matches the backup criterion (a rename counts as a change). Molding on `cmd_backup_vault` keeps the heartbeatctl surface consistent and testable (the lib is host-runnable; the bats suite already tests `backup-vault` the same way).

**Alternatives considered**:
- *Watcher sources `qmd_index.sh` directly (not via heartbeatctl)* — rejected: two entry points to keep in sync; the command indirection is one `exec` and gives identical flock/state semantics.
- *Separate hash impl in `qmd_index.sh`* — rejected: duplicates `vault_hash`; source `backup_vault.sh` and reuse it.

---

## D6 — Immediate trigger: inotify watcher with debounce (US2a)

**Decision**: A daemon `docker/scripts/qmd_watch.sh` (image-baked, its own COPY + chmod) runs `inotifywait -r -m -e modify,create,delete,move <vault_root>` (package **`inotify-tools`**, to add to the Dockerfile apk list). Events are coalesced with a **debounce of ~15s of quiet** before calling `heartbeatctl qmd-reindex`. Started from `start_services.sh` when `vault.qmd.enabled`; the 2s watchdog poll **respawns it if its PID is dead** (deterministic liveness check).

**Rationale**: A filesystem watcher captures every vault change regardless of origin — MCPVault writes, the agent's native Write/Edit, and **Syncthing-pushed** changes (the rodri-cenco-admin case) — which an agent-side hook cannot. Debounce coalesces ingest bursts into a single reindex (FR-005; one embed pass, not N). `inotify_add_watch` needs **no Linux capability** for files the agent can already read, so Principle II is intact (verify in DOCKER_E2E that inotify fires under the bind-mount). The respawn is a plain "is PID alive?" check — explicitly **not** the reverted heuristic bridge watchdog (tmux-pane scraping), so it doesn't reintroduce that false-positive failure mode (CLAUDE.md; commit `ebfe35f`).

**Known limitation (documented, not blocking)**: On macOS dev hosts, inotify under VirtioFS may not deliver events for host-originated changes. The cron backstop (D7) covers this — the index stays fresh within ≤5 min even where the watcher is blind. On the Linux production node (Ferrari RPi5) inotify fires for all in-kernel bind-mount writes including Syncthing's. The watcher self-degrades: if `inotifywait` is absent or errors, it logs and exits; the supervisor doesn't crash and cron carries the load.

**Alternatives considered**:
- *Agent-side reindex hook* — rejected in brainstorm: depends on the agent remembering; misses Syncthing/external writes.
- *Supervise the watcher with the full watchdog state machine* — unnecessary: a PID-liveness respawn + cron backstop is sufficient and avoids touching the delicate crash-budget logic.

---

## D7 — Periodic backstop cron (US2b)

**Decision**: Add a sixth conditional line to `heartbeatctl::cmd_reload`'s crontab: `<schedule> /usr/local/bin/heartbeatctl qmd-reindex >> …/logs/qmd-reindex.log 2>&1`, guarded by `vault.qmd.enabled = true`, schedule `vault.qmd.schedule // "*/5 * * * *"`. Mirrors the existing `backup-vault` line exactly.

**Rationale**: The watchdog/crontab path is already the established mechanism (`heartbeatctl reload` → staging crontab → entrypoint root-sync → `/etc/crontabs/agent`). Adding a conditional line is a one-block change with an existing test pattern (`tests/backup-vault-cmd.bats`). The backstop guarantees freshness even if the watcher died or missed an event (SC-003, ≤5 min). Both triggers share the flock'd `qmd_reindex`, so cron+watcher overlap is safe (D5).

**Insertion point**: `docker/scripts/heartbeatctl::cmd_reload`, after the token-health line (~L234), before the `cat > "$tmp_crontab"` heredoc; add `${qmd_reindex_line}` to the heredoc body. New subcommand `cmd_qmd_reindex` before `main()`; dispatch `qmd-reindex) cmd_qmd_reindex "$@" ;;`.

---

## D8 — Schema validation for vault.qmd.* (US3, FR-014)

**Decision**: Extend `scripts/lib/schema.sh`:
- `_SCHEMA_BOOLEANS` += `'.vault.qmd.enabled'` (catches `enabled: yes` typos; tolerant of absent via the existing `_schema_get`/false-survival logic from fix 002/005).
- `_SCHEMA_OPTIONAL_NONEMPTY` += `'.vault.qmd.version'` (if present, must be non-empty) and `'.vault.qmd.schedule'` (if present, non-empty).

**Rationale**: Today `vault.*` is unvalidated. These are the keys this feature reads at boot; a typo (`enabled: ture`, empty `version`) should fail loud during scaffolding (`agent_yml_validate` runs in `setup.sh`), not silently at runtime. Reuses the established arrays and the boolean-false-safe `_schema_get` (do not reintroduce the `// ""` collapse bug fixed in 002/005).

**Out of scope**: Cron-expression *syntax* validation of `vault.qmd.schedule` — `wizard-validators.sh` already owns interval/cron validation for the heartbeat; replicating a full cron parser in `schema.sh` is overkill. Non-empty is enough here.

---

## D9 — Test strategy (Principle III, test-first)

**Decision**:
- **Host-side bats (no Docker), written first**:
  - `tests/qmd-index.bats` — `qmd_reindex` idempotence (same hash → embed skipped), hash-change → embed runs, flock concurrency (two concurrent calls → one runs, one skips), state-file shape. Stubs: a fake `bunx`/`qmd` on PATH and a `timeout` shim for macOS (pattern from 008/009).
  - `tests/qmd-setup.bats` — `qmd_setup_if_needed` idempotent (sentinel/index present → no re-run; absent → runs collection add+update+embed via stub).
  - `tests/qmd-watch.bats` — debounce/coalesce: a burst of stub `inotifywait` events yields exactly one `heartbeatctl qmd-reindex` call; absent `inotifywait` → clean no-op exit.
  - `tests/qmd-reindex-cmd.bats` — `cmd_reload` emits the cron line when `vault.qmd.enabled=true` (+ default `*/5` and `vault.qmd.schedule` override), omits it when false; `cmd_qmd_reindex` dispatch.
  - `tests/schema.bats` / `tests/mcp-json.bats` / `tests/scaffold.bats` — update the `@tobilu/qmd@latest` assertions to the pinned `@2.5.3`/`{{VAULT_QMD_VERSION}}`; add vault.qmd.* schema cases.
- **DOCKER_E2E (gated)**: extend `tests/docker-e2e-*` with a QMD-enabled vault: assert first-boot setup produces `index.sqlite` + model cache, a vault write triggers a reindex (watcher and/or cron), and inotify fires under the bind-mount. Mirror the compose-run gotchas (pre-create `.state`, `--entrypoint`, declare config).

**Rationale**: Principle III is test-first and host-runnable; the costly model download and inotify-under-bind-mount are the integration seams that only DOCKER_E2E can prove, so they're gated there. The host suite stays green and Docker-free.

---

## Resolved unknowns summary

| # | Unknown | Resolution |
|---|---------|-----------|
| D1 | QMD stable version | **2.5.3** (not 0.4.4 — doesn't exist) |
| D2 | Single-source the pin | `vault.qmd.version` in `agent.yml` |
| D3 | Model/index storage | `~/.cache/qmd/` → under `.state`, persists; download at first boot |
| D4 | Setup placement | backgrounded, timeout-bounded, from `boot_side_effects` |
| D5 | Reindex routine | `heartbeatctl qmd-reindex` → flock'd, hash-debounced `qmd_reindex` |
| D6 | Immediate trigger | `qmd_watch.sh` inotify + ~15s debounce; `inotify-tools` added |
| D7 | Periodic backstop | conditional `*/5` cron line in `cmd_reload` |
| D8 | Schema validation | `vault.qmd.{enabled,version,schedule}` in `schema.sh` |
| D9 | Tests | host-first bats + gated DOCKER_E2E |

No NEEDS CLARIFICATION remain.
