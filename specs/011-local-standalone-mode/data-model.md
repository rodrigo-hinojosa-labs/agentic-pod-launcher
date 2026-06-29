# Data Model — Modo agente local standalone (011)

**Date**: 2026-06-28 · **Branch**: `011-local-standalone-mode`

## agent.yml — campo nuevo

Único cambio de esquema en v1: un campo en el bloque `deployment` existente.

```yaml
deployment:
  host: "..."            # (existente)
  workspace: "..."       # (existente) — WorkingDirectory de la unit local
  install_service: true  # (existente)
  claude_cli: "claude"   # (existente)
  mode: "docker"         # NUEVO — enum: docker | local (default docker)
```

- **`deployment.mode`** — enum `docker|local`. Default `docker`. Flatea a `DEPLOYMENT_MODE`.
  - Validación: `scripts/lib/schema.sh` `_SCHEMA_ENUMS += '.deployment.mode=docker,local'` (opcional: ausente = válido = legacy docker; un valor presente debe ser del enum).
  - Backfill: en `setup.sh --regenerate`, si `deployment.mode` ausente → escribir `docker` en `agent.yml` (espejo de `vault.qmd.version` en 010), para que el modo sea explícito y `--regenerate` quede determinista.

**No se agregan más campos en v1.** El resto se **deriva** al instalar (evita duplicar verdad):

| Dato | Derivación | Dónde |
|------|-----------|-------|
| Usuario del servicio | `id -un` del operador al instalar | `User=` de la unit |
| `HOME` | `$HOME` del operador | EnvironmentFile |
| `CLAUDE_CONFIG_DIR` | `<workspace>/.state/.claude` | EnvironmentFile |
| `WorkingDirectory` | `deployment.workspace` | unit |
| `--name` de la sesión | `<hostname>-<agent.name>` | ExecStart de la unit |
| Nombre de la unit | `agent-<agent.name>.service` (local) | install_service |

> Campos local-específicos (p.ej. `deployment.local.config_dir`, `deployment.local.systemd_scope`) se podrán agregar en un follow-up si la derivación resulta insuficiente; v1 los deriva para mantener el esquema mínimo.

**`claude.config_dir` es docker-only (C1).** El campo `claude.config_dir` de `agent.yml` (hoy `/home/agent/.claude`, la ruta DENTRO del contenedor) NO aplica al modo local: la sesión corre en el host, así que el modo local **fija** `CLAUDE_CONFIG_DIR=<workspace>/.state/.claude` vía el EnvironmentFile e **ignora** `claude.config_dir`. El render del modo local no lee ese campo. (Un follow-up podría reinterpretarlo si se necesita una ruta configurable.)

**Scope de la unit en v1 = unit de sistema (A1).** v1 instala una **unit de sistema** (`/etc/systemd/system/agent-<name>.service`) con `User=$(id -un)` (el usuario del operador). `systemd --user` + `loginctl enable-linger` queda como opción de follow-up (no v1), para evitar la complejidad del linger y mantener un único camino de instalación/persistencia.

## Variables de render derivadas

- `DEPLOYMENT_MODE` — flateado de `agent.yml` (`docker`|`local`).
- `DEPLOYMENT_MODE_IS_DOCKER` — derivada en `setup.sh` tras `render_load_context`: `true` si `${DEPLOYMENT_MODE:-docker}` = `docker`, si no `false`. Gatea `{{#if}}`/`{{#unless}}` en `next-steps.*.tpl` y `claude-md.tpl`.

## Entidades

- **Modo de despliegue** — `deployment.mode`; selecciona el set de artefactos y la ruta de runtime. Única fuente de la ramificación.
- **Base de config del agente** — archivos rendizados en ambos modos: `CLAUDE.md`, `.mcp.json`, `scripts/heartbeat/*` (incl. `heartbeat.conf`), vault sembrado, config RAG/qmd, skills. En local viven en el workspace del host directamente (no en una imagen).
- **Unit de sesión Remote Control** (local) — `agent-<name>.service`: `Type=simple`, `Restart=always`/`RestartSec=10`, `StartLimitIntervalSec=300`/`Burst=5`, `ExecCondition` por `.credentials.json`, `WorkingDirectory` trusted, `EnvironmentFile`, `User=<operador>`, `ExecStart=claude remote-control --name <NAME> --spawn=session --verbose` (sin skip-permissions).
- **EnvironmentFile** (local) — `<workspace>/.state/remote-control.env` (0640): `CLAUDE_CONFIG_DIR`, `DISABLE_AUTOUPDATER=1`, `HOME`; sin `ANTHROPIC_API_KEY`.
- **Credenciales full-scope** — `<CLAUDE_CONFIG_DIR>/.credentials.json` (0600): producidas por el login OAuth; contienen `expiresAt` (ms epoch); secreto, gitignored, reutilizable.
- **Estado de confianza del workspace** — `<CLAUDE_CONFIG_DIR>/.claude.json` → `projects["<workdir>"].hasTrustDialogAccepted=true`; más `hasCompletedOnboarding=true` pre-sembrado.
- **Healthcheck** (local) — `agent-<name>-healthcheck.{service,timer}`: timer ~5min → script que evalúa activo/conectado/expiración y reporta OK/WARN/DEGRADED.
- **Kill switch** (local) — `systemctl stop/disable agent-<name>.service` (con `Restart=always`, `stop` no rearranca).

## Transiciones de estado de la unit local

```
(sin login)        --ExecCondition falla-->   inactive (NO failed)
(login presente)   --systemctl start-->       active (running)  --señal de conexión en journal-->  connected
active             --sesión completa/PID muere--> Restart (≤~10s) --> active
active             --systemctl stop (kill switch)--> inactive (NO rearranca)
login expira       --healthcheck timer-->     DEGRADED (notifica); unit puede seguir "active" pero sin control
```

## Gitignore

- `.state/` ya está gitignored a nivel de template (Principio V) → cubre `.state/.claude/.credentials.json` y `.state/remote-control.env`. Verificar que el `.gitignore` del workspace local incluya explícitamente cualquier env/secreto del modo local que caiga fuera de `.state/`.
