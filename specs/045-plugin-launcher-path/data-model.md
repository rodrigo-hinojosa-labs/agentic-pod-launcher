# Data Model: Los hooks de claude-mem 15.x encuentran su lanzador en los agentes docker

**Feature**: `045-plugin-launcher-path` | **Fecha**: 2026-11-11

La feature no agrega ni cambia datos persistentes: ni `agent.yml`, ni plantillas, ni archivos derivados, ni nada bajo `.state/` (Principios I y V). Lo que modela es entorno de proceso. Este documento fija las entidades y las reglas que las pruebas verifican.

## Entidades

### Directorio de binarios del usuario agente

| Campo | Valor |
| --- | --- |
| Ruta | `$HOME/.local/bin`; en el contenedor, `/home/agent/.local/bin` |
| Dueño | `agent` (vive en el bind-mount `.state/`, sobrevive a los rebuilds) |
| Quién escribe ahí | plugins como claude-mem 15.x (`ensure-launcher.cjs`); antes de 036, uv |
| Quién lo limpia | `mcp_warm_prune_stale_links`, solo los enlaces colgantes que apuntan a `/opt/uv/tools` (sin cambios) |
| Existencia | puede no existir al arrancar; la crea el plugin durante la sesión |

### PATH compuesto

El valor que `agent_path_compose` devuelve para un contexto del agente (contrato C1).

| Entrada | Regla | Salida |
| --- | --- | --- |
| UID 0, `00`, vacío o no decimal | root nunca recibe el directorio, y un UID que no se puede leer cuenta como root (falla cerrada) | PATH sin cambios |
| `HOME` vacío, `/`, relativo, con barra final, o con `:` o salto de línea | no se puede formar un directorio confiable | PATH sin cambios |
| PATH vacío | no se crea un PATH que tenga solo el directorio del usuario | PATH sin cambios (vacío) |
| PATH que ya contiene el directorio como elemento entero, en cualquier posición | idempotencia (un directorio parecido no cuenta) | PATH sin cambios |
| cualquier otro caso | se agrega al final | `PATH:$HOME/.local/bin` |

Invariantes:

- Si la función agrega el directorio, queda como **último** elemento del resultado (FR-003). Si el PATH de entrada ya lo traía en otra posición (por ejemplo, desde un entorno heredado), la función no lo mueve: FR-003 se garantiza para lo que agrega la función, no para lo que ya venía.
- El resultado empieza con el PATH de entrada, sin cambios. Ningún directorio de la imagen se mueve ni se quita.
- La función no exporta nada, no lee el sistema de archivos y sale con 0.

### Contexto de ejecución

Cada proceso en que el producto crea una sesión de `claude`, y cómo recibe el PATH compuesto (D1).

| Contexto | Quién crea la sesión | Cómo recibe el PATH | Requisito |
| --- | --- | --- | --- |
| Sesión interactiva (los tres casos de `next_tmux_cmd`) | `start_session` en `start_services.sh`, como `agent` | un prefijo `PATH=... tmux new-session` (el pane toma el PATH del cliente que lo crea; `-e PATH=` se ignora, `research.md` M10) | FR-002 |
| Respawn del watchdog | la misma `start_session` | el mismo prefijo | FR-002 |
| Tick del heartbeat (hoy sin plugins; se cubre por consistencia, `research.md` M9) | `heartbeat.sh`, job de `crond` como `agent` | un prefijo `PATH=... tmux new-session` | FR-002 |
| `agentctl mcp` | `docker exec -u agent` desde el host | `sh -c` que carga la librería en el contenedor | FR-002 (D3) |
| `agentctl shell` y un `docker exec -u agent` manual | el operador | PATH de la imagen, sin cambios (documentado) | FR-002, cláusula del exec manual |

### Proceso root del contenedor

| Proceso | PATH | Requisito |
| --- | --- | --- |
| `tini` (PID 1) y el entrypoint antes del `exec su-exec` | el de la imagen | FR-004 |
| el bucle de sincronización del crontab (subshell del entrypoint) | el de la imagen | FR-004 |
| `crond` | el de la imagen; sus jobs lo heredan (`research.md` M1) | FR-004 |
| `docker exec -u root` | el `ENV` de la imagen, que no cambia | FR-004 |

Cómo se verifica: el e2e lee con `docker inspect` el entorno que Docker entrega al contenedor, del que heredan todos estos procesos, y la guardia G1 comprueba en el código que el entrypoint no cambia el PATH. Ninguna prueba entra al contenedor como root.

## Transiciones

No hay estado persistente. El único ciclo es el de una sesión:

1. `start_session` (o el heartbeat) calcula el PATH compuesto a partir de su propio PATH.
2. Crea la sesión tmux con ese PATH. El proceso creador conserva su PATH original.
3. Dentro de la sesión, `claude` lanza los hooks de los plugins. Cada hook en forma exec resuelve su ejecutable con ese PATH en el momento de ejecutarse, así que un lanzador que el plugin instala a mitad de sesión se encuentra en los hooks siguientes.
4. Cuando la sesión muere, el respawn vuelve al paso 1.

Si la librería no está, el paso 1 devuelve el PATH original (D4). La sesión se crea como antes de 045 y el arranque deja una línea en el log.
