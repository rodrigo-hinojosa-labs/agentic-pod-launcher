# Research — 023-fix-render-ampersand (Fase 0)

Todo lo de aquí fue **medido**, con el comando y el resultado. Donde no medí, lo digo.
Banco de pruebas: cuatro candidatos × nueve valores × tres versiones de bash.

---

## R1 — La causa exacta

`scripts/lib/render.sh:90,95`:

```bash
row_expanded="${row_expanded//\{\{${field}\}\}/$fval}"
row_expanded="${row_expanded//\{\{${field_upper}\}\}/$fval_upper}"
```

Bash 5.2 introdujo compatibilidad con ksh93 en la sustitución de patrones: un `&` sin
escapar en el **reemplazo** se expande al texto que hizo match. `$fval` viene de
`agent.yml`, o sea es dato del operador, y nunca se trata como literal.

Las **dos** líneas están afectadas — la de minúsculas y la de mayúsculas. Arreglar solo
una dejaría el bug vivo por la otra mitad (FR-003).

## R2 — Alcance de versiones: medido en tres bash

| bash | dónde | valor `A&B` sobre `ref={{u}}!` |
|---|---|---|
| 3.2.57 | `/bin/bash`, macOS de stock | `ref=A&B!` — correcto |
| 5.2.37 | **mclaren**, host de agente en producción | `ref=A{{u}}B!` — **corrupto** |
| 5.3.15 | Homebrew, el que resuelve `env bash` | `ref=A{{u}}B!` — **corrupto** |

**El bug está vivo en producción.** No es un artefacto del entorno de desarrollo.

## R3 — Los cuatro candidatos, medidos

Nueve valores: `A&B`, `&`, `&&`, `\&`, `a&`, `&a`, `?a=1&b=2&ref=$1&v=\1`, `x{{y}}z`, y el
vacío. Un candidato "pasa" solo si los nueve salen idénticos a la entrada, en las tres
versiones.

| Candidato | 3.2.57 | 5.2.37 | 5.3.15 | Veredicto |
|---|---|---|---|---|
| (a) actual `${t//$p/$v}` | pasa | **falla 6/9** | **falla 6/9** | es el bug |
| (b) escapar `&` en el valor | **falla 7/9** | **falla 1/9** | **falla 1/9** | **descartado** |
| (c) `BASH_COMPAT=5.1` / `shopt -s compat51` | — | — | **no aplica** | **descartado** |
| (d) perl con `ENV{REPL}` + `/e` | pasa | pasa | pasa | viable |
| (e) recorrido con prefijo/sufijo, bash puro | pasa | pasa | pasa | **elegido** |

### Por qué (b) está descartado — la trampa se confirmó midiendo

La intuición dice "escapa el `&` y listo". Es **portátil al revés**:

```
bash 3.2.57  valor=A&B  ->  ref=A\&B!     inserta un backslash literal
bash 5.3.15  valor=\&   ->  ref=\{{u}}!   rompe un & que el operador ya había escapado
```

Arregla 5.2+ y **rompe 3.2**, que hoy funciona bien. Esto estaba anotado como sospecha en
la spec; queda confirmado por medición, no por razonamiento.

### Por qué (c) está descartado

```console
$ bash -c 'shopt -s compat51'      # bash 5.3.15
shopt compat51: NO existe
$ BASH_COMPAT=5.1 bash -c '…'      # sigue corrupto
BASH_COMPAT=5.1 -> ref=A{{u}}B!
```

No existe el `shopt` en 5.3 y `BASH_COMPAT=5.1` **no** restaura el comportamiento para
este constructo. Además ataría el repo a una bandera de compatibilidad que desaparece.

## R4 — Decisión: (e), el recorrido en bash puro

```bash
# reemplaza TODAS las ocurrencias de "$p" por "$v" en "$t", sin interpretar "$v"
_render_replace_all() {
  local t="$1" p="$2" v="$3" out=""
  while [ -n "$t" ]; do
    case "$t" in
      *"$p"*) out="${out}${t%%"$p"*}${v}"; t="${t#*"$p"}" ;;
      *)      out="${out}${t}"; t="" ;;
    esac
  done
  printf '%s' "$out"
}
```

**Rationale**: es un arreglo *estructural*, no de escapado. `${t%%"$p"*}` y `${t#*"$p"}`
no tienen cadena de reemplazo, así que no hay caracteres con significado especial que
recordar escapar — ni hoy, ni cuando bash 6 agregue otro. `$v` se concatena, nunca se
interpreta.

Ventajas medidas frente a (d): cero subprocesos (200 sustituciones en 0s contra ~1s),
cero dependencias nuevas.

**Alternatives considered**: (d) perl con `ENV{REPL}` + `/e` — correcto en las tres
versiones y **consistente con el propio archivo**, que ya lo usa en `:105-110` para
sustituir el bloque completo. Se descartó como primera opción por un motivo concreto:
sigue siendo un arreglo que depende de escapar bien (`quotemeta` sobre el patrón, `/e`
sobre el reemplazo). (e) elimina la categoría entera. (d) queda como respaldo documentado
si (e) mostrara algún borde no previsto.

**No se toca `:105-110`.** Esa sustitución es correcta y su salida debe quedar
byte-idéntica (FR-005).

## R5 — El caso autorreferencial

Un valor que **contiene el propio placeholder** (`{{u}}` como valor de `{{u}}`) no debe
re-escanearse:

```
perl   -> [a{{u}}b]      correcto
split  -> [a{{u}}b]      correcto
```

Ambos consumen la plantilla de izquierda a derecha sin releer lo ya emitido.

## R6 — Por qué el bug vivió meses sin verse

Medido con timestamps, no inferido:

- `bats` es `#!/usr/bin/env bash` → usa el **primer bash del PATH**.
- `/opt/homebrew/Cellar/bash/5.3.15` fue creado el **2026-07-19 a las 10:38:34**. Es la
  **única** versión en el Cellar: antes no había bash de Homebrew, así que `env bash`
  resolvía a `/bin/bash` 3.2.
- El `INSTALL_RECEIPT.json` dice `installed_on_request: false` — entró como dependencia
  transitiva de otra fórmula, no por una instalación explícita.
- La corrida de la suite que terminó **10:40:04** había arrancado ~10:28, bajo 3.2 → verde.
  La que terminó **11:44:45** arrancó después de las 10:38, bajo 5.3 → roja.

O sea: **el mismo commit dio verde y rojo el mismo día en la misma máquina**, y nada en el
repo lo declaraba. Esa es la causa de fondo, y es lo que justifica la US3.

## R7 — Superficie: qué más podría estar afectado

`grep -rn '\${[a-z_]*//' scripts/lib/*.sh setup.sh scripts/agentctl` da cinco sitios. Los
otros cuatro usan reemplazos **literales** sin `&` y quedan como están:

| Sitio | Reemplazo | Riesgo |
|---|---|---|
| `render.sh:90,95` | `$fval` (dato del operador) | **este bug** |
| `schema.sh:137` | `, ` | ninguno |
| `wizard-validators.sh:103` | `-` | ninguno |
| `wiki_graph.sh:394` | `\\\"` | ninguno (sin `&`) |
| `setup.sh:161` | `-` | ninguno |

Los consumidores de `{{#each}}` son exactamente dos, ambos sobre `MCPS_ATLASSIAN`:
`modules/mcp-json.tpl:48` y `modules/env-example.tpl:14`, con campos `name`, `url`,
`email`. `env-example.tpl:15-19` escribe `{{url}}`/`{{email}}` **directo** a líneas del
`.env` generado.

## R8 — ¿Hay datos ya dañados?

- **mclaren**: `agent.yml` sin filas `.mcps.atlassian`; cero valores con `&` (solo conteo;
  no se imprimió ningún valor). **No hay remediación de datos que hacer.**
- **ferrari**: **NO medido** — el túnel SSH está caído, pendiente de re-autenticación en el
  navegador. Es la única pregunta abierta de la spec que sigue abierta. No bloquea el
  arreglo; sí debe consultarse antes de cerrar la feature.

## R9 — Piso de versiones: qué se propone

No subir el piso. El repo corre bien en 3.2 y debe seguir corriendo: es el bash de stock de
macOS y el del entorno de desarrollo del operador. Lo que cambia es **dejar de afirmar
equivalencia sin probarla**:

1. Corregir la afirmación de `CLAUDE.md` (y `README.md` si la repite): el rango sostenido
   es 3.2+, y se sostiene porque **se prueba**, no porque no se usen constructos modernos.
2. Que el resultado de la suite diga bajo qué bash se obtuvo (FR-009).
3. Un guard de no-drift que impida reintroducir `${var//…}` con reemplazo derivado de
   datos en `render.sh` — el mismo patrón de los guards `no-drift` que ya existen en la
   suite.

La matriz completa en CI (correr la suite en las dos versiones automáticamente) se deja
**fuera de alcance**: hoy no hay CI en el repo, y montarla es una feature propia. El
quickstart documenta cómo correr ambas a mano, que es lo que el gate de esta feature exige.
