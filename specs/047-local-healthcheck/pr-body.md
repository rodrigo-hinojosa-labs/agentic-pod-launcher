Un agente local sano podía avisar pérdida de login por el vencimiento renovable del token
de acceso, perder la conexión de un descendiente o repetir el mismo aviso cada tick.
El healthcheck ahora verifica la renovación desde el perfil correcto, advierte a siete
días y atribuye sockets a la unidad mediante cgroup/proc/inodes. Los avisos opcionales
siguen transiciones con estado durable y reintentos pendientes cada treinta minutos.

Conserva los códigos 0/1/2, la unidad/timer y el runtime Docker. La observación tiene hasta 25 s,
los avisos hasta 30 s después de observar y la invocación hasta 60 s totales. Fallar al enviar
no altera la salud; perder ACK o persistencia después de aceptación puede duplicar un
mensaje al reintentar. VERSION 0.32.0 → 0.33.0. El healthcheck no opera el login ni servicios.

Validación:

- Focales: 121/121 en bash 5.3.15 y 3.2.57 con SIGPIPE ignorada, stderr vacío y limpieza confirmada.
- Mutaciones: 48 variantes en ambos bash, 96/96 detectadas y válidas; cero sobrevivientes.
- Renders local/Docker, invariantes de unidad/timer y shellcheck acreditados. Los ignores
  nuevos se limitan al tooling que no copia el scaffold.
- Gate host completo: 2.196/2.196 en bash 5.3.15 (32 min 38 s) y 3.2.57 (31 min 49 s),
  secuenciales, cero fallas y stderr vacío. Incluye 69/70 saltadas idénticas a la base;
  ejecutados 2.127/2.126 casos. Fuente y limpieza confirmadas.
- Pendiente antes del merge: CI de esta cabeza, incluidos L01–L10 sobre Linux real con datos
  ficticios y limpieza confirmada. El receptor HTTP del M4 y los oráculos sintéticos no
  sustituyen ese gate. Sin despliegue de flota ni llamadas al modelo.

Dos controles anteriores fallaron aisladamente en N05/N13 sin causa confirmada. El Registro
conserva los fallos y los intentos instrumentados; no se relajaron expectativas ni topes.
Se calibraron por RED/GREEN el reloj monotónico del doble y la identidad del intérprete,
sin atribuirles retrospectivamente la causa de esos dos incidentes.

Evidencia, fuentes exactas y pendientes: [Registro de 047](https://github.com/rodrigo-hinojosa-labs/agentic-pod-launcher/blob/047-local-healthcheck/specs/047-local-healthcheck/tasks.md).

Closes #111
