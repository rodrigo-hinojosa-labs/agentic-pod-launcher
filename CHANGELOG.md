# Changelog

## [Unreleased]

### Added
- telegram: persist Telegram `update_id` offset to disk on each successful
  reply (`/home/agent/.claude/channels/telegram/last-offset.json`) and
  replay from disk on plugin startup via a synchronous
  `bot.api.getUpdates({ offset })` call before `bot.start()`. Ack-on-reply
  semantics: a `_pendingUpdates` Map is populated in `handleInbound`
  (right after `chat_id` is bound) and drained in the `case 'reply'` MCP
  tool dispatcher only after `bot.api.sendMessage` returns successfully.
  Net effect: if bun dies between an inbound being forwarded to claude
  via MCP and claude calling the `reply` tool back, the offset stays
  put — Telegram re-delivers the update on the next `bot.start()`. This
  fixes the silent "message acknowledged but never replied" failure
  mode that the prior pre-handler middleware shipped on the abandoned
  `feat/telegram-reliability` branch had. Four hunks: helpers (B1),
  replay-before-bot.start (B2), mark-pending in handleInbound (B3),
  ack-pending in case 'reply' (B4). Marker:
  `agentic-pod-launcher: offset persistence patch v1`.
- telegram: primary-secondary lock to prevent sub-claude bun spawns from
  killing the live primary. Upstream's stale-poller block sends `SIGTERM`
  to whatever PID is in `bot.pid` whenever a new bun starts — designed
  to clean up a crashed predecessor. But every claude session that loads
  the telegram plugin (heartbeat-driven `claude --print`, claude-mem's
  observer worker, Task subagents...) spawns its own `bun server.ts` that
  hits the same code path and SIGTERMs the interactive session's bun
  mid-turn. The primary-lock patch (a) refreshes `bot.pid`'s mtime every
  5s via `setInterval`, and (b) makes the stale-poller exit cleanly
  (`process.exit(0)`) when it sees a recent (`< 30s`) mtime — any new
  instance that finds a fresh primary gives up instead of taking over.
  Marker: `agentic-pod-launcher: primary lock patch v1`.
- heartbeat: `ensure_heartbeat_config_dir` no longer symlinks
  `settings.json` or `plugins/` into `~/.claude-heartbeat`. Instead it
  writes a real `settings.json` with `enabledPlugins: {}` and
  `extraKnownMarketplaces: {}` (preserving auth-mode + skip-perms-prompt
  from the source) and creates an empty `plugins/` directory. Without
  this, the heartbeat's `claude --print` inherited the agent's
  `enabledPlugins.telegram@... = true` and spawned a sub-bun on every
  cron tick (i.e. every 30 minutes) that took over the bot poller and
  killed the interactive session's bun. With the primary-lock patch
  above as belt-and-suspenders, but this one prevents the spawn at all.
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
- backup: identity backup via git orphan branch. `heartbeatctl
  backup-identity` snapshots login / pairing / plugin list / settings
  / age-encrypted .env to `backup/identity` on the agent's fork.
  Three triggers (manual, post-plugin-install + 60s watchdog hash
  check, daily cron at 03:30). Restore via
  `setup.sh --destination <path> --restore-from-fork <fork-url>`.
  age encryption uses the fork owner's SSH key from
  `github.com/<owner>.keys` — no extra secrets. A4 fallback (partial
  mode, plaintext-only) kicks in when no key is available; user can
  upgrade via `heartbeatctl backup-identity --configure-key <key>`.
  Design: `docs/superpowers/specs/2026-04-22-identity-backup-design.md`.
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
