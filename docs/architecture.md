# Docker Architecture

Docker mode runs each agent inside a container with a self-contained workspace on the host: both the editable files and the agent's private state (login, pairing, sessions) live under the same directory, mounted into the container via two bind-mounts. This section describes the layout, process tree, and lifecycle.

## Deployment modes (`deployment.mode`)

The wizard offers two deployment modes, persisted in `agent.yml` as `deployment.mode` (the single source of truth; legacy workspaces without the key are treated — and backfilled — as `docker`):

| | `docker` (recommended, default) | `local` (opt-in, Linux/systemd only) |
|---|---|---|
| Runtime | Isolated Alpine container | Directly on the host as the operator's user |
| Auth | Inference-only token (`CLAUDE_CODE_OAUTH_TOKEN`) | **Full-scope interactive OAuth login** (one-time per host) |
| Session | `claude --channels` in tmux under a supervisor | `claude remote-control --spawn=session` under a systemd unit |
| Artifacts | `docker-compose.yml`, `docker/` build context, docker systemd unit | systemd unit + `EnvironmentFile` + login/healthcheck/kill-switch helpers under `scripts/local/` |
| Isolation | `cap_drop: ALL`, `no-new-privileges`, non-root (Principle II) | **None** — inherits the operator's privileges/secrets |

The config base (`CLAUDE.md`, `.mcp.json`, `scripts/heartbeat/*`, vault, RAG) is rendered the same way in both modes; only the runtime wrapper differs. The branch lives in `setup.sh` (the docker-compose render + catalog mirror are skipped for `local`), so **docker mode stays byte-identical** to before this feature. Switching modes on `--regenerate` warns about the now-orphaned artifacts of the previous mode and never deletes them.

> **Principle II trade-off (local mode).** Local mode is a deliberate, opt-in violation of the least-privilege container model: there is no container, so no `cap_drop`/`no-new-privileges`, and the agent runs as the operator's login user — inheriting their files, SSH keys, and tokens. It exists because Claude Code Remote Control **requires** a full-scope interactive login that ephemeral pods cannot provide. Mitigations: opt-in with an explicit wizard warning; docker mode untouched; never `--dangerously-skip-permissions` (live confirmations stay on); MFA mandatory; secrets confined to gitignored `.state/`. Remote Control persistence (login, trust, unit, healthcheck, kill-switch) is detailed in [`specs/011-local-standalone-mode/`](../specs/011-local-standalone-mode/). Heartbeat scheduling and plugin auto-install are **not** ported to systemd; the RAG/backup automation (qmd reindex timer + watcher, vault backup, wiki-graph) *is* — as per-agent systemd units since 012/014, described in the local-mode paragraphs of the [Vault layer](#vault-layer-karpathy-llm-wiki-opt-in) section. Local-mode hardening (`015-local-mode-hardening`): the remote-control unit's `ExecStart` uses an absolute CLI path — `resolve_claude_bin` resolves it at scaffold time, persists it to `agent.yml`, and the render fails loud if it is still unresolvable at unit-emit time (a bare `claude` under systemd's minimal `PATH` was a 203/EXEC) — and the local bootstrap's `_libc_variant` probes glibc vs musl to install the matching bun build.

## Local healthcheck (047)

`setup.sh` renders a define-only helper and the executable CLI into `scripts/local/` only
for local mode. The existing oneshot service, `User`, success-exit policy and five-minute
timer remain intact. No Docker mirror or image-baked consumer is added. Regenerate updates
the pair under its existing service-installation policy: with `deployment.install_service:true`
and available sudo, it can reinstall units and enable timers. Validation uses a disposable
workspace with service installation disabled.

Observation combines a complete `claudeAiOauth` profile, a bounded per-event journal
classification and a cgroup-v2 socket inventory. Renewal WARN starts at seven days before
`refreshTokenExpiresAt`; expired access alone is not lost login. Process directories are
pinned while start time, cgroup membership and FD socket inodes are checked against the
same unit invocation. ESTABLISHED remote-port-443 ownership is a transport signal, not proof
of conversation responsiveness. Unknown evidence yields WARN; observed DEGRADED dominates.

The optional notice controller owns `.state/.local-healthcheck.lock` in its parent process;
children close that descriptor. Contenders observe health but never mutate the notice state.
Schema-1 `.state/local-healthcheck.json` is a bounded mode-0600 ledger with closed fields,
event versions, confirmation and retry accounting; it contains no tokens, messages or raw logs.
A same-directory private temporary is validated, synchronized, renamed and followed by a
directory synchronization. Existing checkpoints cross a file/directory adoption barrier.
Unavailable persistence suspends notices while leaving the health result intact.

Transitions into renewal WARN, DEGRADED and eligible recovery produce at most one delivery
attempt per evaluation. A failed pending notice retries after thirty minutes, with a persisted
wall-clock high-water mark that avoids double credit after backward time adjustments.
Recovery requires a confirmed alarm in the episode; superseded unconfirmed alarms are cancelled.
Curl receives quoted configuration on stdin with unexported secrets and uses a private unlinked
response capture. API acknowledgement plus a durable commit confirm delivery. Lost responses
or uncertain storage can cause duplicates on retry; exactly-once delivery is not promised.

All phases use the original monotonic deadline: at most 25 s for observation, at most 30 s
for notices after observation, and 60 s for the invocation, including TERM/KILL and cleanup.
The CI Linux integration job exercises isolated non-root systemd services, cgroups and real
loopback HTTP with fictional data. Its ten scenarios and confirmed cleanup are required
before merge; host fixture tests alone do not establish that integration.

Operator details and dependencies: [getting started](getting-started.md#healthcheck).
Contracts and evidence: [`specs/047-local-healthcheck/`](../specs/047-local-healthcheck/).

## Host / Container / Volume Layout

```
HOST (e.g. myhost)
├── ~/agents/<name>/                    ← the workspace IS the agent
│   ├── CLAUDE.md
│   ├── .env                            ← 0600, secrets written by wizard
│   ├── agent.yml
│   ├── scripts/heartbeat/
│   │   ├── heartbeat.sh
│   │   ├── heartbeat.conf
│   │   └── logs/
│   ├── docs/
│   ├── .git/
│   ├── agent-repo/                     ← the agent's work clone (046, only with an
│   │                                     agent repository; gitignored)
│   └── .state/                         ← bind-mounted to /home/agent inside container
│       └── .claude/                    ← OAuth login, sessions, plugin cache,
│                                         channels/telegram/access.json (pairing)
│
├── /etc/systemd/system/agent-<name>.service   ← host systemd unit
│
└── cloudflared (unchanged, SSH tunnels only)

CONTAINER (image agentic-pod:latest by default as of v0.12.0 — agent.yml docker.image_tag — one per agent)
├── tini (PID 1)
│   └── entrypoint.sh
│       ├── first-run check → wizard-container.sh (interactive)
│       └── steady-state   → start_services.sh (watchdog + services)
│
├── /opt/agent-admin/                   ← baked in image (read-only)
│   ├── entrypoint.sh
│   ├── scripts/start_services.sh       ← watchdog loop
│   ├── scripts/wizard-container.sh           ← first-run prompts
│   └── crontab.tpl
│
├── /workspace/                         ← bind-mount (host's ~/agents/<name>)
└── /home/agent/                        ← bind-mount (host's ~/agents/<name>/.state)
```

## Process Tree Inside Container

```
PID 1: tini
  └── start_services.sh (bash watchdog)
        ├── crond (background)
        │     └── every N min (default 30): /workspace/scripts/heartbeat/heartbeat.sh
        │
        ├── tmux server (session "agent")
        │     └── claude CLI (Telegram polling, interactive)
        │
        └── watchdog loop (respawns tmux/claude on death, backoff on repeated crashes)
```

The watchdog polls tmux every 2s (`tmux has-session` plus a channel-plugin liveness check) and respawns on death. After 5 crashes in 5 minutes the container exits and Docker's `unless-stopped` policy restarts it.

## Lifecycle Phases

### Phase 1: Scaffold (host)

```bash
./setup.sh                          # interactive wizard
./setup.sh --destination ~/my-agent # skip the destination prompt
```

Runs interactively on the host. Collects agent config (name, personality, MCPs, notifications) but **does not ask for Telegram chat secrets** — those are deferred to the in-container wizard so they never sit on disk in plaintext outside the bind-mount. Renders:

- `<destination>/` with `agent.yml`, `CLAUDE.md`, `docker-compose.yml`, `.mcp.json`, `scripts/`, `docker/`.
- On Linux only, `/etc/systemd/system/agent-<name>.service` (wraps `docker compose up -d`).

Detects the host user's UID and GID and writes them to `docker-compose.yml` as build args (`UID`, `GID`). The container's `agent` user is created with the same numeric ownership at image-build time so writes through the bind-mount land with the host user's identity.

### Phase 2: First-run wizard (container)

```bash
cd ~/agents/<name> && docker compose up -d && docker attach <name>
```

The host-side wizard intentionally skips Telegram secrets. The first time the container boots:

1. `entrypoint.sh` runs as root, fixes ownership of `/home/agent` (the bind-mount target), renders a safe-default crontab to `/etc/crontabs/agent`, starts the root crontab-sync loop, starts `crond`, then `exec su-exec agent /opt/agent-admin/scripts/start_services.sh`.
2. `start_services.sh::next_tmux_cmd` decides the launch:
    - **Case A** — no Claude profile yet → `claude` (bare) so the user runs `/login` interactively.
    - **Case B** — authenticated but `/workspace/.env` lacks `TELEGRAM_BOT_TOKEN` → `wizard-container.sh` (gum prompts for the token, writes `.env` with 0600). When the wizard exits, the watchdog respawns and re-decides.
    - **Case C** — token present → `claude --channels plugin:telegram@claude-plugins-official --dangerously-skip-permissions [--continue]`.

Each respawn re-evaluates these cases, so going from "no login" → "/login done" → "token saved" happens without manual restart.

### Phase 3: Steady state

`start_services.sh` runs an event loop on the `agent` user:

```text
loop every 2s:
  if crond died             → exit 1   (Docker restarts the container)
  if tmux session alive
     and channel plugin OK  → continue
  if tmux alive but bun     → kill tmux + respawn (forces fresh plugin attachment)
     server.ts gone
  otherwise (tmux gone)     → respawn via next_tmux_cmd

crash budget: 5 crashes within a 300s window → exit 1
```

Real-world detail worth noting:

- **No `pgrep claude`.** Earlier iterations grepped the process tree, which false-positived on every claude subprocess (heartbeat ticks, `claude plugin install`, etc.). The current check is purely on the tmux session.
- **Channel plugin liveness** is checked separately because bun can die while tmux stays up (claude keeps running but stops receiving Telegram messages); kill+respawn re-attaches the plugin.
- **Channel boot health-check timeout.** After a `--channels` launch the supervisor waits for `bun server.ts` to appear before marking the session healthy; if it never does, it kills + respawns. That wait defaults to 60s and is set via `docker.channel_health_timeout_s` (seconds) in `agent.yml` (`026-channel-watchdog-timeout` introduced the knob; `036-cold-start-boot-resilience` moved it out of the `.env`) — a hardcoded 20s used to flap slow hosts. It interacts with the crash budget: an override `≥65s` logs a boot warning that 5 failures may no longer fit the 300s window, so the container might not escalate to a restart. The in-container reader is unchanged and still consumes the `CHANNEL_HEALTH_TIMEOUT` env var with the same 60 default and the same absent/invalid fallback; only the source moved, from `env_file:` to the rendered compose `environment:` block, which outranks it. A key left behind in the workspace `.env` is migrated into `agent.yml` on the next `--regenerate`, which prints a note naming the leftover — so an operator who widened the window keeps it across the upgrade.
- **No bridge watchdog.** A previous attempt to detect "bun alive but MCP notifications dropped" via tmux pane scraping was reverted (see commit `ebfe35f`) because the false-positive rate killed sessions every ~2 minutes during normal use. Manual recovery is `heartbeatctl kick-channel`.
- **Reply-delivery guard (`028`).** A live agent under a long conversation can answer as plain TUI text instead of calling the `plugin:telegram:telegram` reply tool, so nothing reaches the chat while the typing indicator misfires. The telegram plugin writes a `pending-reply.json` marker on each inbound (cleared when the reply tool fires); a Claude Code **Stop hook** (`scripts/hooks/stop-redeliver.sh`, merged into `~/.claude/settings.json` by `pre_install_stop_hook` right after `pre_accept_bypass_permissions`, before the session starts) fires at turn-end and, if a channel turn ended with that marker present, re-injects one corrective nudge (`{"decision":"block", …}`) so the agent resends through the tool. Bounded to one attempt by `stop_hook_active`, fail-silent, one stderr line per fire, gated on `features.reply_guard`. The heartbeat's isolated config drops `.hooks.Stop` so plugin-less cron ticks never carry it.
- **MCP warm cache (`030`).** `pre_warm_mcps` runs synchronously just before the tmux launch (after the other `pre_*` hooks, before Claude starts its MCPs). It derives the set of `uvx`/`npx` packages from the effective `.mcp.json` via `scripts/lib/mcp_warm.sh` (`mcp_warm_targets` scans `command`+`args`, so overlay wrapper commands like `seed-creds.sh → uvx workspace-mcp` are covered) and warms them into `/opt/uv` + `/opt/npm-cache` (off the state mount). Fail-soft, idempotent, timeout-bounded, secret-free: a cold download no longer races the handshake window (the root cause `029` only widened). Local mode does the same for `uvx` packages during `--login` (`provision_uv_tools`, args-aware). Requires `DOCKER_E2E` (image-baked).

Every N minutes (configurable via `agent.yml`'s `features.heartbeat.interval`, default 30m), `crond` dispatches `/workspace/scripts/heartbeat/heartbeat.sh` as the `agent` user. The heartbeat probes the agent and writes a structured trace; the notifier (none / log / telegram, configurable) forwards a status line. See [Heartbeat Pipeline](#heartbeat-pipeline) below.

## Restart Layers

Three independent restart mechanisms:

```
watchdog in-container ──► Docker `unless-stopped` ──► systemd host unit
  (tmux/claude death)      (container exit)           (host reboot / OOM)
```

- **In-container watchdog** respawns tmux/claude on isolated crashes.
- **Docker restart policy** restarts the container if it exits.
- **systemd unit** (on the host) ensures the container starts on boot and restarts if Docker itself crashes.

## Connecting to the Session

```bash
ssh <host>
docker exec -it -u agent <name> tmux attach -t agent
# Ctrl-b d to detach
```

This is exactly one extra hop over the current host-mode flow (`ssh <host> && tmux attach`).

## Upgrade & Rollback

### Upgrade

The workspace is **self-contained**: the scaffold copies `setup.sh`, `VERSION`, `modules/`, `scripts/` and (docker mode) `docker/` into it, and `docker-compose.yml` builds from the workspace's own `./docker` context. Pulling a newer launcher clone therefore changes nothing by itself — running `docker compose build` in an untouched workspace silently rebuilds the *old* code. To upgrade, bring the new launcher code into the workspace first (as of v0.12.0 the default image tag is `agentic-pod:latest`, per-agent via `agent.yml` `docker.image_tag`):

```bash
# Backup current image
docker tag agentic-pod:latest agentic-pod:prev

# Copy the updated launcher code into the workspace
cd ~/agents/<name>
cp -R /path/to/updated-launcher/setup.sh /path/to/updated-launcher/VERSION .
cp -R /path/to/updated-launcher/modules /path/to/updated-launcher/scripts /path/to/updated-launcher/docker .

# Re-render derived files from agent.yml, then rebuild and restart
./setup.sh --regenerate
docker compose build
docker compose up -d
```

The copy overwrites only same-named launcher files — workspace-local state under `scripts/heartbeat/` (`heartbeat.conf`, `logs/`, state files) is left in place, and `--regenerate` re-renders the derived files. Workspace bind-mounts and `.state/` persist. All agent data survives.

### What an upgrade leaves behind, and how the agent learns about it (038)

`--regenerate` re-renders derived files, but two documents the agent itself reads sit outside that
mechanism, and each fell behind silently until someone noticed (donna described its RAG with the
pre-0.27.0 model, weeks after the code was current):

1. **The vault's own `CLAUDE.md`** is never rewritten: it is the agent's co-evolved schema. New schema
   arrives as a *delta* document that the agent must integrate (see `docs/vault.md`).
2. **The workspace `CLAUDE.md`** is a derived file, but `--regenerate` used to preserve it
   unconditionally. It now renders the current template once into
   `.state/launcher/claude-md.upstream.md` (U) and compares three files byte for byte: `CLAUDE.md` (C),
   U, and `.state/launcher/claude-md.baseline.md` (B), the render that C incorporates.

| Situation | What `--regenerate` does |
|---|---|
| C equals B and differs from U (nobody edited it) | **Refreshes** C from U and moves B. The persona is safe: it lives in `personas/<agent>.md` and is injected by the render, it is not stored in `CLAUDE.md`. |
| C has edits of its own | **Preserves** C byte for byte, leaves U to compare against, and says so. |
| No baseline yet (every agent scaffolded before 0.28.0) | **Preserves** and says so. Run `./setup.sh --regenerate --force-claude-md` once per agent (answer `y`): from then on every upgrade applies by itself. |
| `--force-claude-md`, confirmed | Rewrites C from U and establishes B. |

After merging a template change by hand into an edited file, record it with
`cp .state/launcher/claude-md.upstream.md .state/launcher/claude-md.baseline.md`. If a separate
overlay re-applies extra configuration after a regenerate (custom MCP injection, for example), run it
**after** the forced re-render, not before: the forced render rebuilds the derived files it touched.

Both layers are **announced, never applied**. A `SessionStart` hook (`scripts/hooks/upgrade-notice.sh`,
registered by `start_services.sh` at every docker boot and by login / `--regenerate` in local mode)
puts one notice into the agent's context at the start of every interactive session while something is
pending, and nothing when nothing is. Heartbeat ticks never receive it (their isolated
`settings.json` drops the hook), and `agentctl doctor` shows the same two layers to the operator in
both modes. Switch the notice off with `features.upgrade_notice.enabled: false`. **Not yet measured:**
whether the sessions `claude remote-control` creates run `SessionStart` hooks; in local mode `doctor`
is the surface that is guaranteed until that is confirmed (`specs/038-schema-delta-boot-nudge/`, gate G0).

### Rollback

```bash
docker tag agentic-pod:prev agentic-pod:latest
docker compose up -d
```

Container restarts with the previous image.

## Secrets and Environment Variables

`.env` is a host-side file (0600 permissions) bind-mounted into the container's `/workspace/` directory. The `docker-compose.yml` uses `env_file: ./.env` to inject these into the container's environment.

To rotate secrets (e.g. Telegram token):

```bash
nano ~/agents/<name>/.env
docker compose restart
```

Changes take effect immediately. No rebuild needed.

`GITHUB_PAT` is no longer only the GitHub MCP's: with an agent repository (046) the backups push with it and the agent's work clone fetches and pushes with it, so the wizard writes it when either is on (`.env.example` carries it under the same condition).

## Backup destination, credential and encryption (046)

Each backup unit keeps its own image-baked library (`backup_identity.sh`, `backup_vault.sh`, `backup_config.sh`, and since 046 `backup_memory.sh` and `backup_history.sh`): its own branch, clone cache, hash, staging and commit. What the units share is a closed list of code that never stages a tree, commits or pushes (constitution, Principle V): `docker/scripts/lib/backup_dest.sh` (destination rule, credential, privacy check and its record, ownership mark, per-unit lock, record of the last attempt) and `docker/scripts/backup_store.py` (the encrypted block store). Commands, results and messages: [`docs/heartbeatctl.md`](heartbeatctl.md#backup-commands).

- **Backups in main (048).** With `repo` every unit stages and commits in its own local cache, as in 046, and `backup_main.sh` publishes that tree into `.agent-backup/<unit>/` of `main`: a bare `blob:none` clone of depth 1 fetches the tip (trees only), rebuilds the root with `mktree --missing` replacing only the unit's entry, `commit-tree -p <tip>`, and pushes without force; a moved `main` means rebuild and retry, a protection means the pull-request path (`backup_pr.sh`). After a verified write the unit deletes its marked legacy `backup/<unit>` branch. The restore reads `main` first, then the branch.
- **Destination rule.** `backup_dest_resolve` answers `repo` when `backup.repo.url` is set, else `fork` when `scaffold.fork.url` is set, else `none`; it is read-only and always returns 0. With `fork` or `none` no unit runs any 046 code: messages, exit codes, state files and the crontab are those of before. The supervisor's "is there a destination" check for the identity trigger uses the same rule. Local mode is out of scope: its vault-backup wrapper still reads `scaffold.fork.url` only.
- **Credential.** The repository path pushes with `GITHUB_PAT`, which reaches the container through compose's `env_file`. Every repository-path git call runs with `GIT_TERMINAL_PROMPT=0`, `GIT_ASKPASS=/opt/agent-admin/scripts/git-askpass-agent.sh` (only when `GITHUB_PAT` is non-empty; otherwise `/bin/true`, as the fork path always had), `GIT_CONFIG_GLOBAL=/dev/null` and `GIT_CONFIG_NOSYSTEM=1` (so the agent's own `~/.gitconfig` cannot change a backup), and `LC_ALL=C` (so git's messages can be recognised), under `timeout -k 10`. The askpass answers `x-access-token` for the username and the token for the password and prints nothing else; the token never goes into an argument, a URL, git config, a log or a state file.
- **Privacy and ownership.** Before every push, an anonymous `git -c credential.helper= ls-remote --heads` with `GIT_ASKPASS=/bin/true` must be refused for lack of a credential (a successful one means public: never pushed), and the same query with the askpass must succeed; its output is reused as the list of remote heads. The verdict is recorded in `scripts/heartbeat/backup-dest.json`. The ownership mark is read with `git show origin/backup/<unit>:.agentic-pod-backup.json`, without a checkout. No push uses `--all`, `--mirror` or any ref other than `refs/heads/backup/<unit>`.
- **Per-unit lock.** Each repository-path run takes `flock -n 9` on `scripts/heartbeat/.backup-<unit>.lock`. A second run of the same unit says so, exits 0 and records nothing; different units run in parallel, each on its own cache. The lock is released explicitly with `flock -u 9`, and descriptor 9 is closed for every child (`9>&-`), because BusyBox `timeout` leaves a watchdog child that would otherwise hold it about a second longer (the 044 lesson).
- **Block store and its data key.** `backup_store.py` uses only the Python standard library (it runs on 3.9, the floor for the restoring host, and in the image) and the `age` / `age-keygen` binaries. Every `store/` has its own `age` key pair: `age-keygen` generates it and its output is piped to `age`, so the private part is never written in plaintext; `store/key.age` is that private part encrypted for the operator's ssh public key (`backup.identity.recipient`), `store/recipient` its public part, `store/operator` the fingerprint of the operator key. Files are split into blocks of up to 1 MiB, gzip-compressed, encrypted for the data key and stored as `store/blocks/<2 hex>/<sha256 of the encrypted block>.age`, so a block name tells nothing about its content; a local block map (`<cache>/<unit>-repo.blockmap`, outside any committed tree) maps each plaintext block to its file, so an unchanged block is not re-encrypted while that map lives; `store/manifest.json.age` lists every file, its blocks and their plaintext hashes. `unpack` checks each block file against its name before decrypting it, refuses any path with a `.git` segment, and drops setuid, setgid and sticky bits. The store **rotates** (new key pair, every block re-encrypted, a full upload) when it has no key yet, when the operator key changed, or when its `recipient` differs from the `store_recipient` the unit recorded, so content placed in the repository cannot redirect the encryption to another key. SQLite databases are packed as a consistent copy made with SQLite's backup API, and `.jsonl` files up to their last newline. A restore opens `key.age` with one `age` call per store, which is why a passphrase-protected key is asked once per store. The encryption gives confidentiality, not authenticity: `age` does not sign, and the backup trusts the repository's access control.
- **Work clone.** `docker/scripts/lib/agent_repo.sh::agent_repo_ensure` runs once per boot, in the background, from `start_services.sh::main()` (never from `_run_watchdog`, whose body is frozen), and at the end of every `heartbeatctl backup-config`. If `/workspace/agent-repo` is missing it creates it (init, remote, a fetch capped at 120 s, then the remote's default branch if it is a work branch, else `main`, else the first work branch alphabetically, else a local `main` with no commits); if it exists it only re-asserts two settings: `remote.origin.fetch` excludes `refs/heads/backup/*`, and `credential.<scheme>://<host>.helper` points at `git-credential-agent.sh`. The launcher never commits or pushes in that clone; a failure goes to `scripts/heartbeat/logs/agent-repo.log` and changes neither the boot nor the config unit.

## Security

- **UID/GID matching:** Container user is created at build time with the host's UID/GID, preventing bind-mount permission issues.
- **Capabilities:** Container drops ALL capabilities and adds only `CHOWN`, `SETUID`, `SETGID` (for the initial entrypoint to chown the volume).
- **Read-only root:** Not currently enforced, but the image layer is read-only; only `/tmp` (tmpfs, 100 MB as of v0.12.0 — `docker-compose.yml.tpl`) and bind-mounts are writable.
- **Host-backed scratch for RAG (015):** the 100MB tmpfs is too small for qmd's bun installs, model downloads and native builds, so both RAG runners route `TMPDIR` to a disk-backed bind-mount via `scripts/lib/rag_obs.sh::scratch_dir` — qmd under its cache root (`<qmd cache root>/tmp`, i.e. `.state`), wiki-graph under the workspace's `scripts/heartbeat/tmp` for its awk/jq intermediates; the compose tmpfs itself is untouched. Captured stderr/env dumps from those runners always pass through `rag_obs.sh::redact_secrets` before landing in logs or state files.
- **The agent's bin directory never reaches root (045):** plugins install their launchers under `/home/agent/.local/bin`, inside `.state/` and writable by `agent` (claude-mem 15.x calls its own by name, without a shell). The image `ENV PATH` stays without it, so tini, the entrypoint, the crontab sync loop, `crond` and a default `docker exec -u root` never see it. The claude sessions the product starts (`start_session` and its respawns, and the heartbeat tick) get it appended at the **end** of their PATH by `docker/scripts/lib/agent_path.sh`, passed as a `PATH=` prefix on the `tmux new-session` client: tmux gives a new pane the PATH of the client that creates it and ignores `new-session -e PATH=`. `agentctl mcp` gets the same PATH. A manual `docker exec -u agent`, `agentctl run` or `agentctl shell` keeps the image PATH. Add the directory inside the container, not on the host (where `$PATH` and `$HOME` would expand to the host's): `docker exec -u agent <agent> sh -c 'PATH="$PATH:$HOME/.local/bin" exec <cmd>'`, or `PATH="$PATH:$HOME/.local/bin"` typed inside `agentctl shell`.
- **Backup credential scripts (046):** `docker/scripts/git-askpass-agent.sh` (the backups' `GIT_ASKPASS`) and `docker/scripts/git-credential-agent.sh` (the work clone's credential helper) are POSIX `sh`, image-baked at `/opt/agent-admin/scripts/` with their own `COPY` lines, and read-only at runtime. git invokes them as the user running git, and every launcher path that does runs as `agent`: the backup units under `heartbeatctl` (cron dispatches as `agent`, `agentctl` passes `-u agent`), the supervisor's work-clone helper, and the agent's own session pushing from its clone. The launcher never runs them as root. They read `GITHUB_PAT` from the environment, print only the git credential answer (`x-access-token` and the token) and write nothing to stderr or to any file. The helper is configured per server (`credential.https://github.com.helper` in the clone's own config), so git consults it for the agent's repository host only. 046 adds no capability, no mount, no port and no root `docker exec`: `agentctl doctor` reads the backup status with `docker exec -u agent`, and the compose privilege set (`cap_drop: ALL` + `CHOWN`, `SETUID`, `SETGID`, `no-new-privileges`) is unchanged.
- **No Docker socket:** Container cannot access `/var/run/docker.sock` or manage the host's Docker.
- **No inbound ports:** Telegram is outbound-only (polling). No services listen on exposed ports.

## Heartbeat Pipeline

The heartbeat is a single scheduled task per agent. `/etc/crontabs/agent`
is rendered by `heartbeatctl reload` from `agent.yml`. Busybox crond
runs as root (launched from entrypoint) so it can `setgid(agent)` when
dispatching the job; `heartbeat.sh` runs as `agent`.

    /etc/crontabs/agent (busybox user crontab, no user field)
         │  every N min
         ▼
    heartbeat.sh (as agent)
      ├─ gen_run_id  →  20260419013000-a3f2
      ├─ tmux new -d -s <agent>-hb-<run_id>  "claude --print <prompt>"
      ├─ wait until HEARTBEAT_DONE or timeout
      ├─ notifiers/<channel>.sh <run_id> <status> → JSON envelope
      ├─ append_run_line   → logs/runs.jsonl
      ├─ write_state_json  → state.json (atomic)
      └─ rotate_runs_jsonl → gz rotation at 10MB

Inspection and mutation go through a single CLI — see
[`docs/heartbeatctl.md`](heartbeatctl.md) for the full reference.

```bash
docker exec -u agent <agent> heartbeatctl status   # dashboard
docker exec -u agent <agent> heartbeatctl logs     # tail runs.jsonl
docker exec -u agent <agent> heartbeatctl set-interval 5m
```

`agent.yml` is the single source of truth. Every mutation backs up to
`agent.yml.prev`, applies via `yq -i`, then regenerates derived files;
any failure restores the backup and re-runs `reload` against the prior
state. `heartbeatctl reload` writes the staging crontab; the
root-privileged sync loop in `entrypoint.sh` installs it into
`/etc/crontabs/` (busybox crond refuses non-root-owned crontabs).

Data files (all under `/workspace/scripts/heartbeat/`; thresholds as of v0.12.0):
- `heartbeat.conf` — shell-sourced by heartbeat.sh; regenerated by reload.
- `state.json` — atomic snapshot of last run + counters. Schema 1.
- `logs/runs.jsonl` — one JSON object per run, rotated at 10MB → `.1`,
  `.2.gz`, `.3.gz` (max 3 generations).
- `logs/cron.log` — crond stderr for schedule-dispatch debugging.
- `logs/sessions/` — per-run tmux session logs (last 20 kept).

## Vault layer (Karpathy LLM Wiki, opt-in)

Each agent can carry a per-agent file-based knowledge base structured around Andrej Karpathy's "LLM Wiki" pattern (https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f). The vault is the third memory layer next to auto-memoria and claude-mem; it serves curated, synthetic, compounding knowledge derived from external sources.

Three layers (verbatim from Karpathy's gist):
- `raw_sources/` — immutable source documents (LLM reads, never edits).
- `wiki/` — LLM-owned generated pages, six type subdirectories: `summaries/`, `entities/`, `concepts/`, `comparisons/`, `overviews/`, `synthesis/`.
- `CLAUDE.md` (vault-local) — the schema document defining frontmatter spec, wikilink format, and ingest/query/lint protocols.

Plus two root files: `index.md` (content-oriented catalog) and `log.md` (chronological append-only).

Storage and lifecycle:

```
HOST: <workspace>/.state/.vault/  ─ bind-mount ─→  CONTAINER: /home/agent/.vault/
                                                              /home/agent/vault/ (symlink)
```

The vault inherits the existing `.state/` bind-mount. No new Docker volume. Persists across `docker compose restart` and `setup.sh --uninstall --yes`. Removed only by `--purge` or `--nuke`.

Boot sequence (docker mode — image-baked, runs as `agent` user during `boot_side_effects` in `start_services.sh`; local mode seeds host-side at scaffold, see the local-mode paragraph below):

```text
seed_vault_if_needed()
  ├─ read agent.yml.vault.{enabled, path, seed_skeleton}
  ├─ resolve in-container path under /home/agent/
  ├─ vault_ensure_paths       (mkdir -p, idempotent)
  ├─ vault_seed_if_empty      (cp -R skeleton + sed SCAFFOLD_DATE; no-op if dir non-empty)
  └─ ln -sfn /home/agent/.vault /home/agent/vault   (convenience alias)
```

When `agent.yml.vault.mcp.enabled` is true, the `mcp-json.tpl` renderer adds a `vault` MCP server entry running `npx -y @bitbonsai/mcpvault@0.12.0` (pinned, as of v0.12.0) against the mode-resolved vault path (`{{VAULT_MCP_PATH}}`: `/home/agent/.vault` in docker mode, the workspace's `.state`-relative path in local mode). MCPVault is zero-dependency, accesses files directly (no Obsidian app required), and exposes 14 tools for note read/write/search/move/frontmatter operations.

For larger vaults, an optional second MCP server can be enabled via `agent.yml.vault.qmd.enabled` — this registers QMD (`@tobilu/qmd`, pinned via `vault.qmd.version`, default `2.5.3` as of v0.12.0 — installed into and run from a managed bun prefix, never `bunx`; see the QMD execution model paragraph below), a local hybrid-search engine with BM25 + vector + LLM-rerank combined via Reciprocal Rank Fusion. QMD downloads a ~300 MB embedding model on first use, so it is off by default. Both servers can run concurrently and are complementary: MCPVault for read/write/list operations on individual notes, QMD for retrieval-style search across the corpus.

Since `010-self-managing-rag`, QMD is **self-managing** when enabled (zero manual steps). In docker mode, `qmd_setup_if_needed` (in `scripts/lib/qmd_index.sh` — host-canonical since 012, mirrored into the workspace's `docker/` build context at scaffold and baked at `/opt/agent-admin/scripts/lib/` in the image) runs at first boot: `collection add` + `update` + `embed` in the background — timeout-bounded so the watchdog is never blocked, idempotent via a sentinel + `index.sqlite`. The model and index live under the qmd cache root (docker mode: `/home/agent/.cache/qmd/`, i.e. durable in `.state`; local mode: `<workspace>/.state/.cache/qmd`) — the derived index is regenerable, so it is intentionally NOT backed up to `backup/vault`. Freshness is kept by a **dual trigger**: an inotify watcher (`scripts/qmd_watch.sh`, same mirroring, ~15 s debounce) fires immediately on any vault change — including Syncthing-pushed edits — and a schedule backstop (`vault.qmd.schedule`, default `*/5 * * * *` as of v0.12.0 — a crontab line calling `heartbeatctl qmd-reindex` in docker mode, a systemd timer in local mode) catches anything the watcher missed. Both route through one `flock`-guarded, hash-debounced `qmd_reindex`, so concurrent triggers never overlap; an unchanged vault skips the costly embed **only when it is also fully embedded** (`pending == 0` in `qmd-index.json`) — with embeddings pending, or an unknown/pre-018 state, the guard resumes the 018 embed loop without re-running `update`. The version pin stays single-sourced in `agent.yml` (`vault.qmd.version`) but is resolved at runtime by the lib's `qmd_pkg()`; since 016 the `.mcp.json` entry no longer embeds the version — it points at the qmd-mcp wrapper (see below).

**Local mode (`012-local-vault-rag`).** In local (systemd) mode there is no container boot and no `/home/agent` bind-mount, so the paths and lifecycle differ while the behavior matches. The vault resolves to `<workspace>/<vault.path>` (default `.state/.vault`) directly — no rebase — and `setup.sh` seeds the skeleton host-side at scaffold/regenerate (the same `vault.sh` lib the container uses at boot). The vault + qmd MCP args are mode-resolved (`VAULT_MCP_PATH`, `.state`-relative). QMD's index lives under `<workspace>/.state/.cache/qmd` (workspace-durable, still never backed up). The dual trigger becomes systemd units: `agent-<name>-qmd-reindex.{service,timer}` (schedule converted from cron to `OnCalendar`) and `agent-<name>-qmd-watch.service` (`Restart=always`, gated by `ExecCondition=command -v inotifywait` so a host without inotify-tools stays inactive rather than restart-looping — the timer is the backstop). First-run setup is dispatched by `--login` in the background and self-heals via a `setup-if-needed` guard on every timer tick. Vault backup runs as `agent-<name>-vault-backup.{service,timer}` over the same `backup_vault.sh` (needs a configured fork). The reindex/backup libs are relocated to `scripts/lib/` (host-canonical, mirrored into `docker/`); `agentctl status`/`doctor` report the units + index/backup freshness.

**Local RAG parity (`013-local-rag-parity`).** 012 *rendered* the local pipeline but its mclaren gate never ran; a parity audit found the chain broken and 013 fixes it. The load-bearing correction is the **storage env contract**: the qmd binary honors `XDG_CACHE_HOME` (index+models) and `QMD_CONFIG_DIR` (collections registry, isolated per workspace) — **not** `QMD_CACHE_HOME`, which only the bash lib reads for its own bookkeeping. So local mode exports all three from `local-qmd-reindex.sh.tpl` (they converge on `<workspace>/.state/.cache/qmd`) **and** pins the same `XDG_CACHE_HOME`/`QMD_CONFIG_DIR` into the qmd MCP's `env` in `.mcp.json` via a precomputed `QMD_MCP_ENV` (docker renders `{}`, byte-identical) — the writer and reader are an atomic pair, because fixing one without the other leaves the MCP reading a silently empty auto-created sqlite. The three local units also inherit systemd's minimal PATH, which excludes the bootstrap's `~/.local/bin` (bunx) and the vendored yq, so each wrapper self-provides PATH as its first action; the watcher additionally gets the real vault dir and runs a supervised loop so a transient exit never strands the unit at its start-limit. Operationally, the kill switch stops every unit, `doctor` degrades honestly (exit 0/1/2 on reindex error, backup staleness, or a failed watcher), `agentctl heartbeat qmd-reindex|backup-vault` invoke the local entrypoints, and a non-convertible cron schedule persists a `qmd-schedule.fallback` marker. Docker gained two audited fixes under the DOCKER_E2E gate: a `flock` around `qmd_setup_if_needed`, and the `bunx` symlink the image was missing (QMD in docker had never run against real binaries — the e2e stub hid it). That `bunx` symlink still ships in the image, but **qmd no longer uses it**: 016 moved every qmd invocation (batch and MCP) to the managed prefix described below.

**Wiki-graph (`014-wiki-graph-rag`).** The vault skeleton already implements Karpathy's three layers, but nothing parsed the `[[wikilink]]` graph, the lint was 100% manual/agentic, and terminology drift (`SENCOSUD`→`Cencosud`) grew silently. 014 adds a **deterministic graph + structural lint** derived from the whole wiki without an LLM: the mirrored lib `scripts/lib/wiki_graph.sh` runs awk per file (the strict frontmatter-subset parser IS the validator — unparseable input becomes a `frontmatter_violation`) and jq to aggregate globally into `<vault>/.graph/{graph,backlinks,findings,policy,packets}.json`. Those are JSON-only by contract, so the backup's `*.md` filter and the qmd mask exclude them by construction; the state file `wiki-graph.json` and the `flock` live OUTSIDE the vault (Syncthing must not see them). A new `wiki/normalization/` layer declares canonical forms + aliases (its own frontmatter, outside the six knowledge types); the schema's ingest step normalizes terminology and its query step pulls 1-hop graph neighbors from `backlinks.json`. Scheduling is mode-agnostic — a docker crontab line (`heartbeatctl wiki-graph`) and a local systemd wrapper+unit+timer built with every 013 lesson from the start (PATH first, vault env, fail-silent with honest doctor); `local_schedule.sh` gained the `M */N` cron form for the `20 */6` default. Ops parity mirrors 013: kill switch stops the timer, healthcheck WARNs on a failed unit, `agentctl status` shows freshness + counts, `agentctl doctor` degrades (WARN on integrity findings or error, FAIL on a dead runner; orphans/stale/alias only inform) with exit codes 0/1/2. Existing vaults upgrade additively via `vault_seed_missing` — it adds only new structures, never overwrites, never touches the vault's co-evolved `CLAUDE.md`, and gates the schema delta on a HIDDEN `.applied` marker (not the deletable delta doc) so the docker boot hook never re-deposits it.

**QMD execution model (`015`–`018`, as of v0.12.0).** Four features harden how the qmd engine is installed and run; the mechanics live in the mirrored lib `scripts/lib/qmd_index.sh`:

- **Observability + host-backed scratch (015).** `scripts/lib/rag_obs.sh` (mirrored into the image like the other RAG libs) provides `redact_secrets` and `scratch_dir`; both RAG runners export `TMPDIR` to a host disk-backed bind-mount (docker mode: instead of the 100 MB `/tmp` tmpfs — see [Security](#security)), each under its own root — qmd under its cache root (`$HOME/.cache/qmd/tmp` in docker, `<workspace>/.state/.cache/qmd/tmp` in local) for bun installs, model downloads and native builds; wiki-graph under its state dir (`<workspace>/scripts/heartbeat/tmp`), where its awk/jq intermediates land (it runs no bun install, downloads no model, builds nothing native). Both runners also capture the engine's real stderr + effective env into logs/state files, always redacted first.
- **Managed bun prefix, not `bunx` (016).** `_qmd_ensure_prefix` installs the pinned `@tobilu/qmd` into `<qmd cache root>/pkg` from a fixed manifest whose `trustedDependencies` lists only `better-sqlite3` and `node-llama-cpp` — bun's default-deny leaves `tree-sitter-*` unbuilt (qmd uses the web-tree-sitter WASM grammar at runtime). This is the root-cause fix for qmd failing on Alpine musl: `bunx` ran every dependency's install script, and tree-sitter's node-gyp aborted the whole install. The install is hash-guarded via a `.installed-hash` sentinel; node-llama-cpp compiles from source with portable-ARM cmake options (`GGML_NATIVE=OFF`, `armv8-a`). Both the batch runner (`_qmd_run`, timeout-bounded) and the MCP server (`qmd_mcp_exec`, no timeout) execute from this same prefix.
- **Docker mode — native toolchain + bigstack (016).** The image bakes `build-base cmake linux-headers libgomp`, gated by build-arg `QMD_NATIVE_TOOLCHAIN=1` (a `=0` build is the DOCKER_E2E RED probe), and compiles `bigstack.so` (`docker/bigstack.c`) — an `LD_PRELOAD` pthread shim that grows musl's 128 KB default thread stacks to 8 MB, against the `std::regex` recursion SIGSEGV in the embed path. The shim is scoped to `qmd embed` and the MCP server only, never global.
- **Docker mode — musl sqlite-vec (017).** sqlite-vec ships glibc-only prebuilts (`vec0.so`, one package per architecture: `sqlite-vec-linux-x64` and `sqlite-vec-linux-arm64`) that cannot `dlopen` under musl. `docker/scripts/build-sqlite-vec.sh` compiles the official amalgamation (v0.1.9 as of v0.12.0, same build-arg gate) and bakes it at `/opt/agent-admin/sqlite-vec/vec0.so`; `_qmd_swap_sqlite_vec` swaps it into the prefix on every ensure, onto the package that matches the machine (`uname -m`: `x86_64` selects `sqlite-vec-linux-x64`, `aarch64` selects `sqlite-vec-linux-arm64`; 042) — musl-gated, `cmp`-idempotent, a no-op on glibc (local mode), and fail-silent: when the artifact is absent, the package of this architecture is missing or the architecture is not supported it logs one line saying why (lexical index keeps working, only vector embed degrades).
- **Embed completion loop (018).** The qmd engine caps each embed session (a hardcoded ~30-min LLM-session ceiling, not env-configurable), so a single pass cannot embed a large first-time corpus. `_qmd_embed_until_complete` runs successive fresh `qmd embed` passes inside one locked reindex until qmd reports full coverage (`Pending: 0` / "All content hashes already have embeddings"), a pass stops making forward progress (`last_status: stalled`), or the fixed anti-runaway cap `QMD_EMBED_MAX_PASSES` (12 as of v0.12.0; env-overridable for tests only, deliberately not an `agent.yml` field) is hit (`last_status: partial`). The state file `qmd-index.json` persists the `pending` count that drives the resumable unchanged-vault guard above; an absent `pending` (pre-018 state) reads as *unknown* and forces a resume, never as zero. The loop wraps the engine — it never patches qmd itself. Contract: [`specs/018-qmd-embed-completion/contracts/embed-completion.md`](../specs/018-qmd-embed-completion/contracts/embed-completion.md).
- **MCP server wrappers (016).** The `.mcp.json` qmd entry renders `{{QMD_MCP_COMMAND}}` per mode — docker: `/opt/agent-admin/scripts/qmd-mcp` (image-baked); local: the workspace's `scripts/local/agent-qmd-mcp.sh` (rendered from `modules/local-qmd-mcp.sh.tpl`, written as an absolute path). Both exec the long-running stdio server via `qmd_mcp_exec` from the managed prefix, with the same storage env as the reindex writer (`QMD_MCP_ENV`), so the MCP reader and the index writer share one installation. The entry carries `args: []` — the version pin is resolved inside the wrapper by `qmd_pkg()`, not embedded in `.mcp.json`.

Test seam (contributor-facing, test-only — no runtime behavior): host tests stub the engine via `tests/helper.bash::install_qmd_stub{,_fail}`, which plant a fake `qmd` inside the managed prefix with a pre-seeded `.installed-hash` and the 018 completion signal, exercising the real `_qmd_run`/`_qmd_ensure_prefix` skip path. Contract: [`specs/019-fix-qmd-test-drift/contracts/qmd-test-seam.md`](../specs/019-fix-qmd-test-drift/contracts/qmd-test-seam.md).

Coexistence rule: auto-memoria for atomic facts about the user/project; claude-mem for passive transcript observations; vault for curated synthetic knowledge from external sources. Don't double-write across layers.

Full feature documentation: [`docs/vault.md`](vault.md). Authoritative schema for vault conventions: `modules/vault-skeleton/CLAUDE.md` in this repo (copied into each agent's vault at first boot).

## See Also

- [Docker Mode User Guide](getting-started.md) — how to scaffold, boot, upgrade, and troubleshoot.
- [State Layout](state-layout.md) — every persistent file mapped to its host and container path (memory, OAuth, plugin cache, Telegram channel state, heartbeat artifacts).
- [Vault feature reference](vault.md) — Karpathy LLM Wiki pattern, lifecycle, operations, troubleshooting.
- [Adding an MCP (Docker)](adding-an-mcp.md) — extending the agent with custom MCPs in Docker mode.
- Historical design specs: [heartbeat observability CLI](superpowers/specs/2026-04-19-heartbeat-observability-cli-design.md), [identity backup](superpowers/specs/2026-04-22-identity-backup-design.md).
