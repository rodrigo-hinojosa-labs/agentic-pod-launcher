# Feature Specification: El embed de qmd funciona en la imagen docker sobre amd64 y el nightly vuelve a ejercitarlo

**Feature Branch**: `042-qmd-sqlite-vec-x64`

**Created**: 2026-10-18

**Status**: Draft

**Input**: El nightly `docker-e2e` tiene la fase del embed de qmd apagada por el issue #107: en la imagen del agente (Alpine/musl) sobre un host amd64, `qmd embed` y `qmd vsearch` fallan con `sqlite-vec extension is unavailable` porque el reemplazo de la extensión vectorial solo conoce la ruta `linux-arm64`. El operador quiere (1) que el embed y la búsqueda semántica funcionen en esa imagen sobre amd64 como ya funcionan sobre arm64, (2) que un reemplazo imposible deje rastro en el log sin romper el índice léxico, y (3) que el nightly vuelva a ejercitar la fase, con el margen del tope de 30 minutos medido en al menos 3 corridas.

## Contexto

**El defecto, medido.** La primera corrida real de la fase del embed en un runner amd64 (feature 041, corrida 39069243972 de CI, 17-10-2026) dejó `qmd real (041)` en rojo en la fase `setup`. El log del contenedor dice `[qmd] setup: 'embed' failed/timed out: ... sqlite-vec extension is unavailable. Error loading shared library /home/agent/.cache/qmd/pkg/node_modules/sqlite-vec-linux-x64/vec0.so.so: No such file or directory`; el estado que el test vuelca al fallar, desde dentro del contenedor, dice `x86_64` y `GLIBC /home/agent/.cache/qmd/pkg/node_modules/sqlite-vec-linux-x64/vec0.so` (159.816 bytes). Ese volcado descartó memoria (sin OOM, pico de 3,19 GiB), disco, red y arnés. El `.so.so` del mensaje es el segundo intento de SQLite al cargar la extensión, no un archivo ausente: lo que falla es que un binario glibc no carga dentro de un contenedor musl.

**Por qué ocurre.** La imagen compila en su build una extensión `vec0.so` para musl y la deja horneada. En el arranque, `_qmd_swap_sqlite_vec` (`scripts/lib/qmd_index.sh:128-144`) la copia sobre el binario glibc que `bun install` dejó en el prefijo gestionado (`_qmd_ensure_prefix`, `qmd_index.sh:209`), para que qmd pueda cargarla. Pero su destino está escrito para una sola arquitectura (`node_modules/sqlite-vec-linux-arm64/vec0.so`) y, cuando ese archivo no existe, la función sale por `[ -e "$target" ] || return 0` sin hacer nada y sin registrar nada. En un host amd64, `bun install` instala el paquete `sqlite-vec-linux-x64` (publicado en el registro de npm); la función no encuentra nada que reemplazar y el defecto queda callado hasta que el embed falla.

**Quién lo sufre.** Cualquier uso de la imagen en un host x86_64 (sin búsqueda semántica y sin aviso; el índice léxico sigue funcionando) y el nightly de CI, cuyo runner es amd64: por eso la feature 041 dejó la fase apagada con `QMD_EMBED_DEFECT: '#107 ...'` (PR #108), de modo que mientras #107 siga abierto el nightly no ejercita el embed. Los agentes desplegados corren aarch64, donde el reemplazo funciona, y el modo local (glibc) no usa el reemplazo: ninguno de los dos está afectado.

**Qué dejó pendiente 041 para esta feature.** El issue #107 lista cinco obligaciones de cierre: vaciar `QMD_EMBED_DEFECT`; correr `docker-e2e` por `workflow_dispatch` con la fase activa y verla en verde en amd64 con sus ocho marcas; medir la duración del job y su margen frente a `timeout-minutes` (si queda bajo 5 minutos, se sube el tope primero); repetir la rotura inducida (imagen del test sin toolchain: rojo con la última marca en `setup` o `vector-extension`); y registrar los resultados. La duración de una corrida verde con la fase activa no está medida: el job rojo de E1 duró 21 min 19 s y se detuvo antes del reindexado, y los mismos 48 e2e tardaron 11 min 45 s en una corrida y 15 min 8 s en otra (29 % más) sin cambio alguno entre ellas.

**Relación con 041.** Esta feature depende de lo que 041 dejó en `main` con el PR #108 (squash `0fc08a8`, 19-10-2026): el paso de obtención de los modelos (`fetch_models`), el test `qmd real (041)` con sus ocho fases, el verificador `vec0-libc.sh` (que ya reconoce cualquier paquete `sqlite-vec-linux-*`) y el interruptor `QMD_EMBED_DEFECT`. La rama de esta feature se creó desde `13cafc3`, anterior a ese merge, así que la implementación se rebasa sobre `main` antes de empezar.

**Lo que no se sabe todavía**, y que la primera corrida con el arreglo responderá: (a) cuánto tardan el embed y la búsqueda en x86_64: llama.cpp se compila con opciones pensadas para ARM (`GGML_NATIVE=OFF` y `GGML_CPU_ARM_ARCH=armv8-a`, `qmd_index.sh:207-208`) y su efecto en x86_64 no se ha medido (E1 sí mostró que la compilación terminó y que qmd arrancó, avisando que corre en CPU); (b) que las cinco fases posteriores a `setup` (`vector-extension`, `reindex`, `semantic-search`, `mcp`, `models-untouched`) pasen en amd64. Que el `vec0.so` musl horneado exista en la imagen amd64 ya no es una incógnita: `qmd real (016)` lo exige (`tests/docker-e2e-qmd.bats:705-706`) y pasó en amd64 en E1.

### Estado de cada afirmación

| Afirmación | Estado | Fuente |
| --- | --- | --- |
| El reemplazo solo apunta a `sqlite-vec-linux-arm64` y sale callado con la disposición x64 | Verificado en código y medido en un runner | `qmd_index.sh:130-132`; E1 |
| El `vec0.so` del paquete x64 es glibc dentro del contenedor musl | Medido | E1: `GLIBC .../sqlite-vec-linux-x64/vec0.so` |
| Por eso el embed falla en la fase `setup` en amd64 | Medido | E1: log del contenedor y marcas de fase |
| Memoria, disco, red y arnés no son la causa | Medido | E1: `oom=false`, contadores en 0, pico de 3,19 GiB; 82 GB libres; obtención en verde |
| El reemplazo funciona en arm64 | Medido (DOCKER_E2E de 017 y T026 de 041) | no vuelto a medir en CI |
| Los agentes desplegados corren aarch64 | Declarado en el repositorio | CLAUDE.md |
| El `vec0.so` musl horneado existe en la imagen amd64 | Medido (por un test, no por el volcado de E1) | `qmd real (016)` exige que `/opt/agent-admin/sqlite-vec/vec0.so` exista y no lleve `GLIBC_` (`tests/docker-e2e-qmd.bats:705-706`) y pasó en amd64 en E1 (`ok 15`, `specs/041-nightly-qmd-embed/tasks.md:399`) |
| La compilación de llama.cpp termina en amd64 | Medido de forma indirecta | E1: el setup llegó al intento de embed; `qmd real (016)` pasa en amd64 |
| Velocidad del embed y de la búsqueda en x86_64 con esas opciones de compilación | No medida | pendiente |
| Las cinco fases posteriores a `setup` pasan en amd64 | No medido | E1 se detuvo en `setup` |
| Duración de un job verde con la fase activa | No medida; el job rojo duró 21 min 19 s y los mismos 48 e2e variaron 29 % entre dos corridas | E1, E2 y E3 de 041 |
| Hay runners arm64 gratuitos para repositorios públicos (`ubuntu-24.04-arm`), útiles para la feature aparte de cobertura arm64 | Documentado por GitHub (agosto de 2025); no probado en este repositorio | anuncio de GitHub |

## Clarifications

### Session 2026-10-18

- Q: ¿Esta feature debe sumar al nightly un job que ejercite el embed también en un runner arm64 (la arquitectura de los agentes desplegados), o eso se difiere a una feature aparte? → A: Se difiere a una feature aparte. 042 queda en amd64 y el no-regreso en arm64 lo cubre el DOCKER_E2E local de FR-008; evita mezclar dos mediciones y dos riesgos en un mismo PR, y la feature aparte diseña el job con la duración que mida 042 (FR-014).
- Q: ¿La línea de log de un reemplazo imposible debe nombrar siempre los paquetes presentes o solo cuando la causa es el paquete? → A: Solo cuando la causa es el paquete (resuelto en `/speckit-analyze` el 18-10-2026). Las líneas del artefacto horneado ausente y de la copia fallida, que ya existen y que FR-002 manda conservar, nombran la causa y no la lista de paquetes; FR-005 y SC-003 quedan acotados a eso y el contrato fija el texto de cada línea.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Quien corre el agente en x86_64 tiene búsqueda semántica, como en arm64 (Priority: P1)

Como operador que ejecuta la imagen del agente en un host x86_64, quiero que el embed y la búsqueda semántica de qmd funcionen igual que en un host arm64, para no quedarme con el índice léxico solo y sin saber por qué.

**Why this priority**: Es el defecto. Todo lo demás (el aviso del nightly, su fase apagada) depende de que el producto funcione en esa arquitectura.

**Independent Test**: Construir la imagen del test de qmd real en amd64 y ejecutar su fase del embed: el setup del primer arranque termina, la extensión vectorial del prefijo gestionado es la build musl, el reindexado deja `pending` en 0 y `vsearch` devuelve el documento esperado. Antes del arreglo el mismo procedimiento termina en rojo en `setup` (E1 de 041).

**Acceptance Scenarios**:

1. **Given** la imagen sobre amd64 con la toolchain, **When** termina el primer setup de qmd, **Then** el paquete de la extensión que corresponde a la arquitectura contiene la build musl y el setup no informa fallas (FR-001).
2. **Given** esa imagen y un vault con un documento bajo `wiki/`, **When** se reindexa y se hace una búsqueda semántica, **Then** el reindexado termina completo y la búsqueda devuelve el documento (FR-001).
3. **Given** la imagen sobre arm64, **When** corre el mismo flujo, **Then** el resultado, el archivo reemplazado y la línea de log son los de hoy (FR-002).
4. **Given** el modo local (glibc), **When** corre el arranque de qmd, **Then** el reemplazo no hace nada, como hoy (FR-003).

---

### User Story 2 - Un reemplazo imposible deja rastro y no tumba nada (Priority: P1)

Como mantenedor, quiero que cuando el reemplazo de la extensión no pueda hacerse el log diga por qué (la causa y, si lo que falta es el paquete, qué arquitectura se esperaba y qué paquetes había) y que el índice léxico siga funcionando, para que el próximo defecto de este tipo no necesite una corrida de CI para descubrirse.

**Why this priority**: El defecto de #107 vivió callado: el camino "no hay nada que reemplazar" no registra nada. Esta rebanada hace diagnosticable la próxima variante (otra disposición de paquetes, un prefijo traído de otra arquitectura) y es barata; es P1 porque vale aunque el reemplazo ya funcione.

**Independent Test**: En el host, sin Docker: con prefijos falsos que reproducen cada caso (paquete de la otra arquitectura, ningún paquete, artefacto horneado ausente, destino no escribible), la función termina con éxito y el log nombra la causa y, cuando la causa es el paquete, los paquetes presentes.

**Acceptance Scenarios**:

1. **Given** una máquina musl y un prefijo que solo trae el paquete de otra arquitectura (por ejemplo, un workspace llevado de un host arm64 a uno x86_64), **When** corre el reemplazo, **Then** el log lo dice (arquitectura esperada y paquetes encontrados), termina con éxito y no toca el paquete ajeno (FR-004, FR-005).
2. **Given** una máquina musl y un prefijo sin ningún paquete `sqlite-vec-linux-*`, **When** corre el reemplazo, **Then** el log lo dice y termina con éxito (FR-005).
3. **Given** que el artefacto horneado falta o que la copia falla, **When** corre el reemplazo, **Then** el log lo dice, termina con éxito y el índice léxico sigue funcionando (FR-005).
4. **Given** un reemplazo ya hecho, **When** vuelve a correr, **Then** no cambia nada y no agrega ruido al log (FR-006).

---

### User Story 3 - El nightly vuelve a ejercitar el embed, con el margen del tope medido (Priority: P2)

Como mantenedor, quiero vaciar el interruptor de #107 y ver el nightly ejecutar la fase del embed en amd64, con la duración del job y su margen medidos en al menos 3 corridas, para que el verde vuelva a significar que el embed anduvo.

**Why this priority**: Es lo que cierra #107 y le devuelve a 041 su valor, pero depende de US1: sin el arreglo la fase vuelve a ponerse roja.

**Independent Test**: Con el arreglo aplicado, lanzar `docker-e2e` a mano con el interruptor vacío y leer el log: `qmd real (041)` figura como ejecutado, con sus ocho marcas, y el resumen lo cuenta; repetir sobre una rama de ensayo con el build sin toolchain y comprobar el rojo con la fase nombrada.

**Acceptance Scenarios**:

1. **Given** el arreglo aplicado y el interruptor vacío, **When** corre el workflow a mano, **Then** `qmd real (041)` pasa en amd64 con las ocho marcas y el resumen lo cuenta entre los ejecutados (FR-009).
2. **Given** esas corridas, **When** se lee la duración del job (de `started_at` a `completed_at`), **Then** queda registrada en al menos 3 corridas con su margen frente al tope; si en alguna el margen es menor de 5 minutos, el tope se sube primero y se vuelve a medir (FR-010).
3. **Given** una rama de ensayo cuya imagen del test se construye sin toolchain, **When** corre el workflow, **Then** el job queda en rojo y la última marca de fase es `setup` o `vector-extension` (FR-011).
4. **Given** las tres noches siguientes al merge, **When** se lee cada una, **Then** ejecutó la fase (no la saltó) y terminó con al menos 5 minutos de margen (SC-001).
5. **Given** que la primera corrida con el arreglo destapa otro defecto de producto en amd64 (por ejemplo, de las opciones de compilación de llama.cpp; no cuenta la build musl horneada ausente, que se corrige aquí), **When** se clasifica, **Then** se registra en un issue y el interruptor pasa a nombrarlo, como fijó 041; no se mezcla con este arreglo (FR-013).

---

### Edge Cases

- Un workspace llevado de un host arm64 a uno x86_64 trae el prefijo gestionado compilado para la otra arquitectura (el hash de instalación no cambió, así que no se reinstala): el reemplazo no encuentra el paquete de esta arquitectura y debe decirlo (US2, escenario 1). Rehacer el prefijo queda fuera de alcance.
- Un prefijo con los dos paquetes (`sqlite-vec-linux-x64` y `sqlite-vec-linux-arm64`): solo se toca el de la arquitectura de la máquina, porque la build horneada se compiló para la arquitectura de la imagen.
- La build horneada y el paquete a reemplazar son de arquitecturas distintas: nunca debe copiarse una sobre la otra (FR-004).
- Una imagen construida sin toolchain (`QMD_NATIVE_TOOLCHAIN=0`): no hay artefacto horneado. En arm64 el comportamiento actual (registrar que el embed vectorial no está disponible y seguir con el índice léxico) no cambia. En amd64 sí cambia: con el paquete x64 que `bun install` instala allí, hoy la función sale callada al comprobar el destino, fijo en el paquete arm64 (`qmd_index.sh:130-132`), antes de llegar a la comprobación del artefacto (`:133`); con este cambio llega a ella y registra la causa (FR-005).
- El reemplazo corre en cada preparación del prefijo, incluso cuando la instalación se saltó (un prefijo restaurado de `.state` sobre un contenedor nuevo): debe seguir siendo idempotente y barato.
- El destino no es escribible o la copia falla: se registra y se sigue.
- Una arquitectura que la imagen no soporta (distinta de x86_64 y aarch64): la imagen no se construye, porque los `case` del Dockerfile salen con error; no es un caso de ejecución esperado. Aun así la función cubre ese caso con una rama defensiva que deja rastro en el log (la ejercitan las pruebas del host con una arquitectura falsa), para que, si algún día ocurre, no sea otro camino callado.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: En la imagen del agente ejecutándose sobre amd64, tras el primer arranque de qmd, la extensión vectorial que carga qmd MUST ser la build musl, y el embed, el reindexado y la búsqueda semántica MUST funcionar, igual que hoy en arm64.
- **FR-002**: En arm64 el comportamiento MUST quedar igual que hoy: el mismo archivo reemplazado, la misma línea de log al reemplazarlo y la misma idempotencia.
- **FR-003**: En glibc (modo local) el reemplazo MUST seguir sin hacer nada, con las garantías de hoy.
- **FR-004**: El reemplazo MUST actuar sobre el paquete de la extensión que corresponde a la arquitectura de la máquina, y MUST NOT copiar la build de una arquitectura sobre el paquete de otra ni tocar un paquete ajeno.
- **FR-005**: Cuando el reemplazo no pueda hacerse (ningún paquete reconocible para la arquitectura, artefacto horneado ausente, copia fallida), MUST dejar en el log una línea con la causa, MUST terminar con éxito y MUST dejar funcionando el índice léxico (principio IV de la constitución: degradar, no caer). Cuando la causa es que falta el paquete de la arquitectura, la línea MUST además nombrar los paquetes `sqlite-vec-linux-*` que sí hay en el prefijo (o decir que no hay ninguno); en los otros dos casos (artefacto horneado ausente, copia fallida) basta con la causa, porque el paquete estaba y la línea ya dice qué falló. El caso "no hay paquete que reemplazar", que hoy es callado, MUST dejar rastro.
- **FR-006**: El reemplazo MUST seguir siendo idempotente y barato, porque corre en cada preparación del prefijo: una segunda ejecución no cambia nada y no agrega ruido al log.
- **FR-007**: El comportamiento nuevo MUST nacer con pruebas del host (sin Docker) que cubran la disposición x64, la arm64, los casos de FR-004 y FR-005 y la idempotencia, con el ROJO visto antes del arreglo (principio III: test-first).
- **FR-008**: La verificación con contenedor real (DOCKER_E2E) MUST ejecutarse con el arreglo en arm64 (local) y en amd64 (CI), y sus resultados MUST quedar registrados con el identificador de cada corrida; la de amd64 es la que cierra #107.
- **FR-009**: Al cerrar #107, `QMD_EMBED_DEFECT` MUST quedar con valor vacío (`''`) en el `env` del paso `fetch_models` del workflow (la clave se conserva: el test W6 de `tests/qmd-embed-nightly.bats` exige que siga declarada y acepta el valor vacío) y el nightly MUST ejecutar la fase: `qmd real (041)` figura como ejecutado en el log del job (su línea TAP `ok N` no lleva `# skip`) y la línea `e2e summary:`, que solo trae conteos, lo cuenta entre las ejecutadas (con la fase apagada dice `executed=48 skipped=1`; con la fase activa debe decir `skipped=0`).
- **FR-010**: La duración del job con la fase activa MUST medirse en al menos 3 corridas (los mismos 48 e2e variaron 29 % entre dos) y su margen frente a `timeout-minutes` MUST registrarse. Si en alguna el margen es menor de 5 minutos, el tope MUST subirse primero y volver a medirse (decisión de 041).
- **FR-011**: La rotura inducida (imagen del test sin toolchain, en una rama de ensayo que no se mergea) MUST dejar el job en rojo con la última marca de fase en `setup` o `vector-extension`.
- **FR-012**: El cambio MUST llevar su bump de `VERSION` (verificado contra `origin/main` a mano tras cualquier rebase), una entrada de CHANGELOG, y corregir lo que hoy dice que el reemplazo solo conoce arm64, que el cierre de su línea de log tiene una sola causa y que el nightly corre el embed en amd64 o lo salta con un defecto abierto: las viñetas de CLAUDE.md, el ítem «017 swap path» de `docs/qmd-upgrade-checklist.md` y los pasajes de `docs/vault.md` (el párrafo de la sección 017 y el paso 3 del diagnóstico) que atan `vector embed unavailable, lexical index intact` al artefacto horneado ausente.
- **FR-013**: Si la primera corrida real con el arreglo destapa otro defecto de producto en amd64, MUST aplicarse la política de 041: se registra en un issue y el interruptor pasa a nombrarlo; ese defecto no se mezcla con este arreglo. La única excepción es que la build musl horneada no exista en la imagen amd64 (el supuesto de más abajo): eso es parte de este arreglo y se corrige aquí, con su revisión de privilegios, sin pasar por un issue aparte. Esta feature MUST NOT cambiar las versiones de qmd o de sqlite-vec, la base Alpine ni el modo local.
- **FR-014**: El nightly MUST seguir ejecutando la fase solo en amd64: esta feature MUST NOT agregar ningún job ni matriz para arm64. El no-regreso en arm64 se verifica con el DOCKER_E2E local de FR-008 (SC-002); la cobertura permanente en arm64 es otra feature.

### Key Entities

- **Paquete de la extensión vectorial por arquitectura** (`sqlite-vec-linux-x64`, `sqlite-vec-linux-arm64`): lo instala el gestor de paquetes según la CPU y trae un `vec0.so` glibc.
- **Extensión musl horneada**: un `vec0.so` compilado durante el build de la imagen, para la arquitectura de la imagen y para musl; es lo que reemplaza al binario glibc.
- **Prefijo gestionado de qmd**: la instalación de qmd bajo el estado del workspace (`.state/.cache/qmd/pkg`), que sobrevive a los reinicios y viaja con el workspace.
- **Interruptor de defecto abierto** (`QMD_EMBED_DEFECT`) e **issue #107**: lo que mantiene apagada la fase del embed del nightly y lo que debe vaciarse al cerrar.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Con el arreglo aplicado y el interruptor vacío, `qmd real (041)` pasa en amd64 con sus ocho marcas en una corrida manual y las tres nocturnas siguientes al merge ejecutan la fase (ninguna la salta) y terminan con al menos 5 minutos de margen contra el tope.
- **SC-002**: En arm64 el DOCKER_E2E local de `qmd real (016)` y `qmd real (041)` sigue en verde, con el mismo archivo reemplazado y la misma línea de log que antes del cambio.
- **SC-003**: En los cuatro casos de reemplazo imposible (paquete de otra arquitectura, ningún paquete, artefacto ausente, copia fallida) el log basta para diagnosticar la causa sin una segunda corrida: nombra la causa en los cuatro y, en los dos en que la causa es el paquete (el de otra arquitectura y ningún paquete), nombra además los paquetes `sqlite-vec-linux-*` presentes (verificado en el host con prefijos falsos).
- **SC-004**: La duración del job con la fase activa queda medida en al menos 3 corridas, con su mínimo y su máximo registrados; si el margen mínimo es menor de 5 minutos, el tope se sube y se mide de nuevo.
- **SC-005**: La rotura inducida deja el job en rojo con la última marca en `setup` o `vector-extension` en una corrida real.
- **SC-006**: La suite del host termina con 0 pruebas fallidas en bash 5.x y en 3.2, con el conteo esperado (la base de `main` más las pruebas nuevas).
- **SC-007**: #107 se cierra con las cinco obligaciones cumplidas y registradas, y `QMD_EMBED_DEFECT` queda vacío en `main`.

## Assumptions

- La imagen sigue soportando solo x86_64 y aarch64 (los `case` por arquitectura del Dockerfile), y `ubuntu-latest` sigue siendo amd64.
- El `vec0.so` musl se compila en el build de la imagen para la arquitectura de la imagen, y `qmd real (016)` exige que exista y no sea glibc (`tests/docker-e2e-qmd.bats:705-706`; pasó en amd64 en E1). Si alguna corrida lo desmintiera, corregirlo es parte de este arreglo (es la excepción de FR-013).
- Los agentes desplegados siguen en aarch64: el arreglo no los afecta y no se despliega por urgencia.
- 041 (PR #108) ya está en `main` (squash `0fc08a8`, 19-10-2026); esta rama se rebasa sobre `main` antes de empezar la implementación. El único conflicto previsible del rebase es `.specify/feature.json` (en `main` apunta a `specs/041-nightly-qmd-embed`; esta rama lo cambia a `specs/042-qmd-sqlite-vec-x64`). `CHANGELOG.md`, `CLAUDE.md` y `docs/qmd-upgrade-checklist.md` también cambiaron en `main` y esta feature los edita: solo chocarían si se editaran antes del rebase, por eso se editan después.
- El bump de `VERSION` es MINOR (0.28.0 a 0.29.0 si `origin/main` sigue en 0.28.0 al implementar): es la práctica del repositorio para las features que tocan código de runtime (017, 018, 023, 024 y 026; el 0.25.1 fue una corrección puntual fuera de feature), y el plan lo verifica contra `origin/main` a mano. Es un default sin pregunta al operador: se cambia en un paso si prefiere PATCH.
- Las opciones de compilación de llama.cpp pensadas para ARM no impiden que el embed corra en x86_64; si la primera corrida demuestra lo contrario, se trata como otro defecto (FR-013).

## Out of Scope

- Cambiar las versiones de qmd o de sqlite-vec, y cambiar la base Alpine.
- Tocar el modo local (glibc), donde el prebuilt carga sin reemplazo.
- Rehacer un prefijo traído de otra arquitectura (solo se diagnostica, US2).
- La cobertura permanente del embed en arm64 dentro del nightly (un job o una matriz en un runner `ubuntu-24.04-arm`): feature aparte, que se diseña con la duración que mida esta.
- Mejorar la velocidad de llama.cpp en x86_64, compartir el prefijo compilado entre los tests 016 y 041, o conservar los modelos entre noches (041 las dejó como mejoras posteriores con medición).
