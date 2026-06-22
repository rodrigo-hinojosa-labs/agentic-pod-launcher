# Quickstart: verifying 004-macos-bootstrap-hardening

Two layers, per the constitution (Principle III): the **default bats suite** (no Docker) asserts the Dockerfile/template *shape* and the host-sourced retry lib; **`DOCKER_E2E=1`** asserts runtime *behavior*. Each fix must be red→green.

## Default suite (no Docker)

```bash
bats tests/                 # full suite stays green
shellcheck -S error docker/scripts/start_services.sh scripts/lib/versions.sh
```

Per-fix shape assertions to add/extend:

- **P1**: a Dockerfile test asserts `NPM_CONFIG_CACHE=/opt/npm-cache` (off `/home/agent`), `NPM_CONFIG_PREFER_OFFLINE=true`, a warm `RUN` for each default npx MCP package, and a numeric `chown ${UID}:${GID}` of the cache. A render test (`modules-render.bats`) asserts `.mcp.json` no longer emits `@latest` for vault (pinned spec matches the warmed build spec).
- **P2**: `start-services-*.bats` asserts (via the `START_SERVICES_NO_RUN=1` + `AUTH_MARKER_OVERRIDE` + mocked-`claude` seams) that the credential flip arms a `~120s` deadline, that `_post_login_plugin_retry` is idempotent (no-ops once all `.installed-ok` sentinels exist), kicks the session exactly once on completion, and clears the deadline on timeout without re-kicking.
- **P3**: `modules-render.bats` asserts the rendered github MCP block uses `command: "github-mcp-server"` + `args: ["stdio"]` (no `npx` / `@modelcontextprotocol/server-github`) and keeps `GITHUB_PERSONAL_ACCESS_TOKEN: ${GITHUB_PAT}`. A Dockerfile test asserts the pinned `github-mcp-server` download stanza + checksum verify.
- **Pinning (VI)**: `versions.bats` asserts the new npm-MCP and `github-mcp-server` pins are tracked so the Dockerfile-vs-`versions.sh` drift guard stays meaningful.

## Behavior suite (`DOCKER_E2E=1`)

```bash
DOCKER_E2E=1 bats tests/docker-e2e-*.bats     # builds the image + boots a container
```

- **P1**: from the built image, `su-exec agent npx -y @modelcontextprotocol/server-filesystem --help` (and the vault spec) resolves with **no network** — e.g. run it under an offline probe and assert exit 0 + no `errno -35`. Confirm the warm `_npx`/`_cacache` live under `/opt/npm-cache`, not `/home/agent`.
- **P3**: `github-mcp-server --version` runs in the built image (exit 0); with a test `GITHUB_PAT`, the MCP handshake succeeds.
- **P2**: boot a container, simulate the credential flip (drop the mocked `.credentials.json`), and assert all declared plugins reach `.installed-ok` within the budget with no manual `plugin install`, and that the channel attaches.

## End-to-end smoke (real macOS scaffold)

```bash
./setup.sh --destination ~/agents/e2e-004     # fresh scaffold (fork-less, minimal)
cd ~/agents/e2e-004 && docker compose build && ./scripts/agentctl up
./scripts/agentctl attach                     # /login once
# after /login, WITHOUT manual steps:
./scripts/agentctl doctor                     # no "Telegram plugin not running" once budget elapses
docker exec -u agent -e CLAUDE_CONFIG_DIR=/home/agent/.claude e2e-004 \
  claude mcp list                             # vault, filesystem, github → Connected
```

Success = SC-001 (`vault`/`filesystem` connected), SC-002 (`github` connected), SC-003 (plugins auto-installed post-login). Re-run on a Linux host for SC-005 (no regression).
