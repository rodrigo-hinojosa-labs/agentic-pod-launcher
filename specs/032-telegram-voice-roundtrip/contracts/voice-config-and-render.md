# Contract: declarative surface — agent.yml, schema, render, wizard, backfill

Scope: everything outside the patcher. Mirrors the 028/031 toggle pattern plus 029's
compose-environment delivery.

## C11 — agent.yml block and schema

- Block shape and defaults: see data-model.md §1. `features.voice.enabled` joins
  `_SCHEMA_BOOLEANS` in `scripts/lib/schema.sh`.
- Both bats fixtures (`tests/fixtures/sample-agent.yml`,
  `sample-agent-with-vault.yml`) carry the block (schema.bats placeholder-drift guard).

## C12 — Render (docker mode)

- `modules/docker-compose.yml.tpl` `environment:` gains the five `TELEGRAM_VOICE_*`
  lines (data-model.md §2), placed with the existing `TZ`/`MCP_TIMEOUT` entries —
  **unconditionally**, exactly like `MCP_TIMEOUT` (no `{{#if}}`; a voice-disabled or
  plugin-less agent carries inert env — remediated 2026-09-06, no "no-telegram renders
  no voice env" test exists).
- `setup.sh` sanitizes after `render_load_context` and re-exports (029 precedent):
  - `FEATURES_VOICE_REPLY_MODE` ∈ {auto,always,never} else `auto`
  - `FEATURES_VOICE_PROVIDER` == `elevenlabs` else `elevenlabs`
  - `FEATURES_VOICE_VOICE_ID` trimmed (may be empty — patcher default applies)
  - `FEATURES_VOICE_ENABLED` is schema-validated boolean (no re-sanitize needed)
  - **STT lang (remediated 2026-09-06, was a HIGH; delivery pinned by analyze F1)**:
    `user.language` ∈ {es,en} passes through; ANYTHING else — including the
    wizard-legal `mixed` and hand-edited free text — renders as the empty string (the
    STT helper omits `language_code` when empty ⇒ autodetect). The sanitized value is
    exported as a **dedicated derived placeholder `VOICE_STT_LANG`** consumed by the
    compose template; `USER_LANGUAGE` itself is NEVER re-exported (`claude-md.tpl`
    consumes it — a `mixed` agent's CLAUDE.md must keep saying `mixed`).
    `{{VOICE_STT_LANG}}` is added to `known_external` in `tests/schema.bats`.
- `modules/env-example.tpl` documents `ELEVENLABS_API_KEY=` plus the two optional
  tuning knobs (names + one-line comments; never values). This is the SINGLE tested
  vehicle for the "key name documented when declined" requirement (NEXT_STEPS carries
  no voice content — remediated 2026-09-06).
- **Local mode — honest invariant (remediated 2026-09-06)**: no local RUNTIME artifact
  (systemd units, rendered scripts, `.mcp.json`, `remote-control.env`) contains any
  `TELEGRAM_VOICE_` string for a voice-enabled local agent.yml; `.env.example` gains
  the inert documentation lines in both modes (it renders unconditionally before the
  mode branch). Test oracle: +1 in `tests/local-render.bats` (029 precedent) asserting
  the runtime-artifact invariant.

## C13 — Wizard (prompts live in `setup.sh`, using existing primitives)

- Offered ONLY on **docker-mode scaffolds** (`deployment.mode == docker`, asked first
  in the wizard) — the telegram plugin is a mandatory default present in every
  scaffold, so plugin presence discriminates nothing (remediated 2026-09-06).
  Local-mode answer streams gain NO voice prompt. Default answer declines ⇒ block
  written disabled.
- The prompts are `ask_yn` + `ask` calls in `setup.sh`'s wizard section;
  `scripts/lib/wizard.sh` / `wizard-gum.sh` are generic primitive libraries and are NOT
  modified (remediated 2026-09-06 — the earlier plan tree was wrong).
- Accepting sets `enabled: true` and prompts for `voice_id` (optional, blank = stock
  default voice) — `reply_mode` stays `auto` (changeable in agent.yml; the wizard does
  not enumerate it, YAGNI).
- Declining still documents the `.env` key name for later enablement via
  `.env.example` (clarified 2026-09-06) — no interactive nagging.
- Known test touchpoints updated in the same task: `wizard_answers` helper, the
  e2e-smoke prompt array, `known_external` in schema.bats.

## C14 — Backfill (`--regenerate` on a pre-032 agent.yml)

- Guarded by `has("voice")` on `.features` — absent ⇒ write the full disabled block;
  present ⇒ leave every field untouched (operator wins, including explicit `false`/
  custom values). NEVER `//`-style defaulting.
- Unlike 028/031 there is NO plugin-derived `enabled=true` path — the backfill value is
  always `false` (clarified 2026-09-06: explicit opt-in; the feature spends money and
  needs a new secret).

## C15 — Regenerate-safety and version discipline

- Two consecutive `--regenerate` runs produce byte-identical derived files (SC-005).
- `VERSION` 0.22.0 → **0.23.0** (MINOR, 028/031 precedent) — verify against
  `origin/main` before bumping (023 lesson).
- `CHANGELOG.md` entry + README "Two-way Telegram chat" section gains the voice
  subsection (key name, opt-in semantics, cost note, caps and their env overrides).
