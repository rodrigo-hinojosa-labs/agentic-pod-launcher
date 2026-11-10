# Contrato NF: formato del aviso (el issue)

Qué escribe `nightly-alert.sh notify` en GitHub y con qué reglas. Es lo que lee el mantenedor y lo que el script relee la noche siguiente para decidir; por eso el marcador es parte del contrato.

## 1. Constantes

| Cosa | Modo real | Modo ensayo |
|---|---|---|
| Etiqueta (identidad) | `nightly-red` (color `D93F0B`, descripción "Nightly docker-e2e en rojo (aviso automatico)") | `nightly-red-trial` (color `FBCA04`, descripción "Ensayo del aviso del nightly") |
| Título | `docker-e2e nightly en rojo` | `[ensayo] docker-e2e nightly en rojo` |
| Asignado | `ASSIGNEE` (hoy `rodrigo-hinojosa`) | el mismo |

El script solo lee y escribe issues con **la etiqueta de su modo**: un ensayo no ve el aviso real y el real no ve el de ensayo.

## 2. Marcador (primera línea del cuerpo)

```text
<!-- nightly-red:v1 state=open total=3 first=2026-10-20 -->
```

Expresión que lo reconoce: `^<!-- nightly-red:v1 state=(open|resolved) total=([0-9]{1,9}) first=([0-9]{4}-[0-9]{2}-[0-9]{2}) -->$`. El total tiene a lo sumo 9 dígitos y se lee como **decimal** (en aritmética de bash `08` es un octal inválido que mataría el script; con más dígitos el número se desbordaría en silencio): un marcador con más de 9 dígitos se trata como inválido.

- Se escribe siempre desde cero con valores del propio script (un estado, un entero y una fecha UTC), nunca con texto del log.
- `state=open`: la racha sigue (o una persona cerró el issue a mano). `state=resolved`: lo cerró el mecanismo tras un verde, o un verde posterior a un cierre manual reescribió el marcador de un issue ya cerrado (solo `edit`).
- **Marcador ausente o inválido** en el aviso más reciente (alguien editó el cuerpo): se trata como `state=open`; el script **no reescribe el cuerpo** (no destruye lo que una persona escribió), solo comenta la noche y lo reabre si estaba cerrado, y anota un `::warning::`. Limitación declarada: con un marcador inválido un verde tampoco puede marcarlo como resuelto, así que el rojo siguiente podría reabrir ese issue.

## 3. Cuerpo (abierto)

```text
<!-- nightly-red:v1 state=open total=3 first=2026-10-20 -->
# docker-e2e nightly en rojo

Racha de **3** noches programadas seguidas en rojo, desde el 20-10-2026 (UTC). Ultima: [run 38400000](https://github.com/OWNER/REPO/actions/runs/38400000).

Este aviso se cierra solo cuando una noche programada vuelve a verde. Si lo cierras a mano mientras sigue en rojo, se reabre la noche siguiente. El cuerpo se regenera cada noche: deja tus notas como comentarios.

## Ultimas noches

| Noche (UTC) | Corrida | Paso que fallo |
|---|---|---|
| 22-10-2026 | [run 38400000](https://github.com/OWNER/REPO/actions/runs/38400000) | `run_suite` |
| 21-10-2026 | [run 38300000](https://github.com/OWNER/REPO/actions/runs/38300000) | `run_suite` |
| 20-10-2026 | [run 38200000](https://github.com/OWNER/REPO/actions/runs/38200000) | `run_suite` |

## Ultima noche

- Resumen de la suite: `total=48 executed=48 skipped=0 failed=2`
- Tests que fallaron (2):

~~~text
nombre uno
nombre dos
~~~
```

- Con una sola noche la frase dice `Racha de **1** noche programada en rojo, desde el DD-MM-YYYY (UTC).` (en singular y sin "seguidas"); con dos o más, la de arriba.
- Las fechas de la tabla y de la prosa van en `DD-MM-YYYY` (texto para personas); el marcador, que es un dato, va en ISO.
- Cada fila se identifica por `[run <id>](`: repetir el id no suma la noche (idempotencia).
- Sin resumen: `- Resumen de la suite: no disponible (la corrida fallo antes de la suite o no dejo e2e.tap)`. Sin tests fallidos: `- Tests que fallaron: ninguno informado`. Sin paso fallido: `-` en la columna.

## 4. Comentarios (una línea cada uno)

| Cuándo | Texto |
|---|---|
| Noche nueva de la racha | `Noche N de la racha: [run ID](URL). Paso que fallo: PASO. Resumen: RESUMEN.` |
| Reapertura | `Se reabre: la noche sigue en rojo ([run ID](URL)). El aviso se habia cerrado a mano mientras la racha seguia.` |
| Cierre por verde | `Verde: la noche programada [run ID](URL) paso. Se cierra el aviso (racha de N noches, desde DD-MM-YYYY).` |

Los comentarios no repiten la lista de tests (ya está en el cuerpo).

## 5. Cotas (FR-003)

| Qué | Cota |
|---|---|
| Nombres de test en el cuerpo | 20; si hay más, la línea final `... y N mas`; cada nombre 120 caracteres como máximo, recortado con `...` |
| Filas de "Ultimas noches" | 10 (las más recientes; el total acumulado vive en el marcador) |
| Tamaño del cuerpo | 60.000 caracteres es el tope de GitHub. **No hay una rama que recorte filas**: el cuerpo está acotado por construcción (10 filas de unos 120 caracteres, 20 nombres de 120, la línea de resto y el texto fijo suman menos de 6.000), así que una rama que nunca se ejecuta no se escribió; N14 afirma `< 60.000` y también `< 8.000`, que es lo que sí puede romperse al cambiar una cota |

## 6. Texto inerte (FR-004)

Todo texto que viene del log (nombres de test, resumen, paso fallido) pasa por una función de saneo que:

1. quita los caracteres de control (salvo el salto de línea que separa nombres);
2. cambia las comillas invertidas y las virgulillas de cercado (`` ` `` y `~`) por apóstrofos;
3. neutraliza `<!--` y `-->` (los reemplaza por `<!-` y `->`);
4. recorta cada línea a 120 caracteres, terminando en `...`;
5. deja el texto en **ASCII imprimible**: cada byte por encima de 127 pasa a `?` (el cuerpo del aviso no lleva nunca bytes no ASCII, así que no hay codificación que verificar ni un corte de recorte que parta un carácter; el costo es que un nombre con tilde se ve con `?`).

El paso fallido se limita además a `[A-Za-z0-9_-]` (un id de paso es una palabra), `RUN_ID` queda en dígitos y `RUN_URL` en un juego de caracteres de URL sin espacios, paréntesis, corchetes ni comillas, de modo que el enlace de la corrida siga siendo uno solo.

Los nombres van **dentro de un bloque de código cercado** con `~~~text` (GitHub no menciona ni enlaza dentro de un bloque cercado, y un nombre no puede cerrarlo porque se le quitaron las virgulillas). El paso fallido y el resumen van entre comillas invertidas, también tras el saneo. El aviso no incluye variables de entorno, el token ni salida cruda del log más allá de estos campos; como el repositorio es público, solo lleva información que ya es pública.
