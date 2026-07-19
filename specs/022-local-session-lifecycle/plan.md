# Implementation Plan: Remote Control session lifecycle in local mode

**Branch**: `022-local-session-lifecycle` | **Date**: 2026-07-18 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/022-local-session-lifecycle/spec.md`

## Summary

A local-mode agent goes silently unreachable because it re-announces a session
identity the server side has already ended. Phase 0 established the causal chain by
reading Claude Code's own logic and measuring it on live hardware, and it overturned
two plausible designs on the way.

**Root event**: with `--spawn=session` the process exits *when its session ends* — by
design. `Restart=always` revives it 12 s later, the new process finds a pointer whose
writer is dead, and reuses an **already-ended** session. Nothing creates a fresh one.
One bad reuse contaminates every subsequent start until the pointer is removed or the
vendor's 4 h mtime TTL expires. The reboot in the incident report was not the cause;
it merely propagated an already-poisoned pointer. **Ending a conversation from the
phone is enough to poison the agent.**

**Approach**: give the launcher the one discriminator the pointer lacks — *why* the
previous process stopped — and act on it once per service start.

- `ExecStopPost=` records systemd's own verdict (`$SERVICE_RESULT`, `$EXIT_CODE`).
- A second `ExecStartPre=` consumes that marker before `claude remote-control` runs.
  Process exited on its own → the session ended → clear the pointer. Process was
  killed → the session may still be live → leave it alone.

That mapping is causal, not heuristic: under `--spawn=session` the process exits
*because* the session ended. It is also **measured on production hardware**: a
`systemctl restart` of mclaren's agent reused the pointer, the backend re-granted the
same environment, and the operator confirmed the agent stayed reachable on the same
link. Reuse is correct for an interrupted process; only an *ended* session must be
discarded. This is exactly FR-014, and it is why "always clear at boot" would be a
regression rather than a cheap safety net.

Two designs were tried and rejected **by evidence**, both recorded in research.md so
they are not re-derived:

1. *Clear the pointer when its writer process is dead.* Wrong: Claude Code uses a
   live writer to mean "register a fresh environment" and a **dead** writer to mean
   "reuse". A dead writer is the normal post-restart state, so this fires on every
   start — the "always renew" degeneration SC-009 exists to forbid.
2. *Switch to `--spawn=same-dir`* (the CLI default). Measured on mclaren: `same-dir`
   reuses the pointer identically, so it does not stop reuse — and because its process
   outlives its sessions, it **destroys the exit-cause signal** the fix depends on.
   Adopting it would trade a signal we have for one we do not.

US2 makes the state visible (`agentctl doctor`) and, in the same change, removes an
existing false alarm: the local doctor still greps the journal for
`session url|connected|polling` (`scripts/agentctl:1280-1285`), a predicate the
healthcheck already retired as a measured false positive
(`modules/local-healthcheck.sh.tpl:50-64`). Leaving it while adding a good check would
violate FR-006. US3 makes the session name configurable from `agent.yml` with a
de-duplicating default.

## Technical Context

**Language/Version**: `bash` (POSIX-ish, must run on macOS stock bash 3.2 — no
bash-4-only constructs), plus `jq` on the agent host for JSON state.

**Primary Dependencies**: systemd (`ExecStartPre`, `ExecStopPost`, and its
`$SERVICE_RESULT`/`$EXIT_CODE`/`$EXIT_STATUS` contract); `yq` v4+ at render time;
`jq` at runtime (guarded — degrade to "cannot determine", never assume).

**Storage**: two JSON files. `bridge-pointer.json` is **Claude Code's**, read-only to
us except for the rename that clears it. `<ws>/scripts/heartbeat/session-exit.json` is
ours, alongside the existing `qmd-index.json` / `wiki-graph.json` / `*-backup.json`.

**Testing**: `bats` on the host with **no systemd and no Docker** (Principle III) —
systemd is simulated by invoking the rendered hook scripts directly with the
environment variables systemd would set. Plus a hardware gate on mclaren for what only
real systemd proves. Baseline measured this session: **1052 ok / 0 not ok / 20 skips**.

**Target Platform**: Linux + systemd (Debian 13 trixie, aarch64, verified on mclaren);
Claude Code 2.1.185 on the agent host. Local mode only.

**Project Type**: bash CLI + template/render launcher. No application code.

**Performance Goals**: N/A. The boot hook must be negligible against service start and
must never block it.

**Constraints**: docker mode byte-unchanged (Principle II / FR-011); the 021 unit
invariants intact (both `EnvironmentFile` lines and their order, the leading `-`, the
existing `ExecStartPre`); every boot hook exits 0 unconditionally; no recurring
supervision (FR-007); no secret values in logs or diagnostics (FR-013).

**Scale/Scope**: one unit template, two new rendered hook scripts, one new shared lib,
one new doctor check plus one removed, one new `agent.yml` field. Roughly 13 files.

## Constitution Check

*GATE: evaluated before Phase 0 and re-evaluated after Phase 1 design. Result: 6/6 PASS,
no violations, Complexity Tracking empty.*

- [x] **I. Single Source of Truth** — PASS. Both hooks are rendered from new `modules/*.tpl`
  into `scripts/local/` by the same `regenerate()` block that renders the 021 hook
  (`setup.sh:2223-2262`), so they survive `--regenerate`. `deployment.session_name` lives in
  `agent.yml`, is backfilled for pre-022 workspaces (pattern of `deployment.mode`,
  `setup.sh:1953-1962`) and persisted when defaulted (pattern of `_persist_claude_cli`,
  `setup.sh:122-132`). Nothing is hand-edited. The runtime artifact the feature *removes*
  (`bridge-pointer.json`) is third-party state, not a derived file.
- [x] **II. Least-Privilege (NON-NEGOTIABLE)** — PASS / N/A. Local-mode only; no `docker/`
  file is touched and no compose capability changes. Guarded by the existing docker-render
  assertions. The new hooks run as `User={{OPERATOR_USER}}`, never root, and require no
  privilege the unit does not already have.
- [x] **III. Test-First, Host-Runnable** — PASS. Every behavior is host-testable without
  systemd: the hooks are plain scripts invoked with the environment systemd would provide,
  and the doctor check follows the established `tests/agentctl-local.bats` stub pattern. The
  new lib guards initialization with `BASH_SOURCE` and has no side effects on source.
  `shellcheck -S error` gate applies. No `DOCKER_E2E` work — docker is untouched.
- [x] **IV. Idempotent, Fail-Silent Lifecycle** — PASS. The exit marker is a content-bearing
  file consumed once, never an mtime comparison. Both hooks carry the 021 double belt: the
  `-` prefix on the unit directive **and** an unconditional `exit 0`. Re-running against an
  already-healthy agent is a no-op (an absent pointer means nothing to do), satisfying
  FR-004. Unknown or unparseable state degrades to "cannot determine", never a crash.
- [x] **V. Workspace-Is-the-Agent** — PASS. The marker lives under
  `<ws>/scripts/heartbeat/`, the established local-mode state directory. Deliberately **not**
  under `.state/`, and explicitly never named `.env`: `backup_identity.sh:72,152-154`
  encrypts that path and would start pushing this to the fork. Session and environment
  identifiers are operational identifiers shown only to the owning operator (FR-013); no
  secret is read or logged. The three backup primitives are untouched.
- [x] **VI. Reproducible, Pinned Dependencies** — PASS. No new dependency and no new pin.
  `jq` is already a documented local-mode requirement, hard-gated at
  `modules/local-login.sh.tpl:37`, and is guarded at every use site anyway. User-facing
  change → `CHANGELOG.md` + `VERSION` bump (0.13.0 → 0.14.0).

**FR-007 (the constitutional gate at `constitution.md:192`)** — satisfied structurally, not
by mitigation. The reverted bridge watchdog (`ebfe35f`) failed because it ran *recurrently*
and inferred liveness from tmux pane scraping, killing healthy sessions every ~2 minutes.
This mechanism runs **once per service start**, never against a running session, and reads a
verdict systemd itself produced rather than inferring one from output. The documented failure
mode cannot occur: there is no recurring actor.

## Project Structure

### Documentation (this feature)

```text
specs/022-local-session-lifecycle/
├── plan.md                                    # This file
├── research.md                                # Phase 0 — measured, includes two rejected designs
├── data-model.md                              # Phase 1
├── quickstart.md                              # Phase 1 — host validation + mclaren hardware gate
├── contracts/
│   ├── session-pointer-hygiene.md             # Phase 1 — mechanism contract + scenarios S1..Sn
│   └── session-name-resolution.md             # Phase 1 — US3 contract + scenarios N1..Nn
├── checklists/requirements.md                 # From /speckit-specify — PASS
└── tasks.md                                   # Phase 2 — /speckit-tasks, not created here
```

### Source Code (repository root)

```text
modules/
├── systemd-remote-control.service.tpl         # CHANGED: +ExecStopPost, +2nd ExecStartPre, --name
├── local-session-exit.sh.tpl                  # NEW: ExecStopPost — records systemd's verdict
├── local-session-check.sh.tpl                 # NEW: 2nd ExecStartPre — consumes it, clears pointer
└── local-killswitch.sh.tpl                    # CHANGED: second identity composition (US3)

scripts/
├── lib/session_pointer.sh                     # NEW: single source for hook + doctor. NOT mirrored
│                                              #      to docker/scripts/lib (FR-011)
└── agentctl                                   # CHANGED: +_local_session_doctor,
                                               #          -false-positive journal grep (:1280-1285)

setup.sh                                       # CHANGED: render both hooks; session_name default,
                                               #          backfill, persist
scripts/lib/schema.sh                          # CHANGED: deployment.session_name optional-nonempty

tests/
├── session-pointer.bats                       # NEW: the lib, in isolation
├── local-session-hooks.bats                   # NEW: both rendered hooks, systemd simulated by env
├── agentctl-local.bats                        # CHANGED: doctor check + removal of the old one
├── local-render.bats                          # CHANGED: ExecStart line, new directives
├── local-install-service.bats                 # CHANGED: inline fixture
├── schema.bats                                # CHANGED: fixture gains the field
└── fixtures/sample-agent-with-vault.yml       # CHANGED: deployment.session_name

docs/heartbeatctl.md                           # CHANGED: doctor check table (also closes 021's
                                               #          missing D1-D4 rows)
CHANGELOG.md, VERSION                          # 0.13.0 → 0.14.0
```

**Structure Decision**: the feature follows the seam 021 established and validated —
behavior that must run at boot lives in a `modules/local-*.sh.tpl` rendered into
`<ws>/scripts/local/`, invoked from the unit with a `-` prefix; detection logic shared
between that hook and `agentctl doctor` lives in `scripts/lib/`. 021 paid the price of
duplicating detection between its hook and `_local_secrets_doctor`; this feature
single-sources it in `session_pointer.sh` from the start. Nothing is mirrored into
`docker/scripts/lib/`, so no `COPY` line and no `DOCKER_E2E` gate are needed.

## Phase 2 note — what `/speckit-tasks` must preserve

- **Test-first ordering is not optional here** (Principle III): the scenario tables in
  both contracts are the test list. Write them RED before the implementation.
- **The unit-template tasks must assert line order numerically**, the way
  `tests/local-render.bats:106-118` does for the 021 `EnvironmentFile` pair. Adding
  directives between them is safe; reordering is not.
- **`tests/local-render.bats:65` is broken on purpose** (the `--name` value changes) and
  must be updated, not worked around.
- **Bats hazard**: a negated `[[ ]]` or `!`-pipeline mid-body does not fail a test in this
  suite. Put load-bearing negatives last as `if … grep -q …; then false; fi`
  (`tests/agentctl-local.bats:407`), never as `! [[ … ]]` (the dead assertions at
  `:120, 148, 206, 274`).
- **A mutation spot-check is expected** before the PR, per 021's habit: break each new
  predicate deliberately and confirm a test goes red.
- **The hardware gate on mclaren must install and restart the unit explicitly.**
  `--regenerate` reinstalls only when `deployment.install_service` is true *and* `sudo -n`
  succeeds, and **nothing in `setup.sh` ever restarts the session unit** — confirmed live
  today, where mclaren's installed unit was still running a `--name` its template no longer
  contained.

## Complexity Tracking

> No constitutional violations. Table intentionally empty.
