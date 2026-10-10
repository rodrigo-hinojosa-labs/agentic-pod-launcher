# Feature Specification: El nightly de docker-e2e ejecuta la suite de verdad

**Feature Branch**: `039-fix-nightly-e2e-sigpipe`

**Created**: 2026-10-05

**Status**: Draft

**Input**: El job nocturno `docker-e2e` está rojo cinco noches seguidas (01 a 05-10-2026) porque su paso de verificación muere por SIGPIPE a los pocos segundos, antes de ejecutar la suite. En las cinco corridas medidas el nightly no corrió ningún e2e, y los rojos reales que esa muerte esconde (E1 y E3 de 031, y los que nadie ha medido) siguen sin tratarse. El objetivo es que una noche en rojo o en verde signifique algo.

## Contexto

El repositorio tiene tres workflows de GitHub Actions: `shellcheck` y `tests` (ambos verdes desde 025) y `docker-e2e (nightly)`, que corre por `schedule` (05:00 UTC) y por `workflow_dispatch` en `ubuntu-latest`, con un tope de 30 minutos por job. Su trabajo es ejecutar con `DOCKER_E2E=1` todos los `tests/docker-e2e-*.bats`: hoy **48 tests en 13 archivos** (conteo del 05-10-2026). Es la única red automática que cubre lo que la suite del host, por diseño, no puede ver: el contenedor real, el arranque, el parcheador de plugins, el supervisor.

**Medido el 05-10-2026 con `gh run` y los logs de Actions.** Cinco corridas nocturnas seguidas terminan en rojo: 36855651113 (01-10, sobre `70214d9`), 36998460203 (02-10, `70214d9`), 37116000464 (03-10, `6a6ce54`), 37197340169 (04-10, `6a6ce54`) y 37307700006 (05-10, `da22a06`). Las cinco acaban con `Process completed with exit code 141` y el job dura entre 4 y 11 s. La feature 025 (spec del 26-07-2026) ya registraba el nightly rojo por `exit 141` y lo dejó fuera de alcance de forma explícita (FR-010), como seguimiento aparte y con la causa solo sospechada: esta es esa feature, y confirma la causa.

**Causa, con el log del run 37197340169.** El paso `Verify deps + docker` corre con `set -euo pipefail` y termina en `docker info | head -10`. El log muestra exactamente las 10 primeras líneas de `docker info` y, 2 ms después, `##[error]Process completed with exit code 141`. El consumidor (`head`) cierra el pipe tras 10 líneas; el productor (`docker info`) sigue escribiendo, recibe SIGPIPE (128 + 13 = 141) y `pipefail` entrega ese código al paso. No es una carrera: `docker info` escribe decenas de líneas, así que falla siempre. El job muere ahí, antes del paso `Run docker-e2e suite`. Es la misma clase de defecto que la regla de `CLAUDE.md` sobre `PRODUCER | grep -q` bajo `pipefail`.

**Consecuencia, la que importa.** En las cinco corridas medidas el nightly no ejecutó ni un solo e2e, y 025 ya lo daba rojo por el mismo código el 26-07-2026: es probable que lleve meses sin ejecutarlos, pero la fecha de inicio no está medida. La constitución del repositorio exige que el e2e pase para los cambios en `docker/` o en el arranque, pero la red que debía vigilarlo de forma continua no existe: los e2e de 031 a 038 solo corren si alguien los lanza a mano en un host con Docker. Eso escondió al menos dos rojos ya medidos: E1 y E3 de `tests/docker-e2e-askq-guard.bats` (031) fallan también sobre la base sin 038, porque E1 llama al instalador con `--entrypoint sh` antes de que exista `~/.claude` y E3 busca un plugin de Telegram que la imagen no trae. Nunca corrieron en una máquina con Docker. Puede haber más detrás: nadie sabe cuántos de los 48 están realmente verdes, y hasta donde consta en el repo solo se han corrido en arm64 (el Mac del operador, Apple Silicon), mientras el runner es amd64.

## Clarifications

### Session 2026-10-05

- Q: Cuando el nightly por fin ejecute la suite, ¿qué se hace con los e2e que fallen? → A: Corregir lo ya diagnosticado (E1 y E3 de 031, defectos de arnés de causa medida) y aislar el resto con salto explícito, motivo escrito y seguimiento. Cada rojo nuevo se clasifica, y se corrige si es de arnés y su arreglo es acotado.
- Q: Si la suite completa no cabe en los 30 minutos del job, ¿cuál es el primer remedio? → A: Subir el tope del job y volver a medir; dividir la suite en jobs paralelos solo con evidencia de que subir el tope no basta (el repo es público, los minutos no se facturan).

### Session 2026-10-06 (resultado de `/speckit-analyze`)

- Q: ¿Cómo se resuelven las dos líneas `| head -1` de `test.yml` frente al Out of Scope? → A: Se enmienda el Out of Scope con la excepción y se mantiene la tarea que las edita; el ratchet queda sin lista de excepciones.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - El nightly llega a ejecutar la suite (Priority: P1)

Como mantenedor del launcher, quiero que el job nocturno supere su verificación previa y ejecute los e2e, para que su resultado, verde o rojo, describa el estado real del producto en vez de un artefacto de diagnóstico.

**Why this priority**: Es el valor central. Hoy el semáforo nocturno está en rojo por una causa que no tiene nada que ver con el producto, así que no informa: el mismo rojo saldría con el código perfecto o con el código roto. Mientras no se arregle, todo lo demás (clasificar rojos, auditar) es imposible porque la suite ni siquiera arranca.

**Independent Test**: Lanzar el workflow a mano (`workflow_dispatch`) sobre la rama de la feature y leer el log: el paso de verificación termina en verde mostrando las versiones de Docker y Compose, el paso de la suite arranca y la conclusión del job sale de los resultados de los tests.

**Acceptance Scenarios**:

1. **Given** un runner con Docker sano, **When** corre el paso de verificación, **Then** termina con éxito y deja en el log las versiones de Docker y de Compose y, del motor, la versión del servidor y la arquitectura, sin importar cuántas líneas imprima cada herramienta.
2. **Given** que el paso de verificación terminó con éxito, **When** el job continúa, **Then** el paso de la suite arranca en el mismo run y ejecuta todos los `tests/docker-e2e-*.bats` con `DOCKER_E2E=1`.
3. **Given** que la suite terminó, **When** el job concluye, **Then** su conclusión depende solo de los resultados de los tests y de fallos ambientales reales (tiempo, red, Docker), nunca de un paso de diagnóstico.
4. **Given** un runner donde Docker está ausente o caído, **When** corre el paso de verificación, **Then** el job se detiene ahí con un mensaje comprensible: un fallo ambiental real sigue siendo ruidoso.

---

### User Story 2 - La regresión no puede volver sin que la suite del host la note (Priority: P1)

Como mantenedor, quiero un oráculo en la suite del host (`bats tests/`, sin Docker ni red) que reproduzca este defecto, para que reintroducirlo, en este paso o en cualquier otro workflow, ponga rojo el semáforo antes de llegar a `main` y no cinco noches después.

**Why this priority**: Sin oráculo, el arreglo de una línea es frágil: el patrón es natural de escribir (`| head`) y ya costó semanas de nightly ciego. Es P1 porque es lo que convierte el arreglo en permanente, y porque el repo ya aprendió que un chequeo que no puede fallar no es evidencia.

**Independent Test**: Revertir el arreglo en una copia y comprobar que el oráculo falla; restaurarlo y comprobar que pasa; repetirlo bajo bash 3.2 y bash 5.x.

**Acceptance Scenarios**:

1. **Given** el workflow con el defecto presente, **When** corre `bats tests/`, **Then** el oráculo falla y nombra el paso culpable.
2. **Given** el workflow arreglado, **When** corre `bats tests/`, **Then** el oráculo pasa.
3. **Given** que el oráculo no logra localizar el paso en el workflow o no puede ejecutarlo, **When** corre, **Then** falla en lugar de pasar en vacío.
4. **Given** los otros workflows, **When** se audita cada paso `run:` por el mismo patrón, **Then** cada hallazgo queda corregido o justificado por escrito como seguro.

---

### User Story 3 - Los rojos reales dejan de estar escondidos (Priority: P2)

Como mantenedor, quiero que cada e2e que falle al ejecutarse por primera vez en CI quede clasificado y con una disposición escrita, para que el nightly pase a ser una señal confiable en vez de otra fuente de ruido.

**Why this priority**: Arreglar el pipe va a destapar fallos que pueden llevar semanas o meses escondidos (dos ya medidos, y la diferencia amd64 contra arm64 sin medir). Si se destapan y se dejan sin tratar, el nightly pasa de "ciego" a "rojo permanente por otra razón", que es igual de inútil. Es P2 porque depende de US1: no hay rojos que clasificar hasta que la suite corra.

**Independent Test**: Tras la primera corrida real de la suite, existe una tabla con los 48 tests y su estado; cada rojo tiene causa, clasificación, evidencia del log y disposición.

**Acceptance Scenarios**:

1. **Given** la primera corrida real de la suite, **When** algunos e2e fallan, **Then** cada fallo queda clasificado como defecto de arnés, defecto de producto o diferencia de entorno, con el fragmento del log que lo prueba.
2. **Given** un defecto de arnés, **When** se trata, **Then** se corrige si su causa ya está diagnosticada (E1 y E3 de 031) o si el arreglo queda acotado al propio test o a su arnés y se verifica con una corrida real; en cualquier otro caso se aísla con un salto explícito que lleva motivo escrito, es visible en la salida del run y tiene un seguimiento registrado.
3. **Given** un defecto de producto, **When** se descubre, **Then** se registra y se decide aparte: no se esconde con un salto ni se corrige en silencio dentro de esta feature.
4. **Given** una diferencia de entorno (por ejemplo, arquitectura del runner o credenciales ausentes), **When** se trata, **Then** queda documentada y su salto, si existe, está condicionado al entorno y es visible.
5. **Given** una corrida en la que ningún e2e llega a ejecutarse (todos saltados, lista vacía o variable de entorno no propagada), **When** el job concluye, **Then** termina en rojo: un verde vacío no es un verde.
6. **Given** que la suite agota el tiempo del job, **When** se trata, **Then** se sube el tope y se mide de nuevo hasta que una corrida termine; dividirla en jobs paralelos solo si subir el tope no basta.

---

### Edge Cases

- **El arreglo no debe depender del volumen de salida.** Hoy falla porque `docker info` escribe mucho; mañana otra herramienta podría hacerlo con otro volumen. El requisito es que ningún paso de diagnóstico pueda abortar el job por cerrar un pipe antes de tiempo, no que se cambie el número de líneas.
- **Docker ausente o caído**: el paso de verificación debe seguir fallando de forma clara; quitarle el `set -e` a todo el paso para "arreglar" el 141 silenciaría un fallo real.
- **La suite quizá no cabe en 30 minutos** con un runner frío (48 tests, construcción de imagen desde cero). Un tiempo agotado es un rojo real y distinto; se mide en la primera corrida y el primer remedio es subir el tope del job y volver a medir (clarificado el 05-10-2026).
- **Los e2e solo constan corridos en arm64**; el runner es amd64. Binarios nativos (por ejemplo `sqlite-vec` compilado para musl, `bun`) pueden comportarse distinto: es una fuente probable de rojos reales y se clasifican según la evidencia, sin presumir causa.
- **Tests que se saltan solos sin `DOCKER_E2E`**: si la variable no llega al proceso de la suite, los 48 se saltan y el job pasaría en vacío. Debe detectarse.
- **Intermitencias**: un e2e que falla a ratos (037 midió una carrera de ~1 en 7 sobre `.reindex.lock`) no se etiqueta "flake" sin medirlo con repeticiones; se registra la tasa medida.
- **Credenciales**: un e2e que necesite secretos que el runner no tiene se aísla con un salto condicionado al entorno y visible; esta feature no agrega secretos ni permisos nuevos al workflow.
- **Corridas concurrentes** (nocturna y manual): el grupo de concurrencia existente ya las serializa sin cancelar; no se toca.
- **Empujar cambios a `.github/workflows/`** exige que el token de `gh` tenga el permiso `workflow`: es un requisito operativo, no de producto, y se verifica con el operador antes de empujar.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: El paso de verificación del nightly MUST completarse con éxito en un runner con Docker sano, sea cual sea la cantidad de líneas que impriman las herramientas de diagnóstico.
- **FR-002**: Ese paso MUST seguir mostrando en el log del run las versiones de Docker y de Compose y, del motor, al menos la versión del servidor y la arquitectura.
- **FR-003**: Un fallo ambiental real (Docker ausente o caído) MUST seguir deteniendo el job en ese paso con un mensaje comprensible.
- **FR-004**: Superado el paso de verificación, el job MUST ejecutar, en el mismo run, todos los archivos `tests/docker-e2e-*.bats` con `DOCKER_E2E=1`.
- **FR-005**: La conclusión del job MUST derivar solo de los resultados de los tests y de fallos ambientales reales, nunca de un paso de diagnóstico.
- **FR-006**: Una corrida en la que ningún e2e llegue a ejecutarse (todos saltados, lista vacía, variable no propagada) MUST terminar en rojo.
- **FR-007**: La suite del host (`bats tests/`, sin Docker ni red) MUST incluir un oráculo que falle si el paso de verificación del workflow aborta cuando las herramientas de diagnóstico producen salida extensa. El método (ejecutar el paso real con un `docker` sustituto o auditar los `run:` de forma estática) lo decide y justifica el plan.
- **FR-008**: El oráculo MUST demostrarse rojo contra el paso con el defecto y verde tras el arreglo, MUST volver a ponerse rojo si se reintroduce el patrón, y MUST NOT poder pasar en vacío: si no localiza el paso en el workflow o no logra ejecutarlo, falla.
- **FR-009**: El oráculo MUST pasar bajo bash 3.2 y bash 5.x, el gate dual del repositorio.
- **FR-010**: Todos los pasos `run:` de los workflows, y los scripts que invocan directamente, MUST auditarse por el mismo patrón (un consumidor que cierra el pipe antes de que el productor termine, bajo `pipefail`), y cada hallazgo MUST tener una disposición escrita: corregido, o justificado como seguro con su razón.
- **FR-011**: Cada e2e que falle en la primera corrida real MUST clasificarse, uno por uno, como defecto de arnés, defecto de producto o diferencia de entorno, con el fragmento de log que lo prueba.
- **FR-012**: Un defecto de arnés MUST corregirse si su causa ya está diagnosticada (E1 y E3 de 031) o si su arreglo queda acotado al propio test o a su arnés, sin tocar producción, y se verifica con una corrida real; en cualquier otro caso MUST aislarse con un salto explícito: motivo escrito, visible en la salida del run y con seguimiento registrado (política fijada en clarify el 05-10-2026).
- **FR-013**: Un defecto de producto MUST registrarse y decidirse aparte; no se esconde con un salto ni se corrige en silencio dentro de esta feature.
- **FR-014**: Debe existir evidencia de al menos un run real de `workflow_dispatch` sobre la rama de la feature, con su identificador, que muestre el paso de la suite arrancado y su resultado por test.
- **FR-015**: Esta feature MUST NOT modificar código de producción (`docker/`, `scripts/`, `modules/`), ni la semántica de los e2e más allá de lo que exige FR-012, ni agregar secretos o permisos al workflow (hoy `contents: read`).
- **FR-016**: Si en la primera corrida real la suite agota el tiempo del job, el primer remedio MUST ser subir el tope del job y volver a medir; dividir la suite en jobs paralelos solo con evidencia de que subir el tope no basta.

### Key Entities

- **Corrida nocturna**: una ejecución del workflow, programada o manual, con su identificador, el commit sobre el que corre, la conclusión y, desde esta feature, el detalle de qué e2e se ejecutaron, cuáles se saltaron (con motivo) y cuáles fallaron.
- **Rojo clasificado**: un e2e que falló, con su causa, su tipo (defecto de arnés, defecto de producto o diferencia de entorno), la evidencia del log, y su disposición (corregido, aislado con salto y seguimiento, o escalado como defecto de producto).

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: En un `workflow_dispatch` real sobre la rama de la feature, el paso de verificación termina en verde y el paso de la suite arranca: el job deja de terminar en el paso de verificación: el paso de la suite arranca y el job supera los 15 s, que es lo que duran hoy las cinco corridas rojas (entre 4 y 11 s). Verificado en al menos 1 corrida, con su identificador registrado.
- **SC-002**: Las 3 corridas nocturnas siguientes al merge no abortan en el paso de verificación (0 de 3).
- **SC-003**: El oráculo de regresión pasa de rojo (contra el paso con el defecto) a verde (tras el arreglo) y vuelve a rojo al reintroducir el patrón, en bash 3.2 y en bash 5.x.
- **SC-004**: Tras la primera corrida real, el 100% de los e2e (hoy 48 en 13 archivos) está contabilizado: verde, rojo con clasificación y evidencia, o saltado con motivo visible; cero casos de "no se sabe qué pasó".
- **SC-005**: El 100% de los pasos `run:` de los tres workflows tiene disposición escrita. La búsqueda preliminar del 05-10-2026 encontró 4 candidatos `| head` (2 en `docker-e2e.yml`, 2 en `test.yml`); solo uno ha fallado en la práctica.
- **SC-006**: El log de una corrida permite distinguir, sin reproducir nada en local, cuántos e2e corrieron, cuántos se saltaron (con su motivo) y cuáles fallaron.
- **SC-007**: Una corrida simulada en la que ningún e2e se ejecuta termina en rojo.
- **SC-008**: El diff de la feature no toca `docker/`, `scripts/` ni `modules/`, y el workflow conserva sus permisos (`contents: read`) y no incorpora secretos nuevos.
- **SC-009**: La primera corrida real de la suite completa termina dentro del tope vigente del job (ajustado si hizo falta), sin tiempo agotado.

## Assumptions

- Se mantiene el runner `ubuntu-latest` (amd64) con Docker y Compose preinstalados, tal como muestran los logs (Docker 28.0.4, Compose v2.38.2 el 05-10-2026). No se cambia de runner.
- El repositorio es público (`gh repo view`, 05-10-2026), así que los minutos de Actions en runners estándar no se facturan: que el nightly pase de gastar ~10 s a ejecutar la suite completa no es un factor de decisión.
- Hasta donde consta en el repositorio, los e2e solo se han corrido en arm64. Que algunos fallen en amd64 es esperable y no se presume causa antes de medirla.
- El conteo de 48 tests en 13 archivos es del 05-10-2026 y puede variar; los criterios se expresan sobre "todos los e2e", no sobre ese número.
- El `workflow_dispatch` ejecuta el archivo de workflow de la rama elegida, de modo que la evidencia de FR-014 se obtiene antes del merge.
- Decidido en clarify el 05-10-2026: ante los rojos reales se corrige lo ya diagnosticado (E1 y E3 de 031) y se aísla el resto con seguimiento; y si la suite no cabe en el tope del job, el primer remedio es subirlo y volver a medir. El spec sigue sin prometer "nightly verde": promete que ningún rojo queda sin clasificar ni escondido.
- Es una feature de CI y de tests, sin cambio de runtime. El precedente (019 y 025) es no subir `VERSION` y dejar una entrada en `CHANGELOG.md`; el plan lo confirma contra `origin/main` a mano.
- Empujar a `.github/workflows/` exige el permiso `workflow` en el token de `gh`; en 025 hubo que autorizarlo por device-flow. Se verifica con el operador antes de empujar. El push va por HTTPS con el helper de `gh`, porque SSH falla por cuenta equivocada.

## Out of Scope

- Cambiar la semántica de los e2e existentes, salvo lo estrictamente necesario para que dejen de fallar por defectos de arnés.
- Tocar código de producción (`docker/`, `scripts/`, `modules/`). Si un e2e revela un defecto real del producto, se registra y se decide aparte.
- Rediseñar la matriz de `test.yml` (025) ni los jobs `tests` y `shellcheck`, que están verdes. La única excepción son las dos líneas `| head -1` de diagnóstico del paso `Verify deps + pin the bash target` de `test.yml`, que el ratchet de FR-010 (sin lista de excepciones) obliga a resolver: es un cambio de dos líneas, no un rediseño (decidido el 06-10-2026).
- Notificaciones o alertas de un nightly rojo.
- G0, G1 y el rollout de 038 (en curso por el operador) y la actualización pendiente de la flota.
