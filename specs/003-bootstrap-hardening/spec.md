# Feature Specification: Bootstrap hardening — fail loud, validate inputs, stay in sync

**Feature Branch**: `003-bootstrap-hardening`

**Created**: 2026-06-20

**Status**: Draft

**Input**: Nine friction points discovered during a real end-to-end scaffold (scaffold → first boot → `/login` → plugins → channel), grouped into three severity tiers.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Silent failures become loud or automatic (Priority: P1)

A first-time operator scaffolds an agent, boots the container, and runs `/login`. Today three things can fail silently: plugins never install until a manual `docker restart`; a fork they asked to be private is created public; and a plugin that fails to install looks identical to one that was merely skipped for being unauthenticated. After this story, the happy path self-heals and every failure is visible.

**Why this priority**: These are the traps that break the documented happy path for *every* new operator. An operator who follows the next-steps exactly still ends up with a broken agent (no plugins, no channel) or an unintended public repository — with no error telling them why.

**Independent Test**: Run a scaffold → boot → `/login` → `/exit` cycle issuing no extra commands; confirm all configured plugins end up installed and the channel-enabled session is running. Separately, request a private fork against a public template and confirm a warning + explicit choice precedes any public fork.

**Acceptance Scenarios**:

1. **Given** a freshly scaffolded agent whose plugins did not install at first boot (unauthenticated), **When** the operator completes `/login` and remains in the session, **Then** the watchdog detects the auth flip, kicks and respawns the session, and within seconds all configured plugins are installed and the session is channel-enabled — no manual restart and no `/exit`.
2. **Given** fork creation is requested and the template repository is public, **When** the operator answered "make the fork private", **Then** the wizard warns that a fork of a public repo cannot be private and will be PUBLIC, and waits for the operator to choose proceed-public or disable-fork before creating anything.
3. **Given** a plugin install attempt that fails for a transient reason, **When** the install step runs, **Then** the log distinguishes "install failed" from "not authenticated", the failure is retried within a bounded budget, and any plugin still failing afterward is named by the doctor diagnostic and the next-steps with a copy-paste retry command.

---

### User Story 2 - Input validation and doc/wizard sync (Priority: P2)

An operator (or an agent driving the wizard via a piped prompt) supplies a destination, an agent name, and relies on the quickstart documentation for the prompt order. Today a malformed destination is accepted, a spaced name is mangled, and the documented prompt order omits prompts the wizard actually asks — desyncing a piped run. After this story, bad inputs are caught up front and the docs cannot drift from the wizard.

**Why this priority**: These do not break the happy path on their own but cause confusing, hard-to-diagnose failures (a workspace created at a nonsense path; a container named differently than the fork/dir; a piped wizard that hangs mid-stream). They protect both human and agentic operators.

**Independent Test**: Feed the wizard a non-absolute destination and a name with spaces; confirm each is rejected or corrected with the normalized value shown. Run the doc-vs-wizard sync check and confirm it fails when the documented order is edited out of sync.

**Acceptance Scenarios**:

1. **Given** a destination that is not an absolute path, or contains a `~` anywhere other than the first character, **When** the wizard reads it, **Then** it is rejected (a leading `~` is expanded), and on macOS a `/home/...` destination warns that the home directory is under `/Users/...`.
2. **Given** an agent name containing spaces or capitals (e.g. "Rodri Cenco Admin"), **When** it is normalized, **Then** spaces become hyphens, double hyphens collapse, leading/trailing hyphens are trimmed (yielding `rodri-cenco-admin`), and the normalized value is shown and confirmed before use.
3. **Given** the agentic-quickstart wizard-order documentation, **When** it diverges from the canonical prompt sequence (including the optional catalog-MCP prompts), **Then** an automated check fails.

---

### User Story 3 - Noise and polish (Priority: P3)

An operator running a fork-less agent, or one who injected a custom persona into CLAUDE.md, or one whose persona is multi-paragraph. Today the supervisor log spams an identity-backup line every tick even with no fork, the in-container CLAUDE.md refresh can clobber an injected section, and a rich persona cannot enter via the one-line wizard prompt. After this story these rough edges are gone.

**Why this priority**: Quality-of-life. None blocks a working agent, but each erodes trust (noisy logs read as churn; a clobbered persona is silent data loss; a truncated role forces a manual post-scaffold step).

**Independent Test**: Boot a fork-less agent and confirm the supervisor log has zero identity-backup lines over an idle window. Inject a marked section into CLAUDE.md, run the refresh, and confirm the section survives byte-for-byte. Supply a multi-paragraph persona from a file and confirm it lands complete in the generated CLAUDE.md.

**Acceptance Scenarios**:

1. **Given** an agent with the fork disabled, **When** the supervisor watchdog runs its periodic checks, **Then** it performs no identity-backup hash check and emits no "identity backup triggered" log line.
2. **Given** a CLAUDE.md containing an operator-injected section beyond the default ones, **When** the in-container refresh runs, **Then** every pre-existing section is preserved and only missing command/architecture/test documentation is added.
3. **Given** a multi-line persona supplied from a file at scaffold time, **When** CLAUDE.md is generated, **Then** the full persona text appears verbatim instead of being truncated to one line.

---

### Edge Cases

- Operator logs in but never `/exit`s the first session: plugins still pending until a session death; the doctor diagnostic surfaces "plugins pending" so the state is at least visible.
- Template repository is private (a fork *can* be private): no warning fires; fork creation proceeds normally.
- A plugin keeps failing past the retry budget: the boot does not loop forever — it continues and surfaces the residual failure (fail-loud, not fail-stuck).
- A plugin's install error text carries a credential (a token in a URL or env): the persisted `last_error` MUST be truncated to its first line and scrubbed of token-like strings before it reaches `.state/` (Principle V — never write secrets to agent state).
- Destination is relative (`./foo`) or empty: rejected before scaffolding.
- Agent name reduces to empty after normalization (only spaces/punctuation): rejected with a re-prompt.
- CLAUDE.md has no custom sections (default agent): refresh behaves as today (adds the standard sections).
- Role file is missing or empty: the wizard fails loud (clear error) or falls back to the one-line role, never silently producing an empty persona.
- `--regenerate` is run after any of these changes: behavior is unchanged and no input re-validation regression occurs.

## Requirements *(mandatory)*

### Functional Requirements

**Story 1 — silent failures (P1)**

- **FR-A1**: After the operator authenticates in the first-boot session, the system MUST install all configured plugins and relaunch the session in channel-enabled mode — by actively kicking the tmux session on the auth flip so it respawns immediately — without a manual container restart and without requiring the operator to `/exit`.
- **FR-A2**: The system MUST detect the unauthenticated→authenticated transition — by the appearance of the auth credential marker, polled by the supervisor watchdog — and on that flip re-run the plugin-install step and **actively kick the running tmux session** (the existing recovery primitive) so the re-decided command takes effect immediately, even if the operator stays in the session. Detection MUST NOT rely on tmux-pane scraping.
- **FR-B1**: When fork creation is requested and the template repository is public, the system MUST warn — before creating anything — that a fork of a public repo cannot be private and will be public.
- **FR-B2**: On that warning the operator MUST be able to choose to proceed (accept public) or disable the fork; the choice MUST be respected. A private non-fork mirror is out of scope for this feature.
- **FR-B3**: The system MUST NOT silently create a public fork after the operator requested a private fork.
- **FR-B4**: In a non-interactive run (no TTY — e.g. the piped/agentic quickstart), a public-template + private-fork conflict MUST default to **disable-fork** with a logged notice (never silently public, never block on an interactive prompt). Creating a public fork in that mode requires an explicit pre-supplied "accept-public" answer in the input stream.
- **FR-C1**: The plugin-install step MUST log "not authenticated" and "install failed" as distinct, distinguishable outcomes.
- **FR-C2**: The system MUST retry a failed plugin install a bounded number of times (3 attempts, a short fixed backoff) before giving up (no infinite loop, no silent surrender).
- **FR-C4**: The persisted failure record's error text MUST be truncated (first line) and scrubbed of token-like strings before it is written to `.state/` — a plugin error MUST NOT leak a secret into agent state (Principle V).
- **FR-C3**: Any plugin still uninstalled after retries MUST be reported by the doctor diagnostic and in the generated next-steps, with an explicit retry command.

**Story 2 — input validation + doc sync (P2)**

- **FR-D1**: The system MUST reject a destination that is not an absolute path.
- **FR-D2**: The system MUST expand a leading `~` to the operator's home and MUST reject a `~` appearing anywhere other than position 0.
- **FR-D3**: On macOS, a destination beginning with `/home/` MUST emit a warning that the macOS home is under `/Users/`.
- **FR-E1**: Agent-name normalization MUST map spaces to hyphens, collapse consecutive hyphens, and trim leading/trailing hyphens, producing a valid DNS-label name.
- **FR-E2**: The normalized agent name MUST be shown to the operator and confirmed before it is used for filenames, branches, and the container name.
- **FR-F1**: The agentic-quickstart wizard-order documentation MUST list every prompt in the exact order the wizard presents them, including the optional catalog-MCP prompts.
- **FR-F2**: An automated check MUST fail when the documented wizard order diverges from the canonical prompt sequence.

**Story 3 — noise + polish (P3)**

- **FR-G1**: When the fork is disabled, the supervisor MUST NOT perform the identity-backup hash check and MUST NOT emit the per-tick "identity backup triggered" log line.
- **FR-H1**: The in-container CLAUDE.md refresh MUST preserve every pre-existing section verbatim, editing the file only to ADD missing command/architecture/test documentation — it MUST NOT edit or remove existing content. An operator-injected section MUST survive unchanged. No sentinel markup is required.
- **FR-I1**: An operator MUST be able to supply a multi-line persona via an `agent.yml` `role_file` path field — populated by a `--role-file PATH` wizard flag — and the renderer MUST inject that file's content into the generated CLAUDE.md verbatim (never truncated to one line). The persona MUST survive `--regenerate` (agent.yml stays the single source of truth).
- **FR-I2**: If the supplied persona file lives outside the destination workspace, the wizard MUST copy it into the workspace (e.g. `personas/<name>.md`) and store the relative path in `agent.yml`, so the persona is self-contained and travels with clone / backup / `--restore-from-fork` (Principle V).

**Cross-cutting (constitution v1.0.0)**

- **FR-X1**: Every behavioral change MUST survive `./setup.sh --regenerate` (agent.yml stays the single source of truth).
- **FR-X2**: The default test suite MUST validate these behaviors without requiring Docker; any Docker-dependent assertion stays opt-in (`DOCKER_E2E=1`).
- **FR-X3**: No change may weaken the least-privilege container model (cap_drop ALL, `-u agent`, root-owned crontab, no-new-privileges).
- **FR-X4**: User-facing changes MUST be recorded in CHANGELOG.md, and the VERSION file bumped when behavior is user-visible.

### Key Entities *(include if feature involves data)*

- **Auth state**: whether the in-container Claude profile is logged in; drives the boot decision between the login session, the token wizard, and the channel-enabled session. The transition unauthenticated→authenticated is the trigger for FR-A1/A2.
- **Plugin install result**: per-plugin outcome of an install attempt — one of installed / skipped-unauthenticated / failed. Distinguishing the last two is the substance of FR-C1.
- **Canonical wizard sequence**: the ordered list of prompts the wizard emits (identity, user, fork, notify, catalog MCPs, Atlassian, GitHub MCP, heartbeat, principles, vault, plugins, review), derived from the wizard and the MCP/plugin catalogs; the doc in FR-F1 must mirror it.
- **Fork visibility intent vs. outcome**: the operator's requested private/public choice versus what the platform will actually produce given the template's visibility; the gap is what FR-B1 surfaces.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An operator who completes `/login` once obtains a fully plugged, channel-enabled agent with zero additional manual commands (no restart).
- **SC-002**: 100% of public-fork outcomes are preceded by an explicit warning and an operator choice; zero surprise-public forks.
- **SC-003**: Every plugin that fails to install is named to the operator (diagnostic + next-steps) within one boot, distinct from expected "not authenticated" skips.
- **SC-004**: 100% of malformed destinations (non-absolute, mid-path `~`) and space-containing agent names are caught or corrected before scaffolding proceeds.
- **SC-005**: A documented-vs-actual wizard-order mismatch is caught automatically (the sync check fails) before it can reach an operator.
- **SC-006**: A fork-less agent produces zero identity-backup log lines over a 10-minute idle window.
- **SC-007**: An operator-injected CLAUDE.md section is present byte-for-byte after the in-container refresh runs.
- **SC-008**: A multi-paragraph persona supplied at scaffold time appears complete (no truncation) in the generated CLAUDE.md.

## Assumptions

- **Fork-public remediation scope** (resolved 2026-06-20): Story B delivers the *warning* plus a proceed-public / disable-fork choice ONLY. A "private non-fork mirror" path is explicitly out of scope for this feature (separate surface, touches `--sync-template`); the bar is "never silently public".
- **Auth-transition trigger (A)** (resolved 2026-06-20): the supervisor watchdog (already polling every ~2s) detects the unauthenticated→authenticated transition by the appearance of the auth credential marker, and on that flip re-runs the plugin-install step and **actively kicks the tmux session** so it respawns immediately with the re-decided command (plugins + channels). No `/exit` is required — the kick guarantees the respawn even if the operator stays logged in (a passive "wait for natural respawn" was rejected: it leaves the logged-in-and-idle operator with no plugins, the exact original bug). tmux-pane scraping is explicitly rejected (per CLAUDE.md). Idempotent and fail-silent (Principle IV).
- **CLAUDE.md preservation mechanism (H)** (resolved 2026-06-20): the in-container refresh preserves ALL pre-existing sections and only ADDS missing command/architecture/test sections — it never edits or removes existing content. No sentinel markup is required.
- **Multi-line persona transport (I)** (resolved 2026-06-20): `agent.yml` gains an optional `role_file` path field that the renderer reads and injects verbatim into CLAUDE.md; the wizard accepts `--role-file PATH` which populates that field. agent.yml stays the single source of truth and the persona survives `--regenerate` (Principle I).
- **Testing without Docker**: image-baked logic (start_services.sh, wizard-container.sh decisions) is assumed extractable into shell functions/libraries that bats can exercise with mocked state, so the default suite stays Docker-free; only genuinely integration-level assertions use `DOCKER_E2E=1`.
- **Delivery is incremental**: P1 (Tier 1) is the MVP and can ship before P2/P3; each story is independently testable and deployable.
- **No catalog changes**: the set of MCPs and plugins is unchanged; this feature only fixes how they are installed, validated, documented, and logged.

## Refinement decisions

### 2026-06-20 session

- D: Story B fork-public remediation scope → A: warning + proceed-public/disable-fork only; private non-fork mirror is OUT of scope (FR-B2).
- D: Story A auth-transition trigger mechanism → A: supervisor watchdog polls the auth credential marker; the unauth→auth flip re-runs plugin install, re-decides the tmux command, and **actively kicks the session** so it respawns immediately (no `/exit` needed even if idle); no tmux-pane scraping (FR-A1/A2).
- D: Story H CLAUDE.md preservation mechanism → A: refresh preserves ALL existing sections and only adds missing ones; no sentinel markup required (FR-H1).
- D: Story I multi-line persona transport → A: `agent.yml` `role_file` path field + `--role-file PATH` wizard flag; renderer injects verbatim; survives `--regenerate` (FR-I1).
- D: Story A passive vs active respawn → A: the watchdog **actively kicks** the tmux session on the auth flip (not a passive "wait for natural respawn") — resolves the logged-in-and-idle gap (FR-A1/A2).
- D: Story B fork warning in non-interactive/piped runs → A: no TTY ⇒ default to disable-fork + a logged notice; a public fork needs an explicit pre-supplied accept-public answer (FR-B4).
- D: Story I persona file outside the workspace → A: the wizard copies it into the workspace and stores the relative path (self-contained; survives clone/backup/restore — Principle V) (FR-I2).
- D: VERSION bump magnitude for 003 → A: MINOR (new backward-compatible user surface: `--role-file`, fork warning, name-normalize confirm, doctor failed-plugins).
