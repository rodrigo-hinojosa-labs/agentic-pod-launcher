# Contrato: `_qmd_swap_sqlite_vec` (`scripts/lib/qmd_index.sh`)

**Feature**: 042-qmd-sqlite-vec-x64 | **Spec**: [../spec.md](../spec.md) (FR-001 a FR-006) | **Modelo**: [../data-model.md](../data-model.md) §5

Define el comportamiento observable de la función tras el arreglo. Es una función de biblioteca (se carga con `source`, sin efectos al cargarla) y su único llamador es `_qmd_ensure_prefix`.

## 1. Interfaz

```text
_qmd_swap_sqlite_vec PREFIJO
```

- **Argumento**: la ruta del prefijo gestionado de qmd (el que contiene `node_modules/`).
- **Estado de salida**: siempre 0, en todas las filas de la tabla de decisión. La función puede ejecutarse bajo `set -e`: `docker/scripts/start_services.sh` (línea 14) usa `set -euo pipefail`, mientras que `heartbeatctl`, `qmd-mcp`, los envoltorios locales y `scripts/qmd_watch.sh` usan `set -u` o `set -uo pipefail`. Por eso no puede abortar al llamador. Incluye el caso en que `uname -m` falla: la asignación lo tolera (`arch=$(uname -m 2>/dev/null || true)`) y la rama cae en la fila D2.
- **Salida estándar**: vacía.
- **Salida de error**: cero o una línea de log (`_qmd_log` antepone `[qmd]` y un espacio). Nunca más de una línea por llamada. Qué ve el operador depende del llamador: `_qmd_ensure_prefix` llama a la función antes de cada `_qmd_run`, y setup y reindex capturan esa salida en sus archivos de registro y solo muestran la cola redactada de 500 bytes cuando la llamada falla.
- **Efectos en el disco**: a lo sumo una copia, sobre el `vec0.so` del paquete de la arquitectura de la máquina. Ningún otro archivo se crea, se modifica ni se borra.
- **Compatibilidad**: bash 3.2 y 5.x; sin construcciones propias de bash 4 o superior; sin `local x=$(...)` (enmascara el estado).

## 2. Entradas del entorno (seams)

| Variable | Significado | Valor por defecto |
| --- | --- | --- |
| `QMD_MUSL_LOADER` | si está definida, la máquina es musl exactamente cuando ese archivo existe (existente) | sin definir: la máquina es musl si hay un `/lib/ld-musl-*.so.1` |
| `QMD_VEC0_MUSL_SO` | ruta de la build musl horneada (existente) | `/opt/agent-admin/sqlite-vec/vec0.so` |
| `QMD_MACHINE_ARCH` | **nueva**: el valor que `uname -m` imprimiría; si está definida (aun vacía) reemplaza a `uname -m` | sin definir: `uname -m` |

`QMD_MACHINE_ARCH` es un seam de pruebas, igual que las otras dos: no se documenta como perilla del operador y ningún otro código la lee.

## 3. Mapa de arquitectura

| `uname -m` (o seam) | Paquete que se toca |
| --- | --- |
| `x86_64`, `amd64` | `node_modules/sqlite-vec-linux-x64/vec0.so` |
| `aarch64`, `arm64` | `node_modules/sqlite-vec-linux-arm64/vec0.so` |
| cualquier otro valor, vacío o un `uname` que falla | ninguno (fila D2) |

## 4. Orden de evaluación y resultados

El orden y las filas son los de [../data-model.md](../data-model.md) §5 (D1 a D7). Resumen por rama:

1. **No es musl** (D1): no hace nada, no imprime, no consulta la arquitectura.
2. **Arquitectura no soportada** (D2): línea L-ARCH; no toca nada. Es una rama defensiva: la imagen solo se construye en x86_64 y aarch64, así que en producción no se llega aquí; la cubre N5 para que, si alguna vez ocurre, no sea otro camino callado.
3. **Falta el paquete de la arquitectura** (D3): no existe `node_modules/sqlite-vec-linux-<sufijo>/vec0.so` (el mismo criterio de hoy, `[ -e "$target" ]` en `qmd_index.sh:132`: se mira el archivo, no el directorio); línea L-PKG; no toca nada, tampoco un paquete ajeno. Un directorio del paquete sin su `vec0.so` también cae aquí y su nombre aparece en `found:`.
4. **Falta la build horneada** (D4): línea L-ABS (texto actual).
5. **La build y el `vec0.so` del paquete son iguales** (D5): no hace nada, no imprime (`cmp -s`).
6. **Copia la build sobre el `vec0.so` del paquete** (D6): línea L-OK si la copia funcionó (texto actual) o L-CP si falló (texto actual) (D7).

## 5. Textos CANON de las líneas de log

Las tres existentes **no cambian** (FR-002 exige la misma línea en arm64), y las dos que nombran una causa que no es el paquete (L-ABS y L-CP) dicen la causa pero no la lista de paquetes: FR-005 y SC-003 piden la lista solo cuando la causa es el paquete (L-PKG). Las dos nuevas son de una sola línea, en ASCII, sin secuencias de color.

| Código | Línea (sin el prefijo `[qmd]`) | Estado |
| --- | --- | --- |
| L-OK | `sqlite-vec: swapped glibc prebuilt for musl build` | existente, sin cambio |
| L-ABS | `sqlite-vec: musl build absent (<QMD_VEC0_MUSL_SO>) <GL> vector embed unavailable, lexical index intact`, donde `<GL>` es el guion largo que el texto actual ya usa | existente, sin cambio |
| L-CP | `sqlite-vec: swap failed (cp) <GL> vector embed may be unavailable` | existente, sin cambio |
| L-PKG | `sqlite-vec: no sqlite-vec-linux-<sufijo> package in the managed prefix (found: <lista>) - vector embed unavailable, lexical index intact` | **nueva** |
| L-ARCH | `sqlite-vec: no musl build for machine architecture '<arch>' (supported: x86_64, aarch64) - vector embed unavailable, lexical index intact` | **nueva** |

- `<sufijo>` es `x64` o `arm64` (la arquitectura de la máquina, según el mapa de §3).
- `<lista>` son los nombres (sin ruta) de los directorios `node_modules/sqlite-vec-linux-*` que existen, separados por un espacio y en el orden del glob (alfabético), o `none` si no hay ninguno.
- `<arch>` es el valor crudo de `uname -m` (o del seam), entre comillas simples; vacío se ve como `''`.
- Una pregunta de diagnóstico se responde con estas líneas sin segunda corrida (SC-003): las cinco nombran la causa; en L-PKG el sufijo dice qué se buscó y la lista dice qué había, y en L-ARCH la arquitectura cruda dice qué se creyó que era la máquina.
- Los pasajes de `docs/vault.md` que explican este cierre (líneas 540 a 541 y 697 a 699) lo atribuyen hoy solo al artefacto horneado ausente. Como L-PKG y L-ARCH lo comparten, T015 los reescribe para distinguir las causas por el comienzo de la línea: `musl build absent` manda reconstruir la imagen con `QMD_NATIVE_TOOLCHAIN=1`; `no sqlite-vec-linux-<sufijo> package` apunta a un prefijo traído de otra arquitectura o a una instalación incompleta; `no musl build for machine architecture` indica una arquitectura que la imagen no soporta.

## 6. Invariantes

- **I1**: nunca se escribe en un paquete de otra arquitectura que la de la máquina (FR-004).
- **I2**: a lo sumo un archivo escrito por llamada.
- **I3**: dos llamadas seguidas con las mismas entradas: la segunda no escribe ni imprime nada si la primera tuvo éxito (FR-006).
- **I4**: en glibc la función no escribe, no imprime y no bifurca `uname` (FR-003); N6 lo afirma con un `uname` falso que anota sus llamadas y M14 lo prueba.
- **I5**: el estado de salida es 0 en todas las filas, también cuando `uname` falla (se comprueba a mano bajo `set -euo pipefail` en el punto de control de US2).
- **I6**: la salida de error es una sola línea por llamada, como máximo (N4 y N5 afirman exactamente una y M15 lo prueba).

## 7. Lo que este contrato no cubre

- Reinstalar el prefijo cuando lo compiló otra arquitectura (fuera de alcance; solo se diagnostica con L-PKG).
- Validar que la build horneada sea de la arquitectura de la máquina: se compila de forma nativa en el build de la imagen, así que no puede diferir dentro de un mismo contenedor.
- El resto de `_qmd_ensure_prefix` (la instalación, las opciones de compilación de llama.cpp) y el llamador, que no cambian.
