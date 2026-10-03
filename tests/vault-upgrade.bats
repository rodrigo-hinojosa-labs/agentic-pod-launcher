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

# ── 037 delta 0.27.0 ─────────────────────────────────────────────────────────
# contracts/vault-schema-delta-0.27.0.md §4, data-model.md §7. Three states:
# pre-014 populated (vault-populated), 0.8.0-complete-empty (vault-0.8.0-empty),
# 0.8.0-with-pages (vault-0.8.0-pages). Additive, idempotent, never touches a
# preexisting file, CANON-D13/D14 exact.

# sha256 of every preexisting file (path\tsha), sorted — used to prove 0 changes.
_sha_list() { (cd "$1" && find . -type f -exec shasum -a 256 {} \; | LC_ALL=C sort); }

# same, but excluding log.md — appending to it is the sanctioned mutation; "0
# preexisting files modified" is about everything ELSE.
_sha_list_no_log() { (cd "$1" && find . -type f ! -name 'log.md' -exec shasum -a 256 {} \; | LC_ALL=C sort); }

@test "037 delta: vault-populated receives BOTH 0.8.0 and 0.27.0 deltas + both markers" {
  local d="$TMP_TEST_DIR/populated"
  cp -R "$REPO_ROOT/tests/fixtures/vault-populated" "$d"
  local before; before=$(_sha_list_no_log "$d")
  run vault_seed_missing "$d" "$SKELETON" "$DELTAS" "2030-06-15"
  [ "$status" -eq 0 ]
  local after; after=$(_sha_list_no_log "$d")
  # every preexisting file line is still present verbatim (0 modified, log.md excluded)
  comm -23 <(printf '%s\n' "$before") <(printf '%s\n' "$after") > "$TMP_TEST_DIR/gone.txt"
  [ ! -s "$TMP_TEST_DIR/gone.txt" ]
  [ -f "$d/_templates/schema-updates-0.8.0.md" ]
  [ -f "$d/_templates/.schema-updates-0.8.0.applied" ]
  [ -f "$d/_templates/schema-updates-0.27.0.md" ]
  [ -f "$d/_templates/entity-project.md" ]
  [ -f "$d/_templates/overview-area.md" ]
  [ "$(cat "$d/_templates/.schema-updates-0.27.0.applied")" = "deposited: 2030-06-15" ]
  [ "$(grep -c 'upgrade | schema delta 0.27.0 deposited' "$d/log.md")" -eq 1 ]
}

@test "037 delta: second run (later date) is a no-op — marker date and log line unchanged" {
  local d="$TMP_TEST_DIR/populated"
  cp -R "$REPO_ROOT/tests/fixtures/vault-populated" "$d"
  vault_seed_missing "$d" "$SKELETON" "$DELTAS" "2030-06-15"
  local h1; h1=$(_sha_list "$d")
  vault_seed_missing "$d" "$SKELETON" "$DELTAS" "2030-06-16"
  local h2; h2=$(_sha_list "$d")
  [ "$h1" = "$h2" ]
  [ "$(cat "$d/_templates/.schema-updates-0.27.0.applied")" = "deposited: 2030-06-15" ]
  [ "$(grep -c 'upgrade | schema delta 0.27.0 deposited' "$d/log.md")" -eq 1 ]
}

@test "037 delta: vault-0.8.0-empty (no 0.8.0 marker) gets ONLY 0.27.0 — fresh-scaffold guard stays quiet (M10)" {
  local d="$TMP_TEST_DIR/e"
  cp -R "$REPO_ROOT/tests/fixtures/vault-0.8.0-empty" "$d"
  local before; before=$(_sha_list_no_log "$d")
  run vault_seed_missing "$d" "$SKELETON" "$DELTAS" "2030-06-15"
  [ "$status" -eq 0 ]
  comm -23 <(printf '%s\n' "$before") <(printf '%s\n' "$(_sha_list_no_log "$d")") > "$TMP_TEST_DIR/gone.txt"
  [ ! -s "$TMP_TEST_DIR/gone.txt" ]
  [ ! -f "$d/_templates/schema-updates-0.8.0.md" ]
  [ ! -f "$d/_templates/.schema-updates-0.8.0.applied" ]
  ! grep -q 'schema updates 0.8.0' "$d/log.md"
  [ -f "$d/_templates/schema-updates-0.27.0.md" ]
  [ "$(cat "$d/_templates/.schema-updates-0.27.0.applied")" = "deposited: 2030-06-15" ]
}

@test "037 delta: vault-0.8.0-pages gets ONLY 0.27.0 — the empty 0.8.0 marker stays empty" {
  local d="$TMP_TEST_DIR/p"
  cp -R "$REPO_ROOT/tests/fixtures/vault-0.8.0-pages" "$d"
  local marker_before; marker_before=$(cat "$d/_templates/.schema-updates-0.8.0.applied")
  local before; before=$(_sha_list_no_log "$d")
  run vault_seed_missing "$d" "$SKELETON" "$DELTAS" "2030-06-15"
  [ "$status" -eq 0 ]
  comm -23 <(printf '%s\n' "$before") <(printf '%s\n' "$(_sha_list_no_log "$d")") > "$TMP_TEST_DIR/gone.txt"
  [ ! -s "$TMP_TEST_DIR/gone.txt" ]
  [ -z "$marker_before" ]
  [ -z "$(cat "$d/_templates/.schema-updates-0.8.0.applied")" ]
  ! grep -q 'schema updates 0.8.0' "$d/log.md"
  [ -f "$d/_templates/schema-updates-0.27.0.md" ]
  [ "$(cat "$d/_templates/.schema-updates-0.27.0.applied")" = "deposited: 2030-06-15" ]
}

@test "037 delta: fresh scaffold gets the 0.27.0 marker dated at seed time, no delta .md" {
  local d="$TMP_TEST_DIR/fresh27"
  run vault_seed_if_empty "$d" "$SKELETON" "2030-06-15"
  [ "$status" -eq 0 ]
  [ "$(cat "$d/_templates/.schema-updates-0.27.0.applied")" = "deposited: 2030-06-15" ]
  [ ! -f "$d/_templates/schema-updates-0.27.0.md" ]
}

@test "037 delta: vault_seed_missing on a fresh scaffold is a no-op (marker present = delta not owed)" {
  local d="$TMP_TEST_DIR/fresh27b"
  vault_seed_if_empty "$d" "$SKELETON" "2030-06-15"
  local before; before=$(_sha_list "$d")
  run vault_seed_missing "$d" "$SKELETON" "$DELTAS" "2030-06-20"
  [ "$status" -eq 0 ]
  [ "$(_sha_list "$d")" = "$before" ]
  [ "$(cat "$d/_templates/.schema-updates-0.27.0.applied")" = "deposited: 2030-06-15" ]
}

@test "037 delta (M17): has_pages27 stays reliable under pipefail on a large populated wiki" {
  # M17 (quickstart.md §4): the naive `find | head -1 | grep -q .` form reads
  # FALSE under `set -o pipefail` once find writes enough output that head
  # closes the pipe before find finishes -- find then dies of SIGPIPE (141)
  # and pipefail promotes that into the pipeline's own exit status, even
  # though grep itself matched. `-print -quit` (the real code) has no
  # downstream reader to close early, so it cannot suffer this race by
  # construction. Reproduced locally at 10,000 padded filenames (8/8 FALSE
  # on the naive form measured while designing this test); real vault content
  # sizes on ferrari are in this range.
  local d="$TMP_TEST_DIR/large-populated"
  mkdir -p "$d/wiki/concepts" "$d/wiki/normalization" "$d/_templates"
  : > "$d/CLAUDE.md"
  : > "$d/log.md"
  : > "$d/_templates/.schema-updates-0.8.0.applied"
  : > "$d/_templates/normalization.md"
  : > "$d/_templates/entity-project.md"
  : > "$d/_templates/overview-area.md"
  local i
  for i in $(seq 1 10000); do : > "$d/wiki/concepts/a-fairly-long-filename-to-pad-bytes-$i.md"; done
  run bash -c 'set -o pipefail; source "$1"; vault_seed_missing "$2" "$3" "$4" "$5"' _ \
    "$REPO_ROOT/scripts/lib/vault.sh" "$d" "$SKELETON" "$DELTAS" "2026-07-07"
  [ "$status" -eq 0 ]
  [ -f "$d/_templates/.schema-updates-0.27.0.applied" ]
}
