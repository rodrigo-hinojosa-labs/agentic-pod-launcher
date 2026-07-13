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
- **No bridge watchdog.** A previous attempt to detect "bun alive but MCP notifications dropped" via tmux pane scraping was reverted (see commit `ebfe35f`) because the false-positive rate killed sessions every ~2 minutes during normal use. Manual recovery is `heartbeatctl kick-channel`.

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

## Security

- **UID/GID matching:** Container user is created at build time with the host's UID/GID, preventing bind-mount permission issues.
- **Capabilities:** Container drops ALL capabilities and adds only `CHOWN`, `SETUID`, `SETGID` (for the initial entrypoint to chown the volume).
- **Read-only root:** Not currently enforced, but the image layer is read-only; only `/tmp` (tmpfs, 100 MB as of v0.12.0 — `docker-compose.yml.tpl`) and bind-mounts are writable.
- **Host-backed scratch for RAG (015):** the 100MB tmpfs is too small for qmd's bun installs, model downloads and native builds, so both RAG runners route `TMPDIR` to a disk-backed bind-mount via `scripts/lib/rag_obs.sh::scratch_dir` — qmd under its cache root (`<qmd cache root>/tmp`, i.e. `.state`), wiki-graph under the workspace's `scripts/heartbeat/tmp` for its awk/jq intermediates; the compose tmpfs itself is untouched. Captured stderr/env dumps from those runners always pass through `rag_obs.sh::redact_secrets` before landing in logs or state files.
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

**Wiki-graph (`014-wiki-graph-rag`).** The vault skeleton already implements Karpathy's three layers, but nothing parsed the `[[wikilink]]` graph, the lint was 100% manual/agentic, and terminology drift (`SENCOSUD`→`Cencosud`) grew silently. 014 adds a **deterministic graph + structural lint** derived from the whole wiki without an LLM: the mirrored lib `scripts/lib/wiki_graph.sh` runs awk per file (the strict frontmatter-subset parser IS the validator — unparseable input becomes a `frontmatter_violation`) and jq to aggregate globally into `<vault>/.graph/{graph,backlinks,findings}.json`. Those are JSON-only by contract, so the backup's `*.md` filter and the qmd mask exclude them by construction; the state file `wiki-graph.json` and the `flock` live OUTSIDE the vault (Syncthing must not see them). A new `wiki/normalization/` layer declares canonical forms + aliases (its own frontmatter, outside the six knowledge types); the schema's ingest step normalizes terminology and its query step pulls 1-hop graph neighbors from `backlinks.json`. Scheduling is mode-agnostic — a docker crontab line (`heartbeatctl wiki-graph`) and a local systemd wrapper+unit+timer built with every 013 lesson from the start (PATH first, vault env, fail-silent with honest doctor); `local_schedule.sh` gained the `M */N` cron form for the `20 */6` default. Ops parity mirrors 013: kill switch stops the timer, healthcheck WARNs on a failed unit, `agentctl status` shows freshness + counts, `agentctl doctor` degrades (WARN on integrity findings or error, FAIL on a dead runner; orphans/stale/alias only inform) with exit codes 0/1/2. Existing vaults upgrade additively via `vault_seed_missing` — it adds only new structures, never overwrites, never touches the vault's co-evolved `CLAUDE.md`, and gates the schema delta on a HIDDEN `.applied` marker (not the deletable delta doc) so the docker boot hook never re-deposits it.

**QMD execution model (`015`–`018`, as of v0.12.0).** Four features harden how the qmd engine is installed and run; the mechanics live in the mirrored lib `scripts/lib/qmd_index.sh`:

- **Observability + host-backed scratch (015).** `scripts/lib/rag_obs.sh` (mirrored into the image like the other RAG libs) provides `redact_secrets` and `scratch_dir`; both RAG runners export `TMPDIR` to a host disk-backed bind-mount (docker mode: instead of the 100 MB `/tmp` tmpfs — see [Security](#security)), each under its own root — qmd under its cache root (`$HOME/.cache/qmd/tmp` in docker, `<workspace>/.state/.cache/qmd/tmp` in local) for bun installs, model downloads and native builds; wiki-graph under its state dir (`<workspace>/scripts/heartbeat/tmp`), where its awk/jq intermediates land (it runs no bun install, downloads no model, builds nothing native). Both runners also capture the engine's real stderr + effective env into logs/state files, always redacted first.
- **Managed bun prefix, not `bunx` (016).** `_qmd_ensure_prefix` installs the pinned `@tobilu/qmd` into `<qmd cache root>/pkg` from a fixed manifest whose `trustedDependencies` lists only `better-sqlite3` and `node-llama-cpp` — bun's default-deny leaves `tree-sitter-*` unbuilt (qmd uses the web-tree-sitter WASM grammar at runtime). This is the root-cause fix for qmd failing on Alpine musl: `bunx` ran every dependency's install script, and tree-sitter's node-gyp aborted the whole install. The install is hash-guarded via a `.installed-hash` sentinel; node-llama-cpp compiles from source with portable-ARM cmake options (`GGML_NATIVE=OFF`, `armv8-a`). Both the batch runner (`_qmd_run`, timeout-bounded) and the MCP server (`qmd_mcp_exec`, no timeout) execute from this same prefix.
- **Docker mode — native toolchain + bigstack (016).** The image bakes `build-base cmake linux-headers libgomp`, gated by build-arg `QMD_NATIVE_TOOLCHAIN=1` (a `=0` build is the DOCKER_E2E RED probe), and compiles `bigstack.so` (`docker/bigstack.c`) — an `LD_PRELOAD` pthread shim that grows musl's 128 KB default thread stacks to 8 MB, against the `std::regex` recursion SIGSEGV in the embed path. The shim is scoped to `qmd embed` and the MCP server only, never global.
- **Docker mode — musl sqlite-vec (017).** sqlite-vec ships a glibc-only prebuilt (`vec0.so`) that cannot `dlopen` under musl. `docker/scripts/build-sqlite-vec.sh` compiles the official amalgamation (v0.1.9 as of v0.12.0, same build-arg gate) and bakes it at `/opt/agent-admin/sqlite-vec/vec0.so`; `_qmd_swap_sqlite_vec` swaps it into the prefix on every ensure — musl-gated, `cmp`-idempotent, a no-op on glibc (local mode), and fail-silent when the artifact is absent (lexical index keeps working, only vector embed degrades).
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
