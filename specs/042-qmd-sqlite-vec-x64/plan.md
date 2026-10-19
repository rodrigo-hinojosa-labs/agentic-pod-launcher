# Implementation Plan: El embed de qmd funciona en la imagen docker sobre amd64 y el nightly vuelve a ejercitarlo

**Branch**: `042-qmd-sqlite-vec-x64` | **Date**: 2026-10-18 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/042-qmd-sqlite-vec-x64/spec.md`

## Summary

En la imagen del agente (Alpine/musl) sobre un host amd64, `qmd embed` y `qmd vsearch` fallan porque el reemplazo de la extensión vectorial (`_qmd_swap_sqlite_vec`, `scripts/lib/qmd_index.sh:128-144`) tiene el destino fijo en el paquete `sqlite-vec-linux-arm64` y, con el paquete x64 que `bun install` instala en amd64, sale sin hacer nada y sin registrar nada (issue #107; evidencia de la corrida 39069243972 de 041). El arreglo es chico y local: la función elige el paquete que corresponde a la arquitectura de la máquina (`x86_64` o `amd64` dan `x64`; `aarch64` o `arm64` dan `arm64`), no toca jamás un paquete ajeno, deja una línea de log cuando no hay nada que reemplazar (hoy es callado) y sigue siendo idempotente, de estado 0 y sin romper el índice léxico. Se escribe test-first sobre `tests/qmd-sqlite-vec.bats` (de 7 a 18 pruebas, con un seam `QMD_MACHINE_ARCH` para que el oráculo sea hermético en ubuntu amd64 y en macOS arm64), con un catálogo de 15 mutaciones (M1 a M15, con M9 y M13 en variantes).

La Fase 0 midió el mecanismo antes de diseñar: el script de producción compila la build musl en un Alpine amd64 (8 s, ELF x86-64, 0 símbolos `GLIBC_`), la extensión musl carga con el CLI `sqlite3` y devuelve `v0.1.9`, y el `vec0.so` glibc del paquete x64 publicado falla con `__memcpy_chk: symbol not found`, como en E1. Con 041 ya en `main` (#108, squash `0fc08a8`), se reactiva el nightly vaciando `QMD_EMBED_DEFECT`, se mide la duración del job en al menos 3 corridas (subiendo el tope primero si el margen baja de 5 minutos), se repite la rotura inducida y se cierra #107. La cobertura permanente en arm64 dentro del nightly es otra feature (decisión del operador del 18-10-2026).

## Technical Context

**Language/Version**: bash 3.2 y 5.x (la biblioteca se carga con `source` desde `heartbeatctl`, `start_services.sh` y las pruebas); el userland del contenedor es busybox de Alpine 3.24.

**Primary Dependencies**: busybox (`uname`, `cmp`, `cp`) y el shell; ninguna dependencia nueva. Los paquetes `sqlite-vec` 0.1.9 y qmd 2.5.3 siguen fijados (no cambian).

**Storage**: archivos del prefijo gestionado de qmd bajo `.state/.cache/qmd/pkg`; no hay estado nuevo.

**Testing**: bats en el host (bash 5.x y 3.2, sin Docker), con el seam de arquitectura; DOCKER_E2E (arm64 local con los modelos de 041 y amd64 en la CI); `shellcheck -S error` sobre la biblioteca.

**Target Platform**: imagen docker Alpine/musl en x86_64 y aarch64; el modo local (glibc) queda como está (la función sale antes de mirar la arquitectura).

**Project Type**: biblioteca de scripts de shell más un workflow de CI (no hay aplicación ni servicio).

**Performance Goals**: el costo del reemplazo es despreciable (como mucho un `uname -m` y unos `stat` por preparación del prefijo, y solo en musl); lo que importa es que el nightly con la fase activa deje al menos 5 minutos de margen contra el tope de 30 (se decide midiendo, D8).

**Constraints**: estado de salida 0 siempre; idempotente; una línea de log como máximo por llamada; sin construcciones de bash 4; sin capacidades nuevas en el contenedor; no cambia las versiones de qmd ni de sqlite-vec, ni la base Alpine, ni el modo local.

**Scale/Scope**: una función (unas 40 líneas), un archivo de pruebas ampliado, cinco documentos y un valor en el workflow. Bump de `VERSION` MINOR (0.28.0 a 0.29.0, a verificar contra `origin/main`).

## Constitution Check

*GATE: debe pasar antes de la Fase 0 y se revisa de nuevo tras el diseño de la Fase 1.*

| Principio o compuerta | Veredicto | Razón |
| --- | --- | --- |
| I. Fuente única (`agent.yml`) | N/A | No hay configuración nueva ni archivos derivados; el cambio es código de biblioteca y un valor del workflow. |
| II. Contenedor de menor privilegio (NO NEGOCIABLE) | PASA | Sin capacidades, montajes ni sockets nuevos. La función copia dentro del prefijo del propio agente (como `agent`), desde un archivo horneado de solo lectura. El único archivo bajo `docker/` que se toca es un comentario de `docker/scripts/build-sqlite-vec.sh`; la compuerta de privilegios se cumple (sin efecto sobre ningún modo de ejecución). Caso contingente: si la primera corrida de amd64 muestra que la build musl horneada no existe en la imagen (el supuesto 2 del spec, FR-013), el arreglo tocaría el Dockerfile o ese script y esta revisión se rehace antes de implementarlo. |
| III. Test-first, ejecutable en el host | PASA | El comportamiento nuevo nace con pruebas del host (11 nuevas y tres reforzadas) con el ROJO visto antes; el oráculo no necesita Docker; el código horneado en la imagen se verifica además con DOCKER_E2E (V3 y V4); `shellcheck` limpio. |
| IV. Ciclo idempotente y que degrada sin caer | PASA | `cmp -s` mantiene la idempotencia; cada camino que no puede reemplazar registra y devuelve 0, sin romper el índice léxico; la guarda de la arquitectura no soportada también degrada. |
| V. El workspace es el agente | N/A | El prefijo vive en `.state/` como hasta hoy; no se agrega ni se mueve estado, y nada se versiona. |
| VI. Dependencias fijadas a propósito | PASA | Ningún pin nuevo ni duplicado (sqlite-vec 0.1.9 y qmd 2.5.3 siguen fijados con su guarda de versiones); el cambio se registra en `CHANGELOG.md` y se refleja en `VERSION`. |
| Plataforma: bash 3.2+, probado en 3.2 y 5.x | PASA | `case`, glob y `uname`, sin constructos de bash 4; el oráculo corre en los dos bash y en ubuntu amd64 y macOS arm64 sin depender de la arquitectura del host. |
| Compuerta de regenerate | N/A | No hay salida derivada nueva. |
| Compuerta de pruebas | PASA | `bats tests/` en el host; DOCKER_E2E para código horneado en la imagen (V3, V4). |
| Compuerta de documentación | PASA | CHANGELOG, VERSION y los documentos que nombran la ruta arm64 (D6). |
| Disciplina de alcance | PASA | Unidad pequeña y de un solo propósito; la cobertura arm64 permanente, la prueba versionada de V2 y la velocidad de llama.cpp quedan fuera. |

**Re-chequeo tras el diseño (Fase 1)**: sin cambios. El seam `QMD_MACHINE_ARCH` sigue el patrón de `QMD_MUSL_LOADER` y `QMD_VEC0_MUSL_SO`; el contrato de la función fija que ningún otro código lo lea. **Resultado: 6 de 6 principios y todas las compuertas sin violación (I y V no aplican).**

## Project Structure

### Documentation (this feature)

```text
specs/042-qmd-sqlite-vec-x64/
├── spec.md              # clarificado el 18-10-2026 (1 pregunta, checklist 16/16)
├── plan.md              # este archivo
├── research.md          # Fase 0: mediciones M1 a M7 y decisiones D1 a D11
├── data-model.md        # Fase 1: entidades, tabla de decisión D1 a D7 y transiciones
├── quickstart.md        # Fase 1: escenarios de validación V1 a V7
├── contracts/
│   ├── swap-sqlite-vec.md        # interfaz, seams, mapa de arquitectura, textos CANON del log, invariantes
│   ├── host-oracle.md            # las 18 pruebas y el catálogo de mutaciones M1 a M15
│   └── nightly-reactivation.md   # cambios al workflow, orden de la evidencia, medición y rotura inducida
├── checklists/
│   └── requirements.md
└── tasks.md             # Fase 2 (/speckit-tasks; no lo crea este comando)
```

### Source Code (repository root)

```text
scripts/lib/qmd_index.sh               # la función _qmd_swap_sqlite_vec (líneas 128-144; su comentario, 122-127) y el comentario de QMD_VEC0_MUSL_SO, que también nombra la ruta arm64 (105-111)
tests/qmd-sqlite-vec.bats              # de 7 a 18 pruebas, seam QMD_MACHINE_ARCH
docker/scripts/build-sqlite-vec.sh     # solo el comentario de cabecera (nombra el paquete arm64)
docs/qmd-upgrade-checklist.md          # el ítem "017 swap path" y la nota de la línea 32
docs/architecture.md                   # la viñeta de la línea 336
docs/vault.md                          # el párrafo de la línea 539 y el paso 3 del diagnóstico (líneas 697-699)
CHANGELOG.md, CLAUDE.md, VERSION       # entrada, viñetas (la del reemplazo y la del nightly) y 0.28.0 a 0.29.0
.github/workflows/docker-e2e.yml       # con 041 ya en main (#108): QMD_EMBED_DEFECT vacío; timeout-minutes solo si la medición lo exige
```

**Structure Decision**: un proyecto único; el cambio de código vive en una biblioteca de `scripts/lib/` que `setup.sh::mirror_catalog_to_docker` copia al contexto de build (no hay copia versionada que sincronizar). El cambio al workflow y la evidencia de CI ya pueden hacerse: #108 está en `main` (squash `0fc08a8`) y el workflow trae el interruptor `QMD_EMBED_DEFECT`.

## Complexity Tracking

Sin violaciones de la constitución que justificar; la tabla queda vacía.
