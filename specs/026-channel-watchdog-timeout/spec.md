# Feature Specification: Timeout configurable del watchdog del channel (docker)

**Feature Branch**: `026-channel-watchdog-timeout`

**Created**: 2026-08-02

**Status**: Draft

**Input**: El timeout del watchdog que espera al plugin de Telegram (`bun server.ts`) tras un lanzamiento `--channels` está hardcodeado en 20s (`docker/scripts/start_services.sh:721-732`). En un host lento o con muchos MCPs el channel tarda más y el watchdog lo mata y respawnea en bucle, dejando el contenedor en flapeo permanente. Hacerlo configurable por el flujo declarativo normal, con un default que no dispare el flapeo medido.

## Contexto

En modo docker, tras lanzar una sesión con `--channels`, el supervisor image-baked `docker/scripts/start_services.sh` verifica que el plugin de Telegram haya levantado su servidor (`bun server.ts`). Esa verificación vive en `verify_channel_healthy()` (`start_services.sh:721-732`): hace `pgrep -f "bun server.ts"` cada 2s durante `local timeout=20` segundos; si el proceso no aparece en ese plazo, retorna fallo. En `start_session()` (`:758-763`), un fallo mata la sesión tmux y retorna 1 — el watchdog lo cuenta como crash y respawnea. Con el crash budget (5 crashes / 300s → el contenedor sale y docker lo revive por `unless-stopped`), un channel que consistentemente tarda más de 20s deja al contenedor en **flapeo permanente**. El mensaje de log de `:760` incrusta el literal `"within 20s"`.

**Bug medido en hardware vivo** (ferrari, Raspberry Pi 5, Debian, 2026-08-02, tras reconstruir la imagen a v0.16.0): el contenedor flapeó de forma permanente — `RestartCount` subió de 14 a 53 sin converger, reiniciando cada ~15-25s. No era falta de memoria (`oomkilled=false`, exit 0). Bajo la contención de ~7 MCPs arrancando a la vez en boot (atlassian ~28% CPU, fetch, mcpvault, filesystem, qmd, github; carga del host ~2.0 sobre 4 cores), `bun server.ts` tardaba ~22-25s en aparecer y perdía la carrera con el timeout de 20s **en todos los arranques**. El mismo mecanismo se observó en el gate confirmatorio de la feature 017 (~35 flaps antes de estabilizar).

**Workaround temporal en producción** (a retirar cuando esta feature se despliegue): en ferrari se dejó un `docker-compose.override.yml` que monta un `start_services.sh` parcheado con `timeout=90` sobre el baked (`:ro`). Rompió el flapeo (restarts=0, healthy, `bun` vivo), pero es un parche a mano no reproducible: no lo genera `--regenerate`, no sobrevive un rebuild limpio y no se replica a otro agente.

**Alcance: docker-only.** `start_services.sh` es image-baked (`/opt/agent-admin/scripts/`) y solo corre en modo docker. El modo local usa units systemd y **no** tiene este watchdog: queda fuera de alcance.

## Clarifications

### Session 2026-08-02

- Q: ¿Qué valor por defecto toma el timeout del watchdog cuando el operador no configura nada (FR-006)? → A: **60 segundos** — ~2.5x el pico de contención de arranque medido en ferrari (~22-25s, con el channel apareciendo en ~3s en calma), suficiente para cerrar el flapeo out-of-the-box sin demorar en exceso la detección de un channel genuinamente muerto; los hosts patológicos suben más por la configuración.
- Q: ¿Dónde vive el valor configurable y cómo llega al contenedor (FR-007)? → A: **Variable de entorno del workspace `.env`** (patrón `TELEGRAM_TYPING_MAX_MS`), que compose entrega al contenedor vía `env_file` y el watchdog lee con default 60s en el propio script. No se agrega campo a `agent.yml` ni se toca schema/render; el `.env` es user-owned y sobrevive `--regenerate`.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - El operador amplía el timeout sin parchear el script (Priority: P1)

Como operador que despliega un agente docker en un host lento o con muchos MCPs, quiero fijar el timeout del watchdog del channel mediante el flujo declarativo normal del launcher, para que el valor sobreviva `--regenerate` y un rebuild sin que yo tenga que editar `start_services.sh` a mano ni mantener un `docker-compose.override.yml`.

**Why this priority**: Es el valor central y lo que elimina el parche manual. Con la configurabilidad, el override que hoy sostiene a ferrari se reemplaza por config reproducible, y cualquier agente futuro en un host exigente tiene la palanca. Es también prerrequisito de US2: un default sano solo se puede razonar una vez que el valor es un parámetro y no una constante.

**Independent Test**: Fijar el timeout a un valor distinto del default por el mecanismo declarativo, correr `--regenerate` y/o un rebuild, y verificar que el watchdog usa el valor configurado (la función `verify_channel_healthy` espera ese plazo, no 20s), sin que ningún archivo de código haya sido editado a mano.

**Acceptance Scenarios**:

1. **Given** un workspace docker con el timeout configurado en un valor mayor al default, **When** se corre `./setup.sh --regenerate`, **Then** el artefacto que entrega el valor al contenedor refleja ese valor y el watchdog lo usa en el próximo arranque.
2. **Given** un agente cuyo `bun server.ts` tarda más que el default en aparecer pero menos que el timeout configurado, **When** arranca el contenedor, **Then** el watchdog espera lo suficiente, el channel se marca healthy y el contenedor NO respawnea la sesión.
3. **Given** un valor de timeout ausente o vacío, **When** arranca el contenedor, **Then** el watchdog usa el default sin fallar (degradación segura, nunca un timeout de 0 o negativo que rompa el arranque).

---

### User Story 2 - Un agente recién desplegado no flapea en un host típico (Priority: P2)

Como operador que despliega un agente docker por primera vez (incluida una Raspberry Pi 5 con el catálogo habitual de MCPs), quiero que el default del timeout ya no dispare el flapeo medido, para que el agente arranque estable sin que yo tenga que conocer ni tocar este parámetro.

**Why this priority**: Cierra el bug medido out-of-the-box. La configurabilidad (US1) resuelve el caso extremo, pero un default que sigue disparando el flap deja a todo scaffold nuevo dependiendo de conocimiento oculto. El default correcto depende de cuánto tarda realmente el channel (a medir en Fase 0), por eso va después de US1.

**Independent Test**: Desplegar un agente docker con el catálogo típico de MCPs en un host de recursos modestos, arrancarlo sin configurar el timeout, y verificar que converge a healthy sin entrar en flapeo (RestartCount se estabiliza, el channel queda vivo).

**Acceptance Scenarios**:

1. **Given** un scaffold docker nuevo sin configurar el timeout, **When** arranca en un host tipo RPi5 con ~7 MCPs, **Then** el channel levanta dentro del plazo por defecto y el contenedor no flapea.
2. **Given** el agente ferrari con la feature desplegada y su `docker-compose.override.yml` manual retirado, **When** se recrea el contenedor, **Then** no reaparece el flapeo.

---

### User Story 3 - El log del watchdog dice la verdad (Priority: P3)

Como operador diagnosticando un arranque, quiero que el mensaje de log del watchdog cuando el channel no aparece refleje el timeout realmente aplicado, para no ser inducido a error por un literal desincronizado.

**Why this priority**: Observabilidad. Es barato y evita que un log diga "within 20s" cuando el timeout efectivo es otro — justo el tipo de mentira sutil que hace perder tiempo en diagnóstico.

**Independent Test**: Configurar un timeout distinto del default, forzar el caso en que el channel nunca aparece, y verificar que el mensaje de log nombra el valor efectivo, no un literal fijo.

**Acceptance Scenarios**:

1. **Given** un timeout configurado en un valor N distinto de 20, **When** el channel no aparece en N segundos, **Then** el mensaje de log de aviso menciona N, no "20s".

---

### Edge Cases

- **Valor inválido** (no numérico, vacío, cero o negativo): el watchdog debe caer al default de forma segura, nunca aplicar un plazo de 0 (que mataría el channel de inmediato) ni fallar el arranque.
- **Valor muy alto**: un timeout desmedido retrasa la detección de un channel genuinamente muerto. El comportamiento sigue siendo correcto (solo más lento en detectar), pero conviene documentar la implicación; no se exige un tope duro salvo que la Fase 0 encuentre una razón.
- **Interacción con el crash budget**: el timeout más largo reduce la frecuencia de respawns; verificar que la relación con la ventana de crash budget (5/300s) sigue siendo coherente y no enmascara un fallo real distinto del arranque lento.
- **Agente existente sin el valor configurado**: tras un upgrade, un workspace que no fija el parámetro debe comportarse según el default nuevo sin intervención.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: El plazo que `verify_channel_healthy` espera a que aparezca el plugin del channel MUST ser un parámetro configurable, no una constante hardcodeada en el script.
- **FR-002**: El valor configurado MUST llegar al watchdog dentro del contenedor por el flujo declarativo normal del launcher y MUST sobrevivir `./setup.sh --regenerate` y un rebuild de la imagen (sin ediciones manuales de archivos de código).
- **FR-003**: En ausencia de un valor configurado (no definido o vacío), el sistema MUST aplicar un default único y bien definido, sin fallar el arranque.
- **FR-004**: Ante un valor inválido (no numérico, cero o negativo), el sistema MUST degradar al default de forma segura y no aplicar jamás un plazo ≤ 0.
- **FR-005**: El mensaje de log emitido cuando el channel no aparece dentro del plazo MUST reflejar el valor efectivamente aplicado, no un literal fijo.
- **FR-006**: El default del timeout MUST ser **60 segundos** — ~2.5x el pico de contención de arranque medido en ferrari (~22-25s), de modo que un agente docker con el catálogo típico de MCPs en un host de recursos modestos (referencia: RPi5, ~7 MCPs) no entre en flapeo de arranque sin configurar nada. Un host patológico puede ampliarlo más vía el mecanismo de FR-007.
- **FR-007**: El valor configurable MUST exponerse como una **variable de entorno del workspace `.env`** (siguiendo el precedente `TELEGRAM_TYPING_MAX_MS`), que compose entrega al contenedor vía `env_file` y que el watchdog lee con el default de FR-006 embebido en el propio script. El cambio MUST NOT agregar un campo a `agent.yml` ni tocar el schema/render; el override es opcional y, al vivir en el `.env` user-owned, sobrevive `--regenerate` sin regeneración.
- **FR-008**: El cambio MUST permitir retirar el `docker-compose.override.yml` manual de ferrari, quedando el timeout provisto por el flujo declarativo.
- **FR-009**: El cambio MUST NOT debilitar el modelo de privilegios del contenedor (Principio II): solo introduce una variable de configuración, sin nuevas capacidades, montajes privilegiados ni acceso al socket de docker.
- **FR-010**: El comportamiento en modo local MUST permanecer intacto (no usa este watchdog); la feature no toca los artefactos del modo local.

### Key Entities

- **Timeout del watchdog del channel**: el plazo máximo (en segundos) que el supervisor espera a que `bun server.ts` aparezca tras un lanzamiento `--channels` antes de considerar el arranque fallido. Atributos: valor efectivo aplicado, default cuando no se configura, origen declarativo (por resolver en FR-007).

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Con el timeout configurado en un valor N mayor al default, tras `--regenerate` + rebuild, el watchdog espera N segundos por el channel (verificable observando el plazo efectivo), sin que se haya editado ningún archivo de código a mano.
- **SC-002**: Un agente docker con el catálogo típico de MCPs, desplegado con el default y sin configurar el timeout, arranca y converge a healthy sin flapeo (RestartCount deja de crecer tras el primer arranque exitoso).
- **SC-003**: Con su `docker-compose.override.yml` manual retirado, ferrari se recrea y no reaparece el flapeo de arranque medido el 2026-08-02.
- **SC-004**: Ante un valor de timeout inválido o ausente, el arranque no falla y el watchdog aplica el default (nunca un plazo ≤ 0).
- **SC-005**: El mensaje de log de channel-no-aparece nombra el plazo efectivo, no un literal desincronizado.
- **SC-006**: El comportamiento del modo local queda byte-idéntico (sus artefactos renderizados no cambian).

## Assumptions

- El "por qué" de la lentitud está medido como contención de arranque de MCPs; la Fase 0 confirmará si es solo contención o si hay un factor adicional en v0.16.0 (p.ej. una sesión `--continue` grande — el `claude.log` de ferrari estaba en ~16.8MB durante el flap) antes de fijar el default de FR-006. El fix del timeout es agnóstico a la causa; el default correcto no.
- El mecanismo de FR-007 quedó fijado en `/speckit-clarify` (2026-08-02) como variable de entorno del workspace `.env`, siguiendo el precedente directo `TELEGRAM_TYPING_MAX_MS` (`docker/scripts/apply_telegram_typing_patch.py`). No viola el Principio I: el `.env` es user-owned, no un archivo derivado renderizado de `agent.yml`. El nombre exacto de la variable se fija en `/speckit-plan`.
- El cambio es test-first: la lógica del timeout configurable se demuestra con `bats` sourceando `verify_channel_healthy` con `pgrep` stubbeado (channel aparece tarde vs nunca) y falla por la razón correcta antes del fix. Como toca `docker/` y el path de boot/supervisor, el gate incluye `DOCKER_E2E` (la lib es image-baked).
- La feature bumpea `VERSION` y agrega entrada en `CHANGELOG.md` (Principio VI).
- El default se aplica a agentes existentes tras un upgrade sin intervención; no requiere migración de datos ni de estado.
