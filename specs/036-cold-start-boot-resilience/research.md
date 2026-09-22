# Research — 036 cold-start boot resilience

Phase 0. Every decision below is anchored either to code read in the tree (path:line) or to a
measurement taken on the live `donna` container on 2026-09-18. Raw incident data is in
`field-evidence.md`.

## D1 — Root cause of the pre-warm failure (MEASURED; refutes the first hypothesis)

**First hypothesis, refuted.** "The per-package warm timeout is too short for a heavy package like
`workspace-mcp`." False: the ceiling is `MCP_WARM_TIMEOUT` = **300 s** (`scripts/lib/mcp_warm.sh:117`)
and the failure does not consume it.

**Measured, inside `donna`:**

```
$ uv tool install --python python3 workspace-mcp     # the exact command mcp_warm_run runs (:98)
rc=2  elapsed=0s
error: Executable already exists: workspace-cli (use `--force` to overwrite)

$ uv tool install --python python3 mcp-server-git
rc=2
error: Executable already exists: mcp-server-git (use `--force` to overwrite)
```

**Why the executable already exists.** uv splits its state across two directories:

| uv state | Env var | Value in this image | Lifecycle |
| --- | --- | --- | --- |
| tool prefix (the installed package tree) | `UV_TOOL_DIR` | `/opt/uv/tools` (`docker/Dockerfile:118`) | **in the image** — discarded on every rebuild/recreate |
| executable links | `UV_TOOL_BIN_DIR` | **unset** → uv defaults to `~/.local/bin` = `/home/agent/.local/bin` | **on the bind-mount** (`.state/` is mounted at `/home/agent`) — survives everything |

Measured state after the rebuild:

```
$ ls /home/agent/.local/bin
mcp-server-git  workspace-cli  workspace-mcp

$ ls -la /home/agent/.local/bin/mcp-server-git
… -> /opt/uv/tools/mcp-server-git/bin/mcp-server-git      # target no longer exists

$ uv tool list
mcp-atlassian v0.23.1
mcp-server-fetch v2026.8.18
mcp-server-time v2026.8.18                                 # only the baked catalogue
```

The links were created 2026-09-12. The rebuild wiped `/opt/uv/tools`, leaving them **dangling**, and
`uv tool install` refuses to overwrite an existing executable. So:

- uv believes the tool is not installed (empty prefix) **and** that its executable is taken.
- The warm fails instantly, permanently, for every package ever installed before a rebuild.
- The dangling links stay behind and block every later `uv tool install` for the same executable
  name. (An earlier draft of this line said they "stay on `PATH`". **Measured and false**: the
  Dockerfile sets no `ENV PATH`, the live container's `PATH` is
  `/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin`, and `~/.local/bin` was never on
  it. Nothing ever invoked those executables by name — MCP servers are launched as `uvx <pkg>`. The
  links' only observable effect was blocking installs, which is exactly why DD-1 rejects adding the
  new bin dir to `PATH`.)

This is a structural defect in the image's uv layout, not a tuning problem. It has been latent since
feature 030 shipped; the only reason it surfaced now is that `donna` had not been rebuilt in a long
time.

**Decision.** Fix the split, then add a belt:

1. Bake `UV_TOOL_BIN_DIR=/opt/uv/bin` next to `UV_TOOL_DIR` so both halves of uv's state share the
   image's lifecycle. **Do not touch `PATH`** — see DD-1: `~/.local/bin` was never on it, so a new
   bin dir on `PATH` would be surface with no consumer.
2. Sanitise, idempotently at boot, any dangling link left in `~/.local/bin` that points into
   `/opt/uv/tools` — otherwise existing agents keep the broken links forever, and each one keeps
   blocking the install of the package that owns its name.
3. Pass `--force` on the install so a residual collision can never re-block a warm.

**Alternatives considered.** (a) `--force` alone: fixes the symptom, leaves uv's state split across
two lifecycles, so the next rebuild recreates dangling links until the warm runs. (b) Move the tool
prefix onto the bind-mount instead: makes uv state survive rebuilds, but puts a multi-hundred-MB
package tree inside `.state/`, which is the backup/restore unit (Principle V) — rejected. (c) Warm
with `uvx` instead of `uv tool install`, matching what the MCP command line actually invokes: it
populates the download cache but installs no tool, so nothing persists in the prefix and each boot
re-resolves; rejected as the primary mechanism, though it explains why a manual `uvx … --help` looked
healthy during the incident while `uv tool install` was failing.

## D2 — Honest warm reporting

Today every failure prints the same line (`mcp_warm.sh:126`):
`mcp_warm: warn: uvx workspace-mcp failed (will resolve on first use)`.
That wording is a promise ("it will resolve later") that was false for the whole incident, and it
erases the distinction between three very different outcomes.

**Decision.** The warn line must name the outcome class: a non-zero exit from the installer, a
timeout that hit the ceiling, or a missing runtime. The existing summary line
(`warm cache: N/M warm, K failed`) stays. No test currently pins either string
(`tests/mcp-warm.bats` has no oracle on the wording), so this is free to change, and the new wording
gets its own oracle so the next incident is diagnosable from the boot log alone.

**Out of scope.** Making a genuinely unbuildable package build. `mcp-server-tree-sitter` needs a
library providing `Python.h` and fails with `rc=1` warm or cold; it must keep warning once and the
boot must keep going (Principle IV, fail-soft).

## D3 — Where the channel window lives

`CHANNEL_HEALTH_TIMEOUT` is read at call time from the environment
(`docker/scripts/start_services.sh:739-745`, default 60, validated `^[0-9]{1,6}$` and `> 0`) and is
rendered by **nothing**: not `modules/docker-compose.yml.tpl`, not `modules/env-example.tpl`. It
reaches the container only through `env_file: ./.env` if the operator typed it there. Feature 026
chose that deliberately ("override by env var, not agent.yml"), but the live gate showed the cost:
recovering a flapping agent required a hand-written `docker-compose.override.yml`, which is exactly
the class of change Principle I forbids (a derived, hand-edited artefact that no `--regenerate`
reproduces).

**Decision.** Promote it to `agent.yml` following the `claude.mcp_timeout_ms` mould of feature 029:
a sanitiser in `setup.sh` (positive integer, else the 60 default), a `has()` backfill, and an
unconditional line in the compose `environment:` block. The field name is decided in `plan.md`; it
belongs under a docker/watchdog-scoped key rather than `claude:`, because its consumer is the
container's watchdog, not the `claude` binary.

**Consequence that must be handled, not discovered later.** In compose, `environment:` **wins over**
`env_file`. An agent like `donna`, whose `.env` carries `CHANNEL_HEALTH_TIMEOUT=120` today, would
silently fall back to the rendered value. The launcher can already read a workspace `.env` safely
without sourcing it (`scripts/lib/env_file.sh::env_file_get`, feature 021), so `--regenerate`
**migrates the value itself** — it seeds `agent.yml` from the `.env` when that holds a valid integer
— and then tells the operator the migration is done and the `.env` line can be removed, naming the
key and never printing the value. (An earlier draft had `--regenerate` merely *warn* and leave the
migration to the operator. That was corrected by the adversarial review, finding #2: a bare warning
plus an unconditionally rendered default would have dropped `donna` from 120 and
`rodri-cenco-admin` from 120 to 60 on their next `up` — re-creating, in agents outside the live
gate, the very cold-cache-plus-short-window combination that caused the outage.)

## D4 — The boot-path asymmetry

Measured in the code, and it explains why the loop could not converge:

| Path | Code | Behaviour on a failed `verify_channel_healthy` |
| --- | --- | --- |
| Watchdog respawn | `start_services.sh:1269` | `start_session \|\| log "WARN: respawn failed, watchdog will retry in 2s"` — absorbed, retried on the next 2 s tick |
| **Initial boot** | `start_services.sh:1279-1282` | `log "ERROR: initial tmux session failed to start"` + **`exit 1`** — container dies immediately, no crash-budget accounting |

The crash budget (`MAX_CRASHES=5`, `WINDOW=300`, `:258-259`) only ever sees watchdog respawns. So at
boot there is no budget, no retry, and the container exits into `restart: unless-stopped`
(`modules/docker-compose.yml.tpl:38`). Each restart discards the container's writable layer — where
the freshly-warmed uv/npm caches live — so the next attempt starts colder than the last. The loop
actively destroys its own progress.

**Decision.** Bound retries at the initial boot before exiting, log each attempt distinguishably, and
keep the final exit non-zero so Docker's escalation is preserved. The retry count and spacing are set
in `plan.md` against two existing constraints: the compose healthcheck's `start_period: 60s`
(`docker-compose.yml.tpl:46-51`) and the crash-budget arithmetic that
`warn_if_channel_timeout_risky` already encodes (`:753-760`, threshold 65 s derived from
`WINDOW/(MAX_CRASHES-1)-5`).

**Explicitly forbidden by `CLAUDE.md`, and honoured here:** no automated detection of the
"bun alive but MCP notifications dropped" case. That was reverted in `ebfe35f` for killing healthy
sessions every ~2 minutes, and nothing in this feature reintroduces it.

## D5 — Why `doctor` lies, and how to stop it structurally

Two independent defects in `scripts/agentctl:523-543`, both confirmed:

**(a) The `0\n0` count.** `grep -c` prints `0` on stdout **and exits 1** when there is no match, so
`count=$(… grep -c … || echo 0)` appends a second `0`. Reproduced on this host and in busybox
(Alpine 3.20, the container's runtime). The resulting `[ "$typing_v3" -ge 1 ]` at `:533` errors with
`integer expression expected` and falls through to the warning branch. `agentctl` runs under
`set -u -o pipefail` without `-e` (`:20`), so the error is printed but not fatal — it just produces a
wrong answer and a non-zero `doctor` exit.

**(b) Version drift.** The check greps `typing refresh patch v3`; the live marker is
`typing refresh patch v6` (`docker/scripts/apply_telegram_typing_patch.py:106`). The other three
counts it reports (`offset=4 stderr=1 primary=2`) match the golden fixtures exactly, which is
independent proof that the file was correctly patched and the reader is what is wrong. The block has
not been touched since its original commit (`1313ae7`) while the patcher grew from 1 to **7** marker
groups; `doctor` still knows 4, and is blind to pending-reply (028), askq-giveup (031) and voice
(032→034).

Fixing (a) alone would still leave a permanent false warning, because (b) guarantees a zero count.

**Decision.** Remove the duplicated knowledge instead of updating it: the patcher owns `ALL_MARKERS`
(`apply_telegram_typing_patch.py:124-132`) and already has a `main(argv)` entry point
(`:2029`, `:2123-2124`), so it gains a flag that prints its current marker set, and `doctor` consumes
that list rather than carrying literals. Same spirit as the 023 fix: remove the category of error
rather than correct this instance of it. Counting is rewritten so a zero count cannot produce
two lines, and the check inspects the same file set the boot patcher iterates over
(`start_services.sh:404-415` walks `"$cache"/*/server.ts`; `doctor` reads only `head -1`, `:526`).

**Coverage note.** The check has **no test at all** today — grep over `tests/*.bats` for its strings
returns nothing, and every existing docker shim returns empty stdout, so the check short-circuits to
`_doctor_skip` and never reaches the comparison. Any test added here is net-new coverage, and the
shim must replicate `grep -c`'s rc=1-on-zero to be a real oracle.

**Documentation drift to correct in the same pass.** `docs/creating-an-agent.md:452-460` documents
this as a known false negative but misattributes it to a "typing-tick count" parse and tells the
operator to grep for `v4`; `docs/state-layout.md:199` still says 9 groups and v4.

## D6 — Test tiers

- **Host bats** covers: warm behaviour with `uv`/`npm` stubs (existing seam, `MCP_WARM_STUB_RC` in
  `tests/start-services-warm.bats:20-31`), the render/sanitiser/backfill of the new field
  (mould: `tests/mcp-handshake-timeout.bats`), the boot retry via the existing `_stub_pgrep_after`
  seam (`tests/start-services-watchdog.bats:357-371`), and the `doctor` check via a docker shim.
- **DOCKER_E2E is required and will be run for real** (precedent 033/034, this host has Docker):
  `scripts/lib/mcp_warm.sh` is mirrored into the image at build (`setup.sh:1646,1668-1670`,
  `docker/Dockerfile:259`), `start_services.sh` is image-baked, and the `UV_TOOL_BIN_DIR` change
  touches the Dockerfile itself — none of which a host test can exercise.
- **Live gate** on `donna` (the agent that exhibits the defect) and `linus`: the real oracles are
  SC-001, SC-003 and SC-004 — a rebuild and recreate that reaches `channel plugin healthy` with no
  override in place.

## Open questions deferred to `plan.md`

1. Exact `agent.yml` key and section for the channel window.
2. Retry count and spacing at the initial boot.
3. Flag name and output shape for the patcher's marker listing.
4. Whether the dangling-link sanitiser lives in `mcp_warm.sh` (runs with the warm) or in
   `start_services.sh` boot side-effects (runs even when no warm target exists).
