# Research: reiniciar el agente deja de romper el enlace del cliente

**Feature**: 024-fix-session-restart-retire
**Fecha**: 2026-07-20
**Host de medición**: mclaren (Raspberry Pi, Debian 13, systemd 257 `257.9-1~deb13u1`, aarch64)

Las cuatro preguntas abiertas de la spec se cierran **midiendo**. Cada afirmación
de este documento tiene su comando y su salida, o dice explícitamente que no se
pudo medir.

---

## R1 · La hipótesis de partida era FALSA

**Pregunta**: ¿`ExecStop=` se ejecuta solo cuando systemd detiene el servicio, y
no cuando el proceso principal sale por su cuenta?

**Respuesta medida: NO. `ExecStop` también corre cuando el proceso sale solo.**

La sonda (`sh /tmp/run-probe.sh`, unidad de usuario desechable, sin `sudo`, sin
tocar el agente) mostró `ExecStop corrio?: SI` tanto en el caso A (el proceso sale
solo con código 0) como en los casos B/C/E (parada iniciada por systemd).

**Esto es exactamente lo que la spec exigía comprobar antes de construir encima.**
Si se hubiera aceptado el candidato razonando —"suena lógico que ExecStop solo
corra en una parada explícita"— se habría repetido el error de 022: elegir un
discriminador que no discrimina y descubrirlo en producción.

Excepción medida: en el caso D (el proceso sale solo con código **3**), `ExecStop`
**NO** corrió. systemd omite `ExecStop` cuando el servicio terminó en fallo. Ese
caso se maneja aparte (ver R3).

---

## R2 · El discriminador que SÍ existe, y dónde estaba escondido

Al registrar las tres variables dentro de **ambos** hooks apareció una asimetría
que no está en `ExecStopPost` —donde 022 miró— sino en `ExecStop`:

| Caso | ¿Corrió `ExecStop`? | `EXIT_CODE` **dentro de `ExecStop`** | `ExecStopPost` |
|---|---|---|---|
| A · sale solo, código 0 | Sí | **`exited`** (definido) | `success` / `exited` / `0` |
| B · `systemctl stop` | Sí | **vacío** | `success` / `exited` / `0` |
| C · `systemctl restart` | Sí | **vacío** | `success` / `exited` / `0` |
| D · sale solo, código 3 | **No** | — | `exit-code` / `exited` / `3` |
| E · ignora TERM → SIGKILL | Sí | **vacío** | `timeout` / `killed` / `KILL` |

**La señal es temporal, no de valor.** systemd define `$EXIT_CODE`/`$EXIT_STATUS`
recién cuando el proceso principal ya murió:

- Si el proceso **salió solo**, cuando systemd corre `ExecStop` la muerte ya
  ocurrió → las variables **están definidas**.
- Si la parada la **inicia systemd**, `ExecStop` corre *antes* de matar al proceso
  —para eso existe, para pedirle que termine— → las variables **están vacías**.

Nótese que `ExecStopPost` es idéntico en A, B y C (`success`/`exited`/`0`): por eso
022 no podía distinguirlos. **La información existía; estaba un hook más arriba.**

### Confirmación de estabilidad

Una segunda pasada repitió cada caso **3 veces** e incluyó la variante
`Restart=always`, que es la que usa la unit real del agente
(`modules/systemd-remote-control.service.tpl:45`):

```text
A · el proceso sale SOLO (Restart=no)        → DEFINIDO(exited)  ×3
B · systemctl stop (Restart=no)              → VACIO             ×3
C · systemctl restart (Restart=no)           → VACIO             ×3
D · sale SOLO, Restart=always                → DEFINIDO(exited)  ×3
E · restart, Restart=always                  → VACIO             ×3
```

**15/15 consistente.** No es un artefacto de timing, y `Restart=always` no lo
altera.

### Decisión

**Discriminador adoptado**: dentro de `ExecStop`, `$EXIT_CODE` definido ⇒ el
proceso salió por su cuenta (la sesión terminó); `$EXIT_CODE` vacío ⇒ la parada
la inició systemd (reinicio, detención, apagado).

**Alternativas descartadas, midiendo**:

- *Seguir con `$EXIT_CODE` en `ExecStopPost`* (lo que hace 022): descartado, es
  idéntico en los tres casos que hay que separar (tabla de arriba, filas A/B/C).
- *`$SERVICE_RESULT`*: descartado como discriminador principal. Vale `success` en
  A, B y C por igual. Sí sirve para separar el caso D (`exit-code`), y ya se está
  persistiendo sin que nadie lo lea (`session_pointer.sh:137`).
- *`$EXIT_STATUS`*: descartado, sigue a `EXIT_CODE` y no aporta separación extra.
- *Inferir por vitalidad de la sesión* (consultar al relay, sondear el socket):
  descartado por FR-006 y por el precedente `ebfe35f`, el bridge watchdog que se
  revirtió por falsos positivos.

---

## R3 · La regla completa, incluidos los bordes

`ExecStop` deja constancia; `ExecStopPost` escribe el marcador como hoy y le
agrega la causa. `ExecStartPre` decide:

| Constancia de `ExecStop` | Marcador de `ExecStopPost` | Causa | Decisión |
|---|---|---|---|
| presente, `EXIT_CODE` vacío | cualquiera | parada externa | **conservar** |
| presente, `EXIT_CODE` definido | cualquiera | la sesión terminó | **retirar** |
| ausente | `service_result=exit-code` | la sesión terminó en fallo | **retirar** |
| ausente | ausente o ilegible | indeterminada | **conservar** (FR-004) |

La cuarta fila es la que cumple FR-004: ante incertidumbre real —marcador ausente,
corrupto, o una unit vieja sin el hook nuevo— se elige la opción que **no destruye
trabajo del operador**. Es lo contrario del default actual, y es deliberado: el
costo de conservar de más es que el operador vea una conversación muerta y reinicie;
el costo de retirar de más es perder la conversación sin aviso.

La tercera fila usa `service_result`, el campo que ya se persiste y nadie lee.

---

## R4 · Frecuencia relativa de los dos casos: NO MEDIBLE con los datos existentes

**Pregunta**: ¿son los reinicios más frecuentes que las sesiones que terminan
solas? Si lo fueran, 022 estaría rompiendo el caso común para arreglar el raro.

**No se puede responder con lo disponible.** El journal de mclaren es persistente
(`/var/log/journal` existe, 87.3M) pero `journalctl --list-boots` devuelve **un
solo boot**, desde `2026-07-18 13:56:33`: no hay historia anterior. En esa ventana
de ~2 días hubo 4 paradas iniciadas por systemd y 0 salidas propias, muestra
demasiado chica para concluir.

**Pero el hallazgo de R2 vuelve la pregunta irrelevante para el diseño.** Importaba
solo mientras hubiera que *elegir* qué caso romper. Con un discriminador real los
dos casos se atienden correctamente y no hay compensación que hacer. Se deja
registrada como no medida en vez de fingir que se cerró.

Medirla exigiría instrumentación hacia adelante (contar decisiones en el estado del
agente). Se propone como subproducto natural de FR-007: si cada arranque registra
causa y decisión, el conteo sale solo con el tiempo. No se agrega instrumentación
dedicada.

---

## R5 · Qué hacer en un reinicio del host

Un apagado del sistema es una parada iniciada por systemd, así que por R2 cae en
`ExecStop` con `EXIT_CODE` vacío ⇒ **conservar**. Es coherente con lo que 022 midió
DOS veces en hardware: la reutilización del proveedor restauraba el mismo enlace,
y por eso "limpiar siempre al boot" se descartó allí como regresión.

**No medido**: si esa restauración sigue valiendo tras un apagado largo (horas). No
se reinició mclaren para comprobarlo — es el agente de producción del operador y el
gate de hardware puede cubrirlo cuando toque un reinicio real. Riesgo residual
declarado: conservar un puntero cuya sesión expiró del lado del servidor reproduce
el síntoma original de 022. Mitigación disponible si aparece: acotar la
conservación por antigüedad. **No se implementa ahora** — sería diseño sobre un
caso no medido, exactamente el error que originó esta feature.

---

## R6 · Por qué la suite no lo vio, y qué se puede y no se puede cubrir en el host

`bats tests/` da 1159 ok / 0 not ok bajo bash 5.3.15 y 3.2.57.
`tests/session-pointer.bats` y `tests/local-session-hooks.bats` cubren esta lib,
y aun así el defecto pasó.

**Causa**: todos los tests alimentan el marcador con valores que el propio test
elige (`tests/local-session-hooks.bats:70` y `tests/agentctl-local.bats:634`
construyen el JSON a mano). Ninguno ejercita qué entrega systemd de verdad. El
test verificaba que la regla implementa lo que el autor creía, no que lo que el
autor creía fuera cierto.

**Lo que SÍ se puede cubrir en el host**: la tabla de decisión de R3 completa,
alimentada con los valores **medidos** en R2 en vez de inventados. Ese es el
cambio de fondo — los fixtures dejan de ser suposiciones y pasan a ser mediciones.

**Lo que NO se puede cubrir en el host**: que systemd entregue esos valores. La
suite corre en macOS, donde no hay systemd. Esa parte solo la cubre el gate de
hardware, y FR-011 obliga a decirlo en la documentación en vez de dejar que el
verde de la suite sugiera una cobertura que no existe.

---

## R7 · Superficie de cambio

Verificado por lectura directa, no inferido:

- `scripts/lib/session_pointer.sh` — `session_decide()` (`:212-224`) es la regla a
  cambiar. `session_exit_marker_write()` (`:129-147`) ya persiste los tres campos.
  `_session_marker_field()` (`:150-152`) y `_session_marker_has_field()`
  (`:157-159`) hoy solo saben leer `exit_code`.
- `modules/systemd-remote-control.service.tpl` — tiene `ExecStartPre` ×2 (`:25`,
  `:33`), `ExecStart` (`:38`) y `ExecStopPost` (`:44`). **No tiene `ExecStop`**:
  hay que agregarlo.
- `modules/local-session-exit.sh.tpl` — el hook de `ExecStopPost`.
- `modules/local-session-check.sh.tpl` — el hook de `ExecStartPre`.
- Falta una plantilla nueva para el hook de `ExecStop`.
- `scripts/agentctl` — el diagnóstico local (FR-008).
- `tests/session-pointer.bats`, `tests/local-session-hooks.bats`,
  `tests/agentctl-local.bats` — cobertura.

**`session_pointer.sh` NO está espejado a `docker/`** (verificado: no existe
`docker/scripts/lib/session_pointer.sh`). El modo contenedor no participa →
DOCKER_E2E fuera de alcance, FR-012 se cumple por construcción.

---

## R8 · Reproducibilidad de la medición (SC-005)

Las dos sondas quedan en el scratchpad de la sesión y son reproducibles en
cualquier host con systemd de usuario:

```bash
# unidad de usuario desechable; no requiere sudo ni toca el agente
sh run-probe.sh       # matriz de 5 casos, una pasada
sh confirm-probe.sh   # A-E ×3 repeticiones, incluye Restart=always
```

Ambas se limpian solas (`systemctl --user stop`, borran la unit, `daemon-reload`).
Contrato de la medición y salidas exactas: ver
[contracts/session-stop-classification.md](./contracts/session-stop-classification.md).
