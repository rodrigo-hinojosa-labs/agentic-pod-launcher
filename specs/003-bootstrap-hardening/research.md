# Research: Bootstrap hardening (003)

**Phase 0 output.** Grounded in a 9-agent code map of the repo (one explorer per story). Every
story is sized as a small, surgical change against an existing seam. The four mechanism
decisions deferred by the spec were resolved via `/refine` (2026-06-20) and are recorded below
with rationale + alternatives. Real file/function citations come from the code map.

## Resolved mechanism decisions (from `/refine`)

| # | Decision | Rationale | Alternatives rejected |
|---|---|---|---|
| **A** | Watchdog detects the **`~/.claude/.credentials.json` absent→present** flip and, on flip, re-runs the plugin-install step, re-decides `next_tmux_cmd`, and **actively kicks the session** to respawn it immediately. | The watchdog already polls every ~2s; the credentials file is the same auth marker `probe_claude_oauth` reads; install is already idempotent. Robust even if the operator never `/exit`s. | (a) Re-run only on tmux respawn — misses the logged-in-and-idle case (the exact bug we hit). (b) tmux-pane scraping to detect `/login` — **forbidden by CLAUDE.md** (reverted for false positives). |
| **B** | Before creating the fork, probe template visibility via `gh api`; if public + private requested, **warn + `ask_choice` proceed-public / disable-fork**. Private non-fork mirror **out of scope**. | "Never silently public" is the real fix; incremental delivery (constitution). gh + PAT already in scope at that point. | Full automated private-mirror path — separate surface, touches `--sync-template`; deferred. |
| **H** | Rewrite the in-container `claude --print` prompt to **preserve ALL existing sections** (scan headers, only ADD missing). | Smallest change; no markup the operator must remember; protects any injection automatically. | `<!-- USER-OWNED -->` sentinel — requires the operator to remember to mark sections. |
| **I** | `agent.yml` gains optional **`role_file` path**; renderer reads it and injects verbatim into CLAUDE.md; `--role-file PATH` flag populates it. | Keeps agent.yml the single source of truth; survives `--regenerate` (Principle I). A path is a single scalar — safe for the flatten engine (a multiline `role:` would risk the `render_load_context` flatten). | (a) flag-only, no agent.yml — would NOT survive `--regenerate` (violates Principle I). (b) inline multiline `role: |` — risks the flatten. |

## Per-story findings (grounded)

### A — login→plugins auto-install (P1)
- **Touchpoints**: `docker/scripts/start_services.sh` — `_run_watchdog` (~764-803), `next_tmux_cmd` (405-445, already calls `ensure_all_plugins_installed` + `_channel_plugin_ready`), `ensure_plugin_installed_one`/`ensure_all_plugins_installed` (168-214, already idempotent via `.installed-ok` sentinel). Auth marker confirmed: `~/.claude/.credentials.json` (read by `probe_claude_oauth`, `docker/scripts/lib/token_health.sh:125-147`).
- **Change**: track prior auth-marker existence across watchdog ticks; on absent→present, set a flag that forces a re-decide on the next respawn (install is re-run via the existing `next_tmux_cmd` path). No new scraping. The independent `_check_auth_banner` notifier flow is untouched.
- **Test seam (host, no Docker)**: source `start_services.sh` with `START_SERVICES_NO_RUN=1` (existing pattern in `tests/start-services-watchdog.bats` + `tests/backup-trigger-plugin-install.bats`); refactor the tick into a unit-testable `_watchdog_tick` taking the auth-marker path; mock the marker + plugin cache in a tmpdir `$HOME`; assert flip detection triggers a (stubbed) re-install exactly once. New file: `tests/watchdog-auth-flip-detection.bats`.

### B — fork-public warning (P1)
- **Touchpoints**: `setup.sh` fork block (474-490) and `scaffold_with_fork` (1269-1366). New helper `gh_get_repo_visibility(template_url, token)` (near the fork block or in `scripts/lib/wizard.sh`).
- **Change**: between template-url and PAT prompts, probe `gh api repos/{owner}/{repo} --jq .visibility`; if `public` and `fork_private=true`, warn and `ask_choice [proceed-public, disable-fork]`; persist the choice to `fork_enabled`/`fork_private` **before** the agent.yml heredoc. **Fail loud** if the probe errors (no silent proceed).
- **Test seam (host)**: mock `gh` via a `$PATH` stub returning `visibility=public`; call the helper directly in `tests/fork-commands.bats`; assert warning text + both branches (disable→`fork_enabled=false`; proceed→`fork_private` stays, operator aware).

### C — plugin retry + diagnostics (P1)
- **Touchpoints**: `docker/scripts/start_services.sh` `ensure_plugin_installed_one` (168-195, the ambiguous `"not authenticated yet or install failed"` log at 193) + `ensure_all_plugins_installed` (202-214); `scripts/agentctl` `cmd_doctor` (293-559); `modules/next-steps.en.tpl`.
- **Change**: extract `retry_plugin_install_bounded(spec, max_attempts)` into new `docker/scripts/lib/plugin-install.sh`; capture stderr, distinguish "not authenticated" (expected skip) from "install failed", retry non-auth failures **3×** with brief backoff; write residual failures to `.state/plugin-install-failures.jsonl`; `cmd_doctor` reads it and prints a copy-paste retry per plugin; `next-steps.en.tpl` renders a failed-plugins section.
- **Test seam (host)**: source with `START_SERVICES_NO_RUN=1`; stub `claude` in `$PATH`; assert outcome codes + state-file contents. New file: `tests/start-services-plugin-install.bats`.

### D — destination validation (P2)
- **Touchpoints**: new `validate_destination_path()` in `scripts/lib/wizard-validators.sh` (mirror `validate_workspace_path` 126-147); wire into `setup.sh` interactive prompt (~446) via `ask_validated`, edit action (~894), and `scaffold_destination` pre-check (~1547-1580, which today only rejects ==$HOME / already-exists).
- **Change**: reject non-absolute; expand leading `~`; reject mid-path `~`; on Darwin warn on `/home/...`.
- **Test seam (host)**: pure string/fs validation; `tests/wizard-validators.bats` calls it directly; integration via piped `wizard_answers()` in `tests/setup.bats`.

### E — agent-name normalization (P2)
- **Touchpoints**: `setup.sh` normalization block (399-408, today `tr '[:upper:]' '[:lower:]' | tr -d ' '` — strips spaces, no hyphens); validator `validate_agent_name` (`wizard-validators.sh` 87-108) stays as-is (validates the normalized result).
- **Change**: extract `normalize_agent_name()` (lowercase → spaces-to-hyphens → collapse `--` → trim leading/trailing `-`); show raw vs normalized and `ask_yn` confirm before accepting.
- **Test seam (host)**: new `tests/agent-name-normalization.bats` calls `normalize_agent_name` directly ("Rodri Cenco Admin"→"rodri-cenco-admin", "my  --  agent"→"my-agent", " -leading"→"leading"); idempotent (re-normalizing a normalized name is a no-op → `--regenerate`-safe).

### F — quickstart doc/wizard sync (P2)
- **Touchpoints**: `tests/quickstart-doc.bats` (add a case); `docs/agentic-quickstart.es.md` (CONSTRUCCIÓN DEL STDIN, ~137-160) + `docs/agentic-quickstart.en.md` (STDIN BUILD); canonical order in `tests/helper.bash::wizard_answers()` (107-111); catalog via `scripts/lib/mcp-catalog.sh` + `modules/mcps/*.yml`.
- **Change**: insert the **6 optional catalog MCPs** (aws, firecrawl, google-calendar, playwright, time, tree-sitter) as a step between notif and Atlassian in both docs; add a bats case that sources `mcp_catalog_list optional` and fails if any optional MCP is missing from the doc's wizard-order section.
- **Test seam (host)**: pure file reads + catalog sourcing; mirrors existing `quickstart-doc.bats` ES/EN-sync tests.

### G — backup spam when fork off (P3)
- **Touchpoints**: `docker/scripts/start_services.sh` `_check_identity_backup` (729-758, logs "identity backup triggered (watchdog-hash-change)" each tick); pattern to mirror: `heartbeatctl::_bi_run` early-exit when `fork_url` empty (573-576).
- **Change**: early-exit guard at the top of `_check_identity_backup` — read `.scaffold.fork.url` from agent.yml; if empty/null, `return 0` before hashing or logging.
- **Test seam (host)**: source with `START_SERVICES_NO_RUN=1`; agent.yml fixture without `scaffold.fork.url`; stub `_trigger_identity_backup`; assert it is NOT called and no line logged. Add to `tests/start-services-watchdog.bats`.

### H — CLAUDE.md refresh preserves all sections (P3) — **the one Docker-e2e case**
- **Touchpoints**: `docker/scripts/wizard-container.sh` refresh block (44-97, prompt HEREDOC 56-76 currently preserves only Identity/User/Core Truths/Boundaries/Execution Strategy).
- **Change**: rewrite the prompt to "scan ALL existing `## ` headers, preserve every section verbatim, only ADD missing command/architecture/test sections, Edit not Write, no-op if complete." Keep the 90s timeout + fail-silent skip.
- **Test seam**: **split.** (1) **Host (default suite):** verify the prompt TEXT contains the new contract keywords (e.g. "preserve ALL", "do not edit or reorder", "scan … section headers") by capturing the HEREDOC without executing `claude` — a pure grep, no Docker. (2) **`DOCKER_E2E=1` (opt-in):** boot a container, inject a `## Marker` section, trigger the refresh, assert the marker survives byte-for-byte. This is the **only** story whose full behavioral assertion needs Docker; the default suite still gets a real (text-contract) test, satisfying Principle III.

### I — multi-line persona via role_file (P3)
- **Touchpoints**: `setup.sh` `parse_args` (350-373, add `--role-file`), wizard role prompt (375-412), agent.yml heredoc (986-1001, write `role_file:`); `scripts/lib/render.sh` `render_load_context` (7-33, read `role_file` → export `AGENT_ROLE_MULTILINE`); `modules/claude-md.tpl` Identity section (7-11, conditional inject); `scripts/lib/schema.sh` (optional path leaf); fixture `tests/fixtures/sample-agent-with-vault.yml`.
- **Change**: optional `agent.yml.role_file` scalar path; when set, render reads the file and injects verbatim (else the one-line `role`); `--role-file` flag writes the field; **fail loud** if the path is set but missing/unreadable.
- **Test seam (host)**: source `render.sh` + `yaml.sh`; tmpdir agent.yml with `role_file` → assert `AGENT_ROLE_MULTILINE` equals file content; template-inject test; missing-file → clear error.

## Cross-cutting notes
- **8/9 stories: host bats, no Docker.** Only **H** needs `DOCKER_E2E=1` for behavior, and even H gets a host text-contract test — so `bats tests/` stays Docker-free (Principle III). ✔
- **No least-privilege change** anywhere (Principle II): all changes are wizard logic, watchdog shell, prompt text, render, or docs/tests. ✔
- **agent.yml stays source of truth** for B (`fork.enabled/private`), I (`role_file`); both survive `--regenerate` (Principle I). ✔
- **Retry budget (C)** finalized at **3 attempts, short backoff** (recommended default; revisit if upstream `claude plugin install` proves slow).
- **shellcheck -S error** must stay clean on all touched shell (Principle III).
