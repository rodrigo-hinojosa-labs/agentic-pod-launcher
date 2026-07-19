# Contract: sustitución de campos en un bloque repetido

**Feature**: 023-fix-render-ampersand · **Requisitos**: FR-001…FR-006 ·
**Criterios**: SC-001, SC-002, SC-003, SC-005, SC-006

## 1. La primitiva

```bash
# _render_replace_all TEXT PLACEHOLDER VALUE → stdout
# Reemplaza TODAS las ocurrencias de PLACEHOLDER en TEXT por VALUE.
# VALUE se concatena literalmente: ningún carácter suyo tiene significado.
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

**Por qué así y no escapando**: `${t%%"$p"*}` y `${t#*"$p"}` no tienen cadena de
reemplazo, así que no existe la categoría "carácter especial del reemplazo". No hay nada
que escapar hoy ni que recordar escapar cuando bash 6 agregue otra regla. Es un arreglo
estructural; escapar el `&` es un parche que además **rompe bash 3.2** (medido:
research.md R3).

**Nota de implementación**: las comillas en `*"$p"*`, `%%"$p"*` y `#*"$p"` son
load-bearing — hacen que el placeholder se compare como literal y no como glob. Verificado
en 3.2.57, 5.2.37 y 5.3.15.

## 2. Call sites

`scripts/lib/render.sh`, dentro del bucle de filas de `_render_each`:

| Antes | Después |
|---|---|
| `row_expanded="${row_expanded//\{\{${field}\}\}/$fval}"` | `row_expanded=$(_render_replace_all "$row_expanded" "{{${field}}}" "$fval")` |
| `row_expanded="${row_expanded//\{\{${field_upper}\}\}/$fval_upper}"` | `row_expanded=$(_render_replace_all "$row_expanded" "{{${field_upper}}}" "$fval_upper")` |

**Las dos, en la misma entrega.** Cambiar solo una deja el bug vivo por la variante en
mayúsculas (FR-003).

**Lo que NO cambia**: la sustitución del `full_match` en `render.sh:105-110` (perl con
`ENV{REPL}` y `/e`). Es correcta y su salida debe quedar byte-idéntica.

## 3. Tabla de casos (el oráculo)

Plantilla `ref={{u}}!`, placeholder `{{u}}`. Cada fila debe producir `ref=<valor>!` sin
alteración, **en toda versión de bash soportada**.

| # | Valor | Qué prueba | Hoy en 5.2+ |
|---|---|---|---|
| A1 | `A&B` | el bug base | `ref=A{{u}}B!` |
| A2 | `&` | valor formado solo por `&` | `ref={{u}}!` |
| A3 | `&&` | ocurrencias múltiples | `ref={{u}}{{u}}!` |
| A4 | `\&` | un `&` que el operador YA escapó | `ref=&!` |
| A5 | `a&` | `&` al final | `ref=a{{u}}!` |
| A6 | `&a` | `&` al principio | `ref={{u}}a!` |
| A7 | `?a=1&b=2&ref=$1&v=\1` | adversarial: `&` + `$1` + `\1` | corrupto |
| A8 | `x{{y}}z` | el valor trae otro placeholder | ok hoy |
| A9 | `` (vacío) | sin regresión | ok hoy |
| A10 | `{{u}}` | autorreferencial: NO re-escanear | ok hoy |

A4 merece atención: hoy en bash 5.2+ un `\&` se convierte en `&` — el motor **se come el
backslash** del operador. El contrato exige devolver `\&` tal cual se escribió.

## 4. Escenarios verificables

| # | Dado / Cuando | Entonces | Dónde |
|---|---|---|---|
| **E1** | Los 10 valores de §3 pasan por la primitiva | Salida idéntica a la entrada en los 10 | `tests/render.bats`, test **dedicado al `&`** (FR-006) |
| **E2** | Un `agent.yml` con `url: "https://x.example/p?a=1&b=2"` renderiza `env-example.tpl` | La línea del `.env` contiene la URL exacta | end-to-end sobre la plantilla real |
| **E3** | El mismo `agent.yml` renderiza bajo 3.2 y bajo 5.x | Salidas byte-idénticas entre sí | quickstart (manual, dos intérpretes) |
| **E4** | Un valor con `$1` y `\1` sin `&` | Se preservan literales | el test heredado de `:71`, que debe seguir verde |
| **E5** | Un `agent.yml` sin ningún `&` | `--regenerate` produce artefactos byte-idénticos a los actuales | test de no-regresión (FR-005) |
| **E6** | La variante `{{CAMPO}}` con un valor con `&` | Igual que la minúscula | caso propio, no compartido con E1 |
| **E7** | `render.sh` gana un `${var//…}` con reemplazo derivado de datos | Un test lo rechaza | guard de no-drift, estilo de los que ya existen |

**E7 es la protección de largo plazo.** Sin él, el próximo `{{#each}}` que alguien agregue
puede reintroducir el patrón exacto sin que nada avise.

## 5. Nombres de test

FR-006 pide que el rojo se explique solo. El nombre debe contener `&` y la palabra
literal — hoy el síntoma llega desde un test llamado *"preserves literal `$1` and `\1`"*,
que mandó la investigación hacia perl, que no tenía nada que ver.

Forma sugerida:

```
@test "render_template preserves a literal & in field values (bash 5.2+ ksh93 semantics)"
```

## 6. Fuera de alcance

- Las otras cuatro sustituciones `${x//…}` del repo: reemplazos literales, sin `&`
  (research R7). Se dejan.
- La sustitución del bloque completo (`:105-110`): correcta.
- Montar CI con matriz de versiones: no hay CI en el repo; es feature propia.
- Remediar datos: no hay datos dañados en mclaren (research R8). Si ferrari muestra un
  valor afectado, entra ahí y no antes.
