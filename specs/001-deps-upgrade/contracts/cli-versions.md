# Contract: `agentctl versions` + build-arg passthrough

The CLI surface and the config→build mapping this feature exposes. CLI is the
project's contract type (it's a bash tool), so this stands in for an API schema.

## `agentctl versions` (host wrapper → in-container/host read)

### `agentctl versions`  (default — recorded, no network)

Lists each managed component with its recorded version and channel. Exit 0.

```text
component     recorded   channel
claude_code   2.1.170    stable
alpine        3.24.1     latest
uv            0.11.22    latest
bun           1.3.14     latest
gum           0.17.0     latest
```

### `agentctl versions --check`  (adds live upstream, best-effort)

Adds `latest` + `status` columns from a best-effort upstream query (per-component
timeout). Network is optional; unreachable → `latest=unknown`, `status=unknown`.
**Always exit 0** (reporting, not a gate) — being outdated is not an error.

```text
component     recorded   channel   latest    status
claude_code   2.1.170    stable    2.1.170   current
alpine        3.24.1     latest    3.24.1    current
uv            0.5.14     latest    0.11.22   outdated
```

- `status` ∈ {`current`, `outdated`, `unknown`, `unmanaged`}.
- The floating MCP/plugin layer is never reported as `current`/`outdated`; if shown
  at all it is `unmanaged`.

### `agentctl versions --json`

Machine-readable array of `{component, recorded, channel, latest?, status?}`.
`--check` adds `latest`/`status`. Stable key names; additive evolution only.

### `agentctl versions --upgrade`  (resolve-and-record; mutating)

1. For each component whose channel ≠ `pinned`: resolve the channel → concrete
   latest stable (best-effort).
2. Write the resolved values into `agent.yml` (atomic `agent.yml.prev` backup +
   rollback on failure — same contract as `heartbeatctl set-*`).
3. Regenerate derived files (`docker-compose.yml`, …) from `agent.yml`.
4. Print a per-component `old → new` diff and remind the operator to
   `docker compose build && agentctl up` to apply (build is the only thing that
   changes the running version; runtime never auto-updates).

Exit 0 on success (including "already current"). Non-zero only on write/regenerate
failure (after rollback). Offline: components that cannot be resolved are left at
their recorded value with a `⚠ unknown (kept X)` note; exit 0.

### `agentctl doctor`

Gains a **Toolchain versions** section listing the recorded versions (no network),
beside the existing `Launcher version` line. Read-only.

## Config → build-arg → image mapping (the passthrough contract)

`agent.yml` is the per-agent source of truth; `render.sh` flattens `docker.X` →
`$DOCKER_X`; `modules/docker-compose.yml.tpl` carries them as `build.args`; the
Dockerfile consumes them as `ARG`s.

| `agent.yml` (`docker.`) | compose `build.args` | Dockerfile `ARG` | Consumed by |
|---|---|---|---|
| `base_image` (`alpine:3.24.1`) | `ALPINE_VERSION` (`3.24.1`) | `ARG ALPINE_VERSION` (before `FROM`) | `FROM alpine:${ALPINE_VERSION}` |
| `claude_code_version` | `CLAUDE_CODE_VERSION` | `ARG CLAUDE_CODE_VERSION` | `npm i -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}` |
| `uv_version` | `UV_VERSION` | `ARG UV_VERSION` | uv musl tarball fetch |
| `bun_version` | `BUN_VERSION` | `ARG BUN_VERSION` | bun musl zip fetch |
| `gum_version` | `GUM_VERSION` | `ARG GUM_VERSION` | gum tarball fetch (+ host download in `setup.sh`) |

Invariants:

- The documented build (`docker compose build`) MUST bake the recorded versions
  (today it bakes hardcoded Dockerfile defaults — the bug this fixes).
- For raw `docker build`, the Dockerfile `ARG` defaults remain for ergonomics but a
  **drift-guard bats test** keeps them consistent with the `versions.sh` resolver
  contract; no managed version has two independently-editable literals.
- `UID`/`GID` build args remain unchanged.
- Add `ENV UV_PYTHON_PREFERENCE=only-system` (research.md) so uv ≥0.8.0 never
  auto-downloads a managed CPython.

## Channel keywords

`toolchain_channels.<component>` ∈ {`stable`, `latest`, `pinned`}:

- `stable` — track the upstream stable channel (Claude Code's npm `stable` dist-tag).
- `latest` — track the latest non-prerelease release.
- `pinned` — never auto-resolve; the recorded version is frozen until the operator
  changes it.
