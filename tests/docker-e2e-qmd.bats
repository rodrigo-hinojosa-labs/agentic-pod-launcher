#!/usr/bin/env bats
# Docker e2e (T035, 010-self-managing-rag): scaffolds a QMD-enabled agent, boots
# it, and proves the integration seams that the host suite can only stub:
#
#   1. first-boot auto-setup    → ~/.cache/qmd/index.sqlite + the .qmd-setup-ok
#                                  sentinel appear (qmd_setup_if_needed ran,
#                                  backgrounded, under the watchdog).
#   2. wiring                    → the inotify watcher process is alive, the
#                                  */5 cron backstop line is in the crontab, and
#                                  inotify-tools is installed in the image.
#   3. cron-path reindex         → a vault change + `heartbeatctl qmd-reindex`
#                                  (the exact command the cron line runs) writes
#                                  qmd-index.json with last_status=indexed.
#   4. inotify-under-bind-mount  → an in-container vault write makes the WATCHER
#                                  drive a reindex on its own. Hard-asserted on
#                                  Linux (CI + production semantics); tolerated
#                                  on macOS where VirtioFS may not deliver inotify
#                                  events (the seam is still proven in Linux CI).
#   5. least privilege (Princ.II)→ `docker inspect` confirms cap_drop: ALL stands.
#
# The FIRST test stubs the qmd ENGINE (fake binary pre-seeded into the managed
# prefix under .state — the post-016 seam, see
# specs/019-fix-qmd-test-drift/contracts/qmd-test-seam.md; a PATH `bunx` stub is
# dead code since 016) so the orchestration (watcher, cron, flock, caps) is
# proven fast, without the ~300 MB model. 019 NOTE: this alignment is
# syntax-validated on the host only; full Docker validation is DEFERRED to the
# next DOCKER_E2E=1 run on a Docker host. The SECOND test (016/017) exercises the
# REAL @tobilu/qmd via the PRODUCTION path (_qmd_run / managed prefix): node-llama-cpp
# + better-sqlite3 compile against the image toolchain, tree-sitter stays WASM, and
# the musl-compiled sqlite-vec vec0.so is swapped into the prefix (017). Tiers:
#   A build-detector : the baked vec0.so is musl (017), and `_qmd_run --help` RC 0
#                      (install + native compile succeed via the managed prefix, NOT
#                      `bunx` which recompiles tree-sitter and re-triggers BUG 4). No
#                      model download.
#   RED detection    : rebuild with --build-arg QMD_NATIVE_TOOLCHAIN=0 → bigstack.so
#                      AND vec0.so are absent (both gated by the toolchain) — a
#                      deterministic SC-003 proof, both directions.
#   Tier 2 (embed)   : its own test since 041 (`qmd real (041)`), gated by
#                      QMD_EMBED_E2E=1 and fed with the models the nightly fetches
#                      beforehand (.github/scripts/fetch-qmd-models.sh), so nothing is
#                      downloaded inside the container; a real reindex (update + embed)
#                      SUCCEEDS only if vec0 loaded (017), and a semantic vsearch returns
#                      the right doc (SC-001). Closed gate = a skip with a reason.
# Mirrors tests/docker-e2e-vault.bats (claude stub, compose-run gotchas).
#
# Skipped by default (slow + requires Docker). Enable with DOCKER_E2E=1.

load helper

setup() {
  if [ "${DOCKER_E2E:-0}" != "1" ]; then skip "set DOCKER_E2E=1 to run"; fi
  TMPDIR=/tmp setup_tmp_dir
  export DEST="$TMP_TEST_DIR/agent-qmd-e2e"
  export AGENT_NAME="qmd-e2e"
}

# 041: what a first red run needs and cannot reproduce afterwards, best effort (the container may
# be gone, and nothing here may turn the red it reports on into a different one): the free disk,
# the verdict of the container itself (OOM kill, exit code, restarts) and, from inside it, the
# CPU, the vector extension the install laid down, the memory counters of its cgroup and the state
# and output files of the reindex and of the semantic search (the cause of a failure that is not a
# timeout lives there, and the workspace is gone when the job ends).
# "qmd-embed" is the compose service of the 041 workspace (NAME in the test).
_embed_failure_state() {
  local d="$TMP_TEST_DIR/agent-qmd-embed" ids
  echo "# --- state at the failure: disk, container verdict, vector extension ---" >&3
  echo "# disk: $(df -Pk "$TMP_TEST_DIR" 2>/dev/null | awk 'END {print "free_kb=" $4}')" >&3 || true
  ids=$(cd "$d" && docker compose ps -aq 2>/dev/null) || true
  if [ -n "$ids" ]; then
    docker inspect --format '{{.Name}} oom={{.State.OOMKilled}} exit={{.State.ExitCode}} restarts={{.RestartCount}}' $ids 2>&1 | sed 's/^/# /' >&3 || true
  fi
  (cd "$d" && docker compose exec -T -u agent qmd-embed sh -c 'uname -m; sh /workspace/.e2e/vec0-libc.sh "$HOME/.cache/qmd/pkg"; ls -la "$HOME"/.cache/qmd/pkg/node_modules/sqlite-vec-linux-* 2>&1; cat /sys/fs/cgroup/memory.events /sys/fs/cgroup/memory.peak 2>&1; echo "--- qmd-index.json"; cat /workspace/scripts/heartbeat/qmd-index.json 2>&1; echo "--- qmd-reindex.out (tail)"; tail -n 40 /tmp/qmd-reindex.out 2>&1; echo "--- vsearch.out (tail)"; tail -n 40 "$HOME/.cache/qmd/tmp/vsearch.out" 2>&1' 2>&1) | sed 's/^/# /' >&3 || true
}

teardown() {
  # 041 (FR-004, research D9): a failed embed test dumps the container logs ONCE, before the
  # project goes down, so the job log says what the container was doing when the phase marked
  # last failed. A skip also sets BATS_TEST_COMPLETED, so a skipped test dumps nothing. The
  # dump goes through fd 3 as TAP comments: it shows whatever flags the runner passes bats.
  if [ -z "${BATS_TEST_COMPLETED:-}" ] && [ -f "$TMP_TEST_DIR/agent-qmd-embed/docker-compose.yml" ]; then
    echo "# --- container logs of the failed embed test (last 150 lines) ---" >&3
    (cd "$TMP_TEST_DIR/agent-qmd-embed" && docker compose logs --tail=150 --no-color 2>&1) | sed 's/^/# /' >&3 || true
    _embed_failure_state
  fi
  # Sweep every per-test workspace under $TMP_TEST_DIR, not just $DEST: the
  # 037 tests use their OWN isolated D2/D3 dirs (distinct compose project
  # names, to avoid the container/network name collisions a shared $DEST/
  # $AGENT_NAME produced when tests ran back-to-back) via `local` vars that
  # do not survive into this separate function call — this glob is how they
  # still get torn down.
  local d
  for d in "$TMP_TEST_DIR"/agent-qmd-*; do
    [ -d "$d" ] || continue
    (cd "$d" && docker compose down -v --remove-orphans || true)
  done
  teardown_tmp_dir
}

@test "qmd e2e: first-boot setup, watcher+cron wiring, reindex on vault change, caps intact" {
  # 1) workspace with agent.yml: vault + qmd enabled, short watcher debounce so
  #    the inotify phase resolves quickly.
  mkdir -p "$DEST"
  cat > "$DEST/agent.yml" <<YML
version: 1
agent: {name: $AGENT_NAME, display_name: "qmd e2e 🔎", role: "test", vibe: "terse"}
user: {name: "Tester", nickname: "Tester", timezone: "UTC", email: "t@e.x", language: "en"}
deployment: {host: "test", workspace: "$DEST", install_service: false, claude_cli: "claude"}
docker: {image_tag: "agent-admin:qmd-e2e", uid: $(id -u), gid: $(id -g), state_volume: "${AGENT_NAME}-state", base_image: "alpine:3.20"}
claude: {config_dir: "/home/agent/.claude", profile_new: true}
notifications: {channel: none}
features:
  heartbeat: {enabled: true, interval: "30m", timeout: 30, retries: 0, default_prompt: "echo pong"}
mcps: {defaults: [], atlassian: [], github: {enabled: false, email: ""}}
vault:
  enabled: true
  path: .state/.vault
  seed_skeleton: true
  initial_sources: []
  mcp: {enabled: true, server: vault}
  qmd: {enabled: true, version: "2.5.3", schedule: "*/5 * * * *"}
  schema: {frontmatter_required: true, log_format: "## [{date}] {op} | {title}"}
plugins: []
YML
  cp -R "$REPO_ROOT/modules" "$REPO_ROOT/scripts" "$REPO_ROOT/docker" "$DEST/"
  cp "$REPO_ROOT/setup.sh" "$DEST/"
  chmod +x "$DEST/setup.sh"

  # 2) regenerate derived files (docker-compose.yml + .mcp.json + crontab inputs)
  (cd "$DEST" && ./setup.sh --regenerate --non-interactive)
  touch "$DEST/.env"; chmod 0600 "$DEST/.env"

  # 3) stubs. claude: sleep forever so the watchdog stops respawning the tmux
  #    session. qmd engine: fake binary PRE-SEEDED into the managed prefix under
  #    .state (019 seam — post-016, _qmd_run executes
  #    $prefix/node_modules/.bin/qmd directly; a PATH bunx stub is dead code).
  #    The pre-seeded .installed-hash makes _qmd_ensure_prefix skip `bun
  #    install`, so qmd_setup_if_needed completes without network or the real
  #    300 MB model download. Hash derived from the lib's own helpers so it
  #    tracks the manifest (sha256 of identical content — host/container agree).
  mkdir -p "$DEST/bin"
  cat > "$DEST/bin/claude" <<'CL'
#!/bin/bash
exec sleep 86400
CL
  chmod +x "$DEST/bin/claude"

  local _prefix="$DEST/.state/.cache/qmd/pkg"
  mkdir -p "$_prefix/node_modules/.bin"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/scripts/lib/qmd_index.sh"
  printf '%s' "$(_qmd_manifest "2.5.3")" > "$_prefix/package.json"
  printf '%s' "$(_qmd_manifest "2.5.3")" | _qmd_sha > "$_prefix/.installed-hash"
  cat > "$_prefix/node_modules/.bin/qmd" <<'QS'
#!/bin/sh
# qmd e2e engine stub: log calls, fake the index on `collection add`, emit the
# 018 completion signal on embed/status so the multi-pass loop ends in one
# pass. (mcp is only launched by claude, which is itself stubbed.)
mkdir -p "$HOME/.cache/qmd" 2>/dev/null || true
echo "$*" >> "$HOME/.cache/qmd/engine-calls.log" 2>/dev/null || true
case "$1" in
  collection) : > "$HOME/.cache/qmd/index.sqlite" ;;
  embed)  echo "✓ All content hashes already have embeddings" ;;
  status) echo "Pending: 0 need embedding" ;;
esac
exit 0
QS
  chmod +x "$_prefix/node_modules/.bin/qmd"

  # 4) bind-mount the claude stub into the container over the real binary.
  #    (The engine stub needs no mount — it lives under .state, which IS the
  #    /home/agent bind-mount.)
  python3 - "$DEST/docker-compose.yml" <<'PY'
import sys
path = sys.argv[1]
txt = open(path).read()
needle = '      - ./:/workspace'
for inject in (
    '      - ./bin/claude:/usr/local/bin/claude:ro',
):
    if inject not in txt:
        txt = txt.replace(needle, needle + '\n' + inject, 1)
open(path, 'w').write(txt)
PY

  # 5) build + up
  (cd "$DEST" && docker compose build)
  (cd "$DEST" && docker compose up -d)

  in_container() { (cd "$DEST" && docker compose exec -T -u agent "$AGENT_NAME" "$@"); }

  # ── Phase 1: first-boot auto-setup produced an index + sentinel ──────────────
  local deadline=$(( $(date +%s) + 90 ))
  local setup_ok=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if in_container sh -c 'test -f "$HOME/.cache/qmd/index.sqlite" && test -f "$HOME/.cache/qmd/.qmd-setup-ok"' 2>/dev/null; then
      setup_ok=1; break
    fi
    sleep 2
  done
  if [ "$setup_ok" -ne 1 ]; then
    echo "--- container logs ---" >&2
    (cd "$DEST" && docker compose logs --tail=100 2>&1) >&2 || true
    echo "--- engine calls ---" >&2
    in_container sh -c 'cat "$HOME/.cache/qmd/engine-calls.log" 2>&1' >&2 || true
  fi
  [ "$setup_ok" -eq 1 ]
  # setup must have run the full add → update → embed sequence, and (037) the
  # collection add MUST carry the wiki/-only mask -- raw_sources/ was never
  # meant to be in the search collection (Grep/search_notes cover it instead).
  run in_container sh -c 'cat "$HOME/.cache/qmd/engine-calls.log"'
  [[ "$output" == *"collection add"* ]]
  echo "$output" | grep -qF -- '--mask wiki/**/*.md'
  [[ "$output" == *"update"* ]]
  [[ "$output" == *"embed"* ]]

  # ── Phase 2: wiring — watcher alive, cron line present, inotifywait installed ─
  # 039-fix-nightly-e2e-sigpipe: WAIT for the watcher instead of checking once.
  # start_services.sh main() launches it only after the initial session has
  # returned (the marketplace registration alone took 12s on the CI runner),
  # while the engine stub lets phases 1-3 finish in seconds. The old one-shot
  # `pgrep -f qmd_watch.sh` passed with no watcher running (run 37868087664:
  # the watcher logged its start 15s after phase 3's state write), and phase 4
  # then wrote its note to a vault nobody was watching yet -- inotify never
  # replays an event that predates the watch. Liveness is what the product
  # itself uses (qmd_watch_alive: the pidfile) plus the inotifywait process,
  # looked up in `ps` with a bracket so this very command line cannot match.
  local up_deadline=$(( $(date +%s) + 120 )) watcher_up=0
  while [ "$(date +%s)" -lt "$up_deadline" ]; do
    if in_container sh -c 'kill -0 "$(cat /tmp/agent-watchdog/qmd-watch.pid 2>/dev/null)" 2>/dev/null && ps w | grep "[i]notifywait" >/dev/null' 2>/dev/null; then
      watcher_up=1; break
    fi
    sleep 2
  done
  if [ "$watcher_up" -ne 1 ]; then
    echo "--- the qmd watcher did not come up in 120s; container logs ---" >&2
    (cd "$DEST" && docker compose logs --tail=60 2>&1) >&2 || true
  fi
  [ "$watcher_up" -eq 1 ]
  sleep 2   # inotifywait -r adds its watches right after exec; give it a beat
  # The */5 backstop line reaches /etc/crontabs/agent via entrypoint's root
  # crontab-sync loop, which polls every 15s. The engine stub makes first-boot
  # setup finish in seconds, so POLL for the line rather than racing the first
  # sync tick. (busybox `crontab -l` reads a different path — read the file crond
  # actually uses.)
  local cron_deadline=$(( $(date +%s) + 60 ))
  local cron_line=""
  while [ "$(date +%s)" -lt "$cron_deadline" ]; do
    cron_line=$(in_container sh -c 'grep -F "qmd-reindex" /etc/crontabs/agent 2>/dev/null' | tr -d '\r')
    [ -n "$cron_line" ] && break
    sleep 3
  done
  [ -n "$cron_line" ]
  [[ "$cron_line" == *"*/5 * * * *"* ]]
  run in_container sh -c 'command -v inotifywait >/dev/null && echo HAVE_INOTIFY'
  [[ "$output" == *"HAVE_INOTIFY"* ]]

  # 013 FR-016: `bunx` MUST exist in the REAL image — general bun tooling relies
  # on the symlink (since 019 no PATH stub can mask it: the engine stub lives in
  # the managed prefix, not on PATH). Assert the absolute path.
  run in_container sh -c 'test -x /usr/local/bin/bunx && readlink /usr/local/bin/bunx'
  [ "$status" -eq 0 ]
  [[ "$output" == *"/usr/local/bin/bun"* ]]

  # ── Phase 3: cron-path reindex is deterministic (no inotify dependency) ──────
  # Change the vault, run the EXACT command the cron line runs, assert state.
  in_container sh -c 'echo "# cron note" > /home/agent/.vault/cron-note.md'
  run in_container /usr/local/bin/heartbeatctl qmd-reindex
  [ "$status" -eq 0 ]
  # last_status is "indexed" (hash changed) or "skipped" (on Linux the watcher
  # may have already reindexed this write) — both prove the cron path ran and
  # wrote a consistent state file. grep (not [[ ]]) so a miss fails the test.
  run in_container sh -c 'jq -r .last_status /workspace/scripts/heartbeat/qmd-index.json'
  echo "$output" | grep -qE '^(indexed|skipped)$'
  run in_container sh -c 'jq -r .runs /workspace/scripts/heartbeat/qmd-index.json'
  local runs_after_cron="$output"
  [ "$runs_after_cron" -ge 1 ]

  # ── Phase 4: inotify-under-bind-mount — the watcher reindexes on its own ─────
  # Debounce default is 15s; poll generously. An in-container write goes through
  # the bind-mount, which is the production-relevant path.
  in_container sh -c 'echo "# watch note" > /home/agent/.vault/watch-note.md'
  local wdeadline=$(( $(date +%s) + 60 ))
  local watcher_fired=0 cur
  while [ "$(date +%s)" -lt "$wdeadline" ]; do
    cur=$(in_container sh -c 'jq -r .runs /workspace/scripts/heartbeat/qmd-index.json' 2>/dev/null | tr -d '\r')
    if [ -n "$cur" ] && [ "$cur" -gt "$runs_after_cron" ]; then watcher_fired=1; break; fi
    sleep 3
  done
  # 039-fix-nightly-e2e-sigpipe: the first real nightly run (run 37834784760)
  # failed on the assertion below with nothing to say why -- start_services.sh
  # launches the watcher with its output discarded and this phase dumped
  # nothing. On failure ONLY, show what the container can still tell. The
  # assertions themselves are unchanged. Order matters: the 45s wait goes
  # BEFORE the probe, because the probe writes into the vault and would itself
  # wake the watcher, hiding a late fire of the original event.
  _watcher_diag() {
    {
      echo "--- 039 diag: runs did not rise above $runs_after_cron in 60s (last seen: ${cur:-none}) ---"
      echo "--- processes:"
      in_container sh -c 'ps w 2>&1 | grep -E "qmd_watch|inotifywait|crond" | grep -v grep'
      echo "--- watcher pid file:"
      in_container sh -c 'cat /tmp/agent-watchdog/qmd-watch.pid 2>&1'
      echo "--- qmd-index.json:"
      in_container sh -c 'cat /workspace/scripts/heartbeat/qmd-index.json 2>&1'
      echo "--- engine calls (every reindex logs update/embed/status):"
      in_container sh -c 'cat "$HOME/.cache/qmd/engine-calls.log" 2>&1'
      echo "--- inotify limits (max_user_watches, max_user_instances):"
      in_container sh -c 'cat /proc/sys/fs/inotify/max_user_watches /proc/sys/fs/inotify/max_user_instances 2>&1'
      echo "--- waiting 45s more, to tell slow from dead"
      sleep 45
      echo "--- qmd-index.json after the extra wait:"
      in_container sh -c 'cat /workspace/scripts/heartbeat/qmd-index.json 2>&1'
      echo "--- engine calls after the extra wait:"
      in_container sh -c 'cat "$HOME/.cache/qmd/engine-calls.log" 2>&1'
      echo "--- raw inotifywait probe (does the kernel deliver events for an in-container write on this mount?):"
      in_container sh -c '(inotifywait -q -t 6 -e create,modify /home/agent/.vault > /tmp/probe.out 2>&1 &); sleep 1; echo probe > /home/agent/.vault/probe-note.md; sleep 4; cat /tmp/probe.out; echo "(end of probe)"'
      echo "--- 20s after the probe write: does the WATCHER react to a write made after it started? (debounce is 15s)"
      sleep 20
      in_container sh -c 'cat /workspace/scripts/heartbeat/qmd-index.json 2>&1'
      in_container sh -c 'cat "$HOME/.cache/qmd/engine-calls.log" 2>&1'
      echo "--- container logs (tail):"
      (cd "$DEST" && docker compose logs --tail=60 2>&1)
    } >&2 || true
  }
  if [ "$(uname -s)" = "Linux" ]; then
    # Production/CI semantics: the inotify seam MUST fire (Principle II evidence).
    if [ "$watcher_fired" -ne 1 ]; then _watcher_diag; fi
    [ "$watcher_fired" -eq 1 ]
  else
    # macOS Docker Desktop: VirtioFS may not deliver inotify for bind-mount
    # writes. Don't fail the dev host — the seam is hard-asserted in Linux CI.
    [ "$watcher_fired" -eq 1 ] || echo "note: inotify did not deliver under VirtioFS on $(uname -s) — seam covered in Linux CI"
  fi

  # ── Phase 4.5: wiki-graph (014) — cron line, manual run, cross-mode parity ───
  # 4.5a: the wiki-graph cron line reaches /etc/crontabs/agent (default-on w/ vault).
  local wg_deadline=$(( $(date +%s) + 60 )) wg_line=""
  while [ "$(date +%s)" -lt "$wg_deadline" ]; do
    wg_line=$(in_container sh -c 'grep -F "heartbeatctl wiki-graph" /etc/crontabs/agent 2>/dev/null' | grep -vE '^#' | tr -d '\r')
    [ -n "$wg_line" ] && break
    sleep 3
  done
  [ -n "$wg_line" ]
  [[ "$wg_line" == *"20 */6"* ]]

  # 4.5b: the additive upgrade ran at boot on a FRESH-seeded vault → no spurious
  # delta (the fresh-scaffold guard holds in the real container). The upgrade log
  # line marks a real (populated) upgrade only — a clean seed leaves none.
  run in_container sh -c 'test -f /home/agent/.vault/wiki/normalization/.gitkeep && echo HAVE_NORM'
  [[ "$output" == *"HAVE_NORM"* ]]
  run in_container sh -c 'test -f /home/agent/.vault/_templates/.schema-updates-0.8.0.applied && echo HAS_DELTA || echo NO_DELTA'
  [[ "$output" == *"NO_DELTA"* ]]

  # 4.5c: cross-mode parity (M1/SC-003) — overlay the SAME vault-graph fixture the
  # host suite uses, run the runner, and assert the counts match the host oracle
  # exactly. This proves docker awk/jq produces identical findings to the host.
  cp -R "$REPO_ROOT/tests/fixtures/vault-graph/." "$DEST/.state/.vault/"
  touch "$DEST/.state/.vault/raw_sources/articles/base.md"   # stale: source newer than updated:
  run in_container /usr/local/bin/heartbeatctl wiki-graph
  [ "$status" -eq 0 ]
  run in_container sh -c 'test -f /home/agent/.vault/.graph/graph.json && test -f /home/agent/.vault/.graph/findings.json && echo OK'
  [[ "$output" == *"OK"* ]]
  # .graph/ holds ONLY non-.md artifacts (backup + qmd exclusion invariant, L1)
  run in_container sh -c 'find /home/agent/.vault/.graph -name "*.md" | wc -l | tr -d " "'
  [ "$output" = "0" ]
  # exact counts == host oracle (SC-001 inventory)
  run in_container sh -c 'jq -c ".counts | {nodes,orphans,broken_links,frontmatter_violations,index_drift,stale,alias_occurrences}" /workspace/scripts/heartbeat/wiki-graph.json'
  [[ "$output" == '{"nodes":7,"orphans":1,"broken_links":1,"frontmatter_violations":1,"index_drift":2,"stale":1,"alias_occurrences":1}' ]]
  run in_container sh -c 'jq -r .last_status /workspace/scripts/heartbeat/wiki-graph.json'
  [ "$output" = "ok" ]

  # ── Phase 4.6: 015 US3 — rag_obs.sh baked in + host-backed scratch routing ───
  # The shared observability helper is mirrored + COPYed into the image (T004), so
  # the runners source it (not the fallback). And the wiki-graph runner routed its
  # temporaries onto host-backed .state (under the state dir), NOT the tmpfs /tmp —
  # this is what keeps bunx's ~98MB qmd cache from filling /tmp and ENOSPC-ing the
  # aggregation on a large vault (the ferrari bug, now fixed in code).
  run in_container sh -c 'test -f /opt/agent-admin/scripts/lib/rag_obs.sh && echo HAVE_RAGOBS'
  echo "$output" | grep -q HAVE_RAGOBS       # grep (not [[ ]]) so a miss FAILS the test
  run in_container sh -c 'test -d /workspace/scripts/heartbeat/tmp && echo HAVE_SCRATCH'
  echo "$output" | grep -q HAVE_SCRATCH

  # ── Phase 5: least privilege intact (Principle II, NON-NEGOTIABLE) ───────────
  local cid
  cid=$(cd "$DEST" && docker compose ps -q "$AGENT_NAME")
  [ -n "$cid" ]
  run docker inspect --format '{{.HostConfig.CapDrop}}' "$cid"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL"* ]]
}

# 037 T037: an agent scaffolded before the 0.27.0 wiki/-only mask migrates its
# qmd collection automatically, once, on the first reindex tick. Pre-seeds a
# "legacy" index (index.sqlite present, NO .qmd-collection-wiki sentinel) so
# qmd_setup_if_needed skips entirely (its `[ ! -f index.sqlite ]` guard is
# false) and the ONLY path that can migrate is _qmd_reindex_locked's own
# pending-state check (T015) -- proving the real boot plumbing, not a stub
# shortcut. `heartbeatctl qmd-reindex` is invoked directly (deterministic)
# rather than waiting for the */5 cron backstop.
@test "qmd e2e (037): a legacy vault-root collection migrates to wiki/-only on the first reindex tick" {
  local D2="$TMP_TEST_DIR/agent-qmd-migrate-e2e" N2="qmd-migrate-e2e"
  mkdir -p "$D2"
  cat > "$D2/agent.yml" <<YML
version: 1
agent: {name: $N2, display_name: "qmd migrate e2e", role: "test", vibe: "terse"}
user: {name: "Tester", nickname: "Tester", timezone: "UTC", email: "t@e.x", language: "en"}
deployment: {host: "test", workspace: "$D2", install_service: false, claude_cli: "claude"}
docker: {image_tag: "agent-admin:qmd-migrate-e2e", uid: $(id -u), gid: $(id -g), state_volume: "${N2}-state", base_image: "alpine:3.20"}
claude: {config_dir: "/home/agent/.claude", profile_new: true}
notifications: {channel: none}
features:
  heartbeat: {enabled: true, interval: "30m", timeout: 30, retries: 0, default_prompt: "echo pong"}
mcps: {defaults: [], atlassian: [], github: {enabled: false, email: ""}}
vault:
  enabled: true
  path: .state/.vault
  seed_skeleton: true
  initial_sources: []
  mcp: {enabled: true, server: vault}
  qmd: {enabled: true, version: "2.5.3", schedule: "*/5 * * * *"}
  schema: {frontmatter_required: true, log_format: "## [{date}] {op} | {title}"}
plugins: []
YML
  cp -R "$REPO_ROOT/modules" "$REPO_ROOT/scripts" "$REPO_ROOT/docker" "$D2/"
  cp "$REPO_ROOT/setup.sh" "$D2/"
  chmod +x "$D2/setup.sh"
  (cd "$D2" && ./setup.sh --regenerate --non-interactive)
  touch "$D2/.env"; chmod 0600 "$D2/.env"

  mkdir -p "$D2/bin"
  cat > "$D2/bin/claude" <<'CL'
#!/bin/bash
exec sleep 86400
CL
  chmod +x "$D2/bin/claude"

  # Pre-seed the managed prefix (installed, so no `bun install`/network) PLUS a
  # legacy index.sqlite with NO sentinel -- the exact shape qmd_collection_
  # migration_state reads as "pending" (index present, sentinel absent).
  local _prefix="$D2/.state/.cache/qmd/pkg"
  mkdir -p "$_prefix/node_modules/.bin" "$D2/.state/.cache/qmd"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/scripts/lib/qmd_index.sh"
  printf '%s' "$(_qmd_manifest "2.5.3")" > "$_prefix/package.json"
  printf '%s' "$(_qmd_manifest "2.5.3")" | _qmd_sha > "$_prefix/.installed-hash"
  : > "$D2/.state/.cache/qmd/index.sqlite"
  cat > "$_prefix/node_modules/.bin/qmd" <<'QS'
#!/bin/sh
mkdir -p "$HOME/.cache/qmd" 2>/dev/null || true
echo "$*" >> "$HOME/.cache/qmd/engine-calls.log" 2>/dev/null || true
case "$1" in
  collection)
    case "$2" in
      add) : > "$HOME/.cache/qmd/index.sqlite" ;;
      remove) : ;;
    esac
    ;;
  cleanup) : ;;
  embed)  echo "✓ All content hashes already have embeddings" ;;
  status) echo "Pending: 0 need embedding" ;;
esac
exit 0
QS
  chmod +x "$_prefix/node_modules/.bin/qmd"

  python3 - "$D2/docker-compose.yml" <<'PY'
import sys
path = sys.argv[1]
txt = open(path).read()
needle = '      - ./:/workspace'
inject = '      - ./bin/claude:/usr/local/bin/claude:ro'
if inject not in txt:
    txt = txt.replace(needle, needle + '\n' + inject, 1)
open(path, 'w').write(txt)
PY

  (cd "$D2" && docker compose build)
  (cd "$D2" && docker compose up -d)
  in_container() { (cd "$D2" && docker compose exec -T -u agent "$N2" "$@"); }

  # boot must NOT have run collection setup (index.sqlite already existed) —
  # confirms the only path exercised below is the reindex-time migration.
  run in_container sh -c 'test -f "$HOME/.cache/qmd/.qmd-setup-ok" && echo RAN || echo SKIPPED'
  [[ "$output" == *"SKIPPED"* ]]

  # qmd_setup_if_needed and qmd_reindex share the SAME .reindex.lock
  # (non-blocking flock -n): the backgrounded boot-time setup check briefly
  # holds it just to confirm index.sqlite already exists and no-op. If this
  # manual reindex races that brief hold, it loses the lock, fail-silently
  # "skips" (exit 91 internally, wrapped to return 0), and no migration
  # happens THIS tick -- exit 0 alone does not prove the work ran. Retry
  # until the engine log actually shows a migration call.
  local retry_deadline=$(( $(date +%s) + 45 )) calls=""
  while [ "$(date +%s)" -lt "$retry_deadline" ]; do
    in_container /usr/local/bin/heartbeatctl qmd-reindex >/dev/null 2>&1
    calls=$(in_container sh -c 'cat "$HOME/.cache/qmd/engine-calls.log" 2>/dev/null')
    echo "$calls" | grep -q '^collection remove' && break
    sleep 2
  done
  if ! echo "$calls" | grep -q '^collection remove'; then
    echo "--- container logs ---" >&2
    (cd "$D2" && docker compose logs --tail=100 2>&1) >&2 || true
  fi
  # order: remove -> add (wiki/-only mask) -> update -> cleanup (sentinel
  # write happens between add/update and cleanup, in-process — not an engine
  # call, so it can't appear in this log; checked separately below).
  local remove_line add_line cleanup_line
  remove_line=$(echo "$calls" | grep -n '^collection remove' | head -1 | cut -d: -f1)
  add_line=$(echo "$calls" | grep -n -- '^collection add.*--mask wiki/\*\*/\*\.md' | head -1 | cut -d: -f1)
  cleanup_line=$(echo "$calls" | grep -n '^cleanup' | head -1 | cut -d: -f1)
  [ -n "$remove_line" ]
  [ -n "$add_line" ]
  [ -n "$cleanup_line" ]
  [ "$remove_line" -lt "$add_line" ]
  [ "$add_line" -lt "$cleanup_line" ]

  run in_container sh -c 'test -f "$HOME/.cache/qmd/.qmd-collection-wiki" && echo HAVE_SENTINEL'
  [[ "$output" == *"HAVE_SENTINEL"* ]]
  run in_container sh -c 'jq -r .migration /workspace/scripts/heartbeat/qmd-index.json'
  [ "$output" = "done" ]

  # a second tick must NOT migrate again (idempotent) — no new remove/add.
  local calls_before; calls_before=$(echo "$calls" | grep -c '^collection')
  run in_container /usr/local/bin/heartbeatctl qmd-reindex
  [ "$status" -eq 0 ]
  run in_container sh -c 'grep -c "^collection" "$HOME/.cache/qmd/engine-calls.log"'
  [ "$output" = "$calls_before" ]
}

# 037 T037 (Phase 4.5 extension): the SAME PARA fixture the host suite uses to
# oracle review_due/project_overdue/pending_ingest/etc. produces IDENTICAL
# counts inside the real container (proves docker awk/jq/date parity, not just
# the pre-037 six-count oracle above). Named COUNT_x markers, not positional
# fields — `docker compose exec` output ordering is not a contract.
@test "qmd e2e (037): vault-graph-para fixture yields host-identical PARA counts in-container" {
  local D3="$TMP_TEST_DIR/agent-qmd-para-e2e" N3="qmd-para-e2e"
  mkdir -p "$D3"
  cat > "$D3/agent.yml" <<YML
version: 1
agent: {name: $N3, display_name: "wiki-graph para e2e", role: "test", vibe: "terse"}
user: {name: "Tester", nickname: "Tester", timezone: "UTC", email: "t@e.x", language: "en"}
deployment: {host: "test", workspace: "$D3", install_service: false, claude_cli: "claude"}
docker: {image_tag: "agent-admin:wg-para-e2e", uid: $(id -u), gid: $(id -g), state_volume: "${N3}-state", base_image: "alpine:3.24.1"}
claude: {config_dir: "/home/agent/.claude", profile_new: true}
notifications: {channel: none}
features:
  heartbeat: {enabled: true, interval: "30m", timeout: 30, retries: 0, default_prompt: "echo pong"}
mcps: {defaults: [], atlassian: [], github: {enabled: false, email: ""}}
vault:
  enabled: true
  path: .state/.vault
  seed_skeleton: true
  initial_sources: []
  mcp: {enabled: true, server: vault}
  qmd: {enabled: false, version: "2.5.3", schedule: "*/5 * * * *"}
  schema: {frontmatter_required: true, log_format: "## [{date}] {op} | {title}"}
plugins: []
YML
  cp -R "$REPO_ROOT/modules" "$REPO_ROOT/scripts" "$REPO_ROOT/docker" "$D3/"
  cp "$REPO_ROOT/setup.sh" "$D3/"
  chmod +x "$D3/setup.sh"
  (cd "$D3" && ./setup.sh --regenerate --non-interactive)
  touch "$D3/.env"; chmod 0600 "$D3/.env"

  # Pre-seed the fixture BEFORE the first boot (same pattern as the vault
  # upgrade e2e test) rather than overlaying after boot: vault_seed_if_empty
  # only seeds an EMPTY target, so a pre-populated vault is never raced by
  # the container's own boot-time skeleton copy. `.state/` must exist first
  # so the bind-mount target is real (macOS gotcha).
  mkdir -p "$D3/.state/.vault"
  cp -R "$REPO_ROOT/tests/fixtures/vault-graph-para/." "$D3/.state/.vault/"

  mkdir -p "$D3/bin"
  cat > "$D3/bin/claude" <<'CL'
#!/bin/bash
exec sleep 86400
CL
  chmod +x "$D3/bin/claude"
  python3 - "$D3/docker-compose.yml" <<'PY'
import sys
path = sys.argv[1]
txt = open(path).read()
needle = '      - ./:/workspace'
inject = '      - ./bin/claude:/usr/local/bin/claude:ro'
if inject not in txt:
    txt = txt.replace(needle, needle + '\n' + inject, 1)
open(path, 'w').write(txt)
PY
  (cd "$D3" && docker compose build)
  (cd "$D3" && docker compose up -d)
  in_container() { (cd "$D3" && docker compose exec -T -u agent "$N3" "$@"); }

  # Wait for the /home/agent/vault SYMLINK, not just CLAUDE.md (already
  # present from the pre-seed) -- the symlink is the LAST step of
  # boot_side_effects's vault sequence (skeleton check -> additive-upgrade
  # check -> symlink), so its presence proves both checks already ran and
  # settled, closing the race a bare CLAUDE.md check would leave open (exec
  # can succeed before boot_side_effects runs at all).
  local deadline=$(( $(date +%s) + 60 )) ready=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    in_container test -L /home/agent/vault 2>/dev/null && { ready=1; break; }
    sleep 2
  done
  if [ "$ready" -ne 1 ]; then
    echo "--- container logs ---" >&2
    (cd "$D3" && docker compose logs --tail=80 2>&1) >&2 || true
  fi
  [ "$ready" -eq 1 ]
  # the pre-seeded fixture must have been left ALONE (vault_seed_if_empty
  # no-ops on a non-empty target) -- the vault-populated e2e test already
  # proves the additive-upgrade path separately; this just confirms no seed
  # clobber happened here.
  run in_container wc -c /home/agent/.vault/CLAUDE.md
  [[ "$output" == *"$(wc -c < "$REPO_ROOT/tests/fixtures/vault-graph-para/CLAUDE.md" | tr -d ' ')"* ]]

  run in_container env WIKI_GRAPH_TODAY=2030-06-15 /usr/local/bin/heartbeatctl wiki-graph
  [ "$status" -eq 0 ]
  # named marker per field (not positional output) -- each is its own jq call
  # against the SAME state file, so no multi-line quoting risk in the exec arg.
  _wg_count() {
    (cd "$D3" && docker compose exec -T -u agent "$N3" \
      jq -r ".counts.$1" /workspace/scripts/heartbeat/wiki-graph.json)
  }
  [ "$(_wg_count nodes)" = "21" ]
  [ "$(_wg_count edges)" = "9" ]
  [ "$(_wg_count project_incomplete)" = "1" ]
  [ "$(_wg_count project_overdue)" = "1" ]
  [ "$(_wg_count review_due)" = "2" ]
  [ "$(_wg_count pending_ingest)" = "1" ]
  [ "$(_wg_count description_missing)" = "3" ]
  [ "$(_wg_count problem_unfed)" = "2" ]
  [ "$(_wg_count packets)" = "1" ]
  [ "$(_wg_count para_project)" = "5" ]
}

# 041: the workspace of the real-qmd tests (`qmd real (016)` and `qmd real (041)`), as
# one helper instead of two copies (specs/041-nightly-qmd-embed/contracts/embed-test.md
# section 1). The qmd version comes from qmd_pkg(), the single source of the pin, and not
# from a literal nothing guarded (041 analysis C1).
_qmd_real_ws() {
  local D="$1" NAME="$2" TAG="$3" qver
  mkdir -p "$D"
  qver=$(source "$REPO_ROOT/scripts/lib/qmd_index.sh"; qmd_pkg "$D/none.yml")
  qver="${qver##*@}"
  # The schedule of the cron backstop is a date that never exists (31 February). These tests run
  # the reindex by hand, and a cron tick between the end of the setup and that call would take
  # the reindex lock: the manual reindex would lose it and a healthy run would turn red. The
  # --regenerate below warns that this form has no systemd equivalent; that matters only in local mode.
  cat > "$D/agent.yml" <<YML
version: 1
agent: {name: $NAME, display_name: "qmd real", role: "test", vibe: "terse"}
user: {name: "Tester", nickname: "Tester", timezone: "UTC", email: "t@e.x", language: "en"}
deployment: {host: "test", workspace: "$D", install_service: false, claude_cli: "claude"}
docker: {image_tag: "$TAG", uid: $(id -u), gid: $(id -g), state_volume: "${NAME}-state", base_image: "alpine:3.24.1"}
claude: {config_dir: "/home/agent/.claude", profile_new: true}
notifications: {channel: none}
features:
  heartbeat: {enabled: true, interval: "30m", timeout: 30, retries: 0, default_prompt: "echo pong"}
mcps: {defaults: [], atlassian: [], github: {enabled: false, email: ""}}
vault:
  enabled: true
  path: .state/.vault
  seed_skeleton: true
  initial_sources: []
  mcp: {enabled: true, server: vault}
  qmd: {enabled: true, version: "$qver", schedule: "0 0 31 2 *"}
  schema: {frontmatter_required: true, log_format: "## [{date}] {op} | {title}"}
plugins: []
YML
  cp -R "$REPO_ROOT/modules" "$REPO_ROOT/scripts" "$REPO_ROOT/docker" "$D/"
  cp "$REPO_ROOT/setup.sh" "$D/"; chmod +x "$D/setup.sh"
  (cd "$D" && ./setup.sh --regenerate --non-interactive)
  touch "$D/.env"; chmod 0600 "$D/.env"
  mkdir -p "$D/.state"   # macOS: absent .state breaks the /home/agent bind-mount
  # claude stub only — NO bunx stub (that's the whole point of these tests).
  mkdir -p "$D/bin"; printf '#!/bin/bash\nexec sleep 86400\n' > "$D/bin/claude"; chmod +x "$D/bin/claude"
  python3 - "$D/docker-compose.yml" <<'PY'
import sys
p=sys.argv[1]; t=open(p).read()
n='      - ./:/workspace'; inj='      - ./bin/claude:/usr/local/bin/claude:ro'
if inj not in t: t=t.replace(n, n+'\n'+inj, 1)
open(p,'w').write(t)
PY
  # The libc check of the vector extension runs INSIDE the container (busybox sh); the
  # workspace is bind-mounted as /workspace, so /workspace/.e2e/vec0-libc.sh is this copy.
  mkdir -p "$D/.e2e"
  cp "$REPO_ROOT/tests/fixtures/qmd-e2e/vec0-libc.sh" "$D/.e2e/vec0-libc.sh"
}

# 016: the des-stubbed, real-qmd test. Slow (native build + network). NOT executed
# in the authoring session (no Docker) — validate/adjust the exact qmd subcommand
# names against `qmd --help` in-container when the gate runs.
@test "qmd real (016): native deps compile with toolchain; RED without it (SC-003)" {
  local D="$TMP_TEST_DIR/agent-qmd-real" NAME="qmd-real"
  _qmd_real_ws "$D" "$NAME" "agent-admin:qmd-real"

  # ── GREEN build (toolchain on) + Tier 1 build-detector (Fase A) ──
  (cd "$D" && docker compose build)
  # bash entrypoint (NOT sh): qmd_index.sh sources backup_vault.sh, which uses bash
  # syntax — busybox sh would syntax-error. -u agent so the managed prefix lands
  # under the agent-owned .state.
  qr() { (cd "$D" && docker compose run --rm -T --entrypoint bash -u agent "$NAME" -lc "$1"); }
  # 017: the musl sqlite-vec build is baked under the toolchain gate — present + musl
  # (the npm prebuilt is glibc and cannot load on musl).
  run qr 'if [ -f /opt/agent-admin/sqlite-vec/vec0.so ] && ! strings /opt/agent-admin/sqlite-vec/vec0.so | grep -q GLIBC_; then echo VEC0_MUSL_OK; fi'
  echo "$output" | grep -q VEC0_MUSL_OK
  # 016/017: Fase A drives the PRODUCTION install path (_qmd_run / managed prefix),
  # NOT `bunx` directly — `bunx PKG` runs EVERY dep's install script, recompiling
  # tree-sitter and re-triggering BUG 4 on musl. `--help` proves the native install
  # (node-llama-cpp + better-sqlite3 compiled, tree-sitter left as WASM) produced a
  # working qmd binary, and _qmd_ensure_prefix ran the vec0 swap — no model download.
  run qr '. /opt/agent-admin/scripts/lib/qmd_index.sh; _qmd_run "$(qmd_pkg)" --help >/tmp/a 2>&1; echo "RC=$?"'
  echo "$output" | grep -q 'RC=0'
  run qr 'command -v cmake'
  [ "$status" -eq 0 ]                    # apk cmake present (not the glibc xpack)

  # The embed phase (Tier 2) lives in `qmd real (041)` since 041: it needs the models
  # fetched by .github/scripts/fetch-qmd-models.sh and reports "skipped" out loud when
  # it does not run, which a conditional block inside this test could not do.

  # ── RED: rebuild WITHOUT the toolchain → the native artifacts are gated off ─────
  # Both bigstack.so (016) and the musl sqlite-vec vec0.so (017) are produced ONLY
  # under QMD_NATIVE_TOOLCHAIN=1. Their ABSENCE is a deterministic, fast proof the
  # gate discriminates (SC-003, both directions: present in GREEN above, absent
  # here) — no compile / network / model, and no .state cache-carryover hazard.
  # Without the musl vec0, `qmd embed` cannot load the extension → semantic RAG is
  # unavailable, which is exactly the pre-017 failure mode.
  (cd "$D" && docker compose build --build-arg QMD_NATIVE_TOOLCHAIN=0)
  run qr 'if [ -f /opt/agent-admin/sqlite-vec/vec0.so ]; then echo PRESENT; else echo ABSENT; fi'
  echo "$output" | grep -q ABSENT
  run qr 'if [ -f /opt/agent-admin/bigstack.so ]; then echo PRESENT; else echo ABSENT; fi'
  echo "$output" | grep -q ABSENT
}

# 041: marks the start of a phase of the embed test as a TAP comment (fd 3). The last mark
# before a `not ok` names the phase that failed, with nothing to reproduce locally
# (research D9, FR-004). The names and their order are the ones of data-model section 4.
_embed_phase() { echo "# qmd embed phase: $1" >&3; }

# 041: a value that may span several lines (ls and find print one line per file) as TAP
# comments: every line needs its own '#', or the rest of the report is noise in the stream.
_embed_note() { printf '%s\n' "$1" | sed 's/^/#   /' >&3; }

# 041: the last lines of a command's output, for a report. A negative substring offset is NOT used:
# it is EMPTY when the value is shorter than the offset, in bash 3.2 and 5.x alike (measured).
_embed_tail() { printf '%s\n' "$1" | tail -n "${2:-12}"; }

# 041: the embed phase of the real qmd (the old Tier 2 of `qmd real (016)`): first boot
# with its setup, vector extension, reindex, semantic search and the MCP server, against
# the models the nightly fetched beforehand (.github/scripts/fetch-qmd-models.sh). It is a
# test of its own so that "not executed" is a skip with a reason in the TAP stream and in
# the `e2e summary:` line, never a silent green.
@test "qmd real (041): embed phase - setup, models, vector extension, reindex, semantic search, MCP" {
  # The gate is the first thing this test does, and it never calls docker or curl. A closed
  # gate, or an open defect named by the fetch step, is a skip that carries its reason; an
  # open gate without the models is a harness error and fails, naming the variable.
  if [ "${QMD_EMBED_E2E:-0}" != "1" ]; then
    skip "${QMD_EMBED_SKIP_REASON:-embed phase needs QMD_EMBED_E2E=1 and the models fetched by .github/scripts/fetch-qmd-models.sh (about 1.6 GB)}"
  fi
  if [ -n "${QMD_EMBED_SKIP_REASON:-}" ]; then
    skip "$QMD_EMBED_SKIP_REASON"
  fi
  if [ -z "${QMD_E2E_MODELS_DIR:-}" ]; then
    echo "# QMD_E2E_MODELS_DIR is required with QMD_EMBED_E2E=1: run .github/scripts/fetch-qmd-models.sh first" >&3
    false
  fi

  local D="$TMP_TEST_DIR/agent-qmd-embed" NAME="qmd-embed"
  _qmd_real_ws "$D" "$NAME" "agent-admin:qmd-embed"

  _embed_phase models-seed
  # The models the fetch step verified go into the directory qmd reads, under the name it
  # looks for, so qmd uses them with no network (research D2). Hard links when both
  # directories share a filesystem (no second copy of 1.6 GB), a copy otherwise. The step
  # only leaves verified files there; if one is missing, qmd would download it inside the
  # container and models-untouched names exactly that.
  local mdir="$D/.state/.cache/qmd/models" f seeded=0 seeded_list
  mkdir -p "$mdir" "$D/.e2e"
  for f in "$QMD_E2E_MODELS_DIR"/*.gguf; do
    if [ ! -f "$f" ]; then continue; fi
    ln "$f" "$mdir/${f##*/}" 2>/dev/null || cp "$f" "$mdir/${f##*/}"
    seeded=$((seeded + 1))
  done
  if [ "$seeded" -lt 1 ]; then
    echo "# models-seed: no *.gguf in QMD_E2E_MODELS_DIR" >&3
    false
  fi
  seeded_list="$(ls -iA "$mdir")"
  touch "$D/.e2e/seed-marker"

  _embed_phase boot
  # The vault the agent boots with. qmd's collection covers wiki/**/*.md only (since 037) and
  # the skeleton ships wiki/ empty, so a page at the vault root, where the Tier 2 of 016 wrote
  # its document, is never indexed: the semantic search below could not find it with a healthy
  # product, and the first-boot setup would have nothing to embed. The vault is pre-seeded
  # BEFORE the first boot, the way the PARA e2e test does it (vault_seed_if_empty never touches
  # a vault that has content), with the skeleton plus one page under wiki/, so that the setup
  # embeds a real page and exercises the models and the vector extension right there.
  mkdir -p "$D/.state/.vault"
  cp -R "$REPO_ROOT/modules/vault-skeleton/." "$D/.state/.vault/"
  printf -- '---\ntitle: computadores\n---\nUn computador portatil tiene teclado, pantalla y bateria.\n' > "$D/.state/.vault/wiki/concepts/computadores.md"
  (cd "$D" && docker compose build)
  (cd "$D" && docker compose up -d)
  inc() { (cd "$D" && docker compose exec -T -u agent "$NAME" "$@"); }
  # qmd turns embed, query expansion and rerank off when CI has a value (llm.js:384), and it
  # reads its models from $XDG_CACHE_HOME/qmd/models. Either one different from what the seed
  # assumes would fail the phases below with a message that looks like a regression, so both
  # are checked here, inside the container, as the agent user.
  run inc sh -c 'if [ -n "${CI:-}" ]; then echo "CI is set (CI=${CI}): qmd turns embed and query expansion off"; exit 1; fi; x="${XDG_CACHE_HOME:-}"; if [ -n "$x" ] && [ "$x" != "$HOME/.cache" ]; then echo "XDG_CACHE_HOME=$x is not \$HOME/.cache: qmd would not find the seeded models"; exit 2; fi'
  if [ "$status" -ne 0 ]; then
    echo "# boot: $output" >&3
    false
  fi

  _embed_phase setup
  # First-boot setup (collection add + update + embed) runs backgrounded under the
  # SAME flock reindex uses. Wait for its sentinel before touching the index —
  # otherwise our reindex just loses the lock (exit 91) and writes nothing. The
  # embed here already exercises vec0 end-to-end; a glibc prebuilt would make it
  # fail with "sqlite-vec extension is unavailable" and no sentinel would appear.
  # The wait ends the moment the container log says a step of the setup failed: waiting
  # out the whole deadline to then say "setup did not complete" costs minutes and hides
  # which step it was (research D11). The deadline includes the native compile of
  # llama.cpp, which this test pays in its own state directory.
  local sdl="${QMD_E2E_SETUP_DEADLINE_S:-600}" sdeadline setup_done=0 sfail
  # whole seconds from 1 to 3600; a leading zero ('08', '010') must not be read as octal by $(( ))
  case "$sdl" in ''|*[!0-9]*|?????*) sdl=600 ;; *) sdl=$((10#$sdl)) ;; esac
  if [ "$sdl" -le 0 ] || [ "$sdl" -gt 3600 ]; then sdl=600; fi
  sdeadline=$(( $(date +%s) + sdl ))
  while [ "$(date +%s)" -lt "$sdeadline" ]; do
    if inc sh -c 'test -f "$HOME/.cache/qmd/.qmd-setup-ok"' 2>/dev/null; then setup_done=1; break; fi
    (cd "$D" && docker compose logs --no-color > "$D/.e2e/compose.log" 2>&1) || true
    sfail="$(grep -E -m1 "\[qmd\] (setup: '[^']+' (failed|timed out)|install: bun install failed)" "$D/.e2e/compose.log" || true)"
    if [ -n "$sfail" ]; then
      echo "# setup: the container log reports a failure: $sfail" >&3
      false
    fi
    sleep 5
  done
  if [ "$setup_done" -ne 1 ]; then
    echo "# setup: .qmd-setup-ok did not appear within ${sdl}s" >&3
    false
  fi
  # The models were seeded before the boot, so this only proves that the container sees them
  # through the bind mount; what proves the setup is the sentinel above.
  run inc sh -c 'ls "$HOME/.cache/qmd/models/"*.gguf 2>/dev/null && echo HAVE_MODEL'
  echo "$output" | grep -q HAVE_MODEL

  _embed_phase vector-extension
  # 017: the swap must have put a MUSL vec0 in the managed prefix (not the glibc prebuilt).
  # vec0-libc.sh looks at whichever sqlite-vec-linux-* package the install laid down, for any
  # CPU, and an absent file fails instead of passing: the check it replaces looked at one
  # architecture only and printed MUSL when there was nothing to look at (FR-003).
  run inc sh -c 'sh /workspace/.e2e/vec0-libc.sh "$HOME/.cache/qmd/pkg"'
  if [ "$status" -ne 0 ]; then
    echo "# vector-extension: vec0-libc.sh says '$output' (rc $status)" >&3
    false
  fi
  [ "${output%% *}" = "MUSL" ]

  _embed_phase reindex
  # 017 (SC-001): a SEMANTIC query returns the right doc — vec0 stores/retrieves
  # vectors and the query embeds too. Add a distinct doc UNDER wiki/ (the only part of the
  # vault the collection covers), reindex (the lock is free now setup is done), and assert
  # last_status=indexed (only reachable if vec0 LOADED — a glibc prebuilt → "sqlite-vec
  # unavailable" → embed error).
  inc sh -c 'printf -- "---\ntitle: gatos\n---\nEl gato duerme sobre el teclado del computador.\n" > /home/agent/.vault/wiki/concepts/gatos.md'
  # Bounded inside the container, with its output in a file: a reindex that hangs must end THIS
  # phase with its name (a job cancelled by its cap names nothing and loses the rest of the
  # suite), and a child that outlives the timeout cannot hold the pipe of docker exec open.
  # Measured on busybox 1.37 (Alpine 3.24): a plain timeout sends TERM only, so a child that
  # ignores it blocks the timeout as long as the child lives, and -k 10 adds the KILL; the exit
  # status is 143 after TERM and 137 after KILL (GNU timeout would say 124).
  local t0=$SECONDS
  run inc sh -c 'timeout -k 10 600 /usr/local/bin/heartbeatctl qmd-reindex > /tmp/qmd-reindex.out 2>&1; rc=$?; cat /tmp/qmd-reindex.out; exit $rc'
  if [ "$status" -eq 124 ] || [ "$status" -eq 137 ] || [ "$status" -eq 143 ]; then
    _embed_note "reindex: qmd-reindex did not finish in 600s (rc $status after $((SECONDS - t0))s; a 137 long before the limit is a kill from outside, see oom= in the failure state). Last lines of its output:"$'\n'"$(_embed_tail "$output" 12)"
    false
  fi
  [ "$status" -eq 0 ]
  run inc sh -c 'jq -r .last_status /workspace/scripts/heartbeat/qmd-index.json'
  echo "$output" | grep -qE 'ok|indexed'
  # 018: a small e2e vault embeds within a single pass, so the completion
  # loop drives pending to 0 in this run (not the multi-pass scenario a
  # multi-thousand-chunk vault needs — that is the ferrari hardware gate).
  run inc sh -c 'jq -r .pending /workspace/scripts/heartbeat/qmd-index.json'
  [ "$output" = "0" ]

  _embed_phase semantic-search
  # Preload bigstack (query embedding hits the same musl std::regex/stack guard the
  # MCP uses) and run qmd from the prefix. The semantic query has no lexical overlap, and
  # vsearch also loads the query-expansion model, which was seeded like the embeddings one.
  # The one call that loads both models into CPU memory: bounded like the reindex, for the same
  # reasons. env and not a prefix assignment, so that LD_PRELOAD reaches qmd and not timeout.
  t0=$SECONDS
  run inc bash -lc 's="$HOME/.cache/qmd/tmp"; mkdir -p "$s"; . /opt/agent-admin/scripts/lib/qmd_index.sh; timeout -k 10 300 env LD_PRELOAD="$QMD_BIGSTACK_SO" TMPDIR="$s" "$(_qmd_prefix)/node_modules/.bin/qmd" vsearch "animal encima del pc" > "$s/vsearch.out" 2>&1; rc=$?; cat "$s/vsearch.out"; exit $rc'
  if [ "$status" -eq 124 ] || [ "$status" -eq 137 ] || [ "$status" -eq 143 ]; then
    _embed_note "semantic-search: vsearch did not finish in 300s (rc $status after $((SECONDS - t0))s; a 137 long before the limit is a kill from outside, see oom= in the failure state). Last lines of its output:"$'\n'"$(_embed_tail "$output" 12)"
    false
  fi
  echo "$output" | grep -qi 'gato'

  _embed_phase mcp
  # 016 T036: the MCP server (Claude's search reader) launches from the SAME managed
  # prefix, via the wrapper, NOT bunx. Feed EOF + a short timeout and assert it
  # started without a native-build/bunx/missing-binary failure (BUG-4 signatures).
  # if+false so the check is subject to set -e (a bare `! ... | grep` never fails).
  inc test -x /opt/agent-admin/scripts/qmd-mcp
  run inc sh -lc 'timeout 25 /opt/agent-admin/scripts/qmd-mcp </dev/null >/tmp/m 2>&1; cat /tmp/m'
  if echo "$output" | grep -qiE 'tree-sitter.*exited with|node-gyp|cannot find module|bunx|no such file'; then
    echo "MCP start showed a BUG-4 signature: $output" >&2
    false
  fi

  _embed_phase models-untouched
  # qmd must have used the seeded models as they are: the same files with the same inodes,
  # nothing new beside them (a half-finished download would show here) and nothing rewritten
  # since the seed marker. A model that qmd had to fetch itself is a failure of the fetch
  # step's contract (FR-007), not a pass.
  local now_list newer
  now_list="$(ls -iA "$mdir")"
  newer="$(find "$mdir" -type f -newer "$D/.e2e/seed-marker")"
  if [ "$now_list" != "$seeded_list" ] || [ -n "$newer" ]; then
    echo "# models-untouched: qmd downloaded or rewrote a model inside the container" >&3
    _embed_note "seeded: $seeded_list"
    _embed_note "now:    $now_list"
    _embed_note "newer than the seed marker: ${newer:-none}"
    false
  fi

  # Not an assertion: what this run cost in disk and memory, for the evidence record
  # (data-model section 6). memory.peak is the cgroup v2 high-water mark of the container.
  local disk_kb mem_peak
  disk_kb="$(df -Pk "$D" | awk 'END {print $4}')"
  mem_peak="$(inc sh -c 'cat /sys/fs/cgroup/memory.peak 2>/dev/null || echo unknown' 2>/dev/null || echo unknown)"
  echo "# qmd embed resources: disk_free_kb=$disk_kb mem_peak_bytes=$mem_peak" >&3
  (cd "$D" && docker compose down -v --remove-orphans || true)
}
