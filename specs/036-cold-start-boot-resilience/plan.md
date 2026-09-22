# Implementation Plan: Cold-start boot resilience + honest patch diagnostics

**Branch**: `036-cold-start-boot-resilience` (own branch, own PR — operator decision 2026-09-19, revising the 2026-09-18 shared-branch decision) | **Date**: 2026-09-18 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/036-cold-start-boot-resilience/spec.md`

## Summary

Four fixes, all found by the live gate of 034 and none caused by it. The load-bearing one is
structural: uv's state is split across two directories with different lifecycles, so every image
rebuild leaves dangling executable links that make `uv tool install` fail instantly — silently
defeating feature 030's pre-warm and, on a 15-MCP agent, pushing Claude Code's initialisation past
the channel watchdog's window until the container restart-loops. Alongside it: the channel window
becomes real configuration instead of a hand-edited env var, the initial boot retries instead of
killing the container on the first miss, and `agentctl doctor` stops reporting false patch failures
by consuming the patcher's own marker list rather than stale copies of it.

## Technical Context

**Language/Version**: bash (3.2.57 and 5.x, both gated), Python 3 (the plugin patcher), YAML templates

**Primary Dependencies**: `uv` 0.11.22 (pinned, `docker/Dockerfile:89`), `yq` v4, `jq`, docker compose, bats-core

**Storage**: `agent.yml` (source of truth), rendered `docker-compose.yml`, `.state/` bind-mount at `/home/agent`

**Testing**: `bats tests/` on the host (no daemon) + `DOCKER_E2E=1` tier, run for real on this host

**Target Platform**: Alpine 3.24 containers on Linux/arm64 (ferrari); launcher runs on macOS/Linux hosts

**Project Type**: CLI/scaffolding tool with image-baked runtime code

**Performance Goals**: an agent with 15 MCP servers reaches `channel plugin healthy` on the first boot after a rebuild, with the default window and no override

**Constraints**: no new container capabilities (Principle II); no automated stuck-channel detection (`ebfe35f`); fail-soft boot steps (Principle IV); every change survives `--regenerate` (Principle I)

**Scale/Scope**: 4 user stories, 5 runtime files + 2 templates + 2 docs, ~4 test files touched

## Constitution Check

| Principle | Verdict | Note |
| --- | --- | --- |
| I. Single Source of Truth (agent.yml) | **PASS — improves it** | US2 moves an operator knob out of a hand-edited `.env` into `agent.yml` with a rendered delivery path. The migration warning (FR-008) exists so the move is not silent. |
| II. Least-Privilege Container | **PASS** | No new capabilities, mounts or sockets. `UV_TOOL_BIN_DIR` is one env var inside the image, with no `PATH` change; the link pruning runs as `agent` over the agent's own `~/.local/bin`. |
| III. Test-First, Host-Runnable | **PASS** | Every story has host bats coverage using existing seams (`MCP_WARM_STUB_RC`, `_stub_pgrep_after`, the docker shim mould). DOCKER_E2E is additive and gated. |
| IV. Idempotent, Fail-Silent Lifecycle | **PASS** | The warm stays fail-soft and idempotent; the link pruner is a no-op when there is nothing stale; the boot retry still ends in a non-zero exit so Docker's escalation is intact. |
| V. Workspace-Is-the-Agent | **PASS — strengthens it** | D1's rejected alternative (moving uv's tool prefix into `.state/`) would have put a large package tree inside the backup unit. Instead the feature removes launcher-owned build state *from* the bind-mount by pruning dangling links. |
| VI. Reproducible, Pinned Dependencies | **PASS** | No version changes. `UV_VERSION` stays pinned; no new duplicate pins. CHANGELOG entry required. |

**Complexity Tracking**: empty. No principle is violated and no exception is requested.

## Project Structure

### Documentation (this feature)

```text
specs/036-cold-start-boot-resilience/
├── spec.md
├── plan.md              # this file
├── research.md          # Phase 0, with the live measurements
├── field-evidence.md    # raw incident data from the 2026-09-18 deploy
├── data-model.md        # Phase 1
├── quickstart.md        # Phase 1 (test tiers + mutation table + live gate)
└── contracts/
    ├── mcp-warm-contract.md
    ├── channel-window-config.md
    ├── boot-retry-contract.md
    └── patch-marker-listing.md
```

### Source Code (repository root)

```text
scripts/lib/mcp_warm.sh                        # US1: --force, honest reporting, stale-link pruning
docker/Dockerfile                              # US1: UV_TOOL_BIN_DIR (no PATH change — DD-1)
docker/scripts/start_services.sh               # US1: call the pruner; US3: bounded boot retry
setup.sh                                       # US2: sanitiser, backfill, .env migration warning
modules/docker-compose.yml.tpl                 # US2: rendered CHANNEL_HEALTH_TIMEOUT
docker/scripts/apply_telegram_typing_patch.py  # US4: --list-markers
scripts/agentctl                               # US4: robust counting, consume the marker list
docs/creating-an-agent.md, docs/state-layout.md # US4: correct the documented false negative
tests/{mcp-warm,start-services-warm,start-services-watchdog}.bats
tests/{channel-window-config,agentctl-doctor-telegram-patches,agentctl-doctor-boot-attempt}.bats   # new
tests/{docker-render,local-render,schema}.bats, tests/fixtures/sample-agent*.yml
tests/docker-e2e-warm-cache.bats                # extended
```

**Structure Decision**: no new structure. Every change lands in an existing file of one of the repo's
three code paths, and the two new test files follow existing moulds
(`tests/mcp-handshake-timeout.bats` for config, `tests/agentctl-doctor-claude-oauth.bats` for the
doctor shim).

## Design decisions (resolving the open questions of research.md)

### DD-1 — uv state layout (US1)

- `docker/Dockerfile:118-120` gains `UV_TOOL_BIN_DIR=/opt/uv/bin`. It is created and chowned by the
  existing `/opt/uv` block (`:121-125`, `mkdir -p /opt/uv` + `chown -R ${UID}:${GID} /opt/uv`), so
  both halves of uv's state then live in the image and are rebuilt together.
- **`PATH` is deliberately NOT modified.** Measured in a live container: `PATH` is
  `/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin` and the Dockerfile sets no `ENV
  PATH` at all, so `~/.local/bin` was never on it. Nothing ever invoked those executables by name —
  MCP servers are launched as `uvx <pkg>` (`uvx` resolves from `/usr/local/bin`). The links uv wrote
  there had exactly one observable effect: blocking later installs. Adding a new bin dir to `PATH`
  would therefore be surface with no consumer, and is rejected.
- `scripts/lib/mcp_warm.sh` gains `mcp_warm_prune_stale_links`: for each entry in the agent's
  `~/.local/bin` that is a symlink into `/opt/uv/tools` **and** whose target does not resolve, remove
  it. Nothing else is touched — not real files, not links pointing elsewhere.
- The installer call gains `--force`, so a residual collision can never re-block a warm.

The pruner is invoked from `pre_warm_mcps` (`start_services.sh:808-811`) **before** `mcp_warm_run`.
The reason is NOT an early return in `mcp_warm_run` — that early return belongs to
`mcp_warm_targets` (`mcp_warm.sh:62`, inside a process substitution), the misreading
`review-remediation.md` #6 already corrected once and which had survived into this paragraph. The
order is load-bearing because a stale link left in place **re-blocks the very install the warm is
about to attempt**, and because the cleanup must still happen for an agent with no uvx/npx targets
left.

### DD-2 — Warm outcome vocabulary (US1)

`mcp_warm_run` classifies each failure and says which it was: the installer exited non-zero, or the
ceiling was hit, or the runtime is missing. The summary line keeps its current shape. Exact strings
are fixed in `contracts/mcp-warm-contract.md` so tests and implementation cannot drift.

### DD-3 — `docker.channel_health_timeout_s` (US2)

The field goes in the existing `docker:` block (`tests/fixtures/sample-agent.yml:20-25`) — its
consumer is the container watchdog, not the `claude` binary, which is why it does not join
`claude.mcp_timeout_ms`. Unit suffix `_s` mirrors the `_ms` precedent.

- Sanitiser `channel_health_timeout_effective()` in `setup.sh`, moulded on `mcp_timeout_effective()`
  (`setup.sh:2016-2023`): positive integer of 1-6 digits → verbatim; anything else → `60`.
- Backfill via `has()` (`setup.sh:2227-2233` mould), never `//`, so a legitimate value is never
  collapsed — and it **MIGRATES**: when the workspace `.env` holds a valid integer for the key, that
  value is what lands in `agent.yml`; `60` is written only when there is nothing to migrate. A flat
  `60` would silently downgrade every agent that followed the current documentation (see data-model
  §1, and the adversarial review's finding #2).
- Re-export of the sanitised value after `render_load_context`, then one unconditional line in the
  compose `environment:` block, next to `MCP_TIMEOUT` (`modules/docker-compose.yml.tpl:73`).
- The in-container default stays 60 (`start_services.sh:739-745` is not touched) so an agent whose
  compose predates this feature behaves exactly as today.
- Migration notice: `--regenerate` uses `env_file_get` (`scripts/lib/env_file.sh`, feature 021) to
  detect the key in the workspace `.env` and prints **CANON-C2**, which announces a *completed
  migration*, not a pending conflict. Its first token is `NOTE:`, not `WARN:` — the contract
  declares the `WARN:` wording stale by construction. It names the key and never its value.
- Local mode: docker-only. The oracle is the FR-011 pattern of 032 — zero `CHANNEL_HEALTH_TIMEOUT`
  in local runtime artefacts.

### DD-4 — Bounded boot retry (US3)

`main()` (`start_services.sh:1279-1282`) delegates to `start_initial_session` — the loop and both log
lines live in that **named function**, not inline in `main()`, because `main()` has no host-side
oracle while a named function can be sourced under `START_SERVICES_NO_RUN=1` (data-model §5). It
retries `start_session` up to **3 attempts total**, logging `initial session attempt N/3`, and exits
1 only after the third. Rationale for 3: with the 60 s default window, worst case is ~3 minutes of
boot. The compose healthcheck (`docker-compose.yml.tpl:46-51` — `:44-45` are comments, and
`start_period: 60s` sits at `:51`) probes `crond` + `tmux`, both alive during the retries, so a warm
boot stays healthy; on a cold one `unhealthy` is reachable, and **DD-6 is the mitigation** rather
than the healthcheck simply tolerating it. It also gives the uv/npm caches two extra chances to
persist in the writable layer instead of being discarded by a container exit. No sleep is inserted
between attempts: `verify_channel_healthy` already consumed the window, and `start_session` kills and
respawns tmux on its own (`:833-835`).

### DD-5 — Patcher-owned marker list (US4)

`apply_telegram_typing_patch.py` gains `--list-markers`, printing one marker per line from
`ALL_MARKERS` (`:124-132`) and exiting 0, with no file argument required. `agentctl doctor` invokes
the image-baked patcher through the container (`_in_container`, `:332-335`), receives the current
seven markers, counts each with a construct that cannot emit `0\n0`, inspects the same
`"$cache"/*/server.ts` set the boot patcher walks (`start_services.sh:404-415`), and names any group
that is absent. No version literal survives in `agentctl`.

Fallback: if the patcher predates the flag (an agent on an older image), `doctor` reports the check as
skipped rather than failing — consistent with how it already handles a plugin that is not installed
yet (`:539`).

### DD-6 — Boot-aware `doctor` (US3/US4 seam, operator decision 2026-09-19)

`start_initial_session` writes `${WATCHDOG_RUNTIME_DIR}/boot-attempt` holding `<attempt> <epoch>` and
removes it on success and on exhaustion; `agentctl doctor` reads it **through `docker exec`** (the
path is a container tmpfs, unreachable from either bind-mount) and, while the marker is present and
fresh, reports `CANON-H1` instead of mapping `unhealthy` to a failure. Full shape, including the
mandatory `mkdir -p` + `|| true` that the adversarial review found missing, is in data-model §5b.

Three things this design must not get wrong, each with its own clause and mutation:

1. The directory does not exist at attempt 1 (`/tmp` is a tmpfs, the only `mkdir` is deep inside
   `start_session`), and the script runs under `set -euo pipefail` — so the write needs both a
   preceding `mkdir -p … || true` and its own `|| true`.
2. The bypass must expire, or a permanently broken agent reads as "still starting" forever.
3. The identifier series is `CANON-H*`; `CANON-D*` already belongs to `contracts/patch-marker-listing.md`.

**Constitution re-check for this addition**: Principle II unaffected (no new capability; the file is
written and read as `agent`, via the existing `_in_container` helper). Principle III satisfied by a
host bats oracle with a docker shim plus a mutation per item above. Principle IV satisfied by the
`|| true` on every marker operation and by the marker's removal on both exit paths.

## Phases

- **Phase 0 — Research**: complete. `research.md` (D1-D6) + `field-evidence.md`.
- **Phase 1 — Design & contracts**: `data-model.md` (the new field, the warm outcome record, the
  marker set), four contracts, `quickstart.md` with the three test tiers, the mutation table and the
  live-gate steps on `donna`/`linus`.
- **Phase 2 — Tasks**: `/speckit-tasks`, test-first, ordered US1 → US2 → US4 → US3 (US3 last because
  it touches the watchdog and should land on an otherwise-green tree).

## Risks

| Risk | Mitigation |
| --- | --- |
| `--force` overwrites an executable belonging to the baked catalogue (`mcp-atlassian`, `mcp-server-fetch`, `mcp-server-time`) | DOCKER_E2E asserts those three still run after a warm that forces; the pruner only removes *dangling* links, never live ones |
| Moving the bin dir strands links already on `PATH` in existing workspaces | That is exactly what the pruner removes, on every boot, idempotently |
| The rendered `environment:` value silently overrides an operator's `.env` | FR-008 warning at `--regenerate`, plus the live gate explicitly migrates `donna`'s value |
| Boot retry masks a genuinely broken channel for ~3 minutes | Each attempt is logged distinguishably; the final exit is unchanged, so Docker still escalates |
| Watchdog regression (precedent `ebfe35f`) | US3 is scoped to the initial-boot path only; no new detection logic; DOCKER_E2E covers it |
| **`doctor` reports a hard FAIL during a legitimate retry** — the compose healthcheck can flip to `unhealthy` when a per-attempt preamble exceeds ~60 s, and `agentctl doctor:381-389` maps `unhealthy` → `_doctor_fail` | **No longer accepted — fixed by DD-6** (operator decision, 2026-09-19). The first draft accepted it as R1 of `contracts/boot-retry-contract.md`; that prohibition is withdrawn. Raising `start_period` stays rejected: it would mute an honest signal |
| **The boot-aware bypass masks a permanently broken agent** — a container that can never bring the channel up is *always* in an initial boot, so a naive bypass would answer "starting (2/3)" forever, which is worse than today's FAIL | The marker carries an epoch and the bypass lapses once its age exceeds `MAX_BOOT_ATTEMPTS × (window + overhead)`; past that the FAIL returns and names the reason (data-model §5b). `scripts/agentctl` consults no `RestartCount` today, so the timestamp is the cheaper of the two viable signals |
| Worst-case boot time at a high window (`420 × 3 ≈ 21 min`) | Accepted without a cap: today's behaviour at that setting is not "fails in 7 minutes", it is an unbounded restart loop that destroys its own caches, and `warn_if_channel_timeout_risky` already fires every boot for any value ≥ 65 s. Deriving the attempt count from a total budget was considered and rejected (it would silently contradict decision D of feature 026) |
