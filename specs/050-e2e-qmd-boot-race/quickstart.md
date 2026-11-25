# Guía de validación de la feature 050

**Fecha**: 24-11-2026. Ejecutar desde la raíz del launcher, en `050-e2e-qmd-boot-race`.

Las pruebas y las dos herramientas de reproducción ya están implementadas. Esta guía contiene sus comandos de validación; los resultados y las huellas aceptadas viven en el [Registro de tasks.md](tasks.md#registro). La evidencia local no sustituye el gate de CI antes del PR.

## 1. Comprobar el checkout y las dependencias

```bash
pwd
git branch --show-current
git status --short
bash -c 'printf "%s\n" "$BASH_VERSION"'
/bin/bash -c 'printf "%s\n" "$BASH_VERSION"'
bats --version
yq --version
jq --version
python3 --version
```

Esperado: rama 050, bash 3.2 y 5.x disponibles, Bats 1.5 o posterior (medido local: 1.13.0; la CI Linux instala 1.11.0), yq v4, jq y Python 3. El host sin Docker debe poder ejecutar toda la regresión del host.

## 2. Oráculos host, en serie

```bash
bats_bin=$(command -v bats)
PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin \
  /opt/homebrew/bin/bash "$bats_bin" --tap --print-output-on-failure \
  tests/qmd-e2e-boot-race.bats tests/qmd-e2e-lock.bats
PATH=/bin:/opt/homebrew/bin:/usr/bin:/usr/sbin:/sbin \
  /bin/bash "$bats_bin" --tap --print-output-on-failure \
  tests/qmd-e2e-boot-race.bats tests/qmd-e2e-lock.bats
```

En este Mac se selecciona explícitamente bash 5.x y después 3.2. En otro host ajustar las rutas del intérprete y PATH. Son 41 resultados: H00-H14 no deben saltarse; O1 de locks se salta en Darwin por ausencia de `/proc`. Los controles negativos son corridas internas que deben fallar por su condición; la suite exterior debe terminar verde.

Ver [host-oracle.md](contracts/host-oracle.md) para el catálogo de mutaciones y la comprobación del Bats hijo. No pasar TAP ni código extenso por argumentos o variables de entorno.

Para probar una copia usar `QMD_BOOT_RACE_E2E_FILE=/ruta/absoluta/copia.bats` con el oráculo nuevo. `QMD_BOOT_RACE_ARTIFACT_DIR=/ruta/externa/nueva` conserva opcionalmente código, TAP y trazas sintéticas del hijo, sin copiar HOME ni estado. El corredor y las veinte copias medidos están enlazados desde el Registro; cada reemplazo debe ser único. Ejecutar CTRL completo antes/después y B2 aparte sobre el candidato sano. M03/M04 son conductuales en 3.2 y guardias de forma en 5.x; M18 es rechazo estructural esperado.

## 3. Reproducción inducida local

Requiere un daemon Docker local ya operativo. La herramienta toma snapshots aislados y ejecuta D1-D4 en serie, con bash 5.x para observar el rojo original:

```bash
evidence_root="$HOME/.cache/agentic-pod-launcher/050"
mkdir -p "$evidence_root"
evidence_dir=$(mktemp -d "$evidence_root/run.XXXXXX")
PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin \
  python3 specs/050-e2e-qmd-boot-race/tools/reproduce.py \
  --baseline a45beaefaa68da17ce16d956351337bd5ce3b9d5 \
  --candidate-root "$PWD" \
  --output-dir "$evidence_dir"
```

Exigir código 0 del coordinador y cada resultado esperado de la matriz. D1 debe estar rojo por la aserción original; no es un fallo del coordinador si está identificado y sus gates están acreditados. Un vencimiento de control o una falla distinta no es reproducción válida. El protocolo y la limpieza están en [evidence-protocol.md](contracts/evidence-protocol.md).

La salida debe ser nueva o estar vacía y quedar fuera del checkout. Revisar `inputs.json`, `summary.json` y, por fila, `events.jsonl`, `inspection.json`, `result.json` y `cleanup.json`. Cada caso tiene sus propios snapshots y proyecto; la configuración del cliente Docker es sintética. No se borran imágenes ni cachés compartidos.

Para D2/D4, exigir el retorno real de setup después de release y antes de tick 1. Comprobar en la evidencia el proyecto Compose único por caso y las labels de sus recursos. Si el nombre fijo de contenedor ya está ocupado, la herramienta debe rechazar el caso sin tocar ese recurso; snapshots distintos no autorizan su reutilización o limpieza.

## 4. Docker normal, sin instrumentación

```bash
docker ps -aq --filter 'name=^/qmd-migrate-e2e$'
# Continuar solo si no hay un contenedor con ese nombre.
COMPOSE_PROJECT_NAME="qmd050-normal-$(python3 -c 'import uuid; print(uuid.uuid4().hex[:12])')" \
  DOCKER_E2E=1 bats --print-output-on-failure --tap tests/docker-e2e-qmd.bats \
  -f '^qmd e2e \(037\): a legacy vault-root collection migrates to wiki/-only on the first reindex tick$'
```

Esperado: exactamente una prueba seleccionada, ejecutada y verde, sin skip. Este comando usa el motor falso existente y no activa el gate de modelos de la 041. Su resultado complementa la matriz, no se infiere de ella.

## 5. Gate de regresión

Después de revisión independiente y sin otras corridas pesadas, ejecutar en serie:

```bash
PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin \
  /opt/homebrew/bin/bash "$bats_bin" --tap tests/
PATH=/bin:/opt/homebrew/bin:/usr/bin:/usr/sbin:/sbin \
  /bin/bash "$bats_bin" --tap tests/
git diff --check
git diff --exit-code a45beaefaa68da17ce16d956351337bd5ce3b9d5 -- \
  docker scripts modules setup.sh VERSION .github/workflows tests/helper-qmd-e2e.bash
```

Aplicar también el comando de shellcheck de `.github/workflows/shellcheck.yml`. `tests/` está excluido de ese workflow: revisar explícitamente sintaxis de ayudantes y herramientas nuevos. La base medida fue 2.300 y se añadieron 15 casos: esperado 2.315, con skips comparados por motivo. Guardar TAP, stderr, versiones, tiempos y hashes en evidencia externa; usar el mismo entorno mínimo registrado para comparar contra la base. No editar código ni ejecutar Docker u otra suite pesada durante el gate.

## 6. CI antes del PR

Con el código local validado y las compuertas de commit/publicación/CI autorizadas, publicar la rama y lanzar el workflow existente. El comando siguiente corresponde a esa compuerta posterior:

```bash
gh workflow run docker-e2e.yml --ref 050-e2e-qmd-boot-race
```

Identificar la corrida por rama y commit, guardar su URL y verificar arquitectura, conclusión, resumen y línea `ok` de la prueba sin skip, según el [protocolo de evidencia](contracts/evidence-protocol.md). Abrir el PR solo después de ese gate. La primera nocturna no sustituye la evidencia acordada antes del PR.
