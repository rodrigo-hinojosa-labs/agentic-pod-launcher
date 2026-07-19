# Data model — 023-fix-render-ampersand (Fase 1)

Esta feature no introduce almacenamiento ni esquema nuevo. Lo que sí tiene es un modelo de
**confianza** sobre el texto que atraviesa el motor, y no estaba escrito en ninguna parte.
Ese vacío es la razón del bug: nadie declaró que el valor de un campo es dato no confiable.

## Entidades

### Valor de campo (`$fval`)

Texto que el operador escribe en un ítem de arreglo de `agent.yml`.

- **Origen**: `yq "${yq_path}[${i}].${field}"` — `render.sh:87`.
- **Nivel de confianza**: **no confiable**. Puede contener cualquier byte. Ningún carácter
  tiene significado para el motor: ni `&`, ni `$1`, ni `\1`, ni `{{`, ni `}}`.
- **Invariante**: sale del render exactamente como entró. Es FR-001 y SC-001.
- **Ausente**: `yq` imprime `null`; `render.sh:88` lo normaliza a cadena vacía. El
  comportamiento actual no cambia.

### Placeholder (`{{campo}}` / `{{CAMPO}}`)

Marca dentro de un bloque repetido.

- **Origen**: el nombre de la clave YAML de esa fila (`yq … | keys | .[]`, `render.sh:95`).
- **Nivel de confianza**: **derivado de la configuración**, no del operador libre — pero se
  trata como literal igual, por el mismo criterio.
- **Variantes**: minúscula (valor tal cual) y MAYÚSCULA (valor en mayúsculas). **Las dos
  usan la misma primitiva**; tratarlas distinto es lo que dejaría medio bug vivo.

### Plantilla de fila (`$row_expanded`)

El bloque entre `{{#each}}` y `{{/each}}`, expandido una vez por fila.

- **Invariante nuevo**: el texto ya sustituido **nunca se re-escanea**. Un valor que
  contenga el propio placeholder no vuelve a expandirse (medido, research R5).

### Artefacto generado

`.env` y `.mcp.json` del workspace: el destino final del valor.

- **Por qué importa el nivel de confianza**: es donde una corrupción pasa inadvertida. El
  `.env` es además el archivo de secretos, así que el bug degradaba justamente el artefacto
  más sensible del workspace.

## Reglas de validación

| Regla | Dónde se verifica |
|---|---|
| El valor sale idéntico a como entró, byte a byte | `tests/render.bats` (test dedicado al `&`) |
| Vale para `&`, `$1`, `\1`, `{{`, y sus combinaciones | casos adversariales del mismo test |
| Vale igual en minúscula y en MAYÚSCULA | un caso por variante |
| Vale igual en toda versión de bash soportada | quickstart: la suite corre en 3.2 y en 5.x |
| Un `agent.yml` sin `&` produce salida byte-idéntica a la actual | test de no-regresión |

## Transiciones de estado

Ninguna. El motor es una transformación pura de texto: misma entrada, misma salida, sin
estado persistente entre invocaciones. Esa pureza es justamente lo que hace que el bug sea
100% reproducible y que el arreglo se pueda probar de forma exhaustiva sobre una tabla de
casos.
