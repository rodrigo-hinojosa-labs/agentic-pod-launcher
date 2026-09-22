# Adversarial review of the design — findings and remediation

Run 2026-09-19 as a four-lens workflow over the complete design (spec, plan, research, data-model,
quickstart, four contracts), each lens verifying every claim against the real tree, plus a refuter
per high-severity finding whose job was to demolish it.

**24 findings. 0 refuted.** Nine were duplicates raised independently by two or more lenses, which is
itself a signal: the same contradictions were visible from unrelated angles. Below, the unique set.

One refuter (`ops:OPS-01`) never ran — it died on an API error, not on the merits. That finding was
re-verified by hand instead.

## Fixed in this pass

| # | Sev | Finding | Remediation |
| --- | --- | --- | --- |
| 1 | **CRITICAL** | The boot marker writes into `${WATCHDOG_RUNTIME_DIR}`, which does not exist at attempt 1: `/tmp` is a tmpfs (`modules/docker-compose.yml.tpl:36-37`) emptied on every container start, and the only `mkdir -p` is at `start_services.sh:830`, deep inside `start_session`. The script runs `set -euo pipefail` (`:14`) | data-model §5b now mandates `mkdir -p … 2>/dev/null \|\| true` before the first attempt and `\|\| true` on every marker write and removal; boot-retry C13 adds the clause, its oracle (runtime dir deliberately absent) and mutations M-B1/M-B2 |
| 2 | HIGH | The backfill would write a flat `60` and the rendered `environment:` line outranks `env_file`, silently downgrading every agent that followed `README.md:150` — `donna` at 120/420, `rodri-cenco-admin` at 120 — re-creating the outage conditions in agents outside the live gate | The backfill **migrates**: it seeds `agent.yml` from the workspace value when that is a valid integer, `60` only when there is nothing to migrate. CANON-C2 rewritten as a completed-migration notice. New mutation M18 |
| 3 | HIGH | `--force` was specified as unconditional in plan/research/quickstart/contract and conditional in data-model; the conditional variant was also unimplementable, since `mcp_warm.sh:98` discards stderr and C3 fixes classification as purely rc-based | Settled by measurement on `donna` (cold install 12 s, forced-over-installed **0 s**): R4 is refuted, `--force` stays **unconditional** everywhere. data-model §2 rewritten with the measurement and a rejected-alternative table |
| 4 | HIGH | FR-020/FR-021 (boot-aware `doctor`) existed only in spec and data-model, with no contract, no plan decision, no oracle, no mutation — while boot-retry R1 explicitly forbade that cross ("should not be smuggled into US4") | R1 withdrawn and replaced by the operator decision; boot-retry scope widened to four files; new clauses C13-C16 with oracles; plan gains DD-6 with its own constitution re-check |
| 5 | HIGH | The bypass would mask a permanent failure: a container that never brings the channel up is *always* in an initial boot, so `doctor` would answer "starting (2/3)" indefinitely — strictly worse than today's FAIL | The marker carries `<attempt> <epoch>`; the bypass lapses once its age exceeds `MAX_BOOT_ATTEMPTS × (window + overhead)` and the FAIL returns. Mutation M-B4 |
| 6 | HIGH | Blind oracle: the named detector for mutation M4 could not fail, and its justification misread `mcp_warm.sh:62` — the early return belongs to `mcp_warm_targets` (inside a process substitution), not to `mcp_warm_run`, which reaches `return 0` regardless | mcp-warm C14 rewritten with a behavioural oracle (dangling link colliding with a declared package + a uv stub keyed on the link's existence); the old assertion demoted to a secondary check; M4 restated |
| 7 | MEDIUM | `tests/docker-e2e-postlogin.bats:150` (feature 026's delivery test) goes red and was listed nowhere; worse, the planned DOCKER_E2E tier did not even run that file, so the "mandatory, run for real" gate would have passed green | Added to the touchpoint table, to the plan's file list and to quickstart §2, with its rewrite specified as three cases including an explicit precedence case |
| 8 | MEDIUM | `CANON-D1` was defined twice with different text — the boot health line in data-model, the patch-check line in patch-marker-listing — in a repo whose whole CANON convention exists to stop test↔implementation drift | Boot health series renamed to `CANON-H*`; patch-marker-listing declares ownership of `CANON-D*`; no contract may define an id another one owns |
| 9 | MEDIUM | The C10 oracle was red in both branches: under bats errexit a bare intermediate `grep -q` aborts the test when it does not match, and when it does match the following comparison fails anyway | Rewritten with `run bash -c '… grep -cF …'` + count comparison; the "no bare intermediate grep" rule promoted to a contract-wide invariant and applied to four more oracles |
| 10 | MEDIUM | C11's retry test was unwritable as specified: with only tmux stubbed, `next_tmux_cmd` lands in Case A, the `--channels` gate at `:840` never opens and `verify_channel_healthy` never runs, so a second attempt is unobservable | C11 rewritten with the two viable routes and the real mould (`tests/start-services-watchdog.bats:213-250`), plus the unauthenticated-boot case the contract itself had asked for |
| 11 | MEDIUM | The pruner carried a default argument of `$HOME/.local/bin` — and `mcp_warm.sh` is also sourced on the operator's own machine in local mode, where that directory holds the real `uv`, `bun`, `node` links. `tests/mcp-warm.bats` does not override `HOME` | Argument made mandatory, empty → `return 0`; the single caller passes it explicitly; a clause now requires the test setup to export a scratch `HOME` |
| 12 | MEDIUM | `field-evidence.md` §3.3 and `research.md` D1 gave contradictory causes for the same failure, and SC-001's reachability depended on which was true | Re-measured discriminatingly. §3.3 was wrong: it described a hand-run `uvx … --help`, not the warm's `uv tool install`. Corrected in place with the correction note and the new numbers; D1 confirmed |
| 13 | MEDIUM | The design never said *how* `doctor` reads the marker, and the convention comment at `scripts/agentctl:315-318` steers toward the bind-mount — where a container tmpfs is unreachable, so the check would silently never fire | data-model §5b and boot-retry C16 fix the read as `_in_container … cat`, with digit validation and "exec failure = no marker". Mutation M-B5 |

## Noted, not changed

- **Worst-case boot of ~21 min at a 420 s window.** Left uncapped by operator decision: today that
  same setting yields an unbounded restart loop that destroys its own caches, and
  `warn_if_channel_timeout_risky` already fires at every boot for any value ≥ 65 s.
- **`unavailable` counts as `failed` in the warm summary.** Today's arithmetic; re-wording the
  summary line would churn behaviour this feature does not need to touch.
- **Rollback caveat.** An operator who removes the migrated line leaves the only copy in `agent.yml`,
  which a rolled-back launcher does not read. Recorded in channel-window-config C15.

---

# Second pass — `/speckit-analyze` over spec ↔ plan ↔ tasks (2026-09-19)

Run after `tasks.md` existed, which the first review could not cover. Four lenses (coverage,
canonical-string drift, executability, ground-truth-against-the-tree) plus a refuter per finding
whose mandate was to demolish it and to refute when genuinely uncertain.

**30 findings, 21 survived refutation, 9 refuted.** The refuted set is informative: five of them
claimed the DOCKER_E2E case E-F and the boot-marker doctor cases were mis-assigned, and the refuters
showed the assignments were defensible.

## Fixed in this pass

| # | Sev | Finding | Remediation |
| --- | --- | --- | --- |
| 1 | **HIGH** | T019's oracle could not turn red for M-B2 (dropping the fail-tolerant suffix from the marker write) — the one mutation guarding half of the first review's CRITICAL finding. Two independent reasons: C13's setup has a *creatable* dir, so the write never fails; and **bats' `run` strips errexit** (`$-` is `ehuBET` in the test body, `huB` inside `run`), so even a genuinely failing write runs to completion | T019 now names three cases with two harnesses: (m1) `run start_initial_session` for the `mkdir`, (m2) `run bash -c 'set -euo pipefail; source …'` asserting the CANON-B1 line **count** is 3 — the status is 1 in both variants, so the count is the sole discriminator — and (m3) the `_run_watchdog` freeze sha. The bats fact is recorded in boot-retry C14 so it is not rediscovered. **Verified independently before accepting**: measured here, `run f_noguard` → 3 lines, `run bash -c 'set -e…'` → 1 |
| 2 | MEDIUM | Mutation id **M5 defined twice**: `quickstart.md` binds it to the warm-wording mutation, `mcp-warm-contract.md` to reinstating the pruner's default `DIR`. Since T025 executes the quickstart table, the guard protecting first-review finding #11 (an `rm` loop defaulting to the operator's real `~/.local/bin`) had **no mutation at all** | New **M19** with its own row; the two contract sentences repointed; T025's range widened to M1–M21 |
| 3 | MEDIUM | The content-based `--list-markers` probe — the subtlest behaviour in the feature, measured in data-model §6 — had a test and no mutation. M17 mutates the opposite direction (a patcher that *fails*), which the skip path already catches | New **M20**: swap the content check for a status check; T014's old-patcher case must go red |
| 4 | MEDIUM | FR-013 ("no new stuck-channel detection", the prohibition born from `ebfe35f`) was enforced only by prose inside an implementation task. `grep -rn _run_watchdog tests/` → **zero**: no test in the repo exercises that function, and US3 edits its file | T019 (m3) adds the freeze sha `745a1a70…` (65 lines, verified reproducible), T029 runs it, and new **M21** (add a `capture-pane` probe) proves it can fail |
| 5 | MEDIUM | T014 required the fully-patched doctor case to assert `rc 0`, which `patch-marker-listing.md:479-484` explicitly forbids. **Measured**: `scripts/agentctl:616-618` exits 0 only with zero failures AND zero warnings; the mould fixture yields exit 2 with 6 unrelated warnings, so the assertion is unreachable — and would go red whenever a future doctor check is added | T014 asserts the CANON-D1 line and the absence of the warning instead; SC-005's exit-0 leg stays on the live gate (T030 §4.5) |
| 6 | MEDIUM | Contract C17's two static oracles over `README.md:150` and `docs/architecture.md:127` had **no owner**: T009 did not list them and T027 was an unoracled docs task, so FR-008's operator-facing half shipped with nothing that could fail | Both added to T009's case list, so the doc edit is driven by a RED check rather than prose |
| 7 | MEDIUM | `research.md` D1 and `plan.md`'s file map still told the implementer to put `/opt/uv/bin` on `PATH`, which DD-1, data-model §4 and T007 forbid on the basis of a live measurement. research.md also twice asserted the dangling links were "on `PATH`", which the same measurement refutes | Corrected in both, with the measurement stated inline so the claim cannot quietly return |
| 8 | MEDIUM | `plan.md` DD-3, `research.md` D3 and `spec.md` scenarios 2-3 / FR-008 still described the **pre-remediation** semantics: a flat `has()` backfill plus a `WARN` about pending precedence. The settled design migrates the `.env` value and its notice starts with `NOTE:` | All four rewritten to the completed-migration semantics, with the reason (a bare warning would have dropped `donna` and `rodri-cenco-admin` from 120 to 60) |
| 9 | MEDIUM | The boot-marker doctor cases had two homes: `boot-retry-contract.md` mandates `tests/agentctl-doctor-boot-attempt.bats`, while plan/tasks/quickstart folded them into the US4 file | Settled on the contract's separate file — they are different doctor checks needing different shims — and aligned plan.md, quickstart §1 and T020 |
| 10 | MEDIUM | T005 and `plan.md` DD-1 still justified the pruner ordering with "`mcp_warm_run` returns early", the exact misreading first-review finding #6 corrected. The fix had reached the contract and quickstart but not these two | Replaced with the true reason (a stale link re-blocks the install being attempted) and an explicit note that the refuted one must not creep back |
| 11 | MEDIUM | `spec.md` had no requirement for CANON-W3 (`unavailable`), and Key Entities listed three of the four warm outcomes | FR-002 extended to name all three classes; Key Entities completed |
| 12 | MEDIUM | FR-001/FR-002 are mode-neutral, but every task lands in docker. Local mode's provisioner (`modules/local-bootstrap.sh.tpl:126`) keeps both the missing `--force` and the exact wording FR-002 forbids | Scope note added to US1: docker-only, with the reason (no image rebuild locally ⇒ no dangling links), so the surviving `grep` hit is expected rather than a miss |
| 13 | MEDIUM | T001's Notes asserted the baseline "still describes the tree" — already false, since T002/T003 were applied while both stayed unchecked | T002/T003 ticked; the baseline clause restated as dated, with a re-measure required at the end of Phase 2; the branch re-base recorded |
| 14 | LOW | SC-007, T029 and the Phase 6 checkpoint demanded "byte-identical" counts across bash arms — unmeetable, since the feature's own baseline is 1412/0 vs 1411/1 | All three restated in the operable form quickstart §1 already used: same total count, 3.2.57 arm N/0, 5.x arm differing only by the **named** flake, re-run green in isolation |
| 15 | LOW | Citation drift repeated across artefacts: `ALL_MARKERS` cited `:126-132` (really `:124-132`), the compose healthcheck `:44-49` (really `:46-51`, with `start_period` at `:51`), the watchdog mould `:213-250` (really `:220-250`), and "25 existing" tests (really 29) | All corrected after verifying each against the tree |
| 16 | MEDIUM | DD-4 justified three attempts with a healthcheck claim that was mis-cited and contradicted by the feature's own contract ("tolerates it") | Citation fixed and the sentence restated: healthy on a warm boot, `unhealthy` reachable on a cold one, with DD-6 as the mitigation. DD-4 also now states that the loop lives in `start_initial_session`, not inline in `main()` |

## What this pass bought

The HIGH alone justifies it: the `|| true` is one of the two lines standing between this feature and
a fleet-wide restart loop, and its only mutation had no catcher — not because the test was missing,
but because the harness silently disabled the mechanism under test. That is invisible to review and
invisible to a green suite; it took measuring `$-` inside `run` to see it.

Three more findings (#2, #3, #4) share one shape: a remediation from the *first* review that arrived
without a mutation, so the guard existed and nothing proved it could fail.

## What this cost and what it bought

Four review agents and eight refuters, against a design that had already been written carefully and
had already survived four contract passes. The critical finding would have put **every** docker agent
into a restart loop — the exact failure this feature exists to end, generalised to the whole fleet.
Two more would have silently degraded live agents. Three would have shipped oracles that cannot fail,
which is worse than no test because it reads as coverage.
