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
#   Tier 2 (embed)   : gated by QMD_EMBED_E2E=1 — a real reindex (update + embed)
#                      downloads the model; embed SUCCEEDS only if vec0 loaded (017),
#                      and a semantic vsearch returns the right doc (SC-001).
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

teardown() {
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

# 016: the des-stubbed, real-qmd test. Slow (native build + network). NOT executed
# in the authoring session (no Docker) — validate/adjust the exact qmd subcommand
# names against `qmd --help` in-container when the gate runs.
@test "qmd real (016): native deps compile with toolchain; RED without it (SC-003)" {
  local D="$TMP_TEST_DIR/agent-qmd-real" NAME="qmd-real"
  mkdir -p "$D"
  cat > "$D/agent.yml" <<YML
version: 1
agent: {name: $NAME, display_name: "qmd real", role: "test", vibe: "terse"}
user: {name: "Tester", nickname: "Tester", timezone: "UTC", email: "t@e.x", language: "en"}
deployment: {host: "test", workspace: "$D", install_service: false, claude_cli: "claude"}
docker: {image_tag: "agent-admin:qmd-real", uid: $(id -u), gid: $(id -g), state_volume: "${NAME}-state", base_image: "alpine:3.24.1"}
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
  cp -R "$REPO_ROOT/modules" "$REPO_ROOT/scripts" "$REPO_ROOT/docker" "$D/"
  cp "$REPO_ROOT/setup.sh" "$D/"; chmod +x "$D/setup.sh"
  (cd "$D" && ./setup.sh --regenerate --non-interactive)
  touch "$D/.env"; chmod 0600 "$D/.env"
  mkdir -p "$D/.state"   # macOS: absent .state breaks the /home/agent bind-mount
  # claude stub only — NO bunx stub (that's the whole point of this test).
  mkdir -p "$D/bin"; printf '#!/bin/bash\nexec sleep 86400\n' > "$D/bin/claude"; chmod +x "$D/bin/claude"
  python3 - "$D/docker-compose.yml" <<'PY'
import sys
p=sys.argv[1]; t=open(p).read()
n='      - ./:/workspace'; inj='      - ./bin/claude:/usr/local/bin/claude:ro'
if inj not in t: t=t.replace(n, n+'\n'+inj, 1)
open(p,'w').write(t)
PY

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

  # ── Tier 2 (embed): real reindex downloads the model — gated + slow ──
  if [ "${QMD_EMBED_E2E:-0}" = "1" ]; then
    (cd "$D" && docker compose up -d)
    inc() { (cd "$D" && docker compose exec -T -u agent "$NAME" "$@"); }
    # First-boot setup (collection add + update + embed) runs backgrounded under the
    # SAME flock reindex uses. Wait for its sentinel before touching the index —
    # otherwise our reindex just loses the lock (exit 91) and writes nothing. The
    # embed here already exercises vec0 end-to-end; a glibc prebuilt would make it
    # fail with "sqlite-vec extension is unavailable" and no sentinel would appear.
    local sdeadline=$(( $(date +%s) + 600 )) setup_done=0
    while [ "$(date +%s)" -lt "$sdeadline" ]; do
      if inc sh -c 'test -f "$HOME/.cache/qmd/.qmd-setup-ok"' 2>/dev/null; then setup_done=1; break; fi
      sleep 5
    done
    if [ "$setup_done" -ne 1 ]; then
      echo "--- setup did not complete; container logs ---" >&2
      (cd "$D" && docker compose logs --tail=120 2>&1) >&2 || true
    fi
    [ "$setup_done" -eq 1 ]
    run inc sh -c 'ls "$HOME/.cache/qmd/models/"*.gguf 2>/dev/null && echo HAVE_MODEL'
    echo "$output" | grep -q HAVE_MODEL
    # 017: the swap put a MUSL vec0 in the managed prefix (not the glibc prebuilt).
    run inc bash -lc 'f="$HOME/.cache/qmd/pkg/node_modules/sqlite-vec-linux-arm64/vec0.so"; if strings "$f" | grep -q GLIBC_; then echo GLIBC; else echo MUSL; fi'
    echo "$output" | grep -q MUSL
    # 017 (SC-001): a SEMANTIC query returns the right doc — vec0 stores/retrieves
    # vectors and the query embeds too. Add a distinct doc, reindex (the lock is free
    # now setup is done), and assert last_status=indexed (only reachable if vec0
    # LOADED — a glibc prebuilt → "sqlite-vec unavailable" → embed error).
    inc sh -c 'printf -- "---\ntitle: gatos\n---\nEl gato duerme sobre el teclado del computador.\n" > /home/agent/.vault/gatos.md'
    run inc /usr/local/bin/heartbeatctl qmd-reindex
    [ "$status" -eq 0 ]
    run inc sh -c 'jq -r .last_status /workspace/scripts/heartbeat/qmd-index.json'
    echo "$output" | grep -qE 'ok|indexed'
    # 018: a small e2e vault embeds within a single pass, so the completion
    # loop drives pending to 0 in this run (not the multi-pass scenario a
    # multi-thousand-chunk vault needs — that is the ferrari hardware gate).
    run inc sh -c 'jq -r .pending /workspace/scripts/heartbeat/qmd-index.json'
    [ "$output" = "0" ]
    # Preload bigstack (query embedding hits the same musl std::regex/stack guard the
    # MCP uses) and run qmd from the prefix. The semantic query has no lexical overlap.
    run inc bash -lc 's="$HOME/.cache/qmd/tmp"; mkdir -p "$s"; . /opt/agent-admin/scripts/lib/qmd_index.sh; LD_PRELOAD="$QMD_BIGSTACK_SO" TMPDIR="$s" "$(_qmd_prefix)/node_modules/.bin/qmd" vsearch "animal encima del pc" 2>&1'
    echo "$output" | grep -qi 'gato'
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
    (cd "$D" && docker compose down -v --remove-orphans || true)
  fi

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
