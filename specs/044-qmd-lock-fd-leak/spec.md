# Feature Specification: Las secciones con lock de qmd sueltan `.reindex.lock` en cuanto terminan

**Feature Branch**: `044-qmd-lock-fd-leak`

**Created**: 2026-11-06

**Status**: Draft

**Input**: Issue #116. El `timeout` de BusyBox que envuelve cada llamada a qmd deja un proceso vigilante que hereda el descriptor del lock y retiene `.reindex.lock` cerca de 1 s después de que termina cada sección del setup y del reindex. En ese segundo, un reindex o una migración que llega pierde el lock y se salta con rc 0, como el producto hace a propósito. El operador decidió (06-11-2026) abrir el arreglo como la feature 044 mientras corren las noches de T046 de 043. Es un arreglo de producto: cambia `scripts/lib/qmd_index.sh`, que se hornea en la imagen, y lleva CHANGELOG y bump de `VERSION`.

## Contexto

**El defecto, medido.** En contenedores desechables (`alpine:3.24.1` con BusyBox 1.37.0 y `alpine:3.20` con BusyBox 1.36.1, `flock` de util-linux, 3 repeticiones por caso), una sección `( exec 9>"$lock"; flock -n 9 || exit 9; timeout 900 sh -c 'exit 0' )` deja el lock tomado entre 0,9 y 1 s después de terminar (9 a 10 sondeos de 100 ms con `flock -n`), y el dueño en ese instante es un proceso `timeout 900 sh -c exit 0`. La misma sección sin `timeout` lo deja libre de inmediato (0 sondeos). El `timeout` de BusyBox deja un hijo que vigila el comando y hereda los descriptores abiertos; el lock de `flock` pertenece a la descripción de archivo abierta, así que sigue tomado hasta que ese hijo termina. La reproducción mínima y la medición están en el cuerpo del issue #116.

**Dónde ocurre en el producto (leído en código).** `_qmd_run` envuelve cada llamada batch a qmd en `timeout ${QMD_CMD_TIMEOUT:-900}` (`scripts/lib/qmd_index.sh:265-284`, el `timeout` en `:272`), y `_qmd_ensure_prefix`, que `_qmd_run` llama antes de cada comando (`:273`), envuelve `bun install` en `timeout ${QMD_INSTALL_TIMEOUT:-3600}` cuando el manifiesto cambió (`:209-261`, el `timeout` en `:212-219`). Esas llamadas corren dentro de los dos subshells que toman el lock con `9>"$lock"` y `flock -n 9`:

- el setup del primer arranque (`:474-479`, que llama a `_qmd_setup_locked`, `:491-540`: `collection add`, `update` y `embed`);
- el reindex (`:556-564`, que llama a `_qmd_reindex_locked`): la migración de 037 cuando está pendiente (`:681`, que llama a `qmd_migrate_collection`, `:352-400`: `collection remove`, `collection add`, `update`, `cleanup`, `status` y `embed`), `update` (`:708`), el `status` de `_qmd_pending_count` (`:612`) y las pasadas de `embed` de 018 (`:630`).

La imagen de producción parte de `alpine:3.24.1` (`docker/Dockerfile:5`, BusyBox 1.37.0), instala `flock` (`:45`) y no instala coreutils, así que su `timeout` es el de BusyBox. `qmd_index.sh` se copia a la imagen (`docker/Dockerfile:265` y el espejo de `setup.sh:1653-1676`): es código horneado y exige DOCKER_E2E.

**La evidencia en marcha (medida).** La sonda de dueños de 043 lo vio en todas las ejecuciones donde pudo verlo:

- la inyección local de T035;
- el DOCKER_E2E local de T037, sin inyección;
- la corrida manual de CI 41366019180;
- las cinco nocturnas del 02 al 06-11-2026 (runs 41451854763, 41637958445, 41832977811, 42031904387 y 42220504587).

En las cinco nocturnas, el segundo tick de la prueba 13 de `tests/docker-e2e-qmd.bats` perdió su primer intento y la sonda nombró de 5 a 7 dueños `timeout 900 /home/agent/.cache/qmd/pkg/node_modules/.bin/qmd ...`: las llamadas del tick anterior, que ya había terminado. El ayudante de 043 reintenta y absorbe la contención en las pruebas. El producto no tiene ese ayudante.

**Qué le cuesta al producto.** El perdedor del lock escribe `already running — skip` y sale con 0 por diseño (Principio IV), así que el costo es un trabajo que no se hace:

- Un `heartbeatctl qmd-reindex` lanzado en ese segundo no hace nada y sale con 0.
- El vigilante de archivos (`scripts/qmd_watch.sh`) dispara un solo reindex, 15 s después del último evento del vault (`QMD_WATCH_DEBOUNCE`, `:20`), con la salida descartada y sin reintento. Si ese reindex cae en el segundo del vigilante del `timeout`, la edición queda sin indexar hasta el próximo reindex del cron (inferido, no medido).
- La noche roja de #112 (29-10-2026) es, probablemente, este mismo mecanismo: la fase `reindex` intentó 0,3 s después de la marca que sigue al sentinel del setup (inferido; la sonda no existía esa noche).

**Un efecto que se sospechó y no existe (medido en la Fase 0 del plan, `research.md` M2).** Se pensó que el vigilante heredaba también la salida estándar. Si así fuera, una llamada dentro de una sustitución de comando, como `out=$(_qmd_run "$pkg" status)` (`:612`), esperaría cerca de 1 s más. No pasa: el vigilante de BusyBox deja los descriptores 0, 1 y 2 en `/dev/null` y conserva el 9, y la sustitución vuelve en 0 ms. El único costo es el lock.

**Modo local.** Usa la misma librería. En un host Linux con glibc, `timeout` es el de GNU coreutils, que no deja vigilante: la misma sección mínima suelta el lock de inmediato (medido en `ubuntu:24.04`, `research.md` M3). Hoy el modo local en Linux no tiene el defecto, y el arreglo debe ser inocuo ahí. Un host sin `flock` (macOS de desarrollo) corre las secciones sin lock (`:568-572`) y tampoco lo tiene.

**Un hallazgo lateral, fuera de alcance.** La migración manual corre sin el lock, aunque el comentario de `qmd_migrate_collection` dice lo contrario (`:336-340`: «Runs under .reindex.lock (caller's responsibility ...)»):

- en docker, `heartbeatctl qmd-migrate` llama a `qmd_migrate_collection` directo (`docker/scripts/heartbeatctl:1157-1194`);
- en local, `agentctl heartbeat qmd-migrate` entra por `agent-qmd-reindex.sh --migrate`, que hace lo mismo (`scripts/agentctl:1703-1709`, `modules/local-qmd-reindex.sh.tpl:54-61`).

Una migración manual puede, entonces, correr al mismo tiempo que un reindex (leído en código, sin medir). No es un problema de descriptores heredados. Se declara para un issue propio, que sale del equipo y lleva COMPUERTA.

### Estado de cada afirmación

| Afirmación | Estado | Fuente |
| --- | --- | --- |
| El `timeout` de BusyBox 1.36.1 y 1.37.0 deja un hijo que retiene un lock de `flock` heredado 0,9 a 1 s después de que el comando termina; sin `timeout` el lock queda libre de inmediato | Medido (contenedores desechables, 3 repeticiones por caso) | issue #116 |
| Cada llamada batch a qmd pasa por `timeout ${QMD_CMD_TIMEOUT:-900}` y `bun install` por `timeout ${QMD_INSTALL_TIMEOUT:-3600}` | Leído en código | `qmd_index.sh:212-219,272` |
| Esas llamadas corren dentro de los subshells con `9>"$lock"` del setup y del reindex, incluida la migración de 037 | Leído en código | `qmd_index.sh:474-479,556-564,681` |
| La imagen de producción usa el `timeout` de BusyBox 1.37.0 | Leído en código (base `alpine:3.24.1`, sin coreutils) | `docker/Dockerfile:5,45` |
| `qmd_index.sh` se hornea en la imagen | Leído en código | `docker/Dockerfile:265`; `setup.sh:1653-1676` |
| El segundo tick de la prueba 13 pierde su primer intento contra 5 a 7 vigilantes `timeout 900 .../qmd` en cada nocturna posterior al merge de 043 | Medido (5 de 5 noches) | runs 41451854763, 41637958445, 41832977811, 42031904387 y 42220504587 |
| Lo mismo pasó sin inyección en local (T037) y en la corrida manual de CI 41366019180 | Medido | comentarios del issue #116 |
| Perder el lock se salta con rc 0 y `already running — skip`, por diseño | Leído en código | `qmd_index.sh:561-566` |
| El vigilante de archivos dispara un solo reindex 15 s después del último evento, sin reintento | Leído en código | `scripts/qmd_watch.sh:20,44-70` |
| Una edición del vault puede quedar sin indexar hasta el próximo reindex del cron | Inferido, sin medir | lectura de lo anterior |
| La noche roja de #112 fue este mecanismo | Inferido (calza con la cronología; la sonda no existía) | issue #112; comentario del 02-11 en #116 |
| Una llamada dentro de `$(...)` tarda cerca de 1 s más porque el vigilante hereda el pipe | **Refutado**: el vigilante deja 0, 1 y 2 en `/dev/null`; la sustitución tarda 0 ms | `research.md` M2 (BusyBox 1.36.1 y 1.37.0) |
| El `timeout` de GNU coreutils (modo local en Linux con glibc) no deja un vigilante | Medido: 0 sondeos en 3 de 3, sin arreglo | `research.md` M3 (`ubuntu:24.04`) |
| Ninguna otra sección con `flock` del repo lanza procesos con `timeout` | Leído en código | `wiki_graph.sh:368-393`; `docker/scripts/lib/state.sh:55,75,102` |
| La migración manual corre sin el lock | Leído en código; fuera de alcance | `heartbeatctl:1157-1194`; `agentctl:1703-1709`; `local-qmd-reindex.sh.tpl:54-61` |
| Cerrar el descriptor del lock en las llamadas de la sección (por ejemplo, `9>&-`) lo arregla | Medido: funciona, y se descartó porque depende de enumerar cada proceso | `research.md` M4 y D1 |
| Un `trap ... EXIT` que suelta el lock lo suelta también ante un SIGTERM al subshell de la sección, aunque un hijo siga corriendo; hoy ese hijo lo retiene | Medido (bash 3.2.57 y 5.3.15); por eso el arreglo suelta el lock al final de la sección y no con un `trap` | `research.md` M8 |

## Clarifications

### Session 2026-11-06

- Q: ¿Qué procesos debe cubrir el arreglo para que no retengan el lock al terminar la sección? → A: Todo lo que corre bajo el lock: las llamadas a qmd de `_qmd_run`, el `bun install` de `_qmd_ensure_prefix` y sus descendientes. El plan revisa cada comando externo de las dos secciones (FR-006).
- Q: ¿Qué evidencia hace falta antes de abrir el PR? → A: El DOCKER_E2E local más una corrida manual del workflow en CI sobre la rama, como en 043. Push y dispatch llevan COMPUERTA (FR-009).

### Session 2026-11-07 (análisis)

- Q: El `trap ... EXIT` del plan suelta el lock ante un SIGTERM al subshell aunque un qmd hijo siga corriendo (`research.md` M8). ¿Qué forma tiene el arreglo? → A: Un `flock -u 9` explícito como último paso de cada sección, sin `trap`. Con una señal, el lock queda como hoy (caso borde de la sección que muere a mitad de camino).
- Q: Ninguna prueba del repo cubre el tope de tiempo. ¿Cómo se verifica SC-004? → A: Con el `timeout` real en contenedores (BusyBox y GNU) y una comprobación estructural de que el diff no toca `_qmd_run` ni `_qmd_ensure_prefix`. Se mantienen las 10 pruebas nuevas.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - El lock queda libre en cuanto termina la sección (Priority: P1)

Cuando el setup, un reindex o la migración de 037 terminan, ningún proceso que esa sección lanzó sigue teniendo `.reindex.lock`. Un reindex o una migración que llega justo después lo obtiene y corre.

**Why this priority**: Es el defecto. Hoy el producto pierde en silencio el trabajo que llega en ese segundo, y el vigilante de archivos no reintenta. Sin esto, el resto de la feature no tiene objeto.

**Independent Test**: Se ejecuta una sección real del producto que llama a qmd a través de `timeout` y, al terminar, se sondea el lock con `flock -n` cada 100 ms. Con el arreglo, el primer sondeo lo obtiene; hoy hacen falta de 9 a 10. Se prueba en el host con un `timeout` falso que deja un hijo con los descriptores heredados, y en un contenedor real con BusyBox 1.36.1 y 1.37.0.

**Acceptance Scenarios**:

1. **Given** un reindex que acaba de terminar, **When** otro reindex empieza inmediatamente después, **Then** toma el lock y corre: no escribe `already running — skip`.
2. **Given** el setup que acaba de escribir su sentinel, **When** un `heartbeatctl qmd-reindex` empieza inmediatamente después, **Then** toma el lock y corre.
3. **Given** un reindex que ejecutó la migración de 037, **When** termina, **Then** el lock queda libre en el primer sondeo, igual que tras un reindex sin migración.
4. **Given** un reindex que todavía está corriendo, **When** empieza otro, **Then** el segundo se salta con rc 0 y `already running — skip`, como hoy: el lock sigue protegiendo la sección mientras dura.

---

### User Story 2 - El arreglo no cambia nada más (Priority: P1)

El tope de tiempo de cada llamada, las salidas capturadas, los códigos de retorno, el log redactado, el modo local y la degradación sin `flock` o sin `timeout` se comportan igual que hoy.

**Why this priority**: El cambio toca la función por la que pasa toda llamada batch a qmd, en código horneado. Un tope que deja de cortar, una salida que se pierde o un código de retorno distinto rompería el arranque o el reindex de toda la flota en la próxima imagen. Vale tanto como el arreglo.

**Independent Test**: La suite del host sigue en verde sin cambiar ninguna prueba existente. Una prueba nueva afirma que el código de retorno y el estado del índice no cambian con un vigilante vivo. El tope se mide con el `timeout` real en contenedores con BusyBox y con GNU, y una comprobación estructural confirma que el diff no toca `_qmd_run` ni `_qmd_ensure_prefix`. El DOCKER_E2E de qmd pasa en un contenedor real.

**Acceptance Scenarios**:

1. **Given** un comando de qmd que se cuelga, **When** supera `QMD_CMD_TIMEOUT`, **Then** se termina igual que hoy, con los mismos códigos (143 tras TERM en BusyBox; 124 en GNU).
2. **Given** `QMD_INSTALL_TIMEOUT=0`, **When** corre `bun install`, **Then** corre sin tope, como hoy: `_qmd_ensure_prefix` no cambia, y la comprobación estructural del diff lo verifica.
3. **Given** una llamada cuya salida se captura (un archivo de log o una sustitución de comando), **When** termina, **Then** el contenido y el código de retorno son los mismos que hoy.
4. **Given** un host sin `timeout` o sin `flock`, **When** corre el setup o el reindex, **Then** se degrada igual que hoy (llamada directa, o sección sin lock con su línea de log).
5. **Given** el modo local en Linux con el `timeout` de GNU, **When** corre un reindex, **Then** el resultado es el mismo que hoy: el lock ya quedaba libre de inmediato (`research.md` M3) y sigue así.

---

### User Story 3 - La corrección se demuestra y se vigila (Priority: P2)

Primero las pruebas nuevas caen contra el código actual con la firma del defecto, el lock tomado después de la sección. Después pasan con el arreglo, en el host y en un contenedor real. Las nocturnas posteriores al merge registran si la contención del segundo tick de la prueba 13 desaparece.

**Why this priority**: Es la evidencia de cierre del issue. Sin el ROJO visto antes del VERDE, no se sabe si las pruebas podían fallar (Principio III). Sin el contenedor real, el `timeout` falso del host podría no representar a BusyBox.

**Independent Test**: El oráculo del host corre en bash 3.2 y 5.x contra `origin/main` (ROJO) y contra la rama (VERDE). La medición en contenedor repite la del issue con las secciones reales. Las nocturnas se registran como en T046 de 043.

**Acceptance Scenarios**:

1. **Given** el código actual, **When** corre el oráculo nuevo, **Then** sus pruebas del lock caen porque el lock sigue tomado tras la sección.
2. **Given** el código con el arreglo, **When** corre el oráculo en bash 3.2 y en 5.x, **Then** pasan todas.
3. **Given** un contenedor con BusyBox 1.36.1 o 1.37.0, **When** termina cada sección real (setup, reindex y migración), **Then** el lock queda libre en el primer sondeo de 100 ms.
4. **Given** las nocturnas posteriores al merge, **When** se registran, **Then** cada una dice si el segundo tick de la prueba 13 reportó contención y, si la reportó, quién tenía el lock.

---

### Edge Cases

- **Un comando de qmd que lanza sus propios hijos** (node, o los compiladores que corre `bun install` para el build nativo): si un nieto hereda el descriptor y vive más que el comando, el lock queda tomado igual. FR-006 los incluye: el plan mide cuáles corren bajo el lock y comprueba que ninguno conserve el descriptor.
- **Un comando que el `timeout` termina por tope**: el lock debe quedar libre cuando el vigilante y el comando ya no existen, igual que en una salida normal.
- **Una sección que muere a mitad de camino** (el contenedor se detiene, o una señal al subshell, como un `pkill -f heartbeatctl`, que alcanza al subshell porque es un fork con la misma línea de comando): hoy el lock se libera cuando muere el último proceso que lo tiene, y si un qmd hijo sigue corriendo, el lock lo protege hasta que termine. El arreglo no puede empeorarlo. Por eso el lock se suelta en el último paso de la sección y no con un `trap`: un `trap ... EXIT` se dispara también ante un SIGTERM y soltaría el lock con el hijo todavía trabajando, de modo que un segundo reindex podría correr al mismo tiempo (`research.md` M8).
- **El `timeout` de GNU en modo local**: no deja vigilante (`research.md` M3). El arreglo debe ser inocuo ahí.
- **Nocturnas de 043 que todavía corren** (T046, hasta el 11-11-2026): si 044 se mergea antes de la décima, las noches restantes de 043 corren con el arreglo y su contención en la prueba 13 puede desaparecer por 044, no por 043. Cada noche ya registra su commit.
- **Agentes desplegados con una imagen anterior**: siguen con el defecto hasta reconstruir la imagen. El arreglo llega con el upgrade normal y no exige migración de datos.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Cuando termina una sección con lock del setup o del reindex (incluida la migración de 037), ningún proceso lanzado por esa sección retiene `.reindex.lock`. Un `flock -n` inmediatamente posterior lo obtiene en el primer intento.
- **FR-002**: La semántica del lock no cambia. Se toma con `flock -n`. El perdedor escribe `already running — skip` y la función devuelve 0. El lock está tomado durante toda la sección, y ningún paso de la sección corre sin él.
- **FR-003**: El tope de tiempo de cada llamada sigue vigente con el mismo comportamiento y los mismos códigos de salida: `QMD_CMD_TIMEOUT`, por defecto 900, y `QMD_INSTALL_TIMEOUT`, por defecto 3600, donde 0 significa sin tope.
- **FR-004**: No cambia nada observable más allá del lock:
  - las salidas y su captura en los archivos de log;
  - los códigos de retorno de `_qmd_run` y de sus llamadores;
  - la cola redactada que llega a los logs;
  - el `LD_PRELOAD` de `embed`;
  - el `TMPDIR` de cada llamada.
- **FR-005**: El modo local y la degradación se comportan como hoy. El modo local cubre Linux con el `timeout` de GNU; la degradación cubre un host sin `timeout` o sin `flock`. El arreglo no depende de qué implementación de `timeout` haya en el host.
- **FR-006**: El arreglo cubre todo proceso que se lance dentro de las dos secciones con lock: las llamadas a qmd de `_qmd_run`, el `bun install` de `_qmd_ensure_prefix` y los descendientes de ambos. El plan inventaría cada comando externo de las dos secciones y deja escrito, para cada uno, si hereda el descriptor 9 y cómo queda cubierto. Un comando de vida corta que el plan mida sin descendientes que lo sobrevivan puede quedar sin cambio, con su medición registrada.
- **FR-007**: El oráculo del host demuestra el defecto sin Docker. Usa un `timeout` falso que deja un hijo con los descriptores heredados durante un tiempo fijo. Primero cae contra el código actual y después pasa con el arreglo, en bash 3.2 y en 5.x. Lo acompaña un catálogo de mutaciones que prueba que cada prueba nueva puede fallar.
- **FR-008**: Un contenedor real confirma el arreglo, con BusyBox 1.36.1 (`alpine:3.20`, la base de las pruebas 12 y 13) y 1.37.0 (`alpine:3.24.1`, la base de producción): tras cada sección real, el lock queda libre en el primer sondeo de 100 ms. Además, el DOCKER_E2E de qmd pasa entero, porque el cambio está en código horneado.
- **FR-009**: Antes del PR hacen falta dos corridas. Primero, el DOCKER_E2E local de qmd en arm64. Después, una corrida manual del workflow `docker-e2e.yml` sobre la rama, en amd64; el push de la rama y el dispatch llevan cada uno su COMPUERTA. Se registra:
  - el identificador de la corrida;
  - la duración del job y su margen frente a 45 minutos;
  - el `e2e summary:` (49 de 49 esperado);
  - `ok 16 qmd real (041)` ejecutada;
  - si el segundo tick de la prueba 13 reportó contención, y quién tenía el lock.
- **FR-010**: Las cinco primeras nocturnas posteriores al merge registran:
  - el segundo tick de la prueba 13: si hubo contención, quién tenía el lock y cómo se clasifica;
  - la duración del job y su margen frente a 45 minutos;
  - el `e2e summary:`.

  Es una observación, no la demostración: la demostración son FR-007 y FR-008. El registro va en un PR de documentos aparte.
- **FR-011**: El ayudante de 043 (`tests/helper-qmd-e2e.bash`) y sus pruebas no cambian. Siguen como defensa de los e2e ante cualquier otro dueño legítimo del lock.
- **FR-012**: El cambio vive en `scripts/lib/qmd_index.sh`. No toca los privilegios del contenedor, `docker-compose.yml.tpl` ni los bind-mounts (Principio II).
- **FR-013**: El CHANGELOG describe el arreglo y su evidencia, y `VERSION` sube con un bump MINOR: de 0.29.0 a 0.30.0, verificado a mano contra `origin/main` antes de subirlo y después de cualquier rebase.
- **FR-014**: La documentación que hoy explica la contención describe el estado nuevo: el gotcha de 043 en `CLAUDE.md`, que nombra al vigilante del `timeout` como dueño medido, y `docs/qmd-upgrade-checklist.md` si lo menciona. El bloque de la feature en `CLAUDE.md` se escribe a mano, como en 041 a 043.

### Key Entities

- **Sección con lock**: el subshell que abre `.reindex.lock` en el descriptor 9 y lo toma con `flock -n`. Hay dos: la del setup y la del reindex, que incluye la migración de 037.
- **Proceso de la sección**: cada proceso que la sección lanza (las llamadas a qmd, `bun install` y sus descendientes) y que hoy hereda el descriptor 9.
- **Vigilante del `timeout`**: el hijo que deja el `timeout` de BusyBox para vigilar el comando. Vive hasta cerca de 1 s después de que el comando termina.
- **Sondeo del lock**: un `flock -n` sobre el archivo del lock, repetido cada 100 ms, que mide cuánto tarda en quedar libre.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: En un contenedor con BusyBox 1.36.1 y en otro con 1.37.0, tras cada una de las tres secciones reales (setup, reindex y reindex con migración), el lock está libre en el primer sondeo de 100 ms, en 3 de 3 repeticiones por caso. Hoy hacen falta de 9 a 10 sondeos.
- **SC-002**: Las seis pruebas nuevas del lock liberado y de la forma del arreglo caen contra `origin/main` y pasan con el arreglo, en bash 3.2 y en 5.x. Las cuatro que guardan la semántica del lock, el estado y el propio arnés nacen verdes, y el control contra `origin/main` y el catálogo de mutaciones prueban que pueden fallar. Todo el catálogo cae, en los dos bash.
- **SC-003**: La suite del host da la línea base medida más las pruebas nuevas, con 0 `not ok`, en bash 3.2 y en 5.x, y ninguna prueba existente cambia salvo las que el plan justifique por nombre. El DOCKER_E2E de qmd pasa entero.
- **SC-004**: Un comando que se cuelga sigue terminando por su tope, con los mismos códigos de salida que hoy (143 en BusyBox, 124 en GNU). Se mide con el `timeout` real en contenedores con BusyBox 1.36.1 y 1.37.0 y con GNU (`ubuntu:24.04`), con el código actual y con el arreglo. El tope del `bun install`, incluido su valor 0, queda garantizado porque el diff no toca `_qmd_run` ni `_qmd_ensure_prefix`, y una comprobación estructural lo verifica.
- **SC-005**: En las cinco primeras nocturnas posteriores al merge, el segundo tick de la prueba 13 no reporta contención con vigilantes `timeout 900 .../qmd` como dueños; hoy la reporta en 5 de 5 noches. Si aparece otro dueño, el reporte de 043 lo nombra y se clasifica.
- **SC-006**: En las corridas medidas (el DOCKER_E2E local, la corrida manual de CI y las cinco primeras nocturnas), ningún reindex manual de los e2e se salta porque el lock lo retiene un vigilante `timeout ... qmd` de una sección que ya terminó: el reporte de 043 no nombra esos dueños en ninguno de los cuatro sitios. Todo otro salto se clasifica con su dueño. Los saltos del cron y del vigilante de archivos no se miden en estas corridas, y se declaran sin medir: el workspace del e2e es temporal y su `teardown` lo borra (`tests/docker-e2e-qmd.bats:84-111`), y el vigilante de archivos descarta su salida (`scripts/qmd_watch.sh`).

## Assumptions

- La medición del issue #116 representa el comportamiento del `timeout` de BusyBox en las dos versiones que importan: 1.37.0 en producción y 1.36.1 en las pruebas 12 y 13. El plan la repite con las secciones reales del producto, no con el caso mínimo.
- El arreglo propuesto en el issue (cerrar el descriptor del lock en las llamadas de la sección) es un candidato, no una decisión. El plan lo mide frente a alternativas y elige.
- Es un arreglo de producto, así que sigue la práctica de 017, 018, 023, 024, 026 y 042: bump MINOR (0.29.0 a 0.30.0) y CHANGELOG. Es un default declarado, reversible antes del PR.
- El DOCKER_E2E local corre en el Mac del operador (arm64), con COMPUERTA, y reconstruye las imágenes de prueba `agent-admin:qmd-real` y `agent-admin:qmd-embed`. Esas etiquetas se quitaron el 02-11-2026 y el caché de build se conservó.
- Las mediciones en contenedores desechables `--rm` de unos minutos, con imágenes base que ya están en caché, no llevan COMPUERTA y se avisan antes de empezar, como T027 y T031 de 043. Las corridas del DOCKER_E2E sí la llevan.
- El merge es del operador. Por defecto, no se propone antes de que termine la décima noche de T046 de 043 (hacia el 11-11-2026), para que esas diez noches midan solo a 043.
- Los e2e y el ayudante de 043 quedan como están. Si el plan quiere una prueba en contenedor del lock libre, la agrega aparte, sin tocar el ayudante.
- Los agentes desplegados reciben el arreglo con la reconstrucción normal de la imagen tras el upgrade. No hay datos que migrar.

## Out of Scope

- Cambiar la semántica del lock: `flock -n` y saltarse con rc 0 son una decisión de diseño (Principio IV).
- Tocar el ayudante de 043 o sus pruebas (FR-011).
- La segunda carrera de arranque de la prueba 13 (#117).
- Que la migración manual (`heartbeatctl qmd-migrate`, `agentctl heartbeat qmd-migrate`) corra sin el lock. Es otro defecto, sin relación con los descriptores heredados, y se propone para un issue propio, con COMPUERTA.
- El servidor MCP de qmd (`qmd_mcp_exec`), que no corre bajo el lock ni con `timeout`.
- La cobertura arm64 del nightly (feature aparte, diferida desde 042).
