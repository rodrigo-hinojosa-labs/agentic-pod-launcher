# Feature Specification: Aviso automatico de integracion de delta al arrancar

**Feature Branch**: `038-schema-delta-boot-nudge`

**Created**: 2026-09-30

**Status**: Draft

**Input**: User description: "al detectar una actualizacion de version con un delta de schema pendiente de integrar, el agente recibe un empujon automatico en su primer arranque, en vez de depender de que el operador se lo pida o de esperar la gracia de 14 dias de schema_delta_pending"

**Nota de rama base**: esta feature depende funcionalmente del mecanismo de delta de schema
introducido por `037-second-brain-rag` (aun no mergeada a `main` al momento de crear esta rama:
`main` sigue en VERSION 0.26.0, esta rama parte de VERSION 0.27.0). Por eso se ramifico desde
`037-second-brain-rag` en vez de desde `main` — precedente: `023-fix-render-ampersand` se ramifico
sobre `022-local-session-lifecycle` por la misma razon (ver CLAUDE.md del repo, seccion "REBASE
SOBRE 022"). El PR de esta feature debe esperar a que 037 mergee a `main` primero; en ese momento
esta rama se rebasa sobre `main`, verificando `VERSION` contra `origin/main` a mano antes de
continuar (la lección explícita de esa rebase pasada: un rebase no avisa un conflicto de VERSION
si ambas ramas escribieron el mismo numero por coincidencia).

## User Scenarios & Testing *(mandatory)*

### User Story 1 - El agente se entera solo de que tiene una actualizacion de conocimiento pendiente (Priority: P1)

Un agente es actualizado a una version nueva del launcher que deposita un delta de schema del
vault (nuevas reglas opcionales de frontmatter, nuevos tipos de hallazgo, etc.). Hoy, el agente
sigue describiendo su propio sistema de conocimiento con el modelo viejo hasta que alguien —
el operador, por lo general — le pide explicitamente que revise el delta e integre los cambios a
su `CLAUDE.md`. Con esta feature, la primera vez que el agente arranca una sesion despues de la
actualizacion, se entera por su cuenta de que hay una integracion pendiente y la puede abordar sin
que nadie se lo pida.

**Why this priority**: es el problema medido en produccion (donna, 30-09-2026): el agente
respondio sobre su propio sistema RAG con informacion desactualizada porque nadie le aviso del
delta pendiente. Sin este empujon, la brecha entre "el codigo esta actualizado" y "el agente sabe
que esta actualizado" puede durar indefinidamente si nadie pregunta.

**Independent Test**: puede probarse actualizando un agente a una version con un delta pendiente,
arrancando su primera sesion, y verificando que el agente recibe la senal de integracion pendiente
sin ninguna accion del operador.

**Acceptance Scenarios**:

1. **Given** un agente fue actualizado y tiene un delta de schema depositado sin integrar a su
   `CLAUDE.md`, **When** arranca su primera sesion tras la actualizacion, **Then** el agente recibe
   una senal explicita, al inicio de esa sesion, de que existe una integracion de conocimiento
   pendiente y cual delta la origina.
2. **Given** un agente sin ningun delta pendiente (nunca actualizado, o ya integro todos los que
   tenia), **When** arranca una sesion normal, **Then** no recibe ninguna senal de integracion
   pendiente.

---

### User Story 2 - El aviso no se repite una vez atendido (Priority: P2)

Una vez que el agente fue notificado de un delta pendiente (ya sea porque lo integro el mismo, o
porque el operador se lo pidio manualmente antes de que el aviso automatico llegara a dispararse),
los arranques siguientes no deben repetir el mismo aviso — seria ruido, no ayuda.

**Why this priority**: un aviso persistente en cada arranque erosiona la utilidad del mecanismo
(el operador empieza a ignorarlo) y puede confundirse con un problema real de arranque.

**Independent Test**: puede probarse integrando el delta pendiente (a mano o via el propio aviso),
reiniciando el agente varias veces, y verificando que el aviso no vuelve a aparecer para ese mismo
delta.

**Acceptance Scenarios**:

1. **Given** un agente ya integro un delta especifico a su `CLAUDE.md`, **When** arranca cualquier
   sesion posterior, **Then** no recibe ningun aviso sobre ese delta ya integrado.
2. **Given** el operador le pidio manualmente al agente integrar un delta ANTES de que el aviso
   automatico llegara a dispararse, **When** el agente arranca su siguiente sesion, **Then** el
   sistema reconoce que ya esta integrado y no dispara un aviso redundante.

---

### User Story 3 - El mismo comportamiento en modo local y en modo docker (Priority: P3)

El hueco de integracion es igual de real en un agente local (ej. mclaren) que en uno docker (ej.
donna, linus). El aviso semanal de PARA introducido por 037 es exclusivo de modo docker; este
mecanismo de aviso de integracion debe funcionar igual en ambos modos.

**Why this priority**: menor urgencia que P1/P2 porque el hueco ya esta confirmado y resuelto
manualmente para el caso docker; pero dejar el modo local sin cobertura recrearia el mismo
problema la proxima vez que un agente local se actualice.

**Independent Test**: puede probarse actualizando un agente local con un delta pendiente y
verificando que recibe el mismo tipo de aviso que un agente docker en la misma situacion.

**Acceptance Scenarios**:

1. **Given** un agente en modo local fue actualizado con un delta de schema pendiente, **When**
   arranca su primera sesion tras la actualizacion, **Then** recibe el mismo tipo de aviso que
   recibiria un agente docker en la misma situacion.

---

### Edge Cases

- Que pasa si un agente acumulo MAS DE UN delta sin integrar (estuvo mucho tiempo apagado a traves
  de varias actualizaciones de version)? El aviso debe cubrir TODOS los pendientes, no solo el mas
  reciente.
- Que pasa si el propio mecanismo de aviso falla (por ejemplo, no puede escribir su propio marcador
  de "ya avisado")? El arranque normal de la sesion no debe verse retrasado ni bloqueado por eso —
  mismo principio de fail-soft que rige el resto del ciclo de arranque (ver feature 036,
  boot-resilience).
- Que pasa si el operador ya le pidio al agente integrar el delta ANTES de que el aviso automatico
  llegara a dispararse (el caso ya ocurrido con donna)? El sistema debe reconocer que ya esta
  integrado (reusando la misma deteccion que usa para decidir si el aviso hace falta) y no disparar
  un aviso redundante en el siguiente arranque.
- Que pasa si un agente tiene el aviso semanal de PARA (`features.heartbeat.review`) deshabilitado
  (el default)? El aviso de esta feature debe dispararse igual — es independiente de ese toggle.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: El sistema DEBE detectar, en el primer arranque de sesion tras una actualizacion de
  version, si existe algun delta de schema del vault depositado y aun no integrado al `CLAUDE.md`
  del agente.
- **FR-002**: Cuando se detecta un delta sin integrar, el sistema DEBE hacer que el agente se entere
  de esto al inicio de esa sesion, sin requerir ninguna accion del operador.
- **FR-003**: El aviso DEBE dispararse como maximo una vez por delta pendiente — arranques
  posteriores NO deben repetir el mismo aviso una vez que se disparo.
- **FR-004**: El mecanismo de aviso NO DEBE depender de que el aviso semanal de PARA
  (`features.heartbeat.review.enabled`) este activado — debe funcionar sin importar ese ajuste.
- **FR-005**: El mecanismo de aviso DEBE estar disponible tanto en modo docker como en modo local.
- **FR-006**: Si el mecanismo de aviso encuentra un error, el arranque de la sesion DEBE continuar
  con normalidad y NO debe verse retrasado ni bloqueado por esa falla.
- **FR-007**: El sistema DEBE reconocer correctamente cuando un delta ya fue integrado (sea porque
  el agente lo hizo por su cuenta, o porque el operador se lo pidio manualmente antes de que el
  aviso automatico se disparara) y NO DEBE disparar un aviso redundante en ese caso.
- **FR-008**: Cuando hay mas de un delta sin integrar a la vez, el aviso DEBE referenciar todos los
  pendientes, no solo el mas reciente.

### Key Entities

- **Delta de schema**: un conjunto versionado de reglas nuevas y opcionales del schema del vault
  (por ejemplo, la capa PARA de la version 0.27.0) que el agente debe leer e incorporar a su propia
  descripcion de como funciona su base de conocimiento.
- **Marcador de aviso**: un registro de que el agente ya fue notificado proactivamente sobre un
  delta pendiente especifico, distinto del marcador que registra que el delta fue depositado.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Tras actualizar un agente a una version con un delta de schema pendiente, la primera
  sesion que arranca despues expone la integracion pendiente al agente sin que el operador tenga
  que preguntar.
- **SC-002**: Un agente que ya integro un delta, o que ya fue avisado una vez sobre el, no recibe un
  aviso repetido sobre ese mismo delta en arranques normales posteriores.
- **SC-003**: Un agente en modo local y un agente en modo docker, frente a un delta pendiente
  equivalente, muestran el mismo comportamiento de aviso.
- **SC-004**: Introducir este mecanismo no genera ningun cambio medible en el tiempo ni la
  confiabilidad de arranque de un agente sin ningun delta pendiente (sin regresion para el caso
  comun).
- **SC-005**: Si el propio mecanismo de aviso falla, el arranque de la sesion igual se completa con
  exito (verificado por inyeccion de fallas).

## Assumptions

- La heuristica de deteccion de "delta ya integrado" que 037 ya usa en su propio gate de hardware
  (buscar en el `CLAUDE.md` del vault la seccion especifica que ese delta pide agregar) es
  reutilizable como señal de si el aviso sigue haciendo falta; el plan puede elegir otro mecanismo
  de implementacion siempre que cumpla los requisitos funcionales de arriba.
- El aviso semanal de PARA (`features.heartbeat.review`) y su gracia de 14 dias para
  `schema_delta_pending` no cambian con esta feature; son mecanismos de revision recurrente
  distintos del aviso unico de arranque que introduce esta feature.
- El `CLAUDE.md` del vault sigue siendo editado unicamente por el propio agente; este mecanismo
  nunca lo reescribe automaticamente, solo se asegura de que el agente note la integracion
  pendiente de inmediato.
- Esta feature depende de `037-second-brain-rag` y no puede mergearse a `main` antes que ella.
