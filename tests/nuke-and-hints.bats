#!/usr/bin/env bats

load helper

setup() {
  setup_tmp_dir
  cp -r "$REPO_ROOT/scripts" "$REPO_ROOT/modules" "$TMP_TEST_DIR/"
  cp "$REPO_ROOT/setup.sh" "$TMP_TEST_DIR/"
  cat > "$TMP_TEST_DIR/agent.yml" << 'EOF'
version: 1
agent:
  name: nuke-bot
  display_name: "NukeBot"
  role: "r"
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
  workspace: "/tmp/nuke-bot"
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
plugins: []
EOF
  touch "$TMP_TEST_DIR/.env"
}

teardown() { teardown_tmp_dir; }

@test "--uninstall --nuke removes the workspace directory itself" {
  cd "$TMP_TEST_DIR"
  ./setup.sh --non-interactive >/dev/null
  # Parent dir is $TMP_TEST_DIR's parent — we're in the workspace itself.
  # --nuke should remove the current dir ($TMP_TEST_DIR)
  local parent
  parent=$(dirname "$TMP_TEST_DIR")
  [ -d "$TMP_TEST_DIR" ]
  run ./setup.sh --uninstall --nuke --yes
  [ "$status" -eq 0 ]
  [ ! -d "$TMP_TEST_DIR" ]
}

@test "--nuke implies --purge (agent.yml and .env gone even if only --nuke passed)" {
  cd "$TMP_TEST_DIR"
  ./setup.sh --non-interactive >/dev/null
  run ./setup.sh --uninstall --nuke --yes
  [ "$status" -eq 0 ]
  # Directory is gone so we can't check agent.yml directly — but the summary should say it'll be purged
  [[ "$output" == *"agent.yml (source of truth)"* ]] || [[ "$output" == *"Purging source of truth"* ]]
}

@test "--uninstall from installer-like dir shows destination hint" {
  # Create a fake installer: modules + scripts/lib but no agent.yml
  local fake_installer="$TMP_TEST_DIR/fake-installer"
  mkdir -p "$fake_installer/modules" "$fake_installer/scripts/lib"
  cp "$REPO_ROOT/setup.sh" "$fake_installer/"
  cp -r "$REPO_ROOT/scripts/lib/." "$fake_installer/scripts/lib/"
  cd "$fake_installer"
  run ./setup.sh --uninstall --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"installer clone"* ]]
  [[ "$output" == *"scaffolded"* ]]
}
