# Contrato: build del `vec0.so` musl (image build-time)

**Dónde**: `docker/Dockerfile`, dentro del bloque gateado por `QMD_NATIVE_TOOLCHAIN` (junto al de 016). Opcionalmente delegado a `docker/scripts/build-sqlite-vec.sh`.

## Entradas
- `ARG SQLITE_VEC_VERSION=0.1.9` (plumbeado desde compose `build.args`, como `QMD_NATIVE_TOOLCHAIN`).
- Toolchain de 016 presente (`build-base`/`cc`) cuando `QMD_NATIVE_TOOLCHAIN=1`.

## Comportamiento (MUST)
1. Si `QMD_NATIVE_TOOLCHAIN != 1`: **no** compilar; no hornear artefacto (el runtime degradará: embed no disponible, léxico intacto).
2. Si `=1`:
   a. `apk add --no-cache sqlite-dev` (provee `sqlite3ext.h`/`sqlite3.h`).
   b. Descargar `sqlite-vec-<VERSION>-amalgamation.tar.gz` desde el release oficial; **verificar `sha256`** contra un valor fijado; **fallar el build (fail-loud) si la descarga o el checksum fallan** (no producir imagen aparentemente completa).
   c. Compilar: `cc -O2 -fPIC -shared -Du_int8_t=uint8_t -Du_int16_t=uint16_t -Du_int64_t=uint64_t -I<sqlite3ext dir> -I. sqlite-vec.c -o vec0.so -lm`.
   d. Verificar en build que el binario es musl (p.ej. `ldd vec0.so` no menciona `ld-linux`; o `! strings vec0.so | grep -q GLIBC_`); fallar si no.
   e. Hornear a `/opt/agent-admin/sqlite-vec/vec0.so` (ruta de imagen, no enmascarada por `.state`).
   f. Limpiar (`apk del sqlite-dev`, borrar la fuente) para minimizar bloat; solo persiste `vec0.so` (~150KB).

## Salidas
- `/opt/agent-admin/sqlite-vec/vec0.so` — ELF musl aarch64, `vec_version()` = `SQLITE_VEC_VERSION`.

## Invariantes
- Determinista: misma `VERSION` + mismo checksum → mismo binario.
- No cambia el OS base ni el modelo de privilegios (Principle II).
- Sin secretos.
