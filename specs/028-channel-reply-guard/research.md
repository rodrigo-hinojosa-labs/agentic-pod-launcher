# Phase 0 Research: Channel reply-delivery guard (028)

**Date**: 2026-08-08 · **Branch**: `028-channel-reply-guard`

This document resolves the spec's feasibility gate and the mechanism/hosting
unknowns with MEASURED evidence (a real Stop-hook payload captured on this host,
the actual Telegram plugin patch, the render/boot pipeline) plus a scoped
delegated survey (workflow `wf_2514c313-f6f`, 3/4 agents; the channel-scope agent
failed the schema and was reconstructed from direct reads).

---

## Gate result: FEASIBLE, with a forced two-part mechanism

**The Stop-hook payload alone cannot tell a channel turn from a console turn.**
Captured on this host (nested `claude -p` with an injected Stop hook via
`--settings`; the hook `cat > payload.json` on its stdin):

```json
{
  "session_id": "…", "transcript_path": "…", "cwd": "…", "prompt_id": "…",
  "permission_mode": "auto", "effort": {"level": "…"},
  "hook_event_name": "Stop", "stop_hook_active": false,
  "last_assistant_message": "ok", "background_tasks": [], "session_crons": []
}
```

- **No origin field.** Nothing says "this turn came from Telegram vs the console".
- **`last_assistant_message`** carries the FULL final assistant text — in the bug
  this is the answer that was written but never sent.
- **`stop_hook_active`** is the native loop guard (false on the first Stop).
- **`transcript_path`** is the fallback signal source.

The transcript records per-turn `userType` / `entrypoint` / `promptSource`, so
origin *might* be inferable there — but the value a Telegram-injected turn gets is
UNVERIFIED (this host has no channel session; only donna/rodri on ferrari do).

**Conclusion**: origin can only come from the component that KNOWS origin — the
Telegram plugin, which injected the message. The guard is therefore a cooperation
between two parts, and neither alone is sufficient:

| Signal needed | Who can provide it | Why not the other |
| --- | --- | --- |
| "This turn came from the channel and no reply was sent" | **Plugin** (it injected + tracks reply) | The Stop-hook payload has no origin; the transcript field is unverified/undocumented and could drift |
| "The turn just ENDED (fire now, not after a 5-min timeout)" | **Stop hook** (fires at turn-end) | The plugin only learns "no reply" via its 5-min typing cap — far too slow |

---

## Decision 1 — Mechanism: cooperative plugin-marker + Stop-hook re-injection

**Decision**: A disk **pending-reply marker** owned by the Telegram plugin is the
origin+unreplied signal; a **Stop hook** consumes it at turn-end and re-injects a
corrective instruction (does not deliver the message itself).

- **Plugin (image-baked `server.ts` patch)**: on inbound (`_markPending`), also
  write `<state>/channels/telegram/pending-reply.json` = `{chat_id, update_id, ts}`;
  on reply (`case 'reply'` → `_ackPending`), delete it. This mirrors the existing
  offset-persistence hunk exactly (same file family, same ack-on-reply timing).
  The marker's existence at any instant means "a channel message is awaiting a
  reply" — it is cleared the moment the reply tool fires.
- **Stop hook (`scripts/hooks/stop-redeliver.sh`)**: reads the payload; if the
  pending-reply marker exists AND `stop_hook_active == false` → emit
  `{"decision":"block","reason":"<instruct the agent to resend its last answer via
  plugin:telegram:telegram now>"}` (exit 0) and log one line to the plugin stderr
  sink; if `stop_hook_active == true` → exit 0 (already nudged once → give up, loop
  guard); if the marker is absent → exit 0 (console / already replied / local).
  **Any error → exit 0** (fail-silent; Principle IV).

**Rationale**:
- Re-injection via `{decision:"block", reason}` matches the spec ("re-inject to
  force the agent to send through the tool", FR-001) and the clarified decisions
  (max_attempts=1, log to stderr). The agent already holds the answer in context;
  it just needs the nudge to call the tool.
- The marker is a *controllable fixture* → the four required bats cases (FR-010)
  are host-testable deterministically without a live channel.
- Marker-cleared-on-reply means "exists ⟺ unreplied", so the hook's core decision
  is a single file-existence check — minimal, fail-silent, no transcript parsing
  required for the go/no-go.

**Alternatives considered**:
- **Pure Stop-hook, origin from the transcript** (no plugin change). Rejected as
  the primary design: depends on an UNVERIFIED, undocumented transcript origin
  field that could silently drift (violates the "don't trust docs / no silent
  drift" posture). Kept as a *leaner variant* to adopt IF a live-host check
  (Decision 5) confirms a stable origin field on a Telegram-injected turn.
- **Hook delivers `last_assistant_message` itself via the bot API** (bypass the
  agent). Rejected as primary: needs the bot token + chat_id inside the hook
  (secret handling), duplicates the plugin's send path, and ships raw TUI text
  instead of the agent's tool-formatted reply. Kept as a documented fallback if
  agent compliance with the nudge proves unreliable in practice.
- **Guard entirely inside the plugin** (no Stop hook). Rejected: the plugin has no
  fast turn-end event — it can only infer "no reply" from its 5-min typing cap,
  which is far too slow for a corrective re-inject.

**Residual to verify on a live host (not on this Mac)**: the exact
`{decision:"block", reason}` continuation and `stop_hook_active` cap behaviour in
the container's Claude Code build (the shape `{hooks:[{type:"command",command}]}`
is already proven to FIRE — measured in the capture; the block/loop semantics are
from docs + one measured `stop_hook_active:false`).

---

## Decision 2 — US2 message fix: bump typing patch v4 → v5

**Decision**: Rewrite the timeout warning to stop asserting OAuth, and ship it as a
new patch version `v5` with a `upgrade_typing_v4_to_v5` step in the cascade.

- Current string (`apply_telegram_typing_patch.py`, `TYPING_HELPERS`, line 139):
  `⚠️ Tardé más de ${minutes} min en responder. Es probable que el OAuth de Claude
  haya expirado o haya un error de conectividad. Revisa: agentctl doctor.`
- New wording states uncertainty (FR-009): the delay may be a slow turn, an answer
  produced **without calling the reply tool**, or an expired login — and points to
  `agentctl doctor`.

**Rationale**: the patch's idempotency is marker-based (`MARKER_TYPING = "…v4"`).
Changing only the string would NOT re-patch an already-v4 agent (`apply_typing`
short-circuits on the v4 marker and there is no v4→v5 upgrader). The established
pattern (v1→v2→v3→v4, `apply_telegram_typing_patch.py:662-671`) is to bump the
marker and add an in-place upgrader so already-patched agents ratchet up on the
next boot. So US2 = new `MARKER_TYPING = "…v5"`, updated `TYPING_HELPERS` message,
`MARKER_TYPING_V4` constant + `upgrade_typing_v3_to_v4` rewired to stamp v4, new
`upgrade_typing_v4_to_v5`, and the cascade extended in `main()`.

**Alternatives considered**: edit the string in place without a version bump —
rejected, breaks the marker idempotency contract (already-v4 agents never update).

**Scope**: image-baked (`docker/scripts/apply_telegram_typing_patch.py`). The
transform is host-testable via `tests/apply-telegram-patches.bats` (no Docker);
end-to-end boot re-application is DOCKER_E2E.

---

## Decision 3 — Hosting: script workspace-templated, config per-mode boot/login merge

**Decision** (from the hosting survey, confirmed against the code):

1. **Hook script** = workspace-templated (code path 3). New
   `modules/stop-hook.sh.tpl` rendered by `regenerate()` to
   `<workspace>/scripts/hooks/stop-redeliver.sh`, mirroring how
   `modules/local-session-stop.sh.tpl` renders to `scripts/local/agent-session-stop.sh`
   (`setup.sh:2325`). Refreshed on every `--regenerate` (Principle I). Reaches the
   container via the `./:/workspace` bind-mount (`docker-compose.yml.tpl:54-55`).
2. **Hook config** (the `settings.json` `hooks.Stop` entry) = merged into the USER
   `settings.json` BEFORE the session starts, per mode, with an **additive jq that
   only touches `.hooks.Stop`**:
   - **docker**: new `pre_install_stop_hook()` in `docker/scripts/start_services.sh`,
     called in `start_session()` right after `pre_accept_bypass_permissions`
     (`:770`) — runs on boot AND every watchdog respawn (idempotent, self-healing).
   - **local**: the same jq merge added to `modules/local-login.sh.tpl`
     (rendered `agent-login.sh`), writing to `<workspace>/.state/.claude/settings.json`;
     durable under `.state`, survives `systemctl restart`.

**Rationale**:
- The additive jq shares NO top-level key with `pre_accept_bypass_permissions`
  (`.skipDangerousModePermissionPrompt`/`.permissions`),
  `pre_accept_extra_marketplaces` (`.extraKnownMarketplaces`), or heartbeat
  (`.enabledPlugins`), and jq emits the whole object → no clobber, pre-existing
  hooks preserved.
- **Why USER settings, not a project `<workspace>/.claude/settings.json`**: Claude
  Code treats a newly-appeared *project-scoped* hook as requiring interactive
  approval — a headless container has nobody to approve it. Merging into the user
  settings before startup registers the hook as trusted config. (One measured data
  point supports this: the capture used `--settings` = user-level and the hook
  fired without prompt.)

**Command path**: render the **absolute** command per mode (docker
`/workspace/scripts/hooks/stop-redeliver.sh`; local
`{{DEPLOYMENT_WORKSPACE}}/scripts/hooks/stop-redeliver.sh`) rather than depend on
`$CLAUDE_PROJECT_DIR` at hook time (that env var is a documented Claude Code
feature but UNVERIFIED in this session — the absolute path removes the unknown).

**Regenerate-safety**: script re-rendered on `--regenerate`; config re-applied
deterministically on every boot/login (never stored/hand-edited). Gate the render +
injection on Telegram-plugin presence so non-channel agents stay byte-identical
(FR-012 precedent from 027).

---

## Decision 4 — Heartbeat isolation must drop the hook (leak found)

**Decision**: extend the heartbeat config-dir isolation jq
(`scripts/heartbeat/heartbeat.sh:146`) from
`.enabledPlugins = {} | .extraKnownMarketplaces = {}` to also `del(.hooks.Stop)`,
AND make the hook script strictly fail-silent so a stray fire is a harmless no-op.

**Rationale**: `ensure_heartbeat_config_dir` builds the isolated cron config by
copying the shared `settings.json` and blanking plugins/marketplaces — but it
PRESERVES `.hooks.Stop`. Heartbeat runs `claude --print` with the Telegram plugin
disabled, so the redelivery hook would fire on cron ticks with no channel and no
pending marker. Belt-and-suspenders: drop the hook in the isolation jq (primary)
AND the hook no-ops when the marker is absent (which it always is under heartbeat).

---

## Decision 5 — agent.yml toggle: `features.reply_guard`

**Decision**: `features.reply_guard: {enabled: <bool>, max_attempts: <int>}` under
the existing `features:` block, mirroring `features.heartbeat`.

- `render_load_context` auto-flattens to `FEATURES_REPLY_GUARD_ENABLED` /
  `FEATURES_REPLY_GUARD_MAX_ATTEMPTS` (fixture-produced, NOT `known_external`).
- **On-by-default** derived from Telegram-**plugin** presence in `plugins[]`
  (`yq -r '.plugins[]?' | grep -qE '^telegram@'`), NOT `notifications.channel`
  (that is the one-way heartbeat notifier — a different subsystem). Since telegram
  is a mandatory default plugin, a fresh scaffold always gets `enabled: true`.
- **Backfill** in `regenerate()` inside the `[ -f "$agent_yml" ]` block BEFORE
  `render_load_context` (`setup.sh:2041`), alongside the existing
  `deployment.mode` / `session_name` / `vault.qmd.version` backfills → survives
  `--regenerate` and reaches legacy/hand-edited agents.
- **No wizard prompt** (telegram is mandatory-default, so the answer is ~always
  "yes"): keeps it a section key with fixture-carried vars and avoids the three
  heaviest test touchpoints (`wizard_answers`, `e2e-smoke` array, `known_external`).
- `max_attempts` default **1** (clarified). `_SCHEMA_BOOLEANS` gains
  `.features.reply_guard.enabled`; `max_attempts` stays out of required leaves
  (optional/backfilled, like `vault.qmd.version`).

**Test touchpoints (measured, `agentyml-tests` agent)**:
- MUST add `features.reply_guard` to `tests/fixtures/sample-agent-with-vault.yml`
  (the `schema.bats:52` placeholder test renders that fixture and greps every
  `{{VAR}}` in `modules/*.tpl`).
- SHOULD add `.features.reply_guard.enabled` to `_SCHEMA_BOOLEANS`
  (`scripts/lib/schema.sh:65-71`).
- SHOULD add `features.reply_guard` to `tests/fixtures/sample-agent.yml` for shape
  consistency.
- Top-level-keys test (`schema.bats:21`) is UNAFFECTED (reply_guard lives under the
  already-present `features` key).

---

## Channel scope (docker Telegram vs local relay) — reconstructed

(The delegated channel-scope agent failed its schema; reconstructed from CLAUDE.md
+ the patch + the wiring.)

- **Docker**: the Telegram channel delivers operator messages via
  `bun server.ts` (the plugin) as MCP notifications into the claude session; the
  agent replies with the `plugin:telegram:telegram` tool. This is where the
  measured bug lives, and where the pending-reply marker + redelivery logic are
  real.
- **Local**: the interactive channel is the claude.ai **remote-control relay**, not
  the Telegram plugin, and its reply path is the relay — NOT a
  `plugin:telegram:telegram` tool call. So the specific "answered without the tool"
  failure is inherently docker/Telegram. In local mode the guard is installed for
  uniformity but is **present-but-inert**: no Telegram plugin → no pending-reply
  marker → the hook always no-ops (fail-silent). A local agent that *does* enable
  the telegram plugin would get real behaviour; the relay's own failure mode is out
  of scope for 028.
- **Heartbeat**: isolated `CLAUDE_CONFIG_DIR` (`~/.claude-heartbeat`), plugins
  disabled — see Decision 4 (drop the hook in isolation + no-op on absent marker).

---

## Open items carried into implementation

1. **Live-host verification (donna/rodri, docker+Telegram)** before/at implement:
   confirm `{decision:"block", reason}` re-injects and `stop_hook_active` caps the
   loop in the container's Claude Code build; and (optional) whether the transcript
   marks Telegram origin (would enable the leaner no-plugin-change variant of
   Decision 1). This is the spec's feasibility gate's live tail — the host-testable
   parts do not depend on it.
2. **Console-turn stale-marker edge**: a marker left by a previously unanswered
   channel message could, in principle, make the hook fire on a later console turn.
   The four required tests use "console turn = no marker = no fire", which is the
   common case; hardening (correlate the marker `ts`/`update_id` to the current
   turn, or clear the marker on give-up) is a task-level refinement to honour FR-003
   under a stale marker.
3. **max_attempts > 1** needs an attempt counter beyond `stop_hook_active` (a small
   per-turn state file); the default 1 needs only `stop_hook_active`.
