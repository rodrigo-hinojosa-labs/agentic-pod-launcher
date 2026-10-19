# Research: El embed de qmd funciona en la imagen docker sobre amd64 y el nightly vuelve a ejercitarlo

**Feature**: 042-qmd-sqlite-vec-x64 | **Fecha**: 2026-10-18 | **Spec**: [spec.md](spec.md)

Fase 0 del plan. Toda afirmación de este documento se leyó del código publicado o se ejecutó el 18-10-2026; lo que no, está marcado como inferencia. Las herramientas de medición son del scratchpad de la sesión (no se versionan): `research_ab.sh`, `research_cdf.sh` y `research_d_simd.sh`.

## Mediciones

### M1. Cómo `sqlite-vec` 0.1.9 resuelve la extensión (leído del paquete publicado)

- Los metadatos del registro de npm declaran **cinco paquetes opcionales** de plataforma, cada uno con `os` y `cpu` y **sin campo `libc`**: `sqlite-vec-linux-x64`, `sqlite-vec-linux-arm64`, `sqlite-vec-darwin-x64`, `sqlite-vec-darwin-arm64` y `sqlite-vec-windows-x64`. Por eso el gestor de paquetes instala la variante glibc en Alpine (lo que E1 vio).
- `index.cjs` e `index.mjs` arman el nombre con `process.platform` y `process.arch`: `sqlite-vec-${os}-${arch}` (con `windows` en lugar de `win32`) y resuelven `<paquete>/vec0.so`. En Linux las dos arquitecturas válidas son `x64` y `arm64` (la lista `supportedPlatforms`); cualquier otra lanza `Unsupported platform for sqlite-vec`.
- Tamaños del `vec0.so` glibc publicado: 159.816 bytes (x64) y 156.520 bytes (arm64). El de x64 coincide con el que el volcado de E1 listó dentro del contenedor.

### M2. Cómo lo carga qmd 2.5.3 (leído del paquete publicado)

`dist/db.js:37-52` importa `sqlite-vec` y usa `getLoadablePath()` o `sqliteVec.load(db)`; si falla, deja `_sqliteVecLoad = null` y la operación vectorial lanza `sqlite-vec extension is unavailable` (`db.js:67-72`). `dist/store.js:567-658` captura el fallo al abrir la base y avisa con `console.warn` el mismo texto (el que E1 mostró). Conclusión: el archivo que carga qmd es `node_modules/sqlite-vec-linux-<arch>/vec0.so` dentro del prefijo gestionado, el mismo que el reemplazo debe tocar.

### M3. Qué dice `uname -m` en cada plataforma (ejecutado)

| Plataforma | `uname -m` | Otros datos |
| --- | --- | --- |
| macOS en Apple Silicon (este Mac) | `arm64` | `process.arch` de Node: `arm64` |
| Alpine 3.24.1, contenedor `linux/arm64` | `aarch64` | `apk --print-arch` = `aarch64`; cargador `/lib/ld-musl-aarch64.so.1` |
| Alpine 3.24.1, contenedor `linux/amd64` | `x86_64` | `apk --print-arch` = `x86_64`; cargador `/lib/ld-musl-x86_64.so.1` |

**Documentado, no medido**: el valor de `process.arch` en Linux (`x64` y `arm64`), con el que el cargador de `sqlite-vec` arma el nombre del paquete, es comportamiento documentado de Node; en esta sesión solo se midió `process.arch` en macOS (`arm64`), no dentro de un contenedor Linux, y que el runtime con que corre qmd en la imagen devuelva lo mismo es una inferencia. Lo que sí está leído en el paquete publicado es la lista `supportedPlatforms` de Linux (M1), y el mapa de abajo coincide con ella.

Consecuencia: el mapa hacia el nombre del paquete debe aceptar `x86_64` y `amd64` (este último, por robustez) como `x64`, y `aarch64` y `arm64` como `arm64`. El oráculo corre en ubuntu amd64 y en macOS arm64 de la CI, así que no puede depender de la arquitectura del host (D4).

### M4. La build musl en amd64 (ejecutado: el script de producción, tal cual)

El script `docker/scripts/build-sqlite-vec.sh` se montó de solo lectura en un contenedor `alpine:3.24.1` `linux/amd64` (emulado en este Mac arm64) con `build-base` y `sqlite` instalados, y se ejecutó sin cambios:

- descargó el amalgamation v0.1.9 y su suma coincidió con el pin del script (`3acd67cb...cf61`, `amalg.tar.gz: OK`);
- compiló en 8 s y horneó `/opt/agent-admin/sqlite-vec/vec0.so`: 151.536 bytes, ELF64 `Advanced Micro Devices X86-64`, `NEEDED` `libc.musl-x86_64.so.1`, **0 símbolos `GLIBC_`** (la guarda del script se cumple);
- el mismo script corrió en el build de la imagen de E1: el paso `RUN if [ "1" = "1" ]; then ... sh /opt/agent-admin/scripts/build-sqlite-vec.sh; fi` aparece en el log como `CACHED` y el build terminó.

Resuelve lo que el spec trataba como incógnita (que la build musl exista en la imagen amd64): se compila bien en amd64 y existe en la imagen del runner, porque `qmd real (016)` exige que `/opt/agent-admin/sqlite-vec/vec0.so` exista y no lleve `GLIBC_` (`tests/docker-e2e-qmd.bats:705-706`) y pasó en amd64 en E1 (`specs/041-nightly-qmd-embed/tasks.md:399`); el volcado de E1 no la listó.

### M5. Las rutas SIMD del amalgamation (leído)

Las rutas vectorizadas solo se activan con `-DSQLITE_VEC_ENABLE_AVX` o `-DSQLITE_VEC_ENABLE_NEON` (`sqlite-vec.c:123`, `:163`, `:393-455` y `:10044-10049`). El script de compilación no pasa ninguna, así que arm64 y x86_64 compilan la misma ruta escalar: el comportamiento es el mismo y no hacen falta banderas por arquitectura.

### M6. Carga real de la extensión en un Alpine amd64 (ejecutado, con el CLI `sqlite3` de Alpine)

| Caso | Resultado |
| --- | --- |
| La build musl horneada (`/opt/agent-admin/sqlite-vec/vec0`) | carga y `select vec_version()` devuelve `v0.1.9` (rc 0) |
| El `vec0.so` glibc del paquete `sqlite-vec-linux-x64` publicado (24 símbolos `GLIBC_`, `NEEDED` `libc.so.6`) | `Error relocating .../vec0.so: __memcpy_chk: symbol not found` (rc 1), la misma clase de falla de 017 y de E1 |
| La build musl copiada sobre la ruta `node_modules/sqlite-vec-linux-x64/vec0.so` (el efecto del reemplazo) | carga y devuelve `v0.1.9` (rc 0) |

Es el mecanismo del arreglo, medido de punta a punta sin qmd ni llama.cpp, en 58 s entre pull y todo. **Límite**: no prueba la función real ni el resto del embed (compilación de llama.cpp, modelos); eso lo prueban el oráculo del host (la función) y el DOCKER_E2E (el embed).

### M7. Superficie del cambio (leído con `git grep`)

- Código: solo `scripts/lib/qmd_index.sh`: la función `_qmd_swap_sqlite_vec` (líneas 128 a 144; su comentario ocupa las 122 a 127, y el comentario de `QMD_VEC0_MUSL_SO`, de las 105 a 111, también nombra la ruta arm64) y su única llamada, al final de `_qmd_ensure_prefix` (línea 227). No hay copia versionada en `docker/scripts/lib/`: `setup.sh::mirror_catalog_to_docker` la genera al andamiar, y el Dockerfile la copia con una línea `COPY`. No hay nada que sincronizar en el repositorio.
- Pruebas que mencionan la ruta arm64 o la función: `tests/qmd-sqlite-vec.bats` (cinco pruebas de la función, todas con la disposición arm64, y dos de guarda de versiones) y, desde el merge de 041 (#108), la prueba P1 de `tests/qmd-embed-nightly.bats`, cuya aserción negativa de la línea 862 exige que el cuerpo de `qmd real (041)` (comentarios incluidos) no contenga `sqlite-vec-linux-arm64`. `tests/docker-e2e-qmd.bats` ya no nombra la ruta arm64: la fase `vector-extension` de `qmd real (041)` verifica con `vec0-libc.sh`, que busca `node_modules/sqlite-vec-linux-*/vec0.so` sin fijar la arquitectura y falla si el archivo falta o si hay más de uno. `tests/qmd-index.bats` y `tests/qmd-setup.bats` no la mencionan; en un host glibc la función sale antes de mirar la arquitectura, así que no se alteran.
- Documentos con la ruta arm64 o con la descripción del reemplazo: `docs/qmd-upgrade-checklist.md` (líneas 32 a 35 y 66 a 69), `docs/architecture.md` (línea 336), `docs/vault.md` (línea 539, el párrafo de las líneas 540 a 541 y el paso 3 del diagnóstico de las líneas 697 a 699, que atan `vector embed unavailable, lexical index intact` a una sola causa: con L-PKG y L-ARCH ese cierre deja de identificarla) y el comentario de cabecera de `docker/scripts/build-sqlite-vec.sh` (líneas 5 y 6); `docs/adding-an-mcp.md:288` solo cita la función y no cambia. CLAUDE.md y CHANGELOG.md llevan las viñetas que 041 dejó.

## Decisiones

### D1. Cómo se decide la arquitectura

**Decisión**: `uname -m` pasado por un mapa explícito: `x86_64` y `amd64` dan `x64`; `aarch64` y `arm64` dan `arm64`; cualquier otro valor (o vacío) es una arquitectura no soportada. Se consulta solo después de comprobar que la máquina es musl, para no bifurcar un proceso en glibc.
**Razón**: es el mapa que usa el cargador de `sqlite-vec` (las plataformas de Linux que publica son `x64` y `arm64`: M1; que `process.arch` valga eso en Linux es comportamiento documentado de Node, no una medición de esta sesión: M3), funciona en busybox y no necesita ninguna herramienta que la imagen no tenga.
**Alternativas descartadas**: deducirla del nombre del cargador musl (`/lib/ld-musl-<arch>.so.1`), porque el seam `QMD_MUSL_LOADER` de las pruebas es un archivo de nombre arbitrario; preguntarle a bun (`process.arch`), por el costo y la dependencia; comparar la cabecera ELF del paquete con la de la build (`readelf` o `file`), porque esas herramientas solo están en la imagen bajo la toolchain.

### D2. Qué paquete se toca

**Decisión**: solo `node_modules/sqlite-vec-linux-<x64|arm64>/vec0.so` del prefijo, el que corresponde a la arquitectura. Un paquete ajeno (por ejemplo, el arm64 en una máquina x86_64) no se toca jamás. La build horneada se compila en el build de la imagen, así que su arquitectura es la de la imagen y la de la máquina (`uname -m` dentro del mismo contenedor): el cruce que prohíbe FR-004 queda excluido por construcción.
**Razón**: FR-004. Un prefijo con los dos paquetes (un workspace llevado entre arquitecturas) debe quedar con el ajeno intacto.

### D3. Qué deja el log

**Decisión**: se conservan sin cambio los textos de "reemplazado", "build ausente" y "copia fallida" (FR-002 exige la misma línea en arm64) y se agregan dos líneas en ASCII para los caminos que hoy son callados: (L-PKG) falta el paquete de la arquitectura, con la lista de los `sqlite-vec-linux-*` que sí hay (`found: ninguno`, en inglés `none`, si no hay ninguno), y (L-ARCH) la arquitectura no está soportada. Las dos líneas nuevas terminan con el mismo cierre que la línea actual de build ausente ("vector embed unavailable, lexical index intact"); "reemplazado" no lleva cierre y "copia fallida" conserva el suyo ("vector embed may be unavailable"). Los textos exactos están en [contracts/swap-sqlite-vec.md](contracts/swap-sqlite-vec.md).
**Razón**: FR-005 y SC-003: el log debe bastar para diagnosticar sin una segunda corrida. La función corre en cada preparación del prefijo, o sea, antes de cada llamada a `_qmd_run` (varias por reindexado: `update` y, por pasada, `embed` y `status`) y de cada arranque del servidor MCP (`qmd_mcp_exec`), así que una condición persistente repite su línea; es la práctica actual de la línea "build ausente". En setup y reindex esas llamadas capturan su salida en archivos de registro, y la línea llega al log del contenedor solo dentro de la cola redactada de 500 bytes que `_qmd_tail_redacted` registra cuando la llamada falla; SC-003 se verifica en el host con prefijos falsos.

### D4. El seam de prueba y la hermeticidad

**Decisión**: una variable `QMD_MACHINE_ARCH`, con el valor que `uname -m` imprimiría, que si está definida reemplaza a `uname -m` (el mismo patrón que `QMD_MUSL_LOADER` y `QMD_VEC0_MUSL_SO`). El `setup()` de `tests/qmd-sqlite-vec.bats` la fija en `aarch64` por defecto para que las cinco pruebas existentes, que usan la disposición arm64, sigan valiendo en cualquier host.
**Razón**: sin ella, esas pruebas pasarían en el macOS arm64 de la CI y fallarían en el ubuntu amd64 (la clase de defecto que 025 midió: pruebas que suponen una propiedad del host). Y el camino real (sin seam) no puede quedar sin ejercer: una prueba pone un `uname` falso en el `PATH` y comprueba que la función lo consulta (D5).

### D5. Pruebas del host y mutaciones

**Decisión**: ampliar `tests/qmd-sqlite-vec.bats` test-first (ROJO visto antes del arreglo) con 11 pruebas nuevas, y fortalecer tres existentes: la del paquete ausente (E5), para que afirme el rastro en el log, y las dos que guardan en arm64 las líneas de hoy (FR-002): la del reemplazo (E1, la línea L-OK) y la del artefacto ausente (E3, la línea L-ABS, porque la palabra `unavailable` que afirmaba la comparten ahora otras ramas). Cada prueba tiene su mutación prevista (M1 a M15 del catálogo de [contracts/host-oracle.md](contracts/host-oracle.md), con M9 y M13 en variantes); el catálogo se ejecuta contra la implementación real, como en 041, y una mutación que sobreviva endurece el oráculo antes de seguir.
**Razón**: principio III. La clase de defecto de 041 ("una aserción que pasa en vacío") se previene midiendo que cada prueba cae con su mutación.

### D6. Versión y documentos

**Decisión**: `VERSION` 0.28.0 a 0.29.0 (MINOR, la práctica para las features que tocan runtime) verificado a mano contra `origin/main` tras cualquier rebase; entrada de CHANGELOG; corregir `docs/qmd-upgrade-checklist.md` (el ítem "017 swap path" nombra los dos paquetes y la regla `sqlite-vec-${plataforma}-${arquitectura}`), `docs/architecture.md`, `docs/vault.md` y el comentario de `build-sqlite-vec.sh`; y las viñetas de CLAUDE.md que 041 dejó (el reemplazo ya conoce las dos arquitecturas; el nightly vuelve a ejecutar la fase).
**Razón**: principio VI (cambios de cara al usuario en CHANGELOG y VERSION) y compuerta de documentación de la constitución.

### D7. Capas de verificación

| Capa | Qué prueba | Dónde | Costo | Compuerta |
| --- | --- | --- | --- | --- |
| V1. Oráculo del host | La función, con prefijos falsos (ambas disposiciones, los casos de FR-004 y FR-005, la idempotencia) | host, bash 5.x y 3.2 | segundos | no |
| V2. Humo local | La función REAL y el mecanismo, en un Alpine amd64 emulado (compila la build con el script de producción, deja un prefijo con el paquete x64 glibc publicado, corre `_qmd_swap_sqlite_vec` y carga la extensión con `sqlite3`) y, con lo mismo, una pata arm64 nativa que guarda la línea y el archivo de hoy (FR-002) | este Mac, contenedores desechables | unos 2 minutos | no (local, desechable) |
| V3. DOCKER_E2E arm64 local | El embed completo en arm64 sin cambio de resultado (SC-002) | este Mac, con los modelos de 041 | unos 9 min | no (local) |
| V4. CI amd64 con la fase activa | El embed completo en amd64, la duración y el margen (al menos 3 corridas) | GitHub Actions, `workflow_dispatch` en la rama | 20 a 30 min por corrida | push y dispatch con confirmación del operador |
| V5. Rotura inducida | Que una imagen del test sin toolchain deje el job en rojo con la fase nombrada | GitHub Actions, rama de ensayo | una corrida | push, dispatch y borrado de la rama, con confirmación |
| V6. Las tres noches | La fase activa en el nightly programado | GitHub Actions | tres noches | observación tras el merge |
| V7. Compuerta completa | `bats tests/` completo en bash 5.x y 3.2 y la CI del PR | host y GitHub Actions | unos 25 min por bash | no (local); abrir el PR con confirmación |

V2 es nueva y barata (M6); no se versiona (D11). V3 a V6 usan lo que 041 dejó en `main` (PR #108, squash `0fc08a8`): el test `qmd real (041)` (`tests/docker-e2e-qmd.bats:753`) y el interruptor `QMD_EMBED_DEFECT` (`.github/workflows/docker-e2e.yml:80`). La numeración es la de [quickstart.md](quickstart.md).

### D8. Medición del tope

**Decisión**: tres corridas por `workflow_dispatch` de la rama con el interruptor vacío; de cada una se lee `started_at` y `completed_at` del job por la API de jobs (no las fechas de la corrida) y se calcula el margen contra `timeout-minutes` (30). Si el margen mínimo es menor de 5 minutos, se sube el tope primero (propuesta: 45, el valor que usó la rama de ensayo de E1) en un commit aparte, y se vuelve a medir con tres corridas más. Los números van a las Notes de `tasks.md`.
**Razón**: decisión de 041 (medir primero, margen mínimo de 5 minutos, subir antes de dividir) y su observación de que los mismos 48 e2e variaron 29 % entre dos corridas: una sola medición no basta. Estimación gruesa, no medida: el job rojo de E1 ya duraba 21 min 19 s deteniéndose en `setup`, así que el margen con la fase completa puede quedar justo.

### D9. Qué se hace si aparece otro defecto

**Decisión**: la política de 041 (FR-013 del spec): se registra en un issue nuevo, el interruptor pasa a nombrarlo y se avisa al operador; no se mezcla con este arreglo. La excepción es la build musl horneada ausente en la imagen amd64 (el supuesto 2 del spec): si el log del contenedor dice `musl build absent`, no es otro defecto, es parte de este arreglo y se corrige aquí, con la revisión de privilegios del Principio II (el Dockerfile o `docker/scripts/build-sqlite-vec.sh`), su ROJO en el humo local y una corrida nueva. Los candidatos conocidos son las opciones de compilación de llama.cpp pensadas para ARM (`GGML_NATIVE=OFF` y `GGML_CPU_ARM_ARCH=armv8-a`, `qmd_index.sh:207-208`), cuya velocidad en x86_64 no se ha medido (E1 mostró que la compilación termina y que qmd arranca).

### D10. Orden de trabajo respecto de #108

**Decisión**: #108 (feature 041) ya está en `main` (squash `0fc08a8`, 19-10-2026), así que este plan y las tareas parten de `main` y la implementación no espera nada: se rebasa la rama sobre `origin/main`, y V3 a V6 y el vaciado del interruptor quedan disponibles. El único conflicto real del rebase es `.specify/feature.json` (041 lo dejó apuntando a `specs/041-nightly-qmd-embed`); `CHANGELOG.md`, `CLAUDE.md` y `docs/qmd-upgrade-checklist.md` solo chocarían si se editaran antes de rebasar, y 041 los tocó en otras líneas (en el checklist, las líneas 98 a 107 y 115 a 134). `VERSION` sigue en 0.28.0 en `origin/main` (041 no la cambió) y se verifica a mano tras el rebase (lección de 023: git no avisa de un VERSION que coincide en texto).

### D11. Propuesta abierta para el operador: llevar V2 al repositorio

Una prueba versionada con contenedor (un e2e de unos 60 s, que corra en la arquitectura nativa del host y del runner: compila la build, instala el paquete publicado de esa arquitectura, ejecuta la función y carga la extensión) daría una guarda barata y siempre activa del reemplazo en el nightly, incluso mientras un defecto abierto apague la fase del embed (que cuesta más de 6 minutos y 1,6 GB de modelos). Costo: un archivo de e2e nuevo, un conteo más (50 e2e) y una descarga de red por corrida. **No se incluye en 042** (ensancharía el alcance y la propuesta equivalente de 041, el docker falso, se difirió por la misma razón); si se quiere, es una mejora posterior sobre el mismo camino.

## Riesgos

1. **El embed completo en amd64 no está medido** (velocidad con las opciones de compilación de ARM, las cinco fases posteriores a `setup`, la duración): la primera corrida con el arreglo lo responde y D9 fija qué hacer si destapa otro defecto.
2. **V2 prueba el mecanismo, no el embed**: un verde de V2 no sustituye a V4.
3. **Rebase pendiente**: #108 ya está en `main` (squash `0fc08a8`, 19-10-2026); antes de V3, V4 y del vaciado del interruptor hay que rebasar esta rama sobre `origin/main` (conflicto previsto: `.specify/feature.json`).
4. **Un `QMD_MACHINE_ARCH` olvidado** en el entorno de un operador torcería la elección; la variable es un seam de pruebas, no se documenta como perilla y no se lee en ningún otro lugar.
5. **Residuo local de la Fase 0**: la variante `linux/amd64` de `alpine:3.24.1` (unos 4 MB) quedó en el Docker de este Mac; los contenedores fueron desechables (`--rm`).
