# Data model: los tests e2e de qmd dejan de caer por la carrera del `.reindex.lock`

**Feature**: `043-e2e-lock-race-hardening` | **Spec**: [spec.md](spec.md) | **Research**: [research.md](research.md)

La feature no agrega estado persistente: las «entidades» son el lock y el estado del índice que ya existen, más las variables y los textos que el ayudante de pruebas deja a los sitios. Los textos de reporte marcados **CANON** los fija el contrato y los afirma el oráculo del host.

## 1. Entidades

### 1.1 `.reindex.lock` (existente, no cambia)

| Campo | Valor |
| --- | --- |
| Ruta en el contenedor | `${QMD_CACHE_HOME:-$HOME/.cache/qmd}/.reindex.lock` (`qmd_index.sh:62,468,554`) |
| Mecanismo | `flock -n 9` dentro de un subshell con `9>"$lock"` (`:474-482`, `:556-567`) |
| Quién lo toma | `qmd_setup_if_needed`, `qmd_reindex` (manual, cron, vigilante) |
| Quién lo suelta | el cierre de **todos** los descriptores del archivo abierto; nada cierra el descriptor 9 para los hijos (verificado), de modo que un descendiente lo retiene |
| Perder la carrera | escribe `[qmd] reindex: already running — skip` a stderr, sale del subshell con 91 y la función devuelve 0 |

### 1.2 Intento (`attempt`)

Una ejecución de la orden del ayudante a través del exec del sitio (D2 de la investigación):

| Dato | Origen |
| --- | --- |
| `status` | estado de salida del exec (el del reindex, o 124, 137 o 143 si el tope de 600 s lo cortó) |
| `output` | stdout y stderr del reindex, reimpresos desde `/tmp/qmd-reindex.out` (se reescribe en cada intento) |
| `busy` | verdadero si `output` contiene la cadena `already running` |

### 1.3 Resultado de una espera (variables que el ayudante deja al sitio)

| Variable | Contenido |
| --- | --- |
| `REINDEX_STATUS` | `status` del último intento |
| `REINDEX_OUTPUT` | `output` del último intento |
| `REINDEX_ATTEMPTS` | cuántos intentos hizo (1 si el lock estaba libre) |
| `REINDEX_WAITED_S` | segundos entre el comienzo del primer intento y el del último, según `_qmd_e2e_now` leído antes de cada intento (0 con el lock libre) |

Valores de retorno de `qmd_e2e_reindex_wait`: **0** el reindex corrió (con cualquier estado: el sitio lo juzga), **1** el lock siguió ocupado al vencer el plazo (el ayudante ya imprimió su reporte), **3** un intento excedió su tope (rc 124, 137 o 143; el sitio imprime el reporte de plazo vencido de 041).

### 1.4 Documento de estado del índice (`qmd-index.json`, existente)

| Campo | Significado | Quién lo escribe |
| --- | --- | --- |
| `hash` | `vault_hash` del vault que cubre la última corrida | `qmd_write_state` (`qmd_index.sh:439-441`) |
| `last_status` | `indexed` (update y embed completos), `skipped` (vault sin cambios y `pending` 0), `partial` (tope de pasadas), `stalled` (sin progreso), `error` | `:635-710` |
| `pending` | documentos que aún necesitan embedding; ausente si nunca se supo | `:427-430` |
| `runs` | contador de escrituras | `:422-426` |
| `last_run`, `collection_layout`, `migration` | informativos | `:431-441` |

Solo una corrida que **obtuvo el lock** escribe este archivo: una que lo perdió lo deja como estaba, o inexistente si fue la primera.

### 1.5 Variable de entorno nueva

| Nombre | Efecto | Valor por defecto |
| --- | --- | --- |
| `QMD_E2E_REINDEX_LOCK_WAIT_S` | plazo de espera por el lock, en segundos | 120 |

Normalización (igual que `QMD_E2E_SETUP_DEADLINE_S`, `docker-e2e-qmd.bats:825-829`): vacío, no numérico o de más de cuatro dígitos dan 120; el valor numérico pasa por `10#` (un `08` no es octal); fuera de 1 a 3600 da 120.

### 1.6 Costuras de prueba del ayudante

| Función | Por defecto | La redefine el host para |
| --- | --- | --- |
| `_qmd_e2e_now` | `date +%s` | un reloj falso que avanza con cada espera falsa |
| `_qmd_e2e_sleep SEGUNDOS` | `sleep "$1"` | registrar la espera pedida y volver al instante |

La cadencia (2 s) es una constante del ayudante y no se sobrescribe por entorno.

## 2. Ciclo de una espera

```text
INICIO
  -> INTENTO (ejecuta la orden por el exec del sitio)
       status en {124, 137, 143}        -> FIN con retorno 3   (sin reintento)
       salida contiene `already running` -> OCUPADO
       cualquier otro resultado          -> FIN con retorno 0   (el sitio juzga status y salida)
  OCUPADO
       primera vez en esta espera        -> sonda del dueño, nota TAP (tolerante a fallas)
       transcurrido >= plazo             -> reporte de plazo vencido, FIN con retorno 1
       en otro caso                      -> espera de 2 s -> INTENTO
```

Invariantes: solo `already running` se reintenta; la sonda nunca cambia el retorno; el lock libre produce un solo intento sin espera previa ni sondeo que tome el lock; el tiempo se lee solo por `_qmd_e2e_now`.

## 3. Tabla de decisión del efecto (`qmd_e2e_reindex_effect`)

El ayudante pide, dentro del contenedor y con `bash -lc`, una sola línea con el contenido del estado y el `vault_hash` actual del vault que resuelve el producto (`qmd_vault_dir /workspace/agent.yml`, el mismo directorio que hashea `_qmd_reindex_locked`, `qmd_index.sh:684`): `STATE absent` si `qmd-index.json` no existe, o `STATE present ESTADO PENDING HASH_ESTADO HASH_VAULT`, con campos sin espacios y `-` para un campo ausente o nulo. Un shell de login puede anteponer ruido, así que el host toma la última línea que empieza con `STATE` seguido de un espacio. El veredicto se decide en el host y en este orden: archivo ausente, estado, `pending` y hash:

| Archivo de estado | `last_status` | `pending` | `hash` frente al `vault_hash` actual | Veredicto |
| --- | --- | --- | --- | --- |
| ausente | | | | falla: `qmd-index.json is absent` |
| presente | `indexed` | 0 | igual | pasa |
| presente | `skipped` | 0 | igual | pasa (otro reindex legítimo hizo el trabajo) |
| presente | `indexed` o `skipped` | 0 | distinto | falla: el índice no cubre el vault de ahora (nombra los dos hashes) |
| presente | `indexed` o `skipped` | distinto de 0 o ausente | cualquiera | falla: `pending` |
| presente | `error`, `partial` o `stalled` | cualquiera | cualquiera | falla: nombra el estado |
| presente | cualquier otro valor | | | falla: nombra el valor |

## 4. Textos de reporte (CANON)

Todos salen por fd 3 como comentarios TAP, una línea por renglón y con el prefijo de una almohadilla y tres espacios (el molde de `_embed_note`). `SITIO` es la etiqueta que pasa cada sitio (`reindex phase`, `test 12 phase 3`, `test 13 tick 1`, `test 13 tick 2`).

| Id | Cuándo | Texto |
| --- | --- | --- |
| R-BUSY | primera contención de una espera | `reindex lock busy (SITIO): the first attempt lost the lock; owners:` seguido de las líneas de la sonda |
| R-EXPIRED | plazo vencido (retorno 1) | `reindex (SITIO): the reindex lock stayed busy for N s (M attempts) and the reindex never ran`, `last output of qmd-reindex:` con la salida del último intento y `lock owners at the end of the wait:` con la sonda |
| R-EFFECT | efecto no cumplido | `reindex effect (SITIO):` seguido de la condición de la tabla 3; de la condición solo es CANON `qmd-index.json is absent`, y el oráculo afirma que el texto nombra el dato (el estado, `pending` o los dos hashes) |

Las líneas de la sonda (`qmd_e2e_lock_owners`):

| Caso | Línea |
| --- | --- |
| un retenedor | `pid N fd K cmd=[COMANDO]` (el `cmdline` con los NUL cambiados por espacios) |
| ninguno | `none found` |
| el archivo del lock no existe | `lock file absent (RUTA)` |
| no hay `/proc` (macOS) | `no /proc here` |

La cadena que el ayudante busca en la salida es `already running` y debe seguir siendo un prefijo literal de lo que escribe `qmd_reindex` después de `reindex:` (`scripts/lib/qmd_index.sh:562`); una prueba del host lo guarda.
