#!/usr/bin/env bats
# 016 US4: guardrail so a qmd version bump can't pass silently. The 016 fix relies
# on tree-sitter-* being optionalDependencies in 2.5.3 (bun default-deny leaves
# them unbuilt → WASM path). In 2.6.x they became HARD deps, which would break the
# trustedDependencies strategy. Bumping vault.qmd.version therefore MUST be a
# deliberate change that also updates this test + docs/qmd-upgrade-checklist.md.

load helper

setup() {
  setup_tmp_dir
  load_lib qmd_index
}

teardown() { teardown_tmp_dir; }

@test "qmd pin default is 2.5.3 (bump requires updating this test + the pre-bump checklist)" {
  # No agent.yml key → the documented floor default in qmd_pkg().
  run qmd_pkg "$TMP_TEST_DIR/nonexistent.yml"
  [ "$output" = "@tobilu/qmd@2.5.3" ]
}

@test "qmd pin reads vault.qmd.version from agent.yml when present" {
  command -v yq >/dev/null 2>&1 || skip "yq required"
  local y="$TMP_TEST_DIR/a.yml"
  printf 'vault:\n  qmd:\n    version: "2.5.3"\n' > "$y"
  run qmd_pkg "$y"
  [ "$output" = "@tobilu/qmd@2.5.3" ]
}

@test "the pre-bump checklist exists and is referenced" {
  [ -f "$REPO_ROOT/docs/qmd-upgrade-checklist.md" ]
  grep -q 'optionalDependencies' "$REPO_ROOT/docs/qmd-upgrade-checklist.md"
}
