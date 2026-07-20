# Contract: clasificación de la causa de parada y decisión sobre el puntero

**Feature**: 024-fix-session-restart-retire
**Fase**: 1 · Este es el documento contra el que se escriben los tests.

Regla de rotulado, aplicada en todo el documento: **MEDIDO** = está en la tabla de
la sonda; **INFERENCIA** = se deriva de lo medido pero no se observó; **POLÍTICA** =
es una elección, no una observación. Un caso sin rótulo es un error de redacción.

---

## 1 · La señal

### 1.1 Enunciado

Dentro del hook de `ExecStop`, systemd entrega `$EXIT_CODE`:

- **definido** cuando el proceso principal ya había salido por su cuenta;
- **vacío** cuando la parada la inició systemd y el proceso sigue vivo.

Funciona porque systemd puebla `$EXIT_CODE`/`$EXIT_STATUS` recién cuando el proceso
principal murió. En una parada iniciada por systemd, `ExecStop` corre *antes* de
matarlo — para eso existe.

**Alcance de lo medido**: los escenarios de parada externa observados son
`systemctl stop`, `systemctl restart` y el `SIGKILL` por `TimeoutStopSec` contra un
proceso que ignora TERM. El **apagado del host NO se midió**; que caiga del mismo
lado es INFERENCIA (ver §3.2).

### 1.2 La medición

Host: mclaren. `uname -m` → `aarch64`. `systemctl --version` → `systemd 257
(257.9-1~deb13u1)`, Debian 13. Fecha: 2026-07-20. Sonda: unidad de **usuario**
desechable, sin `sudo`, sin tocar el agente.

| Caso | Escenario | ¿Corrió `ExecStop`? | `EXIT_CODE` dentro de `ExecStop` | `ExecStopPost` |
|---|---|---|---|---|
| A | sale solo, código 0 | Sí | `exited` (**definido**) | `success` / `exited` / `0` |
| B | `systemctl stop` | Sí | **vacío** | `success` / `exited` / `0` |
| C | `systemctl restart` | Sí | **vacío** | `success` / `exited` / `0` |
| D | sale solo, código 3 | **No** | — | `exit-code` / `exited` / `3` |
| E | ignora TERM → `SIGKILL` | Sí | **vacío** | `timeout` / `killed` / `KILL` |

Obsérvese que `ExecStopPost` es **idéntico** en A, B y C. Ahí está la razón de que
022 no pudiera separarlos: miró el hook equivocado.

### 1.3 Confirmación de estabilidad

Segunda pasada, **5 escenarios × 3 repeticiones = 15 corridas**, incluyendo la
variante `Restart=always` que usa la unit real
(`modules/systemd-remote-control.service.tpl:45`):

```text
sale solo (Restart=no)              → DEFINIDO(exited)  ×3
systemctl stop (Restart=no)         → VACIO             ×3
systemctl restart (Restart=no)      → VACIO             ×3
sale solo (Restart=always)          → DEFINIDO(exited)  ×3
systemctl restart (Restart=always)  → VACIO             ×3
```

**15/15 consistente.** No es un artefacto de timing y `Restart=always` no lo altera.

---

## 2 · La refutación (leer antes de "mejorar" este contrato)

La hipótesis de partida era: *"`ExecStop` se ejecuta solo cuando systemd detiene el
servicio, y no cuando el proceso sale por su cuenta"*.

**Es FALSA, y se midió.** En el caso A —el proceso sale solo— `ExecStop` **corrió
igual**. Lo que discrimina no es *si* corre, sino *qué ve cuando corre*.

Esta sección existe porque la feature 022 nació de aceptar un discriminador
plausible sin medirlo. Cualquier redacción futura del tipo "`ExecStop` significa que
systemd nos está deteniendo" reintroduce el mismo error y **contradice la tabla de
§1.2**. Vale también para los comentarios de las plantillas: quedan renderizados en
la unit instalada y le enseñan el modelo mental al próximo lector.

---

## 3 · Tabla oráculo

Identificadores `C1..C10`. Los tests los referencian por identificador, y **los
escenarios de medición se nombran por su nombre** (`sale solo`, `systemctl stop`, …)
para no colisionar con las letras A–E de §1.2.

### 3.1 Casos

| # | `stop_cause` en el marcador | Resto del marcador | Puntero | Decisión | Respaldo |
|---|---|---|---|---|---|
| C1 | `external` | cualquiera | `present` | `keep` | MEDIDO (stop, restart, SIGKILL) |
| C2 | `session-ended` | cualquiera | `present` | `retire` | MEDIDO (sale solo, código 0) |
| C3 | ausente | `service_result=exit-code` | `present` | `retire` | MEDIDO (sale solo, código 3) |
| C4 | ausente | ausente | `present` | `keep` | POLÍTICA (FR-004) |
| C5 | ausente | ilegible o truncado | `present` | `keep` | POLÍTICA (FR-004) |
| C6 | presente pero con valor desconocido | cualquiera | `present` | `keep` | POLÍTICA (FR-004) |
| C7 | cualquiera | cualquiera | `absent` | `noop` | comportamiento actual (`session_pointer.sh:214-217`) |
| C8 | cualquiera | cualquiera | `unknown` | `noop` + aviso | comportamiento actual |
| C9 | ausente (unit vieja, sin `ExecStop`) | cualquiera | `present` | `keep` | POLÍTICA — compatibilidad hacia atrás |
| C10 | cualquiera | ya consumido por otro arranque | `present` | `keep` | POLÍTICA (FR-004) |

**C9 es load-bearing**: un agente cuya unit instalada todavía no tiene la directiva
`ExecStop` nunca escribirá `stop_cause`, y debe degradar hacia **conservar**. Es lo
contrario de lo que hace hoy, y es lo que evita que una actualización a medio aplicar
siga destruyendo conversaciones.

**C10** es el arranque perdedor de una carrera: `session_exit_marker_consume`
(`session_pointer.sh:179`) resuelve por `rename`, así que solo un arranque obtiene el
contenido y el otro ve "sin marcador".

### 3.2 El apagado del host

Es una parada iniciada por systemd, así que por §1.1 debería caer en C1. **Es
INFERENCIA, no medición**: no se reinició mclaren para comprobarlo, por ser el agente
de producción del operador.

Riesgo residual declarado: conservar un puntero cuya sesión expiró del lado del
servidor reproduce el síntoma original de 022. Mitigación disponible si aparece
(acotar por antigüedad) que **no se implementa ahora**, porque sería diseñar sobre un
caso no medido — el error que originó esta feature.

### 3.3 Estado `unknown` del puntero (C8)

`session_pointer_path` (`session_pointer.sh:49`) devuelve rc≠0 por **varias** causas
distintas, no solo por haber más de un candidato: `CLAUDE_CONFIG_DIR` vacío o que no
sea directorio (`:55-56`), fallo al listar `projects` (`:63`), y más de un candidato
(`:89`). Las cuatro deciden `noop`, pero un test escrito contra una sola deja las
demás sin cubrir.

---

## 4 · Contrato de las directivas de la unit

Orden en `modules/systemd-remote-control.service.tpl`, con los hooks que 021 y 022
ya instalaron:

```ini
ExecStartPre=-<ws>/scripts/local/agent-secret-check.sh     # 021
ExecStartPre=-<ws>/scripts/local/agent-session-check.sh    # 022 · consume y decide
ExecStart=<claude> remote-control --name "<session>" --spawn=session --verbose
ExecStop=-<ws>/scripts/local/agent-session-stop.sh         # 024 · NUEVO · crea la causa
ExecStopPost=-<ws>/scripts/local/agent-session-exit.sh     # 022 · fusiona la salida
```

Reglas:

1. **Los tres hooks llevan el prefijo `-`.** Ninguno puede convertir un apagado o un
   arranque en un fallo de unit (Principio IV). Además salen 0 internamente.
2. `agent-secret-check.sh` va **antes** de `agent-session-check.sh`; ese orden ya
   está establecido por 021 y no se altera.
3. `ExecStop` va **antes** de `ExecStopPost`, que es el orden en que systemd los
   ejecuta.
4. La directiva se renderiza desde la plantilla, nunca se edita en la unit instalada
   (Principio I). Debe sobrevivir a `./setup.sh --regenerate`.

**Un solo marcador**: `ExecStop` lo crea con la causa, `ExecStopPost` le fusiona los
campos de salida, `ExecStartPre` lo consume una vez. No se introduce ningún fichero
de estado nuevo.

---

## 5 · Contrato de observabilidad

### 5.1 Registro (FR-007)

El hook de arranque emite por `stderr` —que en la unit va al journal— una línea con
el prefijo que ya usa `modules/local-session-check.sh.tpl:33`
(`_info() { echo "agent-${AGENT_NAME} session-check: $1" >&2; }`). Textos esperados,
completos:

| Caso | Línea |
|---|---|
| C1 | `agent-<name> session-check: previous stop was external (systemd) — session pointer kept` |
| C2 | `agent-<name> session-check: previous session ended — retired stale pointer; a fresh session will be announced` |
| C3 | `agent-<name> session-check: previous session exited with failure — retired stale pointer; a fresh session will be announced` |
| C4-C6, C9, C10 | `agent-<name> session-check: stop cause undetermined — keeping the session pointer (conservative default)` |
| C8 | el aviso actual de puntero irresoluble |

Cada línea nombra **causa** y **decisión**. La línea actual
(`local-session-check.sh.tpl:55`) dice `retired a stale session pointer (previous
exit_code=…); a fresh session will be announced`: afirma "stale" sin decir en qué se
basó, y es parte de por qué el defecto pasó desapercibido.

### 5.2 Diagnóstico (FR-008)

`agentctl doctor` en modo local reporta:

1. la causa y la decisión del último arranque, mientras el marcador consumido siga
   disponible;
2. si la **unit instalada** ejecuta la directiva `ExecStop` — leído con
   `systemctl show -p ExecStop`, **no** con `systemctl cat`, que da `Permission
   denied` en una unit root-only y haría que el check se saltara en silencio (lección
   medida en el gate de 021);
3. cuando la unit instalada no coincide con la que el workspace generaría, con el
   remedio `sudo cp … ; daemon-reload ; restart`.

El punto 2 es el que delata el caso medido en mclaren: `--regenerate` deja la unit
**staged** y no la instala cuando `sudo` no está disponible
(`setup.sh:2464` decide por `sudo -n true`; el fallback staged está en `:2469-2473`,
y la llamada entera está gateada por `install_service:true` en `setup.sh:2331-2333`).

---

## 6 · Nombres de los tests

El test del caso del reinicio **debe nombrar el caso en su título**. Por ejemplo:

```text
session_decide keeps the pointer when systemd initiated the stop (C1, restart)
```

Razón: en 022 un test que asertaba un hint compartido por dos avisos distintos pasaba
por la razón equivocada, y solo lo destapó la corrida de mutación
(`specs/022-local-session-lifecycle/tasks.md:165`, tests S16/S17). Un rojo que llega
desde un test cuyo nombre habla de otra cosa cuesta el diagnóstico completo.

Regla de mutación (SC-004): revertir `session_decide` a la regla actual
(`if [ "$marker" = "killed" ]` → `keep`, si no `retire`, `session_pointer.sh:218-222`)
**debe** poner en rojo al menos un test cuyo nombre mencione el reinicio.

---

## 7 · La sonda reproducible (SC-005)

Versionadas en [`../probes/`](../probes/). Corren en cualquier host con systemd de
usuario, sin `sudo`, y se limpian solas:

```bash
sh specs/024-fix-session-restart-retire/probes/run-probe.sh      # 5 escenarios
sh specs/024-fix-session-restart-retire/probes/confirm-probe.sh  # ×3 + Restart=always
```

**PASA** cuando: en `sale solo` el `ExecStop` reporta `EXIT_CODE` definido; en
`systemctl stop`, `systemctl restart` e `ignora TERM` lo reporta vacío; y en
`sale solo con código 3` el `ExecStop` no corre.

---

## 8 · Fuera de alcance

- **Modo contenedor.** `session_pointer.sh` **no** está espejado a `docker/`
  (verificado). DOCKER_E2E no aplica.
- **Detectar si la sesión sigue viva** del lado del relay: prohibido por FR-006 y por
  el precedente `ebfe35f`.
- **Acotar la conservación por antigüedad**: ver §3.2.
- **Medir la frecuencia relativa** de los dos casos: el journal de mclaren retiene un
  solo boot (~2 días). Queda como subproducto natural de FR-007 con el tiempo.
- **Campos nuevos en `agent.yml`**: la regla es constante, no configuración.
