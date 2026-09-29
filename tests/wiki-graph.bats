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

# ── 037 core ──────────────────────────────────────────────────────────────────
# contracts/graph-findings-extension.md — PARA columns, new edges, F1-F5,
# packets/policy inputs (packets.json/policy.json land in T026/T010-state).
# vault-graph-para oracle: tests/fixtures/vault-graph-para/README.md.

_setup_para() {
  PARA_VAULT="$TMP_TEST_DIR/para-vault"
  cp -R "$REPO_ROOT/tests/fixtures/vault-graph-para" "$PARA_VAULT"
  cat > "$TMP_TEST_DIR/para-agent.yml" <<'YML'
vault: {enabled: true, wiki_graph: {enabled: true}}
YML
  PARA_AGENT_YML="$TMP_TEST_DIR/para-agent.yml"
  export WIKI_GRAPH_VAULT_DIR="$PARA_VAULT"
  export WIKI_GRAPH_STATE_FILE="$TMP_TEST_DIR/para-wiki-graph.json"
  export WIKI_GRAPH_LOCK="$TMP_TEST_DIR/.para-wiki-graph.lock"
  export WIKI_GRAPH_TODAY="2030-06-15"
}

_para_count() { jq -r ".counts.$1" "$TMP_TEST_DIR/para-wiki-graph.json"; }
_para_findings() { jq -rc '.findings[] | [.kind,.page,.detail] | @tsv' "$PARA_VAULT/.graph/findings.json"; }
_para_node() { jq -c --arg id "$1" '.nodes[] | select(.id==$id)' "$PARA_VAULT/.graph/graph.json"; }

@test "037 core: golden 014 fixture is byte-identical to the golden and all 12 new counts are 0" {
  wiki_graph_run "$AGENT_YML"
  run jq -S '{findings: .findings}' "$VAULT/.graph/findings.json"
  local got="$output"
  local want; want=$(jq -S '{findings: .findings}' "$REPO_ROOT/tests/fixtures/vault-graph.findings.golden.json")
  [ "$got" = "$want" ]
  for c in project_incomplete project_overdue review_due pending_ingest description_missing \
           problem_unfed archive_candidate schema_delta_pending packets para_project para_area para_archive; do
    [ "$(_count "$c")" -eq 0 ]
  done
}

@test "037 core: F1-F5 frontmatter violations present with their page" {
  _setup_para
  wiki_graph_run "$PARA_AGENT_YML"
  run _para_findings
  [[ "$output" == *$'frontmatter_violation\tentities/proj-badpara\tpara: invalid '\''projet'\'''* ]]
  [[ "$output" == *$'frontmatter_violation\tconcepts/packet-bad\tpacket: invalid '\''nope'\'''* ]]
}

@test "037 core: project_incomplete lists only the missing fields, in order" {
  _setup_para
  wiki_graph_run "$PARA_AGENT_YML"
  [ "$(_para_count project_incomplete)" -eq 1 ]
  run _para_findings
  [[ "$output" == *$'project_incomplete\tentities/proj-incomplete\tmissing: goal,next_action'* ]]
}

@test "037 core: para: archive is excluded from orphan and stale (suppression)" {
  _setup_para
  touch -d '2030-07-01' "$PARA_VAULT/raw_sources/articles/archived-source.md" 2>/dev/null \
    || touch -t 203007010000 "$PARA_VAULT/raw_sources/articles/archived-source.md"
  wiki_graph_run "$PARA_AGENT_YML"
  run _para_findings
  [[ "$output" != *$'orphan\tentities/proj-archived'* ]]
  [[ "$output" != *$'stale\tentities/proj-archived'* ]]
}

@test "037 core: graph.json nodes carry the new PARA fields, para normalized to resource when absent" {
  # golden fixture 014's alpha must still carry its tags (contract 037 closes this
  # drift) — checked FIRST, before _setup_para reassigns WIKI_GRAPH_VAULT_DIR etc.
  wiki_graph_run "$AGENT_YML"
  run jq -c '.nodes[] | select(.id=="summaries/alpha") | .tags' "$VAULT/.graph/graph.json"
  [ "$output" = '["demo"]' ]

  _setup_para
  wiki_graph_run "$PARA_AGENT_YML"
  run bash -c "_para_node() { jq -c --arg id \"\$1\" '.nodes[] | select(.id==\$id)' '$PARA_VAULT/.graph/graph.json'; }; _para_node entities/proj-active"
  [[ "$output" == *'"para":"project"'* ]]
  [[ "$output" == *'"due":"2030-08-01"'* ]]
  [[ "$output" == *'"tags":["demo"]'* ]]
  run bash -c "_para_node() { jq -c --arg id \"\$1\" '.nodes[] | select(.id==\$id)' '$PARA_VAULT/.graph/graph.json'; }; _para_node concepts/area-note"
  [[ "$output" == *'"para":"resource"'* ]]
}

@test "037 core: related edges from project:/area:/problems: — backlinks reach the target" {
  _setup_para
  wiki_graph_run "$PARA_AGENT_YML"
  # M5 (quickstart.md §4): a project:/area: edge emitted as kind wikilink instead of
  # related would still populate backlinks.json identically (both kinds count as
  # backlinks) — only graph.json's raw edge kind exposes the mutation. Assert it directly.
  run jq -r '.edges[] | select(.from=="summaries/note-proj-active" and .to=="entities/proj-active") | .kind' \
    "$PARA_VAULT/.graph/graph.json"
  [ "$output" = "related" ]
  run jq -r '.edges[] | select(.from=="concepts/area-note" and .to=="overviews/area-main") | .kind' \
    "$PARA_VAULT/.graph/graph.json"
  [ "$output" = "related" ]
  run jq -r '.pages["entities/proj-active"].backlinks[]' "$PARA_VAULT/.graph/backlinks.json"
  [[ "$output" == *"summaries/note-proj-active"* ]]
  run jq -r '.pages["overviews/area-main"].backlinks[]' "$PARA_VAULT/.graph/backlinks.json"
  [[ "$output" == *"concepts/area-note"* ]]
  run jq -r '.pages["synthesis/favorite-problems"].backlinks[]' "$PARA_VAULT/.graph/backlinks.json"
  [[ "$output" == *"concepts/problem-fp1-fed"* ]]
  [[ "$output" == *"concepts/problem-fp9-ref"* ]]
}

@test "037 core: project: pointing at a missing page produces broken_link" {
  _setup_para
  wiki_graph_run "$PARA_AGENT_YML"
  run _para_findings
  [[ "$output" == *$'broken_link\tsummaries/dangling-project\tentities/no-existe'* ]]
}

@test "037 core: problems: [fp-N] with no favorite-problems page produces no edge, no finding" {
  cp -R "$REPO_ROOT/tests/fixtures/vault-graph" "$TMP_TEST_DIR/nofp-vault"
  printf -- '---\ntitle: "T"\ntype: concept\nstatus: active\ncreated: 2026-06-01\nupdated: 2026-06-01\nproblems: [fp-9]\n---\nbody\n' \
    > "$TMP_TEST_DIR/nofp-vault/wiki/concepts/nofp.md"
  WIKI_GRAPH_VAULT_DIR="$TMP_TEST_DIR/nofp-vault" WIKI_GRAPH_STATE_FILE="$TMP_TEST_DIR/nofp.json" \
    WIKI_GRAPH_LOCK="$TMP_TEST_DIR/.nofp.lock" wiki_graph_run "$AGENT_YML"
  run jq -r '.edges[] | select(.from=="concepts/nofp")' "$TMP_TEST_DIR/nofp-vault/.graph/graph.json"
  [ -z "$output" ]
  # the page is still not in index.md (unrelated index_drift finding is expected);
  # only assert there's no problems/favorite-problems related finding for it
  run jq -rc '.findings[] | select(.page=="concepts/nofp" and (.detail | test("problem"; "i")))' \
    "$TMP_TEST_DIR/nofp-vault/.graph/findings.json"
  [ -z "$output" ]
}

@test "037 core: problems: [fp-9] with the page present but the entry absent — edge yes, finding no" {
  _setup_para
  wiki_graph_run "$PARA_AGENT_YML"
  run jq -r '.edges[] | select(.from=="concepts/problem-fp9-ref" and .to=="synthesis/favorite-problems") | .kind' \
    "$PARA_VAULT/.graph/graph.json"
  [ "$output" = "related" ]
  # the page is otherwise orphan by design (nothing links TO it) — only assert
  # there's no problems/favorite-problems-related finding for it
  run jq -rc '.findings[] | select(.page=="concepts/problem-fp9-ref" and (.detail | test("problem"; "i")))' \
    "$PARA_VAULT/.graph/findings.json"
  [ -z "$output" ]
}

@test "037 core: positional integrity — type/status of every node match the golden and the para fixture design" {
  wiki_graph_run "$AGENT_YML"
  run jq -r '.nodes[] | select(.id=="summaries/alpha") | [.type,.status] | @tsv' "$VAULT/.graph/graph.json"
  [ "$output" = $'summary\tactive' ]
  _setup_para
  wiki_graph_run "$PARA_AGENT_YML"
  run jq -r '.nodes[] | select(.id=="entities/proj-active") | [.type,.status] | @tsv' "$PARA_VAULT/.graph/graph.json"
  [ "$output" = $'entity\tactive' ]
  run jq -r '.nodes[] | select(.id=="entities/proj-badpara") | [.type,.status] | @tsv' "$PARA_VAULT/.graph/graph.json"
  [ "$output" = $'entity\tdraft' ]
}

@test "037 core: policy.json is always written, with defaults 7/30/90/14/30/300" {
  wiki_graph_run "$AGENT_YML"
  [ -f "$VAULT/.graph/policy.json" ]
  run jq -c '{review, archive, thresholds}' "$VAULT/.graph/policy.json"
  [ "$output" = '{"review":{"project_days":7,"area_days":30},"archive":{"candidate_days":90},"thresholds":{"delta_pending_days":14,"problem_unfed_days":30,"index_first_max_pages":300}}' ]
  run jq -c '.collection' "$VAULT/.graph/policy.json"
  [ "$output" = '{"layout":"none","migration":"n/a"}' ]
}

@test "037 core: policy.json honors agent.yml overrides and env seams; invalid value WARNs by key, never the value" {
  cat > "$TMP_TEST_DIR/agent2.yml" <<'YML'
vault: {enabled: true, wiki_graph: {enabled: true}, review: {project_days: 14}, archive: {candidate_days: 45}}
YML
  wiki_graph_run "$TMP_TEST_DIR/agent2.yml"
  run jq -c '.review, .archive' "$VAULT/.graph/policy.json"
  [ "$(echo "$output" | sed -n 1p)" = '{"project_days":14,"area_days":30}' ]
  [ "$(echo "$output" | sed -n 2p)" = '{"candidate_days":45}' ]

  WIKI_GRAPH_ARCHIVE_CANDIDATE_DAYS=1 wiki_graph_run "$AGENT_YML"
  run jq -r '.archive.candidate_days' "$VAULT/.graph/policy.json"
  [ "$output" = "1" ]

  cat > "$TMP_TEST_DIR/agent3.yml" <<'YML'
vault: {enabled: true, wiki_graph: {enabled: true}, review: {project_days: abc}}
YML
  run wiki_graph_run "$TMP_TEST_DIR/agent3.yml"
  [[ "$output" == *"WARN"* ]]
  [[ "$output" == *"vault.review.project_days"* ]]
  [[ "$output" != *"abc"* ]]
  run jq -r '.review.project_days' "$VAULT/.graph/policy.json"
  [ "$output" = "7" ]
}

@test "037 core: WIKI_GRAPH_TODAY is accepted as a seam (2030-01-01 changes nothing structural)" {
  _setup_para
  export WIKI_GRAPH_TODAY="2030-01-01"
  run wiki_graph_run "$PARA_AGENT_YML"
  [ "$status" -eq 0 ]
  [ "$(_para_count nodes)" -eq 21 ]
  [ "$(_para_count broken_links)" -eq 1 ]
  # 3, not 2: F1 (proj-badpara) + F2 (packet-bad) + F6 (fp-3 is not a question,
  # date-independent -- added by T028).
  [ "$(_para_count frontmatter_violations)" -eq 3 ]
}

# ── 037 review queue ────────────────────────────────────────────────────────
# contracts/graph-findings-extension.md §3-§4 — review_due/project_overdue/
# pending_ingest, TODAY-driven, deterministic. T018/T019.

@test "037 review queue: review_due — overdue next_review, missing, current and archived excluded" {
  _setup_para
  wiki_graph_run "$PARA_AGENT_YML"
  run _para_findings
  [[ "$output" == *$'review_due\tentities/proj-overdue\tnext_review: 2030-06-01 (14 days)'* ]]
  [[ "$output" == *$'review_due\tentities/proj-no-review\tnext_review: missing'* ]]
  [[ "$output" != *$'review_due\tentities/proj-active'* ]]
  [[ "$output" != *$'review_due\tentities/proj-archived'* ]]
  [ "$(_para_count review_due)" -eq 2 ]
}

@test "037 review queue: project_overdue — overdue due, future due, archive excluded, malformed gives only F4" {
  _setup_para
  cat > "$PARA_VAULT/wiki/entities/proj-malformed-due.md" <<'MD'
---
title: "Malformed Due Project"
type: entity
para: project
status: active
created: 2030-01-01
updated: 2030-01-01
due: not-a-date
---
Body.
MD
  wiki_graph_run "$PARA_AGENT_YML"
  run _para_findings
  [[ "$output" == *$'project_overdue\tentities/proj-overdue\tdue: 2030-05-01 (45 days)'* ]]
  [[ "$output" != *$'project_overdue\tentities/proj-active'* ]]
  [[ "$output" != *$'project_overdue\tentities/proj-archived'* ]]
  [[ "$output" != *$'project_overdue\tentities/proj-malformed-due'* ]]
  [[ "$output" == *$'frontmatter_violation\tentities/proj-malformed-due\tdue: malformed '\''not-a-date'\'''* ]]
  [ "$(_para_count project_overdue)" -eq 1 ]
}

@test "037 review queue: pending_ingest — uncited raw flagged, cited and clip-less raw excluded" {
  _setup_para
  wiki_graph_run "$PARA_AGENT_YML"
  run _para_findings
  [[ "$output" == *$'pending_ingest\traw_sources/articles/uncited.md\tno summary cites this source (clipped: 2030-06-01)'* ]]
  [[ "$output" != *$'pending_ingest\traw_sources/articles/cited.md'* ]]
  [[ "$output" != *$'pending_ingest\traw_sources/articles/archived-source.md'* ]]
  [ "$(_para_count pending_ingest)" -eq 1 ]
}

@test "037 review queue: pending_ingest is 0 and last_status stays ok when raw_sources/ is absent" {
  _setup_para
  rm -rf "$PARA_VAULT/raw_sources"
  wiki_graph_run "$PARA_AGENT_YML"
  [ "$(jq -r '.last_status' "$TMP_TEST_DIR/para-wiki-graph.json")" = "ok" ]
  [ "$(_para_count pending_ingest)" -eq 0 ]
}

@test "037 review queue: determinism — same TODAY twice yields byte-identical findings.json" {
  _setup_para
  wiki_graph_run "$PARA_AGENT_YML"
  local first; first=$(jq -S '.findings' "$PARA_VAULT/.graph/findings.json")
  wiki_graph_run "$PARA_AGENT_YML"
  local second; second=$(jq -S '.findings' "$PARA_VAULT/.graph/findings.json")
  [ "$first" = "$second" ]
}

@test "037 review queue: TODAY=2030-01-01 — review_due/project_overdue at 0 except the date-independent missing case" {
  _setup_para
  export WIKI_GRAPH_TODAY="2030-01-01"
  wiki_graph_run "$PARA_AGENT_YML"
  [ "$(_para_count project_overdue)" -eq 0 ]
  [ "$(_para_count review_due)" -eq 1 ]
  run _para_findings
  [[ "$output" == *$'review_due\tentities/proj-no-review\tnext_review: missing'* ]]
}

@test "037 review queue: state counts match findings.json by kind" {
  _setup_para
  wiki_graph_run "$PARA_AGENT_YML"
  local kind from_state from_findings
  for kind in review_due project_overdue pending_ingest; do
    from_state=$(_para_count "$kind")
    from_findings=$(jq --arg k "$kind" '[.findings[] | select(.kind==$k)] | length' "$PARA_VAULT/.graph/findings.json")
    [ "$from_state" -eq "$from_findings" ]
  done
}

@test "037 review queue: .graph/ still carries no .md files, policy.json present alongside the queue" {
  _setup_para
  wiki_graph_run "$PARA_AGENT_YML"
  run find "$PARA_VAULT/.graph" -name '*.md'
  [ -z "$output" ]
  [ -f "$PARA_VAULT/.graph/policy.json" ]
}

# ── 037 description ──────────────────────────────────────────────────────────
# contracts/graph-findings-extension.md §4 (description_missing) — DELTA_DATE
# resolution from the _templates/.schema-updates-0.27.0.applied marker. T023/T024.
# Fixture marker: `deposited: 2030-05-01`.

@test "037 description: para-declared page without description reports 'para: <v>', regardless of created date" {
  _setup_para
  wiki_graph_run "$PARA_AGENT_YML"
  run _para_findings
  [[ "$output" == *$'description_missing\tentities/proj-nodesc\tpara: project'* ]]
  [[ "$output" == *$'description_missing\tentities/proj-badpara\tpara: projet'* ]]
}

@test "037 description: a new undescribed page with no para reports via the created-vs-delta date" {
  _setup_para
  wiki_graph_run "$PARA_AGENT_YML"
  run _para_findings
  [[ "$output" == *$'description_missing\tconcepts/new-undescribed\tcreated: 2030-06-01 >= delta 2030-05-01'* ]]
}

@test "037 description: a preexisting undescribed page with no para and created before the delta is not reported" {
  _setup_para
  wiki_graph_run "$PARA_AGENT_YML"
  run _para_findings
  [[ "$output" != *$'description_missing\tsummaries/note-proj-active'* ]]
  [ "$(_para_count description_missing)" -eq 3 ]
}

@test "037 description: without the delta marker, only para-declared pages report — none by created date" {
  _setup_para
  rm -f "$PARA_VAULT/_templates/.schema-updates-0.27.0.applied"
  wiki_graph_run "$PARA_AGENT_YML"
  run _para_findings
  [[ "$output" != *$'description_missing\tconcepts/new-undescribed'* ]]
  [[ "$output" == *$'description_missing\tentities/proj-nodesc'* ]]
  [[ "$output" == *$'description_missing\tentities/proj-badpara'* ]]
  [ "$(_para_count description_missing)" -eq 2 ]
}

@test "037 description: a marker that exists but does not parse falls back to its mtime" {
  _setup_para
  : > "$PARA_VAULT/_templates/.schema-updates-0.27.0.applied"
  touch -d '2030-01-15' "$PARA_VAULT/_templates/.schema-updates-0.27.0.applied" 2>/dev/null \
    || touch -t 203001150000 "$PARA_VAULT/_templates/.schema-updates-0.27.0.applied"
  wiki_graph_run "$PARA_AGENT_YML"
  run _para_findings
  [[ "$output" == *$'description_missing\tconcepts/new-undescribed\tcreated: 2030-06-01 >= delta 2030-01-15'* ]]
  [[ "$output" != *$'description_missing\tsummaries/note-proj-active'* ]]
}

@test "037 description: WIKI_GRAPH_DELTA_PENDING_DAYS does not affect this kind" {
  _setup_para
  WIKI_GRAPH_DELTA_PENDING_DAYS=1 wiki_graph_run "$PARA_AGENT_YML"
  [ "$(_para_count description_missing)" -eq 3 ]
}

# ── 037 packets ──────────────────────────────────────────────────────────────
# contracts/graph-findings-extension.md §5 — packets.json, the fifth atomic
# artifact. T025/T026.

@test "037 packets: packets.json always exists — skeleton-clean vault yields schema 1, empty list" {
  wiki_graph_run "$AGENT_YML"
  [ -f "$VAULT/.graph/packets.json" ]
  run jq -c '{schema, packets}' "$VAULT/.graph/packets.json"
  [ "$output" = '{"schema":1,"packets":[]}' ]
  run jq -r '.generated_at' "$VAULT/.graph/packets.json"
  [ -n "$output" ]
  [ "$(_count packets)" -eq 0 ]
}

@test "037 packets: valid packet: pages are listed with their six fields, invalid packet: excluded" {
  _setup_para
  wiki_graph_run "$PARA_AGENT_YML"
  run jq -c '.packets' "$PARA_VAULT/.graph/packets.json"
  [ "$output" = '[{"id":"summaries/packet-good","type":"summary","packet":"wip","description":"A valid packet entry.","project":"","updated":"2030-06-05"}]' ]
  [ "$(_para_count packets)" -eq 1 ]
  run _para_findings
  [[ "$output" == *$'frontmatter_violation\tconcepts/packet-bad\tpacket: invalid '\''nope'\'''* ]]
}

@test "037 packets: multiple entries sort by updated desc, then id" {
  _setup_para
  cat > "$PARA_VAULT/wiki/concepts/packet-second.md" <<'MD'
---
title: "Second Packet"
type: concept
packet: outtake
created: 2030-06-01
updated: 2030-06-08
status: active
description: "A newer packet entry."
---
Body.
MD
  wiki_graph_run "$PARA_AGENT_YML"
  run jq -r '.packets[].id' "$PARA_VAULT/.graph/packets.json"
  [ "$output" = $'concepts/packet-second\nsummaries/packet-good' ]
}

# ── 037 favorite problems ────────────────────────────────────────────────────
# contracts/graph-findings-extension.md §2/§4 — CANON-F6 + problem_unfed. T027/T028.
# Fixture: fp-1/fp-2/fp-3 declared, fp-3 not phrased as a question; only fp-1 is
# fed (problem-fp1-fed.md, updated 2030-06-10); favorite-problems created 2030-01-01.

@test "037 favorite problems: fp-2/fp-3 are unfed, fp-1 (fed 5 days ago) is not" {
  _setup_para
  wiki_graph_run "$PARA_AGENT_YML"
  run _para_findings
  [[ "$output" == *$'problem_unfed\tsynthesis/favorite-problems\tfp-2: 165 days without entries (threshold 30)'* ]]
  [[ "$output" == *$'problem_unfed\tsynthesis/favorite-problems\tfp-3: 165 days without entries (threshold 30)'* ]]
  [[ "$output" != *'fp-1: '* ]]
  [ "$(_para_count problem_unfed)" -eq 2 ]
}

@test "037 favorite problems: fp-3 (not phrased as a question) produces CANON-F6" {
  _setup_para
  wiki_graph_run "$PARA_AGENT_YML"
  run _para_findings
  [[ "$output" == *$'frontmatter_violation\tsynthesis/favorite-problems\tfavorite_problems: fp-3 is not a question'* ]]
}

@test "037 favorite problems: WIKI_GRAPH_PROBLEM_UNFED_DAYS=400 clears the unfed findings" {
  _setup_para
  WIKI_GRAPH_PROBLEM_UNFED_DAYS=400 wiki_graph_run "$PARA_AGENT_YML"
  [ "$(_para_count problem_unfed)" -eq 0 ]
}

@test "037 favorite problems: no favorite-problems page (golden fixture) — 0 unfed, 0 F6" {
  wiki_graph_run "$AGENT_YML"
  [ "$(_count problem_unfed)" -eq 0 ]
  run jq -rc '.findings[] | select(.detail | test("favorite_problems"))' "$VAULT/.graph/findings.json"
  [ -z "$output" ]
}

@test "037 favorite problems: 13 entries produces the entry-count F6, not a per-entry one" {
  _setup_para
  cat > "$PARA_VAULT/wiki/synthesis/favorite-problems.md" <<'MD'
---
title: "Favorite problems"
type: synthesis
status: active
created: 2030-01-01
updated: 2030-06-10
description: "The favorite-problems catalog."
---
1. **fp-1** — How should PARA review cadences adapt over time?
2. **fp-2** — What signals indicate a project needs re-scoping?
3. **fp-3** — What is the retrieval latency budget?
4. **fp-4** — What is fp-4?
5. **fp-5** — What is fp-5?
6. **fp-6** — What is fp-6?
7. **fp-7** — What is fp-7?
8. **fp-8** — What is fp-8?
9. **fp-9** — What is fp-9?
10. **fp-10** — What is fp-10?
11. **fp-11** — What is fp-11?
12. **fp-12** — What is fp-12?
13. **fp-13** — What is fp-13?
MD
  wiki_graph_run "$PARA_AGENT_YML"
  run _para_findings
  [[ "$output" == *$'frontmatter_violation\tsynthesis/favorite-problems\tfavorite_problems: 13 entries (max 12)'* ]]
}

# ── 037 delta pending ────────────────────────────────────────────────────────
# contracts/graph-findings-extension.md §4 — schema_delta_pending: the delta
# self-denounces if never integrated. T029/T030.
# Fixture marker: `deposited: 2030-05-01`; CLAUDE.md lacks CANON-D1.

@test "037 delta pending: an un-integrated delta past the threshold reports itself" {
  _setup_para
  wiki_graph_run "$PARA_AGENT_YML"
  run _para_findings
  [[ "$output" == *$'schema_delta_pending\t_templates/schema-updates-0.27.0.md\tdeposited 2030-05-01 (45 days); vault CLAUDE.md lacks '\''## Actionability (PARA)'\'''* ]]
  [ "$(_para_count schema_delta_pending)" -eq 1 ]
}

@test "037 delta pending: once CANON-D1 lands in the vault CLAUDE.md, it clears" {
  _setup_para
  printf '\n## Actionability (PARA)\n\nIntegrated.\n' >> "$PARA_VAULT/CLAUDE.md"
  wiki_graph_run "$PARA_AGENT_YML"
  [ "$(_para_count schema_delta_pending)" -eq 0 ]
}

@test "037 delta pending: without the marker (delta never received) it never fires" {
  _setup_para
  rm -f "$PARA_VAULT/_templates/.schema-updates-0.27.0.applied"
  wiki_graph_run "$PARA_AGENT_YML"
  [ "$(_para_count schema_delta_pending)" -eq 0 ]
}

@test "037 delta pending: WIKI_GRAPH_DELTA_PENDING_DAYS=60 clears it (45 < 60)" {
  _setup_para
  WIKI_GRAPH_DELTA_PENDING_DAYS=60 wiki_graph_run "$PARA_AGENT_YML"
  [ "$(_para_count schema_delta_pending)" -eq 0 ]
}

@test "037 delta pending: TODAY=2030-05-10 (9 days since deposit) is under the default threshold" {
  _setup_para
  export WIKI_GRAPH_TODAY="2030-05-10"
  wiki_graph_run "$PARA_AGENT_YML"
  [ "$(_para_count schema_delta_pending)" -eq 0 ]
}

@test "037 delta pending: a real skeleton scaffold (no marker at all, static tree) never fires" {
  local sk="$TMP_TEST_DIR/skvault2"
  cp -R "$REPO_ROOT/modules/vault-skeleton" "$sk"
  WIKI_GRAPH_VAULT_DIR="$sk" WIKI_GRAPH_STATE_FILE="$TMP_TEST_DIR/sk2.json" \
    WIKI_GRAPH_LOCK="$TMP_TEST_DIR/.sk2.lock" wiki_graph_run "$AGENT_YML"
  [ "$(jq -r '.counts.schema_delta_pending' "$TMP_TEST_DIR/sk2.json")" -eq 0 ]
}

# ── 037 archive candidates ───────────────────────────────────────────────────
# contracts/graph-findings-extension.md §4 — archive_candidate, using the LOG
# enumeration from T019. T033/T034.

@test "037 archive candidates: a stale, backlink-less, never-mentioned page is a candidate" {
  _setup_para
  wiki_graph_run "$PARA_AGENT_YML"
  run _para_findings
  [[ "$output" == *$'archive_candidate\tconcepts/candidate-stale\tstatus: stale; backlinks: 0; last log mention: none'* ]]
}

@test "037 archive candidates: mentioned within the window is NOT a candidate; para: archive never is" {
  _setup_para
  wiki_graph_run "$PARA_AGENT_YML"
  run _para_findings
  [[ "$output" != *$'archive_candidate\tconcepts/candidate-mentioned'* ]]
  [[ "$output" != *$'archive_candidate\tentities/proj-archived'* ]]
  [ "$(_para_count archive_candidate)" -eq 1 ]
}

@test "037 archive candidates: a superseded page WITH a backlink is never a candidate" {
  _setup_para
  wiki_graph_run "$PARA_AGENT_YML"
  run _para_findings
  [[ "$output" != *$'archive_candidate\tconcepts/candidate-superseded-linked'* ]]
}

@test "037 archive candidates: WIKI_GRAPH_ARCHIVE_CANDIDATE_DAYS=1 makes the mentioned page a candidate too" {
  _setup_para
  WIKI_GRAPH_ARCHIVE_CANDIDATE_DAYS=1 wiki_graph_run "$PARA_AGENT_YML"
  run _para_findings
  [[ "$output" == *$'archive_candidate\tconcepts/candidate-mentioned\tstatus: stale; backlinks: 0; last log mention: 2030-06-10'* ]]
  [ "$(_para_count archive_candidate)" -eq 2 ]
}

@test "037 archive candidates: log.md absent — no error, the mention rule goes empty" {
  _setup_para
  rm -f "$PARA_VAULT/log.md"
  run wiki_graph_run "$PARA_AGENT_YML"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.last_status' "$TMP_TEST_DIR/para-wiki-graph.json")" = "ok" ]
  run _para_findings
  [[ "$output" == *$'archive_candidate\tconcepts/candidate-mentioned\tstatus: stale; backlinks: 0; last log mention: none'* ]]
}

@test "037 packets: .graph/ still holds no .md files alongside the fifth artifact" {
  wiki_graph_run "$AGENT_YML"
  run find "$VAULT/.graph" -name '*.md'
  [ -z "$output" ]
  for f in graph backlinks findings policy packets; do
    [ -f "$VAULT/.graph/$f.json" ] || { echo "missing: $f.json" >&2; return 1; }
  done
}
