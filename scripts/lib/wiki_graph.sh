# shellcheck shell=bash
# Library: deterministic knowledge graph + structural lint over the vault wiki.
#
# Feature 014 (wiki-graph-rag). Derives a graph from the whole wiki/ base
# WITHOUT an LLM and WITHOUT ever editing the wiki:
#   - nodes  = pages under wiki/<6-types>/ (frontmatter attrs)
#   - edges  = body [[wikilinks]] + related: + sources: + alias→canonical
#   - findings = orphans, broken_links, frontmatter_violations, index_drift,
#                stale, alias_occurrences
# Artifacts land under <vault>/.graph/{graph,backlinks,findings,policy,packets}.json (JSON only,
# so backup_vault.sh's `*.md` filter and the qmd mask exclude them by
# construction). State file mirrors qmd-index.json. flock lives OUTSIDE the vault
# (Syncthing). Mirrors qmd_index.sh in shape; pure defs only (BASH_SOURCE-safe).
#
# awk extracts per-file (the strict frontmatter-subset parser IS the validator),
# jq aggregates globally. jq + awk are present in all three contexts (image,
# host tests, local). No new dependencies.

# Reuse the vault resolver (VAULT_ROOT_OVERRIDE-aware). Image path first, then
# repo-relative so host bats tests that source this file get vault_resolve_root.
# shellcheck source=/dev/null
if [ -f /opt/agent-admin/scripts/lib/backup_vault.sh ]; then
  source /opt/agent-admin/scripts/lib/backup_vault.sh
elif [ -f "$(dirname "${BASH_SOURCE[0]}")/backup_vault.sh" ]; then
  # shellcheck source=/dev/null
  source "$(dirname "${BASH_SOURCE[0]}")/backup_vault.sh"
fi

# 015 US3: shared observability helpers (redact_secrets + scratch_dir). Same
# image-first / repo-relative pattern. Fallback defs keep the runner working (and
# safe) if the mirror is ever missing — scratch_dir degrades to /tmp; redaction,
# when unavailable, is handled by callers omitting the sensitive dump rather than
# leaking (see qmd_index.sh). For wiki-graph the captured stderr is jq/awk output,
# so a passthrough fallback is acceptable here.
# shellcheck source=/dev/null
if [ -f /opt/agent-admin/scripts/lib/rag_obs.sh ]; then
  source /opt/agent-admin/scripts/lib/rag_obs.sh
elif [ -f "$(dirname "${BASH_SOURCE[0]}")/rag_obs.sh" ]; then
  # shellcheck source=/dev/null
  source "$(dirname "${BASH_SOURCE[0]}")/rag_obs.sh"
fi
command -v redact_secrets >/dev/null 2>&1 || redact_secrets() { cat; }
command -v scratch_dir    >/dev/null 2>&1 || scratch_dir() { printf '%s\n' "${TMPDIR:-/tmp}"; }

_wg_log() { echo "[wiki-graph] $*" >&2; }

# 0 iff vault.enabled AND vault.wiki_graph.enabled is not false (default true
# when the vault is on). Single gate shared by runner, manual action and cron.
wiki_graph_enabled() {
  local agent_yml="${1:-/workspace/agent.yml}"
  [ -f "$agent_yml" ] || return 1
  command -v yq >/dev/null 2>&1 || return 1
  local vault_en wg_en
  vault_en=$(yq -r '.vault.enabled // false' "$agent_yml" 2>/dev/null)
  [ "$vault_en" = "true" ] || return 1
  # default-true: only an explicit `false` disables it.
  wg_en=$(yq -r '.vault.wiki_graph.enabled' "$agent_yml" 2>/dev/null)
  [ "$wg_en" = "false" ] && return 1
  return 0
}

# Resolve the vault dir. Tests override via $WIKI_GRAPH_VAULT_DIR; local mode
# exports VAULT_ROOT_OVERRIDE; docker uses vault_resolve_root (agent.yml).
wiki_graph_vault_dir() {
  local agent_yml="${1:-/workspace/agent.yml}"
  if [ -n "${WIKI_GRAPH_VAULT_DIR:-}" ]; then printf '%s\n' "$WIKI_GRAPH_VAULT_DIR"; return 0; fi
  command -v vault_resolve_root >/dev/null 2>&1 || return 0
  vault_resolve_root "$agent_yml"
}

# Derived-artifact dir under the vault (JSON only). Test-overridable is implicit
# via the vault dir override.
wiki_graph_dir() { printf '%s/.graph\n' "$1"; }

# State file (freshness/counts). Test-overridable. Lives in scripts/heartbeat/,
# NEVER in the vault (Syncthing).
wiki_graph_state_file() {
  printf '%s\n' "${WIKI_GRAPH_STATE_FILE:-/workspace/scripts/heartbeat/wiki-graph.json}"
}

# Lock path — OUTSIDE the vault. Test-overridable.
wiki_graph_lock() {
  printf '%s\n' "${WIKI_GRAPH_LOCK:-/workspace/scripts/heartbeat/.wiki-graph.lock}"
}

# 037: the run's reference date (ISO, UTC), same zone as generated_at. Test
# seam WIKI_GRAPH_TODAY keeps every date-dependent finding deterministic
# (contracts/graph-findings-extension.md §1).
wiki_graph_today() {
  printf '%s\n' "${WIKI_GRAPH_TODAY:-$(date -u +%F)}"
}

# 037: _wg_config_days AGENT_YML YQ_PATH ENV_OVERRIDE DEFAULT KEY_NAME
# Integer 1..3650 (molde mcp_timeout_effective/channel_health_timeout_effective,
# setup.sh). ENV_OVERRIDE wins when set (test seam); otherwise reads YQ_PATH
# from AGENT_YML. Anything else (absent, non-numeric, out of range) degrades to
# DEFAULT with a WARN naming KEY_NAME -- never the value (contracts/
# graph-findings-extension.md §1).
_wg_config_days() {
  local agent_yml="$1" yq_path="$2" env_override="$3" default="$4" key_name="$5" v
  if [ -n "$env_override" ]; then
    v="$env_override"
  elif [ -f "$agent_yml" ] && command -v yq >/dev/null 2>&1; then
    v=$(yq -r "${yq_path} // \"\"" "$agent_yml" 2>/dev/null)
  else
    v=""
  fi
  if [[ "$v" =~ ^[0-9]{1,4}$ ]] && [ "$v" -ge 1 ] && [ "$v" -le 3650 ]; then
    printf '%s' "$v"
  else
    [ -n "$v" ] && echo "WARN: invalid value for $key_name, using default $default" >&2
    printf '%s' "$default"
  fi
}

# Atomic write of the state file: {schema,last_run,last_status,duration_ms,
# counts{...},error}. tmp+mv. No `locked` status (the flock loser writes nothing).
wiki_graph_write_state() {
  local state_file="$1" status="$2" duration_ms="$3" counts_json="$4" errmsg="${5:-}"
  local dir tmp now
  dir=$(dirname "$state_file")
  mkdir -p "$dir" 2>/dev/null || true
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  [ -z "$counts_json" ] && counts_json='{"nodes":0,"edges":0,"orphans":0,"broken_links":0,"frontmatter_violations":0,"index_drift":0,"stale":0,"alias_occurrences":0,"project_incomplete":0,"project_overdue":0,"review_due":0,"pending_ingest":0,"description_missing":0,"problem_unfed":0,"archive_candidate":0,"schema_delta_pending":0,"packets":0,"para_project":0,"para_area":0,"para_archive":0}'
  tmp=$(mktemp "$dir/.wiki-graph.json.XXXXXX") || return 0
  if jq -n --argjson schema 1 --arg run "$now" --arg status "$status" \
        --argjson dur "${duration_ms:-0}" --argjson counts "$counts_json" --arg err "$errmsg" \
        '{schema:$schema, last_run:$run, last_status:$status, duration_ms:$dur, counts:$counts, error:$err}' \
        > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$state_file" 2>/dev/null || rm -f "$tmp"
  else
    rm -f "$tmp"
  fi
}

# The structural awk program (stdin: all wiki/*.md via `find ... -print0 | xargs`).
# Emits TSV records to stdout. Reads VAULT to compute ids. See graph-artifacts.md.
_wg_structural_awk() {
  cat <<'AWK'
BEGIN {
  split("summary entity concept comparison overview synthesis", _t, " ");
  for (i in _t) VALIDTYPE[_t[i]] = 1;
  split("draft active stale superseded", _s, " ");
  for (i in _s) VALIDSTATUS[_s[i]] = 1;
  FS = "\n";
}
# strip surrounding single/double quotes
function unquote(v) {
  gsub(/^[ \t]+|[ \t]+$/, "", v);
  if (v ~ /^".*"$/) { v = substr(v, 2, length(v)-2); }
  else if (v ~ /^'.*'$/) { v = substr(v, 2, length(v)-2); }
  return v;
}
# unwrap a [[target|display]] / [[target#anchor]] token to bare target
function unwrap(v,   t) {
  t = v;
  if (t ~ /^\[\[.*\]\]$/) { t = substr(t, 3, length(t)-4); }
  sub(/\|.*$/, "", t);   # drop display
  sub(/#.*$/, "", t);    # drop anchor
  gsub(/^[ \t]+|[ \t]+$/, "", t);
  return t;
}
# parse a flow array "[a, b]" (or "[]") into arr[], return count
function parse_flow(v, arr,   inner, n, i, tok) {
  n = 0;
  gsub(/^[ \t]+|[ \t]+$/, "", v);
  if (v !~ /^\[.*\]$/) return 0;
  inner = substr(v, 2, length(v)-2);
  if (inner ~ /^[ \t]*$/) return 0;
  n = split(inner, tok, ",");
  for (i = 1; i <= n; i++) arr[i] = unquote(tok[i]);
  return n;
}
function reset() {
  curid=""; isnorm=0; infm=0; fmdone=0; fence=0;
  ftype=""; fstatus=""; fcreated=""; fupdated=""; title_present=0;
  canonical=""; matchcase="false"; entityid=""; naliases=0;
  nwl=0; nrel=0; nsrc=0; cbody="";
  delete al; delete wl; delete rel; delete src;
  curkey="";
  # 037: PARA + Second Brain frontmatter (contracts/graph-findings-extension.md §2)
  fpara=""; fdescription=""; fpacket=""; fdistill="";
  fdue=""; fnext_review=""; farchived=""; fgoal=""; fnext_action="";
  fproject=""; farea=""; nproblems=0; ntags=0;
  delete fproblems; delete ftags;
  nfp=0;   # 037: favorite-problems entry count (only meaningful on that page)
}
# join arr[1..n] with ';' (037: problems/tags travel as one TSV field)
function join_semi(arr, n,   i, s) {
  s = "";
  for (i = 1; i <= n; i++) { if (i > 1) s = s ";"; s = s arr[i]; }
  return s;
}
function compute_id(path,   p) {
  p = path;
  sub(/^.*\/wiki\//, "", p);
  sub(/\.md$/, "", p);
  return p;
}
function emit_v(id, reason) { print "V\t" id "\t" reason; }
function flush(   i, a) {
  if (curid == "") return;
  if (isnorm) {
    if (has_type_key) emit_v(curid, "normalization: type key not allowed");
    if (canonical == "") emit_v(curid, "normalization: canonical missing/empty");
    if (naliases == 0) emit_v(curid, "normalization: aliases missing/empty");
    for (i = 1; i <= naliases; i++) {
      print "AL\t" canonical "\t" al[i] "\t" matchcase "\t" entityid;
    }
    return;
  }
  gsub(/\t/, " ", fdescription); gsub(/\t/, " ", fgoal); gsub(/\t/, " ", fnext_action);
  print "N\t" curid "\t" ftype "\t" fstatus "\t" fcreated "\t" fupdated "\t" title_present \
    "\t" fpara "\t" (fdescription == "" ? 0 : 1) "\t" fpacket "\t" fdistill \
    "\t" fdue "\t" fnext_review "\t" farchived \
    "\t" (fgoal == "" ? 0 : 1) "\t" (fnext_action == "" ? 0 : 1) \
    "\t" fproject "\t" farea "\t" join_semi(fproblems, nproblems) "\t" join_semi(ftags, ntags) \
    "\t" fdescription;   # column 20, appended for packets.json (T026) -- raw text, not just _present
  if (!title_present) emit_v(curid, "title: key missing");
  if (ftype == "") emit_v(curid, "type: missing");
  else if (!(ftype in VALIDTYPE)) emit_v(curid, "type: invalid '" ftype "'");
  if (fstatus != "" && !(fstatus in VALIDSTATUS)) emit_v(curid, "status: invalid '" fstatus "'");
  # 037 F1-F5 (empty value = absent, molde status; contracts/graph-findings-extension.md §2)
  if (fpara != "" && fpara !~ /^(project|area|resource|archive)$/) emit_v(curid, "para: invalid '" fpara "'");
  if (fpacket != "" && fpacket !~ /^(distilled-note|outtake|wip|deliverable|external)$/) emit_v(curid, "packet: invalid '" fpacket "'");
  if (fdistill != "" && fdistill !~ /^[1-4]$/) emit_v(curid, "distill: invalid '" fdistill "'");
  if (fdue != "" && fdue !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) emit_v(curid, "due: malformed '" fdue "'");
  if (fnext_review != "" && fnext_review !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) emit_v(curid, "next_review: malformed '" fnext_review "'");
  if (farchived != "" && farchived !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) emit_v(curid, "archived: malformed '" farchived "'");
  else if (fpara == "archive" && farchived == "") emit_v(curid, "archived: missing");
  if (curid == "synthesis/favorite-problems" && nfp > 12) emit_v(curid, "favorite_problems: " nfp " entries (max 12)");
  for (i = 1; i <= nwl; i++) print "E\t" curid "\t" wl[i] "\twikilink";
  for (i = 1; i <= nrel; i++) print "E\t" curid "\t" rel[i] "\trelated";
  for (i = 1; i <= nsrc; i++) print "E\t" curid "\t" src[i] "\tsource";
  if (fproject != "") print "E\t" curid "\t" fproject "\trelated";
  if (farea != "") print "E\t" curid "\t" farea "\trelated";
  # problems_ref: distinct kind so jq can silently DROP it (no edge, no
  # finding) when synthesis/favorite-problems doesn't exist, unlike
  # project/area (which become broken_link when the target is missing).
  if (nproblems > 0) print "E\t" curid "\tsynthesis/favorite-problems\tproblems_ref";
  print "SRCN\t" curid "\t" fstatus "\t" fupdated;   # for stale (bash reads sources via E/source)
  bodytext[curid] = cbody;
}
FNR == 1 {
  flush();
  reset();
  curid = compute_id(FILENAME);
  if (curid ~ /^normalization\//) isnorm = 1;
  has_type_key = 0;
}
{
  line = $0;
  # frontmatter block: first '---' opens, next '---' closes
  if (!fmdone && FNR == 1 && line ~ /^---[ \t]*$/) { infm = 1; next; }
  if (infm && line ~ /^---[ \t]*$/) { infm = 0; fmdone = 1; next; }
  if (infm) {
    # key: value  (continuation dash-array items handled minimally)
    if (line ~ /^[ \t]*-[ \t]+/ && curkey != "") {
      val = line; sub(/^[ \t]*-[ \t]+/, "", val); val = unquote(val);
      if (curkey == "related") { rel[++nrel] = unwrap(val); }
      else if (curkey == "sources") { src[++nsrc] = unquote(val); }
      else if (curkey == "aliases") { al[++naliases] = val; }
      else if (curkey == "problems") { fproblems[++nproblems] = val; }
      else if (curkey == "tags") { ftags[++ntags] = val; }
      next;
    }
    if (line ~ /^[A-Za-z_]+[ \t]*:/) {
      key = line; sub(/[ \t]*:.*$/, "", key); gsub(/[ \t]/, "", key);
      rest = line; sub(/^[^:]*:[ \t]*/, "", rest);
      curkey = key;
      if (key == "type") { has_type_key = 1; ftype = unquote(rest); }
      else if (key == "status") { fstatus = unquote(rest); }
      else if (key == "created") { fcreated = unquote(rest); }
      else if (key == "updated") { fupdated = unquote(rest); }
      else if (key == "title") { title_present = 1; }
      else if (key == "canonical") { canonical = unquote(rest); }
      else if (key == "match_case") { matchcase = unquote(rest); }
      else if (key == "entity") { entityid = unwrap(unquote(rest)); }
      else if (key == "related") {
        n = parse_flow(rest, tmpa);
        for (i = 1; i <= n; i++) rel[++nrel] = unwrap(tmpa[i]);
      }
      else if (key == "sources") {
        n = parse_flow(rest, tmpa);
        for (i = 1; i <= n; i++) src[++nsrc] = tmpa[i];
      }
      else if (key == "aliases") {
        n = parse_flow(rest, tmpa);
        for (i = 1; i <= n; i++) al[++naliases] = tmpa[i];
      }
      else if (key == "para") { fpara = unquote(rest); }
      else if (key == "description") { fdescription = unquote(rest); }
      else if (key == "packet") { fpacket = unquote(rest); }
      else if (key == "distill") { fdistill = unquote(rest); }
      else if (key == "due") { fdue = unquote(rest); }
      else if (key == "next_review") { fnext_review = unquote(rest); }
      else if (key == "archived") { farchived = unquote(rest); }
      else if (key == "goal") { fgoal = unquote(rest); }
      else if (key == "next_action") { fnext_action = unquote(rest); }
      else if (key == "project") { fproject = unwrap(unquote(rest)); }
      else if (key == "area") { farea = unwrap(unquote(rest)); }
      else if (key == "problems") {
        n = parse_flow(rest, tmpa);
        for (i = 1; i <= n; i++) fproblems[++nproblems] = tmpa[i];
      }
      else if (key == "tags") {
        n = parse_flow(rest, tmpa);
        for (i = 1; i <= n; i++) ftags[++ntags] = tmpa[i];
      }
    }
    next;
  }
  # body: track fenced code blocks (``` toggles); skip fenced lines entirely
  if (line ~ /^[ \t]*```/) { fence = 1 - fence; next; }
  if (fence) next;
  # 037 CANON-F6: on synthesis/favorite-problems only, each numbered entry
  # "N. **fp-N** — <text>" is counted (favorite_problems: N entries, checked
  # against the max in flush()) and its text checked for question form (ends
  # in ? or opens with an interrogative word, ES/EN) -- non-questions emit F6
  # immediately, since that check needs no end-of-page total.
  if (curid == "synthesis/favorite-problems" && match(line, /^[0-9]+\. \*\*fp-[0-9]+\*\* /)) {
    fpslug = line;
    sub(/^[0-9]+\. \*\*/, "", fpslug);
    sub(/\*\*.*$/, "", fpslug);
    fptext = line;
    sub(/^[0-9]+\. \*\*fp-[0-9]+\*\*[ \t]*—[ \t]*/, "", fptext);
    gsub(/^[ \t]+|[ \t]+$/, "", fptext);
    nfp++;
    isq = 0;
    if (fptext ~ /\?[ \t]*$/) isq = 1;
    else if (fptext ~ /^(How|What|Why|When|Which|Cómo|Qué|Por qué|Cuándo|Cuál)/) isq = 1;
    print "FP\t" fpslug "\t" isq;
    if (!isq) emit_v(curid, "favorite_problems: " fpslug " is not a question");
  }
  # extract wikilinks as edges (before stripping)
  tmp = line;
  while (match(tmp, /\[\[[^]]*\]\]/)) {
    tok = substr(tmp, RSTART, RLENGTH);
    wl[++nwl] = unwrap(tok);
    tmp = substr(tmp, RSTART + RLENGTH);
  }
  # cleaned body for alias scan: remove wikilink tokens entirely
  cl = line;
  gsub(/\[\[[^]]*\]\]/, " ", cl);
  cbody = cbody " " cl;
}
END {
  flush();
  # alias occurrences: for each non-norm page body, each alias (word-boundary).
  for (id in bodytext) {
    b = bodytext[id];
    for (k = 1; k <= galias_n; k++) {
      target = galias[k]; canon = galias_canon[k]; mc = galias_mc[k];
      hay = b;
      # normalize non-alnum to spaces for word-boundary matching
      gsub(/[^A-Za-z0-9_]/, " ", hay);
      t = target;
      if (mc != "true") { hay = tolower(hay); t = tolower(t); }
      if (index(" " hay " ", " " t " ") > 0) {
        print "OCC\t" id "\t" target "\t" canon;
      }
    }
  }
}
AWK
}

# wiki_graph_run: the whole pipeline. flock-guarded, atomic, fail-silent (exit 0
# in batch contexts; honesty goes in the state file). Returns 0 always.
wiki_graph_run() {
  local agent_yml="${1:-/workspace/agent.yml}"
  wiki_graph_enabled "$agent_yml" || { _wg_log "disabled — skip"; return 0; }
  local vault_dir lock
  vault_dir=$(wiki_graph_vault_dir "$agent_yml")
  [ -n "$vault_dir" ] || { _wg_log "vault not resolvable — skip"; return 0; }
  lock=$(wiki_graph_lock)
  mkdir -p "$(dirname "$lock")" 2>/dev/null || true

  if command -v flock >/dev/null 2>&1; then
    local rc=0
    (
      if ! flock -n 9; then _wg_log "already running — skip"; exit 91; fi
      _wg_run_locked "$agent_yml" "$vault_dir"
    ) 9>"$lock" || rc=$?
    [ "$rc" -eq 91 ] && return 0
    return 0
  fi
  _wg_log "flock unavailable — running unlocked (dev degrade)"
  _wg_run_locked "$agent_yml" "$vault_dir"
  return 0
}

# Critical section. Runs under flock when available.
_wg_run_locked() {
  local agent_yml="$1" vault_dir="$2"
  local state_file graph_dir wiki_dir start_ms end_ms dur
  state_file=$(wiki_graph_state_file)
  graph_dir=$(wiki_graph_dir "$vault_dir")
  wiki_dir="$vault_dir/wiki"
  start_ms=$(_wg_now_ms)

  if [ ! -d "$vault_dir" ] || [ ! -d "$wiki_dir" ]; then
    _wg_log "vault/wiki dir missing ($vault_dir) — error state, artifacts untouched"
    wiki_graph_write_state "$state_file" "error" 0 "" "vault or wiki dir missing"
    return 0
  fi

  # 015 US3: route temporaries onto host-backed .state (the state dir lives under
  # /workspace, disk-backed) instead of the 100MB tmpfs /tmp, which bunx's qmd
  # package cache (~98MB) otherwise fills → ENOSPC for records/combined on a large
  # vault. Robust-by-design against a full /tmp.
  local scratch
  scratch=$(scratch_dir "$(dirname "$state_file")")
  export TMPDIR="$scratch" TMP="$scratch" TEMP="$scratch"

  local tmpd
  tmpd=$(mktemp -d "${TMPDIR:-/tmp}/wg.XXXXXX") || { wiki_graph_write_state "$state_file" "error" 0 "" "mktemp failed"; return 0; }

  # 1) structural pass (all wiki files) → records.tsv, with aliases fed back in.
  #    Two awk invocations: first collect aliases, then the full run with the
  #    alias table injected (galias_*), so OCC can be computed in END.
  local records="$tmpd/records.tsv" alias_tsv="$tmpd/aliases.tsv"
  # pass A: just alias declarations
  find "$wiki_dir" -type f -name '*.md' -print0 2>/dev/null \
    | LC_ALL=C sort -z \
    | xargs -0 awk -v VAULT="$vault_dir" "$(_wg_structural_awk)" 2>/dev/null > "$records" || true
  grep '^AL	' "$records" > "$alias_tsv" 2>/dev/null || true
  # pass B: re-run with aliases injected so OCC (END phase) can fire.
  if [ -s "$alias_tsv" ]; then
    local inject="$tmpd/inject.awk"
    _wg_alias_inject "$alias_tsv" > "$inject"
    find "$wiki_dir" -type f -name '*.md' -print0 2>/dev/null \
      | LC_ALL=C sort -z \
      | xargs -0 awk -v VAULT="$vault_dir" "$(cat "$inject"; _wg_structural_awk)" 2>/dev/null > "$records" || true
  fi

  # 2) index.md entries (exclude HTML comments, backticks, placeholders — H3).
  local idx_file="$tmpd/index_entries.txt"
  _wg_index_entries "$vault_dir/index.md" > "$idx_file" 2>/dev/null || true

  # 3) all wiki files as ids (for missing_file check) + node source list handled in jq.
  local allwiki="$tmpd/allwiki.txt"
  find "$wiki_dir" -type f -name '*.md' 2>/dev/null \
    | sed -e "s#^${wiki_dir}/##" -e 's#\.md$##' | LC_ALL=C sort > "$allwiki" || true

  # 4) stale ids (mtime of sources vs updated+1d) computed in bash → list.
  local stale_file="$tmpd/stale.txt"
  _wg_compute_stale "$vault_dir" "$records" > "$stale_file" 2>/dev/null || true

  # 4.5) 037: enumerations outside wiki/ (raw_sources/, log.md) — see
  # contracts/graph-findings-extension.md §3. Empty file, not error, when the
  # source dir/file is absent.
  local raw_file="$tmpd/raw.tsv" log_file="$tmpd/log.tsv"
  _wg_raw_entries "$vault_dir" > "$raw_file" 2>/dev/null || true
  _wg_log_entries "$vault_dir" > "$log_file" 2>/dev/null || true
  local delta_date; delta_date=$(_wg_delta_date "$vault_dir")
  local integrated=0
  grep -F -q -- '## Actionability (PARA)' "$vault_dir/CLAUDE.md" 2>/dev/null && integrated=1

  # config days computed HERE (not just below, next to policy.json) because
  # problem_unfed needs its threshold during aggregation itself; reused as-is
  # for policy.json further down so the WARN (on an invalid value) fires once.
  local review_project_days review_area_days archive_candidate_days
  local delta_pending_days problem_unfed_days index_first_max_pages
  review_project_days=$(_wg_config_days "$agent_yml" '.vault.review.project_days' "${WIKI_GRAPH_REVIEW_PROJECT_DAYS:-}" 7 "vault.review.project_days")
  review_area_days=$(_wg_config_days "$agent_yml" '.vault.review.area_days' "${WIKI_GRAPH_REVIEW_AREA_DAYS:-}" 30 "vault.review.area_days")
  archive_candidate_days=$(_wg_config_days "$agent_yml" '.vault.archive.candidate_days' "${WIKI_GRAPH_ARCHIVE_CANDIDATE_DAYS:-}" 90 "vault.archive.candidate_days")
  delta_pending_days=$(_wg_config_days "" "" "${WIKI_GRAPH_DELTA_PENDING_DAYS:-}" 14 "WIKI_GRAPH_DELTA_PENDING_DAYS")
  problem_unfed_days=$(_wg_config_days "" "" "${WIKI_GRAPH_PROBLEM_UNFED_DAYS:-}" 30 "WIKI_GRAPH_PROBLEM_UNFED_DAYS")
  index_first_max_pages=$(_wg_config_days "" "" "${WIKI_GRAPH_INDEX_FIRST_MAX_PAGES:-}" 300 "WIKI_GRAPH_INDEX_FIRST_MAX_PAGES")

  # 5) jq aggregation → combined.json
  local combined="$tmpd/combined.json" aggerr="$tmpd/agg.err"
  # 015 US3/FR-007: capture the real aggregation stderr (redacted) instead of
  # swallowing it with 2>/dev/null. The old generic "jq aggregation failed" hid an
  # ENOSPC "No space left on device" during the ferrari gate; fail-silent must
  # record the infra error, not eat it (refines Principle IV).
  if ! _wg_aggregate "$records" "$idx_file" "$allwiki" "$stale_file" "$vault_dir" "$(wiki_graph_today)" "$raw_file" "$log_file" "$delta_date" "$problem_unfed_days" "$integrated" "$delta_pending_days" "$archive_candidate_days" > "$combined" 2>"$aggerr"; then
    local emsg
    # Redact the WHOLE stream FIRST, then truncate (a boundary-straddling secret
    # anchor could otherwise leak the bare value — Principle V, defense in depth).
    emsg=$(redact_secrets < "$aggerr" 2>/dev/null | tr '\n' ' ' | tail -c 500)
    [ -n "$emsg" ] || emsg="unknown"
    _wg_log "aggregation failed — error state, artifacts untouched: $emsg"
    wiki_graph_write_state "$state_file" "error" 0 "" "aggregation failed: $emsg"
    rm -rf "$tmpd"
    return 0
  fi

  # 6) atomic writes of the artifacts under <vault>/.graph/
  mkdir -p "$graph_dir" 2>/dev/null || true
  local now; now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  _wg_atomic_write "$graph_dir/graph.json" \
    "$(jq -c --argjson s 1 --arg g "$now" --arg v "$vault_dir" '{schema:$s,generated_at:$g,vault:$v,nodes:.nodes,edges:.edges}' "$combined")"
  _wg_atomic_write "$graph_dir/backlinks.json" \
    "$(jq -c --argjson s 1 --arg g "$now" '{schema:$s,generated_at:$g,pages:.pages}' "$combined")"
  _wg_atomic_write "$graph_dir/findings.json" \
    "$(jq -c --argjson s 1 --arg g "$now" '{schema:$s,generated_at:$g,findings:.findings}' "$combined")"
  _wg_atomic_write "$graph_dir/packets.json" \
    "$(jq -c --argjson s 1 --arg g "$now" '{schema:$s,generated_at:$g,packets:.packets}' "$combined")"

  # policy.json: agent.yml cadences/thresholds + qmd collection layout, so the
  # vault schema can read them without a MCP call (data-model.md §6). Values
  # already resolved above (before aggregation), reused as-is here.

  # collection layout/migration: copy from qmd's own state file if present
  # (same scripts/heartbeat/ dir as ours); local mode's QMD_INDEX_STATE_FILE
  # is not exported to this runner, so absence just means "not indexed yet".
  local qmd_state coll_layout="none" coll_migration="n/a"
  qmd_state="$(dirname "$state_file")/qmd-index.json"
  if [ -f "$qmd_state" ]; then
    coll_layout=$(jq -r '.collection_layout // "none"' "$qmd_state" 2>/dev/null)
    coll_migration=$(jq -r '.migration // "n/a"' "$qmd_state" 2>/dev/null)
    [ -n "$coll_layout" ] || coll_layout="none"
    [ -n "$coll_migration" ] || coll_migration="n/a"
  fi
  _wg_atomic_write "$graph_dir/policy.json" \
    "$(jq -n --argjson s 1 --arg g "$now" \
          --argjson pd "$review_project_days" --argjson ad "$review_area_days" \
          --argjson cd "$archive_candidate_days" --argjson dpd "$delta_pending_days" \
          --argjson pud "$problem_unfed_days" --argjson ifmp "$index_first_max_pages" \
          --arg layout "$coll_layout" --arg migration "$coll_migration" \
          '{schema:$s, generated_at:$g,
            review:{project_days:$pd, area_days:$ad},
            archive:{candidate_days:$cd},
            thresholds:{delta_pending_days:$dpd, problem_unfed_days:$pud, index_first_max_pages:$ifmp},
            collection:{layout:$layout, migration:$migration}}')"

  # 7) state file with counts
  end_ms=$(_wg_now_ms); dur=$((end_ms - start_ms)); [ "$dur" -lt 0 ] && dur=0
  local counts; counts=$(jq -c '.counts' "$combined")
  wiki_graph_write_state "$state_file" "ok" "$dur" "$counts" ""
  _wg_log "ok — $(echo "$counts" | jq -c '.') "
  rm -rf "$tmpd"
  return 0
}

# emit a BEGIN block that seeds galias_* from the alias TSV (AL\tcanon\talias\tmc\tentity)
_wg_alias_inject() {
  local alias_tsv="$1"
  printf 'BEGIN {\n'
  local n=0 canon alias mc entity
  while IFS=$'\t' read -r tag canon alias mc entity; do
    [ "$tag" = "AL" ] || continue
    n=$((n + 1))
    # awk-escape single quotes/backslashes minimally; aliases are simple tokens
    printf '  galias[%d]="%s"; galias_canon[%d]="%s"; galias_mc[%d]="%s";\n' \
      "$n" "${alias//\"/\\\"}" "$n" "${canon//\"/\\\"}" "$n" "${mc//\"/\\\"}"
  done < "$alias_tsv"
  printf '  galias_n=%d;\n}\n' "$n"
}

# index.md entry extraction (H3): bullets `- [[type/slug]]` at list level,
# EXCLUDING HTML comments, backticked text and <...> placeholders.
_wg_index_entries() {
  local index_md="$1"
  [ -f "$index_md" ] || return 0
  awk '
    BEGIN { incomment = 0 }
    {
      line = $0;
      # strip whole-line and inline HTML comments
      while (match(line, /<!--.*-->/)) { line = substr(line,1,RSTART-1) substr(line,RSTART+RLENGTH); }
      if (incomment) { if (line ~ /-->/) { sub(/^.*-->/, "", line); incomment = 0 } else { next } }
      if (line ~ /<!--/) { sub(/<!--.*$/, "", line); incomment = 1 }
      # drop backticked spans
      gsub(/`[^`]*`/, " ", line);
      # only list bullets
      if (line !~ /^[ \t]*-[ \t]+/) next;
      # extract [[...]] tokens that are not placeholders (<...>)
      while (match(line, /\[\[[^]]*\]\]/)) {
        tok = substr(line, RSTART+2, RLENGTH-4);
        if (tok !~ /[<>]/) {
          sub(/\|.*$/, "", tok); sub(/#.*$/, "", tok);
          gsub(/^[ \t]+|[ \t]+$/, "", tok);
          if (tok != "") print tok;
        }
        line = substr(line, RSTART + RLENGTH);
      }
    }
  ' "$index_md" | LC_ALL=C sort -u
}

# 037: raw sources with a `clipped:` key (contracts/graph-findings-extension.md
# §3), for pending_ingest. Files without the key are not candidates at all (not
# even emitted) -- unclipped raw material is not "waiting to be ingested".
_wg_raw_entries() {
  local vault_dir="$1" raw_dir rel clipped
  raw_dir="$vault_dir/raw_sources"
  [ -d "$raw_dir" ] || return 0
  find "$raw_dir" -type f -name '*.md' 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
    rel=${f#"$vault_dir/"}
    clipped=$(awk '
      BEGIN { infm = 0 }
      FNR == 1 && /^---[ \t]*$/ { infm = 1; next }
      infm && /^---[ \t]*$/ { infm = 0; exit }
      infm && /^clipped[ \t]*:/ {
        v = $0; sub(/^clipped[ \t]*:[ \t]*/, "", v);
        gsub(/^[ \t]+|[ \t]+$/, "", v);
        if (v ~ /^".*"$/) v = substr(v, 2, length(v)-2);
        print v; exit
      }
    ' "$f")
    [ -n "$clipped" ] && printf 'RAW\t%s\t%s\n' "$rel" "$clipped"
  done
}

# 037: log.md entries, `## [YYYY-MM-DD] ...` headers + the [[wikilinks]]
# mentioned in that entry's body (contracts/graph-findings-extension.md §3).
# Consumed by archive_candidate (T034); built here since it is, like RAW, an
# enumeration outside wiki/ fed to _wg_aggregate as a --rawfile.
_wg_log_entries() {
  local vault_dir="$1" log_md
  log_md="$vault_dir/log.md"
  [ -f "$log_md" ] || return 0
  awk '
    BEGIN { date = "" }
    /^##[ \t]+\[[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\]/ {
      line = $0;
      match(line, /\[[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\]/);
      date = substr(line, RSTART+1, RLENGTH-2);
      next;
    }
    {
      if (date == "") next;
      line = $0;
      while (match(line, /\[\[[^]]*\]\]/)) {
        tok = substr(line, RSTART+2, RLENGTH-4);
        sub(/\|.*$/, "", tok); sub(/#.*$/, "", tok);
        gsub(/^[ \t]+|[ \t]+$/, "", tok);
        if (tok != "") print "LOG\t" date "\t" tok;
        line = substr(line, RSTART+RLENGTH);
      }
    }
  ' "$log_md"
}

# stale (informational, L4): status:active nodes whose source file mtime is
# newer than updated: + 1 day. Best-effort + portable; on any parse failure the
# node is simply not reported (no false positive).
_wg_compute_stale() {
  local vault_dir="$1" records="$2"
  # node -> status,updated  (from SRCN records) and node -> sources (E/source)
  local id status updated
  # iterate SRCN records
  grep '^SRCN	' "$records" 2>/dev/null | while IFS=$'\t' read -r _tag id status updated; do
    [ "$status" = "active" ] || continue
    [ -n "$updated" ] || continue
    local thresh; thresh=$(_wg_date_epoch "$updated") || continue
    [ -n "$thresh" ] || continue
    thresh=$((thresh + 86400))
    # sources for this id
    local src src_abs mt
    grep "^E	$id	" "$records" 2>/dev/null | awk -F'\t' '$4=="source"{print $3}' | while IFS= read -r src; do
      [ -n "$src" ] || continue
      src_abs="$vault_dir/$src"
      [ -f "$src_abs" ] || continue
      mt=$(_wg_file_mtime "$src_abs") || continue
      [ -n "$mt" ] || continue
      if [ "$mt" -gt "$thresh" ]; then printf '%s\n' "$id"; fi
    done
  done | LC_ALL=C sort -u
}

# portable epoch seconds -> YYYY-MM-DD (GNU `date -d @epoch`, BSD `date -r`).
_wg_epoch_to_date() {
  local e="$1" d
  d=$(date -u -d "@$e" +%F 2>/dev/null) && { printf '%s\n' "$d"; return 0; }
  d=$(date -u -r "$e" +%F 2>/dev/null) && { printf '%s\n' "$d"; return 0; }
  return 1
}

# 037: DELTA_DATE (contracts/graph-findings-extension.md §1/§3). Marker exists
# and parses ("deposited: YYYY-MM-DD", CANON-D13) -> that date; exists but does
# NOT parse (including empty) -> the marker's own mtime; absent -> "" (vault
# that never received the 0.27.0 delta -- description_missing then gates only
# on a declared `para`, never on a created-date comparison it has no anchor for).
_wg_delta_date() {
  local vault_dir="$1" marker d mt
  marker="$vault_dir/_templates/.schema-updates-0.27.0.applied"
  [ -f "$marker" ] || { printf ''; return 0; }
  d=$(sed -n 's/^deposited: \([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\)[ \t]*$/\1/p' "$marker" 2>/dev/null | head -1)
  if [ -n "$d" ]; then printf '%s\n' "$d"; return 0; fi
  mt=$(_wg_file_mtime "$marker") || { printf ''; return 0; }
  _wg_epoch_to_date "$mt" || printf ''
}

# portable YYYY-MM-DD -> epoch seconds (GNU/busybox `date -d`, BSD `date -j`).
_wg_date_epoch() {
  local d="$1" e
  e=$(date -u -d "$d" +%s 2>/dev/null) && { printf '%s\n' "$e"; return 0; }
  e=$(date -u -j -f "%Y-%m-%d" "$d" +%s 2>/dev/null) && { printf '%s\n' "$e"; return 0; }
  return 1
}

# portable file mtime epoch (GNU/busybox `stat -c`, BSD `stat -f`).
_wg_file_mtime() {
  local f="$1" m
  m=$(stat -c %Y "$f" 2>/dev/null) && { printf '%s\n' "$m"; return 0; }
  m=$(stat -f %m "$f" 2>/dev/null) && { printf '%s\n' "$m"; return 0; }
  return 1
}

# milliseconds (best-effort; falls back to seconds*1000).
_wg_now_ms() {
  local ns
  ns=$(date +%s%N 2>/dev/null)
  case "$ns" in
    *N|"") printf '%s\n' "$(( $(date +%s) * 1000 ))" ;;
    *) printf '%s\n' "$(( ns / 1000000 ))" ;;
  esac
}

# atomic write: content to <path>.tmp then mv (same dir → atomic rename).
_wg_atomic_write() {
  local path="$1" content="$2" dir tmp
  dir=$(dirname "$path")
  mkdir -p "$dir" 2>/dev/null || true
  tmp=$(mktemp "$dir/.wg.XXXXXX") || return 1
  printf '%s\n' "$content" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$path" 2>/dev/null || { rm -f "$tmp"; return 1; }
}

# jq aggregation: records.tsv + index entries + allwiki + stale → combined JSON
# {nodes, edges, pages(backlinks), findings, counts}.
_wg_aggregate() {
  local records="$1" idx="$2" allwiki="$3" stale="$4" vault_dir="$5" today="${6:-$(date -u +%F)}"
  local rawfile="${7:-/dev/null}" logfile="${8:-/dev/null}" deltadate="${9:-}"
  local punfeddays="${10:-30}" integrated="${11:-0}" deltapendingdays="${12:-14}"
  local archdays="${13:-90}"
  jq -n -R \
    --arg today "$today" \
    --arg deltadate "$deltadate" \
    --argjson punfeddays "$punfeddays" \
    --argjson integrated "$integrated" \
    --argjson deltapendingdays "$deltapendingdays" \
    --argjson archdays "$archdays" \
    --rawfile records "$records" \
    --rawfile idx "$idx" \
    --rawfile allwiki "$allwiki" \
    --rawfile stale "$stale" \
    --rawfile raw "$rawfile" \
    --rawfile logf "$logfile" '
    def lines($s): ($s | split("\n") | map(select(length>0)));
    def tsv($s): lines($s) | map(split("\t"));
    # 037: date helpers -- arithmetic runs ONLY on values already validated by
    # the awk F4 check (^[0-9]{4}-[0-9]{2}-[0-9]{2}$); a malformed non-empty
    # value is reported there and never reaches strptime here.
    def isdate($d): ($d != "" and ($d | test("^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$")));
    def epoch($d): ($d | strptime("%Y-%m-%d") | mktime);
    def todayepoch: epoch($today);
    def daysBetween($d): ((todayepoch - epoch($d)) / 86400 | floor);

    (tsv($records)) as $rec
    # 037: 13 columns appended after title_present, canonical order (contracts/
    # graph-findings-extension.md §2): para description_present packet distill
    # due next_review archived goal_present next_action_present project area
    # problems tags. problems/tags travel ";"-joined, split back here.
    | ([ $rec[] | select(.[0]=="N") | {
          id:.[1], type:.[2], status:.[3], created:.[4], updated:.[5], title_present:(.[6]=="1"),
          para: (if (.[7]//"")=="" then "resource" else .[7] end),
          para_raw: (.[7]//""),
          description_present: ((.[8]//"0")=="1"),
          packet: (.[9]//""), distill: (.[10]//""),
          due: (.[11]//""), next_review: (.[12]//""), archived: (.[13]//""),
          goal_present: ((.[14]//"0")=="1"), next_action_present: ((.[15]//"0")=="1"),
          project: (.[16]//""), area: (.[17]//""),
          problems: ((.[18]//"") as $p | if $p=="" then [] else ($p/";") end),
          tags: ((.[19]//"") as $t | if $t=="" then [] else ($t/";") end),
          description: (.[20]//"")
        } ]) as $nodes
    | ([ $nodes[].id ]) as $nodeids
    | ($nodeids | map({key:., value:true}) | from_entries) as $nodeset
    | (lines($allwiki) | map({key:., value:true}) | from_entries) as $fileset
    | (lines($idx)) as $identries
    | ($identries | map({key:., value:true}) | from_entries) as $idxset
    | (lines($stale) | map({key:., value:true}) | from_entries) as $staleset
    | ([ $rec[] | select(.[0]=="E") | {from:.[1], to:.[2], kind:.[3]} ]) as $rawedges0
    # 037: problems_ref (from `problems:`) is silently dropped when the target
    # (synthesis/favorite-problems) does not exist -- no edge, no broken_link,
    # unlike project:/area:, which DO become broken_link (data-model #5).
    | ([ $rawedges0[] | if .kind=="problems_ref"
          then (if $nodeset[.to] then (. + {kind:"related"}) else empty end)
          else . end ]) as $rawedges
    | ([ $rawedges[] | . + {broken: ((.kind=="wikilink" or .kind=="related") and ($nodeset[.to]|not)) } ]) as $edges
    | ([ $rec[] | select(.[0]=="V") | {page:.[1], reason:.[2]} ]) as $violations
    | ([ $rec[] | select(.[0]=="OCC") | {page:.[1], alias:.[2], canonical:.[3]} ]) as $occ
    # backlinks: incoming wikilink/related edges per node
    | ( reduce $edges[] as $e ({};
          if ($e.kind=="wikilink" or $e.kind=="related") and ($nodeset[$e.to]) and ($e.broken|not)
          then .[$e.to] += [$e.from] else . end) ) as $backmap
    # related_out per node
    | ( reduce $edges[] as $e ({};
          if $e.kind=="related" then .[$e.from] += [$e.to] else . end) ) as $relout
    # co_sourced: pages sharing a source
    | ( reduce $edges[] as $e ({};
          if $e.kind=="source" then .[$e.to] += [$e.from] else . end) ) as $bysource
    | ( reduce ($bysource|to_entries[]) as $s ({};
          reduce $s.value[] as $p (.; .[$p] += ($s.value | map(select(.!=$p)))) ) ) as $cosourced
    # canonical_of: aliases whose entity == node
    | ( reduce ($rec[] | select(.[0]=="AL")) as $a ({};
          if ($a[4]//"")!="" then (($a[4]) as $ent | .[$ent] += [$a[2]]) else . end) ) as $canonof
    | ( [ $nodes[].id ] | map({ (.): {
            backlinks: (($backmap[.] // []) | unique),
            related_out: (($relout[.] // []) | unique),
            co_sourced: (($cosourced[.] // []) | unique),
            canonical_of: (($canonof[.] // []) | unique)
        }}) | add // {} ) as $pages
    # 037: para lookup by id, for orphan/stale suppression on para=="archive"
    | ( $nodes | map({key:.id, value:.para}) | from_entries ) as $paraOf
    # 037: type lookup by id, for pending_ingest "cited by a summary" test
    | ( $nodes | map({key:.id, value:.type}) | from_entries ) as $typeOf
    # 037: raw sources with a clipped: key (RAW tag; empty when raw_sources/ is absent)
    | ( [ tsv($raw)[] | select(.[0]=="RAW") | {path:.[1], clipped:.[2]} ] ) as $rawsources
    # 037: raw paths already cited by a `sources:` edge FROM a summary node
    | ( ( [ $edges[] | select(.kind=="source" and ($typeOf[.from]=="summary")) | .to ] )
        | map({key:., value:true}) | from_entries ) as $citedmap
    # findings
    | ( [ $nodes[] | select(($backmap[.id]|length // 0) == 0 and .para != "archive") | {kind:"orphan", page:.id, detail:""} ] ) as $f_orphan
    | ( [ $edges[] | select(.broken) | {kind:"broken_link", page:.from, detail:.to} ] ) as $f_broken
    | ( [ $violations[] | {kind:"frontmatter_violation", page:.page, detail:.reason} ] ) as $f_fm
    | ( [ $identries[] | select($fileset[.]|not) | {kind:"index_drift", page:., detail:"missing_file"} ] ) as $f_idx_mf
    | ( [ $nodes[].id | select($idxset[.]|not) | {kind:"index_drift", page:., detail:"missing_from_index"} ] ) as $f_idx_mi
    | ( [ $staleset | keys[] | select(($paraOf[.] // "resource") != "archive") | {kind:"stale", page:., detail:"source newer than updated:"} ] ) as $f_stale
    | ( [ $occ[] | {kind:"alias_occurrence", page:.page, detail:(.alias + " -> " + .canonical)} ] ) as $f_alias
    # 037 project_incomplete: para=="project" missing goal/due/next_action, fixed order, non-date-dependent
    | ( [ $nodes[] | select(.para=="project") | . as $n |
          ([ (if $n.goal_present then empty else "goal" end),
             (if $n.due != "" then empty else "due" end),
             (if $n.next_action_present then empty else "next_action" end) ]) as $missing |
          select(($missing|length) > 0) |
          {kind:"project_incomplete", page:$n.id, detail:("missing: " + ($missing | join(",")))}
        ] ) as $f_incomplete
    # 037 review_due: para=="project", next_review missing OR in the past (archive
    # excluded by construction -- its para is never "project")
    | ( [ $nodes[] | select(.para=="project") | . as $n |
          (if $n.next_review=="" then
             {kind:"review_due", page:$n.id, detail:"next_review: missing"}
           elif (isdate($n.next_review) and (epoch($n.next_review) < todayepoch)) then
             {kind:"review_due", page:$n.id,
              detail:("next_review: " + $n.next_review + " (" + (daysBetween($n.next_review)|tostring) + " days)")}
           else empty end)
        ] ) as $f_review_due
    # 037 project_overdue: para=="project", due in the past (malformed/missing
    # due never reaches here -- isdate() guards the arithmetic)
    | ( [ $nodes[] | select(.para=="project") | . as $n |
          select(isdate($n.due) and (epoch($n.due) < todayepoch)) |
          {kind:"project_overdue", page:$n.id,
           detail:("due: " + $n.due + " (" + (daysBetween($n.due)|tostring) + " days)")}
        ] ) as $f_overdue
    # 037 pending_ingest: a clipped raw source not cited by any summary sources:
    | ( [ $rawsources[] | select($citedmap[.path]|not) |
          {kind:"pending_ingest", page:.path, detail:("no summary cites this source (clipped: " + .clipped + ")")}
        ] ) as $f_pending
    # 037 description_missing: no description AND (para declared in the file --
    # raw column non-empty -- OR (a delta date exists AND created is on/after
    # it)). para-declared always wins the detail when both branches would fire.
    | ( [ $nodes[] | select(.description_present|not) | . as $n |
          (if $n.para_raw != "" then
             {kind:"description_missing", page:$n.id, detail:("para: " + $n.para_raw)}
           elif ($deltadate != "" and isdate($n.created) and ($n.created >= $deltadate)) then
             {kind:"description_missing", page:$n.id,
              detail:("created: " + $n.created + " >= delta " + $deltadate)}
           else empty end)
        ] ) as $f_desc
    # 037 problem_unfed: for each fp-N declared on synthesis/favorite-problems
    # (FP tag from the awk body scan), the most recent `updated` among nodes
    # whose `problems` array contains it -- falling back to the
    # own `created` field of the favorite-problems page when nothing feeds it
    # yet (there is no other anchor). Absent the page entirely: no entries.
    | ( [ $rec[] | select(.[0]=="FP") | .[1] ] | unique ) as $fpslugs
    | ( $nodes | map(select(.id=="synthesis/favorite-problems")) | first ) as $fpnode
    | ( if $fpnode == null then [] else
          [ $fpslugs[] as $slug |
            ( [ $nodes[] | select(.problems | index($slug)) | .updated ] ) as $feeders |
            ( if ($feeders|length) > 0 then ($feeders | max) else $fpnode.created end ) as $lastdate |
            select(isdate($lastdate)) |
            daysBetween($lastdate) as $days |
            select($days > $punfeddays) |
            {kind:"problem_unfed", page:"synthesis/favorite-problems",
             detail:($slug + ": " + ($days|tostring) + " days without entries (threshold " + ($punfeddays|tostring) + ")")}
          ]
        end ) as $f_unfed
    # 037 schema_delta_pending: the delta self-denounces when it was deposited,
    # is NOT yet integrated (CANON-D1 absent from the CLAUDE.md of the vault)
    # and sat longer than the threshold.
    | ( if ($deltadate != "" and $integrated == 0 and isdate($deltadate) and (daysBetween($deltadate) > $deltapendingdays)) then
          [{kind:"schema_delta_pending", page:"_templates/schema-updates-0.27.0.md",
            detail:("deposited " + $deltadate + " (" + (daysBetween($deltadate)|tostring) + " days); vault CLAUDE.md lacks '\''## Actionability (PARA)'\''")}]
        else [] end ) as $f_delta_pending
    # 037 archive_candidate: status stale/superseded, no backlinks, para not
    # archive, and no log.md mention within the candidate window (a mention
    # OUTSIDE the window, or no mention ever, both count toward candidacy).
    | ( [ tsv($logf)[] | select(.[0]=="LOG") | {date:.[1], id:.[2]} ] ) as $logentries
    | ( reduce $logentries[] as $e ({}; .[$e.id] = (if ((.[$e.id]//"") == "") or ($e.date > .[$e.id]) then $e.date else .[$e.id] end)) ) as $lastmention
    | ( [ $nodes[] | select((.status=="stale" or .status=="superseded") and .para != "archive") | . as $n |
          select(($backmap[$n.id]|length // 0) == 0) |
          ($lastmention[$n.id] // "") as $lm |
          select(($lm == "") or (isdate($lm) and (epoch($lm) < (todayepoch - ($archdays * 86400))))) |
          {kind:"archive_candidate", page:$n.id,
           detail:("status: " + $n.status + "; backlinks: 0; last log mention: " + (if $lm=="" then "none" else $lm end))}
        ] ) as $f_archive
    | ( ($f_orphan + $f_broken + $f_fm + $f_idx_mf + $f_idx_mi + $f_stale + $f_alias + $f_incomplete
         + $f_review_due + $f_overdue + $f_pending + $f_desc + $f_unfed + $f_delta_pending + $f_archive)
        | sort_by(.kind, .page, .detail) ) as $findings
    # 037 packets.json: pages with a VALID packet: value (an invalid one is F2,
    # already excluded here since it never matches the enum). Order: updated
    # desc, then id asc. Built explicitly (unique updated values, newest first,
    # each bucket sorted by id) rather than sort+reverse, which would also
    # reverse the id tie-break.
    | ( [ $nodes[] | select(.packet | test("^(distilled-note|outtake|wip|deliverable|external)$")) |
          {id, type, packet, description, project, updated} ] ) as $cand
    | ( [ $cand[].updated ] | unique | reverse ) as $uvals
    | ( [ $uvals[] as $u | ($cand | map(select(.updated == $u)) | sort_by(.id))[] ] ) as $packets
    | {
        nodes: $nodes,
        edges: $edges,
        pages: $pages,
        findings: $findings,
        packets: $packets,
        counts: {
          nodes: ($nodes|length),
          edges: ($edges|length),
          orphans: ($f_orphan|length),
          broken_links: ($f_broken|length),
          frontmatter_violations: ($f_fm|length),
          index_drift: (($f_idx_mf|length) + ($f_idx_mi|length)),
          stale: ($f_stale|length),
          alias_occurrences: ($f_alias|length),
          project_incomplete: ($f_incomplete|length),
          project_overdue: ($f_overdue|length), review_due: ($f_review_due|length), pending_ingest: ($f_pending|length),
          description_missing: ($f_desc|length), problem_unfed: ($f_unfed|length), archive_candidate: ($f_archive|length), schema_delta_pending: ($f_delta_pending|length),
          packets: ($packets|length),
          para_project: ([$nodes[] | select(.para=="project")] | length),
          para_area: ([$nodes[] | select(.para=="area")] | length),
          para_archive: ([$nodes[] | select(.para=="archive")] | length)
        }
      }
  '
}
