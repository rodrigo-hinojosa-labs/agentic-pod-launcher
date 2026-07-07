# Tasks: Wiki-grafo RAG agéntico — grafo derivado, normalización y mantenimiento determinista

**Feature**: `014-wiki-graph-rag` | **Branch**: `014-wiki-graph-rag`
**Input**: spec.md (5 US), plan.md (D1-D16), research.md (R1-R13), data-model.md, contracts/ (4), quickstart.md
**Disciplina**: test-first (Principle III) — cada tarea de comportamiento tiene su test bats ANTES de la implementación.

## Phase 1: Setup (fixtures)

- [ ] T001 [P] Crear fixture de grafo en `tests/fixtures/vault-graph/`: vault con páginas interconectadas y casos conocidos — 1 huérfano, 1 wikilink roto, 1 página con frontmatter inválido, drift bidireccional de `index.md` (entrada sin archivo + archivo sin entrada), 1 página stale (source con mtime posterior a `updated:`), wikilinks en formas `[[t|d]]` y `[[t#a]]`, fenced code block con un wikilink y un alias que NO deben contar. Incluir `README.md` del fixture con el inventario exacto de hallazgos esperados (oráculo de SC-001).
- [ ] T002 [P] Crear fixture de upgrade en `tests/fixtures/vault-populated/`: vault poblado con contenido en las 6 carpetas de `wiki/`, `CLAUDE.md` customizado (distinto del skeleton), `log.md` con entradas previas, SIN `wiki/normalization/` — oráculo de SC-005.

## Phase 2: Foundational (bloquea todas las US)

- [ ] T003 VALIDACIÓN de schema, NO defaults (M7), en `scripts/lib/schema.sh`: agregar `.vault.wiki_graph.enabled` a `_SCHEMA_BOOLEANS` y `.vault.wiki_graph.schedule` a `_SCHEMA_OPTIONAL_NONEMPTY` (patrón `.vault.qmd.*`; schema.sh solo valida forma, NO fija valores) + tests en `tests/schema.bats`, incluyendo agregar `WIKI_GRAPH_ENABLED`/`WIKI_GRAPH_SCHEDULE` a AMBOS arrays `known_external` (~:62 y ~:114 — único touchpoint real, M8).
- [ ] T004 Precompute de render vars `WIKI_GRAPH_ENABLED`/`WIKI_GRAPH_SCHEDULE` en `setup.sh` (patrón VAULT_MCP_PATH, D12) — AQUÍ vive el default real (M7): `enabled` condicionado a `vault.enabled`, `schedule` con fallback `20 */6 * * *`; mismos fallbacks yq `//` en los sitios de consumo. NO tocar `wizard_answers` ni el array de `e2e-smoke.bats` (son respuestas a prompts; 014 no agrega prompt — M8).

**Checkpoint**: fixtures listos + config única en `agent.yml` → las US pueden arrancar.

## Phase 3: US1 — Grafo derivado determinista (P1) — MVP

**Goal**: derivar grafo + backlinks + hallazgos estructurales de toda la wiki, sin LLM, sin editar jamás la wiki.
**Independent test**: `bats tests/wiki-graph.bats` sobre el fixture → exactamente los hallazgos del inventario; skeleton limpio → 0.

- [ ] T005 [P] [US1] Tests RED del parser/grafo en `tests/wiki-graph.bats`: nodos tipados desde frontmatter, aristas `wikilink`/`related`/`source`, `backlinks`/`co_sourced` en backlinks.json, resolución de `[[t|d]]`/`[[t#a]]`, exclusión de fences y de `index.md`/`log.md`/`_templates/`/`raw_sources/`/`.graph/`. NORMALIZACIÓN de valores (H4): `related: ["[[concepts/x]]"]` → arista a `concepts/x` (no broken); `sources: ["raw_sources/x.md"]` → path sin comillas; sin strip habría broken_links espurios. Campo requerido vacío `title: ""` NO es violación (L6). Extracción de entradas de `index.md` (H3): excluir comentarios HTML, backticks y `<…>` → el `index.md` del fixture con tokens `[[…]]` en prosa NO genera `index_drift`.
- [ ] T006 [P] [US1] Tests RED de hallazgos en `tests/wiki-graph.bats`: exactitud contra el inventario del fixture (`broken_link`, `frontmatter_violation`, `index_drift`, `orphan`, `stale` — 0 falsos +/−), skeleton limpio → 0 hallazgos, página malformada NO aborta ni omite el resto, orden estable de `findings.json`, ninguna página de `wiki/`/`raw_sources/` modificada tras la corrida (hash antes/después). HUÉRFANO (H2): un `related:` entrante NO recíproco hace NO-huérfana a la página destino (related cuenta siempre como backlink). STALE (L4): solo páginas `status: active`.
- [ ] T007 [P] [US1] Tests RED de artefactos/estado en `tests/wiki-graph.bats`: escritura atómica (sin `.tmp` residual en nombre final), `wiki-graph.json` schema 1 con `last_status` ∈ {`ok`,`error`} (NO existe `locked`), `counts` == findings de la misma corrida, vault inaccesible → `last_status=error` + exit 0 + artefactos previos intactos, lock flock — el perdedor sale 91 y NO escribe state (skip en host sin flock — precedente `qmd-setup.bats`), y aserción L1: `! find <vault>/.graph -name '*.md'` (invariante no-`.md`).
- [ ] T008 [US1] Implementar `scripts/lib/wiki_graph.sh`: `wiki_graph_enabled` (yq gating), `wiki_graph_vault_dir` (overrides `WIKI_GRAPH_VAULT_DIR`/`VAULT_ROOT_OVERRIDE`), `wiki_graph_run` (extracción awk per-file por lotes con normalización de valores H4 + agregación jq, contrato graph-artifacts.md), artefactos atómicos bajo `<vault>/.graph/`, state file (`ok`/`error`, sin `locked`), flock en `<ws>/scripts/heartbeat/.wiki-graph.lock` (perdedor sale 91 sin escribir state), guard `BASH_SOURCE`, shellcheck limpio → GREEN T005-T007.

**Checkpoint US1**: el grafo existe y es correcto — MVP demostrable con la lib sola.

## Phase 4: US2 — Capa de normalización (P1)

**Goal**: `wiki/normalization/` declara canonical+aliases; el linter detecta ocurrencias; el ingest escribe capa 2 canónica.
**Independent test**: regla `Cencosud`/`[SENCOSUD]` + página con "SENCOSUD" → hallazgo `alias_occurrence` exacto.

- [ ] T009 [P] [US2] Tests RED de normalización en `tests/wiki-graph.bats`: `alias_occurrence` con word-boundary (SENCOSUDESTE no matchea), case-insensitive default y `match_case: true`, fenced code excluido, `wiki/normalization/` excluida del escaneo, arista `alias`→entity + `canonical_of` en backlinks.json, validación del frontmatter propio (`canonical`/`aliases` requeridos no vacíos, `type:` prohibido, alias duplicado en dos reglas → `frontmatter_violation` en ambas — contrato normalization-pages.md).
- [ ] T010 [US2] Extender `scripts/lib/wiki_graph.sh` con escaneo de aliases y validación de páginas de normalización → GREEN T009.
- [ ] T011 [P] [US2] Skeleton: `modules/vault-skeleton/wiki/normalization/.gitkeep` + `modules/vault-skeleton/_templates/normalization.md` (frontmatter del contrato) + sección `## Normalization` en `modules/vault-skeleton/index.md` + test de seed en `tests/vault.bats` (la carpeta y el template llegan al vault sembrado; L2: aserción de que el `CLAUDE.md` sembrado contiene los marcadores del paso `2.5 Normalize` y del paso de query con `.graph/backlinks.json`).
- [ ] T012 [P] [US2] Schema del skeleton (scaffolds nuevos): paso `2.5 Normalize terminology` en el protocolo ingest de `modules/vault-skeleton/CLAUDE.md` (consultar `wiki/normalization/`, capa 1 VERBATIM, capa 2 canónica, proponer regla nueva ante error recurrente) + descripción de la capa en la sección de estructura y de page types (aclarando que normalization está FUERA de los 6 types).

**Checkpoint US2**: SENCOSUD→Cencosud declarable, detectable y aplicable en ingest.

## Phase 5: US3 — Retrieval graph-aware + acción manual (P2)

**Goal**: el protocolo query usa vecinos a 1 salto; el operador regenera el grafo on-demand en ambos modos.
**Independent test**: schema documenta el flujo; `agentctl heartbeat wiki-graph` refresca grafo y state en ambos modos (local con stubs, docker en e2e).

- [ ] T013 [P] [US3] Schema del skeleton: protocolo query con paso "consultar `.graph/backlinks.json` para vecinos a 1 salto (backlinks + related + co_sourced + canonical_of) antes de sintetizar, citando vecinos usados" + nota de que el lint estructural corre determinístico (el lint agéntico se concentra en contradicciones) en `modules/vault-skeleton/CLAUDE.md`.
- [ ] T014 [P] [US3] Tests RED de acción manual local en `tests/agentctl-local.bats`: caso `wiki-graph` en `cmd_local_heartbeat` — exec directo del wrapper/lib sin systemctl, state file fresco tras la corrida.
- [ ] T015 [US3] Implementar caso `wiki-graph` en `cmd_local_heartbeat` de `scripts/agentctl` → GREEN T014.
- [ ] T016 [US3] Subcommand `wiki-graph` en `docker/scripts/heartbeatctl` (carga `wiki_graph.sh`, corre `wiki_graph_run`, imprime resumen de counts; help actualizado) + tests en `tests/heartbeatctl.bats` (overrides `HEARTBEATCTL_*` existentes).
- [ ] T017 [US3] Espejado docker de la lib: línea `cp` en `setup.sh::mirror_catalog_to_docker` + `COPY scripts/lib/wiki_graph.sh` en `docker/Dockerfile` + drift-guard en `tests/docker-render.bats` (los 3 puntos juntos — gotcha COPY explícito).

**Checkpoint US3**: grafo consultable por el agente y regenerable on-demand con paridad de semántica.

## Phase 6: US4 — Mantenimiento automático agnóstico al modo (P2)

**Goal**: corrida programada en ambos modos + integración operacional completa (kill-switch, healthcheck, status/doctor, NEXT_STEPS).
**Independent test**: renders contienen las entradas nuevas; stubs systemd demuestran kill-switch/healthcheck/doctor.

- [ ] T018 [P] [US4] Tests RED de render local en `tests/local-wiki-graph.bats`: wrapper con `export PATH` como PRIMERA acción + `VAULT_ROOT_OVERRIDE`/`WIKI_GRAPH_VAULT_DIR` + exit 0 incondicional; unit/timer `agent-<name>-wiki-graph.{service,timer}` con OnCalendar derivado del schedule; marker `wiki-graph-schedule.fallback` persistente cuando `cron_to_systemd_calendar` cae al fallback (mecanismo CRON_FALLBACK 013).
- [ ] T019 [US4] Crear `modules/local-wiki-graph.{sh,service,timer}.tpl` + render/staging en `setup.sh` (modo local, gated por `WIKI_GRAPH_ENABLED`) + instalación en `modules/local-login.sh.tpl` (incluye staged pendientes, flujo 012/013) → GREEN T018.
- [ ] T020 [US4] Línea staged de cron docker en `docker/scripts/heartbeatctl` (patrón `qmd_reindex_line`:265-272, gated por `wiki_graph_enabled`, log a `logs/wiki-graph.log`) + test en `tests/heartbeatctl.bats` de que `.crontab.staging` la contiene con el schedule de `agent.yml`.
- [ ] T021 [P] [US4] Kill-switch: `AUX_UNITS` += `agent-${AGENT_NAME}-wiki-graph.timer` en `modules/local-killswitch.sh.tpl` + test en `tests/local-killswitch.bats`.
- [ ] T022 [P] [US4] Healthcheck local: WARN si `systemctl is-failed --quiet agent-<name>-wiki-graph.service` (self-gating, unit ausente = no-op) en `modules/local-healthcheck.sh.tpl` + test con stub en `tests/local-healthcheck.bats`.
- [ ] T023 [US4] Status/doctor local en `scripts/agentctl`: bloque `Wiki graph` en `_local_vault_qmd_status` (frescura + counts + marker fallback `wiki-graph-schedule.fallback`) + contrato Q5 en `_local_vault_qmd_doctor` (WARN: `broken_links`/`frontmatter_violations`/`index_drift` > 0 o `last_status=error`; FAIL: state ausente o `last_run` > 2× intervalo; integrado a exit codes 0/1/2 de `cmd_local_doctor`) + tests en `tests/agentctl-local.bats`, incluyendo el parser de intervalo (M6): `20 */6 * * *` → 6 h (FAIL a 12 h), forma no reconocida → 24 h.
- [ ] T024 [P] [US4] NEXT_STEPS: bloques de operación wiki-graph en `modules/next-steps.en.tpl` y `modules/next-steps.es.tpl` (bloques hermanos gated por `WIKI_GRAPH_ENABLED`, sin `{{#if}}` anidado; local: journalctl/list-timers/acción manual; docker: heartbeatctl + tail del log) + test de render en `tests/scaffold.bats`.

**Checkpoint US4**: el grafo se mantiene solo y la operación es honesta en ambos modos.

## Phase 7: US5 — Upgrade aditivo para vaults existentes (P3)

**Goal**: ferrari/mclaren reciben la estructura nueva sin perder un byte de contenido.
**Independent test**: fixture poblado → estructuras nuevas + 0 hashes cambiados + idempotencia.

- [ ] T025 [P] [US5] Tests RED de upgrade en `tests/vault-upgrade.bats` sobre `tests/fixtures/vault-populated/`: estructuras nuevas creadas (`wiki/normalization/` + template), CERO archivos preexistentes modificados (hash antes/después), `CLAUDE.md` byte-idéntico, delta `_templates/schema-updates-0.8.0.md` depositado + marcador oculto `.schema-updates-0.8.0.applied` + entrada en `log.md`, 2ª corrida no-op total (sin duplicados en log), **caso C1**: borrar el delta `.md` y re-correr → NO se re-deposita ni duplica log (el sentinel es el marcador oculto), regla fresh-scaffold (vault recién sembrado del skeleton → SIN delta ni log entry), fail-silent con vault read-only (warning + return 0).
- [ ] T026 [US5] Implementar `vault_seed_missing TARGET SKELETON DELTAS_DIR [TODAY]` en `scripts/lib/vault.sh` (contrato vault-additive-upgrade.md: lista explícita de estructuras, jamás sobreescribe, jamás toca CLAUDE.md, **sentinel = marcador oculto `_templates/.schema-updates-0.8.0.applied`, NO la existencia del delta borrable — C1**) → GREEN T025.
- [ ] T027 [P] [US5] Crear `modules/vault-deltas/schema-updates-0.8.0.md`: secciones nuevas del schema (capa normalización, paso 2.5 ingest, query con `.graph/`, lint determinista) en el tono del skeleton, con instrucción de integración al CLAUDE.md del vault y nota de que borrarlo es seguro (M9: este contenido DUPLICA el del skeleton T012/T013 — designar el skeleton como fuente canónica y anotar aquí que ambos deben editarse juntos si el schema cambia).
- [ ] T028 [US5] Triggers del upgrade: llamada a `vault_seed_missing` en `docker/scripts/start_services.sh::seed_vault_if_needed` (tras la rama `vault_seed_if_empty`, contexto usuario `agent` — NO en `entrypoint.sh`, que no toca el vault; H5), en `modules/local-login.sh.tpl` y en `setup.sh --regenerate` (si `vault.enabled` y vault existente) + `COPY modules/vault-deltas/` en `docker/Dockerfile` + tests de trigger en `tests/vault-upgrade.bats` (host paths) y drift-guard del COPY en `tests/docker-render.bats`.

**Checkpoint US5**: feature desplegable a los agentes reales sin `backup_and_reseed`.

## Phase 8: Polish & gates

- [ ] T029 DOCKER_E2E: fase wiki-graph en `tests/docker-e2e-qmd.bats` (mismo boot, D16): línea `wiki-graph` en `/etc/crontabs/agent`, `heartbeatctl wiki-graph` genera `.graph/*.json` + `wiki-graph.json` con `last_status: ok`, `vault_seed_missing` en boot no modifica contenido preexistente (y no re-deposita el delta en 2º boot — C1), `cap_drop: ALL` intacto. PARIDAD (M1/SC-003): montar `tests/fixtures/vault-graph/` en el contenedor, correr el runner y verificar que `findings.json`/counts coinciden con el oráculo host (mismo inventario de SC-001) — cubre la divergencia potencial de awk BSD/GNU entre modos.
- [ ] T034 [P] Fixture de complejidad (M2/R13/SC-006): generador de ~100 páginas wiki interconectadas en `tests/fixtures/` (o helper que lo cree en tmpdir) + test en `tests/wiki-graph.bats` que corre el runner sobre él y asegura una sola pasada awk + una agregación jq (guard contra O(n²) por página, p. ej. asertando que no hay loop bash per-file). Único guardrail automatizado de SC-006 (el gate de 1.000 páginas < 60 s queda en el manual T033).
- [ ] T030 [P] Docs: `docs/vault.md` (capa normalización + `.graph/` + protocolos actualizados), `docs/architecture.md` (párrafo 014), `docs/heartbeatctl.md` (subcommand `wiki-graph`).
- [ ] T031 [P] `CHANGELOG.md` entrada 014 + `VERSION` 0.7.0 → 0.8.0.
- [ ] T032 Gate 1 completo: `bats tests/` verde (suite completa, sin regresiones) + `shellcheck -S error` limpio global (quickstart Gate 1) y Gate 2: `DOCKER_E2E=1` qmd+vault verdes (quickstart Gate 2).
- [ ] T033 Gate manual en hardware real (quickstart Gates 3-4, apilado con los gates 013 pendientes): mclaren (upgrade aditivo sobre vault real, timer activo, doctor exit codes, kill-switch, SC-006, SC-007) y ferrari (seed_missing en boot, línea de cron, grafo de la wiki real, query con vecinos vía Telegram, Syncthing sin conflictos) — DIFERIDO a disponibilidad de hosts.

## Dependencies

```text
Setup:        T001, T002                    (paralelos)
Foundational: T003 → T004                   (T004 usa los defaults de T003)
US1:  T005,T006,T007 (P, RED) → T008        (requiere T001; T003 para gating)
US2:  T009 (RED) → T010 (requiere T008)     |  T011, T012 (P, independientes de la lib)
US3:  T013 (P)  |  T014 → T015  |  T016 → T017   (T016 requiere T008)
US4:  T018 (RED) → T019 (requiere T004)  |  T020 (requiere T016)  |  T021, T022 (P)
      T023 (requiere T008)  |  T024 (requiere T004)
US5:  T025 (RED, requiere T002) → T026 → T028  |  T027 (P)
Polish: T029 (requiere US3+US4+US5 docker) → T032 → T033
        T030, T031 (P, en cualquier momento post-diseño estable)
        T034 (P, requiere T008 — guard de complejidad SC-006)
```

Orden de historias: US1 → US2 (extiende la lib) → US3/US4/US5 (independientes entre sí una vez que US1 existe; US3 y US4 comparten heartbeatctl: T016 antes de T020).

## Parallel execution examples

- **Arranque**: T001 + T002 en paralelo; luego T003.
- **US1 RED**: T005 + T006 + T007 se escriben en paralelo (mismo archivo de tests, secciones distintas — coordinar en un solo commit RED).
- **Post-US1**: T009 (US2), T013 (US3), T018 (US4), T025 (US5) pueden arrancar en paralelo — archivos distintos.
- **Cierre**: T030 + T031 en paralelo con T029.

## Implementation strategy

**MVP = US1 + US2** (ambas P1): con la lib y la normalización ya hay valor demostrable
(grafo correcto + SENCOSUD→Cencosud detectable) sin tocar scheduling ni upgrade. Luego
US3 (consumo agéntico), US4 (automatización + ops), US5 (despliegue a agentes reales),
Polish (e2e + docs + versión). Cada checkpoint deja la suite host verde; el DOCKER_E2E
se corre al cierre (T029/T032) y ante cualquier cambio de `docker/` intermedio.
