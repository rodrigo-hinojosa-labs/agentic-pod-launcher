# Changelog

## [Unreleased]

### Added
- telegram: persist Telegram `update_id` offset to disk on every processed
  message (`/home/agent/.claude/channels/telegram/last-offset.json`) and
  replay from disk on plugin startup via a synchronous
  `bot.api.getUpdates({ offset })` call before `bot.start()`. Makes
  message loss impossible across `bun server.ts` crashes — Telegram
  re-delivers any updates with id ≥ persisted offset that are still in
  its 24h buffer. Patch is independently idempotent (own marker:
  `agentic-pod-launcher: offset persistence patch v1`) and fail-silent
  on anchor drift in upstream `server.ts`.
- telegram: tee `process.stderr` to
  `/workspace/scripts/heartbeat/logs/telegram-mcp-stderr.log` plus
  register `process.on('uncaughtException')` and
  `process.on('unhandledRejection')` handlers that append the trace
  there. Without this, bun crashes left no forensic evidence (the MCP
  transport drops the existing handlers' stderr writes). Marker:
  `agentic-pod-launcher: stderr-capture patch v1`.
- heartbeatctl: new `drop-plugin <spec>` subcommand. Atomic
  `yq -i '.plugins -= [strenv(V)]'` mutation against `agent.yml` with
  backup/restore on failure. Idempotent. Useful for evicting a
  known-broken plugin without manual `yq` invocations.

### Removed
- catalog: `caveman@JuliusBrussee` opt-in plugin removed from the
  default catalog. The repo `JuliusBrussee/caveman` ships a single
  Claude Code skill, not a plugin marketplace (no `marketplace.json`
  at root) — `claude plugin install caveman@JuliusBrussee` failed on
  every container respawn, leaving "1 MCP server failed" in the
  status panel and ~1s of churn per crash cycle. Existing agents:
  `docker exec -u agent <name> heartbeatctl drop-plugin
  caveman@JuliusBrussee` then `kick-channel` to apply.

### Changed
- docker: agent state (login, Telegram pairing, sessions, plugin cache)
  moved from a docker-managed named volume (`<agent>-state`, living in
  `/var/lib/docker/volumes/`) to a bind-mount inside the workspace at
  `<workspace>/.state/`. The workspace directory is now self-contained
  — `rsync` / `cp -r` of the workspace is a full agent migration. Side
  effects: `docker compose down -v` no longer wipes the agent's state;
  `setup.sh --uninstall` no longer removes state either (use `--purge`
  to remove `agent.yml` + `.env` + `.state/`, or `--nuke` to delete the
  whole workspace). `.state/` is gitignored at the template level. For
  existing agents, migrate with
  `docker run --rm -v <agent>-state:/src -v $(pwd)/.state:/dst alpine
  cp -a /src/. /dst/` before editing `docker-compose.yml` to reference
  `./.state:/home/agent`.

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
- telegram plugin: post-install patch
  (`docker/scripts/apply_telegram_typing_patch.py`) keeps the Telegram
  "typing…" chat action refreshed every 4s while Claude is processing a
  message. Upstream (`claude-plugins-official/telegram`) fires
  `sendChatAction` once on inbound and Telegram auto-expires the action
  at ~5s, so users saw "typing…" stop mid-processing on any reply that
  needed an MCP call or more than a few seconds of thought. Patch adds
  a refresh `setInterval` with a 120s hard cap + cleanup at the start of
  the `reply` tool handler. Idempotent via marker comment; fail-silent if
  any of the three anchor regexes miss (upstream drift) so the plugin
  keeps its default behavior. Applied by
  `start_services.sh:apply_plugin_patches` on every boot against the
  plugin copy in the state volume.
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
