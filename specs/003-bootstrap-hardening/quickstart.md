# Quickstart: verify Bootstrap hardening (003)

The default suite is host-only (no Docker). Story H is the only one with a `DOCKER_E2E=1`
behavioral test; everything else is plain `bats tests/`.

## Run the feature's tests

```bash
# Full default suite (host, no Docker) — must stay green
bats tests/

# Per-story (host)
bats tests/watchdog-auth-flip-detection.bats      # A
bats tests/fork-commands.bats                      # B
bats tests/start-services-plugin-install.bats      # C
bats tests/wizard-validators.bats                  # D (destination)
bats tests/agent-name-normalization.bats           # E
bats tests/quickstart-doc.bats                      # F
bats tests/start-services-watchdog.bats             # G
bats tests/wizard-container-refresh.bats            # H (prompt-text contract)
bats tests/render.bats                              # I

# Story H behavioral assertion (opt-in, builds + boots a container)
DOCKER_E2E=1 bats tests/docker-e2e-claude-md-refresh.bats
```

## Manual acceptance (per tier)

### P1
- **A**: scaffold an agent, `agentctl up`, attach, `/login`, `/exit` (no manual restart). After the next respawn, `agentctl doctor` shows all plugins installed and the session is channel-enabled.
- **B**: run `./setup.sh` with fork enabled + private against the **public** template → the wizard warns "will be PUBLIC" and offers proceed-public / disable-fork before creating anything.
- **C**: with a plugin that fails to install, the boot log shows `plugin install failed (attempt N/3)` (not the old ambiguous line), and `agentctl doctor` lists it with a copy-paste retry.

### P2
- **D**: `./setup.sh --destination ./relative` → rejected (non-absolute). `--destination '/home/me/~/x'` on macOS → rejected (mid-path `~`) and warns about `/Users`.
- **E**: enter agent name `Rodri Cenco Admin` → shown normalized to `rodri-cenco-admin`, confirm before use.
- **F**: edit the quickstart doc to drop an optional MCP from the wizard-order section → `bats tests/quickstart-doc.bats` fails.

### P3
- **G**: boot a fork-less agent; `docker logs <agent>` over ~10 min shows **zero** "identity backup triggered" lines.
- **H**: inject `## My Notes` into a scaffolded `CLAUDE.md`, boot (triggers the in-container refresh), confirm `## My Notes` survives byte-for-byte (covered by the `DOCKER_E2E` test).
- **I**: `./setup.sh --role-file persona.md` with a multi-paragraph `persona.md` → the generated `CLAUDE.md` `## Identity` contains the full text; `./setup.sh --regenerate` keeps it.

## Expected

- `bats tests/` stays green with no Docker daemon (Principle III).
- Each story's red test (pre-fix) goes green (post-fix); no regressions in the existing ~195-test suite.
- `shellcheck -S error` clean on all touched shell.
