# 037 — Discovery B: superficie de configuración, render y tests del subsistema vault/RAG

**Fecha:** 22-09-2026 · **Base:** `main` @ `70214d9`, VERSION `0.26.0` · **Alcance:** solo lectura del repo; nada modificado.

Convención de este informe: todo lo que cita `archivo:línea` fue leído en esta sesión (hecho verificado). Lo marcado **[INFERENCIA]** es deducción no confirmada por ejecución.

---

## 0. Resumen ejecutivo

- El bloque `vault:` de `agent.yml` tiene **14 campos**; solo **7 tienen lector real**. `initial_sources`, `schema.frontmatter_required`, `schema.log_format` y `mcp.server` se escriben en el heredoc pero **nadie los lee** (grep exhaustivo en `setup.sh`, `scripts/`, `modules/`, `docker/`, `tests/`). Son candidatos naturales a reutilizar o retirar en 037.
- Hay **dos patrones de campo** ya establecidos y probados: (a) *persistido* — heredoc + backfill `has()` en `regenerate()` (`features.voice`, `reply_guard`); (b) *derivado en render* — el campo es opcional, NO va al heredoc, el default se computa en `setup.sh` tras `render_load_context` y el placeholder entra a `known_external` (`vault.wiki_graph.*`, `vault.backup_schedule`). Para 037 conviene elegir uno y no mezclar.
- El **único backfill del bloque vault** es `vault.qmd.version` (`setup.sh:2237-2244`) con chequeo de string vacío, no `has()`. Ningún booleano de vault se backfillea; los booleanos ausentes caen a `false` vía `// false`.
- `vault_seed_missing` (`scripts/lib/vault.sh:70-112`) es el ÚNICO mecanismo aditivo para vaults ya poblados: lista explícita de dirs nuevos, copia-si-ausente de templates, un delta `.md` + marcador oculto `.applied` + una línea en `log.md`. **Jamás toca `CLAUDE.md` del vault ni sobreescribe nada.** Un segundo delta (0.27.x) necesita su propio marcador y su propio bloque; el actual está cableado al literal `0.8.0`.
- El `CLAUDE.md` del **workspace** se renderiza UNA vez (`setup.sh:2623-2642`); nuevas secciones en `modules/claude-md.tpl` **no llegan a agentes existentes** sin `--force-claude-md` (destructivo, `ask_yn` default `n`). El canal correcto para instrucciones nuevas al agente sobre el vault es el delta de skeleton, no la plantilla del workspace.
- `wiki_graph.sh` tiene los seis tipos **hardcodeados** (`scripts/lib/wiki_graph.sh:111`); cualquier tipo de página nuevo (p. ej. PARA `project`) se reporta como `type: invalid`. Un cambio de tipos re-baselinea el oráculo exacto de `tests/fixtures/vault-graph` (`wiki-graph.bats:65-85`).
- Drift documentado: el contrato 014 lista `--login` local como trigger de `vault_seed_missing`, pero `modules/local-login.sh.tpl` no llama al vault y `--login` no invoca `regenerate()` (`setup.sh:3308-3327`). Los triggers reales son dos: boot docker y `--regenerate` en modo local.
- Docker: `VAULT_MCP_PATH` está **hardcodeado** a `/home/agent/.vault` (`setup.sh:2446`) mientras `start_services.sh:97-99` sí rebasa `vault.path` custom. Quirk preexistente, documentado en el propio código.

---

## 1. Tabla de campos `vault.*`

Leyenda: **Heredoc** = lo escribe el wizard (`setup.sh:1282-1297`); **Flatten** = variable que produce `render_load_context` (`scripts/lib/render.sh:40-62`: `vault.x.y` → `VAULT_X_Y`; arrays se saltan; un `null` YAML aplana como la cadena `"null"`); **Backfill** = escritura en `regenerate()` cuando falta.

| Campo | Default (fuente) | Heredoc | Dónde se LEE (yq directo) | Dónde se RENDEA / consume (placeholder) | Schema (`scripts/lib/schema.sh`) | Backfill |
|---|---|---|---|---|---|---|
| `vault.enabled` | wizard `y` (`setup.sh:863`) | sí (`:1283`) | `setup.sh:2756,2815`; `start_services.sh:87`; `qmd_index.sh:87`; `wiki_graph.sh:54`; `backup_vault.sh:37`; `heartbeatctl:244,296`; `agentctl:582` | `VAULT_ENABLED` → `claude-md.tpl:184,190,194`; `next-steps.en.tpl:401`; gate de `WIKI_GRAPH_ENABLED` (`setup.sh:2523`) y de units locales de backup (`:2987`) | booleano (`:70`) | NO — ausente = `false` por `// false` |
| `vault.path` | `.state/.vault` (`:1284`) | sí | `setup.sh:2438` (→`LOCAL_VAULT_DIR`), `:1818` (restore); `start_services.sh:90-99` (rebase `/home/agent/<path sin .state/>`); `backup_vault.sh:39` (`vault_resolve_root`) | NO directamente. Docker: `VAULT_MCP_PATH="/home/agent/.vault"` fijo (`setup.sh:2446`); local: `VAULT_MCP_PATH="$LOCAL_VAULT_DIR"` (`:2449`) → `mcp-json.tpl:70`, `claude-md.tpl:185,197` | opcional no-vacío (`:84`) | NO (fallbacks `// ".state/.vault"` en cada lector) |
| `vault.seed_skeleton` | wizard `y` (`:868`) | sí (`:1285`) | `setup.sh:2824`; `start_services.sh:91` | no se rendea | **no validado** (no está en `_SCHEMA_BOOLEANS`) | NO |
| `vault.force_reseed` | `false` (`:1286`) | sí | `setup.sh:2827` (y lo **resetea** a `false` en `:2829`); `start_services.sh:92,109-119` (reset `:116`) | no se rendea | **no validado** | NO (es una mutación runtime de agent.yml: se auto-resetea tras usarse) |
| `vault.initial_sources` | `[]` (`:1287`) | sí | **NINGUNO** | array → saltado por flatten | ninguno | NO |
| `vault.mcp.enabled` | wizard `y` (`:869`) | sí (`:1289`) | — | `VAULT_MCP_ENABLED` → `mcp-json.tpl:67` | booleano (`:71`) | NO |
| `vault.mcp.server` | `vault` (`:1290`) | sí | **NINGUNO** (solo `tests/scaffold.bats:151` lo asserta) | `VAULT_MCP_SERVER` aplana pero ninguna plantilla lo usa | ninguno | NO |
| `vault.qmd.enabled` | wizard `n` (`:870`) | sí (`:1292`) | `setup.sh:2238,2748`; `qmd_index.sh:88` (`_qmd_enabled` exige vault.enabled Y qmd.enabled); `heartbeatctl:284` | `VAULT_QMD_ENABLED` → `mcp-json.tpl:72`, `claude-md.tpl:199`, `next-steps.*`; gates `setup.sh:2780,2960` | booleano (`:72`) | NO |
| `vault.qmd.version` | `"2.5.3"` (`:1293`) | sí | `qmd_index.sh:53` (`qmd_pkg`, default runtime 2.5.3) | `VAULT_QMD_VERSION` aplana pero **ya no lo consume ninguna plantilla** post-016 (`regenerate.bats:110-114`) | opcional no-vacío (`:86`) | **SÍ** — `setup.sh:2237-2244`: solo si `qmd.enabled=true` y version ausente/vacía → escribe `"2.5.3"`. Guard: `qmd-version-guard.bats` |
| `vault.qmd.schedule` | `"*/5 * * * *"` (`:1294`) | sí | `setup.sh:2492` (→ `QMD_TIMER_ONCALENDAR` vía `cron_to_systemd_calendar`, marcador `scripts/heartbeat/qmd-schedule.fallback` `:2500-2512`); `heartbeatctl:285` (línea cron docker) | `VAULT_QMD_SCHEDULE` → `claude-md.tpl:207` | opcional no-vacío (`:87`) | NO |
| `vault.backup_schedule` | `0 * * * *` (`heartbeatctl:245`; OnCalendar `*-*-* *:00:00` `setup.sh:2496`) | **NO** (documentado en `docs/vault.md:120-125`) | `setup.sh:2496`; `heartbeatctl:245` | derivado `BACKUP_TIMER_ONCALENDAR` (known_external) → `local-vault-backup.timer.tpl` | opcional no-vacío (`:85`) | NO |
| `vault.wiki_graph.enabled` | derivado: `true` si `vault.enabled` y no es literalmente `false` (`setup.sh:2521-2527`; `wiki_graph.sh:49-61`; `heartbeatctl:297`) | **NO** | los tres anteriores | derivado `WIKI_GRAPH_ENABLED` (known_external) → `claude-md.tpl:213`, `next-steps.*`, gates `setup.sh:2760,3011` | booleano (`:73`) | NO (default computado, nunca persistido) |
| `vault.wiki_graph.schedule` | `20 */6 * * *` (`setup.sh:2528-2529`; `heartbeatctl:298`) | **NO** | `setup.sh:2528`; `heartbeatctl:298` | derivados `WIKI_GRAPH_SCHEDULE` (→ `claude-md.tpl:216`) y `WIKI_GRAPH_TIMER_ONCALENDAR` (→ timer local); marcador `wiki-graph-schedule.fallback` (`:2533-2545`) | opcional no-vacío (`:88`) | NO |
| `vault.schema.frontmatter_required` | `true` (`:1296`) | sí | **NINGUNO** | `VAULT_SCHEMA_FRONTMATTER_REQUIRED` aplana, sin consumidor | ninguno | NO |
| `vault.schema.log_format` | `"## [{date}] {op} \| {title}"` (`:1297`) | sí | **NINGUNO** (el formato real está hardcodeado en `vault.sh:152` y `:105`) | sin consumidor | ninguno | NO |

Notas verificadas:

- `modules/docker-compose.yml.tpl` **no tiene nada de vault**: el único match es el build-arg `QMD_NATIVE_TOOLCHAIN` (`:22-26`). El vault llega al contenedor por el bind-mount `.state → /home/agent`, no por volumen ni env propio.
- Los placeholders precomputados por modo existen porque el motor de render **no soporta un `{{#if}}` de modo anidado dentro de `{{#if VAULT_*}}`** (`setup.sh:2439-2480`): `VAULT_MCP_PATH`, `GCAL_CREDS_PATH`, `QMD_MCP_ENV`, `QMD_MCP_COMMAND`. Cualquier valor nuevo dependiente del modo sigue ese molde.
- Fixtures: `tests/fixtures/sample-agent-with-vault.yml:75-90` trae el bloque completo del heredoc (sin `backup_schedule` ni `wiki_graph`); `sample-agent.yml:62-67` trae un bloque mínimo con `backup_schedule` y sin `mcp`/`qmd`/`schema`.

---

## 2. Touchpoints exactos por tipo de cambio

### 2.1 Agregar un campo `vault.<nuevo>` a `agent.yml`

| # | Touchpoint | Archivo:línea | Qué hacer | Si se omite |
|---|---|---|---|---|
| 1 | Heredoc del wizard | `setup.sh:1282-1297` | escribir la clave con su default para scaffolds nuevos (si el campo es *persistido*) | scaffolds frescos sin la clave; el backfill la escribe en el primer `--regenerate` |
| 2 | Backfill en `regenerate()` | `setup.sh:2204-2372` (bloque `[ -f "$agent_yml" ]`, **antes** de `render_load_context` `:2374`) | patrón `has()`: `if [ "$(yq -r '(.vault \| has("x")) // false' …)" != "true" ]; then yq -i '.vault.x = …'` (moldes `:2281`, `:2309`, `:2324`, `:2335`, `:2358`). **Nunca `//`** para booleanos (colapsa `false` a ausente). Segunda pasada debe ser byte-estable | agentes existentes sin la clave; `--regenerate` no determinista |
| 3 | Validación de forma | `scripts/lib/schema.sh:65-74` (`_SCHEMA_BOOLEANS`) / `:81-89` (`_SCHEMA_OPTIONAL_NONEMPTY`) | agregar la ruta; sumar casos en `tests/schema-validate.bats` (moldes `:192-272`) | typos `ture`/vacío pasan silenciosos |
| 4 | Fixture + lista exacta de sub-claves | `tests/fixtures/sample-agent-with-vault.yml:75-90` **y** `tests/schema.bats:38-49` (compara `keys` del fixture contra una lista fija `enabled force_reseed initial_sources mcp path qmd schema seed_skeleton`) | agregar la clave en AMBOS | `schema.bats` rojo |
| 5 | Placeholder derivado (si el valor se computa en `setup.sh` en vez de aplanar) | `tests/schema.bats:62-83` (`{{VAR}}`) y `:129-139` (`{{#if VAR}}`) | agregar a `known_external` con comentario de por qué es externo | `schema.bats` lo marca como drift |
| 6 | Sanitización de texto libre | molde `voice_phrase_effective` (`setup.sh:2409-2418`): leer del **valor crudo** `yq -r '… // ""'`, nunca del `FEATURES_*`/`VAULT_*` aplanado (`null` → `"null"`) | — | valores basura llegan al artefacto |
| 7 | Prompt interactivo (solo si se pregunta en el wizard) | `setup.sh:857-872` (bloque 7.5, gateado en `vault_enabled`) | ver 2.4 | — |
| 8 | Docs | `docs/vault.md:104-125` (ejemplo YAML y "dos claves opcionales"), `docs/state-layout.md:88-160`, `README.md`, `CHANGELOG.md`, `VERSION` | — | gate de documentación de la constitución |

### 2.2 Agregar placeholders / secciones a plantillas existentes

- **`modules/claude-md.tpl`** (secciones vault `:184-198`, QMD `:199-212`, wiki-graph `:213-223`): se rendea **solo** si el archivo falta, con `--force-claude-md` (pregunta destructiva default `n`, `setup.sh:2628-2634`) o en modo local cuando el `CLAUDE.md` es el del launcher (`:2638`). **Consecuencia:** la flota actual (donna/linus/rodri-cenco-admin) no recibe secciones nuevas por `--regenerate`. Tests que grepean `CLAUDE.md`: `scaffold.bats:158-159`, `regenerate.bats:93-101`.
- **`modules/mcp-json.tpl`**: bloques `{{#if VAULT_MCP_ENABLED}}`/`{{#if VAULT_QMD_ENABLED}}` (`:67-77`) con placeholders por modo precomputados. Tests: `tests/mcp-json.bats:154-332` (9 tests vault/qmd), `scaffold.bats:139,154-157,173-174`, `docker-e2e-vault.bats:150-157`.
- **`modules/next-steps.{en,es}.tpl`** (`en:387-420`, `es:395-428`): bloques gateados por `VAULT_QMD_ENABLED`/`VAULT_ENABLED`/`WIKI_GRAPH_ENABLED`; asserts en `scaffold.bats:208-244`. Se rendea en local por `--regenerate` (027 US4) y en el wizard; en docker solo en el wizard.
- Regla del motor: `{{#if}}` testea la cadena literal `"true"`, no no-vacío (`render.sh:66-70`).

### 2.3 Plantillas / artefactos nuevos (units locales, wrappers, libs image-baked)

| Pieza | Dónde engancharla | Tests existentes que sirven de molde |
|---|---|---|
| Wrapper local `modules/local-<x>.sh.tpl` | render en `regenerate()` rama local `setup.sh:2743-2765` (gateado por yq/`VAULT_*`); `chmod +x` `:2764` | `local-wiki-graph.bats` (stub de la lib que registra el env; `render_to_file` directo del template) |
| Units `.service/.timer` | staging-si-no-sudo en `install_service` `setup.sh:2955-3030`; instalación diferida en `modules/local-login.sh.tpl:186-210`; lista de units para `--uninstall` `setup.sh:3154` | `local-qmd.bats:121-141`, `local-vault-backup.bats:106` |
| Cron docker | `docker/scripts/heartbeatctl:238-300` (`_yq` + línea cron; moldes backup `:243-247`, qmd `:283-287`, wiki-graph `:295-300`) y despacho `:1054-1057` | `qmd-reindex-cmd.bats:34-57`, `backup-vault-cmd.bats:58-84` |
| Lib compartida `scripts/lib/<x>.sh` | espejo a `docker/scripts/lib/` en `mirror_catalog_to_docker` `setup.sh:1621-1735` (+ punch-list `:1701-1726`) **y** `COPY` en `docker/Dockerfile:258-290`; guard `BASH_SOURCE`-style sin side effects | `docker-render.bats:333-344`, `scaffold.bats:177-200` (byte-idéntico) |
| Surface `agentctl status/doctor` | `scripts/agentctl:580-590` (doctor docker vault), `:1105-1145` (`_local_vault_qmd_status`) | `agentctl-local.bats` |
| Estado runtime | SIEMPRE bajo `scripts/heartbeat/<x>.json` (nunca dentro del vault: Syncthing; `wiki_graph.sh:77-86`) o `.state/` | `local-wiki-graph.bats:70` |

Todo lo que toque `docker/` exige **DOCKER_E2E** (constitución, gate de tests) y revisión contra el Principio II.

### 2.4 Nuevo prompt de wizard (solo si 037 pregunta algo)

Los tres puntos de la memoria `wizard-prompt-test-touchpoints` siguen vigentes, verificados:

1. `tests/helper.bash::wizard_answers` `:215-221`: el bloque vault emite `y y y` + `y|n` (qmd) o un solo `n`. Solo modela `vault=on|off` y `qmd=on|off`; `mcp` siempre `y`.
2. **Stdin a mano**: `tests/e2e-smoke.bats:52-65` — el array **no incluye** las respuestas de vault; depende del fallback EOF→default de `ask_yn` (`scripts/lib/wizard.sh:38-39`: `answer="${answer:-$default}"`), o sea ese scaffold nace con vault `y/y/y`, qmd `n`. Un prompt nuevo con `ask_yn` y default seguro se tolera; un `ask_choice` cuelga la suite (hallazgo 011). `tests/scaffold.bats:39-63` (heredoc `--in-place`): la línea `n` antes de `proceed` es "vault disabled".
3. `tests/schema.bats` `known_external` (2.1 #5).

### 2.5 Nuevos deltas de skeleton (vaults ya poblados)

Ver §3. Touchpoints: `modules/vault-skeleton/**` (seed fresco), `modules/vault-deltas/schema-updates-<ver>.md` (nuevo delta), `scripts/lib/vault.sh::vault_seed_missing` (nuevo bloque + marcador `_templates/.schema-updates-<ver>.applied`), espejo docker automático por `COPY modules/vault-deltas/` (`Dockerfile:290`) y `setup.sh:1676-1678`, `RUN test` de sanidad `Dockerfile:304-305`, tests `vault.bats` (lista fija de templates `:36-40`, seis subdirs `:30-34`, seis headers de `index.md` `:59-65`), `vault-upgrade.bats`, y si cambian tipos de página: `wiki_graph.sh:111` + `wiki-graph.bats` + `tests/fixtures/vault-graph` + `docs/state-layout.md:104-135`.

---

## 3. Contrato de `modules/vault-deltas` y `vault_seed_missing`

Fuente: `scripts/lib/vault.sh:52-112` y `specs/014-wiki-graph-rag/contracts/vault-additive-upgrade.md`.

**Firma:** `vault_seed_missing TARGET SKELETON DELTAS [TODAY]`. Siempre `return 0` (fail-silent, Principio IV).

**Orden de ejecución en el orquestador** (ambos triggers): `vault_ensure_paths` → (`force_reseed` ? `vault_backup_and_reseed` : `vault_seed_if_empty`) → `vault_seed_missing`.

| Paso | Qué hace hoy | Regla dura |
|---|---|---|
| 0 | No-op si TARGET vacío/ausente (`:74`) — ese camino es `vault_seed_if_empty` | — |
| 1 | Crea `wiki/normalization/` + `.gitkeep` si falta (`:80-85`) | **lista explícita**, nunca un walk del skeleton (resucitaría dirs borrados a propósito) |
| 2 | Copia `_templates/normalization.md` desde SKELETON si falta (`:87-90`) | nunca sobreescribe |
| 3 | Si no existe el marcador oculto `_templates/.schema-updates-0.8.0.applied`: copia `DELTAS/schema-updates-0.8.0.md` a `_templates/`, toca el marcador, agrega `## [fecha] upgrade \| schema updates 0.8.0 — read … and integrate into CLAUDE.md` a `log.md` (`:93-109`) | el sentinel es el **marcador**, no el `.md` (el agente puede borrar el delta tras integrarlo; el boot docker corre esto en CADA arranque) |
| 3b | Guard de scaffold fresco: deposita el delta solo si `changed=1` (algo faltaba) **o** `wiki/` ya tiene páginas `.md` (`:96-100`) | un vault recién sembrado no recibe delta ni línea de log |

**Qué SÍ se puede agregar aditivamente a un vault poblado:**

- Directorios nuevos (con `.gitkeep`), templates nuevos bajo `_templates/`, archivos nuevos en rutas que no existen.
- Un documento delta nuevo (`schema-updates-<ver>.md`) con instrucciones para que **el agente** integre las secciones en SU `CLAUDE.md` e `index.md`.
- Una línea al final de `log.md` (append-only, `:105-106`).

**Qué NO se puede hacer (y no hay mecanismo para ello):**

- Modificar `TARGET/CLAUDE.md` (capa 3 co-evolucionada) — test `vault-upgrade.bats:37-45` lo fija byte a byte.
- Editar `index.md` (agregar un header `## Projects`, por ejemplo), reescribir templates existentes, tocar `wiki/**` o `raw_sources/**`. El único camino a "pristine" es `force_reseed` (mueve todo a `<vault>.backup-<ts>` y resiembra; `vault.sh:126-141`, `docs/vault.md:648-695`).
- Escribir `.md` dentro de `.graph/` (invariante L1 JSON-only, `wiki-graph.bats:142`).

**Para un segundo delta (037):** el bloque actual está cableado a literales (`0.8.0`, `normalization`). Hay que agregar un bloque paralelo con su propia lista de dirs/templates, su propio `changed`, su propio marcador `.schema-updates-<ver>.applied` y su propio texto de log; el guard de scaffold fresco se cumple solo con `has_pages` para vaults reales. **[INFERENCIA]** reutilizar la misma variable `changed` entre versiones haría que un vault 0.8.0-completo con wiki vacía deposite el delta nuevo solo si el bloque nuevo creó algo — lo cual es el comportamiento deseado, pero conviene un test explícito.

**Triggers reales (verificados):**

| Contexto | Punto | Nota |
|---|---|---|
| Boot docker | `docker/scripts/start_services.sh:132-134` (dentro de `seed_vault_if_needed`, solo si `seed_skeleton=true` `:108`) | cada arranque, como `agent` |
| Host `--regenerate` **modo local** | `setup.sh:2840-2843` (`_seed_vault_local`, llamada única en `:2768` dentro de la rama `DEPLOYMENT_MODE_IS_DOCKER != true` `:2723`) | también en scaffold |
| Docker `--regenerate` | **no toca el vault** (host-side no hay seed; lo hace el boot) | — |
| Local `--login` | **NO** implementado: `modules/local-login.sh.tpl` no llama a `vault_seed*` (grep vacío) y `--login` ejecuta solo el helper (`setup.sh:3308-3327`). Drift respecto a `vault-additive-upgrade.md:60` | — |

Un detalle de `vault_seed_missing` que importa para 037: si `seed_skeleton=false`, en docker el bloque completo (incluido el upgrade aditivo) no corre (`start_services.sh:108`); en local igual (`setup.sh:2824` retorna antes).

---

## 4. Tests por área y patrones

### 4.1 Inventario

| Área | Archivo (tests) | Patrón/seam |
|---|---|---|
| Skeleton + lib `vault.sh` | `vault.bats` (24), `vault-upgrade.bats` (10) | `load_lib vault`; `setup_tmp_dir`; `SKELETON="$REPO_ROOT/modules/vault-skeleton"`; fixture `tests/fixtures/vault-populated` (vault **pre-014**: sin `normalization/`) copiada a `$TMP_TEST_DIR`; hash `find -exec shasum` antes/después; `run f; [ $status -eq 0 ]` |
| Seed local + regenerate | `local-vault-seed.bats` (7) | copia `scripts/ modules/ setup.sh VERSION` a `$TMP_TEST_DIR`, `touch .env`, `mkdir .state`, `install_claude_stub` en `deployment.claude_cli`, agent.yml mínimo por heredoc `_seed`, `echo 'n' \| ./setup.sh --regenerate` |
| Regenerate/backfill | `regenerate.bats` (vault `:93-120`, backfill mirror `:129-146`) | igual al anterior; asserta `yq -r` sobre agent.yml y `jq` sobre `.mcp.json` |
| Render | `mcp-json.bats` (9 vault/qmd), `docker-render.bats:333-344`, `local-render.bats`, `modules-render.bats`, `schema.bats` (5), `schema-validate.bats` (34, vault `:192-272`) | `load_lib render`; `render_load_context` + `render_to_file` directos; `known_external` |
| Wizard | `scaffold.bats:133-244`, `e2e-smoke.bats`, `quickstart-doc.bats` | `wizard_answers vault=on qmd=on \| ./setup.sh --destination` |
| QMD | `qmd-index` (11), `qmd-setup` (8), `qmd-invocation` (8), `qmd-reindex-cmd` (10), `qmd-embed-completion` (13), `qmd-sqlite-vec` (7), `qmd-version-guard` (3), `qmd-watch` (4), `local-qmd` (15), `start-services-qmd` (4) | seam 019: `install_qmd_stub`/`install_qmd_stub_fail` (`helper.bash:79-118`) plantan un `qmd` falso en el prefijo gestionado + `.installed-hash` + `bun` no-op; env `HOME`, `QMD_CACHE_HOME`, `QMD_VAULT_DIR`, `QMD_INDEX_STATE_FILE`, `QMD_STUB_LOG` bajo tmp; `source scripts/lib/qmd_index.sh` |
| Wiki-graph | `wiki-graph.bats` (19), `local-wiki-graph.bats` (7) | fixture-oráculo `tests/fixtures/vault-graph` con **conteos exactos** de findings; env `WIKI_GRAPH_VAULT_DIR/STATE_FILE/LOCK`; asserts `flock` se saltan en macOS; wrapper local testeado con una `wiki_graph.sh` **stub** que registra el env recibido |
| Backup vault | `backup-vault-lib` (12), `backup-vault-cmd` (8), `backup-vault-git` (7), `local-vault-backup` (8) | repo git bare local como fork; `VAULT_ROOT_OVERRIDE`; `VAULT_BACKUP_CACHE_DIR` |
| heartbeatctl (cron) | `heartbeatctl.bats` + los `*-cmd.bats` | `HEARTBEATCTL_WORKSPACE`/`_CRONTAB_FILE`/`_LIB_DIR` apuntan a tmp |
| Docker e2e (gated) | `docker-e2e-vault.bats` (2), `docker-e2e-qmd.bats` (2) | `DOCKER_E2E=1`; agent.yml escrito a mano; `--regenerate --non-interactive`; stub `claude` bind-montado a `/usr/local/bin/claude`; `docker compose exec -T -u agent`; corre en CI solo nightly (`.github/workflows/docker-e2e.yml:60`) |

### 4.2 Convenciones que un test nuevo debe respetar (verificadas en `helper.bash` y CLAUDE.md raíz)

- `load helper`; `setup(){ setup_tmp_dir; … }`; `teardown(){ teardown_tmp_dir; }`. `AGENTIC_VERSIONS_OFFLINE=1` viene por defecto (`helper.bash:11`).
- Nunca depender de `claude`/`bun` del host: `install_claude_stub` (path absoluto en `deployment.claude_cli`), `install_bun_stub`, `install_qmd_stub`.
- Negativos: un `! grep -q` o `[[ ]]` intermedio **no falla** en bats; ir al final o usar `run …; [ "$status" -ne 0 ]` (regla del repo).
- `PRODUCER | grep -q` bajo `pipefail` es una carrera; leer a variable y decidir con `case`.
- Payloads grandes van por archivo, no por `argv`/env (límite 128 KiB por string en Linux CI).
- Suite debe pasar en bash 3.2 y 5.x (matriz CI); nada de `declare -A`, `mapfile`, `${x,,}`.
- Estado de runtime de un runner nuevo: bajo `scripts/heartbeat/`, atómico (tmp+mv), `flock` fuera del vault.

---

## 5. Restricciones de la constitución que aplican (`.specify/memory/constitution.md` v1.0.1)

| Principio | Implicación concreta para 037 |
|---|---|
| **I. agent.yml fuente única** (`:67-86`) | cada campo nuevo se lee de agent.yml y sobrevive `--regenerate`; los derivados se rendean por `render.sh` + `modules/*.tpl`; mutaciones runtime escriben agent.yml primero (molde `force_reseed` reset, `heartbeatctl set-*`). Gate "regenerate-safety" (`:203-205`): dos pasadas byte-idénticas |
| **II. Contenedor de mínimo privilegio** (`:88-104`) | solo si se toca `docker/`; el vault ya entra por bind-mount, sin volúmenes ni caps nuevas. Un runner nuevo corre como `agent` (`start_services.sh` sección de boot) |
| **III. Test-first, host-runnable** (`:106-122`) | bats en `tests/` antes de la implementación; suite por defecto sin Docker; e2e detrás de `DOCKER_E2E=1`; libs con guard de `BASH_SOURCE`; `shellcheck -S error` limpio |
| **IV. Idempotente, fail-silent** (`:124-139`) | seeds/upgrades con sentinel o hash (nunca mtime); runners `exit 0` siempre, verdad en el state file (molde `wiki_graph_run`); notifiers/cron nunca rompen el boot |
| **V. Workspace-is-the-agent** (`:141-159`) | todo estado nuevo bajo `.state/` (vault, caches) o `scripts/heartbeat/` (state/locks); jamás commitear ni loguear `.state/`; backup: **no** fusionar primitivas; preservar `--restore-from-fork` (orden config → identity → vault). Un artefacto nuevo dentro del vault que no sea `.md` **no viaja** en `backup/vault` (`backup_vault.sh:93` filtra `*.md`) ni lo indexa qmd (`qmd_index.sh:379`, máscara `**/*.md`) |
| **VI. Pins deliberados** (`:161-182`) | no duplicar literales (`2.5.3`, `0.12.0` de MCPVault están single-sourced/guardados por test); `CHANGELOG.md` + `VERSION`; `meta.launcher_version` lo actualiza `regenerate()` |

Gate de documentación (`:211-212`): `docs/vault.md` y `docs/state-layout.md` son las referencias que cambian.

---

## 6. Hallazgos que 037 debe decidir o absorber

1. **Cuatro campos muertos** (`initial_sources`, `mcp.server`, `schema.frontmatter_required`, `schema.log_format`): o se les da lector en 037 o se dejan como están (retirarlos rompe `schema.bats:43` y la lista fija; es cambio aparte).
2. **`seed_skeleton` y `force_reseed` no están en `_SCHEMA_BOOLEANS`**: un typo pasa silencioso. Sumarlos cuesta dos líneas + dos tests.
3. **`CLAUDE.md` del workspace no se refresca**: el protocolo CODE/PARA/reviews para el agente debe viajar en el `CLAUDE.md` del **vault** (skeleton, para nuevos) + delta `schema-updates-<ver>.md` (para poblados). Cualquier sección nueva en `claude-md.tpl` es solo para scaffolds nuevos o `--force-claude-md`.
4. **Tipos de página hardcodeados** en `wiki_graph.sh:111` (`VALIDTYPE`) y en `vault.bats:30-40,59-65`. Si 037 introduce tipos PARA (`project`, `area`, `resource`, `archive`) o "intermediate packet", hay que extender la lista, la fixture-oráculo `vault-graph` (conteos exactos en `wiki-graph.bats:65-85`), `index.md` del skeleton y `docs/state-layout.md:104-135`. Alternativa sin tocar el linter: modelar PARA como `tags`/`status`/carpetas fuera de `wiki/` **[INFERENCIA de diseño, no verificada]**.
5. **`index_drift`** se calcula sobre bullets `- [[type/slug]]` en cualquier sección de `index.md` (`wiki_graph.sh:399-425`): secciones nuevas en `index.md` no rompen el linter, pero solo llegan a vaults nuevos (los poblados requieren que el agente las agregue).
6. **Fixture `vault-populated` es pre-014**: un test de "delta v2 sobre vault 0.8.0-completo" necesita una fixture nueva o sembrar con `vault_seed_if_empty` + páginas.
7. **Docker `VAULT_MCP_PATH` fijo** (`setup.sh:2446`) vs rebase real de `vault.path` en `start_services.sh:97-99`: con `vault.path` custom en docker, el MCP `vault` apunta al directorio equivocado. Preexistente; no ampliar la superficie de `vault.path` sin cerrar esto.
8. **`--login` local no corre el upgrade aditivo** (drift contra el contrato 014). Si 037 depende de que un vault local se actualice, el trigger es `--regenerate`.
9. **Wizard**: 037 sin prompt nuevo evita tocar `wizard_answers`, `e2e-smoke.bats` y `scaffold.bats`. Si se agrega prompt, el bloque vault (`setup.sh:867-871`) es el lugar, con `ask_yn` (nunca `ask_choice`) y default seguro.
10. **Programaciones cron**: cualquier tarea periódica nueva (p. ej. review semanal/mensual) necesita tres entregas coherentes: línea cron en `heartbeatctl` (docker), timer local vía `cron_to_systemd_calendar` (`scripts/lib/local_schedule.sh:27`, solo formas `*/N`, `M * * * *`, `M */N * * *`, `M H * * *`; el resto cae al default con marcador `.fallback`), y línea en `claude-md.tpl`/`next-steps`. Un cron semanal (`0 9 * * 1`) **no es convertible** hoy (`local_schedule.sh:44-47` exige `dow=*`) → caería al default con WARN. Esto es una restricción real para "weekly review" en modo local.

---

## 7. Referencias leídas

`setup.sh` (`:857-885`, `:1270-1310`, `:1621-1735`, `:2195-2545`, `:2596-2850`, `:2950-3035`, `:3288-3342`); `scripts/lib/{schema,vault,render,qmd_index,wiki_graph,backup_vault,local_schedule}.sh`; `docker/scripts/start_services.sh:26-190`; `docker/scripts/heartbeatctl:238-300,1001-1060`; `docker/Dockerfile:244-305`; `modules/{mcp-json,claude-md,docker-compose.yml,next-steps.en}.tpl`; `modules/vault-deltas/schema-updates-0.8.0.md`; `modules/vault-skeleton/**`; `modules/local-login.sh.tpl`; `scripts/agentctl:580-590,1105-1145`; `tests/helper.bash`; `tests/{vault,vault-upgrade,local-vault-seed,wiki-graph,local-wiki-graph,qmd-index,schema,schema-validate,scaffold,e2e-smoke,regenerate,docker-e2e-vault,docker-e2e-qmd,mcp-json}.bats`; `tests/fixtures/sample-agent{,-with-vault}.yml`, `vault-graph/`, `vault-populated/`; `.specify/memory/constitution.md`; `specs/014-wiki-graph-rag/contracts/vault-additive-upgrade.md`; `specs/010-self-managing-rag/contracts/agent-yml-schema.md`; `docs/vault.md:83-172,648-717`; `docs/state-layout.md`; `.gitignore`; memoria `wizard-prompt-test-touchpoints.md`.

