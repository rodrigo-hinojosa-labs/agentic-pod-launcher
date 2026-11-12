# Implementation Plan: Los hooks de claude-mem 15.x encuentran su lanzador en los agentes docker

**Branch**: `045-plugin-launcher-path` | **Date**: 2026-11-11 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/045-plugin-launcher-path/spec.md`

## Summary

claude-mem 15.x invoca su lanzador por nombre, sin shell, y lo instala en `/home/agent/.local/bin`, un directorio que no está en el PATH de ningún proceso del contenedor.

La Fase 0 midió dos cosas que el spec dejaba sin medir y que deciden el diseño (`research.md` M1 a M5):

- Un job de busybox `crond` hereda el PATH de `crond`, que es root (M1).
- En tmux 3.6b, una sesión nueva toma el PATH del **cliente que la crea**, no del servidor (M2 y M3). El spec suponía lo contrario.

En consecuencia, ni un `ENV PATH` de imagen ni un `export` en el supervisor cubren el heartbeat sin abrirle el directorio a root.

El arreglo (D1) fija el PATH donde se crea cada sesión de `claude`: `start_session` y el tick del heartbeat llaman a `tmux new-session` con el PATH compuesto como prefijo del cliente (`PATH=... tmux new-session`), porque tmux le da al pane el PATH del cliente e ignora `new-session -e PATH=` (`research.md` M10; el plan original usaba `-e`, y la prueba H1 lo desmintió). El PATH sale de una función pura y POSIX, `agent_path_compose`, en una librería nueva solo para docker, `docker/scripts/lib/agent_path.sh` (D2). La función agrega el directorio al final, no lo duplica y no hace nada con UID 0 ni con un `HOME` dudoso.

`agentctl mcp` la usa dentro del contenedor, para que el diagnóstico vea el mismo PATH que la sesión (D3). Los procesos root, el `ENV` de la imagen, el entrypoint, compose y el modo local no cambian.

La evidencia tiene tres partes:

- un oráculo nuevo de 16 pruebas en el host, en los dos bash, con 26 mutaciones (13 pruebas y 18 mutaciones en el diseño; la revisión independiente agregó 3 y 8);
- un e2e nuevo de 5 pruebas en un contenedor real, más el DOCKER_E2E entero;
- el gate en cbum con la imagen de la rama, antes del merge.

## Technical Context

**Language/Version**: bash (scripts del launcher y del contenedor) y POSIX sh (la librería nueva, que también carga el `sh` de BusyBox). El oráculo corre en bash 3.2.57 y 5.x.

**Primary Dependencies**: tmux 3.6b en la imagen (`alpine:3.24.1`, medido en M2 y M10) y 3.6a en el Mac. En la CI, 3.6 en el brazo ubuntu y 3.8 en el macOS, leídos del `tmux -V` de la corrida 42878267508 de `test.yml` sobre `main`. H1 ejercita el prefijo con el tmux real de cada una de esas versiones del host y de la CI. Para el producto solo cuenta la versión de la imagen, que se mide en M10 y en el e2e. BusyBox 1.37.0 (`crond` y `sh`) y `su-exec`. Ninguna dependencia nueva.

**Storage**: no aplica; no cambia ningún dato persistente (`data-model.md`).

**Testing**:

- **Host**: bats, con `tests/agent-user-bin-path.bats` (16 pruebas) y una prueba actualizada en `tests/agentctl.bats`.
- **Mutaciones**: M0 a M26, en los dos bash, más una pata en `ubuntu:24.04` para P5 y M7.
- **Contenedor**: `tests/docker-e2e-user-bin-path.bats` (5 pruebas) y el DOCKER_E2E entero.
- **Agente real**: el gate en cbum.

**Target Platform**: el contenedor del agente (Alpine 3.24.1; aarch64 en la flota y amd64 en el runner de la nocturna).

**Project Type**: CLI y librerías de shell (el launcher y su código horneado).

**Performance Goals**: no aplica. Crear la sesión cuesta una llamada más a una función de shell sin procesos externos, salvo un `id -u`.

**Constraints**:

- Ningún proceso root recibe el directorio (FR-004).
- Ningún binario de la imagen queda sombreado (FR-003).
- `_run_watchdog` no se toca (su oráculo de sha).
- El texto de los comandos de tmux no cambia (`tests/start-services-watchdog.bats:247`).
- El código está horneado, así que el DOCKER_E2E es obligatorio.
- Fail-silent si falta la librería (Principio IV).

**Scale/Scope**:

- una librería de unas 25 líneas;
- unas 8 líneas en `start_services.sh`, unas 6 en `heartbeat.sh` y unas 3 en `agentctl`;
- una línea `COPY` y un comentario reescrito en el Dockerfile;
- 16 pruebas en el host, una prueba existente actualizada y 5 pruebas e2e;
- CHANGELOG, `VERSION` 0.31.0 y documentos.

No queda ningún NEEDS CLARIFICATION. El spec se clarificó el 11-11-2026 y la Fase 0 resolvió las dos afirmaciones inferidas (M1 y M2; la segunda quedó refutada).

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principio | Evaluación | Resultado |
| --- | --- | --- |
| I. Single Source of Truth (`agent.yml`) | No cambia `agent.yml`, plantillas ni archivos derivados; `--regenerate` no tiene nada nuevo que producir | N/A |
| II. Least-Privilege Container Model | Revisión de privilegios hecha en el diseño. No agrega capacidades, mounts ni sockets, y no toca `docker-compose.yml.tpl` ni el entrypoint. El directorio que `agent` puede escribir queda fuera del PATH de todo proceso root (FR-004): por eso se descartó el `ENV PATH` de imagen (D1). La guarda de UID 0 de la función lo refuerza, y G1 (código) y E5 (`docker inspect`) lo verifican, sin ningún `docker exec -u root`. Antes del merge, la revisión de privilegios del diff de `docker/` (T031) cumple el gate de la constitución | PASS |
| III. Test-First, Host-Runnable | Las 16 pruebas nuevas corren en el host sin Docker y en los dos bash. Las 12 que caen se ven en ROJO contra `origin/main` antes del VERDE, y las 4 que nacen verdes se prueban con mutaciones. El e2e queda detrás de `DOCKER_E2E=1`. La librería solo define funciones (cargarla no tiene efectos, P5). Todo pasa `shellcheck -S error` | PASS |
| IV. Idempotent, Fail-Silent Lifecycle | La función es idempotente (no duplica el directorio) y siempre sale con 0. Sin la librería, la sesión se crea como antes y el arranque lo dice en el log (S2 y H2). Un respawn repite el cálculo sin acumular | PASS |
| V. Workspace-Is-the-Agent | El directorio vive en `.state/` y no se toca: ni se crea, ni se borra, ni se respalda. La poda de 036 sigue igual | PASS |
| VI. Reproducible, Pinned Dependencies | Sin dependencias nuevas. CHANGELOG y `VERSION` 0.31.0 (MINOR), verificada contra `origin/main` antes y después de cualquier rebase | PASS |

**Re-check after Phase 1**: sin cambios. Los contratos C1 a C5 mantienen intactos el `ENV` de la imagen, el entrypoint y compose, y solo agregan una línea `COPY`. Complexity Tracking queda vacío.

**Re-check tras el análisis (11-11-2026)**: el análisis encontró que E5 leía `/proc` con `docker exec -u root`, que contradice el Principio II («Every `docker exec` into an agent container MUST pass `-u agent`»), y que ninguna tarea cumplía el gate de revisión de privilegios. E5 pasó a `docker inspect` y T031 incluye esa revisión. El rollback del gate en cbum ya no rehace el enlace manual con root sin autorización explícita. Los seis principios quedan en PASS.

## Project Structure

### Documentation (this feature)

```text
specs/045-plugin-launcher-path/
├── spec.md              # clarificado el 11-11-2026
├── plan.md              # este archivo
├── research.md          # Fase 0: M1 a M7, D1 a D6
├── data-model.md        # el directorio, el PATH compuesto, los contextos y los procesos root
├── quickstart.md        # V1 a V7
├── contracts/
│   ├── agent-path.md        # C1 a C5: la función, la sesión, el heartbeat, agentctl y lo que no cambia
│   ├── host-oracle.md       # P1 a P6, S1, S2, H1, H2, A1, G1, G2; mutaciones M0 a M26
│   └── e2e-and-gate.md      # E1 a E5, el gate en cbum y el despliegue
├── checklists/
│   └── requirements.md
└── tasks.md             # /speckit-tasks (no lo crea este comando)
```

### Source Code (repository root)

```text
docker/
├── Dockerfile                       # + COPY de agent_path.sh; comentario de 036 reescrito; ENV sin cambios
└── scripts/
    ├── start_services.sh            # carga la librería; start_session llama PATH=... tmux new-session
    └── lib/
        └── agent_path.sh            # NUEVO: agent_path_compose (POSIX)
scripts/
├── agentctl                         # cmd_mcp corre claude mcp dentro de sh -c con el PATH compuesto
└── heartbeat/
    └── heartbeat.sh                 # carga la librería (HEARTBEAT_AGENT_PATH_LIB); el tick llama PATH=... tmux new-session
tests/
├── agent-user-bin-path.bats         # NUEVO: oráculo del host (13)
├── agentctl.bats                    # se actualiza la prueba de agentctl mcp
└── docker-e2e-user-bin-path.bats    # NUEVO: e2e en contenedor (5), gated
docs/architecture.md                 # una línea en el modelo de privilegios
CHANGELOG.md, VERSION                # 0.31.0
CLAUDE.md                            # bloque de la feature, a mano (git add -f)
```

**Structure Decision**: la librería vive solo en `docker/scripts/lib/`, como `state.sh` e `interval.sh`. El modo local no la necesita (FR-006) y `docker/` viaja entero al workspace, así que no hace falta un espejo en `scripts/lib/` ni tocar `setup.sh`.

## Orden de implementación (para `/speckit-tasks`)

1. **Línea base** (V1) sobre una copia aislada de `origin/main`, en los dos bash.
2. **Oráculo en ROJO**: escribir `tests/agent-user-bin-path.bats` y ver caer las 11 que deben caer, y en verde H2 y G1, en los dos bash.
3. **Librería** (C1): P1 a P6 en verde.
4. **Sesión** (C2): S1 y S2 en verde. Confirmar que el oráculo de sha de `_run_watchdog` sigue verde.
5. **Heartbeat** (C3): H1 y H2 en verde.
6. **agentctl** (C4): A1 en verde y la prueba de `tests/agentctl.bats` actualizada.
7. **Dockerfile** (C5): G2 en verde y G1 sigue en verde.
8. **Mutaciones** M0 a M26 en los dos bash, más la pata Linux.
9. **E2E nuevo** (E1 a E5) y **DOCKER_E2E entero**, con COMPUERTA.
10. **Documentos**: comentario de 036, `docs/architecture.md`, CHANGELOG, `VERSION` 0.31.0 y `CLAUDE.md`.
11. **Revisión independiente** de solo lectura antes del gate completo, y después el **gate completo** del host (V4).
12. **Commits** (COMPUERTA), **push** (COMPUERTA) y **gate en cbum** (COMPUERTA, V6).
13. **PR**. El **merge** es del operador. Después, el **despliegue** de donna y linus y el cierre documental (V7).

## Complexity Tracking

Sin violaciones de la constitución que justificar.
