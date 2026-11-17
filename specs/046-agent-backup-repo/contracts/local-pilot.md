# Piloto de integración real en el M4

**Decisión del operador: 16-11-2026.** Sustituye el agente elegido para el gate previo al merge; conserva FR-022 y sus comprobaciones de respaldo/restauración. El repositorio autorizado es `rodrigo-hinojosa/agentic-046-recovery-gate`, privado y separado de la flota. Su creación no autoriza borrar el repositorio. M5 mantiene su compuerta separada por consumo de cuota.

## P1. Aislamiento y procedencia

- Workspace nuevo bajo el caché de 046, con nombre de agente propio, imagen etiquetada aparte y fuentes comparadas con el código validado de la rama. No sobreescribir `agentic-pod:latest`.
- Bind del workspace a `/workspace` y de su `.state` a `/home/agent`: ambas rutas de estado deben representar los mismos archivos.
- Proceso principal inerte bajo `tini` como PID 1, que recoge los hijos terminados; ejecuciones como `agent`, sin capacidades agregadas ni nuevos privilegios. No arrancar cron, supervisor, plugins, Claude ni canales al preparar el piloto. No conectar un bot existente ni montar el perfil o las llaves del Mac. La guarda registra PID/PPID/nombre/estado antes de validar, sin argumentos ni valores del entorno.
- Configuración y datos sintéticos: identidad, persona, vault, auto-memoria, SQLite de claude-mem, extra path y JSONL con línea completa y cola incompleta. `backup.sensitive: true` para ejercer las cuatro unidades con almacén cifrado.
- URL HTTPS de GitHub, `allow_unverified: false`, Git y age reales, askpass y librerías horneados. Sin overrides de rutas de librería, cache, motor de cifrado, reloj o destino HTTP de pruebas.
- La privada M4 permanece en el host bajo control del operador. Su pública ya comprobada se configura mediante la CLI real antes de fijar las listas de origen. `--configure-key` dispara identidad: registrar ese efecto y no repetirlo entre ciclos.

## P2. Credencial y ejecución

El operador entrega una credencial con acceso al repositorio del piloto por su Terminal o un gestor seguro, sin valores en chat, argumentos, URL o logs. Los procesos de respaldo la reciben como `GITHUB_PAT` en el entorno. No extraer ni mostrar tokens del login de gh, archivos reales de secretos o perfiles del host. La consulta autenticada normal de gh se puede usar para crear y comprobar el repositorio autorizado.

Registrar el mecanismo elegido para entregar el entorno. El piloto no acredita por sí solo la entrega de credenciales por Compose a cron. La imagen y el camino de Git/age de producción deben permanecer intactos.

## P3. Respaldo y comprobaciones

1. Registrar privacidad, propietario y todas las cabezas remotas antes de asociar; iniciar `main` con un commit de contenido de prueba.
2. Registrar el inventario cerrado del piloto y sus rutas adicionales. Revisar todos los contenidos sintéticos que viajan en claro; no confundir esa revisión con la de agentes vivos.
3. Ejecutar las cinco unidades reales. Exigir las cinco ramas, las marcas de agente/unidad correctas, el archivo cifrado de secretos en identidad, los almacenes de vault/config/memory/history y `last_result: ok`. Un retorno 0 solo no basta.
4. Sin escritores concurrentes, repetir las cinco unidades: mismas cinco cabezas remotas, nuevos intentos y `last_result: no-change`. No regenerar ni cambiar la llave o las cachés entre mediciones.
5. Comprobar clon de trabajo y ramas de trabajo intactas. Después, con una modificación controlada del historial, medir bloques reutilizados y nuevos; no atribuir reutilización incremental al solo segundo ciclo sin cambios.

## P4. Recuperación y M5

Aplicar R7 de `restore.md` contra GitHub real: lista independiente de archivos tal cual y listas de las capturas SQLite/JSONL, producidas con Python/SQLite de la imagen. Restaurar a un directorio limpio del host y exigir correspondencia completa, no solo rc 0 o mensajes de restauración. No arrancar el workspace recuperado.

El operador ejecuta age en su Terminal. La función directa de restauración se carga desde `setup.sh`, evitando el wizard, y la llave explícita se fija después de cargarlo; registrar la autenticación de Git del host. Usar un HOME temporal vacío para no recorrer llaves predeterminadas. No guardar una passphrase en argumentos o variables.

M5 requiere un caso de conversación real preparado y autorización separada antes de cualquier llamada que consuma cuota. Debe probar el historial recuperado en un perfil separado, desde `/workspace`, sin poder leer la sesión original como alternativa. Hasta obtener ese resultado no se declara SC-002 completo. Si no retoma, el operador decide la enmienda antes del merge.

Conservar workspace, repositorio y evidencia para revisión. Registrar la retirada del destino de restauración y de cualquier temporal con datos descifrados cuando termine su uso; el repositorio remoto no se elimina automáticamente.

## P5. Límites y fallas

No se certifican cron, supervisor, canal Telegram, datos reales ni inventarios de ferrari con este piloto. La evidencia del e2e existente cubre el código de arranque; la evidencia operacional de la flota sigue pendiente de FR-023, FR-026 y SC-010. Al recuperar ferrari, linus pasa primero por el inventario, revisión de archivos en claro, respaldo/restauración reales y salud del canal, con copia de imagen y archivos de sistema para reversión, antes de ampliar a donna y cbum.

Ante una falla: detener la secuencia, conservar diagnósticos y mostrar el hallazgo antes de modificar código. No proponer el merge por una prueba incompleta. Una falta de credencial, rama omitida, ausencia de datos o candado ocupado no cuenta como verde. No cambiar los registros históricos anteriores; añadir la nueva evidencia.
