# Contract — QMD runtime CLI (image-baked)

**Date**: 2026-06-28 · **Branch**: `010-self-managing-rag`

Function/command contracts for the new image-baked code. All shell, all run as `agent`. Libs guard side-effects at source-time (`BASH_SOURCE` pattern) so the bats suite can source them without firing the boot path.

---

## Lib: `docker/scripts/lib/qmd_index.sh`

Sources `backup_vault.sh` to reuse `vault_resolve_root` and `vault_hash` (no duplicate resolver/hasher).

### `qmd_pkg [agent_yml]`
- **Returns** (stdout): `@tobilu/qmd@<version>` where version = `yq -r '.vault.qmd.version // "2.5.3"' <agent_yml>`. Default agent_yml `/workspace/agent.yml`.
- **Single-source** of the pin for every `bunx` call below (D2).

### `qmd_cache_root [agent_yml]`
- **Returns** (stdout): the QMD cache dir for the agent. Default `$HOME/.cache/qmd`. (Override hook for tests via `QMD_CACHE_HOME`/env; production uses the default which lands under `.state`.)

### `qmd_setup_if_needed [agent_yml]`
- **Pre**: `vault.qmd.enabled = true` and `vault.enabled = true`; else **return 0 (no-op)** (FR-012).
- **Idempotency** (FR-003): return 0 immediately if sentinel `<qmd_cache_root>/.qmd-setup-ok` exists AND `<qmd_cache_root>/index.sqlite` exists.
- **Action**: `timeout <T> bunx $(qmd_pkg) collection add <vault_root>` then `update` then `embed`; on success `touch` the sentinel.
- **Failure** (FR-011): any `bunx` non-zero/timeout → log a WARN, do NOT write the sentinel, **return 0** (caller continues; retried next boot). Never exits non-zero.
- **Invariant**: never blocks indefinitely; every external call is `timeout`-bounded. The *caller* (`start_services.sh`) backgrounds this whole function so boot is not delayed (D4).

### `qmd_reindex [agent_yml]`
- **Pre**: `vault.qmd.enabled = true`; else return 0.
- **Concurrency** (FR-007): acquire non-blocking `flock` on `<qmd_cache_root>/.reindex.lock` (fd-based, `flock -n`). If not acquired → log "reindex already running — skip", return 0.
- **Debounce** (FR-008): compute `current=$(vault_hash <vault_root>)`; read `last=$(jq -r '.hash' qmd-index.json)`. If `current == last` → write state with `last_status:"skipped"`, return 0 (no embed).
- **Reindex**: else `timeout <T> bunx $(qmd_pkg) update && timeout <T> bunx $(qmd_pkg) embed`. On success write state `{hash:current, last_status:"indexed", last_run, runs++}`. On failure write `last_status:"error"` WITHOUT updating `hash` (so the next run retries), release lock, return 0 (fail-silent).
- **State file** (FR-010): `/workspace/scripts/heartbeat/qmd-index.json`, atomic tmp+mv (mirror `vault_write_state`).
- **Returns**: always 0 (never crashes a cron tick or the watcher).

### State helpers
- `qmd_last_hash <state_file>` → `.hash` or empty (mirror `vault_last_hash`).
- `qmd_write_state <state_file> <hash> <status> <runs>` → atomic write (mirror `vault_write_state`).

---

## Script: `docker/scripts/qmd_watch.sh`

Standalone daemon (its own COPY + `chmod +x` in the Dockerfile).

- **Pre**: invoked by `start_services.sh` only when `vault.qmd.enabled=true`. Resolves `vault_root` via `qmd_index.sh::vault_resolve_root`.
- **Availability guard**: if `command -v inotifywait` fails → log "inotifywait unavailable — relying on cron backstop", exit 0 (FR: graceful degrade; cron still fresh).
- **Watch**: `inotifywait -r -m -e modify,create,delete,move "$vault_root"` (monitor mode, never exits on its own).
- **Debounce** (FR-005): on each event, (re)start a quiet timer; only after `QMD_WATCH_DEBOUNCE` (default ~15s) of no further events, invoke `heartbeatctl qmd-reindex` once. A burst of N events ⇒ exactly one reindex call.
- **Idempotency of effect**: the reindex it calls is itself flock'd + hash-debounced, so even if two debounce windows fire close together, no overlapping embed (D5).
- **Resilience**: the watch loop is wrapped so a transient `inotifywait` exit re-enters the loop; a hard failure exits non-zero and the watchdog respawns it.
- **Testability**: `inotifywait`, `heartbeatctl`, and the debounce interval are overridable via PATH stubs / env so `tests/qmd-watch.bats` drives it without inotify or Docker.

---

## Command: `heartbeatctl qmd-reindex`

New subcommand, molded on `cmd_backup_vault`.

- **`heartbeatctl qmd-reindex`** → sources `qmd_index.sh`, calls `qmd_reindex /workspace/agent.yml`.
- **`heartbeatctl qmd-reindex --dry-run`** → resolve + hash + report what would happen, no `embed`, no state write.
- **Dispatch**: `qmd-reindex) cmd_qmd_reindex "$@" ;;` in `main()`.
- **Help**: one line under the existing command list.
- **Exit**: always 0 on the cron path (fail-silent); `--dry-run` may return non-zero only on argument errors.

---

## Supervisor wiring: `docker/scripts/start_services.sh`

### `setup_qmd_if_needed` (boot)
- Called from `boot_side_effects()` **after** `seed_vault_if_needed`.
- Guard: `vault.qmd.enabled=true` else return 0.
- Runs `qmd_setup_if_needed` **backgrounded** in a timeout-bounded subshell (`( timeout <T> qmd_setup_if_needed ) &`), mirroring `_trigger_identity_backup`. Boot continues immediately (D4, FR-011).

### Watcher start + respawn
- At boot (when `vault.qmd.enabled`): start `qmd_watch.sh &`, record PID (e.g. `$WATCHDOG_RUNTIME_DIR/qmd-watch.pid`, on tmpfs).
- In `_run_watchdog` poll (2s): if QMD enabled AND the recorded PID is not alive → respawn `qmd_watch.sh`, update PID. **Deterministic liveness only** — no tmux scraping, no heuristic (CLAUDE.md / Principle IV). Counts toward NO crash budget (it's an independent helper, not the tmux session).

### No-op guarantee (FR-012)
- All three (`setup_qmd_if_needed`, watcher start, watchdog respawn branch) gate on `vault.qmd.enabled`. Disabled ⇒ none run; the only residue is unused functions. `cmd_reload` omits the cron line. `mcp-json.tpl` omits the `qmd` server.
