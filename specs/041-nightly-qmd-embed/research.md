# Research: El nightly de docker-e2e ejercita el embed real de qmd

**Feature**: `041-nightly-qmd-embed` | **Fecha**: 2026-10-15 (mediciones del 14 y 15-10-2026) | **Spec**: [spec.md](spec.md)

Todo lo de abajo está leído o ejecutado, salvo lo que se marca como inferencia o como no medido. Las fuentes externas son el código publicado en npm de `@tobilu/qmd@2.5.3` y `node-llama-cpp@3.18.1` (descargado al scratchpad y leído, sin instalar), la API pública de HuggingFace, el registro de npm y la documentación oficial de GitHub Actions. Ninguna medición tocó un agente ni la red de la flota.

## Mediciones

### M1. Línea base de tiempo (`gh`, 14-10-2026)

- Corrida 37873376103 (`workflow_dispatch`, rama de 039, amd64): el paso de la suite tardó **885,4 s**; `qmd real (016)`, el test 15 de 48, **288,5 s**. Calculado por diferencia de las marcas de tiempo de las líneas TAP del log del job (`gh run view --job 113636249841 --log`, con `GNU bash, version` presente: el log no estaba truncado).
- Cinco nocturnas programadas sobre `main` (`13cafc3`), todas verdes, medidas de la creación a la última actualización de la corrida: 38047040835 (10-10, 14 min 54 s), 38135162982 (11-10, 15 min 12 s), 38252436900 (12-10, 15 min 05 s), 38398219639 (13-10, 15 min 29 s) y 38546565987 (14-10, 13 min 11 s). Dispersión: 2 min 18 s. Esas duraciones incluyen la espera en cola; el tope de 30 minutos aplica al job, así que el margen de E1 se mide con `started_at` y `completed_at` del job `e2e`.

### M2. Identidad de los modelos (API de HuggingFace, anónima)

| Uso | Repositorio (commit de `main`) | Archivo | Bytes | sha256 (oid LFS) | Acceso |
| --- | --- | --- | --- | --- | --- |
| embeddings | `ggml-org/embeddinggemma-300M-GGUF` (`0f741b5a6585…`) | `embeddinggemma-300M-Q8_0.gguf` | 333.590.944 | `b5ce9d77a3fc4b3b39ccb5643c36777911cc4eb46a66962eadfa3f5f60490d63` | público, `gated: false` |
| expansión | `tobil/qmd-query-expansion-1.7B-gguf` (`7816de0b7257…`) | `qmd-query-expansion-1.7B-q4_k_m.gguf` | 1.282.438.912 | `000dfb1c06efa6a049e9f64ba921c3740e2454f62abab6fa10e77bd30bb2bcc0` | público, `gated: false` |

Un HEAD anónimo de `https://huggingface.co/ggml-org/embeddinggemma-300M-GGUF/resolve/main/embeddinggemma-300M-Q8_0.gguf?download=true` responde `302` hacia `us.aws.cdn.hf.co`, con `x-linked-size: 333590944` y un `x-linked-etag` igual al sha256 de la tabla; la redirección termina en `200` con `content-length: 333590944`. Total de los dos: **1.616.029.856 bytes** (unos 1,6 GB).

### M3. qmd 2.5.3 (código publicado)

- `dist/llm.js:90-93`: modelos por defecto de embeddings, rerank y generación; `QMD_EMBED_MODEL` los puede reemplazar (`:89`, `:103`).
- `:119-121`: directorio de modelos `$XDG_CACHE_HOME/qmd/models`, o `~/.cache/qmd/models` si no está definido. En modo docker nadie define `XDG_CACHE_HOME` (compose no lo hace; `qmd_index.sh:560` solo lo imprime).
- `embed` resuelve el modelo con `resolveModel` → `resolveModelFile(uri, cacheDir)` + `validateGgufFile` (`:621-627`). La comprobación de ETag (un HEAD a HuggingFace que puede borrar el archivo local) vive solo en `pullModels` (`:247-301`), y a esa función solo la llama `qmd pull` (`cli/qmd.js:3912-3922`).
- `vsearch` → `vectorSearch` (`cli/qmd.js:2261`) → `vectorSearchQuery` (`store.js:3773`), que expande la consulta **sin condición** (`:3783`) → `LlamaCpp.expandQuery` → `ensureGenerateModel` (`llm.js:1062`): carga el modelo de generación y lo descarga si falta. La CLI no tiene una bandera que lo evite; `structuredSearch` (`store.js:3812`) salta la expansión pero reranquea, que es otro modelo.
- `_ciMode = !!process.env.CI` (`llm.js:384`) hace fallar `embedBatch` (`:942`), `generate` (`:1003`), `expandQuery` (`:1057`) y `rerank` (`:1149`) con «LLM operations are disabled in CI». GitHub Actions define `CI` en el runner; compose no la pasa al contenedor.
- `ensureLlama` llama a `getLlama({ build: "auto" })` (`llm.js:521-535`): compila en tiempo de ejecución solo si no hay un binario utilizable.

### M4. node-llama-cpp 3.18.1 (código publicado)

- `resolveModelFile`, con `download = "auto"` y `verify = false` (como lo llama qmd), busca en el directorio los nombres de archivo esperados y, si encuentra uno, lo devuelve **sin red** (`dist/utils/resolveModelFile.js`, `findMatchingFilesInDirectory` y el retorno anticipado).
- Nombre local de una URI `hf:<usuario>/<repo>/<archivo>`: `hf_<usuario>_<archivo>` cuando el archivo empieza con el nombre del repo sin `-GGUF` (`parseModelUri.js:284-332`). Resultan `hf_ggml-org_embeddinggemma-300M-Q8_0.gguf` (el mismo nombre que midió 037) y `hf_tobil_qmd-query-expansion-1.7B-q4_k_m.gguf`.
- URL de descarga: `<HF_ENDPOINT o https://huggingface.co/><usuario>/<repo>/resolve/main/<archivo>?download=true` (`parseModelUri.js:276-282`, `modelDownloadEndpoints.js:13-16`).

### M5. Dónde compila llama.cpp

- El `postinstall` de node-llama-cpp (`node ./dist/cli/cli.js postinstall`) llama a `getLlamaForOptions` (`OnPostInstallCommand.js`): usa un binario precompilado si alguno sirve y, si no, compila. Como `node-llama-cpp` está en `trustedDependencies` (`qmd_index.sh:151`), bun ejecuta ese postinstall en el `bun install` de `_qmd_ensure_prefix`: en la fase A del test y en el primer arranque de cualquier `.state` nuevo.
- El código fuente de llama.cpp viene dentro del paquete: `llama/gitRelease.bundle` (28.597.931 bytes, tag `b8390`). Inferencia: la compilación no baja el código de GitHub. No medido.
- No medido: cuánto tarda esa compilación en el runner amd64. Cota medida: la fase A completa, incluida la reconstrucción RED, tardó 288,5 s (M1).

### M6. El setup y sus señales

- El centinela `.qmd-setup-ok` se escribe solo si `collection add`, `update` y `embed` terminan bien (`qmd_index.sh:477-504`). Cada falla deja `[qmd] setup: '<paso>' failed/timed out: <cola redactada> — retry next boot` en stderr (`_qmd_log`, `:45`); una falla de instalación deja `[qmd] install: bun install failed for …` (`:220`).
- `start_services.sh:186` lanza `( qmd_setup_if_needed /workspace/agent.yml ) &` sin redirigir: esas líneas llegan a `docker compose logs`.

### M7. El reemplazo de `sqlite-vec` y la arquitectura

- `_qmd_swap_sqlite_vec` (`qmd_index.sh:128-144`) solo conoce `node_modules/sqlite-vec-linux-arm64/vec0.so` y retorna en silencio si no existe.
- Sonda ejecutada en el host el 14-10-2026 con la función real contra prefijos falsos: con la disposición x64 devuelve 0, no registra nada y deja intacto el prebuilt glibc; con la de arm64 lo reemplaza y registra `swapped glibc prebuilt for musl build`.
- `sqlite-vec@0.1.9` y `@tobilu/qmd@2.5.3` declaran un paquete opcional por CPU (`cpu: x64`, `cpu: arm64`), sin campo `libc` (registro de npm, 14-10-2026).
- **Inferencia, no medida**: en el runner amd64 bun instala la variante x64, el reemplazo no ocurre, la extensión glibc no carga en musl (como se midió con la de arm64 en 017) y el embed falla por un defecto de producto.

### M8. La aserción de la línea 690 pasa en vacío

Ejecutada contra un archivo ausente: `strings` sale con 1, `grep -q` no encuentra nada y la rama `else` imprime `MUSL`, que es lo que la aserción espera.

### M9. GitHub Actions (documentación oficial, consultada el 14-10-2026)

- Expresiones: «A default status check of `success()` is applied unless you include one of these functions.» Un `if:` que incluye `!cancelled()` se evalúa aunque un paso anterior haya fallado.
- Contextos: «The `steps` context contains information about the steps in the current job that have an `id` specified and have already run.» y «When a `continue-on-error` step fails, the `outcome` is `failure`, but the final `conclusion` is `success`.»

### M10. Lo que congela 040 (rama `040-nightly-red-alert`, sin mergear)

`tests/nightly-alert.bats` exige que todo paso del job `e2e` tenga `id` (`:1415`), fija la lista exacta de ids `checkout,install_yq,install_bats,verify_deps,run_suite,collect` (`:1419`), el `if:` del paso de la suite (`${{ !inputs.alert_trial }}`, `:1952`), el `timeout-minutes` como expresión con el literal 30 (`:1956`) y los tres últimos ids (`:1958`). Su `collect` nombra como fallido el primer paso con `id` cuyo `outcome` sea `failure` o `cancelled` (`nightly-alert.sh:122`); no conoce solo `verify_deps` y `run_suite`.

### M11. shellcheck

El job de shellcheck (`shellcheck.yml`) revisa todo `*.sh` salvo `./.git`, `./scripts/vendor` y `./tests`. Un script nuevo en `.github/scripts/` entra al gate; uno en `tests/fixtures/` no.

### M12. bats

`BATS_TEST_COMPLETED` queda vacío al empezar cada test y vale 1 solo si el cuerpo terminó bien, tanto en 1.11.0, la versión que fija la CI (`bats-exec-test:338` y `:358`, leído del tag), como en 1.13.0, la local.

### M13. sha256 del texto `run:` congelado (yq v4.52.5, 14-10-2026)

- `Verify deps + docker`: `22d71bf880487e37158734312834a7c7d56b504c111b2ffe5f5f84a7a35e2abc`
- `Run docker-e2e suite`: `8c473b2e742d763a49bccd64d785305f3ba059d6087172d81af12ba1b120ca08`

Coinciden con los prefijos que registró 040. Se vuelven a verificar con el yq v4.44.3 de la CI antes del gate.

### M14. La colección de qmd y el documento del test (revisión independiente, 16-10-2026)

- `collection add … --mask 'wiki/**/*.md'` (`scripts/lib/qmd_index.sh:350` y `:479`): desde 037 la colección solo cubre `wiki/`. El esqueleto del vault trae `wiki/{comparisons,concepts,entities,normalization,overviews,summaries,synthesis}/` con solo `.gitkeep`, y `vault_seed_if_empty` (`scripts/lib/vault.sh`) copia el esqueleto solo cuando el destino está vacío.
- El Tier 2 de 016 escribía su documento en la raíz del vault, que era parte de la colección antes de 037 (máscara `**/*.md`). Nadie lo había ejecutado desde entonces. Movido tal cual a `qmd real (041)`, habría fallado en la fase de búsqueda semántica con un producto sano, y el rojo se habría podido clasificar como defecto de producto.
- Corrección: el vault se siembra antes del primer arranque con una página bajo `wiki/` (el setup embebe algo real) y el documento de la fase `reindex` va también bajo `wiki/`. El oráculo P1 lo vigila (D17).

### M15. `timeout` de busybox y los mensajes de bash (segunda revisión, 16-10-2026)

- Medido en `alpine:3.24` con busybox 1.37.0, el mismo que el contenedor: `timeout 2 sleep 10` envía TERM y sale con **143**; `timeout -s KILL 2 sleep 10`, con **137**; un hijo que ignora TERM (`trap "" TERM`) hace que un `timeout 2` a secas **espere a que el hijo termine por su cuenta** (6 s y rc 0), mientras que `timeout -k 1 2` lo mata con KILL a los 3 s (rc 137). GNU `timeout` diría 124. `timeout 5 env VAR=… cmd` entrega la variable al hijo. Un hijo huérfano mantiene abierta la tubería de `docker exec` aunque su padre muera: la salida va a un archivo y se hace `cat` después, como la fase `mcp`.
- La opción `-k` y la `-s` son de la misma versión que ya usan la fase `mcp` y `_qmd_run` (`timeout` a secas).
- Un redirect fallido de bash (`>> directorio`) imprime su mensaje traducido («línea») en el bash de Homebrew de esta Mac en español, **aun desde `env -i`**: gettext consulta el idioma preferido del sistema cuando `LANG` y `LC_*` no existen. Lo vio F12 al agregar la pierna del `GITHUB_ENV` que no se puede escribir. La CI, en inglés, no lo vería; el script fija `LC_ALL=C` para que sus mensajes sean ASCII en cualquier máquina (D18).

## Decisiones

### D1. Los modelos se obtienen en un paso propio del workflow

- **Decisión**: un paso `Fetch the qmd models` (`id: fetch_models`), después de `Verify deps + docker` y antes de la suite, que ejecuta `.github/scripts/fetch-qmd-models.sh`. El script baja y verifica los dos modelos de M2 en el directorio temporal del runner y deja el resultado en `$GITHUB_ENV`: `QMD_E2E_MODELS_DIR` si todo salió bien, o `QMD_EMBED_SKIP_REASON` si la fase no debe correr.
- **Razón**: FR-007 y la decisión del 14-10-2026 piden que una falla de red se lea en el paso fallido que nombra el aviso de 040, y el `collect` de 040 nombra cualquier paso con `id` (M10). Un script aparte es lo que el host puede probar sin Docker ni red (FR-016).
- **Alternativas descartadas**: (a) dejar que qmd descargue dentro del contenedor, como hoy: la falla se lee como del embed (contra FR-007); (b) un test de bats que descarga: el aviso nombraría `run_suite` y no la obtención; (c) `QMD_EMBED_MODEL=/ruta`: cambia el camino de código y el modelo que queda registrado en el índice respecto de producción.

### D2. Los modelos llegan al contenedor por el directorio que qmd ya usa

- **Decisión**: el test enlaza (hard link, o copia si no se puede) cada archivo verificado en `<workspace>/.state/.cache/qmd/models/` con el nombre local de M4, antes de `docker compose up`.
- **Razón**: es el mismo camino de código que en producción (`hf:` + directorio de modelos), y `resolveModelFile` lo usa sin red (M4). El enlace evita duplicar 1,6 GB en el disco del runner.
- **Vigilancia**: al final de la fase, el directorio debe tener exactamente los archivos sembrados, con cualquier extensión (un temporal de descarga también cuenta), con el mismo inodo y sin modificaciones posteriores a la siembra. Si qmd volviera a descargar, el test lo nombra.

### D3. Integridad: tamaño y sha256 fijados, descarga desde `main`

- **Decisión**: cada archivo se baja a `<nombre>.part` y se acepta solo si su tamaño y su sha256 coinciden con la tabla; después se renombra. Se baja de `resolve/main`, igual que qmd en producción.
- **Razón**: si el archivo cambia en origen, producción bajaría el nuevo y el nightly lo nota en vez de probar uno viejo (FR-012). Fijar el commit de HuggingFace sería reproducible, pero ciego a esa deriva; los commits de M2 quedan anotados como referencia. Un archivo con el tamaño esperado y otra suma es justamente esa deriva: no se reintenta y se nombra como cambio en origen (D4).

### D4. Reintentos acotados y un presupuesto total (FR-008)

- **Decisión**: hasta 3 intentos por modelo, con esperas de 10 s y 30 s, `curl --fail --location` con aborto por estancamiento (menos de 1 MiB/s durante 30 s) y un **presupuesto total de 480 s** para toda la obtención, que también recorta el `--max-time` de cada intento. Un tamaño distinto cuenta como intento fallido. El mismo tamaño con otro sha256 es un cambio del modelo en origen: no se reintenta, y el script sale con 1 y un motivo propio que pide revisar la tabla (decisión del operador del 16-10-2026). Si un modelo agota sus intentos o el presupuesto, el script escribe la razón y sale con 1.
- **Razón**: una falla transitoria no enrojece la noche, una persistente sí (decisión del 14-10-2026), y el peor caso queda acotado: 480 s más una suite sin embed (15 min 29 s, M1) suman 23 min 29 s, con margen bajo el tope de 30. A la velocidad típica de la CDN las dos descargas toman segundos o pocos minutos; no está medido en el runner.

### D5. Fuente única de la identidad de los modelos (FR-012)

- **Decisión**: una tabla de dos filas al inicio del script (`nombre|repo|archivo|nombre local|bytes|sha256`) más la constante `QMD_MODELS_QMD_VERSION=2.5.3`, que declara para qué versión de qmd se verificó la tabla. Un guard del host compara esa constante con la versión por defecto de `qmd_pkg` (`qmd_index.sh:56`) y comprueba que cada nombre local siga la regla de M4. `docs/qmd-upgrade-checklist.md` agrega el paso de revisar la tabla.
- **Razón**: un cambio del pin de qmd puede cambiar los modelos. El guard obliga a revisarlos, siguiendo el patrón de `tests/qmd-version-guard.bats`. La constante no es un pin nuevo de qmd, sino el registro del emparejamiento, y el guard impide que derive (Principio VI).
- **Consolidación**: el `agent.yml` del e2e repetía `version: "2.5.3"` como literal, sin guard. El asistente `_qmd_real_ws` toma esa versión de `qmd_pkg`, así que el nightly corre la misma versión que vigila G1 (Principio VI: un duplicado existente se consolida al tocarlo).

### D6. La puerta y el interruptor de defecto abierto

- **Decisión**: el paso de la suite declara `QMD_EMBED_E2E: '1'` (la puerta, visible en el workflow). El paso `fetch_models` declara `QMD_EMBED_DEFECT: ''`. Si ese valor no está vacío, debe empezar con `#<número>` o con la URL de un issue; entonces el script no baja nada, escribe `QMD_EMBED_SKIP_REASON` con el defecto y sale con 0 (FR-014). Un valor sin esa referencia es un error de configuración (sale con 1).
- **Razón**: apagar la fase por un defecto conocido no debe poner roja la noche, pero sí debe nombrar el defecto y su seguimiento. Exigir la referencia hace cumplir el «registrado» de FR-014.

### D7. La suite corre aunque falle la obtención

- **Decisión**: el paso de la suite gana `if: ${{ !cancelled() && steps.verify_deps.outcome == 'success' }}`, y `Verify deps + docker` gana `id: verify_deps`. Ninguno de los dos cambia su `run:`.
- **Razón**: sin eso, una falla de HuggingFace dejaría a las otras 48 pruebas sin correr (M9: el `success()` implícito salta los pasos siguientes). Con eso, la noche queda roja por `fetch_models` y el resto del producto se sigue verificando, con la fase del embed saltada por el motivo que dejó el script.
- **Alternativa descartada**: `continue-on-error` en la obtención más un paso final que falle: agrega un paso y obliga a las mismas enmiendas de 040 (M10).

### D8. Estructura del test

- **Decisión**: la fase del embed sale de `qmd real (016)` (que conserva su nombre, su fase A y su detección RED) a un test nuevo, ubicado justo después: `qmd real (041): embed phase - setup, models, vector extension, reindex, semantic search, MCP`. La primera instrucción del test nuevo es la puerta: si `QMD_EMBED_E2E` no vale 1 o hay un `QMD_EMBED_SKIP_REASON`, hace `skip` con el motivo antes de cualquier llamada a Docker. Con la puerta abierta exige `QMD_E2E_MODELS_DIR`; si falta, falla con un mensaje que lo nombra, porque abrir la puerta sin los modelos es un error del arnés y no un salto. El workspace de cada test se arma con un asistente común, extraído del setup del test 016.
- **Costo conocido**: el test nuevo usa un `.state` propio, así que repite el `bun install` con la compilación de llama.cpp (M5), dentro de su fase `setup`; la cota medida es de 288,5 s (M1). Si la primera corrida deja menos de 5 minutos de margen, se sube el tope y se vuelve a medir (FR-013; decisión del operador del 16-10-2026). Compartir el prefijo ya compilado entre los dos tests queda como mejora posterior, solo con medición, porque acopla los tests: el 041 corrido solo con `-f` se comportaría distinto.
- **Alternativas descartadas**: un solo test (bats no permite saltar una parte, y FR-005 exige el salto visible); estado compartido desde el principio (acopla los tests antes de medir que haga falta).

### D9. Marcas de fase y volcado al fallar (FR-004)

- **Decisión**: antes de cada fase el test imprime por el descriptor 3 una línea `# qmd embed phase: <nombre>`, en este orden: `models-seed`, `boot`, `setup`, `vector-extension`, `reindex`, `semantic-search`, `mcp` y `models-untouched`. Si el test falla (`BATS_TEST_COMPLETED` vacío y no saltado, M12), el `teardown` vuelca una vez `docker compose logs --tail=150` antes de bajar el proyecto.
- **Razón**: la última marca antes del `not ok` nombra la fase sin reproducir nada en local, y las marcas son comentarios TAP: el resumen de 039 y el `collect` de 040 no las cuentan.
- **Atribución**: cada marca precede al comando que define su fase y queda antes de la marca siguiente. El oráculo P1 lo verifica sobre el cuerpo del test; una marca puesta después de su comando atribuiría la falla a la fase anterior.

### D10. La comprobación de la extensión vectorial no depende de la arquitectura (FR-003)

- **Decisión**: un script POSIX `tests/fixtures/qmd-e2e/vec0-libc.sh <prefijo>` busca `node_modules/sqlite-vec-linux-*/vec0.so` y responde `MUSL` (rc 0), `GLIBC` (rc 1, si el archivo contiene `GLIBC_`), `ABSENT` (rc 2) o `AMBIGUOUS <n>` (rc 3). El test lo ejecuta dentro del contenedor con `sh` (busybox) y el oráculo del host, también con `sh`, contra prefijos falsos.
- **Razón**: la aserción de hoy mira solo `linux-arm64` y pasa en vacío (M8). `grep -q` sobre el archivo, sin tubería, evita depender de `strings` y la carrera de `grep -q` bajo `pipefail`.

### D11. El setup falla rápido cuando el log ya dijo qué falló

- **Decisión**: el ciclo de espera del centinela (600 s por defecto, configurable con `QMD_E2E_SETUP_DEADLINE_S`) lee en cada vuelta `docker compose logs`. Si encuentra `[qmd] setup: '<paso>' failed` o `[qmd] install: bun install failed`, termina de inmediato y falla nombrando el paso.
- **Razón**: según la inferencia de M7, la falla más probable de la primera corrida en amd64 es exactamente esa. Esperar 600 s para luego decir «setup» gasta 10 minutos y esconde el paso (M6).
- **Límite conocido**: los saltos del setup que no escriben el centinela ni una línea de falla (`vault not resolvable`, `already running`, `bun unavailable`) no cortan la espera. En este arnés son inalcanzables (la imagen trae bun, el vault se siembra antes del arranque y el cron no corre, D18) y, si ocurrieran, el rojo llega por el plazo. Una lista cerrada de esas frases en la expresión del ciclo no se agregó: dejaría fuera `already done` y `completed by a concurrent run`, que son éxitos, y no tiene un caso alcanzable que la pruebe.

### D12. La variable `CI` y el directorio de modelos, verificados al arrancar

- **Decisión**: la fase `boot` comprueba dentro del contenedor que `CI` no tenga valor y que `XDG_CACHE_HOME` no esté definida o apunte a `$HOME/.cache`. Si alguna condición no se cumple, falla nombrando la variable.
- **Razón**: con `CI` definida, qmd hace fallar el embed con un mensaje que parecería una regresión (M3). Con otro `XDG_CACHE_HOME`, la siembra de D2 caería en un directorio que qmd no lee.

### D13. Oráculos del host (FR-016, FR-017)

- **Decisión**: un archivo nuevo, `tests/qmd-embed-nightly.bats`, con seis grupos: W (estructura del workflow), F (script de obtención, con un `curl` falso y una pierna con el `curl` real contra un servidor local de Python), V (`vec0-libc.sh`), K (la semántica de salto del test real, ejecutado con bats anidado y con `docker` y `curl` sustitutos que registran cada llamada), G (guards de identidad) y P (orden de las marcas de fase). El contrato está en [contracts/host-oracle.md](contracts/host-oracle.md); las mutaciones que cada test caza, en [quickstart.md](quickstart.md).
- **Razón**: cada requisito de FR-016 tiene un test que se puede ver en rojo sin Docker. `tests/ci-workflows.bats` (039) no se edita: sus S1 a S6 siguen verdes porque el `run:` no cambia y S6 solo exige `DOCKER_E2E=1`.

### D14. Secuencia de evidencia, con compuertas (FR-020)

- **Decisión**: E1, corrida manual sobre la rama con la fase activa. Se clasifica el resultado y se registran la duración, el margen (FR-013), los tiempos de obtención, el disco libre y la arquitectura. Si E1 muestra un defecto de producto: el operador abre el issue de seguimiento, se fija `QMD_EMBED_DEFECT` y E2 confirma el salto con el motivo y el resto de la suite en verde. E3, una rama de ensayo que no se mergea, con la URL de un modelo apuntando a un archivo inexistente: la noche queda roja en `fetch_models`, la suite corre y la fase sale saltada. E4, solo si el embed pasó en amd64: una rama de ensayo con la fase rota a propósito (por ejemplo, la imagen construida sin la toolchain), para ver la noche roja con la fase nombrada. Si E1 no llega a la fase `models-untouched`, un DOCKER_E2E local en arm64 ejecuta las fases que faltaron, y es obligatorio antes del PR (decisión del operador del 16-10-2026): sin él, el código nuevo de esas fases se mergearía sin haber corrido nunca. Cada push, cada `workflow_dispatch`, el issue, el PR y el merge piden confirmación del operador.
- **Razón**: lo no medido se mide primero (spec, Assumptions), y la decisión de FR-014 se toma antes del merge.

### D15. Interacción con 040

- **Decisión**: la rama que mergee segunda rebasa. Si 041 rebasa sobre 040, el paso `fetch_models` gana `if: ${{ !inputs.alert_trial }}` (los ensayos de 040 no bajan 1,6 GB), el `if:` de la suite pasa a `${{ !inputs.alert_trial && !cancelled() && steps.verify_deps.outcome == 'success' }}`, y se enmiendan de forma explícita `tests/nightly-alert.bats:1419` (la lista de ids gana `fetch_models` entre `verify_deps` y `run_suite`) y `:1952` (el `if:` combinado), además de los tests W de 041. Si hubiera que subir el tope, se cambia el literal 30 de la expresión de `:1956`.
- **Razón**: los dos oráculos describen el mismo archivo. Declararlo evita que una enmienda se lea como debilitamiento.

### D16. Presupuesto de tiempo (estimación, no medida)

| Camino | Suma | Margen frente a 30 min |
| --- | --- | --- |
| Obtención fallida (peor caso acotado) | 15 min 29 s (M1) + 8 min (D4) | 6 min 31 s |
| Normal, estimado | 15 min 29 s + obtención (no medida; segundos a minutos) + fase del embed (compilación de hasta 288,5 s, M1, más setup, reindexado, `vsearch` con la expansión en CPU y MCP con tope de 25 s) | no medido; podría quedar bajo 5 min |
| Setup colgado sin línea de falla | 15 min 29 s + obtención + compilación + 600 s de espera | podría exceder el tope |

- **Decisión**: no se sube el tope antes de medir (decisión del 14-10-2026). E1 mide; si el margen queda bajo 5 min, se sube el tope y se vuelve a medir (decisión del 16-10-2026). Compartir el prefijo compilado es una mejora posterior (D8). El caso del setup colgado se acota bajando `QMD_E2E_SETUP_DEADLINE_S` a un valor medido en E1 (el doble del setup observado), no a ciegas.

### D17. El oráculo exige las aserciones del cuerpo del test, no solo sus comandos

- **Decisión**: P1 comprueba, para cada fase, el comando que la define (ancla) **y el texto de las aserciones de su resultado**, que las fases que informan una falla la terminan con `false`, que `_embed_phase` imprime por el descriptor 3 y que las páginas del vault van bajo `wiki/` (M14).
- **Razón**: la revisión independiente mostró que se podía borrar `grep -qi 'gato'`, la comprobación de `MUSL`, la de `pending` o el `false` de `models-untouched` sin que cayera ningún test del host, porque el cuerpo no se ejecuta sin Docker. P1 es la única red. No cubre una aserción neutralizada (un `if false`), que es lo que los ensayos reales y la rotura inducida (E4) deben mostrar.
- **Alternativa no tomada, y por qué queda como propuesta**: llevar al repositorio el ensayo con un `docker` falso que se hizo en el scratchpad (el test corre entero sobre un contenedor emulado y se le provoca cada falla). Cierra también la clase «aserción neutralizada», pero agrega un fixture y alrededor de diez tests a la suite del host y cambia todos los conteos del plan; queda a decisión del operador.

### D18. Fases acotadas, evidencia al fallar y cron quieto (segunda revisión, 16-10-2026)

- **Decisión**: (1) `reindex` y `semantic-search` corren acotadas dentro del contenedor (`timeout -k 10 600` y `timeout -k 10 300`), con la salida a un archivo y la fase nombrada en el fallo (rc 124, 137 o 143, M15); (2) el `teardown` de un test que falla deja, además del log del contenedor, el estado que no se puede pedir después (`_embed_failure_state`: disco libre, `docker inspect` con `OOMKilled`, código de salida y reinicios, y dentro del contenedor `uname -m`, el veredicto de `vec0-libc.sh`, los paquetes `sqlite-vec-linux-*`, los contadores de memoria del cgroup y los archivos de estado y de salida del reindex y de la búsqueda: `qmd-index.json`, `qmd-reindex.out` y `vsearch.out`); (3) el workspace de los tests reales programa el cron de respaldo de qmd el 31 de febrero (`0 0 31 2 *`); (4) el plazo del setup se normaliza a decimal; (5) el informe de `models-untouched` lleva su `#` en cada línea (`_embed_note`); (6) el script fija `LC_ALL=C`, devuelve el estado de su escritura en `$GITHUB_ENV`, rechaza tamaños con cero a la izquierda, no culpa a `QMD_MODELS_DIR` cuando nadie lo definió y conserva la causa cuando se agota el presupuesto.
- **Razón**: el cuerpo del test no se ha ejecutado nunca contra un contenedor y su primera corrida real (E1) es una medición con compuerta cuyo resultado más probable es un rojo en amd64. Sin plazo propio, un `vsearch` o un reindex colgados cancelan el job a los 30 min: la noche queda roja sin fase, sin `e2e summary:` y sin el resto de la suite (33 de los 49 e2e corren después de este archivo). Sin el estado al fallar, un rojo en `setup` no distingue ENOSPC, OOM y el paquete x64 glibc, y cada sonda extra cuesta una corrida de unos 15 minutos. El cron `*/5` dejaba una ventana de unos 6 a 10 s entre el centinela y el reindex (cerca de un 3 % por noche; inferido, no medido) en que el cron tomaba el lock y el reindex manual salía con 0 sin escribir `qmd-index.json`: un rojo falso que dispara el aviso de 040.
- **Alternativas descartadas**: un `BATS_TEST_TIMEOUT` global (cortaría el test 041 completo, que es largo a propósito); un `timeout` del host alrededor de `run` (mata al cliente de `docker exec` y deja el proceso vivo en el contenedor); un plazo por variable de entorno y por fase (más perillas que probar); reintentar el reindex hasta que el hash cubra `gatos.md` (más código para una carrera que ya no existe sin el cron); la sonda de `vec0-libc.sh` solo en las dos ramas de fallo del setup (el `teardown` cubre cualquier fase).
- **Residuos aceptados, sin arreglo**: el sembrado con enlace duro deja que el contenedor modifique el archivo ya verificado de origen, cosa que `models-untouched` detecta al final y que en el nightly es efímera; un modelo reemplazado en origen con otro tamaño se reintenta como una descarga truncada (el motivo lleva ambos tamaños); los saltos del setup sin reintento (D11); los pasos sin plazo propio (el `build` y el `up` del arranque, los `exec` de la comprobación de `CI` y de `XDG_CACHE_HOME`, `vector-extension`, `models-untouched` y el `docker exec` de cada vuelta del sondeo del setup: un cuelgue ahí lo corta el tope del job); y el motivo `budget (<N>s)` sin `tras:` cuando el primer modelo se baja bien pero consume todo el presupuesto y el segundo no llega a intentarse.
- **Propuesta al operador, no un cambio**: si la suma de la obtención, dos compilaciones nativas y el embed pasa de 30 min, E1 se corta y llega sin `e2e summary:`. Para medir la duración completa en una sola corrida se puede correr E1 desde un commit de ensayo con `timeout-minutes: 45` en una rama que no se mergea; la rama que se mergea conserva 30 hasta que T033 lo decida con los números (D16).
- **Tercera revisión (16-10-2026)**: workflow `wf_5d3c4ca1-dc7`, tres lentes de solo lectura sobre lo que cambió la segunda (el script, el cuerpo del e2e y la deriva documental) y un escéptico por hallazgo: 11 hallazgos, 1 MEDIA y 10 BAJAS, todos confirmados. Arreglados con su ROJO visto antes: el estado al fallar no traía el estado ni la salida del reindex y de la búsqueda, que es donde queda la causa de una falla que no es un plazo; el informe de un plazo vencido mostraba el comienzo de la salida (`${output:0:400}`) y no su final, y no decía cuánto corrió el comando (ahora `SECONDS - t0` y `_embed_tail`, con `tail`: el corte `${x: -N}` que sugería el hallazgo da una cadena vacía cuando el valor es más corto que N, medido en bash 3.2 y 5.x); la rama del defecto abierto ignoraba el estado de su escritura en `$GITHUB_ENV` (las dos ramas pasan ahora por `emit_env_or_stop`); y la checklist citaba un encabezado que el test no imprime con ese cierre (G3 lo ata al archivo del test). El resto fue deriva documental. Aceptado: el motivo `budget (<N>s)` sin `tras:` cuando el primer modelo consume el presupuesto, y los pasos sin plazo propio (arriba).
