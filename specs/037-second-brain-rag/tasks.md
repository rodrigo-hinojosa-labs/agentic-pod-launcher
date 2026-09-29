# Tasks: Second Brain sobre el LLM Wiki (037)

**Input**: Design documents from `/specs/037-second-brain-rag/`

**Prerequisites**: plan.md, spec.md (9 historias, 36 FR, 10 SC), research.md (R1-R10, D*, K*, M*), data-model.md, contracts/{vault-schema-delta-0.27.0, graph-findings-extension, qmd-collection-migration, heartbeat-review-notice, agent-yml-config-037}.md, quickstart.md, discovery/K-touchpoints.md (líneas), discovery/L-qmd-measurements.md (hechos de qmd 2.5.3).

**Tests**: OBLIGATORIOS (constitución III, test-first). Cada tarea de comportamiento va precedida por una tarea RED en bats. Negativos en formas vivas (`run grep -q …; [ "$status" -ne 0 ]` o `[ "$(grep -c … || true)" -eq 0 ]`), nunca un `! grep` intermedio (memoria `bats-intermediate-double-bracket-quirk`). Toda comparación de fechas usa `WIKI_GRAPH_TODAY` remoto (2030-06-15) para que ningún oráculo dependa del calendario. Cero aserciones sobre `rc` de qmd (flags desconocidos se ignoran en silencio, L Q1): se aserta sobre los argumentos grabados por el stub.

**Organization**: por dependencia real, no por prioridad. El schema del vault (prosa + delta) y el núcleo del runner van en Foundational porque todas las historias validan contra ese texto y esas columnas; la higiene qmd (US2) va antes que cualquier regla que escriba en `log.md` (FR-011, M2); la cola de revisión (US1+US3) después; luego US4/US5/US6; el hallazgo de delta pendiente y la documentación de config (US7); `archive_candidate` (US8); el aviso y la observabilidad (US9); Polish. Las nueve historias viajan en una rama y un PR (decisión R1).

**Line numbers**: `:NNN` son las de `discovery/K-touchpoints.md` sobre `main` @ `70214d9`; sirven para ubicar, no para editar a ciegas. Desde la primera edición de un archivo, buscar por nombre de función o por `@test` citado. Las cadenas **CANON-D\***, **CANON-F\***, **CANON-H\*** están fijadas en los contratos y deben ser idénticas entre test e implementación.

**Reglas de bytes**: inglés en skeleton/delta/plantillas; cero marcas combinantes (`LC_ALL=C grep -c $'\xcc\x80' FILE` = 0) en skeleton, delta, `setup.sh`, `heartbeatctl`, bats; los guiones largos de CANON-D6/D7 son U+2014 reales. Nunca `local LC_ALL=C` dentro de una función de `setup.sh` (034). `git add` con lista explícita; `CLAUDE.md` del repo con `git add -f`.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: paralelizable (archivos distintos, sin dependencia pendiente)
- **[Story]**: US1 eje PARA, US2 higiene qmd, US3 cola y operaciones, US4 index-first y destilación, US5 packets, US6 favorite problems, US7 upgrade y config, US8 candidatos a archivo, US9 aviso y observabilidad

## Path Conventions

- Libs canónicas (espejadas al `docker/` del workspace por `mirror_catalog_to_docker`): `scripts/lib/{wiki_graph,vault,qmd_index}.sh`
- Skeleton y delta: `modules/vault-skeleton/{CLAUDE.md,index.md,log.md,_templates/*.md,raw_sources/README.md}`, `modules/vault-deltas/schema-updates-0.27.0.md`
- Image-baked: `docker/scripts/heartbeatctl`; workspace-templated (NO se toca): `scripts/heartbeat/heartbeat.sh`
- Launcher: `setup.sh`, `scripts/lib/schema.sh`, `scripts/agentctl`, `modules/{claude-md,local-qmd-reindex.sh}.tpl`
- Tests: `tests/*.bats`, `tests/helper.bash`, `tests/fixtures/{vault-graph (intacta), vault-graph.findings.golden.json, vault-graph-para/, vault-0.8.0-empty/, vault-0.8.0-pages/, sample-agent{,-with-vault}.yml}`
- Gated e2e: `tests/docker-e2e-{qmd,vault,heartbeat}.bats`
- Docs: `README.md`, `CHANGELOG.md`, `VERSION`, `docs/{vault,heartbeatctl,state-layout,qmd-upgrade-checklist}.md`, `CLAUDE.md` (repo, gitignored)
- Scratch: el scratchpad de sesión o `mktemp -d`; nunca dentro del repo; los informes de investigación van a `specs/037-second-brain-rag/discovery/` (memoria `scratchpad-wiped-between-sessions`)

---

## Phase 1: Setup (línea base, golden, fixtures, seam)

**Purpose**: fijar la verdad previa (suite, hallazgos de la fixture 014) y construir las fixtures y el stub que todo oráculo posterior necesita.

- [X] T001 Línea base sobre el árbol pre-037 (rama recién creada, sin cambios de código): `bats tests/ > /tmp/037-base5.txt 2>&1` y `PATH=/bin:$PATH bats tests/ > /tmp/037-base3.txt 2>&1`; contar `^ok `/`^not ok ` en ambos y anotar en Notes (conteo estático hoy: 1502 `@test`); `shellcheck -S error setup.sh scripts/lib/*.sh scripts/agentctl scripts/heartbeat/*.sh docker/scripts/heartbeatctl docker/scripts/*.sh` rc=0; `git show origin/main:VERSION` = `0.26.0` (lección 023).
- [X] T002 [P] Golden de la fixture 014: con la lib ACTUAL y un `agent.yml` temporal (`ay=$(mktemp); printf 'vault: {enabled: true, wiki_graph: {enabled: true}}\n' > "$ay"` — sin argumento `wiki_graph_run` resuelve `/workspace/agent.yml`, ausente en host, y sale `disabled — skip` sin generar nada, refutación N C7), `WIKI_GRAPH_VAULT_DIR=tests/fixtures/vault-graph WIKI_GRAPH_STATE_FILE=$(mktemp) wiki_graph_run "$ay"` (sourceando `tests/helper.bash::load_lib wiki_graph`), copiar `jq -S '{findings: .findings}' tests/fixtures/vault-graph/.graph/findings.json` a `tests/fixtures/vault-graph.findings.golden.json`; verificar 7 hallazgos (`README.md:26-36` de la fixture: orphan 1, broken_link 1, frontmatter_violation 1, index_drift 2, stale 1, alias_occurrence 1); borrar el `.graph/` generado dentro de la fixture (`git status` limpio salvo el golden); registrar `shasum -a 256` del golden en `research.md` §2.
- [X] T003 [P] Fixtures nuevas: (a) `tests/fixtures/vault-graph-para/` según `contracts/graph-findings-extension.md` §7.2 (páginas con fechas remotas alrededor de `TODAY=2030-06-15`; `_templates/.schema-updates-0.27.0.applied` con `deposited: 2030-05-01`; `CLAUDE.md` copiado del skeleton ACTUAL, sin CANON-D1; `raw_sources/` con un `.md` `clipped:` sin summary y otro citado; `log.md` con una mención fechada `2030-06-10` a la página stale no candidata; `index.md` con todas las páginas listadas para que `index_drift` sea 0) y su `README.md` con la tabla exacta de hallazgos esperados por kind y por página; (b) `tests/fixtures/vault-0.8.0-empty/` = skeleton **pre-037** (copia del skeleton actual SIN `_templates/entity-project.md` ni `overview-area.md` y sin las secciones nuevas de `index.md`), **sin marcador ni delta 0.8.0**, wiki vacía — es el estado real de un agente sembrado post-014 con wiki vacía, al que el guard fresh-scaffold nunca le depositó el 0.8.0 (refutación N C9); (c) `tests/fixtures/vault-0.8.0-pages/` = (b) + dos páginas válidas en `wiki/concepts/` listadas en `index.md` + `_templates/schema-updates-0.8.0.md` + marcador 0.8.0 vacío (un vault con páginas que sí recibió el 0.8.0). Ninguna fixture trae página de favorite problems salvo la de (a).
- [X] T004 [P] Extender el seam de qmd (019) en `tests/helper.bash::install_qmd_stub` (`:93-106`): el stub sigue grabando `$@` por línea en `$QMD_STUB_LOG`; ante `collection add` crea `$QMD_CACHE_HOME/index.sqlite` (ya; los setups exportan solo `QMD_CACHE_HOME`, `qmd-setup.bats:18`, y `qmd_cache_root` lo honra) y un marcador `$QMD_STUB_DIR/collections/<name>`; ante `collection remove`/`rm` lo borra (rc=1 si no existe); ante `cleanup` incrementa `$QMD_STUB_DIR/cleanup.count`; ante `status` imprime `Total: N files indexed` y `Pending: ${QMD_STUB_PENDING:-0} need embedding` solo si `QMD_STUB_PENDING` > 0; ante `ls` imprime rutas `wiki/…` del vault real; ante `embed` imprime la señal de 018 (`All content hashes already have embeddings`); seam `QMD_STUB_FAIL_ONCE=<subcomando>` hace fallar (rc=1) la primera invocación de ese subcomando y borra el seam. El heredoc del stub es `<<EOF` sin comillas: `QMD_STUB_PENDING`/`QMD_STUB_FAIL_ONCE` deben ir escapados (`\$QMD_STUB_PENDING`) para leerse en tiempo de ejecución, y `QMD_STUB_DIR` no existe hoy — definirlo en `_qmd_stub_prefix_seed` (`:79-87`) (refutación N §3). Verificar que `bats tests/qmd-*.bats tests/local-qmd.bats tests/start-services-qmd.bats` sigue GREEN.

**Checkpoint**: suite GREEN con números anotados; golden commiteable; tres fixtures nuevas con README de oráculo; stub extendido sin romper nada.

---

## Phase 2: Foundational (schema + delta + upgrade, núcleo del runner, config)

**Purpose**: el texto del schema y las columnas nuevas del runner son la base de las nueve historias; la config entra aquí porque el runner la lee.

**CRITICAL**: ninguna historia empieza antes de cerrar esta fase.

- [X] T005 RED en `tests/vault.bats` (sección `# ── 037 schema ──`): cada **CANON-D1..D7**, **D10**, **D11** y **D15** aparece exactamente una vez en `modules/vault-skeleton/CLAUDE.md` (D8 y D9 se asertan en T020: su prosa escribe en `log.md` y aterriza tras la higiene qmd, FR-011); **CANON-D12** aparece 0 veces en el skeleton y 1 en el delta; cada sección `## …` del delta (encabezado + cuerpo hasta el siguiente `## `, extraídos con awk) aparece verbatim en el skeleton salvo D12 y la cabecera del delta; `index.md` contiene `## Projects (active)`, `## Areas`, `## Archive`, `## Packets`, `## Favorite problems` y sus ejemplos van SOLO dentro de `<!-- -->` (el runner sobre el skeleton limpio sigue en 0, T009 lo re-asegura); existen `_templates/entity-project.md` (`type: entity`, `para: project`, `goal`, `due`, `next_action`, `next_review`, `description`) y `_templates/overview-area.md` (`type: overview`, `para: area`, `standard`, `cadence`, `description`); las seis plantillas de conocimiento y las dos nuevas llevan `description:`; `summary.md` lleva `distill: 1`; `log.md:9` es CANON-D15; no existe ningún archivo bajo `modules/vault-skeleton/wiki/` que no sea `.gitkeep`/README (sin semilla); `raw_sources/README.md` menciona Grep y `search_notes`; cero marcas combinantes en skeleton y delta. Confirmar RED (contar).
- [X] T006 Escribir el schema 0.27.0 en `modules/vault-skeleton/CLAUDE.md` siguiendo `contracts/vault-schema-delta-0.27.0.md` §3 (3.1 Actionability con la regla de ruteo y las vistas; 3.2 frontmatter extendido con `description` obligatorio en páginas nuevas y `distill`; 3.3 `Step 0 — read the map first` con `policy.json`, umbral `index_first_max_pages`, overview/PARA/ficha activa, raw por Grep/`search_notes`, archive solo si se pide; 3.4 `Step 0.5 — capture filter`; 3.5-3.8 las cuatro operaciones con pasos mecánicos y decisionales separados, "at most three", "do not review every project every week"; NO escribir aquí 3.9 Filing policy ni 3.10 Session close (llegan en T021, después de la higiene qmd: FR-011); 3.11 Intermediate packets; 3.12 Favorite problems (bajo demanda, máx. 12, `fp-N`); 3.14 fila de capas de memoria), `index.md` (cinco secciones con comentarios), `log.md` (CANON-D15), plantillas (dos nuevas + `description`/`distill`), `raw_sources/README.md`; escribir `modules/vault-deltas/schema-updates-0.27.0.md` con el formato de `schema-updates-0.8.0.md` (cabecera que nombra el marcador, `schema_delta_pending` y la integración manual aditiva) + las mismas secciones verbatim + 3.13 `## Migration: project_* memory files` + la nota de `log.md`. Todo en inglés. GREEN T005; `bats tests/wiki-graph.bats -f "skeleton"` sigue GREEN (0 hallazgos).
- [X] T007 RED en `tests/vault-upgrade.bats` (sección `# ── 037 delta 0.27.0 ──`): sobre las tres fixtures (`vault-populated` de 014, `vault-0.8.0-empty`, `vault-0.8.0-pages`): `vault_seed_missing "$d" modules/vault-skeleton modules/vault-deltas 2030-06-15` deja 0 archivos preexistentes modificados (sha256 antes/después con `comm -23`), deposita `_templates/schema-updates-0.27.0.md`, `_templates/entity-project.md`, `_templates/overview-area.md`, escribe `_templates/.schema-updates-0.27.0.applied` con contenido exactamente `deposited: 2030-06-15` (**CANON-D13**), agrega UNA línea con **CANON-D14** a `log.md`; segunda corrida con `2030-06-16`: nada nuevo, sigue una sola línea D14 y el marcador conserva `2030-06-15`; en `vault-0.8.0-empty` (sin marcador 0.8.0) NO aparece `schema updates 0.8.0` en `log.md` ni el marcador 0.8.0 tras la corrida (el guard fresh-scaffold `:96-100` no debe dispararse aunque el bloque nuevo copie plantillas: es lo que caza la mutación M10); en `vault-0.8.0-pages` solo se agrega el 0.27.0 y el marcador 0.8.0 sigue vacío; en `vault-populated` aparecen AMBOS deltas y ambos marcadores (0.8.0 vacío, 0.27.0 con fecha); scaffold nuevo: `vault_seed_if_empty "$d" modules/vault-skeleton 2030-06-15` sobre un dir vacío deja `_templates/.schema-updates-0.27.0.applied` con exactamente `deposited: 2030-06-15` y NINGÚN `_templates/schema-updates-0.27.0.md`, y un `vault_seed_missing` posterior sobre ese scaffold es no-op (marcador presente, "sin marcador" = "no recibió el delta"; análisis M U3). Confirmar RED.
- [X] T008 Implementar en `scripts/lib/vault.sh::vault_seed_missing` (tras `:110`, antes de `return 0`): bloque 0.27.0 con flag propio `changed27`; plantillas nuevas solo si ausentes (molde `:87-90`); delta + marcador `printf 'deposited: %s\n' "$today"` + línea `log.md` `## [%s] upgrade | schema delta 0.27.0 deposited — integrate _templates/schema-updates-0.27.0.md into CLAUDE.md`, gateado por el marcador 0.27.0 y por (`changed27==1 || has_pages27==1`). **NO reutilizar** el `find | head -1 | grep -q .` de `:97`: bajo el `pipefail` de `start_services.sh:14` evalúa FALSE con vaults grandes (medido 200/200 con 3.000 páginas en bash 3.2 y 5.3, refutación N §2); usar `has_pages27=0; [ -n "$(find "$target/wiki" -type f -name '*.md' -print -quit 2>/dev/null)" ] && has_pages27=1`. El bloque 0.8.0 (`:76-110`) queda byte-idéntico (su carrera es inocua hoy: la flota ya tiene el marcador; deuda anotada en `research.md`). Además `vault_seed_if_empty` (`:33-50`, junto a la sustitución de `SCAFFOLD_DATE` `:46-49`) escribe el marcador 0.27.0 con `deposited: $today` en el scaffold nuevo, sin delta. GREEN T007 y los 10 tests previos del archivo; `wiki-graph.bats:98` (skeleton limpio → 0) sigue GREEN con el marcador presente (el `CLAUDE.md` del skeleton integra CANON-D1).
- [X] T009 RED en `tests/wiki-graph.bats` (sección `# ── 037 core ──`): (a) golden: la lib sobre `tests/fixtures/vault-graph` produce `jq -S '{findings: .findings}' findings.json` byte-idéntico a `vault-graph.findings.golden.json` y los 12 counts nuevos en 0 (correr con `WIKI_GRAPH_TODAY=2030-06-15`); (b) sobre `vault-graph-para` con `WIKI_GRAPH_TODAY=2030-06-15`: violaciones **CANON-F1** (`para: invalid 'projet'`), **F2**, **F3**, **F4** (`due: malformed`, `next_review: malformed`), **F5** (`archived: missing`) presentes con su página; `project_incomplete` con detail `missing: goal,next_action` en la ficha incompleta; la página `para: archive` sin backlinks y con fuente más nueva NO aparece en `orphan` ni en `stale`; `graph.json` trae `para` (`resource` en páginas sin clave), `tags` (la de la fixture 014 `alpha` tiene `["demo"]` — probar sobre AMBAS fixtures), `description`, `packet`, `distill`, `due`, `next_review`, `archived`, `project`, `area`, `problems`; aristas `related` desde `project:` y `area:` (backlinks de la ficha y del área contienen la página origen) y desde `problems:` hacia `synthesis/favorite-problems`; una página con `project: [[entities/no-existe]]` produce `broken_link`; `problems: [fp-9]` en una fixture sin página de favorite problems (usar `vault-graph` con una página temporal en `$TMP`) no produce arista ni hallazgo; `problems: [fp-9]` en `vault-graph-para` (página presente, entrada `fp-9` inexistente) sí produce la arista y ningún hallazgo (la entrada solo importa para `problem_unfed`, FR-004); integridad posicional: `type`/`status` de todos los nodos de ambas fixtures iguales a los del golden; seam `WIKI_GRAPH_TODAY` (con `2030-01-01` no cambia nada de (b) salvo los kinds fechados, que llegan en T018 — aquí solo se asegura que la variable se acepta). Confirmar RED (contar).
- [X] T010 Implementar el núcleo en `scripts/lib/wiki_graph.sh` según `contracts/graph-findings-extension.md` §1-§2 y §5: variables en `reset()` (`:144-151`); ramas `else if` para las 13 claves + `tags` (`:206-225`; arrays con `parse_flow`) **y** la rama de continuación por guiones `:195-201` extendida con `problems` y `tags` (hoy solo `related`/`sources`/`aliases`: un array en guiones se descartaría en silencio); `gsub(/\t/, " ", v)` en `description`, `goal`, `next_action` antes del record (viajan en TSV); regla del valor vacío para F1-F4 (solo valor NO vacío e inválido es violación, molde `status` `:174`, para que las plantillas con `due: ""` parseen limpias); record `N` (`:170`) con las 13 columnas en el orden canónico; `SRCN` (`:178`) con `para`; aristas `related` desde `project`/`area` (`unwrap(unquote())`) y `problems` → `synthesis/favorite-problems`; violaciones F1-F5 vía `emit_v` (F6 llega en T028); jq: destructuring `:506` extendido en el mismo orden, `para` vacío → `"resource"`, filtro `.para!="archive"` en `$f_orphan` `:539` y en la lista `stale` (bash `_wg_compute_stale` `:439` o jq `:512`), descarte de aristas `problems` cuando el nodo destino no existe; `WIKI_GRAPH_TODAY` (default `date -u +%F`) pasado a jq como `--arg today`; counts nuevos con default 0 también en `wiki_graph_write_state` `:94`; lectura de `.vault.review.project_days`, `.vault.review.area_days`, `.vault.archive.candidate_days` con yq (molde `wiki_graph_enabled` `:49-60`) + overrides `WIKI_GRAPH_*` + saneo `1..3650` con WARN que nombra la clave; firma posicional de `_wg_aggregate` (`:496`) extendida junto con su único call site (`:353`); `_wg_atomic_write` de `policy.json` (schema 1; `collection` copiado de `$(dirname "$WIKI_GRAPH_STATE_FILE")/qmd-index.json` si existe — en local `QMD_INDEX_STATE_FILE` no llega al runner —, si no `{"layout":"unknown","migration":"n/a"}`) — el quinto artefacto `packets.json` llega en T026. GREEN T009; `bats tests/wiki-graph.bats tests/local-wiki-graph.bats tests/agentctl-local.bats` GREEN.
- [X] T011 RED de config: (a) `tests/schema.bats:42-43`: lista exacta de sub-claves de `vault` gana `archive review` y falla hasta que la fixture cambie; (b) `tests/schema-validate.bats`: `features.heartbeat.review.enabled: maybe` → error; `features.heartbeat.review.schedule: ""` → error; (c) `tests/regenerate.bats`: `agent.yml` pre-037 (sin los tres bloques) → tras `--regenerate` existen `vault.review.{project_days:7,area_days:30}`, `vault.archive.candidate_days: 90`, `features.heartbeat.review.{enabled:false,schedule:"7 9 * * 1",prompt:""}`; un `agent.yml` con `vault.review.project_days: 14` conserva 14; `features.heartbeat.review.enabled: true` preexistente no se pisa; dos `--regenerate` byte-idénticos; (d) nuevo `tests/vault-review-config.bats` (molde `mcp-handshake-timeout.bats`): `_write_agent_yml` con `project_days` = `value|OMIT|NULL|abc|0|99999` → el runner (T010) escribe `policy.json.review.project_days` = valor válido o 7, y `--regenerate` imprime `WARN` que contiene `vault.review.project_days` y NO contiene el valor inválido; idem `area_days`, `candidate_days`; `WIKI_GRAPH_REVIEW_PROJECT_DAYS=3` gana al `agent.yml` (seam). Confirmar RED.
- [X] T012 Implementar la superficie declarativa (`contracts/agent-yml-config-037.md`): `setup.sh` heredocs (`features.heartbeat` tras `:1254-1260`; `vault:` tras `:1282-1297`), tres backfills `has()` en `regenerate()` (moldes 029 `:2335-2337`, 036 `:2358-2362`, 034 `:2324-2329`), helpers `vault_review_project_days_effective`/`vault_review_area_days_effective`/`vault_archive_candidate_days_effective` (molde `mcp_timeout_effective` `:2373`, regex `^[0-9]{1,4}$`, rango 1..3650, `echo "WARN: … <clave> …" >&2` sin el valor); `scripts/lib/schema.sh` `_SCHEMA_BOOLEANS` + `.features.heartbeat.review.enabled`, `_SCHEMA_OPTIONAL_NONEMPTY` + `.features.heartbeat.review.schedule`; fixtures `tests/fixtures/sample-agent-with-vault.yml` (`vault.review`, `vault.archive`, `features.heartbeat.review`) y `sample-agent.yml` (solo `features.heartbeat.review`); lista `schema.bats:43`. GREEN T011; `bats tests/schema.bats tests/schema-validate.bats tests/regenerate.bats tests/vault-review-config.bats tests/e2e-smoke.bats tests/quickstart-doc.bats` GREEN (los dos últimos sin cambio: no hay prompt de wizard).
- [X] T013 Cierre de Foundational: `bats tests/vault.bats tests/vault-upgrade.bats tests/wiki-graph.bats tests/local-wiki-graph.bats tests/schema.bats tests/schema-validate.bats tests/regenerate.bats tests/vault-review-config.bats tests/docker-render.bats tests/local-render.bats` GREEN en bash 5.x Y 3.2 (`PATH=/bin:$PATH`); skeleton limpio → exactamente 0 hallazgos con la lib nueva; golden 014 idéntico; auditoría de bytes = 0 en skeleton, delta, plantillas, `setup.sh`, `wiki_graph.sh`, `vault.sh`, bats tocados; `git status` sin archivos fuera de los previstos; anotar conteos en Notes.

**Checkpoint**: schema y delta escritos y verificados verbatim; upgrade aditivo en tres estados; runner con columnas, aristas, violaciones de forma, supresiones y `policy.json`; seis claves con backfill y saneo; golden 014 intacto.

---

## Phase 3: US2 — Higiene del índice de búsqueda (Priority: P1)

**Goal**: la colección qmd cubre solo `wiki/`; los agentes existentes migran solos una vez en el primer tick, reutilizando embeddings; acción manual `qmd-migrate [--dry-run]` en ambos modos; `status`/`doctor` informan el layout.

**Independent Test**: con el stub (seam A) el setup graba `--mask 'wiki/**/*.md'` y el sentinel; un índice heredado migra en el primer `_qmd_reindex_locked` en el orden remove → add → update → sentinel → cleanup, sin `embed` si `Pending` es 0; interrupción y segunda corrida se comportan como el contrato; `qmd-migrate --dry-run` no toca nada.

- [X] T014 [US2] RED: (a) `tests/qmd-setup.bats` (setup crea `$QMD_VAULT_DIR/wiki/`): el log del stub contiene `collection add <vault> --name vault --mask wiki/**/*.md` (la ruta es `$QMD_VAULT_DIR`, no `/wiki`), existe `$QMD_CACHE_HOME/.qmd-collection-wiki` con `wiki-root <fecha>`, `qmd-index.json` tiene `collection_layout: "wiki-root"` y `migration: "done"`; setup re-entrante (`index.sqlite` pre-sembrado, `.qmd-setup-ok` ausente): `qmd_setup_if_needed` graba `update` pero NO `collection add` y NO crea `.qmd-collection-wiki` (estado `pending`; refutación N C6); sin `index.sqlite` ni setup, `collection_layout: "none"` y `migration: "n/a"`; (b) `tests/qmd-index.bats`: fixture con `index.sqlite` pre-sembrado y SIN sentinel → el primer `_qmd_reindex_locked` graba en orden `collection remove vault`, `collection add … --mask wiki/**/*.md`, `update`, luego escribe el sentinel, luego `cleanup`, y NO `embed` (`QMD_STUB_PENDING` vacío); con `QMD_STUB_PENDING=3` sí `embed`; `qmd-index.json.migration == "done"`; segundo tick: ningún `collection` ni `cleanup` nuevos; con `QMD_STUB_FAIL_ONCE=add`: sentinel ausente, `migration: "pending"`, `last_status` es `error`, el hash del vault NO se actualizó y no hubo `update`/`embed` en ese tick; el tick siguiente completa desde `remove`; sin `index.sqlite` → `migration: "n/a"` y ningún `remove`; (c) `tests/qmd-reindex-cmd.bats`: `heartbeatctl qmd-migrate --dry-run` imprime `collection_layout`, `migration` y los seis pasos, y no modifica `index.sqlite` ni crea el sentinel; `heartbeatctl qmd-migrate` sin flags con sentinel presente → `already migrated`, rc 0, ningún `collection` nuevo en el log; con estado `pending` migra; `heartbeatctl qmd-migrate --force` con sentinel presente → vuelve a grabar remove/add/update/cleanup; (d) `tests/local-qmd.bats`: el wrapper renderizado despacha `--migrate` y `--migrate --dry-run` (molde `--setup-only` `local-qmd-reindex.sh.tpl:52-54`); (e) `tests/agentctl-local.bats`: `agentctl heartbeat qmd-migrate --dry-run` invoca el wrapper con esos flags; `agentctl status` muestra `qmd collection: wiki-root (migration done)`/`pending`, **calculado en vivo**: con un `qmd-index.json` heredado SIN las claves nuevas, `index.sqlite` presente y sentinel ausente imprime `pending` (es el estado antes del primer tick); `doctor` con `migration: pending` sale 0; (f) `tests/heartbeatctl.bats`: `status` imprime `qmd index: … collection=<layout> migration=<state>` con el mismo cálculo en vivo (mismo caso del state heredado → `pending`). Confirmar RED.
- [X] T015 [US2] Implementar en `scripts/lib/qmd_index.sh` (`contracts/qmd-collection-migration.md` §2): máscara `'wiki/**/*.md'` en `_qmd_setup_locked:379` + sentinel escrito SOLO dentro de la rama `if [ ! -f index.sqlite ]` (`:377-382`) tras el `add` exitoso — nunca en el camino común `:397`, que también recorre la rama re-entrante `:383-385` sin `add`; `qmd_collection_migration_state` (`n/a`/`pending`/`done`; layout derivado `none`/`vault-root`/`wiki-root` en `qmd_write_state`); `qmd_migrate_collection [--dry-run|--force]` bajo `.reindex.lock` (sin flags idempotente: `done` → `already migrated` rc 0; remove tolerante → add → update → sentinel → cleanup → embed solo si `status` reporta `Pending`, cada paso con `_qmd_run` y stderr redactado; log `qmd: collection migrated to wiki scope`; cualquier fallo → `qmd_write_state … error`, hash intacto, `pending`, sin `update`/embed en ese tick); llamada al inicio de `_qmd_reindex_locked` (antes del guard `:538`) cuando el estado es `pending`; `qmd_write_state` con `collection_layout` y `migration` (también en el path de error). GREEN T014 (a)(b).
- [X] T016 [US2] Implementar las superficies: `docker/scripts/heartbeatctl` `cmd_qmd_migrate [--dry-run|--force]` (molde `cmd_qmd_reindex` `:948-975` + `_qmd_reindex_dry` `:978-996`), dispatch en `main()` `:1056`, help `:121-130`, bloque `qmd index:` en `cmd_status` tras `:418`; `modules/local-qmd-reindex.sh.tpl` `--migrate [--dry-run]` despachado ANTES de `qmd_setup_if_needed` (`:51`) — si va tras `:52-54` como `--setup-only`, un dry-run en un workspace sin índice ejecuta el setup real y descarga el modelo (refutación N C10); oráculo en `local-qmd.bats`: con `--migrate --dry-run` el log del stub no contiene `collection add` ni `embed`; `scripts/agentctl` `cmd_local_heartbeat` `case qmd-migrate)` (`:1566-1596`, dejando pasar `--dry-run` a diferencia de `qmd-reindex` `:1575-1577`), `_local_vault_qmd_status` línea de layout junto a `:1118-1119`, `_local_vault_qmd_doctor` línea informativa (nunca `_doctor_warn`). GREEN T014 (c)-(f); `bats tests/qmd-*.bats tests/local-qmd.bats tests/agentctl-local.bats tests/heartbeatctl.bats tests/start-services-qmd.bats` GREEN.
- [X] T017 [P] [US2] Docs: `docs/vault.md:398` (`collection add <vault> --mask 'wiki/**/*.md'`), `:444-452` (sentinel `.qmd-collection-wiki`, migración automática única, `qmd-migrate`), `docs/heartbeatctl.md:5` (+`qmd-migrate`), `docs/qmd-upgrade-checklist.md` (máscara y sentinel como dependencias del pin), nota "superseded by 037" en `specs/010-self-managing-rag/contracts/qmd-cli.md:23`; `tests/quickstart-doc.bats` sigue GREEN.

**Checkpoint**: setup nuevo en `wiki-root`; migración automática, idempotente, tolerante a interrupción; acción manual y dry-run en ambos modos; `status` informa; nada bajo `docker/scripts/lib/` del repo.

---

## Phase 4: US1 + US3 — Cola de revisión determinista y operaciones (Priority: P1)

**Goal**: `review_due`, `project_overdue`, `pending_ingest` en el runner con `TODAY` inyectable; las operaciones del schema con su contenido verificable; `agentctl` local muestra los counts sin degradar.

**Independent Test**: sobre `vault-graph-para` con `WIKI_GRAPH_TODAY=2030-06-15` los tres kinds salen con 0 falsos positivos/negativos y detalles CANON; con `2030-01-01` salen 0; los oráculos de contenido del schema pasan; `doctor` local no cambia de exit.

- [X] T018 [US1] [US3] RED en `tests/wiki-graph.bats` (sección `# ── 037 review queue ──`): `review_due` con `next_review: 2030-06-01 (14 days)` en la ficha vencida, `next_review: missing` en la ficha sin fecha, ausente en la ficha vigente y en la archivada; `project_overdue` con `due: 2030-05-01 (45 days)`, ausente con `due` futuro, en `para: archive` y con `due` malformado (que sí da F4); `pending_ingest` con `page` = `raw_sources/articles/<x>.md` y detail `no summary cites this source (clipped: …)` para el raw sin summary, ausente para el citado, ausente para el raw sin `clipped:`; `raw_sources/` ausente (copia de la fixture sin ese dir) → `last_status: ok` y 0 `pending_ingest`; determinismo: dos corridas con el mismo `TODAY` → `findings.json` idénticos; `TODAY=2030-01-01` → `review_due`, `project_overdue` en 0 (salvo `next_review: missing`, que no depende de la fecha); counts del state coinciden con `findings.json` por kind; `.graph/` sin `.md` (L1 de 014) con `policy.json` presente. Confirmar RED.
- [X] T019 [US1] [US3] Implementar en `scripts/lib/wiki_graph.sh` (`contracts/graph-findings-extension.md` §3-§4): enumeración `RAW\t<ruta>\t<clipped>` (awk sobre el frontmatter de `raw_sources/**/*.md`) y `LOG\t<fecha>\t<id>` (awk sobre `log.md`, usada en T034) pasadas por `--rawfile`; en jq: `($d|strptime("%Y-%m-%d")|mktime)` con `$today`, `review_due`, `project_overdue` (excluyendo `para=="archive"`), `pending_ingest` por ruta relativa normalizada contra `.to` de aristas `source` desde nodos `summary`; counts. GREEN T018; golden 014 sigue idéntico.
- [X] T020 [US3] RED de contenido en `tests/vault.bats` (sección `# ── 037 operations ──`): bajo CANON-D2 aparecen `packets.json`, `related:` (recíproco), `next_review`, `project-open`; bajo D3: `para: archive`, `archived:`, `## Archive`, `project-close`, "never move"; bajo D4: `pending_ingest`, `project_overdue`, `project_incomplete`, `review_due`, `review | weekly`, `at most three`, "do not review every project every week"; bajo D5: `archive_candidate`, `para: area`, `review | monthly`; encabezados **CANON-D8** y **CANON-D9** presentes exactamente una vez en skeleton y delta (movidos aquí desde T005 por FR-011); bajo D8: `filed:`, "three or more pages"; bajo D9: `next_action`, `session |`; la operación query dice que con `review_due` o `pending_ingest` > 0 se ofrece la revisión en el primer mensaje ("first message"); el delta contiene exactamente lo mismo (el test verbatim de T005 lo garantiza; aquí solo se re-corre). Confirmar RED (lo que T006 no haya cubierto).
- [X] T021 [US3] Escribir 3.9 `## Filing policy` (CANON-D8) y 3.10 `## Session close (Hemingway Bridge)` (CANON-D9) y completar la prosa de las operaciones en `modules/vault-skeleton/CLAUDE.md` y el delta (mismo texto, verbatim) hasta GREEN T020, manteniendo T005 GREEN y bytes limpios. Aterriza después de T014-T016 por FR-011 (estas reglas escriben en `log.md`, que ya no está en la colección).
- [X] T022 [US1] [US3] RED+GREEN en `tests/agentctl-local.bats`: `_local_vault_qmd_status` imprime los siete contadores canónicos en orden fijo `review_due=<n> project_overdue=<n> project_incomplete=<n> pending_ingest=<n> archive_candidate=<n> schema_delta_pending=<n> problem_unfed=<n>` (data-model §6); `doctor` con todos esos counts > 0 y los seis de 014 en 0 sale **0** (fixture de `wiki-graph.json` sintética); implementar en `scripts/agentctl:1141` y `:1155-1236` (solo `_doctor_pass`/líneas informativas). `bats tests/agentctl-local.bats` GREEN (50 previos + nuevos).

**Checkpoint**: la cola de revisión existe, es determinista y visible en local; las operaciones están escritas y verificadas.

---

## Phase 5: US4 — Index-first gateado y destilación (Priority: P2)

- [X] T023 [US4] RED: en `tests/vault.bats`, bajo **CANON-D6**: `policy.json`, `index_first_max_pages`, `overview`, `Projects (active)`, "active project", `search_notes`, `Grep`, `raw_sources/`, "archive" condicionado; en la sección de frontmatter: `description` "required on every page created from now on", `distill` con las cuatro capas y "never run a distillation pass"; plantillas: las ocho con `description:`, `summary.md` con `distill: 1` y secciones `## Highlights`/`## Core` (opcionales, comentadas); en `tests/wiki-graph.bats` (`# ── 037 description ──`): `description_missing` con detail `para: project` para la ficha sin `description`, con detail `created: 2030-06-01 >= delta 2030-05-01` para la página nueva sin `para`, ausente para la preexistente (`created: 2030-01-01`, sin `para`), presente para `description: ""`; sin marcador (copia de la fixture sin el `.applied` = vault que no recibió el delta, p. ej. `seed_skeleton: false`) SOLO las páginas con `para:` declarado y sin `description` lo reportan, ninguna por `created` (análisis M U3); marcador presente pero vacío → se usa su mtime (M I5); `WIKI_GRAPH_DELTA_PENDING_DAYS` no afecta a este kind. Confirmar RED.
- [X] T024 [US4] Implementar: prosa del paso 0 y de destilación (skeleton + delta) y `description_missing` en el runner (lee `DELTA_DATE` del marcador; fallback mtime si el marcador existe vacío; `""` si no existe). GREEN T023; T005/T009/T018 siguen GREEN.

**Checkpoint**: navegación index-first y destilación en el schema; `description_missing` gateado.

---

## Phase 6: US5 — Packets como unidad de recuperación (Priority: P2)

- [X] T025 [US5] RED: `tests/wiki-graph.bats` (`# ── 037 packets ──`): `.graph/packets.json` existe siempre (skeleton limpio → `packets: []`, schema 1, `generated_at`); sobre `vault-graph-para` lista las páginas con `packet:` válido con `id,type,packet,description,project,updated`, ordenadas por `updated` desc y luego `id`; la página `packet: nope` no está en la lista y produce **CANON-F2**; `counts.packets` coincide; `.graph/` sigue sin `.md`; `tests/vault.bats`: bajo **CANON-D10** aparecen los cinco valores del enum, "natural type", "never create a `packets/` directory", `## Packets`; bajo D2 `project-open … packets reused`. Confirmar RED.
- [X] T026 [US5] Implementar `packets.json` (quinto `_wg_atomic_write` junto a `graph`, `backlinks`, `findings` y `policy`; clave `packets` en `_wg_aggregate`) y la prosa de packets (skeleton + delta). GREEN T025; L1 de 014 (`wiki-graph.bats:142-149`) sigue GREEN con cinco artefactos JSON.

**Checkpoint**: catálogo de packets derivado y documentado.

---

## Phase 7: US6 — Favorite problems como filtro de captura (Priority: P2)

- [X] T027 [US6] RED: `tests/vault.bats`: el skeleton no contiene `favorite-problems` fuera de la prosa (0 archivos bajo `wiki/`); bajo **CANON-D7**: "candidate", "ask the human", "two", `problems:`, `project:`; bajo **CANON-D11**: "when the human declares", "never pre-created", `fp-`, "twelve"/"12", `## Favorite problems`, `problem_unfed`; `tests/wiki-graph.bats` (`# ── 037 favorite problems ──`): sobre `vault-graph-para` (página con `fp-1`, `fp-2`, `fp-3`; una entrada sin forma de pregunta) → `problem_unfed` para `fp-2` y `fp-3` con detail `fp-2: <n> days without entries (threshold 30)` (la única página `problems: [fp-1]` tiene `updated: 2030-06-10`), no para `fp-1`; **CANON-F6** `favorite_problems: fp-3 is not a question`; con `WIKI_GRAPH_PROBLEM_UNFED_DAYS=400` → 0 `problem_unfed`; sobre `vault-graph` (sin página) → 0 `problem_unfed` y 0 F6; una copia de la fixture con 13 entradas → `favorite_problems: 13 entries (max 12)`. Confirmar RED.
- [X] T028 [US6] Implementar: en awk, cuando `compute_id == "synthesis/favorite-problems"`, parsear el cuerpo (`^[0-9]+\. \*\*fp-[0-9]+\*\* — …`) emitiendo `FP\t<slug>\t<is_question>` y contando entradas (F6 en `flush()`); en jq, `problem_unfed` cruzando `FP` con `problems` de los nodos y `updated`; prosa de 3.4 y 3.12 en skeleton + delta. GREEN T027.

**Checkpoint**: favorite problems operativos sin página semilla.

---

## Phase 8: US7 — Upgrade verificable y documentación de config (Priority: P2)

- [X] T029 [US7] RED en `tests/wiki-graph.bats` (`# ── 037 delta pending ──`): sobre `vault-graph-para` (marcador `deposited: 2030-05-01`, `CLAUDE.md` sin CANON-D1, `TODAY=2030-06-15`) → `schema_delta_pending` con page `_templates/schema-updates-0.27.0.md` y detail `deposited 2030-05-01 (45 days); vault CLAUDE.md lacks '## Actionability (PARA)'`; copia con CANON-D1 agregado al `CLAUDE.md` → 0; copia sin marcador → 0; `WIKI_GRAPH_DELTA_PENDING_DAYS=60` → 0; `TODAY=2030-05-10` → 0; skeleton limpio → 0; `counts.schema_delta_pending` coincide. Confirmar RED.
- [X] T030 [US7] Implementar `schema_delta_pending` (lectura del marcador + `grep -F -q -- '## Actionability (PARA)' "$vault_dir/CLAUDE.md"` + aritmética en jq). GREEN T029.
- [X] T031 [US7] RED en `tests/docker-render.bats` y `tests/local-render.bats`: el `CLAUDE.md` renderizado de un agente con vault contiene la fila "Project state → vault project page" y los nombres `review_due`, `packets.json`, `policy.json`; docker: menciona el aviso semanal y `heartbeatctl qmd-migrate`; local: menciona que el aviso es docker-only y `agentctl heartbeat qmd-migrate`; la fila de ruteo y la heurística van DENTRO de los bloques `{{#if VAULT_ENABLED}}` de `claude-md.tpl:184-185` y `:190-191`, así que un agente SIN vault renderiza byte-idéntico al render pre-037 (oráculo estricto: golden generado con `git show main:modules/claude-md.tpl` y el render de la fixture sin vault). Confirmar RED.
- [X] T032 [US7] Implementar `modules/claude-md.tpl` (capas de memoria `:176-193` fila de ruteo; wiki graph `:214-223` kinds nuevos y artefactos; heartbeat `:80-135` aviso opt-in con `qmd-migrate`; local `:92`), y docs de config: `docs/vault.md:100-126` (tabla con `review.*`, `archive.*` y las cuatro claves **reserved (no reader today)**), `docs/state-layout.md:49-55` (puntero `project_<slug>.md`), `README.md:206-225` (capas + vault); `docs/vault.md` §seeding dice explícitamente que en local el delta llega por `--regenerate` (no por `--login`) y que un agente con `vault.seed_skeleton: false` no recibe deltas (US7 AS6 y edge cases de la spec); oráculo automatizado en `tests/quickstart-doc.bats`: `grep -c 'reserved (no reader today)' docs/vault.md` = 4 y presencia de ambas frases (FR-029 doc, FR-030 se verifica por revisión). GREEN T031; `bats tests/docker-render.bats tests/local-render.bats tests/quickstart-doc.bats` GREEN.

**Checkpoint**: el delta se autodenuncia si no se integra; la documentación de config está completa.

---

## Phase 9: US8 — Candidatos a archivo (Priority: P3)

- [X] T033 [US8] RED en `tests/wiki-graph.bats` (`# ── 037 archive candidates ──`): sobre `vault-graph-para` → `archive_candidate` para la página `status: stale` sin backlinks y sin mención en `log.md` (detail `status: stale; backlinks: 0; last log mention: none`), ausente para la `stale` mencionada el `2030-06-10` (dentro de 90 días) y para cualquier `para: archive`; con `WIKI_GRAPH_ARCHIVE_CANDIDATE_DAYS=1` la mencionada también es candidata (detail `last log mention: 2030-06-10`); una `superseded` con un backlink no es candidata; `log.md` ausente → sin error, la regla de mención se vacía; `tests/vault.bats`: bajo **CANON-D5** aparecen `archive_candidate`, "at most three", "evidence", "the human decides", y se remite a la operación close (sin mover). Confirmar RED.
- [X] T034 [US8] Implementar `archive_candidate` en jq (usa `LOG` de T019: fecha ≥ `today - N` e id mencionado; backlinks desde `$backmap`) y la prosa de la monthly review. GREEN T033; runner sigue sin escribir nada fuera de `.graph/` y el state (test existente de 014 "ninguna página modificada" se re-corre sobre la fixture nueva).

**Checkpoint**: propuesta de archivo determinista; ninguna acción automática.

---

## Phase 10: US9 — Aviso semanal (docker, opt-in) y observabilidad (Priority: P3)

- [X] T035 [US9] RED: `tests/heartbeatctl.bats` (molde `:299-327`): con `features.heartbeat.review.enabled: false` el crontab generado es byte-idéntico al golden `tests/fixtures/crontab-v0.26.0.golden`, generado con el `heartbeatctl` de `main` (`git show main:docker/scripts/heartbeatctl > "$TMP/hbctl"; HEARTBEATCTL_* bash "$TMP/hbctl" reload` sobre el mismo `agent.yml` de prueba; T016 ya tocó el archivo en el working tree) y no existe `review-prompt.txt`; la línea de comentario del heredoc (`heartbeatctl:305`) NO se edita en 037 o el golden deja de ser byte-idéntico; con `enabled: true` y `schedule: "7 9 * * 1"`: exactamente una línea que empieza por `7 9 * * 1 ` y contiene `HEARTBEAT_TRIGGER=review`, `--trigger review`, `--prompt "$(cat /workspace/scripts/heartbeat/review-prompt.txt)"`, `>> /workspace/scripts/heartbeat/logs/review.log 2>&1`; `review-prompt.txt` contiene **CANON-H2-es** `sin pendientes` para `user.language: es` y `mixed`, **CANON-H2-en** `nothing pending` para `en`, la ruta del vault sustituida (sin `{{VAULT_DIR}}` literal) y `/workspace/scripts/heartbeat/wiki-graph.json`; `prompt: "custom text"` → el archivo contiene `custom text` y no el default; schedules inválidos `"9 * *"`, `"a b c d e"`, `"0 9 * * 8x"`, `"* * * * * *"`, `"* 9 * * 1"` (minuto `*`), `"*/5 9 * * 1"`, `"0 25 * * 1"` → WARN en stderr que nombra `features.heartbeat.review.schedule`, línea ausente, las otras siete entradas idénticas al caso `enabled: false`; `status` imprime `wiki-graph: <status> @ <run>` con los siete contadores canónicos `due= overdue= incomplete= ingest= archive= delta= unfed=` (data-model §6); `tests/heartbeat-runs-jsonl.bats:62`: `HEARTBEAT_TRIGGER=review` produce `"trigger":"review"`; `tests/docker-render.bats:132-137`: `docker/crontab.tpl` byte-idéntico; `tests/local-render.bats`: cero `review` en `scripts/`, units y wrappers renderizados en local (extensión del oráculo FR-011 de 032: agregar los archivos nuevos a la lista del MISMO `! grep -rq` que hoy es la última sentencia en `:304`; un `! grep` intermedio no falla el test); `features.heartbeat.enabled: false` + `review.enabled: true` → la línea de revisión se emite y la principal queda comentada como hoy (`:227`). Confirmar RED.
- [X] T036 [US9] Implementar en `docker/scripts/heartbeatctl` (`contracts/heartbeat-review-notice.md` §2-§3): lectura de las tres claves en `cmd_reload` (`:178-184`), `_v_cron5`, `heartbeat_review_prompt_default <lang>` (CANON-H1-es/en, `mixed` → es; sin tildes; lee `user.language` con `_yq`), sustitución de `{{VAULT_DIR}}` con `vault_resolve_root` (definida en `scripts/lib/backup_vault.sh:26`, ya sourceada por `heartbeatctl:35-40`) y `{{WORKSPACE}}`, `review-prompt.txt` tmp+mv junto a `heartbeat.conf` (`:196-215`), `review_line=$'\n'"…"` (salto de línea INICIAL embebido) concatenada en la MISMA línea del heredoc `:304-313` que `${wiki_graph_line}` — nunca como línea propia, que agregaría una línea en blanco con `enabled: false` y rompería el byte-idéntico (refutación N C1); la línea se emite con independencia de `features.heartbeat.enabled`; bloque `wiki-graph:` en `cmd_status` (lee `WIKI_GRAPH_STATE_FILE` `:68`); help. `scripts/heartbeat/heartbeat.sh` NO se toca (`git diff --stat -- scripts/heartbeat/` vacío). GREEN T035; `bats tests/heartbeatctl.bats tests/heartbeat-*.bats tests/docker-render.bats tests/local-render.bats` GREEN.
- [X] T037 [P] [US9] Escribir los DOCKER_E2E (parsean y skippean sin `DOCKER_E2E`): `tests/docker-e2e-qmd.bats` — Tier-1 des-diferido (`:25-27`): tras el boot el log del reindex contiene `collection add … --mask wiki/**/*.md`; caso "migración": pre-sembrar en `.state/.cache/qmd/` un `index.sqlite` con colección heredada creada dentro del contenedor con la lib ACTUAL de `main` (o con `qmd collection add <vault> --mask '**/*.md'` directo) y sin sentinel, arrancar, esperar el primer tick, asertar `qmd ls vault` solo `wiki/…`, `qmd embed` → `All content hashes already have embeddings`, `qmd status` sin `Pending`, `qmd search <token de plantilla>` vacío, `qmd-index.json.migration == done`, y que `cleanup` aparece DESPUÉS de `add` en el log; Fase 4.5 (`:236-275`) con `vault-graph-para` copiada al vault del contenedor y `WIKI_GRAPH_TODAY=2030-06-15` en la invocación manual: mismos conteos que en host (usar marcadores nombrados `COUNT_x=` en la salida, no posiciones); `tests/docker-e2e-vault.bats`: (a) scaffold fresco (arnés actual `:44-47`): tras el boot existe `_templates/.schema-updates-0.27.0.applied` con `deposited: <fecha ISO>` (lo escribe la siembra) pero NO existe `_templates/schema-updates-0.27.0.md` ni línea CANON-D14 (molde `docker-e2e-qmd.bats:249-252` `NO_DELTA`); (b) caso upgrade: antes del primer boot copiar `tests/fixtures/vault-populated/.` a `$DEST/.state/.vault/` (pre-crear `.state/`), arrancar, asertar marcador 0.27.0 con `deposited: <fecha ISO>`, marcador 0.8.0 vacío y exactamente una línea CANON-D14 tras `docker compose restart` (refutación N C4); `tests/docker-e2e-heartbeat.bats`: con `features.heartbeat.review.enabled: true` en el `agent.yml` del arnés, `heartbeatctl reload` dentro del contenedor deja en `/etc/crontabs/agent` (tras el sync loop, `cmp -s`, 15 s) exactamente una línea que contiene `--trigger review` (`grep -c -- '--trigger review' … || true` = 1, nunca `wc -l`: el crontab ya trae líneas en blanco) y `review-prompt.txt` existe; con `false`, 0. Gotchas 033/034 aplicados (`|| true` en `grep -c`, marcadores nombrados, `.state/` pre-creado, `plugins: []`).

**Checkpoint**: aviso opt-in renderizado y validado; e2e escritos; `heartbeat.sh` intacto.

---

## Phase 11: Polish y gates

- [X] T038 Documentación y versión: `README.md` (sección vault: PARA en frontmatter, cola de revisión, packets, favorite problems, aviso semanal opt-in, `qmd-migrate`), `CHANGELOG.md` `### Added` bajo `## [Unreleased]` (una entrada que nombra las nueve piezas y la migración automática única), `VERSION` 0.26.0 → **0.27.0** tras `git show origin/main:VERSION` = 0.26.0, `docs/heartbeatctl.md` (`qmd-migrate`, `review-prompt.txt`, bloques nuevos de `status`, regla del minuto fuera de la rejilla), `modules/next-steps.{en,es}.tpl` (aviso semanal y `qmd-migrate --dry-run`), `specs/014-wiki-graph-rag/contracts/graph-artifacts.md:31-33` (nota: `tags` emitido desde 037, `title` no), el texto caduco "three artifacts" en `scripts/lib/wiki_graph.sh:10,365` (comentarios), `docker/scripts/heartbeatctl:1007` (help), `modules/local-wiki-graph.sh.tpl:4`, `docs/architecture.md:295`, `docs/state-layout.md:160` (no tocar `CHANGELOG.md:891`, histórico), el párrafo de `docs/vault.md` sobre `--exclude .graph/` si T043 entra, y el `CLAUDE.md` del repo: sección "Architecture" gana un párrafo sobre la cola de revisión/PARA y el bloque SPECKIT gana el resumen de 037 **a mano** (nunca vía el hook; memoria `speckit-agent-context-hook-wipes-claude-md`); `git add -f CLAUDE.md` cuando toque commitear.
- [X] T039 Mutación M1-M18 de `quickstart.md` §4 contra la implementación real: aplicar cada una, correr el bats predicho, confirmar RED, revertir, confirmar GREEN; anotar en Notes cuál test cazó cada mutación (si alguna sobrevive, endurecer el oráculo antes de seguir, precedente 034 M6).
- [X] T040 Gates de host (quickstart §1): `bats tests/` en bash 5.x y `PATH=/bin:$PATH bats tests/` en 3.2.57 → 0 `not ok` en ambos, conteos en Notes (esperado: línea base de T001 + los nuevos); `shellcheck -S error` (comando exacto de CI) rc=0; auditoría de bytes = 0 en skeleton, delta, plantillas, `setup.sh`, `heartbeatctl`, bats; `git diff --stat main -- docker/` solo `docker/scripts/heartbeatctl`; `--regenerate` dos veces sobre un workspace fixture pre-037 → byte-idéntico y con los tres bloques nuevos; `git status` muestra solo los archivos previstos (nada bajo `docker/scripts/lib/`, nada en `scripts/heartbeat/`).
- [X] T041 DOCKER_E2E corrido de verdad en este host (imagen `agentic-pod:latest`; rebuild si el Dockerfile lo exige): `DOCKER_E2E=1 bats tests/docker-e2e-qmd.bats tests/docker-e2e-vault.bats tests/docker-e2e-heartbeat.bats` y, por prudencia, `tests/docker-e2e-postlogin.bats` (el crontab cambia); resultados en Notes con la versión de Docker/Compose y de la imagen; cualquier drift del Tier-1 diferido desde 019 se arregla aquí (es el gate que 019 dejó abierto).
- [ ] T042 Gate de hardware antes del merge (quickstart §6; precedente 024). **Bloqueado hoy** por la reautenticación de Cloudflare Access (ferrari: banner timeout el 26-09-2026); cuando el operador la resuelva: conteos previos por agente (`seed_skeleton`, páginas, delta 0.8.0, `project_*`), despliegue en orden (rebuild/regenerate → delta depositado → primer tick migra → `qmd ls`/`status`/`embed` → agente integra), linus (Q4/Q15, SC-006 arranca), mclaren (`--regenerate`, `status`, `qmd-migrate --dry-run`, timers), ferrari vault grande (`time` del runner < 60 s, `wc` de `index.md`/`findings.json`, migración en segundos, Q2 sobre copia). Registrar en Notes con fecha; solo entonces PR.
- [ ] T043 Opcional (medido viable, Q8): `scripts/qmd_watch.sh:77` gana `--exclude '(^|/)\.graph/'` para no disparar un dispatch de reindex por cada corrida del grafo; RED primero en `tests/qmd-watch.bats` (la línea de `inotifywait` invocada contiene `--exclude` y `.graph`), luego GREEN. Solo toca `scripts/qmd_watch.sh` y `tests/qmd-watch.bats`; su párrafo de docs va en T038 (`docs/vault.md` lo editan T017 y T032: por eso no es [P]). Si el tiempo aprieta, dejarlo para 038 y decirlo en el CHANGELOG.

---

## Dependencies & Execution Order

- **Setup (T001-T004)**: T002/T003/T004 en paralelo tras T001.
- **Foundational (T005-T012)**: T005→T006 (schema) y T007→T008 (upgrade) pueden ir en paralelo con T009→T010 (runner) hasta que T010 necesita las plantillas nuevas para el test de "plantilla parsea sin violación"; T011→T012 (config) depende de T010 para `policy.json`.
- **US2 (T014-T017)** antes que T020/T021 (FR-011: la prosa que escribe en `log.md` aterriza después de la higiene). T017 paralelo a T015/T016.
- **US1+US3 (T018-T022)**: T018→T019 depende de T010; T020→T021 depende de T006; T022 depende de T019.
- **US4 (T023-T024)**, **US5 (T025-T026)**, **US6 (T027-T028)**: dependen de T010 y T006; entre sí independientes salvo que editan los mismos dos archivos (skeleton, delta) → secuenciales en la práctica.
- **US7 (T029-T032)**: T029→T030 depende de T008 (marcador con fecha) y T010; T031→T032 independiente (tpl y docs).
- **US8 (T033-T034)**: depende de T019 (lista `LOG`).
- **US9 (T035-T037)**: depende de T012 (claves) y T016 (`cmd_status` ya tocado); T037 paralelo.
- **Polish (T038-T043)**: T038 tras todo lo anterior; T039 y T040 secuenciales; T041 tras T040; T042 tras T041 y del acceso a la flota; T043 opcional en cualquier momento tras T004.

## Parallel Example

```bash
# Tras T001:
T002 golden 014      | T003 fixtures nuevas      | T004 stub qmd
# Foundational (dos frentes):
T005→T006 schema+delta, T007→T008 upgrade        | T009→T010 runner
# Historias P2 (mismo par de archivos de prosa: secuenciar la prosa, paralelizar los tests de runner):
T023 (RED)  T025 (RED)  T027 (RED)  T029 (RED)   → implementaciones en orden T024, T026, T028, T030
# US9:
T035→T036 heartbeatctl   | T037 e2e (escritura)
```

## Implementation Strategy

1. Setup + Foundational → schema, delta, upgrade, runner con columnas y `policy.json`, config: aquí ya se puede desplegar un scaffold nuevo y verlo en 0 hallazgos.
2. US2 (higiene) → primer valor medible sin LLM: el índice deja de tener ruido y los agentes migran solos.
3. US1+US3 → la cola de revisión existe y `status` la muestra: es el MVP de accionabilidad.
4. US4/US5/US6 → navegación, packets, favorite problems (prosa + tres kinds).
5. US7 → el delta se autodenuncia; docs completas.
6. US8/US9 → candidatos y aviso.
7. Polish → docs, VERSION, mutación, gates duales, DOCKER_E2E real, gate de hardware, y solo entonces commit + PR con confirmación del operador.

## Notes

- Línea base T001 (2026-09-28, host, sin Docker): **1502 ok / 0 not ok** en bash 5.3.15 Y en 3.2.57
  (`PATH=/bin:$PATH`) — corridos EN AISLAMIENTO. La primera corrida (ambas suites en paralelo,
  en background) dio 1499/3 en 5.x; los 3 `not ok` (`ensure_plugin_installed_one invokes
  backup-identity on success`, `heartbeat: detects 'Please run /login' banner`, `heartbeat.sh
  writes one runs.jsonl line on success`) son el flake de contención documentado (memoria
  `measure-flakes-before-naming-them`; precedentes 025/027/032) — confirmado 13/13 verde
  corriendo esos tres archivos solos. Conteo estático coincide (1502 `@test`).
  `shellcheck -S error` (comando exacto de CI) rc=0. `git show origin/main:VERSION` = `0.26.0`.
- Golden T002 (2026-09-28): `tests/fixtures/vault-graph.findings.golden.json`, 7 hallazgos exactos
  (orphan 1, broken_link 1, frontmatter_violation 1, index_drift 2, stale 1, alias_occurrence 1),
  sha256 `26f403a028c2b84bb165f3d0b30ebdcd7fdff58b66f5fa05143175863663a26b` (registrado en
  research.md §2). Generado ejecutando `wiki_graph_run` directo sobre la fixture y borrando el
  `.graph/` después; `git status` de la fixture queda limpio.
- T003 (2026-09-28): las tres fixtures nuevas están construidas y verificadas estructuralmente
  contra el parser PRE-037 (21 nodos, 0 broken/violation/drift/stale/alias espurios en
  `vault-graph-para`, matching su propio `README.md`). El oráculo COMPLETO de conteos nuevos
  (project_incomplete=1, project_overdue=1, review_due=2, description_missing=3, pending_ingest=1,
  problem_unfed=2/0, archive_candidate=1/2, schema_delta_pending=1, packets=1, orphans=15,
  edges=8, frontmatter_violations=2) queda documentado en el README de la fixture; se re-verifica
  empíricamente en T009/T010 contra la implementación real y se corrige ahí si diverge (T003 es
  diseño, no ejecución del runner nuevo). Regla de `problem_unfed` sin página que alimente un
  `fp-N`: se usa el `created:` de la propia página `favorite-problems` como piso de "última vez
  tocado" (decisión tomada aquí, no estaba en el contrato; documentada en el README de la fixture).
- T004 (2026-09-28): stub extendido y verificado a mano (marcador de colección, `remove` rc=1 si
  ausente, contador de `cleanup`, `status` con `Total`/`Pending` en tiempo de ejecución, `ls` sobre
  `$QMD_VAULT_DIR` real, `QMD_STUB_FAIL_ONCE` autoconsumido vía marcador de archivo — un proceso
  hijo no puede desexportar la variable del padre, así que el efecto "borra el seam" se logra con
  un fichero de consumo). `bats tests/qmd-*.bats tests/local-qmd.bats tests/start-services-qmd.bats`
  = 83/83 sin regresión.
- **Checkpoint Fase 1 CERRADO.**
- **Checkpoint Fase 2+3 CERRADO (2026-09-28, T005-T017, 16/43 tareas totales).** Prosa del esquema
  0.27.0 (CANON-D1-D7,D10,D11,D15) en skeleton+delta verbatim; delta 0.27.0 en `vault.sh` sobre tres
  estados de vault; núcleo del runner extendido en `wiki_graph.sh` (13 columnas PARA, aristas
  `project`/`area`/`problems`, F1-F5, `project_incomplete`, `policy.json`); superficie de config
  (`vault.review`, `vault.archive`, `features.heartbeat.review`) con backfill `has()` + saneadores;
  US2 higiene qmd completa (máscara `wiki/**/*.md`, sentinel de layout, `qmd_migrate_collection`
  automática-una-vez, `qmd-migrate` en docker/local/agentctl, status/doctor en vivo). Dos bugs reales
  cazados y corregidos antes de commit (migración interrumpida enmascaraba su propio error;
  `local-qmd-reindex.sh.tpl` pasaba mal los argumentos de `--migrate` sin flag). Gate dual en
  corrida LIMPIA (sin edición en paralelo, a diferencia de mediciones parciales previas de esta
  sesión): **1570 ok / 0 not ok, byte-idéntico en bash 5.3.15 Y 3.2.57**
  (`/tmp/037-checkpoint-full5.txt`, `/tmp/037-checkpoint-full32.txt`). `shellcheck -S error` limpio
  en todos los archivos tocados; auditoría de marcas combinantes en cero.
- **Checkpoint Fase 4 CERRADO (2026-09-28, T018-T022, 22/43 tareas totales).** `review_due`,
  `project_overdue`, `pending_ingest` en el runner con aritmética de fechas guardada por
  `isdate()` (un valor malformado dispara solo F4, nunca la aritmética); enumeraciones `RAW`/
  `LOG` fuera de `wiki/`; contenido verificable en las cuatro operaciones + las dos secciones
  diferidas por FR-011 (`## Filing policy` CANON-D8, `## Session close (Hemingway Bridge)`
  CANON-D9, verbatim en skeleton y delta) + la cláusula "primer mensaje" (FR-018) en la
  operación de consulta; `agentctl` local (`status`/`doctor`) con los siete contadores
  canónicos en orden fijo, siempre informativos. Cada conteo predicho (45/14 días, malformado
  → solo F4, `raw_sources/` ausente → `ok`, `TODAY=2030-01-01` → solo el caso `missing`) se
  verificó por ejecución real contra la fixture antes de escribir el test. Gate dual en
  corrida LIMPIA: **1589 ok / 0 not ok, byte-idéntico en bash 5.3.15 Y 3.2.57**
  (`/tmp/037-checkpoint4-full5.txt`, `/tmp/037-checkpoint4-full32.txt`; 1570 + 19 nuevos).
  `shellcheck -S error` limpio; cero marcas combinantes.
- **T037 DOCKER_E2E CORRIDO DE VERDAD (2026-09-28), no solo escrito.** Este host tiene Docker
  29.8.0/Compose v5.5.1. `tests/docker-e2e-qmd.bats` gana el assert de máscara reforzado
  (`--mask wiki/**/*.md` vía `grep -qF`, no glob laxo), un test de migración (índice heredado
  sin sentinel, `heartbeatctl qmd-reindex` directo, orden `remove→add→cleanup` verificado por
  posición de línea en el log del motor) y un test de paridad con `vault-graph-para`
  (`WIKI_GRAPH_TODAY=2030-06-15`, diez contadores vía `jq` nombrados, no posicionales).
  `tests/docker-e2e-vault.bats` gana los casos scaffold-fresco (marcador 0.27.0 fechado, sin
  delta) y upgrade (`vault-populated` preexistente → ambos deltas, 0.8.0 vacío + 0.27.0
  fechado, línea CANON-D14 única y estable tras `restart`). `tests/docker-e2e-heartbeat.bats`
  gana el caso de la línea de revisión real en `/etc/crontabs/agent`.
  **Tres bugs reales cazados por la propia ejecución, ninguno visible en el host suite:**
  (1) `in_container` en el test de la línea de revisión usaba `-u "$AGENT_NAME"` en vez de
  `-u agent` — typo de copia que rompía todo exec posterior al chequeo del crontab; (2) el
  overlay de `vault-graph-para` DESPUÉS del boot competía con el propio `vault_seed_if_empty`
  del contenedor (una carrera real, no simulable en host) — resuelto sembrando el fixture
  ANTES de `docker compose up` (mismo patrón que el caso upgrade) y esperando el símlink
  `/home/agent/vault` (el último paso de la secuencia de arranque) en vez de solo `CLAUDE.md`;
  (3) `qmd_setup_if_needed` y `qmd_reindex` comparten el mismo `.reindex.lock` no bloqueante —
  la migración manual puede perder la carrera contra el chequeo de arranque en background y
  salir 0 sin migrar nada ese tick (exit 91 interno, envuelto a 0 por diseño fail-silent);
  mitigado con un reintento de hasta 45s hasta que `collection remove` aparece en el log,
  reduciendo la tasa observada de fallo de ~2/3 a ~1/7 corridas. **Esta última no quedó en
  cero**: es una característica de contención del entorno Docker Desktop (mismo patrón que
  los "flakes de contención" ya documentados en el host suite), medida y declarada, no
  ocultada — cada corrida real de esta sesión (incluida la última, 9/9 con los cuatro
  archivos completos) pasó limpia. Gate final: `DOCKER_E2E=1 bats tests/docker-e2e-qmd.bats
  tests/docker-e2e-vault.bats tests/docker-e2e-heartbeat.bats` → **9/9**.
- **Checkpoint Fase 10 CERRADO (2026-09-28, T035-T037, 37/43 tareas totales).** Aviso semanal
  opt-in (docker, `_v_cron5`, prompts localizados CANON-H1/H2 sin tildes, `heartbeatctl status`
  con los siete contadores) + DOCKER_E2E real en los tres archivos (qmd/vault/heartbeat), tres
  bugs reales cazados y corregidos (ver nota T037 arriba). Gate dual en corrida LIMPIA:
  **1642 ok / 0 not ok, byte-idéntico en bash 5.3.15 Y 3.2.57**
  (`/tmp/037-checkpoint-t037-full5.txt`, `/tmp/037-checkpoint-t037-full32.txt`; 1638 + 4 nuevos:
  3 en heartbeatctl.bats/local-render.bats de superficie + 1 en heartbeat-runs-jsonl.bats).
- **Gate T040 CERRADO (2026-09-28).** `bats tests/` en bash 5.3.15 y `PATH=/bin:$PATH bats tests/`
  en 3.2.57: 0 `not ok` en ambos (línea base 1638 + T038's cero tests nuevos, doc-only). `shellcheck
  -S error` (comando exacto de CI) rc=0. Auditoría de bytes = 0 (`LC_ALL=C grep -rc $'\xcc\x80'`)
  en skeleton, delta, plantillas, `setup.sh`, `heartbeatctl`, bats y en `CLAUDE.md` del repo tras
  T038. `git diff --stat main -- docker/` sigue tocando solo `docker/scripts/heartbeatctl`.
  `--regenerate` corrido dos veces sobre un workspace fixture pre-037: byte-idéntico entre pasadas,
  con los tres bloques nuevos (schema delta, aviso semanal, migración qmd) presentes. `git status`
  muestra únicamente los archivos previstos por el plan — nada bajo `docker/scripts/lib/`, nada en
  `scripts/heartbeat/`.
- **RE-VERIFICACIÓN T040 tras T039 (2026-09-28).** Las 18 mutaciones tocaron seis archivos de
  producción de forma transitoria (`wiki_graph.sh`, `qmd_index.sh`, `vault.sh`, `heartbeatctl`,
  `setup.sh`, `agentctl`), cada una revertida a mano antes de seguir — gate completo repetido
  para confirmarlo. Bash 5.3.15: **1643 ok / 1 not ok** — el rojo es
  `tests/heartbeat-auth-detection.bats:88` ("detects 'API Error: 401'..."), el flake de
  contención YA documentado en este archivo (precedentes 025/027/032/033/034); medido en
  aislamiento antes de nombrarlo (memoria `measure-flakes-before-naming-them`): **5/5 limpio**
  corriendo solo ese archivo. Bash 3.2.57: **1644 ok / 0 not ok**, byte-idéntico en conteo total
  (1642 base de T037 + 2 tests nuevos endurecidos por T039: uno en `regenerate.bats` para M15,
  uno en `vault-upgrade.bats` para M17 — M5 solo agregó aserciones dentro de un `@test`
  existente, sin sumar al conteo). `shellcheck -S error` sobre los seis archivos tocados
  durante las mutaciones, rc=0 tras el revert final. `git status`: limpio salvo los 3 archivos
  de test endurecidos + este archivo — ningún archivo de producción quedó con diferencias
  respecto a lo commiteable de T001-T038.
- **Gate T041 CERRADO (2026-09-28).** Docker 29.8.0 / Compose v5.5.1, imagen `agentic-pod:latest`
  reconstruida sobre el Dockerfile de la rama. `DOCKER_E2E=1 bats tests/docker-e2e-qmd.bats
  tests/docker-e2e-vault.bats tests/docker-e2e-heartbeat.bats` → 9/9 (detalle de los tres bugs
  reales cazados y corregidos en la nota de T037 arriba). Por prudencia, `tests/docker-e2e-postlogin.bats`
  también corrido de verdad → 2/2, sin drift (el crontab cambió por el aviso semanal y por
  `qmd-migrate`, y el Tier-1 diferido desde 019 sigue verde).
- **T039 CERRADO (2026-09-28). Mutación M1-M18 corrida de verdad contra la implementación
  real (apply → RED → revert → GREEN, cada una), no simulada. 15/18 cazadas de inmediato por
  el oráculo ya existente; 3 sobrevivieron a la primera pasada y el oráculo se endureció antes
  de seguir (precedente 034 M6), quedando las 18 verdes al cierre:**
  - M1 (quitar la rama `para` del awk): 11 tests caen, incluido "F1-F5 frontmatter violations
    present with their page" (`para: invalid 'projet'`) — exactamente la forma predicha.
  - M2 (invertir `fpara`/`description_present` en el `print` de `N` sin tocar el jq): 13 tests
    caen, incluido "golden 014 fixture is byte-identical... all 12 new counts are 0" — la
    predicción de "findings distintos sobre el golden" se confirmó tal cual.
  - M3 (quitar `.para!="archive"` de `$f_orphan`): cae exactamente "para: archive is excluded
    from orphan and stale (suppression)".
  - M4: el diseño real ya no tiene una columna `para` en `SRCN` (`$paraOf` se arma desde
    `$nodes`, no desde el TSV `SRCN` — el runner evolucionó desde el plan). Mutación
    equivalente aplicada sobre `$paraOf` (mapear todo a `"resource"`, perdiendo la señal de
    archivo): cae el mismo test de suppression que M3.
  - **M5 SOBREVIVIÓ a la primera pasada** — emitir la arista `project:` como `wikilink` en vez
    de `related` no rompe ningún test porque `backlinks.json` cuenta ambos kinds igual y
    ningún test miraba el `kind` crudo de esa arista en `graph.json`. Oráculo endurecido:
    `tests/wiki-graph.bats` "related edges from project:/area:/problems:" gana dos aserciones
    directas de `.kind` sobre `graph.json` (project: y area:) — re-verificado RED con la
    mutación activa, luego GREEN al revertir.
  - M6 (usar `date -u +%F` real en vez de `WIKI_GRAPH_TODAY`): caen 5 tests de fecha
    (review_due, project_overdue, favorite problems, delta pending, archive candidates).
  - M7 (cleanup antes de add en `qmd_migrate_collection`): cae el test de orden por posición
    de línea en `tests/qmd-index.bats`.
  - M8 (sentinel antes de add): cae "interrupted migration (add fails once) leaves sentinel
    absent...".
  - M9 (máscara `**/*.md` en el `collection add` de setup fresco): cae "fresh setup masks to
    wiki/\*\*/\*.md and writes the layout sentinel".
  - M10 (plantillas nuevas en la sección 2 del bloque 0.8.0 en vez del bloque 0.27.0): cae el
    test que ya lleva "(M10)" en su propio nombre en `vault-upgrade.bats` — escrito para esta
    mutación específica en T008/T017.
  - M11 (marcador 0.27.0 vacío): caen 4 tests de `vault-upgrade.bats` (deposited:, no-op del
    segundo run, los dos casos de fixture).
  - M12 (bypass de `_v_cron5`): cae "invalid schedules WARN naming the key, line absent...".
  - M13 (default `0 9 * * 1` en vez de `7 9 * * 1`): cae "enabled with default schedule — line
    + prompt file with VAULT_DIR substituted".
  - M14 (borrar el heading `## Actionability (PARA)` del skeleton, CANON-D1): caen los dos
    tests predichos en `vault.bats` (conteo de presencia + verbatim delta↔skeleton).
  - **M15 SOBREVIVIÓ a la primera pasada** — la traducción literal de "backfill con `//` en
    vez de `has()`" no rompía nada porque jq's `//` solo trata `null`/`false` como falsy, y
    ningún test preexistente usaba un valor `false`/`0` explícito como preexistente (solo
    `true` y `14`, ambos truthy para `//`). Se replicó el hazard REAL: reemplazar el guard
    `has("review")` por un chequeo `.enabled // "MISSING"` — que SÍ colapsa un `enabled: false`
    explícito del operador, arrastrando su `schedule` personalizado de vuelta al default.
    Oráculo endurecido: nuevo test en `tests/regenerate.bats` ("preserves an operator's
    explicit enabled:false + custom schedule (M15)") — RED con la mutación, GREEN al revertir.
  - M16 (`_doctor_warn` cuando `review_due>0` en vez de `_doctor_pass`): cae exactamente el
    test marcado "(T022)" en `agentctl-local.bats`.
  - **M17: SIN ORÁCULO PREEXISTENTE** — la medición "200/200 con 3.000 páginas" del research
    nunca se convirtió en un test commiteado. Reproducir la carrera SIGPIPE resultó sensible
    a la escala real en ESTE host: 3.000 archivos vacíos NO la disparó (0/5), 10.000 archivos
    con nombres más largos SÍ, de forma reproducible (8/8 aislado, 5/5 end-to-end contra
    `vault_seed_missing` una vez aislada `has_pages27` de `changed27` — el probe inicial daba
    falso negativo porque `entity-project.md`/`overview-area.md` ausentes ya disparaban
    `changed27=1` por su cuenta, enmascarando la señal). Nuevo test commiteado en
    `vault-upgrade.bats` ("has_pages27 stays reliable under pipefail on a large populated
    wiki", `set -o pipefail` explícito vía `bash -c`, 10.000 archivos, ~1.2s) — RED con la
    forma vulnerable (`find | head -1 | grep -q .`), GREEN con la forma real (`-print -quit`).
    Confirmado en bash 5.3.15 Y 3.2.57 (17/0 en ambos).
  - M18 (sentinel de layout en el camino común en vez de dentro de la rama `add`): cae
    exactamente "re-entrant setup (index present, sentinel absent) does NOT write the layout
    sentinel".
  Cada mutación se aplicó sobre el archivo REAL (nunca una copia), se confirmó RED, se revirtió
  con una edición exacta inversa, y se confirmó GREEN antes de pasar a la siguiente — ninguna
  quedó aplicada. `git status` al cierre: limpio salvo los 3 archivos de test endurecidos
  (`wiki-graph.bats`, `regenerate.bats`, `vault-upgrade.bats`) más este archivo; `shellcheck -S
  error` sobre los seis archivos de producción tocados durante las mutaciones (`wiki_graph.sh`,
  `qmd_index.sh`, `vault.sh`, `heartbeatctl`, `setup.sh`, `agentctl`) rc=0 tras el revert final.
- **T038 CERRADO (2026-09-28).** `README.md`, `CHANGELOG.md` (`### Added` bajo `## [Unreleased]`,
  nueve piezas + migración automática única), `VERSION` 0.26.0→**0.27.0** (verificado
  `git show origin/main:VERSION` = 0.26.0 antes del bump), `docs/heartbeatctl.md` (`qmd-migrate`,
  `review-prompt.txt`, `logs/review.log`, bloque `wiki-graph:` de `status`, regla del minuto fuera
  de la rejilla), `modules/next-steps.{en,es}.tpl` (aviso semanal + `qmd-migrate --dry-run` en los
  TRES bloques de comandos de cada archivo — docker "manual actions", docker "quick reference" y
  local RAG — EN y ES, 88/0 en `docker-render.bats`+`local-render.bats`+`quickstart-doc.bats` tras
  el cambio), `specs/014-wiki-graph-rag/contracts/graph-artifacts.md:37-45` (nota: `tags` sale real,
  `title` nunca como texto — solo `title_present`), los cinco sitios con el texto caduco "tres
  artefactos" (`scripts/lib/wiki_graph.sh:10`, `docker/scripts/heartbeatctl:1205`,
  `modules/local-wiki-graph.sh.tpl:4`, `docs/architecture.md:295`, `docs/state-layout.md:162-163`)
  corregidos a los cinco reales — `CHANGELOG.md:937` (entrada histórica de 014) se dejó INTACTO a
  propósito, nunca se reescribe historia. `docs/vault.md` ya tenía su párrafo de config 037 y las
  4 claves legacy muertas desde el checkpoint de la Fase 8; T043 no entró en esta rama, así que no
  hubo párrafo de `--exclude .graph/` que agregar. `CLAUDE.md` del repo gana una subsección nueva
  "Wiki-graph PARA review queue (037)" en Architecture (entre "Heartbeat data contract" y
  "Workspace-is-the-agent") y el resumen histórico completo de 037 en el bloque SPECKIT, escrito
  A MANO (nunca vía el hook — memoria `speckit-agent-context-hook-wipes-claude-md`), prependido
  antes de la entrada de 034; auditoría de marcas combinantes = 0, UTF-8 válido. `git add -f
  CLAUDE.md` queda pendiente para el momento del commit (el archivo está gitignoreado a nivel de
  regla, no de contenido).
- Gate de hardware T042: **bloqueado** por reautenticación de Cloudflare Access (ferrari `banner exchange timeout` 26-09-2026); no mergear sin él (precedente 024).
- Decisiones del operador que cambiaron durante el plan: migración de colección **automática, una vez** (2026-09-27; antes "explícita"), forma del aviso (entrada semanal aparte), "sin pendientes", umbrales, loops por el runner (clarify 2026-09-26).
