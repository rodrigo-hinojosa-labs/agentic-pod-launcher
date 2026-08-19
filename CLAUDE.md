# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

This is **the launcher**, not an agent. `./setup.sh` is a bash wizard that scaffolds a *separate*, self-contained agent workspace elsewhere on disk. The launcher is disposable after scaffolding — every subsequent operation (`--regenerate`, `--uninstall`, `heartbeatctl`) runs from inside the scaffolded workspace.

Three distinct code paths live in this repo, and confusing them is the most common mistake:

1. **Host-side launcher** — `setup.sh`, `scripts/lib/{yaml,render,wizard,wizard-gum}.sh`, `modules/*.tpl`. Runs on the user's Mac/Linux during scaffolding. Depends on host tools: `bash` **3.2–5.3, tested in both** (not just "no bash-4-only construct" — that description was TRUE about constructs and FALSE about behavior: bash 5.2 changed `${var//pattern/replacement}` so an unescaped `&` in the replacement means "the whole match", which silently corrupted any operator value containing one until `023-fix-render-ampersand` replaced it with `_render_replace_all`, a prefix/suffix walk with no replacement string to escape at all; see that spec's `research.md` for the full measurement, including why `bats`, being `#!/usr/bin/env bash`, can silently switch which bash a given run uses), `yq v4+`, `jq`, `git`, BSD/GNU `sed`, optional `gum` (auto-downloaded to `scripts/vendor/bin/`).
2. **Image-baked code** — `docker/` (Dockerfile, `entrypoint.sh`, `crontab.tpl`, `scripts/start_services.sh`, `scripts/wizard-container.sh`, `scripts/heartbeatctl`, `scripts/lib/{interval,state}.sh`, `scripts/apply_telegram_typing_patch.py`). Copied into the Alpine 3.20 image at build time, lives at `/opt/agent-admin/` inside containers. Read-only at runtime — changes require an image rebuild.
3. **Workspace-templated code** — `scripts/heartbeat/{heartbeat.sh,notifiers/}`. Copied verbatim into each scaffolded workspace by `setup.sh`. Runs as `agent` inside the container via the bind-mount.

`modules/claude-md.tpl` is the CLAUDE.md template *for scaffolded agents*, not for this repo. Don't edit it expecting changes here; edit this file instead.

## Commands

```bash
# Tests (bats-core required on host)
bats tests/                              # full suite (~195 tests, no Docker)
bats tests/heartbeatctl.bats             # single file
bats tests/render.bats -f "substitutes"  # single test by name fragment
DOCKER_E2E=1 bats tests/docker-e2e-heartbeat.bats   # opt-in: builds image + boots a container

# Launcher (run from a fresh clone of this repo)
./setup.sh                               # interactive wizard
./setup.sh --destination ~/my-agent      # skip the destination prompt
./setup.sh --help                        # all flags

# Inside a scaffolded workspace (NOT this repo)
docker compose build && ./scripts/agentctl up   # agentctl up == docker compose up -d
./scripts/agentctl attach                # tmux attach with retry-loop
./scripts/agentctl status                # heartbeatctl status (proxy through agentctl)
./scripts/agentctl heartbeat <sub>       # any heartbeatctl subcommand
./scripts/agentctl logs -f               # tail /workspace/claude.log
./scripts/agentctl logs --stderr         # forensic tail of telegram-mcp-stderr.log
./scripts/agentctl --help                # full subcommand list
./setup.sh --regenerate                  # re-render derived files from agent.yml
./setup.sh --uninstall --yes             # remove generated files (keeps agent.yml/.env/.state)
./setup.sh --uninstall --purge --yes     # also removes agent.yml/.env/.state/
./setup.sh --uninstall --nuke --yes      # delete the workspace entirely
```

Test deps on the host: `bats-core`, `yq` v4+, `jq`, `git`, `tmux`. Tests source `scripts/lib/*.sh` directly via `tests/helper.bash::load_lib`; `heartbeatctl.bats` overrides `HEARTBEATCTL_WORKSPACE` / `HEARTBEATCTL_CRONTAB_FILE` / `HEARTBEATCTL_LIB_DIR` to run the image-baked CLI against a tmpdir without Docker.

## Architecture worth knowing before editing

Deeper docs: [`docs/architecture.md`](docs/architecture.md) (render engine, lifecycle, data contracts, privilege model) and [`docs/heartbeatctl.md`](docs/heartbeatctl.md) (full subcommand reference).

### `agent.yml` is the single source of truth

The wizard collects answers into `agent.yml`. Every derived file (`docker-compose.yml`, `.mcp.json`, `CLAUDE.md`, `scripts/heartbeat/heartbeat.conf`, `.env` skeleton, `NEXT_STEPS.md`) is rendered from it via `scripts/lib/render.sh`. Mutations made by `heartbeatctl set-*` write back to `agent.yml` first (with atomic `agent.yml.prev` rollback), then regenerate derived files. **Never edit a derived file by hand if you want the change to survive a regenerate** — change the template + `agent.yml`, or change `heartbeatctl` if it's a runtime mutation.

### Render engine (`scripts/lib/render.sh`)

`render_load_context FILE` flattens YAML into env vars: `agent.name` → `$AGENT_NAME`, `features.heartbeat.enabled` → `$FEATURES_HEARTBEAT_ENABLED`, etc. Array items are skipped at flattening time and handled by `{{#each VAR}}…{{/each}}` blocks, which derive a yq path from `VAR` (`MCPS_ATLASSIAN` → `.mcps.atlassian`) and substitute `{{field}}` per row. Templates also support `{{#if VAR}}` / `{{#unless VAR}}`. Look at `tests/fixtures/{simple,conditional,loop}.tpl` for canonical examples and `tests/render.bats` for the contract.

### Container privilege model (read this before changing `docker/`)

`docker-compose.yml.tpl` ships `cap_drop: ALL` + `cap_add: [CHOWN, SETUID, SETGID]` + `no-new-privileges`. Three load-bearing consequences:

- **Every `docker exec` must pass `-u agent`.** `root` inside the container can't write agent-owned files (no `CAP_FOWNER`).
- **busybox `crond` silently rejects crontabs not owned by root.** `entrypoint.sh` runs as root, renders the safe-default crontab to `/etc/crontabs/agent`, then `exec su-exec agent /opt/agent-admin/scripts/start_services.sh` — but a backgrounded sync loop *stays* running as root and copies `<workspace>/scripts/heartbeat/.crontab.staging` (written by `heartbeatctl reload` as agent) into `/etc/crontabs/`. Comparison uses `cmp -s`, not mtime — busybox `sh -nt` rounds to whole seconds and missed sub-second writes during boot.
- **`crond` itself runs as root** so it can `setgid(agent)` when dispatching jobs. `start_services.sh` only *monitors* it — if `crond` dies the watchdog exits the container, and Docker's `unless-stopped` policy revives it.

### Watchdog state machine (`docker/scripts/start_services.sh`)

Polls every 2s. Three failure modes it handles:

- **tmux session gone** → respawn via `next_tmux_cmd` (which re-decides between bare `claude` for `/login`, in-container Telegram-token wizard, or `claude --channels --dangerously-skip-permissions --continue`).
- **`bun server.ts` (channel plugin) gone but tmux alive** → kill tmux, respawn (forces a fresh plugin attachment).
- **`crond` gone** → exit the container.

Crash budget: 5 crashes per 300s window → exit. Docker restarts the container, restarting the budget. There used to be a "bridge watchdog" that detected the silent-stuck case (bun alive but MCP notifications dropped); it was reverted in commit `ebfe35f` because tmux pane scraping produced too many false positives. Manual recovery for that case is `heartbeatctl kick-channel`. **Don't re-add automated detection for this without solving the false-positive problem first** — it killed sessions every ~2 minutes during normal operation.

After a `--channels` launch the watchdog first waits for `bun server.ts` to appear before marking the session healthy (`verify_channel_healthy`). Since `026-channel-watchdog-timeout` (v0.17.0) that wait is **not** hardcoded: it defaults to 60s and is overridable via `CHANNEL_HEALTH_TIMEOUT` (seconds) in the workspace `.env` (delivered by compose `env_file`, same channel as `TELEGRAM_TYPING_MAX_MS`), resolved at call time by `channel_health_timeout()` (absent/invalid → 60). The old hardcoded 20s flapped ferrari at boot (bun took ~22-25s under MCP contention). **The timeout interacts with the crash budget**: a sustained failure cycle costs ~T+5s, so 5 failures only fit the 300s window while T stays under ~70s; the default 60 is safe, and `warn_if_channel_timeout_risky` logs a boot WARN once for an override `≥65s` (no cap — the operator's value is used as-is). Docker-only; `start_services.sh` is image-baked, not mirrored to `scripts/lib/`.

### Heartbeat data contract

`scripts/heartbeat/heartbeat.sh` (workspace-templated, runs as agent under crond) emits per-tick:

- One JSON line appended to `logs/runs.jsonl` (rotated at 10MB → `.1`, `.2.gz`, `.3.gz`, max 3 generations).
- Atomic rewrite of `state.json` (schema 1) with last-run summary + counters.
- One notifier invocation (`notifiers/{none,log,telegram}.sh`). Notifiers must always exit 0 and emit a JSON envelope `{channel, ok, latency_ms, error}` on stdout — they are not allowed to crash the heartbeat.

Heartbeat sessions use an isolated `CLAUDE_CONFIG_DIR=/home/agent/.claude-heartbeat` with selective symlinks to auth + plugins so cron ticks don't step on the interactive session's channels/state. The prompt is shell-escaped via `sh_sq` before embedding in the tmux command — preserve that pattern when touching the runner.

### Workspace-is-the-agent

After PR #3 (2026-04-22) all agent state (OAuth login, Telegram pairing, sessions, plugin cache) lives in `<workspace>/.state/` as a bind-mount to `/home/agent`, not a Docker named volume. Implications for any change touching state lifecycle:

- `docker compose down -v` no longer wipes login.
- `setup.sh --uninstall` no longer removes state — `--purge` removes `agent.yml`/`.env`/`.state`, `--nuke` deletes the whole workspace.
- `.state/` is gitignored at the template level and contains OAuth tokens — never commit it, never log its contents.
- Migration is `rsync` / `cp -a` of the workspace directory.

### Backup model: three orphan branches in the agent's fork

The non-regenerable subset of the workspace is replicated to the agent's own fork in three independent orphan branches:

- `backup/identity` — `.claude.json` + `.claude/settings.json` + `.claude/channels/telegram/access.json` + `.claude/plugins/config/` + `.env.age`. Encryption uses an SSH key recipient fetched from `github.com/<owner>.keys` at scaffold time; absent a recipient, the primitive falls back to **partial mode** (plaintext, `.env.age` omitted). Triggered by `heartbeatctl backup-identity`, the watchdog (60s hash check), post-plugin-install hooks, and a daily 03:30 cron.
- `backup/vault` — markdown subset of the configured vault (`vault.path` in `agent.yml`, default `.state/.vault`). Excludes `.obsidian/workspace*.json`, `cache/`, `.trash/`, and `*.sync-conflict-*` files. Cron `0 * * * *` by default; override via `vault.backup_schedule`. Helpers in `docker/scripts/lib/backup_vault.sh`.
- `backup/config` — `agent.yml` (plaintext, no secrets — those live in `.env`, which is in identity). Cron `30 3 * * *` by default; toggle via `features.config_backup.enabled`. Helpers in `docker/scripts/lib/backup_config.sh`.

All three primitives share the same shape: hash-based idempotency (sha256 over content + filenames), worktree-staged commit + push, atomic state file in `<workspace>/scripts/heartbeat/<X>-backup.json`. Each branch can be missing without breaking the others — restore via `setup.sh --restore-from-fork <url>` pulls all three in order (`config` first so `vault.path` is known, then `identity`, then `vault`) and skips any that are absent.

Three things to remember when touching the backup code:
1. **Don't merge primitives across branches.** Each `backup_X.sh` library mirrors the others' shape but stays independent — different filesystem inputs, different schedules, different threat models. Splitting was an explicit design goal so a noisy vault doesn't churn the identity branch's hash, and so sharing the config-only branch with another agent doesn't expose `.env.age`.
2. **Trees are wiped before each commit.** `vault_commit_and_push` and `config_commit_and_push` blow away the existing stage tree before copying the current snapshot in. This is what makes deletes propagate. Don't add merge logic — the branch is append-only commits, but the tree per commit is a complete replacement.
3. **Per-branch clone caches.** `~/.cache/agent-backup/{identity,vault,config}-clone/` are independent worktrees against the same fork. Don't try to share them — `git worktree add` on the same path would conflict, and the orphan-branch `init` flow in each lib expects a private clone dir.

### Telegram plugin patch

`docker/scripts/apply_telegram_typing_patch.py` is re-applied on every boot by `start_services.sh::apply_plugin_patches` against the plugin copy in `~/.claude/plugins/cache/claude-plugins-official/telegram/*/server.ts`. Idempotent via marker comments (one per patch group: typing, offset, stderr, primary), fail-silent if any of the anchor regexes drift. Don't move the patch invocation out of the boot path — the plugin cache lives under `.state/` which means a workspace clone receives an unpatched plugin until the next boot.

The typing patch is at **v4 (anti-zombie)** — `MARKER_TYPING = "…typing refresh patch v4"` (`apply_telegram_typing_patch.py:61`). The runtime contract changed at v4: the indicator is **capped**, it no longer persists indefinitely.

- **Cap (v4).** `_TYPING_MAX_DURATION_MS` = `TELEGRAM_TYPING_MAX_MS` if it parses to a positive int, else **300000 (5 min)** (`:118-122`). When `elapsed` exceeds it, the keep-alive calls `_typingStop`, sends the chat a user-facing warning ("Tardé más de N min… es probable que el OAuth de Claude haya expirado… revisa `agentctl doctor`"), writes `telegram channel: typing aborted after Nm (T ticks)` to stderr, and returns (`:132-146`). The motivating failure was zombie typing: with v3, an agent blocked on `/login` left the bot "thinking" for hours.
- **Observability (from v3, retained).** The setInterval logs `telegram channel: typing tick N for chat <id>` to stderr every 5 invocations (~20s), teed by the stderr-capture patch to `/workspace/scripts/heartbeat/logs/telegram-mcp-stderr.log` — a quiet log during a long Claude turn is direct evidence of a runtime issue. `bot.api.sendChatAction(...).catch(() => {})` was the v1/v2 anti-pattern that silently swallowed every Telegram error; v3+ routes it through `process.stderr.write(...)`.

The patcher runs an upgrade cascade on every boot: `v1 → v2 → v3 → v4` (`:668-670`). Already-patched agents at any version ratchet up transparently — `upgrade_typing_v1_to_v2` strips the old 120s cap, `upgrade_typing_v2_to_v3` adds instrumentation, `upgrade_typing_v3_to_v4` rewrites the helper with the duration cap + warning. All upgraders are fail-silent if helpers were edited out-of-band (logs WARN; leaves the file at the highest matching version).

**Implication for long operations**: any turn that legitimately exceeds ~5 minutes (a big embed, a wiki-graph pass over a large vault) will drop the indicator and warn the chat. That's the intended trade-off — a false "I'm stuck" beats an indefinite lie. Raise `TELEGRAM_TYPING_MAX_MS` in the workspace `.env` if an agent's normal turns run longer.

## Common gotchas

- **This file is gitignored.** `.gitignore`'s `/CLAUDE.md` rule is meant for *scaffolded workspaces* (where it's a derived file from `modules/claude-md.tpl`), but the same rule catches the launcher's own root-level `CLAUDE.md`. `git status` won't show edits — use `git add -f CLAUDE.md` to commit changes here.
- **`Agentic Pod Lanuncher/` (sic) is not part of this repo.** It's the user's personal Obsidian vault that happens to live in this directory; it's untracked. Don't touch it, don't include it in greps, and don't "fix" the typo.
- The wizard normalizes `agent_name` to lowercase + no spaces silently because it's used for filenames, branches, container names, and systemd units. If you add a new field that participates in any of those, normalize it the same way.
- `setup.sh` detects host UID/GID and bakes them into `docker-compose.yml` build args. macOS hosts often have GID `20` (`staff`), which collides with Alpine's `dialout` group — the Dockerfile deletes the colliding user/group before `addgroup agent`. Don't remove that block.
- `permissions.defaultMode=auto` and `skipDangerousModePermissionPrompt=true` are written into `~/.claude/settings.json` on every boot by `pre_accept_bypass_permissions`. The chat-driven workflow requires `auto` (plan mode blocks the Telegram `reply` MCP call → looks like the agent ghosts every message).
- `gum` is optional — the wizard falls back to `scripts/lib/wizard.sh` (plain `read`) when stdin is not a TTY (CI, piped tests). Don't add gum-only behavior without a non-gum fallback in `wizard.sh`.
- Library files sourced by both `heartbeatctl` and bats tests guard their initialization with `BASH_SOURCE`-style checks so `source` doesn't run side-effecting code at load time. Preserve that pattern when adding new shared libs.

<!-- SPECKIT START -->
**030-mcp-warm-cache — MERGED-PENDING (rama `030-mcp-warm-cache`, PR #92 ABIERTO contra main,
rebasada sobre main=`a90fbd6` v0.20.0 tras el merge de 029; VERSION 0.20.0→**0.21.0**; 2ª de las
3 features del incidente ferrari 16-08-2026; la 1ª es 029 MERGED, la 3ª es 031 guardia
AskUserQuestion, spec separada).** Plan: `specs/030-mcp-warm-cache/plan.md`. **PROBLEMA:** 029
ensancha la ventana de handshake (mitigación); 030 ataca la causa raíz — que el paquete uvx/npx del
MCP ya esté tibio antes de que `claude` arranque, para que un recreate no dispare descarga en frío
desde PyPI/npm dentro de la ventana. El pre-warm previo era una lista HARDCODEADA de 3 paquetes en
`docker/Dockerfile`; cualquier MCP fuera del catálogo (p. ej. `google-workspace`=`uvx workspace-mcp`,
inyectado por el overlay externo `custom-apply`) quedaba expuesto. **DISEÑO (Fase 0, workflow
`wf_fe741b61-a1a`; constitución 6/6 PASS):** (D1) fix **100% del launcher, cero cambio obligatorio en
el overlay** — tras `custom-apply` el `.mcp.json` del agente ya contiene los MCP de overlay (fuente
única). (D2) **warm en BOOT, no en build** (el overlay inyecta en el HOST post-build → un warm de
build jamás los cubre); el catálogo baked del Dockerfile se CONSERVA (no-regresión). (D3) **derivación
args-aware**: escanear `[command]+args` por el token `uvx`/`npx` y tomar el siguiente token no-flag —
cubre `command=seed-google-creds.sh, args=[uvx, workspace-mcp]`, que el selector `command=="uvx"` NO
veía (el MCP del incidente). (D4) warm síncrono pre-`claude` en `start_services.sh`, timeout por
paquete, fail-soft, como `agent`, a `/opt/uv`+`/opt/npm-cache` (fuera del montaje de estado). (D6)
single-source `scripts/lib/mcp_warm.sh` (`mcp_warm_targets` pura + `mcp_warm_run`), mirroreada a docker
y usada por local. **DECISIÓN DEL OPERADOR (2026-08-17): paridad de derivación** — docker warma uvx+npx
en boot; local corrige su selector a args-aware (uvx-only). **IMPLEMENTADO 2026-08-17 (test-first,
25/27 tareas; T025 DOCKER_E2E y T026 hardware ferrari DIFERIDOS al deploy).** `scripts/lib/mcp_warm.sh`
nueva; `pre_warm_mcps` en `start_services.sh` (source cascade + llamada pre-tmux); mirror en
`setup.sh::mirror_catalog_to_docker` + COPY en `docker/Dockerfile`; `provision_uv_tools` args-aware con
fallback pre-030 en `local-bootstrap.sh.tpl`. Tests: `mcp-warm.bats` (14), `start-services-warm.bats`
(8), +2 en `local-bootstrap.bats`, `docker-e2e-warm-cache.bats` (3, gated). **GATES VERDES (host):**
suite completa **1252 ok / 0 not ok byte-idéntico en bash 3.2.57 Y 5.3.15** (baseline 1225 + 27
nuevos); `shellcheck -S error` rc=0; **mutación 3/3**; regenerate-safety por `regenerate.bats`.
VERSION 0.20.0→**0.21.0** (rebase sobre 029; VERSION verificado contra `origin/main`, lección 023).
`/speckit-analyze`: 0 CRITICAL/HIGH. **PR #92 ABIERTO contra main (NO mergeado). Siguiente: gate
DOCKER_E2E/hardware ferrari en el deploy; luego merge con confirmación. Después: 031.**

**029-mcp-handshake-timeout MERGED (PR #91, squash `a90fbd6` en main, 2026-08-17; branch desde
main=`7334d58` v0.19.0→**0.20.0**; 1ª de tres features del incidente ferrari 16-08-2026; las otras
dos son 030 warm-cache y 031 guardia AskUserQuestion, specs separadas).** Plan:
`specs/029-mcp-handshake-timeout/plan.md`. **BUG MEDIDO (ferrari, agente donna, 16-08-2026):** un MCP
(`google-workspace`, inyectado por el overlay externo `custom-apply`) quedó muerto tras un reinicio —
descargó su wheel de PyPI durante el boot (~50 s medido), excedió la ventana de handshake de arranque
y Claude Code lo marcó failed **sin reintento** por el resto de la sesión (le dijo al usuario ~40 min
"ya va a volver"; nunca iba a volver). `docker restart` lo resolvió (2º arranque con cache caliente,
3 s). **FASE 0 — MEDIDO EN EL BINARIO (`strings` de claude 2.1.223, ≈ la 2.1.220 pineada), no
inferido:** la ventana de **arranque** del MCP es la env var **`MCP_TIMEOUT`, default 30000 ms**
(`qw(){ e=MCP_TIMEOUT; return e&&e>0?e:30000 }`); `MCP_TOOL_TIMEOUT` es de tool-calls y
`MCP_CONNECT_TIMEOUT_MS`(5000) es el dial de remotos — NO son la del incidente. 50 s > 30 s = el bug.
**DISEÑO (research.md, constitución 6/6 PASS):** campo `claude.mcp_timeout_ms` en `agent.yml` (fuente
única cross-mode, flatten `CLAUDE_MCP_TIMEOUT_MS`; el bloque `claude:` es config del binario, mejor que
`docker:`/`mcps:`/bloque nuevo), default **120000 ms** (holgura ~2.4x sobre los 50 s). Entrega a DOS
artefactos del mismo placeholder (FR-004): docker `environment:` de `docker-compose.yml.tpl` (como el
`TZ` existente) + local `remote-control.env.tpl` (2º EnvironmentFile de la unit de sesión, se re-rendea
en cada `--regenerate` sin sudo). **Saneo en el render host** (`setup.sh`, patrón
`channel_health_timeout`: entero>0 → valor, inválido → 120000, nunca ≤0), no en runtime (claude caería
a SU default 30000). **Backfill `has()`** (patrón 028, evita el gotcha del `//` que colapsaría un `0`).
**SIN DOCKER_E2E requerido** (mapeo verificó: agregar la var al `environment:` NO toca `docker/`
image-baked; `su-exec`/tmux entregan el env intacto a `claude`; consumidor = binario nativo, sin lector
baked nuevo). Alcance local: solo la unit de sesión corre `claude` (los demás timers no). Tests host
bats (render docker+local, saneo, backfill, schema). VERSION bump MINOR + CHANGELOG.
**IMPLEMENTADO 2026-08-17 (test-first, 22/23 tareas; T015 diferido a hardware).** Foundational: campo
`claude.mcp_timeout_ms: 120000` en el heredoc de `agent.yml` (setup.sh ~:1206); helper
`mcp_timeout_effective()` (~:1972, molde `channel_health_timeout`: `^[0-9]{1,7}$` y `>0` → valor,
inválido/ausente → 120000); backfill `has()` (~:2082, NO `//`) y **re-export de `CLAUDE_MCP_TIMEOUT_MS`
saneado tras `render_load_context`** (~:2095) para que ambos renders usen el mismo valor. US1:
`MCP_TIMEOUT: "{{CLAUDE_MCP_TIMEOUT_MS}}"` en `docker-compose.yml.tpl:73` (junto a `TZ`) +
`MCP_TIMEOUT={{CLAUDE_MCP_TIMEOUT_MS}}` en `remote-control.env.tpl:19`; single-source (ninguna plantilla
horneó el literal). Tests: `tests/mcp-handshake-timeout.bats` (12, con `_write_agent_yml`
parametrizado value/OMIT/NULL), +1 en `docker-render.bats`, +1 en `local-render.bats`, fixtures
`sample-agent{,-with-vault}.yml` con el campo (with-vault exigido por `schema.bats:52`). **GATES
VERDES:** suite completa **1239 ok / 0 not ok byte-idéntico en bash 5.3.15 Y 3.2.57** (baseline 1225,
+14 nuevos), `shellcheck -S error` rc=0 (comando exacto de CI); **mutación 4/4** (revertir render
docker → 10 not ok, render local → 2, saneo → 5, backfill → 1; cada restauración vuelve a 0). VERSION
0.19.0→**0.20.0** (MINOR, precedente 026), CHANGELOG + README (sub-sección + puntero de diagnóstico).
`/speckit-analyze`: 0 CRITICAL/HIGH. **T015 DIFERIDO:** gate de despliegue a `donna` (ferrari, cache
`workspace-mcp` frío → `google-workspace` conecta en 120 s), paso separado gateado por el operador en el
deploy de v0.20.0. **Pendiente inmediato: commit + PR contra main (no ejecutado — falta confirmación del
operador). Siguiente feature: 030 warm-cache declarativo.**

**028-channel-reply-guard MERGED (PR #89, squash `f2bfd77` en main, 2026-08-08; branch desde
main=`5871405` v0.18.0→0.19.0; historia lineal 087→088→089).** Post-merge: rama 028 (local +
remota auto-eliminada en el merge) limpiada, main sincronizada a `f2bfd77` y verificada (VERSION
0.19.0, archivos `modules/stop-hook{,-install}.sh.tpl` presentes, símbolos `pre_install_stop_hook`
/ `del(.hooks.Stop)` / `reply_guard` en schema / `typing refresh patch v5` / `MARKER_PENDING`).
Plan: `specs/028-channel-reply-guard/plan.md`. **BUG MEDIDO EN
PRODUCCIÓN (ferrari, agente donna, 2026-08-08):** un agente Telegram (docker) VIVO dejó de
responder por Telegram — procesó los mensajes y generó las respuestas, pero las escribió como
texto plano en la TUI en vez de llamar `plugin:telegram:telegram`, así que nunca salieron del
contenedor; el typing patch v4 luego disparó el warning MENTIROSO "es probable OAuth expirado"
(76 ticks × 4). Causa raíz: comportamiento del modelo con contexto largo (~106k en `--continue`),
NO infra → guardia determinista, no más prompt. **GATE DE FACTIBILIDAD DE FASE 0 — MEDIDO EN
ESTE HOST (captura real del payload del Stop hook vía `claude -p --settings`):** el payload
`{session_id, transcript_path, cwd, prompt_id, stop_hook_active, last_assistant_message, …}`
**NO expone el origen** del turno (canal vs consola) → el Stop hook solo no basta; SÍ trae
`last_assistant_message` (la respuesta no entregada) y `stop_hook_active` (loop guard nativo).
**DISEÑO (research.md, 6/6 constitución PASS):** guardia COOPERATIVA en dos partes forzada por
la arquitectura — (1) el plugin persiste un **marcador `pending-reply.json`** en disco (write
on-inbound / delete on-reply, espeja la persistencia de offset) = señal de origen+unreplied; (2)
un **Stop hook** (`modules/stop-hook.sh.tpl` → `scripts/hooks/stop-redeliver.sh`, rendered en
`regenerate()`) lee el marcador al fin de turno y, si existe y `stop_hook_active=false`, re-inyecta
`{"decision":"block","reason":…}` para que el agente reenvíe vía la tool (max_attempts=1, log a
stderr); fail-silent (exit 0 siempre). Config del hook = merge jq aditivo per-modo (docker
`start_services.sh::pre_install_stop_hook` tras `pre_accept_bypass_permissions`; local en
`agent-login.sh`); leak encontrado → heartbeat debe `del(.hooks.Stop)`. **US2:** el mensaje
mentiroso (`apply_telegram_typing_patch.py:139`) se reescribe honesto vía **bump v4→v5 +
`upgrade_typing_v4_to_v5`** (idempotencia por marcador). Toggle `features.reply_guard:{enabled,
max_attempts}` (mirror de heartbeat), on-by-default derivado de presencia del plugin telegram en
`plugins[]`, backfill en `regenerate()`. **Decisiones clarify (2026-08-08):** 1 reintento;
on-by-default; log a stderr. **Residual a host vivo (donna/rodri):** confirmar
`{decision:block}`+cap del loop en el Claude del contenedor, y (opcional) si el transcript marca
el origen de canal (habilitaría la variante sin cambio de plugin). **Scope:** docker/Telegram el
comportamiento real; local (relay remote-control, sin tool telegram) el hook queda inerte.
**IMPLEMENTADO 2026-08-08 (test-first, 24/25 tareas; T025 diferido):** Foundational toggle
`features.reply_guard:{enabled,max_attempts}` (schema `_SCHEMA_BOOLEANS`, heredoc del wizard con
`enabled` derivado de `^telegram@`, backfill en `regenerate()` con `has()` — evita el gotcha del
`//`). US1: `modules/stop-hook.sh.tpl` (hook fail-silent, `stop_hook_active` como loop guard, log
stderr, `max_attempts` horneado por `{{VAR}}` — sin `.conf`) + helper compartido
`modules/stop-hook-install.sh.tpl` (merge jq aditivo, testeable) rendered en ambos modos; hunks del
marcador `pending-reply` (write on-inbound `/home/agent/.claude/channels/telegram/`, delete on-reply)
en el patcher; `del(.hooks.Stop)` en el aislamiento de heartbeat. US2: bump typing **v4→v5** +
`upgrade_typing_v4_to_v5` (quirúrgico, `TYPING_HELPERS_V4` derivado por `.replace`, idempotente).
**GATES HOST VERDES (T022-T024):** suite completa **1225 ok / 0 not ok byte-idéntico en bash 5.3.15
Y 3.2.57** (baseline 027 = 1207, +18 nuevos: reply-guard-config 3, stop-hook-guard 11, apply-telegram
+4); shellcheck CI `rc=0` + hooks renderizados shellcheck-limpios; **mutación 5/5** (A marcador-origen
→ casos 1/2/3/8; B loop-guard → caso 4; C mensaje v5 → US2; D clear del marcador → pending-marker; E
detección telegram del backfill → reply-guard-config); regenerate-safety (dos `--regenerate` byte-
idénticos + agente sin canal SIN `scripts/hooks/`). VERSION 0.19.0, CHANGELOG/README/architecture.md.
`/speckit-analyze`: 0 CRITICAL/HIGH, 4 drifts de doc (plan/data-model/contract) corregidos in-situ.
**T025 DIFERIDO (sigue abierto tras el merge):** DOCKER_E2E (sin daemon aquí) + cola de host vivo
(donna/rodri) = el despliegue de v0.19.0, paso separado gateado por el operador; confirma en el
Claude del contenedor que `{decision:block}` reinyecta y que `stop_hook_active` corta el loop.
**MERGEADO por el operador (squash `f2bfd77`, #89); main sincronizada y verificada.** shellcheck de
CI pasó pre-merge; los dos brazos de bats (5.x ubuntu / 3.2 macos) quedaron corriendo al abrir el PR.
Pendiente NO bloqueante: el despliegue de v0.19.0 a donna/rodri (cierra T025 en hardware real).

**027-declarative-scaffold-parity MERGED** (PR #88, squash `5871405` en main, 2026-08-06; branch
desde main=`cd85bb2` v0.17.0→**0.18.0**; mergeado por `rodrigo-hinojosa`). Post-merge: rama 027
(local + remota auto-eliminada en el merge) limpiada, main sincronizada y verificada (`5871405`,
VERSION 0.18.0, símbolos presentes: `_is_launcher_own_claude_md`, `agent-qmd-mcp.sh` en el trigger,
`AGENTIC_FLOOR_MCP_FETCH/_GIT/_ATLASSIAN/_LIB`, `MCP_FETCH_VERSION` export, `render_next_steps quiet`;
historia lineal 087→088). Plan:
`specs/027-declarative-scaffold-parity/plan.md`.
Trae al launcher, test-first, los 4 huecos MEDIDOS en el scaffold declarativo de `ferrari-admin`
(2026-08-05, ver [[ferrari-admin-agent]] en memoria): **US1 (P1)** el render no-interactivo debe
dar el CLAUDE.md del AGENTE, no el del launcher — discriminador `_is_launcher_own_claude_md` por el
sentinel `This is **the launcher**, not an agent` en `regenerate()` (`setup.sh:2228`); preserva un
CLAUDE.md editado por el operador (sin sentinel). **US2 (P1)** provisionar `bun` cuando el MCP qmd
está como wrapper `agent-qmd-mcp.sh` (no gateado a `bunx` literal, `local-bootstrap.sh.tpl:219`).
**US3 (P2)** pinnear los uvx `fetch`/`git`/`atlassian` + la lib `mcp` a la combo validada de mclaren
(fetch 2026.6.4/git 2026.6.16/atlassian 0.21.1/mcp 1.28.1), single-sourced en `versions.sh`
(`AGENTIC_FLOOR_MCP_FETCH/_GIT/_ATLASSIAN/_LIB`, junto a los `_FILESYSTEM/_VAULT/_GH_MCP` existentes);
inyectados al bootstrap en render. **US4 (P3)** rendear `NEXT_STEPS.md` como derivado en `regenerate()`
reusando `render_next_steps()` (templates ya usan sólo vars de agent.yml). **local-only** (decisión
2026-08-06: el MISMO drift de US3 vive en `docker/Dockerfile:122-124` sin pin → follow-up aparte;
sin tocar `docker/` → **sin DOCKER_E2E**, docker byte-idéntico FR-012). Constitución **6/6 PASS**
(II/V N/A). VERSION 0.17.0→**0.18.0** (MINOR, precedente 015). Test-first host bats (US2/US3 vía
`BOOTSTRAP_DRY_RUN=1` plan lines; US1/US4 vía aserciones de archivo), mutación SC-007. 3 clarify
integrados (rendear NEXT_STEPS; pinnear los 3 uvx; discriminador quirúrgico).
**IMPLEMENTADO 2026-08-06 (test-first, 20/21 tareas; T021 diferido):** US1 helper
`_is_launcher_own_claude_md` (grep -F del sentinel) + condición de render reestructurada en
`regenerate()` (`setup.sh`), local-gateada (docker preservado, FR-012); US2 trigger de bun por el
wrapper `agent-qmd-mcp.sh` además de `bunx`; US3 pins `AGENTIC_FLOOR_MCP_FETCH/_GIT/_ATLASSIAN/_LIB`
en `versions.sh`, exportados por `_export_local_context`, `provision_uv_tools` instala
`pkg==<pin> --with mcp==<lib>` (cableado verificado end-to-end en un scaffold local real: bootstrap
con los 4 pins, `PLAN bun` por wrapper, `NEXT_STEPS.md` 94 líneas); US4 `render_next_steps` con modo
`quiet` llamado desde `regenerate()` en local. Touchpoint conocido: los 4 nuevos `{{MCP_*_VERSION}}`
agregados a `known_external` de `schema.bats`. **GATES VERDES:** suite completa **1207 ok / 0 not ok
en bash 5.3.15 Y 3.2.57** (secuencial; baseline 1197 + 10 tests nuevos); mutación **4/4 RED**
(revertir cada fix tumba ≥1 test, SC-007); `shellcheck -S error` limpio (comando exacto de CI); docker
byte-idéntico (cero archivo `docker/` tocado → sin DOCKER_E2E). Observado: 2 tests de heartbeat flakean
si se corren las dos suites CONCURRENTES (contención de CPU sobre timeouts); pasan 0/0 en aislamiento y
secuencial — ajeno a 027. VERSION 0.17.0→**0.18.0**; CHANGELOG + `docs/creating-an-agent.md`
actualizados. **T021 — residual de compat de pins CERRADO (2026-08-07, ferrari real, Linux aarch64/musl, uv
0.11.22):** `uv run --isolated --with <pkg>==<pin> --with mcp==1.28.1` resolvió e importó los TRES
uvx bajo un mismo `mcp==1.28.1` (atlassian 0.21.1 / fetch 2026.6.4 / git 2026.6.16, con `McpError`
importable) → la combo de `versions.sh` es mutuamente compatible en host real, sin override
per-server; validación aislada, sin tocar el agente vivo. **Falta (más pesado, separado):** la
aceptación completa SC-001/SC-002 "sin pasos manuales, 4 fixes desde el código del launcher" = el
**despliegue de v0.18.0** a ferrari/mclaren (re-scaffold o `--regenerate` + `--login`). **Follow-up
docker:** el MISMO drift sin pin de US3 vive en `docker/Dockerfile:122-124` → feature aparte
(tocaría `docker/` + DOCKER_E2E; los pins de `versions.sh` quedan de fuente).

**026-channel-watchdog-timeout MERGED** (PR #86, squash `f827c31` en main, 2026-08-04; branch desde
main=`cebd8b7`, VERSION 0.16.0→**0.17.0**). Post-merge: ramas 026 (local + remota) y
`docs/fix-upgrade-preserve-scripts-state` (#85, squash `11244fd`) limpiadas; main sincronizada y
verificada (`f827c31`, VERSION 0.17.0, helper `channel_health_timeout()` presente, literal `timeout=20`
ausente, historia lineal 084→085→086). Plan:
`specs/026-channel-watchdog-timeout/plan.md`. **BUG MEDIDO EN FERRARI (2026-08-02, tras el upgrade a
v0.16.0):** el watchdog `verify_channel_healthy` (`docker/scripts/start_services.sh`) tenía
`local timeout=20` hardcodeado; bajo contención de ~7 MCPs al arrancar, `bun server.ts` tarda ~22-25s
en aparecer (medido: ~3s en calma) → el watchdog lo mata y respawnea → **flapeo permanente**
(RestartCount 14→53, NO OOM). Workaround VIVO en ferrari: `docker-compose.override.yml` monta un
`start_services.sh` parcheado a `timeout=90` (`.override/`, bind-mount). **FIX (docker-only, el script
es image-baked `Dockerfile:231`, sin mirror):** helper `channel_health_timeout()` (`:726`) lee
`CHANNEL_HEALTH_TIMEOUT` del `.env` del workspace (`env_file` de `docker-compose.yml.tpl:67`, patrón
`TELEGRAM_TYPING_MAX_MS`), **default 60s** embebido, valida entero>0 acotado a 6 dígitos con
`=~ ^[0-9]{1,6}$` sin comillas (bash 3.2+5.x); `verify_channel_healthy` (`:752`) usa el helper y el log
de `:792` nombra el valor efectivo (FR-005). **HALLAZGO de Fase 0 (workflow `wf_922c62d5-f37`):**
interacción con el crash budget (`MAX_CRASHES=5`/`WINDOW=300`, `:245-246`) — un timeout `≥70s` haría que
5 fallos consecutivos no quepan en la ventana y el backstop de restart NO escale; el default 60 es seguro
(5º fallo a ~260s<300s). **DECISIÓN DEL USUARIO (clarify+plan):** default=60s; override por env var (no
`agent.yml`); **WARN sin cap** al boot (`warn_if_channel_timeout_risky` `:740`, umbral derivado
`WINDOW/(MAX_CRASHES-1)-5 -5` = 65s) + documentar, sin tocar el crash budget. Constitución **6/6 PASS**.
**Test-first (7 tests nuevos en `start-services-watchdog.bats` + 1 e2e en `docker-e2e-postlogin.bats`):**
sourcean `verify_channel_healthy` con `START_SERVICES_NO_RUN=1` + stub `pgrep`/`sleep` (K=12 discrimina
20 vs 60); edición cruzada `tests/docker-render.bats:163` (assert del mensaje dinámico, ya no `"within
20s"`). **GATES VERDES:** suite completa **1197 ok / 0 not ok en bash 5.3.15 Y 3.2.57**; mutación
(revertir `:752` tumba US1+US2); `shellcheck -S error` limpio; **revisión adversarial pre-commit
(workflow `wf_d4343179-37c`, 5 agentes): 0 ALTA, 0 regresión — 2 MEDIA + BAJA triviales arreglados**
(mensaje del WARN reformulado a lenguaje veraz de proximidad + umbral derivado de las constantes; rango
del regex acotado; `unset` en un test; orden del párrafo README; `2>/dev/null` en el e2e). Docs
README/CLAUDE.md/architecture.md/CHANGELOG (NO `env-example.tpl`). Retiro del override de ferrari
planificado post-deploy (preservar `CHANNEL_HEALTH_TIMEOUT=90`; ver `quickstart.md` §3). DOCKER_E2E real
diferido a un host Docker. Fase spec-kit: **completa y MERGEADA (PR #86, squash `f827c31`).** Pendiente
NO bloqueante: el despliegue de v0.17.0 a ferrari, que retira el `docker-compose.override.yml` manual
preservando `CHANNEL_HEALTH_TIMEOUT=90` en el `.env` (ver `quickstart.md` §3), y el DOCKER_E2E real.

**025-hermetic-ci-suite MERGED** (PR #83, squash `bb85914` en main, 2026-07-27; branch desde
main=`febe652`+doc local `b6acbf3`, 2026-07-26; **VERSION sin cambio en 0.16.0** — tests-only,
precedente 019). Post-merge: ramas 021-025 (locales + remotas) limpiadas, main reconciliada a
`bb85914`. Plan: `specs/025-hermetic-ci-suite/plan.md`. **BUG MEDIDO (`gh run view
--log-failed`, 2026-07-26): el job `tests` de CI está ROJO en cada commit de main por 16 tests NO
herméticos**; `shellcheck` VERDE; `docker-e2e` nocturno rojo aparte por `exit 141` (SIGPIPE, fuera de
alcance). Los 16: 14 corren `--regenerate` en modo local y necesitan `claude` resoluble (post-015
`resolve_claude_bin`); 2 (`qmd-reindex-cmd.bats` 685/686) por el guard `command -v bun`
(`qmd_index.sh:544`) que corta antes del `_qmd_run` stubbeado. Pasa en una máquina con `claude`/`bun` y
falla en un runner limpio — la clase que 023 midió. **FASE 0 MIDIÓ ambas incógnitas y refutó una del
spec**: 685/686 NO era un subshell que pierde el override (hipótesis del spec), era el guard `:544`
(reproducido: bun presente→GREEN, PATH podado→RED idéntico a CI); y bash 3.2 en CI = runner macOS +
`PATH=/bin:$PATH` fuerza `/bin/bash` 3.2.57 (medido; `env bash` resuelve al Homebrew 5.x sin eso, la
trampa de 023). Seam Clase 1: `resolve_claude_bin` Caso 1 (`setup.sh:92`) resuelve un absoluto
ejecutable SIN mirar PATH → un stub en `deployment.claude_cli` fuerza su uso aun con claude real
(FR-004). Alcance (elegido por el usuario): sellar los 16 (helper compartido `install_claude_stub`/
`install_bun_stub`) + matriz de bash 3.2/5.x en `test.yml`, cada brazo imprime `bash --version`. CERO
cambio de runtime de producción (`resolve_claude_bin`/`setup.sh`/`qmd_index.sh` intactos; SC-004
byte-idéntico). Constitución 6/6 PASS; único ítem: la línea "bash 4+" de Platform quedó contradicha por
esta feature (drift ya detectado por 020) → enmienda PATCH propuesta "bash 3.2+, probado en ambos".
**SIN bump de VERSION** (precedente 019, tests-only: 025 no cambia runtime, SC-004 byte-idéntico).
tasks.md: **19 tareas** test-first (RED con PATH podado → seams claude/bun → matriz de bash → mutación).

**IMPLEMENTADO 2026-07-24→26 (16/19 tareas; T013/T019 pendientes de push+PR).** T001 trajo una
CORRECCIÓN sobre research.md: el PATH podado solo no reproduce la RED en un host con Claude Code
nativo — `resolve_claude_bin` Caso 4 encuentra `$HOME/.local/bin/claude` igual; hace falta
`env -i PATH=<podado> HOME=<tmpdir>`, que sí reproduce los 16 `not ok` exactos medidos en CI.
`install_claude_stub`/`install_bun_stub` en `tests/helper.bash` (guard test propio,
`tests/hermetic-seam.bats`, 6 tests). Cableados en `deployment-mode.bats`, `local-vault-seed.bats`
(2 ocurrencias), `regenerate.bats` (SOLO el test `:135`, sin tocar los de docker) y
`qmd-reindex-cmd.bats` (retirado el `bunx` obsoleto). **Gate GREEN: 1189 ok / 0 not ok en bash 5.x Y
en 3.2.57 (`PATH=/bin:$PATH`), byte-idéntico** (1183 base + 6 nuevos). **Mutación confirmada**
(`git stash` del cableado): reaparecen los 16 `not ok` byte-idénticos a la RED; restaurado. **SC-004
confirmado**: `git diff` fuera de `tests/`+`specs/` está vacío — cero archivo de runtime tocado.
`.github/workflows/test.yml` reescrito como matriz `ubuntu-latest`(5.x)/`macos-latest`(3.2.57 arm64 vía
`PATH=/bin:$PATH`), cada brazo imprime `bash --version`; un bug de YAML propio (`:` sin comillas en
un nombre de step) detectado y corregido antes de commitear. Constitución **enmendada 1.0.0→1.0.1**
("bash 4+"→"bash 3.2+, tested in both"). `shellcheck.yml` confirmado que EXCLUYE `tests/*` por
diseño → cero archivo de esta feature entra a ese gate; corrido el comando exacto de CI igual,
`rc=0`. CHANGELOG con entrada, **sin bump de VERSION**. README gana un puntero de repro hermético
(comando `env -i` verificado copy-paste-funcional). **PR #83 ABIERTO (sin mergear) — GATE DE CI
COMPLETO Y VERDE EN AMBOS BRAZOS (2026-07-27, run 30226974940, commit `0e690a8`)**, cerrando T013.
Historia del desbloqueo: el commit `eb49524` (14 archivos, SIN `test.yml`) ya había dado
`ubuntu-latest` VERDE (`1189 ok / 0 not ok`, run 30221199153) — primera vez en la historia del repo.
El scope `workflow` que GitHub exige para pushear `.github/workflows/*.yml` FALTABA en la cuenta
`rodrigo-hinojosa`; **lo autorizó el operador con su cuenta personal vía device-flow**
(`gh auth refresh --scopes workflow`), y la matriz se commiteó (`b616f07`) y pusheó. **PIVOTE DE
RUNNER MEDIDO**: el brazo `macos-13` quedó **atascado en cola ~1h en DOS intentos, sin aprovisionar
jamás** (imagen en retiro por GitHub). Como el requisito real es bash 3.2.57 —no la etiqueta del
runner, y Apple lo congeló en `/bin/bash` en TODA versión de macOS, incluido Apple Silicon— se movió
a `macos-latest` (commit `0e690a8`), que aprovisionó de inmediato; el paso de yq se volvió arch-aware
(`uname -m` → `yq_darwin_arm64`, sin Rosetta). **Evidencia dura del brazo `macos-latest`**: runner
`macos-26-arm64`; "Verify deps" imprimió `GNU bash, version 3.2.57(1)-release (arm64-apple-darwin25)`
para el bash del PATH Y `/bin/bash`; suite `1..1189`, **0 líneas `not ok`** → 1189/0 byte-idéntico a
`ubuntu-latest` y a la medición local. **La matriz entera VERDE en CI real por primera vez.** Docs
durables (CHANGELOG/README/constitución) y los internos de la feature actualizados `macos-13`→
`macos-latest`. **T019 CERRADO: el operador mergeó (squash `bb85914`); main sincronizada y verificada
(historia lineal 022→023→024→025, VERSION 0.16.0 sin cambio). Post-merge se limpiaron las ramas
021-025 y se reconcilió main local.** Refresh de docs post-025 (este trabajo, rama
`docs/post-025-refresh`): README gana sección **Upgrade an existing agent** (swap manual de archivos
de sistema + `--regenerate` + rebuild/reinstalar units, verificado contra `setup.sh:1843-1850` y el
nombre real de la unit `agent-<name>.service`), conteo de tests 1052→1189, y se corrige un drift de
022 (el README mandaba a grepear el journal por `session url`/`connected`, que un `--spawn=session`
sano no imprime).

**024-fix-session-restart-retire MERGED** (PR #82, merge `febe652` en main, 2026-07-25; branch desde
main=`9b97654`, 2026-07-20; VERSION 0.15.0→**0.16.0**). Plan: `specs/024-fix-session-restart-retire/plan.md`. **BUG MEDIDO EN
HARDWARE, VIVO EN MAIN, introducido por 022 y cazado por su propio gate T051**: un `systemctl restart`
retira el puntero de una sesión VIVA y anuncia una nueva, matando el enlace del operador.
`session_decide` (`scripts/lib/session_pointer.sh:212-224`) conserva solo si el marcador es `killed`,
pero Claude Code atrapa SIGTERM y sale con 0 → systemd reporta `exited` tanto en parada externa como
en fin de sesión. El discriminador de 022 no discrimina, y como `killed` casi nunca ocurre la regla
se comporta como **"retirar siempre"** — textualmente lo que la investigación de 022 declaró que
sería regresión.

**FASE 0: LA HIPÓTESIS OBVIA ERA FALSA, MEDIDA.** El candidato "`ExecStop` solo corre en paradas
explícitas" se **refutó**: también corre cuando el proceso sale solo. La asimetría real está un hook
más arriba y es **temporal, no de valor**: systemd puebla `$EXIT_CODE`/`$EXIT_STATUS` recién cuando el
proceso principal ya murió, así que **dentro de `ExecStop`** están DEFINIDAS si salió solo y VACÍAS si
la parada la inicia systemd (que corre `ExecStop` antes de matarlo). `ExecStopPost` es idéntico en los
tres casos que hay que separar — por eso 022 no podía verlo; la información existía, estaba en el hook
anterior. Sonda con unit de usuario desechable (sin sudo, sin tocar el agente): 5 casos + 3
repeticiones c/u = **15/15 consistente**, incluida la variante `Restart=always` de la unit real.
Bordes medidos: sale-solo-con-fallo (código 3) **omite `ExecStop`** por completo; ignorar TERM da
`timeout`/`killed`/`KILL`. Regla adoptada de 4 filas, con **conservar** como default ante
incertidumbre (lo contrario de hoy): conservar de más cuesta una conversación muerta y visible;
retirar de más cuesta trabajo del operador sin aviso. `service_result`/`exit_status` YA se persisten
(`:137`) y ninguna decisión los lee. **NO MEDIDO y declarado así**: si la restauración del enlace
sigue valiendo tras un apagado largo, y la frecuencia relativa de los dos casos (el journal de mclaren
retiene UN solo boot, ~2 días) — esta última quedó irrelevante para el diseño, porque con un
discriminador real no hay que elegir qué caso romper. `session_pointer.sh` **NO** está espejado a
`docker/` (verificado) → DOCKER_E2E fuera de alcance. Constitución 6/6 PASS, sin violaciones.
**SC-006: el gate de hardware corre ANTES del merge** — van dos seguidas mergeadas sin él (021 costó
el PR #79, 022 costó este defecto).

**IMPLEMENTADO 2026-07-24 (test-first, 43/45 tareas):** `session_pointer.sh` gana `session_classify_stop`
(EXIT_CODE en ExecStop → `external`/`session-ended`), `session_decide_cause` (default **conservar** ante
incertidumbre, lo contrario de hoy) y la lectura/fusión de `stop_cause` en el marcador — UN solo fichero,
dos escritores, un consumidor por rename (el borrador de dos ficheros lo tumbó la pasada adversarial).
Nueva plantilla `local-session-stop.sh.tpl` (ExecStop) + directiva en la unit + render en `setup.sh`;
`local-session-check.sh.tpl` decide por causa y nombra causa Y decisión; `agentctl doctor` reporta la
causa y avisa si la unit INSTALADA no trae ExecStop (leído con `systemctl show -p`, nunca `cat`).
**Seis tests de 022 codificaban la política contraria** —cuatro lo decían en su nombre
(*"indeterminacy favours availability"*)— actualizados preservando su intención, con el porqué en cada
uno. Suite **1183 ok / 0 not ok** en bash 5.3.15 y 3.2.57 (base 1159, +24). Mutación: revertir la regla
tumba 12 tests, dos con "restart" en el título (SC-004). `--regenerate`: única diferencia en la unit es
la directiva ExecStop (T032). VERSION 0.15.0→**0.16.0** (verificado a mano vs origin/main). Un error
propio corregido: la línea base en background quedó contaminada por editar en paralelo → se descartó.

**GATE DE COMPOSICIÓN en mclaren (2026-07-24, sin `sudo`, agente intocado):** los TRES hooks reales
renderizados, cableados a una unit de systemd **de usuario**, sobre un workspace desechable con un
`claude` falso que atrapa SIGTERM y sale 0 — valida la **composición**, el hueco exacto por el que se
coló 022. Medido: `systemctl --user restart` **conserva** el puntero byte-idéntico sin hermano retirado
(SC-001 mecánica); un self-exit lo **retira** (SC-002, sin regresión); un marcador truncado **no**
destruye un puntero vivo (SC-007). Las 4 cadenas de observabilidad capturadas del stderr real (SC-003).
Delta portado con 6/6 hashes idénticos a `ab4bb32`, backups `.bak-pre024`; el `doctor` cazó EN VIVO la
unit instalada sin ExecStop. Sondas versionadas en `probes/`.

**GATE DE PRODUCCIÓN CERRADO (2026-07-24 23:28, mclaren, con `sudo` del operador) — SC-006 corrió
ANTES del merge, rompiendo el patrón de 021/022.** El operador instaló la unit de PRODUCCIÓN
(`sudo cp` + `daemon-reload` + `restart`). Verificado en el host (lectura, sin imprimir secretos):
`systemctl show -p ExecStop` confirma `agent-session-stop.sh` instalado; `active/running`,
`Result=success`. **La medición decisiva salió del journal del system-unit —que SÍ es consultable, a
diferencia del user-unit del gate de composición—:** `agent-session-check.sh: previous stop was external
(systemd) — session pointer kept`. El `sessionId` sobrevivió **byte-idéntico al reinicio**: pid viejo
`claude[2118]` y pid nuevo `claude[500467]` reportan el mismo `session_01A1obgNuL2XkXLX7bdr6nQV`, y el
`bridge-pointer.json` vivo apunta a ese — **el vendor reconectó a la misma sesión, no anunció una nueva**,
lo contrario del bug de 022 (que el Jul 20 retiró el puntero; su `.retired.json` lleva otro `sessionId`).
Marcador consumido por rename; `doctor` sin WARN de `ExecStop`. Journal del user-unit no consultable en
el arnés (`-- No entries --`); el del system-unit de producción sí. **MERGEADO tras este gate** (squash
`febe652`, `main` sincronizada y verificada: VERSION 0.16.0, `session_decide_cause`/`session_classify_stop`
presentes, directiva ExecStop en el template y en el render de `setup.sh`, historia lineal 022→023→024) —
SC-006 cumplido (el gate de hardware corrió ANTES del merge, por primera vez en tres features). Residual
NO bloqueante: la confirmación visual del operador desde el celular (la identidad del `sessionId`
reconectado ya es prueba de alcance). 023 T026 (medir ferrari) sigue abierta, sin relación con 024.

**023-fix-render-ampersand MERGED** (PR #81, merge `9b97654` en main, 2026-07-19; branch rebasada
sobre main=`ab4bb32` tras el merge de 022; VERSION 0.14.0→**0.15.0**). Plan:
`specs/023-fix-render-ampersand/plan.md`. **BUG MEDIDO, VIVO EN PRODUCCIÓN, ajeno
a toda rama en curso** (falla igual en un worktree limpio de main): `scripts/lib/render.sh:90,95`
expanden los `{{campo}}` de un bloque `{{#each}}` con `${var//patrón/reemplazo}`, y **desde bash 5.2**
un `&` sin escapar en el REEMPLAZO significa "todo el texto coincidente" (compatibilidad ksh93). El
valor `A&B` sale como `A{{url}}B` — sin error, sin warning, sin rc≠0. Medido en tres bash: 3.2.57
correcto; **5.2.37 en mclaren (host de agente) corrupto**; 5.3.15 (Homebrew) corrupto. Consumidores:
`modules/mcp-json.tpl:48` y `modules/env-example.tpl:14`, ambos sobre `MCPS_ATLASSIAN` (campos `name`,
`url`, `email`) — y `env-example.tpl:15-19` escribe `{{url}}`/`{{email}}` DIRECTO al `.env` generado,
o sea el bug degradaba el artefacto más sensible del workspace.

**FASE 0 CIERRA 3 DE LAS 4 PREGUNTAS ABIERTAS, MIDIENDO**: (1) el arreglo "obvio" —escapar el `&` en
el valor— **está descartado por medición**: en bash 3.2 inserta un backslash literal (7/9 casos rojos),
o sea arregla 5.2+ y ROMPE 3.2, que hoy funciona. (2) `shopt -s compat51` **no existe** en 5.3 y
`BASH_COMPAT=5.1` **no** restaura el comportamiento → descartado. (3) **Por qué el bug vivió meses**:
`bats` es `#!/usr/bin/env bash`; `/opt/homebrew/Cellar/bash/5.3.15` se creó el **2026-07-19 10:38:34**
(única versión en el Cellar, `installed_on_request:false` → dependencia transitiva), así que antes
`env bash` resolvía a `/bin/bash` 3.2. La corrida de suite que terminó 10:40 arrancó ~10:28 bajo 3.2 →
VERDE; la que terminó 11:44 arrancó post-10:38 bajo 5.3 → ROJA. **El mismo commit dio verde y rojo el
mismo día en la misma máquina y nada en el repo lo declaraba.** Queda abierta solo ferrari (túnel SSH
caído): sin medir su bash ni su `agent.yml`.

**DECISIÓN**: primitiva nueva `_render_replace_all` con recorrido de prefijo/sufijo
(`${t%%"$p"*}` / `${t#*"$p"}`), que **no tiene cadena de reemplazo** → no hay categoría "carácter
especial" que escapar, ni hoy ni cuando bash 6 agregue otra regla. Arreglo estructural, no de escapado.
Medido correcto en las 3 versiones × 9 valores + autorreferencial; cero subprocesos (200 sustituciones
en 0s vs ~1s de la alternativa perl). Runner-up documentado: perl con `ENV{REPL}`+`/e`, que es lo que el
propio archivo ya usa en `:105-110` para el bloque completo (esa línea NO se toca, es correcta).
**NO hay datos dañados**: el `agent.yml` de mclaren no tiene filas `mcps.atlassian` y cero valores con
`&` (solo conteo, nunca se imprimieron valores). `render.sh` **NO** está espejado a `docker/` →
DOCKER_E2E fuera de alcance (verificado, no supuesto). Constitución 6/6 PASS, sin violaciones.

**IMPLEMENTADO 2026-07-19 (test-first, 25/27 tareas):** `_render_replace_all` conectada en los dos call
sites (`render.sh:90,95`). **SEGUNDO BUG, AUTOINFLINGIDO, cazado por el propio gate de no-regresión**:
la primera versión capturaba el resultado con `row_expanded=$(...)`, y `$(...)` recorta los saltos de
línea finales sin condición → se comía la línea en blanco entre filas consecutivas de un `{{#each}}`
en el `.env` generado. Arreglado con byte centinela (`; printf '@'` / `%@`); test de regresión propio
agregado. Guard de no-drift + línea de versión de bash visible en cada corrida (vía `&3`, funciona en
una corrida normal sin flags) + `CLAUDE.md`/`README.md` corregidos. Suite completa: 1066 ok/3 not ok
bajo 5.3.15, 1068 ok/1 not ok bajo 3.2.57 — las 4 fallas son ruido preexistente ajeno (heartbeat/backup,
pasan limpio en aislamiento), ninguna toca `render.sh` ni `render.bats` (28/28 en ambas versiones).
Mutación: revertir un call site tumba 4 tests, incluido el dedicado. Shellcheck limpio. PR #81 abierto
contra main y **MERGEADO** (`9b97654`) — T027 cerrado. Pendiente no bloqueante: T026, medir ferrari
cuando vuelva el túnel SSH.

**REBASE SOBRE 022 (2026-07-19) — la trampa que dejó y que git NO delata:** al mergearse 022 el PR
quedó CONFLICTING. Los conflictos marcados eran dos y triviales (`.specify/feature.json`, `CHANGELOG.md`),
pero **el peligroso fue `VERSION`, que git auto-mergeó SIN marcar conflicto**: ambas ramas habían escrito
`0.14.0`, así que textualmente coincidían y el rebase las dio por resueltas, dejando dos features
distintas reclamando la misma versión. El conflicto era semántico, no textual. Regla que sale de acá:
**después de todo rebase, verificar `VERSION` contra `origin/main` a mano** — el rebase no lo va a
avisar. 023 quedó en `0.15.0` (T023 ya tenía escrita esta regla de desempate desde antes de existir el
conflicto). De paso se corrigió un defecto que dejó el merge de 022 en `main`: su heading `### Changed`
quedó insertado ENTRE su propia viñeta y la de 021, así que la entrada de 021 —un *Fixed*— aparecía
archivada bajo *Changed*. Se le devolvió su `### Fixed`.

**022-local-session-lifecycle MERGED** (PR #80, merge `ab4bb32` en main, 2026-07-19; branch desde
main=`7e50c44`, VERSION 0.13.0→0.14.0). Plan: `specs/022-local-session-lifecycle/plan.md`. Con
`--spawn=session` el proceso sale PORQUE su sesión terminó, `Restart=always` lo revive, y Claude Code
lee un puntero cuyo escritor está muerto como "reutiliza el environment Y el sessionId" → re-anuncia
una sesión que el relay ya cerró, con TODO el diagnóstico en verde (is-active, 0 restarts, sin errores
en journal, socket ESTABLISHED con tráfico real). **El reboot no era el disparador**: solo propagó un
puntero ya envenenado; terminar una conversación desde el celular basta. **`--spawn=same-dir` NO lo
arregla** (probado sobre el agente real: reutiliza igual y además destruye la señal de causa de salida).
FIX: `ExecStopPost` persiste `$SERVICE_RESULT`/`$EXIT_CODE`/`$EXIT_STATUS`; `ExecStartPre` lo lee antes
de arrancar. Salió solo ⇒ retirar el puntero (rename, nunca delete); lo mató systemd ⇒ dejarlo (la
sesión puede seguir viva y la reutilización del vendor restaura el mismo enlace — medido DOS veces en
hardware, por eso "limpiar siempre al boot" habría sido regresión). Sin detector nuevo (precedente
`ebfe35f`). Doctor: delata `exited` sin consumir junto a puntero vivo, y DEJA de grepear el journal por
`session url|connected|polling` (un `--spawn=session` sano es silencioso ahí → avisaba en todo agente
sano). US3: el nombre de sesión sale de `deployment.session_name` en vez de componerse con `$(hostname)`
(un agente bautizado con su host leía `mclaren-mclaren-admin`). Suite 1141 ok / 1 not ok, y ese único
rojo es el bug de 023, preexistente y ajeno. Mutación 5 corridas, y una destapó un test propio que
pasaba por la razón equivocada (S16 asertaba un hint compartido por dos avisos). **T051 SIGUE ABIERTA
y el merge ocurrió sin ella**: el gate de hardware en mclaren (necesita `sudo`) estaba planificado
ANTES del merge, precisamente porque en 021 correrlo después costó un PR aparte (#79) con dos bugs de
portabilidad que la suite de macOS no podía ver. Se repitió el patrón. El riesgo concreto: los hooks
`ExecStopPost`/`ExecStartPre` solo corren en el host Linux del agente, así que su primera ejecución
real será en producción y cualquier defecto de portabilidad ahí saldrá igual que los de 021.

**021-local-secret-delivery MERGED** (PR #78, merge `dbe8274` en main, 2026-07-18; branch desde
main=`cd6ad89` v0.12.0, VERSION 0.12.0→0.13.0). Plan: `specs/021-local-secret-delivery/plan.md`. **BUG MEDIDO EN HARDWARE VIVO**: el
`.env` del workspace NUNCA llega a los procesos del agente en modo local. En mclaren, el entorno de la
sesión corriendo tiene **0** de sus 6 secretos declarados (`tr '\0' '\n' < /proc/<MainPID>/environ |
grep -cE '^(GITHUB_PAT|ATLASSIAN_MCLAREN_TOKEN)=' → 0`), mientras su `.mcp.json` declara 7 MCPs y
referencia 6 variables. Docker entrega vía `env_file` de compose; local NO tiene equivalente (la única
`EnvironmentFile` es `.state/remote-control.env`, con 4 claves NO secretas). Peor: el healthcheck local
lee sus secretos de OTRO archivo (`.state/healthcheck-notify.env`) que NADIE crea → el wizard te pide el
token del notifier y la alerta de DEGRADED nunca se dispara.

DISEÑO (Fase 0: workflow `wf_7f4e37a8-1f4`, 6 investigadores + síntesis adversarial, 313 tool calls):
**`EnvironmentFile=-<workspace>/.env` en la unit de sesión, PRIMERO** (antes de `remote-control.env` —
en systemd gana el ÚLTIMO, así el PATH/HOME/CLAUDE_CONFIG_DIR del launcher nunca lo pisa una línea del
operador; un PATH malo hace ENOENT a todo spawn de MCP = el 203/EXEC histórico). El prefijo `-` es
OBLIGATORIO: un `.env` ausente/corrupto es no-op, no falla de unit — **eso ES FR-004, impuesto por
systemd, no por nuestro código**. Claude Code expande `${VAR}` de `.mcp.json` desde su propio env y
lanza los MCPs, así que esa línea cierra todo el hueco del catálogo.

CLARIFICACIONES (decididas por el usuario 2026-07-13): alcance = sesión + healthcheck (los 4 timers NO
reciben secretos, menor privilegio); `healthcheck-notify.env` = override de compatibilidad (si existe
gana; un scaffold nuevo nunca lo crea); secreto faltante = doctor + WARN al boot, **nunca falla dura**
(el ciclo sigue fail-silent — lo que muere es el silencio hacia el operador; NO enmienda la
constitución).

HALLAZGOS CRÍTICOS: (1) el healthcheck hoy hace `. "$NOTIFY_ENV"` — **RCE**, porque
`--restore-from-fork` descifra un `.env.age` REMOTO al `.env`; el reemplazo PARSEA, nunca sourcea.
(2) Un nombre de variable inválido hace que systemd loguee el `KEY=VALUE` COMPLETO al journal (fuga de
credencial) — y el alias Atlassian del wizard **no está validado**: `cenco-corp` →
`ATLASSIAN_CENCO-CORP_TOKEN`, nombre inválido en systemd → se dropea TODO el set Atlassian *y* se
filtra el token. Sanitizar el alias ENTRA en 021 o 021 despacha una fuga el día uno. (3) systemd y
compose **divergen** en shapes que el operador escribe a mano (backslash final se traga la línea
siguiente; BOM descarta el archivo ENTERO en silencio) → nueva lib `scripts/lib/env_file.sh`
(`env_file_get` sin `eval`, `env_file_lint` del subset portable). (4) **NUNCA** crear un archivo
llamado `.env` bajo `.state/` — `backup_identity.sh:72,152-154` ya cifra esa ruta y empezaría a
empujar secretos al fork. (5) El doctor debe inspeccionar la unit **INSTALADA**: `--regenerate` no
reinicia nada y solo reinstala la unit si `install_service:true` Y `sudo -n` funciona — si no, deja el
archivo staged y sale 0 (agente sigue sin secretos, doctor lo daría verde).

DESMENTIDO por medición en vivo: la doc de Claude Code dice que un `${VAR}` sin definir hace fallar el
parseo de TODO el `.mcp.json`; en 2.1.185 **no pasa** (los 7 MCPs enumeran igual). `${VAR:-}` en
`mcp-json.tpl` baja de bloqueante a prudente. Constitución 6/6 PASS.

**IMPLEMENTADO 2026-07-13 (test-first, 18/20 tareas — T019/T020 pendientes de despliegue/merge):**
unit de sesión con `EnvironmentFile=-.env` PRIMERO + `ExecStartPre=-agent-secret-check.sh`;
`scripts/lib/env_file.sh` nueva (`env_file_get` sin eval, `env_file_lint` del subset portable);
`validate_atlassian_alias` cierra la fuga de credencial; `${VAR:-}` en las 9 referencias de secretos
de `mcp-json.tpl`; healthcheck reescrito para parsear (nunca sourcear) con `.state/healthcheck-notify.env`
como override de compatibilidad; `_local_secrets_doctor` nuevo en `agentctl` (D1-D4, WARN nunca fail);
seam `SETUP_SYSTEMD_DIR` en `install_service` (antes sin cobertura de test alguna). Mutation spot-check 3/3
(orden de EnvironmentFile detectado por 1 test, RCE del healthcheck por 1, lint neutralizado por 11).
Shellcheck limpio. Docker intacto (guardado por assertion byte-level). VERSION 0.12.0→0.13.0.

**GATE DE HARDWARE mclaren — PASADA DE STAGING (2026-07-18, PRE-restart):** porté los 8 deltas de runtime
al workspace vivo (los 8 eran byte-idénticos a `main` antes → el delta 021 aplicó limpio, sin merge
quirúrgico), corrí `./setup.sh --regenerate` → unit **staged, NO instalada** (`sudo` pide contraseña en
mclaren; es exactamente la trampa que D3 existe para cazar). Invariantes en artefactos verificados en el
host: unit con `EnvironmentFile=-.env` primero + `ExecStartPre=-`, `.mcp.json` todo `${VAR:-}`, healthcheck
con `env_file_get` y cero `source`. **El gate cazó DOS bugs de portabilidad en `agentctl doctor`** — ambos
en código que solo corre en el host Linux del agente, ambos verdes en la suite macOS, ambos arreglados
test-first (RED→GREEN + re-verificados en mclaren): (1) `stat -f` (macOS) en Linux es `--file-system` →
falso WARN de permisos del `.env` + fuga del statvfs; fix helper portable `_file_mode` (GNU `-c %a`
primero). (2) D3 leía la unit con `systemctl cat`, que da `Permission denied` en una unit root-only → el
check se saltaba en silencio; fix a `systemctl show -p EnvironmentFiles`. Suite: **1052 ok, 0 not ok** (977
baseline + 75 nuevos = 73 + 2 del gate).

**GATE T019 CERRADO — PASADA POST-RESTART (2026-07-18):** el operador instaló la unit staged +
`daemon-reload` + `restart`; unit `active`. Medido en vivo, solo conteos, sin imprimir jamás un valor:
la unit carga `.env (ignore_errors=yes)` **primero** y `remote-control.env (ignore_errors=no)` segundo
(ese `ignore_errors=yes` **es** FR-004, impuesto por systemd); **`/proc/<MainPID>/environ`: `GITHUB_PAT`
0→1 y las 6 variables declaradas presentes (6/6), ninguna vacía** — el bug medido está muerto;
`systemctl show -p Environment` vacío (SC-003, sin exposición); `agentctl doctor` con `✓ .env present
(0600)` + `✓ installed unit loads the workspace .env` (D3 pasa) y cero WARN de secreto faltante; el
`ExecStartPre` no avisó (correcto, no falta nada). La detección FR-004 se validó con `env_file_lint`
sobre fixtures desechables (BOM y backslash final), nombrando la clave y **nunca el valor**. DOS ítems
NO corridos a propósito (costo > evidencia, documentados en `tasks.md`): el test *empírico* de `.env`
corrupto (exigía 2 restarts más y solo reprobaría el `ignore_errors=yes` que systemd ya reporta) y una
llamada MCP viva (Claude Code spawnea los MCP on-demand: el cgroup solo tiene la sesión, 10 hilos sin
hijos; la cadena está probada donde importa — el proceso que los lanza lleva los 6 secretos, y heredar
el entorno al hijo es garantía del SO). Fase
spec-kit: **implement completo y MERGEADO (PR #78, `dbe8274`); T020 cerrado. Los 2 fixes de portabilidad
del doctor NO alcanzaron ese merge (el gate corrió después) → van en PR aparte desde
`021-doctor-portability`. T019 a medias: falta el restart con `sudo` en mclaren + la batería
post-restart.**

**020-docs-refresh MERGED** (PR #76, merge `336f559`, 2026-07-13; docs-only, VERSION sigue 0.12.0).
Plan: `specs/020-docs-refresh/plan.md`. Puso los 14 docs en alcance (README, agentic-quickstart.{es,en},
las 8 guías de docs/ y los 3 templates de docs modules/{next-steps.en,next-steps.es,claude-md}.tpl) al
día con la realidad del código. Fase 0 (workflow de 16 agentes, 475 verificaciones): **121 hallazgos** (33
false, 46 stale, 41 needs-qualifier, 1 unverified) en `drift-audit.md` (oráculo SC-001) + orden canónico
de 52 prompts del wizard en `wizard-prompt-order.md` (oráculo SC-002; fuente `wizard_answers()`) +
coverage-map de 25 subsistemas 011-019 (8 SIN documentar). Los peores eran: README (framing docker-only,
más el consejo FALSO `RESTORE_IDENTITY_KEY` env — solo existe el flag `--identity-key`), los dos quickstarts
(anteriores al prompt de deployment mode → reconstruidos sobre los 52 prompts), vault.md (sección QMD
pre-010: bunx manual + shape retirado de `.mcp.json`), adding-an-mcp.md, claude-md.tpl y
architecture.md:279 ("invoked via bunx").

**La lección del cierre — la pasada adversarial es obligatoria en features de docs.** Los escritores
cerraron los 121 hallazgos, pero un verificador por doc (instrucción: *refutar* al escritor releyendo el
código) cazó **14 errores nuevos** introducidos o arrastrados AL REESCRIBIR: el TMPDIR del wiki-graph NO
está bajo `.state` (es `<workspace>/scripts/heartbeat/tmp`, `wiki_graph.sh:310`); `/opt/npm-cache` es del
UID del agente, no de root (`Dockerfile:211`); rotar el token de Telegram NO se arregla con restart
(`ensure_channel_env_synced` early-returnea si la key ya existe, `start_services.sh:413`); `heartbeatctl`
NO regenera "todos los derivados", solo `heartbeat.conf` + crontab; el pin de MCPVault se single-sourcea
en `versions.sh:46` (dos drift-guards en bats), no en el template; un scaffold con fork deshabilitado SÍ
deja rama local `<agent>/live` (`setup.sh:1869-1881`); `NEXT_STEPS.md` NO lo refresca ningún
`--regenerate` (único call site: `setup.sh:1255`, dentro de `run_wizard`). Sin esa pasada se mergeaban.
Gates: SC-001 121/121 sin sobrevivientes, SC-005 `bats tests/` 977 ok / 0 not ok (baseline intacto; NINGÚN
string grepeado por tests cambió), SC-006 0 enlaces muertos.

**DOS HALLAZGOS DE CÓDIGO registrados en `specs/020-docs-refresh/research.md` (R5), NO arreglados —
candidatos a feature propia:**
1. **Modo local: ningún artefacto renderizado carga el `.env` del workspace en la sesión systemd.** La
   única `EnvironmentFile` de las units es `systemd-remote-control.service.tpl:12` →
   `.state/remote-control.env`, que define 4 claves (`CLAUDE_CONFIG_DIR`, `DISABLE_AUTOUPDATER`, `HOME`,
   `PATH`). Pero `mcp-json.tpl` pasa TODOS los secretos del catálogo por expansión `${VAR}`
   (`FIRECRAWL_API_KEY`:27, los seis `ATLASSIAN_*`:53-58, `GITHUB_PAT`:65, `AWS_*`:41-42). En docker
   resuelven vía `env_file` de compose (`docker-compose.yml.tpl:67`); **en local expanden a vacío** → un
   MCP opcional con `requires_secret: true` arranca sin credencial. El fix aparente
   (`EnvironmentFile=-<workspace>/.env`) exige su propio threat-model: el `.env` es `0600` y la unit corre
   como el operador.
2. **El piso de `bash 4+` NO lo exige el código** (ni un constructo bash-4-only —`declare -A`, `mapfile`,
   `local -n`, `${x,,}`, `coproc`— ni un gate de `BASH_VERSINFO`; la suite corre en macOS con bash 3.2 de
   stock). Corregido en el README y en el punto 1 de este archivo (que lo declaraba mal).

Fase spec-kit: **completa (19/19 tareas + T019 al merge, hecho).**

**019-fix-qmd-test-drift MERGED** (PR #74, merge `2bf984b`, 2026-07-12; rebasada sobre el squash de
018 antes del merge — historia lineal). Plan:
`specs/019-fix-qmd-test-drift/plan.md`. Cierra las 7 fallas PREEXISTENTES de la suite host (drift de
016): `tests/qmd-index.bats` (2) y `tests/qmd-setup.bats` (4) stubbean un `bunx` que `_qmd_run` ya no
invoca (post-016 ejecuta `$(_qmd_prefix)/node_modules/.bin/qmd` directo), y `tests/regenerate.bats`
(1) asume el shape pre-T036 de `.mcp.json` (`args[0]=@tobilu/qmd@…`) retirado por
`{{QMD_MCP_COMMAND}}`+`args:[]`. Fix: **seam canónico A** — binario `qmd` falso DENTRO del prefijo
gestionado (`$QMD_CACHE_HOME/pkg/node_modules/.bin/qmd`) más `.installed-hash` pre-sembrado vía
`_qmd_manifest`/`_qmd_sha` de la propia lib más `bun` no-op en PATH para los guards; el stub de éxito
DEBE emitir la señal de completitud 018 (`All content hashes already have embeddings` / `Pending: 0`)
o el reindex cae en `stalled`. Contrato: `specs/019-fix-qmd-test-drift/contracts/qmd-test-seam.md`
(seam B = override de `_qmd_run`, SOLO unit tests). regenerate: aserta backfill agent.yml (intacto)
más `command=/opt/agent-admin/scripts/qmd-mcp`, `args|length==0`. CERO cambios de producción
(tests-only; sin bump de VERSION); Tier-1 de docker-e2e-qmd.bats alineado al seam con
validación DIFERIDA al próximo DOCKER_E2E. **GATE CERRADO: `bats tests/` = 977 ok, 0 not ok
(antes 7), 20 skips esperados; intención de cobertura verificada por mutation spot-check 3/3.**
Fase spec-kit: **completa (12/12 tareas).**

**018-qmd-embed-completion MERGED** (PR #73, merge `5f5a2d3`, 2026-07-12; branch desde main=`70d8f23`,
VERSION 0.11.0→0.12.0). **Gate confirmatorio ferrari AÚN ABIERTO (corpus 2423 completo vía cron +
hit semántico, SC-006) + DOCKER_E2E Tier-2 (`pending→0`) — ambos ocurren en el despliegue de
v0.12.0.** Plan: `specs/018-qmd-embed-completion/plan.md`. Cierra el hallazgo
del gate confirmatorio de 017: `qmd embed` tiene un cap HARDCODEADO de 30min/sesión (`store.js:1377`
`maxDuration: 30*60*1000`, no configurable por env) → un embed grande de primera vez corta a
~859/2423 chunks ("LLM session expired") y el cron NO reanuda (guard `vault unchanged → skip embed`).
Fix (decisiones /speckit-clarify 2026-07-10): **LOOP alrededor del motor (NO parchear qmd) DENTRO de
una sola invocación** de `_qmd_reindex_locked` — pasadas frescas de `qmd embed` hasta
completar/stall/cap; el guard REANUDA si quedan pendientes (`pending>0` o desconocido); el estado
`qmd-index.json` gana `pending` + `last_status` `partial`/`stalled`; el cap es una **constante fija**
`QMD_EMBED_MAX_PASSES` (env-overridable solo para tests, NO en agent.yml). Señal de completitud/stall =
`qmd status` `Pending: N` + `✓ All content hashes already have embeddings`. Lib espejada
`scripts/lib`↔`docker/scripts/lib` → DOCKER_E2E OBLIGATORIO. Gates: bats host (loop/guard/stall
stubbeados) + DOCKER_E2E (`pending→0`) + ferrari (corpus 2423 completo + hit semántico limpio, SC-006).
Artifacts: `specs/018-qmd-embed-completion/{spec,plan,research,data-model,quickstart}.md` +
`contracts/{embed-completion,reindex-state}.md`. Implementación validada: 13 tests nuevos
(qmd-embed-completion.bats) + 5 de `pending` en qmd-index.bats + sanity check en contenedor
Alpine/musl real (las 3 funciones nuevas correctas bajo busybox); las 7 fallas restantes de la
suite en ese momento eran drift preexistente de 016 → cerradas por 019 (suite 977/0 tras ambos
merges). Fase spec-kit: **completa (17/18 tareas + T018 al merge, hecho).**

**017-qmd-sqlite-vec-musl MERGED** (PR #72, merge `70d8f23`, 2026-07-10, VERSION 0.11.0). Plan:
`specs/017-qmd-sqlite-vec-musl/plan.md`. **El DOCKER_E2E de 016 se CORRIÓ
(imagen `agent-admin:qmd-real`, Alpine musl aarch64) y reveló que 016 NO cierra el embed semántico:
hay un TERCER módulo nativo que la investigación de 17 agentes jamás vio.** node-llama-cpp (el "muro
real" temido) embebe OK sin SIGSEGV; el muro es `sqlite-vec-linux-arm64@0.1.9`, un prebuilt **glibc**
(needs `ld-linux-aarch64.so.1`, `__memcpy_chk@GLIBC_2.17`) que no carga en musl (el `vec0.so.so` era
red herring del fallback de dos intentos de SQLite). Solo afecta docker/musl (ferrari); local/glibc
(mclaren) el embed YA funciona. **FIX VERIFICADO end-to-end en musl**: compilar la amalgamación
oficial de sqlite-vec v0.1.9 con shim `-Du_int8_t=uint8_t …` (musl no expone nombres BSD) + toolchain
de 016, hornear en build a `/opt/agent-admin/sqlite-vec/vec0.so`, y swap del prebuilt glibc en
`_qmd_ensure_prefix` (gateado por el artefacto horneado + libc musl) → `embed` real "2 chunks in 24s"
+ vsearch semántico 42%. 017 completa el US2 de 016, des-stubea el DOCKER_E2E (embed+vsearch reales) y
arregla el defecto de la Fase A (usaba `bunx --help`, por eso 016 pasó el merge sin ejercer el
binding). Guardrail: par qmd 2.5.3 ↔ sqlite-vec 0.1.9. Decisión del usuario: 017 primero (test-first),
LUEGO un solo despliegue completo a mclaren+ferrari. **IMPLEMENTADO Y VALIDADO (2026-07-10): suite
host VERDE (959), shellcheck limpio, y DOCKER_E2E VERDE en Alpine musl aarch64 real (build + Fase A
con vec0 musl + Tier 2 embed real `last_status=indexed` + vsearch semántico "gato" + MCP sin BUG-4 +
RED con vec0/bigstack ausentes). Confianza ALTA — el gate DOCKER_E2E que 016 saltó ahora está CERRADO.
Cambios: `docker/scripts/build-sqlite-vec.sh` (nuevo), `docker/Dockerfile` (ARG SQLITE_VEC_VERSION +
compile gateado), `scripts/lib/qmd_index.sh` (`_qmd_swap_sqlite_vec`), `tests/qmd-sqlite-vec.bats`
(nuevo, 7), `tests/docker-e2e-qmd.bats` (des-stub embed real; arregla carrera de timing y aserción MCP
muerta), VERSION 0.11.0, CHANGELOG. Falta: commit + PR + gate confirmatorio ferrari (vault 2696 real),
que ocurre en el despliegue.** Fase spec-kit: implement hecho.

**016-qmd-native-deps MERGED** (PR #71, merge `14169cf`, 2026-07-10, VERSION 0.10.0). **Gates
confirmatorios AÚN ABIERTOS: DOCKER_E2E parcialmente corrido (léxico VERDE, embed ROJO por sqlite-vec
→ lo cierra 017) + ferrari.** Fix del root-cause de BUG 4 (qmd falla en docker
Alpine musl). Plan: `specs/016-qmd-native-deps/plan.md`. La
observabilidad de 015 (US4), desplegada en ferrari 2026-07-10, reveló el root-cause: `bunx
@tobilu/qmd@2.5.3` compila DOS módulos nativos sin prebuilt musl — `tree-sitter-*` (opcional; qmd usa
el `.wasm` de web-tree-sitter en runtime, el binding nativo es irrelevante) y `node-llama-cpp@3.18.1`
(DURO, para `qmd embed`; el muro real). Decisiones (clarify): **Opción A — mantener Alpine** (no
cambiar base OS) + **embed en alcance** + **DOCKER_E2E real** (des-stubear bunx). Diseño
(plan/research, 2 workflows 17+5 agentes): (1) `apk add build-base cmake git linux-headers libgomp`
gateado por build-arg `QMD_NATIVE_TOOLCHAIN`; `apk cmake` en PATH hace que node-llama-cpp use el
cmake del sistema (nunca el xpack glibc); (2) `scripts/lib/qmd_index.sh::_qmd_run`: `bunx` → prefijo
`bun install` con `trustedDependencies:[better-sqlite3,node-llama-cpp]` → tree-sitter NO compila
(WASM), node-llama-cpp SÍ; env `NODE_LLAMA_CPP_CMAKE_OPTION_GGML_NATIVE=OFF`+`GGML_CPU_ARM_ARCH=armv8-a`
y `LD_PRELOAD=/opt/agent-admin/bigstack.so` (pthread 8MB, hazard std::regex/stack musl 128KB) SOLO en
embed; (3) DOCKER_E2E tiers A(build)/B(update)/C(embed, gate `QMD_EMBED_E2E`) + detección RED por
`--build-arg QMD_NATIVE_TOOLCHAIN=0`. Veredicto adversarial: viable pero confianza **MEDIA** (nadie
demostró node-llama-cpp compilado-desde-fuente + cargado-por-bun + embed real en musl; riesgo bun/N-API
en dispose/exit, INDEPENDIENTE de musl) → **fallback B (base glibc, exigiría enmienda de constitución)
/ C (embeddings remotos) ARMADO** con criterio de disparo en research.md. Complexity Tracking: bloat de
toolchain (violación del *espíritu* minimalista; "Alpine single-stage" y Principle II intactos, sin
enmienda). Libs `scripts/lib/qmd_index.sh` espejada a docker (COPY) → DOCKER_E2E OBLIGATORIO. Artifacts:
`specs/016-qmd-native-deps/{spec,plan,research,data-model,quickstart}.md` +
contracts/{qmd-invocation,dockerfile-toolchain,docker-e2e-tiers,qmd-version-guardrail}.md. Gates: host
suite + shellcheck, DOCKER_E2E des-stubeado (ABSORBE el gate DOCKER_E2E que 015 dejó pendiente),
confirmatorio ferrari (embed real + wiki-graph 2696 + `/tmp` sin ENOSPC — es el gate de BUG 4 que 015
difirió). Siguiente: `/speckit-tasks`.

Prior: 001-deps-upgrade (PR #55), 002-fix-schema-bool, 003-bootstrap-hardening (PR #56),
004-macos-bootstrap-hardening (PR #59), 005-fix-schema-false (PR #60), 006-headless-bootstrap (PR #61),
007-fix-mcp-test-drift (PR #62), 008-fix-postlogin-plugin-install (PR #63),
009-fix-extra-marketplace-install (PR #64), 010-self-managing-rag (PR #65),
011-local-standalone-mode (PR #66), 012-local-vault-rag (PR #67), 013-local-rag-parity (PR #68),
014-wiki-graph-rag (PR #69), 015-local-mode-hardening (PR #70), 016-qmd-native-deps (PR #71) — all
merged. 011 added the second
wizard **deployment mode** (`deployment.mode: docker|local`); Principle II is a justified opt-in
VIOLATION in local mode. 012 ported vault+QMD+backup to local systemd (5 units, lib relocation to
`scripts/lib/` with docker mirror, cron→OnCalendar via `local_schedule.sh`, `VAULT_ROOT_OVERRIDE`,
mode-resolved `VAULT_MCP_PATH`/`GCAL_CREDS_PATH`). 013 closed the 30 RAG parity gaps: XDG storage
pair (`XDG_CACHE_HOME`/`QMD_CONFIG_DIR` under `.state` — the qmd binary never read
`QMD_CACHE_HOME`), wrapper PATH self-provisioning, watcher vault env + supervised loop, ops
parity (kill-switch/doctor 0-1-2/manual actions/healthcheck), and docker `bunx` symlink
(FR-016 — docker qmd never ran against real binaries before). 014 shipped the wiki-graph +
normalization + additive `vault_seed_missing` upgrade (VERSION 0.8.0). The 013/014 hardware
gates were CLOSED by the 2026-07-08 live deployment (mclaren local + ferrari docker, wiki-graph
validated on 2696 real pages, zero mutation) — that gate surfaced 015's 4 bugs. 015 (VERSION 0.9.0)
brought those 4 host-only patches into the launcher code test-first: US1 `resolve_claude_bin`
(absolute path to the stable symlink) + `_persist_claude_cli` in agent.yml + fail-loud
`_export_local_context`; US2 `_libc_variant` (loader/ldd/getconf probe) + glibc/musl bun build
selection with a real-execution guard; US3 new mirrored `scripts/lib/rag_obs.sh`
(`redact_secrets`+`scratch_dir`) + host-backed `TMPDIR` under `.state` for bunx/qmd/wiki-graph
(`docker-compose.yml.tpl` UNTOUCHED → Principle II intact) + redacted real-stderr capture; US4
observability-only. An adversarial pre-commit review (5 dimensions) caught 2 self-introduced
defects and fixed them before commit: truncate-before-redact secret leak at the 500-byte boundary
(fixed to redact-then-truncate in qmd_index.sh + wiki_graph.sh, with a boundary regression test),
and 2 dead `[[ ]]` e2e assertions (fixed to `grep -q`).

**016 STATUS (2026-07-10): MERGED to main (PR #71, `14169cf`), host suite GREEN (952), shellcheck
clean — but the DOCKER_E2E + ferrari confirmatory gates were NOT run before merge (still open).** Wrapper `_qmd_run` (managed `bun install` prefix, tree-sitter unbuilt via default-deny,
node-llama-cpp/better-sqlite3 compiled) + Dockerfile toolchain gated by `QMD_NATIVE_TOOLCHAIN` +
`bigstack.so` (8MB-stack pthread shim for musl std::regex; now also grows attr!=NULL <8MB threads) +
compose build-arg + DOCKER_E2E des-stubbed (RED via `--build-arg=0`, throwaway `HOME`). An adversarial
review (15-agent workflow) caught 4 self-introduced defects — all fixed: (1) `bun install >/dev/null`
killed US4 observability → capture to scratch + redacted `_qmd_log` + `return 1` on absent binary
(degrade to old binary if it survives); (2) `docker/bigstack.c` untracked → `git add`ed; (3+4) two
dead `!`-negated bats assertions → reordered last. Plus 2 plausible hardenings: separate
`QMD_INSTALL_TIMEOUT` (3600s) for the one-time build, and the bigstack attr!=NULL coverage. **T036
CLOSED (user chose extend-now):** the qmd MCP server no longer uses `bunx` (repeated BUG 4 + split the
prefix) — new `qmd_mcp_exec` (no timeout, bigstack, from the managed prefix) behind an image-baked
`docker/scripts/qmd-mcp` + a rendered local `agent-qmd-mcp.sh` (fixes PATH + `QMD_CACHE_HOME` so its
prefix matches the reindex writer); `mcp-json.tpl` → `{{QMD_MCP_COMMAND}}` (per-mode, like
`QMD_MCP_ENV`). **Gates still OPEN (not runnable in this session): DOCKER_E2E on a Docker host + the
ferrari confirmatory (real embed + MCP start + wiki-graph 2696 + `/tmp` no ENOSPC).** VERSION 0.10.0,
CHANGELOG done.
<!-- SPECKIT END -->
