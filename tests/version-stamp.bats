#!/usr/bin/env bats
# Tests for the launcher version stamping introduced in 0.1.0:
#   - VERSION file at repo root
#   - setup.sh --version / -V prints VERSION and exits 0
#   - First-run wizard stamps meta.launcher_version + meta.scaffolded_at
#   - --regenerate refreshes meta.launcher_version + meta.regenerated_at

load helper

setup() {
  setup_tmp_dir
  mkdir -p "$TMP_TEST_DIR/installer"
  cp -r "$REPO_ROOT/scripts" "$REPO_ROOT/modules" "$TMP_TEST_DIR/installer/"
  cp "$REPO_ROOT/setup.sh" "$REPO_ROOT/VERSION" "$TMP_TEST_DIR/installer/"
  [ -f "$REPO_ROOT/.gitignore" ] && cp "$REPO_ROOT/.gitignore" "$TMP_TEST_DIR/installer/"
  [ -f "$REPO_ROOT/LICENSE" ] && cp "$REPO_ROOT/LICENSE" "$TMP_TEST_DIR/installer/"
}

teardown() { teardown_tmp_dir; }

@test "VERSION file exists at repo root and is non-empty semver" {
  [ -f "$REPO_ROOT/VERSION" ]
  local v
  v=$(tr -d '[:space:]' < "$REPO_ROOT/VERSION")
  [ -n "$v" ]
  [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$ ]]
}

@test "--version prints VERSION verbatim and exits 0" {
  cd "$TMP_TEST_DIR/installer"
  run ./setup.sh --version
  [ "$status" -eq 0 ]
  local expected
  expected=$(tr -d '[:space:]' < ./VERSION)
  [ "$output" = "$expected" ]
}

@test "-V short flag is equivalent to --version" {
  cd "$TMP_TEST_DIR/installer"
  run ./setup.sh -V
  [ "$status" -eq 0 ]
  local expected
  expected=$(tr -d '[:space:]' < ./VERSION)
  [ "$output" = "$expected" ]
}

@test "wizard stamps meta.launcher_version + scaffolded_at on scaffold" {
  local dest="$TMP_TEST_DIR/v-bot"
  cd "$TMP_TEST_DIR/installer"
  wizard_answers name=v-bot display=VBot | ./setup.sh --destination "$dest"

  [ -f "$dest/agent.yml" ]
  local stamped
  stamped=$(yq '.meta.launcher_version' "$dest/agent.yml")
  local expected
  expected=$(tr -d '[:space:]' < ./VERSION)
  [ "$stamped" = "$expected" ]

  # scaffolded_at is an ISO 8601 UTC timestamp ending in Z.
  local scaffolded
  scaffolded=$(yq '.meta.scaffolded_at' "$dest/agent.yml")
  [[ "$scaffolded" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "--regenerate refreshes meta.launcher_version + sets meta.regenerated_at" {
  local dest="$TMP_TEST_DIR/regen-bot"
  cd "$TMP_TEST_DIR/installer"
  wizard_answers name=regen-bot display=RegenBot | ./setup.sh --destination "$dest"

  # The wizard's final regenerate() step already stamps both fields, so
  # tamper them to a known stale value first; the explicit --regenerate
  # below has to refresh them past those values to pass.
  local stale_ts="2020-01-01T00:00:00Z"
  yq -i ".meta.launcher_version = \"stale-version\" | .meta.regenerated_at = \"$stale_ts\"" \
    "$dest/agent.yml"
  [ "$(yq '.meta.launcher_version' "$dest/agent.yml")" = "stale-version" ]
  [ "$(yq '.meta.regenerated_at' "$dest/agent.yml")" = "$stale_ts" ]

  cd "$dest"
  ./setup.sh --regenerate

  local after_v after_regen expected
  after_v=$(yq '.meta.launcher_version' "$dest/agent.yml")
  after_regen=$(yq '.meta.regenerated_at' "$dest/agent.yml")
  expected=$(tr -d '[:space:]' < "$REPO_ROOT/VERSION")
  [ "$after_v" = "$expected" ]
  [ "$after_regen" != "$stale_ts" ]
  [[ "$after_regen" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "missing VERSION file falls back to literal 'unknown'" {
  rm -f "$TMP_TEST_DIR/installer/VERSION"
  cd "$TMP_TEST_DIR/installer"
  run ./setup.sh --version
  [ "$status" -eq 0 ]
  [ "$output" = "unknown" ]
}
