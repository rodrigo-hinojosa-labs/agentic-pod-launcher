# Data Model: 013-local-rag-parity

**Date**: 2026-07-05. Entidades y contratos de datos de la feature. No hay entidades de negocio nuevas; el modelo es el **contrato de entorno/storage** del subsistema RAG y el **inventario de units** que la capa operacional debe conocer completo.

## E1 — Contrato de env del subsistema qmd (por proceso y modo)

| Variable | La lee | Docker (escritor y lector) | Local escritor (wrappers) | Local lector (MCP qmd) |
|----------|--------|----------------------------|---------------------------|------------------------|
| `XDG_CACHE_HOME` | binario qmd (`store.js:428`, `llm.js:119`) | no seteada → `~agent/.cache` (= `.state` por bind) | **NUEVO** `<ws>/.state/.cache` | **NUEVO** `<ws>/.state/.cache` (env granular `.mcp.json`) |
| `QMD_CONFIG_DIR` | binario qmd (`collections.js:60`) | no seteada → `~agent/.config/qmd` (= `.state`) | **NUEVO** `<ws>/.state/.config/qmd` | **NUEVO** `<ws>/.state/.config/qmd` |
| `QMD_CACHE_HOME` | solo lib bash (`qmd_index.sh:51`) | no seteada → `$HOME/.cache/qmd` | ya existente: `<ws>/.state/.cache/qmd` (se mantiene) | n/a |
| `QMD_VAULT_DIR` | lib + watcher | no seteada → resolve del contenedor | ya existente (reindex) / **NUEVO** (watcher) | n/a |
| `VAULT_ROOT_OVERRIDE` | `backup_vault.sh::vault_resolve_root` | no seteada (rebase contenedor intacto) | ya existente (reindex, backup) / **NUEVO** (watcher) | n/a |
| `QMD_INDEX_STATE_FILE` | lib | default contenedor | ya existente: `<ws>/scripts/heartbeat/qmd-index.json` | n/a |
| `PATH` | todos | imagen (baked) | **NUEVO** prefijo `~op/.local/bin` + `<ws>/scripts/vendor/bin` en los 3 wrappers | ya cubierto (`remote-control.env:13`) |

**Invariante (FR-001)**: para cada modo, el storage resuelto por el escritor y por el lector es idéntico. Docker lo logra por `HOME` compartido (sin setear nada — byte-idéntico); local lo logra por el par explícito de arriba. **Regla de cambio**: escritor y lector se modifican en el mismo commit, con tests que rendericen ambos lados.

## E2 — Layout de storage por modo (post-013)

| Artefacto | Docker (efectivo) | Local |
|-----------|-------------------|-------|
| Índice (`index.sqlite`) | `<ws>/.state/.cache/qmd/` (vía bind) | `<ws>/.state/.cache/qmd/` |
| Modelos (~300MB) | `<ws>/.state/.cache/qmd/models/` | `<ws>/.state/.cache/qmd/models/` |
| Config colecciones (`index.yml`) | `<ws>/.state/.config/qmd/` | `<ws>/.state/.config/qmd/` |
| Sentinel `.qmd-setup-ok` / `.reindex.lock` | ídem cache root | ídem cache root (ya correcto) |
| Clone cache backup vault | `~agent/.cache/agent-backup/vault-clone` (= `.state`) | `~op/.cache/agent-backup/vault-clone` (fuera del ws; purge/nuke local lo remueve — R12) |

Propiedades: regenerable, jamás respaldado (Constitution V + decisión 010), viaja con el workspace en migración rsync/cp -a (SC-002).

## E3 — State files operacionales (`<ws>/scripts/heartbeat/`)

- **`qmd-index.json`** (existente, schema de 010 sin cambios): `last_run`, `last_status` (`ok|skipped|error`), contadores. Escrito atómicamente por la lib en cada tick. **Nuevo consumo**: `_local_vault_qmd_doctor` degrada por `last_status=error` (FR-009); `_local_vault_qmd_status` muestra `last_run`.
- **`vault-backup.json`** (existente): **nuevo consumo** — staleness >25h vía `_check_backup_freshness` en doctor local (FR-009).
- **`qmd-schedule.fallback`** (**NUEVO**, R10): presente solo cuando la conversión cron→OnCalendar cayó al default. Contenido legible: `original=<cron>`, `applied=<OnCalendar>`, `at=<ISO>`. Ciclo de vida: creado/eliminado exclusivamente por `--regenerate` (derivado puro); leído por status/doctor (FR-013).

## E4 — Inventario de units locales (fuente única para la capa operacional)

| Unit | Tipo | Debe conocerla |
|------|------|----------------|
| `agent-<n>.service` (sesión) | simple | killswitch, uninstall, healthcheck, status/doctor |
| `agent-<n>-healthcheck.{timer,service}` | oneshot+timer | killswitch (**NUEVO**), uninstall (012), status/doctor |
| `agent-<n>-qmd-reindex.{timer,service}` | oneshot+timer | killswitch (012), uninstall (012), status/doctor (012), acciones manuales (**NUEVO**) |
| `agent-<n>-qmd-watch.service` | simple+loop (**cambia**: wrapper supervisado D5) | killswitch (012), uninstall (012), healthcheck WARN-si-failed (**NUEVO**), status/doctor (012) |
| `agent-<n>-vault-backup.{timer,service}` | oneshot+timer | killswitch (**NUEVO**), uninstall (012), status/doctor staleness (**NUEVO**), acciones manuales (**NUEVO**) |

**Regla (FR-008)**: kill-switch = las 5 filas; toda unit nueva futura debe sumarse a killswitch + uninstall + doctor en el mismo cambio.

## E5 — Variables de render nuevas (setup.sh → templates)

| Variable | Valor docker | Valor local | Consumida por |
|----------|--------------|-------------|---------------|
| `QMD_MCP_ENV` | `{}` (literal, byte-idéntico) | `{"XDG_CACHE_HOME":"<ws>/.state/.cache","QMD_CONFIG_DIR":"<ws>/.state/.config/qmd"}` | `mcp-json.tpl` bloque qmd |

Nota de test: `tests/schema.bats` mantiene DOS listas `known_external` — ambas deben sumar `QMD_MCP_ENV` (gotcha conocido de 012).
