# Phase 0 Research: Reproducible In-Container Dependency Upgrades

Resolved 2026-06-18. External version facts from a 5-agent web-research fan-out
(npm registry, GitHub releases APIs, Alpine APKINDEX/release notes, Docker Hub).
Internal wiring decisions from the repo dependency inventory.

## Decision 1 — Resolution model: resolve-and-record on upgrade

- **Decision**: The repo ships NO frozen version literals. Defaults are upstream
  *channels* (Claude Code → `stable`; Alpine/`uv`/`bun`/`gum` → latest stable). The
  launcher resolves a channel to a concrete version and **records it into
  `agent.yml`** at scaffold, `./setup.sh --regenerate`, and an explicit
  `agentctl versions --upgrade`. The image build consumes the recorded concrete
  versions via `build.args`.
- **Rationale**: Satisfies the operator directive "always the latest stable of the
  moment, never hardcoded" while keeping builds reproducible (a built image equals
  the recorded versions) and runtime drift-free (`DISABLE_AUTOUPDATER=1` stays).
  Compatible with constitution Principle VI: `agent.yml` still holds explicit pins;
  the *bump* is the intentional `--upgrade`/scaffold action, not silent runtime
  drift.
- **Alternatives considered**: (a) *Resolve at every build* — rejected: two builds
  at different times differ (not reproducible) and Alpine could jump minors
  unexpectedly. (b) *Frozen literal pins refreshed manually* — rejected: violates
  "not hardcoded" and goes stale. (c) *Hybrid (Claude Code fresh-at-build, rest
  recorded)* — viable but adds a second resolution path; rejected for uniformity.
- **Offline degradation**: if upstream is unreachable during resolution, fall back
  to the currently recorded `agent.yml` version (or a documented last-known floor
  for a first-ever offline scaffold) and report the degradation; never install a
  wrong version (FR-012).

## Decision 2 — Concrete initial targets + channels + queries

First recorded set (resolved 2026-06-18). `upstream_latest_query` runs on the
host (which already requires `jq`); for in-container use all are `curl`+`jq`,
no auth.

| Component | Channel | Current | Resolved latest stable | Read installed |
|---|---|---|---|---|
| Claude Code | `stable` | 2.1.119 | **2.1.170** | `claude --version` |
| Alpine base | latest | 3.20 | **3.24.1** | `cat /etc/alpine-release` |
| `uv` | latest | 0.5.14 | **0.11.22** | `uv --version` |
| `bun` | latest | 1.1.38 | **1.3.14** | `bun --version` |
| `gum` | latest | 0.14.5 | **0.17.0** | `gum --version` |

Resolution queries (channel → concrete):

- **Claude Code** (`stable` dist-tag, NOT `latest`/`next`):
  `curl -s https://registry.npmjs.org/@anthropic-ai/claude-code | jq -r '."dist-tags".stable'`
  → `2.1.170`. (`latest`=2.1.181, `next`=2.1.183 is prerelease — exclude.) Install
  consumes the recorded concrete version: `npm i -g @anthropic-ai/claude-code@<ver>`.
- **Alpine**: `curl -s https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64/latest-releases.yaml | grep -m1 'version:'`
  (or Docker Hub tags API). Recorded into `docker.base_image` as `alpine:3.24.1`.
- **uv**: `curl -fsSL https://api.github.com/repos/astral-sh/uv/releases/latest | jq -r .tag_name`
  (bare semver, no leading `v`; endpoint excludes prereleases).
- **bun**: `curl -fsSL https://api.github.com/repos/oven-sh/bun/releases/latest | jq -r '.tag_name | ltrimstr("bun-v")'`.
- **gum**: `curl -fsSL https://api.github.com/repos/charmbracelet/gum/releases/latest | jq -r .tag_name`
  (strip leading `v`).

## Decision 3 — Per-component upgrade caveats → concrete tasks

These convert "bump versions" into specific, testable work. Download-asset naming
for `uv`/`bun`/`gum` is UNCHANGED, so the existing `curl|tar`/`unzip` fetches in
`docker/Dockerfile` and `setup.sh` resolve with only the version value changed.

- **Claude Code 2.1.119→2.1.170**:
  - `2.1.161` fixed the musl "native binary not found" SDK bug — directly relevant
    (Alpine = musl). Good.
  - `2.1.160`: `acceptEdits` may now prompt before writing build-tool config files.
    **Re-verify** the Telegram `reply` MCP path isn't blocked given
    `permissions.defaultMode=auto` + `skipDangerousModePermissionPrompt=true`
    (Docker-e2e smoke).
  - `2.1.147`: `/simplify` renamed to `/code-review`. **Grep the repo/docs** for any
    `/simplify` reference and update.
  - `claude --version` output format unchanged; `DISABLE_AUTOUPDATER=1` stays.
- **Alpine 3.20→3.24.1** (4 minors — highest risk; Docker-e2e is mandatory):
  - **Node 20→24**: `apk add nodejs` now gives Node 24 LTS (satisfies QMD's Node≥22
    natively). Audit any Node-20 assumption; sanity-check plugin install hooks.
  - **Python 3.12→3.14**: re-run python-touching bats; `apply_telegram_typing_patch.py`
    and `fetch-github-key` child run under 3.14 (stdlib deprecations; setuptools 82
    dropped `pkg_resources`).
  - **apk v2→v3** (lands in 3.23): on-disk format stays v2-compatible and `apk add`
    is seamless, but **audit any Dockerfile/entrypoint that parses `apk` output**.
  - **busybox 1.36→1.37**: crond root-crontab-ownership + applet behavior documented
    unchanged — **re-verify** with `DOCKER_E2E=1 bats tests/docker-e2e-heartbeat.bats`
    (the cmp-based staging-sync model and `sh -nt` sub-second rounding are the
    load-bearing assumptions). Keep the GID-20/`dialout` collision block.
- **uv 0.5.14→0.11.22** (6 minors):
  - **`0.8.0` interpreter-preference validation** (highest risk): uv now ignores
    PATH interpreters not matching python-preference unless explicitly requested.
    The repo uses `uv tool install --python python3` (explicit → should resolve),
    but add **`ENV UV_PYTHON_PREFERENCE=only-system`** as a belt-and-suspenders
    guard so uv never auto-downloads a managed CPython (which would defeat the warm
    `/opt/uv` cache and could break the offline MCP handshake). Smoke-test the three
    baked uvx MCPs after bump.
  - `0.11.0` TLS stack → rustls-platform-verifier/aws-lc; `--native-tls` deprecated
    (repo uses neither flag; `ca-certificates` already installed). Confirm build-time
    PyPI fetches succeed.
- **bun 1.1.38→1.3.14**: low risk; `bun server.ts` + `bunx` semantics unchanged.
  Single full build + boot the telegram plugin once to confirm the MCP server
  attaches.
- **gum 0.14.5→0.17.0** (REQUIRED CODE FIX):
  - **`v0.15.0` changed Esc exit code 2→1.** `scripts/lib/wizard-gum.sh::_abort_if_interrupted`
    only treats rc 130/2 as abort, so post-bump an Esc in `gum input`/`gum choose`
    falls through to the default instead of aborting. **Fix**: also handle rc==1 for
    `input`/`choose` — but NOT for `gum confirm` (where rc==1 is the legitimate "no").
  - `v0.15.0` also strips ANSI from captured output by default (beneficial; wizard
    captures into shell vars). All wizard-used flags (`input`/`choose`/`confirm`
    `--prompt/--value/--placeholder/--password/--header/--selected/--default`) still
    exist and behave the same through 0.17.0.
  - Dual-source: bump BOTH `docker/Dockerfile` ARG and `setup.sh` — which this
    feature replaces with the single `versions.sh` source anyway.

## Decision 4 — Internal wiring (from the repo inventory; no external research)

- **Declaration**: extend `agent.yml` `docker:` block with `claude_code_version`,
  `uv_version`, `bun_version`, `gum_version` (recorded concrete); `base_image`
  (existing) records `alpine:<ver>`. Channels (the defaults) live in the new
  `scripts/lib/versions.sh`.
- **Render → build-args**: `render.sh` already flattens `docker.x → $DOCKER_X`;
  add the fields to `modules/docker-compose.yml.tpl` `build.args` as `{{DOCKER_*}}`.
  Today the template forwards only `UID`/`GID` (the root cause of "the build
  ignores chosen versions").
- **Dockerfile**: declare `ARG ALPINE_VERSION` BEFORE `FROM alpine:${ALPINE_VERSION}`
  (BuildKit global-arg pattern); keep `ARG CLAUDE_CODE_VERSION/UV_VERSION/BUN_VERSION/GUM_VERSION`
  consumed exactly as today. The ARGs receive values from compose `build.args`. For
  raw `docker build` ergonomics, keep ARG defaults but cover them with a drift-guard
  bats test (default == what `versions.sh`/scaffold would record), OR leave required
  — decided in /plan: keep defaults, drift-guarded.
- **setup.sh**: source `versions.sh`; at scaffold/regenerate resolve channels →
  record concrete into `agent.yml`; drive the host-side `gum` download from the
  recorded `gum_version` (removing the `setup.sh:154` literal). `--regenerate`
  re-stamps (same mechanism as the `meta` block).
- **schema.sh**: add the `docker.*_version` leaves as OPTIONAL (legacy-safe);
  absent values are resolved+recorded on next regenerate (FR-010).
- **agentctl**: new `versions [--check] [--json] [--upgrade]` subcommand; `doctor`
  gains a "toolchain versions" line (declared only, no network).
- **No-duplicate-pin invariant**: enforced by a bats test that asserts each managed
  version has a single authoritative origin (`versions.sh` channels + the
  recorded `agent.yml` value), with no independent literal in `setup.sh`/Dockerfile
  that can drift.

## Open risks carried into implementation

- Alpine 3.24 Docker-e2e is the gating verification for the whole feature; if the
  heartbeat/boot e2e regresses under busybox 1.37 / apk v3, fall back per the
  Alpine intermediate option (3.23) is NOT chosen — escalate instead.
- `uv` `0.8.0` python-preference is the most likely silent breakage; the
  `UV_PYTHON_PREFERENCE=only-system` guard + post-build MCP smoke is mandatory.
