# Quickstart / Validation — 018 qmd Embed Completion

How to build, test, and validate this feature. Mirrors the repo's existing gates.

## Host tests (no Docker) — the inner loop

```bash
# Full suite (must stay green)
bats tests/

# This feature's new/changed tests
bats tests/qmd-embed-completion.bats     # loop, guard, stall, state outcomes (stubbed qmd)
bats tests/qmd-index.bats                # state shape incl. new `pending` field
bats tests/qmd-reindex-cmd.bats          # reindex dispatch/guard unchanged behaviour

# Lint gate
shellcheck -S error scripts/lib/qmd_index.sh
```

The new bats file stubs the `qmd` binary (or `_qmd_run`) on `PATH` to emit canned outputs across passes:

- **Multi-pass completes**: pass 1 emits "Embedded N … Session expired", `status` → `Pending: 700`;
  pass 2 emits "Embedded 700…", `status` → `Pending: 0`; pass 3 emits "All content hashes already have
  embeddings". Expect: loop stops at complete, state `last_status=indexed`, `pending=0`.
- **Stall**: `status` returns a pending count that never decreases → loop stops, `last_status=stalled`,
  `pending>0`, no infinite loop.
- **Guard resume**: vault hash unchanged AND state `pending>0` (or absent) → embed-loop runs. Vault
  unchanged AND state `pending=0` → `skipped`, no embed pass invoked.
- **Pass cap**: `QMD_EMBED_MAX_PASSES=2` with an always-progressing stub that never reaches 0 → stops
  after 2 passes, `last_status=partial`.

## Regenerate + mirror check (Principle I)

```bash
# From a scaffolded workspace: the lib change must reach the image copy
./setup.sh --regenerate
diff -q scripts/lib/qmd_index.sh docker/scripts/lib/qmd_index.sh   # must be identical
```

## Docker E2E (gated) — integration seam

```bash
DOCKER_E2E=1 bats tests/docker-e2e-qmd.bats
```

Extend the existing qmd e2e to assert: after reindex, `qmd status` reports `Pending: 0` and the state
file records `last_status=indexed`, `pending=0`. (The real 30-min-cap multi-pass is not reproducible on
a tiny e2e corpus that finishes in one pass; the multi-pass logic is covered by the host stubs and by
the ferrari hardware gate below.)

## Ferrari hardware gate (SC-006) — the real multi-pass

On the ferrari agent (Docker, Alpine musl, ~2,423-chunk Cencosud vault):

1. Deploy the built image with the 018 lib.
2. Let the scheduled maintenance run (or trigger `heartbeatctl qmd-reindex`).
3. Confirm over successive maintenance runs:
   - `qmd status` → `Pending: 0` (full coverage), and `qmd-index.json` → `last_status=indexed`,
     `pending=0`.
   - A semantic query for content in the initially-skipped portion returns a strong, on-topic top hit
     (contrast: pre-fix returned a weak/off-topic 33% hit at ~35% coverage).
   - `/tmp` shows no ENOSPC; the container does not crash-loop.

Note: the manual embed loop run during the 017 gate is a preview of this behaviour; 018 codifies it so
it happens unattended.

## Docs / version gates

```bash
grep -q "0.12.0" VERSION                 # bumped from 0.11.0
grep -qi "embed" CHANGELOG.md            # 018 entry present
```
