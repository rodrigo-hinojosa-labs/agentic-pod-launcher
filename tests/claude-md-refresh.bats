#!/usr/bin/env bats
#
# 038 - the workspace CLAUDE.md is a derived file that --regenerate used to preserve
# unconditionally, so it fell behind the template (donna/linus ran a pre-037 copy after
# a 0.27.0 upgrade although nobody had edited it). Three files decide what to do, always
# compared with cmp -s (never mtime, never a hash):
#   C  <ws>/CLAUDE.md                                   what Claude loads
#   U  <ws>/.state/launcher/claude-md.upstream.md       the render of TODAY's template
#   B  <ws>/.state/launcher/claude-md.baseline.md       the render C incorporates
# Contract: specs/038-schema-delta-boot-nudge/contracts/claude-md-refresh.md

load 'helper'

# ============================================================================
# Library: scripts/lib/claude_md.sh (pure functions, no yq, rc 0, one token)
# ============================================================================

setup() {
  load_lib claude_md
  setup_tmp_dir
  C="$TMP_TEST_DIR/CLAUDE.md"
  U="$TMP_TEST_DIR/upstream.md"
  B="$TMP_TEST_DIR/baseline.md"
  printf 'rendered template v2\n' > "$U"
}

teardown() { teardown_tmp_dir; }

# --- claude_md_state C U B ----------------------------------------------------

@test "038 state: no upstream render yet is 'unknown' (a pre-038 workspace; say nothing)" {
  printf 'whatever\n' > "$C"
  rm -f "$U"
  run claude_md_state "$C" "$U" "$B"
  [ "$status" -eq 0 ]
  [ "$output" = "unknown" ]
}

@test "038 state: empty arguments are 'unknown' with rc 0, never an error" {
  run claude_md_state "" "" ""
  [ "$status" -eq 0 ]
  [ "$output" = "unknown" ]
  run claude_md_state
  [ "$status" -eq 0 ]
  [ "$output" = "unknown" ]
}

@test "038 state: C identical to U is 'in_sync', with or without a baseline" {
  cp "$U" "$C"
  run claude_md_state "$C" "$U" "$B"
  [ "$status" -eq 0 ]
  [ "$output" = "in_sync" ]
  printf 'an older render\n' > "$B"
  run claude_md_state "$C" "$U" "$B"
  [ "$output" = "in_sync" ]
}

@test "038 state: C differs from U and the baseline equals U is 'customized' (own edits, template unchanged)" {
  printf 'rendered template v2\nplus an operator paragraph\n' > "$C"
  cp "$U" "$B"
  run claude_md_state "$C" "$U" "$B"
  [ "$status" -eq 0 ]
  [ "$output" = "customized" ]
}

@test "038 state: C differs from U and the baseline is an OLDER render is 'pending_template'" {
  printf 'rendered template v1\n' > "$C"
  cp "$C" "$B"
  run claude_md_state "$C" "$U" "$B"
  [ "$status" -eq 0 ]
  [ "$output" = "pending_template" ]
}

@test "038 state: C differs from U and there is no baseline is 'pending_no_baseline' (the whole fleet today)" {
  printf 'rendered template v1\n' > "$C"
  rm -f "$B"
  run claude_md_state "$C" "$U" "$B"
  [ "$status" -eq 0 ]
  [ "$output" = "pending_no_baseline" ]
}

@test "038 state: a missing CLAUDE.md is 'pending_no_baseline' even if a baseline exists" {
  rm -f "$C"
  run claude_md_state "$C" "$U" "$B"
  [ "$output" = "pending_no_baseline" ]
  cp "$U" "$B"
  run claude_md_state "$C" "$U" "$B"
  [ "$status" -eq 0 ]
  [ "$output" = "pending_no_baseline" ]
}

@test "038 state: an unreadable upstream is 'unknown' (cannot compare, so say nothing)" {
  [ "$(id -u)" -ne 0 ] || skip "root ignores file modes"
  printf 'rendered template v1\n' > "$C"
  chmod 000 "$U"
  run claude_md_state "$C" "$U" "$B"
  chmod 644 "$U"
  [ "$status" -eq 0 ]
  [ "$output" = "unknown" ]
}

@test "038 state: a one-byte difference is enough (cmp, not a size or mtime heuristic)" {
  printf 'rendered template v2\n' > "$C"
  touch -t 200001010000 "$C"
  cp "$C" "$B"
  printf 'rendered template v3\n' > "$U"      # same length as v2, one byte different
  run claude_md_state "$C" "$U" "$B"
  [ "$output" = "pending_template" ]
}

# --- claude_md_regenerate_decision C U B FORCE LAUNCHER_OWN --------------------

@test "038 decision: no CLAUDE.md yet is 'render'" {
  rm -f "$C"
  run claude_md_regenerate_decision "$C" "$U" "$B" false false
  [ "$status" -eq 0 ]
  [ "$output" = "render" ]
}

@test "038 decision: a confirmed --force-claude-md is 'render' even over an edited file" {
  printf 'operator edits\n' > "$C"
  cp "$U" "$B"
  run claude_md_regenerate_decision "$C" "$U" "$B" true false
  [ "$status" -eq 0 ]
  [ "$output" = "render" ]
}

@test "038 decision: the launcher's own dev doc (027, local mode) is 'render'" {
  printf 'This is **the launcher**, not an agent.\n' > "$C"
  run claude_md_regenerate_decision "$C" "$U" "$B" false true
  [ "$status" -eq 0 ]
  [ "$output" = "render" ]
}

@test "038 decision: force wins over a would-be refresh" {
  printf 'rendered template v1\n' > "$C"
  cp "$C" "$B"
  run claude_md_regenerate_decision "$C" "$U" "$B" true false
  [ "$output" = "render" ]
}

@test "038 decision: C equals the baseline and differs from upstream is 'refresh' (nobody edited it)" {
  printf 'rendered template v1\n' > "$C"
  cp "$C" "$B"
  run claude_md_regenerate_decision "$C" "$U" "$B" false false
  [ "$status" -eq 0 ]
  [ "$output" = "refresh" ]
}

@test "038 decision: C equals upstream and there is no baseline is 'adopt'" {
  cp "$U" "$C"
  rm -f "$B"
  run claude_md_regenerate_decision "$C" "$U" "$B" false false
  [ "$status" -eq 0 ]
  [ "$output" = "adopt" ]
}

@test "038 decision: C equals upstream and the baseline is stale is 'adopt' (move the baseline forward)" {
  cp "$U" "$C"
  printf 'an older render\n' > "$B"
  run claude_md_regenerate_decision "$C" "$U" "$B" false false
  [ "$output" = "adopt" ]
}

@test "038 decision: everything equal is 'noop'" {
  cp "$U" "$C"
  cp "$U" "$B"
  run claude_md_regenerate_decision "$C" "$U" "$B" false false
  [ "$status" -eq 0 ]
  [ "$output" = "noop" ]
}

@test "038 decision: an edited file (differs from baseline AND upstream) is 'preserve'" {
  printf 'rendered template v1\nplus operator paragraph\n' > "$C"
  printf 'rendered template v1\n' > "$B"
  run claude_md_regenerate_decision "$C" "$U" "$B" false false
  [ "$status" -eq 0 ]
  [ "$output" = "preserve" ]
}

@test "038 decision: an existing file with no baseline that differs from upstream is 'preserve'" {
  printf 'hand written\n' > "$C"
  rm -f "$B"
  run claude_md_regenerate_decision "$C" "$U" "$B" false false
  [ "$output" = "preserve" ]
}

@test "038 decision: omitted or non-'true' flags count as false" {
  printf 'operator edits\n' > "$C"
  run claude_md_regenerate_decision "$C" "$U" "$B"
  [ "$status" -eq 0 ]
  [ "$output" = "preserve" ]
  run claude_md_regenerate_decision "$C" "$U" "$B" yes 1
  [ "$output" = "preserve" ]
}

@test "038 decision: without a readable upstream and no render trigger it is 'preserve', never refresh/adopt" {
  printf 'rendered template v1\n' > "$C"
  cp "$C" "$B"
  rm -f "$U"
  run claude_md_regenerate_decision "$C" "$U" "$B" false false
  [ "$status" -eq 0 ]
  [ "$output" = "preserve" ]
}

@test "038 decision: C is never written by the library (it only reports)" {
  printf 'rendered template v1\n' > "$C"
  cp "$C" "$B"
  local before
  before=$(cksum < "$C")
  run claude_md_regenerate_decision "$C" "$U" "$B" false false
  [ "$output" = "refresh" ]
  [ "$(cksum < "$C")" = "$before" ]
}

# --- loading ------------------------------------------------------------------

@test "038 lib: sourcing under set -euo pipefail defines the functions and prints nothing" {
  run bash -c 'set -euo pipefail; source "$1/scripts/lib/claude_md.sh"; type claude_md_state >/dev/null; type claude_md_regenerate_decision >/dev/null; echo loaded' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "loaded" ]
}

@test "038 lib: no yq dependency outside comments (the hook that sources it must run without yq on PATH)" {
  run bash -c "grep -v '^[[:space:]]*#' \"\$1\" | grep -c yq" _ "$REPO_ROOT/scripts/lib/claude_md.sh"
  [ "$output" = "0" ]
}

# ============================================================================
# --regenerate end to end (the same decisions, through the real setup.sh)
# ============================================================================

# _ws_setup [docker|local]: a scaffolded-looking workspace with a persona file. The persona
# lives in personas/ (agent.role_file) - NOT in CLAUDE.md - which is why re-rendering is safe.
_ws_setup() {
  local mode="${1:-docker}"
  WS="$TMP_TEST_DIR/ws"
  mkdir -p "$WS/personas"
  cp -r "$REPO_ROOT/scripts" "$REPO_ROOT/modules" "$WS/"
  cp "$REPO_ROOT/setup.sh" "$WS/"
  printf 'PERSONA_038_MARKER the persona lives in personas/, not in CLAUDE.md.\n' > "$WS/personas/regen-bot.md"
  cat > "$WS/agent.yml" <<YML
version: 1
agent:
  name: regen-bot
  display_name: "RegenBot"
  role: "r"
  role_file: "personas/regen-bot.md"
  vibe: "v"
  use_default_principles: true
user:
  name: "A"
  nickname: "A"
  timezone: "UTC"
  email: "a@b.com"
  language: "en"
deployment:
  host: "h"
  workspace: "/tmp/regen-bot"
  install_service: false
docker:
  image_tag: "agent-admin:latest"
  uid: 1000
  gid: 1000
  base_image: "alpine:3.20"
notifications:
  channel: none
features:
  heartbeat:
    enabled: true
    interval: "30m"
    timeout: 300
    retries: 1
    default_prompt: "ok"
mcps:
  atlassian: []
  github:
    enabled: false
plugins:
  - claude-mem@thedotmack
YML
  if [ "$mode" = "local" ]; then
    local stub
    stub=$(install_claude_stub)
    yq -i '.deployment.mode = "local"' "$WS/agent.yml"
    yq -i ".deployment.claude_cli = \"$stub\"" "$WS/agent.yml"
  fi
  WC="$WS/CLAUDE.md"
  WU="$WS/.state/launcher/claude-md.upstream.md"
  WB="$WS/.state/launcher/claude-md.baseline.md"
}

# _regen [args]: --regenerate with 'n' on stdin (answers the unrelated plugin prompt).
_regen() {
  run bash -c 'cd "$1" && shift && echo n | ./setup.sh --regenerate "$@"' _ "$WS" "$@"
}

# _regen_force Y|N: the forced re-render, answering its destructive-overwrite prompt.
_regen_force() {
  local ans="$1"
  run bash -c 'cd "$1" && printf "%s\n" "$2" | ./setup.sh --regenerate --force-claude-md' _ "$WS" "$ans"
}

# _flip_template: change an agent.yml input that changes the rendered CLAUDE.md (the Heartbeat
# section only exists while the heartbeat is enabled - exactly donna's situation).
_flip_template() { yq -i '.features.heartbeat.enabled = false' "$WS/agent.yml"; }

@test "038 regen R1: a workspace with no CLAUDE.md gets it, the upstream render and the baseline, all identical" {
  _ws_setup
  _regen
  [ "$status" -eq 0 ]
  [ -f "$WC" ]
  cmp -s "$WC" "$WU"
  cmp -s "$WC" "$WB"
  [[ "$output" == *"CLAUDE.md"* ]]
  grep -q 'PERSONA_038_MARKER' "$WC"
}

@test "038 regen R2: a second regenerate with unchanged inputs writes nothing: C, U, B byte-identical" {
  _ws_setup
  _regen
  cp "$WC" "$TMP_TEST_DIR/c.first"; cp "$WU" "$TMP_TEST_DIR/u.first"; cp "$WB" "$TMP_TEST_DIR/b.first"
  _regen
  [ "$status" -eq 0 ]
  cmp -s "$WC" "$TMP_TEST_DIR/c.first"
  cmp -s "$WU" "$TMP_TEST_DIR/u.first"
  cmp -s "$WB" "$TMP_TEST_DIR/b.first"
  [[ "$output" == *"CLAUDE.md (up to date)"* ]]
}

@test "038 regen R3: nobody edited it and the template moved: refreshed, persona intact (donna's case)" {
  _ws_setup
  _regen
  [ "$(grep -c '^## Heartbeat' "$WC")" = "1" ]
  _flip_template
  _regen
  [ "$status" -eq 0 ]
  [[ "$output" == *"refreshed: no local edits"* ]]
  cmp -s "$WC" "$WU"
  cmp -s "$WB" "$WU"
  [ "$(grep -c '^## Heartbeat' "$WC")" = "0" ]
  grep -q 'PERSONA_038_MARKER' "$WC"
}

@test "038 regen R4: an edited CLAUDE.md is NEVER overwritten (the guarantee of FR-007), upstream still advances" {
  _ws_setup
  _regen
  printf '\nOPERATOR_PARAGRAPH_038 written by hand\n' >> "$WC"
  cp "$WC" "$TMP_TEST_DIR/c.edited"; cp "$WB" "$TMP_TEST_DIR/b.before"
  _flip_template
  _regen
  [ "$status" -eq 0 ]
  cmp -s "$WC" "$TMP_TEST_DIR/c.edited"            # C untouched, byte for byte
  cmp -s "$WB" "$TMP_TEST_DIR/b.before"            # the baseline did not move either
  [ "$(grep -c '^## Heartbeat' "$WU")" = "0" ]     # but U is the NEW render
  [ "$(grep -c 'OPERATOR_PARAGRAPH_038' "$WC")" = "1" ]
  [[ "$output" == *"preserved: differs from the current template"* ]]
  [[ "$output" == *"--force-claude-md"* ]]
  [ "$(claude_md_state "$WC" "$WU" "$WB")" = "pending_template" ]
}

@test "038 regen R5: after the baseline is confirmed (cp U B) the file reads as the operator's own edits" {
  _ws_setup
  _regen
  printf '\nOPERATOR_PARAGRAPH_038\n' >> "$WC"
  _flip_template
  _regen
  cp "$WU" "$WB"                                    # what the agent or operator runs after merging by hand
  cp "$WC" "$TMP_TEST_DIR/c.edited"
  _regen
  [ "$status" -eq 0 ]
  cmp -s "$WC" "$TMP_TEST_DIR/c.edited"
  [[ "$output" == *"preserved: local edits, template unchanged"* ]]
  [ "$(claude_md_state "$WC" "$WU" "$WB")" = "customized" ]
}

@test "038 regen R6: C already equals the render but there is no baseline: it is adopted silently" {
  _ws_setup
  _regen
  rm -f "$WB"
  _regen
  [ "$status" -eq 0 ]
  cmp -s "$WB" "$WU"
  [[ "$output" == *"up to date; baseline recorded"* ]]
}

@test "038 regen R7: an edited file with no baseline is preserved and reported as pending_no_baseline" {
  _ws_setup
  _regen
  printf '\nOPERATOR_PARAGRAPH_038\n' >> "$WC"
  rm -f "$WB"
  cp "$WC" "$TMP_TEST_DIR/c.edited"
  _regen
  [ "$status" -eq 0 ]
  cmp -s "$WC" "$TMP_TEST_DIR/c.edited"
  [ ! -e "$WB" ]
  [ "$(claude_md_state "$WC" "$WU" "$WB")" = "pending_no_baseline" ]
}

@test "038 regen R8a: the forced re-render, confirmed, rewrites it and establishes the baseline" {
  _ws_setup
  _regen
  printf '\nOPERATOR_PARAGRAPH_038\n' >> "$WC"
  _flip_template
  _regen_force y
  [ "$status" -eq 0 ]
  [[ "$output" == *"overwritten"* ]]
  cmp -s "$WC" "$WU"
  cmp -s "$WB" "$WU"
  [ "$(grep -c 'OPERATOR_PARAGRAPH_038' "$WC")" = "0" ]
  grep -q 'PERSONA_038_MARKER' "$WC"
}

@test "038 regen R8b: the forced re-render declined leaves C alone (and does not refresh it behind the 'no')" {
  _ws_setup
  _regen
  _flip_template                                    # C == B, so an automatic refresh WOULD apply...
  cp "$WC" "$TMP_TEST_DIR/c.before"
  _regen_force n                                    # ...but the operator explicitly said no
  [ "$status" -eq 0 ]
  cmp -s "$WC" "$TMP_TEST_DIR/c.before"
  [ "$(grep -c '^## Heartbeat' "$WU")" = "0" ]      # U is still brought up to date
  [[ "$output" == *"skipping CLAUDE.md (preserved)"* ]]
}

@test "038 regen R9: local mode, the launcher's own dev doc is replaced by the agent's (027 intact) and baselined" {
  _ws_setup local
  printf '# CLAUDE.md\n\nThis is **the launcher**, not an agent. ./setup.sh is a bash wizard.\n' > "$WC"
  _regen
  [ "$status" -eq 0 ]
  grep -q '## Identity' "$WC"
  grep -q 'RegenBot' "$WC"
  [ "$(grep -c 'This is \*\*the launcher\*\*, not an agent' "$WC")" = "0" ]
  cmp -s "$WC" "$WU"
  cmp -s "$WB" "$WU"
}

@test "038 regen R10: C equals the render and the baseline is garbage: adopt moves the baseline forward" {
  _ws_setup
  _regen
  printf 'garbage from an older render\n' > "$WB"
  _regen
  [ "$status" -eq 0 ]
  cmp -s "$WB" "$WU"
  [ "$(claude_md_state "$WC" "$WU" "$WB")" = "in_sync" ]
}

@test "038 regen R11: when the current render cannot be written, regenerate still exits 0 and C stays intact" {
  [ "$(id -u)" -ne 0 ] || skip "root ignores file modes"
  _ws_setup
  _regen
  _flip_template
  cp "$WC" "$TMP_TEST_DIR/c.before"
  chmod 444 "$WU"
  chmod 555 "$WS/.state/launcher"
  _regen
  local rc="$status"
  chmod 755 "$WS/.state/launcher"
  chmod 644 "$WU"
  [ "$rc" -eq 0 ]
  cmp -s "$WC" "$TMP_TEST_DIR/c.before"
}

@test "038 regen R12: the fleet today - a stale CLAUDE.md and no .state/launcher at all - is preserved, reported, and gets its upstream" {
  _ws_setup
  printf '# an older template render\nsome text from before the upgrade\n' > "$WC"
  cp "$WC" "$TMP_TEST_DIR/c.stale"
  [ ! -e "$WS/.state/launcher" ]
  _regen
  [ "$status" -eq 0 ]
  cmp -s "$WC" "$TMP_TEST_DIR/c.stale"
  [ -f "$WU" ]
  [ ! -e "$WB" ]
  [[ "$output" == *"--force-claude-md"* ]]
  [ "$(claude_md_state "$WC" "$WU" "$WB")" = "pending_no_baseline" ]
}

@test "038 regen R13: rollout rehearsal - force once per agent, and every later upgrade applies by itself" {
  _ws_setup
  printf '# an older template render\n' > "$WC"
  _regen                                            # preserved, no baseline (the state of the fleet)
  _regen_force y                                    # the one-time forced render
  [ "$status" -eq 0 ]
  cmp -s "$WC" "$WU"
  cmp -s "$WB" "$WU"
  _flip_template                                    # a later upgrade changes the template
  _regen
  [ "$status" -eq 0 ]
  [[ "$output" == *"refreshed: no local edits"* ]]
  cmp -s "$WC" "$WU"
}

@test "038 regen R14: the refresh is mode-independent - local mode refreshes an unedited file too" {
  _ws_setup local
  _regen
  [ "$status" -eq 0 ]
  cmp -s "$WC" "$WB"
  _flip_template
  _regen
  [ "$status" -eq 0 ]
  [[ "$output" == *"refreshed: no local edits"* ]]
  cmp -s "$WC" "$WU"
}

@test "038 regen R15: the only thing it adds under .state is launcher/ (it must not fake a login state)" {
  # Local mode gates its systemd unit on .state/.claude/.credentials.json; docker bind-mounts
  # .state as the agent's home. Creating the baseline directory must not make an unlogged
  # workspace look logged in, so nothing but launcher/ may appear.
  _ws_setup
  [ ! -e "$WS/.state" ]
  _regen
  [ "$status" -eq 0 ]
  [ "$(ls -A "$WS/.state")" = "launcher" ]
  [ "$(ls -A "$WS/.state/launcher" | sort | tr '\n' ' ')" = "claude-md.baseline.md claude-md.upstream.md " ]
  # local mode already renders .state/remote-control.env, but must still not create the login dir
  rm -rf "$WS"
  _ws_setup local
  _regen
  [ "$status" -eq 0 ]
  [ -d "$WS/.state/launcher" ]
  [ ! -e "$WS/.state/.claude" ]
}
