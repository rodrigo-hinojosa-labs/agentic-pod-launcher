# Feature Specification: Channel interactive-prompt (AskUserQuestion) guard

**Feature Branch**: `031-channel-askuserquestion-guard`

**Created**: 2026-08-19

**Status**: Draft

**Input**: User description: "A deterministic guard so that a channel-originated turn (a Telegram message) cannot hang silently mid-turn when the agent calls the AskUserQuestion tool — a console-only interactive selection prompt the channel user can never see or answer. The guard must intercept that prompt before it blocks and redirect the agent to pose the question(s) through the channel reply tool instead, so the operator receives the question. Third and last feature of the ferrari incident family (2026-08-16, donna); sibling of the merged 028-channel-reply-guard, but a distinct failure mode: 028 fires at turn-END (Stop hook) when a reply was never sent; 031 must fire MID-turn (before the interactive prompt blocks), because a hung turn never reaches Stop. Anticipated failure mode of the same class/subsystem — no forensic capture in hand for the AskUserQuestion case specifically; mechanism to be confirmed in Phase 0."

## Clarifications

### Session 2026-08-19

- Q: When the guard intercepts the interactive prompt in a channel turn, how does the question reach the operator? → A: Agent-driven — the guard denies the prompt and instructs the agent to re-ask through the channel reply tool (mirrors 028, no new privilege in the interception path, best-effort bounded by max redirections). Delivery is guaranteed-by-bounded-retry, not deterministic.
- Q: If the agent exhausts the maximum redirections and keeps insisting on the prompt, what does the operator receive? → A: One explicit give-up message in the chat ("I tried to open an interactive prompt I can't show you here") plus the stderr trace — the turn never ends in silence. That message is delivered through the plugin's existing channel-send path (the same one that already emits the typing-timeout warning), so it needs no new privilege and is deterministic even when the model no longer complies.

### Session 2026-08-22 (post-analyze remediation)

- Give-up is a **terminal deny**, not a fall-through. At the redirection cap the guard
  keeps denying the interactive prompt (with a terminal "stop retrying this tool"
  reason) instead of allowing it through. Rationale: allowing it through reopened the
  console-only menu and reintroduced the silent hang this feature exists to prevent
  (would have violated SC-001). What is bounded is the number of *redirections*, not
  interceptions — the interception continues all turn, which is what guarantees no
  hang. (analyze finding I1)
- Give-up delivery trigger is **pinned**: the plugin checks the give-up marker on every
  typing keep-alive tick AND on keep-alive (re)start for the next inbound turn,
  delivering exactly once (delete-on-send). Rationale: a single "tick or turn-end"
  trigger could drop the message if the turn ended between the marker write and the next
  tick, violating SC-001's "never in silence" guarantee. (analyze finding U1)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A channel turn never hangs silently on a console-only prompt (Priority: P1)

The operator sends a message to the agent over the channel (Telegram). While
processing it, the agent decides it needs a decision from the operator and calls
the interactive selection tool (`AskUserQuestion`). In the container that tool
renders a menu in the agent's own terminal (TUI) — a surface the Telegram operator
cannot see and cannot answer. The turn blocks, waiting for an input that will never
arrive. The operator sees only a "still thinking" indicator that eventually turns
into the (post-028) timeout warning, and the conversation is stuck until someone
restarts or attaches to the container.

With this feature, when a channel-originated turn attempts the interactive prompt,
the system intercepts it before it blocks and steers the agent to ask its
question(s) through the channel reply tool instead — as ordinary text the operator
receives in chat and can answer in chat. The turn keeps moving; nothing hangs
invisibly.

**Why this priority**: It is the failure that makes a chat-driven agent go dark
mid-conversation with everything looking green — the same shape as the measured 028
incident, one layer earlier. Without it, any turn in which the model reaches for an
interactive prompt (a natural thing to do, and one this very workflow uses on the
console) becomes a silent dead end for the channel operator.

**Independent Test**: Feed the guard a representation of an interactive-prompt
attempt inside a channel-originated turn and confirm it intercepts and redirects
(does not let the prompt block); feed it the same attempt inside a console turn and
confirm it does nothing (the prompt proceeds normally). Fully host-testable with
fixtures, no live agent required.

**Acceptance Scenarios**:

1. **Given** a channel-originated turn in which the agent calls the interactive
   prompt tool, **When** the tool is about to open, **Then** the system intercepts it
   before it blocks and steers the agent to deliver the question(s) through the
   channel reply tool, so the operator receives the question in chat.
2. **Given** a turn that did NOT originate from a channel (a console / interactive
   turn), **When** the agent calls the interactive prompt tool, **Then** the system
   does nothing and the prompt proceeds normally.
3. **Given** a channel-originated turn where the guard cannot reliably determine the
   turn's origin, **When** the interactive prompt tool is called, **Then** the system
   fails OPEN (allows the prompt) rather than block a possibly-legitimate console
   prompt.
4. **Given** a channel turn that has already received the maximum number of
   redirections, **When** the agent calls the interactive prompt tool again, **Then**
   the system stops redirecting (no unbounded redirect → retry loop) while still
   preventing the console-only prompt from opening (the turn does not hang), the
   operator receives one explicit give-up message in the chat that an unsupported
   interactive prompt was attempted, and a stderr trace is written.

---

### User Story 2 - The stuck-turn warning names the interactive-prompt cause (Priority: P3)

After 028, the typing-timeout warning already stopped asserting a single definite
cause; it lists slow-turn / answered-without-the-tool / expired-login and points to
a diagnostic. It does not yet name the case this feature targets: a turn blocked in
a console-only interactive prompt. In the rare path where the guard is absent,
disabled, or its anchors have drifted, the operator would again be sent down the
wrong diagnostic path.

With this feature, that timeout message also names "blocked in an interactive prompt
the channel can't answer" among the possible causes, so an honest message remains
even when the guard did not act.

**Why this priority**: Defense-in-depth and honesty, not the primary fix — when US1
works, this cause never reaches the timeout warning at all. Valuable only for the
degraded path (guard disabled/failed), hence P3.

**Independent Test**: Inspect the rendered timeout warning text and confirm it names
the interactive-prompt possibility alongside the existing causes, and still asserts
no single definite cause.

**Acceptance Scenarios**:

1. **Given** a turn that exceeds the typing-indicator cap, **When** the warning is
   emitted to the chat, **Then** the message names the "blocked in an interactive
   prompt" possibility among the existing causes and still points to a diagnostic,
   without asserting any single certain cause.

---

### Edge Cases

- **Origin signal unavailable (fail OPEN)**: If, at interception time, the system
  cannot reliably determine that the turn originated from a channel, it MUST allow
  the prompt (do nothing). This is the OPPOSITE fail-safe direction from 028:
  blocking a legitimate console interactive prompt would break a normal, supported
  workflow (this very session uses it), which is worse than leaving a channel turn to
  hang — the latter is the pre-existing behaviour and is still covered by the
  typing-timeout warning (US2). This is the feasibility gate — see Assumptions.
- **Agent keeps insisting on the interactive prompt**: After the maximum number of
  redirections the guard stops *redirecting* for that turn (bounded) but MUST keep the
  console-only prompt from opening — it switches to a terminal decision that tells the
  agent to stop retrying the tool, rather than fight the model in an infinite
  redirect → retry loop or fall through to a hang. It delivers one explicit give-up
  message to the operator through the channel's existing send path plus a stderr trace,
  so the operator is never left in silence and the turn never hangs even on give-up.
- **Heartbeat / cron ticks**: Autonomous heartbeat ticks run in an isolated
  configuration and are not channel-originated operator turns; the guard MUST NOT
  interfere with them (they are not channel turns → fail open).
- **Multiple questions in one prompt**: The interactive tool can carry several
  questions at once; the redirection MUST convey all of them to the channel, not just
  the first.
- **Interaction with the 028 reply guard**: A turn that this guard has already
  steered toward the reply tool must still satisfy 028 (a reply is delivered). The
  two guards MUST NOT cross-fire or double-count against each other.
- **Local mode**: The relay session in local mode has no channel reply tool; define
  the guard as inert there (see Assumptions), never blocking a local console prompt.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: When a channel-originated turn attempts the interactive-prompt tool
  (`AskUserQuestion`), the system MUST intercept the attempt before it blocks and
  cause the agent to deliver its question(s) to the operator through the channel
  reply tool instead of the console-only prompt. The interception MUST work by
  returning a redirect instruction to the agent (agent-driven); the guard itself MUST
  NOT need to post the question to the channel, so no new channel-send capability is
  introduced in the interception path (Clarification 2026-08-19).
- **FR-002**: The number of **redirections** MUST be bounded to at most a configured
  maximum per turn (default 1). Once the maximum is reached the system MUST stop
  redirecting and MUST NOT enter an unbounded redirect → retry → redirect loop; because
  the pre-invocation hook exposes no platform re-entrancy signal (measured, Phase 0), a
  per-turn redirection counter is the bound. On a confirmed channel turn the
  console-only prompt MUST NEVER be allowed to open — at the cap the system MUST switch
  to a terminal decision that keeps the prompt from opening (so the turn never hangs)
  while telling the agent to stop retrying the tool, rather than fall through to the
  prompt. On reaching the maximum, the operator MUST receive exactly one explicit
  give-up message in the channel stating that an unsupported interactive prompt was
  attempted, so a give-up never leaves the operator in silence. That message MUST be
  delivered through the channel's existing send path (the same one that emits the
  typing-timeout warning) rather than by the model, so it is delivered even when the
  model no longer complies and introduces no new privilege (Clarification 2026-08-19).
- **FR-003**: The system MUST NOT interfere with the interactive-prompt tool in turns
  that did not originate from a channel (console / interactive turns); such a prompt
  MUST proceed and function normally.
- **FR-004**: The system MUST derive, from data available at interception time,
  whether the current turn originated from a channel. If that origin signal cannot be
  reliably obtained, the guard MUST FAIL OPEN (allow the prompt) — it MUST NEVER block
  a prompt whose turn origin it cannot confirm is a channel.
- **FR-005**: The guard MUST coexist with the existing typing-indicator behaviour and
  with the 028 reply-delivery guard; it MUST NOT remove or replace either. The three
  are layered: this guard intercepts mid-turn (before the prompt blocks), the 028
  guard acts at turn-end, and the typing indicator is the last-resort signal.
- **FR-006**: The guard MUST NOT break local mode (systemd `--spawn=session`) or
  docker mode, and MUST degrade gracefully (fail-silent) — it MUST NOT be able to
  crash the interactive session or the container supervisor. Where the channel reply
  tool does not exist (local relay), the guard MUST be inert.
- **FR-007**: Any operator-facing toggle governing the guard (enable/disable, maximum
  redirections) MUST be sourced from `agent.yml` and MUST survive `./setup.sh
  --regenerate` (single source of truth). The guard MUST be enabled by default for any
  agent configured with a Telegram channel and disableable via `agent.yml`; existing
  agents adopt it at their next `--regenerate`, with full activation on the agent's
  next restart (the channel through which the launcher re-applies its managed
  settings).
- **FR-008**: Each time the guard intercepts and redirects, it MUST emit one log line
  to the channel plugin's stderr log (the same sink as the typing-indicator
  instrumentation). The only chat output attributable to the guard is the single
  give-up message after the maximum redirections (FR-002); the redirected question(s)
  themselves reach the chat because the agent delivers them through the reply tool, not
  because the guard posts them. The guard MUST NOT write secrets or transcript contents
  to the log.
- **FR-009**: The typing-timeout warning message MUST additionally name the
  "blocked in an interactive prompt the channel cannot answer" possibility among its
  existing causes, and MUST still not assert any single definite cause.
- **FR-010**: The guard's behaviour MUST be covered by host-runnable `bats` tests
  including at minimum: (a) channel turn calling the interactive prompt → intercepted
  and redirected; (b) console turn calling the interactive prompt → never fires
  (proceeds); (c) origin signal absent → fails open (proceeds); (d) loop guard →
  after the maximum redirections, stops redirecting and issues the terminal give-up
  decision (the prompt never opens; no unbounded loop); (e) give-up path →
  after the maximum redirections, exactly one give-up message is produced for the
  operator.
- **FR-011**: User-facing changes MUST be recorded in `CHANGELOG.md` and reflected in
  the Telegram section of `README.md`; the launcher `VERSION` MUST be bumped per the
  project's versioning discipline (verified against `origin/main` before release).

### Key Entities *(include if feature involves data)*

- **Interception signal**: The information available when the agent is about to
  invoke a tool, carrying the tool name and (if feasible) the turn's origin and a
  re-entrancy marker. The authoritative fields are UNVERIFIED and are the subject of
  the feasibility gate.
- **Turn origin**: Whether the in-progress turn came from the channel (an operator
  message) or from the console / an autonomous tick. Drives whether the guard is
  eligible to fire at all; when unknown, forces fail-open.
- **Interactive-prompt tool call**: The record that the console-only selection tool
  (`AskUserQuestion`) is being invoked during the turn — the event the guard
  intercepts.
- **Redirection counter (loop guard)**: The per-turn bound on interceptions that
  guarantees termination and prevents an infinite intercept → retry loop.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: For a channel turn in which the agent calls the interactive-prompt
  tool, the operator receives — within the same session and with zero manual
  intervention — either the redirected question(s) through the channel or, if the agent
  never complies within the bounded redirections, one explicit give-up message. The
  turn never again hangs invisibly on a console-only prompt.
- **SC-002**: Across the test matrix, the guard performs zero interceptions on
  (a) console / interactive turns and (b) turns whose channel origin cannot be
  confirmed — a legitimate console interactive prompt always proceeds (no false
  block).
- **SC-003**: No channel turn triggers more than the configured maximum redirections;
  after the maximum the guard issues no further redirections (bounded, no infinite
  loop) yet the console-only prompt still never opens, so the turn settles without
  hanging and leaves an explicit trace.
- **SC-004**: An operator reading the typing-timeout warning can see the
  interactive-prompt cause named among the possibilities, and the message still
  asserts no single definite cause.
- **SC-005**: The default host `bats` suite (bash 3.2 and 5.x) passes with the new
  tests and requires no Docker daemon; any docker-image-scoped portion is gated behind
  `DOCKER_E2E=1` and is not required for the default suite.
- **SC-006**: Re-running `./setup.sh --regenerate` reproduces the guard's rendered
  configuration byte-for-byte from `agent.yml` (no hand-authored drift); an agent with
  no channel configured gains no guard behaviour.
- **SC-007**: When the guard fires, its action is visible in the channel plugin's
  stderr log (one line per interception), and the only chat output attributable to the
  guard is the single give-up message after the maximum redirections — the redirected
  question(s) reach the chat via the agent's own reply-tool call, not the guard.

## Assumptions

- **Feasibility / research gate (NOT to be papered over)**: It is UNVERIFIED that a
  pre-invocation hook fires for the `AskUserQuestion` tool in the pinned Claude Code
  version, that its payload/context allows determining the turn's channel origin, and
  that such a hook can prevent the tool from opening while returning a reason the
  agent acts on (redirect). Planning MUST first dump the REAL pre-invocation payload
  for `AskUserQuestion` on a representative setup and confirm the deny/redirect
  contract and the origin signal. If none of this is viable, the feature is HALTED and
  reported — no implementation proceeds on a guessed signal. FR-004 encodes the
  fail-open default if the origin signal is only sometimes available.
- **Origin signal reuse**: The likeliest origin signal is the 028 `pending-reply.json`
  marker (written on inbound by the Telegram plugin, deleted on reply). Because the
  turn has not ended when the interactive prompt is attempted, the marker is expected
  to still be present — its presence indicating a channel-originated, in-flight turn.
  This is a strong design lead to confirm in Phase 0, not a settled fact.
- **Fail-open direction (deliberate, opposite of 028)**: When origin is uncertain the
  guard allows the prompt. Rationale: a false block breaks a normal, supported console
  workflow, whereas a false allow reproduces only the pre-existing channel-hang, which
  the typing-timeout warning (US2) still covers. Availability of the console workflow
  outranks catching every channel-hang.
- **Anticipated, not measured**: Unlike 028 (which had a forensic ferrari capture),
  there is no captured incident log for the `AskUserQuestion` case specifically. It is
  a failure mode of the same class and subsystem (a console-only blocking prompt inside
  a channel turn), consistent with the measured behaviour; its exact mechanism is
  confirmed in Phase 0.
- **Channel scope**: The only channel in use today is Telegram; the channel reply tool
  is `plugin:telegram:telegram`. The design is channel-generic but validated against
  Telegram.
- **Default maximum redirections = 1** (redirect once, then give up) — chosen as the
  safest default against loops and to mirror the 028 guard; operator-tunable via
  `agent.yml`.
- **Guard applicability & default state**: The guard applies to the interactive
  channel session (operator turns), not to autonomous heartbeat cron ticks (isolated
  configuration). It is enabled by default for agents configured with a Telegram
  channel and can be disabled via `agent.yml`; existing agents adopt it at their next
  `--regenerate`.
- **Redirection content (agent-driven, confirmed 2026-08-19)**: The redirection is a
  single instruction telling the agent it attempted a console-only prompt the channel
  operator cannot answer, and to ask the same question(s) through the reply tool now.
  The guard does NOT send the question to the channel itself; delivery is the agent's
  own reply-tool call. Neither the redirect nor the give-up message adds a new
  channel-send capability to the guard: the redirect is model-driven, and the give-up
  message reuses the plugin's existing send path (the same one that already emits the
  typing-timeout warning), which keeps Principle II (least privilege) intact. Whether
  the give-up message and the US2 warning enhancement share one plugin-side code path
  is a planning decision. Exact wording is an implementation detail, not a spec-level
  decision.
- **Typing-message scope**: The US2 message improvement lives in the image-baked
  Telegram plugin patch and therefore takes effect on an image rebuild (docker scope);
  it does not change local-mode behaviour.
- **Configuration shape is a planning decision**: Whether the toggle is a new
  `features.*` block or folds under the existing 028 `features.reply_guard`, and which
  of the three code paths hosts the guard and how it is installed, is resolved in
  planning under Principle I. This guard uses a NEW hook event (pre-invocation) that
  the launcher does not use yet, though it can reuse the 028 hook-installation surface.

## Dependencies

- The 028 reply-guard's hook-installation mechanism and its `pending-reply.json`
  origin marker — 031 is expected to reuse both (confirmed in Phase 0).
- The existing Telegram plugin typing patch (currently at v5) — US2 extends its
  warning message; US1 must coexist with, not replace, its typing behaviour.
- The channel plugin and its reply tool (`plugin:telegram:telegram`) as the delivery
  path the guard redirects the agent onto.
- `agent.yml` as the single source of truth for any new toggle (Principle I).
