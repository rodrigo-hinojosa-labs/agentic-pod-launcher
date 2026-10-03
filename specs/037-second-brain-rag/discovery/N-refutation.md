# N — Refutación técnica de tasks.md y contratos (037)

**Fecha**: 2026-09-27 | **Árbol**: rama `037-second-brain-rag`, código idéntico a `main` @ `70214d9` | **Método**: lectura del código con `archivo:línea`, mediciones puntuales en host (bash 3.2.57 y 5.3.15, jq 1.7.1) y en la imagen `agentic-pod:latest` (BusyBox 1.37.0, jq 1.8.1). Ninguna suite completa ejecutada; ningún archivo del repo modificado salvo este informe.

Leyenda: **CONFIRMADO** (el código soporta la afirmación tal como está escrita), **REFUTADO** (la tarea o el contrato no se puede implementar o su oráculo falla tal como está escrito), **PARCIAL** (implementable, pero el texto omite una condición necesaria o cita algo incorrecto).

## Resumen ejecutivo

Refutado (cambia tareas o contratos):

1. **Crontab byte-idéntico con `review.enabled: false`** (T035/T036, contrato heartbeat §2.2/§6). Agregar `${review_line}` como octava línea del heredoc `heartbeatctl:304-313` agrega una línea EN BLANCO cuando está deshabilitado: el crontab deja de ser byte-idéntico al golden pre-037. La variable debe llevar su propio salto de línea inicial y concatenarse a la línea de wiki-graph.
2. **`%` en busybox crond** (contrato heartbeat §2.3, research K4). Medido en la imagen: `echo a%b` produce `a%b` literal; `$(echo sub)` expande. La justificación del archivo `review-prompt.txt` es falsa en su premisa; el archivo sigue siendo la decisión correcta por las comillas, el largo (hasta 4000 chars) y el `heartbeat.conf`-molde, no por `%`.
3. **`vault_resolve_root` no vive en `vault.sh`** (contrato heartbeat §2.3, T036): está en `scripts/lib/backup_vault.sh:26`; `heartbeatctl` ya la sourcea (`:35-40`, con fallback relocated para bats).
4. **DOCKER_E2E de vault en T037**: el arnés siembra un skeleton FRESCO (`docker-e2e-vault.bats:44-47`, `seed_skeleton: true`, vault ausente). Con el skeleton 037 las plantillas nuevas ya existen (`changed27=0`) y la wiki está vacía (`has_pages=0`), así que el guard fresh-scaffold impide el delta. El oráculo "el boot deposita el delta 0.27.0 con marcador" es falso en ese arnés; el precedente `docker-e2e-qmd.bats:249-252` asserta exactamente lo contrario (`NO_DELTA`). Hay que pre-sembrar un vault pre-037 en `.state/.vault` para probar el depósito.
5. **`has_pages` es una carrera SIGPIPE bajo `pipefail`** (`vault.sh:97`: `find | head -1 | grep -q .`). `start_services.sh:14` corre `set -euo pipefail` y llama `vault_seed_missing` en `:133`. Medido: con 3000 páginas, `has_pages` evalúa FALSE **200/200** en bash 3.2.57 y 5.3.15; TRUE 200/200 con 5 páginas o sin pipefail. T008 dice copiar el molde para el bloque 0.27.0: no hacerlo. `[ -n "$(find … -print -quit)" ]` da TRUE 200/200.
6. **Sentinel de layout en `_qmd_setup_locked`** (contrato qmd §2 fila 1, T015). "Tras `:397`" cae en el camino común de AMBAS ramas, incluida la re-entrante `:383-385` (índice presente, `.qmd-setup-ok` ausente) donde NO se hizo `collection add`: un índice heredado quedaría marcado `wiki-root` sin haber migrado. El sentinel debe escribirse solo tras un `collection add` exitoso.
7. **`wiki_graph_run` sin agent.yml no corre en host** (T002, quickstart §2.1-2.3). Sin argumento usa `/workspace/agent.yml` (`wiki_graph.sh:268`), que no existe en el host → `wiki_graph_enabled` retorna 1 → `disabled — skip` (medido: rc=0, sin `.graph/`). El golden de T002 no se puede generar con el comando escrito.
8. **F1-F4 sobre valores vacíos** (contrato graph §2, oráculo vault-schema §5). El contrato no exime el valor vacío; las plantillas traen `due: ""`, `next_review: ""`, `created: ""` y el oráculo "plantilla sembrada parsea sin violación" caería por `due: malformed ''`. Molde correcto: `status` en `:174` (`v != "" && inválido`).
9. **Fixture (b) `vault-0.8.0-empty` con marcador 0.8.0** (T003) hace inmatable la mutación M10 y no representa el estado real de la flota (un agente sembrado post-014 con wiki vacía NO tiene marcador, por el propio guard). La fixture debe ser "skeleton pre-037, sin marcador ni delta 0.8.0, wiki vacía".
10. **`--migrate --dry-run` local dispararía el setup real** (T016): `local-qmd-reindex.sh.tpl:51` corre `qmd_setup_if_needed` ANTES del dispatch de flags `:52-54`. En un workspace sin índice, un dry-run descargaría el modelo. Despachar `--migrate` antes de `:51`.
11. **Contradicción data-model §9 vs contrato agent-yml §1** sobre `known_external`: el data-model dice que los seis `{{VAR}}` entran; el contrato dice que no cambia. El código (`schema.bats:52-117`) solo verifica placeholder → producido, sin chequeo inverso: el contrato tiene razón, el data-model está caduco.
12. **Paralelismo**: T043 `[P]` edita `docs/vault.md`, también editado por T017 y T032.

Confirmado (implementable tal como está): la extensión posicional de `N`/jq (1a), `SRCN` + `_wg_compute_stale` (1b), `--rawfile`/`--arg` adicionales y jq `strptime`/`mktime` en host e imagen (1d), lectura de `agent.yml` por el runner en ambos modos (1e), escrituras atómicas adicionales (1f), skeleton limpio en 0 con secciones comentadas y plantillas fuera de `wiki/` (1g), gating del bloque 0.27.0 sin disparar el 0.8.0 (2, con la salvedad de `has_pages`), cambio de máscara sin romper los tests qmd actuales (3), `heartbeatctl.bats` sin golden ni conteo exacto (4), `heartbeat.sh` parsea `--trigger`/`--prompt` y honra `HEARTBEAT_TRIGGER` (4), `agentctl` extensible sin cambiar exit codes (5), backfills `has()` dentro del `if [ -f agent.yml ]` no gateado por vault (6), `schema.sh` acepta rutas anidadas (6), lista de `schema.bats:43` (6).

---

## 1. `scripts/lib/wiki_graph.sh`

### 1(a) Record `N` y destructuring jq posicionales — CONFIRMADO

- `wiki_graph.sh:170`: `print "N\t" curid "\t" ftype "\t" fstatus "\t" fcreated "\t" fupdated "\t" title_present;`
- `wiki_graph.sh:506`: `{id:.[1], type:.[2], status:.[3], created:.[4], updated:.[5], title_present:(.[6]=="1")}`.
- Anexar 13 columnas tras `title_present` (índices `.[7]..[19]`) no toca `.[6]`. El riesgo K-4 (desfase silencioso) es real; el oráculo de T009 "type/status de todos los nodos iguales al golden" lo cubre.
- Detalle no cubierto: `description` es texto libre y viaja en un TSV. Un tabulador dentro del valor desplaza las columnas en silencio. Recomendación: `gsub(/\t/, " ", v)` en awk para `description`, `goal`, `next_action` antes de imprimir el record.

### 1(b) `SRCN` con columna `para` — CONFIRMADO

- `wiki_graph.sh:178`: `print "SRCN\t" curid "\t" fstatus "\t" fupdated;`
- `wiki_graph.sh:438`: `read -r _tag id status updated` — agregar `para` como quinto campo y `[ "$para" = "archive" ] && continue` junto a `:439` funciona sin tocar el resto. Alternativa jq en `:512` también viable (filtrar `$staleset` contra `$nodes`).

### 1(c) Parser de arrays: flujo y guiones — PARCIAL

- `parse_flow` `:134-143` sirve para `problems: [fp-1, fp-2]` y `tags: [demo]` (la fixture 014 `alpha.md:9` tiene `tags: [demo]`, confirmado).
- La rama de continuación por guiones `:195-201` SOLO trata `related`, `sources`, `aliases`. Un `tags:` o `problems:` en forma de guiones entra a `:195` con `curkey` correcto y cae por ninguna rama: se descarta en silencio, sin violación. **Hay que extender explícitamente `:195-201`** con `problems` y `tags` (T010 dice "arrays con parse_flow y guiones" pero solo cita `:206-225`; el contrato §2 no menciona `:195-201`).
- `project`/`area` con `unwrap(unquote(rest))` (molde `entity` `:213`) — CONFIRMADO.

### 1(d) `_wg_aggregate` y jq — CONFIRMADO

- `_wg_aggregate` `:495-501` es una invocación `jq -n -R` con cuatro `--rawfile`; agregar `--rawfile raw`, `--rawfile log`, `--arg today`, `--arg delta_date`, `--arg integrated` es trivial. Ojo: la firma posicional `_wg_aggregate records idx allwiki stale vault_dir` (`:496`) también hay que extenderla en su único call site `:353`.
- jq host: `jq-1.7.1-apple`, `("2026-09-26"|strptime("%Y-%m-%d")|mktime) - ("2026-09-01"|…)` = **25** días (medido). Imagen: `jq-1.8.1`, mismo resultado **25** (medido dentro de `agentic-pod:latest`). `jq` está en `/usr/bin/jq` (Dockerfile `:36`).

### 1(e) Acceso a `agent.yml` desde el runner — CONFIRMADO

- Docker: `heartbeatctl:1017` `wiki_graph_run "$AGENT_YML"` con `AGENT_YML="$WORKSPACE/agent.yml"` (`:10`).
- Local: `modules/local-wiki-graph.sh.tpl:12,38` `AGENT_YML="${WORKSPACE}/agent.yml"` → `wiki_graph_run "$AGENT_YML"`.
- El parámetro llega a `_wg_run_locked "$agent_yml" "$vault_dir"` (`:280`, `:292`), donde hoy no se usa más; leer `.vault.review.*` con yq ahí (molde `wiki_graph_enabled` `:49-60`) es directo.
- Tests: `wiki-graph.bats:16-19` escribe `vault: {enabled: true, wiki_graph: {enabled: true}}` → las claves nuevas ausentes → defaults. Compatible.
- **Consecuencia para T002 y quickstart §2.1-2.3 (REFUTADO)**: `wiki_graph_run` SIN argumento resuelve `/workspace/agent.yml` (`:268`) → en host no existe → `wiki_graph_enabled` retorna 1 (`:51`) → `[wiki-graph] disabled — skip`. Medido: rc=0 y `tests/fixtures/vault-graph/.graph` no se crea. El comando del golden de T002 y los tres escenarios del quickstart necesitan un `agent.yml` temporal con `vault: {enabled: true}` como primer argumento.
- **`policy.json.collection` en local**: el contrato dice copiar `collection_layout`/`migration` de `qmd-index.json`. El runner no sourcea `qmd_index.sh`; en docker `QMD_INDEX_STATE_FILE` está definida en `heartbeatctl:66` (misma shell), pero en local `local-wiki-graph.sh.tpl` no la exporta y el default de `qmd_index.sh:65` es `/workspace/scripts/heartbeat/qmd-index.json` (inexistente en el host). Derivar la ruta como `$(dirname "$WIKI_GRAPH_STATE_FILE")/qmd-index.json` (ambos state files viven en `scripts/heartbeat/`, `heartbeatctl:66,68`; `local-qmd-reindex.sh.tpl:43` y `local-wiki-graph.sh.tpl:30`).

### 1(f) `_wg_atomic_write` para dos artefactos más — CONFIRMADO

- `_wg_atomic_write` `:484-491` es autocontenida (tmp en el mismo dir + `mv -f`), sin lock propio; el lock es del `flock` externo `:276-281`. Dos llamadas más tras `:373` no alteran orden ni lock. El oráculo `:151-158` (`ls .graph/.wg.* == 0`) sigue válido.

### 1(g) Skeleton limpio sigue en 0 — CONFIRMADO

- `wiki-graph.bats:98-107` suma todos los `counts` salvo `nodes`/`edges` y exige 0. Los 12 counts nuevos serán 0 sobre el skeleton si: (i) `index.md` lleva los ejemplos dentro de `<!-- -->` — `_wg_index_entries` `:409-411` los elimina (inline y multilínea) y `:419` descarta placeholders `<…>`; (ii) las plantillas viven en `_templates/`, fuera de `$wiki_dir` — el runner enumera solo `$vault_dir/wiki` (`:321`, `:329`, `:340`), así que **las plantillas NO son nodos**; (iii) el skeleton no trae marcador 0.27.0 → `schema_delta_pending` 0.
- Cuidado con el oráculo vault-schema §5 "plantilla sembrada en una fixture parsea sin violación": ver §1 punto 8 del resumen (F4 sobre `due: ""`).

### 1(h) Lugares que asumen exactamente tres artefactos — PARCIAL

- Tests: `wiki-graph.bats:142-149` (L1) solo exige cero `.md` y la presencia de los tres → no rompe con cinco. `:151-158` idem.
- Texto que quedará caduco y NO está en T032/T038: `wiki_graph.sh:10` y `:365` (comentarios "three artifacts"), `heartbeatctl:1007` (help de `wiki-graph`), `modules/local-wiki-graph.sh.tpl:4`, `docs/architecture.md:295`, `docs/state-layout.md:160`, `CHANGELOG.md:891` (histórico, no tocar). Sí cubiertos: `modules/claude-md.tpl:214-219` ("derives three JSON artifacts"), `README.md:223`, `docs/heartbeatctl.md:472`.

## 2. `scripts/lib/vault.sh::vault_seed_missing` — PARCIAL

- Bloque 0.8.0 `:76-110`: `changed` se decide en `:80-90`; el delta se gatea en `:95` por marcador 0.8.0 ausente Y (`changed==1 || has_pages==1`) `:100`. Un bloque nuevo tras `:110` con `changed27` propio no puede disparar el 0.8.0 (ya evaluado). CONFIRMADO en ese sentido.
- `has_pages` `:96-99`: `find "$target/wiki" -type f -name '*.md' | head -1 | grep -q .` dentro de un `if`. **Medido**: con 3000 páginas y `set -o pipefail`, FALSE 200/200 (bash 3.2.57 y 5.3.15); con 5 páginas o sin pipefail, TRUE 200/200. `start_services.sh:14` es `set -euo pipefail` y llama `vault_seed_missing` en `:133`; `setup.sh::_seed_vault_local` (`:2841-2842`) es el otro caller. Es la clase de carrera documentada en CLAUDE.md ("PRODUCER | grep -q bajo pipefail"). Para el bloque 0.8.0 es hoy inocuo (la flota ya tiene el marcador y el bloque debe quedar byte-idéntico), pero **T008 no debe copiarlo**: la forma segura `[ -n "$(find "$target/wiki" -type f -name '*.md' -print -quit 2>/dev/null)" ]` dio TRUE 200/200 (`-quit` existe en GNU, BSD y busybox find).
- Cuándo importa para 0.27.0: la primera corrida siempre tiene `changed27=1` (plantillas ausentes), pero si `cp` del delta falla tras copiar las plantillas, la siguiente corrida depende de `has_pages` y en un vault grande nunca depositaría el delta.
- **Fixtures**: solo existe `tests/fixtures/vault-populated/` (con `_templates/summary.md`, seis páginas, sin `normalization/`, sin marcadores). `vault-upgrade.bats` tiene 10 tests y el helper `_vault_hash` (`:21`, `shasum` portable). Las fixtures (b) y (c) no existen; las crea T003.
- **Fixture (b) tal como la define T003 hace inmatable M10**: con el marcador 0.8.0 presente, el bloque 0.8.0 se salta en `:95` sin mirar `changed`. La mutación real (copiar las plantillas nuevas en la sección 2 `:86-90` con `changed=1`) solo se detecta en un vault SIN marcador 0.8.0 y wiki vacía, que además es el estado real de todo agente sembrado post-014 con wiki vacía (el guard `:100` nunca le depositó el 0.8.0). Ver corrección.

## 3. `scripts/lib/qmd_index.sh` — PARCIAL

- `:379` `--mask '**/*.md'`: los tests actuales solo asertan `collection add` (`qmd-setup.bats:41,83,120`; `docker-e2e-qmd.bats:171`); ninguno asserta la máscara. Cambiarla no rompe nada (grep de `**/*.md` en `tests/`: cero ocurrencias). CONFIRMADO.
- Migración antes del guard `:538`: `_qmd_reindex_locked` `:529-566` tiene `state_file` resuelto en `:532`; insertar `qmd_migrate_collection` antes de `:538` es directo. Los tests de `qmd-index.bats` y `qmd-embed-completion.bats` NUNCA pre-siembran `index.sqlite` (grep: solo `qmd-setup.bats:77,103`, `agentctl-local.bats` y `local-qmd.bats:110`, que no invocan la lib) → `qmd_collection_layout_state` = `n/a` → sin migración → sus logs de stub no cambian. CONFIRMADO.
- `qmd_write_state` `:286-313` construye el JSON completo en cada escritura (`:305-307`); las claves nuevas deben calcularse dentro (llamando a `qmd_collection_layout_state`) o pasarse como argumentos. Nadie asserta el set exacto de claves de `qmd-index.json` (grep `keys` en tests qmd: cero). CONFIRMADO. Vacío del contrato: qué `collection_layout` se escribe cuando `migration == n/a` (sin índice).
- `qmd_cache_root` `:62` = `${QMD_CACHE_HOME:-$HOME/.cache/qmd}`; docker `/home/agent/.cache/qmd` (bind `.state`), local `QMD_CACHE_HOME=<ws>/.state/.cache/qmd` (`local-qmd-reindex.sh.tpl:41`); ahí ya viven `.qmd-setup-ok` (`:326`) y `.reindex.lock` (`:334`). Escribible en ambos modos. CONFIRMADO.
- **Sentinel "tras `:397`" (REFUTADO)**: `:397` es `: > "$sentinel"` (el `.qmd-setup-ok`) y se alcanza tanto desde la rama `if [ ! -f index.sqlite ]` `:377-382` (que hace el `add`) como desde la rama `else` `:383-385` ("index present, sentinel absent — refreshing only"), que NO cambia la colección. Un agente pre-037 con índice heredado y `.qmd-setup-ok` perdido pasaría por `:384` → `update` → `embed` → sentinel de layout → `done` con máscara `**/*.md` todavía. El sentinel de layout debe escribirse solo cuando ESTE run hizo `collection add` (dentro de `:377-382` tras el éxito, o con `did_add=1`).
- Stub `tests/helper.bash:93-106`: ve el subcomando en `$1` (`collection`), el verbo en `$2` (`add`/`remove`); graba `$@` completo por línea `:97`. Extensible con `case "$1 $2"`. Dos detalles para T004: (i) el heredoc es `<<EOF` sin comillas: `$QMD_CACHE_HOME`, `$QMD_STUB_LOG` se expanden al crear el stub (bien), pero `QMD_STUB_PENDING` y `QMD_STUB_FAIL_ONCE` deben ir escapados (`\$QMD_STUB_PENDING`) para leerse en tiempo de ejecución, si no el test no podrá cambiarlos tras `install_qmd_stub`; (ii) `QMD_STUB_DIR` no existe hoy: definirlo en `_qmd_stub_prefix_seed` `:79-87` o en `install_qmd_stub`.

## 4. `docker/scripts/heartbeatctl` y `heartbeat.sh` — PARCIAL

- `cmd_reload` `:173-331`: lee claves con `_yq` (`:160-171`, devuelve `""` para null); agregar tres lecturas junto a `:178-184` es directo. `user.language` es legible con `_yq '.user.language'` (mismo `AGENT_YML`). CONFIRMADO.
- `heartbeatctl.bats:299-327`: no hay golden ni conteo exacto de líneas; los tests grepean líneas (`:308`, `:320`, `:326`); los `! grep` de `:320`/`:326` son la ÚLTIMA sentencia del test, así que no caen en el quirk. Extensible. CONFIRMADO.
- **Octava línea en el heredoc (REFUTADO como oráculo)**: el heredoc `:304-313` emite una línea por variable; con la variable vacía emite una línea EN BLANCO (así funcionan hoy `${backup_line}`, `${vault_backup_line}`, etc.). Agregar `${review_line}` como línea propia produce, con `enabled: false`, un crontab con una línea en blanco más que el de v0.26.0 → `cmp` falla. Para cumplir "byte-idéntico" la variable debe incluir su propio salto: `review_line=$'\n'"$schedule HEARTBEAT_TRIGGER=review …"` y el heredoc `${wiki_graph_line}${review_line}` en la misma línea. Con `false`, `review_line=""` y el archivo es byte-idéntico. El mismo punto invalida "8 líneas / 7 líneas" de T037 y quickstart §3: hoy `/etc/crontabs/agent` tiene 8 líneas físicas (cabecera + 7, varias en blanco); contar con `grep -cv '^#\|^$'`, no con `wc -l`.
- `vault_resolve_root`: definida en `scripts/lib/backup_vault.sh:26`, NO en `vault.sh` (que solo tiene `vault_ensure_paths`, `vault_seed_*`, `vault_backup_and_reseed`, `vault_log_append`). `heartbeatctl:35-40` la sourcea desde `$LIB_DIR/backup_vault.sh` con fallback a `scripts/lib/` (`_HBCTL_RELOCATED_LIB` `:26`), que es lo que usa `heartbeatctl.bats` (`HEARTBEATCTL_LIB_DIR=docker/scripts/lib`, sin `backup_vault.sh` en el repo). Disponible en ambos contextos; la atribución del contrato es incorrecta. En docker devuelve `/home/agent/.vault` para el path por defecto (`backup_vault.sh:38-45`); honra `VAULT_ROOT_OVERRIDE` (`:29-32`).
- Formato de crontab: `/etc/crontabs/agent` es crontab de usuario busybox, SIN campo usuario (`docker/crontab.tpl:2-3`; las siete líneas `:225`, `:235`, `:247`, `:260`, `:274`, `:287`, `:300` son `<schedule> <cmd> >> log 2>&1`). El comando corre en `/bin/sh -c`. **Medido en la imagen (BusyBox 1.37.0)** con `* * * * * echo a%b >> out; echo "$(echo sub)" >> out`: salida `a%b` / `sub` / `done`. Es decir: `%` NO es salto de línea en busybox crond (el contrato §2.3 y research K4 lo afirman) y `$(cat …)` con comillas dobles funciona. El diseño del archivo sigue siendo correcto por otras razones (comillas, hasta 4000 chars, `heartbeat.conf` como molde), y la línea propuesta es válida. CONFIRMADO el mecanismo, REFUTADA la justificación.
- `heartbeat.sh:35` `TRIGGER="${HEARTBEAT_TRIGGER:-cron}"`; `:37-43` parsea `--prompt` y `--trigger` (cualquier valor, sin enum) y descarta flags desconocidos. `runs.jsonl` graba `trigger` en `:308,315`. `HEARTBEAT_TRIGGER=review` y `--trigger review` son redundantes pero inocuos. CONFIRMADO. `mkdir -p "$HEARTBEAT_DIR/logs"` `:193` cubre `logs/review.log`.
- Vacío del contrato: `heartbeat.sh` no lee `HEARTBEAT_ENABLED` para decidir (solo lo persiste en `:379`); `cmd_reload` comenta la línea principal cuando `enabled=false` (`:227`) pero las otras seis no dependen de eso. El contrato no dice si `review.enabled: true` con `features.heartbeat.enabled: false` (`heartbeatctl pause`) debe emitir la línea. Decidir y fijar oráculo.
- `cmd_status` `:350-438`: exige `state.json` con `schema == 1` (`:351-357`) antes de imprimir nada; el test de T035 para `status` debe crear `state.json` (los tests actuales lo hacen). Bloques nuevos tras `:418` sin exit por contenido. CONFIRMADO.

## 5. `scripts/agentctl` y `modules/local-qmd-reindex.sh.tpl` — PARCIAL

- `_local_vault_qmd_status` `:1107-1151`: solo `echo`; la línea de counts está en `:1141` y "qmd index: present" en `:1118-1119`. Sin exit codes. CONFIRMADO.
- `_local_vault_qmd_doctor` `:1155-1236`: `_doctor_pass`/`_doctor_warn`/`_doctor_fail`; agregar `_doctor_pass` informativos no cambia el contrato 0/1/2 (`:1216-1228` intacto). CONFIRMADO.
- `cmd_local_heartbeat` `:1566-1596`: `case` con `qmd-reindex` (`:1570`, que RECHAZA `--dry-run` en `:1575-1577`), `backup-vault`, `wiki-graph`; agregar `qmd-migrate)` que ejecute `"$script" --migrate "$@"` es directo. El nuevo caso debe dejar pasar `--dry-run` (a diferencia de `qmd-reindex`). CONFIRMADO.
- `local-qmd-reindex.sh.tpl:52-54`: `if [ "${1:-}" = "--setup-only" ]; then exit 0; fi` tras `qmd_setup_if_needed` (`:51`). **REFUTADO el molde para `--migrate --dry-run`**: el setup corre antes del dispatch; en un workspace sin índice, un `--migrate --dry-run` dispararía `collection add` + descarga del modelo. El dispatch de `--migrate` debe ir ANTES de `:51`.

## 6. `setup.sh`, `schema.sh`, `schema.bats` — CONFIRMADO (con dos precisiones)

- `regenerate()` en `:2189`. Los backfills 029 (`:2335-2337`) y 036 (`:2358-2362`) usan `yq -r '((.X // {}) | has("k")) // false'` → `!= "true"` → `yq -i`. Ambos están dentro de `if [ -f "$agent_yml" ]` (`:2204-2363`), NO gateado por vault ni por modo: el backfill de `features.heartbeat.review` corre para todo workspace. Heredocs: `features.heartbeat` `:1255-1260`, `vault:` `:1282-1297`. `mcp_timeout_effective` en `:2373`, `channel_health_timeout_effective` en `:2380`. Todo como cita el contrato.
- `schema.bats:38-50`: compara el set EXACTO de sub-claves de `vault` de `sample-agent-with-vault.yml` con la lista `:42-43` (`enabled force_reseed initial_sources mcp path qmd schema seed_skeleton`); la lista debe pasar a incluir `archive review` (el `sort` lo ordena). La fixture hoy NO trae `wiki_graph` ni `backup_schedule` (claves opcionales no escritas por el heredoc) — consistente con que `review`/`archive` sí entren porque van al heredoc.
- `schema.bats:52-117`: solo verifica placeholder de plantilla → producido por `render_load_context` con la fixture (o `known_external`). No hay chequeo inverso (variable producida sin consumidor). Por tanto agregar `vault.review.*` a la fixture es inocuo aunque ninguna plantilla los consuma, y `known_external` solo cambia si alguna plantilla usa un `{{VAR}}` que la fixture no produce. **Contradicción**: data-model §9 dice "los seis `{{VAR}}` nuevos entran a `known_external`"; contrato agent-yml §1 dice que no cambia. El contrato es el correcto.
- `schema.sh:65-74` `_SCHEMA_BOOLEANS` y `:81-89` `_SCHEMA_OPTIONAL_NONEMPTY` son rutas yq evaluadas con `yq -r "$path"` (`:99`, `:165`); `.features.heartbeat.review.enabled` (cuatro niveles) funciona igual que `.vault.wiki_graph.schedule`. CONFIRMADO.
- `regenerate.bats:85-90` ("is idempotent") solo diffea `.mcp.json`; el invariante 1 del contrato agent-yml lo cita como oráculo de "agent.yml byte-idéntico" — no lo es; T011(c) sí lo agrega explícito, mantenerlo.

## 7. `quickstart.md` y trampas de bats en `tasks.md` — PARCIAL

- §2.1, §2.2, §2.3: `wiki_graph_run` sin agent.yml → skip (ver 1e). REFUTADO tal como está.
- §2.3: `sed -i '' "s/…/"` es sintaxis BSD; GNU sed toma `''` como script vacío y el `s/…/` como archivo (falla). Usar `sed "s/SCAFFOLD_DATE/2030-06-01/" log.md > log.tmp && mv log.tmp log.md`, o directamente `vault_seed_if_empty "$d" modules/vault-skeleton 2030-06-01` que ya hace la sustitución (`vault.sh:46-49`).
- §2.4: usa `vault_seed_missing` sin `load_lib vault` previo (solo §2.1 sourcea `wiki_graph`). `shasum -a 256` existe en macOS y en ubuntu CI (perl); OK.
- §2.7: `grep -c -- '--trigger review --prompt "$(cat …)"'` con BRE: `$` no final y `(` son literales en POSIX BRE, pero es frágil entre GNU/BSD; usar `grep -F -c`.
- §1: `git diff --stat main -- docker/ | grep -vE 'heartbeatctl|crontab'` excluye `crontab`, pero el contrato exige `docker/crontab.tpl` intacto (`docker-render.bats:132-137`). Quitar `crontab` de la exclusión o el gate ocultaría una regresión.
- §3: "8 líneas / 7 líneas" — ver §4 (contar no comentadas no vacías).
- Trampa bats: el encabezado de tasks.md ya fija las formas vivas. En el cuerpo, T009 ("NO aparece en `orphan` ni en `stale`"), T018 ("ausente…"), T027/T029/T033 ("→ 0") y T035 ("no existe `review-prompt.txt`", "línea ausente") describen negativos sin forma; basta que la implementación use `[ "$(grep -c … || true)" -eq 0 ]` / `[ ! -f … ]` como manda el encabezado. `tests/local-render.bats:304` usa `! grep -rq …` como ÚLTIMA sentencia (válido); si T035 extiende ese test agregando archivos DESPUÉS del `! grep`, el negativo queda intermedio y muerto: agregar los archivos nuevos a la lista del mismo `grep`, no en una sentencia posterior.

## 8. Paralelismo y dependencias — PARCIAL

- T002/T003/T004 `[P]`: archivos disjuntos (`vault-graph.findings.golden.json`; `vault-graph-para/`, `vault-0.8.0-*`; `tests/helper.bash`). OK.
- T017 `[P]` (docs + `specs/010…/qmd-cli.md`) frente a T015/T016 (`qmd_index.sh`, `heartbeatctl`, `agentctl`, tpl). OK.
- T037 `[P]` (`tests/docker-e2e-*.bats`) frente a T035/T036 (`heartbeatctl.bats`, `heartbeatctl`). OK.
- **T043 `[P]` edita `docs/vault.md`**, también editado por T017 y T032 → conflicto si corre en paralelo. Quitar `[P]` o restringir T043 a `scripts/qmd_watch.sh` + `tests/qmd-watch.bats` y mover su párrafo de docs a T038.
- T023/T025/T027/T029 (RED) son independientes entre sí (secciones distintas de `tests/vault.bats` y `tests/wiki-graph.bats`), pero editan los MISMOS archivos bats: paralelizables solo si cada uno agrega su sección al final; la nota "secuenciar la prosa" ya está.
- Dependencias hacia adelante: T009→T018/T028, T010→T026, T019→T034 son exclusiones explícitas, no dependencias invertidas. T011(d) necesita `policy.json` de T010 (declarado). T035 necesita `cmd_status` de T016 (declarado). No hay tarea que dependa de una posterior.
- `tests/agentctl-local.bats` tiene 50 `@test` (T022 "50 previos" correcto). Conteo estático total: 1502 `@test` (T001 correcto).

---

## Correcciones concretas a tasks.md y contratos

### C1 — `contracts/heartbeat-review-notice.md` §2.3 y §6; T035/T036

Reemplazar "emite la octava línea del crontab, tras la de wiki-graph `:294-301`" por:

> Construye `review_line` con un salto de línea INICIAL embebido (`review_line=$'\n'"<schedule> HEARTBEAT_TRIGGER=review /workspace/scripts/heartbeat/heartbeat.sh --trigger review --prompt \"\$(cat /workspace/scripts/heartbeat/review-prompt.txt)\" >> /workspace/scripts/heartbeat/logs/review.log 2>&1"`) y la concatena en la MISMA línea del heredoc que `${wiki_graph_line}` (`${wiki_graph_line}${review_line}`). Con `enabled: false`, `review_line=""` y el crontab es byte-idéntico al de v0.26.0 (una línea propia en el heredoc agregaría una línea en blanco y rompería el oráculo).

En §6 y en T037/quickstart §3, reemplazar "8 líneas / 7 líneas" por "una línea no comentada que contiene `--trigger review` / cero; conteo con `grep -c -- '--trigger review' /etc/crontabs/agent || true`".

### C2 — `contracts/heartbeat-review-notice.md` §2.3 (motivo del archivo); `research.md` K4

Reemplazar "hasta 4000 chars con comillas y `%` (que busybox crond interpreta como salto de línea) no caben de forma segura" por:

> hasta 4000 chars con comillas dobles y `$` no caben legibles ni seguros en una línea de crontab; el archivo sigue el molde de `heartbeat.conf`. Medido en la imagen (BusyBox 1.37.0): `%` NO es salto de línea en busybox crond y `$(cat …)` se expande en `/bin/sh -c`.

### C3 — `contracts/heartbeat-review-notice.md` §2.3; T036

Reemplazar "`vault_resolve_root` de `vault.sh`, image-baked" por "`vault_resolve_root` de `backup_vault.sh:26`, ya sourceada por `heartbeatctl:35-40` (fallback `scripts/lib/` para bats)".

### C4 — T037 (`tests/docker-e2e-vault.bats`)

Reemplazar "el boot deposita el delta 0.27.0 con marcador `deposited: <fecha>` y exactamente una línea CANON-D14 tras dos boots" por:

> (a) scaffold fresco (arnés actual): tras el boot NO existe `_templates/.schema-updates-0.27.0.applied` ni línea CANON-D14 (guard fresh-scaffold, molde `docker-e2e-qmd.bats:249-252` `NO_DELTA`); (b) caso upgrade: antes del primer boot copiar `tests/fixtures/vault-populated/.` a `$DEST/.state/.vault/` (pre-crear `.state/`), arrancar, asertar marcador 0.27.0 con `deposited: <fecha ISO>`, marcador 0.8.0 vacío, y exactamente una línea CANON-D14 tras `docker compose restart`.

### C5 — T008 (`vault.sh` bloque 0.27.0)

Agregar: "NO reutilizar el `find | head -1 | grep -q .` de `:97` para `has_pages`: bajo el `pipefail` de `start_services.sh:14` evalúa FALSE con vaults grandes (medido 200/200 con 3000 páginas). Usar `has_pages27=0; [ -n "$(find "$target/wiki" -type f -name '*.md' -print -quit 2>/dev/null)" ] && has_pages27=1`. El bloque 0.8.0 queda byte-idéntico (su carrera es inocua hoy: la flota ya tiene el marcador); anotar la deuda en `research.md`."

Agregar a `quickstart.md` §4 una mutación M17: "volver `has_pages27` a la forma `| head -1 | grep -q .` → test con fixture de 3000 páginas vacías bajo `set -o pipefail` en `vault-upgrade.bats`".

### C6 — `contracts/qmd-collection-migration.md` §2 fila 1; T015

Reemplazar "tras `:397` escribe el sentinel de layout" por:

> escribe el sentinel de layout `$(qmd_cache_root)/.qmd-collection-wiki` SOLO dentro de la rama `if [ ! -f "$cache_root/index.sqlite" ]` (`:377-382`), inmediatamente después de un `collection add` exitoso (antes de `update`). La rama re-entrante `:383-385` (índice presente, `.qmd-setup-ok` ausente) NO escribe el sentinel: ese índice puede ser heredado y debe migrar en el primer tick.

Agregar oráculo a T014(a): "con `index.sqlite` pre-sembrado y `.qmd-setup-ok` ausente, `qmd_setup_if_needed` NO crea `.qmd-collection-wiki`". Agregar mutación M18 (escribir el sentinel tras `:397`).

### C7 — T002 y `quickstart.md` §2.1-2.3

Reemplazar los comandos por la forma con agent.yml explícito:

```bash
source tests/helper.bash; load_lib wiki_graph
ay=$(mktemp); printf 'vault: {enabled: true, wiki_graph: {enabled: true}}\n' > "$ay"
WIKI_GRAPH_VAULT_DIR=tests/fixtures/vault-graph WIKI_GRAPH_STATE_FILE=$(mktemp) WIKI_GRAPH_TODAY=2030-06-15 wiki_graph_run "$ay"
```

(Sin el argumento, `wiki_graph_run` resuelve `/workspace/agent.yml`, ausente en host, y sale con `disabled — skip` sin generar `.graph/`.)

### C8 — `contracts/graph-findings-extension.md` §2 (violaciones F1-F4) y `data-model.md` §1

Agregar la regla: "F1, F2, F3 y F4 se emiten SOLO cuando el valor tras `unquote` es NO vacío (molde `status` `wiki_graph.sh:174`). `para: ""`, `packet: ""`, `distill: ""`, `due: ""`, `next_review: ""`, `archived: ""` equivalen a clave ausente (para `para`, a `resource`). Esto es lo que permite que una plantilla de `_templates/` sembrada en `wiki/` parsee sin `frontmatter_violation` (oráculo vault-schema §5)."

### C9 — T003 fixture (b)

Reemplazar "`vault-0.8.0-empty/` = skeleton actual + `_templates/schema-updates-0.8.0.md` + marcador 0.8.0 vacío, wiki vacía" por:

> `vault-0.8.0-empty/` = skeleton PRE-037 (copia del skeleton actual sin `_templates/entity-project.md` ni `overview-area.md`, sin las secciones nuevas de `index.md`), SIN marcador ni delta 0.8.0 (estado real de un agente sembrado post-014 con wiki vacía: el guard fresh-scaffold nunca le depositó el 0.8.0), wiki vacía. Oráculo T007: recibe SOLO el 0.27.0 (plantillas + delta + marcador fechado + una línea D14) y NO aparece `schema updates 0.8.0`.

Con esa fixture M10 ("copiar las plantillas nuevas dentro de la sección 2 `:86-90` con `changed=1`") sí cae. Reescribir M10 en esos términos.

### C10 — T016 (`modules/local-qmd-reindex.sh.tpl`)

Agregar: "el dispatch de `--migrate [--dry-run]` va ANTES de `qmd_setup_if_needed` (`:51`); si no, un dry-run en un workspace sin índice ejecuta el setup real (descarga del modelo). Oráculo en `local-qmd.bats`: con `--migrate --dry-run` el log del stub no contiene `collection add` de setup ni `embed`."

### C11 — `data-model.md` §9

Reemplazar "los seis `{{VAR}}` nuevos entran a `known_external` de `tests/schema.bats`" por "ningún `{{VAR}}` nuevo entra a plantillas ni a `known_external` (contrato agent-yml §1); `schema.bats:52-117` solo verifica placeholder → producido, sin chequeo inverso, así que las claves nuevas en las fixtures son inocuas".

### C12 — T043

Quitar `[P]` o restringir la tarea a `scripts/qmd_watch.sh` y `tests/qmd-watch.bats`, moviendo su párrafo de `docs/vault.md` a T038 (que ya consolida docs). Motivo: `docs/vault.md` lo editan T017 y T032.

### C13 — T010 (menores, sin cambio de diseño)

- Extender también la rama de continuación por guiones `:195-201` con `problems` y `tags` (hoy solo `related`/`sources`/`aliases`; un array en guiones se descarta en silencio).
- Sanear tabuladores (`gsub(/\t/, " ", v)`) en `description`, `goal`, `next_action` antes del record `N`.
- Extender la firma posicional de `_wg_aggregate` (`:496`) y su único call site (`:353`).
- `policy.json.collection`: leer `qmd-index.json` desde `$(dirname "$WIKI_GRAPH_STATE_FILE")/qmd-index.json`, no desde `QMD_INDEX_STATE_FILE` (no exportada en local).

### C14 — `contracts/qmd-collection-migration.md` §2 fila 4 (vacío)

Fijar el valor de `collection_layout` cuando `migration == "n/a"` (propuesta: `"none"`), para que `heartbeatctl status`/`agentctl status` no impriman vacío.

### C15 — `contracts/heartbeat-review-notice.md` §1 (vacío)

Decidir y fijar: con `features.heartbeat.enabled: false` (`heartbeatctl pause`) y `review.enabled: true`, ¿se emite la línea de revisión? Propuesta: sí (misma semántica que las otras seis líneas, que no dependen de `enabled`), documentado; oráculo en `heartbeatctl.bats`.

### C16 — T038 (texto caduco de "tres artefactos")

Agregar a la lista: `scripts/lib/wiki_graph.sh:10,365` (comentarios), `docker/scripts/heartbeatctl:1007` (help), `modules/local-wiki-graph.sh.tpl:4`, `docs/architecture.md:295`, `docs/state-layout.md:160`.

### C17 — `quickstart.md` (portabilidad)

- §2.3: sustituir `sed -i ''` por `vault_seed_if_empty "$d" modules/vault-skeleton 2030-06-01` (hace la sustitución de `SCAFFOLD_DATE`) o por `sed … > tmp && mv`.
- §2.4: anteponer `source tests/helper.bash; load_lib vault`.
- §2.7: `grep -F -c`.
- §1: quitar `crontab` del `grep -vE` (el contrato exige `docker/crontab.tpl` intacto).

### C18 — `contracts/agent-yml-config-037.md` §5 invariante 1

Reemplazar la cita `regenerate.bats:85` (ese test solo diffea `.mcp.json`) por la referencia al test nuevo de T011(c) que compara `agent.yml` byte a byte entre dos `--regenerate`.

---

## Mediciones realizadas (reproducibles)

| Qué | Cómo | Resultado |
|---|---|---|
| `has_pages` bajo pipefail | 3000 archivos `.md`, `set -o pipefail`, 200 iteraciones de `find \| head -1 \| grep -q .` | FALSE 200/200 (bash 3.2.57 y 5.3.15); con 5 archivos TRUE 200/200; sin pipefail TRUE 200/200; `-print -quit` TRUE 200/200 |
| busybox crond `%` y `$(…)` | `docker run --rm -u root --entrypoint sh agentic-pod:latest`, crontab root `* * * * * echo a%b >> out; echo "$(echo sub)" >> out`, `crond -f`, 65 s | `a%b`, `sub`, `done` (BusyBox 1.37.0) |
| jq host | `jq --version`; diferencia de fechas con `strptime`/`mktime` | `jq-1.7.1-apple`, 25 días |
| jq imagen | idem dentro de `agentic-pod:latest` | `jq-1.8.1`, 25 días, `/usr/bin/jq` |
| `wiki_graph_run` sin agent.yml | `load_lib wiki_graph; WIKI_GRAPH_VAULT_DIR=tests/fixtures/vault-graph … wiki_graph_run` | `[wiki-graph] disabled — skip`, rc=0, sin `.graph/` |
| Conteos de `@test` | `grep -c '^@test'` | `agentctl-local.bats` 50, `vault-upgrade.bats` 10, `wiki-graph.bats` 19, `heartbeatctl.bats` 34, total 1502 |

No medido (declarado): el comportamiento de `qmd` real ante `collection remove` + `add` (viene de `discovery/L-qmd-measurements.md`); la disponibilidad de `yq` en el PATH del `sh -c` mínimo de la imagen (irrelevante: el runner ya corre bajo `heartbeatctl`, probado en DOCKER_E2E 014 fase 4.5c).
