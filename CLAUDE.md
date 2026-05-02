# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

This is **the launcher**, not an agent. `./setup.sh` is a bash wizard that scaffolds a *separate*, self-contained agent workspace elsewhere on disk. The launcher is disposable after scaffolding — every subsequent operation (`--regenerate`, `--uninstall`, `heartbeatctl`) runs from inside the scaffolded workspace.

Three distinct code paths live in this repo, and confusing them is the most common mistake:

1. **Host-side launcher** — `setup.sh`, `scripts/lib/{yaml,render,wizard,wizard-gum}.sh`, `modules/*.tpl`. Runs on the user's Mac/Linux during scaffolding. Depends on host tools: `bash 4+`, `yq v4+`, `jq`, `git`, BSD/GNU `sed`, optional `gum` (auto-downloaded to `scripts/vendor/bin/`).
2. **Image-baked code** — `docker/` (Dockerfile, `entrypoint.sh`, `crontab.tpl`, `scripts/start_services.sh`, `scripts/wizard-container.sh`, `scripts/heartbeatctl`, `scripts/lib/{interval,state}.sh`, `scripts/apply_telegram_typing_patch.py`). Copied into the Alpine 3.20 image at build time, lives at `/opt/agent-admin/` inside containers. Read-only at runtime — changes require an image rebuild.
3. **Workspace-templated code** — `scripts/heartbeat/{heartbeat.sh,notifiers/}`. Copied verbatim into each scaffolded workspace by `setup.sh`. Runs as `agent` inside the container via the bind-mount.

`modules/claude-md.tpl` is the CLAUDE.md template *for scaffolded agents*, not for this repo. Don't edit it expecting changes here; edit this file instead.

## Commands

```bash
# Tests (bats-core required on host)
bats tests/                              # full suite (~195 tests, no Docker)
bats tests/heartbeatctl.bats             # single file
bats tests/render.bats -f "substitutes"  # single test by name fragment
DOCKER_E2E=1 bats tests/docker-e2e-heartbeat.bats   # opt-in: builds image + boots a container

# Launcher (run from a fresh clone of this repo)
./setup.sh                               # interactive wizard
./setup.sh --destination ~/my-agent      # skip the destination prompt
./setup.sh --help                        # all flags

# Inside a scaffolded workspace (NOT this repo)
docker compose build && ./scripts/agentctl up   # agentctl up == docker compose up -d
./scripts/agentctl attach                # tmux attach with retry-loop
./scripts/agentctl status                # heartbeatctl status (proxy through agentctl)
./scripts/agentctl heartbeat <sub>       # any heartbeatctl subcommand
./scripts/agentctl logs -f               # tail /workspace/claude.log
./scripts/agentctl logs --stderr         # forensic tail of telegram-mcp-stderr.log
./scripts/agentctl --help                # full subcommand list
./setup.sh --regenerate                  # re-render derived files from agent.yml
./setup.sh --uninstall --yes             # remove generated files (keeps agent.yml/.env/.state)
./setup.sh --uninstall --purge --yes     # also removes agent.yml/.env/.state/
./setup.sh --uninstall --nuke --yes      # delete the workspace entirely
```

Test deps on the host: `bats-core`, `yq` v4+, `jq`, `git`, `tmux`. Tests source `scripts/lib/*.sh` directly via `tests/helper.bash::load_lib`; `heartbeatctl.bats` overrides `HEARTBEATCTL_WORKSPACE` / `HEARTBEATCTL_CRONTAB_FILE` / `HEARTBEATCTL_LIB_DIR` to run the image-baked CLI against a tmpdir without Docker.

## Architecture worth knowing before editing

Deeper docs: [`docs/architecture.md`](docs/architecture.md) (render engine, lifecycle, data contracts, privilege model) and [`docs/heartbeatctl.md`](docs/heartbeatctl.md) (full subcommand reference).

### `agent.yml` is the single source of truth

The wizard collects answers into `agent.yml`. Every derived file (`docker-compose.yml`, `.mcp.json`, `CLAUDE.md`, `scripts/heartbeat/heartbeat.conf`, `.env` skeleton, `NEXT_STEPS.md`) is rendered from it via `scripts/lib/render.sh`. Mutations made by `heartbeatctl set-*` write back to `agent.yml` first (with atomic `agent.yml.prev` rollback), then regenerate derived files. **Never edit a derived file by hand if you want the change to survive a regenerate** — change the template + `agent.yml`, or change `heartbeatctl` if it's a runtime mutation.

### Render engine (`scripts/lib/render.sh`)

`render_load_context FILE` flattens YAML into env vars: `agent.name` → `$AGENT_NAME`, `features.heartbeat.enabled` → `$FEATURES_HEARTBEAT_ENABLED`, etc. Array items are skipped at flattening time and handled by `{{#each VAR}}…{{/each}}` blocks, which derive a yq path from `VAR` (`MCPS_ATLASSIAN` → `.mcps.atlassian`) and substitute `{{field}}` per row. Templates also support `{{#if VAR}}` / `{{#unless VAR}}`. Look at `tests/fixtures/{simple,conditional,loop}.tpl` for canonical examples and `tests/render.bats` for the contract.

### Container privilege model (read this before changing `docker/`)

`docker-compose.yml.tpl` ships `cap_drop: ALL` + `cap_add: [CHOWN, SETUID, SETGID]` + `no-new-privileges`. Three load-bearing consequences:

- **Every `docker exec` must pass `-u agent`.** `root` inside the container can't write agent-owned files (no `CAP_FOWNER`).
- **busybox `crond` silently rejects crontabs not owned by root.** `entrypoint.sh` runs as root, renders the safe-default crontab to `/etc/crontabs/agent`, then `exec su-exec agent /opt/agent-admin/scripts/start_services.sh` — but a backgrounded sync loop *stays* running as root and copies `<workspace>/scripts/heartbeat/.crontab.staging` (written by `heartbeatctl reload` as agent) into `/etc/crontabs/`. Comparison uses `cmp -s`, not mtime — busybox `sh -nt` rounds to whole seconds and missed sub-second writes during boot.
- **`crond` itself runs as root** so it can `setgid(agent)` when dispatching jobs. `start_services.sh` only *monitors* it — if `crond` dies the watchdog exits the container, and Docker's `unless-stopped` policy revives it.

### Watchdog state machine (`docker/scripts/start_services.sh`)

Polls every 2s. Three failure modes it handles:

- **tmux session gone** → respawn via `next_tmux_cmd` (which re-decides between bare `claude` for `/login`, in-container Telegram-token wizard, or `claude --channels --dangerously-skip-permissions --continue`).
- **`bun server.ts` (channel plugin) gone but tmux alive** → kill tmux, respawn (forces a fresh plugin attachment).
- **`crond` gone** → exit the container.

Crash budget: 5 crashes per 300s window → exit. Docker restarts the container, restarting the budget. There used to be a "bridge watchdog" that detected the silent-stuck case (bun alive but MCP notifications dropped); it was reverted in commit `ebfe35f` because tmux pane scraping produced too many false positives. Manual recovery for that case is `heartbeatctl kick-channel`. **Don't re-add automated detection for this without solving the false-positive problem first** — it killed sessions every ~2 minutes during normal operation.

### Heartbeat data contract

`scripts/heartbeat/heartbeat.sh` (workspace-templated, runs as agent under crond) emits per-tick:

- One JSON line appended to `logs/runs.jsonl` (rotated at 10MB → `.1`, `.2.gz`, `.3.gz`, max 3 generations).
- Atomic rewrite of `state.json` (schema 1) with last-run summary + counters.
- One notifier invocation (`notifiers/{none,log,telegram}.sh`). Notifiers must always exit 0 and emit a JSON envelope `{channel, ok, latency_ms, error}` on stdout — they are not allowed to crash the heartbeat.

Heartbeat sessions use an isolated `CLAUDE_CONFIG_DIR=/home/agent/.claude-heartbeat` with selective symlinks to auth + plugins so cron ticks don't step on the interactive session's channels/state. The prompt is shell-escaped via `sh_sq` before embedding in the tmux command — preserve that pattern when touching the runner.

### Workspace-is-the-agent

After PR #3 (2026-04-22) all agent state (OAuth login, Telegram pairing, sessions, plugin cache) lives in `<workspace>/.state/` as a bind-mount to `/home/agent`, not a Docker named volume. Implications for any change touching state lifecycle:

- `docker compose down -v` no longer wipes login.
- `setup.sh --uninstall` no longer removes state — `--purge` removes `agent.yml`/`.env`/`.state`, `--nuke` deletes the whole workspace.
- `.state/` is gitignored at the template level and contains OAuth tokens — never commit it, never log its contents.
- Migration is `rsync` / `cp -a` of the workspace directory.

### Backup model: three orphan branches in the agent's fork

The non-regenerable subset of the workspace is replicated to the agent's own fork in three independent orphan branches:

- `backup/identity` — `.claude.json` + `.claude/settings.json` + `.claude/channels/telegram/access.json` + `.claude/plugins/config/` + `.env.age`. Encryption uses an SSH key recipient fetched from `github.com/<owner>.keys` at scaffold time; absent a recipient, the primitive falls back to **partial mode** (plaintext, `.env.age` omitted). Triggered by `heartbeatctl backup-identity`, the watchdog (60s hash check), post-plugin-install hooks, and a daily 03:30 cron.
- `backup/vault` — markdown subset of the configured vault (`vault.path` in `agent.yml`, default `.state/.vault`). Excludes `.obsidian/workspace*.json`, `cache/`, `.trash/`, and `*.sync-conflict-*` files. Cron `0 * * * *` by default; override via `vault.backup_schedule`. Helpers in `docker/scripts/lib/backup_vault.sh`.
- `backup/config` — `agent.yml` (plaintext, no secrets — those live in `.env`, which is in identity). Cron `30 3 * * *` by default; toggle via `features.config_backup.enabled`. Helpers in `docker/scripts/lib/backup_config.sh`.

All three primitives share the same shape: hash-based idempotency (sha256 over content + filenames), worktree-staged commit + push, atomic state file in `<workspace>/scripts/heartbeat/<X>-backup.json`. Each branch can be missing without breaking the others — restore via `setup.sh --restore-from-fork <url>` pulls all three in order (`config` first so `vault.path` is known, then `identity`, then `vault`) and skips any that are absent.

Three things to remember when touching the backup code:
1. **Don't merge primitives across branches.** Each `backup_X.sh` library mirrors the others' shape but stays independent — different filesystem inputs, different schedules, different threat models. Splitting was an explicit design goal so a noisy vault doesn't churn the identity branch's hash, and so sharing the config-only branch with another agent doesn't expose `.env.age`.
2. **Trees are wiped before each commit.** `vault_commit_and_push` and `config_commit_and_push` blow away the existing stage tree before copying the current snapshot in. This is what makes deletes propagate. Don't add merge logic — the branch is append-only commits, but the tree per commit is a complete replacement.
3. **Per-branch clone caches.** `~/.cache/agent-backup/{identity,vault,config}-clone/` are independent worktrees against the same fork. Don't try to share them — `git worktree add` on the same path would conflict, and the orphan-branch `init` flow in each lib expects a private clone dir.

### Telegram plugin patch

`docker/scripts/apply_telegram_typing_patch.py` is re-applied on every boot by `start_services.sh::apply_plugin_patches` against the plugin copy in `~/.claude/plugins/cache/claude-plugins-official/telegram/*/server.ts`. Idempotent via marker comments (one per patch group: typing, offset, stderr, primary), fail-silent if any of the anchor regexes drift. Don't move the patch invocation out of the boot path — the plugin cache lives under `.state/` which means a workspace clone receives an unpatched plugin until the next boot.

The typing patch is currently at **v3** — same runtime contract as v2 (no time cap; the indicator persists until `case 'reply'` fires or the bun process exits) plus observability:

- The setInterval logs `telegram channel: typing tick N for chat <id>` to stderr every 5 invocations (~20s). The stderr-capture patch tees this to `/workspace/scripts/heartbeat/logs/telegram-mcp-stderr.log`, so a quiet log during a long Claude turn is direct evidence of a runtime issue.
- `bot.api.sendChatAction(...).catch(() => {})` was the v1/v2 anti-pattern that silently swallowed every Telegram error (rate limit, network, expired token). v3 routes the error through `process.stderr.write(...)` so it's visible in the same log.

The patcher runs an upgrade cascade on every boot: `v1 → v2 → v3`. Already-patched agents at any version ratchet up transparently — `upgrade_typing_v1_to_v2` strips the cap and bumps the marker; `upgrade_typing_v2_to_v3` rewrites the helper block with instrumentation. Both upgraders are fail-silent if helpers were edited out-of-band (logs WARN; leaves the file at the highest matching version).

## Common gotchas

- **This file is gitignored.** `.gitignore`'s `/CLAUDE.md` rule is meant for *scaffolded workspaces* (where it's a derived file from `modules/claude-md.tpl`), but the same rule catches the launcher's own root-level `CLAUDE.md`. `git status` won't show edits — use `git add -f CLAUDE.md` to commit changes here.
- **`Agentic Pod Lanuncher/` (sic) is not part of this repo.** It's the user's personal Obsidian vault that happens to live in this directory; it's untracked. Don't touch it, don't include it in greps, and don't "fix" the typo.
- The wizard normalizes `agent_name` to lowercase + no spaces silently because it's used for filenames, branches, container names, and systemd units. If you add a new field that participates in any of those, normalize it the same way.
- `setup.sh` detects host UID/GID and bakes them into `docker-compose.yml` build args. macOS hosts often have GID `20` (`staff`), which collides with Alpine's `dialout` group — the Dockerfile deletes the colliding user/group before `addgroup agent`. Don't remove that block.
- `permissions.defaultMode=auto` and `skipDangerousModePermissionPrompt=true` are written into `~/.claude/settings.json` on every boot by `pre_accept_bypass_permissions`. The chat-driven workflow requires `auto` (plan mode blocks the Telegram `reply` MCP call → looks like the agent ghosts every message).
- `gum` is optional — the wizard falls back to `scripts/lib/wizard.sh` (plain `read`) when stdin is not a TTY (CI, piped tests). Don't add gum-only behavior without a non-gum fallback in `wizard.sh`.
- Library files sourced by both `heartbeatctl` and bats tests guard their initialization with `BASH_SOURCE`-style checks so `source` doesn't run side-effecting code at load time. Preserve that pattern when adding new shared libs.
