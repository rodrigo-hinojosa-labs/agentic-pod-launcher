# Contrato: reactivar la fase del embed en el nightly

**Feature**: 042-qmd-sqlite-vec-x64 | **Spec**: [../spec.md](../spec.md) (FR-008 a FR-011, FR-013, FR-014, SC-001, SC-004, SC-005, SC-007) | **Origen**: las cinco obligaciones de cierre del issue #107

Fija qué cambia en `.github/workflows/docker-e2e.yml`, en qué orden se corre la evidencia, cómo se mide y qué se registra. Presupone que el PR #108 (041) ya está en `main` y que esta rama se rebasó sobre él.

## 1. Cambios al workflow

Solo dos, ambos en `.github/workflows/docker-e2e.yml`, y ninguno toca el texto `run:` de los pasos que 039 congeló (los vigila un sha256, pruebas W2 y W3 de `tests/qmd-embed-nightly.bats`):

1. **El interruptor**: el valor de `QMD_EMBED_DEFECT` en el paso `fetch_models` pasa de `'#107 ...'` a `''`, y se quitan las tres líneas de comentario que explican el estado "encendido desde el 17-10-2026" (la explicación del formato se queda). La prueba W6 acepta el valor vacío o el formato registrado, así que no cambia.
2. **El tope, solo si la medición lo exige** (sección 3): `timeout-minutes` del job `e2e` (hoy 30). Va en un commit aparte para que se pueda revertir sin deshacer el interruptor.

Nada más cambia en el workflow. El script `fetch-qmd-models.sh` y el test `qmd real (041)` no se tocan salvo que la evidencia revele un defecto de arnés acotado al test (en ese caso se corrige test-first y se anota).

## 2. Orden de la evidencia

| Paso | Qué | Dónde | Compuerta |
| --- | --- | --- | --- |
| R0 | oráculo del host, humo local (amd64 y su pata arm64) y DOCKER_E2E arm64 local en verde (quickstart V1, V2, V3) | este Mac | no |
| R1 | empujar la rama; lanzar `docker-e2e` por `workflow_dispatch` con el interruptor vacío (corrida 1) | GitHub Actions, amd64 | sí: push y dispatch |
| R2 | corridas 2 y 3, con el mismo texto | GitHub Actions | sí: dispatch |
| R3 | calcular el margen de cada corrida; si el mínimo es menor de 5 minutos, subir el tope (sección 3) y volver a medir con otras 3 corridas | GitHub Actions | sí: commit, push y dispatch |
| R4 | la rotura inducida: rama de ensayo con la imagen del test sin toolchain; lanzar el workflow | GitHub Actions | sí: push de la rama de ensayo, dispatch y borrado de la rama |
| R5 | abrir el PR con la tabla de evidencia; el operador lo mergea | GitHub | sí: abrir el PR; el merge es del operador |
| R6 | las tres nocturnas siguientes al merge | GitHub Actions | no (se observan) |

Si una corrida real destapa otro defecto de producto en amd64, se detiene la secuencia y se aplica la sección 5.

## 3. Medición del tope (FR-010, SC-004)

- **Qué se mide**: la duración del job `e2e` con `started_at` y `completed_at` de la API de jobs (`gh api repos/<dueño>/<repo>/actions/runs/<id>/jobs`), no las fechas de la corrida, que incluyen la cola; y la duración de cada fase del test 041 con las marcas de tiempo del log (la de `setup` incluye la compilación de llama.cpp).
- **Cuántas**: al menos 3 corridas con el texto final; se anotan el mínimo y el máximo.
- **Regla**: margen = 30 minutos menos la duración. Si el margen mínimo es menor de 5 minutos, se sube `timeout-minutes` primero (propuesta: 45, el valor que usó la rama de ensayo de E1) en un commit aparte y se vuelve a medir con 3 corridas; no se divide el job sin evidencia de que subir el tope no basta (decisión de 041). Compartir el prefijo compilado entre `qmd real (016)` y `qmd real (041)` queda como mejora posterior medida.
- **Dato de partida** (de 041, sin la fase activa): el job rojo de E1 duró 21 min 19 s y se detuvo en `setup`; los mismos 48 e2e tardaron 11 min 45 s en una corrida y 15 min 8 s en otra. La duración con la fase completa no está medida.

Formato del registro en las Notes de `tasks.md` (una línea por corrida): identificador, rama y commit, `started_at`, `completed_at`, duración, margen, duración de `setup`, línea TAP del test 041 y el `e2e summary:`.

## 4. Rotura inducida (FR-011, SC-005)

En una rama de ensayo que no se mergea, desde la punta de la rama final, se cambia `tests/docker-e2e-qmd.bats` en lo mínimo para que la imagen del test 041 se construya con `QMD_NATIVE_TOOLCHAIN=0`: en `qmd real (041)` (línea 753 en `origin/main` `0fc08a8`), la línea 802, `(cd "$D" && docker compose build)`, pasa a llevar `--build-arg QMD_NATIVE_TOOLCHAIN=0`, como la pata RED de `qmd real (016)` (línea 728); el compose del test trae `QMD_NATIVE_TOOLCHAIN: "1"` en `modules/docker-compose.yml.tpl:26` y el flag de la línea de comandos lo anula. Resultado esperado:

- el job termina en rojo;
- el TAP trae `not ok N qmd real (041): ...` y la última marca `# qmd embed phase:` es `setup` (o `vector-extension`);
- el estado que el test vuelca al fallar da el motivo (sin toolchain no hay compilación de llama.cpp ni build musl horneada);
- los demás e2e siguen en verde.

Se anota el identificador de la corrida y se borra la rama de ensayo (con confirmación del operador).

## 5. Si aparece otro defecto de producto (FR-013)

La política de 041: se registra en un issue nuevo (con la evidencia y las obligaciones de cierre), el interruptor `QMD_EMBED_DEFECT` pasa a nombrarlo (`'#<número> <motivo en ASCII>'`), se corre la suite una vez más para ver el salto con el nuevo motivo y se avisa al operador. El arreglo de ese defecto no se mezcla con este. Los candidatos conocidos están en el research D9. Excepción: si el log del contenedor dice `musl build absent` (la build horneada no existe en la imagen amd64), no es otro defecto sino el supuesto 2 del spec, y se corrige en esta feature (el Dockerfile o `docker/scripts/build-sqlite-vec.sh`, con la revisión de privilegios del Principio II) antes de seguir con las corridas.

## 6. Cierre de #107

El cuerpo del PR lleva `Closes #107` solo si las cinco obligaciones del issue están cumplidas y registradas en las Notes: (1) el interruptor vacío en el workflow del PR, (2) la corrida con la fase activa en verde en amd64 con sus ocho marcas, (3) la duración y el margen medidos, (4) la rotura inducida en rojo con la fase nombrada y (5) los resultados registrados. Las tres noches siguientes al merge (SC-001) se registran después en un PR de documentos aparte, como en 039 y 041; si alguna fallara por la fase, el issue se reabre.
