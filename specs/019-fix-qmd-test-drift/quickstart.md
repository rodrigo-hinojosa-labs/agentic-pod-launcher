# Quickstart: Fix QMD Test Drift (019)

## Verify the fix (host, no Docker, no bun)

```bash
# The three repaired files, standalone:
bats tests/qmd-index.bats
bats tests/qmd-setup.bats
bats tests/regenerate.bats

# The release gate (SC-001 — expect 0 failures):
bats tests/
```

## Prove intent survived (US2 spot-check, not committed)

```bash
# Example: invert the sentinel write in _qmd_setup_locked (': > "$sentinel"'
# → 'false'), re-run tests/qmd-setup.bats, confirm the sentinel test FAILS,
# then git checkout -- scripts/lib/qmd_index.sh.
```

## What changed

- `tests/qmd-index.bats`, `tests/qmd-setup.bats`: `_install_bunx*` →
  `_install_qmd_stub*` (fake engine binary inside `$QMD_CACHE_HOME/pkg` +
  pre-seeded install hash + no-op `bun` on PATH). Header comments now point
  at `specs/019-fix-qmd-test-drift/contracts/qmd-test-seam.md`.
- `tests/regenerate.bats`: the qmd-pin test now asserts the post-T036
  `.mcp.json` shape (wrapper `command`, empty `args`) + the unchanged
  `agent.yml` backfill.
- `tests/docker-e2e-qmd.bats` (Tier 1): same seam alignment; validation
  deferred to the next `DOCKER_E2E=1` run on a Docker host.
- NO changes under `scripts/`, `docker/`, `modules/`, `setup.sh`.

## Known deferrals

- Tier-1 e2e stub: syntactically aligned, exercised only on the next Docker
  host pass (gated, cannot redden the host suite).
