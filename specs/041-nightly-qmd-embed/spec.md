# Feature Specification: El nightly de docker-e2e ejercita el embed real de qmd

**Feature Branch**: `041-nightly-qmd-embed`

**Created**: 2026-10-14

**Status**: Draft

**Input**: El nightly `docker-e2e` está verde desde 039 y ejecuta los 48 e2e, pero el test del qmd real (`qmd real (016)`) pasa sin ejercer el embed: esa fase solo corre con `QMD_EMBED_E2E=1`, el workflow no la define y el test no figura como saltado. El operador quiere que una regresión del embed (sqlite-vec, llama.cpp, el modelo, la pila de musl, la búsqueda semántica) se vea como una noche en rojo con su causa, y no solo en el despliegue a hardware.

## Contexto

El workflow `.github/workflows/docker-e2e.yml` corre por `schedule` y `workflow_dispatch` en `ubuntu-latest` (amd64), con `permissions: contents: read` y un tope de 30 minutos por job, y ejecuta con `DOCKER_E2E=1` todos los `tests/docker-e2e-*.bats` (48 tests en 13 archivos, conteo de la corrida 37873376103). Desde el merge de 039 (09-10-2026) lo hace de verdad. La rama `040-nightly-red-alert` (sin mergear) le agrega un aviso al mantenedor cuando una noche termina en rojo. Esta feature trata de lo que el verde de ese nightly todavía no dice.

**Qué cubre hoy el test del qmd real y qué no** (verificado en `tests/docker-e2e-qmd.bats` el 14-10-2026). El test `qmd real (016): native deps compile with toolchain; RED without it (SC-003)` siempre construye la imagen con la toolchain y comprueba la fase A: la extensión vectorial `vec0.so` horneada es musl, `_qmd_run --help` termina con rc 0 y existe el `cmake` de apk. Al final reconstruye sin toolchain y comprueba que esos artefactos desaparecen (detección RED). La fase del embed real (Tier 2) vive dentro de `if [ "${QMD_EMBED_E2E:-0}" = "1" ]` (línea 669; en adelante, esa variable es la «puerta» de la fase) y comprueba: el arranque con `docker compose up` y el centinela `.qmd-setup-ok` (espera de hasta 600 s), que existe un modelo `*.gguf`, que el `vec0.so` del prefijo es el musl, que `heartbeatctl qmd-reindex` deja `last_status` en `ok` o `indexed` y `pending` en 0, que `qmd vsearch` devuelve el documento correcto y que el servidor MCP arranca sin las firmas del BUG-4. El workflow no define `QMD_EMBED_E2E`, así que el nightly nunca ejerce el embed, y el test termina en verde sin avisarlo: no figura como saltado (CHANGELOG de 039, «Not a coverage claim»; CLAUDE.md, «Common gotchas»). Es la clase de hueco que ya costó caro: 016 se mergeó sin haber corrido su e2e del embed, la corrida posterior destapó un tercer módulo nativo sin build para musl (017), y el tope de 30 minutos por sesión de `qmd embed` apareció recién en el gate de hardware (018).

**Cuánto cuesta hoy** (medido el 14-10-2026 con `gh run` y el log de la corrida). En la corrida 37873376103 (manual, rama de 039, amd64) la suite tardó 885,4 s (14 min 45 s) y `qmd real (016)`, el test 15 de 48, tardó 288,5 s. Las cinco nocturnas programadas sobre `main` entre el 10 y el 14-10-2026 terminaron en verde en entre 13 min 11 s y 15 min 29 s de los 30 permitidos: queda un margen de 14 min 31 s a 16 min 49 s. Cuánto añade la fase del embed en este runner no está medido.

**Los modelos.** `qmd embed` descarga desde HuggingFace el modelo de embeddings (`embeddinggemma-300M-Q8_0.gguf`, 333.590.944 bytes según la medición de 037 y la API de HuggingFace) la primera vez que corre. La búsqueda semántica del test (`qmd vsearch`) además expande la consulta con el modelo de generación (`qmd-query-expansion-1.7B-q4_k_m.gguf`, 1.282.438.912 bytes): qmd 2.5.3 llama a la expansión sin condición (`store.js:3783`) y carga ese modelo (`llm.js:1062`), así que esa fase lo descargaría dentro del contenedor. El reranker no lo usa ninguna fase del test. El test usa un `HOME` desechable por ejecución, así que hoy cada corrida con el embed descargaría unos 1,6 GB. El CHANGELOG de 016 dice que el modelo se cachea «via `QMD_E2E_MODEL_CACHE`», pero esa variable no existe en ningún test, script ni documento fuera del CHANGELOG y de `specs/016` (búsqueda del 14-10-2026): el documento y el código no coinciden.

**La arquitectura: el riesgo mayor.** Hasta donde consta en el repositorio, el embed en Alpine/musl solo se ha corrido en aarch64 (la imagen `agent-admin:qmd-real` de 017; el despliegue real, ferrari, también es aarch64). El runner del nightly es amd64. Tres hechos verificados apuntan a que la primera corrida allí no será trivial:

1. El reemplazo de la extensión vectorial por la build musl (`_qmd_swap_sqlite_vec`) solo conoce la ruta `node_modules/sqlite-vec-linux-arm64/vec0.so` (`scripts/lib/qmd_index.sh:130`) y retorna en silencio si ese archivo no existe (`:132`).
2. Los metadatos de `sqlite-vec@0.1.9` en el registro de npm (consultados el 14-10-2026) declaran un paquete opcional por CPU, `sqlite-vec-linux-x64` (`cpu: x64`) y `sqlite-vec-linux-arm64` (`cpu: arm64`), ambos sin campo `libc`.
3. La aserción del test que comprueba que el `vec0.so` del prefijo es musl (línea 690) inspecciona solo la ruta `linux-arm64` y, si el archivo no existe, imprime `MUSL` y pasa (ejecutada el 14-10-2026 contra un archivo ausente).
4. Ejecutada en el host contra prefijos falsos (14-10-2026), la función real deja intacta la disposición x64 y no registra nada, y reemplaza la de arm64 registrando `swapped glibc prebuilt for musl build`.

**Inferencia, no medida:** en el runner amd64 se instalaría la variante x64 (metadatos de npm), el reemplazo no ocurriría (hecho 4), la extensión glibc no cargaría en musl (como se midió con la de arm64 en 017) y el embed fallaría por un defecto de producto, no de arnés. Las variables con que el instalador del prefijo compila llama.cpp (`GGML_NATIVE=OFF` y `GGML_CPU_ARM_ARCH=armv8-a`, `qmd_index.sh:207-208`) también están pensadas para ARM; su efecto en x86_64 no se ha medido. Esta feature no corrige el producto (fuera de alcance), pero tiene que comportarse bien si la primera corrida lo destapa.

**Cómo se relaciona con 039 y 040.** 039 dejó oráculos que ejecutan el texto de los pasos del workflow (`tests/ci-workflows.bats`: O1 a O5 sobre «Verify deps + docker», S1 a S5 sobre el `run:` de «Run docker-e2e suite», y S6, que solo exige `DOCKER_E2E=1` en el `env:` del paso). Agregar una variable al `env:` no toca el `run:` ni rompe esos tests; cambiar el `run:` sí obligaría a enmendarlos. 040 edita el mismo archivo (+102/-1 líneas: ids de paso, un `if:` en el paso de la suite, `timeout-minutes` convertido en expresión y el job `alert`), de modo que el orden de merge decide quién rebasa. El resultado de este nightly alimenta ese aviso (un issue y un mensaje por Telegram): una noche roja por una falla de infraestructura que parezca una regresión del producto le resta credibilidad a la señal justo cuando empieza a funcionar.

### Estado de cada afirmación

| Afirmación | Estado | Fuente |
| --- | --- | --- |
| El nightly nunca ejerce la fase del embed | Verificado | workflow sin `QMD_EMBED_E2E`; test, línea 669 |
| `qmd real (016)` dura 288,5 s dentro de una suite de 885,4 s | Medido | corrida 37873376103 |
| Cinco nocturnas verdes de 13 min 11 s a 15 min 29 s | Medido | `gh run list`, 14-10-2026 |
| El reemplazo de `sqlite-vec` solo conoce la ruta arm64 | Verificado en código | `qmd_index.sh:130` y `:132` |
| La aserción de la línea 690 pasa sobre un archivo ausente | Ejecutado | 14-10-2026 |
| Con la disposición x64, el reemplazo no ocurre y no deja aviso | Ejecutado (función real contra un prefijo falso) | 14-10-2026 |
| En el runner amd64 se instala la variante x64 | Inferencia (metadatos de npm: un paquete por CPU, sin campo `libc`) | sin medir |
| La extensión x64 glibc no carga en musl | Inferencia (por analogía con arm64, 017) | sin medir |
| Costo de la fase del embed en este runner | No medido | pendiente |
| La compilación de llama.cpp ocurre en el postinstall de node-llama-cpp, durante el `bun install` de la fase A | Verificado en código (node-llama-cpp 3.18.1; no medido en el runner) | research M5 |
| La búsqueda vectorial del test también carga el modelo de expansión (1,28 GB) | Verificado en código (qmd 2.5.3) | `store.js:3783`, `llm.js:1062` |
| El reranker no lo usa ninguna fase del test | Inferencia (el test no ejecuta `qmd query` ni envía consultas al servidor MCP) | research M3 |
| Un modelo ya presente con el nombre esperado se usa sin red | Verificado en código (qmd 2.5.3 y node-llama-cpp 3.18.1) | research M3 y M4 |
| qmd desactiva embed, expansión y rerank si la variable `CI` tiene valor | Verificado en código (`llm.js:384`) | compose no la pasa al contenedor |

## Clarifications

### Session 2026-10-14

- Q: Si la primera corrida real del embed en el runner amd64 revela un defecto de producto, ¿qué debe hacer el nightly mientras ese defecto siga abierto? → A: Apagar la fase del embed con un salto explícito que nombra el defecto y su seguimiento (la política que 039 fijó el 05-10-2026 para los rojos reales). El resto de la feature se mergea igual y el embed se reactiva cuando el producto se corrija, sin volver a especificar (FR-014).
- Q: Si el modelo de embeddings no se puede obtener una noche (origen caído o red del runner), ¿cómo debe tratarlo el nightly? → A: Reintentar un número acotado de veces y, si persiste, dejar la noche en rojo con el paso de obtención del modelo como paso fallido; una falla transitoria que cede al reintento no la enrojece (FR-008).
- Q: ¿El modelo de embeddings (333 MB) debe conservarse entre noches o descargarse en cada corrida? → A: Descargarse en cada corrida, con los reintentos de FR-008, y medir su tamaño y tiempo; conservarlo (cache) queda como una mejora posterior sobre este mismo camino, solo si la medición la justifica (FR-010).
- Q: Cuando la fase del embed se active por primera vez, ¿el tope de 30 minutos del job se mantiene hasta medir o se sube de antemano? → A: Se mantiene hasta medir: la primera corrida manual registra el margen y, si deja menos de 5 minutos, se sube el tope y se vuelve a medir (política de 039). El margen de 5 minutos es una propuesta basada en la dispersión de 2 min 18 s medida entre nocturnas (FR-013).

### Session 2026-10-15 (durante /speckit-plan)

- Q: La búsqueda semántica del test (`qmd vsearch`) también carga el modelo de expansión de consultas (1,28 GB), que se descargaría dentro del contenedor en esa fase; ¿cómo se trata? → A: Se precargan los dos modelos (embeddings, 333 MB, y expansión, 1,28 GB) en el paso de obtención, con los mismos reintentos e integridad; `vsearch` queda igual (FR-002) y toda descarga de modelo se atribuye a la obtención (FR-007). Corrige el supuesto del 14-10-2026 de que la búsqueda vectorial solo usaba el modelo de embeddings, refutado por el código de qmd 2.5.3 (`store.js:3783`, `llm.js:1062`).

### Session 2026-10-16 (durante /speckit-analyze)

- Q: Si la primera corrida manual deja menos de 5 minutos de margen frente al tope, ¿cuál es el primer remedio? → A: Subir el tope y volver a medir, como se decidió el 14-10-2026. Compartir el prefijo compilado entre los tests 016 y 041 queda como mejora posterior, solo con medición, porque acopla los dos tests (FR-013).
- Q: Si un modelo llega con el tamaño esperado pero con otra suma (el archivo cambió en HuggingFace), ¿cómo lo trata la obtención? → A: Sin reintento y con un motivo propio que pide revisar la tabla; la noche queda roja en el paso de obtención, sin leerse como una red caída (FR-008).
- Q: Si la primera corrida real no llega a la última fase del embed (lo previsto en amd64), ¿la corrida local en arm64 pasa a ser obligatoria antes del PR? → A: Sí. Las fases que la corrida real no ejecutó se ejecutan al menos una vez en un DOCKER_E2E local en arm64 antes del PR, con su resultado en las Notes de `tasks.md` (FR-020).

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Una regresión del embed vuelve roja la noche y el log dice qué fase falló (Priority: P1)

Como mantenedor del launcher, quiero que el nightly ejecute el embed real de qmd (arranque con su setup, modelos, extensión vectorial, reindexado, búsqueda semántica y servidor MCP) y que una regresión en cualquiera de esas piezas ponga la noche en rojo con la fase culpable a la vista, para enterarme por el semáforo y no al desplegar a hardware.

**Why this priority**: Es el valor central de la feature. Hoy una regresión del embed solo la ve quien corre el test a mano con la puerta abierta o el gate de hardware, y la historia de 016, 017 y 018 muestra que ahí se descubren tarde y con otro costo.

**Independent Test**: Lanzar el workflow a mano (`workflow_dispatch`) sobre la rama y leer el log: la fase del embed figura como ejecutada, no como saltada, y cada una de sus partes deja constancia. Repetir sobre una rama de ensayo con una rotura inducida del embed y comprobar que la corrida termina en rojo nombrando la fase.

**Acceptance Scenarios**:

1. **Given** el nightly o una corrida manual, **When** el job ejecuta el test del qmd real, **Then** la fase del embed se ejecuta y el resumen de la suite la cuenta como ejecutada.
2. **Given** una regresión en cualquier pieza del embed (la extensión vectorial no carga, la búsqueda no devuelve el documento esperado, el servidor MCP no arranca), **When** corre el nightly, **Then** la noche termina en rojo y el log nombra la fase que falló (FR-002, FR-004).
3. **Given** que la comprobación de la extensión vectorial inspecciona un archivo que no existe, **When** corre la fase, **Then** falla en lugar de pasar, sea cual sea la arquitectura de la CPU del runner (FR-003).
4. **Given** que la primera corrida real en el runner del nightly revela un defecto de producto que impide el embed, **When** se clasifica, **Then** se registra y se decide aparte, y mientras siga abierto la fase queda apagada con un salto explícito que nombra el defecto y su seguimiento, de modo que la noche no quede en rojo permanente por algo ya conocido; el resto de la feature se entrega igual.

---

### User Story 2 - La cobertura es honesta: ejecutada o saltada con motivo, nunca en silencio (Priority: P1)

Como mantenedor, quiero que cuando la fase del embed no se ejecute (porque la puerta está cerrada en una corrida local, o porque un defecto abierto la apagó) la salida lo declare como un salto con motivo y el resumen del nightly lo cuente, para que un verde nunca signifique «el embed anduvo» cuando no se miró.

**Why this priority**: Es la rebanada que vale aunque el embed en amd64 resulte bloqueado por el producto: hace que el semáforo diga la verdad hoy. Es P1 porque el hueco actual (un verde que no avisa lo que no cubre) es exactamente el que 039 dejó declarado como «Not a coverage claim».

**Independent Test**: En el host, sin Docker: un oráculo comprueba que, con la puerta cerrada, el resultado del test trae un salto con motivo sin llamar a Docker, y que con la puerta abierta y sin modelos el test falla en vez de saltar. El resumen del nightly cuenta ese salto porque el texto del paso de la suite no cambia (FR-019).

**Acceptance Scenarios**:

1. **Given** la puerta cerrada (el valor por defecto en una máquina local), **When** corre `tests/docker-e2e-qmd.bats` con `DOCKER_E2E=1`, **Then** la fase del embed se reporta como saltada con un motivo escrito, y el resto del test (fase A y detección RED) se reporta por separado y sigue pasando.
2. **Given** el nightly con la puerta abierta, **When** termina la suite, **Then** la línea `e2e summary:` cuenta la fase del embed entre las ejecutadas.
3. **Given** una corrida donde la fase quedó saltada, **When** se lee el resumen, **Then** el conteo de saltados lo refleja y nadie necesita leer el código del test para enterarse.
4. **Given** una corrida donde todo quedó saltado, **When** termina el job, **Then** sigue siendo rojo: la guarda de 039 no se debilita.

---

### User Story 3 - Una falla de infraestructura no se confunde con una regresión del producto (Priority: P2)

Como mantenedor, quiero que una falla al obtener los modelos (red, HuggingFace) se vea distinta de una falla del embed, para que una noche roja por infraestructura no se lea como una regresión del producto ni erosione el aviso de 040.

**Why this priority**: El nightly alimenta un aviso que llega al mantenedor. Cada noche roja que no sea una regresión cuesta credibilidad a esa señal. Es P2 porque depende de que la fase del embed corra (US1).

**Independent Test**: Simular que los modelos no se pueden obtener (origen inalcanzable) y leer el log y el resumen: la falla queda atribuida a la obtención de los modelos y no a una aserción del embed.

**Acceptance Scenarios**:

1. **Given** que un modelo sigue sin poder obtenerse tras los reintentos acotados, **When** corre el nightly, **Then** la noche queda en rojo y el log y el paso fallido que el aviso nombra la identifican como una falla de infraestructura en la obtención de los modelos, distinta de las fases del embed.
2. **Given** una falla transitoria de red que cede a un reintento, **When** corre el nightly, **Then** la obtención de los modelos se recupera y la noche no queda en rojo por ella.
3. **Given** que los modelos se obtuvieron con éxito y el embed falla, **When** se clasifica la noche, **Then** se clasifica como una falla del embed (regresión del producto o defecto de arnés, según la evidencia), nunca como infraestructura (FR-009).

---

### User Story 4 - El costo queda acotado y medido: cabe en el tope y se sabe cuánto cuestan los modelos (Priority: P2)

Como mantenedor, quiero que activar el embed no ponga en riesgo el tope del job y que el costo de obtener los modelos quede medido, para decidir con datos si conviene conservarlos entre noches en vez de adivinarlo.

**Why this priority**: La suite ya usa unos 15 de 30 minutos y la fase del embed en amd64 nunca se ha medido. Un tiempo agotado es un rojo real y distinto (039), y descargar unos 1,6 GB cada noche (333 MB de embeddings y 1,28 GB de expansión) es una decisión provisoria (clarify del 14 y del 15-10-2026) que solo se sostiene si se mide.

**Independent Test**: Una corrida manual con la fase activa deja registrados su duración total y, por modelo, el tamaño, los intentos y el tiempo que tardó en obtenerlo, y cabe en el tope del job.

**Acceptance Scenarios**:

1. **Given** la fase del embed activa, **When** el nightly termina, **Then** su duración total cabe en el tope del job con un margen de al menos 5 minutos, sin tiempo agotado, y el margen queda registrado.
2. **Given** cualquier corrida con la fase activa, **When** se lee su log, **Then** declara, por modelo, el tamaño, cuántos intentos hicieron falta y cuánto tardó en estar disponible (FR-010, FR-011).
3. **Given** que la primera medición deja menos de 5 minutos de margen, **When** se trata, **Then** se sube el tope y se vuelve a medir (FR-013); el job no se divide sin evidencia de que subir el tope no basta.

---

### User Story 5 - Hay evidencia real de que el embed corre en el runner y de que una rotura lo pone en rojo (Priority: P2)

Como mantenedor, quiero corridas reales, con su identificador, que muestren que la fase del embed se ejecutó en el runner del nightly y que una rotura inducida la deja en rojo, para dar la cobertura por buena con datos y no con diseño.

**Why this priority**: Los precedentes 039 y 040 no dan por hecho lo que no se midió en el entorno real, y aquí pesa doble: el embed nunca se ha corrido en amd64. Es P2 porque depende de US1 y US2, pero sin ella el merge sería a ciegas.

**Independent Test**: Los identificadores de las corridas, su clasificación y su duración quedan en las Notes de `tasks.md`.

**Acceptance Scenarios**:

1. **Given** una corrida manual sobre la rama con la fase activa, **When** termina, **Then** su resultado queda clasificado (verde, rojo por defecto de arnés, rojo por defecto de producto o rojo por infraestructura) con el fragmento de log que lo prueba; si es un defecto de arnés acotado, se corrige y se vuelve a correr (FR-015, FR-020).
2. **Given** una rama de ensayo, que no se mergea, con una rotura inducida del embed, **When** corre el workflow, **Then** termina en rojo y el log nombra la fase fallida (FR-020).
3. **Given** el merge, **When** corren las tres primeras nocturnas, **Then** cada una ejecuta la fase del embed (o la tiene apagada por un defecto abierto y registrado) y termina dentro del tope.
4. **Given** que la corrida manual no llega a la última fase del embed, **When** se prepara el PR, **Then** las fases que faltaron se ejecutan en un DOCKER_E2E local en arm64 y su resultado queda en las Notes de `tasks.md` (FR-020).

---

### Edge Cases

- **La primera corrida en amd64 puede fallar por el producto**, no por el arnés (ver «La arquitectura»). Se clasifica con evidencia, no se corrige aquí y no deja el nightly en rojo permanente (FR-014).
- **El plazo de 600 s del centinela incluye la compilación de llama.cpp.** El test del embed usa su propio `.state` (research D8), así que el `bun install` con la compilación ocurre dentro de su fase de setup, y eso no se ha medido en amd64. Si la causa de un rojo es el plazo del arnés y no el producto, se ajusta el plazo con la duración medida en la primera corrida y se vuelve a medir (FR-015); no se sube a ciegas.
- **Descarga incompleta o dañada.** Un archivo truncado o corrupto no cuenta como un modelo obtenido: la obtención lo verifica antes de darlo por bueno y, si no coincide, es una falla de la obtención y se reintenta (FR-008).
- **Un modelo cambia en origen.** Si el archivo de HuggingFace se reemplaza y llega con el tamaño esperado pero con otra suma, la obtención no lo reintenta: la noche queda roja en el paso de obtención con un motivo propio que pide revisar la tabla (FR-008, clarify del 16-10-2026). Si el repositorio se movió o se borró, la descarga responde 404 y se trata como una falla de la obtención. **Un cambio del pin de qmd** puede cambiar los modelos por defecto: el guard del host de FR-012 falla hasta que alguien revise la tabla.
- **Red caída varias noches seguidas.** Tras los reintentos de FR-008 sigue siendo rojo, no se esconde, y queda etiquetada como infraestructura; el aviso de 040, si ya está mergeado, la agrupa en una racha.
- **Disco y memoria del runner.** La imagen con toolchain, los artefactos de compilación de llama.cpp y los modelos (unos 1,6 GB) se suman, y el uso no está medido. La obtención registra el disco libre antes y después de bajar los modelos, y el test del embed registra el disco libre y la memoria pico del contenedor al terminar; la primera corrida deja esas cifras.
- **La variable `CI`.** qmd desactiva embed, expansión y rerank si `CI` tiene valor (`llm.js:384`), y GitHub Actions la define en el runner. Compose no la pasa al contenedor; si algún día llegara, el embed fallaría con «LLM operations are disabled in CI», y la fase de arranque debe detectarlo y nombrarlo.
- **Suite local del desarrollador.** `DOCKER_E2E=1 bats tests/docker-e2e-qmd.bats` sin abrir la puerta sigue sin descargar nada y ahora lo dice (FR-005, FR-006).
- **Un verde sin e2e ejecutados** sigue siendo rojo (039); un salto de la fase del embed no cuenta como ejecución.
- **Corridas concurrentes** (nocturna y manual): el grupo de concurrencia existente las serializa; no se toca.

## Requirements *(mandatory)*

### Functional Requirements

#### Ejecución del embed en el nightly

- **FR-001**: El nightly y cada corrida manual del workflow MUST ejecutar la fase del embed real de qmd (hoy, el Tier 2 de `qmd real (016)`), salvo lo dispuesto en FR-014.
- **FR-002**: La fase del embed MUST conservar todas sus aserciones actuales (centinela de setup, modelos presentes, extensión vectorial musl en el prefijo, reindexado con `last_status` en `ok` o `indexed` y `pending` en 0, búsqueda semántica que devuelve el documento esperado, arranque del servidor MCP sin las firmas del BUG-4); ninguna se elimina ni se debilita, y las únicas correcciones permitidas son las de FR-003 y FR-004 y las de arnés que manda hacer FR-015 (por ejemplo, dónde escribe el test el documento que la búsqueda debe encontrar, el plazo de cada fase o el cron del workspace).
- **FR-003**: La comprobación de que la extensión vectorial del prefijo es la compilada para musl MUST fallar si el archivo que inspecciona no existe y MUST NOT depender de una arquitectura de CPU concreta.
- **FR-004**: Cada parte de la fase del embed (setup y centinela, modelos, extensión vectorial, reindexado, búsqueda semántica, servidor MCP) MUST dejar constancia en el log de la corrida, de modo que una falla se atribuya a una fase concreta sin reproducir nada en local. Una fase que ejecuta qmd y puede colgarse (el reindexado, la búsqueda semántica y el servidor MCP) MUST fallar como esa fase si no termina, con un plazo propio dentro del contenedor, y no como un job cancelado por su tope, que no nombra nada y pierde el resto de la suite; el setup ya tiene el suyo. Los pasos que solo llaman a Docker o leen un archivo (el `build` y el `up` del arranque, las comprobaciones de `CI` y de `XDG_CACHE_HOME`, `vector-extension`, `models-untouched` y cada vuelta del sondeo del setup) no tienen plazo propio: un cuelgue ahí lo corta el tope del job (residuo aceptado, research D18). Un test que falla MUST dejar en el log el estado que no se puede pedir después: el disco libre, el veredicto del contenedor (OOM, código de salida, reinicios), la extensión vectorial del prefijo y el estado y la salida del reindexado y de la búsqueda (segunda y tercera revisión, 16-10-2026).

#### Cobertura honesta

- **FR-005**: Cuando la fase del embed no se ejecute (puerta cerrada o apagada por FR-014), MUST reportarse como saltada con un motivo escrito, y el resto del test (fase A y detección RED) MUST seguir reportándose por separado. El conteo de saltados de la línea `e2e summary:` MUST reflejarlo, y la guarda de 039 («ningún e2e se ejecutó» es rojo) MUST seguir intacta.
- **FR-006**: Con la puerta cerrada (en una máquina local, o en el nightly apagado por FR-014) la suite MUST NOT obtener los modelos ni cambiar de comportamiento salvo por el salto declarado.

#### Infraestructura frente a regresión

- **FR-007**: La obtención de los modelos que usa la fase (embeddings y expansión) MUST poder atribuirse por separado de las aserciones del embed, de modo que su falla quede identificada como infraestructura en el log y en el paso fallido que el aviso de 040 nombra; ninguna fase del embed MUST descargar un modelo dentro del contenedor (clarify del 15-10-2026).
- **FR-008**: Una falla al obtener cualquiera de los modelos MUST reintentarse un número acotado de veces y, si persiste, dejar la noche en rojo con el paso de obtención de los modelos como paso fallido; una falla transitoria que cede a un reintento MUST NOT poner roja la noche. El número de intentos y la espera entre ellos los fija el plan (clarify del 14-10-2026). Un archivo que llega con el tamaño esperado pero con otra suma no es una falla transitoria: MUST NOT reintentarse y MUST nombrarse como un cambio del modelo en origen (clarify del 16-10-2026).
- **FR-009**: Modelos obtenidos con éxito seguidos de una falla de cualquier fase del embed MUST clasificarse como una falla del embed (regresión del producto o defecto de arnés, según la evidencia), nunca como infraestructura.

#### Costo

- **FR-010**: Los modelos MUST obtenerse en cada corrida (con los reintentos de FR-008); esta feature no los conserva entre noches. Conservarlos, si la medición de FR-011 lo justifica, es una mejora posterior que se agrega sobre este mismo camino (clarify del 14-10-2026).
- **FR-011**: El log de cada corrida MUST declarar, por modelo, su tamaño, el número de intentos que hicieron falta y cuánto tardó en estar disponible, para decidir con datos si conviene conservarlos entre noches.
- **FR-012**: El identificador de cada modelo que la corrida obtiene, y el tamaño y la suma con que se verifica su integridad, MUST derivar de una sola fuente en el repositorio, y un guard del host MUST fallar si el pin de qmd cambia sin revisarlos (mismo patrón del guardrail de versión de qmd que ya existe).
- **FR-013**: La duración total del nightly con la fase del embed MUST caber en el tope del job con un margen de al menos 5 minutos. La primera medición se hace en una corrida manual sobre la rama con el tope vigente (30 minutos); si deja menos de ese margen, el tope se sube y se vuelve a medir (política de 039), y dividir el job en partes paralelas solo se considera con evidencia de que subir el tope no basta (clarify del 14-10-2026). Subir el tope es el primer remedio; compartir el prefijo compilado entre tests queda como mejora posterior medida (clarify del 16-10-2026).

#### Defectos que destape la primera corrida

- **FR-014**: Si la primera corrida real en el runner del nightly revela un defecto de producto, MUST registrarse y decidirse aparte; no se corrige dentro de esta feature ni se esconde. Mientras siga abierto, la fase del embed MUST quedar apagada con el salto de FR-005, que nombra el defecto y su seguimiento (la misma política que 039 fijó el 05-10-2026 para los rojos reales), y el resto de la feature (la comprobación no vacía, las marcas de fase, los saltos visibles, la obtención atribuible de los modelos y los oráculos del host) se entrega igual. La fase se reactiva cuando el defecto se cierra, sin volver a especificar esta feature (clarify del 14-10-2026).
- **FR-015**: Un defecto de arnés hallado en la fase del embed (plazo del centinela, rutas dependientes de la arquitectura, esperas) MUST corregirse en esta feature si su arreglo queda acotado al propio test o a su arnés y se verifica con una corrida real.

#### Oráculos del host

- **FR-016**: La suite del host (`bats tests/`, sin Docker ni red) MUST incluir oráculos que fallen si: (a) el workflow deja de activar la fase del embed en el nightly sin que haya un defecto abierto y registrado que lo justifique (FR-014); (b) la fase del embed deja de reportarse como saltada con motivo, u obtiene los modelos, cuando su puerta está cerrada; (c) la comprobación de la extensión vectorial pasa sobre un archivo ausente o fija una arquitectura; (d) la obtención de los modelos pierde su atribución por separado, sus reintentos acotados (FR-008) o su verificación de integridad (FR-012).
- **FR-017**: Cada oráculo MUST demostrarse rojo contra el defecto que vigila (mutación) y verde tras el arreglo, MUST NOT poder pasar en vacío, y MUST pasar bajo bash 3.2 y bash 5.x.

#### Restricciones y evidencia

- **FR-018**: Esta feature MUST NOT modificar `docker/`, `scripts/`, `modules/` ni `setup.sh`, ni agregar secretos o permisos al workflow (hoy `contents: read`), y MUST NOT subir `VERSION` (se verifica contra `origin/main` a mano).
- **FR-019**: El texto `run:` de los pasos «Verify deps + docker» y «Run docker-e2e suite» MUST NOT cambiar, para que los oráculos de 039 (O1 a O5, S1 a S5) sigan verdes sin editarse. Si el diseño no permitiera evitarlo, la enmienda de esos tests se declara de forma explícita en el plan y en las Notes de `tasks.md`.
- **FR-020**: Antes de dejar la fase del embed activa en el nightly MUST existir evidencia de al menos una corrida manual sobre la rama en que se ejecutó en el runner del nightly, con su resultado clasificado, su duración y el tiempo de obtención de los modelos; y de al menos una rotura inducida que la deja en rojo nombrando la fase. Si aplica FR-014, la corrida de evidencia clasifica el defecto de producto y la rotura inducida se demuestra al reactivar la fase. Si la corrida de evidencia no llega a ejecutar todas las fases del embed (por ejemplo, porque un defecto de producto la detiene en el setup), las fases que no ejecutó MUST ejecutarse al menos una vez antes del PR en un DOCKER_E2E local en arm64, con su resultado en las Notes de `tasks.md` (clarify del 16-10-2026). Los identificadores de esas corridas quedan en las Notes de `tasks.md`.
- **FR-021**: CHANGELOG y CLAUDE.md MUST reflejar lo que el nightly cubre y lo que no tras esta feature: que ejerce el embed en amd64 o, si aplica FR-014, que lo tiene apagado por el defecto registrado, con su seguimiento; que el despliegue real es aarch64; y que el gate de hardware sigue vigente. La frase de «Common gotchas» que dice que `qmd real (016)` pasa sin ejercer el embed MUST corregirse. Los conteos que cambian (49 e2e en 13 archivos; la suite del host, en la línea base más 37) MUST quedar en la entrada nueva de CHANGELOG y de CLAUDE.md. La mención a `QMD_E2E_MODEL_CACHE` del CHANGELOG de 016, que no existe en el código, MUST aclararse en la entrada nueva (la de 016 es historia y no se reescribe). `docs/qmd-upgrade-checklist.md` MUST describir cómo se corre la fase del embed después de esta feature.

### Key Entities

- **Fase del embed**: la secuencia de comprobaciones sobre el qmd real dentro de un contenedor: setup y centinela, modelos, extensión vectorial, reindexado, búsqueda semántica y servidor MCP. Se activa por una puerta explícita.
- **Obtención de los modelos**: la descarga de los modelos de embeddings y de expansión en cada corrida, con el tamaño, el número de intentos y el tiempo de cada uno.
- **Resultado de la fase en una corrida**: ejecutada y verde; ejecutada y roja por regresión, con su fase; no ejecutada por una falla de infraestructura al obtener los modelos; o saltada con motivo declarado (puerta cerrada o defecto abierto).
- **Defecto abierto**: un defecto de producto que la fase destapó, registrado con su seguimiento y nombrado en el salto mientras siga abierto.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: En al menos una corrida real de `workflow_dispatch` sobre la rama, la fase del embed figura como ejecutada (no saltada) en el runner del nightly, y su resultado, duración, arquitectura y tiempo de obtención de los modelos quedan registrados con el identificador de la corrida (FR-001, FR-020).
- **SC-002**: Una rotura inducida del embed, hecha en una rama de ensayo que no se mergea, deja la corrida en rojo y el log nombra la fase que falló: al menos 1 caso, con su identificador (FR-004, FR-020); si aplica FR-014, se demuestra al reactivar la fase.
- **SC-003**: Con la puerta cerrada, el resultado del test trae un salto con motivo y no se llama a Docker ni se obtienen los modelos; con la puerta abierta y sin modelos, el test falla nombrando la variable que falta en vez de saltar. Comprobado en el host, sin Docker, en bash 3.2 y 5.x. Que la línea `e2e summary:` del nightly cuente ese salto lo garantiza el paso de la suite, cuyo texto no cambia (FR-019) y cuyo conteo de saltos ya prueba el oráculo de 039 (S1).
- **SC-004**: La comprobación de la extensión vectorial falla sobre un archivo ausente y acepta cualquier arquitectura: demostrado por un oráculo del host que pasa de rojo (contra el defecto) a verde (tras el arreglo) (FR-003, FR-016, FR-017).
- **SC-005**: Un oráculo del host demuestra, con un origen simulado, que una falla transitoria que cede a un reintento no enrojece la noche y que una indisponibilidad persistente la deja en rojo con el paso de obtención de los modelos como paso fallido; y una corrida real de ensayo con la indisponibilidad inducida confirma lo segundo en el log: al menos 1 caso, con su identificador.
- **SC-006**: La duración total de la corrida de evidencia, con la fase del embed, queda registrada junto con su margen frente al tope; si el margen es menor de 5 minutos, el tope se sube y se vuelve a medir antes de dar por buena la corrida (FR-013).
- **SC-007**: Las 3 nocturnas siguientes al merge ejecutan la fase del embed, o la tienen apagada por un defecto abierto y registrado, y terminan dentro del tope, con un margen de al menos 5 minutos y sin tiempo agotado: 3 de 3.
- **SC-008**: El diff de la feature no toca `docker/`, `scripts/`, `modules/` ni `setup.sh`; el workflow conserva `contents: read` y no incorpora secretos nuevos; `VERSION` no cambia; y el texto `run:` de los pasos «Verify deps + docker» y «Run docker-e2e suite» no cambia (FR-018, FR-019).
- **SC-009**: La suite completa del host pasa en bash 3.2 y bash 5.x con los tests nuevos contados (esperado = línea base medida más los tests nuevos) (FR-017).
- **SC-010**: Tras el merge, CHANGELOG y CLAUDE.md ya no dicen que el nightly pasa `qmd real (016)` sin ejercer el embed, y dicen lo que cubre y lo que no.

## Assumptions

- **Disparo.** El embed corre en la nocturna y en cada `workflow_dispatch`. El workflow no tiene disparador de pull request y esta feature no lo agrega: ejecutar una fase de 10 minutos o más en cada PR que toque qmd es un cambio de alcance. Se puede reabrir en clarify si el operador lo quiere.
- **Runner y costo.** Se mantiene `ubuntu-latest` (amd64). El repositorio es público, así que los minutos de Actions no se facturan (039).
- **Sin secretos ni permisos nuevos.** Los dos repositorios de los modelos son públicos y sin acceso restringido (`gated: false` en la API de HuggingFace, consultada el 14 y el 15-10-2026), y la URL de descarga responde de forma anónima (redirige a la CDN de HuggingFace).
- **Versión de qmd.** El pin vigente es `vault.qmd.version` (2.5.3 por defecto, `qmd_index.sh:56`). Un cambio de pin puede cambiar los modelos; para eso existe FR-012.
- **Qué modelos usa el test.** El de embeddings (setup, reindexado y la consulta) y el de expansión (`vsearch`), verificado en el código de qmd 2.5.3; el reranker no lo usa ninguna fase. El supuesto anterior (solo embeddings) quedó refutado el 15-10-2026.
- **Modelo ya presente.** Verificado en el código publicado (qmd 2.5.3, `llm.js:621-627`, y node-llama-cpp 3.18.1, `resolveModelFile`): un archivo con el nombre esperado se usa sin red, por el mismo camino que en producción. El test vigila que no se vuelva a descargar.
- **`QMD_E2E_MODEL_CACHE`.** La variable que documentan el CHANGELOG y los specs de 016 no existe en el código; como los modelos se obtienen en cada corrida, esta feature no la implementa y la aclaración documental queda en FR-021.
- **Lo no medido se mide primero.** El costo de la fase en amd64, el tiempo de la compilación de llama.cpp en el runner y la carga real de la extensión vectorial en x64 se miden en la primera corrida manual sobre la rama; su resultado decide si el embed queda activo en el nightly (FR-001) o apagado por un defecto abierto (FR-014) antes del merge.
- **La paridad es parcial.** El nightly ejerce amd64 y el despliegue real es aarch64: detecta regresiones de la pila (musl, llama.cpp, los modelos, la búsqueda) en una arquitectura, pero no sustituye el gate de hardware.
- **040 sin mergear.** Esta feature no depende de 040 para funcionar, pero su valor operativo (que el rojo llegue al mantenedor) sí. El orden de merge y el rebase del workflow se deciden en el plan. El aviso de 040 nombra como fallido el primer paso con identificador (`id:`) cuyo resultado sea falla o cancelación, y no solo `verify_deps` y `run_suite` (verificado el 14-10-2026 en `nightly-alert.sh`, función `collect`, rama `040-nightly-red-alert`): un paso de obtención de los modelos con identificador queda nombrado sin tocar 040.
- **Compuertas operativas.** Empujar la rama, lanzar cada `workflow_dispatch`, abrir el PR y mergear exigen la confirmación explícita del operador. El push va por HTTPS con el helper de `gh` y el token ya tiene el permiso `workflow` (verificado el 14-10-2026).
- **Es una feature de CI y de tests, sin cambio de runtime.** El precedente (019, 025, 039 y 040) es no subir `VERSION` y dejar una entrada en `CHANGELOG.md`.

## Out of Scope

- Cambiar el código del producto (`docker/`, `scripts/`, `modules/`, `setup.sh`), incluido el reemplazo de la extensión vectorial que hoy solo conoce arm64. Si la primera corrida demuestra que es un defecto, se abre una feature aparte.
- El gate de hardware en ferrari (corpus real completo y hit semántico de 017 y 018): el nightly cubre amd64 y el despliegue real es aarch64.
- Un runner arm64, propio o alojado.
- Ejercer el reranker y la consulta híbrida (`qmd query`): el reranker es otro modelo y ninguna fase del test lo usa. La expansión sí se ejerce, porque `vsearch` la usa (clarify del 15-10-2026).
- Conservar los modelos entre noches (cache): queda como mejora posterior si la medición de FR-011 la justifica (clarify del 14-10-2026).
- El aviso de 040: aquí solo se consume su señal. Tampoco se rediseñan `test.yml` ni `shellcheck.yml`.
- Disparar el embed en pull requests (ver Assumptions).
- G0, G1 y el rollout de 038, y la actualización pendiente de la flota.
