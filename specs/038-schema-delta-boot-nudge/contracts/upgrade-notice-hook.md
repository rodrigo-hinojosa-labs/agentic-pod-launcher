# Contract: hook `SessionStart`, instalador y línea de doctor

## 1. Hook: `modules/upgrade-notice.sh.tpl` → `scripts/hooks/upgrade-notice.sh`

Renderizado en todo `--regenerate`, ambos modos, sin gate. Ejecutable.

### Placeholders

| Placeholder | Valor |
|---|---|
| `{{VAULT_MCP_PATH}}` | Raíz del vault del modo: `/home/agent/.vault` (docker) o `LOCAL_VAULT_DIR` (local). Ya exportado por regenerate (`setup.sh:2501-2506`). |
| `{{USER_LANGUAGE}}` | Leído tal cual; el hook decide `en` vs. resto. No se re-exporta ni se sanea (lo consume también `claude-md.tpl`). |
| `{{FEATURES_UPGRADE_NOTICE_ENABLED}}` | `true`/`false`, aplanado de `features.upgrade_notice.enabled`. |
| `{{#if VAULT_ENABLED}}` | Se hornea como `_vault_enabled="true"` solo si `vault.enabled` es `true`; en cualquier otro caso (`false`, ausente, un `agent.yml` sin bloque `vault:`) queda `_vault_enabled="false"`. Va como condicional y no como `{{VAULT_ENABLED}}` porque una variable sin definir no es lo mismo que `false`. |

### Comportamiento

1. `set +e`. Drenar stdin (`cat >/dev/null`); el payload no se usa.
2. Si el interruptor no es `true` → `exit 0` sin salida.
3. `ws` = dos niveles arriba del propio script (`scripts/hooks/` → `<ws>`): `/workspace` en docker, la ruta del
   workspace en local. Sin rutas de workspace horneadas.
4. Cargar `<ws>/scripts/lib/vault.sh` y `<ws>/scripts/lib/claude_md.sh`. Si alguna no existe o las funciones no
   quedan definidas → `exit 0` sin salida.
5. Capa vault, **solo si `_vault_enabled` es `true`** (caso borde del spec: un vault deshabilitado que sigue en
   disco con un delta depositado NO produce aviso; la capa del workspace es independiente de ese interruptor y
   `agentctl doctor` salta la misma capa): `vault_pending_deltas "${VAULT_ROOT_OVERRIDE:-{{VAULT_MCP_PATH}}}"`. `VAULT_ROOT_OVERRIDE` es la
   misma convención que ya respeta `vault_resolve_root`; sirve de costura para los tests host del hook
   renderizado en modo docker, cuya ruta horneada (`/home/agent/.vault`) no existe en el host. Por cada versión, documento = `<vault>/_templates/
   schema-updates-<v>.md` si existe; si no, `<ws>/modules/vault-deltas/schema-updates-<v>.md`.
6. Capa workspace: `claude_md_state <ws>/CLAUDE.md <U> <B>`; pendiente solo en `pending_template` y
   `pending_no_baseline`.
7. Sin pendientes → `exit 0` sin salida (SC-002: 0 bytes).
8. Con pendientes y sin `jq` → `exit 0` sin salida (doctor sigue reportando).
9. Con pendientes → armar el texto (§2) y emitir exactamente un objeto:
   `{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"<texto>"}}`.
10. `exit 0` en todo camino. Nunca escribe archivos. Nunca imprime a stdout otra cosa que el JSON.

### Garantías

- Termina en menos de 1 s (dos funciones O(número de deltas) y hasta tres `cmp`).
- Mismo estado pendiente → mismo texto en ambos modos salvo rutas (SC-006).
- Sin `yq`, sin red, sin pipelines `producer | grep -q`.

## 2. Texto del aviso (CANON)

ASCII puro, sin tildes (regla de bytes de 033/034/037). Líneas separadas por `\n`, en este orden: cabecera, una
línea por delta (orden ascendente), a lo más una línea de workspace, cierre. Variables: `{V}` versión, `{DOC}`
documento del delta, `{CP}` hito, `{VAULT}` raíz del vault, `{C}` `<ws>/CLAUDE.md`, `{U}` y `{B}` rutas
absolutas de upstream y baseline.

`user.language` distinto de `en` (incluye `es` y `mixed`):

- **CANON-N1-es**: `Aviso del launcher al iniciar sesion: tienes conocimiento pendiente de actualizar.`
- **CANON-N2-es** (por delta): `- Vault, delta de schema {V}: lee {DOC} e integra sus secciones en {VAULT}/CLAUDE.md. Queda integrado cuando ese archivo contiene la linea literal: {CP}`
- **CANON-N3-es** (`pending_no_baseline`): `- Tu CLAUDE.md del workspace no coincide con la plantilla vigente del launcher. La version vigente esta en {U}; hasta que se actualice, tratala como autoritativa para todo lo que describe sobre la maquinaria del launcher (vault, wiki-graph, qmd, heartbeat, backups). Compara con: diff {C} {U}. Si las diferencias vienen solo de la plantilla, pidele al operador que corra ./setup.sh --regenerate --force-claude-md. Si tienes contenido propio, integra lo nuevo de la plantilla y confirma con: cp {U} {B}`
- **CANON-N4-es** (`pending_template`): `- La plantilla del launcher cambio desde la ultima version que integraste en tu CLAUDE.md del workspace. Cambios exactos: diff {B} {U}. Integralos en {C} y confirma con: cp {U} {B}`
- **CANON-N5-es**: `No bloquees la peticion del operador por esto: responde primero, salvo que dependa de tu base de conocimiento. Mencionale estos pendientes una vez en esta sesion.`

`user.language` = `en`:

- **CANON-N1-en**: `Launcher notice at session start: you have knowledge pending an update.`
- **CANON-N2-en**: `- Vault schema delta {V}: read {DOC} and integrate its sections into {VAULT}/CLAUDE.md. It counts as integrated once that file contains the literal line: {CP}`
- **CANON-N3-en**: `- Your workspace CLAUDE.md does not match the current launcher template. The current version is at {U}; until it is updated, treat it as authoritative for everything it says about the launcher machinery (vault, wiki-graph, qmd, heartbeat, backups). Compare with: diff {C} {U}. If the differences come only from the template, ask the operator to run ./setup.sh --regenerate --force-claude-md. If you have content of your own, integrate what is new in the template and confirm with: cp {U} {B}`
- **CANON-N4-en**: `- The launcher template changed since the last version you integrated into your workspace CLAUDE.md. Exact changes: diff {B} {U}. Integrate them into {C} and confirm with: cp {U} {B}`
- **CANON-N5-en**: `Do not block the operator's request for this: answer first, unless it depends on your knowledge base. Mention these pending items to the operator once in this session.`

Peor caso (dos deltas + workspace) bajo 2 KB. Los tests comparan contra estos literales; cambiar un texto exige
cambiar el contrato.

## 3. Instalador: `modules/upgrade-notice-install.sh.tpl` → `scripts/hooks/install-upgrade-notice-hook.sh`

- **Uso**: `install-upgrade-notice-hook.sh <settings.json> <comando absoluto del hook>`.
- Mismo molde que `modules/stop-hook-install.sh.tpl`: `set +e`, sale 0 en todo camino, crea `{}` si el archivo
  no existe, merge con `jq` a un temporal y `mv` atómico, `chmod 0644`.
- Toca solo `.hooks.SessionStart`. Agrega `{hooks:[{type:"command",command:$cmd,timeout:10}]}`, sin clave
  `matcher` (así dispara en todos los inicios de sesión, FR-003), si ningún hook
  de `.hooks.SessionStart[].hooks[]` tiene ese `command`. Preserva todo lo demás (otros hooks, permisos,
  plugins, marketplaces).
- Idempotente: N corridas dejan exactamente una entrada con ese comando.

## 4. Puntos de instalación

| Modo | Dónde | Cuándo | Destino |
|---|---|---|---|
| docker | `start_services.sh::pre_install_upgrade_notice_hook`, llamado en `start_session` después de `pre_install_askq_hook` | Boot y cada respawn del watchdog | `$HOME/.claude/settings.json`, comando `/workspace/scripts/hooks/upgrade-notice.sh` |
| local | `local-login.sh.tpl`, paso 4e | Login | `${CONFIG_DIR}/settings.json` |
| local | `setup.sh --regenerate` | Cada regenerate en modo local, solo si `<ws>/.state/.claude/` ya existe (post-login); nunca crea el directorio | `<ws>/.state/.claude/settings.json` |

En docker la función tiene la forma de `pre_install_askq_hook`: si el instalador no es ejecutable (workspace
pre-038) → `return 0`; la invocación lleva `|| true`. No toca `_run_watchdog`.

## 5. Aislamiento de heartbeat

`scripts/heartbeat/heartbeat.sh` agrega `del(.hooks.SessionStart)` al filtro `jq` que ya descarta
`.hooks.Stop` y `.hooks.PreToolUse` (`:151`). Un tick de heartbeat nunca recibe el aviso (FR-004).

## 6. Doctor: `scripts/agentctl::_upgrade_notice_doctor <ws> <vault_root>`

Llamada desde el doctor docker (después de la sección 11) y desde el doctor local. Corre en el host; carga
`<ws>/scripts/lib/{vault,claude_md}.sh`. Si alguna falta (workspace pre-038), imprime una sola línea
`_doctor_skip "Upgrade notice" "workspace predates 038 (run ./setup.sh --regenerate)"` y retorna 0. En docker, `vault_root` = `<ws>/<vault.path>` (default
`.state/.vault`); vacío si `vault.enabled` no es `true`.

| Capa | Condición | Línea |
|---|---|---|
| vault | `vault_root` vacío | `_doctor_skip "Vault schema deltas" "vault disabled"` |
| vault | sin pendientes | `_doctor_pass "Vault schema deltas: all integrated"` |
| vault | pendientes `v1 v2` | `_doctor_warn "Vault schema delta pending integration: v1 v2" "the agent is told at session start; checkpoint per version in <vault>/_templates/schema-updates-<v>.md"` |
| workspace | `in_sync` | `_doctor_pass "Workspace CLAUDE.md: in sync with the current template"` |
| workspace | `customized` | `_doctor_pass "Workspace CLAUDE.md: local edits on the current template"` |
| workspace | `unknown` | `_doctor_skip "Workspace CLAUDE.md" "run ./setup.sh --regenerate to render the current template"` |
| workspace | `pending_no_baseline` | `_doctor_warn "Workspace CLAUDE.md differs from the current template (no baseline)" "diff CLAUDE.md .state/launcher/claude-md.upstream.md; template-only differences: ./setup.sh --regenerate --force-claude-md; own content: merge, then cp .state/launcher/claude-md.upstream.md .state/launcher/claude-md.baseline.md"` |
| workspace | `pending_template` | `_doctor_warn "Workspace CLAUDE.md: the template changed since the last integration" "diff .state/launcher/claude-md.baseline.md .state/launcher/claude-md.upstream.md; merge into CLAUDE.md, then cp .state/launcher/claude-md.upstream.md .state/launcher/claude-md.baseline.md"` |

Las líneas WARN se repiten en cada corrida hasta que el estado cambie. La función nunca falla ni cambia el
código de salida de doctor por sí misma más allá de sumar al contador de WARN.
