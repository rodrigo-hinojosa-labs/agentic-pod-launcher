# Contrato: las secciones con lock sueltan `.reindex.lock` al terminar

**Archivo**: `scripts/lib/qmd_index.sh` (se hornea en la imagen: `docker/Dockerfile:265`; espejo de `setup.sh:1653-1676`)
**Funciones**: `qmd_setup_if_needed` (sección en `:474-479`) y `qmd_reindex` (sección en `:556-564`), según las líneas de `origin/main` `8cb45e4`.
**Origen**: spec FR-001 a FR-006 y FR-012; `research.md` M1 a M9 y D1. Revisado por el análisis del 07-11-2026: la primera versión usaba un `trap ... EXIT`, descartado por M8.

## C1. La forma de cada sección

Cada una de las dos secciones queda así, y solo cambia la línea marcada:

```sh
(
  if ! flock -n 9; then _qmd_log "<setup|reindex>: already running — skip"; exit 91; fi
  _qmd_<setup|reindex>_locked ...
  flock -u 9 2>/dev/null || true          # 044: nueva
) 9>"$lock" || rc=$?
```

- **I1.** El `flock -u 9` va **después** de la llamada a la función de la sección y es el último comando del subshell. Nunca va antes: la sección corre entera con el lock tomado.
- **I2.** Es el único cambio dentro del subshell, más una línea de comentario encima si hace falta. El texto del perdedor, el `exit 91`, el `|| rc=$?` y las líneas posteriores (`[ "$rc" -eq 91 ] && return 0`, `return 0`) quedan idénticos.
- **I3.** El `flock -u 9` va en la rama con `flock`. La rama sin `flock` (`:483-486` y `:568-572`) no cambia y no llama a `flock` (FR-005). La rama del perdedor tampoco lo lleva.
- **I4.** El comando nunca falla hacia afuera (`2>/dev/null || true`). Un `flock -u` que fallara no puede cambiar el código de salida del subshell ni escribir en la salida de error (Principio IV).
- **I5.** `_qmd_run`, `_qmd_ensure_prefix` y los llamadores no cambian (FR-003, FR-004). El tope, la captura de salidas, los códigos de retorno, el `LD_PRELOAD` de `embed` y el `TMPDIR` siguen siendo los de hoy. Lo verifica una comprobación estructural del diff: las líneas agregadas caen dentro de `qmd_setup_if_needed` y de `qmd_reindex`, y los cuerpos de `_qmd_run` y de `_qmd_ensure_prefix` son idénticos a los de `origin/main`.
- **I6.** No hay ningún `trap` en las secciones. Un `trap ... EXIT` se dispara también ante un SIGTERM al subshell, y soltaría el lock mientras un qmd hijo sigue trabajando (`research.md` M8).

## C2. Lo que garantiza

| Momento | Antes (medido, M1 y M8) | Después |
| --- | --- | --- |
| Mientras la sección corre | el lock está tomado | el lock está tomado (I1; lo guarda L6) |
| Al terminar la función de la sección, por su fin normal o por un `return` temprano tras un paso fallido | tomado de 0,9 a 1 s más, mientras viva el vigilante del `timeout` de BusyBox | libre: el primer `flock -n` posterior lo obtiene |
| Un perdedor que encuentra el lock tomado | se salta con rc 0 y `already running — skip` | igual; y el lock del ganador sigue tomado (L5) |
| Una señal al subshell (SIGTERM o SIGKILL) con un qmd hijo vivo | tomado mientras viva el hijo | igual (I6; M8) |
| Modo local con el `timeout` de GNU | libre al terminar (M3) | libre al terminar |
| Host sin `flock` | sección sin lock, con su línea de log | igual (I3) |

**Por qué basta con soltarlo**: el lock de `flock(2)` pertenece a la descripción de archivo abierta, y esa descripción la comparten el subshell y todos los procesos que heredaron el descriptor 9. `flock -u 9` libera el lock para la descripción entera, aunque el vigilante siga vivo con el descriptor abierto. Lo que el vigilante conserva después es un descriptor sin lock, que no estorba al próximo `flock -n`. Cuando la función de la sección vuelve, todos sus hijos ya terminaron: ninguno corre en segundo plano (M6). Lo único que queda vivo son los vigilantes.

## C3. Lo que NO cubre

- **Una sección que termina por una señal**: el `flock -u 9` no corre, y el lock se libera cuando muere el último proceso que tiene el descriptor, como hoy. Es a propósito (I6): si un qmd hijo sobrevive, el lock lo sigue protegiendo.
- **Un `exit` dentro de la sección**: hoy no hay ninguno, en ninguna de las funciones que corren bajo el lock (`_qmd_setup_locked`, `_qmd_reindex_locked`, `qmd_migrate_collection`, `_qmd_embed_until_complete`, `_qmd_pending_count`, `_qmd_run`, `_qmd_ensure_prefix` y `_qmd_swap_sqlite_vec`; leído el 07-11-2026). El `set -e` de un llamador tampoco puede producirlo, porque el subshell está a la izquierda de `|| rc=$?`. Si un cambio futuro agregara un `exit`, ese camino dejaría el lock como hoy, retenido por los vigilantes, sin empeorar nada.
- **La migración manual** (`heartbeatctl qmd-migrate`, `agentctl heartbeat qmd-migrate`), que no toma el lock: fuera de alcance (spec, Out of Scope).
- **Otros dueños legítimos del lock**: un reindex del cron o del vigilante de archivos que corre de verdad. Siguen ganando o perdiendo según la semántica de siempre.
