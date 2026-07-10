# qmd version upgrade checklist (pre-bump)

The 016 fix for BUG 4 (qmd native deps on Alpine musl) depends on assumptions about
`@tobilu/qmd`'s dependency graph. Bumping `vault.qmd.version` in `agent.yml` MUST be a
deliberate change. Before raising the pin, verify **all** of the following against the
target version's published `package.json`, then update `tests/qmd-version-guard.bats`
to the new string.

## Why this exists

- The current pin is **2.5.3** (single-source in `agent.yml` → `vault.qmd.version`).
- 016 makes qmd install from a managed `bun install` prefix that trusts ONLY
  `better-sqlite3` and `node-llama-cpp` (`scripts/lib/qmd_index.sh::_qmd_manifest`).
  `tree-sitter-*` are left unbuilt (bun default-deny) because qmd uses the
  `web-tree-sitter` WASM grammar at runtime — the native binding is irrelevant.
- In qmd **2.6.x** the `tree-sitter-*` packages moved from `optionalDependencies` to
  **hard dependencies**. Under that graph the trustedDependencies strategy no longer
  prevents a native `tree-sitter` build → BUG 4 would return (or require a redesign).

## Checklist

- [ ] `tree-sitter-*` (typescript/go/python/rust) are still **optionalDependencies**
      in the target version (if they became hard deps, the fix must be redesigned).
- [ ] `web-tree-sitter` is still a dependency and the `.wasm` grammar ships in the
      `tree-sitter-*` tarball (qmd resolves it via `require.resolve(...wasm)`).
- [ ] `node-llama-cpp` is still the embeddings path and the build recipe still applies
      (system `cmake` on PATH, `GGML_NATIVE=OFF` + `GGML_CPU_ARM_ARCH=armv8-a`, the
      `bigstack.so` LD_PRELOAD for the musl std::regex/stack hazard).
- [ ] Either a prebuilt musl-arm64 exists for the target's native deps, OR the
      Option A toolchain (build-base + cmake + linux-headers + libgomp) still covers
      the from-source build.
- [ ] `tests/qmd-version-guard.bats` updated to assert the new version string.
- [ ] `DOCKER_E2E=1` (Tier 1) + `QMD_EMBED_E2E=1` (Tier 2) re-run green on the new
      version; confirmatory ferrari gate (Alpine musl aarch64) re-run.

## References

- `specs/016-qmd-native-deps/research.md` (Decision 1/2, fallback trigger)
- `specs/016-qmd-native-deps/contracts/qmd-version-guardrail.md`
