# Contrato: `.github/scripts/fetch-qmd-models.sh`

Obtiene y verifica los dos modelos que usa la fase del embed y le deja el resultado al paso siguiente del job (D1, D3, D4, D5, D6). Las entidades y los mensajes están en [data-model.md](../data-model.md) §1 a §3.

## 1. Forma

- Ruta `.github/scripts/fetch-qmd-models.sh`, en el índice de git con modo `100755`.
- bash 3.2 a 5.x: sin `mapfile`, sin arreglos asociativos, sin `${v,,}`.
- `set -u`, sin `set -e`: cada código de salida se decide de forma explícita. El script de 040 no usa ninguna de las dos; este usa `-u` para que una variable mal escrita falle en los tests de los dos bash. Si aun así abortara sin escribir resultado, data-model §2 y §5 describen lo que se ve.
- Solo ASCII, en el código y en todo lo que imprime. El script fija `LC_ALL=C` al empezar: bash traduce sus propios mensajes (una redirección fallida, por ejemplo) al idioma del usuario cuando tiene el catálogo, también desde un entorno limpio en macOS (research M15).
- Ninguna tubería con un consumidor que cierre antes que el productor (`head`, `grep -q`, `sed Nq`, `awk … exit`).
- Lo revisa el job de shellcheck (research M11): `shellcheck -S error -e SC1090,SC1091` en rc 0.
- Se invoca sin argumentos: `run: .github/scripts/fetch-qmd-models.sh`.

## 2. Tabla de modelos (fuente única, FR-012)

Al inicio del script, como un heredoc de filas `name|repo|file|local_name|bytes|sha256` con los valores de data-model §1, más `QMD_MODELS_QMD_VERSION=2.5.3`. Ningún otro archivo del repositorio repite esos valores; los guards G1 y G2 del oráculo los leen de aquí.

## 3. Entradas

| Variable | Valor por defecto | Regla |
| --- | --- | --- |
| `QMD_EMBED_DEFECT` | vacío | data-model §3. Un valor no vacío debe empezar con `#<dígitos>` seguido de un espacio y un motivo, o con `https://github.com/<dueño>/<repo>/issues/<dígitos>`, y ser ASCII imprimible de una sola línea. Cualquier otro valor da `misconfigured`. |
| `GITHUB_ENV` | sin definir | archivo al que se agregan las salidas de §5. Sin definir, no se escribe nada. Definido y sin poder escribirse, el paso termina en rojo con su error, no en verde sin su salida. |
| `RUNNER_TEMP` | sin definir | base del directorio por defecto |

Costuras para tests. El workflow no debe definir ninguna (oráculo W7). `QMD_MODELS_DIR` es además la perilla del operador en la receta local de `docs/qmd-upgrade-checklist.md`; en el workflow tampoco se define:

| Variable | Valor por defecto | Regla |
| --- | --- | --- |
| `QMD_MODELS_DIR` | `${RUNNER_TEMP:-${TMPDIR:-/tmp}}/qmd-models` | se crea si no existe; si no se puede crear, da `misconfigured` que nombra la variable cuando el operador la definió y, con el directorio por defecto, dice que el directorio por defecto no se pudo crear (no culpa a una variable que nadie fijó) |
| `QMD_MODELS_BASE_URL` | `https://huggingface.co` | solo se aceptan exactamente ese valor o `http://127.0.0.1:<1 a 5 dígitos>`; cualquier otro da `misconfigured` sin tocar la red |
| `QMD_MODELS_TABLE` | sin definir | ruta de una tabla alternativa con el formato de §2; solo se acepta con una base `http://127.0.0.1:…`, y con la base real da `misconfigured` |
| `QMD_FETCH_ATTEMPTS` | `3` | entero de 1 a 5; otro valor vuelve al de por defecto |
| `QMD_FETCH_BACKOFF_S` | `10 30` | enteros de 0 a 300 separados por espacios; la espera k-ésima usa el k-ésimo valor y, si faltan, el último |
| `QMD_FETCH_BUDGET_S` | `480` | entero de 1 a 3600; otro valor vuelve al de por defecto |

## 4. Algoritmo

1. Validar `QMD_MODELS_BASE_URL`, `QMD_MODELS_TABLE` (y sus filas: seis campos, `bytes` entero positivo sin cero a la izquierda, porque la aritmética de shell lo leería en octal, y `sha256` de 64 hexadecimales en minúscula) y que existan una herramienta de sha256 y `curl`. Si fallan: `misconfigured`, sin red.
2. Si `QMD_EMBED_DEFECT` no está vacío: si es válido, `defect`; si no, `misconfigured`. Sin red en los dos casos. En `defect` la razón se escribe en `$GITHUB_ENV` y, si esa escritura falla, el paso termina en rojo con el error del paso 6: una razón que no llega al paso siguiente dejaría la puerta del test abierta y sin modelos.
3. Crear el directorio (si no se puede: `misconfigured`), registrar un `trap` de salida que borra los `.part` e imprimir `qmd models: dir=<dir> free_kb=<n>` (`df -Pk`).
4. Por cada fila de la tabla, en orden, hasta `QMD_FETCH_ATTEMPTS` intentos mientras quede presupuesto:
   - `curl --fail --location --silent --show-error --speed-limit 1048576 --speed-time 30 --max-time <presupuesto restante> --output <dir>/<local_name>.part --write-out '%{http_code}' <base>/<repo>/resolve/main/<file>?download=true`.
   - Con la base real se agregan `--proto =https --proto-redir =https`; con la base local, `--proto =http`.
   - El intento falla si curl sale distinto de 0 o si el tamaño (`wc -c`) no es `bytes`. Al fallar se imprime `qmd model <name>: attempt <k>/<n> failed: <motivo>` y se espera `min(espera, presupuesto restante)`.
   - Si el tamaño es `bytes` pero el sha256 (`sha256sum`, o `shasum -a 256` si no existe) no es `sha256`, el archivo cambió en origen: no hay más intentos y el resultado es `drift`.
   - Si el intento tiene éxito, se renombra el `.part` a `<local_name>` con `mv -f` y se imprime `qmd model <name>: ok file=<local_name> bytes=<n> attempts=<k> elapsed_s=<s>`.
5. Si un modelo agota sus intentos o el presupuesto: `failed`. El motivo es el último error o, si el presupuesto se agotó, `budget (<N>s)` seguido de `tras: <último error>`: `budget` a secas se leería como un problema de la tabla y no como un enlace lento. Un modelo reemplazado en origen con OTRO tamaño se reintenta como una descarga truncada y sale como `failed` con `size <n> != <m>`; solo el mismo tamaño con otro sha256 es `drift` (límite conocido: el motivo no distingue ese reemplazo de una descarga cortada). Con `failed` o `drift`, el script termina ahí, sin bajar los modelos siguientes. Límite conocido: si el primer modelo se baja bien pero consume todo el presupuesto, el segundo ni siquiera se intenta y su motivo es `budget (<N>s)` a secas, sin `tras:`; la causa (un enlace lento) la muestra el `elapsed_s=` de la línea `ok` del primero.
6. Si los dos quedan verificados: imprimir `qmd models: ok total_bytes=<n> elapsed_s=<s> free_kb=<n>` y terminar con `ok`. Si la escritura de la salida en `$GITHUB_ENV` falla (esta, o la de `QMD_EMBED_SKIP_REASON` en la rama `defect`), termina con 1 y `::error::no se pudo escribir <CLAVE> en GITHUB_ENV (paso fetch_models)`, con `<CLAVE>` la que iba a escribir. Un rc 0 dejaría al paso siguiente sin su variable y con el rojo atribuido a la suite, que no tiene la culpa. Las dos ramas pasan por un solo ayudante (`emit_env_or_stop`), para que no puedan divergir.

## 5. Salidas

Los textos exactos de cada clave están en data-model §2, que es su única fuente. Aquí, el código de salida, la clave y la anotación:

| `outcome` | Sale con | Clave en `$GITHUB_ENV` | Imprime |
| --- | --- | --- | --- |
| `ok` | 0 | `QMD_E2E_MODELS_DIR` | las líneas de §4 |
| `defect` | 0 | `QMD_EMBED_SKIP_REASON` | `::warning::` con el mismo texto |
| `failed` | 1 | `QMD_EMBED_SKIP_REASON` | `::error::` con el mismo texto |
| `drift` | 1 | `QMD_EMBED_SKIP_REASON` | `::error::` con el mismo texto |
| `misconfigured` | 1 | `QMD_EMBED_SKIP_REASON` | `::error::` con el mismo texto |
| escritura fallida | 1 | ninguna | `::error::` con el texto de data-model §2 (la salida no se pudo escribir) |

## 6. Invariantes

- Nunca escribe las dos claves a la vez; las escribe en una sola línea `CLAVE=valor`, en ASCII imprimible.
- Con `failed`, `drift` o `misconfigured` no quedan archivos `.part` ni modelos a medio verificar: cada intento empieza borrando el parcial del anterior y un `trap` de salida borra el último por cualquier camino (éxito, falla, una configuración inválida o un SIGTERM del runner).
- Con `defect` o `misconfigured` no llama a curl ni una vez.
- Termina antes de `QMD_FETCH_BUDGET_S` más 5 s, sin importar cuántas veces curl se cuelgue.
- No modifica el repositorio, no llama a Docker, no lee secretos y no imprime el entorno.
