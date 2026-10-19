# Quickstart: validar el arreglo del reemplazo de sqlite-vec en amd64

**Feature**: 042-qmd-sqlite-vec-x64 | **Spec**: [spec.md](spec.md) | **Plan**: [plan.md](plan.md)

Guía de validación ejecutable, de la más barata a la más cara. Cada escenario dice qué prueba, qué necesita, cómo se corre y qué resultado se espera; los contratos y el modelo de datos tienen el detalle ([contracts/swap-sqlite-vec.md](contracts/swap-sqlite-vec.md), [contracts/host-oracle.md](contracts/host-oracle.md), [contracts/nightly-reactivation.md](contracts/nightly-reactivation.md), [data-model.md](data-model.md)). Los escenarios V3 a V6 usan lo que el PR #108 (041) dejó en `main` (squash `0fc08a8`) y necesitan que esta rama se haya rebasado sobre él.

## Requisitos previos

- Un clon de esta rama con `bats` 1.11 o superior, `yq` v4, `jq`, `shellcheck` y `git`.
- Para V2 y V3: Docker Desktop encendido en el Mac (arm64). V2 usa la imagen `alpine:3.24.1` en su variante `linux/amd64` (se emula; la primera vez baja unos 4 MB) y en la `linux/arm64` (nativa; si falta, baja unos pocos MB).
- Para V3: los dos modelos de 041 en `~/.cache/agentic-qmd-e2e/models-041` (1.616.029.856 bytes); si faltan, se obtienen con `QMD_MODELS_DIR=<dir> .github/scripts/fetch-qmd-models.sh` (unos 3 minutos con buena red).
- Para V4 a V6: `gh` con la cuenta que tiene el scope `workflow` y el visto bueno del operador para cada push y cada `workflow_dispatch`.

## V1. El oráculo del host (segundos; SC-003, SC-006)

1. **ROJO primero** (test-first): con las pruebas nuevas escritas y la función sin cambiar, `bats tests/qmd-sqlite-vec.bats` debe fallar en la reforzada E5 y en N1 a N5, N7 a N9 y N11 (10 pruebas); las demás siguen en verde: E1 a E4 (E1 y E3 reforzadas con la línea del log, que guardan FR-002 y caen con M13a y M13b), G1, G2 y las dos que nacen verdes a propósito, N6 y N10, que guardan comportamiento actual y caen con M6 y M14 (N6) y con M9a (N10). Se anota cuáles cayeron.
2. **VERDE** con la función arreglada: `bats tests/qmd-sqlite-vec.bats` da 18 de 18 en bash 5.x; en bash 3.2 con `PATH=/bin:$PATH bats tests/qmd-sqlite-vec.bats`.
3. **Mutaciones** M1 a M15 del catálogo ([contracts/host-oracle.md](contracts/host-oracle.md) §3, con M9 y M13 en sus variantes M9a y M9b, M13a, M13b y M13c), como usuario no root: cada una cae por la prueba prevista.
4. **shellcheck** con las opciones del paso `Run shellcheck` de `.github/workflows/shellcheck.yml` (`shellcheck -S error -e SC1090,SC1091 scripts/lib/qmd_index.sh`): rc 0; el paso completo, que recorre todo el árbol, se corre en V7.
5. **Paridad**: lo mismo con la señal SIGPIPE ignorada (`perl -e '$SIG{PIPE}="IGNORE"; exec @ARGV' bats ...`) y con el `uname` del host distinto del que usa la prueba (macOS arm64 y ubuntu amd64 dan el mismo resultado porque las pruebas fijan la arquitectura).

**Se espera**: 18 de 18 en los dos bash, 15 de 15 mutaciones cazadas (M9 y M13 en sus variantes), shellcheck limpio.

## V2. Humo local con la función real: amd64 emulado y pata arm64 nativa (unos 2 minutos; FR-001, FR-002, research M4 y M6)

Prueba el reemplazo de verdad en un Alpine amd64 emulado, sin qmd ni modelos, y repite lo mismo en un Alpine arm64 nativo para guardar que arm64 queda igual que hoy.

1. En el host, bajar solo para leer el tarball publicado de `sqlite-vec-linux-x64@0.1.9` y extraerlo a un directorio temporal (como hizo la Fase 0: `curl` del `dist.tarball` del registro y `tar -xzf`; no se ejecuta nada en el host).
2. Levantar un contenedor desechable `alpine:3.24.1` `--platform linux/amd64` con el repositorio montado de solo lectura y ese directorio montado de solo lectura; instalar `bash`, `build-base` y `sqlite`.
3. Ejecutar `docker/scripts/build-sqlite-vec.sh` (hornea la build musl en `/opt/agent-admin/sqlite-vec/vec0.so`).
4. Armar un prefijo falso `node_modules/sqlite-vec-linux-x64/vec0.so` con el binario glibc del paquete publicado.
5. Cargar `scripts/lib/qmd_index.sh`, llamar a `_qmd_swap_sqlite_vec <prefijo>` y cargar la extensión con `sqlite3 :memory: ".load <prefijo>/node_modules/sqlite-vec-linux-x64/vec0" "select vec_version();"`.

**Antes del arreglo** (ROJO): la función no cambia nada ni dice nada; la carga falla con `Error relocating ...: __memcpy_chk: symbol not found`. **Después** (VERDE): la salida de error trae `swapped glibc prebuilt for musl build` y la carga devuelve `v0.1.9`. Una segunda llamada no imprime nada. Con el paquete arm64 en el prefijo y la arquitectura de la máquina x86_64, la función dice `no sqlite-vec-linux-x64 package` y `found: sqlite-vec-linux-arm64`.

Los pasos 1 a 3 y la carga final ya se midieron en la Fase 0 (research M4 y M6); lo nuevo de V2 es llamar a la función real.

**Pata arm64 (FR-002, SC-002)**: el mismo procedimiento con `--platform linux/arm64` (nativo en este Mac), el paquete `sqlite-vec-linux-arm64@0.1.9` y, uno tras otro, la biblioteca de `origin/main` y la de esta rama. **Se espera** que las dos dejen el `vec0.so` del paquete idéntico a la build horneada (`cmp -s`), impriman la misma línea `swapped glibc prebuilt for musl build` y callen en la segunda llamada: es la evidencia, con la función real, de que arm64 queda igual que hoy, porque el DOCKER_E2E de V3 no muestra esa línea en una corrida verde (solo vuelca el log del contenedor cuando falla).

## V3. DOCKER_E2E arm64 local sin cambio de resultado (unos 9 minutos; FR-002, SC-002)

Con Docker Desktop encendido, en este Mac (arm64):

```text
DOCKER_E2E=1 QMD_EMBED_E2E=1 QMD_E2E_MODELS_DIR=$HOME/.cache/agentic-qmd-e2e/models-041 \
  bats --tap tests/docker-e2e-qmd.bats -f 'qmd real'
```

**Se espera**: `ok qmd real (016)` y `ok qmd real (041)` con las ocho marcas en orden, la línea `# qmd embed resources:` y un tiempo en el orden de los 8 min 42 s de T026 (con la imagen en la caché de capas). Con la variable `QMD_EMBED_DEFECT` del workflow vacía o no (el local no lee el workflow). La línea `swapped glibc prebuilt for musl build` no aparece en una corrida verde: la guardan E1 (V1) y la pata arm64 de V2. Se anota el resultado en las Notes.

## V4. CI amd64 con la fase activa (3 o más corridas; FR-008, FR-009, FR-010, SC-001, SC-004)

Con el interruptor vacío en la rama, el operador autoriza cada push y cada dispatch:

1. `gh workflow run docker-e2e.yml --ref 042-qmd-sqlite-vec-x64` y seguir la corrida (un monitor del scratchpad emite cada paso del job).
2. Al terminar, descargar el log y **comprobar que trae `GNU bash, version` antes de contar nada** (un log vacío cuenta cero en silencio).
3. Registrar por corrida lo de [contracts/nightly-reactivation.md](contracts/nightly-reactivation.md) §3: identificador, commit, `started_at`, `completed_at`, duración, margen, duración de `setup`, línea TAP del test 041 y `e2e summary:`.
4. Repetir hasta tener al menos 3 corridas con el mismo texto. Si el margen mínimo es menor de 5 minutos, subir el tope primero (propuesta: 45) en un commit aparte y volver a medir.

**Se espera**: `ok N qmd real (041)` ejecutado (no saltado) con las ocho marcas; `e2e summary: total=49 executed=49 skipped=0 failed=0` (o el total vigente tras el rebase); margen de al menos 5 minutos. Si el test 041 falla, se clasifica con el volcado del estado al fallar (producto, arnés o infraestructura): si el log del contenedor dice `musl build absent`, es el supuesto de la build horneada ausente y se corrige en esta feature; cualquier otra causa de producto sigue la sección 5 del contrato.

## V5. La rotura inducida (una corrida; FR-011, SC-005)

En una rama de ensayo desde la punta final (no se mergea), cambiar una línea de `tests/docker-e2e-qmd.bats` para que la imagen del test 041 se construya con `QMD_NATIVE_TOOLCHAIN=0` (en `qmd real (041)`, línea 753 en `origin/main` `0fc08a8`, la línea 802, `(cd "$D" && docker compose build)`, pasa a llevar `--build-arg QMD_NATIVE_TOOLCHAIN=0`, como la pata RED de `qmd real (016)` en la línea 728), empujarla y lanzar el workflow. **Se espera**: job en rojo, `not ok N qmd real (041)` y la última marca `# qmd embed phase:` en `setup` o `vector-extension`; el resto de la suite en verde. Se anota la corrida y se borra la rama (con confirmación).

## V6. Las tres noches (SC-001)

Tras el merge, para cada una de las tres nocturnas siguientes: `gh run list --workflow docker-e2e.yml --event schedule --limit 3` y el log de cada una. **Se espera**: el test 041 ejecutado (no saltado), el resumen sin fallas y al menos 5 minutos de margen. Los resultados van a un PR de documentos aparte.

## V7. La compuerta completa (antes del PR)

`bats --tap tests/` secuencial en bash 5.x y en 3.2 sobre un árbol congelado, con la salida de error vacía. **Se espera**: 0 pruebas fallidas y el conteo de la línea base medida más las 11 pruebas nuevas; shellcheck con el comando de la CI en rc 0; la CI del PR en verde en sus tres checks.

## Qué escenario prueba qué criterio

| Criterio | Escenarios |
| --- | --- |
| SC-001 (la fase corre en amd64 y deja margen) | V4, V6 |
| SC-002 (arm64 sin cambio) | V1, V2 (pata arm64), V3 |
| SC-003 (el log diagnostica) | V1, V2 |
| SC-004 (duración medida en 3 corridas) | V4 |
| SC-005 (rotura inducida en rojo) | V5 |
| SC-006 (suite del host en verde en los dos bash) | V1, V7 |
| SC-007 (#107 se cierra con sus obligaciones) | V4, V5, V6 y el PR |
