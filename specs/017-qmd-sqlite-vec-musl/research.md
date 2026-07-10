# Research: qmd sqlite-vec en Alpine musl

Todas las decisiones de abajo están **verificadas empíricamente** en esta sesión (2026-07-10) sobre la imagen `agent-admin:qmd-real` (Alpine musl aarch64), no son inferencias. La evidencia bruta vive en los logs de los diagnósticos del gate DOCKER_E2E.

## R1 — Root cause: el prebuilt de sqlite-vec es glibc, no carga en musl

**Decision**: El muro del embed en musl es `sqlite-vec-linux-arm64@0.1.9` (prebuilt glibc), un tercer módulo nativo distinto de los dos que 016 atacó.

**Evidence**:
- `file node_modules/sqlite-vec-linux-arm64/vec0.so` → ELF aarch64; `ldd` → `Error loading shared library ld-linux-aarch64.so.1: No such file or directory` + `Error relocating … __memcpy_chk: symbol not found` / `__fread_chk: symbol not found`.
- `strings vec0.so | grep GLIBC` → `GLIBC_2.17`, `__memcpy_chk@GLIBC_2.17`, `__fread_chk@GLIBC_2.17`, `ld-linux-aarch64.so.1`. Binario glibc inequívoco.
- El error de runtime `vec0.so.so: No such file or directory` es un **red herring**: SQLite (`sqlite3_load_extension`) intenta el path verbatim `vec0.so` (dlopen falla por glibc), luego agrega el sufijo `.so` (`vec0.so.so` → no existe) y reporta el segundo error, enmascarando el fallo glibc-en-musl. Confirmado: `loadExtension('.../vec0')` (sin sufijo) da directamente `ld-linux-aarch64.so.1: No such file or directory` sobre `vec0.so`.
- `bun pm untrusted`: los únicos postinstalls bloqueados son los `tree-sitter-*` (node-gyp-build); **sqlite-vec NO está bloqueado** — su `.so` se instala bien; el problema es que es glibc, no que falte.
- node-llama-cpp (el "muro real" que 016 temía) descarga el modelo (333MB gguf) y **embebe sin SIGSEGV** una vez que sqlite-vec carga. No era el bloqueo del embed.

**Rationale**: Explica por qué falla en ferrari (docker/musl) y no en mclaren (local/glibc): en glibc el prebuilt carga sin más.

**Alternatives considered**: (descartadas por la evidencia) postinstall bloqueado — no lo está; bug de path en qmd — el `.so.so` es efecto del fallback de SQLite, no la causa; node-llama-cpp — embebe bien.

## R2 — Fix: compilar la amalgamación de sqlite-vec para musl con shim de typedefs

**Decision**: Compilar `vec0.so` desde la amalgamación oficial `sqlite-vec` v0.1.9 para musl, con el shim `-Du_int8_t=uint8_t -Du_int16_t=uint16_t -Du_int64_t=uint64_t`, y reemplazar el prebuilt glibc.

**Evidence (verificado)**:
- Comando: `cc -O2 -fPIC -shared -Du_int8_t=uint8_t -Du_int16_t=uint16_t -Du_int64_t=uint64_t -I<sqlite3ext.h dir> -I. sqlite-vec.c -o vec0.so -lm` → RC=0.
- `file`/`ldd` del binario resultante → enlaza contra `ld-musl-aarch64.so.1` / `libc.musl-aarch64.so.1` (musl puro, sin glibc, sin ld-linux).
- Cargado con better-sqlite3: `vec_version()` → `v0.1.9`; `CREATE VIRTUAL TABLE … USING vec0(...)` + insert + `MATCH … ORDER BY distance` → KNN funciona.
- Pipeline real (caché fresco, modelo descargado): `collection add` (2 docs) → `update` → `embed` → `✓ Done! Embedded 2 chunks from 2 documents in 24s` → `vsearch "animal encima del pc"` devuelve el doc "El gato duerme sobre el teclado del computador" con Score 42% (match **semántico**, sin solapamiento léxico).

**Por qué el shim es obligatorio**: `sqlite-vec.c` (líneas ~65-74) hace, en Linux no-wasi/no-cosmopolitan/no-emscripten:
```c
typedef u_int8_t uint8_t;
typedef u_int16_t uint16_t;
typedef u_int64_t uint64_t;
```
Asume los nombres BSD `u_int*_t` disponibles (glibc los expone vía `<sys/types.h>`). musl NO los expone — y `-D_GNU_SOURCE`/`-D_DEFAULT_SOURCE` no ayudan, porque `sqlite-vec.c` nunca incluye `<sys/types.h>`. Sin el shim, la compilación falla con `unknown type name 'u_int8_t'` y una cascada de `bitmap_copy`/`u8` (efecto del typedef roto). El shim `-Du_intN_t=uintN_t` mapea los nombres BSD a los C99 (ya definidos por `<stdint.h>`), volviendo esos typedefs no-ops legales (redefinición al mismo tipo, permitida en C11).

**Rationale**: sqlite-vec es un único `.c` amalgamado portable; compilarlo para musl es exactamente lo que hace upstream para producir sus prebuilts, solo que retargeteado. Bajo riesgo (C puro, deps mínimas: libc+libm).

**Alternatives considered**:
- Symlink `vec0.so.so → vec0.so`: NO sirve — el binario sigue siendo glibc; solo cambiaría el mensaje de error, no la carga.
- `-D_GNU_SOURCE`/`-D_DEFAULT_SOURCE`: verificado que NO resuelven (sqlite-vec no incluye `<sys/types.h>`).
- Compilar node-llama-cpp de otra forma: irrelevante, node-llama-cpp ya funciona (R1).

## R3 — Dónde/cuándo compilar y cómo gatear el swap

**Decision**: Compilar en **build-time** del Dockerfile (dentro del bloque gateado por `QMD_NATIVE_TOOLCHAIN`) y hornear a `/opt/agent-admin/sqlite-vec/vec0.so`. En runtime, `_qmd_ensure_prefix` copia ese artefacto sobre `node_modules/sqlite-vec-linux-arm64/vec0.so` del prefijo, gateado por **la presencia del artefacto horneado** (con salvaguarda de libc==musl).

**Rationale**:
- El prefijo gestionado vive bajo `~/.cache/qmd/pkg`, sobre el bind-mount `.state` que **enmascara** cualquier artefacto horneado dentro del prefijo. Por eso el binario se hornea en `/opt/agent-admin/` (ruta de la imagen, no enmascarada) y se copia en runtime — mismo patrón que `bigstack.so`.
- Build-time evita red en runtime y recompilación por cada aprovisionamiento; es determinista.
- **Gate por presencia del artefacto**: `/opt/agent-admin/sqlite-vec/vec0.so` solo existe en la imagen docker/musl (horneado con toolchain). En modo local, esa ruta no existe → no hay swap → se usa el prebuilt glibc (correcto para glibc). Autogateo natural. Salvaguarda secundaria: confirmar libc==musl (vía `_libc_variant` de 015-US2 o probe `/lib/ld-musl-*`) antes de reemplazar, para nunca clobberear un prefijo glibc con un `.so` musl en un host mixto.
- Idempotencia: `cp -f` del mismo artefacto determinista; re-ejecutable sin efectos.

**Headers en build**: `sqlite3ext.h`/`sqlite3.h` vía `apk add --no-cache sqlite-dev` en el bloque de build (removible con `apk del` tras compilar). Upstream compila sus prebuilts contra headers genéricos de SQLite (no los de better-sqlite3); replicamos eso. El DOCKER_E2E real (R4) es la red de seguridad que confirma que el `.so` compilado en build carga en el SQLite de better-sqlite3 en runtime.

**Alternatives considered**:
- Compilar en runtime en `_qmd_ensure_prefix`: descartado — necesita red + toolchain en runtime y recompila cada vez; frágil.
- Vendorizar `sqlite-vec.c` (~320KB) en el repo: descartado por bloat de repo; se prefiere descarga por URL de versión fija + `sha256` (determinista, Principle VI). Se documenta como fallback si el asset del release desaparece.
- Compilar contra los headers de better-sqlite3 en build: no disponibles en build (el prefijo se crea en runtime); innecesario dada la estabilidad del API de extensión de SQLite.

**Local musl (host Alpine local)**: fuera de alcance (no soportado/probado hoy; mclaren es glibc). Si en el futuro se soporta, requeriría un provisioning análogo en el bootstrap local. Documentado como edge case.

## R4 — Des-stub del DOCKER_E2E (embed+vsearch reales) y fix de la Fase A

**Decision**: El tier de embed (`QMD_EMBED_E2E=1`) corre el pipeline real `collection add → update → embed → vsearch` contra el path de producción (`_qmd_run`), asevera "Embedded" y un hit semántico, y falla (RED) si se construye con `--build-arg QMD_NATIVE_TOOLCHAIN=0`. La Fase A deja de usar `bunx @tobilu/qmd --help` directo y pasa a usar el prefijo gestionado.

**Rationale**: 016 pasó el merge porque el e2e nunca ejerció el binding real (stub de `bunx`, Fase A con `--help`). Ejercer `embed`+`vsearch` reales es lo que convierte el fix en garantía reproducible y cierra el gate que 016 saltó. El caso RED (toolchain off → sin artefacto horneado → embed no disponible) prueba que el gate discrimina.

**Alternatives considered**: mantener solo el arranque del MCP — insuficiente (no ejerce el binding vectorial); es lo que dejó pasar el bug.

## R5 — Guardrail de versión qmd ↔ sqlite-vec

**Decision**: Un test bats host fija el par (qmd `2.5.3` ↔ sqlite-vec `0.1.9`) leyendo el pin de qmd (`agent.yml`/default del wizard) y el `SQLITE_VEC_VERSION` del Dockerfile; falla si uno cambia sin el otro, forzando re-verificar la compilación musl.

**Rationale**: El fix compila una versión concreta de la amalgamación. Un bump de qmd puede arrastrar otra versión de sqlite-vec cuya fuente/typedefs cambien, invalidando el shim en silencio. Mismo patrón `wizard-prompt-test-touchpoints` (un cambio de pin rompe un test a propósito, obligando a actualizar deliberadamente). Cumple Principle VI (pins deliberados, no drift).

**Alternatives considered**: derivar la versión de sqlite-vec dinámicamente de qmd — descartado; el punto es justamente forzar revisión humana ante el cambio.

## Contexto heredado (no reabrir)

- qmd pin 2.5.3 single-source en `agent.yml vault.qmd.version`.
- Toolchain runtime gateado por `QMD_NATIVE_TOOLCHAIN` (016); `bigstack.so` LD_PRELOAD para node-llama-cpp (016).
- `TMPDIR` host-backed bajo `.state` (015-US3); observabilidad del reindex (015-US4); `_libc_variant` (015-US2).
- Libs espejadas `scripts/lib` ↔ `docker/scripts/lib` con COPY explícito; `mirror_catalog_to_docker` en `--regenerate`.
- Imagen Alpine single-stage (constitución) — este fix NO la cambia.
