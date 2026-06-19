# Quickstart: Upgrading the In-Container Toolchain

Audience: operators of a scaffolded agent, and launcher maintainers. Assumes the
001-deps-upgrade feature is implemented.

## Concept (30 seconds)

The image toolchain (Claude Code, Alpine base, `uv`, `bun`, `gum`) tracks the
**latest stable of the moment** via *channels* — nothing is hardcoded. The
concrete versions are **recorded in `agent.yml`** so builds are reproducible and
the running container never auto-updates. You move forward on demand.

## Operator: upgrade everything to latest stable

```bash
cd ~/agents/my-agent

# 1. Re-resolve channels → record new concrete versions into agent.yml
./scripts/agentctl versions --upgrade
#   prints e.g.  claude_code 2.1.119 → 2.1.170   alpine 3.20 → 3.24.1   uv … bun … gum …
#   (pinned components are skipped; offline → keeps current + warns)

# 2. Rebuild the image with the recorded versions and restart
docker compose build
./scripts/agentctl up

# 3. Verify
./scripts/agentctl versions          # recorded versions per component
./scripts/agentctl run claude --version
```

## Operator: upgrade just Claude Code

`--upgrade` moves every channel-tracked component. To move only Claude Code, pin
the others first (see below), or edit the single recorded value:

```bash
# set a specific Claude Code version in the ONE place
yq -i '.docker.claude_code_version = "2.1.170"' agent.yml
yq -i '.docker.toolchain_channels.claude_code = "pinned"' agent.yml   # opt out of auto-track
./setup.sh --regenerate
docker compose build && ./scripts/agentctl up
./scripts/agentctl run claude --version    # -> 2.1.170 (Claude Code)
```

## Operator: see what's outdated (no changes made)

```bash
./scripts/agentctl versions --check
#   component     recorded   channel   latest    status
#   claude_code   2.1.170    stable    2.1.170   current
#   alpine        3.20       latest    3.24.1    outdated
#   uv            0.5.14     latest    0.11.22   outdated
#   …
#   (no network → latest column shows "unknown"; never errors)
./scripts/agentctl versions --check --json     # machine-readable
```

`./scripts/agentctl doctor` also shows the recorded toolchain versions (no network).

## Operator: pin a component (freeze it)

```bash
yq -i '.docker.uv_version = "0.11.22"' agent.yml
yq -i '.docker.toolchain_channels.uv = "pinned"' agent.yml
./setup.sh --regenerate
# `agentctl versions --upgrade` will now leave uv untouched.
```

## First scaffold

`./setup.sh` resolves each channel and records the concrete latest-stable versions
into the new `agent.yml` automatically — you start current with no extra step.
(Offline first-scaffold falls back to a documented last-known floor and warns.)

## Maintainer: change a default channel

Channels — not version numbers — live in `scripts/lib/versions.sh`:

```sh
AGENTIC_CHANNEL_CLAUDE_CODE="stable"   # change to "latest" to track the npm latest tag instead
```

Then run the host suite:

```bash
bats tests/                                   # default suite (no Docker)
DOCKER_E2E=1 bats tests/docker-e2e-heartbeat.bats   # required when Alpine/boot changed
shellcheck -S error scripts/lib/versions.sh scripts/agentctl
```

## Done-when (maps to Success Criteria)

- `agentctl run claude --version` reports the recorded version (SC-001).
- No managed version literal is duplicated across sources (SC-002).
- `agentctl versions --check` flags outdated components in one command (SC-003).
- After `--upgrade`, all five run latest stable (SC-004).
- `bats tests/` passes with no Docker; two `--regenerate`s without an `--upgrade`
  yield identical build config (SC-005).
