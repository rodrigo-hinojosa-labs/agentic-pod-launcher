# Data Model: Secret delivery in local mode (021)

No database, no schema migration. The "entities" are the files that carry secrets and
the derivation that decides which secrets are *required*.

## Secrets file — `<workspace>/.env`

| Property | Value |
|---|---|
| Owner / mode | the operator / `0600` (`setup.sh:1232`) |
| Written by | the wizard, at scaffold only |
| **Never** rewritten by | `--regenerate` (it renders `.env.example`, not `.env` — `setup.sh:2187-2189`) |
| Read by (docker) | compose `env_file` (`docker-compose.yml.tpl:67`) |
| Read by (local, **new**) | the session unit's `EnvironmentFile=-`; the healthcheck via `env_file_get`; the doctor / boot-check via `env_file_lint` + `env_file_get` |
| Committed | never (gitignored) |
| Format | the **portable subset** — see [contracts/env-file-format.md](contracts/env-file-format.md) |

Keys the wizard can emit (`setup.sh:1210-1232`): `CLAUDE_CODE_OAUTH_TOKEN` (always
written **empty**), `NOTIFY_BOT_TOKEN`, `NOTIFY_CHAT_ID`, `ATLASSIAN_<ALIAS>_*` (×5
per instance), `GITHUB_PAT`, `GITHUB_FORK_PAT`, and one line per optional-MCP secret.

## Legacy override — `<workspace>/.state/healthcheck-notify.env`

| Property | Value |
|---|---|
| Created by | **nothing** — hand-made by an operator who hit the bug |
| Read by | the local healthcheck (`local-healthcheck.sh.tpl:14,101`) |
| Status after 021 | **compatibility override**: wins when readable; a fresh scaffold never creates it; no doc tells an operator to make one |
| Lifecycle | frozen. Not extended, not migrated, not deleted. |

## Required-secret set (derived — this is the interesting one)

Not a stored entity. Computed, at doctor/boot-check time, from two sources:

```
required = { d.secret_env_var
             | m in agent.yml .mcps (enabled)
             , d = catalog descriptor modules/mcps/<m>.yml
             , d.requires_secret == true }
         ∪ { ATLASSIAN_<ALIAS>_TOKEN, …_JIRA_URL, …_JIRA_USERNAME,
             …_CONFLUENCE_URL, …_CONFLUENCE_USERNAME
             | ALIAS in agent.yml .mcps.atlassian[] }
         ∪ { GITHUB_PAT  if the github MCP is enabled }
         − { GITHUB_FORK_PAT }                       # no session/MCP consumer
```

**It MUST NOT be derived by grepping `${VAR}` out of the rendered `.mcp.json`.**
`mcp-json.tpl:41-42` references `AWS_PROFILE`/`AWS_REGION`, but `modules/mcps/aws.yml`
declares `requires_secret: false` and the wizard never writes those keys — so grepping
would WARN forever on every AWS agent, and US3 scenario 3 forbids crying wolf.

The catalog **is** available in a local workspace: `setup.sh:1805-1809` copies
`modules/`, `scripts/` and (docker only) `docker/` — only `docker` is skipped in local
mode.

### Per-variable state

| State | Meaning | Doctor |
|---|---|---|
| present, non-empty | delivered | silent |
| key absent | not provided | **WARN** |
| key present, value empty | not provided (FR-005) | **WARN** |
| `CLAUDE_CODE_OAUTH_TOKEN` empty | normal for a `/login` agent | **INFO**, never WARN |
| belongs to a disabled MCP | not required | silent |

## Delivery state (the thing the upgrade can silently get wrong)

| State | How it happens | Detected by |
|---|---|---|
| **Delivered** | the *installed* unit carries `EnvironmentFile=-…/.env` **and** the unit has been restarted since | the agent works; doctor silent |
| **Rendered but not installed** | `--regenerate` ran, but `install_service` is false or `sudo -n` failed → the unit was only *staged* into the workspace (`setup.sh:2380-2390`) | **doctor D3** (inspect the installed unit, not the template) |
| **Installed but not restarted** | `sudo cp` + `daemon-reload` done, no `restart` — `EnvironmentFile` is read at **spawn** | doctor D3 + the quickstart's mandatory `systemctl restart` |

The middle and bottom rows are why the doctor must inspect the **installed** unit: a
check that only reads `.env` would call a still-secretless agent **green**.
