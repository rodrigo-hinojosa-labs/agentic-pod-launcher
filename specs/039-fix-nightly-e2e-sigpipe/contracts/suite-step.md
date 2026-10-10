# Contract: Paso de la suite del nightly

**Feature**: `039-fix-nightly-e2e-sigpipe` | **Cubre**: FR-004, FR-005, FR-006, FR-016, SC-006, SC-007, SC-009 | **Workflow**: `.github/workflows/docker-e2e.yml`, paso `Run docker-e2e suite`

Define qué hace el paso que ejecuta los e2e y cómo decide su resultado. El objetivo es que un verde signifique "se ejecutaron tests y ninguno falló", y que un rojo nombre su causa.

## 1. Entrada

- **`env:`** con `DOCKER_E2E: '1'`, exactamente esa cadena. Sin ella los 48 e2e se saltan solos (medido en M5 de [research.md](../research.md)).
- **Archivos**: `tests/docker-e2e-*.bats` (hoy 13 archivos y 48 tests).
- **Shell**: el por defecto del runner (`bash -e {0}`); el paso trae su propio `set -euo pipefail`.

## 2. Texto de referencia

El texto normativo es el del workflow; esta es su forma de referencia, de la que el oráculo extrae el `run:` real:

```bash
set -euo pipefail
rc=0
bats --print-output-on-failure --tap tests/docker-e2e-*.bats | tee e2e.tap || rc=$?
total=$(grep -c -E '^(ok|not ok) [0-9]+' e2e.tap || true)
skipped=$(grep -c -E '^ok [0-9]+ .*# skip' e2e.tap || true)
failed=$(grep -c -E '^not ok [0-9]+' e2e.tap || true)
executed=$((total - skipped))
echo "e2e summary: total=$total executed=$executed skipped=$skipped failed=$failed"
[ "$rc" -eq 0 ] || exit "$rc"
if [ "$executed" -eq 0 ]; then
  echo "::error::ningun e2e se ejecuto: todos saltados o lista vacia (revisar DOCKER_E2E, el daemon de Docker y la ruta de los tests)"
  exit 1
fi
```

**Por qué `tee`**: el log se ve en vivo durante los minutos que dura la suite y el archivo queda para contar. `tee` consume toda su entrada, así que no reintroduce el patrón que esta feature elimina. **Por qué `|| true` en los `grep -c`**: `grep -c` sale con 1 cuando el conteo es 0, y bajo `set -e` abortaría el paso antes de imprimir el resumen.

## 3. Salida

- El flujo TAP completo, en vivo. Las líneas `ok N nombre # skip motivo` quedan en el log: un salto siempre es visible con su motivo (FR-012).
- **Exactamente una** línea de resumen: `e2e summary: total=<N> executed=<N> skipped=<N> failed=<N>`.
- En el caso de verde vacío, una anotación `::error::` con el motivo.

## 4. Reglas de conteo

| Magnitud | Definición |
|----------|------------|
| `total` | líneas que empiezan con `ok N` o `not ok N` |
| `skipped` | líneas `ok N … # skip …` |
| `failed` | líneas `not ok N` |
| `executed` | `total - skipped` |

Sin mínimo de tests y sin exigir cero saltos. Exigir un número fijo se rompería cada vez que se agregue un e2e, y exigir cero saltos dejaría el nightly rojo para siempre si algún test tiene un salto legítimo.

## 5. Semántica de salida

| Código de `bats` | `executed` | Resultado del paso |
|:----------------:|:----------:|--------------------|
| distinto de 0 | cualquiera | termina con **ese código**, tras imprimir el resumen (FR-005) |
| 0 | 0 | termina en **1** con la anotación `::error::` (FR-006, SC-007) |
| 0 | mayor que 0 | termina en **0** |

El código de `bats` gana sobre la guarda: si `bats` no arranca (127) o falla, el paso lo dice sin disfrazarlo de verde vacío.

## 6. Tiempo (FR-016, SC-009)

El job tiene hoy un tope de 30 minutos. Si la primera corrida real lo agota, el primer remedio es **subir `timeout-minutes` y volver a medir**; dividir la suite en jobs paralelos solo con evidencia de que subir el tope no basta. Una corrida que agota el tiempo deja en el log el TAP de los tests que alcanzó a ejecutar. La conclusión del job la da GitHub (`timed_out`), no este paso.

## 7. Casos del oráculo

El arnés de [workflow-step-oracle.md](workflow-step-oracle.md) ejecuta el `run:` real en un directorio temporal que contiene un archivo `tests/docker-e2e-x.bats` (para que el glob se expanda) y un `tests/other.bats` (que el glob no debe tomar), y un `bats` falso en el `PATH` que **registra sus argumentos** en `$FAKE_ARGS`, imprime el TAP enlatado del caso y sale con el código indicado.

| ID | TAP enlatado | Código del `bats` falso | Debe afirmar |
|----|--------------|:-----------------------:|--------------|
| **S1** | `tap-all-skip.tap`: todos `ok … # skip` | 0 | Paso termina en 1; el resumen dice `executed=0`; aparece la anotación `::error::` |
| **S2** | `tap-empty.tap`: solo `1..0` | 0 | Paso termina en 1 (lista vacía) |
| **S3** | `tap-mixed.tap`: ok, ok, y un `# skip` | 0 | Paso termina en 0; el resumen cuenta bien (`total=3 executed=2 skipped=1 failed=0`); **los argumentos que recibió `bats` incluyen `--tap` y `tests/docker-e2e-x.bats` y no incluyen `tests/other.bats`** (FR-004: el glob toma todos los e2e y solo ellos) |
| **S4** | `tap-failing.tap`: un `not ok` | 1 | Paso termina en 1 (el código del `bats`); el resumen dice `failed=1` |
| **S5** | (sin salida) | 127 | Paso termina en 127, no en 1: el código de `bats` gana |
| **S6** | — | — | El `env:` extraído del paso trae `DOCKER_E2E` igual a `'1'` |

**Mutaciones que cada caso caza**: quitar la guarda `executed -eq 0` pone rojo S1 y S2; quitar `DOCKER_E2E` del `env:` pone rojo S6; cambiar `exit "$rc"` por un `exit 0` pone rojo S4 y S5; estrechar el glob (`tests/docker-e2e-smoke.bats`), ensancharlo (`tests/*.bats`) o quitar `--tap` pone rojo S3.

## 8. Fuera del contrato

- Cobertura reducida por diseño: `qmd real (016)` ejecuta su Tier A y pasa sin ejercer el Tier 2 si falta `QMD_EMBED_E2E=1`. No aparece como `# skip`, así que este paso no la ve. Se declara para que un nightly verde no se lea como cobertura total.
- Notificaciones o alertas de un nightly rojo.
- Qué e2e fallan y qué se hace con cada uno: [e2e-classification.md](e2e-classification.md).
