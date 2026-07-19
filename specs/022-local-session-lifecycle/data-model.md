# Data Model: Remote Control session lifecycle in local mode (022)

**Fecha**: 2026-07-18
**Rama**: `022-local-session-lifecycle`
**Base**: `main` = `7e50c44`
**Fuentes de diseño**: `spec.md` (FR-001..FR-015), `research.md` (R1, R1b, R2, R4, R5, R6, R7, R9)

Este documento modela las cuatro entidades que la feature lee o escribe. Cada
afirmación sobre código lleva su `archivo:línea`; lo que no pude verificar en este
entorno está marcado como **NO VERIFICADO** y recogido al final.

Alcance: **modo local únicamente**. Docker no participa en ninguna de estas
entidades (FR-011) — resuelve su ruta de proyecto con una constante,
`docker/scripts/start_services.sh:693` → `${CLAUDE_CONFIG_DIR_VAL}/projects/-workspace`,
válida porque el cwd del contenedor es siempre `/workspace`.

---

## Mapa de entidades

| # | Entidad | Dueño | Formato | Ubicación | La feature |
|---|---|---|---|---|---|
| E1 | Bridge pointer | **Claude Code (terceros)** | JSON | `<CLAUDE_CONFIG_DIR>/projects/<slug>/bridge-pointer.json` | lee, renombra; **nunca escribe** |
| E2 | Session exit marker | **Nuestro** | JSON | `<ws>/scripts/heartbeat/session-exit.json` | escribe (ExecStopPost), consume (ExecStartPre) |
| E3 | Session name | **Nuestro** | string en `agent.yml` | `deployment.session_name` | resuelve, persiste, renderiza |
| E4 | Reachability state | **Nadie** (derivado) | — | no existe como artefacto | infiere y reporta |

---

## E1 — Bridge pointer (estado de un tercero)

### Propiedad y ciclo de vida

El launcher **no** es dueño de este archivo y no lo crea:
`grep -rn "bridge-pointer" modules/ scripts/ docker/ setup.sh` no devuelve nada
(`spec.md:20-22`). Lo escribe el proceso `claude remote-control`.

| Momento | Quién | Qué hace |
|---|---|---|
| Registro inicial en el relay | proceso `claude` | escribe el pointer con su `pid`/`procStart` |
| Cada 3600 s mientras el proceso vive | proceso `claude` | reescribe el pointer (`setInterval(…, 3600000)`, `research.md:118-122`) → el mtime nunca envejece en un agente de larga vida |
| Al leerlo con schema inválido | `readBridgePointer` | log `[bridge:pointer] invalid schema, clearing` + `unlink` (`research.md:27`) |
| Al leerlo con `mtime` > 4 h | `readBridgePointer` | log `[bridge:pointer] stale (>4h mtime), clearing` + `unlink` (`research.md:29`, `yOl = 14400000`) |
| Cuando el backend concede otro `environmentId` | proceso `claude` | `clearBridgePointer` → arranque limpio (`research.md:112`) |

El "clear" del vendor es un `unlink` plano (`research.md:37-39`).

### Esquema validado (extraído de 2.1.185 en mclaren, `research.md:53-54`)

```
{
  sessionId:      string          # requerido
  environmentId:  string          # requerido
  source:         "standalone" | "repl"   # requerido, enum cerrado
  pid:            number?         # opcional
  procStart:      string?         # opcional
}
```

`readBridgePointer` añade en memoria `ageMs` (`research.md:30`); ese campo **no
está en disco**.

Valores medidos en vivo (`research.md:62-66`):

| Fuente | Valor |
|---|---|
| `systemctl show agent-mclaren-admin.service -p ExecStart` | `pid=59237` |
| `awk '{print $22}' /proc/59237/stat` | `141705` |
| `bridge-pointer.json` | `"pid": 59237, "procStart": "141705"` |

`procStart` es el campo 22 de `/proc/<pid>/stat` (`starttime`, ticks desde el boot),
serializado como **string**. El par `(pid, procStart)` identifica una *instancia de
proceso*, inmune a reuso de pid (`research.md:68-70`).

### Ruta: el slug y sus dos trampas

La función del vendor (`research.md:309-314`):

```js
function FS(e){ let t=e.replace(/[^a-zA-Z0-9]/g,"-");
                if(t.length<=CVe) return t;
                return `${t.slice(0,CVe)}-${h7c(e)}` }     // CVe = 200
function _Vn(e){ return join(<config>/projects, FS(e), "bridge-pointer.json") }
```

- La sustitución es **todo carácter no alfanumérico** → `-`, no solo `/`. Un punto,
  espacio o guion bajo en la ruta del workspace produce slug distinto.
- Sobre **200 caracteres** el slug se trunca y se sufija con un hash base-36 interno
  (`h7c`) que **no podemos reproducir en bash**.

`CLAUDE_CONFIG_DIR` en modo local está fijado a `<ws>/.state/.claude`
(`modules/remote-control.env.tpl:6`), y el directorio del que se deriva el slug es el
cwd del proceso = `WorkingDirectory={{DEPLOYMENT_WORKSPACE}}`
(`modules/systemd-remote-control.service.tpl:11`).

**Resolución de ruta (decidida en `research.md:330-335`)**:

1. Calcular el slug ingenuo (`[^a-zA-Z0-9]` → `-`) y usarlo **si el directorio existe**.
2. Si no existe — lo que incluye toda ruta > 200 chars — hacer glob de
   `<CLAUDE_CONFIG_DIR>/projects/*/bridge-pointer.json` y actuar **solo si hay
   exactamente 1** coincidencia.
3. 0 o ≥ 2 coincidencias → **"no se puede determinar"** → no-op.

Medido en mclaren: `/home/rodrigo-hinojosa/Documents/Personal/Claude/Agents/mclaren-admin`
→ `-home-rodrigo-hinojosa-Documents-Personal-Claude-Agents-mclaren-admin` (69 chars,
un solo directorio de proyecto presente) (`research.md:325-328`).

Este cómputo es **código nuevo**: el repo no tiene hoy ninguna transformación
ruta→slug (`research.md:336-338`). Por eso vive en `scripts/lib/session_pointer.sh`,
fuente única para el hook y el doctor — 021 ya pagó el costo de duplicar la lógica de
detección entre su hook de boot y `_local_secrets_doctor` (`research.md:341-342`).

### Estados del pointer (los que nuestro código debe distinguir)

| Estado | Cómo se reconoce | Quién lo repara |
|---|---|---|
| `ABSENT` | archivo no existe | nadie — es el estado de un agente sin login (spec Edge Cases, `spec.md:156-157`) |
| `LIVE` | existe, parsea, `pid` == MainPID de la unit activa | nadie: es el estado sano |
| `ORPHANED` | existe, parsea, su escritor está muerto | **no distinguible en sí mismo**: es el estado normal tras un restart (`research.md:100-106`) |
| `TTL_EXPIRED` | `mtime` > 4 h | el vendor, al leerlo (`research.md:29`) |
| `UNPARSEABLE` | JSON roto o schema fuera del enum | el vendor, al leerlo (`research.md:27`); para **nosotros** es "no se puede determinar" |
| `RETIRED` | nombre fijo distinto de `bridge-pointer.json` | nuestro hook lo dejó ahí; nadie lo lee |

**`ORPHANED` no es el defecto.** Un escritor muerto es el estado normal después de
cualquier restart, y es justamente el que dispara la *reutilización* del vendor
(`research.md:101-102`, sobre el código extraído en `research.md:87-92`: escritor vivo
→ entorno fresco; escritor muerto → reusar `environmentId` **y** `sessionId`).
Limpiar por "escritor muerto" dispararía en cada
arranque — la degeneración "renovar siempre" que SC-009 prohíbe (`research.md:100-106`).
La discriminación tiene que venir de fuera del pointer: de E2.

### Contrato de tolerancia (FR-003, `spec.md:281-283`)

El formato es interno de Claude Code y puede cambiar entre versiones. Toda lectura
nuestra debe cumplir:

- Ausencia, JSON inválido, campo faltante, `source` fuera del enum, o cualquier shape
  no reconocido → **"no se puede determinar"**, nunca crash y nunca `exit != 0`.
- `jq` ausente → misma degradación. El patrón está establecido:
  `modules/local-healthcheck.sh.tpl:101` degrada a WARN, y el hook de 021 guarda cada
  dependencia con `command -v` (`modules/local-secret-check.sh.tpl:28,37`).
- El archivo llega potencialmente de un origen remoto (el flujo
  `--restore-from-fork` de 021 estableció el precedente): **jamás** `source`, `eval`
  ni sustitución de comandos sobre su contenido — la razón por la que existe
  `scripts/lib/env_file.sh:1-13`.
- Nunca depender de campos que el vendor no documenta como contrato (`spec.md:300-301`).

---

## E2 — Session exit marker (nuestro)

Es la entidad que esta feature **inventa**. Aporta el único discriminador que el
pointer no tiene: *por qué* se detuvo el proceso anterior.

### Ubicación

`<workspace>/scripts/heartbeat/session-exit.json`

Ese directorio ya es el hogar del estado operativo del agente:
`qmd-index.json` (`scripts/lib/qmd_index.sh:65`), `wiki-graph.json`
(`scripts/lib/wiki_graph.sh:78`), `*-backup.json`. En modo local el mismo directorio
se usa explícitamente: `modules/local-qmd-reindex.sh.tpl:43` exporta
`QMD_INDEX_STATE_FILE="${WORKSPACE}/scripts/heartbeat/qmd-index.json"`.

**Prohibido** ubicarlo bajo `.state/` con el nombre `.env`: son dos call sites
distintos y ambos aplican — `docker/scripts/lib/backup_identity.sh:71-73` mete
`$state_dir/.env` en el hash de idempotencia, y `:152-157` lo **cifra a `.env.age`**
(`age -R … -o "$stage/.env.age" "$state_dir/.env"`, `:154`) dentro del stage que se
empuja a la rama `backup/identity`, es decir empujaría el archivo al fork.
(El pointer y su versión retirada sí viven bajo `.state/.claude/projects/`, pero eso
**no** entra al backup: el whitelist son 4 rutas explícitas —
`docker/scripts/lib/backup_identity.sh:30-38` — y `.claude/projects` no está entre
ellas.)

### Esquema

```json
{
  "schema": 1,
  "written_at": "2026-07-18T21:15:04Z",
  "service_result": "success",
  "exit_code": "exited",
  "exit_status": "0"
}
```

| Campo | Tipo | Origen | Obligatorio | Notas |
|---|---|---|---|---|
| `schema` | integer | constante `1` | sí | mismo convenio que `wiki_graph.sh:96-98` (`--argjson schema 1`) y `scripts/heartbeat/heartbeat.sh:376` (`{schema:1, …}`). Ojo: `qmd-index.json` **no** lleva `schema` (`qmd_write_state` escribe `{hash,last_run,last_status,runs[,pending]}`, `qmd_index.sh:305-307`) — no es precedente del convenio |
| `written_at` | string ISO-8601 UTC | reloj del host | sí | solo diagnóstico; **el predicado no usa tiempo** |
| `service_result` | string | `$SERVICE_RESULT` | sí (puede ser `""`) | contexto para el operador |
| `exit_code` | string | `$EXIT_CODE` | sí (puede ser `""`) | **el único campo del que depende el predicado** |
| `exit_status` | string | `$EXIT_STATUS` | sí (puede ser `""`) | código numérico o nombre de señal |

systemd entrega las tres variables a `ExecStopPost=` (`research.md:169-170`).
Ningún campo contiene valores de secretos (FR-013): son códigos de salida.

### Quién escribe, quién consume

- **Escribe**: `ExecStopPost=-<ws>/scripts/local/agent-session-exit.sh`, en cada
  detención de la unit de sesión.
- **Consume**: un **segundo** `ExecStartPre=-<ws>/scripts/local/agent-session-check.sh`,
  declarado **después** del `agent-secret-check.sh` de 021
  (`modules/systemd-remote-control.service.tpl:25`). systemd ejecuta los
  `ExecStartPre=` secuencialmente en orden de declaración, antes de `ExecStart`, así
  que es el único seam **utilizable** que corre antes de que `claude remote-control`
  lea el pointer (`research.md:348-351`). El `ExecCondition=` de la línea 22 corre
  todavía antes, pero está descartado por semántica: un rc distinto de 0 ahí **salta
  la unit entera**, exactamente lo que FR-003 prohíbe.

### Semántica de consumo único

El marcador se **borra al leerlo**, gane la decisión que gane. Sin eso, un marcador
de dos arranques atrás decidiría el arranque actual.

- El borrado es idempotente (`rm -f`): dos arranques concurrentes no lo corrompen.
- El segundo de dos arranques concurrentes encuentra el marcador ya consumido →
  "no se puede determinar" → limpia (FR-014) — no queda peor que un arranque único
  (Edge Case "concurrent starts", `spec.md:141-143`).
- **Consecuencia para el doctor**: en régimen normal el marcador **no existe** cuando
  el operador corre `agentctl doctor`. Su ausencia jamás debe reportarse como problema
  (FR-006, o sería la falsa alarma que entrena al operador a ignorar el reporte).

### Ausencia del marcador

`ExecStopPost` no corre en un corte de energía ni si systemd mismo muere. Ese caso
es indistinguible de "primer arranque" y de "marcador ya consumido", y los tres
colapsan al mismo camino: **"no se puede determinar" → limpiar**, porque FR-014 manda
priorizar disponibilidad sobre continuidad ante la duda (`spec.md:196-199`).

### Predicado (el corazón de la feature)

| `exit_code` | Interpretación bajo `--spawn=session` | Verdicto |
|---|---|---|
| `killed` | lo detuvo systemd (restart / reboot / stop) → la sesión puede seguir viva del lado del servidor | **KEEP** (no tocar el pointer) |
| `exited` | el proceso salió solo → con capacidad 1 eso significa que la sesión **terminó** → el pointer apunta a una sesión muerta | **CLEAR** |
| `dumped` | crash con volcado: ni salida limpia ni detención ordenada | **CLEAR** (cae en el caso indeterminado) |
| `""` / desconocido / marcador ausente / JSON ilegible | no se puede determinar | **CLEAR** |

El predicado es una **lista blanca de un solo valor** para KEEP: cualquier cosa que no
sea exactamente `killed` limpia. Ese default-deny hacia la disponibilidad *es* FR-014.

El significado causal solo existe bajo `--spawn=session`, donde el proceso sale
**porque** la sesión terminó (`research.md:208-219`). Bajo `same-dir` el proceso
sobrevive a sus sesiones y "fue matado" ya no implica "la sesión sigue viva": adoptar
`same-dir` destruiría la única señal local disponible. Por eso `--spawn=session` se
mantiene (`research.md:222-231`).

### "Limpiar" = renombrar, nunca escribir

`CLEAR` renombra el pointer a un **nombre fijo y sobrescribible** en el mismo
directorio (p. ej. `bridge-pointer.json.retired`), nunca escribe un pointer nuevo.

Razones, en orden de peso:

1. **Guard de split-brain**: justo después de escribir, el proceso relee el pointer y
   sale con "Another `claude remote-control` instance (pid N) is already running in
   this directory" si el pid difiere (`research.md:124-126`). Un pointer escrito por
   nosotros mataría el arranque.
2. **Nombre fijo** ⇒ acotado a un archivo, sin crecimiento sin límite y sin necesidad
   de rotación.
3. **Basename distinto de `bridge-pointer.json`** ⇒ ni `_Vn` del vendor
   (`research.md:314`, join exacto) ni nuestro glob de fallback
   (`*/bridge-pointer.json`) lo ven jamás.
4. Renombrar preserva evidencia forense del incidente; el `unlink` del vendor
   (`research.md:37-39`) no.

---

## E3 — Session name

### Situación actual

`modules/systemd-remote-control.service.tpl:26`:

```
ExecStart={{CLAUDE_BIN}} remote-control --name {{HOST_NAME}}-{{AGENT_NAME}} --spawn=session --verbose
```

`HOST_NAME` se calcula en tiempo de render — `HOST_NAME="$(hostname)"`,
`setup.sh:2335` (dentro de `_export_local_context`) — y **no** sale de `agent.yml`.
Dos efectos secundarios registrados en `research.md:417-422`:

- la identidad de sesión depende del hostname vivo y no de `deployment.host`
  (`setup.sh:1150`), así que mover el workspace de máquina la cambia en silencio;
- existe una **segunda** composición independiente de la misma identidad en
  `modules/local-killswitch.sh.tpl:37` (`$(hostname)-${AGENT_NAME}`), que imprimiría
  una identidad falsa si el nombre pasa a ser configurable y ese archivo queda atrás.

`--name` no se usa en ningún otro lugar (verificado por `grep -rn` sobre `modules/`,
`scripts/`, `docker/`, `setup.sh`, `tests/` — `research.md:424-427`): es puramente la
etiqueta que muestra claude.ai/code. No toca el nombre de la unit, ni el healthcheck,
ni el doctor. Eso es lo que hace a US3 de bajo riesgo.

### Modelo

| Aspecto | Valor |
|---|---|
| Campo | `deployment.session_name` |
| Tipo | string no vacío, opcional |
| Variable de render | `DEPLOYMENT_SESSION_NAME` (convenio `section.key → $SECTION_KEY`, `scripts/lib/render.sh:30-31`) |
| Validación de schema | `_SCHEMA_OPTIONAL_NONEMPTY` (`scripts/lib/schema.sh:78-85`): ausente está bien; presente y vacío es error |
| Consumidor | `modules/systemd-remote-control.service.tpl:26` (y, por consistencia, `modules/local-killswitch.sh.tpl:37`) |
| Persistencia | escrito de vuelta a `agent.yml` (patrón `_persist_claude_cli`, `setup.sh:124-132`; backfill como `deployment.mode`, `setup.sh:1957-1961`) |
| Prompt de wizard | **ninguno**, deliberadamente (`research.md:453-459`) |

### Regla del default (FR-009 + FR-015, una sola regla)

Si `agent_name` **ya empieza** con el segmento del host → usar `agent_name` solo.
Si no → `<host>-<agent>`.

En mclaren eso da `mclaren-admin` en vez de `mclaren-mclaren-admin`, que es
exactamente el cambio que el operador ya aplicó a mano (`research.md:436-439`).

**Sin rama de compatibilidad**: workspaces existentes y nuevos resuelven igual
(FR-015). El cambio de identidad de una sola vez en el cliente está aceptado
(`spec.md:266-270`) y va documentado en las notas de upgrade.

### Normalización

El valor es una **etiqueta de presentación**, no participa en nombres de archivo,
ramas, unidades ni contenedores, así que no requiere la normalización que
`agent_name` sí exige. Dos observaciones honestas:

- `agent_name` ya llega normalizado (minúsculas, sin espacios) por el wizard.
- `hostname` **no** se normaliza (`setup.sh:2335` lo toma literal), de modo que un
  FQDN o un host con mayúsculas entra verbatim al default. Eso es el comportamiento de
  hoy, no una regresión de esta feature — el template ya componía `{{HOST_NAME}}-{{AGENT_NAME}}`.

El backfill debe respetar el orden que ya establece `setup.sh`: la escritura ocurre
**antes** de `render_load_context` (`setup.sh:1964-1965`), de modo que el valor está
disponible en el mismo `--regenerate` que lo creó.

---

## E4 — Reachability state

No existe como artefacto. Es la propiedad "¿puede un cliente usar este agente ahora
mismo?" y ninguna señal local la reporta (`spec.md:216-218`).

### Lo que es observable localmente

| Señal | Observable | ¿Sirve? | Evidencia |
|---|---|---|---|
| `systemctl is-active` | sí | **no** — dijo `active` durante el incidente | `spec.md:73` |
| Contador de restarts | sí | **no** — cero durante el incidente | `spec.md:73-74` |
| Errores en el journal | sí | **no** — ninguno durante el incidente | `spec.md:74` |
| `ExecCondition` / `ExecStartPre` rc | sí | **no** — ambos salieron 0 | `spec.md:74` |
| Socket `:443` ESTABLISHED del MainPID | sí | **no** — establecido y con tráfico bidireccional real mientras el agente era inusable | `spec.md:75`, `research.md:501-504` |
| Grep del journal por `session url\|connected\|polling` | sí | **activamente engañoso** en ambos sentidos | `modules/local-healthcheck.sh.tpl:49-54`, `research.md:485-494` |
| Pointer presente, parseable, `sessionId`/`environmentId` | sí | sí, como contexto | E1 |
| `mtime` del pointer vs TTL de 4 h | sí | parcialmente: > 4 h el vendor lo limpia solo | `research.md:29` |
| `pointer.pid` vs `MainPID` de la unit activa | sí | **candidato, sin medir** | ver más abajo |
| `ExecStartPre` con el hook en la unit **instalada** | sí | sí — detecta el no-op silencioso | `research.md:404-408` |

**El grep del journal ya está en producción y hay que sacarlo.**
`scripts/agentctl:1280-1285` decide "connection signal" con exactamente ese grep, y
el healthcheck ya lo abandonó por falso positivo medido:
`modules/local-healthcheck.sh.tpl:50-54` — *"A healthy `--spawn=session` is SILENT in
the journal, so grepping it for 'session url|connected|polling' false-WARNed on every
tick even when connected (validated on mclaren)"*. Dejarlo corriendo en paralelo con
un check bueno viola FR-006 (`research.md:496-500`).

`pointer.pid` vs `MainPID`: tras un restart con reutilización, el vendor reescribe el
pointer con el pid nuevo (medido: `sessionId` y `environmentId` sin cambio, solo
`pid`/`procStart` actualizados — `research.md:194`). Con la unit activa y sana se
esperaría `pointer.pid == MainPID`. Una divergencia significa o bien la rama
"deferring pointer write" (otro escritor vivo, `research.md:89`) o bien un pointer que
el proceso actual nunca reescribió. Es una señal local, causal y barata — **pero su
tasa de falsos positivos no está medida**, y FR-006 y FR-007 exigen medirla antes de
convertirla en predicado. Queda como candidato para el plan, no como hecho.

### Lo que NO es observable localmente

- Si el servidor considera abierta la sesión. No hay superficie de cliente soportada;
  consultarlo metería una dependencia de red en el camino de boot, rechazado contra
  FR-003 (`research.md:250-251`).
- Si `reconnectSession` adoptó la sesión. La línea existe en el journal
  (`[bridge:init] Adopted session … re-queued via bridge/reconnect`,
  `research.md:113`), pero la línea de estado se redibuja in situ y llega al journal
  como `[66B blob data]`, así que el último texto legible miente
  (`research.md:252-254`). Predicado cerrado por la spec; no reabrir.

### Convención para "no se puede determinar"

El repo tiene dos convenciones incompatibles: el healthcheck lo trata como **WARN**
(`modules/local-healthcheck.sh.tpl:63`, testeado en `tests/local-healthcheck.bats:110-115`);
el doctor lo trata como **skip** (⊝, sin contador — `scripts/agentctl:105-119`).

**Decisión (`research.md:509-518`)**: `_doctor_warn` con texto explícito de
indeterminación. `_doctor_skip` queda reservado para "este check no aplica a esta
configuración". Elegir skip haría que un estado de sesión ilegible saliera **verde y
con exit 0** — precisamente el modo de falla contra el que se escribió la spec
(`spec.md:76`).

Contrato de salida del doctor local (`scripts/agentctl:1304-1314`): 0 limpio,
1 solo warnings, 2 cualquier fail. El segundo argumento de `_doctor_warn`/`_doctor_fail`
se imprime como línea `→` y es donde va el comando de recuperación que exige FR-005.

---

## Transiciones de estado del pointer

Notación: **KEEP** = el hook no toca el pointer; **CLEAR** = lo renombra al nombre
retirado fijo.

| # | Evento | Causa de salida (`exit_code`) | Marcador al siguiente arranque | Verdicto | Pointer tras el hook | Qué hace el vendor después | Resultado para el operador |
|---|---|---|---|---|---|---|---|
| 1 | **Arranque limpio** (primer boot, sin login) | — (no hubo proceso previo) | ausente | CLEAR → **no-op** (no hay pointer) | `ABSENT` | crea sesión y pointer nuevos | agente utilizable; link nuevo (esperado) |
| 2 | **`systemctl restart`** con sesión viva | `killed` | presente, `killed` | **KEEP** | intacto | lee el pointer, pide reutilización, el backend re-concede el mismo `environmentId`, `reconnectSession` adopta | **mismo link** — continuidad (medido, `research.md:190-197`) |
| 3 | **Reboot ordenado** | `killed` (asumido — ver No verificado #1) | presente, `killed` | **KEEP** | intacto | igual que #2 | mismo link, agente utilizable |
| 4 | **Sesión terminada desde el cliente** (capacidad 1 → el proceso sale por diseño) | `exited` | presente, `exited` | **CLEAR** | `RETIRED` | no encuentra pointer → sesión y entorno nuevos | **link nuevo, agente utilizable** ← este es el arreglo (`research.md:129-139`) |
| 5 | **Corte de energía / SIGKILL a systemd** | `ExecStopPost` no corre | **ausente** | CLEAR (no se puede determinar) | `RETIRED` | pointer ausente → sesión nueva | link nuevo; costo aceptado por FR-014 |
| 6 | **Crash con volcado** | `dumped` | presente, `dumped` | CLEAR (no es `killed`) | `RETIRED` | sesión nueva | link nuevo, agente utilizable |
| 7 | **Dos arranques concurrentes** | cualquiera | el 1.º lo consume; el 2.º lo ve ausente | 1.º según su valor; 2.º CLEAR | a lo más un `RETIRED` (nombre fijo, se sobrescribe) | según el pointer resultante | no queda peor que un arranque único (`spec.md:141-143`) |
| 8 | **Pointer con más de 4 h de `mtime`** | cualquiera | cualquiera | según #2-#6 | si KEEP, sigue ahí | el vendor lo borra al leerlo (`research.md:29`) | sesión nueva; nuestra decisión es irrelevante aquí |
| 9 | **Pointer ilegible / schema no reconocido** | cualquiera | cualquiera | según #2-#6 — **el pointer no participa del predicado**, solo el `exit_code` del marcador | según ese verdicto (renombrar NO exige parsear el pointer) | si sobrevive, el vendor lo borra al leerlo (`research.md:27`) | sesión nueva |

El evento raíz del incidente medido es el **#4 seguido de un arranque**, no el reboot:
la sesión terminó a las 13:51:37, `Restart=always` revivió el proceso 12 s después, se
pidió reutilización de una sesión ya terminada, `reconnectSession` falló de forma
**transitoria** (no un error definitivo de API), el `sessionId` muerto se conservó y no
se creó sesión nueva. El reboot de las 13:57:40 solo propagó un pointer ya envenenado
(`research.md:128-141`). Un pointer envenenado contamina cada arranque siguiente hasta
que se elimina o pasan 4 h.

---

## Invariantes

Lo que el código **nunca** debe hacer con estos datos.

**Sobre el bridge pointer (E1)**

1. **Nunca escribir ni crear un `bridge-pointer.json`.** El guard de split-brain del
   proceso hace salir el arranque con error si el pid del pointer no es el suyo
   (`research.md:124-126`). Las únicas mutaciones permitidas son *renombrar* y
   *no tocar*.
2. **Nunca `rm` el pointer**: `CLEAR` es un rename a un nombre fijo y sobrescribible.
   Acotado a un archivo, sin rotación, y conserva evidencia forense.
3. **El nombre retirado nunca es `bridge-pointer.json`** ni encaja en
   `*/bridge-pointer.json`, para que ni `_Vn` del vendor ni nuestro glob de fallback lo
   lean jamás.
4. **Nunca `source`, `eval` ni sustitución de comandos** sobre el contenido del
   pointer. Es contenido de un tercero, potencialmente de origen remoto; parsear,
   nunca ejecutar (el principio que motivó `scripts/lib/env_file.sh:1-13`).
5. **Un shape no reconocido nunca es un crash**: es "no se puede determinar"
   (FR-003, `spec.md:281-283`). Tampoco es un error reportable — el formato es interno
   del vendor y puede cambiar entre versiones.
6. **Nunca depender de campos no documentados** como si fueran contrato estable
   (`spec.md:300-301`); toda lectura tolera su ausencia.
7. **Nunca actuar con el glob de fallback si hay 0 o ≥ 2 coincidencias**
   (`research.md:330-335`). Nunca intentar reproducir el hash base-36 del vendor.
8. **Nunca limpiar por "el escritor está muerto"**: es el estado normal tras cualquier
   restart y dispararía en cada arranque (`research.md:100-106`, SC-009).
9. **Nunca limpiar incondicionalmente en cada arranque** (rechazado explícitamente en
   Clarifications, `spec.md:251-258`; registrado también como alternativa descartada
   en `research.md:241-242`).
10. **Un pointer ausente nunca se reporta como roto** — es un agente sin login todavía
    (`spec.md:156-157`).

**Sobre el marcador (E2)**

11. **Nunca decidir con un marcador no consumido** de un arranque anterior: se borra al
    leerlo, gane el verdicto que gane.
12. **La ausencia del marcador nunca es un problema reportable.** En régimen normal el
    doctor lo encuentra ausente, porque el arranque lo consumió.
13. **Nunca contiene valores de secretos** (FR-013): solo códigos de salida. Los
    identificadores de sesión y entorno sí pueden mostrarse al operador dueño.
14. **Nunca se crea un archivo llamado `.env` bajo `.state/`**:
    `docker/scripts/lib/backup_identity.sh:71-73` lo metería en el hash y `:152-157`
    lo cifraría a `.env.age` y lo empujaría al fork.
15. **Ningún fallo de escritura o lectura del marcador puede impedir el arranque.**
    El directive lleva prefijo `-` y el script lleva su propio `exit 0` incondicional —
    doble cinturón, el patrón exacto de 021
    (`modules/systemd-remote-control.service.tpl:24-25`,
    `modules/local-secret-check.sh.tpl:2-7`).
16. **El predicado nunca usa el tiempo.** `written_at` es diagnóstico; la decisión es
    causal, no temporal (por eso se rechazó back-datar el mtime, `research.md:255-256`).

**Sobre el nombre de sesión (E3)**

17. **Nunca se edita a mano en la unit renderizada**: el valor vive en `agent.yml` y
    debe sobrevivir a `--regenerate` (FR-008/FR-012, Principio I).
18. **Nunca una rama de compatibilidad** por antigüedad del workspace: existentes y
    nuevos resuelven con la misma regla (FR-015).
19. **Nunca dejar atrás la segunda composición** de la identidad en
    `modules/local-killswitch.sh.tpl:37`, o imprimirá una identidad falsa.

**Sobre el diagnóstico (E4)**

20. **Nunca `_doctor_skip` para "no se puede determinar"** — sale verde con exit 0 y es
    el modo de falla exacto que la spec ataca (`research.md:509-518`, `spec.md:76`).
21. **Nunca dejar corriendo el grep del journal** de `scripts/agentctl:1280-1285` junto
    a un check bueno: es una falsa alarma medida y viola FR-006.
22. **Nunca inspeccionar la unit renderizada en vez de la instalada.** `--regenerate` no
    reinicia nada y solo reinstala si `install_service` es true **y** `sudo -n`
    funciona; usar `systemctl show` (no `systemctl cat`, que falla "Permission denied"
    para el operador y salta el check en silencio) — `research.md:404-408`,
    `scripts/agentctl:1171-1186`.
23. **Nunca remediar automáticamente de forma recurrente** contra una sesión sana sin
    demostrar antes su comportamiento ante falsos positivos (FR-007, y la regla
    constitucional de no reintroducir diseños revertidos —
    `.specify/memory/constitution.md:190-192`).

**Sobre docker**

24. **Ninguna de estas cuatro entidades existe en modo docker** (FR-011). Ni el lib
    nuevo se espeja a `docker/scripts/lib/`, ni el render de docker cambia un byte.

---

## Afirmaciones NO verificadas

Registradas aquí en vez de presentadas como hechos.

1. **La causa de salida en un `systemctl restart` / reboot es `killed`** (filas #2 y #3
   de la tabla). Es el supuesto del que depende TODA la continuidad de FR-014/SC-009, y
   **no está medido en `research.md`** — la medición en vivo de `research.md:184-197`
   midió la reutilización del pointer bajo `same-dir`, no el valor de `$EXIT_CODE`. Si
   `claude remote-control` atrapa SIGTERM y sale con 0, systemd reportaría
   `exit_code=exited` / `service_result=success`, **indistinguible de una sesión
   terminada**, y el predicado colapsaría a "limpiar siempre" (falla SC-009). Es un
   gate de hardware obligatorio antes de confiar en la rama KEEP: reiniciar la unit en
   mclaren y leer el marcador escrito.
2. **La semántica de `$EXIT_CODE` ∈ {`exited`, `killed`, `dumped`}** viene de la
   documentación de `systemd.service(5)`. `research.md:169-170` confirma que las tres
   variables se entregan a `ExecStopPost=`, pero no enumera sus valores, y este entorno
   es macOS: no pude consultar el man page ni ejecutar systemd para verificarlo.
3. **`bridge-pointer.json.retired` como nombre concreto** del pointer retirado es una
   propuesta mía, no una decisión registrada en `spec.md` ni `research.md`. Lo que sí
   está decidido es la *forma*: nombre fijo, sobrescribible, distinto de
   `bridge-pointer.json`. El nombre final corresponde al contrato del plan.
4. **`pointer.pid` vs `MainPID` como predicado del doctor**: derivado por mí desde
   `research.md:89` y `:194`. Su tasa de falsos positivos no está medida, y FR-006/FR-007
   exigen medirla antes de adoptarlo. Está listado como candidato, no como hecho.
5. **`.claude/projects/**` queda fuera del backup de identidad**: verificado contra el
   whitelist de 4 rutas en `docker/scripts/lib/backup_identity.sh:30-38`. No verifiqué
   que el `state_dir` que recibe esa función en modo local sea exactamente `<ws>/.state`
   (no leí su call site local); si no lo fuera, la conclusión no cambia, porque el
   whitelist es de rutas explícitas.
6. **El orden de nombres de los scripts** (`agent-session-exit.sh`,
   `agent-session-check.sh`, `scripts/lib/session_pointer.sh`) viene del brief de
   diseño de esta tarea; esos archivos **no existen todavía** en el repo (los
   templates presentes bajo `modules/` son los 19 `local-*.tpl` listados por `ls`).
</content>
</invoke>
