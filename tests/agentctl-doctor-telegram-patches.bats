#!/usr/bin/env bats
# 036 US4 — doctor check 12 (Telegram plugin patches). Net-new coverage: the
# check has no test at all today, which is how it went on lying for months.
#
# Three measured defects, all reproduced by the shim below:
#
#   1. It greps for "typing refresh patch v3" while the patcher has been at v6
#      since feature 031 — so a fully-patched agent counts 0 and is warned
#      "patches incomplete" forever. The four marker literals are duplicated in
#      agentctl and drift every time the patcher bumps a version.
#   2. `v=$(… grep -c … || echo 0)` yields TWO tokens when the file exists and
#      does not match: grep prints its own 0, exits 1, and the `||` appends
#      another. The next `[ "$v" -ge 1 ]` then dies with
#      `[: 0\n0: integer expression expected` — the exact live symptom.
#   3. It inspects `… | head -1` of the cache glob, so with two version
#      directories present it can read the inactive one and report on a file the
#      boot patcher never touched.
#
# Mould: tests/agentctl-doctor-claude-oauth.bats (stub docker, drive doctor,
# assert on its output).
#
# NOTE ON EXIT STATUS — deliberately never asserted. `doctor` exits 0 only when
# every check is clean (scripts/agentctl:616-618), and this tmpdir fixture always
# carries unrelated failures. Asserting rc 0 would be unreachable today and would
# go red the day any future check is added. The oracles read check-12's own
# lines. SC-005's exit-0 leg belongs to the live gate.

load helper

AGENTCTL="$REPO_ROOT/scripts/agentctl"
PATCHER="$REPO_ROOT/docker/scripts/apply_telegram_typing_patch.py"

setup() {
  setup_tmp_dir
  cat > "$TMP_TEST_DIR/agent.yml" <<YAML
agent:
  name: testagent
notifications:
  channel: telegram
vault:
  enabled: false
YAML
  mkdir -p "$TMP_TEST_DIR/fake-cache"
}

teardown() { teardown_tmp_dir; }

# Build a docker shim. $1 = directory holding the fake plugin tree; every
# server.ts under it answers greps against its real content.
#
# The shim REPLICATES grep -c's rc=1-on-zero-count, because that behaviour is
# half of defect 2 — a shim that always exits 0 would hide the very bug the
# implementation has to survive.
_install_docker_shim() {
  cat > "$TMP_TEST_DIR/docker" <<SHIM
#!/usr/bin/env bash
case "\$1" in
  info)    exit 0 ;;
  ps)      echo "abc123"; exit 0 ;;
  inspect) echo "running"; exit 0 ;;
  exec)
    # Drop everything up to and including the container name; what remains is
    # the command, still as separate words.
    shift
    while [ \$# -gt 0 ]; do
      a="\$1"; shift
      [ "\$a" = "testagent" ] && break
    done
    # Rewrite the container's plugin-cache prefix to the fixture root argument
    # by argument, so word splitting survives: \`grep -c "<marker with spaces>"
    # <file>\` must stay three words. Rewriting here rather than making the path
    # configurable in agentctl keeps the production code under test exactly as
    # it ships, with no test-only branch to diverge from it.
    args=()
    for a in "\$@"; do
      args+=( "\${a//\/home\/agent\/.claude\/plugins\/cache/${TMP_TEST_DIR}\/fake-cache}" )
    done
    case "\${args[*]}" in
      *--list-markers*)
        if [ -n "\${SHIM_MARKERS_FILE:-}" ] && [ -f "\${SHIM_MARKERS_FILE}" ]; then
          cat "\${SHIM_MARKERS_FILE}"
          exit 0
        fi
        # Pre-036 patcher: exits 0, prints no marker (the false-clean trap).
        echo "[apply_telegram_typing_patch] server.ts not found at --list-markers — skipping"
        exit 0
        ;;
    esac
    # Run it for real against the fixture, so \`ls -d …\` and \`grep -c … file\`
    # behave exactly as they would in the container — grep's exit 1 on a zero
    # count included, which is half of defect 2.
    "\${args[@]}"
    exit \$?
    ;;
  *) exit 0 ;;
esac
SHIM
  chmod +x "$TMP_TEST_DIR/docker"
  export PATH="$TMP_TEST_DIR:$PATH"
}

# Create a fake plugin cache. $1 = version dir, $2... = markers to write into
# that version's server.ts. The path mirrors the real cache layout so the
# doctor's own glob finds it.
_seed_plugin() {
  local ver="$1"; shift
  local dir="$TMP_TEST_DIR/fake-cache/claude-plugins-official/telegram/$ver"
  mkdir -p "$dir"
  : > "$dir/server.ts"
  local m
  for m in "$@"; do printf '// %s\n' "$m" >> "$dir/server.ts"; done
  printf 'export const x = 1;\n' >> "$dir/server.ts"
}

# The seven markers the current patcher publishes, read from the patcher itself
# so this file carries no literal of its own (the anti-drift rule the whole
# story is about).
_all_markers() { python3 "$PATCHER" --list-markers; }

_markers_file() {
  _all_markers > "$TMP_TEST_DIR/markers.txt"
  export SHIM_MARKERS_FILE="$TMP_TEST_DIR/markers.txt"
}

# ── The headline defect: a fully-patched agent must PASS ─────────────────────

@test "036 US4: a fully-patched agent passes with CANON-D1 and no warning" {
  cd "$TMP_TEST_DIR"
  _install_docker_shim
  _markers_file
  local dir="$TMP_TEST_DIR/fake-cache/claude-plugins-official/telegram/0.0.6"
  mkdir -p "$dir"; : > "$dir/server.ts"
  _all_markers | while IFS= read -r m; do printf '// %s\n' "$m" >> "$dir/server.ts"; done

  AGENT_NAME=testagent run "$AGENTCTL" doctor
  printf '%s\n' "$output" > out.txt

  run bash -c "grep -cE '✓ Telegram plugin patches: 7/7 groups present' out.txt"
  [ "$output" = "1" ]
  run bash -c "grep -cF '⚠ Telegram plugin patches' out.txt"
  [ "$output" = "0" ]
}

@test "036 US4: the check emits no shell error text (the grep -c two-token bug)" {
  cd "$TMP_TEST_DIR"
  _install_docker_shim
  _markers_file
  # A file that matches NOTHING is the trigger: grep -c prints 0 and exits 1,
  # and `|| echo 0` appends a second token.
  _seed_plugin "0.0.6" "nothing-matches-here"

  AGENT_NAME=testagent run "$AGENTCTL" doctor
  printf '%s\n' "$output" > out.txt
  # Asserted via the PREFIX bash puts on its own diagnostics — the script path
  # and a line number — not via the message text. Measured: on this host the
  # message arrives localised ("agentctl: línea 533: [: 0") and, because the
  # bad value itself contains a newline, it is split across two lines. An
  # oracle grepping for "integer expression expected" would therefore be green
  # for the wrong reason here and red on an English CI runner, or vice versa.
  # The path prefix is emitted in every locale and appears nowhere else in a
  # healthy run.
  run bash -c "grep -cF '$REPO_ROOT/scripts/agentctl:' out.txt"
  [ "$output" = "0" ]
}

# ── A genuinely missing group must still warn, and name itself ───────────────

@test "036 US4: one missing group warns and names that group's marker" {
  cd "$TMP_TEST_DIR"
  _install_docker_shim
  _markers_file
  # Everything except the voice group.
  local voice keep
  voice=$(_all_markers | grep 'voice roundtrip')
  keep=$(_all_markers | grep -v 'voice roundtrip')
  local dir="$TMP_TEST_DIR/fake-cache/claude-plugins-official/telegram/0.0.6"
  mkdir -p "$dir"; : > "$dir/server.ts"
  printf '%s\n' "$keep" | while IFS= read -r m; do printf '// %s\n' "$m" >> "$dir/server.ts"; done

  AGENT_NAME=testagent run "$AGENTCTL" doctor
  printf '%s\n' "$output" > out.txt
  run bash -c "grep -cF '⚠ Telegram plugin patches incomplete' out.txt"
  [ "$output" = "1" ]
  # Named by the marker string as received — which is what keeps agentctl free
  # of literals it would have to chase on every version bump.
  VOICE="$voice" run bash -c 'grep -cF "$VOICE" out.txt'
  [ "$output" = "1" ]
}

# ── Two version directories: the check must not pass on the inactive one ─────

@test "036 US4: with two version dirs, an unpatched one is not masked by a patched one" {
  cd "$TMP_TEST_DIR"
  _install_docker_shim
  _markers_file
  # ORDER MATTERS, and getting it backwards makes this test vacuous — which is
  # how it first shipped. The glob sorts 0.0.5 first, so if the UNPATCHED dir
  # came first, `head -1` would read it and produce the same warning as walking
  # every match: the mutation would survive. The discriminating shape is the
  # inverse — first dir patched, second not. `head -1` then reports a clean
  # pass on a cache that still holds an unpatched plugin.
  local dir5="$TMP_TEST_DIR/fake-cache/claude-plugins-official/telegram/0.0.5"
  mkdir -p "$dir5"; : > "$dir5/server.ts"
  _all_markers | while IFS= read -r m; do printf '// %s\n' "$m" >> "$dir5/server.ts"; done
  local dir6="$TMP_TEST_DIR/fake-cache/claude-plugins-official/telegram/0.0.6"
  mkdir -p "$dir6"; printf 'export const x = 1;\n' > "$dir6/server.ts"

  AGENT_NAME=testagent run "$AGENTCTL" doctor
  printf '%s\n' "$output" > out.txt
  run bash -c "grep -cF '⚠ Telegram plugin patches incomplete' out.txt"
  [ "$output" = "1" ]
  # The warning names the offending version directory, not the full path.
  run bash -c "grep -cF '0.0.6' out.txt"
  [ "$output" = "1" ]
  # And it must NOT report a clean pass off the back of the patched one.
  run bash -c "grep -cF 'groups present (' out.txt"
  [ "$output" = "0" ]
}

# ── An image whose patcher predates the flag: SKIP, never a verdict ──────────

@test "036 US4: an unsupported --list-markers skips, detected by content not status" {
  cd "$TMP_TEST_DIR"
  _install_docker_shim
  unset SHIM_MARKERS_FILE       # the shim now answers like a pre-036 patcher
  _seed_plugin "0.0.6" "nothing-matches-here"

  AGENT_NAME=testagent run "$AGENTCTL" doctor
  printf '%s\n' "$output" > out.txt
  run bash -c "grep -cF 'image patcher predates --list-markers' out.txt"
  [ "$output" = "1" ]
  # And emphatically NOT a pass: a 0/0 verdict would be the same false-clean
  # answer as today's bug, wearing the other glyph.
  run bash -c "grep -cF '0/0 groups present' out.txt"
  [ "$output" = "0" ]
}

# ── Non-telegram agents keep skipping ────────────────────────────────────────

@test "036 US4: a non-telegram agent still skips the check" {
  cd "$TMP_TEST_DIR"
  cat > agent.yml <<'YAML'
agent:
  name: testagent
notifications:
  channel: none
vault:
  enabled: false
YAML
  _install_docker_shim
  _markers_file

  AGENT_NAME=testagent run "$AGENTCTL" doctor
  printf '%s\n' "$output" > out.txt
  run bash -c "grep -cF 'notifications.channel=none' out.txt"
  [ "$output" -ge 1 ]
}

# ── Anti-drift: agentctl may not restate what the patcher knows ──────────────

@test "036 US4: agentctl restates no marker the patcher owns" {
  # The root cause of the whole story: a duplicated constant drifted, and a
  # missing marker is indistinguishable from an unpatched plugin, so nothing
  # caught it.
  #
  # Asserted against the patcher's OWN list, not a re-typed pattern — an eighth
  # patch group would otherwise escape this guard on the day it is added. What
  # is banned is any marker string appearing verbatim in agentctl; the generic
  # `^agentic-pod-launcher: ` prefix used at :546 to sanity-check the listing is
  # deliberately allowed, since it carries no version and so cannot drift.
  #
  # Comment lines are stripped first: the rewritten check's own docstring names
  # "typing refresh patch v3" to explain which literal went stale, and deleting
  # that explanation to satisfy a grep would trade the documentation for the
  # test.
  local code="$TMP_TEST_DIR/agentctl-code-only"
  sed 's/[[:space:]]*#.*//' "$REPO_ROOT/scripts/agentctl" > "$code"
  local m found=0
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    if LC_ALL=C grep -qF "$m" "$code"; then
      found=$((found + 1))
      echo "restated marker literal: $m" >&2
    fi
  done < <(_all_markers)
  [ "$found" -eq 0 ]
}
