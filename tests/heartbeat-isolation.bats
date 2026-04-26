#!/usr/bin/env bats
# Tests for ensure_heartbeat_config_dir in scripts/heartbeat/heartbeat.sh.
#
# The function builds an isolated CLAUDE_CONFIG_DIR for the heartbeat's
# `claude --print` invocation. Critical invariant for the Telegram-message-
# loss bug: the heartbeat must NOT load any plugins. If settings.json or
# plugins/ are symlinked from the agent's interactive config dir, claude
# spawns the channel plugin's bun MCP server, whose stale-poller block
# SIGTERMs the bun running the user's interactive session.
#
# heartbeat.sh interleaves runtime side-effects with function defs (mkdir
# of LOG_DIR, source of state.sh, argparse loop), so we can't `source` it
# in test mode without a HEARTBEAT_NO_RUN guard. Instead we awk-extract
# just the function body into a tmpfile and source that.

load helper

HEARTBEAT_SH="$REPO_ROOT/scripts/heartbeat/heartbeat.sh"

setup() {
  setup_tmp_dir
  # Sandbox HOME so the function writes to a tmpdir, not the real home.
  export TEST_HOME="$TMP_TEST_DIR/home"
  mkdir -p "$TEST_HOME/.claude/plugins/cache/some-plugin"
  # Real-shape settings.json with multiple plugins enabled (matches the
  # post-PR-10 default catalog) plus an extraKnownMarketplaces entry that
  # would otherwise leak into the heartbeat's claude --print config.
  cat > "$TEST_HOME/.claude/settings.json" <<'JSON'
{
  "permissions": { "defaultMode": "auto" },
  "enabledPlugins": {
    "telegram@claude-plugins-official": true,
    "claude-mem@thedotmack": true,
    "context7@claude-plugins-official": true
  },
  "extraKnownMarketplaces": {
    "thedotmack": {
      "source": { "source": "github", "repo": "thedotmack/claude-mem" }
    }
  },
  "skipDangerousModePermissionPrompt": true,
  "theme": "dark"
}
JSON
  # OAuth credentials and global config that MUST be shared via symlink.
  echo '{"token":"fake-oauth"}' > "$TEST_HOME/.claude/.credentials.json"
  echo '{}' > "$TEST_HOME/.claude/.claude.json"
  # Extract only the function body — heartbeat.sh has interleaved runtime
  # side effects elsewhere that we don't want firing.
  awk '/^ensure_heartbeat_config_dir\(\) \{$/,/^\}$/' "$HEARTBEAT_SH" > "$TMP_TEST_DIR/fn.sh"
  # Sanity-check the extraction succeeded (catches future renames of the fn).
  grep -q "^ensure_heartbeat_config_dir() {$" "$TMP_TEST_DIR/fn.sh"
  grep -q "^}$" "$TMP_TEST_DIR/fn.sh"
}

teardown() { teardown_tmp_dir; }

# run_fn — source the extracted function under sandboxed HOME and call it.
# bats's `run` captures stdout into $output; the function prints the dst
# path on success, which we compare to the expected ~/.claude-heartbeat.
run_fn() {
  HOME="$TEST_HOME" bash -c "source '$TMP_TEST_DIR/fn.sh' && ensure_heartbeat_config_dir"
}

@test "settings.json is a real file (not a symlink) with plugins disabled" {
  run run_fn
  [ "$status" -eq 0 ]
  local s="$TEST_HOME/.claude-heartbeat/settings.json"
  [ -f "$s" ]
  [ ! -L "$s" ]
  # enabledPlugins must be an empty object — this is the load-bearing
  # check for the message-loss bug.
  [ "$(jq -c '.enabledPlugins' "$s")" = '{}' ]
  [ "$(jq -c '.extraKnownMarketplaces' "$s")" = '{}' ]
  # Other fields preserved from src so the heartbeat session inherits
  # auto-mode, skip-perms-prompt, theme, etc.
  [ "$(jq -r '.permissions.defaultMode' "$s")" = 'auto' ]
  [ "$(jq -r '.skipDangerousModePermissionPrompt' "$s")" = 'true' ]
  [ "$(jq -r '.theme' "$s")" = 'dark' ]
}

@test "plugins/ is an empty directory (not a symlink to the shared cache)" {
  run run_fn
  [ "$status" -eq 0 ]
  local p="$TEST_HOME/.claude-heartbeat/plugins"
  [ -d "$p" ]
  [ ! -L "$p" ]
  # Must be empty — if it had any content (or symlinked into the shared
  # cache) claude would discover the telegram plugin manifest and spawn
  # bun, which is exactly what we're preventing.
  [ -z "$(ls -A "$p")" ]
}

@test ".credentials.json + .claude.json stay symlinked (shared with the agent)" {
  run run_fn
  [ "$status" -eq 0 ]
  [ -L "$TEST_HOME/.claude-heartbeat/.credentials.json" ]
  [ -L "$TEST_HOME/.claude-heartbeat/.claude.json" ]
  # Resolves to the source (single source of truth for OAuth tokens).
  [ "$(readlink "$TEST_HOME/.claude-heartbeat/.credentials.json")" = "$TEST_HOME/.claude/.credentials.json" ]
}

@test "channels/ sessions/ cache/ are real empty dirs (isolated runtime state)" {
  run run_fn
  [ "$status" -eq 0 ]
  for sub in channels sessions cache; do
    [ -d "$TEST_HOME/.claude-heartbeat/$sub" ]
    [ ! -L "$TEST_HOME/.claude-heartbeat/$sub" ]
    [ -z "$(ls -A "$TEST_HOME/.claude-heartbeat/$sub")" ]
  done
}

@test "idempotent: re-running rewrites settings.json from src on every call" {
  run_fn
  # Mutate the heartbeat-side settings.json to confirm a re-run regenerates
  # it from src (so a stale enabledPlugins from a prior version of this fn
  # gets cleared even if it sneaks back in).
  echo '{"enabledPlugins":{"stale@bad":true}}' > "$TEST_HOME/.claude-heartbeat/settings.json"
  run run_fn
  [ "$status" -eq 0 ]
  [ "$(jq -c '.enabledPlugins' "$TEST_HOME/.claude-heartbeat/settings.json")" = '{}' ]
}

@test "idempotent: stale plugins/ symlink from a prior version is replaced with an empty dir" {
  # Pre-existing symlink: simulate a workspace previously initialized by
  # the v1 heartbeat (which symlinked plugins/). The new fn must clear
  # the symlink and replace it with an empty dir.
  mkdir -p "$TEST_HOME/.claude-heartbeat"
  ln -s "$TEST_HOME/.claude/plugins" "$TEST_HOME/.claude-heartbeat/plugins"
  [ -L "$TEST_HOME/.claude-heartbeat/plugins" ]
  run run_fn
  [ "$status" -eq 0 ]
  [ ! -L "$TEST_HOME/.claude-heartbeat/plugins" ]
  [ -d "$TEST_HOME/.claude-heartbeat/plugins" ]
  [ -z "$(ls -A "$TEST_HOME/.claude-heartbeat/plugins")" ]
}

@test "idempotent: stale settings.json symlink from a prior version is replaced with a real file" {
  # Pre-existing symlink for settings.json (v1 behavior).
  mkdir -p "$TEST_HOME/.claude-heartbeat"
  ln -s "$TEST_HOME/.claude/settings.json" "$TEST_HOME/.claude-heartbeat/settings.json"
  [ -L "$TEST_HOME/.claude-heartbeat/settings.json" ]
  run run_fn
  [ "$status" -eq 0 ]
  [ ! -L "$TEST_HOME/.claude-heartbeat/settings.json" ]
  [ -f "$TEST_HOME/.claude-heartbeat/settings.json" ]
  [ "$(jq -c '.enabledPlugins' "$TEST_HOME/.claude-heartbeat/settings.json")" = '{}' ]
}

@test "fallback when src settings.json missing: writes minimal stub" {
  rm "$TEST_HOME/.claude/settings.json"
  run run_fn
  [ "$status" -eq 0 ]
  local s="$TEST_HOME/.claude-heartbeat/settings.json"
  [ -f "$s" ]
  [ "$(jq -c '.enabledPlugins' "$s")" = '{}' ]
  [ "$(jq -c '.extraKnownMarketplaces' "$s")" = '{}' ]
}

@test "function prints the destination path on stdout" {
  run run_fn
  [ "$status" -eq 0 ]
  [ "$output" = "$TEST_HOME/.claude-heartbeat" ]
}

@test "function returns 1 if HOME/.claude does not exist" {
  rm -rf "$TEST_HOME/.claude"
  run run_fn
  [ "$status" -eq 1 ]
}
