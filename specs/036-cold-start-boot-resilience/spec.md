# Feature Specification: Cold-start boot resilience + honest patch diagnostics

**Feature Branch**: `036-cold-start-boot-resilience` (own branch, own PR — operator decision
2026-09-19; see Assumptions)

**Created**: 2026-09-18

**Status**: Draft

**Input**: Two defects found by the live gate (T028) of feature 034, deploying v0.25.0 to `linus` and
`donna` on ferrari. Full measurements in `field-evidence.md`.

## Context

Deploying v0.25.0 to two production agents surfaced defects that have nothing to do with voice. One
of them took `donna` — the operator's personal assistant — down for ~25 minutes in a restart loop,
and was only recovered by a hand-written compose override that is still in place and that weakens a
safety mechanism. The other has been lying to the operator in every `doctor` run for months.

Neither is a regression introduced by 034. Both are pre-existing and were merely exposed by the
first image rebuild in a long time.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - The pre-warm actually warms, and says so honestly (Priority: P1)

An operator upgrades an agent and rebuilds its image. On the next boot, the MCP pre-warm either
leaves every resolvable package genuinely warm, or says precisely why it could not — never a blanket
"will resolve on first use" that hides a hard error behind the same wording as a slow download.

**Why this priority**: This is the root cause of the `donna` outage. Measured: `uv tool install
--python python3 workspace-mcp` exits **rc=2 in 0 seconds** with `error: Executable already exists:
workspace-cli (use --force to overwrite)`. The package is never installed into the managed prefix,
so every boot pays full resolution cost inside Claude Code's initialisation. The 300 s per-package
ceiling (`scripts/lib/mcp_warm.sh:117`) was never the problem — the warm was failing instantly and
reporting it as if it were a slow-download fallback. Feature 030 exists precisely to prevent this
class, and has been silently ineffective for any package whose executable name collides.

**Independent Test**: Host bats, with `uv`/`npm` stubs, asserting that a warm target whose executable
already exists is still warmed successfully, and that a genuinely broken package produces a warn line
that names the failure cause (non-zero exit vs timeout) rather than a single catch-all wording.

**Acceptance Scenarios**:

1. **Given** a package whose executable already exists in the managed prefix, **When** the pre-warm
   runs, **Then** the package ends up warm and no warning is emitted.
2. **Given** a package that cannot be built at all (`mcp-server-tree-sitter` needs `Python.h` in this
   image), **When** the pre-warm runs, **Then** exactly one warning is emitted, it names the package
   and distinguishes "failed" from "timed out", and the boot continues (fail-soft, Principle IV).
3. **Given** a warm run that already succeeded, **When** it runs again, **Then** it is a no-op and
   still returns 0 (preserves the existing idempotency contract, `tests/mcp-warm.bats:176`).

---

### User Story 2 - The channel window is configuration, not a hand-edit (Priority: P1)

An operator can set how long the watchdog waits for the channel plugin from `agent.yml`, like every
other knob, and it survives `--regenerate`.

**Why this priority**: `CHANNEL_HEALTH_TIMEOUT` is read from the workspace `.env`
(`docker/scripts/start_services.sh:739-745`, default 60) but **is rendered nowhere** — not in
`modules/docker-compose.yml.tpl`, not in `modules/env-example.tpl`. It exists only if the operator
types it by hand. That is why recovering `donna` required writing a `docker-compose.override.yml`
instead of changing configuration, and it contradicts Principle I (agent.yml is the single source of
truth; every change must survive `--regenerate`). Feature 029 already established the exact pattern
for this with `claude.mcp_timeout_ms`.

**Independent Test**: Host bats over render + sanitiser + backfill, following the
`tests/mcp-handshake-timeout.bats` mould: a valid value reaches the compose `environment:` block, an
invalid one degrades to the default, and a workspace that predates the field gains it on
`--regenerate` without clobbering an operator's value.

**Acceptance Scenarios**:

1. **Given** an `agent.yml` with the new field set, **When** `--regenerate` runs, **Then** the value
   appears in the rendered compose `environment:` and the container sees it.
2. **Given** an `agent.yml` without the field (pre-036 workspace), **When** `--regenerate` runs,
   **Then** the field is backfilled with the value migrated from the workspace `.env` when that
   holds a valid integer, and with the default only when there is nothing to migrate; an existing
   value in `agent.yml` is never overwritten.
3. **Given** a workspace whose `.env` already carries `CHANNEL_HEALTH_TIMEOUT` by hand, **When**
   `--regenerate` runs, **Then** that value is carried into `agent.yml` and the operator is told the
   migration is done and the `.env` line can be removed — naming the key, never printing any value.
   The agent's effective behaviour is unchanged across the upgrade, which is the whole point.
4. **Given** an invalid value (empty, negative, zero, non-numeric), **When** rendering, **Then** the
   effective value is the default and rendering does not fail.

---

### User Story 3 - A slow first boot does not kill the container (Priority: P2)

When the channel plugin is slow to appear on the very first launch after a rebuild, the agent retries
before giving up, instead of exiting immediately and bouncing through Docker's restart policy.

**Why this priority**: Measured asymmetry — a failed `verify_channel_healthy` during a **watchdog
respawn** is absorbed (`start_services.sh:1269`: `start_session || log "WARN: respawn failed, watchdog
will retry in 2s"`), but the same failure at **initial boot** hits `main()` at `:1279-1282`, which
logs `ERROR: initial tmux session failed to start` and calls `exit 1` outright — bypassing the crash
budget entirely. The container dies and is revived by `restart: unless-stopped`, discarding the
container's writable layer, which is exactly where the freshly-warmed uv/npm caches live. Each
restart therefore throws away the progress the previous attempt made: the loop cannot converge on its
own. That circularity is what forced manual intervention on `donna`.

**Why it is P2, not P1**: US1 and US2 together already prevent the observed outage. This one removes
the failure mode's teeth for the general case, and it touches the watchdog — an area with an
expensive regression precedent (the bridge watchdog reverted in `ebfe35f`), so it carries its own
risk budget.

**Independent Test**: Host bats sourcing `start_services.sh` with `START_SERVICES_NO_RUN=1` and a
stubbed `pgrep`/`sleep` (existing seam `_stub_pgrep_after`, `tests/start-services-watchdog.bats:357`),
asserting the retry count and that exhaustion still exits non-zero.

**Acceptance Scenarios**:

1. **Given** the channel plugin appears on the second attempt, **When** the container boots, **Then**
   the session ends up healthy and the container never exits.
2. **Given** the channel plugin never appears, **When** the retries are exhausted, **Then** the
   container still exits non-zero so Docker's restart policy escalates as it does today.
3. **Given** a boot retry, **When** it happens, **Then** each attempt is logged distinguishably
   (attempt N of M) so the operator can tell a retry from a restart in the journal.

**Explicitly out of scope for this story**: any automated detection of the "bun alive but MCP
notifications dropped" case. `CLAUDE.md` forbids re-adding it without first solving the
false-positive problem that killed sessions every ~2 minutes (`ebfe35f`).

---

### User Story 4 - `doctor` tells the truth about plugin patches (Priority: P2)

`agentctl doctor` reports the plugin patch state correctly: no false warnings on a healthy agent, and
a real warning when a patch group is genuinely missing.

**Why this priority**: Two independent defects in one block (`scripts/agentctl:523-543`), both
confirmed:

1. `grep -c PATTERN FILE 2>/dev/null || echo 0` yields `0\n0` when the count is zero, because
   `grep -c` exits 1 on no-match while still printing `0`. That breaks `[ "$typing_v3" -ge 1 ]` at
   `:533` with `integer expression expected` and falls through to the warning branch.
2. The check greps for `typing refresh patch v3` while the live marker is **v6**
   (`docker/scripts/apply_telegram_typing_patch.py:106`), and knows only 4 of the patcher's **7**
   marker groups — it has never been updated since its original commit (`1313ae7`) while the patcher
   grew from 1 to 7 groups.

Fixing only the first still leaves a permanent false warning. The check also inspects only the first
`server.ts` (`head -1`, `:526`) while the patcher iterates over all of them
(`start_services.sh:404-415`).

**Independent Test**: Host bats with a docker shim that returns a plugin path and replicates
`grep -c`'s rc=1-on-zero behaviour — today the check has **no test at all**, so any test is net new
coverage. The regression oracle is that a fully-patched agent produces a pass, and an agent missing
one group produces a warning that names that group.

**Acceptance Scenarios**:

1. **Given** an agent whose `server.ts` carries all current patch groups, **When** `doctor` runs,
   **Then** it reports a pass and exits 0 with no warning about patches.
2. **Given** an agent missing one patch group, **When** `doctor` runs, **Then** it warns and names
   the missing group.
3. **Given** the patcher later bumps a marker version, **When** nothing else changes, **Then**
   `doctor` keeps working without edits — it must not hardcode version strings.

### Edge Cases

- A warm target whose executable collides with a package installed by the baked catalogue
  (`docker/Dockerfile:122-124` installs `mcp-atlassian`, `mcp-server-fetch`, `mcp-server-time`):
  forcing the overwrite must not leave the baked tool unusable.
- An agent with zero uvx/npx MCPs: the warm must stay a silent no-op.
- A plugin cache holding two version directories: `doctor` must not pass because it happened to read
  the inactive one.
- An agent whose notification channel is not telegram: the patch check must stay skipped as today.
- Local (non-docker) mode: the channel window does not exist there; the new field must be inert and
  must not leak `CHANNEL_HEALTH_TIMEOUT` into local runtime artefacts (the FR-011 oracle of 032 is
  the precedent).

## Requirements *(mandatory)*

### Functional Requirements

**Pre-warm (US1)**

**Scope note (added 2026-09-19).** FR-001 and FR-002 govern the **docker boot pre-warm**
(`mcp_warm_run`, called from `start_services.sh::pre_warm_mcps`). They do **not** extend to local
mode's provisioner (`modules/local-bootstrap.sh.tpl:126`), which installs uv tools on the operator's
own machine and keeps both the missing `--force` and the catch-all wording. The reason is that the
defect is specific to the container lifecycle: there is no image rebuild locally, so uv's two state
directories never fall out of sync and no dangling links accumulate. Stated explicitly because the
requirement text is otherwise mode-neutral and a `grep` for the forbidden wording still hits
`local-bootstrap.sh.tpl` after this feature ships — that hit is expected, not a miss.

- **FR-001**: The pre-warm MUST leave a resolvable package warm even when its executable name is
  already present in the managed prefix.
- **FR-002**: The pre-warm MUST distinguish, in its log line, a package that failed from one that
  exceeded the time ceiling, **and from one whose runtime is not on PATH at all**. The current single
  wording (`will resolve on first use`) MUST NOT be the only signal. The three classes are fixed as
  CANON-W1 (failed, with the exit code), CANON-W2 (timed out, with the ceiling) and CANON-W3
  (runtime unavailable); a missing runtime still counts toward the summary's `K failed` bucket,
  which is today's arithmetic and does not churn.
- **FR-003**: The pre-warm MUST remain fail-soft (always return 0) and idempotent, preserving the
  contracts already fixed by `tests/mcp-warm.bats`.
- **FR-004**: Overwriting an existing executable MUST NOT break a tool installed by the image's baked
  catalogue.

**Channel window as configuration (US2)**

- **FR-005**: The channel health timeout MUST be settable from `agent.yml` and MUST survive
  `--regenerate`.
- **FR-006**: The value MUST be sanitised host-side (positive integer; anything else degrades to the
  documented default) and delivered to the container by the rendered compose `environment:` block,
  following the `claude.mcp_timeout_ms` precedent of feature 029.
- **FR-007**: A workspace that predates the field MUST gain it on `--regenerate` via a presence check
  (`has()`), never a `//` default that would collapse a legitimate value.
- **FR-008**: When a workspace `.env` already defines the same key by hand, `--regenerate` MUST
  **migrate** that value into `agent.yml` and then tell the operator that the migration happened and
  that the `.env` line can be removed — naming the key and never printing its value. The notice is
  CANON-C2 and announces a completed migration, not a pending conflict; a bare warning that left the
  value behind would drop the agent to the default on the next `up`.
- **FR-009**: The runtime default MUST remain 60 s, and the existing risk warning for values at or
  past the crash-budget threshold MUST keep firing.

**Boot retry (US3)**

- **FR-010**: A failed channel verification during the **initial** boot MUST be retried a bounded
  number of times before the container exits.
- **FR-011**: Exhausting the retries MUST still exit non-zero, preserving today's escalation through
  Docker's restart policy.
- **FR-012**: Each boot attempt MUST be logged distinguishably so a retry is not mistaken for a
  container restart.
- **FR-013**: No new automated detection of a silently-stuck channel may be introduced.

**Patch diagnostics (US4)**

- **FR-014**: `doctor` MUST compute patch-group counts without the `grep -c … || echo 0` construct,
  and MUST NOT emit a shell error under any count.
- **FR-015**: `doctor` MUST check the patcher's current set of marker groups, derived from a single
  source shared with the patcher rather than duplicated version literals.
- **FR-016**: `doctor` MUST inspect the same plugin file(s) the boot patcher targets.
- **FR-017**: The documentation that describes this known false negative
  (`docs/creating-an-agent.md:452-460`) and the stale marker counts (`docs/state-layout.md:199`) MUST
  be corrected.

**Boot-aware diagnostics (US3/US4 seam — operator decision 2026-09-19)**

- **FR-020**: While the initial boot is retrying, `doctor` MUST report the agent as starting, naming
  the attempt, instead of mapping the container's `unhealthy` state to a hard failure.
- **FR-021**: Outside an initial boot, `doctor`'s treatment of an `unhealthy` container MUST be
  unchanged, and the boot marker MUST NOT survive the boot that created it.

**Cross-cutting**

- **FR-018**: Changes MUST hold on bash 3.2 and 5.x, pass `shellcheck -S error`, and ship with host
  bats coverage (Principle III).
- **FR-019**: Because US1 and US3 touch image-baked code, DOCKER_E2E coverage is REQUIRED and MUST be
  run for real on this host (precedent 033/034), not deferred.

### Key Entities

- **Warm target**: a `(runtime, package)` pair derived from `.mcp.json` by `mcp_warm_targets`; its
  outcome is warm / failed / timed out / unavailable (the runtime is not on PATH).
- **Channel window**: the number of seconds the watchdog waits for `bun server.ts`; today an
  undeclared env var, after this feature an `agent.yml` field with a rendered delivery path.
- **Patch group**: one of the patcher's seven marker-identified transforms of the Telegram plugin;
  `doctor` consumes the set, the patcher owns it.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: On an agent with a cold cache and an executable-name collision, the boot pre-warm
  reports zero failures for packages that are actually resolvable — measured on `donna`, whose
  `workspace-mcp` warn disappears.
- **SC-002**: A package that genuinely cannot build still produces exactly one warning naming it, and
  the boot proceeds — `mcp-server-tree-sitter` remains the live example.
- **SC-003**: After a full rebuild and recreate of an agent with 15 MCP servers, the channel reaches
  `channel plugin healthy` without manual intervention and without any compose override.
- **SC-004**: The temporary `docker-compose.override.yml` on `donna` can be removed and its value
  expressed in `agent.yml`, with a `--regenerate` reproducing the same effective configuration.
- **SC-005**: `agentctl doctor` on a fully-patched agent exits 0 with no patch warning and no shell
  error text in its output.
- **SC-006**: `doctor` warns, naming the group, on an agent where one patch group is absent.
- **SC-007**: `bats tests/` reports the **same total test count** on bash 3.2.57 and 5.3.15, the
  3.2.57 arm is N/0, and the 5.x arm differs only by the named `askq-guard-config.bats` contention
  flake, which must be re-run in isolation and shown green. (The earlier wording, "byte-identically",
  was unmeetable: the feature's own baseline is 1412/0 vs 1411/1. A gate whose pass condition has to
  be reinterpreted at reading time is a gate that has stopped catching things.) And `shellcheck -S
  error` returns 0.
- **SC-008**: Every changed behaviour has a mutation spot-check: reverting the fix turns at least one
  named test red.

## Assumptions

- **Own branch, own version.** The 2026-09-18 decision was to share the 034 branch; the operator
  **revised it on 2026-09-19** once 034 was finished, gated and already deployed to both production
  agents. 034 therefore shipped alone as **0.25.0** (commit `a1fa449`, PR #96) and this feature lands
  on `036-cold-start-boot-resilience` with its own **0.26.0** bump, restoring the repo's precedent
  (feature 021 sent its `doctor` portability fixes to a separate PR for the same reason). The branch
  is cut from 034's head rather than from `main`, because both features touch `setup.sh`,
  `modules/docker-compose.yml.tpl` and the patcher; it is rebased onto `main` once #96 merges.
- **Number 036, not 035.** 035 is reserved by a standing operator decision (2026-09-15) for the
  real-time "recepcionista" feature over ElevenLabs Agents.
- The exact `agent.yml` key for the channel window, and the exact mechanism by which `doctor` shares
  the marker list with the patcher, are design decisions deferred to `plan.md`.
- `linus` and `donna` remain available on the LAN for the live gate; both are already at v0.25.0, so
  the gate measures only the deltas of this feature.
- Fixing the warm does not change what Claude Code does with MCP handshakes; `MCP_TIMEOUT` (feature
  029) stays as is.
