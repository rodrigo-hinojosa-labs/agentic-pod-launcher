Un agente local sano podía avisar pérdida de login al vencer un token de acceso renovable,
ignorar la conexión de un descendiente o repetir avisos cada tick. El healthcheck ahora
evalúa el perfil de renovación correcto, advierte a siete días y atribuye sockets a la
unidad mediante cgroup/proc/inodes. Los avisos opcionales siguen transiciones con estado
durable y reintentos pendientes cada treinta minutos.

Conserva códigos 0/1/2, unidad/timer y runtime Docker. La observación tiene hasta 25 s,
los avisos hasta 30 s después de observar y la invocación hasta 60 s. El presupuesto
exterior de BATS en CI pasa a 60 min: macOS necesitó 54 min 03 s; los límites del producto
y de cada prueba no cambian. VERSION 0.32.0 → 0.33.0.

Validación acreditada sobre `17fcd6b`, con producto idéntico al del gate host:

- Host: plan 2.196 por bash 5.3.15/3.2.57, cero fallas y stderr vacío; 69/70 saltadas
  idénticas a la base. Control focal 121/121 y 48 variantes de mutación detectadas en
  ambos bash. El ajuste posterior de CI tiene RED/GREEN y 16/16 oráculos por bash.
- CI Ubuntu: plan 2.196, 2.132 ejecutados, 64 saltadas, cero fallas; 23 min 16 s.
- CI macOS: plan 2.196, 2.124 ejecutados, 72 saltadas, cero fallas; 54 min 03 s y
  margen de 5 min 57 s. Los 92 casos nuevos se ejecutaron sin saltos en ambos brazos.
- Linux real: L01–L10 completos, 14 probes como UID1001, variantes requeridas y
  limpieza confirmada; job de 24 s, margen de 9 min 36 s.
  [Reporte Linux](https://github.com/rodrigo-hinojosa-labs/agentic-pod-launcher/actions/runs/44318397218/artifacts/14432498491).
- Shellcheck, renders e invariantes de unidad/timer y Docker conformes.

TCP es una señal de conexión, no una prueba de respuesta del modelo. Perder ACK o
persistencia tras aceptación puede duplicar un aviso al reintentar; una falla de envío
conserva la salud. Dos controles aislados anteriores N05/N13 no se reprodujeron y su
causa sigue sin confirmar: el Registro conserva los fallos y diagnósticos.

La cabeza con la que se propone mergear debe tener sus cuatro checks verdes; los
commits posteriores de registro mantienen la fuente de producto y se verifican también
en CI. Sin despliegue de flota ni llamadas al modelo.

Evidencia, fuentes exactas y pendientes: [Registro de 047](https://github.com/rodrigo-hinojosa-labs/agentic-pod-launcher/blob/047-local-healthcheck/specs/047-local-healthcheck/tasks.md).

Closes #111
