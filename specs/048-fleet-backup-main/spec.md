# Feature Specification: Respaldos en main y cierre de los pendientes de la flota

**Feature Branch**: `048-fleet-backup-main`

**Created**: 2026-11-21

**Status**: Draft

**Input**: Decisiones del operador (21-11-2026), tras desplegar 046 en linus, donna y cbum. (1) "Los respaldos de cada repo deben quedar en la rama main": se le expusieron antes los costos (commits del launcher en main, crecimiento del clon de main, la poda deja de ser borrar una rama) y eligió esta opción por sobre mantener las ramas `backup/*`, verlas desde main o usar un repositorio de respaldo aparte. (2) "Trabajemos en un feat para ordenar los pendientes y resolverlos todos con refinamiento": esta feature absorbe además los avisos falsos del doctor medidos ese día (Atlassian, heartbeat, Claude OAuth) y los gates operativos de la flota (ensayo de restauración, despliegue y limpieza). Absorbe el spec que se había abierto como 049 (sonda de Atlassian), que se retiró.

## Contexto

**Lo que hay hoy (046, v0.32.0; desplegado el 21-11-2026).** Con `backup.repo.url`, cada una de las cinco unidades (`identity`, `vault`, `config`, `memory`, `history`) empuja a su propia rama huérfana `backup/<unidad>` del repositorio del agente. Cada commit reemplaza el árbol completo de su rama, que es como se propagan los borrados. Las ramas de trabajo (`main` y las de features) nunca se leen ni se escriben, y el clon de trabajo del agente (`/workspace/agent-repo`) nunca descarga las ramas `backup/*`.

**Lo medido el 21-11-2026.**

- Los tres repositorios (`rodrigo-hinojosa/{linus,donna,cbum}-workspace-agent-admin`) son privados, tienen `main` sin protección y las cinco ramas `backup/*` con un ciclo completo empujado y un segundo ciclo sin cambios.
- La cuenta es del plan gratuito: GitHub no permite reglas ni protección de ramas en repos privados (la API de rulesets responde 403 con "Upgrade to GitHub Pro"), así que hoy nada impide escribir en `main`.
- `main` de donna recibe trabajo real del operador por pull requests (PR #22 y #23 el 21-11-2026, desarrollados en un clon de la Mac), y su único workflow corre en `pull_request` hacia `main`.
- El tamaño de las cachés de respaldo es de 123 MB en donna, 10,6 MB en linus y 2,8 MB en cbum, la mayor parte en `history`.

**Avisos falsos del doctor (medidos el 21-11-2026 en ferrari).**

- **Atlassian.** `agentctl doctor` y `heartbeatctl token-check` muestran `Token atlassian-personal: network error (HTTP 404)` en linus, donna y cbum. La sonda consulta solo Jira (`<JIRA_URL>/rest/api/3/myself`). En `rodrigo-hinojosa.atlassian.net` Jira no responde ni sin credencial (`/rest/api/3/serverInfo` = 404, también por la pasarela `api.atlassian.com/ex/jira/<cloudId>`), y el mismo token vale para Confluence (`/wiki/rest/api/user/current` = 200 y `/wiki/rest/api/space` = 200 en los tres agentes). El token está sano; el aviso es falso e irresoluble.
- **Heartbeat.** El doctor de donna dice `Heartbeat enabled but no run recorded yet`, pero `heartbeatctl status` muestra 1818 corridas, todas `ok`, la última a las 15:00Z. El doctor lee `/workspace/scripts/heartbeat/logs/state.json` (`scripts/agentctl`, cerca de la línea 726) y el heartbeat escribe `scripts/heartbeat/state.json`. El aviso sale siempre que el heartbeat está activo.
- **Claude OAuth.** El doctor de donna y cbum muestra `Token claude_oauth (skipped — malformed expiresAt)`. Los tres agentes se autentican con `CLAUDE_CODE_OAUTH_TOKEN` en el entorno (medido: `set` en los tres), cuyo vencimiento el launcher no puede observar; la sonda solo mira el archivo de login que deja `/login`. No es un aviso (es informativo), pero el mensaje es engañoso.

**Pendientes operativos ya resueltos el 21-11-2026 (registro, no son alcance de código).** Los 3 commits sin publicar del clon viejo de linus se empujaron a `main` de su repo (`597033e..0d4ca24`, fast-forward); los 7 commits de la feature 010 de `cluster-rpi5-iac-admin`, que solo existían en ferrari, quedaron en la rama nueva `010-linus-dev-environment`; los clones viejos (`linus/linus-workspace-agent-admin`, `donna/.state/donna-workspace-agent-admin`) se movieron a `~/old-clones-20261121/` en ferrari; linus y donna integraron el delta de vault 0.27.0 (doctor: `all integrated`); y el commit `9d2dda8` del clon de linus en la Mac quedó publicado en la rama `001-n8n-agentic-ops`, sin tocar sus cambios sin commitear.

**Lo que cambia.** Los respaldos pasan a vivir dentro de `main`, cada unidad en su propio directorio, conviviendo con el trabajo del agente y del operador. Eso choca con tres supuestos de 046 y con el Principio V de la constitución ("Backups are five INDEPENDENT orphan branches"):

1. Un respaldo ya no puede reemplazar el árbol completo de su rama: solo su directorio.
2. Las cinco unidades y las personas escriben en la misma rama, así que un empuje puede encontrar a `main` adelantada y tiene que integrarse sin force push.
3. La poda ya no consiste en borrar una rama: lo que entra en el historial de `main` queda ahí.

## Clarifications

### Session 2026-11-21 (specify)

- Q: Cuando los respaldos ya estén en `main`, ¿qué pasa con las ramas `backup/*` viejas? → A: el launcher las borra, pero solo después de verificar que `main` tiene ese respaldo (decisión del operador, contra la recomendación de dejarlas intactas; el operador acepta que el launcher gane la capacidad de borrar ramas de respaldo propias).
- Q: Si `main` no se puede escribir directo (protegida, exige pull request), ¿qué hace la unidad? → A: abre un pull request con su commit y lo mergea ella misma con `GITHUB_PAT`, si GitHub lo permite; si no lo permite, falla visible (respuesta del operador: "el mismo agente puede mergear el PR a main en GitHub si esto se puede, que use el PAT").

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Cada unidad respalda en su directorio de main (Priority: P1)

El operador asocia un repositorio a un agente. Desde entonces, cada unidad de respaldo deja su contenido en un directorio propio dentro de `main`, sin tocar ningún archivo fuera de ese directorio, con el mismo cifrado, la misma marca de propiedad, la misma comprobación de privacidad y la misma idempotencia que en 046.

**Why this priority**: es el pedido. Sin esto no hay feature.

**Independent Test**: con un repositorio de prueba que tiene contenido de trabajo en `main`, correr las cinco unidades y comprobar que `main` gana exactamente los cinco directorios de respaldo, que ningún archivo de trabajo cambió y que un segundo ciclo no crea commits.

**Acceptance Scenarios**:

1. **Given** un agente con repositorio cuyo `main` tiene trabajo, **When** corre una unidad por primera vez, **Then** `main` gana un commit que solo agrega o cambia archivos bajo el directorio de esa unidad.
2. **Given** una unidad sin cambios de contenido, **When** corre otra vez, **Then** no crea commit y lo informa como hoy (`no changes since last backup`).
3. **Given** un archivo que desapareció del agente, **When** corre su unidad, **Then** ese archivo desaparece también de su directorio en `main`, y nada fuera del directorio se toca.
4. **Given** un agente marcado como sensible, **When** corre cualquier unidad, **Then** lo que 046 cifra sigue viajando cifrado: en `main` nunca aparece en claro nada que en 046 iba cifrado.
5. **Given** un repositorio público o no verificable, **When** corre una unidad, **Then** no escribe nada, como en 046.

---

### User Story 2 - Los respaldos conviven con el trabajo en main (Priority: P1)

El agente, el operador o un pull request mergeado pueden adelantar `main` mientras una unidad prepara su commit. La unidad se integra con esos cambios sin force push y sin perder ni alterar trabajo ajeno; y el trabajo de las personas no se ve estorbado por los respaldos.

**Why this priority**: `main` es donde se desarrolla. Un respaldo que pisa trabajo ajeno, o que obliga a resolver conflictos a mano, es peor que no tener respaldo en `main`.

**Independent Test**: con un repositorio de prueba, adelantar `main` con un commit ajeno entre la preparación y el empuje de una unidad, y con dos unidades empujando a la vez; comprobar que todos los commits ajenos siguen en `main`, que la unidad termina empujada y que nunca hubo un empuje forzado.

**Acceptance Scenarios**:

1. **Given** `main` adelantada por un commit ajeno, **When** una unidad empuja, **Then** integra su commit sobre la `main` nueva y el commit ajeno queda intacto.
2. **Given** dos unidades que empujan al mismo tiempo, **When** terminan, **Then** ambas quedan en `main` y ninguna borró el commit de la otra.
3. **Given** `main` sigue moviéndose y la unidad no logra integrarse dentro de su número de reintentos, **When** se agota, **Then** termina sin empujar, lo registra como fallo visible en `backup-status` y en el doctor, y reintenta en su próximo ciclo.
4. **Given** un commit ajeno que modificó archivos dentro de un directorio de respaldo, **When** corre esa unidad, **Then** el directorio vuelve a reflejar el estado del agente, y la unidad deja una línea que dice que sobrescribió un cambio ajeno.
5. **Given** un pull request abierto contra `main`, **When** las unidades empujan respaldos, **Then** el diff del pull request no muestra archivos de respaldo que el pull request no tocó.
6. **Given** el clon de trabajo del agente, **When** el agente trabaja, hace commit y empuja, **Then** los directorios de respaldo no aparecen en su árbol de trabajo y sus commits no pueden modificarlos.
7. **Given** un repositorio con workflows que corren en `push` a `main`, **When** una unidad empuja un respaldo, **Then** ese empuje no dispara esos workflows.

---

### User Story 3 - El operador restaura desde main (Priority: P1)

Tras perder el host, el operador restaura el agente con `--restore-from-repo` y obtiene lo mismo que con 046, leyendo desde `main`. Un repositorio que todavía solo tiene las ramas `backup/*` también se restaura.

**Why this priority**: un respaldo que no se puede restaurar no es respaldo.

**Independent Test**: restaurar desde un repositorio con los respaldos en `main` y comparar el workspace resultante con el de 046 sobre el mismo contenido; repetir con un repositorio que solo tiene las ramas `backup/*`.

**Acceptance Scenarios**:

1. **Given** un repositorio con los cinco directorios en `main`, **When** el operador restaura, **Then** obtiene los mismos archivos, en el mismo orden (`config`, `identity`, `vault`, `memory`, `history`) y con las mismas reglas de escritura (R9 de 046) que con las ramas.
2. **Given** un repositorio que solo tiene ramas `backup/*`, **When** el operador restaura, **Then** se restaura desde las ramas exactamente como en 046.
3. **Given** un repositorio con una unidad en `main` y otra solo en su rama, **When** el operador restaura, **Then** cada unidad sale de donde está y el informe dice de dónde salió cada una.
4. **Given** un directorio de respaldo en `main` sin marca de propiedad o con la de otro agente, **When** el operador restaura, **Then** esa unidad se salta con una línea que lo dice.

---

### User Story 4 - Los agentes ya desplegados migran sin perder la restauración (Priority: P2)

linus, donna y cbum tienen hoy sus respaldos en las cinco ramas `backup/*`. Al actualizarlos, sus respaldos pasan a `main` y en ningún momento quedan sin un respaldo restaurable.

**Why this priority**: son los únicos agentes con repositorio; la feature solo sirve si llega a ellos.

**Independent Test**: con un repositorio de prueba que tiene las cinco ramas `backup/*`, actualizar y correr un ciclo; comprobar que `main` tiene los cinco directorios, que una restauración funciona antes, durante y después de la migración, y que las ramas viejas siguen como el operador decidió.

**Acceptance Scenarios**:

1. **Given** un agente con ramas `backup/*`, **When** corre su primer ciclo tras la actualización, **Then** cada unidad escribe en `main` con una subida completa y nunca hay un momento en que una unidad no sea restaurable ni desde la rama ni desde `main`.
2. **Given** la migración completa, **When** el operador mira el repositorio, **Then** cada rama `backup/<unidad>` que lleva la marca de este agente fue borrada por el launcher, y solo después de verificar que el directorio de esa unidad en `main` remoto tiene la marca de este agente y el mismo contenido que se acaba de respaldar.
3. **Given** una rama `backup/<unidad>` sin marca, con la marca de otro agente, o cuya unidad todavía no verificó su directorio en `main`, **When** corre la migración, **Then** esa rama no se borra y la unidad lo informa.
4. **Given** el despliegue en la flota, **When** termina, **Then** linus, donna y cbum tienen los cinco directorios en `main`, un segundo ciclo sin cambios, y su trabajo en `main` intacto.

---

### User Story 5 - El operador ve y acota el costo de tener los respaldos en main (Priority: P3)

El operador sabe cuánto pesa lo que los respaldos dejaron en `main` y recibe un aviso antes de que crezca de forma problemática.

**Why this priority**: es la consecuencia aceptada de la decisión; conviene que se vea, pero no bloquea respaldar.

**Independent Test**: con un repositorio de prueba, generar varios ciclos con cambios y comprobar que `backup-status` y el doctor reportan el peso y avisan al cruzar el umbral.

**Acceptance Scenarios**:

1. **Given** respaldos en `main`, **When** el operador corre `backup-status`, **Then** ve el destino (`main` y el directorio de cada unidad) y el peso estimado de cada una.
2. **Given** un repositorio cuyo peso de respaldo supera el umbral, **When** corre el doctor, **Then** avisa con el peso y dice cómo se reduce (y que reducirlo exige reescribir historia, que el launcher no hace).

---

### User Story 6 - El doctor solo avisa lo que es verdad (Priority: P2)

El operador corre `agentctl doctor` en un agente sano y no ve avisos falsos: el token de Atlassian se juzga por el producto que responde, el heartbeat se lee desde donde se escribe y la sonda de Claude dice que el login es por token de entorno.

**Why this priority**: un aviso permanente e irresoluble entrena a ignorar los avisos; hoy los tres agentes muestran al menos uno.

**Independent Test**: con dobles de prueba, (a) Jira 404 y Confluence 200 dan sano y nombran Confluence; Jira 404 y Confluence 401 dan `auth_fail`; Jira 200 no consulta Confluence; (b) un `state.json` del heartbeat en su ruta real hace que el doctor informe la última corrida; (c) con `CLAUDE_CODE_OAUTH_TOKEN` en el entorno, la sonda de Claude informa login por token de entorno.

**Acceptance Scenarios**:

1. **Given** Jira responde 404 y Confluence 200, **When** corre la sonda de Atlassian, **Then** el resultado es `ok` y la línea dice que lo validó Confluence.
2. **Given** Jira responde 2xx, 401 o 403, **When** corre la sonda, **Then** resuelve como antes de 048, sin consultar Confluence.
3. **Given** Jira responde 404 y Confluence 401 o 403, **When** corre la sonda, **Then** el resultado es `auth_fail` y nombra Confluence y el código.
4. **Given** Jira responde 404 y Confluence también 404, o falla por red, **When** corre la sonda, **Then** el resultado es `network` y la línea dice que ningún producto respondió.
5. **Given** un heartbeat activo con corridas registradas, **When** corre el doctor, **Then** informa la última corrida (estado, hora, duración) y no dice "no run recorded yet".
6. **Given** un heartbeat activo sin ninguna corrida todavía, **When** corre el doctor, **Then** sigue diciendo "no run recorded yet", como hoy.
7. **Given** `CLAUDE_CODE_OAUTH_TOKEN` presente en el entorno del agente, **When** corre la sonda de Claude, **Then** informa `skipped` con el motivo "login por token de entorno; vencimiento no observable", sin aviso, aunque exista además el archivo de login.
8. **Given** sin token de entorno y con el archivo de login, **When** corre la sonda de Claude, **Then** se comporta como antes de 048.

---

### User Story 7 - La flota queda migrada, verificada y limpia (Priority: P3)

Tras el merge, el operador lleva la versión nueva a cbum primero, ensaya una restauración real desde `main`, y solo entonces la lleva a linus y donna. Al final, los tres respaldan en `main`, sus ramas viejas se borraron de forma verificada, el doctor de cada uno no tiene avisos falsos y se retiraron los respaldos temporales del despliegue anterior.

**Why this priority**: es lo que convierte el código en el estado pedido de la flota; depende de las historias anteriores.

**Independent Test**: seguir el procedimiento del gate y comprobar cada paso con `backup-status`, la lista de ramas del repo en GitHub, el doctor y el informe de la restauración.

**Acceptance Scenarios**:

1. **Given** cbum actualizado, **When** corre su primer ciclo, **Then** `main` de su repo tiene los cinco directorios, sus ramas `backup/*` se borraron tras la verificación y un segundo ciclo no crea commits.
2. **Given** cbum migrado, **When** el operador restaura cbum desde `main` en la Mac, en un destino desechable y con la llave M4, **Then** la restauración termina sin errores, su informe dice que cada unidad salió de `main` y el contenido coincide con el del agente vivo (comparación por nombres y hashes, sin imprimir secretos). Ningún contenedor restaurado se levanta mientras cbum corre.
3. **Given** el ensayo aprobado, **When** se actualizan linus y donna, **Then** quedan como cbum en el escenario 1, con todos los commits previos de su `main` presentes.
4. **Given** el ensayo fallido, **When** el operador lo ve, **Then** linus y donna no se actualizan y cbum vuelve a su imagen y archivos previos.
5. **Given** los tres migrados y verificados, **When** termina el despliegue, **Then** el doctor de cada uno no muestra los avisos falsos de US6, y se borran en ferrari los respaldos `~/<agente>-pre033-*`, las imágenes `agentic-pod:<agente>-pre033` y `~/old-clones-20261121/`, tras confirmar que su contenido está en GitHub o ya no se necesita.

---

### Edge Cases

- **`main` protegida.** Un plan de pago, o un repositorio público, puede proteger `main` o exigir pull requests. Si el empuje directo es rechazado por la protección, la unidad empuja su commit a una rama temporal propia, abre un pull request hacia `main` y lo mergea con `GITHUB_PAT`; borra la rama temporal tras el merge. Si GitHub no permite el merge (revisión obligatoria, checks pendientes, credencial sin permiso), cierra el pull request, borra la rama temporal y falla de forma visible; no deja respaldos en otra rama.
- **`main` no existe o el repositorio está vacío.** Igual que en 046: el repositorio debe tener un commit inicial en `main`; si no, la unidad no escribe y lo dice.
- **Rama por defecto distinta de `main`.** Los respaldos van a `main`, no a la rama por defecto; si `main` no existe, la unidad falla visible.
- **Un pull request mergeado borra o mueve un directorio de respaldo.** La próxima corrida de cada unidad lo recrea completo y lo informa.
- **El historial de `main` crece por los blobs cifrados.** Consecuencia aceptada: no se poda borrando una rama. Ver US5.
- **Rebases del operador.** Un force push del operador sobre `main` que descarta commits de respaldo deja el subárbol `.agent-backup/<unidad>` de `main` distinto del último que la unidad empujó, o ausente; la siguiente corrida de cada unidad lo detecta y recrea su directorio.
- **Workflows en `push`.** Los commits de respaldo no deben disparar CI; si un workflow ignora la señal de omisión, el costo es de ese repositorio y se documenta.
- **Archivos de más de 100 MB.** El almacén por bloques de 046 ya los parte en bloques de 1 MiB; ningún archivo de respaldo en `main` puede superar el límite de GitHub.
- **Fork o sin destino.** Byte a byte igual que antes de 048, que a su vez es igual que antes de 046.
- **Modo local.** Fuera de alcance para los respaldos, como en 046. La corrección del doctor del heartbeat (US6) aplica donde el doctor docker la lee; el modo local usa sus propias rutas y no cambia.
- **Sitio de Atlassian con la URL configurada terminada en `/wiki`.** La consulta a Confluence se arma sobre la base del sitio, sin duplicar `/wiki`.
- **Jira 5xx o sin respuesta.** Es un problema del servicio o de red, no de producto ausente: `network`, sin consultar Confluence.
- **El token de Atlassian o de Claude nunca aparece** en la línea, el estado, los logs ni el informe del doctor.

## Requirements *(mandatory)*

### Functional Requirements

**Ubicación y alcance de escritura**

- **FR-001**: Con repositorio asociado, cada unidad MUST escribir su respaldo en `.agent-backup/<unidad>/` dentro de `main` (`identity`, `vault`, `config`, `memory`, `history`). `.agent-backup/README.md` MUST explicar qué contiene cada directorio, que lo escribe el launcher y cómo se restaura; lo escribe el launcher y solo cambia cuando cambia su texto.
- **FR-002**: Cada commit de una unidad MUST cambiar solo archivos dentro de su directorio; la única excepción es `.agent-backup/README.md`, cuyo dueño es la unidad `config`. Ningún otro archivo de `main` puede agregarse, cambiar ni borrarse por un respaldo.
- **FR-003**: Dentro de su directorio, cada unidad MUST dejar exactamente su contenido actual (los borrados se propagan), con la misma idempotencia por hash de 046: sin cambios, sin commit.
- **FR-004**: El contenido de cada directorio MUST conservar el formato de su rama en 046 (archivos en claro permitidos, almacén cifrado `store/`, marca de propiedad), de modo que el cifrado, la lista de lo que viaja en claro y la marca no cambien.

**Convivencia con el trabajo**

- **FR-005**: Una unidad MUST NOT empujar con force ni reescribir historia de `main`.
- **FR-006**: Si `main` avanzó, la unidad MUST integrar su commit sobre la `main` actual y reintentar, hasta un número acotado de intentos dentro de su tiempo límite; al agotarlo MUST terminar sin empujar y registrar el fallo de forma visible.
- **FR-007**: Las cinco unidades MUST poder empujar en paralelo sin perder el commit de otra ni de un tercero.
- **FR-008**: Si encuentra en su directorio cambios que no hizo, la unidad MUST restaurar su contenido y dejar una línea que lo diga.
- **FR-009**: Los commits de respaldo MUST identificarse como del launcher (autor y mensaje fijos, con agente y unidad) y MUST pedir que no se disparen workflows de CI.
- **FR-010**: El clon de trabajo del agente MUST NOT mostrar los directorios de respaldo en su árbol de trabajo ni permitir que un commit del agente los modifique; el agente MUST poder trabajar, hacer commit y empujar a `main` y a ramas de features como hoy.
- **FR-011**: El texto del `CLAUDE.md` del agente (sección "Your repository") MUST describir la nueva convivencia: los respaldos viven en `main` bajo el directorio de respaldo, el agente no lo toca.

**Seguridad (sin cambios respecto de 046)**

- **FR-012**: La comprobación de privacidad, la credencial, el candado por unidad, los límites de tiempo y la regla "nada que deba ir cifrado sale en claro" MUST aplicarse igual que en 046.
- **FR-013**: Una unidad MUST NOT escribir en un directorio de respaldo cuya marca de propiedad falte o nombre a otro agente; MUST fallar visible.

**Restauración**

- **FR-014**: `--restore-from-repo` MUST restaurar cada unidad desde su directorio en `main` si existe y tiene marca válida; si no, desde su rama `backup/<unidad>` como en 046; si no hay ninguna, saltarla con una línea, como hoy.
- **FR-015**: La restauración MUST conservar el orden y las reglas de escritura de 046 (R9) y su informe MUST decir de dónde salió cada unidad.

**Migración**

- **FR-016**: En un agente con ramas `backup/*`, la primera corrida de cada unidad tras actualizar MUST escribir su directorio en `main` (subida completa) sin borrar su rama antes de que `main` tenga ese respaldo.
- **FR-017**: Tras escribir su directorio en `main`, cada unidad MUST verificar en el remoto que `main` contiene su directorio con la marca de este agente y el contenido recién respaldado; solo entonces MUST borrar su rama `backup/<unidad>`, y solo si esa rama lleva la marca de este agente. Una rama sin marca o de otro agente MUST NOT borrarse. Si la verificación o el borrado fallan, la rama queda y se reintenta en el próximo ciclo.
- **FR-021**: Si `main` rechaza el empuje directo por protección, la unidad MUST intentar el camino de pull request (rama temporal propia, pull request hacia `main`, merge con la credencial del agente, borrado de la rama temporal). Si el merge no es posible, MUST cerrar el pull request, borrar la rama temporal y fallar visible. La rama temporal y el pull request MUST llevar la marca del launcher para que nunca se confundan con trabajo de personas.

**Visibilidad**

- **FR-018**: `backup-status` MUST mostrar, por unidad, el destino (`main:<directorio>` o la rama) y el peso estimado; el doctor MUST avisar cuando el peso total de respaldo en el repositorio supere un umbral.

**Doctor y sondas veraces (US6)**

- **FR-022**: La sonda de Atlassian MUST consultar primero Jira en la URL configurada y, con 2xx, 401 o 403, resolver como antes de 048 sin una segunda consulta.
- **FR-023**: Si Jira responde 404, la sonda MUST consultar Confluence en la misma base del sitio con la misma credencial y usar su resultado (2xx = `ok`, 401/403 = `auth_fail`, otro = `network`); con cualquier otro resultado de Jira MUST informar `network` sin segunda consulta.
- **FR-024**: La línea de la sonda de Atlassian MUST nombrar el producto cuando fue Confluence quien decidió, y conservar el formato de cuatro campos (estado, código, latencia, mensaje) que consumen las transiciones y la deduplicación; su tiempo total MUST quedar acotado a dos consultas con el límite por consulta existente.
- **FR-025**: El doctor docker MUST leer el estado del heartbeat desde la ruta donde el heartbeat lo escribe; con un estado presente MUST informar la última corrida y solo con el estado ausente o sin corridas MUST decir "no run recorded yet".
- **FR-026**: Con `CLAUDE_CODE_OAUTH_TOKEN` presente en el entorno, la sonda de Claude MUST informar `skipped` con el motivo de login por token de entorno y vencimiento no observable, sin aviso; sin ese token MUST comportarse como antes de 048.
- **FR-027**: Las sondas de GitHub y Telegram, la lógica de transiciones y la deduplicación de avisos MUST quedar sin cambios.

**Despliegue y cierre (US7)**

- **FR-028**: El despliegue MUST seguir el orden cbum, ensayo de restauración aprobado por el operador, linus y donna; sin ensayo aprobado, linus y donna MUST NOT actualizarse.
- **FR-029**: El ensayo MUST restaurar en un destino desechable, con la llave del operador, sin levantar el agente restaurado, y comparar contra el agente vivo por nombres y hashes sin imprimir contenidos de secretos.
- **FR-030**: Solo después de los tres agentes migrados y verificados MUST retirarse en ferrari los respaldos `~/<agente>-pre033-*`, las imágenes `agentic-pod:<agente>-pre033`, `~/old-clones-20261121/` y los respaldos del despliegue de 047 en los admins locales (`~/mclaren-preUpgrade-v033-*` en mclaren y `~/ferrari-preUpgrade-v033-*` en ferrari), y cada retiro MUST registrarse.

**No regresión**

- **FR-019**: Con fork o sin destino, todo MUST quedar byte a byte igual que en `main` del launcher antes de 048 (los archivos dorados de 046 lo comprueban).
- **FR-020**: El Principio V de la constitución MUST enmendarse para reflejar que, con repositorio, los respaldos son directorios independientes en `main` y no ramas huérfanas; la independencia de las unidades (código, caché, hash, staging, commit) se conserva.

### Key Entities

- **Directorio de respaldo de una unidad**: la carpeta de `main` que contiene el respaldo de una unidad: sus archivos permitidos en claro, su almacén cifrado y su marca de propiedad. Una por unidad.
- **Commit de respaldo**: commit en `main` hecho por el launcher, que solo toca un directorio de respaldo y lleva agente, unidad y la señal para no disparar CI.
- **Rama `backup/<unidad>` (heredada)**: la ubicación de 046; fuente de restauración de compatibilidad mientras exista.
- **Clon de trabajo del agente**: el clon de `/workspace/agent-repo`, que trabaja en `main` y ramas de features sin ver ni modificar los directorios de respaldo.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: En 100 ciclos de prueba con `main` adelantada por commits ajenos, el 100 % de los commits ajenos sigue en `main` y ningún empuje fue forzado.
- **SC-002**: En el mismo conjunto, ningún commit de respaldo cambia un archivo fuera de su directorio (0 casos).
- **SC-003**: Una restauración desde `main` deja el mismo conjunto de archivos que la restauración desde las ramas de 046 sobre el mismo contenido (diferencias: 0).
- **SC-004**: Un segundo ciclo sin cambios no crea commits en ninguna de las cinco unidades.
- **SC-008**: En la migración, ninguna rama `backup/<unidad>` se borra antes de que su directorio en `main` esté verificado (0 casos en las pruebas de orden), y ninguna rama sin marca o de otro agente se borra.
- **SC-005**: linus, donna y cbum terminan con los cinco directorios en `main`, el trabajo de `main` intacto (todos sus commits previos presentes) y una restauración verificada al menos en uno de ellos.
- **SC-006**: Con fork o sin destino, las salidas, códigos de salida, archivos de estado y crontab son idénticos a los de antes de 048 (0 diferencias en los archivos dorados).
- **SC-007**: Un commit de respaldo no dispara ningún workflow que corra en `push` a `main`. En el host solo se verifica que el mensaje lleva `[skip ci]` (GitHub Actions no se puede ejecutar ahí); el efecto real se verifica en vivo en el despliegue (T052).
- **SC-009**: Tras el despliegue, el doctor de linus, donna y cbum muestra 0 de los tres avisos falsos medidos el 21-11-2026 (Atlassian 404, heartbeat sin corridas en donna, Claude `malformed expiresAt`).
- **SC-010**: En las pruebas de la sonda de Atlassian, el 100 % de las combinaciones de la tabla de respuestas de Jira y Confluence produce el veredicto esperado, y el resto de las pruebas de salud de tokens pasa sin editarse.
- **SC-011**: El ensayo de restauración de cbum desde `main` termina con 0 diferencias de nombres y hashes frente al agente vivo en lo que las cinco unidades cubren.
- **SC-012**: Al cierre, ferrari no conserva respaldos `pre033` ni `~/old-clones-20261121/`, y cada borrado figura en el registro de la feature.

## Assumptions

- La rama de respaldo es `main` por decisión del operador, no la rama por defecto del repositorio.
- El directorio raíz es `.agent-backup/` (oculto, para no chocar con código, specs ni con el nombre de las ramas `backup/*` heredadas).
- El clon de trabajo excluye `.agent-backup/` de su árbol (checkout parcial) y la regla del FR-010 se impone en el lado del agente; un humano en otro clon puede igual modificarlo, y por eso existe el FR-008.
- La señal para no disparar CI es la convención de GitHub en el mensaje del commit; un workflow que la ignore queda fuera del control del launcher.
- El diff de un pull request se calcula contra su base de merge, así que los commits de respaldo que llegan a `main` después de abrirlo no aparecen en él (US2, escenario 5); se prueba en TM22 con el diff de tres puntos que usa GitHub.
- El FR-018 conserva el aviso de 046 por cachés sobre 800 MB y suma uno por tamaño del repositorio sobre 1 GB (contrato D4).
- La credencial `GITHUB_PAT` ya puede escribir en `main` de los tres repositorios (lo hace en las ramas `backup/*` desde el 21-11-2026 y la cuenta no tiene protección de ramas).
- La cuenta es del plan gratuito: hoy no existe un `main` protegido en estos repositorios, así que el camino de pull request del FR-021 no se ejerce en la flota actual; se prueba con un servidor de prueba.
- En Atlassian Cloud, Jira y Confluence comparten la base del sitio y la misma credencial; `/wiki/rest/api/user/current` devuelve 200 a cualquier usuario autenticado (medido con el token del operador).
- El vencimiento de `CLAUDE_CODE_OAUTH_TOKEN` no es observable desde el agente sin una llamada que consuma cuota; la feature no lo intenta.
- La versión sube como MINOR y exige reconstruir la imagen (código horneado: librerías de backup, sonda de tokens, heartbeatctl).
- Borrar una rama de respaldo es irreversible desde el launcher; GitHub permite restaurar una rama borrada desde la interfaz durante un tiempo limitado, pero el launcher no depende de eso.

## Out of Scope

- Modo local.
- Podar o compactar el historial de `main` (exige reescribir historia y force push; queda en manos del operador, documentado).
- Cambiar el formato del almacén cifrado, la lista de lo que viaja en claro o la regla de sensibilidad de 046.
- Evaluar el vencimiento real del login de Claude en docker (la evaluación completa del perfil de 047 queda para un agente que use `/login`).
- Sondear Jira por la pasarela de Atlassian o soportar tokens con alcance restringido; cambiar el MCP `mcp-atlassian`.
- Mover los respaldos de un repositorio a otro.

## Refinement decisions

### 2026-11-21 session

- D: estructura de los pendientes de la flota → A: una sola feature 048 (renombrada `048-fleet-backup-main`) con las historias de código (respaldo en main, sonda de Atlassian, ruta del heartbeat en el doctor, sonda de Claude) y los gates operativos como historia final, al estilo de 046; un solo PR y un bump MINOR; el spec 049 se absorbió y su worktree se retiró.
- D: sonda `claude_oauth` en docker con token de entorno → A: informar con honestidad "login por token de entorno; vencimiento no observable", sin aviso; el archivo de login solo se evalúa sin token de entorno.
- D: orden del despliegue y del ensayo de restauración → A: cbum como canario, ensayo de restauración desde main en la Mac con la llave M4, y solo si pasa linus y donna.
- D: cómo se ve el respaldo en `main` → A: `.agent-backup/<unidad>/` oculto con un `README.md` propio; el clon de trabajo del agente lo excluye con checkout parcial (FR-001, Assumptions).
- D: restos de despliegues anteriores a pre033 en ferrari → A: borrados el 21-11-2026 (8 imágenes de rollback, 5 tgz de código y el clon `~/apl-donna-src`, cuyo commit local ya estaba en main por el squash de 037); se conservan pre033 y `~/old-clones-20261121/` hasta el cierre de US7.
- D: rodri-cenco-admin (deprecado, detenido desde el 24-10-2026) → A: fuera del alcance de 048; su retiro es una decisión aparte (vault de 2899 páginas y Syncthing en dos equipos).
- D: commit `9d2dda8` del clon de linus en la Mac → A: publicar solo la rama `001-n8n-agentic-ops` sin tocar lo sin commitear (hecho el 21-11-2026: remoto en `9d2dda8`).

