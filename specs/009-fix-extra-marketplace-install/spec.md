# Feature Specification: Instalación al boot de plugins de marketplaces de terceros

**Feature Branch**: `009-fix-extra-marketplace-install`

**Created**: 2026-06-23

**Status**: Draft

**Input**: Reparar la instalación al boot de plugins provenientes de marketplaces de terceros (no oficiales) en el supervisor del agente, y asegurar cobertura DOCKER_E2E para ese camino. Descubierto durante la reinstalación declarativa del agente `rodri-cenco-admin` (launcher v0.4.2): de 6 plugins configurados, 5 se autoinstalaron al boot pero `claude-mem@thedotmack` no. Root cause confirmado con evidencia runtime (log del supervisor) y análisis del código.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Un plugin de marketplace de terceros se instala al boot (Priority: P1)

Un operador scaffolda un agente cuyo `agent.yml` declara un plugin que vive en un marketplace de terceros (no `@claude-plugins-official`) — por ejemplo `claude-mem@thedotmack`. Tras `docker compose build` + `up`, el agente bootea y, sin ninguna intervención manual, ese plugin queda instalado y habilitado igual que los plugins del marketplace oficial.

**Why this priority**: Es el defecto central. Hoy el plugin de un marketplace de terceros queda permanentemente ausente tras el boot (el operador debe instalarlo a mano con `claude plugin install`). Un agente declara sus plugins en `agent.yml` como fuente de verdad; que uno se omita silenciosamente rompe esa promesa y la observabilidad (no figura como fallo registrado, solo como "skip").

**Independent Test**: Con un `agent.yml` que declara un plugin de un marketplace de terceros, bootear el contenedor y verificar — sin acción manual — que el plugin aparece como instalado/habilitado, y que el log del supervisor reporta su instalación (no un "skip"). Validable end-to-end con `DOCKER_E2E=1`.

**Acceptance Scenarios**:

1. **Given** un `agent.yml` que declara un plugin de un marketplace de terceros además de plugins oficiales, **When** el contenedor bootea hasta estado estable, **Then** todos los plugins declarados (oficiales y de terceros) quedan instalados y habilitados, sin intervención manual.
2. **Given** el mismo agente, **When** se inspecciona el log del supervisor, **Then** el plugin de terceros figura como instalado (no como "skipped: marketplace not registered yet").
3. **Given** un marketplace de terceros que el supervisor aún no ha resuelto, **When** se intenta instalar su plugin, **Then** el supervisor primero asegura/confirma el registro del marketplace y luego instala, en el mismo boot.

---

### User Story 2 - El boot degrada con gracia ante un marketplace de terceros lento o caído (Priority: P2)

Si el registro o la resolución de un marketplace de terceros falla o tarda (red lenta, repositorio inaccesible, CLI colgado), el supervisor no se cuelga ni queda en estado degradado: continúa el boot, arranca el watchdog y deja registrado el fallo de forma observable, sin filtrar secretos.

**Why this priority**: El path de registro/instalación corre en el boot, antes de que el watchdog esté activo. Una llamada sin acotar a un marketplace inaccesible podría bloquear el arranque (mismo modo de falla que motivó el fix 008). El agente debe priorizar bootear operativo por sobre completar la instalación de un plugin no esencial.

**Independent Test**: Simular (host-side) un marketplace/CLI que cuelga o falla y verificar que la rutina de aseguramiento retorna acotada (no cuelga), permanece fail-silent (no aborta el boot) y registra el resultado. Verificable sin Docker.

**Acceptance Scenarios**:

1. **Given** un marketplace de terceros cuyo registro cuelga, **When** el supervisor lo procesa en el boot, **Then** la operación está acotada en el tiempo y el boot continúa hasta el watchdog.
2. **Given** un marketplace de terceros que no puede resolverse tras los reintentos acotados, **When** el boot termina, **Then** el agente queda operativo (canal/auth) y el fallo del plugin queda registrado de forma observable, sin secretos en el log ni en el estado.

---

### User Story 3 - Cobertura E2E del camino de marketplaces de terceros (Priority: P3)

El equipo de mantenimiento cuenta con una prueba de integración (DOCKER_E2E) que ejercita explícitamente la instalación al boot de un plugin de un marketplace de terceros, de modo que una regresión en este camino se detecte antes de mergear.

**Why this priority**: El defecto pasó inadvertido porque la suite E2E solo ejercitaba `@claude-plugins-official`. Sin cobertura del camino de terceros, una regresión futura reaparecería silenciosamente. Cierra el hueco de proceso, no solo el de código.

**Independent Test**: Correr la suite `DOCKER_E2E=1` y constatar que existe (y pasa) un caso que declara un plugin de marketplace de terceros y verifica su instalación al boot.

**Acceptance Scenarios**:

1. **Given** la suite DOCKER_E2E, **When** se ejecuta, **Then** incluye un caso que bootea un agente con un plugin de marketplace de terceros y afirma su instalación.
2. **Given** una regresión que reintroduzca el skip permanente, **When** corre la suite E2E, **Then** ese caso falla.

---

### Edge Cases

- **Marketplace de terceros inaccesible**: el plugin no se instala, pero el agente bootea operativo y el fallo queda registrado de forma observable (no un "skip" silencioso permanente).
- **Múltiples marketplaces de terceros**: cada uno se asegura/confirma de forma independiente antes de instalar sus plugins; el fallo de uno no impide la instalación de plugins de otro marketplace ya resuelto.
- **Marketplace ya registrado** (reboot): la rutina es idempotente — no re-registra ni rompe si el marketplace ya está resuelto.
- **Sin plugins de terceros declarados**: el comportamiento del camino oficial no cambia (cero regresión para agentes que solo usan `@claude-plugins-official`).
- **CLI sin `timeout` disponible** (entorno host de test): la lógica degrada a la llamada directa sin romper (paralelo al patrón del fix 008).

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: El supervisor MUST asegurar que cada marketplace de terceros declarado quede efectivamente resuelto por la CLI (no solo declarado en la configuración) ANTES de intentar instalar sus plugins, con una confirmación verificable del registro — análoga a la que ya existe para el marketplace oficial.
- **FR-002**: Tras asegurar el registro, el supervisor MUST (re)intentar la instalación de los plugins de terceros dentro del mismo boot, de modo que un plugin de terceros declarado quede instalado sin intervención manual.
- **FR-003**: El "skip por marketplace no registrado aún" NO debe quedar como estado terminal en operación normal: el plugin afectado MUST instalarse una vez su marketplace esté resuelto, sin depender de un respawn de la sesión interactiva.
- **FR-004**: Toda llamada a la CLI en este camino de boot MUST estar acotada en el tiempo (degradando a llamada directa si el mecanismo de acotación no está disponible) y permanecer fail-silent: nunca colgar el supervisor antes de que arranque el watchdog (Principio IV).
- **FR-005**: La rutina MUST ser idempotente: en reboots, no re-registrar de forma destructiva ni fallar si el marketplace ya está resuelto.
- **FR-006**: Los fallos residuales de instalación de plugins de terceros MUST quedar registrados de forma observable y sin secretos (consistente con el registro de fallos existente).
- **FR-007**: El cambio MUST preservar el comportamiento del camino oficial (`@claude-plugins-official`): cero regresión para agentes sin plugins de terceros.
- **FR-008**: La suite host-side por defecto (`bats tests/`, sin Docker) MUST cubrir, con tests escritos antes de la implementación: (a) el aseguramiento/confirmación del registro de un marketplace de terceros, y (b) que un plugin de terceros no quede en skip permanente; y MUST quedar verde.
- **FR-009**: La suite `DOCKER_E2E` MUST incluir cobertura del camino de marketplaces de terceros (instalación al boot de un plugin de terceros) y MUST pasar tras el cambio.
- **FR-010**: El cambio MUST sobrevivir `--regenerate`, preservar el modelo de menor privilegio del contenedor (Principio II) y respetar la disciplina de versionado (CHANGELOG + bump `VERSION` 0.4.2 → 0.4.3), sin introducir pins de versión duplicados (Principio VI).

### Key Entities

- **Marketplace de terceros**: una fuente de plugins distinta del marketplace oficial, declarada indirectamente por los plugins del `agent.yml` (cada plugin de terceros referencia su marketplace). Estados relevantes: *declarado* (conocido por la config) vs *resuelto* (la CLI puede instalar desde él).
- **Plugin de terceros**: un plugin del `agent.yml` cuyo origen es un marketplace de terceros. Resultado esperado tras el boot: *instalado/habilitado* o, ante fallo persistente, *fallo registrado* (nunca *skip silencioso permanente*).
- **Registro de fallos de instalación**: el artefacto observable existente donde se anotan los plugins que no pudieron instalarse, sin secretos.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Tras un boot limpio de un agente que declara N plugins (incluyendo al menos uno de un marketplace de terceros), el 100% de los plugins declarados quedan instalados sin intervención manual.
- **SC-002**: En el log del supervisor de ese boot, los plugins de terceros figuran como instalados; no aparece ningún "skip por marketplace no registrado" como resultado final.
- **SC-003**: Ante un marketplace de terceros que cuelga, el supervisor completa el boot y arranca el watchdog dentro de un límite acotado (sin bloqueo indefinido).
- **SC-004**: La suite host-side por defecto queda en 0 fallas; la suite `DOCKER_E2E` queda en 0 fallas e incluye un caso que ejercita el camino de marketplaces de terceros.
- **SC-005**: Cero regresión para agentes que solo usan el marketplace oficial (su camino de boot e instalación de plugins permanece idéntico).

## Assumptions

- El enfoque de solución será análogo al ya probado para el marketplace oficial (asegurar el registro con una confirmación verificable y una llamada acotada en el tiempo, fail-silent), aplicado de forma genérica a cualquier marketplace de terceros declarado — no específico de `thedotmack`/`claude-mem`.
- "Marketplace de terceros" abarca cualquier origen no oficial declarado por los plugins del `agent.yml`; el fix no privilegia un proveedor concreto.
- Los reintentos de instalación son acotados (presupuesto finito), consistentes con el mecanismo de reintento ya existente; no se introduce reintento indefinido.
- La instalación manual de `claude-mem` ya realizada en el agente vivo `rodri-cenco-admin` es una operación puntual y queda fuera del alcance del cambio de código.
- Se reutiliza la infraestructura de tests existente: stubs de la CLI host-side y, en macOS (donde el mecanismo de acotación no existe), un shim en PATH, como en el fix 008.
- Fuera de alcance: rediseñar el flujo de auth/login, cambiar el contrato del canal Telegram, rediseñar el catálogo de plugins, y la rotación de secretos del agente de prueba.
