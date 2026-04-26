#!/usr/bin/env bats

load helper

setup() {
  setup_tmp_dir
  load_lib yaml
  load_lib render
  FIXTURE="$REPO_ROOT/tests/fixtures/sample-agent.yml"
  render_load_context "$FIXTURE"
  export HOME_DIR="/home/test"
}

teardown() { teardown_tmp_dir; }

@test "docker-compose.yml.tpl renders with agent name as service" {
  result=$(render_template "$REPO_ROOT/modules/docker-compose.yml.tpl")
  [[ "$result" == *"  dockbot:"* ]]
}

@test "docker-compose.yml.tpl sets build args from docker.uid/gid" {
  result=$(render_template "$REPO_ROOT/modules/docker-compose.yml.tpl")
  [[ "$result" == *'UID: "1000"'* ]]
  [[ "$result" == *'GID: "1000"'* ]]
}

@test "docker-compose.yml.tpl mounts workspace and bind-mount state directory" {
  result=$(render_template "$REPO_ROOT/modules/docker-compose.yml.tpl")
  [[ "$result" == *"./:/workspace"* ]]
  [[ "$result" == *"./.state:/home/agent"* ]]
}

@test "docker-compose.yml.tpl drops all caps and re-adds only the three" {
  result=$(render_template "$REPO_ROOT/modules/docker-compose.yml.tpl")
  [[ "$result" == *"cap_drop:"* ]]
  [[ "$result" == *"cap_add:"* ]]
  [[ "$result" == *"CHOWN"* ]]
  [[ "$result" == *"SETUID"* ]]
  [[ "$result" == *"SETGID"* ]]
}

@test "docker-compose.yml.tpl uses unless-stopped and no published ports" {
  result=$(render_template "$REPO_ROOT/modules/docker-compose.yml.tpl")
  [[ "$result" == *"restart: unless-stopped"* ]]
  [[ "$result" != *"ports:"* ]]
}

@test "systemd unit has Type=oneshot RemainAfterExit=yes" {
  result=$(render_template "$REPO_ROOT/modules/systemd.service.tpl")
  [[ "$result" == *"Type=oneshot"* ]]
  [[ "$result" == *"RemainAfterExit=yes"* ]]
}

@test "systemd unit ExecStart runs docker compose up -d in workspace" {
  result=$(render_template "$REPO_ROOT/modules/systemd.service.tpl")
  [[ "$result" == *"WorkingDirectory=/home/test/agents/dockbot"* ]]
  [[ "$result" == *"ExecStart=/usr/bin/docker compose up -d"* ]]
  [[ "$result" == *"ExecStop=/usr/bin/docker compose down"* ]]
}

@test "systemd unit description includes agent display name" {
  result=$(render_template "$REPO_ROOT/modules/systemd.service.tpl")
  [[ "$result" == *"Description=DockBot 🐳 (Docker)"* ]]
}

@test "crontab.tpl contains heartbeat invocation against workspace" {
  # The runtime uses envsubst, but shape is the same: $AGENT_NAME + cron schedule.
  content=$(< "$REPO_ROOT/docker/crontab.tpl")
  [[ "$content" == *"/workspace/scripts/heartbeat/heartbeat.sh"* ]]
  [[ "$content" == *'${HEARTBEAT_CRON}'* ]]
}

@test "Dockerfile builds from alpine:3.20 base" {
  content=$(< "$REPO_ROOT/docker/Dockerfile")
  [[ "$content" == *"FROM alpine:3.20"* ]]
}

@test "Dockerfile accepts UID/GID build args and creates agent user" {
  content=$(< "$REPO_ROOT/docker/Dockerfile")
  [[ "$content" == *"ARG UID=1000"* ]]
  [[ "$content" == *"ARG GID=1000"* ]]
  [[ "$content" == *"addgroup -g"* ]]
  [[ "$content" == *"adduser -D -u"* ]]
}

@test "Dockerfile installs required runtime packages" {
  content=$(< "$REPO_ROOT/docker/Dockerfile")
  for pkg in bash tmux tini nodejs npm git curl; do
    [[ "$content" == *"$pkg"* ]]
  done
}

@test "Dockerfile ENTRYPOINT uses tini then entrypoint.sh" {
  content=$(< "$REPO_ROOT/docker/Dockerfile")
  [[ "$content" == *"ENTRYPOINT"* ]]
  [[ "$content" == *"/sbin/tini"* ]]
  [[ "$content" == *"/opt/agent-admin/entrypoint.sh"* ]]
}

@test "entrypoint.sh chowns /home/agent when owned by root" {
  content=$(< "$REPO_ROOT/docker/entrypoint.sh")
  [[ "$content" == *"chown -R agent:agent /home/agent"* ]]
}

@test "entrypoint.sh renders crontab from envsubst template" {
  content=$(< "$REPO_ROOT/docker/entrypoint.sh")
  [[ "$content" == *"envsubst"* ]]
  [[ "$content" == *"/opt/agent-admin/crontab.tpl"* ]]
  [[ "$content" == *"/etc/crontabs/agent"* ]]
}

@test "entrypoint.sh hands off unconditionally to start_services.sh" {
  # Launch decisions (bare claude / wizard / claude --channels) live in the
  # supervisor, not the entrypoint — so the entrypoint never routes to the
  # wizard directly and never gates on TELEGRAM_BOT_TOKEN.
  content=$(< "$REPO_ROOT/docker/entrypoint.sh")
  [[ "$content" == *"su-exec agent"* || "$content" == *"exec su agent"* ]]
  [[ "$content" == *"start_services.sh"* ]]
  [[ "$content" != *"wizard-container.sh"* ]]
}

@test "start_services.sh decides launch based on auth + token presence" {
  content=$(< "$REPO_ROOT/docker/scripts/start_services.sh")
  [[ "$content" == *"has_telegram_token"* ]]
  [[ "$content" == *"next_tmux_cmd"* ]]
  [[ "$content" == *"wizard-container.sh"* ]]
}

@test "start_services.sh attaches --dangerously-skip-permissions in steady state" {
  content=$(< "$REPO_ROOT/docker/scripts/start_services.sh")
  # Only the --channels branch opts into skip-permissions; the bare pre-login
  # launch should NOT carry it (so /login stays interactive).
  [[ "$content" == *"--channels plugin:\$REQUIRED_CHANNEL_PLUGIN --dangerously-skip-permissions"* ]]
}

@test "start_services.sh verifies channel health after --channels launch" {
  content=$(< "$REPO_ROOT/docker/scripts/start_services.sh")
  [[ "$content" == *"verify_channel_healthy"* ]]
  [[ "$content" == *"bun server.ts"* ]]
  # start_session must kill the tmux session when verify fails so the
  # watchdog picks it up as a crash and respawns with fresh state.
  [[ "$content" == *"never appeared within 20s"* ]]
}

@test "start_services.sh pre-accepts bypass dialog before every session launch" {
  content=$(< "$REPO_ROOT/docker/scripts/start_services.sh")
  # Call site lives in start_session so it runs before tmux gets the
  # command, not inside next_tmux_cmd where only case C would trigger it.
  [[ "$content" == *"pre_accept_bypass_permissions"$'\n'*"cmd=\$(next_tmux_cmd)"* ]]
}

@test "start_services.sh monitors crond liveness and calls heartbeatctl reload" {
  content=$(< "$REPO_ROOT/docker/scripts/start_services.sh")
  # crond is now started by entrypoint.sh (root); start_services.sh must NOT
  # launch it itself but MUST check its liveness in the watchdog loop and
  # call heartbeatctl reload before the main loop.
  [[ "$content" != *"crond -b"* ]]
  [[ "$content" == *"pgrep -x crond"* ]]
  [[ "$content" == *"heartbeatctl reload"* ]]
}

@test "start_services.sh starts tmux session named 'agent'" {
  content=$(< "$REPO_ROOT/docker/scripts/start_services.sh")
  [[ "$content" == *'SESSION="agent"'* ]]
  [[ "$content" == *'tmux new-session -d -s "$SESSION"'* ]]
  [[ "$content" == *'CLAUDE_CONFIG_DIR_VAL="/home/agent/.claude"'* ]]
}

@test "start_services.sh auto-installs the channel plugin on launch" {
  content=$(< "$REPO_ROOT/docker/scripts/start_services.sh")
  [[ "$content" == *'ensure_plugin_installed'* ]]
  [[ "$content" == *'telegram@claude-plugins-official'* ]]
  [[ "$content" == *'claude plugin install'* ]]
}

@test "start_services.sh has 5-crashes-in-5-minutes backoff" {
  content=$(< "$REPO_ROOT/docker/scripts/start_services.sh")
  [[ "$content" == *"MAX_CRASHES=5"* ]]
  [[ "$content" == *"WINDOW=300"* ]]
  [[ "$content" == *"exit 1"* ]]
}

@test "wizard-container.sh uses gum for prompts" {
  content=$(< "$REPO_ROOT/docker/scripts/wizard-container.sh")
  [[ "$content" == *"gum input"* ]]
  [[ "$content" == *"--password"* ]]
}

@test "wizard-container.sh writes .env with 0600 permissions" {
  content=$(< "$REPO_ROOT/docker/scripts/wizard-container.sh")
  [[ "$content" == *"chmod 0600"* ]]
  [[ "$content" == *"/workspace/.env"* ]]
}

@test "wizard-container.sh exits 0 after writing so Docker restarts the container" {
  content=$(< "$REPO_ROOT/docker/scripts/wizard-container.sh")
  [[ "$content" == *"exit 0"* ]]
}

@test "wizard-container.sh upserts into existing .env without clobbering other keys" {
  content=$(< "$REPO_ROOT/docker/scripts/wizard-container.sh")
  # Has the upsert helper and uses sed -i for in-place replace.
  [[ "$content" == *"update_env_var"* ]]
  [[ "$content" == *"sed -i"* ]]
  # Only opens the file for `>` inside a "file doesn't exist yet" guard;
  # every other write goes via >> (append) in update_env_var.
  [[ "$content" == *'if [ ! -f "$ENV_FILE" ]'* ]]
  [[ "$content" == *'>> "$ENV_FILE"'* ]]
}

@test "wizard-container.sh prompts for Atlassian tokens listed in agent.yml" {
  content=$(< "$REPO_ROOT/docker/scripts/wizard-container.sh")
  [[ "$content" == *"mcps.atlassian"* ]]
  [[ "$content" == *"ATLASSIAN_"* ]]
}

@test "docker-compose.yml.tpl allocates stdin/tty for interactive first-run wizard" {
  result=$(render_template "$REPO_ROOT/modules/docker-compose.yml.tpl")
  [[ "$result" == *"stdin_open: true"* ]]
  [[ "$result" == *"tty: true"* ]]
}

@test "crontab.tpl renders without a user field (busybox user-crontab format)" {
  export HEARTBEAT_CRON="*/2 * * * *"
  local rendered
  rendered=$(envsubst < "$REPO_ROOT/docker/crontab.tpl")
  # Must NOT contain the token "agent " in the executable position.
  # Valid format: "<5 time fields> /workspace/scripts/heartbeat/heartbeat.sh ..."
  [[ "$rendered" == *"*/2 * * * * /workspace/scripts/heartbeat/heartbeat.sh"* ]]
  [[ "$rendered" != *"* agent /workspace"* ]]
}
