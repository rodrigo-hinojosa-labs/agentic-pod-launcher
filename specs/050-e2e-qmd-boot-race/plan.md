# Implementation Plan: Migración QMD independiente del orden de arranque

**Branch**: `050-e2e-qmd-boot-race` | **Date**: 2026-11-24 | **Spec**: [spec.md](spec.md)

**Input**: especificación clarificada del issue #117. **Estado**: diseño; implementación y gates de ejecución pendientes.

## Summary

La prueba de migración legacy supone que la existencia de `index.sqlite` impide el setup. El producto exige además `.qmd-setup-ok`, por lo que un arranque rápido puede invalidar su aserción inicial. Dos aserciones intermedias también pueden quedar inactivas bajo bash 3.2.

El fix prepara una instalación con setup completado y migración pendiente: índice y marcador de setup presentes, marcador de colección ausente. Presembrar el vault y usar el calendario imposible del fixture evita que el watcher o el cron migren antes del tick manual. El primer reindex se ejecuta una vez antes del bucle; los 45 s existentes quedan solo para observar el log. Se comprueban status, conteos exactos, orden, confirmación, estado `done` e idempotencia con aserciones activas en ambos bash.

Un oráculo host ejecuta las secciones reales en un Bats hijo y controles negativos. La aceptación incluye matriz Docker base/candidato con órdenes early/late, corrida normal sin instrumentación y workflow e2e de CI verde antes del PR. Solo cambian pruebas y documentación; no hay bump de VERSION ni despliegue.

## Technical Context

**Language/Version**: bash 3.2 y 5.x para los tests; POSIX sh en inspecciones del contenedor; Python 3 para el coordinador de evidencia. Medido en la fase: bash 3.2.57 y 5.3.15.

**Primary Dependencies**: bats-core (1.13.0 local medido; el workflow Linux instala 1.11.0), yq v4, jq, Git, Python 3 y las herramientas ya requeridas por la suite. Docker/Compose solo en aceptación e2e; gh solo en la compuerta remota posterior. Ninguna dependencia de producto nueva.

**Storage**: archivos propios de fixtures temporales, caché de motor falso y evidencia local. No hay formatos nuevos de producto, migraciones de datos reales ni lectura de estado de la flota.

**Testing**: nuevo oráculo host, guardia B2 de 043 adaptada, pruebas existentes de setup/locks, mutaciones en ambos bash; reproducción Docker controlada; e2e normal y CI manual. El gate completo del host corre en serie en los dos bash.

**Target Platform**: host macOS con bash 3.2/5.x y Linux amd64 de CI; contenedor Alpine/musl existente. No se cambia ninguna imagen base ni se habilita una nueva arquitectura de nightly.

**Project Type**: reparación de un arnés e2e de shell; sin interfaces nuevas de producto. Las interfaces de prueba y evidencia se documentan en `contracts/`.

**Performance Goals**: no aumentar los presupuestos de espera existentes. Se conserva lectura de log de 45 s, espera de lock de 120 s por defecto, cadencia de 2 s y cap por intento del ayudante de 600 s con KILL posterior de 10 s. El host usa reloj falso en casos de espera. Gates nuevos de reproducción acotados, exclusivos del coordinador y sin instrumentación en la corrida normal.

**Constraints**: cero diff de runtime y workflows; VERSION 0.35.0 sin cambio; sin root exec, capacidades ni puertos nuevos; sin red o Docker en la suite host; sin agentes desplegados; sin `[[ ]]` intermedios en el sujeto; sin payload grande por argv/env. Conservar diagnóstico, contención e idempotencia de 043.

**Scale/Scope**: una prueba Docker existente y B2; un archivo host nuevo de 15 casos propuestos más su ayudante privado; dos herramientas de evidencia dentro de la spec; CHANGELOG y artefactos de diseño. El total de e2e no aumenta. El total host esperado se calcula desde la base medida al iniciar implementación, no desde conteos históricos.

## Constitution Check

*Evaluación anterior a investigación y revalidación posterior al diseño, contra constitución 1.2.0. Los veredictos califican el diseño; no equivalen a gates de ejecución realizados.*

| Principio | Inicial | Después del diseño | Evidencia del diseño |
| --- | --- | --- | --- |
| I. Fuente única, agent.yml | N/A | N/A | Solo cambia el YAML propio del fixture; no se agregan opciones ni derivados de producto. |
| II. Menor privilegio | PASA | PASA | Exec como `agent`; wrapper solo en copias de reproducción, entrypoint original, montajes de prueba de solo lectura y sin privilegios añadidos. |
| III. Test-first y host | PASA | PASA | Oráculo conductual y ROJO antes del fix, controles del arnés, dos bash; Docker separado del host. |
| IV. Idempotencia y degradación | PASA | PASA | Conserva ayudante y guardias; no acepta una contención como ejecución ni reintenta trabajo para ocultar una falla. |
| V. Workspace durable | N/A | N/A | Solo fixtures desechables y evidencia sintética; no se accede a estado del operador. |
| VI. Dependencias reproducibles | PASA | PASA | Sin nuevos pins; motor falso ya gestionado; CHANGELOG sin bump por ser tests-only. |

| Gate adicional | Decisión y ejecución posterior |
| --- | --- |
| Bash 3.2/5.x | Host y controles negativos en ambos; la matriz Docker usa 5.x para que el rojo anterior sea observable. |
| Regenerate | Sin nuevo derivado; runtime idéntico. El fixture conserva su `--regenerate` de preparación. |
| Pruebas | Host completo y shellcheck; Docker inducido y normal; CI manual antes del PR, FR-009. Todos pendientes de implementación. |
| Privilegios | Revisar el cableado del wrapper y `-u agent`; no se edita `docker/`. |
| Documentación | CHANGELOG y esta spec; no editar AGENTS.md generado/sin seguimiento ni el vault personal. |
| Alcance | No #120, no otras pruebas con aserciones similares, no producto, no workflows, no flota. |

**Resultado**: seis principios revisados, cero violaciones; no hace falta enmienda constitucional. El wrapper de reproducción es un montaje del contenedor de pruebas, no del producto desplegado.

## Project Structure

### Documentation (this feature)

```text
specs/050-e2e-qmd-boot-race/
├── spec.md
├── checklists/requirements.md
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
└── contracts/
    ├── migration-fixture.md
    ├── host-oracle.md
    └── evidence-protocol.md
```

`tasks.md` se crea solo mediante `/speckit-tasks`. `tools/reproduce.py` y `tools/start-services-gate.sh` son salidas previstas de implementación, no de este comando.

### Source Code (repository root)

```text
tests/docker-e2e-qmd.bats                  # solo escenario legacy y comentarios delimitadores
tests/qmd-e2e-lock.bats                    # B2: tick 1 anterior al bucle, guardias conservadas
tests/qmd-e2e-boot-race.bats               # nuevo: comportamiento de fixture y aserciones
tests/helper-qmd-e2e-boot-race.bash        # nuevo: extracción y Bats hijo, privado del oráculo
specs/050-e2e-qmd-boot-race/tools/          # futuro: coordinador y wrapper de reproducción
CHANGELOG.md                             # registro del fix de pruebas, sin VERSION
```

**Structure Decision**: todo el soporte nuevo vive bajo pruebas o en la carpeta de la feature. `tests/helper-qmd-e2e.bash` no cambia; tampoco `scripts/`, `docker/`, `modules/`, `setup.sh`, `.github/workflows/` ni `VERSION`.

## Phase 0: investigación y decisiones

Completada en [research.md](research.md): D1 fixture y competidores; D2 tick único; D3 aserciones reales y controles; D4 separación del oráculo; D5 reproducción inducida; D6 evidencia antes del PR.

Medición local nueva: ocho celdas de sondas de aserciones, todas con el resultado previsto. Las dos aserciones originales fallan bajo 5.x y quedan ocultas bajo 3.2; `[ ]` y status fallan en ambos. No se ejecutó Docker ni se reprodujo todavía el e2e completo.

## Phase 1: diseño y contratos

1. [Modelo de datos](data-model.md): independencia de setup/migración, ticks y gates.
2. [Fixture](contracts/migration-fixture.md): preparación anterior al up, precondición, efectos e idempotencia.
3. [Oráculo host](contracts/host-oracle.md): extracción con fallo cerrado, Bats hijo en el mismo intérprete, 15 casos y controles negativos.
4. [Evidencia](contracts/evidence-protocol.md): snapshots, wrapper, cuatro intercalaciones inducidas y gates local/CI.
5. [Quickstart](quickstart.md): comandos de validación para cuando la implementación exista.

### Orden previsto de implementación

Esta secuencia alimenta `/speckit-tasks`; no lo ejecuta.

1. Medir la base, fijar hashes y añadir solo delimitadores sin alterar comportamiento. Validar primero el autotest del arnés; un fallo de extracción no cuenta como ROJO del producto bajo prueba.
2. Escribir el oráculo y B2 reforzada. Registrar qué controles ya pasan y qué fallas corresponden al defecto; no exigir artificialmente que toda prueba nueva esté roja.
3. Aplicar el fixture determinista, tick único, conteos y aserciones. Cerrar los controles y mutaciones en ambos bash.
4. Implementar y comprobar el arnés Docker, ejecutar D1-D4 y el e2e normal; revisión independiente y gates completos locales.
5. Con autorización, consolidar commits, publicar y ejecutar la CI acordada. PR solo después del e2e verde del commit corregido.

### Trazabilidad

| Requisito | Diseño y aceptación |
| --- | --- |
| FR-001 | F1/F2; H01/H02; estados del modelo |
| FR-002 | F1/F2; D1-D4 Docker; SC-001 |
| FR-003 | F3; H07-H11; conteos exactos y orden, SC-002 |
| FR-004 | F4; H12/H13; SC-002/SC-003 |
| FR-005 | F3/F4; H04/H12; guardias y suite de locks conservadas |
| FR-006 | F5; H02/H03/H10/H11/H14; sondas y mutaciones M03/M04 |
| FR-007 | F5/F6; H05/H06; B2 y diagnóstico existente |
| FR-008 | Protocolo D1-D4 con gates acreditados; SC-004 |
| FR-009 | H00-H14, mutaciones, Docker normal, gate host y CI antes del PR; SC-005 |
| FR-010 | Diff de alcance y hashes de runtime; SC-006 |

## Complexity Tracking

Sin violaciones que justificar. Se mantiene vacío el registro de excepciones; los gates y herramientas descritos son exclusivos del entorno de prueba.

## Estado de salida

Diseño completo el 24-11-2026. Los hooks de `.specify/extensions.yml` están vacíos. No se ejecutan otras fases ni se crean sus scripts o tareas. Siguiente comando: `/speckit-tasks`.

**Actualización posterior aprobada tras el análisis (24-11-2026):** U1 exige el retorno real del setup tardío antes de tick 1; U2 fija identidad Compose única, preflight de colisiones y limpieza propia; I1 conserva B2 como regresión del candidato sano y atribuye M14 al oráculo que lee las copias; A1 clasifica M18 como rechazo estructural esperado. Los detalles normativos están en [evidencia](contracts/evidence-protocol.md) y [oráculo host](contracts/host-oracle.md), con sus tareas actualizadas. No cambia el alcance ni el número de tareas; la comprobación de estas ediciones no sustituye una nueva invocación de análisis ni los gates de implementación. Siguiente revisión recomendada: `/speckit-analyze`.
