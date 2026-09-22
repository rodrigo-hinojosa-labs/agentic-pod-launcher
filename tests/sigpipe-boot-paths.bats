#!/usr/bin/env bats
# 036 US5 — the last two measured instances of the SIGPIPE-under-pipefail class.
#
# Where these come from: a 26-site audit of every early-exit pipeline in the repo
# (2026-09-21, every verdict measured, one adversarial refuter per finding).
# Four real instances; two were fixed in PR #97 (setup.sh's guard backfills) and
# these are the other two. Evidence:
# specs/036-cold-start-boot-resilience/sigpipe-audit.md
#
# THE MECHANISM. EPIPE only happens if the producer attempts a write() AFTER the
# reader closed. So the deciding factor is the producer's write pattern, not the
# pipeline's text:
#
#   * A producer that emits its whole output in ONE write() fitting the 64 KiB
#     pipe buffer is immune — the kernel accepts it before the reader even runs.
#     `printf` is in that class BELOW 64 KiB, and reliably fatal above it
#     (boundary measured at exactly 65536 bytes on both bash versions).
#   * A producer with only one matching output line never writes again, so it is
#     safe whatever its speed. Two matching lines is where it turns.
#
# And how the status is consumed decides the CONSEQUENCE: inside `if PIPELINE`,
# errexit does not fire but the condition silently goes FALSE (a wrong
# decision); in a plain `v=$(PIPELINE)` assignment it ABORTS the script.

load helper

setup() { setup_tmp_dir; }
teardown() { teardown_tmp_dir; }

# ══ (a) modules/local-healthcheck.sh.tpl — a dead agent that does not say so ══
#
# `if printf '%s\n' "$journal" | grep -qE 'API Error: 401|Please run /login'`.
# The file declares `set -uo pipefail` (no -e), so this is the silent-wrong-
# decision shape: on a 141 the `if` goes FALSE, `_demote DEGRADED` never runs,
# the unit reports OK, and the operator's alert — gated on the DEGRADED status —
# never fires. The agent is down and nothing says so.
#
# printf is a builtin and therefore immune below 64 KiB, but line 44 captures
# `journalctl … --since "-10 min"` with NO `-n` cap, so the payload is unbounded.
# Measured: macOS bash 5.3.15 clean at 64,883 B, 261/300 failing at 65,573 B;
# Linux (bookworm, GNU grep 3.8) 29/300 at 66,263 B and 35/300 at 110,423 B.

_render_healthcheck() {
  # shellcheck source=/dev/null
  source "$REPO_ROOT/scripts/lib/render.sh"
  render_load_context "$REPO_ROOT/tests/fixtures/sample-agent.yml"
  render_to_file "$REPO_ROOT/modules/local-healthcheck.sh.tpl" "$TMP_TEST_DIR/healthcheck.sh"
}

# Drive ONLY the auth-detection stanza of the rendered script, with a journal of
# a chosen size, and report which branch it took. Keeps the harness independent
# of systemd, ss and everything else the real script touches.
_auth_branch() {
  local bytes="$1" shell="${2:-bash}"
  local pad
  # A 401 on the FIRST line, then filler: that is the shape that makes the
  # reader close early while the producer still has bytes to push.
  pad=$(head -c "$bytes" < /dev/zero | tr '\0' 'x')
  cat > "$TMP_TEST_DIR/probe.sh" <<'PROBE'
set -uo pipefail
journal="API Error: 401
$PAD"
PROBE
  # Extract the real line from the rendered template, so this test tracks the
  # implementation instead of restating it.
  grep -n "Please run /login" "$TMP_TEST_DIR/healthcheck.sh" | head -1 | cut -d: -f2- >> "$TMP_TEST_DIR/probe.sh"
  printf '  echo DEGRADED\nfi\necho DONE\n' >> "$TMP_TEST_DIR/probe.sh"
  PAD="$pad" "$shell" "$TMP_TEST_DIR/probe.sh"
}

@test "036 US5(a): the healthcheck detects a 401 in a journal far past the pipe buffer" {
  _render_healthcheck
  # 200 KiB: comfortably past the measured 64 KiB cliff, and a plausible ten
  # minutes of journal for a chatty agent.
  run _auth_branch 204800
  [ "$status" -eq 0 ]
  run bash -c "printf '%s\n' \"\$1\" | grep -cF 'DEGRADED'" _ "$output"
  [ "$output" = "1" ]
}

@test "036 US5(a): it still detects a 401 in a small journal (no regression)" {
  _render_healthcheck
  run _auth_branch 1024
  [ "$status" -eq 0 ]
  run bash -c "printf '%s\n' \"\$1\" | grep -cF 'DEGRADED'" _ "$output"
  [ "$output" = "1" ]
}

@test "036 US5(a): a clean journal is still not demoted" {
  _render_healthcheck
  # Same size, no 401 anywhere: the branch must NOT be taken.
  local pad
  pad=$(head -c 204800 < /dev/zero | tr '\0' 'x')
  cat > "$TMP_TEST_DIR/probe.sh" <<'PROBE'
set -uo pipefail
journal="$PAD"
PROBE
  grep -n "Please run /login" "$TMP_TEST_DIR/healthcheck.sh" | head -1 | cut -d: -f2- >> "$TMP_TEST_DIR/probe.sh"
  printf '  echo DEGRADED\nfi\necho DONE\n' >> "$TMP_TEST_DIR/probe.sh"
  PAD="$pad" run bash "$TMP_TEST_DIR/probe.sh"
  [ "$status" -eq 0 ]
  run bash -c "printf '%s\n' \"\$1\" | grep -cF 'DEGRADED'" _ "$output"
  [ "$output" = "0" ]
}

@test "036 US5(a): the journal capture is bounded at its source" {
  # Belt and braces: the consumer no longer closes early, AND the producer is
  # capped, because an unbounded capture is a memory cost on every tick even
  # when it is not a correctness problem.
  run bash -c "LC_ALL=C grep -cE 'journalctl -u \"\\\$UNIT\".*-n [0-9]+' '$REPO_ROOT/modules/local-healthcheck.sh.tpl'"
  [ "$output" = "1" ]
}

# ══ (b) docker/scripts/wizard-container.sh — the wizard that never comes back ══
#
# `existing=$(grep "^${var}=" "$ENV_FILE" | head -1 | cut -d= -f2-)`, a plain
# assignment with NO `local` — verified: the sole `local` in main() is
# existing_gh_pat. Under `set -e` a 141 therefore ABORTS the wizard.
#
# It needs two lines matching the same key, which setup.sh emits for two
# colliding Atlassian aliases. Measured in the real image (busybox 1.37.0,
# bash 5.3.9, aarch64-musl): 22/3000 aborts. The consequence is worse than the
# rate suggests: the Telegram token is persisted BEFORE this point, so on
# respawn the supervisor sees a token and takes the steady-state branch — the
# wizard is never relaunched, and the GitHub PAT and every remaining Atlassian
# prompt are skipped forever.

@test "036 US5(b): the wizard survives a config file holding two lines for one key" {
  # Reproduces the shape without touching a real secrets file: the same
  # duplicate-key collision, driven through the extracted line.
  local cfg="$TMP_TEST_DIR/cfg"
  {
    printf 'ATLASSIAN_ACME_TOKEN=first\n'
    # 4000 further matching lines: enough writes after the reader closes that
    # the race is not a coin toss.
    for i in $(seq 1 4000); do printf 'ATLASSIAN_ACME_TOKEN=dup%s\n' "$i"; done
  } > "$cfg"

  # Sources the SHIPPED script and calls its helper, so the oracle exercises the
  # code that actually ships rather than a copy of it. WIZARD_CONTAINER_NO_RUN
  # keeps the interactive flow from firing (the seam the file already provides).
  cat > "$TMP_TEST_DIR/probe.sh" <<PROBE
set -euo pipefail
WIZARD_CONTAINER_NO_RUN=1 source "$REPO_ROOT/docker/scripts/wizard-container.sh"
existing=\$(current_env_value "ATLASSIAN_ACME_TOKEN" "$cfg")
echo "SURVIVED:\$existing"
PROBE
  # 40 runs: at the measured per-run rate a single pass would miss it.
  local failures=0 i
  for i in $(seq 1 40); do
    bash "$TMP_TEST_DIR/probe.sh" >/dev/null 2>&1 || failures=$((failures + 1))
  done
  [ "$failures" -eq 0 ]
}

@test "036 US5(b): it still reads the first value correctly" {
  local cfg="$TMP_TEST_DIR/cfg"
  printf 'ATLASSIAN_ACME_TOKEN=wanted\nATLASSIAN_ACME_TOKEN=other\n' > "$cfg"
  cat > "$TMP_TEST_DIR/probe.sh" <<PROBE
set -euo pipefail
WIZARD_CONTAINER_NO_RUN=1 source "$REPO_ROOT/docker/scripts/wizard-container.sh"
printf '%s\n' "\$(current_env_value "ATLASSIAN_ACME_TOKEN" "$cfg")"
PROBE
  run bash "$TMP_TEST_DIR/probe.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "wanted" ]
}

@test "036 US5(b): an absent key still yields empty without aborting" {
  local cfg="$TMP_TEST_DIR/cfg"
  printf 'SOMETHING_ELSE=x\n' > "$cfg"
  cat > "$TMP_TEST_DIR/probe.sh" <<PROBE
set -euo pipefail
WIZARD_CONTAINER_NO_RUN=1 source "$REPO_ROOT/docker/scripts/wizard-container.sh"
existing=\$(current_env_value "ATLASSIAN_ACME_TOKEN" "$cfg")
printf 'rc=%s empty=%s\n' "\$?" "\${existing:-EMPTY}"
PROBE
  run bash "$TMP_TEST_DIR/probe.sh"
  [ "$status" -eq 0 ]
  run bash -c "printf '%s\n' \"\$1\" | grep -cF 'empty=EMPTY'" _ "$output"
  [ "$output" = "1" ]
}

# ══ T030c — anti-drift: the shape must not come back ═════════════════════════

@test "036 US5: no UNBOUNDED producer feeds an early-exiting consumer in either file" {
  # The invariant is deliberately NOT "no pipeline into grep -q". The audit
  # measured three such pipelines in the healthcheck (:71, :72, :106) as safe,
  # and they are safe for a structural reason rather than by luck: their
  # payloads are a PID and an integer, emitted by a builtin in a single write()
  # that the kernel accepts whole, so there is never a second write to take
  # EPIPE. Banning the shape outright would force a rewrite of correct code and
  # teach the next reader the wrong rule.
  #
  # What must not come back is an UNBOUNDED producer — a captured journal, a
  # file of unknown length — feeding a consumer that can close early. So the
  # oracle names the two producers that were actually dangerous.
  #
  # Counted, never `grep -q`-negated: an intermediate negated pipeline does not
  # fail a bats test, it just evaluates (documented repo gotcha). Comment lines
  # are stripped first, because both fixes quote the forbidden shape in their
  # docstrings so the next reader knows exactly what not to write.
  run bash -c "sed 's/[[:space:]]*#.*//' '$REPO_ROOT/modules/local-healthcheck.sh.tpl' | grep -cE '\\\$journal\" *\\| *grep'"
  [ "$output" = "0" ]
  run bash -c "sed 's/[[:space:]]*#.*//' '$REPO_ROOT/docker/scripts/wizard-container.sh' | grep -cE '\| *head -'"
  [ "$output" = "0" ]
}
