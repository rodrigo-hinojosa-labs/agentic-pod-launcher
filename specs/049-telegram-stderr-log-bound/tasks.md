---
description: "Lista de tareas de la feature 049: log de stderr del canal de Telegram acotado y sin bucle de EPIPE"
---

# Tasks: Log de stderr del canal de Telegram acotado y sin bucle de EPIPE

**Input**: `specs/049-telegram-stderr-log-bound/` (spec.md, plan.md, research.md, data-model.md, contracts/, quickstart.md)

**Tests**: obligatorios. El Principio III de la constitución exige que cada cambio de comportamiento parta por una prueba que falla. Toda tarea de implementación va precedida por la tarea que escribe sus pruebas, y cada ROJO se registra en el Registro antes del VERDE.

**Organization**: una fase por historia de usuario del spec (US1 a US4), después E2E, cierre y compuertas.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: se puede hacer en paralelo (archivo distinto y sin dependencias pendientes).
- **[Story]**: US1 a US4, según el spec.

## Path Conventions

- Patcher horneado: `docker/scripts/apply_telegram_typing_patch.py`
- CLI del host: `scripts/agentctl`
- Pruebas: `tests/`. Fixtures: `tests/fixtures/`.

---

## Phase 1: Setup

- [X] T001 Medir la línea base de la suite del host antes de tocar código: `bats tests/` con bash 5.3.15 y `PATH=/bin:$PATH bats tests/` con 3.2.57, **en serie**, nunca en paralelo. Registrar en el Registro de este archivo, por bash, los `ok`, los `not ok`, los saltados por motivo y si el stderr quedó vacío.
- [X] T002 Generar el fixture dorado `tests/fixtures/telegram-server-patched-v034.ts` **una sola vez**:
  - copiar el patcher de main a un temporal con `git show 9a0b93e:docker/scripts/apply_telegram_typing_patch.py`;
  - copiar `tests/fixtures/telegram-server-pristine.ts` a otro temporal y correr ese patcher sobre la copia;
  - versionar el resultado.

  Comprobar que contiene una vez cada uno de los siete marcadores vigentes (typing v6, offset, pending, stderr v1, primary, askq, voice v3). Anotar su sha256 en research.md (D4) y en el Registro. Nunca regenerarlo con el patcher de la rama.
- [X] T003 [P] Inventariar los oráculos que nombran el marcador v1 (`grep -rn 'stderr-capture patch v1' tests/`) y registrar la clasificación en el Registro:
  - **Pasan a v2**, porque miran la salida del patcher sobre un archivo prístino o mutado: `tests/apply-telegram-patches.bats:43`, `:183`, `:194`, `:208`, `:613` y `:1264`.
  - **A revisar después de la cascada**, porque miran los dorados 033 y 034: `:957` y `:1381`.
  - **Se conserva**: `tests/docker-render.bats:270`, que mira que la constante v1 siga declarada en el patcher.

---

## Phase 2: Foundational (bloquea a todas las historias)

- [X] T004 [P] Crear `tests/fixtures/stderr-hook/vendor-handlers.ts` con los dos manejadores del vendor copiados textualmente de `server.ts:82-87` del plugin `telegram@claude-plugins-official` 0.0.7 (`process.on('unhandledRejection', …)` y `process.on('uncaughtException', err => { process.stderr.write(\`telegram channel: uncaught exception: ${err}\n\`) })`). Encabezarlo con un comentario de procedencia: plugin, versión, líneas y fecha 2026-11-23.
- [X] T005 [P] Crear `tests/helper-stderr-hook.bash`, sin efectos al cargarse (guarda `BASH_SOURCE`, Principio III), con estas funciones:
  - `stderr_hook_require_bun`: hace `skip "bun not on PATH: the stderr hook behavior is covered by the local gate and DOCKER_E2E (049 research D6)"` cuando falta bun.
  - `stderr_hook_build <V1|V2> <out.ts> <log>`: importa el patcher por ruta con `python3 -I` y toma `STDERR_HOOK_V1` o `STDERR_HOOK`. Reemplaza el literal `'/workspace/scripts/heartbeat/logs/telegram-mcp-stderr.log'` por la ruta de prueba citada con `json.dumps` y escribe el `.ts`. El driver se agrega después, con heredoc citado.
  - `stderr_hook_run_closed_pipe <ts> <segundos>`: el bucle de v1 no termina solo y escribe unos 10 MB/s (research M2), así que el helper tiene que matar a **bun**, no al último proceso del pipe. En `cmd | true &`, `$!` es el PID de `true`. Forma: `sh -c 'echo $$ > "$1"; exec bun "$2"' _ "$pidf" "$ts" 2>&1 >/dev/null | true &`, con los descriptores 3 y 4 de bats cerrados (`3>&- 4>&-`). El PID de bun se lee de `$pidf` (el `exec` conserva el PID del `sh`). Al vencer el plazo, el helper manda `kill` a ese PID, espera hasta 2 s, manda `kill -9` si sigue vivo y comprueba con `kill -0` que murió. Devuelve si el proceso salió solo antes del plazo.
  - `stderr_hook_run_healthy <ts> <stderr-out>`: corre con stderr a un archivo.
  - `stderr_hook_reap`: lo llama el `teardown`. Mata cualquier PID registrado por el helper que siga vivo y borra cualquier log de prueba de más de 1 MB.

  Los logs y los archivos de PID van bajo `$BATS_TEST_TMPDIR`. **Prueba del propio arnés** (en `tests/telegram-stderr-hook.bats`, junto a T007): correr la pierna v1 de H1 y afirmar que, al volver el helper, el PID de bun ya no existe y el log dejó de crecer (dos `stat` con 0,5 s de diferencia dan el mismo tamaño). Sin esta prueba, un error en el helper deja un bun llenando el disco de la Mac.
- [X] T006 En `docker/scripts/apply_telegram_typing_patch.py`, **antes de editar cualquier constante viva**, agregar `MARKER_STDERR_V1 = "agentic-pod-launcher: stderr-capture patch v1"` y `STDERR_HOOK_V1`, el bloque v1 **en su forma en disco** (research D4b: los `\n` de `[uncaught]` y `[unhandled]` son saltos reales en los plugins de la flota), construido con `MARKER_STDERR_V1`, más un comentario que diga que es la gemela congelada y que nunca se edita. No cambia ningún comportamiento.
  - Prueba primero, en `tests/apply-telegram-patches.bats`: **S4**, la fidelidad de la gemela, comprueba que `STDERR_HOOK_V1` está contenido textualmente en `tests/fixtures/telegram-server-patched-v034.ts`. Registrar el ROJO (el atributo no existe) y después el VERDE.

**Checkpoint**: el fixture dorado, el helper, los manejadores del vendor y la gemela v1 existen, y la suite sigue igual a la línea base más S4.

---

## Phase 3: User Story 1 - El log nunca supera un tope de disco (Priority: P1)

**Goal**: rotación al umbral, a lo sumo dos generaciones anteriores y recorte del archivo heredado.

**Independent Test**: con el hook vivo bajo bun, escribir mucho más que el tope y comprobar la cota total, la última línea en el archivo actual y el proceso vivo.

### Tests for User Story 1

- [X] T007 [US1] Escribir primero, en `tests/telegram-stderr-hook.bats` (archivo nuevo; carga `helper-stderr-hook`, llama a `stderr_hook_require_bun` en `setup` y a `stderr_hook_reap` en `teardown`), la prueba del arnés de T005 y las pruebas **H4, H5, H6, H7, H8 y H10** de `contracts/stderr-hook-v2.md` contra el hook vivo:
  - **H4**: `TELEGRAM_STDERR_LOG_MAX_BYTES=100000`, 100.000 escrituras de 48 bytes, `actual + .1 + .2 < 300000 + 3*48`; la última línea escrita está en el archivo actual; y los únicos archivos del directorio cuyo nombre empieza con el del log son el actual, `.1` y `.2` (atrapa una `.3` que quede fuera de la suma).
  - **H5**: un heredado de 50.000 bytes que termina en `TAILMARK`, umbral 1000 → `.1` de 1000 bytes que termina en `TAILMARK`, y el archivo actual contiene solo la escritura nueva.
  - **H6**: los valores `0`, `-5`, `abc` y vacío se comportan como `10485760`. Con 10.000 escrituras no hay rotación.
  - **H7**: un bucle de shell con 3.000 `printf >> log` en paralelo termina con rc 0 y cero líneas malformadas.
  - **H8**: con el directorio del log sin permiso de escritura (`chmod 500`), la escritura llega al stderr capturado y el proceso sale con 0.
  - **H10**: dos procesos bun con el hook, `TELEGRAM_STDERR_LOG_MAX_BYTES=20000`, 5.000 escrituras de 48 bytes cada uno, lanzados a la vez: los dos salen con 0, cero líneas malformadas en el actual, `.1` y `.2`, y `actual + .1 + .2 < 60000 + 3*48 + 2*48`.

  Correr y registrar el ROJO esperado: H4, H5 y H10 fallan porque v1 no rota. H6, H7 y H8 pueden nacer en verde con v1; anotar cuáles y por qué siguen siendo útiles (protegen la nueva rotación).

### Implementation for User Story 1

- [X] T008 [US1] En `STDERR_HOOK` de `docker/scripts/apply_telegram_typing_patch.py`, implementar la rotación de `data-model.md` §2:
  - umbral: solo dígitos (`/^[0-9]+$/`) y un entero seguro `> 0`; si no, `10485760` (la versión original con `Number.parseInt` aceptaba `10M` como 10; lo corrigió la revisión de T022);
  - un `statSync` antes de cada anexo;
  - si `U <= tamaño < 2U`: `rename .1 → .2` y `rename actual → .1`;
  - si `tamaño >= 2U`: `rename .1 → .2`, lectura posicionada de los últimos U bytes a `.1.tmp`, `rename .1.tmp → .1` y `unlink` del actual;
  - todo dentro de `try { } catch {}`.

  Una sola función de anexo (contrato C3) la usan la escritura reemplazada y los manejadores `[uncaught]` y `[unhandled]`, que conservan su formato. Cada `\n` destinado al TS va como `\\n` en el literal Python (research D5). Cambiar el reemplazo de `re.subn` en `apply_stderr` a `lambda m: "\n" + STDERR_HOOK + m.group(1)` (contrato P3). Correr H4 a H8 y H10 y registrar el VERDE en los dos bash.
- [X] T009 [US1] Agregar en `tests/apply-telegram-patches.bats`:
  - **S8**: con `grep -F`, cada secuencia `\n` literal esperada del bloque nuevo aparece en el `server.ts` parcheado; además, cero bytes de control fuera de tab y LF, con `LC_ALL=C grep -c '[[:cntrl:]]'` ajustado a excluir tab y LF.
  - **S9**: con bun presente, `bun build --no-bundle <server.ts parcheado> --outfile <temporal>` sale con 0 (la opción existe en bun 1.3.12, verificado el 23-11-2026); sin bun, se salta con motivo.

  Registrar el ROJO plantando un `\n` sin doblar en una copia del patcher, y el VERDE.

**Checkpoint**: US1 completa. El tope se respeta bajo bun y el patcher emite el TS correcto.

---

## Phase 4: User Story 2 - Un stderr cerrado no genera un bucle (Priority: P1)

**Goal**: cortar el reenvío ante un destino cerrado, con un solo aviso, sin excepciones al plugin y sin cambiar nada con un stderr sano.

**Independent Test**: hook + manejadores del vendor + stderr a un pipe cerrado. Una sola línea `[stderr-closed]`, ninguna repetición de EPIPE y el proceso atendiendo.

### Tests for User Story 2

- [X] T010 [US2] Escribir primero, en `tests/telegram-stderr-hook.bats`, las pruebas **H1, H2, H2a, H3 y H9**, con `tests/fixtures/stderr-hook/vendor-handlers.ts` concatenado al hook:
  - **H1, pierna v1** (`STDERR_HOOK_V1`, prueba del arnés, debe pasar desde ya): en 1 s con el pipe cerrado, el log pasa de 1 MB y el timer de salida no corre.
  - **H1, pierna viva**: exactamente una línea con `[stderr-closed] EPIPE - forwarding to stderr stopped, log only`, cero líneas `telegram channel: uncaught exception: Error: EPIPE`, y el timer de 1,2 s corre (el proceso sale solo antes del plazo).
  - **H2**: el driver instala, **antes** del hook, un espía que envuelve la escritura real (`const real = process.stderr.write.bind(process.stderr); process.stderr.write = (...a) => { calls++; return real(...a) }`), así que el hook lo captura como `_origWrite`. Después de ver la línea `[stderr-closed]` en el log, el driver pone `calls` en cero, hace 1.000 escrituras y escribe `calls` a un archivo lateral con `writeFileSync` (stderr está cerrado). Afirmar: 1.000 líneas nuevas en el log, ninguna línea de aviso adicional y `calls == 0`.
  - **H2a**: 50 escrituras en un mismo tick contra el pipe cerrado, antes de ceder el event loop, dejan exactamente una línea `[stderr-closed]`.
  - **H3**: con stderr sano y bajo el umbral, el log y el stderr capturado son byte por byte iguales a los de `STDERR_HOOK_V1` con las mismas escrituras (strings y `Uint8Array`).
  - **H9**: emitir `process.stderr.emit('error', Object.assign(new Error('x'), { code: 'EAGAIN' }))` deja una línea `[stderr-error] EAGAIN`, y la escritura siguiente sigue llegando al stderr capturado.

  Registrar el ROJO de la pierna viva de H1 (con el hook después de T008 el bucle sigue) y de H2, H2a y H9.

### Implementation for User Story 2

- [X] T011 [US2] En `STDERR_HOOK`, implementar los contratos C4 y C5 de `contracts/stderr-hook-v2.md`:
  - conjunto de destino cerrado: `EPIPE`, `ERR_STREAM_DESTROYED`, `ERR_STREAM_WRITE_AFTER_END` y `EBADF`;
  - bandera de reenvío;
  - `process.stderr.on('error', …)`, que corta o anexa `[<ISO>] [stderr-error] <code o error>`;
  - corte idempotente, que anexa una sola vez `[<ISO>] [stderr-closed] <code> - forwarding to stderr stopped, log only`;
  - escritura reemplazada: con el reenvío cortado devuelve `true` e invoca el callback final con `queueMicrotask`; con el reenvío activo, un `try` alrededor de `_origWrite` que corta ante un código de destino cerrado y relanza cualquier otro.

  Correr H1 a H10 (con H2a) y registrar el VERDE en los dos bash.

**Checkpoint**: US1 y US2 completas. El hook vivo ya es el comportamiento final, aunque el marcador todavía dice v1.

---

## Phase 5: User Story 3 - El upgrade llega solo a los agentes ya parcheados (Priority: P2)

**Goal**: cascada v1 → v2 idempotente, con la gemela congelada y el dorado como oráculo.

**Independent Test**: patcher sobre prístino, dorado 0.34.0, v2 y v1 editada, con los resultados de `contracts/patcher-stderr-upgrade.md` §P5.

### Tests for User Story 3

- [X] T012 [US3] Escribir primero, en `tests/apply-telegram-patches.bats`, las pruebas **S1, S2, S3, S5, S6 y S7** de `contracts/patcher-stderr-upgrade.md`:
  - **S1**: además del marcador v2 una vez y cero v1, el literal de la ruta del log aparece entre el marcador v2 y el ancla `const TOKEN =` (FR-014).
  - **S2**: `sha256(nuevo(dorado)) == sha256(nuevo(prístino))`.
  - **S3**: `nuevo(prístino)`, con `STDERR_HOOK` reemplazado por `STDERR_HOOK_V1` (reemplazo hecho en Python, `str.replace`), es byte por byte igual al dorado.
  - **S6**: un byte cambiado dentro de `STDERR_HOOK_V1` en una copia del dorado produce el WARN `stderr v1→v2 upgrade: v1 block not found exactly once (edited out-of-band?) — leaving v1 in place`, conserva el marcador v1, no agrega v2 y deja los otros seis marcadores presentes.

  En la misma tarea, actualizar a v2 los oráculos de T003 que pasan a v2, conservando su intención y anotando en cada uno el porqué. Registrar el ROJO.
- [X] T013 [US3] En `docker/scripts/apply_telegram_typing_patch.py`:
  - `MARKER_STDERR` pasa a `"agentic-pod-launcher: stderr-capture patch v2"`, y `STDERR_HOOK` empieza con `"// " + MARKER_STDERR`;
  - `upgrade_stderr_v1_to_v2` según P2, con `str.replace` y la regla `work.count(old) != 1`;
  - `apply_stderr` no toca un archivo que tenga v1 o v2 (P3);
  - en `main()`, la llamada inmediatamente antes de `apply_stderr`, su resultado en la condición de "sin cambios" y la etiqueta `stderr-upgrade-v1→v2` en las partes del log (P4);
  - `ALL_MARKERS` con v2;
  - el docstring del módulo (punto 3, *Stderr-capture patch*) actualizado a v2: rotación, corte y perilla.

  Correr S1 a S9 y registrar el VERDE.
- [X] T014 [US3] Revisar los oráculos de los dorados 033 y 034 (`tests/apply-telegram-patches.bats:957` y `:1381`). Donde la prueba mira el **archivo de entrada** del dorado, se conserva v1; donde mira la **salida** del patcher nuevo, pasa a v2. Confirmar que G1 a G5 y G2d de 034 y G1 a G6 de 033 siguen en verde con su intención, y registrar cada cambio.

**Checkpoint**: la cascada completa. `--list-markers` imprime v2 y el doctor la reconoce sin cambios (research M6).

---

## Phase 6: User Story 4 - El doctor avisa cuando el log crece de más (Priority: P3)

**Goal**: la línea del tamaño del log en `agentctl doctor`, modo docker, sin leer contenido.

**Independent Test**: doctor con el archivo ausente, con 5 MB y con 101 MiB disperso.

### Tests for User Story 4

- [X] T015 [US4] Escribir primero, en `tests/agentctl-doctor-telegram-patches.bats` (su arnés ya lleva al doctor docker hasta los chequeos del plugin con un `docker` falso), las pruebas **A1 a A4** de `contracts/doctor-stderr-size.md`:
  - el archivo disperso de A3 se crea con `dd if=/dev/null of=<f> bs=1 seek=105906176` (101 MiB), sin escribir datos;
  - A3 usa un `agent.yml` con `notifications.channel` distinto de `telegram`, para que una línea puesta dentro del bloque de parches (que solo corre con `telegram`) haga caer la prueba;
  - el contenido de A4 es un centinela único, que no aparece en ninguna línea de la salida.

  A5 queda cubierta por correr A2 y A3 en los dos brazos de la CI. Registrar el ROJO.

### Implementation for User Story 4

- [X] T016 [US4] En `scripts/agentctl`, agregar `_file_size() { stat -c '%s' "$1" 2>/dev/null || stat -f '%z' "$1" 2>/dev/null; }` junto a `_file_mode`. En `cmd_doctor`, junto a la llamada `_doctor_check_plugin_failures "$WORKSPACE"` (cerca de la línea 898; `WORKSPACE` se asigna cerca de la 855), agregar la línea de `contracts/doctor-stderr-size.md` §D2. **No** ponerla dentro del bloque *Telegram plugin patches* (cerca de la 785): ahí `WORKSPACE` no existe todavía y el bloque solo corre con `notifications.channel == telegram` (§D3). Textos literales:
  - `Telegram stderr log: <N> MiB`;
  - el WARN `Telegram stderr log is <N> MiB (rotation not active?)`, con la sugerencia que nombra el `truncate -s 0`;
  - umbral `104857600`; `<N>` en MiB, redondeado hacia abajo;
  - nada si el archivo falta o el tamaño no es un entero.

  No tocar `cmd_local_doctor`. Correr A1 a A4, registrar el VERDE y pasar `shellcheck -S error` sobre `scripts/agentctl`.

**Checkpoint**: las cuatro historias completas en el host.

---

## Phase 7: DOCKER_E2E (código horneado, FR-016)

- [X] T017 Crear `tests/docker-e2e-stderr-log.bats`, detrás de `DOCKER_E2E=1` y auto-sembrado en el molde de `tests/docker-e2e-voice.bats`:
  - cuerpos `-c '…'` con comillas simples, el TS por heredoc citado, y `-u agent` en cada `exec`;
  - copiar el dorado 0.34.0 al path del caché del plugin y correr el patcher de la imagen;
  - comprobar v2 una vez y v1 cero; una segunda pasada imprime `no changes to … all patch groups already present`;
  - copiar también `tests/fixtures/stderr-hook/vendor-handlers.ts` al contenedor, porque H1 necesita los manejadores del vendor;
  - con el bun de la imagen, correr H1 (pierna viva) con stderr a un pipe cerrado y H4 con un umbral chico, sobre el hook extraído del patcher de la imagen. Cada bun va bajo `timeout -k 10 <N>` (BusyBox manda solo TERM sin `-k`), y la prueba acepta 124, 137 y 143 como "lo mató el plazo".
- [X] T018 Correr en arm64 local `DOCKER_E2E=1 bats tests/docker-e2e-stderr-log.bats` y `DOCKER_E2E=1 bats tests/docker-e2e-voice.bats`, porque tocan el mismo patcher. Registrar el resultado, la duración y la versión de bun de la imagen.

---

## Phase 8: Polish & Cross-Cutting Concerns

- [X] T019 [P] Documentación:
  - `README.md`: una viñeta nueva en la sección del plugin de Telegram, junto a la de *Persistent "typing…" indicator*, sobre la captura de stderr v2 (rotación de 10 MiB con dos generaciones, `TELEGRAM_STDERR_LOG_MAX_BYTES`, el corte con la línea `[stderr-closed]` y la línea del doctor).
  - `CLAUDE.md`, sección *Telegram plugin patch*: el grupo stderr está en v2, el mecanismo medido (M1 y M2) y la gemela con su dorado. Commitear con `git add -f CLAUDE.md`.
- [X] T020 Verificar a mano `git show origin/main:VERSION` (lección 023) y subir `VERSION` de 0.34.0 a 0.35.0. Agregar en `CHANGELOG.md` una entrada `### Fixed` que nombre #139, el bucle medido (unos 10 MB/s, el canal deja de atender), el tope y el aviso del doctor.
- [X] T021 Mutaciones dirigidas, cada una sobre una copia y cada una debe hacer caer al menos un oráculo en los dos bash. Registrar el oráculo que cae en cada caso.
  - M1: sin el listener de `error` (H1).
  - M2: el reenvío sigue activo después del corte (H2, por el espía: `calls > 0`).
  - M3: aviso sin la guarda de una vez (H2b; sobrevivió a H2a, ver el Registro).
  - M4: la rotación sin el caso del heredado (H5).
  - M5: `.2` no se reemplaza; queda una `.3` o se acumula (H4, por la lista de archivos).
  - M6: un byte cambiado en `STDERR_HOOK_V1` (S4 y S2).
  - M7: la cascada fuera de `main()` (S2).
  - M8: el umbral sin validar (H6).
  - M9: un `\n` sin doblar en el bloque (S8 o S9).
  - M10: el doctor sin el umbral, avisando siempre (A2).
  - M11: la línea del doctor movida dentro del bloque de parches de Telegram (A3).
  - M12: el helper mata el PID del último proceso del pipe en vez del de bun (prueba del arnés de T005).
- [X] T022 Revisión independiente de solo lectura (agente `code-reviewer`) del diff completo contra `main`, antes del gate final (ver la memoria *independent review before the final gate*). Buscar aserciones vacuas, oráculos tautológicos, fixtures sin la disposición de producción y escapes de Python. Corregir lo que salga, con la prueba en ROJO primero, y registrarlo.
- [X] T023 Gate final:
  - `shellcheck` con el comando exacto de la CI;
  - suite completa en serie con bash 5.3.15 y 3.2.57, con stderr vacío; esperado = línea base de T001 + pruebas nuevas, 0 `not ok`;
  - la suite de bun también con SIGPIPE ignorada en los dos bash: `perl -e '$SIG{PIPE}="IGNORE"; exec @ARGV' bats tests/telegram-stderr-hook.bats`, porque así corre el runner;
  - auditoría de bytes: `LC_ALL=C grep -c $'\xcc\x80'` = 0 en el patcher y en los archivos de pruebas nuevos o tocados.
- [ ] T024 COMPUERTA (commit): commits locales en español, en imperativo y sin atribución, en este orden: artefactos de spec-kit; fixture dorado y gemela; implementación con sus pruebas; documentación, VERSION y CHANGELOG. Ninguno intermedio en rojo.
- [ ] T025 COMPUERTA (push y PR): push de la rama y PR contra `main` con `Closes #139`, el resumen, la evidencia de T018 a T023 y el plan de despliegue. CI verde en los checks, con los conteos por brazo y los saltados por motivo en el Registro. El merge lo hace el operador.
- [ ] T026 Después del merge, verificar `main` (árbol igual al de la cabeza validada, VERSION 0.35.0) y la primera nocturna `docker-e2e` (`e2e summary` sin fallas ni saltados inesperados).
- [ ] T027 COMPUERTA (despliegue): cbum como canario, después linus y donna, con el runbook *Upgrade an existing agent* del README y la verificación de quickstart §4 (`token-check`, doctor, `grep -c` de los marcadores v2 y v1, `ls -l` del log y un mensaje por Telegram respondido). En donna, después de `--force-claude-md`, correr `custom-apply --no-regenerate` y comparar el `CLAUDE.md` antes de reiniciar.
- [ ] T028 Registro final: actualizar la memoria del proyecto, el bloque de 049 en `CLAUDE.md` y este Registro con el resultado del despliegue.

---

## Dependencies & Execution Order

- **Setup (T001 a T003)**: T001 antes que cualquier cambio; T002 y T003 en paralelo.
- **Foundational (T004 a T006)**: T004 y T005 en paralelo. T006 depende de T002 por el dorado de S4. Las tres bloquean todas las historias.
- **US1 (T007 a T009)** depende de Foundational.
- **US2 (T010 y T011)** depende de US1: editan el mismo `STDERR_HOOK` y H1 usa la función de anexo de T008.
- **US3 (T012 a T014)** depende de US1 y US2: el bump congela el contenido final de v2.
- **US4 (T015 y T016)** es independiente del patcher y puede hacerse en paralelo con US1 a US3, porque toca `scripts/agentctl` y `tests/agentctl-doctor-telegram-patches.bats`.
- **E2E (T017 y T018)** depende de US1 a US3.
- **Polish (T019 a T023)** depende de todo lo anterior; T019 y T020 en paralelo.
- **Compuertas (T024 a T028)**: en orden y con autorización del operador.

### Parallel Opportunities

- T002 ∥ T003; T004 ∥ T005.
- US4 completa (T015 y T016) ∥ US1 a US3.
- T019 ∥ T020.

## Implementation Strategy

### MVP

Setup, Foundational, US1, US2 y US3. Con eso, la flota recibe el corte del bucle y el tope en el primer arranque después del despliegue. US4 agrega solo visibilidad.

### Incremental

1. US1: el tope protege el disco aunque el bucle siguiera.
2. US2: el bucle no arranca.
3. US3: el arreglo llega a los plugins ya parcheados.
4. US4: el doctor detecta un agente al que el arreglo no llegó.

## Registro

_(Mediciones, ROJOS, VERDES, mutaciones y compuertas, con fecha y comando.)_

### 23-11-2026: `/speckit-analyze`

Resultado: 13 hallazgos (0 CRITICAL, 3 HIGH, 5 MEDIUM, 5 LOW). El operador aprobó aplicar todos, y se aplicaron el mismo día, sin código:

- **HIGH**:
  - H2 no podía detectar el reenvío después del corte (M2). Ahora usa un espía con `calls == 0` (T010).
  - En `cmd | true &`, `$!` es el PID de `true`, así que el helper habría dejado vivo a bun en la pierna v1 de H1. Ahora se registra el PID de bun y hay una prueba del arnés (T005, M12).
  - La línea del doctor iba dentro del bloque de parches, antes de asignar `WORKSPACE` y detrás del gate `notifications.channel == telegram`. Ahora va junto a `_doctor_check_plugin_failures` (contrato §D3, T016, M11).
- **MEDIUM**:
  - el archivo de pruebas del doctor pasa a `tests/agentctl-doctor-telegram-patches.bats`;
  - FR-004 queda como "dos umbrales o más";
  - H4 lista los archivos, para atrapar una `.3`;
  - SC-001 queda proporcional al umbral;
  - se agregó H10, con dos procesos rotando a la vez.
- **LOW**:
  - SC-003 se formula en términos de timers;
  - MiB unificado en spec, contrato, data-model y research;
  - S9 con `bun build --no-bundle`, verificado en bun 1.3.12;
  - T017 copia los manejadores del vendor y usa `timeout -k 10`;
  - S1 afirma el literal de la ruta (FR-014);
  - H2a cubre M3.

### 23-11-2026: T002 y T003

- **T002**: dorado generado y versionado, con sha256 `96263610…58ac3` y 32.882 bytes. Tiene los siete marcadores (stderr v1 una vez). **Hallazgo** (research D4b): el bloque v1 en disco tiene saltos reales en las líneas `[uncaught]` y `[unhandled]`, porque `re.subn` interpretó la plantilla. Sobre el dorado, `count(STDERR_HOOK)` da 0 y la forma con saltos reales da 1. Por eso la gemela se define con la forma en disco, y P1 y T006 se ajustaron.
- **T003**: `grep -rn 'stderr-capture' tests/` encuentra nueve referencias.
  - **Pasan a v2**:
    - `apply-telegram-patches.bats:43`, `:183`, `:194`, `:208`, `:613` y `:1264` miran la salida sobre prístino o mutado. La `:194` es la última línea de su prueba, así que su `!` no está muerto.
    - **`:957` y `:1381` también pasan a v2**, contra lo que preveía esta lista. Son G4 de 033 y G4 de 034, y afirman que los otros grupos están en la salida del patcher sobre los dorados de voz, que llevan stderr v1 y quedan en v2.
  - **Se conserva**: `docker-render.bats:270`, porque la constante `MARKER_STDERR_V1` sigue declarada.

### 23-11-2026: T004 a T011 (Foundational, US1 y US2)

Medido en la Mac con bun 1.3.12. "Los dos bash" son 5.3.15 y 3.2.57 (`PATH=/bin:$PATH`).

- **T004**: `tests/fixtures/stderr-hook/vendor-handlers.ts`, con las líneas 80 a 87 de `server.ts` del plugin 0.0.7, copiadas de `~/.claude-personal/plugins/cache/claude-plugins-official/telegram/0.0.7/`.
- **T005**: `tests/helper-stderr-hook.bash`. El PID de bun sale de un archivo que escribe `sh` antes de hacer `exec`. La prueba del arnés comprueba que, al volver del helper, bun está muerto y el log ya no crece.
- **T006**: S4 en ROJO (la gemela no existía) y después en VERDE. La gemela usa la forma en disco (D4b).
- **T007**:
  - **ROJO**: H4 (total de 4.800.000 bytes), H5 (no existe `.1`) y H10 (total de 480.000).
  - **Nacen en verde**: H6, H7 y H8, porque v1 no rota. Protegen la rotación nueva:
    - H6, la validación del umbral (M8);
    - H7 y H10, la integridad con escritores concurrentes;
    - H8, el fail-silent.
- **T008**: rotación implementada. `apply_stderr` reemplaza con un `lambda`. **VERDE** en los dos bash:
  - H4: total de 298.560 bytes, contra el límite de 300.144;
  - H10: 32.688 y 35.712 bytes, cero malformadas. Las rotaciones simultáneas descartan una generación antes de tiempo, así que el borde del spec se corrigió para decir lo medido.
- **T009**:
  - **S9**: verde, con `bun build --no-bundle`.
  - **S8**: rojo solo en las líneas `[stderr-closed]` y `[stderr-error]`, que todavía no existían; las de `[uncaught]` y `[unhandled]` ya llegaban como dos bytes. Su ROJO por mutación queda para M9 (T021).
- **T010**:
  - **ROJO**: la pierna viva de H1 (el bucle sigue y el helper tuvo que matar a bun), H2 y H2a (nunca aparece `[stderr-closed]`) y H9 (sin listener, `emit('error')` lanza y la escritura siguiente no ocurre).
  - **Verdes**: la pierna v1 de H1, que reproduce el bucle en 1 s, y H3.
- **T011**: corte implementado (C4 y C5). **VERDE** con 13 de 13 en `tests/telegram-stderr-hook.bats`, en los dos bash, más S4, S8 y S9. Al terminar no quedó ningún bun de prueba vivo (`pgrep`).

### 23-11-2026: T012 a T014 (US3)

- **T012, ROJO**: S1 (sin v2), S2 (sin `stderr-upgrade-v1→v2`), S6 (sin el WARN) y S7 (la línea 3 de `--list-markers` decía v1). S3 y S5 nacen en verde:
  - S3, porque el bloque v2 ya existía con el marcador v1, y al volver a cambiarlo por la gemela queda igual al dorado;
  - S5, porque la idempotencia ya valía.

  Los ocho oráculos de T003 pasan a v2, cada uno con un comentario `# 049:` que dice por qué.
- **T013**: `MARKER_STDERR` pasa a v2, se agrega `upgrade_stderr_v1_to_v2` (todo o nada), `apply_stderr` respeta v1 y v2, `main()` usa la etiqueta `stderr-upgrade-v1→v2` y se actualiza el docstring del punto 3. La etiqueta sigue el molde de `typing-upgrade-v1→v2` y `voice-upgrade-v2→v3`, no el `stderr v1→v2` que decía el contrato P4, que ya se ajustó.
- **T014**: la única falla después del bump fue **034 G2d**. Comparaba el upgrader de voz aplicado solo sobre el dorado v2, que lleva stderr v1, con una instalación fresca, que ahora lleva v2. Para conservar su intención (el upgrader de voz reproduce la v3 fresca), la prueba ahora sube también el grupo stderr con su propio upgrader antes de comparar.
- **VERDE**:
  - `apply-telegram-patches.bats` 133 de 133 en los dos bash, con G1 a G6 de 033 y G1 a G5 y G2d de 034;
  - `docker-render.bats` 45 de 45;
  - `agentctl-doctor-telegram-patches.bats` 7 de 7. El doctor reconoce v2 sin cambios, porque le pregunta los marcadores al patcher (research M6).

### 23-11-2026: T015 y T016 (US4)

- **T015**: las pruebas van en `tests/agentctl-doctor-telegram-patches.bats`.
  - **ROJO**: A2, A3 y A4, porque no había línea. A4 falló en la línea `0 MiB`; su aserción de que el centinela no aparece ya pasaba. A1 nace en verde.
  - **A3** corre con `notifications.channel: none`, para que poner la línea dentro del bloque de parches haga caer la prueba.
- **T016**: `_file_size` (GNU primero) y `_doctor_check_stderr_log`, llamada junto a `_doctor_check_plugin_failures "$WORKSPACE"`. **VERDE**: 11 de 11 en los dos bash, con `shellcheck -S error scripts/agentctl` limpio.

### 23-11-2026: T021, mutaciones

El runner (`mutate.py`, en el scratchpad de la sesión, sin versionar) reemplaza el texto en sitio, corre la prueba prevista en los dos bash y restaura el archivo, verificando el sha256 (`shasum -c` OK después de cada corrida).

| Id | Mutación | Cae en | bash 5.3.15 | bash 3.2.57 |
| --- | --- | --- | --- | --- |
| M1 | listener de `error` desconectado | H1 (viva) | cae | cae |
| M2 | reenvío activo después del corte | H2 (espía, `calls > 0`) | cae | cae |
| M3 | sin la guarda de una vez | **H2b** | cae | cae |
| M4 | rotación sin el caso del heredado | H5 | cae | cae |
| M5 | `.2` → `.3` en vez de reemplazarse | H4 (lista de archivos) | cae | cae |
| M6 | un byte en `STDERR_HOOK_V1` | S4 y S2 | cae | cae |
| M7 | la cascada fuera de `main()` | S2 | cae | cae |
| M8 | umbral sin validar `> 0` | H6 | cae | cae |
| M9 | `\n` sin doblar en `[stderr-closed]` | S8 | cae | cae |
| M10 | doctor sin umbral | A2 | cae | cae |
| M11 | línea del doctor detrás del gate `notifications.channel == telegram` | A3 | cae | cae |
| M12 | el helper registra el PID de `true` | arnés y pierna v1 de H1 | cae | cae |

**M3 sobrevivió a H2a.** Se midió que bun 1.3.12 emite un solo `error` por stream aunque fallen 50 escrituras, así que la guarda nunca se ejercitaba. Se agregó **H2b**, que corta dos veces a mano y exige un solo aviso. Con eso M3 cae.

**M12 colgó la primera corrida y dejó cuatro bun vivos.** El helper mutado registraba el PID de `true`, así que ni él ni el `teardown` mataban al bun del bucle v1. bats no terminaba, y los cuatro logs sumaron unos 9 GB hasta que se mataron los procesos y se borraron los logs (todo era de la prueba). El disco llegó a 2,3 GiB libres. Remedio, como defensa en profundidad: `stderr_hook_reap` también mata los PID de los archivos `stderr-hook-pid.*` que escribe `sh`. Después, M12 cae limpia en 2,6 s, sin cuelgue ni proceso filtrado. El runner ahora corta cada corrida a los 180 s y la marca como HANG.

### 23-11-2026: T022, revisión independiente

Revisión de solo lectura con el agente `code-reviewer` sobre el diff completo. Sin hallazgos críticos. Lo que salió y cómo se resolvió, cada código con su ROJO antes del VERDE:

- **MEDIUM, rollback** (reproducido por el revisor y por S10). El patcher de 0.34.0 busca solo el marcador v1, así que sobre un archivo v2 apila un bloque v1, y la cascada lo convertía en un segundo v2: cada línea quedaba duplicada para siempre. Remedio: `upgrade_stderr_v1_to_v2` quita el `"\n" + STDERR_HOOK_V1` apilado cuando ya hay v2. **S10** compara contra una instalación fresca. El borde del spec y el riesgo del research decían que el patcher viejo "no toca v2": era falso y se corrigió.
- **MEDIUM, recorte fallido.** Si fallaba la escritura de `.1.tmp` (ENOSPC, justamente lo que deja #139), el heredado nunca bajaba y cada escritura releía 10 MiB. Remedio: el actual se borra igual (perder la cola es aceptable) y se limpia el `.1.tmp`. **H5b** fuerza la falla con un directorio en el lugar de `.1.tmp`.
- **LOW, umbral.** `Number.parseInt` aceptaba `10M` como 10 y `1e7` como 1. Ahora solo se aceptan dígitos (`/^[0-9]+$/`) y un entero seguro `> 0`.
- **LOW, H6 no probaba el valor por defecto.** Ahora escribe 9.830.400 bytes (entre 9 y 10 MiB) sin rotar, con seis valores inválidos que incluyen `10M` y `1e7`. ROJO: `10M` dejaba el log en 4.096 bytes.
- **LOW, negativo muerto previo a 049.** `apply-telegram-patches.bats:181`, en una prueba que 049 tocó: `! grep -q` a mitad de la prueba no se evalúa. Pasa a `if …; then false; fi`, y la prueba sigue en verde.
- **Se dejan, con motivo**:
  - H9 emite un EAGAIN sintético; ejerce la rama del listener, que es lo que prueba.
  - Que el doctor no muestre nada si el archivo falta es lo que fija A1.
  - El revisor no encontró problemas en el E2E.

**VERDE**: `tests/telegram-stderr-hook.bats` 15 de 15 y `tests/apply-telegram-patches.bats` 134 de 134, en los dos bash.

**Catálogo final de mutaciones**: M1 a M14 caen en los dos bash. Las nuevas son M13 (el recorte fallido no borra el actual, cae en H5b) y M14 (sin la rama del v1 apilado, cae en S10), y M8 se re-ancló a la validación nueva.

### 23-11-2026: T017 y T018, DOCKER_E2E en arm64 local

Imagen `agentic-pod:latest` reconstruida desde la rama: Alpine 3.24.1, aarch64, bun **1.3.14**, con `MARKER_STDERR` horneado en v2. Docker 29.8.0.

- **`tests/docker-e2e-stderr-log.bats`**: 3 de 3 en 38 s (la primera corrida, sin las mediciones por fd 3, dio 3 de 3 en 53 s).
  - **E1**: el patcher horneado sube el dorado 0.34.0 a v2 (`V2COUNT=1`, `V1COUNT=0`). La segunda pasada es un no-op registrado, y el archivo transpila con `bun build --no-bundle`.
  - **E2**, con el bun de la imagen y el stderr en un pipe cerrado:
    - **v1**: `size=40992423 exited=no closed=0 loops=120566`. El bucle de #139 se reproduce en el contenedor (unos 13,7 MB/s en 3 s) y el timer de salida nunca corre.
    - **v2**: `size=120 exited=yes closed=1 loops=0`.
  - **E3**: con U = 100.000 y 100.000 escrituras, el total queda en 298.560, bajo el límite de 300.144, y solo existen `log`, `log.1` y `log.2`.
- **`tests/docker-e2e-voice.bats`**: 12 de 12 en 2 min 11 s. El patcher es el mismo, y la cascada de voz y el no-op siguen bien.

### 23-11-2026: T001, línea base

Corrida en una copia aislada de `9a0b93e` (`git clone --no-local`, con `main` local creada), en serie, para que las ediciones de la rama no la contaminen.

| bash | ok | not ok | saltadas | stderr | inicio | duración |
| --- | --- | --- | --- | --- | --- | --- |
| 5.3.15 | 2.267 de 2.267 | 0 | 71 | vacío | 10:53 | unos 64 min |
| 3.2.57 | 2.267 de 2.267 | 0 | 72 | vacío | 11:57 | unos 51 min |

**Las saltadas son todas previstas:**

- 64 por `DOCKER_E2E`;
- 6 por `flock`, `timeout` o `/proc`, que el host macOS no tiene;
- 1 más en 3.2, por `read -t`, que pide bash 4 o más.

**Medido**: 2.267 coincide con la CI de 048 por brazo. La duración se alargó por la carga del sistema (load average de 13 a 15, por aplicaciones del operador) y por las corridas de 049 en paralelo durante la pierna 5.3.

**Esperado en el gate**: 2.267 + 32 nuevas = **2.299** por bash, con 0 `not ok`. Las 32 nuevas son 15 bajo bun, 10 del patcher, 4 del doctor y 3 E2E. Las tres E2E se saltan fuera de Docker, así que las saltadas esperadas son 74 en 5.3 y 75 en 3.2.

### 23-11-2026: T023, gate final

Corrido en serie sobre el árbol de la rama, con la huella `e4137f1f8cdb427e` (sha256 del patcher, `scripts/agentctl`, `tests/*.bats` y `tests/helper-stderr-hook.bash`), igual al empezar y al terminar.

| bash | ok | not ok | saltadas | stderr | inicio | fin |
| --- | --- | --- | --- | --- | --- | --- |
| 5.3.15 | 2.299 de 2.299 | 0 | 74 | vacío | 12:49 | 13:38 |
| 3.2.57 | 2.299 de 2.299 | 0 | 75 | vacío | 13:38 | 14:25 |

- **Conteo**: 2.299 = 2.267 de la línea base + 32 nuevas, lo esperado. Las saltadas son 67 por `DOCKER_E2E` (las 64 previas y las 3 E2E de 049), 7 por `flock`, `timeout` o `/proc`, que el host macOS no tiene, y 1 más en 3.2 por `read -t`. La línea base del T001 contó 6 de host, pero su total de 71 solo cuadra con 7: el desglose de entonces estaba corrido en uno, no el total.
- **shellcheck**, con el comando exacto de la CI: rc 0.
- **Suite de bun con SIGPIPE ignorada** (`perl -e '$SIG{PIPE}="IGNORE"; exec @ARGV' bats tests/telegram-stderr-hook.bats`): 15 de 15 en bash 5.3.15 y en 3.2.57, sin saltadas, stderr vacío y ningún bun sobreviviente.
- **Auditoría de bytes** (`LC_ALL=C grep -c $'\xcc\x80'`): 0 en el patcher, `scripts/agentctl`, los cinco archivos de pruebas nuevos o tocados y el fixture `vendor-handlers.ts`.

