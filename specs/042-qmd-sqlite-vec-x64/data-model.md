# Data Model: El embed de qmd funciona en la imagen docker sobre amd64 y el nightly vuelve a ejercitarlo

**Feature**: 042-qmd-sqlite-vec-x64 | **Fecha**: 2026-10-18 | **Spec**: [spec.md](spec.md)

No hay datos persistentes nuevos. Las entidades del spec son archivos del prefijo gestionado de qmd y variables del entorno; este documento fija sus campos, la tabla de decisión del reemplazo y las transiciones de estado. Los textos exactos del log están en [contracts/swap-sqlite-vec.md](contracts/swap-sqlite-vec.md).

## 1. Máquina

Lo que la función necesita saber de donde corre.

| Campo | Origen | Valores |
| --- | --- | --- |
| `libc` | presencia de un cargador `/lib/ld-musl-*.so.1` (seam `QMD_MUSL_LOADER` en las pruebas) | `musl` o `glibc` |
| `arch` | `uname -m` (seam `QMD_MACHINE_ARCH` en las pruebas, con el valor que `uname -m` imprimiría) | `x86_64`, `amd64`, `aarch64`, `arm64`, otro, o vacío si `uname` falla |
| `sufijo` | mapa de `arch` | `x86_64` y `amd64` dan `x64`; `aarch64` y `arm64` dan `arm64`; otro valor (o vacío) da "no soportada" |

`uname -m` vale `arm64` en macOS, `aarch64` en un Alpine arm64 y `x86_64` en un Alpine amd64 (research M3).

## 2. Paquete de la extensión vectorial

Un directorio bajo `<prefijo>/node_modules/` que el gestor de paquetes instala según la CPU.

| Campo | Valor |
| --- | --- |
| Nombre | `sqlite-vec-linux-x64` o `sqlite-vec-linux-arm64` (las dos únicas variantes de Linux que `sqlite-vec` 0.1.9 publica) |
| Contenido relevante | `vec0.so`, un binario **glibc** (159.816 bytes en x64, 156.520 en arm64) |
| Quién lo elige | el cargador de `sqlite-vec` (`sqlite-vec-${os}-${arch}`, con `os` tomado de `process.platform` (`windows` en lugar de `win32`) y `arch` de `process.arch`), o sea, el mismo nombre que el sufijo de arriba |
| Cuántos hay | normalmente uno; un workspace llevado entre arquitecturas puede tener dos, o solo el ajeno |

## 3. Build musl horneada

| Campo | Valor |
| --- | --- |
| Ruta | `/opt/agent-admin/sqlite-vec/vec0.so` (variable `QMD_VEC0_MUSL_SO`, que las pruebas redefinen) |
| Origen | `docker/scripts/build-sqlite-vec.sh`, durante el build de la imagen y solo con `QMD_NATIVE_TOOLCHAIN=1` |
| Arquitectura | la de la imagen (compilada de forma nativa): ELF x86-64 en una imagen amd64, ELF aarch64 en una arm64 |
| Medido en amd64 | 151.536 bytes, `NEEDED` `libc.musl-x86_64.so.1`, 0 símbolos `GLIBC_` (research M4) |
| Puede faltar | sí: una imagen construida sin toolchain no la tiene |

## 4. Prefijo gestionado

`<qmd_cache_root>/pkg` (en producción `~/.cache/qmd/pkg`, bajo `.state`). Lo prepara `_qmd_ensure_prefix`, que llama al reemplazo al final de **cada** preparación, incluso cuando la instalación se saltó por hash.

## 5. Tabla de decisión del reemplazo

Evaluada en este orden; la primera fila que aplica decide. En todas las filas el estado de salida es 0 y nada se imprime por la salida estándar.

| # | libc | `arch` | Paquete de la arquitectura | Build horneada | Resultado | Línea de log |
| --- | --- | --- | --- | --- | --- | --- |
| D1 | glibc | cualquiera | cualquiera | cualquiera | no hace nada, sin cambios de archivos | ninguna |
| D2 | musl | no soportada, vacía o `uname` que falla | cualquiera | cualquiera | no toca nada | L-ARCH: arquitectura no soportada (rama defensiva) |
| D3 | musl | soportada | falta (haya o no otros `sqlite-vec-linux-*`) | cualquiera | no toca nada, ni los paquetes ajenos | L-PKG: falta el paquete, con lo encontrado |
| D4 | musl | soportada | presente | ausente | no toca nada | L-ABS: "build ausente" (texto actual, sin cambio) |
| D5 | musl | soportada | presente | presente e igual a `vec0.so` del paquete | no hace nada (idempotente) | ninguna |
| D6 | musl | soportada | presente | presente y distinta | copia la build sobre `vec0.so` del paquete y solo de ese | L-OK: "reemplazado" (texto actual, sin cambio) |
| D7 | musl | soportada | presente | presente y distinta, pero la copia falla | si la copia falla al abrir (permisos), deja el `vec0.so` como estaba; si falla a mitad de la escritura (disco lleno), puede quedar truncado hasta que la preparación siguiente lo reintente (`cp -f` reescribe en el sitio, como antes de 042) | L-CP: "copia fallida" (texto actual, sin cambio) |

Hoy (antes del arreglo) las filas D2 y D3 no existen: el destino está fijo en el paquete arm64 y, si ese archivo falta, la función sale sin decir nada; y en una máquina x86_64 con solo el paquete x64 ninguna de las filas D4 a D7 se alcanza, porque la salida callada las precede.

## 6. Transiciones de estado del paquete de la arquitectura

```text
glibc (recién instalado) --D6--> musl --(cada preparación siguiente: D5)--> musl
glibc (recién instalado) --D7--> glibc            (la copia falló: reintenta en la próxima preparación)
glibc (recién instalado) --D4--> glibc            (imagen sin toolchain: el índice léxico sigue; el vectorial no)
glibc (recién instalado) --D3--> (el paquete no existe)  (se informa; no hay nada que transicionar)
```

Una reinstalación del prefijo (cambio del manifiesto) vuelve a dejar el paquete en glibc; `_qmd_ensure_prefix` llama al reemplazo en su último paso (la llamada `_qmd_swap_sqlite_vec "$prefix"` justo antes del `return 0` final), dentro de esa misma preparación, así que el paquete vuelve a musl antes de que corra qmd. Solo si la instalación falla sin dejar el binario (el `return 1` tras el mensaje `install: bun install failed`) el reemplazo espera a la preparación siguiente.

## 7. Interruptor de defecto abierto (de 041, sin cambios de formato)

`QMD_EMBED_DEFECT` en el paso `fetch_models`: hoy `'#107 ...'`; esta feature lo deja en `''` (la fase corre). El formato y su validación son los de 041 (`.github/scripts/fetch-qmd-models.sh`).
