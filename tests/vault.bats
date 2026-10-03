#!/usr/bin/env bats

load 'helper'

setup() {
  load_lib vault
  setup_tmp_dir
  SKELETON="$REPO_ROOT/modules/vault-skeleton"
}

teardown() {
  teardown_tmp_dir
}

# --- skeleton structure -----------------------------------------------------

@test "skeleton: required top-level entries exist" {
  [ -d "$SKELETON/raw_sources" ]
  [ -d "$SKELETON/wiki" ]
  [ -d "$SKELETON/_templates" ]
  [ -f "$SKELETON/index.md" ]
  [ -f "$SKELETON/log.md" ]
  [ -f "$SKELETON/CLAUDE.md" ]
}

@test "skeleton: raw_sources has README" {
  [ -f "$SKELETON/raw_sources/README.md" ]
}

@test "skeleton: wiki has the six Karpathy page-type subdirs" {
  for t in summaries entities concepts comparisons overviews synthesis; do
    [ -d "$SKELETON/wiki/$t" ] || { echo "missing: wiki/$t"; return 1; }
  done
}

@test "skeleton: _templates has one file per page type plus source" {
  for t in source summary entity concept comparison overview synthesis; do
    [ -f "$SKELETON/_templates/$t.md" ] || { echo "missing: _templates/$t.md"; return 1; }
  done
}

@test "skeleton: page templates have valid YAML frontmatter with the right type" {
  for t in summary entity concept comparison overview synthesis; do
    local f="$SKELETON/_templates/$t.md"
    [ -f "$f" ] || { echo "missing: $f"; return 1; }
    head -1 "$f" | grep -q '^---$' || { echo "$f: no opening ---"; return 1; }
    local fm type_val
    fm=$(awk '/^---$/{c++; if(c==2) exit; next} c==1{print}' "$f")
    [ -n "$fm" ] || { echo "$f: empty frontmatter"; return 1; }
    type_val=$(printf '%s\n' "$fm" | yq '.type' 2>/dev/null)
    [ "$type_val" = "$t" ] || { echo "$f: type=$type_val, expected $t"; return 1; }
  done
}

@test "skeleton: log.md contains SCAFFOLD_DATE placeholder pre-seed" {
  grep -q 'SCAFFOLD_DATE' "$SKELETON/log.md"
}

@test "skeleton: index.md has all six section headers" {
  for h in Summaries Entities Concepts Comparisons Overviews Synthesis; do
    grep -qE "^## $h\$" "$SKELETON/index.md" || { echo "missing header: $h"; return 1; }
  done
}

# --- 014: normalization layer + schema markers -------------------------------

@test "skeleton (014): normalization dir + template exist, index has the section" {
  [ -d "$SKELETON/wiki/normalization" ]
  [ -f "$SKELETON/_templates/normalization.md" ]
  grep -qE '^## Normalization$' "$SKELETON/index.md"
  # template carries the own-frontmatter keys (not the six-type ones)
  grep -q '^canonical:' "$SKELETON/_templates/normalization.md"
  grep -q '^aliases:' "$SKELETON/_templates/normalization.md"
}

@test "skeleton (014): CLAUDE.md documents the 2.5 Normalize + graph query steps (L2)" {
  grep -q '2.5. \*\*Normalize terminology' "$SKELETON/CLAUDE.md"
  grep -q '.graph/backlinks.json' "$SKELETON/CLAUDE.md"
}

@test "vault_seed_if_empty (014): normalization layer + schema markers reach the seed" {
  run vault_seed_if_empty "$TMP_TEST_DIR/vseed14" "$SKELETON" "2026-07-07"
  [ "$status" -eq 0 ]
  [ -d "$TMP_TEST_DIR/vseed14/wiki/normalization" ]
  [ -f "$TMP_TEST_DIR/vseed14/_templates/normalization.md" ]
  grep -q '2.5. \*\*Normalize terminology' "$TMP_TEST_DIR/vseed14/CLAUDE.md"
  grep -q '.graph/backlinks.json' "$TMP_TEST_DIR/vseed14/CLAUDE.md"
}

# --- vault_ensure_paths -----------------------------------------------------

@test "vault_ensure_paths: creates the directory" {
  run vault_ensure_paths "$TMP_TEST_DIR/v1"
  [ "$status" -eq 0 ]
  [ -d "$TMP_TEST_DIR/v1" ]
}

@test "vault_ensure_paths: idempotent when dir exists" {
  mkdir -p "$TMP_TEST_DIR/v2"
  echo "preexisting" > "$TMP_TEST_DIR/v2/file"
  run vault_ensure_paths "$TMP_TEST_DIR/v2"
  [ "$status" -eq 0 ]
  [ -f "$TMP_TEST_DIR/v2/file" ]
}

@test "vault_ensure_paths: errors on missing arg" {
  run vault_ensure_paths
  [ "$status" -ne 0 ]
}

# --- vault_seed_if_empty ----------------------------------------------------

@test "vault_seed_if_empty: copies skeleton into empty target" {
  local target="$TMP_TEST_DIR/seeded"
  run vault_seed_if_empty "$target" "$SKELETON" "2026-04-26"
  [ "$status" -eq 0 ]
  [ -f "$target/CLAUDE.md" ]
  [ -f "$target/index.md" ]
  [ -f "$target/log.md" ]
  [ -d "$target/wiki/concepts" ]
  [ -f "$target/_templates/summary.md" ]
}

@test "vault_seed_if_empty: replaces SCAFFOLD_DATE in log.md with provided date" {
  local target="$TMP_TEST_DIR/seeded2"
  run vault_seed_if_empty "$target" "$SKELETON" "2026-04-26"
  [ "$status" -eq 0 ]
  ! grep -q 'SCAFFOLD_DATE' "$target/log.md"
  grep -q '\[2026-04-26\] init' "$target/log.md"
}

@test "vault_seed_if_empty: no-op when target has content" {
  local target="$TMP_TEST_DIR/already-there"
  mkdir -p "$target"
  echo "user content" > "$target/notes.md"
  run vault_seed_if_empty "$target" "$SKELETON" "2026-04-26"
  [ "$status" -eq 0 ]
  [ -f "$target/notes.md" ]
  [ ! -f "$target/CLAUDE.md" ]
}

@test "vault_seed_if_empty: errors on missing skeleton" {
  run vault_seed_if_empty "$TMP_TEST_DIR/x" "$TMP_TEST_DIR/nonexistent-skeleton"
  [ "$status" -ne 0 ]
}

# --- vault_log_append -------------------------------------------------------

@test "vault_log_append: appends a Karpathy-format entry" {
  local target="$TMP_TEST_DIR/with-log"
  vault_seed_if_empty "$target" "$SKELETON" "2026-04-26"
  run vault_log_append "$target" "ingest" "Karpathy LLM Wiki" "2026-05-01"
  [ "$status" -eq 0 ]
  grep -qE '^## \[2026-05-01\] ingest \| Karpathy LLM Wiki$' "$target/log.md"
}

@test "vault_log_append: errors when log.md is missing" {
  mkdir -p "$TMP_TEST_DIR/no-log"
  run vault_log_append "$TMP_TEST_DIR/no-log" "ingest" "X"
  [ "$status" -ne 0 ]
}

@test "vault_log_append: errors on missing args" {
  run vault_log_append "$TMP_TEST_DIR" "" ""
  [ "$status" -ne 0 ]
}

# --- vault_backup_and_reseed -----------------------------------------------

@test "vault_backup_and_reseed: equivalent to seed when target is empty/missing" {
  local target="$TMP_TEST_DIR/empty-target"
  run vault_backup_and_reseed "$target" "$SKELETON" "2026-04-29" "2026-04-29-120000"
  [ "$status" -eq 0 ]
  [ -f "$target/CLAUDE.md" ]
  [ -d "$target/wiki/concepts" ]
  # No backup created since there was nothing to back up
  [ ! -d "$target.backup-2026-04-29-120000" ]
}

@test "vault_backup_and_reseed: backs up existing content and re-seeds" {
  local target="$TMP_TEST_DIR/existing-vault"
  mkdir -p "$target/wiki/concepts"
  echo "user-content" > "$target/wiki/concepts/my-note.md"
  echo "old log" > "$target/log.md"

  run vault_backup_and_reseed "$target" "$SKELETON" "2026-04-29" "2026-04-29-120000"
  [ "$status" -eq 0 ]

  # Backup preserved with the expected timestamped path
  [ -d "$target.backup-2026-04-29-120000" ]
  [ -f "$target.backup-2026-04-29-120000/wiki/concepts/my-note.md" ]
  grep -q "user-content" "$target.backup-2026-04-29-120000/wiki/concepts/my-note.md"

  # Fresh skeleton at the original path
  [ -f "$target/CLAUDE.md" ]
  grep -q "Karpathy" "$target/CLAUDE.md"
  [ -d "$target/wiki/concepts" ]
  [ ! -f "$target/wiki/concepts/my-note.md" ]
  grep -qE '## \[2026-04-29\] init' "$target/log.md"
}

@test "vault_backup_and_reseed: errors on missing args" {
  run vault_backup_and_reseed
  [ "$status" -ne 0 ]
  run vault_backup_and_reseed "$TMP_TEST_DIR/x"
  [ "$status" -ne 0 ]
}

@test "vault_backup_and_reseed: errors on missing skeleton" {
  run vault_backup_and_reseed "$TMP_TEST_DIR/y" "$TMP_TEST_DIR/nonexistent-skeleton"
  [ "$status" -ne 0 ]
}

# ── 037 schema ────────────────────────────────────────────────────────────────
# contracts/vault-schema-delta-0.27.0.md — CANON-D* literals, one text delivered
# by two vehicles (skeleton + delta), verbatim per section (D12 delta-only).

_canon_count() {
  local file="$1" needle="$2"
  grep -F -c -- "$needle" "$file" 2>/dev/null || true
}

# extract HDR (exact "## ..." line) up to (excluding) the next "## " line.
_canon_extract() {
  local hdr="$1" file="$2"
  awk -v hdr="$hdr" '
    $0 == hdr { grab=1; print; next }
    grab && /^## / { exit }
    grab { print }
  ' "$file"
}

DELTA_037="$REPO_ROOT/modules/vault-deltas/schema-updates-0.27.0.md"

@test "037 schema: CANON-D1..D5,D10,D11 each appear exactly once in the skeleton CLAUDE.md (D8/D9 land in T020, after qmd hygiene, FR-011)" {
  for canon in \
    '## Actionability (PARA)' \
    '## Operation: project kickoff' \
    '## Operation: project close' \
    '## Operation: weekly review' \
    '## Operation: monthly review' \
    '## Intermediate packets' \
    '## Favorite problems'
  do
    n=$(_canon_count "$SKELETON/CLAUDE.md" "$canon")
    [ "$n" -eq 1 ] || { echo "expected 1 occurrence of '$canon', got $n" >&2; return 1; }
  done
}

@test "037 schema: CANON-D6/D7 (Step 0 / Step 0.5, em dash) each appear exactly once" {
  [ "$(_canon_count "$SKELETON/CLAUDE.md" 'Step 0 — read the map first')" -eq 1 ]
  [ "$(_canon_count "$SKELETON/CLAUDE.md" 'Step 0.5 — capture filter')" -eq 1 ]
}

@test "037 schema: CANON-D15 log.md format line lists all ten op kinds, exactly once" {
  [ "$(_canon_count "$SKELETON/log.md" '{ingest|query|lint|init|upgrade|project-open|project-close|review|session|other}')" -eq 1 ]
}

@test "037 schema: CANON-D12 is delta-only (0 in skeleton, present in delta)" {
  [ "$(_canon_count "$SKELETON/CLAUDE.md" '## Migration: project_* memory files')" -eq 0 ]
  [ "$(_canon_count "$DELTA_037" '## Migration: project_* memory files')" -ge 1 ]
}

@test "037 schema: each CANON-D section is verbatim identical between skeleton and delta" {
  for hdr in \
    '## Actionability (PARA)' \
    '## Operation: project kickoff' \
    '## Operation: project close' \
    '## Operation: weekly review' \
    '## Operation: monthly review' \
    '## Intermediate packets' \
    '## Favorite problems'
  do
    _canon_extract "$hdr" "$SKELETON/CLAUDE.md" > "$TMP_TEST_DIR/a.txt"
    _canon_extract "$hdr" "$DELTA_037" > "$TMP_TEST_DIR/b.txt"
    diff -q "$TMP_TEST_DIR/a.txt" "$TMP_TEST_DIR/b.txt" >/dev/null || \
      { echo "section diverged: $hdr" >&2; diff "$TMP_TEST_DIR/a.txt" "$TMP_TEST_DIR/b.txt" >&2; return 1; }
  done
}

@test "037 schema: index.md has the five PARA sections, examples only inside comments" {
  for section in '## Projects (active)' '## Areas' '## Archive' '## Packets' '## Favorite problems'; do
    grep -F -q -- "$section" "$SKELETON/index.md"
  done
  # no live bullet entries outside HTML comments for the new sections
  run grep -B1 -A1 '^## Projects (active)$' "$SKELETON/index.md"
  [[ "$output" != *"- [[entities/"* ]]
}

@test "037 schema: entity-project.md and overview-area.md templates exist with required keys" {
  local t="$SKELETON/_templates/entity-project.md"
  [ -f "$t" ]
  grep -q '^type: entity$' "$t"
  grep -q '^para: project$' "$t"
  grep -q '^goal: ' "$t"
  grep -q '^due: ' "$t"
  grep -q '^next_action: ' "$t"
  grep -q '^next_review: ' "$t"
  grep -q '^description: ' "$t"

  t="$SKELETON/_templates/overview-area.md"
  [ -f "$t" ]
  grep -q '^type: overview$' "$t"
  grep -q '^para: area$' "$t"
  grep -q '^standard: ' "$t"
  grep -q '^cadence: ' "$t"
  grep -q '^description: ' "$t"
}

@test "037 schema: the six pre-existing templates gain description:" {
  for t in entity concept comparison overview synthesis; do
    grep -q '^description: ' "$SKELETON/_templates/$t.md"
  done
  grep -q '^description: ' "$SKELETON/_templates/summary.md"
  grep -q '^distill: 1' "$SKELETON/_templates/summary.md"
}

@test "037 schema: raw_sources/README.md mentions Grep and search_notes" {
  grep -q 'Grep' "$SKELETON/raw_sources/README.md"
  grep -q 'search_notes' "$SKELETON/raw_sources/README.md"
}

@test "037 schema: no wiki page under the skeleton besides .gitkeep" {
  run find "$SKELETON/wiki" -mindepth 1 -type f ! -name '.gitkeep'
  [ -z "$output" ]
}

@test "037 schema: zero combining marks in skeleton, templates and delta" {
  local hit
  hit=$(LC_ALL=C grep -rc $'\xcc\x80' "$SKELETON" "$DELTA_037" 2>/dev/null | grep -v ':0$' || true)
  [ -z "$hit" ]
}

# ── 037 operations ───────────────────────────────────────────────────────────
# contracts/vault-schema-delta-0.27.0.md §3.5-3.10 — mechanical content inside
# each operation; CANON-D8/D9 land HERE (moved from T005 by FR-011: their prose
# writes to log.md, which only leaves the qmd collection once US2 lands).

@test "037 operations: project kickoff (D2) mentions packets.json, reciprocal related:, next_review, project-open" {
  grep -Fq -- 'packets.json' "$SKELETON/CLAUDE.md"
  grep -Fq -- 'related:' "$SKELETON/CLAUDE.md"
  grep -Fq -- 'next_review' "$SKELETON/CLAUDE.md"
  grep -Fq -- 'project-open' "$SKELETON/CLAUDE.md"
}

@test "037 operations: project close (D3) mentions para: archive, archived:, ## Archive, project-close, never move" {
  grep -Fq -- 'para: archive' "$SKELETON/CLAUDE.md"
  grep -Fq -- 'archived:' "$SKELETON/CLAUDE.md"
  grep -Fq -- '## Archive' "$SKELETON/CLAUDE.md"
  grep -Fq -- 'project-close' "$SKELETON/CLAUDE.md"
  grep -Fq -- 'never move' "$SKELETON/CLAUDE.md"
}

@test "037 operations: weekly review (D4) mentions the queue kinds, at-most-three and the every-project rule" {
  for needle in pending_ingest project_overdue project_incomplete review_due 'review | weekly' 'at most three'; do
    grep -Fq -- "$needle" "$SKELETON/CLAUDE.md" || { echo "missing: $needle" >&2; return 1; }
  done
  grep -Fqi -- 'do not review every project every week' "$SKELETON/CLAUDE.md"
}

@test "037 operations: monthly review (D5) mentions archive_candidate, para: area, review | monthly" {
  grep -Fq -- 'archive_candidate' "$SKELETON/CLAUDE.md"
  grep -Fq -- 'para: area' "$SKELETON/CLAUDE.md"
  grep -Fq -- 'review | monthly' "$SKELETON/CLAUDE.md"
}

@test "037 operations: CANON-D8 and CANON-D9 headers exist exactly once in skeleton and delta" {
  [ "$(_canon_count "$SKELETON/CLAUDE.md" '## Filing policy')" -eq 1 ]
  [ "$(_canon_count "$SKELETON/CLAUDE.md" '## Session close (Hemingway Bridge)')" -eq 1 ]
  [ "$(_canon_count "$DELTA_037" '## Filing policy')" -eq 1 ]
  [ "$(_canon_count "$DELTA_037" '## Session close (Hemingway Bridge)')" -eq 1 ]
}

@test "037 operations: Filing policy (D8) mentions filed: and the three-or-more-pages rule" {
  grep -Fq -- 'filed:' "$SKELETON/CLAUDE.md"
  grep -Fqi -- 'three or more pages' "$SKELETON/CLAUDE.md"
}

@test "037 operations: Session close (D9) mentions next_action and the session | log line" {
  _canon_extract '## Session close (Hemingway Bridge)' "$SKELETON/CLAUDE.md" > "$TMP_TEST_DIR/d9.txt"
  grep -Fq -- 'next_action' "$TMP_TEST_DIR/d9.txt"
  grep -Fq -- 'session |' "$TMP_TEST_DIR/d9.txt"
}

@test "037 operations: D8/D9 sections are verbatim identical between skeleton and delta" {
  for hdr in '## Filing policy' '## Session close (Hemingway Bridge)'; do
    _canon_extract "$hdr" "$SKELETON/CLAUDE.md" > "$TMP_TEST_DIR/a.txt"
    _canon_extract "$hdr" "$DELTA_037" > "$TMP_TEST_DIR/b.txt"
    diff -q "$TMP_TEST_DIR/a.txt" "$TMP_TEST_DIR/b.txt" >/dev/null || \
      { echo "section diverged: $hdr" >&2; diff "$TMP_TEST_DIR/a.txt" "$TMP_TEST_DIR/b.txt" >&2; return 1; }
  done
}

@test "037 operations: query offers the review in the first message when review_due/pending_ingest > 0 (FR-018)" {
  _canon_extract '## Operation: answering questions (query)' "$SKELETON/CLAUDE.md" > "$TMP_TEST_DIR/query.txt"
  grep -Fqi -- 'first message' "$TMP_TEST_DIR/query.txt"
  grep -Fq -- 'review_due' "$TMP_TEST_DIR/query.txt"
  grep -Fq -- 'pending_ingest' "$TMP_TEST_DIR/query.txt"
}

# ── 037 index-first ──────────────────────────────────────────────────────────
# contracts/vault-schema-delta-0.27.0.md §3.3/§3.2 — Step 0 content (CANON-D6),
# extended frontmatter and distill prose. T023/T024.

@test "037 index-first: Step 0 (D6) names policy.json, the threshold, the map sources and the raw-search escape hatch" {
  _canon_extract '## Operation: answering questions (query)' "$SKELETON/CLAUDE.md" > "$TMP_TEST_DIR/query.txt"
  for needle in 'policy.json' 'index_first_max_pages' 'overview' 'Projects (active)' 'active project' 'search_notes' 'Grep' 'raw_sources/'; do
    grep -Fq -- "$needle" "$TMP_TEST_DIR/query.txt" || { echo "missing: $needle" >&2; return 1; }
  done
  grep -Fqi -- 'archive' "$TMP_TEST_DIR/query.txt"
}

@test "037 index-first: extended frontmatter documents description as required-from-now-on and the four distill layers" {
  grep -Fq -- 'required on every page created from now on' "$SKELETON/CLAUDE.md"
  # whitespace-normalized: the phrase may legitimately wrap across prose lines.
  tr '\n' ' ' < "$SKELETON/CLAUDE.md" | grep -Fq -- 'never run a distillation pass'
  for layer in 'Full note' 'Bolded' 'Highlighted' 'Executive summary'; do
    grep -Fq -- "$layer" "$SKELETON/CLAUDE.md" || { echo "missing distill layer: $layer" >&2; return 1; }
  done
}

@test "037 index-first: Intermediate packets (D10) lists the five values, natural type, no packets/ dir, ## Packets" {
  _canon_extract '## Intermediate packets' "$SKELETON/CLAUDE.md" > "$TMP_TEST_DIR/d10.txt"
  for v in 'distilled-note' 'outtake' 'wip' 'deliverable' 'external'; do
    grep -Fq -- "$v" "$TMP_TEST_DIR/d10.txt" || { echo "missing: $v" >&2; return 1; }
  done
  grep -Fqi -- 'natural type' "$TMP_TEST_DIR/d10.txt"
  grep -Fqi -- 'never create a `packets/` directory' "$TMP_TEST_DIR/d10.txt"
  grep -Fq -- '## Packets' "$TMP_TEST_DIR/d10.txt"
  grep -Fq -- 'packets reused' "$SKELETON/CLAUDE.md"
}

@test "037 favorite problems: skeleton has no favorite-problems file outside prose (never pre-seeded)" {
  run find "$SKELETON/wiki" -iname 'favorite-problems*'
  [ -z "$output" ]
}

@test "037 favorite problems: capture filter (D7) names candidate, ask the human, two, problems:, project:" {
  _canon_extract '## Operation: ingest' "$SKELETON/CLAUDE.md" > "$TMP_TEST_DIR/ingest.txt"
  for needle in 'candidate' 'ask the human' 'two' 'problems:' 'project:'; do
    grep -Fqi -- "$needle" "$TMP_TEST_DIR/ingest.txt" || { echo "missing: $needle" >&2; return 1; }
  done
}

@test "037 favorite problems: Favorite problems (D11) names the on-demand rule, fp- slugs, the cap and problem_unfed" {
  _canon_extract '## Favorite problems' "$SKELETON/CLAUDE.md" > "$TMP_TEST_DIR/d11.txt"
  grep -Fqi -- 'when the human declares' "$TMP_TEST_DIR/d11.txt"
  grep -Fqi -- 'never pre-created' "$TMP_TEST_DIR/d11.txt"
  grep -Fq -- 'fp-' "$TMP_TEST_DIR/d11.txt"
  grep -Fqi -- 'twelve' "$TMP_TEST_DIR/d11.txt"
  grep -Fq -- 'problem_unfed' "$TMP_TEST_DIR/d11.txt"
}

@test "037 archive candidates: monthly review (D5) names archive_candidate, at most three, evidence, and defers to project close" {
  _canon_extract '## Operation: monthly review' "$SKELETON/CLAUDE.md" > "$TMP_TEST_DIR/d5.txt"
  tr '\n' ' ' < "$TMP_TEST_DIR/d5.txt" | tr -s ' ' > "$TMP_TEST_DIR/d5-flat.txt"
  grep -Fq -- 'archive_candidate' "$TMP_TEST_DIR/d5-flat.txt"
  grep -Fqi -- 'at most three' "$TMP_TEST_DIR/d5-flat.txt"
  grep -Fqi -- 'evidence' "$TMP_TEST_DIR/d5-flat.txt"
  grep -Fq -- 'Decisional (the human)' "$TMP_TEST_DIR/d5-flat.txt"
  grep -Fq -- 'Operation: project close' "$TMP_TEST_DIR/d5-flat.txt"
  grep -Fqi -- 'never move the file directly' "$TMP_TEST_DIR/d5-flat.txt"
}

@test "037 index-first: all eight templates carry description:, summary.md keeps distill:1 and the commented layer 2-3 sections" {
  for t in entity concept comparison overview synthesis summary entity-project overview-area; do
    grep -q '^description: ' "$SKELETON/_templates/$t.md" || { echo "missing description: in $t.md" >&2; return 1; }
  done
  grep -q '^distill: 1' "$SKELETON/_templates/summary.md"
  grep -Fq -- '## Highlights' "$SKELETON/_templates/summary.md"
  grep -Fq -- '## Core' "$SKELETON/_templates/summary.md"
}
