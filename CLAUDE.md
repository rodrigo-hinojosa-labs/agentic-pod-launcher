# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

This is **the launcher**, not an agent. `./setup.sh` is a bash wizard that scaffolds a *separate*, self-contained agent workspace elsewhere on disk. The launcher is disposable after scaffolding — every subsequent operation (`--regenerate`, `--uninstall`, `heartbeatctl`) runs from inside the scaffolded workspace.

Three distinct code paths live in this repo, and confusing them is the most common mistake:

1. **Host-side launcher** — `setup.sh`, `scripts/lib/{yaml,render,wizard,wizard-gum}.sh`, `modules/*.tpl`. Runs on the user's Mac/Linux during scaffolding. Depends on host tools: `bash` (no version floor — no bash-4-only construct and no `BASH_VERSINFO` gate anywhere; the suite runs on macOS's stock 3.2), `yq v4+`, `jq`, `git`, BSD/GNU `sed`, optional `gum` (auto-downloaded to `scripts/vendor/bin/`).
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
**023-fix-render-ampersand ACTIVE** (branch `023-fix-render-ampersand` desde main=`7e50c44`,
2026-07-19). Plan: `specs/023-fix-render-ampersand/plan.md`. **BUG MEDIDO, VIVO EN PRODUCCIÓN, ajeno
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
Siguiente: `/speckit-tasks`.

**022-local-session-lifecycle EN PR #80, SIN MERGEAR** (branch `022-local-session-lifecycle` desde
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
pasaba por la razón equivocada (S16 asertaba un hint compartido por dos avisos). **PENDIENTE: T051 gate
de hardware en mclaren (necesita sudo), a correr ANTES del merge — en 021 el gate corrió después y
costó un PR aparte (#79).**

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
