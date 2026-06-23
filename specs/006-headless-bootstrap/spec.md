# Feature Specification: Headless bootstrap — token auth, marketplace, onboarding

**Feature Branch**: `006-headless-bootstrap`

**Created**: 2026-06-22

**Status**: Draft

**Input**: Un agente recién scaffoldeado por el launcher no llega a operar sin intervención: el `/login` interactivo de Claude Code completa el OAuth del lado servidor ("Login successful") pero **no persiste** el credential en el contenedor headless (incoherencia de cache de VirtioFS sobre el bind-mount `./.state:/home/agent` para `~/.claude`), revirtiendo a "Not logged in" en cada arranque. Validado en el agente de prueba `rodri-cenco-admin` que el fix de autenticación es usar `CLAUDE_CODE_OAUTH_TOKEN` (de `claude setup-token`) en el `.env`, que docker-compose ya inyecta vía `env_file`; claude autentica por entorno (`claude -p` → READY, sin 401) sin depender de la persistencia de `~/.claude`. Al autenticar de verdad emergieron gaps de bootstrap que el login roto venía ocultando: el marketplace oficial no se registra (ningún plugin instala, el canal nunca engancha) y el onboarding de primer arranque (theme picker + trust) bloquea la sesión headless.

## User Scenarios & Testing *(mandatory)*

El actor principal es un **operador** que scaffoldea un agente con el launcher y lo levanta en su Mac (Docker Desktop, VirtioFS), esperando que arranque operativo sin tener que adjuntarse a una sesión interactiva.

### User Story 1 - Arrancar un agente autenticado sin `/login` interactivo (Priority: P1)

El operador scaffoldea un agente, provee un token de autenticación headless durante el wizard, y al levantar el contenedor el agente queda autenticado **sin que nadie ejecute `/login`**. El supervisor en contenedor reconoce el token y no cae al flujo de `/login` ni dispara reinicios de sesión espurios.

**Why this priority**: Es el corazón del feature y el MVP. Sin esto, el agente no autentica de forma estable (el `/login` interactivo no persiste bajo VirtioFS) y "pide login a cada rato". Entrega valor por sí solo: un agente que arranca logueado y se mantiene logueado.

**Independent Test**: Scaffoldear con token provisto → `up` → el agente responde a una interacción sin pedir login; scaffoldear sin token → el path `/login` interactivo se preserva como fallback.

**Acceptance Scenarios**:

1. **Given** un `.env` con `CLAUDE_CODE_OAUTH_TOKEN` válido, **When** el contenedor arranca, **Then** claude autentica por entorno y el supervisor NO inicia el `bare-claude` que dispara `/login`, sino que procede a instalar plugins / enganchar el canal.
2. **Given** el token presente en el entorno, **When** el supervisor corre su loop de vigilancia, **Then** la detección de aparición de credential ("auth flip") NO dispara un reinicio de sesión espurio (el token no escribe `.credentials.json`).
3. **Given** un agente scaffoldeado **sin** token en el `.env`, **When** arranca, **Then** el comportamiento actual (`/login` interactivo) se preserva sin regresiones.
4. **Given** el wizard de scaffold, **When** el operador deja el paso de token vacío, **Then** el scaffold procede sin token y sin error (path interactivo).

---

### User Story 2 - Los plugins y el canal se instalan en arranque headless (Priority: P2)

Con el agente autenticado por token, el marketplace oficial se registra automáticamente en el arranque y los plugins oficiales (incluido el plugin del canal, p. ej. Telegram) se instalan, de modo que el canal se engancha sin intervención.

**Why this priority**: Sin el marketplace registrado, ningún plugin instala y el canal nunca funciona — el agente autentica pero queda mudo. Depende de US1 (auth) y entrega el valor "agente operativo con canal".

**Independent Test**: Con auth por token, al arrancar, el listado de marketplaces incluye el oficial y el plugin del canal obtiene su sentinel de instalación.

**Acceptance Scenarios**:

1. **Given** un agente autenticado y el marketplace oficial no registrado, **When** arranca, **Then** el supervisor registra el marketplace oficial de forma idempotente **antes** de instalar plugins.
2. **Given** el marketplace registrado, **When** se instalan los plugins oficiales, **Then** cada uno obtiene su sentinel de instalación y el canal queda enganchado.
3. **Given** el marketplace ya registrado, **When** el supervisor re-corre en un respawn posterior, **Then** no re-registra (idempotente, sin ruido ni reintentos desperdiciados).

---

### User Story 3 - La sesión headless no se bloquea en el onboarding (Priority: P3)

El primer arranque no queda atascado en el selector de tema ni en el diálogo de "trust folder"; esos prompts están pre-resueltos para que la sesión avance al estado operativo automáticamente.

**Why this priority**: Aunque el agente autentique, el picker de onboarding bloquea la sesión headless (nadie lo responde por chat). Pre-sembrar el onboarding desbloquea el arranque desatendido.

**Independent Test**: Primer arranque de un agente nuevo → la sesión alcanza el estado operativo sin intervención (no se queda en el theme picker ni en el trust dialog).

**Acceptance Scenarios**:

1. **Given** un agente sin estado de onboarding previo, **When** arranca por primera vez, **Then** el tema y la confirmación de trust del folder están pre-resueltos y la sesión no se bloquea.
2. **Given** que el archivo de settings no existe, **When** arranca, **Then** se crea con las preconfiguraciones headless (modo auto, skip del prompt de permisos) desde el primer arranque.

---

### User Story 4 - El log del supervisor distingue "marketplace no encontrado" de "no autenticado" (Priority: P4)

Cuando un plugin no instala porque el marketplace no está registrado, el log lo reporta como tal, en vez del mensaje genérico "not authenticated yet or install failed" que conflaciona ambas causas.

**Why this priority**: Diagnosticabilidad. El mensaje engañoso costó tiempo real de diagnóstico. Es bajo porque no bloquea la operación, solo la observabilidad.

**Independent Test**: Forzar un install con marketplace ausente → el log reporta una causa distinguible de "no autenticado".

**Acceptance Scenarios**:

1. **Given** un install que falla por marketplace ausente, **When** el supervisor lo registra, **Then** el log distingue esa causa de "no autenticado" y no la clasifica como skip-por-auth.

---

### Edge Cases

- **Token presente pero inválido/expirado**: claude responde `401`; el supervisor NO debe entrar en loop de `/login` (no hay credential interactivo que recolectar) y el fallo de auth debe ser **visible** (no enmascarado como "marketplace not found" ni como "not authenticated yet").
- **Token presente Y un `.credentials.json` de un `/login` interactivo previo**: el reinicio por "auth flip" NO debe dispararse (cubierto por US1, escenario 2).
- **Registro del marketplace requiere red** (git clone) sobre el bind-mount VirtioFS: un clone lento o fallido debe tolerarse (no bloquear ni crashear el supervisor; reintento idempotente en el próximo tick).
- **Backup de identidad en modo partial** (sin recipient SSH): el `.env` se respalda en **texto plano** al fork; un token embebido viaja plano — debe advertirse en la documentación.
- **Las keys de onboarding o el slug del marketplace cambian entre versiones de claude**: si no coinciden con la versión pineada, el pre-seed/registro debe degradar de forma visible (fail-loud o version-guard), nunca romper en silencio.

## Requirements *(mandatory)*

### Functional Requirements

Autenticación headless (US1):

- **FR-001**: El scaffold MUST hacer descubrible la autenticación headless: el `.env` generado incluye un placeholder `CLAUDE_CODE_OAUTH_TOKEN=` (vacío) y la documentación de próximos pasos (en/es) instruye generar el token con `claude setup-token` en el host y pegarlo en el `.env` antes de levantar el contenedor; el path `/login` se preserva como fallback. *(Decisión de implementación: placeholder + docs en lugar de un prompt interactivo del wizard, para no desfasar los ~16 tests que alimentan `setup.sh` con respuestas en orden fijo — mismo resultado funcional, menor superficie de cambio.)*
- **FR-002**: El `.env` generado MUST incluir la línea `CLAUDE_CODE_OAUTH_TOKEN=` (placeholder vacío) con permisos `0600` para que el operador pegue el token; el valor del token NUNCA se hardcodea en el template, el `.env` ni el `.env.example`.
- **FR-003**: El `.env.example` generado MUST advertir la variable `CLAUDE_CODE_OAUTH_TOKEN` (sin valor) para descubribilidad.
- **FR-004**: El token MUST permanecer fuera de `agent.yml` y de cualquier log; vive únicamente en el `.env` (y en el backup de identidad cifrado).
- **FR-005**: Cuando `CLAUDE_CODE_OAUTH_TOKEN` está presente en el entorno del contenedor, el supervisor MUST NOT iniciar el `bare-claude` que dispara `/login`, y MUST proceder hacia la instalación de plugins / enganche del canal.
- **FR-006**: Con el token presente, la detección de "auth flip" MUST NOT disparar un reinicio de sesión espurio.
- **FR-007**: La documentación de próximos pasos (en y es) MUST describir el path headless por token como recomendado y mantener el `/login` interactivo como fallback.

Marketplace / plugins (US2):

- **FR-008**: En el arranque, **antes** de instalar plugins, el supervisor MUST registrar el marketplace oficial de forma idempotente (no re-registrar si ya existe) para que los plugins oficiales puedan instalarse.
- **FR-009**: El registro del marketplace MUST tolerar fallos transitorios (red/clone) sin bloquear ni crashear el supervisor, reintentando de forma idempotente.

Onboarding (US3):

- **FR-010**: En el primer arranque headless, el onboarding interactivo (selección de tema y confirmación de trust del folder) MUST estar pre-resuelto para que la sesión no se bloquee.
- **FR-011**: Las preconfiguraciones headless (modo auto, skip del prompt de permisos) MUST aplicarse desde el primer arranque, creando el archivo de settings si no existe.

Diagnóstico (US4):

- **FR-012**: Cuando un plugin no instala por marketplace no registrado, el supervisor MUST registrar una causa distinguible de "no autenticado".

Transversal:

- **FR-013**: Todos los cambios MUST sobrevivir `./setup.sh --regenerate` (derivados desde `agent.yml`/templates); ningún archivo derivado MUST requerir edición a mano para persistir.
- **FR-014**: Los valores concretos dependientes de la versión de claude (el slug del marketplace oficial y las keys de onboarding del config) MUST verificarse contra la versión pineada antes de fijarse; si no coinciden, el comportamiento MUST degradar de forma visible (fail-loud / version-guard), no romper en silencio.

### Key Entities

- **`CLAUDE_CODE_OAUTH_TOKEN`**: credential de larga duración de Claude (producido por `claude setup-token`). Secreto. Reside en el `.env` del workspace (0600, gitignored) y en el backup de identidad cifrado. Nunca en `agent.yml` ni en logs.
- **Marketplace oficial (`claude-plugins-official`)**: registro desde el cual se instalan los plugins oficiales, incluido el plugin del canal. Su slug exacto se verifica contra la versión pineada.
- **Estado de onboarding**: preferencias de primer arranque (tema, trust del folder) más las preconfiguraciones headless (modo auto, skip del prompt de permisos). Las keys exactas se verifican contra la versión pineada.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Un agente recién scaffoldeado con token provisto arranca autenticado y responde a una interacción **sin que nadie ejecute `/login`**.
- **SC-002**: Tras el arranque, el canal queda enganchado sin intervención manual (los plugins oficiales instalan correctamente).
- **SC-003**: El primer arranque no requiere intervención humana para superar el onboarding (no se bloquea en el theme picker ni en el trust dialog).
- **SC-004**: Un agente scaffoldeado **sin** token conserva el comportamiento actual (path `/login`) sin regresiones.
- **SC-005**: La suite `bats` por defecto (sin Docker) queda verde, con cobertura nueva que falla antes del cambio y pasa después.
- **SC-006**: El secreto del token no aparece en `agent.yml`, ni en `.env.example` con valor, ni en ningún log.

## Assumptions

- `claude setup-token` está disponible en la versión pineada (verificado: 2.1.170) y produce un token de larga duración usable como `CLAUDE_CODE_OAUTH_TOKEN` (validado empíricamente: `claude -p` → READY, sin 401).
- docker-compose ya inyecta el `.env` del workspace vía `env_file`; no se requieren cambios de compose para transportar el token al entorno del contenedor.
- El operador tiene una suscripción Claude activa (`setup-token` la requiere).
- El slug exacto del marketplace oficial y las keys exactas de onboarding del config se determinan **empíricamente** en la fase de plan/research contra claude 2.1.170; no se inventan.
- La incoherencia residual de `~/.claude` bajo VirtioFS se **acepta en v1** (el login por token no depende de ella); la persistencia coherente de plugins/sesiones es un feature posterior.

## Out of Scope

- Mover `~/.claude` a un Docker named volume para resolver la incoherencia de VirtioFS — reintroduce el regression "`docker compose down -v` borra el login" que PR #3 eliminó deliberadamente y detacha `.claude` del modelo de backup/identidad.
- Persistencia coherente de plugins/sesiones bajo VirtioFS más allá del login.
- Rotación de los secretos comprometidos del `.env` del agente de prueba `rodri-cenco-admin` (responsabilidad operativa del usuario).
