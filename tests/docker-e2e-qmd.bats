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
# The real @tobilu/qmd engine + its ~300 MB model download are NOT exercised
# (network-gated, slow, flaky) — `bunx` is stubbed so the orchestration, the
# real filesystem-event delivery, real flock, and the cap set are what get
# proven. Mirrors tests/docker-e2e-vault.bats (claude stub, compose-run gotchas).
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
  if [ -d "$DEST" ]; then
    (cd "$DEST" && docker compose down -v --remove-orphans || true)
  fi
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
  #    session. bunx: fast no-op that fakes index.sqlite on `collection add`, so
  #    qmd_setup_if_needed completes without the real 300 MB model download.
  mkdir -p "$DEST/bin"
  cat > "$DEST/bin/claude" <<'CL'
#!/bin/bash
exec sleep 86400
CL
  cat > "$DEST/bin/bunx" <<'BX'
#!/bin/sh
# qmd e2e stub for @tobilu/qmd: log calls, fake the index on `collection add`,
# exit 0 fast for collection/update/embed. (mcp is only launched by claude,
# which is itself stubbed, so it never runs here.)
mkdir -p "$HOME/.cache/qmd" 2>/dev/null || true
echo "$*" >> "$HOME/.cache/qmd/bunx-calls.log" 2>/dev/null || true
case "$2" in
  collection) : > "$HOME/.cache/qmd/index.sqlite" ;;
esac
exit 0
BX
  chmod +x "$DEST/bin/claude" "$DEST/bin/bunx"

  # 4) bind-mount both stubs into the container over the real binaries.
  python3 - "$DEST/docker-compose.yml" <<'PY'
import sys
path = sys.argv[1]
txt = open(path).read()
needle = '      - ./:/workspace'
for inject in (
    '      - ./bin/claude:/usr/local/bin/claude:ro',
    '      - ./bin/bunx:/usr/local/bin/bunx:ro',
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
    echo "--- bunx calls ---" >&2
    in_container sh -c 'cat "$HOME/.cache/qmd/bunx-calls.log" 2>&1' >&2 || true
  fi
  [ "$setup_ok" -eq 1 ]
  # setup must have run the full add → update → embed sequence
  run in_container sh -c 'cat "$HOME/.cache/qmd/bunx-calls.log"'
  [[ "$output" == *"collection add"* ]]
  [[ "$output" == *"update"* ]]
  [[ "$output" == *"embed"* ]]

  # ── Phase 2: wiring — watcher alive, cron line present, inotifywait installed ─
  run in_container sh -c 'pgrep -f qmd_watch.sh >/dev/null && echo WATCHER_UP'
  [[ "$output" == *"WATCHER_UP"* ]]
  # The */5 backstop line reaches /etc/crontabs/agent via entrypoint's root
  # crontab-sync loop, which polls every 15s. The bunx stub makes first-boot
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

  # 013 FR-016: `bunx` MUST exist in the REAL image (not via the PATH stub the
  # pipeline uses) — the qmd MCP + qmd_index.sh call it. Assert the absolute path
  # so the stub can't mask a missing symlink like it did before this feature.
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
  if [ "$(uname -s)" = "Linux" ]; then
    # Production/CI semantics: the inotify seam MUST fire (Principle II evidence).
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
