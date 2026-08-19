# Feature Specification: Warm cache para MCPs fuera del catálogo

**Feature Branch**: `030-mcp-warm-cache`

**Created**: 2026-08-17

**Status**: Draft

**Input**: User description: "los MCPs fuera del catálogo no tienen warm cache" — incidente ferrari 16-08-2026 (agente donna), mismo incidente que motivó la feature 029.

## Contexto del incidente

El 16-08-2026 el agente `donna` (contenedor `agentic-pod:donna`) perdió el MCP `google-workspace`
tras un reinicio y no lo recuperó. Evidencia forense: el proceso del server estaba ausente mientras
los otros 14 MCP corrían normal; las credenciales y el entorno estaban presentes; el arranque manual
del server post-incidente levantaba en 3 s; el paquete `workspace-mcp` se descargó de PyPI **durante
el arranque del contenedor** (mtime del wheel 19:09:37–19:09:51, contra `start_services` a las
19:09:01), tardó ~50 s y el server quedó marcado como fallido antes de terminar de instalarse.

La feature 029 (ventana de handshake configurable, default 120 s) es una **mitigación**: ensancha la
ventana para que una descarga en frío alcance a completarse. Esta feature ataca la **causa raíz**: que
el paquete ya esté presente (warm cache) antes de que el agente arranque, de modo que el primer uso no
dispare descarga alguna.

Hoy el precalentamiento existe **solo** como lista hardcodeada de tres paquetes del catálogo propio.
Cualquier MCP inyectado fuera de ese catálogo — como `google-workspace`, que un overlay externo agrega
al workspace — queda expuesto a la descarga en frío en cada recreación del contenedor.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Un MCP de overlay conecta sin descarga en frío (Priority: P1)

Un operador tiene un agente con un MCP inyectado por el overlay externo (no parte del catálogo del
launcher) cuyo arranque requiere descargar un paquete la primera vez. Al recrear el contenedor del
agente, ese MCP conecta de inmediato porque su paquete ya está presente en el cache tibio; no hay
descarga en frío dentro de la ventana de handshake, y por tanto el MCP no queda muerto por el resto de
la sesión.

**Why this priority**: Es exactamente el modo de falla medido en producción (donna/`google-workspace`).
Sin esto, la única defensa es la ventana ancha de 029, que sigue pagando la descarga en cada recreación
y falla si la red está lenta o cortada. Cierra el incidente en su origen.

**Independent Test**: Recrear el contenedor de un agente con un MCP de overlay declarado, con el acceso
de red a la fuente de paquetes (PyPI/registro npm) **cortado**, y verificar que el MCP conecta igual —
prueba de que el paquete estaba tibio y no se intentó descarga.

**Acceptance Scenarios**:

1. **Given** un agente con un MCP de overlay que se instala vía descarga en el primer uso, **When** se
   recrea el contenedor con la red a la fuente de paquetes disponible, **Then** el MCP conecta sin que
   ocurra una descarga dentro de la ventana de handshake (el paquete ya estaba tibio).
2. **Given** el mismo agente, **When** se recrea el contenedor con la red a la fuente de paquetes
   **cortada**, **Then** el MCP conecta igual (no depende de la red en el arranque).
3. **Given** un agente sin ningún MCP de overlay (solo catálogo), **When** se recrea el contenedor,
   **Then** el comportamiento del catálogo propio no cambia respecto de hoy (sin regresión).

---

### User Story 2 - El precalentamiento es declarativo y general, no un hardcode por MCP (Priority: P2)

El operador puede sumar un nuevo MCP que requiere descarga sin editar la definición de la imagen ni
tocar código del launcher: el conjunto de paquetes a precalentar se resuelve de lo ya declarado para
el agente, de forma que la próxima integración no repite el mismo bug de descarga en frío.

**Why this priority**: La lista hardcodeada de hoy es la deuda que causó el incidente — cubre tres
paquetes y deja fuera todo lo demás. Un mecanismo declarativo cierra la **clase** de bug, no solo la
instancia. Es el valor de fondo; P2 porque US1 ya entrega la mitigación observable para el caso vivo.

**Independent Test**: Declarar un MCP nuevo con descarga en el primer uso (por catálogo o por overlay),
regenerar/recrear sin editar la imagen ni el código, y verificar que su paquete quedó tibio con el
mismo procedimiento que US1.

**Acceptance Scenarios**:

1. **Given** un MCP declarado que se instala por descarga, **When** se regenera y recrea el agente,
   **Then** su paquete se precalienta sin que haya hecho falta agregar una línea por-MCP a la
   definición de la imagen.
2. **Given** dos agentes con distintos conjuntos de MCPs de overlay, **When** cada uno se recrea,
   **Then** cada uno precalienta exactamente los paquetes que declaró, sin arrastrar los del otro.

---

### User Story 3 - Un precalentamiento que falla no rompe el arranque ni filtra secretos (Priority: P3)

Si un paso de precalentamiento no puede completarse (la fuente de paquetes no responde, un nombre de
paquete es inválido), el agente arranca igual y deja una traza legible de qué se precalentó y qué no;
y el precalentamiento nunca requiere ni transporta credenciales.

**Why this priority**: Un warm cache que aborta el arranque, o que exige secretos para instalar un
paquete, sería peor que el problema que resuelve. Es la red de seguridad del mecanismo. P3 porque no
entrega valor nuevo por sí solo, pero es condición para desplegar US1/US2 sin riesgo.

**Independent Test**: Forzar un fallo de precalentamiento (paquete inexistente o fuente inalcanzable en
el momento del warm) y verificar que el arranque del agente continúa, que la traza nombra el paquete
que falló, y que ningún paso de precalentamiento leyó un archivo de secretos.

**Acceptance Scenarios**:

1. **Given** un paquete declarado con un nombre inválido, **When** corre el precalentamiento, **Then**
   el arranque del agente continúa y la traza registra el paquete que no se pudo precalentar.
2. **Given** la fuente de paquetes inalcanzable durante el precalentamiento de build, **When** corre el
   warm, **Then** el resultado degrada de forma legible sin abortar el flujo, y en el arranque el MCP
   afectado se comporta como hoy (dependiente de la ventana de 029), no peor.
3. **Given** un MCP cuyo **arranque** requiere credenciales (p. ej. OAuth), **When** se precalienta su
   paquete, **Then** el precalentamiento instala el paquete sin leer ni requerir esas credenciales.

---

### Edge Cases

- **Paquete ya tibio**: si el paquete ya está presente, el precalentamiento es idempotente y no vuelve
  a descargar ni falla.
- **Cache sobre un montaje efímero**: el cache tibio debe vivir en una ubicación que **sobreviva** al
  montaje del volumen de estado en runtime; un cache escrito donde el volumen luego monta encima se
  pierde y reintroduce la descarga en frío.
- **MCP agregado después del build**: un overlay aplicado sobre un contenedor ya construido introduce
  un MCP que el build no conocía; el mecanismo debe cubrir ese caso (no solo lo conocido en build).
- **MCP remoto o sin descarga**: un MCP que no se instala por descarga (server remoto, binario ya
  presente) no necesita precalentamiento y no debe romper el paso.
- **Auto-descarga de dependencias del entorno**: el precalentamiento no debe activar la descarga
  automática de un intérprete gestionado que rompería la reproducibilidad del cache tibio.
- **Modo local**: sin imagen no hay etapa de build; el problema de cache frío existe igual y el alcance
  debe quedar definido explícitamente.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: El sistema MUST asegurar que, para cada MCP declarado de un agente cuyo arranque
  requiere obtener un paquete por descarga, ese paquete esté presente en un cache local **antes** de que
  el agente inicie sus MCPs, de modo que el primer uso no dispare descarga dentro de la ventana de
  handshake.
- **FR-002**: El mecanismo MUST cubrir los MCP **inyectados por overlay externo** (fuera del catálogo
  del launcher), no solo el conjunto del catálogo propio.
- **FR-003**: El conjunto de paquetes a precalentar MUST derivarse de lo declarado para el agente (su
  configuración efectiva de MCPs), sin exigir una entrada hardcodeada por-MCP en la definición de la
  imagen o en el código del launcher.
- **FR-004**: El cache tibio MUST persistir en una ubicación que sobreviva al montaje del volumen de
  estado en runtime (no puede quedar bajo la ruta que el volumen monta encima).
- **FR-005**: El precalentamiento MUST ser idempotente: un paquete ya tibio no se vuelve a descargar y
  no provoca fallo.
- **FR-006**: El precalentamiento MUST NOT requerir, leer ni transportar credenciales ni secretos; la
  instalación de un paquete es independiente de las credenciales que su arranque pueda necesitar.
- **FR-007**: Un fallo de precalentamiento (fuente inalcanzable, paquete inválido) MUST NOT abortar el
  arranque del agente; el flujo degrada de forma segura al comportamiento previo (dependiente de la
  ventana de handshake de 029).
- **FR-008**: El sistema MUST emitir una traza legible de qué paquetes se precalentaron y cuáles no,
  suficiente para diagnosticar un MCP que quedó sin warm.
- **FR-009**: El comportamiento del catálogo propio (los MCP ya precalentados hoy) MUST permanecer sin
  regresión: los agentes sin MCP de overlay se comportan igual que antes de esta feature.
- **FR-010**: La capacidad MUST definir su alcance en **ambos modos de despliegue** (contenedor y
  local); donde no exista etapa de imagen, el precalentamiento debe ocurrir en un momento equivalente
  (regeneración/arranque) contra un cache persistente del host.
- **FR-011**: La configuración y el resultado del precalentamiento MUST sobrevivir a una regeneración
  de los archivos derivados del agente (no dependen de una edición manual que un `--regenerate` borre).
- **FR-012**: Todo cambio de comportamiento MUST quedar documentado en el registro de cambios y, si
  toca superficie de usuario, en la documentación de usuario.

### Key Entities *(include if feature involves data)*

- **Paquete precalentable**: la unidad que un MCP declarado necesita presente antes de arrancar —
  identificada por su gestor de obtención (descarga de paquete Python vía uvx, de paquete Node vía npx)
  y su nombre. Se deriva de la declaración efectiva de MCPs del agente.
- **Cache tibio**: el almacén local persistente donde vive el paquete ya obtenido, ubicado fuera del
  punto de montaje del volumen de estado de runtime.
- **Manifiesto de precalentamiento**: el conjunto de paquetes precalentables resuelto para un agente en
  un momento dado; entrada del paso de warm y base de su traza.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Recrear el contenedor de un agente con un MCP de overlay declarado, **con la red a la
  fuente de paquetes cortada**, resulta en ese MCP conectado (0 descargas en frío en el arranque). Es
  el criterio de aceptación duro del incidente.
- **SC-002**: Sumar un MCP nuevo que requiere descarga y ponerlo tibio **no requiere editar la
  definición de la imagen ni el código del launcher** — solo declararlo por los medios ya existentes.
- **SC-003**: En un agente sin MCP de overlay, el conjunto de archivos derivados y el comportamiento de
  arranque son equivalentes a los de antes de esta feature (sin regresión verificable).
- **SC-004**: Un fallo inducido de precalentamiento deja el arranque del agente en estado funcional
  (el agente inicia) y produce una traza que nombra el paquete afectado, en el 100% de los casos
  probados.
- **SC-005**: Ningún paso de precalentamiento accede a un archivo de secretos, verificable por
  inspección del flujo de warm (0 lecturas de credenciales).
- **SC-006**: La suite de tests herméticos del repo permanece verde en las dos versiones de shell
  soportadas, sin regresión sobre la línea base previa.

## Assumptions

- **Reparto launcher / overlay (decisión de diseño central, a fijar en el plan)**: el **launcher**
  provee el *mecanismo* de warm cache (el paso que precalienta y su ubicación persistente); el
  **overlay** aporta la *declaración* de sus MCPs por los medios que ya usa (fragmentos que se mergean
  en la configuración efectiva del agente). La hipótesis de trabajo es que el mecanismo del launcher
  puede resolver la lista de paquetes desde la configuración efectiva de MCPs del agente, de modo que un
  MCP de overlay quede cubierto sin cambio en el overlay. Este reparto se **confirma en Fase 0 leyendo
  el contrato real del overlay** (`custom-apply` y sus contracts) antes de fijarlo.
- **Momento del precalentamiento (a fijar en el plan)**: la opción recomendada es precalentar en build
  lo conocido en build, con un gancho de arranque/regeneración que cubra lo que un overlay agrega
  después del build (los MCP de overlay se inyectan post-build). Se justificará contra la alternativa de
  solo-build (no cubre overlays) y solo-boot (arranque más lento).
- **Alcance de modos**: contenedor es el modo donde vive el incidente y el foco principal. Modo local
  entra en alcance para el precalentamiento en el momento equivalente (sin imagen), contra un cache
  persistente del host; su profundidad exacta se acota en el plan.
- **Restricciones técnicas heredadas** (verificadas contra el código, a respetar en el diseño): el
  cache tibio vive fuera del punto de montaje del volumen de estado; la preferencia de intérprete del
  gestor de paquetes está fijada a propósito para no auto-descargar un runtime gestionado que rompería
  el cache; instalar un paquete no requiere los secretos que su arranque sí necesita.
- El caso vivo de validación es el agente donna con `google-workspace` (paquete `workspace-mcp` vía
  uvx); el mecanismo debe ser general, pero ese es el gate de aceptación de hardware.

## Dependencies

- Complementa a la feature **029** (ventana de handshake configurable): 030 elimina la descarga en frío
  que 029 solo ensancha la ventana para tolerar. No requiere que 029 esté mergeada para funcionar, pero
  su valor se entiende en conjunto.
- Depende del **contrato del overlay externo** (`agentic-pod-launcher-custom-config`): la spec asume que
  la configuración efectiva de MCPs del agente refleja los MCP de overlay tras aplicar el overlay. Si el
  plan concluye que hace falta un cambio en el overlay, ese cambio es un follow-up en ese repo (PR
  aparte en su propio remoto), fuera del PR de esta spec contra el launcher.

## Out of Scope

- Cambiar la mecánica de inyección del overlay (cómo `custom-apply` mergea MCPs). Esta feature consume
  esa configuración; no la rediseña.
- Precalentar dependencias de arranque que **sí** requieren credenciales (p. ej. la obtención de tokens
  OAuth): eso es arranque, no instalación de paquete, y queda fuera.
- Cambiar la ventana de handshake (eso es 029).
- La guardia de `AskUserQuestion` (feature 031, spec separada).
