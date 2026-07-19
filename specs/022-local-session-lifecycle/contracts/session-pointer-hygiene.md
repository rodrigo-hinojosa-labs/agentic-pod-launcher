# Contract: higiene del bridge-pointer por causa de salida (mecanismo B)

**Feature**: 022-local-session-lifecycle · **Base**: `main` = `7e50c44` ·
**Alcance**: modo local únicamente (FR-011: docker byte-idéntico).

Diseño cerrado en `research.md` R1b + R2 (medición en mclaren 2026-07-18 21:15 UTC).
Se **mantiene** `--spawn=session` en la unit: la opción `same-dir` fue medida y
descartada porque reusa el pointer igual (R2, tabla de medición) y destruye la única
señal causal disponible — "por qué murió el proceso anterior".

Tres artefactos nuevos, más una modificación de la unit y del doctor:

| Artefacto | Naturaleza | Origen |
|---|---|---|
| `scripts/lib/session_pointer.sh` | lib compartida (hook + doctor), **no** espejada a `docker/` | nuevo |
| `modules/local-session-exit.sh.tpl` → `scripts/local/agent-session-exit.sh` | hook `ExecStopPost=` | nuevo |
| `modules/local-session-check.sh.tpl` → `scripts/local/agent-session-check.sh` | hook `ExecStartPre=` (segundo) | nuevo |
| `modules/systemd-remote-control.service.tpl` | +2 directivas, `--name` parametrizado | modificado |
| `scripts/agentctl` → `_local_session_doctor` | US2 | nuevo + un bloque **eliminado** |

La lib es fuente única para el hook y el doctor. 021 ya pagó el costo de duplicar la
detección entre `modules/local-secret-check.sh.tpl` y `_local_secrets_doctor`
(`scripts/agentctl:1129`); 022 no lo repite.

---

## 0. Vocabulario y hechos verificados

| Hecho | Fuente | Estado |
|---|---|---|
| `readBridgePointer` valida `{sessionId, environmentId, source, pid?, procStart?}`, borra si mtime > 4 h | `research.md:22-31` (código), `:52-53` (esquema) — extraído del binario 2.1.185 | medido |
| Escritor **vivo** → entorno fresco; escritor **muerto** → reusa `environmentId` **y** `sessionId` | `research.md:83-95` | medido |
| Tras escribir, el proceso re-lee el pointer y **aborta** si el `pid` no es el suyo (guard de split-brain) | `research.md:123-126` | medido |
| Ruta = `<CLAUDE_CONFIG_DIR>/projects/<slug>/bridge-pointer.json`, `slug = ruta.replace(/[^a-zA-Z0-9]/g,"-")`, truncado + hash propietario sobre 200 chars | `research.md:309-314` | medido |
| `CLAUDE_CONFIG_DIR` en local = `<workspace>/.state/.claude` | `modules/remote-control.env.tpl:6` | leído |
| `systemd` entrega `$SERVICE_RESULT`, `$EXIT_CODE`, `$EXIT_STATUS` a `ExecStopPost=` | `research.md:169-170` lo **afirma sin citar fuente** | **NO verificable en este repo** |
| Vocabulario de `$EXIT_CODE`: `exited` \| `killed` \| `dumped` | **ninguna** — `research.md` nunca enuncia estos tres valores; procede de `systemd.service(5)`, no consultado aquí | **NO verificado en ningún artefacto de 022** — lo cierra el gate de hardware |
| Un `{{VAR}}` no definido renderiza **cadena vacía**, en silencio | `scripts/lib/render.sh:135-141` (la sustitución es `:139`) | leído |
| `scripts/heartbeat/` existe en todo workspace | `setup.sh:1853` (`mkdir -p`), `modules/local-qmd-reindex.sh.tpl:43` | leído |

**Marcador**: `<workspace>/scripts/heartbeat/session-exit.json`. Ahí ya viven
`qmd-index.json`, `wiki-graph.json` y los `*-backup.json`. **Prohibido** crear nada
llamado `.env` bajo `.state/`: `backup_identity.sh` cifra esa ruta y empujaría
secretos al fork (CLAUDE.md, hallazgo (4) de 021).

**"Limpiar" nunca significa escribir un pointer nuevo.** El guard de split-brain
(`research.md:123-126`) hace abortar al proceso si el `pid` del pointer no es el
suyo. Limpiar = **renombrar** a un nombre fijo y sobrescribible en el **mismo
directorio**: `bridge-pointer.retired.json`. Nombre fijo ⇒ cota superior de un
archivo, sin crecimiento. Mismo directorio ⇒ `mv` atómico, sin cruce de sistemas de
archivos. El nombre no calza con el glob `*/bridge-pointer.json`, así que ni el
vendor ni nuestro propio fallback lo vuelven a ver.

---

## 1. `scripts/lib/session_pointer.sh` — API pública

Reglas transversales (Principio III + IV):

- Sin efectos al sourcear: solo definiciones. Sin `set -e` / `set -u`.
- bash 3.2 (la suite corre en el bash de stock de macOS). Sin `declare -A`,
  `mapfile`, `local -n`, `${x,,}`.
- `shellcheck -S error` limpio.
- **Ninguna** función ejecuta contenido de archivo: sin `.`/`source`, sin `eval`,
  sin sustitución de comandos sobre texto leído. El pointer y el marcador son
  entradas no confiables (el `.env` remoto de 021 estableció el precedente,
  `scripts/lib/env_file.sh:5-10`).
- Ninguna función imprime valores de secretos. `sessionId` / `environmentId` son
  identificadores operativos y **sí** pueden mostrarse al operador dueño (FR-013,
  `spec.md:192-194`).

### 1.1 `session_pointer_slug WORKSPACE_ABS`

| | |
|---|---|
| **args** | `$1` ruta absoluta del workspace |
| **stdout** | el slug ingenuo: cada carácter que no sea `[a-zA-Z0-9]` reemplazado por `-`. Sin newline final adicional más allá de un `printf '%s\n'` |
| **exit** | `0` siempre |
| **efectos** | ninguno (función pura) |

No reproduce el truncado sobre 200 caracteres ni el hash base-36 propietario
(`h7c`, `research.md:312` y su explicación en `:321-323`). Para eso existe el
fallback de `session_pointer_path`.

Implementación obligatoria con `tr -c 'a-zA-Z0-9' '-'` o `sed 's/[^a-zA-Z0-9]/-/g'`;
**no** con `${var//\//-}`, que solo cubriría la barra (trampa de `research.md:319-320`).

**Trampa de `tr -c`, verificada en este host**: el complemento incluye el `\n`. Con
`echo "$1" | tr -c 'a-zA-Z0-9' '-'` el newline final se convierte en un `-` de más
(`/tmp/a b.c_d/ws-1` → `-tmp-a-b-c-d-ws-1-`, medido) y S12 falla. La entrada debe
alimentarse con `printf '%s' "$1"`, nunca con `echo`.

### 1.2 `session_pointer_path WORKSPACE_ABS CLAUDE_CONFIG_DIR`

| | |
|---|---|
| **args** | `$1` workspace absoluto; `$2` `CLAUDE_CONFIG_DIR` |
| **stdout** | la ruta absoluta del `bridge-pointer.json` cuando se puede determinar; vacío si no |
| **exit** | `0` = ruta determinada (el archivo existe); `1` = **no se puede determinar**; `2` = el pointer no existe pero la ruta es válida (agente sin sesión anunciada todavía) |
| **efectos** | solo lectura |

Resolución, **en este orden exacto** (el orden es load-bearing, ver la nota):

1. `$2` vacío, inexistente, o `$2/projects` inexistente o no listable (sin `r`/`x`)
   → `return 1`. **Este paso va primero**: si se dejara al final sería inalcanzable,
   porque un `$2` ausente hace que el paso 3 globee 0 coincidencias y devuelva `2`
   ("sano, sin sesión") — justo el falso verde que FR-006 prohíbe y que C6/D7
   esperan ver como `unknown`.
2. `dir = $2/projects/$(session_pointer_slug $1)`.
   - Si `dir/bridge-pointer.json` existe → imprime y `return 0`.
   - Si `dir` existe pero el pointer no → `return 2` (silencio: primer arranque).
3. Si `dir` no existe (incluye **todo** path > 200 chars, donde el vendor trunca +
   hashea y nosotros no podemos reproducirlo): glob
   `$2/projects/*/bridge-pointer.json`.
   - Exactamente **1** coincidencia → imprime y `return 0`.
   - **0** coincidencias → `return 2`.
   - **2 o más** → `return 1`. Nunca adivinar entre candidatos (`research.md:330-334`).

La distinción `1` vs `2` es load-bearing: `2` es "sano, todavía sin sesión" (nunca se
reporta como roto, `spec.md:155-156`); `1` es "no se puede determinar" y arrastra
WARN en el doctor y limpieza en el hook (FR-014).

### 1.3 `session_pointer_retire POINTER_PATH`

| | |
|---|---|
| **args** | `$1` ruta del pointer |
| **stdout** | nada |
| **exit** | `0` = renombrado; `1` = no se pudo (ausente, sin permisos, carrera perdida) |
| **efectos** | `mv "$1" "$(dirname $1)/bridge-pointer.retired.json"`, sobrescribiendo |

Única mutación de estado del vendor en toda la feature. **Nunca** crea, escribe ni
edita un `bridge-pointer.json`. Un `1` no es una falla del hook: el llamador lo
convierte en WARN y sale 0.

### 1.4 `session_exit_marker_path WORKSPACE`

`stdout` = `<workspace>/scripts/heartbeat/session-exit.json`. `exit 0` siempre. Pura.
Existe para que el hook y el doctor no dupliquen el literal.

### 1.5 `session_exit_marker_write WORKSPACE RESULT EXIT_CODE EXIT_STATUS`

| | |
|---|---|
| **args** | `$1` workspace; `$2` `$SERVICE_RESULT`; `$3` `$EXIT_CODE`; `$4` `$EXIT_STATUS` (cualquiera puede venir vacío) |
| **stdout** | nada |
| **exit** | `0` **siempre**, incluso si no pudo escribir |
| **efectos** | escribe el marcador de forma atómica: `> tmp` en el mismo directorio + `mv` |

Esquema (schema 1, una sola línea JSON):

```json
{"schema":1,"service_result":"success","exit_code":"exited","exit_status":"0","ts":"2026-07-18T21:15:00Z"}
```

Los tres valores se escriben **verbatim tal como systemd los entregó**, sin
interpretar. Un valor vacío se escribe como `""`. Se emite con `printf` y escapado
mínimo (`\` y `"`), **no** con `jq`: `jq` puede faltar y este camino no puede
depender de él (R5, `research.md:383-388`).

### 1.6 `session_exit_marker_read WORKSPACE`

| | |
|---|---|
| **stdout** | el valor del campo `exit_code` del marcador |
| **exit** | `0` = leído; `1` = ausente, ilegible, o no parseable |
| **efectos** | solo lectura — **no** consume |

Parseo sin `jq` y sin `eval`: extracción por `sed`/`grep` del par `"exit_code":"…"`.
Si `jq` está disponible **puede** usarse como camino preferente, pero su ausencia
jamás cambia el resultado (misma regla de degradación que
`modules/local-healthcheck.sh.tpl:101`). Cualquier shape irreconocible → `1`, nunca
un crash (`spec.md:281-283`).

### 1.7 `session_exit_marker_consume WORKSPACE`

| | |
|---|---|
| **stdout** | el valor de `exit_code` si lo pudo leer; vacío si no |
| **exit** | `0` = había marcador y se consumió; `1` = no había marcador utilizable |
| **efectos** | **mueve** el marcador a un nombre privado temporal, lo lee de ahí y lo borra |

Consumir con `mv` (atómico) y no con `read` + `rm` es lo que hace segura la carrera
de dos arranques simultáneos (`spec.md:141-142`): solo un proceso gana el `mv`; el
perdedor ve "marcador ausente" → "no se puede determinar" → limpia (FR-014). El
resultado neto de la carrera nunca es estado corrupto ni un agente peor que con un
solo arranque.

### 1.8 `session_decide MARKER_VALUE POINTER_STATE`

El corazón testeable. **Función pura**: no toca el sistema de archivos.

| | |
|---|---|
| **args** | `$1` valor de `exit_code` (`exited`, `killed`, `dumped`, otro, o vacío); `$2` estado del pointer: `present` \| `absent` \| `unknown` |
| **stdout** | exactamente una de: `retire` \| `keep` \| `noop` |
| **exit** | `0` siempre |

| `$1` (marcador) | `$2` (pointer) | stdout | Por qué |
|---|---|---|---|
| cualquiera | `absent` | `noop` | El agente aún no anunció sesión. Jamás reportar roto (`spec.md:155-156`). |
| `exited` | `present` | `retire` | Con `--spawn=session` el proceso sale **porque la sesión terminó** (`research.md:130-133`). El pointer apunta a una sesión muerta. |
| `killed` | `present` | `keep` | Lo mató systemd (restart/reboot/stop). La sesión puede seguir viva del lado del servidor y el reuse del vendor restaura continuidad — **medido** (`research.md:189-196`, tabla de medición en mclaren). FR-014 / SC-009. |
| `dumped` | `present` | `retire` | El proceso murió por su cuenta de forma anómala; la sesión no sobrevive de forma demostrable → disponibilidad sobre continuidad. |
| vacío / desconocido | `present` | `retire` | "No se puede determinar" → FR-014 manda disponibilidad sobre continuidad. |
| cualquiera | `unknown` | `noop` | No sabemos **sobre qué archivo** actuaríamos. Nunca adivinar (R4). |

La asimetría entre las dos filas de indeterminación es deliberada y hay que
mantenerla: no saber **por qué murió** ⇒ limpiar (el costo es un link nuevo); no
saber **cuál es el archivo** ⇒ no tocar nada (el costo de equivocarse es corromper
el estado de otro workspace).

---

## 2. `agent-session-exit.sh` — contrato del `ExecStopPost=`

Renderizado desde `modules/local-session-exit.sh.tpl`. Rutas interpoladas **en
tiempo de render**, nunca pasadas por argumento — patrón exacto de
`modules/local-secret-check.sh.tpl:11-13`.

**Lee, y solo lee, del entorno que systemd le entrega**:

| Variable | Uso |
|---|---|
| `$SERVICE_RESULT` | se registra verbatim; no participa del predicado |
| `$EXIT_CODE` | **el discriminador** (`exited` / `killed` / `dumped`) |
| `$EXIT_STATUS` | se registra verbatim (código numérico o nombre de señal) |

**Escribe**: el marcador de §1.5, y nada más. No toca el pointer. No lee el `.env`.
No escribe en `.state/`.

**Garantía de exit 0 incondicional**: `exit 0` como última línea, sin `set -e`, sin
`set -u`, con cada dependencia opcional protegida por `command -v` — el mismo doble
cinturón de 021 (`modules/local-secret-check.sh.tpl:1-9, 66`). Adicionalmente la
directiva lleva prefijo `-`. Un `ExecStopPost` que falla no puede impedir el
siguiente arranque, pero tampoco tiene por qué ensuciar el estado de la unit.

**Salida al journal**: una línea a stderr,
`agent-<name> session-exit: <exit_code>/<exit_status> (result=<service_result>)`.
Sin secretos (FR-013).

**No corre en corte de energía**. Es una limitación aceptada y explícita
(`research.md:181-182`): sin marcador, el arranque siguiente cae en la rama
"no se puede determinar" → `retire` → disponibilidad. Ese es el comportamiento
correcto, no una degradación.

---

## 3. `agent-session-check.sh` — contrato del `ExecStartPre=`

### 3.1 Orden dentro de la unit

`systemd` ejecuta los `ExecStartPre=` **secuencialmente en orden de declaración**,
antes de `ExecStart` (`research.md:348-351`). Estado objetivo del bloque:

```ini
ExecCondition=/usr/bin/test -r {{DEPLOYMENT_WORKSPACE}}/.state/.claude/.credentials.json
ExecStartPre=-{{DEPLOYMENT_WORKSPACE}}/scripts/local/agent-secret-check.sh    # 021 — NO SE MUEVE
ExecStartPre=-{{DEPLOYMENT_WORKSPACE}}/scripts/local/agent-session-check.sh   # 022 — SEGUNDO
ExecStart={{CLAUDE_BIN}} remote-control --name {{DEPLOYMENT_SESSION_NAME}} --spawn=session --verbose
ExecStopPost=-{{DEPLOYMENT_WORKSPACE}}/scripts/local/agent-session-exit.sh    # 022
```

El hook de 021 va **primero** y su línea no se toca (FR-010): el diagnóstico de
secretos debe llegar al journal aunque el hook de 022 se cuelgue o cambie. El hook de
022 va **después** porque es el que muta estado, y porque debe correr lo más cerca
posible de `ExecStart` — es el único punto que se ejecuta antes de que
`claude remote-control` lea el pointer.

El prefijo `-` es obligatorio en ambos: sin él, un `ExecStartPre` que falla marca la
unit como **failed** y el agente no arranca (FR-003).

### 3.2 Árbol de decisión completo

Precondición implícita: `WORKSPACE` y `CLAUDE_CONFIG_DIR` interpolados en render.
El script consume el marcador **primero** (§1.7), resuelve el pointer (§1.2), llama a
`session_decide` (§1.8) y actúa.

Toda línea emitida lleva el prefijo `agent-<name> session-check:` seguido de un
espacio — la convención de 021 (`modules/local-secret-check.sh.tpl:15`, que emite
`agent-${AGENT_NAME} secret-check: WARN: $1`). En la columna de abajo se omite el
prefijo por brevedad; **no es opcional**, y las ramas WARN lo llevan igual, con el
token `WARN:` intercalado entre el prefijo y el texto, tal como en 021.

| # | Estado observado | Acción | Línea emitida a stderr (journal, sin prefijo) |
|---|---|---|---|
| C1 | Pointer `absent` (rc 2 de `session_pointer_path`) | ninguna; el marcador igual se consume | *(silencio — un agente sin login no es un agente roto)* |
| C2 | Marcador `exited`, pointer `present` | `session_pointer_retire` | `previous session ended (exit_code=exited) — retired stale pointer <ruta>` |
| C3 | Marcador `killed`, pointer `present` | ninguna | `previous run was terminated (exit_code=killed) — keeping pointer for session reuse` |
| C4 | Marcador `dumped`, pointer `present` | `session_pointer_retire` | `previous run crashed (exit_code=dumped) — retired pointer` |
| C5 | Marcador ausente / ilegible / valor desconocido, pointer `present` | `session_pointer_retire` | `WARN: cannot determine why the previous run stopped — retiring pointer (availability over continuity)` |
| C6 | Pointer `unknown` (rc 1: glob ambiguo, config dir ausente o ilegible) | ninguna | `WARN: cannot locate the session pointer (N candidates) — leaving state untouched` |
| C7 | Decisión `retire` pero el `mv` falla | ninguna | `WARN: could not retire <ruta> (permissions?) — the agent may re-announce an ended session` |
| C8 | `session_pointer.sh` no se pudo sourcear | ninguna | `WARN: session_pointer.sh unavailable — skipping pointer hygiene` |

**Invariantes del hook**:

- `exit 0` incondicional, sin `set -e` / `set -u` (FR-003, SC-005).
- El marcador se consume **siempre** que exista, en todas las ramas — incluidas C1 y
  C6. Un marcador viejo jamás debe decidir un arranque futuro.
- Jamás escribe un `bridge-pointer.json`. Solo `mv` del existente (guard de
  split-brain, `research.md:123-126`).
- No lee ni imprime nada del `.env`.
- Idempotente: una segunda ejecución sin marcador nuevo cae en C1 o C5-sin-pointer y
  no hace nada (FR-004).

---

## 4. `_local_session_doctor "$agent" "$ws"` — contrato de US2

Cableado en `cmd_local_doctor` (`scripts/agentctl:1258-1315`), después de
`_local_secrets_doctor` (`:1298`). Docker (`cmd_doctor`, `:337-626`) **no se toca**
(FR-011).

Numeración continuada de 021 (que dejó D1-D4 en `_local_secrets_doctor`):

| # | Chequeo | Verde | Rojo |
|---|---|---|---|
| **D5** | La unit **instalada** declara el `ExecStartPre` de session-check | `_doctor_pass` | `_doctor_warn` + hint `sudo cp ./agent-<n>.service /etc/systemd/system/ ; sudo systemctl daemon-reload ; sudo systemctl restart agent-<n>.service` |
| **D6** | La unit **instalada** declara el `ExecStopPost` de session-exit | `_doctor_pass` | mismo WARN + hint |
| **D7** | Veredicto de alcanzabilidad (tabla abajo) | `_doctor_pass` | `_doctor_warn` + hint de recuperación |

D5/D6 inspeccionan la unit **instalada**, no el archivo renderizado, vía
`systemctl show "agent-${agent}.service" -p ExecStartPre --value` /
`-p ExecStopPost --value`, con match de subcadena sobre el nombre del script. Es
literalmente la lección de 021 R6 (`research.md:393-408`): `--regenerate` re-renderiza
pero **solo** reinstala si `install_service:true` **y** `sudo -n` funciona, y nada en
`setup.sh` reinicia la unit; sin esto el doctor daría verde a un agente que jamás
ejecutó el hook. Se usa `show` y no `cat` porque el archivo instalado puede ser
root-only y `cat` falla "Permission denied" y saltaría el chequeo en silencio
(hallazgo del gate mclaren de 021, `scripts/agentctl:1172-1175`).
El formato exacto con que systemd renderiza estas propiedades depende de la versión,
así que la aserción es **subcadena**, nunca igualdad — y el test estubea `systemctl`.

**D7, tabla de veredicto**:

| Estado | Resultado | Texto |
|---|---|---|
| Unit no activa | `_doctor_skip` | `session pointer state (skipped — unit not active)`. Único skip permitido: no es indeterminación sino "el chequeo no aplica"; y no puede dejar verde nada, porque la unit inactiva ya es un `_doctor_fail` en `scripts/agentctl:1276` (exit 2). |
| Pointer `absent` | `_doctor_pass` | `no session pointer yet (agent has not announced a session)` — jamás WARN (`spec.md:155-156`, FR-006). |
| Pointer `present`, marcador **ausente** | `_doctor_pass` | `session pointer looks current` — el estado sano: el hook corrió y consumió. |
| Pointer `present`, marcador **presente** con `exited`/`dumped` | `_doctor_warn` | `agent is likely unreachable: an ended session was never cleaned up` + hint `sudo systemctl restart agent-<n>.service` (el hook lo repara en el arranque). |
| Pointer `present`, marcador **presente** con `killed` | `_doctor_warn` | `pending session-exit marker was never consumed — the startup hook did not run` + hint de reinstalar la unit. |
| Pointer `unknown` (rc 1) | `_doctor_warn` | `cannot determine session pointer state (<N> candidates under <config>/projects)` — **nunca** `_doctor_skip` (FR-006 exige distinguir "no se puede determinar" de "sano"; un skip no cuenta y saldría verde, que es exactamente el modo de falla que ataca la spec, `spec.md:76`). |
| `session_pointer.sh` ausente | `_doctor_warn` | `cannot determine session state (session_pointer.sh unavailable)` + hint `./setup.sh --regenerate`. |

El predicado central de D7 — **marcador presente mientras la unit está activa** — es
causal, no correlacional: si el arranque actual hubiera ejecutado el hook, el
marcador estaría consumido. Su presencia prueba que el hook no corrió, que es
precisamente el estado del incidente medido.

El doctor **nunca** llama a `session_pointer_retire`. Diagnostica; no repara. Reparar
desde un comando que el operador corre a mano contra un agente sano sería exactamente
la remediación recurrente que FR-007 cerca.

### 4.1 Lo que se ELIMINA

`scripts/agentctl:1280-1285` (el bloque "Connection signal seen in journal", que
grepea el journal por `session url|connected|polling`) **se borra**, no se deja
corriendo en paralelo. El healthcheck ya declaró ese predicado falso positivo medido
en mclaren y lo reemplazó por la sonda de socket
(`modules/local-healthcheck.sh.tpl:49-64`: *"A healthy `--spawn=session` is SILENT in
the journal … false-WARNed on every tick even when connected (validated on
mclaren)"*). Dejarlo viola FR-006 (`research.md:498-500`).

No se reemplaza por la sonda de socket: durante el incidente medido el socket `:443`
estaba ESTABLISHED con tráfico bidireccional real mientras el agente era inusable
(`spec.md:74-77`, `research.md:501-504`). Ninguno de los dos predicados existentes
detecta una sesión muerta; D7 es el primero que sí.

**Punto abierto que registro sin decidir**: `cmd_local_status:1240-1247` contiene el
**mismo grep**. No emite veredicto ni afecta el exit code (imprime "last connection
signal" / "no recent connection signal (alive ≠ controllable)"), así que FR-006 no lo
alcanza literalmente. Recomiendo alinearlo por consistencia, pero no lo declaro
obligatorio en este contrato.

**Consecuencia directa para el test S22**: como `cmd_local_status` **conserva** el
patrón, un `grep` a nivel de archivo sobre `scripts/agentctl` seguirá encontrándolo y
daría un falso rojo. S22 debe acotarse al cuerpo de `cmd_local_doctor`, p. ej.
`sed -n '/^cmd_local_doctor()/,/^}/p' scripts/agentctl`, y buscar el patrón ahí dentro.

---

## 5. US3 — `deployment.session_name`

Template: `--name {{HOST_NAME}}-{{AGENT_NAME}}` → `--name {{DEPLOYMENT_SESSION_NAME}}`
(`modules/systemd-remote-control.service.tpl:26`).

**Regla del default, una sola, sin rama de compatibilidad** (FR-009 + FR-015): si
`agent.name` **ya empieza** con el segmento del host, se usa `agent.name` solo; si no,
`<host>-<agent>`. En mclaren: `mclaren-admin` en vez de `mclaren-mclaren-admin`
(`research.md:436-439`).

Resuelto en `setup.sh` y **persistido de vuelta a `agent.yml`** — patrón de
`_persist_claude_cli` (`setup.sh:124-132`; el early-return "el valor no cambió" es
`:130`) y del backfill de `deployment.mode` (`setup.sh:1953-1962`, que corre **antes**
de `render_load_context` — `:1965` — y por eso el valor está disponible en el mismo
`--regenerate`). Flattening `deployment.session_name` → `DEPLOYMENT_SESSION_NAME` por
la convención de `scripts/lib/render.sh:30-31`.

**Sin prompt nuevo en el wizard**, deliberadamente: evita la cascada de tres archivos
de tests (`tests/helper.bash`, los dos arrays de `tests/e2e-smoke.bats`, y las tablas
de 52 prompts de ambos quickstarts con su paridad ES/EN testeada). El campo queda
editable en `agent.yml`, que es lo que FR-008 realmente exige (`research.md:454-459`).

**Trampa de render, verificada**: un `{{VAR}}` no definido renderiza **vacío en
silencio** (`scripts/lib/render.sh:135-141`; la sustitución es `:139`). Un
`DEPLOYMENT_SESSION_NAME` sin
resolver produciría `ExecStart=… remote-control --name  --spawn=session …`, con
`--name` colgando. Por eso hay una aserción dedicada (S24) de que el `--name`
renderizado nunca queda vacío.

**Consistencia obligatoria**: `modules/local-killswitch.sh.tpl:37` compone la misma
identidad de forma independiente (`echo "(session identity: $(hostname)-${AGENT_NAME})."`,
verificado). Si no se actualiza al valor resuelto, imprime una identidad falsa apenas
el nombre se vuelve configurable (`research.md:419-422`). También hay menciones en
`modules/next-steps.es.tpl:426` y `modules/next-steps.en.tpl:418` (ambas hardcodean
la cadena `` `<hostname>-{{AGENT_NAME}}` ``, verificado).

**Esquema**: `.deployment.session_name` entra en `_SCHEMA_OPTIONAL_NONEMPTY`
(`scripts/lib/schema.sh:78-85`): ausente está bien; presente-pero-vacío es error.

---

## 6. Escenarios verificables S1-S28

Todos corren **en el host, sin systemd** (Principio III). systemd se simula de dos
formas, y solo dos:

- **Para los hooks**: systemd no es más que (a) un entorno con `$SERVICE_RESULT` /
  `$EXIT_CODE` / `$EXIT_STATUS` exportados y (b) la invocación del script. El test
  exporta las variables y ejecuta el script renderizado directamente. No hace falta
  nada más — ese *es* el contrato completo de `ExecStopPost`.
- **Para el doctor**: stub de `systemctl` en un `bin/` antepuesto al `PATH`, el patrón
  ya establecido en `tests/agentctl-local.bats:33-43`, sobrescrito dentro del cuerpo
  del test cuando necesita otra semántica (`:507-518`).

Archivos de test propuestos: `tests/session-pointer.bats` (lib pura, S1-S15),
`tests/agentctl-local.bats` (doctor, S16-S23), `tests/local-render.bats` +
`tests/local-install-service.bats` (unit y US3, S24-S28).

**Peligro de bats a respetar** (documentado en `tests/agentctl-local.bats` y en la
memoria del proyecto): una aserción negada `! [[ … ]]` a mitad de cuerpo **no**
falla el test. Usar `if … grep -q …; then false; fi` o `run grep …; [ "$status" -ne 0 ]`.

| # | Precondición | Acción | Resultado esperado | Cubre |
|---|---|---|---|---|
| **S1** | Marcador con `exit_code=exited`; pointer en `<cfg>/projects/<slug>/bridge-pointer.json` | Ejecutar `agent-session-check.sh` | Sale 0; ya no existe `bridge-pointer.json`; existe `bridge-pointer.retired.json` con el contenido original | FR-001, FR-002, SC-001 |
| **S2** | Marcador con `exit_code=killed`; pointer presente | idem | Sale 0; el pointer sigue existiendo **byte-idéntico** (`cmp`); no hay `.retired.json` | FR-014, SC-009 |
| **S3** | **Sin** marcador; pointer presente | idem | Sale 0; el pointer fue retirado (indeterminación → disponibilidad) | FR-014 |
| **S4** | Marcador truncado a mitad de JSON (`{"schema":1,"exit_c`) | idem | Sale 0; pointer retirado; ningún mensaje de error de parseo del shell en stdout | FR-003, FR-014 |
| **S5** | Marcador `exited`; **sin** pointer (directorio `projects/` vacío) | idem | Sale 0; no se crea ningún archivo bajo `projects/`; stderr **no** contiene "WARN" | edge "agente sin login", FR-006 |
| **S6** | Marcador `exited`; pointer presente | Ejecutar el hook **dos veces** | 1ª retira; 2ª es no-op (marcador ya consumido, pointer ausente); ambas salen 0 | FR-004 |
| **S7** | Marcador `exited` y un `.retired.json` **preexistente** | Ejecutar el hook | Existe exactamente **un** `.retired.json` (nombre fijo, sobrescrito); no proliferan archivos | FR-004 |
| **S8** | `SERVICE_RESULT=success EXIT_CODE=exited EXIT_STATUS=0` exportados | Ejecutar `agent-session-exit.sh` | Sale 0; el marcador contiene los tres valores verbatim y `"schema":1` | FR-003 |
| **S9** | **Ninguna** de las tres variables exportada | idem | Sale 0; el marcador se escribe con valores vacíos; no queda basura sin `mv` | FR-003 |
| **S10** | `scripts/heartbeat/` en modo `0500` (no escribible) | idem | Sale **0** igual; no hay traza a stdout | FR-003, Principio IV |
| **S11** | Directorio `projects/<slug>/` en modo `0500` (el `mv` fallará) | Ejecutar el hook con marcador `exited` | Sale **0**; stderr contiene el WARN de C7; el pointer sigue intacto | FR-003, SC-005 |
| **S12** | Workspace `/tmp/a b.c_d/ws-1` | `session_pointer_slug` | Imprime `-tmp-a-b-c-d-ws-1` (todo no-alfanumérico → `-`, no solo la barra) | R4 |
| **S13** | Directorio del slug **inexistente**; exactamente 1 `projects/*/bridge-pointer.json` | `session_pointer_path` | rc 0; imprime esa ruta | R4 (path > 200 chars) |
| **S14** | Directorio del slug inexistente; **dos** `projects/*/bridge-pointer.json` | `session_pointer_path`, y luego el hook | rc 1; el hook sale 0, emite el WARN de C6 y **ninguno** de los dos pointers cambia | R4, FR-003 |
| **S15** | Cualquiera de las ramas anteriores | Ejecutar el hook | En **ningún** escenario aparece un `bridge-pointer.json` que no existiera antes (guard de split-brain: solo se mueve, nunca se escribe) | R1b |
| **S16** | Stub de `systemctl` cuyo `show -p ExecStartPre` devuelve solo `agent-secret-check.sh` | `agentctl doctor` | WARN de D5 nombrando `cp` + `daemon-reload` + `restart`; exit 1 | SC-003, R6 |
| **S17** | Stub cuyo `show -p ExecStopPost` devuelve vacío | `agentctl doctor` | WARN de D6 | SC-003, R6 |
| **S18** | Unit activa; pointer presente; marcador `exited` presente | `agentctl doctor` | WARN "likely unreachable" nombrando el `systemctl restart`; exit 1 | FR-005, SC-003 |
| **S19** | Unit activa; pointer presente; **sin** marcador; stub de `journalctl` que no imprime nada | `agentctl doctor` **5 veces** | Cero warnings de sesión en las 5; el texto "No recent connection signal" **no** aparece nunca | FR-006, SC-004, §4.1 |
| **S20** | `projects/` con dos pointers (glob ambiguo) | `agentctl doctor` | WARN que dice literalmente "cannot determine"; **no** aparece el glifo `⊝` para ese chequeo; exit 1 | FR-006 |
| **S21** | Unit activa; `projects/` vacío (agente recién scaffoldeado, sin login) | `agentctl doctor` | Cero warnings de sesión; nada que sugiera un agente roto | FR-006 |
| **S22** | — | `grep` sobre el **cuerpo extraído** de `cmd_local_doctor` (`sed -n '/^cmd_local_doctor()/,/^}/p'`), **nunca** sobre el archivo entero | ese cuerpo ya no contiene el patrón `session url\|connected\|polling`. Acotar es obligatorio: `cmd_local_status:1240-1247` conserva el mismo patrón a propósito (§4.1) y haría fallar un grep de archivo completo | FR-006, §4.1 |
| **S23** | Workspace en modo **docker** | `agentctl doctor` | `cmd_doctor` no invoca `_local_session_doctor`; render docker byte-idéntico al de `main` | FR-011, SC-007 |
| **S24** | Fixture con `deployment.session_name: "locbot-remote"` | Render de la unit | `ExecStart=… --name locbot-remote --spawn=session --verbose`; y `--name` **nunca** queda seguido de espacio en blanco | FR-008, SC-006 |
| **S25** | `resolve_session_name mclaren mclaren-admin` / `resolve_session_name rpi5 locbot` | Llamada directa a la función de `setup.sh` | `mclaren-admin` y `rpi5-locbot` respectivamente | FR-009, FR-015, SC-006 |
| **S26** | `agent.yml` **sin** `session_name` | `./setup.sh --regenerate` dos veces | La 1ª persiste `deployment.session_name` con el default; la 2ª no cambia el archivo (`cmp` del `agent.yml`) | FR-008, FR-012, Principio I |
| **S27** | — | Suite completa | Siguen verdes **sin editarse** los tests de U1 (`tests/local-render.bats:106-118`), U2 (`:101-104`), U3 (`:120-123`), U5 (`:125-128`, el test de `Environment=`, sin etiqueta `U5` en su nombre) y los **cinco** tests negativos de U4 (`:130-153`) — nueve en total (ver §7) | FR-010, SC-008 |
| **S28** | — | Render del kill-switch | `modules/local-killswitch.sh.tpl` imprime el **mismo** nombre resuelto que la unit, no `$(hostname)-${AGENT_NAME}` | FR-012, consistencia R7 |

---

## 7. Invariantes de 021 que este cambio NO puede romper

Tabulados en `research.md:352-368`; verificados leyendo `tests/local-render.bats` y
`tests/local-install-service.bats` en el árbol actual.

| # | Invariante | Test que lo defiende | Verificado |
|---|---|---|---|
| 1 | `EnvironmentFile=-…/.env` **antes** de `remote-control.env`, por número de línea | `tests/local-render.bats:106-118`; `tests/local-install-service.bats:130-140` | sí — `:113-117` comparan `env_line -lt rc_line` |
| 2 | Prefijo `-` en el `EnvironmentFile` del `.env` (FR-004 de 021) | `tests/local-render.bats:101-104` | sí — `grep -q '^EnvironmentFile=-/home/op/agents/locbot/.env$'` |
| 3 | Ninguna otra unit local tiene `EnvironmentFile` | `tests/local-render.bats:130-153` (5 tests negativos: healthcheck, qmd-reindex, qmd-watch, vault-backup, wiki-graph) | sí |
| 4 | Nunca `Environment=` en la unit (secreto al journal) | `tests/local-render.bats:125-128` (es el U5 de `specs/021-local-secret-delivery/contracts/secret-delivery.md:23`; el nombre del test no lleva la etiqueta) | sí |
| 5 | El `ExecStartPre` de 021 conserva su prefijo `-` y su ruta | `tests/local-render.bats:120-123` | sí — assert anclado a `agent-secret-check.sh` |
| 9 | `ExecCondition` sobre `.credentials.json` | `tests/local-render.bats:74-78` | sí |
| 10 | `User=` operador y `WorkingDirectory=` workspace | `tests/local-render.bats:58-61, 88-91` | sí |
| 11 | Los seams `SETUP_SYSTEMD_DIR` / `LOGIN_SYSTEMD_DIR` gobiernan todo camino de instalación | `tests/local-install-service.bats:106-111` | sí — test "nothing is written to the real /etc/systemd/system" |
| 12 | Camino docker byte-inalterado | rama `regenerate` de `setup.sh` | no re-verificado línea por línea aquí |

Los invariantes 7 (`--dangerously-skip-permissions` ausente,
`tests/local-render.bats:85`) y 8 (`Restart=always`, `:68-72`) también siguen intactos:
022 no toca esas líneas.

**Trampa que hay que atender**, detectada leyendo el test byte a byte:
`tests/local-install-service.bats:113-125` compara con `diff` el resultado de un
`render_to_file` hecho **antes** de correr `./setup.sh --regenerate` contra la unit
instalada. Si `setup.sh` persiste `deployment.session_name` durante ese
`--regenerate`, el lado "expected" se renderizó con la variable **vacía** y el
instalado con el valor resuelto → el `diff` falla. El fixture de ese archivo (el
heredoc `YML` de `:19-56`; su bloque `deployment:` es `:32-37`) debe declarar
`session_name` explícitamente (con lo cual el persist es no-op, igual que
`_persist_claude_cli` cuando el valor no cambió, `setup.sh:130`), o el
`render_load_context` debe moverse después del `--regenerate`. Recomendado: lo
primero, es una línea.

---

## 8. Lo que se rompe a propósito

**Una sola aserción**: `tests/local-render.bats:65`.

```bash
grep -q '^ExecStart=/usr/local/bin/claude remote-control --name rpi5-locbot --spawn=session --verbose$' "$TMP_TEST_DIR/unit"
```

Se rompe porque el template deja de componer el nombre (`{{HOST_NAME}}-{{AGENT_NAME}}`)
y pasa a consumirlo de `agent.yml` (`{{DEPLOYMENT_SESSION_NAME}}`). Es el invariante 6
de `research.md:362`, y la instrucción explícita ahí es que **se actualiza, no se
esquiva**.

Forma de la actualización: el fixture de `setup()` (`tests/local-render.bats:26-31`)
gana `session_name: "locbot-remote"`, un valor **distinto** del default compuesto, y
la aserción pasa a:

```bash
grep -q '^ExecStart=/usr/local/bin/claude remote-control --name locbot-remote --spawn=session --verbose$' "$TMP_TEST_DIR/unit"
```

Se elige un valor distinto del default a propósito: así el test prueba lo que US3
promete (FR-008 — el nombre configurado llega **verbatim** a la unit) en vez de
volver a probar la composición vieja por coincidencia. El **default** queda cubierto
por separado en S25, contra la función resolvedora, donde se puede ejercitar la regla
de-duplicadora (`mclaren` + `mclaren-admin` → `mclaren-admin`) sin renombrar el
agente del fixture y sin arrastrar el resto del archivo.

Efecto colateral obligatorio: `tests/local-render.bats:83` (`grep -q -- '--name'`)
sigue verde tal cual, pero conviene endurecerlo para que `--name` vacío no pase
(escenario S24).

---

## 9. Cosas que este contrato NO afirma

Se listan explícitamente para que nadie las tome por verificadas:

1. **El vocabulario de `$EXIT_CODE`** (`exited` / `killed` / `dumped`) **no aparece en
   ningún artefacto de 022**: `research.md:169-170` afirma que systemd exporta las tres
   variables a `ExecStopPost`, pero lo hace **sin citar fuente** y **sin enumerar los
   tres valores**. Los valores provienen de `systemd.service(5)`, que **no consulté**:
   no pude ejecutar `man systemd.service` ni systemd en este host (macOS). Es la única
   afirmación de este contrato sin respaldo verificable en el repo. Los tests del host
   simulan el contrato exportando las variables — es decir, **asumen** el vocabulario,
   no lo prueban; **el gate de hardware en mclaren es lo único que lo confirma**. Si en
   el hardware el valor real difiere, la rama que se activa es C5 (`retire`), segura
   por FR-014. Acción del gate: registrar el `$EXIT_CODE` observado y corregir este
   documento con la medición.
2. **El formato exacto de `systemctl show -p ExecStartPre --value`** varía por versión
   de systemd. Por eso D5/D6 hacen match de subcadena y no de igualdad. No lo verifiqué
   contra un systemd real.
3. **`ExecStopPost` no corre en corte de energía** — lo tomo de `research.md:181-182`,
   no de una medición propia.
4. **El invariante 12** (docker byte-inalterado) lo cito de `research.md:368`; no
   recorrí la rama `regenerate` de `setup.sh` línea por línea para reconfirmarlo.
5. **`resolve_session_name` es un nombre propuesto**, no una función existente: hoy
   `setup.sh` no tiene ninguna función de resolución de nombre de sesión
   (`HOST_NAME="$(hostname)"` se calcula en `_export_local_context`, `setup.sh:2335`
   — la única otra aparición de `HOST_NAME` es el `export` de `:2332` — y `--name` se
   compone en el template). S25 la testea test-first.
