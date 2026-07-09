# shellcheck shell=bash
# Library: deterministic knowledge graph + structural lint over the vault wiki.
#
# Feature 014 (wiki-graph-rag). Derives a graph from the whole wiki/ base
# WITHOUT an LLM and WITHOUT ever editing the wiki:
#   - nodes  = pages under wiki/<6-types>/ (frontmatter attrs)
#   - edges  = body [[wikilinks]] + related: + sources: + alias→canonical
#   - findings = orphans, broken_links, frontmatter_violations, index_drift,
#                stale, alias_occurrences
# Artifacts land under <vault>/.graph/{graph,backlinks,findings}.json (JSON only,
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

# Atomic write of the state file: {schema,last_run,last_status,duration_ms,
# counts{...},error}. tmp+mv. No `locked` status (the flock loser writes nothing).
wiki_graph_write_state() {
  local state_file="$1" status="$2" duration_ms="$3" counts_json="$4" errmsg="${5:-}"
  local dir tmp now
  dir=$(dirname "$state_file")
  mkdir -p "$dir" 2>/dev/null || true
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  [ -z "$counts_json" ] && counts_json='{"nodes":0,"edges":0,"orphans":0,"broken_links":0,"frontmatter_violations":0,"index_drift":0,"stale":0,"alias_occurrences":0}'
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
  print "N\t" curid "\t" ftype "\t" fstatus "\t" fcreated "\t" fupdated "\t" title_present;
  if (!title_present) emit_v(curid, "title: key missing");
  if (ftype == "") emit_v(curid, "type: missing");
  else if (!(ftype in VALIDTYPE)) emit_v(curid, "type: invalid '" ftype "'");
  if (fstatus != "" && !(fstatus in VALIDSTATUS)) emit_v(curid, "status: invalid '" fstatus "'");
  for (i = 1; i <= nwl; i++) print "E\t" curid "\t" wl[i] "\twikilink";
  for (i = 1; i <= nrel; i++) print "E\t" curid "\t" rel[i] "\trelated";
  for (i = 1; i <= nsrc; i++) print "E\t" curid "\t" src[i] "\tsource";
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
    }
    next;
  }
  # body: track fenced code blocks (``` toggles); skip fenced lines entirely
  if (line ~ /^[ \t]*```/) { fence = 1 - fence; next; }
  if (fence) next;
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

  # 5) jq aggregation → combined.json
  local combined="$tmpd/combined.json" aggerr="$tmpd/agg.err"
  # 015 US3/FR-007: capture the real aggregation stderr (redacted) instead of
  # swallowing it with 2>/dev/null. The old generic "jq aggregation failed" hid an
  # ENOSPC "No space left on device" during the ferrari gate; fail-silent must
  # record the infra error, not eat it (refines Principle IV).
  if ! _wg_aggregate "$records" "$idx_file" "$allwiki" "$stale_file" "$vault_dir" > "$combined" 2>"$aggerr"; then
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

  # 6) atomic writes of the three artifacts under <vault>/.graph/
  mkdir -p "$graph_dir" 2>/dev/null || true
  local now; now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  _wg_atomic_write "$graph_dir/graph.json" \
    "$(jq -c --argjson s 1 --arg g "$now" --arg v "$vault_dir" '{schema:$s,generated_at:$g,vault:$v,nodes:.nodes,edges:.edges}' "$combined")"
  _wg_atomic_write "$graph_dir/backlinks.json" \
    "$(jq -c --argjson s 1 --arg g "$now" '{schema:$s,generated_at:$g,pages:.pages}' "$combined")"
  _wg_atomic_write "$graph_dir/findings.json" \
    "$(jq -c --argjson s 1 --arg g "$now" '{schema:$s,generated_at:$g,findings:.findings}' "$combined")"

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
  local records="$1" idx="$2" allwiki="$3" stale="$4" vault_dir="$5"
  jq -n -R \
    --rawfile records "$records" \
    --rawfile idx "$idx" \
    --rawfile allwiki "$allwiki" \
    --rawfile stale "$stale" '
    def lines($s): ($s | split("\n") | map(select(length>0)));
    def tsv($s): lines($s) | map(split("\t"));

    (tsv($records)) as $rec
    | ([ $rec[] | select(.[0]=="N") | {id:.[1], type:.[2], status:.[3], created:.[4], updated:.[5], title_present:(.[6]=="1")} ]) as $nodes
    | ([ $nodes[].id ]) as $nodeids
    | ($nodeids | map({key:., value:true}) | from_entries) as $nodeset
    | (lines($allwiki) | map({key:., value:true}) | from_entries) as $fileset
    | (lines($idx)) as $identries
    | ($identries | map({key:., value:true}) | from_entries) as $idxset
    | (lines($stale) | map({key:., value:true}) | from_entries) as $staleset
    | ([ $rec[] | select(.[0]=="E") | {from:.[1], to:.[2], kind:.[3]} ]) as $rawedges
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
    # findings
    | ( [ $nodes[] | select(($backmap[.id]|length // 0) == 0) | {kind:"orphan", page:.id, detail:""} ] ) as $f_orphan
    | ( [ $edges[] | select(.broken) | {kind:"broken_link", page:.from, detail:.to} ] ) as $f_broken
    | ( [ $violations[] | {kind:"frontmatter_violation", page:.page, detail:.reason} ] ) as $f_fm
    | ( [ $identries[] | select($fileset[.]|not) | {kind:"index_drift", page:., detail:"missing_file"} ] ) as $f_idx_mf
    | ( [ $nodes[].id | select($idxset[.]|not) | {kind:"index_drift", page:., detail:"missing_from_index"} ] ) as $f_idx_mi
    | ( [ $staleset | keys[] | {kind:"stale", page:., detail:"source newer than updated:"} ] ) as $f_stale
    | ( [ $occ[] | {kind:"alias_occurrence", page:.page, detail:(.alias + " -> " + .canonical)} ] ) as $f_alias
    | ( ($f_orphan + $f_broken + $f_fm + $f_idx_mf + $f_idx_mi + $f_stale + $f_alias)
        | sort_by(.kind, .page, .detail) ) as $findings
    | {
        nodes: $nodes,
        edges: $edges,
        pages: $pages,
        findings: $findings,
        counts: {
          nodes: ($nodes|length),
          edges: ($edges|length),
          orphans: ($f_orphan|length),
          broken_links: ($f_broken|length),
          frontmatter_violations: ($f_fm|length),
          index_drift: (($f_idx_mf|length) + ($f_idx_mi|length)),
          stale: ($f_stale|length),
          alias_occurrences: ($f_alias|length)
        }
      }
  '
}
