# Contrato TP: el empuje por Telegram

Enmienda 1 de 040 (14-10-2026): además del issue, el job `alert` envía un mensaje al chat del mantenedor. Este contrato fija cuándo se envía, qué dice, cómo se llama a `curl` y qué anota el script. Lo implementa la función de empuje de `.github/scripts/nightly-alert.sh` (dentro de `notify`, después de la acción sobre el issue) y lo verifica el oráculo con el `curl` real contra un servidor local (`contracts/alert-oracle.md`, N32 a N42). Decisiones y mediciones: `research.md` R17 a R24.

## 1. Entrada

| Variable | Origen | Regla |
|---|---|---|
| `TELEGRAM_BOT_TOKEN` | secreto de repositorio del mismo nombre, solo en el paso que publica | validada con `^[0-9]{3,20}:[A-Za-z0-9_-]{20,80}$` antes de usarse |
| `TELEGRAM_CHAT_ID` | secreto de repositorio del mismo nombre, solo en el paso que publica | validada con `^(-?[0-9]{1,20}\|@[A-Za-z0-9_]{5,32})$` |
| `TELEGRAM_API_BASE` | **solo pruebas**; el workflow no la define | por defecto `https://api.telegram.org`; solo se acepta ese valor o, en las pruebas, `http://127.0.0.1:PUERTO`: el token viaja a esa dirección y el valor entra al archivo de configuración de `curl`, así que cualquier otro deja el empuje omitido |
| `TELEGRAM_MAX_TIME` | **solo pruebas**; el workflow no la define | segundos de `--max-time`; por defecto `15`; de 1 a 6 dígitos y mayor que cero (cualquier otro valor, el cero incluido que en `curl` significa "sin límite", vale `15`) |

Al arrancar `notify` el script copia los dos secretos a variables del shell y los quita del entorno (`unset`): `gh`, `jq` y `date` no los heredan. Un secreto ausente (vacío) u inválido deja el empuje omitido (sección 6) sin tocar el issue. **Nunca** se imprime el valor de un secreto, ni siquiera el de uno inválido.

## 2. Cuándo se envía

El empuje sigue a la acción sobre el issue (`data-model.md` sección 6):

| Acción de `notify` | ¿Mensaje? | Tipo | Sonido |
|---|---|---|---|
| crear | sí | `rojo-nuevo` | normal |
| actualizar (noche siguiente) | sí | `rojo-sigue` | normal |
| reabrir (cierre manual) | sí | `rojo-reabierto` si `gh issue reopen` funcionó; `rojo-sigue` si falló (el mensaje no afirma una reapertura que no ocurrió) | normal |
| cerrar (verde sobre un aviso abierto) y el aviso quedó cerrado | sí | `verde` | silencio |
| cerrar, pero el cierre no se completó (falló la reescritura del marcador o el cierre mismo) | no | | |
| solo reescribir el marcador (verde sobre un aviso cerrado a mano) | no | | |
| ninguna (noche ya registrada, cancelada, manual normal, verde sin aviso) | no | | |
| no se pudo consultar el issue y la noche es roja | sí | `rojo-sin-aviso` | normal |
| no se pudo consultar el issue y la noche es verde | no | | |

Un ensayo (`modo=trial`) envía los mismos mensajes con el prefijo `[ensayo] ` en la primera línea. El empuje se intenta **después** de la acción sobre el issue y, en una noche en rojo, aunque esta haya fallado (un rojo no se pierde porque GitHub falle); que el empuje falle no afecta al issue ni al código de salida. La recuperación es la excepción: el mensaje de `verde` sigue al cierre real del aviso y no a la noche verde. Si la noche verde no pudo cerrarlo, no dice nada; la noche verde siguiente repite el trabajo, cierra el aviso y envía el mensaje una sola vez (si lo hubiera enviado la primera, la misma recuperación se anunciaría dos veces).

## 3. El mensaje

Texto plano de ASCII imprimible sin tildes, de 2 a 6 líneas (de 4 a 6 en los casos normales), sin `parse_mode`, sin nombres de tests, con cada dato variable saneado como en `notice-format.md` sección 6. Plantilla (las líneas marcadas "si hay" se omiten cuando no hay dato):

| # | Línea | Cuándo |
|---|---|---|
| 1 | `[ensayo] ` (solo ensayo) + `docker-e2e nightly EN ROJO` / `docker-e2e nightly SIGUE EN ROJO` / `docker-e2e nightly SIGUE EN ROJO (aviso reabierto)` / `docker-e2e nightly VOLVIO A VERDE` | siempre; `EN ROJO` para `rojo-nuevo` y `rojo-sin-aviso` |
| 2 | `Racha: noche N (desde DD-MM-YYYY)`, y en `verde` `La racha duro N noches (desde DD-MM-YYYY)` (`1 noche` en singular) | si el marcador del issue es válido; en `rojo-sigue` y `rojo-reabierto`, además, solo si su estado es `open` (un marcador `resolved` en un aviso abierto es de una racha que ya terminó, porque su cierre falló después de lo demás: sin número es mejor que con uno equivocado) |
| 3 | `Paso que fallo: PASO` | rojo y hay paso |
| 4 | `Resumen: RESUMEN` | rojo y hay resumen |
| 5 | `Corrida: ENLACE` | siempre |
| 6 | `Aviso: ENLACE` | si se conoce el issue (en `rojo-nuevo` es la URL que imprime `gh issue create`; en los demás, la del issue leído) |

Ejemplo de `rojo-nuevo` (6 líneas):

```text
docker-e2e nightly EN ROJO
Racha: noche 1 (desde 14-10-2026)
Paso que fallo: run_suite
Resumen: total=48 executed=48 skipped=0 failed=2
Corrida: https://github.com/OWNER/REPO/actions/runs/38400000
Aviso: https://github.com/OWNER/REPO/issues/107
```

Ejemplo de `verde` (4 líneas, en silencio):

```text
docker-e2e nightly VOLVIO A VERDE
La racha duro 3 noches (desde 12-10-2026)
Corrida: https://github.com/OWNER/REPO/actions/runs/38500000
Aviso: https://github.com/OWNER/REPO/issues/107
```

El texto se escribe en un archivo (con `printf '%s'`, sin salto de línea final) y nunca viaja por argumentos ni por el entorno.

## 4. La petición

El script escribe `tg.conf` en su directorio temporal privado (modo 0600; lo borra el `trap EXIT`) y ejecuta `curl -K tg.conf` leyendo el código HTTP de la salida estándar:

```text
silent
show-error
max-time = "<TELEGRAM_MAX_TIME>"
output = "<tmp>/tg-response.json"
write-out = "%{http_code}"
url = "<TELEGRAM_API_BASE>/bot<TOKEN>/sendMessage"
data-urlencode = "chat_id=<CHAT_ID>"
data-urlencode = "text@<tmp>/tg-text.txt"
data-urlencode = "link_preview_options={\"is_disabled\":true}"
data-urlencode = "disable_notification=true"
```

La última línea solo se escribe en el tipo `verde`. Los argumentos del proceso son únicamente `-K <ruta>`: el token no aparece en ellos ni en el entorno de ningún hijo. Un solo intento, sin reintentos (`research.md` R22).

## 5. La respuesta

Éxito: código HTTP `200` y `ok` igual a `true` en el JSON de `tg-response.json` (leído con `jq`). Todo lo demás es falla.

## 6. Anotaciones (en `stdout`, formato de Actions)

| Caso | Línea |
|---|---|
| enviado | `::notice::nightly-alert: telegram enviado (tipo=<tipo>)` |
| secretos ausentes o inválidos | `::warning::nightly-alert: empuje por Telegram omitido: <falta TELEGRAM_BOT_TOKEN \| falta TELEGRAM_CHAT_ID \| TELEGRAM_BOT_TOKEN tiene un formato inesperado \| TELEGRAM_CHAT_ID tiene un formato inesperado \| TELEGRAM_API_BASE no es la API de Telegram>` |
| Telegram rechaza o falla | `::warning::nightly-alert: no se pudo enviar el empuje por Telegram (tipo=<tipo>): HTTP <código> <description saneada>` |
| `curl` falla (red, tiempo agotado) | `::warning::nightly-alert: no se pudo enviar el empuje por Telegram (tipo=<tipo>): curl salio con <código>: <primera línea del error, saneada>` |

Todo texto que pudiera contener el token pasa antes por una redacción que lo reemplaza por `***`; el `::warning::` nunca lleva el valor de un secreto.

## 7. Garantías que comprueba el oráculo

El valor centinela del token no aparece nunca en la salida del script, en el cuerpo ni los comentarios del issue, en las llamadas registradas de `gh`, en los argumentos de `curl` ni en el entorno de `gh` (SC-010), tampoco cuando Telegram falla; un secreto ausente o inválido omite el empuje y el issue se publica igual; cada falla de Telegram deja un `::warning::`, sale con 0 y el issue ya está publicado; ningún caso sin acción sobre el issue envía mensaje; el ensayo lleva `[ensayo] `; el mensaje de verde va en silencio y los demás no; el texto es ASCII imprimible de a lo sumo 6 líneas y un nombre o resumen hostil no lo altera.
