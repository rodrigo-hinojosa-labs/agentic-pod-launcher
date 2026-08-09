# Feature Specification: Channel reply-delivery guard

**Feature Branch**: `028-channel-reply-guard`

**Created**: 2026-08-08

**Status**: Draft

**Input**: User description: "Add a deterministic Stop-hook guard so that a channel-originated turn (e.g. a Telegram message) is verified to have actually delivered its reply through the channel's response tool — and if it didn't, the turn is re-injected once (at most twice) to force the send. Bug measured in production (ferrari host, donna agent, 2026-08-08): the agent was alive, generated the answers, but wrote them as plain text in the TUI instead of calling the reply tool, so the replies never left the container; the typing indicator then fired a misleading 'OAuth expired' warning. Root cause is model behaviour under a long (~106k token) `--continue` context diluting the reply-through-the-tool convention — a deterministic guard, not more prompt."

## Clarifications

### Session 2026-08-08

- Q: Maximum corrective attempts per turn before the guard gives up? → A: 1 — one re-injection, then give up (the honest timeout message covers the operator). Operator-tunable via `agent.yml`.
- Q: Is the guard on by default, or opt-in? → A: On by default for any agent configured with a Telegram channel; disableable via `agent.yml`. Existing agents adopt it at their next `./setup.sh --regenerate`.
- Q: Should the guard leave a visible trace when it fires? → A: Yes — one line to the channel plugin's stderr log (the same sink as the typing-indicator instrumentation); nothing extra to the chat beyond the forced reply; never logs secrets or transcript contents.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A channel answer always reaches the operator (Priority: P1)

The operator sends a message to the agent over the channel (Telegram). The agent
processes it and produces an answer, but — because the convention of replying
through the channel tool has diluted under a long conversation context — it writes
the answer only as plain text inside its own terminal, never invoking the channel
reply tool. Today that answer is silently lost: the operator sees nothing but a
"still thinking" indicator that eventually turns into a misleading warning.

With this feature, when a channel-originated turn finishes without the channel
reply tool having been called, the system automatically nudges the agent exactly
once to deliver the pending answer through the reply tool. The operator receives
the answer in the same session, with no manual intervention (no restart, no
`kick-channel`, no re-sending the message).

**Why this priority**: This is the measured production failure. Without it, a live,
healthy agent silently drops replies once its context grows — the single most
damaging failure mode for a chat-driven agent, because everything else looks green.

**Independent Test**: Feed the guard a representation of a finished channel turn in
which the reply tool was NOT called, and confirm it emits exactly one corrective
action; feed it the same turn where the reply tool WAS called, and confirm it does
nothing. Fully host-testable with fixtures, no live agent required.

**Acceptance Scenarios**:

1. **Given** a channel-originated turn that produced an answer but did not call the
   channel reply tool, **When** the turn ends, **Then** the system issues exactly one
   corrective action that causes the agent to send the answer through the reply tool.
2. **Given** a channel-originated turn in which the agent already called the channel
   reply tool, **When** the turn ends, **Then** the system takes no corrective action
   (no duplicate reply, no nudge).
3. **Given** a turn that did NOT originate from a channel (a console / interactive
   turn), **When** the turn ends, **Then** the system never fires.
4. **Given** a turn that has already received the maximum number of corrective
   actions, **When** it ends still without a reply-tool call, **Then** the system gives
   up without re-injecting again (no unbounded loop), leaving the session idle.

---

### User Story 2 - The stuck-turn warning stops lying about the cause (Priority: P2)

When a turn runs long enough for the typing indicator to give up, the operator
today sees a message that asserts a single definite cause: "it is probable that
Claude's OAuth expired". In the measured incident that was false — the login was
fine; the agent had simply answered without the tool. The message sent the operator
down the wrong diagnostic path.

With this feature, that timeout message no longer asserts a cause it cannot know.
It states the real alternatives — the agent may be genuinely slow, it may have
answered without calling the reply tool, or the login may have expired — and points
to the diagnostic that disambiguates them.

**Why this priority**: Independent of US1 and valuable on its own — even when the
guard cannot act, an honest message stops wasting the operator's time on a
non-existent OAuth problem. Lower than US1 because it improves diagnosis rather than
restoring the dropped reply.

**Independent Test**: Inspect the rendered timeout warning text and confirm it names
more than one possible cause and a next step, and does not assert OAuth expiry as
the definite reason.

**Acceptance Scenarios**:

1. **Given** a turn that exceeds the typing-indicator cap, **When** the warning is
   emitted to the chat, **Then** the message presents multiple possible causes
   (slow turn / answered-without-tool / expired login) and a diagnostic step, and
   does not state expired OAuth as the certain cause.

---

### Edge Cases

- **Origin signal unavailable**: If, at turn-end, the system cannot reliably
  determine both whether the turn originated from a channel AND whether the reply
  tool was called, it MUST do nothing (fail safe) rather than guess and misfire.
  (This is the feasibility gate — see Assumptions.)
- **Empty / no-answer turn**: A channel turn that produced no answer at all (the
  agent genuinely had nothing to say and called no tool) — the corrective nudge
  should not manufacture a spurious reply; the guard targets the "answer exists but
  wasn't delivered" case. If the two cannot be distinguished, the safe default is to
  nudge once (a redundant "please reply via the tool" is cheaper than a dropped
  answer), bounded by the loop guard.
- **Agent still refuses after the nudge**: After the maximum corrective attempts the
  guard stops; the turn ends undelivered but the loop is bounded and the honest
  timeout message (US2) covers the operator.
- **Heartbeat / cron ticks**: Autonomous heartbeat ticks run in an isolated
  configuration and are not channel-originated operator turns; the guard MUST NOT
  interfere with them.
- **Concurrent / rapid messages**: Overlapping operator messages must not cause the
  guard to cross-fire between turns or double-count attempts.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: When a channel-originated turn ends without the channel reply tool
  having been called during that turn, the system MUST perform an automatic
  corrective action that causes the agent to deliver its pending answer through the
  channel reply tool.
- **FR-002**: The corrective action MUST be bounded to at most a configured maximum
  number of attempts per turn (default 1, confirmed in Clarifications). After the
  maximum is reached the system
  MUST stop and MUST NOT re-inject again — there MUST be no unbounded
  end-turn → re-inject → end-turn loop. The platform's own re-entrancy signal for
  turn-end hooks MUST be respected.
- **FR-003**: The system MUST NOT perform the corrective action for turns that did
  not originate from a channel (console / interactive turns).
- **FR-004**: The system MUST NOT perform the corrective action when the channel
  reply tool WAS called during the turn.
- **FR-005**: The system MUST derive, from data available at turn-end, (a) whether
  the turn originated from a channel and (b) whether the channel reply tool was
  called. If either signal cannot be reliably obtained, the feature MUST fail safe
  (take no action) instead of misfiring.
- **FR-006**: The guard MUST coexist with the existing typing-indicator behaviour;
  it MUST NOT remove or replace the typing indicator.
- **FR-007**: The guard MUST NOT break local mode (systemd `--spawn=session`) or
  docker mode, and MUST degrade gracefully (fail-silent) — it MUST NOT be able to
  crash the interactive session or the container supervisor.
- **FR-008**: Any operator-facing toggle governing the guard (enable/disable, max
  attempts) MUST be sourced from `agent.yml` and MUST survive `./setup.sh
  --regenerate` (single source of truth).
- **FR-009**: The typing-timeout warning message MUST NOT assert a single definite
  cause. It MUST communicate that the delay may be a slow turn, an answer produced
  without calling the reply tool, or an expired login, and MUST point to a
  diagnostic action.
- **FR-010**: The guard's behaviour MUST be covered by host-runnable `bats` tests
  including at minimum: (a) channel turn with reply tool called → no corrective
  action; (b) channel turn without reply tool → exactly one corrective action;
  (c) console turn → never fires; (d) loop guard → after the maximum attempts, gives
  up and does not re-inject again.
- **FR-011**: User-facing changes MUST be recorded in `CHANGELOG.md` and reflected in
  `README.md`; the launcher `VERSION` MUST be bumped per the project's versioning
  discipline.
- **FR-012**: Each time the guard performs a corrective action, it MUST emit one log
  line to the channel plugin's stderr log (the same sink as the typing-indicator
  instrumentation). It MUST NOT post anything to the chat beyond the forced reply
  itself, and MUST NOT write secrets or transcript contents to the log.
- **FR-013**: The guard MUST be enabled by default for any agent configured with a
  Telegram channel, and MUST be disableable via `agent.yml`. The enabled/disabled
  state and the maximum-attempts value (FR-002) MUST take effect through `./setup.sh
  --regenerate` (which backfills the toggle and re-renders the hook script), so
  existing agents adopt the guard at their next regenerate. The hook's `settings.json`
  registration is re-applied at the next docker boot / local login (the same channel
  the launcher uses to re-apply trusted user-settings), so on a running agent full
  activation follows its next restart.

### Key Entities *(include if feature involves data)*

- **Turn-end signal**: The information available when an agent turn finishes,
  carrying (at least, if feasible) the turn's origin and a re-entrancy marker. The
  authoritative fields are UNVERIFIED and are the subject of the feasibility gate.
- **Turn origin**: Whether a finished turn came from the channel (an operator
  message) or from the console / an autonomous tick. Drives whether the guard is
  eligible to fire at all.
- **Reply-tool-call evidence**: The record that the channel reply tool was invoked
  during the turn. Its presence suppresses the guard; its absence (on a channel
  turn) triggers it.
- **Attempt counter (loop guard)**: The per-turn bound on corrective actions that
  guarantees termination and prevents an infinite re-injection loop.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: For a channel turn in which the agent produced an answer but did not
  call the reply tool, the operator receives that answer through the channel within
  the same session and with zero manual intervention — the measured donna failure no
  longer results in a silently dropped reply.
- **SC-002**: Across the test matrix, the guard performs zero corrective actions on
  (a) console / interactive turns and (b) channel turns where the reply tool was
  already called — no duplicate replies, no false fires.
- **SC-003**: No turn triggers more than the configured maximum corrective attempts;
  after the maximum the session settles with no further re-injection (bounded, no
  infinite loop).
- **SC-004**: An operator reading the typing-timeout warning can tell it is NOT
  asserting a definite OAuth failure — the message names more than one possible cause
  and a diagnostic step.
- **SC-005**: The default host `bats` suite (bash 3.2 and 5.x) passes with the new
  tests and requires no Docker daemon; any docker-image-scoped portion is gated
  behind `DOCKER_E2E=1` and is not required for the default suite.
- **SC-006**: Re-running `./setup.sh --regenerate` reproduces the guard's rendered
  configuration byte-for-byte from `agent.yml` (no hand-authored drift).
- **SC-007**: When the guard fires, its action is visible in the channel plugin's
  stderr log (one line per corrective action) and produces no chat output other than
  the delivered reply.

## Assumptions

- **Feasibility / research gate (NOT to be papered over)**: It is UNVERIFIED that the
  turn-end signal exposes the turn's origin (channel vs console) and reply-tool-call
  status. Planning MUST first dump the REAL turn-end payload on a representative
  setup and, as a fallback, inspect the session transcript to infer origin + tool
  call. If neither yields a reliable signal, the feature is HALTED and reported — no
  implementation proceeds on a guessed signal. FR-005 encodes the fail-safe if the
  signal is only sometimes available.
- **Channel scope**: The only channel in use today is Telegram; the channel reply
  tool is `plugin:telegram:telegram`. The design is channel-generic but is validated
  against Telegram.
- **Default maximum attempts = 1** (re-inject once, then give up) — confirmed in
  Clarifications. Chosen as the safest default against loops; the diluted-context
  cause rarely yields to an identical second nudge. Operator-tunable via `agent.yml`
  (FR-002, FR-013).
- **Guard applicability & default state**: The guard applies to the interactive
  channel session (operator turns), not to autonomous heartbeat cron ticks, which run
  in an isolated configuration. It is enabled by default for agents configured with a
  Telegram channel and can be disabled via `agent.yml` (FR-013); existing agents adopt
  it at their next `--regenerate`.
- **Observability of firing**: Each corrective action emits one line to the channel
  plugin's stderr log (the same sink as the typing instrumentation), never to the
  chat and never carrying secrets (FR-012, SC-007).
- **Corrective action content**: The corrective action is a single re-injected
  instruction telling the agent it answered without delivering through the channel
  and to resend via the reply tool now. Its exact wording is an implementation
  detail, not a spec-level decision.
- **Typing-message scope**: The US2 message improvement lives in the image-baked
  Telegram plugin patch and therefore takes effect on an image rebuild (docker
  scope); it does not change local-mode behaviour.
- **Hosting mechanism is a planning decision**: Which of the three code paths hosts
  the guard (host launcher, image-baked `docker/`, or workspace-templated), where
  its configuration is rendered, and how it survives `--regenerate`, is resolved in
  planning under Principle I — not fixed by this spec. This feature introduces the
  launcher's first Claude Code hook, so that surface is genuinely new.

## Dependencies

- The existing Telegram plugin typing patch (currently at v4) — US2 modifies its
  warning message; US1 must coexist with, not replace, its typing behaviour.
- The channel plugin and its reply tool (`plugin:telegram:telegram`) as the delivery
  path the guard forces the agent onto.
- `agent.yml` as the single source of truth for any new toggle (Principle I).
