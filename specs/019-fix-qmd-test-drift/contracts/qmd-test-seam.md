# Contract: Canonical QMD test seam (post-016)

Status: authoritative for all host bats that exercise QMD invocation paths.
Referenced from the header comments of `tests/qmd-index.bats`,
`tests/qmd-setup.bats`, and `tests/docker-e2e-qmd.bats` (Tier 1).

## The rule

Since 016 (`bunx` → managed prefix), a PATH-level `bunx` stub is DEAD CODE:
`_qmd_run`/`qmd_mcp_exec` execute `$(_qmd_prefix)/node_modules/.bin/qmd`
directly. Tests intercept the engine at exactly ONE of two seams:

### Seam A — fake engine binary in the managed prefix (DEFAULT)

For tests of `qmd_reindex`, `qmd_setup_if_needed`, or anything that should
traverse `_qmd_run`/`_qmd_ensure_prefix` for real. Implemented ONCE in
`tests/helper.bash` — do not re-implement per file:

- `install_qmd_stub [VER]` — success engine: logs `"$@"` to `$QMD_STUB_LOG`,
  fakes `index.sqlite` on `collection`, emits the 018 completion signal on
  `embed` (`✓ All content hashes already have embeddings`) and answers
  `status` with `Pending: 0 need embedding`; exit 0.
- `install_qmd_stub_fail [VER]` — same layout, exit 1, no completion output.
- `_qmd_stub_prefix_seed VER` — shared layout builder (manifest +
  `.installed-hash` via the lib's `_qmd_manifest`/`_qmd_sha` + no-op `bun` on
  PATH). Use it for file-local variants (e.g.
  `tests/qmd-setup.bats::_install_qmd_stub_slow`, which sleeps on
  `collection` for the flock-contention test).

Preconditions: the test has sourced `scripts/lib/qmd_index.sh` and exported
`QMD_CACHE_HOME` + `QMD_STUB_LOG` (see the `setup()` of the repaired files).

Requirements:

1. `.installed-hash` derived via the lib's OWN `_qmd_manifest`/`_qmd_sha` —
   never hardcode the manifest or its hash (survives manifest evolution).
2. A no-op `bun` on PATH — `_qmd_setup_locked`/`_qmd_reindex_locked` guard on
   `command -v bun` before ever reaching the prefix.
3. Success stubs MUST emit the 018 completion signal on `embed` (or answer
   `status` with `Pending: 0`), or reindex lands `stalled`/`partial`.
4. The stub sees qmd subcommands as `$1` (no package-spec prefix — that was
   the `bunx` calling convention).
5. Failure variant: same layout, stub `exit 1`, no completion output.

### Seam B — bash function override of `_qmd_run` (UNIT TESTS ONLY)

For pure logic units around the engine (e.g., `_qmd_embed_until_complete` in
`tests/qmd-embed-completion.bats`): redefine `_qmd_run` after sourcing the
lib. Cheaper, but SKIPS `_qmd_ensure_prefix` — never use it for tests whose
intent includes the invocation boundary itself. Cross-call state in such
stubs must live in FILES, not shell variables (command substitution runs the
stub in a subshell — repo gotcha).

## Anti-patterns (do not reintroduce)

- `bunx` on PATH: not executed by anything since 016 (PR #71).
- Asserting `.mcp.json` `.mcpServers.qmd.args[0]` carries a package spec:
  retired by 016/T036 — current shape is per-mode wrapper `command` +
  `args: []` (`modules/mcp-json.tpl`), pin lives in `agent.yml` only.
- Bare `!`-negated intermediate pipelines in bats (repo quirk: they do not
  fail the test) — use `if …; then false; fi` or place the negation last.

## Change management

If the invocation contract changes again (e.g., prefix path or binary name),
update THIS contract and both seam helpers in the same feature — the 016
drift happened precisely because the contract moved and the seams did not.
