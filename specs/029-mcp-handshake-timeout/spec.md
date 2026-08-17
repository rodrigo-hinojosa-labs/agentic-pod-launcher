# Feature Specification: Ventana de handshake MCP configurable (docker + local)

**Feature Branch**: `029-mcp-handshake-timeout`

**Created**: 2026-08-17

**Status**: Draft

**Input**: La ventana de handshake que Claude Code aplica al arrancar un MCP server no es configurable. Un MCP cuyo primer arranque incluye una descarga en frío (p.ej. un wheel de PyPI que baja durante el boot del contenedor) tarda más que esa ventana, el handshake expira, el server se marca como failed y Claude Code NO lo reintenta: queda muerto por el resto de la vida de la sesión. Hacer la ventana configurable por el flujo declarativo normal del launcher, con un default más generoso que el actual, en modo docker y en modo local.

## Contexto

Claude Code arranca cada MCP server declarado en `.mcp.json` durante el inicio de la sesión y espera a que complete su handshake dentro de una ventana de tiempo. Si el server no responde dentro de ese plazo, Claude Code lo marca como fallido y **no lo reintenta durante el resto de la vida de la sesión**. No hay recuperación automática: el MCP queda muerto hasta que se reinicia la sesión completa (en docker, un `docker restart`; en local, un `systemctl restart` de la unit).

El launcher ya identificó y documentó este modo de falla, pero solo lo mitigó para su propio catálogo. `docker/Dockerfile:105-113` explica el mecanismo: sin pre-instalar los MCP basados en `uvx`, la primera invocación de cada uno dispara una descarga de PyPI **dentro de la ventana de handshake**; el handshake expira y el server se marca failed antes de que termine el install. La mitigación (`uv tool install` de `mcp-atlassian`, `mcp-server-fetch`, `mcp-server-time` en `docker/Dockerfile:122-124`) es una lista hardcodeada: cualquier MCP fuera de ella queda expuesto.

**Bug medido en hardware vivo** (ferrari, Raspberry Pi 5, 2026-08-17, agente `donna`, contenedor `agentic-pod:donna`): tras un reinicio, el MCP `google-workspace` (inyectado por la herramienta de overlay externa `custom-apply`, no por el catálogo del launcher) quedó muerto. El agente le dijo al usuario durante ~40 minutos que la conexión "todavía no reconecta, puede tardar un poco en volver sola" — nunca iba a volver. Evidencia forense (medida, no inferida):

| Chequeo | Resultado |
|---|---|
| Proceso `workspace-mcp` en el contenedor | Ausente. Los otros 14 MCP corriendo normal |
| Credenciales `/workspace/.custom/gcreds/<email>.json` | Presentes, 16-08-2026 18:03 |
| Env `GOOGLE_OAUTH_*` en el proceso `claude` (`/proc/<pid>/environ`) | Todas presentes |
| Arranque manual del server post-incidente | Levanta en **3 s** |
| `/opt/uv/cache/wheels-v6/pypi/workspace-mcp/1.24.1-py3-none-any` (mtime) | 19:09:37–19:09:51 |
| `docker logs` — `start_services` | 19:09:01 |

El wheel se descargó de PyPI **durante el arranque del contenedor**, tardó ~50 s, y el server quedó marcado como fallido antes de terminar de instalarse. Con el cache caliente arranca en 3 s. Un `docker restart donna` lo resolvió al instante (el segundo arranque ya encontró el wheel en cache). La causa raíz es genérica: cualquier MCP —del catálogo o de un overlay— cuyo primer arranque exceda la ventana de handshake sufre el mismo destino silencioso.

**Alcance: ambos modos, docker y local.** El proceso `claude` corre en los dos: en docker dentro del contenedor (el env llega por `env_file`/`environment` del compose), en local bajo systemd (el env llega por el `EnvironmentFile` de la unit de sesión). La ventana de handshake es una propiedad del binario de Claude Code, no del supervisor, así que ambos modos la necesitan. A diferencia de la feature 026 (watchdog del channel, docker-only, que usó una variable del `.env` del workspace), esta feature aplica a los dos modos y por eso se ancla en `agent.yml` como fuente única que rendea a los dos artefactos.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - El operador amplía la ventana de handshake desde el flujo declarativo (Priority: P1)

Como operador que despliega un agente (docker o local) con MCPs que pueden tardar en su primer arranque —descarga en frío, host lento, muchos MCPs compitiendo—, quiero fijar la ventana de handshake MCP desde `agent.yml`, para que el valor sobreviva `./setup.sh --regenerate` y un rebuild sin que yo tenga que editar archivos derivados a mano ni conocer el nombre interno de una variable de entorno.

**Why this priority**: Es la palanca central. Hoy la ventana es el default fijo del binario y no hay forma declarativa de ampliarla; el único recurso del operador es editar a mano un archivo que `--regenerate` pisa. Es también prerrequisito de US2: un default sano solo se puede razonar una vez que el valor es un parámetro y no una constante.

**Independent Test**: Fijar la ventana a un valor distinto del default en `agent.yml`, correr `./setup.sh --regenerate`, y verificar que el artefacto que entrega el valor al proceso `claude` (env del compose en docker; `EnvironmentFile` de la unit en local) refleja ese valor, sin que ningún archivo de código o derivado haya sido editado a mano.

**Acceptance Scenarios**:

1. **Given** un workspace con la ventana configurada en `agent.yml` a un valor mayor al default, **When** se corre `./setup.sh --regenerate` en modo docker, **Then** el bloque de entorno del `docker-compose.yml` renderizado entrega ese valor al contenedor.
2. **Given** el mismo workspace en modo local, **When** se corre `./setup.sh --regenerate`, **Then** el `EnvironmentFile`/unit renderizado entrega ese valor al proceso systemd, derivado del mismo campo de `agent.yml` (sin duplicar el literal).
3. **Given** un valor de ventana ausente o vacío en `agent.yml`, **When** se rendea, **Then** se aplica el default de la feature sin fallar el render ni el arranque.

---

### User Story 2 - Un MCP de primer arranque lento conecta en vez de quedar muerto (Priority: P2)

Como operador cuyo agente monta un MCP que en su primer arranque descarga un paquete (del catálogo o de un overlay), quiero que el default de la ventana de handshake ya sea suficiente para absorber esa descarga en frío, para que el MCP conecte out-of-the-box sin que yo tenga que conocer ni tocar este parámetro.

**Why this priority**: Cierra el incidente medido out-of-the-box. La configurabilidad (US1) resuelve el caso extremo, pero un default que sigue siendo el del binario deja a todo scaffold nuevo con un MCP de descarga en frío expuesto al mismo fallo silencioso. El default correcto depende del default real del binario (a medir en Fase 0) y del peor caso de descarga medido (~50 s), por eso va después de US1.

**Independent Test**: Con un MCP cuyo primer arranque tarda ~60 s (descarga en frío simulada o real), arrancar la sesión con el default y sin configurar nada, y verificar que el MCP queda conectado en vez de marcado como failed.

**Acceptance Scenarios**:

1. **Given** un scaffold nuevo sin configurar la ventana, **When** arranca con un MCP cuyo primer handshake incluye una descarga de ~50 s, **Then** el MCP completa el handshake y queda conectado.
2. **Given** el agente `donna` con la feature desplegada, **When** se recrea el contenedor con el cache de `workspace-mcp` frío, **Then** `google-workspace` conecta y no reaparece el estado muerto del 16-08-2026.

---

### User Story 3 - Una ventana amplia no esconde un MCP genuinamente roto (Priority: P3)

Como operador diagnosticando por qué un MCP no responde, quiero poder distinguir un MCP que arrancó lento pero conectó de uno que agotó la ventana y quedó muerto, para que ampliar el default no me deje ciego ante una falla real (un MCP mal configurado, un secreto faltante, un binario ausente).

**Why this priority**: Observabilidad y contención del trade-off. Ampliar la ventana reduce los falsos negativos (MCP lento marcado muerto) a costa de tardar más en delatar un MCP genuinamente roto. Es barato dejar traza o documentar el método de diagnóstico, y evita que la feature convierta un fallo ruidoso en uno silencioso más largo.

**Independent Test**: Con la ventana configurada, provocar el caso de un MCP que nunca completa el handshake, y verificar que existe una señal legible (log/estado) o un procedimiento documentado que lo distingue de un arranque simplemente lento.

**Acceptance Scenarios**:

1. **Given** un MCP que agota la ventana configurada, **When** el operador diagnostica, **Then** dispone de una señal o procedimiento documentado que identifica el MCP muerto y lo separa de uno que arrancó dentro del plazo.

---

### Edge Cases

- **Valor inválido** (no numérico, vacío, cero o negativo): el sistema debe caer al default de forma segura, nunca aplicar una ventana de 0 (que mataría todo MCP de inmediato) ni fallar el render/arranque.
- **Valor muy alto**: una ventana desmedida retrasa la detección de un MCP genuinamente roto. El comportamiento sigue siendo correcto (solo más lento en delatar la falla); conviene documentar la implicación (US3). No se exige un tope duro salvo que la Fase 0 encuentre una razón.
- **Dos variables distintas en Claude Code**: si el binario distingue la ventana de *arranque* del MCP de la de las *llamadas de tool*, la feature debe cubrir la del arranque (la que causó el incidente). Cuál es se resuelve empíricamente en Fase 0.
- **Agente existente sin el valor configurado**: tras un upgrade, un workspace que no fija el parámetro debe comportarse según el default nuevo sin intervención ni migración de estado.
- **Modo local con el `.env` no entregado a la sesión**: el mecanismo debe garantizar que el valor llegue al proceso `claude` en local (por la unit), no depender de un `.env` que en local mode históricamente no llegaba a la sesión.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: La ventana de handshake que Claude Code aplica al arrancar un MCP server MUST ser un parámetro configurable, no el default fijo del binario.
- **FR-002**: El valor configurable MUST tener su fuente única en `agent.yml` (Principio I) y MUST llegar al proceso `claude` en **ambos modos** — docker (por el entorno que el compose entrega al contenedor) y local (por el `EnvironmentFile` de la unit de sesión systemd).
- **FR-003**: El valor MUST sobrevivir `./setup.sh --regenerate` y un rebuild de imagen, por re-render desde `agent.yml`, sin ediciones manuales de archivos derivados ni de código.
- **FR-004**: Ambos artefactos derivados (compose en docker, unit/`EnvironmentFile` en local) MUST derivarse del **mismo** campo de `agent.yml`; el valor literal MUST NOT duplicarse entre ellos (Principio VI).
- **FR-005**: En ausencia de un valor configurado (no definido o vacío), el sistema MUST aplicar un default único, bien definido y **más generoso que el default del binario de Claude Code**, sin fallar el arranque.
- **FR-006**: Ante un valor inválido (no numérico, cero o negativo), el sistema MUST degradar al default de forma segura y MUST NOT aplicar jamás una ventana ≤ 0.
- **FR-007**: El default MUST ser suficiente para absorber el peor caso medido de descarga en frío de un MCP (~50 s), de modo que un MCP de primer arranque lento conecte en vez de quedar muerto sin que el operador configure nada. El valor exacto se fija contra el default real del binario medido en Fase 0 (orientativo: 120 s).
- **FR-008**: La variable de entorno exacta que Claude Code respeta para la ventana de handshake de **arranque** del MCP MUST verificarse empíricamente en Fase 0 contra la versión de Claude Code pineada en la imagen (`docker.claude_code_version`), no inferirse de documentación; si el binario distingue arranque de llamadas de tool, el mecanismo declarativo MUST alimentar la del arranque.
- **FR-009**: El sistema MUST proveer una señal legible o un procedimiento de diagnóstico documentado que distinga un MCP que agotó la ventana (muerto) de uno que arrancó dentro del plazo, para que un default amplio no enmascare una falla genuina.
- **FR-010**: El cambio MUST NOT debilitar el modelo de privilegios del contenedor (Principio II): solo introduce una variable de configuración, sin nuevas capacidades, montajes privilegiados ni acceso al socket de docker.
- **FR-011**: El cambio MUST registrarse en `CHANGELOG.md` y reflejarse en el archivo `VERSION` del launcher (Principio VI); si toca la superficie de usuario, MUST actualizar la referencia de `docs/` correspondiente.

### Key Entities

- **Ventana de handshake de arranque MCP**: el plazo máximo que Claude Code espera a que un MCP server complete su handshake de arranque antes de marcarlo failed (sin reintento posterior). Atributos: valor efectivo aplicado; default cuando no se configura; origen declarativo (campo en `agent.yml`); variable(s) de entorno subyacente(s) que el binario respeta (a verificar en Fase 0); modo (docker/local) por el que el valor llega al proceso.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Con la ventana configurada en `agent.yml` a un valor N mayor al default, tras `--regenerate`, el artefacto que entrega el entorno al proceso `claude` refleja N — en docker (entorno del compose) y en local (unit/`EnvironmentFile`) — sin que se haya editado ningún archivo derivado a mano.
- **SC-002**: El valor vive en un solo lugar (`agent.yml`); docker y local lo derivan del mismo campo, sin el literal duplicado en dos plantillas.
- **SC-003**: Un MCP cuyo primer arranque tarda ~60 s (descarga en frío) conecta en vez de quedar marcado como failed, con el default nuevo y sin configurar nada.
- **SC-004**: Recrear el contenedor de `donna` con el cache de `workspace-mcp` frío deja `google-workspace` conectado; el estado muerto medido el 16-08-2026 no se reproduce.
- **SC-005**: Ante un valor de ventana inválido o ausente, el render y el arranque no fallan y se aplica el default (nunca una ventana ≤ 0).
- **SC-006**: Un agente existente que no fija el parámetro, tras el upgrade, obtiene el default nuevo sin migración de datos ni de estado.
- **SC-007**: Existe una señal legible o un procedimiento documentado que permite, ante un MCP que no responde, distinguir "arrancó lento pero conectó" de "agotó la ventana y quedó muerto".

## Assumptions

- El nombre exacto de la variable de entorno y el default real del binario se **miden en Fase 0** (dumpear el comportamiento contra `docker.claude_code_version`, hoy `2.1.220`, no inferir de documentación). Candidatos a distinguir: la ventana de arranque del MCP vs la de las llamadas de tool. La feature alimenta la del arranque, que es la que causó el incidente.
- El default orientativo de 120 s (FR-007) se ajustará según el default real medido y el peor caso de descarga en frío (~50 s medido en ferrari). La 026 usó 60 s para el watchdog del channel, un plazo distinto: aquí el peor caso incluye la descarga completa del paquete, no solo la aparición de un proceso ya instalado.
- El mecanismo se ancla en `agent.yml` (a diferencia del `.env` directo de la 026) porque la feature aplica a **ambos modos** y necesita una fuente única que rendee a dos artefactos distintos (compose en docker, unit en local); esto respeta el Principio I. La ubicación exacta del campo (bloque `docker:`, un bloque nuevo compartido por ambos modos, u otro) se decide en `/speckit-plan` / data-model.
- El cambio es test-first (Principio III): `bats` verifica que el valor de `agent.yml` se rendea a los artefactos de ambos modos y que el default y la validación de valor inválido funcionan, con los tests escritos antes del fix. La Fase 0 determina si el cambio toca `docker/` image-baked (que exigiría `DOCKER_E2E`) o solo plantillas de render host-testeables; el precedente sugiere que un cambio de entorno en el compose template es render puro, pero el punto se confirma, no se asume.
- El incidente concreto que motiva la feature involucra un MCP inyectado por la herramienta externa `custom-apply` (repo `agentic-pod-launcher-custom-config`), pero la feature es agnóstica al origen del MCP: cubre cualquier MCP de `.mcp.json`. La eliminación de la descarga en frío misma (warm cache) es la feature 030 separada; esta feature solo amplía la ventana para que la descarga alcance a completarse.
- La feature bumpea `VERSION` y agrega entrada en `CHANGELOG.md` (Principio VI).
