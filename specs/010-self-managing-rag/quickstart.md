# Quickstart — Validating Self-Managing RAG (010)

**Date**: 2026-06-28 · **Branch**: `010-self-managing-rag`

How to exercise the feature end-to-end. Host scenarios run without Docker; integration scenarios are `DOCKER_E2E=1`-gated.

---

## Host-side (no Docker) — the default gate

```bash
# Full suite stays green (Principle III)
bats tests/

# The feature's own units
bats tests/qmd-index.bats        # reindex idempotence / flock / state
bats tests/qmd-setup.bats        # setup idempotence
bats tests/qmd-watch.bats        # debounce / coalesce
bats tests/qmd-reindex-cmd.bats  # cron line + dispatch
bats tests/schema.bats -f qmd    # vault.qmd.* validation
bats tests/mcp-json.bats -f QMD  # pinned @2.5.3 render

# Shell gate
shellcheck -S error docker/scripts/qmd_watch.sh docker/scripts/lib/qmd_index.sh \
                    docker/scripts/start_services.sh docker/scripts/heartbeatctl
```

**Stubs used** (so host tests need no bun/inotify/Docker):
- a fake `bunx` on PATH that records its args and fakes `collection add`/`update`/`embed`/touching `index.sqlite`;
- a fake `inotifywait` that emits a scripted burst of events then exits;
- a `timeout` shim for macOS (where `timeout(1)` is absent), same pattern as 008/009.

---

## Scenario A — first-boot setup is idempotent (US1)

1. `agent.yml` with `vault.enabled=true`, `vault.qmd.enabled=true`, a seeded vault.
2. Call `qmd_setup_if_needed` with the stub `bunx`.
   - **Expect**: `collection add` + `update` + `embed` invoked once; sentinel `.qmd-setup-ok` + `index.sqlite` present.
3. Call it again.
   - **Expect**: returns 0 with **no** `bunx` invocation (sentinel + index present → no-op). SC-006.
4. Remove the sentinel, leave `index.sqlite`; call again.
   - **Expect**: re-runs (partial state → not trusted).
5. Make `bunx` fail; remove sentinel + index; call again.
   - **Expect**: returns 0 (fail-silent), sentinel NOT written (will retry next boot). US1 scenario 3.

## Scenario B — reindex skips when unchanged, runs when changed (US2, FR-008)

1. Setup done (Scenario A). State `qmd-index.json.hash` = current `vault_hash`.
2. `heartbeatctl qmd-reindex` with no vault change.
   - **Expect**: `last_status:"skipped"`, no `embed` call.
3. Write a new note into the vault; `heartbeatctl qmd-reindex`.
   - **Expect**: `update` + `embed` called once; `hash` updated; `last_status:"indexed"`. SC-002.

## Scenario C — concurrent reindex is serialized (FR-007, SC-005)

1. Hold the flock on `.reindex.lock` (background `flock` process).
2. Call `heartbeatctl qmd-reindex`.
   - **Expect**: logs "reindex already running — skip", returns 0, **no** `embed`, state untouched.

## Scenario D — watcher coalesces a burst into one reindex (FR-005, SC-004)

1. Start `qmd_watch.sh` with stub `inotifywait` scripted to emit 20 events within 2s, then quiet, and a stub `heartbeatctl` that counts `qmd-reindex` calls.
2. Wait past the debounce window.
   - **Expect**: exactly **one** `qmd-reindex` call recorded.
3. Run `qmd_watch.sh` with `inotifywait` absent from PATH.
   - **Expect**: logs "inotifywait unavailable — relying on cron backstop", exits 0.

## Scenario E — cron line presence is gated (US2b, US3)

1. `vault.qmd.enabled=true`; `heartbeatctl reload`.
   - **Expect**: staging crontab contains `*/5 * * * * /usr/local/bin/heartbeatctl qmd-reindex …`.
2. Set `vault.qmd.schedule="*/10 * * * *"`; `reload`.
   - **Expect**: the line uses `*/10 * * * *`.
3. `vault.qmd.enabled=false`; `reload`.
   - **Expect**: no `qmd-reindex` line.

## Scenario F — disabled is a true no-op (FR-012, SC-007)

1. `vault.qmd.enabled=false`.
   - `mcp-json`: no `qmd` server (existing `tests/mcp-json.bats`).
   - `reload`: no cron line (Scenario E.3).
   - `setup_qmd_if_needed`/watcher start: return 0 without side effects.

## Scenario G — schema validation (US3, FR-014)

```bash
# reject typo'd boolean
yq -i '.vault.qmd.enabled = "ture"' agent.yml && ! agent_yml_validate agent.yml
# reject empty version
yq -i '.vault.qmd.version = ""' agent.yml && ! agent_yml_validate agent.yml
# accept well-formed
agent_yml_validate tests/fixtures/sample-agent-with-vault.yml   # (with version+schedule added)
```

---

## DOCKER_E2E (gated) — integration seams

```bash
DOCKER_E2E=1 bats tests/docker-e2e-qmd.bats   # (new or folded into an existing e2e file)
```

Asserts, on a real container with a QMD-enabled minimal vault:
1. **First-boot setup** eventually produces `~/.cache/qmd/index.sqlite` + a model dir (backgrounded; poll with a timeout).
2. **inotify fires under the bind-mount**: writing a note into the vault triggers a `qmd-reindex` (watcher path), observable in `logs/qmd-reindex.log` and a bumped `runs` in `qmd-index.json`.
3. **Cron backstop**: with the watcher killed, a vault change is still picked up within the cron window.
4. **Least privilege intact**: the container still runs `cap_drop: ALL` (+3 caps); no privileged mount/socket added. (Principle II verify-in-e2e.)

Mirror the documented compose-run gotchas: pre-create `.state`, pass `--entrypoint`, declare the plugins/config the boot path expects.

---

## Manual smoke (live agent, optional)

On a running QMD-enabled agent:

```bash
./scripts/agentctl heartbeat qmd-reindex --dry-run   # report-only
./scripts/agentctl logs -f                            # watch qmd-reindex.log activity
```

The agent's semantic search (QMD MCP) should return results reflecting recently-added notes within ~60s (watcher) without any manual `qmd` command.
