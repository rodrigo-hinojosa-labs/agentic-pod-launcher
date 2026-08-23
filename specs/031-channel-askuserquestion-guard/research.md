# Phase 0 Research: Channel interactive-prompt (AskUserQuestion) guard

**Feature**: 031-channel-askuserquestion-guard
**Date**: 2026-08-19
**Constitution**: v1.0.1 (6/6 PASS — see plan.md Constitution Check)

The spec's central risk was a feasibility gate that MUST be measured, not assumed:
does a hook fire before `AskUserQuestion` blocks, can it deny + redirect, and can the
turn's channel origin be determined? This document records what was **measured on
this host** (real Claude Code **2.1.223**, ≈ the image-pinned ~2.1.220) plus what was
**read in-repo** from the merged 028 implementation that 031 reuses.

---

## D0 — FEASIBILITY GATE (measured, not inferred) — RESOLVED POSITIVE

### The doubt

A documentation-oriented consult claimed "`AskUserQuestion` does NOT fire
`PreToolUse`". If true, the whole PreToolUse design collapses. The spec explicitly
forbade trusting documentation here and demanded a real payload dump. That claim was
**refuted by direct measurement.**

### Measurement setup

- Real binary `/Users/rodrigo-hinojosa/.local/bin/claude` (the host `claude` is a
  shell alias to a warning; the real bin is **2.1.223**, one patch off the image's
  ~2.1.220 → representative).
- Isolated, non-destructive: `CLAUDE_CONFIG_DIR=~/.claude-personal` for auth +
  `--settings <tempfile>` layering a `PreToolUse` hook. No config file was modified;
  the hook applied only to the child invocation. This is the same technique 028 used
  to capture its Stop-hook payload.
- The hook dumped the stdin payload + `tool_name` and returned a deny decision.

### Results

1. **Hook infra fires (control)**: `claude -p "use the Bash tool…"` →
   `FIRED tool_name=Bash`, and the model reported the command was *"bloqueado por un
   hook… no se ejecutó"* and answered in text. So `PreToolUse` fires and its **deny +
   reason reaches the model**, which changes course.
2. **`-p` headless does NOT expose `AskUserQuestion`** (it is interactive-only). Two
   headless attempts failed with *"AskUserQuestion no está disponible en esta
   sesión"* / deferred-tool-not-found. This is why the measurement had to be done in
   an **interactive** session (a PTY), which is the agent's real mode
   (`claude --channels` in tmux), not `-p`.
3. **PreToolUse FIRES for `AskUserQuestion` (interactive, PTY)**: driving an
   interactive `claude` over a pty and prompting it to call the tool produced
   `FIRED tool_name=AskUserQuestion`. The deny then surfaced in the TUI as
   *"Error: blocked by measurement hook — respond in text instead"*, and the model
   **redirected on its own to asking the question as plain text** ("la llamada a
   AskUserQuestion fue bloqueada por un hook… así que la planteo directamente aquí.
   Responde con A o B"). That is exactly the 031 behaviour, end to end.

### Real PreToolUse(AskUserQuestion) payload shape (captured, keys only)

```
cwd, effort, hook_event_name="PreToolUse", permission_mode, prompt_id,
session_id, tool_input{questions:[…]}, tool_name="AskUserQuestion",
tool_use_id, transcript_path
```

- **No origin field.** Nothing distinguishes a channel turn from a console turn — the
  same finding 028 measured for the Stop payload. Origin MUST come from elsewhere (D2).
- `permission_mode` was **`auto`** — the exact mode the chat-driven agent runs in, so
  a live agent's payload matches this capture.
- `prompt_id`, `session_id`, `tool_use_id` are present → usable as the loop-guard key
  (D4).

**Decision**: The PreToolUse mechanism is VIABLE. Build proceeds. The one residual is
that this was measured on 2.1.223, not on the exact image build; the DOCKER_E2E gate
re-confirms it on the pinned image (Development Workflow gate, see D7).

**Rationale**: Measured, reproducible, matches the agent's `auto` mode. The refuted
doc claim is precisely why the spec mandated measurement.

**Alternatives considered**: (a) Trust the doc claim and HALT — rejected, the claim
was false. (b) A `Stop`-hook-only approach like 028 — rejected, a turn blocked in the
interactive prompt never reaches `Stop` (the whole reason 031 exists). (c) Patch the
plugin to detect the block — rejected, the plugin cannot see the TUI prompt; the hook
is the only layer that sees the tool call before it blocks.

---

## D1 — Origin signal: reuse the 028 `pending-reply.json` marker

**Decision**: Determine "this turn is channel-originated" by the presence of the 028
marker `${HOME}/.claude/channels/telegram/pending-reply.json`.

**Evidence (in-repo)**: `docker/scripts/apply_telegram_typing_patch.py` (patch group
`MARKER_PENDING`, hunks at `:263-294`) makes the plugin write the marker **on inbound**
and delete it **on the reply tool**. Because a turn blocked in `AskUserQuestion` has
**not ended** (and has not replied), the marker is **still present** at PreToolUse
time for a channel turn. `modules/stop-hook.sh.tpl:30-37` already reads exactly this
file as its origin+unreplied signal. 031 reuses the identical check.

**Rationale**: Zero new origin mechanism; one deterministic file check; consistent
with the merged sibling. Absent marker ⇒ console / local relay / already-replied ⇒
the guard must not fire.

**Alternatives**: Parse `transcript_path` to infer origin — rejected as heavier and
redundant now that the marker exists and is proven alive mid-turn.

---

## D2 — FAIL-OPEN direction (opposite of 028)

**Decision**: When the marker is absent or unreadable, the guard **allows** the
prompt (does nothing). It only ever intercepts when the marker is present.

**Rationale**: A false block would break a legitimate **console** `AskUserQuestion`
(a normal, supported flow — this very launcher session uses it constantly), which is
worse than a false allow (a channel turn hangs, the pre-existing behaviour, still
covered by the typing-timeout warning US2). This is the inverse of 028's fail-safe,
by design, and is stated in spec FR-004 / SC-002 / Edge Cases so it cannot be
silently reversed.

---

## D3 — Deny + redirect contract (agent-driven, no new privilege)

**Decision**: On a channel turn, the hook returns exit 0 with
`{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny",
"permissionDecisionReason":"<redirect text>"}}`. The reason instructs the agent to ask
its question(s) through `plugin:telegram:telegram` instead. The guard itself never
posts to the channel (Clarification Q1).

**Evidence**: Measured (D0) — the deny blocked the tool and the reason reached the
model, which redirected to text. `permissionDecision:"deny"` is the current contract
for 2.1.223 and exposes the reason to the model (also corroborated by the docs
consult). The legacy `{"decision":"block"}` (what 028's Stop hook emits) is a Stop-hook
shape; for PreToolUse the `hookSpecificOutput.permissionDecision` form is the correct
one.

**Rationale**: Best-effort, bounded, and privilege-free — the model performs the
delivery via the existing reply tool. Mirrors 028's cooperative philosophy.

**Alternatives**: exit-code-2 + stderr (also blocks, but the reason is not as cleanly
surfaced to the model) — kept as a fallback string only.

---

## D4 — Loop guard: own per-prompt counter (no `stop_hook_active`)

**Decision**: PreToolUse has **no** `stop_hook_active` re-entrancy flag (that is a
Stop-hook field). 031 keeps its own attempt counter keyed by `prompt_id` (falling back
to `session_id`) under `${state}/askq-guard-attempts/<key>`, capped at
`max_attempts` (default 1). Same counter pattern as `modules/stop-hook.sh.tpl:52-63`
for its `max>1` branch.

**Evidence**: Measured payload carries `prompt_id`, `session_id`, `tool_use_id`. The
docs consult and the absence of `stop_hook_active` in the captured payload both
confirm no built-in re-entrancy for PreToolUse.

**Rationale**: A deny that keeps firing on every retry is an infinite intercept→retry
loop; the counter bounds it. On reaching the cap the guard triggers give-up (D5).

---

## D5 — Give-up path: signal a marker; the plugin sends (Q2 + no new privilege)

**Decision**: On reaching `max_attempts`, the hook writes a small **give-up marker**
(e.g. `${state}/askq-guard-giveup.json` with `chat_id` + prompt id) and stops
intercepting for that turn. The **plugin-side patch** (which already owns the channel
send path) detects the marker and delivers one explicit chat message to the operator,
then clears it. This unifies with US2: the same typing keep-alive that already calls
`bot.api.sendMessage(chat_id, warnMsg)` (`apply_telegram_typing_patch.py:165`) is the
natural place to check the give-up marker and to name the interactive-prompt cause.

**Evidence**: The plugin already sends to the channel via `bot.api.sendMessage`
(measured location in the patcher). The hook (a separate as-`agent` process) has no
channel-send capability and must NOT gain one (Q1) — so the split hook-writes-marker /
plugin-reads-marker keeps Principle II intact while making delivery deterministic
(plugin-side, independent of whether the model complies).

**Rationale**: Satisfies Q2 (operator never in silence on give-up) and Q1 (no new
privilege in the guard) simultaneously. Mirrors the existing marker-coordination
between the hook and the plugin (028's `pending-reply.json`).

**Open for planning**: whether the give-up message and the US2 warning are literally
one code path or two adjacent ones is a detail resolved in tasks; both live in the
image-baked patcher.

---

## D6 — US2: bump the typing warning v5 → v6

**Decision**: Add "blocked in an interactive prompt the channel can't answer" to the
typing-timeout warning's list of causes via a new `upgrade_typing_v5_to_v6` in
`apply_telegram_typing_patch.py`, bumping `MARKER_TYPING` to v6, idempotent, fail-silent
on anchor drift — the exact cascade pattern used for v4→v5 (`:522`).

**Evidence**: `apply_telegram_typing_patch.py:67` `MARKER_TYPING = "…v5"`; the warning
string is the `warnMsg` around `:114-121`; upgraders `upgrade_typing_vN_to_vN+1` at
`:357-522`. The cascade `v1→…→v5` runs on every boot; adding v6 ratchets existing
agents up transparently.

**Rationale**: Same proven, idempotent upgrade mechanism; docker-scoped (image-baked),
takes effect on rebuild.

---

## D7 — Hosting, install, config, and the DOCKER_E2E requirement

**Decision (hosting/install)**: 031 renders a new hook script
`modules/askq-guard.sh.tpl` → `scripts/hooks/askq-guard.sh` and registers it in
`settings.json` under `.hooks.PreToolUse` with `matcher:"AskUserQuestion"`. The install
merge reuses the 028 pattern; because 028's `install-stop-hook.sh` is hardcoded to
`.hooks.Stop`, the plan generalizes the installer (event + optional matcher args) OR
adds a sibling `install-pretooluse-hook.sh` — decided in tasks, but the additive,
idempotent jq merge shape is identical to `modules/stop-hook-install.sh.tpl:28-33`.
Install is invoked from the same two places as 028:
`start_services.sh::pre_install_stop_hook` (docker) and `agent-login.sh` (local).

**Decision (config)**: A new `features.askuserquestion_guard.{enabled,max_attempts}`
block, mirroring 028's `features.reply_guard` exactly: heredoc default in `setup.sh`
(`:1230` region), `has()`-guarded backfill in `regenerate()` (`:2072-2083` pattern,
NOT `//`), `enabled` derived from the Telegram plugin's presence in `plugins[]`,
rendered hook gated on `FEATURES_ASKUSERQUESTION_GUARD_ENABLED` (`:2337-2345` pattern).
A separate block (not folding under `reply_guard`) keeps the two guards independently
toggleable and their tests independent.

**Decision (DOCKER_E2E)**: REQUIRED. The feature touches image-baked
`apply_telegram_typing_patch.py` (US2 v6) and the boot install in
`start_services.sh`. Per Principle III + the Development Workflow gate, a
`DOCKER_E2E=1` test re-confirms, on the pinned image, that (a) the PreToolUse hook is
registered at boot and (b) the v6 warning renders. The interactive AUQ interception
itself is validated on the host by the measurement above + host bats over the hook
script with fixture payloads; the live-agent interception is the ferrari deploy gate.

**Rationale**: Single source of truth (Principle I), least privilege intact (Principle
II — no cap/mount/socket, hook runs as `agent`, no channel-send in the hook), test-first
host-runnable + Docker-gated (Principle III), idempotent fail-silent (Principle IV).

---

## Constitution re-check (post-research): 6/6 PASS

- **I** — config in `agent.yml`, hook rendered by `--regenerate`; survives regenerate.
- **II** — NO new capability/mount/socket; hook runs as `agent`; the guard never gains
  channel-send (give-up delivered by the plugin's existing path). NON-NEGOTIABLE intact.
- **III** — host bats over the hook script (fixture payloads) + DOCKER_E2E gated;
  `shellcheck -S error`; sourced install lib guarded.
- **IV** — hook fail-silent (exit 0 every path, like 028), idempotent install (jq merge
  keyed on command), typing upgrade idempotent by version marker.
- **V** — marker + counter under `.state`-backed `~/.claude/channels/telegram/`; no
  secrets logged; backup branches untouched.
- **VI** — no new pins; CHANGELOG + VERSION bump (MINOR, 0.21.0 → 0.22.0, verified vs
  origin/main before release).
