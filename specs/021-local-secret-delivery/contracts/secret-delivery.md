# Contract: secret delivery in local mode

Three surfaces: the session unit, the healthcheck's alert path, and the diagnosis
(doctor + boot warn). Nothing else receives secrets.

## 1. The session unit (`modules/systemd-remote-control.service.tpl`)

```ini
[Service]
EnvironmentFile=-{{DEPLOYMENT_WORKSPACE}}/.env                      # NEW — MUST be first
EnvironmentFile={{DEPLOYMENT_WORKSPACE}}/.state/remote-control.env  # MUST stay second
ExecStartPre=-{{DEPLOYMENT_WORKSPACE}}/scripts/local/agent-secret-check.sh
```

**Invariants** (each has a test):

| # | Invariant | Why it is load-bearing |
|---|---|---|
| U1 | The `.env` line appears **strictly before** the `remote-control.env` line | systemd: the **later** file wins. A stray `PATH=`/`HOME=`/`CLAUDE_CONFIG_DIR=` in `.env` must never beat the launcher's. A wrong `PATH` `ENOENT`s every MCP spawn — the historical `203/EXEC` failure. |
| U2 | The `.env` line carries the `-` prefix | Missing/unreadable/invalid `.env` → **no-op**, not a unit failure. This IS FR-004, enforced by systemd rather than by our code. |
| U3 | `ExecStartPre` carries the `-` prefix **and** the script exits 0 unconditionally | Without the `-`, a failing `ExecStartPre` marks the unit **failed**. Belt and braces. |
| U4 | The four timer units (qmd-reindex, qmd-watch, vault-backup, wiki-graph) have **no** `EnvironmentFile` | Least privilege. Asserted **negatively**. |
| U5 | `Environment=` is never used for a secret | systemd's own man page: `Environment=` values are exported over D-Bus. |

**Delivery to the MCPs is transitive and needs no extra wiring**: Claude Code expands
`${VAR}` in `.mcp.json` from its **own process environment** and spawns the MCP
servers itself. Giving the session the env gives every MCP the env — with the
accepted consequence that *every* MCP server sees *every* secret (the filesystem MCP
can read `GITHUB_PAT`). This is parity with docker's `env_file`, and it is stated,
not hidden.

## 2. The healthcheck (`modules/local-healthcheck.sh.tpl`)

**Resolution order** (the compatibility override the user chose):

```
if [ -r <workspace>/.state/healthcheck-notify.env ]; then SRC=<that file>   # LEGACY — wins
else                                                      SRC=<workspace>/.env
fi
NOTIFY_BOT_TOKEN=$(env_file_get NOTIFY_BOT_TOKEN "$SRC")
NOTIFY_CHAT_ID=$(env_file_get  NOTIFY_CHAT_ID  "$SRC")
```

| # | Invariant |
|---|---|
| H1 | The legacy file wins when readable — a live agent that hand-made one keeps working (SC-005). |
| H2 | A fresh scaffold **never creates** the legacy file, and nothing instructs the operator to. |
| H3 | The reader **never sources**: no `.`, no `eval`, no command substitution on file content. Proven by a canary line in the fixture (`FOO=$(touch /tmp/pwned)`) that must not fire. |
| H4 | Only `NOTIFY_BOT_TOKEN` and `NOTIFY_CHAT_ID` are read. Nothing else from `.env` enters the healthcheck's environment. |
| H5 | The token still reaches `curl` via `--config -` on **stdin** — never argv, never the journal. (Already test-pinned; must survive.) |
| H6 | The healthcheck unit gains **no** `EnvironmentFile` — `User=` already lets it read a `0600` operator-owned file. |

## 3. Diagnosis: the doctor check and the boot warn

Both use the **same** detection logic and the same lib.

**Required-secret set** — derived from `agent.yml` + the MCP catalog
(`requires_secret` / `secret_env_var` in `modules/mcps/*.yml`), **never** by grepping
the rendered `.mcp.json`:

- Grepping `${VAR}` out of `.mcp.json` produces **permanent false positives** on every
  AWS agent: `mcp-json.tpl:41-42` references `AWS_PROFILE`/`AWS_REGION`, but
  `modules/mcps/aws.yml` declares `requires_secret: false` and the wizard never writes
  them to `.env`. US3 scenario 3 forbids crying wolf.
- The catalog **is** present in a local workspace (`setup.sh:1805-1809` — only the
  `docker` dir is skipped in local mode).

**Exclusions** (or the check cries wolf on every healthy agent):

| Variable | Treatment | Why |
|---|---|---|
| `GITHUB_FORK_PAT` | ignored | no session/MCP consumer |
| `CLAUDE_CODE_OAUTH_TOKEN` empty | **INFO, never WARN** | the normal state of every `/login`-based local agent |
| any `secret_env_var` of a **disabled** MCP | ignored | not enabled ⇒ not required |
| a **set-but-empty** required value | **counts as missing** | FR-005 |

**Doctor (`_local_secrets_doctor`, called after `_local_vault_qmd_doctor`)** — WARN
(exit 1) only, **never** `_doctor_fail`:

| # | Check |
|---|---|
| D1 | `.env` exists, mode `0600`, owned by the operator (the docker path has this; **local has none today**) |
| D2 | `env_file_lint` findings — line + key + reason, **never a value** |
| D3 | **The installed unit carries the `.env` `EnvironmentFile`** — catches the silent no-op where the operator ran `--regenerate` but never `sudo cp` + `restart` |
| D4 | Each required secret is present and non-empty |

Message shape: `<VAR> missing or empty in <workspace>/.env`, plus the catalog's
`secret_doc_url` as the hint. **Names and paths only — never a value.**

**Boot warn** (`scripts/local/agent-secret-check.sh`, rendered from
`modules/local-secret-check.sh.tpl`): same detection, prints WARN to **stderr**
(→ `journalctl -u agent-<name>`), **exits 0 unconditionally**.

**Silence on a healthy agent is part of the contract** (US3 scenario 3): a correctly
configured agent produces **no** secrets warning from either surface.

## 4. Hard prohibitions

| Never | Because |
|---|---|
| Create any file named `.env` under `.state/` | `backup_identity.sh:72,152-154` already age-encrypts exactly that path — it would start pushing secret material to the fork's `backup/identity` branch. |
| Put secrets into `.state/remote-control.env` | It is loaded **without** `-`: one un-re-quotable value turns "no secrets" into "**the agent will not start**" (FR-004 violation). |
| Put an `EnvironmentFile` on the qmd / vault / wiki-graph / healthcheck units | Least privilege; none of them consumes a secret. |
| Use `Environment=` for a secret | Exported over D-Bus (systemd's own warning). |
| Print a secret value anywhere | FR-006 / SC-006. |
