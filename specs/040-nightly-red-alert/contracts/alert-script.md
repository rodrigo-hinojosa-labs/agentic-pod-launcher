# Contrato AS: `.github/scripts/nightly-alert.sh`

Un solo script con tres subcomandos. Lo invoca el workflow (`contracts/alert-workflow.md`) y lo ejecuta la suite del host contra un `gh` falso (`contracts/alert-oracle.md`). Reglas de shell: bash 3.2 y 5.x, sin `mapfile`, arreglos asociativos ni `${v,,}`; ningún pipe cuyo consumidor cierre antes que el productor; las cargas grandes por archivo; el cuerpo del issue siempre con `--body-file`.

## 1. Invocación y códigos de salida

```text
nightly-alert.sh collect          # lee STEPS_JSON y e2e.tap; escribe las salidas del job
nightly-alert.sh simulate <red|green|timeout>   # produce e2e.tap y un resultado simulado
nightly-alert.sh notify           # decide y publica el aviso
```

| Subcomando | Código de salida |
|---|---|
| `collect` | siempre 0 (un dato que falta es un campo vacío, no un error) |
| `notify` | siempre 0 (FR-009); cualquier falla se anota con `::warning::` y el script sigue |
| `simulate red` | 1 a propósito, tras escribir un `e2e.tap` con un fallo |
| `simulate green` | 0, tras escribir un `e2e.tap` sin fallos |
| `simulate timeout` | duerme más que el tope del job (variable `TRIAL_TIMEOUT_SLEEP`, 120 s por defecto, para poder probarlo en el host) y sale con 0 si llega a despertar |
| subcomando desconocido o ausente | 2, con el uso en `stderr` |

## 2. `collect`

**Entrada**: variable `STEPS_JSON` (`toJSON(steps)`); archivo `e2e.tap` en el directorio actual (puede no existir); `GITHUB_OUTPUT` (si no está definida, escribe a `stdout`).

**Salidas** (formato `nombre=valor`; las de varias líneas con un delimitador aleatorio `nombre<<DELIM`):

| Salida | Cómo se calcula |
|---|---|
| `failed_step` | el primer id, en el orden de `STEPS_JSON`, cuyo `outcome` es `failure` o `cancelled`; vacío si ninguno o si `STEPS_JSON` no es JSON válido |
| `summary` | si hay `e2e.tap`: `total=N executed=N skipped=N failed=N`, con las mismas tres cuentas del paso `Run docker-e2e suite` (`^(ok\|not ok) [0-9]+`, `^ok [0-9]+ .*# skip`, `^not ok [0-9]+`; `executed = total - skipped`); vacío si no hay archivo |
| `failed_tests` | los nombres de las líneas `not ok N <nombre>`, uno por línea, cada uno recortado a 120 caracteres, hasta 20, más `... y M más` si había más; vacío si no hay fallos o no hay archivo |

**Paridad**: la cadena `summary` es idéntica a la que imprime el paso de la suite (`e2e summary: ` más estas cuentas) para el mismo TAP; una prueba lo exige (AO N19).

## 3. `simulate`

Escribe `e2e.tap` en el directorio actual:

- `red`: `1..4`, tres líneas `ok` y `not ok 4 trial: induced failure`; sale con 1.
- `green`: `1..4` con cuatro `ok`; sale con 0.
- `timeout`: escribe `1..1` y duerme `TRIAL_TIMEOUT_SLEEP` segundos (el job tiene tope de 1 minuto en ese caso).

No imprime nada que parezca un resultado real de la suite, y su nombre de test deja claro que es un ensayo.

## 4. `notify`

**Entrada**: el entorno de `data-model.md` sección 1 (`EVENT`, `TRIAL`, `RUN_RESULT`, `FAILED_STEP`, `SUMMARY`, `FAILED_TESTS`, `RUN_ID`, `RUN_ATTEMPT`, `RUN_URL`, `ASSIGNEE`, `GH_TOKEN`, `GH_REPO`). Una variable ausente se trata como vacía; `GH_TOKEN` nunca se imprime. `NIGHTLY_ALERT_NOW` (opcional, solo para pruebas; el workflow no la define): segundos desde la época que sustituyen al reloj para fechar la noche (marcador `first=` ISO y fechas `DD-MM-YYYY` de las filas); se formatea con `date -u -d @N` (GNU) o `date -u -r N` (BSD), porque las pruebas corren en macOS y en Linux.

**Salida por `stdout`**: anotaciones de Actions, una por decisión:

- `::notice::nightly-alert: modo=<real|trial|ninguno> resultado=<valor> accion=<crea|actualiza|reabre|cierra|ninguna> [motivo]`
- `::warning::nightly-alert: no se pudo <accion>: <estado de gh>`

La primera línea de salida siempre incluye el valor de `RUN_RESULT` recibido (es lo que deja ver, en la corrida de ensayo `timeout`, cómo lo reportó la plataforma).

**Decisión**: la tabla de `data-model.md` sección 5.

**Llamadas a `gh`**, en este orden y solo las que la decisión necesita (flags de research R8):

1. `gh issue list --label L --state all --limit 1 --json number,state,body,url` (siempre que haya modo y clase `red` o `green`).
2. Si hay que crear: `gh label create L --color D93F0B --description "..."` (se ignora el error si ya existe) y `gh issue create --title T --label L --assignee A --body-file F`; si falla con asignado, un segundo intento sin `--assignee` y una anotación.
3. Si hay que actualizar: `gh issue edit N --body-file F` y `gh issue comment N --body-file F`.
4. Si hay que reabrir: `gh issue reopen N --comment C`, y luego lo de 3.
5. Si hay que cerrar: `gh issue edit N --body-file F` (marcador `state=resolved`), `gh issue comment N --body-file F` y `gh issue close N --reason completed`.
6. Verde con el último aviso cerrado a mano (`state=open`): solo `gh issue edit N --body-file F` con el marcador en `state=resolved`; no reabre, no comenta y no cierra (hallazgo I1).

**Manejo de errores**: cada llamada pasa por una función que captura el código y la salida, anota la falla y devuelve; una falla en `list` termina el subcomando con una anotación (sin `list` no se puede decidir) y las demás no impiden el resto de los pasos. Nunca hay `set -e`.

**Idempotencia**: si el cuerpo ya contiene la fila `run=<RUN_ID>`, no se suma la noche ni se comenta de nuevo. Cerrar un aviso ya cerrado no hace nada.

**Archivos temporales**: el cuerpo y los comentarios se arman en un directorio temporal propio (`mktemp -d`) que se borra al salir (`trap … EXIT`); nada de datos del log pasa por argv o por el entorno hacia `gh`.

## 5. Garantías que comprueba el oráculo

Sale siempre con 0 en `collect` y `notify`, incluso con cada llamada a `gh` fallando (AO N12); no escribe nada fuera de su directorio temporal y de `GITHUB_OUTPUT`/`e2e.tap`; no contiene pipes que cierren antes de tiempo ni construcciones de bash 4 (AO N22); da el mismo resultado con SIGPIPE ignorada o por defecto (AO N17).
