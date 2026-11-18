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
- Integración Linux real sobre `8bc7baa`: L01–L10 completos, 14 probes como UID1001,
  variantes requeridas y limpieza confirmada; job de 47 s, margen de 9 min 13 s.
  [Reporte de la integración](https://github.com/rodrigo-hinojosa-labs/agentic-pod-launcher/actions/runs/44304997727/artifacts/14426728576).
- BATS Ubuntu de `8bc7baa`: plan 2.196, cero fallas y 64 saltadas anteriores; bash 5.3.9,
  BATS 1.11.0 y yq 4.44.3. [Job Ubuntu](https://github.com/rodrigo-hinojosa-labs/agentic-pod-launcher/actions/runs/44304997727/job/134804138845).
- macOS de `8bc7baa`: el primer intento no obtuvo runner; el segundo llegó a 1.872/2.196
  resultados, sin aserciones fallidas entre los terminados, al agotarse los 45 min del job.
  Los 92 casos nuevos de 047 habían terminado sin skip ni fallo; quedaron 324 sin resultado final.
- Ajuste medido de CI: presupuesto exterior compartido BATS de 45 a 60 min, con RED/GREEN
  de la guarda y 16/16 oráculos en ambos bash. No cambia runners, pruebas, permisos ni los
  límites de 25/30/60 s del healthcheck; Linux conserva 10 min. La CI de la cabeza propuesta
  debe concluir completa antes de quitar el borrador. Sin despliegue ni llamadas al modelo.

Dos controles anteriores fallaron aisladamente en N05/N13 sin causa confirmada. El Registro
conserva los fallos y los intentos instrumentados; no se relajaron expectativas ni topes.
Se calibraron por RED/GREEN el reloj monotónico del doble y la identidad del intérprete,
sin atribuirles retrospectivamente la causa de esos dos incidentes.

Evidencia, fuentes exactas y pendientes: [Registro de 047](https://github.com/rodrigo-hinojosa-labs/agentic-pod-launcher/blob/047-local-healthcheck/specs/047-local-healthcheck/tasks.md).

Closes #111
