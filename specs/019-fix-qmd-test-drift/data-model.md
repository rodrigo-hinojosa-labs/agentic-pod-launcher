# Data Model: Fix QMD Test Drift (019)

Phase 1 output. This feature has no production data; the "entities" are the
test fixtures and their shapes.

## Fake engine prefix (per-test tmpdir)

```text
$QMD_CACHE_HOME/pkg/                      # _qmd_prefix (qmd_index.sh:103)
├── package.json                          # _qmd_manifest "<ver>" verbatim
├── .installed-hash                       # sha256 of package.json content
└── node_modules/.bin/qmd                 # executable stub (the seam)
```

Invariants:
- `.installed-hash` MUST equal `printf '%s' "$(_qmd_manifest <ver>)" | _qmd_sha`
  where `<ver>` matches `vault.qmd.version` in the test's `agent.yml`
  (`2.5.3`). Both helpers come from the sourced lib — tests never hardcode the
  manifest text or hash.
- The stub MUST be executable and MUST exit 0 (success variants) or 1
  (failure variant) for EVERY subcommand — mirroring the old `_install_bunx*`
  binary semantics.
- A no-op `bun` executable MUST exist on PATH (guards at qmd_index.sh:370 and
  in `_qmd_reindex_locked`); it is never expected to be invoked.

## Stub call log (`$QMD_STUB_LOG`)

One line per engine invocation: the stub appends `"$@"` (its own args —
i.e., qmd subcommands, NO package spec prefix). Expected sequences:

| Scenario | Log lines (order) |
|----------|-------------------|
| First-boot setup | `collection add <vault> --name vault --mask **/*.md` → `update` → `embed` |
| Setup refresh (index present, no sentinel) | `update` → `embed` (NO `collection add`) |
| Reindex, vault changed (success) | `update` → `embed` [→ `status` only if the embed output lacks the completion line] |
| Reindex, engine failure | `update` (single line; nothing after the failure) |

Delta vs pre-016 stubs: the old `bunx` stub saw `@tobilu/qmd@2.5.3` as `$1`
and the subcommand as `$2`; the new stub sees the subcommand as `$1` (the
setup stub's `case "$2" in collection)` becomes `case "$1" in collection)`).

## Stub output contract (018-aware)

| Stub variant | On `embed` | On `status` | Exit |
|--------------|-----------|-------------|------|
| `_install_qmd_stub` (success) | prints `✓ All content hashes already have embeddings` | prints `Pending: 0 need embedding` | 0 |
| `_install_qmd_stub_fail` | (any output) | (any output) | 1 |
| slow variant (flock test, qmd-setup only) | as success | as success | 0 (with `sleep 1` on `collection`) |

The success stub MUST emit the completion line so
`_qmd_embed_until_complete` terminates in one pass with `indexed`/`pending=0`
(research.md R4).

## State-file expectations (unchanged coverage, current schema)

| Repaired test | `last_status` | `hash` | `pending` |
|---------------|---------------|--------|-----------|
| reindex success (vault changed) | `indexed` | new vault hash | `0` |
| reindex engine failure | `error` | `STALEHASH` (preserved) | absent/carried |

## Rendered MCP entry (regenerate test, docker-mode seed)

```json
".mcpServers.qmd": {
  "command": "/opt/agent-admin/scripts/qmd-mcp",
  "args": [],
  "env": { …QMD_MCP_ENV… }
}
```

Assertions: `command` equals the docker wrapper path; `args | length == 0`;
`vault.qmd.version == "2.5.3"` in `agent.yml` (backfill — unchanged from the
original test).
