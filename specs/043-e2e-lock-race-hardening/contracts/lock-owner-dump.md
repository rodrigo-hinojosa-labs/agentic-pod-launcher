# Contrato: el dueño del lock en la primera contención y en el estado al fallar

**Feature**: `043-e2e-lock-race-hardening` | **Cubre**: FR-009, FR-004 (reporte), SC-008 | **Spec**: [../spec.md](../spec.md) | **Datos**: [../data-model.md](../data-model.md)

## 1. La sonda

`qmd_e2e_lock_owners EXEC_FN` ejecuta, a través del exec del sitio (siempre `-u agent`, principio II), un script de POSIX sh guardado en la variable `QMD_E2E_LOCK_OWNERS_SH` del ayudante. El estado al fallar de la prueba 041 usa esa misma variable, de modo que hay una sola copia del script.

Qué hace el script, en orden:

1. El archivo del lock es `${QMD_CACHE_HOME:-$HOME/.cache/qmd}/.reindex.lock`.
2. Si `/proc` no es un directorio, imprime `no /proc here` y termina.
3. Si el archivo no existe, imprime `lock file absent (RUTA)` y termina.
4. Recorre `/proc/<pid>/fd/*`; por cada descriptor cuyo `readlink` es la ruta del lock, imprime `pid N fd K cmd=[CMDLINE]`, con el `cmdline` del proceso (los NUL y los saltos de línea cambiados por espacios) acortado a 120 caracteres. Los saltos de línea se agregaron el 01-11-2026: en la primera corrida de inyección de T035 con el cuerpo nuevo, el `sh -c` del retenedor llevaba un script de varias líneas, y como `cut` corta por línea, el reporte imprimió el script entero (20 renglones). Ahora O1 lo fija con un retenedor cuya línea de comando trae un salto, y M92 lo pone a prueba en la pata Linux. Los procesos que no puede leer se saltan en silencio: los de root, que dan `Permission denied` como usuario `agent` (medido), y uno que termina entre el hallazgo de su descriptor y la lectura de su `cmdline` (la revisión de T033, H6).
5. Si no encontró ninguno, imprime `none found`.
6. Como mucho 10 líneas, y estado de salida 0 siempre.

Lo que **no** hace: no toma el lock, no prueba con `flock -n` (tomarlo un instante podría hacer perder la carrera a otro proceso, incluido el reindex del vigilante), no escribe ningún archivo y no depende de `lsof` ni de `fuser`. Está medido que el escaneo nombra a un retenedor y también a un descendiente huérfano que heredó el descriptor 9 (M2 de la investigación).

| Caso | Línea de salida |
| --- | --- |
| uno o más retenedores | `pid N fd K cmd=[COMANDO]`, una línea por descriptor, aunque el comando traiga saltos de línea |
| ninguno | `none found` |
| el archivo del lock no existe | `lock file absent (RUTA)` |
| no hay `/proc` (macOS) | `no /proc here` |

## 2. Los tres momentos

| Momento | Quién la llama | Dónde sale |
| --- | --- | --- |
| La primera contención de cada espera | `qmd_e2e_reindex_wait` | R-BUSY, como comentario TAP: una corrida verde que tuvo contención deja escrito quién la causó |
| El vencimiento del plazo | `qmd_e2e_reindex_wait` | dentro de R-EXPIRED |
| Una falla de `qmd real (041)` | `_embed_failure_state`, desde `teardown` | un bloque propio del estado al fallar |

Los dos primeros son tolerantes por construcción (la sonda no cambia el retorno del ayudante, regla I7 de `reindex-wait.md`). El tercero lo es por la regla de `_embed_failure_state`: cada sonda termina en `|| true`. Antes del merge, el tercer momento corre en un contenedor en una sola corrida: la fila del vencimiento de la fase 041 en la inyección (`evidence-protocol.md` sección 3, SC-008).

## 3. Cambios a `_embed_failure_state` (`tests/docker-e2e-qmd.bats:64-73`)

El encabezado `# --- state at the failure: disk, container verdict, vector extension ---` no cambia ni de texto ni de lugar: la checklist de upgrade lo cita y G3 de `tests/qmd-embed-nightly.bats` lo guarda. Se agregan, después de la sonda de contenedor que ya existe:

1. Una línea de encabezado propia por fd 3: `# --- reindex lock owners (who has .reindex.lock open: pid, fd and command) ---`.
2. La sonda del dueño, ejecutada con `docker compose exec -T -u agent qmd-embed sh -c "$QMD_E2E_LOCK_OWNERS_SH"`, con los dos flujos juntos, cada línea con el prefijo de una almohadilla y un espacio, y toda la sonda protegida por `|| true`.
3. Dentro de la orden en contenedor que ya existe, una sección `--- qmd-setup.err (first 3 lines)` con `head -n 3 "$HOME/.cache/qmd/tmp/qmd-setup.err" 2>&1` (la ruta sale de `scratch_dir`, `scripts/lib/rag_obs.sh:30-38`). La primera línea del reemplazo de sqlite-vec de 042 queda al comienzo de ese archivo y la cola de 500 bytes que llega al log del contenedor la empuja fuera, así que el volcado de las tres primeras es lo que la muestra.

Sin cambios: `teardown` llama a `_embed_failure_state` una sola vez y antes de `docker compose down` (P2 lo guarda), y cada sonda existente conserva su `|| true`.

## 4. Límites declarados

- La sonda ve los procesos del mismo usuario (`agent`). Un retenedor de root no aparecería; ninguno se espera, porque el producto corre como `agent`.
- Un retenedor que ya terminó cuando se corre la sonda no aparece: por eso la primera contención escribe R-BUSY de inmediato, que es la mejor oportunidad de nombrarlo.
- En macOS no hay `/proc`: la sonda lo dice y las pruebas del host que necesitan un retenedor real se saltan allí con su motivo.
