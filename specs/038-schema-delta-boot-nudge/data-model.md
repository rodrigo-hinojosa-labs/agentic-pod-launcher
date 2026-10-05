# Data Model: Aviso de actualización de conocimiento al iniciar sesión

Sin base de datos. El estado son archivos dentro del workspace, un campo nuevo en `agent.yml` y una entrada
nueva en el `settings.json` de la sesión. Todo lo demás se deriva en el momento.

## 1. Archivos de estado

| Archivo | Tipo | Escritor | Lector | Ciclo de vida |
|---|---|---|---|---|
| `<ws>/.state/launcher/claude-md.upstream.md` | Derivado | `setup.sh --regenerate` (siempre) | regenerate, hook, doctor, el agente | Se reescribe en cada regenerate. Perderlo equivale a `unknown` hasta el próximo regenerate. |
| `<ws>/.state/launcher/claude-md.baseline.md` | Durable | regenerate (render, force, refresh, adopt); el agente u operador con `cp` tras integrar a mano | regenerate, hook, doctor | Nunca se borra por esta feature. Perderlo degrada a `pending_no_baseline` (aviso conservador), nunca a pérdida de datos. |
| `<vault>/_templates/.schema-updates-<v>.applied` | Existente (014/037) | `vault_seed_missing`, `vault_seed_if_empty` | `vault_pending_deltas` | Sin cambios. Solo lectura para esta feature. |
| `<vault>/CLAUDE.md` | Existente, del agente | El agente | `vault_pending_deltas` (`grep -F` del hito) | Esta feature nunca lo escribe (FR-013). |
| `<ws>/CLAUDE.md` | Derivado preservable | regenerate según §4 | Claude Code (carga automática), hook, doctor | Re-render solo si coincide con la línea base. |
| `<ws>/scripts/hooks/upgrade-notice.sh` | Derivado | regenerate (siempre) | Claude Code (hook `SessionStart`) | Se re-renderiza en cada regenerate. |
| `<ws>/scripts/hooks/install-upgrade-notice-hook.sh` | Derivado | regenerate (siempre) | boot docker, login local, regenerate local | Se re-renderiza en cada regenerate. |

En docker, `<ws>` es `/workspace` y `<ws>/.state` también es `/home/agent` (dos bind-mounts sobre el mismo
directorio, `docker-compose.yml.tpl:55,60`). `<vault>` es el `VAULT_MCP_PATH` del modo: `/home/agent/.vault` en
docker, `LOCAL_VAULT_DIR` en local (`setup.sh:2501-2506`).

## 2. Campo nuevo en `agent.yml`

```yaml
features:
  upgrade_notice:
    enabled: true   # inyectar el aviso al iniciar sesion; doctor y el re-render no dependen de esto
```

- Default `true`. Backfill en `regenerate()` con `has()`, nunca con `//` (el `//` de yq colapsa un `false`
  explícito igual que `null`; gotcha documentado en 028/037).
- Se agrega a `_SCHEMA_BOOLEANS` (`scripts/lib/schema.sh`) y a los fixtures `sample-agent{,-with-vault}.yml`.
- Sin prompt de wizard. El heredoc del wizard lo escribe con `enabled: true`.
- Se hornea en el hook al renderizar. Apagado, el hook sale sin imprimir; sigue registrado.

## 3. Tabla de hitos de la capa vault

Vive en `scripts/lib/vault.sh` (`vault_delta_versions`, `vault_delta_checkpoint`). Orden ascendente.

| Versión | Hito literal (`grep -F` contra `<vault>/CLAUDE.md`) |
|---|---|
| 0.8.0 | `wiki/normalization/` |
| 0.27.0 | `## Actionability (PARA)` |

Delta pendiente ⇔ `.applied` existe ∧ hito ausente. No hay estado de "ya avisado": el pendiente se recalcula
en cada lectura y desaparece cuando el agente integra.

Invariantes (vigiladas por tests): una fila por cada `modules/vault-deltas/schema-updates-*.md`; el skeleton
contiene todos los hitos; el literal 0.27.0 coincide con `wiki_graph.sh:458`.

## 4. Máquina de estados de la capa workspace

Notación: `C` = `<ws>/CLAUDE.md`, `U` = upstream, `B` = baseline; igualdad = `cmp -s`.

### Estado (lo que leen el hook y doctor: `claude_md_state`)

| Estado | Condición | ¿Pendiente? |
|---|---|---|
| `unknown` | `U` no existe | No (no se puede saber) |
| `in_sync` | `C = U` | No |
| `customized` | `C ≠ U`, `B` existe, `B = U` | No: ediciones propias sobre la plantilla vigente |
| `pending_template` | `C ≠ U`, `B` existe, `B ≠ U` | Sí: la plantilla cambió; diff exacto `B → U` |
| `pending_no_baseline` | `C ≠ U`, `B` no existe | Sí: procedencia desconocida (toda la flota hoy) |

### Decisión de regenerate (`claude_md_regenerate_decision`)

Se evalúa después de escribir `U`. Primera fila que aplica:

| # | Condición | Acción | Efecto |
|---|---|---|---|
| 1 | `C` no existe | `render` | `C ← U`, `B ← U` |
| 2 | `--force-claude-md` y el operador confirma | `render` | `C ← U`, `B ← U` |
| 3 | modo local y `C` es el `CLAUDE.md` del launcher (027) | `render` | `C ← U`, `B ← U` |
| 4 | `B` existe, `C = B`, `C ≠ U` | `refresh` | `C ← U`, `B ← U` |
| 5 | `C = U`, `B` ausente o distinta de `U` | `adopt` | `B ← U` |
| 6 | `C = U`, `B = U` | `noop` | sin cambios |
| 7 | cualquier otro | `preserve` | sin cambios; el estado queda `customized` o `pending_*` |

### Transiciones fuera de regenerate

- El agente u operador integra a mano y corre `cp U B`: `pending_template` o `pending_no_baseline` →
  `customized` (o `in_sync`, si `C` quedó idéntico a `U`).
- El agente edita `C` sin tocar `B`: `in_sync` → `customized` si `B = U`; el siguiente cambio de plantilla lo
  lleva a `pending_template`, nunca a `refresh` (el archivo ya no coincide con la línea base).

### Invariantes

- Ninguna acción de regenerate escribe `C` si `C ≠ B` salvo las filas 1-3 (FR-007).
- Dos regenerate seguidos sin cambios de entrada son byte-idénticos en `C`, `U` y `B`.
- Un workspace recién scaffoldeado queda en `in_sync` con `B = U` (SC-007).

## 5. Entrada en `settings.json`

Agregada por `install-upgrade-notice-hook.sh`, aditiva y con dedupe por `command`:

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "<ws>/scripts/hooks/upgrade-notice.sh", "timeout": 10 } ] }
    ]
  }
}
```

- Docker: `$HOME/.claude/settings.json` (= `<ws>/.state/.claude/settings.json`), `command` =
  `/workspace/scripts/hooks/upgrade-notice.sh`.
- Local: `<ws>/.state/.claude/settings.json` (el `CLAUDE_CONFIG_DIR` de la unit), `command` = ruta absoluta del
  workspace.
- Heartbeat: la copia aislada de `settings.json` descarta `.hooks.SessionStart`.

## 6. Sin cambios

- `.graph/findings.json`, `wiki-graph.json` y `schema_delta_pending` de 037.
- `vault_seed_missing` y los marcadores `.applied`.
- `features.heartbeat.review`.
- `personas/<agente>.md`: se sigue leyendo vía `agent.role_file`; esta feature no lo escribe.
