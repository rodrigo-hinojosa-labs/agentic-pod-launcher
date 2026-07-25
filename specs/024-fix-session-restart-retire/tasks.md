# Tasks: reiniciar el agente deja de romper el enlace del cliente

**Feature**: 024-fix-session-restart-retire · **Branch**: `024-fix-session-restart-retire` (base `main`=`9b97654`)
**Plan**: [plan.md](./plan.md) · **Contrato**: [contracts/session-stop-classification.md](./contracts/session-stop-classification.md)
**Gates**: [quickstart.md](./quickstart.md)

Test-first no es opcional acá (Principio III). Cada fase de historia escribe sus tests, los
confirma **ROJOS**, y recién entonces toca producción.

**Dos reglas que atraviesan todo el archivo:**

1. **La suite corre en las dos versiones de bash.** Un verde en una sola no prueba nada
   (lección de 023).

   ```bash
   bats tests/                      # bash del PATH (5.x)
   PATH="/bin:$PATH" bats tests/    # bash de stock (3.2)
   ```

2. **Los fixtures se alimentan con los valores MEDIDOS**, nunca con valores elegidos a
   mano. Esa es la causa raíz de por qué la suite dejó pasar el defecto de 022: cada test
   verificaba que la regla implementara lo que el autor creía, no que lo que el autor
   creía fuera cierto ([research.md](./research.md) R6). Los valores están en la tabla de
   R2 y en el contrato §1.2.

---

## Phase 1: Setup

- [X] T001 Línea base: **1159 ok / 0 not ok en ambas versiones**, medida sobre este mismo
      contenido (`main`=`9b97654`) antes de crear la rama. NOTA HONESTA: el intento de
      recapturarla en background durante esta sesión quedó **contaminado** —corría las dos
      versiones en secuencia mientras yo ya editaba archivos, así que la corrida de 3.2
      reportó 1176 ok / 4 not ok (más tests que la base, y las 4 fallas eran los tests de
      política que 024 cambia a propósito). Esa medición se descarta; la válida es la
      anterior. Lección: una línea base no se toma en paralelo con la edición.
- [X] T002 Verificar que la sonda del contrato §7 reproduce la medición en este entorno:
      `sh specs/024-fix-session-restart-retire/probes/confirm-probe.sh` en un host con
      systemd de usuario. **Si no hay host systemd disponible en este momento, marcar la
      tarea como diferida al gate de hardware y decirlo**, en vez de darla por hecha.

---

## Phase 2: Foundational — la clasificación (BLOQUEANTE)

**Todo lo demás depende de esta fase.** Es el cambio de contrato de la lib.

### Tests (escribir primero, confirmar ROJO)

- [X] T003 En `tests/session-pointer.bats`, agregar los casos **C1-C10** del contrato §3.1
      contra `session_decide`, cada uno asertando la decisión completa esperada y **con el
      identificador del caso en el nombre del test**. Confirmar ROJO: hoy C1 devuelve
      `retire` en vez de `keep`.
- [X] T004 [P] Agregar en `tests/session-pointer.bats` la cobertura de lectura del campo
      nuevo `stop_cause`: presente/ausente/truncado, contra los helpers `_session_marker_field`
      y `_session_marker_has_field` (`scripts/lib/session_pointer.sh:150,157`), que hoy solo
      saben leer `exit_code`. Un fichero truncado debe leer "no se puede determinar", nunca
      un valor vacío pero válido.
- [X] T005 [P] Agregar el test de **fusión** del marcador: `ExecStop` crea con causa,
      `ExecStopPost` fusiona los campos de salida, y el resultado conserva **ambos**.
      Es el invariante del diseño de marcador único (data-model §Decisión estructural).
- [X] T006 Confirmar que T003-T005 están **ROJOS** en las dos versiones de bash.

### Implementación

- [X] T007 Extender `session_exit_marker_write` en `scripts/lib/session_pointer.sh:129-147`
      para aceptar y persistir `stop_cause`, **preservando** el valor ya presente cuando el
      llamador no lo aporta (la fusión de `ExecStopPost`). Sin `jq`: se sigue usando
      `printf`, porque `jq` puede faltar en el host del agente.
- [X] T008 Generalizar `_session_marker_field` / `_session_marker_has_field`
      (`:150-159`) para leer cualquier campo, conservando la semántica de "presente y
      completo" que hoy protege contra ficheros truncados.
- [X] T009 Reescribir `session_decide` (`:212-224`) según la tabla del contrato §3.1.
      **El default ante incertidumbre pasa a ser `keep`** — es lo contrario de hoy y es el
      corazón de la feature (FR-004).
- [X] T010 Confirmar **VERDE** de T003-T005 en ambas versiones y
      `shellcheck -S error scripts/lib/session_pointer.sh` limpio.

**Checkpoint**: la clasificación es correcta y portable, aún sin conectar a systemd.

---

## Phase 3: User Story 1 — reiniciar no le quita la conversación al operador (P1)

**Goal**: un `systemctl restart` con sesión viva conserva el puntero y el enlace.
**Independent test**: reiniciar el servicio y comprobar que el `sessionId` no cambió y que
no apareció hermano retirado.

### Tests (escribir primero, confirmar ROJO)

- [X] T011 [P] [US1] En `tests/local-session-hooks.bats`, cubrir el hook de `ExecStop`:
      con `EXIT_CODE` **vacío** escribe `stop_cause=external`; con `EXIT_CODE` **definido**
      escribe `session-ended`. Son los dos valores MEDIDOS (contrato §1.2), no inventados.
- [X] T012 [P] [US1] Cubrir el flujo completo de los tres hooks para C1: `ExecStop`
      (vacío) → `ExecStopPost` → `ExecStartPre` **conserva** el puntero y no crea hermano
      retirado. **El nombre del test debe mencionar el reinicio** (contrato §6).
- [X] T013 [US1] Confirmar ROJO de T011-T012: el hook de `ExecStop` todavía no existe.

### Implementación

- [X] T014 [US1] Crear `modules/local-session-stop.sh.tpl`, el hook de `ExecStop`: clasifica
      por `${EXIT_CODE:-}` y escribe la causa en el marcador. Sale **0 siempre**
      (Principio IV). **En su comentario de cabecera, NO escribir que `ExecStop` significa
      "systemd nos está deteniendo"** — es la hipótesis refutada (contrato §2), el comentario
      queda renderizado en la unit instalada y le enseñaría el modelo mental equivocado al
      próximo lector.
- [X] T015 [US1] Agregar la directiva `ExecStop=-.../agent-session-stop.sh` en
      `modules/systemd-remote-control.service.tpl`, **antes** de `ExecStopPost` y con el
      prefijo `-` (contrato §4).
- [X] T016 [US1] Renderizar el hook nuevo en `setup.sh`, al lado de los dos que 022 ya
      renderiza (`setup.sh:2303-2304`), con permisos de ejecución.
- [X] T017 [US1] Adaptar `modules/local-session-exit.sh.tpl` para que **fusione** en vez de
      sobrescribir, preservando el `stop_cause` que dejó `ExecStop`.
- [X] T018 [US1] Confirmar VERDE de T011-T012 en ambas versiones de bash.

**Checkpoint**: el defecto medido está muerto en la lógica. MVP cerrado.

---

## Phase 4: User Story 2 — una sesión que termina sola sigue limpiándose (P1)

**Goal**: no reintroducir el bug original de 022 al arreglar US1.
**Independent test**: simular el fin de sesión y comprobar que el puntero se retira.

> US2 es P1 junto con US1 **a propósito**: arreglar una sin la otra deja el sistema roto
> por el lado contrario, y ese lado (agente inalcanzable) es peor que el defecto actual.

- [X] T019 [P] [US2] Cubrir C2 en `tests/local-session-hooks.bats`: `ExecStop` con
      `EXIT_CODE` definido → `ExecStartPre` **retira** el puntero y **lo renombra**, nunca
      lo borra (FR-005). Confirmar ROJO primero.
- [X] T020 [P] [US2] Cubrir C3, el borde medido: salir solo con código ≠ 0 **omite
      `ExecStop`** por completo, así que no hay `stop_cause` y la decisión sale de
      `service_result=exit-code`. **Ojo con generalizar**: el caso `ignora TERM` también
      termina en fallo y ahí `ExecStop` SÍ corre.
- [X] T021 [P] [US2] Cubrir C9 (compatibilidad hacia atrás): una unit **sin** la directiva
      `ExecStop` nunca escribe `stop_cause` → debe **conservar**. Es lo que evita que una
      actualización a medio aplicar siga destruyendo conversaciones.
- [X] T022 [P] [US2] Cubrir C10 (carrera): dos arranques competidores; solo uno gana el
      `rename` de `session_exit_marker_consume` (`:179`) y el perdedor cae en la rama
      conservadora.
- [X] T023 [US2] Confirmar VERDE de T019-T022 en ambas versiones.

**Checkpoint**: los dos casos se atienden bien. Ya no hay que elegir cuál romper.

---

## Phase 5: User Story 3 — el operador puede saber qué pasó (P2)

**Goal**: causa y decisión legibles sin leer el código.

- [X] T024 [P] [US3] En `modules/local-session-check.sh.tpl`, emitir los textos del
      contrato §5.1 — uno por caso, nombrando **causa y decisión**. La línea actual (`:55`)
      afirma "stale" sin decir en qué se basó, y eso es parte de por qué el defecto pasó
      desapercibido.
- [X] T025 [P] [US3] En `scripts/agentctl`, reportar en el diagnóstico local la causa y la
      decisión del último arranque.
- [X] T026 [US3] En `scripts/agentctl`, verificar que la **unit instalada** ejecuta la
      directiva `ExecStop`, leyéndola con `systemctl show -p ExecStop` y **NO** con
      `systemctl cat`, que da `Permission denied` en una unit root-only y haría que el check
      se saltara en silencio (lección medida en el gate de 021).
- [X] T027 [US3] Cobertura en `tests/agentctl-local.bats` para T025-T026. **Cada aviso
      necesita su propia aserción**: en 022 un test que compartía hint entre dos avisos
      pasaba por la razón equivocada y solo lo destapó la mutación
      (`specs/022-local-session-lifecycle/tasks.md:165`).
- [X] T028 [US3] Confirmar VERDE en ambas versiones.

---

## Phase 6: Polish & cross-cutting

- [X] T029 Suite completa **en las dos versiones**, cero fallas en ambas. Anotar los dos
      conteos y las dos versiones exactas de bash en el PR.
- [X] T030 `shellcheck -S error setup.sh scripts/agentctl scripts/lib/*.sh` limpio.
- [X] T031 **Mutación (SC-004)**: revertir `session_decide` a la regla actual
      (`if [ "$marker" = "killed" ]` → `keep`, si no `retire`) y confirmar que el rojo
      **incluye un test cuyo nombre menciona el reinicio**. Si el único rojo fuera un test
      genérico, la historia no está cumplida. Restaurar y anotar el resultado.
- [X] T032 Gate de no-regresión: `--regenerate` sobre un `agent.yml` existente produce la
      unit con la directiva nueva y **sin otros cambios**. Verificar por `diff`, no por
      inspección visual.
- [X] T033 `CHANGELOG.md` + `VERSION`. **Verificar `VERSION` contra `origin/main` A MANO
      al abrir el PR**: 023 destapó que dos ramas que escriben el mismo número hacen que
      git auto-mergee `VERSION` **sin marcar conflicto** — el conflicto es semántico, no
      textual, y el rebase no lo delata.
- [X] T034 Nota de despliegue en el CHANGELOG: un workspace existente **no se corrige
      solo**. Hay que correrle `--regenerate` **y reinstalar la unit**, porque
      `--regenerate` no reinstala cuando `sudo` no está disponible (`setup.sh:2464`,
      fallback staged en `:2469-2473`) y **nunca** reinicia.
- [X] T035 Documentar el límite de cobertura (FR-011): la suite corre en macOS, donde no
      hay systemd, así que **no puede** verificar que systemd entregue esos valores. Decir
      qué gate lo cubre, en vez de dejar que el verde de la suite sugiera una cobertura que
      no existe.

---

## Phase 7: GATE DE HARDWARE — corre ANTES del merge (SC-006)

> **Van dos features seguidas mergeadas sin su gate.** En 021 correrlo después costó el
> PR #79 con dos bugs de portabilidad invisibles para la suite de macOS. En 022 costó el
> defecto que esta feature arregla — y era un defecto de **premisa de diseño**, no de
> portabilidad. **No una tercera vez.**

- [ ] T036 Portar el delta al workspace de mclaren, midiendo divergencia por hash antes de
      sobrescribir y dejando backups `.bak-pre024`. El workspace vivo está en
      `/home/rodrigo-hinojosa/Documents/Personal/Claude/Agents/mclaren-admin`.
- [ ] T037 `./setup.sh --regenerate` y verificar los artefactos **staged**: la unit con la
      directiva `ExecStop`, y el hook nuevo renderizado y ejecutable. `sudo` pide
      contraseña en mclaren, así que la unit queda staged y **no** instalada.
- [X] T038 **GATE DE PRODUCCIÓN CERRADO (2026-07-24 23:28, mclaren, con `sudo` del operador).**
      El operador instaló la unit de PRODUCCIÓN (`sudo cp` + `daemon-reload` + `restart`).
      Verificado en el host, todo lectura, sin imprimir secretos: `systemctl show -p ExecStop`
      confirma `agent-session-stop.sh` instalado; servicio `active/running`, `Result=success`.
      **La medición decisiva, en el journal del system-unit (que SÍ es consultable, a diferencia
      del user-unit del gate de composición):**
      `agent-session-check.sh[500444]: … previous stop was external (systemd) — session pointer kept`.
      El `sessionId` es **byte-idéntico a ambos lados del reinicio**: pid viejo `claude[2118]` y
      pid nuevo `claude[500467]` reportan el mismo `session_01A1obgNuL2XkXLX7bdr6nQV`, y el
      `bridge-pointer.json` vivo apunta a ese. **El vendor reconectó a la misma sesión, no anunció
      una nueva** — exactamente lo contrario del bug de 022, que en el gate del Jul 20 retiró el
      puntero (`.retired.json` del Jul 20 lleva otro `sessionId`, `…UsHot8`). El marcador de causa
      fue consumido por rename (ya no existe `session-exit.json`). `agentctl doctor`: sin WARN de
      `ExecStop` faltante.
- [X] T039 **SC-001 (parte mecánica) CERRADA** vía gate de composición
      (`probes/compose-gate.sh`): los **tres hooks reales renderizados**, cableados a una
      unit de systemd **de usuario** (sin `sudo`, sin tocar el agente), sobre un workspace
      desechable con un `claude` falso que atrapa SIGTERM y sale 0 como el real. Medido:
      un `systemctl --user restart` **conserva** el puntero, byte-idéntico, sin hermano
      retirado. Esto valida la **composición** —el hueco exacto por el que se coló 022—.
      **CERRADA TAMBIÉN EN PRODUCCIÓN (T038, 2026-07-24)**: un `systemctl restart` real de la
      unit de producción conservó el puntero con `sessionId` idéntico y el journal nombró
      `external → session pointer kept`. Confirmación visual desde el celular: queda al operador
      (la identidad del `sessionId` reconectado es la prueba de alcance).
- [X] T040 **SC-002 (parte mecánica) CERRADA** por el mismo gate: un self-exit del proceso
      **retira** el puntero. Sin regresión de 022. **PENDIENTE (solo operador)**: que el
      agente quede alcanzable en una sesión nueva desde el cliente.
- [X] T041 **SC-003 CERRADA**: las cuatro cadenas del hook real capturadas de su stderr —
      `external`→"session pointer kept", `session-ended`→"retired stale pointer",
      fallo-propio→"exited with failure", sin-marcador→"conservative default". Cada una
      nombra causa Y decisión. El `agentctl doctor` cazó en vivo la unit instalada sin
      `ExecStop` (T037). NOTA: el journal del user-unit no es consultable en este arnés
      (`-- No entries --`), por eso se capturó el stderr directo; el journal del
      **system-unit** de producción sí funciona (se leyó en el gate de 022).
- [X] T042 **SC-007 CERRADA** por el gate: un marcador **truncado** no destruye un puntero
      vivo. Ficheros desechables; nunca se imprimió contenido del puntero real.
- [X] T043 Resultado del gate anotado (aquí y en el cuerpo del PR): composición **7/7 en lo
      mecánico** (2 "FAIL" eran el journal del user-unit, refutados por la captura de
      stderr). **Tramo de PRODUCCIÓN CERRADO (T038, 2026-07-24 23:28):** el journal del
      system-unit —que sí es consultable— capturó la línea del check hook real
      (`external → session pointer kept`) y el `sessionId` sobrevivió byte-idéntico al reinicio.
      El gate de hardware corrió **antes del merge** (SC-006), rompiendo el patrón de 021/022.

---

## Phase 8: Cierre

- [ ] T044 Abrir el PR contra `main`. **No mergear sin confirmación explícita**: `main`
      está protegida.
- [ ] T045 Al mergear: actualizar el bloque SPECKIT de `CLAUDE.md` marcando 024 MERGED con
      su SHA, y registrar el resultado del gate T036-T043.

---

## Dependencies

```text
Phase 1 (Setup)
    └── Phase 2 (clasificación en session_pointer.sh)   ← BLOQUEA todo
            ├── Phase 3 (US1 · P1) ── hook de ExecStop + directiva
            │       └── Phase 4 (US2 · P1) ── depende de US1: los hooks ya existen
            └── Phase 5 (US3 · P2) ── observabilidad [necesita la lib, NO los hooks]
                    └── Phase 6 (Polish)
                            └── Phase 7 (GATE DE HARDWARE)  ← ANTES del merge
                                    └── Phase 8 (Cierre)
```

- **US2 depende de US1**, a diferencia del patrón habitual: sus casos ejercitan el hook de
  `ExecStop` que US1 crea. No se pueden entregar en el orden inverso.
- **US3 no depende de US1/US2.** Toca la lib y el diagnóstico; se puede construir en
  paralelo una vez cerrada la Phase 2.
- **T017 debe entrar junto con T014**, nunca después: si `ExecStop` empieza a escribir
  `stop_cause` y `ExecStopPost` sigue sobrescribiendo el fichero entero, la causa se pierde
  y C1 vuelve a fallar en silencio.

## Parallel opportunities

- **Phase 2 tests**: T004 y T005 son ficheros/aserciones independientes.
- **Phase 4 completa**: T019-T022 son cuatro casos independientes del oráculo.
- **Phase 5**: T024 (plantilla) y T025 (agentctl) tocan archivos distintos.
- **Phase 3 y Phase 5** pueden avanzar en paralelo tras el checkpoint de Phase 2.

## Implementation strategy

**MVP = Phase 2 + Phase 3 + Phase 4.** Las dos historias P1 van juntas porque entregar una
sola deja el sistema roto por el otro lado. Phase 5 (observabilidad) es entregable después
sin bloquear el arreglo, pero **antes** del gate de hardware: sin ella, el gate no puede
verificar SC-003.

**El gate de hardware no es opcional ni posponible.** Es la única cobertura que existe para
la parte del comportamiento que la suite host no puede tocar, y las dos features anteriores
demostraron el costo de saltárselo.
