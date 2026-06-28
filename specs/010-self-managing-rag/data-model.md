# Phase 1 — Data Model: Self-Managing RAG (010)

**Date**: 2026-06-28 · **Branch**: `010-self-managing-rag`

This feature is shell + filesystem, not a database schema. "Entities" here are the config keys, on-disk artifacts, and state files the feature reads/writes, plus their validation rules and lifecycle.

---

## E1 — QMD configuration (in `agent.yml`)

Single source of truth (Principle I). Lives under `vault.qmd`:

| Key | Type | Required | Default | Validated by |
|-----|------|----------|---------|--------------|
| `vault.qmd.enabled` | boolean | no (default false) | `false` | `schema.sh` `_SCHEMA_BOOLEANS` |
| `vault.qmd.version` | string | no | `"2.5.3"` | `schema.sh` `_SCHEMA_OPTIONAL_NONEMPTY` |
| `vault.qmd.schedule` | string (cron) | no | `"*/5 * * * *"` | `schema.sh` `_SCHEMA_OPTIONAL_NONEMPTY` |

Rendered/consumed:
- `vault.qmd.enabled` → `$VAULT_QMD_ENABLED` (render context) → gates the `qmd` block in `mcp-json.tpl`.
- `vault.qmd.version` → `$VAULT_QMD_VERSION` → `"@tobilu/qmd@{{VAULT_QMD_VERSION}}"` in `mcp-json.tpl`; also read at runtime by `qmd_index.sh` (`yq -r '.vault.qmd.version // "2.5.3"'`).
- `vault.qmd.schedule` → read by `heartbeatctl cmd_reload` for the cron line.

Relationship: `vault.qmd.*` is meaningful only when `vault.enabled = true` (QMD indexes the vault). If `vault.enabled=false`, the whole subtree is inert.

---

## E2 — Embedding model (on disk, durable)

- **Location**: `~/.cache/qmd/models/` = `/home/agent/.cache/qmd/models/` → `<workspace>/.state/.cache/qmd/models/`.
- **Origin**: downloaded from HuggingFace by QMD on first `embed` (~300MB).
- **Lifecycle**: created once at first-boot setup; persists across restarts/rebuilds (under `.state`); never committed/logged (Principle V); never backed up (regenerable).
- **Validation**: presence is part of the setup idempotency guard (E5).

## E3 — Vault index (on disk, durable, regenerable)

- **Location**: `~/.cache/qmd/index.sqlite` → `<workspace>/.state/.cache/qmd/index.sqlite`.
- **Origin**: `qmd collection add <vault_root>` + `qmd update` + `qmd embed`.
- **Lifecycle**: built at setup; refreshed by every `qmd_reindex`; regenerable from the vault markdown at any time → intentionally NOT in `backup/vault` (only the markdown is backed up; the index is derived).
- **Freshness criterion**: `qmd_reindex` rebuilds it only when the vault content hash (E6) changed.

## E4 — Vault root (input corpus)

- **Resolution**: `vault_resolve_root agent.yml` (existing in `backup_vault.sh`) → `/home/agent/.vault` (default) or rebased non-default path. `qmd_index.sh` reuses this resolver — no second implementation.
- **Content**: markdown notes under the vault skeleton; the same set `vault_list_markdown` enumerates (excludes `.obsidian/cache`, `.trash`, sync-conflicts, etc.).

---

## E5 — Setup state (sentinel)

- **Artifact**: `<vault .cache>/qmd/.qmd-setup-ok` (touch-file sentinel) — combined with `index.sqlite` presence.
- **Semantics**: `qmd_setup_if_needed` is a no-op when the sentinel exists AND `index.sqlite` exists (FR-003, idempotency by presence not mtime). Absent/partial → (re)run `collection add` + `update` + `embed`, then touch the sentinel on success.
- **Failure**: on setup failure (no network, timeout) the sentinel is NOT written → next boot retries (US1 scenario 3).

## E6 — Reindex state file `qmd-index.json`

- **Location**: `/workspace/scripts/heartbeat/qmd-index.json` (under `.state`, alongside `vault-backup.json`).
- **Shape** (atomic write via tmp+mv, mirrors `vault_write_state`):

```json
{
  "hash": "<sha256 of vault markdown content+filenames>",
  "last_run": "2026-06-28T22:10:03Z",
  "last_status": "indexed|skipped|error",
  "runs": 42
}
```

- **`hash`**: from `vault_hash` (reused from `backup_vault.sh`). Equality with the current vault hash ⇒ `qmd_reindex` skips the costly `embed` and records `last_status: "skipped"` (FR-008).
- **Lifecycle**: written after every `qmd_reindex` invocation (whether it embedded or skipped). Read at the start of each reindex for the debounce decision (E6 ↔ E3).

## E7 — Reindex lock (concurrency)

- **Artifact**: `<vault .cache>/qmd/.reindex.lock`, held via non-blocking `flock` for the duration of a `qmd_reindex` run.
- **Semantics**: if the lock is held (watcher + cron overlap, or a long embed), the second caller logs "reindex already running — skip" and returns 0 without touching the index/state (FR-007). Guarantees no overlapping `embed` corrupts `index.sqlite`.

---

## E8 — Watcher process

- **Process**: `qmd_watch.sh` running `inotifywait -r -m -e modify,create,delete,move <vault_root>`, owned by `agent`.
- **State**: in-memory debounce timer only (no persisted state); coalesces a burst into one `heartbeatctl qmd-reindex` after ~15s quiet.
- **Lifecycle**: started by `start_services.sh` at boot when `vault.qmd.enabled`; PID tracked so the 2s watchdog poll respawns it if dead (deterministic liveness). Self-exits (logged, non-fatal) if `inotifywait` is unavailable → cron backstop carries freshness.

---

## State transitions (reindex)

```text
                 ┌─────────────────────────────────────────────┐
   trigger ──▶  flock acquire ──┬─ held? ─▶ log "skip", return 0 (E7)
   (watcher /                   │
    cron)                       └─ got lock
                                      │
                          current_hash = vault_hash(vault_root)   (E6)
                                      │
                       current_hash == state.hash ?
                          │ yes                  │ no
                          ▼                      ▼
                  last_status=skipped    qmd update && qmd embed   (E3)
                  write qmd-index.json   last_status=indexed
                  release lock           write hash + qmd-index.json
                                         release lock
```

All `qmd`/`bunx` invocations in the above are `timeout`-bounded and fail-silent (Principle IV); a failed embed records `last_status:"error"` and releases the lock without leaving a partial index marked fresh.
