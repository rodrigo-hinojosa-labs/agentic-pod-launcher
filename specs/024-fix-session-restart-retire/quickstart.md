# Quickstart — 024-fix-session-restart-retire

Cómo reproducir el bug, cómo re-correr la medición que sostiene el arreglo, y qué
gates hay que pasar antes del merge.

**Regla de lectura.** Todo lo que se afirma sobre el código está citado como
`archivo:línea` y fue leído. Todo lo que se afirma sobre systemd fue **medido** en
mclaren (Debian 13, systemd 257, 2026-07-20) y dice de qué caso viene. Lo que
todavía **no existe en el árbol** —lo que esta feature va a crear— está marcado
como *diseño*, nunca como hecho. Lo que no se midió se dice "no medido" y no se
rellena.

---

## 0. Nomenclatura

| Artefacto | Ruta | Estado |
|---|---|---|
| Regla de decisión | `session_decide()` en `scripts/lib/session_pointer.sh:212-224` | **existe** (es el bug) |
| Marcador de salida | `<ws>/scripts/heartbeat/session-exit.json` | **existe** (`session_exit_marker_path`, `:110-112`) |
| Hook de `ExecStopPost` | `<ws>/scripts/local/agent-session-exit.sh` ← `modules/local-session-exit.sh.tpl` | **existe** (`setup.sh:2303`) |
| Hook de `ExecStartPre` | `<ws>/scripts/local/agent-session-check.sh` ← `modules/local-session-check.sh.tpl` | **existe** (`setup.sh:2304`) |
| Hook de `ExecStop` | `<ws>/scripts/local/agent-session-stop.sh` ← `modules/local-session-stop.sh.tpl` | *diseño* (`plan.md` §Project Structure) |
| Campo `stop_cause` | **dentro del marcador existente**, escrito por el hook de `ExecStop` | *diseño*; ver `data-model.md`. **No** se crea ningún fichero de estado nuevo: el borrador de dos ficheros se descartó en revisión |
| Directiva `ExecStop=` | `modules/systemd-remote-control.service.tpl` | *diseño*; **hoy no está** (verificado: la plantilla tiene `ExecStartPre` ×2 `:25,:33`, `ExecStart` `:38`, `ExecStopPost` `:44`) |

Variables usadas en todos los bloques de este documento:

```bash
AGENT=mclaren-admin
UNIT=agent-${AGENT}.service
WS=/home/rodrigo-hinojosa/Documents/Personal/Claude/Agents/mclaren-admin
SLUG=$(printf '%s' "$WS" | sed 's/[^a-zA-Z0-9]/-/g')
PTR="$WS/.state/.claude/projects/$SLUG/bridge-pointer.json"
MARK="$WS/scripts/heartbeat/session-exit.json"
```

El slug medido en mclaren es
`-home-rodrigo-hinojosa-Documents-Personal-Claude-Agents-mclaren-admin`
(un solo directorio bajo `projects/`). Si `ls -l "$PTR"` no encuentra nada,
lista `ls -1 "$WS/.state/.claude/projects/"` antes de seguir.

---

## 1. Reproducir el bug en 60 segundos

### 1.0 Qué reproduce el bug y qué no

La reproducción fiel **no es "borrar el chat"**. El disparador es que el proceso
del agente se detenga, por cualquiera de estas dos vías:

- **la sesión termina** (el proceso sale por su cuenta) — este caso 022 lo arregla
  y debe seguir arreglado;
- **el servicio se detiene o se reinicia** (`systemctl stop|restart`, reinicio del
  host) — **este es el caso roto**: hoy también retira el puntero.

> **Advertencia.** Reproducir el caso roto con una conversación viva **cuesta esa
> conversación**: el enlace que el operador tiene abierto muere y no se recupera.
> El agente queda `active` y alcanzable, pero en un enlace nuevo. Si no quieres
> pagar eso, usa la reproducción en frío del punto 1.1, que prueba exactamente la
> misma regla sin tocar el agente.

### 1.1 En frío, sin costo: la regla decide mal por sí sola

Corre esto en cualquier host que tenga el repo o un workspace desplegado. No toca
al agente, no necesita systemd ni sudo:

```bash
bash -c '. scripts/lib/session_pointer.sh
  # La llamada es DELIBERADAMENTE idéntica en las dos líneas: es el valor que
  # systemd entrega en AMBOS casos. Esa igualdad es el bug.
  printf "restart con sesion viva -> systemd reporta exit_code=exited -> %s\n" "$(session_decide exited present)"
  printf "la sesion termino sola  -> systemd reporta exit_code=exited -> %s\n" "$(session_decide exited present)"'
```

Salida, verificada corriendo el snippet contra el árbol de hoy:

```text
restart con sesion viva -> systemd reporta exit_code=exited -> retire
la sesion termino sola  -> systemd reporta exit_code=exited -> retire
```

El valor de entrada es el mismo en los dos casos porque **systemd entrega el
mismo valor**: Claude Code atrapa `SIGTERM` y sale con código 0, así que
`ExecStopPost` recibe `service_result=success` / `exit_code=exited` en ambos
(medido, casos A/B/C de §2). La rama `keep` solo se alcanza con `killed`
(`session_pointer.sh:220`), lo que exige que el proceso **no** atrape la señal —
y sí la atrapa. La regla se comporta como *retirar siempre*.

**Eso es el bug entero**: dos causas distintas, un solo valor, una sola decisión.
Y explica por qué la suite lo dejó pasar: cada test elige el valor que le pasa a
`session_decide`, así que verifica que la regla implementa lo que el autor creía,
no que lo que el autor creía fuera cierto.

### 1.2 En vivo, con costo: el restart retira un puntero sano

```bash
# 1) foto previa
cp "$PTR" /tmp/ptr.before.json
jq -r '.sessionId' "$PTR"                    # sin jq: sha256sum "$PTR"
ls -l "$WS/.state/.claude/projects/$SLUG/"   # NO debe haber bridge-pointer.retired.json
journalctl -u "$UNIT" --since -10min --no-pager | grep -o 'session_[A-Za-z0-9]*' | tail -1

# 2) el disparador (con una conversación viva abierta desde el cliente)
sudo systemctl restart "$UNIT"
sleep 25

# 3) qué mirar en el journal
journalctl -u "$UNIT" --since -2min --no-pager | grep -iE 'session-check|session-exit|Deactivated|session_'
```

Salida medida en mclaren el 2026-07-20 00:21:22 (esta es la traza del defecto):

```text
systemd[1]: Stopping agent-mclaren-admin.service...
claude[1154300]: ·✔︎· Connected · mclaren-admin
claude[1154300]: .../session_01Fbg3Cg1ywYaeAx32UsHot8      <- sesión VIVA al momento del stop
systemd[1]: agent-mclaren-admin.service: Deactivated successfully.
agent-session-check.sh[591196]: agent-mclaren-admin session-check: retired a stale session pointer (previous exit_code=exited); a fresh session will be announced
claude[591215]: .../session_01A1obgNuL2XkXLX7bdr6nQV      <- sessionId NUEVO
```

```bash
# 4) la evidencia en disco
ls -l "$WS/.state/.claude/projects/$SLUG/"   # apareció bridge-pointer.retired.json
cmp -s /tmp/ptr.before.json "$PTR" && echo "IGUAL (sano)" || echo "DISTINTO (bug reproducido)"
```

**Bug reproducido** = la línea `agent-<name> session-check: retired a stale session pointer (previous
exit_code=exited); a fresh session will be announced` en el journal **más** el hermano `bridge-pointer.retired.json`
**más** un `sessionId` distinto al de la foto previa.

**Después del arreglo**, ese mismo bloque debe dar: sin línea `retired`, sin
hermano nuevo, y `cmp` diciendo `IGUAL (sano)`.

---

## 2. La sonda del discriminador (sostiene SC-005)

La regla nueva se apoya en una asimetría **temporal** de systemd, no en un valor:
dentro de `ExecStop`, `$EXIT_CODE` está **definido** si el proceso ya había salido
solo, y **vacío** si la parada la inicia systemd (porque `ExecStop` corre *antes*
de matarlo). `ExecStopPost` es idéntico en los tres casos que hay que separar —por
eso 022 no podía distinguirlos—.

Esta sonda re-corre esa medición en **cualquier host con systemd de usuario**. No
usa `sudo`, no toca al agente ni a su unit, y se limpia sola.

### 2.1 Precondición

```bash
systemctl --user show -p Version --value && systemctl --version | head -1 && hostnamectl --static
```

Si `systemctl --user` falla, no hay gestor de usuario en esa sesión (hace falta un
login real o `loginctl enable-linger $USER`). **No sustituyas por una unit de
sistema con sudo**: eso no es lo que se midió.

### 2.2 La sonda

```bash
cat > /tmp/probe-session-stop.sh <<'PROBE'
#!/bin/sh
# Sonda del discriminador de causa de parada (024 · research.md R2).
# Unidad de USUARIO desechable. Sin sudo. No toca el agente.
set -eu

UDIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
BASE="${TMPDIR:-/tmp}/024-probe"
LOG="$BASE/probe.log"
HOOK="$BASE/hook.sh"
UNIT=stopprobe.service

mkdir -p "$UDIR" "$BASE"
: > "$LOG"

# El hook lee las variables del entorno que systemd le entrega. No se ponen en
# la línea Exec= a propósito: systemd expande $VAR ahí con su propia sintaxis.
cat > "$HOOK" <<'EOS'
#!/bin/sh
printf '%s %-12s EXIT_CODE=[%s] EXIT_STATUS=[%s] SERVICE_RESULT=[%s]\n' \
  "${CASE:-?}" "$1" "${EXIT_CODE:-}" "${EXIT_STATUS:-}" "${SERVICE_RESULT:-}" >> "$LOG"
EOS
chmod +x "$HOOK"

write_unit() {   # $1=caso  $2=ExecStart  $3=Restart
  cat > "$UDIR/$UNIT" <<EOF
[Unit]
Description=024 session-stop discriminator probe ($1)

[Service]
Type=simple
Environment=CASE=$1
Environment=LOG=$LOG
TimeoutStopSec=2
ExecStart=$2
ExecStop=$HOOK ExecStop
ExecStopPost=$HOOK ExecStopPost
Restart=$3
RestartSec=30
EOF
  systemctl --user daemon-reload
  systemctl --user reset-failed "$UNIT" 2>/dev/null || true
}

# Un durmiente que ATRAPA TERM y sale 0 — el comportamiento de Claude Code.
CATCHER="/bin/sh -c 'trap \"exit 0\" TERM; while :; do sleep 1; done'"

# A · el proceso sale SOLO con código 0
write_unit A "/bin/sh -c 'sleep 2'" no
systemctl --user start "$UNIT" || true;   sleep 5

# B · systemctl stop
write_unit B "$CATCHER" no
systemctl --user start "$UNIT" || true;   sleep 2
systemctl --user stop  "$UNIT" || true;   sleep 2

# C · systemctl restart  (deja DOS líneas: el restart y la limpieza; ambas cuentan igual)
write_unit C "$CATCHER" no
systemctl --user start   "$UNIT" || true; sleep 2
systemctl --user restart "$UNIT" || true; sleep 2
systemctl --user stop    "$UNIT" || true; sleep 1

# D · el proceso sale SOLO con código 3
#     systemd OMITE ExecStop al salir SOLO con código != 0. Ojo: NO es "en cualquier
#     fallo" — el caso E también termina en fallo y ahí ExecStop SI corre.
write_unit D "/bin/sh -c 'sleep 2; exit 3'" no
systemctl --user start "$UNIT" || true;   sleep 5

# E · ignora TERM -> systemd lo mata con SIGKILL al vencer TimeoutStopSec
write_unit E "/bin/sh -c 'trap \"\" TERM; while :; do sleep 1; done'" no
systemctl --user start "$UNIT" || true;   sleep 2
systemctl --user stop  "$UNIT" || true;   sleep 3

# F · como A pero con Restart=always, que es lo que usa la unit real del agente
write_unit F "/bin/sh -c 'sleep 2'" always
systemctl --user start "$UNIT" || true;   sleep 5
systemctl --user stop  "$UNIT" || true;   sleep 1

# limpieza
systemctl --user stop "$UNIT" 2>/dev/null || true
rm -f "$UDIR/$UNIT"
systemctl --user daemon-reload
systemctl --user reset-failed "$UNIT" 2>/dev/null || true

echo "--- crudo -------------------------------------------------"
cat "$LOG"
echo "--- veredicto (primera linea ExecStop de cada caso) --------"
awk '$2=="ExecStop" && !seen[$1]++ {print $1, ($3=="EXIT_CODE=[]" ? "VACIO" : "DEFINIDO")}' "$LOG"
PROBE
sh /tmp/probe-session-stop.sh
```

### 2.3 Qué constituye un PASA

El veredicto debe ser **exactamente** esto:

```text
A DEFINIDO
B VACIO
C VACIO
E VACIO
F DEFINIDO
```

- **`D` no aparece**, y eso es parte del PASA: systemd omite `ExecStop` cuando el
  servicio terminó en fallo. `D` solo deja línea de `ExecStopPost`, con
  `SERVICE_RESULT=[exit-code]` — el campo que la tercera fila de la regla usa.
- `A`/`F` **DEFINIDO** frente a `B`/`C`/`E` **VACIO** es el discriminador completo.
  `F` prueba que `Restart=always` no lo altera.
- En el bloque crudo, las líneas de `ExecStopPost` de `A`, `B` y `C` son
  **idénticas** (`success` / `exited` / `0`). Esa igualdad es la causa raíz del bug
  y conviene verla con los propios ojos.

**FALLA** = cualquier caso fuera de ese patrón. Si `A` sale `VACIO` o `B`/`C` salen
`DEFINIDO`, la regla de esta feature no aplica a ese host y **no se implementa
encima**: se investiga primero. Esa es exactamente la lección de 022.

Medición de referencia: mclaren, systemd 257 (`257.9-1~deb13u1`), Debian 13,
aarch64. La confirmación de estabilidad fue de **5 escenarios × 3 repeticiones = 15/15**
(ver `../probes/confirm-probe.sh`, que es la sonda canónica). El caso F de la sonda de
arriba es una variante ilustrativa y NO forma parte de ese conteo.

---

## 3. Gates de verificación

### 3.A · En el host de desarrollo (macOS, sin systemd)

#### G1 — la suite, en las DOS versiones de bash

```bash
cd /Users/rodrigo-hinojosa/Documents/Cencosud/Claude/Agents/agentic-pod-launcher
bats tests/                      # bash del PATH (5.3.15)
PATH="/bin:$PATH" bats tests/    # bash de stock (3.2.57)
bats --version; bash --version | head -1; /bin/bash --version | head -1
```

- **PASA**: `0 not ok` en ambas corridas, y el total **no baja** de la baseline
  1159 ok (medida en las dos versiones antes de esta feature).
- **FALLA**: cualquier `not ok`, o un total menor que 1159 (test perdido).

Correr en una sola versión **no cuenta**: 023 midió que el mismo commit da verde y
rojo según el intérprete.

#### G2 — shellcheck

```bash
shellcheck -S error scripts/lib/session_pointer.sh scripts/agentctl setup.sh \
                    modules/local-session-check.sh.tpl \
                    modules/local-session-exit.sh.tpl \
                    modules/local-session-stop.sh.tpl
```

- **PASA**: salida vacía, rc 0.
- **FALLA**: cualquier hallazgo de severidad `error`.

#### G3 — mutación: revertir la regla debe tumbar un test NOMBRADO

Reintroduce el defecto a mano en `session_decide` (`scripts/lib/session_pointer.sh`)
volviendo al predicado de hoy —`[ "$marker" = "killed" ] && keep || retire`— y corre:

```bash
bats tests/session-pointer.bats tests/local-session-hooks.bats
```

- **PASA**: se pone rojo **al menos un test cuyo nombre identifique el caso del
  reinicio** (FR-010). El nombre debe nombrar la parada externa, no el código de
  salida; por ejemplo `S-decide: parada externa (ExecStop sin EXIT_CODE) + pointer
  → keep`. *(El nombre exacto lo fija `tasks.md`; el requisito es que se lea solo.)*
- **FALLA**: la suite queda verde, **o** el único rojo es un test genérico que no
  menciona el caso. Un rojo genérico no cumple FR-010: la próxima persona que lo
  vea no sabrá qué se rompió.

Repite la mutación por pieza nueva: neutraliza el hook de `ExecStop`, borra la
lectura de `service_result`, e invierte la fila de incertidumbre. Cada una debe
producir al menos un rojo.

> **Trampa de bats que ya mordió dos veces en este repo**: una aserción negada a
> mitad de cuerpo **no falla el test**. Los negativos de esta feature ("el hook NO
> retiró el puntero") son exactamente esa forma. Escribe
> `run grep -q '…' "$f"; [ "$status" -ne 0 ]`, o deja el `if … then false; fi`
> **último**.

#### G4 — sobrevive a `--regenerate` (FR-009)

Sobre un workspace de prueba, nunca editando artefactos derivados a mano:

```bash
./setup.sh --regenerate
grep -n 'ExecStop=' ./agent-<AGENT>.service          # la directiva nueva, presente
ls -l ./scripts/local/agent-session-stop.sh          # el hook nuevo, renderizado
grep -c '{{' ./scripts/local/agent-session-stop.sh   # 0 → sin placeholders sin sustituir
```

- **PASA**: `ExecStop=` presente, hook ejecutable, cero `{{`.
- **FALLA**: cualquier placeholder sin sustituir, o un hook ausente.

#### G5 — el modo contenedor intacto (FR-012)

```bash
git diff --stat origin/main -- docker/    # debe salir vacío
```

- **PASA**: sin diferencias bajo `docker/`.
- **FALLA**: una sola línea.

### 3.B · Solo en hardware con systemd

Estos tres **no se pueden correr en el host de desarrollo** y ningún verde de la
suite los sustituye (FR-011). El detalle operativo está en §4.

| Gate | Criterio | Cubre |
|---|---|---|
| **G6** | Un `systemctl restart` con la conversación abierta la conserva: sin línea `retired`, sin hermano `.retired.json`, `sessionId` idéntico, y el operador **confirma desde su cliente** que el enlace previo sigue sirviendo. Dos reinicios consecutivos. | SC-001 |
| **G7** | Cerrar la conversación desde el cliente deja al agente alcanzable de nuevo **sin tocar el host**: aparece el hermano `.retired.json`, un `bridge-pointer.json` nuevo con otro `sessionId`, y el operador confirma que puede hablarle. | SC-002 |
| **G8** | Tras cada uno de los dos casos, el journal nombra la **causa** y la **decisión**, y `agentctl doctor` informa la última decisión sin que haya que leer el código. | SC-003 |

**FALLA de G6** = cualquier `retired a stale session pointer` tras un restart.
**FALLA de G7** = el agente queda inalcanzable, o hay que intervenir el host.
**FALLA de G8** = el journal dice "stale" sin decir en qué se basó (que es
exactamente el estado de hoy).

---

## 4. Gate de hardware en mclaren — paso a paso

**Este gate corre ANTES del merge.** Van dos features seguidas mergeadas sin él:
021 costó un PR aparte (#79) y 022 costó este defecto. No es negociable.

### 4.0 Contexto real, ya medido

- Workspace vivo: `/home/rodrigo-hinojosa/Documents/Personal/Claude/Agents/mclaren-admin`.
- **`sudo` PIDE CONTRASEÑA en mclaren.** Consecuencia verificada: `--regenerate`
  reinstala la unit solo si `deployment.install_service: true` **y** `sudo -n true`
  funciona (gate `install_service` en `setup.sh:2331-2333`; decisión por `sudo -n true` en `:2464`; fallback staged en `:2469-2473`); si no, deja el archivo **staged** y **sale 0**.
  Y nada en `setup.sh` reinicia jamás la unit de sesión. Un `--regenerate` a secas
  deja al agente corriendo la lógica vieja con el doctor en verde.
- El alcance desde el cliente **solo lo puede confirmar el operador**. Ningún
  comando del host prueba G6/G7 por sí solo.

### 4.1 Precondición: qué está instalado de verdad

```bash
systemctl show "$UNIT" -p ExecStart -p ExecStartPre -p ExecStop -p ExecStopPost --value
systemctl is-active "$UNIT"
```

Antes del despliegue: `ExecStop` **vacío** (la directiva no existe todavía). Si
`ExecStart` trae `--spawn=same-dir` o `--debug-file`, la unit quedó en estado de
experimento de una medición anterior y hay que devolverla al estado de `main`
antes de empezar: un gate sobre esa unit no mide esta feature.

### 4.2 Foto previa (antes de tocar nada)

```bash
cp "$PTR" /tmp/gate024.ptr.before.json
jq -r '.sessionId' "$PTR" > /tmp/gate024.sid.before   # sin jq: sha256sum "$PTR"
ls -l "$WS/.state/.claude/projects/$SLUG/"            # ¿hay ya un .retired.json?
ls -l "$MARK" 2>/dev/null || echo "marcador ausente (normal: es de consumo único)"
sudo cp /etc/systemd/system/${UNIT} /root/${UNIT}.pre024.$(date +%Y%m%d-%H%M%S)
sudo ls -l /root/ | grep -F "${UNIT}.pre024"          # el glob lo expande TU shell, que no lee /root
```

Y que el operador **abra una conversación desde su cliente y la deje viva**. Sin
eso, G6 no prueba nada: un restart sin sesión viva no puede romper un enlace.

### 4.3 Desplegar — `--regenerate` NO basta

```bash
cd "$WS"
./setup.sh --regenerate

# OBLIGATORIO en mclaren, porque sudo pide contraseña y la unit quedó staged:
sudo cp ./agent-${AGENT}.service /etc/systemd/system/${UNIT}
sudo systemctl daemon-reload
sudo systemctl restart "$UNIT"

# verificar la unit INSTALADA, no el archivo del repo
systemctl show "$UNIT" -p ExecStartPre -p ExecStop -p ExecStopPost --value
```

Debe aparecer: dos `ExecStartPre` en orden (`agent-secret-check.sh` de 021, después
`agent-session-check.sh`), un `ExecStop` con `agent-session-stop.sh`, y un
`ExecStopPost` con `agent-session-exit.sh` — **todos con `ignore_errors=yes`**. Si
`ExecStop` sale vacío, la unit instalada sigue siendo la vieja: el `cp` no se hizo
o el `daemon-reload` falta. No sigas.

> Este `restart` de despliegue ocurre con la unit vieja todavía activa, así que
> **puede** retirar el puntero una última vez. Es esperado. La foto que cuenta para
> G6 se toma **después** de este paso, en 4.4.

### 4.4 G6 — restart con sesión viva conserva el enlace (SC-001)

Con la unit nueva instalada y una conversación abierta y viva:

```bash
cp "$PTR" /tmp/g6.before.json
jq -r '.sessionId' "$PTR" > /tmp/g6.sid.before

sudo systemctl restart "$UNIT"; sleep 25

# comparación posterior
cmp -s /tmp/g6.before.json "$PTR" && echo "PUNTERO INTACTO" || echo "PUNTERO CAMBIADO"
jq -r '.sessionId' "$PTR" > /tmp/g6.sid.after
diff /tmp/g6.sid.before /tmp/g6.sid.after && echo "sessionId preservado"
ls -l "$WS/.state/.claude/projects/$SLUG/" | grep -c 'retired'   # debe seguir igual que en 4.2
journalctl -u "$UNIT" --since -3min --no-pager | grep -iE 'session-check|session-stop|session-exit'
```

- **PASA**: `sessionId preservado`, sin hermano `.retired.json` nuevo, el journal
  dice que la parada fue **externa** y que el puntero se **conservó**, y —lo
  decisivo— **el operador confirma desde su cliente que el enlace previo sigue
  sirviendo**.
- **FALLA**: aparece `retired a stale session pointer`, o el `sessionId` cambió, o
  el operador ya no alcanza la conversación.

**Repetir el bloque completo una segunda vez** (SC-001 pide dos reinicios
consecutivos).

### 4.5 G7 — la sesión que termina sola se sigue limpiando (SC-002)

```bash
jq -r '.sessionId' "$PTR" > /tmp/g7.sid.before
# el operador CIERRA la conversación desde el cliente. Esperar ~25 s
# (salida del proceso + RestartSec=10 + arranque).
sleep 25

ls -l "$WS/.state/.claude/projects/$SLUG/"     # bridge-pointer.retired.json PRESENTE
jq -r '.sessionId' "$PTR" > /tmp/g7.sid.after
diff /tmp/g7.sid.before /tmp/g7.sid.after || echo "sessionId renovado — correcto"
journalctl -u "$UNIT" --since -3min --no-pager | grep -iE 'session-check|session-stop|session-exit'
```

- **PASA**: hermano retirado presente (renombrado, **nunca borrado** — FR-005), un
  `bridge-pointer.json` nuevo con otro `sessionId`, cero intervención en el host, y
  el operador confirma que le puede hablar.
- **FALLA**: el agente queda inalcanzable (sería el bug original de 022 de vuelta),
  o hace falta tocar algo en el host.

### 4.6 G8 — causa y decisión legibles (SC-003)

```bash
journalctl -u "$UNIT" --since -20min --no-pager | grep -iE 'session-check|session-stop'
cd "$WS" && ./scripts/agentctl doctor; echo "rc=$?"
```

- **PASA**: por cada arranque, una línea que nombra la **causa** (parada externa /
  la sesión terminó / indeterminada) **y** la decisión (conservado / retirado); y
  el doctor informa la última decisión. Con un agente sano, **cero WARN**.
- **FALLA**: una línea que solo dice "stale" sin su fundamento, o un doctor que no
  menciona la decisión. (Hoy `_local_session_doctor`, `scripts/agentctl:1247`, ya
  delata una unit instalada desactualizada; esa parte debe seguir pasando.)

### 4.7 Rollback

```bash
sudo cp /root/${UNIT}.pre024.<timestamp> /etc/systemd/system/${UNIT}
sudo systemctl daemon-reload && sudo systemctl restart "$UNIT"
```

Los hooks renderizados pueden quedarse: sin la directiva `ExecStop` en la unit,
el hook nuevo simplemente no se invoca.

---

## 5. Qué NO hace falta

- **DOCKER_E2E — fuera de alcance, verificado.** `session_pointer.sh` **no está
  espejado a `docker/`**: `find docker -name 'session_pointer.sh' -o -name
  'local-session*'` no devuelve nada, y el `Dockerfile` no lo copia. El modo
  contenedor no tiene puntero de sesión ni units de systemd, así que FR-012 se
  cumple por construcción y G5 (`git diff` vacío bajo `docker/`) es suficiente
  prueba. Verificado, no supuesto.
- **Campos nuevos en `agent.yml`** — la regla es constante, no configuración. No
  hay que tocar el wizard ni el esquema, y por lo tanto no aplican los tres
  touchpoints de test que un prompt nuevo rompería.
- **Un detector de vitalidad** — prohibido por FR-006. El precedente es `ebfe35f`:
  el bridge watchdog escrapeaba paneles de tmux, daba falsos positivos y mataba
  sesiones sanas cada ~2 minutos. La decisión ocurre **una vez por arranque**,
  sobre un hecho que systemd ya registró.

---

## 6. Nota de despliegue

**Un workspace existente no se corrige solo.** Son dos pasos, y el segundo es el
que se olvida:

```bash
cd <workspace>
./setup.sh --regenerate                                   # 1) rehace hooks + unit
sudo cp ./agent-<AGENT>.service /etc/systemd/system/agent-<AGENT>.service
sudo systemctl daemon-reload
sudo systemctl restart agent-<AGENT>.service              # 2) sin esto, nada cambia
```

Por qué el paso 2 es obligatorio y no un detalle:

1. `--regenerate` **solo reinstala la unit** si `deployment.install_service: true`
   **y** `sudo -n true` funciona (gate `install_service` en `setup.sh:2331-2333`; decisión por `sudo -n true` en `:2464`; fallback staged en `:2469-2473`). En un host donde `sudo`
   pide contraseña —mclaren— deja el archivo staged y **sale 0**.
2. `--regenerate` **nunca reinicia** la unit de sesión. No hay un solo
   `systemctl restart` en `setup.sh`.

Combinados: un operador que corre `--regenerate` y ve rc 0 puede quedarse con la
lógica vieja corriendo por tiempo indefinido. El doctor lo delata —esa es la razón
de ser de la comprobación D5/D6 de 021/022 sobre la unit **instalada**
(`scripts/agentctl:1264-1287`)—, pero hay que mirarlo:

```bash
./scripts/agentctl doctor
```

---

## 7. Lo que este documento NO puede afirmar

Se declara en vez de rellenarse:

- **Que la suite host valide el comportamiento de systemd.** No lo hace y no puede:
  corre en macOS, donde systemd no existe. Los fixtures se alimentan con los
  valores **medidos** en §2, lo cual los vuelve fieles, pero fidelidad no es
  verificación. Eso lo cubre §4 y solo §4 (FR-011).
- **Si la restauración del enlace por parte del proveedor sigue valiendo tras un
  apagado LARGO (horas).** **No medido.** No se reinició mclaren para comprobarlo:
  es el agente de producción del operador. Riesgo residual declarado: conservar un
  puntero cuya sesión ya expiró del lado del servidor reproduce el síntoma original
  de 022. Mitigación disponible si aparece —acotar la conservación por antigüedad—;
  **no se implementa ahora**, porque diseñar sobre un caso no medido es exactamente
  el error que originó esta feature.
- **La frecuencia relativa de los dos casos.** **No medido.** El journal de mclaren
  retiene un solo boot, desde el 2026-07-18 13:56: en esa ventana de ~2 días hubo
  4 paradas iniciadas por systemd y 0 salidas propias. Muestra insuficiente para
  concluir nada. Con FR-007 registrando causa y decisión en cada arranque, el
  conteo saldrá solo con el tiempo, sin instrumentación dedicada.
