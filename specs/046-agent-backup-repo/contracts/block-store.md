# Contrato: la herramienta del almacén por bloques

**Feature**: `046-agent-backup-repo` | Cubre FR-009, FR-010, FR-011, FR-012 y FR-014.

`docker/scripts/backup_store.py` es un solo archivo en Python, sin dependencias fuera de la biblioteca estándar. Corre en Python 3.9 (el host que restaura) y en 3.14 (la imagen). Lleva su línea `COPY` en `docker/Dockerfile` y `setup.sh` lo usa desde el clon del launcher al restaurar. El formato que escribe está en la sección 6 de [data-model.md](../data-model.md).

La herramienta no hace commits ni habla con ningún repositorio: lee archivos y escribe un directorio.

## S1. La llave de datos

Cada almacén tiene su propio par de llaves de `age` (D27 de [research.md](../research.md)).

| Archivo de `store/` | Contenido | Quién lo puede leer |
| --- | --- | --- |
| `key.age` | La parte privada de la llave de datos, cifrada para la llave pública del operador | Quien tenga la llave privada del operador |
| `recipient` | La parte pública de la llave de datos, en una línea | Cualquiera |
| `operator` | La huella de la llave del operador para la que se cifró `key.age`, en una línea | Cualquiera |

- Los bloques y el manifiesto se cifran para `recipient`.
- La parte privada se genera con `age-keygen`, cuya salida la herramienta lee por un pipe y entrega a `age` por la entrada estándar. Nunca se escribe en claro en un archivo del agente.

### Rotación

`pack` rota el almacén cuando se cumple cualquiera de estas condiciones, en este orden:

| Condición | `rotated` |
| --- | --- |
| Falta `key.age`, `recipient` u `operator` | `new` |
| `operator` no es la huella de la llave de `--recipients` | `operator-changed` |
| Se pasó `--expect-recipient` y no es igual a `recipient` | `recipient-mismatch` |

Rotar es: generar un par nuevo, borrar todos los bloques y el manifiesto, y cifrar todo de nuevo. Es una subida completa.

- **Por qué la segunda**: los bloques ya subidos se cifraron para una llave de datos que solo abre la llave anterior del operador. Sin rotar, el respaldo quedaría ilegible con la llave vigente sin que nada lo avise.
- **Por qué la tercera**: `recipient` llega desde el repositorio. La unidad recuerda en su estado la que ella misma generó; si la del repositorio es otra, no se cifra para ella.
- **Sin `--expect-recipient`** (la unidad perdió su estado), `pack` confía en la `recipient` que encuentra. Es el riesgo aceptado de D27.

## S2. Subcomandos

### `digest`

```text
backup_store.py digest --map ARCHIVO [--extra TEXTO] [--snapshot-dir DIR] [--list]
  stdout: el hash de la unidad, en hexadecimal
  con --list: una línea por archivo, "<ruta lógica>\t<tamaño>\t<sha256>", ordenadas por ruta
```

- Calcula el hash de la sección 6 de data-model sin escribir nada en el almacén, con las mismas reglas de captura que `pack`.
- `--extra` agrega texto al final del cálculo. La unidad lo usa para la marca de datos sensibles y la llave pública del operador.
- `--list` entrega el tamaño y el SHA-256 de cada archivo **tal como se captura**. Es lo que el ensayo de restauración compara con lo restaurado: la copia consistente de una base SQLite no tiene los bytes del archivo vivo, y un `.jsonl` se captura hasta su último salto de línea.

### `pack`

```text
backup_store.py pack --unit NOMBRE --map ARCHIVO --store DIR --recipients ARCHIVO
                     [--expect-recipient TEXTO] [--extra TEXTO] [--block-size BYTES] [--snapshot-dir DIR]
  stdout: {"files": N, "blocks": N, "new_blocks": N, "bytes": N, "new_bytes": N,
           "digest": "<hash>", "recipient": "<age1...>", "rotated": ""}
```

- Decide la rotación de S1 antes de leer ningún archivo.
- Lee cada archivo de `--map`, lo parte en bloques y escribe en `DIR/blocks/` solo los que no existen.
- `digest` es el hash de lo que de verdad se empaquetó. Es informativo. El hash que una unidad guarda en su estado es el que calculó antes, con el subcomando `digest`, sobre todos sus archivos, también los que viajan en claro (U1 de [backup-units.md](backup-units.md)).
- `recipient` es la parte pública de la llave de datos con que se cifró. La unidad la guarda como `store_recipient`.
- `rotated` vale `""`, `new`, `operator-changed` o `recipient-mismatch`.
- Borra de `DIR/blocks/` los bloques que el manifiesto nuevo ya no nombra.
- Escribe `DIR/manifest.json.age` de forma atómica, en cada corrida. Como `age` cifra distinto cada vez, ese archivo cambia aunque nada más haya cambiado.
- No escribe ningún byte en claro dentro de `DIR`, salvo `recipient` y `operator`.
- Una base SQLite no se lee en bruto. Se reconoce por su cabecera de 16 bytes (`SQLite format 3` y un byte nulo), se copia a `--snapshot-dir` con la API de respaldo, se verifica, y lo que se empaqueta es la copia. `digest` hace lo mismo, para que los dos calculen el mismo hash. Sin `--snapshot-dir`, encontrar una base SQLite es un error de uso.
- Los archivos `*-wal`, `*-shm` y `*-journal` del mapa se omiten.

### `unpack`

```text
backup_store.py unpack --store DIR --dest DIR --identity ARCHIVO [--work-dir DIR]
  stdout: {"files": N, "verified": N}
```

- Abre `DIR/key.age` con la llave del operador, en **una sola** invocación de `age`. Es la única vez que usa esa llave: si tiene passphrase, `age` la pide una vez (M19 de [research.md](../research.md)).
- La llave de datos queda en un archivo con modo 0600, dentro de `--work-dir` (por defecto, un directorio temporal nuevo con modo 0700), y se borra al terminar, también ante un error o una interrupción.
- Descifra el manifiesto y los bloques con la llave de datos, sin preguntar nada.
- Reconstruye cada archivo bajo `--dest`, con sus permisos, y verifica su SHA-256 contra el manifiesto.
- Rechaza cualquier `path` absoluto o con `..`.
- Si algo falla, no deja ningún archivo en `--dest`.

### `sqlite-snapshot`

```text
backup_store.py sqlite-snapshot ORIGEN DESTINO
  stdout: "ok" si la copia pasa la verificación de integridad
```

Copia la base con la API de respaldo de SQLite y corre `PRAGMA integrity_check` sobre la copia. Abre el origen en modo de solo lectura. Es la misma rutina que usan `pack` y `digest`.

### `fingerprint`

```text
backup_store.py fingerprint "ssh-ed25519 AAAA... comentario"
  stdout: SHA256:<huella en base64 sin relleno>
```

Entrega la misma huella que muestra `ssh-keygen -lf`. La usan `pack` (para `operator`), `backup-status`, el wizard y `--configure-key`, porque la imagen no trae las herramientas de OpenSSH.

## S3. Archivo de mapa

`--map` recibe un archivo con pares separados por el byte nulo: la ruta lógica y la ruta de origen, alternadas.

```text
ruta-lógica-1 \0 /ruta/de/origen-1 \0 ruta-lógica-2 \0 /ruta/de/origen-2 \0
```

Un origen que ya no existe al momento de leerlo se omite, y no es un error: los archivos de una sesión viva cambian mientras corre el respaldo.

## S4. Códigos de salida

| Código | Significado |
| --- | --- |
| 0 | Correcto |
| 2 | Uso incorrecto |
| 3 | Falta el archivo de la llave pública o el de la llave privada |
| 4 | `age` o `age-keygen` fallaron o no están instalados. Incluye una llave privada que no corresponde |
| 5 | La verificación de integridad falló: el hash de un archivo reconstruido no coincide, o la copia de SQLite no pasa la verificación |
| 6 | Error de lectura o escritura |

Los mensajes de error van a stderr y nunca incluyen contenido de los archivos ni rutas de origen: solo la ruta lógica.

## S5. Cifrado

- Se usan los binarios `age` y `age-keygen` del PATH. Las variables `AGE_BIN` y `AGE_KEYGEN_BIN` los reemplazan en las pruebas. La imagen trae los dos (M20 de [research.md](../research.md)); el host que restaura solo necesita `age`.
- Cada bloque y el manifiesto se cifran por separado, pasando el contenido por la entrada estándar.
- `--recipients` es un archivo con la llave pública del operador, en el formato que acepta `age -R`: una llave `ssh-ed25519` o `ssh-rsa`. Se usa la primera línea válida.
- `--identity` es la ruta de la llave privada del operador. La herramienta no la lee: se la entrega a `age -d -i`.
- **Confidencialidad, no autenticidad**: `age` no firma. Quien pueda escribir en el repositorio puede reemplazar un respaldo por otro contenido que la restauración aceptaría. El respaldo confía en el control de acceso del repositorio, igual que el respaldo en claro de hoy.

## S6. Invariantes

- **I1**: `unpack` aplicado a la salida de `pack` reproduce cada archivo byte a byte, incluidos los archivos vacíos, los binarios y los que ocupan varios bloques.
- **I2**: dos `pack` seguidos sobre los mismos archivos dan `new_blocks` 0 y `rotated` vacío en el segundo.
- **I3**: si a un archivo solo se le agregan bytes al final, el `pack` siguiente escribe como máximo el último bloque anterior y los bloques nuevos.
- **I4**: después de `pack`, `DIR/blocks/` contiene exactamente los bloques que nombra el manifiesto.
- **I5**: ningún archivo de `DIR` contiene una cadena centinela presente en los archivos de origen.
- **I6**: con una llave privada que no corresponde, `unpack` termina con el código 4 y no escribe ningún archivo en `--dest`.
- **I7**: un `.jsonl` cuya última línea no termina en salto de línea se empaqueta sin esa línea, y su tamaño en el manifiesto es el de lo empaquetado.
- **I8**: dos `pack` seguidos sobre una base SQLite sin cambios dan el mismo `digest`, aunque entre los dos se haya vaciado su WAL.
- **I9**: una base SQLite del mapa nunca se empaqueta desde su archivo en bruto, sea cual sea su nombre.
- **I10**: después de un `pack` con otra llave del operador, el almacén entero se abre con la llave nueva y ya no se abre con la anterior.
- **I11**: `unpack` invoca a `age` con la llave del operador exactamente una vez, sea cual sea la cantidad de bloques.
- **I12**: después de `pack` y después de `unpack`, la parte privada de la llave de datos no queda en ningún archivo en claro.
- **I13**: con `--expect-recipient` distinto de `recipient`, ningún bloque se cifra para la `recipient` que traía el almacén.
