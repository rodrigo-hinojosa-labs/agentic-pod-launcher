# Feature Specification: qmd Embed Completion (multi-pass beyond the 30-minute session cap)

**Feature Branch**: `018-qmd-embed-completion`

**Created**: 2026-07-10

**Status**: Draft

**Input**: User description: "Completar el embed de qmd pese al cap hardcodeado de 30min por sesión: loop bounded embed-hasta-completar en el wrapper del launcher, para que un corpus grande se embeba en varias pasadas en vez de quedar parcial."

## Context

Scaffolded agents with the vault RAG (`qmd`) enabled build two indexes over the vault: a lexical
index and a **vector (semantic) index**. Semantic search only works over documents that have been
embedded. The embedding engine (`qmd embed`) caps a single embedding run at **30 minutes of
wall-clock** (a hard, non-configurable limit inside qmd). On real hardware (Raspberry Pi 5), 30
minutes of CPU inference covers only a few hundred documents, so a first-time embedding of a large
vault stops partway and reports partial success. The scheduled re-index does not resume it, because it
only embeds when the vault contents change. The result is a semantic index that silently covers a
fraction of the vault, degrading every semantic search until something forces a change.

This was surfaced by the ferrari confirmatory gate (2026-07-10): a 2,423-chunk vault embedded ~859
chunks (~35%) and then stopped; semantic queries returned weak, off-topic hits. The gate proved the
embedding mechanism itself works end-to-end; the defect is that **one run cannot finish a large
corpus and nothing resumes it**.

## Clarifications

### Session 2026-07-10

- Q: Mechanism to complete embedding despite qmd's 30-minute session cap — loop around the engine, or
  patch the engine? → A: **Loop around the engine.** Re-invoke embedding in successive fresh sessions
  (each respecting the 30-minute cap) until complete; do NOT modify/patch the embedding engine. The cap
  is treated as fixed engine behavior.
- Q: Multi-pass operational model — does one maintenance invocation iterate until complete, or does each
  invocation do a single pass and rely on the scheduler to re-trigger? → A: **Loop within one
  maintenance invocation** until complete-or-stall (bounded). A first-time bulk completion holds the
  maintenance concurrency lock for the duration; overlapping scheduled runs skip via the existing guard.
- Q: The hard maximum-passes backstop — a fixed internal constant, or operator-configurable in
  `agent.yml`? → A: **Fixed internal constant** (not exposed in `agent.yml`). The real stop conditions
  are "coverage complete" and "no forward progress"; the pass cap is only an anti-runaway backstop.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A large vault embeds completely without manual intervention (Priority: P1)

An operator enables the vault RAG on an agent whose vault is large enough that embedding it exceeds a
single 30-minute engine session. After the agent has been running, the entire vault is semantically
searchable — not just the portion that fit in the first session. The operator does not have to notice
the shortfall or run anything by hand.

**Why this priority**: This is the whole point of the feature. A semantic index that silently covers
35% of the vault is worse than useless — it looks like it works but returns misleading results. P1
because it is the core value and the observed failure.

**Independent Test**: Point an agent at a vault large enough to require more than one embedding
session, let the maintenance cycle run, and confirm that the count of documents still needing
embeddings reaches zero and that a semantic query for content in the *later* (initially skipped)
portion of the vault returns a strong, on-topic hit.

**Acceptance Scenarios**:

1. **Given** a vault whose embedding needs exceed one engine session, **When** the embedding
   maintenance runs, **Then** it performs successive embedding passes until every embeddable document
   has a vector (0 pending), rather than stopping after the first session.
2. **Given** the first embedding session ended with documents still pending, **When** the next
   embedding pass starts, **Then** it resumes from the pending documents (already-embedded documents
   are not re-embedded) and makes forward progress.
3. **Given** the vault is fully embedded, **When** the embedding maintenance runs again, **Then** it
   completes quickly and does no unnecessary embedding work.

---

### User Story 2 - Incomplete embeddings resume even when the vault has not changed (Priority: P2)

An operator's vault stops changing while its semantic index is still incomplete (for example, the
first embedding run was interrupted or hit the session cap and no notes have been edited since).
Maintenance still finishes the semantic index instead of skipping embedding forever because "nothing
changed."

**Why this priority**: Without this, US1 only works while the vault keeps changing; a static,
partially-embedded vault would stay partial indefinitely. P2 because it is the necessary condition
that makes US1 hold in the common "vault went quiet" case.

**Independent Test**: Bring a vault to a partially-embedded state, make no further changes to its
contents, trigger the maintenance cycle, and confirm embedding still runs and drives pending to zero.

**Acceptance Scenarios**:

1. **Given** the vault content is unchanged since the last maintenance run **and** documents still
   need embeddings, **When** maintenance runs, **Then** it runs embedding (does not skip) and reduces
   the pending count.
2. **Given** the vault content is unchanged **and** every document is already embedded, **When**
   maintenance runs, **Then** it skips embedding work and finishes cheaply.

---

### User Story 3 - Bounded, observable completion (no runaway, no silent stall) (Priority: P3)

An operator can see whether embedding is complete, still in progress, or stuck, and the system never
loops forever on documents that can never be embedded.

**Why this priority**: Operational safety and trust. The maintenance runs unattended under a
supervisor and a crash budget; an unbounded retry loop or a silent stall would be its own incident.
P3 because US1/US2 deliver the value and this hardens them.

**Independent Test**: Introduce a document that cannot be embedded (permanently failing), run the
maintenance, and confirm the process terminates after a bounded number of attempts, records the
outstanding count, and reports a stalled/partial outcome rather than hanging or spinning.

**Acceptance Scenarios**:

1. **Given** some documents fail to embed on every attempt, **When** the embedding maintenance runs,
   **Then** it stops after a bounded number of passes once no further progress is being made, and
   records the run as partial with the number of documents still pending.
2. **Given** an embedding pass in progress, **When** an operator inspects the maintenance state/logs,
   **Then** they can determine how many documents remain to embed and whether the last run finished
   complete, partial, or stalled.
3. **Given** the maintenance is completing a large corpus over several passes, **When** the scheduled
   maintenance fires again during that work, **Then** the concurrent invocation does not start a
   second overlapping embedding run.

### Edge Cases

- **Permanently-failing documents**: pending count never reaches zero → the loop must stop on
  no-progress, not on a fixed iteration count alone, and must not re-loop forever.
- **Zero progress in a pass** (session ended before embedding anything, e.g. very slow model load):
  detect and stop rather than repeat identically.
- **Both deployment modes**: the 30-minute cap lives in the embedding engine, independent of the
  container/host libc, so the behavior MUST hold for both the Docker (musl) and local (glibc/systemd)
  modes. The shared library that implements it is mirrored between the host and image copies.
- **Long first-time completion vs incremental**: a first-time bulk completion may take multiple
  sessions (potentially over an hour); routine incremental embeds (a few changed documents) MUST still
  finish in a single pass and not pay a multi-pass penalty.
- **Interaction with existing maintenance concurrency guard**: a long multi-pass completion holds the
  maintenance lock; overlapping scheduled runs MUST skip rather than pile up.
- **Secrets**: embedding runs and their captured output MUST NOT expose secrets in logs, argv, or run
  records.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The embedding maintenance MUST drive the vector index to full coverage of all embeddable
  vault documents even when full coverage requires more embedding time than a single engine session
  allows, by performing successive embedding passes.
- **FR-002**: Successive passes MUST be incremental — a pass MUST NOT re-embed documents that already
  have a current embedding, and MUST make forward progress by embedding documents that are still
  pending.
- **FR-003**: Embedding MUST resume when the vector index is incomplete even if the vault content is
  unchanged since the last maintenance run; the "vault unchanged" condition alone MUST NOT skip
  embedding while documents still need embeddings.
- **FR-004**: When the vault is unchanged AND fully embedded, maintenance MUST skip embedding work and
  complete cheaply (no wasted embedding passes).
- **FR-005**: Multi-pass embedding MUST be bounded: it MUST terminate when coverage is complete, OR
  when a pass makes no forward progress (pending count does not decrease), OR at a hard maximum number
  of passes — whichever comes first — so it can never loop indefinitely.
- **FR-006**: Maintenance MUST record, in its persisted run state, whether the last embedding outcome
  was complete, partial (with the count of documents still pending), or stalled, so the outcome is
  observable after the fact.
- **FR-007**: Only one embedding completion run MUST be active at a time; a scheduled maintenance that
  fires while a completion run is in progress MUST skip rather than start an overlapping run.
- **FR-008**: The behavior MUST hold identically for both deployment modes (Docker and local),
  implemented in the shared maintenance library so the host and image copies stay in lockstep.
- **FR-009**: The feature MUST NOT weaken the container privilege model, MUST NOT require new
  capabilities or mounts, and MUST NOT expose secrets in logs, argv, or run records.
- **FR-010**: The behavior MUST be reproducible from `agent.yml` via `./setup.sh --regenerate` (no
  hand-edited runtime file may be required to make it work). The maximum-passes backstop is a fixed
  internal constant, NOT an `agent.yml`-configurable field (per Clarifications 2026-07-10), so it adds
  no new `agent.yml` schema surface.
- **FR-011**: A first-time bulk completion runs as a single maintenance invocation that iterates
  embedding passes until complete-or-stall; while it runs it holds the maintenance concurrency guard,
  and overlapping scheduled maintenance MUST skip rather than start a second run (per Clarifications
  2026-07-10). The completion loop MUST NOT patch or modify the embedding engine.

### Key Entities *(include if feature involves data)*

- **Pending embedding count**: the number of active vault documents that still need a (fresh)
  embedding. The signal that drives "keep going / stop" and that is surfaced for observability; the
  embedding engine already exposes it.
- **Embedding maintenance run state**: the persisted summary of the last maintenance cycle, extended
  to distinguish complete vs partial (with residual pending count) vs stalled outcomes.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: For a vault large enough to exceed one 30-minute engine session, the semantic index
  reaches 100% coverage of embeddable documents through unattended maintenance (0 documents pending),
  where before the fix it plateaus at a partial fraction.
- **SC-002**: A semantic query for content located in the portion of the vault that a single session
  would not have reached returns a strong, on-topic top result after completion (demonstrating the
  later content is now embedded), where before the fix that content was absent from the vector index.
- **SC-003**: A fully-embedded, unchanged vault completes a maintenance cycle without performing any
  embedding inference (no wasted passes).
- **SC-004**: With a permanently-failing document present, the maintenance terminates within a bounded
  number of passes and records a partial/stalled outcome — it never hangs and never loops
  indefinitely.
- **SC-005**: Routine incremental maintenance (a handful of changed documents that fit well within one
  session) still completes in a single embedding pass, i.e. the multi-pass logic adds no extra passes
  when one suffices.
- **SC-006**: The fix is validated on real hardware: the ferrari agent's ~2,423-chunk vault reaches
  full embedding coverage and a semantic query that previously returned a weak/off-topic hit returns a
  strong on-topic hit.

## Assumptions

- **Loop-around, not engine patch** (confirmed, Clarifications 2026-07-10): the 30-minute session cap is
  treated as fixed engine behavior; the feature completes the corpus by re-invoking embedding across
  fresh sessions rather than modifying or patching the embedding engine to lengthen the session.
- **Completion within the maintenance path, single invocation** (confirmed, Clarifications 2026-07-10):
  the multi-pass completion runs inside the existing embedding maintenance flow (the scheduled/triggered
  re-index), and a single invocation iterates passes until complete-or-stall, reusing the existing
  concurrency guard so overlapping scheduled runs skip. It is not a separate always-on daemon.
- **Progress signal**: the embedding engine's existing "documents needing embedding" count and its
  "all embedded" completion signal are reliable enough to drive stop/continue decisions.
- **Bounds** (confirmed, Clarifications 2026-07-10): the multi-pass loop stops on coverage-complete OR
  no-forward-progress OR a fixed internal maximum-passes constant. That constant is not
  `agent.yml`-configurable; its exact value is an implementation/tuning detail set in planning, not a
  scope question.
- **Hardware reality**: target hardware is Raspberry Pi 5-class CPU-only inference; a first-time bulk
  completion of a multi-thousand-chunk vault may legitimately take more than an hour across several
  sessions, and that is acceptable for a one-time catch-up.
- **Scope of "complete"**: complete means every *embeddable* active document has a current embedding;
  documents that legitimately cannot be embedded (permanently failing) are excluded from the
  completion target and counted as residual.
- **No vault mutation**: the feature only reads vault content and writes vectors/state; it never
  modifies vault documents.

## Out of Scope

- Changing the embedding engine, its 30-minute session cap, its model, or its schema.
- Remote/hosted embeddings (explicitly rejected in prior work).
- The lexical index and the wiki-graph (already complete; unaffected).
- Changing the vector storage/search layer delivered by feature 017 (this feature only ensures the
  corpus is fully embedded through it).
- Speeding up per-document embedding (GPU, quantization, model swap).
