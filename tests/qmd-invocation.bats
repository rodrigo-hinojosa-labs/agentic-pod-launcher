#!/usr/bin/env bats
# 016: qmd runs from a managed bun-install prefix (not bunx). These host tests
# assert the wrapper's LOGIC (manifest shape, no-bunx, idempotency, scoped env)
# with mock `bun`/`qmd` binaries — the real native build is exercised by
# DOCKER_E2E (tests/docker-e2e-qmd.bats), not here.

load helper

setup() {
  setup_tmp_dir
  load_lib qmd_index
  MOCK_BIN="$TMP_TEST_DIR/bin"; mkdir -p "$MOCK_BIN"
  export QMD_CACHE_HOME="$TMP_TEST_DIR/cache"; mkdir -p "$QMD_CACHE_HOME"
  # A present bigstack shim so the embed branch preloads it (path is overridable).
  export QMD_BIGSTACK_SO="$TMP_TEST_DIR/bigstack.so"; : > "$QMD_BIGSTACK_SO"
  export QMD_TEST_INSTALL_COUNT="$TMP_TEST_DIR/install.count"; : > "$QMD_TEST_INSTALL_COUNT"
  export QMD_TEST_INSTALL_ENV="$TMP_TEST_DIR/install.env"
  export QMD_TEST_RUN_ENV="$TMP_TEST_DIR/run.env"
  # Mock `bun`: on `install`, record env + count and drop a fake qmd binary that
  # records its own env per subcommand. Everything else is a no-op exit 0.
  cat > "$MOCK_BIN/bun" <<'MOCK'
#!/bin/sh
if [ "$1" = "install" ]; then
  echo x >> "$QMD_TEST_INSTALL_COUNT"
  env > "$QMD_TEST_INSTALL_ENV"
  mkdir -p node_modules/.bin
  cat > node_modules/.bin/qmd <<'FAKE'
#!/bin/sh
env > "${QMD_TEST_RUN_ENV}.$1"
exit 0
FAKE
  chmod +x node_modules/.bin/qmd
fi
exit 0
MOCK
  chmod +x "$MOCK_BIN/bun"
  export PATH="$MOCK_BIN:$PATH"
}

teardown() { teardown_tmp_dir; }

@test "manifest trusts only better-sqlite3 + node-llama-cpp, never tree-sitter" {
  run _qmd_manifest "2.5.3"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"trustedDependencies"'
  echo "$output" | grep -q 'better-sqlite3'
  echo "$output" | grep -q 'node-llama-cpp'
  echo "$output" | grep -q '"@tobilu/qmd": "2.5.3"'
  # tree-sitter must NOT be trusted (default-deny → uses WASM grammar)
  ! echo "$output" | grep -q 'tree-sitter'
}

@test "_qmd_run no longer uses bunx and invokes the prefix binary" {
  # The plain grep gates as an intermediate (a failure aborts under set -e); the
  # `!`-negated pipeline is exempt from set -e, so it MUST be the final statement
  # or it silently never fails (bats/bash quirk).
  declare -f _qmd_run | grep -q 'node_modules/.bin/qmd'
  ! declare -f _qmd_run | grep -q 'bunx'
}

@test "version is extracted from the pkg spec" {
  run _qmd_ver "@tobilu/qmd@2.5.3"
  [ "$output" = "2.5.3" ]
  run _qmd_ver "@tobilu/qmd"
  [ "$output" = "latest" ]
}

@test "install is idempotent: unchanged manifest does not reinstall" {
  _qmd_run "@tobilu/qmd@2.5.3" update
  _qmd_run "@tobilu/qmd@2.5.3" update
  local n; n=$(grep -c x "$QMD_TEST_INSTALL_COUNT")
  [ "$n" -eq 1 ]
}

@test "embed preloads bigstack; update does not (scoped LD_PRELOAD)" {
  _qmd_run "@tobilu/qmd@2.5.3" embed
  _qmd_run "@tobilu/qmd@2.5.3" update
  # embed run saw LD_PRELOAD = the shim
  grep -q "LD_PRELOAD=$QMD_BIGSTACK_SO" "${QMD_TEST_RUN_ENV}.embed"
  # update run saw an empty LD_PRELOAD (never the shim)
  ! grep -q "LD_PRELOAD=$QMD_BIGSTACK_SO" "${QMD_TEST_RUN_ENV}.update"
}

@test "the native build runs under portable-ARM GGML options" {
  _qmd_run "@tobilu/qmd@2.5.3" embed
  grep -q 'NODE_LLAMA_CPP_CMAKE_OPTION_GGML_NATIVE=OFF' "$QMD_TEST_INSTALL_ENV"
  grep -q 'NODE_LLAMA_CPP_CMAKE_OPTION_GGML_CPU_ARM_ARCH=armv8-a' "$QMD_TEST_INSTALL_ENV"
}

@test "install failure surfaces the real build error, not a missing-binary symptom" {
  # A bun whose `install` fails WITHOUT producing the prefix binary — the BUG 4
  # native-build-failure shape. _qmd_run must surface that error and return
  # non-zero, never fall through to a misleading 'No such file or directory'
  # (016/US4: the whole feature exists to make this failure diagnosable).
  cat > "$MOCK_BIN/bun" <<'MOCK'
#!/bin/sh
if [ "$1" = "install" ]; then
  echo "CMake Error: could not find cmake" >&2
  echo "node-gyp rebuild failed" >&2
  exit 1
fi
exit 0
MOCK
  chmod +x "$MOCK_BIN/bun"
  run _qmd_run "@tobilu/qmd@2.5.3" update
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'bun install failed'
  ! echo "$output" | grep -qi 'no such file'
}

@test "qmd_mcp_exec launches the MCP server from the managed prefix with bigstack, never bunx" {
  # T036: the MCP READER path must run `qmd mcp` from the same managed prefix as
  # the reindex (not `bunx`), and preload bigstack (query embedding hits the same
  # node-llama-cpp/musl hazard as `embed`).
  run qmd_mcp_exec "@tobilu/qmd@2.5.3"
  [ "$status" -eq 0 ]
  # the mock qmd records its env per subcommand → the server ran as `qmd mcp`
  [ -f "${QMD_TEST_RUN_ENV}.mcp" ]
  grep -q "LD_PRELOAD=$QMD_BIGSTACK_SO" "${QMD_TEST_RUN_ENV}.mcp"
  # it went through the managed bun-install prefix binary...
  declare -f qmd_mcp_exec | grep -q 'node_modules/.bin/qmd'
  # ...and never bunx (negated pipeline MUST be last — set -e exempts it otherwise)
  ! declare -f qmd_mcp_exec | grep -q 'bunx'
}
