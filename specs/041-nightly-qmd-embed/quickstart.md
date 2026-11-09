# Quickstart: validar que el nightly ejercita el embed real de qmd

**Feature**: `041-nightly-qmd-embed` | Contratos: [fetch-models-script](contracts/fetch-models-script.md), [workflow-delta](contracts/workflow-delta.md), [embed-test](contracts/embed-test.md), [host-oracle](contracts/host-oracle.md)

Cada sección dice qué criterio de éxito valida. Las marcadas «compuerta» no se ejecutan sin la confirmación explícita del operador.

## 1. Prerrequisitos

- Host: `bats` (CI 1.11.0, local 1.13.0), `yq` v4, `jq`, `curl`, `python3`, y `sha256sum` o `shasum`. Para el gate dual, `/bin/bash` 3.2.57 en macOS.
- Solo para DOCKER_E2E: Docker con Compose, red y unos 6 GB libres (imagen con toolchain, compilación de llama.cpp y 1,6 GB de modelos).

## 2. Oráculos del host (SC-003, SC-004, SC-005 en su parte de host, SC-009)

```bash
bats tests/qmd-embed-nightly.bats                     # bash 5.x (Homebrew)
PATH=/bin:$PATH bats tests/qmd-embed-nightly.bats     # bash 3.2.57
bats tests/ci-workflows.bats                          # 039: debe seguir en 14 de 14 sin editarse
```

- Esperado: los 36 tests de [host-oracle](contracts/host-oracle.md) en verde en los dos bash, y los 14 de 039 en verde.
- Gate completo, **secuencial y nunca concurrente**: `bats tests/` en bash 5.x y después en 3.2. El esperado es la línea base, medida en una copia aislada de `main` al empezar la implementación, más 37: los 36 del oráculo y el test e2e `qmd real (041)`, que sin `DOCKER_E2E` sale saltado y también se cuenta. Si 041 se rebasa sobre 040, la línea base se vuelve a medir sobre el `main` rebasado (tasks T037). Todo rojo de contención se vuelve a medir en aislamiento antes de nombrarlo.
- Paridad con la CI: repetir los tests W con el yq v4.44.3 que instala el workflow, porque el formato de extracción de `yq` es parte del sha256 de research M13. El binario se baja de la release oficial y se verifica su checksum; bajarlo y ejecutarlo pide el visto bueno del operador.
- Como en el runner: la CI de `tests` (`test.yml`) solo corre en PR y en `main`, así que el oráculo verá el runner real recién en el PR. Antes, se corre con la SIGPIPE ignorada, como la entrega el runner (gotcha de `CLAUDE.md`):

  ```bash
  perl -e '$SIG{PIPE}="IGNORE"; exec @ARGV' bats tests/qmd-embed-nightly.bats
  PATH=/bin:$PATH perl -e '$SIG{PIPE}="IGNORE"; exec @ARGV' bats tests/qmd-embed-nightly.bats
  ```

## 3. Mutaciones (FR-017)

Cada mutación se aplica sobre una copia o se revierte después. El test indicado debe pasar a rojo en bash 5.x y en 3.2. En esta tabla `M<n>` es una mutación; las mediciones de [research.md](research.md) se citan siempre como «research M<n>».

| M | Mutación | Cae |
| --- | --- | --- |
| M1 | quitar `QMD_EMBED_E2E: '1'` del `env` de la suite | W4 |
| M2 | borrar el `if:` del paso de la suite | W5 |
| M3 | mover `Fetch the qmd models` después de la suite | W1 |
| M4 | editar un comentario dentro del `run:` de la suite | W3 |
| M5 | quitar `id: verify_deps` | W2 |
| M6 | definir `QMD_MODELS_BASE_URL` en el `env` del paso de obtención | W7 |
| M7 | `QMD_EMBED_DEFECT: 'apagado'`, sin issue, en el workflow | W6 |
| M8 | dejar en 1 el valor por defecto de `QMD_FETCH_ATTEMPTS` | F2 |
| M9 | salir con 0 tras la falla persistente | F3 |
| M10 | no verificar el tamaño | F4 |
| M11 | no verificar el sha256 | F5 |
| M12 | descargar igual con el interruptor de defecto activo | F6 |
| M13 | aceptar cualquier `QMD_MODELS_BASE_URL` | F8 |
| M14 | aceptar la tabla alternativa con la base real | F9 |
| M15 | `--max-time` fijo en 300 s, sin descontar el presupuesto | F10 |
| M16 | quitar `--proto =https` | F13 |
| M17 | escribir las dos claves en `$GITHUB_ENV` en la falla | F3 |
| M18 | imprimir una línea con un carácter no ASCII | el test F del camino que la imprime (lo afirma `_run_fetch`) |
| M19 | que `vec0-libc.sh` vuelva a mirar solo `linux-arm64` | V2 |
| M20 | que `vec0-libc.sh` imprima `MUSL` cuando no hay archivo | V4 |
| M21 | evaluar la puerta del test 041 después de `docker compose build` | K1 (el log de los stubs ya no está vacío) |
| M22 | ignorar `QMD_EMBED_SKIP_REASON` en el test 041 | K2 |
| M23 | hacer `skip` en vez de fallar con la puerta abierta y sin modelos | K3 |
| M24 | dejar el bloque del Tier 2 dentro del test 016 | K4 |
| M25 | `QMD_MODELS_QMD_VERSION=2.6.0` | G1 |
| M26 | quitar el prefijo `hf_tobil_` del `local_name` del modelo de expansión | G2 |
| M27 | quitar la marca `_embed_phase reindex` | P1 |
| M28 | dejar en el test 041 la aserción vieja de la línea 690 (`sqlite-vec-linux-arm64` con `strings`) en vez de `vec0-libc.sh` | P1 |
| M29 | mover `_embed_phase reindex` después de `heartbeatctl qmd-reindex` | P1 |
| M30 | crear `.github/scripts/fetch-qmd-models.sh` sin el bit ejecutable | W8 |
| M31 | no escribir `QMD_E2E_MODELS_DIR` en `$GITHUB_ENV` con `outcome=ok` | F1 |
| M32 | aceptar como defecto cualquier valor no vacío | F7 |
| M33 | usar `--proto =https` también con la base local | F11 |
| M34 | que `vec0-libc.sh` mire solo `linux-x64` | V1 |
| M35 | que `vec0-libc.sh` responda `MUSL` aunque el archivo contenga `GLIBC_` | V3 |
| M36 | que `vec0-libc.sh` tome el primer archivo en vez de responder `AMBIGUOUS` | V5 |
| M37 | que `vec0-libc.sh` sin argumento salga con 0 | V6 |
| M38 | quitar de `docs/qmd-upgrade-checklist.md` la receta con el script de obtención | G3 |
| M39 | `continue-on-error: true` en `Fetch the qmd models` | W1 |
| M40 | `continue-on-error: true` en `Run docker-e2e suite` | W5 |
| M41 | dejar en `0 0` las esperas por defecto | F3 |
| M42 | dejar en 4800 el presupuesto por defecto | F13 |
| M43 | quitar `elapsed_s=` de la línea `ok` de cada modelo | F1 |
| M44 | volver a escribir `version: "2.5.3"` como literal en `_qmd_real_ws` | G1 |
| M45 | reintentar cuando el tamaño coincide y la suma no | F5 |
| M46 | aceptar un motivo no ASCII en `QMD_EMBED_DEFECT` | F7 |
| M47 | sin `GITHUB_ENV`, salir con 1 aunque los dos modelos queden verificados (un `[ -n "$GITHUB_ENV" ] && …` como última instrucción) | F12 |
| M48 | borrar la validación de la base (`QMD_MODELS_BASE_URL`) | F8 |
| M49 | quitar el chequeo de que el puerto sean dígitos (`http://127.0.0.1:@a.io`: el host sería `a.io`) | F8 |
| M50 | borrar el guard de salto de línea del defecto (inyección de variables en `$GITHUB_ENV`) | F7 |
| M51 | quitar el `trap` de salida que borra los `.part` | F3 |
| M52 | no recortar la espera al presupuesto restante | F10 |
| M53 | aceptar un cuerpo más corto que lo esperado (`-ne` a `-gt`) | F4 |
| M54 | un bloque `permissions: contents: write` en el job `e2e` | W7 |
| M55 | `continue-on-error` en `Verify deps + docker` | W2 |
| M56 | ignorar `QMD_MODELS_DIR` | F1 |
| M57 | borrar la aserción de la búsqueda semántica (`grep -qi 'gato'`) del test 041 | P1 |
| M58 | borrar la aserción `MUSL` del test 041 | P1 |
| M59 | borrar la aserción `pending == 0` del test 041 | P1 |
| M60 | `models-untouched` deja de fallar (quitar su `false`) | P1 |
| M61 | las marcas de fase van a stdout y no al descriptor 3 | P1 |
| M62 | la página de la fase `reindex` vuelve a la raíz del vault (fuera de la colección) | P1 |
| M63 | la puerta trata `QMD_EMBED_E2E=0` como abierta | K1 |
| M64 | la puerta cerrada ignora `QMD_EMBED_SKIP_REASON` | K2 |
| M65 | `vec0-libc.sh` busca `GLIBC` sin el guion bajo | V1 |
| M66 | `curl` sin `--show-error` | F11 |
| M67 | quitar la anotación `(http NNN)` de un intento fallido | F3 |
| M68 | no comprobar la longitud del sha256 de una fila de la tabla | F9 |
| M69 | aceptar un defecto cuyo motivo son solo espacios | F7 |
| M70 | `elapsed_s` deja de ser un número | F1 |
| M71 | el motivo de la deriva repite la suma esperada en vez de la observada | F5 |
| M72 | no comprobar que el directorio de modelos se pudo crear | F9 |
| M73 | quitar del vault sembrado la página que el primer arranque embebe | P1 |
| M74 | quitar el `timeout` de la fase `reindex` | P1 |
| M75 | quitar el `timeout` de la fase `semantic-search` | P1 |
| M76 | un reindex que no termina ya no termina la fase (quitar su `false`) | P1 |
| M77 | un `vsearch` que no termina ya no termina la fase (quitar su `false`) | P1 |
| M78 | el plazo del setup deja de normalizarse a decimal (`10#`) | P1 |
| M79 | el informe de `models-untouched` vuelve a un `echo` sin `#` en cada línea | P1 |
| M80 | el `teardown` deja de llamar a `_embed_failure_state` | P2 |
| M81 | `_embed_failure_state` se llama después de bajar el proyecto | P2 |
| M82 | borrar del estado al fallar la sonda `docker inspect` | P2 |
| M83 | la sonda de dentro del contenedor pierde su protección contra fallos | P2 |
| M84 | el cron de respaldo del workspace de los tests reales vuelve a `*/5 * * * *` | P2 |
| M85 | `emit_env` ignora el estado de la escritura en `GITHUB_ENV` | F12 |
| M86 | la rama de éxito ignora un `GITHUB_ENV` que no pudo escribir | F12 |
| M87 | la tabla acepta un tamaño con cero a la izquierda | F9 |
| M88 | el directorio por defecto que no se puede crear nombra `QMD_MODELS_DIR` | F9 |
| M89 | el presupuesto agotado pisa la causa del último intento | F10 |
| M90 | el workflow registra un defecto cuyo motivo son solo espacios | W6 |
| M91 | quitar del estado al fallar el veredicto de `vec0-libc.sh` | P2 |
| M92 | el estado al fallar no lee el veredicto de OOM del contenedor | P2 |
| M93 | los plazos pierden el `-k 10` (el KILL que necesita un hijo que ignora TERM) | P1 |
| M94 | el script deja de fijar `LC_ALL=C` (la pierna de comportamiento solo muerde donde bash traduce sus mensajes, como en esta Mac en español; la aserción sobre las dos líneas del script lo caza en todas partes) | F12 |
| M95 | quitar del estado al fallar el contenido de `qmd-index.json` | P2 |
| M96 | quitar del estado al fallar las últimas líneas de `qmd-reindex.out` | P2 |
| M97 | quitar del estado al fallar las últimas líneas de `vsearch.out` | P2 |
| M98 | la rama del defecto abierto ignora un `GITHUB_ENV` que no pudo escribir | F12 |
| M99 | el informe de un reindex que no termina pierde cuánto corrió | P1 |
| M100 | el informe de una búsqueda semántica que no termina pierde cuánto corrió | P1 |
| M101 | la checklist cita un encabezado que el test no imprime | G3 |

Cada uno de los 36 tests tiene al menos una mutación en la tabla. M1 a M47 son las del diseño; **M48 a M73 salieron de la revisión independiente (T025) y de las correcciones que provocó**: las 22 primeras sobrevivían al oráculo original (0 cazadas), y por eso se reforzaron los tests antes del gate. **M74 a M94 salieron de la segunda revisión (T025, ronda 2: un workflow de cinco lentes con dos escépticos por hallazgo)**: cada aserción nueva se vio en rojo antes del arreglo y se cazó con su mutación después. Dos de ellas sobrevivieron a la primera versión de los tests nuevos (M79 y M83: el umbral «al menos uno» dejaba pasar la pérdida de uno de tres usos y de una de cuatro protecciones) y se endurecieron antes de seguir; M94 (`LC_ALL=C`) solo caía donde bash traduce sus propios mensajes, como en esta Mac en español (en bash 3.2 de Apple, sin catálogos, y en la CI, en inglés, no), y se agregó la aserción sobre las dos líneas del script para que caiga en todas partes. **M95 a M101 salieron de la tercera revisión (un workflow de tres lentes sobre lo que cambió la segunda)**: el estado al fallar con los archivos del reindex y de la búsqueda (M95 a M97), la rama del defecto abierto que ignoraba una escritura fallida (M98), el informe con los segundos y la cola de la salida (M99 y M100) y el encabezado que cita la checklist (M101). Cada aserción nueva se vio en rojo contra el código anterior y se cazó con su mutación después; M31, M47, M76, M77, M83 y M86 se apuntaron de nuevo a los textos que el arreglo cambió. Se registra el resultado de cada una en las Notes de `tasks.md`. Si una sobrevive, se endurece el oráculo antes de seguir (precedente de 034 y 037).

## 4. DOCKER_E2E local (compuerta: Docker Desktop y disco del operador)

Da una referencia verde en arm64, donde 017 midió el embed. Es opcional antes de E1 y **obligatorio antes del PR si E1 no llega a la fase `models-untouched`** (FR-020, decisión del 16-10-2026): es la única forma de ejecutar esas fases antes del merge.

```bash
QMD_MODELS_DIR="$HOME/.cache/agentic-qmd-e2e/models" .github/scripts/fetch-qmd-models.sh
DOCKER_E2E=1 QMD_EMBED_E2E=1 QMD_E2E_MODELS_DIR="$HOME/.cache/agentic-qmd-e2e/models" \
  bats tests/docker-e2e-qmd.bats -f 'qmd real'
```

Esperado: `qmd real (016)` verde y `qmd real (041)` verde, con las ocho marcas `# qmd embed phase:` en orden y la línea `# qmd embed resources:`. La primera línea baja 1,6 GB al disco del operador.

## 5. Evidencia en CI (FR-020; SC-001, SC-002, SC-005, SC-006). Cada paso es una compuerta

Antes de E1: push de la rama por HTTPS con el helper de `gh` (el token tiene el permiso `workflow`).

| Ensayo | Cómo | Qué se espera | Qué se registra |
| --- | --- | --- | --- |
| E1 | `gh workflow run docker-e2e.yml --ref 041-nightly-qmd-embed` | según la inferencia de research M7, un rojo en `setup` o en `vector-extension` en amd64; si el embed pasa, un verde | identificador, arquitectura, duración del job (con `started_at` y `completed_at`) y margen, la duración de cada fase (la de `setup` incluye la compilación), las líneas `qmd model … ok` (tamaño, intentos, segundos), `free_kb` antes y después, la línea `# qmd embed resources:`, las marcas de fase, la línea TAP del test 041 y la clasificación con su fragmento de log |
| E2 (si E1 muestra un defecto de producto) | el operador abre el issue de seguimiento; commit con `QMD_EMBED_DEFECT: '#<n> <motivo>'`; dispatch | `# skip fase del embed apagada por defecto abierto: #<n> …`; job verde si nada más falla | identificador y línea TAP |
| E3 | rama de ensayo que no se mergea, con el `file` del modelo de embeddings cambiado por uno inexistente; dispatch | `fetch_models` en rojo tras tres intentos (404), la suite corre, el test 041 sale saltado con «no se pudieron obtener…», job rojo | identificador, motivo, que la suite corrió |
| E4 (solo si E1 fue verde) | rama de ensayo que no se mergea, que construye la imagen del test 041 con `--build-arg QMD_NATIVE_TOOLCHAIN=0`; dispatch | rojo con la última marca en `setup` o en `vector-extension` | identificador y la marca |

- Logs: `gh run view <id> --log > run.log` y comprobar que trae `GNU bash, version` antes de buscar nada; con `gh api …/logs` hace falta `--allow-escape-sequences`.
- Un rojo del test 041 trae, tras el volcado del log del contenedor, el bloque `# --- state at the failure: disk, container verdict, vector extension ---`: el disco libre (`free_kb=`), el veredicto del contenedor (`oom=`, `exit=`, `restarts=`), `uname -m`, la respuesta de `vec0-libc.sh` sobre el prefijo, el contenido de los paquetes `sqlite-vec-linux-*`, y el estado y la salida del reindex y de la búsqueda (`qmd-index.json` y las últimas 40 líneas de `qmd-reindex.out` y de `vsearch.out`). Una línea `GLIBC …/sqlite-vec-linux-x64/vec0.so` confirma la inferencia de research M7 y es la base para registrar `QMD_EMBED_DEFECT`; sin ella, el defecto no se abre solo por inferencia.
- Un reindex o un `vsearch` que no terminan fallan como `reindex` o `semantic-search`, con el rc, los segundos que corrieron y las últimas 12 líneas de su salida (`… did not finish in 600s` o `300s`) en vez de agotar el tope del job. Si E1 aun así se corta por el tope de 30 min (la suma de la obtención, dos compilaciones nativas y el embed no está medida), la medición llega sin `e2e summary:`. Para medir la duración completa en una sola corrida se puede correr E1 desde un commit de ensayo con `timeout-minutes: 45` en una rama que no se mergea; la rama que se mergea conserva 30 hasta que T033 lo decida con los números (research D18).
- Con el margen de E1 se decide FR-013: si queda bajo 5 min, se sube el tope y se vuelve a medir. Compartir el prefijo compilado es una mejora posterior (research D8).
- Si E1 no llega a la fase `models-untouched`, el DOCKER_E2E local de §4 pasa a ser obligatorio antes del PR.
- Las ramas de ensayo se borran al terminar, con la confirmación del operador.

## 6. Después del merge (SC-007). Compuerta: el merge

Las tres nocturnas siguientes deben ejecutar la fase del embed, o tenerla apagada por un defecto abierto y registrado, y terminar dentro del tope con al menos 5 minutos de margen. Se registra en las Notes de cada noche: identificador, duración del job, margen, línea TAP del test 041 y la `e2e summary:`. Si alguna queda con menos de 5 minutos de margen o con tiempo agotado, se reabre FR-013: se sube el tope en un PR aparte y se vuelve a medir.

## 7. Gates finales (SC-008, SC-010)

```bash
# shellcheck: el comando exacto del job de CI (incluye .github/scripts/)
{ find . -type f \( -name '*.sh' -o -name '*.bash' \) -not -path './.git/*' \
    -not -path './scripts/vendor/*' -not -path './tests/*'
  printf './scripts/agentctl\n./docker/scripts/heartbeatctl\n'; } | xargs shellcheck -S error -e SC1090,SC1091

git diff --stat origin/main -- docker scripts modules setup.sh    # vacío
git show origin/main:VERSION; cat VERSION                          # iguales (0.28.0 hoy)
git ls-files -s .github/scripts/fetch-qmd-models.sh tests/fixtures/qmd-e2e/   # 100755 en los ejecutables
LC_ALL=C grep -c $'\xcc\x80' specs/041-nightly-qmd-embed/*.md specs/041-nightly-qmd-embed/contracts/*.md   # 0 en cada uno
```

- El script y los fixtures son ASCII puro (F12 lo prueba en el script).
- CHANGELOG y CLAUDE.md dicen lo que el nightly cubre y lo que no (FR-021).
