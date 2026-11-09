# Data Model: El nightly de docker-e2e ejercita el embed real de qmd

**Feature**: `041-nightly-qmd-embed` | **Fecha**: 2026-10-15 | Fuentes: [spec.md](spec.md), [research.md](research.md)

No hay base de datos. Las «entidades» son registros que viven en el script de obtención, en las variables que ese script deja al paso siguiente, en el texto del workflow y en la salida TAP de la suite.

## 1. Identidad de un modelo

Una fila de la tabla al inicio de `.github/scripts/fetch-qmd-models.sh`: la única fuente (FR-012, D5).

| Campo | Regla de validación | Valor `embed` | Valor `expand` |
| --- | --- | --- | --- |
| `name` | `embed` o `expand`; único en la tabla | `embed` | `expand` |
| `repo` | `<usuario>/<repo>`, ASCII imprimible sin espacios | `ggml-org/embeddinggemma-300M-GGUF` | `tobil/qmd-query-expansion-1.7B-gguf` |
| `file` | nombre de archivo en el repo, termina en `.gguf` | `embeddinggemma-300M-Q8_0.gguf` | `qmd-query-expansion-1.7B-q4_k_m.gguf` |
| `local_name` | `hf_<usuario>_<file>` cuando `file` empieza con el repo sin `-GGUF`, sin distinguir mayúsculas (regla de node-llama-cpp, research M4) | `hf_ggml-org_embeddinggemma-300M-Q8_0.gguf` | `hf_tobil_qmd-query-expansion-1.7B-q4_k_m.gguf` |
| `bytes` | entero mayor que 0 | `333590944` | `1282438912` |
| `sha256` | 64 caracteres hexadecimales en minúsculas | `b5ce9d77a3fc4b3b39ccb5643c36777911cc4eb46a66962eadfa3f5f60490d63` | `000dfb1c06efa6a049e9f64ba921c3740e2454f62abab6fa10e77bd30bb2bcc0` |

La regla de `local_name` solo cubre el caso en que `file` empieza con el nombre del repo sin `-GGUF`. Para otro caso, node-llama-cpp usa otra forma que aquí no está modelada: el guard G2 falla y lo dice, en vez de calcular un nombre que qmd no buscaría.

A nivel de tabla, `QMD_MODELS_QMD_VERSION=2.5.3` registra para qué versión de qmd se verificó. Un guard del host la compara con la versión por defecto de `qmd_pkg`. Si no coinciden, el guard falla hasta que alguien revise la tabla (D5).

## 2. Resultado de la obtención

Lo produce una ejecución del script. Por modelo:

| Campo | Significado |
| --- | --- |
| `attempts` | intentos hechos, de 1 al máximo (3 por defecto) |
| `elapsed_s` | segundos desde el primer intento hasta que el archivo quedó verificado |
| `bytes` | tamaño del archivo aceptado |
| `last_error` | motivo del último intento fallido: código de salida de curl, código HTTP, `size <observado> != <esperado>`, `sha256 <observado> != <esperado>` (con el tamaño esperado: es un cambio en origen y no se reintenta) o `budget (<N>s)` seguido de `tras: <último error>` cuando el presupuesto se agota después de un intento fallido |

Resultado global y su efecto:

| `outcome` | Código de salida | Lo que escribe en `$GITHUB_ENV` | Anotación |
| --- | --- | --- | --- |
| `ok` | 0 | `QMD_E2E_MODELS_DIR=<dir>` | ninguna |
| `defect` | 0 | `QMD_EMBED_SKIP_REASON=fase del embed apagada por defecto abierto: <valor>` | `::warning::` |
| `failed` | 1 | `QMD_EMBED_SKIP_REASON=no se pudieron obtener los modelos de qmd (<name>: <last_error>; paso fetch_models)` | `::error::` |
| `drift` | 1 | `QMD_EMBED_SKIP_REASON=el modelo <name> cambio en origen (bytes iguales, sha256 <observado> != <esperado>): revisar la tabla del paso fetch_models` | `::error::` |
| `misconfigured` | 1 | `QMD_EMBED_SKIP_REASON=configuracion invalida del paso fetch_models: <detalle>` | `::error::` |
| escritura fallida (en `ok` o en `defect`) | 1 | nada: no hay dónde escribirlo | `::error::` con `no se pudo escribir <CLAVE> en GITHUB_ENV (paso fetch_models)`, con `<CLAVE>` la que iba a escribir (`QMD_E2E_MODELS_DIR` o `QMD_EMBED_SKIP_REASON`) |

Esta tabla es la fuente de los textos; el contrato del script la cita.

Reglas:

- Nunca escribe las dos claves a la vez.
- Sin `$GITHUB_ENV` (una corrida local), no escribe nada. Los códigos de salida y el log son los mismos. Con un `$GITHUB_ENV` que no se puede escribir, el script no termina en verde, ni en `ok` ni en `defect` (las dos salidas con rc 0 que dejan algo para el paso siguiente): sale con 1 y el error nombra `GITHUB_ENV` (última fila de la tabla).
- Los valores son de una sola línea, en ASCII imprimible y sin tildes, como los mensajes de los scripts de 039 y 040.
- Con `failed`, `drift` o `misconfigured` no quedan archivos `.part`.
- `drift` no reintenta y termina sin bajar los modelos siguientes.
- Si el script termina sin escribir ningún resultado (un aborto inesperado, por ejemplo de `set -u`), no hay clave. El paso queda rojo y, con la puerta abierta, el test 041 falla nombrando `QMD_E2E_MODELS_DIR` (§5).

## 3. Interruptor de defecto abierto (`QMD_EMBED_DEFECT`)

Variable del paso `fetch_models` en el workflow (FR-014, D6).

| Valor | Significado |
| --- | --- |
| `''` | la fase del embed está activa |
| `#<número> <motivo>` | defecto registrado como issue del repositorio: la fase se apaga |
| `https://github.com/<dueño>/<repo>/issues/<número> [<motivo>]` | igual, con la URL completa; en esta forma el motivo es opcional |
| cualquier otro valor no vacío | error de configuración: `outcome=misconfigured` |

El motivo de la forma `#<número>` debe tener al menos un carácter visible: solo espacios no cuenta. El valor va en ASCII imprimible y en una sola línea, sin tildes: pasa tal cual a `QMD_EMBED_SKIP_REASON`. Un valor con otro carácter también da `misconfigured`.

Transiciones:

```text
activo ──(una corrida real clasifica un defecto de producto y el operador abre el issue)──▶ apagado
apagado ──(el defecto se corrige, se vacía QMD_EMBED_DEFECT, una corrida manual con la fase activa termina verde y una rotura inducida la deja roja con la fase nombrada)──▶ activo
```

El cuerpo del issue de seguimiento registra las obligaciones de la segunda transición, para que las cumpla la feature que arregle el producto (FR-020).

## 4. Fases del embed

En orden. Cada una imprime su marca `# qmd embed phase: <nombre>` antes de empezar (FR-004, D9).

| # | Fase (marca) | Pasa si | Una falla apunta a |
| --- | --- | --- | --- |
| 1 | `models-seed` | los `*.gguf` verificados de `QMD_E2E_MODELS_DIR` (al menos uno) quedan enlazados en `.state/.cache/qmd/models/`; se registra su inodo y una marca de tiempo | arnés (falta el directorio o no hay modelos) |
| 2 | `boot` | el vault se siembra antes del arranque (esqueleto más una página bajo `wiki/`); `docker compose build` y `up -d` terminan; dentro del contenedor `CI` está vacía y `XDG_CACHE_HOME` vacía o igual a `$HOME/.cache` | arnés o entorno |
| 3 | `setup` | aparece `.qmd-setup-ok` antes del plazo (600 s, `QMD_E2E_SETUP_DEADLINE_S`) y el log no tiene `[qmd] setup: '<paso>' failed` ni `[qmd] install: bun install failed` | producto (instalación, compilación, embed) o el plazo del arnés |
| 4 | `vector-extension` | `vec0-libc.sh` sobre el prefijo responde `MUSL` | producto (el reemplazo de `sqlite-vec`) |
| 5 | `reindex` | se agrega una página bajo `wiki/` (la colección de qmd cubre solo `wiki/**/*.md`); `heartbeatctl qmd-reindex` con rc 0 dentro de 600 s, `last_status` en `ok` o `indexed` y `pending` en 0 | producto (o un reindex que no termina: la fase falla, el job no se cancela) |
| 6 | `semantic-search` | `qmd vsearch "animal encima del pc"` devuelve el documento de los gatos dentro de 300 s | producto (embed o expansión) |
| 7 | `mcp` | el servidor MCP arranca sin las firmas del BUG-4 | producto |
| 8 | `models-untouched` | el directorio de modelos tiene exactamente los archivos sembrados, con cualquier extensión, con el mismo inodo y sin cambios posteriores a la marca | qmd descargó o reescribió un modelo dentro del contenedor (contra FR-007) |

Cada fase contiene, entre su marca y la siguiente, el comando que la define (su ancla, contracts/host-oracle.md P1).

## 5. Resultado de la noche

Cómo se ve cada caso en los lugares que miran los operadores y el aviso de 040.

| Caso | TAP del test 041 | `e2e summary:` | Conclusión del job | Paso que nombra el aviso de 040 |
| --- | --- | --- | --- | --- |
| fase ejecutada y verde | `ok N qmd real (041) …` | cuenta como ejecutado | `success` | ninguno (no hay aviso) |
| regresión en una fase | `not ok N …` y la última marca nombra la fase | `failed` sube en 1 | `failure` | `run_suite` |
| modelos no obtenidos | `ok N … # skip no se pudieron obtener …` | `skipped` sube en 1 | `failure` (por `fetch_models`) | `fetch_models` |
| modelo cambiado en origen | `ok N … # skip el modelo <name> cambio en origen …` | `skipped` sube en 1 | `failure` (por `fetch_models`) | `fetch_models` |
| la obtención terminó sin escribir resultado | `not ok N …` con un mensaje que nombra `QMD_E2E_MODELS_DIR` | `failed` sube en 1 | `failure` | `fetch_models` (el primer paso fallido) |
| defecto abierto | `ok N … # skip fase del embed apagada por defecto abierto: #<n> …` | `skipped` sube en 1 | `success`, si nada más falla | ninguno |
| puerta abierta sin modelos (error del arnés) | `not ok N …` con un mensaje que nombra `QMD_E2E_MODELS_DIR` | `failed` sube en 1 | `failure` | `run_suite` |
| puerta cerrada (corrida local) | `ok N … # skip … QMD_EMBED_E2E=1 …` | `skipped` sube en 1 | no aplica | no aplica |

## 6. Corrida de evidencia

Lo que se registra de cada corrida real en las Notes de `tasks.md` (FR-020):

- identificador de la corrida, rama y commit;
- arquitectura (la imprime el paso de verificación de 039);
- duración del job `e2e`, medida con su `started_at` y su `completed_at` (no con las fechas de la corrida, que incluyen la cola), y su margen frente al tope;
- duración de cada fase del embed, con las marcas de tiempo del log entre una marca y la siguiente (la de `setup` incluye la compilación de llama.cpp);
- por modelo: tamaño, intentos y segundos;
- disco libre antes y después de la obtención;
- disco libre al terminar la fase del embed y memoria pico del contenedor (línea `# qmd embed resources:`);
- clasificación (verde, rojo de arnés, rojo de producto o rojo de infraestructura), con el fragmento de log que la prueba.
