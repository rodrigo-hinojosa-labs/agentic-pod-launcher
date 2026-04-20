# Heartbeat: observability + CLI (design spec)

**Status:** approved design, pending implementation plan
**Date:** 2026-04-19
**Scope:** `agentic-pod-launcher` base repo only. No runtime migration of existing containers — users do a clean scaffold from the updated launcher.

## Context

The current heartbeat pipeline ships but does not work:

1. `HEARTBEAT_INTERVAL` from `agent.yml` never reaches cron. `docker/entrypoint.sh` falls back to a hard-coded `*/30 * * * *` regardless of user choice.
2. `docker/crontab.tpl` renders a user field (`agent`) inside `/etc/crontabs/agent`, a busybox **user crontab** where the user is already implicit. Busybox interprets the token as the command's argv[0] and tries to exec a binary called `agent`. No run has ever succeeded; `scripts/heartbeat/logs/` stays absent because `heartbeat.sh` never executes.
3. `crond` is launched from `start_services.sh` after `su-exec agent`, i.e. as uid=agent. Its `setgroups()` on job dispatch fails (`Operation not permitted`), producing permanent warnings and blocking clean privilege drops for cron-launched jobs.
4. Agents scaffolded from pre-import versions of the template ship a `scripts/heartbeat/launch.sh` that is host-mode dead weight (systemd/launchd). It cannot run on Alpine — any `./launch.sh install` fails. This repo no longer ships `launch.sh`, but scaffolded agents from before the Docker-only import still carry it; the new CLI should fully supplant its role.
5. Tracing is scattered across three file formats (`heartbeat-history.log` pipe-delimited, `cron.log` stderr, `claude.cron.log` crond's own log) with no correlation id and no machine-readable state snapshot.

The system supports a **single heartbeat per agent** — multiple scheduled tasks are an explicit non-goal.

## Goals

- Fix the 4 blocking bugs (interval propagation, crontab format, crond privileges, dead weight `launch.sh`).
- Introduce a structured trace (`runs.jsonl`) and a live state snapshot (`state.json`) that the agent can read with a single `jq` call.
- Ship a single CLI (`heartbeatctl`) that exposes read, control, and mutation commands. Mutations write back to `agent.yml` (source of truth) with atomic rollback.
- Entire trace pipeline must survive container restarts (bind-mounted) and be rotated (bounded disk usage).

## Non-goals

- Multiple scheduled tasks per agent.
- Migration of already-deployed agents. Users will re-scaffold.
- Sub-minute intervals (busybox cron resolution is 1 minute; `< 1m` is rejected by the validator).
- Distributed tracing / OpenTelemetry / journald integration.
- A web UI or HTTP endpoint for status.

## Architecture

```
HOST agent.yml (source of truth, user-owned)
  └─► ./setup.sh render → modules/heartbeat-conf.tpl
                       → modules/docker-compose.yml.tpl
                       (cron expression is NOT baked here)

IMAGE (baked, read-only)                WORKSPACE (bind mount, agent-owned)
/opt/agent-admin/                       /workspace/
  ├─ entrypoint.sh  (root, then su-exec)  ├─ agent.yml                ← mutated by heartbeatctl
  ├─ crontab.tpl                          ├─ .env
  └─ scripts/                             └─ scripts/heartbeat/
      ├─ start_services.sh                     ├─ heartbeat.sh          ← runner, emits runs.jsonl + state.json
      └─ heartbeatctl     ── symlink ──►       ├─ heartbeat.conf        ← derived from agent.yml
/usr/local/bin/heartbeatctl                    ├─ notifiers/{none,log,telegram}.sh
                                               ├─ state.json            ← atomic snapshot (last run + counters)
                                               └─ logs/
                                                   ├─ runs.jsonl        ← rotated at 10MB → .1.gz, .2.gz, .3.gz
                                                   └─ cron.log          ← crond stderr (debug of schedule only)
```

### Reparto

- **Image-owned, stable**: `entrypoint.sh`, `start_services.sh`, `crontab.tpl`, `heartbeatctl`. Updated via image rebuild. No agent-specific state inside.
- **Workspace-owned, mutable**: `agent.yml`, `heartbeat.conf`, `state.json`, `runs.jsonl`, `cron.log`. All owned by `agent:agent` UID/GID.
- **Single source of truth**: `agent.yml`. Every mutation (CLI `set-*`, `pause`, `resume`) writes there first via `yq -i` under a transactional wrapper. `heartbeat.conf` and `/etc/crontabs/agent` are derived.

### Privilege model

`entrypoint.sh` runs as root briefly to:
1. Chown `/home/agent` (existing).
2. Chown `/workspace/scripts/heartbeat` (new — first-boot only, idempotent).
3. Render `/etc/crontabs/agent` from template (no user field).
4. Launch `crond -b -L /workspace/claude.cron.log` **as root**, so `setgid(agent)` on job dispatch succeeds.
5. `su-exec agent /opt/agent-admin/scripts/start_services.sh` — supervisor runs as `agent`, which in turn runs `heartbeatctl reload` + tmux watchdog.

`heartbeat.sh` itself always runs as `agent` (crond sets it via `/etc/crontabs/agent` owner + busybox behavior).

## Data contracts

### `runs.jsonl`

One JSON object per line, append-only. Written by `heartbeat.sh` at end-of-run (single atomic line via `>>` flush).

```json
{
  "ts": "2026-04-19T01:30:00Z",
  "run_id": "20260419013000-a3f2",
  "trigger": "cron",
  "status": "ok",
  "attempt": 1,
  "duration_ms": 12480,
  "claude_exit_code": 0,
  "prompt": "Check status and report",
  "tmux_session": "<agent>-hb-a3f2",
  "notifier": {
    "channel": "telegram",
    "ok": true,
    "latency_ms": 230,
    "error": null
  }
}
```

- `ts` — ISO8601 UTC, always Z-suffixed.
- `run_id` — `YYYYMMDDHHMMSS-<4 hex>`. Uniqueness is per-second; `<4 hex>` comes from `$RANDOM` and gives ~1-in-65k collision protection within the same second.
- `trigger` — `cron` | `manual` (latter from `heartbeatctl test`).
- `status` — `ok` | `timeout` | `error` | `skipped`. `skipped` is reserved for the case where a previous run is still in flight (tmux session with the reserved name exists).
- `attempt` — 1-based, reflects the final (last) attempt after retries; earlier attempts are not persisted as separate lines.
- `duration_ms` — total wall time of the final attempt in milliseconds.
- `claude_exit_code` — integer; `-1` if killed by timeout.
- `prompt` — full prompt as executed (truncation happens only in `state.json` pretty views, not here).
- `notifier` — output of the notifier driver (see contract below); `{"channel":"none","ok":true,"latency_ms":0,"error":null}` when the channel is `none`.

### `state.json`

Atomic snapshot of the last run + aggregates. Rewritten at the end of every run via write-to-temp + `mv`. Never read mid-write.

```json
{
  "schema": 1,
  "enabled": true,
  "interval": "2m",
  "cron": "*/2 * * * *",
  "prompt": "Check status and report",
  "notifier_channel": "telegram",
  "last_run": { "...": "full object copied from runs.jsonl" },
  "counters": {
    "total_runs": 42,
    "ok": 40,
    "timeout": 1,
    "error": 1,
    "consecutive_failures": 0,
    "success_rate_24h": 0.98
  },
  "next_run_estimate": "2026-04-19T01:32:00Z",
  "crond": { "alive": true, "pid": 45 },
  "updated_at": "2026-04-19T01:30:12Z"
}
```

- `schema: 1` — integer. `heartbeatctl status` refuses to parse unknown schemas with a clear message.
- `enabled` — mirror of `agent.yml` `features.heartbeat.enabled`. `pause` sets false, `resume` sets true.
- `counters.success_rate_24h` — computed at run end by tailing `runs.jsonl` entries with `ts >= now - 24h`. Cheap (expect <1000 entries in that window).
- `next_run_estimate` — computed from `cron` + current time with a simple evaluator (no external `croniter`-style dep). Null if `enabled: false`.
- `crond.alive` — `pgrep -x crond` at status read time. Populated by `heartbeatctl status`, not by `heartbeat.sh`.
- `updated_at` — when the state file was last rewritten. Used by `heartbeatctl status` to flag stale state (if `ts(last_run) + 2×interval < now`, state is "stale — runner may have crashed").

### Notifier contract

Each `scripts/heartbeat/notifiers/<channel>.sh`:

- **Input:** stdin = message body (plain text); `$1` = `run_id`; `$2` = status (`ok`/`timeout`/`error`).
- **Output:** single-line JSON on stdout: `{"ok":true|false,"latency_ms":<int>,"error":null|"<string>"}`.
- **Exit:** always `0`. Failures are reported in-band in the JSON; never tumble the runner.

`heartbeat.sh` captures stdout and embeds it verbatim as the `notifier` field in the run record.

### Log rotation

At end of each run, if `stat -c %s runs.jsonl > 10485760`:
1. If `runs.jsonl.3.gz` exists: `rm`.
2. `[ -f runs.jsonl.2.gz ] && mv runs.jsonl.2.gz runs.jsonl.3.gz`
3. `[ -f runs.jsonl.1 ]    && gzip runs.jsonl.1 && mv runs.jsonl.1.gz runs.jsonl.2.gz`
4. `mv runs.jsonl runs.jsonl.1`
5. New `runs.jsonl` created on next run.

Ceiling: ~30MB uncompressed equivalent across four files.

## Bug fixes bundled in this change

| # | Current bug | Fix |
|---|---|---|
| 1 | `HEARTBEAT_INTERVAL` stuck at `*/30 * * * *` | `heartbeatctl reload` parses `HEARTBEAT_INTERVAL` (`30s` rejected, `2m` → `*/2 * * * *`, `1h` → `0 * * * *`, etc.) and writes `/etc/crontabs/agent`. Invoked by `entrypoint.sh` at boot — single code path shared with runtime mutations. |
| 2 | Crontab `user` field breaks command | `docker/crontab.tpl` drops the `agent` token: `${HEARTBEAT_CRON} /workspace/scripts/heartbeat/heartbeat.sh >> /workspace/scripts/heartbeat/logs/cron.log 2>&1`. User is implicit by filename. |
| 3 | `crond` as non-root can't `setgroups` | Move `crond -b` launch into `entrypoint.sh` (root-phase) before the `su-exec agent` handoff. `start_services.sh` no longer starts crond — just checks it's alive in its watchdog and restarts the container if it died (treat as fatal). |
| 4 | `launch.sh` scaffolded by legacy agents | This repo no longer ships `launch.sh`, so nothing to delete here. `heartbeatctl` is the replacement scaffolded by the current launcher; legacy agents drop it naturally when they re-scaffold against the updated launcher. |
| 5 | `/workspace/scripts/heartbeat/` root-owned on macOS hosts with matching UID=501 (benign) but wrong UID elsewhere | `entrypoint.sh` chowns `/workspace/scripts/heartbeat` to `agent:agent` in the root phase, before handoff. Idempotent. |
| 6 | `logs/` missing until first successful run | `heartbeatctl reload` creates `logs/` with 0755 `agent:agent` (mkdir -p is idempotent). |

## `heartbeatctl` command reference

Single bash script at `docker/scripts/heartbeatctl`, symlinked into image at `/usr/local/bin/heartbeatctl`.

### Read commands

```
heartbeatctl status [--json]
```
Pretty status (no flag) or raw `state.json` dump (`--json`). Pretty output includes: enabled flag, interval + derived cron, prompt (truncated to 120 chars with `…`), notifier channel, last run (status + ts + duration), counters, next run estimate, crond liveness, tail of last 5 `runs.jsonl` entries in a table.

```
heartbeatctl logs [-n N] [--json]
```
Tail of `runs.jsonl`. Default `N=20`. `--json` emits raw lines; without it, columns: `TS  STATUS  DUR  ATTEMPT  PROMPT[:60]`.

```
heartbeatctl show
```
Dumps verbatim: `heartbeat.conf`, `/etc/crontabs/agent`, and the `features.heartbeat` + `notifications` sections of `agent.yml`. For answering "what's actually installed right now".

### Control commands

```
heartbeatctl test [--prompt "..."]
```
Runs a synchronous heartbeat with `trigger=manual`. Writes a line to `runs.jsonl` and updates `state.json` like any other run, but does **not** touch `counters.consecutive_failures` (manual tests must not poison ok-streak metrics).

```
heartbeatctl pause
```
Sets `features.heartbeat.enabled=false` in `agent.yml`, comments the cron line in `/etc/crontabs/agent` (prefix `#`), `kill -HUP crond`. Idempotent.

```
heartbeatctl resume
```
Inverse. Refuses with clear message if `agent.yml` has `enabled=false` for another reason (invariant: `resume` only works against a `pause`-induced state; full reconfig flows through `reload`).

```
heartbeatctl reload
```
Re-reads `agent.yml`, regenerates `heartbeat.conf`, rewrites `/etc/crontabs/agent` via the interval→cron converter, `kill -HUP crond`, ensures `logs/` exists with correct permissions. Idempotent. Invoked by `entrypoint.sh` at every container boot.

### Mutation commands

```
heartbeatctl set-interval <value>
heartbeatctl set-prompt "<str>"        # also accepts multi-line via stdin when no arg
heartbeatctl set-notifier <none|log|telegram>
heartbeatctl set-timeout <seconds>
heartbeatctl set-retries <N>
```

All mutations follow a transactional wrapper:

```bash
_mutate() {
  cp agent.yml agent.yml.prev           # single pre-image
  yq -i "<expression>" agent.yml \
    && heartbeatctl reload \
    || { cp agent.yml.prev agent.yml; heartbeatctl reload; exit 1; }
  rm agent.yml.prev
}
```

Validation runs **before** the `yq -i` call:

- `set-interval`: regex `^[1-9][0-9]*[mh]$`. The `s` suffix is not accepted (busybox cron has 1-minute resolution). The numeric part must be in a fixed divisor table — anything else rejected with a message listing the accepted values. Raw cron strings are deferred to Future Work.
  - `Nm` where `N ∈ {1, 2, 3, 4, 5, 6, 10, 12, 15, 20, 30}` → `*/N * * * *`.
  - `Nh` where `N ∈ {1, 2, 3, 4, 6, 8, 12}` → `0 */N * * *`.
  - `24h` → `0 0 * * *` (special-cased, once per day at 00:00 UTC).
- `set-notifier`: membership in {`none`, `log`, `telegram`}. Choosing `telegram` without `NOTIFY_BOT_TOKEN` and `NOTIFY_CHAT_ID` in `.env` prints a stderr warning but does not refuse (user may be setting tokens next).
- `set-timeout`: integer ≥ 10.
- `set-retries`: integer 0..5.
- `set-prompt`: trimmed, length ≤ 4000.

### Help

```
heartbeatctl help | heartbeatctl | heartbeatctl --help
```
Prints command list grouped by {Read, Control, Mutate} with one-line descriptions.

## Lifecycle scenarios

### First boot of a freshly scaffolded agent

```
tini
 └─ /opt/agent-admin/entrypoint.sh (root)
     ├─ chown /home/agent          (existing)
     ├─ chown /workspace/scripts/heartbeat  (new, idempotent)
     ├─ envsubst crontab.tpl → /etc/crontabs/agent      (base line, */30 default)
     ├─ crond -b -L /workspace/claude.cron.log          (root; will setgid on dispatch)
     └─ su-exec agent /opt/agent-admin/scripts/start_services.sh
           ├─ heartbeatctl reload                        (derives real cron from agent.yml, creates logs/)
           └─ tmux + watchdog loop
```

### Runtime mutation (agent or human)

```
heartbeatctl set-interval 2m
  → backup agent.yml
  → yq -i '.features.heartbeat.interval = "2m"' agent.yml
  → heartbeatctl reload
      → regenerate heartbeat.conf from template
      → rewrite /etc/crontabs/agent
      → kill -HUP crond
  → unlink agent.yml.prev
  exit 0
```

Any failure rolls back `agent.yml`, re-runs `reload` against the prior config, exits non-zero with a concrete message. `state.json` is untouched because its `interval`/`cron` fields refresh on the next run.

### Runtime failure of a heartbeat

| Scenario | Detected by | Recorded as | Side effects |
|---|---|---|---|
| Timeout | `timeout <T> claude ...` returns 124 | `status:"timeout"`, `claude_exit_code:-1` | `consecutive_failures++`; notifier fires (errors bypass `NOTIFY_SUCCESS_EVERY`) |
| Claude exit ≠ 0 | Exit code captured post-command | `status:"error"`, `claude_exit_code:<N>` | Same as timeout |
| Retries exhausted | After `HEARTBEAT_RETRIES + 1` attempts | Single line with `attempt:N` = last attempt | Earlier attempts not persisted |
| `heartbeat.sh` killed mid-run | Missing `runs.jsonl` line for the `run_id` in tmux session name | `heartbeatctl status` shows "stale" when `ts(last_run) + 2×interval < now` | Warning in pretty output |
| Concurrent tick (previous run still alive) | `tmux has-session -t <name>-hb` non-empty | `status:"skipped"` line written | `consecutive_failures` unchanged |

### Container restart

State survives — `runs.jsonl`, `state.json`, `agent.yml` are on the workspace bind mount. `heartbeatctl reload` at entrypoint re-derives cron, so any `set-*` made before restart remains in force.

## File-level impact on the launcher repo

| Path | Action |
|---|---|
| `docker/crontab.tpl` | Drop `agent` user field. |
| `docker/entrypoint.sh` | Add `chown /workspace/scripts/heartbeat`; launch crond as root; call `su-exec agent heartbeatctl reload` before starting services. |
| `docker/scripts/start_services.sh` | Remove crond launch; add crond liveness check in watchdog (crond death → exit container). |
| `docker/scripts/heartbeatctl` | **New.** Single bash script with all subcommands. Symlinked into `/usr/local/bin/`. |
| `docker/Dockerfile` | `COPY` + `chmod +x` heartbeatctl; `RUN ln -s /opt/agent-admin/scripts/heartbeatctl /usr/local/bin/heartbeatctl`. |
| `scripts/heartbeat/heartbeat.sh` | Rewritten to emit `runs.jsonl` + `state.json` per the contract; `run_id` generation; notifier invocation per new contract; rotation. |
| `scripts/heartbeat/notifiers/{none,log,telegram}.sh` | Rewritten to emit JSON-per-contract on stdout; always exit 0. |
| `scripts/heartbeat/launch.sh` | Not present in this repo. No action. |
| `modules/heartbeat-conf.tpl` | Add any fields the CLI needs to read; keep the conf shape minimal (all state is in agent.yml + state.json). |
| `scripts/lib/render.sh` | No change expected; conversion logic lives in `heartbeatctl`, not the render engine. |
| `setup.sh` | Remove `launch.sh` scaffolding; add a scaffold-time sanity check that `agent.yml` has `features.heartbeat.interval` shape valid. |
| `tests/heartbeatctl.bats` | **New.** |
| `tests/interval-to-cron.bats` | **New.** |
| `tests/heartbeat-runs-jsonl.bats` | **New.** |
| `tests/docker-e2e-heartbeat.bats` | **New.** |
| `docs/architecture.md` | Update process tree + heartbeat section. |
| `CHANGELOG.md` | Entry for the change. |

## Test strategy

Bats suite (no new dependencies beyond the existing `bats-core + yq + jq + tmux`):

1. **`tests/interval-to-cron.bats`** — pure-function table tests for the converter. Valid cases: `1m` → `* * * * *`, `2m` → `*/2 * * * *`, `15m` → `*/15 * * * *`, `1h` → `0 * * * *`, `2h` → `0 */2 * * *`, `24h` → `0 0 * * *`. Invalid cases (non-zero exit): `30s`, `60s`, `45m`, `7m`, `5h`, `foo`, empty, `-2m`, `2M`.
2. **`tests/heartbeatctl.bats`** — fixture-based:
   - `status` against a pre-made `state.json` produces expected text.
   - `status --json` matches the fixture byte-for-byte.
   - `set-interval 2m` mutates `agent.yml` correctly and regenerates the crontab.
   - `set-interval 30s` rejects with exit 2 and leaves `agent.yml` untouched.
   - `pause` followed by `resume` is a no-op round-trip.
   - `set-prompt "..."` with `yq` failure path: simulate by pointing at read-only `agent.yml` and assert rollback.
3. **`tests/heartbeat-runs-jsonl.bats`** — stubs `claude` with a shell that echoes + exits 0/124/1, runs `heartbeat.sh`, asserts:
   - `runs.jsonl` has exactly one line with valid JSON matching schema.
   - `state.json` is atomically replaced (simulate SIGKILL mid-write and assert no partial file).
   - Rotation triggers at >10MB with a forged large `runs.jsonl`.
4. **`tests/docker-e2e-heartbeat.bats`** — end-to-end: scaffold a test agent with interval `1m`, `docker compose up -d`, wait 90s, assert `runs.jsonl` has an entry with `status:"ok"` and `trigger:"cron"`. Marked `@skip` when `DOCKER_E2E=0` for fast local runs.

**Gate for merge:** items 1-3 green; item 4 green or explicitly skipped with `DOCKER_E2E=0` and manually validated.

## Out of scope (future work)

- Raw cron expressions for intervals that don't fit `Nm` / `Nh` (e.g. `45m`, `2h30m`, `0 9,17 * * 1-5`).
- Multiple heartbeats per agent (explicit non-goal).
- Remote observability (Prometheus exporter, Grafana panel).
- `heartbeatctl tail -f` streaming mode.

## Open questions

None at time of writing. All decisions are locked by the brainstorming dialog that produced this spec.
