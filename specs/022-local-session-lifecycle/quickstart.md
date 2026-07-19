# Quickstart: ciclo de vida de la sesión Remote Control en modo local (022)

Guía de validación para el operador. Cubre los dos gates de la feature (host sin
systemd, y hardware real en mclaren), cómo reproducir el bug antes del fix y
comprobar que dejó de ocurrir, cómo verificar que las invariantes de 021 siguen
vivas, y el rollback.

**Regla de lectura**: todo lo que aquí se afirma sobre el código está citado como
`archivo:línea`. Lo que todavía **no** existe en el repo (los artefactos que esta
feature va a crear) está marcado como *diseño*, no como hecho. Ver la sección final
"Lo que esta guía NO puede verificar todavía".

---

## 0. Qué entrega la feature (nomenclatura usada en esta guía)

| Artefacto | Ruta | Estado |
|---|---|---|
| Hook de salida | `<ws>/scripts/local/agent-session-exit.sh` (`ExecStopPost=-`) | diseño fijado (`plan.md` §Project Structure) |
| Hook de arranque | `<ws>/scripts/local/agent-session-check.sh` (2º `ExecStartPre=-`) | diseño fijado |
| Lib compartida | `scripts/lib/session_pointer.sh` (hook + doctor, fuente única) | diseño fijado |
| Marcador de causa de salida | `<ws>/scripts/heartbeat/session-exit.json` | diseño fijado (`data-model.md` E2) |
| Check del doctor | `_local_session_doctor` (D5/D6/D7) en `scripts/agentctl`, cableado en `cmd_local_doctor` | diseño fijado (`contracts/session-pointer-hygiene.md` §4) |
| Campo nuevo | `deployment.session_name` en `agent.yml` → `DEPLOYMENT_SESSION_NAME` | diseño fijado (`contracts/session-name-resolution.md`) |

"Diseño fijado" = decidido en los artefactos de Fase 1, **todavía no escrito en el
árbol**. Nada de esta tabla existe aún como código.

Los dos hooks siguen el patrón de plantilla de 021: `modules/local-<x>.sh.tpl` →
`scripts/local/agent-<x>.sh`, renderizado en el bloque local de `--regenerate`
(patrón verificado en `setup.sh:2234-2238`, donde
`modules/local-secret-check.sh.tpl` → `scripts/local/agent-secret-check.sh`). Los
nombres exactos de las plantillas nuevas —`modules/local-session-exit.sh.tpl` y
`modules/local-session-check.sh.tpl`— están fijados en `plan.md` (§Source Code), no
inferidos.

El pointer que gobierna todo esto **no es nuestro**: lo escribe Claude Code en

```
<ws>/.state/.claude/projects/<slug>/bridge-pointer.json
```

con `CLAUDE_CONFIG_DIR=<ws>/.state/.claude` (`modules/remote-control.env.tpl:6`) y
`slug` = la ruta absoluta del workspace con `[^a-zA-Z0-9]` → `-` (research.md R4,
extraído del binario 2.1.185).

---

## 1. Gate de host (macOS, sin systemd)

Lo que el host puede probar es el **render** y la **lógica pura** de la lib y del
doctor. El comportamiento de systemd no se prueba aquí: eso es el gate de hardware.

```bash
cd /Users/rodrigo-hinojosa/Documents/Cencosud/Claude/Agents/agentic-pod-launcher

# Suite completa. Baseline medido en main=7e50c44 (research.md R9, cross-check
# propio: `grep -h "^@test" tests/*.bats | wc -l` = 1052):
#   1052 ok, 0 not ok, 20 skips
bats tests/

# Los archivos que esta feature toca o crea
bats tests/local-render.bats
bats tests/local-install-service.bats
bats tests/agentctl-local.bats

# Principle III: shellcheck limpio
shellcheck -S error scripts/lib/session_pointer.sh scripts/agentctl setup.sh \
                    modules/local-session-check.sh.tpl modules/local-session-exit.sh.tpl
```

**Qué esperar al terminar la feature**: `0 not ok` y **ningún test perdido**. El
total sube respecto de 1052 en la cantidad de tests nuevos; lo que se verifica no es
el número final sino que (a) no haya fallas, (b) el conteo no **baje**, y (c) los
20 skips sigan siendo los mismos (son esperados).

### La trampa de bats que ya mordió dos veces en este repo

Una aserción negada a mitad de cuerpo **no falla el test**. Está documentado en
`tests/agentctl-local.bats` y hay aserciones muertas vivas en el árbol
(research.md R9 las ubica en `:120, 148, 206, 274`). Los negativos de esta feature
—"el hook NO borró el pointer cuando lo mataron", "el doctor NO warneó con un agente
sano"— son exactamente esa forma. Escríbelos como:

```bash
run grep -q 'algo' "$file"; [ "$status" -ne 0 ]      # forma preferida
if grep -q 'algo' "$file"; then false; fi            # o esta, y va ÚLTIMA
```

Un `bats` verde con aserciones muertas no prueba nada. La contramedida barata es el
**mutation spot-check**: rompe a mano cada pieza nueva (invierte el predicado
exited/killed, borra el consumo del marcador, neutraliza el glob de fallback) y
confirma que al menos un test se pone rojo por cada una.

### Nota de render sobre `DEPLOYMENT_SESSION_NAME` (US3)

`tests/local-render.bats:65` (dentro del test `:63-66`) asevera la línea `ExecStart`
**completa y anclada**:

```
ExecStart=/usr/local/bin/claude remote-control --name rpi5-locbot --spawn=session --verbose
```

El fixture es `host: "rpi5"` + `agent.name: locbot` (`tests/local-render.bats:16,27`),
y `locbot` **no** empieza con `rpi5`, así que la regla por defecto resolvería
`rpi5-locbot`: el mismo string de hoy. Aun así el contrato **no** deja el test como
está: `contracts/session-pointer-hygiene.md` §8 lo declara "roto a propósito" y manda
darle al fixture un `session_name` **distinto** del default (`locbot-remote`), para
que el test pruebe lo que US3 promete —el valor configurado llega verbatim— en vez de
revalidar por coincidencia la composición vieja.

En cualquier caso, el default se calcula en `setup.sh` y se persiste a `agent.yml`,
**no** en la plantilla — así que un render directo del `.tpl` en bats (que es lo que
hace ese archivo, sin pasar por `setup.sh`) necesita que `DEPLOYMENT_SESSION_NAME`
exista en el fixture o esté exportado en `setup()`, igual que ya se exportan
`OPERATOR_USER`/`HOST_NAME`/`CLAUDE_BIN` (`tests/local-render.bats:48-53`).

**Dónde se prueba el default — y dónde NO.** El default NO lo prueba el `diff` de
`tests/local-install-service.bats:113-126`: ese test renderiza `expected.unit` con el
mismo `render_to_file` y el mismo contexto que luego produce la unit instalada, así
que compara un render contra sí mismo — prueba la fidelidad del camino de
instalación, no el valor del nombre. Peor: es una **trampa activa**
(`contracts/session-pointer-hygiene.md` §7). Su `render_to_file` corre **antes** de
`./setup.sh --regenerate`; si `setup.sh` persiste `deployment.session_name` durante
ese regenerate, el lado "expected" se renderizó con la variable vacía y el instalado
con el valor resuelto → el `diff` falla. La resolución recomendada es declarar
`session_name` en el fixture del archivo (`:19-51`), con lo cual el persist queda
no-op.

El default se prueba en su propio nivel: un test unitario de la función resolvedora
(escenarios N2-N5 de `contracts/session-name-resolution.md`, patrón
`tests/claude-cli-resolution.bats:18`), y el backfill end-to-end de un `agent.yml`
pre-022 en el escenario N8, sobre el seam `SETUP_SYSTEMD_DIR`.

---

## 2. Gate de hardware (mclaren) — el único que prueba la feature

### 2.0 Variables de la sesión de gate

```bash
AGENT=mclaren-admin
UNIT=agent-${AGENT}.service
WS=/home/rodrigo-hinojosa/Documents/Personal/Claude/Agents/mclaren-admin
SLUG=$(printf '%s' "$WS" | sed 's/[^a-zA-Z0-9]/-/g')
PTR="$WS/.state/.claude/projects/$SLUG/bridge-pointer.json"
MARK="$WS/scripts/heartbeat/session-exit.json"

ls -l "$PTR"          # debe existir; si no, verifica el slug con:
ls -1 "$WS/.state/.claude/projects/"
```

El slug medido en mclaren es
`-home-rodrigo-hinojosa-Documents-Personal-Claude-Agents-mclaren-admin`
(69 caracteres, un solo directorio de proyecto presente — research.md R4).

### 2.1 Precondición: la unit viva puede estar contaminada por el experimento de R2

La medición de research.md R2 (2026-07-18 21:15 UTC) cambió la unit corriendo a
`--spawn=same-dir` con `--debug-file`. **Antes de medir nada, confirma qué está
instalado de verdad**:

```bash
systemctl show "$UNIT" -p ExecStart --value
```

Si aparece `--spawn=same-dir` o `--debug-file`, la unit está en estado de
experimento y hay que devolverla al estado de `main` antes de empezar. Un gate
corrido sobre esa unit no mide esta feature.

### 2.2 Desplegar — `--regenerate` NO basta

Hallazgo de research.md R6, confirmado en vivo: `--regenerate` reinstala la unit
**solo si** `deployment.install_service: true` **y** `sudo -n true` funciona
(`setup.sh:2264-2266`, `setup.sh:2384`); si no, deja el archivo staged y **sale 0**.
Y **nada en `setup.sh` reinicia jamás la unit de sesión** — no hay un solo
`systemctl restart` en ese archivo. En mclaren esto ya ocurrió: la plantilla se
editó y la unit instalada seguía corriendo `--name mclaren-mclaren-admin`.

Por eso el gate instala y reinicia **explícitamente**:

```bash
cd "$WS"

# 0) respaldo de la unit instalada, con nombre único y verificado ANTES de tocar nada
sudo cp /etc/systemd/system/${UNIT} /root/${UNIT}.pre022.$(date +%Y%m%d-%H%M%S)
# El glob lo expande TU shell, que no puede leer /root → 'sudo ls /root/*.pre022.*'
# no encuentra nada aunque el respaldo exista. Lista el directorio y filtra:
sudo ls -l /root/ | grep -F "${UNIT}.pre022"   # confirma que el respaldo existe y pesa

./setup.sh --regenerate

# 1) SOLO si regenerate imprimió "staged in workspace (sudo unavailable)":
sudo cp ./agent-${AGENT}.service /etc/systemd/system/${UNIT}

# 2) obligatorio, siempre:
sudo systemctl daemon-reload
sudo systemctl restart "$UNIT"

# 3) verificar la unit INSTALADA (no el archivo del repo)
systemctl show "$UNIT" -p ExecStart -p ExecStartPre -p ExecStopPost -p EnvironmentFiles
```

En `-p ExecStartPre` deben aparecer **dos** entradas, en orden: primero
`agent-secret-check.sh` (021), después `agent-session-check.sh` (022), ambas con
`ignore_errors=yes`. En `-p ExecStopPost`, `agent-session-exit.sh` con
`ignore_errors=yes`.

---

## 3. Reproducir el bug y comprobar que dejó de ocurrir (SC-001, SC-002, SC-009)

### 3.1 Corrección importante sobre "reiniciar dos veces"

`spec.md:224` (SC-001) describe la reproducción como "reiniciar el servicio dos veces
seguidas". La investigación posterior la **matiza**: research.md R1b establece que el
evento que envenena el pointer es que la **sesión termine** (con `--spawn=session` el
proceso sale solo cuando la sesión se completa; el nuevo proceso pide reusar una
sesión ya cerrada). Y research.md R2 **midió** un `systemctl restart` limpio: el
entorno se re-otorga, el `sessionId` no cambia y el agente quedó **alcanzable con el
mismo link**.

Consecuencia práctica: **un restart sin que haya terminado ninguna sesión no
reproduce el bug** — y no debería, eso es justamente SC-009. La reproducción fiel es
terminar la conversación desde el cliente. Los dos restarts del enunciado original
funcionan solo si entre medio hubo una sesión que se completó.

### 3.2 Reproducción ANTES del fix (opcional; deja el agente inalcanzable)

Hazlo únicamente si quieres la evidencia del estado roto. Es recuperable (paso 3.4).

```bash
# 1) foto del pointer sano
jq '{sessionId, environmentId, pid, procStart}' "$PTR"

# 2) desde el cliente (teléfono o claude.ai/code): TERMINA la conversación,
#    para que la sesión se complete y el proceso salga por su cuenta.

# 3) systemd lo revive (Restart=always, RestartSec=10). Espera ~20 s y vuelve a mirar:
jq '{sessionId, environmentId, pid, procStart}' "$PTR"
#    sessionId IGUAL al de la foto + pid/procStart NUEVOS = el pointer quedó
#    envenenado: el proceso vivo está re-anunciando una sesión ya cerrada.

# 4) desde el cliente: intenta hablarle. Está inalcanzable.
#    Y sin embargo, TODO lo demás dice "sano":
systemctl is-active "$UNIT"                    # active
systemctl show "$UNIT" -p NRestarts --value    # bajo
journalctl -u "$UNIT" --since "-10 min" --no-pager | tail -20   # sin errores
```

Este es el modo de falla que la spec ataca: verde en todas partes, agente muerto.

### 3.3 Comprobación DESPUÉS del fix

Tres escenarios; los tres se miden en la misma sesión de gate.

> **Antes de escribir un solo comando, entiende el reloj.** El marcador es de
> **consumo único**: lo escribe el `ExecStopPost` al detenerse el proceso y lo borra
> el `ExecStartPre` del arranque siguiente (`data-model.md` E2, "Semántica de consumo
> único"). Con `Restart=always` + `RestartSec=10` ese arranque ocurre ~10 s después,
> así que **a los 20 s el marcador ya NO existe — y eso es lo sano**. Igual de
> importante: tras limpiar el pointer, `claude remote-control` crea una sesión nueva
> y **escribe un `bridge-pointer.json` nuevo**. La evidencia de que el hook actuó no
> es "el pointer desapareció": es el `sessionId` distinto, el sibling retirado y la
> línea del journal.

**A. Sesión que termina sola → el pointer se limpia (SC-001 / SC-002, FR-002)**

```bash
# 1) foto ANTES de terminar la conversación
jq -r '.sessionId' "$PTR" > /tmp/sid.A.before

# 2) desde el cliente: termina la conversación. Espera ~25 s (salida + RestartSec=10
#    + arranque). El hook ya corrió y ya consumió el marcador.

# 3) la línea del hook en el journal — este es el oráculo principal (rama C2)
journalctl -u "$UNIT" -n 60 --no-pager | grep -i 'session-check\|session-exit'
#   -> 'session-exit: exited/...' y
#      'session-check: previous session ended (exit_code=exited) — retired stale pointer …'

# 4) el pointer retirado quedó como sibling, y hay un pointer NUEVO al lado
ls -l "$WS/.state/.claude/projects/$SLUG/"
#   -> bridge-pointer.retired.json  PRESENTE (la evidencia forense)
#   -> bridge-pointer.json          PRESENTE otra vez (sesión nueva)

# 5) y su sessionId es OTRO
jq -r '.sessionId' "$PTR" > /tmp/sid.A.after
diff /tmp/sid.A.before /tmp/sid.A.after || echo "sessionId renovado — correcto"

# 6) el marcador está consumido (ausente). Su ausencia es el estado sano.
ls -l "$MARK" 2>/dev/null || echo "marcador consumido — correcto"
```

Si quieres ver el marcador **con tus ojos** antes de que lo consuman, hay que impedir
el rearranque: en cuanto el cliente cierre la conversación, `sudo systemctl stop
"$UNIT"` (dentro de la ventana de `RestartSec`), y entonces
`jq . "$MARK"` muestra `{"schema":1,…,"exit_code":"exited",…}` — el esquema está en
`data-model.md` E2. Después `sudo systemctl start "$UNIT"`. Es una carrera; el
oráculo estable son los pasos 3-5.

Confirmación que **solo el operador puede dar**: desde el teléfono, el agente
responde. El link es nuevo — eso es inherente a `--spawn=session` cuando una
conversación genuinamente termina, no un defecto de esta feature (research.md R2,
"Revised recommendation").

**B. Restart con sesión viva → continuidad intacta (SC-009, FR-014)**

Se mide en dos tiempos, justamente para poder ver el marcador antes de que el
arranque lo consuma:

```bash
jq -r '.sessionId' "$PTR" > /tmp/sid.before

sudo systemctl stop "$UNIT"          # el ExecStopPost escribe el marcador
jq -r '.exit_code' "$MARK"           # -> killed   (campo JSON, NO 'EXIT_CODE=')
ls -l "$PTR"                         # el pointer sigue ahí: rama C3 = KEEP

sudo systemctl start "$UNIT"; sleep 20
journalctl -u "$UNIT" -n 40 --no-pager | grep -i 'session-check'
#   -> 'previous run was terminated (exit_code=killed) — keeping pointer for session reuse'
ls -l "$MARK" 2>/dev/null || echo "marcador consumido — correcto"

jq -r '.sessionId' "$PTR" > /tmp/sid.after
diff /tmp/sid.before /tmp/sid.after && echo "continuidad OK"
```

Con `systemctl restart` en un solo paso el resultado final es el mismo, pero el
marcador nace y muere dentro del comando: solo quedan observables el journal y el
`sessionId`.

`sessionId` y `environmentId` **iguales**, solo `pid`/`procStart` cambian — es
exactamente lo que midió research.md R2. Y desde el cliente: **mismo link, sigue
funcionando**. Si aquí el `sessionId` cambia, el fix degeneró en "renovar siempre" y
el gate falla.

**C. Reboot del host (SC-002)**

```bash
# NO uses /tmp para esta foto: en Debian reciente es tmpfs y el reboot la borra.
jq -r '.sessionId' "$PTR" > ~/sid.C.before
sudo reboot
# tras el arranque (el marcador YA fue consumido por el ExecStartPre — no lo busques):
systemctl is-active "$UNIT"
journalctl -b -u "$UNIT" --no-pager | grep -i 'session-check'   # QUÉ rama corrió
jq -r '.sessionId' "$PTR" 2>/dev/null || echo "sin pointer"
diff <(cat ~/sid.C.before) <(jq -r '.sessionId' "$PTR") \
  && echo "mismo sessionId (rama keep)" || echo "sessionId nuevo (rama retire)"
```

Dos desenlaces, ambos aceptables — y el discriminador es la **línea del journal**, no
la presencia del marcador (que en ambos casos está consumido):

- el `ExecStopPost` alcanzó a correr en el apagado ordenado → marcador `killed` →
  línea `keeping pointer for session reuse` → `sessionId` **igual** al de antes → el
  operador reconecta con el mismo link;
- no alcanzó a correr (corte de energía) → sin marcador → línea
  `WARN: cannot determine why the previous run stopped — retiring pointer` → **se
  limpia** el pointer (FR-014: disponibilidad sobre continuidad) → `sessionId` nuevo,
  agente alcanzable.

Lo que **no** es aceptable: agente inalcanzable. Eso lo confirma el operador desde el
cliente, no el host.

### 3.4 Recuperación manual (la que 022 automatiza)

Si en cualquier momento el agente queda inalcanzable:

```bash
sudo systemctl stop "$UNIT"
mv "$PTR" "$PTR".manual-$(date +%s)
sudo systemctl start "$UNIT"
```

Es lo mismo que hace el vendor internamente (`clearBridgePointer` es un `unlink`
plano — research.md R1). Renombrar en vez de borrar deja evidencia forense. El hook
hace exactamente esta operación, pero a un nombre **fijo y sobrescribible**,
`bridge-pointer.retired.json` (`contracts/session-pointer-hygiene.md` §1.3), para
acotarse a un solo archivo; el sufijo con timestamp de arriba es para la recuperación
a mano, donde no hay quien rote nada.

---

## 4. El doctor (SC-003, SC-004)

La tabla de veredictos es D7 en `contracts/session-pointer-hygiene.md` §4. Dos hechos
de esa tabla gobiernan lo que se puede probar aquí: el estado sano es **pointer
presente + marcador ausente** (→ `_doctor_pass`), y el estado que WARNea es
**marcador presente mientras la unit está activa** — porque si el arranque actual
hubiera ejecutado el hook, el marcador estaría consumido.

```bash
cd "$WS"

# SC-004 — agente sano: CERO warnings/fails de sesión, 5 corridas seguidas.
# Filtra por el glifo, no por la palabra: en verde el doctor SÍ imprime líneas con
# "session" (los ✓ de D5/D6/D7), y grepear 'session' a secas las confunde con alarmas.
for i in 1 2 3 4 5; do ./scripts/agentctl doctor | grep -E '⚠|✗' | grep -i 'session'; done
# salida esperada: vacía las 5 veces
```

**SC-003 — el estado que debe WARNear.** No se reproduce con 3.2: con el fix
instalado ese estado ya no se alcanza solo (el hook lo repara en el arranque). Se
**simula** su firma exacta —un marcador que nadie consumió con la unit activa—
escribiendo el marcador a mano, sin tocar el pointer:

```bash
systemctl is-active "$UNIT"        # debe decir 'active' para que D7 aplique
cat > "$MARK" << 'JSON'
{"schema":1,"written_at":"2026-07-18T00:00:00Z","service_result":"success","exit_code":"exited","exit_status":"0"}
JSON
./scripts/agentctl doctor; echo "exit=$?"
#   -> ⚠ agent is likely unreachable: an ended session was never cleaned up
#      → sudo systemctl restart agent-<n>.service
#   -> exit=1  (si hay otros fails previos será 2; lo que se verifica es el WARN)
rm -f "$MARK"                      # OBLIGATORIO: si el simulacro sobrevive al próximo
                                   # arranque, el hook lo consume, retira un pointer sano
                                   # y le cambia el link al operador sin motivo.
```

Contrato de salida (`scripts/agentctl:1304-1314`): `0` limpio, `1` solo warnings,
`2` cualquier fallo. `_doctor_skip` **no incrementa contador** y saldría 0: por eso
"no se puede determinar" tiene que ser `_doctor_warn` con texto explícito
(research.md R9, `data-model.md` E4).

**La rama "no se puede determinar" NO se gatilla en hardware, a propósito.** Un
`chmod 000 "$PTR"` no la produce: `session_pointer_path` resuelve por *existencia*
del archivo (`contracts/session-pointer-hygiene.md` §1.2), así que el pointer sigue
siendo `present` y el doctor pasa en verde, correctamente. Los estados `unknown`
—dos o más candidatos bajo `projects/`, o un `CLAUDE_CONFIG_DIR` ilegible— exigen
romper el directorio de configuración del agente vivo (ahí están las credenciales).
Esa rama se prueba en el **host**, en el test unitario de la lib, que es justamente
donde el Principio III la quiere.

**Regresión que esta feature debe eliminar, no dejar en paralelo**: el bloque
"connection signal" de `cmd_local_doctor` (`scripts/agentctl:1280-1285`) grepea el
journal por `session url|connected|polling`. El healthcheck ya declaró ese predicado
falso positivo medido en mclaren y lo reemplazó por la sonda de socket
(`modules/local-healthcheck.sh.tpl:50-64`: *"A healthy `--spawn=session` is SILENT in
the journal … false-WARNed on every tick even when connected (validated on
mclaren)"*). Dejarlo vivo viola FR-006. Comprobación:

```bash
# Oráculo exacto: esta cadena es única del bloque del doctor (:1284).
grep -n 'No recent connection signal' scripts/agentctl      # esperado tras 022: sin resultados

# El patrón crudo aparece DOS veces hoy: :1281 (doctor, se borra) y :1242
# (cmd_local_status, que solo imprime y no emite veredicto). El contrato
# (§4.1) recomienda alinear el segundo pero NO lo exige, así que un hit
# restante en cmd_local_status es aceptable; dos hits no lo son.
grep -n 'session url|connected|polling' scripts/agentctl    # esperado tras 022: 0 o 1 hit, nunca en cmd_local_doctor
```

---

## 5. Estado corrupto no puede impedir el arranque (SC-005, FR-003)

**Corromper y después `restart` NO prueba nada.** Un `systemctl restart` ejecuta
primero el `ExecStopPost`, que **reescribe el marcador** — tu basura desaparece antes
de que el hook de arranque la vea. Hay que corromper *entre* el stop y el start:

```bash
# marcador basura
sudo systemctl stop "$UNIT"
printf 'no soy json' > "$MARK"          # el workspace es tuyo: sin sudo
sudo systemctl start "$UNIT"; systemctl is-active "$UNIT"        # espera: active
journalctl -u "$UNIT" -n 20 --no-pager | grep -i 'session-check' # espera: WARN rama C5

# marcador vacío
sudo systemctl stop "$UNIT"; : > "$MARK"
sudo systemctl start "$UNIT"; systemctl is-active "$UNIT"

# pointer truncado (NO lo restaures: ver más abajo)
sudo systemctl stop "$UNIT"
cp "$PTR" /tmp/ptr.forensics && printf '{' > "$PTR"
sudo systemctl start "$UNIT"; systemctl is-active "$UNIT"
```

En los tres casos: unit `active`, y a lo más una línea WARN en el journal. La doble
protección es el prefijo `-` del `ExecStartPre`/`ExecStopPost` **más** el `exit 0`
incondicional del propio script (patrón de `modules/local-secret-check.sh.tpl:1-9,66`).

**Costo esperado de este bloque**: los dos primeros casos dejan al hook en la rama C5
("no se puede determinar" → retirar), así que el agente sale con un **link nuevo**.
Es el comportamiento correcto (FR-014), no una falla del test — pero córrelo cuando
puedas absorber el cambio de link, y **después** de las mediciones de continuidad
de §3.3 B.

**No restaures el pointer desde el respaldo con el agente corriendo.** `/tmp/ptr.bak`
es evidencia forense, no un punto de retorno: sobrescribir `bridge-pointer.json`
mientras el proceso vive lo pone en riesgo del guard de split-brain (§9, trampa 8) y
además le miente al vendor sobre qué sesión anunciar. El proceso vivo reescribe su
propio pointer; déjalo. Por eso arriba el respaldo se llama `ptr.forensics`.

**El caso "sin `jq`" no se prueba en hardware.** Para quitar `jq` del PATH de la unit
habría que editar `.state/remote-control.env`, que es un archivo derivado (lo pisa el
próximo `--regenerate`, Principio I) y que además define el PATH del que dependen
todos los MCPs. Esa degradación se prueba en el host, donde el test invoca el hook
con un PATH controlado; el contrato ya exige que el parseo funcione **sin** `jq`
(`contracts/session-pointer-hygiene.md` §1.6: extracción por `sed`/`grep`, `jq` solo
como camino preferente).

---

## 6. Nombre de sesión (SC-006, US3)

```bash
systemctl show "$UNIT" -p ExecStart --value | grep -o -- '--name [^ ]*'
yq -r '.deployment.session_name' "$WS/agent.yml"    # 'null' si el backfill no corrió
```

(`grep -A2 '^deployment:'` no sirve: el bloque `deployment` tiene seis claves y
`session_name` no cae en las dos primeras líneas.)

Regla por defecto (FR-009/FR-015, una sola regla, sin rama de compatibilidad), tal
como la precisa `contracts/session-name-resolution.md` §1:

- el **host** sale de `.deployment.host` en `agent.yml`, **no** de `$(hostname)` en
  vivo (Principio I: el nombre tiene que reproducirse re-renderizando);
- se toma su **primera etiqueta** antes del punto y se normaliza (`mclaren.local` →
  `mclaren`);
- si el `agent_name` es igual a ese segmento, o empieza con `<segmento>-`, se usa el
  `agent_name` solo; si no, `<host>-<agent>`. La frontera con guion es deliberada:
  sin ella, host `rpi5` + agente `rpi5x` colapsaría a `rpi5x`.

En mclaren: `mclaren-admin` (no `mclaren-mclaren-admin`).

Con un valor explícito en `agent.yml`:

```bash
yq -i '.deployment.session_name = "mclaren"' "$WS/agent.yml"
./setup.sh --regenerate
# el mismo despliegue de §2.2: el 'cp' SOLO si regenerate dijo "staged in workspace";
# si tenías sudo -n, el regenerate ya instaló la unit y ese archivo no existe.
sudo systemctl daemon-reload && sudo systemctl restart "$UNIT"
systemctl show "$UNIT" -p ExecStart --value | grep -o -- '--name [^ ]*'   # --name mclaren
```

**Cambio de identidad de una sola vez, aceptado y documentado** (FR-015): al primer
re-render el agente aparece en el cliente con nombre nuevo. En mclaren el operador ya
absorbió ese cambio a mano.

Consistencia a revisar en el mismo PR: `modules/local-killswitch.sh.tpl:37` compone
la misma identidad por su cuenta (`$(hostname)-${AGENT_NAME}`) y **imprimiría un
nombre falso** si queda atrás (research.md R7). El arreglo está especificado en
`contracts/session-name-resolution.md` §5: interpolar `SESSION_NAME="{{DEPLOYMENT_SESSION_NAME}}"`
junto al `AGENT_NAME="{{AGENT_NAME}}"` de `:10` y consumirlo en `:37`. El nombre de la
unit (`agent-<agent_name>.service`) **no** cambia: sale de `AGENT_NAME`.

---

## 7. Las invariantes de 021 siguen vivas (SC-008)

022 toca el mismo archivo que 021. Estas verificaciones se corren **después** de
reinstalar la unit:

```bash
# 1) .env PRIMERO y con el flag de ignorar; remote-control.env DESPUÉS
systemctl show "$UNIT" -p EnvironmentFiles --value
#    esperado, en este orden:
#      <ws>/.env (ignore_errors=yes)
#      <ws>/.state/remote-control.env (ignore_errors=no)

# 2) el secreto llegó al proceso — SOLO CONTEO, jamás imprimir el valor.
#    La unit corre como el operador (User=), así que NO hace falta sudo. Y si lo
#    usaras, 'sudo tr < /proc/…' no serviría: la redirección la abre TU shell antes
#    de que sudo eleve nada. Si algún día hiciera falta, es 'sudo cat … | tr'.
tr '\0' '\n' < /proc/$(systemctl show -p MainPID --value "$UNIT")/environ \
  | grep -c '^GITHUB_PAT='            # esperado: 1

# 3) systemd no filtra valores
systemctl show "$UNIT" -p Environment    # sin secretos

# 4) el primer ExecStartPre sigue siendo el de 021, y sigue con '-'
systemctl show "$UNIT" -p ExecStartPre

# 5) las units auxiliares siguen SIN EnvironmentFile (menor privilegio).
#    OJO con el falso verde: 'systemctl show' de una unit inexistente también
#    imprime vacío y sale 0. Por eso se imprime primero LoadState.
for u in healthcheck qmd-reindex qmd-watch vault-backup wiki-graph; do
  printf '%s: load=%s ef=[%s]\n' "$u" \
    "$(systemctl show "agent-${AGENT}-${u}.service" -p LoadState --value 2>/dev/null)" \
    "$(systemctl show "agent-${AGENT}-${u}.service" -p EnvironmentFiles --value 2>/dev/null)"
done          # esperado: las cargadas (load=loaded) con ef=[] ; el resto, not-found

# 6) el doctor completo
./scripts/agentctl doctor; echo "exit=$?"
```

En el host, las mismas invariantes están fijadas por tests que **no deben tocarse**:
orden numérico de líneas en `tests/local-render.bats:106-118` y
`tests/local-install-service.bats:130-140`; prefijo `-` del `.env` en
`tests/local-render.bats:101-104`; `ExecStartPre` con `-` en
`tests/local-render.bats:120-123`; ausencia de `Environment=` en
`tests/local-render.bats:125-128`; los cinco negativos de "ninguna otra unit tiene
EnvironmentFile" en `tests/local-render.bats:130-153`.

Docker (FR-011): debe quedar **byte-idéntico**. Lo fijan `bats tests/docker-render.bats`
(39 tests) y `tests/modules-render.bats` —donde 021 dejó su propia aserción de
invarianza docker (`:157`)—, y ningún archivo bajo `docker/` se toca. La rama docker de
`--regenerate` (`setup.sh:2195-2205`) no cambia; 022 vive entera en la rama local
(`setup.sh:2223-2262`).

---

## 8. Rollback

Del más barato al más caro.

**8.1 Neutralizar la feature sin desinstalar nada** (deja el agente en el
comportamiento pre-022):

```bash
sudo systemctl edit "$UNIT"        # drop-in
# [Service]
# ExecStartPre=
# ExecStartPre=-<ws>/scripts/local/agent-secret-check.sh
# ExecStopPost=
sudo systemctl daemon-reload && sudo systemctl restart "$UNIT"
```

Una línea vacía `ExecStartPre=` limpia la lista acumulada; la que sigue la repuebla
solo con el hook de 021. Reversible borrando el drop-in **explícitamente**:

```bash
sudo rm -f /etc/systemd/system/${UNIT}.d/override.conf
sudo systemctl daemon-reload && sudo systemctl restart "$UNIT"
```

**No uses `systemctl revert` aquí.** Está definido como "volver a la versión del
proveedor", y esta unit no tiene versión de proveedor: existe únicamente en
`/etc/systemd/system` porque la instaló `install_service`. Borrar el drop-in a mano
es inequívoco y no depende de cómo interprete ese caso la versión de systemd del host.

Esto neutraliza los dos hooks, no la feature completa: el `--name` de US3 lo decide el
`ExecStart`, que este drop-in no toca. Para volver también al nombre viejo, usa 8.2.

**8.2 Restaurar la unit anterior desde el respaldo del paso 2.2:**

```bash
sudo ls -l /root/ | grep -F "${UNIT}.pre022"     # el glob no lo expandiría tu shell
sudo cp /root/${UNIT}.pre022.<timestamp> /etc/systemd/system/${UNIT}
sudo systemctl daemon-reload && sudo systemctl restart "$UNIT"
systemctl show "$UNIT" -p ExecStart -p ExecStartPre -p ExecStopPost
```

**8.3 Revertir la feature completa en el workspace:**

El `git revert` va en el **clon del launcher**, no en el workspace: `$WS` es un repo
propio con su historia de scaffold, sin remoto al launcher, así que el merge de 022 no
existe ahí. El workspace se actualiza portando los archivos, igual que se desplegó
(quirúrgico, como 015/016 en mclaren):

```bash
# 1) en el clon del launcher
cd <clon-del-launcher> && git revert <merge-de-022>

# 2) portar al workspace los archivos que 022 tocó
#    (modules/systemd-remote-control.service.tpl, modules/local-killswitch.sh.tpl,
#     modules/local-session-*.sh.tpl, scripts/lib/session_pointer.sh, scripts/agentctl,
#     setup.sh, scripts/lib/schema.sh)
#    y borrar los que 022 creó:
cd "$WS"
rm -f scripts/local/agent-session-exit.sh scripts/local/agent-session-check.sh \
      scripts/lib/session_pointer.sh

# 3) re-render + reinstalar + reiniciar (nada de esto lo hace --regenerate solo)
./setup.sh --regenerate
sudo cp ./agent-${AGENT}.service /etc/systemd/system/${UNIT}
sudo systemctl daemon-reload && sudo systemctl restart "$UNIT"
rm -f "$MARK"                       # el marcador no tiene consumidores tras el rollback
```

**Qué NO hay que deshacer**: el pointer renombrado. Si el hook retiró uno, era de una
sesión ya terminada; restaurarlo reintroduce el bug. `deployment.session_name` puede
quedarse en `agent.yml`: **verificado** — `agent_yml_validate` no rechaza claves
desconocidas (solo valida las listas explícitas de `scripts/lib/schema.sh:78-85` y
sus pares), así que un launcher pre-022 lo ignora sin romper el render. Lo que sí
vuelve es el nombre compuesto `<hostname>-<agent>`: otro cambio de identidad de una
sola vez en el cliente, en sentido inverso.

---

## 9. Trampas conocidas (aprendidas en hardware, 2026-07-18)

1. **La unit instalada es solo-root: `cat`/`grep` mienten por omisión.** Para el
   operador, `systemctl cat` falla con "Permission denied" y el check se salta en
   silencio — hallazgo del gate de 021, corregido en el PR #79. Usa siempre
   `systemctl show <unit> -p <Propiedad>`, que funciona sin privilegios y refleja lo
   que systemd **cargó de verdad**, no lo que dice un archivo del workspace. Esa es
   la razón de ser del check D3 (`scripts/agentctl:1168-1186`) y la razón por la que
   el check nuevo de 022 debe inspeccionar también la unit instalada: si no, el
   doctor da verde sobre un agente que jamás ejecutó el hook.

2. **`--verbose` NO emite las líneas `[bridge:init]`.** La unit corre con
   `--verbose` (`modules/systemd-remote-control.service.tpl:26`) y aun así el journal
   no muestra la decisión de reuso del pointer. Para verla hace falta `--debug-file`.
   Antes de usarlo, confirma la sintaxis exacta del flag en el host
   (`claude remote-control --help`): esta guía no la fija. Y recuerda **sacarlo**
   después: dejar la unit con `--debug-file` es contaminarla para el próximo gate
   (ver 2.1).

3. **Un `cp` de respaldo hecho sobre un archivo ya modificado no es un respaldo.**
   Pasó hoy. Toma el respaldo **antes** de cualquier edición, con nombre único
   (timestamp, nunca `.bak` reutilizado) y **verifícalo** (`ls -l`, o mejor
   `diff` contra el original) antes de tocar nada. Aplica igual a `$PTR` y a
   `$WS/.env`.

4. **`--regenerate` puede salir 0 sin haber tocado la unit instalada.** Repetido aquí
   porque es el error de despliegue más caro: sin `install_service: true` **y**
   `sudo -n`, deja el archivo staged y sale limpio (`setup.sh:2264-2266`, `:2384`).
   Y nada en `setup.sh` reinicia la unit. Instala y reinicia a mano, siempre.

5. **El journal no sirve para decidir si el agente está conectado.** La línea de
   estado se redibuja en el mismo lugar y llega al journal como blob binario, así que
   el último texto legible puede decir "connecting" con la sesión perfectamente
   conectada (research.md R2, alternativas rechazadas). Ese artefacto ya produjo un
   diagnóstico equivocado durante el incidente.

6. **El socket `:443` ESTABLECIDO tampoco prueba nada aquí.** Durante el incidente
   había tráfico bidireccional real mientras el agente era inutilizable
   (research.md R9). Ni el predicado del journal ni el del socket detectan una sesión
   muerta.

7. **Nunca crear un archivo llamado `.env` bajo `.state/`.**
   `docker/scripts/lib/backup_identity.sh:71-73` lo mete en el hash y `:152-154` lo
   cifra a `.env.age` para empujarlo a la rama `backup/identity` del fork. Por eso el
   marcador vive en `scripts/heartbeat/`, junto a `qmd-index.json`, `wiki-graph.json`
   y los `*-backup.json`. (El pointer y su sibling retirado sí viven bajo
   `.state/.claude/projects/`, pero eso no entra al backup: el whitelist son 4 rutas
   explícitas, `:30-38`, y `.claude/projects` no está entre ellas.)

8. **No reescribir el `bridge-pointer.json`, solo renombrarlo.** El proceso, apenas
   escribe el pointer, lo relee y **sale con error** si el pid no es el suyo
   ("Another `claude remote-control` instance (pid N) is already running in this
   directory" — research.md R1b). Cualquier cosa que escriba un pointer nuevo se hace
   pasar por otra instancia y mata el arranque.

---

## 10. Lo que esta guía NO puede verificar todavía

Declarado explícitamente para que nadie lo lea como hecho verificado:

- **Los artefactos de 022 no existen en el árbol.** `scripts/lib/session_pointer.sh`,
  los dos hooks, `session-exit.json`, `_local_session_doctor` y
  `deployment.session_name` están **especificados** (plan.md, data-model.md, los dos
  contratos) pero no escritos. Todo lo que esta guía dice de ellos sale de esos
  documentos, no de código leído; si la implementación se desvía, gana el árbol y
  corrige esta guía.
- **El vocabulario de `$EXIT_CODE`** (`exited`/`killed`/`dumped`) y el hecho de que
  systemd exporte `$SERVICE_RESULT`/`$EXIT_CODE`/`$EXIT_STATUS` al `ExecStopPost`
  vienen de `systemd.service(5)` vía research.md; **nadie los ejecutó en un systemd
  real** durante el diseño (el host de diseño es macOS). Si el valor real difiere en
  mclaren, la rama que se activa es C5 (`retire`), segura por FR-014 — pero el gate de
  §3.3 es lo único que lo confirma.
- **El formato de `systemctl show -p ExecStartPre --value`** varía por versión de
  systemd; por eso los checks D5/D6 hacen match de subcadena y no de igualdad, y por
  eso §2.2 mira el contenido y no compara strings completos.
- **Que el `ExecStopPost` no corre en un corte de energía** se toma de la
  documentación, no de una medición propia. El escenario C de §3.3 lo ejercita con un
  `reboot` ordenado, que es el caso opuesto.
- **La sintaxis exacta de `--debug-file`** no está citada de una fuente leída; hay
  que confirmarla contra `claude remote-control --help` en el host.
- **Discrepancia interna abierta entre artefactos de diseño**: el contrato
  (`contracts/session-pointer-hygiene.md` §1.3) fija el nombre retirado como
  `bridge-pointer.retired.json`; `data-model.md` E2 lo ejemplifica como
  `bridge-pointer.json.retired`. Esta guía usa el del contrato, que es el normativo.
  La implementación debe cerrar la discrepancia en uno de los dos documentos.
- **La confirmación de alcanzabilidad solo la puede dar el operador** desde el
  teléfono o claude.ai/code. Ningún comando del host la sustituye: ese es
  precisamente el punto de la feature.
- **La confirmación de alcanzabilidad solo la puede dar el operador** desde el
  teléfono o claude.ai/code. Ningún comando del host la sustituye: ese es
  precisamente el punto de la feature.

## Artefactos

- [spec.md](spec.md) — 3 historias, FR-001..FR-015, SC-001..SC-009, 3 clarificaciones.
- [plan.md](plan.md) — enfoque, Constitution Check 6/6, mapa de archivos, nota de Fase 2.
- [research.md](research.md) — R1/R1b (la lógica del vendor extraída del binario),
  R2 (la medición que descarta `same-dir`), R4 (el slug), R6 (la unit instalada ≠ la
  renderizada), R7 (el nombre de sesión), R9 (el falso positivo que ya está
  embarcado).
- [data-model.md](data-model.md) — E1 pointer, E2 marcador (esquema JSON + semántica
  de consumo único), E3 nombre de sesión, E4 alcanzabilidad.
- [contracts/session-pointer-hygiene.md](contracts/session-pointer-hygiene.md) — API de
  la lib, contratos de los dos hooks (ramas C1-C8), doctor D5/D6/D7, escenarios S1-S28.
- [contracts/session-name-resolution.md](contracts/session-name-resolution.md) — regla
  de resolución, archivos a tocar, escenarios N1-N8.
