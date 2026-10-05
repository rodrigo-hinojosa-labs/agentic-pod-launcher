# Feature Specification: Aviso de actualización de conocimiento al iniciar sesión

**Feature Branch**: `038-schema-delta-boot-nudge`

**Created**: 2026-09-30 (reescrito el mismo día; el borrador previo quedó en el commit `d88cbfb`)

**Status**: Draft

**Input**: User description: "cada vez que se actualice la versión del agente dejar un proceso automático para que cuando se levante el agente entienda que debe actualizar toda su base de conocimiento"

**Nota de rama base**: esta feature depende del mecanismo de delta de schema de `037-second-brain-rag`,
que aún no está en `main` (`main` = VERSION 0.26.0; esta rama parte de 0.27.0). Por eso se ramificó
desde `037-second-brain-rag`, igual que `023-fix-render-ampersand` lo hizo sobre
`022-local-session-lifecycle`. El PR de 038 espera a que 037 mergee; en ese momento la rama se rebasa
sobre `main` y `VERSION` se verifica a mano contra `origin/main` (un rebase no delata un conflicto de
VERSION cuando ambas ramas escribieron el mismo número).

**Nota de nombre**: el identificador `schema-delta-boot-nudge` se conserva por estabilidad (rama,
directorio, `.specify/feature.json`), aunque el alcance creció de "deltas del vault" a "las dos capas de
conocimiento que un upgrade deja atrás".

## Clarifications

### Session 2026-09-30

- Q: ¿Con qué mecanismo se entera el agente? → A: un hook `SessionStart` de Claude Code, en ambos modos,
  que inyecta el aviso en el contexto de la sesión interactiva; `agentctl doctor` como superficie para el
  operador. Sin turno aislado de heartbeat y sin marcador de "ya avisado". Reemplaza la decisión previa del
  mismo día (heartbeat aislado en docker + doctor en local), tomada sobre una premisa incorrecta: que la
  inyección en la sesión no tenía precedente. El repo ya instala hooks en ambos modos (028, 031).
- Q: ¿Qué capas de conocimiento cubre? → A: las dos que un upgrade deja atrás: el `CLAUDE.md` del vault
  (deltas de schema) y el `CLAUDE.md` del workspace (plantilla del launcher).
- Q: ¿Cómo se trata el `CLAUDE.md` del workspace? → A: se re-renderiza solo si no cambió desde la última
  vez que el launcher lo escribió; si tiene ediciones propias, o si no hay línea base para saberlo, se
  preserva y se avisa.

## Contexto medido

Medido en ferrari y en este host el 30-09-2026, después de subir donna y linus a 0.27.0:

1. **Capa vault.** Ni donna ni linus tienen el encabezado `## Actionability (PARA)` en el `CLAUDE.md` de
   su vault. El delta 0.27.0 está depositado (`_templates/.schema-updates-0.27.0.applied`) pero nadie le
   avisó al agente que debía integrarlo. Por diseño (014/037), el launcher nunca reescribe ese archivo: la
   integración es tarea del agente.
2. **Capa workspace.** El `CLAUDE.md` del workspace de ambos, el que Claude Code carga solo en cada sesión,
   sigue en la plantilla pre-037: dice "derives three JSON artifacts" y no menciona `policy.json`,
   `packets.json`, la cola de revisión ni el alcance `wiki/` de qmd. `--regenerate` preserva ese archivo
   salvo `--force-claude-md`.
3. **La preservación no protege nada en la flota medida.** Las "Reglas de trabajo" no viven en
   `CLAUDE.md`, viven en `personas/<agente>.md` (`agent.role_file`) y el render las inyecta. Un render de
   la plantilla actual con el `agent.yml` y la persona de donna difiere de su `CLAUDE.md` vivo solo en los
   cambios de 037 y en una sección Heartbeat que quedó de cuando lo tenía activo (hoy `enabled: false`). No
   hay ediciones a mano. El archivo no está personalizado: está viejo, y además miente sobre su propia
   configuración.
4. **El mecanismo funciona.** En Claude Code 2.1.280, un hook `SessionStart` que devuelve
   `additionalContext` llega al modelo al arrancar (`source=startup`) y al reanudar con `--continue`
   (`source=resume`). Una sesión reanudada también carga el `CLAUDE.md` vigente del disco.

Conclusión: el síntoma de donna (describir su RAG con el modelo pre-037) tiene dos causas, no una.
Integrar solo el delta del vault deja a la sesión cargando instrucciones operativas viejas.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - El agente sabe al iniciar sesión qué conocimiento tiene pendiente (Priority: P1)

Tras un upgrade, el agente inicia sesión y su contexto ya le dice qué quedó pendiente de integrar: qué delta
de schema del vault falta, dónde leerlo y cómo se reconoce que quedó integrado; y si su `CLAUDE.md` del
workspace quedó atrás de la plantilla vigente, dónde está la versión actual. Nadie tiene que pedírselo.

**Why this priority**: es la falla medida en producción. Sin esto, la brecha entre "el código está
actualizado" y "el agente sabe que está actualizado" dura hasta que alguien pregunta y nota la respuesta
vieja.

**Independent Test**: un workspace de prueba con un delta depositado sin integrar y un `CLAUDE.md`
preservado distinto del render vigente; al ejecutar el hook de inicio de sesión, su salida nombra ambos
pendientes. Con nada pendiente, la salida es vacía.

**Acceptance Scenarios**:

1. **Given** un vault con el delta 0.27.0 depositado y sin el hito `## Actionability (PARA)` en su
   `CLAUDE.md`, **When** el agente inicia una sesión interactiva, **Then** el contexto de esa sesión
   incluye un aviso que nombra la versión del delta, la ruta del documento a leer y el hito que confirma
   la integración.
2. **Given** un `CLAUDE.md` del workspace preservado que difiere del render vigente, **When** el agente
   inicia sesión, **Then** el aviso indica que sus instrucciones operativas están desactualizadas, señala la
   ruta del render vigente y le indica tratarlo como autoritativo para la maquinaria del launcher hasta que
   se actualice.
3. **Given** ambos pendientes a la vez, **When** inicia sesión, **Then** recibe un solo aviso que lista los
   dos.
4. **Given** nada pendiente en ninguna capa, **When** inicia sesión, **Then** no se agrega nada a su
   contexto.

---

### User Story 2 - El CLAUDE.md del workspace se actualiza solo cuando nadie lo editó (Priority: P2)

Cuando el operador corre `--regenerate` tras un upgrade, o tras cambiar `agent.yml`, el `CLAUDE.md` del
workspace se re-renderiza igual que cualquier otro archivo derivado, siempre que no haya cambiado desde la
última vez que el launcher lo escribió. Si alguien lo editó, se respeta y se avisa.

**Why this priority**: elimina la causa del desfase en vez de solo avisarlo. En la flota medida el archivo
no tiene ediciones propias, así que preservarlo solo acumula atraso.

**Independent Test**: regenerar un workspace cuyo `CLAUDE.md` coincide con la línea base, tras cambiar la
plantilla o `agent.yml`: el archivo queda idéntico al render vigente. Repetir con un `CLAUDE.md` editado: el
archivo queda intacto y el render vigente queda disponible aparte.

**Acceptance Scenarios**:

1. **Given** un `CLAUDE.md` sin cambios desde la última escritura del launcher, **When** el operador corre
   `--regenerate` con una plantilla o un `agent.yml` distintos, **Then** `CLAUDE.md` pasa a ser el render
   vigente, la persona de `personas/<agente>.md` sigue presente y la salida de regenerate lo informa.
2. **Given** un `CLAUDE.md` con ediciones propias, **When** corre `--regenerate`, **Then** el archivo queda
   byte-idéntico, el render vigente queda disponible para comparar y el desfase se reporta.
3. **Given** un workspace sin línea base (toda la flota actual), **When** corre `--regenerate`, **Then** el
   archivo se preserva y el desfase se reporta; **When** el operador fuerza el re-render una vez, **Then**
   queda establecida la línea base y los upgrades siguientes se aplican solos.
4. **Given** un workspace sin línea base cuyo `CLAUDE.md` ya es idéntico al render vigente, **When** corre
   `--regenerate`, **Then** se adopta la línea base sin reportar desfase.

---

### User Story 3 - El aviso se apaga solo y el operador lo ve en doctor (Priority: P3)

El aviso deja de aparecer apenas el pendiente se resuelve, sin estado de "ya avisado" que mantener. Mientras
siga pendiente, `agentctl doctor` lo muestra al operador con el remedio exacto.

**Why this priority**: un aviso que no se apaga se vuelve ruido, y un aviso que solo ve el agente deja al
operador sin forma de verificar el estado.

**Independent Test**: con un pendiente, `doctor` muestra un WARN; tras resolverlo (agregar el hito, o
re-renderizar), el hook no emite nada y `doctor` muestra PASS.

**Acceptance Scenarios**:

1. **Given** el agente integró el delta (el hito está en el `CLAUDE.md` del vault), **When** inicia la
   siguiente sesión, **Then** el aviso ya no menciona ese delta.
2. **Given** el operador le pidió al agente integrar el delta antes de que existiera esta feature, **When**
   inicia sesión, **Then** no hay aviso para ese delta.
3. **Given** un pendiente en cualquier capa, **When** el operador corre `agentctl doctor` una o varias
   veces, **Then** cada corrida muestra un WARN por capa pendiente con su remedio, hasta que se resuelva.

---

### User Story 4 - Mismo comportamiento en modo local y en modo docker (Priority: P4)

Un agente local (mclaren, ferrari-admin) con el mismo estado pendiente recibe el mismo aviso que un agente
docker (donna, linus).

**Why this priority**: el hueco existe igual en ambos modos. Queda en P4 porque depende de un gate de
factibilidad en modo local (ver Assumptions); `doctor` ya cubre al operador en ambos.

**Independent Test**: el hook renderizado para cada modo, ejecutado contra el mismo estado pendiente,
produce el mismo texto de aviso salvo las rutas.

**Acceptance Scenarios**:

1. **Given** un agente local con un delta pendiente, **When** inicia una sesión desde Remote Control,
   **Then** recibe el mismo aviso que un agente docker en la misma situación.

---

### Edge Cases

- **Varios deltas acumulados** (un agente apagado durante varios upgrades): el aviso los lista todos, en
  orden ascendente de versión.
- **El agente borró el documento del delta sin integrarlo**: sigue pendiente (manda el hito, no la
  existencia del archivo); el aviso apunta a la copia del launcher.
- **Falla del hook** (sin `jq`, librería ausente en un workspace parcialmente actualizado, archivos
  ilegibles, línea base corrupta): la sesión arranca normal y no se inyecta un aviso a medias. `doctor`
  sigue reportando.
- **Sesiones de heartbeat** (aisladas, desatendidas): no reciben el aviso. Un turno sin nadie presente no
  debe ponerse a editar `CLAUDE.md` del vault.
- **Reanudación y compactación**: el aviso se inyecta en cada inicio de sesión mientras siga pendiente,
  incluidos `--continue` y la compactación. El historial reanudado puede contener avisos de inicios
  anteriores; el estado real siempre es verificable leyendo los archivos que el aviso nombra.
- **Integración larga vs. el tope de typing de Telegram** (5 minutos antes de avisar al chat que algo
  falló): el aviso no debe hacer que el agente bloquee la primera petición del operador para integrar.
  Responde primero, salvo que la petición dependa de su base de conocimiento.
- **El agente edita su propio `CLAUDE.md` del workspace**: cuenta como edición propia; se preserva y se
  avisa cuando la plantilla vuelva a cambiar.
- **Workspace recién scaffoldeado**: cero pendientes en ambas capas. El skeleton ya trae todos los hitos y
  el primer render establece la línea base.
- **Vault deshabilitado**: solo aplica la capa del workspace.
- **Aviso semanal de PARA apagado** (el default): no afecta; esta feature no depende de él.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: El sistema DEBE detectar cada delta de schema del vault que fue depositado y cuyo hito de
  integración no aparece en el `CLAUDE.md` del vault.
- **FR-002**: El sistema DEBE detectar cuándo el `CLAUDE.md` del workspace fue preservado y difiere del
  render vigente de la plantilla.
- **FR-003**: En cada inicio de la sesión interactiva del agente (arranque, reanudación, limpieza y
  compactación), si hay algo pendiente, el sistema DEBE inyectar en el contexto de esa sesión un aviso que
  nombre cada pendiente, dónde leerlo y cómo reconocer que quedó resuelto. Si no hay nada pendiente, NO
  DEBE inyectar nada.
- **FR-004**: El aviso NO DEBE llegar a las sesiones aisladas de heartbeat.
- **FR-005**: El aviso DEBE dejar de emitirse apenas el pendiente se resuelve, sin estado de "ya avisado".
- **FR-006**: El re-render automático del `CLAUDE.md` del workspace en `--regenerate` DEBE ocurrir si, y solo
  si, el archivo coincide byte a byte con su línea base, es decir, no tiene ediciones propias.
- **FR-006b**: Tras integrar a mano los cambios de la plantilla en un `CLAUDE.md` con ediciones propias,
  el agente o el operador DEBE poder confirmarlo con un solo comando, que mueve la línea base al render
  vigente y apaga el aviso.
- **FR-007**: `--regenerate` DEBE dejar disponible el render vigente de la plantilla para comparar, lo haya
  aplicado o no, y NUNCA DEBE sobrescribir un `CLAUDE.md` con ediciones propias. Las únicas excepciones son
  explícitas y preexistentes: `--force-claude-md` confirmado por el operador, y el reemplazo de 027 del
  `CLAUDE.md` del propio launcher heredado por un clon declarativo en modo local.
- **FR-008**: `agentctl doctor` DEBE mostrar una línea por capa: WARN con el remedio exacto mientras haya
  pendientes, PASS cuando esté al día. La detección NO DEBE depender de hallazgos
  cacheados del wiki-graph.
- **FR-009**: El aviso y la línea de doctor DEBEN estar disponibles en modo docker y en modo local.
- **FR-010**: Ninguna falla de esta feature DEBE impedir ni retrasar el inicio de sesión, ni abortar
  `--regenerate`.
- **FR-011**: `agent.yml` DEBE ofrecer un interruptor que desactive la inyección del aviso, activado por
  defecto y completado automáticamente en workspaces existentes.
- **FR-012**: El sistema NO DEBE depender de `features.heartbeat.review.enabled` ni alterar la detección
  ni la gracia de 14 días de `schema_delta_pending` de 037.
- **FR-013**: El sistema NUNCA DEBE escribir el `CLAUDE.md` del vault; integrar un delta sigue siendo
  tarea del agente.
- **FR-014**: El aviso DEBE estar en el idioma del usuario (`user.language`).

### Key Entities

- **Delta de schema del vault**: documento versionado que el upgrade aditivo deposita en `_templates/`
  junto a un marcador oculto `.schema-updates-<versión>.applied`. Pide agregar secciones al `CLAUDE.md` del
  vault.
- **Hito de integración**: texto literal que, presente en el `CLAUDE.md` del vault, confirma que un delta
  quedó integrado (0.27.0: `## Actionability (PARA)`). Uno por versión.
- **Render vigente**: el `CLAUDE.md` que produciría hoy la plantilla con el `agent.yml` y la persona
  actuales. Se regenera en cada `--regenerate`.
- **Línea base del CLAUDE.md**: copia del render de la plantilla que el `CLAUDE.md` del workspace
  incorpora: la que el launcher escribió por última vez, o la que el agente confirmó haber integrado a
  mano. Permite distinguir "viejo" de "editado" y muestra exactamente qué cambió la plantilla desde
  entonces.
- **Aviso de actualización**: texto que se inyecta al iniciar sesión cuando hay pendientes.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: En un agente real con ambas capas pendientes (el estado de donna o linus al 30-09-2026), la
  primera pregunta del operador sobre su sistema de conocimiento, tras el deploy, obtiene una respuesta que
  menciona la integración pendiente o ya refleja 0.27.0, sin que el operador lo haya pedido.
- **SC-002**: Con nada pendiente, el inicio de sesión agrega 0 bytes de contexto, y la verificación de
  pendientes, haya o no, termina en menos de 1 segundo.
- **SC-003**: Tras resolver un pendiente, el siguiente inicio de sesión no lo menciona y `doctor` muestra
  PASS para esa capa.
- **SC-004**: El 100 % de los `--regenerate` sobre un `CLAUDE.md` sin ediciones dejan el archivo idéntico
  al render vigente, y el 0 % sobrescribe un `CLAUDE.md` editado (verificado por tests y por mutación).
- **SC-005**: Con fallas inyectadas (dependencias ausentes, archivos ilegibles, estado de línea base
  corrupto), la sesión arranca sin aviso parcial y `--regenerate` termina con código 0.
- **SC-006**: Para el mismo estado pendiente, el aviso de modo local y el de modo docker coinciden salvo
  las rutas.
- **SC-007**: Un workspace recién scaffoldeado tiene cero pendientes en ambas capas.

## Assumptions

- **Hitos explícitos**: cada delta declara un hito literal en una tabla mantenida a mano. 0.27.0 ya lo
  declara en su propio documento; 0.8.0 no lo declara, y se adopta `wiki/normalization/`, presente en los
  tres vaults de la flota que integraron 0.8.0 (medido). Todo delta futuro debe declarar el suyo.
- **La persona vive en `personas/<agente>.md`**: medido en donna, linus y rodri-cenco-admin. Por eso el
  re-render no pierde la persona. Quien escriba directo en `CLAUDE.md` queda protegido por la línea base.
- **Remote Control ejecuta hooks `SessionStart`**: no verificado. Es un gate de factibilidad en modo local.
  Si no los ejecuta, el modo local queda cubierto solo por `doctor` y la brecha se documenta.
- **Interacción con la feature 004 de `agentic-pod-launcher-custom-config`** (inyección de las reglas de
  persona): debe escribir en `personas/<agente>.md`, no en `CLAUDE.md`. Si escribiera en `CLAUDE.md`, el
  archivo dejaría de coincidir con la línea base y el re-render automático se detendría para siempre en
  ese agente.
- **Dependencia**: requiere `037-second-brain-rag` y no puede mergearse antes que ella.
- **Fuera de alcance**: la auto-memoria y `claude-mem` (no son del launcher); el contenido de las reglas
  de persona, incluido el voseo (feature 004 de custom-config); separar estructuralmente la plantilla del
  launcher y la persona en archivos distintos; `heartbeatctl status` como superficie (doctor basta).
