# Research: Fix QMD Test Drift (019)

Phase 0 output. All decisions grounded in code read on 2026-07-12 (file:line
citations against branch `019-fix-qmd-test-drift`, stacked on 018).

## R1 — Why exactly these 7 tests fail (root cause, per file)

**Decision**: classify all 7 as pure stub/assertion drift from 016; no
production bug is implicated.

**Evidence**:
- `_qmd_run` executes `"$prefix/node_modules/.bin/qmd" "$@"` and never spawns
  `bunx` (`scripts/lib/qmd_index.sh:235-250`). The tests' `_install_bunx`
  helpers plant a `bunx` shim on PATH that nothing executes, so
  `$QMD_STUB_LOG` stays empty → every `grep -q … "$QMD_STUB_LOG"` assertion
  fails; with no stub intercepting, `_qmd_ensure_prefix` attempts a REAL
  `bun install` (absent binary / no network) and the functions take their
  fail-silent paths, which the old tests don't expect.
- `regenerate.bats:100-111` asserts `.mcp.json` `.mcpServers.qmd.args[0] ==
  "@tobilu/qmd@2.5.3"` and `args[1] == "mcp"`. Post-T036 the template renders
  `command: {{QMD_MCP_COMMAND}}, args: []` (`modules/mcp-json.tpl:73-77`) —
  the assertion can never pass again by design.

**Alternatives considered**: treating any failure as a possible library bug —
rejected: the covered paths were exercised for real by the 017 DOCKER_E2E run
(Alpine musl, real embed) and the 018 container sanity check; the failures
reproduce identically at the 016 merge point.

## R2 — Canonical seam: fake engine binary in the managed prefix

**Decision**: stub at the ENGINE BINARY level — plant an executable fake at
`$QMD_CACHE_HOME/pkg/node_modules/.bin/qmd` + pre-seed
`$QMD_CACHE_HOME/pkg/.installed-hash` with `sha256(_qmd_manifest <ver>)` (both
helper functions callable from tests after `source`), + a no-op `bun` on PATH
for the `command -v bun` guards (`qmd_index.sh:370, :~540`).

**Rationale**:
- Exercises the REAL `_qmd_run` / `_qmd_ensure_prefix` skip path (hash guard,
  env plumbing, timeout wrapper) instead of bypassing it — strictly more
  production code under test than a bash function override.
- Zero library changes (FR-005): every knob already exists
  (`QMD_CACHE_HOME` line 62, `_qmd_prefix` line 103, hash-skip lines 195-202).
- `_qmd_swap_sqlite_vec` is a no-op off musl (line 131) — inert on macOS/CI.
- The stub receives qmd subcommands directly (`collection add …`, `update`,
  `embed`, `status`) so the existing `grep` assertions keep their meaning
  (arg position shifts from `$2` to direct `$1` in the setup stub's `case`).

**Alternatives considered**:
1. *Override `_qmd_run` as a bash function after `source`* (the 018 test
   pattern). Rejected as the CANONICAL seam for these tests: it skips
   `_qmd_ensure_prefix` entirely, so the repaired tests would cover less than
   the originals did (which at least aimed at the invocation boundary).
   Remains the right pattern for pure loop-logic units (as in
   `qmd-embed-completion.bats`) — the contract doc records when to use which.
2. *Fake `bun` that simulates `bun install` populating the prefix*. Rejected:
   re-implements bun's layout in every test, brittle against manifest changes,
   and adds nothing over pre-seeding the hash.

## R3 — Contingency if the seam proves insufficient

**Decision**: if during implementation a repaired test cannot observe a
behavior through the binary seam (e.g., needs to fail `bun install` itself),
FIRST prefer adjusting the test scenario; introducing a new library test hook
is a LAST resort that reopens the plan's Constitution re-check and triggers
the docker-mirror rule (`scripts/lib` ↔ `docker/scripts/lib`).

**Rationale**: FR-005 (no production change) outranks test elegance; all 7
original tests assert behaviors reachable through `_qmd_run`'s result codes
and outputs, so no such hook is anticipated.

## R4 — 018-aware repair of the reindex success test

**Decision**: the repaired "vault changed → indexed" stub must emit the 018
completion signal: respond to `embed` with output containing
`All content hashes already have embeddings` (single-pass completion). The
stub also answers `status` with `Pending: 0` for robustness (either signal
suffices — `_qmd_embed_until_complete`, `qmd_index.sh:497-516`).

**Rationale**: post-018, `update` success alone no longer yields
`last_status=indexed`; a naive re-stub would land `stalled`/`partial` and the
test would fail for a NEW reason. This is the one place where 019 must encode
018's contract, not just 016's.

**Error-path test**: stub exits 1 on any subcommand → `update` fails →
`error` + prior hash preserved (`_qmd_reindex_locked`, lines 552-558) —
unchanged semantics from the original test.

## R5 — Regenerate assertion: what "a valid qmd pin" means post-T036

**Decision**: keep the `agent.yml` backfill assertion
(`vault.qmd.version == "2.5.3"`) — that IS the pin and the test's core intent
(agent.yml as single source). Replace the two retired `args` assertions with
the current rendered contract for the seeded (docker-mode-backfilled)
workspace: `.mcpServers.qmd.command == "/opt/agent-admin/scripts/qmd-mcp"`
and `.mcpServers.qmd.args | length == 0` (`setup.sh:2018-2022`,
`modules/mcp-json.tpl:73-77`).

**Rationale**: the version pin no longer flows into `.mcp.json` args by
design (the wrapper resolves it from `agent.yml` at runtime via `qmd_pkg`);
asserting the wrapper command + empty args is the faithful translation of
"renders a valid qmd pin" into the current architecture.

**Alternatives considered**: asserting only the backfill and dropping the
render assertion — rejected: the test also guards against T036 regressions
(e.g., someone reintroducing args-based pinning that would break docker/musl).

## R6 — Scope of the docker-e2e Tier-1 stub alignment

**Decision**: align `tests/docker-e2e-qmd.bats` Tier-1's stale `bunx` stub to
the same binary seam in the same change, but mark its validation explicitly
deferred to the next Docker host run (`DOCKER_E2E=1`); it cannot affect host
greenness (file self-skips without the env gate).

**Rationale**: leaving a known-stale stub in the repo after documenting the
canonical seam invites copy-paste of the wrong pattern; the syntax-level risk
is low and the deferral is honest (same precedent as 015/016/017/018 gates).

**Alternatives considered**: full local Docker validation now — rejected for
this feature: the Tier-1 path needs an image build (~minutes) and the change
is mechanical; it rides the next deployment's mandatory DOCKER_E2E pass.
