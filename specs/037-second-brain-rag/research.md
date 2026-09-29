# Research — 037 Second Brain sobre el LLM Wiki (Fase 0)

**Branch**: `037-second-brain-rag` | **Date**: 2026-09-27 | **Spec**: [spec.md](spec.md) | **Plan**: [plan.md](plan.md)

Fuentes: los doce documentos de discovery archivados en [`discovery/`](discovery/) (A libs RAG, B config y
render, C schema y runtime, D historia de specs 010-019, E fuente primaria de Karpathy, F método de Forte, G
prior art 2025-2026, H síntesis, I crítica adversarial de H, J decisiones del operador, K mapa de puntos de
cambio verificado línea a línea, L mediciones de qmd 2.5.3) más el digest del PDF de Forte. Convención:
**[H]** medido o leído con `archivo:línea`; **[I]** inferencia; **[NV]** no verificable en este host;
**[BLOQ]** medición bloqueada por acceso a la flota (ferrari no responde: `Connection timed out during
banner exchange` el 26-09-2026; reautenticación de Cloudflare Access pendiente del operador).

## 1. Decisiones

Formato: Decisión / Racional / Alternativas descartadas. Las D1-D12 nacen de H §5, las D13-D20 de I M5, las
R* de las rondas AskUserQuestion (spec Clarifications).

| Id | Decisión | Racional | Alternativas descartadas |
|---|---|---|---|
| R1 | Alcance **(c) ambicioso**, una spec, un PR | Elección del operador; el diseño completo se fija ahora y se mide uso después | (a) mínimo, (a)+(b) medio, dos PRs, dos specs |
| R2 / D1 | PARA en **frontmatter** sobre los seis tipos | Cero costo en el linter hoy (`wiki_graph.sh:202-227` ignora claves desconocidas); no rompe wikilinks ni `compute_id`; unánime en el prior art (G §7.1); coherente con "the only six" (014) | Carpetas PARA (todo `[[…]]` hacia fuera de `wiki/` es `broken_link` `:514`); ambos |
| R3 / D8 | Colección qmd con **alcance `wiki/`** dentro del pin 2.5.3 | Gap #1 de H; qmd indexa hoy 14 de 23 documentos de ruido en un vault mínimo (L Q2 [H]); solo argumentos del CLI | Bump a ≥ 2.8 (filtro por metadatos no liberado; reabre 016/017); `ignore:` en YAML del vendor (funciona [H] pero el CLI reescribe ese archivo); trabajar alrededor |
| R3-bis | Máscara `wiki/**/*.md` sobre la **raíz del vault** (no raíz `wiki/`) | Medido (L Q3 variante B [H]): mismo resultado que raíz `wiki/` y conserva las URIs `qmd://vault/wiki/...` que el agente ya cita; refinamiento de R3 sin cambiar la decisión | Raíz `<vault>/wiki` (cambia URIs a `qmd://vault/summaries/...`) |
| R4 / D3 | **Cola determinista** (`review_due` en el runner) + ejecución en sesión; cadencia **semanal** proyectos, mensual áreas | Prior art unánime "el agente prepara, el humano decide" (G P11); local no tiene tick LLM (`claude-md.tpl:92`); `local_schedule.sh:44-47` no convierte crons semanales; el lint agéntico programado fue rechazado en 014 por costo | Heartbeat como motor; manual |
| R5 / D2 | Ficha de proyecto en el **vault + puntero** en auto-memoria | "Don't double-write" (`CLAUDE.md:183`); `MEMORY.md` se trunca a 200 líneas; el vault tiene grafo, backup y búsqueda | Auto-memoria como hoy; retirar `project_*` |
| R6 | Heartbeat **opt-in, solo avisa** | Única pieza con tick LLM y la de menor evidencia; apagada por defecto | Ejecuta la revisión; sin heartbeat |
| R6-bis (clarify) | **Entrada semanal aparte** con `--prompt`/`--trigger` propios; `heartbeat.sh` no cambia (K §5 [H]) | Un mapa por día repetiría el aviso en cada tick del día; el runner ya parsea `--prompt` y `--trigger` (`heartbeat.sh:37-43`) | Mapa día → prompt con dedupe en `heartbeat.sh` |
| R6-ter (clarify) | Cola vacía → línea **"sin pendientes"** (`nothing pending` en `en`) | Distingue "nada" de "heartbeat muerto"; cero cambio en notifiers | Silencio (exige suprimir envío en `heartbeat.sh`) |
| R7 | Skeleton, delta y plantillas en **inglés** | Consistencia con skeleton, delta 0.8.0, docs, README; strings que los tests grepean | Español; bilingüe |
| R8 (clarify) | Umbrales por defecto: proyecto 7 d, área 30 d, `archive_candidate` 90 d, `schema_delta_pending` 14 d, `problem_unfed` 30 d, index-first completo < 300 páginas | Paquete propuesto aceptado; configurables | Conservador; agresivo |
| R9 (clarify) | Loops abiertos **por el runner**: `project_overdue` + `project_incomplete` (extendido a `next_action`) | Mismo patrón que `review_due`; gratis en tokens; visible en `status` y en el aviso | El agente los infiere leyendo fichas |
| R10 (2026-09-27) | Migración de colección **automática, una vez**, en el primer tick de reindex; `qmd-migrate` manual = `--dry-run`/forzado | La premisa "85 min" era falsa: `remove`+`add` reutiliza embeddings, cuesta segundos (L Q4 [H]); cero acciones en cinco agentes | Explícita (decisión previa, superada) |
| D4 | Destilación **oportunista** | Regla literal de Forte (F R16); un pase batch es una reescritura masiva por LLM sin puerta (G §4.2) y, medido, re-embebería cada página tocada (L Q5) | Batch periódico; híbrido (038) |
| D5 | **Sin séptimo `type`** ni valores nuevos de `status` | Contrato de tres capas (prosa, código `:111`, tests `:33`); ratificado en 014; `entity` ya admite "project" | Tipo `project`/`packet` |
| D6 | Archivo por frontmatter en el mismo archivo; democión por protocolo; **sin mover** | Mover rompe wikilinks e ids; el índice ya no incluye ruido estructural tras R3 | Carpeta `archive/` + stub; colección aparte; filtro del motor |
| D7 | Ambos modos para skeleton/schema/linter/higiene; heartbeat docker-only opt-in | Paridad costó 30 gaps en 013; la única asimetría real (heartbeat) ya está documentada | Docker primero |
| D9 | Entrega por **delta** 0.27.0 + marcador con fecha + hallazgo `schema_delta_pending` | Append y reemplazo rechazados en 014 R7; el hueco "petición sin verificación" (C §6.13) se cierra con un finding | Reemplazo opt-in; delta sin finding |
| D10 / D13 | Favorite problems = **una página del vault creada bajo demanda**; nunca semilla en el skeleton | Una semilla en `wiki/` es `orphan` por construcción y rompe el oráculo "skeleton limpio = 0" (`wiki-graph.bats:98`; I A1) | Semilla en skeleton; `MEMORY.md`; `agent.yml` |
| D11 | `packet:` tipado sobre el tipo natural + `packets.json` | Sin tipo ni directorio nuevo; `synthesis` sigue siendo raro | `wiki/packets/`; sin marca |
| D12 | `para` ausente = `resource`, sin violación | Población perezosa; ningún vault existente cambia; skeleton limpio sigue en 0 | Obligatorio |
| D14 | Index-first **gateado**: `overview` del dominio + secciones PARA de `index.md` + ficha activa; `index.md` completo solo bajo 300 páginas | El vault de ferrari tiene 2.696 páginas; el gist mismo fija el régimen "< 100 fuentes" (I A2) | Incondicional |
| D17 | Findings nuevos **informan, no degradan** `doctor` | Contrato 0/1/2 de 013 intacto; la cola es información | WARN por `para invalid` |
| D18 | `heartbeatctl status` docker gana wiki-graph y qmd (cierra deuda 013) | El rebuild ya es obligatorio (libs image-baked); `cmd_status` no tiene exit por contenido (K §4) | Dejarlo |
| D20 | `para: archive` suprime `orphan` y `stale` | Un proyecto cerrado no acumula hallazgos para siempre (I M1) | Ruido aceptado |
| M1 | Aristas desde `project`/`area`/`problems` **por código** (kind `related`) | El parser solo emite aristas desde cuerpo/`related`/`sources` (K §1); reutilizar `related` da `broken` y backlinks gratis | Solo disciplina de prosa |
| M2 | Higiene qmd aterriza **antes** que las reglas que escriben en `log.md`/`index.md` (orden de fases) | Mientras `log.md` esté en la colección, cada línea nueva empeora el retrieval (I M2) | Orden libre |
| M3 | Weekly = bandeja + loops + proyectos `review_due`; monthly = áreas + archivo + outcome | Fidelidad a Forte con la cadencia del operador (I M3) | "Semanal" como método de Forte |
| M4 | `description_missing` gateado (`para:` o `created >= DELTA_DATE`); `pending_ingest` con dominio `raw_sources/**/*.md` + `clipped:` | Sin gate, miles de hallazgos el día uno en el vault grande (I M4) | Sin gate |
| K1 | Deltas siguen gateados por `vault.seed_skeleton: true` (contrato vigente); documentado y verificado en el gate | Desacoplar cambiaría la semántica para quien apagó el seed a propósito (K riesgo 1) | Desacoplar upgrade del seed |
| K2 | Bloque 0.27.0 con flag propio, evaluado **después** del check 0.8.0 | `changed` compartido (`vault.sh:76`, guard `:100`) provocaría un delta 0.8.0 espurio (K riesgo 2) | Reusar `changed` |
| K3 | Fechas en **jq** (`strptime`/`mktime`), `TODAY` inyectable (`WIKI_GRAPH_TODAY`, UTC) | Medido: jq 1.8.1 (Alpine) y 1.7.1 (macOS) dan 25 días entre 2026-09-01 y 2026-09-26; awk BSD no tiene `mktime`; `date -d` difiere BSD/GNU/busybox | awk; `date` |
| K4 | Prompt del aviso en **archivo** `review-prompt.txt` escrito por `cmd_reload`; minuto por defecto **7** (`7 9 * * 1`) | 4000 chars con comillas dobles y `$` no caben legibles ni seguros en una línea de crontab; el archivo sigue el molde de `heartbeat.conf`. Medido en la imagen (BusyBox 1.37.0, N §4): `%` NO es salto de línea en busybox crond y `$(cat …)` se expande en `/bin/sh -c` — la justificación original por `%` era falsa. El tick regular `*/N` no cae en el minuto 7 → sin `skipped` por colisión (K riesgo 11) | Inline; minuto 0 |
| N1 | La octava línea del crontab se concatena a la de wiki-graph con `review_line=$'\n'…` | Una línea propia en el heredoc agrega una línea en blanco cuando está deshabilitado y rompe el oráculo byte-idéntico (N C1) | Línea propia |
| N2 | Sentinel de layout SOLO tras un `collection add` exitoso en `_qmd_setup_locked` | La rama re-entrante `:383-385` no cambia la colección; un índice heredado quedaría `wiki-root` sin migrar (N C6) | Tras `:397` (camino común) |
| N3 | `has_pages` del bloque 0.27.0 con `[ -n "$(find … -print -quit)" ]`, no `find \| head -1 \| grep -q .` | El molde de `:97` es la carrera SIGPIPE bajo `pipefail` documentada en CLAUDE.md: medido FALSE 200/200 con 3.000 páginas en bash 3.2 y 5.3 (N §2). El bloque 0.8.0 queda byte-idéntico (inocuo hoy: la flota tiene el marcador); deuda registrada | Copiar el molde |
| N4 | Fixture "0.8.0 vacía" = skeleton pre-037 SIN marcador ni delta 0.8.0 | Es el estado real de un agente sembrado post-014 con wiki vacía (el guard fresh-scaffold nunca le depositó el 0.8.0) y hace matable la mutación M10 (N C9) | Con marcador |
| N5 | Línea de revisión independiente de `features.heartbeat.enabled` | Misma semántica que las otras seis líneas de mantenimiento; `pause` solo comenta la principal (N C15); registrado en FR-032 (M U7) | Gatearla |
| M1 | `qmd-migrate` sin flags **idempotente** (`already migrated`, rc 0), `--dry-run` imprime, `--force` recrea | Tres artefactos daban tres semánticas distintas a la acción manual (M I3) | Sin flags = forzar |
| M2 | FR-009 acota `doctor` a local; docker remite a `heartbeatctl status`; el estado se calcula **en vivo** (sentinel + `index.sqlite`) | `agentctl doctor` docker no toca qmd (`:580-591`) y nadie lo cubría (M G1); el state lo escribe el mismo tick que migra, así que `pending` solo es observable en vivo (M U2) | Línea nueva en `doctor` docker vía `docker exec` |
| M3 | El scaffold nuevo nace con el marcador 0.27.0 fechado (`vault_seed_if_empty`); sin marcador, `description_missing` gatea solo por `para` | Con `seed_skeleton: false` nunca llega el marcador y la regla "sin marcador = scaffold nuevo" produciría miles de hallazgos en el vault grande (M U3); regla única del marcador: parsea → fecha, no parsea/vacío → mtime, ausente → `""` (M I5) | Gatear solo por `para` siempre |
| M4 | Lista canónica de siete contadores de `status` en orden fijo (data-model §6) | Cinco artefactos listaban 5, 6 o 7 (M I2) | — |
| M5 | 3.9 Filing policy y 3.10 Session close se escriben en T021, después de la higiene qmd | FR-011 exige que las reglas que escriben en `log.md` aterricen tras la higiene; T006 las adelantaba (M I8) | Relajar FR-011 |
| K5 | `_v_cron5` valida solo la línea nueva; las otras seis siguen verbatim | No cambiar comportamiento heredado (K riesgo 13) | Validar todas |
| K6 | Fixture 014 intacta + golden de sus 7 hallazgos; fixture **nueva** `vault-graph-para` para los kinds nuevos | Hace literal el SC "seis hallazgos previos byte-idénticos" | Extender la fixture 014 (re-baseline opaco) |
| K7 | Sin `--timeout` por invocación en `heartbeat.sh`; `< 60 s` se **mide** (SC-007) | No tocar el runner del heartbeat (workspace-templated, la flota lo corre) | Agregar `--timeout` |
| K8 | `policy.json` como canal de las perillas al agente; el runner lee `agent.yml` con yq (molde `wiki_graph_enabled` `:49-60`) | El `CLAUDE.md` del workspace no se refresca en agentes existentes (B §2.2); el del vault no se toca | Renderear en `claude-md.tpl`; prosa con números fijos |

## 2. Mediciones de Fase 0

| # | Pregunta | Resultado | Fuente |
|---|---|---|---|
| Q1 | Superficie de exclusión de qmd 2.5.3 | [H] Solo `--name`/`--mask` en `collection add`; flags desconocidos ignorados en silencio; `collection remove/rm` existe; `ignore:` solo por YAML (`$QMD_CONFIG_DIR/index.yml`); `--mask` acepta subdir, llaves y extglob; `include/exclude` escribe `includeByDefault` | L Q1 |
| Q2 | Degradación del top-K | [H parcial] En el vault sintético de 23 `.md`, 14 documentos indexados son ruido (schema, índice, log, 8 plantillas, 3 raw) y cada uno es alcanzable por búsqueda léxica. Hit-rate sobre un vault real: **[BLOQ]**, protocolo en `quickstart.md` §5 para el gate | L Q2 |
| Q3 | ¿La sesión del heartbeat carga los MCP `vault`/`qmd`? | **[BLOQ]**. Irrelevante por diseño: el prompt del aviso lee `findings.json` y `wiki-graph.json` por ruta con `Read` | K §5, contrato heartbeat |
| Q4/Q15 | Duración y tokens de kickoff/close/weekly | **[BLOQ]** → gate de despliegue en linus (`runs.jsonl`, `telegram-mcp-stderr.log`) | quickstart §6 |
| Q5/Q16 | Estado de la flota (páginas por tipo, delta 0.8.0 integrado, `project_*`, `seed_skeleton`) | **[BLOQ]** → checklist de despliegue (conteos por `docker exec -u agent`/ssh, sin contenido) | quickstart §6 |
| Q6/Q14 | Costo del runner y tamaño de `index.md`/`findings.json` sobre 2.696 páginas | **[BLOQ]** → gate de hardware antes del merge (SC-005) | quickstart §6 |
| Q7 | Segundo bloque de `vault_seed_missing` en tres estados | [H por lectura] `changed` compartido y guard fresh-scaffold (`vault.sh:76`, `:96-100`); diseño K2; se cubre con tres fixtures | K §2 |
| Q8 | `inotifywait` de Alpine excluye `.graph/`? | [H] `inotify-tools 4.23.9.0-r0`: `--exclude <pattern>` y `@<file>` existen (solo el último `--exclude` cuenta); también presente en `agentic-pod:latest` | medición directa 26-09 |
| Q9 | ¿`qmd update` re-indexa cambios solo de frontmatter? | [H] Sí: `1 updated`, `Pending: 1`, buscable por FTS; `touch` sin cambio de bytes → `0 updated`. Mitigación de `updated:` retirada | L Q5 |
| Q10 | Index-first en la flota | **[BLOQ]** → gate (10 preguntas sonda, vault chico y grande) | quickstart §5 |
| Q11 | ¿`heartbeat.sh` necesita cambio? | [H] No para `--prompt`/`--trigger` (`:37-43`); sí lo necesitaría para `--timeout` por invocación (no se hace) | K §5 |
| Q12 | Raw consultable con dos colecciones | Moot: la máscara sobre la raíz deja `raw_sources/` fuera y el MCP `query` acepta `collections: string[]` si algún día se agrega una colección `raw` (`includeByDefault: false`) | L Q6 |
| Q13 | ¿`remove`+`add` reutiliza embeddings? | [H] **Sí**: vectores indexados por hash + modelo + fingerprint; `removeCollection` no los toca; `embed` → "All content hashes already have embeddings" en 0,1 s. `cleanup` después, nunca entre medio | L Q3/Q4 |
| jq | `strptime`/`mktime` en Alpine y macOS | [H] jq 1.8.1 (imagen) y 1.7.1 (host): 25 días entre 2026-09-01 y 2026-09-26; busybox `date -d YYYY-MM-DD` también funciona; awk BSD sin `mktime` | medición directa 26-09 |
| flota | Alcance a ferrari | [BLOQ] `ssh -o BatchMode=yes ssh-ferrari` → banner timeout | medición directa 26-09 |
| imagen | `agentic-pod:latest` disponible en este host (Alpine 3.24.1, aarch64, bun 1.3.14, 5 días) | [H] DOCKER_E2E se puede correr de verdad aquí | `docker images` |
| T002 | Golden de `vault-graph` (7 hallazgos, lib pre-037) | [H] `tests/fixtures/vault-graph.findings.golden.json` sha256 `26f403a028c2b84bb165f3d0b30ebdcd7fdff58b66f5fa05143175863663a26b` | ejecución directa `wiki_graph_run` sobre la fixture, `.graph/` borrado tras copiar |

## 3. Riesgos de implementación y disposición

De los 17 de K más los de I:

| Riesgo | Disposición |
|---|---|
| `seed_skeleton: false` apaga los deltas | K1: documentado en spec/docs; verificación por agente en el gate |
| `changed` compartido en `vault_seed_missing` | K2: flag propio; test "0.8.0 vacía no recibe delta 0.8.0 espurio" |
| Marcador 0.8.0 vacío → edad solo por mtime | 0.27.0 escribe `deposited: <fecha>` (CANON-D13); fallback mtime |
| `N`/jq posicionales | Orden canónico fijado en el contrato del runner; golden de la fixture 014 lo delata |
| `para` en `SRCN` | Columna añadida; test de archive+stale |
| Sin `TODAY` | `WIKI_GRAPH_TODAY` (UTC) en todas las comparaciones nuevas |
| Detección de colección heredada sin parsear al vendor | Sentinel `.qmd-collection-wiki` + `index.sqlite`; el borde "setup interrumpido" es inocuo (contrato qmd §2) |
| `collection remove` fuera del contrato 010 y del stub | Verbo medido [H]; stub extendido; nota de superación en `qmd-cli.md` |
| Setups de test sin `wiki/` | Se crean; la raíz sigue siendo el vault |
| `schema.bats:42-43` set exacto | Touchpoint obligatorio en tasks |
| Colisión tick regular vs semanal | Minuto 7 por defecto + doc |
| `state.json.prompt` mezclado | Cosmético; documentado |
| Sin validador de cron | `_v_cron5` solo para la línea nueva |
| `HEARTBEAT_TIMEOUT` global | Se mide, no se impone |
| `vault_hash` compartido con backup | No se toca; se acepta el `update` extra |
| Watcher sin `--exclude .graph/` | Opcional en tasks (medido viable); no bloquea |
| Drift documental del contrato 014 (`title`/`tags`) | Se corrige el contrato al extraer `tags` |
| MCP `qmd` vivo durante `remove`+`add` | WAL; ventana de segundos; documentado [NV] |
| Ventana de divergencia imagen/schema en el despliegue | Orden fijado (rebuild → boot deposita → agente integra); hallazgos esperados en el intervalo |
| Ferrari inalcanzable | Gate de hardware bloqueado hasta la reautenticación; el resto de gates (host dual, DOCKER_E2E, linus si vuelve el acceso) no dependen de ello |
| `has_pages` del bloque 0.8.0 (`vault.sh:97`) es una carrera SIGPIPE bajo `pipefail` (medido N §2) | Deuda declarada, no se toca en 037 (bloque byte-idéntico; la flota ya tiene el marcador 0.8.0). El bloque 0.27.0 usa la forma segura. Candidata a fix aparte |
| El arnés `docker-e2e-vault.bats` siembra un skeleton FRESCO: el guard fresh-scaffold impide el delta | El e2e de depósito del delta pre-siembra `vault-populated` en `.state/.vault` (N C4); el caso fresco asserta la AUSENCIA del delta (molde `docker-e2e-qmd.bats:249-252`) |
| `wiki_graph_run` sin `agent.yml` resuelve `/workspace/agent.yml` y sale `disabled — skip` en host | Todo comando manual y el golden pasan un `agent.yml` temporal con `vault: {enabled: true}` (N C7) |
| `--migrate --dry-run` local ejecutaría el setup real si el dispatch va tras `:51` del wrapper | Dispatch de `--migrate` antes de `qmd_setup_if_needed` (N C10) |

## 4. Lo que la Fase 0 no midió y queda para el gate de despliegue

Q2 (hit-rate real), Q4/Q15 (duración y tokens por operación), Q5/Q16 (estado de la flota), Q6/Q14 (runner
y tamaños sobre 2.696 páginas), Q10 (index-first). Todos tienen protocolo en `quickstart.md` y ninguno
cambia el diseño: cambian umbrales (`index_first_max_pages`, cadencias) o la forma de exponer contadores
(lista vs solo count para `pending_ingest`/`description_missing`), que son perillas.
