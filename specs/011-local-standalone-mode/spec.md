# Feature Specification: Modo agente local standalone (Linux/systemd)

**Feature Branch**: `011-local-standalone-mode`

**Created**: 2026-06-28

**Status**: Draft

**Input**: User description: modo del wizard que crea toda la base del agente directamente en el host (sin contenedor Docker) y deja una sesión de Claude Code Remote Control persistente atada al sistema operativo (Linux/systemd), como contraparte persistente del modo Docker actual. Opt-in y con advertencia explícita de seguridad.

## Resumen ejecutivo

Hoy el launcher solo sabe crear agentes dentro de contenedores Docker efímeros. Esta feature agrega un **segundo modo de despliegue, opt-in, elegido en el wizard**: en vez de un contenedor, el agente se materializa **directamente en el host Linux** y queda corriendo como una **sesión de Claude Code Remote Control siempre viva** (controlable desde claude.ai/code y la app móvil), persistida por systemd. El modo Docker actual queda **idéntico** y sigue siendo el recomendado; el modo local es la opción avanzada, con su riesgo de seguridad declarado.

Restricción que define toda la arquitectura: **Remote Control exige un token full-scope de login OAuth interactivo** (one-time por host/usuario). El token inference-only que usa el launcher hoy NO sirve para Remote Control y no existe vía headless oficial → el modo local **solo es viable en un host/usuario persistente** y requiere un paso de login manual una vez.

## Clarifications

### Session 2026-06-28

- Q: Identidad del SO bajo la que corre el agente local → A: El **usuario actual del login** (el operador). HOME y CONFIG_DIR son los de ese usuario; el agente hereda sus privilegios y secretos (amplifica el riesgo del modo local). NOTA para plan: persistir tras logout/reboot exige unit de sistema con `User=<operador>` o `systemd --user` + `loginctl enable-linger`.
- Q: ¿Cuántos agentes locales por host en v1? → A: **Uno por host** en v1 (documentado y validado), pero el naming (`--name` único), `CONFIG_DIR` y la unit se diseñan por-agente para que multi-agente sea una extensión natural luego. Límite adicional: sesiones concurrentes del plan de la cuenta.
- Q: En `--regenerate`, al cambiar de modo (docker↔local), ¿qué hacer con los artefactos del modo anterior? → A: **Avisar y dejar de regenerarlos, sin borrar** — regenera solo el set del modo actual y emite un aviso listando los huérfanos del modo previo; nunca borra archivos por su cuenta.
- Q: ¿Cómo se orquesta el login OAuth full-scope one-time? → A: **Helper guiado** (`setup.sh`/`agentctl --login`) **+ NEXT_STEPS** — el launcher genera instrucciones y un comando helper que lanza el login interactivo (tuneliza el callback por SSH en headless) y luego aplica trust + habilita el servicio.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Elegir modo y materializar el agente en el host sin Docker (Priority: P1)

Como operador que corre `./setup.sh`, el wizard me ofrece elegir el **modo de despliegue**: "contenedor Docker (recomendado)" o "local standalone (riesgo de seguridad)". Si elijo Docker, todo funciona exactamente como hoy. Si elijo local, el launcher escribe en el host la **base completa del agente** —el mismo contenido que hoy vive dentro del contenedor: CLAUDE.md, configuración MCP, skills, heartbeat, vault sembrado, configuración RAG/qmd— pero **sin** `docker-compose.yml`/`Dockerfile`, y en su lugar emite los artefactos del modo local (servicio del SO, configuración de entorno, scripts de bootstrap/healthcheck/kill-switch y los siguientes pasos). El modo elegido queda registrado en `agent.yml` como única fuente de verdad y **sobrevive a `--regenerate`**.

**Why this priority**: es el cimiento del modo local — sin la elección del wizard y el render de la base en el host, no hay agente local que persistir. Entrega valor por sí sola: deja un workspace local listo para el paso de login.

**Independent Test**: con `deployment.mode=local` en `agent.yml`, correr `./setup.sh --regenerate --non-interactive` produce la base del agente en el host con los artefactos del modo local y SIN artefactos Docker; con `deployment.mode=docker` produce exactamente lo de hoy y SIN artefactos de local. Verificable con bats host-side, sin Docker.

**Acceptance Scenarios**:

1. **Given** un wizard nuevo, **When** el operador elige el modo en el primer paso, **Then** la primera opción es "Docker (recomendado)" y la segunda "local (riesgo de seguridad)" con su advertencia visible, y la elección se persiste en `agent.yml` (`deployment.mode`).
2. **Given** `deployment.mode=docker`, **When** se renderiza/regenera, **Then** los archivos derivados son **idénticos** a los del flujo actual (no se generan artefactos de modo local).
3. **Given** `deployment.mode=local`, **When** se renderiza/regenera, **Then** se emiten la base del agente (CLAUDE.md, MCP, skills, heartbeat, vault, RAG) y los artefactos del modo local, y **no** se generan `docker-compose.yml` ni `Dockerfile`.
4. **Given** un workspace en modo local ya generado, **When** se corre `--regenerate`, **Then** el modo se preserva y los artefactos se regeneran de forma idempotente sin pérdida de configuración del usuario.

---

### User Story 2 - Sesión Remote Control persistente atada al SO (Priority: P1)

Como operador del agente local, una vez hecho el login full-scope, el sistema mantiene **siempre una sesión de Claude Code Remote Control viva** bajo mi identidad de agente, con un nombre estable y único, de modo que pueda controlar al agente desde claude.ai/code y la app móvil. Si la sesión se completa o el proceso muere, el SO la **rearranca automáticamente** manteniendo la misma identidad. El servicio **no arranca** si todavía no hay credenciales de login (queda inactivo, no en fallo), y **nunca** corre saltando las confirmaciones de Claude Code.

**Why this priority**: es el objetivo central del modo local — una presencia de agente persistente y controlable remotamente. Sin esto, el modo local sería solo archivos en disco.

**Independent Test**: con credenciales de login presentes, el servicio queda activo y emite señal de conexión; al matar el proceso, rearranca solo dentro de ~10 s; sin credenciales, el servicio queda inactivo (no en fallo). Verificable con bats host-side usando stubs del binario `claude` y de los comandos del SO.

**Acceptance Scenarios**:

1. **Given** credenciales de login full-scope presentes, **When** se habilita el servicio, **Then** queda activo y aparece señal de conexión (URL de sesión / conectado) en el journal.
2. **Given** el servicio activo, **When** el proceso de la sesión termina (se completa o se mata), **Then** el SO levanta una nueva sesión con el mismo nombre dentro de ~10 s.
3. **Given** un host sin credenciales de login, **When** se intenta iniciar el servicio, **Then** queda **inactivo** (condición de arranque no satisfecha), **no** en estado de fallo.
4. **Given** el servicio activo, **When** el operador ejecuta el kill switch (detener el servicio), **Then** la sesión se detiene y **no** rearranca hasta reactivación explícita.
5. **Given** el modo local, **When** se inicia la sesión, **Then** corre **sin** la bandera que salta confirmaciones de permisos (las acciones destructivas siguen pidiendo confirmación).

---

### User Story 3 - Salud, expiración de login y advertencia de seguridad (Priority: P2)

Como operador, necesito (a) que el wizard me **advierta del riesgo** antes de elegir el modo local y me deje claros los requisitos (MFA en la cuenta, plan compatible, login manual one-time), y (b) un **healthcheck** periódico que distinga "proceso vivo" de "conectado y controlable" y que me avise cuando el login esté **expirado o por expirar** o cuando haya error de autenticación.

**Why this priority**: el modo local rompe el aislamiento del contenedor; sin advertencias claras y sin observabilidad del login (que expira), el operador puede creer que el agente está sano cuando en realidad perdió control remoto. Es P2 porque US1+US2 ya entregan un agente local funcional; esto lo hace operable con seguridad.

**Independent Test**: el healthcheck reporta OK cuando el servicio está activo y conectado; DEGRADED cuando detecta error de auth o login expirado; WARN cuando el login está por expirar — todo verificable con stubs de los comandos del SO y un archivo de credenciales con `expiresAt` controlado.

**Acceptance Scenarios**:

1. **Given** el operador elige modo local en el wizard, **When** confirma, **Then** ve una advertencia explícita de que el modo local **no** tiene el aislamiento del contenedor, que el agente corre como **su usuario actual y hereda sus privilegios y secretos** (archivos, llaves SSH), y que quien controle la cuenta claude.ai controla el host (MFA obligatorio).
2. **Given** el servicio activo y conectado, **When** corre el healthcheck, **Then** reporta sano.
3. **Given** el journal con un error de autenticación reciente (login expirado/revocado), **When** corre el healthcheck, **Then** reporta DEGRADED (y dispara la notificación opcional si está configurada).
4. **Given** un login cuya expiración está dentro de la ventana de aviso, **When** corre el healthcheck, **Then** emite una advertencia de expiración próxima.

---

### Edge Cases

- **Login ausente al primer arranque**: el servicio no arranca y queda inactivo (no en fallo); el healthcheck lo refleja y los siguientes pasos indican cómo completar el login.
- **El login reescribe la confianza del workspace**: tras el login interactivo, la confianza del directorio de trabajo debe (re)aplicarse, o Remote Control sale con error "workspace not trusted".
- **Directorio de trabajo no confiable / raíz**: si el directorio no está marcado como confiable, el servicio entra en bucle de reinicio; la confianza debe pre-aceptarse sobre el directorio correcto (nunca `/`).
- **Herramientas faltantes** (p.ej. el utilitario que lee la expiración del login): el healthcheck debe degradar con gracia y señalarlo, no romperse en silencio.
- **Versión de Claude Code insuficiente** (< requerida por Remote Control): el bootstrap debe detectarlo y fallar con un mensaje claro antes de habilitar el servicio.
- **Plan de cuenta sin Remote Control / toggle apagado**: la sesión no conecta; el healthcheck lo refleja como no-conectado.
- **Cambio de modo en `--regenerate`**: cambiar de docker a local (o viceversa) regenera solo el set del modo actual y **emite un aviso** listando los artefactos huérfanos del modo anterior (p.ej. `docker-compose.yml` / la unit systemd), **sin borrarlos** (el borrado queda a decisión del operador).
- **Secreto de notificación**: el token de la notificación opcional nunca debe quedar visible en la línea de comandos, el repo ni el journal.

## Requirements *(mandatory)*

### Functional Requirements

**Wizard y modo (US1)**

- **FR-001**: El wizard MUST ofrecer la elección de modo de despliegue con "Docker (recomendado)" como primera opción y "local standalone (riesgo de seguridad)" como segunda, con la advertencia de seguridad visible antes de confirmar local.
- **FR-002**: El sistema MUST persistir el modo elegido en `agent.yml` como única fuente de verdad y MUST preservarlo a través de `--regenerate`.
- **FR-003**: Con modo Docker, el sistema MUST producir exactamente los mismos artefactos derivados que hoy (sin regresión) y MUST NOT emitir artefactos del modo local.
- **FR-004**: Con modo local, el sistema MUST renderizar la base completa del agente en el host (el equivalente del home/estado del agente: CLAUDE.md, configuración MCP, skills, heartbeat, vault sembrado, configuración RAG/qmd) reutilizando el motor de render existente, y MUST NOT emitir `docker-compose.yml` ni `Dockerfile`.
- **FR-005**: Con modo local, el sistema MUST emitir los artefactos del modo local: el servicio del SO, su archivo de entorno, los scripts de bootstrap/healthcheck/kill-switch, un **comando helper de login guiado** (que lanza el OAuth interactivo y luego aplica trust + habilita el servicio) y los siguientes pasos (NEXT_STEPS) con el procedimiento de login.
- **FR-005a**: En `--regenerate`, si el modo cambió respecto a la generación previa, el sistema MUST regenerar solo los artefactos del modo actual y MUST emitir un aviso listando los artefactos huérfanos del modo anterior, SIN borrarlos.
- **FR-006**: Todos los artefactos del modo local MUST renderizarse desde `agent.yml` (single source) y MUST sobrevivir `--regenerate` de forma idempotente.

**Persistencia Remote Control (US2)**

- **FR-007**: El sistema MUST mantener siempre una sesión de Claude Code Remote Control viva mientras el modo local esté habilitado y exista login válido, identificada por un nombre estable y único por agente.
- **FR-008**: El servicio MUST rearrancar automáticamente la sesión cuando esta se complete o el proceso muera, conservando la misma identidad, dentro de una ventana corta (~10 s).
- **FR-009**: El servicio MUST NOT arrancar si no hay credenciales de login presentes, quedando **inactivo** (no en estado de fallo).
- **FR-010**: El sistema MUST asegurar que el directorio de trabajo de la sesión esté marcado como confiable, de forma idempotente, preservando el resto de la configuración, y MUST (re)aplicarlo **después** del login (que resetea esa confianza).
- **FR-011**: El sistema MUST pre-sembrar el estado de onboarding **antes** del login sin sobrescribirlo si ya existe.
- **FR-012**: La sesión MUST correr **sin** la bandera que salta confirmaciones de permisos.
- **FR-013**: El sistema MUST proveer un kill switch que detenga la sesión y evite el rearranque hasta reactivación explícita, por un canal independiente de la sesión de Claude.
- **FR-014**: El bootstrap MUST verificar que la versión de Claude Code cumple el mínimo requerido por Remote Control y MUST fallar con mensaje claro si no.

**Salud y seguridad (US3)**

- **FR-015**: El healthcheck MUST distinguir tres estados: proceso activo, conectado/controlable, y autenticación válida/expirada; y MUST reportar DEGRADED ante error de auth o login expirado, WARN ante expiración próxima, y OK en caso sano.
- **FR-016**: El healthcheck MUST degradar con gracia (no romperse) cuando falte una herramienta auxiliar o el archivo de credenciales.
- **FR-017**: El sistema MUST poder ejecutar el healthcheck de forma periódica desatendida.
- **FR-018**: El sistema MUST soportar una notificación opcional ante fallo/degradación cuyo secreto NUNCA quede expuesto en la línea de comandos, el repositorio ni el journal.
- **FR-019**: El sistema MUST excluir del control de versiones las credenciales de login y cualquier archivo de secretos del modo local.
- **FR-020**: La documentación generada (NEXT_STEPS) MUST dejar explícitos los requisitos del modo local: MFA en la cuenta, plan compatible con Remote Control, y el login interactivo one-time.

**Identidad y alcance**

- **FR-021**: El sistema MUST ejecutar el agente local bajo el **usuario actual del login** (el operador): HOME es el de ese usuario y `CLAUDE_CONFIG_DIR=<workspace>/.state/.claude` (el campo `claude.config_dir` de agent.yml es docker-only y se ignora en local — C1). La persistencia tras logout/reboot se garantiza con una **unit de sistema** (`/etc/systemd/system/agent-<name>.service`) con `User=<operador>` (v1; `systemd --user`+linger queda como follow-up — A1). El sistema MUST advertir que, con esta identidad, el agente hereda los privilegios y secretos del usuario.
- **FR-022**: v1 MUST soportar **un (1) agente local por host**, documentado y validado; el nombre de sesión (`--name` único), el directorio de configuración y la unidad MUST diseñarse por-agente para que multi-agente sea una extensión futura sin reescritura. El número de agentes vivos queda además limitado por las sesiones concurrentes del plan de la cuenta.

### Key Entities *(include if feature involves data)*

- **Modo de despliegue** (`deployment.mode`): valor en `agent.yml` que selecciona docker | local; única fuente de verdad de la ramificación.
- **Base del agente en el host**: el conjunto de archivos que hoy vive dentro del contenedor (CLAUDE.md, configuración MCP, skills, heartbeat, vault, RAG/qmd) materializado en el directorio del agente en el host.
- **Servicio de sesión persistente**: la unidad del SO que mantiene viva la sesión Remote Control (nombre estable, política de rearranque, condición de credenciales, directorio de trabajo confiable, archivo de entorno sin API key).
- **Credenciales de login full-scope**: el archivo de credenciales (con su fecha de expiración) producido por el login OAuth interactivo; secreto, fuera del repo, reutilizable.
- **Estado de confianza del workspace**: marca por-directorio que Remote Control exige para arrancar sin TTY.
- **Healthcheck**: rutina periódica que evalúa actividad, conexión y expiración del login y reporta OK/WARN/DEGRADED.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Un operador puede pasar de "elegí modo local en el wizard" a "agente local controlable remotamente" siguiendo los NEXT_STEPS, con un único paso manual (el login OAuth one-time) y sin editar archivos a mano.
- **SC-002**: Elegir modo Docker produce un resultado byte-idéntico al flujo actual (cero regresión): la suite host existente sigue verde.
- **SC-003**: En modo local, tras un reinicio del proceso de la sesión (o un `kill -9`), el agente vuelve a estar conectado en ≤ ~10 s sin intervención.
- **SC-004**: Sin credenciales de login, el servicio queda inactivo (no en fallo) en el 100% de los arranques, y el healthcheck lo reporta correctamente.
- **SC-005**: El healthcheck detecta y reporta como DEGRADED el 100% de los casos de login expirado o error de autenticación inyectados en pruebas, y como WARN los de expiración próxima.
- **SC-006**: Ningún secreto (credenciales de login, token de notificación) aparece en el repositorio, la línea de comandos de procesos, ni el journal, en ninguna ruta del modo local.
- **SC-007**: `--regenerate` preserva el modo y es idempotente: una segunda regeneración sin cambios no altera los artefactos.

## Assumptions

- **OS objetivo**: la persistencia del modo local es **Linux con systemd**; macOS/launchd queda explícitamente fuera de alcance (follow-up). Decisión confirmada con el usuario.
- **Alcance de la feature**: un solo spec cubre US1 (scaffolding local) + US2 (persistencia remote-control) + US3 (salud/seguridad). Decisión confirmada con el usuario.
- **Autenticación full-scope**: el login OAuth es interactivo y manual, una vez por host/usuario; no existe vía headless oficial. El launcher provee un **comando helper guiado** (`setup.sh`/`agentctl --login`) que lanza el login interactivo (tuneliza el callback por SSH en headless) y luego aplica el trust del workspace y habilita el servicio; NEXT_STEPS documenta el procedimiento. (Resuelto en Clarifications.)
- **Reutilización del render**: el modo local reusa el motor de render y las plantillas existentes para la base del agente; solo cambia el set de artefactos de despliegue (servicio del SO en vez de compose/Dockerfile).
- **Requisitos de cuenta/herramientas**: cuenta claude.ai con plan compatible y Remote Control habilitado, MFA activo, versión mínima de Claude Code, y el utilitario de lectura de expiración disponible en el host (lo verifica/instala el bootstrap).
- **Modo Docker intacto**: la opción contenedor sigue siendo la recomendada y no cambia su comportamiento.
- **Directorio de trabajo confiable**: por defecto es el directorio del workspace del agente (nunca `/`); su alcance fino se afina en clarify.
- **Disciplina de release**: CHANGELOG + bump de VERSION; test-first host-side; los cambios que toquen el árbol Docker exigen DOCKER_E2E verde (el modo docker no debe romperse).

## Out of Scope

- Soporte macOS/launchd (follow-up).
- Cambiar el comportamiento del modo Docker actual.
- Automatizar el login OAuth full-scope (no hay vía headless oficial).
- Rediseñar RAG/qmd, backups, canal Telegram, catálogo de plugins, o el flujo de auth del modo docker.
