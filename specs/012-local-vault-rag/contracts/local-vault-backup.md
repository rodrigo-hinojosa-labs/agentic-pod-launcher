# Contract: Vault base + backup en modo local (FR-001/002/007/008, D2/D8)

## Siembra host-side (setup.sh, rama local de scaffold/regenerate)

```text
Gate:   deployment.mode=local AND vault.enabled=true
Flujo:  source scripts/lib/vault.sh
        root="<ws>/<vault.path>"                      # default <ws>/.state/.vault — SIN rebase
        vault_ensure_paths "$root"
        [ vault.force_reseed=true ] && vault_backup_and_reseed ... (contrato lib: backup ts + reset flag)
        [ vault.seed_skeleton=true ] && vault_seed_if_empty "$root" <skeleton_src> <SCAFFOLD_DATE>
Invariantes:
  - Vault poblado → no-op byte-exacto (idempotente).
  - vault.enabled=false → cero efectos (ni mkdir).
  - Modo docker → este camino NO corre (la siembra sigue en el boot del contenedor, intacta).
```

## Remap del MCP vault (`modules/mcp-json.tpl`)

```text
docker:  "args": [..., "/home/agent/.vault"]          # byte-idéntico a hoy
local:   "args": [..., "{{LOCAL_VAULT_DIR}}"]         # <ws>/<vault.path> resuelto en render-time
Patrón:  {{#if DEPLOYMENT_MODE_IS_DOCKER}}...{{/if}}{{#unless ...}}...{{/unless}} (mismo de git/filesystem)
Nota:    docker hoy NO templa vault.path en el MCP (quirk pre-existente) — se conserva tal cual (SC-003).
Export:  LOCAL_VAULT_DIR se exporta junto a DEPLOYMENT_MODE_IS_DOCKER (antes del render de .mcp.json).
```

## Entrypoint `scripts/local/agent-vault-backup.sh` (rendered)

```text
Env fija: VAULT_ROOT_OVERRIDE=<ws>/<vault.path>, VAULT_BACKUP_STATE_FILE=<ws>/scripts/heartbeat/vault-backup.json,
          agent.yml del workspace; VAULT_BACKUP_CACHE_DIR default ~/.cache/agent-backup.
Flujo:   source scripts/lib/backup_vault.sh
         fork_url ← .scaffold.fork.url de agent.yml; ausente → exit 0 silencioso (paridad docker)
         vault_backup run (mismas fases: hash → short-circuit | stage wipe → commit → push → state)
Exit:    siempre 0. Credencial git: la del entorno del operador (helper HTTPS / llave SSH) — supuesto documentado.
Timer:   OnCalendar={{BACKUP_TIMER_ONCALENDAR}} (conversión FR-012; default horario *-*-* *:00:00), Persistent=true.
```

## Invariantes docker (SC-003 — tests que NO cambian de aserción)

- `vault_resolve_root` sin `VAULT_ROOT_OVERRIDE` → rebase `/home/agent` idéntico (`backup-vault-lib.bats`).
- Exclusiones, hash, wipe-tree, rama huérfana, no-op sin fork: sin cambios (`backup-vault-git.bats`, `backup-vault-cmd.bats`).
- Cron del contenedor (`heartbeatctl:212-217`) intacto.

## agentctl (FR-013)

- `status` (modo local, vault on): estado de `vault-backup.timer` + qmd units (active/staged/absent).
- `doctor`: frescura de `vault-backup.json` vía el helper existente (`agentctl:170-210`, mismo umbral que docker) + skeleton presente cuando seed_skeleton=true.
