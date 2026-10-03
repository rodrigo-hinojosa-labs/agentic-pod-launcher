# D — Historia de las specs del RAG (010 → 019): decisiones tomadas y alternativas rechazadas

**Propósito.** Extraer de las specs históricas del subsistema vault/RAG las decisiones ya tomadas, las alternativas explícitamente rechazadas, la deuda declarada, el estilo de criterios de éxito y los gates exigidos, para que la feature 037 (LLM Wiki + Second Brain) no re-litigue nada ya cerrado.

**Alcance.** `specs/{010,012,013,014,016,017,018,019}-*/{spec,research,plan}.md`, sus `tasks.md`/`quickstart.md`/`contracts/` cuando aportaban deuda o gates, `CHANGELOG.md` (entradas de esas features), `docs/vault.md`, `docs/qmd-upgrade-checklist.md`, `modules/vault-skeleton/*`, `modules/vault-deltas/*` y el historial git de los PR #13/#16 (skeleton pre-spec-kit). Fecha de lectura: 22-09-2026, rama `main` en `70214d9`.

**Convención de evidencia.** `[V]` = hecho verificado (archivo:línea, comando o commit). `[I]` = inferencia mía a partir de lo leído. Cuando un ítem no consta en ninguna fuente lo digo con `Sin registro`.

---

## Resumen ejecutivo

- El vault Karpathy nació **antes de spec-kit** (PR #13, 27-04-2026, `1915fc2`) sin spec formal; sus reglas de diseño viven en `modules/vault-skeleton/CLAUDE.md` y `docs/vault.md` (PR #16). Las ocho features posteriores (010 → 019, del 28-06-2026 al 12-07-2026) **no rediseñaron el esquema del wiki**: automatizaron QMD (010), lo portaron a local (012/013), derivaron el grafo + normalización + lint determinista (014) y pelearon tres muros nativos de Alpine musl (016/017/018) más un drift de tests (019). `[V]` tabla §1.
- Decisiones **ratificadas con la marca "no reabrir"**: grafo derivado a JSON bajo `<vault>/.graph/` (no servidor de grafos), "the only six" tipos de página (la normalización entró como carpeta-convención, NO como séptimo `type`), derivados regenerables jamás respaldados, `agent.yml` como única fuente con defaults precomputados en `setup.sh`, libs espejadas con `COPY` explícito, fail-silent en entrypoints con honestidad en `doctor`, pin qmd 2.5.3 single-source, 1 agente por host en local. `[V]` §2.7.
- Alternativas rechazadas con nombre y razón: skill `/vault:ingest|query|lint` (`docs/vault.md:542-556`), Neo4j o similar (`specs/014/spec.md` §Decisión de arquitectura), base glibc y embeddings remotos (016 clarify; 018 los llama "explicitly rejected in prior work"), parchear el motor qmd (018), runner en bun/JS (014 R2), append directo al `CLAUDE.md` del vault (014 R7), pre-hornear el modelo en la imagen (010 D3), hook agéntico de reindex (010 D6), `systemd --user`, cron parser completo, claves paralelas por modo (012). `[V]` §2.
- Deuda RAG que **sigue abierta al 22-09-2026**: `status`/`doctor` docker no reportan QMD ni wiki-graph (declarada en 013, verificada hoy en `docker/scripts/heartbeatctl::cmd_status`), stderr del watcher docker a `/dev/null`, retry de setup docker solo al boot, lint agéntico programado (backlog 014), inline code spans no excluidos del escaneo de alias (014 v1), gate SC-006 de 018 en ferrari sin registro de cierre, validación DOCKER_E2E del stub Tier-1 de 019 diferida y sin registro de ejecución posterior, `qmd` 2.6.x upstream mueve `tree-sitter-*` a deps duras (un bump exige rediseño). `[V]` §3.
- Los SC de la cadena son **cuantitativos y medibles por artefacto**: latencias (<60 s watcher, ≤5 min backstop, ~15 s reindex-on-change), presupuestos de hardware (1.000 páginas < 60 s en RPi5), "0 falsos positivos / 0 falsos negativos" sobre fixture, "0 archivos preexistentes modificados (hash antes/después)", "docker byte-idéntico (diff vacío)", "suite 0 `not ok`", poder de detección RED/GREEN en ambos sentidos, exit codes 0/1/2 sin falsos ✓. `[V]` §4.
- Gates: suite host bats + `shellcheck -S error` siempre; **DOCKER_E2E obligatorio cuando se toca una lib espejada, `docker/` o una línea de crontab staged**; gate de hardware mclaren (systemd real) y/o ferrari (musl real + wiki de 2.696 páginas + Syncthing) cuando el comportamiento solo existe ahí. La lección repetida: 013/014 se mergearon con el gate de hardware diferido y 016 se mergeó sin correr su DOCKER_E2E — cada vez apareció un bug real (015 y 017 existen por eso). `[V]` §5.
- **Ninguna mención previa** a PARA, Second Brain, Zettelkasten, Progressive Summarization, Tiago Forte, Intermediate Packets ni weekly/monthly review en `specs/`, `docs/`, `modules/`, `README.md` ni `CHANGELOG.md`. "project" aparece solo como ejemplo de `entity` y en la tabla de capas de memoria ("ongoing project state" → auto-memoria, no vault). `[V]` §6.

---

## 1. Tabla cronológica: feature → qué agregó → decisiones clave con su porqué

Fechas de merge tomadas de `git log` (`[V]`, comando en §Anexo). VERSION según `plan.md`/CHANGELOG de cada feature.

| # | Feature (PR, fecha merge) | VERSION | Qué agregó | Decisiones clave y porqué |
|---|---|---|---|---|
| — | **Skeleton del vault** (PR #13 `1915fc2`, 27-04-2026; docs PR #16 `9f11f01`, mismo día). **Pre-spec-kit, sin `specs/`.** | 0.1.x | `modules/vault-skeleton/` con las 3 capas Karpathy verbatim: `raw_sources/` (inmutable), `wiki/` con **seis** subdirs (`summaries, entities, concepts, comparisons, overviews, synthesis`), `CLAUDE.md` como schema (frontmatter, wikilinks, protocolos ingest/query/lint, heurística vault vs auto-memoria vs claude-mem), `index.md` (content-oriented), `log.md` (time-oriented, append-only), `_templates/`; `scripts/lib/vault.sh` (`vault_ensure_paths`, `vault_seed_if_empty`, `vault_log_append`); `tests/vault.bats`. `[V]` cuerpo del commit `1915fc2`. | (a) "Page types (the only six) … No other types. If something doesn't fit … make it a `concept` or extend an existing page, not invent a new type" (`modules/vault-skeleton/CLAUDE.md:36-49` `[V]`). (b) Sin skill de slash-commands — razones en `docs/vault.md:542-556` `[V]`: no hay patrón de skills workspace-local en el repo; los protocolos ya viven en el `CLAUDE.md` del vault; se podría agregar después como plugin aparte. (c) `CLAUDE.md` del vault es capa **co-evolucionada** humano+LLM (`CLAUDE.md:29`). (d) Tres capas de memoria con heurística de ruteo (`CLAUDE.md:171-183`): auto-memoria = hechos atómicos del usuario/"ongoing project state"; claude-mem = observaciones de transcripts; vault = conocimiento curado derivado de fuentes externas. "Don't double-write across layers". |
| 010 | **Self-managing RAG** (PR #65 `5680b21`, 28-06-2026) | 0.4.3 → 0.4.4 (`plan.md` Constraints `[V]`) | Auto-setup de QMD al boot (backgrounded, timeout-bounded, sentinel + `index.sqlite`), reindex con **doble disparador** (watcher inotify ~15 s debounce + cron backstop `*/5`), ambos vía `heartbeatctl qmd-reindex` (flock + hash-debounce reusando `vault_hash`), state `qmd-index.json`, pin `@tobilu/qmd@2.5.3` single-source en `agent.yml vault.qmd.version`, validación `schema.sh` de `vault.qmd.*`. | D1: pin 2.5.3 — la 0.4.4 asumida en el brainstorm **no existe en npm** (`research.md` D1 `[V]`). D2: un solo literal del pin en `agent.yml`, ni en template ni en lib (Principio VI). D3: modelo e índice en `~/.cache/qmd` → bajo `.state` por el bind-mount; **descarga en primer boot, no pre-horneado** (el bind enmascara `/home/agent`; 300 MB para agentes sin QMD viola opt-in). D5: un solo entry point para cron y watcher (una ruta, un lock, un state). D6: watcher de filesystem porque captura Syncthing y escrituras externas; respawn por liveness de PID, **no** heurística tipo bridge-watchdog (`ebfe35f`). Índice derivado **no se respalda** (regenerable). |
| 012 | **Vault + RAG en modo local** (PR #67 `d630a6e`, 04-07-2026) | 0.5.0 → 0.6.0 | Siembra host-side del skeleton en local; remap `VAULT_MCP_PATH` por modo; reubicación de `qmd_index.sh`/`backup_vault.sh`/`qmd_watch.sh` a `scripts/lib/` con espejo a `docker/` en scaffold/regenerate; 5 units systemd (reindex timer+service, watcher, backup timer+service); `local_schedule.sh::cron_to_systemd_calendar` (3 formas + fallback con warning); doble enganche del setup (`--login` background + timer setup-if-needed); `VAULT_ROOT_OVERRIDE` aditivo. | D1: canónico host-side + espejo (precedente `vault.sh`), porque "local no lleva `docker/`". D2: override por env en vez de cambiar la firma de `vault_resolve_root` (tests docker fijan el rebase). D3: conversión de formas comunes + fallback visible, `agent.yml` sigue en sintaxis cron sin claves paralelas (clarify Q2). D4: doble enganche auto-sanador (clarify Q1). D5: storage bajo `<ws>/.state/.cache/qmd` (**supuesto luego refutado por 013 RC1**: el binario no lee `QMD_CACHE_HOME`). D6: mismo ciclo de vida que 011 (units de sistema, staged sin sudo). D7: journal + state files, sin logs paralelos. |
| 013 | **Paridad RAG local↔docker** (PR #68 `fa6add7`, 05-07-2026) | 0.6.0 → 0.7.0 | Cierra 30 gaps de una auditoría multi-agente. RC1: contrato real de storage del binario = `XDG_CACHE_HOME` (índice+modelos) + `QMD_CONFIG_DIR` (colecciones), verificado contra el tarball (`store.js:420-435`, `llm.js:119-121`, `collections.js:59-65`) — **par atómico** escritor (wrapper) + lector (`{{QMD_MCP_ENV}}` en `.mcp.json`; docker `{}` byte-idéntico). RC2: PATH auto-provisto como primera acción de los 3 wrappers. RC3: watcher con env del vault + loop supervisado. Kill-switch completo, `doctor` honesto (exit 0/1/2), acciones manuales `agentctl heartbeat qmd-reindex|backup-vault`, marker `qmd-schedule.fallback`. Dos excepciones docker: flock en `qmd_setup_if_needed` (FR-015) y **symlink `bunx` en la imagen** (FR-016: "QMD en docker nunca funcionó contra binarios reales" desde 010; el e2e lo stubeaba). | Corregir solo el escritor **empeoraba**: qmd auto-crea un sqlite vacío en silencio (`spec.md` RC1 `[V]`). PATH en el wrapper, no en la unit, para cubrir timer/watcher/`--login`/manual con un solo cambio (R5). Loop supervisado para que `failed` sea señal real (R7, clarify Q1). Nunca `rm` en el HOME del operador (R11). `QMD_CONFIG_DIR` prepara multi-agente sin soportarlo (1 agente/host v1, `spec.md:141`). |
| 014 | **Wiki-grafo RAG agéntico** (PR #69 `e73ef3a`, 07-07-2026) | 0.7.0 → 0.8.0 | Lib espejada `scripts/lib/wiki_graph.sh` (awk extrae per-file, jq agrega): grafo de TODA la `wiki/` (nodos = páginas tipadas; aristas = wikilinks + `related:` + `sources:` + alias→canonical) a `<vault>/.graph/{graph,backlinks,findings}.json`; lint determinista sin LLM (huérfanos, links rotos, frontmatter inválido, drift de `index.md`, stale, ocurrencias de alias); `wiki/normalization/` con frontmatter propio (`canonical`, `aliases`, `match_case`, `entity`, `notes`); schema del skeleton gana ingest 2.5 "Normalize" y query 1.5 "Expand via the graph"; scheduling en ambos modos (`20 */6 * * *`); `vault_seed_missing` (upgrade aditivo) + `modules/vault-deltas/schema-updates-0.8.0.md` + sentinel oculto `_templates/.schema-updates-0.8.0.applied` + entrada en `log.md`. | Grafo **derivado**, no servidor (ratificado en clarify 06-07-2026: "no reabrir sin causa"). Normalización como carpeta-convención, "los 6 types quedan intactos" (clarify Q1). Delta del schema aparte, jamás append al `CLAUDE.md` co-evolucionado (clarify). Runner bash+awk+jq: cero deps nuevas y bash 3.2 en host (R2). JSON-only en `.graph/` para quedar fuera del backup (`*.md`) y de la mask qmd por construcción (R5). Locks y tmp **fuera del vault** por Syncthing (R8). "El script reporta, el agente corrige" — FR-005: el runner jamás edita `wiki/` ni `raw_sources/`. Doctor: integridad degrada, contenido informa (clarify Q5). |
| 015 | *(fuera de la lista pedida; incluida por dependencia)* Local-mode & docker RAG hardening (PR #70, entre 014 y 016) | 0.8.0 → 0.9.0 | Los 4 bugs del gate de hardware del 08-07-2026: `claude_cli` absoluto, `_libc_variant` para elegir bun glibc/musl, `TMPDIR` host-backed bajo `.state` (`rag_obs.sh`: `scratch_dir` + `redact_secrets`), observabilidad del reindex (stderr capturado y redactado). `[V]` CHANGELOG. | Fail-silent no puede tragarse errores de infra (`ENOSPC`); redactar antes de truncar. 016/017 dependen de `_libc_variant`, `TMPDIR` y la observabilidad. |
| 016 | **qmd deps nativas en Alpine** (PR #71 `14169cf`, 10-07-2026) | 0.9.0 → 0.10.0 | Toolchain `build-base cmake git linux-headers libgomp` gateado por build-arg `QMD_NATIVE_TOOLCHAIN`; **prefijo `bun install` gestionado** con `trustedDependencies: [better-sqlite3, node-llama-cpp]` reemplaza `bunx` (tree-sitter queda sin compilar → WASM); `bigstack.so` (`LD_PRELOAD` solo en embed) para el hazard stack/`std::regex` de musl; MCP qmd desde el mismo prefijo (T036, `{{QMD_MCP_COMMAND}}` por modo); DOCKER_E2E des-stubeado en tiers; guardrail `tests/qmd-version-guard.bats` + `docs/qmd-upgrade-checklist.md`. | Clarify: **Opción A (mantener Alpine)**, embed en alcance, e2e con qmd real. B (glibc) y C (embeddings remotos) rechazadas y armadas como fallback con criterio de disparo (`research.md` §Criterio). Bloat de toolchain registrado como violación del *espíritu* minimalista (Complexity Tracking), constitución literal intacta. Se mergeó **sin correr** su DOCKER_E2E — por eso existe 017. |
| 017 | **sqlite-vec en Alpine musl** (PR #72 `70d8f23`, 10-07-2026) | 0.10.0 → 0.11.0 | Tercer muro nativo que nadie vio: `sqlite-vec-linux-arm64@0.1.9` es prebuilt **glibc** (`vec0.so.so` era red herring del fallback de SQLite). Compila la amalgamación oficial v0.1.9 en build con shim `-Du_int8_t=uint8_t…`, hornea a `/opt/agent-admin/sqlite-vec/vec0.so`, `_qmd_swap_sqlite_vec` la sustituye en el prefijo gateado por artefacto presente + libc musl; guardrail del par qmd 2.5.3 ↔ sqlite-vec 0.1.9 (`tests/qmd-sqlite-vec.bats`). | Build-time, no runtime (sin red ni recompilación por aprovisionamiento; el bind-mount enmascara el prefijo, por eso el artefacto va en `/opt`). Verificado **antes** de escribir la spec (embed real + vsearch semántico 42 % en musl). `node-llama-cpp` (el "muro real" temido por 016) embebía bien; el bloqueo era sqlite-vec. |
| 018 | **Embed completion multi-pasada** (PR #73 `5f5a2d3`, 12-07-2026) | 0.11.0 → 0.12.0 | El gate ferrari de 017 mostró que `qmd embed` cierra sesión a los 30 min (`store.js:1377`, `maxDuration` hardcodeado) → 859/2.423 chunks y el guard "vault unchanged" nunca reanudaba. `_qmd_embed_until_complete`: pasadas frescas dentro de UNA invocación bloqueada hasta cobertura completa / sin progreso / cap fijo `QMD_EMBED_MAX_PASSES=12`; guard reanuda si `pending>0`; state gana `pending` y `last_status ∈ {partial, stalled}`. | Clarify Q1: loop alrededor del motor, **nunca parchear el dist** (Principio VI). Q2: loop en una invocación reusando el flock (un modelo por tick no reduce el lock y agrega piezas). Q3: cap como **constante interna**, no campo de `agent.yml` (evita schema/wizard/tests para un backstop). Señal autoritativa = `qmd status` "Pending: N" + "All content hashes already have embeddings". |
| 019 | **Fix drift de tests post-016** (PR #74 `2bf984b`, 12-07-2026) | sin bump | 7 tests que stubeaban `bunx` (que `_qmd_run` ya no invoca) o el shape pre-T036 de `.mcp.json`. Seam canónico: binario `qmd` falso **dentro del prefijo gestionado** + `.installed-hash` pre-sembrado + `bun` no-op en PATH (`tests/helper.bash::install_qmd_stub{,_fail}`), contrato en `contracts/qmd-test-seam.md`. | Cero cambio de producción (FR-005). El stub de éxito debe emitir la señal de completitud 018 o el test cae en `stalled` (R4). Tier-1 de `docker-e2e-qmd.bats` alineado sintácticamente, validación Docker **diferida** (R6). |

---

## 2. Alternativas explícitamente rechazadas y su razón

### 2.1 Esquema del vault y del wiki (lo más pertinente para 037)

| Alternativa rechazada | Dónde | Razón registrada |
|---|---|---|
| Skill `vault-ops` con `/vault:ingest`, `/vault:query`, `/vault:lint` | `docs/vault.md:542-556` `[V]`; commit `1915fc2` la llamaba "Phase D" y nunca se implementó | Sin patrón de skills workspace-local en el repo; los protocolos ya están en el `CLAUDE.md` del vault y el lenguaje natural funciona igual; "could be added later as a separate plugin if the friction shows up". |
| Tipos de página adicionales / séptimo `type` | `modules/vault-skeleton/CLAUDE.md:48-49` `[V]`; 014 clarify Q1 y FR-007 `[V]` | "No other types … make it a `concept` or extend an existing page". 014 lo **ratificó** al meter `wiki/normalization/` como carpeta-convención con frontmatter propio, "los 6 types de conocimiento quedan intactos ('the only six')". |
| Servidor de base de datos de grafos (Neo4j o similar) | `specs/014-wiki-graph-rag/spec.md` §Decisión de arquitectura y §Fuera de alcance `[V]` | Viola el stack (Alpine, `cap_drop: ALL`, mínimas deps) y el gist tampoco lo usa; el grafo ya existe implícito en los wikilinks → se **deriva** a JSON regenerable. "RATIFICADA en clarify 2026-07-06 … no reabrir sin causa". |
| Append directo al `CLAUDE.md` del vault con marcadores (para entregar schema nuevo) | 014 `research.md` R7 `[V]` | Capa co-evolucionada; riesgo de duplicar contenido reorganizado por el agente. Se reemplazó por `_templates/schema-updates-<version>.md` + entrada en `log.md`; el agente integra. |
| Delta de schema dentro del skeleton | 014 R7 `[V]` | Cada scaffold fresco lo heredaría como ruido (su `CLAUDE.md` ya está al día) → `modules/vault-deltas/` separado. |
| Sentinel de upgrade = existencia del delta `.md` | 014 `spec.md` §Remediaciones C1 `[V]` | El agente puede borrar el delta tras integrarlo; el boot docker lo re-depositaría en cada arranque → marcador **oculto** `_templates/.schema-updates-<v>.applied`. |
| Lint agéntico programado (sesiones LLM por cron) | 014 `research.md:22`, `spec.md:409` `[V]` | Costo de tokens; la dimensión estructural es 100 % determinizable. Queda en backlog "sobre la infraestructura heartbeat existente". |
| Scripts que editen páginas del wiki | 014 FR-005, §Fuera de alcance `[V]` | Principio del gist: LLM ownership de capa 2. "El script reporta, el agente corrige". |
| Migración de contenido de vaults existentes | 014 §Fuera de alcance `[V]` | Solo estructura **aditiva** (`vault_seed_missing`: nunca sobreescribe, nunca toca `CLAUDE.md`, idempotente por sentinel). |
| Visualización propia del grafo | 014 §Fuera de alcance `[V]` | Obsidian graph view vía Syncthing ya lo cubre. |
| Reportes `.md` bajo `.graph/` | 014 R5 `[V]` | Entrarían al backup y al índice qmd; contrato duro: solo JSON. |
| Exigir reciprocidad para contar backlinks (huérfano) | 014 §Remediaciones H2 `[V]` | `related:` entrante cuenta siempre. |
| Runner en bun/JS (parsing YAML robusto) | 014 R2 `[V]` | Agrega bun como dep de la suite host, rompe el patrón de libs espejadas bash, duplica estilos de test. `yq` por archivo también rechazado (1.000 forks en la Pi rompen SC-006). |
| Tocar `docker/crontab.tpl` para el cron del grafo | 014 R3 `[V]` | Solo el heartbeat vive ahí; el patrón es la línea staged por `heartbeatctl` (010). |
| Rediseñar el esquema del vault / sus plantillas | 010 `spec.md` §Out of Scope `[V]` | Fuera de alcance de 010; 012/013 tampoco lo tocan ("Rediseñar RAG/qmd, el esquema del skeleton o el modelo de backup"). |
| Reemplazar el MCP keyword (MCPVault) por QMD | 010 §Out of Scope; `docs/vault.md` "QMD and MCPVault are complementary" `[V]` | Coexisten: MCPVault para read/write/list de notas, QMD para retrieval. |
| Tuning de ranking del motor más allá de sus defaults | 010 §Out of Scope `[V]` | — |

### 2.2 Motor de búsqueda, pin y storage

| Alternativa rechazada | Dónde | Razón |
|---|---|---|
| `@tobilu/qmd@latest` flotante | 010 D1 `[V]` | Principio VI: dos scaffolds del mismo `agent.yml` podrían diferir. |
| Pin en template + lib (duplicado) o en `versions.sh` | 010 D2 `[V]` | Pin duplicado; `versions.sh` es tooling de build de imagen, qmd es paquete runtime. |
| Pre-hornear el modelo (~300 MB) en la imagen bajo `/opt` + `XMD_CACHE_HOME` | 010 D3 `[V]` | Bloat para agentes sin QMD (viola FR-012 opt-in); el bind-mount enmascara `/home/agent`. |
| Respaldar el índice qmd en `backup/vault` | 010 Constitution V; 012 D5 `[V]` | 300 MB regenerables desde el markdown. |
| `INDEX_PATH` como mecanismo de relocación | 013 R1 `[V]` | Solo mueve el índice, no modelos ni PID del daemon MCP. |
| `XDG_CONFIG_HOME` en vez de `QMD_CONFIG_DIR` | 013 R2 `[V]` | Contaminaría la config XDG de otros procesos hijos. |
| `remote-control.env` global para el env del lector MCP | 013 R4 `[V]` | Redirige caches XDG de toda la sesión — blast radius injustificado. |
| Migrar (`mv`) el índice viejo de `~/.cache/qmd` al workspace | 013 R11 `[V]` | Hereda config de colecciones posiblemente compartida con el qmd personal del operador; reconstruir limpio. Nunca `rm` automático en HOME ajeno. |
| Índice en `~/.cache/qmd` del operador (local) | 012 D5 `[V]` | Se pierde en migración; colisiona con qmd personal. |

### 2.3 Scheduling, watcher y modo local

| Alternativa rechazada | Dónde | Razón |
|---|---|---|
| Hook agéntico de reindex ("el agente recuerda disparar") | 010 D6 `[V]` | Se pierden escrituras de Syncthing/externas. |
| Supervisar el watcher con la máquina de estados completa del watchdog | 010 D6 `[V]` | PID-liveness + cron backstop basta; no tocar el crash budget. Tampoco heurística de scraping (bridge watchdog revertido `ebfe35f`). |
| Watcher que source-a la lib directo (sin `heartbeatctl`) | 010 D5 `[V]` | Dos entry points que sincronizar. |
| Parser cron completo en bash / claves `*_interval_minutes` por modo / `OnUnitActiveSec` | 012 D3 `[V]` | Matriz de tests enorme para valores que nadie usa; rompe fuente única; no equivale a cron anclado al reloj. |
| Setup solo en `--login` / solo en timer / `ExecStartPre` en la unit del watcher | 012 D4 `[V]` | Fallo = sin corpus hasta re-login; login sin feedback; acopla a componente opcional. |
| `systemd --user` | 012 D6 (heredado de 011) `[V]` | Requiere linger. |
| Un "supervisor local" que multiplexe units | 012 D6 `[V]` | Reinventa el watchdog; systemd ya es el supervisor. |
| Logs paralelos `logs/*.log` en local; `OnFailure→Telegram` para units batch | 012 D7 `[V]` | Redundante con journal; docker tampoco notifica esos flujos (paridad). |
| `Environment=PATH=` en units / `EnvironmentFile=remote-control.env` | 013 R5 `[V]` | No cubre `--login` ni ejecución manual; arrastra env de sesión innecesario. |
| `StartLimitIntervalSec=0` o híbrido para el watcher | 013 R7 `[V]` | Churn de journal cada 2 s; dos mecanismos que testear. |
| Lock separado `.setup.lock` / diferir el flock del setup | 013 R8 `[V]` | No serializa setup-vs-reindex; diferir dejaba 29/30. |
| `systemctl start` para acciones manuales | 013 R9 `[V]` | Exige root/polkit; `start` de un oneshot en marcha falla. |
| Fallback de schedule como campo de `qmd-index.json` / solo stderr | 013 R10; 014 clarify `[V]` | La lib reescribe el JSON entero por tick; stderr es efímero → archivo marker aparte. |
| Copiar libs desde `docker/scripts/` al workspace local / duplicarlas en ambos árboles | 012 D1 `[V]` | Flujo host dependiendo del árbol de imagen; deriva garantizada. |
| Parámetro posicional nuevo en `vault_resolve_root` | 012 D2 `[V]` | Rompe llamadores (`heartbeatctl`, `start_services.sh`). |
| Sembrar el vault desde `--login` en vez del scaffold | 012 D8 `[V]` | No necesita sudo; el MCP debe apuntar a contenido desde el primer render. |
| Feature separada para el symlink `bunx` docker | 013 R3, clarify Q4 `[V]` | Bloqueaba QMD-en-ferrari un release y dejaba el e2e mintiendo. `bun x` en todas partes también rechazado (diff mayor). |

### 2.4 Dependencias nativas (016/017)

| Alternativa rechazada | Dónde | Razón |
|---|---|---|
| **Opción B — base glibc** (debian-slim / node-slim) | 016 `spec.md` §Clarifications, `research.md` D1; 017 Complexity Tracking `[V]` | Enmienda de constitución ("Alpine single-stage") + migración de privilegios (crond busybox→cron, su-exec→gosu, apk→apt). Queda **armada como fallback** con criterio de disparo (N-API crash bajo bun, shim no cubre el tokenizer, llama.cpp no enlaza). |
| **Opción C — embeddings remotos** | 016 `spec.md:39`, research D1; 018 `spec.md` §Out of Scope ("explicitly rejected in prior work") `[V]` | Saca el vault del host (choca con Workspace-Is-the-Agent), dependencia de red/servicio, costo/latencia, soporte no confirmado en qmd 2.5.3. Fallback armado. |
| Multi-stage que hornee el `.node` compilado | 016 D1 `[V]` | El bind-mount `.state:/home/agent` lo enmascara y `bunx`/`bun install` reinstala en runtime. |
| Compilar `tree-sitter-*` con el toolchain | 016 D2 `[V]` | Desperdicia build en runtime para un binding que qmd no usa (WASM). |
| `bunx --ignore-scripts` / `--omit=optional` | 016 D2 `[V]` | Bajo bun solo afecta scripts del root; `--omit=optional` dropea `sqlite-vec-linux-arm64`, que sí se necesita. |
| Smoke acotado (build+carga sin index) / un test monolítico con modelo | 016 D3 `[V]` | Poca detección; lento y frágil sin red. |
| Symlink `vec0.so.so → vec0.so`; `-D_GNU_SOURCE`/`-D_DEFAULT_SOURCE` | 017 R2 `[V]` | El binario sigue siendo glibc; sqlite-vec no incluye `<sys/types.h>`. |
| Compilar sqlite-vec en runtime; vendorizar `sqlite-vec.c` en el repo; compilar contra headers de better-sqlite3 | 017 R3 `[V]` | Red+toolchain por aprovisionamiento; bloat de repo (~320 KB) — se prefiere URL de versión fija + sha256; headers no disponibles en build. |
| Derivar la versión de sqlite-vec dinámicamente de qmd | 017 R5 `[V]` | El objetivo es forzar revisión humana ante el cambio. |
| Host **local musl** (Alpine local) | 017 R3 `[V]` | No soportado ni probado; mclaren es glibc. |

### 2.5 Embed completion (018) y tests (019)

| Alternativa rechazada | Dónde | Razón |
|---|---|---|
| Parchear `maxDuration` en el dist de qmd | 018 R2, clarify Q1 `[V]` | Dep vendorizada, minificada y reinstalada en el prefijo; frágil ante bumps (Principio VI). |
| Un pase por tick, confiando en el scheduler | 018 R3, clarify Q2 `[V]` | No reduce el tiempo de lock (30 min > cadencia 5 min igual), agrega dependencia de re-trigger. |
| Cap de pasadas configurable en `agent.yml` | 018 R5, clarify Q3 `[V]` | Schema + wizard + render + tests para un backstop de seguridad. |
| Parsear "Embedded N chunks" como señal primaria | 018 R4 `[V]` | Menos autoritativa que `qmd status`; queda como secundaria. |
| GPU / cuantización / cambio de modelo; cambiar el motor, su cap, modelo o schema | 018 §Out of Scope `[V]` | — |
| Override de `_qmd_run` como seam canónico | 019 R2 `[V]` | Salta `_qmd_ensure_prefix`; cubre menos que los tests originales. Válido solo para unidades de lógica de loop. |
| `bun` falso que simule `bun install` | 019 R2 `[V]` | Re-implementa el layout de bun en cada test. |
| Tratar los 7 rojos como posibles bugs de producción | 019 R1 `[V]` | Los paths fueron ejercidos por 017 DOCKER_E2E y el sanity check de 018. |

### 2.6 Decisiones heredadas marcadas explícitamente como "no reabrir"

Compiladas de 013 `spec.md` §Assumptions, 014 `spec.md` §Assumptions ("Decisiones heredadas (no reabrir)") y 017 `research.md` §Contexto heredado `[V]`:

1. Pin qmd **2.5.3** single-source en `agent.yml vault.qmd.version`; un upgrade re-verifica el contrato de env contra el tarball y pasa por `docs/qmd-upgrade-checklist.md`.
2. Storage 013: `XDG_CACHE_HOME`/`QMD_CONFIG_DIR` bajo `<ws>/.state`, par atómico escritor+lector.
3. Índice y grafo = **derivados regenerables, nunca respaldados**; solo `*.md` va a `backup/vault`.
4. Render engine sin `{{#if}}` anidado → variables por modo **precomputadas en `setup.sh`**; `schema.sh` solo valida forma; defaults en `setup.sh` + fallbacks `yq //`.
5. Libs canónicas en `scripts/lib/` **espejadas** a `docker/scripts/lib/` con línea `COPY` explícita por lib; toda lib nueva necesita su `COPY`.
6. Principio IV: entrypoints batch **fail-silent exit 0**; la honestidad va en `doctor`/healthcheck/`status` (exit codes 0/1/2).
7. 1 agente por host en local v1; identidad local = usuario operador; units de sistema (no `--user`); nunca `--dangerously-skip-permissions` en local.
8. Grafo derivado a `<vault>/.graph/` (dot-dir, ruta relativa idéntica en ambos modos); locks y tmp fuera del vault (Syncthing).
9. Imagen Alpine single-stage; Principio II (`cap_drop: ALL`) intacto; `LD_PRELOAD` es env del wrapper, no privilegio.
10. Modelo de backup de tres ramas huérfanas intacto.

---

## 3. Deuda técnica y follow-ups declarados — estado al 22-09-2026

| Ítem | Origen | Estado | Evidencia |
|---|---|---|---|
| `status`/`doctor` **docker** no reportan QMD ni wiki-graph (hay que leer `scripts/heartbeat/{qmd-index,wiki-graph}.json`) | 013 `spec.md` §Out of Scope ("Backlog para una feature docker-side"); 014 `spec.md` SC-002 y `plan.md` D9 lo reafirman | **ABIERTO** | `docker/scripts/heartbeatctl::cmd_status` solo enriquece `vault backup` (verificado hoy: el cuerpo de `cmd_status` no menciona qmd/wiki). `docs/vault.md` §Ops surface lo documenta como "read the JSON". `[V]` |
| stderr del watcher docker va a `/dev/null`; retry de setup docker solo al boot (local es superior con el doble hook) | 013 §Out of Scope | **ABIERTO** (sin feature posterior que lo cierre) | `Sin registro` de cierre en CHANGELOG/specs 020-036. `[I]` sigue tal cual. |
| Lint **agéntico** programado (contradicciones semánticas por sesión LLM en cron) | 014 R1 / §Fuera de alcance | **Backlog** | `specs/014/spec.md:409` `[V]`. Candidato natural para 037 si quiere "reviews" automáticos, pero fue descartado en v1 por costo de tokens. |
| Inline code spans **no** se excluyen del escaneo de alias | 014 R9; `contracts/normalization-pages.md:41` | **Deuda v1 documentada** | `[V]` |
| Gate de hardware 014 (T033: mclaren + ferrari) y 013 (T040) | `tasks.md` de ambas con `[ ]` | **CERRADOS** por el despliegue en vivo del 08-07-2026 (2.696 páginas reales), que a su vez destapó los 4 bugs de 015 | CLAUDE.md del repo §"Prior" y CHANGELOG 015 `[V]`. Los checkboxes en `tasks.md` nunca se marcaron. |
| Gate mclaren de 012 (T036) | `specs/012/tasks.md:75` `[ ]` | Nunca corrió como tal; 013 lo **pre-ejecutó estáticamente** y encontró 3 causas raíz | `specs/013/spec.md` §Contexto `[V]` |
| DOCKER_E2E de 016 (T035) | `specs/016/tasks.md:139` `[ ]` | **CERRADO** por 017 (corrió el gate: léxico verde, embed rojo → sqlite-vec) | `specs/017/spec.md` Input `[V]` |
| WARN en doctor/healthcheck local si falta toolchain con qmd habilitado (T030, opcional) | `specs/016/tasks.md:127` `[ ]` | **ABIERTO (opcional)**; el prerequisito quedó documentado (T029) | `[V]` |
| Gate confirmatorio ferrari de 017 (SC-005) | 017 quickstart §4 | **CORRIÓ** el 10-07-2026 y reveló el cap de 30 min → 018 | `specs/018/spec.md` §Context `[V]` |
| Gate ferrari de 018 (SC-006: corpus 2.423 chunks completo vía cron + hit semántico) y DOCKER_E2E Tier-2 `pending→0` | 018 quickstart; CLAUDE.md del repo: "Gate confirmatorio ferrari AÚN ABIERTO" | **Sin registro de cierre**. `[I]` El código está desplegado (memoria: donna/linus/rodri-cenco-admin en ≥0.19.0), pero la medición SC-006 no consta en ningún artefacto leído. | `[V]` CLAUDE.md; grep de `docker-e2e-qmd` en CHANGELOG/specs 02x-03x no muestra una corrida posterior. |
| Validación Docker del stub Tier-1 alineado por 019 | 019 R6; `tests/docker-e2e-qmd.bats:25-26` "DEFERRED to the next DOCKER_E2E=1 run" | **Sin registro** de una corrida posterior de `docker-e2e-qmd.bats` (033/034 corrieron `docker-e2e-voice.bats`, no qmd) | `[V]` header del test; `[I]` sigue diferida. |
| `qmd` 2.6.x upstream mueve `tree-sitter-*` a deps **duras** → la estrategia `trustedDependencies` deja de proteger; un bump exige rediseño | 016 US4; `docs/qmd-upgrade-checklist.md:20-35` | **Guardrail activo** (`tests/qmd-version-guard.bats` + `tests/qmd-sqlite-vec.bats`) | `[V]`. Relevante si 037 quisiera funciones de qmd más nuevas. |
| inotify bajo VirtioFS (macOS) puede no entregar eventos de origen host | 010 D6 "Known limitation" | Aceptado; el cron backstop cubre | `[V]` |
| `bunx qmd` manual del agente en local no hereda el pin XDG | 013 FR-001, clarify Q2 | Caso borde documentado | `[V]` |
| Residuos pre-013 en `~/.cache/qmd` y `~/.config/qmd` de hosts locales | 013 R11, CHANGELOG "MIGRATION NOTE" | Limpieza manual documentada; nunca automatizada | `[V]` |
| Multi-agente por host en local | 013 `spec.md:141` | No soportado (v1 = 1 agente); `QMD_CONFIG_DIR` solo lo prepara | `[V]` |
| Host local musl | 017 R3 | Fuera de alcance | `[V]` |
| Pin de `@bitbonsai/mcpvault` en `versions.sh:46` (drift-guards) | `docs/vault.md` §MCP; 020 drift-audit | Vigente; no es deuda, es touchpoint a recordar si 037 toca MCPVault | `[V]` docs/vault.md |

---

## 4. Métricas y criterios de éxito (SC-*) usados — para reusar el estilo

### 4.1 Inventario por feature `[V]`

| Feature | SC representativos (texto abreviado) |
|---|---|
| 010 | SC-001 **cero** pasos manuales tras primer boot; SC-002 cambio reflejado **< 60 s** (watcher); SC-003 **≤ 5 min** con watcher caído (backstop); SC-004 ráfaga de N notas → **una sola** reindexación (conteo de pasadas de embed); SC-005 nunca solapamiento ni corrupción bajo concurrencia; SC-006 segundo boot **no** re-descarga ni reindexa; SC-007 overhead **cero** con QMD deshabilitado; SC-008 dos renders → **misma** versión; SC-009 config inválida **rechazada** con mensaje accionable. |
| 012 | SC-001 skeleton sembrado + MCP conectado sin intervención tras scaffold+login; SC-002 índice responde **≤ 15 min** post-login y edición reflejada **< 2 min**; SC-003 docker **byte-idéntico**; SC-004 backup en `backup/vault` dentro del primer intervalo + restore simétrico; SC-005 deshabilitar → **cero artefactos** (diff de scaffold). |
| 013 | SC-001 ~15 s con watcher / un ciclo del schedule sin él; SC-002 migración por rsync conserva la memoria RAG (sin re-descarga de 300 MB); SC-003 render docker **diff vacío** vs v0.6.0 (test); SC-004 kill-switch → **cero** actividad en 24 h de ventanas; SC-005 `doctor` **sin falsos ✓** (exit ≥ 1 en cada fallo simulado); SC-006 gate mclaren: los **3 fallos predichos** verificados corregidos; SC-007 `bunx` real en imagen (aserción contra imagen, no stub). |
| 014 | SC-001 **0 falsos positivos y 0 falsos negativos** sobre fixture con hallazgos conocidos; skeleton limpio → **exactamente 0**; SC-003 mismo vault → mismos hallazgos en ambos modos; SC-005 upgrade aditivo modifica **0 archivos preexistentes** (hash antes/después) y es idempotente; SC-006 wiki de **1.000 páginas < 60 s en RPi5**; SC-007 ingest con alias declarado → capa 2 canónica, capa 1 VERBATIM (transcript real con SENCOSUD); SC-008 suite host + DOCKER_E2E verdes antes del merge. |
| 016 | SC-001 `last_status=ok` + índice ≥ 1 doc, **0 intentos fallidos** por deps nativas; SC-003 e2e **falla** sin fix y **pasa** con fix (poder de detección en ambos sentidos); SC-005 ferrari: reindex real, semántica responde, wiki-graph `ok` sobre 2.696 páginas, `/tmp` sin ENOSPC; SC-006 cambiar el pin sin el guardrail → test falla. |
| 017 | SC-001 consulta **sin solapamiento léxico** recupera el documento correcto; SC-002 cero regresión glibc; SC-003 RED/GREEN reproducible por build-arg; SC-005 ferrari sobre ~2.696 páginas. |
| 018 | SC-001 **100 % de cobertura** (0 pendientes) donde antes plateau parcial; SC-002 query sobre contenido de la porción tardía → **top result on-topic**; SC-003 vault completo sin cambios → **cero** inferencia; SC-004 documento permanentemente fallido → termina acotado con `partial/stalled`; SC-005 mantenimiento incremental sigue en **un** pase; SC-006 ferrari ~2.423 chunks. |
| 019 | SC-001 **0 failures** (era 7) en macOS y Linux sin `bun`; SC-002 los 7 tests **fallan** cuando se rompe deliberadamente el comportamiento (mutation spot-check); SC-003 **cero** diffs de producción; SC-004 ningún test borrado ni skippeado, conteo ≥ actual. |

### 4.2 Patrones reutilizables `[I]` (destilados de lo anterior)

1. **Latencia con dos cotas**: vía rápida (watcher, ~15 s / < 60 s) y vía backstop (≤ 5 min / un ciclo del schedule). Siempre se declara qué pasa si la vía rápida cae.
2. **"Cero" como número**: cero pasos manuales, cero overhead cuando está deshabilitado, cero artefactos por diff, cero archivos preexistentes modificados (hash), cero diffs de producción, cero `not ok`.
3. **Fixture con verdad conocida** → "exactamente esos hallazgos", 0 FP / 0 FN; skeleton limpio → exactamente 0.
4. **Byte-identidad** del modo no tocado (docker vs versión anterior) probada por test, no a mano.
5. **Poder de detección bidireccional**: el gate debe ponerse ROJO sin el fix y VERDE con él (build-arg, mutación).
6. **Mutation spot-check**: revertir cada fix tumba ≥ 1 test (SC-007 de 027; 019 SC-002; 028-034 lo generalizan).
7. **Presupuesto de hardware objetivo** (RPi5): "N páginas en < T s", medido en el gate real, con fixture sintético de 100 páginas en bats como smoke de complejidad (no benchmark).
8. **Honestidad operacional**: `doctor` sin falsos ✓, exit codes 0/1/2, "integridad degrada, contenido informa".
9. **Idempotencia observable**: segunda corrida no duplica (archivos, entradas de `log.md`, descargas).
10. **Gate en hardware nombrado por SC** (SC-005/SC-006/SC-007) con vault real (2.696 páginas / 2.423 chunks) y una consulta semántica concreta como oráculo.

---

## 5. Gates exigidos y por qué — para anticipar los de 037

### 5.1 Qué exigió cada feature `[V]`

| Feature | Host bats + shellcheck | DOCKER_E2E | Hardware | Motivo declarado |
|---|---|---|---|---|
| 010 | Sí (test-first, stubs `bunx`/`inotifywait`) | **Sí, gated** | — | Descarga del modelo e inotify bajo bind-mount solo se prueban en contenedor; nuevas libs image-baked (`COPY`). |
| 012 | Sí (stubs systemctl/bunx/git) | **Sí** (reubicación de libs: la imagen se construye desde el workspace espejado) | mclaren (RPi5, Debian, arm64) — diferido, nunca corrió | systemd real solo existe en Linux. |
| 013 | Sí | **Obligatorio** (FR-015 lib espejada + FR-016 Dockerfile) + test de byte-identidad docker | mclaren (3 fallos predichos) + ferrari post-merge (bunx real, QMD on) | Toca lib compartida y Dockerfile. |
| 014 | Sí (fixtures de vault; flock skippeado en macOS) | **Obligatorio** (lib nueva en imagen + cron staged + `seed_missing` en boot) | mclaren + ferrari (wiki real, Syncthing, SC-006/SC-007) | "Cambio de comportamiento real en la imagen". |
| 016 | Sí (drift-guards) | **Obligatorio, des-stubeado, en tiers** (A build, B update, C embed con `QMD_EMBED_E2E=1`) + RED por build-arg | ferrari (musl real) | "El stub de bunx fue exactamente lo que ocultó BUG 4". Se mergeó sin correrlo → 017. |
| 017 | Sí (guardrail + swap con mocks) | **Sí** (`QMD_EMBED_E2E=1`, embed+vsearch reales, RED) | ferrari | Binding nativo solo carga en musl real. |
| 018 | Sí (stub `_qmd_run` para lógica del loop) | **Sí** (lib espejada) + sanity en contenedor Alpine real | ferrari SC-006 (abierto) | Lib espejada → DOCKER_E2E mandatorio. |
| 019 | Sí (seam canónico) | Diferido (tests-only) | — | Sin cambio de producción. |

### 5.2 Regla de decisión que se desprende `[I]` (respaldada por el gotcha "docker lib needs explicit COPY; cambios de boot exigen DOCKER_E2E" del CLAUDE.md del repo `[V]`)

- **Solo host bats** basta si el cambio vive en `modules/vault-skeleton/`, `modules/vault-deltas/`, docs, o en tests. Las suites que ya cubren ese terreno: `tests/vault.bats`, `tests/vault-upgrade.bats` (`vault_seed_missing`), `tests/wiki-graph.bats` (fixtures `tests/fixtures/vault-graph/`), `tests/schema.bats`.
- **DOCKER_E2E obligatorio** si se toca cualquier lib espejada (`scripts/lib/{vault,wiki_graph,qmd_index,backup_vault,rag_obs}.sh`), `docker/`, una línea de crontab staged por `heartbeatctl`, o el hook de boot `seed_vault_if_needed`. Nota: el 019 dejó el Tier-1 de `docker-e2e-qmd.bats` sin validación Docker registrada; la primera corrida real de 037 podría destapar drift ahí (§3).
- **Hardware** cuando el SC depende de escala real (2.696 páginas), de Syncthing, de systemd (timers, PATH, kill-switch) o de musl (embed). Precedente duro: **correr el gate de hardware ANTES del merge** (024 lo instauró tras 021/022; 013/014/016 pagaron por diferirlo).
- **Touchpoints de tests** si 037 agrega claves a `agent.yml`: `known_external` en `tests/schema.bats` (ambos arrays); `wizard_answers` y el array de `e2e-smoke.bats` **solo** si se agrega un prompt de wizard (014 D4 y memoria `wizard-prompt-test-touchpoints` `[V]`).
- **Upgrade aditivo**: si 037 agrega carpetas/plantillas/secciones de schema, el mecanismo ya existe y tiene contrato: `vault_seed_missing TARGET SKELETON DELTAS_DIR [TODAY]` (`scripts/lib/vault.sh:52-70` `[V]`) + `modules/vault-deltas/schema-updates-<version>.md` + sentinel oculto `_templates/.schema-updates-<version>.applied` + entrada en `log.md`, disparado en boot docker, `--login` local y `--regenerate` (014 FR-016/FR-017). SC de referencia: "0 archivos preexistentes modificados (hash)" e idempotencia en segunda corrida.

---

## 6. Menciones previas a PARA, Second Brain, Zettelkasten, Progressive Summarization o "projects"

**Resultado: ninguna.** `[V]` Comando ejecutado sobre `specs/`, `docs/`, `modules/`, `README.md` y `CHANGELOG.md` (excluye el vault personal `Agentic Pod Lanuncher/`, que no es parte del repo):

```bash
grep -rnw 'PARA' specs docs modules/vault-skeleton modules/vault-deltas README.md CHANGELOG.md     # 0 hits
grep -rniE 'second brain|zettelkasten|progressive summari|tiago|forte\b|intermediate packet|favorite problems|weekly review|monthly review|building a second' specs docs modules README.md CHANGELOG.md
# únicos hits: 'forte' dentro de "America/Santiago" no; en realidad matchea "TIMEZONE … Santiago" por 'forte'? No — los 5 hits son líneas de TIMEZONE que contienen "Region/City" ... revisados uno a uno: ninguno es una mención al método.
```

Los cinco hits del segundo grep son líneas de `docs/agentic-quickstart.{en,es}.md` y `docs/creating-an-agent.md` sobre `TIMEZONE` (`[V]`, revisadas); no hay mención al método ni al autor.

`projects` aparece solo como: ejemplo de `entity` ("person, product, tool, **project**, place, organization", `modules/vault-skeleton/CLAUDE.md:39`; `index.md:21`; `docs/vault.md:309`) y en la ruta de auto-memoria `~/.claude/projects/-workspace/memory/` (`CLAUDE.md:173`, `docs/vault.md:286`). `[V]`

### 6.1 Vecinos conceptuales ya existentes (mapa `[I]`, no decisiones)

Aunque nadie nombró CODE/PARA, varias piezas vigentes se solapan con ellos y **condicionan** cómo 037 puede integrarlos sin re-litigar §2.1:

| Concepto Forte | Lo más cercano que ya existe | Implicancia |
|---|---|---|
| Capture | `raw_sources/` inmutable (capa 1) + protocolo ingest paso 1 "Clip the source" | Ya cubierto; cualquier "capture" nuevo debe respetar "never modify the source content again". |
| Organize (PARA: Projects/Areas/Resources/Archives) | **No existe una dimensión de organización por accionabilidad.** La organización actual es **por tipo de página** ("the only six") + `status: draft\|active\|stale\|superseded` + `tags` en frontmatter. "Ongoing project state" está asignado a **auto-memoria**, no al vault (`CLAUDE.md:171-183`, `docs/vault.md:286-292`). | Meter PARA como **tipos** nuevos choca con "the only six" y con la ratificación de 014. El precedente compatible es el de `wiki/normalization/`: carpeta-convención con frontmatter propio, o un campo de frontmatter (p. ej. un eje de accionabilidad) validado por el linter. También hay que resolver la frontera con auto-memoria para "Projects". |
| Distill (Progressive Summarization) | Cadena `summary → concept/entity → overview → synthesis`; regla "Synthesize, don't paste"; "File good answers back" (query paso 5) | Ya hay capas de destilación por tipo; no hay capas de resaltado dentro de una página. |
| Express / Intermediate Packets | `overview`/`synthesis` como "meta-pages"; reporte de lint como `wiki/synthesis/lint-<date>.md` | Los "packets" reutilizables ya tienen un lugar (synthesis); un tipo nuevo re-litiga §2.1. |
| Archives | `status: superseded` + regla stale (014 R10: solo `status: active` reporta stale) | Archivar por estado ya existe; archivar por carpeta no. |
| Weekly/monthly review; project checklists | "Maintenance triggers … Periodically — once a month is usually enough" (`CLAUDE.md` §Maintenance triggers); lint determinista cada 6 h (014); lint agéntico manual/on-demand (backlog: programado) | Un review programado con LLM es exactamente el "lint agéntico programado" que 014 dejó en backlog por costo de tokens — reabrirlo requiere justificar el costo, no re-diseñar. |
| 12 Favorite Problems | Sin equivalente | Terreno libre; encaja como página de schema/convención más que como tipo. |
| `index.md` / `log.md` | Content-oriented vs time-oriented (ya existen, con drift detectado por el linter) | Cualquier índice PARA debe convivir con el `index.md` por tipo que el linter valida (drift bidireccional, 014 D8). |

---

## 7. Qué NO re-litigar en 037 (síntesis operativa) `[I]`

1. **No** proponer un séptimo `type` ni renombrar los seis subdirs de `wiki/` — usar el patrón carpeta-convención/frontmatter de `normalization/` o un campo de frontmatter, y entregarlo a vaults existentes vía `schema-updates-<version>.md` + sentinel oculto.
2. **No** tocar el `CLAUDE.md` del vault desde scripts (capa co-evolucionada); **no** editar páginas desde scripts (el linter reporta, el agente corrige).
3. **No** proponer skills `/vault:*` sin antes mostrar la fricción que `docs/vault.md:542` pide como condición.
4. **No** proponer grafo en base de datos, embeddings remotos, base glibc, parche del motor qmd, ni bump casual de qmd (checklist + dos guardrails).
5. **No** poner locks, tmp ni artefactos derivados `.md` dentro del vault; derivados = JSON en `.graph/`, jamás respaldados.
6. **No** agregar campos a `agent.yml` sin defaults precomputados en `setup.sh`, validación de forma en `schema.sh` y el touchpoint `known_external`.
7. **No** mergear con el gate de hardware diferido si el SC depende de escala real, Syncthing o systemd — el precedente (013/014/016) ya costó tres features correctivas (015/017/018).
8. Reabrir el **lint agéntico programado** solo con un argumento de costo de tokens, porque esa fue la razón del rechazo en v1.

---

## Anexo — comandos de verificación usados `[V]`

```bash
git log --format='%h %ad %s' --date=short | grep -E '\(#(13|16|65|67|68|69|71|72|73|74)\)'
git show --stat --format='%h %ad %s' --date=short 1915fc2
git log --format='%h %ad %s' --date=short -S'Why no slash-command' -- docs/vault.md   # 9f11f01 (#16)
grep -n 'vault_seed_missing' scripts/lib/vault.sh                                     # :52 doc, :70 def
awk '/^cmd_status\(\)/,/^}/' docker/scripts/heartbeatctl | grep -nE 'qmd|wiki|vault'   # solo "vault backup"
sed -n 25,26p tests/docker-e2e-qmd.bats                                               # "019 NOTE … DEFERRED"
grep -rnE 'docker-e2e-qmd' CHANGELOG.md specs/02*/ specs/03*/                          # sin corridas registradas post-019
```
