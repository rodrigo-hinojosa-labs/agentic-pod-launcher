# Data Model: Una noche en rojo del nightly le llega a alguien

Fase 1 de `/speckit-plan`. Esta feature no guarda datos en disco: el estado de una racha vive en el propio issue. Las entidades son tres (la corrida, el aviso y la racha) y una tabla de decisión que dice qué hace el script con cada combinación. Los campos son lógicos; el formato exacto del issue está en `contracts/notice-format.md`.

## 1. Corrida (entrada del script)

Lo que el job `alert` recibe como entorno, ya resuelto por el workflow.

| Campo | Origen | Valores y reglas |
|---|---|---|
| `EVENT` | `github.event_name` | `schedule` o `workflow_dispatch`; cualquier otro valor: sin acción |
| `TRIAL` | `inputs.alert_trial` | `true` o vacío/`false`; solo cuenta con `workflow_dispatch` |
| `RUN_RESULT` | `needs.e2e.result` | `success`, `failure`, `cancelled`, `skipped`; otro valor o vacío: sin acción, anotado |
| `FAILED_STEP` | salida `failed_step` del job `e2e` | id del primer paso con `outcome` `failure` o `cancelled`; vacío si ninguno o si `collect` no corrió |
| `SUMMARY` | salida `summary` | `total=N executed=N skipped=N failed=N`; vacío si no hubo `e2e.tap` |
| `FAILED_TESTS` | salida `failed_tests` | nombres de los tests fallidos, uno por línea, ya acotados; vacío si no hubo |
| `RUN_URL`, `RUN_ID`, `RUN_ATTEMPT` | contexto `github` | enlace, identificador y número de intento de la corrida |
| `NIGHTLY_ALERT_NOW` | solo pruebas (el workflow no la define) | segundos desde la época que el script usa como "ahora" para fechar la noche; ausente: el reloj |
| `ASSIGNEE` | `env` fijo del workflow (no es secreto) | usuario a asignar; `rodrigo-hinojosa` |
| `GH_TOKEN`, `GH_REPO` | `github.token`, `github.repository` | lo que `gh` necesita; el token nunca se imprime |

**Modo derivado**: `real` si `EVENT=schedule`; `trial` si `EVENT=workflow_dispatch` y `TRIAL=true`; en cualquier otro caso **ninguno** (corrida manual normal: no abre, actualiza ni cierra nada, FR-011).

**Clase derivada del resultado**: `green` (`success`), `red` (`failure`), `none` (`cancelled`, `skipped`, otro valor). Pendiente de la medición M7: si la plataforma reportara un tiempo agotado como `cancelled`, una regla adicional lo reclasifica como `red` (research R7) y FR-007 se enmienda con esa salvedad (tarea T082).

## 2. Aviso (el issue)

| Campo | Valor |
|---|---|
| Identidad | etiqueta `nightly-red` (modo `real`) o `nightly-red-trial` (modo `trial`) |
| Título | `docker-e2e nightly en rojo` (real) o `[ensayo] docker-e2e nightly en rojo` (trial) |
| Asignado | `ASSIGNEE`; si la asignación falla, se publica sin asignar y se anota |
| Estado de GitHub | `OPEN` o `CLOSED` |
| Marcador (primera línea del cuerpo) | `<!-- nightly-red:v1 state=open|resolved total=N first=YYYY-MM-DD -->` |
| Detalle | filas de las últimas 10 noches (fecha UTC, corrida con enlace, paso fallido), resumen de la última noche, nombres de los tests fallidos (hasta 20) |
| Comentarios | una línea por noche nueva; una línea al cerrar por verde; una línea al reabrir |

**Reglas de validación**:

- El marcador se escribe siempre desde cero con valores propios del script (números y una fecha), nunca con texto del log.
- `total` es un entero positivo; `first` es una fecha ISO en UTC.
- El cuerpo no pasa de 60.000 caracteres: si pasara, se recortan primero las filas de detalle.
- Cada nombre de test: máximo 120 caracteres, sin caracteres de control, sin comillas invertidas, con `<!--` y `-->` neutralizados, y dentro de un bloque de código cercado.
- Una fila se identifica por el id de la corrida; repetir el id no suma la noche.

## 3. Racha

La secuencia de corridas programadas consecutivas en rojo, desde la primera hasta el siguiente verde. No tiene almacenamiento propio: es el issue que lleva su marcador. Una racha tiene **como máximo un aviso abierto**; un aviso cerrado por el mecanismo (`state=resolved`) es el historial de una racha terminada, y uno cerrado a mano con `state=open` es una racha que sigue hasta que una noche verde la termina y reescribe su marcador a `resolved`.

## 4. Estados y transiciones del aviso

```text
                  rojo (no hay aviso, o el ultimo es state=resolved)
   (ninguno) ---------------------------------------------------> ABIERTO (state=open, total=1)
                                                                      |   ^
                       rojo (misma racha)                              |   |
                       total=total+1, fila nueva, comentario           v   |
                                                                  ABIERTO (total=N)
                                                                      |   |
        verde (corrida programada)                                    |   | persona lo cierra a mano
        escribe state=resolved, comenta, cierra                       |   v
                                                                      |  CERRADO (state=open)
                                                                      |   |
                                                                      |   | rojo: reabre y comenta (misma racha)
                                                                      v   |
                                                         CERRADO (state=resolved) <- historial
                                                                      |
                                       rojo: abre un aviso NUEVO (otra racha)
```

Transición que el diagrama no dibuja: desde **CERRADO (`state=open`)**, un **verde** reescribe el marcador a `state=resolved` (solo `gh issue edit`; no reabre, no comenta y no vuelve a cerrar) y lo deja como historial; así el rojo siguiente abre un aviso nuevo en vez de reabrir uno viejo (hallazgo I1 del análisis del 12-10-2026).

## 5. Tabla de decisión del subcomando `notify`

`U` es el aviso más reciente con la etiqueta de la identidad, de cualquier estado (o "ninguno").

| Modo | Clase | `U` | Acción | Cubre |
|---|---|---|---|---|
| ninguno (manual normal) | cualquiera | cualquiera | ninguna; anota el motivo | FR-011 |
| real o trial | `none` | cualquiera | ninguna; anota `RUN_RESULT` | FR-007 |
| real o trial | `red` | ninguno | crea etiqueta si falta; crea el aviso (asignado) | FR-001, FR-002, FR-019 |
| real o trial | `red` | abierto | si la fila de esta corrida ya está: nada; si no: suma la noche, reescribe el cuerpo, comenta | FR-005 |
| real o trial | `red` | cerrado, `state=open` | reabre con comentario y suma la noche | FR-008 |
| real o trial | `red` | cerrado, `state=resolved` | crea un aviso nuevo (otra racha); el anterior no se toca | FR-008 |
| real o trial | `green` | abierto | escribe `state=resolved`, comenta con el enlace de la corrida verde y cierra con razón `completed` | FR-006 |
| real o trial | `green` | ninguno, o cerrado con `state=resolved` | ninguna | FR-006 |
| real o trial | `green` | cerrado, `state=open` (cerrado a mano) | reescribe el marcador a `state=resolved` con `gh issue edit`; no reabre, no comenta y no cierra | FR-008 |
| cualquiera | cualquiera | (falla una llamada a `gh`) | anota `::warning::` y sigue; el script sale con 0 | FR-009 |

El modo `trial` usa su propia etiqueta y su propio título, de modo que un ensayo jamás lee ni modifica el aviso real, y viceversa.
