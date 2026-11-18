# Contrato: oráculos y evidencia de 047

**Date**: 2026-11-17
**Requirements**: FR-001 a FR-023; SC-001 a SC-009.

## V1. Fuente, base y test-first

Antes de cambiar comportamiento, medir la suite completa de la base en una copia aislada, registrar bash/BATS/yq y huellas. La línea base focal 21/21 de specify es histórica y no reemplaza esta medición. Conservar los rojos por aserción antes de cada arreglo; una falla de dependencia/arnés no cuenta como prueba del defecto.

BATS 5.x y 3.2 siempre secuenciales en el mismo equipo. Los jobs de CI son hosts distintos. No introducir asserts intermedios muertos (`! cmd` o `[[ ]]` en 3.2); usar `[ ]` o retorno comprobado. Datos grandes viajan por archivos, no argv/env.

## V2. Matriz de aceptación del host

Los siguientes son identificadores de escenarios, no un conteo físico de tests. tasks debe mapear cada fila a casos concretos y fijar el esperado final por medición.

| Grupo | Escenarios obligatorios | Requisitos |
| --- | --- | --- |
| A: auth | Acceso vencido renovable; renovación vencida con acceso futuro; límites 7 días/+1 ms/ahora/+1 ms; tokens vacíos observados; cada campo ausente/null/tipo incorrecto; JSON inválido; fechas extremas; raíces mcpOAuth contradictorias; falta de jq/archivo | FR-003 a FR-008 |
| J: journal | Vacío frente a rc fallido; terminal con fechas futuras; acceso renovable conocido; 401 desconocido; ambos órdenes de mensajes; refresh temporal; datos >64 KiB al principio/final; captura acotada | FR-005, FR-019 |
| C: conexión | Principal/hijo/nieto/subcgroup; hermano mismo UID y prefijo parecido; puertos exactos; listener; PID desaparecido/reutilizado; permisos; cambio InvocationID; jerarquía desconocida; deadline/cap de candidatos | FR-009, FR-010 |
| N: avisos | Repetidos W/D; escalada; D→W→D; recuperación parcial; recuperación silenciosa sin confirmación; deuda de recuperación seguida de nueva alarma; cancelación obsoletos; reset de estado; ausencia de configuración y precedencia legacy | FR-011 a FR-016 |
| S: persistencia y tiempo | Falla de cada paso de commit; cero red sin precommit; postcommit fallido tras ack; respuesta perdida; JSON/HTTP/ok falsos; concurrencia con lock real del arnés; falta de flock; salida del hijo; reserva 0/30/60 min; reinicio; retroceso del reloj; presupuesto | FR-015 a FR-019 |
| R: render/privacidad | Helper+CLI local, source sin I/O, biblioteca ausente, dos regeneraciones, User/SuccessExitStatus/timer inalterados, Docker funcional sin delta salvo versión; secreto centinela ausente en argv/env/salidas/estado/diagnósticos | FR-001, FR-019 a FR-022 |

SC-001 exige treinta evaluaciones sanas consecutivas, con acceso vencido y renovación válida, todas OK y sin avisos. SC-005 exige treinta W, treinta D y recuperación: exactamente tres avisos confirmados, incluyendo reinicios entre repeticiones. SC-006 se comprueba con reloj controlado en 0/5/25/30/55/60/65 min: intentos solo en 0/30/60 y ninguno después del éxito; también cero intentos con registro no persistible y cero recuperación sin aviso previo confirmado. No reemplazar estas secuencias por casos aislados que omitan repetición o persistencia.

Archivos previstos: local-healthcheck.bats existente actualizado; tres nuevos para auth, procesos y avisos; helper/fixtures compartidos; ampliación de local-render/regenerate y adaptación de sigpipe-boot-paths. Ningún test del host usa systemctl/sudo reales. El fake de una herramienta no puede caer al binario real si falta una respuesta.

El arnés debe probar su propia capacidad de fallar: transporte falso con estados y fallas; clock controlado sin sleeps de treinta minutos; writer que puede fallar por operación; proceso hijo que ignora TERM; canarios de valores secretos. En Mac se usa el flock de Perl ya existente donde falte util-linux, no un stub que siempre concede el lock.

T004/T005 suministran timeout/sync estrictos en el PATH privado del arnés, sin depender del GNU coreutils del Mac: timeout debe ejecutar, señalizar y recoger al hijo, y sync validar destino/orden/retorno sin llamar al sync global. Los argumentos no previstos fallan. N30 prueba el camino satisfactorio y TERM ignorado seguido de KILL; N31 prueba orden de flush, errores y plazos. Las variantes de dependencia ausente ocultan expresamente el doble correspondiente, sin caer al binario del host. La persistencia real se acredita solo en Linux con herramientas reales.

El arnés fija el intérprete Python real seleccionado al crear su PATH privado. El doble de timeout mide duración con CLOCK_MONOTONIC; N30 simula un salto del reloj de pared solo dentro del hijo y verifica identidad del intérprete, éxito, TERM/KILL y recolección. Sus registros de fallas contienen únicamente nombre cerrado del comando y tiempos/retorno, nunca argv ni entorno. La historia por evaluación y el ledger ficticio se muestran si una aserción de avisos falla.

N31 ejecuta el CLI completo con reloj monotónico controlado: lectura de configuración, observación bajo lock, adopción, reserva, red, commit final, cleanup y salida, contra el global de 60 s fijado antes de configuración. Incluye caminos con avisos configurados y sin configurar, topes de fase según H5, presupuesto consumido por operaciones anteriores y un intento de extender el global al cruzar una fase. Afirma cero llamadas posteriores al plazo, hijos recogidos y nivel de salud correcto; no espera un minuto real ni simula un kernel bloqueado. Son variantes del N31 existente, sin nuevos casos BATS físicos.

Casos de revisión obligatorios: JSON con tipos correctos pero kind incompatible con identity, recuperación con notified=false y fases/fechas incoherentes; legacy presente ilegible con configuración principal válida; retroceso y posterior corrección del reloj según la secuencia del modelo; nacimiento de hijo sin cambio de InvocationID. Inyectar en particular falla de sync del directorio DESPUÉS del ack y rename final: no afirmar confirmación en ese ciclo y, en el siguiente, adoptar el checkpoint nuevo solo después de sincronizarlo; probar también recuperación del checkpoint anterior inflight y falla repetida de esa barrera, sin envío.

## V3. Mutaciones mínimas dirigidas

El catálogo final se confecciona sobre anclas de implementación; no se cuenta aquí como ejecutado. Debe detectar al menos:

- volver al primer expiresAt recursivo o decidir por el acceso;
- convertir forma incompleta en login perdido;
- suprimir terminales por una excepción renovable en otra línea;
- volver a MainPID/PPID o aceptar prefijos de cgroup/puerto sin frontera;
- reabrir proc por ruta numérica tras fijar el handle, o aceptar InvocationID cambiada;
- retirar el lock o su precommit durable y permitir fallback unlocked;
- marcar éxito por HTTP sin ok, o ignorar falla del commit final;
- adelantar reintento, perder reserva en restart, restar tiempo negativo o bajar la referencia durante un retroceso y dar doble crédito tras corregir el reloj;
- deduplicar D de por vida, borrar deuda de recuperación o avisar recuperación sin confirmación previa;
- filtrar respuesta/stderr/token, omitir el render del helper o renderizarlo en Docker.

Un mutante sobreviviente se diagnostica antes de tocar el producto; el oracle nuevo debe fallar contra él y pasar sin mutar. No atribuir flakiness sin reproducir y medir.

## V4. Gate real Linux previo al merge

Job nuevo `local-healthcheck-integration` del workflow test, en `ubuntu-24.04`, timeout de 10 min, permissions contents:read, checkout con persist-credentials:false, sin secrets ni pull_request_target. Instalar el yq del mismo pin del workflow, sin introducir otro literal de versión. La matriz host existente sigue sin sudo/servicios en sus comandos BATS.

Prerrequisitos obligatorios: systemd como PID1 y bus de sistema; cgroup v2; systemd-run/systemctl/ss/ip/python3/jq/curl, flock de util-linux y GNU sync/timeout; sudo -n para el arnés; permiso del UID runner para observar sus fixtures. Si falta alguno, el gate falla. Ningún escenario se salta ni se sustituye por respuestas ficticias.

El script explícito `.github/scripts/local-healthcheck-integration.sh` prepara un workspace único, con agent.name normalizado, claude_cli ficticio e install_service:false. Renderiza el CLI y helper reales. No copia perfiles ni archivos de usuario. Su configuración de login/avisos es enteramente sintética.

Recursos del arnés:

- Namespace de red único con solo loopback, sin veth ni ruta externa. Sysctl de puerto no privilegiado ajustado SOLO dentro del namespace para el listener 443.
- Unidades transitorias de sistema con prefijo único `apl047-<run>-<attempt>-<nonce>`; target `agent-<name>.service`, receptor y probe del mismo fixture.
- Todos los cuerpos de prueba y el healthcheck corren como el UID runner no root. systemd-run aplica User y NetworkNamespacePath. Delegate=yes solo en el target ficticio que prueba un subcgroup.
- El probe comprueba su UID, guarda retorno/salida del healthcheck y termina con un resultado propio. El arnés verifica ese registro; no confunde el éxito de systemd-run con un healthcheck OK cuando el caso esperaba 1 o 2.
- Readiness por archivos y consultas reales, con deadline. Nada de sleeps que supongan arranque. RuntimeMaxSec/TimeoutStopSec acotan fixtures.

| ID | Escenario real | Resultado mínimo |
| --- | --- | --- |
| L01 | Socket remoto 443 del principal | present, salud sana sintética |
| L02 | Solo el hijo tiene socket | present; PID distinto del principal |
| L03 | Solo el nieto tiene socket | present; cadena de fixture y pertenencia contrastadas |
| L04 | Socket en subcgroup delegado | present, ruta bajo ControlGroup |
| L05 | Solo otra unidad del mismo UID, nombre/prefijo parecido | WARN absent; nunca falso OK |
| L06 | Listener sin conexión y remoto 4430 | WARN absent en ambas variantes |
| L07 | Target inactivo con socket ajeno abierto | DEGRADED por unidad |
| L08 | Proceso desaparece o nace un hijo durante observación, misma InvocationID | Desaparición: unknown o nueva observación coherente; nacimiento: present tras repetir, o unknown; no absent basado en el inventario viejo |
| L09 | Restart durante observación, nueva InvocationID sin conexión | Descartar muestra vieja; WARN, sin falso OK |
| L10 | Aviso sintético, dos healthchecks solapados y receptor HTTP local real | Un envío confirmado y checkpoint válido; repetición no envía; flock/sync/timeout y curl reales |

L08/L09 requieren barreras verificadas. El wrapper obtiene ss real después de fijar proc y bloquea antes de devolver su salida; el controller provoca terminación/restart, comprueba el cambio real y libera la respuesta capturada. Para nacimiento, el candidato inicial tiene un socket remoto 4430, y el controller crea el hijo con 443 después de capturar ss, antes de liberar la barrera; la enumeración final debe detectar al nuevo hijo. Todo handshake tiene deadline y falla si no se cruzó en el orden previsto. No basta preparar el cambio antes de arrancar el healthcheck.

L10 configura exclusivamente valores ficticios y un receptor HTTP dentro del namespace. Un wrapper de curl solo reescribe el destino de prueba y ejecuta el curl real; no fabrica HTTP, JSON ni retorno. El receptor verifica que inflight esté visible antes de liberar su respuesta ok=true. El segundo healthcheck se solapa con esa barrera y debe perder el lock; después de confirmar, una tercera ejecución no repite. Wrappers de flock/sync delegan a los binarios reales y registran operación/retorno sin payloads; se exige sync del temporal y directorio, checkpoint final y exclusión efectiva. El límite usa GNU timeout real. Esta composición no simula un corte físico del almacenamiento.

La prueba de PID reutilizado tiene además un caso sintético determinista. No modificar pid_max/ns_last_pid del host ni afirmar que L08/L09 demuestran una reutilización real. Los wrappers instrumentales no fabrican respuestas para acreditar pertenencia.

El gate usa TCP al puerto 443 como señal, sin afirmar TLS o conversación. Conservar pruebas de autenticación/transporte por fixtures; no hacer llamadas al proveedor o Telegram real.

## V5. Evidencia y limpieza

Registrar: head/huella, ImageOS/ImageVersion, kernel, versiones systemd/ss/herramientas, UID del probe, propiedades whitelisted de las unidades, cgroups, PIDs e inodes ficticios, retorno/salida saneada y resultado de cada escenario. No volcar env, cmdline generales, journal crudo del usuario ni valores secretos.

Resumen obligatorio, y guarda de plan/numeración completa:

```text
047 integration summary: total=10 executed=10 skipped=0 failed=0
```

L06 y L08 incluyen variantes dentro de su escenario. Un fallo de caso, preparación, deadline o limpieza deja rc no cero; total ejecutado incompleto tampoco es verde. Un paso always publica la evidencia ficticia en logs y resumen del job, aun al fallar; su rc no convierte una falla del gate en éxito.

Instalar cleanup desde el inicio. Detener SOLO unidades registradas de la corrida; esperar su salida y retirar SOLO su namespace y scratch. Nunca rm global, pkill por patrón amplio o ip netns del -all. Comprobar la retirada; si no se confirma, registrarlo como falla. La cancelación del job se trata como gate no verificado aunque la VM se retire después.

## V6. Aceptación de la cabeza final

Antes del merge: revisión independiente; shellcheck del CI y de los dos renders; suite completa secuencial en ambos bash con conteo esperado y saltadas clasificadas; mutaciones sin sobrevivientes; invariancia funcional Docker; nuevo check Linux en verde sobre la misma fuente. Registrar puente de hashes si solo cambian documentos después. Nunca usar un workflow verde con todos los casos saltados como evidencia.

No se exige otro DOCKER_E2E por esta feature si el diff mantiene docker/, compose y código horneado intactos. Si el alcance cambia, reabrir Constitución y aplicar el gate que corresponda. Una publicación de rama/PR, ejecución manual remota, merge o despliegue necesita su autorización existente o compuerta propia; el plan no las ejecuta.
