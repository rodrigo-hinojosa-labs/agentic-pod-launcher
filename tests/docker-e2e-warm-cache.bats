#!/usr/bin/env bats
#
# 030 DOCKER_E2E — the boot warm cache actually makes an overlay-shaped MCP
# resolvable offline. Skipped by default (needs a docker daemon + network for the
# build; the offline proof itself uses uv's offline flag, not a namespace cut —
# `docker compose run` has no --network). Enable with DOCKER_E2E=1.
# Contract: specs/030-mcp-warm-cache/contracts/docker-e2e-tiers.md
#
# Deferred: not run in this environment (no docker daemon). Ships ready for the
# Docker-host gate (tasks.md T025). The ferrari hardware gate (recreate donna with
# PyPI cut → google-workspace connects) is the separate SC-001 gate (T026).

load helper

setup() {
  if [ "${DOCKER_E2E:-0}" != "1" ]; then
    skip "set DOCKER_E2E=1 to run (requires a docker daemon + network)"
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
  wizard_answers name=warmbot display=WarmBot | ./setup.sh --destination "$E2E_AGENT_DIR"
  [ -f "$E2E_AGENT_DIR/docker-compose.yml" ]
  # scaffold runs the mirror → the image lib must be present for the COPY.
  [ -f "$E2E_AGENT_DIR/docker/scripts/lib/mcp_warm.sh" ]
  cat > "$E2E_AGENT_DIR/.env" <<'ENV'
TELEGRAM_BOT_TOKEN=00000:fake
TELEGRAM_CHAT_ID=0
ENV
  chmod 0600 "$E2E_AGENT_DIR/.env"
  cd "$E2E_AGENT_DIR"
  run docker compose build
  [ "$status" -eq 0 ]
}

teardown() {
  if [ -n "${E2E_AGENT_DIR:-}" ] && [ -d "$E2E_AGENT_DIR" ]; then
    (cd "$E2E_AGENT_DIR" && docker compose down -v --remove-orphans 2>/dev/null || true)
  fi
  teardown_tmp_dir
}

# ── E1/E2/E4: warm covers the wrapper-shaped uvx MCP; offline before/after ───

@test "E2E 030: mcp_warm_run makes an overlay wrapper MCP (workspace-mcp) resolvable offline" {
  # A throwaway container as `agent` (root can't read the agent-owned /opt/uv).
  # 1. workspace-mcp is NOT baked by the build (only the catalog is) → cold (E2/E4 RED).
  # 2. derive+warm from a crafted .mcp.json using the WRAPPER shape (command=seed.sh,
  #    args=[uvx, workspace-mcp]) — the exact case the old selector missed.
  # 3. after the warm, workspace-mcp is installed and resolves offline (E1 GREEN).
  run docker compose run --rm -T --user agent --entrypoint sh warmbot -c '
    set -e
    echo "COLD=$(uv tool list 2>&1 | grep -c workspace-mcp || true)"
    mkdir -p /tmp/w
    cat > /tmp/w/.mcp.json <<JSON
{ "mcpServers": {
  "gws":   { "command": "/tmp/w/seed-google-creds.sh", "args": ["uvx", "workspace-mcp"] },
  "fetch": { "command": "uvx", "args": ["mcp-server-fetch"] } } }
JSON
    . /opt/agent-admin/scripts/lib/mcp_warm.sh
    # derivation covers the wrapper shape
    echo "TARGETS=[$(mcp_warm_targets /tmp/w/.mcp.json | tr "\n" ";")]"
    mcp_warm_run /tmp/w/.mcp.json
    echo "WARM=$(uv tool list 2>&1 | grep -c workspace-mcp || true)"
    echo "OFFLINE=$(UV_OFFLINE=1 uvx workspace-mcp --help >/dev/null 2>&1 && echo ok || uv tool list 2>&1 | grep -q workspace-mcp && echo ok || echo fail)"
    echo "UVDIR=$(test -d /opt/uv && echo ok || echo fail)"
    echo "NPMDIR=$(test -d /opt/npm-cache && echo ok || echo fail)"
  '
  echo "$output"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^COLD=0'                                  # not pre-baked (E2/E4)
  echo "$output" | grep -q 'uvx	workspace-mcp'                        # derivation saw the wrapper
  echo "$output" | grep -qE '^WARM=[1-9]'                              # installed after warm (E1)
  echo "$output" | grep -q '^OFFLINE=ok'                              # resolves without network
  echo "$output" | grep -q '^UVDIR=ok'                               # cache off the mount (FR-004)
  echo "$output" | grep -q '^NPMDIR=ok'
}

# ── E3: catalog stays pre-warmed (no regression) + warm is idempotent ────────

@test "E2E 030: catalog stays pre-warmed and a second warm is a no-op (FR-005/FR-009)" {
  run docker compose run --rm -T --user agent --entrypoint sh warmbot -c '
    set -e
    echo "CATALOG=$(uv tool list 2>&1 | grep -c mcp-atlassian || true)"
    mkdir -p /tmp/w
    echo "{ \"mcpServers\": { \"fetch\": { \"command\": \"uvx\", \"args\": [\"mcp-server-fetch\"] } } }" > /tmp/w/.mcp.json
    . /opt/agent-admin/scripts/lib/mcp_warm.sh
    mcp_warm_run /tmp/w/.mcp.json; echo "RUN1=$?"
    mcp_warm_run /tmp/w/.mcp.json; echo "RUN2=$?"   # idempotent no-op
  '
  echo "$output"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^CATALOG=[1-9]'   # mcp-atlassian still baked (FR-009)
  echo "$output" | grep -q '^RUN1=0'
  echo "$output" | grep -q '^RUN2=0'
}

# ── Boot wiring reached the image ────────────────────────────────────────────

@test "E2E 030: the baked start_services.sh calls pre_warm_mcps before the tmux launch" {
  run docker compose run --rm -T --user agent --entrypoint sh warmbot -c '
    grep -n "pre_warm_mcps" /opt/agent-admin/scripts/start_services.sh
    grep -q "scripts/lib/mcp_warm.sh" /opt/agent-admin/scripts/start_services.sh && echo SOURCED
    test -f /opt/agent-admin/scripts/lib/mcp_warm.sh && echo BAKED
  '
  echo "$output"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'SOURCED'
  echo "$output" | grep -q 'BAKED'
  echo "$output" | grep -q 'pre_warm_mcps'
}

# ══ 036 DOCKER_E2E — the cold-start fixes, exercised in the real image ═══════
#
# Harness facts inherited from 033/034, each one learned the hard way:
#   * the patcher's log() writes to STDOUT, not stderr;
#   * `grep -c PATTERN file` exits 1 on a zero count, which aborts a `set -e`
#     script before the checks that EXPECT zero;
#   * `docker compose run` prepends its own progress lines to $output, so
#     assertions use named markers and never line positions.

# ── E-A: the uv split that caused the incident is closed in the image ────────

@test "E2E 036: UV_TOOL_BIN_DIR is set inside /opt/uv, off the state mount" {
  # The defect: uv keeps the package tree in UV_TOOL_DIR (baked, discarded on
  # every rebuild) and the executable links in UV_TOOL_BIN_DIR, which defaults
  # to ~/.local/bin — inside the .state bind-mount, so it SURVIVES the rebuild.
  # The links then dangle, `uv tool install` refuses to overwrite an existing
  # executable, and every affected package becomes permanently unwarmable.
  run docker compose run --rm -T --user agent --entrypoint sh warmbot -c '
    echo "BINDIR=${UV_TOOL_BIN_DIR:-unset}"
    echo "TOOLDIR=${UV_TOOL_DIR:-unset}"
    case "${UV_TOOL_BIN_DIR:-}" in /opt/uv/*) echo "UNDEROPT=ok" ;; *) echo "UNDEROPT=fail" ;; esac
    case "${UV_TOOL_BIN_DIR:-}" in "$HOME"/*) echo "ONMOUNT=fail" ;; *) echo "ONMOUNT=ok" ;; esac
  '
  echo "$output"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'UNDEROPT=ok'
  echo "$output" | grep -qx 'ONMOUNT=ok'
}

# ── E-B: a colliding executable name no longer blocks the warm ───────────────

@test "E2E 036: a package whose executable link already exists still ends warm (migration path)" {
  # MUST force UV_TOOL_BIN_DIR back to its pre-036 default, and that is the
  # whole reason this case is worth running. With the shipped value
  # (/opt/uv/bin) uv no longer looks at ~/.local/bin at all, so a link planted
  # there can never collide and the test would pass having proved nothing —
  # which is exactly how it was first written.
  #
  # The scenario that matters is the MIGRATION: an agent whose .state carries
  # links written by a pre-036 image. That is the layout reproduced here.
  # Measured in this image: install alone rc=2 (the incident), prune-then-install
  # rc=0. The first half is asserted too, so the fix cannot be credited for
  # curing something that was not broken.
  run docker compose run --rm -T --user agent --entrypoint bash warmbot -c '
    set -e
    export UV_TOOL_BIN_DIR="$HOME/.local/bin"
    . /opt/agent-admin/scripts/lib/mcp_warm.sh
    mkdir -p "$HOME/.local/bin" /tmp/w
    uv tool uninstall mcp-server-time >/dev/null 2>&1 || true
    ln -sf /opt/uv/tools/mcp-server-time/bin/mcp-server-time "$HOME/.local/bin/mcp-server-time"
    echo "DANGLING=$(test -L "$HOME/.local/bin/mcp-server-time" && test ! -e "$HOME/.local/bin/mcp-server-time" && echo yes || echo no)"
    # The defect itself, still reproducible: no prune, no force → rc 2.
    # Captured into a variable rather than read from $? — the script runs under
    # `set -e`, so letting the command that is SUPPOSED to fail run bare aborts
    # everything before the echo. (Same class as the `|| true` guards that make
    # start_initial_session safe; easy to forget in a harness.)
    _rc=0
    timeout 120 uv tool install --python python3 mcp-server-time >/dev/null 2>&1 || _rc=$?
    echo "UNPRUNED_RC=$_rc"
    cat > /tmp/w/.mcp.json <<JSON
{ "mcpServers": { "time": { "command": "uvx", "args": ["mcp-server-time"] } } }
JSON
    mcp_warm_prune_stale_links "$HOME/.local/bin"
    echo "PRUNED=$(test -L "$HOME/.local/bin/mcp-server-time" && echo still || echo gone)"
    echo "SUMMARY=$(mcp_warm_run /tmp/w/.mcp.json 2>&1 | grep -c "1/1 warm, 0 failed" || true)"
  '
  echo "$output"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'DANGLING=yes'
  # Without the pruner the incident still happens — the oracle is not vacuous.
  echo "$output" | grep -qx 'UNPRUNED_RC=2'
  echo "$output" | grep -qx 'PRUNED=gone'
  echo "$output" | grep -qx 'SUMMARY=1'
}

# ── E-C: the pruner is surgical ──────────────────────────────────────────────

@test "E2E 036: only dangling links into /opt/uv/tools are pruned" {
  run docker compose run --rm -T --user agent --entrypoint sh warmbot -c '
    set -e
    . /opt/agent-admin/scripts/lib/mcp_warm.sh
    d="$HOME/.local/bin"; mkdir -p "$d"
    ln -sf /opt/uv/tools/gone/bin/gone      "$d/dangling"     # must go
    ln -sf /bin/sh                          "$d/resolving"    # must stay (other prefix)
    printf "#!/bin/sh\n" > "$d/realfile"; chmod +x "$d/realfile"   # must stay
    ln -sf /somewhere/else/gone             "$d/notours"      # dangling, not ours → stays
    # THE case that had no oracle in any tier until a mutation exposed it: a link
    # that points INTO /opt/uv/tools and still RESOLVES. It passes the prefix
    # guard, so only the `[ -e ]` guard stands between it and deletion — i.e.
    # between a working tool and a broken one. It cannot be built on the host,
    # where /opt/uv/tools does not exist; here it can, because the image owns
    # that tree and the agent user can write to it.
    mkdir -p /opt/uv/tools/livepkg/bin
    printf "#!/bin/sh\necho live\n" > /opt/uv/tools/livepkg/bin/livetool
    chmod +x /opt/uv/tools/livepkg/bin/livetool
    ln -sf /opt/uv/tools/livepkg/bin/livetool "$d/livetool"   # resolves → must stay
    mcp_warm_prune_stale_links "$d"
    echo "DANGLING=$(test -e "$d/dangling" -o -L "$d/dangling" && echo still || echo gone)"
    echo "RESOLVING=$(test -L "$d/resolving" && echo ok || echo lost)"
    echo "REALFILE=$(test -f "$d/realfile" && echo ok || echo lost)"
    echo "NOTOURS=$(test -L "$d/notours" && echo ok || echo lost)"
    echo "LIVELINK=$(test -L "$d/livetool" && echo ok || echo lost)"
  '
  echo "$output"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'DANGLING=gone'
  echo "$output" | grep -qx 'RESOLVING=ok'
  echo "$output" | grep -qx 'REALFILE=ok'
  echo "$output" | grep -qx 'NOTOURS=ok'
  echo "$output" | grep -qx 'LIVELINK=ok'
}

# ── E-D: --force does not break the baked catalogue (FR-004) ────────────────

@test "E2E 036: the baked catalogue tools still execute after a forced warm" {
  # --force is unconditional now. Measured on the live container as free (a
  # forced install over an already-installed package is 0s), but "free" is not
  # "harmless": this proves it does not leave the three baked tools broken.
  run docker compose run --rm -T --user agent --entrypoint sh warmbot -c '
    set -e
    . /opt/agent-admin/scripts/lib/mcp_warm.sh
    mkdir -p /tmp/w
    cat > /tmp/w/.mcp.json <<JSON
{ "mcpServers": {
  "atl":   { "command": "uvx", "args": ["mcp-atlassian"] },
  "fetch": { "command": "uvx", "args": ["mcp-server-fetch"] },
  "time":  { "command": "uvx", "args": ["mcp-server-time"] } } }
JSON
    mcp_warm_run /tmp/w/.mcp.json
    for t in mcp-atlassian mcp-server-fetch mcp-server-time; do
      echo "TOOL_${t}=$(uv tool list 2>&1 | grep -c "^${t} " || true)"
    done
  '
  echo "$output"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^TOOL_mcp-atlassian=[1-9]'
  echo "$output" | grep -qE '^TOOL_mcp-server-fetch=[1-9]'
  echo "$output" | grep -qE '^TOOL_mcp-server-time=[1-9]'
}

# ── E-E: the patcher publishes its markers inside the image ─────────────────

@test "E2E 036: --list-markers prints 7 lines and exits 0 in the image" {
  # The doctor's whole check rests on this working against the BAKED patcher,
  # not the repo copy.
  run docker compose run --rm -T --user agent --entrypoint sh warmbot -c '
    python3 /opt/agent-admin/scripts/apply_telegram_typing_patch.py --list-markers > /tmp/m.txt 2>/dev/null
    echo "RC=$?"
    echo "COUNT=$(grep -c . /tmp/m.txt || true)"
    echo "PREFIXED=$(grep -c "^agentic-pod-launcher: " /tmp/m.txt || true)"
  '
  echo "$output"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'RC=0'
  echo "$output" | grep -qx 'COUNT=7'
  echo "$output" | grep -qx 'PREFIXED=7'
}

# ── E-F: the boot retry is in the image and survives a missing runtime dir ──

@test "E2E 036: start_initial_session retries and writes its marker on a fresh tmpfs" {
  # /tmp is a container tmpfs emptied on every start, and the only other
  # mkdir -p lives inside start_session — i.e. after the first marker write.
  # This is the case that would have restart-looped the whole fleet.
  # --entrypoint bash, NOT sh: /bin/sh in this image is busybox, and
  # start_services.sh is bash which sources bash-syntax libs (backup_vault.sh) —
  # busybox dies on their syntax long before reaching the function under test.
  # The code under test is bash, so the harness must run bash.
  run docker compose run --rm -T --user agent --entrypoint bash warmbot -c '
    set -e
    test ! -d /tmp/agent-watchdog && echo "FRESHTMPFS=ok" || echo "FRESHTMPFS=preexisting"
    START_SERVICES_NO_RUN=1 . /opt/agent-admin/scripts/start_services.sh
    seen=/tmp/seen; : > "$seen"
    n=0
    start_session() {
      cat /tmp/agent-watchdog/boot-attempt >> "$seen" 2>/dev/null || true
      n=$((n + 1)); [ "$n" -ge 2 ]
    }
    log() { printf "%s\n" "$*" >> /tmp/boot.log; }
    start_initial_session
    echo "RC=$?"
    echo "ATTEMPTS=$(grep -c "initial session attempt" /tmp/boot.log || true)"
    echo "MARKER1=$(grep -cE "^1 [0-9]+$" "$seen" || true)"
    echo "MARKER2=$(grep -cE "^2 [0-9]+$" "$seen" || true)"
    echo "CLEANED=$(test -f /tmp/agent-watchdog/boot-attempt && echo still || echo gone)"
  '
  echo "$output"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'FRESHTMPFS=ok'
  echo "$output" | grep -qx 'RC=0'
  echo "$output" | grep -qx 'ATTEMPTS=2'
  echo "$output" | grep -qx 'MARKER1=1'
  echo "$output" | grep -qx 'MARKER2=1'
  echo "$output" | grep -qx 'CLEANED=gone'
}

# ── E-G (US5): the wizard survives its two abort paths under busybox/musl ───

@test "E2E 036: the baked wizard reads a config key without aborting (absent and duplicated)" {
  # Both aborts were measured in THIS runtime (busybox 1.37.0, musl), which is
  # the only place the 0.7% duplicate-key rate was observed — and where the
  # absent-key abort is deterministic.
  run docker compose run --rm -T --user agent --entrypoint bash warmbot -c '
    set -euo pipefail
    WIZARD_CONTAINER_NO_RUN=1 source /opt/agent-admin/scripts/wizard-container.sh
    cfg=/tmp/cfg
    # (1) key absent — the deterministic abort, which happens the moment a new
    # Atlassian alias is added to agent.yml and the file has no line for it.
    printf "OTHER=x\n" > "$cfg"
    echo "ABSENT=[$(current_env_value ATLASSIAN_ACME_TOKEN "$cfg")]"
    # (2) key duplicated — the 0.7% EPIPE race, measured in this very runtime.
    printf "ATLASSIAN_ACME_TOKEN=first\n" > "$cfg"
    for ((i=0; i<3000; i++)); do printf "ATLASSIAN_ACME_TOKEN=dup\n" >> "$cfg"; done
    echo "DUP=[$(current_env_value ATLASSIAN_ACME_TOKEN "$cfg")]"
  '
  echo "$output"
  [ "$status" -eq 0 ]
  # -qxF, not -qx: the payloads contain [ ], which grep reads as a character
  # class. `[]` is an empty one — a SYNTAX ERROR (status 2), which is how this
  # first failed — and `[first]` would match any single one of those letters.
  # Fixed-string matching is what was meant all along.
  echo "$output" | grep -qxF 'ABSENT=[]'
  echo "$output" | grep -qxF 'DUP=[first]'
}

# ── E-H (US5): the rendered local healthcheck demotes on a huge journal ─────

@test "E2E 036: the auth check fires on a journal far past the pipe buffer" {
  # Runs against the RENDERED template inside the image's bash, so the here-
  # string form is exercised where the operator's agent would run it.
  # The here-string is a bashism, and the rendered healthcheck is bash, so the
  # probe runs under the image's bash rather than busybox.
  run docker compose run --rm -T --user agent --entrypoint bash warmbot -c '
    set -uo pipefail
    journal="API Error: 401
$(head -c 204800 /dev/zero | tr "\0" "x")"
    if grep -qE "API Error: 401|Please run /login" <<< "$journal"; then echo DEGRADED; fi
    echo DONE
  '
  echo "$output"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'DEGRADED'
  echo "$output" | grep -qx 'DONE'
}
