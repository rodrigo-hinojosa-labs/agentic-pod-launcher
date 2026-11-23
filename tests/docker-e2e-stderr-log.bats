#!/usr/bin/env bats
#
# 049 DOCKER_E2E: the image-baked patcher upgrades a fleet plugin (stderr-capture v1) to v2,
# and the v2 block, run by the image's own bun (musl), cuts the EPIPE loop of #139 and keeps
# the log under its cap. Skipped by default (needs a docker daemon). Enable with DOCKER_E2E=1.
# Contracts: specs/049-telegram-stderr-log-bound/contracts/{stderr-hook-v2,patcher-stderr-upgrade}.md
#
# SELF-SEEDING, like tests/docker-e2e-voice.bats: the image ships no plugin (it is installed
# after login), so every case copies a committed fixture into the plugin cache path and runs
# the image-baked patcher on it. The block under test is extracted from that same baked
# patcher by import, never retyped. Bodies are single-quoted `-c '...'` strings, every bun
# runs under `timeout -k 10` (busybox timeout sends TERM only without -k), and a killed bun
# shows up as 124, 137 or 143.

load helper

setup() {
  if [ "${DOCKER_E2E:-0}" != "1" ]; then
    skip "set DOCKER_E2E=1 to run (requires a docker daemon)"
  fi
  command -v docker >/dev/null 2>&1 || skip "docker not on PATH"
  docker info >/dev/null 2>&1 || skip "docker daemon not reachable"
  TMPDIR=/tmp setup_tmp_dir
  mkdir -p "$TMP_TEST_DIR/installer"
  cp -r "$REPO_ROOT/scripts" "$REPO_ROOT/modules" "$REPO_ROOT/docker" "$TMP_TEST_DIR/installer/"
  cp "$REPO_ROOT/setup.sh" "$TMP_TEST_DIR/installer/"
  [ -f "$REPO_ROOT/.gitignore" ] && cp "$REPO_ROOT/.gitignore" "$TMP_TEST_DIR/installer/"
  [ -f "$REPO_ROOT/LICENSE" ] && cp "$REPO_ROOT/LICENSE" "$TMP_TEST_DIR/installer/"

  cd "$TMP_TEST_DIR/installer"
  E2E_AGENT_DIR="$TMP_TEST_DIR/agent"; export E2E_AGENT_DIR
  wizard_answers name=stderrbot display=StderrBot | ./setup.sh --destination "$E2E_AGENT_DIR"
  [ -f "$E2E_AGENT_DIR/docker-compose.yml" ]
  cd "$E2E_AGENT_DIR"
  cat > "$E2E_AGENT_DIR/.env" <<'ENV'
TELEGRAM_BOT_TOKEN=00000:fake
TELEGRAM_CHAT_ID=0
ENV
  chmod 0600 "$E2E_AGENT_DIR/.env"

  mkdir -p "$E2E_AGENT_DIR/.e2e"
  cp "$REPO_ROOT/tests/fixtures/telegram-server-patched-v034.ts" "$E2E_AGENT_DIR/.e2e/"
  cp "$REPO_ROOT/tests/fixtures/stderr-hook/vendor-handlers.ts" "$E2E_AGENT_DIR/.e2e/"

  # Seeds the 0.34.0 golden (stderr v1, as on every fleet plugin) and runs the baked patcher.
  cat > "$E2E_AGENT_DIR/.e2e/seed.sh" <<'SEED'
#!/bin/sh
set -e
d="$HOME/.claude/plugins/cache/claude-plugins-official/telegram/0.0.7"
mkdir -p "$d"
cp /workspace/.e2e/telegram-server-patched-v034.ts "$d/server.ts"
python3 /opt/agent-admin/scripts/apply_telegram_typing_patch.py "$d/server.ts" > /tmp/patch.log 2>&1
echo "$d/server.ts"
SEED

  # build.sh <V1|V2> <out.ts> <log>: the block from the BAKED patcher, log path replaced.
  cat > "$E2E_AGENT_DIR/.e2e/build.py" <<'PY'
import importlib.util, json, sys
which, out, log = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("p", "/opt/agent-admin/scripts/apply_telegram_typing_patch.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
block = mod.STDERR_HOOK_V1 if which == "V1" else mod.STDERR_HOOK
prod = "'/workspace/scripts/heartbeat/logs/telegram-mcp-stderr.log'"
assert block.count(prod) == 1
open(out, "w").write(block.replace(prod, json.dumps(log)))
PY

  cat > "$E2E_AGENT_DIR/.e2e/loop.ts" <<'TS'
setTimeout(() => { process.stderr.write('telegram channel: first write\n') }, 300)
setTimeout(() => {
  try { require('node:fs').writeFileSync('/tmp/exited', 'exited\n') } catch {}
  process.exit(0)
}, 1200)
TS
  cat > "$E2E_AGENT_DIR/.e2e/writes.ts" <<'TS'
for (let i = 0; i < 100000; i++) process.stderr.write('x'.repeat(40) + String(i).padStart(7, '0') + '\n')
TS

  run docker compose build
  [ "$status" -eq 0 ]
}

teardown() {
  if [ -n "${E2E_AGENT_DIR:-}" ] && [ -d "$E2E_AGENT_DIR" ]; then
    (cd "$E2E_AGENT_DIR" && docker compose down -v --remove-orphans 2>/dev/null || true)
  fi
  teardown_tmp_dir
}

@test "E2E 049: the baked patcher upgrades the 0.34.0 golden to stderr v2, and a second run is a logged no-op" {
  run docker compose run --rm -T --user agent --entrypoint sh stderrbot -c '
    set -e
    server=$(sh /workspace/.e2e/seed.sh)
    cat /tmp/patch.log
    echo "V2COUNT=$(grep -c "agentic-pod-launcher: stderr-capture patch v2" "$server" || true)"
    echo "V1COUNT=$(grep -c "agentic-pod-launcher: stderr-capture patch v1" "$server" || true)"
    sha1=$(sha256sum "$server" | cut -d" " -f1)
    python3 /opt/agent-admin/scripts/apply_telegram_typing_patch.py "$server"
    sha2=$(sha256sum "$server" | cut -d" " -f1)
    [ "$sha1" = "$sha2" ]
    bun build --no-bundle "$server" --outfile /tmp/server.js > /dev/null
    echo "PARSE=ok"
    bun --version | sed "s/^/BUN=/"
  '
  echo "$output"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'stderr-upgrade-v1→v2'
  echo "$output" | grep -qx 'V2COUNT=1'
  echo "$output" | grep -qx 'V1COUNT=0'
  echo "$output" | grep -qF 'all patch groups already present'
  echo "$output" | grep -qx 'PARSE=ok'
  echo "$output" | grep -E '^(BUN|V[12]COUNT)=' | sed 's/^/# /' >&3
}

@test "E2E 049: under the image's bun, v1 loops on a closed stderr and v2 cuts it with one notice" {
  run docker compose run --rm -T --user agent --entrypoint sh stderrbot -c '
    cd /tmp
    for leg in V1 V2; do
      rm -f /tmp/exited /tmp/log-$leg
      python3 /workspace/.e2e/build.py $leg /tmp/h1-$leg.ts /tmp/log-$leg
      cat /workspace/.e2e/vendor-handlers.ts /workspace/.e2e/loop.ts >> /tmp/h1-$leg.ts
      timeout -k 10 3 bun /tmp/h1-$leg.ts 2>&1 >/dev/null | true
      size=$(wc -c < /tmp/log-$leg | tr -d " ")
      if [ -f /tmp/exited ]; then ex=yes; else ex=no; fi
      closed=$(grep -c "\[stderr-closed\] EPIPE - forwarding to stderr stopped, log only" /tmp/log-$leg || true)
      loops=$(grep -c "telegram channel: uncaught exception: Error: EPIPE" /tmp/log-$leg || true)
      echo "$leg size=$size exited=$ex closed=$closed loops=$loops"
      rm -f /tmp/log-$leg
    done
  '
  echo "$output"
  [ "$status" -eq 0 ]
  local v1 v2
  v1=$(echo "$output" | grep '^V1 ')
  v2=$(echo "$output" | grep '^V2 ')
  printf '# %s\n# %s\n' "$v1" "$v2" >&3
  # v1: the loop of #139 reproduces in the image (log past 1 MB in 3 s, exit timer starved).
  echo "$v1" | grep -q 'exited=no'
  [ "$(echo "$v1" | sed -E 's/.*size=([0-9]+).*/\1/')" -gt 1048576 ]
  # v2: one notice, no EPIPE report, and the exit timer ran.
  echo "$v2" | grep -q 'exited=yes closed=1 loops=0'
}

@test "E2E 049: under the image's bun, 100000 writes with U=100000 stay under 3U + 3 writes" {
  run docker compose run --rm -T --user agent -e TELEGRAM_STDERR_LOG_MAX_BYTES=100000 --entrypoint sh stderrbot -c '
    set -e
    mkdir -p /tmp/h4
    python3 /workspace/.e2e/build.py V2 /tmp/h4.ts /tmp/h4/log
    cat /workspace/.e2e/writes.ts >> /tmp/h4.ts
    timeout -k 10 60 bun /tmp/h4.ts 2>/dev/null >/dev/null
    total=0
    for f in /tmp/h4/log /tmp/h4/log.1 /tmp/h4/log.2; do
      [ -f "$f" ] && total=$((total + $(wc -c < "$f")))
    done
    echo "TOTAL=$total"
    echo "FILES=$(ls /tmp/h4 | tr "\n" " ")"
    echo "LAST=$(tail -1 /tmp/h4/log | cut -c41-)"
  '
  echo "$output"
  [ "$status" -eq 0 ]
  local total
  total=$(echo "$output" | sed -n 's/^TOTAL=//p')
  echo "# TOTAL=$total" >&3
  [ "$total" -lt $((300000 + 3 * 48)) ]
  echo "$output" | grep -qx 'FILES=log log.1 log.2 '
  echo "$output" | grep -qx 'LAST=0099999'
}
