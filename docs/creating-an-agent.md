# Creating an agent declaratively — worked example: `john-doe`

This runbook builds a brand-new agent by **hand-writing its definition** instead of
answering the wizard. You author three files — `agent.yml`, a persona, and a real
`.env` — then run **one non-interactive command** that renders and installs
everything else. It is the reproducible, reviewable, version-controllable path:
the whole agent is described by files you can diff, commit, and copy.

Scope: **docker mode**, the recommended least-privilege deployment. It uses a
fictional agent named **`john-doe`** throughout. For the interactive wizard, the
first-boot login/pairing details, and the full troubleshooting catalogue, see
[`getting-started.md`](getting-started.md) — this runbook complements it and links
back to it rather than repeating it.

## When to use this vs. the wizard

| Use the **wizard** (`./setup.sh`) | Use this **declarative** runbook |
| --- | --- |
| One-off agent, interactive host with a TTY | Reproducible / scripted provisioning |
| You want to be prompted for each field | You already know the config and want to review it as a file |
| First time, exploring options | Standing up a second agent alongside an existing one (isolation matters) |

The two produce the **same** `agent.yml`; the wizard just collects it through
prompts. Everything below is exactly what the wizard writes, authored by hand.

## Mental model (read this first)

- **The launcher clone _is_ the workspace.** You clone the launcher into the
  agent's directory; `setup.sh`, `scripts/`, `modules/`, and `docker/` live there,
  and `--non-interactive` / `--regenerate` render **in place**. `deployment.workspace`
  in `agent.yml` is that same absolute path.
- **`agent.yml` is the single source of truth.** Every derived file
  (`docker-compose.yml`, `.mcp.json`, `CLAUDE.md`, `.env.example`,
  `scripts/heartbeat/heartbeat.conf`, `NEXT_STEPS.md`) is rendered from it. Never
  hand-edit a derived file — change `agent.yml` and re-render.
  - `CLAUDE.md` is _generated once, then yours_: a re-render preserves an
    operator-edited agent doc. The launcher clone ships the launcher's OWN
    `CLAUDE.md`, so a **local** declarative render replaces that inherited dev
    doc with the agent's automatically (027 — no manual `rm`). In **docker**
    mode the inherited doc is still preserved; delete it once before the first
    render so the agent gets its own.
  - `NEXT_STEPS.md` is rendered by `--non-interactive` / `--regenerate` in
    **local** mode (027); in **docker** mode only the wizard emits it today.
- **You author exactly three files by hand:** `agent.yml`, `personas/<name>.md`
  (the persona), and `.env` (secrets). Everything else is generated.
- **`.env` must be a _real file_ in the workspace, never a symlink** (see
  Troubleshooting — this one bites hard in docker mode).
- **Isolation between agents is your responsibility in this flow:** give each
  agent a **unique `docker.image_tag`** and it inherits a unique container name
  from `agent.name`. Reusing the default tag will overwrite another agent's image.

## Prerequisites

Host tools (same as the wizard — see [`getting-started.md`](getting-started.md#prerequisites)):
`git`, `jq`, `yq` v4+ (auto-vendored into `scripts/vendor/bin/` if missing),
Docker Engine with the **Compose v2** plugin, and ~2GB free disk for the image +
workspace. Know your host identity — you'll need it for `docker.uid` / `docker.gid`:

```bash
id -u    # → docker.uid
id -g    # → docker.gid
```

---

## Step 1 — Put the launcher into the workspace

The workspace is a self-contained copy of the launcher. Clone it to the path you
want the agent to live at, then `cd` in:

```bash
git clone <launcher-repo-url> /home/jane/agents/john-doe
cd /home/jane/agents/john-doe

# Optional: pin the launcher version (the version is also recorded into
# agent.yml's meta block on the first render).
git checkout v0.17.0            # a tag, branch, or commit

# Optional: a fork-less agent doesn't need git at all. Dropping .git avoids
# tying the workspace to the launcher's remote. Keep git only if you plan to
# enable fork backups (scaffold.fork.*).
rm -rf .git
```

From here on, every command runs from **inside** this directory.

---

## Step 2 — Write `agent.yml`

Create `agent.yml` at the workspace root. This is the complete, valid definition
for `john-doe` — docker mode, fork-less, heartbeat on, a working MCP set, and the
knowledge vault with QMD search enabled. Comments call out what is **required** and
what is auto-filled on render.

```yaml
version: 1

agent:
  name: john-doe                      # REQUIRED. DNS label: lowercase, no spaces.
                                      # Drives container name, tmux session,
                                      # channel-state dir, (fork) branch names.
  display_name: "John Doe"            # human-facing
  role: "personal assistant"          # one line, plain ASCII (it feeds the renderer)
  role_file: "personas/john-doe.md"   # the persona from Step 3 (workspace-relative)
  vibe: "calm, concise, proactive"
  use_default_principles: true        # inject the opinionated default agent principles

user:
  name: "Jane Operator"
  nickname: "Jane"
  timezone: "America/Santiago"        # REQUIRED (IANA tz)
  email: "jane@example.com"           # REQUIRED
  language: "es"                      # es | en | mixed (drives NEXT_STEPS + persona)

deployment:
  host: "my-host"                     # informational label
  workspace: "/home/jane/agents/john-doe"   # REQUIRED. Absolute path == this clone.
  install_service: false              # docker mode ignores it (compose handles restart)
  mode: "docker"                      # docker | local — this runbook is docker

claude:
  config_dir: "~/.claude-personal"    # host-side launcher profile dir
  profile_new: false

docker:
  uid: 1000                           # REQUIRED. Must equal `id -u` on the host.
  gid: 1000                           # REQUIRED. Must equal `id -g` on the host.
  image_tag: "agentic-pod:john-doe"   # REQUIRED. UNIQUE per agent — see mental model.
  base_image: "alpine:3.24.1"         # REQUIRED. Validated BEFORE the render backfill,
                                      # so it must be present in the file you write.

scaffold:
  fork:
    enabled: false                    # fork-less: no GitHub backup branches

notifications:
  channel: telegram                   # none | log | telegram

features:
  heartbeat:
    enabled: true                     # REQUIRED
    interval: "30m"                   # REQUIRED
    timeout: 300                      # REQUIRED (seconds)
    retries: 1                        # REQUIRED
    default_prompt: "give me the container resource status as a table"   # REQUIRED

mcps:
  defaults:                           # the always-on trio PLUS any optional catalog
    - fetch                           # MCP you want. The wizard writes optional MCPs
    - filesystem                      # into this same list; the renderer enables each.
    - git
    - playwright                      # optional
    - time                            # optional
    - firecrawl                       # optional → needs FIRECRAWL_API_KEY in .env
    - tree-sitter                     # optional
  atlassian:
    - name: personal                  # alias → ATLASSIAN_PERSONAL_* env vars.
      url: "https://your-domain.atlassian.net"   # Use a simple lowercase alias with
      email: "jane@example.com"                   # NO hyphens (it becomes a shell/systemd
                                                  # variable name).
  github:
    enabled: true                     # → needs GITHUB_PAT in .env
    email: "jane@example.com"

vault:
  enabled: true                       # Karpathy three-layer knowledge vault
  path: .state/.vault
  seed_skeleton: true
  mcp:
    enabled: true                     # @bitbonsai/mcpvault MCP server
    server: vault
  qmd:
    enabled: true                     # hybrid RAG search (downloads ~2GB models lazily)
    version: "2.5.3"
    schedule: "*/5 * * * *"
  # wiki_graph is default-on with the vault; opt out with:
  #   wiki_graph:
  #     enabled: false

plugins:                              # EXTRA plugins only. Five defaults (telegram,
  - claude-mem@thedotmack             # claude-mem, context7, claude-md-management,
                                      # security-guidance) are always installed and
                                      # need not be listed here.
```

Auto-filled on the first render (you may omit them): the `meta` block
(`launcher_version`, timestamps), `docker.*_version` toolchain pins,
`deployment.session_name`, and `deployment.mode` if absent. The **four `docker.*`
leaves above are _not_ backfilled** — validation runs before the backfill, so they
must be in the file you write.

**Optional MCPs go in `mcps.defaults[]`.** The catalog: always-on `fetch`,
`filesystem`, `git`; optional `aws`, `firecrawl`, `google-calendar`, `playwright`,
`time`, `tree-sitter`. `atlassian` and `github` are separate blocks (above).

---

## Step 3 — Write the persona (`personas/john-doe.md`)

`agent.role_file` points here. This is the agent's identity and operating rules, in
its own voice — it becomes part of the rendered `CLAUDE.md`. Keep `agent.yml`
scalar values plain ASCII (they feed the renderer), but the persona **markdown** can
use full prose and accents freely.

```bash
mkdir -p personas
```

`personas/john-doe.md` (adapt to taste):

```markdown
# John Doe — identity

You are John Doe, a personal assistant. You help the operator manage email, calendars,
health topics, and areas of interest. When a topic needs depth you can coordinate with
other agents to gather information, then summarize it back.

## Operating rules

- Respond in the operator's language; be concise and direct. Lead with the answer.
- No decorative emojis — not in headings, not at the start of bullets.
- Do not invent. Distinguish verified fact from inference; cite the source of any
  non-trivial claim. If you cannot verify something, say so.
- Never expose or hardcode secrets. Confirm before destructive or irreversible actions.
- Dates as DD-MM-YYYY.
```

---

## Step 4 — Write the real `.env` (0600)

Create `.env` at the workspace root as a **real file** — never a symlink (see
Troubleshooting). It holds every secret the MCPs and the runtime reference. For
`john-doe` (telegram + firecrawl + atlassian `personal` + github):

```bash
umask 077                              # ensures 0600
cat > .env <<'EOF'
# .env — secrets for John Doe. NEVER commit this file.

# Claude headless auth (see below to obtain it). Boots operational without /login.
CLAUDE_CODE_OAUTH_TOKEN=

# Pre-fill the interactive bot token so the container skips its first-run wizard.
TELEGRAM_BOT_TOKEN=

# Heartbeat notifier (a SEPARATE bot from the interactive one, if you want).
NOTIFY_BOT_TOKEN=
NOTIFY_CHAT_ID=

# Optional-MCP secret. NOTE: .env.example does NOT template this one — add it here.
FIRECRAWL_API_KEY=

# Atlassian workspace "personal" (4 config vars + 1 token).
ATLASSIAN_PERSONAL_CONFLUENCE_URL=https://your-domain.atlassian.net/wiki
ATLASSIAN_PERSONAL_CONFLUENCE_USERNAME=jane@example.com
ATLASSIAN_PERSONAL_JIRA_URL=https://your-domain.atlassian.net
ATLASSIAN_PERSONAL_JIRA_USERNAME=jane@example.com
ATLASSIAN_PERSONAL_TOKEN=

# GitHub MCP.
GITHUB_PAT=
EOF
chmod 600 .env
```

Notes:

- **Obtain `CLAUDE_CODE_OAUTH_TOKEN`** by running `claude setup-token` on the host
  and pasting the result. With it set, the agent boots fully operational without an
  interactive `/login`.
- **`.env.example` is a starting skeleton, not the full list.** The renderer (Step 5)
  writes `.env.example` covering `CLAUDE_CODE_OAUTH_TOKEN`, notifier, Atlassian, and
  GitHub — but **not** the optional-MCP secrets (`FIRECRAWL_API_KEY`, AWS,
  `GOOGLE_OAUTH_CREDENTIALS`). Add those to your real `.env` yourself.
- **Pre-filling `TELEGRAM_BOT_TOKEN`** lets the container skip the in-container token
  wizard and boot straight into the paired channel flow. Leave it blank to use the
  interactive wizard instead (see [`getting-started.md` §2](getting-started.md#2-enter-your-telegram-bot-token)).
- `.env` is gitignored at the template level. **Never commit it. Never symlink it.**

---

## Step 5 — Render the derived files

One command validates `agent.yml` against the schema and renders everything:

```bash
./setup.sh --non-interactive
```

It produces (docker mode): `CLAUDE.md` (if missing), `.mcp.json`, `.env.example`,
`docker-compose.yml`, the mirrored `docker/` build context (plugin catalog),
`scripts/heartbeat/heartbeat.conf`, and `scripts/heartbeat/logs/`. Your hand-written
`.env` is **not touched** (it's user-owned), and `CLAUDE.md` is preserved on
re-runs unless you pass `--force-claude-md`.

> For later edits, `./setup.sh --regenerate` is the same operation — edit `agent.yml`,
> re-render. It preserves `.env` and `CLAUDE.md`.

If validation fails it prints one `ERROR: agent.yml: …` line per problem (missing
required leaf, bad enum, non-boolean where a boolean is required). Fix the file and
re-run.

---

## Step 6 — Build the image

```bash
docker compose build
```

This bakes `docker.image_tag` (`agentic-pod:john-doe`) with your host UID/GID. First
build is a few minutes and ~1.8GB.

---

## Step 7 — Start the container

```bash
./scripts/agentctl up            # == docker compose up -d
docker ps                        # john-doe should be Up / healthy
./scripts/agentctl status        # heartbeatctl status, proxied into the container
```

The in-container supervisor (`start_services.sh`) is PID 1 and launches Claude Code
inside a detached tmux session. Reach it with `./scripts/agentctl attach` (never
`docker attach`).

---

## Step 8 — Log in

- **Headless (recommended for this flow):** with `CLAUDE_CODE_OAUTH_TOKEN` already in
  `.env`, the agent authenticates on boot — nothing to do.
- **Interactive:** `./scripts/agentctl attach`, then `/login` inside tmux, paste the
  code, `/exit`, wait ~2–3s. See [`getting-started.md` §1](getting-started.md#1-log-in-to-claude).

---

## Step 9 — Pair Telegram

With `TELEGRAM_BOT_TOKEN` pre-filled, the watchdog launches the channel plugin
automatically. Then:

```bash
./scripts/agentctl attach
```

1. DM the bot from Telegram — it replies with a 6-character pairing code.
2. In the Claude session: `/telegram:access pair <code>` (accept the `access.json`
   overwrite prompt).
3. Send a test DM — it should reach Claude and trigger a reply. Detach with `Ctrl-b d`.

Pairing mode reads `access.json` on every message, so later edits to that file take
effect **without a restart**. Full walkthrough: [`getting-started.md` §3](getting-started.md#3-pair-your-telegram-account).

---

## Step 10 — First QMD index (vault + QMD only)

QMD builds its index on the heartbeat/cron schedule, but you can kick the first one
immediately:

```bash
./scripts/agentctl heartbeat qmd-reindex
# or: docker exec -u agent john-doe heartbeatctl qmd-reindex
```

First index builds the managed prefix (`~/.cache/qmd/pkg`, compiling
`better-sqlite3` / `node-llama-cpp` / the musl `sqlite-vec`) and embeds the seeded
vault. The three models (~2GB total: embedding + reranker + query-expansion)
**download lazily on the first `qmd query`**, not at index time. Verify:

```bash
docker exec -u agent john-doe heartbeatctl qmd-reindex   # look for last_status: indexed, pending: 0
docker exec -u agent john-doe qmd query "how should the assistant behave"
```

---

## Verification checklist

- [ ] `docker ps` shows the container **Up / healthy**, `RestartCount` stable (not flapping).
- [ ] `./scripts/agentctl doctor` is green apart from expected benign warnings
      (heartbeat not run yet; fork-less agents show "backup never pushed"; a known
      `typing patch incomplete` false-negative — see Troubleshooting).
- [ ] Telegram: a DM from your phone reaches Claude and gets a reply.
- [ ] `./scripts/agentctl mcp` lists the expected servers connected (ignore
      `claude.ai`-scoped ones you haven't configured).
- [ ] If QMD is on: `heartbeatctl qmd-reindex` reports `last_status: indexed`, and a
      `qmd query` returns ranked hits.

---

## Troubleshooting (declarative-specific)

The wizard hides some of these because it does the file plumbing for you. The big
generic catalogue (wizard re-fires, `uvx: not found`, UID mismatch, MCP failures,
`docker attach` hangs) is in [`getting-started.md` §Troubleshooting](getting-started.md#troubleshooting).

### The container flaps on boot — `.env` must be a real file, not a symlink

**Symptom:** the container restarts in a loop; logs show "authenticated profile
detected with no Telegram token" → wizard → `/workspace/.env: No such file or
directory` → "initial tmux session failed to start".

**Root cause:** `env_file:` in compose resolves a symlink **host-side** and _does_
deliver the variables — but the boot does **file operations** on `/workspace/.env`
(`[ -f ]`, `grep`; `start_services.sh`). The container only bind-mounts the
workspace, so a symlink pointing outside it (e.g. `.env -> ../secrets/john-doe.env`)
is **dangling inside the container** → `[ -f ]` is false → it drops into the token
wizard, which then can't write the dangling path → boot fails → Docker revives it →
permanent flap.

**Fix:** make `.env` a **real file** in the workspace (Step 4). If you want a central
secrets store, keep the master copy elsewhere and **copy** it into the workspace
(`cp`, not `ln -s`), re-copying when it changes.

### A second agent overwrote the first agent's image

Give **every** agent a unique `docker.image_tag` in `agent.yml`. The default tag is
generic; reusing it across agents makes the second `docker compose build` clobber the
first's image. The container name is separately isolated (it comes from `agent.name`).

### `.state/` missing → the `/home/agent` bind-mount breaks

If `.state/` doesn't exist when the container starts, the `/home/agent` bind-mount
has nothing to mount and login/state won't persist. Create it and recreate:

```bash
mkdir -p .state
docker compose up -d --force-recreate
```

### QMD is broken after a boot flap

A boot flap can interrupt the QMD `bun install` mid-way, leaving a corrupt prefix
(`better_sqlite3.node` won't load; `last_status: error`). **Deleting only the prefix
is not enough** — the reindex guard sees the unchanged vault hash in `qmd-index.json`
and skips ("vault unchanged → skip"), so it never rebuilds. Blow away the state file
too (keep the downloaded models):

```bash
docker exec -u agent john-doe sh -lc '
  cd ~/.cache/qmd &&
  rm -rf pkg index.sqlite qmd-index.json .reindex.lock   # keep models/
'
docker exec -u agent john-doe heartbeatctl qmd-reindex
```

### `agentctl doctor` says the typing patch is "incomplete"

Known false-negative: `doctor`'s integer parse of the typing-tick count misreports the
Telegram typing patch as incomplete even when the `v4` marker is present. Confirm the
patch is applied and ignore the warning:

```bash
docker exec john-doe grep -c "typing refresh patch v4" \
  /home/agent/.claude/plugins/cache/claude-plugins-official/telegram/*/server.ts
```

---

## References

- [`getting-started.md`](getting-started.md) — the wizard flow, first-boot login /
  pairing, upgrade / rollback / backup-restore, and the full troubleshooting catalogue.
- [`architecture.md`](architecture.md) — render engine, container lifecycle,
  privilege model, the three code paths.
- [`heartbeatctl.md`](heartbeatctl.md) — the in-container runtime CLI (heartbeat,
  QMD, backups).
- [`vault.md`](vault.md) — vault layers, QMD setup, storage/cost, wiki-graph.
- [`agentic-quickstart.es.md`](agentic-quickstart.es.md) / [`.en`](agentic-quickstart.en.md)
  — driving the wizard from a Claude Code session in one prompt.
