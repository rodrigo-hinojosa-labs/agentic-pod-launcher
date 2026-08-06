# Phase 0 Research: Declarative Local-Scaffold Parity

All four root causes were **measured on hardware** during the `ferrari-admin` scaffold
(2026-08-05) and manually worked around to bring the agent up. This document records the
measurement, the chosen design, and the alternatives rejected — so implementation is
test-first against a known target.

---

## US1 — the scaffolded agent's `CLAUDE.md` is the launcher's dev doc

**Measured**: a `git clone` of the launcher (the declarative "clone-is-the-workspace" method)
ships the launcher's own root `CLAUDE.md`, because that file is force-committed to the launcher
repo (`git add -f`, per the launcher's own gotcha). `setup.sh`'s render (`regenerate()`,
`setup.sh:2227-2241`) only renders `CLAUDE.md` when the file is **absent** or `--force-claude-md`
is passed; `--force-claude-md` gates the overwrite behind `ask_yn 'Overwrite… DESTRUCTIVE' 'n'`,
which returns "no" with no TTY. Net: the non-interactive render logs `◦ CLAUDE.md (preserved)`
and the agent keeps the launcher's doc. Confirmed on ferrari: `head` of the workspace `CLAUDE.md`
was the launcher's `## What this repo is / This is **the launcher**, not an agent.` framing; a
manual `rm CLAUDE.md && ./setup.sh --regenerate` produced the agent's doc (`## Identity / Name:
Ferrari Admin`).

**Discriminator (the key design choice)**: the two docs share their first three lines
(`# CLAUDE.md` + the "guidance … in this repository" line). The launcher's doc carries a stable,
unique sentence the agent template never emits:

- Launcher doc (`CLAUDE.md`): `## What this repo is` + **`This is **the launcher**, not an agent.`**
- Agent doc (`modules/claude-md.tpl`): `## Identity` (+ `Name:`, `Role:` from `agent.yml`).

**Decision**: add a small helper `_is_launcher_own_claude_md FILE` that greps for the launcher
sentinel (the literal `This is **the launcher**, not an agent`); change the render condition in
`regenerate()` to:

```sh
if [ ! -f "$SCRIPT_DIR/CLAUDE.md" ] || [ "$FORCE_CLAUDE_MD" = true ] || _is_launcher_own_claude_md "$SCRIPT_DIR/CLAUDE.md"; then
  render_to_file "$modules_dir/claude-md.tpl" "$SCRIPT_DIR/CLAUDE.md"
```

An operator-authored agent `CLAUDE.md` lacks the sentinel → preserved (FR-002). No TTY, no
prompt, no manual delete (FR-001, FR-003).

**Alternatives rejected**:
- *Always render in `--non-interactive`* — user chose "surgical" in clarify; clobbers a genuine
  operator-edited doc (violates FR-002).
- *Hash-compare against the launcher's committed `CLAUDE.md`* — brittle: the launcher doc changes
  every release, the hash drifts, and the workspace has no copy of "the launcher's current doc"
  to compare against. A content sentinel is version-stable.
- *Inject a hidden marker into the agent template and treat its absence as "launcher doc"* —
  unneeded; the launcher's existing human-meaningful sentinel already discriminates cleanly.

---

## US2 — `bun` is never provisioned for a fresh local QMD scaffold

**Measured**: `agent-bootstrap.sh` (rendered from `modules/local-bootstrap.sh.tpl`) provisions
runtimes by reading the `.value.command` set from `.mcp.json` and gating each installer. `bun`
is gated on `printf '%s\n' "$cmds" | grep -qx "bunx"` (`local-bootstrap.sh.tpl:219`). But in
local mode the QMD MCP command is the wrapper `scripts/local/agent-qmd-mcp.sh` (feature 016/T036),
**not** literal `bunx`. So a fresh scaffold never provisions `bun`; `ls ~/.local/bin` on ferrari
after `--login` showed `github-mcp-server node npm npx uv uvx` — **no `bun`**. Both the QMD
reindex and the QMD MCP wrapper depend on `~/.local/bin/bun` (their own comments say so). mclaren
is unaffected only because its `bun` was installed in a pre-016 era when qmd's command WAS `bunx`.

**Decision**: extend the bun trigger in `main()` to also fire when the QMD wrapper is present in
the command set:

```sh
if printf '%s\n' "$cmds" | grep -qx "bunx" || printf '%s\n' "$cmds" | grep -q "agent-qmd-mcp.sh"; then
  provision_bun
fi
```

The QMD wrapper is always named `agent-qmd-mcp.sh`, and the render only emits the `qmd` server
when `vault.qmd.enabled` (so QMD-off agents have no such command → no `bun`, FR-005). Testable
with zero downloads via `BOOTSTRAP_DRY_RUN=1`, which emits `PLAN bun …` (FR-006).

**Alternatives rejected**:
- *Read `agent.yml` `vault.qmd.enabled` in the bootstrap* — the provisioner's contract is
  `.mcp.json`-driven (that IS its input); the render already gates the qmd command on `agent.yml`,
  so detecting the wrapper in `.mcp.json` inherits that gate without a second source.
- *`jq` for a server keyed `qmd`* — equivalent but heavier than reusing the existing `$cmds`
  extraction; a `grep` on the command list matches the file's style.

**Note (upstream gap, not fixed here)**: `provision_bun` is only *one* consumer of this gap; the
same "gated on literal `bunx`" shape is the root — the wrapper-detection fix is the minimal,
targeted correction.

---

## US3 — `fetch`/`git` uvx MCPs broken by unpinned `mcp` SDK drift

**Measured**: `provision_uv_tools` (`local-bootstrap.sh.tpl:68-81`) warms each uvx MCP tool with
`uv tool install $py_flag "$pkg"` — **no version constraint**. A fresh scaffold today resolved
`mcp-server-fetch`/`mcp-server-git` **v2026.7.10** together with a newer `mcp` Python SDK that
renamed `McpError` → `MCPError`, so both fail at import: `ImportError: cannot import name
'McpError' from 'mcp.shared.exceptions' … Did you mean: 'MCPError'?`. `atlassian` (`mcp-atlassian`)
connected only because its resolution happened to land compatible. The manual fix that restored
`fetch`/`git` on ferrari: reinstall the **mclaren-validated combo** —
`uv tool install --force mcp-server-fetch==2026.6.4 --with mcp==1.28.1` and
`mcp-server-git==2026.6.16 --with mcp==1.28.1`. Reference versions read from the working mclaren
host: `mcp-server-fetch 2026.6.4`, `mcp-server-git 2026.6.16`, `mcp-atlassian 0.21.1`, `mcp`
lib `1.28.1`.

**Decision (single-source + scope)**:
1. Record the pins in `scripts/lib/versions.sh`, extending the existing MCP-pin convention there
   (`AGENTIC_FLOOR_MCP_FILESYSTEM/_VAULT/_GH_MCP`): add `AGENTIC_FLOOR_MCP_FETCH`,
   `AGENTIC_FLOOR_MCP_GIT`, `AGENTIC_FLOOR_MCP_ATLASSIAN`, `AGENTIC_FLOOR_MCP_LIB`.
2. Inject those values into the rendered `agent-bootstrap.sh` at render time (so the standalone
   provisioner — which cannot source launcher libs — carries the literal pins), and have
   `provision_uv_tools` install each pkg as `pkg==<pin>` with `--with mcp==<MCP_LIB>`.
3. The dry-run plan surfaces the pinned versions (`PLAN uv-tool <pkg>==<ver> (mcp==<lib>)`) so the
   pin is host-testable and mutation-detectable (FR-009, SC-007).
4. **Scope = local only** (decision 2026-08-06). Confirm the exact validated combo empirically at
   implement time: install all three on a clean env and assert `claude mcp list` reports
   `fetch`/`git`/`atlassian` Connected under a single `mcp==1.28.1`; **if** a single `mcp` version
   cannot satisfy all three (e.g. `mcp-atlassian 0.21.1` needs a different `mcp`), the version map
   carries a per-server `mcp` override — the mechanism accommodates it, the default is the shared
   `AGENTIC_FLOOR_MCP_LIB`.

**Alternatives rejected**:
- *Pin only `fetch`/`git`* (clarify option B) — rejected in clarify: `atlassian` works today by
  luck and would drift the same way on a future scaffold.
- *Literals in the template only* — inconsistent with `versions.sh` being the established MCP-pin
  home; single-sourcing there matches Principle VI and keeps a future bump one edit. (The existing
  `UV_VERSION`/`BUN_VERSION` literals in the same template are a pre-existing minor smell, left
  untouched — not propagated.)
- *Pin `mcp` globally without pinning servers* — fragile; a future server release could need a
  newer `mcp`. Pinning the servers to a validated release + a compatible `mcp` is the durable fix.

**DOCKER FOLLOW-UP (out of scope, flagged):** `docker/Dockerfile:122-124` runs
`uv tool install --python python3 mcp-atlassian`, `… mcp-server-fetch`, `… mcp-server-time`
**UNPINNED** → a fresh image build has the identical latent drift. Fixing it means plumbing the
`versions.sh` pins through compose `build.args` into the Dockerfile and re-running `DOCKER_E2E`
on a Docker host. Deferred to a separate feature per the 2026-08-06 scope decision; the pins this
feature adds to `versions.sh` become the ready single source for that follow-up.

---

## US4 — `NEXT_STEPS.md` is never produced by the non-interactive path

**Measured**: after `./setup.sh --non-interactive` on ferrari, `NEXT_STEPS.md` was absent. Cause:
`render_next_steps()` (`setup.sh:1410-1460`) is called only inside `run_wizard` — it selects the
i18n template by `user.language`, injects `{{PLUGINS_BLOCK}}`, renders to `NEXT_STEPS.md`, and
`cat`s it to stdout. `regenerate()` (`setup.sh:1941`, which backs both `--non-interactive` and
`--regenerate`, rendering `CLAUDE.md`/`.mcp.json`/`.env.example` at `2225-2249`) never renders it.
Confirmed the templates are pure derived files: `modules/next-steps.{es,en}.tpl` reference only
`{{AGENT_DISPLAY_NAME}}`, `{{DEPLOYMENT_WORKSPACE}}`, `{{DEPLOYMENT_MODE_IS_DOCKER}}`,
`{{AGENT_NAME}}`, `{{PLUGINS_BLOCK}}` — all derivable from `agent.yml`, **no wizard-only input**.

**Decision**: render `NEXT_STEPS.md` inside `regenerate()`, reusing the existing template
selection + `{{PLUGINS_BLOCK}}` injection from `render_next_steps()`. Refactor the file-write half
into a callable path (e.g. `render_next_steps --quiet` or an extracted `_write_next_steps` helper)
so `regenerate()` writes the file without the interactive stdout `cat`; the wizard path keeps its
current print behavior (FR-013). `NEXT_STEPS.md` is a pure derived guidance file (not
"user-owned"), so it is (re)written on every `regenerate()`/`--regenerate` (FR-010, FR-011,
Principle I). No new template; the docker/local branch already lives in the templates.

**Alternatives rejected**:
- *Document-only in the runbook* — user chose "render as derived" in clarify.
- *A separate minimal NEXT_STEPS for regenerate* — duplicates the i18n + PLUGINS_BLOCK logic;
  reuse is cleaner and keeps one source.

---

## Cross-cutting decisions

- **Version bump**: local-mode runtime behavior changes → `VERSION` `0.17.0 → 0.18.0` (MINOR),
  `CHANGELOG.md` entry. (Precedent: 015 local-mode-hardening bumped MINOR.)
- **No `docker/` files touched** → no `DOCKER_E2E` gate (Constitution III). Docker byte-identical
  (FR-012) verified by a test asserting the docker render path is unchanged.
- **Docs**: `docs/creating-an-agent.md` currently documents the manual `rm CLAUDE.md` + manual
  `bun`/uvx steps as declarative gotchas; those notes are removed/updated once the fixes land
  (the manual steps become automatic).
- **Testability**: everything is host-runnable. The provisioner's `BOOTSTRAP_DRY_RUN=1` plan mode
  is the seam for US2/US3 (no downloads); `regenerate()` file assertions are the seam for US1/US4.
  A live-host confirmation (QMD indexed, `claude mcp list` all-connected) is the SC-001/SC-002
  acceptance, run against a real local host at implement time (ferrari already validated the
  fixes manually — this feature reproduces them from launcher code).
