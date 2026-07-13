# Feature Specification: Secret delivery in local mode

**Feature Branch**: `021-local-secret-delivery`

**Created**: 2026-07-13

**Status**: Draft

**Input**: User description: the workspace `.env` never reaches the agent's
processes in local (systemd) mode — the operator fills it in as the wizard
instructs, and nothing happens.

## Clarifications

### Session 2026-07-13

- Q: Which consumers are in scope for local secret delivery? → **A: the agent
  session unit + the healthcheck's alert path.** These are the two consumers with
  broken secrets and evidence of harm today. The qmd/vault/wiki-graph timers
  consume no secret in the current code, so handing them the `.env` would widen
  the surface for nothing (least privilege).
- Q: What becomes of the legacy `.state/healthcheck-notify.env`? → **A: honored
  as a compatibility override.** If the file exists it wins; otherwise the values
  come from `.env`. No live agent breaks on upgrade, new scaffolds never need it,
  and it is documented as legacy. Accepted cost: a second read path survives, but
  nothing creates it any more.
- Q: How loud is a missing required secret? → **A: doctor + a boot warning.**
  `agentctl doctor` reports it (naming the variable and the file); the agent's own
  log carries a WARN at start. The agent still boots — a miscredentialed optional
  MCP must not take down the session. Fail-silent stays intact for the *lifecycle*;
  what dies is the silence.

## The problem in one paragraph

The wizard collects every secret an agent needs and writes them to
`<workspace>/.env` (mode `0600`). In **docker** mode those secrets reach the
agent because compose mounts the file (`env_file`). In **local** mode there is
no equivalent: nothing loads `.env` into any process. The result is not an
error — it is **silence**. An MCP that needs an API key starts without one and
fails at its first call; the health alert the operator configured never fires.
The operator did everything the wizard asked and gets no signal that it did not
take effect. Meanwhile local mode has grown parallel, hand-managed secret files
to work around the gap, so the same token can need to exist in two places with
nothing saying so.

## Verified evidence (code at `main` = `cd6ad89`, v0.12.0)

| # | Fact | Source |
|---|---|---|
| 1 | The wizard writes all secrets to `<workspace>/.env`, `chmod 0600`: `CLAUDE_CODE_OAUTH_TOKEN`, `NOTIFY_BOT_TOKEN`/`NOTIFY_CHAT_ID`, `ATLASSIAN_*`, `GITHUB_PAT`, `GITHUB_FORK_PAT`, and the optional-MCP secrets | `setup.sh:1210-1232` |
| 2 | Docker delivers them to the process | `modules/docker-compose.yml.tpl:67` (`env_file`) |
| 3 | Local mode has exactly one `EnvironmentFile` across all its units, and it points at `.state/remote-control.env` | `modules/systemd-remote-control.service.tpl:12` |
| 4 | That file defines exactly four **non-secret** keys: `CLAUDE_CONFIG_DIR`, `DISABLE_AUTOUPDATER`, `HOME`, `PATH` | `modules/remote-control.env.tpl` |
| 5 | The other five local units (healthcheck, qmd-reindex, qmd-watch, vault-backup, wiki-graph) declare no `EnvironmentFile` and no `Environment=` at all | `modules/local-*.service.tpl` |
| 6 | No rendered local artifact sources `<workspace>/.env` | grep across `modules/local-*.tpl`, `modules/systemd-*.tpl` |
| 7 | `.mcp.json` passes every catalog secret by shell expansion — so in local mode they expand to the **empty string** | `modules/mcp-json.tpl:27,41-42,53-58,65` |
| 8 | The local healthcheck reads its notify secrets from a **different** file, `.state/healthcheck-notify.env`, which **nothing creates or populates** | `modules/local-healthcheck.sh.tpl:14,101` |
| 9 | `CLAUDE_CODE_OAUTH_TOKEN` appears in **no** local artifact — the headless-auth path the `.env` advertises does not exist in local mode | grep across `modules/local-*`, `modules/systemd-*` |
| 10 | There is no heartbeat unit in local mode; `heartbeat.sh` (the only caller of `notifiers/`) runs under `crond` in docker only. The sole local consumer of `NOTIFY_*` is the healthcheck | `modules/local-*.{service,timer}.tpl`, `scripts/heartbeat/heartbeat.sh` |

## User Scenarios & Testing *(mandatory)*

### User Story 1 - The agent can use the credentials I gave it (Priority: P1)

I scaffold a local agent, answer the wizard's prompts for an optional MCP that
needs an API key, and paste the key into `.env` where the wizard tells me to.
When the agent starts, that MCP works.

Today it does not: the MCP starts with an empty credential and fails on its
first call, with nothing in the setup output, the doctor, or the journal to tell
me why.

**Why this priority**: this is the feature. Every other story is a variation of
"the secret did not arrive." Without it the optional-MCP catalog is decorative
in local mode, and the `.env` the wizard so carefully generates is a file that
does nothing.

**Independent Test**: scaffold a local workspace with a secret-bearing MCP
enabled, fill `.env`, start the agent, confirm the MCP process sees a non-empty
credential. Delivers the core value on its own.

**Acceptance Scenarios**:

1. **Given** a local workspace whose `.env` holds a non-empty value for a secret
   an enabled MCP requires, **When** the agent session starts, **Then** that MCP
   receives the value — not an empty string.
2. **Given** the same workspace, **When** the operator edits `.env` and restarts
   the agent, **Then** the new value takes effect: no second file to update, no
   re-scaffold.
3. **Given** an identical `agent.yml` + `.env` scaffolded in **docker** mode,
   **When** the agent starts, **Then** the same secrets reach the same consumers.
   The `.env` is portable across modes.

---

### User Story 2 - One place for secrets, not two (Priority: P1)

As the operator of a local agent I keep secrets in exactly one file. I am never
asked to maintain the same token in `.env` *and* in a second hand-made file
whose existence nothing told me about.

Today the notify token I typed at the wizard prompt lands in `.env`, while the
local healthcheck reads `.state/healthcheck-notify.env` — a file no code
creates. My DEGRADED alert silently never fires.

**Why this priority**: the duplication is the mechanism of the silence, and it
is the part an operator cannot discover unaided. Fixing delivery (US1) without
consolidating the sources would leave the same class of bug alive in whatever
subsystem needs a secret next.

**Independent Test**: with only `.env` populated (no hand-made second file),
force the healthcheck into a DEGRADED state and confirm the alert fires.

**Acceptance Scenarios**:

1. **Given** a local workspace where `NOTIFY_BOT_TOKEN`/`NOTIFY_CHAT_ID` are set
   **only** in `.env`, **When** the healthcheck detects a DEGRADED state,
   **Then** the alert is delivered.
2. **Given** an existing local agent that already carries a hand-made
   `.state/healthcheck-notify.env`, **When** it is upgraded to this version,
   **Then** that file still wins and the agent keeps alerting exactly as before —
   the upgrade never silently breaks a live agent.
3. **Given** a workspace with **no** legacy file, **When** the healthcheck needs
   the notify credentials, **Then** it reads them from `.env`. A fresh scaffold
   never produces the legacy file, and nothing instructs the operator to create
   one.

---

### User Story 3 - Silence is not an acceptable failure mode (Priority: P2)

When a secret that an enabled subsystem requires is missing or empty, I find out
— from the setup output, from `agentctl doctor`, or from the logs. I do not
discover it weeks later, when a tool call fails for reasons that look unrelated.

**Why this priority**: it turns the whole class of bug from invisible into
visible. Valuable on its own even if delivery were already correct, because the
operator can simply *forget* to fill a key the wizard deliberately left blank.

**Independent Test**: leave a required secret empty in `.env`, run
`agentctl doctor`, confirm it reports the gap with an actionable hint.

**Acceptance Scenarios**:

1. **Given** an enabled MCP that declares it requires a secret, **When** the
   corresponding key in `.env` is missing or empty, **Then** `agentctl doctor`
   reports it, naming the variable and the file to edit.
2. **Given** the same condition, **When** the agent starts, **Then** a warning
   naming the variable is written to the agent's own log — and the agent still
   starts. A miscredentialed optional MCP degrades that MCP; it does not take
   down the session.
3. **Given** a workspace with no missing secrets, **When** the agent starts and
   the doctor runs, **Then** neither emits a secrets warning. The check must not
   cry wolf on a correctly configured agent.

---

### Edge Cases

- **`.env` absent entirely** (scaffolded and never created, or deleted): the
  agent must still start. A missing secrets file is a degraded state, not a boot
  failure — an agent with no optional MCPs needs no secrets at all.
- **`.env` present but a value is empty**: the wizard deliberately emits the key
  name with an empty value so the operator can fill it later. Must be treated as
  "not provided", not as "provided, empty".
- **Values containing spaces, `#`, quotes or `=`** (an Atlassian URL, a padded
  token): whatever loads the file must not corrupt them — and must not execute
  anything the file contains.
- **`.env` with loosened permissions** (operator did `chmod 644`): the doctor
  already warns about this; the delivery path must not silently make a `0600`
  file readable to others, nor copy its contents somewhere more permissive.
- **A secret is rotated**: the operator needs a documented, actually-working path
  to make the new value take effect. Docker already has a known trap here
  (`restart` does not re-read `.env`); local must not invent a second, different
  trap.
- **Two agents on one host**: one workspace's `.env` must never leak into the
  other agent's units.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST deliver the secrets an operator writes into
  `<workspace>/.env` to the local-mode processes that consume them, with no
  manual copying of any value into a second file.
- **FR-002**: `.env` MUST be the single source of secrets in local mode. The one
  pre-existing parallel file, `.state/healthcheck-notify.env`, is demoted to a
  **compatibility override**: honored when present (so live agents do not break),
  never created by a fresh scaffold, never something the operator is told to
  maintain.
- **FR-003**: The same `agent.yml` + `.env` pair MUST yield equivalent secret
  availability in docker and in local mode (parity — a hard constraint from the
  requester).
- **FR-004**: An absent or unreadable `.env` MUST NOT prevent the agent from
  starting; it degrades the subsystems that need secrets and nothing more.
- **FR-005**: An empty value MUST be treated as "not provided".
- **FR-006**: The system MUST NOT widen the exposure of `.env`: its `0600` mode
  and operator ownership are preserved, and secret **values** MUST NOT reach
  logs, the journal, or any world-readable surface as a side effect of delivery.
- **FR-007**: `agentctl doctor` MUST report, per enabled subsystem, when a secret
  it requires is missing or empty — naming the variable and the file to edit —
  and the agent MUST log a warning naming the variable at start. Neither may fire
  on a correctly configured agent.
- **FR-008**: A missing secret MUST NOT prevent the agent or the affected
  subsystem from starting. It degrades what depends on it, and says so.
- **FR-009**: The operator MUST have a documented path to rotate a secret and
  have it take effect, and that path MUST be the one the docs actually promise.
- **FR-010**: Secrets reach exactly two consumers: **the agent session unit**
  (and the MCP servers it spawns) and **the healthcheck's alert path**. The
  qmd-reindex, qmd-watch, vault-backup and wiki-graph timers consume no secret in
  the current code and MUST NOT be given the `.env` — least privilege.
- **FR-011**: Docker-mode behavior MUST be unchanged, and the host test suite
  (977 tests, green at `cd6ad89`) MUST stay green.
- **FR-012**: The change MUST survive `--regenerate` (single-source-of-truth
  principle: what is generated is regenerable).

### Key Entities

- **Workspace `.env`**: the operator-owned secrets file (`0600`), generated by
  the wizard with the keys the chosen configuration needs, values filled by the
  operator. Never committed. Already the source of truth in docker.
- **Secret consumer**: any process needing a secret value — the agent session
  (and the MCP servers it spawns), the healthcheck's alert path, and possibly the
  backup timers. Each declares which variables it requires.
- **Secret requirement**: the declaration — already present in the MCP catalog
  descriptors as `requires_secret` / `secret_env_var` — of which variable a
  subsystem needs. This is what makes FR-007 checkable without a hand-maintained
  list.
- **Legacy parallel secret file**: `.state/healthcheck-notify.env`, today's
  workaround. Its fate is Q2.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: In a local workspace, **100%** of the secrets the wizard writes
  into `.env` for the enabled configuration reach their consumer; **zero**
  require a second file. (Today: zero reach their consumer.)
- **SC-002**: An operator goes from "wizard finished" to "secret-bearing MCP
  works" by editing exactly **one** file, with **no** manual step that is not
  printed in the post-scaffold instructions.
- **SC-003**: The identical `.env` yields the same secret availability in both
  deployment modes — verifiable by scaffolding the same `agent.yml` twice.
- **SC-004**: A missing or empty required secret is surfaced by `agentctl doctor`
  in **100%** of cases, naming the variable — never discovered only through a
  downstream tool failure.
- **SC-005**: An existing local agent (e.g. the live one on `mclaren`) upgrades
  without losing any capability it had: no silent regression of its alerting or
  its MCPs.
- **SC-006**: No secret **value** appears in the journal, in `systemctl` output,
  in the doctor's output, or in any file more permissive than `0600`.
- **SC-007**: The host suite stays green (977 at baseline) and docker mode is
  unchanged — this feature adds capability to local mode; it does not touch
  docker.

## Assumptions

- The operator owns both the workspace and the systemd units
  (`User={{OPERATOR_USER}}`), so a file the operator can read is a file the
  agent's units can read. The threat model defends against *other users on the
  host* and against *anything that copies or logs the file* — not against the
  operator.
- The wizard's prompts and the shape of `.env` do not change. This feature makes
  the existing `.env` work; it does not redesign what goes into it.
- The heartbeat is out of scope: it has no local unit at all (fact 10). Making
  the heartbeat run in local mode is a separate feature.
- `agent.yml` stays the single source of truth for configuration and `.env` the
  single source for secrets. Secrets do not move into `agent.yml` — it is
  committed; `.env` never is.
- Docker's current behavior is correct and is the reference for parity.

## Out of Scope

- Adding a heartbeat unit to local mode.
- Changing which secrets the wizard collects, or how it prompts for them.
- A secrets-manager integration (age, sops, `systemd-creds`). The bar here is
  "the `.env` the launcher already generates works in both modes"; anything
  richer is a follow-on decision, not a prerequisite for this one.
- Rotating or generating any secret on the operator's behalf.

## Constitution note

The project's constitution values an **idempotent, fail-silent lifecycle** — and
fail-silent is exactly what produced this bug. The resolution (Q3) does not
amend the principle: the *lifecycle* stays fail-silent (a missing secret never
blocks a boot, never crashes a unit, and a re-run changes nothing), while the
*diagnosis* becomes loud (doctor + a boot warning). Fail-silent was always about
not letting a degraded subsystem take the agent down — never about hiding from
the operator that it is degraded. Planning should confirm this reading against
`.specify/memory/constitution.md` rather than assume it.
