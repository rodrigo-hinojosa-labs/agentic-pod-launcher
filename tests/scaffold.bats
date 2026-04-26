#!/usr/bin/env bats

load helper

setup() {
  setup_tmp_dir
  mkdir -p "$TMP_TEST_DIR/installer"
  cp -r "$REPO_ROOT/scripts" "$REPO_ROOT/modules" "$TMP_TEST_DIR/installer/"
  cp "$REPO_ROOT/setup.sh" "$TMP_TEST_DIR/installer/"
  [ -f "$REPO_ROOT/.gitignore" ] && cp "$REPO_ROOT/.gitignore" "$TMP_TEST_DIR/installer/"
  [ -f "$REPO_ROOT/LICENSE" ] && cp "$REPO_ROOT/LICENSE" "$TMP_TEST_DIR/installer/"
}

teardown() { teardown_tmp_dir; }

# Helper: run wizard with default answers, given --destination
run_wizard_with_dest() {
  local dest="$1"
  cd "$TMP_TEST_DIR/installer"
  ./setup.sh --destination "$dest" <<EOF
test-bot
TestBot
r
v
Alice
Alice
UTC
a@b.com
en
host
n
n
none
n
n
y
30m
ok
y
proceed
EOF
}

@test "scaffold fails when destination already exists" {
  local dest="$TMP_TEST_DIR/existing"
  mkdir "$dest"
  run run_wizard_with_dest "$dest"
  [ "$status" -ne 0 ]
  [[ "$output" == *"destination already exists"* ]]
}

@test "scaffold fails when destination equals \$HOME" {
  run run_wizard_with_dest "$HOME"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot be \$HOME"* ]]
}

@test "--in-place skips scaffold (files stay in installer)" {
  cd "$TMP_TEST_DIR/installer"
  run ./setup.sh --in-place <<EOF
inp-bot
InpBot
r
v
Alice
Alice
UTC
a@b.com
en
host
$TMP_TEST_DIR/whatever
n
n
none
n
n
y
30m
ok
y
proceed
EOF
  [ "$status" -eq 0 ]
  [ -f "$TMP_TEST_DIR/installer/agent.yml" ]
  [ -f "$TMP_TEST_DIR/installer/CLAUDE.md" ]
  [ ! -d "$TMP_TEST_DIR/whatever" ]  # destination NOT created
}

@test "scaffolded destination has git repo on {agent}/live branch" {
  local dest="$TMP_TEST_DIR/scaffold-git"
  run run_wizard_with_dest "$dest"
  [ "$status" -eq 0 ]
  [ -d "$dest/.git" ]
  [ "$(git -C "$dest" rev-parse --abbrev-ref HEAD)" = "test-bot/live" ]
  # Initial commit should exist
  [ -n "$(git -C "$dest" log --oneline)" ]
}

@test "scaffolded agent.yml includes the 5 default plugins from the catalog" {
  local dest="$TMP_TEST_DIR/scaffold-plugins"
  run run_wizard_with_dest "$dest"
  [ "$status" -eq 0 ]
  [ -f "$dest/agent.yml" ]
  local plugin_count
  plugin_count=$(yq '.plugins | length' "$dest/agent.yml")
  [ "$plugin_count" -eq 5 ]
  yq -r '.plugins[]' "$dest/agent.yml" | grep -q "^telegram@claude-plugins-official$"
  yq -r '.plugins[]' "$dest/agent.yml" | grep -q "^claude-mem@thedotmack$"
  yq -r '.plugins[]' "$dest/agent.yml" | grep -q "^context7@claude-plugins-official$"
  yq -r '.plugins[]' "$dest/agent.yml" | grep -q "^claude-md-management@claude-plugins-official$"
  yq -r '.plugins[]' "$dest/agent.yml" | grep -q "^security-guidance@claude-plugins-official$"
}

@test "scaffold mirrors plugin-catalog.sh + modules/plugins/ into docker/ build context" {
  local dest="$TMP_TEST_DIR/scaffold-mirror"
  run run_wizard_with_dest "$dest"
  [ "$status" -eq 0 ]
  [ -f "$dest/docker/scripts/lib/plugin-catalog.sh" ]
  [ -d "$dest/docker/modules/plugins" ]
  [ -f "$dest/docker/modules/plugins/telegram.yml" ]
  [ -f "$dest/docker/modules/plugins/claude-mem.yml" ]
}
