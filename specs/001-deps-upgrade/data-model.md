# Data Model: Reproducible In-Container Dependency Upgrades

Configuration-and-pipeline, not a runtime store. The model is: default *channels*
(launcher level) → resolved to *recorded concrete versions* (per agent) → carried
into the build → reported by the outdated report.

## Managed Toolchain Components

The five pinned, image-baked components. Concrete values in [research.md](./research.md).

| Key (config / build-arg) | Component | Default channel | Role in image | Verify (installed) |
|---|---|---|---|---|
| `claude_code` / `CLAUDE_CODE_VERSION` | Claude Code CLI (`@anthropic-ai/claude-code`) | `stable` (npm dist-tag) | Agent runtime (npm global) | `claude --version` |
| `alpine` / `ALPINE_VERSION` | Alpine base image | latest stable | OS base; dictates Node/Python majors | `cat /etc/alpine-release` |
| `uv` / `UV_VERSION` | astral `uv`/`uvx` | latest stable | Python MCP runner | `uv --version` |
| `bun` / `BUN_VERSION` | `bun` | latest stable | Telegram-plugin MCP + `bunx` | `bun --version` |
| `gum` / `GUM_VERSION` | charmbracelet `gum` | latest stable | In-container wizard TUI | `gum --version` |

## Channels & resolution (the "not hardcoded" rule)

- A **channel** is the default intent the repo ships: `stable` (Claude Code) or
  `latest` (others). Channels live in `scripts/lib/versions.sh`; they are NOT
  version numbers.
- A **resolver** maps a channel → a concrete version via a best-effort upstream
  query (per-component, see research.md), runnable on host (`jq` present) or
  in-container (`curl`+`jq`), timeout-bounded, no auth.
- **Resolve-and-record** happens at: first scaffold, `./setup.sh --regenerate`, and
  `agentctl versions --upgrade`. The resolved concrete version is RECORDED into
  `agent.yml`. The build only ever consumes recorded concrete versions → builds are
  reproducible; the network is not a build dependency.
- **Pinning**: an operator may set a concrete version and channel `pinned`; the
  resolver then leaves that component alone.
- **Offline**: resolution failure falls back to the currently recorded version (or a
  documented last-known floor on a first-ever offline scaffold) and reports the
  degradation (FR-012).

## `scripts/lib/versions.sh` (NEW)

The single launcher-level source of default channels + the resolver. Sourced (not
executed); `BASH_SOURCE`-guarded so sourcing has no side effects (Principle III).
No frozen version literals are the source of truth (FR-011).

```sh
# default CHANNELS (not numbers) — the one place channel intent lives
AGENTIC_CHANNEL_CLAUDE_CODE="stable"   # npm dist-tag
AGENTIC_CHANNEL_ALPINE="latest"
AGENTIC_CHANNEL_UV="latest"
AGENTIC_CHANNEL_BUN="latest"
AGENTIC_CHANNEL_GUM="latest"

# resolver: channel -> concrete version (best-effort upstream query; see research.md)
versions_resolve <component>   # echoes concrete version, or non-zero + "unknown" offline

# optional documented last-known floor, ONLY used on first-ever offline scaffold
# (clearly labelled "fallback", not the source of truth)
```

## Version Declaration — `agent.yml` `docker:` block

Recorded concrete versions added **alongside** the existing `docker.base_image` /
`docker.image_tag`. Per-agent SSOT; what the build bakes.

```yaml
docker:
  image_tag: "agentic-pod:latest"      # existing
  base_image: "alpine:3.24.1"          # existing field; now records the resolved Alpine
  claude_code_version: "2.1.170"       # NEW — recorded (channel: stable)
  uv_version: "0.11.22"                # NEW — recorded (channel: latest)
  bun_version: "1.3.14"                # NEW — recorded
  gum_version: "0.17.0"                # NEW — recorded
  toolchain_channels:                  # NEW (optional) — per-component intent for --upgrade
    claude_code: stable                #   stable | latest | pinned
    uv: latest
    bun: latest
    gum: latest
    alpine: latest
```

- **Types**: version fields are strings (semver for the binaries; `alpine:X.Y.Z` for
  base_image). `toolchain_channels.*` ∈ {`stable`,`latest`,`pinned`}.
- **Validation (`schema.sh`)**: version leaves OPTIONAL (legacy-safe, FR-010); when
  present, non-empty + shape-checked. `toolchain_channels` optional, defaults from
  `versions.sh`.
- **Legacy**: an `agent.yml` lacking these is upgraded transparently on the next
  `--regenerate`, which resolves+records (same mechanism as the `meta` block).

## Dataflow (channels → resolve → record → render → build)

```text
scripts/lib/versions.sh  (default CHANNELS + resolver)   ← no frozen numbers
   │  setup.sh / --regenerate / `agentctl versions --upgrade`
   │      versions_resolve(component)  ──best-effort──►  upstream (npm / GitHub / Alpine)
   ├─► agent.yml docker.*_version = <resolved concrete>   (per-agent SSOT, recorded)
   │        │  render.sh flattens docker.x → $DOCKER_X
   │        └─► docker-compose.yml build.args (CLAUDE_CODE_VERSION, ALPINE_VERSION, …)
   │                 │  docker compose build  (uses RECORDED versions; no network)
   │                 └─► Dockerfile ARGs → npm i -g claude-code@$, FROM alpine:$…
   └─► host-side gum download in setup.sh reads the recorded gum_version

Dockerfile ARG defaults ── drift-guard bats test ──► consistent with versions.sh resolver shape
pinned component ──► resolver skips it (channel=pinned)
```

## Outdated Report (P3) — row shape

Produced by `agentctl versions --check`; one row per managed component.

| Field | Source | Notes |
|---|---|---|
| `component` | static | display name/key |
| `recorded` | `agent.yml` `docker.*_version` | what the build will bake |
| `channel` | `agent.yml` `toolchain_channels.*` (or default) | `stable`/`latest`/`pinned` |
| `latest` | live best-effort upstream query | "unknown" when offline/timeout |
| `status` | derived | `current` \| `outdated` \| `unknown` \| `unmanaged` |

The floating MCP/plugin layer is **out of scope** and, if listed, is `unmanaged`.

## State transitions

- **Channel → Resolved → Recorded → Built → Running**: channel intent →
  `versions_resolve` → `agent.yml` recorded value → `build.args` → baked into image
  → reported by the component verify command at runtime.
- **Check**: `recorded` vs live `latest` → `current` / `outdated` / `unknown`.
- **Upgrade**: re-resolve non-`pinned` channels → rewrite recorded values (atomic
  `agent.yml.prev`) → regenerate derived → operator rebuilds to apply.
