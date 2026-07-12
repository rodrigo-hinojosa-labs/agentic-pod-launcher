# Research — 018 qmd Embed Completion

All questions resolved before planning. Root cause was confirmed by reading the deployed qmd 2.5.3
`dist` on ferrari; the three design decisions were fixed in the 2026-07-10 Clarifications session.

## R1 — Root cause of the incomplete embed

- **Decision**: The 30-minute cap is real, hard, and non-configurable inside qmd; treat it as fixed.
- **Evidence**:
  - `@tobilu/qmd/dist/store.js:1377` creates the embedding session with
    `{ maxDuration: 30 * 60 * 1000, name: 'generateEmbeddings' }` — a literal 30 min, not read from
    options/env.
  - `dist/llm.js:1367-1372`: on `maxDuration`, a `setTimeout` calls `signal.abort(...)` →
    `session.isValid = false`.
  - `dist/store.js:1298-1306`: the embed loop checks `if (!session.isValid)` before each batch and, on
    expiry, does `recordFailure(chunk, "LLM session expired before embedding chunk")` for the rest and
    `console.warn("⚠ Session expired — skipping N remaining chunks")`. The process still exits 0
    (partial success).
  - No `QMD_*` env var controls session duration (full env-var scan of the dist).
- **Alternatives considered**: patching `maxDuration` in the dist (rejected — see R2).

## R2 — Mechanism: loop-around vs patch-the-engine

- **Decision**: **Loop around the engine.** Re-invoke `qmd embed` in successive fresh sessions until
  complete; never modify the qmd dist. (Clarifications 2026-07-10, Q1.)
- **Rationale**: qmd is a vendored, minified dependency pinned at 2.5.3 and reinstalled into the managed
  prefix; a regex patch of its dist is fragile across version bumps (Principle VI) and a single ~90-min
  session risks failing late. `qmd embed` is already incremental (only embeds hashes without a current
  vector — `getEmbeddingDocsForBatch`), so re-invocation naturally resumes. This is exactly what the
  manual ferrari loop is proving right now.
- **Alternatives considered**: patch `maxDuration` (fragile, off-Principle-VI); remote embeddings
  (rejected in 016).

## R3 — Operational model: single-invocation loop vs one-pass-per-tick

- **Decision**: **Loop within one maintenance invocation** until complete-or-stall. (Clarifications
  2026-07-10, Q2.)
- **Rationale**: `_qmd_reindex_locked` already runs under a `flock -n` guard (via `qmd_reindex`).
  Looping inside one invocation gives deterministic completion and reuses that guard for free —
  overlapping scheduled runs (`*/5` cron in docker, systemd timer locally) simply skip with "already
  running". A per-tick model is muddied because a 30-min pass overlaps the 5-min cadence anyway (ticks
  skip on the lock), so it does not actually reduce the held-lock time; it only adds re-trigger
  dependence and more moving parts.
- **Trade-off (accepted)**: a first-time bulk completion holds the maintenance lock for the full
  multi-pass duration (potentially >1h). This is a one-time catch-up; steady-state incremental embeds
  finish in a single pass. Documented in the spec (Edge Cases) and quickstart.

## R4 — Completion & progress signal

- **Decision**: Use qmd's authoritative pending count from `qmd status` ("Pending: N need embedding")
  to (a) decide whether to resume on an unchanged vault and (b) detect stall (pending not decreasing).
  Treat `qmd embed`'s "✓ All content hashes already have embeddings" as the definitive complete signal.
- **Evidence**:
  - `cli/qmd.js:186-189, 365-367` print `Vectors: N embedded` and `Pending: N need embedding`, sourced
    from `getHashesNeedingEmbedding()` / `{ needsEmbedding, totalDocs }` (`store.js:1615`).
  - `cli/qmd.js:1718` prints `✓ All content hashes already have embeddings` when nothing is pending.
- **Rationale**: `qmd status` is a fast DB query (no model load) and is authoritative, so it is robust
  for both the guard and stall detection. Persisting the last pending count in the state file lets the
  steady-state (unchanged-vault, already-complete) path skip cheaply without a status call.
- **Alternatives considered**: parsing per-pass "Embedded N chunks" from embed output (works for
  progress but is less authoritative for the pre-embed guard decision; kept as a secondary signal).

## R5 — Bounds (anti-runaway)

- **Decision**: Stop on ANY of: coverage complete (pending 0 / "all embedded"), no forward progress
  (pending did not decrease across a pass), OR a **fixed internal maximum-passes constant**
  (`QMD_EMBED_MAX_PASSES`, default 12; env-overridable for tests only, NOT an `agent.yml` field).
  (Clarifications 2026-07-10, Q3.)
- **Rationale**: The no-progress stop is the real guard against permanently-failing chunks; the pass cap
  is a coarse backstop so the loop is provably finite even if the progress signal misbehaves. 12 passes
  × 30 min ≈ 6 h ceiling — far above the ~3 passes a few-thousand-chunk vault needs, but bounded.
- **Alternatives considered**: `agent.yml` config (rejected in Q3 — adds schema + wizard/render/test
  touchpoints for a safety backstop).

## R6 — Placement, mirroring, and test seams

- **Decision**: Implement in `scripts/lib/qmd_index.sh`; the existing
  `setup.sh::mirror_catalog_to_docker` copies it to `docker/scripts/lib/qmd_index.sh` at
  `--regenerate` (the Dockerfile COPYs the mirror). Because a mirrored lib changes, DOCKER_E2E is
  mandatory.
- **Test seam**: the host bats suite already stubs `qmd`/`bunx` for reindex tests
  (`tests/qmd-reindex-cmd.bats`, `tests/qmd-index.bats`); the new loop/guard/stall tests stub `_qmd_run`
  (or the `qmd` binary on `PATH`) to emit canned `embed`/`status` outputs across passes. The state-shape
  test at `tests/qmd-index.bats:83` uses an existence assertion
  (`.hash and .last_run and .last_status and (.runs|type=="number")`), so adding a `pending` key is
  backward-compatible.
- **Backward compatibility**: `qmd_write_state` gains an OPTIONAL 4th arg (pending); existing 3-arg
  callers (setup, error, skipped) keep working, with `pending` defaulting to `0`/omitted.

## Open items

None. No NEEDS CLARIFICATION remain.
