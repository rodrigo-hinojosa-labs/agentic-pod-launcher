#!/usr/bin/env bats

load helper

setup() {
  load_lib yaml
  load_lib render
  FIXTURE="$REPO_ROOT/tests/fixtures/sample-agent.yml"
  render_load_context "$FIXTURE"
}

@test "render_template substitutes simple placeholders" {
  export USER_NAME="Alice Example"
  export AGENT_DISPLAY_NAME="TestAgent 🤖"
  export DEPLOYMENT_WORKSPACE="/tmp/work"
  result=$(render_template "$REPO_ROOT/tests/fixtures/simple.tpl")
  [[ "$result" == *"Hello Alice Example"* ]]
  [[ "$result" == *"welcome to TestAgent 🤖"* ]]
  [[ "$result" == *"workspace is /tmp/work"* ]]
}

@test "render_template includes {{#if}} block when true" {
  export FEATURES_HEARTBEAT_ENABLED=true
  export FEATURES_HEARTBEAT_INTERVAL="15m"
  export MCPS_GITHUB_ENABLED=false
  result=$(render_template "$REPO_ROOT/tests/fixtures/conditional.tpl")
  [[ "$result" == *"Heartbeat runs every 15m"* ]]
  [[ "$result" == *"GitHub MCP is disabled"* ]]
  [[ "$result" == *"Core content"* ]]
  [[ "$result" == *"End."* ]]
}

@test "render_template excludes {{#if}} block when false" {
  export FEATURES_HEARTBEAT_ENABLED=false
  export MCPS_GITHUB_ENABLED=true
  result=$(render_template "$REPO_ROOT/tests/fixtures/conditional.tpl")
  [[ "$result" != *"Heartbeat runs every"* ]]
  [[ "$result" != *"GitHub MCP is disabled"* ]]
}

@test "render_template expands {{#each}} over array" {
  result=$(render_template "$REPO_ROOT/tests/fixtures/loop.tpl")
  [[ "$result" == *"- work at https://work.atlassian.net (alice@work.com)"* ]]
  [[ "$result" == *"- personal at https://personal.atlassian.net (alice@personal.com)"* ]]
  [[ "$result" == *"Done."* ]]
}

@test "render_template preserves literal \$1 and \\1 in field values" {
  # Regression: perl's s/.../$repl/ used to interpolate $1, $2 (capture
  # refs) and \1, \2 (backrefs) inside the replacement string, so a
  # field value containing those would be silently corrupted. The
  # current engine routes the replacement through ENV{REPL} with /e
  # so the value is treated as literal data.
  local tmp_yml="$BATS_TEST_TMPDIR/yml.yml"
  local tmp_tpl="$BATS_TEST_TMPDIR/tpl.tpl"
  cat > "$tmp_yml" <<'YML'
version: 1
mcps:
  atlassian:
    - name: q1
      url: 'https://q1.example/path?ref=$1&v=\1'
      email: '$2-test@example.com'
YML
  cat > "$tmp_tpl" <<'TPL'
{{#each MCPS_ATLASSIAN}}
- {{name}}: {{url}} ({{email}})
{{/each}}
TPL
  render_load_context "$tmp_yml"
  result=$(render_template "$tmp_tpl")
  [[ "$result" == *'https://q1.example/path?ref=$1&v=\1'* ]]
  [[ "$result" == *'$2-test@example.com'* ]]
}

# ─── 023-fix-render-ampersand: _render_replace_all oracle (contracts/field-substitution.md §3) ───
#
# Bug: scripts/lib/render.sh:90,95 expand {{field}} with `${row_expanded//\{\{${field}\}\}/$fval}`.
# Since bash 5.2, an unescaped `&` in the REPLACEMENT of `${var//pattern/replacement}` means
# "the whole matched text" (ksh93 compat). Measured: 3.2.57 correct, 5.2.37 (mclaren, a live
# agent host) and 5.3.15 both corrupt. `_render_replace_all` must reproduce every value
# byte-for-byte in EVERY bash this project supports, because escaping `&` in the value is a
# trap that is portable in the wrong direction (bash 3.2 would insert a literal backslash).
#
# Each case: template "ref={{u}}!", placeholder "{{u}}", expected output "ref=<value>!".

@test "023/A1: a literal & in the middle of the value" {
  result=$(_render_replace_all 'ref={{u}}!' '{{u}}' 'A&B')
  [ "$result" = 'ref=A&B!' ]
}

@test "023/A2: a value consisting of only &" {
  result=$(_render_replace_all 'ref={{u}}!' '{{u}}' '&')
  [ "$result" = 'ref=&!' ]
}

@test "023/A3: multiple & occurrences in one value" {
  result=$(_render_replace_all 'ref={{u}}!' '{{u}}' '&&')
  [ "$result" = 'ref=&&!' ]
}

@test "023/A4: an operator-escaped \\& must survive with its backslash intact" {
  # In bash 5.2+, `${var//pat/repl}` with repl containing \& today EATS the
  # backslash (repl \1 is a backreference in the OLD ksh semantics too, but
  # this is testing our own value, not a regex capture — the point is the
  # value is opaque data, never interpreted).
  result=$(_render_replace_all 'ref={{u}}!' '{{u}}' '\&')
  [ "$result" = 'ref=\&!' ]
}

@test "023/A5: & at the end of the value" {
  result=$(_render_replace_all 'ref={{u}}!' '{{u}}' 'a&')
  [ "$result" = 'ref=a&!' ]
}

@test "023/A6: & at the start of the value" {
  result=$(_render_replace_all 'ref={{u}}!' '{{u}}' '&a')
  [ "$result" = 'ref=&a!' ]
}

@test "023/A7: adversarial combination of &, \$1, and \\1" {
  result=$(_render_replace_all 'ref={{u}}!' '{{u}}' '?a=1&b=2&ref=$1&v=\1')
  [ "$result" = 'ref=?a=1&b=2&ref=$1&v=\1!' ]
}

@test "023/A8: the value itself contains another placeholder-looking token" {
  result=$(_render_replace_all 'ref={{u}}!' '{{u}}' 'x{{y}}z')
  [ "$result" = 'ref=x{{y}}z!' ]
}

@test "023/A9: an empty value" {
  result=$(_render_replace_all 'ref={{u}}!' '{{u}}' '')
  [ "$result" = 'ref=!' ]
}

@test "023/A10: the value equals the placeholder itself — no re-scanning" {
  result=$(_render_replace_all 'ref={{u}}!' '{{u}}' '{{u}}')
  [ "$result" = 'ref={{u}}!' ]
}

# ─── 023-fix-render-ampersand: end-to-end on the real consumer templates ───
# The two ONLY {{#each}} consumers in the repo (grep -rn '{{#each' modules/):
# modules/mcp-json.tpl:48 and modules/env-example.tpl:14, both over
# MCPS_ATLASSIAN. This is the operator scenario, not a unit test of the
# primitive: a value with `&` reaching the generated .env / .mcp.json intact.

@test "023/E2/T005: env-example.tpl preserves a & in the atlassian url (lowercase field, render.sh:90)" {
  local tmp_yml="$BATS_TEST_TMPDIR/yml.yml"
  cat > "$tmp_yml" <<'YML'
version: 1
mcps:
  atlassian:
    - name: work
      url: 'https://work.example/wiki?a=1&b=2'
      email: 'alice@work.example'
YML
  render_load_context "$tmp_yml"
  result=$(render_template "$REPO_ROOT/modules/env-example.tpl")
  [[ "$result" == *'ATLASSIAN_WORK_CONFLUENCE_URL=https://work.example/wiki?a=1&b=2/wiki'* ]]
}

@test "023/E6/T006: mcp-json.tpl preserves a & in the UPPERCASE variable name (render.sh:95)" {
  local tmp_yml="$BATS_TEST_TMPDIR/yml.yml"
  cat > "$tmp_yml" <<'YML'
version: 1
mcps:
  atlassian:
    - name: 'w&b'
      url: 'https://wb.example'
      email: 'alice@wb.example'
YML
  render_load_context "$tmp_yml"
  result=$(render_template "$REPO_ROOT/modules/mcp-json.tpl")
  # lowercase {{name}} in the JSON key AND uppercase {{NAME}} in the env var
  # name both carry the & untouched — neither line corrupts it.
  [[ "$result" == *'"atlassian-w&b": {'* ]]
  [[ "$result" == *'"CONFLUENCE_URL": "${ATLASSIAN_W&B_CONFLUENCE_URL:-}"'* ]]
}

@test "023/E5/T007: an agent.yml with no & renders byte-identical output (no-regression)" {
  render_load_context "$REPO_ROOT/tests/fixtures/sample-agent.yml"
  env_result=$(render_template "$REPO_ROOT/modules/env-example.tpl")
  json_result=$(render_template "$REPO_ROOT/modules/mcp-json.tpl")
  [[ "$env_result" == *'ATLASSIAN_WORK_CONFLUENCE_URL=https://work.atlassian.net/wiki'* ]]
  [[ "$env_result" == *'ATLASSIAN_WORK_CONFLUENCE_USERNAME=alice@work.com'* ]]
  [[ "$json_result" == *'"atlassian-work": {'* ]]
  [[ "$json_result" == *'"CONFLUENCE_URL": "${ATLASSIAN_WORK_CONFLUENCE_URL:-}"'* ]]
}

# 023/T013: the DEDICATED, explicitly-named end-to-end test for this bug class.
# Before this, the only test that caught it was the one above named "preserves
# literal $1 and \1" — a name that sent the original investigation toward
# perl's capture-ref interpolation, which had nothing to do with it. If a call
# site regresses, THIS is the test whose name should tell you what broke and
# why, without re-deriving the diagnosis. Covers A1, A4, A7 of the contract at
# the render_template level (not the raw primitive, unlike the 023/A* tests
# above) — the same level at which the bug was originally discovered.
@test "render_template preserves a literal & in field values (bash 5.2+ ksh93 semantics)" {
  local tmp_yml="$BATS_TEST_TMPDIR/yml.yml"
  local tmp_tpl="$BATS_TEST_TMPDIR/tpl.tpl"
  cat > "$tmp_yml" <<'YML'
version: 1
mcps:
  atlassian:
    - name: 'q1\&x'
      url: 'https://q1.example/path?a=1&b=2&ref=$1&v=\1'
      email: 'a&b@example.com'
YML
  cat > "$tmp_tpl" <<'TPL'
{{#each MCPS_ATLASSIAN}}
- {{name}}: {{url}} ({{email}})
{{/each}}
TPL
  render_load_context "$tmp_yml"
  result=$(render_template "$tmp_tpl")
  # A1: & mid-value
  [[ "$result" == *'a&b@example.com'* ]]
  # A4: an operator-escaped \& must keep its backslash
  [[ "$result" == *'q1\&x'* ]]
  # A7: & combined with $1/\1 in the SAME value — the exact adversarial case
  [[ "$result" == *'https://q1.example/path?a=1&b=2&ref=$1&v=\1'* ]]
}

# 023/E7 (no-drift): guard against ever reintroducing a bash `${var//pat/repl}`
# substitution in render.sh whose replacement is data-derived — the exact
# shape of this bug. Comment lines are stripped FIRST: this file's own header
# documents the forbidden pattern in prose (`${TEXT//$PLACEHOLDER/$VALUE}` in
# the rationale comment above _render_replace_all), and a naive grep over the
# raw file would match that explanation instead of actual code — the same
# class of self-inflicted false failure that hit 3 different tests in the 022
# session. IMPORTANT: filter comments BEFORE adding line numbers with `grep
# -n` — piping `grep -n` first prepends "N:" to each line, which defeats a
# `^[[:space:]]*#` anchor (this exact ordering mistake was caught while
# writing this very test).
#
# The pattern targets bash's own substitution syntax (`${name//`), not any
# occurrence of `//` — scripts/lib/render.sh:72 uses yq's `// ""` alternative
# operator inside a query string, which is unrelated and must NOT trip this.
@test "no-drift: render.sh never re-introduces a data-derived \${var//pattern/replacement}" {
  if grep -v '^[[:space:]]*#' "$REPO_ROOT/scripts/lib/render.sh" \
      | grep -qE '\$\{[A-Za-z_][A-Za-z0-9_]*//'; then
    false
  fi
}

# 023/T019/FR-009: expose which bash a run used. This is the root cause of why
# the & bug went undetected for months: `bats` is `#!/usr/bin/env bash`, so it
# silently runs under whichever bash is first on PATH — and the SAME commit
# gave a green suite under 3.2 and a red one under 5.3 the same day on the
# same machine, with nothing recording which had run. `echo … >&3` is bats'
# diagnostic channel: it prints in a PLAIN `bats tests/` run, not only with
# -v/--verbose-run (verified empirically — a normal run above already shows
# this pattern working).
@test "bash version used for this run (diagnostic, always passes)" {
  echo "# BASH_VERSION=$BASH_VERSION" >&3
  echo "# See specs/023-fix-render-ampersand/research.md R6 for why this line exists." >&3
}

# 023/T022 regression: caught by the byte-for-byte no-regression check, NOT by
# any of the & tests above. `row_expanded=$(_render_replace_all ...)` is a
# command substitution, and $(...) unconditionally strips trailing newlines
# from whatever it captures — silently eating the blank-line separator between
# consecutive {{#each}} rows in env-example.tpl. render.sh guards against this
# with a `; printf '@'` sentinel + `%@` strip at both call sites; this test
# exists so a future refactor that drops the sentinel fails loudly here
# instead of only showing up as one fewer blank line in a generated .env.
@test "render_template does not lose the blank line between two {{#each}} rows" {
  render_load_context "$REPO_ROOT/tests/fixtures/sample-agent.yml"
  result=$(render_template "$REPO_ROOT/modules/env-example.tpl")
  [[ "$result" == *$'ATLASSIAN_WORK_TOKEN=\n\n# Atlassian workspace: personal'* ]]
}

@test "docker-compose template forwards toolchain versions as build args" {
  # The build-arg passthrough is the fix for "docker compose build ignores
  # chosen versions": agent.yml docker.* must reach the image as build.args.
  export AGENT_NAME="bot" AGENT_DISPLAY_NAME="Bot"
  export DOCKER_IMAGE_TAG="agentic-pod:latest"
  export DOCKER_UID=1000 DOCKER_GID=1000 USER_TIMEZONE=UTC
  export DOCKER_BASE_IMAGE="alpine:3.24.1"
  export DOCKER_CLAUDE_CODE_VERSION="2.1.170"
  export DOCKER_UV_VERSION="0.11.22"
  export DOCKER_BUN_VERSION="1.3.14"
  export DOCKER_GUM_VERSION="0.17.0"
  result=$(render_template "$REPO_ROOT/modules/docker-compose.yml.tpl")
  [[ "$result" == *'BASE_IMAGE: "alpine:3.24.1"'* ]]
  [[ "$result" == *'CLAUDE_CODE_VERSION: "2.1.170"'* ]]
  [[ "$result" == *'UV_VERSION: "0.11.22"'* ]]
  [[ "$result" == *'BUN_VERSION: "1.3.14"'* ]]
  [[ "$result" == *'GUM_VERSION: "0.17.0"'* ]]
}

# ── Story I: role_file → AGENT_ROLE_MULTILINE ──

@test "render_load_context exports AGENT_ROLE_MULTILINE from agent.role_file (verbatim)" {
  local persona="$BATS_TEST_TMPDIR/persona.md"
  printf 'Line one.\n\nLine two with **markdown** and an apostrophe'\''s tail.\n' > "$persona"
  local yml="$BATS_TEST_TMPDIR/role.yml"
  cat > "$yml" <<YML
agent:
  name: pbot
  role: "one-liner"
  role_file: "$persona"
YML
  render_load_context "$yml"
  [ "$AGENT_ROLE_MULTILINE" = "$(cat "$persona")" ]
  [ "$AGENT_ROLE_MULTILINE_ENABLED" = "true" ]
}

@test "render_load_context resolves a workspace-relative role_file against the agent.yml dir" {
  mkdir -p "$BATS_TEST_TMPDIR/personas"
  printf 'RELMARKER relative persona.\n' > "$BATS_TEST_TMPDIR/personas/pbot.md"
  local yml="$BATS_TEST_TMPDIR/role.yml"
  cat > "$yml" <<'YML'
agent:
  name: pbot
  role: "one-liner"
  role_file: "personas/pbot.md"
YML
  render_load_context "$yml"
  [ "$AGENT_ROLE_MULTILINE_ENABLED" = "true" ]
  grep -q "RELMARKER" <<< "$AGENT_ROLE_MULTILINE"
}

@test "render_load_context leaves the one-line role path intact when role_file is unset" {
  local yml="$BATS_TEST_TMPDIR/role.yml"
  cat > "$yml" <<'YML'
agent:
  name: pbot
  role: "just a one-liner"
YML
  render_load_context "$yml"
  [ -z "${AGENT_ROLE_MULTILINE:-}" ]
  [ "${AGENT_ROLE_MULTILINE_ENABLED:-false}" != "true" ]
  [ "$AGENT_ROLE" = "just a one-liner" ]
}

@test "render_load_context fails loud when role_file path is missing" {
  local yml="$BATS_TEST_TMPDIR/role.yml"
  cat > "$yml" <<'YML'
agent:
  name: pbot
  role: "one-liner"
  role_file: "does/not/exist.md"
YML
  run render_load_context "$yml"
  [ "$status" -ne 0 ]
  [[ "$output" == *"role_file not found"* ]]
}

@test "claude-md.tpl injects the multiline persona into the Identity section" {
  local persona="$BATS_TEST_TMPDIR/persona.md"
  printf 'PERSONAMARKER first paragraph.\n\nSecond paragraph.\n' > "$persona"
  local yml="$BATS_TEST_TMPDIR/role.yml"
  cat > "$yml" <<YML
agent:
  name: pbot
  display_name: "PBot"
  role: "one-liner"
  role_file: "$persona"
  vibe: "v"
YML
  render_load_context "$yml"
  result=$(render_template "$REPO_ROOT/modules/claude-md.tpl")
  # grep (a regular command) is caught by bats even mid-test; a failing
  # intermediate [[ ]] is silently ignored, so avoid it for the load-bearing
  # assertion.
  grep -q "PERSONAMARKER" <<< "$result"
}
