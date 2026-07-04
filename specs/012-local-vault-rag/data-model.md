# Data Model: Vault + RAG en modo local (012)

## Entidades y ubicaciones

| Entidad | Path (modo local) | Owner/creador | Ciclo de vida |
|---|---|---|---|
| Vault local | `<ws>/<vault.path>` (default `.state/.vault`) | Siembra en scaffold/regenerate (`vault_seed_if_empty`) | Idempotente; `force_reseed` → backup timestampeado + re-siembra + flag reset en `agent.yml` |
| Índice QMD | `<ws>/.state/.cache/qmd/` (`index.sqlite`, `models/`, sentinel `.qmd-setup-ok`, lock `.reindex.lock`) | Setup first-run (login bg / timer guard) | Regenerable; NUNCA respaldado; viaja con el workspace |
| Estado reindex | `<ws>/scripts/heartbeat/qmd-index.json` | `qmd_reindex` (escritura atómica mktemp+mv) | Esquema docker sin cambios: `{hash, last_run, last_status, runs}` |
| Estado backup vault | `<ws>/scripts/heartbeat/vault-backup.json` | `vault_write_state` | Esquema docker sin cambios |
| Cache de clones backup | `~/.cache/agent-backup/vault-clone/` (override `VAULT_BACKUP_CACHE_DIR`) | `backup_vault.sh` | Por-rama, no compartido (regla del modelo de 3 ramas) |

## Units systemd (renderizadas desde agent.yml, gateadas por flags)

| Unit | Gate | Tipo | Claves relevantes |
|---|---|---|---|
| `agent-<name>-qmd-reindex.service` | `vault.qmd.enabled` | oneshot | `User=<operador>`, `ExecStart=<ws>/scripts/local/agent-qmd-reindex.sh` |
| `agent-<name>-qmd-reindex.timer` | `vault.qmd.enabled` | timer | `OnCalendar={{QMD_TIMER_ONCALENDAR}}`, `Persistent=true` |
| `agent-<name>-qmd-watch.service` | `vault.qmd.enabled` | simple | `Restart=always`, `RestartSec=2`, `ExecStart=<ws>/scripts/local/agent-qmd-watch.sh` (wrapper con env) |
| `agent-<name>-vault-backup.service` | `vault.enabled` | oneshot | `ExecStart=<ws>/scripts/local/agent-vault-backup.sh` |
| `agent-<name>-vault-backup.timer` | `vault.enabled` | timer | `OnCalendar={{BACKUP_TIMER_ONCALENDAR}}`, `Persistent=true` |

Instalación: `/etc/systemd/system/` con sudo; staged (workspace root para la principal era el patrón 011 — las nuevas van a `scripts/local/` como el healthcheck) sin sudo; `--login` instala staged; kill-switch `stop`; `--uninstall` `disable+rm`.

## Variables de contexto de render (nuevas)

| Variable | Origen | Consumidor |
|---|---|---|
| `LOCAL_VAULT_DIR` | `setup.sh`: `<ws>/<vault.path>` resuelto (solo se computa; usada solo en modo local) | `mcp-json.tpl` (arg MCP vault), entrypoints `.tpl` |
| `QMD_TIMER_ONCALENDAR` | `cron_to_systemd_calendar "$(yq .vault.qmd.schedule)" "*/5"` | `local-qmd-reindex.timer.tpl` |
| `BACKUP_TIMER_ONCALENDAR` | `cron_to_systemd_calendar "$(yq .vault.backup_schedule)" "hourly@:00"` | `local-vault-backup.timer.tpl` |

Ya existentes que se reusan: `DEPLOYMENT_MODE_IS_DOCKER`, `DEPLOYMENT_WORKSPACE`, `AGENT_NAME`, `OPERATOR_USER`, `OPERATOR_HOME`, `VAULT_QMD_VERSION`, flags `VAULT_*_ENABLED` (flatten de agent.yml).

## Contrato de env de los entrypoints locales

| Env | Valor (local) | Default docker (intacto) |
|---|---|---|
| `QMD_CACHE_HOME` | `<ws>/.state/.cache/qmd` | `$HOME/.cache/qmd` |
| `QMD_VAULT_DIR` | `<ws>/<vault.path>` | `vault_resolve_root` (rebase `/home/agent`) |
| `QMD_INDEX_STATE_FILE` | `<ws>/scripts/heartbeat/qmd-index.json` | `/workspace/scripts/heartbeat/qmd-index.json` |
| `VAULT_ROOT_OVERRIDE` (nuevo, aditivo) | `<ws>/<vault.path>` | ausente → rebase actual |
| `VAULT_BACKUP_CACHE_DIR` | (default) `~/.cache/agent-backup` | `/home/agent/.cache/agent-backup` |
| `QMD_REINDEX_CMD` (watcher) | `<ws>/scripts/local/agent-qmd-reindex.sh` | `heartbeatctl qmd-reindex` |

## Transiciones de estado (sin cambios de esquema)

- Setup qmd: `sin-sentinel → (add→update→embed OK) → sentinel` | `fallo → sin-sentinel (reintento próximo tick)`.
- Reindex: `hash igual → skipped` | `hash distinto → update+embed → {hash,last_status}` | `lock tomado → exit 0 silencioso`.
- Backup: `hash igual → no-op` | `distinto → commit+push → state` | `sin fork → no-op exit 0`.
