# Feature Specification: Remote Control session lifecycle in local mode

**Feature Branch**: `022-local-session-lifecycle`

**Created**: 2026-07-18

**Status**: Draft

**Input**: User description: local-mode Remote Control session lifecycle — after a
restart the agent goes silently unreachable, and the session name is redundant and
not configurable.

## Context

Measured on live hardware (mclaren, 2026-07-18). After the operator rebooted the
host, the agent became unreachable from phone and web, and **every routine health
signal stayed green**. The operator discovered it only by trying to use the agent.

The launcher does not own the file at the centre of this: Claude Code persists the
session pointer itself (`grep -rn "bridge-pointer" modules/ scripts/ docker/
setup.sh` returns nothing). What the launcher *does* own is the unit that decides
how the session is spawned and supervised — and in local mode nothing supervises
session *usability*, only process liveness.

This mirrors feature 021 exactly: docker had a mechanism, local mode never got an
equivalent, and the gap failed silently.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - My agent still answers after a reboot (Priority: P1)

As the operator of a local-mode agent, when I restart the service or reboot the
host, I want the agent reachable again from my phone without logging into the
machine to repair internal state by hand.

Today it is not. The service returns "active", the process reconnects to the
relay, and the agent is nonetheless unusable — because it re-announces a session
identity the server side already closed. Recovery currently requires the operator
to know an undocumented manual procedure involving Claude Code's internal state.

**Why this priority**: Total loss of the agent's primary function (being
controllable remotely), triggered by the most routine operation there is — a
restart. It is silent, so time-to-discovery is unbounded: the agent can sit
"healthy and useless" for days. Everything else here is secondary to the agent
actually working.

**Independent Test**: On a local-mode workspace, restart the agent service twice
consecutively (the second restart is what reproduces the failure today) and
confirm from a separate client that the agent is reachable after each, with zero
manual intervention on the host.

**Acceptance Scenarios**:

1. **Given** a local-mode agent that has been reachable, **When** the operator
   restarts the agent service, **Then** the agent is reachable from a client again
   without any manual repair of internal state.
2. **Given** a local-mode agent, **When** the host is rebooted, **Then** the agent
   is reachable from a client once the host finishes booting.
3. **Given** an agent whose previous session already ended, **When** the service
   starts, **Then** the agent presents a usable session instead of re-announcing
   the ended one.
4. **Given** a restart where the previous session is still valid, **When** the
   service starts, **Then** the agent does not needlessly discard a working
   session (no gratuitous churn — see Edge Cases).

---

### User Story 2 - The health check tells me when the agent is unreachable (Priority: P2)

As the operator, when the agent is not usable, I want the standard diagnostic to
say so, instead of reporting everything green while the agent is dead to me.

During the measured incident, `systemctl is-active` said active, restart count was
zero, the journal had no errors, both `ExecCondition` and `ExecStartPre` exited 0,
and the socket to the relay was ESTABLISHED with real bidirectional traffic. The
existing `agentctl doctor` reported no problem. Every available signal said
"healthy".

**Why this priority**: It is the safety net for whatever US1 cannot prevent, and it
has standalone value — an operator who *knows* can apply the documented recovery in
a minute. It is also the low-risk half of this feature: reporting never kills a
working session. P2 rather than P1 only because preventing the outage beats
reporting it.

**Independent Test**: Put a workspace into the unreachable state (an ended session
identity plus a live process), run the diagnostic, and confirm it reports the agent
as unusable and names the recovery step; then put it in the healthy state and
confirm the diagnostic stays quiet.

**Acceptance Scenarios**:

1. **Given** an agent in the unreachable state, **When** the operator runs the
   diagnostic, **Then** it reports the agent as not usable and states what to do.
2. **Given** a healthy, reachable agent, **When** the operator runs the diagnostic,
   **Then** it reports no session problem (no false alarm).
3. **Given** an agent whose state cannot be determined, **When** the operator runs
   the diagnostic, **Then** it says so explicitly rather than implying health.

---

### User Story 3 - The session has a name I can read (Priority: P3)

As the operator, I want the agent to appear under a sensible name in the Claude
client, and to choose that name in the agent's configuration.

Today the displayed name is composed as `<hostname>-<agent name>`. When the agent
name already contains the host — the natural convention for an agent named after
the machine it administers — the result stutters (`mclaren-mclaren-admin`). The
name is not settable from `agent.yml`, so the only fix is hand-editing a rendered
artifact, which does not survive re-rendering.

**Why this priority**: Cosmetic and operational polish. It causes no outage and has
a working (if fragile) local workaround. It rides along because it is a one-line
change in the same file US1 touches, and because "not configurable from
`agent.yml`" is a Principle I smell worth closing while we are here.

**Independent Test**: Render a workspace whose configuration sets an explicit
session name and confirm the rendered unit uses it; render one that omits it and
confirm the documented default applies.

**Acceptance Scenarios**:

1. **Given** a configuration that specifies a session name, **When** the workspace
   is rendered, **Then** the agent presents that name to the client.
2. **Given** a configuration that omits it, **When** the workspace is rendered,
   **Then** a documented default applies with no duplicated host segment.
3. **Given** an already-deployed workspace, **When** it is re-rendered, **Then** it
   resolves the name exactly as a brand-new one would — no compatibility branch —
   accepting the documented one-time identity change in the client.

---

### Edge Cases

- **A still-valid session at startup**: recovery must not blindly discard a usable
  session on every start, or every restart burns session continuity and hands the
  operator a new link each time.
- **State that cannot be read or parsed** (missing, truncated, unreadable): must
  degrade to the safe path, never block startup. The unit's boot hook introduced by
  021 already establishes this contract — it always exits 0 by design.
- **Concurrent starts**: two service starts racing on the same internal state must
  not corrupt it or leave the agent worse off than a single start.
- **A session that dies mid-operation**, with no restart involved: an agent can
  become unreachable without anyone restarting anything. **Explicitly out of scope**
  (see Clarifications) — repairing it would require recurring supervision, which
  FR-007 fences off. US2's diagnostic still surfaces the state, so the operator
  learns about it and applies the documented recovery; it simply is not automatic.
- **False alarms in the diagnostic**: a report that cries wolf on a healthy agent is
  worse than none — it trains the operator to ignore it. The one observable that
  looked usable (a "connected" marker in the service log) is actively unreliable:
  the status line is redrawn in place and those updates reach the log as unreadable
  binary blobs, so the last *readable* text can say "connecting" while the session
  is fully connected. That artifact produced a wrong diagnosis during the incident
  and must not become the basis of a check.
- **An agent that never had a session yet** (first boot, before any login) must not
  be reported as broken.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: After a service restart or host reboot, a local-mode agent MUST become
  reachable from a client without manual repair of internal state on the host.
- **FR-002**: The system MUST NOT present, as if usable, a session identity the
  server side has already ended.
- **FR-003**: Startup handling of session state MUST NOT be able to prevent the agent
  from starting. Unreadable, missing, or unexpected state MUST degrade to the safe
  path (Principle IV, and the existing boot-hook contract of always exiting 0).
- **FR-004**: Recovery MUST be idempotent and safe to repeat: running it against an
  already-healthy agent MUST leave a healthy agent (Principle IV).
- **FR-005**: The diagnostic MUST report an unreachable agent as a problem and MUST
  name the corrective action.
- **FR-006**: The diagnostic MUST NOT report a problem for a healthy, reachable agent
  (no false alarms), and MUST distinguish "cannot determine" from "healthy".
- **FR-007**: No automated remediation may be introduced that can act against a
  *healthy* session on a recurring basis unless its false-positive behavior is
  demonstrated first. This is a constitutional constraint, not a preference: the
  previously reverted watchdog killed healthy sessions every ~2 minutes, and the
  constitution forbids re-introducing reverted designs without first solving their
  documented failure mode.
- **FR-008**: The session name presented to the client MUST be configurable from the
  agent's configuration file and MUST survive re-rendering (Principle I).
- **FR-009**: With no session name configured, a documented default MUST apply that
  does not duplicate the host segment when the agent name already contains it.
- **FR-010**: All changes MUST preserve the local unit's secret-delivery behavior
  from 021 — both environment-file directives, their relative order, and the boot
  hook — verified by the existing tests.
- **FR-011**: Docker mode MUST remain byte-unchanged (Principle II); this feature is
  local-mode only.
- **FR-012**: Every behavior MUST be reproducible by re-rendering from the agent's
  configuration; no hand-edited runtime artifact (Principle I).
- **FR-013**: Diagnostics and logs MUST NOT print secret values. Session and
  environment identifiers are operational identifiers and MAY be shown to the owning
  operator.
- **FR-014**: When the stored session is still usable, the system MUST reuse it —
  a restart MUST NOT hand the operator a new client link gratuitously. When
  usability cannot be determined, the system MUST favour availability over
  continuity (renew rather than risk an unreachable agent), because renewing costs
  a changed link while wrongly reusing costs the whole agent.
- **FR-015**: Session-name resolution MUST be identical for existing and newly
  scaffolded workspaces — no compatibility branch keyed on workspace age. The
  resulting one-time change of the agent's identity in the client on first
  re-render is accepted and MUST be documented in the upgrade notes.

### Key Entities

- **Session identity**: what a client uses to reach this agent. Created by Claude
  Code, persisted in agent state under the workspace, re-announced by each new agent
  process. Can be *ended server-side while still present locally* — that divergence
  is the root of this feature.
- **Session name**: the human-readable label the agent presents in the client.
  Currently derived from host plus agent name; the subject of US3.
- **Agent service definition**: the launcher-owned unit deciding how the session is
  spawned, what runs before startup, and what happens on exit. The only place the
  launcher can influence this lifecycle.
- **Reachability state**: whether a client can actually use the agent right now. No
  artifact reports it today; process liveness and network connectivity both report
  "fine" while it is false.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: On live hardware, restarting the agent service twice consecutively
  leaves the agent reachable from a client both times, with zero manual repair steps.
  (Today the second restart reproduces the failure.)
- **SC-002**: On live hardware, a host reboot leaves the agent reachable once the
  host finishes booting, with zero manual repair steps.
- **SC-003**: In the unreachable state, the diagnostic reports the problem and names
  the corrective action — measured by running it against a workspace placed in that
  state.
- **SC-004**: Against a healthy agent, the diagnostic produces zero session-related
  warnings across at least 5 consecutive runs (no false alarms).
- **SC-005**: A corrupted or missing session-state file does not prevent the agent
  from starting, verified on real systemd.
- **SC-006**: A configured session name appears verbatim in the rendered unit; an
  omitted one yields the documented default with no duplicated host segment.
- **SC-007**: The host test suite stays green with zero regressions (measured
  baseline **1052 ok / 0 not ok / 20 skips** on `main` at `7e50c44`, after PR #79),
  and the docker-mode render is byte-identical to before this feature.
- **SC-008**: The 021 secret-delivery invariants still hold afterwards: the live
  agent's session environment still carries all its declared secrets.
- **SC-009**: Continuity is preserved when it should be — restarting an agent whose
  session is still usable does not change the client link, measured on live
  hardware. (This is the guard against the fix degenerating into "always renew".)

## Clarifications

### Session 2026-07-18

- Q: Should startup always force a fresh session (guaranteeing reachability but
  discarding continuity and changing the client link on every restart), or replace
  the session only when it is actually unusable? → A: **Replace only when unusable.**
  Session continuity is worth preserving, so a restart must not hand the operator a
  new link when the previous session still works. This puts the burden on finding a
  reliable "is it dead?" signal — the hard part, given that the stored process id
  does not discriminate and the log marker is unreliable. Where that signal is
  inconclusive, availability wins over continuity (FR-014).
- Q: Does this feature cover an agent that becomes unreachable *without* a restart
  (session dies mid-operation), or only the restart/reboot path? → A: **Only the
  restart/reboot path.** Covering mid-operation death requires recurring
  supervision, exactly the shape the constitution restricts after the reverted
  watchdog. The hole is accepted knowingly and mitigated by US2: the diagnostic
  surfaces the state even though nothing repairs it automatically.
- Q: For an already-deployed agent, should the session-name default preserve its
  current name (no visible change on upgrade) or adopt the new de-duplicated default
  (a one-time identity change in the client)? → A: **Adopt the clean default
  everywhere.** No compatibility branch: existing and new workspaces resolve the
  name the same way. The one-time identity change in the client is accepted (the
  operator already absorbed it manually on the live agent).

## Assumptions

- The reachability failure is caused by re-announcing an ended session identity.
  This is inference from strong measured evidence (the manual fix — renewing the
  stored identity — restored reachability immediately, and the connected marker
  appeared only afterwards), not server-side confirmation, which the operator cannot
  observe.
- The operator owns the machine and the Claude account; session and environment
  identifiers are not secrets in their own diagnostics.
- Session state is internal to Claude Code and may change shape across versions.
  Anything this feature does with it must tolerate that: an unrecognized shape is a
  "cannot determine" case (FR-006), never a crash (FR-003).
- The measured behavior comes from the Claude Code version currently deployed on the
  local agent. The spawn behavior is the launcher's decision to make, and
  alternatives are open to evaluation during planning.
- Docker mode is unaffected: it supervises its session through a different mechanism
  and did not exhibit this failure.
- The 021 changes to the same unit are already merged to `main`; this feature builds
  on them and must not disturb them.

## Out of Scope

- **Automatically repairing a session that dies mid-operation** (no restart
  involved) — decided in Clarifications. Recurring supervision is fenced by FR-007;
  US2 reports the state, the operator recovers manually.
- Any change to docker mode's supervision.
- Reintroducing recurring automated remediation of the previously reverted kind
  without first satisfying FR-007.
- Treating Claude Code's internal state format as a supported contract, or depending
  on fields it does not document.
- The pending unrelated deployment work (ferrari's corpus upgrade).
