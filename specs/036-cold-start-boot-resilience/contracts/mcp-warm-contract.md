# Contract — MCP pre-warm (US1)

Feature 036, User Story 1. This contract fixes the behaviour of the boot pre-warm so that a
resolvable package ends up genuinely warm, a failure says which kind of failure it was, and the
dangling executable links an image rebuild leaves behind are cleaned up instead of blocking every
future install.

It covers four things:

1. `--force` on the uv installer call.
2. Honest classification of every warm outcome (`warm` / `failed` / `timed out` / `unavailable`).
3. The new `mcp_warm_prune_stale_links`.
4. `UV_TOOL_BIN_DIR` in the image.

Sources of truth: [`../spec.md`](../spec.md) (FR-001…FR-004, FR-018, FR-019),
[`../plan.md`](../plan.md) (DD-1, DD-2), [`../research.md`](../research.md) (D1, D2, D6),
[`../data-model.md`](../data-model.md) (§2, §3, §4). The canonical strings below are copied
**verbatim** from `data-model.md`; nothing in this contract rewords them.

## 1. Purpose

The measured defect (`research.md` D1): uv keeps its tool prefix in the image (`UV_TOOL_DIR=/opt/uv/tools`,
`docker/Dockerfile:118`) but its executable links default to `~/.local/bin`, which lives on the
`.state/` bind-mount. An image rebuild wipes the prefix and leaves the links, so
`uv tool install --python python3 <pkg>` — the exact command `_mcp_warm_one` runs
(`scripts/lib/mcp_warm.sh:98`) — exits non-zero **in 0 seconds** with
`error: Executable already exists: … (use --force to overwrite)`. The single existing warn wording
(`mcp_warm.sh:126`) reported that instant hard failure with the same sentence it uses for a slow
download, so feature 030 has been silently ineffective for any previously-installed package since it
shipped.

This contract makes that class of failure impossible (C1, C15), and makes the remaining failures
diagnosable from the boot log alone (C3–C7).

## 2. Surface

### 2.1 Existing functions, after this feature

```bash
# scripts/lib/mcp_warm.sh  (mirrored into the image; see C19)

_mcp_warm_log     MESSAGE                          # unchanged (:24) — prefixes "mcp_warm: ", stderr
mcp_warm_targets  <mcp_json_path>                  # unchanged (:60-75) — pure derivation
_mcp_warm_timeout SECONDS CMD...                   # unchanged (:79-88)
_mcp_warm_pick                                     # unchanged (:29-53)

_mcp_warm_one     RUNTIME PACKAGE PY_FLAG TIMEOUT  # CHANGED — see C1, C3
mcp_warm_run      <mcp_json_path>                  # CHANGED — see C3..C9
```

### 2.2 New function

```bash
# mcp_warm_prune_stale_links DIR
#   DIR is MANDATORY — there is NO default (see C10 for why). An empty or
#   missing DIR returns 0 immediately, scanning nothing.
#   Removes ONLY entries that are symlinks whose raw target starts with /opt/uv/tools/
#   AND that do not resolve. Always returns 0. Logs CANON-W4 iff at least one was removed.
mcp_warm_prune_stale_links() { :; }
```

### 2.3 Classification channel

`_mcp_warm_one` keeps its `0` / non-zero return (so C8's fail-soft shape is untouched) and, in
addition, sets two globals in the **caller's** shell — it is invoked as a plain command from
`mcp_warm_run`, never in a subshell, so plain assignment is visible:

| Variable | Values |
| --- | --- |
| `_MCP_WARM_CLASS` | `warm` \| `failed` \| `timeout` \| `unavailable` |
| `_MCP_WARM_RC` | the installer's numeric exit status (`0` when the class is `unavailable`) |

Rationale for a side channel rather than a reserved return code: a reserved code (e.g. `127` for
"runtime missing") collides with a real installer exit of the same value, and the whole point of US1
is to stop conflating different outcomes.

### 2.4 Caller

```bash
# docker/scripts/start_services.sh :808-811
pre_warm_mcps() {
  command -v mcp_warm_run >/dev/null 2>&1 || return 0
  mcp_warm_prune_stale_links "$HOME/.local/bin" || true   # NEW — see C14 (must precede the warm)
  mcp_warm_run "$WORKDIR/.mcp.json" || true
}
```

The directory is passed **explicitly**, never defaulted inside the function (`data-model.md` §3,
C10). `pre_warm_mcps` is the only defined caller and it always knows the path.

## 3. Canonical strings (verbatim from `data-model.md` §2 and §3)

```text
mcp_warm: warn: uvx workspace-mcp failed (exit 2) — will resolve on first use
mcp_warm: warn: uvx workspace-mcp timed out after 300s — will resolve on first use
mcp_warm: warn: uvx unavailable (uv not on PATH) — skipping workspace-mcp
mcp_warm: pruned N stale uv link(s) from /home/agent/.local/bin (image rebuild leaves them dangling)
```

Those four lines are CANON-W1, CANON-W2, CANON-W3 and CANON-W4 respectively, quoted exactly as
`data-model.md` fixes them. They are **instances**; the substitutions each one implies are:

| Token in the canonical instance | Substituted with |
| --- | --- |
| `uvx` | the runtime label of the target (`uvx` or `npx`) |
| `workspace-mcp` | the package name of the target |
| `2` in `(exit 2)` | `_MCP_WARM_RC` |
| `300` in `after 300s` | the effective `MCP_WARM_TIMEOUT` (`mcp_warm.sh:117`, default `300`) |
| `uv` in `(uv not on PATH)` | the runtime's binary: `uv` for `uvx`, `npm` for `npx` (`mcp_warm.sh:96,101`) |
| `N` | the number of links removed, as a decimal integer |
| `/home/agent/.local/bin` | the directory actually scanned |

`(s)` in CANON-W4 is literal and never pluralised, and the `mcp_warm: ` prefix of all four comes from
`_mcp_warm_log` (`mcp_warm.sh:24`) — the implementation passes only the text after that prefix.

Unchanged and not re-worded by this feature: the summary line
`mcp_warm: warm cache: N/M warm, K failed` (`mcp_warm.sh:130`).

## 4. Clauses

Every clause states the normative rule and the oracle that proves it. "Host bats" means
`bats tests/` with no daemon; "DOCKER_E2E" means `DOCKER_E2E=1 bats tests/docker-e2e-warm-cache.bats`,
which this feature requires to be run for real (FR-019).

### C1 — The uv installer is invoked with `--force`

`_mcp_warm_one`'s `uvx` branch (`mcp_warm.sh:98`) MUST run, in this exact token order:

```bash
uv tool install --force $py_flag "$pkg"
```

`$py_flag` stays `--python python3` when `python3` is on PATH and empty otherwise
(`mcp_warm.sh:116`), and keeps its `shellcheck disable=SC2086` word-splitting.

**Oracle** (host bats, `tests/mcp-warm.bats`): with the `_install_warm_stubs 0` seam
(`tests/mcp-warm.bats:19-34`), run `mcp_warm_run` over a one-server `.mcp.json` and assert
`warm.log` contains `uv tool install --force` on the same line as the package name. The stub records
`uv $*`, so the argv is directly observable.

**Mutation** (M1): dropping `--force` turns that assertion red, and only that one — the pre-existing
`grep -q 'uv tool install'` (`tests/mcp-warm.bats:161`) still matches, which is why the new
assertion must pin the flag explicitly.

#### Why `--force` is UNCONDITIONAL, and why the conditional variant was rejected (MEASURED)

`--force` is passed on **every** warm of every uvx target. It is not gated on a prior collision, not
gated on a first-attempt failure, and not gated on the boot attempt number.

The conditional variant *was* designed and *was* evaluated: plain `uv tool install` first, then a
forced retry only when the first call failed with uv's "Executable already exists" text. Its sole
motivation was the cross-story cost that [`boot-retry-contract.md`](boot-retry-contract.md) raised as
**R4** — if forcing turns each warm into a full reinstall, US3's three boot attempts pay that cost
three times.

**R4 is refuted by measurement** (`data-model.md` §2, 2026-09-19). Inside the live `donna` container,
against a throwaway prefix/cache on real disk (not `/tmp`, a 100 MB tmpfs there):

```console
$ uv tool install --python python3 workspace-mcp      # cold cache, empty prefix
rc=0  elapsed=12s
$ uv tool install --force --python python3 workspace-mcp   # same cache, already installed
rc=0  elapsed=0s
```

Forcing over an already-resolved package reuses `UV_CACHE_DIR` and costs nothing measurable, so the
`Q` inflation R4 feared does not exist and no cap, gate or attempt-aware behaviour is warranted.

Unconditional forcing therefore wins on every axis, and each of these is a reason the conditional
variant is **rejected**, not merely unnecessary:

| Axis | Unconditional `--force` | Conditional (rejected) |
| --- | --- | --- |
| Cost on an already-warm package | 0 s, measured | same, plus a wasted first call |
| stderr capture | none needed — `mcp_warm.sh:98` keeps discarding stderr | required, to read uv's message |
| Coupling to uv's wording | none | matches an **unversioned** English error string that uv may reword at any release |
| Outcome classes (C3) | four, clean | a collision would have to be distinguished from a real failure before the retry, re-introducing the conflation US1 exists to remove |
| This contract | C1, its oracle and M1 stay exactly as written | all three would have to be rewritten |

Two consequences recorded so they are not rediscovered (`data-model.md` §2):

- The 300 s ceiling is **not** the binding constraint for this package — a cold install is 12 s. The
  incident was entirely the collision (`rc=2`), never slowness.
- `tests/docker-e2e-warm-cache.bats:88-104` warms `mcp-server-fetch`, one of the three baked
  catalogue tools. With unconditional `--force` that case reinstalls from the local cache rather than
  being a pure no-op, so it must stay offline-safe — which FR-004 already requires and C16 verifies.

### C2 — The npx path is unchanged

`_mcp_warm_one`'s `npx` branch MUST keep running
`npm exec --prefer-offline -y --package="$pkg" -- true` (`mcp_warm.sh:102`). The collision defect is
uv-specific (npm's cache has no per-executable link namespace), so no `--force`-equivalent is added.

**Oracle**: the existing assertion `grep -q 'npm exec'` (`tests/mcp-warm.bats:162`) stays green
unmodified; a new byte-level assertion pins the full argv so a future edit cannot drift it silently.

### C3 — Every target resolves to exactly one outcome class

`_mcp_warm_one` MUST set `_MCP_WARM_CLASS` per §2.3 before returning, using this decision order:

1. The runtime's binary is not on PATH (`command -v uv` / `command -v npm` fails,
   `mcp_warm.sh:96,101`), or the runtime is not `uvx`/`npx` (`mcp_warm.sh:104`) → `unavailable`.
2. Installer rc `0` → `warm`.
3. Installer rc `124` **or** `143` → `timeout`.
4. Any other non-zero rc → `failed`, with `_MCP_WARM_RC` carrying it.

The `{124,143}` set is measured, not assumed: GNU `timeout` reports `124`, and busybox `timeout`
(the container's runtime) reports **`143`** — verified on this host on 2026-09-18 with
`docker run --rm alpine:3.24 sh -c 'timeout 1 sleep 5; echo rc=$?'` → `rc=143`, and
`alpine:3.20` → `rc=143`. Both pass a non-timing-out child's status through unchanged (measured:
`timeout 1 sh -c "exit 7"` → `7`).

Because the rule is purely rc-based, it behaves identically whether `_mcp_warm_timeout` took the
`timeout` branch (Linux CI) or the direct-exec fallback (macOS, which has no `timeout` binary —
verified: `command -v timeout` and `command -v gtimeout` both empty on this host). That is what
keeps SC-007's byte-identical bash 3.2 / 5.x requirement satisfiable.

**Oracle** (host bats): three cases driven by the stub seam — `_install_warm_stubs 0` → class
`warm`, `_install_warm_stubs 2` → `failed`, `_install_warm_stubs 143` → `timeout`, and a fourth with
`uv` removed from `PATH` → `unavailable`. Each asserts the emitted line, not the variable, so the
oracle survives a refactor of the channel.

### C4 — A non-zero installer exit emits CANON-W1

Class `failed` MUST emit exactly one line per target, of the CANON-W1 shape, naming the runtime, the
package, and the numeric exit status.

**Oracle** (host bats): `_install_warm_stubs 2`, one `uvx` server, assert stderr matches
`warn: uvx <pkg> failed (exit 2) — will resolve on first use` and that the line count for that
package is exactly 1 (`grep -c`, compared with `[ "$n" -eq 1 ]` — never `grep -c … || echo 0`,
see `data-model.md` §6).

**Mutation**: reverting to the old catch-all wording (`failed (will resolve on first use)`) turns
this red while leaving the 030 idempotency and fail-soft tests green — which is precisely the gap
that let the defect survive from 030 to the outage.

### C5 — Hitting the ceiling emits CANON-W2

Class `timeout` MUST emit the CANON-W2 shape, naming the effective ceiling in seconds. It MUST NOT
reuse the `failed (exit N)` wording — distinguishing these two is FR-002's entire content.

**Oracle** (host bats): `_install_warm_stubs 143` plus `MCP_WARM_TIMEOUT=7`, assert the line reads
`timed out after 7s` (proving the seconds come from the variable, not a literal) and that no
`failed (exit` substring is present in the output.

### C6 — A missing runtime emits CANON-W3

Class `unavailable` MUST emit the CANON-W3 shape, naming the missing **binary** (`uv` / `npm`), not
the runtime label, and naming the package it skipped.

**Oracle** (host bats): run `mcp_warm_run` with a `PATH` that contains neither `uv` nor the stub dir
(`PATH=/usr/bin:/bin`), one `uvx` server; assert `uvx unavailable (uv not on PATH) — skipping <pkg>`
and rc 0. A second case with an `npx` server asserts the `npm` variant.

### C7 — The summary line and its arithmetic are preserved

`mcp_warm_run` MUST keep emitting `warm cache: ${warmed}/${tried} warm, ${failed} failed`
(`mcp_warm.sh:129-131`) only when `tried > 0`, and MUST preserve the invariant
`warmed + failed == tried`. The `unavailable` class counts toward `failed` (it is not warm), exactly
as today, where `_mcp_warm_one` returns 1 for a missing runtime.

**Oracle** (host bats): a mixed `.mcp.json` with two `uvx` servers under `_install_warm_stubs 2`
asserts `warm cache: 0/2 warm, 2 failed`; a zero-target `.mcp.json` asserts the summary line is
absent entirely.

### C8 — `mcp_warm_run` stays fail-soft

`mcp_warm_run` MUST return 0 unconditionally, for every combination of classes, including all
targets failing and the runtime being absent (Principle IV).

**Oracle**: the existing 030 test `"030: mcp_warm_run is fail-soft — a failing warmer does not abort
(FR-007/008/SC-004)"` (`tests/mcp-warm.bats:165-174`) stays green **unmodified**. CANON-W1 retains
the substring `will resolve on first use`, so its `grep -qi` assertion keeps matching — this is
deliberate and load-bearing, not an accident of wording.

### C9 — `mcp_warm_run` stays idempotent

A second run over the same input MUST return 0 and MUST NOT change the outcome class of any target.

**Oracle**: the existing 030 test `"030: mcp_warm_run is idempotent — safe to re-run (FR-005)"`
(`tests/mcp-warm.bats:176-185`) stays green unmodified — the contract the spec pins at
`tests/mcp-warm.bats:176`.

### C10 — `mcp_warm_prune_stale_links` exists, with a MANDATORY argument and the narrow predicate

Signature: `mcp_warm_prune_stale_links DIR`. **`DIR` is mandatory and has no default**
(`data-model.md` §3). When it is empty or missing the function MUST `return 0` immediately, scanning
nothing and logging nothing. For each entry of `DIR`, it removes the entry **iff all three** hold:

```sh
[ -L "$entry" ]                        # it is a symlink
[ ! -e "$entry" ]                      # it does not resolve (dangling, or a loop)
case "$(readlink "$entry")" in /opt/uv/tools/*) true ;; *) false ;; esac
```

`readlink` (no `-f`) is used deliberately: it is the only form available in both busybox and
BSD/macOS, and the predicate is about the **raw** target, not a canonicalised one. A relative target
therefore never matches the prefix and is never removed.

#### Why there is no default argument (adversarial review, MEDIUM)

`scripts/lib/mcp_warm.sh` is **not** docker-only. `modules/local-bootstrap.sh.tpl:47` sources it on
the operator's own machine:

```sh
# shellcheck source=/dev/null
[ -f "${WORKSPACE}/scripts/lib/mcp_warm.sh" ] && . "${WORKSPACE}/scripts/lib/mcp_warm.sh"
```

There, `~/.local/bin` is the operator's **real** bin directory — it holds the `uv`, `uvx`, `bun`,
`node`/`npx` and `github-mcp-server` links the local bootstrap installs, and
`modules/remote-control.env.tpl:10-13` puts it first on the session unit's `PATH`. A function whose
body contains `rm` and whose default target is that directory is one careless call — or one
`source` + tab-completion — away from damage. The single defined caller (`pre_warm_mcps`) always
knows the path, so the convenience buys nothing and the blast radius is real.

**Oracle** (host bats, `tests/mcp-warm.bats`): build a scratch `DIR` under `TMP_TEST_DIR` holding a
dangling `/opt/uv/tools/<pkg>/bin/<exe>` link, pass it **explicitly**, then assert the link is gone
and the function returned 0. The `load_lib mcp_warm` seam (`tests/helper.bash:26`) already exposes
the function.

**Oracle (b)** — the mandatory-argument rule itself: `run mcp_warm_prune_stale_links` with no
argument, and `run mcp_warm_prune_stale_links ""`, each asserting `[ "$status" -eq 0 ]` and
`[ -z "$output" ]`; plus a static check that the lib never names the default —
`run bash -c "grep -n 'HOME}/.local/bin' '$REPO_ROOT/scripts/lib/mcp_warm.sh'"` with
`[ "$status" -ne 0 ]`.

#### Test-setup clause: `tests/mcp-warm.bats` must export a scratch `HOME`

`tests/mcp-warm.bats:10-14` does **not** override `HOME` today — unlike
`tests/start-services-warm.bats:14-15`, which does:

```bash
export HOME="$TMP_TEST_DIR/home"
mkdir -p "$HOME"
```

Its `setup()` MUST gain the same two lines in this feature. Without them, any test that reaches a
`${HOME}`-derived path — a future regression, a copy-paste of a `start-services-warm.bats` case, or
a mutation that reinstates the default argument — scans the developer's real `~/.local/bin` while
the suite runs. The scratch `HOME` is a containment measure for the mutation, not a convenience:
mutation **M19** (reinstating `DIR="${DIR:-$HOME/.local/bin}"`) must be safe to run. (This was
written as "M5" until `/speckit-analyze` 2026-09-19 found that `quickstart.md` §3 — the registry for
the M-namespace — already binds M5 to the warm-wording mutation, so this one had no row and never
ran.)

### C11 — The pruner NEVER removes anything else

Normative, and the clause this feature is most exposed on — the directory it walks is on the
operator's bind-mount:

1. It MUST NOT remove a symlink whose target **resolves**, regardless of where that target points —
   including a live link into `/opt/uv/tools/`.
2. It MUST NOT remove a symlink whose raw target does **not** begin with `/opt/uv/tools/`, even when
   that link is dangling (e.g. `→ /usr/local/bin/gone`, `→ ../relative/gone`, `→ /opt/uv/bin/gone`).
3. It MUST NOT remove, truncate or modify a **regular file**, a directory, or any other node type,
   even when its name matches a package the warm is about to install.
4. It MUST NOT follow the link and touch the target.
5. It MUST NOT scan any path other than the directory it was given (no recursion, no system paths).

**Oracle** (host bats): one test per sub-clause over a single scratch directory pre-populated with
six entries — a dangling `/opt/uv/tools/…` link (removed), a resolving `/opt/uv/tools/…` link
(kept), a dangling `/usr/local/bin/…` link (kept), a dangling relative link (kept), a regular file
named like a warm package (kept, with its content compared byte-for-byte after the run), and a
subdirectory (kept). Post-conditions are asserted with `[ -e ]` / `[ -L ]` / `cmp`, so a
`readlink`-vs-`-e` mix-up is caught.

**Mutation**: widening the predicate to "any dangling symlink" turns sub-clauses 2 red; dropping the
`[ ! -e ]` guard turns sub-clause 1 red.

### C12 — The pruner always returns 0

It MUST return 0 in every case, including: **no argument at all**, an **empty** argument, `DIR` does
not exist, `DIR` is not readable, `DIR` is empty, `rm` fails on an individual entry, and `readlink`
is unavailable. A boot step may never abort the boot (Principle IV; the caller's `|| true` is a belt,
not the mechanism).

**Oracle** (host bats): six cases — no argument, `""`, absent `DIR`, empty `DIR`, `DIR` with mode
`0000` (skipped when the test runs as root, since root ignores the mode), and a `DIR` containing a
prunable link on a read-only parent — each asserting `[ "$status" -eq 0 ]`. The first two overlap
with C10 oracle (b) deliberately: one proves the guard exists, the other proves it is fail-soft.

### C13 — The pruner is idempotent and silent when there is nothing to do

CANON-W4 MUST be emitted **only** when at least one link was removed, with `N` equal to the number
removed. A run that removes nothing MUST produce no output at all. A second consecutive run over the
same directory MUST remove nothing and log nothing.

**Oracle** (host bats): run twice over a directory holding two dangling `/opt/uv/tools/…` links;
first run asserts `pruned 2 stale uv link(s) from <dir> (image rebuild leaves them dangling)` and
that both are gone; second run asserts empty output and rc 0. A third case over a directory with
only kept entries asserts empty output.

### C14 — The pruner runs before the warm, on every boot

`pre_warm_mcps` (`docker/scripts/start_services.sh:808-811`) MUST call
`mcp_warm_prune_stale_links` **before** `mcp_warm_run`. The order is load-bearing for two reasons:

- `mcp_warm_targets` returns early when `.mcp.json` is absent (`mcp_warm.sh:62`), and
  `mcp_warm_run` then does nothing — but the stale links must be cleaned even for an agent that has
  no uvx/npx targets left (spec Edge Cases).
- A link left in place would re-block the very install the warm is about to attempt.

`pre_warm_mcps` keeps its `command -v mcp_warm_run` guard (`:809`) so an image whose lib failed to
load is still a no-op, and it is still called from `start_session` (`:821`) before the tmux launch.

#### The first draft's oracle was blind to the mutation it claimed to catch (adversarial review, HIGH)

The earlier wording of this clause justified its behavioural oracle with "test (b) fails if the call
is placed after `mcp_warm_run`'s early return path". **That justification is false, and so was the
oracle built on it.** Verified in the tree:

- The early return belongs to `mcp_warm_targets` — `[ -f "$mcp_json" ] || return 0`
  (`scripts/lib/mcp_warm.sh:62`) — and `mcp_warm_targets` is invoked inside a **process
  substitution**, `done < <(mcp_warm_targets "$mcp_json")` (`:128`). Its early return ends a
  subshell, nothing more.
- `mcp_warm_run` itself has **no** early return. With an absent `.mcp.json` the `while` loop simply
  reads zero lines, `tried` stays `0`, the summary is skipped (`:129-131`) and control reaches
  `return 0` (`:132`) exactly as it does on a normal run.

So a pruner call placed *after* `mcp_warm_run` still executes, and the seeded link is still deleted.
The old test (b) asserts only "the link is gone and rc is 0", which both orders satisfy — mutation
**M4** (move the pruner below the warm) would have survived it.

#### The oracle, rewritten so the order is actually observable

The only way to make the order load-bearing in an assertion is to make the **warm's outcome** depend
on whether the link was still there when the installer ran. Seed a dangling link whose basename
collides with a package the `.mcp.json` declares, and give `uv` a stub that reproduces the real
failure — `rc=2` while the link exists, `rc=0` once it is gone:

```bash
@test "036 US1: pre_warm_mcps prunes the colliding stale link BEFORE warming (M4)" {
  mkdir -p "$HOME/.local/bin"
  ln -s /opt/uv/tools/workspace-mcp/bin/workspace-mcp "$HOME/.local/bin/workspace-mcp"

  # Reproduces uv's real behaviour: "Executable already exists" (rc 2) while the
  # link is present; a clean install (rc 0) once the pruner has removed it.
  cat > "$TMP_TEST_DIR/bin/uv" <<EOF
#!/bin/sh
echo "uv \$*" >> "$TMP_TEST_DIR/warm.log"
[ -L "$HOME/.local/bin/workspace-mcp" ] && exit 2
exit 0
EOF
  chmod +x "$TMP_TEST_DIR/bin/uv"

  cat > "$WORKDIR/.mcp.json" <<'EOF'
{ "mcpServers": { "gws": { "command": "/w/seed.sh", "args": ["uvx", "workspace-mcp"] } } }
EOF

  run pre_warm_mcps
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$TMP_TEST_DIR/warm.out"

  # Post-condition 1: the link is gone. TRUE IN BOTH ORDERS — never assert only this.
  [ ! -L "$HOME/.local/bin/workspace-mcp" ]

  # Post-condition 2: the installer never saw the link, so no CANON-W1 was emitted.
  # Pruner-before → 0. Pruner-after → 1 (`warn: uvx workspace-mcp failed (exit 2) …`).
  run grep -c 'failed (exit 2)' "$TMP_TEST_DIR/warm.out"
  [ "$output" -eq 0 ]
  run grep -c 'warm cache: 1/1 warm, 0 failed' "$TMP_TEST_DIR/warm.out"
  [ "$output" -eq 1 ]
}
```

Counts are read through `run grep -c` and compared, never with a bare intermediate `grep -q` (an
unmatched `grep -q` under bats' errexit aborts the test) and never with
`$(grep -c … || echo 0)` (`data-model.md` §6).

**Oracle (a)** — static source order, in the mould of
`"030 US1: pre_warm_mcps is invoked in start_session before tmux new-session"`
(`tests/start-services-warm.bats:81-89`): inside the extracted body of `pre_warm_mcps`, the
`mcp_warm_prune_stale_links` line number is lower than the `mcp_warm_run` one. Cheap, but it only
pins the text — (b) is what pins the behaviour.

**Oracle (c)** — independence from `.mcp.json`: with **no** `.mcp.json`, `START_SERVICES_NO_RUN=1`,
`HOME` in the tmpdir and a dangling `/opt/uv/tools/…` link seeded in `$HOME/.local/bin`, assert the
link is gone and `pre_warm_mcps` returned 0. This is the old test (b), kept for what it *does*
prove — that the cleanup happens for an agent with zero uvx/npx targets left (spec Edge Cases, E2) —
and demoted from "the order oracle", which it never was.

**Mutation M4**: move `mcp_warm_prune_stale_links` below `mcp_warm_run` in `pre_warm_mcps`. Oracle
(b)'s two count assertions go red; (a) goes red; (c) stays green, which is exactly the blind spot
this rewrite closes.

### C15 — The image sets `UV_TOOL_BIN_DIR`, and `PATH` is deliberately untouched

`docker/Dockerfile` MUST add `UV_TOOL_BIN_DIR=/opt/uv/bin` to the existing `ENV` block at `:118-120`
(alongside `UV_TOOL_DIR`, `UV_CACHE_DIR`, `UV_PYTHON_PREFERENCE`), so both halves of uv's state share
the image's lifecycle. The `RUN mkdir -p /opt/uv … chown -R ${UID}:${GID} /opt/uv` block at
`:121-125` already creates and owns the parent and is **not** modified.

`ENV PATH` MUST NOT be introduced. The Dockerfile sets no `PATH` today, MCP servers are launched as
`uvx <pkg>` (resolved from `/usr/local/bin`, `docker/Dockerfile:100-101`), and the links uv wrote had
exactly one observable effect — blocking later installs (plan DD-1, measured). Adding a bin
directory to `PATH` would be surface with no consumer.

**Oracle**: (a) host bats greps the Dockerfile for `UV_TOOL_BIN_DIR=/opt/uv/bin` and asserts the
absence of any `ENV PATH` / `ENV .*PATH=` line, in the mould of the existing COPY assertion
(`tests/start-services-warm.bats:99-101`); (b) DOCKER_E2E asserts, inside a `--user agent` container,
that `printenv UV_TOOL_BIN_DIR` is `/opt/uv/bin`, that a warm of a non-catalogue package creates its
executable under `/opt/uv/bin`, and that `$HOME/.local/bin` gained nothing.

### C16 — Forcing must not break the baked catalogue (FR-004)

`docker/Dockerfile:122-124` bakes `mcp-atlassian`, `mcp-server-fetch` and `mcp-server-time`. A warm
run that passes `--force` MUST leave all three installed and runnable.

**Oracle** (DOCKER_E2E, extending `tests/docker-e2e-warm-cache.bats`): after a warm whose
`.mcp.json` includes one of the baked packages **and** an out-of-catalogue one, assert `uv tool list`
still lists all three baked tools and that `UV_OFFLINE=1 uvx mcp-server-fetch --help` exits 0. The
existing assertion `grep -qE '^CATALOG=[1-9]'` in
`"E2E 030: catalog stays pre-warmed and a second warm is a no-op (FR-009)"` stays green unmodified.

### C17 — The new code inherits 030's static guarantees

The added code MUST NOT reference secrets or credential paths, and sourcing the lib MUST remain
side-effect free (definitions only — no directory scan, no `rm`, at source time).

**Oracle**: the two existing static tests stay green **unmodified** —
`"030: mcp_warm.sh reads no secrets (FR-006/SC-005)"` (`tests/mcp-warm.bats:187-193`, a grep over
non-comment lines for `\.env|GOOGLE_OAUTH|credential|id_rsa|\.age|\.ssh`) and
`"030: sourcing mcp_warm.sh has no side effects"` (`tests/mcp-warm.bats:195-201`, asserting empty
output and rc 0 on a fresh `source`).

### C18 — Portability

Every construct MUST work under bash 3.2.57 and 5.x (SC-007) **and** under the container's shell
environment. Concretely: no `declare -A`, no `mapfile`, no `${var,,}`; `readlink` without `-f`;
`[ ]` rather than `[[ ]]` for the predicate tests so an intermediate negation cannot silently pass
(`tests/…` lesson: a non-final `[[ ]]` does not fail a bats test); and `shellcheck -S error` clean.

**Oracle**: `bats tests/` byte-identical under both bashes, plus `shellcheck -S error` rc 0 — the
gates SC-007 already requires.

### C19 — The new function reaches the image

`mcp_warm_prune_stale_links` lives in `scripts/lib/mcp_warm.sh`, which `setup.sh` mirrors to
`<workspace>/docker/scripts/lib/mcp_warm.sh` (`setup.sh:1646,1668-1669`, validated at
`setup.sh:1710-1711`) and the Dockerfile copies to `/opt/agent-admin/scripts/lib/mcp_warm.sh`
(`docker/Dockerfile:259`). No new file is introduced, so no new `COPY` line is needed — the gotcha
"docker lib needs explicit COPY" is satisfied by the existing wiring.

**Oracle**: the existing wiring tests stay green unmodified
(`tests/start-services-warm.bats:93-105`), and DOCKER_E2E asserts
`type mcp_warm_prune_stale_links` resolves after sourcing the baked lib inside the container, in the
mould of `"E2E 030: the baked start_services.sh calls pre_warm_mcps before the tmux launch"`.

## 5. Invariants preserved from feature 030

`tests/mcp-warm.bats` holds 14 tests today. **All 14 keep applying verbatim** — none is rewritten,
churned or deleted by this feature. Listed with their status:

| # | Test name | Status under 036 |
| --- | --- | --- |
| 1 | `030: mcp_warm_targets derives uvx/npx across every shape (cases 1-10)` | applies as-is (derivation untouched) |
| 2 | `030: the incident case (google-workspace wrapper) is derived (case 5)` | applies as-is |
| 3 | `030: npx -p takes the package after the flag, not the bin name (case 7)` | applies as-is |
| 4 | `030: binaries and wrappers-to-baked are omitted (cases 9,10)` | applies as-is |
| 5 | `030: duplicate (runtime,package) is deduped (case 11)` | applies as-is |
| 6 | `030: absent .mcp.json → zero lines, rc 0 (case 12)` | applies as-is |
| 7 | `030: empty mcpServers → zero lines, rc 0` | applies as-is |
| 8 | `030: a server without args does not abort derivation` | applies as-is |
| 9 | `030: mixed catalog+overlay derives ALL uvx/npx with no hardcoded list` | applies as-is |
| 10 | `030: mcp_warm_run warms each target and returns 0 (uv/npm stubs)` | applies as-is — `grep -q 'uv tool install'` still matches once `--force` is appended (C1 adds a stricter assertion beside it, it does not replace this one) |
| 11 | `030: mcp_warm_run is fail-soft — a failing warmer does not abort (FR-007/008/SC-004)` | applies as-is — CANON-W1 keeps `will resolve on first use` (C8) |
| 12 | `030: mcp_warm_run is idempotent — safe to re-run (FR-005)` | applies as-is (C9) |
| 13 | `030: mcp_warm.sh reads no secrets (FR-006/SC-005)` | applies as-is, and constrains the new code (C17) |
| 14 | `030: sourcing mcp_warm.sh has no side effects` | applies as-is, and constrains the new code (C17) |

Also preserved, from `tests/start-services-warm.bats`: the six boot-integration tests, in particular
`"030 US1: pre_warm_mcps is fail-soft — returns 0 even when the warmer fails"` (`:65-71`) and
`"030 US1: pre_warm_mcps with no .mcp.json does not abort"` (`:73-77`) — the second of which now
also exercises the pruner's independence from `.mcp.json` (C14).

Unchanged contracts from 030 that this feature explicitly does not renegotiate:

- `mcp_warm_targets` is pure: no network, no side effects, deterministic sorted output.
- The warm reads no secrets: installing a package is independent of the credentials its MCP needs to
  start.
- The per-package ceiling is `MCP_WARM_TIMEOUT`, default 300 s (`mcp_warm.sh:117`) — unchanged; D1
  refuted the hypothesis that it was ever the problem.
- `_mcp_warm_timeout`'s fallback to direct execution when no `timeout`/`gtimeout` exists
  (`mcp_warm.sh:79-88`).

## 6. Edge cases

| # | Case | Required behaviour | Oracle |
| --- | --- | --- | --- |
| E1 | New package, no executable-name collision | Installs normally; `--force` is a no-op on the outcome; class `warm`; no warn line | host bats: stub rc 0, assert no `warn:` in output and summary `1/1 warm, 0 failed` |
| E2 | Agent with zero uvx/npx targets | `mcp_warm_run` emits nothing (no summary line, `tried == 0`); the pruner still runs | host bats: `.mcp.json` with only baked-binary servers → empty output; plus C14 oracle (c) with no `.mcp.json` at all |
| E3 | The directory passed does not exist | Pruner returns 0, logs nothing, creates nothing | host bats: pass `"$TMP_TEST_DIR/home/.local/bin"` **explicitly** on a tree where it was never created; assert rc 0, empty output, and that the directory was **not** created |
| E3b | The pruner is called with no argument, or with `""` | Returns 0 without scanning; nothing is read, nothing is removed | C10 oracle (b) + C12 — the guard that keeps a local-mode `source` from ever reaching the operator's own `~/.local/bin` |
| E4 | Link that resolves correctly | Kept, untouched (`[ -L ]` and `[ -e ]` both still true after the run) | C11 sub-clause 1 |
| E5 | Link pointing somewhere other than `/opt/uv/tools/` | Kept, even when dangling | C11 sub-clause 2, with three variants: absolute non-uv, relative, and `/opt/uv/bin/` |
| E6 | Regular file with the same name as a warm package | Kept, byte-identical (`cmp` after the run); never replaced by the install either | C11 sub-clause 3 |
| E7 | Package that genuinely cannot build (`mcp-server-tree-sitter`, needs `Python.h`) | Exactly one CANON-W1 line naming it; boot continues; rc 0 (SC-002) | host bats with stub rc 1 + `grep -c` equal to 1; live gate on `donna` |
| E8 | Warm target colliding with a baked catalogue package | Both stay usable after the forced install | C16, DOCKER_E2E |
| E9 | Directory entry whose name contains spaces or a newline | Predicate still evaluated per entry; nothing outside the predicate is removed | host bats: seed a dangling `/opt/uv/tools/…` link named `a b`; assert it is removed and a sibling regular file survives |

## 7. Test seams

| Seam | Where | Used for |
| --- | --- | --- |
| `load_lib mcp_warm` | `tests/helper.bash:26`, already used by `tests/mcp-warm.bats:12` | Unit-testing `mcp_warm_run` and `mcp_warm_prune_stale_links` directly on the host |
| `_install_warm_stubs RC` | `tests/mcp-warm.bats:19-34` | `uv`/`npm` stubs on `PATH` that log `"$*"` to `warm.log` and exit `RC` — drives C1, C3, C4, C5, C7 |
| `MCP_WARM_STUB_RC` | `tests/start-services-warm.bats:20-31` | The same stubs, but with the exit code read at call time from the environment — drives the boot-integration variants |
| `START_SERVICES_NO_RUN=1` | `tests/start-services-warm.bats:13`, sourcing `docker/scripts/start_services.sh` | Sourcing the supervisor without running it, so `pre_warm_mcps` can be invoked directly (C14) |
| `WORKDIR` override after sourcing | `tests/start-services-warm.bats:36` | `start_services.sh` hardcodes `WORKDIR=/workspace` at load; the override must stay **after** the `source` |
| `HOME` override into `TMP_TEST_DIR` | `tests/start-services-warm.bats:14-15` (exists); **must be added to `tests/mcp-warm.bats:10-14`, which has none today** | Containment: the pruner's caller derives `"$HOME/.local/bin"`, and mutation M19 (reinstating a default argument) must be safe to run. See C10 |
| `MCP_WARM_TIMEOUT` | `mcp_warm.sh:117` | Proving CANON-W2's seconds come from the variable (C5) |
| `DOCKER_E2E=1` | `tests/docker-e2e-warm-cache.bats:16-20` | The image-level clauses C15, C16, C19 |

No new seam is introduced — every clause above is reachable from a seam that already exists. The one
required *test-setup* change is the scratch `HOME` in `tests/mcp-warm.bats::setup` (C10); it adds no
mechanism, it only stops an existing seam from resolving to the developer's real home.

## 8. What this contract does NOT cover

- **US2** (`docker.channel_health_timeout_s` and its render) — `channel-window-config.md`.
- **US3** (bounded initial-boot retry, `MAX_BOOT_ATTEMPTS`, CANON-B1/B2) — `boot-retry-contract.md`.
- **US4** (`--list-markers` and `agentctl doctor`) — `patch-marker-listing.md`.
- **Making an unbuildable package build.** `mcp-server-tree-sitter` fails warm or cold for lack of
  `Python.h`; it must keep warning once and the boot must keep going (`research.md` D2).
- **The `MCP_TIMEOUT` handshake window** (feature 029). Unchanged; a warm failure still degrades to
  that wider window.
- **Migrating `~/.local/bin` links to `/opt/uv/bin`.** Nothing is moved; stale links are removed and
  new ones are written to the new location by uv itself.
- **Adding `/opt/uv/bin` to `PATH`.** Rejected in plan DD-1; no consumer exists.
- **Dangling links under `~/.local/bin` that point into `/opt/uv/bin/`** rather than
  `/opt/uv/tools/`. The predicate is deliberately narrow (`data-model.md` §3) and leaves them in
  place; they are harmless because `/opt/uv/bin` lives in the image and is recreated with it. See
  Observaciones.
- **The npm cache** (`/opt/npm-cache`). It has no per-executable link namespace, so the collision
  class does not exist there.
- **Any automated detection of a silently-stuck channel.** Forbidden by `CLAUDE.md` (`ebfe35f`) and
  by FR-013.

## 9. Observaciones

Three notes for the operator, none of which change a canonical string:

1. **CANON-W3's outcome has no bucket in the summary line.** `data-model.md` §2 lists four outcomes
   (`warm` / `failed` / `timed out` / `unavailable`) but the preserved summary line
   `warm cache: N/M warm, K failed` has only two buckets, and its wording says "failed" for a case
   whose own warn line says "skipping". C7 resolves this the conservative way — `unavailable` counts
   toward `K failed`, which is exactly today's arithmetic, since `_mcp_warm_one` already returns 1
   for a missing runtime. Flagged rather than changed: altering the summary would churn a line that
   `data-model.md` explicitly marks as unchanged.

2. **`data-model.md` fixes CANON-W2's wording but not the exit codes that trigger it.** I measured
   them rather than assuming: busybox `timeout` on Alpine 3.20 and 3.24.1 (the image's base,
   `docker/Dockerfile:5`) returns **143**, not the GNU `124`. A rule written only against `124`
   would have classified every real container timeout as `failed (exit 143)` — silently reproducing
   the exact conflation US1 exists to remove. C3 therefore specifies `{124, 143}`. Residual, stated
   openly: an installer that genuinely exits 124 or 143 on its own would be misreported as a
   timeout. That is strictly better than today (where it is reported as nothing at all), and the
   alternative — inspecting elapsed wall time — would add a clock dependency to a function that is
   currently deterministic under test.

3. **The pruner's predicate does not cover `/opt/uv/bin/`.** After C15 lands, uv writes its links to
   `/opt/uv/bin`, inside the image; a workspace that has *both* generations of links will keep any
   dangling `/opt/uv/bin/…` link in `~/.local/bin` forever, because `data-model.md` §3 scopes the
   predicate to `/opt/uv/tools/`. In practice this cannot arise — uv never wrote to `~/.local/bin`
   with a `/opt/uv/bin` target — so I implemented the predicate as specified rather than widening
   it. If a future review wants belt-and-braces, the change is one `case` branch, and E5's third
   variant is the test that would have to flip.
