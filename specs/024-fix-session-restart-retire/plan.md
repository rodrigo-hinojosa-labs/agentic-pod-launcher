# Implementation Plan: reiniciar el agente deja de romper el enlace del cliente

**Branch**: `024-fix-session-restart-retire` | **Date**: 2026-07-20 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/024-fix-session-restart-retire/spec.md`

## Summary

Un `systemctl restart` de un agente en modo local retira el puntero de sesión de
una conversación **viva** y anuncia una sesión nueva, matando el enlace que el
operador tenía abierto. Medido en mclaren durante el gate T051 de la feature 022,
que corrió después de su merge: el defecto está en `main`.

La causa es que `session_decide` (`scripts/lib/session_pointer.sh:212-224`)
conserva el puntero solo si el `exit_code` del marcador es `killed`, y Claude Code
atrapa `SIGTERM` y sale con código 0 — así que systemd reporta `exited` tanto
cuando detiene el servicio como cuando la sesión termina sola. El discriminador
elegido por 022 no discrimina.

**El enfoque sale de una medición, no de un razonamiento.** La Fase 0 refutó el
candidato obvio (`ExecStop` no corre solo en paradas explícitas: también corre
cuando el proceso sale por su cuenta) y encontró la asimetría real un hook más
arriba: **dentro de `ExecStop`, `$EXIT_CODE` está definido si el proceso ya había
salido solo, y vacío si la parada la inicia systemd**, porque systemd solo puebla
esas variables una vez que el proceso murió. 15/15 consistente, incluida la
variante `Restart=always` que usa la unit real.

El cambio: agregar un hook `ExecStop` que deje constancia de esa señal, que
`ExecStopPost` la incorpore al marcador existente, y que `session_decide` decida
sobre la causa en vez de sobre el código de salida. Bajo incertidumbre se conserva
—lo contrario del default actual— porque el costo de conservar de más es una
conversación muerta y visible, y el de retirar de más es perder trabajo sin aviso.

## Technical Context

**Language/Version**: `sh`/`bash` POSIX-compatible. Las libs corren bajo el `sh` de
BusyBox/dash en el host del agente y bajo `bash` 3.2 y 5.x en la suite. Sin
constructos exclusivos de bash 4+ en `session_pointer.sh`.

**Primary Dependencies**: systemd (host del agente; medido en 257 sobre Debian 13).
Sin dependencias nuevas. Sin `jq` en la ruta de los hooks — `session_exit_marker_write`
usa `printf` a propósito porque `jq` puede faltar en el host.

**Storage**: ficheros bajo `<workspace>/.state/`. El marcador de salida ya existe;
gana un campo. Constancia nueva de `ExecStop` en la misma zona.

**Testing**: `bats tests/`, host, sin Docker, en **ambas** versiones de bash.
Fixtures alimentados con los valores **medidos** en R2, no inventados.

**Target Platform**: modo local (Linux + systemd). El modo contenedor no participa.

**Project Type**: launcher de shell que renderiza el workspace de un agente.

**Performance Goals**: N/A. La decisión ocurre una vez por arranque.

**Constraints**: los hooks nunca pueden convertir un apagado en un fallo (Principio
IV) — todos salen 0 pase lo que pase. Prohibido cualquier sondeo o inferencia
periódica de vitalidad (FR-006, precedente `ebfe35f`).

**Scale/Scope**: una lib, tres plantillas de hook (una nueva), la plantilla de la
unit, el diagnóstico y su cobertura de tests.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*
*Source: `.specify/memory/constitution.md` (v1.0.0).*

- [x] **I. Single Source of Truth** — **PASS**. El hook nuevo es una plantilla en
  `modules/` renderizada desde `agent.yml`, igual que los dos existentes. La
  directiva `ExecStop` va en `modules/systemd-remote-control.service.tpl`, no en la
  unit instalada a mano. Todo se reproduce con `--regenerate` (FR-009). No se
  agregan campos a `agent.yml`: la regla es constante, no configuración.
- [x] **II. Least-Privilege (NON-NEGOTIABLE)** — **N/A**. Feature exclusiva de modo
  local. `docker/` no se toca y `session_pointer.sh` **no** está espejado ahí
  (verificado en R7, no supuesto). FR-012 se cumple por construcción.
- [x] **III. Test-First, Host-Runnable** — **PASS**. Cobertura `bats` para toda la
  tabla de decisión, escrita antes de la implementación, corriendo en las dos
  versiones de bash sin Docker. `shellcheck -S error` limpio. La lib mantiene su
  guarda de `BASH_SOURCE` sin efectos al sourcearse. **Se declara explícitamente el
  límite**: la suite no puede verificar que systemd entregue esos valores (FR-011);
  eso lo cubre el gate de hardware.
- [x] **IV. Idempotent, Fail-Silent Lifecycle** — **PASS**. Los tres hooks salen 0
  siempre. Se conserva el consumo único por `rename` que 022 ya implementó: **hay un
  solo marcador**, y la **ruta de decisión lo lee exactamente una vez**, por la
  variante que consume. El hook nuevo no agrega una segunda ruta de decisión.
  `ExecStop` crea el marcador con la causa; `ExecStopPost` le fusiona los campos de
  salida. Esa fusión es una reescritura del **lado escritor**, sobre el fichero que
  esos hooks ya poseen, no una lectura de decisión — la distinción es load-bearing y
  está desarrollada en [data-model.md](./data-model.md). Un marcador sin campo de
  causa (porque `ExecStop` no corrió, caso medido D) es un estado válido y previsto,
  no un error.
- [x] **V. Workspace-Is-the-Agent** — **PASS**. Todo el estado vive bajo `.state/`.
  El puntero retirado se conserva renombrado, nunca se borra (FR-005). No se
  registra ningún contenido de sesión ni token: la constancia guarda una
  clasificación, no datos de la conversación.
- [x] **VI. Reproducible, Pinned Dependencies** — **PASS**. Sin dependencias ni
  pins nuevos. `CHANGELOG.md` y `VERSION` se actualizan (cambio visible para el
  operador). `VERSION` se fija **al abrir el PR**, verificando contra
  `origin/main` a mano: 023 destapó que dos ramas que escriben el mismo número
  hacen que git auto-mergee `VERSION` **sin marcar conflicto**.

**Resultado: 6/6 sin violaciones.** Complexity Tracking queda vacío.

## Project Structure

### Documentation (this feature)

```text
specs/024-fix-session-restart-retire/
├── plan.md              # Este archivo
├── spec.md              # Qué y por qué
├── research.md          # Fase 0 — las 4 preguntas, medidas
├── data-model.md        # Fase 1
├── quickstart.md        # Fase 1 — reproducción y gates
├── checklists/
│   └── requirements.md
├── contracts/
│   └── session-stop-classification.md
└── tasks.md             # Fase 2 (/speckit-tasks)
```

### Source Code (repository root)

```text
scripts/lib/
└── session_pointer.sh                    # CAMBIA: session_decide decide sobre
                                          #   la causa, no sobre el exit_code;
                                          #   el marcador gana un campo

modules/
├── systemd-remote-control.service.tpl    # CAMBIA: agrega la directiva ExecStop
├── local-session-stop.sh.tpl             # NUEVO: el hook de ExecStop
├── local-session-exit.sh.tpl             # CAMBIA: incorpora la constancia
└── local-session-check.sh.tpl            # CAMBIA: registra causa y decisión

scripts/
└── agentctl                              # CAMBIA: el diagnóstico local (FR-008)

tests/
├── session-pointer.bats                  # CAMBIA: tabla de decisión completa,
│                                         #   con los valores MEDIDOS
├── local-session-hooks.bats              # CAMBIA: el flujo de los tres hooks
└── agentctl-local.bats                   # CAMBIA: el diagnóstico
```

**Structure Decision**: no se crean directorios nuevos. El cambio sigue la
estructura que 022 ya estableció —plantilla en `modules/` → hook renderizado en
`<workspace>/scripts/local/` → lógica compartida en `scripts/lib/`— y agrega una
tercera plantilla de hook al lado de las dos existentes. `docker/` queda intacto.

## Complexity Tracking

> Sin violaciones de la constitución. Tabla vacía a propósito.
