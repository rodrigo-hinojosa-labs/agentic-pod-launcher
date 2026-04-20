# Changelog

## [Unreleased]

### Fixed
- heartbeat: `HEARTBEAT_INTERVAL` now propagates into the cron schedule
  via `heartbeatctl reload` (derives `*/N * * * *` from `agent.yml`).
- heartbeat: dropped the user field from `/etc/crontabs/agent` — busybox
  user-crontabs have the user implicit in the filename.
- heartbeat: `crond` is launched as root from `entrypoint.sh` so job
  dispatch can `setgid(agent)` cleanly. `start_services.sh` monitors
  rather than launches.
- heartbeat: `entrypoint.sh` chowns `/workspace/scripts/heartbeat` on
  boot so the agent uid matches the bind-mount.
- heartbeat: crontab write order adjusted for `cap_drop: ALL` — chmod
  while root-owned, then chown to agent (CAP_FOWNER not available).
- heartbeatctl: crontab is written directly (not via mv) because agent
  can overwrite the file but not rename into `/etc/crontabs/`.

### Added
- heartbeat: structured `runs.jsonl` trace, one JSON object per run with
  `run_id` correlation, embedded notifier envelope, size-based gz
  rotation at 10MB keeping 3 generations.
- heartbeat: atomic `state.json` snapshot (schema 1) of last run +
  counters (`total_runs`, `ok`, `timeout`, `error`,
  `consecutive_failures`, `success_rate_24h`), enriched with live
  `crond.alive` / `pid` at read time.
- heartbeat: ephemeral runner uses an isolated `CLAUDE_CONFIG_DIR`
  (`/home/agent/.claude-heartbeat`) with selective symlinks to auth +
  plugins so cron ticks don't step on the interactive session's
  channels/state.
- heartbeat: notifier message is now Claude's actual output (session
  log captured + ANSI stripped + capped at 3500 chars), not the canned
  "Heartbeat OK Nms" string. Empty/missing log falls back to the
  canned line.
- heartbeat: ephemeral runner adds `--dangerously-skip-permissions
  --permission-mode auto` so the cron-driven session can call tools
  without a human to approve them.
- heartbeatctl: single CLI with `status` (pretty + `--json`), `logs`,
  `show`, `test`, `pause`, `resume`, `reload`, `kick-channel`, and
  mutable `set-interval`, `set-prompt`, `set-notifier`, `set-timeout`,
  `set-retries`. All mutations are atomic against `agent.yml` with
  rollback on failure.
- heartbeatctl `kick-channel`: one-command recovery for the upstream
  `claude-plugins-official/telegram` MCP-bridge stall (bun stays alive
  and polls Telegram, but its `notifications/claude/channel` messages
  stop reaching Claude). Kills the tmux session; the supervisor
  watchdog respawns it in ~2s with a fresh plugin attachment.
- start_services.sh: `pre_accept_bypass_permissions` writes
  `skipDangerousModePermissionPrompt: true` and
  `permissions.defaultMode: "auto"` to `~/.claude/settings.json` on
  every boot, so the first-launch warning dialog never blocks and
  every session starts in auto mode without `/auto`.
- start_services.sh: clears stale `pending` entries in the telegram
  plugin's `access.json` on every boot (mitigates the upstream
  re-prompt-after-restart bug).
- start_services.sh: watchdog now also exits the container if `crond`
  dies, and respawns the tmux session if `bun server.ts` (the
  channel plugin) is missing.
- entrypoint.sh: root-privileged sync loop copies the
  heartbeatctl-managed staging crontab into `/etc/crontabs/` because
  busybox crond silently rejects non-root-owned crontabs. Uses
  `cmp -s` instead of `-nt` (busybox sh's mtime comparison rounds
  to whole seconds and missed sub-second writes).
- wizard: defaults are pre-filled for one-Enter accept, with `Ctrl+U`
  to clear and `Ctrl+C` to abort the whole wizard cleanly. Tips
  printed once at the top of the banner.
- wizard: at the Telegram-token step, the in-container wizard runs
  `claude --print` once with a targeted prompt to enrich the
  template-rendered `CLAUDE.md` with workspace-specific commands /
  architecture / test conventions. Bounded by `timeout 90`; falls
  back to template-only on failure.
- notifiers: standardized JSON-envelope contract on stdout
  (`{channel, ok, latency_ms, error}`); always exit 0. Race-free
  per-invocation tempfiles.
- docs: `docs/heartbeatctl.md` (full CLI reference), updated
  `docs/architecture.md` (heartbeat pipeline + privilege model),
  `NEXT_STEPS.md` template includes inline troubleshooting (no
  more dead links to `docs/`), `CLAUDE.md` template documents
  self-service permission-mode switching for the agent.
- tests: `interval-to-cron.bats`, `state-lib.bats`,
  `heartbeat-runs-jsonl.bats`, `heartbeatctl.bats`, opt-in
  `docker-e2e-heartbeat.bats` (set `DOCKER_E2E=1`). Suite is at
  ~160 tests.

### Security
- heartbeat.sh: prompt is shell-escaped (`sh_sq` helper) before
  embedding into the tmux command, preventing injection via a
  mutated prompt.
- telegram notifier: HTTP error bodies are JSON-escaped with `jq -n`
  instead of manual `sed`, preventing malformed JSON output on
  upstream errors.

### Known limitations
- Telegram chat may go silent: the upstream
  `claude-plugins-official/telegram` plugin's MCP bridge can wedge
  while bun is still alive and polling. Recovery: `docker exec
  -u agent <agent> heartbeatctl kick-channel`. An auto-detection
  watchdog was attempted (commits 3c5465f / fcb6744) and reverted
  in `ebfe35f` because tmux pane scraping produces too many false
  positives. Tracked for upstream report.

See `docs/superpowers/specs/2026-04-19-heartbeat-observability-cli-design.md`
for the original design spec.

## [0.1.0] — 2026-04-19

Initial import from `agent-admin-template@feature/docker-mode`
(927fffca700b111b84ae32f70b49b230c781aaf1). Docker-only template: no `--docker` flag, no host-mode
paths, single-user-per-container model.

See `docs/architecture.md` for the design.
