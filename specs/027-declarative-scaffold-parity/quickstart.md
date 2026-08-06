# Quickstart / Validation: Declarative Local-Scaffold Parity

## Host gates (no Docker, no network) — the required suite

```bash
# full host suite on both bash flavors (SC-006)
bats tests/                                   # bash 5.x
PATH=/bin:$PATH bats tests/                    # bash 3.2.57 (macOS stock)
shellcheck -S error $(git ls-files '*.sh' 'modules/*.tpl' 2>/dev/null)   # per repo gate

# focused
bats tests/local-bootstrap.bats               # US2 (bun gate) + US3 (pins) via BOOTSTRAP_DRY_RUN=1
bats tests/regenerate.bats                     # US1 (identity) + US4 (NEXT_STEPS)
```

### US2 — bun gate (dry-run, no download)
```bash
# QMD-enabled fixture (.mcp.json has the agent-qmd-mcp.sh wrapper command)
BOOTSTRAP_DRY_RUN=1 <rendered agent-bootstrap.sh>   # expect a `PLAN bun …` line
# QMD-disabled fixture → expect NO `PLAN bun`
```

### US3 — pins surfaced (dry-run)
```bash
BOOTSTRAP_DRY_RUN=1 <rendered agent-bootstrap.sh>   # expect:
#   PLAN uv-tool mcp-server-fetch==2026.6.4 (mcp==1.28.1)
#   PLAN uv-tool mcp-server-git==2026.6.16 (mcp==1.28.1)
#   PLAN uv-tool mcp-atlassian==<pin> (mcp==<lib>)
# versions must equal versions.sh, never unpinned
```

### US1 — identity render
```bash
# Arrange a workspace whose CLAUDE.md is the launcher's own dev doc, then:
./setup.sh --non-interactive
grep -q 'This is \*\*the launcher\*\*, not an agent' CLAUDE.md && echo FAIL || echo OK  # want OK
grep -q '## Identity' CLAUDE.md && echo OK   # agent doc present
# Operator-doc case: a CLAUDE.md WITHOUT the sentinel must be preserved byte-for-byte on --regenerate
```

### US4 — NEXT_STEPS render
```bash
./setup.sh --non-interactive
test -f NEXT_STEPS.md && echo OK             # present now (was absent pre-fix)
./setup.sh --regenerate && test -f NEXT_STEPS.md   # re-produced, idempotent
```

### Mutation gate (SC-007)
Revert each of the four fixes in turn; at least one new test must go red for each:
- revert US1 discriminator → identity test red
- revert US2 wrapper trigger → `PLAN bun` test red
- revert US3 pins → pin-surfacing test red
- revert US4 regenerate render → NEXT_STEPS-present test red

## Live-host acceptance (a real local systemd host) — SC-001 / SC-002

On a fresh declarative local scaffold (clone → agent.yml → `--non-interactive` → `--login`),
with **no manual runtime steps**:

```bash
# US1: agent identity
head -8 <ws>/CLAUDE.md                         # the agent's ## Identity, not the launcher's framing

# US2: QMD works
cat <ws>/scripts/heartbeat/qmd-index.json      # last_status: indexed, pending: 0
#   qmd MCP connects (see below)

# US2+US3: all project MCPs connect
cd <ws>; set -a; . ./.env; set +a
CLAUDE_CONFIG_DIR=<ws>/.state/.claude PATH=$HOME/.local/bin:$PATH claude mcp list
#   fetch ✔  git ✔  filesystem ✔  atlassian ✔  github ✔  vault ✔  qmd ✔   (7/7)

# US4
test -f <ws>/NEXT_STEPS.md
```

Note: `ferrari-admin` already validated all four fixes **manually** on 2026-08-05; this feature
reproduces them from launcher code so the next scaffold needs none of those manual steps. A
re-scaffold or a `--regenerate` + `--login` on a throwaway local workspace is the clean gate.

## Docker non-regression (FR-012)

```bash
# a docker-mode agent.yml render must be byte-identical to pre-feature output for the
# provisioner/render paths this feature touches (assert in bats; no DOCKER_E2E needed since no
# docker/ file changes).
```
