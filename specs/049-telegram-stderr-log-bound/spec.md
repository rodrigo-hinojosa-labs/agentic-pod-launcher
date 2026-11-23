# Feature Specification: Log de stderr del canal de Telegram acotado y sin bucle de EPIPE

**Feature Branch**: `049-telegram-stderr-log-bound`

**Created**: 2026-11-23

**Status**: Draft

**Input**: Issue #139 y decisión del operador (23-11-2026) de tomarlo como la feature siguiente a 048. El log de stderr del canal de Telegram (`/workspace/scripts/heartbeat/logs/telegram-mcp-stderr.log`) no tiene rotación ni tope, y un bucle de EPIPE lo infló a 26,7 GB en donna. La feature debe acotar su tamaño, cortar el bucle y, como opción, hacer que `agentctl doctor` avise cuando el log crezca de más. Sin cambiar lo que se registra ni los otros grupos de parches del plugin.

## Contexto

**Qué es el log.** El plugin de Telegram viene del vendor y se instala después del login. En cada arranque, el launcher le aplica parches desde la imagen (`docker/scripts/apply_telegram_typing_patch.py`). Uno de esos grupos, la captura de stderr (marcador `stderr-capture patch v1`), copia al log cada escritura del plugin a su stderr y registra ahí las excepciones no capturadas y las promesas rechazadas. Es la evidencia forense del canal: `agentctl logs --stderr` lo muestra, y los hooks de guardia de respuesta (028) y de AskUserQuestion (031) anexan sus propias líneas al mismo archivo.

**Lo medido el 22-11-2026 en ferrari.**

- **donna**: 26,7 GB, 434.907.306 líneas, de las cuales 144.968.645 contienen `EPIPE`. Las últimas 300.000 líneas son casi enteras el mismo bloque repetido: `telegram channel: uncaught exception: Error: EPIPE: broken pipe, write` y tres líneas de stack.
- El archivo ya pesaba lo mismo el 21-11 y no creció después del reinicio del 22-11. La última marca de tiempo es del 30-09-2026 04:48Z, así que el bucle se detuvo solo o con un reinicio.
- **linus**: 5,7 MB. **cbum**: 276 KB.
- Cada copia del workspace arrastró los 25 GB, porque los respaldos de upgrade excluyen solo `.state/`.
- Se vació a mano con `truncate -s 0`, sin reiniciar. Eso es seguro porque el parche abre el archivo, anexa y lo cierra en cada escritura.

**El mecanismo, leído del código y sin reproducir.**

1. El parche reemplaza la escritura a stderr del plugin. Primero anexa el texto al log, después llama a la escritura original.
2. Si el stderr original es un pipe cuyo lector ya cerró, la escritura original falla con EPIPE.
3. El manejador de excepciones del plugin informa ese error escribiendo otra vez a stderr. Eso vuelve a anexar al log y vuelve a fallar.
4. Cada vuelta deja cuatro líneas en el log, y nada corta el ciclo.

Inferido, sin medir: el disparador es un proceso del canal que siguió vivo después de que la sesión que lo lanzó cerró su extremo del pipe.

**Qué cambia.** El log pasa a tener un tamaño máximo en disco, y la captura deja de reenviar a un stderr que ya está cerrado. Todo lo que hoy entra al log sigue entrando con el mismo texto, mientras haya espacio dentro del tope.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - El log del canal nunca supera un tope de disco (Priority: P1)

El operador deja un agente corriendo semanas o meses. Pase lo que pase en el canal, el log de stderr y sus generaciones anteriores ocupan en total menos de un tope fijo, y la parte más reciente del registro siempre está disponible para diagnosticar.

**Why this priority**: es el daño medido. Un log sin tope llena el disco del host, se copia en cada respaldo de upgrade y hace inmanejable la lectura forense. Si solo se arregla esto, el bucle puede volver, pero el disco queda a salvo.

**Independent Test**: con un plugin parcheado, escribir al stderr mucho más que el tope en total y comprobar que la suma del log y sus generaciones nunca lo excede, que las líneas más recientes están en el archivo actual y que el proceso sigue vivo.

**Acceptance Scenarios**:

1. **Given** un log que llega al umbral de rotación, **When** llega la siguiente escritura, **Then** el contenido actual pasa a ser la generación anterior más reciente, el archivo actual empieza vacío con esa escritura, y la generación más vieja que exceda el máximo se descarta.
2. **Given** un agente que arranca con un log heredado de dos umbrales o más (el caso de donna antes del 22-11), **When** ocurre la primera escritura después del upgrade, **Then** ese archivo no se conserva entero: de él queda a lo sumo el tramo final, de un umbral de tamaño. Un heredado de entre uno y dos umbrales rota entero, como cualquier archivo que acaba de pasar el umbral.
3. **Given** el log y sus generaciones, **When** termina cualquier secuencia de escrituras, **Then** el espacio total en disco no supera el tope declarado en FR-003.
4. **Given** un hook de guardia (028 o 031) que anexa una línea mientras el plugin rota, **When** se completa la rotación, **Then** la línea del hook queda en alguna de las generaciones y ninguna escritura hace fallar al hook ni al plugin.
5. **Given** una falla al rotar, por ejemplo un directorio de logs sin permiso de escritura, **When** el plugin escribe, **Then** la escritura original a stderr ocurre igual y el plugin no cae.

---

### User Story 2 - Un stderr cerrado no genera un bucle (Priority: P1)

Cuando el destino original de stderr del plugin se cierra, el plugin deja de reenviarle texto. Sigue registrando en el archivo y deja una sola línea que dice por qué dejó de reenviar.

**Why this priority**: es la causa. El tope de US1 contiene el daño; esto evita que el canal gaste CPU y escrituras en un ciclo infinito, y que el log de forense quede lleno de ruido en vez de lo que pasó antes del ciclo.

**Independent Test**: lanzar el plugin parcheado con su stderr conectado a un pipe cuyo lector se cierra, forzar una escritura a stderr y comprobar que el log tiene una línea de aviso, ninguna repetición de la excepción de EPIPE y que el proceso sigue vivo atendiendo.

**Acceptance Scenarios**:

1. **Given** un stderr original cerrado, **When** el plugin escribe a stderr, **Then** el texto queda en el log, la escritura no lanza error y el log gana una sola línea de aviso que nombra el código de error.
2. **Given** que la captura ya dejó de reenviar, **When** el plugin vuelve a escribir a stderr miles de veces, **Then** cada texto queda en el log una vez, no aparece ninguna línea nueva de EPIPE ni de aviso, y no hay más intentos contra el destino cerrado.
3. **Given** un stderr original sano, **When** el plugin escribe, **Then** el comportamiento es byte por byte el de hoy: el texto llega al log y a stderr, y el log no gana líneas nuevas.
4. **Given** un error de escritura a stderr que no indica un destino cerrado, **When** ocurre, **Then** la captura no deja de reenviar por él (solo los errores de destino cerrado cortan el reenvío).

---

### User Story 3 - El upgrade llega solo a los agentes ya parcheados (Priority: P2)

Un agente ya desplegado tiene el plugin parcheado con la captura v1. Al arrancar con la imagen nueva, la cascada de parches lo sube a la versión nueva sin intervención del operador. Si el archivo del plugin cambió de forma que el parche no reconoce, lo deja como estaba y lo avisa.

**Why this priority**: sin esto el arreglo solo llega a plugins recién instalados, y linus, donna y cbum ya tienen la v1.

**Independent Test**: aplicar el patcher nuevo sobre un plugin con la v1, sobre uno sin parchear y sobre uno con la versión nueva, y comprobar el resultado en cada caso; aplicarlo otra vez y comprobar que no cambia nada.

**Acceptance Scenarios**:

1. **Given** un plugin con la captura v1, **When** corre el patcher del arranque, **Then** queda con la versión nueva y sin rastro de la v1, y los demás grupos de parches quedan byte por byte iguales.
2. **Given** un plugin sin parchear, **When** corre el patcher, **Then** el resultado es idéntico al de subir desde la v1.
3. **Given** un plugin ya en la versión nueva, **When** corre el patcher otra vez, **Then** el archivo no cambia y el patcher lo informa como hoy.
4. **Given** un plugin cuyo bloque v1 fue editado a mano, **When** corre el patcher, **Then** no modifica ese grupo, escribe un WARN que lo nombra y el resto de los grupos se aplica igual.

---

### User Story 4 - El doctor avisa cuando el log crece de más (Priority: P3)

`agentctl doctor` informa el tamaño del log de stderr del canal y avisa cuando pasa un umbral que solo se alcanza si el tope no está funcionando, por ejemplo con una imagen vieja o un parche que no se aplicó.

**Why this priority**: con US1 y US2 el log no debería crecer. Este aviso detecta que el arreglo no llegó a un agente; no es necesario para que el arreglo funcione.

**Independent Test**: correr el doctor con un log chico y con uno sobre el umbral, y comprobar que con el chico no hay aviso y con el grande hay un WARN con el tamaño y la acción sugerida.

**Acceptance Scenarios**:

1. **Given** un log bajo el umbral, **When** corre el doctor, **Then** muestra una línea informativa con el tamaño, sin WARN.
2. **Given** un log sobre el umbral, **When** corre el doctor, **Then** muestra un WARN con el tamaño y la acción sugerida (actualizar la imagen y vaciar el log), sin imprimir contenido del log.
3. **Given** un agente sin log, porque el canal todavía no arrancó, **When** corre el doctor, **Then** no avisa.
4. **Given** un agente en modo local, que no tiene canal de Telegram, **When** corre el doctor, **Then** no aparece la línea.

---

### Edge Cases

- **Disco lleno o directorio sin permiso**: si no se puede anexar al log ni rotar, la escritura original a stderr sigue ocurriendo y el plugin no cae. Es el comportamiento fail-silent de hoy.
- **Escritura más grande que el umbral**: una sola escritura de más de un umbral de tamaño se registra completa en el archivo actual. El total puede pasar el tope en esa escritura, pero la siguiente rotación lo devuelve al tope.
- **Dos procesos del canal a la vez**: puede ocurrir mientras el lock de primario/secundario resuelve cuál sigue, y los dos pueden rotar. Ninguna línea debe quedar corrupta y ninguno de los dos debe caer. Dos rotaciones casi simultáneas pueden descartar una generación antes de tiempo: el historial retenido se acorta durante ese traslape, pero nunca supera el tope. Medido en H10 de `contracts/stderr-hook-v2.md` (23-11-2026): con U = 20.000, dos procesos de 5.000 escrituras cada uno dejan 32.688 bytes y cero líneas malformadas.
- **Hooks de shell escribiendo durante una rotación**: anexan a la ruta. Si la línea cae en el archivo que se está renombrando, termina en la generación anterior; no se pierde ni falla el hook.
- **El stderr se cierra mientras se reporta una excepción**: el aviso del corte se registra una sola vez aunque el primer EPIPE llegue desde el manejador de excepciones.
- **Upgrade sin reinicio**: la versión nueva aplica cuando el proceso del canal se reinicia, igual que los otros parches.
- **Rollback a una imagen anterior** (corregido por la revisión independiente, 23-11-2026): el patcher viejo busca solo el marcador v1. Sobre un archivo v2 **apila** un bloque v1 encima, porque el ancla `const TOKEN =` sigue ahí. Mientras el agente queda en la imagen vieja, las dos capturas conviven: el log no tiene tope, cada línea se registra dos veces y el doctor de US4 lo avisa. Al volver a la imagen nueva, la cascada quita el v1 apilado y el archivo queda idéntico a una instalación fresca (S10). Sin esa rama, lo habría convertido en un segundo v2 y cada línea quedaría duplicada para siempre.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: La captura de stderr DEBE rotar el log cuando el archivo actual alcanza el umbral de rotación, que por defecto es de 10 MiB (10.485.760 bytes), igual que `runs.jsonl`.
- **FR-002**: La captura DEBE conservar a lo sumo dos generaciones anteriores. Al rotar, la generación más vieja que exceda ese número se descarta.
- **FR-003**: El espacio total del log y sus generaciones DEBE quedar por debajo de tres veces el umbral más, a lo sumo, una escritura por archivo: unos 30 MiB con el umbral por defecto (medido en el plan: 286.728 bytes con un umbral de 100.000 y escrituras de 48 bytes, research M4).
- **FR-004**: Un archivo heredado de dos umbrales o más NO DEBE conservarse entero al rotar. De él se conserva a lo sumo el tramo final, de un umbral de tamaño. Uno de entre uno y dos umbrales rota entero.
- **FR-005**: El umbral DEBE poder ajustarse con una variable de entorno del workspace, en la línea de `TELEGRAM_TYPING_MAX_MS`. Un valor ausente o inválido usa el valor por defecto, nunca cero ni un número negativo.
- **FR-006**: Si la escritura original a stderr falla con un error que indica un destino cerrado (EPIPE o equivalente), la captura DEBE dejar de reenviar a stderr por el resto de la vida del proceso y seguir registrando en el log.
- **FR-007**: Al cortar el reenvío, la captura DEBE escribir en el log una sola línea de aviso, con marca de tiempo y el código de error. NO DEBE escribirla de nuevo en la vida del proceso.
- **FR-008**: Una escritura a stderr NO DEBE lanzar un error al plugin por un destino cerrado, ni antes ni después del corte.
- **FR-009**: Con un stderr sano, el texto que llega al log y a stderr DEBE ser byte por byte el de hoy. La rotación no agrega líneas al log.
- **FR-010**: Una falla al anexar o al rotar NO DEBE impedir la escritura original a stderr ni hacer caer el plugin.
- **FR-011**: El patcher del arranque DEBE subir un plugin con la captura v1 a la versión nueva y aplicar la versión nueva a un plugin sin parchear. El resultado de ambos caminos DEBE ser idéntico.
- **FR-012**: El patcher DEBE ser idempotente. Sobre un plugin ya en la versión nueva no cambia nada, y sobre una v1 editada fuera de lo esperado deja ese grupo intacto, avisa con WARN y aplica el resto de los grupos.
- **FR-013**: Los demás grupos de parches (typing, offset, primary, voice, pending-reply, askq give-up) DEBEN quedar byte por byte iguales con y sin esta feature.
- **FR-014**: La ruta del log y su formato DEBEN seguir iguales, para que `agentctl logs --stderr` y los hooks de guardia (028 y 031) sigan funcionando sin cambios.
- **FR-015**: `agentctl doctor`, en modo docker, DEBE mostrar el tamaño del log de stderr del canal y avisar con WARN cuando el archivo actual supere un umbral de alarma fijo de 100 MiB (104.857.600 bytes), sin leer ni imprimir su contenido.
- **FR-016**: El cambio DEBE entrar a la imagen y probarse en un contenedor real (DOCKER_E2E), porque el patcher está horneado en la imagen.

### Key Entities

- **Log de stderr del canal**: archivo actual en la ruta de hoy. Lo escriben el plugin parcheado y los hooks de guardia.
- **Generación anterior**: copia del log rotada en un momento previo, con un nombre derivado de la ruta del log. Hay a lo sumo dos.
- **Umbral de rotación**: tamaño a partir del cual se rota. Vale 10 MiB por defecto y se ajusta por variable de entorno.
- **Estado de reenvío**: por proceso, activo o cortado. Una vez cortado, no vuelve a activarse en la vida del proceso.
- **Línea de aviso de corte**: una por proceso, con marca de tiempo y el código de error.
- **Versión del grupo de captura**: v1, la de hoy, y la nueva. La cascada del patcher sube de una a la otra.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Con cualquier umbral U, después de escribir al stderr del plugin más de diez veces el tope total, el log y sus generaciones ocupan como máximo 3U más una escritura por archivo (con el umbral por defecto, unos 30 MiB). Se mide con un umbral chico, porque la cota es proporcional al umbral (H4).
- **SC-002**: Con el stderr original cerrado, el plugin parcheado escribe una sola línea de aviso de corte, y la cantidad de líneas de EPIPE en el log no crece después de ella. Sin el arreglo, la misma prueba muestra el crecimiento sostenido de hoy, como ROJO antes del VERDE.
- **SC-003**: Con el stderr original cerrado, el proceso del canal sigue vivo y su event loop sigue ejecutando timers y tareas durante la prueba, sin reinicios. Es la condición que el bucle rompe (research M2); la atención de mensajes reales se verifica en el despliegue (T027).
- **SC-004**: En operación normal, con un stderr sano y bajo el umbral, el contenido del log es idéntico al que produce la versión actual con las mismas escrituras.
- **SC-005**: En los tres agentes docker (linus, donna y cbum), después de desplegar, el plugin queda en la versión nueva tras el primer arranque, sin pasos manuales, y el doctor no muestra el WARN de tamaño.
- **SC-006**: El patcher aplicado dos veces seguidas sobre cada estado de partida (sin parchear, v1, versión nueva) deja el mismo archivo que aplicado una vez.
- **SC-007**: La suite del host pasa en bash 3.2 y 5.x sin fallas nuevas, y el DOCKER_E2E de la feature pasa en un contenedor real.

## Assumptions

- El manejador de excepciones del plugin del vendor informa los errores escribiendo a stderr. Lo indican las líneas `telegram channel: uncaught exception:` del log de donna; el fixture prístino del repo no lo contiene, así que la prueba del bucle tiene que reproducir esa forma.
- El disparador es un stderr cerrado por el proceso que lanzó el canal. Es inferido, no medido; la feature corta el bucle para cualquier destino cerrado, sin depender de cuál sea la causa.
- 10 MiB por umbral y dos generaciones anteriores alcanzan para el diagnóstico. linus, el agente con más uso, llegó a 5,7 MB en meses sin bucle.
- El umbral de alarma del doctor, 100 MiB, solo se alcanza si la rotación no funciona: es diez veces el umbral de rotación y más de tres veces el tope total.
- La rotación la hace el plugin al escribir, no un proceso aparte, para no sumar un cron ni un servicio nuevo.
- Los hooks de guardia siguen anexando a la ruta del log con su método de hoy. No se cambian.
- El modo local no tiene canal de Telegram ni este log; la feature no lo toca.
- Vaciar el log heredado de linus y cbum no es necesario: la primera rotación lo acota (FR-004). El de donna ya se vació el 22-11-2026.
- El bump de versión sigue la práctica del proyecto (MINOR por un cambio de comportamiento en código horneado), con CHANGELOG.

## Out of Scope

- Cambiar qué se registra o su formato.
- Rotar otros logs del workspace (`claude.log`, `runs.jsonl`, que ya rota, o los logs de qmd).
- Diagnosticar o eliminar la causa por la cual el stderr se cierra. La feature lo tolera sin bucle.
- Cambiar los hooks de guardia 028 y 031.
- Enviar avisos por Telegram o GitHub por el tamaño del log.
