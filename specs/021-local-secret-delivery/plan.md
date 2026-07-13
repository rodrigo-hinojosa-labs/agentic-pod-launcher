# Implementation Plan: Secret delivery in local mode

**Branch**: `021-local-secret-delivery` | **Date**: 2026-07-13 | **Spec**: [spec.md](spec.md)

**Input**: [spec.md](spec.md) (3 clarifications resolved) + [research.md](research.md)
(Phase 0: 6 researchers + adversarial synthesis, `wf_7f4e37a8-1f4`; plus a live
measurement on the mclaren host).

## Summary

The wizard writes every secret to `<workspace>/.env` (`0600`). Docker delivers them
(`env_file`). **Local mode delivers nothing** — measured, not inferred: the running
agent on mclaren has **zero** of its six declared secrets in its environment.

The fix is one systemd directive plus three supporting pieces:

1. **`EnvironmentFile=-<workspace>/.env` on the session unit, listed FIRST** (before
   the existing `remote-control.env`, because the **later** file wins and the
   launcher-pinned `PATH`/`HOME`/`CLAUDE_CONFIG_DIR` must always beat an operator
   line). The `-` prefix makes a missing/invalid `.env` a **silent no-op** — that is
   FR-004 enforced by systemd itself, not by our code. Claude Code expands `${VAR}`
   in `.mcp.json` from its own process env and spawns the MCP servers, so this one
   line closes the entire catalog-secret gap.
2. **The healthcheck stops `source`-ing and starts parsing.** Today it does
   `. "$NOTIFY_ENV"` — and `.env` can arrive from a *remote* source
   (`--restore-from-fork` decrypts `.env.age` into it), so that is remote code
   execution as the operator every five minutes. New reader: allowlisted keys only,
   no `.`, no `eval`. Legacy `.state/healthcheck-notify.env` wins when present
   (compatibility override); otherwise the values come from `.env`.
3. **A doctor check + a boot warning** so a missing secret is never silent again —
   WARN only, never a hard failure.
4. **A linter for the portable `.env` subset** (systemd ∩ compose), because the two
   parsers diverge on shapes an operator can easily hand-write, and hand-editing
   `.env` is the *normal* path (the wizard always leaves `CLAUDE_CODE_OAUTH_TOKEN`
   empty and every secret prompt offers "fill it in `.env` later").

Docker is untouched. The host suite must stay at 977 green.

## Technical Context

**Language/Version**: POSIX-ish `bash` (host launcher + rendered workspace scripts);
systemd unit files; no new runtime dependency.

**Primary Dependencies**: systemd (`EnvironmentFile=`, `ExecStartPre=`), the repo's
own `render.sh` template engine, `agentctl`, the MCP catalog descriptors
(`modules/mcps/*.yml`).

**Storage**: `<workspace>/.env` (`0600`, operator-owned, never committed) stays the
one and only secrets file. **No new file may be named `.env` under `.state/`** —
`backup_identity.sh:72,152-154` already age-encrypts such a path and would start
pushing secrets to the fork's `backup/identity` branch.

**Testing**: `bats tests/` on the host — **no Docker, no systemd** (Principle III).
Everything systemd-side is proven by asserting on the *rendered* unit; the runtime
behavior is proven on the mclaren hardware gate.

**Target Platform**: local mode = Linux + systemd (the operator's own user). Docker
mode unchanged.

**Project Type**: bash launcher/CLI + templates.

**Constraints**: docker↔local parity for the same `.env` (FR-003); a malformed or
hostile `.env` must never prevent boot (FR-004); no secret value in the journal,
`systemctl` output, doctor output, or any file looser than `0600` (FR-006); must
survive `--regenerate` (FR-012).

**Scale/Scope**: 2 secret consumers (session unit + healthcheck alert path). The 4
timers (qmd-reindex, qmd-watch, vault-backup, wiki-graph) get **nothing** — least
privilege, and a decision the user made explicitly.

## Constitution Check

*GATE: passed before Phase 0; re-checked after Phase 1 design. Source: `.specify/memory/constitution.md` v1.0.0.*

- [x] **I. Single Source of Truth** — every artifact is rendered from `agent.yml` via
  `render.sh` (the unit template, the new `agent-secret-check.sh`, `mcp-json.tpl`).
  Nothing hand-edited. `--regenerate` re-emits all of it. **One caveat made explicit
  in the design**: `--regenerate` re-installs the *root-owned* unit only when
  `deployment.install_service: true` **and** `sudo -n` succeeds; otherwise it stages
  the file and exits 0. That is pre-existing behavior, but it means a regenerate can
  leave the *installed* unit stale — so the doctor must inspect the installed unit,
  not just the workspace. Covered by T-DOCTOR-2.
- [x] **II. Least-Privilege (NON-NEGOTIABLE)** — **N/A to docker** (nothing under
  `docker/` changes; no capability, mount, or socket touched). The *spirit* is
  honored on the local side: only the two consumers that need secrets get them; the
  four timers stay secret-free.
- [x] **III. Test-First, Host-Runnable** — every deliverable has a host-side bats
  assertion (rendered-unit content and line ORDER, the healthcheck's reader and its
  legacy precedence, the never-sources proof, the doctor's WARN and its silence on a
  clean agent, the linter against a nasty-shapes fixture, and a docker-unchanged
  guard). New lib guards its init with `BASH_SOURCE`. `shellcheck -S error` clean.
  **Known trap**: this suite silently passes mid-body `[[ ]]` and `!`-negated
  pipelines — the negatives here are exactly that shape, so they use `run grep` +
  `[ "$status" -ne 0 ]` or land last. A real RED phase + a mutation spot-check is a
  task, not an afterthought (the 019 lesson).
- [x] **IV. Idempotent, Fail-Silent Lifecycle** — the `-` prefix on both
  `EnvironmentFile` and `ExecStartPre` means a missing/invalid `.env` and a failing
  secret-check are **no-ops**, never a failed unit. Re-running `--regenerate` is
  idempotent. **The constitution's fail-silent principle is not amended**: the
  *lifecycle* stays silent-and-degrading; what becomes loud is the *diagnosis*
  (doctor + a boot WARN). Fail-silent was always about not letting a degraded
  subsystem take the agent down — never about hiding the degradation from the
  operator.
- [x] **V. Workspace-Is-the-Agent** — `.env` stays in the workspace root, `0600`,
  gitignored, never logged. No new file under `.state/`. The three backup primitives
  are untouched, and the `.state/.env` landmine is explicitly avoided.
- [x] **VI. Reproducible, Pinned Dependencies** — no version pins touched.
  `CHANGELOG.md` + `VERSION` bump on merge (user-facing change).

**Result: 6/6 PASS. No violations to justify.**

## Design

### D1 — The session unit (`modules/systemd-remote-control.service.tpl`)

```ini
[Service]
EnvironmentFile=-{{DEPLOYMENT_WORKSPACE}}/.env                      # NEW — first
EnvironmentFile={{DEPLOYMENT_WORKSPACE}}/.state/remote-control.env  # unchanged — second, wins
ExecStartPre=-{{DEPLOYMENT_WORKSPACE}}/scripts/local/agent-secret-check.sh   # NEW
```

Three properties, each with its own test:

- **Order is load-bearing, not cosmetic.** Later wins → a stray `PATH=` in `.env`
  can never clobber the launcher's. Asserted by comparing *line numbers*, not by a
  comment.
- **Both new directives carry `-`.** Missing/unreadable/invalid `.env` → ignored.
  A failing `ExecStartPre` → ignored (without the `-`, systemd marks the unit
  **failed**).
- **The four timers get no `EnvironmentFile`.** Asserted negatively.

### D2 — `scripts/lib/env_file.sh` (new shared lib; **not** mirrored to `docker/`)

- `env_file_get KEY FILE` — allowlisted reader. Pure parameter expansion
  (`case "$line" in KEY=*) v=${line#*=};; esac`), last match wins, strips one layer
  of matching surrounding quotes. **No `.`, no `eval`, no `export`, no subshell of
  file content.** This is the anti-RCE primitive.
- `env_file_lint FILE` — validates against the **portable subset** (systemd ∩
  compose): blank | `^#…` | `^[A-Za-z_][A-Za-z0-9_]*=` whose value carries no
  backslash, no `$`, no ` #`, no leading quote, no CR; the file must be valid UTF-8,
  no NUL, no BOM. Reports **line + key + reason — never a value.**

  The linter is not decoration. It is the only guard against three *silent* modes:
  a **trailing backslash** makes systemd swallow the *next* assignment (two secrets
  lost); an **invalid variable name** (e.g. a pasted `export FOO=…`) makes systemd
  drop the line **and log the full `KEY=VALUE` at ERROR into the journal** — a real
  credential leak the `-` prefix does not suppress; a **BOM or a non-UTF-8 byte**
  makes systemd discard the **entire file**, silently, precisely *because* of the
  `-`. The agent then boots looking perfectly healthy with zero secrets.

### D3 — The healthcheck (`modules/local-healthcheck.sh.tpl`)

Replace `. "$NOTIFY_ENV"` (line 100) with:

```
SRC = .state/healthcheck-notify.env  if readable   (LEGACY OVERRIDE — wins; never created by a fresh scaffold)
    = <workspace>/.env               otherwise
NOTIFY_BOT_TOKEN / NOTIFY_CHAT_ID  <- env_file_get, nothing else
```

Its unit gains **no** `EnvironmentFile` (`User=` already lets it read a `0600`
operator-owned file). `curl -s --config -` stays exactly as it is — the token goes
in on stdin, never on argv, never in the journal, and that is already test-pinned.

### D4 — The doctor (`scripts/agentctl`, new `_local_secrets_doctor`)

Called right after `_local_vault_qmd_doctor`. **WARN (exit 1) only, never `_doctor_fail`.**

1. `.env` exists, mode `0600`, owned by the operator (the docker path has this check
   at `:430-443`; **local has none at all** today).
2. `env_file_lint` findings — line + key + reason, never a value.
3. **The installed unit actually carries the directive** (catches the silent no-op
   where an operator ran `--regenerate` but never `sudo cp` + `restart`).
4. Required-secret set: derived from **`agent.yml` + the MCP catalog**
   (`requires_secret` / `secret_env_var` in `modules/mcps/*.yml`), *not* from
   grepping the rendered `.mcp.json` — grepping yields permanent false positives on
   every AWS agent (`mcp-json.tpl:41-42` references `AWS_PROFILE`/`AWS_REGION`, but
   `aws.yml` declares `requires_secret: false` and the wizard never writes them).
   A **set-but-empty** value counts as missing. Explicitly excluded: `GITHUB_FORK_PAT`
   (no session/MCP consumer); an empty `CLAUDE_CODE_OAUTH_TOKEN` is **INFO, never
   WARN** — it is the normal state of every `/login`-based local agent.

Message shape: `<VAR> missing or empty in <workspace>/.env` + the catalog's
`secret_doc_url`. Names and paths only.

### D5 — The boot warning

New template `modules/local-secret-check.sh.tpl` → rendered to
`scripts/local/agent-secret-check.sh`, wired as `ExecStartPre=-`. Same lib, same
detection as the doctor; prints WARN lines to stderr (→ `journalctl -u agent-<name>`);
**exits 0 unconditionally** *and* carries the `-` prefix (belt and braces).

### D6 — Two pre-existing defects that 021 would newly EXPOSE

Both ship **with** 021 or 021 ships a silent mode-dependent failure plus a credential
leak on day one:

1. **Sanitize the Atlassian workspace alias** to `[A-Za-z0-9_]` (`setup.sh:753`
   collects it with no validator and uppercases it into `ATLASSIAN_<ALIAS>_TOKEN`).
   An alias like `cenco-corp` produces `ATLASSIAN_CENCO-CORP_TOKEN` — a legal compose
   key but an **invalid systemd name**: in local mode the whole Atlassian credential
   set is silently dropped **and the token is printed verbatim into the journal**.
   Mirror the normalization into `render.sh`'s `{{NAME}}` for `mcp-json.tpl`.
2. **`mcp-json.tpl` emits `${VAR:-}`** instead of bare `${VAR}` for every secret
   reference. Demoted from *blocking* to *prudent* by the live measurement (Claude
   Code 2.1.185 parses the config fine with the vars unset — all 7 MCPs enumerate),
   but it is free defence-in-depth against the documented behavior. Docker-neutral;
   gets a docker-render assertion proving nothing else moved.

### D7 — Test seam for `install_service`

`install_service` has **zero** coverage today. Add
`SETUP_SYSTEMD_DIR="${SETUP_SYSTEMD_DIR:-/etc/systemd/system}"` (mirroring the
existing `LOGIN_SYSTEMD_DIR` pattern) so "the *installed* unit carries the directive"
is provable — and so a test on a dev Mac with a cached sudo timestamp can never
`sudo cp` into the tester's `/etc`.

## Project Structure

```text
specs/021-local-secret-delivery/
├── spec.md            # done
├── plan.md            # this file
├── research.md        # done (R0-R8 + the live mclaren measurement)
├── data-model.md      # Phase 1
├── quickstart.md      # Phase 1 — incl. the mclaren hardware gate
├── contracts/
│   ├── env-file-format.md      # the portable subset (systemd ∩ compose) + the divergence table
│   └── secret-delivery.md      # unit contract, doctor contract, healthcheck override
└── tasks.md           # /speckit-tasks

# Source touched (all host-side / local-mode; NOTHING under docker/)
modules/systemd-remote-control.service.tpl   # +2 directives (order is load-bearing)
modules/local-healthcheck.sh.tpl             # source -> parse; .env fallback
modules/local-secret-check.sh.tpl            # NEW (boot warn)
modules/mcp-json.tpl                         # ${VAR} -> ${VAR:-}
scripts/lib/env_file.sh                      # NEW (env_file_get, env_file_lint)
scripts/agentctl                             # NEW _local_secrets_doctor
setup.sh                                     # render the new script; sanitize the Atlassian alias; SETUP_SYSTEMD_DIR seam
tests/                                       # env-file.bats (NEW), local-render.bats, local-healthcheck.bats,
                                             # agentctl-local.bats, modules-render.bats (docker-unchanged guard)
```

**Structure Decision**: no new directories. One new lib (`scripts/lib/env_file.sh`),
one new template, one new test file; everything else extends an existing seam. The
lib is deliberately **not** mirrored into `docker/scripts/lib/` — it has no container
consumer, and mirroring would drag in a `DOCKER_E2E` obligation for nothing.

## Risks

| Risk | Mitigation |
|---|---|
| **Silent no-op after upgrade** — `--regenerate` never restarts the unit, and re-installs it only under `install_service: true` + passwordless `sudo`. An operator who stops there keeps running the old, secretless environment while everything *looks* fine. | The doctor inspects the **installed unit** (D4.3), and `quickstart.md` carries the exact, verified command sequence — including the **mandatory** `sudo systemctl restart`. |
| **Order inversion** — if the `.env` line lands *after* `remote-control.env`, a stray `PATH=` in `.env` silently wins and every MCP spawn `ENOENT`s (the historical `203/EXEC`). | A numeric line-order assertion, not a comment. |
| **Journal credential leak** via an invalid variable name (`export FOO=…`, a dashed Atlassian alias). The `-` prefix does not suppress it. | The alias sanitization (D6.1) + `env_file_lint` flagging the shape before it ever reaches systemd. |
| **Whole-file silent drop** on a BOM / non-UTF-8 byte — the agent boots healthy with zero secrets. | `env_file_lint` + the `ExecStartPre` WARN + the doctor. This is the failure mode the linter exists for. |
| **Coredump residual** — a piped `core_pattern` journals `COREDUMP_ENVIRON` in cleartext. `LimitCORE=0` does not stop it. | Inherent to env delivery; docker shares it. Record `core_pattern` on mclaren and document as accepted. |
| **Bats silent-pass** — the negatives this feature needs are exactly the shape that passes without running. | `run grep` + `[ "$status" -ne 0 ]`, or last-line. A real RED phase + a mutation spot-check is its own task. |

## Complexity Tracking

*No constitution violations.* Two items are **scope expansions beyond the spec**, both
recorded here because they were discovered in Phase 0 and are preconditions for 021
being correct rather than optional polish:

| Expansion | Why it must ship with 021 | Simpler alternative rejected because |
|---|---|---|
| Sanitize the Atlassian alias (`setup.sh` + `render.sh`) | A dashed alias becomes an **invalid systemd variable name**. The moment the new unit loads `.env`, the whole Atlassian credential set is silently dropped **and the token is logged verbatim to the journal**. 021 does not cause the defect; 021 is what makes it *fire*. | "Ship 021 and fix the alias later" = shipping a known credential leak. "Just document it" = the operator cannot see it (the failure is silent). |
| `${VAR}` → `${VAR:-}` in `mcp-json.tpl` | Free defence-in-depth against the *documented* Claude Code behavior (an unset var fails the whole config parse). **Demoted from blocking by measurement** — 2.1.185 does not actually do this. | Doing nothing is defensible today, but the doc says otherwise, and a future release enforcing it would take down every MCP in the workspace. The change is one template line and docker-neutral. |
