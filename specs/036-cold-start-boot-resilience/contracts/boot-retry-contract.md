# Contract: bounded retry of the initial boot session (US3)

Feature 036, User Story 3. Covers FR-010 … FR-013 plus FR-020 / FR-021 (the boot-aware `doctor`
seam, added by operator decision on 2026-09-19), and the acceptance scenarios of
[`spec.md`](../spec.md) US3, with the canonical strings of
[`data-model.md`](../data-model.md) §5 and §5b.

This contract touches the watchdog file. The repo has an expensive regression precedent there
(the bridge watchdog reverted in `ebfe35f`), so every clause below carries an oracle and the
prohibition of C10 is as load-bearing as the behaviour of C1.

## Scope

**In scope** — four files:

| File | Edit |
| --- | --- |
| `docker/scripts/start_services.sh` | new constant `MAX_BOOT_ATTEMPTS=3` beside `MAX_CRASHES`/`WINDOW` (`:258-259`); new function `start_initial_session`, which also writes and removes the boot-in-progress marker (C13-C15); `main()`'s initial-boot block (`:1279-1282`) calls it |
| `tests/start-services-watchdog.bats` | new tests over the new function, using the existing `_stub_pgrep_after` seam (`:357-371`) |
| `scripts/agentctl` | check 4 (`:381-390`) learns to read the boot marker through `_in_container` (`:332-335`) and emit CANON-H1 instead of `_doctor_fail` while a boot is legitimately fresh (C16) |
| `tests/agentctl-doctor-boot-attempt.bats` (new) | host bats over that check, in the mould of `tests/agentctl-doctor-claude-oauth.bats:11-35` (docker shim on `PATH`, `agent.yml` in `TMP_TEST_DIR`, `cd` into it, run `agentctl doctor`) |

The `scripts/agentctl` row exists because of an **operator decision taken 2026-09-19** that reversed
an earlier prohibition in this file; see R1 and C16. It is a US3 concern, not a US4 one: the signal it
consumes is written by `start_initial_session`, and the doctor check is meaningless without it.

**Out of scope, and required to stay untouched**: `_run_watchdog` (`:1207-1271`), the crash budget
(`:258-263`, `:883-898`), `verify_channel_healthy` (`:765-777`), `channel_health_timeout`
(`:739-745`), `warn_if_channel_timeout_risky` (`:753-760`), `start_session` (`:813-850`), and every
line of `modules/docker-compose.yml.tpl` (`restart:` `:38`, `healthcheck:` `:46-51`).

## Current behaviour (the thing being replaced)

```bash
# docker/scripts/start_services.sh:1273-1288
main() {
  boot_side_effects
  warn_if_channel_timeout_risky
  log "starting tmux session '$SESSION'"
  if ! start_session; then
    log "ERROR: initial tmux session failed to start"
    exit 1
  fi
  qmd_watch_start
  _run_watchdog
}
```

One attempt, then `exit 1`. The asymmetry with the watchdog path (`:1269`, which absorbs the same
failure) is measured in `research.md` D4 and is the whole reason this story exists.

## Canonical strings

Copied verbatim from `data-model.md` §5. Implementation and test oracles use these and nothing else.

**CANON-B1** — one per attempt:

```text
initial session attempt N/3
```

**CANON-B2** — once, on exhaustion:

```text
ERROR: initial tmux session failed to start after 3 attempts
```

Both reach the journal through `log()` (`:18`), which prefixes
`[YYYY-MM-DD HH:MM:SS] [start_services] ` and writes to **stderr**. Oracles therefore match on
substring, never on a whole line.

`N` and the `3` are rendered from `MAX_BOOT_ATTEMPTS`, not typed as literals — see C2. The strings
above are those two forms at the default constant value.

**CANON-H1** — emitted by `agentctl doctor`, not by the container (`data-model.md` §5b):

```text
Container health: starting (boot attempt N/3)
```

It is an **informational** line (`_doctor_pass`/`_doctor_warn` class, never `_doctor_fail`), and `N`
comes from the marker file, `3` from the same marker's denominator convention as CANON-B1.

> **The series is `CANON-H*`, never `CANON-D*`.** `CANON-D1` is already owned by
> [`patch-marker-listing.md`](patch-marker-listing.md) for a different `doctor` line, and
> `data-model.md` §5b forbids any contract from redefining a `CANON-*` id another one owns.

### CANON-B2 preserves today's line as a prefix

`ERROR: initial tmux session failed to start` — the exact text emitted today at `:1280` — survives
**verbatim as a substring** of CANON-B2. Any log scraping, alert rule or runbook written against the
pre-036 wording keeps matching after this change. This is a contract clause, not a coincidence of
phrasing: see **C7**.

## Required shape

```bash
# ── Config (beside MAX_CRASHES / WINDOW, :258-259) ──
# 036/US3: bounded retry of the INITIAL session only. The watchdog respawn path
# already absorbs a failed verify_channel_healthy (:1269); the initial boot did
# not, and exiting there discards the container's writable layer — where the
# freshly-warmed uv/npm caches live — so every restart started colder than the
# last (research.md D4). Three attempts inside ONE container life let those
# caches persist across retries. Exhaustion still exits non-zero.
MAX_BOOT_ATTEMPTS=3

# ── Boot ──
# Returns 0 as soon as an attempt succeeds, 1 after MAX_BOOT_ATTEMPTS failures.
# No sleep between attempts: a failed verify_channel_healthy has already spent
# the whole channel window, and start_session kills + respawns tmux itself
# (:833-835). Logs CANON-B1 per attempt and CANON-B2 on exhaustion, so the
# caller only has to decide the exit code.
#
# The boot-attempt marker lets `agentctl doctor` tell "retrying its first boot"
# apart from "permanently unhealthy" (FR-020). Every line that touches it is
# non-fatal: this function runs under `set -euo pipefail` (:14) and must never
# be the reason an agent fails to boot.
start_initial_session() {
  local attempt=1
  # /tmp is a tmpfs and this directory does not exist yet on a fresh container:
  # the only other mkdir for it lives inside start_session (:830), AFTER the
  # whole preamble. Without this line the first attempt's redirect fails.
  mkdir -p "$WATCHDOG_RUNTIME_DIR" 2>/dev/null || true
  while [ "$attempt" -le "$MAX_BOOT_ATTEMPTS" ]; do
    log "initial session attempt ${attempt}/${MAX_BOOT_ATTEMPTS}"
    printf '%s %s\n' "$attempt" "$(date +%s)" > "$WATCHDOG_RUNTIME_DIR/boot-attempt" 2>/dev/null || true
    if start_session; then
      rm -f "$WATCHDOG_RUNTIME_DIR/boot-attempt" 2>/dev/null || true
      return 0
    fi
    attempt=$(( attempt + 1 ))
  done
  rm -f "$WATCHDOG_RUNTIME_DIR/boot-attempt" 2>/dev/null || true
  log "ERROR: initial tmux session failed to start after ${MAX_BOOT_ATTEMPTS} attempts"
  return 1
}

# ── main() ──
  log "starting tmux session '$SESSION'"
  start_initial_session || exit 1
```

Those three marker lines are copied **verbatim** from `data-model.md` §5b; C13, C14 and C15 make each
one normative, and mutations M-B1 … M-B3 remove one at a time.

Two shape decisions worth recording:

1. **CANON-B2 is emitted by `start_initial_session`, not by `main()`.** `main()` is not host-testable
   (it runs `boot_side_effects` and enters `_run_watchdog`), so a message emitted there would have no
   host oracle. Putting it in the function makes both canonical strings and the return code
   assertable from bats.
2. **`log "starting tmux session '$SESSION'"` (`:1278`) stays byte-identical** and stays *before* the
   first CANON-B1, so the boot log reads
   `starting tmux session 'agent'` → `initial session attempt 1/3` → … .
3. **The marker is written by `start_initial_session`, never by `start_session`.** `start_session` is
   also the watchdog's respawn path (`:1269`), and a respawn is not an initial boot: writing the
   marker there would make a channel that dies in steady state look like a boot in progress forever
   (`data-model.md` §5b, *Scope boundary*). C15 and C8 together fence this off.

## Clauses

Each clause is normative. "Oracle" is the check that must exist and must fail if the clause is
broken (SC-008: reverting the behaviour turns a named test red).

### C1 — Three attempts total at the initial boot

A failed `start_session` at the initial boot is retried until `MAX_BOOT_ATTEMPTS` attempts have been
made. The default is **3** (initial + 2 retries).

> **Oracle** — `tests/start-services-watchdog.bats`: source with `START_SERVICES_NO_RUN=1`, redefine
> `start_session() { echo attempt >> "$TMP_TEST_DIR/attempts"; return 1; }`, run
> `start_initial_session`; assert `[ "$(wc -l < "$TMP_TEST_DIR/attempts")" -eq 3 ]`.
> Mutation: changing the loop to a single call leaves 1 line → red.

### C2 — The attempt count is a constant, never derived from the channel window

`MAX_BOOT_ATTEMPTS` is a plain integer constant declared beside `MAX_CRASHES`/`WINDOW`. No expression
anywhere derives it from `CHANNEL_HEALTH_TIMEOUT`, `channel_health_timeout()`, `WINDOW` or
`MAX_CRASHES`. The denominator of CANON-B1 and the count in CANON-B2 are interpolated from the
constant, not typed as the literal `3`.

> **Oracle (a)** — same attempt-counting harness with `MAX_BOOT_ATTEMPTS=2` exported: exactly 2
> attempts, and the output contains `initial session attempt 1/2` and
> `failed to start after 2 attempts`. A hardcoded `3` in either string turns this red.
>
> **Oracle (b)** — run the C1 harness twice, once with `CHANNEL_HEALTH_TIMEOUT=1` and once with
> `CHANNEL_HEALTH_TIMEOUT=420`: the attempt count is 3 in both.
>
> **Oracle (c)** — static: `grep -n 'MAX_BOOT_ATTEMPTS=' docker/scripts/start_services.sh` matches
> exactly one line and that line is `MAX_BOOT_ATTEMPTS=3`.

### C3 — No sleep is inserted between attempts

The retry loop introduces no `sleep`, no backoff and no timer of its own. The pacing already exists:
a failed `verify_channel_healthy` has consumed the entire channel window (`:769-775`), and
`start_session` performs its own `tmux kill-session` + `sleep 1` + `sleep 2` (`:833-837`).

> **Oracle** — the C1 harness with a `start_session` stub that returns immediately: wall time of
> `start_initial_session` under 3 s (`start=$(date +%s)` / `end=$(date +%s)`, mould
> `start-services-watchdog.bats:383-391`). Any added inter-attempt sleep of a realistic size
> (≥ 2 s × 2) turns this red.
>
> **Oracle (static)** — the body of `start_initial_session` contains no `sleep`:
> `sed -n '/^start_initial_session() {/,/^}/p' docker/scripts/start_services.sh | grep -c sleep` is
> `0`.

### C4 — Success on the second attempt does not kill the container

As soon as an attempt returns 0 the loop stops, no further attempt runs, no CANON-B2 is emitted, and
`main()` proceeds to `qmd_watch_start` + `_run_watchdog` exactly as on a clean first boot. This is
US3 acceptance scenario 1.

> **Oracle** — stub `start_session` to fail once and then succeed (counter file); run
> `start_initial_session`; assert `status -eq 0`, exactly 2 attempts recorded, output contains
> `initial session attempt 1/3` **and** `initial session attempt 2/3`, and output does **not**
> contain `failed to start after`. The negative assertion is placed last, or written as
> `run ! grep …` — an intermediate `[[ ]]`/`!`-negated pipeline does not fail a bats test
> (`tests/…` lesson recorded in `CLAUDE.md`; memory note *bats intermediate `[[ ]]` quirk*).

### C5 — Exhausting the attempts still exits non-zero

`start_initial_session` returns 1 after the last failure and `main()` turns that into `exit 1` — the
same status the pre-036 code used — so `restart: unless-stopped`
(`modules/docker-compose.yml.tpl:38`) escalates exactly as today. This is FR-011 / US3 acceptance
scenario 2.

> **Oracle (a)** — `run start_initial_session` with an always-failing stub: `[ "$status" -eq 1 ]`
> (assert the value, not merely non-zero — a bare `-ne 0` would also pass on a syntax error).
>
> **Oracle (b)** — static: the initial-boot block of `main()` still contains `exit 1`, and
> `grep -c 'exit 1' docker/scripts/start_services.sh` does not decrease relative to the baseline
> recorded in `quickstart.md`.

### C6 — Every attempt is logged distinguishably (CANON-B1)

One CANON-B1 line per attempt, emitted **before** the attempt runs, so the operator can tell a retry
inside one container life from a container restart. This is FR-012 / US3 acceptance scenario 3.

> **Oracle** — always-failing stub: `$output` contains all three of `initial session attempt 1/3`,
> `initial session attempt 2/3`, `initial session attempt 3/3`. (bats' `run` merges stderr into
> `$output`; `log()` writes to stderr — same assumption the existing
> `warn_if_channel_timeout_risky` test relies on, `:408-416`.)

### C7 — The exhaustion line is CANON-B2 and keeps the legacy prefix

Exactly one CANON-B2 line is emitted, only on exhaustion, and it contains the pre-036 text
`ERROR: initial tmux session failed to start` as a literal substring.

> **Oracle (a)** — always-failing stub: `$output` contains
> `ERROR: initial tmux session failed to start after 3 attempts`, exactly once
> (`[ "$(grep -c 'failed to start after' <<<"$output")" -eq 1 ]`).
>
> **Oracle (b)** — backward compatibility, asserted separately so it cannot be lost in a later
> reword: `$output` contains the bare legacy substring
> `ERROR: initial tmux session failed to start`. A reword to e.g.
> `ERROR: initial session failed after 3 attempts` satisfies (a)'s intent but turns (b) red — which
> is the point.
>
> **Oracle (c)** — success path (C4 stub): neither substring appears.

### C8 — The watchdog respawn path stays BYTE-IDENTICAL

`_run_watchdog` is not edited. In particular line `:1269` keeps its exact bytes:

```bash
    start_session || log "WARN: respawn failed, watchdog will retry in 2s"
```

The retry belongs to the initial boot only. The watchdog must keep calling `start_session` **once**
per tick and absorbing a failure into the next 2 s tick; wrapping it in `start_initial_session`
would multiply the crash-budget cadence by three and silently break the escalation arithmetic that
`warn_if_channel_timeout_risky` encodes.

> **Oracle (a)** — content sha of the whole function, taken on the current tree before the edit and
> re-taken after:
>
> ```bash
> sed -n '/^_run_watchdog() {/,/^}/p' docker/scripts/start_services.sh | shasum -a 256
> # 745a1a70f53eee28e9f87acbc406580b2e7a4ce44cb1fada19651beef94b32c4  (65 lines, measured 2026-09-18)
> ```
>
> The sha is over the extracted function, not over line numbers, so adding `MAX_BOOT_ATTEMPTS` above
> it does not move the oracle.
>
> **Oracle (b)** — line-level, cheap and readable in a bats test:
> `grep -c 'start_session || log "WARN: respawn failed, watchdog will retry in 2s"'` is `1`, and
> `grep -c 'start_initial_session'` inside the extracted `_run_watchdog` body is `0`.

### C9 — The crash budget is not touched

`MAX_CRASHES=5` (`:258`), `WINDOW=300` (`:259`), `CRASH_TIMES` (`:263`) and `crash_budget_check`
(`:883-898`) are unchanged, and the boot retry does **not** record attempts into `CRASH_TIMES`. A
boot attempt is not a crash: the budget's contract is "5 watchdog respawns inside a trailing 300 s
window", and injecting three boot attempts into it would make a slow first boot consume 60 % of the
budget before the watchdog has ticked once.

> **Oracle (a)** — the five existing `crash_budget_check` tests
> (`start-services-watchdog.bats:27,40,47,57,68`) plus
> `crash budget: 5 failures fit the window at the 60s default…` (`:398`) stay green, byte-identical.
>
> **Oracle (b)** — static: `grep -c 'CRASH_TIMES' docker/scripts/start_services.sh` is **3** (the
> declaration `:263` and the two references inside `_run_watchdog`, `:1260` and `:1267`) and
> `grep -c 'MAX_CRASHES' …` is **10** — both measured on the pre-036 tree. `start_initial_session`
> references neither symbol.
>
> **Oracle (c)** — `warn_if_channel_timeout_risky` keeps its breakeven expression
> `WINDOW / (MAX_CRASHES - 1) - 5` (`:756`) unchanged; its test at `:408` stays green.

### C10 — PROHIBITION: no automated stuck-channel detection

This feature introduces **no** detection, heuristic, probe or timer for the "bun alive but MCP
notifications dropped" state. Not in the retry loop, not in `start_session`, not in the watchdog.
Nothing in US3 scrapes a tmux pane, calls the Telegram API, or infers liveness from anything other
than the two signals that already exist: `tmux has-session` (`:838`, `:856-858`) and
`pgrep -f "bun server.ts"` (`:770`).

The prohibition is written down in two places in the repo and both are binding:

- `CLAUDE.md:75`, section *Watchdog state machine (`docker/scripts/start_services.sh`)*: "There used
  to be a 'bridge watchdog' … it was reverted in commit `ebfe35f` because tmux pane scraping produced
  too many false positives. … **Don't re-add automated detection for this without solving the
  false-positive problem first** — it killed sessions every ~2 minutes during normal operation."
- `docker/scripts/start_services.sh:900-930`, the surviving comment block, which records the reverted
  commits (`3c5465f` / `fcb6744`) and why. That comment block is documentation of a decision, not
  dead code to revive.

Manual recovery for that state remains `heartbeatctl kick-channel`.

> **Oracle (a)** — static, over the diff of this feature: the added lines contain none of
> `capture-pane`, `getUpdates`, `api.telegram.org`, `bridge_watchdog`, `suspicion`.
> `git diff main -- docker/scripts/start_services.sh | grep '^+' | grep -cE 'capture-pane|getUpdates|api\.telegram\.org|bridge_watchdog|suspicio'` is `0`.
>
> **Oracle (b)** — C8's function sha: any new per-tick detection would have to live in
> `_run_watchdog`, which is frozen.

### C11 — The retry is reachable from a host test (seam)

The loop lives in a named shell function, not inline in `main()`, so `START_SERVICES_NO_RUN=1` +
`source` reaches it (the seam every test in `start-services-watchdog.bats` already uses, `:9-23`).
The function name `start_initial_session` is fixed by this contract; if `tasks.md` renames it, the
contract and the tests change in the same edit.

The channel-window seam for an end-to-end-ish host test is the existing `_stub_pgrep_after`
(`:357-371`): it shadows `pgrep` with a counter-driven fake that "finds bun server.ts" only on its
K-th call **and** shadows `sleep` with a no-op, so `verify_channel_healthy` can be driven to any
elapsed value without burning wall clock. Because the counter file persists across calls, a single
`_stub_pgrep_after K` drives the *whole* retry sequence: with `CHANNEL_HEALTH_TIMEOUT=60` each
attempt consumes 30 `pgrep` calls (elapsed `0,2,…,58`), so `K=31` makes attempt 1 fail and attempt 2
succeed — the C4 scenario against the real `verify_channel_healthy` rather than a stub. Reset with
`: > "$TMP_TEST_DIR/pgrep.count"` between cases, as `:378` and `:426` already do.

#### "stub tmux only" does not reach `verify_channel_healthy` (adversarial review, MEDIUM — verified)

The first draft of this clause prescribed a `start_session` "**not** stubbed beyond `tmux`". That
test is **impossible to write**, and would silently pass for the wrong reason. Traced in the tree:

- `start_session` (`:813`) computes `cmd=$(next_tmux_cmd)` (`:823`), and the channel gate is
  `if [[ "$cmd" == *"--channels "* ]]` (`:840`) — `verify_channel_healthy` runs **only** inside it.
- `next_tmux_cmd` (`:666`) reaches Case C (the only branch that emits `--channels `) only after
  `_channel_plugin_ready` **or** `has_oauth_token` is true (`:678`) *and* `has_telegram_token` is
  true (`:687`). In the bats environment none of those holds: `setup()` unsets
  `CLAUDE_CODE_OAUTH_TOKEN` (`tests/start-services-watchdog.bats:20`), `HOME` is an empty tmpdir, so
  the plugin cache does not exist.
- Result: Case A, `cmd` is the bare `CLAUDE_CONFIG_DIR=… claude`, the gate at `:840` is false,
  `start_session` returns 0 on the **first** attempt, and a "second attempt" can never be observed.
  The `_stub_pgrep_after 31` counter would never be consulted.

#### The overrides the test must actually install

Two routes; both are legitimate, the first is the recommended one because it has the fewest moving
parts. Both follow the real mould of `tests/start-services-watchdog.bats:220-250`, which already
redefines boot dependencies as shell functions after sourcing.

**Route 1 (recommended) — shadow `next_tmux_cmd` so the gate is satisfied by construction:**

```bash
@test "US3: initial boot — channel appears on the second attempt, container never exits" {
  # The channel gate at :840 is a substring test on the command string. Emitting a
  # command that carries "--channels " is the whole requirement; nothing execs it,
  # because tmux is stubbed.
  next_tmux_cmd() { echo "claude --channels plugin:telegram --dangerously-skip-permissions"; }
  # tmux: new-session/pipe-pane/kill-session are no-ops, has-session succeeds.
  mkdir -p "$TMP_TEST_DIR/bin"
  printf '#!/bin/bash\nexit 0\n' > "$TMP_TEST_DIR/bin/tmux"
  chmod +x "$TMP_TEST_DIR/bin/tmux"
  _stub_pgrep_after 31          # also shadows sleep; 30 pgrep calls per 60s window
  unset CHANNEL_HEALTH_TIMEOUT  # → channel_health_timeout() = 60

  PATH="$TMP_TEST_DIR/bin:$PATH" run start_initial_session
  [ "$status" -eq 0 ]

  # bats' `run` clobbers $output, so freeze it once, then count with `run grep -c`.
  printf '%s\n' "$output" > "$TMP_TEST_DIR/boot.out"
  run grep -c 'initial session attempt 1/3' "$TMP_TEST_DIR/boot.out"
  [ "$output" -eq 1 ]
  run grep -c 'initial session attempt 2/3' "$TMP_TEST_DIR/boot.out"
  [ "$output" -eq 1 ]
  run grep -c 'initial session attempt 3/3' "$TMP_TEST_DIR/boot.out"
  [ "$output" -eq 0 ]
  run grep -c 'failed to start after' "$TMP_TEST_DIR/boot.out"
  [ "$output" -eq 0 ]
}
```

Never a bare intermediate `grep -q`: an unmatched one aborts the test under bats' errexit (memory
note *bats intermediate `[[ ]]` quirk*). `run grep -c` is safe precisely because `run` swallows
grep's exit 1 on a zero count while still printing the `0`.

**Route 2 — drive the real `next_tmux_cmd` into Case C.** Redefine, as plain functions after the
`source`: `_channel_plugin_ready() { return 0; }` (or `has_oauth_token() { return 0; }`),
`has_telegram_token() { return 0; }`, `ensure_channel_env_synced() { :; }`, plus the four the
existing mould at `:213-217` already stubs — `pre_accept_extra_marketplaces`,
`ensure_extra_marketplaces`, `ensure_official_marketplace`, `ensure_all_plugins_installed`. Same
`tmux` stub, same `_stub_pgrep_after 31`. This route additionally proves the real Case-C string
carries `--channels `, at the cost of five more overrides and coupling to `next_tmux_cmd`'s
branching.

Either route may also stub `start_session`'s preamble (`pre_accept_bypass_permissions`,
`pre_seed_onboarding`, `pre_warm_mcps`) for speed. It is not required: `pre_install_stop_hook`
(`:784`) and `pre_install_askq_hook` (`:794`) are already no-ops when the `/workspace/scripts/hooks/`
helper is absent, and `pre_warm_mcps` is a no-op with no `.mcp.json` under `$WORKDIR`.

> **Oracle (a)** — the test above: status 0, exactly one `initial session attempt 1/3` line, exactly
> one `initial session attempt 2/3` line, zero `initial session attempt 3/3` lines, and zero
> `failed to start after` lines (all four as `run grep -c` + `[ "$output" -eq N ]`). If the loop is
> inlined into `main()` the test cannot be written at all — which is the failure this clause
> prevents.
>
> **Oracle (b)** — the case the contract itself calls for under *Non-obvious behaviour worth
> knowing*: an **unauthenticated** first boot emits exactly ONE CANON-B1 line and the loop ends.
> Same `tmux` stub, **no** `next_tmux_cmd` override, `CLAUDE_CODE_OAUTH_TOKEN` unset,
> `_channel_plugin_ready() { return 1; }` and `has_telegram_token() { return 1; }` (mould
> `:237-250`, the Case-A regression guard), so `next_tmux_cmd` yields bare `claude`. Assert
> `status -eq 0`, `run grep -c 'initial session attempt' …` equal to `1`, and
> `run grep -c 'failed to start after' …` equal to `0`. This is the regression fence against a later
> change that "fixes" the single attempt on an unauthenticated boot — which would burn three
> preambles, and three plugin-install passes, before every `/login`.

### C12 — The change ships inside the image

`start_services.sh` is image-baked (`docker/Dockerfile`, copied to `/opt/agent-admin/scripts/`), so a
host test cannot prove delivery. FR-019 makes DOCKER_E2E mandatory for this story.

> **Oracle** — in `tests/docker-e2e-warm-cache.bats` (or a sibling), mould
> `tests/docker-e2e-postlogin.bats:193`:
>
> ```bash
> run in_container grep -c 'MAX_BOOT_ATTEMPTS' /opt/agent-admin/scripts/start_services.sh
> [ "$output" -ge 1 ]
> run in_container grep -c 'initial session attempt' /opt/agent-admin/scripts/start_services.sh
> [ "$output" -ge 1 ]
> ```
>
> `grep -c` exits 1 when the count is 0, so under a `set -e` container script the count must be
> captured the way `data-model.md` §6 prescribes — never `$(grep -c … || echo 0)`.

### C13 — The runtime directory is created before the first attempt, non-fatally

`start_initial_session` MUST run, **once, before the loop**:

```sh
mkdir -p "$WATCHDOG_RUNTIME_DIR" 2>/dev/null || true
```

This is the clause that a first draft of the design missed, and the miss was CRITICAL. Three verified
facts make it load-bearing:

1. `WATCHDOG_RUNTIME_DIR="/tmp/agent-watchdog"` (`docker/scripts/start_services.sh:255`).
2. `/tmp` is a **tmpfs** declared in the compose (`modules/docker-compose.yml.tpl:36-37`,
   `size=100m`), so it is empty on every container start.
3. The only other `mkdir -p` for that directory lives at `:830` — **inside** `start_session`, after
   the whole preamble. On attempt 1 it has not run yet.

Without the `mkdir`, the marker redirect on attempt 1 targets a directory that does not exist. And
`start_services.sh` runs under `set -euo pipefail` (`:14`), so without the `|| true` that failed
redirect would abort the boot of **every docker agent**, turning a diagnostics nicety into a
fleet-wide outage. The failure mode is the opposite of subtle and the opposite of rare: it is
attempt 1 of every cold start.

> **Oracle (host bats, `tests/start-services-watchdog.bats`)** — point the directory at a path that
> does **not** exist, and prove the function both survives and produces the marker:
>
> ```bash
> @test "US3: the boot marker directory is created on the first attempt (dir absent)" {
>   WATCHDOG_RUNTIME_DIR="$TMP_TEST_DIR/never-created/agent-watchdog"   # NOT mkdir'ed
>   [ ! -d "$WATCHDOG_RUNTIME_DIR" ]
>   start_session() { return 1; }        # force all three attempts
>   run start_initial_session
>   [ "$status" -eq 1 ]                  # returned normally, did not abort
>   [ -d "$WATCHDOG_RUNTIME_DIR" ]       # the mkdir ran
> }
> ```
>
> `WATCHDOG_RUNTIME_DIR` is a plain assignment at `:255`, executed on every load, so the override
> MUST come **after** the `source` — the same trap `tests/start-services-warm.bats:34-36` documents
> for `WORKDIR`. Setting it in the environment before sourcing is silently overwritten.
>
> **Mutation M-B1**: delete the `mkdir -p` line. The marker never appears on attempt 1 (C14's
> oracle goes red) and, with the `|| true` also removed, the function aborts instead of returning 1.

### C14 — The marker is written at the top of every attempt, non-fatally, as `<attempt> <epoch>`

Immediately after CANON-B1 and before `start_session`, each iteration MUST run:

```sh
printf '%s %s\n' "$attempt" "$(date +%s)" > "$WATCHDOG_RUNTIME_DIR/boot-attempt" 2>/dev/null || true
```

Normative details, all from `data-model.md` §5b:

- **Path**: `${WATCHDOG_RUNTIME_DIR}/boot-attempt`, the same directory as the existing
  `CHANNEL_MARKER` (`:255-256`).
- **Content**: one line, `<attempt> <epoch>`, space-separated, e.g. `2 1789420000`. The epoch is
  what makes C16's freshness guard possible; a bare attempt number would let `doctor` answer
  "starting" forever for a dead agent.
- **`|| true` is mandatory**, for the same `set -euo pipefail` reason as C13. The write is a
  diagnostics side effect; it may never decide whether an agent boots.
- **Overwrite, not append** (`>`): the marker describes the attempt in flight, not a history.

> **Oracle (a)** — same harness as C13 (`WATCHDOG_RUNTIME_DIR` in a **non-created** tmpdir, override
> after the `source`), with a `start_session` stub that captures the marker as it sees it:
>
> ```bash
> start_session() { cat "$WATCHDOG_RUNTIME_DIR/boot-attempt" >> "$TMP_TEST_DIR/seen"; return 1; }
> run start_initial_session
> [ "$status" -eq 1 ]
> run grep -c '^1 [0-9][0-9]*$' "$TMP_TEST_DIR/seen"
> [ "$output" -eq 1 ]
> run grep -c '^3 [0-9][0-9]*$' "$TMP_TEST_DIR/seen"
> [ "$output" -eq 1 ]
> [ "$(wc -l < "$TMP_TEST_DIR/seen")" -eq 3 ]
> ```
>
> This proves three things at once: the file exists during the attempt (so the `mkdir` of C13 ran),
> the attempt number advances, and the second field is an integer epoch.
>
> **Oracle (b)** — non-fatality when the write genuinely cannot succeed: set
> `WATCHDOG_RUNTIME_DIR` to a path whose parent is a **regular file** (so `mkdir -p` also fails),
> with an always-failing `start_session`; assert `[ "$status" -eq 1 ]` and that all three CANON-B1
> lines are still present (`run grep -c`, `-eq 3`). Do **not** assert empty stderr: measured on this
> host, `printf … > missing/file 2>/dev/null || true` still prints
> `bash: …: No such file or directory`, because redirections are applied left to right and the `>`
> fails before `2>/dev/null` is in place. The contract is "does not abort", not "is silent".
>
> **The harness for oracle (b) MUST re-establish errexit in a subshell.** Measured on this host
> (bats 1.13.0, `/speckit-analyze` 2026-09-19): **bats' `run` strips errexit** — `$-` is `ehuBET` in
> the test body but `huB` inside `run` — so `run start_initial_session` on a sourced
> `start_services.sh` executes the mutant to completion and returns `status=1` with all three
> CANON-B1 lines, byte-identical to the guarded version. Written that way, oracle (b) cannot fail,
> and the `|| true` would ship with no catcher. The oracle must be:
>
> ```bash
> run bash -c 'set -euo pipefail; START_SERVICES_NO_RUN=1 source "'"$REPO_ROOT"'/docker/scripts/start_services.sh"; WATCHDOG_RUNTIME_DIR='"$parent_is_a_file"'/sub; start_session() { return 1; }; start_initial_session'
> [ "$(printf '%s\n' "$output" | grep -c 'initial session attempt')" -eq 3 ]
> ```
>
> The **status is 1 in both variants**, so the CANON-B1 line count is the sole discriminator:
> guarded → 3, mutant → 1.
>
> **Mutation M-B2**: drop the `|| true` from the `printf` line and run oracle (b) in the subshell
> form above — the function aborts under errexit after the first attempt instead of returning 1.

### C15 — The marker is removed on success AND on exhaustion

`rm -f "$WATCHDOG_RUNTIME_DIR/boot-attempt" 2>/dev/null || true` MUST run on **both** exits of
`start_initial_session`: immediately before `return 0` on a successful attempt, and immediately
before the CANON-B2 log on exhaustion. A stale marker must not outlive the boot that created it
(FR-021) — it is exactly what would make C16's bypass mask a permanently broken agent.

The `|| true` is required here too (C13's reason), and the tmpfs is a second, independent guarantee:
`/tmp` empties on every container start, so even a marker leaked by a `kill -9` cannot survive a
restart. Belt and braces, both cheap, both stated in `data-model.md` §5b.

> **Oracle (a)** — success path: `start_session` stub that fails once then succeeds (the C4 counter
> stub); after `run start_initial_session`, assert `[ "$status" -eq 0 ]` and
> `[ ! -e "$WATCHDOG_RUNTIME_DIR/boot-attempt" ]`.
>
> **Oracle (b)** — exhaustion path: always-failing stub; assert `[ "$status" -eq 1 ]` and
> `[ ! -e "$WATCHDOG_RUNTIME_DIR/boot-attempt" ]`.
>
> **Oracle (c)** — static, so a later edit cannot delete one of the two call sites and keep the
> other: inside the extracted body of the function,
> `sed -n '/^start_initial_session() {/,/^}/p' docker/scripts/start_services.sh | grep -c 'rm -f'`
> is `2` (read through `run`, compared with `[ "$output" -eq 2 ]`).
>
> **Mutation M-B3**: delete the success-path `rm -f`. Oracle (a) and oracle (c) go red; (b) stays
> green, which is why both paths are asserted separately.

### C16 — `agentctl doctor` distinguishes a boot in progress from a dead container

**Operator decision, 2026-09-19** — this reverses the prohibition an earlier revision of this file
carried in R1. Rationale (`data-model.md` §5b): on a cold or degraded boot the compose healthcheck
can flip to `unhealthy` while an agent is legitimately retrying, and `scripts/agentctl:387` maps
`unhealthy` → `_doctor_fail`. Reporting a hard FAIL for a healthy-but-slow boot is a false negative
of the same family US4 exists to remove, so `doctor` learns the distinction rather than the
healthcheck being silenced.

Normative:

1. `doctor` reads the marker **through `docker exec`**, using the existing helper
   (`scripts/agentctl:332-335`), never through a bind-mount:

   ```sh
   boot_attempt=$(_in_container "$agent" cat /tmp/agent-watchdog/boot-attempt)
   case "$boot_attempt" in ''|*[!0-9\ ]*) boot_attempt='' ;; esac
   ```

   `/tmp` is a container tmpfs: it is reachable through neither `./:/workspace` nor
   `./.state:/home/agent`. This is called out because the convention comment at
   `scripts/agentctl:315-318` explicitly steers freshness checks toward the bind-mount, which here
   would silently never find the file.
2. A `docker exec` that fails (container restarting, daemon slow) yields an empty value and is
   treated as **"no marker"** — today's behaviour, per FR-021. The value is also validated to digits
   and spaces before use, so a truncated or garbage read degrades to "no marker" rather than
   producing a nonsense verdict.
3. With a marker present **and** fresh, check 4 emits **CANON-H1**
   (`Container health: starting (boot attempt N/3)`) as an informational line, and the
   `unhealthy` → `_doctor_fail` mapping (`:387`) is bypassed.
4. **The freshness guard is not optional.** A container that can never bring the channel up exhausts
   its attempts, exits, is revived by `restart: unless-stopped`, and starts over — so it is
   *permanently* inside an "initial boot" with a marker almost always present. Without the guard,
   `doctor` would answer `starting (boot attempt 2/3)` forever for a dead agent, which is **worse**
   than today. When the marker's age exceeds `MAX_BOOT_ATTEMPTS × (channel window + overhead)` the
   bypass lapses and the FAIL returns, naming the reason. `scripts/agentctl` consults no
   `RestartCount` today (verified: no occurrence in the file), so the epoch is the cheaper of the two
   viable signals.
5. **Every other health state is untouched**: `healthy`, `starting`, `none` and the `*` fallback
   keep their current lines (`:385-389`), and `unhealthy` **without** a fresh marker keeps
   `_doctor_fail` byte-identical.

> **Oracle (host bats, new file `tests/agentctl-doctor-boot-attempt.bats`)** — mould
> `tests/agentctl-doctor-claude-oauth.bats:11-35`: an `agent.yml` in `TMP_TEST_DIR`, a `docker` shim
> first on `PATH`, `cd "$TMP_TEST_DIR"`, then `run "$AGENTCTL" doctor`. The shim is parameterised by
> environment variables so one file covers four cases — `inspect` echoes `$SHIM_HEALTH`, and `exec`
> echoes `$SHIM_MARKER` (exiting 1 when it is unset, to model a failed `docker exec`):
>
> | # | `SHIM_HEALTH` | `SHIM_MARKER` | Required output |
> | --- | --- | --- | --- |
> | 1 | `unhealthy` | `2 <now>` | contains CANON-H1 `Container health: starting (boot attempt 2/3)`; **no** `Container health: unhealthy` |
> | 2 | `unhealthy` | unset (exec fails) | `Container health: unhealthy` exactly as today; exit code unchanged |
> | 3 | `unhealthy` | `2 <now − 3600>` | stale → `Container health: unhealthy` returns, naming the stale marker |
> | 4 | `healthy` | `1 <now>` | `Container health: healthy` — a marker never upgrades or downgrades any other state |
>
> Each assertion is `run grep -c …` over the captured output compared with `[ "$output" -eq N ]`, or
> `echo "$output" | grep -qE …` as the **last** statement of the test — never a bare intermediate
> `grep -q`.
>
> **Mutation M-B4**: remove the freshness comparison so any marker bypasses the FAIL. Case 3 goes
> red, cases 1/2/4 stay green — the guard has its own catcher, independent of the happy path.

## Interaction with the compose healthcheck

This is the clause of the design most likely to bite, so the arithmetic is written out rather than
asserted.

### What the healthcheck actually checks

`modules/docker-compose.yml.tpl:46-51`:

```yaml
    healthcheck:
      test: ["CMD-SHELL", "pgrep -x crond >/dev/null && pgrep -f 'tmux .*-s agent' >/dev/null"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 60s
```

It probes **two** things: `crond` is alive, and a process whose command line matches
`tmux .*-s agent` exists. It does **not** look at the channel — not `bun server.ts`, not the channel
marker (`/tmp/agent-watchdog/session.channels-mode`), not `claude`. So a boot that is retrying
because the *channel* never came up is, from the healthcheck's point of view, healthy for as long as
a tmux session exists.

### tmux presence during a retry cycle

Inside one `start_session` call (`:813-850`), with `T` = `channel_health_timeout()`:

| Phase | Duration | tmux session present? |
| --- | --- | --- |
| `pre_accept_bypass_permissions` … `pre_warm_mcps`, then `next_tmux_cmd` (marketplaces, `ensure_all_plugins_installed`, the Telegram patcher) | `Q` | **no** (previous session already killed) |
| `tmux kill-session` + `sleep 1` | ~1 s | no |
| `new-session` + `pipe-pane` + `sleep 2` | ~2 s | **yes** |
| `verify_channel_healthy` | up to `T` | **yes** |
| `kill-session` on failure | ~0 s | no → next attempt |

So per failed attempt the session is **absent for `Q + ~1 s`** and **present for `T + ~2 s`**.

`Q` is small on a warm boot (the pre-hooks are jq/file operations; `pre_warm_mcps` is a no-op once the
prefix is warm; the plugin walk is idempotent) — call it ~5 s. It is large on a cold or degraded boot,
where `pre_warm_mcps` and `claude plugin install` do real network work.

### Can the healthcheck declare `unhealthy` during the retries?

Docker Engine semantics (documented behaviour, not measured in this repo): probes start after
`interval`; a failure while still inside `start_period` does not count toward `retries`; once the
start period has elapsed, `retries` **consecutive** failures flip the state to `unhealthy`. With
`interval: 30s` and `retries: 3`, that needs **~60 s of continuously failing probes** (three probes,
30 s apart) after t ≈ 60 s.

**Warm case (`T=60`, `Q≈5`): no.** The cycle is ~69 s with a ~6 s absent window. Probe instants are
30 s apart, so their phase within the 69 s cycle walks 0 → 30 → 60 → 21 → 51 → 12 → … Only phases
< 6 s land in the gap, and two such phases are never adjacent in that walk. Three *consecutive*
failures are therefore arithmetically unreachable. The container stays `healthy` through all three
attempts, and the operator sees `attempt 1/3 … 2/3 … 3/3` in the log with a green `docker ps`.

**Cold / degraded case (`Q ≳ 60 s`): yes, reachable.** If the per-attempt preamble itself exceeds a
minute — a cold `uv tool install` sweep over 15 MCP servers, or a `claude plugin install` pass over a
slow network — the absent window grows to the same order as the present window and three consecutive
failing probes become possible. That case is real: it is the `donna` scenario this whole feature
exists for.

**And the first stretch is already exposed today.** Between container start and the *first* tmux
session there is `boot_side_effects` (`:147-189`) plus the first, coldest `Q`. If that exceeds
~150 s (probes at 30/60 suppressed by `start_period`, then three counted failures at 90/120/150), the
container is marked `unhealthy` before the retry logic has any say. US3 does not lengthen that
stretch by a single second — it only adds attempts *after* it.

### What an `unhealthy` verdict actually costs

Nothing in the container lifecycle. `restart: unless-stopped` (`:38`) reacts to the container
**exiting**, not to its health status (health-driven restarts are a Swarm-only behaviour), there is no
second service with `depends_on: condition: service_healthy`, and no script in this repo restarts on
health. The consumers are:

1. `docker ps` / `docker inspect` display.
2. `scripts/agentctl:381-390`, where `unhealthy` maps to `_doctor_fail "Container health: unhealthy"`
   (`:387`) — so `agentctl doctor` reports a hard failure and exits non-zero while a boot is still
   legitimately retrying.

Consumer 2 **was** the honest cost of US3. As of the operator decision of 2026-09-19 it is no longer
accepted: **C16** makes `doctor` read the boot marker and report CANON-H1 instead, with a freshness
guard so the bypass cannot mask a permanently broken agent. The healthcheck itself is still not
touched — the fix is in the consumer, not in the signal.

**Direction of the change, stated plainly.** Today the container exits on the first failure, so its
health state resets to `starting` on every restart and `unhealthy` is rarely observed — the operator
sees a flapping `starting` that hides a permanent failure. After US3 the container stays up through
three attempts, so a genuinely slow boot can surface as `unhealthy` for a few minutes. That is a more
truthful signal, not a regression, but it *is* a visible behaviour change and must be in the
CHANGELOG and in the live-gate expectations.

**No compose change is made.** Raising `start_period` to cover the retries was considered and
rejected: it would suppress the honest signal for every agent, including the ones whose boot really is
broken, and `start_period` is not the knob that governs whether the container survives.

## Edge case: a large `CHANNEL_HEALTH_TIMEOUT`

`channel_health_timeout()` (`:739-745`) accepts any positive integer up to 6 digits; feature 026
decision D fixed that there is **no cap** — the operator's value is used as-is, with
`warn_if_channel_timeout_risky` (`:753-760`) logging one boot WARN from `T ≥ 65` (breakeven
`WINDOW/(MAX_CRASHES-1) - 5 = 70`, minus 5).

Worst-case wall time before the container exits, with `MAX_BOOT_ATTEMPTS = 3`:

```text
total ≈ B + 3 × (Q + 3 + T)          B = boot_side_effects, Q = per-attempt preamble

T = 60  (default),  Q ≈ 5   →  3 × 68  =  204 s  ≈  3.4 min     (plan DD-4's "~3 minutes")
T = 120 (donna's current override) →  3 × 128 =  384 s  ≈  6.4 min
T = 420 (the case asked about), Q ≈ 5  →  3 × 428 = 1284 s  ≈ 21.4 min
T = 420, cold boot Q ≈ 60              →  3 × 483 = 1449 s  ≈ 24.2 min
```

So: **~21 minutes warm, ~24 minutes cold**, against ~7 minutes today.

**Verdict: acceptable, and no cap is introduced.** Four reasons, in order of weight:

1. **The terminal behaviour is identical.** Today `T=420` does not mean "fails in 7 minutes and
   recovers" — it means "fails in 7 minutes, exits, restarts, discards the writable layer, and fails
   again, forever" (research.md D4: the loop destroys its own progress). US3 changes the period of an
   already-unbounded loop, not its outcome, and it is the only version of the loop in which the warm
   caches survive between attempts. A longer period that converges beats a shorter one that cannot.
2. **The operator has already been warned, at every boot, for this exact value.** `T=420` fires
   `warn_if_channel_timeout_risky` unconditionally. Adding a silent cap here would be a *second*
   place that overrides the operator's number, and it would contradict a decision (026 D) that was
   taken deliberately.
3. **The cost is bounded and computable**: `MAX_BOOT_ATTEMPTS × (T + overhead)`, with
   `MAX_BOOT_ATTEMPTS` a constant that C2 forbids deriving from `T`. The operator can multiply.
4. **CANON-B1 is the mitigation for the only thing that actually hurts** — not knowing whether a
   21-minute boot is progressing or hung. Three timestamped `initial session attempt N/3` lines make
   that unambiguous from the journal alone (FR-012).

**Rejected alternative, recorded so the decision is not re-litigated silently**: deriving the attempt
count from a total boot budget (e.g. `attempts = max(1, min(3, 300 / T))`, giving 3 attempts at
`T ≤ 100` and 1 at `T = 420`). It caps the worst case at ~5 minutes, but it makes the retry count
invisible and value-dependent — an operator who raises `T` to buy patience would silently *lose* the
retries, which is the opposite of the intent — and it violates C2. If a total-budget cap is ever
wanted, it belongs in its own feature with its own canonical strings, not smuggled in here.

**Documentation requirement**: the formula `MAX_BOOT_ATTEMPTS × (CHANNEL_HEALTH_TIMEOUT + overhead)`
must appear next to the `docker.channel_health_timeout_s` field documentation, so the multiplier is
discoverable at the moment the operator sets the value.

## Non-obvious behaviour worth knowing

- **The retry only has teeth for a `--channels` launch.** `start_session` returns 0 without calling
  `verify_channel_healthy` whenever `next_tmux_cmd` picked Case A (bare `claude` for `/login`) or
  Case B (the in-container Telegram wizard) — the health gate is inside
  `if [[ "$cmd" == *"--channels "* ]]` (`:840`). On a first, unauthenticated boot exactly one
  CANON-B1 line is emitted and the loop ends. That is correct, and **C11 oracle (b) is that test** —
  written so nobody later "fixes" the single attempt into three. The same mechanic is why C11's
  positive test cannot get away with stubbing only `tmux`: see C11.
- **Each retry re-runs the full preamble**, including `pre_warm_mcps` and
  `ensure_all_plugins_installed` (via `next_tmux_cmd`, `:666-710`) and therefore the Telegram plugin
  patcher (`_hook_telegram_typing_patch`, `:404-415`). All three are idempotent by design, so this is
  safe — but it is not free, and it is why `Q` appears three times in the worst-case arithmetic.
- **Three `WARN: --channels launched but bun server.ts never appeared within Ns` lines** (`:842`) now
  appear on an exhausted boot instead of one. Each is immediately preceded by its CANON-B1 line, so
  they are attributable. No existing test pins the count of that line.

## Risks

| # | Risk | Severity | Mitigation / status |
| --- | --- | --- | --- |
| R1 | On a cold or degraded boot (`Q ≳ 60 s`) the container can reach `unhealthy` during the retries, and `agentctl doctor` turns that into `_doctor_fail` (`scripts/agentctl:387`) — a hard FAIL while the boot is still legitimately working. | Medium | **Fixed in this feature, by operator decision of 2026-09-19** (was: "accepted, not hidden"). An earlier revision of this row declared the `doctor` cross-check *out of scope for 036* and told the reader not to smuggle it into US4; **that prohibition is withdrawn.** `doctor` MUST distinguish a boot in progress from a dead container: `start_initial_session` writes `${WATCHDOG_RUNTIME_DIR}/boot-attempt` (C13-C15) and check 4 reads it through `docker exec`, emitting CANON-H1 instead of the FAIL while the marker is present *and* fresh (C16, FR-020/FR-021). Nothing acts on `unhealthy` in the container lifecycle, so the fix is purely about telling the operator the truth. The freshness guard is what keeps it from becoming a *new* false clean. Still named in CHANGELOG + live-gate expectations, now as a behaviour change in `doctor` rather than as accepted damage. |
| R2 | A slow boot masks a genuinely broken channel for ~3 min at the default, ~21 min at `T=420`. | Medium | Bounded and computable (C2); each attempt logged (C6); final exit unchanged so Docker still escalates (C5). Already listed in `plan.md` Risks. |
| R3 | A later edit moves the retry into `_run_watchdog`, tripling the crash-budget cadence and breaking the escalation arithmetic `warn_if_channel_timeout_risky` encodes. | High if it happens | C8 (function sha + line grep) and C9 (`CRASH_TIMES` count) are the guards. This is the single most expensive way to get US3 wrong. |
| R4 | US1's `--force` on `uv tool install` makes `pre_warm_mcps` non-trivial on *every* attempt (it reinstalls rather than no-ops), inflating `Q` and therefore the worst case by 3×. | ~~Low–Medium~~ **REFUTED** | **Measured 2026-09-19 in the live `donna` container** (`data-model.md` §2): a cold `uv tool install` of `workspace-mcp` is `rc=0 elapsed=12s`; the same call with `--force` over the already-installed package is `rc=0 elapsed=0s` — forcing reuses `UV_CACHE_DIR` and costs nothing measurable. The premise "reinstalls rather than no-ops" is false, so there is no 3× inflation to mitigate. `mcp-warm-contract.md` C1 answers the question this row asked: `--force` is **unconditional**, and the conditional variant was evaluated and rejected there. DOCKER_E2E still exercises a warm second boot (case E-D / C16 of that contract) for the offline-safety requirement of FR-004, not for `Q`. |
| R5 | The bridge-watchdog class of regression (`ebfe35f`) creeps back in as "just one small check" while this file is already open. | High if it happens | C10, with the two in-repo citations. No detection of any kind is added by this story. |
| R6 | `pgrep -f 'tmux .*-s agent'` matching the tmux **server** process relies on the server inheriting the client's argv (tmux renames only `comm` via `PR_SET_NAME`). If a future tmux or busybox changes that, the healthcheck becomes a constant failure — independent of this feature, but this analysis leans on it. | Low | Pre-existing; not introduced or worsened by US3. Flagged so the assumption is written down rather than assumed. Verifiable in the live gate with `docker inspect --format '{{.State.Health.Status}}'` on a known-good agent. |

## Traceability

| Requirement / scenario | Clause |
| --- | --- |
| FR-010 bounded retry at the initial boot | C1, C2 |
| FR-011 exhaustion still exits non-zero | C5 |
| FR-012 each attempt logged distinguishably | C6, C7 |
| FR-013 no new stuck-channel detection | C10 |
| FR-018 bash 3.2 + 5.x, shellcheck, host bats | C11 (+ `quickstart.md` gates) |
| FR-019 DOCKER_E2E run for real | C12 |
| FR-020 `doctor` reports "starting", naming the attempt, during a retrying boot | C13, C14, C16 |
| FR-021 `unhealthy` unchanged outside a boot; the marker does not outlive its boot | C15, C16 (points 2, 4, 5) |
| US3 scenario 1 (healthy on the 2nd attempt) | C4, C11 |
| US3 scenario 2 (exhaustion escalates) | C5 |
| US3 scenario 3 (attempt N of M in the log) | C6 |
| US3 unauthenticated first boot makes exactly one attempt | C11 oracle (b) |
| SC-008 mutation spot-check | every clause's oracle (M-B1 … M-B4 for C13-C16) |

## Baseline measurements (this tree, 2026-09-18)

Recorded so a later reader can tell drift from disagreement.

```text
_run_watchdog body sha256   745a1a70f53eee28e9f87acbc406580b2e7a4ce44cb1fada19651beef94b32c4  (65 lines)
grep -c CRASH_TIMES         3
grep -c MAX_CRASHES         10
tests/start-services-watchdog.bats   29 tests
```

The 29 tests, in file order — the ones that touch the boot/channel-window surface this story edits
are marked ●; everything else must stay green untouched:

| # | Line | Test |
| --- | --- | --- |
| 1 | 27 | `crash_budget_check accepts 4 crashes spread over 600s (sliding window)` ● |
| 2 | 40 | `crash_budget_check exits when 5 crashes fit within trailing 300s` ● |
| 3 | 47 | `crash_budget_check accepts 5 crashes spread over 1500s (none recent)` ● |
| 4 | 57 | `crash_budget_check is the strict-equality sliding boundary at exactly 300s` ● |
| 5 | 68 | `crash_budget_check tolerates empty input` ● |
| 6 | 75 | `channel_plugin_alive returns 0 when no marker file exists` |
| 7 | 81 | `channel_plugin_alive returns 1 when marker present but bun absent` |
| 8 | 96 | `channel_plugin_alive returns 0 when marker present and bun running` |
| 9 | 117 | `_trigger_identity_backup returns immediately when heartbeatctl is slow` |
| 10 | 141 | `_trigger_identity_backup is reentrancy-guarded by pgrep` |
| 11 | 165 | `_identity_backup_fork_configured is false for a fork-less agent.yml` |
| 12 | 176 | `_identity_backup_fork_configured is true when agent.yml carries a fork url` |
| 13 | 187 | `_check_identity_backup skips the trigger and stays silent for a fork-less agent` |
| 14 | 208 | `has_oauth_token is true with CLAUDE_CODE_OAUTH_TOKEN set, false when unset/empty` |
| 15 | 220 | `next_tmux_cmd: with OAuth token and channel NOT ready, does NOT emit bare-claude /login` ● |
| 16 | 237 | `next_tmux_cmd: WITHOUT OAuth token and channel NOT ready, keeps bare-claude (Case A regression guard)` ● |
| 17 | 269 | `ensure_official_marketplace registers the official marketplace when absent` |
| 18 | 276 | `ensure_official_marketplace is a no-op when already registered (idempotent)` |
| 19 | 282 | `ensure_official_marketplace is fail-silent when the add fails (clone error)` |
| 20 | 293 | `pre_seed_onboarding creates .claude.json with onboarding keys when absent` |
| 21 | 302 | `pre_seed_onboarding is idempotent and preserves existing theme + keys` |
| 22 | 314 | `pre_accept_bypass_permissions creates settings.json with headless defaults when absent` |
| 23 | 327 | `channel_health_timeout defaults to 60 when unset/empty/non-numeric/<=0` ● |
| 24 | 343 | `channel_health_timeout echoes a valid positive integer verbatim` ● |
| 25 | 373 | `verify_channel_healthy: channel at elapsed=22s passes with 60s default, fails when capped at 20` ● |
| 26 | 383 | `verify_channel_healthy: returns 1 without sleeping the full timeout when bun never appears` ● |
| 27 | 398 | `crash budget: 5 failures fit the window at the 60s default (fires) but not at 90s (backstop lost)` ● |
| 28 | 408 | `warn_if_channel_timeout_risky: silent for the 60s default, warns for an override past the threshold` ● |
| 29 | 421 | `US2: default (unset) tolerates the 22s contention peak; invalid override degrades to 60` ● |

Marked ● = 15 tests. None of them is *modified* by US3; they are the regression fence. The new tests
of C1–C7, C11 and C13–C15 append after `:429` (the file's current last line). C16's tests do **not**
live here — they go in the new `tests/agentctl-doctor-boot-attempt.bats`, because they need the
`docker` shim + `agent.yml` setup of `tests/agentctl-doctor-claude-oauth.bats:11-35`, not the
`START_SERVICES_NO_RUN=1` source of this file.

**One setup detail the C13–C15 tests depend on**: `WATCHDOG_RUNTIME_DIR="/tmp/agent-watchdog"`
(`:255`) is a plain, unconditional assignment executed at load, so an override must be applied
**after** `source "$REPO_ROOT/docker/scripts/start_services.sh"` — inside the test body, not in
`setup()`'s environment. This is the same trap `tests/start-services-warm.bats:34-36` documents for
`WORKDIR`, and a test that sets it before sourcing would silently write into the host's real
`/tmp/agent-watchdog`.

### The seam the new tests must use

`_stub_pgrep_after K` (`:357-371`) — reproduced here because the retry tests depend on details of it
that are easy to miss:

```bash
_stub_pgrep_after() {
  local k="$1"
  mkdir -p "$TMP_TEST_DIR/bin"
  : > "$TMP_TEST_DIR/pgrep.count"          # counter file, PERSISTS across calls
  cat > "$TMP_TEST_DIR/bin/pgrep" <<STUB
#!/bin/bash
c=\$(cat "$TMP_TEST_DIR/pgrep.count" 2>/dev/null || echo 0)
c=\$((c + 1))
echo "\$c" > "$TMP_TEST_DIR/pgrep.count"
[ "\$c" -ge $k ] && exit 0
exit 1
STUB
  printf '#!/bin/bash\nexit 0\n' > "$TMP_TEST_DIR/bin/sleep"   # no-op sleep
  chmod +x "$TMP_TEST_DIR/bin/pgrep" "$TMP_TEST_DIR/bin/sleep"
}
```

Four properties that matter for US3:

1. **It shadows `sleep` too**, so `verify_channel_healthy`'s `sleep 2` costs nothing and a 60 s window
   is traversed in milliseconds. This is what makes a three-attempt test finish in under a second.
2. **The counter is global across attempts**, not per call — `verify_channel_healthy` calls `pgrep`
   at elapsed `0, 2, …, T-2`, i.e. `T/2` times per attempt. With `T=60` that is 30 calls, so
   `K = 31` fails attempt 1 and succeeds on the first probe of attempt 2.
3. **It must be activated by prefixing `PATH`** on the command under test —
   `PATH="$TMP_TEST_DIR/bin:$PATH" run start_initial_session` — exactly as `:376` and `:424` do.
   Exporting `PATH` in `setup()` instead would shadow `sleep` for the whole file.
4. **Reset between cases** with `: > "$TMP_TEST_DIR/pgrep.count"` (`:378`, `:426`).

Note that `channel_plugin_alive` and `_trigger_identity_backup` also shadow `pgrep` (`:87`, `:127`)
with simpler always-0/always-1 stubs; the retry tests must not reuse those, since they cannot express
"fails for one whole window, then succeeds".
