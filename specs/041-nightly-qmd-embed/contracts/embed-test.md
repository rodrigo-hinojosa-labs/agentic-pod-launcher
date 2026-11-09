# Contrato: la fase del embed en `tests/docker-e2e-qmd.bats`

La fase del embed sale de `qmd real (016)` a un test propio (FR-001 a FR-006, FR-014, FR-015; research D2, D8 a D12). Las fases y sus criterios están en [data-model.md](../data-model.md) §4.

## 1. Asistente común: `_qmd_real_ws DIR NAME IMAGE_TAG`

Arma el workspace igual que lo arma hoy el test 016:

- el `agent.yml` actual, con `image_tag` parametrizado y la versión de qmd tomada de `qmd_pkg` (cargando `scripts/lib/qmd_index.sh` en un subshell, como el archivo ya lo hace en sus otros tests), sin el literal `2.5.3` (research D5, oráculo G1);
- la copia de `modules/`, `scripts/`, `docker/` y `setup.sh`;
- `setup.sh --regenerate --non-interactive`;
- el `.env` vacío en modo 0600 y `.state/` creado;
- el stub de `claude` y su montaje inyectado en el compose;
- el cron de respaldo de qmd programado el 31 de febrero (`schedule: "0 0 31 2 *"`, una fecha que no existe): estos tests corren el reindex a mano, y un disparo del cron entre el fin del setup y esa llamada tomaría el lock, así que el reindex manual saldría con 0 sin escribir nada y una corrida sana se pondría en rojo (segunda revisión, research D18). `setup.sh --regenerate` avisa de que esa forma no tiene equivalente en systemd; solo importa en modo local.

Además copia `tests/fixtures/qmd-e2e/vec0-libc.sh` a `DIR/.e2e/vec0-libc.sh` (dentro del contenedor, `/workspace/.e2e/vec0-libc.sh`). Lo ejecuta solo el test 041 (fase `vector-extension`) y lo prueba el oráculo del host (grupo V); el 016 recibe la copia, porque el asistente la hace para los dos workspaces, pero no la invoca y conserva su comprobación con `strings` sobre el `vec0.so` horneado en la imagen, que mira otro archivo. Extraerlo no cambia ninguna aserción del test 016.

## 2. `qmd real (016): native deps compile with toolchain; RED without it (SC-003)`

Mismo nombre y mismas aserciones de la fase A y de la detección RED. Lo único que se elimina es el bloque `if [ "${QMD_EMBED_E2E:-0}" = "1" ]` (las líneas 668 a 721 de `main`), que pasa al test de §3. El comentario de cabecera del archivo deja de describir el Tier 2 como parte de este test.

## 3. `qmd real (041): embed phase - setup, models, vector extension, reindex, semantic search, MCP`

Va justo después del test 016. Workspace `$TMP_TEST_DIR/agent-qmd-embed`, `NAME=qmd-embed`, imagen `agent-admin:qmd-embed`. El nombre empieza con `agent-qmd-`, así que el barrido del `teardown` existente lo incluye.

### 3.1 Puerta: las primeras instrucciones, antes de cualquier llamada a Docker

```text
QMD_EMBED_E2E distinto de 1      → skip "${QMD_EMBED_SKIP_REASON:-embed phase needs QMD_EMBED_E2E=1 and the models fetched by .github/scripts/fetch-qmd-models.sh (about 1.6 GB)}"
QMD_EMBED_SKIP_REASON no vacío   → skip "$QMD_EMBED_SKIP_REASON"
QMD_E2E_MODELS_DIR vacío         → falla: "QMD_E2E_MODELS_DIR is required with QMD_EMBED_E2E=1: run .github/scripts/fetch-qmd-models.sh first"
```

El tercer caso es un error del arnés, no un salto (D8). Ninguno de los tres llama a `docker` ni a `curl`.

### 3.2 Fases

Cada fase empieza con `_embed_phase <nombre>`, que imprime `# qmd embed phase: <nombre>` por el descriptor 3. Entre su marca y la siguiente, cada fase contiene el comando que la define (su ancla; la tabla está en contracts/host-oracle.md, P1), de modo que la última marca antes de un `not ok` nombra la fase que falló.

1. **`models-seed`**: se toman los `*.gguf` presentes en `QMD_E2E_MODELS_DIR`. El script solo deja ahí archivos verificados; debe haber al menos uno, o la fase falla. El test no repite los nombres de la tabla, que siguen teniendo una sola fuente. Se enlazan, o se copian si no se puede, en `.state/.cache/qmd/models/`. Se registra el inodo de cada uno (`ls -i`) y se crea `DIR/.e2e/seed-marker` después de sembrar. Si faltara un modelo, la fase 8 lo detecta: qmd lo bajaría dentro del contenedor.
2. **`boot`**: primero, el vault con que arranca el agente. La colección de qmd cubre solo `wiki/**/*.md` desde 037 (`scripts/lib/qmd_index.sh`, `collection add … --mask 'wiki/**/*.md'`) y el esqueleto trae `wiki/` vacío, así que una página en la raíz del vault, donde escribía su documento el Tier 2 de 016, nunca se indexa: con un producto sano la búsqueda semántica no la podía encontrar y el setup del primer arranque no tenía nada que embeber. El test siembra el vault **antes del primer arranque**, como el e2e de PARA (`vault_seed_if_empty` no toca un vault que ya tiene contenido): copia `modules/vault-skeleton/.` a `.state/.vault/` y agrega la página `wiki/concepts/computadores.md`, para que el setup embeba una página real y ejerza los modelos y la extensión vectorial ahí mismo (hallazgo de la revisión independiente, research M14). Después, `docker compose build` y `docker compose up -d`. Con `docker compose exec -T -u agent`, `CI` debe estar vacía y `XDG_CACHE_HOME` vacía o igual a `$HOME/.cache`. Si no, la falla nombra la variable (D12).
3. **`setup`**: espera `.qmd-setup-ok` con un sondeo cada 5 s, hasta `QMD_E2E_SETUP_DEADLINE_S` (entero de 1 a 3600; por defecto 600; un valor con ceros a la izquierda se lee en decimal, no en octal). En cada vuelta vuelca `docker compose logs` a un archivo (`DIR/.e2e/compose.log`) y lo busca con `grep` sobre el archivo, sin tubería. Si aparece `[qmd] setup: '<paso>' failed` o `[qmd] install: bun install failed`, falla en ese momento con el paso y la línea redactada (D11).
4. **`vector-extension`**: `sh /workspace/.e2e/vec0-libc.sh "$HOME/.cache/qmd/pkg"` dentro del contenedor (busybox) debe imprimir `MUSL` con rc 0. Reemplaza la aserción de la línea 690, que miraba solo `linux-arm64` y pasaba en vacío (FR-003); el cuerpo del test ya no contiene `sqlite-vec-linux-arm64`.
5. **`reindex`**: escribe `wiki/concepts/gatos.md` dentro del contenedor (bajo `wiki/`, por la razón de la fase 2), corre `heartbeatctl qmd-reindex` acotado dentro del contenedor (`timeout -k 10 600`, con la salida a un archivo para que un hijo huérfano no retenga la tubería de `docker exec`) y comprueba `last_status` (`ok` o `indexed`) y `pending` (0). Si el comando no termina (rc 124, 137 o 143), la fase falla con «qmd-reindex did not finish in 600s», el rc, los segundos que corrió (`SECONDS - t0`: un 137 mucho antes del plazo es un kill desde fuera, que el `oom=` del estado al fallar confirma o descarta) y las últimas 12 líneas de lo que alcanzó a imprimir, en vez de dejar que el tope del job cancele la noche y pierda el resto de la suite (segunda y tercera revisión; research M15 y D18). Las líneas salen con `_embed_tail`, que usa `tail`: un corte por posición negativa (`${x: -N}`) da una cadena vacía, no el valor entero, cuando el valor es más corto que N (medido en bash 3.2 y 5.x).
6. **`semantic-search`**: igual que hoy (`vsearch "animal encima del pc"`, con `LD_PRELOAD` de bigstack, debe contener `gato`). Esta fase carga el modelo de expansión sembrado en la fase 1. Va acotada como el reindex (`timeout -k 10 300 env LD_PRELOAD=… qmd vsearch …`; `env` y no una asignación de prefijo, para que el `LD_PRELOAD` llegue a qmd y no a `timeout`) y falla con «vsearch did not finish in 300s» si no termina, con el mismo informe que el reindex (rc, segundos y últimas 12 líneas). Si `vsearch` termina con otro código no cero pero imprime el documento, la aserción es la de siempre (`gato`).
7. **`mcp`**: igual que hoy (`timeout 25`, sin firmas del BUG-4).
8. **`models-untouched`**: en `.state/.cache/qmd/models/` hay exactamente los archivos sembrados, ni uno más ni uno menos y con cualquier extensión (un temporal de descarga también cuenta), con el mismo inodo, y `find <archivo> -newer DIR/.e2e/seed-marker` no imprime nada. Si no, falla con «qmd downloaded or rewrote a model inside the container» (FR-007), con cada línea de sus listas (una por archivo) precedida por su propio `#` (`_embed_note`). Si qmd dejara ahí un archivo legítimo, es un hallazgo de arnés (FR-015) que se registra.

Al terminar, y antes de bajar el proyecto, el test imprime por el descriptor 3 `# qmd embed resources: disk_free_kb=<n> mem_peak_bytes=<n o unknown>`, con `df -Pk` del workspace y el `memory.peak` del cgroup del contenedor (`unknown` si el archivo no existe). No es una aserción: es la medición de disco y memoria que pide el spec (data-model §6). Después, `docker compose down -v --remove-orphans`.

### 3.3 Diagnóstico al fallar (D9)

El `teardown` del archivo, antes de su barrido actual: si `BATS_TEST_COMPLETED` está vacío y existe `$TMP_TEST_DIR/agent-qmd-embed/docker-compose.yml`, vuelca una vez `docker compose logs --tail=150` de ese proyecto por el descriptor 3, como comentarios TAP: se ven con cualquier bandera de bats. A continuación, `_embed_failure_state` deja el estado que una primera corrida roja no puede pedir después: el disco libre (`df -Pk`), el veredicto del propio contenedor (`docker inspect`: `OOMKilled`, código de salida y reinicios) y, desde dentro (`exec -T -u agent`), la arquitectura (`uname -m`), el veredicto de `vec0-libc.sh` sobre el prefijo, el contenido de los paquetes `sqlite-vec-linux-*`, los contadores de memoria del cgroup (`memory.events`, `memory.peak`) y los tres archivos donde queda la causa de una falla que no es un plazo (un rc 91, un `stalled`, un segfault de `vsearch`): `qmd-index.json`, las últimas 40 líneas de `qmd-reindex.out` y las de `vsearch.out`; el workspace desaparece cuando termina el job y esos archivos con él. Cada sonda tolera el fallo: ninguna puede cambiar el rojo que reporta. La línea `# qmd embed resources:` del camino verde se mantiene (segunda revisión; research D18). El volcado ad hoc que hoy hace el ciclo del centinela se elimina, para que no quede duplicado. **Sin plazo propio, y aceptado** (research D18): el `build` y el `up` del arranque, los `exec` de la comprobación de `CI` y de `XDG_CACHE_HOME`, las fases `vector-extension` y `models-untouched` y el `docker exec` de cada vuelta del sondeo del setup; un cuelgue ahí lo corta el tope del job y FR-004 no los cubre.

## 4. `tests/fixtures/qmd-e2e/vec0-libc.sh PREFIJO`

Script POSIX (`#!/bin/sh`), porque corre con el busybox del contenedor y con el `sh` del host (dash en Ubuntu, bash en modo sh en macOS). Tanto el test como el oráculo lo invocan con `sh`.

| Situación en `PREFIJO/node_modules/sqlite-vec-linux-*/vec0.so` | Imprime | rc |
| --- | --- | --- |
| exactamente uno y no contiene `GLIBC_` | `MUSL <ruta>` | 0 |
| exactamente uno y contiene `GLIBC_` (`grep -q` sobre el archivo, sin tubería) | `GLIBC <ruta>` | 1 |
| ninguno | `ABSENT` | 2 |
| más de uno | `AMBIGUOUS <n>` | 3 |

Sin argumento, o con un argumento que no es un directorio, imprime `usage: vec0-libc.sh PREFIX` con rc 64.

## 5. Lo que no cambia

- `setup()`, el gate de `DOCKER_E2E` y los otros tres tests de qmd del archivo.
- `-u agent` en todo `docker compose exec` y `run`.
- Ninguna aserción existente se debilita. Las únicas correcciones son la de la línea 690 (§3.2, fase 4) y las marcas de fase (FR-002).
