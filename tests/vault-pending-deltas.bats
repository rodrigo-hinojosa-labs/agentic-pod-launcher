#!/usr/bin/env bats
#
# 038 - vault_pending_deltas (scripts/lib/vault.sh): which schema deltas were
# DEPOSITED into a vault but whose integration checkpoint is not yet in the vault's
# own CLAUDE.md. Pure read, always exit 0, one version per line in ascending order.
# Contract: specs/038-schema-delta-boot-nudge/contracts/vault-pending-deltas.md

load 'helper'

setup() {
  load_lib vault
  setup_tmp_dir
  V="$TMP_TEST_DIR/vault"
  mkdir -p "$V/_templates"
  printf '# vault CLAUDE.md (no checkpoints yet)\n' > "$V/CLAUDE.md"
  CP08='wiki/normalization/'
  CP27='## Actionability (PARA)'
}

teardown() { teardown_tmp_dir; }

# deposit VERSION - create the hidden marker the additive upgrade writes.
_deposit() { printf 'deposited: 2026-09-30\n' > "$V/_templates/.schema-updates-$1.applied"; }

# --- detection matrix ---------------------------------------------------------

@test "038 pending: empty, missing or template-less vault root reports nothing and exits 0" {
  run vault_pending_deltas ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run vault_pending_deltas "$TMP_TEST_DIR/does-not-exist"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  mkdir -p "$TMP_TEST_DIR/bare"
  printf '# x\n' > "$TMP_TEST_DIR/bare/CLAUDE.md"
  run vault_pending_deltas "$TMP_TEST_DIR/bare"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "038 pending: nothing deposited means nothing pending (no .applied marker)" {
  run vault_pending_deltas "$V"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "038 pending: 0.27.0 deposited and its checkpoint absent is reported" {
  _deposit 0.27.0
  run vault_pending_deltas "$V"
  [ "$status" -eq 0 ]
  [ "$output" = "0.27.0" ]
}

@test "038 pending: both deltas deposited, no checkpoints: 0.8.0 then 0.27.0, one per line" {
  _deposit 0.27.0
  _deposit 0.8.0
  run vault_pending_deltas "$V"
  [ "$status" -eq 0 ]
  [ "$output" = $'0.8.0\n0.27.0' ]
}

@test "038 pending: a checkpoint in the middle of a line counts as integrated" {
  _deposit 0.27.0
  _deposit 0.8.0
  printf 'see the wiki/normalization/ folder for writing rules\n' >> "$V/CLAUDE.md"
  run vault_pending_deltas "$V"
  [ "$status" -eq 0 ]
  [ "$output" = "0.27.0" ]
}

@test "038 pending: every checkpoint present means nothing pending" {
  _deposit 0.27.0
  _deposit 0.8.0
  printf '%s\n%s\n' "$CP08" "$CP27" >> "$V/CLAUDE.md"
  run vault_pending_deltas "$V"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "038 pending: the checkpoint is matched literally, not as a regex" {
  _deposit 0.27.0
  # '.' and '(' are regex-special; a near-miss line must NOT count as integrated.
  printf '## ActionabilityXPARAX\n' >> "$V/CLAUDE.md"
  run vault_pending_deltas "$V"
  [ "$output" = "0.27.0" ]
}

@test "038 pending: a stray marker for a version the table does not know is ignored" {
  : > "$V/_templates/.schema-updates-9.9.9.applied"
  run vault_pending_deltas "$V"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "038 pending: markers present but no vault CLAUDE.md reports nothing" {
  _deposit 0.27.0
  rm -f "$V/CLAUDE.md"
  run vault_pending_deltas "$V"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "038 pending: an unreadable vault CLAUDE.md reports nothing (cannot tell, so say nothing)" {
  [ "$(id -u)" -ne 0 ] || skip "root ignores file modes"
  _deposit 0.27.0
  chmod 000 "$V/CLAUDE.md"
  run vault_pending_deltas "$V"
  chmod 644 "$V/CLAUDE.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "038 pending: a directory where CLAUDE.md should be reports nothing" {
  _deposit 0.27.0
  rm -f "$V/CLAUDE.md"
  mkdir "$V/CLAUDE.md"
  run vault_pending_deltas "$V"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "038 pending: removing the deposited delta document does not clear it (the checkpoint decides)" {
  _deposit 0.27.0
  : > "$V/_templates/schema-updates-0.27.0.md"
  rm -f "$V/_templates/schema-updates-0.27.0.md"
  run vault_pending_deltas "$V"
  [ "$output" = "0.27.0" ]
}

@test "038 pending: read-only, the vault tree is byte-identical before and after" {
  _deposit 0.27.0
  _deposit 0.8.0
  local before after
  before=$(cd "$V" && find . | sort | while read -r p; do if [ -f "$p" ]; then cksum < "$p"; fi; echo "$p"; done | cksum)
  run vault_pending_deltas "$V"
  # the function must really have run (a missing function would also leave the tree untouched)
  [ "$status" -eq 0 ]
  [ "$output" = $'0.8.0\n0.27.0' ]
  after=$(cd "$V" && find . | sort | while read -r p; do if [ -f "$p" ]; then cksum < "$p"; fi; echo "$p"; done | cksum)
  [ "$before" = "$after" ]
}

@test "038 pending: safe under set -euo pipefail with a large CLAUDE.md (no SIGPIPE trap)" {
  _deposit 0.27.0
  # 3 MiB file built on disk (never through argv/env); the checkpoint is at the TOP so
  # an early-exit reader is exactly the shape that dies with 141 behind a pipe.
  { printf '%s\n' "$CP27"; yes 'filler line to make the file big enough to matter' | head -n 60000; } > "$V/CLAUDE.md"
  run bash -c 'set -euo pipefail; source "$1/scripts/lib/vault.sh"; vault_pending_deltas "$2"; echo END' _ "$REPO_ROOT" "$V"
  [ "$status" -eq 0 ]
  [ "$output" = "END" ]
  # and the same with the checkpoint absent: reported, still rc 0
  yes 'filler line to make the file big enough to matter' | head -n 60000 > "$V/CLAUDE.md"
  run bash -c 'set -euo pipefail; source "$1/scripts/lib/vault.sh"; vault_pending_deltas "$2"; echo END' _ "$REPO_ROOT" "$V"
  [ "$status" -eq 0 ]
  [ "$output" = $'0.27.0\nEND' ]
}

# --- the table ----------------------------------------------------------------

@test "038 table: vault_delta_versions prints 0.8.0 then 0.27.0 and nothing else" {
  run vault_delta_versions
  [ "$status" -eq 0 ]
  [ "$output" = $'0.8.0\n0.27.0' ]
}

@test "038 table: vault_delta_checkpoint returns the literal for each known version" {
  run vault_delta_checkpoint 0.8.0
  [ "$status" -eq 0 ]
  [ "$output" = "wiki/normalization/" ]
  run vault_delta_checkpoint 0.27.0
  [ "$status" -eq 0 ]
  [ "$output" = "## Actionability (PARA)" ]
}

@test "038 table: an unknown version returns 1 with no output" {
  run vault_delta_checkpoint 9.9.9
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  run vault_delta_checkpoint ""
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

# --- drift guards: the table must not silently diverge from what ships --------

@test "038 drift G1: every shipped delta document has a checkpoint, and every table version has a document" {
  local f ver
  for f in "$REPO_ROOT"/modules/vault-deltas/schema-updates-*.md; do
    ver=$(basename "$f" .md | sed 's/^schema-updates-//')
    vault_delta_checkpoint "$ver" >/dev/null || { echo "no checkpoint row for shipped delta $ver"; return 1; }
  done
  local versions
  versions=$(vault_delta_versions)
  [ -n "$versions" ]
  for ver in $versions; do
    [ -f "$REPO_ROOT/modules/vault-deltas/schema-updates-$ver.md" ] || { echo "table version $ver has no delta document"; return 1; }
  done
}

@test "038 drift G2: the skeleton CLAUDE.md contains every checkpoint (a fresh vault is never pending)" {
  local ver cp versions
  versions=$(vault_delta_versions)
  [ -n "$versions" ]   # an empty table would make this loop vacuous
  for ver in $versions; do
    cp=$(vault_delta_checkpoint "$ver")
    grep -F -q -- "$cp" "$REPO_ROOT/modules/vault-skeleton/CLAUDE.md" || { echo "skeleton lacks checkpoint for $ver: $cp"; return 1; }
  done
}

@test "038 drift G2b: a vault seeded from the skeleton reports nothing pending, end to end" {
  local fresh="$TMP_TEST_DIR/fresh"
  vault_seed_if_empty "$fresh" "$REPO_ROOT/modules/vault-skeleton" 2026-09-30
  [ -f "$fresh/_templates/.schema-updates-0.27.0.applied" ]
  run vault_pending_deltas "$fresh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "038 drift G3: the literal wiki_graph.sh uses for 'integrated' equals the 0.27.0 checkpoint" {
  local lit
  lit=$(grep -E "grep -F -q -- '[^']+' \"\\\$vault_dir/CLAUDE.md\"" "$REPO_ROOT/scripts/lib/wiki_graph.sh" | head -1 | sed -E "s/.*grep -F -q -- '([^']+)'.*/\1/")
  [ -n "$lit" ]
  [ "$lit" = "$(vault_delta_checkpoint 0.27.0)" ]
}

@test "038 drift G4: each shipped delta document contains its own checkpoint" {
  local ver cp versions
  versions=$(vault_delta_versions)
  [ -n "$versions" ]   # an empty table would make this loop vacuous
  for ver in $versions; do
    cp=$(vault_delta_checkpoint "$ver")
    grep -F -q -- "$cp" "$REPO_ROOT/modules/vault-deltas/schema-updates-$ver.md" || { echo "delta $ver does not contain its checkpoint: $cp"; return 1; }
  done
}
