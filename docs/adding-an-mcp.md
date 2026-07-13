# Adding an MCP

How MCP servers are wired into scaffolded agents, and how to add a new one to
the launcher. Applies to both deployment modes (`deployment.mode: docker |
local`); mode-specific behavior is called out explicitly. Verified against
v0.12.0.

## How MCPs are wired

- `agent.yml` is the single source of truth. `modules/mcp-json.tpl` renders to
  `<workspace>/.mcp.json` **host-side** (`setup.sh` calls `render_to_file`
  during scaffold and `--regenerate`), in both modes.
- Docker mode: the rendered `.mcp.json` reaches the container through the
  `./:/workspace` bind-mount (`modules/docker-compose.yml.tpl`). Templates are
  **not** baked into the image — `docker compose build` will never pick up an
  edited `mcp-json.tpl`. The re-render step is `./setup.sh --regenerate`; an
  image rebuild is only needed for `docker/` changes. Two MCP artifacts *are*
  image-baked: the qmd MCP wrapper (`docker/scripts/qmd-mcp` →
  `/opt/agent-admin/scripts/qmd-mcp`) and the catalog descriptors — those live
  at `modules/mcps/<id>.yml`, not under `docker/`, and `setup.sh`
  (`mirror_catalog_to_docker`) stages a copy into the *workspace's*
  `docker/modules/mcps/` so the `context: ./docker` build can `COPY` them to
  `/opt/agent-admin/modules/mcps/`. Edit the descriptor at its source, never
  the mirrored copy.
- Local mode: the same `.mcp.json` sits at the workspace root and Claude
  spawns the MCP processes directly on the host, as the operator.
- Secrets live in `.env` only — never in `agent.yml` (see
  [Secrets contract](#secrets-contract)).

There are two routes to add an MCP:

- **Route A — catalog MCP**: single-instance, optionally one secret, a y/n
  wizard prompt. This is the standard path; no `setup.sh` edit needed.
- **Route B — bespoke MCP**: multi-instance or custom sub-prompts (the
  Atlassian and GitHub MCPs are the precedents). Requires wizard code.

## Route A: catalog MCP

### 1. Add a descriptor at `modules/mcps/<id>.yml`

As of v0.12.0 the catalog has 3 `default` MCPs (fetch, git, filesystem —
always on) and 6 `optional` ones (aws, firecrawl, google-calendar, playwright,
time, tree-sitter). Example (`modules/mcps/google-calendar.yml`, abridged):

```yaml
id: google-calendar
spec: "@cocal/google-calendar-mcp"
type: optional
runtime: npx
description: "Google Calendar — listar/crear/actualizar eventos ..."
when_useful: "Agentes que coordinan reuniones ..."
when_overhead: "OAuth flow es 3-legged ..."
requires_secret: true
secret_env_var: GOOGLE_OAUTH_CREDENTIALS
secret_doc_url: "https://github.com/nspady/google-calendar-mcp#setup"
post_install_note: |
  Setup OAuth flow: ...
```

Fields enforced by `tests/mcp-catalog.bats`: `id`, `spec`, `type`
(`default` | `optional`), `description`, `when_useful`, `when_overhead`,
`requires_secret`. When `requires_secret: true`, `secret_env_var` is required
and `secret_doc_url` is recommended. `runtime` and `post_install_note` are
informational.

What the wizard does automatically from the descriptor
(`scripts/lib/mcp-catalog.sh` + the MCP block in `setup.sh`):

- Prompts y/n for every `type: optional` descriptor, alphabetically, printing
  `description` / `when_useful` / `when_overhead`.
- Exports the render gate `MCPS_<ID>_ENABLED`
  (`mcp_catalog_id_to_envvar`: id uppercased, `-` → `_`; e.g. `tree-sitter` →
  `MCPS_TREE_SITTER_ENABLED`).
- If `secret_env_var` is set, prompts for the secret and appends
  `<SECRET_ENV_VAR>=<value>` directly to the workspace `.env` (empty answer
  leaves a blank placeholder to fill in later). Catalog MCP secrets never go
  through `modules/env-example.tpl` — the only MCP secrets that template
  carries are the bespoke Atlassian/GitHub blocks (alongside the headless-auth
  token and the Telegram notifier vars).
- Persists the selection in `agent.yml` under `mcps.defaults`, which is what
  `--regenerate` reads to re-derive the `MCPS_<ID>_ENABLED` gates without the
  wizard.

No `setup.sh` edit, no `env-example.tpl` edit, and no `scripts/lib/schema.sh`
edit is needed for this route (`mcps.defaults` is not schema-validated).

### 2. Add the gated block to `modules/mcp-json.tpl`

```text
{{#if MCPS_MY_SERVICE_ENABLED}},
    "my-service": {
      "command": "npx",
      "args": ["-y", "my-service-mcp"],
      "env": {
        "MY_SERVICE_TOKEN": "${MY_SERVICE_TOKEN}"
      }
    }{{/if}}
```

Rules, all enforced by tests:

- `command` is a bare executable; arguments go in the `args` array. No entry
  in the template embeds args in the command string.
- Secrets are `${VAR}` references resolved from the session environment —
  never literal values.
- Every `optional` descriptor must have a matching `{{#if MCPS_<ID>_ENABLED}}`
  block, and every `default` descriptor an unconditional block
  (`tests/mcp-catalog.bats`).

### 3. Decide the per-mode shape

Anything that differs between the container and the host must be branched.
Two mechanisms:

- **Inline branch** for paths (see the `git` / `filesystem` entries):

  ```text
  "{{#if DEPLOYMENT_MODE_IS_DOCKER}}/workspace{{/if}}{{#unless DEPLOYMENT_MODE_IS_DOCKER}}{{DEPLOYMENT_WORKSPACE}}{{/unless}}"
  ```

- **Precomputed variable** when the branch would have to nest inside another
  `{{#if}}` — the render engine does not support nested conditionals, so
  `setup.sh` resolves the value per mode before rendering and the template
  stays dumb. Existing precedents to copy:

  | Variable | Docker mode value | Local mode value |
  | --- | --- | --- |
  | `{{GCAL_CREDS_PATH}}` | `/home/agent/.gcal/gcp-oauth.keys.json` | `<workspace>/.state/.gcal/gcp-oauth.keys.json` |
  | `{{VAULT_MCP_PATH}}` | `/home/agent/.vault` | resolved `vault.path` under the workspace |
  | `{{QMD_MCP_COMMAND}}` | `/opt/agent-admin/scripts/qmd-mcp` (image-baked wrapper) | `<workspace>/scripts/local/agent-qmd-mcp.sh` (rendered from `modules/local-qmd-mcp.sh.tpl`) |
  | `{{QMD_MCP_ENV}}` | `{}` | JSON object pinning `XDG_CACHE_HOME` + `QMD_CONFIG_DIR` under `.state` |

  The qmd pair is the canonical pattern for an MCP whose *command* differs per
  mode: an image-baked wrapper in docker, a rendered workspace wrapper in
  local (rendered as `"command": "{{QMD_MCP_COMMAND}}", "args": []`). Any new
  precomputed variable must be added to the `known_external` lists in
  `tests/schema.bats` (see next step).

### 4. Update the test touchpoints

Adding an optional descriptor adds a wizard prompt, which breaks a fixed set
of tests. Update all of them in the same change:

1. `tests/mcp-catalog.bats` — the expected `default` / `optional` ID sets are
   hardcoded; add your id.
2. `tests/helper.bash::wizard_answers` — the optional-MCP block pipes one `n`
   per catalog prompt (a single `printf 'n\n...'`); add one answer and update
   the comment listing the ids.
3. `tests/e2e-smoke.bats` — the hand-rolled `answers` array (and its numbered
   comment block) must gain one `n` in the optional-MCP run. Note the
   deployment-mode answer is FIRST in the array (since 011).
4. `tests/schema.bats` — `known_external`: the `MCPS_<ID>_ENABLED` gate goes
   in the `{{#if VAR}}` predicate test's list; any new bare `{{VAR}}` you
   precompute in `setup.sh` goes in the placeholder test's list.
5. `docs/agentic-quickstart.es.md` + `docs/agentic-quickstart.en.md` — both
   enumerate the wizard prompts in a numbered table, optional MCPs included
   ("optional MCP n/6" as of v0.12.0), so a new prompt shifts the numbering in
   both. `tests/quickstart-doc.bats` does not check MCP ids, but it does
   enforce ES/EN parity of `UPPER_CASE_TOKEN`s — name the new `secret_env_var`
   in one locale only and the suite goes red.

Also add render assertions for the new block to `tests/mcp-json.bats`
(enabled/omitted, and per-mode values if any).

## Route B: bespoke MCP (multi-instance)

When one y/n prompt is not enough — multiple accounts, several fields per
instance — model it as an array in `agent.yml` and iterate with `{{#each}}`.
The Atlassian MCP is the reference implementation. **Do not put secrets in
the array**: `agent.yml` is replicated in plaintext to the fork's
`backup/config` branch (see [architecture.md](architecture.md)).

```yaml
# agent.yml — non-secret fields only
mcps:
  my_service:
    - name: work
      workspace: "https://work.example.com"
    - name: personal
      workspace: "https://personal.example.com"
```

```text
{{#each MCPS_MY_SERVICE}},
    "my-service-{{name}}": {
      "command": "python",
      "args": ["-m", "mcp.servers.my_service"],
      "env": {
        "SERVICE_WORKSPACE": "{{workspace}}",
        "SERVICE_TOKEN": "${SERVICE_TOKEN_{{NAME}}}"
      }
    }{{/each}}
```

Notes:

- Inside `{{#each}}`, `{{name}}` renders the row value as-is and `{{NAME}}`
  renders it uppercased — that is how the per-instance `.env` variable name is
  derived (`SERVICE_TOKEN_WORK`, `SERVICE_TOKEN_PERSONAL`).
- The loop variable maps to a YAML path (`MCPS_MY_SERVICE` →
  `.mcps.my_service`). `tests/schema.bats` checks that path against
  `tests/fixtures/sample-agent-with-vault.yml` — it must be a sequence, null,
  or absent (a map or scalar there fails the test), so an unseeded fixture
  passes by default. Seed it anyway with a realistic row: that same fixture is
  the one `tests/mcp-json.bats` renders, so an absent path means your
  `{{#each}}` block emits nothing and is never exercised (`.mcps.atlassian` is
  the precedent — it is seeded in both `sample-agent-with-vault.yml` and
  `sample-agent.yml`).
- The wizard sub-prompts (in `setup.sh`) collect the secret once per instance
  and write it straight into `.env`; add a matching placeholder block to
  `modules/env-example.tpl` (this is the route that *does* touch both files —
  mirror the Atlassian pattern).

## Secrets contract

- Secrets live in the workspace `.env` (0600) and nowhere else. `agent.yml`
  goes to the `backup/config` orphan branch in plaintext; `.env` travels only
  encrypted, as `.env.age` inside `backup/identity`.
- Docker mode: `docker-compose.yml` injects `.env` via `env_file`, so `${VAR}`
  references in `.mcp.json` resolve inside the container. Rotation: edit
  `.env`, then recreate the container —

  ```bash
  docker compose up -d
  ```

  `docker compose restart` does **not** re-read `env_file` (the env is fixed
  at container creation); if `up -d` reports the container as up-to-date, use
  `docker compose up -d --force-recreate`.
- Local mode: the Remote Control unit loads only
  `<workspace>/.state/remote-control.env` (its `EnvironmentFile`) — the
  workspace `.env` is *not* injected into the session. A secret your MCP needs
  must be present in that session environment for the `${VAR}` reference to
  resolve.
- Never add secrets under `environment:` in the compose template, and never
  hardcode them in `mcp-json.tpl`.

## Docker-mode specifics

### Paths inside the container

- `/workspace` — bind-mount of the workspace directory chosen at scaffold
  time (default `<parent-of-launcher-clone>/agents/<name>`, overridable with
  `--destination`).
- `/home/agent` — bind-mount of `<workspace>/.state/`. This is **not** a
  named volume: it survives `docker compose down -v` and moves with the
  workspace. The Claude config dir is `/home/agent/.claude`. Layout details:
  [state-layout.md](state-layout.md).
- `/tmp` — 100MB tmpfs (as of v0.12.0). Transient only; heavy jobs use a
  host-backed scratch dir under `.state` instead.

If your MCP writes state that must persist, write under `/home/agent/` or
`/workspace/`, not `/tmp`.

### Alpine musl and native binaries

The image is Alpine (musl libc). The base version is resolved to the latest
stable at scaffold time and recorded in `agent.yml` `docker.base_image`; the
`docker/Dockerfile` fallback is `alpine:3.24.1` as of v0.12.0.

**There is no Debian variant.** `docker.base_image` does feed the `FROM` line
via a build arg, but the Dockerfile installs everything with
`apk add --no-cache` — a glibc base image will not build. Do not point
`base_image` at Debian; solve native-binary problems in-image instead:

1. Prefer runtimes already baked into the image: `uvx` (Python), `npx`
   (Node), `bun`. Every catalog MCP uses one of these.
2. Alpine package: add an `apk add --no-cache <pkg>` step to
   `docker/Dockerfile`.
3. Module that must compile at install time (the 016 pattern): gate a build
   toolchain behind a Dockerfile build arg — see `QMD_NATIVE_TOOLCHAIN`
   (`apk add build-base cmake linux-headers libgomp`) and the managed
   `bun install` prefix with `trustedDependencies` in
   `scripts/lib/qmd_index.sh`.
4. Dependency that ships only a glibc prebuilt (the 017 pattern): compile it
   for musl at image build and swap it in at runtime — see
   `docker/scripts/build-sqlite-vec.sh` and
   `qmd_index.sh::_qmd_swap_sqlite_vec`.

Diagnostic: a "not found" error when executing a binary that exists is the
musl loader failing on a glibc-linked ELF (`ldd <binary>` shows the missing
`ld-linux` interpreter). That binary needs option 3 or 4, not a base-image
change.

### Exec convention

Every `docker exec` must pass `-u agent` — the container drops all
capabilities, so root inside it cannot write (and often cannot read)
agent-owned files. Prefer the wrappers:

```bash
./scripts/agentctl logs -f      # tail /workspace/claude.log
./scripts/agentctl attach       # tmux attach (retry loop)
```

## Local-mode specifics

- The MCP `command` runs on the host as the operator, spawned by the Remote
  Control session, whose PATH is pinned by `.state/remote-control.env` to
  `~/.local/bin` plus system dirs. `scripts/local/agent-bootstrap.sh` (rendered
  from `modules/local-bootstrap.sh.tpl`) provisions the runtimes `.mcp.json`
  references into `~/.local/bin`: it downloads `uv`/`uvx`, `bun` and
  `github-mcp-server` (version pins mirrored from the `docker/Dockerfile`
  ARGs) and *symlinks* the operator's existing `node`/`npx` — it never
  installs Node. A new runtime dependency means extending that bootstrap or
  documenting a host install.
- Workspace paths use `{{DEPLOYMENT_WORKSPACE}}` (or a precomputed per-mode
  variable), never container paths.
- If the MCP needs a wrapper script, render it into `scripts/local/` from a
  `modules/local-*.tpl` template (`agent-qmd-mcp.sh` is the precedent).

## Validating the change

In the launcher repo:

```bash
bats tests/mcp-catalog.bats tests/mcp-json.bats tests/schema.bats
bats tests/quickstart-doc.bats tests/e2e-smoke.bats
```

In a scaffolded workspace:

```bash
./setup.sh --regenerate        # re-render .mcp.json from agent.yml
jq . .mcp.json                 # must be valid JSON
```

Docker mode, after the render:

```bash
./scripts/agentctl up          # docker compose up -d
./scripts/agentctl attach      # exercise the MCP in the Claude session
./scripts/agentctl logs -f     # if it fails, check the agent log
```

Remember: `--regenerate` for template/config changes; `docker compose build`
only when `docker/` changed.

## Common issues

### "command not found" when the MCP starts

The binary is not on the PATH of the process that spawns it. Docker mode: use
a full path in `mcp-json.tpl` or install the package at image build (`apk`).
Local mode: get it into `~/.local/bin` (bootstrap script) — the systemd unit
does not see your interactive shell's PATH.

### glibc errors on Alpine

See [Alpine musl and native binaries](#alpine-musl-and-native-binaries).
There is no Debian escape hatch — compile for musl or pick a musl-compatible
runtime.

### State not persisting across restarts

Docker mode: write under `/home/agent/` (the `.state/` bind-mount) or
`/workspace/`, not `/tmp` (tmpfs). Inspect as the agent user:

```bash
docker exec -u agent <name> find /home/agent -name "mcp-*"
```

### Secret not visible to the MCP

Docker mode: confirm the var is in `.env` and recreate the container
(`docker compose up -d` — `restart` is not enough). Local mode: the workspace
`.env` is not loaded into the session; see [Secrets contract](#secrets-contract).

## See also

- [architecture.md](architecture.md) — render engine, privilege model, backup
  model (why `agent.yml` must stay secret-free).
- [state-layout.md](state-layout.md) — what lives under `.state/`.
- [getting-started.md](getting-started.md) — daily operations and
  troubleshooting.
