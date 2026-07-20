# Implementation Plan: el motor de render deja de corromper valores con `&`

**Branch**: `023-fix-render-ampersand` | **Date**: 2026-07-19 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/023-fix-render-ampersand/spec.md`

## Summary

Dos líneas de `scripts/lib/render.sh` (`:90` y `:95`) expanden los campos de un bloque
`{{#each}}` con `${var//patrón/reemplazo}`. Desde bash 5.2 el `&` del *reemplazo*
significa "todo el texto coincidente", así que un valor de `agent.yml` con `&` se
reescribe solo, en silencio. Medido corrupto en bash 5.3.15 (este equipo) y en **5.2.37
(mclaren, host de agente en producción)**.

El arreglo **elimina el concepto de cadena de reemplazo** en vez de escapar sus
caracteres especiales: se reemplaza la sustitución de patrones por un recorrido con
expansiones de prefijo/sufijo (`${t%%"$p"*}` / `${t#*"$p"}`), que no tienen semántica
especial en ninguna versión de bash. Medido correcto en las tres versiones disponibles
(3.2.57, 5.2.37, 5.3.15) sobre nueve casos, incluido el autorreferencial.

Alcance secundario, y es la causa de que el bug viviera meses sin verse: el proyecto
declara compatibilidad de bash que no prueba. Se corrige la afirmación y se deja el
resultado de la suite atado a la versión con que se obtuvo.

## Technical Context

**Language/Version**: bash. Rango medido y a sostener: **3.2.57 … 5.3.15**. Sin piso
declarado hoy; el proyecto afirma equivalencia entre versiones y esa afirmación es falsa.

**Primary Dependencies**: `yq` v4+, `perl` (ya requerido por las otras tres funciones de
`render.sh`), `jq`, `git`. **Esta feature no agrega ninguna.**

**Storage**: N/A — el motor transforma texto; el estado vive en `agent.yml` y los
artefactos renderizados.

**Testing**: `bats-core` 1.13.0. `tests/render.bats` es el archivo dueño del contrato.

**Target Platform**: host del operador (macOS y Linux). `render.sh` es **host-side puro**:
no está espejado a `docker/` (`find docker -name render.sh` vacío, el `Dockerfile` no lo
copia), así que esta feature **no** necesita `DOCKER_E2E`.

**Project Type**: CLI / motor de plantillas dentro del launcher.

**Performance Goals**: irrelevante a esta escala — el render hace ~12-30 sustituciones por
workspace. Medido igual: 200 sustituciones en <1s con el mecanismo elegido, sin
subprocesos.

**Constraints**: salida byte-idéntica para cualquier `agent.yml` que no contenga `&`
(FR-005); preservar `$1`/`\1` literales (FR-004); cero dependencias nuevas.

**Scale/Scope**: dos líneas de producción, una función nueva, un archivo de tests.

## Constitution Check

*GATE: pasa antes de Fase 0. Re-evaluado tras Fase 1 — sin cambios.*

- [x] **I. Single Source of Truth** — PASS. El arreglo hace que `agent.yml` sea *más*
  fielmente la fuente de verdad: hoy un valor del operador llega alterado al artefacto.
  Nada se hand-edita; el cambio sobrevive `--regenerate` por construcción (es el
  renderizador mismo).
- [x] **II. Least-Privilege** — N/A. No toca `docker/`, capacidades, montajes ni `docker
  exec`. `render.sh` no viaja a la imagen.
- [x] **III. Test-First, Host-Runnable** — PASS. El oráculo existe (`tests/render.bats`) y
  ya está rojo; se agrega uno **dedicado al `&`** (FR-006) antes de tocar producción. Corre
  sin Docker. `shellcheck -S error` limpio.
- [x] **IV. Idempotent, Fail-Silent** — N/A. El motor es una transformación pura, sin
  lifecycle, sin sentinelas, sin supervisor.
- [x] **V. Workspace-Is-the-Agent** — PASS. No toca `.state/`. **Relevante en un punto**:
  el bug corrompe justamente el `.env` generado, que es donde viven los secretos — el
  arreglo protege ese archivo, no lo expone. Ningún test imprime valores de secretos.
- [x] **VI. Reproducible, Pinned Dependencies** — PASS. Sin dependencias nuevas ni pines
  nuevos. `CHANGELOG.md` + `VERSION` se actualizan (cambio visible para el usuario:
  artefactos que hoy salen mal empiezan a salir bien).

**Sin violaciones. Complexity Tracking vacío a propósito.**

## Project Structure

### Documentation (this feature)

```text
specs/023-fix-render-ampersand/
├── spec.md
├── plan.md              # este archivo
├── research.md          # Fase 0 — las mediciones que descartan 2 de 4 candidatos
├── data-model.md        # Fase 1
├── quickstart.md        # Fase 1 — cómo verificar en las dos versiones de bash
├── contracts/
│   └── field-substitution.md
└── checklists/requirements.md
```

### Source Code (repository root)

```text
scripts/lib/render.sh          # CAMBIA: :90 y :95 -> nueva primitiva; función nueva
tests/render.bats              # CAMBIA: test dedicado al `&` + casos adversariales
CLAUDE.md                      # CAMBIA: la afirmación falsa sobre versiones de bash
README.md                      # CAMBIA (si repite la afirmación — verificar)
CHANGELOG.md, VERSION          # CAMBIA: 0.14.0 -> 0.15.0 (o 0.13.0 -> 0.14.0 si 022 no mergea antes)

modules/mcp-json.tpl           # NO cambia — consumidor, sirve de test end-to-end
modules/env-example.tpl        # NO cambia — idem
docker/**                      # NO cambia — render.sh no vive ahí
```

**Structure Decision**: no hay estructura nueva. El cambio es una función nueva en una lib
existente más sus dos call sites. La superficie mínima es deliberada: el defecto es de
*mecanismo*, y ampliar el alcance a "revisar todas las sustituciones del repo" ya se hizo
en la Fase 0 (las otras cuatro usan reemplazos literales y quedan como están).

## Complexity Tracking

Sin violaciones que justificar.
