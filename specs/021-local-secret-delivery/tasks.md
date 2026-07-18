# Tasks: Secret delivery in local mode

**Input**: Design documents from `/specs/021-local-secret-delivery/`
**Prerequisites**: plan.md, spec.md (3 stories, 12 FR), research.md (R0-R8 +
the live mclaren measurement), contracts/{env-file-format,secret-delivery}.md,
data-model.md, quickstart.md (host + hardware gates).

**Tests**: MANDATORY and test-first (Constitution Principle III — behavior
change). Every implementation task is preceded by its RED test task. Two
suite-wide hazards apply to EVERY test task here: (1) a mid-body `[[ ]]` or a
`!`-negated pipeline does NOT fail a bats test in this suite — negatives use
`run grep` + `[ "$status" -ne 0 ]` or land last; (2) a new test that does not
fail before its implementation lands is presumed dead (the 019 lesson — T024
runs the mutation spot-check).

**Organization**: by user story. US1 = delivery to the session (the MVP);
US2 = one secrets file (healthcheck); US3 = loud diagnosis (doctor + boot warn).

## Phase 1: Setup

- [X] T001 Confirm the pre-feature baseline: run `bats tests/` on the host and
  record the counts in this file (expect the 977-green baseline at branch point
  `cd6ad89`); run `shellcheck -S error` over `setup.sh scripts/agentctl
  scripts/lib/*.sh` and confirm clean. Any pre-existing failure found here is
  REPORTED, not silently absorbed into this feature.
  - **Result**: 977 ok / 0 not ok. `shellcheck -S error` clean. Baseline confirmed.

## Phase 2: Foundational (blocking — the lib, the seam, the leak fix)

- [X] T002 [RED] Write `tests/env-file.bats` (new file) against the contract in
  `contracts/env-file-format.md`, before the lib exists:
  `env_file_get` — last match wins; `KEY=` empty → empty; missing file → empty,
  exit 0; strips ONE layer of matching quotes; value containing `=` splits on
  the FIRST `=`; the canary fixture line `EVIL=$(touch "$TMP_TEST_DIR/pwned")`
  must NOT create the file (assert with `[ ! -e … ]` as the LAST line).
  `env_file_lint` — a nasty-shapes fixture straight from the divergence table
  (trailing backslash, `export KEY=v`, `KEY: v`, bare `KEY`, `;` line, ` # `
  inline comment, `$` in value, leading quote, CR, BOM bytes) each produce a
  finding formatted `line <N>: <KEY|->: <reason>`; a wizard-shaped clean file
  produces zero findings and exit 0; and NO finding line contains any fixture
  VALUE (negative via `run grep` + `[ "$status" -ne 0 ]`).
- [X] T003 Implement `scripts/lib/env_file.sh` (new lib): `env_file_get KEY FILE`
  (pure parameter expansion — no `.`/`source`, no `eval`, no command
  substitution on file content, no `export`) and `env_file_lint FILE` (the
  portable subset: blank | `^#` | `^[A-Za-z_][A-Za-z0-9_]*=` with value free of
  backslash, `$`, ` #`, leading quote, CR; file valid UTF-8, no NUL/BOM).
  `BASH_SOURCE`-guarded init (no side effects when sourced); bash-3.2
  compatible (macOS host runs the suite); `shellcheck -S error` clean. Do NOT
  mirror into `docker/scripts/lib/` (no container consumer). T002 goes GREEN.
- [X] T004 [P] Add the `SETUP_SYSTEMD_DIR` seam to `setup.sh`:
  `SETUP_SYSTEMD_DIR="${SETUP_SYSTEMD_DIR:-/etc/systemd/system}"` replacing the
  hardcoded `/etc/systemd/system` in `install_service` (setup.sh:2359) and the
  five sibling unit paths (healthcheck :2395-2396, qmd-reindex/watch :2424-2426,
  vault-backup :2450-2451, wiki-graph :2474-2475), mirroring the existing
  `LOGIN_SYSTEMD_DIR` pattern. Add the first-ever `install_service` test
  (extend `tests/local-render.bats`): with `SETUP_SYSTEMD_DIR` pointed at a
  tmpdir and stubbed passwordless sudo, the installed session unit lands there
  and matches the staged render. Guard: the test MUST fail (not sudo-prompt or
  write to `/etc`) when the seam is absent — that is the reason the seam exists.
- [X] T005 [P] [RED→GREEN] Atlassian alias sanitization (the day-one credential
  leak, plan D6.1): add a validator so the wizard alias collected at
  setup.sh:753 only accepts/normalizes to `[A-Za-z0-9_]` (document the chosen
  behavior: reject with re-prompt in interactive mode, hard error in
  non-interactive), and normalize identically wherever the alias becomes an env
  var name (`setup.sh:767` uppercase step) and in `render.sh`'s `{{NAME}}`
  substitution used by `modules/mcp-json.tpl`. RED first: a test in
  `tests/schema.bats` or `tests/wizard-validators.bats` (follow the existing
  validator-test pattern) feeding alias `cenco-corp` and asserting the derived
  key is `ATLASSIAN_CENCO_CORP_TOKEN` (or the rejection message) — plus a render
  test that `.mcp.json` and `.env` skeleton agree on the SAME normalized name.
  Verify the 3 wizard touchpoints (helper.bash `wizard_answers`, e2e-smoke
  hand-rolled array, schema.bats known_external) are unaffected — no new prompt
  is added, but record the check here.

**Checkpoint**: lib + seam + leak fix in place; suite green; user stories can start.

## Phase 3: US1 — The agent can use the credentials I gave it (P1) — MVP

**Goal**: the session unit loads `<workspace>/.env`; every catalog MCP receives
its secret transitively (Claude Code expands `${VAR}` from its own env).

**Independent test**: render a local workspace, assert the unit's directives
and order; on hardware (quickstart gate) the live session env contains the
secret.

- [X] T006 [RED] [US1] Extend `tests/local-render.bats` against
  `contracts/secret-delivery.md` invariants U1-U4, before touching the
  template: (U1) the rendered session unit contains
  `EnvironmentFile=-<ws>/.env` at a line number STRICTLY LOWER than the
  `EnvironmentFile=<ws>/.state/remote-control.env` line (numeric comparison of
  `grep -n` outputs, single-bracket `[ ]`); (U2) the `.env` line carries the
  `-` prefix (exact-match grep); (U3) an `ExecStartPre=-<ws>/scripts/local/agent-secret-check.sh`
  line is present, `-`-prefixed; (U4) NONE of the four timer service templates
  (`local-{qmd-reindex,qmd-watch,vault-backup,wiki-graph}.service.tpl` rendered)
  nor `local-healthcheck.service.tpl` contains any `EnvironmentFile` for `.env`
  (negative via `run grep` + `[ "$status" -ne 0 ]`, one per unit, last lines).
- [X] T007 [US1] Edit `modules/systemd-remote-control.service.tpl`: insert
  `EnvironmentFile=-{{DEPLOYMENT_WORKSPACE}}/.env` immediately BEFORE the
  existing EnvironmentFile line (:12) and add
  `ExecStartPre=-{{DEPLOYMENT_WORKSPACE}}/scripts/local/agent-secret-check.sh`
  in `[Service]`. Two-line diff; the `-` prefixes are load-bearing (FR-004).
  T006 goes GREEN (the ExecStartPre target script lands in US3 — safe interim
  because of the `-` prefix).
- [X] T008 [P] [US1] [RED→GREEN] `${VAR}` → `${VAR:-}` for every secret
  reference in `modules/mcp-json.tpl` (:27, :41-42, :53-58, :65 — plan D6.2,
  demoted to prudent by the live measurement but shipping). RED: extend
  `tests/modules-render.bats` asserting the docker-mode render now carries
  `${FIRECRAWL_API_KEY:-}` etc. AND that the rendered `.mcp.json` diff against
  the previous shape contains NOTHING but the `:-` insertions (byte-level guard
  that docker behavior is otherwise unchanged — SC-007).
- [X] T009 [US1] Regenerate-safety (FR-012): extend `tests/regenerate.bats` (or
  `tests/local-render.bats` if the local regenerate seam lives there) — after
  `./setup.sh --regenerate` on a local-mode fixture, the re-rendered session
  unit still carries both new directives in the right order, and with
  `SETUP_SYSTEMD_DIR` at a tmpdir + `install_service: true` the INSTALLED copy
  matches. Also assert regenerate did NOT create or touch `<ws>/.env`.

**Checkpoint**: US1 host-provable. MVP rendered artifacts complete.

## Phase 4: US2 — One place for secrets, not two (P1)

**Goal**: the healthcheck reads `NOTIFY_*` from `.env`, honors the legacy file
as an override, and stops executing file content.

**Independent test**: run the rendered healthcheck script directly with a
fixture workspace and a `curl` stub; force DEGRADED; inspect what the stub
received on stdin.

- [X] T010 [RED] [US2] Extend `tests/local-healthcheck.bats` (existing harness:
  rendered script + PATH-stubbed `curl` dumping its stdin), before the template
  changes, per contract H1-H5: (H-fallback) only `.env` populated with
  `NOTIFY_BOT_TOKEN`/`NOTIFY_CHAT_ID`, no legacy file → DEGRADED fires the stub
  and stdin contains the token; (H1) BOTH files present with different tokens →
  the LEGACY token is the one sent; (H3) a canary
  `EVIL=$(touch "$TMP_TEST_DIR/pwned")` line in BOTH fixture files → the file
  is never created (assert `[ ! -e … ]` LAST) — this test MUST fail against
  today's `. "$NOTIFY_ENV"`; (H4) the stub's environment does not contain other
  `.env` keys (e.g. `GITHUB_PAT` from the fixture — negative, `run grep` on the
  stub's env dump + `[ "$status" -ne 0 ]`); (H5) the token never appears in the
  stub's argv capture (existing pinned test stays green).
- [X] T011 [US2] Rewrite the notify-config block of
  `modules/local-healthcheck.sh.tpl` (:14, :98-105): drop `. "$NOTIFY_ENV"`;
  resolve `SRC` = legacy file if readable else `<ws>/.env`; read ONLY the two
  keys via `env_file_get` (source the workspace copy of
  `scripts/lib/env_file.sh` — verify setup.sh's existing copy step ships it to
  local workspaces, else add it to the copy list in the same commit); keep
  `curl -s --config -` byte-identical. T010 goes GREEN. Confirm no code path
  ever CREATES the legacy file (H2 — grep the template, negative assertion in
  T010's file).

**Checkpoint**: US2 independently shippable; the RCE (`source` of a
remote-restorable file) is dead.

## Phase 5: US3 — Silence is not an acceptable failure mode (P2)

**Goal**: a missing required secret is visible in `agentctl doctor` and in the
journal at boot; a healthy agent stays silent.

**Independent test**: doctor fixtures with blanked/absent/healthy `.env`
variants; run the rendered boot-check script directly.

- [X] T012 [RED] [US3] Extend `tests/agentctl-local.bats` per contract D1-D4 +
  the exclusion table, before implementing: (D4-warn) a fixture with the github
  MCP enabled and `GITHUB_PAT=` empty → doctor exits 1 and the output names
  `GITHUB_PAT` and the `.env` path; (silence) the same fixture with all
  required secrets set → doctor exits 0 and output contains NO secrets-section
  WARN (negative, last line); (no-cry-wolf) an aws-MCP fixture with no
  `AWS_PROFILE` anywhere → NO warn (the required set comes from the catalog's
  `requires_secret`, never from grepping `.mcp.json`); (INFO) empty
  `CLAUDE_CODE_OAUTH_TOKEN` → INFO line, exit unchanged, not WARN;
  (D2) a lint-dirty `.env` (trailing backslash) → WARN naming line+key, and the
  VALUE never appears in doctor output (negative); (D3) with `SETUP_SYSTEMD_DIR`
  fixture lacking the directive in the installed unit → WARN "installed unit
  does not load .env"; (D1) `.env` chmod 644 → WARN (mirror of the docker check).
- [X] T013 [US3] Implement `_local_secrets_doctor` in `scripts/agentctl`, called
  from `cmd_local_doctor` right after `_local_vault_qmd_doctor` (:1170): checks
  D1-D4 via `scripts/lib/env_file.sh` + the catalog descriptors
  (`modules/mcps/*.yml` in the workspace; `requires_secret`/`secret_env_var`;
  atlassian set from agent.yml instances; exclusions per data-model.md). WARN
  = `_doctor_warn` (exit 1) only — never `_doctor_fail`. Message shape:
  `<VAR> missing or empty in <ws>/.env` + `secret_doc_url` hint. T012 GREEN.
- [X] T014 [RED→GREEN] [US3] Boot warn: new template
  `modules/local-secret-check.sh.tpl` rendered to
  `scripts/local/agent-secret-check.sh` (wire into the local render block at
  setup.sh:2234-2237 + chmod at :2256). Same detection logic via the same lib;
  WARN lines to stderr; `exit 0` unconditionally (contract U3). RED first in
  `tests/local-render.bats` (script rendered, executable, carries the render
  header) + a direct-run test: blanked-secret fixture → WARN on stderr AND
  exit 0 (assert exit code as the LAST assertion); healthy fixture → no output.

**Checkpoint**: all three stories host-complete.

## Phase 6: Polish & closing gates

- [X] T015 [P] Docs touched by this behavior change (Documentation gate):
  update `docs/state-layout.md` (the `.state/healthcheck-notify.env` row →
  legacy-override status), `docs/getting-started.md` (local Rotating Secrets:
  the restart sequence from quickstart.md), `docs/adding-an-mcp.md` (per-mode
  secret delivery now symmetric; the alias normalization rule), and
  `modules/next-steps.{en,es}.tpl` local blocks if they instruct on `.env`
  (keep EN/ES parity; respect the render-test touchpoints from 020's T001 list).
- [X] T016 [P] `CHANGELOG.md` Unreleased entry (Fixed: local secret delivery +
  the healthcheck RCE + the alias leak; the mclaren zero-secrets measurement as
  the motivating evidence) and bump `VERSION` 0.12.0 → 0.13.0.
- [X] T017 Full gates: `bats tests/` (expect baseline 977 + the new tests, 0
  failures), `shellcheck -S error` clean over every touched shell file, and the
  docker-unchanged guard (T008's byte-level assertion) green. Record counts here.
  - **Result**: `bats tests/` = **1052 ok / 0 not ok** (977 baseline + 75 new,
    zero regressions). `shellcheck -S error` clean over every touched file
    (`setup.sh`, `scripts/agentctl`, `scripts/lib/env_file.sh`,
    `scripts/lib/wizard-validators.sh`). Docker-unchanged guard green
    (`021: docker mode is otherwise byte-unchanged` in `modules-render.bats`).
    (75 = the original 73 + 2 added by the mclaren hardware gate; see T019.)
  - **New test tally**: 75 across 8 files — 3 new (`env-file.bats` 25,
    `local-install-service.bats` 6, `local-secret-check.bats` 4) + additions to
    5 existing (`wizard-validators.bats` +4, `local-render.bats` +10,
    `modules-render.bats` +4, `local-healthcheck.bats` +6, `agentctl-local.bats`
    +16) + assertion-only updates (no new tests) in `mcp-json.bats` (7 literal
    `${VAR}` shapes → `${VAR:-}`) and `quickstart-doc.bats` (validator allowlist
    + a new EN/ES parity row for the alias rule).
- [X] T018 Mutation spot-check (the 019 discipline): 3 deliberate breakages —
  (a) swap the two EnvironmentFile lines in the unit template, (b) restore
  `. "$NOTIFY_ENV"` in the healthcheck template, (c) make `env_file_lint`
  return 0 unconditionally — each must turn at least one test RED; revert all
  three. Record 3/3 here.
  - **Result 3/3**: (a) detected by 1 test (U1 order assertion in
    `local-render.bats`); (b) detected by 1 test (H3 RCE canary in
    `local-healthcheck.bats`); (c) detected by 11 tests (10 in `env-file.bats`
    + 1 in `agentctl-local.bats`'s D2 doctor check) — spanning both the lib
    layer and the doctor's consumption of it. All three reverted; the suite
    returned to 1052/0 after each revert.
- [X] T019 Hardware gate on mclaren (quickstart.md section "Hardware gate"):
  items 1-7 including the FR-004 corrupted-.env boot test and the
  `/proc/<MainPID>/environ` count going 0 → 1. Closes SC-001/SC-003/SC-005 on
  real systemd.
  - **Staging pass done (2026-07-18, pre-restart)**: ported the 8 runtime deltas
    to the live mclaren workspace (all 8 byte-identical to `main` before, so the
    021 delta applied clean), ran `./setup.sh --regenerate` → unit **staged, not
    installed** (`sudo` needs a password on mclaren — the exact trap D3 exists
    for). Rendered-artifact invariants all verified on the host: unit has
    `EnvironmentFile=-.../.env` first + `ExecStartPre=-`; `.mcp.json` all
    `${VAR:-}`; healthcheck uses `env_file_get`, zero `source`.
  - **The gate caught two portability bugs in `agentctl doctor`** — both in code
    that only ever runs on the agent's Linux host, both green on the macOS test
    suite, both fixed test-first here (RED→GREEN + re-verified on mclaren):
    (1) `stat -f` (macOS) means `--file-system` on Linux → false `.env`
    permission WARN + statvfs leak; fixed with a portable `_file_mode` helper.
    (2) D3 read the unit via `systemctl cat`, which is `Permission denied` on a
    root-only unit file → the check silently skipped; switched to `systemctl
    show -p EnvironmentFiles`. Post-fix the doctor correctly reports the staged
    unit as not-yet-installed.
  - **PASSED post-restart (2026-07-18)** — operator installed the staged unit +
    `daemon-reload` + `restart`; unit came back `active`. Measured on the live
    host, counts only, no secret value ever printed:
    - *(item 1)* `systemctl show -p EnvironmentFiles` → `.env (ignore_errors=yes)`
      **first**, `remote-control.env (ignore_errors=no)` second. Exactly the
      designed order; the `ignore_errors=yes` **is** FR-004, enforced by systemd.
    - *(item 2)* **The gate metric**: `/proc/<MainPID>/environ` — `GITHUB_PAT`
      **0 → 1**, `ATLASSIAN_MCLAREN_TOKEN` 1, **all 6 declared variables present
      (6/6)**, and 0 of them present-but-empty. The measured bug is dead.
    - *(item 3)* `systemctl show -p Environment` → empty: secrets are **not**
      exposed via systemctl (SC-003).
    - *(item 5)* `agentctl doctor` → `✓ .env present (0600)`, `✓ installed unit
      loads the workspace .env` (D3 now passes), no D4 missing-secret warnings.
      The 3 remaining warnings are unrelated to 021 (`claude` absent from a
      non-login ssh PATH, silent-session connection heuristic, vault backup never
      pushed). `ExecStartPre` emitted no WARN — correct, nothing is missing.
    - *(item 7)* `core_pattern` = `core` (documented residual, unchanged).
  - **FR-004 detection verified without touching the live `.env`**: ran
    `env_file_lint` on throwaway fixtures — a BOM file reported `line 0: BOM at
    start of file (systemd discards the entire file silently)` and a trailing
    backslash reported `line 1: GITHUB_PAT: backslash in value`, naming the key
    and **never the value** (the anti-leak rule holds on real hardware).
  - **Two items deliberately not run** (cost > evidence, both documented rather
    than skipped silently): (a) the *empirical* corrupted-`.env` boot test needs
    two more sudo restarts and would only re-prove `ignore_errors=yes`, which
    systemd already reports on the installed unit; (b) a live MCP auth call —
    Claude Code spawns MCP servers on demand, so the unit's cgroup holds only the
    session process (10 threads, no children) while idle. The chain is proven at
    the point that matters: the process that spawns them carries all 6 secrets,
    and env inheritance to children is an OS guarantee, not our code.
- [ ] T020 On merge: update `CLAUDE.md` SPECKIT block — 021 to MERGED with
  PR/SHA (never commit `.claude/settings.json`).

## Dependencies & Execution Order

- T001 → everything. T002 → T003 (RED→GREEN); T004 and T005 run parallel to
  T002/T003 (different files).
- US1: T006 → T007; T008 parallel to T006/T007 (different files); T009 after
  T007 (and uses T004's seam).
- US2: T010 → T011; needs T003 (the lib). Independent of US1.
- US3: T012 → T013; T014 after T003 and after T007 only for the ExecStartPre
  line already existing (safe either way — `-` prefix). Needs T004 for the
  D3 installed-unit fixture.
- Polish: T015/T016 parallel; T017 → T018; T019 at deployment; T020 at merge.

## Parallel Opportunities

- T004 ∥ T005 ∥ (T002→T003) — three disjoint file sets.
- T008 ∥ T006/T007. US2 (T010-T011) ∥ US3 (T012-T013) once Phase 2 lands —
  different files (`local-healthcheck.*` vs `agentctl` + new template).
- T015 ∥ T016.

## Implementation Strategy

MVP = Phase 2 + US1 (the unit directive is the fix; everything else is safety
and visibility). Then US2 (kills the RCE and the dead alert), then US3 (kills
the silence). One PR — the stories share the lib and the contracts, and a
partial merge would leave the doctor describing behavior that does not exist
yet. RED discipline throughout; T018 proves the tests can actually fail.
