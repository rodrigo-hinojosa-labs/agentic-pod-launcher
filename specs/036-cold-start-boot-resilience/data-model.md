# Data model — 036 cold-start boot resilience

Phase 1. Entities, their fields, and the **canonical strings** (CANON-*) that implementation and
tests must both use verbatim. A string that appears here is the contract; divergence between a test
oracle and the implementation is the failure mode this file exists to prevent (lesson of 033/034).

## 1. `docker.channel_health_timeout_s` (new `agent.yml` field)

| Property | Value |
| --- | --- |
| Path | `.docker.channel_health_timeout_s` |
| Type | positive integer, seconds |
| Default written by the wizard heredoc | `60` |
| Flattened context var | `DOCKER_CHANNEL_HEALTH_TIMEOUT_S` (automatic, `render_load_context`) |
| Sanitiser | `channel_health_timeout_effective()` in `setup.sh`, mould `mcp_timeout_effective()` (`setup.sh:2016-2023`) |
| Accepted | `^[0-9]{1,6}$` **and** `> 0` → verbatim |
| Rejected → `60` | empty, absent, `0`, negative, non-numeric, `1.5`, more than 6 digits |
| Backfill | `yq … has("channel_health_timeout_s")` → if absent, **migrate the live value**: seed from the workspace `.env` when it holds a valid integer, else `60`. Never `//` |
| Delivery | one unconditional line in the compose `environment:` block |
| Wizard prompt | **none** (precedent: `features.voice.{signoff,currency}` of 034) |
| Mode | docker-only; inert in local mode |

Rendered line (CANON-C1), placed next to `MCP_TIMEOUT` in `modules/docker-compose.yml.tpl`:

```yaml
      CHANNEL_HEALTH_TIMEOUT: "{{DOCKER_CHANNEL_HEALTH_TIMEOUT_S}}"
```

The in-container reader (`start_services.sh:739-745`) is **not** modified: its embedded `60` default
and its own validation stay exactly as today, so an agent whose compose predates this feature keeps
behaving identically.

### Precedence warning (FR-008)

`environment:` outranks `env_file` in compose, so a key an operator put in the workspace `.env`
stops taking effect once this renders. `--regenerate` detects the key with
`env_file_get` (`scripts/lib/env_file.sh`, feature 021 — parses, never sources) and emits, to
stderr, exactly (CANON-C2):

```text
NOTE: CHANNEL_HEALTH_TIMEOUT from the workspace .env was migrated into agent.yml (docker.channel_health_timeout_s); docker-compose.yml now renders it and the rendered value wins — you can remove the .env line
```

The value is never read into a message, printed, or logged — only the key's presence.

### The backfill MIGRATES, it does not reset (adversarial review, HIGH)

Backfilling a flat `60` while rendering CANON-C1 unconditionally would **silently downgrade every
agent that followed the current documentation**. `README.md:150` and `docs/architecture.md:127` tell
the operator to put `CHANNEL_HEALTH_TIMEOUT` in the workspace `.env`; `donna` runs at 120 (raised to
420 during the incident) and CLAUDE.md records `rodri-cenco-admin` at 120 as well. Since
`environment:` outranks `env_file`, the first `--regenerate` + `up` after this feature would drop
them all to 60 — re-creating, in agents that are not even in the live gate, exactly the cold-cache +
many-MCP + short-window combination that caused the 25-minute outage.

So the backfill reads the workspace `.env` first (`env_file_get`, which parses and never sources):

| `.env` holds | `agent.yml` gains | Operator is told |
| --- | --- | --- |
| a valid positive integer | **that value** | migrated; the `.env` line can be removed |
| nothing / invalid / no `.env` | `60` | nothing |

CANON-C2's wording changes accordingly: it announces a completed migration, not a pending conflict.
Only after the value lives in `agent.yml` does the rendered line take over, so effective behaviour is
unchanged across the upgrade — which is the whole point.

**Four implementation facts that the first draft of this design got wrong** (found while writing
`contracts/channel-window-config.md`, all verified in the tree):

1. **`setup.sh` did not source `scripts/lib/env_file.sh`.** Its lib block (`setup.sh:7-14`) loaded
   eight libraries and that was not one of them, so `env_file_get` was *not* callable. Wiring it in
   was part of the work, not an assumption, and is **done as of T003** — the block now loads nine.
   The guarded precedent copied is `scripts/agentctl:1133-1135`.
2. **`env_file_get` cannot express "key present".** By its own documented contract
   (`scripts/lib/env_file.sh:15-17`, FR-005 of feature 021) it returns an empty string both for
   *absent* and for *present-but-empty*. The trigger is therefore a **non-empty value**. The
   present-but-empty case deliberately does not warn: an empty value already degrades to 60 in the
   container (`start_services.sh:741-743`), so there is nothing to migrate.
3. **The warning is gated to docker mode**, inside the docker-only render branch
   (`setup.sh:2545-2549`). A local-mode workspace has no channel window and must stay silent.
4. **Heredoc placement is a trap.** `$docker_yaml` (`setup.sh:1116-1129`) *ends* with the nested
   `toolchain_channels:` mapping, so appending the new key at the end would nest it under
   `toolchain_channels`, not under `docker:`. The key goes before that nested block, and the
   contract carries an oracle that catches exactly this slip.

**Digit bound, deliberately narrower than the 029 mould.** This field accepts `^[0-9]{1,6}$` to match
the container-side reader (`start_services.sh:740`), whereas `claude.mcp_timeout_ms` allows 7. A
7-digit value is therefore *rejected* here (→ 60), which is the opposite of the equivalent case in
`tests/mcp-handshake-timeout.bats`. Intentional; called out so the transposed test is not copied
blindly.

**Test-surface touchpoints** (absent from the first draft of plan.md): both fixtures gain the field —
`tests/fixtures/sample-agent.yml` (what `docker-render.bats` renders) and
`tests/fixtures/sample-agent-with-vault.yml` (required by the placeholder test at
`tests/schema.bats:52`). No `scripts/lib/schema.sh` change is needed: `claude.mcp_timeout_ms` appears
in none of its lists either, and this field introduces no new boolean.

## 2. Warm outcome (US1)

`mcp_warm_run` already iterates `(runtime, package)` targets. Each now resolves to exactly one
outcome:

| Outcome | When | Emits |
| --- | --- | --- |
| warm | installer exited 0 | nothing (the per-target `warming …` line already exists) |
| failed | installer exited non-zero within the ceiling | CANON-W1 |
| timed out | the ceiling was reached | CANON-W2 |
| unavailable | the runtime (`uv` / `npm`) is not on PATH | CANON-W3 |

### `--force` is UNCONDITIONAL (settled by measurement, 2026-09-19)

An earlier draft of this file made `--force` conditional — plain install first, forced retry only on
a collision — to avoid the cross-story cost that `contracts/boot-retry-contract.md` raised as R4: if
forcing turns the warm into a full reinstall, US3's three boot attempts pay it three times.

**R4 is refuted by measurement.** Inside the live `donna` container, against a throwaway
prefix/cache on real disk (not `/tmp`, which is a 100 MB tmpfs here):

```console
$ uv tool install --python python3 workspace-mcp      # cold cache, empty prefix
rc=0  elapsed=12s
$ uv tool install --force --python python3 workspace-mcp   # same cache, already installed
rc=0  elapsed=0s
```

Forcing over an already-resolved package reuses `UV_CACHE_DIR` and costs nothing measurable, so the
inflation R4 feared does not exist. Unconditional forcing therefore wins on every axis: it needs no
stderr capture (`mcp_warm.sh:98` discards stderr today), no matching of uv's unversioned error text,
and it keeps `contracts/mcp-warm-contract.md` C1, its oracle, and mutation M1 exactly as written.

Two consequences recorded so they are not rediscovered:

- The 300 s ceiling is not the binding constraint for this package — a cold install is 12 s. The
  incident was **entirely** the collision (`rc=2`), never slowness.
- `tests/docker-e2e-warm-cache.bats:88-104` warms `mcp-server-fetch`, one of the three baked
  catalogue tools. With unconditional `--force` that case reinstalls from the local cache rather
  than being a pure no-op; it must stay offline-safe, which FR-004 already requires and DOCKER_E2E
  case E-D verifies.

Canonical strings, all on stderr through the existing `_mcp_warm_log` prefix (`mcp_warm.sh:24`):

- **CANON-W1**: `mcp_warm: warn: uvx workspace-mcp failed (exit 2) — will resolve on first use`
- **CANON-W2**: `mcp_warm: warn: uvx workspace-mcp timed out after 300s — will resolve on first use`
- **CANON-W3**: `mcp_warm: warn: uvx unavailable (uv not on PATH) — skipping workspace-mcp`

The `(exit N)` / `timed out after Ns` clause is the whole point of US1's FR-002: the old wording made
an instant hard failure indistinguishable from a slow download, which is why the defect survived from
feature 030 until a 25-minute outage exposed it.

### Which exit codes mean "timed out" (MEASURED — do not assume 124)

GNU `timeout` reports `124` on expiry; **busybox `timeout`, which is what the image actually has,
reports `143`** (128+SIGTERM). Measured on both Alpine 3.20 and Alpine 3.24.1 (the image base,
`docker/Dockerfile:5`):

```console
$ docker run --rm alpine:3.24 sh -c 'timeout 1 sleep 5; echo rc=$?'
rc=143
$ docker run --rm alpine:3.24 sh -c 'timeout 5 sh -c "exit 7"; echo rc=$?'
rc=7          # a non-expiring child's status passes through faithfully
```

Therefore the timeout class is `{124, 143}`, not `{124}`. Classifying only on 124 would have labelled
every real in-container timeout as `failed (exit 143)` — re-creating, through the back door, the very
ambiguity this story removes. Accepted residual, documented rather than hidden: an installer that
legitimately exits 124 or 143 of its own accord is reported as a timeout.

### Where `unavailable` counts in the summary

The preserved summary line has two buckets (`N/M warm, K failed`) but §2 defines four outcomes. A
missing runtime counts toward `K failed`, which is today's arithmetic (`_mcp_warm_one` already
returns 1 when the runtime is absent). The summary line is not re-worded, so no existing behaviour
churns.

Unchanged (no test pins it today, and none is added that would freeze the counts): the summary line
`mcp_warm: warm cache: N/M warm, K failed` (`mcp_warm.sh:130`).

## 3. Stale uv link (US1)

| Property | Value |
| --- | --- |
| Location scanned | `${HOME}/.local/bin` (the agent's own; never a system path) |
| Removal predicate | entry **is a symlink** AND its target path begins with `/opt/uv/tools/` AND the target does **not** resolve |
| Never removed | regular files; symlinks that resolve; symlinks pointing anywhere other than `/opt/uv/tools/` |
| Function | `mcp_warm_prune_stale_links DIR` in `scripts/lib/mcp_warm.sh` — **the argument is mandatory, with no default**; an empty or missing `DIR` returns 0 without scanning |
| Caller | `pre_warm_mcps` (`start_services.sh:808-811`), passing `"$HOME/.local/bin"` explicitly, **before** `mcp_warm_run` |
| Return | always 0 (fail-soft, Principle IV) |
| Idempotency | a second run removes nothing and logs nothing |

Log line, only when at least one link was removed (CANON-W4):

```text
mcp_warm: pruned N stale uv link(s) from /home/agent/.local/bin (image rebuild leaves them dangling)
```

**Why no default argument.** `scripts/lib/mcp_warm.sh` is *not* docker-only: `modules/local-bootstrap.sh.tpl:47`
sources it on the operator's own machine, where `~/.local/bin` holds the real `uv`, `uvx`, `bun`,
`node`/`npx` links and `github-mcp-server` that the local bootstrap installs, and which
`modules/remote-control.env.tpl:10-13` puts first on the unit's `PATH`. A function containing `rm`
whose default target is the operator's own bin directory is one careless call away from damage, and
`tests/mcp-warm.bats:10-16` does not override `HOME` (unlike `tests/start-services-warm.bats:14-15`),
so a default-path test would scan the developer's real directory. The single defined caller always
knows the directory, so the convenience buys nothing. The test setup must also export a scratch
`HOME`.

Rationale for the predicate's narrowness, measured: in a live container `PATH` does not contain
`~/.local/bin` at all, and the three links found there
(`mcp-server-git`, `workspace-cli`, `workspace-mcp`) all pointed into `/opt/uv/tools/…` and were
dangling after the rebuild. Nothing consumes that directory; the only observable effect of its
contents was blocking `uv tool install`.

## 4. Image environment (US1)

| Dockerfile | Before | After |
| --- | --- | --- |
| `:118-120` | `UV_TOOL_DIR=/opt/uv/tools`, `UV_CACHE_DIR=/opt/uv/cache`, `UV_PYTHON_PREFERENCE=only-system` | same **plus** `UV_TOOL_BIN_DIR=/opt/uv/bin` |
| `:121-125` | `mkdir -p /opt/uv` … `chown -R ${UID}:${GID} /opt/uv` | unchanged — already covers the new subdirectory |
| `PATH` | not set by the Dockerfile | **unchanged, deliberately** (see plan DD-1) |

## 5. Boot attempt (US3)

| Property | Value |
| --- | --- |
| Attempts | 3 total (initial + 2 retries) |
| Constant | `MAX_BOOT_ATTEMPTS=3`, beside `MAX_CRASHES`/`WINDOW` (`start_services.sh:258-259`) |
| Function | `start_initial_session` — the retry loop and both log lines live here, **not** in `main()`, because `main()` has no host-side oracle while a named function can be sourced under `START_SERVICES_NO_RUN=1` |
| Sleep between attempts | none (the failed `verify_channel_healthy` already consumed the window; `start_session` respawns tmux itself, `:833-835`) |
| On exhaustion | `exit 1`, exactly as today, so `restart: unless-stopped` still escalates |
| Scope | the **initial** boot path only (`main()`, `:1279-1282`). The watchdog respawn path (`:1269`) is untouched |

Log lines:

- **CANON-B1**, per attempt: `initial session attempt N/3`
- **CANON-B2**, on exhaustion (replaces today's single-line `ERROR: initial tmux session failed to start`):
  `ERROR: initial tmux session failed to start after 3 attempts`

CANON-B2 deliberately keeps the existing prefix `ERROR: initial tmux session failed to start` as a
substring, so any log-scraping that predates this feature keeps matching.

## 5b. Boot-in-progress marker (operator decision 2026-09-19)

Without this, `agentctl doctor` reports a hard FAIL while an agent is legitimately retrying its
boot: the compose healthcheck flips to `unhealthy` when an attempt's preamble runs long, and
`agentctl doctor:381-389` maps `unhealthy` → `_doctor_fail`. The operator chose to make `doctor`
distinguish the two rather than silence the healthcheck.

| Property | Value |
| --- | --- |
| Path | `${WATCHDOG_RUNTIME_DIR}/boot-attempt` (same directory as the existing `CHANNEL_MARKER`, `start_services.sh:255-256`) |
| Content | `<attempt> <epoch>` on one line, e.g. `2 1789420000` |
| Written by | `start_initial_session`, at the top of each attempt |
| Removed by | the same function, on success **and** on exhaustion — a stale marker must not outlive the boot |
| Read by | `agentctl doctor`, **through `docker exec`**, never the bind-mount |

### The directory does not exist yet — this killed the first draft

`WATCHDOG_RUNTIME_DIR` is `/tmp/agent-watchdog` (`start_services.sh:255`), `/tmp` is a **tmpfs**
declared in the compose (`modules/docker-compose.yml.tpl:36-37`, `size=100m`) so it is empty on every
container start, and the only `mkdir -p` for it lives at `start_services.sh:830` — *inside*
`start_session`, after the whole preamble. Writing the marker at the top of attempt 1 therefore
targets a directory that does not exist, and `start_services.sh` runs under `set -euo pipefail`
(`:14`).

The mandated shape, which a contract clause and a mutation must both pin:

```sh
mkdir -p "$WATCHDOG_RUNTIME_DIR" 2>/dev/null || true      # once, before the first attempt
printf '%s %s\n' "$attempt" "$(date +%s)" > "$WATCHDOG_RUNTIME_DIR/boot-attempt" 2>/dev/null || true
rm -f "$WATCHDOG_RUNTIME_DIR/boot-attempt" 2>/dev/null || true
```

Both failure modes are real and opposite: without the `mkdir`, the redirect fails; without the
`|| true`, a failed redirect aborts the boot under `set -e`; with `|| true` but no `mkdir`, the
marker silently never exists on attempt 1 — which is precisely the attempt this feature exists to
explain. FR-021 is satisfied twice over: the explicit `rm -f`, and the tmpfs that empties on restart.

### Reading it (host side)

`/tmp` is a container tmpfs, so the marker is **not** reachable through either bind-mount
(`./:/workspace`, `./.state:/home/agent`). `doctor` must read it with the existing helper
(`scripts/agentctl:332-335`):

```sh
boot_attempt=$(_in_container "$agent" cat /tmp/agent-watchdog/boot-attempt)
case "$boot_attempt" in ''|*[!0-9\ ]*) boot_attempt='' ;; esac
```

A `docker exec` that fails (container restarting, daemon slow) yields an empty value and is treated
as "no marker" — today's behaviour, per FR-021. This is called out because the convention comment at
`scripts/agentctl:315-318` explicitly steers freshness checks toward the bind-mount, which here would
silently never find the file.

### Behaviour, and the guard against masking a permanent failure

- **CANON-H1** (informational, not a failure): `Container health: starting (boot attempt N/3)`
- The `unhealthy` → `_doctor_fail` mapping (`scripts/agentctl:381-390`) is bypassed **only** while the
  marker is present *and* the boot is plausibly fresh.

The freshness guard is not optional. A container that can never bring the channel up exhausts its
attempts, exits, is revived by `restart: unless-stopped`, and starts over — so it is **permanently**
inside an "initial boot" with the marker almost always present. Without a guard, `doctor` would answer
`starting (boot attempt 2/3)` forever for an agent that is dead, which is *worse* than today, where it
at least reports `unhealthy`. Hence the epoch in the marker: when its age exceeds
`MAX_BOOT_ATTEMPTS × (channel window + overhead)`, the bypass lapses and the FAIL returns, naming the
reason. `scripts/agentctl` consults no `RestartCount` today (verified: no occurrence in the file), so
the timestamp is the cheaper of the two viable signals.

**Scope boundary.** The marker describes the *initial* boot only. Watchdog respawns do not write it,
so a channel dying in steady state still reaches `doctor` as the failure it is.

**Note on `CANON-D1`.** That identifier is already taken by `contracts/patch-marker-listing.md` for a
`doctor` patch-check line. This series is therefore `CANON-H*` (health), and no contract may redefine
a `CANON-*` id that another one already owns.

## 6. Patch marker set (US4)

Owned by `docker/scripts/apply_telegram_typing_patch.py` as `ALL_MARKERS` (`:124-132` — verified;
the `:126-132` this and three other artefacts carried was off by two), seven entries today:

| Group | Marker (current) |
| --- | --- |
| typing | `agentic-pod-launcher: typing refresh patch v6` |
| offset | `agentic-pod-launcher: offset persistence patch v1` |
| stderr | `agentic-pod-launcher: stderr-capture patch v1` |
| primary | `agentic-pod-launcher: primary lock patch v1` |
| pending-reply | `agentic-pod-launcher: pending-reply marker patch v1` |
| askq-giveup | `agentic-pod-launcher: askq-guard give-up delivery patch v1` |
| voice | `agentic-pod-launcher: telegram voice roundtrip patch v3` |

New CLI surface on the patcher (US4), which today rejects anything but exactly one argument
(`main()`, `:2029-2033`, `if len(argv) != 2: … return 2`):

| Invocation | Behaviour |
| --- | --- |
| `apply_telegram_typing_patch.py --list-markers` | prints one marker per line, in `ALL_MARKERS` order, to stdout; exits 0; touches no file |
| `apply_telegram_typing_patch.py <server.ts>` | unchanged |
| anything else | unchanged (usage, exit 2) |

`agentctl doctor` consumes that list and carries **no marker literal and no version string** of its
own. If the flag is unsupported (older image), the check reports skipped rather than failing —
matching how it already treats a plugin that is not installed yet (`scripts/agentctl:539`).

**The compatibility probe MUST be content-based, never status-based (MEASURED).** An older patcher
handed `--list-markers` does **not** exit 2: `len(argv) == 2` satisfies the usage guard
(`:2029-2033`), `Path("--list-markers").is_file()` is then False, and that branch logs and
`return 0`s. So the old binary answers *success with no markers*. A probe that trusts the exit status
would read that as "zero groups expected, zero missing" and report a perfectly healthy agent — the
exact false-clean verdict this story exists to eliminate, merely inverted. The probe therefore
requires a non-empty list whose lines carry the `agentic-pod-launcher:` prefix; anything else is
`skipped`.

Counting rule (US4, FR-014): the count must be obtained so that a zero count yields the single
token `0`. The forbidden construct is `$(grep -c … || echo 0)`, which yields `0\n0` because `grep -c`
prints `0` **and** exits 1 on no-match (measured on this host and in busybox/Alpine 3.20).

File set (FR-016): the same glob the boot patcher walks, `"$cache"/*/server.ts`
(`start_services.sh:404-415`) — not `head -1` (`scripts/agentctl:526`).
