#!/usr/bin/env bats
# Feature 014 (wiki-graph-rag) — the deterministic graph+lint runner
# (scripts/lib/wiki_graph.sh) against the vault-graph fixture oracle (SC-001)
# and the real skeleton (skeleton-clean → 0 findings, H3).
#
# Host-runnable, no Docker. flock-dependent assertions skip when flock is absent
# (macOS dev host) — the seam is covered in Linux CI (precedent: qmd-setup.bats).

load helper

setup() {
  load_lib wiki_graph
  setup_tmp_dir
  VAULT="$TMP_TEST_DIR/vault"
  cp -R "$REPO_ROOT/tests/fixtures/vault-graph" "$VAULT"
  cat > "$TMP_TEST_DIR/agent.yml" <<'YML'
vault: {enabled: true, wiki_graph: {enabled: true}}
YML
  AGENT_YML="$TMP_TEST_DIR/agent.yml"
  export WIKI_GRAPH_VAULT_DIR="$VAULT"
  export WIKI_GRAPH_STATE_FILE="$TMP_TEST_DIR/wiki-graph.json"
  export WIKI_GRAPH_LOCK="$TMP_TEST_DIR/.wiki-graph.lock"
  # stale (L4): make alpha's source newer than its updated: (2026-06-01).
  touch "$VAULT/raw_sources/articles/base.md"
}

teardown() { teardown_tmp_dir; }

_count() { jq -r ".counts.$1" "$TMP_TEST_DIR/wiki-graph.json"; }
_findings() { jq -rc '.findings[] | [.kind,.page,.detail] | @tsv' "$VAULT/.graph/findings.json"; }

# ── T005: parser / graph ─────────────────────────────────────────────────────
@test "wiki-graph: nodes are the 7 six-type pages (normalization is not a node)" {
  run wiki_graph_run "$AGENT_YML"; [ "$status" -eq 0 ]
  [ "$(_count nodes)" -eq 7 ]
  run jq -r '.nodes[].id' "$VAULT/.graph/graph.json"
  [[ "$output" == *"summaries/alpha"* ]]
  [[ "$output" == *"entities/acme"* ]]
  [[ "$output" != *"normalization/cencosud"* ]]
}

@test "wiki-graph: edges resolve wikilinks, related and sources; display/anchor stripped" {
  wiki_graph_run "$AGENT_YML"
  # A→C via [[concepts/widget|widget concept]] (display stripped)
  run jq -r '.edges[] | select(.from=="summaries/alpha" and .to=="concepts/widget") | .kind' "$VAULT/.graph/graph.json"
  [ "$output" = "wikilink" ]
  # E→O via related (quoted + [[..]] unwrapped, H4)
  run jq -r '.edges[] | select(.from=="entities/acme" and .to=="overviews/topic") | .kind' "$VAULT/.graph/graph.json"
  [ "$output" = "related" ]
  # A→base via sources
  run jq -r '.edges[] | select(.from=="summaries/alpha" and .kind=="source") | .to' "$VAULT/.graph/graph.json"
  [ "$output" = "raw_sources/articles/base.md" ]
}

@test "wiki-graph: backlinks and canonical_of are correct" {
  wiki_graph_run "$AGENT_YML"
  # acme has ≥1 backlink and canonical_of SENCOSUD (alias→entity)
  run jq -c '.pages["entities/acme"].canonical_of' "$VAULT/.graph/backlinks.json"
  [ "$output" = '["SENCOSUD"]' ]
  run jq -r '.pages["entities/acme"].backlinks | length' "$VAULT/.graph/backlinks.json"
  [ "$output" -ge 1 ]
}

# ── T006: findings — exact against the oracle (SC-001) ───────────────────────
@test "wiki-graph: exact finding counts match the fixture oracle" {
  wiki_graph_run "$AGENT_YML"
  [ "$(_count orphans)" -eq 1 ]
  [ "$(_count broken_links)" -eq 1 ]
  [ "$(_count frontmatter_violations)" -eq 1 ]
  [ "$(_count index_drift)" -eq 2 ]
  [ "$(_count stale)" -eq 1 ]
  [ "$(_count alias_occurrences)" -eq 1 ]
}

@test "wiki-graph: each finding points at the expected page" {
  wiki_graph_run "$AGENT_YML"
  run _findings
  [[ "$output" == *$'orphan\tconcepts/orphan-note'* ]]
  [[ "$output" == *$'broken_link\tcomparisons/broken\tconcepts/ghost-x'* ]]
  [[ "$output" == *$'frontmatter_violation\tsynthesis/badfm'* ]]
  [[ "$output" == *$'index_drift\tconcepts/ghostpage\tmissing_file'* ]]
  [[ "$output" == *$'index_drift\tconcepts/widget\tmissing_from_index'* ]]
  [[ "$output" == *$'stale\tsummaries/alpha'* ]]
  [[ "$output" == *$'alias_occurrence\toverviews/topic\tSENCOSUD -> Cencosud'* ]]
}

@test "wiki-graph: negative cases produce NO false positives (L5/L6/H3/H4)" {
  wiki_graph_run "$AGENT_YML"
  run _findings
  # L6: concepts/widget has title:"" but is NOT a frontmatter_violation
  [[ "$output" != *$'frontmatter_violation\tconcepts/widget'* ]]
  # L5: alias inside [[entities/acme|SENCOSUD]] does not add a 2nd occurrence
  [ "$(_count alias_occurrences)" -eq 1 ]
  # H4: related "[[overviews/topic]]" resolved (not a broken_link)
  [[ "$output" != *$'broken_link\tentities/acme'* ]]
}

@test "wiki-graph: skeleton-clean vault yields exactly 0 findings (H3)" {
  local sk="$TMP_TEST_DIR/skvault"
  cp -R "$REPO_ROOT/modules/vault-skeleton" "$sk"
  WIKI_GRAPH_VAULT_DIR="$sk" WIKI_GRAPH_STATE_FILE="$TMP_TEST_DIR/sk.json" \
    WIKI_GRAPH_LOCK="$TMP_TEST_DIR/.sk.lock" wiki_graph_run "$AGENT_YML"
  run jq -r '[.counts | to_entries[] | select(.key!="nodes" and .key!="edges") | .value] | add' "$TMP_TEST_DIR/sk.json"
  [ "$output" -eq 0 ]
  run jq -r '.counts.nodes' "$TMP_TEST_DIR/sk.json"
  [ "$output" -eq 0 ]
}

@test "wiki-graph: a malformed page is reported, not fatal — rest of wiki still parsed" {
  printf -- '---\nthis is not valid frontmatter\n---\nbody [[entities/acme]]\n' > "$VAULT/wiki/concepts/malformed.md"
  run wiki_graph_run "$AGENT_YML"; [ "$status" -eq 0 ]
  [ "$(jq -r .last_status "$TMP_TEST_DIR/wiki-graph.json")" = "ok" ]
  # the 7 originals + malformed = 8 nodes; the run did not abort
  [ "$(_count nodes)" -eq 8 ]
}

@test "wiki-graph: the runner never modifies wiki/ or raw_sources/" {
  local before after
  before=$(cd "$VAULT" && find wiki raw_sources -type f -exec shasum {} \; | sort | shasum)
  wiki_graph_run "$AGENT_YML"
  after=$(cd "$VAULT" && find wiki raw_sources -type f -exec shasum {} \; | sort | shasum)
  [ "$before" = "$after" ]
}

# ── T007: artifacts / state ──────────────────────────────────────────────────
@test "wiki-graph: last_status is ok (never 'locked'); state carries counts" {
  wiki_graph_run "$AGENT_YML"
  run jq -r '.last_status' "$TMP_TEST_DIR/wiki-graph.json"
  [ "$output" = "ok" ]
  run jq -r '.schema' "$TMP_TEST_DIR/wiki-graph.json"
  [ "$output" = "1" ]
}

@test "wiki-graph: missing vault → error state, no artifacts, exit 0" {
  WIKI_GRAPH_VAULT_DIR="$TMP_TEST_DIR/does-not-exist" \
    run wiki_graph_run "$AGENT_YML"
  [ "$status" -eq 0 ]
  [ "$(jq -r .last_status "$TMP_TEST_DIR/wiki-graph.json")" = "error" ]
  [ ! -d "$TMP_TEST_DIR/does-not-exist/.graph" ]
}

@test "wiki-graph: .graph/ holds ONLY non-.md artifacts (L1 invariant)" {
  wiki_graph_run "$AGENT_YML"
  run bash -c "find '$VAULT/.graph' -name '*.md' | wc -l | tr -d ' '"
  [ "$output" = "0" ]
  [ -f "$VAULT/.graph/graph.json" ]
  [ -f "$VAULT/.graph/backlinks.json" ]
  [ -f "$VAULT/.graph/findings.json" ]
}

@test "wiki-graph: artifacts are valid JSON (atomic write left no partial)" {
  wiki_graph_run "$AGENT_YML"
  run jq -e . "$VAULT/.graph/graph.json"; [ "$status" -eq 0 ]
  run jq -e . "$VAULT/.graph/backlinks.json"; [ "$status" -eq 0 ]
  run jq -e . "$VAULT/.graph/findings.json"; [ "$status" -eq 0 ]
  run bash -c "ls '$VAULT/.graph'/.wg.* 2>/dev/null | wc -l | tr -d ' '"
  [ "$output" = "0" ]
}

@test "wiki-graph: flock loser exits without writing state (91)" {
  command -v flock >/dev/null 2>&1 || skip "no flock(1) on host"
  # hold the lock, then a concurrent run must be a no-op (state untouched)
  wiki_graph_run "$AGENT_YML"   # seed a good state
  local good; good=$(jq -r .last_run "$TMP_TEST_DIR/wiki-graph.json")
  ( flock -n 9 || exit 1
    run wiki_graph_run "$AGENT_YML"
    [ "$status" -eq 0 ]
  ) 9>"$WIKI_GRAPH_LOCK"
  # state not overwritten by a locked loser (last_run unchanged in the held window)
  [ "$(jq -r .last_run "$TMP_TEST_DIR/wiki-graph.json")" = "$good" ]
}

# ── T009: normalization scanning ─────────────────────────────────────────────
@test "wiki-graph: alias scan honors word-boundary, fences and normalization/ exclusion" {
  # add a page with SENCOSUD as a substring (must NOT match) + a clean prose hit
  printf -- '---\ntitle: "N"\ntype: concept\nstatus: active\ncreated: 2026-06-01\nupdated: 2026-06-01\n---\nSENCOSUDESTE is a region.\n' > "$VAULT/wiki/concepts/nb.md"
  wiki_graph_run "$AGENT_YML"
  run _findings
  # substring SENCOSUDESTE does not count
  [[ "$output" != *$'alias_occurrence\tconcepts/nb'* ]]
  # normalization page's own body ("SENCOSUD" in cencosud.md) is excluded
  [[ "$output" != *$'alias_occurrence\tnormalization/cencosud'* ]]
}

@test "wiki-graph: match_case:true makes the alias case-sensitive" {
  # redefine the rule as case-sensitive; a lowercase 'sencosud' must not match
  cat > "$VAULT/wiki/normalization/cencosud.md" <<'EOF'
---
canonical: "Cencosud"
aliases: [SENCOSUD]
match_case: true
entity: "[[entities/acme]]"
---
rule
EOF
  printf -- '---\ntitle: "L"\ntype: concept\nstatus: active\ncreated: 2026-06-01\nupdated: 2026-06-01\n---\nthe lowercase sencosud should not match.\n' > "$VAULT/wiki/concepts/lc.md"
  wiki_graph_run "$AGENT_YML"
  run _findings
  [[ "$output" != *$'alias_occurrence\tconcepts/lc'* ]]
}

# ── T034: complexity guard (M2/R13/SC-006) ───────────────────────────────────
@test "wiki-graph: ~100 interconnected pages complete quickly, one graph produced" {
  local big="$TMP_TEST_DIR/big"; mkdir -p "$big/wiki/concepts"
  cat > "$big/agent.yml" <<'YML'
vault: {enabled: true, wiki_graph: {enabled: true}}
YML
  local i
  for i in $(seq 1 100); do
    local nxt=$(( (i % 100) + 1 ))
    printf -- '---\ntitle: "P%s"\ntype: concept\nstatus: active\ncreated: 2026-06-01\nupdated: 2026-06-01\n---\nlinks [[concepts/p%s]]\n' "$i" "$nxt" > "$big/wiki/concepts/p$i.md"
  done
  WIKI_GRAPH_VAULT_DIR="$big" WIKI_GRAPH_STATE_FILE="$TMP_TEST_DIR/big.json" \
    WIKI_GRAPH_LOCK="$TMP_TEST_DIR/.big.lock" run wiki_graph_run "$big/agent.yml"
  [ "$status" -eq 0 ]
  [ "$(jq -r .counts.nodes "$TMP_TEST_DIR/big.json")" -eq 100 ]
  # ring is fully linked → 0 orphans
  [ "$(jq -r .counts.orphans "$TMP_TEST_DIR/big.json")" -eq 0 ]
}

# ── 015 US3: host-backed TMPDIR + honest infra-error observability ────────────
@test "wiki-graph: routes TMPDIR to a host-backed scratch dir under the state dir (US3)" {
  # Stub the aggregation to record the TMPDIR the runner set before failing fast.
  export WG_SEEN_TMPDIR="$TMP_TEST_DIR/seen_tmpdir"
  _wg_aggregate() { printf '%s\n' "$TMPDIR" > "$WG_SEEN_TMPDIR"; return 2; }
  run wiki_graph_run "$AGENT_YML"
  [ "$status" -eq 0 ]                                   # fail-silent (exit 0)
  local seen; seen=$(cat "$WG_SEEN_TMPDIR")
  # host-backed scratch = "<state-dir>/tmp", NOT the tmpfs /tmp
  [ "$seen" = "$TMP_TEST_DIR/tmp" ]
}

@test "wiki-graph: aggregation failure records the REAL stderr (redacted) in state (US3/FR-007)" {
  # Simulate the ferrari ENOSPC that the old 2>/dev/null hid, with a secret in the
  # message to prove redaction (Principle V).
  _wg_aggregate() { echo "jq: error: No space left on device (sk-ant-oat01-LEAKSECRET123)" >&2; return 2; }
  run wiki_graph_run "$AGENT_YML"
  [ "$status" -eq 0 ]
  run jq -r '.error' "$TMP_TEST_DIR/wiki-graph.json"
  # real infra error surfaced (not the generic "jq aggregation failed") ...
  echo "$output" | grep -q 'No space left on device'
  # ... and the secret never reaches the state file
  echo "$output" | grep -q 'aggregation failed:' && ! echo "$output" | grep -q 'LEAKSECRET123'
}
