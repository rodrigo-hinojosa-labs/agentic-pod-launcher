# Data Model: qmd sqlite-vec en Alpine musl

No hay esquema de datos nuevo (el fix no toca la DB de qmd ni el esquema `vec0`). Las "entidades" son los artefactos y estados que el fix produce/consume.

## E1 — Binario vectorial `vec0` (sqlite-vec)

La extensión SQLite que provee la virtual table `vec0` para almacenar/consultar embeddings.

| Atributo | Valores | Nota |
|---|---|---|
| `libc_target` | `glibc` (prebuilt del paquete) \| `musl` (compilado por este fix) | Discriminante clave; determina si carga en la imagen |
| `version` | `0.1.9` | Debe coincidir con la que arrastra `qmd@2.5.3` |
| ruta prebuilt | `<prefix>/node_modules/sqlite-vec-linux-arm64/vec0.so` | Lo que qmd resuelve vía `getLoadablePath()` |
| ruta horneada | `/opt/agent-admin/sqlite-vec/vec0.so` | Artefacto musl en la imagen (no enmascarado por `.state`) |

**Estados / transición**: `prebuilt-glibc (instalado por bun)` → *(swap en `_qmd_ensure_prefix` si musl)* → `musl (cargable)`. En glibc, permanece `prebuilt-glibc` (ya cargable).

**Validación**: cargable ⟺ `vec_version()` responde y `CREATE VIRTUAL TABLE … USING vec0` no lanza "no such module: vec0".

## E2 — Prefijo gestionado de qmd

Directorio del `node_modules` de qmd instalado en runtime.

| Atributo | Valor |
|---|---|
| raíz | `${QMD_CACHE_HOME:-$HOME/.cache/qmd}/pkg` (bajo `.state`) |
| provisto por | `_qmd_ensure_prefix` (016): `bun install` con `trustedDependencies` |
| contiene | `@tobilu/qmd`, `better-sqlite3` (nativo), `node-llama-cpp` (nativo), `sqlite-vec` + `sqlite-vec-linux-arm64` |

**Relación**: contiene E1 (el prebuilt que se sustituye). El swap es idempotente sobre este prefijo.

## E3 — Fuente de sqlite-vec (amalgamación)

El `.c` único desde el que se compila E1(musl) en build.

| Atributo | Valor |
|---|---|
| origen | `github.com/asg017/sqlite-vec/releases/download/v0.1.9/sqlite-vec-0.1.9-amalgamation.tar.gz` |
| contenido | `sqlite-vec.c` (~320KB) + `sqlite-vec.h` |
| integridad | `sha256` fijado (Principle VI) |
| headers de compilación | `sqlite3ext.h`/`sqlite3.h` (vía `apk sqlite-dev` en build) |

**Ciclo de vida**: solo build-time; no persiste en la imagen (solo el `vec0.so` resultante ~150KB).

## E4 — Par de versión (guardrail)

| Atributo | Valor | Fuente |
|---|---|---|
| qmd | `2.5.3` | `agent.yml vault.qmd.version` / default del wizard |
| sqlite-vec | `0.1.9` | `SQLITE_VEC_VERSION` (ARG Dockerfile) |

**Validación**: un test host asevera que ambos coinciden con el par conocido-bueno; un cambio en uno sin el otro falla el test (fuerza re-verificación de la compilación musl).

## E5 — Estado de reindexado (observabilidad)

El archivo de estado del heartbeat de reindexado (015-US4). No cambia de esquema; el fix se apoya en él para reportar si el embed tuvo éxito o degradó (artefacto ausente → embed no disponible, léxico intacto), sin secretos.
