# Field evidence — 2026-09-18 live deploy of v0.25.0 to ferrari

Everything on this page was measured during the live gate of feature 034 (T028), on the operator's
own hardware, against two production agents. It is the primary source for feature 036; nothing here
is inferred.

Host: `ferrari` (LAN, plain SSH). Both agents are docker-mode, both were on launcher **v0.23.0**
before the deploy (so the same swap also carried 033, whose live gate had never run).

## 1. What was deployed and how

Launcher files were rsync'd from the operator's Mac (uncommitted branch `034-voice-spoken-style`)
into each workspace, following `README.md:348-406` ("Upgrade an existing agent"), with step 1
(`git pull`) replaced by the rsync of the working tree:

- `modules/`, `docker/` — `rsync --delete` (wipe-and-copy, per the README's orphan rule)
- `scripts/` — `rsync` without `--delete` (preserves live state)
- `setup.sh`, `VERSION`, `.gitignore`, `LICENSE` — copy-over

Backups taken first, still on the host: `/tmp/agent-upgrade-backups/{linus,donna}-pre-034-*.tar.gz`.

`linus`: `./setup.sh --regenerate` → `docker compose build` → `agentctl up`.
`donna`: same, except `--regenerate` was run **through** the overlay wrapper
(`~/agentic-pod-launcher-custom-config/bin/custom-apply.sh <ws> --agent donna`), because
`donna`'s Google MCP servers are injected into the **derived** `.mcp.json` and are absent from
`agent.yml`; a bare `--regenerate` would have dropped them.

## 2. Outcome per agent

| Agent | MCP servers declared | Result |
| --- | --- | --- |
| `linus` | 8 | Healthy on the first recreate. Channel up, no flap, stable for >1 h. |
| `donna` | 15 | **Flapped for ~25 minutes**, escalating to container restarts, until the channel window was widened by hand. |

Both ended at v0.25.0 with the voice patch group at v3, verified in the live `server.ts`:
`telegram voice roundtrip patch v3` = 1 occurrence, `v2` = 0, `v1` = 0; boot log
`applied voice-upgrade-v1→v2+voice-upgrade-v2→v3 patch(es)`; channel boot line
`voice active mode=auto caps=300s/900chars signoff=50chars`.

## 3. The `donna` failure, measured

Boot-time pre-warm reported three failures (`docker compose logs`):

```
mcp_warm: warn: uvx mcp-server-git failed (will resolve on first use)
mcp_warm: warn: uvx mcp-server-tree-sitter failed (will resolve on first use)
mcp_warm: warn: uvx workspace-mcp failed (will resolve on first use)
```

Then, every ~120 s:

```
[start_services] launching: … claude --continue --channels plugin:telegram@… --dangerously-skip-permissions
[start_services] WARN: --channels launched but bun server.ts never appeared within 120s — killing for respawn
```

`CHANNEL_HEALTH_TIMEOUT` on this agent is **120** (not the 60 default); the boot log carries the
launcher's own risk warning that at this length five consecutive failures no longer fit the 300 s
crash-budget window. The cycle nevertheless escalated to container restarts.

### 3.1 The voice patch was ruled out as the cause

Two independent checks, both inside the container:

- `bun build --target=bun --no-bundle server.ts` → **PARSE_OK**.
- Running the patched plugin directly: `bun server.ts` → printed
  `telegram channel: voice active mode=auto caps=300s/900chars signoff=50chars` and kept running
  until killed. The v3 plugin starts correctly; Claude Code simply never launched it in time.

### 3.2 What actually consumed the window

15 MCP servers declared in `donna`'s `.mcp.json`: `atlassian-personal brave-search fetch filesystem
firecrawl git github google-maps google-workspace open-meteo playwright qmd time tree-sitter vault`
(plus the `claude-mem` plugin server). All were spawned within ~15 s of the session start, but the
handshakes did not complete: 4 minutes into the launch, `claude` was still initialising and
`bun server.ts` had not appeared. `MCP_TIMEOUT` is 120000 ms per server, and at least one server
(`tree-sitter`) can never succeed in this image (see 3.3), so it burns its full timeout every boot.

### 3.3 Why the pre-warm failed, per package

Running each package by hand, detached (`docker exec -d`), gave:

| Package | Result | Note |
| --- | --- | --- |
| `workspace-mcp` | `rc=0` | Resolves fine. |
| `mcp-server-git` | `rc=0` | Resolves fine. |
| `mcp-server-tree-sitter` | `rc=1` | Genuinely cannot build: `tree-sitter` (v0.26.0) needs a library providing `Python.h`. This one fails **permanently** in this image, warm or not. |

> **Correction (2026-09-19).** As first written, this table said the two `rc=0` packages were "slower
> than the warm step's per-package timeout", and an adversarial review caught that it contradicted
> `research.md` D1, which had measured an instant `rc=2`. The review was right and this paragraph was
> wrong: the command run by hand here was `uvx <pkg> --help`, **not** the command the warm actually
> runs (`uv tool install`). They fail differently, which is the whole confusion. Re-measured on the
> same container against a throwaway prefix and cache on real disk: `uv tool install --python python3
> workspace-mcp` completes in **12 s from a cold cache** (`rc=0`), and **0 s when forced over an
> existing install**. The 300 s ceiling was never the binding constraint; the failure was entirely the
> executable collision. An earlier probe of mine that appeared to hit a ceiling had in fact been given
> a 60 s `timeout` by me, and a later one failed with `os error 28` because I pointed the cache at
> `/tmp`, which is a 100 MB tmpfs in this compose — both were artefacts of the probe, not of uv.

`linus` shows 2 warm warnings of the same family and is healthy, so a warm warning on its own is
not the failure — the failure is the combination of a cold cache, many servers, and a window that
cannot accommodate them.

### 3.4 What recovery looked like

A temporary `docker-compose.override.yml` raising `CHANNEL_HEALTH_TIMEOUT` to 420 let the boot
finish. Once the caches were warm (they live in the container's writable layer and survive a
restart, but **not** a recreate), the very next launch was:

```
21:41:36 [start_services] launching: … claude --continue --channels …
21:41:39 [start_services] channel plugin healthy — bun server.ts running
```

**Three seconds.** The steady-state cost is negligible; the entire failure is a first-boot-after-rebuild
transient that the current window cannot absorb.

The override is still in place on `donna` and is a liability: at 420 s the crash budget no longer
escalates a genuinely dead channel to a container restart. Retiring it requires a recreate, which
discards the warm cache and reproduces the flap — that circularity is the problem feature 036 has
to break.

## 4. Second defect found in the same session

`./scripts/agentctl doctor` on a healthy agent printed:

```
./scripts/agentctl: line 533: [: 0
0: integer expression expected
  ⚠ Telegram plugin patches incomplete (typing=0
0 offset=4 stderr=1 primary=2)
    → agentctl restart (apply_telegram_typing_patch.py runs at boot)
```

The `typing` count arrived as two lines (`0\n0`) instead of an integer, breaking the `[ ]`
comparison and producing a **false** "patches incomplete" warning: the markers were verified present
by hand in the same container. Diagnosed separately (see `research.md`).
