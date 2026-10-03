# I — Crítica adversarial de la síntesis H (feature 037)

**Fecha:** 25-09-2026 · **Base verificada:** `main` @ `70214d9`, VERSION `0.26.0` · **Objeto:** `H-synthesis.md` contra los informes A-G y contra el código real. Solo lectura del repo; nada modificado. No se leyó ningún `.env`, clave ni credencial.

**Método.** Cada cita `archivo:línea` de H que sostiene una decisión se releyó en el repo (lista en §6). Las atribuciones a Forte y Karpathy se cotejaron contra F y E (que a su vez marcan [HV]/[SEC]/[INF]). Las colisiones se buscaron ejecutando mentalmente el diseño (a)+(b) contra `wiki_graph.sh`, `qmd_index.sh`, `backup_vault.sh`, `vault.sh` y los tests que H declara como oráculos.

Convención: **[H]** hecho verificado hoy (`archivo:línea`); **[I]** inferencia; **[NV]** no verificable en este host.

---

## 0. Resumen ejecutivo

- La síntesis está bien anclada: de 41 citas de código revisadas, 41 apuntan a la línea correcta y dicen lo que H dice que dicen (§6). El problema no es de evidencia sino de **composición**: tres piezas del diseño recomendado chocan con oráculos y mecanismos que la propia H declara intocables.
- **ALTA (3):** (1) la página semilla `wiki/synthesis/favorite-problems.md` en el skeleton rompe el oráculo "skeleton limpio → exactamente 0 findings" que H lista como SC; (2) "index-first" se prescribe sin gate de tamaño, pero la flota tiene un vault de 2.696 páginas y el propio gist dice que a esa escala hay que usar buscador; (3) la migración de la colección qmd (gap #1, "el más barato") no tiene camino en el código actual, exige escribir config del vendor y su costo real en ferrari es ~85 min de re-embed con búsqueda semántica parcial, no "decenas de minutos".
- **MEDIA (5):** huérfanos estructurales perpetuos en fichas de proyecto/área (el parser no emite aristas desde claves nuevas de frontmatter); orden de aterrizaje higiene-antes-que-prosa (las nuevas líneas por sesión caen sobre `log.md`, que hoy está en el índice qmd); la "weekly review" de Forte no es una revisión semanal de proyectos (es de bandejas; los proyectos se revisan mensualmente); `description_missing`/`pending_ingest` producen miles de findings el día uno y `pending_ingest` exige un enumerador de `raw_sources/` que no existe; y siete decisiones del operador que H da por tomadas.
- **Respuesta a la pregunta del encargo** (¿un campo que cambia en cada review dispara re-embed y push por tick?): **no por tick, sí una vez por revisión** — `vault_hash` es por contenido de `*.md` y `.graph/*.json` queda fuera por construcción; el riesgo real es el inverso (Q9: que un cambio solo de frontmatter NO llegue al índice). Detalle en §4.
- Ninguna violación constitucional oculta en (a)+(b); sí dos tensiones no declaradas (§3).

---

## 1. Hallazgos ALTA

### A1. La página semilla `favorite-problems.md` rompe el oráculo de "0 findings" y contradice el propio principio de población perezosa

**Dónde en H:** §4.1 (skeleton: "Página semilla `wiki/synthesis/favorite-problems.md` (vacía, con instrucciones)"), D10, y a la vez SC-aditividad ("el skeleton limpio sigue dando **exactamente 0** findings") y D12 ("never pre-create", S3/R25).

**Evidencia [H]:**
- Todo `*.md` bajo `wiki/` es nodo (`scripts/lib/wiki_graph.sh:321,340`; `compute_id` `:152-157`).
- `orphan` = nodo sin entradas en `$backmap` (`:539`), y `$backmap` se construye **solo** con aristas `wikilink`/`related` entre nodos (`:518-520`). `index.md` no aporta aristas: `_wg_index_entries` (`:401-428`) alimenta únicamente `index_drift` (`:542-543`).
- En un skeleton limpio no hay ninguna otra página que enlace a la semilla → `orphan` garantizado; además, si no se lista en `index.md`, `index_drift: missing_from_index` (`:543`).
- El oráculo existe y es exacto: `tests/wiki-graph.bats:98` ("skeleton-clean vault yields exactly 0 findings").

**Consecuencia:** el diseño (a) tal como está escrito pone en rojo el test que H declara invariante, y lo hace por una página que Forte guarda "como una nota" cuando el humano la escribe (F §2.8), no por defecto.

**Corrección propuesta:** no embarcar la semilla en el skeleton. La página se crea bajo demanda desde la prosa del `CLAUDE.md` del vault ("cuando el humano declare sus problemas favoritos, crea `wiki/synthesis/favorite-problems.md` y enlázala desde `index.md` y desde la página `overview` raíz si existe"). Si el operador insiste en la semilla, hay que pagar el costo completo: excepción en el linter (código + fixture + doc), que H no presupuestó. Alternativa a evaluar por el operador: ubicarla en la raíz del vault (como `index.md`/`log.md`, fuera de `wiki/` → no es nodo), a costa de no poder wikilinkearla (`[[favorite-problems]]` sería `broken_link`, `:514`) y de citarla por ruta.

### A2. "Index-first" sin gate de tamaño choca con la escala real de la flota y con el umbral del propio Karpathy

**Dónde en H:** §3 gap #2 ("Alto a escala de la flota (< 100 fuentes: es exactamente el régimen donde Karpathy dice que el índice basta)"), §4.1 ("paso 0 index-first en query"), SC-navegación (medido en linus, vault chico).

**Evidencia [H]:**
- El vault de Cencosud en ferrari tenía **2.696 páginas** en el gate de 08-07-2026 (`CHANGELOG.md:847`: "a 2696-page Cencosud wiki"; también `CLAUDE.md` raíz, sección 015). H misma usa la cifra en §4.3 y Q6 para el presupuesto del runner, pero no la aplica al gap #2.
- `index.md` es "one line per page" (`modules/vault-skeleton/index.md:4`) → ~2.700 viñetas; con el hook `description` que (a) propone, cada línea se alarga. Leerlo entero en **cada** consulta es un costo de decenas de miles de tokens por pregunta, lo contrario de la reducción de tool calls/latencia que H cita (Ar9av, **38 páginas**, auto-reportado; G §2.5).
- El gist fija el régimen: "at small scale the index file is enough, but as the wiki grows you want proper search" y "~100 sources, ~hundreds of pages" (E §3.1 [HV]). Prescribir index-first incondicional contradice la fuente que se invoca.
- `index.md` está además en la colección qmd (`scripts/lib/qmd_index.sh:379`, máscara `**/*.md`): mientras no aterrice el gap #1, engordar `index.md` con descripciones agrava el "gravity well" (G §4.6).

**Corrección propuesta:** (1) el paso 0 se gatea por tamaño o por sección: leer solo la sección de `index.md` pertinente al tipo/proyecto activo, o un índice de dos niveles (H lo reserva a (c); debería subir a (a) para el vault grande); (2) SC-navegación se mide **también** en el vault de 2.696 páginas, no solo en linus, con dos cotas (estilo D §4.2); (3) el hook `description` en `index.md` se decide después de Q2, no antes.

### A3. La migración de la colección qmd no tiene camino en el código actual, toca config del vendor y su costo está subestimado

**Dónde en H:** §3 gap #1 ("el más barato de arreglar"), §4.1 fila qmd ("migración única gateada por sentinel"), §4.1 riesgo ("re-embebe una vez… minutos a decenas de minutos, [NV] exacto"), D8.

**Evidencia [H]:**
- `qmd_setup_if_needed` ejecuta `collection add … --mask '**/*.md'` **solo si no existe `index.sqlite`** (`scripts/lib/qmd_index.sh:377-385`); con índice presente salta directo a `update`/`embed`. Ningún path del launcher modifica una colección existente. Cambiar la raíz a `wiki/` o pasar a dos colecciones exige `collection remove` + `add` (o editar el YAML de colecciones bajo `QMD_CONFIG_DIR`), un flujo nuevo con su propio sentinel — y el sentinel debe vivir bajo el cache root en `.state/`, nunca en el vault (Syncthing, D §1 fila 014 R8), cosa que H no fija.
- `ignore:` es "YAML-only — no CLI command sets this" (G §2.26 [HV] sobre README/CHANGELOG upstream). Es decir, la forma "ignore globs" implica que el launcher **escriba un archivo de configuración de qmd**, acoplándose a su formato interno en el mismo pin que la constitución VI y `docs/qmd-upgrade-checklist.md` piden no tocar a la ligera. H lo presenta como una de tres formas equivalentes; no lo es en costo ni en riesgo.
- Costo de re-embed medido, no [NV]: 018 documentó que `qmd embed` corta a los 30 min con **859/2.423 chunks** en ferrari (`CLAUDE.md` raíz, sección 018: `store.js:1377`), o sea ≈28 chunks/min → un re-embed completo del vault grande ≈ **85 min** bajo el loop multipasada, durante los cuales `vsearch` responde con cobertura parcial. "Decenas de minutos" no describe eso. Si qmd reutiliza embeddings por content hash al recrear la colección (el mensaje "All content hashes already have embeddings" sugiere que podría), el costo baja a minutos — pero eso es **[NV]** y **no está en Q1**.
- Con la forma "raíz `wiki/`", `raw_sources/**` deja de ser consultable por qmd (Q12 solo cubre la forma "dos colecciones"); el agente conserva `Grep`, pero la semántica sobre texto crudo se pierde — decisión del operador, no detalle.

**Corrección propuesta:** (1) añadir a Q1: "¿`collection remove` + `add` sobre el mismo directorio reutiliza embeddings por content hash o re-embebe todo?" y "¿el MCP `qmd` (proceso vivo en la sesión) tolera que la colección se recree debajo?"; (2) ordenar las tres formas por acoplamiento: raíz `wiki/` (solo argumentos del CLI que ya usamos) > dos colecciones (CLI, pero Q12 abierta) > `ignore:` (escribe config del vendor, última opción); (3) declarar la migración como **acción explícita** (`agentctl heartbeat qmd-migrate`, con aviso de ventana) o como boot con aviso en `status`, y decidirlo con el operador (§2.5); (4) reescribir el riesgo de (a): "en ferrari, ≈85 min con búsqueda semántica parcial, salvo que Q1 muestre reutilización de embeddings".

---

## 2. Hallazgos MEDIA

### M1. Fichas de proyecto/área y `favorite-problems` serán `orphan` perpetuos; las claves nuevas de frontmatter no generan aristas

**Dónde en H:** §2 filas Projects/Areas ("página-MOC del proyecto: enlaza al wiki"), §4.1/4.2 (claves `area`, `problems`, `project` como wikilinks o slugs), "tres toques por clave nueva" (A §4.1).

**Evidencia [H]:** el parser emite aristas `E` únicamente desde wikilinks del **cuerpo** (`wiki_graph.sh:234-238,175`), desde `related:` (`:197,214-217,176`) y desde `sources:` (`:198,218-221,177`). Cualquier otra clave, aunque contenga `[[…]]`, se ignora (`:202-227`). Por tanto: (a) una ficha de proyecto creada en kickoff enlaza hacia afuera pero nada enlaza hacia ella → `orphan` en cada corrida hasta que otra página la cite; (b) `area: [[overviews/x]]` no cuenta como backlink de la página de área ni se valida como `broken_link`; (c) `problems: [fp-1]` no conecta con `favorite-problems.md`, que queda huérfana. El "tercer toque" de A §4.1 (rama awk + registro `N` + proyección jq) extrae valores; **no** emite aristas — hace falta un cuarto toque o una regla de prosa.

**Corrección propuesta:** elegir una de dos y declararla: (i) prosa — el kickoff incluye el paso mecánico "agrega `[[entities/<proyecto>]]` al `related:` de cada página que enlaces" (es lo que `CLAUDE.md:84-85` ya pide "si es load-bearing"; aquí lo es por definición), y lo mismo para `area`; (ii) código — el parser emite aristas kind `related` desde `area`/`project`/`problems` cuando el valor es wikilink o slug resoluble. (ii) cambia backlinks y por tanto el oráculo de la fixture; (i) no toca código pero depende de disciplina. Añadir además la política para proyectos archivados: un MOC archivado que nadie enlaza es `orphan` para siempre → o el finding `orphan` excluye `para: archive`, o se acepta como ruido y se documenta.

### M2. Orden de aterrizaje: las nuevas escrituras por sesión caen sobre archivos que hoy están dentro del índice qmd

**Dónde en H:** §2 fila Archipelago/Hemingway ("toda sesión que tocó un proyecto termina con… una línea `## [fecha] session | …` en `log.md`"), §2 filing ("`query | … | filed: yes/no` en `log.md`"), §4.1 hook de `description` en `index.md`; gap #1 (qmd indexa `log.md`, `index.md`).

**Evidencia [H]:** `vault_hash` cubre todo `*.md` del vault (`scripts/lib/backup_vault.sh:86-110`), así que cada línea nueva en `log.md` cambia el hash → el watcher (debounce 15 s, `scripts/qmd_watch.sh:77`) o el cron `*/5` corren `qmd update` (`qmd_index.sh:553-557`) y `log.md` se re-trocea; `log.md` es el archivo más caliente del vault y crece linealmente. Mientras `log.md`/`index.md` sigan en la colección, cada regla de prosa nueva que los toque **empeora** el retrieval que 037 dice mejorar (G §4.6 "gravity wells"). El push de backup no es problema (uno por hora como máximo, `heartbeatctl` cron horario), pero el costo de `update` sí es por sesión.

**Corrección propuesta:** fijar en la spec una **dependencia de fases**: la higiene del índice (gap #1) aterriza antes o en la misma release que las reglas de sesión/filing; si Q1 muestra que la higiene no cabe en 037, las líneas `session`/`filed` se difieren o se escriben en un archivo fuera de la colección. Añadir a SC-higiene: "cero documentos `log.md` en el top-10" ya está; falta "el runner de qmd no ejecuta `update` por una escritura que solo tocó `log.md`" (solo alcanzable excluyéndolo).

### M3. Atribución a Forte: la "weekly review" no es una revisión semanal de proyectos

**Dónde en H:** §2 fila "Weekly / monthly review" (F §2.9 [HV]) y D3 ("Cadencia inicial: semanal para proyectos, mensual para áreas") presentadas como el método.

**Evidencia (F §2.9, [HV] F11/F12/F15):** la weekly review vigente de Forte son cinco pasos de **bandejas** (email, calendario, Desktop/Downloads, bandeja de notas, bandeja de tareas) en 30 min, con la regla explícita de **no** revisar todas las metas cada semana ("creates overwhelming lists that kill motivation"). La revisión de la **lista de proyectos** (archivar completados, actualizar outcome, ordenar por prioridad) y de áreas es la **monthly review** (F15). La regla "horizonte por categoría / `next_review`" es R7, marcada **[INF]** por el propio informe F; "semanal para proyectos" no aparece en ninguna fuente primaria. Lo que sí es weekly en Forte y H sitúa en otra fila es la bandeja de notas → equivale exactamente al finding `pending_ingest`.

**Corrección propuesta:** reetiquetar: "Operation: weekly review" = bandeja (`pending_ingest`) + loops abiertos + elegir tareas de la semana; "Operation: monthly review" = proyectos (`review_due`, archivar, outcome) + áreas. La cadencia por defecto de `next_review` pasa a **decisión del operador** (§2.5), con "resistance as feedback" (F14) como regla de ajuste. Esto además reduce el costo de tokens: la revisión de proyectos es mensual, no semanal.

### M4. `description_missing` y `pending_ingest` sobre vaults existentes: ruido masivo el día uno y un enumerador que no existe

**Dónde en H:** §3 gap #6 ("opcional finding `description_missing`"), §4.2 (`pending_ingest`, `description_missing` como findings del runner), §4.2 riesgo ("`pending_ingest` puede arrancar con muchos findings… aceptable").

**Evidencia [H]:**
- Ninguna página existente tiene `description`; en el vault grande son ~2.696 findings nuevos en la primera corrida, y `agentctl status`/`doctor` local los cuenta (informan, pero convierten el count en inútil). `title` solo se valida por presencia (`wiki_graph.sh:171,210`; `tests/wiki-graph.bats:90-91`), así que `description: ""` pasaría igual — el finding no garantiza lo que promete.
- El runner **nunca** toca `raw_sources/` (grep `raw_sources` en `wiki_graph.sh`: 0 hits; `find` solo sobre `wiki/`, `:321,340`). `pending_ingest` = "raw sin `summary` que lo cite" exige (a) enumerar `raw_sources/**`, (b) definir el dominio (binarios con `.md` hermano según `raw_sources/README.md:57-58`, fuentes sin `.md`, `sources:` con URLs en vez de rutas), (c) normalizar rutas (`sources:` se compara como cadena, `:220,526`). Nada de eso está diseñado; Q6 mide costo, no definición.

**Corrección propuesta:** `description_missing` solo para páginas con `created >=` fecha del delta o con `para:` declarado, y exigiendo valor no vacío; `pending_ingest` con dominio explícito = `raw_sources/**/*.md` con frontmatter `clipped:`; ambos con presupuesto de Q6 (< 60 s en RPi5) medido **con** el enumerador nuevo. Considerar entregarlos como `counts` sin listar cada página en `findings.json` para no inflar el JSON que el agente lee en cada query 1.5.

### M5. Decisiones del operador que H da por tomadas

Además de D1-D12, estas quedan implícitas en las tablas de §4 y deberían ir a la ronda de decisión (recomendación primero, según regla 05):

| # | Decisión implícita en H | Dónde la fija H | Por qué es del operador |
|---|---|---|---|
| D13 | Semilla `favorite-problems.md` en skeleton vs creación bajo demanda | §4.1, D10 | Rompe un oráculo (A1) o exige excepción en el linter |
| D14 | Gate de tamaño para index-first (umbral y forma) | §4.1 paso 0 | Costo por consulta en el vault de 2.696 páginas (A2) |
| D15 | Migración qmd: automática al boot vs acción manual con aviso; forma (raíz `wiki/` / dos colecciones / `ignore:`) | §4.1 fila qmd, D8 | Ventana de ~85 min con búsqueda parcial (A3); escribir config del vendor |
| D16 | Cadencia por defecto de `next_review` y quién la fija al kickoff | D3 ("semanal") | No es de Forte (M3); es política de uso |
| D17 | ¿`doctor` local degrada (exit 1) con `para invalid` / `project_incomplete`? | §4.1 "solo si se decide elevar" | Cambia el contrato 0/1/2 de 013 |
| D18 | ¿`review_due`/`pending_ingest` se exponen en `heartbeatctl status` docker? | §4.2 | Toca `heartbeatctl` (image-baked) → rebuild + DOCKER_E2E |
| D19 | Idioma de las secciones nuevas del schema y del delta | — | El skeleton y el delta 0.8.0 están en inglés; la flota opera en español (memoria del proyecto) |
| D20 | ¿`para: archive` suprime `orphan`/`stale` para esa página? | — | Sin regla, los proyectos cerrados acumulan findings para siempre (M1) |

---

## 3. Constitución: violaciones ocultas y tensiones no declaradas

Verificado contra `.specify/memory/constitution.md:65-183` (v1.0.1).

- **I (agent.yml fuente única):** (a)+(b) no agregan claves; la constante interna con override por env tiene precedente (018 `QMD_EMBED_MAX_PASSES`). Sin violación. **Tensión no declarada:** si la forma elegida de higiene qmd es `ignore:` en YAML del vendor, aparece un segundo lugar (fuera de `agent.yml` y fuera de la lib) que define qué se indexa; si un operador lo edita a mano, `--regenerate` no lo reconcilia. Declararlo o descartar esa forma.
- **III (test-first, host-runnable):** `review_due` depende de "hoy". Para que el oráculo sea determinista el runner debe aceptar `TODAY` inyectable (`-v TODAY=` al awk, como `WIKI_GRAPH_VAULT_DIR`), y las fixtures usar fechas remotas. H no lo dice; sin eso, un test de conteo exacto se vuelve dependiente del calendario.
- **IV (idempotente, fail-silent):** sin violación. Nota: el segundo bloque de `vault_seed_missing` reutilizando la variable `changed` funciona como B §3 infiere (`scripts/lib/vault.sh:76-110`: un vault 0.8.0 con wiki vacía recibe el delta nuevo solo si el bloque nuevo creó algo, que es lo deseado); Q7 sigue siendo necesaria como test, no como duda.
- **V (estado en `.state`):** el sentinel de la migración qmd no tiene ubicación fijada en H (ver A3). Debe ir bajo el cache root de qmd, no en el vault ni en `scripts/heartbeat/`.
- **VI (pins):** intacto en (a)+(b); (c) reabre `heartbeat.sh` (workspace-templated) — H lo declara.
- **`--regenerate` / entrega:** H documenta bien que `--login` local no corre `vault_seed_missing` (verificado: `setup.sh:2841-2842` en `regenerate()`; `docker/scripts/start_services.sh:132-133` en boot; nada en `modules/local-login.sh.tpl`).

---

## 4. Respuesta a la pregunta del encargo: hash de idempotencia, re-embed y backup

**¿Un campo de frontmatter que cambia en cada review dispara re-embed y push de backup en cada tick?** No. Mecanismo verificado:

1. `vault_hash` = sha256 sobre nombre + contenido de **todo `*.md`** del vault, excluidos `.git`, `.obsidian/{cache,workspace*.json,.trash}`, `.trash`, `*.sync-conflict-*` (`backup_vault.sh:52-61,86-110`). Cambia **una vez** por edición real, no por tick.
2. `.graph/*.json` (donde viviría `review_due`) queda fuera del hash por construcción (JSON, `wiki_graph.sh:10-12`) y fuera del backup (`backup_vault.sh:93`). Que la fecha pase y el finding aparezca **no** toca ningún `*.md` → cero re-embed, cero push.
3. Lo que sí ocurre **por revisión**: K fichas editadas (`next_review`, `updated`) + `index.md` + `log.md` → un `qmd update` en el siguiente tick del watcher/cron (`qmd_index.sh:553-557`), que re-indexa solo los archivos cambiados (semántica interna de qmd, [NV]), y un commit de backup en la siguiente hora. Es el comportamiento actual para cualquier ingest; aceptable.
4. **Riesgo inverso, no el que teme el encargo:** si el hash interno de qmd mira solo el cuerpo, un cambio exclusivo de frontmatter (`para: archive`) **no** se re-indexa y el índice queda desactualizado (G §4.14, caso real cerrado 17-09-2026). H lo cubre en Q9; conviene subirlo de "pregunta" a "riesgo con mitigación" (bumpear `updated:` y una línea del cuerpo en cada cambio de `para`).
5. Efecto colateral ya conocido y bien descrito por H (gap #7): cada corrida del grafo marca `dirty` en el watcher (`qmd_watch.sh:77`, `-r` sobre el vault) y termina en `skipped` (`qmd_index.sh:538-541`). Con `review_due` cambiando a diario, `findings.json` cambia a diario → un tick vacío más por día. Barato; no cambia la conclusión.

**Costos ocultos que H no cuantifica** (a agregar a Fase 0): tokens por revisión mensual sobre el vault grande (leer `findings.json` — cuyo tamaño con `pending_ingest` puede crecer a miles de entradas —, secciones de `index.md`, K fichas); Q4 mide duración, no tokens. Propuesta: Q4 registra también el uso reportado por `claude --print` en `heartbeatctl test`.

---

## 5. Hallazgos BAJA

| # | Hallazgo | Evidencia | Corrección |
|---|---|---|---|
| B1 | H §1.5 etiqueta "rerank on-device" como [H]; A:259 lo marca **[NV]** (que el rerank no llame a red no se verificó) | A §5.2 nota | Cambiar a [NV] |
| B2 | H §2 dice que el vocabulario de ops de `log.md` es "libre" citando `vault.sh:146-153`; la función acepta cualquier op, pero el skeleton documenta un enum cerrado `{ingest\|query\|lint\|init\|other}` (`modules/vault-skeleton/log.md:9`). `upgrade` (`vault.sh:105`) ya lo viola | `log.md:9` | El delta y el skeleton actualizan la línea de formato con las ops nuevas (`upgrade`, `project-open`, `project-close`, `review`, `session`) |
| B3 | "as little as possible, as late as possible" (D12) se cita como F §2.11 sin marcar que es **[SEC, S3]** (libro 2023 vía resumen), no [HV] | F §2.11 | Etiquetar [SEC] |
| B4 | "la crítica de Sascha (F §6) dice que el valor está en L4-L5" — Sascha dice que el highlighting "is merely preparing resources" y que el procesamiento "is explicitly not part of BASB"; que el valor esté en L4-L5 es la **mitigación [INF]** del autor de F | F §6 fila "PS prepara, no procesa" | Reatribuir: "Sascha: PS prepara, no procesa; mitigación propuesta [I]: importar L4, no L2-L3" |
| B5 | §6.7 rechaza archivos por semana citando P17 (nombres fechados invierten la recencia) y en la misma viñeta admite briefs mensuales como `synthesis` con nombre fechado | H §6.7; G P17 | Decidir una regla: brief mensual con nombre sin fecha y `updated:` real, o aceptar la excepción y decirlo |
| B6 | "Cero menciones previas a PARA/Forte" (§1.12): verificado hoy (grep en `specs/ docs/ modules/ README.md CHANGELOG.md` → 0 archivos). Correcto; se registra como confirmación | grep 25-09-2026 | — |
| B7 | `20 */6 * * *` en local: verificado que `local_schedule.sh:59-63` sí convierte la forma `M */N` (el comentario del código la nombra como el default de wiki-graph). Correcto; H no lo afirma explícitamente pero su diseño lo asume | `scripts/lib/local_schedule.sh:59-63` | — |
| B8 | H llama "libs espejadas" a `vault.sh`/`wiki_graph.sh`; en el repo `docker/scripts/lib/` no las contiene — el Dockerfile las COPYa desde `scripts/lib/` del workspace (`docker/Dockerfile:266,285`). La conclusión (DOCKER_E2E obligatorio) se sostiene igual | `docker/Dockerfile:258-290` | Precisar "image-baked vía COPY" |

---

## 6. Citas de H verificadas correctas (no requieren corrección)

Releídas hoy en `main` @ `70214d9`; todas dicen lo que H afirma:

- `modules/vault-skeleton/CLAUDE.md`: `:32-46` (seis tipos, "No other types"), `:39` (`entity` incluye project), `:42-43`, `:54` (normalization "never cited"), `:57-72` (frontmatter de 8 claves, `status` enum), `:84-85` (backlinks manuales), `:92-94` (clip), `:108` (synthesis "rare"), `:118-119` (query sin `index.md`), `:120-125` (grafo), `:131-133` ("ask the human first"), `:162` (lint report en `wiki/synthesis/lint-<date>.md`), `:167-183` (tres capas, "Don't double-write"), `:185-195`, `:200` (nombres fechados solo para `lint-*`).
- `scripts/lib/vault.sh:52-57,70-112,93-94,105,146-153`; `scripts/lib/wiki_graph.sh:111-114` (enums), `:171-174` (violaciones: solo `title` ausente, `type`, `status`), `:185` (normalization no nodo), `:202-227` (11 claves; el resto ignorado; `tags` no se extrae), `:321,340` (solo `wiki/`), `:439` (`stale` solo `active`), `:441-452` (mtime fuente > `updated`+1 d), `:514` (`broken`), `:539-545` (findings), `:542-543` (`index_drift`), `:94` (counts por defecto).
- `scripts/lib/qmd_index.sh:372,379` (una colección `vault`, máscara `**/*.md`, sin exclusiones), `:538-541` (`skipped`); `scripts/qmd_watch.sh:77`; `scripts/lib/backup_vault.sh:52-61,93,100-110`.
- `modules/claude-md.tpl:92` (local: "Nothing"), `:176-193`; `docs/state-layout.md:49,55` (`project_*`; `MEMORY.md` truncado a 200 líneas — C §3.2 correcto); `scripts/lib/local_schedule.sh:44-47`; `modules/vault-skeleton/raw_sources/README.md:18`; `modules/vault-deltas/schema-updates-0.8.0.md:3-7`; `tests/wiki-graph.bats:33,65-85,98,142`; `tests/schema.bats:43`; `docs/vault.md:542`; `setup.sh:2446`; `specs/014-wiki-graph-rag/contracts/graph-artifacts.md:31-33` (`tags` prometido, no emitido); `scripts/heartbeat/heartbeat.sh` (sin `vault`; `HEARTBEAT_TIMEOUT` default 300, `:30`); `docker/scripts/heartbeatctl:290-300` (cron `20 */6`), `:350` (`cmd_status` sin qmd/wiki-graph — D §3 correcto); `docker/Dockerfile:266,285` (COPY).
- Atribuciones correctas: Karpathy "reads the index first", "often I end up filing", "data gaps/web search", cláusula "optional and modular", append-and-review como anti-PARA (E §3.1, §2.9, §6, filas 10/12/14); Forte PS 50/25/20/5/<1 % [HV F5], "Don't apply all layers to all notes", oportunismo [HV F4], IP 5 tipos [SEC], favorite problems "una nota" [HV F9/F10], checklists [SEC S1], "resistance as feedback" [HV F14], F21; prior art: Ar9av (auto-reportado), qmd #975/#645, `includeByDefault`/`ignore:`/`--filter [Unreleased]`, Astro-Han, second-brain-os, Mandalivia, Moriwaki, P1-P20 y G §7.1.

---

## 7. Preguntas de Fase 0 que faltan (complemento a Q1-Q12)

| # | Pregunta | Desbloquea |
|---|---|---|
| Q13 | ¿`qmd collection remove` + `add` (o el cambio de raíz) reutiliza embeddings por content hash o re-embebe los 2.423 chunks? ¿El MCP `qmd` vivo tolera la recreación? | A3 / D15 |
| Q14 | Tamaño real de `index.md` y de `findings.json` en el vault de 2.696 páginas (líneas y bytes; sin imprimir contenido) | A2 / M4 / D14 |
| Q15 | Tokens por turno de revisión mensual y de kickoff (uso reportado por `claude --print`), además de la duración de Q4 | §4 costos |
| Q16 | ¿Cuántas fichas `entity` de la flota son hoy "proyectos" (para dimensionar M1 y la migración de `project_*`)? Conteo por `docker exec -u agent`, sin contenido | D2 / M1 |

---

## 8. Veredicto

La síntesis es utilizable como base de `/speckit-specify` **después** de: retirar la página semilla del skeleton (A1), gatear index-first por tamaño y medirlo en el vault grande (A2), rediseñar la migración qmd como flujo propio con su costo real y su sentinel en `.state` (A3), resolver la política de aristas/backlinks para fichas PARA (M1), secuenciar higiene antes que prosa (M2), reetiquetar weekly/monthly según Forte (M3), gatear los findings nuevos (M4) y llevar D13-D20 a la ronda de decisión del operador. Ninguna de estas correcciones invalida la recomendación central "(a) + subconjunto de (b), sin séptimo tipo, sin claves nuevas, sin bump de qmd"; todas la hacen ejecutable.

