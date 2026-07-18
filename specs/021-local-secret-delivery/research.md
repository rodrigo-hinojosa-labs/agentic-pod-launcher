# Research: Secret delivery in local mode (021)

Phase 0. Produced by workflow `wf_7f4e37a8-1f4`: 6 parallel researchers + 1
adversarial synthesis agent, 313 tool calls, 0 errors (2026-07-13). Every claim
below is anchored in the systemd/compose **source or man page**, the Claude Code
docs, or this repo at `file:line`. Where a researcher could not verify something,
it is marked and carried into the hardware gate.

## R0 — The decision, in one block

**Mechanism: Design A′ — `EnvironmentFile=-<workspace>/.env` on the session unit,
listed FIRST.**

```ini
# modules/systemd-remote-control.service.tpl, [Service]
EnvironmentFile=-{{DEPLOYMENT_WORKSPACE}}/.env                      # NEW, first
EnvironmentFile={{DEPLOYMENT_WORKSPACE}}/.state/remote-control.env  # unchanged, now second
```

Three load-bearing properties, each verified at the systemd source:

1. **Order: the LATER file wins.** `.env` goes **first** so the launcher-pinned
   `PATH` / `HOME` / `CLAUDE_CONFIG_DIR` in `remote-control.env` always beat an
   operator line in `.env`. Without a correct `PATH` every MCP spawn `ENOENT`s —
   this is the historical `203/EXEC` failure (`remote-control.env.tpl:9-13`).
   The relative order gets its own numeric assertion in the tests; a comment is
   not enough.
2. **The `-` prefix is mandatory.** A missing, unreadable, or invalid `.env`
   becomes a silent no-op instead of a unit start failure. This is what makes
   **FR-004 ("never a hard failure") enforced by systemd itself**, not by our
   code.
3. **One line closes the whole MCP gap.** Claude Code expands `${VAR}` in
   `.mcp.json` from **its own process environment** and spawns the MCP servers
   itself. Give the session the env and every catalog MCP is fixed. Docker is
   untouched.

**Rejected — Design B (a wrapper script as `ExecStart`, "no sudo needed") and the
variant "inject the secrets into `.state/remote-control.env`".** The variant is an
**FR-004 violation**: `remote-control.env` is loaded **without** `-`, so a single
un-re-quotable value (a single quote, a newline, a control character, a non-UTF-8
byte) turns "agent runs without secrets" into "agent will not start" —
with `Restart=always` + `StartLimitBurst`, into `failed`. It also duplicates every
secret into a second file and forces us to reimplement systemd's quoting grammar
in bash. And its one selling point is **illusory**: systemd reads `EnvironmentFile`
at process **spawn**, so *any* mechanism needs
`sudo systemctl restart agent-<name>` on a live agent. A wrapper-as-`ExecStart`
rewrites the unit too — also a root write. We pay one extra `sudo cp` and get
systemd's own parser, its fail-open, and zero secret duplication.

## R1 — Parsing parity: systemd vs docker compose

**Decision**: every shape the wizard writes today parses **identically** in both.
The divergences are all reachable only by hand-editing — but hand-editing is the
**normal path**, not an edge case (`CLAUDE_CODE_OAUTH_TOKEN` is always written
empty; every secret prompt says "Press Enter to skip — fill it in `.env` later",
`setup.sh:731,760,790`). So we ship a linter, not a parser.

**What the wizard emits** (`setup.sh:1210-1232`): `#` comments at column 0, blank
lines, `KEY=` with an empty value, `KEY=<raw token>` unquoted, the 5-line Atlassian
block, and the GitHub/catalog secrets. **Nothing is ever quoted, no line is ever
continued.**

**Shapes that AGREE** (parity holds — this is every shape the wizard writes):
`#` comment at col 0; blank line; `KEY=` (empty in both); `KEY=token`; trailing
space (both right-trim); interior spaces (both preserve); a value containing `=`
(base64/JWT padding — both split on the **first** `=`); a value containing `:`
(a Telegram bot token — the `=` comes first, so the key survives in both); an
Atlassian URL with `#fragment` and no preceding space; CRLF.

**Shapes that BREAK parity** (same line, different value in the two modes):

| Line | docker compose | systemd |
|---|---|---|
| `KEY=abc\` (trailing backslash) | value `abc\` | **line-continues and swallows the next `KEY=VAL`** — two secrets silently lost |
| `KEY=a\b` | `a\b` | `ab` |
| `KEY=val # note` | `val` (inline comment stripped) | `val # note` |
| `KEY=a$B` | interpolated | literal `$` |
| `KEY="a\nb"` | a real newline | literal `a\nb` |
| `export KEY=v` | sets `KEY` | invalid name `export KEY` → **dropped, and the full `KEY=VALUE` logged to the journal at ERROR** |
| `KEY: v` | sets `KEY` | line ignored |
| bare `KEY` (no `=`) | inherits from the host env | ignored |
| `;`-prefixed line | **hard parse failure** | ignored as a comment |

Sources: systemd `man/systemd.exec.xml:3255-3299` and `src/basic/env-file.c:66-192`
(the `#`-is-not-special-inside-a-value state machine, the trailing-whitespace
chomp, the backslash continuation); compose-spec `05-services.md:626-655` and
`compose-go/dotenv/parser.go:101-204`.

**systemd does NOT expand `$VAR` in an `EnvironmentFile` value**: the unit path
calls `load_env_file()` (plain parse), not `merge_env_file()` (`execute.c:1015`
vs `env-file.c:584`). `$` is a literal.

**`--regenerate` never rewrites `.env`** (`setup.sh:2187-2189` renders only
`.env.example`), so the launcher cannot retroactively normalize an existing
workspace. The linter has to *report*; the operator fixes.

## R2 — Exposure surface (FR-006 / SC-006)

**Decision**: `EnvironmentFile` **meets** SC-006 as-is. It is strictly better than
the docker baseline the project already accepts.

- `systemctl show <unit>` prints **only the file PATHS**, never the contents
  (`EnvironmentFiles` is exported as `a(sb)` = path + ignore-flag; the values live
  only in the per-invocation `ExecParameters.files_env`, `execute.c:1015/1029`).
- The **docker baseline is worse**: `docker inspect` and `docker compose config`
  print the values in cleartext to any member of the `docker` group (verified
  empirically with a canary container).
- The env is readable at `/proc/<pid>/environ` — by the owner and by root. Same in
  both modes.

**Two residuals, both accepted and documented:**

1. **Journal credential leak via an invalid variable NAME.** systemd drops the
   assignment *and logs the full `KEY=VALUE` at ERROR* (`execute.c:944-948`). The
   `-` prefix does **not** suppress it. Two live triggers exist **today**:
   `export FOO=...` pasted from a provider's docs, and **the wizard's own dashed
   Atlassian alias** (see R5). This is why the alias sanitization is not optional.
2. **Coredump residual.** If the host pipes `core_pattern` to `systemd-coredump`, a
   crash of `claude` or an MCP child journals `COREDUMP_ENVIRON` — the whole
   environment in cleartext. `LimitCORE=0` stops the core *file*, not the journal
   metadata (`RLIMIT_CORE` is ignored for a piped `core_pattern`). Inherent to env
   delivery; docker shares it via the host's global `core_pattern`. Check it on
   mclaren and document as accepted.

**Do NOT use `Environment=`** — it is the one mechanism systemd's own man page
calls unsafe (the values are exported over D-Bus).

## R3 — Code seams

| Seam | Today | Change |
|---|---|---|
| Session unit | `modules/systemd-remote-control.service.tpl:12` — one `EnvironmentFile`, no `ExecStartPre` | add the `.env` line **before** it; add `ExecStartPre=-` for the boot warn |
| MCP expansion | `modules/mcp-json.tpl` uses bare `${VAR}`; Claude Code expands from its own env | see R4 — must become `${VAR:-}` |
| Healthcheck | `modules/local-healthcheck.sh.tpl:100` does **`. "$NOTIFY_ENV"`** — it *sources* the file | replace with a **parser**; add the `.env` fallback |
| Healthcheck unit | `modules/local-healthcheck.service.tpl` — `User=`, no `EnvironmentFile` | **unchanged** (the five timers keep zero secret exposure) |
| Doctor | `scripts/agentctl:1131-1187` `cmd_local_doctor` — **no `.env` check at all** (the `0600` check exists only on the docker path, `:430-443`) | new `_local_secrets_doctor`, WARN-only, after `_local_vault_qmd_doctor` |

**The `source` is a live RCE.** `.env` can arrive from a **remote** source:
`--restore-from-fork` decrypts `.env.age` into the workspace `.env`
(`setup.sh:1648-1667`). So `. "$NOTIFY_ENV"` executes attacker-controlled content
as the operator, every 5 minutes. The replacement must **parse, never source** —
no `.`, no `eval`, no `export`. The existing `curl -s --config -` pattern (the
token goes in on stdin, never on argv, never in the journal) is real and already
test-pinned (`tests/local-healthcheck.bats:181-186`) — keep it exactly.

**The doctor's required-set must come from `agent.yml` + the MCP catalog**
(`requires_secret` / `secret_env_var` in `modules/mcps/*.yml`), **not** from
grepping the rendered `.mcp.json`. Grepping produces **permanent false positives**
on every AWS agent: `mcp-json.tpl:41-42` references `AWS_PROFILE`/`AWS_REGION`, but
`modules/mcps/aws.yml` declares `requires_secret: false` and the wizard never
writes them to `.env`. The catalog **does** ship into local workspaces
(`setup.sh:1805-1809` — only `docker` is skipped in local mode).

## R4 — `${VAR}` vs `${VAR:-}` — the scare, and what the hardware actually said

**The claim** (<https://code.claude.com/docs/en/mcp>, "Environment variable
expansion in `.mcp.json`"): *"If a required environment variable isn't set and has
no default value, Claude Code fails to parse the config."* `modules/mcp-json.tpl`
uses **bare `${VAR}`** everywhere (`:27,41-42,53-58,65`). Taken literally, local
mode would be running with **no MCPs at all** — the whole config dead, taking
`fetch`, `git`, `filesystem`, `vault` and `qmd` down with the secret-bearing ones.

**MEASURED ON THE LIVE HOST (mclaren, 2026-07-13) — the doc overstates it.**
Reproducing the unit's exact condition (all six `${VAR}` refs explicitly unset,
`CLAUDE_CONFIG_DIR` pointed at the workspace, Claude Code 2.1.185):

```
$ env -u GITHUB_PAT -u ATLASSIAN_MCLAREN_* claude mcp list
fetch: …          git: …            filesystem: …      atlassian-mclaren: …
github: …         vault: …          qmd: …
```

**All 7 workspace MCPs enumerate.** The config parses. The `${VAR}` refs do not
kill it. So: **`${VAR:-}` is PRUDENT, not BLOCKING** — it is defence in depth
against a future Claude Code that enforces the documented behavior, and it is
free. It stays in scope, but it does **not** gate the feature and it does **not**
turn 021 into an emergency.

*(The "Failed to connect" statuses in that run are an artifact of the ssh shell's
`PATH` lacking `uvx`/`npx`, not of the missing secrets. Do not read them as
evidence.)*

**WHAT THE LIVE HOST DID CONFIRM — the bug itself, on production hardware:**

```
$ tr '\0' '\n' < /proc/$(systemctl show -p MainPID --value agent-mclaren-admin.service)/environ \
    | grep -cE '^(GITHUB_PAT|ATLASSIAN_MCLAREN_TOKEN)='
0
```

The running agent's environment contains **zero** of its secrets. `.mcp.json`
references six variables; the session has none of them. The `github` and
`atlassian-mclaren` MCPs are live, declared, and credential-less. This is no
longer a code-reading inference — it is measured.

## R5 — Two pre-existing defects that 021 would newly EXPOSE

Both must ship **with** 021, or 021 ships a mode-dependent silent failure and a
credential leak on day one.

1. **The Atlassian alias is unvalidated.** `setup.sh:753` collects it with
   `ask_required` (no charset validator) and merely uppercases it into
   `ATLASSIAN_<ALIAS>_TOKEN`. An alias like `cenco-corp` yields
   `ATLASSIAN_CENCO-CORP_TOKEN` — a **legal** compose key but an **invalid systemd
   name**. In local mode the **entire Atlassian credential set is silently
   dropped**, *and* the token is printed verbatim into the journal (R2 residual 1).
   Fix: sanitize the alias to `[A-Za-z0-9_]` at collection, and mirror the
   normalization into `render.sh`'s `{{NAME}}` for `mcp-json.tpl`.
2. **`mcp-json.tpl` must emit `${VAR:-}`** (R4).

## R6 — Upgrade path for the live agent (mclaren)

**Verified facts** (`setup.sh:2263-2265`, `:2380-2390`):

- `--regenerate` re-renders the unit **only when `deployment.install_service: true`**,
  and installs it **only when `sudo -n` succeeds**. Otherwise it silently stages
  `agent-<name>.service` into the workspace and **exits 0**.
- **Nothing in `setup.sh` ever restarts the unit.** And `EnvironmentFile` is read at
  **spawn**.
- `./setup.sh --login` is **not** an upgrade path — it refuses to overwrite an
  existing unit (`local-login.sh.tpl:98`).

**Therefore the dangerous failure mode is a silent no-op**: an operator who stops
at `--regenerate` gets a perfect workspace and an agent still running the old,
secretless environment — and a doctor that only inspects `.env` would call it
**green**. So the doctor must also inspect the **installed unit**, and (where
possible) the live `MainPID`'s `/proc/<pid>/environ` — *presence only, never the
value*.

**The command sequence** (verified, not invented; goes in `quickstart.md`):

```bash
./setup.sh --regenerate
sudo cp ./agent-<name>.service /etc/systemd/system/   # ONLY if regenerate said "staged (sudo unavailable)"
sudo systemctl daemon-reload
sudo systemctl restart agent-<name>.service           # MANDATORY — nothing restarts it for you
./scripts/agentctl doctor
```

## R7 — Test strategy under Principle III (no systemd, no Docker on the host)

**Host-testable** (the seams already exist —`tests/local-render.bats:8-56,93-96`,
`tests/local-healthcheck.bats:27-70`, `tests/agentctl-local.bats:236-242`):

- the rendered unit carries the directive, with the `-` prefix, **before**
  `remote-control.env` (a numeric line-order assertion);
- the healthcheck reads the right value, prefers the legacy file when present, and
  **never sources** (a `curl` stub that dumps stdin + a canary in the fixture);
- the doctor WARNs (exit 1) on a missing secret and stays **silent** on a
  correctly configured agent (SC/US3 forbids crying wolf);
- `env_file_lint` against a nasty-shapes fixture (the R1 divergence table);
- docker's rendered artifacts are **unchanged**.

**Not host-testable**: systemd actually parsing the file and injecting the env; a
real MCP receiving the value. → the **mclaren hardware gate** below.

**`install_service` has ZERO test coverage today.** Recommended seam:
`SETUP_SYSTEMD_DIR="${SETUP_SYSTEMD_DIR:-/etc/systemd/system}"` (mirroring the
existing `LOGIN_SYSTEMD_DIR` pattern), so "the *installed* unit carries the
directive" is provable — and so a test on a dev Mac with a cached sudo timestamp
can never `sudo cp` into the tester's `/etc`.

**Bats hazard (verified empirically, matches project memory)**: a mid-body `[[ ]]`,
any `!`-negated command, and `POS && ! NEG` chains **do not fail a test**. The
negatives this feature needs are exactly that shape. Write them last-line, or
`run grep` + `[ "$status" -ne 0 ]`, or add a `refute_grep` helper. Dead assertions
already exist in the suite at `tests/agentctl-local.bats:94-95,204,268`. Run a real
RED phase plus a mutation spot-check, as 019 did.

## R8 — The backup trap

`backup_identity` **already** hashes and age-encrypts a file at
`<workspace>/.state/.env` — a path that does not exist today
(`docker/scripts/lib/backup_identity.sh:72,152-154`). **Any design that creates a
file literally named `.env` under `.state/` silently starts pushing secret material
to the fork's `backup/identity` branch.** Do not create one. (This is why the
rejected "inject into `.state/remote-control.env`" design was doubly wrong.)

## Confidence and the hardware gate

| Area | Confidence | To raise it |
|---|---|---|
| R1 parsing (systemd side) | **HIGH** — man source read directly | — |
| R1 parsing (compose side) | MEDIUM | run 4 shapes through `docker compose config` |
| R2 exposure | MEDIUM-HIGH | one `systemctl show` on mclaren |
| R3 code seams | **HIGH** — every file re-read | — |
| R4 `${VAR}` fail-parse | **HIGH — settled on hardware** | measured on mclaren: the config parses, all 7 MCPs enumerate. `${VAR:-}` demoted to prudent |
| The bug itself | **HIGH — measured on hardware** | mclaren's live session env holds **0** of its 6 declared secrets |
| R6 upgrade path (facts) | **HIGH** | — |
| R7 testability | **HIGH** | — |

**Hardware gate (mclaren — cannot be run on the macOS host; goes in
`quickstart.md`):**

1. `systemctl show agent-<name>.service -p EnvironmentFiles` lists **both** files,
   `.env` with the ignore flag.
2. `/proc/<MainPID>/environ` contains the secret — **count only, never print**.
3. One catalog MCP actually authenticates from the live session.
4. A deliberately blanked key → `agentctl doctor` exits 1 naming the variable and
   the file, **and the agent still boots**.
5. A deliberately corrupted `.env` (BOM / trailing backslash) → **the agent still
   boots** (FR-004) and the `ExecStartPre` WARN appears in `journalctl`.
6. `systemctl show -p Environment` shows **no** secret values.
7. `cat /proc/sys/kernel/core_pattern` — record the coredump residual.
8. ~~Does an unset `${VAR}` break `.mcp.json` parsing?~~ **SETTLED 2026-07-13 on
   mclaren: no. All 7 MCPs enumerate with every `${VAR}` unset.** (R4.)

**Fallbacks if the gate fails**: if systemd rejects the real `.env` wholesale
(encoding/shape), do **not** abandon the mechanism — make `env_file_lint` a loud
doctor WARN and have the wizard **single-quote** every value it writes (single
quotes are the one form systemd and compose interpret identically and literally);
existing workspaces are fixed by hand, since `--regenerate` never rewrites `.env`.
If Claude Code fail-parses on a set-but-empty `${VAR}`, `${VAR:-}` in
`mcp-json.tpl` becomes **mandatory and blocking**.

**Worth 5 seconds each before rollout**: does mclaren's `agent.yml` have
`deployment.install_service: true`? Does its live `.env` already contain a
non-portable line? Does any live agent use an Atlassian alias containing a dash
(if so, **its token leaks into the journal the moment the new unit starts**)? Does
`.state/healthcheck-notify.env` exist anywhere in the wild (nothing in the launcher
has ever created it)?
