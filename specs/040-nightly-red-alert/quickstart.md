# Quickstart: validar el aviso del nightly

Guía de validación de la feature: qué correr, en qué orden y qué se espera. No contiene el código del script ni de los tests (están en `tasks.md` y en la implementación); los contratos están en `contracts/` y las entidades en `data-model.md`. Lo marcado **[COMPUERTA]** necesita una autorización explícita del operador antes de ejecutarse (push de la rama, `workflow_dispatch`, PR).

## 1. Prerrequisitos

- Rama `040-nightly-red-alert` desde `main`@`13cafc3`; `VERSION` 0.28.0 (se confirma contra `origin/main` a mano, sin bump).
- Herramientas del host: `bats-core`, `yq` v4, `jq`, `perl`, `shellcheck`, `gh` (para las corridas reales) y, desde la enmienda 1, `python3` (3.9 o posterior; hace de servidor de Telegram en las pruebas) y `curl`.
- Línea base del gate: 1817 ok y 0 not ok en bash 5.x y en 3.2.57 (la CI de `main` sobre `13cafc3` está en verde).
- Para las corridas reales: token de `gh` con el scope `workflow` (lo tiene), push por HTTPS con el helper de `gh`, y los logs bajados con `--allow-escape-sequences`.

## 2. Validación local (sin Docker, sin red)

```bash
# 2.1 El oráculo nuevo, en ROJO antes de existir el script y el workflow editado
bats tests/nightly-alert.bats                      # esperado al empezar: todos not ok

# 2.2 Tras implementar: el oráculo nuevo en verde, en los dos bash, secuencial
bats tests/nightly-alert.bats                      # bash 5.x
PATH=/bin:$PATH bats tests/nightly-alert.bats      # bash 3.2.57
perl -e '$SIG{PIPE}="IGNORE"; exec @ARGV' bats tests/nightly-alert.bats   # el proceso de bats con SIGPIPE ignorada, como en el runner (los casos de comportamiento fijan su propia disposición con SIGPIPE_MODE; esta pasada cubre el resto del archivo)

# 2.3 El gate completo, un bash tras otro (nunca a la vez)
bats tests/                                        # esperado: 1860 ok, 0 not ok (1817 + 43; con la primera versión del oráculo fueron 1849 = 1817 + 32)
PATH=/bin:$PATH bats tests/                        # esperado: lo mismo

# 2.4 shellcheck con el comando exacto del job de CI (incluye .github/scripts)
{ find . -type f \( -name '*.sh' -o -name '*.bash' \) -not -path './.git/*' -not -path './scripts/vendor/*' -not -path './tests/*'
  printf './scripts/agentctl\n./docker/scripts/heartbeatctl\n'; } | xargs shellcheck -S error -e SC1090,SC1091

# 2.5 Alcance (FR-017, SC-007)
git diff origin/main -- docker scripts modules setup.sh | wc -l      # esperado: 0
grep -c 'secrets\.' .github/workflows/docker-e2e.yml                 # esperado: 2 (enmienda 1: solo TELEGRAM_BOT_TOKEN y TELEGRAM_CHAT_ID, ambas en el entorno del paso que publica; antes de la enmienda era 0)
```

Los tests de 039 (`tests/ci-workflows.bats`, 14) deben seguir verdes sin editarse: el paso `Run docker-e2e suite` no cambia de texto.

El oráculo del empuje (N32 a N42) no necesita red ni los secretos reales: prueba el script con el `curl` real contra un servidor HTTP local de Python (`contracts/alert-oracle.md` sección 6) y con un valor centinela como token.

## 3. Mutaciones (SC-005)

Son 20 mutaciones (M2, M12 y M19 con dos variantes cada una). Cada fila se aplica sobre una copia del script o del workflow, apuntando `ALERT_SCRIPT` o `ALERT_WORKFLOW` a ella (los tests no leen otra ruta), el test cazador debe caer y la copia se descarta. Una mutación que sobrevive obliga a endurecer el oráculo antes de seguir.

| Id | Mutación | Cae |
|---|---|---|
| M1 | quitar `always()` del `if` del job `alert` | N23 |
| M2 | (a) agregar `issues: write` al nivel del workflow; (b) agregar una referencia a `secrets.TOKEN` | N25; N27 |
| M3 | quitar `continue-on-error: true` del paso `notify` | N26 |
| M4 | `notify` sale con el código del último `gh` fallido | N12 |
| M5 | crear el aviso sin `--assignee` | N01 |
| M6 | tratar `cancelled` como rojo | N07 |
| M7 | dejar que una corrida manual normal abra el aviso | N08 |
| M8 | en un rojo repetido crear un segundo issue | N03, N04 |
| M9 | en verde no cerrar el aviso | N05 |
| M10 | en verde sin aviso previo crear o comentar | N06 |
| M11 | cierre manual: crear uno nuevo en vez de reabrir | N09 |
| M12 | (a) cierre por verde sin escribir `state=resolved`; (b) un verde sobre un issue cerrado a mano que no reescribe el marcador | N10 |
| M13 | quitar la cota de 20 nombres | N14 |
| M14 | no sanear comillas invertidas ni `~~~` | N15 |
| M15 | `collect` cuenta `executed` igual que `total` | N19 |
| M16 | quitar la guarda de idempotencia (`[run <id>](`) | N13 |
| M17 | el ensayo usa la etiqueta del aviso real | N11 |
| M18 | `run_suite` pierde su `if` de ensayo | N29 |
| M19 | (a) introducir `\| head -1` en el script; (b) introducir un pipe que lee una línea y cierra, con un **productor externo** (`yes \| { read -r _first; }`; solo se nota si cambia la disposición de SIGPIPE) | N22; N17 |
| M20 | cambiar el literal de `timeout-minutes` | N29 |

Extras, fuera de las 20 de la tabla, que la implementación y la revisión independiente agregaron con su cazador (tabla completa en las Notes de `tasks.md`): **M21** quitar `continue-on-error: true` del paso `collect` (N30); **M22** quitar el filtro de la URL de la corrida (N15); **M23** quitar la normalización de CRLF del cuerpo leído (N03); **M24 a M26** una expresión equivocada en el entorno del paso que publica (`job.status` por `needs.e2e.result`, `ASSIGNEE` vacío, un typo en la salida `failed_tests`) (N26); **M27** quitar el `continue-on-error` del `Checkout` del job `alert` y **M28** quitar el tope de 3 minutos del paso que publica (N26); **M29** que `notify` deje de reconocer la línea `... y N mas` (N14); **M30** leer el total del marcador sin pasarlo a decimal (N03); **M31** cerrar el aviso aunque falle la reescritura del marcador (N12); **M33** una llamada que el `gh` real rechazaría (N03 y otros; M32 queda sin usar). Nota sobre M19(b): con el `printf` interno de bash como productor (`printf '%070000d\n%070000d\n' 0 0 \| { read -r _first; }`) la mutación cae en bash 5.x pero **no en 3.2.57**, cuyo `printf` interno no informa los errores de escritura (con SIGPIPE ignorada calla igual que cuando el proceso muere de la señal): es un mutante equivalente en 3.2, no una debilidad de N17; por eso la variante vigente usa un productor externo.

### 3.1 Mutaciones del empuje por Telegram (enmienda 1)

Se suman a las anteriores y se aplican igual (copia del script o del workflow, `ALERT_SCRIPT` o `ALERT_WORKFLOW`, el cazador debe caer, la copia se descarta). Todas deben caer en los dos bash; una que sobreviva obliga a endurecer N32 a N42 antes de seguir. M32 sigue sin usarse.

| Id | Mutación | Cae |
|---|---|---|
| M34 | el mensaje de recuperación sin `disable_notification` (con sonido) | N35 |
| M35 | enviar también cuando no hubo acción sobre el issue (noche ya registrada, cancelada, verde sin aviso) | N36 |
| M36 | (a) el token por argumentos de `curl` (la URL completa en la línea de comandos en vez de `-K`); (b) el archivo de configuración con los permisos por defecto (sin el `chmod 600`) | N39; N39 |
| M37 | no quitar los secretos del entorno con `unset` (el `gh` hijo los hereda) | N39 |
| M38 | imprimir la URL con el token en la advertencia de falla | N38, N39 |
| M39 | no omitir el empuje cuando faltan los secretos (llamar a `curl` igual) | N37 |
| M40 | no validar el formato de los secretos antes de escribir la configuración de `curl` | N37 |
| M41 | el ensayo sin el prefijo `[ensayo]` y su espacio | N40 |
| M42 | enviar el mensaje antes de la acción sobre el issue | N33 |
| M43 | no sanear el paso fallido ni el resumen en el mensaje | N41 |
| M44 | no enviar si falló la acción sobre el issue | N42 |
| M45 | no enviar el rojo cuando no se pudo consultar el issue (`rojo-sin-aviso`) | N42 |
| M46 | propagar el código de `curl` o de Telegram como código de salida | N38 |
| M47 | tomar `200` como éxito sin mirar `ok` | N38 |
| M48 | (a) una referencia a `secrets.` a nivel del workflow; (b) quitar una de las dos variables de Telegram del entorno del paso que publica | N27; N26 |
| M49 | el rojo repetido con el texto de `rojo-nuevo` (noche 1) | N34 |

### 3.2 Extras de la auditoría y de la revisión independiente de la enmienda (M50 a M71)

La auditoría de consistencia y la revisión independiente del 14-10-2026 encontraron aserciones sin mutación que probara que podían fallar y huecos del oráculo; cada uno se cerró con su arreglo o su test y su mutación. Misma mecánica que arriba.

| Id | Mutación | Cae |
|---|---|---|
| M50 | `gh_run` no avisa de la falla de una llamada | N12 |
| M51 | quitar las advertencias del marcador inválido | N16 |
| M52 | `tg_redact` no redacta | N38 |
| M53 | redactar después del corte de 120 caracteres | N38 |
| M54 | el rojo también en silencio (`disable_notification` en todos los tipos) | N33 |
| M55 | sin `link_preview_options` | N33 |
| M56 | el aviso reabierto sin su sufijo | N34 |
| M57 | el singular "noche" siempre en plural | N35 |
| M58 | no borrar el directorio temporal | N39 |
| M59 | enviar la recuperación aunque el aviso no se haya cerrado | N35 |
| M60 | `toJSON(secrets)` en el entorno del paso de la suite | N27 |
| M61 | sin tope de tiempo para las llamadas a `gh` | N42 |
| M62 | `export TG_TOKEN TG_CHAT` (el valor del token en el entorno de los hijos) | N39 |
| M63 | el endpoint por defecto en `http://` | N33 |
| M64 | sin `silent` ni `show-error` en la configuración de `curl` | N33, N38 |
| M65 | anunciar "reabierto" aunque `gh issue reopen` falló | N34 |
| M66 | quitar el empuje `rojo-sin-aviso` de la rama "gh no devolvió una lista" | N42 |
| M67 | la URL que imprime `gh issue create` sin filtro de caracteres de URL | N41 |
| M68 | la URL del aviso listado sin filtro | N41 |
| M69 | sin validar `TELEGRAM_API_BASE` | N37 |
| M70 | imprimir la racha de un marcador `resolved` en un aviso abierto | N34 |
| M71 | sin validar `TELEGRAM_MAX_TIME` | N33 |

En total la feature cierra con 70 identificadores de mutación: 20 de la tabla original (23 filas con sus variantes), 12 extras de la implementación y de la primera revisión (M21 a M31 y M33), 16 de la enmienda (M34 a M49; 18 filas con las variantes de M36 y M48) y 22 extras de la auditoría y la revisión de la enmienda (M50 a M71); M32 queda sin usar.

## 4. Evidencia real **[COMPUERTA]**

### 4.0 Aprovisionamiento del bot y de los secretos (lo hace el operador)

El empuje por Telegram necesita un bot nuevo solo para la CI y dos secretos de repositorio. Lo hace el operador con sus propias cuentas; el agente no ve ni pide los valores, no los escribe en ningún archivo y solo comprueba que los nombres existen (`research.md` R24):

1. En Telegram, con @BotFather: `/newbot`, nombre y usuario del bot de la CI. El token que entrega BotFather no se pega en ningún chat con el agente.
2. Abrir el chat con el bot nuevo y enviarle `/start` (un bot no puede iniciar la conversación).
3. Obtener el chat id con `getUpdates`, leyendo el token sin eco (por ejemplo `read -rs T; printf 'url = "https://api.telegram.org/bot%s/getUpdates"\n' "$T" | curl -sS -K - | jq '.result[].message.chat.id'; unset T`: la configuración entra por la entrada estándar y el token no queda en la línea de comandos).
4. `gh secret set TELEGRAM_BOT_TOKEN --repo rodrigo-hinojosa-labs/agentic-pod-launcher` y `gh secret set TELEGRAM_CHAT_ID --repo rodrigo-hinojosa-labs/agentic-pod-launcher`; cada comando pide el valor por la entrada estándar.
5. Verificación (la hace el agente): `gh secret list --repo rodrigo-hinojosa-labs/agentic-pod-launcher` debe mostrar los dos nombres. Si falta alguno, E1 no se lanza.

Hasta que el operador lo confirme, la implementación y el gate local avanzan sin los secretos reales: el oráculo usa un servidor local y un valor centinela.

### 4.1 La secuencia

Se necesita: la rama empujada, los dos secretos de 4.0 y las corridas lanzadas con `gh workflow run docker-e2e.yml --ref 040-nightly-red-alert -f alert_trial=true -f trial_outcome=<red|green|timeout>`. Cada corrida de ensayo dura cerca de un minuto. Tras cada una se anota: id de la corrida, número del issue de ensayo, conclusión de cada job, la anotación `::notice::nightly-alert:` del log (con `RUN_RESULT`), la anotación del empuje (`telegram enviado (tipo=...)` o su advertencia) y lo que el operador confirma haber recibido en Telegram.

| Paso | Lanzamiento | Esperado | Cubre |
|---|---|---|---|
| E0 | ensayo `green` (precondición, solo mientras el issue #106 del E1 original siga abierto) | el #106 (`total=1`, `state=open`) se marca `resolved`, se comenta y se cierra, y llega `[ensayo] docker-e2e nightly VOLVIO A VERDE` en silencio. Sin este paso la repetición de E1 sería la noche 2 de esa racha de ensayo (`SIGUE EN ROJO`) y no la noche 1 | FR-006, FR-020, FR-023 |
| E1 | ensayo `red` | issue `[ensayo] docker-e2e nightly en rojo` creado, asignado al mantenedor, con la etiqueta de ensayo y `total=1`; el job `e2e` en rojo, el job `alert` en verde; **el mantenedor confirma que le llegó el mensaje de Telegram `[ensayo] docker-e2e nightly EN ROJO` (noche 1, con sonido) sin abrir Issues ni Actions** (el E1 original del 14-10-2026 mostró que el issue funciona y que su notificación de GitHub no llega a donde el operador mira; se repite con el empuje) | FR-001, FR-002, FR-019, FR-020, FR-022, SC-001, SC-009; mediciones M8 y M9 de research |
| E2 | ensayo `red` otra vez | el mismo issue, `total=2`, un comentario nuevo y ningún issue nuevo; llega `[ensayo] docker-e2e nightly SIGUE EN ROJO` (noche 2) | FR-005, FR-020, SC-002 |
| E3 | el mantenedor cierra a mano el issue de ensayo y se lanza ensayo `red` | el mismo issue se reabre con comentario, `total=3`; llega `SIGUE EN ROJO (aviso reabierto)` | FR-008, FR-020 |
| E4 | ensayo `green` | marcador `resolved`, comentario de cierre y issue cerrado; corrida completa en verde; llega `[ensayo] docker-e2e nightly VOLVIO A VERDE` **en silencio** (sin sonido, lo confirma el operador) con las noches de la racha | FR-006, FR-020, FR-023, SC-003 |
| E5 | ensayo `red` | un issue **nuevo** (otra racha); el anterior sigue cerrado; llega `EN ROJO` con la noche 1 | FR-008, FR-020 |
| E6 | ensayo `green` | el issue nuevo se cierra; llega `VOLVIO A VERDE` en silencio | FR-006, FR-020 |
| E7 | ensayo `timeout` | se registra con qué valor entrega la plataforma `needs.e2e.result`, qué hace el script y si llegó un mensaje; decide la regla de research R7 | FR-001, FR-007; medición M7 de research |
| E8 | corrida manual **normal** (sin ensayo; corre los 15 minutos de la suite) | 48 de 48 en verde, el job `alert` omitido, ningún cambio en los issues, ningún mensaje de Telegram y las salidas de `collect` presentes; duración dentro del +1 minuto | FR-011, SC-008, regresión de 039 |

**Regla de la evidencia**: la evidencia vale para el texto que se mergea. Se anota el commit con el que se lanzó E1; si el script o el workflow cambian después, se repiten E1 a E6 o se justifica por escrito que el cambio no toca esos caminos, y antes del PR `git diff <commit de E1>..HEAD -- .github/workflows/docker-e2e.yml .github/scripts/nightly-alert.sh` debe salir vacío o justificado. El E1 original (corrida 38497730831, commit `d4d6e00`, 14-10-2026) probó el flujo del issue y los permisos (M9) con el texto anterior a la enmienda 1; la enmienda cambia el script y el workflow, así que **esa corrida queda como historia y no vale como evidencia del texto final**: E1 a E6 se repiten (precedidas de E0 si el #106 sigue abierto) y E7 y E8, que nunca corrieron, se ejecutan por primera vez sobre el texto final.

**Limpieza al terminar**: cerrar cualquier issue de ensayo abierto (hoy sigue abierto el #106 del E1 original). Los issues de ensayo quedan cerrados como historial y la etiqueta `nightly-red-trial` se conserva.

Si E1 muestra que la política de la organización impide crear issues o etiquetas con el token del workflow (M9 de research), o que el mensaje de Telegram no llega, se detiene la secuencia y se consulta al operador. Para lo segundo, el primer dato es la anotación del empuje en el log de la corrida: `HTTP 401` apunta a un token equivocado, `HTTP 400` con `chat not found` a un chat id equivocado o a un bot al que nunca se escribió `/start`, y `empuje omitido` a un secreto ausente. Si Telegram rechaza `disable_notification` o `link_preview_options` (R18), se corrige el campo en el contrato y en el script con su prueba antes de repetir; cambiar de canal vuelve a `/speckit-clarify`.

## 5. Criterios de éxito: cómo se verifica cada uno

| SC | Cómo |
|---|---|
| SC-001 | E1: el aviso existe al terminar la corrida y contiene los cuatro elementos, y el mensaje de Telegram llega dentro de los 10 minutos siguientes al fin de la corrida (en las Notes se anotan la hora de fin de la corrida y la de recepción que dice el operador) |
| SC-002 | N04 en el host y E2 en real |
| SC-003 | N05 en el host y E4 en real |
| SC-004 | N12 (cada llamada a `gh` fallando por turnos) |
| SC-005 | la tabla de la sección 3, 0 mutaciones sobrevivientes en ambos bash |
| SC-006 | los ids de las corridas E0 a E8 que se hayan lanzado, registrados en las Notes de `tasks.md` |
| SC-007 | los dos comandos de la sección 2.5, con la excepción de las dos referencias a `secrets.` del empuje, y los tests N23 a N31 (N27 reescrito) |
| SC-008 | E8: duración de la suite menos de 1 minuto sobre los ~15 medidos |
| SC-009 | la confirmación humana de E1 repetido: el mensaje de Telegram llegó sin abrir Issues ni Actions (la primera versión pedía la notificación de GitHub y E1 mostró que no era el canal que el operador mira) |
| SC-010 | N39 (el valor centinela del token no aparece en ninguna salida, argumento ni entorno de `gh`) |

## 6. Documentación y cierre

- `CHANGELOG.md`: entrada (sin cambio de `VERSION`) que diga qué cubre el aviso y qué no cubre (FR-018): no detecta un nightly que no llega a arrancar, y la rama `schedule` de la condición solo la ejercen el oráculo y la primera noche roja real. Con la enmienda 1 dice además que el aviso llega por Telegram (bot de la CI y los dos secretos que debe crear el operador) y que sin los secretos el issue funciona igual y el empuje se omite con una advertencia.
- `CLAUDE.md`: entrada de 040 en el bloque SPECKIT (con la enmienda 1) y, si algo nuevo se aprendió, una viñeta en "Common gotchas".
- Commit y push de la rama, las corridas de ensayo, el PR y el merge piden la confirmación del operador, cada uno.
