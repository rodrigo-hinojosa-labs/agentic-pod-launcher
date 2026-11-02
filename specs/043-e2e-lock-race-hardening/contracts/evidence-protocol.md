# Contrato: el protocolo de evidencia

**Feature**: `043-e2e-lock-race-hardening` | **Cubre**: FR-011, SC-001 a SC-008 | **Spec**: [../spec.md](../spec.md) | **Oráculo**: [host-oracle.md](host-oracle.md)

Una carrera que ocurre una de cada cinco noches no se demuestra esperando: la prueba determinista es la inyección con el lock retenido (etapa 3); la corrida de CI valida los cuerpos nuevos en el runner real; las noches son un registro. Todo lo que sale del Mac (push, dispatch, PR) lleva COMPUERTA y la confirmación explícita del operador cada vez; las corridas locales de Docker también se confirman, porque ocupan Docker Desktop de 50 a 60 minutos.

## 1. Orden de las etapas

| Etapa | Qué | Compuerta |
| --- | --- | --- |
| 0 | línea base del host en copia aislada | no |
| 1 | pruebas del host escritas primero (ROJO visto) | no |
| 2 | ayudante y sitios (VERDE del host), mutaciones y revisión independiente | no |
| 3 | inyección de falla local, ROJO contra los cuerpos actuales y VERDE contra los nuevos | Docker local |
| 4 | DOCKER_E2E local completo del archivo de qmd y, después, el gate completo del host en los dos bash sobre el árbol final | Docker local |
| 5 | una corrida manual del workflow sobre la rama | push y dispatch |
| 6 | PR y, tras el merge, las diez noches | PR; el merge es del operador |

## 2. Etapa 0: la línea base del host

En una copia aislada de `origin/main` (no en el worktree), `bats --tap tests/` en bash 5.x y después en bash 3.2 (`PATH=/bin:$PATH` fuerza `/bin/bash` 3.2.57 en este Mac, como en 025), en secuencia y sin otra carga, unos 20 minutos por bash. Esperado: 1868 pruebas por brazo, como la CI de `cd8b74f`. Se registran las cifras, las saltadas y la duración. El esperado final es esa línea base más 26.

## 3. Etapa 3: la inyección de falla local

Es evidencia local: los scripts quedan en el scratchpad y no se versionan (decisión del operador del 31-10-2026); los resultados van al Registro de `tasks.md`.

**El retenedor** corre dentro del contenedor del test, como `agent`, lanzado con `docker exec -d` apenas el contenedor está en marcha. Espera a un archivo marcador que el propio test escribe justo antes de su reindex manual (sondeo cada 50 ms), toma entonces el lock con un `flock` bloqueante sobre `$HOME/.cache/qmd/.reindex.lock` y lo retiene H segundos. Anota el instante en que lo tomó. Medido (M2 y M12 de la investigación): ya tiene el lock en el `exec` siguiente al que crea el marcador, y un `flock` bloqueante lanzado mientras otro proceso retiene el lock se encola y lo toma al soltarse.

Una corrida es **conclusiva** solo si el retenedor tenía el lock antes del primer intento del sitio; si no, se repite. El mismo disparo se usa contra el cuerpo actual (copia de `origin/main` del archivo de pruebas) y contra el cuerpo nuevo.

| Sitio | Marcador | H | Cuerpo actual (ROJO esperado) | Cuerpo nuevo (VERDE esperado) |
| --- | --- | --- | --- | --- |
| Fase `reindex` de 041 | `gatos.md` | 20 s | cae en la fase `reindex` con `already running` en `qmd-reindex.out` y sin `qmd-index.json`, como el run 40865079036 | pasa; el TAP trae R-BUSY con el dueño |
| Fase `reindex` de 041 | `gatos.md` | 5 s | no se corre | pasa |
| Fase `reindex` de 041 (opcional) | `gatos.md` | 15 s, el borde del debounce del vigilante | no se corre | pasa; si el reindex del vigilante se adelantó y dejó `skipped` (la afirmación de efecto lo acepta), se registra. El vigilante dispara una sola vez y no reintenta, así que el resultado se decide por milisegundos y no prueba nada si no aparece |
| Prueba 13 | el contenedor creado | 20 s | aborta en la primera vuelta por `engine-calls.log` ausente (#109) | pasa |
| Prueba 13 | el contenedor creado | 5 s | no se corre | pasa |
| Fase 3 de la prueba 12 | `cron-note.md` | 20 s | cae porque `qmd-index.json` no existe | pasa |
| Fase 3 de la prueba 12 | `cron-note.md` | 5 s | no se corre | pasa |
| Vencimiento (SC-002), sobre la prueba 13 | el contenedor creado | 60 s con `QMD_E2E_REINDEX_LOCK_WAIT_S=6` | no se corre | falla a los 6 s de espera, y su reporte trae el lock, la espera de 6 s, los intentos, la salida del último y el dueño (el `sleep` del retenedor con el descriptor 9); sin error de `jq` ni de `grep` |
| Vencimiento (SC-002 y SC-008), sobre la fase `reindex` de 041 | `gatos.md` | 600 s con `QMD_E2E_REINDEX_LOCK_WAIT_S=6` | no se corre | falla a los 6 s de espera con el mismo reporte, y el estado al fallar trae el bloque del dueño del lock (el retenedor, con su pid, el descriptor 9 y su comando) y las tres primeras líneas de `qmd-setup.err` |

El vencimiento se prueba sobre la prueba 13 (con el motor falso, unos 2 minutos) y también sobre la 041 (una corrida completa de 8 a 10 minutos). El ayudante y sus reportes son los mismos, pero solo la 041 tiene `_embed_failure_state`, y esa corrida es la que ejecuta su bloque nuevo antes del merge (SC-008; decisión del operador del 31-10-2026).

Costo estimado: cuatro corridas de 041 (un ROJO, dos VERDES y el vencimiento) de 8 a 10 minutos cada una más siete corridas con el motor falso de 2 a 3 minutos (tres por cada prueba y el vencimiento de la 13), unos 50 a 60 minutos de Docker. La quinta de 041 (15 s) es opcional.

Criterios: SC-001 (cada sitio de FR-008 pasa con 5 s y 20 s y cae sin el arreglo), SC-002 (el vencimiento, en la prueba 13 y en la 041) y SC-008 (el dueño aparece con su pid y su comando, o se dice qué sonda falta, en el estado al fallar del vencimiento de la 041).

## 4. Etapa 4: DOCKER_E2E local completo

`DOCKER_E2E=1 QMD_EMBED_E2E=1 QMD_E2E_MODELS_DIR=$HOME/.cache/agentic-qmd-e2e/models-041 bats --tap tests/docker-e2e-qmd.bats` sobre el árbol final: las cinco pruebas del archivo (12, 13, 14, 15 y 16) deben dar `ok`, la 16 con sus ocho marcas en orden. Se registran la duración, lo que costó reconstruir las imágenes de prueba (T036 quitó sus etiquetas el 29-10-2026; el caché de build se conservó), el pico de memoria y, como referencia, la prueba 16 sin su fase `setup`: el umbral de SC-003 (24 s) sale de nocturnas amd64 y no hay línea base local, así que el criterio se decide en la etapa 5. Si hubo contención, el TAP trae R-BUSY con el dueño. Después, sobre el árbol final, corre el gate completo del host en los dos bash, con el esperado de la etapa 0 más 26.

## 5. Etapa 5: una corrida manual en CI (COMPUERTA)

Con la confirmación del operador: push de la rama por HTTPS con el helper de `gh`, comprobando que la cabeza del remoto es la local, y `gh workflow run docker-e2e.yml --ref 043-e2e-lock-race-hardening`. Se lee el log comprobando antes que trae `GNU bash, version`, y se registran: identificador, rama y commit, `started_at` y `completed_at` del job por la API de jobs, duración y margen frente a los 45 minutos, la línea TAP de la prueba 16 (`ok`, no saltada), `e2e summary:`, las marcas de fase y **SC-003**: la prueba 16 sin su fase `setup` no pasa de 24 s (de 16,0 a 18,5 s en las nocturnas, más 5 s). Un rojo se clasifica (arnés, producto o infraestructura) con su fragmento de log antes de seguir, como en 042. El push de una rama sin PR no dispara `test.yml` ni `shellcheck.yml`, y `docker-e2e` serializa sus corridas con su propio grupo, sin cancelación.

## 6. Etapa 6: el PR y las noches

El PR lleva la tabla de evidencia (etapas 2 a 5) y `Closes #109` y `Closes #112` solo si la evidencia respectiva está registrada; el merge es del operador. Tras el merge, las diez nocturnas siguientes se registran en un PR de documentos aparte, como hizo 042 con su T035 (SC-007): por noche, identificador, duración del job, margen, línea TAP de la prueba 16, `e2e summary:`, si apareció R-BUSY y quién tenía el lock, y la clasificación de cualquier rojo. Diez noches limpias son un registro razonable, no una demostración (spec, SC-007).

## 7. Qué etapa prueba cada criterio

| Criterio | Etapa |
| --- | --- |
| SC-001 | 3 |
| SC-002 | 3 |
| SC-003 | 5 (la 4 registra una referencia) |
| SC-004 | 1 y 2 (oráculo y mutaciones) |
| SC-005 | 0 y 4 |
| SC-006 | 4 y 5 |
| SC-007 | 6 |
| SC-008 | 3 (el vencimiento de la 041) y las pruebas O1, O2 y B4 del host |
