# Implementation Plan: Los tests e2e de qmd dejan de caer por la carrera del `.reindex.lock`

**Branch**: `043-e2e-lock-race-hardening` | **Date**: 2026-10-31 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/043-e2e-lock-race-hardening/spec.md`

## Summary

Dos pruebas de `tests/docker-e2e-qmd.bats` suponen que `.reindex.lock` está libre cuando lanzan un reindex manual: la fase `reindex` de `qmd real (041)` cayó en la noche del 29-10-2026 (run 40865079036, issue #112) y el bucle de la prueba 13 de 037 aborta si `engine-calls.log` aún no existe (issue #109). La fase 3 de la prueba 12 y el segundo tick de la 13 comparten la premisa, y el operador decidió cubrir todos los sitios. Perder el lock no es un defecto del producto: el reindex se salta con rc 0 y escribe `already running` por diseño (`scripts/lib/qmd_index.sh:545-573`). La corrección es solo de pruebas: un ayudante compartido, `tests/helper-qmd-e2e.bash`, que lanza el reindex manual con la orden que hoy usa la fase 041 (las pruebas 12 y 13 pasan a compartirla, con su tope y su archivo de salida), reintenta mientras la salida diga `already running` (plazo de 120 s, variable `QMD_E2E_REINDEX_LOCK_WAIT_S`, un intento cada 2 s), comprueba el efecto por el estado del índice (`hash` igual al `vault_hash` actual, `pending` en 0, `indexed` o `skipped`, de modo que un reindex del vigilante que se adelantó no pone en rojo una corrida sana) y nombra al dueño del lock con un escaneo de `/proc/*/fd` en la primera contención, al vencer el plazo y en el estado al fallar, junto con las tres primeras líneas de `qmd-setup.err`.

Se escribe test-first: 26 pruebas del host en `tests/qmd-e2e-lock.bats` (el comportamiento del ayudante con una función de exec falsa y un reloj falso, el efecto, la sonda, los cuerpos de los cuatro sitios y dos guardias), un catálogo de 39 mutaciones en bash 5.x y 3.2 (78 desde T032, que sumó una por cada aserción de los cuerpos de los sitios que ninguna ponía en rojo, y 89 desde la revisión independiente de T033; más dos que solo corren en Linux), y la enmienda de P1 de 041 (que hoy exige `grep -qE 'ok|indexed'` y `timeout -k 10 600` dentro de la fase). La Fase 0 midió el mecanismo antes de diseñar: un retenedor lanzado con `docker exec -d` o con `nohup` sobrevive al exec y hace perder el lock al idioma del producto; un descendiente que hereda el descriptor 9 sigue reteniéndolo cuando el subshell ya terminó (el segundo candidato del #112, reproducido); y `/proc/*/fd` lo nombra como usuario `agent`. Dos decisiones del operador (31-10-2026): el ayudante compartido con pruebas de comportamiento en el host, y la inyección de falla como evidencia local no versionada. La evidencia es la inyección (ROJO contra los cuerpos actuales, VERDE contra los nuevos, con 5 s y 20 s, y un vencimiento forzado en la fase 041 que ejecuta el estado al fallar), el DOCKER_E2E local, una corrida manual de CI antes del PR y el registro de las diez noches siguientes.

## Technical Context

**Language/Version**: bash 3.2 y 5.x (el ayudante y las pruebas se cargan en el host con bats); las órdenes dentro del contenedor corren en busybox sh o en bash 5 de la imagen (Alpine 3.24, busybox 1.37).

**Primary Dependencies**: bats-core (1.13 local, 1.11 en la CI de Linux), `jq` y `bash` dentro de la imagen, `flock` de util-linux (paquete `flock`, `docker/Dockerfile:45`), busybox (`timeout`, `ps`, `readlink`); docker Compose v2 solo para el DOCKER_E2E. Ninguna dependencia nueva.

**Storage**: ninguno nuevo. Archivos del contenedor que ya existen: `${QMD_CACHE_HOME:-$HOME/.cache/qmd}/.reindex.lock`, `/tmp/qmd-reindex.out`, `/workspace/scripts/heartbeat/qmd-index.json` y `$HOME/.cache/qmd/tmp/qmd-setup.err`.

**Testing**: bats en el host (`tests/qmd-e2e-lock.bats` nuevo, con una función de exec falsa y un reloj falso; P1 de `tests/qmd-embed-nightly.bats` enmendada); DOCKER_E2E local en arm64 con los modelos de 041; una corrida manual del workflow en CI (amd64). `tests/` queda fuera del shellcheck de la CI, como el resto de los archivos de pruebas.

**Target Platform**: host macOS arm64 y ubuntu amd64 (CI); la imagen Alpine/musl no cambia.

**Project Type**: arnés de pruebas de shell; no hay aplicación ni servicio.

**Performance Goals**: sin espera añadida con el lock libre: la prueba 16 sin su fase `setup` no sube más de 5 s sobre los 16 a 19 s medidos (umbral de 24 s, SC-003, que se decide en la corrida manual de CI). El peor caso de la fase 041 suma 120 s de espera y un reindex acotado a 600 s; con un dueño que no suelta el lock, cada una de las tres pruebas espera 120 s y termina (unos 6 minutos en total). Los dos caben en el tope de 45 minutos del job.

**Constraints**: solo pruebas: `git diff origin/main -- docker scripts modules setup.sh` vacío y `VERSION` sin cambio; sin constructos de bash 4; sin aserciones intermedias muertas (`[ ]`, `grep -q` o `if cmd; then false; fi`); el ayudante escribe solo por fd 3; ninguna prueba e2e nueva (el resumen sigue en `total=49`); nada grande por argv ni por el entorno.

**Scale/Scope**: un ayudante de unas 150 líneas, un archivo de pruebas nuevo de 26 pruebas, ediciones en cuatro sitios y en `_embed_failure_state`, una enmienda de P1, una frase de la checklist de upgrade, CHANGELOG y CLAUDE.md. Esperado de la suite del host: la línea base medida más 26.

## Constitution Check

*GATE: debe pasar antes de la Fase 0 y se revisa de nuevo tras el diseño de la Fase 1.*

| Principio o compuerta | Veredicto | Razón |
| --- | --- | --- |
| I. Fuente única (`agent.yml`) | N/A | No hay configuración nueva ni archivos derivados; el cambio es código de pruebas. |
| II. Contenedor de menor privilegio (NO NEGOCIABLE) | PASA | No se toca `docker/`. Todo `docker exec` del ayudante pasa por `in_container` o `inc`, que usan `-u agent`; la sonda del dueño lee `/proc` como `agent` y no usa root, ni capacidades, ni montajes, ni sockets nuevos. El retenedor de la evidencia local también corre como `agent`. |
| III. Test-first, ejecutable en el host | PASA | Las 26 pruebas del host nacen antes que el ayudante, con el ROJO visto (`contracts/host-oracle.md`, sección 6); el comportamiento del ayudante se ejercita sin Docker; lo que solo corre en contenedor se cubre con el DOCKER_E2E local y una corrida de CI; el ayudante y las pruebas corren en bash 3.2 y 5.x. |
| IV. Ciclo idempotente y que degrada sin caer | PASA | El ayudante reintenta solo `already running`, acotado, y nunca convierte un reindex fallido en un éxito (I4); las sondas toleran su propia falla sin cambiar el rojo que reportan (I7 y `\|\| true` en el estado al fallar). |
| V. El workspace es el agente | N/A | No se agrega ni se mueve estado; el lock y el estado del índice son los de hoy. |
| VI. Dependencias fijadas a propósito | PASA | Ningún pin nuevo ni duplicado; el cambio se registra en `CHANGELOG.md` sin bump de `VERSION`, porque no toca código de runtime (práctica de 025, 039, 041 y #113). |
| Plataforma: bash 3.2+, probado en 3.2 y 5.x | PASA | I11 y la guardia D2 del oráculo; el ayudante evita `[[ ]]`, `mapfile`, arreglos asociativos y las expansiones de mayúsculas y minúsculas. |
| Compuerta de regenerate | N/A | No hay salida derivada nueva. |
| Compuerta de pruebas | PASA | `bats tests/` en el host; DOCKER_E2E local y una corrida de CI para el cuerpo nuevo de los e2e (no cambia `docker/`, pero sí lo que el nightly ejecuta). |
| Compuerta de privilegios | N/A | Ningún cambio bajo `docker/`. |
| Compuerta de documentación | PASA | CHANGELOG, el bloque de CLAUDE.md y una frase de `docs/qmd-upgrade-checklist.md`. |
| Disciplina de alcance | PASA | Una unidad de un solo propósito (la espera del reindex manual); la inyección versionada, el vigilante, el producto y la cobertura arm64 quedan fuera. |

**Re-chequeo tras el diseño (Fase 1)**: sin cambios. El ayudante sigue el patrón de costuras de `QMD_MUSL_LOADER` y `QMD_MACHINE_ARCH` (funciones que el host redefine) y el contrato fija que ningún otro código las lea; la sonda no toma el lock, de modo que no introduce una carrera propia. **Resultado: 6 de 6 principios y todas las compuertas sin violación (I, V y la compuerta de privilegios no aplican).**

## Project Structure

### Documentation (this feature)

```text
specs/043-e2e-lock-race-hardening/
├── spec.md              # clarificado el 29 y 31-10-2026 (2 preguntas, checklist 16/16)
├── plan.md              # este archivo
├── research.md          # Fase 0: mediciones M1 a M12 y decisiones D1 a D11
├── data-model.md        # Fase 1: entidades, ciclo de la espera, tabla del efecto y textos CANON
├── quickstart.md        # Fase 1: escenarios V1 a V8
├── contracts/
│   ├── reindex-wait.md       # interfaz del ayudante, reglas, plazo, uso por sitio e invariantes I1 a I12
│   ├── lock-owner-dump.md    # la sonda del dueño y los cambios a `_embed_failure_state`
│   ├── host-oracle.md        # las 26 pruebas, la enmienda de P1 y las 89 mutaciones
│   └── evidence-protocol.md  # etapas, inyección local, DOCKER_E2E, corrida de CI y noches
├── checklists/
│   └── requirements.md
└── tasks.md             # Fase 2 (/speckit-tasks; no lo crea este comando)
```

### Source Code (repository root)

```text
tests/helper-qmd-e2e.bash        # NUEVO: qmd_e2e_reindex_wait, qmd_e2e_reindex_effect, qmd_e2e_lock_owners, las costuras _qmd_e2e_now y _qmd_e2e_sleep y QMD_E2E_LOCK_OWNERS_SH
tests/qmd-e2e-lock.bats          # NUEVO: las 26 pruebas del host (L, X, O, B y D)
tests/docker-e2e-qmd.bats        # EDICION: load del ayudante; fase reindex de 041 (:861-887); prueba 13 (:493-499 y :522-527); fase 3 de la prueba 12 (:264-276); _embed_failure_state (:57-73); comentario de cabecera
tests/qmd-embed-nightly.bats     # ENMIENDA: P1 (:855-935), solo lo que exige de la fase reindex
docs/qmd-upgrade-checklist.md    # una frase sobre el bloque del dueño del lock (la cita que guarda G3 no cambia)
CHANGELOG.md, CLAUDE.md          # entrada sin bump de VERSION y bloque de la feature
```

**Structure Decision**: un proyecto único y solo de pruebas. El ayudante vive en `tests/` y no en `scripts/` ni en `docker/`: es código de arnés, no del producto, y así `git diff origin/main -- docker scripts modules setup.sh` queda vacío (FR-012). Los números de línea de `tests/docker-e2e-qmd.bats` y de `tests/qmd-embed-nightly.bats` son los de `cd8b74f`. Con el PR #115 (cierre documental de 042) abierto, un rebase al final es probable en `CLAUDE.md` y en dos `tasks.md`; `VERSION` (0.29.0) se verifica a mano contra `origin/main` tras cualquier rebase.

## Complexity Tracking

Sin violaciones de la constitución que justificar; la tabla queda vacía.
