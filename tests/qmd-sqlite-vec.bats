#!/usr/bin/env bats
# 017: sqlite-vec musl swap + qmd/sqlite-vec version guardrail.
#
# The prebuilt sqlite-vec-linux-arm64/vec0.so is GLIBC and cannot dlopen on musl
# (needs ld-linux + __memcpy_chk@GLIBC). On musl we bake a musl-compiled vec0.so at
# image build and swap it into the managed prefix. These host tests assert the
# swap LOGIC (gate by musl + baked artifact, idempotency, fail-silent) with mock
# files — the real compile + embed is exercised by DOCKER_E2E.

load helper

setup() {
  setup_tmp_dir
  load_lib qmd_index
  PREFIX="$TMP_TEST_DIR/pkg"
  SV_DIR="$PREFIX/node_modules/sqlite-vec-linux-arm64"
  mkdir -p "$SV_DIR"
  printf 'GLIBC-PREBUILT' > "$SV_DIR/vec0.so"   # stand-in for the glibc prebuilt
  # Mock musl loader (present == musl) and baked musl artifact.
  export QMD_MUSL_LOADER="$TMP_TEST_DIR/ld-musl"; : > "$QMD_MUSL_LOADER"
  export QMD_VEC0_MUSL_SO="$TMP_TEST_DIR/vec0-musl.so"; printf 'MUSL-BUILD' > "$QMD_VEC0_MUSL_SO"
}

# --- US1: swap logic ---------------------------------------------------------

@test "swap replaces the glibc prebuilt with the musl build on musl + artifact present" {
  run _qmd_swap_sqlite_vec "$PREFIX"
  [ "$status" -eq 0 ]
  run cat "$SV_DIR/vec0.so"
  [ "$output" = "MUSL-BUILD" ]
}

@test "swap is a no-op on glibc (musl loader absent)" {
  export QMD_MUSL_LOADER="$TMP_TEST_DIR/does-not-exist"
  run _qmd_swap_sqlite_vec "$PREFIX"
  [ "$status" -eq 0 ]
  run cat "$SV_DIR/vec0.so"
  [ "$output" = "GLIBC-PREBUILT" ]
}

@test "swap on musl with the baked artifact absent logs + continues (fail-silent), prebuilt untouched" {
  export QMD_VEC0_MUSL_SO="$TMP_TEST_DIR/absent-artifact.so"
  run _qmd_swap_sqlite_vec "$PREFIX"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "unavailable"
  run cat "$SV_DIR/vec0.so"
  [ "$output" = "GLIBC-PREBUILT" ]
}

@test "swap is idempotent (second call is a no-op, content stays the musl build)" {
  _qmd_swap_sqlite_vec "$PREFIX"
  run _qmd_swap_sqlite_vec "$PREFIX"
  [ "$status" -eq 0 ]
  run cat "$SV_DIR/vec0.so"
  [ "$output" = "MUSL-BUILD" ]
}

@test "swap is a no-op when the sqlite-vec package dir is absent" {
  rm -rf "$SV_DIR"
  run _qmd_swap_sqlite_vec "$PREFIX"
  [ "$status" -eq 0 ]
}

# --- US3: version guardrail --------------------------------------------------

@test "qmd pin default is the known-good 2.5.3" {
  run qmd_pkg "$TMP_TEST_DIR/no-agent.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "@tobilu/qmd@2.5.3" ]
}

@test "Dockerfile pins SQLITE_VEC_VERSION to the known-good 0.1.9 (paired with qmd 2.5.3)" {
  # Guardrail: if qmd is bumped past 2.5.3, its transitive sqlite-vec may change and
  # the musl compile shim (research R2) must be re-verified. This test fixes the
  # known-good pair so a bump can't slip through silently.
  local qmd_ver sv_ver
  qmd_ver="$(qmd_pkg "$TMP_TEST_DIR/no-agent.yml")"
  [ "$qmd_ver" = "@tobilu/qmd@2.5.3" ]
  run grep -Eq '^ARG SQLITE_VEC_VERSION=0\.1\.9$' "$REPO_ROOT/docker/Dockerfile"
  [ "$status" -eq 0 ]
}
