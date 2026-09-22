#!/usr/bin/env bats
#
# 030 — warm cache for out-of-catalog MCPs. Derivation (mcp_warm_targets) is a
# pure function over the effective .mcp.json; the warmer (mcp_warm_run) is
# fail-soft, idempotent, and reads no secrets.
# Contract: specs/030-mcp-warm-cache/contracts/warm-derivation.md + boot-integration.md

load helper

setup() {
  setup_tmp_dir
  load_lib mcp_warm
  MCP_JSON="$TMP_TEST_DIR/.mcp.json"
}

teardown() { teardown_tmp_dir; }

# uv/npm stubs on PATH: log every call; exit code controllable via $1.
_install_warm_stubs() {
  local rc="${1:-0}" dir="$TMP_TEST_DIR/bin"
  mkdir -p "$dir"
  cat > "$dir/uv" <<EOF
#!/bin/sh
echo "uv \$*" >> "$TMP_TEST_DIR/warm.log"
exit ${rc}
EOF
  cat > "$dir/npm" <<EOF
#!/bin/sh
echo "npm \$*" >> "$TMP_TEST_DIR/warm.log"
exit ${rc}
EOF
  chmod +x "$dir/uv" "$dir/npm"
  export PATH="$dir:$PATH"
}

# ── Derivation: all catalog + overlay shapes (contract C1-C3, cases 1-10) ────

@test "030: mcp_warm_targets derives uvx/npx across every shape (cases 1-10)" {
  cat > "$MCP_JSON" <<'EOF'
{
  "mcpServers": {
    "fetch":      { "command": "uvx", "args": ["mcp-server-fetch"] },
    "git":        { "command": "uvx", "args": ["mcp-server-git", "--repository", "/workspace"] },
    "filesystem": { "command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "/home/agent"] },
    "playwright": { "command": "npx", "args": ["@playwright/mcp@latest"] },
    "google-workspace": { "command": "/workspace/.custom/seed-google-creds.sh", "args": ["uvx", "workspace-mcp"] },
    "firecrawl":  { "command": "npx", "args": ["-y", "firecrawl-mcp"] },
    "open-meteo": { "command": "npx", "args": ["-p", "open-meteo-mcp@2.0.1", "open-meteo-mcp"] },
    "mcpvault":   { "command": "npx", "args": ["-y", "@bitbonsai/mcpvault@0.12.0", "/vault"] },
    "github":     { "command": "github-mcp-server", "args": ["stdio"] },
    "qmd":        { "command": "/opt/agent-admin/scripts/qmd-mcp", "args": [] }
  }
}
EOF
  run mcp_warm_targets "$MCP_JSON"
  [ "$status" -eq 0 ]
  # exact, sorted set — github + qmd omitted (no uvx/npx token)
  expected=$(printf '%s\n' \
    "npx	@bitbonsai/mcpvault@0.12.0" \
    "npx	@modelcontextprotocol/server-filesystem" \
    "npx	@playwright/mcp@latest" \
    "npx	firecrawl-mcp" \
    "npx	open-meteo-mcp@2.0.1" \
    "uvx	mcp-server-fetch" \
    "uvx	mcp-server-git" \
    "uvx	workspace-mcp" | sort)
  [ "$output" = "$expected" ]
}

@test "030: the incident case (google-workspace wrapper) is derived (case 5)" {
  cat > "$MCP_JSON" <<'EOF'
{ "mcpServers": { "google-workspace": {
  "command": "/workspace/.custom/seed-google-creds.sh", "args": ["uvx", "workspace-mcp"] } } }
EOF
  run mcp_warm_targets "$MCP_JSON"
  [ "$status" -eq 0 ]
  [ "$output" = "uvx	workspace-mcp" ]
}

@test "030: npx -p takes the package after the flag, not the bin name (case 7)" {
  cat > "$MCP_JSON" <<'EOF'
{ "mcpServers": { "om": { "command": "npx", "args": ["-p", "open-meteo-mcp@2.0.1", "open-meteo-mcp"] } } }
EOF
  run mcp_warm_targets "$MCP_JSON"
  [ "$output" = "npx	open-meteo-mcp@2.0.1" ]
}

@test "030: binaries and wrappers-to-baked are omitted (cases 9,10)" {
  cat > "$MCP_JSON" <<'EOF'
{ "mcpServers": {
  "github": { "command": "github-mcp-server", "args": ["stdio"] },
  "qmd":    { "command": "/opt/agent-admin/scripts/qmd-mcp", "args": [] } } }
EOF
  run mcp_warm_targets "$MCP_JSON"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "030: duplicate (runtime,package) is deduped (case 11)" {
  cat > "$MCP_JSON" <<'EOF'
{ "mcpServers": {
  "a": { "command": "uvx", "args": ["mcp-server-fetch"] },
  "b": { "command": "uvx", "args": ["mcp-server-fetch"] } } }
EOF
  run mcp_warm_targets "$MCP_JSON"
  [ "$output" = "uvx	mcp-server-fetch" ]
}

@test "030: absent .mcp.json → zero lines, rc 0 (case 12)" {
  run mcp_warm_targets "$TMP_TEST_DIR/nope.json"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ── Robustness (contract C4) ─────────────────────────────────────────────────

@test "030: empty mcpServers → zero lines, rc 0" {
  echo '{ "mcpServers": {} }' > "$MCP_JSON"
  run mcp_warm_targets "$MCP_JSON"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "030: a server without args does not abort derivation" {
  cat > "$MCP_JSON" <<'EOF'
{ "mcpServers": {
  "weird": { "command": "npx" },
  "ok":    { "command": "uvx", "args": ["mcp-server-fetch"] } } }
EOF
  run mcp_warm_targets "$MCP_JSON"
  [ "$status" -eq 0 ]
  [ "$output" = "uvx	mcp-server-fetch" ]
}

# ── General / derived, no hardcode (US2 / SC-002) ────────────────────────────

@test "030: mixed catalog+overlay derives ALL uvx/npx with no hardcoded list" {
  cat > "$MCP_JSON" <<'EOF'
{ "mcpServers": {
  "atlassian": { "command": "uvx", "args": ["mcp-atlassian"] },
  "gws":       { "command": "/w/seed.sh", "args": ["uvx", "workspace-mcp"] },
  "brave":     { "command": "npx", "args": ["-y", "@brave/brave-search-mcp-server@2.1.0"] } } }
EOF
  run mcp_warm_targets "$MCP_JSON"
  echo "$output" | grep -q '^uvx	mcp-atlassian$'
  echo "$output" | grep -q '^uvx	workspace-mcp$'
  echo "$output" | grep -q '^npx	@brave/brave-search-mcp-server@2.1.0$'
}

# ── Warmer: fail-soft + idempotent + no secrets (US3 / FR-005/006/007/008) ───

@test "030: mcp_warm_run warms each target and returns 0 (uv/npm stubs)" {
  _install_warm_stubs 0
  cat > "$MCP_JSON" <<'EOF'
{ "mcpServers": {
  "fetch": { "command": "uvx", "args": ["mcp-server-fetch"] },
  "fs":    { "command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "/x"] } } }
EOF
  run mcp_warm_run "$MCP_JSON"
  [ "$status" -eq 0 ]
  grep -q 'uv tool install' "$TMP_TEST_DIR/warm.log"
  grep -q 'npm exec' "$TMP_TEST_DIR/warm.log"
}

@test "030: mcp_warm_run is fail-soft — a failing warmer does not abort (FR-007/008/SC-004)" {
  _install_warm_stubs 1   # every warm fails
  cat > "$MCP_JSON" <<'EOF'
{ "mcpServers": { "fetch": { "command": "uvx", "args": ["mcp-server-fetch"] } } }
EOF
  run mcp_warm_run "$MCP_JSON"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'mcp-server-fetch'          # trace names the package
  echo "$output" | grep -qi 'will resolve on first use'
}

@test "030: mcp_warm_run is idempotent — safe to re-run (FR-005)" {
  _install_warm_stubs 0
  cat > "$MCP_JSON" <<'EOF'
{ "mcpServers": { "fetch": { "command": "uvx", "args": ["mcp-server-fetch"] } } }
EOF
  run mcp_warm_run "$MCP_JSON"
  [ "$status" -eq 0 ]
  run mcp_warm_run "$MCP_JSON"   # second pass, same input
  [ "$status" -eq 0 ]
}

@test "030: mcp_warm.sh reads no secrets (FR-006/SC-005)" {
  # static guarantee: the CODE (comments excluded) must never touch .env /
  # credentials / keys / age files. Comments may mention them to document the
  # no-secrets property, so strip comment lines before asserting.
  run bash -c "grep -vE '^[[:space:]]*#' '$REPO_ROOT/scripts/lib/mcp_warm.sh' | grep -nE '\\.env|GOOGLE_OAUTH|credential|id_rsa|\\.age|\\.ssh'"
  [ "$status" -ne 0 ]   # no matches in code
}

@test "030: sourcing mcp_warm.sh has no side effects" {
  # sourcing (done in setup via load_lib) must not run anything; a fresh source
  # produces no output and rc 0.
  run bash -c "source '$REPO_ROOT/scripts/lib/mcp_warm.sh'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ══ 036 — US1: the warm actually warms, and says which failure it hit ═════════
#
# Contract: specs/036-cold-start-boot-resilience/contracts/mcp-warm-contract.md
# CANON strings: specs/036-cold-start-boot-resilience/data-model.md §2 and §3.
# Every warn string below is copied VERBATIM from data-model; a paraphrase here
# is the drift this convention exists to prevent (lesson of 033/034).

# A single .mcp.json with exactly one uvx target: workspace-mcp — the package
# that failed in the live incident.
_one_uvx_target() {
  cat > "$MCP_JSON" <<'EOF'
{
  "mcpServers": {
    "google-workspace": { "command": "uvx", "args": ["workspace-mcp"] }
  }
}
EOF
}

# uv stub whose exit code is controllable, logging the full argv so the oracle
# can assert on the flags the installer was actually called with.
_install_uv_stub() {
  local rc="${1:-0}" dir="$TMP_TEST_DIR/bin"
  mkdir -p "$dir"
  cat > "$dir/uv" <<EOF
#!/bin/sh
echo "uv \$*" >> "$TMP_TEST_DIR/warm.log"
exit ${rc}
EOF
  chmod +x "$dir/uv"
  export PATH="$dir:$PATH"
}

@test "036 US1: the installer is NOT called with --force (C1)" {
  # This oracle is inverted from its first revision, and the reversal is the
  # point. The live failure is uv exiting 2 in 0s with "Executable already
  # exists" when a dangling link from a previous image holds the name, and
  # --force does clear it — but so does removing the link first, which the
  # pruner already does. Measured in the real image against the pre-036 layout:
  # install alone rc=2, --force rc=0, prune-then-install rc=0.
  #
  # Since both work, the tie is broken on blast radius: every uvx MCP is
  # declared unversioned, so a forced reinstall on every boot and every watchdog
  # respawn is an unattended version change waiting to happen. The pruner is the
  # cure; --force would be a second one carrying a risk the first does not.
  _one_uvx_target
  _install_uv_stub 0
  run mcp_warm_run "$MCP_JSON"
  [ "$status" -eq 0 ]
  run grep -cF -- '--force' "$TMP_TEST_DIR/warm.log"
  [ "$output" = "0" ]
  # …and the install did happen, so this is not passing by silence.
  run grep -cF 'tool install' "$TMP_TEST_DIR/warm.log"
  [ "$output" = "1" ]
}

@test "036 US1: a non-zero installer exit reports CANON-W1 with the exit code" {
  _one_uvx_target
  _install_uv_stub 2
  run mcp_warm_run "$MCP_JSON"
  [ "$status" -eq 0 ]
  run bash -c "printf '%s\n' \"\$1\" | grep -cF 'mcp_warm: warn: uvx workspace-mcp failed (exit 2) — will resolve on first use'" _ "$output"
  [ "$output" = "1" ]
}

@test "036 US1: an expiring timeout reports CANON-W2, for BOTH 124 and 143" {
  # MEASURED (data-model §2): GNU timeout reports 124 on expiry, but busybox
  # timeout — which is what the Alpine image actually ships — reports 143
  # (128+SIGTERM). Classifying only on 124 would label every real in-container
  # timeout as "failed (exit 143)", re-creating the ambiguity US1 removes.
  local rc
  for rc in 124 143; do
    rm -f "$TMP_TEST_DIR/warm.log"
    _one_uvx_target
    _install_uv_stub "$rc"
    run mcp_warm_run "$MCP_JSON"
    [ "$status" -eq 0 ]
    run bash -c "printf '%s\n' \"\$1\" | grep -cF 'mcp_warm: warn: uvx workspace-mcp timed out after 300s — will resolve on first use'" _ "$output"
    [ "$output" = "1" ]
  done
}

@test "036 US1: a missing runtime reports CANON-W3, not a generic failure" {
  _one_uvx_target
  # Prune PATH so `uv` genuinely cannot be found, while keeping `jq` (in
  # /usr/bin on both CI arms) so the derivation still yields the target —
  # otherwise the run produces zero targets and the oracle passes vacuously.
  run env PATH=/usr/bin:/bin bash -c "source '$REPO_ROOT/scripts/lib/mcp_warm.sh'; mcp_warm_run '$MCP_JSON' 2>&1"
  [ "$status" -eq 0 ]
  run bash -c "printf '%s\n' \"\$1\" | grep -cF 'mcp_warm: warn: uvx unavailable (uv not on PATH) — skipping workspace-mcp'" _ "$output"
  [ "$output" = "1" ]
}

# ── The stale-link pruner (data-model §3, contract C10) ──────────────────────
#
# EVERY case below runs against a scratch HOME. tests/mcp-warm.bats does not
# override HOME today (unlike start-services-warm.bats:14-15), and this library
# is ALSO sourced on the operator's own machine by modules/local-bootstrap.sh.tpl,
# where ~/.local/bin holds the real uv, bun, node and github-mcp-server links.
# A pruner test that scanned the developer's actual home is a bug waiting to run.
# NOT a command substitution — that was the bug. `bin="$(_scratch_bin)"` runs the
# function in a SUBSHELL, so its `export HOME` dies with that subshell and the
# test body keeps the developer's REAL home. Every case here then believed it was
# sandboxed while `$HOME` pointed at the operator's actual directory. Harmless as
# long as each call passes an explicit path — but mutation M19 reinstates a
# default of `$HOME/.local/bin` inside a function containing `rm`, and under that
# mutation the no-argument case below would have scanned, and pruned, the
# developer's own ~/.local/bin. Caught by the adversarial review; M19 never
# actually applied in the mutation harness, so it was never executed.
#
# Sets SCRATCH_BIN in the caller's scope instead.
_scratch_bin() {
  export HOME="$TMP_TEST_DIR/home"
  mkdir -p "$HOME/.local/bin" "$TMP_TEST_DIR/opt/uv/tools/live/bin"
  printf '#!/bin/sh\n' > "$TMP_TEST_DIR/opt/uv/tools/live/bin/live-tool"
  chmod +x "$TMP_TEST_DIR/opt/uv/tools/live/bin/live-tool"
  SCRATCH_BIN="$HOME/.local/bin"
}

@test "036 US1: the pruner removes a dangling link into /opt/uv/tools" {
  _scratch_bin; local bin="$SCRATCH_BIN"
  ln -s /opt/uv/tools/workspace-mcp/bin/workspace-cli "$bin/workspace-cli"
  [ -L "$bin/workspace-cli" ]
  run mcp_warm_prune_stale_links "$bin"
  [ "$status" -eq 0 ]
  [ ! -L "$bin/workspace-cli" ]
  [ ! -e "$bin/workspace-cli" ]
}

@test "036 US1: the pruner keeps a link that resolves, a regular file, and a link pointing elsewhere" {
  _scratch_bin; local bin="$SCRATCH_BIN"
  ln -s "$TMP_TEST_DIR/opt/uv/tools/live/bin/live-tool" "$bin/live-tool"
  printf '#!/bin/sh\n' > "$bin/regular-file"; chmod +x "$bin/regular-file"
  ln -s /somewhere/else/that/does/not/exist "$bin/foreign-link"
  run mcp_warm_prune_stale_links "$bin"
  [ "$status" -eq 0 ]
  [ -L "$bin/live-tool" ]
  [ -f "$bin/regular-file" ]
  [ -L "$bin/foreign-link" ]
}

@test "036 US1: the pruner logs CANON-W4 only when it removed something, and is idempotent" {
  _scratch_bin; local bin="$SCRATCH_BIN"
  ln -s /opt/uv/tools/a/bin/a "$bin/a"
  ln -s /opt/uv/tools/b/bin/b "$bin/b"
  run bash -c "source '$REPO_ROOT/scripts/lib/mcp_warm.sh'; mcp_warm_prune_stale_links '$bin' 2>&1"
  [ "$status" -eq 0 ]
  run bash -c "printf '%s\n' \"\$1\" | grep -cF 'mcp_warm: pruned 2 stale uv link(s) from $bin (image rebuild leaves them dangling)'" _ "$output"
  [ "$output" = "1" ]
  # Second run: nothing left to remove, nothing logged.
  run bash -c "source '$REPO_ROOT/scripts/lib/mcp_warm.sh'; mcp_warm_prune_stale_links '$bin' 2>&1"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "036 US1: the pruner refuses to run without an explicit directory (C10 oracle b)" {
  # The argument is MANDATORY, with no default. A function containing `rm` whose
  # default target is the operator's own bin directory is one careless call from
  # damage — adversarial-review finding #11. Mutation M19 reinstates the default
  # and must turn this red.
  _scratch_bin; local bin="$SCRATCH_BIN"
  ln -s /opt/uv/tools/x/bin/x "$bin/x"
  run mcp_warm_prune_stale_links
  [ "$status" -eq 0 ]
  run mcp_warm_prune_stale_links ""
  [ "$status" -eq 0 ]
  # Nothing was scanned: the dangling link under the scratch HOME survives.
  [ -L "$bin/x" ]
  # Static half: the library never names a default bin directory.
  run bash -c "grep -vE '^[[:space:]]*#' '$REPO_ROOT/scripts/lib/mcp_warm.sh' | grep -cF 'DIR:-'"
  [ "$output" = "0" ]
}
