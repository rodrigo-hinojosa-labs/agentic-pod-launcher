# Implementation Plan: Channel reply-delivery guard

**Branch**: `028-channel-reply-guard` | **Date**: 2026-08-08 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `specs/028-channel-reply-guard/spec.md`

## Summary

A live, healthy Telegram (docker) agent can finish a turn having written its answer
as plain TUI text instead of calling `plugin:telegram:telegram`, so the reply never
leaves the container; the typing indicator then fires a misleading "OAuth expired"
warning. The fix is a **deterministic reply-delivery guard**, not more prompt:

- **US1** — a cooperative guard. The Telegram plugin persists a **pending-reply
  marker** (write on inbound, delete on reply) as the channel-origin + unreplied
  signal; a **Stop hook** fires at turn-end, and when the marker is present and it
  has not already nudged this turn (`stop_hook_active == false`), it re-injects
  (`{"decision":"block","reason":…}`) instructing the agent to resend via the reply
  tool — at most once (default), then gives up. One stderr line per fire; fail-silent.
- **US2** — the typing-timeout warning stops asserting OAuth; it names the real
  alternatives (slow turn / answered-without-tool / expired login) + a diagnostic.
  Shipped as a `v4→v5` bump of the image-baked plugin patch.

Feasibility was proven by MEASURING the real Stop-hook payload (it lacks turn
origin → the plugin marker is required). See [research.md](./research.md).

## Technical Context

**Language/Version**: bash 3.2+ (host launcher, hook script, `start_services.sh`);
Python 3 (image-baked `apply_telegram_typing_patch.py`); TypeScript patch fragments
(the plugin `server.ts`); `jq` for the `settings.json` merge; `yq` v4+ for
`agent.yml`.

**Primary Dependencies**: Claude Code Stop hooks (`hooks.Stop` in `settings.json`,
`{decision:"block",reason}` continuation, `stop_hook_active` loop guard); the
grammy-based Telegram plugin (`plugin:telegram:telegram` reply tool); the existing
`apply_telegram_typing_patch.py` cascade; the render engine (`scripts/lib/render.sh`).

**Storage**: files only — `<workspace>/.state/.claude/channels/telegram/pending-reply.json`
(the marker; container path `/home/agent/.claude/channels/telegram/pending-reply.json`,
`/home/agent` ↔ `.state`), `~/.claude/settings.json` (docker) / `<workspace>/.state/.claude/settings.json`
(local) for the hook registration, `agent.yml` for the toggle.

**Testing**: `bats tests/` (host, no Docker) for the hook script + agent.yml/schema
wiring + the patcher transform (`tests/apply-telegram-patches.bats`); `DOCKER_E2E=1`
for boot re-application + the plugin marker end-to-end; `shellcheck -S error`.

**Target Platform**: Alpine 3.20 container (docker mode) and systemd (local mode);
host launcher on macOS/Linux.

**Project Type**: CLI / infrastructure scaffolder (the three code paths in CLAUDE.md).

**Performance Goals**: negligible — one file-existence check + a small jq per turn.

**Constraints**: fail-silent (never crash the session/supervisor); survive
`./setup.sh --regenerate`; docker regenerate byte-identical for non-channel agents;
no runtime change for the interactive wizard path or the local remote-control relay;
never log secrets or message content.

**Scale/Scope**: per-agent; one hook, one plugin marker, one toggle.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*
*Source: `.specify/memory/constitution.md` (v1.0.1).*

- [x] **I. Single Source of Truth** — the toggle lives in `agent.yml`
  (`features.reply_guard`), auto-flattened by `render_load_context`; the hook script
  is a derived file rendered from `modules/stop-hook.sh.tpl` in `regenerate()`; the
  toggle is backfilled in `regenerate()` before render; the `settings.json`
  registration is re-applied deterministically at every docker boot / local login
  (never hand-edited). Survives `--regenerate`. **PASS**.
- [x] **II. Least-Privilege (NON-NEGOTIABLE)** — no new capability, mount, or
  socket; no Docker socket; no inbound port. The hook runs as `agent` inside the
  session; the marker is an agent-owned file under `.state`. No `root` exec, no
  weakening of `cap_drop: ALL` / `no-new-privileges`. **PASS**.
- [x] **III. Test-First, Host-Runnable** — the hook script's four required cases
  (FR-010) run on the host with JSON fixtures + a fake marker (no Docker); the
  patcher transform is host-tested in `apply-telegram-patches.bats`; the agent.yml
  schema wiring is covered by `schema.bats`. DOCKER_E2E gates only the boot/plugin
  integration. `shellcheck` clean; the hook lib guards side effects. **PASS**.
- [x] **IV. Idempotent, Fail-Silent Lifecycle** — the hook exits 0 on every path
  (fail-silent) and no-ops on an absent marker; the `settings.json` merge is
  idempotent (skips if the command is already present); the plugin marker is
  content-simple and the patcher is marker-gated (`v5`); the loop is bounded by
  `stop_hook_active` (and an attempt file only if `max_attempts > 1`). **PASS**.
- [x] **V. Workspace-Is-the-Agent** — the marker lives under bind-mounted
  `.state/.claude/channels/telegram/`; the hook logs at most one line (a count / a fixed
  phrase) to the plugin stderr sink and NEVER the message text, the token, or the
  chat contents; no backup-branch changes; `--restore-from-fork` untouched. **PASS**.
- [x] **VI. Reproducible, Pinned Dependencies** — no new toolchain pin (the typing
  patch `v5` is an internal marker, not a version pin); `CHANGELOG.md` + `README.md`
  updated; `VERSION` bumped MINOR (new feature). **PASS**.

**Result: 6/6 PASS. No violations → Complexity Tracking empty.**

## Project Structure

### Documentation (this feature)

```text
specs/028-channel-reply-guard/
├── plan.md              # This file
├── research.md          # Phase 0 — gate result + mechanism/hosting decisions
├── data-model.md        # Phase 1 — entities (marker, payload, config, loop state)
├── quickstart.md        # Phase 1 — how to validate (host + live-host tail)
├── contracts/
│   ├── stop-hook-io.md          # hook stdin payload → decision output contract
│   ├── pending-reply-marker.md  # plugin marker file lifecycle + shape
│   └── settings-merge.md        # the additive jq that registers the hook
└── tasks.md             # Phase 2 (/speckit-tasks — NOT created here)
```

### Source Code (files this feature adds/changes)

```text
# Host launcher (code path 1) — render + schema + backfill
setup.sh                         # regenerate(): backfill features.reply_guard;
                                 #   render modules/stop-hook.sh.tpl → scripts/hooks/
scripts/lib/schema.sh            # _SCHEMA_BOOLEANS += .features.reply_guard.enabled
modules/stop-hook.sh.tpl         # NEW — the Stop-hook script (workspace-templated);
                                 #   max_attempts baked via {{FEATURES_REPLY_GUARD_MAX_ATTEMPTS}} (no .conf file)
modules/stop-hook-install.sh.tpl # NEW — shared rendered jq merge that registers the hook in settings.json
modules/local-login.sh.tpl       # local: invokes install-stop-hook.sh into .state/.claude/settings.json

# Image-baked (code path 2) — needs image rebuild + DOCKER_E2E
docker/scripts/start_services.sh # NEW pre_install_stop_hook() after pre_accept_bypass_permissions
docker/scripts/apply_telegram_typing_patch.py  # US2 v4→v5 message + upgrader;
                                 #   US1 pending-reply marker hunk (write on inbound / delete on reply)

# Workspace-templated (code path 3)
scripts/heartbeat/heartbeat.sh   # isolation jq += del(.hooks.Stop)

# Fixtures + tests
tests/fixtures/sample-agent-with-vault.yml   # + features.reply_guard (schema.bats:52)
tests/fixtures/sample-agent.yml              # + features.reply_guard (shape parity)
tests/stop-hook-guard.bats       # NEW — the 4 required cases + fail-silent
tests/apply-telegram-patches.bats# + US2 v5 message + v4→v5 upgrade + marker hunks
tests/schema.bats                # (only if a new {{VAR}} is added; fixture edit covers it)

# Docs
CHANGELOG.md · README.md · docs/architecture.md · VERSION (MINOR bump)
```

**Structure Decision**: the feature deliberately splits across the three code paths
because that is where the required signals live (research.md, Decision 1 & 3): the
hook *script* is workspace-templated so `--regenerate` refreshes it; the hook
*registration* and the plugin *marker* are image-baked (docker) / login-time (local)
because only the boot/login path can merge trusted user-settings before the session
starts and only the plugin knows the channel origin.

## Complexity Tracking

No constitution violations to justify — this section is intentionally empty.
