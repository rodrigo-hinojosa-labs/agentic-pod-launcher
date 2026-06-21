# Data Model: Bootstrap hardening (003)

**Phase 1 output.** This feature is shell tooling, not a database app — the "entities" are the
small state/data shapes the stories read and write. Each maps to the spec's Key Entities.

## 1. Auth state (Story A)

- **What**: whether the in-container Claude profile is logged in.
- **Representation**: existence of `~/.claude/.credentials.json` (the same marker `probe_claude_oauth` reads). Boolean derived from `[ -f ]`.
- **Transitions**: `absent → present` (login) is the **trigger** for re-running plugin install + re-deciding `next_tmux_cmd`. `present → absent` (logout/expiry) is not acted on by this feature.
- **Lifetime**: tracked across watchdog ticks in a shell variable inside `_run_watchdog`; not persisted to disk (the file itself is the durable truth).
- **Validation**: file existence only; content is never read or logged (it holds OAuth tokens — Principle V).

## 2. Plugin install result (Story C)

- **What**: per-plugin outcome of an install attempt.
- **States**: `installed` (sentinel `.installed-ok` written) · `skipped-unauthenticated` (expected, retryable on next auth flip) · `failed` (non-auth error, retried up to 3×, then recorded).
- **Persistence**: residual `failed` specs appended to `.state/plugin-install-failures.jsonl` — one JSON object per line `{spec, attempts, last_error, ts}`. Lives under `.state/` (durable, gitignored, bind-mounted so host `agentctl doctor` can read it).
- **Lifecycle**: sourced from `agent.yml.plugins[]` at boot; an entry is cleared when a later attempt succeeds (sentinel present ⇒ remove from failure list). The list is advisory output, never a source of truth.
- **Consumers**: `agentctl cmd_doctor` (renders each with a retry command) and `modules/next-steps.en.tpl`.

## 3. Fork visibility intent vs. outcome (Story B)

- **What**: the operator's requested fork privacy versus what GitHub will actually produce.
- **Fields**: `agent.yml.scaffold.fork.enabled` (bool), `.private` (bool); plus the probed template `visibility` (`public|private`, transient — from `gh api`).
- **Rule**: if `template.visibility == public` AND `fork.private == true` ⇒ conflict ⇒ warn + `ask_choice`. The operator's choice writes back to `fork.enabled` (disable) or leaves `fork.private` (proceed, now knowingly public) **before** the agent.yml heredoc. agent.yml stays authoritative (Principle I).
- **Failure**: if the `gh api` probe errors, the wizard **fails loud** (no silent fork creation).

## 4. Canonical wizard sequence (Story F)

- **What**: the ordered list of prompts the wizard emits.
- **Source of truth**: `tests/helper.bash::wizard_answers()` (the `printf` order) + the catalogs (`mcp_catalog_list optional` → aws, firecrawl, google-calendar, playwright, time, tree-sitter; `plugin_catalog_list optional`).
- **Derived doc**: the wizard-order section of `docs/agentic-quickstart.{es,en}.md` MUST mirror it, including the 6 optional catalog-MCP prompts between notify and Atlassian.
- **Invariant (tested)**: every `mcp_catalog_list optional` id appears, by name, in the doc's wizard-order section. A divergence fails `tests/quickstart-doc.bats`.

## 5. role_file (Story I)

- **What**: optional path to a multi-line persona file, injected verbatim into CLAUDE.md.
- **Field**: `agent.yml.agent.role_file` — a string path (absolute, or relative to the workspace), optional/nullable. Sits beside the existing one-line `agent.role`. If supplied from outside the workspace, the wizard copies the file in and stores the relative path (self-contained — Principle V).
- **Render rule**: if `role_file` is set and readable ⇒ `render.sh` exports its full content as `AGENT_ROLE_MULTILINE`; `modules/claude-md.tpl` injects that into `## Identity` instead of the one-line `{{AGENT_ROLE}}`. If unset ⇒ existing one-line behavior.
- **Validation**: optional leaf in `schema.sh` (not required); if set but the path is missing/unreadable at render time ⇒ **fail loud** (clear error, never a silent empty persona).
- **Regenerate**: the path persists in agent.yml; content is re-read on every render ⇒ edits to the persona file are picked up by `--regenerate` without re-prompting (Principle I).

## Relationships

- (1) **Auth state** gates (2) **plugin install** re-runs — the absent→present flip is what re-invokes the install loop whose per-plugin **results** feed the doctor/next-steps surface.
- (3) **Fork visibility** and (5) **role_file** are both `agent.yml` fields written by the wizard and consumed by the renderer — the source-of-truth path.
- (4) **Canonical wizard sequence** is documentation/test metadata, not runtime state.
