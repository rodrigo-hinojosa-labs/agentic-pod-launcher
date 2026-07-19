# Research: Remote Control session lifecycle in local mode (022)

**Date**: 2026-07-18
**Branch**: `022-local-session-lifecycle`
**Baseline**: `main` = `7e50c44` (PR #79 merged), host suite 1052 ok / 0 not ok

All measurements below were taken on the live target host (mclaren: Debian 13
trixie, aarch64, Claude Code **2.1.185**) or read directly from the repo at
`7e50c44`. Every claim carries its source. Inference is labelled as such.

---

## R1 — The vendor already has a staleness concept, and its criterion is weak

**This is the finding that unblocks the whole feature.** The spec assumed we would
have to invent a "is this session dead?" signal. We do not. Claude Code already
decides whether to reuse the stored session, and we can read its exact logic.

Extracted from the 2.1.185 binary on mclaren
(`grep -a -o -E "function uko.{700}" ~/.local/share/claude/versions/2.1.185`):

```js
function uko(e){                                  // readBridgePointer(dir)
  let t=_Vn(e),n,r;
  try{ r=(await Mue.stat(t)).mtimeMs, n=await Mue.readFile(t,"utf8") }catch{ return null }
  let o=amm().safeParse(umm(n));
  if(!o.success) return v(`[bridge:pointer] invalid schema, clearing: ${t}`), await dko(e), null;
  let s=Math.max(0,Date.now()-r);
  if(s>yOl) return v(`[bridge:pointer] stale (>4h mtime), clearing: ${t}`), await dko(e), null;
  return {...o.data, ageMs:s}
}
```

with `yOl = 14400000` (**4 hours**) and `dko` = `clearBridgePointer`, which is a
plain `unlink`:

```js
function dko(e){ let t=_Vn(e); try{ await Mue.unlink(t), v(`[bridge:pointer] cleared ${t}`) }
                 catch(n){ if(!Dn(n)) v(`[bridge:pointer] clear failed: ${n}`,{level:"warn"}) } }
```

Three consequences, all load-bearing for the design:

1. **The staleness predicate is mtime-only.** A pointer younger than 4 h is reused
   unconditionally. This explains the measured incident exactly: the pointer was
   rewritten at 13:51:49 and the host rebooted at 13:57:40 — an age of ~6 minutes,
   far inside the 4 h window, so the new process reused a session the relay had
   already closed. **The bug is not that Claude Code lacks a check; it is that its
   check cannot see process death.**
2. **`readBridgePointer` itself ignores `pid`/`procStart` — but its caller does not**
   (see R1b, which corrects an earlier reading of this). The validated schema
   (`amm`) is: `{sessionId: string, environmentId: string,
   source: "standalone"|"repl", pid?: number, procStart?: string}`.
3. **The remediation already exists and is a plain `unlink`.** Anything we do can
   mirror the vendor's own repair rather than invent one.

### `procStart` is a process-instance discriminator — verified

`procStart` is field 22 of `/proc/<pid>/stat` (`starttime`, in clock ticks since
boot). Verified on the live agent:

| Source | Value |
|---|---|
| `systemctl show agent-mclaren-admin.service -p ExecStart` | `pid=59237` |
| `awk '{print $22}' /proc/59237/stat` | `141705` |
| `bridge-pointer.json` | `"pid": 59237, "procStart": "141705"` |

The pair `(pid, procStart)` therefore identifies a **process instance**, not just a
pid — it is immune to pid reuse. This is the missing signal.

---

## R1b — CORRECTION: the caller *does* check liveness, and the sense is inverted

An earlier reading of this research concluded that process liveness was ignored and
proposed "clear the pointer when its writer is dead". **That conclusion was wrong**
and is recorded here so it is not re-derived. `readBridgePointer` ignores
`pid`/`procStart`, but its **caller**, the remote-control startup path, uses both —
and uses them to decide the opposite of what was assumed.

Verified on mclaren's 2.1.185 (extracted directly) and corroborated in 2.1.214:

```js
if(!y && te){                                   // y = --session-id/-c ; te = createSessionInDir
  let nr = await readBridgePointer(T);
  if(nr){
    if(nr.pid!==undefined && nr.pid!==process.pid
       && isProcessRunning(nr.pid) && await isSameProcessAsync(nr.pid,nr.procStart))
      se=true,  log(`[bridge:init] Pointer writer pid ${nr.pid} still running; registering a fresh env and deferring pointer write`);
    else if(nr.source==="standalone")
      ee=nr.environmentId, oe=nr.sessionId,
      log(`[bridge:init] Found prior environment ${ee} in pointer (ageMs=${nr.ageMs}); requesting reuse on registration`)
  }
}
```

with `isProcessRunning(e) = process.kill(e,0)` and
`isSameProcessAsync(pid,start)` returning **true when `start` is undefined or
unreadable**.

**Writer alive → fresh environment. Writer dead → reuse the environment *and* the
sessionId.** A dead writer is exactly the trigger for reuse. Since a restart or
reboot always leaves a dead writer, the earlier proposal ("clear when the writer is
dead") would have fired on every single start — the "always renew" degeneration
that SC-009 exists to forbid. The spec's own warning that the stored pid "does not
discriminate" was right for a reason deeper than the one recorded there.

### What happens after reuse is requested

| Backend response | Outcome |
|---|---|
| Returns a **different** `environmentId` | Warns "Existing claude.ai/code sessions from the previous run will not reconnect", calls `clearBridgePointer` → clean start. Self-healing. |
| Returns the **same** `environmentId`, and `reconnectSession` succeeds | `[bridge:init] Adopted session … re-queued via bridge/reconnect` → genuine continuity. **This is the mechanism FR-014 wants to preserve.** |
| Same env, `reconnectSession` fails with a **definitive** API error | Inherited sessionId dropped → a **new** session is created. Reachable. |
| Same env, `reconnectSession` fails **transiently** | Stale sessionId retained; logged as "session will be picked up passively once its lease expires". **This is the outage state.** |

Two further behaviors that shape the design:

- **Hourly refresh**: while the server lives, a `setInterval(…, 3600000)` rewrites
  the pointer with a fresh `procStart`. So the mtime stays young and the vendor's
  4 h TTL effectively never expires for a long-lived agent — it only starts ticking
  once the process is gone.
- **Split-brain guard**: right after writing, the process re-reads the pointer and
  exits with "Another `claude remote-control` instance (pid N) is already running in
  this directory" if the pid differs. Anything that rewrites this file must not
  masquerade as another instance.

### The causal chain of the measured incident

1. 13:51:37 — the session **ends**. With `--spawn=session` (capacity fixed at 1)
   the process exits by design: "Single session · exits when complete".
2. `Restart=always` revives it 12 s later. The new process finds a pointer whose
   writer is dead → requests reuse of an **already-ended** session.
3. `reconnectSession` cannot adopt a session that is over; the failure is not a
   definitive API error, so the stale sessionId is retained and no new session is
   created. The agent is now announcing a dead session.
4. 13:57:40 — the host reboots. The pointer is *already poisoned*, so the reboot
   merely propagates it. One bad reuse contaminates every subsequent start until
   the pointer is removed or 4 h elapse.

**The root event is step 1–2, not the reboot**: a completed session immediately
re-announced. Ending a conversation from the phone is enough to poison the agent.

---

## R2 — Decision: this is a design fork for the operator, not a settled call

Given R1b, the reachability fix has two credible shapes, and they differ in what
they change about how the agent runs. Both are recorded; the choice is the
operator's because it changes runtime behavior of a live agent.

### Option A — adopt the CLI's default spawn mode (`same-dir`)

Attacks the root event directly: in `same-dir` the process is a **persistent
server** that does not exit when a session ends, so step 1–2 of the chain above
cannot happen. Sessions are created on demand; the pointer keeps being refreshed by
a living process, which is precisely the state in which the vendor's liveness branch
does the right thing.

- One-token change at `modules/systemd-remote-control.service.tpl:26`.
- Aligns the launcher with the upstream default instead of opting out of it.
- Costs: operator-visible behavior change (concurrent sessions, capacity 32, the
  runtime `w` toggle), and **not yet validated on this deployment**. It does not by
  itself repair an already-poisoned pointer.

### Option B — exit-cause-aware pointer hygiene

Keeps `--spawn=session` and adds the discriminator the pointer lacks: *why* the
previous process stopped. systemd is the authority on this and exposes it to
`ExecStopPost=` via `$SERVICE_RESULT` / `$EXIT_CODE` / `$EXIT_STATUS`.

- Process **exited on its own** → with `--spawn=session` that means the session
  ended → the pointer is dead weight → clear it.
- Process was **killed** (restart, reboot, stop) → the session may still be live
  server-side → leave the pointer → the vendor's reuse path restores continuity.

This maps onto FR-014 exactly, without guessing: continuity is preserved for
interrupted sessions and discarded only for sessions that provably ended.

- Costs: a new marker file and a second unit directive; `ExecStopPost` does not run
  on hard power loss, so the "cannot determine" branch must be defined (FR-014 says
  favour availability there).

### Live measurement on mclaren, 2026-07-18 21:15 UTC (settles the choice)

The operator authorised changing the running unit to `--spawn=same-dir` with
`--debug-file`. Measured across one `systemctl restart`:

| Observation | Result |
|---|---|
| Registration payload | `"max_sessions":32` → `same-dir` confirmed active |
| Pointer read | `[bridge:init] Found prior environment env_01VGAiNxctVi… in pointer (ageMs=3337066); requesting reuse on registration` |
| Backend response | `[bridge:init] Registered, server environmentId=env_01VGAiNxctVi…` — **same environment granted** |
| Pointer after restart | `sessionId` and `environmentId` **unchanged**; only `pid`/`procStart` updated |
| `Created initial session` | **absent** — the inherited sessionId suppressed pre-creation, as the extracted gate `if(te && !ot && !de)` predicts |
| **Reachability from the client** | **reachable, same link** (confirmed by the operator) |

Two conclusions, both of which contradict earlier assumptions in this document:

1. **`same-dir` reuses the pointer exactly like `session` does.** The reuse path is
   not gated on spawn mode — now measured, not inferred. Option A does not stop
   reuse.
2. **Reuse is *correct* behavior for an interrupted process.** A `systemctl restart`
   leaves the server-side session alive, the environment is re-granted, and the
   operator keeps the same link. This is FR-014 working as intended, and it is why
   "always clear at boot" would be a real regression rather than a cheap safety net.

### Second measurement, in the mode we ship (`--spawn=session`)

Reverting mclaren to `--spawn=session` required another `systemctl restart`, which
produced an independent confirmation of the same behavior **in the exact spawn mode
this feature keeps**:

| Observation | Result |
|---|---|
| Pointer after restart | `sessionId` and `environmentId` unchanged; `pid` 466890 → 1154300 |
| Client link | **unchanged** (`session_01Fbg3Cg…`), still reachable |
| 021 invariants | intact — `.env (ignore_errors=yes)` first, then `remote-control.env`; `ExecStartPre` = `agent-secret-check.sh` |
| Unit state | `active`, `NeedDaemonReload=no` |

This is the direct hardware validation of the **"killed → do not touch"** branch of
the predicate: systemd terminated the process, the server-side session survived, the
vendor's reuse restored the same link. Any design that cleared the pointer on every
start would have destroyed this. Measured twice now — once under `same-dir`, once
under `session`.

### The tension this exposes between A and B

B's discriminator is *why the previous process stopped*, and it only carries meaning
under `--spawn=session`, where the process exits **because** the session ended. That
is a causal link, not a correlation.

Under `same-dir` the process outlives its sessions, so "the process was killed" no
longer implies "the session is still alive": a long-lived server can be restarted
hours after its pointed-to session ended, and the exit cause says nothing. **Adopting
A destroys the only reliable local signal available to B**, and no replacement signal
exists — the pointer has no "ended" field, and server-side liveness is not observable
from the host (rejected in Alternatives).

### Revised recommendation

**`--spawn=session` + B, and do not adopt `same-dir` in this feature.**

- The exit-cause signal is causal and locally observable only in `session` mode.
- Continuity on restart/reboot is preserved (measured above) because those paths kill
  the process, so B leaves the pointer alone and the vendor's reuse succeeds.
- The poisoning case — a session that *ended*, so the process exited on its own — is
  precisely the case B clears. That is the measured incident, and nothing else in the
  system distinguishes it.
- A new client link after a conversation genuinely ends is inherent to single-session
  mode, not a defect this feature introduces.

`same-dir` remains an interesting operator-experience change (a persistent server with
on-demand sessions), but it is a *different* feature with a different supervision
model, and it would have to bring its own answer for stale-pointer detection. Bundling
it here would trade a signal we have for one we do not.

### Alternatives considered and rejected

- **Clear the pointer unconditionally at every start.** Guarantees reachability;
  explicitly rejected by the operator in Clarifications and fails SC-009.
- **Clear when the writer process is dead.** The earlier proposal — rejected by
  R1b: a dead writer is the normal post-restart state, so this is the previous
  option in disguise.
- **`--no-create-session-in-dir`.** Per the extracted gate `if(!y && te)`, this
  skips the reuse block entirely and would fix the bug by construction. Rejected
  for now: no session is pre-created, so the operator must create one from the
  client, and that flow is unverified.
- **Query the relay for session liveness.** No supported client-side surface; adds
  a network dependency to the boot path. Rejected against FR-003.
- **Use the "connected" marker in the journal.** Rejected on measured grounds: the
  status line is redrawn in place and reaches the journal as `[66B blob data]`, so
  the last readable text lies — the exact trap the spec fenced off.
- **Shorten the vendor's 4 h TTL by back-dating the file's mtime.** Relies on an
  undocumented constant and is time-based rather than causal.

---

## R3 — Spawn-mode reference data

`claude remote-control --help` on 2.1.185 (verbatim excerpt):

```
  --spawn <mode>       Spawn mode: same-dir, worktree, session
                       (default: same-dir)
  --capacity <N>       Max concurrent sessions in worktree or same-dir mode
                       (default: 32)
```

```
  Remote Control runs as a persistent server that accepts multiple concurrent
  sessions in the current directory. One session is pre-created on start so
  you have somewhere to type immediately. Use --spawn=worktree to isolate
  each on-demand session in its own git worktree, or --spawn=session for
  the classic single-session mode (exits when that session ends).
```

So the unit (`modules/systemd-remote-control.service.tpl:26`) opts *out* of the CLI
default. `--spawn=session` + `Restart=always` means: session ends → process exits →
systemd revives it → a new session and a new client link. `same-dir` would keep one
persistent server with on-demand sessions.

**Decision: keep `--spawn=session` in this feature; evaluate `same-dir` separately.**

Rationale:

1. **It is not a substitute for R2.** `readBridgePointer` is generic and is not
   gated on spawn mode, so a `same-dir` process starting after a reboot would read
   the same stale pointer. Switching modes alone is not demonstrated to fix the
   measured failure — and nothing in the extracted code suggests it would.
2. **R2 alone closes the measured incident**, and does so with a predicate we can
   test on the host with no systemd.
3. Switching spawn mode changes operator-visible behavior (concurrent sessions,
   capacity 32, the runtime `w` toggle) and is unvalidated on this deployment.
   Bundling an unvalidated behavior change into an outage fix widens the blast
   radius for no measured gain.

Recorded as an open question rather than a closed door: `same-dir` plausibly gives a
*stabler client link* across session completions, which is a genuine operator-experience
improvement. It deserves its own measurement and its own decision, not a ride-along.

---

## R4 — Locating the pointer: do not reimplement the slug blindly

The vendor's path function, extracted from the same binary:

```js
function FS(e){ let t=e.replace(/[^a-zA-Z0-9]/g,"-");
                if(t.length<=CVe) return t;
                return `${t.slice(0,CVe)}-${h7c(e)}` }     // CVe = 200
function W1(){ return sV.join(tr(),"projects") }           // <config>/projects
function _Vn(e){ return join(W1(), FS(e), "bridge-pointer.json") }
```

Two traps a naive implementation walks into:

- The substitution is **every non-alphanumeric character** → `-`, not just `/`. A
  workspace path containing a dot, space or underscore would produce a wrong slug.
- Above **200 characters** the slug is truncated and suffixed with a base-36 hash
  of the original path (`h7c` = `Math.abs(sTe(e)).toString(36)`, a non-standard
  internal hash we cannot reproduce faithfully in bash).

Measured on mclaren: workspace
`/home/rodrigo-hinojosa/Documents/Personal/Claude/Agents/mclaren-admin` →
slug `-home-rodrigo-hinojosa-Documents-Personal-Claude-Agents-mclaren-admin`
(69 chars, single project directory present).

**Decision**: compute the naive slug (`[^a-zA-Z0-9]` → `-`) and use it when the
directory exists. When it does not — including every path over 200 chars — fall
back to globbing `"$CLAUDE_CONFIG_DIR"/projects/*/bridge-pointer.json` and act only
if **exactly one** match exists; otherwise treat it as "cannot determine" and do
nothing. This never reproduces the vendor hash and never guesses between candidates.

Note: the repo has **no** path→slug transformation today (`grep` for `tr '/' '-'`,
`s#/#-#`, `s|/|-|` over `scripts/`, `setup.sh`, `docker/scripts/`, `modules/*.tpl`
returns nothing). Docker sidesteps it with a hardcoded constant
(`docker/scripts/start_services.sh:693` → `projects/-workspace`, valid because the
container cwd is always `/workspace`). So this computation is new code, and it must
be single-sourced for the hook and the doctor — 021 already paid the price of
duplicating detection logic between its boot hook and `_local_secrets_doctor`.

---

## R5 — Where the hook goes, and what must not move

`modules/systemd-remote-control.service.tpl` (33 lines) already carries a boot hook
from 021 at line 25. systemd runs multiple `ExecStartPre=` directives sequentially
in declaration order, before `ExecStart`, so a second one at line 26 is the natural
and only seam that runs **before** `claude remote-control` reads the pointer.

Invariants defended by existing tests that this feature must not disturb:

| # | Invariant | Test |
|---|---|---|
| 1 | `.env` `EnvironmentFile` **before** `remote-control.env` (numeric line-order assertion) | `tests/local-render.bats:106-118`, `tests/local-install-service.bats:130-140` |
| 2 | `EnvironmentFile=-` leading dash on `.env` (FR-004) | `tests/local-render.bats:101-104` |
| 3 | No other local unit may have `EnvironmentFile` (least privilege) | `tests/local-render.bats:130-152` (5 negative tests) |
| 4 | Never `Environment=` in the unit (secret in journal) | `tests/local-render.bats:125-128` |
| 5 | `ExecStartPre` keeps its `-` prefix | `tests/local-render.bats:120-123` |
| 6 | `ExecStart` asserted as one exact anchored line | `tests/local-render.bats:65` |
| 7 | `--dangerously-skip-permissions` absent | `tests/local-render.bats:85` |
| 8 | `Restart=always`, never `on-failure` | `tests/local-render.bats:68-72` |
| 9 | `ExecCondition` on `.credentials.json` | `tests/local-render.bats:74-78` |
| 10 | `User=` operator (never root), `WorkingDirectory=` workspace | `tests/local-render.bats:58-61, 88-91` |
| 11 | `SETUP_SYSTEMD_DIR` / `LOGIN_SYSTEMD_DIR` seams govern every install path | `tests/local-install-service.bats:106` |
| 12 | Docker path byte-unchanged | `regenerate` branch at `setup.sh:2195/2223` |

Invariant 6 is the one US3 deliberately breaks (the `--name` value changes); it is
updated, not worked around. Invariant 10's `WorkingDirectory` is load-bearing for
R4: the slug derives from it.

### The hook's contract, copied from 021

`modules/local-secret-check.sh.tpl` establishes the pattern to imitate exactly:
`#!/usr/bin/env bash`, **no** `set -e`/`set -u`, unconditional `exit 0` at the end,
WARN to stderr as `agent-<name> <check>: WARN: …`, paths interpolated at render time
(not passed as arguments), and every optional dependency guarded with `command -v`.
The `-` prefix on `ExecStartPre` plus the script's own `exit 0` form a deliberate
double belt.

`jq` availability: hard-gated in the login helper
(`modules/local-login.sh.tpl:37` exits 1 without it) and documented as a local-mode
requirement (`docs/agentic-quickstart.es.md:24`), so it is present in practice — but
runtime consumers never assume it (`modules/local-healthcheck.sh.tpl:101` degrades
to WARN). The hook must guard it and degrade the same way.

---

## R6 — The installed unit is not the rendered unit (inherited risk)

`--regenerate` re-renders the template but reinstalls the unit **only if**
`deployment.install_service` is true *and* `sudo -n true` succeeds
(`setup.sh:2264-2266`, `:2384`); otherwise it leaves the file staged and returns 0.
And **nothing in `setup.sh` ever restarts the session unit** — there is no
`systemctl restart` anywhere in it.

Confirmed live: mclaren's template was edited earlier today, yet the installed unit
still runs `--name mclaren-mclaren-admin` (`systemctl show … -p ExecStart`). The
template change never reached the running service.

021 already hit this and answered it with doctor check D3, which inspects the
**installed** unit via `systemctl show … -p EnvironmentFiles --value` rather than
reading the file (the unit file can be root-only, and `systemctl cat` then fails
"Permission denied" and silently skips the check — a mclaren gate finding, fixed in
PR #79). 022 must do the same for its new `ExecStartPre`, or the doctor will report
green on an agent that has never executed the hook.

---

## R7 — Making the session name configurable (US3)

Today: `--name {{HOST_NAME}}-{{AGENT_NAME}}`
(`modules/systemd-remote-control.service.tpl:26`) with `HOST_NAME="$(hostname)"`
computed at render time (`setup.sh:2335`) — **not** read from `agent.yml`. Two
side-effects worth recording: the session identity silently depends on the live
hostname rather than on `deployment.host` (`setup.sh:1150`), so moving a workspace
between machines changes it; and there is a second, independent composition of the
same identity at `modules/local-killswitch.sh.tpl:37`
(`$(hostname)-${AGENT_NAME}`) which would print a false identity if the name became
configurable and that file were left behind.

`--name` is used nowhere else (verified by `grep -rn` over `modules/`, `scripts/`,
`docker/`, `setup.sh`, `tests/`): it is purely the label shown in claude.ai/code.
It does not touch the unit name, the healthcheck, or the doctor. That is what makes
US3 low-risk.

**Decision**: add `deployment.session_name` to `agent.yml`, flattened by the render
engine to `DEPLOYMENT_SESSION_NAME` (`scripts/lib/render.sh:30-31`), with the
default resolved in `setup.sh` and **persisted back into `agent.yml`** — the
Principle I pattern already used by `_persist_claude_cli` (`setup.sh:122-132`) and
by the `deployment.mode` backfill (`setup.sh:1953-1962`), which runs before
`render_load_context` so the value is available in the same `--regenerate`.

**Default rule** (satisfies FR-009 and FR-015 — one rule, no compatibility branch):
if the agent name already starts with the host segment, use the agent name alone;
otherwise use `<host>-<agent>`. On mclaren that yields `mclaren-admin` instead of
`mclaren-mclaren-admin`, matching the change the operator already applied by hand.

### Files a new `agent.yml` field touches (measured, not estimated)

Core (5): `setup.sh:1149-1154` (heredoc), `setup.sh:1953-1962` (backfill),
`scripts/lib/schema.sh:78-85` (`_SCHEMA_OPTIONAL_NONEMPTY`),
`modules/systemd-remote-control.service.tpl:26`,
`tests/fixtures/sample-agent-with-vault.yml`.

Template-specific tests (2): `tests/local-render.bats:13-53, 65, 83`,
`tests/local-install-service.bats:19-51` (its `diff` at `:113-125` is byte-for-byte).

Consistency (3): `modules/local-killswitch.sh.tpl:37`,
`modules/next-steps.{es,en}.tpl:426/418`.

**A wizard prompt is deliberately NOT added.** The default is computed and
persisted, so nothing needs asking; this avoids the three-file prompt cascade
(`tests/helper.bash:137-138`, `tests/e2e-smoke.bats:29-49` and `:50-62`, plus the
52-prompt tables in both quickstarts, whose ES/EN token parity is itself tested at
`tests/quickstart-doc.bats:48-65`). The field stays editable in `agent.yml`, which
is what FR-008 actually requires.

---

## R8 — Open questions carried into the plan

1. **`same-dir` behavior** (R3): does a persistent-server process keep a stable
   client link across session completions, and does it also read the stale pointer?
   Answering it needs a live experiment in a throwaway directory. Not required for
   this feature; recorded so the question is not lost.
2. **Deployment reach** (R6): mclaren's installed unit is stale relative to its
   template. The hardware gate for this feature must install and restart the unit
   explicitly, not assume `--regenerate` did it.

---

## R9 — The diagnostic: where US2 plugs in, and a false alarm already shipping

There are **two** doctors. `cmd_doctor` (`scripts/agentctl:337-626`) is docker;
`cmd_local_doctor` (`:1258-1315`) is local, dispatched at `:1365`. US2 touches only
the latter — docker stays byte-unchanged (FR-011).

Output helpers and the exit contract (`scripts/agentctl:105-119`, `:1304-1314`):
`_doctor_pass` (✓), `_doctor_warn` (⚠, +1 warn), `_doctor_fail` (✗, +1 fail),
`_doctor_skip` (⊝, **no counter**). Exit 0 = clean, 1 = warnings only, 2 = any fail.
`$2` on warn/fail prints as a `→` hint line and is where the recovery command goes.

### A false alarm is already in the local doctor, and 022 must remove it

`cmd_local_doctor:1280-1285` decides "connection signal" by grepping the journal for
`session url|connected|polling`. The healthcheck **already abandoned exactly this
predicate** as a measured false positive
(`modules/local-healthcheck.sh.tpl:50-64`): *"A healthy `--spawn=session` is SILENT
in the journal, so grepping it for 'session url|connected|polling' false-WARNed on
every tick even when connected (validated on mclaren)."* The healthcheck replaced it
with an ESTABLISHED `:443` socket probe on the `MainPID`; the doctor never followed.

Two consequences:

1. Leaving that block while adding a good check means the doctor keeps emitting the
   very false alarm FR-006 forbids. **It must be replaced or removed in this change,
   not run in parallel.**
2. The socket probe the healthcheck moved to is *also* insufficient for this
   feature's failure: during the incident the `:443` socket was ESTABLISHED with
   real bidirectional traffic while the agent was unusable. Neither existing
   predicate detects a stale session.

### "Cannot determine" — two incompatible conventions in the repo

The healthcheck treats it as **WARN** (`local-healthcheck.sh.tpl:63`,
`_demote WARN "cannot verify connection (ss unavailable or MainPID unknown)"`,
tested at `tests/local-healthcheck.bats:110-115`). The doctor treats it as **skip**
(⊝, exit 0, uncounted). A third, worse pattern exists: D3 prints *nothing* when
`systemctl show` returns empty (`:1178`), making the indeterminacy invisible.

**Decision**: use `_doctor_warn` with explicit "cannot determine" wording, and
reserve `_doctor_skip` for "this check does not apply to this configuration".
Choosing `_doctor_skip` would make an unreadable session state exit 0 — the exact
all-green-while-dead failure the spec was written against (`spec.md:76`).

### Test seam

`tests/agentctl-local.bats` (602 lines, 38 tests) builds a fake workspace in
`setup()` (`:8-62`): `agent.yml` with `mode: local`, and stub binaries in a
`bin/` prepended to `PATH` (`systemctl`, `journalctl`, `claude`, plus a `docker`
stub that writes a marker to prove it is never called). Tests that need different
semantics **overwrite the stub inside the test body** (`:507-518`) rather than
parameterising `setup()`. `tests/local-healthcheck.bats:60-72` is the closer model
for this feature: it renders the template and stubs `ss` with `STUB_*` env vars.

Bats hazard to respect (documented in the file itself): a negated assertion
mid-body does **not** fail the test. Use `if … grep -q …; then false; fi` last
(`:407`) or `run grep …; [ "$status" -ne 0 ]` (`:392-393`). The older tests at
`:120, 148, 206, 274` still use `! [[ … ]]` mid-body and are **dead assertions** —
do not copy that style.

### Baseline correction

Measured `bats tests/` on this host: **1052 ok, 0 not ok, 20 skips**, cross-checked
against `grep -h "^@test" tests/*.bats | wc -l` = 1052. `spec.md` SC-007 quoted 1050
(pre-PR #79) and has been corrected.

### Documentation debt to close in the same PR

`docs/heartbeatctl.md:501-511` tabulates the doctor's checks and has **no rows for
D1-D4** added by 021. Adding this feature's check without fixing that leaves the
reference two features behind.
