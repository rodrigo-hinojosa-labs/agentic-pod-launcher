# Contrato AO: el oráculo del host (`tests/nightly-alert.bats`)

Qué prueba la suite del host (sin Docker ni red) y con qué instrumentos, de modo que un cambio que apague el aviso en silencio haga caer al menos un test. Un chequeo que no puede fallar no es evidencia (025, 039): por eso el oráculo trae sus propias guardias de no-vacuidad y una tabla de mutaciones (en `quickstart.md`).

## 1. El `gh` falso (`tests/fixtures/nightly-alert/gh`)

- Es un script bash que el test pone al frente del `PATH`; mantiene su estado en `$FAKE_GH_STATE` (variable obligatoria: sin ella sale con 99, para que un test no corra contra un estado fantasma).
- **Estado**: `issues.json` (arreglo de issues con `number`, `state` `OPEN|CLOSED`, `title`, `body`, `labels`, `assignees`, `comments`, `url`), `labels.txt` y `calls.log`. Un helper del test siembra issues con un marcador dado.
- **Lista blanca de banderas** (las verificadas en `gh` 2.102.0, research R8): `issue list --label --state --limit --json`; `issue create --title --label --assignee --body-file`; `issue comment --body-file`; `issue edit --body-file`; `issue reopen --comment`; `issue close --reason --comment`; `label create --color --description`. Cualquier otra bandera o subcomando sale con 64, escribe `UNSUPPORTED` en `calls.log` y hace fallar el test: el oráculo no puede aprobar un script que el `gh` real rechazaría.
- **`issue list --json`**: filtra por etiqueta y estado (`open|closed|all`), ordena por número descendente (más reciente primero), aplica `--limit` y proyecta solo los campos pedidos; sin `--jq` (el script filtra con `jq`).
- **Inyección de fallas**: `FAKE_GH_FAIL` con una lista separada por comas de `list`, `label`, `create`, `create_assignee` (falla solo si hay `--assignee`), `edit`, `comment`, `reopen`, `close`. Un comando que falla escribe un mensaje a `stderr`, sale con 1 y no cambia el estado.
- **`calls.log`**: una línea por llamada, `verbo<TAB>argumentos`; las mutantes son `create`, `edit`, `comment`, `reopen`, `close` y `label-create`.

## 2. El arnés

Ejecuta el script con un entorno explícito (las variables de `data-model.md` sección 1), `PATH=<directorio del falso>:$PATH`, en un directorio temporal (allí vive `e2e.tap`), con la disposición de SIGPIPE que pida `SIGPIPE_MODE`, fijada con `perl` justo antes de lanzarlo: `ignore` por defecto (es la que el script hereda en el runner de GitHub) o `default`. A diferencia de 039, donde el `docker` falso en bash necesitaba el valor por defecto para morir como el binario Go, aquí el script debe dar el mismo resultado con las dos, y N17 lo comprueba.

**Costuras de prueba** (el workflow no las define): `ALERT_SCRIPT` y `ALERT_WORKFLOW` apuntan a las rutas bajo prueba (por defecto `.github/scripts/nightly-alert.sh` y `.github/workflows/docker-e2e.yml` del repositorio), de modo que cada mutación se aplica a una copia sin tocar el árbol; `NIGHTLY_ALERT_NOW` fija el "ahora" del script (épocas del 20, 21 y 22-10-2026 a las 12:00 UTC: `1792497600`, `1792584000` y `1792670400`), así que ningún test depende del reloj ni de la medianoche UTC. Deja `status`, `output` y el estado del falso para las aserciones. Las afirmaciones negativas se escriben con `_lacks` o `run …; [ "$status" -ne 0 ]`, nunca con `!` intermedio (bats no lo convierte en falla); los `[[ ]]` intermedios se evitan (muertos en bash 3.2).

## 3. Guardias de no-vacuidad

1. Los casos "sin acción" no se contentan con la ausencia de llamadas mutantes: exigen además la anotación `::notice::nightly-alert:` en la salida (prueba que el script corrió y decidió) y, si correspondía leer, la llamada `list` en `calls.log`.
2. Si el script no existe o no es ejecutable, el primer test que lo invoca falla con un mensaje que lo dice.
3. Un autotest del falso: llamado directo, registra la llamada y rechaza una bandera desconocida (N00). N00 es la **calibración del instrumento**: su capacidad de fallar se demuestra rompiendo el falso una vez (por ejemplo, haciendo que acepte cualquier bandera) y anotándolo.
4. La tabla de mutaciones de `quickstart.md`: cada mutación se aplica a una copia del script o del workflow, el test cazador debe caer, y la copia se descarta.

## 4. Casos (cada uno con su FR/SC)

### Comportamiento de `notify` (gh falso)

| Id | Caso | Afirma | Cubre |
|---|---|---|---|
| N01 | rojo nuevo | crea la etiqueta y el issue con título, etiqueta, asignado y cuerpo (marcador `total=1`, enlace, paso fallido, resumen, nombres en bloque cercado) | FR-001, FR-002, FR-019, SC-001 |
| N02 | rojo sin resumen | `FAILED_STEP=verify_deps`, sin `SUMMARY` ni tests: el cuerpo dice "no disponible" y "ninguno informado" | FR-002 |
| N03 | rojo repetido | con un aviso abierto no se crea otro; `total` +1; fila y comentario nuevos | FR-005 |
| N04 | racha de tres | tres corridas rojas con ids distintos dejan un solo aviso con `total=3` y tres filas | SC-002 |
| N05 | verde tras rojo | marcador `resolved`, comentario con el enlace verde y cierre con razón `completed` | FR-006, SC-003 |
| N06 | verde sin aviso previo | sin aviso, o con el último en `resolved`: cero llamadas mutantes | FR-006 |
| N07 | cancelada y desconocidos | `cancelled`, `skipped` y un valor desconocido: cero llamadas mutantes y el valor aparece en la salida | FR-007, R7 |
| N08 | corrida manual normal | `workflow_dispatch` sin ensayo, en rojo y en verde: cero llamadas, ni siquiera `list` | FR-011 |
| N09 | cierre manual | último aviso `CLOSED` con `state=open` y rojo: se reabre con comentario, `total` +1, no se crea otro | FR-008 |
| N10 | nueva racha | (a) último aviso `CLOSED` con `state=resolved` y rojo: se crea uno nuevo y el anterior no se toca; (b) último aviso `CLOSED` con `state=open` (cerrado a mano) y **verde**: solo se reescribe su marcador a `resolved` con `edit` (sin reabrir, comentar ni cerrar) y el rojo siguiente crea uno nuevo sin reabrir el viejo | FR-008 |
| N11 | ensayo aislado | con un aviso real abierto, un ensayo rojo crea el de ensayo con su etiqueta y no toca el real; un ensayo verde cierra solo el de ensayo | FR-011, FR-016 |
| N12 | fallas de gh | con cada comando fallando por turnos el script sale con 0 y avisa; si falla la asignación, el aviso se crea igual sin asignado | FR-009, FR-019, SC-004 |
| N13 | idempotencia | el mismo `RUN_ID` dos veces, en rojo y en verde: la segunda no cambia nada | Principio IV |
| N14 | cotas | 25 tests fallidos: 20 nombres y `... y 5 mas`; nombres largos recortados; total 155 con 10 filas; cuerpo menor de 60.000 caracteres | FR-003 |
| N15 | texto inerte | nombres con `@usuario`, `#12`, comillas invertidas, `~~~`, `<!--` y `-->`: saneados, bloque cercado íntegro y marcador intacto | FR-004 |
| N16 | marcador inválido | cuerpo editado a mano: se comenta y se reabre si hacía falta, sin reescribir el cuerpo, con advertencia | NF sección 2 |
| N17 | independencia de SIGPIPE | el caso N03 con `SIGPIPE_MODE=ignore` y con `SIGPIPE_MODE=default` da el mismo estado final, la misma salida (incluida `stderr`) y el mismo código; una sonda del arnés (`yes` hacia `head -1`, mirando `PIPESTATUS`) demuestra que cada modo aplica de verdad su disposición (141 en `default`, otro valor en `ignore`) | R14 |

### `collect` y `simulate`

| Id | Caso | Afirma | Cubre |
|---|---|---|---|
| N18 | paso fallido | con ejemplos de `toJSON(steps)`: suite roja, verificación roja, todo verde, `cancelled`, JSON inválido | AS sección 2 |
| N19 | paridad del resumen | el resumen de `collect` es idéntico al que imprime el paso real de la suite (extraído con `yq`, con un `bats` falso) para cuatro TAP | R2 |
| N20 | formato de salidas | nombres con caracteres especiales no rompen `GITHUB_OUTPUT` (delimitador aleatorio) | AS sección 2 |
| N21 | `simulate` | `red` sale con 1 y deja un `not ok`; `green` con 0; `timeout` duerme `TRIAL_TIMEOUT_SLEEP`; desconocido sale con 2 | R6 |

### Estructura y higiene

| Id | Caso | Afirma | Cubre |
|---|---|---|---|
| N22 | higiene del script | `bash -n`, shebang, bit de ejecución, sin construcciones de bash 4, sin pipes que cierren antes de tiempo (con las mismas reglas del ratchet de 039) | R14, Principio III |
| N23 a N31 | AW-1 a AW-9 | las pruebas estructurales de `contracts/alert-workflow.md` sección 5 | FR-009, FR-011, FR-013, SC-007 |

Son **32 tests** (N00 más N01 a N31); `tasks.md` fija el número final y el esperado total (1817 más los nuevos).

## 5. Reglas de la ejecución

- Test-first: los tests se escriben y se ven en ROJO (script y workflow ausentes) antes de crear cualquiera de los dos.
- Gate dual de bash 3.2 y 5.x, secuencial, nunca concurrente; `shellcheck -S error -e SC1090,SC1091` con el comando exacto del job de CI sobre el árbol.
- Los casos de comportamiento no dependen del orden entre sí: cada uno crea su propio estado.
