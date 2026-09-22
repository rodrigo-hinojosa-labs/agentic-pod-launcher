# Tasks: Cold-start boot resilience + honest patch diagnostics

**Feature**: `036-cold-start-boot-resilience` | **Branch**: `036-cold-start-boot-resilience`
(cut from `main` = `da9d2a3`, VERSION 0.25.1 — originally cut from 034's head `a1fa449`, then
re-based twice as PR #96 and PR #97 merged)

**Input**: `spec.md`, `plan.md`, `research.md`, `field-evidence.md`, `data-model.md`,
`quickstart.md`, `contracts/{mcp-warm-contract,channel-window-config,boot-retry-contract,patch-marker-listing}.md`,
`review-remediation.md`

**Constitution**: test-first (Principle III) — every story writes its RED oracles before the
implementation, and the RED set actually observed is recorded in Notes. Canonical strings come from
`data-model.md` verbatim; a test oracle that paraphrases a CANON-* string is a defect, not a style
choice (lesson of 033/034).

**Story order**: US1 → US2 → US4 → US3. Fixed in `plan.md`: US3 lands last because it touches the
watchdog, an area with an expensive regression precedent (`ebfe35f`), and should land on an
otherwise-green tree.

---

## Phase 1: Setup

- [X] T001 Baseline before touching anything: `bats tests/` under bash 5.x and `PATH=/bin:$PATH bats tests/` (3.2.57), `shellcheck -S error setup.sh scripts/lib/*.sh docker/scripts/*.sh docker/scripts/lib/*.sh`, `python3 -B -m py_compile docker/scripts/apply_telegram_typing_patch.py`. Record both counts in Notes (expected 1412/0 on the 034 tree). Any pre-existing red must be named here, in isolation, so it is never confused with a regression of this feature.

---

## Phase 2: Foundational (blocking prerequisites)

- [X] T002 Add `channel_health_timeout_s: 60` to the `docker:` block of `tests/fixtures/sample-agent.yml` and `tests/fixtures/sample-agent-with-vault.yml` — the second is required by the placeholder test at `tests/schema.bats:52`. No `scripts/lib/schema.sh` change: the field introduces no new boolean, and `claude.mcp_timeout_ms` appears in none of its lists either (data-model §1).
- [X] T003 Source `scripts/lib/env_file.sh` from `setup.sh`'s lib block (`setup.sh:7-14`, which loaded eight libraries and not this one; **nine** after this task), following the guarded precedent at `scripts/agentctl:1133-1135`. `env_file_get` was **not callable in `setup.sh`**; US2's migration depends on it. Verify with a scratch call that both bash arms still source cleanly.

---

## Phase 3: User Story 1 — The pre-warm actually warms, and says so honestly (Priority: P1)

**Goal**: a resolvable package ends up warm even when its executable name collides, and a failure
says which kind of failure it was.

**Independent test**: `bats tests/mcp-warm.bats tests/start-services-warm.bats` — a collision case
ends warm, each failure class emits its own CANON string, and the pruner removes only dangling links
into `/opt/uv/tools/`.

### Tests for User Story 1 (write FIRST, confirm RED)

- [X] T004 [US1] In `tests/mcp-warm.bats`: RED oracles for `--force` in the installer call (C1), the three outcome strings CANON-W1/W2/W3 asserted **verbatim** from data-model §2, the timeout class `{124, 143}` (busybox `timeout` reports 143, not 124 — measured, data-model §2), and `mcp_warm_prune_stale_links`: removes a dangling symlink into `/opt/uv/tools/`, **keeps** a resolving symlink, **keeps** a regular file, **keeps** a symlink pointing elsewhere, logs CANON-W4 only when it removed at least one, and returns 0 with an empty or missing argument. The setup MUST export a scratch `HOME` — `tests/mcp-warm.bats:10-16` does not override it today, and a default-path scan would hit the developer's real `~/.local/bin` (data-model §3).
- [X] T005 [US1] In `tests/start-services-warm.bats`: RED oracle for call order — the pruner runs **before** `mcp_warm_run`. The reason is NOT "because `mcp_warm_run` returns early": that early return belongs to `mcp_warm_targets` (`mcp_warm.sh:62`, inside a process substitution), and the misreading was already corrected once (`review-remediation.md` #6) — it must not creep back, or the next reader will "simplify" the order away. The order is load-bearing because **a stale link left in place re-blocks the very install the warm is about to attempt**, and because the cleanup must still happen for an agent with zero uvx/npx targets (C14 oracle (c)). Use the behavioural oracle of mcp-warm C14 (a dangling link colliding with a declared package: pruner-before reports `1/1 warm`, pruner-after reports CANON-W1 `failed (exit 2)`) — **not** the naive assertion, which cannot fail (`review-remediation.md` #6).

### Implementation for User Story 1

- [X] T006 [US1] `scripts/lib/mcp_warm.sh`: add `--force` unconditionally to the `uv tool install` call (settled by measurement — forced-over-installed costs 0 s, data-model §2), classify each target's outcome into warm/failed/timed-out/unavailable and emit CANON-W1/W2/W3, and add `mcp_warm_prune_stale_links DIR` with a **mandatory** argument (empty or missing → `return 0`, no scan). Keep the summary line and the always-return-0 contract untouched (FR-003). Single source: the file is copied into the image by `docker/Dockerfile:259` and into a scaffold by `setup.sh::mirror_catalog_to_docker` — there is no committed `docker/scripts/lib/mcp_warm.sh` to keep in sync.
- [X] T007 [US1] `docker/Dockerfile:118-120`: add `UV_TOOL_BIN_DIR=/opt/uv/bin`. The existing `mkdir -p /opt/uv` + `chown -R ${UID}:${GID} /opt/uv` block (`:121-125`) already covers the new subdirectory. **Do NOT touch `PATH`** — measured in a live container, the Dockerfile sets no `ENV PATH` and `~/.local/bin` was never on it; adding a bin dir to `PATH` would be surface with no consumer (plan DD-1).
- [X] T008 [US1] `docker/scripts/start_services.sh::pre_warm_mcps` (`:808-811`): call `mcp_warm_prune_stale_links "$HOME/.local/bin"` explicitly, before `mcp_warm_run`.

**Checkpoint**: `bats tests/mcp-warm.bats tests/start-services-warm.bats` green on both bash arms; `shellcheck -S error` rc=0.

---

## Phase 4: User Story 2 — The channel window is configuration, not a hand-edit (Priority: P1)

**Goal**: `docker.channel_health_timeout_s` in `agent.yml`, rendered into compose, surviving
`--regenerate`, migrating the value an operator already has in the workspace `.env`.

**Independent test**: `bats tests/channel-window-config.bats tests/docker-render.bats tests/local-render.bats tests/schema.bats`.

### Tests for User Story 2 (write FIRST, confirm RED)

- [X] T009 [US2] New `tests/channel-window-config.bats`, moulded on `tests/mcp-handshake-timeout.bats` (parameterised `_write_agent_yml` with value/OMIT/NULL): a valid value reaches the rendered compose line CANON-C1; invalid values (empty, `0`, negative, non-numeric, `1.5`, **7 digits**) degrade to `60` — note the digit bound is `^[0-9]{1,6}$`, deliberately **narrower** than the 029 mould, so the 7-digit case is the opposite of the equivalent test there (data-model §1); `has()` backfill preserves an operator value; the **migration** case seeds `agent.yml` from a valid `.env` value and emits CANON-C2 to stderr; the oracle asserts the value **never appears** in the output, written as `run bash -c '… grep -cF …'` + count comparison, never a bare intermediate `grep -q` (which aborts the test under bats errexit — `review-remediation.md` #9); a present-but-empty `.env` key does **not** warn (`env_file_get` cannot distinguish absent from empty, data-model §1 fact 2); the warning is silent in local mode. **Plus the two C17 static oracles**, which `contracts/channel-window-config.md` specifies, records as RED today, and which no task owned until now: `README.md:150` and `docs/architecture.md:127` must stop instructing the operator to hand-set the key in the workspace `.env`. They belong here rather than in the docs task so the doc edit is driven by a failing check instead of by prose — FR-008's operator-facing half otherwise ships with nothing that can fail.
- [X] T010 [P] [US2] `tests/docker-render.bats`: CANON-C1 present unconditionally in the rendered compose. `tests/local-render.bats`: extend the FR-011 oracle of 032 — zero `CHANNEL_HEALTH_TIMEOUT` in local runtime artefacts. `tests/schema.bats`: confirm no new external placeholder is needed (the var is a `render_load_context` flatten of an `agent.yml` field, not a derived placeholder).

### Implementation for User Story 2

- [X] T011 [US2] `setup.sh`: `channel_health_timeout_effective()` moulded on `mcp_timeout_effective()` (`:2016-2023`); the wizard heredoc gains `channel_health_timeout_s: 60` **before** the nested `toolchain_channels:` mapping — `$docker_yaml` (`:1116-1129`) ends with that block, so appending at the end would nest the key under it (data-model §1 fact 4, which has its own oracle); `has()` backfill that **migrates** from the workspace `.env` when it holds a valid integer and writes `60` only when there is nothing to migrate; re-export of the sanitised value after `render_load_context`; CANON-C2 to stderr inside the docker-only render branch (`:2545-2549`).
- [X] T012 [US2] `modules/docker-compose.yml.tpl`: one unconditional CANON-C1 line in the `environment:` block, next to `MCP_TIMEOUT` (`:73`). The in-container reader (`start_services.sh:739-745`) stays untouched, so an agent whose compose predates this feature behaves exactly as today.
- [X] T013 [US2] Rewrite `tests/docker-e2e-postlogin.bats:150` (feature 026's delivery test). It goes red under this feature and was listed nowhere in the first draft: it renders without the field, then writes `.env` with `45`, and asserts the container sees `45` — but the rendered `environment:` line now outranks `env_file`. Three cases: the field reaches the container, an explicit precedence case, and the migration path.

**Checkpoint**: the four host test files green on both arms; two `--regenerate` runs byte-identical.

---

## Phase 5: User Story 4 — `doctor` tells the truth about plugin patches (Priority: P2)

**Goal**: no false patch warning on a healthy agent, a real one when a group is missing, and no
version literal left in `agentctl`.

**Independent test**: `bats tests/agentctl-doctor-telegram-patches.bats` — net new coverage; the
check has **no test at all** today.

### Tests for User Story 4 (write FIRST, confirm RED)

- [X] T014 [US4] New `tests/agentctl-doctor-telegram-patches.bats`, moulded on `tests/agentctl-doctor-claude-oauth.bats`, with a docker shim that returns a plugin path and **replicates `grep -c`'s rc=1-on-zero behaviour** (that is the defect being fixed): fully-patched agent → the CANON-D1 pass line present, no `⚠ Telegram plugin patches` line, and **no shell error text** in the output (the live symptom was `line 533: [: 0\n0: integer expression expected`). **Do NOT assert `rc 0`** — measured: `scripts/agentctl:616-618` exits 0 only with zero failures AND zero warnings, and the mould fixture in a tmpdir always carries unrelated ones (`1 error(s), 6 warning(s)`, exit 2), so that assertion is unreachable and would go red the day any future doctor check is added. SC-005's exit-0 leg belongs to the live gate (T030 §4.5), as `contracts/patch-marker-listing.md:479-484` already requires; one group absent → warning naming that group; two version directories in the cache → must not pass by reading the inactive one; a patcher without `--list-markers` → **skipped**, and the probe must be **content-based**: an old patcher handed the flag exits **0 with no markers** (`len(argv)==2` satisfies the usage guard, `Path("--list-markers").is_file()` is False, it logs and returns 0), so a status-based probe would report a perfectly healthy agent — the same false-clean verdict, inverted (data-model §6); non-telegram agent → still skipped; an anti-drift grep asserting `scripts/agentctl` carries no marker literal and no version string.
- [X] T015 [US4] In `tests/apply-telegram-patches.bats`: RED oracles for `--list-markers` — seven lines, `ALL_MARKERS` order, stdout, exit 0, no file argument required, no file touched; the existing single-argument usage path (exit 2) unchanged.

### Implementation for User Story 4

- [X] T016 [US4] `docker/scripts/apply_telegram_typing_patch.py`: `--list-markers` in `main()` (`:2029-2033`), printing one marker per line from `ALL_MARKERS` (`:124-132` — verified; the `:126-132` repeated across the earlier artefacts was off by two). Everything else unchanged.
- [X] T017 [US4] `scripts/agentctl:523-543`: count without `grep -c … || echo 0` (FR-014); consume the patcher's list through `_in_container` (`:332-335`) instead of duplicated literals (FR-015); inspect the same `"$cache"/*/server.ts` glob the boot patcher walks (`start_services.sh:404-415`) rather than `head -1` (`:526`) (FR-016); skip, not fail, when the flag is unsupported.
- [X] T018 [P] [US4] Correct the documentation that describes this false negative as known behaviour: `docs/creating-an-agent.md:452-460` and the stale marker counts at `docs/state-layout.md:199` (FR-017).

**Checkpoint**: doctor tests green; `shellcheck -S error` rc=0; `py_compile` ok.

---

## Phase 6: User Story 3 — A slow first boot does not kill the container (Priority: P2)

**Goal**: the initial boot retries up to three times, logs each attempt distinguishably, still exits
non-zero on exhaustion, and `doctor` tells a legitimate retry apart from a dead agent.

**Independent test**: `bats tests/start-services-watchdog.bats` + the boot-marker cases of
`tests/agentctl-doctor-telegram-patches.bats`.

### Tests for User Story 3 (write FIRST, confirm RED)

- [X] T019 [US3] In `tests/start-services-watchdog.bats`: source `start_services.sh` with `START_SERVICES_NO_RUN=1` and the existing `_stub_pgrep_after` seam (`:357`, real mould at `:220-250`; the file holds **29** tests today, not 25) — the retry loop must live in a **named function** `start_initial_session`, not in `main()`, precisely so it has a host oracle. Cases: healthy on the second attempt → no exit; never healthy → exits non-zero after exactly 3; CANON-B1 logged per attempt; CANON-B2 on exhaustion (which keeps today's line as a **substring**, so pre-existing log scraping still matches); **no sleep** between attempts (timing oracle); and the marker contract of data-model §5b — written per attempt as `<attempt> <epoch>`, removed on success **and** on exhaustion. The `mkdir` and the `|| true` need **two separate cases with two different harnesses**, and this is the single most important detail in the task, because those two lines are what guard the adversarial review's CRITICAL finding:

  - **(m1) the `mkdir -p`, catches M-B1.** `run start_initial_session` with `WATCHDOG_RUNTIME_DIR` pointing at a creatable-but-absent path (C13's setup). Assert the marker exists during the attempt. Removing the `mkdir` makes the write fail and the marker never appear.
  - **(m2) the `|| true`, catches M-B2 — and it CANNOT use `run <function>`.** Measured on this host (bats 1.13.0): bats' `run` strips errexit (`$-` is `ehuBET` in the test body but `huB` inside `run`), so a sourced function whose unguarded redirect fails still runs to completion — guarded and mutant both give `status=1` with all three attempt lines, byte-identical. The oracle must re-establish errexit in a subshell: `run bash -c 'set -euo pipefail; START_SERVICES_NO_RUN=1 source "$REPO_ROOT/docker/scripts/start_services.sh"; WATCHDOG_RUNTIME_DIR=<path whose PARENT is a regular file>; start_session() { return 1; }; start_initial_session'` and assert the **count** of CANON-B1 lines is 3. The status is 1 in both variants, so the line count is the only discriminator: guarded → 3, mutant → 1. Record this bats fact in the test comment so it is not rediscovered.
  - **(m3) FR-013, the watchdog stays frozen.** `sed -n '/^_run_watchdog() {/,/^}/p' docker/scripts/start_services.sh | shasum -a 256` must equal `745a1a70f53eee28e9f87acbc406580b2e7a4ce44cb1fada19651beef94b32c4` (65 lines; verified reproducible). Today **no test in the repo exercises `_run_watchdog`** (`grep -rn _run_watchdog tests/` → zero), and US3 edits that very file — so this sha is the only thing standing between a refactor and a silent re-run of the `ebfe35f` regression.

  Note C11's first draft was unwritable as specified (with only tmux stubbed, `next_tmux_cmd` lands in Case A and the `--channels` gate at `:840` never opens): use the two viable routes named in the contract, plus the unauthenticated-boot case.
- [X] T020 [US3] In **`tests/agentctl-doctor-boot-attempt.bats`** (a new file, NOT the US4 one — `contracts/boot-retry-contract.md:21,616` mandates it and the two are different doctor checks with different shims: the patch check needs a plugin-path shim, the boot marker needs a `cat`-through-`docker exec` shim; folding them would force one fixture to satisfy both): CANON-H1 `Container health: starting (boot attempt N/3)` while the marker is present and fresh; the `unhealthy` → `_doctor_fail` mapping (`scripts/agentctl:381-390`) **restored** once the marker's age exceeds `MAX_BOOT_ATTEMPTS × (window + overhead)` — without this guard a permanently broken agent reads as "starting" forever, which is worse than today's FAIL; the marker read via `_in_container … cat`, **not** the bind-mount (the path is a container tmpfs; the convention comment at `:315-318` steers the wrong way here); a failed `docker exec` and a non-digit payload both treated as "no marker".

### Implementation for User Story 3

- [X] T021 [US3] `docker/scripts/start_services.sh`: `MAX_BOOT_ATTEMPTS=3` beside `MAX_CRASHES`/`WINDOW` (`:258-259`); new `start_initial_session` holding the loop, both log lines and the marker writes in the exact shape mandated by data-model §5b (`mkdir -p "$WATCHDOG_RUNTIME_DIR" 2>/dev/null || true` once before the first attempt, `|| true` on every write and on the removal); `main()` (`:1279-1282`) calls it. The watchdog respawn path (`:1269`) is **untouched**, and no new stuck-channel detection is introduced (FR-013, `ebfe35f`).
- [X] T022 [US3] `scripts/agentctl`: read the boot marker through `_in_container`, validate it is digits-and-space, and bypass the `unhealthy` → fail mapping only while present **and** fresh, reporting CANON-H1; outside an initial boot, behaviour is byte-identical to today (FR-021).

**Checkpoint**: full host suite at the T029 condition — 3.2.57 arm N/0, 5.x arm differing only by the named flake (re-run green in isolation), same total count on both.

---

## Phase 6b: User Story 5 — the SIGPIPE class is left with no live instances (Priority: P2)

**Goal**: the two remaining measured instances of the defect class that PR #97 opened are closed,
so no code path still turns "the producer had one more line to write" into a wrong decision or an
abort.

**Where this came from**: a 26-site audit of every early-exit pipeline under `pipefail`
(2026-09-21, 12 agents, every verdict measured, adversarial refuter per EXPLOITABLE finding). Four
real instances; two were fixed in PR #97 (`setup.sh:2183`/`:2195`), and the operator routed these
two here because `wizard-container.sh` is image-baked and this feature already runs DOCKER_E2E for
real in Phase 7 — the apparatus exists once instead of twice. The 22 sites cleared are recorded in
`CLAUDE.md`'s gotchas, six of them as safe-by-input-property rather than safe-by-design.

**Independent test**: `bats tests/sigpipe-boot-paths.bats` plus E-G/E-H of Phase 7.

### Tests for User Story 5 (write FIRST, confirm RED)

- [X] T030a [US5] New `tests/sigpipe-boot-paths.bats`. **(a) `modules/local-healthcheck.sh.tpl:45`** — `if printf '%s\n' "$journal" | grep -qE 'API Error: 401|Please run /login'`. The file declares `set -uo pipefail` (no `-e`), so this is the silent-wrong-decision shape, not the abort shape: on a 141 the `if` goes FALSE, `_demote DEGRADED "auth error in journal"` never runs, the unit reports `status=OK` and the operator's Telegram alert at `:109` (gated on `[ "$status" = "DEGRADED" ]`) never fires — **a dead agent that does not say so**. `printf` is a builtin and therefore immune below the 64 KiB pipe buffer, but `:44` captures `journalctl -u "$UNIT" --since "-10 min"` with **no `-n` cap**, so the payload is unbounded. Measured: macOS bash 5.3.15 clean at 64,883 B and 261/300 failing at 65,573 B; Linux (bookworm, bash 5.2.15, GNU grep 3.8) 29/300 at 66,263 B and 35/300 at 110,423 B. The oracle renders the template and drives the rendered script with a `$journal` payload **over** the boundary, asserting the DEGRADED branch is taken; a second case under the boundary pins that the detection still works normally. Use `run bash -c '… grep -cF …'` + a count, never a bare intermediate `grep -q`. **(b) `docker/scripts/wizard-container.sh:146`** — `existing=$(grep "^${var}=" "$ENV_FILE" | head -1 | cut -d= -f2-)`, a plain assignment with **no `local`** (the sole `local` in `main()` is `existing_gh_pat` at `:118`), so a 141 aborts under `set -e`. Verified by the refuter that even the split-declaration form (`local x` then `x=$(…)`) does NOT mask errexit: 12/3000 aborts. Requires two lines matching the same key, which `setup.sh:802-820` emits for two colliding Atlassian aliases. Measured in the real image (busybox 1.37.0, bash 5.3.9, aarch64-musl): **22/3000 (0.7%)**. The oracle sources the script with a stub-driven harness and asserts it survives a two-matching-line `.env`.
- [X] T030b [US5] Implementation. **(a)** cap the producer at its source — `journalctl … -n <N>` at `local-healthcheck.sh.tpl:44` — **and** make the consumer read to completion, because the cap is a property of the input and this file's own gotcha entry says that is not enough: prefer a here-string (`grep -qE … <<<"$journal"`), which removes the pipeline entirely, so there is no second process to signal. **(b)** `wizard-container.sh:146`: make the assignment fail-tolerant and the read complete — the same structural move, not a wider guard. **Both files' change surface is deliberately minimal**: `wizard-container.sh` is image-baked, so Phase 7 must cover it.
- [X] T030c [US5] Anti-drift oracle in the same file: no `PRODUCER | grep -q` remains in either touched file, counted (never `grep -q`-negated — the documented bats gotcha), with comment lines stripped first so the explanatory docstrings survive. Mirrors the oracle shipped in `tests/backfill-plugin-detection.bats`.

**Checkpoint**: `bats tests/sigpipe-boot-paths.bats` green on both arms; `shellcheck -S error` rc=0.

---

## Phase 7: DOCKER_E2E (this host has Docker — run it, do not defer)

- [X] T023 Extend `tests/docker-e2e-warm-cache.bats` with the six cases of `quickstart.md` §2: E-A `UV_TOOL_BIN_DIR` set in the built image and inside `/opt/uv`; E-B a warm target whose executable link already exists still ends warm (the exact `rc=2` reproduced and defeated); E-C dangling links into `/opt/uv/tools` pruned while a resolving link and a same-named regular file survive; E-D the three baked catalogue tools (`mcp-atlassian`, `mcp-server-fetch`, `mcp-server-time`) still execute after a forced warm (FR-004); E-E `--list-markers` prints 7 lines and exits 0 inside the image; E-F the boot retry logs `initial session attempt 1/3` and a second attempt when the channel is slow; **E-G** (US5) the image-baked `wizard-container.sh` survives an `.env` carrying two lines that match the same key — run it against the real busybox/musl runtime, which is the only place the 0.7% was measured, and assert the wizard reaches its next prompt instead of dying; **E-H** (US5) the rendered local healthcheck takes the DEGRADED branch on an over-64 KiB journal — this one runs on the host, but pin it here so both US5 legs have a gate in the same phase. Harness facts inherited from 033/034: the patcher's `log()` writes to **stdout**; `grep -c` exits 1 on a zero count under `set -e`; `docker compose run` prepends progress lines to `$output`, so assert named markers with `grep -qx`, never line positions.
- [X] T024 Run both e2e files for real: `DOCKER_E2E=1 bats tests/docker-e2e-warm-cache.bats` and `DOCKER_E2E=1 bats tests/docker-e2e-postlogin.bats`. Record the image digest, Docker/Compose versions and the per-case results in Notes (FR-019 — required, not deferred).

---

## Phase 8: Polish, docs, version, gates

- [X] T025 Mutation spot-checks **M1–M21 and M-B1–M-B5** of `quickstart.md` §3 against the real implementation, one at a time, each reverted after its predicted RED is observed. Record the actual RED set per mutation in Notes. M-B1 (drop the `mkdir -p`) and M-B2 (drop the `|| true`) are the two that guard the CRITICAL finding of the adversarial review — and M-B2's catcher only works through the `run bash -c` harness of T019 (m2), never `run <function>`. M4's catcher is the behavioural oracle, not the naive one. **M19–M21 are new** (`/speckit-analyze` 2026-09-19): M19 reinstates the pruner's default `DIR`, M20 swaps the content-based `--list-markers` probe for a status-based one, M21 adds a `tmux capture-pane` probe to the retry loop. The three guard remediations that previously had no mutation at all.
- [X] T026 [P] `CHANGELOG.md`: `[Unreleased]` → `### Fixed` entry for `036-cold-start-boot-resilience` above the 034 entry, naming the four defects and the incident that surfaced them.
- [X] T027 [P] `README.md` and `docs/architecture.md`: both currently tell the operator to put `CHANNEL_HEALTH_TIMEOUT` in the workspace `.env` (`README.md:150`, `docs/architecture.md:127`) — update to the `agent.yml` field and note that the rendered value wins. `CLAUDE.md`: the watchdog-timeout paragraph gains the new field and the boot retry; `git add -f CLAUDE.md` at commit time (gitignored).
- [X] T028 `VERSION` → `0.26.0` — FIRST `git show origin/main:VERSION`, then bump. **Moving target, which is exactly why the check exists**: at first writing `origin/main` read `0.24.0` with `0.25.0` in PR #96; #96 merged; then PR #97 took it to `0.25.1` and **this branch was re-based onto that commit**, so the working tree already reads `0.25.1` before this task runs. The bump is to `0.26.0` regardless — a MINOR over whatever PATCH line #97 ends on. A rebase auto-merges `VERSION` without flagging a semantic conflict (lesson 023), so read `origin/main` at the moment of the bump rather than trusting any number written here.
- [X] T029 Gates. The earlier wording carved out a permitted exception for the `askq-guard-config.bats` red on the 5.x arm; **that exception is withdrawn** — the red was the SIGPIPE defect, not contention, and PR #97 fixed it (see the correction in Notes). The gate is now the plain one: **both arms N / 0 not ok, with the same total count**, over the post-#97 baseline of 1417/0. No named exception is permitted; if one appears, measure it before naming it a flake. Also run the FR-013 freeze oracles of T019 (m3) here. Then: `shellcheck -S error …` rc=0 (the exact CI command); `python3 -B -m py_compile docker/scripts/apply_telegram_typing_patch.py` and zero `__pycache__`; byte audit `LC_ALL=C grep -rc $'\xcc\x80'` across the patcher, the touched bats files, `specs/036-cold-start-boot-resilience/` and the docs — empty; `git diff --stat` limited to the touchpoints named in `plan.md`.
- [ ] T030 Live gate on ferrari, `donna` **first** (inverted relative to 034 on purpose: `donna` is the agent that reproduces the defect and the one still carrying the temporary override). Follow `quickstart.md` §4: capture preconditions, SC-004 (retire `docker-compose.override.yml`, expressing its value in `agent.yml`, regenerating **through** `custom-apply.sh` because `donna`'s Google MCP servers live only in the derived `.mcp.json`), SC-001 (the warm stops lying), SC-003 (a cold boot converges with no override and no container restart), SC-005/SC-006 (`doctor` truthful), then `linus` as the no-regression control. **Never run `docker compose config` with context lines** — it expands and prints every secret in the environment; filter to the exact key.

---

## Dependencies & Execution Order

### Phase dependencies

- **Setup (1)** → **Foundational (2)** → **US1 (3)** → **US2 (4)** → **US4 (5)** → **US3 (6)** → **US5 (6b)** → **DOCKER_E2E (7)** → **Polish (8)**.
- US5 sits after US3 and before Phase 7 for one reason: it touches `docker/scripts/wizard-container.sh`, which is image-baked, and Phase 7 is where the image gets built and exercised. It depends on nothing else and could be done at any point; placing it last keeps the image-baked edits contiguous.
- T003 (sourcing `env_file.sh`) blocks T011. T002 blocks T009/T010 (`schema.bats:52` fails without the fixture field).
- T016 (`--list-markers`) blocks T017 (`agentctl` consumes it) and E-E.
- T021 (the marker writer) blocks T022 (the marker reader) and E-F.
- US3 is last by design, not by priority: it touches the watchdog and must land on a green tree.

### Within each story

RED test task first, with the observed RED set recorded, then the implementation, then GREEN plus
`shellcheck` and — where the patcher changed — `py_compile` and the byte audit.

### Parallel opportunities

- T010 alongside T009 (different files).
- T018 alongside T016/T017 (docs vs code).
- T026 and T027 together after T025.

---

## Implementation Strategy

### MVP = US1 + US2

Those two alone close the measured outage: the warm stops failing silently, and the window becomes
configuration instead of a hand-edited override. US4 and US3 remove the failure mode's teeth for the
general case and stop `doctor` from lying, but neither is required to end the incident.

### Incremental delivery

1. Phase 2 → fixtures and the `env_file.sh` wiring; no behaviour change yet.
2. Phase 3 (US1) → the pre-warm genuinely warms; `donna`'s two spurious warnings disappear.
3. Phase 4 (US2) → the override becomes `agent.yml`; SC-004 becomes reachable.
4. Phase 5 (US4) → `doctor` stops emitting a false warning it has emitted for months.
5. Phase 6 (US3) → a slow first boot retries instead of restart-looping.
6. Phase 7 → DOCKER_E2E for real, both files.

---

## Notes

- Baseline (T001, 2026-09-19, measured on `a1fa449` — the exact commit this branch is cut from, so
  the numbers are this branch's baseline and were not re-run): bash 3.2.57 `PATH=/bin:$PATH bats
  tests/` = **1412 ok / 0 not ok**; bash 5.3.15 `bats tests/` = **1411 / 1**, the single red being
  `031: --regenerate backfills askuserquestion_guard.enabled=true when telegram plugin present`,
  re-run in isolation as `bats tests/askq-guard-config.bats` = **6/6 green**.
  `shellcheck -S error setup.sh scripts/lib/*.sh docker/scripts/*.sh docker/scripts/lib/*.sh`
  rc=0; `py_compile` ok, 0 `__pycache__`.

  **CORRECTION (2026-09-21): that red was never a CPU-contention flake — it was a production
  defect, and calling it contention is what let it live for months.** Both `--regenerate` guard
  backfills derived `enabled` from `yq -r '.plugins[]?' … | grep -qE '^telegram@'` under
  `setup.sh:4`'s `set -euo pipefail`: `grep -q` exits on the match, yq takes EPIPE on its next line
  and dies with 141, and pipefail turns a successful match into "no telegram plugin". Measured
  through the real `--regenerate`: **2 failures in 72 runs (~3%)**. `askq-guard-config.bats` and
  `reply-guard-config.bats` both seed `telegram@` FIRST, which is exactly the exposed ordering — so
  the suite was carrying a ~3% latent red that looked like noise. Fixed by `agent_yml_has_plugin` in
  PR #97, **merged to `main` as the squash `da9d2a3` (VERSION 0.25.1, 2026-09-21)**, and this branch
  is cut from that commit, so the operative baseline for T029 is now:
  **1417 ok / 0 not ok on bash 5.3.15 AND on 3.2.57, identical** (1412 + 5 from
  `tests/backfill-plugin-detection.bats`), with no permitted exception. Measured 2026-09-21 on this
  branch with US1 applied.

  The lesson generalises and is why US5 exists: a test that fails a few percent of the time is
  evidence of a race in the code under test until someone proves otherwise. "Contention" was an
  explanation that required no fix, so it got adopted without measurement.
  **Dated, not permanent.** When first recorded, the only touched files were `.specify/feature.json`
  and `specs/036-cold-start-boot-resilience/**`. That is no longer true: T002 and T003 are applied
  (both fixtures gained the field, `setup.sh` sources `env_file.sh`), so re-measure at the end of
  Phase 2 before treating these numbers as the comparison point for T029.
  **Branch re-based 2026-09-19**: 034 merged to main as the squash `6e363d7`, so this branch was
  re-cut from `main` + the `fix/voice-config-yq-oracle` hotfix (PR #97) rather than from 034's head.
  That hotfix matters for the baseline: without it, `034 US2(d2)` fails under yq 4.44.3.
- RED sets observed: US1 8/22 red in `mcp-warm.bats` + 2/11 in `start-services-warm.bats`;
  US2 18/24 red in `channel-window-config.bats` + 1 in `docker-render.bats` (the six green ones are
  no-regression guards that must pass before and after); US4 6/7 red in
  `agentctl-doctor-telegram-patches.bats` + 2/5 in the `--list-markers` block; US3 7/10 red in
  `start-services-watchdog.bats` + 2/6 in `agentctl-doctor-boot-attempt.bats`; US5 5/8 red in
  `sigpipe-boot-paths.bats`.
- DOCKER_E2E run (T024): **11/11 GREEN, run for real** on this host — Docker 29.6.2, Compose
  v5.3.1, image `agentic-pod:latest` (Alpine aarch64/musl, bash 5.3.9, busybox 1.37.0). Three
  harness defects of my own were found and fixed en route, none of them in the code under test:
  (a) `--entrypoint sh` is BUSYBOX in this image, and `start_services.sh`/`wizard-container.sh` are
  bash that source bash-syntax libs — busybox died on `backup_vault.sh` before reaching the function
  under test; the three affected cases now ask for `--entrypoint bash`. (b) `grep -qx 'ABSENT=[]'`
  reads `[]` as an empty character class, a SYNTAX error (status 2) — `-qxF` is what was meant.
  (c) E-C created a link pointing into `/opt/uv/tools` that resolves but never asserted it, leaving
  the `[ -e ]` guard with no oracle anywhere (see the mutation notes).
- Mutation results (T025): 18 host-side mutations run one at a time, each reverted after its
  predicted RED was observed; M-B1/M-B2/M-B4 were run separately during US3. **13 caught on the
  first pass; the 5 survivors each taught something different, and two were real coverage holes:**
  * **M2** (drop the pruner's `[ -e ]` guard, i.e. let it delete links that still RESOLVE) —
    **a real hole, in no tier at all.** The host test's "keeps a resolving symlink" case links to
    `$TMP_TEST_DIR/opt/uv/tools/…`, which does not start with `/opt/uv/tools/`, so the PREFIX guard
    saves it before the resolution guard is ever reached — and the host cannot build the real case,
    since `/opt/uv/tools` does not exist there. E-C had created such a link but never asserted it.
    Closed in E-C by creating a genuinely resolving link inside the image's own `/opt/uv/tools` and
    asserting it survives; re-measured RED (`LIVELINK=lost`) / GREEN. This guard sits inside a
    function containing `rm`, so the hole was worth finding.
  * **M16** (make `doctor` read only the first `server.ts`) — **a real hole**: the two-version case
    was written with the UNPATCHED directory first, where `head -1` produces the same warning as
    walking every match. Inverted to patched-first, which is the shape where `head -1` reports a
    clean pass over a cache that still holds an unpatched plugin. Re-measured RED/GREEN.
  * **M3** (drop the pruner's `-L` guard) — **not a hole: the mutation is not lethal.** Measured:
    `readlink` fails on a regular file and the `|| continue` protects it anyway. The quickstart
    assumed `-L` was the only guard; there is defence in depth.
  * **M15** and **M19** — mutations I wrote wrong, not weak oracles. M15 inserted the literal into a
    COMMENT, and the anti-drift oracle strips comments on purpose; M19's replacement text did not
    match the file, so nothing was applied.
- Gates (T029): bash 3.2.57 `PATH=/bin:$PATH bats tests/` = **1498 ok / 0 not ok**. bash 5.3.15
  measured 1495/3 while the adversarial review occupied the machine; all three are timeout-stubbed
  tests (`ensure_extra_marketplaces`, `ensure_official_marketplace`, `verify_channel_healthy`) and
  re-ran **0 red in 3 consecutive isolated runs**. Both arms report the same total (1495+3 = 1498),
  which is the count parity the gate requires. Per the correction recorded above, "contention" here
  is a measured cause (20+ concurrent agents, three sleep-stubbed tests) and not the label that hid
  the SIGPIPE defect — that one failed 29/400 with no load at all.
  `shellcheck -S error setup.sh scripts/lib/*.sh docker/scripts/*.sh docker/scripts/lib/*.sh` rc=0;
  `python3 -B -m py_compile` OK with 0 `__pycache__`; byte audit `LC_ALL=C grep -rc $'\xcc\x80'`
  clean across the patcher, `agentctl`, `setup.sh`, the docs, the touched bats files and
  `specs/036-cold-start-boot-resilience/`.
- **Gates RE-RUN 2026-09-22, and these are the numbers that count.** Every figure above predates the
  last round of remediation (`--force` removed from `_mcp_warm_one`, `channel_env_value` added,
  `_scratch_bin` export fixed, the `yml` probe moved ahead of doctor check 4, E-B rewritten), so it
  described a tree that no longer existed. Re-measured sequentially, nothing else competing:
  **bash 5.3.15 = 1502 ok / 0 not ok; bash 3.2.57 (`PATH=/bin:$PATH`) = 1502 ok / 0 not ok**,
  identical totals, **no named exception on either arm**. `shellcheck -S error -e SC1090,SC1091` over
  the exact CI file set rc=0; `python3 -B -m py_compile` OK with 0 `__pycache__`; byte audit clean;
  FR-013 freeze oracle green; `git diff --stat` inside the plan's touchpoints (27 tracked + 5 new
  test files + `specs/036-cold-start-boot-resilience/`).
- **DOCKER_E2E re-run 2026-09-22.** `docker-e2e-warm-cache` 11/11 green against an image whose baked
  `scripts/lib/mcp_warm.sh` is **sha-identical to the host copy** (`e30a5e77…781c`) — checked rather
  than assumed, because the whole point of the re-run was that `--force` had been removed after T024.
- **A red in `docker-e2e-postlogin` case 1, diagnosed as a PRE-EXISTING TEST DEFECT, and fixed.**
  The case is untouched by this feature (only case 2 was re-pointed), yet it failed on this branch
  and passed on `origin/main`. Measured rather than labelled:
  * Mechanism: the test slept a fixed 15s after `up -d` and then created the credential file. The
    watchdog's auth-flip detector needs that file to appear AFTER its first tick, which establishes
    the absent/present baseline; a file already present at baseline reads as "booted already
    authenticated" and correctly never arms the post-login retry. That is exactly the observed
    symptom: no `auth credential appeared` line anywhere in the container log.
  * Boot duration, 5 samples per side: **main 4-6s, this branch 4-7s** — overlapping distributions.
    Both observed failures had a 12-13s boot, the build-adjacent tail, which is when this test runs.
  * Controlled repro (touch timed off the boot log instead of the clock): green on the branch, with
    the flip line present. Same repro in the test's own fixed-sleep mode: 3/3 green on BOTH sides.
  * Rates under the real harness: branch 2 red / 3, main 0 red / 4. Suggestive, not conclusive — the
    mechanism is what settles it, not the ratio.
  * **No production impact**: a real `/login` lands minutes after boot, never 2 seconds after.
  * Fix (test-only, same file): wait for the boot log to announce `launching:`, then give the
    watchdog 5s for its baseline tick. The assertions are untouched, so the oracle is strengthened —
    an implicit assumption became a checked precondition. The wait deliberately avoids
    `docker compose logs | grep -q`: under `pipefail` the producer takes EPIPE on grep's first match
    and the condition silently goes false, the very class US5 audits. It reads into a variable and
    decides with `case`, like `agent_yml_has_plugin`.
  * Mutation: reverting to `sleep 15` reproduces 2 red / 3. Hardened: **3/3 green**, and both bash
    arms re-measured at 1502/0 afterwards.
- **CORRECTION to the T029 record, 2026-09-22 after the merge.** The line above says both arms were
  green with no named exception. That was true of *this machine* and false of the gate: PR #98's
  `bats — bash 5.x (ubuntu-latest)` arm went **red**, and the PR was merged before anyone read it, so
  `main` shipped red — the state feature 025 exists to prevent. Two tests of my own,
  `036 US5(a)` cases 1 and 3, failed with `Argument list too long`.
  * Cause, and it is a platform limit rather than logic: the harness handed a 200 KiB pad to the
    probe **through the environment** (`PAD="$pad" bash probe.sh`). Linux caps each individual
    `argv`/`envp` string at `MAX_ARG_STRLEN` (32 pages, 128 KiB) and returns `E2BIG`; macOS enforces
    only a 1 MiB total, with no per-string limit. Green on both local arms, red on Linux, every time.
  * Fixed on `fix/sigpipe-test-arg-limit`: the pad goes to a file and the probe reads it with
    `$(cat …)`, in-process, with no exec in the path.
  * Verified where it actually fails, not here: **RED/GREEN reproduced in a Linux container**
    (Alpine, bash 5.3.9) — without the fix exactly cases 1 and 3 fail, with it 8/8. Then the full
    suite in a CI-faithful replica (`debian:bookworm`, non-root, pinned yq 4.44.3, plus `age`,
    `gettext-base`, `tmux`, `busybox`): **1502/0**.
  * The harness lesson is worth as much as the fix: the FIRST container run was Alpine **as root**
    and reported 20 reds, none of them real — "unwritable directory" tests cannot fail for a user
    who ignores mode bits. An unfaithful oracle is not a weaker oracle, it is a different one. Both
    points are now in `CLAUDE.md`.
- Live gate (T030): _pending_
- **Branch decision revised 2026-09-19.** The design was written assuming this work would ride the
  034 PR. The operator revised that once 034 was finished, gated and already deployed: 034 shipped
  alone as `0.25.0` (`a1fa449`, PR #96) and this feature gets its own branch, its own PR and its own
  `0.26.0`. `spec.md`, `plan.md` and `contracts/patch-marker-listing.md` were updated accordingly.
- **The adversarial review's CRITICAL finding lives in T019/T021/T025.** The boot marker writes into a
  directory that does not exist on attempt 1 (`/tmp` is a tmpfs emptied on every container start; the
  only `mkdir -p` is deep inside `start_session`) while the script runs under `set -euo pipefail`.
  Without both the preceding `mkdir -p … || true` and the per-write `|| true`, every docker agent
  enters a restart loop — the exact failure this feature exists to end, generalised to the fleet.
  M-B1 and M-B2 are its mutations; do not let either become a paraphrase.
