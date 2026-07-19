# Tasks: Remote Control session lifecycle in local mode

**Feature**: `022-local-session-lifecycle` | **Plan**: [plan.md](./plan.md) | **Base**: `main` = `7e50c44`

**Contracts**: [session-pointer-hygiene.md](./contracts/session-pointer-hygiene.md) (S1-S28),
[session-name-resolution.md](./contracts/session-name-resolution.md) (N1-N9)

## Ground rules for this feature

- **Test-first is mandatory, not optional** (Principle III + `plan.md` Phase 2 note). The
  scenario tables in both contracts *are* the test list. Each test task must be seen RED
  before its implementation task is started.
- **Bats hazard**: a negated `! [[ … ]]` or `!`-pipeline mid-body does **not** fail a test in
  this suite. Use `if … grep -q …; then false; fi` last (`tests/agentctl-local.bats:407`) or
  `run grep …; [ "$status" -ne 0 ]` (`:392-393`). Never copy the dead assertions at
  `tests/agentctl-local.bats:120, 148, 206, 274`.
- **bash 3.2 only** (macOS stock): no `declare -A`, `mapfile`, `local -n`, `${x,,}`.
- **Docker is byte-unchanged** (FR-011). No file under `docker/` is touched and the new lib is
  **not** mirrored to `docker/scripts/lib/`, so no `COPY` line and no `DOCKER_E2E` run.
- **Never print secret values.** `sessionId`/`environmentId` are operational identifiers and may
  be shown to the owning operator (FR-013).
- **What `[P]` means here.** Several test tasks marked `[P]` append to the *same* `.bats` file.
  They are parallel-safe **only** as append-only, self-contained `@test` blocks — two agents editing
  the same file concurrently will clobber each other. If you cannot guarantee append-only writes,
  run the same-file group sequentially. `[P]` on implementation tasks always means genuinely
  disjoint files.

---

## Phase 1: Setup

- [X] T001 Record the pre-change baseline: run `bats tests/` from the repo root and confirm
      **1052 ok / 0 not ok / 20 skips**; run `shellcheck -S error scripts/agentctl scripts/lib/*.sh`
      and confirm clean. Paste both results into the PR description as the SC-007 reference point.
- [X] T002 [P] Create `tests/session-pointer.bats` with only the bats preamble and
      `load_lib session_pointer` (`tests/helper.bash:26-32`). It MUST fail at this point — the lib
      does not exist yet. This is the first RED.
- [X] T003 [P] Create `tests/local-session-hooks.bats` with the preamble plus a `setup()` that
      renders both new templates into a tmpdir, following the render-a-template pattern of
      `tests/local-secret-check.bats:12-13`. Also RED.

---

## Phase 2: Foundational — `scripts/lib/session_pointer.sh` (BLOCKS every user story)

This lib is the single source of truth for hook **and** doctor. 021 paid the cost of duplicating
detection between its hook and `_local_secrets_doctor`; do not repeat it.

### Tests (write first, confirm RED)

- [X] T004 [P] In `tests/session-pointer.bats`, add S12: `session_pointer_slug '/tmp/a b.c_d/ws-1'`
      prints `-tmp-a-b-c-d-ws-1`. Assert the **exact** string — the contract records a measured trap
      where `echo | tr -c` appends a spurious trailing `-`
      (`contracts/session-pointer-hygiene.md:88-91`).
- [X] T005 [P] In `tests/session-pointer.bats`, add the `session_pointer_path` cases: rc 0 with the
      path when the slug dir holds the pointer; rc 2 when the slug dir exists without a pointer;
      rc 1 when `CLAUDE_CONFIG_DIR` is empty/missing/unlistable (S-path step 1); S13 (slug dir absent,
      exactly one glob match → rc 0); S14 (two glob matches → rc 1). The rc 1 vs rc 2 distinction is
      load-bearing and must be asserted separately, never as "non-zero".
- [X] T006 [P] In `tests/session-pointer.bats`, add the full `session_decide` truth table from
      `contracts/session-pointer-hygiene.md:199-206` — all six rows, one assertion each. Include the
      deliberate asymmetry: unknown **marker** → `retire`, unknown **pointer** → `noop`.
- [X] T007 [P] In `tests/session-pointer.bats`, add the marker round-trip: `session_exit_marker_write`
      then `session_exit_marker_read` returns the `exit_code` verbatim (S8); all-empty inputs still
      produce a valid marker (S9); a truncated marker `{"schema":1,"exit_c` reads as rc 1 with no
      shell parse error on stdout (S4); `session_exit_marker_consume` returns the value and removes
      the file, and a second consume returns rc 1 (S6 precondition).
- [X] T008 [P] In `tests/session-pointer.bats`, add S7: `session_pointer_retire` over an existing
      `bridge-pointer.retired.json` leaves exactly **one** retired file (fixed name, overwritten),
      and rc 1 when the target cannot be moved.
- [X] T009 Add a no-side-effects-on-source test: sourcing `scripts/lib/session_pointer.sh` in a
      subshell with `set -u` produces no output and creates no file (the `BASH_SOURCE` guard
      convention, Principle III).

### Implementation

- [X] T010 Create `scripts/lib/session_pointer.sh` implementing the eight public functions specified
      in `contracts/session-pointer-hygiene.md:56-212`: `session_pointer_slug`,
      `session_pointer_path`, `session_pointer_retire`, `session_exit_marker_path`,
      `session_exit_marker_write`, `session_exit_marker_read`, `session_exit_marker_consume`,
      `session_decide`. No `source`/`eval`/command substitution over file content — the pointer and
      the marker are untrusted input (precedent: `scripts/lib/env_file.sh:5-10`). Marker writes use
      `printf` with minimal escaping, **not** `jq`, because this path cannot depend on it.
      `session_exit_marker_consume` must consume via `mv` (atomic) so two concurrent starts cannot
      corrupt state.
- [X] T011 Confirm T004-T009 go GREEN and `shellcheck -S error scripts/lib/session_pointer.sh` is clean.

**Checkpoint**: the lib is complete and independently tested. US1, US2 and US3 can now proceed.

---

## Phase 3: User Story 1 — the agent still answers after a reboot (P1)

**Goal**: a restart or reboot leaves the agent reachable with no manual repair.
**Independent test**: restart the service twice consecutively; the agent is reachable after each.

### Tests (write first, confirm RED)

- [X] T012 [P] [US1] In `tests/local-session-hooks.bats`, add S8-S10 for `agent-session-exit.sh`:
      with `SERVICE_RESULT`/`EXIT_CODE`/`EXIT_STATUS` exported the marker holds all three verbatim
      plus `"schema":1`; with none exported it still writes with empty values and leaves no
      un-`mv`ed temp file; with `scripts/heartbeat/` mode `0500` it still **exits 0** and prints
      nothing to stdout. systemd is simulated by exporting the three variables and invoking the
      script — that is the entire `ExecStopPost` contract.
- [X] T013 [P] [US1] In `tests/local-session-hooks.bats`, add S1-S3 for `agent-session-check.sh`:
      marker `exited` + pointer present → pointer retired, `.retired.json` holds the original bytes;
      marker `killed` + pointer present → pointer **byte-identical** (`cmp`), no `.retired.json`;
      no marker + pointer present → retired (indeterminacy favours availability, FR-014).
- [X] T014 [P] [US1] In `tests/local-session-hooks.bats`, add S5, S6, S11, S14: no pointer → exit 0,
      nothing created, stderr free of `WARN`; running the hook twice is idempotent; an unwritable
      `projects/<slug>/` still exits 0 with a WARN and an intact pointer; two glob matches → exit 0,
      WARN, and **neither** pointer changed.
- [X] T015 [US1] In `tests/local-session-hooks.bats`, add S15 as the split-brain guard: across every
      branch above, no `bridge-pointer.json` is ever created that did not exist before. Put this
      load-bearing negative **last** in the body as `if … then false; fi`.
- [X] T016 [P] [US1] In `tests/local-render.bats`, add the new unit assertions: a second
      `ExecStartPre=-…/scripts/local/agent-session-check.sh` exists **after** the 021
      `agent-secret-check.sh` line (assert by line number, the way `:106-118` does for the
      `EnvironmentFile` pair), and an `ExecStopPost=-…/scripts/local/agent-session-exit.sh` exists
      with its `-` prefix.

### Implementation

- [X] T017 [P] [US1] Create `modules/local-session-exit.sh.tpl` rendering to
      `<ws>/scripts/local/agent-session-exit.sh`. Follow the 021 hook contract exactly
      (`modules/local-secret-check.sh.tpl`): `#!/usr/bin/env bash`, no `set -e`/`set -u`,
      unconditional `exit 0`, paths interpolated at render time, every optional dependency guarded
      with `command -v`. It sources `scripts/lib/session_pointer.sh` defensively and calls
      `session_exit_marker_write` with systemd's three variables.
- [X] T018 [P] [US1] Create `modules/local-session-check.sh.tpl` rendering to
      `<ws>/scripts/local/agent-session-check.sh`, same contract. It consumes the marker, resolves
      the pointer, calls `session_decide`, and acts: `retire` → `session_pointer_retire`;
      `keep`/`noop` → nothing. Emits WARN to stderr as `agent-<name> session-check: WARN: …` and
      exits 0 unconditionally.
- [X] T019 [US1] Edit `modules/systemd-remote-control.service.tpl`: add the second `ExecStartPre=-`
      **after** line 25, and `ExecStopPost=-` after `ExecStart`. Do **not** reorder the two
      `EnvironmentFile` lines (20-21) and do not touch `ExecStart` in this task — US3 owns that line.
- [X] T020 [US1] Edit `setup.sh` so both new templates render in the local-mode block
      (`setup.sh:2223-2262`), inheriting the `+x` from the existing glob at `:2257`.
- [X] T021 [US1] Confirm T012-T016 GREEN, plus S27: the nine 021 invariant tests
      (`tests/local-render.bats:101-104, 106-118, 120-123, 125-128, 130-153`) still pass **without
      being edited**. If any needed editing, the change is wrong.

**Checkpoint**: US1 is independently verifiable on the host. The hardware gate is T045.

---

## Phase 4: User Story 2 — the health check tells me when the agent is unreachable (P2)

**Goal**: the diagnostic reports the unreachable state and names the fix; it never cries wolf.
**Independent test**: place a workspace in the unreachable state → reported; healthy → silent.

### Tests (write first, confirm RED)

- [X] T022 [P] [US2] In `tests/agentctl-local.bats`, add S18: unit active + pointer present + marker
      `exited` → WARN "likely unreachable" naming the `systemctl restart`, exit 1. Overwrite the
      `systemctl` stub **inside the test body** (`:507-518`), not in `setup()`.
- [X] T023 [P] [US2] In `tests/agentctl-local.bats`, add S19 (the anti-false-alarm test, SC-004):
      healthy state with a `journalctl` stub that prints nothing, run `agentctl doctor` **five
      times**, assert zero session warnings each time and that `No recent connection signal` never
      appears.
- [X] T024 [P] [US2] In `tests/agentctl-local.bats`, add S20 and S21: ambiguous glob → WARN whose
      text literally contains `cannot determine`, no `⊝` glyph for that check, exit 1; empty
      `projects/` (fresh scaffold, no login) → zero session warnings, nothing suggesting a broken agent.
- [X] T025 [P] [US2] In `tests/agentctl-local.bats`, add S16 and S17: a `systemctl show -p ExecStartPre`
      stub returning only `agent-secret-check.sh` → WARN naming `cp` + `daemon-reload` + `restart`;
      an empty `ExecStopPost` → its own WARN. These are the D3-style installed-unit checks (R6).
- [X] T026 [US2] In `tests/agentctl-local.bats`, add S22: extract the body of `cmd_local_doctor` with
      `sed -n '/^cmd_local_doctor()/,/^}/p'` and assert it no longer contains
      `session url\|connected\|polling`. **Scoping is mandatory** — `cmd_local_status:1240-1247`
      keeps that pattern on purpose and a whole-file grep would fail.
- [X] T027 [P] [US2] Add S23: in docker mode `cmd_doctor` does not invoke `_local_session_doctor`,
      and the docker render is byte-identical to `main`.

### Implementation

- [X] T028 [US2] Add `_local_session_doctor "$agent" "$ws"` to `scripts/agentctl`, placed next to
      `_local_secrets_doctor` (`:1113`). Use `_doctor_warn` for both the unreachable verdict and the
      "cannot determine" case, **never** `_doctor_skip` — skip does not increment a counter and would
      exit 0 green, which is precisely the failure mode this feature exists to kill. Always pass `$2`
      with a copy-pasteable recovery command. Guard `jq`/`systemctl` with `command -v` and, when
      absent, emit the "cannot determine" line rather than staying silent.
- [X] T029 [US2] Wire `_local_session_doctor` into `cmd_local_doctor` next to `:1297-1298`, **before**
      the vault/QMD block (session health is the more important signal).
- [X] T030 [US2] Delete the false-positive block at `scripts/agentctl:1280-1285` (the
      `session url|connected|polling` journal grep). It was retired from the healthcheck as a measured
      false positive (`modules/local-healthcheck.sh.tpl:50-64`); leaving it while adding a good check
      violates FR-006. Leave `cmd_local_status:1240-1247` untouched.
- [X] T031 [US2] Confirm T022-T027 GREEN.

**Checkpoint**: the diagnostic now reports the state US1 prevents, and the pre-existing false alarm
is gone.

---

## Phase 5: User Story 3 — the session has a name I can read (P3)

**Goal**: the client-visible name comes from `agent.yml` with a de-duplicating default.
**Independent test**: render with an explicit name → verbatim; render without → documented default.

### Tests (write first, confirm RED)

- [X] T032 [P] [US3] In `tests/local-render.bats`, update the deliberately-broken assertion at `:65`
      per `contracts/session-pointer-hygiene.md:514-544`: the `setup()` fixture (`:26-31`) gains
      `session_name: "locbot-remote"` — a value **different** from the composed default — and the
      assertion becomes `--name locbot-remote`. Also harden `:83` so an empty `--name` cannot pass (S24).
- [X] T033 [P] [US3] Add N2-N5 against the resolver function: `mclaren`+`mclaren-admin` →
      `mclaren-admin`; `rpi5`+`locbot` → `rpi5-locbot`; `rpi5`+`rpi5-bot` → `rpi5-bot`;
      `My Pi.local`+`locbot` → `my-pi-locbot` (first dot-label, normalized). Include the boundary case
      `rpi5`+`rpi5x` → `rpi5-rpi5x` (bare-prefix false positive guard) and `mclaren`+`mclaren` →
      `mclaren`.
- [X] T034 [P] [US3] Add N8/N9: a pre-022 `agent.yml` (no field) gains the default on
      `--regenerate`; an explicitly empty `session_name` is treated as absent. Add the `yq` trap
      guard: `.deployment.host` absent makes `yq -r '.deployment.host'` print the literal `null`, so
      the code must read `// ""` and treat `null` as empty.
- [X] T035 [US3] Add S26: run `./setup.sh --regenerate` twice; the first persists
      `deployment.session_name`, the second leaves `agent.yml` byte-identical (`cmp`) — idempotency,
      Principle I.
- [X] T036 [US3] Add S28: the rendered kill-switch prints the **same** resolved name as the unit, not
      `$(hostname)-${AGENT_NAME}`.

### Implementation

- [X] T037 [US3] Add `_resolve_session_name AGENT_NAME HOST` to `setup.sh` implementing
      `contracts/session-name-resolution.md:29-49`: take the first dot-label of the host, normalize it
      with the `normalize_agent_name` rules (`scripts/lib/wizard-validators.sh:100-108`), return the
      agent name alone when the host segment is empty, equal, or a hyphen-bounded prefix; otherwise
      `<host_seg>-<agent>`.
- [X] T038 [US3] Write `session_name` into the wizard heredoc `deployment:` block
      (`setup.sh:1149-1154`), next to `claude_cli` (`:1153`).
- [X] T039 [US3] Add the backfill in `regenerate()` as a sibling of the `deployment.mode` block
      (`setup.sh:1953-1961`): inside the `if [ -f "$agent_yml" ]` that closes at `:1962`, and
      **before** `render_load_context` at `:1965`.
- [X] T040 [US3] Add the safety belt inside `_export_local_context` (`setup.sh:2331-2350`): if
      `DEPLOYMENT_SESSION_NAME` arrives empty, fill it with the default. This is the only correct choke
      point — it is called from **both** `regenerate()` (`:2224`) and `install_service()` (`:2375`), and
      `install_service` is what renders the unit. Placing it next to `_persist_claude_cli` (`:2231`)
      would be skipped by a run that installs the unit without passing through `regenerate()`.
- [X] T041 [US3] Change `modules/systemd-remote-control.service.tpl:26` from
      `--name {{HOST_NAME}}-{{AGENT_NAME}}` to `--name {{DEPLOYMENT_SESSION_NAME}}`.
- [X] T042 [US3] Update `modules/local-killswitch.sh.tpl:37` to print the resolved name instead of
      recomposing `$(hostname)-${AGENT_NAME}`.
- [X] T043 [P] [US3] Add `.deployment.session_name` to `_SCHEMA_OPTIONAL_NONEMPTY`
      (`scripts/lib/schema.sh:78-85`), and add the field to `tests/fixtures/sample-agent-with-vault.yml`
      so `tests/schema.bats:62-72` stays green without touching `known_external`.
- [X] T044 [US3] Add `session_name` to the inline fixture of `tests/local-install-service.bats:19-56`
      (its `deployment:` block is `:32-37`). **This is mandatory, not cosmetic**: that file's `diff` at
      `:113-125` compares a `render_to_file` taken *before* `--regenerate` against the installed unit;
      if `setup.sh` persists the field during that run, expected renders empty and installed renders
      resolved, and the diff fails.

**Checkpoint**: all three user stories complete and independently testable on the host.

---

## Phase 6: Polish & cross-cutting

- [ ] T045 Run the full suite: `bats tests/` must be **1052 + N ok / 0 not ok** with N equal to the
      number of tests added, and zero pre-existing tests edited except the two US3 owns
      (`tests/local-render.bats:65, 83`). Run `shellcheck -S error scripts/agentctl scripts/lib/*.sh`.
- [ ] T046 Mutation spot-check (the 021 habit that caught the `EnvironmentFile` ordering and the
      healthcheck RCE): break each new predicate deliberately — invert the `killed` branch of
      `session_decide`, empty the doctor's WARN message, neuter `session_pointer_retire` — and confirm
      at least one test goes red for each. Record the three results in the PR.
- [ ] T047 [P] Update `docs/heartbeatctl.md:501-511` with the new doctor check, and close 021's
      documentation debt in the same pass: that table still has **no rows for D1-D4**.
- [ ] T048 [P] Update `CHANGELOG.md` and bump `VERSION` 0.13.0 → 0.14.0. The upgrade note must state
      the accepted one-time change of the agent's client identity on first re-render (FR-015).
- [ ] T049 [P] Update `modules/next-steps.es.tpl:426` and `modules/next-steps.en.tpl:418`, which
      currently document the identity as `<hostname>-{{AGENT_NAME}}`. Both languages must change
      together — `tests/quickstart-doc.bats:48-65` enforces ES/EN token parity.
- [ ] T050 Open the PR against `main`. Do **not** merge without explicit confirmation; `main` is
      protected. Never stage `.claude/settings.json`.
- [ ] T051 **Hardware gate on mclaren** (per [quickstart.md](./quickstart.md)): the gate must install
      and restart the unit **explicitly** — `--regenerate` reinstalls only when
      `deployment.install_service` is true *and* `sudo -n` succeeds, and nothing in `setup.sh` ever
      restarts the session unit (confirmed live on 2026-07-18, where the installed unit still ran a
      `--name` its template no longer contained). Verify: SC-001 (two consecutive restarts reachable),
      SC-002 (reboot reachable), SC-005 (corrupt marker does not block startup), SC-008 (the 021
      `EnvironmentFile` order and `ExecStartPre` still intact via `systemctl show`), SC-009 (a restart
      of a live session preserves the client link). Reachability confirmation can only come from the
      operator's client.
- [ ] T052 On merge: update the SPECKIT block in `CLAUDE.md` to mark 022 MERGED with the merge SHA,
      and record the outcome of the T051 gate.

---

## Dependencies

```text
Phase 1 (Setup)
    └── Phase 2 (session_pointer.sh)   ← BLOCKS everything
            ├── Phase 3 (US1 · P1)  ── hooks + unit directives
            ├── Phase 4 (US2 · P2)  ── doctor  [needs the lib, NOT US1]
            └── Phase 5 (US3 · P3)  ── session name  [independent of the lib]
                    └── Phase 6 (Polish → PR → hardware gate)
```

- **US2 does not depend on US1.** The doctor reports the state whether or not the hooks exist; it can
  be built and shipped independently.
- **US3 depends on neither.** It touches the same template file as US1 (`ExecStart` vs
  `ExecStartPre`/`ExecStopPost`), so if both are in flight, sequence T019 before T041 to avoid a
  conflict on `modules/systemd-remote-control.service.tpl`.
- T044 must land with Phase 5, never after: without it `tests/local-install-service.bats` goes red the
  moment T039 starts persisting the field.

## Parallel opportunities

- **Phase 2 tests**: T004-T008 are five independent test bodies in one new file — parallel-safe if
  each appends its own `@test` block.
- **Phase 3**: T017 and T018 are two different new template files; T012-T014 and T016 touch different
  test files.
- **Phase 4**: T022-T025 and T027 append independent `@test` blocks. T026 must come after T030.
- **Phase 6**: T047, T048 and T049 touch three disjoint doc sets.

## Suggested MVP

**Phase 1 + Phase 2 + Phase 3 (US1)** — the agent stops going silently unreachable. That is the whole
outage. US2 makes the residual visible and US3 is polish; both can follow in the same PR or a later
one without changing US1's value.

## Task counts

| Phase | Tasks | Of which tests |
|---|---|---|
| 1 Setup | 3 | 2 |
| 2 Foundational (lib) | 8 | 6 |
| 3 US1 (P1) | 10 | 5 |
| 4 US2 (P2) | 10 | 6 |
| 5 US3 (P3) | 13 | 5 |
| 6 Polish | 8 | — |
| **Total** | **52** | **24** |
