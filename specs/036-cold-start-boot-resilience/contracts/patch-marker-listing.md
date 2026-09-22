# Contract — patch marker listing (`--list-markers`) and its `doctor` consumer

**Feature**: 036 cold-start boot resilience — **US4** (`doctor` tells the truth about plugin patches)

**Covers**: FR-014, FR-015, FR-016, FR-017 · SC-005, SC-006, SC-008

**Producers / consumers**

| Role | File |
| --- | --- |
| Owner of the marker set | `docker/scripts/apply_telegram_typing_patch.py` (image-baked, `/opt/agent-admin/scripts/…`) |
| Consumer | `scripts/agentctl`, check 12 (`cmd_doctor`, `:523-543`) |
| Reference for the file set | `docker/scripts/start_services.sh::_hook_telegram_typing_patch` (`:404-415`) |
| Documentation to correct | `docs/creating-an-agent.md:452-460`, `docs/state-layout.md:199` |

Every clause below is numbered `C<n>` and carries an oracle. An oracle is a command or a bats
assertion that must be **red before** the change and **green after**; where the oracle is net-new
coverage (the whole check has no test today, research D5 "Coverage note"), that is stated explicitly.

**Canonical-identifier ownership (adversarial review, MEDIUM — collision resolved).** The
`CANON-D*` series (`CANON-D1` … `CANON-D5`, defined in C11) belongs to **this contract** and names
`agentctl doctor`'s check-12 output lines. An earlier draft of `data-model.md` reused `CANON-D1` for
an unrelated boot-health line; that series was renamed to `CANON-H*` (`data-model.md` §5b), and the
identifiers here are unchanged — `CANON-D1` … `CANON-D5` still mean exactly what C11 says. No other
artefact of feature 036 may define a `CANON-D*` id, and this contract defines no `CANON-H*`,
`CANON-B*`, `CANON-W*` or `CANON-C*` id.

---

## 0. Ground truth read from the tree (2026-09-18)

### 0.1 The marker set the patcher owns

`docker/scripts/apply_telegram_typing_patch.py:106-132`, verbatim:

```python
MARKER_TYPING = "agentic-pod-launcher: typing refresh patch v6"
MARKER_TYPING_V5 = "agentic-pod-launcher: typing refresh patch v5"
MARKER_TYPING_V4 = "agentic-pod-launcher: typing refresh patch v4"
MARKER_TYPING_V3 = "agentic-pod-launcher: typing refresh patch v3"
MARKER_TYPING_V2 = "agentic-pod-launcher: typing refresh patch v2"
MARKER_TYPING_V1 = "agentic-pod-launcher: typing refresh patch v1"
MARKER_OFFSET = "agentic-pod-launcher: offset persistence patch v1"
MARKER_STDERR = "agentic-pod-launcher: stderr-capture patch v1"
MARKER_PRIMARY = "agentic-pod-launcher: primary lock patch v1"
MARKER_PENDING = "agentic-pod-launcher: pending-reply marker patch v1"
MARKER_ASKQ_GIVEUP = "agentic-pod-launcher: askq-guard give-up delivery patch v1"
MARKER_VOICE_V1 = "agentic-pod-launcher: telegram voice roundtrip patch v1"
MARKER_VOICE_V2 = "agentic-pod-launcher: telegram voice roundtrip patch v2"
MARKER_VOICE = "agentic-pod-launcher: telegram voice roundtrip patch v3"

# The seven patch groups at their CURRENT version — main() counts these on the
# no-change path so the boot log says whether the file is fully patched or
# some group's anchors were not found (034).
ALL_MARKERS = (
    MARKER_TYPING,
    MARKER_OFFSET,
    MARKER_STDERR,
    MARKER_PRIMARY,
    MARKER_PENDING,
    MARKER_ASKQ_GIVEUP,
    MARKER_VOICE,
)
```

Note the superseded constants (`MARKER_TYPING_V1..V5`, `MARKER_VOICE_V1`, `MARKER_VOICE_V2`) exist for
the upgrade cascade and are **not** members of `ALL_MARKERS`. Only `ALL_MARKERS` is the contract
surface.

### 0.2 The CLI guard as it stands today

`docker/scripts/apply_telegram_typing_patch.py:2029-2037`, verbatim:

```python
def main(argv: list[str]) -> int:
    if len(argv) != 2:
        log("usage: apply_telegram_typing_patch.py <server.ts>")
        return 2

    path = Path(argv[1])
    if not path.is_file():
        log(f"server.ts not found at {path} — skipping")
        return 0
```

and `log` (`:1312-1313`) writes to **stdout** with a prefix:

```python
def log(msg: str) -> None:
    print(f"[apply_telegram_typing_patch] {msg}", flush=True)
```

**Measured on this host (today's patcher, unmodified):**

```console
$ python3 docker/scripts/apply_telegram_typing_patch.py --list-markers
[apply_telegram_typing_patch] server.ts not found at --list-markers — skipping
rc=0

$ python3 docker/scripts/apply_telegram_typing_patch.py
[apply_telegram_typing_patch] usage: apply_telegram_typing_patch.py <server.ts>
rc=2
```

This is load-bearing for C12 (and for the shim design of C9): **an old patcher given
`--list-markers` exits 0**, because `len(argv) == 2` passes the guard and
`Path("--list-markers").is_file()` is False, which is the `return 0` branch. A compatibility probe
based on the exit code alone therefore cannot work — it would read "empty list = nothing missing =
healthy". `data-model.md` §6 records the same measurement and the same conclusion; C12 is where the
resulting three-condition, content-based gate is specified.

### 0.3 The consumer as it stands today

`scripts/agentctl:523-543`, verbatim:

```bash
  # 12. Telegram plugin patched
  if [ "$notif_channel" = "telegram" ]; then
    local plugin_dir
    plugin_dir=$(_in_container "$agent" sh -c 'ls -d /home/agent/.claude/plugins/cache/claude-plugins-official/telegram/*/server.ts 2>/dev/null | head -1')
    if [ -n "$plugin_dir" ]; then
      local typing_v3 offset stderr primary
      typing_v3=$(_in_container "$agent" grep -c "typing refresh patch v3" "$plugin_dir" 2>/dev/null || echo 0)
      offset=$(_in_container "$agent" grep -c "offset persistence patch v1" "$plugin_dir" 2>/dev/null || echo 0)
      stderr=$(_in_container "$agent" grep -c "stderr-capture patch v1" "$plugin_dir" 2>/dev/null || echo 0)
      primary=$(_in_container "$agent" grep -c "primary lock patch v1" "$plugin_dir" 2>/dev/null || echo 0)
      if [ "$typing_v3" -ge 1 ] && [ "$offset" -ge 1 ] && [ "$stderr" -ge 1 ] && [ "$primary" -ge 1 ]; then
        _doctor_pass "Telegram plugin patches: typing v3, offset v1, stderr v1, primary v1"
      else
        _doctor_warn "Telegram plugin patches incomplete (typing=$typing_v3 offset=$offset stderr=$stderr primary=$primary)" "agentctl restart (apply_telegram_typing_patch.py runs at boot)"
      fi
    else
      _doctor_skip "Telegram plugin patches" "plugin not yet installed in cache"
    fi
  else
    _doctor_skip "Telegram plugin patches" "notifications.channel=$notif_channel"
  fi
```

Supporting facts, all read in the tree:

- `scripts/agentctl:20` — `set -u -o pipefail`. **No `-e`**: a `[` error is printed and execution
  continues, which is why the defect produces a wrong answer rather than a crash.
- `scripts/agentctl:332-335` — the container seam:

  ```bash
  # Helper: run a command inside the container as agent, capture stdout.
  _in_container() {
    local agent="$1"; shift
    docker exec -u agent "$agent" "$@" 2>/dev/null
  }
  ```

  It discards **stderr only**; the invoked command's exit status propagates through `docker exec`.
- `scripts/agentctl:108-119` — the reporters:

  ```bash
  _doctor_pass() { echo "  ✓ $1"; }
  _doctor_warn() {
    echo "  ⚠ $1"
    [ -n "${2:-}" ] && echo "    → $2"
    _doctor_warn_count=$((_doctor_warn_count + 1))
  }
  _doctor_fail() {
    echo "  ✗ $1"
    [ -n "${2:-}" ] && echo "    → $2"
    _doctor_fail_count=$((_doctor_fail_count + 1))
  }
  _doctor_skip() { echo "  ⊝ $1 (skipped — $2)"; }
  ```

- `scripts/agentctl:472-473` — `notif_channel` is resolved once from `agent.yml`
  (`yq -r '.notifications.channel'`) and reused by check 12.
- `scripts/agentctl:616-625` — `doctor` exits 0 only when **both** counters are zero, 1 on
  warnings-only, 2 on any failure. Consequence for oracles: see C11.

### 0.4 The file set the boot patcher walks

`docker/scripts/start_services.sh:404-415`, verbatim:

```bash
_hook_telegram_typing_patch() {
  local spec="$1" cache="$2"
  local patcher=/opt/agent-admin/scripts/apply_telegram_typing_patch.py
  [ -f "$patcher" ] || { log "_hook_telegram_typing_patch: $patcher missing, skipping"; return 0; }
  local server_ts
  for server_ts in "$cache"/*/server.ts; do
    [ -f "$server_ts" ] || continue
    python3 "$patcher" "$server_ts" 2>&1 | while IFS= read -r line; do
      log "$line"
    done
  done
}
```

Two properties to mirror: the loop is over **every** `*/server.ts` under the plugin cache, and the
patcher is invoked as `python3 <path>` (the file is shipped `0644` by
`docker/Dockerfile:234`, so it is not directly executable).

---

## Part A — the producer: `--list-markers`

### C1 — The flag exists and requires no file argument

`apply_telegram_typing_patch.py --list-markers` MUST be accepted, and MUST NOT require, accept as
meaningful, or consult any file path. The guard at `:2030` MUST be changed so that `--list-markers`
is dispatched **before** `argv[1]` is interpreted as a path.

```text
Oracle (net-new, tests/apply-telegram-patches.bats):
  run python3 "$PATCHER" --list-markers
  [ "$status" -eq 0 ]
RED today: status is 0 but stdout is the "server.ts not found at --list-markers" log line
           (measured, §0.2) — so the status assertion alone is NOT a valid oracle.
           C2+C3 are what turn this red. See C1b.
```

**C1b (the discriminating oracle for C1).** Because today's exit status for this invocation is
already 0, every test of the flag MUST assert on **content**, never on status alone.

```bash
run python3 "$PATCHER" --list-markers
[ "$status" -eq 0 ]
# the log prefix must NOT appear anywhere in the output
run bash -c 'python3 "'"$PATCHER"'" --list-markers | grep -c "apply_telegram_typing_patch"'
[ "$output" = "0" ]
```

### C2 — Output shape: one marker per line, nothing else

Stdout MUST consist of exactly `len(ALL_MARKERS)` lines. Each line MUST be one marker string,
verbatim, with no prefix, no suffix, no index, no quoting, and no blank lines. Stderr MUST be empty.
The `log()` helper MUST NOT be used (it prefixes every line with `[apply_telegram_typing_patch]`
followed by a space, §0.2) — the
listing writes with a bare `print()`.

```bash
# Oracle: line count and prefix purity
run bash -c 'python3 "'"$PATCHER"'" --list-markers | wc -l | tr -d " "'
[ "$output" = "7" ]
run bash -c 'python3 "'"$PATCHER"'" --list-markers | grep -cv "^agentic-pod-launcher: "'
[ "$output" = "0" ]
# Oracle: stderr silent
run bash -c 'python3 "'"$PATCHER"'" --list-markers 2>&1 >/dev/null'
[ -z "$output" ]
```

### C3 — Output order is `ALL_MARKERS` order

The lines MUST appear in the tuple order of `ALL_MARKERS` (`:124-132`): typing, offset, stderr,
primary, pending-reply, askq-giveup, voice. The listing MUST iterate that tuple directly; it MUST NOT
re-sort, de-duplicate, or rebuild the list from the individual `MARKER_*` constants.

```bash
# Oracle: byte-exact expected output (see C4 for the literal)
run bash -c 'python3 "'"$PATCHER"'" --list-markers'
[ "$output" = "$EXPECTED_MARKER_LISTING" ]
```

### C4 — Reference output (verbatim, measured 2026-09-18)

This is the exact stdout of `--list-markers` for the patcher at the head of
v0.25.0 (commit `a1fa449`), copied from `ALL_MARKERS` as read in §0.1:

```text
agentic-pod-launcher: typing refresh patch v6
agentic-pod-launcher: offset persistence patch v1
agentic-pod-launcher: stderr-capture patch v1
agentic-pod-launcher: primary lock patch v1
agentic-pod-launcher: pending-reply marker patch v1
agentic-pod-launcher: askq-guard give-up delivery patch v1
agentic-pod-launcher: telegram voice roundtrip patch v3
```

This block is **illustrative of the current set, not a frozen oracle**. A test MUST NOT hardcode
these seven strings as the expected value — that would re-create in the test suite exactly the
duplication FR-015 removes from `agentctl`, and SC-003-of-US4 (spec acceptance scenario 3, "the
patcher later bumps a marker version → `doctor` keeps working without edits") would then fail in the
test suite instead of in `agentctl`. The permitted oracle derives the expectation from the patcher's
own source:

```bash
# Derive the expectation from ALL_MARKERS, then compare with the flag's output.
_expected_markers() {
  python3 - "$PATCHER" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("apl", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
for m in mod.ALL_MARKERS:
    print(m)
PY
}
run bash -c "diff <(python3 '$PATCHER' --list-markers) <(_expected_markers)"
[ "$status" -eq 0 ]
```

One count assertion against the literal `7` is allowed (C2) because a change in the number of groups
is a deliberate, reviewable event; a change in a *version suffix* is not.

### C5 — `--list-markers` touches no file

The flag MUST return before any `Path` is constructed from `argv`, before any `read_text`, and before
any write. Specifically it must not create the `<path>.apl-tmp` temp file of the write path
(`:2087-2089`).

```bash
# Oracle: run inside an empty dir; nothing appears, nothing is modified.
tmp="$(mktemp -d)"
cp tests/fixtures/telegram-server-pristine.ts "$tmp/server.ts"
before=$(cd "$tmp" && ls -1 | sort; shasum "$tmp/server.ts")
( cd "$tmp" && python3 "$PATCHER" --list-markers >/dev/null )
after=$(cd "$tmp" && ls -1 | sort; shasum "$tmp/server.ts")
[ "$before" = "$after" ]
```

### C6 — Every other invocation is unchanged

`--list-markers` is additive. `python3 apply_telegram_typing_patch.py <server.ts>` MUST behave
byte-identically to today, and any other argument count MUST still print the usage line and exit 2
(`:2030-2032`).

```bash
# Oracle A: no-arg and two-arg usage unchanged
run python3 "$PATCHER"; [ "$status" -eq 2 ]
echo "$output" | grep -q "usage: apply_telegram_typing_patch.py <server.ts>"
run python3 "$PATCHER" a b; [ "$status" -eq 2 ]
# Oracle B: the patch path is untouched — the full-cascade sha of a patched
# pristine fixture is identical before and after this feature.
```

Oracle B is the standing regression net of `tests/apply-telegram-patches.bats` (119 tests as of 034);
no assertion in it may change for this feature. A diff in that file is itself the failure signal.

---

## Part B — the consumer: `agentctl doctor`, check 12

### C7 — The marker set is fetched, never authored

`doctor` MUST obtain the group list by invoking the image-baked patcher in the container:

```bash
_in_container "$agent" python3 /opt/agent-admin/scripts/apply_telegram_typing_patch.py --list-markers
```

It MUST iterate the returned lines with `while IFS= read -r marker` (markers contain spaces) and MUST
match each one with **fixed-string** grep (`grep -F`), never as a pattern.

```text
Oracle: bats with a docker shim (mould: tests/agentctl-doctor-claude-oauth.bats::setup) whose
`exec` arm answers the --list-markers probe with a marker list the test controls. Feeding the
shim a SIX-marker list and a server.ts carrying those six must produce a pass — proving the
check consulted the list it was given rather than an internal set of seven.
```

### C8 — Counting: `$(grep -c … || echo 0)` is forbidden

**The rule.** The construct

```bash
count=$(_in_container "$agent" grep -c "…" "$file" 2>/dev/null || echo 0)
```

MUST NOT appear in `scripts/agentctl`. Any value that reaches a `[ … -ge … ]` or `$(( … ))` MUST be a
single numeric token; an empty or non-numeric value MUST be normalised to `0` **before** the test,
e.g.:

```bash
c=$(_in_container "$agent" grep -c -F -- "$marker" "$f")
case "$c" in ''|*[!0-9]*) c=0 ;; esac
```

Presence-only testing (`grep -q -F --`, branch on rc) is equally acceptable and is the preferred
shape, since FR-015 needs presence, not multiplicity.

**Why the construct is wrong — measured on this host, bash 3.2.57:**

```console
$ /bin/bash -c 'set -u -o pipefail
v=$(grep -c "nomatch" /tmp/gctest.txt 2>/dev/null || echo 0)
printf "value=[%s]\n" "$v"
if [ "$v" -ge 1 ]; then echo GE; else echo LT; fi'
value=[0
0]
/bin/bash: line 0: [: 0
0: integer expression expected
LT
```

`grep -c` prints `0` on stdout **and** exits 1 when there is no match, so `|| echo 0` appends a second
`0`; the captured value is the 3-byte string `0\n0`. `[` then errors on stderr and, because
`agentctl` runs without `set -e` (`:20`), execution falls through to the `else` branch — the warning.
The same reproduction holds in busybox/Alpine 3.20 (research D5).

```text
Oracle A (static, whole file):
  run bash -c "LC_ALL=C grep -nE 'grep -c[^|]*\|\| *echo' '$REPO_ROOT/scripts/agentctl'"
  [ "$status" -eq 1 ]          # no match anywhere
RED today: matches scripts/agentctl:529,530,531,532.

Oracle B (behavioural, net-new): see C10 — a doctor run over a fully patched file must contain
no shell error text.
```

### C9 — The test shim MUST replicate `grep -c`'s rc=1-on-zero

A docker shim whose grep arm does `echo 0; exit 0` is a **dead oracle**: with that shim the buggy
`|| echo 0` never fires, the captured value is a clean `0`, the comparison succeeds arithmetically,
and the test passes against the unfixed implementation. The shim MUST therefore mirror the real
tool's contract — print the count, and exit 1 when the count is zero:

```bash
# in the docker shim's `exec` arm, for a grep-style invocation
n=$(count_of_marker_in_fixture)
echo "$n"
[ "$n" -gt 0 ] || exit 1      # this line is the oracle; without it the test is tautological
```

The same applies to the `ls -d … server.ts` arm: real `ls` exits non-zero when the glob matches
nothing, and the current code's `2>/dev/null | head -1` masks that, so the shim must be able to
produce both the empty-and-nonzero and the populated-and-zero cases.

```text
Oracle (meta, run once by hand and recorded in quickstart.md's mutation table):
with the shim's `|| exit 1` line present, `git stash` the agentctl fix and re-run the new bats
file — at least one named test must go red. That is SC-008 for US4.
```

### C10 — No shell error text may appear in `doctor` output, at any count

Under every count (0, 1, many) and every shim shape, the output of `agentctl doctor` MUST NOT contain
`integer expression expected`, `unary operator expected`, `: not found`, or any other shell
diagnostic. `bats`'s `run` merges stderr into `$output`, so a single assertion covers both streams.

```bash
# Oracle (net-new)
AGENT_NAME=testagent run "$AGENTCTL" doctor
run bash -c "printf '%s' \"\$output\" | grep -cE 'integer expression expected|unary operator expected'"
[ "$output" = "0" ]
```

RED today: with a shim that replicates C9, a zero count produces
`[: 0\n0: integer expression expected` in the captured output.

### C11 — Pass and warn wording (CANON strings)

| ID | Condition | Emitted |
| --- | --- | --- |
| **CANON-D1** | every file in the set carries every marker in the list | `_doctor_pass "Telegram plugin patches: <N>/<N> groups present (<M> file(s) checked)"` |
| **CANON-D2** | at least one file is missing at least one marker | `_doctor_warn "Telegram plugin patches incomplete in <verdir>: <K>/<N> groups present, missing: <marker>[, <marker>…]" "agentctl restart (apply_telegram_typing_patch.py runs at boot)"` |
| **CANON-D3** | the flag is unsupported (C12) | `_doctor_skip "Telegram plugin patches" "image patcher predates --list-markers; rebuild the image to enable this check"` |
| **CANON-D4** | no `server.ts` in the cache | `_doctor_skip "Telegram plugin patches" "plugin not yet installed in cache"` — **unchanged from today** (`:539`) |
| **CANON-D5** | `notifications.channel != telegram` | `_doctor_skip "Telegram plugin patches" "notifications.channel=$notif_channel"` — **unchanged from today** (`:542`) |

The five ids above are this contract's own series (see the ownership note in the preamble); they are
`CANON-D1` … `CANON-D5` and no other 036 artefact defines a `CANON-D*`.

`<N>` is the length of the list received from the patcher. `<verdir>` is the version directory
segment of the offending file (the path component between `telegram/` and `/server.ts`), not the full
path — the full path is a constant and carries no information. The missing groups are named **by
their marker string as received**, which is what keeps `agentctl` literal-free (C13). The hint text of
CANON-D2 is byte-identical to today's (`:536`).

**CANON-D1 is unreachable with an empty list.** `<N>` comes from the listing, so a `0/0 groups
present` pass is arithmetically possible and semantically false — it is the false-clean verdict of
C12 wearing a pass glyph. The acceptance gate of C12 runs **before** any counting, so an empty or
unprefixed listing reaches CANON-D3 and never CANON-D1. See C12's Oracle D.

```text
Oracle, SC-005 (net-new): fully-patched fixture + list of 7 → output matches
  '✓ Telegram plugin patches: 7/7 groups present' and contains no '⚠ Telegram plugin patches'.
Oracle, SC-006 (net-new): fixture missing exactly the voice group → output matches
  '⚠ Telegram plugin patches incomplete' AND contains the literal marker text the shim served
  for that group.
```

**Scope note for the SC-005 oracle.** `doctor`'s process exit code is 0 only when *every* check is
clean (`:616-618`). A bats oracle must therefore assert on the **check-12 lines**, not on
`[ "$status" -eq 0 ]`, unless the fixture agent is contrived so that all other checks pass too. SC-005
("exits 0 with no patch warning and no shell error text") is measured end-to-end on the live gate,
not in the unit test.

### C12 — Unsupported flag degrades to *skipped*, never to a failure

If the container's patcher predates `--list-markers`, the check MUST report CANON-D3 and MUST NOT
call `_doctor_warn` or `_doctor_fail`. Detection is **content-based, never status-based** — this is
the same rule `data-model.md` §6 states, and it is measured, not inferred.

**Why a status probe is not merely weaker but actively wrong** (§0.2, reproduced on this host): an
old patcher handed `--list-markers` exits **0**, not 2. `len(argv) == 2` satisfies the usage guard
(`:2029-2033`), `Path("--list-markers").is_file()` is then False, and that branch logs to stdout and
`return 0`s. A probe that trusts the exit status therefore reads *success with no markers*, i.e.
"zero groups expected, zero missing", and reports a perfectly healthy agent — the exact false-clean
verdict US4 exists to eliminate, merely inverted. Making the old binary exit non-zero is not an
option either: it is image-baked and already shipped.

The listing is accepted only if **all** of the following hold:

1. the command's exit status is 0, **and**
2. stdout is non-empty after trimming trailing newlines — an empty listing is **never** treated as
   "no groups to check", **and**
3. every line begins with `agentic-pod-launcher:` followed by a space (regex
   `^agentic-pod-launcher:[[:space:]]`) — in particular, a line containing
   `[apply_telegram_typing_patch]` invalidates the whole listing, which is precisely what the old
   binary's `server.ts not found at --list-markers — skipping` log emits.

Condition 1 alone is worthless (it holds for the old binary); conditions 2 and 3 are what actually
discriminate, and both are about **content**. Failing any of the three, the check emits CANON-D3 and
returns *before* counting anything. The same path covers a container that is not running, a
`docker exec` that fails, and a patcher file that is missing — all of which yield empty stdout
through `_in_container`.

```text
Oracle A (old-image simulation, net-new): shim answers the --list-markers probe with
  '[apply_telegram_typing_patch] server.ts not found at --list-markers — skipping' and exit 0.
  Expect: output contains '⊝ Telegram plugin patches (skipped — image patcher predates'
  and does NOT contain '⚠ Telegram plugin patches'.
  This is the discriminating case: a status-based probe passes it while emitting a PASS, so the
  test must assert the skip line, never merely "no failure".
Oracle B: shim answers with empty stdout, exit 0 → same CANON-D3 line.
Oracle D (anti-false-clean, net-new): under both Oracle A's and Oracle B's shims, the output must
  NOT contain '✓ Telegram plugin patches' — in particular not '0/0 groups present'. Written in the
  run-and-count shape, never as a plain intermediate grep:
    run bash -c "printf '%s' \"$doctor_out\" | grep -cF '✓ Telegram plugin patches'"
    [ "$output" = "0" ]
Oracle C: the warn counter must not move — assert the run's trailing summary is unchanged
  relative to a baseline run with the check skipped for channel!=telegram.
```

### C13 — Anti-drift: no marker literal and no version literal in `agentctl`

`scripts/agentctl` MUST NOT contain any marker string, any fragment of one, or any version token
belonging to a patch group. This is the structural half of FR-015: the check stops being a *copy* of
the patcher's knowledge and becomes a *consumer* of it.

```bash
# Oracle A — marker strings and group-name fragments
run bash -c "LC_ALL=C grep -nE \
  'agentic-pod-launcher:|typing refresh|offset persistence|stderr-capture|primary lock|pending-reply marker|askq-guard give-up|voice roundtrip' \
  '$REPO_ROOT/scripts/agentctl'"
[ "$status" -eq 1 ]

# Oracle B — version tokens attached to a group name
run bash -c "LC_ALL=C grep -nE '(patch|typing|offset|stderr|primary|pending|askq|voice) v[0-9]' \
  '$REPO_ROOT/scripts/agentctl'"
[ "$status" -eq 1 ]
```

**Both oracles were executed against the current tree and are RED in exactly the intended places, with
no false positives:** Oracle A matches `:529 :530 :531 :532`; Oracle B matches those four plus `:534`
(`_doctor_pass "Telegram plugin patches: typing v3, offset v1, stderr v1, primary v1"`). Oracle B is
deliberately anchored to a group name rather than a bare `v[0-9]`: an unanchored pattern also matches
the unrelated `:42` comment about vendoring a yq `v4` binary.

### C14 — The file set: the patcher's glob, not `head -1`

The check MUST evaluate **every** file matched by
`/home/agent/.claude/plugins/cache/claude-plugins-official/telegram/*/server.ts`, the same glob
`_hook_telegram_typing_patch` walks (§0.4). The `| head -1` of `:526` MUST go.

Semantics: the result is the **conjunction** over files. A pass requires all markers present in all
files; a single incomplete file produces CANON-D2 naming that file's version directory. The file set
is enumerated once, in the container, with `ls -d … 2>/dev/null` (no `head`), and iterated host-side
with `while IFS= read -r f`.

**Edge case — two version directories in the cache.** A plugin upgrade leaves the previous version
directory behind; the boot patcher patches both, so a cache holding `2.4.0/server.ts` (patched) and
`2.5.0/server.ts` (unpatched, e.g. the hook never ran after the upgrade) is a genuinely degraded
agent. Today's `head -1` returns whichever `ls` sorts first and reports on that one alone, so the
answer depends on directory naming rather than on state.

```text
Oracle (net-new): shim exposes TWO version dirs; the first in ls order is fully patched, the
second is missing one group.
  Expect: '⚠ Telegram plugin patches incomplete in <second-verdir>' in the output.
  Expect NOT: '✓ Telegram plugin patches'.
Mutation check: reinstating `| head -1` must turn this test red (and only this one) — that is
the discriminating oracle for FR-016.
```

### C15 — DOCKER_E2E (gated, additive)

US4 is fully host-testable and adds no DOCKER_E2E requirement of its own (unlike US1/US3, FR-019).
One cheap real-image assertion is nonetheless added to the existing gated tier, because the patcher
is image-baked and the host tests never execute the copy that ships:

```text
Oracle (DOCKER_E2E=1): inside the built image,
  python3 /opt/agent-admin/scripts/apply_telegram_typing_patch.py --list-markers
must print 7 lines, all matching '^agentic-pod-launcher: ', and exit 0.
```

---

## Part C — documentation correction (FR-017)

### C16 — `docs/creating-an-agent.md:452-460` is wrong on both the cause and the remedy

Current text, verbatim:

````markdown
### `agentctl doctor` says the typing patch is "incomplete"

Known false-negative: `doctor`'s integer parse of the typing-tick count misreports the
Telegram typing patch as incomplete even when the `v4` marker is present. Confirm the
patch is applied and ignore the warning:

```bash
docker exec john-doe grep -c "typing refresh patch v4" \
  /home/agent/.claude/plugins/cache/claude-plugins-official/telegram/*/server.ts
```
````

What it asserts, and why each assertion is false today:

| Claim in the doc | Status | Evidence |
| --- | --- | --- |
| "`doctor`'s integer parse of the **typing-tick count**" | **False.** There is no tick count in the check. The parsed value is a `grep -c` **marker count**, and it breaks because of `\|\| echo 0`, not because of anything to do with typing ticks | `scripts/agentctl:529-533`; measurement in C8 |
| "even when the **`v4`** marker is present" | **False / stale.** The live marker is **v6**; a file at v4 is a file the boot cascade has not upgraded yet | `apply_telegram_typing_patch.py:106`, `MARKER_TYPING = "… typing refresh patch v6"`; cascade `:2050-2055` |
| the remedy `grep -c "typing refresh patch v4"` | **False.** On a correctly patched file this command prints `0` and exits 1, so the doc's own verification hands the operator the opposite of the truth | measured: on a freshly patched pristine fixture, `typing refresh patch v6` → 1, `… v4` → 0 |
| "ignore the warning" | **Obsolete after this feature.** Once C7-C14 land the warning is real; telling operators to ignore it would suppress the signal SC-006 exists to produce | — |

Required correction: replace the section with one that (a) states the false negative was fixed in
this release, (b) gives a version-free verification command, and (c) says that a warning now means a
real missing group. The replacement verification command must not name a version:

```bash
docker exec -u agent john-doe sh -c \
  'python3 /opt/agent-admin/scripts/apply_telegram_typing_patch.py --list-markers |
   while IFS= read -r m; do
     printf "%s: " "$m"
     grep -c -F -- "$m" /home/agent/.claude/plugins/cache/claude-plugins-official/telegram/*/server.ts
   done'
```

```text
Oracle: run bash -c "LC_ALL=C grep -nE 'typing refresh patch v[0-9]|typing-tick count' docs/creating-an-agent.md"
        [ "$status" -eq 1 ]
RED today: matches :454 (typing-tick count) and :459 (typing refresh patch v4).
```

### C17 — `docs/state-layout.md:199` is wrong on the group list, the count and the version

Current text, verbatim (single line):

```markdown
The Telegram plugin's `server.ts` is the file the boot-time post-install hook edits (`docker/scripts/apply_telegram_typing_patch.py`): typing refresh, offset persistence, stderr capture, primary lock. Each group is guarded by a marker comment and is idempotent. On a fully patched file, `grep -c "agentic-pod-launcher:" server.ts` returns **9** (2 typing — the group marker plus the inline `_typingStop` call — + 4 offset hunks + 2 primary + 1 stderr). Treat exact-count greps as fragile: the typing marker is versioned (currently v4) and the patcher runs a `v1 → v4` upgrade cascade on every boot.
```

What it asserts, and why each assertion is false today:

| Claim in the doc | Status | Evidence |
| --- | --- | --- |
| the hook edits four groups: "typing refresh, offset persistence, stderr capture, primary lock" | **False.** There are **seven**: the four listed plus pending-reply marker (028), askq-guard give-up delivery (031) and telegram voice roundtrip (032→034) | `ALL_MARKERS`, `apply_telegram_typing_patch.py:124-132` |
| `grep -c "agentic-pod-launcher:"` returns **9** | **False.** Measured **19** on a pristine fixture run through today's patcher | `python3 docker/scripts/apply_telegram_typing_patch.py <pristine copy>`, then `grep -c` |
| the breakdown "2 typing + 4 offset + 2 primary + 1 stderr" | **False in its typing term and incomplete.** Measured per-group occurrence counts of the marker strings: typing v6 **1**, offset v1 **4**, stderr v1 **1**, primary v1 **2**, pending-reply v1 **3**, askq-giveup v1 **1**, voice v3 **1** = 13; the remaining 6 of the 19 are other `agentic-pod-launcher:`-prefixed comment lines that are not marker strings | same run as above |
| "currently v4" and "a `v1 → v4` upgrade cascade" | **False / stale.** The typing cascade is `v1 → v2 → v3 → v4 → v5 → v6` (`:2050-2054`) and the current marker is v6; there is additionally a voice cascade `v1 → v2 → v3` (`:2071-2072`) the sentence does not mention | `apply_telegram_typing_patch.py:106`, `:2042-2055`, `:2071-2073` |

Required correction: name all seven groups, drop the hardcoded total, and replace "treat exact-count
greps as fragile" with a pointer to `--list-markers` as the supported, version-free way to enumerate
them.

```text
Oracle: run bash -c "LC_ALL=C grep -nE 'returns \*\*9\*\*|currently v4|v1 → v4' docs/state-layout.md"
        [ "$status" -eq 1 ]
RED today: matches :199 on all three.
```

---

## Summary of oracles by requirement

| Requirement | Clauses | Oracle tier |
| --- | --- | --- |
| FR-014 (no `grep -c \|\| echo 0`, no shell error) | C8, C9, C10 | host bats (net-new) + static grep |
| FR-015 (single source for the marker set) | C1-C7, C12, C13 | host bats (net-new) + static grep + patcher unit tests |
| FR-015 (old image ⇒ skipped, never a silent clean pass) | C12 (Oracles A, B, D) | host bats with an old-patcher shim; content-based, never status-based |
| FR-016 (same file set as the boot patcher) | C14 | host bats (net-new) |
| FR-017 (documentation) | C16, C17 | static grep |
| SC-005 | C10, C11 | host bats (check-12 lines) + live gate for the process exit code |
| SC-006 | C11, C14 | host bats |
| SC-008 (mutation) | C9, C14 | recorded in `quickstart.md` |

## Notes for the implementer

- The new bats file is `tests/agentctl-doctor-telegram-patches.bats` (plan, Project Structure). Its
  `setup()` follows `tests/agentctl-doctor-claude-oauth.bats:11-35` — an `agent.yml` with
  `notifications.channel: telegram`, a `docker` shim on `PATH`, `AGENT_NAME=testagent`. The
  parameterised-shim idiom of `tests/agentctl.bats:163-177` (`_install_docker_shim`, env-var knobs
  interpolated into a **non**-quoted heredoc while `$1`/`$@` stay escaped) is the mould for driving
  the several shim shapes C9/C12/C14 need from one helper.
- The shim must distinguish the three `docker exec` payloads the check issues: the `ls -d` file
  enumeration, the `--list-markers` probe, and the per-marker `grep`. Dispatch on the whole argument
  string (`case "$*" in *--list-markers*) … ;; *"ls -d"*) … ;; *grep*) … ;; esac`), because the check
  passes markers containing spaces and positional dispatch would misread them.
- `agentctl` runs under `set -u`: initialise every new local before first read, and keep
  `local` declarations separate from the command substitution that fills them when the rc matters
  (`local x=$(cmd)` swallows `cmd`'s status).
- All seven markers are pure ASCII. Nothing in this contract requires a non-ASCII byte beyond the
  `✓ ⚠ ⊝ →` glyphs quoted verbatim from `scripts/agentctl:108-119`; no combining marks appear
  anywhere in this file (audited: `LC_ALL=C grep -c $'\xcc\x80'` = 0).
