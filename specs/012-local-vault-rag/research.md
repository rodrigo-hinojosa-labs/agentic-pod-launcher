# Research: Vault + RAG operativos en modo local (012)

Sin NEEDS CLARIFICATION abiertos: las incógnitas se resolvieron con (a) la auditoría del 2026-07-04 (workflow de 4 lectores con evidencia file:línea sobre el repo) y (b) la sesión de clarify del spec (3 preguntas). Este documento consolida cada decisión con su racional y alternativas descartadas.

## D1 — Reubicación de libs: canónico host-side + espejo al build context

- **Decision**: `git mv docker/scripts/lib/qmd_index.sh scripts/lib/`, `git mv docker/scripts/lib/backup_vault.sh scripts/lib/`, `git mv docker/scripts/qmd_watch.sh scripts/`. El bloque de espejo de `setup.sh` (scaffold `setup.sh:1501-1535` + regenerate) copia las tres al `<dest>/docker/scripts/{lib/,}` SOLO en modo docker. Dockerfile sin cambios (sus `COPY` leen el build context del workspace, que el espejo puebla).
- **Rationale**: verificado que el precedente `vault.sh` funciona exactamente así — `docker/scripts/lib/vault.sh` NO existe checked-in en el repo; el canónico es `scripts/lib/vault.sh` y el espejo del scaffold lo materializa en el destino. `docker compose build` siempre corre en un workspace scaffoldeado (también en DOCKER_E2E), nunca en el clon crudo. Así las libs viajan con TODO workspace: docker las hornea vía espejo, local las source-a directo.
- **Alternatives considered**: (1) copiar desde `docker/scripts/` al workspace local en scaffold — mantiene el canónico bajo `docker/`, arquitectura confusa (flujo host dependiendo del árbol de imagen) y rompe la regla "local no lleva docker/"; (2) duplicar las libs (copia en ambos árboles del repo) — deriva garantizada, rechazada por Principio VI (no duplicar fuentes).

## D2 — Resolución del vault root por modo

- **Decision**: override aditivo por env (`VAULT_ROOT_OVERRIDE`; nombre final en `contracts/local-vault-backup.md`) chequeado al inicio de `vault_resolve_root`; sin él, comportamiento actual intacto (rebase `/home/agent/${path#.state/}`). Entrypoints locales exportan el override a `<ws>/<vault.path>`. Para qmd se reusa `QMD_VAULT_DIR` (override ya existente en `qmd_index.sh:49-63`).
- **Rationale**: los tests `backup-vault-lib.bats` fijan el rebase docker como contrato ("rebases non-default path under /home/agent") — un cambio de firma los rompería; un env aditivo los deja intactos y es el mismo estilo de inyección que `HEARTBEATCTL_*`/`QMD_*`.
- **Alternatives considered**: parámetro posicional nuevo en `vault_resolve_root` (rompe llamadores existentes: `heartbeatctl`, `start_services.sh`); duplicar la función para local (deriva).

## D3 — Conversión cron→systemd: formas comunes + fallback (clarify Q2)

- **Decision**: función pura `cron_to_systemd_calendar()` en `scripts/lib/local_schedule.sh` (lib nueva, sin side effects al source). Soporta exactamente: `*/N * * * *` → `*-*-* *:0/N:00`; `M * * * *` → `*-*-* *:M:00`; `M H * * *` → `*-*-* H:M:00`. Cualquier otra forma → imprime el default del llamador + warning a stderr. `setup.sh` la evalúa en render-time y exporta `QMD_TIMER_ONCALENDAR` / `BACKUP_TIMER_ONCALENDAR` como contexto de render; los timers templan `OnCalendar={{...}}`.
- **Rationale**: cubre el 100% de los valores que el wizard emite hoy (`*/5 * * * *`, `0 * * * *`, `30 3 * * *`) con una tabla de tests chica; `agent.yml` sigue siendo fuente única en sintaxis cron (sin claves paralelas); una forma rara degrada visible en vez de generar un timer inválido.
- **Alternatives considered**: parser cron completo en bash (matriz de tests enorme para valores que nadie usa); claves nuevas `*_interval_minutes` para local (rompe fuente única, complica switch de modo — rechazada en clarify); `OnUnitActiveSec` (no equivale a cron anclado a minutos del reloj y complica el caso diario).

## D4 — Enganche del setup first-run qmd: doble, auto-sanador (clarify Q1)

- **Decision**: (a) `--login` backgroundea `agent-qmd-reindex.sh --setup-only` (nohup, sin bloquear; solo si qmd habilitado — bloque render-condicional); (b) el mismo entrypoint, cuando lo invoca el timer, corre `qmd_setup_if_needed` ANTES de `qmd_reindex` en cada tick (sentinel `.qmd-setup-ok` = no-op instantáneo).
- **Rationale**: paridad con docker, donde el boot llama el setup en cada arranque; si el login falla o el operador lo salta, el primer tick del timer (≤5 min) construye el índice sin intervención. Un solo entrypoint para ambos triggers minimiza superficies.
- **Alternatives considered**: solo login (fallo = sin corpus hasta re-login manual); solo timer (login no reporta nada de qmd; primer índice demora); `ExecStartPre` en la unit del watcher (acopla setup a un componente opcional — el watcher puede no existir sin inotify-tools).

## D5 — Storage del índice en local: `QMD_CACHE_HOME=<ws>/.state/.cache/qmd`

- **Decision**: los entrypoints locales exportan `QMD_CACHE_HOME` bajo `.state/.cache/qmd` (más `QMD_INDEX_STATE_FILE=<ws>/scripts/heartbeat/qmd-index.json` y `QMD_VAULT_DIR`).
- **Rationale**: reproduce la equivalencia documentada de 010 (`~/.cache/qmd` ↔ `.state/.cache/qmd` vía bind) sin bind-mount: el índice viaja con el workspace (migración = `cp -a` del workspace, igual que docker) y no contamina el `~/.cache` del operador. Índice regenerable, NO respaldado (Constitution V de 010, no se reabre).
- **Alternatives considered**: `~/.cache/qmd` del operador (se pierde en migración de workspace; colisiona si el operador usa qmd personalmente); respaldarlo a `backup/vault` (rechazado en 010: 300 MB regenerables).

## D6 — Units systemd: mismo ciclo de vida que 011

- **Decision**: 5 units nuevas renderizadas desde `agent.yml`, gateadas por flags: `agent-<name>-qmd-reindex.{service,timer}` + `agent-<name>-qmd-watch.service` (si `vault.qmd.enabled`), `agent-<name>-vault-backup.{service,timer}` (si `vault.enabled`). `User={{OPERATOR_USER}}`, `WorkingDirectory={{DEPLOYMENT_WORKSPACE}}`. Watcher con `Restart=always`/`RestartSec=2` (reemplaza el respawn de 2 s del watchdog docker). Instalación: `install_service` con sudo, staged sin sudo; `--login` generaliza el loop de instalación staged (hoy healthcheck: `local-login.sh.tpl` paso 6) a una lista; kill-switch y `--uninstall` las paran/remueven.
- **Rationale**: los tres gotchas de instalación de 011 (unit staged no instalada, healthcheck staged, prompt bloqueante) ya se pagaron y su patrón está testeado (`local-login-install.bats`); reutilizarlo evita re-aprenderlos.
- **Alternatives considered**: systemd --user (rechazado en 011 — requiere linger, decisión heredada); un solo service "supervisor local" que multiplexe (reinventa el watchdog del contenedor; systemd YA es el supervisor).

## D7 — Observabilidad: journal + state files (default de plan)

- **Decision**: entrypoints logean a stdout/stderr → journal de systemd por unit; el estado máquina-legible queda en los JSON de `scripts/heartbeat/` (mismo esquema que docker). `agentctl status` muestra estado de units; `doctor` frescura de `vault-backup.json` (helper existente `agentctl:170-210`) + `qmd-index.json` + existencia de `index.sqlite` (clarify Q3).
- **Rationale**: systemd ya captura, rota y timestampea; crear archivos de log paralelos duplicaría sin agregar señal. Los state files son el contrato de frescura que doctor ya sabe leer.
- **Alternatives considered**: replicar los `logs/*.log` de docker (redundante con journal); OnFailure→Telegram para estas units (docker no notifica estos flujos — paridad; el healthcheck de sesión ya cubre la alerta crítica).

## D8 — Siembra local del vault (FR-001)

- **Decision**: `setup.sh` (rama local de regenerate + scaffold) source-a `scripts/lib/vault.sh` y ejecuta `vault_ensure_paths` + `vault_seed_if_empty` (y `vault_backup_and_reseed` si `force_reseed`) con el root local `<ws>/<vault.path>` — sin rebase.
- **Rationale**: la lib ya es host-compatible y está testeada (21 tests en `tests/vault.bats`); el comentario de su header ya prometía uso host-side ("setup.sh (host-side scaffold) — seed", hoy desactualizado — esta feature lo vuelve verdadero).
- **Alternatives considered**: sembrar desde `--login` (la siembra no necesita sudo ni login; el scaffold es el momento natural y así el MCP vault apunta a contenido desde el primer render); duplicar la lógica inline en setup.sh (deriva).
