# Investigación de 047: healthcheck local

**Date**: 2026-11-17
**Base**: `3afae74bd6335f7ebd8f6b4ff613b4e876f2db08`
**Scope**: [#111](https://github.com/rodrigo-hinojosa-labs/agentic-pod-launcher/issues/111), modo local solamente.

La investigación del 17-11-2026 resolvió las decisiones de diseño con lecturas del código, la constitución y fuentes primarias. Tres agentes de investigación de solo lectura revisaron autenticación, avisos y Linux. No ejecutaron BATS, Docker, SSH, servicios, sudo ni modelos. Tampoco leyeron credenciales reales. La línea base 21/21 por bash pertenece a specify y se conserva en [intake.md](intake.md); no acredita la corrección nueva.

## D1. Empaquetado exclusivamente local

**Decision**: mantener el CLI `modules/local-healthcheck.sh.tpl` y añadir una biblioteca `modules/local-healthcheck-lib.sh.tpl` sin efectos al cargarla, renderizada como `scripts/local/agent-healthcheck-lib.sh` solo dentro de la rama local de `setup.sh`. El CLI resuelve esa biblioteca junto a sí mismo y conserva `env_file.sh` como parser de configuración.

**Rationale**: `setup.sh:3423-3470` ya concentra los renders locales. La biblioteca permite probar clasificadores y transiciones sin arrancar servicios. No se agrega una biblioteca bajo `scripts/lib/` ni un mirror Docker: esos árboles se copian al workspace y algunos se hornean. La plantilla nueva no se ejecuta ni se renderiza en modo Docker. Se comparan artefactos funcionales emitidos, descontando solo identificación de versión (FR-001).

**Alternatives considered**: todo dentro del CLI simplifica el número de archivos pero acopla pruebas al arranque; compartir `docker/scripts/lib/token_health.sh` conservaría el criterio erróneo de acceso y ampliaría el alcance; una biblioteca general de estado tiene semánticas incompatibles de fallback sin lock.

**Evidence**: `modules/local-healthcheck.sh.tpl`, `modules/local-healthcheck.service.tpl`, `setup.sh:3440`, `docker/scripts/lib/token_health.sh:106-146`. El CLI guardará la lectura de sus bibliotecas antes de hacer source: un componente ausente produce WARN, no un aborto silencioso de bash 3.2.

## D2. Snapshot estricto del login

**Decision**: una sola lectura con jq de `.claudeAiOauth`; tipos y campos explícitos. El shell recibe únicamente enums, presencia de datos y fechas/tiempo restante, nunca tokens o el objeto original. `accessToken` y `refreshToken` deben ser strings no vacíos para acreditar una forma renovable completa. Fechas: enteros epoch milliseconds entre 1 y 9007199254740991; no se convierten segundos heurísticamente.

**Rationale**: la búsqueda recursiva actual puede elegir una fecha de `mcpOAuth`. La forma `accessToken=""`, `refreshToken=""`, `expiresAt=0`, con campos presentes y tipos correctos, es la pérdida comprobada del issue. Ausencias, null, tipos desconocidos o fechas inválidas son información incompleta. Un acceso vencido con renovación válida no demota; renovación vencida sí produce DEGRADED, sin afirmar que la sesión ya cayó.

**Alternatives considered**: usar solo la fecha de renovación perdería la forma de tokens borrados; interpretar cualquier campo ausente como login perdido confundiría versiones desconocidas con fallas comprobadas; consultar al proveedor o renovar el login contradice FR-020.

**Evidence**: el esquema exacto procede de #111, no de una API pública estable del proveedor. La [documentación de autenticación](https://code.claude.com/docs/en/authentication#renew-an-expiring-login) distingue la renovación del acceso y el login que requiere intervención. No se supone una duración fija del refresh token.

## D3. Journal por eventos, sin silenciamiento global

**Decision**: conservar diez minutos y `-n 2000`; capturar en un temporal privado, comprobar el retorno y clasificar todas las líneas. Precedencia: terminal explícito, 401 no clasificado, refresh temporal/no verificable, ausencia de señal. La excepción conocida de acceso renovable se evalúa por línea; no suprime un terminal encontrado en otra.

**Rationale**: `Please run /login` y `You must be logged in to use Remote Control` son señales terminales del contrato observado. `Authentication failed (401): OAuth access token has expired` identifica acceso vencido, no demuestra por sí solo pérdida del login. `API Error: 401` no clasificado conserva DEGRADED. `Failed to refresh session` solo no acredita rechazo; añade WARN de verificación/refresh no disponible. Journal vacío y lectura fallida son casos distintos.

**Alternatives considered**: añadir cualquier frase de refresh a un grep terminal recrearía falsos positivos; ignorar todos los 401 si existe un texto de acceso vencido ocultaría errores distintos.

**Evidence**: [errores oficiales de Remote Control](https://code.claude.com/docs/en/errors#remote-control-couldnt-refresh-your-login); `modules/local-healthcheck.sh.tpl:59-62`. `tests/sigpipe-boot-paths.bats:74,106` extrae una línea de la implementación vieja: se reemplazará esa extracción por la función real, manteniendo payloads mayores de 64 KiB, captura acotada y ausencia de pipes con consumidores que cierran antes.

## D4. Pertenencia a la unidad e inodes de sockets

**Decision**: cgroup v2 de la unidad como fuente de pertenencia. Consultar ActiveState, ControlGroup, InvocationID y MainPID; enumerar recursivamente sus `cgroup.procs`, con frontera literal de ruta. Un proceso pertenece si su ruta es exactamente la de la unidad o comienza con esa ruta más `/`.

Por candidato con sockets, fijar primero el directorio `/proc/PID` como cwd de un subshell. Leer su `cgroup` y enlaces `fd/*` relativos a ese directorio; consultar `ss -H -t -n -e state established '( dport = :443 )'`; intersectar inodes `ino:N` con `socket:[N]`; revalidar el FD y pertenencia. No leer contenido de FDs, entornos o cmdline. Releer la identidad de la unidad al terminar. Un cambio permite una repetición dentro del presupuesto; una segunda inestabilidad produce unknown.

Para concluir absent, repetir la enumeración completa y comparar PID+starttime contra las identidades efectivamente recorridas. Un hijo nuevo dentro de la misma InvocationID exige reintento o unknown; una lista inicial sola no acredita ese negativo. Cada enumeración usa sus propios handles fijados; no se convierte starttime en sustituto del handle de atribución.

**Rationale**: no depende del formato variable `users:(pid=...)`, ni de un PPID que cambia por reparentado. Un handle proc fijado no pasa a identificar al proceso nuevo que reutiliza un PID. `present` exige evidencia positiva vigente; `absent` exige un recorrido completo y estable; cualquier limitación deja `unknown`. Las dos últimas clases son WARN diferentes.

**Alternatives considered**: MainPID solo es el defecto; PPID y nombres no acreditan pertenencia; un prefijo sin frontera acepta unidades hermanas; PID+starttime reduce carreras pero no es un handle estable. Un helper en otro lenguaje reduciría consultas ss, a costa de otra dependencia de producción.

**Evidence**: [systemd D-Bus 255](https://www.freedesktop.org/software/systemd/man/255/org.freedesktop.systemd1.html), [cgroup v2](https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html#processes), [handles proc](https://www.kernel.org/doc/html/latest/filesystems/proc.html#process-specific-subdirectories), [ss](https://man7.org/linux/man-pages/man8/ss.8.html), [FDs proc](https://man7.org/linux/man-pages/man5/proc_pid_fd.5.html). El costo del recorrido todavía debe medirse en implementación; el límite de tiempo evita un recorrido ilimitado. No se promete un snapshot atómico de toda la máquina ni una conversación Remote Control comprobada.

## D5. JSON propio, lock no bloqueante y flush explícito

**Decision**: `.state/local-healthcheck.json` (máximo 16 KiB, schema 1) y `.state/.local-healthcheck.lock`, ambos privados; aprovechar el directorio .state existente. Tomar `flock -n` antes de observar cuando se van a procesar avisos. Mantenerlo hasta terminar la transacción; el perdedor sigue diagnosticando pero no envía. Sin flock no existe fallback de envío sin exclusión.

El commit usa temporal único en el mismo directorio, jq, validación, `sync TEMP`, `mv TEMP STATE`, `sync STATE_DIR`, con retorno comprobado en cada paso. No se borra el archivo de lock. Los comandos flock de adquisición/liberación heredan el descriptor; los hijos de observación, persistencia y transporte lo cierran. Soltarlo explícitamente al terminar. Si no puede guardarse el registro, suspender todos los envíos y conservar el nivel de salud.

**Rationale**: rename evita JSON parcial; sincronizar también el directorio conserva el cambio de nombre. No se necesita añadir Python o SQLite al runtime. La nueva lógica nunca depende de errexit para comprobar un commit.

**Alternatives considered**: mkdir-lock requiere resolver bloqueos abandonados; SQLite añade dependencia y no resuelve la transacción de red; `docker/scripts/lib/state.sh` permite fallback unlocked y usa temporal fijo. Marcar entregado antes de enviar puede perder definitivamente avisos.

**Evidence**: [flock](https://man7.org/linux/man-pages/man1/flock.1.html), [GNU sync](https://www.gnu.org/s/coreutils/manual/html_node/sync-invocation.html), [fsync](https://man7.org/linux/man-pages/man2/fsync.2.html), [rename](https://man7.org/linux/man-pages/man2/rename.2.html). El arnés sintético aporta bloqueo efectivo y dobles estrictos de timeout/sync, con señales, orden y fallas verificados dentro de N30/N31; no depende de GNU coreutils instalado en el Mac. El gate Linux ejerce las herramientas reales. No se usa sync global ni syncfs de todo el filesystem.

## D6. Episodio, transición y confirmación durable

**Decision**: distinguir identidad notificable `NONE|WARN_EXPIRY|DEGRADED`, versión de transición, episodio abierto y aviso pendiente. Cada cambio de identidad crea una versión; el texto del motivo no crea otra. El episodio continúa hasta NONE más recuperación confirmada, o NONE sin ningún aviso confirmado. Así se conserva una recuperación pendiente aunque vuelva DEGRADED antes de entregarla.

Antes de red se guarda `inflight`, último intento y espera de 1800 s. Confirmación local exige curl rc 0, HTTP 200, JSON `ok=true` y commit durable posterior. Una respuesta perdida o caída después del ack y antes de persistir deja entrega incierta; el reintento puede duplicar el mensaje remoto. Nunca se etiqueta esa situación como confirmada ni se promete exactly-once.

**Rationale**: cumple la política de reintentar pendientes y evita convertir un envío incierto en un éxito inventado. La versión por transición permite D→W→D sin suprimir el segundo DEGRADED. La recuperación parcial combina problemas todavía presentes y no anuncia OK.

**Alternatives considered**: deduplicar por “DEGRADED enviado alguna vez” pierde reentradas; cerrar el episodio antes de confirmar recuperación pierde su deuda; esperar forever por una respuesta bloquea el diagnóstico.

**Evidence**: [Telegram making requests](https://core.telegram.org/bots/api#making-requests), [sendMessage](https://core.telegram.org/bots/api#sendmessage). Máquina completa en [data-model.md](data-model.md).

## D7. Reloj y presupuestos

**Decision**: persistir `retry_remaining_s` y `clock_seen_s`. En cada evaluación usar `delta=max(0, now-clock_seen)`, restar delta sin bajar de cero y guardar `clock_seen=max(clock_seen,now)`, sin reducir esa referencia mientras siga el mismo aviso. Un reloj que retrocede aporta cero tiempo y se diagnostica; su posterior corrección no vuelve a contar un intervalo consumido. Un intento fallido vuelve a reservar 1800 s conservando la referencia máxima; una transición nueva elegible no hereda la espera vieja.

Deadline global de 60 s desde la entrada al CLI, antes de leer configuración. El presupuesto de observación nace al iniciarla y admite hasta 25 s; el de avisos nace después de observar y admite hasta 30 s. H5 define los deadlines absolutos y su mínimo con el global: configuración, reintentos de observación, adopción, reserva, red, confirmación y cleanup no reinician ni extienden ese plazo. Se usa tiempo monotónico (`/proc/uptime`), separado de las fechas epoch del login. Cada llamada externa respeta el remanente mediante GNU timeout con escalada a KILL y recolección incluidos en él. N31 compondrá el CLI completo con reloj controlado; todavía no es una medición de ejecución.

Un envío: curl `-q` primero, conexión 5 s, máximo 15 s, sin retries internos; límite externo 18 s más 2 s hasta KILL. Cada commit tiene 5 s compartidos entre sus operaciones. Si falta tiempo para confirmar, queda incierto y se suspenden nuevos envíos de esa evaluación. Estos son límites de diseño por validar; no mediciones de rendimiento ni garantía frente a un kernel o almacenamiento bloqueado fuera del control de usuario.

**Alternatives considered**: solo un next_attempt_at absoluto no representa cuánto intervalo ya se contabilizó; bajar la referencia al retroceder permite doble crédito al corregirse el reloj y se descartó en la revisión independiente; dormir dentro del healthcheck añadiría otro scheduler; timeouts solo de curl no acotan un doble de prueba que ignore sus flags. La referencia máxima puede demorar conservadoramente el reintento después de un retroceso.

**Evidence**: [manual curl](https://curl.se/docs/manpage.html#--connect-timeout), [timeout GNU](https://www.gnu.org/software/coreutils/manual/html_node/timeout-invocation.html). Los presupuestos se probarán con fallas inyectadas, sin esperar 30 minutos reales.

## D8. Gate Linux y CI

**Decision**: job independiente `local-healthcheck-integration` en `.github/workflows/test.yml`, `ubuntu-24.04`, diez minutos, permisos contents:read y checkout sin persistir credenciales. Los BATS normales no crean servicios ni requieren sudo. El job usa systemd real, unidades transitorias con nombres únicos y red con solo loopback; healthcheck y procesos de prueba corren como runner, nunca root. sudo queda limitado al ciclo de vida de fixtures.

**Rationale**: el runner estándar es una VM desechable y permite esos fixtures. `ubuntu-latest` es móvil: se fija 24.04 y se registra ImageOS/ImageVersion, kernel, systemd y ss. No se usa un contenedor privilegiado como sustituto de un host systemd. Los prerequisitos faltantes hacen fallar el gate, sin skip o verde vacío.

**Alternatives considered**: una VM propia añade mantenimiento; user-units no reproducen exactamente la unidad de sistema y requieren otro bus; probar solo respuestas simuladas no satisface FR-023.

**Evidence**: [runners GitHub](https://docs.github.com/en/actions/reference/runners/github-hosted-runners), [imagen Ubuntu 24.04](https://raw.githubusercontent.com/actions/runner-images/main/images/ubuntu/Ubuntu2404-Readme.md), [systemd-run 255](https://www.freedesktop.org/software/systemd/man/255/systemd-run.html), [NetworkNamespacePath](https://www.freedesktop.org/software/systemd/man/255/systemd.exec.html#NetworkNamespacePath=), [sysctl IP por namespace](https://www.kernel.org/doc/html/latest/networking/ip-sysctl.html#ip-variables). El gate no se ejecutó durante plan; su evidencia es obligatoria antes de proponer merge.

## D9. Compatibilidad, versiones y pruebas

**Decision**: conservar 021 H1-H6, códigos 0/1/2 y razones de QMD/grafo; actualizar fixtures incompletos, no reutilizarlos como prueba de login sano. Mantener regresión SIGPIPE ejecutando el clasificador real. VERSION prevista 0.33.0, MINOR por el cambio visible de política y el precedente 042/044; revalidar contra origin/main antes del bump. La referencia local origin/main consultada sigue en 0.32.0.

El yq del nuevo job usará el mismo pin v4.44.3 del workflow, elevado a una única variable de workflow para no añadir otra copia. No se cambia la selección de bash ni los límites actuales de sus jobs. El shellcheck incluye los scripts nuevos y se aplica además a las plantillas renderizadas.

**Rationale**: no aparece una nueva fuente de configuración; siete días y treinta minutos son constantes aprobadas, no nuevas perillas. Los secretos siguen solo por el parser y stdin de curl, sin EnvironmentFile nuevo en la unidad de healthcheck.

**Alternatives considered**: tocar las sondas OAuth de Docker o añadir configuraciones no pedidas ampliaría el alcance. El conteo físico de pruebas y la duración final se fijan por medición en tasks/implement, no a partir del número de escenarios de este plan.

## Resultado de Phase 0

Todas las decisiones técnicas tienen una elección y alternativa documentadas. No quedan preguntas de diseño bloqueantes. Están pendientes de ejecución las pruebas, las mutaciones, el gate Linux y la revisión del código que se implemente: esta investigación no los marca como pasados. La revisión documental del plan y sus correcciones constan en intake.md.
