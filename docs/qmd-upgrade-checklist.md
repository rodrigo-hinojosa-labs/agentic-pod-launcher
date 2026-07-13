# qmd version upgrade checklist (pre-bump)

The 016/017/018 fixes (qmd native deps on Alpine musl, the sqlite-vec musl build, the
multi-pass embed loop) depend on assumptions about `@tobilu/qmd`'s dependency graph,
its CLI output strings, and its embedding-session behavior. Bumping
`vault.qmd.version` in `agent.yml` MUST be a deliberate change. Before raising the
pin, verify **all** of the following against the target version, then update BOTH
guard tests: `tests/qmd-version-guard.bats` (version string) and
`tests/qmd-sqlite-vec.bats` (the qmd <-> sqlite-vec pair — updating only the first
leaves an unexplained failure in the second).

## Why this exists

As of v0.12.0:

- The current pin is **2.5.3** (single-source in `agent.yml` → `vault.qmd.version`;
  the same string is the hardcoded floor in `scripts/lib/qmd_index.sh::qmd_pkg`, for
  a pre-010 `agent.yml` regenerated without the key). It is also the latest version
  published to npm (`npm view @tobilu/qmd versions`, checked 2026-07-12) — no 2.6.x
  exists on the registry.
- 016 makes qmd install from a managed `bun install` prefix that trusts ONLY
  `better-sqlite3` and `node-llama-cpp` (`scripts/lib/qmd_index.sh::_qmd_manifest`).
  `tree-sitter-*` are left unbuilt (bun default-deny) because qmd uses the
  `web-tree-sitter` WASM grammar at runtime — the native binding is irrelevant.
- Upstream, qmd's unreleased **2.6.x** line moved the `tree-sitter-*` packages from
  `optionalDependencies` to **hard dependencies** (observed in the qmd repo; NOT
  published to npm — this guardrail is preventive, not a present fix; see
  `specs/016-qmd-native-deps/contracts/qmd-version-guardrail.md`). Under that graph
  the trustedDependencies strategy no longer prevents a native `tree-sitter` build →
  BUG 4 would return (or require a redesign).
- 017 pairs the qmd pin with **sqlite-vec 0.1.9**: qmd's transitive
  `sqlite-vec-linux-arm64` prebuilt is glibc-only, so in docker mode the image
  compiles the pinned amalgamation for musl (`docker/scripts/build-sqlite-vec.sh`,
  `ARG SQLITE_VEC_VERSION=0.1.9` in `docker/Dockerfile`) and
  `_qmd_swap_sqlite_vec` swaps it into the managed prefix at runtime. A qmd bump can
  drag the transitive sqlite-vec version along, invalidating the baked build.
- 018's multi-pass embed loop parses qmd's CLI output verbatim:
  `_qmd_pending_count` greps `Pending: N` from `qmd status`, and completion is
  detected via the `qmd embed` line "All content hashes already have embeddings"
  (`scripts/lib/qmd_index.sh`). The loop exists because a single `qmd embed`
  session is capped at ~30 minutes inside the engine (hardcoded, not configurable
  — `specs/018-qmd-embed-completion/spec.md`). A bump that changes these strings
  or the cap silently degrades the loop.

## Checklist

Facts below (versions, defaults) are as of v0.12.0.

- [ ] `tree-sitter-*` (typescript/go/python/rust) are still **optionalDependencies**
      in the target version's published `package.json` (if they became hard deps,
      the fix must be redesigned).
- [ ] `web-tree-sitter` is still a dependency and the `.wasm` grammar ships in the
      `tree-sitter-*` tarball (qmd resolves it via `require.resolve(...wasm)`).
- [ ] `node-llama-cpp` is still the embeddings path and the build recipe still applies
      (system `cmake` on PATH, `GGML_NATIVE=OFF` + `GGML_CPU_ARM_ARCH=armv8-a`, the
      `bigstack.so` LD_PRELOAD for the musl std::regex/stack hazard).
- [ ] Either a prebuilt musl-arm64 exists for the target's native deps, OR the
      Option A toolchain (build-base + cmake + linux-headers + libgomp) still covers
      the from-source build.
- [ ] **017 sqlite-vec pair** (docker mode): the target qmd's transitive
      `sqlite-vec` version still matches `ARG SQLITE_VEC_VERSION` in
      `docker/Dockerfile` (0.1.9). If it moved: bump the ARG **and** the `SHA256`
      tarball pin in `docker/scripts/build-sqlite-vec.sh`, then re-verify the musl
      amalgamation compile still works (the `-Du_int8_t=uint8_t` BSD-typedef shim
      and the no-GLIBC-symbols guard in that script).
- [ ] **017 swap path** (docker mode): `_qmd_swap_sqlite_vec`'s target
      `node_modules/sqlite-vec-linux-arm64/vec0.so` still matches the target
      version's package layout (`scripts/lib/qmd_index.sh`). Local mode (glibc) is
      unaffected — the swap is a no-op there.
- [ ] **018 output contract**: on the target version, `qmd status` still prints
      `Pending: N ...` and a fully-embedded `qmd embed` still prints
      "All content hashes already have embeddings". If either string changed,
      update `_qmd_pending_count` / `_qmd_embed_until_complete` — otherwise the
      loop silently runs to the `QMD_EMBED_MAX_PASSES` cap and parks at
      `last_status=partial`.
- [ ] **018 session cap** (both modes — the cap lives in the engine): re-check
      whether the target still caps a single embed session (~30 min in 2.5.3). If
      the cap changed or moved, re-size `QMD_EMBED_MAX_PASSES` (default 12,
      `scripts/lib/qmd_index.sh`; a fixed constant, env-overridable for tests only,
      NOT an `agent.yml` field) so passes x per-pass throughput still bounds a
      full-corpus embed.
- [ ] **013 storage env** (local mode): the target binary still honors
      `XDG_CACHE_HOME` (index + models) and `QMD_CONFIG_DIR` (collections config) —
      the rendered `scripts/local/agent-qmd-{reindex,mcp}.sh` wrappers (from
      `modules/local-qmd-{reindex,mcp}.sh.tpl`) export both under `.state`.
      `QMD_CACHE_HOME` is read only by the bash lib (`qmd_cache_root`),
      never by qmd itself. Docker mode sets neither (`.mcp.json` qmd env is `{}`)
      and relies on qmd's own `~/.cache/qmd` default, which lands in the `.state`
      bind-mount. Either way, a storage-resolution change in the target version
      would orphan the existing index under `.state`.
- [ ] **MCP**: the `qmd mcp` stdio subcommand still exists (`qmd_mcp_exec` execs it
      from the managed prefix — the MCP server must never fall back to `bunx`).
- [ ] `tests/qmd-version-guard.bats` updated to assert the new version string, AND
      `tests/qmd-sqlite-vec.bats` updated for the new qmd <-> sqlite-vec pair (it
      asserts both the `qmd_pkg` string and the Dockerfile ARG). `qmd-version-guard.bats`
      also asserts this file exists and still mentions `optionalDependencies` — keep
      that word when rewriting the tree-sitter item.
- [ ] `DOCKER_E2E=1` (Phase A build-detector: baked `vec0.so` is musl + `_qmd_run
      --help` RC 0 from the managed prefix, plus the RED rebuild with
      `--build-arg QMD_NATIVE_TOOLCHAIN=0`) and `QMD_EMBED_E2E=1` (Tier 2: real
      update + embed + semantic vsearch) re-run green on the new version
      (`tests/docker-e2e-qmd.bats`); confirmatory hardware gate on Alpine musl
      aarch64 re-run.
- [ ] Post-upgrade (both modes): run a full reindex against a real vault and confirm
      the state file `<workspace>/scripts/heartbeat/qmd-index.json` reaches
      `last_status=indexed` with `pending: 0` (the multi-pass loop ran to
      completion). `partial` (pass cap hit) or `stalled` (a pass made no forward
      progress) with `pending > 0` means the vector index is incomplete.

## References

- `specs/016-qmd-native-deps/research.md` (Decision 1/2, fallback trigger)
- `specs/016-qmd-native-deps/contracts/qmd-version-guardrail.md`
- `specs/017-qmd-sqlite-vec-musl/contracts/version-guardrail.md` (qmd <-> sqlite-vec pair)
- `specs/018-qmd-embed-completion/contracts/embed-completion.md` (loop, output strings, pass cap)
- `specs/018-qmd-embed-completion/contracts/reindex-state.md` (`qmd-index.json` schema: `pending`, `partial`/`stalled`)
