# Contract — Embed completion loop & amended reindex guard

Behavioral contract for the shell functions in `scripts/lib/qmd_index.sh` (mirrored to
`docker/scripts/lib/qmd_index.sh`). "The engine" = `qmd` invoked via `_qmd_run "$pkg" ...`.

## Constant

```sh
# Fixed internal backstop. Env-overridable for TESTS ONLY; never surfaced in agent.yml.
QMD_EMBED_MAX_PASSES="${QMD_EMBED_MAX_PASSES:-12}"
```

## `_qmd_pending_count PKG` → stdout: integer, or empty on unknown

- MUST run `qmd status` through the managed prefix and extract the number from the
  `Pending: <N> need embedding` line.
- MUST echo a bare non-negative integer on success; MUST echo empty (and return non-zero) when status
  fails or the line/number is absent (caller treats empty as "unknown").
- MUST NOT load the embedding model (status is a DB query) and MUST NOT print secrets.

## `_qmd_embed_until_complete PKG STATE_FILE HASH` → return 0; side effects: state written

Runs successive embed passes and records the outcome. Preconditions: prefix ensured, `bun` present,
collection exists (guaranteed by the caller / prior setup).

Loop invariant per pass `i` (1..`QMD_EMBED_MAX_PASSES`):

1. Run `_qmd_run "$pkg" embed` (each invocation is a fresh ≤30-min engine session), capturing stderr to
   the redacted scratch log (existing `_qmd_tail_redacted` pattern).
2. Determine outcome for this pass:
   - If the pass output contains `All content hashes already have embeddings` → **COMPLETE**.
   - Else read `pending = _qmd_pending_count`:
     - `pending == 0` → **COMPLETE**.
     - `pending` known and `pending < prev_pending` → **PROGRESS**; set `prev_pending = pending`; continue.
     - `pending` known and `pending >= prev_pending` → **STALL**.
     - `pending` unknown AND the embed pass hard-failed (non-zero) → treat as error, stop with prior
       hash preserved (`error`), like today's single-embed failure path.
     - `pending` unknown but the pass succeeded → continue up to the cap (do not spin forever — the cap
       bounds it).

Termination & recorded state (via `qmd_write_state STATE_FILE HASH STATUS PENDING`):

| Stop reason | `last_status` | `pending` | `hash` written |
|-------------|---------------|-----------|----------------|
| COMPLETE | `indexed` | `0` | `HASH` (current vault hash) |
| Pass cap reached with pending>0 | `partial` | last known | `HASH` |
| STALL (no progress) | `stalled` | last known | `HASH` |
| Embed pass hard-failed | `error` | (unchanged/omitted) | prior `last` hash preserved |

- MUST always `return 0` (fail-silent; never crash the caller/supervisor).
- MUST log one human-readable progress line per pass (pass number, embedded/pending) via `_qmd_log`,
  redacted.
- MUST NOT re-embed already-embedded documents (guaranteed by qmd incrementality; the loop only
  re-invokes).

## Amended `_qmd_reindex_locked AGENT_YML VAULT_DIR` guard

Replaces today's "unchanged → skip embed (always)" and the single `embed` call.

```text
current = vault_hash(VAULT_DIR)
last    = state.hash
pend    = state.pending          # may be absent (unknown) in pre-018 files

IF current == last AND pend is known AND pend == 0:
    write state {hash:current, status:skipped, pending:0}; return   # cheap steady-state

IF current == last (unchanged) AND (pend > 0 OR pend unknown):
    # resume: no re-chunk needed, embeddings still pending
    _qmd_embed_until_complete(pkg, state_file, current); return

# vault changed:
run `update`; on failure → state error (preserve last hash); return
_qmd_embed_until_complete(pkg, state_file, current); return
```

Guarantees:

- **FR-003**: an unchanged vault with pending>0 (or unknown) still runs embedding.
- **FR-004**: an unchanged, fully-embedded vault skips cheaply with no status call and no embed pass.
- **FR-001/FR-002**: a changed or resuming vault embeds to completion across passes, incrementally.
- **FR-007**: concurrency is the existing `flock -n` in `qmd_reindex`; a long multi-pass run holds it,
  overlapping scheduled runs skip. No new concurrency primitive.
- **FR-005/FR-011**: bounded by complete / no-progress / pass-cap; loops inside one invocation; never
  patches the engine.

## Non-goals (explicit)

- Does not change qmd's 30-min session, model, or schema.
- Does not add `agent.yml` fields.
- Does not alter `docker-compose.yml`, crontab cadence, or the wiki-graph.
