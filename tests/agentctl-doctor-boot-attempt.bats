#!/usr/bin/env bats
# 036 US3 — doctor check 4 (container health) learns to tell a boot that is
# legitimately retrying from a container that is simply dead.
#
# Why this is needed at all: on a cold or degraded boot the compose healthcheck
# can flip to `unhealthy` while start_initial_session is still working through
# its attempts, and scripts/agentctl maps `unhealthy` → _doctor_fail. Reporting
# a hard FAIL for a healthy-but-slow boot is a false negative of the same family
# US4 removes, so doctor learns the distinction rather than the healthcheck
# being silenced.
#
# A SEPARATE FILE from agentctl-doctor-telegram-patches.bats on purpose: the two
# are different checks needing different shims — that one serves a plugin path
# and greps files, this one serves a marker through `docker exec … cat`. Folding
# them would force one fixture to satisfy both.

load helper

AGENTCTL="$REPO_ROOT/scripts/agentctl"

setup() {
  setup_tmp_dir
  cat > "$TMP_TEST_DIR/agent.yml" <<'YAML'
agent:
  name: testagent
notifications:
  channel: none
vault:
  enabled: false
YAML
  # One shim, four cases, driven by environment:
  #   SHIM_HEALTH — what `docker inspect` reports for the health status
  #   SHIM_MARKER — the boot marker's content; UNSET models a failed exec,
  #                 which is what a restarting container or a slow daemon gives.
  cat > "$TMP_TEST_DIR/docker" <<'SHIM'
#!/usr/bin/env bash
case "$1" in
  info) exit 0 ;;
  ps)   echo "abc123"; exit 0 ;;
  inspect)
    # Health query vs the StartedAt query the previous check makes.
    case "$*" in
      *State.Health*) printf '%s\n' "${SHIM_HEALTH:-healthy}"; exit 0 ;;
      *StartedAt*)    printf '2026-09-21T00:00:00\n'; exit 0 ;;
      *)              printf 'running\n'; exit 0 ;;
    esac
    ;;
  exec)
    case "$*" in
      *boot-attempt*)
        if [ -n "${SHIM_MARKER+x}" ]; then printf '%s\n' "$SHIM_MARKER"; exit 0; fi
        exit 1
        ;;
      *) exit 0 ;;
    esac
    ;;
  *) exit 0 ;;
esac
SHIM
  chmod +x "$TMP_TEST_DIR/docker"
  export PATH="$TMP_TEST_DIR:$PATH"
  unset SHIM_HEALTH SHIM_MARKER
}

teardown() { teardown_tmp_dir; }

_now() { date -u +%s; }

# ── Case 1: unhealthy + fresh marker → informational, not a failure ──────────

@test "036 US3: an unhealthy container with a fresh boot marker reports CANON-H1, not a failure" {
  cd "$TMP_TEST_DIR"
  export SHIM_HEALTH=unhealthy
  export SHIM_MARKER="2 $(_now)"
  AGENT_NAME=testagent run "$AGENTCTL" doctor
  printf '%s\n' "$output" > out.txt
  run bash -c "grep -cF 'Container health: starting (boot attempt 2/3)' out.txt"
  [ "$output" = "1" ]
  run bash -c "grep -cF 'Container health: unhealthy' out.txt"
  [ "$output" = "0" ]
}

# ── Case 2: a failed docker exec must mean "no marker", never a bypass ───────

@test "036 US3: a failed marker read leaves the unhealthy failure exactly as today" {
  cd "$TMP_TEST_DIR"
  export SHIM_HEALTH=unhealthy
  # SHIM_MARKER unset → the shim exits 1, modelling a restarting container.
  AGENT_NAME=testagent run "$AGENTCTL" doctor
  printf '%s\n' "$output" > out.txt
  run bash -c "grep -cF 'Container health: unhealthy' out.txt"
  [ "$output" = "1" ]
  run bash -c "grep -cF 'boot attempt' out.txt"
  [ "$output" = "0" ]
}

# ── Case 3: the freshness guard. Without it this feature makes doctor WORSE ──

@test "036 US3: a stale boot marker does not keep a dead agent looking like it is starting" {
  cd "$TMP_TEST_DIR"
  # The failure mode the guard exists for: a container that can never bring the
  # channel up exhausts its attempts, exits, is revived by `restart:
  # unless-stopped`, and starts over — so it sits *permanently* inside an
  # "initial boot" with a marker almost always present. Without the age check,
  # doctor would answer "starting (boot attempt 2/3)" forever for an agent that
  # is thoroughly dead, which is worse than the FAIL it replaced.
  export SHIM_HEALTH=unhealthy
  export SHIM_MARKER="2 $(( $(_now) - 3600 ))"
  AGENT_NAME=testagent run "$AGENTCTL" doctor
  printf '%s\n' "$output" > out.txt
  run bash -c "grep -cF 'Container health: unhealthy' out.txt"
  [ "$output" = "1" ]
  run bash -c "grep -cF 'boot attempt 2/3)' out.txt"
  [ "$output" = "0" ]
}

# ── Case 4: no other health state is touched ─────────────────────────────────

@test "036 US3: a marker neither upgrades nor downgrades any other health state" {
  cd "$TMP_TEST_DIR"
  export SHIM_HEALTH=healthy
  export SHIM_MARKER="1 $(_now)"
  AGENT_NAME=testagent run "$AGENTCTL" doctor
  printf '%s\n' "$output" > out.txt
  run bash -c "grep -cF 'Container health: healthy' out.txt"
  [ "$output" = "1" ]
  run bash -c "grep -cF 'boot attempt' out.txt"
  [ "$output" = "0" ]
}

# ── Garbage in the marker degrades to "no marker", never to a nonsense verdict ─

@test "036 US3: a non-numeric marker payload is treated as no marker" {
  cd "$TMP_TEST_DIR"
  export SHIM_HEALTH=unhealthy
  export SHIM_MARKER="corrupted garbage"
  AGENT_NAME=testagent run "$AGENTCTL" doctor
  printf '%s\n' "$output" > out.txt
  run bash -c "grep -cF 'Container health: unhealthy' out.txt"
  [ "$output" = "1" ]
}

@test "036 US3: the marker is read through docker exec, never through the bind-mount" {
  # The convention comment at scripts/agentctl:315-318 steers freshness checks
  # toward the workspace bind-mount, which would silently never find this file:
  # /tmp is a container tmpfs, reachable through neither ./:/workspace nor
  # ./.state:/home/agent. Asserted structurally, because a bind-mount read would
  # simply return nothing and look like "no marker" in every case above.
  run bash -c "LC_ALL=C grep -cF 'boot-attempt' '$REPO_ROOT/scripts/agentctl'"
  [ "$output" -ge 1 ]
  run bash -c "LC_ALL=C grep -nF 'boot-attempt' '$REPO_ROOT/scripts/agentctl' | grep -cF 'WORKSPACE'"
  [ "$output" = "0" ]
}

@test "036 US3: the freshness budget honours this agent's own channel window" {
  cd "$TMP_TEST_DIR"
  # Regression guard for the adversarial-review finding: the guard read $yml 29
  # lines BEFORE its own `local yml=""` declaration, so it always saw an unset
  # name, always fell back to 60, and every agent got a 195 s budget regardless
  # of configuration. donna's window is 120, which should give 375 s — so a
  # marker aged 300 s must still count as fresh for her, and would have been
  # declared stale under the bug.
  cat > agent.yml <<'YAML'
agent:
  name: testagent
notifications:
  channel: none
vault:
  enabled: false
docker:
  channel_health_timeout_s: 120
YAML
  export SHIM_HEALTH=unhealthy
  export SHIM_MARKER="2 $(( $(_now) - 300 ))"
  AGENT_NAME=testagent run "$AGENTCTL" doctor
  printf '%s\n' "$output" > out.txt
  run bash -c "grep -cF 'Container health: starting (boot attempt 2/3)' out.txt"
  [ "$output" = "1" ]
}

@test "036 US3: a 60s-window agent still calls the same age stale" {
  cd "$TMP_TEST_DIR"
  # The other half: with the default window the budget is 195 s, so the SAME
  # 300 s marker must be stale. Without this pair, a mutation that simply
  # widened the constant would pass the test above.
  cat > agent.yml <<'YAML'
agent:
  name: testagent
notifications:
  channel: none
vault:
  enabled: false
docker:
  channel_health_timeout_s: 60
YAML
  export SHIM_HEALTH=unhealthy
  export SHIM_MARKER="2 $(( $(_now) - 300 ))"
  AGENT_NAME=testagent run "$AGENTCTL" doctor
  printf '%s\n' "$output" > out.txt
  run bash -c "grep -cF 'Container health: unhealthy' out.txt"
  [ "$output" = "1" ]
}
