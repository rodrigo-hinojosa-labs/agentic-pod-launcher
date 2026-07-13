# Research: Docs Refresh to v0.12.0 (020)

Phase 0 synthesis. Full evidence lives in the three generated artifacts:
[drift-audit.md](drift-audit.md) (121 findings, per-doc tables with file:line
disproofs), [wizard-prompt-order.md](wizard-prompt-order.md) (52-prompt
canonical order), [coverage-map.md](coverage-map.md) (25 subsystems, 011-019).
Produced by workflow `wf_a96ac163-11f`: 16 agents, 475 verification tool
calls, 0 errors (2026-07-12).

## R1 — Scale and shape of the drift (audit results)

**Decision**: treat the audit tables as the feature's test oracle (SC-001);
no doc edit lands without closing its findings.

**Numbers**: 121 findings across all 14 docs — 33 **false**, 46 **stale**,
41 **needs-qualifier**, 1 unverified-suspicion (resolve at implement).
Coverage map: of 25 subsystems shipped in 011-019, **8 are documented
nowhere** (local `agent-bootstrap`, `resolve_claude_bin`, `_libc_variant`
bun selection, `rag_obs.sh`/TMPDIR routing, qmd MCP wrapper shape,
sqlite-vec/vec0 musl swap, 018 multi-pass embed + `pending` state, 019 test
seam), 13 partial, 4 complete.

**Highest-risk docs** (false claims that actively mislead):
- `docs/adding-an-mcp.md` — 6 false/6 high: predates the per-mode MCP
  contract entirely.
- `docs/vault.md` — 15 findings/4 high; its "QMD operations" section
  predates even feature 010 ("QMD is not auto-configured at boot" + manual
  `bunx` commands) and documents the RETIRED `.mcp.json` shape
  (`args: ["@tobilu/qmd@latest", "mcp"]`).
- `modules/claude-md.tpl` — 4 high: teaches every scaffolded agent wrong
  runtime facts.
- `docs/architecture.md:279` — still says qmd is "invoked via bunx"
  (contradicts 016).
- `README.md` — Docker-only framing (hides local mode) + a false restore
  instruction: advises `RESTORE_IDENTITY_KEY=...` as env var, but
  `setup.sh:356` clobbers the env value; only the `--identity-key PATH`
  flag works.

## R2 — Repair strategy per doc: rewrite vs surgical

**Decision**: rewrite where the FRAME is wrong; surgical corrections where
the skeleton holds.

- **Rebuild**: both agentic quickstarts (reconstructed on the canonical
  52-prompt order — their current prompt walkthrough lacks the
  deployment-mode prompt entirely); `docs/state-layout.md` (tree predates
  local mode, managed prefix, `.graph/`); `docs/vault.md` qmd sections
  (pre-010 content); `README.md` framing sections (What-this-is,
  Prerequisites, Quickstart become dual-mode).
- **Surgical**: `architecture.md`, `getting-started.md`, `heartbeatctl.md`,
  `adding-an-mcp.md` (structure OK, contract examples replaced),
  `adding-a-notifier.md`, `qmd-upgrade-checklist.md` (add 017/018 items),
  the three templates.

**Rationale**: rewrites limited to where finding density × severity makes
patching costlier than rebuilding; everything else stays diff-reviewable.

## R3 — Coverage-gap placement

**Decision**: land each of the 8 undocumented + 13 partial subsystems in the
`best_home_doc` from the coverage map (no new standalone docs, per spec Out
of Scope). Notables: local-mode operational knowledge consolidates in
`getting-started.md`; qmd invocation/MCP/embed-loop truth consolidates in
`vault.md` (with `architecture.md` keeping the design-level view);
017/018 items extend `qmd-upgrade-checklist.md`; the 019 test seam gets a
two-line pointer from `architecture.md`'s testing notes to the spec contract
(records the decision without duplicating it).

## R4 — Template edits and the render-test contract

**Decision**: template fixes (next-steps EN/ES, claude-md.tpl) ship in the
same commit as any rendered-string assertion they legitimately change; the
tasks phase must first enumerate which tests grep rendered NEXT_STEPS/
CLAUDE.md content (known touchpoints: `e2e-smoke.bats` hand-rolled array,
render fixtures) so no assertion drifts silently (the 016-era lesson).

## R5 — Findings that are NOT doc bugs (recorded, not fixed here)

1. The Telegram typing patch is at **v4** (5-minute default cap via
   `TELEGRAM_TYPING_MAX_MS`, user-facing timeout warning) —
   `docker/scripts/apply_telegram_typing_patch.py:61,112-150`. The repo's
   own `CLAUDE.md` still describes v3; `CLAUDE.md` is out of scope here
   (maintained by its own process) — flagged for its next maintenance pass.
2. **Local mode never loads the workspace `.env` into the agent session — so
   catalog-MCP secrets cannot resolve there** (surfaced by the `adding-an-mcp`
   writer; verified independently at implement time). `modules/mcp-json.tpl`
   passes every catalog secret by shell expansion — `"FIRECRAWL_API_KEY":
   "${FIRECRAWL_API_KEY}"` (:27), the six `${ATLASSIAN_*}` (:53-58),
   `"GITHUB_PERSONAL_ACCESS_TOKEN": "${GITHUB_PAT}"` (:65), `${AWS_*}` (:41-42).
   In **docker** those resolve because `modules/docker-compose.yml.tpl:67` mounts
   the workspace `.env` via `env_file`. In **local** mode there is no equivalent:
   the only `EnvironmentFile` in the rendered units is
   `modules/systemd-remote-control.service.tpl:12` →
   `<workspace>/.state/remote-control.env`, and that file
   (`modules/remote-control.env.tpl`) defines exactly four keys —
   `CLAUDE_CONFIG_DIR`, `DISABLE_AUTOUPDATER`, `HOME`, `PATH`. No rendered local
   artifact sources `<workspace>/.env`. Consequence: an operator who enables an
   optional MCP with `requires_secret: true` in local mode fills `.env` as the
   wizard instructs, and the variable expands to the empty string at MCP start.
   **This is a CODE gap, not doc drift** — out of scope for 020 (docs-only,
   FR-008). Candidate for its own feature; the fix is presumably an
   `EnvironmentFile=-<workspace>/.env` on the session unit (the `-` prefix keeps
   it optional), but that needs its own threat-model pass: `.env` is `0600` and
   the unit runs as the operator, so the file's mode and the unit's `User=` have
   to be reconciled before shipping.

3. **The launcher's own `CLAUDE.md` claims a `bash 4+` host floor that the code
   does not enforce** (surfaced by the README writer). `setup.sh` /
   `scripts/lib/*` / `scripts/agentctl` contain no bash-4-only construct
   (`declare -A`, `mapfile`/`readarray`, `local -n`, `${x,,}`/`${x^^}`, `coproc`)
   and there is no `BASH_VERSINFO` gate anywhere; the suite is routinely run on a
   macOS host with stock bash 3.2. The README now says "no bash version floor".
   `CLAUDE.md` is out of scope here — flagged for its next maintenance pass,
   alongside the typing-patch v3→v4 correction above.

4. No other code-is-wrong findings surfaced: every remaining mismatch audited
   resolved to doc drift.

## R6 — Verification discipline at implement time

**Decision**: the drift tables carry each finding's disproof, so writers
correct WITH the evidence in hand; FR-002 still requires re-verification at
writing time (the second pass, adversarial by construction). Aging facts get
"as of v0.12.0" tags (FR-009). ES/EN parity is enforced by writing EN and ES
from the same section skeleton, then a section-diff check (SC-004).
