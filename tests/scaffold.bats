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
n
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
n
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
  [ -f "$dest/docker/modules/plugins/superpowers.yml" ]
  # caveman.yml dropped — single-skill repo, not a CC marketplace.
  [ ! -f "$dest/docker/modules/plugins/caveman.yml" ]
}

@test "wizard opt-in for superpowers appends it to agent.yml plugins" {
  local dest="$TMP_TEST_DIR/scaffold-optin-sp"
  cd "$TMP_TEST_DIR/installer"
  # Stream order, then 5 optional answers (alphabetical):
  #   code-simplifier=n, commit-commands=n, github=n, skill-creator=n,
  #   superpowers=y → finally `proceed` for the review.
  ./setup.sh --destination "$dest" <<EOF
opt-bot
OptBot
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
n
n
n
n
n
y
proceed
EOF
  [ -f "$dest/agent.yml" ]
  local plugin_count
  plugin_count=$(yq '.plugins | length' "$dest/agent.yml")
  [ "$plugin_count" -eq 6 ]
  yq -r '.plugins[]' "$dest/agent.yml" | grep -q "^superpowers@claude-plugins-official$"
}

@test "scaffolded NEXT_STEPS.md includes the Plugins block with descriptions" {
  local dest="$TMP_TEST_DIR/scaffold-next-steps"
  run run_wizard_with_dest "$dest"
  [ "$status" -eq 0 ]
  [ -f "$dest/NEXT_STEPS.md" ]
  grep -q "## Installed plugins\|## Plugins instalados" "$dest/NEXT_STEPS.md"
  grep -q "telegram@claude-plugins-official" "$dest/NEXT_STEPS.md"
  grep -q "claude-mem@thedotmack" "$dest/NEXT_STEPS.md"
  grep -q "security-guidance@claude-plugins-official" "$dest/NEXT_STEPS.md"
  # Description text from a default descriptor must surface in the block.
  grep -q "Persistent memory across sessions" "$dest/NEXT_STEPS.md"
}

@test "wizard with vault disabled writes vault.enabled=false and omits vault MCP" {
  local dest="$TMP_TEST_DIR/scaffold-no-vault"
  run run_wizard_with_dest "$dest"
  [ "$status" -eq 0 ]
  [ "$(yq -r '.vault.enabled' "$dest/agent.yml")" = "false" ]
  [ "$(yq -r '.vault.mcp.enabled' "$dest/agent.yml")" = "false" ]
  [ "$(jq -r '.mcpServers.vault // "absent"' "$dest/.mcp.json")" = "absent" ]
}

@test "wizard with vault enabled writes vault block + emits vault MCP + memory section" {
  local dest="$TMP_TEST_DIR/scaffold-vault-on"
  cd "$TMP_TEST_DIR/installer"
  ./setup.sh --destination "$dest" <<EOF
vault-bot
VaultBot
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
y
y
y
n
n
n
n
n
n
proceed
EOF
  [ -f "$dest/agent.yml" ]
  [ "$(yq -r '.vault.enabled' "$dest/agent.yml")" = "true" ]
  [ "$(yq -r '.vault.seed_skeleton' "$dest/agent.yml")" = "true" ]
  [ "$(yq -r '.vault.mcp.enabled' "$dest/agent.yml")" = "true" ]
  [ "$(yq -r '.vault.mcp.server' "$dest/agent.yml")" = "vault" ]
  [ "$(yq -r '.vault.qmd.enabled' "$dest/agent.yml")" = "false" ]
  [ "$(yq -r '.vault.path' "$dest/agent.yml")" = ".state/.vault" ]
  [ "$(jq -r '.mcpServers.vault.command' "$dest/.mcp.json")" = "npx" ]
  [ "$(jq -r '.mcpServers.vault.args[1]' "$dest/.mcp.json")" = "@bitbonsai/mcpvault@latest" ]
  [ "$(jq -r '.mcpServers.vault.args[2]' "$dest/.mcp.json")" = "/home/agent/.vault" ]
  [ "$(jq -r '.mcpServers.qmd // "absent"' "$dest/.mcp.json")" = "absent" ]
  grep -q "Vault" "$dest/CLAUDE.md"
  grep -q "~/.vault/" "$dest/CLAUDE.md"
}

@test "wizard with vault + QMD enabled writes vault.qmd.enabled=true and emits qmd MCP" {
  local dest="$TMP_TEST_DIR/scaffold-vault-qmd-on"
  cd "$TMP_TEST_DIR/installer"
  ./setup.sh --destination "$dest" <<EOF
qmd-bot
QmdBot
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
y
y
y
y
n
n
n
n
n
proceed
EOF
  [ -f "$dest/agent.yml" ]
  [ "$(yq -r '.vault.enabled' "$dest/agent.yml")" = "true" ]
  [ "$(yq -r '.vault.qmd.enabled' "$dest/agent.yml")" = "true" ]
  [ "$(jq -r '.mcpServers.qmd.command' "$dest/.mcp.json")" = "bunx" ]
  [ "$(jq -r '.mcpServers.qmd.args[0]' "$dest/.mcp.json")" = "@tobilu/qmd@latest" ]
  [ "$(jq -r '.mcpServers.qmd.args[1]' "$dest/.mcp.json")" = "mcp" ]
}

@test "scaffold mirrors vault.sh + modules/vault-skeleton/ into docker/ build context" {
  local dest="$TMP_TEST_DIR/scaffold-vault-mirror"
  run run_wizard_with_dest "$dest"
  [ "$status" -eq 0 ]
  [ -f "$dest/docker/scripts/lib/vault.sh" ]
  [ -d "$dest/docker/modules/vault-skeleton" ]
  [ -f "$dest/docker/modules/vault-skeleton/CLAUDE.md" ]
  [ -d "$dest/docker/modules/vault-skeleton/raw_sources" ]
  [ -d "$dest/docker/modules/vault-skeleton/wiki/concepts" ]
  [ -f "$dest/docker/modules/vault-skeleton/_templates/summary.md" ]
}
