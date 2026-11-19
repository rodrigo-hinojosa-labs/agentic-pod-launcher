---
description: "Tareas de 047: diagnóstico local y avisos por transición para #111"
---

# Tasks: Healthcheck local sin falsos avisos de login

**Date**: 2026-11-17
**Branch**: `047-local-healthcheck`
**Input**: [spec.md](spec.md), [plan.md](plan.md), [research.md](research.md), [data-model.md](data-model.md), [contracts/](contracts/health-verdict.md) y [quickstart.md](quickstart.md).
**Prerequisites**: fases specify, clarify, plan y analyze terminadas; remediación documental U1/A1 aprobada y constitución 1.1.0.
**Aceptación registrada (18-11-2026)**: T001–T061 realizadas sobre `17fcd6b`, con cuatro checks verdes, BATS2196 por bash y Linux10/10. Se observó el PR#136 listo sobre esa cabeza y se devolvió a borrador para publicar este cierre documental. La fuente aceptada d81d962d no cambia; cualquier SHA posterior debe tener su CI completa verde antes de la habilitación final. Estado vigente en [PR#136/checks](https://github.com/rodrigo-hinojosa-labs/agentic-pod-launcher/pull/136/checks). T062–T064 y el despliegue permanecen reservados al operador.
**Tests**: obligatorios por FR-021/FR-023 y Principio III. RED por comportamiento antes de cada arreglo; si un caso ya pasa, registrar qué preserva y comprobar su mutante, sin inventar un RED.
**Organization**: cuatro historias en orden P1, P1, P2, P2; infraestructura común primero y cierre transversal al final.

## Formato y rutas

Cada tarea usa `- [ ] Tnnn [P?] [USn?] descripción con ruta`. [P] permite trabajar en archivos distintos una vez satisfechas sus dependencias; nunca autoriza dos BATS simultáneos en el mismo equipo. Las rutas de código son relativas a la raíz del worktree, no a esta carpeta.

Worktree exclusivo: `/Users/rodrigo-hinojosa/Documents/Cencosud/Claude/Agents/agentic-pod-launcher/.claude/worktrees/047-local-healthcheck`. Base de diseño: `3afae74bd6335f7ebd8f6b4ff613b4e876f2db08`, VERSION 0.32.0. Verificar estado antes de actuar; no tocar main, el worktree 046 ni el AGENTS.md ajeno.

Este archivo se genera sin ejecutar sus tareas. No confundir la línea base focal previa de 21/21 por bash con evidencia de la implementación. Cada ejecución futura deja en el Registro fecha local, fuente/huella, comando, bash efectivo, resultados, duración, evidencia y hallazgos. Ante un rojo, diagnóstico y prueba antes de arreglo. Las compuertas Git/CI/merge se indican explícitamente; esta invocación no las autoriza.

## Phase 1: Setup

**Propósito**: fijar checkout, evidencia y línea base antes de modificar comportamiento.

- [X] T001 Verificar pwd/rama/estado, selector `.specify/feature.json`, hooks y constitución; registrar fuente y autoridad en `specs/047-local-healthcheck/tasks.md`, conservando los documentos y cambios previos.
- [X] T002 Medir `bats tests/` sobre una copia aislada de la base real sin editarla durante la corrida: bash 5.x y 3.2 secuenciales, stdout/stderr/versiones/huellas y saltadas por motivo; guardar evidencia privada bajo cache de 047 y sus referencias en `specs/047-local-healthcheck/tasks.md`. Si falla, diagnosticar antes de iniciar el producto.
- [X] T003 Inventariar los tests existentes y asignar los 92 nuevos de la matriz de este archivo a sus tareas; fijar B por bash y esperado B+92, mapear FR/SC y registrar cualquier cambio de inventario en `specs/047-local-healthcheck/tasks.md`. No eliminar tests previos para cuadrar el total.

## Phase 2: Foundational

**Propósito**: arnés hermético y empaquetado local común. Bloquea las historias.

- [X] T004 Crear `tests/helper-local-healthcheck.bash` y fixtures sintéticos bajo `tests/fixtures/local-healthcheck/` para render local, tiempo explícito, proc/cgroup, systemctl/journalctl/ss y CLI ficticios. Preparar `tests/fixtures/local-healthcheck/timeout` en el PATH privado: doble estricto de las formas GNU usadas que ejecuta al hijo, aplica TERM/KILL, lo recoge y rechaza argumentos no previstos; no passthrough ni dependencia de coreutils instalado en el Mac. Todo comando externo no previsto falla sin caer al servicio del host; los casos de ausencia ocultan deliberadamente el doble. Los payloads grandes viajan por archivos; evitar assertions intermedias muertas y cerrar descriptores BATS de hijos.
- [X] T005 Ampliar `tests/helper-local-healthcheck.bash` con transporte controlado, espía de valores secretos ficticios, fallas por operación de escritura/sync/mv y reloj. Preparar `tests/fixtures/local-healthcheck/sync` en el PATH privado: validar archivo/directorio y orden, registrar retornos e inyectar fallas, nunca llamar al sync global/BSD del host ni limitarse a éxito incondicional. Usar util-linux flock real o `tests/fixtures/qmd-lock/flock` en Mac; N30/N31 incluyen autopruebas de los dobles de timeout/sync y cleanup de hijos sin sumar tests físicos. El gate Linux conserva herramientas reales.
- [X] T006 Añadir LC01/LC02 en `tests/local-render.bats` y RG01/RG02 en `tests/regenerate.bats`: par CLI/helper solo local, source sin I/O, librerías ausentes con WARN, dos regeneraciones e invariantes de unidad/timer/Docker. Observar RED por helper/render ausentes antes de T007, sin afirmar que ese RED reproduce #111.
- [X] T007 Crear `modules/local-healthcheck-lib.sh.tpl` con definiciones sin efectos al cargar, source guards y las interfaces H6; renderizarla desde `setup.sh` como `scripts/local/agent-healthcheck-lib.sh` exclusivamente local y cargarla con existencia comprobada desde `modules/local-healthcheck.sh.tpl`. Mantener User/ExecStart/SuccessExitStatus/timer y no añadir EnvironmentFile, mirror, COPY ni configuración nueva.
- [X] T008 Actualizar los fixtures de los 21 tests existentes en `tests/local-healthcheck.bats` para expresar login completo o desconocido deliberadamente y conservar sus intenciones 021/QMD/grafo; cerrar LC/RG en ambos bash y registrar el checkpoint en `specs/047-local-healthcheck/tasks.md`. Cambiar expectativas de comportamiento únicamente junto al RED y arreglo de su historia.

**Checkpoint**: render y arnés utilizables; comportamiento de #111 aún no se declara corregido.

## Phase 3: User Story 1 — Distinguir login renovable de login perdido (P1, MVP)

**Objetivo**: quitar el falso DEGRADED por acceso renovable y conservar señales de pérdida/rechazo comprobadas.
**Prueba independiente**: con unidad/conexión sanas ficticias, acceso vencido y renovación lejana, treinta evaluaciones OK; pérdida, renovación vencida y terminales producen D; desconocidos W. Sin cuenta real.

### Tests primero

- [X] T009 [US1] Escribir A01–A15 y J01–J10 de la matriz en `tests/local-healthcheck-auth.bats`, contra el CLI generado y los clasificadores H6 cuando corresponda; conservar el RED por acceso renovable, forma perdida, raíz distractora y mensajes mezclados antes de T010/T011. Los casos que preservan comportamiento deben tener un control de mutación, no un RED artificial por función ausente.

### Implementación

- [X] T010 [US1] Implementar `hc_auth_snapshot` en `modules/local-healthcheck-lib.sh.tpl`: lectura única jq de `.claudeAiOauth`, tokens solo dentro de jq, forma vacía exacta y fechas enteras 1..9007199254740991 ms sin heurísticas. Preservar las restricciones literales del modelo: auth_class «renewable / renewal_expiring / renewal_expired / login_lost / incomplete» y renewal_remaining_ms «entero o null», «Solo si la fecha fue verificable». La clasificación calcula TTL y las clases completas; US3 completa su presentación de vencimiento.
- [X] T011 [US1] Implementar `hc_journal_snapshot` en `modules/local-healthcheck-lib.sh.tpl`: diez minutos/-n 2000, temporal 0600, comprobar retorno, catálogo H3 por evento y precedencia terminal/401 desconocido sobre excepción renovable de otra línea; lectura fallida es W, no journal vacío. No pasar journal por argv/env ni usar consumidor que cierre el pipe antes.
- [X] T012 [US1] Integrar snapshot/veredicto en `modules/local-healthcheck.sh.tpl` y `modules/local-healthcheck-lib.sh.tpl`, conservando QMD/grafo y salida H1 0/1/2; fijar global_deadline monotónico t0+60 s al entrar al CLI, antes de configuración, y pasarlo a las interfaces H5/H6 sin renovarlo. Aplicar literalmente health «OK / WARN / DEGRADED», «Máximo de las comprobaciones; códigos 0/1/2»; reason_codes «lista de enums cerrados», «Unidad, login, journal, conexión, QMD/grafo; nunca texto externo». El snapshot es efímero, sin tokens ni journal persistidos.
- [X] T013 [US1] Adaptar `tests/sigpipe-boot-paths.bats` para ejecutar el clasificador real en lugar de extraer un if antiguo; conservar los tests existentes, entradas >64 KiB por archivo, captura acotada y pruebas con SIGPIPE ignorada. Demostrar que volver al patrón defectuoso sigue siendo detectado.
- [X] T014 [US1] Validar los 25 casos A01–A15/J01–J10, regresión previa y SIGPIPE en ambos bash secuenciales; A14 ejecuta las treinta evaluaciones de SC-001 con cero avisos. Registrar RED/GREEN, motivos precisos y límites de este MVP en `specs/047-local-healthcheck/tasks.md`; no publicar ni desplegar.

**Checkpoint**: diagnóstico de login comprobable independientemente. El reconocimiento de hijos, la presentación de la ventana y la política de envíos se completan en US2–US4; el MVP es una validación local, no autorización de release.

## Phase 4: User Story 2 — Reconocer la conexión de la sesión completa (P1)

**Objetivo**: atribuir conexiones a la unidad completa sin aceptar procesos ajenos ni identidades obsoletas.
**Prueba independiente**: C01–C20 aceptan principal/hijo/nieto/subgrupo; rechazan ajenos y puertos incorrectos; datos incompletos W, unidad inactiva D. L01–L09 ejercitarán esa composición real antes del merge.

### Tests primero

- [X] T015 [US2] Escribir C01–C11 en `tests/local-healthcheck-processes.bats` con raíces sintéticas, fixtures de ss por inode y unidad controlada; comprobar RED de hijo/nieto/ajeno/frontera antes de T017/T018, preservando los positivos previos.
- [X] T016 [US2] Escribir C12–C20 en `tests/local-healthcheck-processes.bats`: proc fijado, reutilización sintética, FD/cgroup cambiados, segunda enumeración, nuevas identidades, InvocationID, presupuesto y cap; ordenar barreras deterministas antes del arreglo, sin sleeps que supongan una carrera.

### Implementación e integración preparada

- [X] T017 [US2] Implementar enumeración cgroup v2/propiedades systemctl en `modules/local-healthcheck-lib.sh.tpl`: ruta exacta o prefijo con slash, nunca `/` ni toda la máquina; identidades PID+starttime, máximo 1024 candidatos y unknown explícito al excederlo. Sin PPID/nombre/UID como sustitutos de pertenencia.
- [X] T018 [US2] Implementar `hc_connection_snapshot` en `modules/local-healthcheck-lib.sh.tpl`, fijando cwd proc antes de ss, leyendo cgroup/enlaces fd relativos e intersectando enteros completos de inodes con remoto 443 establecido; revalidar FD/pertenencia sin reabrir el PID numérico. No leer entorno, cmdline o contenido de FDs.
- [X] T019 [US2] Implementar revalidación de unidad e inventario final en `modules/local-healthcheck-lib.sh.tpl`: una repetición dentro del mismo plazo ante cambio; segunda inestabilidad unknown; absent requiere inventarios coincidentes; un positivo válido puede vencer otro candidato incompleto. Fijar una vez observation_deadline=min(observation_start+25 s,global_deadline) según H5, sin renovarlo al repetir. systemctl/journalctl 4 s y ss 3 s se recortan por el remanente, incluidos KILL/recolección; no afirmar snapshot atómico.
- [X] T020 [US2] Integrar conexión en `modules/local-healthcheck.sh.tpl`/`modules/local-healthcheck-lib.sh.tpl` respetando literalmente connection «present / absent / unknown», «Señal de red de la unidad, no conversación comprobada» y unit_invocation «identificador o null», «Solo durante la observación; permite descartar reinicios». Absent y unknown son W distinguibles, unidad inactiva D; el deadline no borra un D ya observado.
- [X] T021 [P] [US2] Crear fixtures de servicio, hijos/nietos, sockets, subcgroup y barreras reales en `tests/fixtures/local-healthcheck/linux-service.py`; parámetros explícitos, datos ficticios y readiness verificable. Puede prepararse junto a T017–T020 después de T016 por ser otro archivo; no ejecutar servicios desde BATS.
- [X] T022 [US2] Crear `.github/scripts/local-healthcheck-integration.sh` con guardia al sourcear, prerequisitos V4 que fallen, workspace sintético renderizado y namespace solo loopback; unidades transitorias de sistema únicas, User=runner, RuntimeMaxSec/TimeoutStopSec y probe de retorno propio. Registrar ownership y cleanup desde el inicio; nada de sudo fuera de la VM de prueba.
- [X] T023 [US2] Cablear L01–L09 en `.github/scripts/local-healthcheck-integration.sh`: propiedades/proc/ss reales, variantes L06/L08 y handshakes V4 después de capturar ss y antes de devolverlo. Verificar salida/restart/nacimiento en ese intervalo; el probe guarda el rc real del healthcheck, no el de systemd-run. No afirmar reutilización real de PID ni modificar pid_max/ns_last_pid.
- [X] T024 [US2] Validar C01–C20 y los oráculos de US1 secuencialmente en ambos bash; comprobar estáticamente los fixtures preparados y registrar en `specs/047-local-healthcheck/tasks.md`. La ejecución Linux completa espera L10/CI en Polish; no marcar integración real como pasada por la simulación.

**Checkpoint**: atribución sintética completa; arnés real L01–L09 preparado y pendiente del gate L01–L10.

## Phase 5: User Story 3 — Anticipar el vencimiento real de la renovación (P2)

**Objetivo**: ventana de siete días y tiempo restante comprensible, sin derivarlo de la vida del acceso.
**Prueba independiente**: A16–A20 en instante controlado: >7 días OK; 7 días/plazo positivo W; ahora/vencido D; fecha desconocida W; nuevo login y WARN ajenos conservados.

### Tests primero

- [X] T025 [US3] Añadir A16–A20 a `tests/local-healthcheck-auth.bats`, con reloj explícito y casos H2; observar RED del texto/veredicto integrado que aún falte. Si la clasificación interna de T010 ya pasa, conservar ese GREEN y exigir RED en la presentación, sin duplicar la implementación.

### Implementación

- [X] T026 [US3] Completar ventana y formato en `modules/local-healthcheck-lib.sh.tpl`: 0 < TTL <=604800000 ms W, <=0 D, >ventana sin ese motivo; redondear hacia arriba días >=24 h, horas <24 h y `<1h`. No estimar expiración desde mtime/otra raíz ni suponer ocho horas o vida fija del refresh.
- [X] T027 [US3] Integrar mensaje/identidad notificable en `modules/local-healthcheck.sh.tpl` y `modules/local-healthcheck-lib.sh.tpl`; copiar literalmente notice_identity «NONE / WARN_EXPIRY / DEGRADED», «DEGRADED si salud 2; WARN_EXPIRY si no hay D y vence renovación; NONE en el resto». Un WARN de QMD/conexión sin vencimiento no abre aviso de expiración.
- [X] T028 [US3] Validar A01–A20/J01–J10 y SC-003 en ambos bash secuenciales, incluidos límites +/-1 ms, relogin y severidad combinada; registrar en `specs/047-local-healthcheck/tasks.md` sin esperas de días reales.

**Checkpoint**: aviso visible local por vencimiento correcto; entrega/deduplicación se completa en US4.

## Phase 6: User Story 4 — Recibir avisos por cambios de situación (P2)

**Objetivo**: una entrega por transición confirmada; reintentar pendientes vigentes a partir de treinta minutos y suspender toda red sin registro acreditado.
**Prueba independiente**: N01–N36 con reloj/receptor sintéticos, lock efectivo, fallas por operación y reinicios de procesos; SC-005/SC-006 completos y veredicto independiente de la entrega.

### Tests primero

- [X] T029 [US4] Escribir N01/N02 en `tests/local-healthcheck-notices.bats` para tipos/claves/rangos/invariantes cruzadas del modelo, registro <=16384 bytes/0600, tipos inesperados y límite de event_version; ningún JSON incoherente debe reactivar un pendiente obsoleto.
- [X] T030 [US4] Escribir N03–N13/N17 en `tests/local-healthcheck-notices.bats`, usando la tabla completa del modelo y secuencias SC-005: treinta W, treinta D y recuperación son tres confirmaciones; incluir cambios de texto, relogin, recuperación parcial, silencio sin confirmación y deuda D confirmado→NONE fallida→D no confirmado→NONE.
- [X] T031 [US4] Escribir N14–N16 en `tests/local-healthcheck-notices.bats`: minutos 0/5/25/30/55/60/65 con intentos solo 0/30/60 y frontera adicional 1799/1800 s; reinicios y retroceso/corrección epoch 0/600/300/1200/1500 con espera 1800/1200/1200/600/300. No contar dos veces tiempo ni esperar treinta minutos reales.
- [X] T032 [US4] Escribir N18–N22 en `tests/local-healthcheck-notices.bats`, inyectando cada falla de precommit, ack antes de write/mv fallido, rename final seguido de sync DIR fallido, siguiente adopción válida/anterior inflight y barrera fallida repetida; antes de persistencia válida debe haber cero red y cero confirmaciones inventadas.
- [X] T033 [US4] Escribir N23–N25/N35 en `tests/local-healthcheck-notices.bats`: dos procesos solapados con flock efectivo, observación fresca bajo lock, perdedor solo diagnostica; dependencias ausentes, tipos de archivo/lock inesperados, inspección del fd9 del hijo, muerte abrupta del controller antes del unlock y liberación/cleanup. jq ausente también causa W de auth; no exigir salud OK sin ese dato.
- [X] T034 [US4] Escribir N26–N31/N36 en `tests/local-healthcheck-notices.bats`: HTTP/JSON/ok/rc, respuesta perdida, flags/escaping de curl, valores secretos, catálogo stderr y salud inalterada. N30 comprueba el doble de timeout con éxito y TERM ignorado seguido de KILL/recolección; N31 comprueba el doble de sync con orden/errores y ejecuta el CLI completo con reloj monotónico controlado desde configuración hasta cleanup/salida contra global_deadline=t0+60 s. Incluir configuración ausente/presente, coste previo consumido y cambio de fase que intente renovar el global, topes H5 y cero llamadas tras vencer; son variantes de N31, no nuevos tests. RED de envíos repetidos/inseguros antes de T042/T043.
- [X] T035 [US4] Escribir N32–N34 en `tests/local-healthcheck-notices.bats`: configuración ausente/incompleta no crea estado ni tráfico, legacy legible gana y legacy ilegible permite fallback, reactivación conserva solo situación vigente; no source/eval, datos totalmente ficticios.

### Implementación

- [X] T036 [US4] Implementar lectura/validador de estado en `modules/local-healthcheck-lib.sh.tpl` con estas restricciones literales de data-model.md: «`schema`: exactamente 1; claves cerradas y tipos validados antes de usar el archivo.»; «`identity`: última identidad reconciliada bajo lock; no el último texto emitido.»; «`event_version`: entero no negativo <=9007199254740990; aumenta en cada cambio de identidad. Al alcanzar el límite, suspender avisos y diagnosticar, sin wrap ni reset que repita un evento.»; «`episode`: null o `{id, notified}`. id es la versión que lo abrió; `notified` indica al menos un aviso de alarma/recuperación parcial confirmado durablemente.» Estado privado regular <=16384 bytes/0600, sin payloads.
- [X] T037 [US4] Completar validación de pending en `modules/local-healthcheck-lib.sh.tpl`, copiando restricciones literales: «`pending`: null o aviso vigente. `version` coincide con el evento vigente. `kind` es WARN_EXPIRY, DEGRADED, RECOVERY_WARN o RECOVERY; `phase` es ready, inflight o pending. No se conserva payload, destino o respuesta cruda.»; «`attempted_at_s`: null si no hubo intento; entero epoch seconds si se reservó uno.»; «`clock_seen_s`: entero epoch seconds; máximo de reloj ya contabilizado para ese aviso, que nunca disminuye mientras siga vigente.»; «`retry_remaining_s`: entero entre 0 y 1800. Ready nace en cero. Inflight y pending con intento tienen reserva persistida.» Aplicar además las invariantes literales citadas en la sección Restricciones cruzadas de este archivo; inconsistencia produce state_reset, no replay.
- [X] T038 [US4] Implementar `hc_notice_reduce` en `modules/local-healthcheck-lib.sh.tpl` según las ocho filas del modelo: nueva versión por identidad, cancelar obsoletos, W/D mantienen episodio, D→W consolidada solo si notified, NONE cierra solo sin confirmación previa o al confirmar recuperación. Conservar deuda entre recuperaciones pendientes/nuevas alarmas; construir mensajes del snapshot actual, nunca texto externo.
- [X] T039 [US4] Implementar reloj/reserva en `modules/local-healthcheck-lib.sh.tpl`: delta=max(0,now-clock_seen), restante=max(0,restante-delta), clock_seen=max(clock_seen,now); reservar inflight/attempted_at/1800 antes de red, conservando el máximo del mismo aviso. Reinicio no resetea; transición nueva no hereda espera; reloj retrocedido se diagnostica y puede demorar, salto adelante depende del host.
- [X] T040 [US4] Implementar `hc_state_commit` y barrera de adopción en `modules/local-healthcheck-lib.sh.tpl`: umask077, temporal único del mismo directorio, validar, GNU sync TEMP→mv→sync DIR con rc explícito; checkpoint existente válido requiere sync archivo/directorio antes de adoptarlo. Cada commit/barrera fija deadline=min(inicio+5 s,notice_deadline,global_deadline), compartido entre sus operaciones, sin renovar fase/global. Falla suspende envío sin cambiar salud ni depender de errexit. Distinguir caída antes de rename de nuevo checkpoint visible sin flush confirmado.
- [X] T041 [US4] Implementar lock/transacción en `modules/local-healthcheck-lib.sh.tpl`: archivo estable `.state/.local-healthcheck.lock`, flock -n fd9 antes de observar y hasta terminar, no unlink ni fallback unlocked; flock hereda fd9, hijos de observación/persistencia/transporte lo cierran. El perdedor observa sin modificar/enviar; liberar explícitamente después de recoger hijos y limpiar temporales.
- [X] T042 [US4] Implementar transporte local en `modules/local-healthcheck-lib.sh.tpl`: env_file_get/precedencia legible 021, configuración curl por stdin, token sin argv/env del hijo/log/estado; escapar/rechazar controles, -q primero, conexión 5 s/total 15 s/retry 0, límite externo 18+2 s KILL y recolección, todo recortado por notice_deadline/global_deadline incluidos los márgenes. Confirmación exige rc0+HTTP200+JSON ok=true y commit final; respuesta perdida o checkpoint no acreditado conserva incertidumbre, un solo intento por evaluación y sin renovar presupuestos entre pasos.
- [X] T043 [US4] Integrar `hc_notice_run` desde `modules/local-healthcheck.sh.tpl`, recibiendo el global_deadline absoluto de entrada al CLI y fijando una vez notice_deadline=min(observation_end+30 s,global_deadline) después de observar bajo lock. Incluir adopción/reserva/red/confirmación y respetar global en cleanup/salida; conservar diagnóstico/rc 0/1/2, parser y silencio sin NOTIFY. Suspender todos los envíos/reintentos/recuperación sin estado acreditado, catálogo N7 en stderr; actualizar expectativas relacionadas de `tests/local-healthcheck.bats` junto a los RED de T030/T034, manteniendo sus 21 casos.
- [X] T044 [US4] Validar N01–N36, toda la regresión focal y SC-005/SC-006/SC-007 en ambos bash secuenciales; registrar número de llamadas/confirmaciones y estado por transición, valores ficticios ausentes y duración de fallas acotadas en `specs/047-local-healthcheck/tasks.md`. No usar Telegram real.

**Checkpoint**: cuatro historias funcionales en simulación; no equivale al gate Linux ni habilita publicación automática.

## Phase 7: Polish & Cross-Cutting Concerns

**Propósito**: completar composición real, revisión, gates congelados y cierre con autoridad explícita.

- [X] T045 Añadir CI04701/CI04702 a `tests/ci-workflows.bats`: job Linux y pin único conformes; validador real de reporte rechaza plan incompleto, skips, fallas y limpieza no confirmada. Sourcear `.github/scripts/local-healthcheck-integration.sh` sin efectos para probar solo sus funciones de reporte, sin ejecutar sudo/systemd; RED antes de T047/T048.
- [X] T046 Crear receptor HTTP con barrera de respuesta y wrapper que solo redirige destino hacia él en `tests/fixtures/local-healthcheck/linux-notify.py` y `tests/fixtures/local-healthcheck/linux-curl`; ejecutar curl real, respuesta HTTP/JSON real y valores ficticios. El receptor requiere inflight visible antes de responder; no bind por HTTPServer.server_bind ni imprimir request/token/payload.
- [X] T047 Completar L10/reporte/cleanup en `.github/scripts/local-healthcheck-integration.sh`: dos healthchecks solapados, segundo pierde lock y tercero no repite; wrappers flock/sync delegan a reales y acreditan sync temporal/directorio. Exigir L01–L10 completos, variantes, UID no root, fuente/versiones/propiedades permitidas y limpieza confirmada; todo fallo deja rc no cero y resumen `total=10 executed=10 skipped=0 failed=0` solo si corresponde.
- [X] T048 Añadir job `local-healthcheck-integration` a `.github/workflows/test.yml`: ubuntu-24.04, 10 min, contents:read, checkout persist-credentials:false, sin secrets/pull_request_target; prerequisitos V4, script ejecutable y paso always para evidencia sintética que no convierta rojo en verde. Single-source del yq v4.44.3 existente para Linux/macOS/nuevo job; conservar bash y runners de la matriz previa. Excepción medida en T060: presupuesto compartido del job BATS45→60min tras el corte real de macOS, sin modificar topes del producto/pruebas. Cerrar CI04701/CI04702 en los dos bash.
- [X] T049 Crear catálogo y corredor reproducible en `specs/047-local-healthcheck/tools/run_mutations.py` y registrar su mapa M00–M31→test en `specs/047-local-healthcheck/tasks.md`; trabajar en copias aisladas, controlar fuente/ancla/diff y restauración, con deadline por prueba y limpieza de sus procesos propios aun ante cuelgue. Cada mutación de la tabla inferior debe ser individual y producir un fallo pertinente; M00 es control sin mutar.
- [X] T050 Ejecutar control y M01–M31, uno a uno y en ambos bash, con `specs/047-local-healthcheck/tools/run_mutations.py`; cero sobrevivientes. Si alguno vive, diagnosticar el oráculo, añadir primero prueba que lo detecte y registrar delta del inventario antes del arreglo; no mutar el checkout validado ni correr BATS simultáneos.
- [X] T051 Pedir revisión independiente de solo lectura del diff en `modules/local-healthcheck*.tpl`, `setup.sh`, `.github/` y tests; examinar estados/privacidad/identidad/deadlines/aserciones vacuas y privilegios del arnés. Registrar hallazgos/refutaciones en `specs/047-local-healthcheck/tasks.md`, corregir con RED/GREEN y cerrar antes del gate completo.
- [X] T052 Verificar VERSION de origin/main actual y cualquier rebase antes de fijar `VERSION` prevista 0.33.0 y `CHANGELOG.md`; si cambió la base, recalcular versión/huellas/esperados sin reutilizar evidencia incompatible. La consulta/fetch de referencias es lectura; no autoriza push ni reescritura de una rama publicada.
- [X] T053 [P] Actualizar `README.md`, `docs/getting-started.md` y `docs/architecture.md` con diagnóstico local, dependencias/fallbacks, estado, siete días, treinta minutos, gate y limitaciones de entrega/conexión; sin afirmar mediciones futuras ni generalizar la vida del login.
- [X] T054 [P] Actualizar `docs/adding-a-notifier.md` y manualmente `CLAUDE.md` con la política local/precedencia021, confirmación durable y operación; preservar historial/bloque SPECKIT y no ejecutar agent-context ni editar AGENTS.md. Puede hacerse con T053 después de T052 al ser archivos diferentes.
- [X] T055 Verificar renders local dos veces y Docker contra base usando misma configuración ficticia, aceptando solo identificación de versión; aplicar shellcheck exacto del CI más CLI/helper renderizados y estáticas del script Linux. Registrar invariancia unidad/timer, cero delta funcional en docker/compose/código horneado, privacidad de evidencia y fuente congelada en `specs/047-local-healthcheck/tasks.md`; si amplía alcance, reabrir Constitución/gates.
- [X] T056 Ejecutar gate completo `bats tests/` sobre árbol congelado, bash 5.x y 3.2 secuenciales, con esperado B+92 o delta revisado documentado; comprobar TAP completo, stderr vacío y saltadas por motivo frente a T002. Ejecutar además los focales con SIGPIPE ignorada si no están acreditados sobre esa fuente; guardar huellas/resultados en `specs/047-local-healthcheck/tasks.md`.
- [X] T057 Completar matriz FR-001–FR-023/SC-001–SC-009 y recorrido de `specs/047-local-healthcheck/quickstart.md` en el Registro de `specs/047-local-healthcheck/tasks.md`: distinguir host acreditado, Linux pendiente y gates externos; revisar diff final, secretos, conteos y propuesta concreta de commit/PR. No hacer commit al preparar esta propuesta.
- [X] T058 COMPUERTA — Solo con autorización explícita para 047, crear el commit revisado con mensaje español imperativo y alcance exacto; comprobar modo 100755 del script Linux en el índice/commit y ausencia de .state/cache/secretos. Registrar SHA/diff en `specs/047-local-healthcheck/tasks.md`; sin autorización, dejar propuesta revisable y parar esta acción.
- [X] T059 COMPUERTA — Solo con autorización explícita para 047, hacer push y abrir PR borrador contra main con validación host y gate Linux aún pendiente; cuerpo por archivo/argumento estructurado, no shell interpolado. Registrar URL/cabeza en `specs/047-local-healthcheck/tasks.md`; no workflow_dispatch ni merge implícitos.
- [X] T060 Observar CI automática del PR y registrar en `specs/047-local-healthcheck/tasks.md` los checks de la misma cabeza, BATS por ambos brazos, shellcheck y job Linux real L01–L10 con variantes/evidencia/cleanup; exigir total 10 ejecutado 10 sin skips/fallas y medir margen frente a 10 min. Si falla, diagnóstico y prueba antes del cambio; revalidar solo lo invalidado por ese cambio.
- [X] T061 Consolidar evidencia de aceptación en `specs/047-local-healthcheck/tasks.md`, incluyendo fuentes y puente de hashes si solo cambiaron documentos; solo con autoridad de publicación vigente quitar borrador y dejar PR listo tras todos los checks verdes. Gate incompleto no se sustituye por simulación ni por “VM retirada”.
- [ ] T062 COMPUERTA DEL OPERADOR — Registrar en `specs/047-local-healthcheck/tasks.md` revisión/decisión y merge que haga el operador; el agente no ejecuta merge ni eliminación remota. No considerar terminado el feature solo por abrir el PR.
- [ ] T063 Verificar por lectura cabeza/árbol/VERSION y checks del merge; registrar resultado en `specs/047-local-healthcheck/tasks.md`, distinguiendo diferencias ajenas de la fuente validada. No resetear ni mover un checkout con trabajo ajeno para hacer la comprobación.
- [ ] T064 Cerrar `specs/047-local-healthcheck/tasks.md` con resultado de #111 y pendientes explícitos de despliegue/observación local y limpieza del operador; no borrar ramas/worktrees ni tocar flota, credenciales o unidades reales. La integración premerge reemplaza la exigencia de 24 h en flota, no demuestra un despliegue que no ocurrió.

## Inventario de pruebas y esperado

Inventario del diseño, materializado y ejecutado durante implement según el Registro. Se conservan los 21 tests de local-healthcheck.bats y los tests SIGPIPE existentes; sus modificaciones suman delta 0. Tres suites nuevas aportan 86 y ampliaciones de tres suites existentes aportan 6: **92 tests nuevos**. Variantes de una fila se ejecutan dentro de su test, sin confundirse con casos omitidos. No se necesitan 92 procesos BATS: cada archivo se ejecuta secuencialmente por bash.

| Archivo | Casos nuevos | Tarea de autoría | Total nuevo |
| --- | --- | --- | --- |
| tests/local-healthcheck-auth.bats | A01–A15/J01–J10; A16–A20 | T009, T025 | 30 |
| tests/local-healthcheck-processes.bats | C01–C20 | T015, T016 | 20 |
| tests/local-healthcheck-notices.bats | N01–N36 | T029–T035 | 36 |
| tests/local-render.bats | LC01/LC02 | T006 | 2 |
| tests/regenerate.bats | RG01/RG02 | T006 | 2 |
| tests/ci-workflows.bats | CI04701/CI04702 | T045 | 2 |

B es el plan TAP completo medido en T002, incluidas saltadas clasificadas. T002 confirmó B=2104 y T056 acreditó B+92=2196 por bash, sin nuevos skips imputables a 047. Un cambio de tests por implementación/revisión exige actualizar inventario/mapa y esperado con su justificación, conservando la trazabilidad; no cambiar solo el número para silenciar un rojo. Los diez escenarios Linux no forman parte del descubrimiento `bats tests/` y no suman al plan TAP del host.

### Mapa de casos de autenticación y journal

| ID | Comprobación |
| --- | --- |
| A01 | Forma completa, acceso y renovación futuros, OK |
| A02 | Acceso vencido con renovación lejana, OK |
| A03 | Dos tokens vacíos y expiresAt=0 exactos, D preciso |
| A04 | Solo un token vacío, W incompleto |
| A05 | Campos token ausentes/null/tipo incorrecto, W |
| A06 | JSON/raíz inválidos, W sin abortar |
| A07 | Archivo ausente/ilegible/no regular o jq ausente, W |
| A08 | Cada fecha ausente/null/string/bool/fracción/extrema, W |
| A09 | mcpOAuth distractor no sustituye fechas |
| A10 | Renovación vencida con acceso futuro, D distinto |
| A11 | Datos completos y campos adicionales no secretos no cambian clase |
| A12 | Forma incompleta con fecha aparentemente vencida no inventa pérdida |
| A13 | Tokens centinela no salen de jq ni llegan al snapshot/log/argv |
| A14 | Treinta evaluaciones sanas con acceso vencido, todos OK sin avisos |
| A15 | Límites enteros seguros/unidades de fecha; no conversión heurística |
| A16 | Siete días más 1 ms, sin WARN de vencimiento |
| A17 | Exactamente siete días y plazos positivos menores, WARN |
| A18 | Exactamente vencido y pasado, D |
| A19 | Redondeo días/horas/<1h en mensaje |
| A20 | Nuevo login quita vencimiento y mantiene otros WARN |
| J01 | Journal vacío con rc0 no añade error |
| J02 | Lectura ausente/fallida/deadline añade W |
| J03 | Ambas frases terminales con fechas futuras dan D |
| J04 | Acceso renovable conocido no se vuelve pérdida |
| J05 | Excepción de acceso con datos incompletos conserva W |
| J06 | 401 desconocido conserva D sin atribuir revocación |
| J07 | Refresh temporal solo añade W |
| J08 | Terminal/excepción en ambos órdenes y deadline tras D conservan D |
| J09 | 401 desconocido/excepción y deadline tras D conservan D y limitación |
| J10 | >64 KiB principio/final, rc y captura limitada sin E2BIG/SIGPIPE |

### Mapa de casos de procesos

| ID | Comprobación |
| --- | --- |
| C01 | Socket del principal |
| C02 | Socket exclusivo de hijo |
| C03 | Socket exclusivo de nieto |
| C04 | Subcgroup de la unidad |
| C05 | Proceso ajeno del mismo UID |
| C06 | Prefijo de cgroup parecido sin frontera |
| C07 | Listener/local443/remoto4430 rechazados |
| C08 | Inodes parecidos no equivalentes |
| C09 | Unidad inactiva con socket ajeno, D |
| C10 | Tool/permisos insuficientes, unknown W |
| C11 | ControlGroup vacío/raíz/jerarquía desconocida, W |
| C12 | PID reutilizado sintético, no reabrir ruta numérica |
| C13 | Proceso desaparecido durante consulta |
| C14 | FD o pertenencia cambiados invalidan positivo |
| C15 | InvocationID cambiada exige repetir |
| C16 | Nace hijo, misma InvocationID, inventario final cambia |
| C17 | Segunda inestabilidad, unknown |
| C18 | Frontera1024/1025 candidatos, sin truncar |
| C19 | Deadline 25 s y llamadas acotadas, D previo prevalece |
| C20 | Positivo válido vence otro incompleto; negativo incompleto unknown |

### Mapa de casos de avisos

| ID | Comprobación |
| --- | --- |
| N01 | Schema/claves/tipos/rangos/tamaño/modo privados |
| N02 | Invariantes cruzadas y overflow de versión |
| N03 | Otros WARN tienen identidad NONE, sin nuevo aviso |
| N04 | Primera W y treinta repeticiones, una confirmación |
| N05 | Treinta W/treinta D/recuperación, tres confirmaciones |
| N06 | D→W consolidada y recuperación parcial sin falso OK |
| N07 | D→W→D tiene nueva versión al reentrar |
| N08 | Cambio de texto/motivo no repite |
| N09 | Reiniciar tras confirmar no repite |
| N10 | Nuevo episodio tras recuperación confirmada |
| N11 | Sin aviso confirmado, cancelar sin recuperación |
| N12 | Deuda de recuperación sobrevive a nueva alarma |
| N13 | Pendiente obsoleto y transición nueva sin espera heredada |
| N14 | Intentos 0/30/60, frontera 1799/1800 s y ninguno después del éxito |
| N15 | Retroceso más corrección sin doble crédito |
| N16 | Reinicio conserva espera y referencia máxima |
| N17 | Ausente/dañado: reset diagnosticado, no replay |
| N18 | Cada falla de precommit impide toda red |
| N19 | Ack y falla previa al rename final deja inflight |
| N20 | Ack/rename/sync DIR fallido; adoptar nuevo solo tras barrera |
| N21 | Reinicio con checkpoint anterior inflight, entrega incierta |
| N22 | Barrera de adopción falla de nuevo, cero red |
| N23 | Contención real, perdedor sin escritura/envío, observación fresca |
| N24 | Faltan dependencias, suspensión y salud conservadora |
| N25 | fd9 cerrado en hijos; controller muere antes de unlock; probe recupera lock y cleanup recoge hijos |
| N26 | rc/HTTP/JSON/ok deben confirmar juntos |
| N27 | Respuesta perdida tras recepción no es confirmación |
| N28 | Curl config por stdin, flags, controles y escaping |
| N29 | Valores secretos fuera de argv/env/log/estado y temporales limpios |
| N30 | Doble estricto de timeout: éxito y TERM ignorado seguido de KILL/recolección; transporte dentro del presupuesto |
| N31 | Doble de sync: orden/errores; CLI completo desde configuración hasta cleanup/salida <=60 s con reloj controlado, fases H5 sin renovar global, sin llamada fuera de plazo |
| N32 | Sin configuración completa, sin tráfico/registro nuevo |
| N33 | Legacy legible gana; ilegible permite fallback; sin source/eval |
| N34 | Reactivar entrega reconcilia solo situación vigente |
| N35 | Tipos inesperados de archivo/lock suspenden envíos |
| N36 | Catálogo stderr, salud independiente y nada de respuesta externa cruda |

### Restricciones cruzadas literales para T037

Estas citas son del modelo, forman parte de la tarea T037 y no se dejan a discreción de implementación:

> Toda identidad W/D requiere episode no null, con id entero positivo <=event_version. pending.version, si existe, debe ser exactamente event_version.
>
> DEGRADED solo admite pending.kind DEGRADED; WARN_EXPIRY admite WARN_EXPIRY o RECOVERY_WARN. Una alarma sin pending requiere notified=true, porque ya se confirmó su aviso.
>
> NONE admite episode=null/pending=null, o episode.notified=true con pending.kind RECOVERY. RECOVERY y RECOVERY_WARN siempre requieren notified=true.
>
> Ready exige attempted_at_s=null y retry_remaining_s=0. Inflight/pending exigen attempted_at_s entero no negativo <=clock_seen_s; clock_seen_s es no negativo y no supera el entero seguro. Las fechas de intento se expresan en segundos, sin conversiones heurísticas.

## Dependencias y orden de ejecución

```text
T001–T003 Setup → T004–T008 Foundational
    → US1 T009–T014 (MVP local)
    → US2 T015–T024
    → US3 T025–T028
    → US4 T029–T044
    → T045–T050 integración preparada + mutaciones
    → T051 revisión → T052 versión → T053/T054 docs
    → T055/T056 gates → T057 propuesta revisable
    → T058/T059 compuertas Git → T060 CI real
    → T061 aceptación → T062 merge operador → T063/T064 cierre
```

US2 usa el arnés sano de US1; US3 usa el clasificador de US1; US4 usa el snapshot completo de US1–US3. Aunque varias funciones sean separables, comparten plantillas y el orden de prioridad evita conflictos. El script real L01–L09 se prepara en US2; L10 requiere US4 y se completa en Polish. Solo el gate completo L01–L10 cierra SC-009.

Dentro de cada historia: pruebas primero, observar fallo pertinente, modelo/funciones, coordinación, integración y checkpoint. Las tareas de autoría de N29–N35 son secuenciales porque editan el mismo archivo; sus ejecuciones no se paralelizan. Los gates remotos son dependencias externas, no tareas “hechas” por preparar un comando.

### Ejemplos de paralelismo por historia

| Historia | Ejemplo permitido y límite |
| --- | --- |
| US1 | Sin tareas [P]: T009/T010/T011 comparten suite o plantilla; ejecutar en secuencia. Preparar datos fuera del checkout no autoriza otra corrida BATS. |
| US2 | Tras T016, T021 sobre linux-service.py puede prepararse mientras T017–T020 modifican la biblioteca/CLI; T022 espera ambos trabajos. |
| US3 | Sin tareas [P]: A16–A20 amplían la misma suite de US1 y luego cambian la misma biblioteca; no solapar. |
| US4 | Sin tareas [P]: N01–N36 comparten archivo; reducer/store/transporte comparten plantilla. Concurrencia de N23 es el escenario del test, no otra suite. |

Oportunidad transversal: T053 y T054 después de T052 trabajan en documentos distintos. Estos ejemplos describen posibilidades, no invocan subagentes ni otorgan permiso para editar el mismo archivo desde dos sesiones.

## Catálogo mínimo de mutaciones para T049/T050

| Mutante | Cambio individual | Oráculo previsto |
| --- | --- | --- |
| M00 | Control sin cambios | Todas las suites focales verdes |
| M01 | Primer expiresAt recursivo | A09 |
| M02 | Acceso vencido produce D | A02/A14 |
| M03 | Forma incompleta es login perdido | A04/A05/A12 |
| M04 | Excepción renovable silencia todo el journal | J08/J09 |
| M05 | Solo MainPID | C02/C03 |
| M06 | Prefijo de cgroup sin slash | C06 |
| M07 | Puerto aceptado por prefijo | C07 |
| M08 | Reabrir proc por PID numérico | C12 |
| M09 | No revalidar InvocationID | C15 |
| M10 | Omitir enumeración final | C16 |
| M11 | Envío sin exclusión | N23 |
| M12 | Red aunque precommit falla | N18 |
| M13 | Ignorar falla del flush final | N20 |
| M14 | Basta HTTP200 | N26 |
| M15 | JSON ok=false confirma | N26 |
| M16 | Espera menor de 1800 s | N14, incluir frontera 1799/1800 |
| M17 | Reinicio elimina reserva | N16 |
| M18 | Referencia del reloj baja | N15 |
| M19 | DEGRADED deduplicado de por vida | N07/N10 |
| M20 | Nueva alarma borra deuda de recuperación | N12 |
| M21 | Recuperar sin previo confirmado | N11 |
| M22 | Token en argv | N29 |
| M23 | Token exportado al transporte | N29 |
| M24 | No renderizar helper local | RG01 |
| M25 | Renderizar helper en Docker | RG02 |
| M26 | Diferir KILL fuera del presupuesto | N30 |
| M27 | Reporte Linux parcial puede salir0 | CI04702 |
| M28 | Legacy gana por existencia, no legibilidad | N33 |
| M29 | Saltar invariantes entre campos | N02 |
| M30 | Adoptar confirmación visible sin barrera | N22 |
| M31 | Hijo conserva fd9; tras morir controller retiene lock | N25 |
| M32 | Error operativo de validación se trata como corrupción/reset | N17 |
| M33 | Adoptar el primer documento de un stream de estado | N01 |
| M34 | Recuperación omite los motivos WARN vigentes | N06 |
| M35 | Retirar margen de limpieza del commit | N31 |
| M36 | Aceptar proveedor sync sin semántica GNU acreditada | N24 |
| M37 | Enviar al alcanzar el límite del contador | N02 |
| M38 | Posponer unlink del journal hasta después del productor | N31 |
| M39 | Aceptar stream de documentos OAuth | A06 |
| M40 | Parsear ss sin consultar plazo por línea | C19 |
| M41 | Silenciar motivo del grafo conservando WARN | Caso previo wiki-graph de local-healthcheck.bats |
| M42 | Deadline del journal borra D ya observado | J08/J09 |
| M43 | Composición descarta limitación del journal tras D | J08/J09 |
| M44 | Extracción de campo falla sin diagnóstico | N36 |
| M45 | Fallo al crear captura de respuesta queda silencioso | N36 |
| M46 | Fallo al desvincular captura de respuesta queda silencioso | N36 |
| M47 | Python privado vuelve al selector de Xcode | N30 (macOS) |
| M48 | Timeout sintético mide duración con reloj de pared | N30 |


El catcher debe caer por el defecto plantado, no por parseo roto, dependencia ausente o ancla vacía. Mutaciones adicionales halladas en implementación/revisión se numeran y registran sin sustituir las anteriores. Si un mutante es equivalente por plataforma, justificar y probarlo donde la semántica exista; no contarlo como detectado solo por error de infraestructura.

## Cobertura de requisitos y gates

| Requisito/criterio | Tareas responsables | Evidencia mínima |
| --- | --- | --- |
| FR-001, FR-022, SC-008 | T006–T008, T012, T043, T055 | LC/RG, unidad/timer/QMD/grafo, Docker salvo versión |
| FR-002, FR-020 | T012, T020, T043, T055 | Niveles 0/1/2, catálogo y sin reparación/servicio vivo |
| FR-003–FR-006, FR-008, SC-001/SC-002 | T009–T014, T025–T028 | A/J, treinta sanos y formas perdidas/desconocidas |
| FR-007, SC-003 | T025–T028 | Límites 7 días/ahora y tiempo restante |
| FR-009/FR-010, SC-004 | T015–T024, T060 | C01–C20 y pertenencia real L01–L09 |
| FR-011 | T035, T042/T043 | N32–N34 y parser021/legacy |
| FR-012–FR-014, SC-005 | T030, T038, T043/T044 | N03–N13, tres confirmaciones y recuperación condicionada |
| FR-015/FR-016 | T029, T032/T033, T036/T037, T040/T041 | N01/N02/N17–N25/N35, cero red sin estado |
| FR-017/FR-018, SC-006 | T031/T032/T034, T039–T044 | Reserva, tiempos, obsolescencia, ack/rename/flush |
| FR-019/FR-021, SC-007 | T004/T005, T009, T034/T035, T042/T044, T055 | Canarios de VALORES, sin credenciales ni agente real |
| FR-023, SC-009 | T021–T023, T045–T048, T058–T061 | CI real L01–L10, fuente, UID/versiones, cleanup |
| Principios III/VI y gate de revisión | T002, T049–T056 | Baseline, mutaciones, revisión independiente, shellcheck, versión y host dual |

## Estrategia de implementación

1. Completar Setup/Foundational y US1 hasta T014 para demostrar el MVP diagnóstico en local. No publicar esa parcialidad como feature terminada.
2. Añadir US2 y US3 con checkpoints y pruebas independientes; preparar L01–L09 sin tocar agentes.
3. Completar US4 con fallas inyectadas antes de producto y sin credenciales reales; las secuencias de persistencia/reinicio son requisito, no optimización posterior.
4. Cerrar fixtures de integración, mutaciones, revisión y documentación antes del gate host largo. Congelar fuente y repetir gates solo si cambios nuevos invalidan su evidencia.
5. Preparar publicación concreta y solicitar únicamente la autoridad que falte para T058/T059. Esperar CI automática de esa cabeza; diagnosticar cualquier rojo antes de tocar código.
6. Entregar PR listo con todos los gates; el operador decide el merge. Registrar verificación posterior y separar despliegue/limpieza.

## Registro

### 17-11-2026 — Generación de tasks

Se ejecutó setup-tasks una vez en la rama/worktree 047, con todos los documentos disponibles. Hooks before_tasks/after_tasks sin registrar (`hooks: {}`). Se generaron 64 tareas: Setup 3, Foundational 5, US1=6, US2=10, US3=4, US4=16 y Polish/cierre20. Se fijó inventario planificado de 92 tests nuevos y 10 escenarios Linux, con baseline pendiente de T002. Ninguna tarea de implementación está hecha por esta generación.

La generación no ejecuta BATS/mutaciones/gates, no modifica runtime/tests/VERSION/constitución, no hace commit/push/PR/merge, no usa SSH/Docker/sudo/servicios ni lee credenciales. El Registro de intake conserva las fases anteriores. Siguiente comando manual recomendado: speckit-analyze sobre estos artefactos; no se encadena automáticamente.

### 17-11-2026 — Remediación documental U1/A1 autorizada

El análisis posterior encontró dos hallazgos medios, sin altos/críticos y con cobertura formal 32/32: U1, preparación de timeout/sync en los tests macOS sin responsabilidad explícita; A1, origen del presupuesto de avisos y prueba global del CLI insuficientemente precisados. El operador aprobó «Aplicar y volver a analizar», limitado a estos documentos, conservando 64 tareas y 92 pruebas previstas, sin implementación ni commit.

U1: T004/T005 asignan los dobles estrictos en PATH privado y N30/N31 sus autopruebas de éxito, señales/recolección, orden y fallas. No se depende de coreutils instalado en el Mac ni se sustituye con esos dobles la persistencia real del gate Linux. A1: H5/H6 fijan global_deadline de 60 s antes de configuración, observación de hasta 25 s y avisos de hasta 30 s después de observar; fases, commits, TERM/KILL y cleanup quedan limitados por los deadlines absolutos sin renovarlos. T012/T019/T034/T040/T042/T043 y la variante N31 quedan alineados.

Las dos revisiones focales de solo lectura confirmaron el cierre documental, sin nuevas contradicciones en los ajustes. La validación estática confirmó 64 IDs/etiquetas/rutas válidos, US1=6/US2=10/US3=4/US4=16, 92 tests nuevos planificados, M00 más 31 mutaciones y referencias relativas válidas. Runtime, tests, VERSION, constitución, spec y modelo de datos se conservaron. No se ejecutaron BATS, mutaciones, gate Linux, servicios o escrituras Git. El nuevo análisis transversal se presenta en la respuesta del comando; ninguna de las 64 tareas de implementación queda hecha por esta remediación.

### 17-11-2026 — Implement: T001 y arranque de T002

T001 verificada: worktree/rama047 y selector propios, HEAD 3afae74bd6335f7ebd8f6b4ff613b4e876f2db08, VERSION0.32.0, constitución1.1.0; checklist requirements16/16 y hooks vacíos. Autorización: implementar localmente hasta las compuertas T058/T059; no commit/push/PR/merge ni agentes vivos. La memoria histórica de046 está desactualizada frente al merge; no se usa para inferir su estado actual.

T002 se ejecuta sobre clon local aislado de HEAD, sin archivos no versionados del operador y con rama main local para las pruebas que la requieren. Bash5.3.15 seguido de3.2.57, BATS1.13.0; procesos secuenciales y evidencia en `/Users/rodrigo-hinojosa/.cache/agentic-047/implement-k69condw` (TAP/stderr/versiones/baseline.json). Aún no se acredita resultado ni se marca T002.

Verificación de ignores del setup de implement: .gitignore ya protege .state y archivos generados; se agregaron solo __pycache__/ y *.pyc para las herramientas Python. Faltaba .dockerignore; se creó en la raíz con exclusiones defensivas. El contexto real de los agentes es ./docker (compose:9), de modo que no se cambia su contexto efectivo, Dockerfile ni COPY. No se crearon ignores de tecnologías ausentes ni se tocó AGENTS.md.

T002, primer brazo terminado: bash5.3.15, plan2104, ok2104, not-ok0, saltadas69, stderr0 bytes, rc0, 2099.149 s (34 min59 s). El clon de la base conserva su diff de HEAD vacío. Bash3.2.57 ya está en ejecución, iniciado después de terminar el anterior. T002 sigue pendiente.

### 17-11-2026 — Preparación de oráculos durante la segunda línea base

Mientras el clon aislado ejecuta el segundo brazo, se prepararon en este worktree los fixtures privados, las tres suites nuevas (A/J30, C20, N36) y los seis casos LC/RG/CI: 92 casos físicos previstos. Todavía no se ejecutan BATS nuevos ni se acredita ningún RED/GREEN de producto. T004–T056 continúan pendientes; escribir un caso no acredita su corrección ni su cobertura. Runtime, setup, VERSION y workflow siguen sin cambios de comportamiento.

Dos revisiones preparatorias de solo lectura encontraron debilidades del arnés: variante cgroup v2 enmascarada por una ruta inválida anterior, espía fd9 dependiente de procfs en Mac, ausencia de espía de argv de jq, alcance incorrecto de un predicado jq, fallback stat contaminable en GNU, éxito de reintento desplazado a90 min, inyección de rename que no se alcanzaba y variantes incompletas de muerte/deadlines/pending. Se fortalecen dentro del inventario físico previsto; la revisión T051 del producto sigue pendiente. No se ejecutaron BATS desde esas revisiones.

Sonda independiente del doble timeout: el backend compartido dejaba vivo un nieto resistente a TERM cuando moría el padre; retenía el pipe y agotó el watchdog externo de4 s. Se eliminó solo el PID de ese fixture. El doble exclusivo de047 se reemplazó por una implementación estricta que completa la terminación del grupo antes de retornar: repetición rc124, stderr0 y nieto ausente. Evidencia privada timeout-tree-{red,green}.json. El fixture de046 no se modificó. Smoke directo del arnés bajo bash3.2: HARNESS_SMOKE_OK; sin BATS ni herramientas/servicios del host.

Sonda de fd9 con handshake: en ambos bash, cerrar9 solo dentro de una función/subshell no basta si el shell de sustitución lo conserva; muerto el controller, el probe flock aún retorna1. Con cierre explícito al inicio del cuerpo de la sustitución, retorna0. Evidencia fd-substitution-probe.json; la sonda inicial sin handshake se descartó y no se cuenta como evidencia. Este resultado guía el cierre de descriptores en la implementación futura.

### 17-11-2026 — T002/T003 cerradas y RED de T006

Base aislada 3afae74bd6335f7ebd8f6b4ff613b4e876f2db08, diff y status vacíos al terminar. BATS1.13.0. Bash5.3.15: plan2104/ok2104/fallas0/saltadas69/stderr0, 2099.149s. Bash3.2.57: plan2104/ok2104/fallas0/saltadas70/stderr0, 1741.610s. Los resultados ok incluyen las saltadas; no se presentan como2104 ejecuciones de casos. Evidencia baseline.json y TAP/err/versiones bajo el cache ya indicado.

Saltadas compartidas: 62 Docker opt-in,1 timeout ausente,1 procfs ausente y5 flock ausente. Bash3.2 añade1 por read-timeout que exige bash4+. No se ocultó ninguna falla ni se ejecutaron suites simultáneas. El conteo B confirmado es2104 por bash; las tres suites nuevas A/J30+C20+N36 y LC2/RG2/CI2 suman92, esperado2196. Se conservan21 casos previos y el conteo SIGPIPE. El mapa FR/SC usa los grupos A/J/C/N/R de contracts/validation.md V2 y el inventario por ID de este archivo; LinuxL01–L10 queda aparte.

T006 RED, antes de tocar runtime/setup: comando bats --tap --filter '047 (LC|RG)' tests/local-render.bats tests/regenerate.bats, secuencial. Ambos bash: plan4,ok0,fallas4,stderr0; 6.629s y6.420s. LC01 falla por plantilla helper ausente; LC02 por ausencia del motivo de componente faltante; RG01 por helper runtime no generado; RG02 conserva ausencia Docker pero falla la existencia de plantilla común. Evidencia t006-red-{bash5,bash32}.{tap,err} y t006-red.json. Este RED es de empaquetado, no una reproducción del defecto de login #111.

### 17-11-2026 — Foundational T004–T008 cerradas

Se agregó la biblioteca local con interfaces definidas y carga sin I/O; sus clasificadores aún devuelven desconocido y no se usan para afirmar corregido #111. setup la renderiza junto al CLI exclusivamente local. Las guardas de helper/env_file evitan source ausente y conservan D de unidad inactiva; no cambian unidad, timer, Docker ni configuración de operador. Los21 fixtures previos ahora expresan tokens y fechas completos sin alterar sus intenciones.

Primer intento de GREEN: los19 casos seleccionados pasaron en ambos bash, pero BATS terminó rc1 y stderr191 por PATH privado borrado antes de la limpieza. No se acreditó verde. Se corrigió teardown para restablecer PATH y limpiar la caché de comandos. Repetición t007-green2: 22/22,rc0,stderr0,27.608s/27.180s. Regresión completa t008-green: 21/21,rc0,stderr0,25.323s/23.533s. Ambos pares fueron secuenciales. Los casos LC/RG conservan par local, source puro, ausencias, dos regeneraciones y ausencia de runtime en Docker fresco.

El arnés tiene PATH cerrado, timeout047 estricto con TERM/KILL y grupo recogido, sync de archivo/directorio con orden/retornos e inyección, flock real o Perl efectivo, transporte/argv/env ficticios y reloj por raíces explícitas. La falla de escritura se prepara por override privado de _hc_state_write en el proceso de prueba; no es perilla productiva. Smoke estricto directo: rechazo de systemctl no previsto, sync global/-f/directorio sin archivo previo, retorno de sync inyectado y opción timeout inválida; STRICT_FIXTURES_OK en bash3.2. N30/N31 conservan sus autopruebas y variantes de composición para US4. No se ejecutó servicio, red real ni credencial del operador.

### 17-11-2026 — US1 T009–T014 cerradas

RED t009-red: A01–A15/J01–J10,25 casos; ambos bash7ok/18fallas,stderr0,14.301s/14.858s. Siete casos de desconocimiento conservan GREEN desde el prototipo y quedan sujetos a mutaciónT050; no se inventó un RED. El CLI generado anterior, con acceso1ms y renovación9007199254740991ms ficticios, dio rc2 y login expired: evidencia del falso aviso, no una medición de cuenta real.

Se implementó lectura única de claudeAiOauth en jq: tokens solo dentro del parser, forma vacía exacta, ambas fechas enteras seguras y plazo de renovación. Se implementó catálogo journal por evento, captura2000líneas, rc y precedencia de terminal/401 desconocido; el acceso conocido no borra otro evento. Primera vuelta t010-unit:23/25 en ambos bash, quedando solo integraciónCLI pendiente (61.837s/37.103s,stderr0). Una autoprueba adicional dentro deJ02 confirmó temporal abandonado al vencer antes del chmod: t011-cleanup-red,1falla por bash; se corrigió esa salida y quedó verde en el integrado.

El CLI ahora guarda uptime crudo al entrar, antes de cargar bibliotecas/configuración; después convierte ese instante y entrega global_deadline absoluto de60s. Se fija observación de25s una vez y las llamadas externas acotan TERM/KILL dentro del presupuesto. La carga se guarda y el source del CLI define funciones. Los fixtures previos usan el mismo main con raíces explícitas. El clasificador SIGPIPE real sustituyó la extracción textual del if viejo, manteniendo los7casos y los payloads grandes por archivo.

Checkpoint t012-integrated:57/57,rc0,stderr0 en bash5.3.15 (86.541s) y3.2.57 (84.269s), secuenciales. Incluye25A/J,21previos, LC/contratos locales seleccionados y7SIGPIPE; A14 acreditó30evaluacionesOK sin avisos. Evidencia t012-integrated.json y TAP/err. El helper aún conserva deliberadamente la heurística PID anterior para US2 y el CLI la entrega021 anterior para US4; no se declaran cgroup ni deduplicación resueltos. No hubo commit/publicación/servicios reales.

El hook protect-secrets rechazó comandos genéricos de edición por referencias literales a .env dentro de plantillas/textos. No se leyó ni escribió ningún archivo de credenciales. Las ediciones se completaron mediante parches con destino explícito no secreto; no se alteró ni deshabilitó el hook.

### 17-11-2026 — US2: cgroup, handles proc y arnés Linux preparado

T015/T016: t015-red dio 6/20 OK y 14 fallas en ambos bash, stderr vacío, 29.633 s y 18.155 s. Las fallas cubren hijos/nietos/subgrupos, frontera de puerto/pertenencia, identidad e inventario cambiantes y presupuesto. Se conservaron los positivos previos sin inventar su RED.

T017–T020: se sustituyó la heurística MainPID por propiedades de unidad, enumeración cgroup v2 acotada a 1024 candidatos, cwd proc fijado antes de ss, FDs/inodes relativos y revalidación. Se compara unidad e inventario, con una repetición dentro del mismo plazo; positivo acreditado vence un candidato incompleto y ausencia requiere recorrido completo. La observación conserva D de unidad inactiva y publica unit_invocation válido o null. Los fixtures de los 21 casos anteriores ahora expresan proc/cgroup/socket coherentes, sin leer procesos del Mac.

Primera vuelta t018-unit: 9 OK/11 fallas en ambos bash. Diagnóstico: set -f del parser de stat inhibía después fd/*. La sonda confirmó flags hBc→fhBc y expansión literal; se validó el sufijo numérico sin alterar el glob. t018-unit2: 20/20, stderr vacío, 48.892 s y 33.076 s. Se fortaleció C19 para el plazo consumido por el systemctl final: t019-deadline-red, 1 falla por bash; tras la guarda, 1/1 (2.204 s/2.223 s).

La revisión preparatoria de solo lectura encontró lectura cgroup.procs sin rc acreditado y un C12 insuficiente para pinning. C10 agregó error de lectura parcial y C12 una colisión sintética de PID/starttime/pertenencia, sin afirmar reutilización real del kernel. t019-read-red: C10 cae y C12 pasa en ambos; tras lectura acotada y rc explícito, t019-read-green dio 2/2, stderr vacío (5.917 s/3.580 s). La documentación primaria confirma que un cgroup threaded puede fallar al leer cgroup.procs: https://cdn.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html#core-interface-files . El fallo conserva unknown, no absent.

Checkpoint integrado t020-regression: **77/77 en ambos bash**, rc0, stderr0, 132.499 s/126.380 s, secuenciales. Incluye A/J de US1, C01–C20 con variantes reforzadas, 21 previos, locales seleccionados y SIGPIPE. Evidencia privada en el cache de 047 ya indicado. No equivale al gate Linux.

T021–T023: fixtures Python, namespace solo loopback, unidades/probes User=runner y barreras L01–L09 preparados en .github/scripts/local-healthcheck-integration.sh. Se comprobaron sintaxis Bash y todos los bloques Python/fixtures por AST; no se ejecutó el script ni servicios. La revisión estática detectó falta de contraste del subgrupo, probes mal formados aceptables y limpieza basada solo en is-active. Se añadieron pertenencia real ControlGroup/worker, veredictos/UID/retornos coherentes, cgroup.events sin población y namespace sin PIDs antes de registrar cleanup. El reporte preserva ambas variantes de L06/L08.

El validador de reporte se probó como función pura, sin main: t022-report-red cayó en ambos por aceptar probes inválidos; t022-report-green pasó 1/1 en cada bash, stderr0 (1.608 s/0.834 s). Es una ejecución preparatoria del caso CI04702 ya inventariado, no un escenario Linux real ni un test físico adicional. L10 sigue deliberadamente pendiente de T047; el job y su ejecución real quedan pendientes. T024 acredita el host y la preparación estática, no SC-009 real.

Corrección de inventario del Registro: SIGPIPE conserva **8 casos** (4 de journal, 3 de wizard y 1 ratchet), no7. La mención7 en la entrada de US1 fue un error del registro; los TAP57/77 son la evidencia medida y los conteos B/92/2196 no cambian.


### 17-11-2026 — US3 y RED de los avisos

T025–T028: A19 pasó a ejecutar el mensaje del CLI completo antes del arreglo. t025-red dio 4 OK/1 falla por bash; las clases internas ya satisfechas se preservaron. Tras agregar el redondeo puro de duración y presentarlo en el CLI, t028-green dio **30/30 A/J en ambos bash**, rc0 y stderr0, 56.382 s y 57.038 s. Incluye la frontera de siete días y +/-1 ms, formatos días/horas/<1h, relogin y WARN de otro componente.

T029–T035: los 36 casos N están escritos con datos ficticios, fallas de flush/rename, lock real del arnés, muerte del controller y transporte que cuenta incluso llamadas rechazadas. N31 incluye coste de configuración presente/ausente, origen de los 30 s después de observar y recorte por t0+60 s, con trazas de inicio de comandos. t035-red dio **2 OK/34 fallas por bash**, rc1 y stderr0, 38.402 s y 36.843 s. N03/N32 ya preservan el silencio para WARN ajeno/configuración ausente; no se inventó su RED. La nueva transacción de avisos se implementa después de esta evidencia; todavía no se acredita su GREEN.


### 17-11-2026 — US4: primera integración y revisión preparatoria

T043-notices dio 33/36 por bash, stderr0, 313.408 s/301.637 s. Pasaron secuencias de entrega, reintentos 0/30/60, retroceso de epoch, deuda de recuperación, fallas de cada commit/adopción, contención real, FD9/corte del controller, respuesta perdida, privacidad y plazos completos. Los tres rojos fueron: N08 generaba un snapshot pretty donde el doble debía mantener el formato de producción; N35 intentaba crear un directorio sobre el lock estable que el escenario anterior ya había dejado; N24 no recibía diagnóstico al faltar timeout durante la lectura de configuración. Se corrigieron los dos casos del arnés y se agregó suspensión diagnosticada del lector.

Revisión independiente preparatoria de US4, solo lectura: se confirmaron cuatro huecos. (1) Una recuperación WARN no describía los motivos restantes. (2) La validación podía adoptar más de un documento JSON. (3, ALTA) Un timeout de validación sobre checkpoint confirmado se interpretaba como corrupción y permitía duplicación. (4) Un flush detenido cerca del final de fase podía dejar un temporal sin margen para limpieza. N06, N01, N17 y N31 ganaron variantes antes de los arreglos. N22 además comprueba que cada adopción fallida sincroniza STATE, evitando un falso kill de M30 por desplazar la falla a un precommit.

t043-review-red: 2/7 OK por bash, stderr0, 39.148 s/35.394 s; N01/N06/N17 reprodujeron los hallazgos. N22 se había ubicado antes de la tercera evaluación en el propio arnés: se corrigió esa colocación y no se cuenta como RED del producto. t043-extra-red dio 19/25 por bash, stderr0, 46.831 s/43.903 s: N24 reprodujo la aceptación de un sync no GNU; el resto correspondió al contrato antiguo de los 21 casos previos y al job todavía ausente. t043-cleanup-red aisló el temporal restante tras timeout de flush: 0/1 en ambos, stderr0, 12.458 s/11.480 s.

Se añadieron mensajes desde el mismo catálogo cerrado que usa el CLI, un parser de documento único, rechazo operativo sin reset, margen de cleanup dentro de los mismos 5 s y comprobación acotada de GNU sync antes del lock. t043-review-green dio 30/31 por bash (101.197 s/98.329 s); el único rojo reveló que jq 1.7.1-apple devuelve5 para parseo inválido, no4. La lectura pasó a raw+fromjson con rechazo de datos controlado; timeouts/señales/errores de herramienta siguen suspendiendo. Está en validación focal, sin atribuir todavía su GREEN completo.

Los 21 casos previos conservan inventario: transporte espía por argv/stdin, persistencia falsa estricta y ack válido. H4 ahora exige que exista la captura antes de afirmar ausencia de la clave ajena; antes podía pasar en vacío. Se prepararon L10 y el job Linux, con yq compartido y evidencia de reporte; nada se ejecutó en Linux. La revisión de L10 no halló bloqueo nuevo. Un supuesto error de regex se refutó con sonda del AST sobre URL ficticia; no se cambió esa regex. Interfaz de artifacts verificada contra https://github.com/actions/upload-artifact (v7), sin publicación remota.

T049 preparado: catálogo M01–M36 y runner aislado. M32–M36 cubren los cinco huecos de validación operativa, documento único, texto de recuperación, cleanup y proveedor sync; las 36 variantes tienen anclas únicas y sintaxis válida en ambos bash, con filtros jq compilados. No es evidencia conductual. M19 se declara aproximación de supresión de reentrada: DEGRADED permitido solo en generación inicial; el schema no conserva una bandera histórica después de cerrar episodio. La ejecución M00/mutantes y la revisión final siguen pendientes.


### 17-11-2026 — Cierre de las fronteras de observación y control M00

t044-focal conservó 112/113 por bash, stderr0, 484.995 s/489.947 s. El filtro incluía los 92 nuevos y21 anteriores, pero omitió accidentalmente los8 SIGPIPE: no se acredita121 con esa corrida. El único fallo, N30, tenía un plazo sintético de500ms incompatible con el nuevo margen de limpieza1s; no alcanzaba el transporte. El arnés ahora concede2s y un tope externo8s, y el líder del transporte ficticio ignora TERM además de su hijo para probar la escaladaKILL del producto sin que el cleanup protector del doble oculte el defecto.

Revisión independiente de observación: dos MEDIA confirmadas (perfil OAuth podía contener varios documentos; parseo de ss no consultaba tiempo por línea) y una BAJA de aserciones intermedias inefectivas en3.2. Además se comprobó la transición que alcanza el límite del contador y el global consumido dentro de journalctl. t044-boundaries-red dio1/5 en ambos, stderr0,54.420 s/52.605 s: A06 anunciaba OK, C19 aceptaba el positivo tras procesar sin consulta de tiempo, N02 enviaba al alcanzar el límite y N31 iniciaba rm fuera del global; N30 ya pasaba con la corrección de arnés.

Arreglos: lectura OAuth única raw+fromjson dentro de jq, control de plazo por línea de ss, suspensión al alcanzar MAX y captura del journal por dos offsets privados con unlink previo al productor. El parser del journal consulta presupuesto y solo cierra FDs después del plazo; no necesita borrar por programa externo al volver de una captura vencida. Se reforzaron los positivos del archivo previo de21 casos para que fallen también en3.2. t044-boundaries-green: **14/14 en ambos bash**, stderr0,60.527 s/59.175 s. Incluye A06/A09/C19/N02/N30/N31 y los8 SIGPIPE; A09 pone primero el distractor recursivo con acceso y renovación lejanos para distinguirlo de la mutación de TTL de acceso.

T036–T043 implementadas; T045–T048 preparadas y sus oráculos CI verdes. La ejecución real Linux sigue reservada a T060. El catálogo se amplió a41 variantes sin sumar tests físicos: M37 contador, M38 cleanup del journal, M39 perfil concatenado, M40 parseo de ss y M41 mensaje específico del caso previo del grafo. Se adaptaron las anclas de M04/M08/M33 después del refactor; las41 variantes tienen anclas únicas, bash-n en ambos y filtros jq compilados.

Revisión independiente del corredor: se atendieron interrupción sin finally (ALTA), PGID sin líder, skips/controlM00, evidencia sobrescrita, permisos fuera de huella y carrera de unlink del registro de hijos. La sonda propia sin BATS dejó grupo vivo con la lógica anterior y ninguno con la actual, incluso con líder ya muerto. Otras sondas verificaron que chmod cambia la huella y que se rechaza evidencia no vacía conservando el canary.

M00 activo, secuencial en bash5/3.2, con SIGPIPE ignorada y esperado121 (92 nuevos+21 previos+8 SIGPIPE). Fuente de código/oráculos incluyendo modos: 890be2c530735fed9894dbab3fcd1568b9dcb19b674da27700f05a4e247d70eb. Evidencia en cache de047/mutations-control. El inventario físico actual confirma **2196 =2104+92**. T044/T049/T050 permanecen pendientes hasta sus resultados, sin commit ni publicación.


Precisión del catálogo antes de ejecutarlo: M19 dejó de usar la aproximación de generación inicial sugerida en el mapeo preparatorio. La variante efectiva guarda un marcador solo después de DEGRADED confirmado y nunca lo retira tras recuperación; dos ediciones plantan una única política errónea de deduplicación de por vida, conservando el schema. M24/M25 se asignan a RG01/RG02 (LC01 renderiza directamente y no prueba ese cableado), y M26 a N30 (C19 no es una prueba de hijo resistente). Es preparación del oráculo, todavía sin atribuir kills.


### 17-11-2026 — M00 verde y receptor real en loopback

T044/T049: control M00 **121/121 en bash5.3.15 y3.2.57**, rc0, stderr0,489.810 s/505.021 s, sin grupos propios pendientes de cleanup y con SIGPIPE ignorada. La huella de fuente de código/oráculos y modos se mantiene en890be2c530735fed9894dbab3fcd1568b9dcb19b674da27700f05a4e247d70eb. El corredor rechaza mutantes sin ese control dual válido de la misma fuente/runner. M01–M41 se ejecutan a continuación, sin modificar el checkout ni correr dos BATS.

T046 también tiene prueba real del auxiliar HTTP en el M4: probe_real_transport.py usó los archivos originales linux-notify.py y linux-curl, curl de sistema, FDs7/8 heredados y respuesta privada desvinculada, con entorno mínimo y datos ficticios. El receptor mantuvo la barrera hasta release; respondió HTTP200/ok=true con inflight y409/ok=false sin él. Dos recibos, rc0 y stderr0 en ambos; los procesos propios finalizaron. Evidencia privada: cache047/implement-k69condw/transport-real-k_0qyhgy. No prueba systemd/cgroups Linux ni sustituye T060. Huellas: linux-notify.py2b3cfd664b641a74fc56cb841fc2c1b4ba8f3117724aa72f729f22b7c0b7a177; linux-curl cff25619b605b42f34b014bec9556151bc333bdcd9e571468c13775b9765cd89.

Lecturas preparatorias por GitHub App: main remoto conserva3afae74bd6335f7ebd8f6b4ff613b4e876f2db08 y VERSION0.32.0; origin/main local coincide y #111 sigue abierto. No se escribió en GitHub ni se hizo fetch por SSH. La verificación final de versión y documentación se completa tras las mutaciones/revisión.

### 18-11-2026 — Revisión cerrada, versión y renders

La ronda previa de M01–M41 terminó con **82/82 ejecuciones detectadas y válidas**, 94 fallos pertinentes de oráculo, stderr0, sin sobrevivientes ni grupos propios pendientes. Fuente890be2c530735fed9894dbab3fcd1568b9dcb19b674da27700f05a4e247d70eb; evidencia mutations-final/results.json. M19 cubre la deduplicación literal de por vida, no la aproximación preparatoria ya superada. Después se añadió al corredor una guarda de admisibilidad: rechaza destino de evidencia dentro del checkout antes de crearlo. La sonda negativa salió2 sin crear directorio. Cambia runner_hash; el corredor rechaza reutilizar el control anterior, aunque esa guarda no cambia la ejecución en destinos externos válidos.

T051: revisión final independiente cerró corredor, avisos e integración preparada sin hallazgos pendientes. Observación encontró una MEDIA adicional: vencer el plazo durante la cola del journal borraba un terminal/401 ya leído. J08/J09 ganaron variantes que fuerzan ese límite y comprueban el veredicto agregado; t051-journal-red dio0/2 por bash, stderr0,4.553 s/3.017 s. Se conserva la evidencia D y se añade journal_unknown. La relectura detectó una BAJA: el agregado descartaba ese motivo de limitación; t051-journal-detail-red volvió a dar0/2 por bash, stderr0,6.764 s/5.120 s. La composición ahora conserva el motivo con guarda pura. **t051-journal-final-green:10/10 journal en ambos bash**, stderr0,23.699 s/24.770 s. Se añadieron M42/M43, sin aumentar los92 tests físicos. El catálogo efectivo es M01–M43.

T052: nueva lectura de VERSION remoto por GitHub App conserva0.32.0; HEAD y origin/main locales siguen3afae74bd6335f7ebd8f6b4ff613b4e876f2db08. Se fijó0.33.0 (MINOR ya prevista), sin rebase ni escritura Git remota. CHANGELOG añade Fixed de047 y conserva la historia046. La fuente actual de código/oráculos y modos es **d6a9d3263b77baa591f9c805cc6d3617f54a842613efb4928d5a1f49b6bd9262**; difiere de la ronda anterior por el guard del journal, su composición/pruebas y VERSION. No se atribuyen los82 kills anteriores a esta fuente: corre M00+M01–M43 de nuevo, secuencial, con el runner actuale2b1b3b5c9ec1d08e66a978a3fb1ec15b1e12dc8e496cd286987e955555e1827.

T053/T054: README, getting-started, architecture y adding-a-notifier describen fechas de renovación, pertenencia de sockets, estados, dependencias, precedencia021, persistencia, límites y entrega incierta. Se corrigió el texto caduco que atribuía al doctor el grep de journal retirado en022. Una revisión independiente documental pidió precisar que regenerate puede reinstalar unidades si install_service:true y sudo disponible, y nombrar curl entre dependencias del transporte; ambos atendidos. CLAUDE.md se actualizó manualmente, preservando historial; no agent-context ni edición de AGENTS.md. Quickstart ya distingue archivos implementados y gate Linux pendiente.

T055: verify_renders.py creó workspaces ficticios con install_service:false y CLI no-op, sin operar servicios. Dos regeneraciones produjeron el mismo par local ejecutable; bash-n dual y shellcheck del par dieron0. El comando exacto de shellcheck.yml dio0; los9 bloques Python del script Linux pasaron AST. Base/candidato producen idénticos docker-compose.yml, .mcp.json, heartbeat.conf y árbol docker/** incluyendo modos. Plantillas de unidad/timer byte-idénticas a base: User/ExecStart, SuccessExitStatus=1 2, OnBootSec=2min y OnUnitActiveSec=5min preservados. Evidencia renders-final/results.json. No se ejecutó systemd, sudo, Docker, login ni modelo. La integración Linux L01–L10 sigue pendiente de T060.

### 18-11-2026 — Matriz de cierre preparada para T057

La tabla identifica oráculos concretos; el resultado final del gate congelado se registra debajo cuando termine. “Host” designa el arnés sintético, no integración con el SO Linux ni entrega a un operador real. Los resultados de red del M4 solo acreditan el auxiliar HTTP. Estado del checklist de requisitos, sin modificarlo:16/16 satisfechos, cero pendientes.

| Requisito | Oráculos / evidencia de implementación | Límite de aceptación |
| --- | --- | --- |
| FR-001 | LC01/RG02, T055 compose/MCP/heartbeat/docker comparados con base | Sin delta funcional Docker |
| FR-002 | A/J/C, casos previos0/1/2, J08/J09 con deadline | DEGRADED prevalece; catálogos visibles |
| FR-003–FR-006 | A01–A15, J01–J10, M01–M04/M39/M42 | Raíz propia y eventos independientes; sin inferir revocación |
| FR-007 | A16–A20 | Fronteras7d/+1ms/vencido y redondeo |
| FR-008 | A04–A08/A12, LC02, J02 | Datos insuficientes producen limitación explícita |
| FR-009/FR-010 | C01–C20, M05–M10/M40 | Host; atribución real requiere L01–L09 |
| FR-011 | N32–N34, H/G3 previos, parser021 | Legacy legible gana; ausencia conserva diagnóstico |
| FR-012–FR-014 | N03–N13 | Episodios/reentrada/deuda/recuperación parcial y silenciosa |
| FR-015/FR-016 | N01/N02/N17–N25/N35, M11–M13/M30–M33/M35–M37 | Host; flush/lock nativos se acreditan en L10 |
| FR-017/FR-018 | N14–N16/N19–N22/N26–N31/N36 | Tiempo/controlador/ACK incierto; sin promesa exactly-once |
| FR-019 | A13/J10/N28/N29/N33, SIGPIPE, transporte real M4 | Valores ficticios fuera de argv/env/salida/estado; sin archivos reales |
| FR-020 | Source guards LC01/LC02, catálogo de comandos del arnés y revisión | Observación; no login/reparación/servicios vivos |
| FR-021 | Helper/PATH cerrado y fixtures, T055, catálogo reproducible | Host sin sudo/systemd/Docker/modelo reales |
| FR-022 | RG01, 21 casos previos, QMD/grafo y M41, T055 | Regeneración/par ejecutable, política de unidad/timer conservada |
| FR-023 | CI04701/CI04702 y script Linux preparado | **Pendiente T060:** diez escenarios reales y cleanup en CI |
| SC-001 | A14 | Treinta sanos con acceso vencido, todos OK, sin avisos |
| SC-002/SC-003 | A03/A10/A16–A20, J03/J06/J08/J09 | Clases precisas, límites y fechas ajenas |
| SC-004 | C01–C20 | Host acreditado por oráculo; Linux pendiente |
| SC-005 | N04–N10 | Treinta W/treinta D/recuperación, tres confirmaciones |
| SC-006 | N11–N27/N30/N31/N35/N36 | Secuencia0/5/25/30/55/60/65, estado/reloj/fallas/concurrencia |
| SC-007 | A13/N28/N29/N33/N36 y revisión de privacidad | Secretos sintéticos; diagnóstico sin abortos |
| SC-008 | LC/RG, casos previos y T055 | Artefactos funcionales Docker idénticos; versión0.33.0 |
| SC-009 | L01–L10 preparado y validador de reporte | **Pendiente integración Linux real antes del merge** |

Recorrido de quickstart:§1 checkout/autoridad/herramientas verificados; §2 baseline y RED registrados; §3 focales y mutaciones se cierran con fuente final; §4 renders/estáticas acreditados y gate completo pendiente en esta anotación; §5 Linux pendiente T060; §6 publicación y merge pendientes. Propuesta concreta preparada en [publication-proposal.md](publication-proposal.md), sin crear commit ni PR. No se reutiliza autoridad de046.

### 18-11-2026 — Control detenido por N13 y diagnóstico independiente

Sobre fuente d6a9d3263b77baa591f9c805cc6d3617f54a842613efb4928d5a1f49b6bd9262, mutations-closure/M00 dio121/121 en bash5 (559.571s) y120/121 en3.2 (522.429s), stderr0 y sin grupos propios pendientes. Único rojo: N13, calls_are2. El control detuvo el corredor antes de mutar. Esa corrida no conservó contador/estado/última salida; **la causa original no está determinada**. No se atribuye a carga ni a temporización sin evidencia.

Se instrumentó una copia temporal (cache047/n13-diagnosis), sin cambiar el checkout: cada evaluación guardó salida, estado, traza de comandos y contador. Treinta intentos N13 secuenciales en3.2 dieron30/30, stderr0, sin procesos propios pendientes, detención prevista ante primera falla. No se reprodujo el rojo; este resultado no demuestra su causa ni estabilidad universal. La revisión independiente confirmó que el reducer Dv1 no confirmado→Wv2 crea reserva nueva sin heredar espera; las trazas1→2 son coherentes. calls_are conserva su expectativa y ahora vuelca evidencia ante cualquier comparación fallida, incluso contador inválido; no se relajó la aserción.

Hallazgo independiente y compatible, pero **no demostrado como causa del N13 original**: cinco extracciones internas jq y dos preparativos de captura podían omitir el aviso sin diagnóstico. N36 ganó fallas individuales de los filtros .state/.action/.pending.kind/.event_version/.health y de mktemp/rm de respuesta. t051-operational-red (N13/N36) dio1/2 por bash, stderr0,6.773s/6.958s: N13 pasó y N36 acreditó el silencio. Tras agregar diagnósticos cerrados sin cambiar salud, topes ni reintentos, t051-operational-green dio2/2 en ambos, stderr0,17.109s/18.931s; sus siete variantes pasaron. Se añadieron M44–M46, manteniendo2196 casos físicos.

T055 revalidado en renders-closure: par reproducible/ejecutable, bash-n dual, shellcheck renderizado y comando exacto CI,9 bloques Python AST, compose/MCP/heartbeat/árbolDocker y plantillas de unidad/timer idénticos a base. Tras esa validación solo cambió el diagnóstico de la aserción de contador, sin delta de runtime. Una preparación M00 de mutations-release fue interrumpida con SIGINT únicamente al controller propio para completar esa traza antes de congelar; rc130/cleanup y ninguna atribución de resultado de pruebas a la corrida incompleta.

Fuente congelada actual **baef5c7536763f920ebaae0293eeb5a22ebe5df1cb61f21eb0945f51ab6bd008**, VERSION0.33.0, runner e2b1b3b5c9ec1d08e66a978a3fb1ec15b1e12dc8e496cd286987e955555e1827. M00+M01–M46 corren de nuevo en mutations-validated, sin reusar el control fallido o interrumpido. No se declara reparado el incidente original por cambiar diagnósticos; una nueva falla debe conservar la evidencia añadida y diagnosticarse antes de modificar comportamiento.

### 18-11-2026 — Segundo control detenido y fidelidad del arnés

mutations-validated/M00 en bash5 terminó120/121, stderr0,540.230s, sin grupos propios pendientes. Único rojo N05: confirmed después de treinta evaluaciones; calls_are había pasado. No se ejecutó3.2 ni ningún mutante tras ese control fallido. El diagnóstico de contador no cubría esta aserción: se añadió historia de cada evaluate, volcado al fallar confirmed/pending y rechazo explícito de un snapshot del arnés con salud no reconocida. Son trazas/verificación del arnés, sin bajar expectativas ni cambiar producto.

Una copia temporal confirmation-diagnosis ejecutó100 primeras confirmaciones WARN seguidas, borrando solo el ledger ficticio entre ellas y deteniéndose ante primera falla. Dio100/100,183.448s,stderr0,3100 comandos acotados, cero timeout; mediana0.040339s/máximo0.274416s por comando. Esto no es una reproducción del N05 completo ni explica su rojo. La variante B confirmation-pinned, idéntica salvo resolver el intérprete Python, dio100/100,161.801s,stderr0,3100 comandos, cero timeout; mediana0.0309765s/máximo0.249540s. Ambos probes conservaron historia/estado y TSV de elapsed/TERM/grace/retorno; cleanup sin grupos pendientes.

Verificación de entorno y revisión independiente: command-vpython3 apunta/usr/bin/python3, un selector que carga libxcselect; sys.executable apunta al Python de Xcode. Resolver una vez realpath(sys.executable) y comprobar ejecutabilidad elimina ese selector en el PATH privado. La comparación demuestra menor coste observado e identidad fijada, **no causalidad de las dos fallas originales**, que siguen sin determinarse.

Además, el doble de timeout medía duración con Time::HiRes::time (reloj de pared). N30 ganó un módulo temporal que adelanta solo esa función del hijo, sin modificar reloj del Mac. t051-clock-red dio0/1 en ambos bash,stderr0,0.726s/0.857s: vencía antes de terminar un hijo de50ms. Se cambió únicamente el reloj del doble a CLOCK_MONOTONIC. t051-interpreter-red luego dio0/1 en ambos,stderr0,1.450s/0.893s: el reloj ya pasaba, pero la identidad del intérprete privado seguía siendo el selector. Tras fijar esa identidad, **t051-harness-green dio4/4 (N13/N30/N31/N36) en ambos**,stderr0,27.848s/27.384s. Los caps de producto y del doble no se ampliaron; TERM/KILL/recolección y presupuesto global siguen ejercitados.

El arnés conserva ahora el nombre cerrado y elapsed/TERM/grace/status de comandos realmente vencidos; no registra argv ni entorno. Las aserciones de avisos muestran ese archivo junto con la historia y ledger ficticios si fallan. Se añadieron M47/M48, sin nuevos tests físicos;48 mutaciones efectivas. El corredor valida también bash-n de helper.bash y perl-c del timeout para que esos mutantes no cuenten un error sintáctico como kill.

Nueva fuente congelada **849bb4ac972eabe8a5763174eb557c59804c09538795319898d6f13af243194c**, VERSION0.33.0; runner **3adcb82358e9efb684bdf213afcb069ffc899c8cb252f4f5dcb32a050c45f5b0**. mutations-monotonic ejecuta M00+M01–M48 en secuencia. Desde renders-closure no hubo cambios de runtime: los deltas posteriores son oráculos/arnés/corredor y documentos. El gate completo aún no se declara ejecutado; Linux real continúa pendienteT060.

### 18-11-2026 — Control final dual acreditado

mutations-monotonic/M00: **121/121 en bash5.3.15 (421.162s) y3.2.57 (413.672s)**, rc0, stderr0, sin saltadas ni grupos propios pendientes. SIGPIPE ignorada explícitamente. Fuente849bb4ac972eabe8a5763174eb557c59804c09538795319898d6f13af243194c, runner3adcb82358e9efb684bdf213afcb069ffc899c8cb252f4f5dcb32a050c45f5b0. Incluye N05/N13, las nuevas calibraciones de N30, los diagnósticos N36 y los92 nuevos+21 previos+8 SIGPIPE. Las fallas previas siguen registradas con causa no confirmada; no se borran ni se adjudican retrospectivamente a los dos ajustes del arnés. Las48 mutaciones corren después de este control válido, sin modificar el checkout.

### 18-11-2026 — T050 cerrada y gate completo iniciado

M01–M48 dieron **96/96 ejecuciones detectadas y válidas** en los dos bash, sin sobrevivientes:112 fallos pertinentes de oráculo,522.259s acumulados de pruebas,stderr0 y cero grupos pendientes de limpieza. El corredor terminó0; las98 filas de results.json son los dos controles y los96 mutantes. Todas corresponden a fuente849bb4ac972eabe8a5763174eb557c59804c09538795319898d6f13af243194c y runner3adcb82358e9efb684bdf213afcb069ffc899c8cb252f4f5dcb32a050c45f5b0. M47/M48 comprueban las nuevas calibraciones sin contar sintaxis rota como kill. Evidencia reproducible en cache047/implement-k69condw/mutations-monotonic; el catálogo está versionado en tools/.

T056 inició la suite completa secuencial (5.x→3.2) sobre esa fuente, con plan esperado2196=2104+92. El driver conserva salida/error/versiones/duración y verifica huella al final de cada brazo. Su scratch propio usa ruta corta bajo/tmp para no exceder el límite del socket Unix de tmux en macOS; mktemp-d recibe template explícito y todas las fixtures quedan bajo esa raíz. Esto no cambia runtime ni oráculos. Caffeinate mantiene solo la vigilia de disco/CPU durante la orden, sin cambiar configuración persistente. Aún no se acredita el resultado de ese gate. README actualiza el catálogo a2196 y aclara que incluye saltadas condicionadas.

### 18-11-2026 — Cierre del alcance de los ignores

La revisión de alcance leyó setup.sh:2394 y comprobó que el scaffold copia el .gitignore raíz. Las dos reglas Python añadidas por la preparación de tooling también habrían viajado al workspace Docker. Se devolvió ese archivo byte a byte a base y se limitaron __pycache__/ y*.pyc a tools/.gitignore de047, que el scaffold no copia. No se cambió código, oráculos ni VERSION: la huella849bb4ac972eabe8a5763174eb557c59804c09538795319898d6f13af243194c se mantiene durante el gate. El .dockerignore raíz tampoco viaja al contexto ./docker.

renders-scaffold-final revalidó el par local, shellcheck exacto/renderizado, AST Linux, unidad/timer y comparación Docker incluyendo ahora .gitignore: todos conformes, sin servicios ni credenciales reales. La inspección opcional posterior de existencia de otro archivo de ejemplo fue rechazada por protect-secrets; no se leyó ese archivo ni se reintentó su inspección por otra vía. No se atribuye a esa consulta una validación inexistente. Se conservan los resultados concretos de renders-scaffold-final/results.json y la regresión completa que sigue en curso.

Precisión operativa de la anotación anterior: caffeinate-i evita la suspensión del sistema por inactividad mientras dura la orden; no es una configuración persistente ni una garantía frente a suspensión forzada.

### 18-11-2026 — T056: error del auxiliar de gate y prueba causal

El primer gate completo (cache047/gate-final) se interrumpió al detectar33 fallos concentrados en nightly-alert y los casos K de qmd-embed-nightly; no se inició3.2. El último progreso del driver tenía1499ok/33notok, sin stderr; es una corrida incompleta, no un gate acreditado. El código047 y esas suites no se corrigieron para silenciarla.

Causa demostrada: el wrapper de mktemp-d que preparé para aislar el scratch dependía de APL047_GATE_TMP. Los tests citados ejecutan env-i preservando PATH y eliminando esa variable; el wrapper intentaba usar un template en la raíz. Se verificó la limpieza de entorno en nightly-alert.bats:140 y qmd-embed-nightly.bats:229. Fue un error del auxiliar de validación, no evidencia de una regresión del producto.

Probe causal full-gate-mktemp-probe, cuatro casos N01/K1/K2/K3 en ambos bash: **nativo4/4** (3.098s/2.295s); wrapper original**0/4** (1.515s/1.494s); candidato con ruta propia fija**4/4** (3.089s/2.386s). stderr0 en las seis ejecuciones. Después de esta prueba se corrigió solo el driver de cache: su wrapper embebe el template privado con shell quoting y no depende de una variable que el hijo pueda eliminar.

Se probaron además **las83 pruebas completas de nightly-alert + qmd-embed-nightly con el wrapper fijo**,83/83 en bash5 (73.289s) y3.2 (70.640s), stderr0, eliminando expresamente la variable del entorno. Git diff de esas suites y nightly-alert.sh sigue vacío. La huella de código/oráculos permanece849bb4ac972eabe8a5763174eb557c59804c09538795319898d6f13af243194c; el control121dual y los96kills de047 siguen vinculados a esa fuente y a su corredor documentado. No se cambió ese corredor ni el runtime por el problema del auxiliar del gate completo.

T056 reinició desde el principio en cache047/implement-k69condw/gate-final-validated a las02:13:39 de Santiago,18-11-2026,5.x→3.2 en secuencia. Ese directorio preserva la nueva evidencia sin sobreescribir el intento incompleto. No se atribuye un resultado final antes de que ambos brazos terminen, ni se ejecuta Git/publicación mientras este gate esté abierto.

### 18-11-2026 — T056/T057 cerradas: validación local y propuesta de publicación

El driver terminó con rc0 y FULL_GATE_COMPLETE. Comando: `APL047_FULL_LABEL=gate-final-validated PYTHONDONTWRITEBYTECODE=1 /usr/bin/caffeinate -i python3 /Users/rodrigo-hinojosa/.cache/agentic-047/implement-k69condw/run_full_gate.py`. Las dos suites fueron secuenciales, sin editar código/oráculos durante la corrida.

| Bash efectivo | Plan / OK | Ejecutados | Saltadas | Fallas | Stderr | Duración |
| --- | --- | --- | --- | --- | --- | --- |
| 5.3.15 | 2196 / 2196 | 2127 | 69 | 0 | 0 bytes | 1957.594 s |
| 3.2.57 | 2196 / 2196 | 2126 | 70 | 0 | 0 bytes | 1909.173 s |

TAP, versiones, context.json, results.json y skip-comparison.json están en `/Users/rodrigo-hinojosa/.cache/agentic-047/implement-k69condw/gate-final-validated/`. Las saltadas coinciden con T002 por nombre y motivo, sin añadidas ni retiradas:62 Docker opt-in,1 timeout ausente,1 procfs ausente y5 flock ausente;3.2 añade read-timeout que exige bash4+. No se presentan las saltadas como casos ejecutados. Cada scratch privado fue retirado y no quedaron grupos propios pendientes de limpieza.

Ambos brazos y la comprobación final acreditan la misma fuente de código/oráculos/modos **849bb4ac972eabe8a5763174eb557c59804c09538795319898d6f13af243194c**, VERSION0.33.0. El control focal M00 de121/121 por bash con SIGPIPE ignorada y los96/96 mutantes detectados ya corresponden a esa fuente; no se repiten sin un cambio que invalide la evidencia. Después del gate solo se actualizaron documentos excluidos de esa huella. Los fallos anteriores N05/N13 y el intento incompleto del auxiliar siguen conservados arriba con sus límites de diagnóstico; el verde actual no demuestra la causa de los dos fallos aislados.

T057: la matriz FR-001–FR-023/SC-001–SC-009 anterior distingue cobertura host y aceptación Linux pendiente. Quickstart§1–4 recorrido y acreditado;§5 requiere CI real L01–L10,§6 publicación/merge. Renders/estáticas e invariantes permanecen acreditados en renders-scaffold-final. Revisión final:45 archivos candidatos de047, diff-check0, índice vacío, rama047 y HEAD3afae74bd6335f7ebd8f6b4ff613b4e876f2db08. La lectura final de GitHub confirmó main en ese mismo commit y VERSION0.32.0. Sin delta en docker/, scripts/, plantillas de unidad/timer o .gitignore raíz; el script Linux es ejecutable en disco, pendiente comprobar100755 en índice/commit al autorizar T058. Checklist de requisitos16/16, sin modificar sus marcas. Hooks after_implement parseados:lista vacía, ninguna acción de extensión que ejecutar.

Una auditoría consolidada opcional fue rechazada por protect-secrets al mencionar extensiones sensibles en una lista de exclusión; no se ejecutó ni se inspeccionó un archivo sensible. Se abandonó esa auditoría y el cierre se basó en el diff y en el inventario de rutas/metadatos de los45 candidatos, además de los oráculos de privacidad con valores ficticios ya acreditados. No se afirma haber ejecutado el análisis rechazado.

Propuesta concreta revisable: [publication-proposal.md](publication-proposal.md), con mensaje `fix: corrige los falsos avisos del healthcheck local` y cuerpo canónico [pr-body.md](pr-body.md). Incluye resultado host, incertidumbre de entrega y Linux pendiente. **T001–T057 hechas; T058–T064 pendientes.** No hubo commit, push, PR, workflow manual, merge, despliegue, SSH, sudo, Docker, credenciales reales ni llamadas al modelo por esta implementación. El siguiente paso requiere la autorización explícita de047 para T058/T059; quitar borrador solo con autoridad vigente y todos los checks de la misma cabeza verdes. El merge y el despliegue siguen fuera de esa propuesta.

### 18-11-2026 — Autorización de publicación y revalidación de entrada

El operador eligió «Autorizar publicación y seguimiento de CI»: commit `fix: corrige los falsos avisos del healthcheck local`, push, PR borrador y retiro del borrador únicamente con toda la CI de la misma cabeza verde, incluido Linux L01–L10. Merge y despliegue siguen excluidos. Esta autorización cubre el registro documental de la publicación y sus resultados; no cambia los gates de aceptación.

Revalidación al retomar: worktree/rama047, HEAD3afae74bd6335f7ebd8f6b4ff613b4e876f2db08, índice vacío, diff-check0 y VERSION0.33.0. GitHub main continúa en el mismo commit. La huella de código/oráculos/modos sigue849bb4ac972eabe8a5763174eb557c59804c09538795319898d6f13af243194c; no se repiten pruebas ya acreditadas sin delta de fuente. Se preparan únicamente los45 archivos revisados para el commit; los SHA y URL se anotarán después de observarlos.

### 18-11-2026 — T058/T059: commit y PR borrador publicados

Commit **8bc7baa951a480bd9293857a3c3148e878d90216**, `fix: corrige los falsos avisos del healthcheck local`:45 archivos,+6603/-214. Índice comprobado con diff-check0 y script Linux100755; el árbol del commit confirma100755 y blob64fa4327d59e3f2f29319296f75638cfe79f6aa6. Working tree limpio después del commit. Push ordinario sin force a origin/047-local-healthcheck acreditado, upstream configurado.

El conector GitHub devolvió403 «Resource not accessible by integration» al intentar crear el PR. No se creó por esa vía. Con el fallback gh autorizado, previa comprobación de que no existía PR abierto de la rama, se creó [PR #136](https://github.com/rodrigo-hinojosa-labs/agentic-pod-launcher/pull/136) contra main, **borrador**, cabeza8bc7baa951a480bd9293857a3c3148e878d90216. Cuerpo desde archivo privado preparado a partir de pr-body.md, con enlace inmutable al Registro de esa cabeza; no shell interpolado ni credenciales leídas.

CI automática pull_request, sin workflow_dispatch: [tests44304997727](https://github.com/rodrigo-hinojosa-labs/agentic-pod-launcher/actions/runs/44304997727) y [shellcheck44304997585](https://github.com/rodrigo-hinojosa-labs/agentic-pod-launcher/actions/runs/44304997585). Observados cuatro checks iniciales: shellcheck, BATS ubuntu/macOS y local-healthcheck-integration. Esta anotación no acredita todavía su conclusión ni Linux L01–L10. El registro de publicación se mantiene local hasta consolidar la evidencia, evitando cancelar una CI útil con escrituras documentales intermedias.

### 18-11-2026 — T060 parcial: integración Linux real acreditada

[Job Linux134804139309](https://github.com/rodrigo-hinojosa-labs/agentic-pod-launcher/actions/runs/44304997727/job/134804139309) en success,09:33:08–09:33:55 de Santiago:47s de job, margen553s frente a600s. El paso de integración tomó7s. El log contiene L01–L10 pass en orden y `047 integration summary: total=10 executed=10 skipped=0 failed=0`. El artefacto report.json se descargó y pasó nuevamente el validador puro, sin ejecutar servicios en el M4.

Reporte: schema1,10 escenarios pass,14 probes, UID1001 no root y cleanup:true; variantes L06 listener/remote4430 y L08 disappear/birth presentes. L10 conserva notify_busy en el competidor, confirmed en el primer proceso y ningún aviso en la repetición. Entorno real Ubuntu24 (imagen20261111.127.1), kernel7.0.0-1014-aws, systemd255, iproute2-6.1.0, util-linux flock2.39.3 y GNU sync/timeout9.4. La prueba usa únicamente servicios/red transitorios de la VM y datos ficticios; no acredita despliegue ni conversación en un agente vivo.

Puente de fuentes: el run tiene headSha8bc7baa951a480bd9293857a3c3148e878d90216; checkout de pull_request es el merge sintético **f584ad7e3632f3641265c760d90abd6958d008d4**, cuyos padres son main3afae74 y8bc7baa. Su árbol **134ca5d651e24afd742cb37abbe05774a9ecc7de** coincide exactamente con el del commit publicado. El hash del subconjunto Linux **f1225d6c7eee6533c9cbe657e8823228d549261df6eae10c9cec3c7879eea1f0** se recalculó localmente con la misma lista/algoritmo y coincide. No se confunde ese hash reducido con la huella completa849bb4ac de código/oráculos.

Evidencia privada: cache047/implement-k69condw/ci-8bc7baa-linux/apl047-evidence.XtBFoV/report.json; respaldo público en [artefacto14426728576](https://github.com/rodrigo-hinojosa-labs/agentic-pod-launcher/actions/runs/44304997727/artifacts/14426728576), digest sha256:5c4ab80d05d3a5ce51310eb1a0ac5941f2a9924a4d63b4f8223eac3527ced20d. Esta evidencia satisface la composición real de FR-009/FR-010, FR-015/FR-016, FR-023 y SC-004/SC-009 para esa fuente. T060 sigue abierta hasta conocer los BATS de ambos brazos y shellcheck; PR permanece borrador.

### 18-11-2026 — T060: macOS cancelado por capacidad del proveedor

Job134804139400 de8bc7baa quedó cancelled a las09:48:07 de Santiago, tras15min02s en cola. API confirma runner_id0, runner_name vacío y steps:[]. Las cuatro anotaciones del check explican que el runner hosted no adquirió el job tras varios intentos y que hay restricciones de capacidad en macOS arm64. No se ejecutó BATS en ese brazo; no se atribuye a código, tests, credenciales ni timeout de ejecución.

Ubuntu continúa en ejecución; Linux y shellcheck están verdes. Diagnóstico presentado al operador antes de cualquier arreglo. Se prevé reintentar únicamente el job macOS de la misma cabeza cuando termine el workflow, dentro del seguimiento autorizado; no workflow_dispatch, cambio de etiquetas/runners, límites, código ni expectativas. La evidencia Linux acreditada se conserva y el PR sigue borrador.

Se comprobó el reintento aislado anticipado: el conector no tiene Actions write (403 de integración), y gh API confirmó403 «The workflow run containing this job is already running». No se creó un nuevo intento ni se interrumpió Ubuntu. Por esa condición explícita del proveedor, el reintento se realizará al terminar el run. Los logs parciales de Ubuntu aún no están publicados (BlobNotFound), por lo que no se inventa un conteo de casos en progreso.

### 18-11-2026 — T060: Ubuntu verde y reintento macOS iniciado

Ubuntu original134804138845 terminó success a las09:57:29 de Santiago,24min21s de job, con margen20min39s frente a45min. Log completo: plan2196,2196ok,0not-ok,64 saltadas y2132 casos ejecutados; bash5.3.9 x86_64, BATS1.11.0, yq4.44.3 y jq1.8.1. Las saltadas son62 Docker opt-in y2 casos anteriores de037 por ref main ausente en el checkout shallow; ningún caso047 saltado. Las diferencias respecto del host se explican por esas2 refs y las herramientas/Linux disponibles, no se igualan artificialmente los conteos.

Tras quedar completo el primer run, gh POST al endpoint rerun del job134804139400 fue aceptado. Se inició únicamente macOS como job**134817991306**, attempt2, misma cabeza8bc7baa; ya está in_progress desde09:58:26, con runner asignado. GitHub replica los checks exitosos de Ubuntu/Linux con IDs134817993741/134818043358 conservando sus timestamps anteriores; no se volvieron a ejecutar esos brazos. PR continúa borrador y T060 abierta hasta concluir/inspeccionar macOS.

### 18-11-2026 — T060: macOS agotó el presupuesto; excepción acotada de CI

Job134817991306 terminó cancelled a las10:43:47 de Santiago,45min21s desde el inicio. Runner asignado y pasos de preparación completados; BATS corrió de09:59:12 a10:43:39. Anotación explícita: «The job has exceeded the maximum execution time of 45m0s». Es un evento distinto de la cancelación anterior sin runner.

TAP parcial: plan2196,1872ok,71 saltadas,1801 casos ejecutados y0not-ok entre los resultados terminados;324 casos sin resultado final. **Los92 casos nuevos047 terminaron, todos sin skip ni fallo.** El último ok salió a10:43:37.858, inmediatamente antes del corte; no se infiere un cuelgue ni se presenta la suite como completa. Versiones reales: bash3.2.57 arm64, BATS1.14.0, jq1.8.2 y yq4.54.3. El último caso terminado fue1872, read-only de038; Linux y Ubuntu de la misma fuente siguen acreditados.

Diagnóstico presentado antes de modificar código. Se preparó una copia temporal y se cambió primero la expectativa CI04701 de presupuesto60min: RED15/16 en ambos bash, único fallo pertinenteCI04701,9.100s/8.295s y stderr0. Después se cambió únicamente el timeout exterior del job compartido en esa copia,45→60min: GREEN16/16 en5.3.15/3.2.57,8.262s/8.192s y stderr0. Evidencia cache047/implement-k69condw/budget-60-proposal/results.json; el checkout conservó45 hasta terminar ese RED/GREEN.

Decisión acotada del agente dentro de la autorización de publicación y seguimiento de CI: ampliar a60min el presupuesto exterior del job BATS compartido, actualizar su guarda y registrar esta excepción a la preservación inicial de T048. No se atribuye al operador una elección numérica que no hizo. Es reversible, conserva runners/Bash/2196 casos/permisos y no toca los topes de cada prueba ni los25/30/60s del healthcheck. El job Linux conserva10min. No requiere cambiar plataforma, dividir suites, añadir privilegios o relajar aserciones de comportamiento; la nueva CI debe demostrar el recorrido completo y medir su margen.

Hallazgo lateral de entorno, sin corrección mezclada: la descarga declarada del workflow sigue en yq4.44.3, pero macOS resuelve yq4.54.3 de Homebrew por PATH. Se registra la versión efectiva y no se afirma un pin efectivo4.44.3 allí; no hay evidencia que atribuya a esa diferencia el corte por tiempo. El ajuste presente se limita al presupuesto exterior y su guarda.

Aplicación y revalidación del ajuste: t060-budget-actual,16/16 en bash5.3.15 (8.876s) y3.2.57 (8.382s), rc0/stderr0; CI04701/CI04702 además2/2 con SIGPIPE ignorada explícitamente,2.041s/1.686s, sin saltadas ni grupos propios pendientes. Evidencia privada t060-budget-actual.json y t060-budget-sigpipe/results.json. Inventario2196 y catálogo48 sin cambios.

Puente de fuentes para la nueva cabeza: hash completo de código/oráculos/modos **d81d962d9c91decfa6d64f0731b63ae1ad5ebdf62364f09b4fc8bf1ddc8281b9**. Frente a8bc7baa solo cambian, dentro de esa huella, el presupuesto/comentario del workflow y la expectativa CI04701; `git diff 8bc7baa -- modules scripts docker setup.sh VERSION` está vacío. El gate host2196 dual, M00 y las96 detecciones quedan atribuidos a849bb4ac, con producto/catchers de mutación idénticos; no se reclaman como una nueva ejecución completa sobre d81d962d. Se revalidó la superficie CI afectada y se exige CI completa de la nueva cabeza antes de entregar el PR listo. Los demás cambios de cierre son documentos y no afectan a esa huella.

### 18-11-2026 — T060: ajuste publicado y nueva integración Linux verde

Commit **17fcd6b3ff51b4746ed618138f6539d6f841b25d**, `fix: amplía el presupuesto de BATS tras medir la CI de 047`:8 archivos,+96/-20; solo workflow/guarda y documentos ya incluidos en el alcance de047. Push ordinario acreditado, working tree limpio inmediatamente después. PR#136 sigue borrador y apunta a17fcd6b. Nueva CI automática: [tests44318397218](https://github.com/rodrigo-hinojosa-labs/agentic-pod-launcher/actions/runs/44318397218) y [shellcheck44318396979](https://github.com/rodrigo-hinojosa-labs/agentic-pod-launcher/actions/runs/44318396979), sin workflow_dispatch. El cuerpo del PR se actualizó mediante archivo con el diagnóstico y el ajuste.

Shellcheck nuevo success. Linux nuevo [job134850516664](https://github.com/rodrigo-hinojosa-labs/agentic-pod-launcher/actions/runs/44318397218/job/134850516664) success:10/10 escenarios,14 probes,UID1001 y cleanup:true;24s de job y576s de margen frente a10min. Reporte descargado y revalidado con la función pura. [Artefacto14432498491](https://github.com/rodrigo-hinojosa-labs/agentic-pod-launcher/actions/runs/44318397218/artifacts/14432498491), digest sha256:2519b6fc9711d0902126441508014590991121acf46f34b74c4b88ff5611e60e; copia privada ci-17fcd6b-linux y verification.json.

Checkout sintético41545608282ac1da311ccde13fd5bcd4186d57a1, padres main3afae74 y17fcd6b, árbol22b6a3a21c44bb41cea1b5d08edbca6c879ed79a idéntico al commit17fcd6b. Subconjunto Linuxf1225d6c7eee6533c9cbe657e8823228d549261df6eae10c9cec3c7879eea1f0 recalculado y coincidente. BATS Ubuntu134850517125 continúa y macOS134850517237 espera runner en esta anotación; no se acredita su resultado por adelantado.

Precisión del hallazgo lateral de yq: está medida la versión efectiva4.54.3 del job macOS, distinta de la descarga declarada4.44.3. Atribuirla a Homebrew/prioridad de PATH es una inferencia por las rutas del workflow; el job no capturó command-v del binario. No se presenta esa procedencia como medición ni se le atribuye el agotamiento de45min. La corrección acotada sigue siendo solo el presupuesto exterior y su guarda; el origen efectivo de yq queda como seguimiento separado.

### 18-11-2026 — T060: Ubuntu de17fcd6b completo

Job134850517125 success,10:53:49–11:17:05 de Santiago:23min16s y36min44s de margen frente al nuevo presupuesto60min. TAP completo:2196ok/0not-ok,64 saltadas anteriores y2132 casos ejecutados; los92 nuevos047 completados sin skip. Versiones observadas: bash5.3.9 x86_64, BATS1.11.0, yq4.44.3, jq1.8.1. Fuente de la cabeza17fcd6b y hashd81d962d ya registrados. MacOS obtuvo runner y sigue ejecutando su suite; PR#136 conserva el borrador hasta su conclusión completa y la consolidación de evidencia.

### 18-11-2026 — T060 cerrada: CI completa de17fcd6b verde

macOS [job134850517237](https://github.com/rodrigo-hinojosa-labs/agentic-pod-launcher/actions/runs/44318397218/job/134850517237) success,10:58:51–11:52:54 de Santiago: **54min03s**, margen **5min57s** frente a60min. El nuevo presupuesto fue necesario; no se acortaron suites ni relajaron aserciones. TAP completo y secuencia1..2196 verificados:2196ok/0not-ok,72 saltadas y2124 casos ejecutados;92 nuevos047 completados sin skip. Saltadas:62 Docker opt-in,2 refs main ausentes,1 timeout ausente,1 procfs ausente,5 flock ausente y1 read-timeout de bash4+. Las dos saltadas adicionales frente al host3.2 son las refs main del checkout shallow, sin pérdida nueva de cobertura de047.

Versiones reales de macOS: bash3.2.57 arm64, BATS1.14.0, jq1.8.2 y yq4.54.3. Se conserva la distinción entre versión medida y procedencia del binario no medida. Ubuntu y macOS completaron el mismo plan2196, con sus diferencias de entorno clasificadas.

PR#136 consultado por lectura: OPEN, borrador, sin autoMergeRequest, base3afae74bd6335f7ebd8f6b4ff613b4e876f2db08 y cabeza**17fcd6b3ff51b4746ed618138f6539d6f841b25d**. Sus cuatro checks están COMPLETED/SUCCESS: shellcheck, BATS Ubuntu, BATS macOS y Linux real L01–L10. Fuente completa d81d962d y subconjunto Linuxf1225d6c registrados arriba. Queda acreditada T060; ninguna cancelación anterior se oculta ni se cuenta como una prueba ejecutada.

### 18-11-2026 — T061: aceptación y cierre documental

Se consolidaron los32 requisitos FR/SC con los oráculos del host, renders, mutaciones, los dos brazos completos deCI de17fcd6b y Linux real L01–L10. La matriz preparada en T057 queda superada en sus filas Linux pendientes por la evidencia real de T060: FR-009/FR-010, FR-015/FR-016, FR-023 y SC-004/SC-009 acreditados para la fuente indicada. Quickstart§1–5 recorrido;§6 conserva revisión/merge, despliegue y limpieza del operador como pendientes explícitos. Checklist de requisitos16/16 sin editar; hooks after_implement parseados otra vez:lista vacía.

Con la autoridad vigente y los cuatro checks de17fcd6b COMPLETED/SUCCESS, se habilitó PR#136 y se verificó `isDraft:false`, OPEN y cabeza17fcd6b a las11:57:02 de Santiago. Recibo privado readiness-17fcd6b.json. Se devolvió inmediatamente a borrador para publicar este registro de aceptación; no hubo merge ni autoMergeRequest. El cambio deSHA por documentación exige verificar de nuevo los cuatro checks antes de devolverlo a listo. T061 queda acreditada sobre17fcd6b y esa condición de entrega se mantiene para la cabeza documental posterior.

Este cierre solo cambia CLAUDE.md, pr-body.md, publication-proposal.md y tasks.md. Conserva hash completo de código/oráculos/modos **d81d962d9c91decfa6d64f0731b63ae1ad5ebdf62364f09b4fc8bf1ddc8281b9**, VERSION0.33.0 y subconjunto Linuxf1225d6c. No se repiten pruebas locales sin un delta que las invalide; la CI automática de la nueva cabeza permanece obligatoria. Sus resultados vigentes se enlazan desde PR#136/checks y se completan en el cuerpo del PR, sin atribuirles un SHA o un resultado futuro dentro de este mismo commit.

**T001–T061 hechas; T062–T064 pendientes del operador y la verificación posterior al merge.** No hubo despliegue, modificación de flota, SSH, Docker local, credenciales reales ni llamadas al modelo. El hallazgo lateral de yq queda registrado con su incertidumbre, sin mezclar un arreglo de PATH en047. El origen de los dos controles aislados N05/N13 anteriores sigue sin confirmar; la aceptación usa la evidencia nueva acreditada y conserva su historia.
