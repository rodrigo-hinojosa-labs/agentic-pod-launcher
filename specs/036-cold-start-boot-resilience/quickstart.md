# Quickstart — 036 cold-start boot resilience

Three tiers, in order: host (no docker, no network) → DOCKER_E2E (real containers, run for real on
this host — precedent 033/034) → live gate on ferrari. Unlike 034, the live gate here is **not**
deferrable in spirit: `donna` is the agent that exhibits the defect and is the only place SC-001,
SC-003 and SC-004 can be measured. It still runs last.

## §1. Host gates

```bash
cd /Users/rodrigo-hinojosa/Documents/Cencosud/Claude/Agents/agentic-pod-launcher

bats tests/mcp-warm.bats                       # 14 existing + US1 (force, outcome classes, pruner)
bats tests/start-services-warm.bats            # 8 existing + pruner call order
bats tests/start-services-watchdog.bats        # 29 existing + US3 boot retry
bats tests/channel-window-config.bats          # new, US2 (mould: mcp-handshake-timeout.bats)
bats tests/agentctl-doctor-telegram-patches.bats   # new, US4 (mould: agentctl-doctor-claude-oauth.bats)
bats tests/agentctl-doctor-boot-attempt.bats   # new, US3 boot marker (separate file: different shim)
bats tests/docker-render.bats tests/local-render.bats tests/schema.bats tests/regenerate.bats

bats tests/                                    # full suite, then again under bash 3.2:
PATH=/bin:$PATH bats tests/ | tail -3          # /bin/bash 3.2.57 on macOS (025 rule)

shellcheck -S error setup.sh scripts/lib/*.sh docker/scripts/*.sh docker/scripts/lib/*.sh   # the CI command
python3 -B -m py_compile docker/scripts/apply_telegram_typing_patch.py && find . -name __pycache__ | wc -l   # 0
```

Both bash arms must report the same counts. The 034 baseline to beat is **1412 ok / 0 not ok** on
3.2.57 (the 5.x arm has a known contention flake in `askq-guard-config.bats` that passes in
isolation — confirm by re-running the single file, do not paper over a new failure with it).

## §2. DOCKER_E2E (this host has Docker — run it, do not defer)

```bash
DOCKER_E2E=1 bats tests/docker-e2e-warm-cache.bats    # 3 existing + the 036 additions
DOCKER_E2E=1 bats tests/docker-e2e-postlogin.bats     # its feature-026 case MUST be rewritten (see below)
```

`tests/docker-e2e-postlogin.bats:150` («channel timeout: CHANNEL_HEALTH_TIMEOUT from .env reaches the
container») **goes red under this feature and the first draft of the plan did not list it**: it writes
an `agent.yml` without the new field, runs `--regenerate`, only then writes `.env` with `45`, and
asserts the container sees `45`. With the rendered `environment:` line outranking `env_file`, it will
see the migrated/backfilled value instead. It is rewritten to express the new semantics — a field that
reaches the container, and an explicit precedence case — rather than deleted.

New coverage required in this tier, because none of it is reachable from the host:

| Case | What it proves |
| --- | --- |
| E-A | `UV_TOOL_BIN_DIR` is set in the built image and points inside `/opt/uv` |
| E-B | A warm target whose executable link already exists still ends warm (the exact `rc=2` reproduced and defeated) |
| E-C | Dangling links under `~/.local/bin` pointing into `/opt/uv/tools` are pruned; a resolving link and a regular file with the same name survive |
| E-D | The three baked catalogue tools (`mcp-atlassian`, `mcp-server-fetch`, `mcp-server-time`) still execute after a forced warm |
| E-E | `apply_telegram_typing_patch.py --list-markers` prints 7 lines and exits 0 inside the image |
| E-F | The boot retry logs `initial session attempt 1/3` and a second attempt when the channel is slow |

Harness facts inherited from 033/034: the patcher's `log()` writes to **stdout**; `grep -c` exits 1
on a zero count (`|| true` under `set -e`); `docker compose run` prepends progress lines to
`$output`, so assert named markers with `grep -qx`, never line positions.

## §3. Mutation spot-checks

Each must turn at least one **named** test red; revert after each.

| # | Mutation | Expected RED |
| --- | --- | --- |
| M1 | Drop `--force` from the installer call | US1 collision test (host), E-B |
| M2 | Make the pruner also remove links that resolve | pruner "keeps a live link" case, E-C |
| M3 | Make the pruner remove regular files, not just symlinks | pruner "keeps a regular file" case |
| M4 | Call the pruner after `mcp_warm_run` instead of before | the behavioural oracle of mcp-warm C14: a dangling link colliding with a declared package makes pruner-after report CANON-W1 `failed (exit 2)` while pruner-before reports `1/1 warm`. NOT the old justification — `mcp_warm_run` has no early return (that belongs to `mcp_warm_targets`, `mcp_warm.sh:62`, inside a process substitution), so a pruner placed after it still deletes the link and the naive oracle stays green |
| M5 | Collapse the three warm outcome strings back into one wording | CANON-W1/W2/W3 oracles |
| M6 | Remove `UV_TOOL_BIN_DIR` from the Dockerfile | E-A, and E-B regresses to the original `rc=2` |
| M7 | Backfill the new field with `//` instead of `has()` | "operator value is preserved" test in `channel-window-config.bats` |
| M8 | Render the compose line conditionally | docker-render assertion |
| M9 | Print the operator's value inside the migration notice | the C10 oracle asserting the value never appears in output — rewritten, because the original form was red in BOTH branches under bats errexit |
| M10 | Change the in-container default from 60 | `channel_health_timeout defaults to 60 …` (existing test, `start-services-watchdog.bats:327`) |
| M11 | Set `MAX_BOOT_ATTEMPTS=1` | boot-retry "succeeds on the second attempt" test |
| M12 | Make exhaustion `exit 0` | boot-retry "still exits non-zero" test |
| M13 | Add a sleep between boot attempts | timing oracle of the retry test |
| M14 | Restore the `grep -c … \|\| echo 0` construct in the doctor count | doctor "no shell error text" oracle |
| M15 | Hardcode one marker literal in `agentctl` | anti-drift grep over `scripts/agentctl` |
| M16 | Make `doctor` read only the first `server.ts` | two-version-cache case |
| M17 | Make `--list-markers` exit non-zero | E-E, and the doctor's skip-vs-fail case |
| M18 | Make the backfill write a flat `60` instead of migrating the operator's existing value | `channel-window-config.bats` migration case — a live agent at 120 must not silently drop to 60 |
| M-B1 | Remove the `mkdir -p "$WATCHDOG_RUNTIME_DIR"` before the first attempt | boot-retry C13: the marker is absent on attempt 1 when the runtime dir does not exist yet |
| M-B2 | Drop the `\|\| true` from the marker write | boot-retry C13/C14 non-fatality oracle — under `set -euo pipefail` the whole boot aborts |
| M-B3 | Remove the marker removal on the exhaustion path | boot-retry C15 oracle; a stale marker would outlive the boot that created it |
| M-B4 | Drop the freshness guard from the doctor bypass | boot-marker case: a stale marker must stop masking `unhealthy`, or a dead agent reads as "starting" forever |
| M-B5 | Make `doctor` read the marker from the bind-mount instead of `docker exec` | boot-marker oracle — the path is a container tmpfs, so the check would silently never fire |
| M19 | Reinstate `DIR="${DIR:-$HOME/.local/bin}"` in `mcp_warm_prune_stale_links` | mcp-warm C10 oracle (b): the no-argument and empty-argument cases, plus the static grep that the lib never names a default. This is the guard that keeps an `rm` loop from ever defaulting to the operator's real `~/.local/bin` — `mcp_warm.sh` is sourced on the host too (`modules/local-bootstrap.sh.tpl:47`). Added by `/speckit-analyze`: the contract called this mutation "M5", an id already taken by the warm-wording one, so the remediation of adversarial-review finding #11 had no catcher |
| M20 | Swap the content-based `--list-markers` probe for a status-based one (`if patcher --list-markers >/dev/null 2>&1`) | T014's old-patcher case. Measured in data-model §6: an older patcher handed the flag exits **0 with no markers**, so a status check reports a perfectly healthy agent — the same false-clean verdict US4 exists to kill, merely inverted. M17 mutates the opposite direction (a patcher that *fails*), which the skip path already catches |
| M21 | Add a `tmux capture-pane` probe to the boot retry loop | T019 (m3): the `_run_watchdog` sha oracle. FR-013 forbids new stuck-channel detection — the prohibition that exists because `ebfe35f` killed sessions every ~2 minutes — and until now it was enforced only by prose inside an implementation task |

## §4. Live gate (ferrari, LAN; `donna` first this time)

Order is inverted relative to 034 on purpose: `donna` is the agent that reproduces the defect, and it
is the one still carrying the temporary override.

### §4.1 Preconditions to capture before touching anything

```bash
ssh ferrari "cd <donna-ws> && cat docker-compose.override.yml; ls /home/agent/.local/bin"
ssh ferrari "docker exec -u agent donna sh -c 'ls -la /home/agent/.local/bin'"   # expect dangling links
```

Record the current `CHANNEL_HEALTH_TIMEOUT` the agent runs with. Back up as in the 034 gate
(`/tmp/agent-upgrade-backups/`).

### §4.2 SC-004 — the override becomes configuration

Set `docker.channel_health_timeout_s` in `donna`'s `agent.yml` to the value the override carried,
run the overlay-aware regenerate (`custom-apply.sh <ws> --agent donna`, because `donna`'s Google MCP
servers live only in the derived `.mcp.json`), then **delete** `docker-compose.override.yml`.
`docker compose config` must show the same effective value as before — inspect it with a filter that
prints only that key, never the whole expanded environment.

> Hard-won rule from the 034 gate: never run `docker compose config` with surrounding context lines.
> It expands and prints every secret in the environment. Filter to the exact key.

### §4.3 SC-001 — the warm stops lying

Rebuild and recreate, then read the boot log:

```bash
ssh ferrari "cd <donna-ws> && docker compose logs donna 2>&1 | grep 'mcp_warm'"
```

Expected: no warning for `workspace-mcp` or `mcp-server-git`; exactly one for
`mcp-server-tree-sitter`, and that one names the failure class (SC-002).

### §4.4 SC-003 — a cold boot converges on its own

The decisive measurement. After the rebuild (caches cold, no override in place):

```bash
ssh ferrari "cd <donna-ws> && docker compose logs donna 2>&1 | grep -E 'initial session attempt|channel plugin healthy|never appeared'"
```

Expected: `channel plugin healthy — bun server.ts running`, with at most the budgeted retries and
**no container restart**. Compare against the pre-036 behaviour recorded in `field-evidence.md`
(infinite loop, container restarts).

### §4.5 SC-005/SC-006 — the doctor tells the truth

```bash
ssh ferrari "cd <donna-ws> && ./scripts/agentctl doctor; echo rc=$?"
```

Expected: a pass line naming the patch groups, `rc=0`, and no `integer expression expected` anywhere
in the output. Then repeat on `linus`.

### §4.6 Regression check on `linus`

`linus` never exhibited the defect, so it is the no-regression control: same upgrade, channel healthy
on the first attempt, `doctor` clean.

## §5. Rollback

Per agent, the backup tarball restores `setup.sh`, `VERSION`, `modules/`, `docker/` and `scripts/`;
then `--regenerate` (through `custom-apply.sh` on `donna`) and a rebuild return the workspace to
v0.25.0-without-036. The `agent.yml` field is inert under an older image (unknown keys are ignored by
the render, and the container keeps reading `CHANNEL_HEALTH_TIMEOUT` from the `.env`), so the field
can stay. If rollback is needed because the boot retry misbehaves, restoring
`docker/scripts/start_services.sh` alone is enough — it is image-baked, so a rebuild is required for
the restore to take effect.
