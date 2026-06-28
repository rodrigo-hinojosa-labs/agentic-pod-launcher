#!/usr/bin/env bats
# 009-fix-extra-marketplace-install: ensure_extra_marketplaces must RESOLVE every
# third-party marketplace declared by the agent's plugins with a CONFIRMED
# `claude plugin marketplace add` BEFORE the plugin install loop — the official
# marketplace is registered+confirmed (ensure_official_marketplace) but the
# third-party ones were only merged into settings.json's extraKnownMarketplaces
# (no add/confirm), so `claude plugin install foo@thirdparty` errored
# "marketplace not found" and was skipped without retry. Like its official
# sibling it is idempotent (guarded by `marketplace list`), bounds each claude
# call with `timeout` (degrade to a direct call if absent) and is fail-silent.
# Host-side, no Docker.
#
# Portability: the runtime image (Alpine/busybox) ships `timeout`; the dev host
# (macOS) may not. The bounded test installs a small enforcing `timeout` shim on
# PATH so it is deterministic everywhere.

load helper

setup() {
  setup_tmp_dir
  export START_SERVICES_NO_RUN=1
  export WORKDIR="$TMP_TEST_DIR"
  export HOME="$TMP_TEST_DIR/home"
  mkdir -p "$HOME" "$TMP_TEST_DIR/bin"
  unset CLAUDE_CODE_OAUTH_TOKEN
  # shellcheck source=/dev/null
  source "$REPO_ROOT/docker/scripts/start_services.sh"
  _stub_catalog
}

teardown() { teardown_tmp_dir; }

# Override the catalog derivation so the function sees one third-party
# marketplace (thedotmack → repo thedotmack/claude-mem) regardless of whether
# the image-baked plugin-catalog lib is sourced on the host. `command -v` must
# find these so ensure_extra_marketplaces proceeds past its guards.
_stub_catalog() {
  plugin_catalog_specs() { printf '%s\n' "claude-mem@thedotmack"; }
  plugin_catalog_marketplaces_json() {
    printf '%s' '{"thedotmack":{"source":{"source":"github","repo":"thedotmack/claude-mem"}}}'
  }
  export -f plugin_catalog_specs plugin_catalog_marketplaces_json
}

# A `claude` stub where `marketplace list` shows NOTHING (not yet resolved) and
# `marketplace add` succeeds and records that it ran (so the test can assert the
# add actually fired).
_install_claude_not_registered() {
  cat > "$TMP_TEST_DIR/bin/claude" <<EOF
#!/bin/sh
if [ "\$2" = "marketplace" ] && [ "\$3" = "list" ]; then
  exit 0   # prints nothing → key not found → proceed to add
fi
if [ "\$2" = "marketplace" ] && [ "\$3" = "add" ]; then
  echo "\$4" > "$TMP_TEST_DIR/add-called"
  exit 0
fi
exit 0
EOF
  chmod +x "$TMP_TEST_DIR/bin/claude"
}

# A `claude` stub where `marketplace list` ALREADY shows the third-party key →
# the function must treat it as resolved and NOT call add.
_install_claude_already_registered() {
  cat > "$TMP_TEST_DIR/bin/claude" <<EOF
#!/bin/sh
if [ "\$2" = "marketplace" ] && [ "\$3" = "list" ]; then
  echo "thedotmack"
  exit 0
fi
if [ "\$2" = "marketplace" ] && [ "\$3" = "add" ]; then
  echo "\$4" > "$TMP_TEST_DIR/add-called"
  exit 0
fi
exit 0
EOF
  chmod +x "$TMP_TEST_DIR/bin/claude"
}

# A `claude` stub where `marketplace add` WEDGES as a single process so a
# SIGTERM from timeout actually kills it. `list` returns fast (not registered).
_install_claude_add_hangs() {
  cat > "$TMP_TEST_DIR/bin/claude" <<'EOF'
#!/bin/sh
if [ "$2" = "marketplace" ] && [ "$3" = "list" ]; then
  exit 0
fi
if [ "$2" = "marketplace" ] && [ "$3" = "add" ]; then
  exec sleep 6
fi
exit 0
EOF
  chmod +x "$TMP_TEST_DIR/bin/claude"
}

# Minimal enforcing `timeout SECS CMD...` shim (deterministic on hosts lacking
# the real one). Mirrors tests/start-services-marketplace.bats.
_install_timeout_shim() {
  cat > "$TMP_TEST_DIR/bin/timeout" <<'EOF'
#!/bin/sh
secs="$1"; shift
"$@" &
pid=$!
( sleep "$secs"; kill -TERM "$pid" 2>/dev/null; sleep 1; kill -KILL "$pid" 2>/dev/null ) &
killer=$!
wait "$pid" 2>/dev/null; st=$?
kill -TERM "$killer" 2>/dev/null
exit "$st"
EOF
  chmod +x "$TMP_TEST_DIR/bin/timeout"
}

# --- US1: register a third-party marketplace when not yet resolved -----------

@test "ensure_extra_marketplaces registers a third-party marketplace via 'marketplace add' when absent" {
  _install_claude_not_registered
  export PATH="$TMP_TEST_DIR/bin:$PATH"
  run ensure_extra_marketplaces
  [ "$status" -eq 0 ]
  # The add fired against the declared repo.
  [ -f "$TMP_TEST_DIR/add-called" ]
  [ "$(cat "$TMP_TEST_DIR/add-called")" = "thedotmack/claude-mem" ]
}

@test "ensure_extra_marketplaces is idempotent — no 'add' when already resolved" {
  _install_claude_already_registered
  export PATH="$TMP_TEST_DIR/bin:$PATH"
  run ensure_extra_marketplaces
  [ "$status" -eq 0 ]
  # marketplace list already showed the key → add must NOT have run.
  [ ! -f "$TMP_TEST_DIR/add-called" ]
}

# --- US2: degrade gracefully -------------------------------------------------

@test "ensure_extra_marketplaces returns bounded (does not hang) when claude hangs on add" {
  _install_claude_add_hangs
  _install_timeout_shim
  export PATH="$TMP_TEST_DIR/bin:$PATH"
  export MARKETPLACE_CMD_TIMEOUT=1
  local start end elapsed
  start=$(date +%s)
  run ensure_extra_marketplaces
  end=$(date +%s)
  elapsed=$(( end - start ))
  [ "$status" -eq 0 ]            # fail-silent
  [ "$elapsed" -lt 5 ]          # bounded (~1-2s), not the 6s the unbounded add would block
}

@test "ensure_extra_marketplaces degrades to a direct call when timeout is absent" {
  _install_claude_not_registered
  # PATH with our bin (claude) but WITHOUT a timeout shim, and stripped of any
  # real timeout, so the degraded branch is exercised deterministically.
  export PATH="$TMP_TEST_DIR/bin:/usr/bin:/bin"
  run ensure_extra_marketplaces
  [ "$status" -eq 0 ]
  [ -f "$TMP_TEST_DIR/add-called" ]
}

@test "ensure_extra_marketplaces stays a no-op (exit 0) when claude is absent" {
  mkdir -p "$TMP_TEST_DIR/empty-bin"
  PATH="$TMP_TEST_DIR/empty-bin" run ensure_extra_marketplaces
  [ "$status" -eq 0 ]
}
