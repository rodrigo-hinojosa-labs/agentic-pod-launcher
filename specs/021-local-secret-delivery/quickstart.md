# Quickstart: Secret delivery in local mode (021)

## Host gates (must pass before the PR)

```bash
# SC-007 — no regression: the suite stays at the 977 baseline
bats tests/

# the new unit test file
bats tests/env-file.bats

# shellcheck (Principle III)
shellcheck -S error scripts/lib/env_file.sh scripts/agentctl setup.sh

# docker is UNCHANGED: no EnvironmentFile leaked into the compose render,
# and the .mcp.json diff is only ${VAR} -> ${VAR:-}
bats tests/modules-render.bats
```

**Do not trust a green bats run on its own.** The negatives this feature needs
(*"no secret value in the doctor's output"*, *"the healthcheck never sourced the
file"*, *"the timers have no EnvironmentFile"*) are exactly the shape that **passes
silently** in this suite (a mid-body `[[ ]]` or a `!`-negated pipeline does not fail a
test — dead assertions already exist at `tests/agentctl-local.bats:94-95,204,268`).
Every new negative uses `run grep` + `[ "$status" -ne 0 ]` or lands last, and the
implementation runs a **RED phase + a mutation spot-check** (the 019 lesson).

## Hardware gate (mclaren — cannot be run on the macOS host)

The whole point of the feature is a systemd behavior. The host suite proves the
*rendered* artifacts; only real hardware proves the *runtime*.

```bash
AGENT=agent-mclaren-admin
WS=/home/rodrigo-hinojosa/Documents/Personal/Claude/Agents/mclaren-admin

# 1. Both files are loaded, .env with the ignore flag
systemctl show "$AGENT.service" -p EnvironmentFiles

# 2. The secret actually reached the process — COUNT ONLY, never print the value
sudo tr '\0' '\n' < /proc/$(systemctl show -p MainPID --value "$AGENT.service")/environ \
  | grep -c '^GITHUB_PAT='            # expect 1   (pre-021 baseline, measured: 0)

# 3. systemctl leaks no values
systemctl show "$AGENT.service" -p Environment          # expect: no secrets

# 4. FR-004 — a corrupted .env must NOT stop the agent
printf '\xEF\xBB\xBF' | cat - "$WS/.env" > /tmp/bom.env   # BOM at the front
cp "$WS/.env" "$WS/.env.bak" && cp /tmp/bom.env "$WS/.env"
sudo systemctl restart "$AGENT.service" && systemctl is-active "$AGENT.service"   # expect: active
journalctl -u "$AGENT" -n 30 | grep -i 'secret'          # expect: the ExecStartPre WARN
cp "$WS/.env.bak" "$WS/.env" && sudo systemctl restart "$AGENT.service"

# 5. The doctor sees a blanked key, names it, and the agent still runs
./scripts/agentctl doctor                                 # expect: exit 1, WARN naming the var

# 6. A real catalog MCP authenticates from the live session
#    (github or atlassian-mclaren — both are declared and credential-less today)

# 7. Record the coredump residual (accepted, documented)
cat /proc/sys/kernel/core_pattern
```

**Pre-021 baseline, measured on mclaren 2026-07-13** — this is the bug, on production
hardware:

```
$ tr '\0' '\n' < /proc/<MainPID>/environ | grep -cE '^(GITHUB_PAT|ATLASSIAN_MCLAREN_TOKEN)='
0
```

The agent's `.mcp.json` declares 7 MCPs and references 6 variables. Its session
environment has **none** of them.

## Upgrade path for a live local agent

Verified against the code, not invented. **The restart is mandatory** — systemd reads
`EnvironmentFile` at process **spawn**, and nothing in `setup.sh` ever restarts the
unit.

```bash
./setup.sh --regenerate

# ONLY if regenerate printed "staged in workspace (sudo unavailable)":
sudo cp ./agent-<name>.service /etc/systemd/system/

sudo systemctl daemon-reload
sudo systemctl restart agent-<name>.service     # MANDATORY
./scripts/agentctl doctor                       # must be clean
```

**`./setup.sh --login` is NOT an upgrade path** — it refuses to overwrite an existing
unit (`local-login.sh.tpl:98`).

**The trap this sequence exists to prevent**: `--regenerate` re-installs the
root-owned unit **only** when `deployment.install_service: true` *and* `sudo -n`
succeeds; otherwise it stages the file and **exits 0**. An operator who stops there
gets a perfect workspace and an agent still running the old, secretless environment.
That is why doctor check D3 inspects the **installed** unit and not just the
workspace.

## Before rolling out — 5-second checks

- Does mclaren's `agent.yml` have `deployment.install_service: true`?
- Does its live `.env` contain any non-portable line? (`env_file_lint` will say.)
- **Does any live agent use an Atlassian alias containing a dash?** If so, its token
  **leaks into the journal** the moment the new unit starts. (mclaren's alias is
  `mclaren` — clean. Check ferrari.)
- Does `.state/healthcheck-notify.env` exist anywhere in the wild? (Nothing in the
  launcher has ever created it.)

## Artifacts

- [spec.md](spec.md) — 3 stories, 12 FR, 7 SC; the 3 clarifications resolved.
- [research.md](research.md) — R0-R8; the systemd/compose divergence table, the
  exposure analysis, and the live mclaren measurement.
- [contracts/env-file-format.md](contracts/env-file-format.md) — the portable subset.
- [contracts/secret-delivery.md](contracts/secret-delivery.md) — unit / healthcheck /
  doctor invariants + the hard prohibitions.
- [data-model.md](data-model.md) — the required-secret derivation and the three
  delivery states.
