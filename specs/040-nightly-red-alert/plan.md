# Implementation Plan: Una noche en rojo del nightly le llega a alguien

**Branch**: `040-nightly-red-alert` | **Date**: 2026-10-12 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/040-nightly-red-alert/spec.md`

**Note**: Este plan lo llena `/speckit-plan`. El paso "Agent context update" se hace A MANO (el hook de contexto de agente ya no existe: `.specify/extensions.yml` queda con `hooks: {}`).

## Summary

El nightly `docker-e2e` ya ejecuta la suite y su color significa algo (039), pero un rojo solo se ve entrando a Actions: hubo 155 corridas programadas seguidas en rojo (07-05 a 09-10-2026) sin que nada lo hiciera notar. Esta feature agrega un job `alert` al workflow que, tras cada corrida **programada**, publica o actualiza **un issue asignado al mantenedor**: lo abre en la primera noche roja, lo actualiza en las siguientes, lo reabre si alguien lo cierra a mano mientras sigue el rojo y lo cierra solo cuando vuelve el verde. Las corridas manuales no lo mueven; la evidencia real sale de una corrida manual de **ensayo** (`alert_trial`) con un aviso de ensayo separado.

**Enfoque técnico** (decisiones y alternativas en [research.md](research.md)):

- **Un job aparte** (`alert`, `needs: e2e`, `if: always()`) con `permissions: {contents: read, issues: write}`; el job de la suite conserva `contents: read` y el código de los tests nunca ve el permiso nuevo. Sin acciones de terceros nuevas; los únicos secretos son los dos del empuje por Telegram (enmienda 1, al final de este plan).
- **Toda la lógica en un script**, `.github/scripts/nightly-alert.sh`, con tres subcomandos (`collect`, `simulate`, `notify`): lo lintea el job `shellcheck` de CI (su `find` incluye `.github/`), y la suite del host lo ejecuta contra un `gh` falso con estado. Queda fuera de `scripts/` (FR-017).
- **El paso de la suite no se toca**: un paso final `if: always()` del job `e2e` (`collect`) deriva paso fallido, resumen y tests fallidos de `toJSON(steps)` y de `e2e.tap`, y los entrega como salidas del job. Los tests S1 a S6 de 039 siguen valiendo tal cual.
- **El aviso no puede romper la noche**: el script nunca sale con error (avisa con `::warning::`) y el paso lleva `continue-on-error: true`, porque la conclusión de una corrida es la peor de sus jobs.
- **El estado vive en el propio issue**: etiqueta `nightly-red` y un marcador en la primera línea del cuerpo (`state=open|resolved`, total y primera noche). Distingue un cierre manual (marcador `open`: se reabre) de un cierre del mecanismo (`resolved`: la racha siguiente abre otro); un verde posterior a un cierre manual también reescribe el marcador a `resolved`, para que un rojo lejano no reabra un issue viejo.
- **Oráculo del host** en un archivo nuevo, `tests/nightly-alert.bats`, con nueve casos de comportamiento (FR-014) más estructura, cotas, texto inerte, idempotencia y paridad del resumen con el paso de la suite; 20 mutaciones con su test cazador (M2, M12 y M19 con dos variantes); la enmienda 1 suma las M34 a M59 (ver `quickstart.md` secciones 3 y 3.1).

## Technical Context

**Language/Version**: Bash compatible con 3.2 y 5.x (el script corre en `ubuntu-latest` con 5.2, pero sus pruebas corren en macOS con 3.2.57: sin `mapfile`, arreglos asociativos ni `${v,,}`); YAML de GitHub Actions; `jq` 1.6+ y `gh` 2.x preinstalados en el runner (`gh` 2.102.0 en el Mac; en el runner no está fijado).

**Primary Dependencies**: `gh` (subcomandos `issue list|create|comment|edit|reopen|close` y `label create`, banderas verificadas en 2.102.0, ver research R8), `jq`, `curl` (para el empuje por Telegram; preinstalado en los runners), `actions/checkout@v6` (ya usada). Para las pruebas: `bats` (1.11 en CI), `yq` v4, `jq`, `perl` (restablece SIGPIPE, como en 039) y `python3` (el servidor local que hace de Telegram; ya lo usan `apply-telegram-patches.bats` y `agentctl-doctor-telegram-patches.bats`). Ninguna dependencia nueva que fijar (Principio VI).

**Storage**: N/A. El estado de una racha vive en el issue (marcador en la primera línea del cuerpo y filas de las últimas noches); el script no guarda nada en disco entre corridas.

**Testing**: `bats tests/` en el host, sin Docker ni red (Principio III): `tests/nightly-alert.bats` con un `gh` falso con estado (`tests/fixtures/nightly-alert/gh`). Evidencia real con `workflow_dispatch` en modo ensayo (compuertas del operador). Línea base 1817 ok y 0 not ok en bash 5.x y 3.2. Costuras de prueba: `ALERT_SCRIPT`, `ALERT_WORKFLOW` (mutar copias) y `NIGHTLY_ALERT_NOW` (reloj fijo); el arnés elige la disposición de SIGPIPE con `SIGPIPE_MODE`.

**Target Platform**: GitHub Actions `ubuntu-latest` para el script; macOS y Linux para las pruebas del host.

**Project Type**: workflow de CI más un script y su oráculo de tests (proyecto único; no hay `src/`).

**Performance Goals**: el job `alert` termina en menos de 1 minuto y la suite en verde no suma más de 1 minuto sobre los ~15 medidos (SC-008); tope del job `alert` de 5 minutos.

**Constraints**: FR-017 (ni `docker/`, ni `scripts/`, ni `modules/`, ni `setup.sh`, ni el contenido de los e2e); permisos: el único nuevo es `issues: write`, acotado al job `alert` (FR-013); los únicos secretos son `TELEGRAM_BOT_TOKEN` y `TELEGRAM_CHAT_ID`, leídos solo por el paso que publica (FR-021); el script sale siempre con 0 (FR-009); texto inerte, repositorio público (FR-004); idempotente ante un reintento del job (Principio IV); reglas de `CLAUDE.md` "Common gotchas" (pipes bajo `pipefail`, SIGPIPE ignorada en runners, `[[ ]]` intermedio muerto en bash 3.2, E2BIG por argv, `gh api …/logs` con `--allow-escape-sequences`).

**Scale/Scope**: un issue por racha; como máximo 20 nombres de test y 10 filas de detalle por aviso; rachas de cientos de noches (ya hubo 155) con cuerpo acotado muy por debajo del límite de 65.536 caracteres de la API.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principio | Veredicto | Razón |
|---|---|---|
| I. Single Source of Truth (`agent.yml`) | N/A | No toca archivos derivados ni `agent.yml`; es CI. |
| II. Least-Privilege Container Model | N/A para el contenedor; **se aplica el espíritu al token** | No hay cambios bajo `docker/`. El permiso nuevo (`issues: write`) queda en un job que no ejecuta código de los tests ni de los e2e, y el job de la suite conserva `contents: read`. |
| III. Test-First, Host-Runnable (bats) | PASS | El comportamiento nuevo trae su oráculo en `bats tests/` sin Docker ni red, escrito y visto en ROJO antes del script y del workflow. El script está bajo el gate `shellcheck -S error`. DOCKER_E2E no aplica (no cambia `docker/` ni el arranque). |
| IV. Idempotent, Fail-Silent Lifecycle | PASS | El script es el equivalente de un notificador: sale siempre con 0, no puede tumbar la corrida, y reintentar el job no duplica la noche (la corrida se identifica por su id en la fila). El empuje por Telegram es un segundo notificador con la misma regla: un solo intento, falla con `::warning::` y nunca cambia el código de salida. |
| V. Workspace-Is-the-Agent | N/A | Sin estado de agente. |
| VI. Reproducible, Intentionally-Pinned Dependencies | PASS | Sin dependencias nuevas; `gh` y `jq` vienen del runner y su deriva se acota con una lista blanca de banderas verificadas en el `gh` falso y con la evidencia real. |
| Platform & Toolchain (bash 3.2+, probado en ambos) | PASS | El script se escribe para 3.2 y el gate dual lo prueba. |
| Quality gates (regenerate-safety, test gate, privilege gate) | PASS / N/A | Regenerate-safety y privilege gate no aplican; el test gate sí (1817 más los tests nuevos, en ambos bash). |
| CHANGELOG / VERSION | PASS | Entrada de CHANGELOG; sin bump de `VERSION` (precedente 019, 025 y 039; se confirma a mano contra `origin/main`). |

**Resultado: 6/6 sin violaciones, Complexity Tracking vacío.**

**Re-chequeo tras el diseño de Fase 1:** sin cambios. La única tensión posible, que FR-013 diga "más allá de escribir issues" mientras el job `alert` también lista `contents: read` para el checkout, no es una ampliación: el workflow ya tiene `contents: read` y al fijar `permissions` en un job hay que repetirlo. **FR-013 se cumple sin enmienda** (research R1). La regla para las corridas canceladas queda **condicionada a una medición** (research R7).

## Project Structure

### Documentation (this feature)

```text
specs/040-nightly-red-alert/
├── plan.md              # Este archivo (/speckit-plan)
├── research.md          # Fase 0: decisiones R1-R16 y las mediciones (hechas y con compuerta)
├── data-model.md        # Fase 1: corrida, aviso, racha y la tabla de decisión
├── quickstart.md        # Fase 1: validación local, ensayo real con compuertas y tabla de mutaciones
├── contracts/
│   ├── alert-workflow.md   # AW: cableado del workflow, entradas de ensayo, permisos
│   ├── alert-script.md     # AS: subcomandos, entradas, salidas, llamadas a gh, códigos
│   ├── notice-format.md    # NF: título, etiquetas, cuerpo, marcadores, cotas, texto inerte
│   ├── telegram-push.md    # TP: el empuje por Telegram (enmienda 1): cuándo, qué dice, la petición y las anotaciones
│   └── alert-oracle.md     # AO: el gh falso, los tests y su cobertura de FR/SC
├── checklists/requirements.md
└── tasks.md             # Fase 2 (/speckit-tasks; NO lo crea este comando)
```

### Source Code (repository root)

```text
.github/
├── workflows/docker-e2e.yml        # editado: entradas de ensayo, ids de paso, paso collect, salidas, job alert
└── scripts/nightly-alert.sh        # nuevo: collect, simulate, notify (fuera de scripts/, FR-017)
tests/
├── nightly-alert.bats              # nuevo: oráculo del aviso (comportamiento, estructura, cotas, mutaciones)
└── fixtures/nightly-alert/
    ├── gh                          # nuevo: gh falso con estado y lista blanca de banderas
    ├── curl                        # nuevo (enmienda 1): espía que anota los argumentos y delega en el curl real
    ├── tg-server.py                # nuevo (enmienda 1): servidor HTTP local que hace de API de Telegram
    ├── steps-*.json                # nuevos: toJSON(steps) de ejemplo (verde, suite roja, verificación roja, cancelada) y steps-invalid.txt
    └── tap-*.tap                   # nuevos: TAP con 25 fallos y con nombres largos (el TAP hostil se genera en la prueba)
CHANGELOG.md                        # editado
CLAUDE.md                           # editado a mano: entrada de 040 al principio del bloque SPECKIT
```

**Structure Decision**: proyecto único, sin `src/`. El código de producción de la feature es un workflow más un script bajo `.github/`; sus pruebas viven en `tests/` junto a las del resto del repositorio. No se toca nada de las tres rutas de código del launcher (anfitrión, imagen, workspace).

## Fases y compuertas

| Fase | Qué | Salida | Compuerta |
|---|---|---|---|
| 0 | Investigación y mediciones locales | `research.md` | ninguna (mediciones locales hechas el 12-10-2026) |
| 1 | Diseño y contratos | `data-model.md`, `contracts/*`, `quickstart.md` | ninguna |
| 2 | `/speckit-tasks` | `tasks.md` (test-first) | ninguna |
| Implementación | oráculo en ROJO, script, workflow, mutaciones, gate dual | commits locales | commit y push los pide el operador |
| Evidencia real | siete corridas de ensayo (E1 a E7; E7 mide el tiempo agotado) y una corrida manual normal de 15 minutos (E8); con la enmienda 1, ver la tabla de fases de la enmienda (E0 si el #106 sigue abierto) | ids en las Notes | push, `workflow_dispatch` y la confirmación humana de la notificación (SC-009) |
| Cierre | PR, CI de ambos bash, merge del operador | PR | PR y merge los pide / hace el operador |

## Observaciones de spec-kit 1.1.2 (primera feature con la versión nueva)

- `/speckit-specify` no crea la rama (solo lo haría un hook `before_specify`); resolvió la plantilla con `resolve-template.sh spec-template --json` y numeró con `feature_numbering: sequential`.
- `/speckit-clarify` impone una pregunta a la vez con "Why it matters" y la forma `**Question:** …? (FR-xxx)`; se usó AskUserQuestion, como pidió el operador. Su integración incremental (una viñeta por respuesta y el cambio en el requisito) funcionó sin fricción.
- `/speckit-plan` ya no actualiza `CLAUDE.md` (el hook se quitó): el paso se hizo a mano.
- Los skills se reinvocan completos cuando una compactación truncó su copia.
- No notado: ningún cambio de comportamiento que afecte al contenido de los artefactos.

## Complexity Tracking

> Sin violaciones de la constitución: la tabla queda vacía.

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| (ninguna) | | |

## Enmienda 1 (14-10-2026): empuje por Telegram

**Origen.** La medición M8 de la primera corrida real de ensayo (E1, run 38497730831, issue #106) mostró que GitHub crea la notificación de la asignación pero que al operador no le llegó nada donde mira (esperaba Telegram). El operador decidió (AskUserQuestion, 14-10-2026) agregar un empuje por Telegram desde el job `alert` con un bot nuevo solo para la CI, y `/speckit-clarify` fijó tres puntos más: un mensaje por cada noche roja y uno de recuperación (FR-020), conciso y con enlaces (FR-022) y la recuperación en silencio (FR-023). Enmienda FR-012, FR-013, SC-007 y SC-009 y agrega FR-020 a FR-023 y SC-010 (spec, sesión del 14-10-2026).

**Diseño** (research R17 a R24, contrato `contracts/telegram-push.md`):

- Una función de empuje dentro de `notify` en el mismo script, después de la acción sobre el issue; el empuje sigue a esa acción (data-model sección 6). Sin permisos nuevos de GitHub.
- `curl -K <configuración>`: el token vive solo en un archivo temporal 0600 y nunca en los argumentos; los secretos se validan por formato, se copian a variables del shell y se quitan del entorno; la redacción del token cubre cualquier texto que se imprima.
- Dos secretos de repositorio (`TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`) que pone el operador y que solo lee el paso `Publish the nightly notice`. Un secreto ausente omite el empuje con un `::warning::` y el issue se publica igual.
- Un intento por mensaje, 15 segundos, sin reintentos; cualquier falla es un `::warning::` con el motivo.
- Oráculo: el `curl` real contra un servidor HTTP local de Python (`tg-server.py`) con un `curl` espía delante; el `gh` falso gana la anotación de orden y la de filtración de entorno. Costuras de prueba `TELEGRAM_API_BASE` y `TELEGRAM_MAX_TIME`.

**Qué cambia en el árbol**: `.github/scripts/nightly-alert.sh` (función de empuje, lectura y retiro de los secretos), `.github/workflows/docker-e2e.yml` (las dos variables de entorno con los secretos en el paso que publica), `tests/nightly-alert.bats` (11 tests nuevos, N32 a N42, y N26 y N27 reescritos; 43 en total), `tests/fixtures/nightly-alert/{curl,tg-server.py}` y el `gh` falso. **Qué no cambia**: `docker/`, `scripts/`, `modules/`, `setup.sh`, el texto de los pasos congelados de 039, los permisos del workflow ni la `VERSION`.

**Constitución**: sin cambio de veredicto (6/6; Complexity Tracking sigue vacío). El empuje es un notificador y cumple el Principio IV; los secretos no son estado de agente (V) y no se toca nada de `docker/` (II).

**Riesgos nuevos**: (1) quien puede escribir en el repositorio puede leer los secretos modificando un workflow (el empuje es tan seguro como ese acceso); (2) `disable_notification` y el límite de 4096 caracteres no se verificaron en la documentación (research M11) y los confirma la primera entrega real; (3) el servidor local de pruebas agrega un proceso a la suite: se levanta y se mata dentro de cada test que lo usa; (4) un secreto rotado y no actualizado deja el empuje en `::warning::` visible sin afectar a la noche.

**Fases y compuertas de la enmienda**

| Fase | Qué | Compuerta |
|---|---|---|
| A | spec, research, data-model y contratos (este documento) y tareas T088 a T137 en `tasks.md` | ninguna |
| B | Implementación test-first: fixtures y arnés, tests en ROJO, función de empuje, workflow, mutaciones, gate dual (esperado 1860), revisión independiente | ninguna |
| C | Commits y push de la rama | el operador, cada uno |
| D | El operador crea el bot y define los dos secretos (R24); el agente solo verifica los nombres con `gh secret list` | el operador (acción suya) |
| E | Se corre E0 (solo si el #106 sigue abierto), se repiten E1 a E6 y se ejecutan por primera vez E7 y E8 sobre el texto final; el operador confirma que el mensaje de Telegram le llegó (SC-009) | el operador, cada `workflow_dispatch` |
| F | PR, CI de ambos bash y merge | el operador |
