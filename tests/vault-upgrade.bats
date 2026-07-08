#!/usr/bin/env bats
# 014 (US5, FR-016/017): vault_seed_missing — the additive upgrade of a
# pre-populated vault. Adds only the new structures, never overwrites, never
# touches CLAUDE.md, and gates the schema delta on a HIDDEN marker (not the
# deletable .md — analyze C1). Host-runnable.

load helper

setup() {
  load_lib vault
  setup_tmp_dir
  SKELETON="$REPO_ROOT/modules/vault-skeleton"
  DELTAS="$REPO_ROOT/modules/vault-deltas"
  V="$TMP_TEST_DIR/vault"
  cp -R "$REPO_ROOT/tests/fixtures/vault-populated" "$V"
}

teardown() { teardown_tmp_dir; }

# snapshot a content hash of every file under the vault
_vault_hash() { (cd "$1" && find . -type f -exec shasum {} \; | LC_ALL=C sort | shasum); }

@test "vault_seed_missing: adds normalization dir + template to a populated vault" {
  run vault_seed_missing "$V" "$SKELETON" "$DELTAS" "2026-07-07"
  [ "$status" -eq 0 ]
  [ -d "$V/wiki/normalization" ]
  [ -f "$V/_templates/normalization.md" ]
}

@test "vault_seed_missing: deposits the schema delta + hidden marker + log entry" {
  vault_seed_missing "$V" "$SKELETON" "$DELTAS" "2026-07-07"
  [ -f "$V/_templates/schema-updates-0.8.0.md" ]
  [ -f "$V/_templates/.schema-updates-0.8.0.applied" ]
  grep -q 'upgrade | schema updates 0.8.0' "$V/log.md"
}

@test "vault_seed_missing: NEVER modifies pre-existing files (CLAUDE.md byte-identical)" {
  local claude_before; claude_before=$(shasum "$V/CLAUDE.md")
  # snapshot the pre-existing wiki pages
  local pages_before; pages_before=$(cd "$V" && find wiki -type f -exec shasum {} \; | LC_ALL=C sort)
  vault_seed_missing "$V" "$SKELETON" "$DELTAS" "2026-07-07"
  [ "$(shasum "$V/CLAUDE.md")" = "$claude_before" ]
  local pages_after; pages_after=$(cd "$V" && find wiki -type f ! -path '*/normalization/*' -exec shasum {} \; | LC_ALL=C sort)
  [ "$pages_after" = "$pages_before" ]
}

@test "vault_seed_missing: idempotent — a 2nd run changes nothing (no dup log)" {
  vault_seed_missing "$V" "$SKELETON" "$DELTAS" "2026-07-07"
  local h1; h1=$(_vault_hash "$V")
  vault_seed_missing "$V" "$SKELETON" "$DELTAS" "2026-07-08"
  local h2; h2=$(_vault_hash "$V")
  [ "$h1" = "$h2" ]
  [ "$(grep -c 'upgrade | schema updates 0.8.0' "$V/log.md")" -eq 1 ]
}

@test "vault_seed_missing: C1 — deleting the delta .md does NOT re-deposit it" {
  vault_seed_missing "$V" "$SKELETON" "$DELTAS" "2026-07-07"
  rm -f "$V/_templates/schema-updates-0.8.0.md"   # agent integrated + deleted it
  vault_seed_missing "$V" "$SKELETON" "$DELTAS" "2026-07-08"
  # the hidden marker survives → no re-deposit, no second log entry
  [ ! -f "$V/_templates/schema-updates-0.8.0.md" ]
  [ "$(grep -c 'upgrade | schema updates 0.8.0' "$V/log.md")" -eq 1 ]
}

@test "vault_seed_missing: fresh 0.8.0 scaffold → NO delta, NO log entry (fresh-scaffold guard)" {
  local fresh="$TMP_TEST_DIR/fresh"
  vault_seed_if_empty "$fresh" "$SKELETON" "2026-07-07"   # full skeleton incl. normalization
  local log_before; log_before=$(cat "$fresh/log.md")
  vault_seed_missing "$fresh" "$SKELETON" "$DELTAS" "2026-07-07"
  [ ! -f "$fresh/_templates/schema-updates-0.8.0.md" ]
  [ ! -f "$fresh/_templates/.schema-updates-0.8.0.applied" ]
  [ "$(cat "$fresh/log.md")" = "$log_before" ]
}

@test "vault_seed_missing: no-op on an empty/absent target (that path is seed_if_empty)" {
  run vault_seed_missing "$TMP_TEST_DIR/empty" "$SKELETON" "$DELTAS" "2026-07-07"
  [ "$status" -eq 0 ]
  [ ! -d "$TMP_TEST_DIR/empty/wiki/normalization" ]
}

@test "vault_seed_missing: fail-silent on missing args (returns 0)" {
  run vault_seed_missing "" "$SKELETON" "$DELTAS"
  [ "$status" -eq 0 ]
}

# --- T028: triggers are wired ------------------------------------------------

@test "trigger: docker start_services.sh calls vault_seed_missing (H5: not entrypoint.sh)" {
  grep -q 'vault_seed_missing' "$REPO_ROOT/docker/scripts/start_services.sh"
  # entrypoint.sh must NOT be the trigger (it never touches the vault)
  ! grep -q 'vault_seed_missing' "$REPO_ROOT/docker/entrypoint.sh"
}

@test "trigger: setup.sh _seed_vault_local calls vault_seed_missing (host --regenerate)" {
  grep -q 'vault_seed_missing' "$REPO_ROOT/setup.sh"
  grep -q 'modules/vault-deltas' "$REPO_ROOT/setup.sh"
}
