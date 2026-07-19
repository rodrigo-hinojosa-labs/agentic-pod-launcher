# Tasks: el motor de render deja de corromper valores con `&`

**Feature**: 023-fix-render-ampersand · **Branch**: `023-fix-render-ampersand` (base `main`=`7e50c44`)
**Plan**: [plan.md](./plan.md) · **Contrato**: [contracts/field-substitution.md](./contracts/field-substitution.md)
**Gate**: [quickstart.md](./quickstart.md) §3

Test-first no es opcional acá (Principio III). Cada fase de historia escribe sus tests, los
confirma **ROJOS**, y recién entonces toca producción.

**Regla que atraviesa todo el archivo**: la suite se corre **en las dos versiones de bash**.
Un verde en una sola no prueba nada — ese es literalmente el bug que estamos arreglando.

```bash
bats tests/                      # bash del PATH (5.x)
PATH="/bin:$PATH" bats tests/    # bash de stock (3.2)
```

---

## Phase 1: Setup

- [ ] T001 Registrar la línea base en ambas versiones: correr `bats tests/` y
      `PATH="/bin:$PATH" bats tests/`, y anotar en el PR el conteo de cada una junto a la
      salida de `bash --version | head -1` y `/bin/bash --version | head -1`. Se espera
      **1 falla bajo 5.x** (`tests/render.bats` "preserves literal `$1` and `\1`") y **cero
      bajo 3.2**. Si ambas dan cero, el bash del PATH no es ≥5.2 y el resto de la feature no
      se puede verificar — parar y resolver eso primero.

---

## Phase 2: Foundational — la primitiva (BLOQUEANTE)

**Todo lo demás depende de esta fase.** Es la única pieza nueva de producción.

- [ ] T002 En `tests/render.bats`, agregar los 10 casos oráculo del contrato §3 (A1-A10)
      contra `_render_replace_all`, con plantilla `ref={{u}}!` y placeholder `{{u}}`. Cada
      caso asserta la salida completa esperada, no un `grep` parcial. Confirmar **ROJO**:
      la función no existe todavía.
- [ ] T003 Implementar `_render_replace_all TEXT PLACEHOLDER VALUE` en
      `scripts/lib/render.sh`, junto a las otras funciones `_render_*`, con el cuerpo del
      contrato §1. **Las comillas de `*"$p"*`, `${t%%"$p"*}` y `${t#*"$p"}` son
      load-bearing**: sin ellas el placeholder se compara como glob. Documentar en el
      comentario por qué NO se escapa el `&` (rompe bash 3.2 — research.md R3).
- [ ] T004 Confirmar **VERDE** de T002 en las dos versiones de bash, y
      `shellcheck -S error scripts/lib/render.sh` limpio.

**Checkpoint**: la primitiva es correcta y portable, aún sin conectar.

---

## Phase 3: User Story 1 — un valor de configuración llega intacto al artefacto (P1)

**Goal**: un valor con `&` en `agent.yml` aparece idéntico en el `.env` y el `.mcp.json`.
**Independent test**: renderizar las plantillas reales y comparar contra el valor original.

### Tests (escribir primero, confirmar ROJO)

- [ ] T005 [P] [US1] En `tests/render.bats`, agregar E2 end-to-end: un `agent.yml` con
      `mcps.atlassian[0].url: "https://x.example/p?a=1&b=2"` renderizado por
      `modules/env-example.tpl` produce una línea que contiene la URL **exacta**. Es el
      escenario del operador real, no un unit test de la primitiva.
- [ ] T006 [P] [US1] Agregar E6: la variante **mayúscula** (`{{NAME}}`, `render.sh:95`) con
      un valor que contenga `&`. Debe ser un caso propio y no compartir aserción con la
      minúscula — arreglar solo una de las dos líneas dejaría medio bug vivo (FR-003).
- [ ] T007 [P] [US1] Agregar E5, no-regresión: un `agent.yml` **sin ningún `&`** produce
      salida byte-idéntica a la actual, para `mcp-json.tpl` y `env-example.tpl`. Es lo que
      protege a los workspaces ya desplegados (FR-005). Capturar la salida esperada ANTES
      de tocar los call sites.
- [ ] T008 [US1] Confirmar que T005-T007 están **ROJOS** bajo bash ≥5.2 (salvo T007, que
      debe estar verde antes y después — su valor es demostrar que no cambia).

### Implementación

- [ ] T009 [US1] Reemplazar el call site de minúsculas, `scripts/lib/render.sh:90`, por
      `row_expanded=$(_render_replace_all "$row_expanded" "{{${field}}}" "$fval")`.
- [ ] T010 [US1] Reemplazar el call site de mayúsculas, `scripts/lib/render.sh:95`, por la
      forma equivalente con `$field_upper` / `$fval_upper`. **Va en la misma entrega que
      T009**, nunca después.
- [ ] T011 [US1] **NO tocar** `scripts/lib/render.sh:105-110` (la sustitución del bloque
      completo con perl `ENV{REPL}` + `/e`). Es correcta; esta tarea es la verificación
      explícita de que quedó intacta — `git diff` no debe mostrar esas líneas.
- [ ] T012 [US1] Confirmar **VERDE** de T005-T007 y del test heredado E4
      (`tests/render.bats` "preserves literal `$1` and `\1`", que hoy es el rojo original)
      en **ambas** versiones de bash.

**Checkpoint**: el bug está muerto y demostrado end-to-end. MVP cerrado.

---

## Phase 4: User Story 2 — el rojo del test nombra su propia causa (P2)

**Goal**: quien vea el rojo entiende la causa sin reconstruir el diagnóstico.
**Independent test**: reintroducir el defecto y leer el nombre del test que falla.

- [ ] T013 [US2] Agregar en `tests/render.bats` el test dedicado del contrato §5, con un
      nombre que mencione explícitamente el `&` y la semántica que lo causa — p. ej.
      `render_template preserves a literal & in field values (bash 5.2+ ksh93 semantics)`.
      Debe cubrir al menos A1, A4 y A7 del contrato §3.
- [ ] T014 [US2] **A4 merece su propia aserción**: hoy en bash ≥5.2 un `\&` escrito por el
      operador pierde el backslash (`ref=&!`). El contrato exige devolverlo tal cual. Ese
      caso no lo cubre ningún test existente.
- [ ] T015 [US2] Mutación: revertir **un** call site a `${var//…}`, correr la suite bajo
      bash ≥5.2 y confirmar que el rojo incluye el test de T013. Si el único rojo fuera el
      test heredado de `$1`/`\1`, la historia no está cumplida. Restaurar y anotar el
      resultado en el PR.

**Checkpoint**: el diagnóstico está en el nombre, no en la cabeza de quien lo vivió.

---

## Phase 5: User Story 3 — la suite dice bajo qué bash corrió (P3)

**Goal**: cerrar la causa de fondo — que un mismo commit dé verde o rojo según la máquina.
**Independent test**: leer la salida de la suite y la documentación, y que ambas digan lo mismo.

- [ ] T016 [P] [US3] Corregir la afirmación de `CLAUDE.md:11`: hoy dice que no hay piso de
      versión "porque no se usan constructos de bash 4+". Eso confunde *no usar constructos
      nuevos* con *comportarse igual*. El texto debe decir que el rango sostenido es 3.2+ y
      que se sostiene **porque se prueba en ambas**, citando el caso del `&` como precedente.
- [ ] T017 [P] [US3] Corregir la misma afirmación en `README.md:20`.
- [ ] T018 [US3] Agregar el guard de no-drift E7 en `tests/render.bats` (o donde vivan los
      otros `no-drift`): `scripts/lib/render.sh` no debe contener ninguna sustitución
      `${var//…}` cuyo reemplazo venga de datos. **Filtrar las líneas de comentario antes de
      grepear** — el archivo va a documentar el patrón prohibido en prosa, y un grep ingenuo
      matchea la explicación en vez del código (ese error se cometió 4 veces en la sesión de
      022). El guard NO debe matchear la primitiva nueva, que usa `%%` y `#`.
- [ ] T019 [US3] Hacer que la corrida de la suite exponga la versión del intérprete
      (FR-009): un `@test` que emita `$BASH_VERSION` a `&3` en un archivo apropiado.
      Verificar que sea visible en una corrida normal de `bats tests/`, no solo con flags.

**Checkpoint**: la próxima divergencia entre versiones se ve, en vez de esconderse meses.

---

## Phase 6: Polish & cross-cutting

- [ ] T020 Suite completa **en las dos versiones**, cero fallas en ambas (SC-004). Anotar
      los dos conteos y las dos versiones exactas en el PR.
- [ ] T021 `shellcheck -S error setup.sh scripts/agentctl scripts/lib/*.sh` limpio.
- [ ] T022 Gate G3 del quickstart: `--regenerate` sobre un `agent.yml` sin `&` produce
      artefactos byte-idénticos a los previos al cambio (`diff` vacío de `.mcp.json` y
      `.env.example`).
- [ ] T023 `CHANGELOG.md` + `VERSION`. **Ojo con el número**: esta rama está en `0.13.0`
      porque salió de `main`=`7e50c44`; el PR #80 (022) sube a `0.14.0` y **no está
      mergeado**. Si 022 entra primero, rebasar y usar `0.15.0`; si entra 023 primero,
      `0.14.0` y 022 rebasa. Verificar `VERSION` contra `origin/main` al momento de abrir
      el PR, no antes.
- [ ] T024 Nota de despliegue en el CHANGELOG: el arreglo es del renderizador, así que un
      workspace existente **no se corrige solo** — hay que correrle `--regenerate`. En un
      workspace sin `&` eso es un no-op byte-idéntico (T022), así que es seguro en todos.
- [ ] T025 Abrir el PR contra `main`. **No mergear sin confirmación explícita**: `main` está
      protegido. Nunca stagear `.claude/settings.json`.
- [ ] T026 Medir ferrari cuando vuelva el túnel SSH (única pregunta abierta de la Fase 0):
      `bash --version` y el **conteo** de valores con `&` en su `agent.yml` — nunca imprimir
      los valores. Si el conteo es >0, ese workspace necesita `--regenerate` después del
      despliegue y conviene revisar su `.env` antes de confiar en él. **No bloquea el
      merge**; sí debe quedar registrado.
- [ ] T027 Al mergear: actualizar el bloque SPECKIT de `CLAUDE.md` a MERGED con el SHA, y
      dejar anotado el resultado de T026.

---

## Dependencias

```text
Phase 1 (baseline)
    └── Phase 2 (la primitiva)  ── BLOQUEA todo lo demás
            ├── Phase 3 (US1 · P1) ── los dos call sites   [MVP]
            │       └── Phase 4 (US2 · P2) ── el nombre del test
            └── Phase 5 (US3 · P3) ── docs + guard + versión  [independiente de US1/US2]
                    └── Phase 6 (Polish → PR)
```

- **T009 y T010 son inseparables**: los dos call sites en la misma entrega, o queda medio
  bug vivo por la variante en mayúsculas.
- **T007 debe capturarse ANTES de T009/T010**, o no hay contra qué comparar la
  no-regresión.
- **T023 depende del estado de `origin/main`** al momento de abrir el PR, no del de hoy.

## Oportunidades de paralelismo

- **Phase 3 tests**: T005, T006 y T007 son bloques `@test` independientes.
- **Phase 5**: T016 y T017 son dos archivos distintos; T018 y T019 tocan tests distintos.
- **Phase 5 completa** puede correr en paralelo con Phase 3/4 — no comparte archivos de
  producción con ellas.

## Estrategia de entrega

**MVP = Phase 2 + Phase 3.** Con eso el bug está muerto y demostrado end-to-end sobre las
plantillas reales, en las dos versiones de bash. Phase 4 hace el rojo legible y Phase 5
ataca la causa de fondo; ninguna de las dos es necesaria para que el arreglo funcione, pero
Phase 5 es la que evita la próxima clase entera de bugs como este.
