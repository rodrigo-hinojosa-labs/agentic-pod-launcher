# Implementation Plan: Channel interactive-prompt (AskUserQuestion) guard

**Branch**: `031-channel-askuserquestion-guard` | **Date**: 2026-08-19 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `specs/031-channel-askuserquestion-guard/spec.md`

## Summary

A Telegram-configured agent, mid-turn, that calls the interactive `AskUserQuestion`
tool renders a console-only menu the channel operator can't see — the turn hangs
invisibly. This adds a deterministic **`PreToolUse` hook** (matcher `AskUserQuestion`)
that, only when the turn is channel-originated (reusing 028's `pending-reply.json`
marker), **denies the tool and redirects** the agent to ask via the reply tool
(agent-driven, no new privilege — measured to work, research.md D0). Bounded by a
per-turn attempt counter; on give-up, a marker tells the plugin (its existing send
path) to deliver one honest give-up message. A companion typing-warning bump (v5→v6)
names the interactive-prompt cause. Fail-open on uncertain origin so a legitimate
console prompt is never blocked.

## Technical Context

**Language/Version**: POSIX-ish `bash` (hook + installer, 3.2 & 5.x), Python 3 (the
image-baked plugin patcher), rendered via `scripts/lib/render.sh`.

**Primary Dependencies**: Claude Code hooks (`PreToolUse`, measured on 2.1.223 ≈ image
~2.1.220); `jq`; the merged 028 subsystem (`pending-reply.json` marker,
`modules/stop-hook*.tpl` install pattern, `apply_telegram_typing_patch.py`).

**Storage**: small state files under `~/.claude/channels/telegram/` (bind-mounted
`.state/`): origin marker (read), attempt counter (r/w), give-up marker (w); stderr log.

**Testing**: `bats` host suite (fixture payloads over the hook + config backfill +
patcher), `shellcheck -S error`; `DOCKER_E2E=1` for the image-baked boot/patcher.

**Target Platform**: Alpine container (docker mode, where the behaviour lives) and
systemd local mode (guard inert — no telegram tool in the relay).

**Project Type**: launcher (bash wizard scaffolding Dockerized agents); this touches
host-launcher render + image-baked plugin patch + boot install.

**Performance Goals**: negligible — one file check + one small jq per AskUserQuestion
call; no hot path.

**Constraints**: fail-silent (exit 0 every path), idempotent, no new container
privilege, no secrets logged, survives `--regenerate`, coexists with 028 + typing v5.

**Scale/Scope**: one hook script + one installer + one config block + one patcher
bump; ~4 new bats files; VERSION MINOR bump.

## Constitution Check

*GATE: passed before Phase 0 and re-checked post-design (research.md). Source: v1.0.1.*

- [x] **I. Single Source of Truth** — `features.askuserquestion_guard.{enabled,max_attempts}`
  in `agent.yml`; hook + installer rendered by `--regenerate`; `has()`-guarded backfill;
  byte-identical re-render. No hand-edited derived file.
- [x] **II. Least-Privilege (NON-NEGOTIABLE)** — NO new capability/mount/socket. Hook
  runs as `agent`. The guard NEVER gains channel-send: it denies (stdout) and, on
  give-up, writes a marker the plugin's **existing** send path consumes. `docker exec`
  usage unchanged.
- [x] **III. Test-First, Host-Runnable** — the hook + config + patcher are host-testable
  with fixtures; default suite needs no Docker; image-baked parts gated behind
  `DOCKER_E2E=1`; `shellcheck` clean; the shared installer sourced with no side effects.
- [x] **IV. Idempotent, Fail-Silent** — hook exits 0 on every path; install jq-merge
  idempotent (keyed on command); typing upgrade idempotent by version marker; give-up
  message once-per-marker.
- [x] **V. Workspace-Is-the-Agent** — markers/counter under `.state`-backed channel dir;
  never logs the question text or a secret; backup branches untouched;
  `--restore-from-fork` unaffected.
- [x] **VI. Reproducible, Pinned Dependencies** — no new pins; CHANGELOG + `VERSION`
  MINOR bump (0.21.0 → 0.22.0, verified vs `origin/main` before release — lesson 023).

**Result: 6/6 PASS.** No Complexity Tracking entries required.

## Project Structure

### Documentation (this feature)

```text
specs/031-channel-askuserquestion-guard/
├── plan.md              # this file
├── spec.md              # feature spec (+ Clarifications 2026-08-19)
├── research.md          # Phase 0 — the measured feasibility gate (D0) + D1–D7
├── data-model.md        # the 6 data artifacts
├── quickstart.md        # enable / validate / diagnose
├── contracts/
│   ├── pretooluse-guard-io.md      # the hook's stdin→decision contract (C1–C6)
│   ├── hook-install-and-config.md  # settings.json PreToolUse merge + agent.yml config
│   └── giveup-and-warning.md       # give-up delivery + typing v6 (image-baked)
├── checklists/requirements.md      # spec quality (16/16)
└── tasks.md             # /speckit-tasks (next)
```

### Source code (repository root)

```text
modules/
├── askq-guard.sh.tpl            # NEW — the PreToolUse hook (rendered → scripts/hooks/askq-guard.sh)
└── (install)                    # generalize modules/stop-hook-install.sh.tpl for PreToolUse+matcher,
                                 #   OR add modules/askq-guard-install.sh.tpl (tasks decision)

setup.sh                         # + features.askuserquestion_guard heredoc, backfill (has()),
                                 #   render gate (FEATURES_ASKUSERQUESTION_GUARD_ENABLED)

docker/scripts/
├── start_services.sh            # + install the PreToolUse hook at boot (beside pre_install_stop_hook)
└── apply_telegram_typing_patch.py  # + give-up read/send/clear hunk; typing v5→v6 + upgrade_typing_v5_to_v6

scripts/local/agent-login.sh     # + install the PreToolUse hook on local login (inert without telegram tool)

tests/
├── askq-guard.bats              # NEW — hook decision table (C1–C6) over fixture payloads
├── askq-guard-config.bats       # NEW — backfill/derive/preserve across --regenerate
├── apply-telegram-patches.bats  # EDIT — v6 + give-up hunk assertions
└── docker-e2e-askq-guard.bats   # NEW (gated) — boot registers hook + baked v6 + give-up hunk
```

**Structure Decision**: three code paths, same split 028 used — host-launcher render
(`modules/` + `setup.sh`), image-baked (`docker/`), and the boot install
(`start_services.sh` / `agent-login.sh`). A new `features.*` block (not folded under
`reply_guard`) keeps the two guards independently toggleable and their tests separate.

## Complexity Tracking

*No Constitution violations — table intentionally empty.*

## Phase 0 — Outline & Research

**Complete.** See [research.md](./research.md). Central result: the feasibility gate is
**RESOLVED POSITIVE by measurement** — `PreToolUse` fires for `AskUserQuestion` in an
interactive session (2.1.223), the deny+reason redirects the model to text, the payload
carries no origin field (→ reuse 028's marker), and there is no `stop_hook_active` for
PreToolUse (→ own counter). A documentation claim to the contrary was refuted.

## Phase 1 — Design & Contracts

**Complete.** data-model.md (6 artifacts), contracts/ (3), quickstart.md. Constitution
re-checked post-design: 6/6 PASS.

## Phase 2 — Next

`/speckit-tasks` to generate the task list (test-first): US1 hook + config +
install + loop guard; US1 give-up path; US2 typing v6; docs + VERSION; DOCKER_E2E
(gated) + ferrari deploy gate (deferred).
