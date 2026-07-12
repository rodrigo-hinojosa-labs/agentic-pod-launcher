# Data Model — 018 qmd Embed Completion

This feature is behavioral; it adds no new persistent store. It extends one existing state file and
consumes one existing engine-reported signal.

## Entity: Maintenance run state (`qmd-index.json`)

Existing file at `QMD_INDEX_STATE_FILE` (default `/workspace/scripts/heartbeat/qmd-index.json`),
written atomically by `qmd_write_state`. Extended backward-compatibly.

| Field         | Type    | Existing? | Description |
|---------------|---------|-----------|-------------|
| `hash`        | string  | yes       | Vault content hash of the last successful index. |
| `last_run`    | string  | yes       | UTC ISO-8601 timestamp of the last maintenance run. |
| `last_status` | string  | yes (values extended) | See status values below. |
| `runs`        | number  | yes       | Monotonic run counter. |
| `pending`     | number  | **new (optional)** | Documents still needing an embedding after the last run. `0` ⇒ vector index complete. Absent in pre-018 files ⇒ treated as unknown (forces a resume pass). |

### `last_status` values

| Value      | Existing? | Meaning |
|------------|-----------|---------|
| `indexed`  | yes       | Vault changed (or resumed) and embedding reached full coverage (`pending == 0`). |
| `skipped`  | yes       | Vault unchanged AND already fully embedded — no work done. |
| `error`    | yes       | `update` or an embedding pass hard-failed/timed out; prior `hash` preserved. |
| `partial`  | **new**   | Embedding made progress but did not reach full coverage before the pass cap; `pending > 0`. Next maintenance resumes. |
| `stalled`  | **new**   | A pass made no forward progress (`pending` did not decrease) — e.g. permanently-failing documents; `pending > 0`. Next maintenance still retries but the operator is signalled. |

### State transitions

```text
                 vault changed ─────► update ──ok──► embed-loop ──► indexed (pending=0)
                                        │                     ├──► partial (cap hit, pending>0)
                                        fail                  └──► stalled (no progress, pending>0)
                                        └──► error (hash preserved)

 vault unchanged ─┬─ pending==0 (from state) ─────────────────► skipped
                  └─ pending>0 OR pending unknown ─► embed-loop ─► indexed | partial | stalled
```

### Validation / invariants

- `pending` is a non-negative integer; on any parse failure it is treated as unknown → the loop runs a
  resume pass rather than skipping (fail toward completeness, never toward silent partial).
- `last_status == indexed` ⇒ `pending == 0`. `partial`/`stalled` ⇒ `pending > 0`.
- Writing state is atomic (tmp + `mv`) and fail-silent (`qmd_write_state` returns 0 even if `jq`/write
  fails) — unchanged from today.
- Secrets never appear in the state file (only counts, a hash, a timestamp, a status enum).

## Signal: pending embedding count (engine-reported, not persisted by us)

- **Source**: `qmd status` line `Pending: N need embedding` (qmd `getHashesNeedingEmbedding()`).
- **Producer**: the qmd engine, queried through the managed prefix (`_qmd_run "$pkg" status`).
- **Consumers**:
  - The amended `_qmd_reindex_locked` guard (decide skip vs resume on an unchanged vault — but only
    when the persisted `pending` is unknown; otherwise the persisted value short-circuits without a
    status call).
  - The embed-completion loop (per-pass stall detection + the value persisted into `pending`).
- **Completion sentinel**: `qmd embed` prints `✓ All content hashes already have embeddings` when
  `pending == 0`; the loop treats this as definitive complete.
- **Resilience**: if `qmd status` fails or the number cannot be parsed, pending is unknown → the loop
  runs at least one embed pass and re-checks, never trusting a silent 0.

## No changes to

- `agent.yml` schema (the max-passes cap is a fixed lib constant, not a config field).
- The qmd index/vector schema, the model set, or the wiki-graph.
- Any rendered/derived file (`.mcp.json`, `docker-compose.yml`, crontab, etc.).
