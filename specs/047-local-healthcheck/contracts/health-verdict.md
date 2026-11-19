# Contrato: observación y veredicto del healthcheck

**Date**: 2026-11-17
**Requirements**: FR-001 a FR-010, FR-019 a FR-023; SC-001 a SC-004, SC-007 a SC-009.

## H1. Superficie pública y empaquetado

El comando sigue siendo `scripts/local/agent-healthcheck.sh`, sin nuevas opciones de operador. Conserva una línea final de stdout:

```text
agent-<name> healthcheck: OK|WARN|DEGRADED (motivos si existen)
```

Retornos: 0=OK, 1=WARN, 2=DEGRADED. Se evalúan todos los componentes y gana el nivel más grave; una falla de entrega no cambia ese nivel. El diagnóstico de avisos va a stderr con un código cerrado, sin respuesta cruda o credenciales.

`modules/local-healthcheck-lib.sh.tpl` genera una biblioteca vecina `scripts/local/agent-healthcheck-lib.sh`, solo en modo local. Contiene definiciones sin I/O al sourcear. El CLI verifica su existencia y la de env_file.sh antes de sourcear; ausencia => WARN por componente faltante, sin el aborto de source en bash 3.2. No se añade EnvironmentFile al servicio de healthcheck ni se modifica su User, ExecStart, SuccessExitStatus o timer.

El flujo del CLI determina si la entrega está configurada. Sin configuración observa salud y no crea estado de avisos. Con configuración intenta la transacción del [contrato de avisos](notice-state.md); si no puede tomarla, observa salud por separado y no envía. Una transacción adquirida realiza su propia observación bajo lock, sin usar un snapshot que esperó fuera de él.

## H2. Login: snapshot de la forma observada

Una lectura de `.claudeAiOauth` con jq. No se recorre recursivamente el JSON; mcpOAuth no participa. Solo se devuelve una clasificación y números/indicadores no secretos.

Orden de clasificación:

1. Archivo ausente/ilegible/no regular, JSON inválido, raíz ausente/no objeto o jq ausente: incomplete, WARN.
2. Campos accessToken y refreshToken presentes, ambos strings vacíos, y expiresAt presente como número 0: login_lost, DEGRADED. Es la forma documentada en #111; no se extrapola desde un único campo ausente.
3. Para acreditar forma renovable: ambos tokens strings no vacíos y ambas fechas expiresAt/refreshTokenExpiresAt como enteros positivos <=9007199254740991. Cualquier forma distinta es incomplete, WARN.
4. Con forma completa, refreshTokenExpiresAt <= now_ms: renewal_expired, DEGRADED, aunque el acceso siga vigente; el texto no afirma que ya cayó la sesión.
5. Con renovación futura, 0 < restante <=604800000 ms: renewal_expiring, WARN. Por encima: renewable, sin democión.

expiresAt pasado con renovación válida no añade DEGRADED ni WARN de vencimiento. No se supone una vida de ocho horas; esa fue una medición histórica. Fechas en segundos, strings, booleanos, fracciones, null y valores extremos no se convierten o corrigen por intuición. La fecha de otra raíz no reemplaza una que falta.

El motivo visible es un mensaje del catálogo: `login unavailable (tokens cleared)`, `login renewal expired`, `login renewal expiring in <duration>` o `cannot verify login renewal (<cause>)`. El tiempo restante se redondea hacia arriba en días para >=24 h y en horas para <24 h, usando `<1h` por debajo de una hora. No se registran tokens ni JSON original.

## H3. Journal: catálogo finito, por línea

Captura con ventana de diez minutos y límite de 2000 líneas, en temporal privado. Se comprueba rc; vacío con rc0 no es un error, falla de lectura sí es WARN. El temporal nunca se publica y se limpia al terminar.

| Señal observada | Efecto |
| --- | --- |
| `Please run /login` o `You must be logged in to use Remote Control` | DEGRADED terminal, aun con fechas futuras |
| `Authentication failed (401): OAuth access token has expired` sin terminal adicional en ese evento | No acredita pérdida; conservar resultado local renewable/expiring o WARN incomplete |
| `API Error: 401`, `Authentication failed (401)` u otro 401 de refresh no encajado en la excepción conocida | DEGRADED por error de autenticación no clasificado; no afirmar revocación ni fecha vencida |
| `Failed to refresh session` sin rechazo terminal/401 | WARN por refresh no verificado; no afirmar login perdido |
| Sin señales / journal vacío | No añade motivo |
| journalctl ausente, fallo o deadline | WARN por verificación incompleta |

La excepción es por evento, nunca global. Una línea renovable no borra un terminal o 401 desconocido en otra línea, cualquiera sea el orden. Se permite ampliar el catálogo solo con evidencia y casos de prueba, no con un grep de cualquier palabra “refresh”.

No transportar payload grande por argv ni variables exportadas. El clasificador recibe el archivo de captura y lo consume completo dentro del presupuesto; no usar productor→grep -q o head. La prueba SIGPIPE conserva la ejecución real del clasificador con datos mayores de 64 KiB, por archivo.

## H4. Unidad, pertenencia y sockets

1. Leer ActiveState, ControlGroup, InvocationID y MainPID mediante systemctl show, parseando claves sin source/eval.
2. Una unidad inactiva produce DEGRADED. Si se desconoce su estado, WARN; no afirmar conexión sana por un PID suelto.
3. ControlGroup debe ser una ruta válida no vacía y distinta de `/`, bajo la jerarquía cgroup v2 conocida. No recorrer toda la máquina ante un dato inválido.
4. Enumerar los cgroup.procs del grupo y sus subgrupos. La pertenencia real se revalida: igualdad de ruta o prefijo literal terminado en `/`; no basta la lista de candidatos. Registrar las identidades PID+starttime obtenidas desde cada directorio proc fijado; starttime sirve para comparar enumeraciones, no reemplaza el handle para atribuir sockets.
5. Por candidato, fijar cwd en `/proc/PID` antes de consultar sockets. Leer cgroup y enlaces fd relativos a ese directorio. Nunca reabrir el proceso mediante su ruta numérica absoluta después de fijarlo.
6. Intersectar los inodes de esos FDs con los obtenidos por `ss -H -t -n -e state established '( dport = :443 )'`. Solo el puerto remoto 443 exacto; listener, puerto local 443 y remoto 4430 no bastan. Cada token ino:N se compara como entero completo, no como prefijo.
7. Revalidar el FD, su pertenencia y la identidad ActiveState/ControlGroup/InvocationID de la unidad antes de aceptar el resultado. Antes de concluir absent, enumerar de nuevo todo el árbol y comparar identidades PID+starttime con el inventario recorrido: un hijo nuevo puede aparecer sin cambiar InvocationID. Esa segunda enumeración fija sus propios directorios proc; no reutiliza por ruta numérica un handle anterior. Se permite una repetición dentro del presupuesto si cambia la unidad o el inventario; la segunda inestabilidad es unknown.

`present`: evidencia positiva de un proceso válido. `absent`: exploración completa sin esa evidencia y con inventarios inicial/final coincidentes. `unknown`: lectura/permisos/herramienta/identidad/deadline insuficiente. Un positivo válido basta aunque otro candidato desaparezca; sin positivo, un recorrido incompleto nunca se llama absent ni OK. La estabilidad entre dos muestras no promete un snapshot atómico del kernel ni detectar un proceso que nació y terminó entre ambas.

Límite defensivo: 1024 candidatos; excederlo produce unknown explícito, no truncamiento silencioso. Una jerarquía cgroup no soportada también queda unknown. No agregar privilegios para leer proc ni inspeccionar entornos, cmdline o contenido de FDs. La señal acredita una conexión TCP al puerto convencional, no TLS, identidad del relay o conversación de extremo a extremo.

## H5. Presupuestos y comprobaciones conservadas

El CLI fija una vez `global_deadline=t0+60 s` con tiempo monotónico desde su entrada, antes de leer configuración de avisos. Ese plazo incluye configuración, toma de lock, observación, adopción de estado, reserva, red, commit final, recolección de hijos, cleanup y diagnóstico. El caso sin configuración de avisos también conserva ese límite.

Al iniciar la observación se fija una vez `observation_deadline=min(observation_start+25 s,global_deadline)`. Repetir una muestra por cambio de unidad/inventario no renueva ese plazo. Al terminar la observación se fija una vez `notice_deadline=min(observation_end+30 s,global_deadline)` para adopción, reserva, red y confirmación. Sin fase de avisos no se crea otro presupuesto. El origen de la fase de avisos es el fin de la observación, aunque hc_notice_run haya tomado el lock antes.

Cada operación usa el menor entre su tope propio y el tiempo restante de sus fases/global. systemctl/journalctl tienen tope de 4 s; ss, 3 s. Lectura/validación del login comparte el plazo de observación. Los topes externos incluyen margen TERM/KILL y recolección; no se agrega ese margen al vencer un deadline. No iniciar llamadas sin tiempo disponible ni dejar hijos trabajando después de liberar la transacción. Al agotarse, las comprobaciones inconclusas añaden WARN; las conclusiones DEGRADED ya obtenidas prevalecen. El objetivo global se valida en N31 con reloj monotónico controlado y fallas acotables de procesos de usuario; no promete terminar un kernel o almacenamiento bloqueado fuera de ese control.

La revisión de QMD-watch y wiki-graph conserva sus semánticas previas: failed añade WARN, una unidad ausente no falla la evaluación. No se cambian estas unidades ni su comportamiento. No se ejecutan sudo, login, modelo, reparaciones o mutaciones de servicios.

## H6. Interfaces internas de biblioteca

Contratos de funciones, no implementación completa:

| Función prevista | Entrada | Salida |
| --- | --- | --- |
| `hc_auth_snapshot` | ruta del archivo, now_ms | JSON de clase/cause/TTL, sin tokens |
| `hc_journal_snapshot` | unidad, clase auth, temporal, deadline | clase de journal y reason_codes |
| `hc_connection_snapshot` | unidad, raíces proc/cgroup, deadline | present/absent/unknown y cause |
| `hc_observe` | workspace, unidad, tiempo, deadline | snapshot agregado del modelo |
| `hc_notice_reduce` | estado + snapshot + now_s por stdin | estado siguiente y decisión de intento |
| `hc_state_commit` | ruta de estado, deadline; JSON por stdin | éxito solo tras flush de archivo y directorio |
| `hc_notice_run` | workspace, unidad, global_deadline absoluto monotónico fijado por el CLI | snapshot de salud; deriva plazos de observación y avisos según H5, sin reiniciar el global |

Las raíces y tiempos explícitos permiten probar fixtures sin nuevas perillas productivas. El CLI usa las rutas reales y reloj del host. El helper no contiene dispatch de servicios al sourcearse.
