# Getting Started

The launcher scaffolds agents in one of two **deployment modes**, selected by the wizard's first prompt:

- **docker mode** (recommended) — the agent runs inside its own container, with all state stored under the workspace directory (`<workspace>/.state/`, bind-mounted to `/home/agent`). Least-privilege by design.
- **local mode** — the agent runs directly on the host as a `claude remote-control` session under systemd (Linux only). No container; see [Local standalone mode](#local-standalone-mode-linuxsystemd).

In both modes teardown is clean and reversible: `./setup.sh --uninstall --nuke` removes the workspace and the agent's dotfiles/state (systemd units too, if it has passwordless sudo — see [Teardown](#teardown)). If the agent has a fork with backups, `./setup.sh --restore-from-fork <url>` brings it back.

See [Architecture](architecture.md) for the technical design of both modes.

## Prerequisites

Host tools for the wizard (both modes):

- Bash 4+, `git`, `jq` (chat-id auto-discovery and `agentctl status`/`doctor` parsing)
- `yq` v4+ — auto-vendored into `scripts/vendor/bin/` if missing or the wrong version
- Optional: `gum` (auto-downloaded; plain-`read` fallback without a TTY), `gh` (only for the GitHub-fork prompt; auto-bootstrapped when needed)

Docker mode additionally needs (as of v0.12.0):

- Docker Engine with the **Compose v2 plugin** — every script invokes `docker compose …` (never the legacy `docker-compose` binary). Bundled with Docker Desktop; a separate package on Linux. The launcher does not enforce a minimum engine version; any release shipping Compose v2 works.
- ~2GB disk for the image and the workspace combined

Local mode needs **no Docker** at all, but requires:

- Linux with systemd
- Claude Code >= 2.1.51 on the host (Remote Control gate, checked by `./setup.sh --login`)
- Node.js on the host if you keep an npx-based MCP (the bootstrap symlinks your existing `node`/`npm`/`npx`; it does not install Node), and `unzip` if you enable QMD (needed to install bun). Everything else (`uv`/`uvx`, `github-mcp-server`, `bun`) is provisioned for you — see [MCP runtime bootstrap](#mcp-runtime-bootstrap-agent-bootstrapsh).

## Scaffold

Run the installer wizard:

```bash
./setup.sh                          # interactive — prompts for destination
./setup.sh --destination ~/my-agent # skip the destination prompt
```

The wizard runs on the host. Prompt order (as of v0.12.0):

1. **Deployment mode** (`docker`/`local`) — asked first; the whole flow branches on it. Choosing `local` prints an explicit security warning.
2. Agent identity (name — normalized to a DNS label, display name, role, vibe).
3. About you (full name, nickname, timezone, email, preferred language `es`/`en`/`mixed`).
4. Destination directory + optional systemd unit (the unit prompt is Linux-only; on macOS it is skipped — Docker Desktop plus the container's `unless-stopped` policy handles restart-on-login).
5. Claude profile — informational, no prompt: it just tells you where the login will live (container `/home/agent/.claude` in docker mode, `<workspace>/.state/.claude` in local mode).
6. GitHub fork for template sync (optional; asks for a fork PAT).
7. Heartbeat notifications (optional bot token + chat-id auto-discovery).
8. MCP servers (Atlassian workspaces + API tokens, GitHub MCP + PAT, per-MCP secrets).
9. Heartbeat feature and agent principles.
10. Knowledge vault (Karpathy three-layer pattern at `.state/.vault/`, default on): seed structure, MCPVault server, and QMD hybrid search (BM25+vector+rerank; downloads a ~300MB embedding model on first use — **default off**). See [vault.md](vault.md).
11. Optional plugins (five defaults — telegram, claude-mem, context7, claude-md-management, security-guidance — are always installed and not asked about).

**Secrets:** the host wizard *optionally* captures GitHub PAT, Atlassian API tokens, the heartbeat notifier token/chat id, the fork PAT, and per-MCP secrets — press Enter to skip any of them and fill `.env` later. Only the chat-plugin **Telegram bot token** is deferred to the container's first-run wizard (docker mode); that wizard skips `GITHUB_PAT` if the host wizard already set it.

Output:

- The workspace directory — defaults to a sibling `agents/<name>/` folder next to the launcher clone (override with `--destination`). Contains `agent.yml`, `docker-compose.yml` (docker mode only), scripts, and `NEXT_STEPS.md`.
- `NEXT_STEPS.md` — the rendered per-agent instruction file (English or Spanish per `user.language`), also printed on screen. This is the primary post-scaffold guide.
- `/etc/systemd/system/agent-<name>.service` — only on Linux and only if you opted in at prompt 4.

## Local standalone mode (Linux/systemd)

`local` mode runs the agent **directly on the host** (no container) as a persistent `claude remote-control` session under systemd. It is **Linux/systemd only** and opt-in, with an explicit security warning at the prompt.

**Choose local mode when** you need a Remote Control session you drive from claude.ai/code and the mobile app, tied to a persistent host/user. **Trade-off:** it breaks the container's least-privilege model — the agent runs as your login user and inherits your privileges and secrets, and whoever controls the claude.ai account controls the host (**MFA mandatory**). Prefer `docker` unless you specifically need this.

After scaffolding in local mode, the one-time login is the only manual step:

```bash
cd <workspace>
./setup.sh --login        # verifies Claude Code >= 2.1.51, provisions MCP runtimes,
                          # launches the full-scope OAuth login, applies workspace
                          # trust, and enables the systemd session unit(s)
```

Remote Control requires a **full-scope interactive OAuth login** — the inference-only `claude setup-token` is rejected. On a headless host, tunnel the callback port over SSH (`ssh -L <port>:localhost:<port> host`) and complete the browser flow on your laptop. The login lands in `<workspace>/.state/.claude/.credentials.json` (0600, gitignored); the session unit has an `ExecCondition` on that file, so it never starts unauthenticated. (Version gate as of v0.12.0: `MIN_VERSION=2.1.51` in `modules/local-login.sh.tpl`.)

### MCP runtime bootstrap (`agent-bootstrap.sh`)

Docker mode bakes MCP runtimes into the image; local mode has to provision them, because the systemd unit runs with a minimal `PATH` and without them **every project MCP fails to connect**. `--login` runs `scripts/local/agent-bootstrap.sh` (rendered from `modules/local-bootstrap.sh.tpl`), which installs into `~/.local/bin` exactly what the rendered `.mcp.json` references:

- `uv`/`uvx` (static musl tarball) — for the `uvx`-based MCPs (fetch, git, time, atlassian).
- `node`/`npm`/`npx` **symlinks** to your existing Node install (nvm or system) — Node itself is not installed; if absent, the script warns and the npx-based MCPs won't start.
- `github-mcp-server` — checksum-verified download, same as the Dockerfile.
- `bun`/`bunx` — for the QMD MCP, **libc-aware**: `_libc_variant` probes the host libc (musl loader file, then `ldd`, then `getconf`; defaults to glibc) and downloads the matching bun build. The idempotency guard runs `bun --version` — actual execution, not mere presence — so a wrong-libc binary gets re-provisioned instead of skipped. Needs `unzip` on the host; without it the install warns and the QMD MCP won't start.

The script is idempotent and best-effort (always exits 0; a failed optional install warns and continues), so `--login` is safe to re-run. `remote-control.env` pins the unit's `PATH` at `~/.local/bin` so the session finds everything. Version pins mirror the Dockerfile ARGs (as of v0.12.0: uv 0.11.22, bun 1.3.14, github-mcp-server 1.4.0). `BOOTSTRAP_DRY_RUN=1` prints the provisioning plan without touching the host.

### Absolute Claude CLI path

systemd resolves `ExecStart` against the manager's PATH, so a bare `claude` (the native installer puts it at `~/.local/bin/claude`, outside that PATH) fails with `status=203/EXEC` in a restart loop. The launcher avoids this: `resolve_claude_bin` persists an **absolute** path into `agent.yml` (`deployment.claude_cli`) at scaffold time, and unit emission re-resolves it against the operator's HOME — failing **loud** with an actionable message rather than emitting an unresolvable unit. If you move your Claude install, set `deployment.claude_cli` in `agent.yml` and re-run `./setup.sh --regenerate`.

### Companion units

Besides the session unit, `--login` installs and enables the units your feature selection implies. Each install needs **passwordless sudo**; without it the rendered unit is staged in `scripts/local/` and picked up by a later `--login` (`agentctl status` shows it as `staged (run --login)`).

| Unit | Installed when |
| --- | --- |
| `agent-<name>-healthcheck.timer` + `.service` | always |
| `agent-<name>-qmd-reindex.timer` + `.service` — scheduled reindex | QMD enabled |
| `agent-<name>-qmd-watch.service` — reindex-on-change watcher | QMD enabled |
| `agent-<name>-vault-backup.timer` + `.service` — vault backup to the fork | vault enabled |
| `agent-<name>-wiki-graph.timer` + `.service` — graph derive + structural lint | vault enabled (default-on with the vault) |

### Healthcheck

The healthcheck timer fires 2 minutes after boot and every 5 minutes thereafter, and reports one of three states via exit code: `OK` (0), `WARN` (1), `DEGRADED` (2).

- `DEGRADED` — unit not active, auth error in the journal (401 / "please run /login"), or login expired.
- `WARN` — no live relay connection, login expiring within 24h, a failed qmd-watch or wiki-graph unit, or a check it could not perform (no `ss`, no `jq`, unknown MainPID). It degrades gracefully rather than crying failure.
- **Connection check:** it asks whether the session process holds an ESTABLISHED `:443` socket (`ss -tnpH state established`, matched against the unit's `MainPID`) — not whether the journal says "connected".

It can notify on `DEGRADED` via optional `NOTIFY_BOT_TOKEN`/`NOTIFY_CHAT_ID` — read from the workspace `.env` (021), or from the legacy `<workspace>/.state/healthcheck-notify.env` if that file is present (a compatibility override for agents that had one before 021; a fresh scaffold never creates it). The token is fed to `curl` via a config file on stdin, so it never appears on argv or in the journal.

Operate and verify:

```bash
systemctl status  agent-<name>.service          # session state
journalctl -u     agent-<name>.service -f       # startup + errors only (see note)
./scripts/local/agent-killswitch.sh             # stop session + ALL companion units
./scripts/agentctl status                       # systemd-aware status
./scripts/agentctl doctor                       # full local diagnostic (exit 0/1/2)
```

**Note on the journal:** a healthy connected `--spawn=session` is **silent** after startup — do not wait for `connected` / `session url` lines to confirm health. Only the **healthcheck** uses the authoritative signal (the live ESTABLISHED `:443` socket). `agentctl status` and `agentctl doctor` still derive their "connection signal" line from a 10-minute journal grep, so on a healthy quiet session they print `no recent connection signal` (and `doctor` warns, exiting 1). Treat that line as advisory: cross-check with `systemctl is-active` plus the healthcheck's exit code before concluding the session is down.

**Kill switch scope:** `scripts/local/agent-killswitch.sh` (`sudo systemctl stop` under the hood) stops the session **and every companion unit** — qmd-reindex timer, qmd-watch, vault-backup timer, wiki-graph timer, healthcheck timer — best-effort, so a host missing any of them never errors out. This matters: stopping only the session would leave the backup timer pushing to the fork with your credentials and the healthcheck still notifying, hours after you thought the agent was off. Because the unit has `Restart=always`, an explicit `systemctl stop` does NOT relaunch it; pass `--disable` to also prevent start at boot. The remote equivalent is toggling Remote Control OFF for the session identity (`<hostname>-<agent>`) in claude.ai/code.

### agentctl in local mode

`agentctl` reads `deployment.mode` from `agent.yml` and dispatches accordingly. In local mode:

- **`status`** — session unit active/not, the journal-derived connection signal (see the caveat above), whether the login is present, and, when the vault/QMD pieces exist, a `vault/RAG` block: qmd reindex timer and watcher state (`active` / `installed (inactive)` / `staged (run --login)` / `absent`), whether the qmd index is built, last reindex + status, vault-backup timer, wiki-graph timer with last run and finding counts (broken links, frontmatter violations, index drift, orphans, alias occurrences).
- **`doctor`** — the same ground plus the Claude Code version, `.credentials.json` permissions (wants 0600), and the qmd/wiki-graph subsystem checks. Same exit contract as docker mode: 0 clean / 1 warnings / 2 failures, so `agentctl doctor || alert` is scriptable.
- **Docker-only subcommands** (`up`, `start`, `stop`, `restart`, `ps`, `attach`, `shell`, `run`, `logs`, `mcp`) never touch Docker: they exit 2 printing the systemd equivalents (`systemctl start|stop`, `journalctl -u … -f`, the kill switch).
- **`heartbeat qmd-reindex`**, **`heartbeat backup-vault`** and **`heartbeat wiki-graph`** exec the rendered `scripts/local/` entrypoints directly as the operator (no `systemctl`, no sudo). Every other `heartbeat` subcommand stays docker-only and exits 2. `qmd-reindex` rejects `--dry-run` (the entrypoint has none, and silently running a real reindex would be worse); `backup-vault` passes `--dry-run` through.

Because systemd/Linux cannot be exercised by the macOS DOCKER_E2E suite, local mode ships a **manual host verification gate** — see [`specs/011-local-standalone-mode/quickstart.md`](../specs/011-local-standalone-mode/quickstart.md) for the six production-verified checks (version, creds 0600, `is-active` + connection signal, `claude -p READY` without 401, idempotency, kill-9 auto-recovery).

Everything below this point is **docker mode**.

## First Boot

After scaffolding, start the agent:

```bash
cd <workspace>
docker compose build
./scripts/agentctl up            # == docker compose up -d
```

The in-container supervisor (`start_services.sh`) runs as PID 1 and launches Claude Code inside a detached tmux session. To reach the user-facing session, use `agentctl attach` (a retry-looped `docker exec` + `tmux attach`) — NOT `docker attach`, which only shows supervisor logs:

```bash
./scripts/agentctl attach
# equivalent to: docker exec -it -u agent <name> tmux attach -t agent
```

Detach from tmux without killing the session with `Ctrl-b d` (standard tmux binding).

## 1. Log in to Claude

Inside the tmux session:

1. Pick a theme (Enter accepts the default) and confirm trust on `/workspace`.
2. `/login` → opens an OAuth URL → paste the returned code. Credentials persist under `<workspace>/.state/` on the host (bind-mounted to `/home/agent` inside the container).
3. `/exit` (or Ctrl-D). Claude shuts down; the watchdog detects the session ended and re-evaluates.
4. **Wait ~2–3 seconds** before re-attaching. The supervisor polls every 2s; re-attaching immediately after `/exit` can show `no sessions` while the next session is still spinning up. Retry is harmless (`agentctl attach` retries for you).

## 2. Enter your Telegram bot token

Re-attach:

```bash
./scripts/agentctl attach
```

The supervisor now sees an authenticated profile with no `TELEGRAM_BOT_TOKEN` in `/workspace/.env`, so it launches the in-container wizard (interactive via `gum` prompts):

- **Telegram bot token** — paste the token from @BotFather. The `telegram@claude-plugins-official` plugin uses dynamic pairing, so no chat id is needed.
- **GitHub PAT** — only if the host wizard didn't capture it (skipped with `GITHUB_PAT already set by host wizard` otherwise).
- **Atlassian workspace tokens** — one prompt per workspace declared in `agent.yml` that still has an empty token.

The wizard writes `/workspace/.env` (0600) and exits. The watchdog respawns, now with token in hand:

1. Auto-installs `telegram@claude-plugins-official` (idempotent) if not already cached.
2. Syncs `TELEGRAM_BOT_TOKEN` from `/workspace/.env` to the channel-scoped `/home/agent/.claude/channels/telegram/.env` (where the plugin's MCP server actually reads it).
3. Launches Claude with `--channels plugin:telegram@claude-plugins-official`.
4. The plugin's `bun server.ts` starts polling Telegram.

**Wait ~2–3 seconds** again before re-attaching — same watchdog gap as after `/exit`.

## 3. Pair your Telegram account

Re-attach one more time (`./scripts/agentctl attach`), then:

1. DM the bot from Telegram — it replies with a 6-character pairing code.
2. In the Claude session: `/telegram:access pair <code>` (accept the `access.json` overwrite prompt).
3. Send a test DM from your phone — it should reach Claude and trigger a reply.

Detach with `Ctrl-b d`.

## Daily Use

`./scripts/agentctl` is the day-2 interface (it wraps the `docker exec -u agent` patterns so you don't have to remember them):

```bash
./scripts/agentctl up            # docker compose up -d
./scripts/agentctl attach        # tmux attach with retry-loop
./scripts/agentctl status        # heartbeatctl status (proxied into the container)
./scripts/agentctl doctor        # full diagnostic: Docker → container → agent.yml/.env →
                                 # tmux/crond → plugin (process + patches) → heartbeat →
                                 # vault → backups → token health
./scripts/agentctl mcp           # `claude mcp list` inside the container (doctor does not check MCPs)
./scripts/agentctl logs -f       # tail /workspace/claude.log
./scripts/agentctl logs --stderr # forensic tail of telegram-mcp-stderr.log
./scripts/agentctl heartbeat <sub>  # any heartbeatctl subcommand
./scripts/agentctl --help        # full subcommand list
```

`doctor` is the post-boot verification step; its exit code is scriptable: 0 = all checks passed, 1 = warnings only, 2 = failures. See [heartbeatctl.md](heartbeatctl.md) for the heartbeat subcommands.

All agent output and interaction happens inside the container. There is no host-side tmux or CLI state.

## Upgrade

Workspaces build from their **own** copy of the `docker/` tree (the compose file's build context is `./docker` inside the workspace), so pulling the launcher repo does **not** update an existing agent. The supported update path is:

```bash
cd <workspace>

# Optional: tag the current image as a rollback point
docker tag agentic-pod:latest agentic-pod:prev

# Pull template improvements (fork-based agents only)
./setup.sh --sync-template      # fetches upstream/main, fast-forwards main,
                                # pushes to origin, rebases the live branch

# Rebuild and restart
docker compose build
docker compose up -d
```

`--sync-template` requires a fork-based agent (`scaffold.fork.enabled=true` in `agent.yml`), a clean working tree, and being on the `*/live` branch. Agents scaffolded without a fork have no automated sync path — port changes manually or re-scaffold.

The image tag comes from `agent.yml` (`docker.image_tag`, default `agentic-pod:latest` as of v0.12.0) — adjust the `docker tag` commands if you changed it.

The workspace (including `.state/`) is on the host as a bind-mount, so all agent data, login, and pairing survive the rebuild untouched.

## Rollback

If the new image is unstable:

```bash
docker tag agentic-pod:prev agentic-pod:latest
docker compose up -d
```

The container restarts with the previous image. No state is lost.

## Backup and restore

Agents with a GitHub fork replicate their non-regenerable state to three independent orphan branches in the fork: `backup/identity` (login, pairing, plugin config, encrypted `.env`), `backup/vault` (markdown subset of the vault), and `backup/config` (`agent.yml`, no secrets). Identity backups run automatically (watchdog + daily cron); trigger one manually with `./scripts/agentctl heartbeat backup-identity`.

To rebuild an agent on a new host (or after `--nuke`):

```bash
./setup.sh --restore-from-fork <fork-url>   # optionally --identity-key <ssh-key-path>
                                            # to decrypt .env.age (defaults try
                                            # ~/.ssh/id_ed25519 then id_rsa)
```

Restore pulls the branches in order — config first (so `vault.path` is known), then identity, then vault — and skips any branch that is absent. Alternatively, since the workspace directory IS the agent, a plain `rsync`/`cp -a` of the workspace migrates everything.

## Rotating Secrets

### Docker mode

`.env` is injected via `env_file`, which only applies at **container creation** — a plain restart does not re-read it, so the container must be recreated for the new value to reach the process environment:

```bash
nano <workspace>/.env             # edit the secret

# GITHUB_PAT / ATLASSIAN_* / other MCP secrets: the container must be recreated
docker compose up -d --force-recreate
```

No rebuild is needed.

**`TELEGRAM_BOT_TOKEN` needs one extra step.** The channel plugin does not read `/workspace/.env`; it reads a channel-scoped env at `<workspace>/.state/.claude/channels/telegram/.env`. The supervisor seeds that file only when the key is *absent* (`ensure_channel_env_synced`, `docker/scripts/start_services.sh:408`) — it never overwrites an existing value, so after pairing a plain restart leaves the **old** token in place. To rotate:

```bash
nano <workspace>/.env                                          # new token here too
rm <workspace>/.state/.claude/channels/telegram/.env           # drop the stale copy
docker compose restart                                         # supervisor re-seeds it from .env
```

Equivalent alternative: run `/telegram:configure <new-token>` inside the Claude session, which rewrites the channel-scoped env directly.

### Local mode (021)

The session unit loads `.env` via `EnvironmentFile=-<workspace>/.env`, and — like docker's `env_file` — systemd only reads it at process **spawn**. Editing `.env` alone does nothing until the unit restarts:

```bash
nano <workspace>/.env                        # edit the secret
sudo systemctl restart agent-<name>.service  # MANDATORY — EnvironmentFile is read at spawn
./scripts/agentctl doctor                    # confirm: no secrets warning
```

If `agentctl doctor` warns `installed unit does not load .env yet`, the *installed* unit predates 021 — re-run `./setup.sh --regenerate`, then (only if it prints "staged … sudo unavailable") `sudo cp ./agent-<name>.service /etc/systemd/system/ && sudo systemctl daemon-reload`, then the restart above.

The healthcheck (a separate oneshot unit, no `EnvironmentFile` of its own) re-reads `NOTIFY_BOT_TOKEN`/`NOTIFY_CHAT_ID` straight from `.env` on its next tick — no restart needed for that one.

## Teardown

To remove the agent completely:

```bash
cd <workspace>
./setup.sh --uninstall --yes
```

This:

1. Stops the container with `docker compose down` (state under `.state/` is preserved — `docker compose down -v` is a no-op since state lives in the workspace, not a named volume).
2. Removes the host systemd units — session unit plus any companion timers (Linux only, and only when passwordless sudo is available; otherwise it prints the `agent-<name>*.{service,timer}` names for manual removal with sudo).
3. Keeps the workspace directory, including `agent.yml`, `.env`, and `.state/` so a re-install carries login + pairing.

To also delete agent.yml/.env/.state:

```bash
./setup.sh --uninstall --purge --yes
```

To also delete the workspace directory itself:

```bash
./setup.sh --uninstall --nuke --yes
```

After `--nuke`, no traces of the agent remain on the host (dotfiles and state gone; systemd units too, given sudo as above). If the agent had a fork with backups, a later `./setup.sh --restore-from-fork <url>` can resurrect it.

## Troubleshooting

### Every Telegram message triggers a permission prompt

In steady state, Claude is launched with `--dangerously-skip-permissions` so
tool calls (including `mcp__plugin_telegram_telegram__reply`) don't stall on
approval prompts for every Telegram message. If you're still seeing prompts,
your container is running a pre-fix image — `docker compose build &&
docker compose up -d --force-recreate` will pick up the updated launch line.

The flag is scoped to the `--channels` launch only. The pre-`/login`
session (before you authenticate) still respects permission prompts,
because that's the interactive phase where you want the confirmations.

### `docker attach <name>` hangs with no output

`docker attach` connects to the container's PID 1 stdio. PID 1 is the supervisor (`start_services.sh`), which runs its watchdog loop silently once the tmux session is up — so attach just hangs, no prompt, no UI.

The user-facing Claude session lives inside a detached tmux session owned by the `agent` user. Use this instead:

```bash
./scripts/agentctl attach
# or: docker exec -it -u agent <name> tmux attach -t agent
```

If you accidentally ran `docker attach` and are stuck, detach with `Ctrl-p Ctrl-q` (NOT `Ctrl-c`, which would kill the container).

### `docker exec … tmux attach -t agent` says "no sessions"

`docker exec` runs as root by default, and tmux keeps a per-UID socket at `/tmp/tmux-<uid>/default`. The session is owned by the `agent` user (whose UID is your host UID, baked at build time), so a root-owned exec looks at `/tmp/tmux-0/` and correctly reports no sessions there. Always pass `-u agent` — or use `./scripts/agentctl attach`, which does:

```bash
docker exec -it -u agent <name> tmux attach -t agent
```

### `plugin:telegram:telegram · ✘ failed` (no pairing code sent)

Two possible causes:

1. **Plugin not installed yet.** On first boot Claude launches before `/login`, so plugins can't install. After you `/login`, the watchdog auto-installs the plugins declared in `agent.yml` on the next respawn and re-launches with `--channels` — no manual restart needed. If one stays failed, `./scripts/agentctl doctor` lists it (from `.state/plugin-install-failures.jsonl`) with a copy-paste retry command.
2. **`bun` missing from the image.** The plugin's MCP server is a bun script. The shipped Dockerfile installs bun; if you built a custom image without it, `/mcp` will show the plugin as failed. Run `docker exec <name> bun --version` to confirm.

Verify with `/mcp` inside the Claude session — look for the line `plugin:telegram:telegram · ✔ connected`.

### `uvx: not found` on `time` / `fetch` / `atlassian-*` MCPs

These MCPs run via `uvx` (astral's `uv` Python runner). The shipped Dockerfile installs `uv` statically. Check:

```bash
docker exec <name> uvx --version
```

If missing and you're running a custom-built image, rebuild from the template's Dockerfile or add the `uv` install step manually.

(Local mode note: the same symptom on a local-mode agent means `agent-bootstrap.sh` hasn't provisioned the runtimes — re-run `./setup.sh --login`.)

### `docker attach` doesn't respond to keystrokes

`docker attach` is connected but the wizard (gum-driven) needs a TTY. The shipped `docker-compose.yml.tpl` sets `stdin_open: true` and `tty: true` — if you wrote a custom compose without these, input will silently drop. Add them and recreate:

```bash
docker compose up -d --force-recreate
```

**Always detach with `Ctrl-p Ctrl-q`.** `Ctrl-c` sends SIGINT and kills the container.

### `addgroup: gid '<N>' in use` at build time

macOS users have GID 20 (`staff`) and alpine ships a system group at GID 20 (`dialout`). The Dockerfile handles this by deleting the conflicting group/user before creating `agent`. If you modified the group-creation stanza, put the delete-then-create logic back (see `docker/Dockerfile`).

### Telegram bot responds with only the welcome text (no pairing code)

The bot polls via long-poll. If it sends only `"This bot bridges Telegram to a Claude Code session. To pair: …"` and never emits a code, the plugin's MCP server isn't running. Check:

```bash
docker exec <name> ps -ef | grep -E "bun|telegram"
docker exec -u agent <name> tmux send-keys -t agent '/mcp' Enter
docker exec -u agent <name> tmux capture-pane -t agent -p | tail -30
```

Look for `plugin:telegram:telegram · ✔ connected`. If `✘ failed`, apply the fix in the first entry above.

### `🔐 Permission: mcp__plugin_telegram_telegram__reply: not authorized`

The bot surfaces this when Claude tries to reply but the MCP tool call wasn't pre-authorized. Inside the Claude session, when prompted "Do you want to proceed?", pick **option 2** ("Yes, and always allow access to telegram/ from this project"). This writes a setting under the project that skips future prompts. If your pairing already happened and you want persistent approval, run any `/telegram:access …` command once more and accept option 2.

### UID mismatch (permission errors in logs)

If you see permission errors on bind-mount files, verify that `docker.uid` in `agent.yml` matches the host user:

```bash
id -u                                  # your user ID on the host
yq '.docker.uid' <workspace>/agent.yml # should match
```

If they differ:

```bash
# Edit agent.yml and update docker.uid to match your user ID
nano <workspace>/agent.yml
docker compose build
docker compose up -d --force-recreate
```

### Container logs

```bash
docker logs <name>
docker logs -f <name>           # follow in real time
./scripts/agentctl logs -f      # tail /workspace/claude.log (tmux pane capture)
docker exec <name> cat /workspace/claude.cron.log                        # busybox crond daemon log
docker exec <name> cat /workspace/scripts/heartbeat/logs/cron.log        # heartbeat tick output
```

### Wizard re-fires on every restart

Means `/workspace/.env` is missing, empty, or doesn't contain `TELEGRAM_BOT_TOKEN=<non-empty>`. Verify:

```bash
ls -la <workspace>/.env       # should be 0600
grep "^TELEGRAM_BOT_TOKEN=" <workspace>/.env
```

If the value is present but the wizard still fires, check that the bind-mount path matches: `docker exec <name> cat /workspace/.env` should show the same content.

### `3 MCP servers failed` / `4 MCP servers failed` at launch

`/mcp` inside the Claude session lists each server with its connection state. Ignore failures from `claude.ai`-scoped servers (those require external auth you haven't configured); the ones to care about are `plugin:telegram:telegram`, `atlassian-*`, `github`, `playwright`. Most failures trace back to missing env vars in `/workspace/.env` (Atlassian token, GitHub PAT) or missing binaries (`bun`, `uvx`).
