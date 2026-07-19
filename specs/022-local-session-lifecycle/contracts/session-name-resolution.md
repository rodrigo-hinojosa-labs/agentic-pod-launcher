# Contract: session-name resolution (US3)

**Feature**: 022-local-session-lifecycle · **Requisitos**: FR-008, FR-009, FR-012,
FR-015 · **Criterio medible**: SC-006

Alcance: el nombre que el agente presenta al cliente (`claude remote-control --name
<valor>`). Es **solo modo local** — la unit que lo lleva
(`modules/systemd-remote-control.service.tpl`) se selecciona únicamente cuando
`deployment.mode = local`, y eso ocurre en **`install_service`**
(`setup.sh:2372-2380`: rama `else` → `tpl="$modules_dir/systemd-remote-control.service.tpl"`).
La otra rama de modo, `setup.sh:2223` dentro de `regenerate()`, NO renderiza la unit —
renderiza las piezas del lado workspace (`remote-control.env`, `agent-login.sh`,
`agent-killswitch.sh`, `agent-healthcheck.sh`…). La distinción importa para el
cinturón de seguridad de §2. Docker no tiene `--name` en ninguna parte (ver §7).

Hoy el valor se compone en la plantilla como `{{HOST_NAME}}-{{AGENT_NAME}}`
(`modules/systemd-remote-control.service.tpl:26`), con `HOST_NAME="$(hostname)"`
resuelto en tiempo de render (`setup.sh:2335`). No sale de `agent.yml`, así que no es
configurable y no sobrevive a un re-render — la violación de Principio I que este
contrato cierra.

---

## 1. La regla de resolución

Dos niveles: **valor explícito** (gana siempre) y **default calculado** (solo cuando
no hay valor explícito).

```text
# Nivel 1 — lectura, en tiempo de render
session_name = agent.yml .deployment.session_name
if session_name no vacío:
    usar VERBATIM. Fin. No se normaliza, no se deduplica, no se valida el contenido.

# Nivel 2 — default, calculado UNA vez y persistido a agent.yml (§2)
_resolve_session_name(agent_name, host):
    host_seg = host
    host_seg = porción anterior al primer '.'        # "mclaren.local" -> "mclaren"
    host_seg = lowercase(host_seg)
    host_seg = reemplazar ' ' por '-'
    host_seg = colapsar corridas de '-'
    host_seg = recortar '-' inicial y final
    # (las cuatro líneas anteriores = normalize_agent_name,
    #  scripts/lib/wizard-validators.sh:100-108, aplicada al segmento de host)

    if host_seg == "":                       return agent_name
    if agent_name == host_seg:               return agent_name
    if agent_name empieza con host_seg+"-":  return agent_name
    return host_seg + "-" + agent_name
```

**Decisiones fijadas por este contrato** (la regla del brief dice "si el `agent_name`
YA empieza con el segmento del host"; aquí se precisa qué significa exactamente):

| Punto | Decisión | Por qué |
|---|---|---|
| Fuente del host | `.deployment.host` de `agent.yml`, **no** `$(hostname)` en vivo | Principio I / FR-012: el nombre debe reproducirse re-renderizando desde `agent.yml`. Hoy depende del hostname vivo, así que mover el workspace de máquina cambia la identidad en silencio (registrado en research.md R7). `deployment.host` por defecto **ya es** `$(hostname)` (`setup.sh:520`), editable en el menú de revisión (`setup.sh:1019`). |
| "Segmento" del host | La primera etiqueta separada por puntos | Un FQDN o un `.local` de mDNS produciría `mclaren.local-mclaren-admin` y además rompería la comparación de prefijo. |
| Prueba de prefijo | Con guion de frontera (`host_seg + "-"`), más el caso de igualdad exacta | Un prefijo desnudo haría que host `rpi5` + agente `rpi5x` resolviera a `rpi5x`, un falso positivo. La igualdad exacta cubre agente `mclaren` en host `mclaren` → `mclaren`, no `mclaren-mclaren`. |
| Sin rama de compatibilidad | Un workspace pre-022 resuelve **igual** que uno nuevo | FR-015. El cambio de identidad de una vez en el cliente es aceptado y va en las notas de upgrade. |

**El `agent_name` nunca necesita normalizarse aquí**: `normalize_agent_name`
(`scripts/lib/wizard-validators.sh:100-108`) más `validate_agent_name`
(`:77-92`) garantizan que `agent.name` ya es minúsculas / dígitos / guiones sin
guiones dobles. El validador son **tres** chequeos, no uno: largo 1..63 (`:79-82`),
`^[a-z0-9][a-z0-9-]*[a-z0-9]$` **o** `^[a-z0-9]$` para el nombre de un solo carácter
(`:83-86`), y un rechazo aparte de `--` (`:87-89`). El host es el único insumo sucio.

**Trampa de lectura del host** (`yq`): un `.deployment.host` **ausente** hace que
`yq -r '.deployment.host'` imprima la cadena literal `null`, no vacío — leerlo así
resolvería `null-locbot`, no C8. El backfill y el cinturón deben leer
`yq -r '.deployment.host // ""'` y, por cinturón, tratar `null` como vacío. Es la
misma distinción absent-vs-empty que `scripts/lib/schema.sh:87-91` documenta para
`_schema_get`.

---

## 2. Dónde se calcula, dónde se persiste, y por qué

| Momento | Sitio | Qué hace |
|---|---|---|
| Scaffold nuevo | Heredoc del wizard, `setup.sh:1149-1154` | Escribe `session_name: "$(_resolve_session_name "$agent_name" "$deploy_host")"` dentro del bloque `deployment:`. Mismo patrón que la línea vecina `claude_cli: "$(detect_claude_cli)"` (`setup.sh:1153`). |
| Workspace pre-022 | Backfill en `regenerate()`, bloque hermano al de `deployment.mode` (`setup.sh:1953-1961`) | Si `.deployment.session_name` está ausente o `null`, `yq -i` escribe el default. **Dos restricciones de ubicación**: (a) dentro del `if [ -f "$agent_yml" ]` que cierra en `setup.sh:1962`, como todos los demás backfills; (b) antes de `render_load_context "$agent_yml"` (`setup.sh:1965`), o el valor no llega a la misma pasada de `--regenerate`. |
| Cinturón de seguridad | **Dentro de `_export_local_context` (`setup.sh:2331-2350`)**, único punto correcto | Si `DEPLOYMENT_SESSION_NAME` llegara vacío, rellenarlo con el default antes de renderizar. Es el único choke point porque `_export_local_context` se invoca desde **ambos** caminos que rinden artefactos locales: `regenerate()` (`setup.sh:2224`) e `install_service()` (`setup.sh:2375`) — y es `install_service` quien renderiza la unit. Ponerlo junto a `_persist_claude_cli` (`setup.sh:2231`) **no sirve**: esa línea vive solo en `regenerate()`, así que un `./setup.sh` que instale la unit sin pasar por ahí saltaría el cinturón. Ver el peligro en §4 #7 y N7. |
| Lectura en render | `render_load_context` aplana `.deployment.session_name` → `$DEPLOYMENT_SESSION_NAME` (`scripts/lib/render.sh:30-31`) | Convención `section.key → $SECTION_KEY` ya existente. Sin cambios en el motor. |

**Por qué se persiste y no se calcula en cada render (Principio I)**: si el valor solo
viviera en una función de `setup.sh`, `agent.yml` dejaría de ser la fuente de verdad
del nombre y FR-008 ("configurable desde el archivo de configuración") quedaría sin
cumplir. Persistirlo hace que (a) el operador pueda editarlo a mano en `agent.yml` y
que el edit sobreviva a `--regenerate`, (b) el nombre no dependa del hostname vivo de
la máquina donde corre el render, y (c) el default se congele una sola vez, de modo
que renombrar el host después no cambie la identidad del agente por sorpresa.

**Sin prompt nuevo en el wizard** (decisión de research.md R7): el default se calcula y
se persiste, así que no hay nada que preguntar. Añadir un prompt dispararía la cascada
de tres archivos (`tests/helper.bash:131-138` `wizard_answers`, el arreglo hecho a mano
de `tests/e2e-smoke.bats`, y la paridad de tokens ES/EN de los quickstarts que
`tests/quickstart-doc.bats:49-65` verifica). FR-008 pide editable en `agent.yml`, no
preguntable.

---

## 3. Tabla de casos

`host_seg` = primera etiqueta del host, normalizada.

| # | `.deployment.session_name` | `agent.name` | `.deployment.host` | `host_seg` | Rama | Resultado |
|---|---|---|---|---|---|---|
| C1 | (ausente) | `mclaren-admin` | `mclaren` | `mclaren` | empieza con `mclaren-` | `mclaren-admin` |
| C2 | (ausente) | `locbot` | `rpi5` | `rpi5` | ninguna coincide | `rpi5-locbot` |
| C3 | (ausente) | `rpi5-bot` | `rpi5` | `rpi5` | empieza con `rpi5-` | `rpi5-bot` |
| C4 | `bitacora` | `mclaren-admin` | `mclaren` | — | explícito | `bitacora` (verbatim; el default no se calcula) |
| C5 | `Bitácora Cenco` | cualquiera | cualquiera | — | explícito | `Bitácora Cenco` verbatim — **exige comillas en la plantilla**, ver N6 |
| C6 | (ausente) | `locbot` | `My Pi.local` | `my-pi` | ninguna coincide | `my-pi-locbot` |
| C7 | (ausente) | `mclaren` | `mclaren` | `mclaren` | igualdad exacta | `mclaren` |
| C8 | (ausente) | `locbot` | `""` / ausente | `""` | host vacío | `locbot` (ojo con la trampa `null` de yq, §1) |
| C9 | (ausente; workspace pre-022) | `mclaren-admin` | `mclaren` | `mclaren` | backfill → C1 | `mclaren-admin` — **idéntico a un scaffold nuevo** (FR-015) |
| C10 | `""` (presente pero vacío) | — | — | — | error de esquema | `agent_yml_validate` falla: *".deployment.session_name, if set, must be a non-empty string"* (`scripts/lib/schema.sh:160-164`) |

C9 es el caso que cambia la identidad visible una sola vez en el agente ya desplegado:
`mclaren-mclaren-admin` → `mclaren-admin`. Aceptado en las Clarifications de la spec y
ya aplicado a mano por el operador en mclaren.

---

## 4. Archivos exactos a tocar

Todas las líneas verificadas leyendo el archivo en `022-local-session-lifecycle`
(base `origin/main` = `7e50c44`, tras PR #79 — ojo: un `main` local sin `fetch`
puede seguir en `dbe8274`). Corrige y precisa el mapa de research.md R7 donde
correspondía (ver §8).

### Núcleo (5)

| # | Archivo:línea | Cambio |
|---|---|---|
| 1 | `setup.sh:1149-1154` | Bloque `deployment:` del heredoc: añadir `session_name: "$(_resolve_session_name "$agent_name" "$deploy_host")"` tras `mode: "$deploy_mode"` (`:1154`). Además, **función nueva** `_resolve_session_name` junto a `detect_claude_cli` (`setup.sh:114-118`) / `_persist_claude_cli` (`setup.sh:124-132`), que es donde viven sus hermanas y donde `tests/claude-cli-resolution.bats:18` demuestra que una función de `setup.sh` se puede sourcear y testear aislada (`main()` está guardado tras `BASH_SOURCE`). |
| 2 | `setup.sh:1953-1961` | Backfill dentro de `regenerate()` (la función arranca en `:1900`): bloque hermano al de `deployment.mode`, leyendo `.deployment.host` y `.agent.name` con `yq` (con `// ""`, §1) y escribiendo el default si falta. Dentro del `if [ -f "$agent_yml" ]` (cierra en `:1962`) y antes de `render_load_context` (`:1965`). |
| 3 | `scripts/lib/schema.sh:78-85` | Añadir `'.deployment.session_name'` a `_SCHEMA_OPTIONAL_NONEMPTY`. Consumido en `:160-164`: `null` → se salta, presente y vacío → error. Da C10 gratis. |
| 4 | `modules/systemd-remote-control.service.tpl:26` | `--name {{HOST_NAME}}-{{AGENT_NAME}}` → `--name "{{DEPLOYMENT_SESSION_NAME}}"`. Con esto `{{HOST_NAME}}` **desaparece de todo `modules/`** (era su único uso; ver §7). **La forma entrecomillada es la normativa** — `contracts/session-pointer-hygiene.md:250` y `:365` muestran la variante SIN comillas; esas dos líneas del contrato hermano quedan desactualizadas y hay que corregirlas (razón en N6 y §8.1). |
| 5 | `tests/fixtures/sample-agent-with-vault.yml:14-19` | Añadir `session_name: "testhost-dockbot"` al bloque `deployment:`. **Obligatorio**: `tests/schema.bats:52-105` exige que todo `{{VAR}}` de `modules/*.tpl` lo produzca `render_load_context` con esta fixture. Riesgo docker (FR-011) descartado por lectura: la fixture solo la consumen `tests/schema.bats` y `tests/mcp-json.bats`, y `DEPLOYMENT_SESSION_NAME` no aparece en ninguna plantilla docker; el test de claves de nivel superior compara solo raíces, no sub-claves de `deployment`. |

Sobre el #5: la alternativa sería añadir `DEPLOYMENT_SESSION_NAME` a `known_external`
(`tests/schema.bats:62-72`). **Se rechaza**: ese arreglo está reservado para variables
que se calculan fuera de `agent.yml` (`OPERATOR_USER`, `HOST_NAME`, `CLAUDE_BIN`…), y
este campo es precisamente lo contrario — nativo de `agent.yml`. Meterlo ahí escondería
la regresión que el test existe para cazar.

### Tests de plantilla (2)

| # | Archivo:línea | Cambio |
|---|---|---|
| 6 | `tests/local-render.bats:26-31` (bloque `deployment:` de la fixture inline) + `:65` + `:83` | La fixture gana `session_name`. `:65` asserta la línea `ExecStart` **exacta y anclada** — se rompe a propósito (Principio: actualizar, no rodear). `:83` (`grep -q -- '--name'`) sigue pasando sin cambios. `:52` (`export HOST_NAME="rpi5"`) queda inerte; puede quedarse. |
| 7 | `tests/local-install-service.bats:32-37` (bloque `deployment:` de la fixture inline) | La fixture gana `session_name`. **Sin esto el test de `diff` byte a byte de `:113-126` se pone rojo**, y por un mecanismo silencioso: ese test renderiza `expected.unit` (`:121`) *antes* de correr `--regenerate` (`:123`) y comparar con `diff` (`:125`), con un `render_load_context` sobre un `agent.yml` que aún no tiene el campo; `_render_placeholders` (`scripts/lib/render.sh:135-142`, sustitución en `:139`) reemplaza un `{{VAR}}` no definido por **cadena vacía**, no por el literal, así que `expected.unit` sale con `--name ""` mientras la unit instalada ya trae el valor del backfill. |

### Coherencia (3)

| # | Archivo:línea | Cambio |
|---|---|---|
| 8 | `modules/local-killswitch.sh.tpl:37` | Segunda composición de identidad. Ver §5. |
| 9 | `modules/next-steps.es.tpl:426` | Prosa `identidad \`<hostname>-{{AGENT_NAME}}\`` → `identidad \`{{DEPLOYMENT_SESSION_NAME}}\``. |
| 10 | `modules/next-steps.en.tpl:418` | Ídem en inglés. |

Sobre 9/10: `render_next_steps` (`setup.sh:1371`) llama a
`render_load_context "$dest/agent.yml"` (`setup.sh:1400`) antes de renderizar la
plantilla, así que en un **scaffold nuevo** el valor está disponible (el heredoc ya lo
escribió).

**Corrección respecto de una lectura previa: `--regenerate` NO refresca
`NEXT_STEPS.md`.** `render_next_steps` tiene **un solo** call site —`setup.sh:1255`,
dentro de `run_wizard` (que arranca en `:428`) y además gateado por
`[ "$IN_PLACE" != true ]`. `regenerate()` no lo invoca en ninguna parte (verificado con
`grep -n 'render_next_steps' setup.sh`: solo `:1255` como llamada, más la definición en
`:1371` y dos menciones en comentarios). Consecuencia operativa que hay que escribir en
las notas de upgrade: los cambios 9/10 alcanzan **solo a scaffolds nuevos**; un
workspace ya desplegado conserva la prosa `<hostname>-<agent>` en su `NEXT_STEPS.md`
hasta que se re-scaffoldee. Es cosmético (prosa de un doc), no funcional, pero no debe
venderse como cubierto por `--regenerate`.

Los cuatro tests de NEXT_STEPS de `tests/scaffold.bats:208-246` (`:208`, `:219`, `:228`,
`:237`) no tocan la línea de identidad — verificado leyéndolos — así que no se rompen.
El de byte-identity docker (`:237-245`) exporta a mano su contexto y no incluirá
`DEPLOYMENT_SESSION_NAME`, con lo que esa línea le renderizará vacía: inocuo para sus
dos aserciones, que solo miran strings de QMD.

### Lo que NO hay que tocar (contra el mapa del plan)

- **`tests/schema.bats` no necesita edición** (salvo el test nuevo de N9, que es
  aditivo). El plan lo lista como CHANGED; verificado leyendo el test: el bucle de
  `:90-95` itera los placeholders de las plantillas y salta los de `known_external`;
  con la fixture actualizada (#5) el nuevo placeholder queda cubierto. Y el test de
  claves de nivel superior (`:21-36`) solo compara claves raíz — las sub-claves de
  `deployment` no se asertan en ninguna parte (solo las de `.vault`, en `:38-50`). Lo
  que cambia es la **fixture**, no los tests existentes.
- `setup.sh:2335` (`HOST_NAME="$(hostname)"`) y `tests/local-render.bats:52` /
  `tests/local-install-service.bats:119` pueden quedarse: tras el cambio #4 la variable
  queda sin consumidores en `modules/`, pero exportarla es inocuo y quitarla obligaría a
  tocar tres archivos más sin ganancia. `tests/schema.bats:63` la seguirá listando en
  `known_external`; una entrada de más en esa lista no falla nada (es una lista de
  exclusión, no una igualdad).

---

## 5. El segundo sitio de composición de identidad

`modules/local-killswitch.sh.tpl:37`:

```bash
echo "(session identity: $(hostname)-${AGENT_NAME})."
```

Es una composición **independiente** de la de la unit: recalcula la identidad con el
`hostname` **en tiempo de ejecución del kill switch**, no con el valor que la unit
realmente lleva. Hoy coincide por accidente (ambas usan `hostname` + `agent_name`); en
cuanto el nombre sea configurable, este `echo` imprimiría una identidad **falsa** —
justo la que el operador usaría para buscar el agente en claude.ai/code y apagarlo.

**Qué hacer**: renderizar el valor real, igual que hace la plantilla con el resto.

```bash
# cerca de :10, junto a AGENT_NAME="{{AGENT_NAME}}"
SESSION_NAME="{{DEPLOYMENT_SESSION_NAME}}"
...
# :37
echo "(session identity: ${SESSION_NAME})."
```

Notas de implementación verificadas: la plantilla ya usa ese patrón —
`AGENT_NAME="{{AGENT_NAME}}"` en `:10`, consumido como variable de shell en `:11`
(`UNIT="agent-${AGENT_NAME}.service"`). El archivo corre con `set -euo pipefail`
(`:8`), así que asignar un literal interpolado en render es seguro. El nombre de la
unit (`agent-<agent_name>.service`) **no** cambia: sale de `AGENT_NAME`, nunca de la
identidad de sesión.

---

## 6. Escenarios verificables (N1..N9)

| # | Dado / Cuando | Entonces | Dónde se fija |
|---|---|---|---|
| **N1** | `agent.yml` con `deployment.session_name: "bitacora"` renderiza la unit | `ExecStart=… remote-control --name "bitacora" --spawn=session --verbose`, con el valor **verbatim** | `tests/local-render.bats` (reemplaza la aserción anclada de `:65`) — SC-006 primera mitad |
| **N2** | `agent.name: mclaren-admin`, `deployment.host: mclaren`, sin `session_name` | El default resuelve `mclaren-admin`: **un solo** segmento de host, sin tartamudeo | test unitario de `_resolve_session_name` sourceando `setup.sh` (patrón `tests/claude-cli-resolution.bats:18`) — FR-009, SC-006 segunda mitad |
| **N3** | `agent.name: locbot`, `deployment.host: rpi5`, sin `session_name` | Resuelve `rpi5-locbot` | mismo test unitario |
| **N4** | `agent.name: rpi5-bot`, `deployment.host: rpi5`, sin `session_name` | Resuelve `rpi5-bot` (no `rpi5-rpi5-bot`) | mismo test unitario |
| **N5** | `deployment.host: "My Pi.local"`, agente `locbot` | Resuelve `my-pi-locbot`: se toma la primera etiqueta y se normaliza | mismo test unitario |
| **N6** | `session_name` con espacios (`"Bitácora Cenco"`) renderiza la unit | El valor queda como **un solo argumento** de `ExecStart` — la plantilla lo entrecomilla | `tests/local-render.bats`: asertar que la línea contiene `--name "Bitácora Cenco"`. Ver §8 (derivación, no medición). |
| **N7a** | Se renderiza la unit **con** la fixture ya portando `session_name` | El `ExecStart` renderizado nunca queda con un `--name` colgando: guarda de regresión contra un futuro rename del campo o un typo del placeholder | `tests/local-render.bats`, aserción negativa **colocada al final**, estilo `if … grep -q …; then false; fi` (`tests/agentctl-local.bats:406-407`) — **no** `! [[ … ]]` ni `! … \| grep …`, que no fallan el test en esta suite (ejemplos muertos vivos hoy: `tests/agentctl-local.bats:120,148,206,274`) |
| **N7b** | `setup.sh` renderiza artefactos locales con `DEPLOYMENT_SESSION_NAME` vacío en el entorno | El cinturón de `_export_local_context` lo rellena con el default **antes** de renderizar, así que la unit emitida trae un valor no vacío | Test que **sourcea `setup.sh`** (patrón `tests/claude-cli-resolution.bats:18`) o el camino completo de `tests/local-install-service.bats` |
| **N8** | Un `agent.yml` **pre-022** (sin el campo) pasa por `./setup.sh --regenerate` | (a) `agent.yml` gana `deployment.session_name` con el default; (b) la unit **instalada** lleva ese mismo valor; (c) un segundo `--regenerate` no cambia nada (idempotente) | `tests/local-install-service.bats` con el seam `SETUP_SYSTEMD_DIR` (`:84-85`) — FR-012, FR-015 |
| **N9** | `deployment.session_name: ""` | `agent_yml_validate` falla con *"…if set, must be a non-empty string"* | `tests/schema.bats` (patrón de los demás `_SCHEMA_OPTIONAL_NONEMPTY`) |

**Por qué N7 se parte en dos** (y por qué la versión anterior de este contrato era
inejecutable): la plantilla **no puede** defenderse sola. `_render_placeholders`
sustituye un `{{VAR}}` no definido por cadena vacía (`scripts/lib/render.sh:139`), de
modo que un `render_to_file` desnudo con `DEPLOYMENT_SESSION_NAME` fuera del entorno
produce exactamente `--name ""` — el escenario que se pretendía prohibir. `setup()` de
`tests/local-render.bats` (`:8-54`) no sourcea `setup.sh`: solo carga `render`/`yaml` y
exporta `OPERATOR_USER`/`OPERATOR_HOME`/`HOST_NAME`/`CLAUDE_BIN`. Por lo tanto el
cinturón **solo** es observable donde vive, en `setup.sh`. Es la misma mecánica que ya
explica el ítem #7 de §4.

**Principio III (host-runnable)**: N1..N9 se ejecutan sin systemd real. N1/N6/N7a son
aserciones de texto sobre un archivo renderizado; N2..N5 y N7b sourcean `setup.sh`;
N8 usa el seam `SETUP_SYSTEMD_DIR` con `sudo`/`systemctl`/`claude` stubbeados
(`tests/local-install-service.bats:60-85`); N9 es `agent_yml_validate` puro. Ningún
escenario de este contrato requiere el gate de hardware — lo que sí lo requiere es la
confirmación de §8.1.

Los cuatro invariantes de 021 sobre esta misma unit (prefijo `-` en el `.env`, orden de
`EnvironmentFile`, `ExecStartPre` con `-`, ausencia de `Environment=`) siguen fijados
por `tests/local-render.bats:101-128` y `tests/local-install-service.bats:130-140`, y
este cambio no los toca — FR-010. (El bloque U4 de `tests/local-render.bats:130-153` es
otra cosa: prueba que las units **auxiliares** no cargan ningún `EnvironmentFile`, y
tampoco se ve afectado.)

---

## 7. Qué NO cambia

`--name` es **solo la etiqueta visible en claude.ai/code**. Verificado por grep, no
inferido:

```console
$ grep -rn -- '--name ' modules/ scripts/ docker/ setup.sh tests/
modules/systemd-remote-control.service.tpl:26:ExecStart={{CLAUDE_BIN}} remote-control --name {{HOST_NAME}}-{{AGENT_NAME}} --spawn=session --verbose
scripts/lib/qmd_index.sh:17:#   qmd collection add <path> --name <n> [--mask '**/*.md']   # index a folder
scripts/lib/qmd_index.sh:379:    if ! _qmd_run "$pkg" collection add "$vault_dir" --name "$coll" --mask '**/*.md' >"$slog" 2>&1; then
tests/local-render.bats:65:  grep -q '^ExecStart=/usr/local/bin/claude remote-control --name rpi5-locbot --spawn=session --verbose$' …
```

Los dos hits de `qmd_index.sh` son el `--name` de una colección de QMD, sin relación.

```console
$ grep -rn 'HOST_NAME' modules/ scripts/ tests/ setup.sh docker/
modules/systemd-remote-control.service.tpl:26   # el único uso en una plantilla
tests/schema.bats:60,63                         # comentario + known_external
tests/local-install-service.bats:119            # export en el test
tests/local-render.bats:52                      # export en el test
setup.sh:2332,2335                              # _export_local_context
docker/scripts/write_container_info.sh:27,29,61,62,68,85   # docker: lee .deployment.host, NO --name
```

En consecuencia, **nada** deriva de `--name`:

| Superficie | De dónde saca su identidad | Efecto de US3 |
|---|---|---|
| Nombre de la unit systemd | `agent-${AGENT_NAME}.service` — `modules/local-killswitch.sh.tpl:11`, `modules/local-login.sh.tpl:10`, `modules/local-healthcheck.sh.tpl:10` | Ninguno |
| Units auxiliares (healthcheck, qmd-reindex, qmd-watch, vault-backup, wiki-graph) | `agent-${AGENT_NAME}-<sufijo>` — `local-login.sh.tpl:124-125,144-146,168-169,186-187`, `local-healthcheck.sh.tpl:71,82` | Ninguno |
| Healthcheck | `UNIT="agent-${AGENT_NAME}.service"` (`local-healthcheck.sh.tpl:10`); su salida usa `agent-${AGENT_NAME}` (`:104`) | Ninguno |
| Doctor local | `unit="agent-${agent}.service"` desde `resolve_agent_name` (`scripts/agentctl:1260-1261`) | Ninguno |
| Modo docker | `docker/scripts/write_container_info.sh:29` lee `.deployment.host` de `agent.yml`; no existe `remote-control --name` en `docker/` | Byte-idéntico (FR-011) |
| Nombres de rama del fork | `deploy_host` en minúsculas (`setup.sh:586-587`), no la identidad de sesión | Ninguno |

Eso es lo que hace a US3 de bajo riesgo: cambia una etiqueta, no una clave.

---

## 8. Afirmaciones NO verificadas contra hardware

Se listan aparte para que nadie las tome por medidas.

1. **Comillas en `ExecStart` (N6, caso C5)**: que systemd trate `--name "Bitácora
   Cenco"` como un solo argumento y despoje las comillas es lo que documenta
   `systemd.service(5)` (reglas de entrecomillado de la línea de comandos). **No lo
   medí en este host** — no hay systemd en el entorno de trabajo. La versión sin
   comillas es demostrablemente peligrosa (un valor con espacios se parte en varios
   argv y `--spawn=session` acabaría siendo el valor de `--name`), así que el contrato
   exige la forma entrecomillada; el gate de hardware en mclaren debe confirmar con
   `systemctl show agent-<name>.service -p ExecStart` que el argumento llega entero.
2. **Comportamiento del cliente ante el cambio de nombre** (C9): que claude.ai/code
   muestre el agente bajo la nueva etiqueta tras el restart es lo que la spec asume
   (Clarifications, "el operador ya lo absorbió a mano en el agente vivo"). No lo
   observé yo.
3. **`_resolve_session_name` no existe todavía** en el código: `grep -rn
   'session_name\|SESSION_NAME'` sobre el repo (excluyendo `specs/`) no devuelve nada.
   Todo lo de §2 es diseño a implementar, no lectura de código existente. Lo que sí está
   verificado es cada sitio de anclaje (líneas, funciones contenedoras y orden de
   ejecución).
4. **Especificadores `%` de systemd**: §1 dice que el valor explícito se usa *verbatim,
   sin validar contenido*. En una línea `ExecStart`, systemd expande especificadores
   `%X` (`%h`, `%i`, `%n`…) y el escape es `%%`. Un `session_name` con `%` produciría
   una identidad distinta de la escrita en `agent.yml`, en silencio. **No lo medí** (no
   hay systemd en este entorno) y no es un caso realista para un nombre de agente, así
   que este contrato NO añade escaping — se registra como límite conocido del
   "verbatim", junto al caso de las comillas del punto 1. Si alguna vez se valida el
   contenido, empezar por aquí.
5. **Fuente del host = `deployment.host`**: es una decisión de este contrato, y cambia
   sutilmente el comportamiento actual respecto de `$(hostname)` para un workspace cuyo
   operador editó el host en el menú de revisión (`setup.sh:1019`). En mclaren ambos
   coinciden (`deploy_host=$(hostname)` por defecto, `setup.sh:520`), así que el default
   allí sale igual por cualquiera de las dos vías — pero no lo comprobé leyendo el
   `agent.yml` de mclaren.
